import SidetoneKit
import SwiftUI

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject var model: MonitorModel
    let openAbout: () -> Void

    var body: some View {
        SettingsForm {
            Section {
                AudioDevicePicker(
                    title: "Output", devices: model.outputDevices,
                    selection: model.binding(\.outputUID), isInput: false, layout: .settings)
            } header: {
                Text("Audio output")
            } footer: {
                Text(
                    "Both audio features use this output. Selecting an output turns microphone monitoring off."
                )
            }
            Section {
                Toggle(
                    "Launch at login",
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
                )
                if model.loginNeedsApproval {
                    SettingsNotice(message: "Allow Sidetone to open at login in System Settings.") {
                        Button("Open Login Items…") { model.openLoginSettings() }
                    }
                }
                if let message = model.loginError {
                    Text(message).foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Sidetone restores the last on/off state of each audio feature when it opens.")
            }
            Section("Keyboard shortcut") {
                SettingsToggle(
                    title: "Toggle microphone monitoring", detail: "Press ⇧⌘M from any app.",
                    isOn: model.binding(\.globalShortcut))
            }
            Section {
                LabeledContent("Version", value: version)
                Button("About Sidetone…", action: openAbout)
            } header: {
                Text("Sidetone")
            } footer: {
                Text("Audio stays on this Mac. Sidetone does not record audio or store typed text.")
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
