#!/bin/bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
if [[ $# -ne 4 || ! "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Usage: release.sh <github-owner/repository> <version-tag> <build-number> <products-dir>\n' >&2
    exit 64
fi
for name in AIDES_DEVELOPER_ID_P12 AIDES_DEVELOPER_ID_PASSWORD AIDES_CODESIGN_IDENTITY \
    AIDES_NOTARY_P8 AIDES_NOTARY_KEY_ID AIDES_NOTARY_ISSUER AIDES_UPDATE_PUBLIC_KEY \
    AIDES_SPARKLE_PRIVATE_KEY; do
    if [[ -z "${!name:-}" ]]; then
        printf 'Release configuration is missing %s.\n' "$name" >&2
        exit 1
    fi
done

stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aides-sign.XXXXXX")"
keychain="$stage/release.keychain-db"
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$stage"
}
trap cleanup EXIT
password="$(openssl rand -hex 24)"
printf '%s' "$AIDES_DEVELOPER_ID_P12" | base64 -D > "$stage/developer-id.p12"
printf '%s' "$AIDES_NOTARY_P8" | base64 -D > "$stage/notary.p8"
unset AIDES_DEVELOPER_ID_P12 AIDES_NOTARY_P8
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$stage/developer-id.p12" -k "$keychain" -P "$AIDES_DEVELOPER_ID_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"
unset AIDES_DEVELOPER_ID_PASSWORD

export AIDES_CODESIGN_KEYCHAIN="$keychain"
export AIDES_NOTARY_KEY_FILE="$stage/notary.p8"
export AIDES_UPDATE_FEED_URL="https://github.com/$1/releases/latest/download/appcast.xml"
export AIDES_BUILD_PRODUCTS_DIR="$4"
dmg="$("$script_dir/package.sh" "${2#v}" "$3")"
"$script_dir/appcast.sh" "$dmg" "$1" "$2"
(
    cd "$(dirname "$dmg")"
    shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt
)
