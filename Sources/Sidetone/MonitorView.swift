import AppKit
import SidetoneKit
import SwiftUI

@MainActor struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sidetone").font(.headline)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Enable Sidetone",
                    isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })
                )
                .toggleStyle(.switch).labelsHidden()
                .accessibilityLabel("Enable Sidetone")
            }

            Divider()

            VStack(spacing: 10) {
                devicePicker(
                    title: "Input", symbol: "mic", devices: model.inputDevices, keyPath: \.inputUID)
                devicePicker(
                    title: "Output", symbol: "headphones", devices: model.outputDevices,
                    keyPath: \.outputUID)
            }

            if model.route?.output.name.localizedCaseInsensitiveContains("speaker") == true {
                Text("Use headphones to prevent feedback.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Microphone").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(levelText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                LevelMeter(peak: model.phase == .monitoring ? model.metrics.peakInput : 0)
                    .frame(height: 5)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue(levelText)
            }

            VStack(spacing: 6) {
                HStack {
                    Text("Monitor gain")
                    Spacer()
                    Text(String(format: "%.0f dB", model.settings.gainDB)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: model.binding(\.gainDB), in: -60...0, step: 1)
                    .accessibilityLabel("Monitor gain in decibels")
                HStack {
                    Text("−60 dB")
                    Spacer()
                    Text("0 dB")
                }.font(.caption2).foregroundStyle(.tertiary)
            }

            Picker(
                "Profile",
                selection: Binding(
                    get: { model.settings.profile },
                    set: { value in
                        model.updateSettings { $0.selectProfile(value) }
                    })
            ) {
                ForEach(MonitorProfile.allCases) { profile in Text(profile.rawValue).tag(profile) }
            }.pickerStyle(.segmented)
                .help(
                    "Direct uses gain and output protection. Natural and Voice add filters and optional compression."
                )

            HStack(spacing: 6) {
                Image(systemName: "timer").accessibilityHidden(true)
                if model.phase == .monitoring {
                    Text(
                        String(
                            format: "Estimated latency %.1f ms", model.metrics.estimatedLatencyMs))
                } else {
                    Text("Latency appears when monitoring starts")
                }
            }.font(.caption).foregroundStyle(.secondary)
                .help(
                    "This value is an estimate from the audio devices and software queue. It is not a physical measurement."
                )

            if let message = model.message {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    if model.permissionDenied {
                        Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                    }
                }
            }

            if advanced {
                Divider()
                ScrollView {
                    AdvancedView(model: model).padding(.trailing, 5)
                }.frame(height: 265)
            }

            Divider()
            HStack {
                Button {
                    advanced.toggle()
                } label: {
                    Label("Advanced", systemImage: advanced ? "chevron.up" : "chevron.down")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }.font(.caption)
        }
        .padding(18)
        .frame(width: 364)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var levelText: String {
        guard model.phase == .monitoring, model.metrics.peakInput > 0.00001 else {
            return "−∞ dBFS"
        }
        return String(format: "%.0f dBFS", 20 * log10(model.metrics.peakInput))
    }

    private func devicePicker(
        title: String, symbol: String, devices: [AudioDevice],
        keyPath: WritableKeyPath<MonitorSettings, String?>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                .accessibilityHidden(true)
            Picker(title, selection: model.binding(keyPath)) {
                Text(defaultDeviceName(devices: devices, isInput: keyPath == \.inputUID)).tag(
                    nil as String?)
                ForEach(devices) { device in Text(device.name).tag(Optional(device.uid)) }
                if let saved = model.settings[keyPath: keyPath],
                    !devices.contains(where: { $0.uid == saved })
                {
                    Text("Saved device (unavailable)").tag(Optional(saved))
                }
            }.labelsHidden().accessibilityLabel(title + " device")
        }
    }

    private func defaultDeviceName(devices: [AudioDevice], isInput: Bool) -> String {
        if let device = devices.first(where: { isInput ? $0.isDefaultInput : $0.isDefaultOutput }) {
            return "System default — \(device.name)"
        }
        return "System default (unavailable)"
    }
}
