import SwiftUI

struct MenuHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 20, height: 16)
                .accessibilityHidden(true)
            configuration.title
        }
        .font(.body.weight(.semibold))
    }
}

enum SelectionMenuLayout {
    case compact, settings
}

struct SelectionMenu<Selection: Hashable, Options: View>: View {
    let title: String
    let selectedLabel: String
    @Binding var selection: Selection
    var selectedImage: Image? = nil
    var layout = SelectionMenuLayout.compact
    @ViewBuilder let options: () -> Options

    var body: some View {
        switch layout {
        case .compact:
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                control
            }
        case .settings:
            LabeledContent(title) {
                control.frame(width: SettingsLayout.controlWidth)
            }
        }
    }

    @ViewBuilder private var control: some View {
        if #available(macOS 26.0, *) {
            menu.buttonSizing(.flexible)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Picker(title, selection: $selection, content: options)
                .pickerStyle(.inline)
        } label: {
            Color.clear.frame(height: 16)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            HStack(spacing: 8) {
                if let selectedImage {
                    selectedImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                Text(selectedLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 28)
            .foregroundStyle(.primary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
    }
}

struct AudioFeatureSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                    .labelStyle(MenuHeaderLabelStyle())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            content()
        }
        .padding(12)
    }
}

struct AudioFeatureNotice<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuVolumeSlider: View {
    let title: String
    @Binding var value: Double

    init(_ title: String, value: Binding<Double>) {
        self.title = title
        self._value = value
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Volume")
                Spacer()
                Text(formattedValue)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: -60...0)
                .controlSize(.small)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
                .accessibilityValue(formattedValue)
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedValue: String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) dB"
    }
}
