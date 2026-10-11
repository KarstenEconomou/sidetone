import AVFoundation
import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
public final class MonitorModel: ObservableObject {
    public enum Phase: Sendable { case off, starting, monitoring, waiting, sleeping }
    @Published public private(set) var settings: MonitorSettings
    @Published public private(set) var devices: [AudioDevice] = []
    @Published public private(set) var metrics = AudioMetrics()
    @Published public private(set) var enabled = false
    @Published public private(set) var phase = Phase.off
    @Published public private(set) var message: String?
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var launchAtLogin = false
    @Published public private(set) var loginNeedsApproval = false
    @Published public private(set) var loginError: String?
    private let store: SettingsStore
    private let worker: any AudioWorking
    private let requestPermission: @MainActor () async -> Bool
    private let now: @MainActor () -> Date
    private var recovery = RecoveryBackoff()
    private var generation: UInt64?
    private var revision: UInt64 = 0
    private var parameterRevision: UInt64 = 0
    private var resumeRoute: AudioRoute?
    private var deviceTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var sleeping = false
    private var closed = false
    private var isPolling = false
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []
    private var permissionGranted = false

    public convenience init(store: SettingsStore = SettingsStore()) {
        self.init(
            store: store, worker: AudioWorker(),
            requestPermission: {
                let permission = AVCaptureDevice.authorizationStatus(for: .audio)
                if permission == .notDetermined {
                    return await AVCaptureDevice.requestAccess(for: .audio)
                }
                return permission == .authorized
            })
    }

    init(
        store: SettingsStore, worker: any AudioWorking,
        requestPermission: @escaping @MainActor () async -> Bool,
        now: @escaping @MainActor () -> Date = { Date() }, startPolling: Bool = true
    ) {
        self.store = store
        self.worker = worker
        self.requestPermission = requestPermission
        self.now = now
        self.settings = store.load()
        guard startPolling else { return }
        refreshLoginStatus()
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.pollDevices()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public var inputDevices: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    public var outputDevices: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }
    public var route: AudioRoute? { RouteSelection.resolve(settings: settings, devices: devices) }
    public var status: String {
        switch phase {
        case .off: "Off"
        case .starting: "Starting…"
        case .monitoring: "Monitoring"
        case .waiting: "Waiting for device"
        case .sleeping: "Paused for sleep"
        }
    }

    public func setEnabled(_ value: Bool) {
        guard !closed else { return }
        if value {
            guard !enabled else { return }
            enabled = true
            recovery.reset()
            message = nil
            permissionDenied = false
            permissionGranted = false
            revision &+= 1
            let request = revision
            phase = .starting
            Task {
                let granted = await requestPermission()
                guard self.enabled, self.revision == request, !self.closed else { return }
                guard granted else {
                    self.permissionDenied = true
                    self.stop(message: "Allow microphone access in System Settings.")
                    return
                }
                self.permissionGranted = true
                await self.pollDevices(force: true, handleRecovery: false)
                guard self.enabled, self.revision == request else { return }
                self.resumeRoute = self.route
                self.startCurrentRoute(recovering: false)
            }
        } else {
            stop()
        }
    }

    public func updateSettings(_ update: (inout MonitorSettings) -> Void) {
        guard !closed else { return }
        let previous = settings
        var next = settings
        update(&next)
        next.normalize()
        guard next != previous else { return }
        settings = next
        parameterRevision &+= 1
        let parameters = parameterRevision
        store.save(next)
        if previous.inputUID != next.inputUID || previous.outputUID != next.outputUID {
            stop(message: "Device selected. Turn on microphone monitoring when ready.")
        } else if previous.bufferFrames != next.bufferFrames
            || previous.inputChannel != next.inputChannel
        {
            recovery.reset()
            if enabled && !sleeping && permissionGranted { startCurrentRoute(recovering: true) }
        } else {
            Task { await worker.setParameters(next, revision: parameters) }
        }
    }

