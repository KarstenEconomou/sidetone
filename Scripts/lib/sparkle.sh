#!/bin/bash

embed_sparkle() {
    local app_path="$1"
    local artifacts="$PWD/.build/artifacts/sparkle/Sparkle"
    mkdir -p "$app_path/Contents/Frameworks"
    /usr/bin/ditto "$artifacts/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
        "$app_path/Contents/Frameworks/Sparkle.framework"
    cp "$artifacts/LICENSE" "$app_path/Contents/Resources/Sparkle-License.txt"
    /usr/libexec/PlistBuddy -c 'Merge Resources/Updates.plist' "$app_path/Contents/Info.plist"
}

sign_sparkle() {
    local app_path="$1"
    local identity="$2"
    local framework="$app_path/Contents/Frameworks/Sparkle.framework"
    local signing_options=(--force --sign "$identity" --options runtime --preserve-metadata=entitlements)
    if [[ "$identity" != "-" ]]; then signing_options+=(--timestamp); fi
    local component
    for component in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
        codesign "${signing_options[@]}" "$framework/Versions/B/$component"
    done
    codesign "${signing_options[@]}" "$framework"
}
