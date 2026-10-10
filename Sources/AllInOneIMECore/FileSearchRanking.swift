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

/// The parts of `@open`'s Spotlight search that don't touch the disk: the keywords of a query, which
/// paths match them, what `mdfind -attr` prints, and the order the results are listed in.
public enum FileSearchRanking {
    /// A file Spotlight found, and when it was last used (kMDItemLastUsedDate; nil: never, or not known).
    public struct Found: Equatable, Sendable {
        public var path: String
        public var lastUsed: Date?

        public init(path: String, lastUsed: Date? = nil) {
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    /// Name searches at most (one `mdfind -name` each).
    public static let maxNameSearches = 3

    /// The words of a query: split at spaces (full-width ones too), empty ones dropped.
    public static func keywords(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The keywords searched for by name: the longest first, each once, at most `maxNameSearches`.
    /// Ones starting with "-" are left out (mdfind would take them for options).
    public static func nameSearches(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        let distinct = keywords.filter { !$0.hasPrefix("-") && seen.insert(folded($0)).inserted }
        let longestFirst = distinct.enumerated().sorted {
            $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
        }
        return longestFirst.prefix(maxNameSearches).map(\.element)
    }

    /// What the full-text search looks for, or nil for no such search: under 2 characters finds far too
    /// much (and a query starting with "-" would be taken for an option).
    public static func contentQuery(_ query: String) -> String? {
        let text = keywords(in: query).joined(separator: " ")
        return text.count >= 2 && !text.hasPrefix("-") ? text : nil
    }

    /// Whether every keyword is somewhere in `path` and at least one in its file name (case and accents
    /// don't matter).
    public static func matches(_ path: String, keywords: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        return keywords.allSatisfy { contains(path, $0) } && keywords.contains { contains(name, $0) }
    }

    static let lastUsedSeparator = "   kMDItemLastUsedDate = "

    /// The files in what `mdfind -attr kMDItemLastUsedDate` printed, one a line:
    /// "<path>   kMDItemLastUsedDate = 2026-10-09 22:51:04 +0000", or "… = (null)" for a file never
    /// used. Paths may have spaces in them: the last separator counts. A last line that was cut off
    /// (mdfind stopped at the time limit) is skipped.
    public static func parseLastUsed(_ output: String) -> [Found] {
        // Bytes, not Strings: a short name finds tens of thousands of files (`-name a`: 11 MB here).
        var lines = Array(output.utf8).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        lines.removeLast()  // what follows the last line break: nothing, or a line cut off
        let separator = Array(lastUsedSeparator.utf8), never = Array("(null)".utf8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return lines.compactMap { line in
            guard let cut = line.indices.reversed().first(where: { line[$0...].starts(with: separator) }) else {
                return line.isEmpty ? nil : Found(path: String(decoding: line, as: UTF8.self))
            }
            let path = String(decoding: line[..<cut], as: UTF8.self), value = line[(cut + separator.count)...]
            guard !path.isEmpty else { return nil }
            return Found(path: path, lastUsed: value.elementsEqual(never) ? nil : formatter.date(from: String(decoding: value, as: UTF8.self)))
        }
    }

    /// The order results are listed in: what was opened through `@open` (the latest first), then apps,
    /// then the files used most recently (never used: after those), then names with more of the
    /// keywords, names that start with one, shallower paths, shorter names; ties keep their order.
    /// A path found twice is listed once.
    public static func rank(_ files: [Found], keywords: [String], history: OpenHistory) -> [Found] {
        let opened = history.lastOpened
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.path).inserted }
        let keyed = unique.enumerated().map { index, file -> (file: Found, key: [Double]) in
            let name = (file.path as NSString).lastPathComponent
            let inName = keywords.filter { contains(name, $0) }.count
            let startsWithOne = keywords.contains { contains(name, $0, options: .anchored) }
            return (file, [
                opened[file.path].map { -$0.timeIntervalSinceReferenceDate } ?? .infinity,
                file.path.hasSuffix(".app") ? 0 : 1,
                file.lastUsed.map { -$0.timeIntervalSinceReferenceDate } ?? .infinity,
                Double(-inName),
                startsWithOne ? 0 : 1,
                Double(file.path.split(separator: "/").count),
                Double(name.count),
                Double(index),
            ])
        }
        return keyed.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.file)
    }

    /// `@open` for `query` (not a path): by name, then by content, at most `limit` paths. `byName` gets
    /// the keywords to search names for (`nameSearches`) and returns all it found; with several keywords
    /// only files that `match` them all are kept. When that leaves fewer than `limit`, `byContent` gets
    /// the full-text query (`contentQuery`), and the files it finds follow, marked as content matches,
    /// without those already listed. Both parts are ranked (`rank`); only paths that `isCandidate` are listed.
    public static func search(_ query: String, limit: Int, history: OpenHistory,
                              isCandidate: (String) -> Bool,
                              byName: ([String]) -> [Found],
                              byContent: (String) -> [Found]) -> [(path: String, matchedContent: Bool)] {
        let words = keywords(in: query)
        let searched = nameSearches(words)
        let named = (searched.isEmpty ? [] : byName(searched)).filter {
            isCandidate($0.path) && (words.count == 1 || matches($0.path, keywords: words))
        }
        let names = rank(named, keywords: words, history: history)
        var listed = names.prefix(limit).map { (path: $0.path, matchedContent: false) }
        guard listed.count < limit, let text = contentQuery(query) else { return listed }
        let shown = Set(names.map(\.path))
        let contents = byContent(text).filter { isCandidate($0.path) && !shown.contains($0.path) }
        listed += rank(contents, keywords: words, history: history).prefix(limit - listed.count)
            .map { (path: $0.path, matchedContent: true) }
        return listed
    }

    static func contains(_ text: String, _ keyword: String, options: String.CompareOptions = []) -> Bool {
        text.range(of: keyword, options: options.union([.caseInsensitive, .diacriticInsensitive])) != nil
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
