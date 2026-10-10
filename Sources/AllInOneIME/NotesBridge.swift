import Carbon
import Foundation

/// Apple Notes, which only AppleScript reaches: `@note` saves to it, and a dashboard can list what was
/// saved and open it. Everything is in a folder named "AllInOneIME" in the default account, made when
/// missing.
///
/// Scripts run one at a time on a queue of their own, never on the main thread: that one handles the
/// keystrokes, and the first script waits until the user answers macOS's prompt to allow controlling
/// Notes (System Settings → Privacy & Security → Automation). NSAppleScript may be used off the main
/// thread (AppleScript release notes, Mac OS X 10.6), one script per thread at a time: each run makes
/// its own. Text goes to a script as an argument (`on run argv`), never into its source.
enum NotesBridge {
    static let folderName = "AllInOneIME"

    /// A note in the folder.
    struct Note: Equatable, Sendable {
        /// Notes' identifier (`x-coredata://…`), for `show(id:)`.
        let id: String
        /// The note's first line.
        let title: String
        let modified: Date
    }

    enum NotesError: Error, Equatable {
        /// Not allowed to control Notes (System Settings → Privacy & Security → Automation).
        case notPermitted
        /// The script failed: AppleScript's error number and message.
        case failed(number: Int, message: String)
    }

    /// Saves `text` as a new note (its first line is the note's title); returns the note's identifier.
    @discardableResult
    static func save(_ text: String) async throws -> String {
        try await run(saveScript, [folderName, html(text)]) { $0.stringValue ?? "" }
    }

    /// The `limit` notes in the folder changed last, newest first (none while there is no folder).
    static func recent(limit: Int = 10) async throws -> [Note] {
        let notes = try await run(recentScript, [folderName]) { result -> [Note] in
            let columns = items(result)
            guard columns.count == 3 else { return [] }
            let (ids, names, dates) = (items(columns[0]), items(columns[1]), items(columns[2]))
            return ids.indices.compactMap { i in
                guard let id = ids[i].stringValue, i < names.count, i < dates.count else { return nil }
                return Note(id: id, title: names[i].stringValue ?? "", modified: dates[i].dateValue ?? .distantPast)
            }
        }
        return Array(notes.sorted { $0.modified > $1.modified }.prefix(max(limit, 0)))
    }

    /// Opens the note in Notes, in front.
    static func show(id: String) async throws {
        try await run(showScript, [id]) { _ in () }
    }

    /// A note's body is HTML: the text escaped, a line per line (an empty one keeps its height).
    static func html(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            return "<div>" + (escaped.isEmpty ? "<br>" : escaped) + "</div>"
        }.joined()
    }

    // MARK: - Scripts

    /// argv: the folder's name, the note's HTML body.
    private static let saveScript = """
        on run argv
            set folderName to item 1 of argv
            tell application "Notes"
                set theAccount to default account
                if not (exists folder folderName of theAccount) then
                    make new folder at theAccount with properties {name:folderName}
                end if
                set theNote to make new note at folder folderName of theAccount with properties {body:item 2 of argv}
                return id of theNote
            end tell
        end run
        """

    /// argv: the folder's name. Three lists, one Apple event each (not three per note): the ids, names
    /// and modification dates. Asked of the folder itself: a list of notes fetched first has no `id of`.
    private static let recentScript = """
        on run argv
            set folderName to item 1 of argv
            tell application "Notes"
                set theAccount to default account
                if not (exists folder folderName of theAccount) then return {}
                tell folder folderName of theAccount
                    return {id of every note, name of every note, modification date of every note}
                end tell
            end tell
        end run
        """

    /// argv: the note's identifier.
    private static let showScript = """
        on run argv
            tell application "Notes"
                show note id (item 1 of argv)
                activate
            end tell
        end run
        """

    /// Every script above, for the self-test (it compiles them; nothing is sent to Notes).
    static var scripts: [String] { [saveScript, recentScript, showScript] }

    private static let queue = DispatchQueue(label: "AllInOneIME.notes", qos: .userInitiated)

    /// Runs `source`'s run handler with `arguments` on the scripts' queue; `read` turns the result into
    /// what the caller gets, still on that queue (Apple event descriptors stay there).
    static func run<T>(_ source: String, _ arguments: [String],
                       read: @escaping (NSAppleEventDescriptor) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try read(execute(source, arguments)) }) }
        }
    }

    /// Runs the script's run handler the way osascript does: an "open application" event whose direct
    /// object is the list of arguments.
    private static func execute(_ source: String, _ arguments: [String]) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw NotesError.failed(number: 0, message: "") }
        let argv = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            argv.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(argv, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user said no (or hasn't been asked and can't be); -1744: it would need asking.
            if number == Int(errAEEventNotPermitted) || number == Int(errAEEventWouldRequireUserConsent) {
                throw NotesError.notPermitted
            }
            throw NotesError.failed(number: number, message: error[NSAppleScript.errorMessage] as? String ?? "")
        }
        return result
    }

    /// The items of an AppleScript list (none for anything else).
    private static func items(_ list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard list.descriptorType == typeAEList else { return [] }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1) }
    }
}
