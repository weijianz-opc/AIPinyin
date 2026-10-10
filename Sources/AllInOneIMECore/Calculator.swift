import Foundation

/// `@calc <expression>`: arithmetic worked out on this Mac; nothing is sent anywhere and no program
/// runs. The result is the one candidate (`@calc 23*17` → `391`); inside another command's text it
/// takes the command's place, as `@read` does (`@reply 总价是 @calc 23*17 元` → `总价是 391 元`).
///
/// The expression is read by a parser of its own, never by `eval`, JavaScript or `NSExpression`:
/// numbers (`3`, `2.5`, `.5`, `1e-3`); `+ - * /` (also `× ÷`); `^` or `**` for powers, right to left
/// and before signs (`2^3^2` is 2^9, `-2^2` is −4, `2^-1` is 0.5); signs; parentheses; `%` after a
/// value for percent (`50%` is 0.5, `200*5%` is 10); the functions `sqrt abs round floor ceil ln log
/// exp sin cos tan min max pow` (`log` is base 10, angles are radians, `round(x, 2)` keeps two
/// decimals) and the constants `pi` (`π`) and `e`, in any case. Full-width digits, signs and spaces
/// from Chinese typing count as their ASCII forms (`（２＋３）×４`), and a `=` at the end is ignored.
///
/// `+ - * /`, `%` and whole powers are exact decimals (`Decimal`: `0.1+0.2` is `0.3`, `2^100` keeps
/// all 31 digits); the functions and other powers use `Double`, and so does anything beyond what a
/// `Decimal` holds. Results come without float noise or trailing zeros (`format`).
public enum Calculator {
    /// Longest expression worked out, in characters.
    public static let maxLength = 1000
    /// Deepest nesting of parentheses, function calls and powers.
    public static let maxDepth = 50

    public enum CalcError: Error, LocalizedError, Equatable, Sendable {
        /// Nothing but spaces.
        case empty
        /// More than `maxLength` characters.
        case tooLong
        /// Parentheses, function calls or powers nested deeper than `maxDepth`.
        case tooDeep
        /// Something that doesn't fit where it is, as typed: `*` in `1+*2`, `3` in `2 3`, `元` in `5元`.
        case unexpected(String)
        /// The expression stops too early: `1+`, `sqrt(`.
        case incomplete
        /// A `(` without its `)`.
        case missingParenthesis
        /// Not a function or constant: `foo(2)`, `x`.
        case unknownName(String)
        /// A function called with the wrong number or kind of arguments: `pow(2)`, `sqrt 4`, `round(1, 0.5)`.
        case badArguments(String)
        case divisionByZero
        /// Infinite or not a real number: `sqrt(-1)`, `ln(0)`, `tan(pi/2)`, `10^400`.
        case notFinite

        /// In English, for logs and tests; the input method shows `UIText.describe`, in either language.
        public var errorDescription: String? {
            switch self {
            case .empty: return "Nothing to calculate"
            case .tooLong: return "The expression is too long: \(maxLength) characters at most"
            case .tooDeep: return "The expression is nested too deeply: \(maxDepth) levels at most"
            case let .unexpected(text): return "Invalid expression near \"\(text)\""
            case .incomplete: return "The expression is incomplete"
            case .missingParenthesis: return "A closing parenthesis is missing"
            case let .unknownName(name): return "Unknown function or constant: \(name)"
            case let .badArguments(name): return "Wrong arguments for \(name)"
            case .divisionByZero: return "Division by zero"
            case .notFinite: return "The result isn't a finite real number"
            }
        }
    }

    /// `expression` worked out, as it is inserted: `"23*17"` → `"391"`. Throws a `CalcError`.
    public static func evaluate(_ expression: String) throws -> String {
        guard expression.count <= maxLength else { throw CalcError.tooLong }
        // Spaces around it, and an "=" at its end (a calculator habit: "23*17=").
        var text = Substring(expression)
        while let last = text.last, last.isWhitespace || halfWidth(last) == "=" { text.removeLast() }
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        guard !text.isEmpty else { throw CalcError.empty }
        var parser = Parser(tokens: try tokens(String(text)))
        return format(try parser.parse())
    }

