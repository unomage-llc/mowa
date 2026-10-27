import AppKit

/// The dictation key the user records (Settings → Key → Custom shortcut): any 1–5 keys held
/// together — modifier keys (left/right ⌘ ⌥ ⌃ ⇧, fn), letters, F keys, anything (Drew 2026-10-21:
/// no restrictions, the user decides). Dictation runs while all of them are held.
struct Shortcut: Codable, Equatable {
    /// Virtual key codes, in the order they were pressed.
    var keys: [UInt16]
    /// Shown in Settings, the menu and the launch notice ("⌃ + Space", "Right ⌥ Option").
    var name: String

    static let maxKeys = 5

    init(keys: [UInt16], name: String) {
        self.keys = keys
        self.name = name
    }

    /// One modifier key on its own (also used to carry over the old Right ⌥/⌘/⌃ choices).
    init?(modifierKey keyCode: UInt16) {
        guard let name = Self.modifierName(keyCode) else { return nil }
        self.init(keys: [keyCode], name: name)
    }

    // MARK: Modifier keys

    /// Device-dependent bits in CGEventFlags / NSEvent.ModifierFlags raw values: they tell the left
    /// key from the right one. Caps Lock is left out (it toggles instead of being held).
    static let modifierMasks: [UInt16: UInt64] = [
        55: 0x08, 54: 0x10,          // left / right ⌘
        58: 0x20, 61: 0x40,          // left / right ⌥
        59: 0x01, 62: 0x2000,        // left / right ⌃
        56: 0x02, 60: 0x04,          // left / right ⇧
        63: 0x800000,                // fn
    ]

    static func isModifier(_ keyCode: UInt16) -> Bool { modifierMasks[keyCode] != nil }

    /// The device-independent flag a modifier key sets (to spot extra modifiers being held).
    static func flag(of keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 55, 54: return .maskCommand
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 56, 60: return .maskShift
        default: return nil
        }
    }

    static func modifierName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 54: return L("Right ⌘ Command")
        case 55: return L("Left ⌘ Command")
        case 61: return L("Right ⌥ Option")
        case 58: return L("Left ⌥ Option")
        case 62: return L("Right ⌃ Control")
        case 59: return L("Left ⌃ Control")
        case 60: return L("Right ⇧ Shift")
        case 56: return L("Left ⇧ Shift")
        case 63: return "fn"
        default: return nil
        }
    }

    /// Short form inside a combination: ⌘ for the left key, "Right ⌘" for the right one.
    private static func modifierSymbol(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "⌘"
        case 58: return "⌥"
        case 59: return "⌃"
        case 56: return "⇧"
        case 63: return "fn"
        case 54: return LF("Right %@", "⌘")
        case 61: return LF("Right %@", "⌥")
        case 62: return LF("Right %@", "⌃")
        case 60: return LF("Right %@", "⇧")
        default: return nil
        }
    }

    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let keyNames: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// Name of a non-modifier key as pressed (layout-aware for letters).
    static func keyName(_ event: NSEvent) -> String {
        if let f = functionKeys[event.keyCode] { return f }
        if event.keyCode == 49 { return L("Space") }
        if let special = keyNames[event.keyCode] { return special }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chars.isEmpty ? "#\(event.keyCode)" : chars.uppercased()
    }

    /// "⌃ + ⌥ + Space": modifiers first (⌃ ⌥ ⇧ ⌘ fn), then the other keys in the order pressed.
    static func name(keys: [UInt16], keyNames: [UInt16: String]) -> String {
        if keys.count == 1, let only = modifierName(keys[0]) { return only }
        let order: [UInt16] = [59, 62, 58, 61, 56, 60, 55, 54, 63]
        let mods = order.filter(keys.contains).compactMap(modifierSymbol)
        let others = keys.filter { !isModifier($0) }.map { keyNames[$0] ?? "#\($0)" }
        return (mods + others).joined(separator: " + ")
    }

    // MARK: Saved

    private enum CodingKeys: String, CodingKey { case keys, name, keyCode, modifiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let keys = try c.decodeIfPresent([UInt16].self, forKey: .keys) {
            self.keys = keys
        } else {
            // First version (one key + modifier flags): modifiers become the left-hand keys.
            let keyCode = try c.decode(UInt16.self, forKey: .keyCode)
            let flags = NSEvent.ModifierFlags(rawValue: try c.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0)
            var keys: [UInt16] = []
            if flags.contains(.control) { keys.append(59) }
            if flags.contains(.option) { keys.append(58) }
            if flags.contains(.shift) { keys.append(56) }
            if flags.contains(.command) { keys.append(55) }
            keys.append(keyCode)
            self.keys = keys
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keys, forKey: .keys)
        try c.encode(name, forKey: .name)
    }

    private static let defaultsKey = "customShortcut"

    static func load() -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func save(_ shortcut: Shortcut?) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
