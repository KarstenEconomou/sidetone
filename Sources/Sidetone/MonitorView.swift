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
                Toggle("Enable Sidetone", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Enable Sidetone")
            }

            Divider()

            VStack(spacing: 10) {
                devicePicker(title: "Input", symbol: "mic", devices: model.inputDevices, keyPath: \.inputUID)
                devicePicker(title: "Output", symbol: "headphones", devices: model.outputDevices, keyPath: \.outputUID)
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
                Slider(value: setting(\.gainDB), in: -60...0, step: 1)
                    .accessibilityLabel("Monitor gain in decibels")
                HStack {
                    Text("−60 dB")
                    Spacer()
                    Text("0 dB")
                }.font(.caption2).foregroundStyle(.tertiary)
            }

            Picker("Profile", selection: Binding(get: { model.settings.profile }, set: { value in
                model.updateSettings { $0.selectProfile(value) }
            })) {
                ForEach(MonitorProfile.allCases) { profile in Text(profile.rawValue).tag(profile) }
            }.pickerStyle(.segmented)
                .help("Direct uses gain and output protection. Natural and Voice add filters and optional compression.")

            HStack(spacing: 6) {
                Image(systemName: "timer").accessibilityHidden(true)
                if model.phase == .monitoring {
                    Text(String(format: "Estimated latency %.1f ms", model.metrics.estimatedLatencyMs))
                } else { Text("Latency appears when monitoring starts") }
            }.font(.caption).foregroundStyle(.secondary)
                .help("This value is an estimate from the audio devices and software queue. It is not a physical measurement.")

            if let message = model.message {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Button { advanced.toggle() } label: {
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
        guard model.phase == .monitoring, model.metrics.peakInput > 0.00001 else { return "−∞ dBFS" }
        return String(format: "%.0f dBFS", 20 * log10(model.metrics.peakInput))
    }

    private func setting<T>(_ path: WritableKeyPath<MonitorSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in
            model.updateSettings { $0[keyPath: path] = value }
        })
    }

    private func devicePicker(title: String, symbol: String, devices: [AudioDevice],
                              keyPath: WritableKeyPath<MonitorSettings, String?>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            Picker(title, selection: setting(keyPath)) {
                Text(defaultDeviceName(devices: devices, isInput: keyPath == \.inputUID)).tag(nil as String?)
                ForEach(devices) { device in Text(device.name).tag(Optional(device.uid)) }
                if let saved = model.settings[keyPath: keyPath], !devices.contains(where: { $0.uid == saved }) {
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

@MainActor private struct AdvancedView: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device configuration").font(.headline)
            Picker("Requested buffer", selection: setting(\.bufferFrames)) {
                ForEach([32, 64, 128, 256, 512], id: \.self) { frames in Text("\(frames) frames").tag(frames) }
            }
            Text("The device can select a larger buffer.").font(.caption).foregroundStyle(.secondary)
            Picker("Microphone channel", selection: setting(\.inputChannel)) {
                ForEach(0..<max(1, selectedInputChannels), id: \.self) { channel in
                    Text("Channel \(channel + 1)").tag(channel)
                }
                if model.settings.inputChannel >= max(1, selectedInputChannels) {
                    Text("Channel \(model.settings.inputChannel + 1) (unavailable)").tag(model.settings.inputChannel)
                }
            }
            if model.phase == .monitoring {
                metric("Input", "\(Int(model.metrics.inputRate)) Hz · \(model.metrics.inputFrames) frames")
                metric("Output", "\(Int(model.metrics.outputRate)) Hz · \(model.metrics.outputFrames) frames")
            }
            Divider()
            Text("Voice processing").font(.headline)
            if model.settings.profile == .direct {
                Text("Direct uses gain and output protection.").font(.caption).foregroundStyle(.secondary)
            } else {
                slider("High-pass filter", path: \.highPassHz, range: 20...250, suffix: "Hz")
                slider("EQ frequency", path: \.eqFrequencyHz, range: 100...10000, suffix: "Hz")
                slider("EQ gain", path: \.eqGainDB, range: -12...12, suffix: "dB")
                HStack {
                    Text("EQ width (Q)")
                    Spacer()
                    Text(String(format: "%.1f", model.settings.eqQ)).foregroundStyle(.secondary).monospacedDigit()
                }.font(.caption)
                Slider(value: setting(\.eqQ), in: 0.2...5, step: 0.1).accessibilityLabel("EQ width")
                Toggle("Gentle compression", isOn: setting(\.compression))
            }
            Divider()
            Text("System").font(.headline)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if model.loginNeedsApproval { Button("Allow in Login Items") { model.openLoginSettings() } }
            Toggle("Global shortcut: ⇧⌘M", isOn: setting(\.globalShortcut))
            Text("Monitoring is off when the app opens.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Diagnostics").font(.headline)
            metric("Maximum callback", String(format: "%.3f ms", model.metrics.maxCallbackMs))
            metric("Maximum DSP", String(format: "%.3f ms", model.metrics.maxDSPMs))
            metric("Device input latency", String(format: "%.2f ms", model.metrics.inputDeviceLatencyMs))
            metric("Device output latency", String(format: "%.2f ms", model.metrics.outputDeviceLatencyMs))
            metric("Input buffer duration", String(format: "%.2f ms", model.metrics.inputRate > 0 ? Double(model.metrics.inputFrames) / model.metrics.inputRate * 1000 : 0))
            metric("Output buffer duration", String(format: "%.2f ms", model.metrics.outputRate > 0 ? Double(model.metrics.outputFrames) / model.metrics.outputRate * 1000 : 0))
            metric("Queue latency", String(format: "%.2f ms", model.metrics.queueLatencyMs))
            metric("Resampler latency", String(format: "%.2f ms", model.metrics.resamplerLatencyMs))
            metric("Clock correction", String(format: "%.0f ppm", model.metrics.driftPPM))
            metric("Underruns / overruns", "\(model.metrics.underruns) / \(model.metrics.overruns)")
            metric("Callback overruns", "\(model.metrics.deadlineMisses)")
            metric("Hardware overloads", "\(model.metrics.hardwareOverloads)")
            metric("Protected samples", "\(model.metrics.clippedSamples)")
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

    private func setting<T>(_ path: WritableKeyPath<MonitorSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in
            model.updateSettings { $0[keyPath: path] = value }
        })
    }
    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.caption)
    }
    private func slider(_ title: String, path: WritableKeyPath<MonitorSettings, Double>,
                        range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 3) {
            metric(title, suffix == "dB"
                   ? String(format: "%.1f dB", model.settings[keyPath: path])
                   : "\(Int(model.settings[keyPath: path])) \(suffix)")
            Slider(value: setting(path), in: range, step: suffix == "dB" ? 0.5 : 1)
                .accessibilityLabel(title)
        }
    }
}