    /// `evaluate` as a stream, like the other commands' results: one final update, or the error.
    public static func stream(_ expression: String) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let started = Date()
            do {
                let text = try evaluate(expression)
                continuation.yield(ConversionUpdate(result: ConversionResult(versions: [CandidateLine(text)]), rawText: text,
                                                    isFinal: true, elapsed: Date().timeIntervalSince(started),
                                                    firstTokenLatency: nil, fromCache: false))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// The first `@calc` inside `plan`'s text that can't be worked out, and why. The input controller
    /// checks this before running the plan, to say so at once and in the interface language (an
    /// inner command's error otherwise reaches it as its English description only).
    public static func failure(in plan: CommandPlan) -> CalcError? {
        for step in plan.inner where step.command == .calc {
            do {
                _ = try evaluate(step.argument)
            } catch {
                return error as? CalcError ?? .incomplete
            }
        }
        return nil
    }

    // MARK: - Inside another command's text

    /// `@calc`'s argument inside another command's text (`CommandPlan.make`): the text in 「…」 or "…",
    /// or else the expression starting there, spaces and all, up to the first thing that can't be in
    /// one: other text (`总价是 @calc 23*17 元` → `23*17`), a word that isn't a function or constant
    /// (`@calc 2 * pi is about 6.28` → `2 * pi`), or a `,` or `)` that closes nothing
    /// (`（共 @calc 2*3）`). A period at its end stays in the text. Nil when no expression starts there.
    static func argument(_ text: [Character], from start: Int) -> (String, Int)? {
        guard start < text.count else { return nil }
        if "「“\"".contains(text[start]) { return CommandPlan.argument(text, from: start) }
        let chars = text.map(halfWidth)
        var i = start
        var end = start  // after the last character of the expression (spaces after it stay text)
        var depth = 0
        scan: while i < chars.count {
            let c = chars[i]
            if c == " " {
                i += 1
                continue
            }
            if c.isASCII, c.isNumber || c == "." {
                i = number(chars, from: i).end
            } else if c.isASCII, c.isLetter {
                let j = wordEnd(chars, from: i)
                guard isName(String(chars[i..<j])) else { break scan }
                i = j
            } else if c == "(" {
                depth += 1
                i += 1
            } else if c == ")" || c == "," {
                guard depth > 0 else { break scan }
                if c == ")" { depth -= 1 }
                i += 1
            } else if symbols[c] != nil || c == "π" {
                i += 1
            } else {
                break scan
            }
            end = i
        }
        while end > start, chars[end - 1] == "." { end -= 1 }
        return end > start ? (String(text[start..<end]), end) : nil
    }

    // MARK: - Reading

    struct Token: Equatable {
        enum Kind: Equatable {
            /// An ASCII literal that `Double` and `Decimal` read: "23", "0.5", "1e-3".
            case number(String)
            /// Lowercased: "sqrt", "pi".
            case name(String)
            case plus, minus, times, divide, power, percent, open, close, comma
        }

        var kind: Kind
        /// As typed, for error messages.
        var text: String
    }

    static let functions: Set<String> = ["sqrt", "abs", "round", "floor", "ceil", "ln", "log", "exp", "sin", "cos", "tan",
                                         "min", "max", "pow"]
    static let constants: Set<String> = ["pi", "e"]

    /// Operators and punctuation, after `halfWidth` (`**` is a power too).
    static let symbols: [Character: Token.Kind] = [
        "+": .plus, "-": .minus, "−": .minus, "*": .times, "×": .times, "/": .divide, "÷": .divide,
        "^": .power, "%": .percent, "(": .open, ")": .close, ",": .comma,
    ]

    /// A full-width form as its ASCII character, as Chinese typing gives them: "２" → "2", "（" → "(",
    /// "＊" → "*", "，" → ",", "　" → " ".
    static func halfWidth(_ c: Character) -> Character {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else { return c }
        switch scalar.value {
        case 0xFF01...0xFF5E: return Unicode.Scalar(scalar.value - 0xFEE0).map(Character.init) ?? c
        case 0x3000: return " "
        default: return c
        }
    }

    static func isName(_ word: String) -> Bool {
        let name = word.lowercased()
        return functions.contains(name) || constants.contains(name)
    }

    /// Where the name starting at `start` ends: a letter, then letters and digits (`log10` is one name).
    static func wordEnd(_ chars: [Character], from start: Int) -> Int {
        var j = start + 1
        while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber { j += 1 }
        return j
    }

    /// The number starting at `start` (digits, a point and more digits, an exponent: `1.5e-3`), as an
    /// ASCII literal ("0.5" for ".5", "5" for "5."), and where it ends.
    static func number(_ chars: [Character], from start: Int) -> (end: Int, literal: String) {
        var i = start
        func digits() -> String {
            let from = i
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            return String(chars[from..<i])
        }
        let whole = digits()
        var fraction = ""
        if i < chars.count, chars[i] == "." {
            i += 1
            fraction = digits()
        }
        var exponent = ""
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            // Only with digits after it: in `2e` the e is the constant.
            var j = i + 1
            var sign = ""
            if j < chars.count, chars[j] == "+" || chars[j] == "-" {
                sign = String(chars[j])
                j += 1
            }
            let from = j
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            if j > from {
                exponent = "e" + sign + String(chars[from..<j])
                i = j
            }
        }
        return (i, (whole.isEmpty ? "0" : whole) + (fraction.isEmpty ? "" : "." + fraction) + exponent)
    }

