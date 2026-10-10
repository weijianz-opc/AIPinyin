import Foundation

// Commands that send something (`@imessage`; later `@wechat`, `@slack`): the user picks a recipient
// in the candidate panel, writes the message (commands inside it run first), and confirms the final
// text in the panel before anything is sent. Nothing is inserted into the document.

/// Someone a message goes to: a name for the panel and the handle the service sends to (a phone
/// number or an email address for iMessage).
public struct Recipient: Hashable, Codable, Sendable {
    /// As the panel shows it ("张三"); empty for a number or address typed directly.
    public var name: String
    public var handle: String

    public init(name: String, handle: String) {
        self.name = name
        self.handle = handle
    }

    /// The name, or the handle when there is none.
    public var displayName: String { name.isEmpty ? handle : name }
}

/// Sends a message (the App target's AppleScript sender for iMessage; stand-ins in the tests).
public protocol MessageSender: Sendable {
    func send(_ text: String, to recipient: Recipient) async throws
}

public enum MessageSendError: Error, Equatable, Sendable {
    /// Not allowed to control the app that sends (Apple events, errAEEventNotPermitted -1743).
    case notPermitted
    /// The sending app isn't on this Mac.
    case appMissing
    /// The script failed with this AppleScript / Apple event error number (0: none given).
    case failed(code: Int)

    /// An osascript error message ("… (-1743)") as an error: only its number is kept.
    public static func from(osascriptError message: String) -> MessageSendError {
        let code = errorCode(in: message) ?? 0
        return code == -1743 ? .notPermitted : .failed(code: code)
    }

    /// The number in the last "(…)" of an osascript error message.
    static func errorCode(in message: String) -> Int? {
        guard let open = message.lastIndex(of: "("), let close = message[open...].firstIndex(of: ")") else { return nil }
        return Int(message[message.index(after: open)..<close])
    }
}

/// The AppleScript that sends an iMessage (an SMS when there is no iMessage account). The handle and
/// the text are passed as arguments (`on run argv`), never written into the script, so nothing in
/// them can be read as AppleScript.
public enum MessageScript {
    public static let iMessage = """
        on run argv
        	set theHandle to item 1 of argv
        	set theText to item 2 of argv
        	tell application "Messages"
        		try
        			set theAccount to 1st account whose service type = iMessage
        		on error
        			set theAccount to 1st account whose service type = SMS
        		end try
        		send theText to participant theHandle of theAccount
        	end tell
        end run

        """

    /// osascript's arguments: the script comes on standard input ("-"), then its own arguments.
    public static func osascriptArguments(handle: String, text: String) -> [String] {
        ["-", handle, text]
    }
}

/// Someone in the address book, as the recipient search needs them.
public struct Contact: Equatable, Sendable {
    /// "张三", "John Appleseed".
    public var name: String
    /// Nickname, company: also found by.
    public var otherNames: [String]
    /// Phone numbers and email addresses, in the card's order.
    public var handles: [String]
    /// The name in pinyin without spaces ("zhangsan") and its initials ("zs"), for Chinese names.
    let pinyin: String
    let initials: String

    public init(name: String, otherNames: [String] = [], handles: [String]) {
        self.name = name
        self.otherNames = otherNames.filter { !$0.isEmpty }
        self.handles = handles
        (pinyin, initials) = Self.pinyin(of: name)
    }

    /// The name's syllables in pinyin, joined, and their first letters ("张三" → "zhangsan", "zs").
    /// Empty without Chinese in the name.
    static func pinyin(of name: String) -> (String, String) {
        guard name.containsHan,
              let latin = name.applyingTransform(.mandarinToLatin, reverse: false)?
                  .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() else { return ("", "") }
        let syllables = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (syllables.joined(), String(syllables.compactMap(\.first)))
    }

