import Foundation
@testable import SidetoneKit
import Testing

private actor TestAudioWorker: AudioWorking {
    private var devices: [AudioDevice]
    private var generation: UInt64 = 0
    private var sample = AudioMetrics()
    private(set) var starts = 0
    private(set) var gainDB = -18.0
    private(set) var bufferFrames = 0
    private var failedStarts = 0
    private var nextPollGate: PermissionGate?

    init(devices: [AudioDevice]) { self.devices = devices }
    func setDevices(_ value: [AudioDevice]) { devices = value; generation += 1 }
    func failNextStart() { failedStarts += 1 }
    func signalOutputChange() { sample.needsRestart = 2 }
    func blockNextPoll(_ gate: PermissionGate) { nextPollGate = gate }
    func apply(route: AudioRoute?, settings: MonitorSettings, revision: UInt64, parameterRevision: UInt64) -> EngineResult {
        sample.running = false
        guard route != nil else { return EngineResult(running: false, error: nil) }
        starts += 1
        if failedStarts > 0 {
            failedStarts -= 1
            return EngineResult(running: false, error: "Device is busy.")
        }
        sample.needsRestart = 0
        sample.running = true
        gainDB = settings.gainDB
        bufferFrames = settings.bufferFrames
        return EngineResult(running: true, error: nil)
    }
    func setParameters(_ settings: MonitorSettings, revision: UInt64) { gainDB = settings.gainDB }
    func poll(generation previous: UInt64?, includeMetrics: Bool) async -> DeviceUpdate {
        let snapshot = DeviceUpdate(generation: generation, devices: previous == generation ? nil : devices,
                                    metrics: includeMetrics ? sample : nil)
        if let gate = nextPollGate {
            nextPollGate = nil
            _ = await gate.request()
        }
        return snapshot
    }
    func metrics() -> AudioMetrics { sample }
}

private actor PermissionGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var granted = false
    private(set) var entered = false
    func request() async -> Bool {
        entered = true
        if granted { return true }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { granted = true; continuation?.resume(returning: true); continuation = nil }
}

@MainActor
private final class Fixture {
    let microphone = AudioDevice(id: 1, uid: "mic", name: "Mic", inputChannels: 1, isDefaultInput: true)
    let output = AudioDevice(id: 2, uid: "iem", name: "IEM", outputChannels: 2, isDefaultOutput: true)
    let name = "SidetoneTests.\(UUID().uuidString)"
    var date = Date(timeIntervalSince1970: 1000)
    let defaults: UserDefaults
    let worker: TestAudioWorker
    init() {
        defaults = UserDefaults(suiteName: name)!
        worker = TestAudioWorker(devices: [microphone, output])
    }
    func model(permission: @escaping @MainActor () async -> Bool = { true }) -> MonitorModel {
        MonitorModel(store: SettingsStore(defaults: defaults), worker: worker, requestPermission: permission,
                     now: { self.date }, startPolling: false)
    }
    func clean() { defaults.removePersistentDomain(forName: name) }
}

