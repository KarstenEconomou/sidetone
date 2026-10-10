#include "include/AudioCore.h"
#include "DSP.hpp"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

namespace {
constexpr UInt32 maximumFrames = 16384;
constexpr UInt32 maximumChannels = 128;
std::atomic<uint64_t> deviceGeneration{1};
std::atomic<uint64_t> serverGeneration{1};
std::atomic<uint64_t> outputRouteGeneration{1};
std::atomic<uint64_t> hardwareOverloads{0};
std::once_flag observerOnce;

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

template<class T> bool readProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                                  T &value, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto property = address(selector, scope);
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, &value) == noErr;
}

OSStatus propertyChanged(AudioObjectID, UInt32 count,
                         const AudioObjectPropertyAddress *properties, void *) {
    deviceGeneration.fetch_add(1, std::memory_order_relaxed);
    for (UInt32 i = 0; i < count; ++i) {
        if (properties[i].mSelector == kAudioDeviceProcessorOverload)
            hardwareOverloads.fetch_add(1, std::memory_order_relaxed);
        if (properties[i].mSelector == kAudioHardwarePropertyServiceRestarted ||
            properties[i].mSelector == kAudioDevicePropertyIOStoppedAbnormally)
            serverGeneration.fetch_add(1, std::memory_order_relaxed);
        if (properties[i].mScope == kAudioObjectPropertyScopeOutput &&
            (properties[i].mSelector == kAudioDevicePropertyDataSource ||
             properties[i].mSelector == kAudioDevicePropertyJackIsConnected ||
             properties[i].mSelector == kAudioDevicePropertyPreferredChannelsForStereo))
            outputRouteGeneration.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
}

void observeSystem() {
    std::call_once(observerOnce, [] {
        for (auto selector : {kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                              kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyServiceRestarted}) {
            auto property = address(selector);
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &property, propertyChanged, nullptr);
        }
    });
}

UInt32 channelCount(AudioDeviceID device, AudioObjectPropertyScope scope) {
    auto property = address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &property, 0, nullptr, &size) != noErr ||
        size < sizeof(AudioBufferList)) return 0;
    std::vector<unsigned char> bytes(size);
    auto *list = reinterpret_cast<AudioBufferList *>(bytes.data());
    if (AudioObjectGetPropertyData(device, &property, 0, nullptr, &size, list) != noErr) return 0;
    UInt32 count = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) count += list->mBuffers[i].mNumberChannels;
    return count;
}

void stringProperty(AudioDeviceID device, AudioObjectPropertySelector selector,
                    char *destination, size_t capacity) {
    CFStringRef value = nullptr;
    if (readProperty(device, selector, value) && value) {
        if (!CFStringGetCString(value, destination, static_cast<CFIndex>(capacity), kCFStringEncodingUTF8))
            destination[0] = '\0';
        CFRelease(value);
    }
}

bool describeDevice(AudioDeviceID device, STDevice &description) {
    description = {};
    UInt32 alive = 0;
    if (!readProperty(device, kAudioDevicePropertyDeviceIsAlive, alive) || !alive) return false;
    description.id = device;
    description.inputChannels = channelCount(device, kAudioObjectPropertyScopeInput);
    description.outputChannels = channelCount(device, kAudioObjectPropertyScopeOutput);
    if (!description.inputChannels && !description.outputChannels) return false;
    stringProperty(device, kAudioDevicePropertyDeviceUID, description.uid, sizeof(description.uid));
    stringProperty(device, kAudioObjectPropertyName, description.name, sizeof(description.name));
    readProperty(device, kAudioDevicePropertyNominalSampleRate, description.sampleRate);
    readProperty(device, kAudioDevicePropertyBufferFrameSize, description.bufferFrames);
    readProperty(device, kAudioDevicePropertyTransportType, description.transportType);
    if (description.outputChannels) {
        readProperty(device, kAudioDevicePropertyDataSource, description.outputDataSource, kAudioObjectPropertyScopeOutput);
        UInt32 connected = 0;
        if (readProperty(device, kAudioDevicePropertyJackIsConnected, connected, kAudioObjectPropertyScopeOutput))
            description.outputJackState = connected ? 2 : 1;
        description.outputRightChannel = description.outputChannels > 1 ? 1 : 0;
        UInt32 preferred[2]{};
        if (readProperty(device, kAudioDevicePropertyPreferredChannelsForStereo, preferred, kAudioObjectPropertyScopeOutput) &&
            preferred[0] && preferred[1] && preferred[0] <= description.outputChannels && preferred[1] <= description.outputChannels) {
            description.outputLeftChannel = preferred[0] - 1;
            description.outputRightChannel = preferred[1] - 1;
        }
    }
    AudioValueRange range{};
    if (readProperty(device, kAudioDevicePropertyBufferFrameSizeRange, range)) {
        description.minBufferFrames = static_cast<UInt32>(std::max(0.0, range.mMinimum));
        description.maxBufferFrames = static_cast<UInt32>(std::max(0.0, range.mMaximum));
    }
    AudioDeviceID defaultDevice = 0;
    readProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, defaultDevice);
    description.isDefaultInput = defaultDevice == device;
    readProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, defaultDevice);
    description.isDefaultOutput = defaultDevice == device;
    return true;
}

