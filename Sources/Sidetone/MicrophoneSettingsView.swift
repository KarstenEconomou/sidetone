import SidetoneKit
import SwiftUI

@MainActor
struct MicrophoneSettingsView: View {
    @ObservedObject var model: MonitorModel
    @State private var shapingExpanded = false
    @State private var hardwareExpanded = false

    var body: some View {
        SettingsForm {
            Section {
                SettingsToggle(
                    title: "Microphone monitoring", detail: model.status, isOn: model.enabledBinding
                )
                if let message = model.message {
                    SettingsNotice(message: message) {
                        if model.permissionDenied {
                            Button("Open Microphone Settings…") { model.openMicrophoneSettings() }
                        }
                    }
                }
                AudioDevicePicker(
                    title: "Input", devices: model.inputDevices,
                    selection: model.binding(\.inputUID), isInput: true, layout: .settings)
                SettingsSlider(
                    title: "Volume", value: model.binding(\.gainDB), range: -60...0, unit: "dB")
            } header: {
                Text("Monitoring")
            } footer: {
                Text(
                    "Hear your voice through the output selected in General. Use headphones to prevent feedback."
                )
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ProfilePicker(model: model)
                    Text(model.settings.profile.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Sound profile")
            }
            Section {
                DisclosureGroup("Voice shaping", isExpanded: $shapingExpanded) {
                    shapingControls.disabled(model.settings.profile == .direct)
                }
            } footer: {
                if model.settings.profile == .direct {
                    Text("Direct bypasses voice shaping. Select Natural or Voice to adjust it.")
                }
            }
            Section {
                DisclosureGroup("Audio hardware", isExpanded: $hardwareExpanded) {
                    Picker("Input channel", selection: model.binding(\.inputChannel)) {
                        ForEach(0..<max(1, inputChannels), id: \.self) { channel in
                            Text("Channel \(channel + 1)").tag(channel)
                        }
                        if model.settings.inputChannel >= max(1, inputChannels) {
                            Text("Channel \(model.settings.inputChannel + 1) (unavailable)")
                                .tag(model.settings.inputChannel)
                        }
                    }
                    .disabled(inputChannels <= 1 && model.settings.inputChannel == 0)
                    Picker("Buffer size", selection: model.binding(\.bufferFrames)) {
                        ForEach([32, 64, 128, 256, 512], id: \.self) { frames in
                            Text("\(frames) frames").tag(frames)
                        }
                        if ![32, 64, 128, 256, 512].contains(model.settings.bufferFrames) {
                            Text("\(model.settings.bufferFrames) frames").tag(
                                model.settings.bufferFrames)
                        }
                    }
                    Text(
                        "Smaller buffers can reduce latency. If audio breaks up, use a larger buffer. The device can use a different size."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var shapingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSlider(
                title: "High-pass filter", value: model.binding(\.highPassHz), range: 20...250,
                unit: "Hz"
            )
            .help("Reduces sound below this frequency.")
            SettingsSlider(
                title: "EQ frequency", value: model.binding(\.eqFrequencyHz), range: 100...10000,
                unit: "Hz", logarithmic: true)
            SettingsSlider(
                title: "EQ gain", value: model.binding(\.eqGainDB), range: -12...12, unit: "dB",
                precision: 1)
            SettingsSlider(
                title: "EQ width", value: model.binding(\.eqQ), range: 0.2...5, unit: "Q",
                precision: 1
            )
            .help(
                "Lower Q affects a wider range of frequencies. Higher Q affects a narrower range.")
            SettingsToggle(
                title: "Gentle compression",
                detail: "Reduce louder sounds without increasing quiet sounds.",
                isOn: model.binding(\.compression))
        }
        .padding(.top, 8)
    }

    private var inputChannels: Int {
        model.inputDevices.first { device in
            model.settings.inputUID.map { $0 == device.uid } ?? device.isDefaultInput
        }?.inputChannels ?? 0
    }
}
