#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang++ -std=c++20 -O3 -Wall -Wextra -Werror -pthread -ISources/AudioCore Sources/AudioCore/DSP.cpp Tests/AudioCoreTests/DSPBenchmark.cpp -o build/tests/dsp-benchmark
build/tests/dsp-benchmark
