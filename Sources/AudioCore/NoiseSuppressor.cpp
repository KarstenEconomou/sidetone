#include "NoiseSuppressor.hpp"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <new>
#include <numbers>
#include <stdexcept>

namespace sidetone {

void NoiseSuppressor::Resampler::prepare(double inputRate, double outputRate) {
    ratio_ = inputRate / outputRate;
    taps_ = static_cast<std::size_t>(32 * std::ceil(std::max(1.0, ratio_)));
    kernel_.resize((phases + 1) * taps_);
    history_.resize(taps_);
    const double cutoff = 0.46 / std::max(1.0, ratio_);
    for (std::size_t phase = 0; phase <= phases; ++phase) {
        const double fraction = static_cast<double>(phase) / phases;
        double sum = 0;
        for (std::size_t tap = 0; tap < taps_; ++tap) {
            const double position = static_cast<double>(tap) - delaySamples() - fraction;
            const double x = 2 * cutoff * position;
            const double sinc = std::abs(x) < 1.0e-12
                                    ? 1.0
                                    : std::sin(std::numbers::pi * x) / (std::numbers::pi * x);
            const double angle = 2 * std::numbers::pi * tap / (taps_ - 1);
            const double window = 0.42 - 0.5 * std::cos(angle) + 0.08 * std::cos(2 * angle);
            const auto index = phase * taps_ + tap;
            kernel_[index] = static_cast<float>(sinc * 2 * cutoff * window);
            sum += kernel_[index];
        }
        for (std::size_t tap = 0; tap < taps_; ++tap)
            kernel_[phase * taps_ + tap] /= static_cast<float>(sum);
    }
    reset();
}

void NoiseSuppressor::Resampler::reset() noexcept {
    std::fill(history_.begin(), history_.end(), 0);
    index_ = 0;
    offset_ = 1;
}

void NoiseSuppressor::Resampler::push(float sample) noexcept {
    index_ = (index_ + 1) % taps_;
    history_[index_] = sample;
    offset_ -= 1;
}

bool NoiseSuppressor::Resampler::pop(float& sample) noexcept {
    if (offset_ > 1.0e-9)
        return false;
    const double position = std::clamp(-offset_, 0.0, 1.0) * phases;
    const auto phase = std::min(static_cast<std::size_t>(position), phases - 1);
    const float fraction = static_cast<float>(position - phase);
    const float* first = kernel_.data() + phase * taps_;
    const float* second = first + taps_;
    sample = 0;
    for (std::size_t tap = 0; tap < taps_; ++tap) {
        const float coefficient = first[tap] + fraction * (second[tap] - first[tap]);
        sample += history_[(index_ + taps_ - tap) % taps_] * coefficient;
    }
    offset_ += ratio_;
    return true;
}

void NoiseSuppressor::prepare(double sampleRate) {
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 768000)
        throw std::invalid_argument("Unsupported noise suppression sample rate.");
    rate_ = sampleRate;
    // Check allocation before RNNoise initializes its state.
    state_.reset(static_cast<DenoiseState*>(std::malloc(rnnoise_get_size())));
    if (!state_)
        throw std::bad_alloc();
    if (rnnoise_init(state_.get(), nullptr) != 0 || rnnoise_get_frame_size() != frameSize)
        throw std::runtime_error("The noise suppression model could not start.");
    for (std::size_t index = 0; index < frameSize; ++index)
        input_[index] = static_cast<float>((index * 73) % 257) - 128;
    // Touch model weights and working memory before the audio callback starts.
    for (int frame = 0; frame < 3; ++frame)
        (void)rnnoise_process_frame(state_.get(), output_.data(), input_.data());
    reserve_ = rate_ == 48000 ? 0 : static_cast<std::size_t>(std::ceil(rate_ / 48000)) + 1;
    delayMs_ = 30;
    if (rate_ != 48000) {
        toModel_.prepare(rate_, 48000);
        fromModel_.prepare(48000, rate_);
        delayMs_ += 1000 * (toModel_.delaySamples() / rate_ +
                           fromModel_.delaySamples() / 48000 + reserve_ / rate_);
    }
    fadeStep_ = static_cast<float>(1 / (0.002 * rate_));
    strengthStep_ = static_cast<float>(1 - std::exp(-1 / (0.010 * 48000)));
    strength_ = requestedStrength_.load(std::memory_order_relaxed);
    enabled_ = requestedEnabled_.load(std::memory_order_relaxed);
    resetProcessing();
    fade_ = enabled_ ? 0 : 1;
    latencyMs_.store(enabled_ ? delayMs_ : 0, std::memory_order_relaxed);
}

