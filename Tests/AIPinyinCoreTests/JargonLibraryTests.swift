import Foundation
import Testing
@testable import AIPinyinCore

struct JargonLibraryTests {
    @Test func parsesTheUsualFormats() {
        let text = """
            # 我们组的黑话
            bandwidth：精力、时间
            circle back: 回头再跟进
              OOO = 请假
            LP\tLeadership Principles
            抓手 - 着力点
            PRFAQ

            BANDWIDTH：重复的词只取第一个
            """
        let entries = JargonLibrary.parse(text)
        #expect(entries == [
            JargonEntry(term: "bandwidth", meaning: "精力、时间"),
            JargonEntry(term: "circle back", meaning: "回头再跟进"),
            JargonEntry(term: "OOO", meaning: "请假"),
            JargonEntry(term: "LP", meaning: "Leadership Principles"),
            JargonEntry(term: "抓手", meaning: "着力点"),
            JargonEntry(term: "PRFAQ", meaning: ""),
        ])
        // The earliest separator wins: a meaning may contain colons.
        #expect(JargonLibrary.parse("Day 1: 永远像创业第一天：保持敏捷") == [JargonEntry(term: "Day 1", meaning: "永远像创业第一天：保持敏捷")])
    }

    @Test func templateHasNoEntriesAndLimitsHold() {
        #expect(JargonLibrary.parse(JargonLibrary.template).isEmpty)  // nothing is built in
        let many = (1...400).map { "term\($0)：意思\($0)" }.joined(separator: "\n")
        #expect(JargonLibrary.parse(many).count == JargonLibrary.maxEntries)
        let long = JargonLibrary.parse(String(repeating: "x", count: 500) + "：" + String(repeating: "y", count: 500))
        #expect(long.first?.term.count == 60 && long.first?.meaning.count == 120)
        let controls = JargonLibrary.parse("bad\u{1B}[2J：意\u{7}思")
        #expect(controls.first?.term == "bad [2J" && controls.first?.meaning == "意 思")
    }

    @Test func loadsFromAFileAndTreatsAMissingFileAsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aipinyin-jargon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("jargon.txt")
        #expect(JargonLibrary.load(from: url).isEmpty)
        try Data("bandwidth：精力\r\n抓手：着力点\r\n".utf8).write(to: url)
        #expect(JargonLibrary.load(from: url).map(\.term) == ["bandwidth", "抓手"])
    }

    @Test func findsTheTermsALineUses() {
        let entries = JargonLibrary.parse("""
            own：负责
            bandwidth：精力、时间
            circle：圈子
            circle back：回头再跟进
            抓手：着力点
            PRFAQ
            """)
        let english = "I'll download it later, my Bandwidth is low; let's circle back. PRFAQ first."
        #expect(JargonLibrary.used(in: english, entries: entries).map(\.term) == ["bandwidth", "circle back"])
        #expect(JargonLibrary.used(in: "这个抓手不够清晰，owner 也没定", entries: entries).map(\.term) == ["抓手"])
        #expect(JargonLibrary.used(in: "nothing here", entries: entries).isEmpty)
        #expect(JargonLibrary.annotation(for: english, entries: entries) == "bandwidth＝精力、时间，circle back＝回头再跟进")
        #expect(JargonLibrary.annotation(for: "plain words", entries: entries) == nil)
        let wordy = [JargonEntry(term: "PRFAQ", meaning: "新功能提案文档，先写新闻稿和常见问题再开发")]
        #expect(JargonLibrary.annotation(for: "Let's write a PRFAQ.", entries: wordy) == "PRFAQ＝新功能提案文档，先写新闻稿…")
    }

    @Test func promptGetsTheListOnlyWithTheJargonStyle() {
        let jargon = [JargonEntry(term: "PRFAQ", meaning: "新功能提案文档"), JargonEntry(term: "LP")]
        var config = Config.default
        config.rewriteStyles = ["简洁", "黑话"]
        let system = Prompt.request(for: "你好", config: config, jargon: jargon).system.first?.text ?? ""
        #expect(system.contains("user's own jargon list") && system.contains("  - PRFAQ (新功能提案文档)\n  - LP"))
        config.rewriteStyles = ["简洁"]
        let without = Prompt.request(for: "你好", config: config, jargon: jargon).system.first?.text ?? ""
        #expect(!without.contains("jargon list") && !without.contains("PRFAQ"))
        config.rewriteStyles = ["黑话"]
        let empty = Prompt.request(for: "你好", config: config, jargon: []).system.first?.text ?? ""
        #expect(!empty.contains("jargon list"))
        // The list stays within its budget.
        let huge = (1...150).map { JargonEntry(term: "term\($0)", meaning: String(repeating: "意", count: 100)) }
        #expect(JargonLibrary.promptList(huge).count <= 4000)
    }

    @Test func configJargonFile() throws {
        #expect(Config.default.jargonFile == nil && Config.default.jargonURL == JargonLibrary.defaultURL)
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"jargonFile": "~/Documents/team.txt"}"#.utf8))
        #expect(c.jargonURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/team.txt").path)
        let blank = try JSONDecoder().decode(Config.self, from: Data(#"{"jargonFile": "  "}"#.utf8))
        #expect(blank.jargonURL == JargonLibrary.defaultURL)
        let encoded = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(encoded.contains("jargonFile"))
    }
}
