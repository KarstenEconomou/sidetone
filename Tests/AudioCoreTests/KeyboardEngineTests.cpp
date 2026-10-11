#include "include/AudioCore.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}
}

int main() {
    st_keyboard_stop(nullptr);
    st_keyboard_destroy(nullptr);
    st_keyboard_play(nullptr, 0);
    st_keyboard_set_gain(nullptr, 0);
    require(st_keyboard_start(nullptr, 0, nullptr) != 0, "null engine rejects start");
    require(st_keyboard_load_sample(nullptr, 0, nullptr, 0, 0) != 0, "null engine rejects load");
    require(!st_keyboard_running(nullptr), "null engine is stopped");
    require(st_keyboard_telemetry(nullptr).callbacks == 0, "null engine has no callbacks");
    require(std::strlen(st_keyboard_error(nullptr)) > 0, "null engine reports an error");
    auto* engine = st_keyboard_create();
    require(engine != nullptr, "create keyboard engine");
    const std::array<float, 256> silence{};
    require(st_keyboard_load_sample(engine, 0, silence.data(), 128, 48000) == 0, "load silence");
    for (int i = 0; i < 50; ++i) {
        require(st_keyboard_start(engine, std::numeric_limits<uint32_t>::max(), "absent") != 0,
                "reject an unavailable output");
        st_keyboard_play(engine, 0);
        st_keyboard_stop(engine);
        st_keyboard_stop(engine);
        require(!st_keyboard_running(engine), "failed start stays stopped");
        require(st_keyboard_telemetry(engine).callbacks == 0, "failed start produces no output");
    }
    if (std::getenv("SIDETONE_KEYBOARD_LIVE_TEST")) {
        std::vector<STDevice> devices(st_devices(nullptr, 0));
        devices.resize(std::min(size_t(st_devices(devices.data(), uint32_t(devices.size()))), devices.size()));
        const auto output = std::find_if(devices.begin(), devices.end(), [](const auto& device) {
            return device.isDefaultOutput && device.outputChannels > 0;
        });
        require(output != devices.end(), "default output is available for the live check");
        for (int session = 0; session < 3; ++session) {
            require(st_keyboard_start(engine, output->id, "changed-uid") != 0, "reject a changed output UID");
            require(st_keyboard_start(engine, output->id, output->uid) == 0, st_keyboard_error(engine));
            require(st_keyboard_load_sample(engine, 0, silence.data(), 128, 48000) != 0,
                    "reject sample writes while output runs");
            for (int event = 0; event < 100; ++event) {
                st_keyboard_play(engine, 0);
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            const bool running = st_keyboard_running(engine);
            st_keyboard_stop(engine);
            const auto metrics = st_keyboard_telemetry(engine);
            std::cout << "Silent live session " << session + 1 << ": " << metrics.outputRate
                      << " Hz / " << metrics.outputBufferFrames << " frames; callbacks " << metrics.callbacks
                      << "; max callback " << metrics.maxCallbackMs << " ms; max queue "
                      << metrics.maxQueueMs << " ms\n";
            require(running && metrics.callbacks > 0, "output did not supply audio callbacks");
            require(metrics.enqueued == 100, "count live events");
            require(metrics.queueDrops == 0 && metrics.voiceDrops == 0 && metrics.staleDrops == 0,
                    "live output delivers every silent event");
            require(metrics.deadlineMisses == 0, "live callbacks meet the output deadline");
        }
    }
    st_keyboard_destroy(engine);
    std::cout << "Keyboard engine lifecycle tests passed.\n";
}
