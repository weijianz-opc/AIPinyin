import Testing
@testable import AllInOneIMECore

struct KeyMappingTests {
    func map(_ code: UInt16, _ chars: String, _ ignoring: String? = nil, _ mods: KeyModifiers = []) -> (Int32, Int32)? {
        RimeKey.map(KeyEvent(keyCode: code, characters: chars, charactersIgnoringModifiers: ignoring, modifiers: mods))
            .map { ($0.keycode, $0.mask) }
    }

    @Test func lettersDigitsAndPunctuation() {
        #expect(map(0x0D, "w")! == (0x77, 0))
        #expect(map(0x0D, "W", "W", .shift)! == (0x57, RimeKey.shiftMask))
        #expect(map(0x0D, "W", "w", .capsLock)! == (0x57, RimeKey.lockMask))
        #expect(map(0x12, "1")! == (0x31, 0))
        #expect(map(0x2B, ",")! == (0x2C, 0))
        #expect(map(0x1B, "_", "_", .shift)! == (0x5F, RimeKey.shiftMask))
    }

    @Test func specialKeys() {
        #expect(map(VirtualKey.returnKey, "\r")! == (RimeKey.returnKey, 0))
        #expect(map(VirtualKey.keypadEnter, "\u{3}")! == (RimeKey.returnKey, 0))
        #expect(map(VirtualKey.space, " ")! == (RimeKey.space, 0))
        #expect(map(VirtualKey.delete, "\u{7F}")! == (RimeKey.backSpace, 0))
        #expect(map(VirtualKey.forwardDelete, "\u{F728}")! == (RimeKey.delete, 0))
        #expect(map(VirtualKey.escape, "\u{1B}")! == (RimeKey.escape, 0))
        #expect(map(VirtualKey.tab, "\t")! == (RimeKey.tab, 0))
        #expect(map(VirtualKey.up, "\u{F700}")! == (RimeKey.up, 0))
        #expect(map(VirtualKey.pageDown, "\u{F72D}")! == (RimeKey.pageDown, 0))
        #expect(map(0x7A, "\u{F704}")! == (RimeKey.f1, 0))
        #expect(map(VirtualKey.returnKey, "\r", nil, .shift)! == (RimeKey.returnKey, RimeKey.shiftMask))
    }

    @Test func modifiersUseBaseCharacter() {
        // Option+a types "å"; librime gets 'a' with the Alt mask.
        #expect(map(0x00, "å", "a", .option)! == (0x61, RimeKey.altMask))
        #expect(map(0x00, "\u{1}", "a", .control)! == (0x61, RimeKey.controlMask))
    }

    @Test func nonASCIIKeysAreNotForThePinyinEngine() {
        #expect(map(0x00, "é", "é") == nil)
        #expect(map(0x00, "") == nil)
    }

    @Test func printableText() {
        #expect(KeyEvent(keyCode: 0, characters: "a").printableText == "a")
        #expect(KeyEvent(keyCode: 0, characters: "\u{1B}").printableText == nil)
        #expect(KeyEvent(keyCode: 0, characters: "\u{F700}").printableText == nil)
        #expect(KeyEvent(keyCode: 0, characters: "c", modifiers: .command).printableText == nil)
        #expect(KeyEvent(keyCode: 0, characters: "!", modifiers: .shift).printableText == "!")
    }

    @Test func hanDetection() {
        #expect("我ok".containsHan)
        #expect(!"，hello".containsHan)
    }
}