UInt32 streamLatency(AudioDeviceID device, AudioObjectPropertyScope scope) {
    auto property = address(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &property, 0, nullptr, &size) != noErr) return 0;
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (streams.empty() || AudioObjectGetPropertyData(device, &property, 0, nullptr, &size, streams.data()) != noErr)
        return 0;
    UInt32 latency = 0;
    for (auto stream : streams) {
        UInt32 current = 0;
        readProperty(stream, kAudioStreamPropertyLatency, current);
        latency = std::max(latency, current);
    }
    return latency;
}

double pathLatency(const STDevice &device, AudioObjectPropertyScope scope) {
    UInt32 latency = 0, safety = 0;
    readProperty(device.id, kAudioDevicePropertyLatency, latency, scope);
    readProperty(device.id, kAudioDevicePropertySafetyOffset, safety, scope);
    return (static_cast<double>(device.bufferFrames) + latency + safety + streamLatency(device.id, scope)) /
        device.sampleRate * 1000.0;
}

AudioStreamBasicDescription clientFormat(double rate, UInt32 channels) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    format.mBytesPerPacket = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float);
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    return format;
}

struct BufferChange { AudioDeviceID device{}; UInt32 previous{}, applied{}; char uid[256]{}; };
struct Listener { AudioObjectID object{}; AudioObjectPropertyAddress property{}; };
struct FreeList { void operator()(AudioBufferList *pointer) const noexcept { std::free(pointer); } };

void clearOutput(AudioBufferList *output) noexcept {
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData)
            std::memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
}
}

// The control thread owns units and storage. AudioOutputUnitStop ends callback access.
struct STEngine {
    AudioUnit inputUnit{}, outputUnit{};
    STConfiguration configuration{};
    STDevice input{}, output{};
    bool sharedUnit{};
    bool running{};
    uint64_t observedGeneration{}, observedServer{}, observedRoute{}, initialHardwareOverloads{};
    double tickMs{}, deviceLatencyMs{}, inputDeviceLatencyMs{}, outputDeviceLatencyMs{};
    uint64_t previousInputCallbacks{}, previousOutputCallbacks{}, inputProgressTime{}, outputProgressTime{};
    UInt32 outputLeft{}, outputRight{1};
    std::vector<float> inputStorage, inputMono, outputMono;
    std::unique_ptr<AudioBufferList, FreeList> inputList;
    std::vector<Listener> listeners;
    std::vector<BufferChange> bufferChanges;
    sidetone::DSP dsp;
    sidetone::AdaptiveTransport transport;
    std::atomic<UInt32> restart{0};
    std::atomic<OSStatus> callbackError{noErr};
    std::atomic<double> inputPeak{0}, outputPeak{0}, maxInputMs{0}, maxOutputMs{0}, maxDSPMs{0};
    std::atomic<uint64_t> inputCallbacks{0}, outputCallbacks{0}, inputMisses{0}, outputMisses{0};
    char error[512]{};

    STEngine() {
        initialHardwareOverloads = hardwareOverloads.load(std::memory_order_relaxed);
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        tickMs = static_cast<double>(timebase.numer) / timebase.denom / 1000000.0;
    }

