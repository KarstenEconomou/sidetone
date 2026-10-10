#include "DSP.hpp"
#include <algorithm>
#include <cmath>
#include <numbers>

namespace sidetone {
namespace {
double safeRate(double rate) noexcept {
    return std::isfinite(rate) ? std::clamp(rate, 8000.0, 768000.0) : 48000.0;
}
float finiteRange(float value, float low, float high, float fallback) noexcept {
    return std::isfinite(value) ? std::clamp(value, low, high) : fallback;
}
std::array<double, 5> highPass(double rate, double frequency) noexcept {
    const double omega = 2.0 * std::numbers::pi * frequency / rate;
    const double cosine = std::cos(omega), alpha = std::sin(omega) / std::sqrt(2.0);
    const double a0 = 1.0 + alpha;
    return {(1.0 + cosine) / (2.0 * a0), -(1.0 + cosine) / a0,
            (1.0 + cosine) / (2.0 * a0), -2.0 * cosine / a0, (1.0 - alpha) / a0};
}
std::array<double, 5> peak(double rate, double frequency, double gain, double q) noexcept {
    const double amplitude = std::pow(10.0, gain / 40.0);
    const double omega = 2.0 * std::numbers::pi * frequency / rate;
    const double cosine = std::cos(omega), alpha = std::sin(omega) / (2.0 * q);
    const double a0 = 1.0 + alpha / amplitude;
    return {(1.0 + alpha * amplitude) / a0, -2.0 * cosine / a0,
            (1.0 - alpha * amplitude) / a0, -2.0 * cosine / a0, (1.0 - alpha / amplitude) / a0};
}
}

float DSP::Biquad::process(float input, double smoothing) noexcept {
    for (std::size_t index = 0; index < current.size(); ++index) {
        current[index] += smoothing * (target[index] - current[index]);
        if (std::abs(target[index] - current[index]) < 1.0e-15) current[index] = target[index];
    }
    const double output = current[0] * input + z1;
    z1 = current[1] * input - current[3] * output + z2;
    z2 = current[2] * input - current[4] * output;
    if (std::abs(z1) < 1.0e-24) z1 = 0;
    if (std::abs(z2) < 1.0e-24) z2 = 0;
    return static_cast<float>(output);
}

void DSP::prepare(double sampleRate) noexcept {
    sampleRate_ = safeRate(sampleRate);
    smoothing_ = static_cast<float>(1.0 - std::exp(-1.0 / (sampleRate_ * 0.005)));
    profileSmoothing_ = static_cast<float>(1.0 - std::exp(-1.0 / (sampleRate_ * 0.010)));
    coefficientSmoothing_ = 1.0 - std::exp(-1.0 / (sampleRate_ * 0.010));
    attack_ = 1.0 - std::exp(-1.0 / (sampleRate_ * 0.008));
    release_ = 1.0 - std::exp(-1.0 / (sampleRate_ * 0.120));
    gain_ = compressionMix_ = 0;
    naturalEnvelope_ = voiceEnvelope_ = 0;
    refresh_ = 0;
    weights_ = {1, 0, 0};
    filters_ = {};
    setParameters(requested_);
    readParameters(true);
    clipped_.store(0, std::memory_order_relaxed);
}

void DSP::setParameters(STParameters parameters) noexcept {
    parameters.gainDB = finiteRange(parameters.gainDB, -60, 6, -60);
    parameters.profile = std::min(parameters.profile, 2U);
    parameters.highPassHz = finiteRange(parameters.highPassHz, 20, 300, 75);
    parameters.eqFrequencyHz = finiteRange(parameters.eqFrequencyHz, 80, static_cast<float>(std::min(16000.0, sampleRate_ * 0.45)), 1800);
    parameters.eqGainDB = finiteRange(parameters.eqGainDB, -12, 12, 0);
    parameters.eqQ = finiteRange(parameters.eqQ, 0.2f, 4.0f, 0.7f);
    requested_ = parameters;
    const std::array<std::array<double, 5>, 5> filters{
        highPass(sampleRate_, parameters.highPassHz),
        peak(sampleRate_, parameters.eqFrequencyHz, parameters.eqGainDB, parameters.eqQ),
        highPass(sampleRate_, std::max(110.0f, parameters.highPassHz)),
        peak(sampleRate_, parameters.eqFrequencyHz, std::clamp(parameters.eqGainDB + 3.0f, -12.0f, 12.0f), parameters.eqQ),
        peak(sampleRate_, 350.0, -2.0, 0.7)
    };
    revision_.fetch_add(1, std::memory_order_acq_rel);
    for (std::size_t filter = 0; filter < filters.size(); ++filter)
        for (std::size_t coefficient = 0; coefficient < 5; ++coefficient)
            coefficients_[filter * 5 + coefficient].store(filters[filter][coefficient], std::memory_order_relaxed);
    targetGain_.store(std::pow(10.0f, parameters.gainDB / 20.0f), std::memory_order_relaxed);
    targetProfile_.store(parameters.profile, std::memory_order_relaxed);
    targetCompression_.store(parameters.compression != 0 ? 1U : 0U, std::memory_order_relaxed);
    revision_.fetch_add(1, std::memory_order_release);
}

void DSP::readParameters(bool immediate) noexcept {
    const auto revision = revision_.load(std::memory_order_acquire);
    if ((revision & 1U) != 0 || (!immediate && revision == readRevision_)) return;
    std::array<double, 25> coefficients{};
    for (std::size_t index = 0; index < coefficients.size(); ++index)
        coefficients[index] = coefficients_[index].load(std::memory_order_relaxed);
    const float gain = targetGain_.load(std::memory_order_relaxed);
    const auto profile = targetProfile_.load(std::memory_order_relaxed);
    const float compression = static_cast<float>(targetCompression_.load(std::memory_order_relaxed));
    std::atomic_thread_fence(std::memory_order_acquire);
    if (revision != revision_.load(std::memory_order_relaxed)) return;
    requestedGain_ = gain;
    profile_ = profile;
    requestedCompression_ = compression;
    for (std::size_t filter = 0; filter < filters_.size(); ++filter)
        for (std::size_t coefficient = 0; coefficient < 5; ++coefficient) {
            filters_[filter].target[coefficient] = coefficients[filter * 5 + coefficient];
            if (immediate) filters_[filter].current[coefficient] = coefficients[filter * 5 + coefficient];
        }
    readRevision_ = revision;
}

float DSP::compress(float value, double &envelope, double threshold, double exponent) noexcept {
    const double level = std::abs(value);
    envelope += (level > envelope ? attack_ : release_) * (level - envelope);
    if (envelope < 1.0e-24) envelope = 0;
    if (envelope <= threshold || compressionMix_ < 1.0e-5f) return value;
    const float gain = static_cast<float>(std::pow(threshold / envelope, exponent));
    return value * (1.0f + compressionMix_ * (gain - 1.0f));
}

float DSP::process(float input) noexcept {
    if (refresh_ == 0) { readParameters(); refresh_ = 32; }
    --refresh_;
    gain_ += smoothing_ * (requestedGain_ - gain_);
    compressionMix_ += profileSmoothing_ * (requestedCompression_ - compressionMix_);
    if (compressionMix_ < 1.0e-12f) compressionMix_ = 0;
    for (std::size_t index = 0; index < weights_.size(); ++index) {
        weights_[index] += profileSmoothing_ * ((profile_ == index ? 1.0f : 0.0f) - weights_[index]);
        if (weights_[index] < 1.0e-12f) weights_[index] = 0;
    }
    const float safeInput = std::isfinite(input) ? std::clamp(input, -16.0f, 16.0f) : 0.0f;
    float value = safeInput;
    if (profile_ != 0 || weights_[1] + weights_[2] > 1.0e-5f) {
        float natural = filters_[1].process(filters_[0].process(safeInput, coefficientSmoothing_), coefficientSmoothing_);
        float voice = filters_[4].process(filters_[3].process(filters_[2].process(safeInput, coefficientSmoothing_), coefficientSmoothing_), coefficientSmoothing_);
        natural = compress(natural, naturalEnvelope_, 0.125892541, 1.0 / 3.0);
        voice = compress(voice, voiceEnvelope_, 0.1, 0.6);
        value = weights_[0] * safeInput + weights_[1] * natural + weights_[2] * voice;
    }
    value *= gain_;
    if (!std::isfinite(value)) {
        for (auto &filter : filters_) filter.z1 = filter.z2 = 0;
        naturalEnvelope_ = voiceEnvelope_ = 0;
        value = 0;
    }
    if (std::abs(value) > 0.95f) clipped_.fetch_add(1, std::memory_order_relaxed);
    return std::clamp(value, -0.95f, 0.95f);
}

void DSP::process(float *samples, std::uint32_t count) noexcept {
    for (std::uint32_t index = 0; index < count; ++index) samples[index] = process(samples[index]);
}

bool AdaptiveTransport::supportsConfiguration(double inputRate, double outputRate,
                                             std::uint32_t inputBufferFrames, std::uint32_t outputBufferFrames) noexcept {
    if (!std::isfinite(inputRate) || !std::isfinite(outputRate) || inputRate < 8000 || inputRate > 768000 ||
        outputRate < 8000 || outputRate > 768000 || inputBufferFrames == 0 || outputBufferFrames == 0) return false;
    const double target = outputBufferFrames * inputRate / outputRate + inputBufferFrames * 0.5 + std::max(16.0, inputRate * 0.002);
    return target + std::max(4.0 * inputBufferFrames, inputRate * 0.020) < 131072;
}

void AdaptiveTransport::prepare(double inputRate, double outputRate,
                                std::uint32_t inputBufferFrames, std::uint32_t outputBufferFrames) {
    inputRate_ = safeRate(inputRate);
    outputRate_ = safeRate(outputRate);
    ratio_ = inputRate_ / outputRate_;
    const double sourceOutputFrames = outputBufferFrames * ratio_;
    targetFrames_ = std::clamp(sourceOutputFrames + inputBufferFrames * 0.5 + std::max(16.0, inputRate_ * 0.002), 4.0, 120000.0);
    startupFrames_ = std::min(125000.0, targetFrames_ + inputBufferFrames * 0.5 + 2.0);
    maximumFrames_ = std::min(130000.0, targetFrames_ + std::max(4.0 * inputBufferFrames, inputRate_ * 0.020));
    tapCount_ = static_cast<std::size_t>(std::clamp(32.0 * std::ceil(std::max(1.0, ratio_)), 32.0, static_cast<double>(maxTaps)));
    kernel_.resize((phases + 1) * tapCount_);
    const double cutoff = 0.46 / std::max(1.0, ratio_ * 1.003);
    for (std::size_t phase = 0; phase <= phases; ++phase) {
        const double fraction = static_cast<double>(phase) / phases;
        double sum = 0;
        for (std::size_t tap = 0; tap < tapCount_; ++tap) {
            const double position = static_cast<double>(tap) - (static_cast<double>(tapCount_ / 2 - 1) - fraction);
            const double x = 2.0 * cutoff * position;
            const double sinc = std::abs(x) < 1.0e-12 ? 1.0 : std::sin(std::numbers::pi * x) / (std::numbers::pi * x);
            const double windowPhase = 2.0 * std::numbers::pi * static_cast<double>(tap) / static_cast<double>(tapCount_ - 1);
            const double window = 0.42 - 0.5 * std::cos(windowPhase) + 0.08 * std::cos(2.0 * windowPhase);
            kernel_[phase * tapCount_ + tap] = static_cast<float>(sinc * 2.0 * cutoff * window);
            sum += kernel_[phase * tapCount_ + tap];
        }
        for (std::size_t tap = 0; tap < tapCount_; ++tap) kernel_[phase * tapCount_ + tap] /= static_cast<float>(sum);
    }
    ring_.reset();
    history_.fill(0);
    historyIndex_ = 0;
    phase_ = filteredError_ = integral_ = correction_ = 0;
    lastOutput_ = fade_ = fadeOutStep_ = 0;
    primed_ = started_ = false;
    underruns_.store(0);
    overruns_.store(0);
    driftPPM_.store(0);
    queueLatencyMs_.store(0);
}

void AdaptiveTransport::push(const float *samples, std::uint32_t count) noexcept {
    bool dropped = false;
    for (std::uint32_t index = 0; index < count; ++index)
        if (!ring_.push(std::isfinite(samples[index]) ? std::clamp(samples[index], -16.0f, 16.0f) : 0.0f)) dropped = true;
    if (dropped) overruns_.fetch_add(1, std::memory_order_relaxed);
}

void AdaptiveTransport::render(float *samples, std::uint32_t count) noexcept {
    const auto queued = ring_.size();
    if (queued > static_cast<std::size_t>(maximumFrames_)) {
        const auto excess = queued - static_cast<std::size_t>(startupFrames_);
        (void)ring_.discard(excess);
        primed_ = false;
        fadeOutStep_ = std::abs(lastOutput_) / static_cast<float>(0.002 * outputRate_);
        if (started_) overruns_.fetch_add(1, std::memory_order_relaxed);
    }
    if (!primed_ && ring_.size() >= static_cast<std::size_t>(startupFrames_) && std::abs(lastOutput_) < 1.0e-5f) {
        const auto excess = ring_.size() - static_cast<std::size_t>(startupFrames_);
        (void)ring_.discard(excess);
        history_.fill(0);
        historyIndex_ = 0;
        primed_ = ring_.pop(history_[historyIndex_]);
        started_ = true;
        phase_ = 0;
        fade_ = 0;
    }
    const double duration = static_cast<double>(count) / outputRate_;
    if (primed_) {
        const double error = (static_cast<double>(ring_.size()) - targetFrames_) / inputRate_;
        const double alpha = 1.0 - std::exp(-duration / 0.25);
        filteredError_ += alpha * (error - filteredError_);
        integral_ = std::clamp(integral_ + filteredError_ * duration * 0.10, -0.003, 0.003);
        const double requested = std::clamp(filteredError_ * 0.75 + integral_, -0.003, 0.003);
        correction_ += std::clamp(requested - correction_, -duration * 0.001, duration * 0.001);
    }
    const double step = ratio_ * (1.0 + correction_);
    const float fadeStep = static_cast<float>(1.0 / (0.002 * outputRate_));
    bool starved = false;
    for (std::uint32_t index = 0; index < count; ++index) {
        if (!primed_) {
            lastOutput_ = std::copysign(std::max(0.0f, std::abs(lastOutput_) - fadeOutStep_), lastOutput_);
            samples[index] = lastOutput_;
            continue;
        }
        const double phasePosition = phase_ * phases;
        const auto kernelIndex = static_cast<std::size_t>(phasePosition);
        const float blend = static_cast<float>(phasePosition - static_cast<double>(kernelIndex));
        const auto first = kernel_.data() + kernelIndex * tapCount_;
        const auto second = first + tapCount_;
        float value = 0;
        for (std::size_t tap = 0; tap < tapCount_; ++tap) {
            const float coefficient = first[tap] + blend * (second[tap] - first[tap]);
            value += history_[(historyIndex_ + maxTaps - tap) % maxTaps] * coefficient;
        }
        fade_ = std::min(1.0f, fade_ + fadeStep);
        samples[index] = lastOutput_ = value * fade_;
        phase_ += step;
        while (phase_ >= 1.0) {
            float next = 0;
            if (!ring_.pop(next)) {
                primed_ = false;
                starved = true;
                fadeOutStep_ = std::abs(lastOutput_) * fadeStep;
                break;
            }
            historyIndex_ = (historyIndex_ + 1) % maxTaps;
            history_[historyIndex_] = next;
            phase_ -= 1.0;
        }
    }
    if (starved) underruns_.fetch_add(1, std::memory_order_relaxed);
    queueLatencyMs_.store(static_cast<double>(ring_.size()) * 1000.0 / inputRate_, std::memory_order_relaxed);
    driftPPM_.store(correction_ * 1.0e6, std::memory_order_relaxed);
}

} // namespace sidetone
