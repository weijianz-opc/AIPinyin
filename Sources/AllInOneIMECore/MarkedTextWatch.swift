import Foundation

/// Notices when the app took the text being typed (the marked text) without saying so: Slack turns
/// an "@…" in it into a mention and commits the composition on its own. The input method still
/// thinks the draft is pending, so its next key would show the whole draft again, doubled.
///
/// Only apps seen reporting a marked range are checked: some report none at all, and they would
/// look as if every composition had been taken.
public struct MarkedTextWatch: Equatable, Sendable {
    /// The app reported marked text for what was set at least once.
    public private(set) var appReportsMarkedText = false

    public init() {}

    /// After the input method set `expected` as the marked text: what the app reports now (the length
    /// of its marked range, nil for none).
    public mutating func didSet(expected: String, reportedLength: Int?) {
        if !expected.isEmpty, let reportedLength, reportedLength > 0 { appReportsMarkedText = true }
    }

    /// Before a key, with `expected` still pending: whether the app has taken it.
    public func appTookText(expected: String, reportedLength: Int?) -> Bool {
        appReportsMarkedText && !expected.isEmpty && (reportedLength ?? 0) == 0
    }

    /// A new text field (or the app changed): nothing known about it yet.
    public mutating func reset() { appReportsMarkedText = false }
}
