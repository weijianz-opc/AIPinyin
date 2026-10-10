import Foundation
import Testing
@testable import AllInOneIMECore

struct FileSearchRankingTests {
    typealias Found = FileSearchRanking.Found

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func search(_ query: String, limit: Int = 8, history: OpenHistory = OpenHistory(), apps: [Found] = [],
                names: [Found], contents: [Found] = []) -> [(path: String, matchedContent: Bool)] {
        FileSearchRanking.search(query, limit: limit, history: history, apps: apps, isCandidate: { !$0.contains("/Library/") },
                                 byName: { _ in names }, byContent: { _ in contents })
    }

    /// Apps as the app index has them: every name each goes by.
    let calculator = Found(path: "/System/Applications/Calculator.app", names: ["Calculator", "计算器", "計算機"])
    let systemSettings = Found(path: "/System/Applications/System Settings.app", names: ["System Settings", "系统设置", "系統設定"])
    let terminal = Found(path: "/System/Applications/Utilities/Terminal.app", names: ["Terminal", "终端", "終端機"])
    let notes = Found(path: "/System/Applications/Notes.app", names: ["Notes", "备忘录", "備忘錄"])
    var apps: [Found] { [calculator, systemSettings, terminal, notes] }

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

    @Test func singleLettersAreSearchedByNameOnlyAlone() {
        // "plan b": "plan" by name, the "b" only checked in what that finds.
        #expect(FileSearchRanking.nameSearches(["plan", "b"]) == ["plan"])
        #expect(FileSearchRanking.nameSearches(["7", "周报", "x"]) == ["周报"])
        #expect(FileSearchRanking.nameSearches(["报", "b"]) == ["报"])  // one Chinese character is a name worth searching
        #expect(FileSearchRanking.nameSearches(["a"]) == ["a"])  // nothing else to search for (⏎)
        #expect(FileSearchRanking.nameSearches(["a", "b"]) == ["a", "b"])
        #expect(FileSearchRanking.nameSearches(["-v", "a"]) == ["a"])
        var searched: [[String]] = []
        let found = FileSearchRanking.search(
            "plan b", limit: 8, history: OpenHistory(), isCandidate: { _ in true },
            byName: { keywords in
                searched.append(keywords)
                return [Found(path: "/Users/me/plan b.txt"), Found(path: "/Users/me/plan.txt"), Found(path: "/Users/me/b/plan.md")]
            },
            byContent: { _ in [] })
        #expect(searched == [["plan"]])
        #expect(found.map(\.path) == ["/Users/me/plan b.txt", "/Users/me/b/plan.md"])  // both keywords somewhere in the path
    }

    @Test func singleLettersAreNotSearchedAsTheyAreTyped() {
        #expect(!FileSearchRanking.searchesAsYouType("a"))
        #expect(!FileSearchRanking.searchesAsYouType(" a "))
        #expect(!FileSearchRanking.searchesAsYouType("a b"))
        #expect(!FileSearchRanking.searchesAsYouType("7"))
        #expect(!FileSearchRanking.searchesAsYouType("　"))
        #expect(FileSearchRanking.searchesAsYouType("ab"))
        #expect(FileSearchRanking.searchesAsYouType("plan b"))
        #expect(FileSearchRanking.searchesAsYouType("报"))
        // Paths are listed as they are typed, however short.
        #expect(FileSearchRanking.searchesAsYouType("/"))
        #expect(FileSearchRanking.searchesAsYouType("~"))
        #expect(FileSearchRanking.searchesAsYouType("~/a"))
    }

