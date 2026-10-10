import Foundation

/// A text with @ commands inside it: `告诉他 @stock AAPL 现在多少钱`. The inner commands fetch something
/// (plugins and custom programs: `kind == .run`); they run first, each one's output takes its place,
/// and the outer command then works on the result (`告诉他 Apple Inc. AAPL 336.64 USD −1.11% 现在多少钱`).
///
/// An inner command is `@name` (a known command, not after a letter or digit, so `a@b.com` stays text)
/// followed by a space and its argument (`argument(_:from:)`): `@stock AAPL TSLA 哪个涨得多` → `AAPL TSLA`,
/// `@stock SNDK is good to buy` → `SNDK`, `@stock「aapl tsla」` → `aapl tsla`. `@calc` takes the whole
/// expression after it (`Calculator.argument`): `总价是 @calc 23 * 17 元` → `23 * 17`. Anything else is plain text.
public struct CommandPlan: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        /// The output of `inner[index]`.
        case inner(Int)
    }

    public struct Inner: Equatable, Sendable {
        public var command: Command
        public var argument: String
    }

    public var parts: [Part]
    public var inner: [Inner]

    /// Nothing to run first: the text is used as it is.
    public var isEmpty: Bool { inner.isEmpty }

    /// Commands that can run inside a text: the ones that fetch something.
    public static func canBeInner(_ command: Command) -> Bool { command.kind == .run }

    public static func make(_ text: String, commands: [Command]) -> CommandPlan {
        let inners = Dictionary(commands.filter(canBeInner).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var parts: [Part] = []
        var inner: [Inner] = []
        var literal = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let afterWordChar = i > 0 && chars[i - 1].isASCII && (chars[i - 1].isLetter || chars[i - 1].isNumber)
            if c == "@", !afterWordChar {
                var j = i + 1
                while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
                let name = String(chars[(i + 1)..<j]).lowercased()
                // A space before the argument, or a quote right after the name (`@stock「aapl tsla」`).
                let start = j < chars.count && chars[j] == " " ? j + 1 : j
                if let command = inners[name], j < chars.count, chars[j] == " " || "「“\"".contains(chars[j]),
                   let (argument, end) = command == .calc ? Calculator.argument(chars, from: start) : Self.argument(chars, from: start) {
                    if !argument.isEmpty {
                        if !literal.isEmpty { parts.append(.text(literal)) }
                        literal = ""
                        parts.append(.inner(inner.count))
                        inner.append(Inner(command: command, argument: argument))
                        i = end
                        continue
                    }
                }
            }
            literal.append(c)
            i += 1
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        return CommandPlan(parts: parts, inner: inner)
    }

    /// The argument starting at `start` and where it ends: the text in 「…」 or "…", or else one word
    /// (ASCII, up to a space, a non-ASCII character or `@`) and the words right after it that have no
    /// lowercase letters (more symbols: `AAPL TSLA`, `600519 700`), so `@stock SNDK is good to buy`
    /// takes `SNDK`. Sentence punctuation at its end stays in the text. Nil when there is none.
    static func argument(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard start < chars.count else { return nil }
        let quotes: [Character: Character] = ["「": "」", "\"": "\"", "“": "”"]
        if let close = quotes[chars[start]] {
            guard let end = chars[(start + 1)...].firstIndex(of: close) else { return nil }
            let text = String(chars[(start + 1)..<end]).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (text, end + 1)
        }
        func word(at i: Int) -> Int {
            var k = i
            while k < chars.count, chars[k].isASCII, chars[k] != " ", chars[k] != "@", !chars[k].isNewline { k += 1 }
            return k
        }
        var end = word(at: start)
        guard end > start else { return nil }
        // More words: separated by one space, with no lowercase letters (symbols, codes, numbers).
        while end < chars.count, chars[end] == " " {
            let next = word(at: end + 1)
            let token = chars[(end + 1)..<next]
            guard next > end + 1, !token.contains(where: { $0.isLowercase }) else { break }
            end = next
        }
        while end > start, ",.;:!?".contains(chars[end - 1]) { end -= 1 }
        return end > start ? (String(chars[start..<end]), end) : nil
    }

    /// The text with each inner command replaced by its output.
    public func input(outputs: [String]) -> String {
        parts.map { part in
            switch part {
            case let .text(text): return text
            case let .inner(index): return index < outputs.count ? outputs[index] : ""
            }
        }.joined()
    }
}

public enum CommandPipelineError: Error, LocalizedError, Equatable {
    /// An inner command failed: its name and why.
    case inner(String, String)

    public var errorDescription: String? {
        switch self {
        case let .inner(name, message): return "@\(name): \(message)"
        }
    }
}

/// Runs a plan: the inner commands together, then the outer one on the text with their outputs.
public enum CommandPipeline {
    public typealias Inner = @Sendable (Command, String) -> AsyncThrowingStream<ConversionUpdate, Error>
    public typealias Outer = @Sendable (String) -> AsyncThrowingStream<ConversionUpdate, Error>

    public static func run(_ plan: CommandPlan, inner: @escaping Inner, outer: @escaping Outer)
        -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                        for (index, step) in plan.inner.enumerated() {
                            group.addTask {
                                var text = ""
                                do {
                                    for try await update in inner(step.command, step.argument) where update.isFinal {
                                        text = update.result.versions.first?.text ?? ""
                                    }
                                } catch {
                                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                                    throw CommandPipelineError.inner(step.command.name, message)
                                }
                                return (index, text)
                            }
                        }
                        var outputs = [String](repeating: "", count: plan.inner.count)
                        for try await (index, text) in group { outputs[index] = text }
                        return outputs
                    }
                    try Task.checkCancellation()
                    for try await update in outer(plan.input(outputs: outputs)) {
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
