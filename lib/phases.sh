# Sourced by build.sh. The three phases of a build, each run once: a marker in
# $STATE records that a phase finished, so running build.sh again skips it.

phase() {
    local name="$1" fn="$2"
    if [[ -f "$STATE/$name.done" ]]; then
        say "$name: already done"
        return 0
    fi
    local start=$SECONDS
    say "$name: starting"
    "$fn"
    touch "$STATE/$name.done"
    say "$name: done in $(( (SECONDS - start) / 60 )) minutes, $(free_gb "$WORK") GB free"
}

# Fetch depot_tools, CEF at the pinned commit and Chromium at the tag CEF names,
# without Chromium's history, then run Chromium's hooks.
sync_phase() {
    [[ -d "$DL/chromium/src/.git" ]] && finish_interrupted_sync
    automate --no-build --no-distrib
    repair_empty_deps
}

# A dependency whose first fetch failed (googlesource answers 429 and 503
# under load) is left as an empty repository, and every later gclient sync
# skips it, so the build stops on a missing source file hours later. Remove
# those and fetch them again.
repair_empty_deps() {
    local empty=() d
    while IFS= read -r d; do
        d="${d%/.git}"
        git -C "$d" rev-parse --verify -q HEAD >/dev/null || empty+=("$d")
    done < <(find "$DL/chromium/src" -name .git -prune -print)
    (( ${#empty[@]} > 0 )) || return 0
    say "sync: fetching again ${#empty[@]} dependencies that never got their first commit: ${empty[*]#"$DL/chromium/"}"
    rm -rf "${empty[@]}"
    (cd "$DL/chromium" && run_gclient sync --nohooks --no-history)
    for d in "${empty[@]}"; do
        git -C "$d" rev-parse --verify -q HEAD >/dev/null || { say "FAILED: $d is still empty; run the same command again"; exit 1; }
    done
}

# automate-git.py only syncs and runs hooks when it creates chromium/src. If an
# earlier run stopped partway, it would now skip both, so do them here first.
finish_interrupted_sync() {
    if ! git -C "$DL/chromium/src" rev-parse --verify -q HEAD >/dev/null; then
        # Stopped during the first fetch: nothing checked out, nothing to keep.
        say "sync: removing a Chromium checkout that never got its first commit"
        rm -rf "$DL/chromium/src"
        return 0
    fi
    say "sync: completing an interrupted Chromium checkout"
    skip_updater_binaries
    (cd "$DL/chromium" && run_gclient sync --nohooks --no-history)
    apply_cef_patch DEPS
    apply_cef_patch runhooks
    (cd "$DL/chromium" && run_gclient runhooks)
}

# Leaves out the prebuilt Chrome updater installers Chromium fetches for its
# updater tests. Nothing CEF builds uses them, and Microsoft Defender quarantines
# at least one of them (chrome_win_x86, 2026-10-16), which stops the sync with
# "the file contains a virus or potentially unwanted software". Written into
# the .gclient automate-git.py made, which it keeps from then on.
skip_updater_binaries() {
    local gclient="$DL/chromium/.gclient" deps="$DL/chromium/src/DEPS"
    [[ -f "$gclient" && -f "$deps" ]] || return 0
    "$PYTHON" - "$(native "$gclient")" "$(native "$deps")" <<'PY'
import re, sys
gclient, deps = sys.argv[1], sys.argv[2]
names = sorted(set(re.findall(r"'(src/third_party/updater/[^']+/cipd)'", open(deps, encoding="utf-8").read())))
text = open(gclient, encoding="utf-8").read()
skip = "'custom_deps': {" + "".join(f"'{n}': None, " for n in names) + "}"
text = re.sub(r"'custom_deps': \{[^}]*\}", lambda m: skip, text)
open(gclient, "w", encoding="utf-8").write(text)
PY
    say "sync: leaving out Chromium's updater test binaries"
}

# Applies one of CEF's pre-sync patches unless it is absent or already applied.
apply_cef_patch() {
    local patch="$DL/cef/patch/patches/$1.patch"
    [[ -f "$patch" ]] || return 0
    git -C "$DL/chromium/src" apply --check "$patch" 2>/dev/null || return 0
    say "sync: applying $1.patch"
    guarded "$PYTHON" "$(native "$DL/cef/tools/patcher.py")" \
        --patch-file "$(native "${patch%.patch}")" --patch-dir "$(native "$DL/chromium/src")"
}

build_dir() {
    case "$ARCH_FLAG" in --arm64-build) echo Release_GN_arm64 ;; *) echo Release_GN_x64 ;; esac
}

# Generate the GN projects and build the release libcef. ninja resumes a
# build that stopped, so running this again carries on where it was.
build_phase() {
    check_build_toolchain
    # Only this platform's configuration: GN would otherwise set up every
    # architecture it has a sysroot or an SDK for.
    export GN_OUT_CONFIGS="$(build_dir),$(build_dir)_sandbox"
    automate --no-update --force-build --no-distrib
    check_codec_args
}

# Refuses a build whose GN arguments lost the codec settings, and writes every
# codec related argument GN settled on, defaults included, to
# codec-args-<platform>.txt beside the archive.
check_codec_args() {
    local out="out/$(build_dir)" list="$OUT/codec-args-$PLATFORM.txt"
    (cd "$DL/chromium/src" && "$WORK/depot_tools/gn" args "$out" --list --short) \
        | grep -E 'proprietary_codecs|ffmpeg_branding|hevc|h264|openh264|dolby|ac3|ac4|dts|iamf|mpeg_h|hls|mpeg2ts|dav1d|libaom|widevine|cdm' >"$list"
    say "build: codec arguments, from gn args --list:"
    tee -a "$LOG" <"$list"
    grep -qx 'proprietary_codecs = true' "$list" && grep -qx 'ffmpeg_branding = "Chrome"' "$list" || {
        say "FAILED: $out does not have proprietary_codecs = true and ffmpeg_branding = \"Chrome\""
        exit 1
    }
    # Chromium turns the platform HEVC decoder on by default on Windows, macOS
    # and Linux once proprietary_codecs is set. Make sure nothing turned it off.
    if ! grep -qx 'enable_platform_hevc = true' "$list"; then
        say "FAILED: $out has enable_platform_hevc off"
        exit 1
    fi
}

# Make the minimal distribution archive and copy it out with its checksums.
distrib_phase() {
    automate --no-update --no-build --force-distrib --minimal-distrib-only \
        --no-distrib-docs --no-distrib-symbols
    local name; name="$(archive_name "$PLATFORM")"
    local made="$DL/chromium/src/cef/binary_distrib/$name"
    if [[ ! -f "$made" ]]; then
        say "FAILED: expected $name; binary_distrib has:"
        ls "$DL/chromium/src/cef/binary_distrib" | tee -a "$LOG"
        exit 1
    fi
    cp "$made" "$OUT/$name.part" && mv "$OUT/$name.part" "$OUT/$name"
    write_checksums "$OUT/$name"
    if [[ "${CLEAN_OUT:-0}" == 1 ]]; then
        say "distrib: CLEAN_OUT=1, removing out/$(build_dir) and its sandbox build"
        rm -rf "$DL/chromium/src/out/$(build_dir)" "$DL/chromium/src/out/$(build_dir)_sandbox"
    fi
}

# Writes <archive>.sha1 and <archive>.sha256 beside the archive, the way the
# official builds publish them: the bare hex digest and nothing else.
write_checksums() {
    local algo
    for algo in sha1 sha256; do
        "$PYTHON" -c 'import hashlib, sys
h = hashlib.new(sys.argv[1])
with open(sys.argv[2], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        h.update(block)
open(sys.argv[2] + "." + sys.argv[1], "w").write(h.hexdigest())' "$algo" "$(native "$1")"
    done
}
