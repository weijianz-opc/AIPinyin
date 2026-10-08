import Foundation

/// One entry of the user's jargon list.
public struct JargonEntry: Equatable, Sendable {
    public var term: String
    /// What it means in plain words (may be empty).
    public var meaning: String

    public init(term: String, meaning: String = "") {
        self.term = term
        self.meaning = meaning
    }
}

/// The user's own jargon list for the 黑话 style ("bring your own"; nothing is built in): a plain
/// text file with one term per line, optionally followed by its meaning after "：", ":", "=", a tab
/// or " - ". Lines starting with # are comments. With a list, the model prefers its terms, and the
/// candidate panel explains the ones a 黑话 line uses.
public enum JargonLibrary {
    /// At most this many entries are read (and sent with a request).
    public static let maxEntries = 150
    static let maxTermLength = 60
    static let maxMeaningLength = 120
    static let maxFileBytes = 256 * 1024
    /// Size budget of the list in the prompt, in characters.
    static let promptBudget = 4000

    /// Where the list is read from unless `Config.jargonFile` names another file.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/aipinyin/jargon.txt")
    }

    /// Written when the user creates a list from the settings window: comments only, no entries.
    public static let template = """
        # AI 拼音 黑话库：每行一个词，后面可以加解释，用「：」「=」或 Tab 隔开。# 开头的行会被忽略。
        # 打开「黑话」改写风格后，模型会优先用这里的词；候选里会注明用到的词是什么意思。
        # 例：
        # bandwidth：精力、时间
        # 抓手：着力点

        """

    static let separators = ["：", ":", "=", "\t", " - ", " — ", " – "]

    public static func parse(_ text: String) -> [JargonEntry] {
        var entries: [JargonEntry] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let (rawTerm, rawMeaning) = split(trimmed)
            let term = clean(rawTerm, limit: maxTermLength)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            entries.append(JargonEntry(term: term, meaning: clean(rawMeaning, limit: maxMeaningLength)))
            if entries.count == maxEntries { break }
        }
        return entries
    }

    /// The list in `url`; a missing or unreadable file is an empty list.
    public static func load(from url: URL) -> [JargonEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes) else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Splits at the earliest separator: term, meaning.
    static func split(_ line: String) -> (String, String) {
        var best: Range<String.Index>?
        for separator in separators {
            if let range = line.range(of: separator), best.map({ range.lowerBound < $0.lowerBound }) ?? true {
                best = range
            }
        }
        guard let best else { return (line, "") }
        return (String(line[..<best.lowerBound]), String(line[best.upperBound...]))
    }

    /// Control characters out (the list goes into the prompt and the candidate panel), length capped.
    static func clean(_ text: String, limit: Int) -> String {
        String(CandidateParser.stripControls(text).trimmingCharacters(in: .whitespaces).prefix(limit))
            .trimmingCharacters(in: .whitespaces)
    }

    /// The list as prompt lines ("  - term (meaning)"), within the size budget.
    static func promptList(_ entries: [JargonEntry]) -> String {
        var lines: [String] = []
        var size = 0
        for entry in entries {
            let line = "  - \(entry.term)" + (entry.meaning.isEmpty ? "" : " (\(entry.meaning))")
            size += line.count + 1
            if size > promptBudget { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Identifies a list's content (for the conversion cache; stable within the process).
    static func fingerprint(_ entries: [JargonEntry]) -> String {
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.term)
            hasher.combine(entry.meaning)
        }
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }

    /// Entries with a meaning whose term appears in `text`, in order of appearance. Terms in Latin
    /// letters match whole words only ("own" doesn't match "download"), ignoring case.
    public static func used(in text: String, entries: [JargonEntry], limit: Int = 2) -> [JargonEntry] {
        let hits = entries.filter { !$0.meaning.isEmpty }
            .compactMap { entry in match(entry.term, in: text).map { (range: $0, entry: entry) } }
            .sorted {
                $0.range.lowerBound != $1.range.lowerBound
                    ? $0.range.lowerBound < $1.range.lowerBound
                    : $0.entry.term.count > $1.entry.term.count  // "circle back" before "circle"
            }
        var out: [JargonEntry] = []
        var covered = text.startIndex
        for hit in hits where hit.range.lowerBound >= covered {
            out.append(hit.entry)
            covered = hit.range.upperBound
            if out.count == limit { break }
        }
        return out
    }

    /// "bandwidth＝精力、时间，抓手＝着力点" for the terms `text` uses (meanings shortened), or nil.
    public static func annotation(for text: String, entries: [JargonEntry]) -> String? {
        let terms = used(in: text, entries: entries)
        guard !terms.isEmpty else { return nil }
        return terms.map { entry in
            let meaning = entry.meaning.count > 14 ? String(entry.meaning.prefix(13)) + "…" : entry.meaning
            return "\(entry.term)＝\(meaning)"
        }.joined(separator: "，")
    }

    static func match(_ term: String, in text: String) -> Range<String.Index>? {
        let isWordCharacter: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let latinStart = term.first.map(isWordCharacter) ?? false
        let latinEnd = term.last.map(isWordCharacter) ?? false
        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let cutStart = latinStart && before.map(isWordCharacter) == true
            let cutEnd = latinEnd && after.map(isWordCharacter) == true
            if !cutStart && !cutEnd { return range }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }
}
