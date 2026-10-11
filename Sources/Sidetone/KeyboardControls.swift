import SidetoneKit
import SwiftUI

extension KeyboardModel {
    func binding<Value>(_ path: WritableKeyPath<KeyboardSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: path] },
            set: { value in self.updateSettings { $0[keyPath: path] = value } })
    }

    var enabledBinding: Binding<Bool> {
        Binding(get: { self.enabled }, set: { self.setEnabled($0) })
    }
}

@MainActor
struct KeyboardControls: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        AudioFeatureSection(
            title: "Keyboard sounds", systemImage: "keyboard", isOn: model.enabledBinding
        ) {
            KeyboardSwitchPicker(model: model)
            MenuVolumeSlider("Keyboard volume", value: model.binding(\.volumeDB))
            if let message = keyboardNotice {
                AudioFeatureNotice(message: message) {
                    if model.phase == .permission {
                        Button("Open Input Monitoring Settings") { model.openInputSettings() }
                    }
                }
            }
        }
    }

    private var keyboardNotice: String? {
        if let message = model.message { return message }
        return model.phase == .off || model.phase == .listening ? nil : model.status
    }
}

@MainActor
struct KeyboardSwitchPicker: View {
    @ObservedObject var model: KeyboardModel
    var layout = SelectionMenuLayout.compact

    var body: some View {
        SelectionMenu(
            title: "Switch", selectedLabel: model.settings.switchType.name,
            selection: model.binding(\.switchType),
            selectedImage: KeyboardSwitchGlyph.image(for: model.settings.switchType), layout: layout
        ) {
            ForEach(KeyboardSwitch.allCases) { type in
                Label {
                    Text(type.name)
                } icon: {
                    KeyboardSwitchGlyph.image(for: type)
                }
                .tag(type)
            }
        }
        .accessibilityHint(model.settings.switchType.summary)
    }
}
