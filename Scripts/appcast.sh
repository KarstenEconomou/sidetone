#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(python3 Scripts/version.py current)"
archive="Sidetone-$version-macos-universal.zip"
tools_path="$PWD/.build/artifacts/sparkle/Sparkle/bin"
mkdir -p build
staging="$(mktemp -d "$PWD/build/.appcast.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp "dist/$archive" "$staging/"
if [[ $# -gt 0 ]]; then
    cp "$1" "$staging/${archive%.zip}.md"
fi
signing_options=(--account com.sidetone.app)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    signing_options=(--ed-key-file -)
fi
generate() {
    "$tools_path/generate_appcast" "${signing_options[@]}" \
        --download-url-prefix "https://github.com/KarstenEconomou/sidetone/releases/download/v$version/" \
        --link "https://github.com/KarstenEconomou/sidetone/releases/tag/v$version" \
        --maximum-deltas 0 --embed-release-notes "$staging"
}
verify() {
    "$tools_path/sign_update" "${signing_options[@]}" --verify "$staging/appcast.xml"
}
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | generate
    printf '%s' "$SPARKLE_PRIVATE_KEY" | verify
else
    generate
    verify
fi
python3 Scripts/validate-appcast.py "$staging/appcast.xml" "dist/$archive" \
    dist/Sidetone.app/Contents/Info.plist
cp "$staging/appcast.xml" dist/appcast.xml
printf 'Signed update feed: %s/dist/appcast.xml\n' "$PWD"
