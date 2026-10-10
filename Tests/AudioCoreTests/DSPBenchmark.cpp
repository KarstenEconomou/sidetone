#include "DSP.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <iostream>
#include <vector>

int main() {
    constexpr std::uint32_t frames = 128;
    constexpr int iterations = 20000;
    std::array<float, frames> samples{};
    std::vector<double> times;
    times.reserve(iterations);
    double checksum = 0;
    for (std::uint32_t profile = 0; profile < 3; ++profile) {
        sidetone::DSP dsp;
        dsp.prepare(48000);
        dsp.setParameters({-6, profile, 75, 2000, 2, 0.7f, 1});
        times.clear();
        for (int pass = 0; pass < iterations; ++pass) {
            for (std::uint32_t index = 0; index < frames; ++index)
                samples[index] =
                    0.1f * std::sin(static_cast<float>(pass * frames + index) * 0.137f);
            const auto start = std::chrono::steady_clock::now();
            dsp.process(samples);
            const auto stop = std::chrono::steady_clock::now();
            times.push_back(std::chrono::duration<double, std::micro>(stop - start).count());
            checksum += samples[0];
        }
        double sum = 0;
        for (double time : times)
            sum += time;
        std::sort(times.begin(), times.end());
        std::cout << "Profile " << profile << ": 128 frames at 48000 Hz; mean " << sum / iterations
                  << " us; p99 " << times[iterations * 99 / 100] << " us; max " << times.back()
                  << " us\n";
    }
    sidetone::AdaptiveTransport transport;
    transport.prepare(96000, 48000, frames * 2, frames);
    std::array<float, frames * 2> input{};
    for (std::size_t index = 0; index < input.size(); ++index)
        input[index] = 0.1f * std::sin(static_cast<float>(index) * 0.073f);
    times.clear();
    for (int pass = 0; pass < iterations; ++pass) {
        transport.push(input);
        const auto start = std::chrono::steady_clock::now();
        transport.render(samples);
        const auto stop = std::chrono::steady_clock::now();
        times.push_back(std::chrono::duration<double, std::micro>(stop - start).count());
        checksum += samples[0];
    }
    double sum = 0;
    for (double time : times)
        sum += time;
    std::sort(times.begin(), times.end());
    std::cout << "Transport 96000 -> 48000 Hz: 128 output frames; mean " << sum / iterations
              << " us; p99 " << times[iterations * 99 / 100] << " us; max " << times.back()
              << " us\n";
    std::cout << "Checksum: " << checksum << '\n';
}
