import Foundation

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
}

/// A key-down as the input method receives it from AppKit.
public struct KeyEvent: Equatable, Sendable {
    public var keyCode: UInt16
    /// `NSEvent.characters`
    public var characters: String
    /// `NSEvent.charactersIgnoringModifiers` (still reflects Shift)
    public var charactersIgnoringModifiers: String
    public var modifiers: KeyModifiers

    public init(
        keyCode: UInt16, characters: String, charactersIgnoringModifiers: String? = nil,
        modifiers: KeyModifiers = []
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.modifiers = modifiers
    }

    /// The text this key types, if it is printable and not a shortcut.
    public var printableText: String? {
        guard modifiers.isDisjoint(with: [.control, .command]), !characters.isEmpty,
              characters.unicodeScalars.allSatisfy(Self.isPrintable)
        else { return nil }
        return characters
    }

    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }  // AppKit function-key range
        return true
    }
}

/// Carbon `kVK_*` virtual key codes, duplicated so Core does not depend on Carbon.
public enum VirtualKey {
    public static let returnKey: UInt16 = 0x24
    public static let keypadEnter: UInt16 = 0x4C
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let forwardDelete: UInt16 = 0x75
    public static let home: UInt16 = 0x73
    public static let end: UInt16 = 0x77
    public static let pageUp: UInt16 = 0x74
    public static let pageDown: UInt16 = 0x79
    public static let left: UInt16 = 0x7B
    public static let right: UInt16 = 0x7C
    public static let down: UInt16 = 0x7D
    public static let up: UInt16 = 0x7E
    public static let leftShift: UInt16 = 0x38
    public static let rightShift: UInt16 = 0x3C
    /// F1–F12 in order.
    public static let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
}

/// X11 keysyms and modifier masks: the key encoding librime expects.
public enum RimeKey {
    public static let shiftMask: Int32 = 1 << 0
    public static let lockMask: Int32 = 1 << 1
    public static let controlMask: Int32 = 1 << 2
    public static let altMask: Int32 = 1 << 3
    public static let superMask: Int32 = 1 << 26
    /// librime's flag for key-up events.
    public static let releaseMask: Int32 = 1 << 30

    public static let shiftL: Int32 = 0xFFE1
    public static let space: Int32 = 0x0020
    public static let backSpace: Int32 = 0xFF08
    public static let tab: Int32 = 0xFF09
    public static let returnKey: Int32 = 0xFF0D
    public static let escape: Int32 = 0xFF1B
    public static let home: Int32 = 0xFF50
    public static let left: Int32 = 0xFF51
    public static let up: Int32 = 0xFF52
    public static let right: Int32 = 0xFF53
    public static let down: Int32 = 0xFF54
    public static let pageUp: Int32 = 0xFF55
    public static let pageDown: Int32 = 0xFF56
    public static let end: Int32 = 0xFF57
    public static let delete: Int32 = 0xFFFF
    public static let f1: Int32 = 0xFFBE

    static let specialKeys: [UInt16: Int32] = {
        var keys: [UInt16: Int32] = [
            VirtualKey.returnKey: returnKey, VirtualKey.keypadEnter: returnKey,
            VirtualKey.tab: tab, VirtualKey.space: space,
            VirtualKey.delete: backSpace, VirtualKey.forwardDelete: delete, VirtualKey.escape: escape,
            VirtualKey.home: home, VirtualKey.end: end, VirtualKey.pageUp: pageUp, VirtualKey.pageDown: pageDown,
            VirtualKey.left: left, VirtualKey.right: right, VirtualKey.up: up, VirtualKey.down: down,
        ]
        for (i, code) in VirtualKey.functionKeys.enumerated() { keys[code] = f1 + Int32(i) }
        return keys
    }()

    public static func mask(for modifiers: KeyModifiers) -> Int32 {
        var mask: Int32 = 0
        if modifiers.contains(.shift) { mask |= shiftMask }
        if modifiers.contains(.capsLock) { mask |= lockMask }
        if modifiers.contains(.control) { mask |= controlMask }
        if modifiers.contains(.option) { mask |= altMask }
        if modifiers.contains(.command) { mask |= superMask }
        return mask
    }

    /// Maps a key-down to (keysym, mask), or nil when librime has no use for the key
    /// (non-ASCII characters, dead keys, unknown function keys). Follows Squirrel's mapping.
    public static func map(_ event: KeyEvent) -> (keycode: Int32, mask: Int32)? {
        let mask = mask(for: event.modifiers)
        if let special = specialKeys[event.keyCode] { return (special, mask) }

        var chars = event.charactersIgnoringModifiers
        let capitalOnly = event.modifiers.isSubset(of: [.shift, .capsLock])
        if let first = chars.unicodeScalars.first {
            if capitalOnly && !first.properties.isAlphabetic {
                chars = event.characters
            } else if !capitalOnly && !first.isASCII {
                chars = event.characters
            }
        }
        guard chars.unicodeScalars.count == 1, let scalar = chars.unicodeScalars.first,
              (0x20...0x7E).contains(scalar.value)
        else { return nil }
        var value = scalar.value
        if !event.modifiers.isDisjoint(with: [.shift, .capsLock]), (0x61...0x7A).contains(value) {
            value -= 0x20  // lowercase → uppercase keysym
        }
        return (Int32(value), mask)
    }
}