@Suite("Monitoring lifecycle")
@MainActor
struct LifecycleTests {
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let satisfied = await condition()
        try #require(satisfied)
    }

    @Test func launchDoesNotRequestPermissionOrCapture() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        var requested = false
        let model = fixture.model { requested = true; return true }
        await model.pollDevices()
        #expect(!model.enabled)
        #expect(model.phase == .off)
        #expect(!requested)
        #expect(await fixture.worker.starts == 0)
        await model.shutdown()
    }

    @Test func permissionDenialKeepsCaptureOff() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let model = fixture.model { false }
        model.setEnabled(true)
        try await waitUntil { model.permissionDenied }
        #expect(!model.enabled)
        #expect(model.phase == .off)
        #expect(await fixture.worker.starts == 0)
        await model.shutdown()
    }

    @Test func stopWhilePermissionIsPendingPreventsStart() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let permission = PermissionGate()
        var permissionReturned = false
        let model = fixture.model {
            let result = await permission.request()
            permissionReturned = true
            return result
        }
        model.setEnabled(true)
        model.setEnabled(false)
        await permission.release()
        try await waitUntil { permissionReturned }
        await model.pollDevices()
        #expect(!model.enabled)
        #expect(await fixture.worker.starts == 0)
        await model.shutdown()
    }

    @Test func temporaryStartFailureRetriesWithDelay() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        await fixture.worker.failNextStart()
        let model = fixture.model()
        model.setEnabled(true)
        try await waitUntil { model.phase == .waiting }
        #expect(model.enabled)
        await model.pollDevices()
        #expect(await fixture.worker.starts == 1)
        fixture.date = fixture.date.addingTimeInterval(1)
        await model.pollDevices()
        try await waitUntil { model.phase == .monitoring }
        #expect(await fixture.worker.starts == 2)
        await model.shutdown()
    }

    @Test func configurationChangeWaitsForMicrophonePermission() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let permission = PermissionGate()
        let model = fixture.model { await permission.request() }
        model.setEnabled(true)
        try await waitUntil { await permission.entered }
        model.updateSettings { $0.bufferFrames = 128 }
        await model.pollDevices(force: true)
        #expect(await fixture.worker.starts == 0)
        #expect(model.phase == .starting)
        await permission.release()
        try await waitUntil { model.phase == .monitoring }
        #expect(await fixture.worker.starts == 1)
        #expect(await fixture.worker.bufferFrames == 128)
        await model.shutdown()
    }

    @Test func sleepDuringPermissionRequestCannotStartCaptureOnWake() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let permission = PermissionGate()
        var permissionReturned = false
        let model = fixture.model {
            let result = await permission.request()
            permissionReturned = true
            return result
        }
        model.setEnabled(true)
        try await waitUntil { await permission.entered }
        model.systemWillSleep()
        model.systemDidWake()
        await permission.release()
        try await waitUntil { permissionReturned }
        await model.pollDevices(force: true)
        #expect(!model.enabled)
        #expect(model.phase == .off)
        #expect(await fixture.worker.starts == 0)
        await model.shutdown()
    }

    @Test func wakeWaitsForFreshRouteAfterPendingPoll() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let model = fixture.model()
        model.setEnabled(true)
        try await waitUntil { model.phase == .monitoring }
        let gate = PermissionGate()
        await fixture.worker.blockNextPoll(gate)
        let oldPoll = Task { await model.pollDevices(force: true) }
        try await waitUntil { await gate.entered }
        model.systemWillSleep()
        let changedOutput = AudioDevice(id: 2, uid: "iem", name: "IEM", outputChannels: 2,
                                        isDefaultOutput: true, outputDataSource: 4, outputJackState: 1)
        await fixture.worker.setDevices([fixture.microphone, changedOutput])
        model.systemDidWake()
        let freshPoll = Task { await model.pollDevices(force: true) }
        await gate.release()
        await oldPoll.value
        await freshPoll.value
        try await waitUntil { !model.enabled }
        #expect(await fixture.worker.starts == 1)
        #expect(model.phase == .off)
        await model.shutdown()
    }

    @Test func disconnectAndSameUIDReturnResumesAtSafeGain() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let model = fixture.model()
        model.updateSettings { $0.outputUID = "iem"; $0.gainDB = -3 }
        model.setEnabled(true)
        try await waitUntil { model.phase == .monitoring }
        await fixture.worker.setDevices([fixture.microphone])
        await model.pollDevices()
        #expect(model.phase == .waiting)
        #expect(model.enabled)
        #expect(!(await fixture.worker.metrics()).running)
        let returned = AudioDevice(id: 9, uid: "iem", name: "IEM", outputChannels: 2)
        await fixture.worker.setDevices([fixture.microphone, returned])
        await model.pollDevices()
        try await waitUntil { model.phase == .monitoring }
        #expect(model.settings.gainDB == -18)
        #expect(await fixture.worker.gainDB == -18)
        await model.shutdown()
    }

    @Test func defaultOutputChangeClearsMonitoringIntent() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let model = fixture.model()
        model.setEnabled(true)
        try await waitUntil { model.phase == .monitoring }
        let speakers = AudioDevice(id: 4, uid: "speakers", name: "Speakers", outputChannels: 2, isDefaultOutput: true)
        await fixture.worker.setDevices([fixture.microphone, speakers])
        await model.pollDevices()
        #expect(!model.enabled)
        #expect(model.phase == .off)
        await model.pollDevices()
        #expect(await fixture.worker.starts == 1)
        await model.shutdown()
    }

    @Test func outputSourceNotificationRequiresUserAction() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let model = fixture.model()
        model.setEnabled(true)
        try await waitUntil { model.phase == .monitoring }
        await fixture.worker.signalOutputChange()
        await model.pollDevices()
        #expect(!model.enabled)
        #expect(model.phase == .off)
        await model.shutdown()
    }

    @Test func sleepStopsCaptureAndWakeUsesSameRouteAtLowGain() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let model = fixture.model()
        model.updateSettings { $0.gainDB = -1 }
        model.setEnabled(true)
        try await waitUntil { model.phase == .monitoring }
        model.systemWillSleep()
        #expect(model.phase == .sleeping)
        #expect(model.enabled)
        model.systemDidWake()
        try await waitUntil { model.phase == .monitoring }
        #expect(await fixture.worker.starts == 2)
        #expect(model.settings.gainDB == -18)
        await model.shutdown()
    }

    @Test func recoveryBackoffIsBoundedAndResets() {
        var recovery = RecoveryBackoff()
        let now = Date()
        for delay in [1.0, 2, 4, 8, 16, 30, 30] {
            recovery.recordFailure(now: now)
            #expect(!recovery.canAttempt(now: now.addingTimeInterval(delay - 0.01)))
            #expect(recovery.canAttempt(now: now.addingTimeInterval(delay)))
        }
        recovery.reset()
        #expect(recovery.canAttempt(now: now))
    }

    @Test func delayedGainUpdateCannotOverrideRecoveryGain() {
        var parameters = ParameterState()
        var loud = MonitorSettings()
        loud.gainDB = -1
        var recovery = loud
        recovery.gainDB = -18
        let acceptedGain = parameters.receive(loud, revision: 1)
        let acceptedRecovery = parameters.receive(recovery, revision: 2)
        let acceptedDelayedGain = parameters.receive(loud, revision: 1)
        #expect(acceptedGain)
        #expect(acceptedRecovery)
        #expect(!acceptedDelayedGain)
        #expect(parameters.settings.gainDB == -18)
        let acceptedNewGain = parameters.receive(loud, revision: 3)
        #expect(acceptedNewGain)
        #expect(parameters.settings.gainDB == -1)
    }
}
