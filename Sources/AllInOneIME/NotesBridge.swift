import AllInOneIMECore
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
        /// The script failed: AppleScript's error number (its message is in the system's language, and may
        /// quote the note: it is neither shown nor logged).
        case failed(number: Int)
    }

    /// Saves `text` as a new note (its first line is the note's title, its lines stay lines); returns the
    /// note's identifier. Then `.allInOneIMENoteSaved` is posted on the main thread (for the floating panel).
    @discardableResult
    static func save(_ text: String) async throws -> String {
        let id = try await run(saveScript, [folderName, html(text)]) { $0.stringValue ?? "" }
        let title = NotesFormat.title(of: text)
        await MainActor.run {
            NotificationCenter.default.post(name: .allInOneIMENoteSaved, object: nil, userInfo: ["id": id, "title": title])
        }
        return id
    }

    /// The `limit` notes in the folder changed last, newest first (none while there is no folder).
    static func recent(limit: Int = 10) async throws -> [Note] {
        try await run(recentScript, [folderName]) { result in
            NotesFormat.entries(from: result, limit: limit).map { Note(id: $0.id, title: $0.title, modified: $0.modified) }
        }
    }

    /// Opens the note in Notes, in front.
    static func show(id: String) async throws {
        try await run(showScript, [id]) { _ in () }
    }

    /// A note's body (`NotesFormat.html`): a line per line, the text escaped, runs of spaces kept.
    static func html(_ text: String) -> String { NotesFormat.html(text) }

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
    static func run<T: Sendable>(_ source: String, _ arguments: [String],
                                 read: @escaping @Sendable (NSAppleEventDescriptor) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try read(execute(source, arguments)) }) }
        }
    }

    /// Runs the script's run handler the way osascript does: an "open application" event whose direct
    /// object is the list of arguments.
    private static func execute(_ source: String, _ arguments: [String]) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw NotesError.failed(number: 0) }
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
            throw NotesError.failed(number: number)
        }
        return result
    }
}
