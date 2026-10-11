#include "KeyboardMixer.hpp"
#include "include/AudioCore.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mach/mach_time.h>
#include <utility>
#include <vector>

static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);

namespace {
// Device notifications do not retain an engine pointer.
std::atomic<uint64_t> outputGeneration{1};
}

struct STKeyboardEngine {
    sidetone::KeyboardMixer mixer;
    AudioUnit unit = nullptr;
    STDevice device{};
    std::atomic<bool> invalidated{false};
    bool started = false;
    bool stalled = false;
    std::array<char, 256> error{};
    uint64_t observedGeneration = 0;
    std::vector<std::pair<AudioObjectID, AudioObjectPropertyAddress>> listeners;
    std::array<float, 512> left{};
    std::array<float, 512> right{};
    std::atomic<uint64_t> callbacks{0}, maximumCallbackTicks{0}, deadlineMisses{0};
    uint64_t previousCallbacks = 0, progressTime = 0;
    double tickMs = 0;

    STKeyboardEngine() {
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        tickMs = double(timebase.numer) / timebase.denom / 1000000.0;
    }

    ~STKeyboardEngine() { stop(); }

    static OSStatus changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void*) noexcept {
        outputGeneration.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    }

    bool needsRestart() const noexcept {
        return invalidated.load(std::memory_order_relaxed) ||
               outputGeneration.load(std::memory_order_relaxed) != observedGeneration;
    }

    void stop() noexcept {
        if (unit) {
            AudioOutputUnitStop(unit);
            AudioUnitUninitialize(unit);
            AudioComponentInstanceDispose(unit);
            unit = nullptr;
        }
        for (const auto& [object, property] : listeners)
            AudioObjectRemovePropertyListener(object, &property, changed, nullptr);
        listeners.clear();
        started = false;
    }

    bool fail(const char* message) noexcept {
        std::snprintf(error.data(), error.size(), "%s", message);
        return false;
    }

    bool check(OSStatus status, const char* operation) noexcept {
        if (status == noErr)
            return true;
        std::snprintf(error.data(), error.size(), "%s (%d).", operation, int(status));
        return false;
    }

    template <class T>
    bool set(AudioUnitPropertyID property, AudioUnitScope scope, UInt32 element, const T& value) {
        return check(AudioUnitSetProperty(unit, property, scope, element, &value, sizeof(value)),
                     "Could not set keyboard audio output");
    }

    void observe(AudioObjectPropertySelector selector,
                 AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
                 AudioObjectID object = kAudioObjectUnknown) {
        if (object == kAudioObjectUnknown)
            object = device.id;
        AudioObjectPropertyAddress property{selector, scope, kAudioObjectPropertyElementMain};
        if (AudioObjectHasProperty(object, &property) &&
            AudioObjectAddPropertyListener(object, &property, changed, nullptr) == noErr)
            listeners.push_back({object, property});
    }

    bool start(uint32_t id, const char* uid) {
        stop();
        error[0] = '\0';
        stalled = false;
        invalidated.store(false, std::memory_order_relaxed);
        std::vector<STDevice> devices(st_devices(nullptr, 0));
        const auto count = st_devices(devices.data(), uint32_t(devices.size()));
        devices.resize(std::min(size_t(count), devices.size()));
        const auto found = std::find_if(devices.begin(), devices.end(), [id, uid](const auto& value) {
            return value.id == id && uid && std::strcmp(value.uid, uid) == 0;
        });
        if (found == devices.end() || !found->outputChannels || found->outputChannels > 128 ||
            !found->bufferFrames || found->bufferFrames > 16384 ||
            !std::isfinite(found->sampleRate) || found->sampleRate < 8000 || found->sampleRate > 192000) {
            return fail("The keyboard output device is unavailable.");
        }
        device = *found;
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_HALOutput;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        const auto component = AudioComponentFindNext(nullptr, &description);
        if (!component) {
            return fail("The HAL audio component is unavailable.");
        }
        if (!check(AudioComponentInstanceNew(component, &unit), "Could not create keyboard audio") ||
            !set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(0)) ||
            !set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1)) ||
            !set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id))
            return false;
        AudioStreamBasicDescription format{};
        format.mSampleRate = device.sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = UInt32(kAudioFormatFlagsNativeFloatPacked) |
                              UInt32(kAudioFormatFlagIsNonInterleaved);
        format.mBytesPerPacket = sizeof(float);
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = sizeof(float);
        format.mChannelsPerFrame = device.outputChannels;
        format.mBitsPerChannel = 32;
        const AURenderCallbackStruct callback{render, this};
        if (!set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                 std::max(UInt32(4096), device.bufferFrames)) ||
            !set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format) ||
            !set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, callback) ||
            !check(AudioUnitInitialize(unit), "Could not initialize keyboard audio"))
            return false;
        mixer.reset(device.sampleRate, uint64_t(100.0 / tickMs));
        callbacks.store(0, std::memory_order_relaxed);
        maximumCallbackTicks.store(0, std::memory_order_relaxed);
        deadlineMisses.store(0, std::memory_order_relaxed);
        previousCallbacks = 0;
        progressTime = mach_absolute_time();
        observedGeneration = outputGeneration.load(std::memory_order_relaxed);
        listeners.reserve(9);
        observe(kAudioDevicePropertyDeviceIsAlive);
        observe(kAudioDevicePropertyIOStoppedAbnormally);
        observe(kAudioDevicePropertyNominalSampleRate);
        observe(kAudioDevicePropertyBufferFrameSize);
        observe(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
        observe(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput);
        observe(kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput);
        observe(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput);
        observe(kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal,
                kAudioObjectSystemObject);
        started = check(AudioOutputUnitStart(unit), "Could not start keyboard audio");
        return started;
    }

    bool running() noexcept {
        if (started && !needsRestart()) {
            const auto now = mach_absolute_time();
            const auto count = callbacks.load(std::memory_order_relaxed);
            if (count != previousCallbacks) {
                previousCallbacks = count;
                progressTime = now;
            }
            if (double(now - progressTime) * tickMs >
                std::max(1000.0, 4000.0 * device.bufferFrames / device.sampleRate)) {
                stalled = true;
                invalidated.store(true, std::memory_order_relaxed);
            }
        }
        return started && !needsRestart();
    }

    STKeyboardTelemetry telemetry() const noexcept {
        const auto stats = mixer.statistics();
        return {device.sampleRate, device.bufferFrames, callbacks.load(std::memory_order_relaxed),
                double(maximumCallbackTicks.load(std::memory_order_relaxed)) * tickMs,
                double(stats.maxQueueTicks) * tickMs, deadlineMisses.load(std::memory_order_relaxed),
                stats.enqueued, stats.queueDrops, stats.voiceDrops, stats.staleDrops,
                stats.clippedFrames, stats.peakVoices, uint32_t(stalled)};
    }

    static OSStatus render(void* context, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32,
                           UInt32 frames, AudioBufferList* buffers) noexcept {
        auto& engine = *static_cast<STKeyboardEngine*>(context);
        const auto begin = mach_absolute_time();
        if (!buffers)
            return noErr;
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
            auto& buffer = buffers->mBuffers[i];
            if (buffer.mData)
                std::memset(buffer.mData, 0, buffer.mDataByteSize);
        }
        if (engine.needsRestart())
            return noErr;
        for (UInt32 offset = 0; offset < frames;) {
            const auto count = std::min(UInt32(engine.left.size()), frames - offset);
            engine.mixer.render(engine.left.data(), engine.right.data(), count, mach_absolute_time());
            UInt32 channelBase = 0;
            for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
                auto& buffer = buffers->mBuffers[i];
                const auto channels = buffer.mNumberChannels;
                auto* data = static_cast<float*>(buffer.mData);
                const auto capacity = channels ? buffer.mDataByteSize / sizeof(float) / channels : 0;
                for (UInt32 channel = 0; data && channel < channels; ++channel) {
                    const auto absolute = channelBase + channel;
                    const bool isLeft = absolute == engine.device.outputLeftChannel;
                    const bool isRight = absolute == engine.device.outputRightChannel;
                    if (!isLeft && !isRight)
                        continue;
                    for (UInt32 frame = 0; frame < count && offset + frame < capacity; ++frame) {
                        const float value = isLeft && isRight
                                                ? (engine.left[frame] + engine.right[frame]) * 0.5f
                                                : isLeft ? engine.left[frame] : engine.right[frame];
                        data[size_t(offset + frame) * channels + channel] = value;
                    }
                }
                channelBase += channels;
            }
            offset += count;
        }
        const auto duration = mach_absolute_time() - begin;
        if (duration > engine.maximumCallbackTicks.load(std::memory_order_relaxed))
            engine.maximumCallbackTicks.store(duration, std::memory_order_relaxed);
        if (double(duration) * engine.tickMs > 1000.0 * frames / engine.device.sampleRate)
            engine.deadlineMisses.fetch_add(1, std::memory_order_relaxed);
        engine.callbacks.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    }
};

