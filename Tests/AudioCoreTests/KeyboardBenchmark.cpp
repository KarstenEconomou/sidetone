#include "KeyboardMixer.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <iostream>
#include <vector>

int main() {
    constexpr uint32_t passes = 12000;
    double checksum = 0;
    for (const double rate : {44100.0, 48000.0, 96000.0, 192000.0}) {
        std::vector<float> recording(size_t(rate) * 2, 0.001f);
        for (const uint32_t frames : {32, 128, 512}) {
            for (const uint32_t voices : {0, 1, 8, 64}) {
                sidetone::KeyboardMixer mixer;
                mixer.load(0, recording.data(), uint32_t(rate), rate);
                mixer.reset(rate);
                std::array<float, 512> left{}, right{};
                std::vector<double> times;
                times.reserve(passes);
                const auto batch = uint32_t(rate / (frames * 2));
                for (uint32_t pass = 0; pass < passes + 1000; ++pass) {
                    if (pass % batch == 0) {
                        mixer.reset(rate);
                        for (uint32_t voice = 0; voice < voices; ++voice)
                            mixer.enqueue(0);
                    }
                    const auto start = std::chrono::steady_clock::now();
                    mixer.render(left.data(), right.data(), frames);
                    const auto elapsed = std::chrono::duration<double, std::micro>(
                        std::chrono::steady_clock::now() - start).count();
                    if (pass >= 1000)
                        times.push_back(elapsed);
                    checksum += left[0];
                }
                double sum = 0;
                for (const double time : times)
                    sum += time;
                std::sort(times.begin(), times.end());
                const double p99 = times[passes * 99 / 100];
                std::cout << rate << " Hz, " << frames << " frames, " << voices
                          << " voices: mean " << sum / passes << " us, p99 " << p99
                          << " us, max " << times.back() << " us, p99 budget "
                          << 100 * p99 / (frames / rate * 1000000) << "%\n";
            }
        }
    }
    std::cout << "Checksum: " << checksum << '\n';
}
