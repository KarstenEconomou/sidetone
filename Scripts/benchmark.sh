#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
source Scripts/lib/rnnoise.sh
build_rnnoise build/tests/rnnoise
xcrun clang++ -std=c++20 -O3 -Wall -Wextra -Werror -ISources/AudioCore -IThirdParty/RNNoise/include Sources/AudioCore/NoiseSuppressor.cpp Tests/AudioCoreTests/NoiseSuppressorBenchmark.cpp build/tests/rnnoise/librnnoise.a -o build/tests/noise-benchmark
build/tests/noise-benchmark
xcrun clang++ -std=c++20 -O3 -Wall -Wextra -Werror -pthread -ISources/AudioCore Sources/AudioCore/DSP.cpp Tests/AudioCoreTests/DSPBenchmark.cpp -o build/tests/dsp-benchmark
build/tests/dsp-benchmark
xcrun clang++ -std=c++20 -O3 -Wall -Wextra -Werror -pthread -ISources/AudioCore Sources/AudioCore/KeyboardMixer.cpp Tests/AudioCoreTests/KeyboardBenchmark.cpp -o build/tests/keyboard-benchmark
build/tests/keyboard-benchmark