    static func tokens(_ text: String) throws -> [Token] {
        let typed = Array(text)
        let chars = typed.map(halfWidth)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            let start = i
            let kind: Token.Kind
            if c.isASCII, c.isNumber || c == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber {
                let (end, literal) = number(chars, from: i)
                kind = .number(literal)
                i = end
            } else if c.isASCII, c.isLetter {
                i = wordEnd(chars, from: i)
                kind = .name(String(chars[start..<i]).lowercased())
            } else if c == "π" {
                kind = .name("pi")
                i += 1
            } else if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                kind = .power
                i += 2
            } else if let symbol = symbols[c] {
                kind = symbol
                i += 1
            } else {
                throw CalcError.unexpected(String(typed[i]))
            }
            tokens.append(Token(kind: kind, text: String(typed[start..<i])))
        }
        return tokens
    }

    /// A token as an error message quotes it.
    static func shortened(_ text: String) -> String {
        text.count > 16 ? String(text.prefix(16)) + "…" : text
    }

    /// Recursive descent: sum → product → signed → power → percent → primary. Only parentheses, calls
    /// and powers recurse (counted against `maxDepth`); runs of signs and operators are loops.
    struct Parser {
        let tokens: [Token]
        var index = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var next: Token.Kind? { index < tokens.count ? tokens[index].kind : nil }

        mutating func parse() throws -> Number {
            guard !tokens.isEmpty else { throw CalcError.empty }
            let value = try sum()
            if index < tokens.count { throw CalcError.unexpected(shortened(tokens[index].text)) }
            return value
        }

        /// Terms added and subtracted, left to right.
        mutating func sum() throws -> Number {
            var value = try product()
            while let op = next, op == .plus || op == .minus {
                index += 1
                let term = try product()
                value = try op == .plus ? value + term : value - term
            }
            return value
        }

        /// Factors multiplied and divided, left to right.
        mutating func product() throws -> Number {
            var value = try signed()
            while let op = next, op == .times || op == .divide {
                index += 1
                let factor = try signed()
                value = try op == .times ? value * factor : value / factor
            }
            return value
        }

        /// Signs before a power: `-2^2` is −(2^2), `--3` is 3.
        mutating func signed() throws -> Number {
            var negative = false
            while let op = next, op == .plus || op == .minus {
                if op == .minus { negative.toggle() }
                index += 1
            }
            let value = try power()
            return negative ? -value : value
        }

        /// `a^b`, right to left (`2^3^2` is 2^9); the exponent may have a sign (`2^-1`).
        mutating func power() throws -> Number {
            let base = try percent()
            guard next == .power else { return base }
            index += 1
            try enter()
            defer { depth -= 1 }
            return try base.raised(to: try signed())
        }

        /// `50%` is 0.5.
        mutating func percent() throws -> Number {
            var value = try primary()
            while next == .percent {
                index += 1
                value = try value / .decimal(100)
            }
            return value
        }

        /// A number, a constant, a function call or an expression in parentheses.
        mutating func primary() throws -> Number {
            guard index < tokens.count else { throw CalcError.incomplete }
            let token = tokens[index]
            index += 1
            switch token.kind {
            case let .number(literal):
                return try Number(literal: literal)
            case .open:
                try enter()
                defer { depth -= 1 }
                let value = try sum()
                try close()
                return value
            case let .name(name):
                if name == "pi" { return .double(.pi) }
                if name == "e" { return .double(exp(1)) }
                guard functions.contains(name) else { throw CalcError.unknownName(shortened(token.text)) }
                // A function takes its arguments in parentheses: `sqrt(4)`, not `sqrt 4`.
                guard next == .open else { throw CalcError.badArguments(shortened(token.text)) }
                index += 1
                try enter()
                defer { depth -= 1 }
                var arguments: [Number] = []
                if next != .close {
                    arguments.append(try sum())
                    while next == .comma {
                        index += 1
                        arguments.append(try sum())
                    }
                }
                try close()
                return try call(name, arguments, typed: shortened(token.text))
            default:
                throw CalcError.unexpected(shortened(token.text))
            }
        }

        /// The `)` that ends a group or a call.
        mutating func close() throws {
            guard let kind = next else { throw CalcError.missingParenthesis }
            guard kind == .close else { throw CalcError.unexpected(shortened(tokens[index].text)) }
            index += 1
        }

        mutating func enter() throws {
            depth += 1
            if depth > maxDepth { throw CalcError.tooDeep }
        }
    }

    // MARK: - Working out

    /// A value: an exact decimal while the arithmetic keeps it one, otherwise a Double.
    enum Number: Equatable {
        case decimal(Decimal)
        case double(Double)
    }

    /// Where Decimal arithmetic is used. It holds 38 digits only from about 1e-90 on, and past its
    /// ends (1e-128, about 1e165) products and quotients can silently wrap around: there, Doubles.
    static let decimalRange: ClosedRange<Double> = 1e-90...1e125

    static func finite(_ value: Double) throws -> Double {
        guard value.isFinite else { throw CalcError.notFinite }
        return value
    }

    /// A function applied to its arguments.
    static func call(_ name: String, _ arguments: [Number], typed: String) throws -> Number {
        let wrong = CalcError.badArguments(typed)
        func only() throws -> Number {
            guard arguments.count == 1 else { throw wrong }
            return arguments[0]
        }
        func real(_ function: (Double) -> Double) throws -> Number {
            .double(try finite(function(try only().double)))
        }
        switch name {
        case "sqrt": return try real { $0.squareRoot() }
        case "ln": return try real { log($0) }
        case "log": return try real { log10($0) }
        case "exp": return try real { exp($0) }
        case "sin", "cos", "tan": return .double(try finite(trigonometry(name, try only().double)))
        case "abs": return try only().magnitude
        case "floor": return try only().rounded(scale: 0, .down)
        case "ceil": return try only().rounded(scale: 0, .up)
        case "round":
            guard (1...2).contains(arguments.count) else { throw wrong }
            var scale = 0
            if arguments.count == 2 {
                // Whole decimals to keep; negative ones round to tens, hundreds…
                guard case let .decimal(places) = arguments[1], let n = Number.wholeNumber(places), abs(n) <= 100 else { throw wrong }
                scale = n
            }
            return arguments[0].rounded(scale: scale, .plain)
        case "min", "max":
            guard var best = arguments.first else { throw wrong }
            for value in arguments.dropFirst() where name == "min" ? value < best : best < value { best = value }
            return best
        case "pow":
            guard arguments.count == 2 else { throw wrong }
            return try arguments[0].raised(to: arguments[1])
        default:
            throw CalcError.unknownName(typed)
        }
    }

    /// sin, cos or tan of `x` radians without the noise an inexact π leaves: `sin(pi)` and `cos(pi/2)`
    /// are 0, and `tan(pi/2)` is undefined. (A value that small next to `x` is that noise; for huge `x`
    /// it could be real, so those are left alone.)
    static func trigonometry(_ name: String, _ x: Double) throws -> Double {
        func clean(_ value: Double) -> Double { abs(x) < 1e9 && abs(value) < abs(x) * 1e-15 ? 0 : value }
        switch name {
        case "sin": return clean(sin(x))
        case "cos": return clean(cos(x))
        default:
            guard clean(cos(x)) != 0 else { throw CalcError.notFinite }
            return clean(sin(x)) == 0 ? 0 : tan(x)
        }
    }

    // MARK: - Writing

    /// A result as it is inserted, without float noise or trailing zeros. A whole decimal of up to 38
    /// digits is written out in full (`2^100` → `1267650600228229401496703205376`); anything else is
    /// rounded to 15 significant digits (`1/3` → `0.333333333333333`), written plainly from 1e-9 up to
    /// 1e15 and beyond that as `1.60693804425899e+60`.
    static func format(_ value: Number) -> String {
        let negative: Bool
        var digits: [Int]
        var exponent: Int  // the power of ten of the first digit
        switch value {
        case let .decimal(x):
            let text = x.description  // plain notation: "-0.00123", "391"
            negative = text.hasPrefix("-")
            let parts = text.drop(while: { $0 == "-" }).split(separator: ".", omittingEmptySubsequences: false)
            let whole = parts[0]
            var fraction = parts.count > 1 ? parts[1] : ""
            while fraction.last == "0" { fraction.removeLast() }
            if fraction.isEmpty, whole.count <= 38 { return whole.allSatisfy({ $0 == "0" }) ? "0" : (negative ? "-" : "") + whole }
            let all = (whole + fraction).compactMap(\.wholeNumberValue)
            let zeros = all.prefix(while: { $0 == 0 }).count
            digits = Array(all.dropFirst(zeros))
            exponent = whole.count - 1 - zeros
            if digits.count > 15 {
                // Half away from zero, on the digits Decimal kept.
                let up = digits[15] >= 5
                digits = Array(digits.prefix(15))
                if up {
                    var i = 14
                    while i >= 0, digits[i] == 9 {
                        digits[i] = 0
                        i -= 1
                    }
                    if i >= 0 {
                        digits[i] += 1
                    } else {
                        digits = [1] + digits.dropLast()
                        exponent += 1
                    }
                }
            }
        case let .double(x):
            let text = String(format: "%.14e", x)  // "-1.22464679914735e-16"
            negative = text.hasPrefix("-")
            let parts = text.split(separator: "e")
            digits = parts[0].compactMap(\.wholeNumberValue)
            exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        }
        while digits.last == 0 { digits.removeLast() }
        guard !digits.isEmpty else { return "0" }
        let sign = negative ? "-" : ""
        let shown = digits.map(String.init).joined()
        guard (-9..<15).contains(exponent) else {
            let mantissa = digits.count == 1 ? shown : String(shown.prefix(1)) + "." + shown.dropFirst()
            return sign + mantissa + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        }
        if exponent < 0 { return sign + "0." + String(repeating: "0", count: -exponent - 1) + shown }
        if digits.count <= exponent + 1 { return sign + shown + String(repeating: "0", count: exponent + 1 - digits.count) }
        return sign + shown.prefix(exponent + 1) + "." + shown.dropFirst(exponent + 1)
    }
}

