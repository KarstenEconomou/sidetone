import Foundation

public enum MonitorProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct = "Direct"
    case natural = "Natural"
    case voice = "Voice"

    public var id: String { rawValue }
    var engineValue: UInt32 {
        switch self {
        case .direct: 0
        case .natural: 1
        case .voice: 2
        }
    }
}

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var inputUID: String?
    public var outputUID: String?
    public var gainDB = -18.0
    public var profile = MonitorProfile.natural
    public var bufferFrames = 64
    public var inputChannel = 0
    public var highPassHz = 75.0
    public var eqFrequencyHz = 2200.0
    public var eqGainDB = 1.5
    public var eqQ = 0.7
    public var compression = false
    public var noiseSuppression = false
    public var noiseSuppressionStrength = 85.0
    public var globalShortcut = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case inputUID, outputUID, gainDB, profile, bufferFrames, inputChannel
        case highPassHz, eqFrequencyHz, eqGainDB, eqQ, compression, globalShortcut
        case noiseSuppression, noiseSuppressionStrength
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputUID = try values.decodeIfPresent(String.self, forKey: .inputUID)
        outputUID = try values.decodeIfPresent(String.self, forKey: .outputUID)
        gainDB = try values.decodeIfPresent(Double.self, forKey: .gainDB) ?? gainDB
        profile = try values.decodeIfPresent(MonitorProfile.self, forKey: .profile) ?? profile
        bufferFrames = try values.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? bufferFrames
        inputChannel = try values.decodeIfPresent(Int.self, forKey: .inputChannel) ?? inputChannel
        highPassHz = try values.decodeIfPresent(Double.self, forKey: .highPassHz) ?? highPassHz
        eqFrequencyHz =
            try values.decodeIfPresent(Double.self, forKey: .eqFrequencyHz) ?? eqFrequencyHz
        eqGainDB = try values.decodeIfPresent(Double.self, forKey: .eqGainDB) ?? eqGainDB
        eqQ = try values.decodeIfPresent(Double.self, forKey: .eqQ) ?? eqQ
        compression = try values.decodeIfPresent(Bool.self, forKey: .compression) ?? compression
        globalShortcut =
            try values.decodeIfPresent(Bool.self, forKey: .globalShortcut) ?? globalShortcut
        noiseSuppression = try values.decodeIfPresent(Bool.self, forKey: .noiseSuppression) ?? false
        noiseSuppressionStrength =
            try values.decodeIfPresent(Double.self, forKey: .noiseSuppressionStrength) ?? 85
    }

    public mutating func selectProfile(_ profile: MonitorProfile) {
        self.profile = profile
        switch profile {
        case .direct: break
        case .natural:
            highPassHz = 75
            eqFrequencyHz = 2200
            eqGainDB = 1.5
            eqQ = 0.7
        case .voice:
            highPassHz = 110
            eqFrequencyHz = 2800
            eqGainDB = 3
            eqQ = 0.8
        }
    }

    public mutating func normalize() {
        gainDB = Self.clamp(gainDB, -60...0, fallback: -18)
        highPassHz = Self.clamp(highPassHz, 20...250, fallback: 75)
        eqFrequencyHz = Self.clamp(eqFrequencyHz, 100...10000, fallback: 2200)
        eqGainDB = Self.clamp(eqGainDB, -12...12, fallback: 0)
        eqQ = Self.clamp(eqQ, 0.2...5, fallback: 0.7)
        noiseSuppressionStrength = Self.clamp(noiseSuppressionStrength, 0...100, fallback: 85)
        bufferFrames = min(2048, max(16, bufferFrames))
        inputChannel = min(255, max(0, inputChannel))
        if inputUID?.isEmpty == true { inputUID = nil }
        if outputUID?.isEmpty == true { outputUID = nil }
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double)
        -> Double
    {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    public func normalized() -> Self {
        var result = self
        result.normalize()
        return result
    }
}

@MainActor
public final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "monitorSettings"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: "monitoringEnabled") }
        set { defaults.set(newValue, forKey: "monitoringEnabled") }
    }

    public func load() -> MonitorSettings {
        guard let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data)
        else {
            return MonitorSettings()
        }
        return settings.normalized()
    }

    public func save(_ settings: MonitorSettings) {
        if let data = try? JSONEncoder().encode(settings.normalized()) {
            defaults.set(data, forKey: key)
        }
    }
}
