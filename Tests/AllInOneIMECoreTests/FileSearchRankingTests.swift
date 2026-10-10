import Foundation
import Testing
@testable import AllInOneIMECore

struct FileSearchRankingTests {
    typealias Found = FileSearchRanking.Found

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func search(_ query: String, limit: Int = 8, history: OpenHistory = OpenHistory(),
                names: [Found], contents: [Found] = []) -> [(path: String, matchedContent: Bool)] {
        FileSearchRanking.search(query, limit: limit, history: history, isCandidate: { !$0.contains("/Library/") },
                                 byName: { _ in names }, byContent: { _ in contents })
    }

    @Test func keywordsAreSplitAtAnySpace() {
        #expect(FileSearchRanking.keywords(in: "aipinyin readme") == ["aipinyin", "readme"])
        #expect(FileSearchRanking.keywords(in: "  周报　2026  ") == ["周报", "2026"])  // full-width space, extra spaces
        #expect(FileSearchRanking.keywords(in: "a \t b\u{00A0}c") == ["a", "b", "c"])
        #expect(FileSearchRanking.keywords(in: "周报2026") == ["周报2026"])
        #expect(FileSearchRanking.keywords(in: " 　 ").isEmpty)
    }

    @Test func nameSearchesAreTheLongestKeywordsEachOnce() {
        #expect(FileSearchRanking.nameSearches(["aipinyin", "readme"]) == ["aipinyin", "readme"])
        #expect(FileSearchRanking.nameSearches(["周报", "2026"]) == ["2026", "周报"])
        #expect(FileSearchRanking.nameSearches(["a", "doc", "readme", "aipinyin", "md"]) == ["aipinyin", "readme", "doc"])
        #expect(FileSearchRanking.nameSearches(["ab", "cd", "ef", "gh"]) == ["ab", "cd", "ef"])  // same length: as typed
        #expect(FileSearchRanking.nameSearches(["README", "readme", "Résumé", "resume"]) == ["README", "Résumé"])
        #expect(FileSearchRanking.nameSearches(["-v", "notes"]) == ["notes"])  // mdfind would take "-v" for an option
    }

    @Test func contentQueryNeedsTwoCharacters() {
        #expect(FileSearchRanking.contentQuery("a") == nil)
        #expect(FileSearchRanking.contentQuery(" a ") == nil)
        #expect(FileSearchRanking.contentQuery("周报") == "周报")
        #expect(FileSearchRanking.contentQuery("周报　2026 ") == "周报 2026")
        #expect(FileSearchRanking.contentQuery("-live notes") == nil)
    }

    @Test func everyKeywordInThePathOneInTheName() {
        let keywords = ["aipinyin", "readme"]
        #expect(FileSearchRanking.matches("/Users/me/workspace/AIPinyin/README.md", keywords: keywords))
        #expect(FileSearchRanking.matches("/Users/me/aipinyin-readme.txt", keywords: keywords))
        #expect(!FileSearchRanking.matches("/Users/me/workspace/AIPinyin/notes.md", keywords: keywords))  // no "readme"
        #expect(!FileSearchRanking.matches("/Users/me/aipinyin-readme/notes.md", keywords: keywords))  // neither in the name
        #expect(FileSearchRanking.matches("/Users/me/Documents/2026/周报-第3周.docx", keywords: ["周报", "2026"]))
        #expect(!FileSearchRanking.matches("/Users/me/Documents/周报.docx", keywords: ["周报", "2026"]))
        #expect(FileSearchRanking.matches("/Users/me/Jobs/Résumé Final.PDF", keywords: ["resume", "JOBS"]))  // case, accents
        #expect(!FileSearchRanking.matches("/Users/me/x.txt", keywords: []))
    }

