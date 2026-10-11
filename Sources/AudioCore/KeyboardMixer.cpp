#include "KeyboardMixer.hpp"
#include <algorithm>
#include <cmath>

namespace sidetone {

bool KeyboardMixer::load(uint32_t index, const float* stereo, uint32_t frames, double rate) {
    if (index >= capacity || !stereo || frames < 2 || frames > 960000 || !std::isfinite(rate) ||
        rate < 8000 || rate > 192000)
        return false;
    const auto count = size_t(frames) * 2;
    if (!std::all_of(stereo, stereo + count, [](float value) {
            return std::isfinite(value) && std::abs(value) <= 16;
        }))
        return false;
    float peak = 0;
    for (size_t i = 0; i < count; ++i)
        peak = std::max(peak, std::abs(stereo[i]));
    const float threshold = std::max(0.0005f, peak * 0.01f);
    uint32_t onset = 0;
    while (onset + 1 < frames && std::abs(stereo[onset * 2]) < threshold &&
           std::abs(stereo[onset * 2 + 1]) < threshold)
        ++onset;
    const auto lead = uint32_t(rate * 0.0005);
    const auto first = onset > lead ? onset - lead : 0;
    samples_[index].stereo.assign(stereo + size_t(first) * 2, stereo + count);
    auto& samples = samples_[index].stereo;
    const auto fade = std::min(uint32_t(rate * 0.002), uint32_t(samples.size() / 8));
    for (uint32_t frame = 0; frame < fade; ++frame) {
        const float gain = fade > 1 ? float(frame) / float(fade - 1) : 0;
        const auto offset = samples.size() - size_t(frame + 1) * 2;
        samples[offset] *= gain;
        samples[offset + 1] *= gain;
    }
    samples_[index].rate = rate;
    return true;
}

void KeyboardMixer::reset(double rate, uint64_t maximumAgeTicks) noexcept {
    rate_ = std::isfinite(rate) && rate >= 8000 ? rate : 48000;
    smoothing_ = float(1 - std::exp(-1 / (rate_ * 0.005)));
    voices_ = {};
    active_ = 0;
    maximumAgeTicks_ = maximumAgeTicks;
    enqueued_.store(0, std::memory_order_relaxed);
    queueDrops_.store(0, std::memory_order_relaxed);
    voiceDrops_.store(0, std::memory_order_relaxed);
    clippedFrames_.store(0, std::memory_order_relaxed);
    peakVoices_.store(0, std::memory_order_relaxed);
    staleDrops_.store(0, std::memory_order_relaxed);
    maxQueueTicks_.store(0, std::memory_order_relaxed);
    read_.store(0, std::memory_order_relaxed);
    write_.store(0, std::memory_order_relaxed);
    gain_ = targetGain_.load(std::memory_order_relaxed);
}

bool KeyboardMixer::enqueue(uint32_t sample, uint64_t time) noexcept {
    if (sample >= capacity || samples_[sample].stereo.empty())
        return false;
    const auto write = write_.load(std::memory_order_relaxed);
    if (write - read_.load(std::memory_order_acquire) >= capacity) {
        queueDrops_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    queue_[write % capacity] = {sample, time};
    write_.store(write + 1, std::memory_order_release);
    enqueued_.fetch_add(1, std::memory_order_relaxed);
    return true;
}

void KeyboardMixer::setGain(float decibels) noexcept {
    const float value = std::isfinite(decibels) ? std::clamp(decibels, -60.0f, 0.0f) : -18.0f;
    targetGain_.store(std::pow(10.0f, value / 20.0f), std::memory_order_relaxed);
}

void KeyboardMixer::render(float* left, float* right, uint32_t frames, uint64_t time) noexcept {
    if (!frames)
        return;
    auto read = read_.load(std::memory_order_relaxed);
    const auto write = write_.load(std::memory_order_acquire);
    uint64_t dropped = 0, stale = 0;
    auto maxWait = maxQueueTicks_.load(std::memory_order_relaxed);
    while (read != write) {
        const auto event = queue_[read % capacity];
        const auto age = event.time && time > event.time ? time - event.time : 0;
        if (maximumAgeTicks_ && age > maximumAgeTicks_) {
            ++stale;
            ++read;
            continue;
        }
        maxWait = std::max(maxWait, age);
        // Drop excess events instead of cutting a sound in progress.
        if (active_ < voices_.size())
            voices_[active_++] = {&samples_[event.sample], 0};
        else
            ++dropped;
        ++read;
    }
    read_.store(read, std::memory_order_release);
    if (dropped)
        voiceDrops_.fetch_add(dropped, std::memory_order_relaxed);
    if (stale)
        staleDrops_.fetch_add(stale, std::memory_order_relaxed);
    maxQueueTicks_.store(maxWait, std::memory_order_relaxed);
    if (active_ > peakVoices_.load(std::memory_order_relaxed))
        peakVoices_.store(active_, std::memory_order_relaxed);
    std::fill_n(left, frames, 0.0f);
    std::fill_n(right, frames, 0.0f);
    const float target = targetGain_.load(std::memory_order_relaxed);
    if (!active_) {
        gain_ = target;
        return;
    }
    for (uint32_t index = 0; index < active_;) {
        auto& voice = voices_[index];
        const auto& samples = voice.sample->stereo;
        const auto length = samples.size() / 2;
        const double step = voice.sample->rate / rate_;
        if (step == 1) {
            const auto position = size_t(voice.position);
            const auto count = std::min(size_t(frames), length - position);
            for (size_t frame = 0; frame < count; ++frame) {
                left[frame] += samples[(position + frame) * 2];
                right[frame] += samples[(position + frame) * 2 + 1];
            }
            voice.position += double(count);
        } else {
            for (uint32_t frame = 0; frame < frames && voice.position < double(length); ++frame) {
                const auto position = size_t(voice.position);
                const auto next = std::min(position + 1, length - 1);
                const float fraction = float(voice.position - double(position));
                left[frame] += samples[position * 2] * (1 - fraction) + samples[next * 2] * fraction;
                right[frame] += samples[position * 2 + 1] * (1 - fraction) +
                                samples[next * 2 + 1] * fraction;
                voice.position += step;
            }
        }
        if (voice.position >= double(length))
            voices_[index] = voices_[--active_];
        else
            ++index;
    }
    uint64_t clipped = 0;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        gain_ += (target - gain_) * smoothing_;
        const float l = left[frame] * gain_, r = right[frame] * gain_;
        clipped += std::abs(l) > 0.98f || std::abs(r) > 0.98f;
        left[frame] = std::clamp(l, -0.98f, 0.98f);
        right[frame] = std::clamp(r, -0.98f, 0.98f);
    }
    if (clipped)
        clippedFrames_.fetch_add(clipped, std::memory_order_relaxed);
}

KeyboardMixer::Statistics KeyboardMixer::statistics() const noexcept {
    return {enqueued_.load(std::memory_order_relaxed), queueDrops_.load(std::memory_order_relaxed),
            voiceDrops_.load(std::memory_order_relaxed), clippedFrames_.load(std::memory_order_relaxed),
            staleDrops_.load(std::memory_order_relaxed), maxQueueTicks_.load(std::memory_order_relaxed),
            peakVoices_.load(std::memory_order_relaxed)};
}
} // namespace sidetone
