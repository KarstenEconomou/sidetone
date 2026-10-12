#include "NoiseSuppressor.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <numbers>
#include <thread>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

void process(sidetone::NoiseSuppressor& processor, std::vector<float>& samples,
             std::size_t block = 64) {
    for (std::size_t index = 0; index < samples.size(); index += block)
        processor.process({samples.data() + index, std::min(block, samples.size() - index)});
}

std::vector<float> noise(std::size_t count) {
    std::vector<float> samples(count);
    std::uint32_t random = 123;
    for (float& sample : samples) {
        random = random * 1664525U + 1013904223U;
        sample = 0.04f * (static_cast<float>(random) / static_cast<float>(UINT32_MAX) - 0.5f);
    }
    return samples;
}

double energy(const std::vector<float>& samples, std::size_t start) {
    double sum = 0;
    for (std::size_t index = start; index < samples.size(); ++index) {
        require(std::isfinite(samples[index]), "Suppression output must be finite.");
        sum += samples[index] * samples[index];
    }
    return sum;
}

void testBypass() {
    sidetone::NoiseSuppressor processor;
    processor.prepare(44100);
    auto samples = noise(10003);
    const auto original = samples;
    process(processor, samples, 127);
    require(samples == original, "Off must preserve samples without a delay.");
    require(processor.latencyMs() == 0, "Off must report zero suppression latency.");
}

void testNoiseAndStrength() {
    const auto original = noise(48000 * 3);
    double previous = energy(original, 48000);
    for (float strength : {0.0f, 0.5f, 0.85f, 1.0f}) {
        sidetone::NoiseSuppressor processor;
        processor.setParameters(true, strength);
        processor.prepare(48000);
        auto samples = original;
        process(processor, samples, 127);
        const double current = energy(samples, 48000);
        if (strength > 0)
            require(current < previous * 0.5, "More strength must reduce steady noise.");
        previous = current;
        if (strength == 1) {
            const double reduction = 10 * std::log10(energy(original, 48000) / current);
            std::cout << "Steady noise reduction: " << reduction << " dB\n";
            require(reduction > 10, "The neural model must suppress steady noise.");
        }
    }
}

void testDelayAndRates() {
    for (double rate : {8000, 16000, 44100, 48000, 88200, 96000, 192000, 768000}) {
        sidetone::NoiseSuppressor processor;
        processor.setParameters(true, 0);
        processor.prepare(rate);
        const auto onset = static_cast<std::size_t>(rate * 0.060);
        std::vector<float> samples(static_cast<std::size_t>(rate * 0.15));
        samples[onset] = 0.1f;
        process(processor, samples, 113);
        auto peak = std::max_element(samples.begin(), samples.end(),
                                     [](float a, float b) { return std::abs(a) < std::abs(b); });
        const double measured = (std::distance(samples.begin(), peak) - onset) * 1000.0 / rate;
        require(std::abs(measured - processor.latencyMs()) <= 1000.0 / rate + 0.001,
                "Impulse delay must match the latency report at each sample rate.");
        require(std::abs(*peak) > 0.003, "Rate conversion must preserve the signal.");
        require(energy(samples, 0) > 0, "Rate conversion must produce finite audio.");
        if (rate == 48000) {
            require(processor.latencyMs() == 30, "The native suppression delay must be 30 ms.");
            require(*peak == 0.1f, "Zero strength must preserve the delayed signal.");
        }
    }
}

void testPartitionAndReset() {
    for (double rate : {44100, 48000, 96000}) {
        const auto original = noise(static_cast<std::size_t>(rate * 0.4));
        sidetone::NoiseSuppressor first, second;
        first.setParameters(true, 0.85f);
        second.setParameters(true, 0.85f);
        first.prepare(rate);
        second.prepare(rate);
        auto a = original, b = original;
        process(first, a, 1);
        process(second, b, 511);
        require(a == b, "Audio must not depend on callback size.");
        first.prepare(rate);
        auto restarted = original;
        process(first, restarted, 64);
        require(a == restarted, "Restart must clear all model and conversion state.");
    }
}

void testRateConversionSpectrum() {
    for (double rate : {16000, 44100, 96000, 192000}) {
        for (double frequency : {1000, 30000}) {
            if (frequency >= rate / 2)
                continue;
            sidetone::NoiseSuppressor processor;
            processor.setParameters(true, 0);
            processor.prepare(rate);
            std::vector<float> samples(static_cast<std::size_t>(rate * 0.5));
            for (std::size_t index = 0; index < samples.size(); ++index)
                samples[index] = static_cast<float>(
                    0.1 * std::sin(2 * std::numbers::pi * frequency * index / rate));
            process(processor, samples, 37);
            const double rms = std::sqrt(energy(samples, samples.size() / 2) /
                                         (samples.size() - samples.size() / 2));
            if (frequency == 1000)
                require(std::abs(rms - 0.0707107) < 0.001,
                        "Rate conversion must preserve the speech band without gaps.");
            else
                require(rms < 0.0001, "Downsampling must reject frequencies above 24 kHz.");
        }
    }
}

void testTransitionsAndInvalidInput() {
    sidetone::NoiseSuppressor processor;
    processor.prepare(48000);
    float previous = 0.1f;
    for (bool enabled : {true, false, true, false}) {
        processor.setParameters(enabled, 0);
        for (int index = 0; index < 6000; ++index) {
            float sample = 0.1f;
            processor.process({&sample, 1});
            require(std::abs(sample - previous) < 0.002f,
                    "Mode changes must fade through silence without a step.");
            previous = sample;
        }
        require(processor.latencyMs() == (enabled ? 30 : 0),
                "Latency must follow the active mode.");
    }
    processor.setParameters(true, std::numeric_limits<float>::quiet_NaN());
    auto samples = noise(96000);
    samples[3000] = std::numeric_limits<float>::infinity();
    samples[5000] = std::numeric_limits<float>::quiet_NaN();
    process(processor, samples);
    require(energy(samples, 0) >= 0, "Invalid input must not poison recurrent state.");
    processor.setParameters(false, 1);
    std::vector<float> bypass(6000, 0.1f);
    process(processor, bypass);
    require(bypass.back() == 0.1f, "Disabling must restore the immediate signal.");
}

void testConcurrentControls() {
    sidetone::NoiseSuppressor processor;
    processor.prepare(48000);
    std::thread control([&] {
        for (int index = 0; index < 100000; ++index) {
            processor.setParameters(index % 3 != 0, static_cast<float>(index % 101) / 100);
            require(std::isfinite(processor.latencyMs()), "Concurrent telemetry must be finite.");
        }
    });
    auto samples = noise(48000);
    process(processor, samples, 32);
    control.join();
    require(energy(samples, 0) >= 0, "Concurrent controls must preserve finite output.");
}
} // namespace

int main() {
    testBypass();
    testNoiseAndStrength();
    testDelayAndRates();
    testPartitionAndReset();
    testRateConversionSpectrum();
    testTransitionsAndInvalidInput();
    testConcurrentControls();
    std::cout << "PASS: Noise suppression, strength, delay, rates, transitions, and reset.\n";
}
