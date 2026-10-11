import Foundation

struct KeyboardStroke: Equatable, Sendable {
    let keyCode: UInt16
    let isDown: Bool
    var isRepeat = false
    var isModifier = false
}

struct KeyboardInputState {
    private var low: UInt64 = 0
    private var high: UInt64 = 0

    mutating func reset() {
        low = 0
        high = 0
    }

    mutating func accepts(_ stroke: KeyboardStroke, settings: KeyboardSettings) -> Bool {
        guard stroke.keyCode < 128 else { return false }
        if stroke.isModifier && !settings.modifierSounds { return false }
        let mask = UInt64(1) << (stroke.keyCode % 64)
        let hadPress = (stroke.keyCode < 64 ? low : high) & mask != 0
        if stroke.isDown {
            if stroke.isRepeat { return settings.repeatSounds && hadPress }
            if stroke.keyCode < 64 { low |= mask } else { high |= mask }
            return !hadPress
        }
        if stroke.keyCode < 64 { low &= ~mask } else { high &= ~mask }
        return hadPress && settings.releaseSounds
    }
}

final class KeyboardEventDelivery: @unchecked Sendable {
    // This lock protects event order and configuration. It never protects device or file access.
    private let lock = NSLock()
    private var input = KeyboardInputState()
    private var settings = KeyboardSettings()
    private var revision: UInt64 = 0
    private var enabled = false
    private let play: @Sendable (KeyboardStroke, KeyboardSettings, UInt64) -> Void

    init(play: @escaping @Sendable (KeyboardStroke, KeyboardSettings, UInt64) -> Void) {
        self.play = play
    }

    func configure(enabled: Bool, settings: KeyboardSettings, revision: UInt64) {
        lock.withLock {
            if self.enabled != enabled || self.revision != revision
                || self.settings.modifierSounds != settings.modifierSounds
                || self.settings.switchType != settings.switchType
            {
                input.reset()
            }
            self.enabled = enabled
            self.settings = settings
            self.revision = revision
        }
    }

    func reset() { lock.withLock { input.reset() } }

    func receive(_ stroke: KeyboardStroke) {
        lock.withLock {
            guard enabled, input.accepts(stroke, settings: settings) else { return }
            play(stroke, settings, revision)
        }
    }
}

enum KeyboardKey {
    // These names identify physical key positions. No text is read from events.
    static let names: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c",
        9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[",
        34: "i", 35: "p", 36: "enter", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 48: "tab", 49: "space",
        50: "`", 51: "backspace", 53: "esc", 54: "command", 55: "command",
        56: "shiftLeft", 57: "capsLock", 58: "optionLeft", 59: "ctrlLeft",
        60: "shiftRight", 61: "optionRight", 62: "ctrlRight", 63: "fn",
        67: "*", 69: "+", 71: "clear", 75: "/", 76: "enter", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
        91: "8", 92: "9", 96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8",
        101: "f9", 103: "f11", 109: "f10", 111: "f12", 115: "home", 116: "pgUp",
        117: "del", 118: "f4", 119: "end", 120: "f2", 121: "pgDn", 122: "f1",
        123: "arrLeft", 124: "arrRight", 125: "arrDown", 126: "arrUp",
    ]
}
