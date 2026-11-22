#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$script_dir/../.." && pwd -P)"
cd "$repo"

version="${1:-0.1.0}"
build_number="${2:-1}"
output_dir="${AIDES_DIST_DIR:-$repo/dist}"
identity="${AIDES_CODESIGN_IDENTITY:--}"
feed_url="${AIDES_UPDATE_FEED_URL:-}"
update_key="${AIDES_UPDATE_PUBLIC_KEY:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Usage: package.sh [major.minor.patch] [positive build number]\n' >&2
    exit 64
fi
if [[ -n "$feed_url" || -n "$update_key" ]]; then
    if [[ "$identity" == - || "$feed_url" != https://* || -z "$update_key" ]]; then
        printf 'Updates require a Developer ID identity, HTTPS appcast URL and Sparkle public key.\n' >&2
        exit 64
    fi
    export AIDES_ENABLE_SPARKLE=1
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
stage="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
build_args=(-c release -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
bin_dir="${AIDES_BUILD_PRODUCTS_DIR:-}"
if [[ -z "$bin_dir" ]]; then
    swift build "${build_args[@]}" --product AidesDesktop
    swift build "${build_args[@]}" --product AidesServer
    bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
fi
app="$stage/image/Aides.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources" "$contents/Frameworks"
cp "$script_dir/Info.plist" "$contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -insert CFBundleVersion -string "$build_number" "$contents/Info.plist"
install -m 755 "$bin_dir/AidesDesktop" "$contents/MacOS/AidesDesktop"
install -m 755 "$bin_dir/AidesServer" "$contents/Helpers/AidesServer"
install -m 755 "$script_dir/aides-service" "$contents/Resources/aides-service"
for executable in "$contents/MacOS/AidesDesktop" "$contents/Helpers/AidesServer"; do
    if ! otool -l "$executable" | awk '$1 == "path" && $2 == "@executable_path/../Frameworks" { found=1 } END { exit !found }'; then
        install_name_tool -add_rpath '@executable_path/../Frameworks' "$executable"
    fi
done
ln -s /Applications "$stage/image/Applications"
xcrun swift-stdlib-tool --copy --platform macosx --destination "$contents/Frameworks" \
    --scan-executable "$contents/MacOS/AidesDesktop" --scan-executable "$contents/Helpers/AidesServer"

framework=""
if [[ "${AIDES_ENABLE_SPARKLE:-0}" == 1 ]]; then
    framework_source="$(find .build/artifacts/sparkle -type d -name Sparkle.framework -print -quit)"
    [[ -n "$framework_source" ]] || { printf 'Unable to find the built Sparkle framework.\n' >&2; exit 1; }
    framework="$contents/Frameworks/Sparkle.framework"
    ditto "$framework_source" "$framework"
fi

if [[ -n "$feed_url" ]]; then
    plutil -insert SUFeedURL -string "$feed_url" "$contents/Info.plist"
    plutil -insert SUPublicEDKey -string "$update_key" "$contents/Info.plist"
    plutil -insert SURequireSignedFeed -bool YES "$contents/Info.plist"
    plutil -insert SUEnableAutomaticChecks -bool YES "$contents/Info.plist"
    plutil -insert SUAllowsAutomaticUpdates -bool NO "$contents/Info.plist"
fi

sign=(codesign --force --sign "$identity")
if [[ "$identity" != - ]]; then
    sign+=(--options runtime --timestamp)
    if [[ -n "${AIDES_CODESIGN_KEYCHAIN:-}" ]]; then
        sign+=(--keychain "$AIDES_CODESIGN_KEYCHAIN")
    fi
fi
while IFS= read -r -d '' library; do
    "${sign[@]}" "$library"
done < <(find "$contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print0)
"${sign[@]}" "$contents/Helpers/AidesServer"
if [[ -n "$framework" ]]; then
    framework_version="$framework/Versions/Current"
    "${sign[@]}" "$framework_version/Autoupdate"
    "${sign[@]}" "$framework_version/Updater.app"
    if [[ -d "$framework_version/XPCServices" ]]; then
        while IFS= read -r -d '' service; do
            "${sign[@]}" --preserve-metadata=entitlements "$service"
        done < <(find "$framework_version/XPCServices/" -type d -name '*.xpc' -print0)
    fi
    "${sign[@]}" "$framework"
fi
"${sign[@]}" "$app"
codesign --verify --deep --strict "$app"

architecture="$(uname -m)"
file_name="Aides-$version-$architecture.dmg"
if [[ "$identity" == - ]]; then
    file_name="Aides-$version-$architecture-development.dmg"
    printf 'This DMG is locally signed for development and has no Apple notarization.\n' >&2
fi
dmg="$stage/$file_name"
hdiutil create -volname Aides -srcfolder "$stage/image" -format UDZO "$dmg" >/dev/null
if [[ "$identity" != - ]]; then
    if [[ -z "${AIDES_NOTARY_KEY_FILE:-}" || -z "${AIDES_NOTARY_KEY_ID:-}" || -z "${AIDES_NOTARY_ISSUER:-}" ]]; then
        printf 'A Developer ID release also requires App Store Connect notarization credentials.\n' >&2
        exit 1
    fi
    "${sign[@]}" "$dmg"
    xcrun notarytool submit "$dmg" --wait --key "$AIDES_NOTARY_KEY_FILE" \
        --key-id "$AIDES_NOTARY_KEY_ID" --issuer "$AIDES_NOTARY_ISSUER" >&2
    xcrun stapler staple "$dmg" >&2
    xcrun stapler validate "$dmg" >&2
fi
mv -f "$dmg" "$output_dir/$file_name"
printf '%s\n' "$output_dir/$file_name"