    /// A contact's name from the parts of a card: "张三" (family name first, no space, when Chinese),
    /// "John Appleseed"; else the nickname or the company.
    public static func displayName(given: String, family: String, nickname: String = "", organization: String = "") -> String {
        let given = given.trimmingCharacters(in: .whitespaces), family = family.trimmingCharacters(in: .whitespaces)
        if !given.isEmpty || !family.isEmpty {
            if (given + family).containsHan { return family + given }
            return [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return nickname.isEmpty ? organization : nickname
    }
}

/// Finds recipients for what is typed after `@imessage`: names (and their pinyin or its initials),
/// nicknames, companies, phone digits, email addresses. The ones messaged lately come first.
public enum RecipientSearch {
    public static let limit = 8
    /// How many recently messaged handles are kept.
    public static let recentLimit = 8

    /// Up to `limit` recipients for `query` (one per handle), the recent ones first, then by how well
    /// they match. Nothing typed: the recent ones. A phone number or an email address typed in full is
    /// offered too when no contact has it.
    public static func results(_ query: String, contacts: [Contact], recent: [String], limit: Int = limit) -> [Recipient] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func recentRank(_ handle: String) -> Int { recent.firstIndex { sameHandle($0, handle) } ?? Int.max }
        if q.isEmpty {
            return recent.prefix(limit).map { handle in
                for contact in contacts {
                    if let known = contact.handles.first(where: { sameHandle($0, handle) }) {
                        return Recipient(name: contact.name, handle: known)
                    }
                }
                return Recipient(name: "", handle: handle)
            }
        }
        var found: [(recent: Int, rank: Int, order: Int, recipient: Recipient)] = []
        for (index, contact) in contacts.enumerated() {
            let byName = nameRank(q, contact)
            for (h, handle) in contact.handles.enumerated() {
                guard let rank = [byName, handleRank(q, handle)].compactMap({ $0 }).min() else { continue }
                found.append((recentRank(handle), rank, index * 100 + h, Recipient(name: contact.name, handle: handle)))
            }
        }
        var out = found.sorted { ($0.recent, $0.rank, $0.order) < ($1.recent, $1.rank, $1.order) }.map(\.recipient)
        var seen = Set<String>()
        out = out.filter { seen.insert($0.handle).inserted }
        if let typed = typedHandle(query), !out.contains(where: { sameHandle($0.handle, typed) }) {
            return Array(out.prefix(limit - 1)) + [Recipient(name: "", handle: typed)]
        }
        return Array(out.prefix(limit))
    }

    /// 0 the whole name, 1 its start, 2 its pinyin's or initials' start, 3 a word's start (or a
    /// nickname's, a company's), 4 inside it or its pinyin. Nil: no match.
    static func nameRank(_ q: String, _ contact: Contact) -> Int? {
        let name = contact.name.lowercased()
        if name.isEmpty { return nil }
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if !contact.pinyin.isEmpty, contact.pinyin.hasPrefix(q) || contact.initials.hasPrefix(q) { return 2 }
        let words = name.split(separator: " ").map(String.init) + contact.otherNames.map { $0.lowercased() }
        if words.contains(where: { $0.hasPrefix(q) }) { return 3 }
        if name.contains(q) || contact.otherNames.contains(where: { $0.lowercased().contains(q) })
            || q.count >= 2 && contact.pinyin.contains(q) { return 4 }
        return nil
    }

    /// 3 an email address starting with it, or a phone number whose digits start with the typed ones;
    /// 5 inside it. Nil: no match.
    static func handleRank(_ q: String, _ handle: String) -> Int? {
        let handle = handle.lowercased()
        if handle.contains("@") {
            if handle.hasPrefix(q) { return 3 }
            return q.count >= 2 && handle.contains(q) ? 5 : nil
        }
        guard looksLikePhone(q) else { return nil }
        let typed = digits(q), number = digits(handle)
        guard typed.count >= 2 else { return nil }
        if number.hasPrefix(typed) { return 3 }
        return number.contains(typed) ? 5 : nil
    }

    /// Digits with the punctuation phone numbers are written with.
    static func looksLikePhone(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || "+-() .".contains($0)) } && text.contains(where: \.isNumber)
    }

    static func digits(_ text: String) -> String { String(text.filter { $0.isASCII && $0.isNumber }) }

    /// The query as a handle to send to, if it is one: an email address, or a phone number with at
    /// least five digits.
    public static func typedHandle(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.contains(" "), let at = text.firstIndex(of: "@"), at != text.startIndex,
           text[text.index(after: at)...].contains("."), !text.hasSuffix("."), text.filter({ $0 == "@" }).count == 1 {
            return text
        }
        if looksLikePhone(text), digits(text).count >= 5 { return text }
        return nil
    }

    /// The same address (ignoring case), or the same phone number (the same digits, or one ending in the
    /// other's, so "+86 138 0000 1111" is "13800001111").
    public static func sameHandle(_ a: String, _ b: String) -> Bool {
        if a.contains("@") || b.contains("@") { return a.lowercased() == b.lowercased() }
        let x = digits(a), y = digits(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        if x == y { return true }
        return min(x.count, y.count) >= 7 && (x.hasSuffix(y) || y.hasSuffix(x))
    }

    /// The recent handles after sending to `handle`: it first, at most `recentLimit`.
    public static func remember(_ handle: String, in recent: [String]) -> [String] {
        Array(([handle] + recent.filter { !sameHandle($0, handle) }).prefix(recentLimit))
    }
}

extension CommandPipeline {
    /// A stream that gives `text` back as it is: the outer step of a send command, whose text is sent
    /// as written once the commands inside it have run.
    public static func unchanged(_ text: String) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ConversionUpdate(result: ConversionResult(versions: [CandidateLine(text)]), rawText: text,
                                                isFinal: true, elapsed: 0, firstTokenLatency: nil, fromCache: false))
            continuation.finish()
        }
    }
}
