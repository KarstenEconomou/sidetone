#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile.}"
if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    printf 'Use a Developer ID Application identity.\n' >&2
    exit 1
fi
CONFIGURATION=release BUILD_ARCHITECTURES='arm64 x86_64' Scripts/build.sh
Scripts/archive.sh
version="$(python3 Scripts/version.py current)"
xcrun notarytool submit "dist/Sidetone-$version-macos-universal.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Sidetone.app
xcrun stapler validate dist/Sidetone.app
spctl --assess --type execute --verbose dist/Sidetone.app
Scripts/archive.sh
