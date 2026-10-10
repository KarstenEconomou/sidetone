import AudioCore
import Foundation
import OSLog

struct AudioRequest: Sendable {
    let route: AudioRoute?
    let settings: MonitorSettings
    let revision: UInt64
    let parameterRevision: UInt64
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
    func apply(_ request: AudioRequest) async -> EngineResult
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
        self.settings = settings.normalized()
        return true
    }
}

private final class EngineHandle: @unchecked Sendable {
    // AudioWorker owns all calls to this handle.
    let pointer = st_engine_create()

    deinit {
        st_engine_destroy(pointer)
    }
}

actor AudioWorker: AudioWorking {
    private let logger = Logger(subsystem: "com.sidetone.app", category: "Audio")
    private let engine = EngineHandle()
    private var revision: UInt64 = 0
    private var parameterState = ParameterState()

    func apply(_ request: AudioRequest) -> EngineResult {
        guard request.revision >= revision else { return EngineResult(running: false, error: nil) }
        revision = request.revision
        st_engine_stop(engine.pointer)
        guard let route = request.route else {
            logger.info("Monitoring stopped.")
            return EngineResult(running: false, error: nil)
        }
        guard let pointer = engine.pointer else {
            return EngineResult(running: false, error: "The audio engine could not start.")
        }
        let settings = request.settings.normalized()
        setParameters(settings, revision: request.parameterRevision)
        let result = st_engine_start_checked(
            pointer, STConfiguration(route: route, settings: settings), STRouteIdentity(route)
        )
        let error = result == 0 ? nil : String(cString: st_engine_error(pointer))
        if let error {
            logger.error("Start failed: \(error, privacy: .public)")
        } else {
            logger.info("Monitoring started.")
        }
        return EngineResult(running: result == 0, error: error)
    }

    func setParameters(_ settings: MonitorSettings, revision: UInt64) {
        guard parameterState.receive(settings, revision: revision) else { return }
        st_engine_set_parameters(engine.pointer, STParameters(parameterState.settings))
    }

    func poll(generation: UInt64?, includeMetrics: Bool) -> DeviceUpdate {
        let current = st_device_generation()
        var devices: [AudioDevice]?
        if generation != current {
            var raw = [STDevice](repeating: STDevice(), count: Int(st_devices(nil, 0)))
            let count = raw.withUnsafeMutableBufferPointer {
                st_devices($0.baseAddress, UInt32($0.count))
            }
            devices = raw.prefix(min(Int(count), raw.count)).map(AudioDevice.init).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return DeviceUpdate(
            generation: current, devices: devices, metrics: includeMetrics ? metrics() : nil
        )
    }

    func metrics() -> AudioMetrics {
        AudioMetrics(st_engine_telemetry(engine.pointer))
    }
}
