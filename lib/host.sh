# Sourced by build.sh. What differs between the machines a build runs on:
# the CEF platform name, the automate-git architecture flag, the toolchain
# checks, and how to keep a build from taking every core.

# Sets HOST_OS (windows, macos, linux) and PLATFORM (windows64, windowsarm64,
# macosarm64, macosx64, linux64, linuxarm64) for this machine, unless PLATFORM
# is set. windowsarm64 is a cross build on an x64 Windows machine.
detect_host() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
        Darwin) HOST_OS=macos ;;
        Linux) HOST_OS=linux ;;
        *) echo "unsupported build host: $(uname -s)" >&2; exit 1 ;;
    esac
    local machine; machine="$(uname -m)"
    if [[ -z "${PLATFORM:-}" ]]; then
        case "$HOST_OS/$machine" in
            windows/*) PLATFORM=windows64 ;;
            macos/arm64) PLATFORM=macosarm64 ;;
            macos/x86_64) PLATFORM=macosx64 ;;
            linux/x86_64) PLATFORM=linux64 ;;
            linux/aarch64) PLATFORM=linuxarm64 ;;
            *) echo "no CEF platform for $HOST_OS on $machine" >&2; exit 1 ;;
        esac
    fi
    case "$PLATFORM" in
        windows64|macosx64|linux64) ARCH_FLAG=--x64-build ;;
        windowsarm64|macosarm64|linuxarm64) ARCH_FLAG=--arm64-build ;;
        *) echo "PLATFORM must be windows64, windowsarm64, macosarm64, macosx64, linux64 or linuxarm64" >&2; exit 1 ;;
    esac
}

# Finds Visual Studio and tells Chromium's vs_toolchain.py where it is.
# Chromium wants Visual Studio 2022 or 2026 with the C++ workload and ATL,
# and Windows SDK 10.0.26100 with its Debugging Tools.
find_visual_studio() {
    local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    [[ -x "$vswhere" ]] || { echo "Visual Studio is not installed; see README, Windows" >&2; exit 1; }
    local vs; vs="$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')"
    local major; major="$("$vswhere" -latest -products '*' -property installationVersion | cut -d. -f1 | tr -d '\r')"
    [[ -n "$vs" ]] || { echo "Visual Studio has no C++ x64 tools; add the 'Desktop development with C++' workload" >&2; exit 1; }
    case "$major" in
        18) export vs2026_install="$vs" ;;
        17) export vs2022_install="$vs" ;;
        *) echo "Visual Studio $major found; Chromium needs 2022 (17) or 2026 (18)" >&2; exit 1 ;;
    esac
    export GYP_MSVS_OVERRIDE_PATH="$vs"
}

# The parts only the compile needs, checked before the build phase so a
# missing one does not hold up the sync.
check_build_toolchain() {
    [[ "$HOST_OS" == windows ]] || return 0
    local vs="$GYP_MSVS_OVERRIDE_PATH" missing=""
    compgen -G "$(cygpath -u "$vs")/VC/Tools/MSVC/*/atlmfc/include/atlbase.h" >/dev/null || missing+=" Microsoft.VisualStudio.Component.VC.ATL"
    [[ -f "/c/Program Files (x86)/Windows Kits/10/Debuggers/x64/dbghelp.dll" ]] || missing+=" Debuggers"
    [[ -d "/c/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0" ]] || missing+=" SDK26100"
    if [[ "$PLATFORM" == windowsarm64 ]]; then
        compgen -G "$(cygpath -u "$vs")/VC/Tools/MSVC/*/lib/arm64" >/dev/null || missing+=" Microsoft.VisualStudio.Component.VC.Tools.ARM64"
        compgen -G "$(cygpath -u "$vs")/VC/Tools/MSVC/*/atlmfc/lib/arm64" >/dev/null || missing+=" Microsoft.VisualStudio.Component.VC.ATL.ARM64"
        [[ -d "/c/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0/um/arm64" ]] || missing+=" SDK26100(arm64)"
    fi
    if [[ -n "$missing" ]]; then
        echo "the Windows toolchain is missing:$missing" >&2
        echo "install it from an elevated prompt, as README.md, Windows, shows" >&2
        exit 1
    fi
}

