#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration" --product Sidetone
binary_path="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/dist/Sidetone.app"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.sidetone.XXXXXX")"
cleanup() {
    if [[ ! -e "$app_path" && -e "$staging/previous.app" ]]; then
        mv "$staging/previous.app" "$app_path"
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
bundle_path="$staging/Sidetone.app"
mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_path/Sidetone" "$bundle_path/Contents/MacOS/Sidetone"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$bundle_path/Contents/Resources/AppIcon.icns"
fi
identity="${SIGNING_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --options runtime --entitlements Resources/Sidetone.entitlements "$bundle_path"
else
    codesign --force --sign "$identity" --timestamp --options runtime --entitlements Resources/Sidetone.entitlements "$bundle_path"
fi
codesign --verify --deep --strict "$bundle_path"
if [[ -e "$app_path" ]]; then mv "$app_path" "$staging/previous.app"; fi
mv "$bundle_path" "$app_path"
printf 'Built %s\n' "$app_path"