void NoiseSuppressor::setParameters(bool enabled, float strength) noexcept {
    requestedStrength_.store(std::isfinite(strength) ? std::clamp(strength, 0.0f, 1.0f) : 0.85f,
                             std::memory_order_relaxed);
    requestedEnabled_.store(enabled, std::memory_order_relaxed);
}

void NoiseSuppressor::resetProcessing() noexcept {
    // The built-in model uses constant weights. This reset does not allocate.
    (void)rnnoise_init(state_.get(), nullptr);
    toModel_.reset();
    fromModel_.reset();
    input_.fill(0);
    output_.fill(0);
    dry_.fill(0);
    converted_.fill(0);
    frameIndex_ = dryIndex_ = read_ = 0;
    write_ = reserve_;
    warmup_ = enabled_ ? static_cast<std::size_t>(std::ceil(delayMs_ * rate_ / 1000)) : 0;
}

float NoiseSuppressor::processFrameSample(float sample) noexcept {
    const float dry = dry_[dryIndex_];
    dry_[dryIndex_] = sample;
    dryIndex_ = (dryIndex_ + 1) % dry_.size();
    strength_ += strengthStep_ *
                 (requestedStrength_.load(std::memory_order_relaxed) - strength_);
    const float wet = output_[frameIndex_] / 32768.0f;
    const float result = dry + strength_ * (wet - dry);
    input_[frameIndex_] = sample * 32768.0f;
    if (++frameIndex_ == frameSize) {
        (void)rnnoise_process_frame(state_.get(), output_.data(), input_.data());
        frameIndex_ = 0;
    }
    return std::isfinite(result) ? result : 0;
}

float NoiseSuppressor::processSample(float sample) noexcept {
    if (rate_ == 48000)
        return processFrameSample(sample);
    toModel_.push(sample);
    float modelSample = 0;
    while (toModel_.pop(modelSample)) {
        fromModel_.push(processFrameSample(modelSample));
        float converted = 0;
        while (fromModel_.pop(converted)) {
            converted_[write_ % converted_.size()] = converted;
            ++write_;
        }
    }
    if (read_ == write_)
        return 0;
    return converted_[read_++ % converted_.size()];
}

void NoiseSuppressor::process(std::span<float> samples) noexcept {
    const bool requested = requestedEnabled_.load(std::memory_order_relaxed);
    if (!enabled_ && !requested && fade_ == 1)
        return;
    for (float& sample : samples) {
        if (requested != enabled_) {
            fade_ = std::max(0.0f, fade_ - fadeStep_);
            if (fade_ == 0) {
                enabled_ = requested;
                resetProcessing();
                latencyMs_.store(enabled_ ? delayMs_ : 0, std::memory_order_relaxed);
            }
        } else if (warmup_ == 0) {
            fade_ = std::min(1.0f, fade_ + fadeStep_);
        }
        const float safe = std::isfinite(sample) ? std::clamp(sample, -1.0f, 1.0f) : 0;
        sample = (enabled_ ? processSample(safe) : safe) * fade_;
        if (warmup_ > 0)
            --warmup_;
    }
}

} // namespace sidetone
