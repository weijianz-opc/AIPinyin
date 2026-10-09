import AllInOneIMECore
import AllInOneIMERime
import AppKit
import AVFoundation
import Carbon
import InputMethodKit
import SwiftUI

/// Records what the input method does to a text field. Like NSTextView, marked or inserted text
/// takes the place of the selection when nothing is marked (empty marked text too, which deletes it).
final class FakeTextClient: NSObject, IMKTextInput {
    var marked = ""
    var markedSelection = NSRange(location: 0, length: 0)
    var inserted: [String] = []
    /// The text field's contents, without the marked text.
    var document = ""
    /// Selected range of `document`; nil: just a caret, at `anchor`.
    var selection: NSRange?
    /// Where the caret (and marked text) is; nil: the end of `document`.
    var anchor: Int?
    /// How much of a requested range the field hands over, in UTF-16 units (Chromium only keeps the
    /// text near the selection on the input method's side); 0: none at all.
    var readLimit = Int.max
    /// Replacement ranges passed with inserted text.
    var replacements: [NSRange] = []
    /// Like Java's text views: a replacement range is ignored, inserted text replaces the selection.
    var ignoresReplacementRange = false
    /// Pretend to be another application (nil: this one).
    var bundleIDOverride: String?
    /// Screen rect of the caret line, used to position the candidate panel.
    var caretRect = NSRect(x: 420, y: 560, width: 1, height: 18)

    private static func plain(_ value: Any?) -> String {
        if let s = value as? NSAttributedString { return s.string }
        return value as? String ?? ""
    }

    /// Puts the field in a known state: `document` with `selected` (its first occurrence) selected.
    func reset(_ document: String = "", selecting selected: String? = nil) {
        self.document = document
        anchor = nil
        replacements.removeAll()
        selection = selected.map { (document as NSString).range(of: $0) }
    }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        if replacementRange.location != NSNotFound, !ignoresReplacementRange {
            replacements.append(replacementRange)
            remove(replacementRange)
        } else if marked.isEmpty, let selection {
            remove(selection)  // typed over the selection
        }
        let s = Self.plain(string)
        inserted.append(s)
        let doc = NSMutableString(string: document)
        let at = min(anchor ?? doc.length, doc.length)
        doc.insert(s, at: at)
        document = doc as String
        if anchor != nil { anchor = at + (s as NSString).length }
        marked = ""
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        if replacementRange.location != NSNotFound {
            remove(replacementRange)
        } else if marked.isEmpty, let selection {
            remove(selection)
        }
        marked = Self.plain(string)
        markedSelection = selectionRange
    }

    /// Takes `range` out of the document; marked or inserted text then goes in its place.
    private func remove(_ range: NSRange) {
        let doc = NSMutableString(string: document)
        guard NSMaxRange(range) <= doc.length else { return }
        doc.deleteCharacters(in: range)
        document = doc as String
        anchor = range.location
        selection = nil
    }

    func selectedRange() -> NSRange {
        selection ?? NSRange(location: anchor ?? (document as NSString).length, length: 0)
    }

    func markedRange() -> NSRange {
        marked.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: anchor ?? (document as NSString).length, length: (marked as NSString).length)
    }

    /// The part of `range` the field hands over (see `readLimit`).
    private func readable(_ range: NSRange) -> NSRange? {
        guard readLimit > 0, range.location != NSNotFound, NSMaxRange(range) <= (document as NSString).length
        else { return nil }
        return NSRange(location: range.location, length: min(range.length, readLimit))
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        readable(range).map { NSAttributedString(string: (document as NSString).substring(with: $0)) }
    }

    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        guard let part = readable(range) else { return nil }
        actualRange?.pointee = part
        return (document as NSString).substring(with: part)
    }

    func length() -> Int { (document as NSString).length }

    func characterIndex(
        for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
        inMarkedRange: UnsafeMutablePointer<ObjCBool>!
    ) -> Int { NSNotFound }

    func attributes(
        forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!
    ) -> [AnyHashable: Any]! {
        lineRect?.pointee = caretRect
        return [:]
    }

    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { bundleIDOverride ?? Bundle.main.bundleIdentifier ?? "com.aipinyin.selftest" }
    func windowLevel() -> CGWindowLevel { CGWindowLevelForKey(.normalWindow) }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "allinoneime-selftest" }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { caretRect }
}

