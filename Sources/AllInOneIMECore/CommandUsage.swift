import Foundation

/// How much each @ command is used, for the order of the command list: every run adds 1 to its
/// score, and scores halve every week, so both how often and how lately count ("frecency").
public struct CommandUsage: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var score: Double
        var last: Date
    }

    var entries: [String: Entry] = [:]
    public static let halfLife: TimeInterval = 7 * 86400

    public init() {}

    /// The command's score as of `now`.
    public func score(_ name: String, now: Date = Date()) -> Double {
        guard let entry = entries[name] else { return 0 }
        return entry.score * pow(0.5, max(now.timeIntervalSince(entry.last), 0) / Self.halfLife)
    }

    /// The command was run.
    public mutating func record(_ name: String, now: Date = Date()) {
        entries[name] = Entry(score: score(name, now: now) + 1, last: now)
        // Forget the long unused (a score under 0.01: about 7 weeks after a single use).
        entries = entries.filter { score($0.key, now: now) >= 0.01 || $0.key == name }
    }
}

extension Command {
    /// The command list has room for this many: the digits 1–5 pick them.
    public static let paletteLimit = 5

    /// The commands the list shows for `query` (the letters after "@"), at most `limit`. Nothing
    /// typed: the most used, then the rest in catalog order. Letters: names starting with them, then
    /// names containing them, each by use. Every match counts for `matching`; only these are shown.
    public static func palette(_ query: String, in commands: [Command], usage: CommandUsage,
                               limit: Int = paletteLimit, now: Date = Date()) -> [Command] {
        let query = query.lowercased()
        let ranked = commands.enumerated().compactMap { index, command -> (group: Int, score: Double, index: Int, command: Command)? in
            let group: Int
            if query.isEmpty || command.name.hasPrefix(query) {
                group = 0
            } else if command.name.contains(query) {
                group = 1
            } else {
                return nil
            }
            return (group, usage.score(command.name, now: now), index, command)
        }
        return ranked.sorted {
            ($0.group, -$0.score, $0.index) < ($1.group, -$1.score, $1.index)
        }.prefix(limit).map(\.command)
    }
}