    @Test func theContentPredicateIsBuiltNotParsedFromTheText() {
        #expect(FileSearchRanking.contentPredicate(["a"]) == nil)
        #expect(FileSearchRanking.contentPredicate([]) == nil)
        #expect(FileSearchRanking.contentPredicate(["周报"]) == #"kMDItemTextContent == "周报"cdw"#)
        #expect(FileSearchRanking.contentPredicate(["周报", "2026"])
            == #"kMDItemTextContent == "周报"cdw && kMDItemTextContent == "2026"cdw"#)
        // mdfind's own syntax is just text here.
        #expect(FileSearchRanking.contentPredicate(["kind:pdf", "OR", "-live"])
            == #"kMDItemTextContent == "kind:pdf"cdw && kMDItemTextContent == "OR"cdw && kMDItemTextContent == "-live"cdw"#)
        #expect(FileSearchRanking.contentPredicate([#""quoted""#]) == #"kMDItemTextContent == "\"quoted\""cdw"#)
        #expect(FileSearchRanking.contentPredicate([#"a\"#, #"b\" || kMDItemFSName == "x"#])
            == #"kMDItemTextContent == "a\\"cdw && kMDItemTextContent == "b\\\" || kMDItemFSName == \"x"cdw"#)
        #expect(FileSearchRanking.contentPredicate(["rep*", "*"]) == #"kMDItemTextContent == "rep\*"cdw && kMDItemTextContent == "\*"cdw"#)
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

    @Test func anAppsOtherNamesCountLikeItsFileName() {
        func matches(_ app: Found, _ keywords: [String]) -> Bool {
            FileSearchRanking.matches(app.path, names: app.names, keywords: keywords)
        }
        #expect(matches(calculator, ["计算器"]) && matches(calculator, ["計算"]) && matches(calculator, ["CALC"]))
        #expect(matches(systemSettings, ["系统", "设置"]))  // several keywords in one localized name
        #expect(matches(systemSettings, ["system", "设置"]))  // in different names
        #expect(matches(terminal, ["utilities", "终端"]))  // one in the path, one in a name
        #expect(!matches(terminal, ["utilities"]))  // only in the path
        #expect(!matches(systemSettings, ["系统", "日历"]))
        #expect(!matches(notes, ["备忘录", "2026"]))
    }

    @Test func appsAreFoundByEveryNameTheyGoBy() {
        var searchedByName: [[String]] = [], searchedByContent = 0
        func find(_ query: String, spotlight: [Found] = []) -> [String] {
            FileSearchRanking.search(query, limit: 8, history: OpenHistory(), apps: apps, isCandidate: { _ in true },
                                     byName: { searchedByName.append($0); return spotlight },
                                     byContent: { _ in searchedByContent += 1; return [] })
                .map(\.path)
        }
        // Spotlight doesn't know the Chinese names; the index does. An app found: no full-text search.
        #expect(find("计算器") == [calculator.path])
        #expect(find("系统 设置") == [systemSettings.path] && searchedByName.last == ["系统", "设置"])
        #expect(find("system 设置") == [systemSettings.path])
        #expect(find("utilities 终端") == [terminal.path])
        #expect(find("备忘") == [notes.path])
        #expect(searchedByContent == 0)
        // Found by Spotlight too: listed once, with Spotlight's dates; the app first.
        let used = date("2026-10-01T00:00:00Z")
        let byName = [Found(path: "/Users/me/code/calculator.py", modified: date("2026-10-09T00:00:00Z")),
                      Found(path: calculator.path, lastUsed: used)]
        #expect(find("calculator", spotlight: byName) == [calculator.path, "/Users/me/code/calculator.py"])
        let ranked = FileSearchRanking.rank([calculator, Found(path: "/Applications/Calculator Pro.app", lastUsed: date("2026-01-01T00:00:00Z"))],
                                            keywords: ["calculator"], history: OpenHistory())
        #expect(ranked.map(\.path) == ["/Applications/Calculator Pro.app", calculator.path])  // a known use first
        // An app of the index is listed as its names match, whatever Spotlight's name search found it for.
        #expect(find("notes 2026", spotlight: [Found(path: notes.path), Found(path: "/Users/me/notes 2026.txt")])
            == ["/Users/me/notes 2026.txt"])
    }

