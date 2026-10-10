#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
flags=(-std=c++20 -O2 -g -Wall -Wextra -Werror -pthread -ISources/AudioCore)
if [[ "${SANITIZER:-}" != "" ]]; then
    flags+=(-fsanitize="$SANITIZER" -fno-omit-frame-pointer)
fi
xcrun clang++ "${flags[@]}" Sources/AudioCore/DSP.cpp Tests/AudioCoreTests/DSPTests.cpp -o build/tests/dsp-tests
build/tests/dsp-tests
xcrun clang++ "${flags[@]}" Sources/AudioCore/DSP.cpp Sources/AudioCore/AudioCore.cpp Tests/AudioIntegrationTests.cpp -framework CoreAudio -framework AudioToolbox -framework CoreFoundation -o build/tests/audio-tests
build/tests/audio-tests
