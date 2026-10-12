import AppKit
import Combine
import Foundation

@MainActor
public final class KeyboardModel: ObservableObject {
    public enum Phase: Sendable {
        case off, starting, listening, permission, waiting, secureInput, sleeping
    }

    @Published public private(set) var settings: KeyboardSettings
    @Published public private(set) var devices: [AudioDevice] = []
    @Published public private(set) var outputUID: String?
    @Published public private(set) var enabled = false
    @Published public private(set) var phase = Phase.off
    @Published public private(set) var message: String?
    @Published public private(set) var hasInputAccess = false
    @Published public private(set) var metrics = KeyboardAudioMetrics()

    private let store: KeyboardSettingsStore
    private let worker: any KeyboardAudioWorking
    private let events: any KeyboardEventMonitoring
    private let now: @MainActor () -> Date
    private let delivery: KeyboardEventDelivery
    private var revision: UInt64 = 0
    private var volumeRevision: UInt64 = 0
    private var activeOutput: AudioDevice?
    private var running = false
    private var starting = false
    private var sleeping = false
    private var closed = false
    private var recovery = RecoveryBackoff()
    private var pollTask: Task<Void, Never>?

    public convenience init(store: KeyboardSettingsStore = KeyboardSettingsStore()) {
        self.init(store: store, worker: KeyboardAudioWorker(), events: KeyboardEventMonitor())
    }

