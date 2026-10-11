import SidetoneKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, microphone, keyboard, diagnostics

    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .microphone: "Microphone"
        case .keyboard: "Keyboard"
        case .diagnostics: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .microphone: "mic"
        case .keyboard: "keyboard"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

@MainActor
struct SettingsView: View {
    let model: MonitorModel
    let keyboard: KeyboardModel
    let openAbout: () -> Void
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol).frame(width: 20)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Label {
                    Text("Sidetone")
                } icon: {
                    Image(nsImage: SidetoneGlyph.image(size: NSSize(width: 16, height: 16)))
                        .renderingMode(.original)
                }
                .labelStyle(MenuHeaderLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail.navigationTitle((pane ?? .general).title)
        }
        .frame(
            minWidth: SettingsLayout.minimumSize.width,
            idealWidth: SettingsLayout.defaultSize.width,
            minHeight: SettingsLayout.minimumSize.height,
            idealHeight: SettingsLayout.defaultSize.height)
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .general {
        case .general: GeneralSettingsView(model: model, openAbout: openAbout)
        case .microphone: MicrophoneSettingsView(model: model)
        case .keyboard: KeyboardSettingsView(model: keyboard)
        case .diagnostics: DiagnosticsSettingsView(model: model, keyboard: keyboard)
        }
    }
}
