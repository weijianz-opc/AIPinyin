// End-to-end check through the real macOS text input system.
//
// A separate app with a real NSTextView types through the *installed* AllInOneIME input method
// (launched by macOS from ~/Library/Input Methods, real Rime engine, live Bedrock call).
// Keys are CGEvent-backed events dispatched to this app's own window, so they take the same
// NSTextInputContext → IMK path as real typing, need no Accessibility permission, and never reach
// other apps. The input source is switched to AllInOneIME for the test and restored afterwards.
//
// Run with: make realtest
import AppKit
import Carbon

let imeID = "com.aipinyin.inputmethod.AIPinyin"

func currentInputSourceID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

@discardableResult
func selectInputSource(_ id: String) -> Bool {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = list.first
    else { return false }
    return TISSelectInputSource(source) == noErr
}

func screenIsLocked() -> Bool {
    let value = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"]
    return (value as? Bool) == true || (value as? Int) == 1
}

/// Where results go (first non-option argument), default /tmp/allinoneime-realtest.
let outputDirectory = URL(fileURLWithPath:
    CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "/tmp/allinoneime-realtest")
let originalSourceFile = outputDirectory.appendingPathComponent("original-source.txt")

func imeIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: imeID).isEmpty
}

/// On-screen windows of the input method process (the candidate panel), in Cocoa screen coordinates.
func imePanelFrames() -> [NSRect] {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: imeID).map(\.processIdentifier))
    guard !pids.isEmpty,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    return windows.compactMap { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
              let bounds = window[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { return nil }
        // CGWindow bounds are top-left based; flip to Cocoa's bottom-left origin.
        return NSRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

let keyCodes: [Character: UInt16] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
    "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
    "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, ",": 0x2B, ".": 0x2F,
]
let spaceCode: UInt16 = 0x31, returnCode: UInt16 = 0x24, escapeCode: UInt16 = 0x35, tabCode: UInt16 = 0x30
let deleteCode: UInt16 = 0x33, leftShiftCode: UInt16 = 0x38, leftOptionCode: UInt16 = 0x3A

final class Harness: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var failures = 0
    var originalSource: String?
    /// Window is key (normal desktop): dispatch through NSApp like real typing. Otherwise (e.g. the
    /// screen is locked) hand events to the text view, which forwards them to its input context.
    var dispatchThroughApp = true

    func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "✓" : "✗") \(message)")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    func note(_ message: String) {
        print("  \(message)")
        fflush(stdout)
    }

    // MARK: - Text view state

    var marked: String {
        guard textView.hasMarkedText() else { return "" }
        return (textView.string as NSString).substring(with: textView.markedRange())
    }

    /// Document text without the marked (still composing) part.
    var committed: String {
        let text = textView.string as NSString
        guard textView.hasMarkedText() else { return text as String }
        return text.replacingCharacters(in: textView.markedRange(), with: "")
    }

    // MARK: - Events

    func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        } while Date() < until
    }

    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            pump(0.05)
        }
        return true
    }

    func dispatch(_ event: NSEvent) {
        if dispatchThroughApp {
            NSApp.sendEvent(event)
        } else {
            switch event.type {
            case .keyDown: textView.keyDown(with: event)
            case .keyUp: textView.keyUp(with: event)
            case .flagsChanged: textView.flagsChanged(with: event)
            default: break
            }
        }
    }

    /// Key events are built from CGEvents, like the system's own: NSEvent.keyEvent(…) events are
    /// handed straight to the text view and never reach the input method (verified on macOS 27).
    let eventSource = CGEventSource(stateID: .hidSystemState)

    func cgFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.command) { out.insert(.maskCommand) }
        return out
    }

    func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
            // Keep the event's own flags (e.g. non-coalesced); only the modifier bits are replaced.
            var eventFlags = cg.flags
            eventFlags.subtract([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift])
            cg.flags = eventFlags.union(cgFlags(flags))
            if let event = NSEvent(cgEvent: cg) { dispatch(event) }
        }
        pump(0.04)
    }

    func type(_ text: String) {
        for ch in text { key(String(ch), keyCodes[ch] ?? 0) }
    }

    func space(_ flags: NSEvent.ModifierFlags = []) { key(" ", spaceCode, flags) }
    func enter() { key("\r", returnCode) }
    func escape() { key("\u{1B}", escapeCode) }
    func backspace() { key("\u{7F}", deleteCode) }

    static func hasLatinLetter(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
    }

    /// The marked text after the command ("@improve 我今天" → "我今天").
    var afterCommand: String {
        let text = marked
        guard text.hasPrefix("@"), let space = text.firstIndex(of: " ") else { return text }
        return String(text[text.index(after: space)...])
    }

    /// Space until no pinyin is left after the command (long input may need more than one pick).
    func confirmAll() {
        for _ in 0..<5 {
            space()
            _ = waitUntil(2) { !Self.hasLatinLetter(self.afterCommand) }
            if !Self.hasLatinLetter(afterCommand) { return }
        }
    }

    /// "@", the first letters of a command and Tab: the palette picks it ("@i" → "@improve ").
    func command(_ prefix: String) {
        key("@", keyCodes["2"]!, .shift)
        type(prefix)
        key("\t", tabCode)
    }

    /// Shift pressed and released on its own (built from CGEvents, like the system's own events).
    func tapShift() {
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: eventSource, virtualKey: leftShiftCode, keyDown: down) else { return }
            cg.type = .flagsChanged
            cg.flags = down ? .maskShift : []
            if let event = NSEvent(cgEvent: cg) { dispatch(event) }
            pump(0.05)
        }
    }

    /// Left Option pressed and released on its own, with the left-Option device bit as the system sets it.
    func tapOption() {
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: eventSource, virtualKey: leftOptionCode, keyDown: down) else { return }
            cg.type = .flagsChanged
            cg.flags = down ? [.maskAlternate, CGEventFlags(rawValue: 0x20)] : []  // NX_DEVICELALTKEYMASK
            if let event = NSEvent(cgEvent: cg) { dispatch(event) }
            pump(0.05)
        }
    }

    /// The input method's action key (config `actionKey`): Return unless set otherwise.
    lazy var actionKey = configValue("actionKey") as? String ?? "enter"

    /// Presses the action key: runs the action on the sentence (converting pinyin still being typed).
    func act() {
        switch actionKey {
        case "optionTap": tapOption()
        case "optionSpace": space(.option)
        case "space": space()
        default: enter()
        }
    }

    /// The command as typed, without AI: ⇧Return (Return alone runs it, whatever the action key).
    func asTyped() { key("\r", returnCode, .shift) }

    /// Clears everything (used between steps so one failure doesn't cascade). Two Escapes take the
    /// input method from any state back to idle (level two → draft → nothing).
    func reset() {
        if textView.hasMarkedText() {
            escape()
            escape()
            if textView.hasMarkedText() { textView.unmarkText() }
        }
        pump(0.1)
    }

    static func hasHan(_ s: String) -> Bool { s.unicodeScalars.contains { $0.properties.isIdeographic } }
    static func looksEnglish(_ s: String) -> Bool {
        !s.isEmpty && !hasHan(s) && s.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count >= 3
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 240, y: 420, width: 760, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AllInOneIME real-app test"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: 18)
        textView.isRichText = false
        // Keep AppKit from rewriting what the input method inserts.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = textView
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(textView)

        // Safety net if something hangs. TIS may only be used on the main thread, so the input
        // source is restored afterwards by `RealTest --restore-input-source` (run by make).
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            print("✗ watchdog: test took too long")
            print("REALTEST FAILED (timeout)")
            fflush(stdout)
            exit(3)
        }
        DispatchQueue.main.async { self.run() }
    }

    func finish() -> Never {
        reset()
        if let originalSource {
            selectInputSource(originalSource)
            pump(0.3)
            check(currentInputSourceID() == originalSource, "input source restored to \(originalSource)")
        }
        let png = window.contentView.flatMap { view -> Data? in
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        let out = outputDirectory
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let png, (try? png.write(to: out.appendingPathComponent("textview.png"))) != nil {
            note("text view snapshot: \(out.path)/textview.png")
        }
        print("--- document ---\n\(textView.string)\n----------------")
        print(failures == 0 ? "REALTEST PASSED" : "REALTEST FAILED (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Test

    func run() {
        // While the lock screen is up, macOS routes no app's keys to input methods (verified: keys go
        // straight into the text view and the input method never sees them), so the test can't run.
        if screenIsLocked() {
            print("✗ the screen is locked: unlock the Mac, then run `make realtest` again")
            print("REALTEST BLOCKED (screen locked)")
            fflush(stdout)
            exit(4)
        }
        if !window.isKeyWindow {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            _ = waitUntil(3) { self.window.isKeyWindow }
        }
        note("app active: \(NSApp.isActive), window key: \(window.isKeyWindow), "
             + "text view first responder: \(window.firstResponder === textView)")
        if !window.isKeyWindow {
            dispatchThroughApp = false
            note("window is not key; delivering keys to the text view directly")
        }
        originalSource = currentInputSourceID()
        if let originalSource {
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try? originalSource.write(to: originalSourceFile, atomically: true, encoding: .utf8)
        }
        note("input source before: \(originalSource ?? "?")")
        let secure = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"]
        note("secure input: \(IsSecureEventInputEnabled() ? "ON (pid \(secure ?? "?")) — translations will be refused" : "off")")

        guard let context = textView.inputContext else {
            check(false, "text view has an input context")
            finish()
        }
        context.activate()
        context.selectedKeyboardInputSource = imeID
        pump(0.5)
        if context.selectedKeyboardInputSource != imeID { selectInputSource(imeID); pump(0.5) }
        check(context.selectedKeyboardInputSource == imeID,
              "AllInOneIME selected (context: \(context.selectedKeyboardInputSource ?? "nil"), system: \(currentInputSourceID() ?? "nil"))")

        // Warm-up: the first keys start the input method process (and wait for its dictionaries).
        var reachable = false
        let warmStart = Date()
        while Date().timeIntervalSince(warmStart) < 25 {
            let before = committed
            type("a")
            if waitUntil(3, { !self.marked.isEmpty || self.committed != before }), !marked.isEmpty {
                reachable = true
                escape()
                break
            }
            if committed != before { backspace() }  // the key went straight into the text: not ready yet
            pump(1)
        }
        check(reachable, String(format: "input method answers (%.1fs, process running: %@)",
                                Date().timeIntervalSince(warmStart), imeIsRunning() ? "yes" : "no"))
        guard reachable else { finish() }
        textView.string = ""

        // 1. Level one: local pinyin; without a command Space inserts the Chinese, like any input method.
        print("— level one: pinyin")
        type("nihao")
        check(waitUntil(3) { self.marked.replacingOccurrences(of: " ", with: "") == "nihao" },
              "pinyin is marked inline (\(marked))")
        _ = waitUntil(2) { !imePanelFrames().isEmpty }
        let panels = imePanelFrames()
        if let caret = Optional(textView.firstRect(forCharacterRange: textView.markedRange(), actualRange: nil)),
           let panel = panels.first {
            let below = panel.maxY <= caret.minY + 1 && caret.minY - panel.maxY < 40
            let aligned = abs(panel.minX - caret.minX) < 120
            check(below && aligned, "candidate panel sits under the caret (panel \(panel.integral), caret \(caret.integral))")
        } else {
            note("candidate panel not on screen (\(panels.count) windows; expected while the screen is locked)")
        }
        space()
        check(waitUntil(3) { self.committed == "你好" && self.marked.isEmpty }, "Space inserts 你好 (document: '\(committed)')")

        // 2. Keys the input method doesn't need still reach the app.
        print("— pass-through")
        key(",", keyCodes[","]!)
        check(waitUntil(2) { self.committed == "你好，" }, "',' types a Chinese comma")
        enter()
        check(waitUntil(2) { self.committed == "你好，\n" }, "Enter with nothing pending makes a new line")
        type("ceshi")
        _ = waitUntil(2) { !self.marked.isEmpty }
        escape()
        check(waitUntil(2) { self.marked.isEmpty && self.committed == "你好，\n" }, "Esc cancels pinyin")
        reset()

        // 3. Level two: the action key on a finished @improve sentence translates; Space inserts the
        //    first English line.
        print("— level two: @improve translates (live Bedrock, key: \(actionKey))")
        textView.string = ""
        command("i")
        check(waitUntil(2) { self.marked == "@improve " }, "@i Tab picks @improve (marked: '\(marked)')")
        type("wojintianyoudianbushufu")
        _ = waitUntil(3) { self.marked != "@improve " }
        confirmAll()
        check(waitUntil(3) { Self.hasHan(self.afterCommand) && !Self.hasLatinLetter(self.afterCommand) },
              "sentence confirmed (marked: \(marked))")
        let started = Date()
        act()
        let translated = waitUntil(20) {
            if self.committed.isEmpty { self.space() }  // ignored until the first English line is complete
            return !self.committed.isEmpty
        }
        let english = committed
        check(translated && Self.looksEnglish(english) && marked.isEmpty,
              String(format: "Space inserts English after %.1fs: '%@'", Date().timeIntervalSince(started), english))
        reset()

        // 4. Digit picks another candidate. With ⌥Space or a tap of ⌥ the key goes right on the pinyin
        //    (it is converted first); with Space the sentence is confirmed first.
        print("— level two: digit 2")
        textView.string = ""
        command("i")
        type("zhegexiangmudejindutaimanle")
        _ = waitUntil(3) { self.marked != "@improve " }
        if actionKey == "space" { confirmAll() }
        act()
        check(waitUntil(3) { Self.hasHan(self.afterCommand) && !Self.hasLatinLetter(self.afterCommand) },
              "sentence converted and sent (\(marked))")
        let picked = waitUntil(20) {
            if self.committed.isEmpty { self.key("2", keyCodes["2"]!); self.pump(0.3) }
            return !self.committed.isEmpty
        }
        check(picked && Self.looksEnglish(committed), "digit 2 inserts another English version: '\(committed)'")
        reset()

        // 5. In level two, 0 keeps the Chinese and Esc goes back to the draft.
        print("— level two: 0 / Esc")
        textView.string = ""
        command("i")
        type("nihao")
        space()
        act()
        key("0", keyCodes["0"]!)
        check(waitUntil(3) { self.committed == "你好" && self.marked.isEmpty }, "0 inserts the Chinese original")
        command("i")
        type("nihao")
        space()
        act()
        escape()
        check(waitUntil(3) { self.marked == "@improve 你好" && self.committed == "你好" }, "Esc returns to the draft")
        type("ma")
        space()
        check(waitUntil(3) { self.afterCommand.hasPrefix("你好") && self.afterCommand.count == 3
                             && Self.hasHan(String(self.afterCommand.suffix(1))) },
              "typing continues the sentence (\(marked))")
        let continued = marked
        asTyped()
        check(waitUntil(3) { self.committed == "你好" + continued && self.marked.isEmpty },
              "⇧Return inserts it as typed (document: '\(committed)')")
        reset()

        // 6. ⇧Space is Space: it picks the candidate, and with nothing pending the app types a space.
        print("— ⇧Space")
        textView.string = ""
        type("nihao")
        space(.shift)
        check(waitUntil(3) { self.committed == "你好" && self.marked.isEmpty }, "⇧Space picks 你好, like Space")
        space(.shift)
        check(waitUntil(2) { self.committed == "你好 " && self.marked.isEmpty },
              "with nothing pending, ⇧Space types a space ('\(committed)')")
        reset()

        // 7. Shift alone switches to English and back. English letters go straight in; after
        //    @improve they collect into the command and the action key polishes them.
        print("— Shift: English / Chinese")
        textView.string = ""
        tapShift()
        type("abc")
        check(waitUntil(2) { self.committed == "abc" && self.marked.isEmpty }, "after Shift, letters are typed as English ('\(committed)')")
        print("— English @improve (live Bedrock)")
        textView.string = ""
        command("i")
        let words = ["this", "is", "a", "blocker", "bug", "your", "team", "need", "fix", "it", "asap"]
        for word in words {
            type(word)
            space()
        }
        check(waitUntil(2) { self.marked == "@improve " + words.joined(separator: " ") + " " }, "sentence drafted (\(marked))")
        let polishStarted = Date()
        act()
        let polished = waitUntil(20) {
            if self.committed.isEmpty { self.space() }  // ignored until the first version is complete
            return !self.committed.isEmpty
        }
        check(polished && Self.looksEnglish(committed) && committed != words.joined(separator: " ") && marked.isEmpty,
              String(format: "the action key polishes, Space inserts after %.1fs: '%@'", Date().timeIntervalSince(polishStarted), committed))
        textView.string = ""
        tapShift()
        type("ni")
        check(waitUntil(2) { !self.marked.isEmpty }, "after Shift again, pinyin input is back (marked: \(marked))")
        reset()

        finish()
    }

    /// A value from the input method's config file (nil if unset or the file is missing).
    func configValue(_ key: String) -> Any? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/allinoneime/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json[key]
    }
}

// Helper modes, run as a plain command (used by the Makefile and the unlock watcher).
switch CommandLine.arguments.dropFirst().first {
case "--is-locked":
    print(screenIsLocked() ? "true" : "false")
    exit(0)
case "--restore-input-source":
    // Backup for when the test couldn't restore it itself (watchdog timeout or crash).
    if let original = try? String(contentsOf: originalSourceFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty, currentInputSourceID() != original {
        print(selectInputSource(original) ? "input source restored to \(original)" : "could not restore \(original)")
    }
    exit(0)
default:
    break
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let harness = Harness()
app.delegate = harness
app.run()