    public func setInterfaceVisible(_ visible: Bool) {
        guard !closed, visible != (meterTask != nil) else { return }
        meterTask?.cancel()
        meterTask = nil
        if visible {
            refreshLoginStatus()
            Task { await pollDevices(force: true) }
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    await self?.refreshMetrics()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    public func systemWillSleep() {
        guard !closed else { return }
        sleeping = true
        guard enabled else { return }
        guard permissionGranted else {
            stop(message: "Monitoring is off. Turn on Sidetone after the Mac wakes.")
            return
        }
        phase = .sleeping
        stopAudio()
    }

    public func systemDidWake() {
        guard !closed else { return }
        sleeping = false
        guard enabled else { return }
        Task {
            await pollDevices(force: true, handleRecovery: false)
            guard enabled, !sleeping else { return }
            startCurrentRoute(recovering: true)
        }
    }

    public func setLaunchAtLogin(_ value: Bool) {
        loginError = nil
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            loginError = "Could not change launch at login: \(error.localizedDescription)"
            refreshLoginStatus()
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
            NSWorkspace.shared.open(url)
        }
    }

    public func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    public func reportError(_ error: String) { message = error }

    public func shutdown() async {
        closed = true
        deviceTask?.cancel()
        meterTask?.cancel()
        deviceTask = nil
        meterTask = nil
        _ = await stop().value
    }

    private func nextRequest(route: AudioRoute?) -> AudioRequest {
        revision &+= 1
        return AudioRequest(
            route: route, settings: settings, revision: revision,
            parameterRevision: parameterRevision)
    }

    @discardableResult
    private func stopAudio() -> Task<EngineResult, Never> {
        let request = nextRequest(route: nil)
        return Task { [worker] in await worker.apply(request) }
    }

    private func refreshMetrics() async {
        guard enabled, phase == .monitoring else { return }
        let request = revision
        let value = await worker.metrics()
        guard phase == .monitoring, revision == request else { return }
        metrics = value
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    @discardableResult
    private func stop(message: String? = nil) -> Task<EngineResult, Never> {
        enabled = false
        permissionGranted = false
        phase = .off
        self.message = message
        resumeRoute = nil
        recovery.reset()
        metrics.peakInput = 0
        metrics.peakOutput = 0
        metrics.running = false
        return stopAudio()
    }

    private func startCurrentRoute(recovering: Bool) {
        guard enabled, permissionGranted, !sleeping, !closed else { return }
        guard let route else {
            phase = .waiting
            message = "The selected device or input channel is unavailable."
            stopAudio()
            return
        }
        if recovering && !RouteSelection.canResume(previous: resumeRoute, next: route) {
            stop(message: "The audio route changed. Check the output, then turn on Sidetone.")
            return
        }
        if recovering && settings.gainDB > -18 {
            settings.gainDB = -18
            parameterRevision &+= 1
            store.save(settings)
        }
        resumeRoute = route
        phase = .starting
        message = nil
        let request = nextRequest(route: route)
        Task {
            let result = await worker.apply(request)
            guard revision == request.revision, enabled, !closed else { return }
            if result.running {
                phase = .monitoring
                recovery.reset()
            } else {
                phase = .waiting
                recovery.recordFailure(now: now())
                message =
                    (result.error ?? "The audio engine could not start.")
                    + " Sidetone will try again."
            }
        }
    }

    func pollDevices(force: Bool = false, handleRecovery: Bool = true) async {
        while isPolling {
            guard force, !closed else { return }
            await withCheckedContinuation { pollWaiters.append($0) }
        }
        guard !closed else { return }
        isPolling = true
        defer {
            isPolling = false
            let waiters = pollWaiters
            pollWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let request = revision
        let update = await worker.poll(
            generation: force ? nil : generation,
            includeMetrics: enabled && !sleeping)
        guard !closed else { return }
        generation = update.generation
        if let devices = update.devices { self.devices = devices }
        if let metrics = update.metrics, phase == .monitoring, revision == request {
            self.metrics = metrics
        }
        guard handleRecovery, enabled, permissionGranted, !sleeping, revision == request,
            phase != .starting
        else { return }
        if let metrics = update.metrics, metrics.restartReasons.contains(.outputRoute) {
            stop(message: "The output changed. Check your headphones, then turn on Sidetone.")
            return
        }
        guard let next = route else {
            if phase != .waiting {
                phase = .waiting
                message = "Waiting for the selected audio device."
                _ = await stopAudio().value
            }
            return
        }
        if let previous = resumeRoute, !previous.hasSameIdentity(as: next) {
            stop(message: "The audio route changed. Check the output, then turn on Sidetone.")
        } else if phase == .waiting || update.metrics?.restartReasons.isEmpty == false
            || update.metrics?.running == false
        {
            if recovery.canAttempt(now: now()) { startCurrentRoute(recovering: true) }
        }
    }
}
