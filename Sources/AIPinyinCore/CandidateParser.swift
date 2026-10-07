import Foundation

public struct CandidateLine: Equatable, Sendable {
    public var text: String
    /// False while the line is still streaming in.
    public var isComplete: Bool

    public init(_ text: String, isComplete: Bool = true) {
        self.text = text
        self.isComplete = isComplete
    }
}

/// One Chinese rewrite in a preset style ("简洁", "正式", …).
public struct Rewrite: Equatable, Sendable {
    /// `RewriteStyle.name`
    public var style: String
    public var line: CandidateLine

    public init(style: String, line: CandidateLine) {
        self.style = style
        self.line = line
    }
}

/// Level-two output for one confirmed sentence.
public struct ConversionResult: Equatable, Sendable {
    public var english: [CandidateLine]
    /// Rewrites in the original language, in the order the model sent them (one per style).
    public var rewrites: [Rewrite]

    public init(english: [CandidateLine] = [], rewrites: [Rewrite] = []) {
        self.english = english
        self.rewrites = rewrites
    }

    public static let empty = ConversionResult()

    public var isEmpty: Bool { english.isEmpty && rewrites.isEmpty }

    public func rewrite(_ style: String) -> CandidateLine? {
        rewrites.first { $0.style == style }?.line
    }
}

/// Parses model output of the form `EN: …` (x3) followed by one line per rewrite style
/// (`POLISH: …`, `CONCISE: …`, …), tolerating partial streaming text, full-width colons,
/// list markers, quotes and markdown emphasis.
public enum CandidateParser {
    enum Tag: Equatable { case english, rewrite(String), ignored }

    public static func parse(_ raw: String, isFinal: Bool, maxEnglish: Int = 3) -> ConversionResult {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var english: [CandidateLine] = []
        var rewrites: [Rewrite] = []
        var sawTag = false
        var untagged: [String] = []

        for (index, rawLine) in lines.enumerated() {
            let isComplete = isFinal || index < lines.count - 1
            let line = stripListMarker(rawLine.trimmingCharacters(in: .whitespaces))
            guard !line.isEmpty else { continue }
            guard let (tag, body) = splitTag(line) else {
                // While streaming, "E" or "CON" may be the start of a tag; only keep finished lines.
                if isComplete { untagged.append(line) }
                continue
            }
            sawTag = true
            let text = clean(body)
            guard !text.isEmpty || !isComplete else { continue }
            switch tag {
            case .english:
                english.append(CandidateLine(text, isComplete: isComplete))
            case let .rewrite(style):
                if !rewrites.contains(where: { $0.style == style }) {
                    rewrites.append(Rewrite(style: style, line: CandidateLine(text, isComplete: isComplete)))
                }
            case .ignored:
                break
            }
        }

        // Model ignored the format entirely: treat whatever it said as English candidates.
        if isFinal, !sawTag {
            english = untagged.map { CandidateLine(clean($0)) }.filter { !$0.text.isEmpty }
        }

        var seen = Set<String>()
        english = english.filter { line in
            guard line.isComplete else { return true }
            return seen.insert(line.text.lowercased()).inserted
        }
        return ConversionResult(english: Array(english.prefix(maxEnglish)), rewrites: rewrites)
    }

    static func splitTag(_ line: String) -> (Tag, String)? {
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let name = line[..<colon]
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_` \t"))
            .uppercased()
        var body = String(line[line.index(after: colon)...])
        // "**EN:** text" leaves the closing emphasis right after the colon.
        while let first = body.first, "*_".contains(first) { body.removeFirst() }
        switch name {
        case "EN", "ENGLISH", "英文": return (.english, body)
        case "ZH", "CN", "中文", "CHINESE": return (.ignored, body)
        default:
            guard let style = RewriteStyle.forTag(name) else { return nil }
            return (.rewrite(style.name), body)
        }
    }

    static func stripListMarker(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-*•".contains(first), s.dropFirst().first == " " {
            s = s.dropFirst(2)
        } else {
            let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty, digits.count <= 2 {
                let rest = s.dropFirst(digits.count)
                if let marker = rest.first, ".)、".contains(marker) {
                    s = rest.dropFirst()
                }
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Model output is inserted into whatever app has focus (possibly a terminal), so characters that
    /// could act as input rather than text are dropped: C0/C1 controls (ESC, DEL, tab, NEL…) and
    /// Unicode line/paragraph separators become spaces; bidi embedding/override/isolate controls are removed.
    static func stripControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                out.append(" ")
            default:
                if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                    continue
                }
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func clean(_ text: String) -> String {
        var s = stripControls(text).trimmingCharacters(in: .whitespaces)
        for _ in 0..<2 {
            for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("「", "」"), ("**", "**"), ("`", "`")]
            where s.count >= open.count + close.count && s.hasPrefix(open) && s.hasSuffix(close) {
                s = String(s.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}
