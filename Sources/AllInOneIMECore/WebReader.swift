import Foundation
import PDFKit

/// `@read <url>`: a web page's title and main text, as context for the AI (`@question 总结一下 @read https://…`).
/// Only http and https; at most `maxBytes` downloaded and `maxChars` of text kept. The user typed the
/// address, so any site may be read (unlike plugins, which reach only the hosts they declare).
public enum WebReader {
    public static let maxBytes = 2 << 20
    public static let maxChars = 6000
    public static let timeout: TimeInterval = 10

    public enum ReadError: Error, LocalizedError, Equatable {
        case invalidURL(String)
        case http(Int)
        case unsupported(String)
        case empty
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case let .invalidURL(text): return "Not a web address: \(text)"
            case let .http(status): return "The page answered HTTP \(status)"
            case let .unsupported(type): return "Can't read this kind of content (\(type))"
            case .empty: return "No text found on the page (pages that need JavaScript can't be read)"
            case .tooLarge: return "The page is larger than \(maxBytes >> 20) MB"
            }
        }
    }

    /// The address as typed, made a URL: `example.com/a` → `https://example.com/a`. Nil unless http(s).
    public static func url(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    public static func read(_ address: String, session: URLSession = .shared) async throws -> String {
        guard let url = url(from: address) else { throw ReadError.invalidURL(address) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain,application/pdf;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, !(200..<300).contains(status) { throw ReadError.http(status) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw ReadError.tooLarge }
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let text = try extract(data, contentType: type, url: http?.url ?? url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadError.empty }
        return text
    }

    /// "Title\nhttps://…\n\nText", the text at most `maxChars`.
    static func extract(_ data: Data, contentType: String, url: URL) throws -> String {
        let title: String
        let body: String
        if contentType.contains("pdf") || data.starts(with: Array("%PDF".utf8)) {
            guard let document = PDFDocument(data: data) else { throw ReadError.unsupported("PDF") }
            title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
            body = document.string ?? ""
        } else if contentType.isEmpty || contentType.contains("html") || contentType.contains("xml") {
            let html = decode(data, contentType: contentType)
            (title, body) = Self.html(html)
        } else if contentType.hasPrefix("text/") || contentType.contains("json") {
            title = ""
            body = decode(data, contentType: contentType)
        } else {
            throw ReadError.unsupported(contentType.split(separator: ";").first.map(String.init) ?? contentType)
        }
        var text = tidy(body)
        // Pages drawn by JavaScript have little more than a title in their HTML.
        guard !text.isEmpty else { throw ReadError.empty }
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "…" }
        return [title.isEmpty ? nil : tidy(title), url.absoluteString].compactMap { $0 }.joined(separator: "\n") + "\n\n" + text
    }

    /// Bytes as text, in the charset the header or the page names (GBK/GB2312 pages read as GB18030).
    static func decode(_ data: Data, contentType: String) -> String {
        func charset(_ s: String) -> String? {
            guard let range = s.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive])
            else { return nil }
            return s[range].split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let name = charset(contentType) ?? charset(head) ?? "utf-8"
        if ["gbk", "gb2312", "gb18030", "x-gbk"].contains(name) {
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        }
        if name == "big5", let s = String(data: data, encoding: String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// The title and the main text of a page: the <article> or <main> when there is one, without
    /// scripts, styles, navigation, headers, footers and forms; block elements become line breaks.
    static func html(_ html: String) -> (title: String, text: String) {
        func first(_ pattern: String, in s: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let range = Range(match.range(at: 1), in: s) else { return nil }
            return String(s[range])
        }
        func removing(_ pattern: String, from s: String, with template: String = " ") -> String {
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]))
                .map { $0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template) } ?? s
        }
        let title = first(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)["']"#, in: html)
            ?? first(#"<title[^>]*>(.*?)</title>"#, in: html) ?? ""
        var s = removing(#"<!--.*?-->"#, from: html)
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head"] {
            s = removing("<\(tag)\\b[^>]*>.*?</\(tag)>", from: s)
        }
        // The main content when the page marks it; otherwise the body without its chrome.
        if let main = first(#"<article\b[^>]*>(.*)</article>"#, in: s) ?? first(#"<main\b[^>]*>(.*)</main>"#, in: s) {
            s = main
        } else {
            for tag in ["nav", "header", "footer", "aside", "form"] {
                s = removing("<\(tag)\\b[^>]*>.*?</\(tag)>", from: s)
            }
        }
        s = removing(#"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/blockquote|/pre)\b[^>]*>"#, from: s, with: "\n")
        s = removing(#"<li\b[^>]*>"#, from: s, with: "\n• ")
        s = removing(#"<[^>]+>"#, from: s)
        return (entities(title), entities(s))
    }

    /// &amp; &lt; &#39; &#x4E2D; … as characters.
    static func entities(_ s: String) -> String {
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’"]
        var out = s
        guard out.contains("&") else { return out }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            out = result + ns.substring(from: last)
        }
        for (entity, char) in named { out = out.replacingOccurrences(of: entity, with: char) }
        return out
    }

    /// Spaces collapsed, blank lines at most one in a row, trimmed.
    static func tidy(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `read` as a stream, like the other commands' results.
    public static func stream(_ address: String, session: URLSession = .shared) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = Date()
                do {
                    let text = try await read(address, session: session)
                    continuation.yield(ConversionUpdate(result: ConversionResult(versions: [CandidateLine(text)]), rawText: text,
                                                        isFinal: true, elapsed: Date().timeIntervalSince(started),
                                                        firstTokenLatency: nil, fromCache: false))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
