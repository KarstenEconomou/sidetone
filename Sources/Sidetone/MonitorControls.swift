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
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.caption)
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
