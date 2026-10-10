#include "DSP.hpp"
#include <array>
#include <cmath>
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
void testGain() {
    sidetone::DSP dsp;
    dsp.prepare(48000);
    dsp.setParameters({-6, 0, 75, 1500, 0, 0.7f, 0});
    float previous = 0;
    float sample = 0;
    for (int index = 0; index < 4800; ++index) {
        sample = dsp.process(0.25f);
        require(sample >= previous && sample - previous < 0.001f, "gain starts with a smooth ramp");
        previous = sample;
    }
    require(std::abs(sample - 0.25f * std::pow(10.0f, -6.0f / 20.0f)) < 0.00001f,
            "gain matches decibels");
    dsp.setParameters({6, 0, 75, 1500, 0, 0.7f, 0});
    for (int index = 0; index < 4800; ++index)
        require(std::abs(dsp.process(2)) <= 0.95f, "output has a safe ceiling");
    require(dsp.clippedSamples() > 0, "clipping is counted");
    require(std::isfinite(dsp.process(std::numeric_limits<float>::quiet_NaN())),
            "NaN input is safe");
    require(std::isfinite(dsp.process(std::numeric_limits<float>::infinity())),
            "infinite input is safe");
}
void testRing() {
    sidetone::SPSCRing<8> ring;
    float sample = 0;
    require(!ring.pop(sample), "empty ring does not read");
    for (int cycle = 0; cycle < 1000; ++cycle) {
        for (int index = 0; index < 8; ++index)
            require(ring.push(static_cast<float>(cycle * 8 + index)),
                    "ring accepts its full capacity");
        require(!ring.push(0), "full ring does not overwrite");
        for (int index = 0; index < 8; ++index) {
            require(ring.pop(sample), "ring reads stored samples");
            require(sample == static_cast<float>(cycle * 8 + index),
                    "ring preserves order across wraparound");
        }
        require(!ring.pop(sample), "ring is empty after reads");
    }
}
void testRingConcurrency() {
    sidetone::SPSCRing<1024> ring;
    constexpr int count = 1000000;
    std::thread producer([&] {
        for (int index = 0; index < count; ++index) {
            while (!ring.push(static_cast<float>(index)))
                std::this_thread::yield();
        }
    });
    for (int index = 0; index < count; ++index) {
        float sample = 0;
        while (!ring.pop(sample))
            std::this_thread::yield();
        require(sample == static_cast<float>(index), "concurrent ring preserves every sample");
    }
    producer.join();
}
void testTransportSafety() {
    sidetone::AdaptiveTransport transport;
    transport.prepare(48000, 48000, 64, 64);
    std::array<float, 64> samples{};
    transport.render(samples);
    for (float sample : samples)
        require(sample == 0, "empty transport is silent");
    samples.fill(0.25f);
    for (int index = 0; index < 2200; ++index)
        transport.push(samples);
    require(transport.overruns() > 0, "transport counts full input queue");
    for (int index = 0; index < 600; ++index) {
        transport.render(samples);
        for (float sample : samples)
            require(std::isfinite(sample) && std::abs(sample) <= 0.3f,
                    "transport output stays finite and bounded");
    }
    require(transport.underruns() > 0, "transport counts input starvation");
}
double response(STParameters parameters, double frequency, double amplitude = 0.03,
                double rate = 48000) {
    sidetone::DSP dsp;
    dsp.prepare(rate);
    dsp.setParameters(parameters);
    double energy = 0;
    const int frames = static_cast<int>(rate);
    for (int index = 0; index < frames; ++index) {
        const double input =
            amplitude * std::sin(2.0 * std::numbers::pi * frequency * index / rate);
        const double output = dsp.process(static_cast<float>(input));
        if (index >= frames / 2)
            energy += output * output;
    }
    return std::sqrt(energy / (frames - frames / 2));
}
void testProfiles() {
    const double direct = response({0, 0, 75, 1500, 0, 0.7f, 0}, 20);
    const double natural = response({0, 1, 75, 1500, 0, 0.7f, 0}, 20);
    const double voice = response({0, 2, 75, 1500, 0, 0.7f, 0}, 20);
    require(natural < direct * 0.1, "Natural removes low frequency rumble");
    require(voice < natural * 0.7, "Voice has stronger low frequency shaping");
    const double flat = response({0, 1, 75, 1500, 0, 0.7f, 0}, 1500);
    const double boost = response({0, 1, 75, 1500, 6, 0.7f, 0}, 1500);
    require(std::abs(20.0 * std::log10(boost / flat) - 6) < 0.15,
            "parametric EQ reaches its selected gain");
    const double dry = response({0, 1, 75, 1500, 0, 0.7f, 0}, 1000, 0.5);
    const double compressed = response({0, 1, 75, 1500, 0, 0.7f, 1}, 1000, 0.5);
    require(compressed < dry * 0.9 && compressed > dry * 0.2,
            "optional compression reduces strong signals");
    const double directCompressed = response({0, 0, 75, 1500, 12, 0.7f, 1}, 1000, 0.5);
    const double directDry = response({0, 0, 75, 1500, 0, 0.7f, 0}, 1000, 0.5);
    require(std::abs(directDry - directCompressed) < 1.0e-6, "Direct has no EQ or compression");
}
void testEQRateChanges() {
    sidetone::DSP dsp;
    dsp.prepare(8000);
    dsp.setParameters({0, 1, 75, 10000, 6, 2.0f, 0});
    for (const double rate : {48000.0, 8000.0, 96000.0}) {
        dsp.prepare(rate);
        const double frequency = std::min(10000.0, rate * 0.45);
        double inputEnergy = 0, outputEnergy = 0;
        for (int index = 0; index < static_cast<int>(rate); ++index) {
            const float input = static_cast<float>(
                0.03 * std::sin(2.0 * std::numbers::pi * frequency * index / rate));
            const float output = dsp.process(input);
            if (index >= static_cast<int>(rate / 2)) {
                inputEnergy += input * input;
                outputEnergy += output * output;
            }
        }
        require(std::abs(10.0 * std::log10(outputEnergy / inputEnergy) - 6) < 0.15,
                "EQ keeps its selected frequency across sample-rate changes");
    }
}
void testEQWidth() {
    for (uint32_t profile : {1U, 2U}) {
        double previous = response({0, profile, 75, 1500, 6, 4, 0}, 1800);
        for (float q : {4.1f, 4.5f, 5.0f}) {
            const double narrower = response({0, profile, 75, 1500, 6, q, 0}, 1800);
            require(narrower < previous - 0.000001,
                    "EQ width increases through Q 5 in Natural and Voice");
            previous = narrower;
        }
        const double aboveLimit = response({0, profile, 75, 1500, 6, 6, 0}, 1800);
        require(std::abs(aboveLimit - previous) < 0.000001, "EQ width is bounded at Q 5");
    }
}
void testProfileTransitions() {
    sidetone::DSP dsp;
    dsp.prepare(48000);
    dsp.setParameters({0, 0, 75, 1500, 0, 0.7f, 0});
    float previous = 0;
    for (int index = 0; index < 4800; ++index)
        previous = dsp.process(0.1f);
    dsp.setParameters({0, 1, 75, 1500, 0, 0.7f, 0});
    for (int index = 0; index < 10000; ++index) {
        const float output = dsp.process(0.1f);
        require(std::abs(output - previous) < 0.001f, "profile changes have no step");
        previous = output;
    }
    require(std::abs(previous) < 0.0001f, "Natural removes DC after a profile change");
    std::uint32_t random = 17;
    for (int index = 0; index < 200000; ++index) {
        random = random * 1664525U + 1013904223U;
        if (index % 127 == 0) {
            dsp.setParameters({6, random % 3, (random & 1) ? 300.0f : 20.0f,
                               (random & 2) ? 15000.0f : 80.0f, (random & 4) ? 12.0f : -12.0f,
                               (random & 8) ? 5.0f : 0.2f, random % 2});
        }
        const float input =
            static_cast<float>(random) / static_cast<float>(UINT32_MAX) * 8.0f - 4.0f;
        const float output = dsp.process(input);
        require(std::isfinite(output) && std::abs(output) <= 0.95f,
                "profile and EQ updates stay stable");
    }
}
void testParameterConcurrency() {
    sidetone::DSP dsp;
    dsp.prepare(48000);
    std::thread control([&] {
        for (std::uint32_t index = 0; index < 100000; ++index)
            dsp.setParameters({static_cast<float>(index % 67) - 60, index % 3,
                               20.0f + static_cast<float>(index % 280),
                               80.0f + static_cast<float>(index % 15000),
                               static_cast<float>(index % 25) - 12, 0.7f, index % 2});
    });
    for (int index = 0; index < 1000000; ++index) {
        const float output = dsp.process(std::sin(static_cast<float>(index) * 0.1f));
        require(std::isfinite(output) && std::abs(output) <= 0.95f,
                "control updates are safe during processing");
    }
    control.join();
}
struct SimulationResult {
    std::uint64_t underruns{0}, overruns{0};
    double rms{0}, frequency{0}, drift{0}, maxQueueMs{0};
};
SimulationResult simulate(double inputRate, double outputRate, std::uint32_t inputFrames,
                          std::uint32_t outputFrames, double driftPPM, double seconds,
                          double frequency = 1000, bool jitter = false) {
    sidetone::AdaptiveTransport transport;
    require(sidetone::AdaptiveTransport::supportsConfiguration(inputRate, outputRate, inputFrames,
                                                               outputFrames),
            "test route is supported");
    transport.prepare(inputRate, outputRate, inputFrames, outputFrames);
    std::vector<float> input(inputFrames), output(outputFrames);
    const double actualInputRate = inputRate * (1.0 + driftPPM / 1.0e6);
    std::uint64_t inputBlock = 0, outputBlock = 0, measuredFrames = 0, crossings = 0,
                  measuredBlocks = 0;
    double nextInput = 0, nextOutput = static_cast<double>(outputFrames) / outputRate * 0.37;
    double energy = 0, driftSum = 0, maxQueue = 0;
    float previous = 0;
    while (nextOutput < seconds) {
        if (nextInput <= nextOutput) {
            for (std::uint32_t index = 0; index < inputFrames; ++index)
                input[index] = static_cast<float>(
                    0.1 * std::sin(2.0 * std::numbers::pi * frequency *
                                   static_cast<double>(inputBlock * inputFrames + index) /
                                   actualInputRate));
            transport.push(input);
            ++inputBlock;
            nextInput = static_cast<double>(inputBlock * inputFrames) / actualInputRate;
            if (jitter)
                nextInput += 0.0001 * std::sin(static_cast<double>(inputBlock) * 0.31);
        } else {
            transport.render(output);
            if (nextOutput > seconds * 0.5) {
                for (float sample : output) {
                    require(std::isfinite(sample), "resampled output stays finite");
                    energy += sample * sample;
                    if (sample > 0 && previous <= 0)
                        ++crossings;
                    previous = sample;
                    ++measuredFrames;
                }
                maxQueue = std::max(maxQueue, transport.queueLatencyMs());
                driftSum += transport.driftPPM();
                ++measuredBlocks;
            }
            ++outputBlock;
            nextOutput = (static_cast<double>(outputBlock) + 0.37) * outputFrames / outputRate;
            if (jitter)
                nextOutput += 0.00007 * std::sin(static_cast<double>(outputBlock) * 0.23);
        }
    }
    return {transport.underruns(),
            transport.overruns(),
            std::sqrt(energy / static_cast<double>(measuredFrames)),
            static_cast<double>(crossings) * outputRate / static_cast<double>(measuredFrames),
            driftSum / static_cast<double>(measuredBlocks),
            maxQueue};
}
void testResampling() {
    for (const auto rates :
         {std::array<double, 2>{44100, 48000}, {48000, 44100}, {96000, 48000}, {192000, 44100}}) {
        const auto result = simulate(rates[0], rates[1], 128, 64, 0, 3);
        std::cout << "Rate " << rates[0] << " -> " << rates[1] << ": underruns " << result.underruns
                  << ", overruns " << result.overruns << ", RMS " << result.rms << ", Hz "
                  << result.frequency << '\n';
        require(result.underruns == 0 && result.overruns == 0, "rate mismatch has no lost blocks");
        require(std::abs(result.rms - 0.1 / std::sqrt(2.0)) < 0.001,
                "resampling preserves speech amplitude");
        require(std::abs(result.frequency - 1000) < 2, "resampling preserves frequency");
    }
    const auto alias = simulate(96000, 48000, 128, 64, 0, 3, 30000);
    require(alias.rms < 0.0003, "downsampling removes frequencies above output Nyquist");
    const auto highRateAlias = simulate(192000, 44100, 256, 64, 0, 3, 30000);
    require(highRateAlias.rms < 0.0003, "high rate downsampling prevents aliasing");
    const auto extremeRate = simulate(768000, 8000, 4096, 64, 0, 1);
    require(std::abs(extremeRate.rms - 0.1 / std::sqrt(2.0)) < 0.001,
            "large rate ratios preserve speech amplitude");
    const auto extremeAlias = simulate(768000, 8000, 4096, 64, 0, 1, 6000);
    require(extremeAlias.rms < 0.0003, "large rate ratios prevent aliasing");
}
void testDrift() {
    for (const double drift : {-1000.0, -100.0, 100.0, 1000.0}) {
        const auto result = simulate(48000, 48000, 64, 64, drift, 90, 1000, true);
        std::cout << "Drift " << drift << " ppm: correction " << result.drift
                  << " ppm, queue <= " << result.maxQueueMs << " ms, underruns " << result.underruns
                  << ", overruns " << result.overruns << '\n';
        require(result.underruns == 0 && result.overruns == 0,
                "independent clocks stay continuous");
        require(result.maxQueueMs < 6, "clock compensation keeps latency bounded");
        require(std::abs(result.drift - drift) < 35, "clock controller follows input drift");
        require(std::abs(result.frequency - 1000) < 0.5, "clock compensation preserves pitch");
    }
    const auto result = simulate(44100, 48000, 128, 64, 300, 90, 1000, true);
    require(result.underruns == 0 && result.overruns == 0,
            "mismatched rates and clocks stay continuous");
    require(std::abs(result.drift - 300) < 50, "mismatched-rate controller follows drift");
}
void testStartupAndRecovery() {
    sidetone::AdaptiveTransport transport;
    transport.prepare(48000, 48000, 64, 64);
    std::array<float, 64> samples{};
    samples.fill(0.1f);
    for (int block = 0; block < 60; ++block)
        transport.push(samples);
    transport.render(samples);
    require(transport.queueLatencyMs() < 4, "startup removes stale capture audio");
    require(transport.overruns() == 0, "startup discard is not an active overrun");
    for (int block = 0; block < 100; ++block) {
        samples.fill(0.1f);
        transport.push(samples);
        transport.render(samples);
    }
    float previous = samples.back();
    for (int block = 0; block < 20; ++block) {
        transport.render(samples);
        for (float sample : samples) {
            require(std::abs(sample - previous) < 0.002f, "an input outage fades without a step");
            previous = sample;
        }
    }
    require(transport.underruns() == 1, "one input outage counts once");
    for (int block = 0; block < 100; ++block) {
        samples.fill(0.1f);
        transport.push(samples);
        transport.render(samples);
    }
    require(std::abs(samples.back() - 0.1f) < 0.001f, "transport recovers from an input outage");
}
void testTransportCapacity() {
    sidetone::AdaptiveTransport transport;
    require(transport.supportsConfiguration(352800, 48000, 64, 16384),
            "a large output block fits the transport");
    require(!transport.supportsConfiguration(768000, 8000, 64, 16384),
            "a block larger than transport capacity is rejected");
    transport.prepare(352800, 48000, 64, 16384);
    std::array<float, 64> input{};
    input.fill(0.1f);
    std::array<float, 16384> output{};
    for (int block = 0; block < 2048; ++block)
        transport.push(input);
    transport.render(output);
    require(transport.underruns() == 0 && transport.overruns() == 0,
            "an accepted large output block renders without lost samples");
    require(std::abs(output.back() - 0.1f) < 0.001f,
            "the full accepted output block contains audio");
}
} // namespace

int main() {
    testGain();
    testRing();
    testRingConcurrency();
    testTransportSafety();
    testProfiles();
    testEQRateChanges();
    testEQWidth();
    testProfileTransitions();
    testParameterConcurrency();
    testResampling();
    testDrift();
    testStartupAndRecovery();
    testTransportCapacity();
    std::cout << "DSP, ring, and transport tests passed.\n";
}
