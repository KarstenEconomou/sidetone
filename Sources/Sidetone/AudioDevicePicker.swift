import SidetoneKit
import SwiftUI

struct AudioDevicePicker: View {
    let title: String
    let devices: [AudioDevice]
    @Binding var selection: String?
    let isInput: Bool
    var layout = SelectionMenuLayout.compact

    private var systemDefault: AudioDevice? {
        devices.first { isInput ? $0.isDefaultInput : $0.isDefaultOutput }
    }

    private var selected: AudioDevice? {
        if let selection { return devices.first { $0.uid == selection } }
        return systemDefault
    }

    private var selectedLabel: String {
        if selection != nil { return selected?.name ?? "Saved device (unavailable)" }
        return systemDefault.map { "Default — \($0.name)" } ?? "Default (unavailable)"
    }

    var body: some View {
        SelectionMenu(
            title: title, selectedLabel: selectedLabel, selection: $selection,
            selectedImage: AudioDeviceIcon.image(for: selected, isInput: isInput), layout: layout
        ) {
            Label {
                Text("System default")
            } icon: {
                AudioDeviceIcon.image(for: systemDefault, isInput: isInput)
            }
            .tag(nil as String?)
            Divider()
            ForEach(devices) { device in
                Label {
                    Text(device.name)
                } icon: {
                    AudioDeviceIcon.image(for: device, isInput: isInput)
                }
                .tag(Optional(device.uid))
            }
            if let selection, selected == nil {
                Divider()
                Text("Saved device (unavailable)").tag(Optional(selection))
            }
        }
        .help(selectedLabel)
    }
}
