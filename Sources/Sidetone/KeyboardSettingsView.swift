import SidetoneKit
import SwiftUI

@MainActor
struct KeyboardSettingsView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        SettingsForm {
            Section {
                SettingsToggle(
                    title: "Keyboard sounds", detail: model.status, isOn: model.enabledBinding)
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                KeyboardSwitchPicker(model: model, layout: .settings)
                SettingsSlider(
                    title: "Volume", value: model.binding(\.volumeDB), range: -60...0, unit: "dB")
            } header: {
                Text("Sound")
            } footer: {
                Text(
                    "Recorded key sounds play through the output selected in General. Microphone monitoring can stay off."
                )
            }
            Section("Key behavior") {
                SettingsToggle(
                    title: "Release sounds", detail: "Play a recording when you release a key.",
                    isOn: model.binding(\.releaseSounds))
                SettingsToggle(
                    title: "Modifier keys",
                    detail: "Include Shift, Control, Option, Command, Caps Lock, and Fn.",
                    isOn: model.binding(\.modifierSounds))
                SettingsToggle(
                    title: "Key repeat", detail: "Play repeat events while a key is held.",
                    isOn: model.binding(\.repeatSounds))
                SettingsToggle(
                    title: "Vary recordings", detail: "Use alternate recordings where available.",
                    isOn: model.binding(\.varySamples))
            }
            Section {
                LabeledContent(
                    "Input Monitoring", value: model.hasInputAccess ? "Allowed" : "Not allowed")
                Button("Open Input Monitoring Settings…") { model.openInputSettings() }
            } header: {
                Text("Permission")
            } footer: {
                Text(
                    "Allow Input Monitoring to play sounds while you type in other apps. Typed text is not stored. Sounds pause during secure input."
                )
            }
            Section {
                DisclosureGroup("Recording credits") {
                    LabeledContent("Recordings", value: model.settings.switchType.author)
                    Link(
                        "Thock sound packs",
                        destination: URL(
                            string: "https://github.com/kamillobinski/thock-soundpacks")!)
                    Button("Show sound pack license…") { model.openSoundLicense() }
                    Text("All recordings are included in Sidetone and work offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
