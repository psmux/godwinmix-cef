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
    (cd "$DL/chromium" && run_gclient sync --nohooks --no-history)
    apply_cef_patch DEPS
    apply_cef_patch runhooks
    (cd "$DL/chromium" && run_gclient runhooks)
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

# Refuses a build whose GN arguments lost the codec settings.
check_codec_args() {
    local args="$DL/chromium/src/out/$(build_dir)/args.gn"
    grep -q 'proprietary_codecs *= *true' "$args" && grep -q 'ffmpeg_branding *= *"Chrome"' "$args" || {
        say "FAILED: $args does not set proprietary_codecs=true and ffmpeg_branding=\"Chrome\""
        exit 1
    }
    say "build: $args has proprietary_codecs=true and ffmpeg_branding=\"Chrome\""
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
