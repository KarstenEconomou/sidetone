#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <span>
#include <vector>
#include <rnnoise.h>

namespace sidetone {

static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);

// One audio callback owns all processing state. Prepare requires stopped I/O.
class NoiseSuppressor {
  public:
    void prepare(double sampleRate);
    void setParameters(bool enabled, float strength) noexcept;
    void process(std::span<float> samples) noexcept;
    double latencyMs() const noexcept { return latencyMs_.load(std::memory_order_relaxed); }

  private:
    // This converter has a fixed ratio. It does not control a device clock.
    class Resampler {
      public:
        void prepare(double inputRate, double outputRate);
        void reset() noexcept;
        void push(float sample) noexcept;
        bool pop(float& sample) noexcept;
        double delaySamples() const noexcept { return static_cast<double>(taps_ / 2 - 1); }

      private:
        static constexpr std::size_t phases = 256;
        std::vector<float> kernel_, history_;
        std::size_t taps_{32}, index_{0};
        double ratio_{1}, offset_{1};
    };

    struct StateDeleter {
        void operator()(DenoiseState* state) const noexcept { rnnoise_destroy(state); }
    };
    void resetProcessing() noexcept;
    float processFrameSample(float sample) noexcept;
    float processSample(float sample) noexcept;
    static constexpr std::size_t frameSize = 480;
    // One frame for accumulation, one for overlap-add, and one for lookahead.
    static constexpr std::size_t delayFrames = 3 * frameSize;
    std::unique_ptr<DenoiseState, StateDeleter> state_;
    Resampler toModel_, fromModel_;
    std::array<float, frameSize> input_{}, output_{};
    std::array<float, delayFrames> dry_{};
    std::array<float, 64> converted_{};
    std::size_t frameIndex_{0}, dryIndex_{0}, read_{0}, write_{0}, reserve_{0};
    std::size_t warmup_{0};
    std::atomic<bool> requestedEnabled_{false};
    std::atomic<float> requestedStrength_{0.85f};
    std::atomic<double> latencyMs_{0};
    double rate_{48000}, delayMs_{30};
    float strength_{0.85f}, strengthStep_{0.002f}, fade_{1}, fadeStep_{0.01f};
    bool enabled_{false};
};

} // namespace sidetone
