#!/bin/bash

package_app() (
    set -euo pipefail
    product="$1"
    app_path="$PWD/$2"
    bundle_id="$3"
    display_name="$4"
    icon="${5:-}"
    configuration="${CONFIGURATION:-release}"
    version="$(python3 Scripts/version.py current)"
    build_number="${BUILD_NUMBER:-1}"
    if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
        printf 'BUILD_NUMBER must be a positive integer.\n' >&2
        exit 1
    fi
    read -r -a architectures <<< "${BUILD_ARCHITECTURES:-$(uname -m)}"
    binaries=()
    for architecture in "${architectures[@]}"; do
        case "$architecture" in
            arm64|x86_64) ;;
            *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
        esac
        build_flags=(-c "$configuration" --triple "$architecture-apple-macosx13.0")
        swift build "${build_flags[@]}" --product "$product"
        binary_path="$(swift build "${build_flags[@]}" --show-bin-path)"
        binaries+=("$binary_path/$product")
    done
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
    xcrun lipo -create "${binaries[@]}" -output "$bundle_path/Contents/MacOS/$product"
    cp LICENSE "$bundle_path/Contents/Resources/License.txt"
    cp ThirdParty/RNNoise/COPYING "$bundle_path/Contents/Resources/RNNoise-License.txt"
    if [[ "$product" == "Sidetone" ]]; then
        cp -R Sources/SidetoneKit/Resources/KeyboardSounds "$bundle_path/Contents/Resources/"
    fi
    plist="$bundle_path/Contents/Info.plist"
    cp Resources/Info.plist "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $product" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $display_name" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $display_name" "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
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
