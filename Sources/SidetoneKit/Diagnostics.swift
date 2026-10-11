import AppKit
import Foundation

extension MonitorModel {
    public var diagnostics: String {
        """
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
        Input buffer duration: \(String(format: "%.2f", metrics.inputBufferDurationMs)) ms
        Output buffer duration: \(String(format: "%.2f", metrics.outputBufferDurationMs)) ms
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
    }

    public func copyDiagnostics(including keyboard: KeyboardModel? = nil) {
        NSPasteboard.general.clearContents()
        let report = diagnostics + (keyboard.map { "\n\n" + $0.diagnostics } ?? "")
        NSPasteboard.general.setString(report, forType: .string)
    }
}

extension KeyboardModel {
    public var diagnostics: String {
        """
        Keyboard sounds
        State: \(status)
        Output: \(output?.name ?? "Unavailable")
        Switch: \(settings.switchType.name)
        Volume: \(settings.volumeDB.formatted()) dB
        Input Monitoring: \(hasInputAccess ? "Allowed" : "Not allowed")
        Release sounds: \(settings.releaseSounds)
        Modifier keys: \(settings.modifierSounds)
        Key repeat: \(settings.repeatSounds)
        Vary recordings: \(settings.varySamples)
        Output: \(Int(metrics.outputRate)) Hz / \(metrics.outputFrames) frames
        Output callbacks: \(metrics.callbacks)
        Maximum callback: \(String(format: "%.3f", metrics.maxCallbackMs)) ms
        Maximum queue wait: \(String(format: "%.3f", metrics.maxQueueMs)) ms
        Callback overruns: \(metrics.deadlineMisses)
        Queued sounds: \(metrics.enqueued)
        Queue drops: \(metrics.queueDrops)
        Voice drops: \(metrics.voiceDrops)
        Stale sound drops: \(metrics.staleDrops)
        Peak voices: \(metrics.peakVoices) / 64
        Protected frames: \(metrics.clippedFrames)
        Output stalled: \(metrics.stalled)
        """
    }
}
