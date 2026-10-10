#pragma once

#include "include/AudioCore.h"
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace sidetone {

// The producer owns write_. The consumer owns read_. Reset requires stopped I/O.
template <std::size_t Capacity> class SPSCRing {
    static_assert(Capacity > 1 && (Capacity & (Capacity - 1)) == 0);

  public:
    void reset() noexcept {
        read_.store(0);
        write_.store(0);
    }
    bool push(float value) noexcept {
        const auto write = write_.load(std::memory_order_relaxed);
        if (write - read_.load(std::memory_order_acquire) >= Capacity)
            return false;
        data_[write & (Capacity - 1)] = value;
        write_.store(write + 1, std::memory_order_release);
        return true;
    }
    bool pop(float& value) noexcept {
        const auto read = read_.load(std::memory_order_relaxed);
        if (read == write_.load(std::memory_order_acquire))
            return false;
        value = data_[read & (Capacity - 1)];
        read_.store(read + 1, std::memory_order_release);
        return true;
    }
    std::size_t discard(std::size_t count) noexcept {
        const auto read = read_.load(std::memory_order_relaxed);
        const auto available = write_.load(std::memory_order_acquire) - read;
        const auto discarded = count < available ? count : available;
        read_.store(read + discarded, std::memory_order_release);
        return static_cast<std::size_t>(discarded);
    }
    std::size_t size() const noexcept {
        const auto read = read_.load(std::memory_order_acquire);
        const auto write = write_.load(std::memory_order_acquire);
        return static_cast<std::size_t>(write - read);
    }
    static constexpr std::size_t capacity() noexcept { return Capacity; }

  private:
    std::array<float, Capacity> data_{};
    alignas(64) std::atomic<std::uint64_t> read_{0};
    alignas(64) std::atomic<std::uint64_t> write_{0};
};

static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);

// The output callback owns processing state. One control thread publishes parameters.
class DSP {
  public:
    void prepare(double sampleRate) noexcept;
    void setParameters(STParameters parameters) noexcept;
    float process(float input) noexcept;
    void process(std::span<float> samples) noexcept;
    std::uint64_t clippedSamples() const noexcept {
        return clipped_.load(std::memory_order_relaxed);
    }

  private:
    enum FilterIndex : std::size_t {
        naturalHighPass,
        naturalEQ,
        voiceHighPass,
        voiceEQ,
        voiceLowMid,
        filterCount
    };
    struct Biquad {
        std::array<double, 5> current{1, 0, 0, 0, 0};
        std::array<double, 5> target{1, 0, 0, 0, 0};
        double z1{0}, z2{0};
        float process(float input, double smoothing) noexcept;
    };
    void readParameters(bool immediate = false) noexcept;
    float compress(float value, double& envelope, double threshold, double exponent) noexcept;
    STParameters requested_{-12, 0, 75, 1800, 0, 0.7f, 0};
    double sampleRate_{48000};
    std::array<std::atomic<double>, filterCount * 5> coefficients_{};
    std::atomic<std::uint64_t> revision_{0};
    std::atomic<float> targetGain_{0.25118864f};
    std::atomic<std::uint32_t> targetProfile_{0}, targetCompression_{0};
    std::atomic<std::uint64_t> clipped_{0};
    std::array<Biquad, filterCount> filters_{};
    std::array<float, 3> weights_{1, 0, 0};
    std::uint64_t readRevision_{0};
    std::uint32_t refresh_{0}, profile_{0};
    float requestedGain_{0.25118864f}, requestedCompression_{0};
    float gain_{0};
    float smoothing_{0.004f};
    float profileSmoothing_{0.001f}, compressionMix_{0};
    double coefficientSmoothing_{0.002}, attack_{0.002}, release_{0.0002};
    double naturalEnvelope_{0}, voiceEnvelope_{0};
};

// Input owns push. Output owns render. Buffers belong to the caller.
class AdaptiveTransport {
  public:
    static bool supportsConfiguration(double inputRate, double outputRate,
                                      std::uint32_t inputBufferFrames,
                                      std::uint32_t outputBufferFrames) noexcept;
    // Call prepare with input and output stopped. It allocates the filter table.
    void prepare(double inputRate, double outputRate, std::uint32_t inputBufferFrames,
                 std::uint32_t outputBufferFrames);
    void push(std::span<const float> samples) noexcept;
    void render(std::span<float> samples) noexcept;
    std::uint64_t underruns() const noexcept { return underruns_.load(std::memory_order_relaxed); }
    std::uint64_t overruns() const noexcept { return overruns_.load(std::memory_order_relaxed); }
    double driftPPM() const noexcept { return driftPPM_.load(std::memory_order_relaxed); }
    double queueLatencyMs() const noexcept {
        return queueLatencyMs_.load(std::memory_order_relaxed);
    }
    double resamplerLatencyMs() const noexcept {
        return static_cast<double>(tapCount_ / 2 - 1) * 1000.0 / inputRate_;
    }

  private:
    static constexpr std::size_t maxTaps = 4096;
    static constexpr std::size_t phases = 256;
    static constexpr std::size_t ringCapacity = 131072;
    SPSCRing<ringCapacity> ring_;
    std::vector<float> kernel_;
    std::array<float, maxTaps> history_{};
    std::atomic<std::uint64_t> underruns_{0}, overruns_{0};
    std::atomic<double> driftPPM_{0}, queueLatencyMs_{0};
    double inputRate_{48000}, outputRate_{48000}, ratio_{1}, phase_{0};
    double targetFrames_{128}, startupFrames_{160}, filteredError_{0}, integral_{0}, correction_{0},
        maximumFrames_{512};
    std::size_t tapCount_{32}, historyIndex_{0};
    float lastOutput_{0}, fade_{0}, fadeOutStep_{0};
    bool primed_{false}, started_{false};
};

} // namespace sidetone
