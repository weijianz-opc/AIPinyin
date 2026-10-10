import Foundation

/// What `@open` opened, the latest first (at most `limit`): those files come first in its results.
public struct OpenHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var date: Date

        public init(path: String, date: Date) {
            self.path = path
            self.date = date
        }
    }

    public static let limit = 200
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// `path` was opened at `date`: it moves to the front, and the oldest beyond `limit` are forgotten.
    public mutating func record(_ path: String, at date: Date = Date()) {
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, date: date), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// When each path was last opened.
    var lastOpened: [String: Date] {
        Dictionary(entries.map { ($0.path, $0.date) }, uniquingKeysWith: { max($0, $1) })
    }
}

/// The parts of `@open`'s search that don't touch the disk: the keywords of a query, what is searched for
/// them, which paths and apps match them, what `mdfind -attr` prints, and the order results are listed in.
public enum FileSearchRanking {
    /// A file Spotlight found, or an app of the app index (`AppIndex`), and when it was last used and changed.
    public struct Found: Equatable, Sendable {
        public var path: String
        /// kMDItemLastUsedDate (nil: never, or not known: editors and terminals don't record a use).
        public var lastUsed: Date?
        /// kMDItemContentModificationDate.
        public var modified: Date?
        /// What else it is called, matched like its file name: an app's names (计算器 for Calculator.app).
        public var names: [String]

        public init(path: String, lastUsed: Date? = nil, modified: Date? = nil, names: [String] = []) {
            self.path = path
            self.lastUsed = lastUsed
            self.modified = modified
            self.names = names
        }

        /// When it was last used or changed, whichever is later.
        public var latest: Date? { lastUsed.map { used in modified.map { max(used, $0) } ?? used } ?? modified }
    }

    /// Name searches at most (one `mdfind -name` each).
    public static let maxNameSearches = 3
    /// The most name matches that still get a full-text search after them (and none of them an app):
    /// with more, what the files contain would only add files that have little to do with the query.
    public static let maxNamesForContent = 2