    bool check(OSStatus result, const char *operation) {
        if (result == noErr) return true;
        char code[5] = {static_cast<char>((static_cast<UInt32>(result) >> 24) & 255),
                        static_cast<char>((static_cast<UInt32>(result) >> 16) & 255),
                        static_cast<char>((static_cast<UInt32>(result) >> 8) & 255),
                        static_cast<char>(static_cast<UInt32>(result) & 255), '\0'};
        for (int i = 0; i < 4; ++i) if (code[i] < 32 || code[i] > 126) code[i] = '?';
        std::snprintf(error, sizeof(error), "%s failed (Core Audio %d, '%s').", operation, static_cast<int>(result), code);
        return false;
    }

    void measure(uint64_t start, UInt32 frames, double rate, std::atomic<double> &maximum,
                 std::atomic<uint64_t> &misses) noexcept {
        const double duration = static_cast<double>(mach_absolute_time() - start) * tickMs;
        if (duration > maximum.load(std::memory_order_relaxed)) maximum.store(duration, std::memory_order_relaxed);
        if (duration > static_cast<double>(frames) / rate * 1000.0) misses.fetch_add(1, std::memory_order_relaxed);
    }

    bool capture(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 frames) noexcept {
        if (frames > maximumFrames) { restart.store(1, std::memory_order_relaxed); return false; }
        for (UInt32 channel = 0; channel < input.inputChannels; ++channel) {
            auto &buffer = inputList->mBuffers[channel];
            buffer.mData = inputStorage.data() + static_cast<size_t>(channel) * maximumFrames;
            buffer.mDataByteSize = frames * sizeof(float);
        }
        const OSStatus result = AudioUnitRender(inputUnit, flags, timestamp, 1, frames, inputList.get());
        if (result != noErr) {
            callbackError.store(result, std::memory_order_relaxed);
            restart.store(1, std::memory_order_relaxed);
            return false;
        }
        const auto &selected = inputList->mBuffers[configuration.inputChannel];
        if (!selected.mData || selected.mDataByteSize < frames * sizeof(float)) {
            restart.store(1, std::memory_order_relaxed);
            return false;
        }
        const auto *samples = static_cast<const float *>(selected.mData);
        double peak = 0;
        for (UInt32 frame = 0; frame < frames; ++frame) {
            const float value = std::isfinite(samples[frame]) ? samples[frame] : 0.0f;
            inputMono[frame] = value;
            peak = std::max(peak, static_cast<double>(std::abs(value)));
        }
        if (peak > inputPeak.load(std::memory_order_relaxed)) inputPeak.store(peak, std::memory_order_relaxed);
        inputCallbacks.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    static OSStatus inputCallback(void *context, AudioUnitRenderActionFlags *flags,
                                  const AudioTimeStamp *timestamp, UInt32, UInt32 frames, AudioBufferList *) noexcept {
        auto &engine = *static_cast<STEngine *>(context);
        const uint64_t start = mach_absolute_time();
        if (engine.capture(flags, timestamp, frames)) engine.transport.push(engine.inputMono.data(), frames);
        engine.measure(start, frames, engine.input.sampleRate, engine.maxInputMs, engine.inputMisses);
        return noErr;
    }

    static OSStatus outputCallback(void *context, AudioUnitRenderActionFlags *flags,
                                   const AudioTimeStamp *timestamp, UInt32, UInt32 frames,
                                   AudioBufferList *buffers) noexcept {
        auto &engine = *static_cast<STEngine *>(context);
        const uint64_t start = mach_absolute_time();
        clearOutput(buffers);
        engine.outputCallbacks.fetch_add(1, std::memory_order_relaxed);
        if (serverGeneration.load(std::memory_order_relaxed) != engine.observedServer) {
            engine.restart.fetch_or(1, std::memory_order_relaxed);
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
        if (outputRouteGeneration.load(std::memory_order_relaxed) != engine.observedRoute) {
            engine.restart.fetch_or(2, std::memory_order_relaxed);
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
        if (frames > maximumFrames || engine.restart.load(std::memory_order_relaxed)) {
            engine.restart.fetch_or(1, std::memory_order_relaxed);
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
        if (engine.sharedUnit) {
            if (!engine.capture(flags, timestamp, frames)) return noErr;
            std::copy_n(engine.inputMono.data(), frames, engine.outputMono.data());
        } else {
            engine.transport.render(engine.outputMono.data(), frames);
        }
        const uint64_t dspStart = mach_absolute_time();
        engine.dsp.process(engine.outputMono.data(), frames);
        const double dspMs = static_cast<double>(mach_absolute_time() - dspStart) * engine.tickMs;
        if (dspMs > engine.maxDSPMs.load(std::memory_order_relaxed)) engine.maxDSPMs.store(dspMs, std::memory_order_relaxed);
        double peak = 0;
        for (UInt32 frame = 0; frame < frames; ++frame)
            peak = std::max(peak, static_cast<double>(std::abs(engine.outputMono[frame])));
        if (peak > engine.outputPeak.load(std::memory_order_relaxed)) engine.outputPeak.store(peak, std::memory_order_relaxed);
        if (peak > 0) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        else *flags |= kAudioUnitRenderAction_OutputIsSilence;
        UInt32 firstChannel = 0;
        if (buffers) for (UInt32 b = 0; b < buffers->mNumberBuffers; ++b) {
            auto &buffer = buffers->mBuffers[b];
            auto *samples = static_cast<float *>(buffer.mData);
            const UInt32 channels = buffer.mNumberChannels;
            const UInt32 availableFrames = channels ? buffer.mDataByteSize / (channels * sizeof(float)) : 0;
            if (samples) for (UInt32 channel = 0; channel < channels; ++channel)
                if (firstChannel + channel == engine.outputLeft || firstChannel + channel == engine.outputRight)
                    for (UInt32 frame = 0; frame < std::min(frames, availableFrames); ++frame)
                        samples[static_cast<size_t>(frame) * channels + channel] = engine.outputMono[frame];
            firstChannel += channels;
        }
        engine.measure(start, frames, engine.output.sampleRate, engine.maxOutputMs, engine.outputMisses);
        return noErr;
    }

    void observe(AudioDeviceID device, AudioObjectPropertySelector selector,
                 AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
        auto property = address(selector, scope);
        if (AudioObjectHasProperty(device, &property) &&
            AudioObjectAddPropertyListener(device, &property, propertyChanged, nullptr) == noErr)
            listeners.push_back({device, property});
    }

    void observeDevice(AudioDeviceID device, bool isOutput) {
        observe(device, kAudioDevicePropertyDeviceIsAlive);
        observe(device, kAudioDevicePropertyIOStoppedAbnormally);
        observe(device, kAudioDeviceProcessorOverload);
        observe(device, kAudioDevicePropertyNominalSampleRate);
        observe(device, kAudioDevicePropertyBufferFrameSize);
        observe(device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
        observe(device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
        if (isOutput) {
            observe(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput);
            observe(device, kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput);
            observe(device, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput);
        }
    }

    void setBuffer(STDevice &device, UInt32 requested) {
        if (!requested || !device.minBufferFrames || device.minBufferFrames > device.maxBufferFrames) return;
        requested = std::clamp(requested, device.minBufferFrames, device.maxBufferFrames);
        if (requested == device.bufferFrames) return;
        auto property = address(kAudioDevicePropertyBufferFrameSize);
        Boolean settable = false;
        if (AudioObjectIsPropertySettable(device.id, &property, &settable) != noErr || !settable) return;
        const UInt32 previous = device.bufferFrames;
        if (AudioObjectSetPropertyData(device.id, &property, 0, nullptr, sizeof(requested), &requested) == noErr) {
            readProperty(device.id, kAudioDevicePropertyBufferFrameSize, device.bufferFrames);
            BufferChange change{device.id, previous, device.bufferFrames, {}};
            std::memcpy(change.uid, device.uid, sizeof(change.uid));
            bufferChanges.push_back(change);
        }
    }

    bool makeUnit(AudioUnit &unit, AudioDeviceID device, bool enableInput, bool enableOutput) {
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_HALOutput;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent component = AudioComponentFindNext(nullptr, &description);
        if (!component) { std::snprintf(error, sizeof(error), "The HAL audio component is not available."); return false; }
        if (!check(AudioComponentInstanceNew(component, &unit), "Create audio unit")) return false;
        UInt32 enabled = enableInput ? 1 : 0;
        if (!check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                        &enabled, sizeof(enabled)), "Set microphone input")) return false;
        enabled = enableOutput ? 1 : 0;
        if (!check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                        &enabled, sizeof(enabled)), "Set audio output")) return false;
        if (!check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                        &device, sizeof(device)), "Select audio device")) return false;
        UInt32 limit = maximumFrames;
        if (!check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                        &limit, sizeof(limit)), "Set callback capacity")) return false;
        if (enableInput) {
            auto format = clientFormat(input.sampleRate, input.inputChannels);
            if (!check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                            &format, sizeof(format)), "Set microphone format")) return false;
            UInt32 allocate = 0;
            AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1,
                                 &allocate, sizeof(allocate));
            if (!enableOutput) {
                AURenderCallbackStruct callback{inputCallback, this};
                if (!check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, sizeof(callback)), "Set input callback")) return false;
            }
        }
        if (enableOutput) {
            auto format = clientFormat(output.sampleRate, output.outputChannels);
            if (!check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                            &format, sizeof(format)), "Set output format")) return false;
            AURenderCallbackStruct callback{outputCallback, this};
            if (!check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                            &callback, sizeof(callback)), "Set output callback")) return false;
        }
        return check(AudioUnitInitialize(unit), "Initialize audio unit");
    }

    void stop() {
        running = false;
        if (outputUnit) AudioOutputUnitStop(outputUnit);
        if (inputUnit && inputUnit != outputUnit) AudioOutputUnitStop(inputUnit);
        if (outputUnit) { AudioUnitUninitialize(outputUnit); AudioComponentInstanceDispose(outputUnit); }
        if (inputUnit && inputUnit != outputUnit) { AudioUnitUninitialize(inputUnit); AudioComponentInstanceDispose(inputUnit); }
        inputUnit = nullptr;
        outputUnit = nullptr;
        for (const auto &listener : listeners)
            AudioObjectRemovePropertyListener(listener.object, &listener.property, propertyChanged, nullptr);
        listeners.clear();
        for (const auto &change : bufferChanges) {
            char currentUID[256]{};
            stringProperty(change.device, kAudioDevicePropertyDeviceUID, currentUID, sizeof(currentUID));
            if (!currentUID[0] || std::strncmp(currentUID, change.uid, sizeof(currentUID)) != 0) continue;
            UInt32 current = 0;
            if (readProperty(change.device, kAudioDevicePropertyBufferFrameSize, current) && current == change.applied) {
                auto property = address(kAudioDevicePropertyBufferFrameSize);
                AudioObjectSetPropertyData(change.device, &property, 0, nullptr, sizeof(change.previous), &change.previous);
            }
        }
        bufferChanges.clear();
        inputStorage.clear();
        inputMono.clear();
        outputMono.clear();
        inputList.reset();
        restart.store(0, std::memory_order_relaxed);
        inputPeak.store(0, std::memory_order_relaxed);
        outputPeak.store(0, std::memory_order_relaxed);
    }

    bool matchesRoute(const STDevice &currentInput, const STDevice &currentOutput,
                      const STRouteIdentity &identity) {
        if (!identity.inputUID[0] || std::strncmp(currentInput.uid, identity.inputUID, sizeof(identity.inputUID)) != 0) {
            std::snprintf(error, sizeof(error), "The selected microphone identity changed. Select the microphone again.");
            return false;
        }
        if (!identity.outputUID[0] || std::strncmp(currentOutput.uid, identity.outputUID, sizeof(identity.outputUID)) != 0) {
            std::snprintf(error, sizeof(error), "The selected output identity changed. Select the output again.");
            return false;
        }
        if (currentOutput.outputDataSource != identity.outputDataSource ||
            currentOutput.outputJackState != identity.outputJackState) {
            std::snprintf(error, sizeof(error), "The output connection changed. Check the headphones and start monitoring again.");
            return false;
        }
        if (currentOutput.outputLeftChannel != identity.outputLeftChannel ||
            currentOutput.outputRightChannel != identity.outputRightChannel) {
            std::snprintf(error, sizeof(error), "The output channels changed. Check the headphones and start monitoring again.");
            return false;
        }
        return true;
    }

    bool start(STConfiguration requested, const STRouteIdentity *identity = nullptr) {
        stop();
        error[0] = '\0';
        callbackError.store(noErr, std::memory_order_relaxed);
        observeSystem();
        configuration = requested;
        if (!requested.inputDevice) readProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, configuration.inputDevice);
        if (!requested.outputDevice) readProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, configuration.outputDevice);
        if (!describeDevice(configuration.inputDevice, input) || !input.inputChannels) {
            std::snprintf(error, sizeof(error), "The selected microphone is not available."); return false;
        }
        if (!describeDevice(configuration.outputDevice, output) || !output.outputChannels) {
            std::snprintf(error, sizeof(error), "The selected audio output is not available."); return false;
        }
        if (identity && !matchesRoute(input, output, *identity)) return false;
        if (input.inputChannels > maximumChannels || output.outputChannels > maximumChannels ||
            input.sampleRate < 8000 || input.sampleRate > 768000 || output.sampleRate < 8000 || output.sampleRate > 768000 ||
            !std::isfinite(input.sampleRate) || !std::isfinite(output.sampleRate)) {
            std::snprintf(error, sizeof(error), "This device format is not supported (8–768 kHz, up to 128 channels)."); return false;
        }
        if (configuration.inputChannel >= input.inputChannels) {
            std::snprintf(error, sizeof(error), "The selected microphone channel is not available."); return false;
        }
        setBuffer(input, configuration.bufferFrames);
        if (input.id != output.id) setBuffer(output, configuration.bufferFrames);
        else output.bufferFrames = input.bufferFrames;
        if (input.bufferFrames > maximumFrames || output.bufferFrames > maximumFrames) {
            std::snprintf(error, sizeof(error), "The device buffer exceeds the 16384-frame limit."); return false;
        }
        sharedUnit = input.id == output.id;
        if (!sharedUnit && !sidetone::AdaptiveTransport::supportsConfiguration(
                input.sampleRate, output.sampleRate, input.bufferFrames, output.bufferFrames)) {
            std::snprintf(error, sizeof(error), "This rate and buffer combination exceeds the audio transport capacity. Select a smaller buffer.");
            return false;
        }
        inputStorage.resize(static_cast<size_t>(input.inputChannels) * maximumFrames);
        inputMono.resize(maximumFrames);
        outputMono.resize(maximumFrames);
        inputList.reset(static_cast<AudioBufferList *>(std::calloc(1, offsetof(AudioBufferList, mBuffers) +
                                                                    sizeof(AudioBuffer) * input.inputChannels)));
        if (!inputList) throw std::bad_alloc();
        inputList->mNumberBuffers = input.inputChannels;
        for (UInt32 channel = 0; channel < input.inputChannels; ++channel) inputList->mBuffers[channel].mNumberChannels = 1;
        outputLeft = output.outputLeftChannel;
        outputRight = output.outputRightChannel;
        dsp.prepare(output.sampleRate);
        if (!sharedUnit) transport.prepare(input.sampleRate, output.sampleRate, input.bufferFrames, output.bufferFrames);
        inputCallbacks.store(0); outputCallbacks.store(0); inputMisses.store(0); outputMisses.store(0);
        maxInputMs.store(0); maxOutputMs.store(0); maxDSPMs.store(0);
        const double inputPathMs = pathLatency(input, kAudioObjectPropertyScopeInput);
        const double outputPathMs = pathLatency(output, kAudioObjectPropertyScopeOutput);
        inputDeviceLatencyMs = inputPathMs - static_cast<double>(input.bufferFrames) / input.sampleRate * 1000.0;
        outputDeviceLatencyMs = outputPathMs - static_cast<double>(output.bufferFrames) / output.sampleRate * 1000.0;
        deviceLatencyMs = inputPathMs + outputPathMs;
        observeDevice(input.id, sharedUnit);
        if (!sharedUnit) observeDevice(output.id, true);
        observedGeneration = deviceGeneration.load(std::memory_order_relaxed);
        observedServer = serverGeneration.load(std::memory_order_relaxed);
        observedRoute = outputRouteGeneration.load(std::memory_order_relaxed);
        initialHardwareOverloads = hardwareOverloads.load(std::memory_order_relaxed);
        if (sharedUnit) {
            if (!makeUnit(inputUnit, input.id, true, true)) return false;
            outputUnit = inputUnit;
        } else {
            if (!makeUnit(inputUnit, input.id, true, false) || !makeUnit(outputUnit, output.id, false, true)) return false;
        }
        STDevice currentInput{}, currentOutput{};
        if (!describeDevice(input.id, currentInput) || !describeDevice(output.id, currentOutput)) {
            std::snprintf(error, sizeof(error), "The audio device is no longer available. Select the devices again."); return false;
        }
        if (identity && !matchesRoute(currentInput, currentOutput, *identity)) return false;
        if (currentInput.inputChannels != input.inputChannels || currentOutput.outputChannels != output.outputChannels ||
            currentOutput.outputLeftChannel != output.outputLeftChannel ||
            currentOutput.outputRightChannel != output.outputRightChannel ||
            currentInput.sampleRate != input.sampleRate || currentOutput.sampleRate != output.sampleRate ||
            currentInput.bufferFrames != input.bufferFrames || currentOutput.bufferFrames != output.bufferFrames) {
            std::snprintf(error, sizeof(error), "The audio device changed during setup. Start monitoring again."); return false;
        }
        if (!sharedUnit && !check(AudioOutputUnitStart(inputUnit), "Start microphone")) return false;
        if (!check(AudioOutputUnitStart(outputUnit), "Start audio output")) return false;
        previousInputCallbacks = previousOutputCallbacks = 0;
        inputProgressTime = outputProgressTime = mach_absolute_time();
        running = true;
        return true;
    }

    STTelemetry telemetry() {
        if (running) {
            const auto now = mach_absolute_time();
            const auto inputCount = inputCallbacks.load(std::memory_order_relaxed);
            const auto outputCount = outputCallbacks.load(std::memory_order_relaxed);
            if (inputCount != previousInputCallbacks) { previousInputCallbacks = inputCount; inputProgressTime = now; }
            if (outputCount != previousOutputCallbacks) { previousOutputCallbacks = outputCount; outputProgressTime = now; }
            const double inputTimeoutMs = std::max(1000.0, 4000.0 * input.bufferFrames / input.sampleRate);
            const double outputTimeoutMs = std::max(1000.0, 4000.0 * output.bufferFrames / output.sampleRate);
            if (static_cast<double>(now - inputProgressTime) * tickMs > inputTimeoutMs ||
                static_cast<double>(now - outputProgressTime) * tickMs > outputTimeoutMs)
                restart.fetch_or(1, std::memory_order_relaxed);
            if (serverGeneration.load(std::memory_order_relaxed) != observedServer) restart.fetch_or(1, std::memory_order_relaxed);
            if (outputRouteGeneration.load(std::memory_order_relaxed) != observedRoute) restart.fetch_or(2, std::memory_order_relaxed);
            const auto generation = deviceGeneration.load(std::memory_order_relaxed);
            if (generation != observedGeneration) {
                observedGeneration = generation;
                STDevice currentInput{}, currentOutput{};
                if (!describeDevice(input.id, currentInput) || !describeDevice(output.id, currentOutput) ||
                    currentInput.inputChannels != input.inputChannels || currentOutput.outputChannels != output.outputChannels ||
                    currentInput.sampleRate != input.sampleRate || currentOutput.sampleRate != output.sampleRate ||
                    currentInput.bufferFrames != input.bufferFrames || currentOutput.bufferFrames != output.bufferFrames)
                    restart.fetch_or(1, std::memory_order_relaxed);
            }
        }
        STTelemetry result{};
        result.running = running;
        result.needsRestart = restart.load(std::memory_order_relaxed);
        result.inputRate = input.sampleRate;
        result.outputRate = output.sampleRate;
        result.inputBufferFrames = input.bufferFrames;
        result.outputBufferFrames = output.bufferFrames;
        result.queueLatencyMs = sharedUnit ? 0 : transport.queueLatencyMs();
        result.inputDeviceLatencyMs = inputDeviceLatencyMs;
        result.outputDeviceLatencyMs = outputDeviceLatencyMs;
        result.resamplerLatencyMs = sharedUnit ? 0 : transport.resamplerLatencyMs();
        result.estimatedLatencyMs = deviceLatencyMs + result.queueLatencyMs + result.resamplerLatencyMs;
        result.peakInput = inputPeak.exchange(0, std::memory_order_relaxed);
        result.peakOutput = outputPeak.exchange(0, std::memory_order_relaxed);
        result.maxCallbackMs = std::max(maxInputMs.load(std::memory_order_relaxed), maxOutputMs.load(std::memory_order_relaxed));
        result.maxDSPMs = maxDSPMs.load(std::memory_order_relaxed);
        result.driftPPM = sharedUnit ? 0 : transport.driftPPM();
        result.inputCallbacks = inputCallbacks.load(std::memory_order_relaxed);
        result.outputCallbacks = outputCallbacks.load(std::memory_order_relaxed);
        result.underruns = sharedUnit ? 0 : transport.underruns();
        result.overruns = sharedUnit ? 0 : transport.overruns();
        result.deadlineMisses = inputMisses.load(std::memory_order_relaxed) + outputMisses.load(std::memory_order_relaxed);
        result.clippedSamples = dsp.clippedSamples();
        result.hardwareOverloads = hardwareOverloads.load(std::memory_order_relaxed) - initialHardwareOverloads;
        return result;
    }
};

