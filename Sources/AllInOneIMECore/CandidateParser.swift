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

/// One rewrite in a preset style ("简洁" concise, "正式" formal, …), in the language the sentence was typed in.
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
    /// The three main versions in the output language (translations, or polished versions of a
    /// sentence already in that language).
    public var versions: [CandidateLine]
    /// Rewrites in the original language, in the order the model sent them (one per style).
    public var rewrites: [Rewrite]

    public init(versions: [CandidateLine] = [], rewrites: [Rewrite] = []) {
        self.versions = versions
        self.rewrites = rewrites
    }

    public static let empty = ConversionResult()

    public var isEmpty: Bool { versions.isEmpty && rewrites.isEmpty }

    public func rewrite(_ style: String) -> CandidateLine? {
        rewrites.first { $0.style == style }?.line
    }
}

/// Parses model output of the form `EN: …` (x3, `ZH: …` for Chinese output) followed by one line
/// per rewrite style (`POLISH: …`, `CONCISE: …`, …), tolerating partial streaming text, full-width
/// colons, list markers, quotes and markdown emphasis.
public enum CandidateParser {
    enum Tag: Equatable { case version, rewrite(String), ignored }

    public static func parse(
        _ raw: String, isFinal: Bool, output: Language = .english, maxVersions: Int = 3
    ) -> ConversionResult {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var versions: [CandidateLine] = []
        var rewrites: [Rewrite] = []
        var sawTag = false
        var untagged: [String] = []

        for (index, rawLine) in lines.enumerated() {
            let isComplete = isFinal || index < lines.count - 1
            let line = stripListMarker(rawLine.trimmingCharacters(in: .whitespaces))
            guard !line.isEmpty else { continue }
            guard let (tag, body) = splitTag(line, output: output) else {
                // While streaming, "E" or "CON" may be the start of a tag; only keep finished lines.
                if isComplete { untagged.append(line) }
                continue
            }
            sawTag = true
            let text = clean(body)
            guard !text.isEmpty || !isComplete else { continue }
            switch tag {
            case .version:
                versions.append(CandidateLine(text, isComplete: isComplete))
            case let .rewrite(style):
                if !rewrites.contains(where: { $0.style == style }) {
                    rewrites.append(Rewrite(style: style, line: CandidateLine(text, isComplete: isComplete)))
                }
            case .ignored:
                break
            }
        }

        // Model ignored the format entirely: treat whatever it said as the main versions.
        if isFinal, !sawTag {
            versions = untagged.map { CandidateLine(clean($0)) }.filter { !$0.text.isEmpty }
        }

        var seen = Set<String>()
        versions = versions.filter { line in
            guard line.isComplete else { return true }
            return seen.insert(line.text.lowercased()).inserted
        }
        return ConversionResult(versions: Array(versions.prefix(maxVersions)), rewrites: rewrites)
    }

    /// Lines tagged with the output language are the main versions; the other language's tag is ignored.
    static func splitTag(_ line: String, output: Language = .english) -> (Tag, String)? {
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let name = line[..<colon]
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_` \t"))
            .uppercased()
        var body = String(line[line.index(after: colon)...])
        // "**EN:** text" leaves the closing emphasis right after the colon.
        while let first = body.first, "*_".contains(first) { body.removeFirst() }
        let language: Language
        switch name {
        case "EN", "ENGLISH", "英文": language = .english
        case "ZH", "CN", "中文", "CHINESE": language = .chinese
        default:
            guard let style = RewriteStyle.forTag(name) else { return nil }
            return (.rewrite(style.name), body)
        }
        return (language == output ? .version : .ignored, body)
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
