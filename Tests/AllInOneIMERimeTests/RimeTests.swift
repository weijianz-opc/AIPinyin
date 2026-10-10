import AllInOneIMECore
import Foundation
import Testing
@testable import AllInOneIMERime

/// Uses the real librime and the rime-ice data prepared by `make deps` (ThirdParty/rime-data).
enum RimeFixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sharedData = root.appendingPathComponent("ThirdParty/rime-data")
    static let userData = FileManager.default.temporaryDirectory.appendingPathComponent("allinoneime-rime-tests")

    /// Starts librime once per test process; returns the deployment time.
    static let startup: Result<TimeInterval, Error> = {
        do {
            guard FileManager.default.fileExists(atPath: sharedData.appendingPathComponent("build/rime_ice.table.bin").path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: sharedData.path + " (run `make deps`)"])
            }
            try? FileManager.default.removeItem(at: userData)
            let started = Date()
            try RimeService.shared.start(sharedDataDir: sharedData, userDataDir: userData, logDir: nil)
            guard RimeService.shared.waitUntilReady(timeout: 120) else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "deployment timed out"])
            }
            return .success(Date().timeIntervalSince(started))
        } catch {
            return .failure(error)
        }
    }()

    static func session() throws -> RimeSession {
        _ = try startup.get()
        return try #require(RimeService.shared.makeSession())
    }
}

func key(_ char: Character, code: UInt16 = 0, modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(keyCode: code, characters: String(char), modifiers: modifiers)
}

let space = KeyEvent(keyCode: VirtualKey.space, characters: " ")
let enter = KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r")

/// "@i" and Tab: an @improve draft ("@improve "), whose sentence the action key then sends.
func startImprove(_ composer: Composer) {
    _ = composer.handleKeyDown(KeyEvent(keyCode: 0x13, characters: "@", modifiers: .shift))
    _ = composer.handleKeyDown(key("i"))
    _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.tab, characters: "\t"))
}

/// Sends text through the same keysym mapping the input method uses.
func type(_ text: String, into session: RimeSession) {
    for ch in text {
        let event = ch == " " ? space : key(ch)
        let mapped = RimeKey.map(event)!
        _ = session.processKey(mapped.keycode, mask: mapped.mask)
    }
}

@Suite(.serialized)
struct RimeEngineTests {
    @Test func deploysQuicklyFromPrebuiltData() throws {
        let seconds = try RimeFixture.startup.get()
        print("rime deployment took \(String(format: "%.2f", seconds))s")
        #expect(seconds < 30)
        #expect(RimeService.shared.currentSchemaName() == "rime_ice")
    }

    @Test func convertsAWord() throws {
        let s = try RimeFixture.session()
        type("nihao", into: s)
        let snap = s.snapshot()
        #expect(snap.isComposing)
        #expect(snap.candidates.first?.text == "你好")
        #expect(snap.candidates.first?.label == "1")
        #expect(s.rawInput == "nihao")
        _ = s.processKey(RimeKey.space, mask: 0)
        #expect(s.takeCommit() == "你好")
        #expect(!s.snapshot().isComposing)
    }

    @Test func convertsAWholeSentence() throws {
        let s = try RimeFixture.session()
        type("wojintianyoudianbushufu", into: s)
        let texts = s.snapshot().candidates.map(\.text)
        #expect(texts.first == "我今天有点不舒服", "candidates: \(texts)")
    }

    @Test func punctuationRawInputAndLatinMode() throws {
        let s = try RimeFixture.session()
        #expect(s.processKey(0x2C, mask: 0))  // ','
        #expect(s.takeCommit() == "，")

        type("hello", into: s)
        _ = s.processKey(RimeKey.returnKey, mask: 0)
        #expect(s.takeCommit() == "hello")

        s.setAsciiMode(true)
        #expect(s.snapshot().isAsciiMode)
        #expect(!s.processKey(0x61, mask: 0))  // 'a' goes to the application
        s.setAsciiMode(false)
        #expect(!s.snapshot().isAsciiMode)
    }

