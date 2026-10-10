import AllInOneIMECore
import AppKit
import EventKit

/// Apple Reminders through EventKit: `@reminder` adds to it, and a dashboard can list what is still to
/// do, tick it off and open the app. Everything is in a list named "AllInOneIME", made in the default
/// account for reminders when missing.
///
/// EventKit's calls are synchronous round trips to the calendar service, so the store is only used on
/// a queue of its own, never on the main thread (which handles the keystrokes). macOS asks the user
/// once, the first time access is needed (System Settings → Privacy & Security → Reminders).
enum RemindersBridge {
    static let listName = "AllInOneIME"

    /// A reminder in the list that isn't done yet.
    struct Reminder: Equatable, Sendable {
        /// EventKit's identifier (`calendarItemIdentifier`), for `complete(id:)`.
        let id: String
        let title: String
        /// When it is due, in this Mac's time zone like `ReminderDraft.due` (nil: no date), and whether
        /// that includes a time of day.
        let due: DateComponents?
        let hasTime: Bool
        /// Its time (without one, its day) is over.
        let overdue: Bool
    }

    enum RemindersError: Error, Equatable {
        /// Not allowed (System Settings → Privacy & Security → Reminders).
        case notPermitted
        /// No account to make the list in (none is set up for reminders).
        case noAccount
        /// No such reminder (any more).
        case notFound
        /// EventKit refused: its message.
        case failed(String)
    }

    /// Adds `draft` to the list, due then (a day without a time: all day), with an alarm at that time
    /// when it has one. Returns the reminder's identifier.
    @discardableResult
    static func add(_ draft: ReminderDraft) async throws -> String {
        try await withStore { store in
            let reminder = EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.calendar = try list(in: store, create: true)
            if var due = draft.due {
                // EventKit raises an exception for components without the Gregorian calendar. A day
                // without a time is all day and floats (no time zone); a time keeps the zone it was
                // written in, like its alarm.
                due.calendar = Calendar(identifier: .gregorian)
                if draft.hasTime {
                    due.timeZone = .current
                } else {
                    (due.hour, due.minute, due.second, due.timeZone) = (nil, nil, nil, nil)
                }
                reminder.dueDateComponents = due
                if draft.hasTime, let date = due.date { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
            }
            try refused { try store.save(reminder, commit: true) }
            return reminder.calendarItemIdentifier
        }
    }

    /// The `limit` reminders in the list that aren't done, the soonest due first and those without a
    /// date last (none while there is no list).
    static func incomplete(limit: Int = 20, now: Date = Date()) async throws -> [Reminder] {
        try await requestAccess()
        let found: [Reminder] = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let store = currentStore()
                    guard let list = try list(in: store, create: false) else { return continuation.resume(returning: []) }
                    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
                    // Read in the completion (on EventKit's queue), where the fetched reminders are valid.
                    store.fetchReminders(matching: predicate) { reminders in
                        continuation.resume(returning: (reminders ?? []).map { reminder(from: $0, now: now) })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let order = { (r: Reminder) in r.due.flatMap { ReminderParser.localCalendar.date(from: $0) } ?? .distantFuture }
        return Array(found.sorted { (order($0), $0.title) < (order($1), $1.title) }.prefix(max(limit, 0)))
    }

    /// Marks the reminder done.
    static func complete(id: String) async throws {
        try await withStore { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw RemindersError.notFound }
            reminder.isCompleted = true
            try refused { try store.save(reminder, commit: true) }
        }
    }

    /// Opens the Reminders app in front.
    static func openApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - The store

    private static let queue = DispatchQueue(label: "AllInOneIME.reminders", qos: .userInitiated)
    /// Only touched on `queue`. Made again once access has been granted: one made before may still
    /// hold the state from then.
    nonisolated(unsafe) private static var store: EKEventStore?

    /// On `queue`.
    private static func currentStore() -> EKEventStore {
        if let store { return store }
        let made = EKEventStore()
        store = made
        return made
    }

    /// Runs `work` with the store on its queue, once macOS allows it (asking the user the first time).
    private static func withStore<T>(_ work: @escaping (EKEventStore) throws -> T) async throws -> T {
        try await requestAccess()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(currentStore()) }) }
        }
    }

    /// Full access (macOS 14's kind, the oldest this runs on), which adding the list and reading it need.
    /// Not yet decided: macOS asks the user (NSRemindersFullAccessUsageDescription), and this waits.
    private static func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    currentStore().requestFullAccessToReminders { granted, error in
                        queue.async {
                            if granted { store = nil }
                            if let error, !granted {
                                continuation.resume(throwing: RemindersError.failed(error.localizedDescription))
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    }
                }
            }
            if !granted { throw RemindersError.notPermitted }
        default:
            // Denied, restricted (and write-only, which only events have).
            throw RemindersError.notPermitted
        }
    }

    /// The AllInOneIME list (the one in the default account, if there are several); made there when
    /// missing and `create`.
    private static func list(in store: EKEventStore, create: Bool) throws -> EKCalendar? {
        let named = store.calendars(for: .reminder).filter { $0.title == listName }
        let account = store.defaultCalendarForNewReminders()?.source
        if let list = named.first(where: { $0.source?.sourceIdentifier == account?.sourceIdentifier }) ?? named.first {
            return list
        }
        guard create else { return nil }
        guard let account else { throw RemindersError.noAccount }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listName
        list.source = account
        try refused { try store.saveCalendar(list, commit: true) }
        return list
    }

    /// What EventKit throws, as `failed` with its message.
    private static func refused(_ work: () throws -> Void) throws {
        do {
            try work()
        } catch let error as RemindersError {
            throw error
        } catch {
            throw RemindersError.failed(error.localizedDescription)
        }
    }

    /// A fetched reminder, its due date in this Mac's time zone (one written elsewhere keeps its moment).
    private static func reminder(from item: EKReminder, now: Date) -> Reminder {
        var due: DateComponents?
        let hasTime = item.dueDateComponents?.hour != nil
        if let components = item.dueDateComponents {
            var calendar = components.calendar ?? Calendar(identifier: .gregorian)
            calendar.timeZone = components.timeZone ?? .current
            if let date = calendar.date(from: components) {
                let fields: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                due = ReminderParser.localCalendar.dateComponents(fields, from: date)
            }
        }
        let title = item.title ?? ""
        let overdue = ReminderDraft(title: title, due: due, hasTime: hasTime).isPast(now: now)
        return Reminder(id: item.calendarItemIdentifier, title: title, due: due, hasTime: hasTime, overdue: overdue)
    }
}
