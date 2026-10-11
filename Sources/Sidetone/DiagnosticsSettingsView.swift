import SidetoneKit
import SwiftUI

@MainActor
struct DiagnosticsSettingsView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var keyboard: KeyboardModel
    @State private var copied = false

    var body: some View {
        SettingsForm {
            Section("Status") {
                MetricRow("Microphone monitoring", model.status)
                MetricRow("Keyboard sounds", keyboard.status)
            }
            Section {
                MetricRow("Peak input", levelText)
                LevelMeter(peak: model.phase == .monitoring ? model.metrics.peakInput : 0)
                    .frame(height: 6)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue(levelText)
            } header: {
                Text("Microphone level")
            }
            Section {
                MetricRow("Estimated total", milliseconds(model.metrics.estimatedLatencyMs))
                DisclosureGroup("Latency details") {
                    MetricRow("Input device", milliseconds(model.metrics.inputDeviceLatencyMs))
                    MetricRow("Output device", milliseconds(model.metrics.outputDeviceLatencyMs))
                    MetricRow("Input buffer", milliseconds(model.metrics.inputBufferDurationMs))
                    MetricRow("Output buffer", milliseconds(model.metrics.outputBufferDurationMs))
                    MetricRow("Audio queue", milliseconds(model.metrics.queueLatencyMs))
                    MetricRow("Resampler", milliseconds(model.metrics.resamplerLatencyMs))
                }
            } header: {
                Text("Microphone latency")
            } footer: {
                Text(
                    "\(sessionDescription) These estimates use device reports and the audio queue, not physical measurements."
                )
            }
            Section("Audio format") {
                MetricRow(
                    "Input",
                    format(rate: model.metrics.inputRate, frames: model.metrics.inputFrames))
                MetricRow(
                    "Output",
                    format(rate: model.metrics.outputRate, frames: model.metrics.outputFrames))
            }
            Section {
                DisclosureGroup("Performance") {
                    MetricRow(
                        "Maximum callback", milliseconds(model.metrics.maxCallbackMs, precision: 3))
                    MetricRow("Maximum DSP", milliseconds(model.metrics.maxDSPMs, precision: 3))
                    MetricRow(
                        "Clock correction",
                        hasMetrics
                            ? "\(model.metrics.driftPPM.formatted(.number.precision(.fractionLength(0)))) ppm"
                            : "—")
                }
                DisclosureGroup("Audio events") {
                    MetricRow("Underruns", count(model.metrics.underruns))
                    MetricRow("Overruns", count(model.metrics.overruns))
                    MetricRow("Callback overruns", count(model.metrics.deadlineMisses))
                    MetricRow("Hardware overloads", count(model.metrics.hardwareOverloads))
                    MetricRow("Protected samples", count(model.metrics.clippedSamples))
                }
            }
            Section {
                DisclosureGroup("Keyboard performance") {
                    MetricRow(
                        "Output",
                        keyboardValue(
                            "\(Int(keyboard.metrics.outputRate).formatted()) Hz · \(keyboard.metrics.outputFrames) frames"
                        ))
                    MetricRow(
                        "Maximum callback", keyboardMilliseconds(keyboard.metrics.maxCallbackMs))
                    MetricRow(
                        "Maximum queue wait", keyboardMilliseconds(keyboard.metrics.maxQueueMs))
                    MetricRow(
                        "Callback overruns",
                        keyboardValue(keyboard.metrics.deadlineMisses.formatted()))
                    MetricRow("Queued sounds", keyboardValue(keyboard.metrics.enqueued.formatted()))
                    MetricRow("Queue drops", keyboardValue(keyboard.metrics.queueDrops.formatted()))
                    MetricRow("Voice drops", keyboardValue(keyboard.metrics.voiceDrops.formatted()))
                    MetricRow(
                        "Stale sound drops", keyboardValue(keyboard.metrics.staleDrops.formatted()))
                    MetricRow("Peak voices", keyboardValue("\(keyboard.metrics.peakVoices) of 64"))
                    MetricRow(
                        "Protected frames",
                        keyboardValue(keyboard.metrics.clippedFrames.formatted()))
                }
            } footer: {
                Text(
                    "Queue wait ends when the audio callback reads a sound. It excludes the output device delay. Counts reset when keyboard output starts."
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    model.copyDiagnostics(including: keyboard)
                    copied = true
                } label: {
                    Label(
                        copied ? "Copied" : "Copy Diagnostics",
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the current microphone and keyboard diagnostics.")
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private var hasMetrics: Bool { model.metrics.outputCallbacks > 0 }

    private var sessionDescription: String {
        guard hasMetrics else { return "Turn on microphone monitoring to collect data." }
        return model.phase == .monitoring
            ? "Live microphone data." : "Data from the last microphone session."
    }

    private var levelText: String {
        guard model.phase == .monitoring else { return "Off" }
        guard model.metrics.peakInput > 0.00001 else { return "−∞ dBFS" }
        return
            "\((20 * log10(model.metrics.peakInput)).formatted(.number.precision(.fractionLength(0)))) dBFS"
    }

    private func format(rate: Double, frames: Int) -> String {
        guard hasMetrics else { return "—" }
        return "\(Int(rate).formatted()) Hz · \(frames) frames"
    }

    private func milliseconds(_ value: Double, precision: Int = 2) -> String {
        guard hasMetrics else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(precision)))) ms"
    }

    private func count(_ value: UInt64) -> String {
        hasMetrics ? value.formatted() : "—"
    }

    private func keyboardValue(_ value: String) -> String {
        keyboard.metrics.callbacks > 0 ? value : "—"
    }

    private func keyboardMilliseconds(_ value: Double) -> String {
        keyboardValue("\(value.formatted(.number.precision(.fractionLength(3)))) ms")
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct LevelMeter: View {
    let peak: Double
    private var fraction: Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(peak) + 60) / 60))
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(peak >= 0.98 ? Color.orange : Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
        }
    }
}
