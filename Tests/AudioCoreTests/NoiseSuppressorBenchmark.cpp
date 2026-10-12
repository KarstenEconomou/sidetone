#include "NoiseSuppressor.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <vector>

int main() {
    double checksum = 0;
    for (double rate : {44100, 48000, 96000}) {
        for (std::size_t block : {32, 64, 128, 512}) {
            sidetone::NoiseSuppressor processor;
            processor.setParameters(true, 0.85f);
            processor.prepare(rate);
            std::vector<float> samples(block);
            std::vector<double> times;
            const auto iterations = static_cast<std::size_t>(rate * 10 / block);
            times.reserve(iterations);
            std::uint32_t random = 123;
            for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
                for (float& sample : samples) {
                    random = random * 1664525U + 1013904223U;
                    sample = 0.04f * (static_cast<float>(random) / static_cast<float>(UINT32_MAX) - 0.5f);
                }
                const auto start = std::chrono::steady_clock::now();
                processor.process(samples);
                const auto stop = std::chrono::steady_clock::now();
                times.push_back(std::chrono::duration<double, std::micro>(stop - start).count());
                checksum += samples[0];
            }
            std::sort(times.begin(), times.end());
            std::cout << "RNNoise rate=" << rate << " frames=" << block
                      << " mean_us=" << std::accumulate(times.begin(), times.end(), 0.0) / times.size()
                      << " p99_us=" << times[times.size() * 99 / 100]
                      << " max_us=" << times.back() << " budget_us=" << block * 1e6 / rate
                      << " delay_ms=" << processor.latencyMs() << '\n';
        }
    }
    return std::isfinite(checksum) ? 0 : 1;
}