    /// The words of a query: split at spaces (full-width ones too), empty ones dropped.
    public static func keywords(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The keywords searched for by name: the longest first, each once, at most `maxNameSearches`. Ones
    /// starting with "-" are left out (mdfind would take them for options), and so is a single letter or
    /// digit when there is anything else to search for: `-name a` lists some 66,000 files here (15 MB,
    /// 2 s), so "plan b" searches for "plan" and keeps the paths that have a "b" too (`matches`).
    public static func nameSearches(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var distinct = keywords.filter { !$0.hasPrefix("-") && seen.insert(folded($0)).inserted }
        if distinct.contains(where: { !isSingleASCII($0) }) { distinct.removeAll(where: isSingleASCII) }
        let longestFirst = distinct.enumerated().sorted {
            $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
        }
        return longestFirst.prefix(maxNameSearches).map(\.element)
    }

    /// Whether `query` is searched while it is typed: not when it is only single letters or digits ("a",
    /// "a b"), whose search takes seconds and lists files at random (⏎ still searches them). A path is.
    public static func searchesAsYouType(_ query: String) -> Bool {
        query.hasPrefix("/") || query.hasPrefix("~") || keywords(in: query).contains { !isSingleASCII($0) }
    }

    /// The full-text search for `keywords`: each one a word in the text (case and accents don't matter).
    /// Built here instead of handing the text to mdfind's own parser, where "kind:pdf", OR, quotes and `*`
    /// change the search. Nil for under 2 characters in all, which finds far too much.
    public static func contentPredicate(_ keywords: [String]) -> String? {
        guard keywords.joined().count >= 2 else { return nil }
        return keywords.map { "kMDItemTextContent == \"\(escaped($0))\"cdw" }.joined(separator: " && ")
    }

    /// `keyword` inside a query's double quotes: a backslash before `\` and `"` (which would end it), and
    /// before `*` (a wildcard there).
    static func escaped(_ keyword: String) -> String {
        var escaped = ""
        for character in keyword {
            if character == "\\" || character == "\"" || character == "*" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Whether every keyword is in `path` or one of `names`, and at least one in its file name or one of
    /// `names` (case and accents don't matter). `names`: what else it is called (an app's 计算器).
    public static func matches(_ path: String, names: [String] = [], keywords: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        return keywords.allSatisfy { keyword in contains(path, keyword) || names.contains { contains($0, keyword) } }
            && keywords.contains { keyword in contains(name, keyword) || names.contains { contains($0, keyword) } }
    }

    /// What a full-text search turns up that nobody means: what is inside the folders of saved web pages
    /// ("…_files"), Python's caches, packages and virtual environments, and build output; compiled Python.
    public static func isNoise(_ path: String) -> Bool {
        path.hasSuffix(".pyc") || path.split(separator: "/").dropLast().contains { folder in
            let folder = folder.lowercased()
            return folder.hasSuffix("_files") || noiseFolders.contains(folder)
        }
    }

    static let noiseFolders: Set<String> = ["__pycache__", "site-packages", "venv", ".venv", "build", "dist"]

    /// The attributes `parse` reads, as mdfind is asked for them.
    public static let attributes = ["-attr", "kMDItemLastUsedDate", "-attr", "kMDItemContentModificationDate"]
    static let lastUsedField = Array("   kMDItemLastUsedDate = ".utf8)
    static let modifiedField = Array("   kMDItemContentModificationDate = ".utf8)

    /// The files in what mdfind printed when asked for `attributes`, one a line: "<path>   kMDItemLastUsedDate
    /// = 2018-03-04 05:06:07 +0000   kMDItemContentModificationDate = (null)" ("(null)": not known). Paths
    /// may have anything in them, so the fields are taken from the end; a line without them is a path. A
    /// last line that was cut off (mdfind stopped at the time limit) is skipped. On the bytes, without a
    /// date formatter: one letter finds tens of thousands of files.
    public static func parse(_ output: Data) -> [Found] {
        output.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return [] }
            var found: [Found] = []
            var start = 0
            while start < bytes.count, let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), bytes.count - start) {
                let newline = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                var end = newline
                let modified = takeField(modifiedField, from: bytes, start: start, end: &end)
                let lastUsed = takeField(lastUsedField, from: bytes, start: start, end: &end)
                if end > start {
                    let path = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
                    found.append(Found(path: path, lastUsed: lastUsed, modified: modified))
                }
                start = newline + 1
            }
            return found
        }
    }

    /// The date in the field `name` that ends the line `start..<end`, and `end` moved back to where the
    /// field starts. When the line doesn't end with it, nil and `end` as it was.
    private static func takeField(_ name: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, start: Int, end: inout Int) -> Date? {
        guard let base = bytes.baseAddress else { return nil }
        // The value is "(null)" or a date (25 bytes): the field starts a little before the end of the line,
        // so only those few places are looked at (the last one there counts).
        let latest = end - name.count - 1, earliest = max(start, end - name.count - 40)
        guard latest >= earliest else { return nil }
        for at in stride(from: latest, through: earliest, by: -1) where memcmp(base + at, name, name.count) == 0 {
            let value = UnsafeBufferPointer(rebasing: bytes[(at + name.count)..<end])
            end = at
            return date(value)
        }
        return nil
    }

    /// A date as mdfind prints it ("2026-10-09 22:51:04 +0000"); nil for anything else ("(null)").
    static func date(_ text: UnsafeBufferPointer<UInt8>) -> Date? {
        // "-", "-", " ", ":", ":", " ", then "+" or "-" before the offset.
        guard text.count == 25, text[4] == 45, text[7] == 45, text[10] == 32, text[13] == 58, text[16] == 58, text[19] == 32,
              text[20] == 43 || text[20] == 45 else { return nil }
        func number(_ from: Int, _ digits: Int) -> Int? {
            var value = 0
            for index in from..<(from + digits) {
                guard (48...57).contains(text[index]) else { return nil }
                value = value * 10 + Int(text[index] - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2), let hour = number(11, 2),
              let minute = number(14, 2), let second = number(17, 2), let offsetHours = number(21, 2),
              let offsetMinutes = number(23, 2), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let offset = (offsetHours * 3600 + offsetMinutes * 60) * (text[20] == 45 ? -1 : 1)
        let seconds = daysSince1970(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days from 1970-01-01 to a date of the Gregorian calendar (Howard Hinnant's days_from_civil).
    static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// What `rank` orders by: the first field that differs decides, the smaller first.
    typealias Key = (opened: Double, app: Int, date: Double, inName: Int, startsWith: Int, depth: Int, length: Int, index: Int)

    static func precedes(_ a: Key, _ b: Key) -> Bool {
        // Tuples compare up to six elements at a time.
        let first = (a.opened, a.app, a.date, a.inName, a.startsWith, a.depth)
        let second = (b.opened, b.app, b.date, b.inName, b.startsWith, b.depth)
        return first != second ? first < second : (a.length, a.index) < (b.length, b.index)
    }

    /// The order results are listed in: what was opened through `@open` (the latest first), then apps,
    /// then what was used or changed most recently (whichever is later; neither known: after those), then
    /// names with more of the keywords, names that start with one (an app's other names count), shallower
    /// paths, shorter names; ties keep their order. A path found twice is listed once. Only the first
    /// `limit` are picked out, without sorting the rest (one letter finds thousands of files); with
    /// `oneOfEachName`, only the first of the files with the same name.
    public static func rank(_ files: [Found], keywords: [String], history: OpenHistory, limit: Int = .max,
                            oneOfEachName: Bool = false) -> [Found] {
        let opened = history.lastOpened
        var seen = Set<String>()
        var keyed: [(file: Found, key: Key)] = []
        keyed.reserveCapacity(files.count)
        for (index, file) in files.enumerated() where seen.insert(file.path).inserted {
            keyed.append((file, key(file, index: index, keywords: keywords, opened: opened)))
        }
        if oneOfEachName {
            var first: [String: Int] = [:]  // name → its best in `keyed`
            for (position, item) in keyed.enumerated() {
                let name = folded((item.file.path as NSString).lastPathComponent)
                if let other = first[name], precedes(keyed[other].key, item.key) { continue }
                first[name] = position
            }
            keyed = first.values.sorted().map { keyed[$0] }
        }
        guard keyed.count > limit else { return keyed.sorted { precedes($0.key, $1.key) }.map(\.file) }
        guard limit > 0 else { return [] }
        // The best `limit` so far, in order: most files don't make it, and are dropped after one comparison.
        var best: [(file: Found, key: Key)] = []
        best.reserveCapacity(limit + 1)
        for item in keyed {
            if best.count == limit, !precedes(item.key, best[limit - 1].key) { continue }
            var low = 0, high = best.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(best[middle].key, item.key) { low = middle + 1 } else { high = middle }
            }
            best.insert(item, at: low)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.file)
    }

    static func key(_ file: Found, index: Int, keywords: [String], opened: [String: Date]) -> Key {
        let name = (file.path as NSString).lastPathComponent
        var inName = 0, startsWith = false
        func score(_ text: String) {
            inName = max(inName, keywords.reduce(0) { $0 + (contains(text, $1) ? 1 : 0) })
            startsWith = startsWith || keywords.contains { contains(text, $0, options: .anchored) }
        }
        score(name)
        file.names.forEach(score)
        return (opened: opened[file.path].map { -$0.timeIntervalSinceReferenceDate } ?? .infinity,
                app: isApp(file.path) ? 0 : 1,
                date: file.latest.map { -$0.timeIntervalSinceReferenceDate } ?? .infinity,
                inName: -inName,
                startsWith: startsWith ? 0 : 1,
                depth: file.path.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "/") ? 1 : 0) },
                length: name.count,
                index: index)
    }

    /// `@open` for `query` (not a path), at most `limit` paths. First what has the keywords in its name:
    /// the apps of the app index (`apps`: all of them, each with its `names`, and its dates when known)
    /// whose names or paths have them all (`matches`), and what `byName` finds (it gets `nameSearches` and
    /// returns all it found; with several keywords only what `matches` them all is kept, and an app of the
    /// index only as matched by its names). When those are `maxNamesForContent` or fewer and none is an
    /// app, `byContent` gets the full-text search (`contentPredicate`), and the files it finds follow,
    /// marked as content matches: not noise (`isNoise`), not listed already, one of each file name. Both
    /// parts are ranked (`rank`); only paths that `isCandidate` are listed.
    public static func search(_ query: String, limit: Int, history: OpenHistory, apps: [Found] = [],
                              isCandidate: (String) -> Bool,
                              byName: ([String]) -> [Found],
                              byContent: (String) -> [Found]) -> [(path: String, matchedContent: Bool)] {
        let words = keywords(in: query)
        let searched = nameSearches(words)
        guard !searched.isEmpty else { return [] }
        var named = apps.filter { isCandidate($0.path) && matches($0.path, names: $0.names, keywords: words) }
        var position = Dictionary(named.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        let indexed = Set(apps.map(\.path))
        for file in byName(searched) where isCandidate(file.path) {
            if let at = position[file.path] {
                // Found again (an app of the index, or by a second keyword): what Spotlight knows of its dates.
                named[at].lastUsed = named[at].lastUsed ?? file.lastUsed
                named[at].modified = named[at].modified ?? file.modified
            } else if !indexed.contains(file.path), words.count == 1 || matches(file.path, keywords: words) {
                position[file.path] = named.count
                named.append(file)
            }
        }
        var listed = rank(named, keywords: words, history: history, limit: limit).map { (path: $0.path, matchedContent: false) }
        guard named.count <= maxNamesForContent, !named.contains(where: { isApp($0.path) }), listed.count < limit,
              let predicate = contentPredicate(words) else { return listed }
        let contents = byContent(predicate).filter { isCandidate($0.path) && !isNoise($0.path) && position[$0.path] == nil }
        listed += rank(contents, keywords: words, history: history, limit: limit - listed.count, oneOfEachName: true)
            .map { (path: $0.path, matchedContent: true) }
        return listed
    }

    static func isApp(_ path: String) -> Bool { path.hasSuffix(".app") }

    /// One letter or digit (or other ASCII character): it is in most paths.
    static func isSingleASCII(_ keyword: String) -> Bool {
        keyword.count == 1 && keyword.unicodeScalars.allSatisfy(\.isASCII)
    }

    static func contains(_ text: String, _ keyword: String, options: String.CompareOptions = []) -> Bool {
        text.range(of: keyword, options: options.union([.caseInsensitive, .diacriticInsensitive])) != nil
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
