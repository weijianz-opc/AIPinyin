import Foundation

/// What the input method tells its own parts about, within the process (the floating panel
/// listens). Posted on the main thread.
extension Notification.Name {
    /// @note saved a note. userInfo: "id" (String, the Notes id), "title" (String, its first line).
    static let allInOneIMENoteSaved = Notification.Name("AllInOneIMENoteSaved")
    /// @reminder added a reminder. userInfo: "id" (String, the EventKit identifier).
    static let allInOneIMEReminderAdded = Notification.Name("AllInOneIMEReminderAdded")
}