extension Calculator.Number {
    typealias CalcError = Calculator.CalcError
    typealias DecimalOperation = (UnsafeMutablePointer<Decimal>, UnsafePointer<Decimal>, UnsafePointer<Decimal>,
                                  NSDecimalNumber.RoundingMode) -> NSDecimalNumber.CalculationError

    /// A literal from `Calculator.number`: a Decimal, exactly, when it is in `decimalRange`.
    init(literal: String) throws {
        guard let estimate = Double(literal) else { throw CalcError.unexpected(literal) }
        self = .double(try Calculator.finite(estimate))
        let parts = literal.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fraction = mantissa.count > 1 ? mantissa[1] : ""
        let digits = (mantissa[0] + fraction).drop(while: { $0 == "0" })
        if digits.isEmpty {
            self = .decimal(0)
        } else if estimate != 0, Calculator.decimalRange.contains(abs(estimate)),
                  let tens = Int(parts.count > 1 ? String(parts[1]) : "0"), let significand = Decimal(string: String(digits)) {
            let value = Decimal(sign: .plus, exponent: tens - fraction.count, significand: significand)
            if !value.isNaN { self = .decimal(value) }
        }
    }

    var double: Double {
        switch self {
        case let .decimal(value): return Double(value.description) ?? .nan
        case let .double(value): return value
        }
    }

