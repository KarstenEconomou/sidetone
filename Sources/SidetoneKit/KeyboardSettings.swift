import Foundation

public enum KeyboardSwitch: String, Codable, CaseIterable, Identifiable, Sendable {
    case alpsSKCMBlue = "alps"
    case topre = "topre"
    case gateronInkBlack = "ink_black"
    case ibmBucklingSpring = "buckling_spring"
    case dropHolyPanda = "holy_panda"

    public var id: Self { self }
    public var name: String {
        switch self {
        case .alpsSKCMBlue: "Alps SKCM Blue"
        case .topre: "Topre"
        case .gateronInkBlack: "Gateron Ink Black"
        case .ibmBucklingSpring: "IBM Buckling Spring"
        case .dropHolyPanda: "Drop Holy Panda"
        }
    }
    public var summary: String {
        switch self {
        case .alpsSKCMBlue: "Alps SKCM Blue. A sharp click with a light return."
        case .topre: "Topre. A soft, low impact with a light return."
        case .gateronInkBlack: "Gateron Ink Black. A linear switch."
        case .ibmBucklingSpring: "IBM Buckling Spring. A clicky spring switch."
        case .dropHolyPanda: "Drop Holy Panda. A tactile switch."
        }
    }
    public var author: String { "Thomas Lai" }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .alpsSKCMBlue
    }
}

public struct KeyboardSettings: Codable, Equatable, Sendable {
    public var switchType = KeyboardSwitch.alpsSKCMBlue
    public var volumeDB = -18.0
    public var releaseSounds = true
    public var modifierSounds = true
    public var repeatSounds = false
    public var varySamples = true

    public init() {}

    public mutating func normalize() {
        volumeDB = volumeDB.isFinite ? min(0, max(-60, volumeDB)) : -18
    }
}

@MainActor
public final class KeyboardSettingsStore {
    private let defaults: UserDefaults
    private let key = "keyboardSettings"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: "keyboardEnabled") }
        set { defaults.set(newValue, forKey: "keyboardEnabled") }
    }

    public func load() -> KeyboardSettings {
        guard let data = defaults.data(forKey: key),
            var settings = try? JSONDecoder().decode(KeyboardSettings.self, from: data)
        else { return KeyboardSettings() }
        settings.normalize()
        return settings
    }

    public func save(_ settings: KeyboardSettings) {
        var settings = settings
        settings.normalize()
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}