extern "C" {
STKeyboardEngine* st_keyboard_create(void) {
    try {
        return new STKeyboardEngine();
    } catch (...) {
        return nullptr;
    }
}
void st_keyboard_destroy(STKeyboardEngine* engine) { delete engine; }
int32_t st_keyboard_start(STKeyboardEngine* engine, uint32_t device, const char* uid) {
    if (!engine)
        return -1;
    try {
        if (engine->start(device, uid))
            return 0;
    } catch (...) {
        engine->fail("Could not prepare keyboard audio.");
    }
    engine->stop();
    return -1;
}
void st_keyboard_stop(STKeyboardEngine* engine) {
    if (engine)
        engine->stop();
}
void st_keyboard_set_gain(STKeyboardEngine* engine, float decibels) {
    if (engine)
        engine->mixer.setGain(decibels);
}
int32_t st_keyboard_load_sample(STKeyboardEngine* engine, uint32_t sample, const float* stereo,
                                uint32_t frames, double rate) {
    if (!engine || engine->started)
        return -1;
    try {
        return engine->mixer.load(sample, stereo, frames, rate) ? 0 : -1;
    } catch (...) {
        return -1;
    }
}
void st_keyboard_play(STKeyboardEngine* engine, uint32_t sample) {
    if (engine && engine->started && !engine->needsRestart())
        engine->mixer.enqueue(sample, mach_absolute_time());
}
uint32_t st_keyboard_running(STKeyboardEngine* engine) {
    return engine && engine->running();
}
STKeyboardTelemetry st_keyboard_telemetry(STKeyboardEngine* engine) {
    return engine ? engine->telemetry() : STKeyboardTelemetry{};
}
const char* st_keyboard_error(STKeyboardEngine* engine) {
    return engine ? engine->error.data() : "Could not create keyboard audio.";
}
}