    @Test func parsesAttributeLines() {
        // No line break at the end: mdfind was stopped in the middle of the last line.
        let output = """
            /Users/me/My Files/report 2026.pdf   kMDItemLastUsedDate = 2026-10-09 22:51:04 +0000   kMDItemContentModificationDate = 2026-10-10 01:02:03 +0000
            /System/Applications/Calculator.app   kMDItemLastUsedDate = (null)   kMDItemContentModificationDate = (null)
            /Users/me/odd   kMDItemLastUsedDate = name.txt   kMDItemLastUsedDate = (null)   kMDItemContentModificationDate = 2026-01-02 03:04:05 +0000
            /Users/me/README.md   kMDItemLastUsedDate = (null)   kMDItemContentModificationDate = 2026-10-09 08:00:00 +0800
            /Users/me/only used.txt   kMDItemLastUsedDate = 2018-03-04 05:06:07 +0000
            /Users/me/no attribute.txt
            /Users/me/cut off   kMDItemLastUsedDate = (null)   kMDItemContentModif
            """
        let found = FileSearchRanking.parse(Data(output.utf8))
        #expect(found == [
            Found(path: "/Users/me/My Files/report 2026.pdf", lastUsed: date("2026-10-09T22:51:04Z"), modified: date("2026-10-10T01:02:03Z")),
            Found(path: "/System/Applications/Calculator.app"),
            Found(path: "/Users/me/odd   kMDItemLastUsedDate = name.txt", modified: date("2026-01-02T03:04:05Z")),
            Found(path: "/Users/me/README.md", modified: date("2026-10-09T00:00:00Z")),
            Found(path: "/Users/me/only used.txt", lastUsed: date("2018-03-04T05:06:07Z")),
            Found(path: "/Users/me/no attribute.txt"),
        ])
        #expect(FileSearchRanking.parse(Data((output + "\n").utf8)).last == Found(path: "/Users/me/cut off"))
        #expect(FileSearchRanking.parse(Data()).isEmpty)
        #expect(FileSearchRanking.parse(Data("\n\n".utf8)).isEmpty)
    }

    @Test func readsDatesAsMdfindPrintsThem() {
        func parsed(_ text: String) -> Date? {
            Array(text.utf8).withUnsafeBufferPointer { FileSearchRanking.date($0) }
        }
        let iso = ISO8601DateFormatter()
        for (text, expected) in [("2024-02-29 12:00:00 +0000", "2024-02-29T12:00:00Z"), ("2000-03-01 00:00:00 +0000", "2000-03-01T00:00:00Z"),
                                 ("1999-12-31 23:59:59 +0000", "1999-12-31T23:59:59Z"), ("1970-01-01 00:00:00 +0000", "1970-01-01T00:00:00Z"),
                                 ("2026-10-10 08:00:00 +0800", "2026-10-10T00:00:00Z"), ("2026-03-08 01:30:00 -0730", "2026-03-08T09:00:00Z"),
                                 ("2100-03-01 00:00:00 +0000", "2100-03-01T00:00:00Z")] {
            #expect(parsed(text) == iso.date(from: expected), "\(text)")
        }
        for text in ["(null)", "2026-1-02 03:04:05 +0000", "2026-13-02 03:04:05 +0000", "2026-10-02T03:04:05 +0000", "2026-10-02 03:04:05 Z0000"] {
            #expect(parsed(text) == nil, "\(text)")
        }
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

    @Test func aRecentChangeCountsLikeARecentUse() {
        // Editors and terminals don't record a use: the README edited yesterday beats a readme last opened in 2018.
        let repo = Found(path: "/Users/me/workspace/AIPinyin/README.md", modified: date("2026-10-09T00:00:00Z"))
        let old = Found(path: "/Users/me/Downloads/readme.txt", lastUsed: date("2018-03-04T00:00:00Z"), modified: date("2018-03-01T00:00:00Z"))
        #expect(FileSearchRanking.rank([old, repo], keywords: ["readme"], history: OpenHistory()) == [repo, old])
        // The later of the two counts.
        let changedLater = Found(path: "/Users/me/b.txt", lastUsed: date("2026-01-01T00:00:00Z"), modified: date("2026-09-01T00:00:00Z"))
        let usedLater = Found(path: "/Users/me/a.txt", lastUsed: date("2026-05-01T00:00:00Z"), modified: date("2026-02-01T00:00:00Z"))
        #expect(FileSearchRanking.rank([usedLater, changedLater], keywords: ["txt"], history: OpenHistory()) == [changedLater, usedLater])
        #expect(changedLater.latest == date("2026-09-01T00:00:00Z") && usedLater.latest == date("2026-05-01T00:00:00Z"))
        #expect(repo.latest == date("2026-10-09T00:00:00Z") && Found(path: "/x").latest == nil)
        // Still after what @open opened, and after apps.
        var history = OpenHistory()
        history.record(old.path, at: date("2020-01-01T00:00:00Z"))
        let app = Found(path: "/Applications/Readme Viewer.app")
        #expect(FileSearchRanking.rank([repo, app, old], keywords: ["readme"], history: history) == [old, app, repo])
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
        // An app's other names count: 「设置」 starts its Chinese name 设置助理, not 系统设置.
        let assistant = Found(path: "/System/Applications/Utilities/Setup Assistant.app", names: ["Setup Assistant", "设置助理"])
        #expect(FileSearchRanking.rank([systemSettings, assistant], keywords: ["设置"], history: OpenHistory()) == [assistant, systemSettings])
    }

    @Test func onlyTheFirstOnesArePickedOutAndInTheOrderOfAFullRanking() {
        // Dates, names, depths and duplicates all over the place (a fixed pseudo-random sequence): picking
        // out the first few gives what ranking all of them would start with.
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let files = (0..<500).map { index -> Found in
            let folder = String(repeating: "/sub", count: next(4))
            let name = ["notes", "my notes", "notes-\(next(50))", "Notes"][next(4)] + [".txt", ".md", ".app"][next(3)]
            let day = next(3) == 0 ? nil : date("2026-01-01T00:00:00Z").addingTimeInterval(Double(next(40)) * 86_400)
            return Found(path: "/Users/me\(folder)/\(next(30))/\(name)", lastUsed: index % 2 == 0 ? day : nil,
                         modified: index % 3 == 0 ? day : nil)
        }
        var history = OpenHistory()
        history.record(files[7].path, at: date("2026-06-01T00:00:00Z"))
        let all = FileSearchRanking.rank(files, keywords: ["notes"], history: history)
        #expect(Set(all.map(\.path)).count == all.count)
        for limit in [0, 1, 3, 8, 50, all.count, all.count + 5] {
            #expect(FileSearchRanking.rank(files, keywords: ["notes"], history: history, limit: limit) == Array(all.prefix(limit)))
        }
        #expect(all.first?.path == files[7].path)
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
            byContent: { predicate in
                asked.append(predicate)
                return [
                    Found(path: "/Users/me/2026/周报.docx"),  // already listed by name
                    Found(path: "/Users/me/notes/old.md"),
                    Found(path: "/Users/me/notes/recent.md", lastUsed: date("2026-10-01T00:00:00Z")),
                    Found(path: "/Users/me/notes/setup.md"),  // opened through @open: first of the content matches
                    Found(path: "/Users/me/Library/Mail/x.emlx"),  // not a candidate
                    Found(path: "/Users/me/notes/old.md"),
                ]
            })
        #expect(asked == [#"kMDItemTextContent == "周报"cdw && kMDItemTextContent == "2026"cdw"#])
        #expect(found.map(\.path) == ["/Users/me/2026/周报.docx", "/Users/me/notes/setup.md", "/Users/me/notes/recent.md",
                                      "/Users/me/notes/old.md"])
        #expect(found.map(\.matchedContent) == [false, true, true, true])
    }

    @Test func contentIsSearchedOnlyWhenNamesAreFewAndNoneIsAnApp() {
        var asked = 0
        func content(_ query: String, names: [Found], apps: [Found] = []) -> [(path: String, matchedContent: Bool)] {
            FileSearchRanking.search(query, limit: 8, history: OpenHistory(), apps: apps, isCandidate: { _ in true },
                                     byName: { _ in names },
                                     byContent: { _ in asked += 1; return [Found(path: "/Users/me/mentions it.txt")] })
        }
        let three = (1...3).map { Found(path: "/Users/me/notes \($0).txt") }
        #expect(content("notes", names: three).count == 3 && asked == 0)  // 3 by name: enough
        #expect(content("notes", names: Array(three.prefix(2))).map(\.matchedContent) == [false, false, true] && asked == 1)
        #expect(content("notes", names: []).map(\.path) == ["/Users/me/mentions it.txt"] && asked == 2)
        // An app among them: the query names it.
        #expect(content("notes", names: [Found(path: "/Users/me/Downloads/Notes Helper.app")]).count == 1 && asked == 2)
        #expect(content("备忘录", names: [], apps: [notes]).map(\.path) == [notes.path] && asked == 2)
        // Under 2 characters: no full-text search.
        #expect(content("n", names: [Found(path: "/Users/me/n.txt")]).map(\.path) == ["/Users/me/n.txt"] && asked == 2)
        // Both together stay within the limit.
        let many = (1...10).map { Found(path: "/Users/me/notes \($0).txt") }
        let topped = search("notes", limit: 3, names: [many[0]], contents: Array(many[1...]))
        #expect(topped.map(\.path) == ["/Users/me/notes 1.txt", "/Users/me/notes 2.txt", "/Users/me/notes 3.txt"])
        #expect(topped.map(\.matchedContent) == [false, true, true])
        // Nothing to search by name (only an option-like word): the content isn't searched either.
        #expect(FileSearchRanking.search("-v", limit: 8, history: OpenHistory(), isCandidate: { _ in true },
                                         byName: { _ in asked += 1; return many }, byContent: { _ in asked += 1; return many })
            .isEmpty && asked == 2)
    }

    @Test func contentMatchesSkipNoiseAndShowEachFileNameOnce() {
        let found = search("报告", names: [], contents: [
            Found(path: "/Users/me/site/Saved Page_files/report.js"),
            Found(path: "/Users/me/proj/__pycache__/report.cpython-312.pyc"),
            Found(path: "/Users/me/proj/report.pyc"),
            Found(path: "/Users/me/proj/venv/lib/report.py"),
            Found(path: "/Users/me/proj/.venv/lib/report2.py"),
            Found(path: "/Users/me/lib/python3/site-packages/pkg/report.md"),
            Found(path: "/Users/me/proj/build/report.txt"),
            Found(path: "/Users/me/proj/Dist/report.html"),
            Found(path: "/Users/me/a/index.html", lastUsed: date("2025-01-01T00:00:00Z")),
            Found(path: "/Users/me/b/index.html", modified: date("2026-10-01T00:00:00Z")),  // the most recent of the three
            Found(path: "/Users/me/c/Index.html"),
            Found(path: "/Users/me/building/report.txt"),  // not a build folder
            Found(path: "/Users/me/build.txt"),
        ])
        // The most recent first, then (no dates) the shallower path.
        #expect(found.map(\.path) == ["/Users/me/b/index.html", "/Users/me/build.txt", "/Users/me/building/report.txt"])
        #expect(FileSearchRanking.isNoise("/Users/me/Downloads/My Page_files/x.png"))
        #expect(!FileSearchRanking.isNoise("/Users/me/Downloads/My Page_files"))  // the folder itself, by name
        #expect(!FileSearchRanking.isNoise("/Users/me/dist.md") && !FileSearchRanking.isNoise("/Users/me/builds/x.txt"))
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
