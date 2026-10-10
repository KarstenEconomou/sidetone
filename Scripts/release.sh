#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(git branch --show-current)" != main ]]; then
    printf 'Run this command from main.\n' >&2
    exit 1
fi
git diff --exit-code --quiet
git diff --cached --exit-code --quiet
git fetch origin --tags
git merge --ff-only origin/main
version="$(python3 Scripts/version.py next)"
if [[ "$version" == "$(python3 Scripts/version.py current)" ]]; then
    printf 'Version %s is ready. Run: gh workflow run release.yml -f version=%s\n' "$version" "$version"
    exit 0
fi
git switch -c "release/$version"
printf '%s\n' "$version" > VERSION
git add VERSION
git commit -m "chore(release): prepare v$version"
git push -u origin "release/$version"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
printf 'Set the app version to %s. CI checks the version, tests, and app build.\n' "$version" > "$body"
gh pr create --base main --title "chore(release): prepare v$version" --body-file "$body" --label release
