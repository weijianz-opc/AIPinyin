import Foundation

/// A web address with `{input}` in its query or fragment, for `link` commands (plugins and custom ones):
/// `https://x.com/intent/post?text={input}`. Running the command puts the text there, percent-encoded,
/// and opens the page in the default browser; nothing is inserted. No script runs and nothing is sent
/// by the input method itself: the browser opens the page, where the user decides what happens next.
public enum LinkTemplate {
    public static let placeholder = CustomCommand.placeholder

    /// The most text a link takes, in Characters (a long post; far longer addresses break in browsers
    /// and the sites cut them anyway).
    public static let maxInputLength = 4000

    /// What makes a template unusable.
    public enum Problem: Equatable, Sendable {
        case empty
        /// Only `https://` addresses: the text must not travel in the clear.
        case notHTTPS
        /// `{input}` must appear exactly once.
        case placeholderCount
        /// `{input}` must be in the query or fragment (after `?` or `#`), never in the host or path,
        /// so the text can't choose where it goes.
        case placeholderNotInQuery
        /// Not a valid web address (spaces, no host, …).
        case invalid

        /// For a manifest's `problem`, in English like the other plugin problems.
        public var description: String {
            switch self {
            case .empty: return "no url"
            case .notHTTPS: return "the url must start with https://"
            case .placeholderCount: return "the url must contain {input} exactly once"
            case .placeholderNotInQuery: return "{input} must be in the url's query (after ? or #)"
            case .invalid: return "invalid url"
            }
        }
    }

    /// Why `template` can't be used, or nil.
    public static func problem(_ template: String?) -> Problem? {
        guard let template = template?.trimmingCharacters(in: .whitespaces), !template.isEmpty else { return .empty }
        guard template.lowercased().hasPrefix("https://") else { return .notHTTPS }
        let pieces = template.components(separatedBy: placeholder)
        guard pieces.count == 2 else { return .placeholderCount }
        let before = pieces[0]
        guard before.contains("?") || before.contains("#") else { return .placeholderNotInQuery }
        guard let url = URL(string: pieces.joined()), let host = url.host, !host.isEmpty else { return .invalid }
        return nil
    }

    /// The host the text goes to ("x.com"), for a valid template.
    public static func host(_ template: String?) -> String? {
        guard let template, problem(template) == nil else { return nil }
        return URL(string: template.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: placeholder, with: ""))?.host
    }

    /// The characters a query value keeps as they are (RFC 3986 "unreserved"); everything else is
    /// percent-encoded as UTF-8: `&`, `#`, `+`, `=` can't end the value or change its meaning, a space is
    /// `%20` (not `+`, which some sites keep as a plus), a newline `%0A`.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The address for `input`; nil if the template isn't valid. An empty input gives an empty value
    /// (the site's composer opens empty).
    public static func url(_ template: String, input: String) -> URL? {
        guard problem(template) == nil else { return nil }
        let address = template.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: placeholder, with: encode(input))
        return URL(string: address)
    }

    /// A link command's outer step after the commands inside its text (`CommandPipeline`): the text,
    /// with their outputs in it, as the one final result (the composer then opens the link with it).
    public static func passThrough(_ text: String) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ConversionUpdate(result: ConversionResult(versions: [CandidateLine(text)]), rawText: text,
                                                isFinal: true, elapsed: 0, firstTokenLatency: nil, fromCache: false))
            continuation.finish()
        }
    }
}
