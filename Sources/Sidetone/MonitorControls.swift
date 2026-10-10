import SidetoneKit
import SwiftUI

extension MonitorModel {
    func binding<Value>(_ path: WritableKeyPath<MonitorSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: path] },
            set: { value in self.updateSettings { $0[keyPath: path] = value } }
        )
    }
}

struct MetricRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Text(title).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct LevelMeter: View {
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

@MainActor struct MonitorHeader: View {
    @ObservedObject var model: MonitorModel
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: SidetoneGlyph.image(size: NSSize(width: 24, height: 24)))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable Sidetone",
                isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("Enable Sidetone")
        }
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

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var precision = 0
    var logarithmic = false

    init(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String,
        precision: Int = 0, logarithmic: Bool = false
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
        self.precision = precision
        self.logarithmic = logarithmic
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(precision)))) \(unit)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: sliderValue, in: sliderRange)
                .controlSize(.small)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
                .accessibilityValue(
                    "\(value.formatted(.number.precision(.fractionLength(precision)))) \(unit)")
        }
        .frame(maxWidth: .infinity)
    }

    private var sliderRange: ClosedRange<Double> {
        logarithmic ? log10(range.lowerBound)...log10(range.upperBound) : range
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { logarithmic ? log10(value) : value },
            set: { value = logarithmic ? pow(10, $0) : $0 }
        )
    }
}
