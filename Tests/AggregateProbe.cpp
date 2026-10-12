#include "../Sources/AudioCore/include/AudioCore.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>
#include <vector>

namespace {
using CF = std::unique_ptr<const void, decltype(&CFRelease)>;
CF number(int value) {
    return CF(CFNumberCreate(nullptr, kCFNumberIntType, &value), CFRelease);
}
CF string(const char* value) {
    return CF(CFStringCreateWithCString(nullptr, value, kCFStringEncodingUTF8), CFRelease);
}
CF subdevice(CFStringRef uid, bool drift) {
    auto enabled = number(drift ? 1 : 0);
    const void* keys[] = {CFSTR(kAudioSubDeviceUIDKey), CFSTR(kAudioSubDeviceDriftCompensationKey)};
    const void* values[] = {uid, enabled.get()};
    return CF(CFDictionaryCreate(nullptr, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                 &kCFTypeDictionaryValueCallBacks),
              CFRelease);
}
struct Aggregate {
    AudioObjectID id{};
    ~Aggregate() {
        if (id)
            AudioHardwareDestroyAggregateDevice(id);
    }
};
} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr,
                     "Usage: AggregateProbe INPUT_ID OUTPUT_ID [SECONDS] [BUFFER_FRAMES]\n"
                     "Use separate input-only and output-only devices. Playback gain is -60 dB.\n");
        return 2;
    }
    const auto inputID = static_cast<uint32_t>(std::strtoul(argv[1], nullptr, 10));
    const auto outputID = static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 10));
    const int seconds = argc > 3 ? std::clamp(std::atoi(argv[3]), 1, 3600) : 5;
    const auto buffer = argc > 4 ? static_cast<uint32_t>(std::strtoul(argv[4], nullptr, 10)) : 64;
    std::vector<STDevice> devices(st_devices(nullptr, 0));
    devices.resize(std::min(static_cast<uint32_t>(devices.size()),
                            st_devices(devices.data(), static_cast<uint32_t>(devices.size()))));
    const auto input = std::find_if(devices.begin(), devices.end(),
                                    [inputID](const auto& device) { return device.id == inputID; });
    const auto output =
        std::find_if(devices.begin(), devices.end(),
                     [outputID](const auto& device) { return device.id == outputID; });
    if (input == devices.end() || output == devices.end() || !input->inputChannels ||
        input->outputChannels || !output->outputChannels || output->inputChannels) {
        std::fprintf(
            stderr, "Select an available input-only device and an available output-only device.\n");
        return 2;
    }
    auto inputUID = string(input->uid);
    auto outputUID = string(output->uid);
    auto inputSubdevice = subdevice(static_cast<CFStringRef>(inputUID.get()), true);
    auto outputSubdevice = subdevice(static_cast<CFStringRef>(outputUID.get()), false);
    const void* subdevices[] = {inputSubdevice.get(), outputSubdevice.get()};
    CF list(CFArrayCreate(nullptr, subdevices, 2, &kCFTypeArrayCallBacks), CFRelease);
    CF uuid(CFUUIDCreate(nullptr), CFRelease);
    CF aggregateUID(CFUUIDCreateString(nullptr, static_cast<CFUUIDRef>(uuid.get())), CFRelease);
    auto privateDevice = number(1);
    const void* keys[] = {CFSTR(kAudioAggregateDeviceUIDKey), CFSTR(kAudioAggregateDeviceNameKey),
                          CFSTR(kAudioAggregateDeviceSubDeviceListKey),
                          CFSTR(kAudioAggregateDeviceMainSubDeviceKey),
                          CFSTR(kAudioAggregateDeviceIsPrivateKey)};
    const void* values[] = {aggregateUID.get(), CFSTR("Sidetone private audio test"), list.get(),
                            outputUID.get(), privateDevice.get()};
    CF composition(CFDictionaryCreate(nullptr, keys, values, 5, &kCFTypeDictionaryKeyCallBacks,
                                      &kCFTypeDictionaryValueCallBacks),
                   CFRelease);
    Aggregate aggregate;
    const auto status = AudioHardwareCreateAggregateDevice(
        static_cast<CFDictionaryRef>(composition.get()), &aggregate.id);
    if (status != noErr) {
        std::fprintf(stderr, "Private aggregate creation failed: %d\n", status);
        return 1;
    }
    std::printf("Private aggregate %u: %s -> %s; output clock; input drift correction enabled.\n",
                aggregate.id, input->name, output->name);
    std::unique_ptr<STEngine, decltype(&st_engine_destroy)> engine(st_engine_create(),
                                                                   st_engine_destroy);
    if (!engine)
        return 1;
    st_engine_set_parameters(engine.get(), {-60, 0, 80, 2500, 0, 0.7f, 0, 0, 0.85f});
    if (st_engine_start(engine.get(), {aggregate.id, aggregate.id, 0, buffer}) != 0) {
        std::fprintf(stderr, "Engine start failed: %s\n", st_engine_error(engine.get()));
        return 1;
    }
    bool success = true;
    for (int tick = 0; tick < seconds; ++tick) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        const auto telemetry = st_engine_telemetry(engine.get());
        std::printf("second=%d frames=%u/%u rate=%.0f/%.0f callbacks=%llu/%llu inputPeak=%.6f "
                    "outputPeak=%.6f "
                    "estimateMs=%.3f queueMs=%.3f resamplerMs=%.3f callbackMs=%.4f dspMs=%.4f "
                    "restart=%u processingOverruns=%llu hardwareOverloads=%llu\n",
                    tick + 1, telemetry.inputBufferFrames, telemetry.outputBufferFrames,
                    telemetry.inputRate, telemetry.outputRate,
                    static_cast<unsigned long long>(telemetry.inputCallbacks),
                    static_cast<unsigned long long>(telemetry.outputCallbacks), telemetry.peakInput,
                    telemetry.peakOutput, telemetry.estimatedLatencyMs, telemetry.queueLatencyMs,
                    telemetry.resamplerLatencyMs, telemetry.maxCallbackMs, telemetry.maxDSPMs,
                    telemetry.needsRestart,
                    static_cast<unsigned long long>(telemetry.deadlineMisses),
                    static_cast<unsigned long long>(telemetry.hardwareOverloads));
        std::fflush(stdout);
        if (telemetry.needsRestart || !telemetry.inputCallbacks || !telemetry.outputCallbacks) {
            std::fprintf(stderr, "Audio did not run continuously: %s\n",
                         st_engine_error(engine.get()));
            success = false;
            break;
        }
    }
    st_engine_stop(engine.get());
    std::printf("Stopped. The private aggregate is removed at process exit.\n");
    return success ? 0 : 1;
}
