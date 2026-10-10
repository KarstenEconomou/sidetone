import SidetoneKit
import SwiftUI

@MainActor struct AdvancedView: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device configuration").font(.headline)
            Picker("Requested buffer", selection: model.binding(\.bufferFrames)) {
                ForEach([32, 64, 128, 256, 512], id: \.self) { frames in
                    Text("\(frames) frames").tag(frames)
                }
            }
            Text("The device can select a larger buffer.").font(.caption).foregroundStyle(
                .secondary)
            Picker("Microphone channel", selection: model.binding(\.inputChannel)) {
                ForEach(0..<max(1, selectedInputChannels), id: \.self) { channel in
                    Text("Channel \(channel + 1)").tag(channel)
                }
                if model.settings.inputChannel >= max(1, selectedInputChannels) {
                    Text("Channel \(model.settings.inputChannel + 1) (unavailable)").tag(
                        model.settings.inputChannel)
                }
            }
            if model.phase == .monitoring {
                MetricRow(
                    "Input",
                    "\(Int(model.metrics.inputRate)) Hz · \(model.metrics.inputFrames) frames")
                MetricRow(
                    "Output",
                    "\(Int(model.metrics.outputRate)) Hz · \(model.metrics.outputFrames) frames")
            }
            Divider()
            Text("Voice processing").font(.headline)
            if model.settings.profile == .direct {
                Text("Direct uses gain and output protection.").font(.caption).foregroundStyle(
                    .secondary)
            } else {
                slider("High-pass filter", path: \.highPassHz, range: 20...250, unit: "Hz")
                slider("EQ frequency", path: \.eqFrequencyHz, range: 100...10000, unit: "Hz")
                slider(
                    "EQ gain", path: \.eqGainDB, range: -12...12, unit: "dB", step: 0.5,
                    precision: 1)
                HStack {
                    Text("EQ width (Q)")
                    Spacer()
                    Text(String(format: "%.1f", model.settings.eqQ)).foregroundStyle(.secondary)
                        .monospacedDigit()
                }.font(.caption)
                Slider(value: model.binding(\.eqQ), in: 0.2...5, step: 0.1).accessibilityLabel(
                    "EQ width")
                Toggle("Gentle compression", isOn: model.binding(\.compression))
            }
            Divider()
            Text("System").font(.headline)
            Toggle(
                "Launch at login",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if model.loginNeedsApproval {
                Button("Allow in Login Items") { model.openLoginSettings() }
            }
            Toggle("Global shortcut: ⇧⌘M", isOn: model.binding(\.globalShortcut))
            Text("Monitoring is off when the app opens.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Diagnostics").font(.headline)
            MetricRow("Maximum callback", String(format: "%.3f ms", model.metrics.maxCallbackMs))
            MetricRow("Maximum DSP", String(format: "%.3f ms", model.metrics.maxDSPMs))
            MetricRow(
                "Device input latency",
                String(format: "%.2f ms", model.metrics.inputDeviceLatencyMs))
            MetricRow(
                "Device output latency",
                String(format: "%.2f ms", model.metrics.outputDeviceLatencyMs))
            MetricRow(
                "Input buffer duration",
                String(format: "%.2f ms", model.metrics.inputBufferDurationMs))
            MetricRow(
                "Output buffer duration",
                String(format: "%.2f ms", model.metrics.outputBufferDurationMs))
            MetricRow("Queue latency", String(format: "%.2f ms", model.metrics.queueLatencyMs))
            MetricRow(
                "Resampler latency", String(format: "%.2f ms", model.metrics.resamplerLatencyMs))
            MetricRow("Clock correction", String(format: "%.0f ppm", model.metrics.driftPPM))
            MetricRow(
                "Underruns / overruns", "\(model.metrics.underruns) / \(model.metrics.overruns)")
            MetricRow("Callback overruns", "\(model.metrics.deadlineMisses)")
            MetricRow("Hardware overloads", "\(model.metrics.hardwareOverloads)")
            MetricRow("Protected samples", "\(model.metrics.clippedSamples)")
            Button("Copy Diagnostics") { model.copyDiagnostics() }
            Text("Audio stays on this Mac. Sidetone does not record audio.")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }

    private var selectedInputChannels: Int {
        model.inputDevices.first { device in
            model.settings.inputUID.map { $0 == device.uid } ?? device.isDefaultInput
        }?.inputChannels ?? 1
    }

    private func slider(
        _ title: String, path: WritableKeyPath<MonitorSettings, Double>,
        range: ClosedRange<Double>, unit: String, step: Double = 1, precision: Int = 0
    ) -> some View {
        VStack(spacing: 3) {
            MetricRow(
                title,
                "\(model.settings[keyPath: path].formatted(.number.precision(.fractionLength(precision)))) \(unit)"
            )
            Slider(value: model.binding(path), in: range, step: step)
                .accessibilityLabel(title)
        }
    }
}
