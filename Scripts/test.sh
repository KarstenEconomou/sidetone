#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/audio-tests.sh
test_flags=(--disable-xctest)
developer_path="$(xcode-select -p)"
framework_path="$developer_path/Library/Developer/Frameworks"
if [[ -d "$framework_path/Testing.framework" ]]; then
    test_flags+=(-Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0")
    test_flags+=(-Xswiftc -F -Xswiftc "$framework_path")
    test_flags+=(-Xlinker -rpath -Xlinker "$framework_path")
    test_flags+=(-Xlinker -rpath -Xlinker "$developer_path/Library/Developer/usr/lib")
fi
swift test "${test_flags[@]}"