    /// rime-ice's date translator is a Lua script: this proves the bundled plugins load.
    @Test func luaPluginsLoad() throws {
        let s = try RimeFixture.session()
        type("rq", into: s)
        let year = String(Calendar(identifier: .gregorian).component(.year, from: Date()))
        let texts = s.snapshot().candidates.map(\.text)
        #expect(texts.contains { $0.contains(year) }, "candidates: \(texts)")
        s.clearComposition()
    }

    @Test func composerDraftsChineseAndTranslatesOnSecondSpace() throws {
        let composer = Composer(engine: try RimeFixture.session(), actionKey: .space)
        startImprove(composer)
        #expect(composer.draft == "@improve ")
        for ch in "wojintianyoudianbushufu" { _ = composer.handleKeyDown(key(ch)) }
        #expect(composer.markedText.hasSuffix("fu"))
        let confirm = composer.handleKeyDown(space)
        #expect(confirm.handled)
        #expect(!confirm.effects.contains { if case .commit = $0 { return true } else { return false } })
        #expect(composer.draft == "@improve 我今天有点不舒服")
        #expect(composer.phase == .drafting)

        _ = composer.handleKeyDown(key(","))
        #expect(composer.draft == "@improve 我今天有点不舒服，")
        for ch in "xiangqingjia" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(space)
        #expect(composer.draft == "@improve 我今天有点不舒服，想请假")

        let translate = composer.handleKeyDown(space)
        #expect(translate.effects.first == .startConversion(input: "我今天有点不舒服，想请假", id: 1))
        #expect(composer.phase == .translating(id: 1))
    }

