import AVFoundation
import AudioCore
import Foundation
import Testing

@testable import SidetoneKit

@Suite("Keyboard sounds")
struct KeyboardTests {
    @Test @MainActor func preferencesAreSeparateFromMicrophoneSettings() throws {
        let name = "KeyboardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var microphone = MonitorSettings()
        microphone.gainDB = -27
        SettingsStore(defaults: defaults).save(microphone)
        var settings = KeyboardSettings()
        settings.switchType = .topre
        settings.volumeDB = -12
        settings.releaseSounds = false
        settings.modifierSounds = false
        settings.repeatSounds = true
        settings.varySamples = false
        KeyboardSettingsStore(defaults: defaults).save(settings)
        #expect(KeyboardSettingsStore(defaults: defaults).load() == settings)
        #expect(SettingsStore(defaults: defaults).load() == microphone)
    }

    @Test func invalidVolumeUsesSafeRange() {
        var settings = KeyboardSettings()
        settings.volumeDB = .nan
        settings.normalize()
        #expect(settings.volumeDB == -18)
        settings.volumeDB = 10
        settings.normalize()
        #expect(settings.volumeDB == 0)
        settings.volumeDB = -100
        settings.normalize()
        #expect(settings.volumeDB == -60)
    }

    @Test func outputDoesNotNeedAMicrophone() {
        let output = AudioDevice(
            id: 1, uid: "output", name: "Output", outputChannels: 2, isDefaultOutput: true)
        #expect(OutputSelection.resolve(uid: nil, devices: [output]) == output)
        #expect(OutputSelection.resolve(uid: "unplugged", devices: [output]) == nil)
    }

    @Test func pressReleaseAndRepeatRules() {
        var input = KeyboardInputState()
        var settings = KeyboardSettings()
        func accepts(_ stroke: KeyboardStroke) -> Bool {
            input.accepts(stroke, settings: settings)
        }
        let down = KeyboardStroke(keyCode: 0, isDown: true)
        let up = KeyboardStroke(keyCode: 0, isDown: false)
        let repeated = KeyboardStroke(keyCode: 0, isDown: true, isRepeat: true)
        #expect(!accepts(up))
        #expect(accepts(down))
        #expect(!accepts(down))
        #expect(!accepts(repeated))
        settings.repeatSounds = true
        #expect(accepts(repeated))
        #expect(accepts(up))
        #expect(!accepts(up))
        #expect(!accepts(repeated))
        settings.releaseSounds = false
        #expect(accepts(down))
        #expect(!accepts(up))
    }

    @Test func modifiersAndReset() {
        var input = KeyboardInputState()
        var settings = KeyboardSettings()
        func accepts(_ stroke: KeyboardStroke) -> Bool {
            input.accepts(stroke, settings: settings)
        }
        let left = KeyboardStroke(keyCode: 56, isDown: true, isModifier: true)
        let right = KeyboardStroke(keyCode: 60, isDown: true, isModifier: true)
        settings.modifierSounds = false
        #expect(!accepts(left))
        settings.modifierSounds = true
        #expect(accepts(left))
        #expect(accepts(right))
        input.reset()
        #expect(!accepts(KeyboardStroke(keyCode: 56, isDown: false)))
        #expect(accepts(left))
    }

