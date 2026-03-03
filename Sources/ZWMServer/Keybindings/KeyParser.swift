import CoreGraphics

/// Parsed key combination: modifier flags + key code.
public struct KeyCombo: Hashable, Sendable {
    public let modifiers: CGEventFlags
    public let keyCode: UInt16

    public init(modifiers: CGEventFlags, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(modifiers.rawValue)
        hasher.combine(keyCode)
    }

    public static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.modifiers.rawValue == rhs.modifiers.rawValue && lhs.keyCode == rhs.keyCode
    }
}

/// Parse a key string like "alt-shift-h" into a KeyCombo.
public func parseKeyCombo(_ str: String) -> KeyCombo? {
    let parts = str.lowercased().split(separator: "-").map(String.init)
    guard !parts.isEmpty else { return nil }

    var modifiers: CGEventFlags = []
    var keyName: String?

    for part in parts {
        switch part {
        case "alt", "option", "opt":
            modifiers.insert(.maskAlternate)
        case "shift":
            modifiers.insert(.maskShift)
        case "ctrl", "control":
            modifiers.insert(.maskControl)
        case "cmd", "command":
            modifiers.insert(.maskCommand)
        default:
            keyName = part
        }
    }

    guard let key = keyName, let code = keyNameToCode[key] else { return nil }
    return KeyCombo(modifiers: modifiers, keyCode: code)
}

// Key name → macOS virtual key code mapping
private let keyNameToCode: [String: UInt16] = [
    // Letters
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03,
    "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
    "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
    "n": 0x2D, "m": 0x2E,
    // Numbers
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
    "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C,
    "9": 0x19, "0": 0x1D,
    // Special
    "enter": 0x24, "return": 0x24,
    "tab": 0x30,
    "space": 0x31,
    "escape": 0x35, "esc": 0x35,
    "backspace": 0x33, "delete": 0x33,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    // Punctuation
    "minus": 0x1B, "equal": 0x18, "equals": 0x18,
    "leftbracket": 0x21, "rightbracket": 0x1E,
    "semicolon": 0x29, "quote": 0x27,
    "comma": 0x2B, "period": 0x2F, "slash": 0x2C,
    "backslash": 0x2A, "grave": 0x32, "backtick": 0x32,
]
