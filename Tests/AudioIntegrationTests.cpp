#include "../Sources/AudioCore/include/AudioCore.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>

namespace {
void require(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}
}

int main() {
    st_engine_stop(nullptr);
    st_engine_destroy(nullptr);
    st_engine_set_parameters(nullptr, {});
    require(st_engine_start(nullptr, {}) != 0, "A null engine must reject start.");
    require(st_engine_telemetry(nullptr).running == 0, "A null engine must not report running.");
    require(std::strlen(st_engine_error(nullptr)) > 0, "A null engine must supply an error.");

    constexpr auto unavailable = std::numeric_limits<uint32_t>::max();
    for (unsigned iteration = 0; iteration < 100; ++iteration) {
        auto *engine = st_engine_create();
        require(engine != nullptr, "Engine creation must succeed.");
        for (unsigned restart = 0; restart < 10; ++restart) {
            const STConfiguration configuration{unavailable, unavailable, 0, 64};
            require(st_engine_start(engine, configuration) != 0, "An unavailable microphone must reject start.");
            require(std::strstr(st_engine_error(engine), "microphone") != nullptr,
                    "The failure must identify the unavailable microphone.");
            auto telemetry = st_engine_telemetry(engine);
            require(!telemetry.running && !telemetry.inputCallbacks && !telemetry.outputCallbacks,
                    "A failed start must not capture or play audio.");
            st_engine_stop(engine);
            st_engine_stop(engine);
            require(!st_engine_telemetry(engine).running, "Repeated stop must keep the engine stopped.");
        }
        st_engine_destroy(engine);
    }

    const uint32_t count = st_devices(nullptr, 0);
    std::vector<STDevice> devices(count + 1);
    std::memset(&devices[count], 0x5a, sizeof(STDevice));
    STDevice guard = devices[count];
    const uint32_t discovered = st_devices(devices.data(), count);
    require(std::memcmp(&devices[count], &guard, sizeof(STDevice)) == 0,
            "Device enumeration must respect the destination capacity.");
    devices.resize(std::min(count, discovered));
    const auto input = std::find_if(devices.begin(), devices.end(), [](const STDevice &d) { return d.inputChannels > 0; });
    const auto output = std::find_if(devices.begin(), devices.end(), [](const STDevice &d) { return d.outputChannels > 0; });
    if (input != devices.end()) {
        auto *engine = st_engine_create();
        require(engine != nullptr, "Engine creation must succeed with devices present.");
        require(st_engine_start(engine, {input->id, unavailable, 0, 64}) != 0,
                "An unavailable output must reject start.");
        require(std::strstr(st_engine_error(engine), "output") != nullptr,
                "The failure must identify the unavailable output.");
        if (output != devices.end()) {
            require(st_engine_start(engine, {input->id, output->id, input->inputChannels, 64}) != 0,
                    "An unavailable microphone channel must reject start.");
            require(std::strstr(st_engine_error(engine), "channel") != nullptr,
                    "The failure must identify the unavailable channel.");
        }
        require(!st_engine_telemetry(engine).running, "Invalid device settings must leave capture stopped.");
        st_engine_destroy(engine);
    }
    std::printf("Audio lifecycle tests passed: 1000 failed starts, repeated stop, null API, bounded enumeration.");
    if (input != devices.end()) std::printf(" Unavailable output and channel checks used current devices.");
    else std::printf(" Device-dependent checks skipped: no input device is visible.");
    std::printf("\n");
    return 0;
}