    @Test(arguments: [8_000.0, 16_000, 44_100, 48_000, 96_000, 192_000])
    func bundledRecordingsCoverEveryKey(sampleRate: Double) throws {
        let engine = try #require(st_keyboard_create())
        defer { st_keyboard_destroy(engine) }
        let library = try KeyboardSoundLibrary(engine: engine, sampleRate: sampleRate)
        for type in KeyboardSwitch.allCases {
            for code: UInt16 in 0...127 {
                let press = library.choices(
                    for: KeyboardStroke(keyCode: code, isDown: true), type: type)
                let release = library.choices(
                    for: KeyboardStroke(keyCode: code, isDown: false), type: type)
                #expect(!press.isEmpty)
                #expect(!release.isEmpty)
            }
            let normal = library.choices(for: KeyboardStroke(keyCode: 0, isDown: true), type: type)
            let space = library.choices(for: KeyboardStroke(keyCode: 49, isDown: true), type: type)
            #expect(normal != space)
            let root = try #require(KeyboardSoundLibrary.resourceURL)
                .appendingPathComponent(type.rawValue)
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("LICENSE.txt").path))
        }
    }

    @Test func variationSeparatesPressAndReleaseGroups() throws {
        var selector = KeyboardSampleSelector()
        func select(_ choices: [UInt32], vary: Bool) -> UInt32? {
            selector.select(choices, vary: vary)
        }
        var lastPress: UInt32?
        var lastRelease: UInt32?
        for _ in 0..<100 {
            let press = try #require(select([0, 1, 2], vary: true))
            let release = try #require(select([3, 4, 5], vary: true))
            #expect(press != lastPress)
            #expect(release != lastRelease)
            lastPress = press
            lastRelease = release
        }
        #expect(select([9], vary: true) == 9)
        #expect(select([0, 1], vary: false) == 0)
        #expect(select([], vary: true) == nil)
    }

    @Test func conversionRemovesFrequenciesAboveTheOutputLimit() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
            ))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        input.frameLength = input.frameCapacity
        let samples = try #require(input.floatChannelData?[0])
        for frame in 0..<Int(input.frameLength) {
            samples[frame] = 0.5 * Float(sin(2 * Double.pi * 15_000 * Double(frame) / 44_100))
        }
        let output = try KeyboardSoundLibrary.convert(input, to: 16_000)
        #expect(abs(Int(output.frameLength) - 1600) <= 1)
        let converted = try #require(output.floatChannelData?[0])
        let interior = (256..<(Int(output.frameLength) - 256)).map { Double(converted[$0]) }
        let rms = sqrt(interior.reduce(0) { $0 + $1 * $1 } / Double(interior.count))
        #expect(rms < 0.001)
    }

    @Test func conversionRejectsAnUnsupportedRateEvenWithoutResampling() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 1000, channels: 1, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        input.frameLength = 100
        #expect(throws: CocoaError.self) { try KeyboardSoundLibrary.convert(input, to: 1000) }
    }

    @Test @MainActor func eventDeliveryDoesNotWaitForTheMainThread() {
        let playback = KeyboardTestPlayback()
        playback.configure(running: true, revision: 1)
        let delivery = KeyboardEventDelivery { stroke, _, revision in
            playback.play(stroke, revision: revision)
        }
        var settings = KeyboardSettings()
        delivery.configure(enabled: true, settings: settings, revision: 1)
        let complete = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            for code: UInt16 in 0..<128 {
                delivery.receive(KeyboardStroke(keyCode: code, isDown: true))
                delivery.receive(KeyboardStroke(keyCode: code, isDown: false))
            }
            complete.signal()
        }
        #expect(complete.wait(timeout: .now() + 2) == .success)
        #expect(playback.strokes.count == 256)
        for (index, stroke) in playback.strokes.enumerated() {
            #expect(stroke.keyCode == UInt16(index / 2))
            #expect(stroke.isDown == index.isMultiple(of: 2))
        }
        delivery.receive(KeyboardStroke(keyCode: 0, isDown: true))
        settings.volumeDB = -24
        delivery.configure(enabled: true, settings: settings, revision: 1)
        delivery.receive(KeyboardStroke(keyCode: 0, isDown: false))
        #expect(playback.strokes.count == 258)
        delivery.configure(enabled: false, settings: settings, revision: 2)
        delivery.receive(KeyboardStroke(keyCode: 1, isDown: true))
        #expect(playback.strokes.count == 258)
    }

    @Test @MainActor func unavailablePackKeepsSoundPreferences() throws {
        let name = "KeyboardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = KeyboardSettings()
        settings.volumeDB = -30
        settings.releaseSounds = false
        let data = try JSONEncoder().encode(settings)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["switchType"] = "unavailable"
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "keyboardSettings")
        #expect(KeyboardSettingsStore(defaults: defaults).load() == settings)
    }
}

private final class KeyboardTestPlayback: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var revision: UInt64 = 0
    private var received: [KeyboardStroke] = []
    var strokes: [KeyboardStroke] { lock.withLock { received } }

    func configure(running: Bool, revision: UInt64) {
        lock.withLock {
            self.running = running
            self.revision = revision
        }
    }

    func play(_ stroke: KeyboardStroke, revision: UInt64) {
        lock.withLock {
            if running && revision == self.revision { received.append(stroke) }
        }
    }
}

