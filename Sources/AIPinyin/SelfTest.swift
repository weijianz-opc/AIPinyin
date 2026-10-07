import AIPinyinCore
import AIPinyinRime
import AppKit
import Carbon
import InputMethodKit
import SwiftUI

/// Records what the input method does to a text field.
final class FakeTextClient: NSObject, IMKTextInput {
    var marked = ""
    var markedSelection = NSRange(location: 0, length: 0)
    var inserted: [String] = []
    var document = ""
    /// Screen rect of the caret line, used to position the candidate panel.
    var caretRect = NSRect(x: 420, y: 560, width: 1, height: 18)

    private static func plain(_ value: Any?) -> String {
        if let s = value as? NSAttributedString { return s.string }
        return value as? String ?? ""
    }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        let s = Self.plain(string)
        inserted.append(s)
        document += s
        marked = ""
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        marked = Self.plain(string)
        markedSelection = selectionRange
    }

    func selectedRange() -> NSRange { NSRange(location: (document as NSString).length, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: (document as NSString).length, length: (marked as NSString).length)
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
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
    func bundleIdentifier() -> String! { Bundle.main.bundleIdentifier ?? "com.aipinyin.selftest" }
    func windowLevel() -> CGWindowLevel { CGWindowLevelForKey(.normalWindow) }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "aipinyin-selftest" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { caretRect }
}

