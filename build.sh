#!/usr/bin/env bash
#
# Build a minimal CEF binary distribution with H.264 and AAC for this machine,
# named and laid out like the official archives at cef-builds.spotifycdn.com.
#
#   ./build.sh 150.0.10+g8042e43+chromium-150.0.7871.101
#   ./build.sh 150.0.10                     # looked up in the official index
#
# Safe to run again after anything stops it: each phase leaves a marker when it
# finishes, a half done Chromium sync is completed with gclient, and ninja
# carries on a half done build. See README.md for the time and disk it takes.
#
# Environment:
#   WORK          where everything goes (C:/cef-build on Windows, ~/cef-build elsewhere)
#   PLATFORM      windows64, windowsarm64, macosarm64, macosx64, linux64 or linuxarm64 (default: this machine)
#   JOBS          hardware threads the build may use (default: all)
#   MIN_FREE_GB   stop the build when free disk falls below this (default 25)
#   FREE_GB_CMD   a command printing free GB, when df cannot see the real disk (WSL)
#   CLEAN_OUT     1 to delete the build's objects once its archive is made
#   STOP_AFTER    sync or build, to stop after that phase
#   EXTRA_GN_DEFINES  added to the GN arguments (default symbol_level=0: no debug symbols, which the minimal
#                 distribution does not carry anyway, and about half the disk)
#   PYTHON        the Python 3 that runs automate-git.py (default python3, or python on Windows)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/version.sh"
source "$HERE/lib/host.sh"

detect_host
if [[ -z "${PYTHON:-}" ]]; then
    if [[ "$HOST_OS" == windows ]]; then PYTHON=python; else PYTHON=python3; fi
fi
parse_version "${1:?usage: ./build.sh <cef version>}"
setup_host

if [[ "$HOST_OS" == windows ]]; then WORK="${WORK:-/c/cef-build}"; else WORK="${WORK:-$HOME/cef-build}"; fi
MIN_FREE_GB="${MIN_FREE_GB:-25}"
CHECK_SECONDS="${CHECK_SECONDS:-600}"
DL="$WORK/$CEF_BRANCH"
STATE="$WORK/state/$CEF_NUMBER-$PLATFORM"
OUT="$WORK/out/$RELEASE_TAG"
LOG="$STATE/build.log"
mkdir -p "$DL" "$STATE" "$OUT"

export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome ${HOST_GN_DEFINES:-} ${EXTRA_GN_DEFINES-symbol_level=0}"
export CEF_ARCHIVE_FORMAT=tar.bz2
# So the log shows automate-git.py as it goes, not in 8 KB blocks.
export PYTHONUNBUFFERED=1
export PATH="$WORK/depot_tools:$PATH"
limit_build_jobs

say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# A path Python on this host understands.
native() { if [[ "$HOST_OS" == windows ]]; then cygpath -m "$1"; else echo "$1"; fi; }

# Runs a command in the background, CPU limited, while watching free disk.
# Stops it and returns 3 if free disk falls below MIN_FREE_GB.
guarded() {
    "$@" >>"$LOG" 2>&1 &
    local pid=$! waited=0
    limit_cpu "$pid" || say "could not limit the build to $JOBS threads; it runs unlimited"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 20
        waited=$(( waited + 20 ))
        (( waited % CHECK_SECONDS == 0 )) || continue
        local free; free="$(free_gb "$WORK")"
        say "still running, $free GB free on the build disk"
        if (( free < MIN_FREE_GB )); then
            say "STOPPED: free disk is $free GB, below MIN_FREE_GB=$MIN_FREE_GB. Free some space and run the same command again to resume."
            kill_tree "$pid"; wait "$pid" 2>/dev/null || true
            return 3
        fi
    done
    wait "$pid"
}

automate() {
    local script="$WORK/automate/$CEF_BRANCH/automate-git.py"
    if [[ ! -f "$script" ]]; then
        mkdir -p "$(dirname "$script")"
        curl -fsSL "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_BRANCH/tools/automate/automate-git.py" -o "$script.part"
        mv "$script.part" "$script"
    fi
    guarded "$PYTHON" "$(native "$script")" \
        --download-dir="$(native "$DL")" --depot-tools-dir="$(native "$WORK/depot_tools")" \
        --branch="$CEF_BRANCH" --checkout="$CEF_COMMIT" \
        --no-chromium-history --with-pgo-profiles --no-debug-build $ARCH_FLAG "$@"
}

run_gclient() {
    if [[ "$HOST_OS" == windows ]]; then guarded cmd.exe //c gclient "$@"; else guarded "$WORK/depot_tools/gclient" "$@"; fi
}

source "$HERE/lib/phases.sh"

free="$(free_gb "$WORK")"
say "CEF $CEF_VERSION for $PLATFORM in $WORK ($free GB free, branch $CEF_BRANCH, commit $CEF_COMMIT)"
say "GN_DEFINES=$GN_DEFINES"
(( free >= MIN_FREE_GB )) || { say "STOPPED: only $free GB free, MIN_FREE_GB is $MIN_FREE_GB"; exit 3; }
phase sync sync_phase
[[ "${STOP_AFTER:-}" == sync ]] && { say "stopping after sync, as STOP_AFTER asks"; exit 0; }
phase build build_phase
[[ "${STOP_AFTER:-}" == build ]] && { say "stopping after build, as STOP_AFTER asks"; exit 0; }
phase distrib distrib_phase
say "done: $OUT/$(archive_name "$PLATFORM")"
say "publish it with: ./publish.sh $CEF_VERSION"