private actor KeyboardTestWorker: KeyboardAudioWorking {
    private(set) var starts = 0
    private(set) var outputUID: String?
    private nonisolated let playback = KeyboardTestPlayback()
    var strokes: [KeyboardStroke] { playback.strokes }
    private var running = false
    private var revision: UInt64 = 0
    private var metrics = KeyboardAudioMetrics()
    private var devices = [
        AudioDevice(id: 1, uid: "out", name: "Output", outputChannels: 2, isDefaultOutput: true),
        AudioDevice(id: 3, uid: "other", name: "Other output", outputChannels: 2),
    ]
    func apply(_ request: KeyboardAudioRequest) -> EngineResult {
        guard request.revision >= revision else { return EngineResult(running: false, error: nil) }
        revision = request.revision
        running = request.output != nil
        playback.configure(running: running, revision: revision)
        outputUID = request.output?.uid
        if running {
            starts += 1
            metrics = KeyboardAudioMetrics()
        }
        return EngineResult(running: running, error: nil)
    }
    func setVolume(_ volumeDB: Double, revision: UInt64) {}
    nonisolated func play(_ stroke: KeyboardStroke, settings: KeyboardSettings, revision: UInt64) {
        playback.play(stroke, revision: revision)
    }
    func poll() -> KeyboardDeviceUpdate {
        KeyboardDeviceUpdate(devices: devices, running: running, metrics: metrics)
    }
    func stall() {
        running = false
        metrics.stalled = true
    }
    func disconnect() {
        devices = []
        running = false
    }
    func reconnect() {
        devices = [
            AudioDevice(id: 2, uid: "out", name: "Output", outputChannels: 2, isDefaultOutput: true)
        ]
    }
}

@MainActor
private final class KeyboardTestEvents: KeyboardEventMonitoring {
    var hasAccess = true
    var secureInput = false
    var requests = 0
    var listening = false
    private(set) var receive: (@Sendable (KeyboardStroke) -> Void)?
    private var reset: (@Sendable () -> Void)?
    func requestAccess() -> Bool {
        requests += 1
        return hasAccess
    }
    func start(
        receive: @escaping @Sendable (KeyboardStroke) -> Void,
        reset: @escaping @Sendable () -> Void
    ) -> Bool {
        listening = hasAccess
        self.receive = listening ? receive : nil
        self.reset = listening ? reset : nil
        return listening
    }
    func stop() {
        listening = false
        receive = nil
        reset = nil
    }

    func send(_ stroke: KeyboardStroke) {
        guard listening, hasAccess else { return }
        if secureInput {
            reset?()
        } else {
            receive?(stroke)
        }
    }
}

