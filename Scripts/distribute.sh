#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile.}"
if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    printf 'Use a Developer ID Application identity.\n' >&2
    exit 1
fi
Scripts/build.sh
/usr/bin/ditto -c -k --keepParent dist/Sidetone.app dist/Sidetone.zip
xcrun notarytool submit dist/Sidetone.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Sidetone.app
xcrun stapler validate dist/Sidetone.app
spctl --assess --type execute --verbose dist/Sidetone.app
/usr/bin/ditto -c -k --keepParent dist/Sidetone.app dist/Sidetone.zip
printf 'Distribution file: %s/dist/Sidetone.zip\n' "$PWD"
