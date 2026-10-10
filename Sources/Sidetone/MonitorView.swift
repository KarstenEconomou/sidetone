import AppKit
import SidetoneKit
import SwiftUI

@MainActor struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MonitorHeader(model: model, title: "Sidetone")
                .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                devices
                volume
                sound
                latency
                if let message = model.message {
                    notice(message)
                }
            }
            .padding(16)
            Divider()
            HStack {
                Button(action: openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Label("Input", systemImage: "mic")
                        .foregroundStyle(.secondary)
                    devicePicker("Input", devices: model.inputDevices, path: \.inputUID)
                }
                GridRow {
                    Label("Output", systemImage: "headphones")
                        .foregroundStyle(.secondary)
                    devicePicker("Output", devices: model.outputDevices, path: \.outputUID)
                }
            }
            if model.route?.output.name.localizedCaseInsensitiveContains("speaker") == true {
                Label(
                    "Use headphones to prevent feedback.", systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                MetricRow("Microphone level", levelText)
                LevelMeter(peak: model.phase == .monitoring ? model.metrics.peakInput : 0)
                    .frame(height: 4)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue(levelText)
            }
        }
    }

    private var volume: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Monitor volume")
                Spacer()
                Text(model.settings.gainDB, format: .number.precision(.fractionLength(0)))
                    + Text(" dB")
            }
            .monospacedDigit()
            Slider(value: model.binding(\.gainDB), in: -60...0)
                .accessibilityLabel("Monitor volume in decibels")
            HStack {
                Text("−60 dB")
                Spacer()
                Text("0 dB")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Sound").font(.caption).foregroundStyle(.secondary)
            ProfilePicker(model: model)
            Text(model.settings.profile.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var latency: some View {
        HStack {
            Label("Latency estimate", systemImage: "timer")
            Spacer()
            if model.phase == .monitoring {
                Text(
                    model.metrics.estimatedLatencyMs, format: .number.precision(.fractionLength(1)))
                    + Text(" ms")
            } else {
                Text("—")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help(
            "Available while monitoring. This estimate uses device reports and the audio queue. It is not a physical measurement."
        )
    }

    private func notice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if model.permissionDenied {
                Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var levelText: String {
        guard model.phase == .monitoring else { return "Off" }
        guard model.metrics.peakInput > 0.00001 else { return "−∞ dBFS" }
        return String(format: "%.0f dBFS", 20 * log10(model.metrics.peakInput))
    }

    @ViewBuilder private func devicePicker(
        _ title: String, devices: [AudioDevice], path: WritableKeyPath<MonitorSettings, String?>
    ) -> some View {
        let current = devices.first { path == \.inputUID ? $0.isDefaultInput : $0.isDefaultOutput }
        let saved = model.settings[keyPath: path]
        let label =
            saved.map { uid in
                devices.first { $0.uid == uid }?.name ?? "Saved device (unavailable)"
            } ?? current.map { "Default — \($0.name)" } ?? "Default (unavailable)"
        let menu = Menu {
            Picker(title, selection: model.binding(path)) {
                Text("System default").tag(nil as String?)
                Divider()
                ForEach(devices) { device in Text(device.name).tag(Optional(device.uid)) }
                if let saved, !devices.contains(where: { $0.uid == saved }) {
                    Divider()
                    Text("Saved device (unavailable)").tag(Optional(saved))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(title) device")
        .accessibilityValue(label)

        if #available(macOS 26.0, *) {
            menu.buttonSizing(.flexible)
        } else {
            menu
        }
    }
}