    @Test func parsesLastUsedLines() {
        // No line break at the end: mdfind was stopped in the middle of the last line.
        let output = """
            /Users/me/My Files/report 2026.pdf   kMDItemLastUsedDate = 2026-10-09 22:51:04 +0000
            /System/Applications/Calculator.app   kMDItemLastUsedDate = (null)
            /Users/me/odd   kMDItemLastUsedDate = name.txt   kMDItemLastUsedDate = 2026-01-02 03:04:05 +0000
            /Users/me/no attribute.txt
            /Users/me/cut off   kMDItemLastUs
            """
        #expect(FileSearchRanking.parseLastUsed(output) == [
            Found(path: "/Users/me/My Files/report 2026.pdf", lastUsed: date("2026-10-09T22:51:04Z")),
            Found(path: "/System/Applications/Calculator.app"),
            Found(path: "/Users/me/odd   kMDItemLastUsedDate = name.txt", lastUsed: date("2026-01-02T03:04:05Z")),
            Found(path: "/Users/me/no attribute.txt"),
        ])
        #expect(FileSearchRanking.parseLastUsed(output + "\n").count == 5)
        #expect(FileSearchRanking.parseLastUsed("").isEmpty)
        #expect(FileSearchRanking.parseLastUsed("\n\n").isEmpty)
    }

    @Test func openedThroughOpenThenAppsThenLastUsed() {
        var history = OpenHistory()
        history.record("/Users/me/Archive/notes-old.txt", at: date("2026-01-01T00:00:00Z"))
        history.record("/Users/me/Archive/my notes.md", at: date("2026-02-01T00:00:00Z"))
        let files = [
            Found(path: "/Users/me/Documents/notes.txt"),
            Found(path: "/Users/me/old-notes.txt", lastUsed: date("2026-03-01T00:00:00Z")),
            Found(path: "/Users/me/notes-2026.txt", lastUsed: date("2026-09-01T00:00:00Z")),
            Found(path: "/Applications/Notes.app"),
            Found(path: "/Applications/Sticky Notes.app", lastUsed: date("2026-05-01T00:00:00Z")),
            Found(path: "/Users/me/Archive/notes-old.txt"),
            Found(path: "/Users/me/Archive/my notes.md", lastUsed: date("2025-01-01T00:00:00Z")),
        ]
        #expect(FileSearchRanking.rank(files, keywords: ["notes"], history: history).map(\.path) == [
            "/Users/me/Archive/my notes.md",  // opened through @open last
            "/Users/me/Archive/notes-old.txt",
            "/Applications/Sticky Notes.app",  // apps: the one used more recently first
            "/Applications/Notes.app",
            "/Users/me/notes-2026.txt",  // then by last use, newer first
            "/Users/me/old-notes.txt",
            "/Users/me/Documents/notes.txt",  // never used
        ])
        // Without the history the two opened files are ordinary ones (one used in 2025, one never).
        #expect(FileSearchRanking.rank(files, keywords: ["notes"], history: OpenHistory()).map(\.path).suffix(3) == [
            "/Users/me/Archive/my notes.md", "/Users/me/Documents/notes.txt", "/Users/me/Archive/notes-old.txt",
        ])
    }

    @Test func tiesFallBackToTheNameAndThenKeepTheirOrder() {
        let used = date("2026-10-01T12:00:00Z")
        let files = [
            Found(path: "/Users/me/my-notes.txt", lastUsed: used),
            Found(path: "/Users/me/a/b/notes.txt", lastUsed: used),
            Found(path: "/Users/me/notes-long-name.txt", lastUsed: used),
            Found(path: "/Users/me/notes.txt", lastUsed: used),
            Found(path: "/Users/me/notes.txt", lastUsed: used),  // found twice: listed once
        ]
        #expect(FileSearchRanking.rank(files, keywords: ["Notes"], history: OpenHistory()).map(\.path) == [
            "/Users/me/notes.txt",  // starts with the keyword, shallow, short
            "/Users/me/notes-long-name.txt",
            "/Users/me/a/b/notes.txt",  // deeper
            "/Users/me/my-notes.txt",  // only contains it
        ])
        let x = Found(path: "/Users/me/x/notes.txt"), y = Found(path: "/Users/me/y/notes.txt")
        #expect(FileSearchRanking.rank([x, y], keywords: ["notes"], history: OpenHistory()) == [x, y])
        #expect(FileSearchRanking.rank([y, x], keywords: ["notes"], history: OpenHistory()) == [y, x])
        // More of the keywords in the name first.
        let both = Found(path: "/Users/me/AIPinyin-README.txt"), one = Found(path: "/Users/me/workspace/AIPinyin/README.md")
        #expect(FileSearchRanking.rank([one, both], keywords: ["aipinyin", "readme"], history: OpenHistory()) == [both, one])
    }

    @Test func severalKeywordsSearchEachNameAndKeepWhatHasThemAll() {
        var searched: [[String]] = []
        let found = FileSearchRanking.search(
            "aipinyin  readme", limit: 8, history: OpenHistory(), isCandidate: { !$0.contains("/Library/") },
            byName: { keywords in
                searched.append(keywords)
                return [
                    Found(path: "/Users/me/other/README.md"),  // no "aipinyin"
                    Found(path: "/Users/me/workspace/AIPinyin/README.md"),
                    Found(path: "/Users/me/workspace/AIPinyin/Package.swift"),  // no "readme"
                    Found(path: "/Users/me/Library/AIPinyin/README.md"),  // not a candidate
                    Found(path: "/Users/me/workspace/AIPinyin/README.md"),  // found by both searches
                ]
            },
            byContent: { _ in [] })
        #expect(searched == [["aipinyin", "readme"]])
        #expect(found.map(\.path) == ["/Users/me/workspace/AIPinyin/README.md"])
        // One keyword: what Spotlight found by name is kept as it is (as before).
        #expect(search("计算器", names: [Found(path: "/System/Applications/Calculator.app")]).map(\.path)
            == ["/System/Applications/Calculator.app"])
    }

    @Test func contentMatchesComeAfterTheNamesMarkedAndWithoutDuplicates() {
        var history = OpenHistory()
        history.record("/Users/me/notes/setup.md", at: date("2026-10-09T00:00:00Z"))
        var asked: [String] = []
        let found = FileSearchRanking.search(
            "周报　2026", limit: 8, history: history, isCandidate: { !$0.contains("/Library/") },
            byName: { _ in [Found(path: "/Users/me/2026/周报.docx")] },
            byContent: { text in
                asked.append(text)
                return [
                    Found(path: "/Users/me/2026/周报.docx"),  // already listed by name
                    Found(path: "/Users/me/notes/old.md"),
                    Found(path: "/Users/me/notes/recent.md", lastUsed: date("2026-10-01T00:00:00Z")),
                    Found(path: "/Users/me/notes/setup.md"),  // opened through @open: first of the content matches
                    Found(path: "/Users/me/Library/Mail/x.emlx"),  // not a candidate
                    Found(path: "/Users/me/notes/old.md"),
                ]
            })
        #expect(asked == ["周报 2026"])
        #expect(found.map(\.path) == ["/Users/me/2026/周报.docx", "/Users/me/notes/setup.md", "/Users/me/notes/recent.md",
                                      "/Users/me/notes/old.md"])
        #expect(found.map(\.matchedContent) == [false, true, true, true])
    }

    @Test func contentIsSearchedOnlyWhenNamesAreFewAndTheQueryIsLongEnough() {
        var asked = 0
        let many = (1...10).map { Found(path: "/Users/me/notes \($0).txt") }
        let enough = FileSearchRanking.search("notes", limit: 8, history: OpenHistory(), isCandidate: { _ in true },
                                              byName: { _ in many }, byContent: { _ in asked += 1; return [] })
        #expect(enough.count == 8 && asked == 0)
        let short = FileSearchRanking.search("n", limit: 8, history: OpenHistory(), isCandidate: { _ in true },
                                             byName: { _ in [Found(path: "/Users/me/n.txt")] },
                                             byContent: { _ in asked += 1; return many })
        #expect(short.map(\.path) == ["/Users/me/n.txt"] && asked == 0)
        // Both together stay within the limit.
        let topped = search("notes", limit: 3, names: [many[0]], contents: Array(many[1...]))
        #expect(topped.map(\.path) == ["/Users/me/notes 1.txt", "/Users/me/notes 2.txt", "/Users/me/notes 3.txt"])
        #expect(topped.map(\.matchedContent) == [false, true, true])
        // Nothing to search by name (only an option-like word): the content isn't searched either.
        #expect(FileSearchRanking.search("-v", limit: 8, history: OpenHistory(), isCandidate: { _ in true },
                                         byName: { _ in asked += 1; return many }, byContent: { _ in asked += 1; return many })
            .isEmpty && asked == 0)
    }

    @Test func historyKeepsTheLatestOpenOfEachPath() throws {
        var history = OpenHistory()
        history.record("/a", at: date("2026-01-01T00:00:00Z"))
        history.record("/b", at: date("2026-01-02T00:00:00Z"))
        history.record("/a", at: date("2026-01-03T00:00:00Z"))
        #expect(history.entries == [OpenHistory.Entry(path: "/a", date: date("2026-01-03T00:00:00Z")),
                                    OpenHistory.Entry(path: "/b", date: date("2026-01-02T00:00:00Z"))])
        let start = date("2026-02-01T00:00:00Z")
        for i in 0..<250 { history.record("/f\(i)", at: start.addingTimeInterval(Double(i))) }
        #expect(history.entries.count == OpenHistory.limit && OpenHistory.limit == 200)
        #expect(history.entries.first?.path == "/f249" && history.entries.last?.path == "/f50")
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(OpenHistory.self, from: data) == history)
    }
}