/// End-to-end check of the input controller without the system text input server.
@MainActor
enum SelfTest {
    static var failures = 0
    /// What the controller under test reads as its settings (the real config, adjusted per section).
    static var settings = Config.default

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "✓" : "✗") \(message)")
        if !condition { failures += 1 }
    }

    static let keyCodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, " ": 0x31, ",": 0x2B,
    ]

    static func event(
        _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown,
        isRepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isRepeat, keyCode: code)!
    }

    @discardableResult
    static func press(
        _ controller: AllInOneIMEInputController, _ client: FakeTextClient,
        _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []
    ) -> Bool {
        controller.handle(event(characters, code: code, flags: flags), client: client)
    }

    static func type(_ text: String, _ controller: AllInOneIMEInputController, _ client: FakeTextClient) {
        for ch in text { press(controller, client, String(ch), code: keyCodes[ch] ?? 0) }
    }

    static func space(_ c: AllInOneIMEInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, " ", code: VirtualKey.space)
    }

    /// ⌥Space as a US layout delivers it (it types a no-break space).
    static func optionSpace(_ c: AllInOneIMEInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, "\u{A0}", code: VirtualKey.space, flags: .option)
    }

    /// Left Option pressed and released on its own, as the system reports it (with the device bit).
    static func tapOption(_ c: AllInOneIMEInputController, _ client: FakeTextClient) {
        let down = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | AllInOneIMEInputController.leftOptionBit)
        _ = c.handle(event("", code: VirtualKey.leftOption, flags: down, type: .flagsChanged), client: client)
        _ = c.handle(event("", code: VirtualKey.leftOption, flags: [], type: .flagsChanged), client: client)
    }

    /// Presses the translate key the controller is set to.
    @discardableResult
    static func translate(_ c: AllInOneIMEInputController, _ client: FakeTextClient) -> Bool {
        switch c.composer.translateKey {
        case .optionSpace: return optionSpace(c, client)
        case .optionTap: tapOption(c, client); return true  // modifier changes always reach the app too
        case .space: return space(c, client)
        }
    }

    /// The hint shown under a draft in `input`, for the current translate key and interface language.
    static func draftHint(_ c: AllInOneIMEInputController, input: Language) -> CandidateView.Status {
        let key = c.composer.translateKey
        let how = key != .space ? UIText.name(key) : c.composer.spaceTranslates ? UIText.name(TranslateKey.space) : tr("连按两次空格", "Space twice")
        return .hint("\(how) → " + UIText.action(input: input, config: settings))
    }

    static func enter(_ c: AllInOneIMEInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, "\r", code: VirtualKey.returnKey)
    }

    static func escape(_ c: AllInOneIMEInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, "\u{1B}", code: VirtualKey.escape)
    }

    /// Shift pressed and released on its own.
    static func tapShift(_ c: AllInOneIMEInputController, _ client: FakeTextClient) {
        _ = c.handle(event("", code: VirtualKey.leftShift, flags: .shift, type: .flagsChanged), client: client)
        _ = c.handle(event("", code: VirtualKey.leftShift, flags: [], type: .flagsChanged), client: client)
    }

    static func pump(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return true
    }

    /// Settings window, run against a temporary copy of the config (the real file is never written).
    static func testSettingsWindow(snapshotDirectory: URL) {
        print("— settings window")
        let dir = snapshotDirectory.appendingPathComponent("settings-config")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let real = (try? Config.load()) ?? .default
        try? real.write(to: url)
        let realBefore = try? Data(contentsOf: Config.defaultURL)

        let model = SettingsModel(configURL: url, aiEnabled: true, saveAI: { _ in })
        check(model.canSave && model.config == real, "loads the config")
        check(model.profiles.contains(real.awsProfile), "profile picker lists \(real.awsProfile) (\(model.profiles))")
        check(model.credentialStatus == SettingsModel.credentialsFound, "credentials found: \(model.credentialStatus)")
        let casual = RewriteStyle.named("口语")!
        let wasOn = model.isStyleOn(casual)
        model.setStyle(casual, on: !wasOn)
        let saved = (try? Config.load(from: url))?.rewriteStyles ?? []
        check(saved.contains("口语") == !wasOn, "toggling 口语 saves at once (\(saved))")
        model.setStyle(casual, on: wasOn)
        let key = model.config.translateKey
        model.config.translateKey = key == .optionSpace ? .space : .optionSpace
        model.save()
        check((try? Config.load(from: url))?.translateKey == model.config.translateKey, "the translate key is saved")
        model.config.translateKey = key
        model.save()

        // The test button makes a live request with the window's settings.
        model.runTest()
        _ = pump(timeout: 20) { model.testStatus != .running }
        if case let .passed(text) = model.testStatus {
            check(true, "测试连接 works: \(text.replacingOccurrences(of: "\n", with: " / "))")
        } else {
            check(false, "测试连接 failed: \(model.testStatus)")
        }

        // Rendered offscreen (nothing appears on screen) for a visual check and the README: the
        // real config, read-only, with a live 测试连接 result.
        let list = dir.appendingPathComponent("jargon.txt")
        try? Data("# 我们组的\nbandwidth：精力\nLP\tLeadership Principles\n抓手 - 着力点\n".utf8).write(to: list)
        model.config.jargonFile = list.path
        model.refreshJargon()
        check(model.jargonExists && model.jargonCount == 3, "the user's jargon list is counted (\(model.jargonCount) terms)")
        // The window follows the system language: Chinese only when it comes before English.
        check(!UIText.prefersChinese(["en-US", "zh-Hans-US"]) && UIText.prefersChinese(["zh-Hans-CN", "en-US"])
              && UIText.prefersChinese(["ja-JP", "zh-Hant-TW", "en"]) && !UIText.prefersChinese(["ja-JP"]),
              "the settings language follows the preferred languages (this Mac: \(UIText.systemPrefersChinese ? "中文" : "English"))")
        // Unless one is picked in the window: it applies at once and is saved.
        let pickedBefore = UIText.choice
        defer { UIText.choice = pickedBefore }
        for picked in [Language.english, .chinese] {
            model.setUILanguage(picked)
            check(UIText.chinese == (picked == .chinese) && (try? Config.load(from: url))?.uiLanguage == picked
                  && model.credentialStatus == SettingsModel.credentialsFound,
                  "界面语言 \(picked.rawValue): applies at once and is saved (\(model.credentialStatus))")
        }
        model.setUILanguage(nil)
        check(UIText.chinese == UIText.systemPrefersChinese && (try? Config.load(from: url))?.uiLanguage == nil,
              "界面语言 跟随系统 is saved as null")
        func render(_ name: String, chinese: Bool) {
            UIText.choice = chinese ? .chinese : .english
            let preview = SettingsModel(configURL: Config.defaultURL, aiEnabled: true, saveAI: { _ in }, persists: false)
            preview.runTest()
            _ = pump(timeout: 20) { preview.testStatus != .running }
            let host = NSHostingView(rootView: SettingsView(model: preview))
            let size = NSSize(width: 560, height: 1700)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.appearance = NSAppearance(named: .aqua)  // README images are light, whatever the Mac uses
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            _ = pump(timeout: 0.5) { false }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: snapshotDirectory.appendingPathComponent("\(name).png"))
                    print("  snapshot \(snapshotDirectory.path)/\(name).png (\(Int(size.width))×\(Int(size.height)))")
                }
            }
            window.close()
        }
        render("6-settings", chinese: true)  // README
        render("6-settings-en", chinese: false)
        UIText.choice = pickedBefore

        // A config file that doesn't parse is shown as an error and never overwritten.
        try? Data("{ broken".utf8).write(to: url)
        let broken = SettingsModel(configURL: url, aiEnabled: true, saveAI: { _ in })
        broken.setStyle(casual, on: true)
        broken.save()
        check(!broken.canSave && broken.loadError != nil
              && (try? String(contentsOf: url, encoding: .utf8)) == "{ broken",
              "a broken config file is reported, not overwritten")
        check((try? Data(contentsOf: Config.defaultURL)) == realBefore, "the real config file was not touched")
    }

    /// Runs `work` while pumping the main run loop (the self-test is synchronous main-thread code).
    static func runAsync<T>(_ timeout: TimeInterval, _ work: @escaping () async throws -> T) -> T? {
        var result: T?
        var done = false
        Task { @MainActor in
            result = try? await work()
            done = true
        }
        _ = pump(timeout: timeout) { done }
        return result
    }

    /// Waits for a live conversion to finish; returns false (and records a failure) if it failed.
    static func finishConversion(_ controller: AllInOneIMEInputController, _ what: String) -> Bool {
        let started = Date()
        _ = pump(timeout: 20) { if case .translating = controller.composer.phase { return false } else { return true } }
        if case let .failed(message) = controller.composer.phase {
            check(false, "\(what) failed: \(message)")
            return false
        }
        check(controller.composer.phase == .choosing, String(format: "\(what) finished in %.2fs", Date().timeIntervalSince(started)))
        for choice in controller.composer.choices { print("  \(choice.label) \(choice.text)\(choice.kind.isRewrite ? "  [\(choice.kind)]" : "")") }
        return controller.composer.phase == .choosing
    }

    /// Selected text: the selection key (a tap of ⌥ by default; ⌥Space when that is the translate key,
    /// or when the translate key is Space) sends it to the model. It stays selected and untouched until
    /// a line is chosen, which then takes exactly its place; every other way out leaves the field as it
    /// was. The sentence is the one level two already translated, so it comes from the cache.
    static func testSelection(_ controller: AllInOneIMEInputController, _ client: FakeTextClient,
                              snapshotDirectory: URL) {
        print("— selected text: the translate key rewrites it in place")
        settings.translateKey = .optionTap
        controller.applySettings()
        /// Presses the selection key for the current setting (a tap of ⌥ always reaches the app too).
        func send() {
            if controller.composer.selectionKey == .optionTap { tapOption(controller, client) } else { _ = optionSpace(controller, client) }
        }
        func notice() -> String { controller.panelModel().detail ?? "" }
        func answered() { _ = pump(timeout: 2) { controller.composer.phase == .choosing } }
        let sentence = "我今天有点不舒服"
        let line = "回复：\(sentence)\n下一行"
        let selected = (line as NSString).range(of: sentence)
        /// The field is as it was: same text, same selection, nothing marked.
        func untouched() -> Bool { client.document == line && client.selection == selected && client.marked.isEmpty }

        // Triple-click selects the line with its line break: only the sentence is replaced, so the
        // line break (in a web editor, the paragraph boundary) stays.
        client.reset(line, selecting: sentence + "\n")
        send()
        check(controller.composer.replacesSelection && client.marked.isEmpty && client.document == line && client.selection != nil,
              "单按 ⌥ sends the selected text; it stays in the document, untouched, meanwhile")
        if finishConversion(controller, "selection translation") {
            check(controller.panelModel().footer == "空格 / ⏎ 替换 · 数字选择 · 0 / Esc 保留原文",
                  "footer: \(controller.panelModel().footer)")
            snapshot("10-selection", in: snapshotDirectory)
            let chosen = controller.composer.choices[controller.composer.highlighted].text
            // Held down, Space repeats: that must not pick a line by itself.
            check(controller.handle(event(" ", code: VirtualKey.space, isRepeat: true), client: client)
                  && client.document == line && controller.composer.phase == .choosing,
                  "a repeating Space doesn't pick a line (auto-repeat is ignored)")
            check(enter(controller, client) && client.document == "回复：\(chosen)\n下一行" && client.replacements == [selected],
                  "⏎ puts the highlighted line in place of the sentence, line break kept: \(client.document)")
        }
        // Space too; a field that ignores the replacement range (Java's) replaces its whole selection.
        client.reset(line, selecting: sentence)
        client.ignoresReplacementRange = true
        send()
        answered()
        let first = controller.composer.choices.first { $0.kind == .version }?.text ?? ""
        check(space(controller, client) && client.document == "回复：\(first)\n下一行",
              "Space too, also in a field that ignores the replacement range (\(client.document))")
        client.ignoresReplacementRange = false
        // A click or scroll while ⌥ was down (an ⌥-click, an ⌥-drag) is not a tap.
        let pointer = controller.pointerUsedWithin
        controller.pointerUsedWithin = { _ in true }
        client.reset(line, selecting: sentence)
        send()
        check(!controller.composer.isComposing && untouched(), "an ⌥-click doesn't send the selected text")
        // The guard looks back over the press only: also for the right ⌥, and for synthesized events
        // without a timestamp (automation tools, the real-app test).
        var looked: [TimeInterval] = []
        controller.pointerUsedWithin = { seconds in
            looked.append(seconds)
            return false
        }
        let rightDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | AllInOneIMEInputController.rightOptionBit)
        for (code, flags, stamp) in [(VirtualKey.rightOption, rightDown, ProcessInfo.processInfo.systemUptime),
                                     (VirtualKey.leftOption, NSEvent.ModifierFlags.option, 0.0)] {
            client.reset(line, selecting: sentence)
            for down in [true, false] {
                let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? flags : [],
                                         timestamp: stamp, windowNumber: 0, context: nil, characters: "",
                                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                _ = controller.handle(e, client: client)
            }
            check(controller.composer.replacesSelection, "a tap of \(code == VirtualKey.rightOption ? "right" : "left") ⌥ "
                  + "(timestamp \(stamp == 0 ? "0" : "set")) sends the selected text")
            _ = escape(controller, client)
        }
        check(looked.count == 2 && looked.allSatisfy { $0 >= 0 && $0 <= 0.5 }, "the ⌥-click check covers just the press (\(looked))")
        controller.pointerUsedWithin = pointer

        let leaving: [(String, () -> Void)] = [
            ("Esc", { _ = escape(controller, client) }),
            ("0 (the original)", { _ = press(controller, client, "0", code: 0x1D) }),
            ("⌫", { _ = press(controller, client, "\u{7F}", code: VirtualKey.delete) }),
            ("focus loss", { controller.commitComposition(client) }),
        ]
        for (name, leave) in leaving {
            client.reset(line, selecting: sentence)
            send()
            answered()
            leave()
            check(untouched() && !controller.composer.isComposing, "\(name) leaves the selected text as it was")
        }
        client.reset(line, selecting: sentence)
        send()  // still waiting for the answer
        _ = press(controller, client, " ", code: VirtualKey.space, flags: .shift)
        check(untouched() && !controller.composer.aiEnabled && !controller.composer.isComposing,
              "so does turning AI off (⇧Space) while it is converted")
        _ = press(controller, client, " ", code: VirtualKey.space, flags: .shift)

        // The field changed while the panel was up: nothing is replaced.
        client.reset(line, selecting: sentence)
        send()
        answered()
        client.selection = NSRange(location: 0, length: 2)  // something else selected meanwhile
        check(space(controller, client) && client.document == line && client.replacements.isEmpty && notice().contains("变了"),
              "a selection that moved is left alone (\(notice()))")
        client.reset(line, selecting: sentence)
        send()
        answered()
        let edited = line.replacingOccurrences(of: "今天", with: "明天")
        client.document = edited  // same range, different text
        check(space(controller, client) && client.document == edited && client.replacements.isEmpty,
              "so is selected text that was edited meanwhile")

        // Typing with the panel up types over the selection, as in any text field.
        client.reset(line, selecting: sentence)
        send()
        type("ni", controller, client)
        check(!controller.composer.replacesSelection && controller.composer.phase == .drafting && !client.marked.isEmpty
              && client.document == "回复：\n下一行", "typing closes the panel and types over the selection (\(client.marked))")
        _ = escape(controller, client)

        // ⌘X, ⌘Z … act on the selected text: the panel closes and the shortcut reaches the app.
        client.reset(line, selecting: sentence)
        send()
        answered()
        check(!press(controller, client, "x", code: 0x07, flags: .command) && !controller.composer.isComposing && untouched(),
              "a ⌘ shortcut closes the panel and reaches the app")
        check(!space(controller, client) && client.replacements.isEmpty, "and nothing is replaced afterwards")

        // With nothing of ours marked, clearing marked text would delete the selection in NSTextView.
        client.reset(line, selecting: sentence)
        tapShift(controller, client)
        tapShift(controller, client)
        check(untouched(), "switching 中/英 with text selected leaves it alone")
        controller.commitComposition(client)
        check(untouched(), "so does the app ending a composition when nothing is composed")

        controller.secureInputActive = { true }
        client.reset(line, selecting: sentence)
        send()
        if case let .failed(message) = controller.composer.phase {
            check(message.contains("安全输入"), "nothing is sent while secure input is on: \(message)")
        } else {
            check(false, "expected the selection to be refused under secure input, got \(controller.composer.phase)")
        }
        check(escape(controller, client) && untouched(), "Esc then leaves it as it was")
        controller.secureInputActive = { false }
        // In the app holding secure input nothing is composed or read; the tap does nothing.
        controller.blocksComposing = { _ in true }
        client.reset(line, selecting: sentence)
        send()
        check(untouched() && !controller.composer.isComposing, "in the app holding secure input, 单按 ⌥ does nothing")
        controller.blocksComposing = { SecureInput.blocksComposing($0) }
        // Secure input turns on while the panel is up: the panel closes; the next key doesn't type
        // over the text if it is still selected, but reaches the app if focus moved on (a password field).
        client.reset(line, selecting: sentence)
        send()
        answered()
        controller.blocksComposing = { _ in true }
        check(space(controller, client) && untouched() && !controller.composer.isComposing && client.replacements.isEmpty,
              "secure input mid-panel: Space doesn't type over the selected text")
        controller.blocksComposing = { SecureInput.blocksComposing($0) }
        client.reset(line, selecting: sentence)
        send()
        answered()
        client.selection = nil  // focus moved to an empty password field
        controller.blocksComposing = { _ in true }
        check(!press(controller, client, "a", code: 0x00) && !controller.composer.isComposing,
              "but a key in the field that took focus reaches it")
        controller.blocksComposing = { SecureInput.blocksComposing($0) }

        // Refused, with a notice, without touching the field (the order keeps the notices distinct).
        let long = String(repeating: "长", count: Composer.maxSelectionLength * 5)
        client.reset(long, selecting: long)
        send()
        check(client.document == long && client.selection != nil && notice().contains("太长"), "a long selection is refused (\(notice()))")
        client.reset(line, selecting: sentence)
        client.readLimit = 3  // like Chromium, which only keeps the text near the selection
        send()
        check(untouched() && !controller.composer.isComposing && notice().contains("读不到"),
              "a selection the app only partly hands over is left alone (\(notice()))")
        client.readLimit = .max
        client.reset("第一行\n第二行", selecting: "第一行\n第二行")
        send()
        check(client.document == "第一行\n第二行" && notice().contains("几行"), "several lines are refused (\(notice()))")
        client.reset("上一行\n\n下一行")
        client.selection = NSRange(location: 4, length: 1)  // triple-click on the empty line
        send()
        check(client.document == "上一行\n\n下一行" && client.selection != nil && notice().contains("空格或换行"),
              "an empty line is refused (\(notice()))")
        client.reset("看这个\u{FFFC}图很好", selecting: "看这个\u{FFFC}图很好")
        send()
        check(client.document == "看这个\u{FFFC}图很好" && notice().contains("图片或附件"),
              "text with an inline image is refused, so the image is kept (\(notice()))")
        let halfEmoji = NSString(characters: [0x597D, 0xD83D], length: 2) as String  // 好 + half of 😀
        client.reset(halfEmoji, selecting: halfEmoji)
        send()
        check(client.document == halfEmoji && notice().contains("读不到"), "a selection that splits a character is refused (\(notice()))")
        client.reset(line, selecting: sentence)
        client.readLimit = 0
        send()
        check(untouched() && notice().contains("读不到"), "so is a selection the app doesn't hand over at all")
        client.readLimit = .max
        _ = press(controller, client, " ", code: VirtualKey.space, flags: .shift)  // AI off
        client.reset(line, selecting: sentence)
        send()
        check(untouched() && notice().contains("AI 翻译已关"), "with AI off the selection is kept (\(notice()))")
        _ = press(controller, client, " ", code: VirtualKey.space, flags: .shift)
        check(controller.composer.aiEnabled, "AI back on")
        settings.uiLanguage = .english
        controller.applySettings()
        client.reset("第一行\n第二行", selecting: "第一行\n第二行")
        send()
        check(notice() == Composer.Messages.english.selectionMultiline, "in the English interface: \(notice())")
        settings.uiLanguage = .chinese
        controller.applySettings()
        client.reset(line)
        send()
        check(!controller.composer.isComposing, "a tap with nothing selected does nothing")
        client.reset(line, selecting: sentence)
        client.bundleIDOverride = "com.apple.Terminal"
        send()
        check(!controller.composer.isComposing && untouched(), "in a terminal the selection is left to the terminal")
        client.bundleIDOverride = nil
        // With 单按 ⌥ as the key, ⌥Space is just ⌥Space (nothing is read).
        client.reset(line, selecting: sentence)
        check(!optionSpace(controller, client) && !controller.composer.isComposing, "with 单按 ⌥, ⌥Space reaches the app")

        // ⌥Space when it is the translate key, or when the translate key is Space.
        for key in [TranslateKey.optionSpace, .space] {
            settings.translateKey = key
            controller.applySettings()
            client.reset(line, selecting: sentence)
            check(optionSpace(controller, client) && controller.composer.replacesSelection && untouched(),
                  "\(UIText.name(key)) as the key: ⌥Space sends the selected text")
            answered()
            check(controller.handle(event("\u{A0}", code: VirtualKey.space, flags: .option, isRepeat: true), client: client)
                  && controller.composer.phase == .choosing && untouched(), "holding ⌥Space doesn't pick a line")
            _ = escape(controller, client)
            client.reset(long, selecting: long)
            check(optionSpace(controller, client) && client.document == long && notice().contains("太长"),
                  "a refusal consumes ⌥Space, so no space is typed over the selection")
            client.reset("10 km", selecting: " ")
            check(!optionSpace(controller, client) && !controller.composer.isComposing,
                  "a selected space: ⌥Space types a no-break space, as usual")
            client.reset(line)
            check(!optionSpace(controller, client), "⌥Space with nothing selected reaches the app")
            client.reset(line, selecting: sentence)
            client.bundleIDOverride = "com.apple.Terminal"
            check(!optionSpace(controller, client) && !controller.composer.isComposing, "in a terminal ⌥Space reaches the app")
            client.bundleIDOverride = nil
            // In the app holding secure input, ⌥Space would type over the selection: kept (only the range is read).
            controller.blocksComposing = { _ in true }
            client.reset(line, selecting: sentence)
            check(optionSpace(controller, client) && untouched() && notice().contains("安全输入"),
                  "in the app holding secure input, ⌥Space keeps the selection (\(notice()))")
            controller.blocksComposing = { SecureInput.blocksComposing($0) }
        }
        settings.translateKey = .optionTap
        controller.applySettings()
        client.reset()
    }

    /// English typed in English mode → English polish (and English rewrites, incl. 黑话); Chinese
    /// output; the default input mode.
    static func testEnglishAndOutput(_ controller: AllInOneIMEInputController, _ client: FakeTextClient,
                                     snapshotDirectory: URL) {
        print("— English input → English polish + 黑话 (live Bedrock)")
        settings.rewriteStyles = ["润色", "简洁", "黑话"]
        let english = settings
        controller.converter = Converter(loadConfig: { english })
        tapShift(controller, client)
        let sentence = "this is a blocker bug your team need fix it asap"
        type(sentence, controller, client)
        check(client.marked == sentence && controller.composer.isLatinDraft, "English collects into a draft (\(client.marked))")
        check(space(controller, client) && controller.composer.draft.hasSuffix(" ") && !controller.composer.isLevelTwo,
              "Space after a word is a space")
        check(controller.panelModel().status == draftHint(controller, input: .english),
              "the hint names the translate key (\(controller.panelModel().status))")
        snapshot("7a-english-draft", in: snapshotDirectory)
        check(translate(controller, client), "the translate key sends it")
        if finishConversion(controller, "English polish") {
            let choices = controller.composer.choices
            let versions = choices.filter { $0.kind == .version }
            check(versions.count == 3 && versions.allSatisfy { !$0.text.containsHan && $0.text.wordingKey != sentence.wordingKey },
                  "3 polished English versions")
            let rewrites = choices.filter { $0.kind.isRewrite }
            check(!rewrites.isEmpty && rewrites.allSatisfy { !$0.text.containsHan }, "rewrites stay in English")
            check(rewrites.contains { $0.kind == .rewrite("黑话") }, "黑话 rewrite present")
            snapshot("7-english-light", in: snapshotDirectory)
            // The user's own jargon list: the 黑话 row notes what the list's terms in it mean.
            let jargonFile = snapshotDirectory.appendingPathComponent("jargon.txt")
            try? Data("bandwidth：精力、时间\nminor issue：小问题（其实很严重）\n".utf8).write(to: jargonFile)
            settings.jargonFile = jargonFile.path
            if let row = choices.firstIndex(where: { $0.kind == .rewrite(RewriteStyle.jargonName) }) {
                let note = JargonLibrary.annotation(for: choices[row].text, entries: JargonLibrary.load(from: jargonFile))
                let comment = controller.panelModel().rows[row].comment
                check(comment == (note.map { "黑话 · \($0)" } ?? "黑话"), "黑话 row explains the user's terms: \(comment)")
            }
            settings.jargonFile = nil
            try? FileManager.default.removeItem(at: jargonFile)
            _ = space(controller, client)
            check(client.inserted.last == versions.first?.text, "Space inserts the first polished version")
        }
        tapShift(controller, client)

        print("— output Chinese (live Bedrock)")
        settings.outputLanguage = .chinese
        settings.rewriteStyles = ["简洁", "黑话"]
        let chinese = settings
        controller.converter = Converter(loadConfig: { chinese })
        type("zhegexiangmudejindutaimanle", controller, client)
        _ = space(controller, client)
        let typed = controller.composer.draft
        check(typed.containsHan, "Chinese sentence confirmed (\(typed))")
        translate(controller, client)
        if finishConversion(controller, "Chinese polish") {
            let versions = controller.composer.choices.filter { $0.kind == .version }
            check(versions.count >= 2 && versions.allSatisfy { $0.text.containsHan && $0.text.wordingKey != typed.wordingKey },
                  "versions in Chinese, none just repeating the input (\(versions.count) shown)")
            check(controller.panelModel().rows.count == controller.composer.choices.count, "panel shows every row")
            snapshot("7b-chinese-output", in: snapshotDirectory)
            let highlighted = controller.composer.choices[controller.composer.highlighted].text
            _ = enter(controller, client)
            check(client.inserted.last == highlighted, "Enter inserts the highlighted line (\(highlighted))")
        }
        if controller.composer.isComposing { _ = enter(controller, client) }  // after a failure: the original
        settings.outputLanguage = .english

        print("— default input mode")
        settings.defaultInput = .english
        controller.applySettings()
        check(controller.composer.engineState.isAsciiMode, "changing the default to English switches an idle field")
        tapShift(controller, client)
        controller.applySettings()
        check(!controller.composer.engineState.isAsciiMode, "a Shift toggle sticks until the setting changes again")
        settings.defaultInput = .chinese
        controller.applySettings()
        check(!controller.composer.engineState.isAsciiMode, "default back to Chinese")
    }

    /// Hold the right Option key: audio (synthesized speech played from a file instead of the
    /// microphone) is recognized on the Mac and continues the draft.
    static func testVoice(_ controller: AllInOneIMEInputController, _ client: FakeTextClient,
                          snapshotDirectory: URL) {
        print("— voice input (on-device recognition of synthesized speech)")
        guard #available(macOS 26.0, *), VoiceInput.isSupported else {
            print("  SpeechAnalyzer not available on this macOS; skipped")
            return
        }
        settings.rewriteStyles = RewriteStyle.defaultNames
        controller.loadSettings = { SelfTest.settings }
        controller.applySettings()
        let voiced = settings
        controller.converter = Converter(loadConfig: { voiced })
        for language in [Language.chinese, .english] {
            if runAsync(5, { await VoiceInput.isModelInstalled(language) }) == true {
                check(true, "\(language.displayName) speech model installed")
                continue
            }
            print("  downloading the \(language.displayName) speech model (one time)…")
            var last = -1
            let ok = runAsync(900) {
                try await VoiceInput.downloadModel(language) { p in
                    let percent = Int(p * 100)
                    if percent / 20 > last / 20 { print("    \(percent)%"); last = percent }
                }
                return true
            }
            check(ok == true && runAsync(5, { await VoiceInput.isModelInstalled(language) }) == true,
                  "\(language.displayName) speech model downloaded")
        }

        func speech(_ text: String, voice: String, name: String) -> URL? {
            let url = snapshotDirectory.appendingPathComponent("\(name).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", url.path, text]
            guard (try? say.run()) != nil else { return nil }
            say.waitUntilExit()
            return say.terminationStatus == 0 ? url : nil
        }
        var holding = false
        controller.isVoiceKeyHeld = { holding }
        defer { controller.isVoiceKeyHeld = { NSEvent.modifierFlags.contains(.option) && NSEvent.pressedMouseButtons == 0 } }
        func optionKey(down: Bool) {
            holding = down
            // As the system reports it: the Option flag plus the right-Option device bit.
            let flags = down ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue
                                                     | AllInOneIMEInputController.rightOptionBit) : []
            _ = controller.handle(event("", code: VirtualKey.rightOption, flags: flags, type: .flagsChanged), client: client)
        }
        /// Holds the key for the length of the file, then releases it and waits for the transcript.
        /// With `sendWhileHolding`, ⌥Space is pressed before the key is released: the recording stops
        /// and the sentence goes to the model once the transcript is final.
        func dictate(_ url: URL, snapshotName: String? = nil, sendWhileHolding: Bool = false) -> Bool {
            controller.voiceFile = (url, speed: 1)
            let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 2
            optionKey(down: true)
            let started = pump(timeout: 1) { if case .listening = controller.composer.voice { return true } else { return false } }
            guard started else {
                check(false, "holding right ⌥ starts listening (\(controller.composer.voice))")
                return false
            }
            var snapped = false
            _ = pump(timeout: seconds + 0.6) {
                if let snapshotName, !snapped, controller.composer.voice.text.count >= 4 {
                    snapped = true
                    snapshot(snapshotName, in: snapshotDirectory)
                }
                return false
            }
            check(!controller.composer.voice.text.isEmpty, "live transcript while listening: \(controller.composer.voice.text)")
            let released = Date()
            if sendWhileHolding {
                check(optionSpace(controller, client) && controller.composer.translatesAfterVoice,
                      "⌥Space while holding right ⌥ stops the recording and sends once it's recognized")
            }
            optionKey(down: false)
            let done = pump(timeout: 8) { controller.composer.voice == .off }
            check(done, String(format: "final transcript %.2fs after releasing the key", Date().timeIntervalSince(released)))
            controller.voiceFile = nil
            return done
        }

        guard let chineseAudio = speech("我今天有点不舒服", voice: "Tingting", name: "voice-zh"),
              let englishAudio = speech("This is a blocker bug, your team needs to fix it as soon as possible.",
                                        voice: "Samantha", name: "voice-en")
        else {
            check(false, "could not synthesize test audio with say")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: chineseAudio)
            try? FileManager.default.removeItem(at: englishAudio)
        }

        // A tap is not dictation: released before the hold is confirmed, nothing is recorded.
        controller.voiceFile = (chineseAudio, speed: 1)
        optionKey(down: true)
        optionKey(down: false)
        let tapNotice = controller.panelModel().detail
        _ = pump(timeout: 0.5) { false }  // past the arming delay
        controller.voiceFile = nil
        check(controller.composer.voice == .off && controller.composer.draft.isEmpty && tapNotice == "按住右 ⌥ 说话",
              "a quick tap of right ⌥ records nothing and shows the hint")
        _ = pump(timeout: 3) { controller.panelModel().detail == nil }  // let the hint expire

        // Chinese mode: Chinese speech continues the sentence, the translate key (a tap of ⌥) translates it.
        type("haode", controller, client)
        _ = space(controller, client)
        let before = controller.composer.draft
        if dictate(chineseAudio, snapshotName: "8-voice") {
            let draft = controller.composer.draft
            check(draft.hasPrefix(before) && draft.wordingKey.contains("不舒服"), "transcript continues the draft: \(draft)")
            check(client.marked == draft, "draft shown inline")
            translate(controller, client)
            if finishConversion(controller, "voice → translation") {
                check(controller.composer.choices.filter { $0.kind == .version }.count == 3, "3 English versions of the spoken sentence")
            }
        }
        _ = enter(controller, client)

        // English mode with ⌥Space as the translate key: English speech makes an English draft;
        // ⌥Space while still holding right ⌥ sends it as soon as it is recognized.
        settings.translateKey = .optionSpace
        controller.applySettings()
        tapShift(controller, client)
        if dictate(englishAudio, sendWhileHolding: true) {
            let draft = controller.composer.draft
            check(controller.composer.isLatinDraft && draft.lowercased().contains("blocker"), "English transcript: \(draft)")
            if finishConversion(controller, "voice + ⌥Space → English polish") {
                check(controller.composer.choices.filter { $0.kind == .version }.allSatisfy { !$0.text.containsHan },
                      "English versions of the spoken sentence")
            }
        }
        _ = enter(controller, client)
        check(client.marked.isEmpty && !controller.composer.isComposing, "Return inserts the highlighted line")
        tapShift(controller, client)
        settings.translateKey = .optionTap
        controller.applySettings()

        // An ⌥ shortcut (a key while right ⌥ is down) is not dictation.
        controller.voiceFile = (chineseAudio, speed: 1)
        optionKey(down: true)
        _ = press(controller, client, "∑", code: 0x0D, flags: .option)
        _ = pump(timeout: 0.5) { false }  // past the arming delay
        check(controller.composer.voice == .off, "an ⌥ shortcut doesn't start a recording")
        optionKey(down: false)
        // A key during dictation cancels it.
        optionKey(down: true)
        _ = pump(timeout: 1) { if case .listening = controller.composer.voice { return true } else { return false } }
        _ = escape(controller, client)
        check(controller.composer.voice == .off && client.marked.isEmpty, "Esc while holding right ⌥ cancels the recording")
        optionKey(down: false)
        controller.voiceFile = nil
        controller.commitComposition(client)
    }

    static func snapshot(_ name: String, in directory: URL, appearance: NSAppearance.Name = .aqua) {
        let view = CandidatePanel.shared.view
        view.appearance = NSAppearance(named: appearance)
        defer { view.appearance = nil }
        let url = directory.appendingPathComponent("\(name).png")
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
            print("  snapshot \(url.path)")
        }
    }

    static func run(snapshotDirectory: URL) -> Int32 {
        _ = NSApplication.shared
        // Voice tests play audio files; the microphone and its permission prompt are never used.
        AllInOneIMEInputController.microphoneAllowed = false
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let className = Bundle.main.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String ?? ""
        check(NSClassFromString(className) == AllInOneIMEInputController.self,
              "Info.plist controller class '\(className)' resolves")

        // Level one: the bundled dictionaries with a throw-away user directory.
        guard let shared = RimeDirectories.shared, FileManager.default.fileExists(atPath: shared.path) else {
            print("✗ Rime data missing from the bundle")
            return 1
        }
        let userDir = snapshotDirectory.appendingPathComponent("rime-user")
        let logDir = snapshotDirectory.appendingPathComponent("rime-log")
        try? FileManager.default.removeItem(at: userDir)
        defer {
            try? FileManager.default.removeItem(at: userDir)
            try? FileManager.default.removeItem(at: logDir)
        }
        let deployStart = Date()
        do {
            try RimeService.shared.start(sharedDataDir: shared, userDataDir: userDir, logDir: logDir)
        } catch {
            print("✗ Rime did not start: \(error)")
            return 1
        }
        check(RimeService.shared.waitUntilReady(timeout: 60),
              String(format: "Rime deployed in %.2fs (librime %@)", Date().timeIntervalSince(deployStart), RimeService.shared.version))

        guard let server = IMKServer(
            name: "com.aipinyin.inputmethod.AIPinyin_SelfTest_Connection",
            bundleIdentifier: Bundle.main.bundleIdentifier)
        else {
            print("✗ IMKServer could not be created (run from inside AllInOneIME.app)")
            return 1
        }
        let client = FakeTextClient()
        guard let controller = AllInOneIMEInputController(server: server, delegate: nil, client: nil) else {
            print("✗ could not create AllInOneIMEInputController")
            return 1
        }
        controller.clientOverride = client
        controller.saveAIMode = { _ in }  // leave the user's setting alone
        // The real config (model, styles, credentials) with the new options pinned to known values;
        // sections below change `settings` and the controller follows (nothing is written to disk).
        settings = (try? Config.load()) ?? .default
        settings.outputLanguage = .english
        settings.defaultInput = .chinese
        settings.englishAI = true
        settings.voiceInput = true
        settings.translateKey = .optionTap  // the default; the translate key section tries the others
        settings.uiLanguage = .chinese  // README images; the interface language section tries English
        controller.loadSettings = { SelfTest.settings }
        controller.composer.aiEnabled = true
        controller.ensureEngine()
        check(controller.composer.engine != nil, "Rime session created")
        let panel = CandidatePanel.shared
        // Invisible and click-through while testing (someone may be using the Mac); snapshots
        // render the view directly, so they are unaffected.
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true

        print("— secure input (password fields)")
        if SecureInput.ownerPID() != nil {
            // Another app (e.g. the lock screen) holds it: that must not stop us from composing here.
            print("  secure input is \(SecureInput.ownerDescription()); checking it doesn't block other apps")
            type("ni", controller, client)
            check(client.marked == "ni" || client.marked == "n i", "composing still works (\(client.marked))")
            _ = escape(controller, client)
        } else {
            _ = EnableSecureEventInput()
            if SecureInput.ownerPID() != getpid() {
                // While the lock screen is up, macOS attributes secure input to loginwindow.
                print("  macOS attributes secure input to \(SecureInput.ownerDescription()), not this process; "
                      + "skipping the owner checks")
            } else {
                check(!press(controller, client, "a", code: 0x00), "letters pass through in the app holding secure input")
                check(client.marked.isEmpty && !controller.composer.isComposing, "nothing is composed")
                _ = DisableSecureEventInput()
                type("ni", controller, client)
                _ = EnableSecureEventInput()
                check(!press(controller, client, "d", code: 0x02), "key passes through when secure input turns on mid-composition")
                check(client.inserted.last == "ni" && client.marked.isEmpty, "pending letters committed as typed")
            }
            _ = DisableSecureEventInput()
        }
        controller.commitComposition(client)  // start the next section from a clean state
        client.inserted.removeAll()

        print("— pass-through when idle")
        check(!press(controller, client, "1", code: 0x12), "digit passes through")
        check(!press(controller, client, "c", code: 0x08, flags: .command), "⌘C passes through")
        check(!enter(controller, client), "Enter passes through")
        check(press(controller, client, ",", code: 0x2B) && client.inserted.last == "，", "',' types a Chinese comma")

        print("— level one: local pinyin")
        type("nihao", controller, client)
        let state = controller.composer.engineState
        check(state.candidates.first?.text == "你好", "first candidate for 'nihao' is 你好 (\(state.candidates.prefix(5).map(\.text)))")
        check(client.marked.replacingOccurrences(of: " ", with: "") == "nihao", "pinyin is marked inline (\(client.marked))")
        check(panel.isVisible, "candidate panel is visible")
        snapshot("1-pinyin", in: snapshotDirectory)
        check(escape(controller, client) && client.marked.isEmpty && !controller.composer.isComposing, "Esc cancels the pinyin")

        type("rq", controller, client)
        let year = String(Calendar(identifier: .gregorian).component(.year, from: Date()))
        let dates = controller.composer.engineState.candidates.map(\.text)
        check(dates.contains { $0.contains(year) }, "Lua plugin works: 'rq' offers today's date (\(dates.prefix(3)))")
        _ = escape(controller, client)

        type("nihao", controller, client)
        _ = space(controller, client)
        check(client.marked == "你好" && controller.composer.draft == "你好", "Space confirms 你好 into the draft (not inserted yet)")
        check(controller.panelModel().status == draftHint(controller, input: .chinese),
              "the hint names the translate key (\(controller.panelModel().status))")
        snapshot("2-draft-hint", in: snapshotDirectory)
        check(enter(controller, client) && client.inserted.last == "你好" && client.marked.isEmpty, "Enter inserts the Chinese draft")

        print("— AI off: plain pinyin")
        check(press(controller, client, " ", code: VirtualKey.space, flags: .shift) && !controller.composer.aiEnabled,
              "⇧Space turns AI off")
        type("nihao", controller, client)
        _ = space(controller, client)
        check(client.inserted.last == "你好" && client.marked.isEmpty, "Space inserts 你好 directly")
        _ = press(controller, client, " ", code: VirtualKey.space, flags: .shift)
        check(controller.composer.aiEnabled, "⇧Space turns AI back on")

        print("— Shift switches Chinese / English")
        tapShift(controller, client)
        check(controller.composer.engineState.isAsciiMode, "Shift alone switches to English")
        controller.composer.englishAI = false
        check(!press(controller, client, "a", code: 0x00), "without English AI, letters go straight to the app")
        controller.composer.englishAI = true
        type("ok", controller, client)
        check(client.marked == "ok" && controller.composer.isLatinDraft, "with English AI, letters start an English draft")
        check(!enter(controller, client) && client.inserted.last == "ok" && client.marked.isEmpty,
              "Return inserts the English as typed and still reaches the app")
        type("hi", controller, client)
        check(!press(controller, client, "a", code: 0x00, flags: .command) && client.inserted.last == "hi",
              "⌘A inserts the English draft first, then reaches the app")
        tapShift(controller, client)
        check(!controller.composer.engineState.isAsciiMode, "Shift alone switches back to Chinese")

        print("— no AI while secure input is on")
        controller.secureInputActive = { true }
        type("nihao", controller, client)
        translate(controller, client)
        if case let .failed(message) = controller.composer.phase {
            check(message.contains("安全输入"), "translation refused without a request: \(message)")
        } else {
            check(false, "expected the translation to be refused, got \(controller.composer.phase)")
        }
        _ = enter(controller, client)
        check(client.inserted.last == "你好", "Enter still inserts the Chinese")
        // The rest exercises the normal state (the real flag may be on now, e.g. while the screen is locked).
        controller.secureInputActive = { false }
        _ = pump(timeout: 3) { controller.panelModel().detail == nil }  // the 中/英 notice, not in the README images

        print("— level two: translate + polish (live Bedrock)")
        type("wojintianyoudianbushufu", controller, client)
        let sentence = controller.composer.engineState.candidates.first?.text ?? ""
        check(sentence == "我今天有点不舒服", "whole-sentence candidate (\(sentence))")
        snapshot("1b-sentence-pinyin", in: snapshotDirectory)
        _ = space(controller, client)
        check(controller.composer.draft == sentence, "Space confirms the sentence")
        snapshot("2b-sentence-draft", in: snapshotDirectory)
        let started = Date()
        check(translate(controller, client), "the translate key starts the translation")
        check(panel.isVisible && client.marked == sentence, "panel visible, Chinese stays marked")
        var streamingSnapshotTaken = false
        let finished = pump(timeout: 20) {
            if !streamingSnapshotTaken, case .translating = controller.composer.phase,
               controller.composer.choices.count >= 2 {
                streamingSnapshotTaken = true
                print(String(format: "  first rows after %.2fs", Date().timeIntervalSince(started)))
                snapshot("3-streaming", in: snapshotDirectory)
            }
            if case .translating = controller.composer.phase { return false }
            return true
        }
        check(finished, String(format: "translation finished in %.2fs", Date().timeIntervalSince(started)))
        if case let .failed(message) = controller.composer.phase {
            check(false, "translation failed: \(message)")
            return 1
        }
        let choices = controller.composer.choices
        for choice in choices { print("  \(choice.label) \(choice.text)") }
        check(choices.filter { $0.kind == .version && !$0.text.isEmpty }.count == 3, "3 English versions")
        check(choices.first?.kind == .original && choices.first?.text == sentence, "row 0 is the sentence as typed")
        // Rewrite rows are only shown when their wording differs from the original (and from each other).
        let rewrites = choices.filter { $0.kind.isRewrite }
        check(!rewrites.isEmpty && rewrites.allSatisfy { $0.text.wordingKey != sentence.wordingKey },
              "Chinese rewrites really reword the sentence (\(rewrites.map { "\($0.label) \($0.kind) \($0.text)" }))")
        check(controller.composer.highlighted == 1, "first English version highlighted")
        snapshot("4-final-light", in: snapshotDirectory)
        snapshot("4-final-dark", in: snapshotDirectory, appearance: .darkAqua)
        let second = choices.count > 2 ? choices[2].text : ""
        check(press(controller, client, "2", code: 0x13), "digit 2 consumed")
        check(client.inserted.last == second && !second.isEmpty, "digit 2 commits '\(second)'")
        check(client.marked.isEmpty && !panel.isVisible, "marked text cleared and panel hidden")

        print("— cache hit + Space commits")
        type("wojintianyoudianbushufu", controller, client)
        check(translate(controller, client) && controller.composer.draft == sentence,
              "the translate key right on the pinyin converts it and sends it")
        _ = pump(timeout: 2) { controller.composer.phase == .choosing }
        check(controller.composer.phase == .choosing, "same sentence answered from cache")
        _ = space(controller, client)
        check(client.inserted.last == choices[1].text, "Space commits the highlighted English")

        print("— typing more in level two continues the sentence")
        type("nihao", controller, client)
        _ = space(controller, client)
        translate(controller, client)  // translation starts
        type("ma", controller, client)  // keep typing instead of choosing
        check(controller.composer.phase == .drafting && client.marked.hasPrefix("你好"), "back to the draft (\(client.marked))")
        _ = space(controller, client)
        check(controller.composer.draft == "你好吗", "sentence is now 你好吗 (\(controller.composer.draft))")
        _ = enter(controller, client)
        check(client.inserted.last == "你好吗", "Enter inserts it")

        // The cached sentence again, so these need no requests.
        print("— translate key setting: a tap of ⌥, ⌥Space, Space")
        type("nihao", controller, client)
        _ = space(controller, client)
        _ = space(controller, client)
        check(controller.composer.draft == "你好 " && !controller.composer.isLevelTwo,
              "with 单按 ⌥, Space in a draft types a space ('\(controller.composer.draft)')")
        check(!controller.composer.spaceTranslates, "and never sends it")
        _ = escape(controller, client)
        settings.translateKey = .optionSpace
        controller.applySettings()
        type("wojintianyoudianbushufu", controller, client)
        _ = optionSpace(controller, client)
        _ = pump(timeout: 2) { controller.composer.phase == .choosing }
        check(controller.composer.phase == .choosing && controller.composer.draft == sentence,
              "⌥空格: converts the pinyin and sends it")
        check(optionSpace(controller, client) && client.inserted.last == choices[1].text,
              "⌥空格 again inserts the highlighted line")
        settings.translateKey = .space
        controller.applySettings()
        type("wojintianyoudianbushufu", controller, client)
        _ = space(controller, client)
        check(controller.composer.spaceTranslates && controller.panelModel().status == draftHint(controller, input: .chinese),
              "空格: the hint says Space (\(controller.panelModel().status))")
        _ = space(controller, client)
        _ = pump(timeout: 2) { controller.composer.phase == .choosing }
        check(controller.composer.phase == .choosing, "空格: the second Space sends it")
        check(press(controller, client, "0", code: 0x1D) && client.inserted.last == sentence, "0 inserts the original")
        settings.translateKey = .optionTap
        controller.applySettings()
        check(controller.composer.translateKey == .optionTap, "back to 单按 ⌥")

        // The cached sentence once more, with the interface in English (an English system, or 界面语言 English).
        print("— interface language: English")
        settings.uiLanguage = .english
        controller.applySettings()
        type("wojintianyoudianbushufu", controller, client)
        check(controller.panelModel().footer == "Space picks · Tap ⌥ to translate",
              "English footer while typing: \(controller.panelModel().footer)")
        _ = space(controller, client)
        check(controller.panelModel().status == draftHint(controller, input: .chinese)
              && controller.panelModel().footer == "⏎ insert as typed · ⌫ delete · Esc clear",
              "English hint under the draft: \(controller.panelModel().status)")
        tapOption(controller, client)
        _ = pump(timeout: 2) { controller.composer.phase == .choosing }
        let english = controller.panelModel()
        let styleNames = english.rows.dropFirst().map { $0.comment.components(separatedBy: " · ")[0] }
        check(english.footer == "Space / ⏎ insert · digits pick · 0 original · Esc back"
              && english.rows.first?.comment == "original" && !styleNames.joined().containsHan,
              "English results panel: \(english.footer) | \(english.rows.map(\.comment))")
        snapshot("9-english-ui", in: snapshotDirectory)
        _ = escape(controller, client)
        _ = escape(controller, client)
        tapShift(controller, client)
        check(controller.panelModel().detail == "English", "English mode notice: \(controller.panelModel().detail ?? "none")")
        tapShift(controller, client)
        let englishMenu = controller.menu()?.items.map(\.title) ?? []
        check(englishMenu.first == "Settings…" && englishMenu.contains { $0.hasPrefix("Model: ") },
              "English input menu (\(englishMenu.prefix(3)))")
        settings.uiLanguage = .chinese
        controller.applySettings()
        check(controller.composer.messages == .chinese && UIText.chinese, "back to Chinese")
        _ = pump(timeout: 3) { controller.panelModel().detail == nil }  // let the 中 notice expire

        testSelection(controller, client, snapshotDirectory: snapshotDirectory)
        testEnglishAndOutput(controller, client, snapshotDirectory: snapshotDirectory)
        testVoice(controller, client, snapshotDirectory: snapshotDirectory)
        controller.loadSettings = { SelfTest.settings }
        controller.converter = sharedConverter

        print("— error display")
        controller.converter = Converter(loadConfig: {
            var config = try Config.load()
            config.modelId = "allinoneime.invalid-model-for-selftest"
            return config
        })
        type("ceshi", controller, client)
        _ = space(controller, client)
        translate(controller, client)
        _ = pump(timeout: 15) { if case .failed = controller.composer.phase { return true } else { return false } }
        if case let .failed(message) = controller.composer.phase {
            check(true, "error shown: \(message)")
            snapshot("5-error", in: snapshotDirectory)
        } else {
            check(false, "expected an error, got \(controller.composer.phase)")
        }
        _ = escape(controller, client)
        check(controller.composer.phase == .drafting && client.marked == "测试", "Esc returns to the draft")
        controller.commitComposition(client)
        check(client.inserted.last == "测试" && controller.composer.phase == .idle, "commitComposition inserts the draft")

        type("nihao", controller, client)
        controller.commitComposition(client)
        check(client.inserted.last == "你好", "commitComposition converts pending pinyin")

        let menu = controller.menu()
        let menuTitles = menu?.items.map(\.title) ?? []
        check(menuTitles.contains { $0.hasPrefix("模型：") } && menuTitles.contains { $0.hasPrefix("AI 翻译") },
              "menu shows the AI switch and the model")
        let styleItems = menu?.items.filter { $0.action == #selector(AllInOneIMEInputController.toggleStyle(_:)) } ?? []
        let configured = Set(RewriteStyle.resolve((try? Config.load())?.rewriteStyles ?? []).map(\.name))
        check(styleItems.compactMap { $0.representedObject as? String } == RewriteStyle.catalog.map(\.name)
              && styleItems.allSatisfy { ($0.state == .on) == configured.contains($0.representedObject as? String ?? "") },
              "menu lists the presets, checked per config (\(styleItems.map { "\($0.state == .on ? "✓" : "·")\($0.representedObject ?? "")" }.joined(separator: " ")))")
        // The toggle logic and IMK's info-dictionary form of the sender (no config is written here).
        check(AllInOneIMEInputController.toggled("口语", in: ["正式", "润色"]) == ["润色", "正式", "口语"]
              && AllInOneIMEInputController.toggled("润色", in: ["正式", "润色"]) == ["正式"],
              "style toggle adds in catalog order and removes in place")
        if let item = styleItems.first {
            let info: NSDictionary = [kIMKCommandMenuItemName as Any: item]
            check(AllInOneIMEInputController.menuItem(from: info) === item, "menu action finds its item in IMK's info dictionary")
        }
        check(menu?.items.first?.action == #selector(AllInOneIMEInputController.showPreferences(_:)),
              "menu starts with 设置… (IMK showPreferences:)")
        let outputItems = menu?.items.filter { $0.action == #selector(AllInOneIMEInputController.setOutputLanguage(_:)) } ?? []
        let configuredOutput = ((try? Config.load()) ?? .default).outputLanguage
        check(outputItems.count == 2 && outputItems.filter { $0.state == .on }.compactMap { $0.representedObject as? String }
              == [configuredOutput.rawValue], "menu offers the output language, checked per config")
        testSettingsWindow(snapshotDirectory: snapshotDirectory)
        controller.deactivateServer(client)

        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
