#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 || ! "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$3" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Usage: appcast.sh <release-dmg> <github-owner/repository> <version-tag>\n' >&2
    exit 64
fi
if [[ ! -f "$1" || "${1##*/}" == *-development.dmg || -z "${AIDES_SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf 'A notarized DMG and the Sparkle private key are required.\n' >&2
    exit 64
fi

repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
swiftpm_dir="${AIDES_PACKAGE_SWIFTPM_DIR:-$repo/.build}"
archive="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
generate="$(find "$swiftpm_dir/artifacts/sparkle" -type f -name generate_appcast -print -quit)"
[[ -x "$generate" ]] || { printf 'Sparkle generate_appcast was not built.\n' >&2; exit 1; }
stage="$(mktemp -d "${TMPDIR:-/tmp}/aides-appcast.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$archive" "$stage/$(basename "$archive")"
url="https://github.com/$2/releases"

printf '%s\n' "$AIDES_SPARKLE_PRIVATE_KEY" | "$generate" --ed-key-file - \
    --download-url-prefix "$url/download/$3/" --full-release-notes-url "$url/tag/$3" \
    --maximum-deltas 0 "$stage"
[[ -s "$stage/appcast.xml" ]] || { printf 'Missing generated appcast.xml.\n' >&2; exit 1; }
if ! grep -Fq "$url/download/$3/$(basename "$archive")" "$stage/appcast.xml"; then
    printf 'Generated feed does not reference the release archive.\n' >&2
    exit 1
fi
signer="$(find "$swiftpm_dir/artifacts/sparkle" -type f -name sign_update -print -quit)"
[[ -x "$signer" ]]
printf '%s\n' "$AIDES_SPARKLE_PRIVATE_KEY" | "$signer" --ed-key-file - --verify "$stage/appcast.xml"
install -m 644 "$stage/appcast.xml" "$(dirname "$archive")/appcast.xml"
