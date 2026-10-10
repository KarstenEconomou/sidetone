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

    public func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }
}
