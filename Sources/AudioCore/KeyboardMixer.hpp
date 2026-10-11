#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <vector>

namespace sidetone {

class KeyboardMixer {
  public:
    struct Statistics {
        uint64_t enqueued = 0, queueDrops = 0, voiceDrops = 0, clippedFrames = 0;
        uint64_t staleDrops = 0, maxQueueTicks = 0;
        uint32_t peakVoices = 0;
    };
    // Load samples and reset only while the producer and callback are stopped.
    bool load(uint32_t index, const float* stereo, uint32_t frames, double rate);
    void reset(double rate, uint64_t maximumAgeTicks = 0) noexcept;
    // One control thread supplies events. The audio callback consumes them.
    bool enqueue(uint32_t sample, uint64_t time = 0) noexcept;
    void setGain(float decibels) noexcept;
    void render(float* left, float* right, uint32_t frames, uint64_t time = 0) noexcept;
    Statistics statistics() const noexcept;

  private:
    static constexpr uint32_t capacity = 256;
    struct Sample {
        std::vector<float> stereo;
        double rate = 44100;
    };
    struct Voice {
        const Sample* sample = nullptr;
        double position = 0;
    };
    std::array<Sample, capacity> samples_;
    struct Event { uint32_t sample = 0; uint64_t time = 0; };
    std::array<Event, capacity> queue_{};
    alignas(64) std::atomic<uint32_t> write_{0};
    alignas(64) std::atomic<uint32_t> read_{0};
    std::atomic<float> targetGain_{0.126f};
    std::array<Voice, 64> voices_{};
    uint32_t active_ = 0;
    uint64_t maximumAgeTicks_ = 0;
    double rate_ = 48000;
    float gain_ = 0;
    float smoothing_ = 0;
    std::atomic<uint64_t> enqueued_{0}, queueDrops_{0}, voiceDrops_{0}, clippedFrames_{0};
    std::atomic<uint64_t> staleDrops_{0}, maxQueueTicks_{0};
    std::atomic<uint32_t> peakVoices_{0};
};

} // namespace sidetone
