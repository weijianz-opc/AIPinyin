import Foundation

/// How a note goes to Apple Notes and how the folder's notes come back, without Notes itself (the app's
/// NotesBridge runs the AppleScript): pure, so it can be tested.
public enum NotesFormat {
    /// A note's body is HTML: a <div> per line (\r\n is one break; an empty line keeps its height), the text
    /// escaped, and spaces that HTML would collapse (several in a row, or at either end of a line) kept as
    /// no-break spaces.
    public static func html(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            let chars = Array(line)
            var out = ""
            for (i, c) in chars.enumerated() {
                switch c {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case " ":
                    let alone = i > 0 && i < chars.count - 1 && chars[i - 1] != " " && chars[i + 1] != " "
                    out += alone ? " " : "&nbsp;"
                default: out.append(c)
                }
            }
            return "<div>" + (out.isEmpty ? "<br>" : out) + "</div>"
        }.joined()
    }

    /// A note's title as Notes shows it: its first line with text, at most `limit` characters.
    public static func title(of text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(line.prefix(limit))
    }

    /// A note listed from the folder.
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let title: String
        public let modified: Date

        public init(id: String, title: String, modified: Date) {
            self.id = id
            self.title = title
            self.modified = modified
        }
    }

    /// What the script listing the folder returns (three lists, one Apple event each: the ids, the names and
    /// the modification dates; an empty list when there is no folder) as entries, the newest first, at most
    /// `limit`. A note without an id is left out; one without a name or date gets none.
    public static func entries(from result: NSAppleEventDescriptor, limit: Int) -> [Entry] {
        let columns = items(result)
        guard columns.count == 3 else { return [] }
        let (ids, names, dates) = (items(columns[0]), items(columns[1]), items(columns[2]))
        let all = ids.indices.compactMap { i -> Entry? in
            guard let id = ids[i].stringValue, !id.isEmpty else { return nil }
            return Entry(id: id, title: i < names.count ? names[i].stringValue ?? "" : "",
                         modified: i < dates.count ? dates[i].dateValue ?? .distantPast : .distantPast)
        }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(max(limit, 0)))
    }

    /// AppleScript's list type ('list').
    private static let listType: FourCharCode = 0x6C69_7374

    /// The items of an AppleScript list (none for anything else).
    private static func items(_ list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard list.descriptorType == listType else { return [] }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1) }
    }
}
