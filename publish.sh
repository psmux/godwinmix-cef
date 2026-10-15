#!/usr/bin/env bash
#
# Upload the archives build.sh made to this repository's release for their CEF
# version, with their checksums, and rewrite the release's index.json so the
# cef crate's downloader can use the release as its CDN:
#
#   ./publish.sh 150.0.10+g8042e43+chromium-150.0.7871.101 [archive ...]
#
# With no archives named it uploads every one in $WORK/out/cef-<number>/.
# Archives built on another machine can be copied there first, or named here.
# Running it again replaces the assets it uploads and leaves the others.
#
# Needs: gh, logged in with write access to the repository.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/version.sh"
source "$HERE/lib/host.sh"
detect_host
if [[ -z "${PYTHON:-}" ]]; then
    if [[ "$HOST_OS" == windows ]]; then PYTHON=python; else PYTHON=python3; fi
fi
parse_version "${1:?usage: ./publish.sh <cef version> [archive ...]}"
shift
REPO="${REPO:-psmux/godwinmix-cef}"
if [[ "$HOST_OS" == windows ]]; then WORK="${WORK:-/c/cef-build}"; else WORK="${WORK:-$HOME/cef-build}"; fi
OUT="$WORK/out/$RELEASE_TAG"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

archives=("$@")
if (( ${#archives[@]} == 0 )); then
    shopt -s nullglob
    archives=("$OUT"/cef_binary_"$CEF_VERSION"_*_minimal.tar.bz2)
fi
(( ${#archives[@]} > 0 )) || { echo "no archives for $CEF_VERSION in $OUT; run ./build.sh $CEF_VERSION first" >&2; exit 1; }

source "$HERE/lib/release.sh"
ensure_release
for archive in "${archives[@]}"; do upload_archive "$archive"; done
write_index
echo "published: https://github.com/$REPO/releases/tag/$RELEASE_TAG"
echo "use it with: CEF_DOWNLOAD_URL=https://github.com/$REPO/releases/download/$RELEASE_TAG"