    init(
        store: KeyboardSettingsStore, worker: any KeyboardAudioWorking,
        events: any KeyboardEventMonitoring, startPolling: Bool = true,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.worker = worker
        self.events = events
        self.now = now
        delivery = KeyboardEventDelivery { worker.play($0, settings: $1, revision: $2) }
        settings = store.load()
        hasInputAccess = events.hasAccess
        if startPolling {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    await self?.poll()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    public var output: AudioDevice? {
        OutputSelection.resolve(uid: outputUID, devices: devices)
    }

    public var status: String {
        switch phase {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .listening: return "On"
        case .permission: return "Input Monitoring access needed"
        case .waiting: return "Waiting for output"
        case .secureInput: return "Paused for secure input"
        case .sleeping: return "Paused for sleep"
        }
    }

    public func restoreEnabledState() {
        setEnabled(store.isEnabled)
    }

    public func setEnabled(_ value: Bool) {
        guard !closed, enabled != value else { return }
        enabled = value
        store.isEnabled = value
        configureDelivery()
        message = nil
        delivery.reset()
        recovery.reset()
        if sleeping {
            phase = value ? .sleeping : .off
            return
        }
        if value && !events.hasAccess { _ = events.requestAccess() }
        reconcile()
    }

    public func updateSettings(_ update: (inout KeyboardSettings) -> Void) {
        guard !closed else { return }
        let previous = settings
        var next = settings
        update(&next)
        next.normalize()
        guard next != previous else { return }
        settings = next
        store.save(next)
        configureDelivery()
        guard next.volumeDB != previous.volumeDB else { return }
        volumeRevision &+= 1
        let volume = volumeRevision
        Task { await worker.setVolume(next.volumeDB, revision: volume) }
    }

    public func setOutputUID(_ uid: String?) {
        guard !closed, outputUID != uid else { return }
        outputUID = uid
        events.stop()
        delivery.reset()
        stopAudio()
        recovery.reset()
        reconcile()
    }

    public func openInputSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        {
            NSWorkspace.shared.open(url)
        }
    }

    public func openSoundLicense() {
        guard let directory = KeyboardSoundLibrary.resourceURL else {
            message = "The keyboard recordings are missing. Reinstall Sidetone."
            return
        }
        let url =
            directory
            .appendingPathComponent(settings.switchType.rawValue)
            .appendingPathComponent("LICENSE.txt")
        NSWorkspace.shared.open(url)
    }

    public func systemWillSleep() {
        guard !closed else { return }
        sleeping = true
        events.stop()
        delivery.reset()
        stopAudio()
        phase = enabled ? .sleeping : .off
    }

    public func systemDidWake() {
        guard !closed else { return }
        sleeping = false
        recovery.reset()
        Task { await poll() }
    }

    public func shutdown() async {
        closed = true
        enabled = false
        phase = .off
        delivery.reset()
        events.stop()
        pollTask?.cancel()
        pollTask = nil
        await stopAudio().value
    }

    func poll() async {
        guard !closed else { return }
        let request = revision
        let wasStarting = starting
        let update = await worker.poll()
        guard !closed else { return }
        if devices != update.devices { devices = update.devices }
        hasInputAccess = events.hasAccess
        guard request == revision else { return }
        if metrics != update.metrics { metrics = update.metrics }
        if !wasStarting && !starting {
            if running && !update.running {
                events.stop()
                stopAudio()
                if update.metrics.stalled {
                    recovery.recordFailure(now: now())
                    phase = .waiting
                    message = "The output stopped responding. Sidetone will try again."
                }
            } else {
                running = update.running
            }
            if update.running && update.metrics.callbacks > 0 { recovery.reset() }
        }
        reconcile()
    }

    private func reconcile() {
        guard !closed, !sleeping else { return }
        hasInputAccess = events.hasAccess
        guard enabled else {
            events.stop()
            if running || starting || activeOutput != nil { stopAudio() }
            phase = .off
            return
        }
        guard hasInputAccess else {
            events.stop()
            delivery.reset()
            if running || starting { stopAudio() }
            phase = .permission
            message =
                "Allow Sidetone in Input Monitoring. If macOS asks, quit and open Sidetone again."
            return
        }
        guard let output else {
            events.stop()
            delivery.reset()
            if running || starting { stopAudio() }
            phase = .waiting
            message = "Connect the selected output or choose another output."
            return
        }
        if let activeOutput, !sameOutput(activeOutput, output) {
            events.stop()
            delivery.reset()
            stopAudio()
            recovery.reset()
        }
        if starting { return }
        if !running {
            guard recovery.canAttempt(now: now()) else { return }
            start(output)
            return
        }
        configureDelivery()
        guard
            events.start(
                receive: { [delivery] in delivery.receive($0) },
                reset: { [delivery] in delivery.reset() })
        else {
            stopAudio()
            recovery.recordFailure(now: now())
            phase = .permission
            message =
                "Could not listen for keys. Check Input Monitoring, then open Sidetone again."
            return
        }
        phase = events.secureInput ? .secureInput : .listening
        if events.secureInput { delivery.reset() }
        message = nil
    }

    private func start(_ output: AudioDevice) {
        revision &+= 1
        let request = KeyboardAudioRequest(
            output: output, volumeDB: settings.volumeDB, revision: revision,
            volumeRevision: volumeRevision)
        starting = true
        phase = .starting
        activeOutput = output
        Task {
            let result = await worker.apply(request)
            guard request.revision == revision, !closed else { return }
            starting = false
            running = result.running
            if running {
                reconcile()
            } else {
                recovery.recordFailure(now: now())
                phase = .waiting
                message = result.error ?? "Could not start keyboard audio."
            }
        }
    }

    @discardableResult
    private func stopAudio() -> Task<Void, Never> {
        revision &+= 1
        let request = KeyboardAudioRequest(
            output: nil, volumeDB: settings.volumeDB, revision: revision,
            volumeRevision: volumeRevision)
        running = false
        starting = false
        activeOutput = nil
        configureDelivery()
        return Task { _ = await worker.apply(request) }
    }

    private func configureDelivery() {
        delivery.configure(
            enabled: enabled && running && !sleeping && !closed && hasInputAccess,
            settings: settings, revision: revision)
    }

    private func sameOutput(_ lhs: AudioDevice, _ rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id && lhs.uid == rhs.uid && lhs.sampleRate == rhs.sampleRate
            && lhs.outputChannels == rhs.outputChannels
            && lhs.outputDataSource == rhs.outputDataSource
            && lhs.outputJackState == rhs.outputJackState
            && lhs.outputLeftChannel == rhs.outputLeftChannel
            && lhs.outputRightChannel == rhs.outputRightChannel
    }
}
