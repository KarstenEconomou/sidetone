import AppKit
import SidetoneKit
import SwiftUI

@MainActor struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    let keyboard: KeyboardModel
    @ObservedObject var updater: UpdateController
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Sidetone")
                } icon: {
                    Image(nsImage: SidetoneGlyph.image(size: NSSize(width: 16, height: 16)))
                        .renderingMode(.original)
                }
                .labelStyle(MenuHeaderLabelStyle())
                AudioDevicePicker(
                    title: "Output", devices: model.outputDevices,
                    selection: model.binding(\.outputUID), isInput: false)
            }
            .padding(12)
            divider
            AudioFeatureSection(
                title: "Microphone monitoring", systemImage: "mic", isOn: model.enabledBinding
            ) {
                AudioDevicePicker(
                    title: "Input", devices: model.inputDevices,
                    selection: model.binding(\.inputUID), isInput: true)
                MenuVolumeSlider("Microphone volume", value: model.binding(\.gainDB))
                Toggle("Noise suppression", isOn: model.binding(\.noiseSuppression))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .help("Reduce background noise. Adjust strength in Settings.")
                if let message = microphoneNotice {
                    AudioFeatureNotice(message: message) {
                        if model.permissionDenied {
                            Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                        }
                    }
                }
            }
            divider
            KeyboardControls(model: keyboard)
            divider
            if let version = updater.availableVersion {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Update to \(version)…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .disabled(!updater.canCheckForUpdates)
                .padding(12)
                divider
            }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var divider: some View {
        Divider()
            .padding(.horizontal, 12)
    }

    private var microphoneNotice: String? {
        if let message = model.message { return message }
        if model.phase != .off && model.phase != .monitoring { return model.status }
        if model.enabled,
            model.route?.output.name.localizedCaseInsensitiveContains("speaker") == true
        {
            return "Use headphones to prevent feedback."
        }
        return nil
    }

}