# Environment every Chromium build on this host needs.
setup_host() {
    case "$HOST_OS" in
        windows)
            find_visual_studio
            export DEPOT_TOOLS_WIN_TOOLCHAIN=0
            # Chromium's checkout breaks under CRLF conversion and needs long
            # paths. Set for these processes only, never in the user's config.
            export GIT_CONFIG_COUNT=3
            export GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
            export GIT_CONFIG_KEY_1=core.longpaths GIT_CONFIG_VALUE_1=true
            export GIT_CONFIG_KEY_2=core.filemode GIT_CONFIG_VALUE_2=false
            ;;
        macos)
            xcode-select -p >/dev/null 2>&1 || { echo "install Xcode and run xcode-select" >&2; exit 1; }
            ;;
        linux)
            # Chromium's own sysroots, so the result runs on older glibc too.
            # CFI is off as in CEF's own Linux builds.
            HOST_GN_DEFINES="use_sysroot=true is_cfi=false"
            # The arm64 sysroot is only fetched when asked for.
            [[ "$PLATFORM" == linuxarm64 ]] && export CEF_INSTALL_SYSROOT=arm64
            ;;
    esac
    # A cross build needs CEF told to configure the other architecture.
    case "$PLATFORM/$(uname -m)" in
        macosx64/arm64) export CEF_ENABLE_AMD64=1 ;;
        macosarm64/x86_64) export CEF_ENABLE_ARM64=1 ;;
    esac
}

# Prints free space in whole GB on the filesystem holding $1.
free_gb() {
    # In WSL df sees the virtual disk, not the Windows drive under it, so
    # FREE_GB_CMD can ask Windows instead.
    if [[ -n "${FREE_GB_CMD:-}" ]]; then
        bash -c "$FREE_GB_CMD" | tr -dc '0-9'
        echo
        return
    fi
    df -Pk "$1" | awk 'NR==2 { printf "%d\n", $4 / 1048576 }'
}

# Kills a process and everything it started. $1 is a pid from $!.
kill_tree() {
    if [[ "$HOST_OS" == windows ]]; then
        local winpid; winpid="$(cat "/proc/$1/winpid" 2>/dev/null)"
        [[ -n "$winpid" ]] && taskkill //T //F //PID "$winpid" >/dev/null 2>&1
    fi
    pkill -TERM -P "$1" 2>/dev/null
    kill -TERM "$1" 2>/dev/null
}

# Keeps the build to JOBS hardware threads and below normal priority, so the
# machine stays usable. Children inherit both. $1 is a pid from $!.
limit_cpu() {
    local pid="$1" jobs="${JOBS:-}"
    [[ -n "$jobs" ]] || return 0
    case "$HOST_OS" in
        windows)
            local winpid; winpid="$(cat "/proc/$pid/winpid")"
            local mask=$(( (1 << jobs) - 1 ))
            powershell.exe -NoProfile -Command "\$p = Get-Process -Id $winpid; \$p.ProcessorAffinity = $mask; \$p.PriorityClass = 'BelowNormal'" >/dev/null
            ;;
        linux) taskset -a -p -c "0-$(( jobs - 1 ))" "$pid" >/dev/null; renice -n 10 -p "$pid" >/dev/null ;;
        macos) renice -n 10 -p "$pid" >/dev/null ;;
    esac
}

# macOS has no way to pin a process to some cores, so on a Mac the thread
# limit goes to the compiler instead: an autoninja ahead of depot_tools' own
# on PATH, which passes it -j JOBS. automate-git.py runs autoninja by name.
limit_build_jobs() {
    [[ "$HOST_OS" == macos && -n "${JOBS:-}" ]] || return 0
    local shims="$WORK/shims"
    mkdir -p "$shims"
    printf '#!/bin/sh\nexec "%s/depot_tools/autoninja" -j %s "$@"\n' "$WORK" "$JOBS" >"$shims/autoninja"
    chmod +x "$shims/autoninja"
    export PATH="$shims:$PATH"
}

# Since Xcode 26 the Metal compiler is a separate download, and ANGLE compiles
# its Metal shaders during the build. Xcode's own copy (xcodebuild
# -downloadComponent MetalToolchain) is used when it is installed. Otherwise a
# copy unpacked under $WORK/metal (or METAL_TOOLCHAIN), which needs no admin
# rights; README.md, macOS, says how to make one.
use_metal_toolchain() {
    [[ "$HOST_OS" == macos ]] || return 0
    xcrun metal --version >/dev/null 2>&1 && return 0
    local bin="${METAL_TOOLCHAIN:-$WORK/metal/Metal.xctoolchain}/usr/bin"
    if [[ ! -x "$bin/metal" ]]; then
        echo "Xcode's Metal toolchain is missing. Run: xcodebuild -downloadComponent MetalToolchain" >&2
        echo "or unpack it to $WORK/metal/Metal.xctoolchain without admin rights, as README.md, macOS, shows" >&2
        exit 1
    fi
    GN_DEFINES+=" angle_metal_toolchain_dir=$bin"
}
