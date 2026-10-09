import AllInOneIMECore
import Carbon
import Foundation

/// Thin wrapper over the Text Input Sources API for installing the input method.
enum InputSourceRegistrar {
    static var sourceID: String {
        Bundle.main.object(forInfoDictionaryKey: "TISInputSourceID") as? String
            ?? "com.aipinyin.inputmethod.AIPinyin"
    }

    static func register(bundleURL: URL = Bundle.main.bundleURL) -> OSStatus {
        TISRegisterInputSource(bundleURL as CFURL)
    }

    /// Finds our input source, including when it is installed but disabled.
    static func source() -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }

    /// Registration is asynchronous inside the text input server; poll briefly.
    static func waitForSource(timeout: TimeInterval = 5) -> TISInputSource? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let source = source() { return source }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    /// Re-queries the source each time (properties of an existing TISInputSource object may be stale).
    static func waitUntilEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let source = source(), bool(source, kTISPropertyInputSourceIsEnabled) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func currentSourceID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(current, kTISPropertyInputSourceID)
    }

    // MARK: The user's input-source list

    /// What input-source lists file the input method under.
    static var bundleID: String { Bundle.main.bundleIdentifier ?? sourceID }

    /// The user's own input-source list (see `InputSourceList`); nil if macOS hasn't written one.
    static func userList() -> [[String: Any]]? {
        CFPreferencesCopyValue(InputSourceList.key as CFString, InputSourceList.domain as CFString,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [[String: Any]]
    }

    static var isInUserList: Bool {
        userList().map { InputSourceList.contains($0, bundleID: bundleID) } ?? false
    }

    enum ListUpdate { case unchanged, written, failed }

    /// Writes back what `change` makes of the user's list (nil: leave it as it is), and tells the
    /// text input agents (Input menu, Ctrl+Space) that the enabled sources changed.
    static func updateUserList(_ change: ([[String: Any]]?) -> [[String: Any]]?) -> ListUpdate {
        guard let updated = change(userList()) else { return .unchanged }
        let domain = InputSourceList.domain as CFString
        CFPreferencesSetValue(InputSourceList.key as CFString, updated as CFArray, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return .failed }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, userInfo: nil, deliverImmediately: true)
        return .written
    }
}