@Suite("Keyboard lifecycle")
@MainActor
struct KeyboardLifecycleTests {
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private func run(
        _ body: (KeyboardModel, KeyboardTestWorker, KeyboardTestEvents) async throws -> Void
    ) async throws {
        let name = "KeyboardLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let worker = KeyboardTestWorker()
        let events = KeyboardTestEvents()
        let model = KeyboardModel(
            store: KeyboardSettingsStore(defaults: defaults), worker: worker,
            events: events, startPolling: false)
        await model.poll()
        do {
            try await body(model, worker, events)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

    @Test func keyboardRunsWithOnlyAnOutput() async throws {
        try await run { model, worker, events in
            #expect(!model.enabled)
            model.setEnabled(true)
            try await waitUntil { model.phase == .listening }
            #expect(events.listening)
            events.send(KeyboardStroke(keyCode: 0, isDown: true))
            try await waitUntil { await worker.strokes.count == 1 }
            model.setEnabled(false)
            #expect(!events.listening)
            #expect(model.phase == .off)
            try await waitUntil { await worker.poll().running == false }
        }
    }

    @Test func diagnosticsDescribeCurrentKeyboardSettings() async throws {
        try await run { model, _, _ in
            model.updateSettings {
                $0.switchType = .gateronInkBlack
                $0.volumeDB = -24
                $0.releaseSounds = false
                $0.repeatSounds = true
            }
            let report = model.diagnostics
            #expect(report.contains("State: Off"))
            #expect(report.contains("Output: Output"))
            #expect(report.contains("Switch: Gateron Ink Black"))
            #expect(report.contains("Volume: -24 dB"))
            #expect(report.contains("Input Monitoring: Allowed"))
            #expect(report.contains("Release sounds: false"))
            #expect(report.contains("Key repeat: true"))
        }
    }

    @Test func permissionCanBeGrantedAndRevoked() async throws {
        try await run { model, worker, events in
            events.hasAccess = false
            model.setEnabled(true)
            #expect(model.phase == .permission)
            #expect(events.requests == 1)
            #expect(await worker.starts == 0)
            events.hasAccess = true
            await model.poll()
            try await waitUntil { model.phase == .listening }
            events.hasAccess = false
            await model.poll()
            #expect(model.phase == .permission)
            #expect(!events.listening)
        }
    }

    @Test func sharedOutputControlsPlayback() async throws {
        try await run { model, worker, events in
            let settings = model.settings
            model.setOutputUID("other")
            #expect(model.output?.uid == "other")
            #expect(!model.enabled)
            #expect(await worker.starts == 0)
            model.setEnabled(true)
            try await waitUntil { model.phase == .listening }
            #expect(await worker.outputUID == "other")
            model.setOutputUID("unavailable")
            #expect(model.output == nil)
            #expect(model.phase == .waiting)
            #expect(model.enabled)
            #expect(!events.listening)
            try await waitUntil { await worker.poll().running == false }
            model.setOutputUID(nil)
            try await waitUntil { model.phase == .listening }
            #expect(await worker.outputUID == "out")
            #expect(model.settings == settings)
        }
    }

    @Test func sleepAndDeviceLossRecover() async throws {
        try await run { model, worker, events in
            model.setEnabled(true)
            try await waitUntil { model.phase == .listening }
            model.systemWillSleep()
            #expect(model.phase == .sleeping)
            #expect(!events.listening)
            model.systemDidWake()
            try await waitUntil { model.phase == .listening }
            await worker.disconnect()
            await model.poll()
            #expect(model.phase == .waiting)
            #expect(!events.listening)
            await worker.reconnect()
            await model.poll()
            try await waitUntil { model.phase == .listening }
        }
    }

    @Test func secureInputClearsHeldKeys() async throws {
        try await run { model, worker, events in
            model.setEnabled(true)
            try await waitUntil { model.phase == .listening }
            events.send(KeyboardStroke(keyCode: 0, isDown: true))
            try await waitUntil { await worker.strokes.count == 1 }
            events.secureInput = true
            await model.poll()
            #expect(model.phase == .secureInput)
            events.send(KeyboardStroke(keyCode: 1, isDown: true))
            events.secureInput = false
            await model.poll()
            events.send(KeyboardStroke(keyCode: 0, isDown: false))
            events.send(KeyboardStroke(keyCode: 0, isDown: true))
            try await waitUntil { await worker.strokes.count == 2 }
        }
    }

    @Test func rapidToggleCannotRestartAfterOff() async throws {
        try await run { model, worker, _ in
            model.setEnabled(true)
            model.setEnabled(false)
            model.setEnabled(true)
            model.setEnabled(false)
            await model.shutdown()
            #expect(!model.enabled)
            #expect(await worker.poll().running == false)
        }
    }

    @Test func shutdownStopsEventDeliveryAndIgnoresLaterChanges() async throws {
        try await run { model, worker, events in
            model.setEnabled(true)
            try await waitUntil { model.phase == .listening }
            let receive = try #require(events.receive)
            let settings = model.settings
            await model.shutdown()
            model.systemWillSleep()
            model.systemDidWake()
            model.updateSettings { $0.volumeDB = -30 }
            model.setOutputUID("other")
            model.setEnabled(true)
            receive(KeyboardStroke(keyCode: 0, isDown: true))
            await model.poll()
            #expect(model.phase == .off)
            #expect(!model.enabled)
            #expect(!events.listening)
            #expect(model.settings == settings)
            #expect(model.outputUID == nil)
            #expect(await worker.starts == 1)
            #expect(await worker.strokes.isEmpty)
            #expect(await worker.poll().running == false)
        }
    }

    @Test func stalledOutputUsesIncreasingRetryDelays() async throws {
        let name = "KeyboardStall.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var time = Date()
        let worker = KeyboardTestWorker()
        let events = KeyboardTestEvents()
        let model = KeyboardModel(
            store: KeyboardSettingsStore(defaults: defaults), worker: worker,
            events: events, startPolling: false, now: { time })
        await model.poll()
        model.setEnabled(true)
        try await waitUntil { model.phase == .listening }
        await worker.stall()
        await model.poll()
        #expect(model.phase == .waiting)
        #expect(!events.listening)
        await model.poll()
        #expect(await worker.starts == 1)
        time.addTimeInterval(1)
        await model.poll()
        try await waitUntil { model.phase == .listening }
        #expect(await worker.starts == 2)
        await worker.stall()
        await model.poll()
        time.addTimeInterval(1)
        await model.poll()
        #expect(await worker.starts == 2)
        time.addTimeInterval(1)
        await model.poll()
        try await waitUntil { model.phase == .listening }
        #expect(await worker.starts == 3)
        await model.shutdown()
    }
}
