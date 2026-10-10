#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(python3 Scripts/version.py current)"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Sidetone.app/Contents/Info.plist)"
if [[ "$bundle_version" != "$version" ]]; then
    printf 'The app version does not match VERSION. Build the app first.\n' >&2
    exit 1
fi
codesign --verify --deep --strict dist/Sidetone.app
xcrun lipo dist/Sidetone.app/Contents/MacOS/Sidetone -verify_arch arm64 x86_64
archive="Sidetone-$version-macos-universal.zip"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn dist/Sidetone.app "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
printf 'Distribution file: %s/dist/%s\n' "$PWD" "$archive"
