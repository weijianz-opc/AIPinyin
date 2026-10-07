import AIPinyinCore
import Foundation
import Testing
@testable import AIPinyinRime

/// Uses the real librime and the rime-ice data prepared by `make deps` (ThirdParty/rime-data).
enum RimeFixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sharedData = root.appendingPathComponent("ThirdParty/rime-data")
    static let userData = FileManager.default.temporaryDirectory.appendingPathComponent("aipinyin-rime-tests")

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
        let composer = Composer(engine: try RimeFixture.session(), aiEnabled: true)
        for ch in "wojintianyoudianbushufu" { _ = composer.handleKeyDown(key(ch)) }
        #expect(composer.markedText.hasSuffix("fu"))
        let confirm = composer.handleKeyDown(space)
        #expect(confirm.handled)
        #expect(!confirm.effects.contains { if case .commit = $0 { return true } else { return false } })
        #expect(composer.draft == "我今天有点不舒服")
        #expect(composer.phase == .drafting)

        _ = composer.handleKeyDown(key(","))
        #expect(composer.draft == "我今天有点不舒服，")
        for ch in "xiangqingjia" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(space)
        #expect(composer.draft == "我今天有点不舒服，想请假")

        let translate = composer.handleKeyDown(space)
        #expect(translate.effects.first == .startConversion(input: "我今天有点不舒服，想请假", id: 1))
        #expect(composer.phase == .translating(id: 1))
    }

    @Test func composerWithAIOffCommitsDirectly() throws {
        let composer = Composer(engine: try RimeFixture.session(), aiEnabled: false)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        let r = composer.handleKeyDown(space)
        #expect(r.effects.contains(.commit("你好")))
        #expect(composer.phase == .idle)
    }

    /// rime-ice rejects keys carrying the Caps Lock mask; turning Caps Lock on mid-word must not freeze it.
    @Test func capsLockMidCompositionKeepsEditing() throws {
        let composer = Composer(engine: try RimeFixture.session(), aiEnabled: true)
        for ch in "nihao" { _ = composer.handleKeyDown(key(ch)) }
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.delete, characters: "\u{7F}", modifiers: .capsLock))
        #expect(composer.markedText.replacingOccurrences(of: " ", with: "") == "niha")
        _ = composer.handleKeyDown(KeyEvent(keyCode: 0x1F, characters: "O", charactersIgnoringModifiers: "o", modifiers: .capsLock))
        #expect(composer.markedText.replacingOccurrences(of: " ", with: "") == "nihao")
        _ = composer.handleKeyDown(KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: .capsLock))
        #expect(composer.draft == "你好")
    }

    /// A Shift tap after picking part of the input keeps the picked word (librime's commit_code).
    @Test func shiftTapKeepsPickedWords() throws {
        let composer = Composer(engine: try RimeFixture.session(), aiEnabled: true)
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
        _ = composer.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 1.1)
        #expect(composer.draft == "你好ma")
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
