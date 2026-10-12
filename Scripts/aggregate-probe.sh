#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
source Scripts/lib/rnnoise.sh
build_rnnoise build/tests/rnnoise
xcrun clang++ -std=c++20 -O2 -Wall -Wextra -Werror -pthread -ISources/AudioCore -IThirdParty/RNNoise/include \
    Sources/AudioCore/DSP.cpp Sources/AudioCore/AudioCore.cpp Tests/AggregateProbe.cpp \
    Sources/AudioCore/NoiseSuppressor.cpp build/tests/rnnoise/librnnoise.a \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
    -Wl,-sectcreate,__TEXT,__info_plist,Resources/Info.plist -o build/tests/aggregate-probe
exec build/tests/aggregate-probe "$@"
