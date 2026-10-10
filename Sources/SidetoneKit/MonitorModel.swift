import AppKit
import AVFoundation
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
    private var popoverVisible = false
    private var isPolling = false
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []
    private var permissionGranted = false

    public convenience init(store: SettingsStore = SettingsStore()) {
        self.init(store: store, worker: AudioWorker(), requestPermission: {
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            if permission == .notDetermined { return await AVCaptureDevice.requestAccess(for: .audio) }
            return permission == .authorized
        })
    }

    init(store: SettingsStore, worker: any AudioWorking,
         requestPermission: @escaping @MainActor () async -> Bool,
         now: @escaping @MainActor () -> Date = { Date() }, startPolling: Bool = true) {
        self.store = store
        self.worker = worker
        self.requestPermission = requestPermission
        self.now = now
        self.settings = store.load()
        guard startPolling else { return }
        refreshLoginStatus()
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
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
        } else { stop() }
    }

    public func updateSettings(_ update: (inout MonitorSettings) -> Void) {
        let previous = settings
        var next = settings
        update(&next)
        next.normalize()
        settings = next
        parameterRevision &+= 1
        let parameters = parameterRevision
        store.save(next)
        if previous.inputUID != next.inputUID || previous.outputUID != next.outputUID {
            stop(message: "Device selected. Turn on Sidetone when ready.")
        } else if previous.bufferFrames != next.bufferFrames || previous.inputChannel != next.inputChannel {
            recovery.reset()
            if enabled && !sleeping && permissionGranted { startCurrentRoute(recovering: true) }
        } else {
            Task { await worker.setParameters(next, revision: parameters) }
        }
    }

    public func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        meterTask?.cancel()
        meterTask = nil
        if visible {
            refreshLoginStatus()
            Task { await pollDevices(force: true) }
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.enabled && self.phase == .monitoring {
                        let value = await self.worker.metrics()
                        if self.phase == .monitoring { self.metrics = value }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    public func systemWillSleep() {
        sleeping = true
        guard enabled else { return }
        guard permissionGranted else {
            stop(message: "Monitoring is off. Turn on Sidetone after the Mac wakes.")
            return
        }
        phase = .sleeping
        revision &+= 1
        let request = revision
        let settings = settings
        let parameters = parameterRevision
        Task { _ = await worker.apply(route: nil, settings: settings, revision: request, parameterRevision: parameters) }
    }

    public func systemDidWake() {
        sleeping = false
        guard enabled else { return }
        Task {
            await pollDevices(force: true, handleRecovery: false)
            guard enabled, !sleeping else { return }
            if route == nil {
                phase = .waiting
            } else if RouteSelection.canResume(previous: resumeRoute, next: route) {
                startCurrentRoute(recovering: true)
            } else {
                stop(message: "The audio route changed. Check the output, then turn on Sidetone.")
            }
        }
    }

    public func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            message = "Could not change launch at login: \(error.localizedDescription)"
            refreshLoginStatus()
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    public func reportError(_ error: String) { message = error }

    public func copyDiagnostics() {
        let text = """
        Sidetone diagnostics
        State: \(status)
        Input: \(route?.input.name ?? "Unavailable")
        Output: \(route?.output.name ?? "Unavailable")
        Profile: \(settings.profile.rawValue)
        Gain: \(String(format: "%.1f", settings.gainDB)) dB
        Input: \(Int(metrics.inputRate)) Hz / \(metrics.inputFrames) frames
        Output: \(Int(metrics.outputRate)) Hz / \(metrics.outputFrames) frames
        Estimated latency: \(String(format: "%.2f", metrics.estimatedLatencyMs)) ms
        Device input latency: \(String(format: "%.2f", metrics.inputDeviceLatencyMs)) ms
        Device output latency: \(String(format: "%.2f", metrics.outputDeviceLatencyMs)) ms
        Input buffer duration: \(String(format: "%.2f", metrics.inputRate > 0 ? Double(metrics.inputFrames) / metrics.inputRate * 1000 : 0)) ms
        Output buffer duration: \(String(format: "%.2f", metrics.outputRate > 0 ? Double(metrics.outputFrames) / metrics.outputRate * 1000 : 0)) ms
        Queue latency: \(String(format: "%.2f", metrics.queueLatencyMs)) ms
        Resampler latency: \(String(format: "%.2f", metrics.resamplerLatencyMs)) ms
        Maximum callback: \(String(format: "%.3f", metrics.maxCallbackMs)) ms
        Maximum DSP: \(String(format: "%.3f", metrics.maxDSPMs)) ms
        Clock correction: \(String(format: "%.1f", metrics.driftPPM)) ppm
        Input callbacks: \(metrics.inputCallbacks)
        Output callbacks: \(metrics.outputCallbacks)
        Underruns: \(metrics.underruns)
        Overruns: \(metrics.overruns)
        Callback overruns: \(metrics.deadlineMisses)
        Hardware overloads: \(metrics.hardwareOverloads)
        Protected samples: \(metrics.clippedSamples)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func shutdown() async {
        closed = true
        enabled = false
        permissionGranted = false
        deviceTask?.cancel(); meterTask?.cancel()
        deviceTask = nil; meterTask = nil
        revision &+= 1
        _ = await worker.apply(route: nil, settings: settings, revision: revision, parameterRevision: parameterRevision)
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    private func stop(message: String? = nil) {
        enabled = false
        permissionGranted = false
        phase = .off
        self.message = message
        resumeRoute = nil
        recovery.reset()
        revision &+= 1
        let request = revision
        let settings = settings
        let parameters = parameterRevision
        metrics.peakInput = 0; metrics.peakOutput = 0; metrics.running = false
        Task { _ = await worker.apply(route: nil, settings: settings, revision: request, parameterRevision: parameters) }
    }

    private func startCurrentRoute(recovering: Bool) {
        guard enabled, permissionGranted, !sleeping, !closed else { return }
        guard let route else {
            phase = .waiting
            message = "The selected device or input channel is unavailable."
            revision &+= 1
            let request = revision
            let settings = settings
            let parameters = parameterRevision
            Task { _ = await worker.apply(route: nil, settings: settings, revision: request, parameterRevision: parameters) }
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
        revision &+= 1
        let request = revision
        let settings = settings
        let parameters = parameterRevision
        Task {
            let result = await worker.apply(route: route, settings: settings, revision: request, parameterRevision: parameters)
            guard revision == request, enabled, !closed else { return }
            if result.running {
                phase = .monitoring
                recovery.reset()
            } else {
                phase = .waiting
                recovery.recordFailure(now: now())
                message = (result.error ?? "The audio engine could not start.") + " Sidetone will try again."
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
        let update = await worker.poll(generation: force ? nil : generation,
                                       includeMetrics: enabled && !sleeping)
        guard !closed else { return }
        generation = update.generation
        if let devices = update.devices { self.devices = devices }
        if let metrics = update.metrics, phase == .monitoring { self.metrics = metrics }
        guard handleRecovery, enabled, permissionGranted, !sleeping, revision == request, phase != .starting else { return }
        if let metrics = update.metrics, metrics.needsRestart & 2 != 0 {
            stop(message: "The output changed. Check your headphones, then turn on Sidetone.")
            return
        }
        guard let next = route else {
            if phase != .waiting {
                phase = .waiting
                message = "Waiting for the selected audio device."
                revision &+= 1
                _ = await worker.apply(route: nil, settings: settings, revision: revision, parameterRevision: parameterRevision)
            }
            return
        }
        if let previous = resumeRoute, !previous.hasSameDevices(as: next) {
            stop(message: "The audio route changed. Check the output, then turn on Sidetone.")
        } else if phase == .waiting || update.metrics?.needsRestart != 0 || update.metrics?.running == false {
            if recovery.canAttempt(now: now()) { startCurrentRoute(recovering: true) }
        }
    }
}