/// End-to-end check of the input controller without the system text input server.
@MainActor
enum SelfTest {
    static var failures = 0

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
        _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }

    @discardableResult
    static func press(
        _ controller: AIPinyinInputController, _ client: FakeTextClient,
        _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []
    ) -> Bool {
        controller.handle(event(characters, code: code, flags: flags), client: client)
    }

    static func type(_ text: String, _ controller: AIPinyinInputController, _ client: FakeTextClient) {
        for ch in text { press(controller, client, String(ch), code: keyCodes[ch] ?? 0) }
    }

    static func space(_ c: AIPinyinInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, " ", code: VirtualKey.space)
    }

    static func enter(_ c: AIPinyinInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, "\r", code: VirtualKey.returnKey)
    }

    static func escape(_ c: AIPinyinInputController, _ client: FakeTextClient) -> Bool {
        press(c, client, "\u{1B}", code: VirtualKey.escape)
    }

    /// Shift pressed and released on its own.
    static func tapShift(_ c: AIPinyinInputController, _ client: FakeTextClient) {
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
        check(model.credentialStatus.hasPrefix("已找到"), "credentials found: \(model.credentialStatus)")
        let casual = RewriteStyle.named("口语")!
        let wasOn = model.isStyleOn(casual)
        model.setStyle(casual, on: !wasOn)
        let saved = (try? Config.load(from: url))?.rewriteStyles ?? []
        check(saved.contains("口语") == !wasOn, "toggling 口语 saves at once (\(saved))")
        model.setStyle(casual, on: wasOn)

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
        let preview = SettingsModel(configURL: Config.defaultURL, aiEnabled: true, saveAI: { _ in }, persists: false)
        preview.runTest()
        _ = pump(timeout: 20) { preview.testStatus != .running }
        let host = NSHostingView(rootView: SettingsView(model: preview))
        let size = NSSize(width: 560, height: 940)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = pump(timeout: 0.5) { false }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: snapshotDirectory.appendingPathComponent("6-settings.png"))
                print("  snapshot \(snapshotDirectory.path)/6-settings.png (\(Int(size.width))×\(Int(size.height)))")
            }
        }
        window.close()

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
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let className = Bundle.main.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String ?? ""
        check(NSClassFromString(className) == AIPinyinInputController.self,
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
            print("✗ IMKServer could not be created (run from inside AIPinyin.app)")
            return 1
        }
        let client = FakeTextClient()
        guard let controller = AIPinyinInputController(server: server, delegate: nil, client: nil) else {
            print("✗ could not create AIPinyinInputController")
            return 1
        }
        controller.clientOverride = client
        controller.saveAIMode = { _ in }  // leave the user's setting alone
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
        check(!press(controller, client, "a", code: 0x00), "letters go straight to the app in English mode")
        tapShift(controller, client)
        check(!controller.composer.engineState.isAsciiMode, "Shift alone switches back to Chinese")

        print("— no AI while secure input is on")
        controller.secureInputActive = { true }
        type("nihao", controller, client)
        _ = space(controller, client)
        _ = space(controller, client)
        if case let .failed(message) = controller.composer.phase {
            check(message.contains("安全输入"), "translation refused without a request: \(message)")
        } else {
            check(false, "expected the translation to be refused, got \(controller.composer.phase)")
        }
        _ = enter(controller, client)
        check(client.inserted.last == "你好", "Enter still inserts the Chinese")
        // The rest exercises the normal state (the real flag may be on now, e.g. while the screen is locked).
        controller.secureInputActive = { false }

        print("— level two: translate + polish (live Bedrock)")
        type("wojintianyoudianbushufu", controller, client)
        let sentence = controller.composer.engineState.candidates.first?.text ?? ""
        check(sentence == "我今天有点不舒服", "whole-sentence candidate (\(sentence))")
        snapshot("1b-sentence-pinyin", in: snapshotDirectory)
        _ = space(controller, client)
        check(controller.composer.draft == sentence, "Space confirms the sentence")
        snapshot("2b-sentence-draft", in: snapshotDirectory)
        let started = Date()
        check(space(controller, client), "second Space starts the translation")
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
        check(choices.filter { $0.kind == .english && !$0.text.isEmpty }.count == 3, "3 English versions")
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
        _ = space(controller, client)
        _ = space(controller, client)
        _ = pump(timeout: 2) { controller.composer.phase == .choosing }
        check(controller.composer.phase == .choosing, "same sentence answered from cache")
        _ = space(controller, client)
        check(client.inserted.last == choices[1].text, "Space commits the highlighted English")

        print("— typing more in level two continues the sentence")
        type("nihao", controller, client)
        _ = space(controller, client)
        _ = space(controller, client)  // translation starts
        type("ma", controller, client)  // keep typing instead of choosing
        check(controller.composer.phase == .drafting && client.marked.hasPrefix("你好"), "back to the draft (\(client.marked))")
        _ = space(controller, client)
        check(controller.composer.draft == "你好吗", "sentence is now 你好吗 (\(controller.composer.draft))")
        _ = enter(controller, client)
        check(client.inserted.last == "你好吗", "Enter inserts it")

        print("— error display")
        controller.converter = Converter(loadConfig: {
            var config = try Config.load()
            config.modelId = "aipinyin.invalid-model-for-selftest"
            return config
        })
        type("ceshi", controller, client)
        _ = space(controller, client)
        _ = space(controller, client)
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
        let styleItems = menu?.items.filter { $0.action == #selector(AIPinyinInputController.toggleStyle(_:)) } ?? []
        let configured = Set(RewriteStyle.resolve((try? Config.load())?.rewriteStyles ?? []).map(\.name))
        check(styleItems.compactMap { $0.representedObject as? String } == RewriteStyle.catalog.map(\.name)
              && styleItems.allSatisfy { ($0.state == .on) == configured.contains($0.representedObject as? String ?? "") },
              "menu lists the presets, checked per config (\(styleItems.map { "\($0.state == .on ? "✓" : "·")\($0.representedObject ?? "")" }.joined(separator: " ")))")
        // The toggle logic and IMK's info-dictionary form of the sender (no config is written here).
        check(AIPinyinInputController.toggled("口语", in: ["正式", "润色"]) == ["润色", "正式", "口语"]
              && AIPinyinInputController.toggled("润色", in: ["正式", "润色"]) == ["正式"],
              "style toggle adds in catalog order and removes in place")
        if let item = styleItems.first {
            let info: NSDictionary = [kIMKCommandMenuItemName as Any: item]
            check(AIPinyinInputController.menuItem(from: info) === item, "menu action finds its item in IMK's info dictionary")
        }
        check(menu?.items.first?.action == #selector(AIPinyinInputController.showPreferences(_:)),
              "menu starts with 设置… (IMK showPreferences:)")
        testSettingsWindow(snapshotDirectory: snapshotDirectory)
        controller.deactivateServer(client)

        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
