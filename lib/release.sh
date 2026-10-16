# Sourced by publish.sh. One GitHub release per CEF version, tagged
# cef-<number>, holding the archives, their checksums and an index.json in the
# format of https://cef-builds.spotifycdn.com/index.json.

ensure_release() {
    gh release view "$RELEASE_TAG" -R "$REPO" >/dev/null 2>&1 && return 0
    sed -e "s|@CEF_VERSION@|$CEF_VERSION|g" -e "s|@TAG@|$RELEASE_TAG|g" -e "s|@REPO@|$REPO|g" \
        "$HERE/release-notes.md" >"$STAGE/notes.md"
    # A draft, so nobody downloads a release with platforms still missing.
    # Publish it once every platform is in and checked:
    #   gh release edit "$RELEASE_TAG" -R "$REPO" --draft=false
    gh release create "$RELEASE_TAG" -R "$REPO" --target main --draft \
        --title "CEF $CEF_VERSION with H.264 and AAC" --notes-file "$STAGE/notes.md"
}

# Checks the archive's name and checksum files, then uploads all three.
upload_archive() {
    local archive="$1" name; name="$(basename "$1")"
    if [[ ! "$name" =~ ^cef_binary_${CEF_VERSION//+/\\+}_(windows64|windowsarm64|macosarm64|macosx64|linux64|linuxarm64)_minimal\.tar\.bz2$ ]]; then
        echo "$name is not a minimal archive of $CEF_VERSION; refusing to upload it" >&2
        exit 1
    fi
    local algo
    for algo in sha1 sha256; do
        [[ -f "$archive.$algo" ]] || write_checksum "$algo" "$archive" "$archive.$algo"
        write_checksum "$algo" "$archive" "$STAGE/check"
        cmp -s "$STAGE/check" "$archive.$algo" || { echo "$archive.$algo does not match the archive" >&2; exit 1; }
    done
    echo "uploading $name ($(( $(wc -c <"$archive") / 1048576 )) MB)"
    gh release upload "$RELEASE_TAG" -R "$REPO" --clobber "$archive" "$archive.sha1" "$archive.sha256"
}

# Writes the bare hex digest of $2 into $3.
write_checksum() {
    "$PYTHON" -c 'import hashlib, sys
h = hashlib.new(sys.argv[1])
with open(sys.argv[2], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        h.update(block)
open(sys.argv[3], "w").write(h.hexdigest())' "$1" "$(native_path "$2")" "$(native_path "$3")"
}

native_path() { if [[ "$HOST_OS" == windows ]]; then cygpath -m "$1"; else echo "$1"; fi; }

# Rebuilds index.json from every archive now in the release, so a platform
# published from another machine keeps its entry.
write_index() {
    gh release view "$RELEASE_TAG" -R "$REPO" --json assets \
        -q '.assets[] | select(.name | endswith("_minimal.tar.bz2")) | "\(.name) \(.size) \(.updatedAt)"' >"$STAGE/assets.txt"
    gh release download "$RELEASE_TAG" -R "$REPO" --pattern '*_minimal.tar.bz2.sha1' --dir "$STAGE/sha1" --clobber
    "$PYTHON" - "$CEF_VERSION" "$(native_path "$STAGE")" <<'PY'
import json, os, sys
version, stage = sys.argv[1], sys.argv[2]
platforms = ["macosarm64", "macosx64", "windows64", "windowsarm64", "windows32",
             "linux64", "linuxarm64", "linuxarm"]
index = {p: {"versions": []} for p in platforms}
for line in open(os.path.join(stage, "assets.txt")):
    name, size, updated = line.split()
    platform = name[len("cef_binary_" + version + "_"):-len("_minimal.tar.bz2")]
    sha1 = open(os.path.join(stage, "sha1", name + ".sha1")).read().strip()
    index[platform]["versions"].append({
        "channel": "stable",
        "cef_version": version,
        "files": [{"type": "minimal", "name": name, "sha1": sha1,
                   "size": int(size), "last_modified": updated}],
    })
with open(os.path.join(stage, "index.json"), "w") as f:
    json.dump(index, f, indent=2)
PY
    gh release upload "$RELEASE_TAG" -R "$REPO" --clobber "$STAGE/index.json"
}
