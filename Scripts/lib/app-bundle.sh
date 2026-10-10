#!/bin/bash

package_app() (
    set -euo pipefail
    product="$1"
    app_path="$PWD/$2"
    bundle_id="$3"
    display_name="$4"
    icon="${5:-}"
    configuration="${CONFIGURATION:-release}"
    swift build -c "$configuration" --product "$product"
    binary_path="$(swift build -c "$configuration" --show-bin-path)"
    output_dir="$(dirname "$app_path")"
    mkdir -p "$output_dir"
    staging="$(mktemp -d "$output_dir/.sidetone.XXXXXX")"
    cleanup() {
        if [[ ! -e "$app_path" && -e "$staging/previous.app" ]]; then
            mv "$staging/previous.app" "$app_path"
        fi
        rm -rf "$staging"
    }
    trap cleanup EXIT
    bundle_path="$staging/$product.app"
    mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
    cp "$binary_path/$product" "$bundle_path/Contents/MacOS/$product"
    plist="$bundle_path/Contents/Info.plist"
    cp Resources/Info.plist "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $product" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $display_name" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $display_name" "$plist"
    if [[ -n "$icon" && -f "Resources/$icon" ]]; then
        cp "Resources/$icon" "$bundle_path/Contents/Resources/$icon"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${icon%.*}" "$plist"
    else
        /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$plist"
    fi
    identity="${SIGNING_IDENTITY:--}"
    signing_options=(--force --sign "$identity" --options runtime --entitlements Resources/Sidetone.entitlements)
    if [[ "$identity" != "-" ]]; then signing_options+=(--timestamp); fi
    codesign "${signing_options[@]}" "$bundle_path"
    codesign --verify --deep --strict "$bundle_path"
    if [[ -e "$app_path" ]]; then mv "$app_path" "$staging/previous.app"; fi
    mv "$bundle_path" "$app_path"
    printf 'Built %s\n' "$app_path"
)
