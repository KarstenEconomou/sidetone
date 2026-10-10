#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product SidetoneProbe
binary_path="$(swift build -c release --show-bin-path)"
app_path="$PWD/build/SidetoneProbe.app"
mkdir -p build
staging="$(mktemp -d "$PWD/build/.probe.XXXXXX")"
cleanup() {
    if [[ ! -e "$app_path" && -e "$staging/previous.app" ]]; then
        mv "$staging/previous.app" "$app_path"
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
bundle_path="$staging/SidetoneProbe.app"
mkdir -p "$bundle_path/Contents/MacOS"
cp "$binary_path/SidetoneProbe" "$bundle_path/Contents/MacOS/SidetoneProbe"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SidetoneProbe' "$bundle_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.sidetone.probe' "$bundle_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Sidetone Probe' "$bundle_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Sidetone Probe' "$bundle_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$bundle_path/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements Resources/Sidetone.entitlements "$bundle_path"
if [[ -e "$app_path" ]]; then mv "$app_path" "$staging/previous.app"; fi
mv "$bundle_path" "$app_path"
cleanup
trap - EXIT
exec "$app_path/Contents/MacOS/SidetoneProbe" "$@"