    var isZero: Bool {
        switch self {
        case let .decimal(value): return value.isZero
        case let .double(value): return value == 0
        }
    }

    var magnitude: Self {
        switch self {
        case let .decimal(value): return .decimal(abs(value))
        case let .double(value): return .double(abs(value))
        }
    }

    /// `operation` on two decimals while the result stays in `decimalRange`, else `double` on Doubles.
    /// A product or quotient must also agree with the Double estimate (`checked`), in case Decimal
    /// arithmetic went wrong without saying so.
    static func combine(_ a: Self, _ b: Self, checked: Bool, _ operation: DecimalOperation,
                        _ double: (Double, Double) -> Double) throws -> Self {
        let estimate = double(a.double, b.double)
        if case var .decimal(x) = a, case var .decimal(y) = b, estimate == 0 || Calculator.decimalRange.contains(abs(estimate)) {
            var result = Decimal()
            let status = operation(&result, &x, &y, .plain)
            if status == .noError || status == .lossOfPrecision, !result.isNaN, !checked || agrees(result, estimate) {
                return .decimal(result)
            }
        }
        return .double(try Calculator.finite(estimate))
    }

    static func agrees(_ value: Decimal, _ estimate: Double) -> Bool {
        abs(Self.decimal(value).double - estimate) <= abs(estimate) * 1e-9
    }

