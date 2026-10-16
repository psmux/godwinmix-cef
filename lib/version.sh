# Sourced by build.sh and publish.sh. Everything about a build is derived from
# one input, the CEF version string as it appears in the official archive names
# and in the cef crate's +metadata:
#
#   150.0.10+g8042e43+chromium-150.0.7871.101
#
# A bare CEF number (150.0.10) is accepted too and looked up in the official
# index at cef-builds.spotifycdn.com, which lists every version CEF publishes.

OFFICIAL_INDEX_URL="${OFFICIAL_INDEX_URL:-https://cef-builds.spotifycdn.com/index.json}"

# Prints the full version for a bare CEF number, using the official index.
resolve_full_version() {
    local number="$1"
    curl -fsSL "$OFFICIAL_INDEX_URL" | "$PYTHON" -c '
import json, sys
number = sys.argv[1]
index = json.load(sys.stdin)
for platform in index.values():
    for v in platform.get("versions", []):
        if v["cef_version"].startswith(number + "+"):
            print(v["cef_version"]); sys.exit(0)
sys.exit("CEF " + number + " is not in the official index; pass the full version string")
' "$number"
}

# Sets CEF_VERSION, CEF_NUMBER, CEF_COMMIT, CHROMIUM_VERSION, CEF_BRANCH and
# RELEASE_TAG from the version given, or exits naming what was wrong with it.
parse_version() {
    local input="$1"
    [[ "$input" == *+* ]] || input="$(resolve_full_version "$input")" || exit 1
    if [[ ! "$input" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+g([0-9a-f]{7,40})\+chromium-([0-9]+\.[0-9]+\.([0-9]+)\.[0-9]+)$ ]]; then
        echo "version '$input' does not look like 150.0.10+g8042e43+chromium-150.0.7871.101" >&2
        exit 1
    fi
    CEF_VERSION="$input"
    CEF_NUMBER="${BASH_REMATCH[1]}"
    CEF_COMMIT="${BASH_REMATCH[2]}"
    CHROMIUM_VERSION="${BASH_REMATCH[3]}"
    # CEF release branches are named after Chromium's build number.
    CEF_BRANCH="${BASH_REMATCH[4]}"
    RELEASE_TAG="cef-$CEF_NUMBER"
}

# The archive name make_distrib.py produces and cef-builds.spotifycdn.com uses.
archive_name() {
    echo "cef_binary_${CEF_VERSION}_$1_minimal.tar.bz2"
}
