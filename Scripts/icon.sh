#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors \
    Sources/Sidetone/SidetoneGlyph.swift Scripts/icon.swift -o "$staging/icon"
"$staging/icon" "$staging/AppIcon.iconset"
iconutil --convert icns "$staging/AppIcon.iconset" --output Resources/AppIcon.icns