    /// A sum of Doubles that cancels to within their rounding error is 0: `sqrt(2)^2 - 2`.
    static func cancelled(_ sum: Double, _ x: Double, _ y: Double) -> Double {
        abs(sum) < max(abs(x), abs(y)) * 1e-15 ? 0 : sum
    }

    static func + (a: Self, b: Self) throws -> Self {
        try combine(a, b, checked: false, NSDecimalAdd) { cancelled($0 + $1, $0, $1) }
    }

    static func - (a: Self, b: Self) throws -> Self {
        try combine(a, b, checked: false, NSDecimalSubtract) { cancelled($0 - $1, $0, $1) }
    }

    static func * (a: Self, b: Self) throws -> Self {
        try combine(a, b, checked: true, NSDecimalMultiply, *)
    }

    static func / (a: Self, b: Self) throws -> Self {
        guard !b.isZero else { throw CalcError.divisionByZero }
        return try combine(a, b, checked: true, NSDecimalDivide, /)
    }

    static prefix func - (a: Self) -> Self {
        switch a {
        case let .decimal(value): return .decimal(-value)
        case let .double(value): return .double(-value)
        }
    }

    static func < (a: Self, b: Self) -> Bool {
        if case let .decimal(x) = a, case let .decimal(y) = b { return x < y }
        return a.double < b.double
    }

    /// A whole number within ±1e15, as an Int.
    static func wholeNumber(_ value: Decimal) -> Int? {
        guard abs(value) <= 1_000_000_000_000_000 else { return nil }
        var rounded = Decimal()
        var x = value
        NSDecimalRound(&rounded, &x, 0, .plain)
        return rounded == value ? Int(rounded.description) : nil
    }

    /// `self` to the power `exponent`: exact for a decimal to a whole power in `decimalRange`,
    /// otherwise `pow` on Doubles.
    func raised(to exponent: Self) throws -> Self {
        let estimate = pow(double, exponent.double)
        if isZero, estimate.isInfinite { throw CalcError.divisionByZero }  // 0^-1
        if case let .decimal(base) = self, case let .decimal(whole) = exponent, let n = Self.wholeNumber(whole),
           estimate == 0 ? base.isZero : Calculator.decimalRange.contains(abs(estimate)),
           let exact = Self.power(base, n), Self.agrees(exact, estimate) {
            return .decimal(exact)
        }
        return .double(try Calculator.finite(estimate))
    }

    /// `base` to the whole power `n` in Decimal arithmetic, or nil if that fails.
    static func power(_ base: Decimal, _ n: Int) -> Decimal? {
        var result = Decimal()
        var x = base
        let status = NSDecimalPower(&result, &x, abs(n), .plain)
        guard status == .noError || status == .lossOfPrecision, !result.isNaN else { return nil }
        guard n < 0 else { return result }
        var one = Decimal(1)
        var quotient = Decimal()
        let divided = NSDecimalDivide(&quotient, &one, &result, .plain)
        return (divided == .noError || divided == .lossOfPrecision) && !quotient.isNaN ? quotient : nil
    }

    /// Rounded to `scale` decimals (negative: to tens, hundreds…). `.plain` rounds halves away from
    /// zero; `.down` and `.up` are floor and ceiling.
    func rounded(scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Self {
        switch self {
        case var .decimal(value):
            var result = Decimal()
            NSDecimalRound(&result, &value, scale, mode)
            return .decimal(result)
        case let .double(value):
            let factor = pow(10, Double(scale))
            let scaled = value * factor
            // From 2^53 on every Double is whole: nothing left to round there.
            guard scaled.isFinite, abs(scaled) < 9_007_199_254_740_992 else { return self }
            let rule: FloatingPointRoundingRule = mode == .down ? .down : mode == .up ? .up : .toNearestOrAwayFromZero
            return .double(scaled.rounded(rule) / factor)
        }
    }
}