extern "C" {
uint32_t st_devices(STDevice *devices, uint32_t capacity) {
    try {
        observeSystem();
        auto property = address(kAudioHardwarePropertyDevices);
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, nullptr, &size) != noErr) return 0;
        std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
        if (ids.empty() || AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, nullptr, &size, ids.data()) != noErr) return 0;
        uint32_t count = 0;
        for (auto id : ids) {
            STDevice device{};
            if (!describeDevice(id, device)) continue;
            if (devices && count < capacity) devices[count] = device;
            ++count;
        }
        return count;
    } catch (...) { return 0; }
}
uint64_t st_device_generation(void) { observeSystem(); return deviceGeneration.load(std::memory_order_relaxed); }
STEngine *st_engine_create(void) { try { return new STEngine(); } catch (...) { return nullptr; } }
void st_engine_destroy(STEngine *engine) { if (engine) { engine->stop(); delete engine; } }
int32_t st_engine_start(STEngine *engine, STConfiguration configuration) {
    if (!engine) return -1;
    try {
        if (engine->start(configuration)) return 0;
    } catch (...) { std::snprintf(engine->error, sizeof(engine->error), "The audio engine could not allocate its buffers."); }
    engine->stop();
    return -1;
}
int32_t st_engine_start_checked(STEngine *engine, STConfiguration configuration, STRouteIdentity identity) {
    if (!engine) return -1;
    try {
        if (engine->start(configuration, &identity)) return 0;
    } catch (...) { std::snprintf(engine->error, sizeof(engine->error), "The audio engine could not allocate its buffers."); }
    engine->stop();
    return -1;
}
void st_engine_stop(STEngine *engine) { if (engine) engine->stop(); }
void st_engine_set_parameters(STEngine *engine, STParameters parameters) { if (engine) engine->dsp.setParameters(parameters); }
STTelemetry st_engine_telemetry(STEngine *engine) {
    if (!engine) return {};
    try { return engine->telemetry(); }
    catch (...) {
        std::snprintf(engine->error, sizeof(engine->error), "The audio device status is not available.");
        engine->restart.fetch_or(1, std::memory_order_relaxed);
        STTelemetry result{};
        result.running = engine->running;
        result.needsRestart = engine->restart.load(std::memory_order_relaxed);
        return result;
    }
}
const char *st_engine_error(STEngine *engine) {
    if (!engine) return "The audio engine is not available.";
    const auto callbackError = engine->callbackError.load(std::memory_order_relaxed);
    if (callbackError != noErr) engine->check(callbackError, "Read microphone audio");
    return engine->error;
}
}
