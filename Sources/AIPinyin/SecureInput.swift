import AppKit
import Carbon
import InputMethodKit

/// Secure event input is a session-wide flag: password fields, terminals' "Secure Keyboard Entry",
/// sudo prompts and the lock screen turn it on. macOS reports only one owner process and may
/// attribute it to loginwindow, so the owner can't always be trusted.
///
/// Policy: while it is on, nothing is ever sent to the model (InputController checks that before
/// every conversion). Local composing is also turned off in the app that reports owning it, in
/// terminals (their password prompts don't restrict input sources), and when the owner is unknown.
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// Process that turned on secure event input: nil when off, -1 when on but the owner is unknown.
    static func ownerPID() -> pid_t? {
        guard isOn else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = session?["kCGSSessionSecureInputPID"] as? NSNumber else { return -1 }
        return pid_t(truncating: pid)
    }

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    /// True when nothing should be composed for `client` (keys then go to the app as typed).
    static func blocksComposing(_ client: IMKTextInput?) -> Bool {
        guard let pid = ownerPID() else { return false }
        let target = client?.bundleIdentifier()
        if let target, terminals.contains(target) { return true }
        guard pid > 0,
              let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let target
        else { return true }  // can't tell who owns it: be safe
        return owner == target
    }

    static func ownerDescription() -> String {
        guard let pid = ownerPID() else { return "off" }
        let name = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)" : "unknown"
        return "held by \(name)"
    }
}
