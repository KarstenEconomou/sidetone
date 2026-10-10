import SidetoneKit
import SwiftUI

@MainActor struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case sound = "Sound"
        case devices = "Devices"
        case general = "General"
        case diagnostics = "Diagnostics"
        var id: Self { self }
    }

    @ObservedObject var model: MonitorModel
    let openAbout: () -> Void
    @State private var pane = Pane.sound

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $pane) {
                ForEach(Pane.allCases) { pane in Text(pane.rawValue).tag(pane) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Group {
                switch pane {
                case .sound: sound
                case .devices: devices
                case .general: general
                case .diagnostics: diagnostics
                }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 460, height: 520)
    }

    private var sound: some View {
        Form {
            Section {
                ProfilePicker(model: model)
            }
            Section {
                SettingSlider(
                    "High-pass filter", value: model.binding(\.highPassHz), range: 20...250,
                    unit: "Hz"
                )
                .help("Reduces low-frequency sound.")
                SettingSlider(
                    "EQ frequency", value: model.binding(\.eqFrequencyHz), range: 100...10000,
                    unit: "Hz", logarithmic: true
                )
                .help("Selects the frequency for tone shaping.")
                SettingSlider(
                    "EQ gain", value: model.binding(\.eqGainDB), range: -12...12, unit: "dB",
                    precision: 1
                )
                .help("Boosts or reduces sound at the selected EQ frequency.")
                SettingSlider(
                    "EQ width", value: model.binding(\.eqQ), range: 0.2...5, unit: "Q", precision: 1
                )
                .help(
                    "Lower Q affects a wider range of frequencies. Higher Q affects a narrower range."
                )
                Toggle("Gentle compression", isOn: model.binding(\.compression))
                    .help("Reduces louder sounds without increasing quiet sounds.")
            } header: {
                Text("Voice shaping")
            } footer: {
                if model.settings.profile == .direct {
                    Text("Select Natural or Voice to use voice shaping.")
                }
            }
            .disabled(model.settings.profile == .direct)
        }
    }

    private var devices: some View {
        Form {
            Section {
                Picker("Buffer size", selection: model.binding(\.bufferFrames)) {
                    ForEach([32, 64, 128, 256, 512], id: \.self) { frames in
                        Text("\(frames) frames").tag(frames)
                    }
                    if ![32, 64, 128, 256, 512].contains(model.settings.bufferFrames) {
                        Text("\(model.settings.bufferFrames) frames").tag(
                            model.settings.bufferFrames)
                    }
                }
                Picker("Input channel", selection: model.binding(\.inputChannel)) {
                    ForEach(0..<max(1, selectedInputChannels), id: \.self) { channel in
                        Text("Channel \(channel + 1)").tag(channel)
                    }
                    if model.settings.inputChannel >= max(1, selectedInputChannels) {
                        Text("Channel \(model.settings.inputChannel + 1) (unavailable)")
                            .tag(model.settings.inputChannel)
                    }
                }
            } footer: {
                Text(
                    "The device can use a different buffer size. Smaller buffers can reduce latency."
                )
            }
            Section("Active format") {
                MetricRow(
                    "Input",
                    format(rate: model.metrics.inputRate, frames: model.metrics.inputFrames))
                MetricRow(
                    "Output",
                    format(rate: model.metrics.outputRate, frames: model.metrics.outputFrames))
            }
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle(
                    "Launch at login",
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
                )
                if model.loginNeedsApproval {
                    Button("Allow in Login Items") { model.openLoginSettings() }
                }
            } footer: {
                Text("Monitoring is off when Sidetone opens.")
            }
            Section {
                Toggle("Global shortcut", isOn: model.binding(\.globalShortcut))
                LabeledContent("Toggle monitoring", value: "⇧⌘M")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("About Sidetone", action: openAbout)
            } footer: {
                Text("Audio stays on this Mac. Sidetone does not record audio.")
            }
        }
    }

    private var diagnostics: some View {
        Form {
            Section {
                MetricRow("Estimated total", milliseconds(model.metrics.estimatedLatencyMs))
                MetricRow("Input device", milliseconds(model.metrics.inputDeviceLatencyMs))
                MetricRow("Output device", milliseconds(model.metrics.outputDeviceLatencyMs))
                MetricRow("Input buffer", milliseconds(model.metrics.inputBufferDurationMs))
                MetricRow("Output buffer", milliseconds(model.metrics.outputBufferDurationMs))
                MetricRow("Audio queue", milliseconds(model.metrics.queueLatencyMs))
                MetricRow("Resampler", milliseconds(model.metrics.resamplerLatencyMs))
            } header: {
                HStack {
                    Text("Latency")
                    Spacer()
                    Text(
                        hasMetrics
                            ? (model.phase == .monitoring ? "Live" : "Last session") : "No data"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "These values use device reports and the audio queue. They are not physical measurements."
                )
            }
            Section("Performance") {
                MetricRow(
                    "Maximum callback", milliseconds(model.metrics.maxCallbackMs, precision: 3))
                MetricRow("Maximum DSP", milliseconds(model.metrics.maxDSPMs, precision: 3))
                MetricRow(
                    "Clock correction",
                    hasMetrics ? String(format: "%.0f ppm", model.metrics.driftPPM) : "—")
            }
            Section("Audio events") {
                MetricRow("Underruns", count(model.metrics.underruns))
                MetricRow("Overruns", count(model.metrics.overruns))
                MetricRow("Callback overruns", count(model.metrics.deadlineMisses))
                MetricRow("Hardware overloads", count(model.metrics.hardwareOverloads))
                MetricRow("Protected samples", count(model.metrics.clippedSamples))
            }
            Button("Copy Diagnostics") { model.copyDiagnostics() }
        }
    }

    private var selectedInputChannels: Int {
        model.inputDevices.first { device in
            model.settings.inputUID.map { $0 == device.uid } ?? device.isDefaultInput
        }?.inputChannels ?? 0
    }

    private func format(rate: Double, frames: Int) -> String {
        guard model.phase == .monitoring else { return "Off" }
        return "\(Int(rate).formatted()) Hz · \(frames) frames"
    }

    private func milliseconds(_ value: Double, precision: Int = 2) -> String {
        guard hasMetrics else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(precision)))) ms"
    }

    private var hasMetrics: Bool { model.metrics.outputCallbacks > 0 }

    private func count(_ value: UInt64) -> String {
        hasMetrics ? value.formatted() : "—"
    }
}
