#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang++ -std=c++20 -O2 -Wall -Wextra -Werror -pthread -ISources/AudioCore \
    Sources/AudioCore/DSP.cpp Sources/AudioCore/AudioCore.cpp Tests/AggregateProbe.cpp \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
    -Wl,-sectcreate,__TEXT,__info_plist,Resources/Info.plist -o build/tests/aggregate-probe
exec build/tests/aggregate-probe "$@"