    /// ⌥Space with real librime: it converts the pinyin still being typed and sends the sentence;
    /// Space picks words and, once nothing is left to convert, types a space.
    @Test func optionSpaceActsWithTheRealEngine() throws {
        let optionSpace = KeyEvent(keyCode: VirtualKey.space, characters: "\u{A0}", charactersIgnoringModifiers: " ",
                                   modifiers: .option)
        let composer = Composer(engine: try RimeFixture.session(), actionKey: .optionSpace)
        startImprove(composer)
        for ch in "wojintianyoudianbushufu" { _ = composer.handleKeyDown(key(ch)) }
        let r = composer.handleKeyDown(optionSpace)
        #expect(r.handled && r.effects.first == .startConversion(input: "我今天有点不舒服", id: 1))
        #expect(composer.phase == .translating(id: 1) && !composer.engineState.isComposing)
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.escape, characters: "\u{1B}"))  // back to the draft

        for ch in "xiangqingjia" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(space)  // picks the words
        let typed = composer.draft
        #expect(typed.hasPrefix("@improve 我今天有点不舒服") && !composer.engineState.isComposing)
        _ = composer.handleKeyDown(space)  // nothing left to convert: a space
        #expect(composer.draft == typed + " " && composer.phase == .drafting)
        #expect(composer.handleKeyDown(optionSpace).effects.first
                == .startConversion(input: String(typed.dropFirst("@improve ".count)), id: 2))
        composer.engine?.clearComposition()
    }

    /// The defaults with real librime: a regular input method, and ⏎ runs an @ command.
    @Test func regularInputMethodWithAtCommandsWithTheRealEngine() throws {
        let composer = Composer(engine: try RimeFixture.session())
        #expect(composer.actionKey == .enter)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        #expect(composer.handleKeyDown(space).effects.contains(.commit("你好")) && composer.draft.isEmpty)
        _ = composer.handleKeyDown(KeyEvent(keyCode: 0x13, characters: "@", modifiers: .shift))
        _ = composer.handleKeyDown(key("q"))
        _ = composer.handleKeyDown(enter)
        #expect(composer.draft == "@question ")
        for ch in "liangzijisuan" { _ = composer.handleKeyDown(key(ch)) }
        #expect(composer.handleKeyDown(enter).effects.first == .startCommand(.question, input: "量子计算", id: 1))
        composer.engine?.clearComposition()
    }

    /// With real librime: a second "@" inside a command's text brings up the commands that run there,
    /// letters for the symbol, Chinese again after it.
    @Test func commandInsideATextWithTheRealEngine() throws {
        let engine = try RimeFixture.session()
        let composer = Composer(engine: engine)
        composer.commands = Command.catalog([CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])])
        let at = KeyEvent(keyCode: 0x13, characters: "@", modifiers: .shift)
        _ = composer.handleKeyDown(at)
        _ = composer.handleKeyDown(key("q"))
        _ = composer.handleKeyDown(enter)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(space)
        _ = composer.handleKeyDown(at)
        #expect(composer.draft == "@question 你好@")
        #expect(composer.paletteMatches.map(\.name) == ["read", "calc", "py", "js", "search", "stock"])
        for ch in "st" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.tab, characters: "\t"))
        #expect(composer.draft == "@question 你好@stock " && composer.engineState.isAsciiMode)
        for ch in "AAPL" { _ = composer.handleKeyDown(KeyEvent(keyCode: 0, characters: String(ch), modifiers: .shift)) }
        _ = composer.handleKeyDown(space)
        #expect(composer.draft == "@question 你好@stock AAPL " && !composer.engineState.isAsciiMode)
        for ch in "zenmeyang" { _ = composer.handleKeyDown(key(ch)) }
        let effects = composer.handleKeyDown(enter).effects
        guard case let .startPlan(outer, plan, _)? = effects.first else {
            Issue.record("expected a plan: \(effects)")
            return
        }
        #expect(outer == .question && plan.inner.map(\.argument) == ["AAPL"])
        #expect(plan.input(outputs: ["QUOTE"]) == "你好QUOTE 怎么样")
        composer.engine?.clearComposition()
    }

    /// An @improve command with real librime: Return converts the pinyin still being typed and sends
    /// it; ⇧Return keeps the letters as typed.
    @Test func returnActsWithTheRealEngine() throws {
        let composer = Composer(engine: try RimeFixture.session())
        #expect(composer.actionKey == .enter)
        startImprove(composer)
        for ch in "wojintianyoudianbushufu" { _ = composer.handleKeyDown(key(ch)) }
        let r = composer.handleKeyDown(enter)
        #expect(r.handled && r.effects.first == .startConversion(input: "我今天有点不舒服", id: 1))
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.escape, characters: "\u{1B}"))
        let shiftReturn = KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: .shift)
        let asTyped = composer.handleKeyDown(shiftReturn)
        #expect(asTyped.effects.contains(.commit("@improve 我今天有点不舒服")) && composer.phase == .idle)
        startImprove(composer)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(shiftReturn)
        #expect(composer.draft == "@improve nihao")  // librime's Return: the letters as typed
        composer.engine?.clearComposition()
    }

    /// An Option tap with real librime: it converts the pinyin and sends it.
    @Test func optionTapActsWithTheRealEngine() throws {
        let composer = Composer(engine: try RimeFixture.session(), actionKey: .optionTap)
        #expect(composer.actionKey == .optionTap)
        startImprove(composer)
        for ch in "wojintianyoudianbushufu" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [.option, .leftOption], timestamp: 1)
        let tap = composer.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [], timestamp: 1.08)
        #expect(tap.first == .startConversion(input: "我今天有点不舒服", id: 1))
        #expect(composer.phase == .translating(id: 1) && !composer.engineState.isComposing)
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.escape, characters: "\u{1B}"))
        composer.engine?.clearComposition()
    }

    /// ⇧Space with real librime is Space: it picks the candidate, in a command too, and with nothing
    /// pending it is the app's.
    @Test func shiftSpaceIsSpaceWithTheRealEngine() throws {
        let composer = Composer(engine: try RimeFixture.session())
        let shiftSpace = KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: .shift)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        let r = composer.handleKeyDown(shiftSpace)
        #expect(r.handled && r.effects.contains(.commit("你好")) && composer.phase == .idle)
        #expect(composer.handleKeyDown(shiftSpace) == .passThrough)
        startImprove(composer)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(shiftSpace)
        _ = composer.handleKeyDown(shiftSpace)
        #expect(composer.draft == "@improve 你好 " && composer.phase == .drafting)
        composer.engine?.clearComposition()
    }

    /// English mode in real librime: letters, capitals and punctuation collect into an @improve
    /// command, a double Space sends it (`space` action key), ⇧Return inserts it as typed.
    @Test func englishModeDraftsWithTheRealEngine() throws {
        let composer = Composer(engine: try RimeFixture.session(), actionKey: .space)
        composer.setInputMode(.english)
        #expect(composer.engineState.isAsciiMode)
        startImprove(composer)
        for ch in "Hi" {
            _ = composer.handleKeyDown(KeyEvent(keyCode: 0, characters: String(ch),
                                                modifiers: ch.isUppercase ? .shift : []))
        }
        _ = composer.handleKeyDown(key(","))
        _ = composer.handleKeyDown(space)
        for ch in "team" { _ = composer.handleKeyDown(key(ch)) }
        #expect(composer.draft == "@improve Hi, team" && composer.isLatinDraft)
        _ = composer.handleKeyDown(space)
        #expect(composer.handleKeyDown(space).effects.first == .startConversion(input: "Hi, team", id: 1))
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.escape, characters: "\u{1B}"))  // back to the draft
        let r = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: .shift))
        #expect(r.handled && r.effects.contains(.commit("@improve Hi, team ")))
        composer.setInputMode(.chinese)
        #expect(!composer.engineState.isAsciiMode)
    }

    /// rime-ice rejects keys carrying the Caps Lock mask; turning Caps Lock on mid-word must not freeze it.
    @Test func capsLockMidCompositionKeepsEditing() throws {
        let composer = Composer(engine: try RimeFixture.session())
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.delete, characters: "\u{7F}", modifiers: .capsLock))
        #expect(composer.markedText.replacingOccurrences(of: " ", with: "") == "niha")
        _ = composer.handleKeyDown(KeyEvent(keyCode: 0x1F, characters: "O", charactersIgnoringModifiers: "o", modifiers: .capsLock))
        #expect(composer.markedText.replacingOccurrences(of: " ", with: "") == "nihao")
        let r = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: .capsLock))
        #expect(r.effects.contains(.commit("你好")))
    }

    /// A Shift tap after picking part of the input keeps the picked word (librime's commit_code).
    @Test func shiftTapKeepsPickedWords() throws {
        let composer = Composer(engine: try RimeFixture.session())
        for ch in "nihaoma" { _ = composer.handleKeyDown(key(ch)) }
        var picked = false
        for _ in 0..<6 where !picked {
            if let i = composer.engineState.candidates.firstIndex(where: { $0.text == "你好" }) {
                _ = composer.choose(index: i)
                picked = true
            } else {
                _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.pageDown, characters: "\u{F72D}"))
            }
        }
        try #require(picked, "你好 not among the candidates for nihaoma")
        #expect(composer.markedText.hasPrefix("你好"))
        _ = composer.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 1)
        let tap = composer.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 1.1)
        #expect(tap.contains(.commit("你好ma")))
        #expect(composer.engineState.isAsciiMode)
        #expect(!composer.engineState.isComposing)
    }

    /// librime reuses session ids after a redeploy; an old session must never act on a new one.
    @Test func redeployInvalidatesOldSessions() throws {
        var old: RimeSession? = try RimeFixture.session()
        RimeService.shared.redeploy()
        #expect(old?.isValid == false)
        #expect(RimeService.shared.waitUntilReady(timeout: 120))
        let fresh = try #require(RimeService.shared.makeSession())
        #expect(old?.isValid == false)
        old = nil  // its deinit must not destroy `fresh`, even if librime reused the id
        #expect(fresh.isValid)
        type("nihao", into: fresh)
        #expect(fresh.snapshot().candidates.first?.text == "你好")
    }
}
