import AudioCore
import Foundation
import OSLog

public struct AudioMetrics: Sendable {
    public var running = false
    public var needsRestart: UInt32 = 0
    public var inputRate = 0.0
    public var outputRate = 0.0
    public var inputFrames = 0
    public var outputFrames = 0
    public var estimatedLatencyMs = 0.0
    public var queueLatencyMs = 0.0
    public var inputDeviceLatencyMs = 0.0
    public var outputDeviceLatencyMs = 0.0
    public var resamplerLatencyMs = 0.0
    public var peakInput = 0.0
    public var peakOutput = 0.0
    public var maxCallbackMs = 0.0
    public var maxDSPMs = 0.0
    public var driftPPM = 0.0
    public var inputCallbacks: UInt64 = 0
    public var outputCallbacks: UInt64 = 0
    public var underruns: UInt64 = 0
    public var overruns: UInt64 = 0
    public var deadlineMisses: UInt64 = 0
    public var clippedSamples: UInt64 = 0
    public var hardwareOverloads: UInt64 = 0
    public init() {}
}

struct EngineResult: Sendable {
    let running: Bool
    let error: String?
}

struct DeviceUpdate: Sendable {
    let generation: UInt64
    let devices: [AudioDevice]?
    let metrics: AudioMetrics?
}

protocol AudioWorking: Sendable {
    func apply(route: AudioRoute?, settings: MonitorSettings, revision: UInt64, parameterRevision: UInt64) async -> EngineResult
    func setParameters(_ settings: MonitorSettings, revision: UInt64) async
    func poll(generation: UInt64?, includeMetrics: Bool) async -> DeviceUpdate
    func metrics() async -> AudioMetrics
}

struct ParameterState {
    private(set) var settings = MonitorSettings()
    private var revision: UInt64?

    mutating func receive(_ settings: MonitorSettings, revision: UInt64) -> Bool {
        if let previous = self.revision, previous > revision { return false }
        self.revision = revision
        self.settings = settings
        return true
    }
}

private final class EngineHandle: @unchecked Sendable {
    // AudioWorker owns all calls to this handle.
    let pointer = st_engine_create()
    deinit { st_engine_destroy(pointer) }
}

actor AudioWorker: AudioWorking {
    private let logger = Logger(subsystem: "com.sidetone.app", category: "Audio")
    private let engine = EngineHandle()
    private var revision: UInt64 = 0
    private var parameterState = ParameterState()

    func apply(route: AudioRoute?, settings: MonitorSettings, revision nextRevision: UInt64,
               parameterRevision: UInt64) -> EngineResult {
        guard nextRevision >= revision else { return EngineResult(running: false, error: nil) }
        revision = nextRevision
        st_engine_stop(engine.pointer)
        guard let route else {
            logger.info("Monitoring stopped.")
            return EngineResult(running: false, error: nil)
        }
        guard engine.pointer != nil else {
            return EngineResult(running: false, error: "The audio engine could not start.")
        }
        setParameters(settings, revision: parameterRevision)
        let configuration = STConfiguration(inputDevice: route.input.id, outputDevice: route.output.id,
                                            inputChannel: UInt32(settings.inputChannel),
                                            bufferFrames: UInt32(settings.bufferFrames))
        var identity = STRouteIdentity()
        withUnsafeMutableBytes(of: &identity.inputUID) { destination in
            destination.copyBytes(from: route.input.uid.utf8.prefix(destination.count - 1))
        }
        withUnsafeMutableBytes(of: &identity.outputUID) { destination in
            destination.copyBytes(from: route.output.uid.utf8.prefix(destination.count - 1))
        }
        identity.outputDataSource = route.output.outputDataSource
        identity.outputJackState = route.output.outputJackState
        identity.outputLeftChannel = UInt32(route.output.outputLeftChannel)
        identity.outputRightChannel = UInt32(route.output.outputRightChannel)
        let result = st_engine_start_checked(engine.pointer, configuration, identity)
        let error = result == 0 ? nil : String(cString: st_engine_error(engine.pointer))
        if let error { logger.error("Start failed: \(error, privacy: .public)") }
        else { logger.info("Monitoring started.") }
        return EngineResult(running: result == 0, error: error)
    }

    func setParameters(_ settings: MonitorSettings, revision: UInt64) {
        guard parameterState.receive(settings, revision: revision) else { return }
        var safe = settings
        safe.normalize()
        st_engine_set_parameters(engine.pointer, STParameters(
            gainDB: Float(safe.gainDB), profile: safe.profile.engineValue,
            highPassHz: Float(safe.highPassHz), eqFrequencyHz: Float(safe.eqFrequencyHz),
            eqGainDB: Float(safe.eqGainDB), eqQ: Float(safe.eqQ),
            compression: safe.compression ? 1 : 0
        ))
    }

    func poll(generation: UInt64?, includeMetrics: Bool) -> DeviceUpdate {
        let current = st_device_generation()
        var devices: [AudioDevice]?
        if generation != current {
            var raw = [STDevice](repeating: STDevice(), count: 256)
            let count = Int(st_devices(&raw, UInt32(raw.count)))
            devices = raw.prefix(min(count, raw.count)).map { value in
                AudioDevice(id: value.id, uid: Self.string(value.uid), name: Self.string(value.name),
                            inputChannels: Int(value.inputChannels), outputChannels: Int(value.outputChannels),
                            sampleRate: value.sampleRate, bufferFrames: Int(value.bufferFrames),
                            minBufferFrames: Int(value.minBufferFrames), maxBufferFrames: Int(value.maxBufferFrames),
                            isDefaultInput: value.isDefaultInput != 0, isDefaultOutput: value.isDefaultOutput != 0,
                            outputDataSource: value.outputDataSource, outputJackState: value.outputJackState,
                            outputLeftChannel: Int(value.outputLeftChannel), outputRightChannel: Int(value.outputRightChannel))
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return DeviceUpdate(generation: current, devices: devices, metrics: includeMetrics ? metrics() : nil)
    }

    func metrics() -> AudioMetrics {
        let raw = st_engine_telemetry(engine.pointer)
        var result = AudioMetrics()
        result.running = raw.running != 0; result.needsRestart = raw.needsRestart
        result.inputRate = raw.inputRate; result.outputRate = raw.outputRate
        result.inputFrames = Int(raw.inputBufferFrames); result.outputFrames = Int(raw.outputBufferFrames)
        result.estimatedLatencyMs = raw.estimatedLatencyMs; result.queueLatencyMs = raw.queueLatencyMs
        result.inputDeviceLatencyMs = raw.inputDeviceLatencyMs
        result.outputDeviceLatencyMs = raw.outputDeviceLatencyMs
        result.resamplerLatencyMs = raw.resamplerLatencyMs
        result.peakInput = raw.peakInput; result.peakOutput = raw.peakOutput
        result.maxCallbackMs = raw.maxCallbackMs; result.maxDSPMs = raw.maxDSPMs
        result.driftPPM = raw.driftPPM; result.inputCallbacks = raw.inputCallbacks
        result.outputCallbacks = raw.outputCallbacks; result.underruns = raw.underruns
        result.overruns = raw.overruns; result.deadlineMisses = raw.deadlineMisses
        result.clippedSamples = raw.clippedSamples
        result.hardwareOverloads = raw.hardwareOverloads
        return result
    }

    private static func string<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
