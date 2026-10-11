#include "KeyboardMixer.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

namespace {
void require(bool value, const char* message) {
    if (!value) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}
void testPlayback() {
    sidetone::KeyboardMixer mixer;
    const std::array<float, 8> recording{0.2f, -0.1f, 0.4f, -0.2f, 0.2f, -0.1f, 0, 0};
    require(mixer.load(0, recording.data(), 4, 48000), "load stereo recording");
    mixer.setGain(0);
    mixer.reset(48000);
    std::array<float, 16> left{}, right{};
    mixer.render(left.data(), right.data(), 16);
    require(left[0] == 0 && right[0] == 0, "idle output is silent");
    require(mixer.enqueue(0), "queue a key");
    mixer.render(left.data(), right.data(), 16);
    require(left[0] == 0.2f && right[0] == -0.1f, "preserve stereo recording");
    require(left[1] == 0.4f && left[4] == 0, "play each frame and stop at the end");
    require(mixer.enqueue(0) && mixer.enqueue(0), "queue overlapping keys");
    mixer.render(left.data(), right.data(), 16);
    require(left[0] == 0.4f && right[0] == -0.2f, "mix overlapping keys");
    mixer.setGain(-6);
    mixer.reset(96000);
    mixer.enqueue(0);
    mixer.render(left.data(), right.data(), 16);
    require(std::abs(left[1] - 0.3f * std::pow(10.0f, -6.0f / 20.0f)) < 0.0001f,
            "resample to the output rate and apply volume");
    mixer.enqueue(0);
    mixer.reset(44100);
    mixer.render(left.data(), right.data(), 16);
    require(std::all_of(left.begin(), left.end(), [](float sample) { return sample == 0; }),
            "reset removes queued and active sounds");
}

void testBounds() {
    sidetone::KeyboardMixer mixer;
    const std::array<float, 8> recording{0.8f, 0.8f, 0.8f, 0.8f, 0.8f, 0.8f, 0, 0};
    require(!mixer.load(256, recording.data(), 4, 48000), "reject invalid sample index");
    require(!mixer.load(0, nullptr, 4, 48000), "reject missing sample data");
    const std::array<float, 4> corrupt{0, 0, std::numeric_limits<float>::max(), 0};
    require(!mixer.load(0, corrupt.data(), 2, 48000), "reject sample values that can overflow a mix");
    require(mixer.load(0, recording.data(), 4, 48000), "load recording");
    require(!mixer.enqueue(1), "reject unloaded samples");
    mixer.setGain(0);
    mixer.reset(48000);
    for (int index = 0; index < 256; ++index)
        require(mixer.enqueue(0), "accept queue capacity");
    require(!mixer.enqueue(0), "bound the queue");
    std::array<float, 32> left{}, right{};
    mixer.render(left.data(), right.data(), 32);
    require(left[0] > 0.9f, "render the queued chord");
    const auto stats = mixer.statistics();
    require(stats.enqueued == 256 && stats.queueDrops == 1, "count queue saturation");
    require(stats.peakVoices == 64 && stats.voiceDrops == 192, "bound and count active voices");
    require(stats.clippedFrames > 0, "count protected frames");
    for (float value : left)
        require(std::isfinite(value) && std::abs(value) <= 0.98f, "limit overlapping recordings");
    require(mixer.enqueue(0), "accept events after the queue drains");
    mixer.setGain(std::numeric_limits<float>::quiet_NaN());
    mixer.render(left.data(), right.data(), 32);
    for (float value : left)
        require(std::isfinite(value), "invalid volume cannot reach output");
}

void testRecordedOnset() {
    sidetone::KeyboardMixer mixer;
    std::array<float, 1000> recording{};
    recording[800] = recording[801] = 0.5f;
    require(mixer.load(0, recording.data(), 500, 48000), "load delayed recording");
    mixer.setGain(0);
    mixer.reset(48000);
    mixer.enqueue(0);
    std::array<float, 128> left{}, right{};
    mixer.render(left.data(), right.data(), 128);
    require(left[24] == 0.5f, "remove file delay and retain 0.5 ms before impact");
}

void testTailAndBlockBoundaries() {
    const std::vector<float> recording(1000, 0.25f);
    sidetone::KeyboardMixer whole, parts;
    for (auto* mixer : {&whole, &parts}) {
        require(mixer->load(0, recording.data(), 500, 48000), "load a cut recording");
        mixer->setGain(0);
        mixer->reset(48000);
        mixer->enqueue(0);
    }
    std::array<float, 600> left{}, right{}, splitLeft{}, splitRight{};
    whole.render(left.data(), right.data(), 600);
    for (uint32_t offset = 0; offset < 600; offset += 30)
        parts.render(splitLeft.data() + offset, splitRight.data() + offset, 30);
    require(left == splitLeft && right == splitRight, "block boundaries do not change playback");
    require(left[400] == 0.25f && left[498] < 0.003f && left[499] == 0,
            "fade only the cut tail to zero");
    require(left[500] == 0 && left[599] == 0, "finished voices produce no extra frames");
    parts.enqueue(0);
    parts.render(splitLeft.data(), splitRight.data(), 30);
    require(splitLeft[0] == 0.25f, "reuse a completed voice");
}

void testStaleQueue() {
    sidetone::KeyboardMixer mixer;
    const std::array<float, 8> recording{0.2f, 0.2f, 0.1f, 0.1f, 0, 0, 0, 0};
    mixer.load(0, recording.data(), 4, 48000);
    mixer.setGain(0);
    mixer.reset(48000, 100);
    mixer.enqueue(0, 1);
    mixer.enqueue(0, 125);
    std::array<float, 16> left{}, right{};
    mixer.render(left.data(), right.data(), 0, 150);
    require(mixer.statistics().staleDrops == 0, "empty output does not consume the queue");
    mixer.render(left.data(), right.data(), 16, 150);
    require(left[0] == 0.2f, "discard stale sounds and retain the current sound");
    require(mixer.statistics().staleDrops == 1 && mixer.statistics().maxQueueTicks == 25,
            "report stale events and queue wait");
}

void testConcurrentQueue() {
    sidetone::KeyboardMixer mixer;
    const std::array<float, 8> recording{0.001f, 0.001f, 0, 0, 0, 0, 0, 0};
    mixer.load(0, recording.data(), 4, 48000);
    mixer.setGain(0);
    mixer.reset(48000);
    constexpr uint32_t count = 100000;
    std::atomic<bool> finished{false};
    std::thread producer([&] {
        for (uint32_t i = 0; i < count; ++i)
            while (!mixer.enqueue(0))
                std::this_thread::yield();
        finished.store(true, std::memory_order_release);
    });
    double sum = 0;
    std::array<float, 16> left{}, right{};
    const auto render = [&] {
        mixer.render(left.data(), right.data(), 16);
        for (float sample : left)
            sum += sample;
    };
    while (!finished.load(std::memory_order_acquire))
        render();
    producer.join();
    render();
    const auto stats = mixer.statistics();
    require(stats.enqueued == count, "concurrent queue accepts each submitted sound once");
    require(std::abs(sum - double(count - stats.voiceDrops) * 0.001) < 0.01,
            "concurrent queue neither loses nor repeats accepted voices");
}
} // namespace

int main() {
    testPlayback();
    testBounds();
    testRecordedOnset();
    testTailAndBlockBoundaries();
    testStaleQueue();
    testConcurrentQueue();
    std::cout << "Keyboard mixer tests passed.\n";
}
