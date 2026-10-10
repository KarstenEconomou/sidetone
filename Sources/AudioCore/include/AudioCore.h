#ifndef SIDETONE_AUDIO_CORE_H
#define SIDETONE_AUDIO_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct STEngine STEngine;
typedef struct {
    uint32_t id;
    char uid[256];
    char name[256];
    uint32_t inputChannels;
    uint32_t outputChannels;
    double sampleRate;
    uint32_t bufferFrames;
    uint32_t minBufferFrames;
    uint32_t maxBufferFrames;
    uint32_t transportType;
    uint32_t isDefaultInput;
    uint32_t isDefaultOutput;
    uint32_t outputDataSource;
    uint32_t outputJackState; /* 0 unknown, 1 disconnected, 2 connected. */
    uint32_t outputLeftChannel; /* Effective output channels, numbered from zero. */
    uint32_t outputRightChannel;
} STDevice;
typedef struct {
    uint32_t inputDevice;
    uint32_t outputDevice;
    uint32_t inputChannel;
    uint32_t bufferFrames;
} STConfiguration;
typedef struct {
    char inputUID[256];
    char outputUID[256];
    uint32_t outputDataSource;
    uint32_t outputJackState;
    uint32_t outputLeftChannel;
    uint32_t outputRightChannel;
} STRouteIdentity;
typedef struct {
    float gainDB;
    uint32_t profile; /* 0 Direct, 1 Natural, 2 Voice. */
    float highPassHz;
    float eqFrequencyHz;
    float eqGainDB;
    float eqQ;
    uint32_t compression;
} STParameters;
typedef struct {
    uint32_t running;
    uint32_t needsRestart;
    double inputRate;
    double outputRate;
    uint32_t inputBufferFrames;
    uint32_t outputBufferFrames;
    double estimatedLatencyMs;
    double queueLatencyMs;
    double peakInput;
    double peakOutput;
    double maxCallbackMs;
    double maxDSPMs;
    double driftPPM;
    uint64_t inputCallbacks;
    uint64_t outputCallbacks;
    uint64_t underruns;
    uint64_t overruns;
    uint64_t deadlineMisses;
    uint64_t clippedSamples;
    double inputDeviceLatencyMs;
    double outputDeviceLatencyMs;
    double resamplerLatencyMs;
    uint64_t hardwareOverloads;
} STTelemetry;
uint32_t st_devices(STDevice *devices, uint32_t capacity);
uint64_t st_device_generation(void);
STEngine *st_engine_create(void);
void st_engine_destroy(STEngine *engine);
int32_t st_engine_start(STEngine *engine, STConfiguration configuration);
/* Checks device UIDs, the output connection, and output channels before I/O. */
int32_t st_engine_start_checked(STEngine *engine, STConfiguration configuration, STRouteIdentity identity);
void st_engine_stop(STEngine *engine);
void st_engine_set_parameters(STEngine *engine, STParameters parameters);
STTelemetry st_engine_telemetry(STEngine *engine);
const char *st_engine_error(STEngine *engine);
#ifdef __cplusplus
}
#endif
#endif
