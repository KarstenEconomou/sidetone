import SwiftUI

enum SettingsLayout {
    static let controlWidth: CGFloat = 260
    static let minimumSize = NSSize(width: 760, height: 560)
    static let defaultSize = NSSize(width: 800, height: 680)
}

struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form(content: content)
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLabel(title, detail: detail)
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var precision = 0
    var logarithmic = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: sliderValue, in: sliderRange)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(formattedValue)
                TextField(
                    "", value: boundedValue,
                    format: .number.precision(.fractionLength(precision))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 62)
                .accessibilityLabel("\(title), \(unit)")
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .frame(width: SettingsLayout.controlWidth)
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var formattedValue: String {
        "\(value.formatted(.number.precision(.fractionLength(precision)))) \(unit)"
    }

    private var boundedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } })
    }

    private var sliderRange: ClosedRange<Double> {
        logarithmic ? log10(range.lowerBound)...log10(range.upperBound) : range
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { logarithmic ? log10(value) : value },
            set: { boundedValue.wrappedValue = logarithmic ? pow(10, $0) : $0 })
    }
}

struct SettingsNotice<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
