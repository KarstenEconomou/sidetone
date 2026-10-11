import SidetoneKit
import SwiftUI

extension MonitorModel {
    var enabledBinding: Binding<Bool> {
        Binding(get: { self.enabled }, set: { self.setEnabled($0) })
    }

    func binding<Value>(_ path: WritableKeyPath<MonitorSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: path] },
            set: { value in self.updateSettings { $0[keyPath: path] = value } }
        )
    }
}

@MainActor struct ProfilePicker: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        let picker = Picker(
            "Sound profile",
            selection: Binding(
                get: { model.settings.profile },
                set: { value in model.updateSettings { $0.selectProfile(value) } }
            )
        ) {
            ForEach(MonitorProfile.allCases) { profile in
                Text(profile.rawValue)
                    .frame(maxWidth: .infinity)
                    .help(profile.summary)
                    .accessibilityHint(profile.summary)
                    .tag(profile)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)

        if #available(macOS 26.0, *) {
            picker.buttonSizing(.flexible)
        } else {
            picker
        }
    }
}

extension MonitorProfile {
    var summary: String {
        switch self {
        case .direct: "Your voice without tone shaping."
        case .natural: "Light tone shaping for a natural voice."
        case .voice: "More tone shaping for a clear voice."
        }
    }
}
