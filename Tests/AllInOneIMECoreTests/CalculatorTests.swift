import Foundation
import Testing
@testable import AllInOneIMECore

struct CalculatorTests {
    typealias CalcError = Calculator.CalcError

    func calc(_ expression: String) -> String {
        do {
            return try Calculator.evaluate(expression)
        } catch {
            return "error: \(error)"
        }
    }

    func failure(_ expression: String) -> CalcError? {
        do {
            _ = try Calculator.evaluate(expression)
            return nil
        } catch {
            return error as? CalcError
        }
    }

    func check(_ table: [(String, String)]) {
        for (expression, result) in table {
            #expect(calc(expression) == result, "\(expression)")
        }
    }

    // MARK: - The evaluator

    @Test func precedenceAndAssociativity() {
        check([
            ("23*17", "391"), ("1+2*3", "7"), ("(1+2)*3", "9"), ("2*3+4*5", "26"), ("2+3*4^2", "50"),
            ("10-4-3", "3"), ("1-2+3", "2"), ("100/10/5", "2"), ("8/2*4", "16"), ("7/2", "3.5"),
            ("(2+3)*(4-1)/5", "3"), ("((((1))))", "1"),
        ])
    }

    @Test func powers() {
        check([
            ("2^10", "1024"), ("2**10", "1024"), ("pow(2, 10)", "1024"),
            ("2^3^2", "512"), ("2**3**2", "512"), ("(2^3)^2", "64"),  // right to left
            ("-2^2", "-4"), ("(-2)^2", "4"), ("(-2)^3", "-8"),        // the power before the sign
            ("2^-1", "0.5"), ("2^-2^2", "0.0625"), ("2^-10", "0.0009765625"),
            ("1.5^2", "2.25"), ("0^0", "1"), ("10^20", "100000000000000000000"),
            ("2^100", "1267650600228229401496703205376"),
            ("4^0.5", "2"), ("2^0.5", "1.4142135623731"), ("27^(1/3)", "3"),
        ])
        #expect(calc("pow(2, 0.5)") == calc("2^0.5"))
    }

    @Test func signs() {
        check([
            ("-3", "-3"), ("--3", "3"), ("+5", "5"), ("2--3", "5"), ("3-+2", "1"), ("2*-3", "-6"),
            ("-2*-2", "4"), ("-(2+3)", "-5"), ("-0", "0"), ("-0.0", "0"),
        ])
    }

    @Test func percent() {
        check([
            ("50%", "0.5"), ("12.5%", "0.125"), ("200*5%", "10"), ("50%*200", "100"), ("(1+1)%", "0.02"),
            ("-50%", "-0.5"), ("10%%", "0.001"),
            ("200+5%", "200.05"),  // a percent is just a number: 5% is 0.05
        ])
    }

    @Test func decimalsAreExact() {
        check([
            ("0.1+0.2", "0.3"), ("0.3-0.1", "0.2"), ("0.1+0.2-0.3", "0"), ("0.1+0.7", "0.8"), ("1.1*3", "3.3"),
            ("4.35*100", "435"), ("1.15*100", "115"), ("19.99*3", "59.97"), ("10/4", "2.5"), ("1/1024", "0.0009765625"),
            ("1e30+1", "1000000000000000000000000000001"),
            // Not exact: 15 significant digits, rounded.
            ("1/3", "0.333333333333333"), ("2/3", "0.666666666666667"), ("1/7", "0.142857142857143"), ("1/3*3", "1"),
            ("1.5^20", "3325.25673007965"), ("12345678901234.5+0.01", "12345678901234.5"),
        ])
    }

    @Test func functionsAndConstants() {
        check([
            ("sqrt(16)", "4"), ("sqrt(2)", "1.4142135623731"), ("abs(-5.5)", "5.5"), ("abs(3)", "3"),
            ("round(2.5)", "3"), ("round(-2.5)", "-3"), ("round(2.4)", "2"), ("round(3.14159, 2)", "3.14"),
            ("round(2.675, 2)", "2.68"), ("round(1234.5, -2)", "1200"), ("round(sqrt(2), 3)", "1.414"),
            ("floor(2.7)", "2"), ("floor(-2.5)", "-3"), ("ceil(2.1)", "3"), ("ceil(-2.5)", "-2"),
            ("ln(1)", "0"), ("ln(e)", "1"), ("log(1000)", "3"), ("log(0.01)", "-2"), ("exp(0)", "1"),
            ("exp(1)", "2.71828182845905"), ("exp(ln(5))", "5"),
            ("e", "2.71828182845905"), ("pi", "3.14159265358979"), ("π", "3.14159265358979"), ("2*pi", "6.28318530717959"),
            ("PI", "3.14159265358979"), ("SQRT(4)", "2"), ("Max(1, 2)", "2"),  // any case
            ("min(3, 1, 2)", "1"), ("max(3, 1, 2)", "3"), ("min(5)", "5"), ("max(-1, -2)", "-1"),
            ("max(sqrt(16), abs(-5))", "5"), ("min(0.1+0.2, 0.3)", "0.3"),
        ])
    }

    @Test func noFloatNoise() {
        // Radians; what an inexact π leaves behind is taken out.
        check([
            ("sin(0)", "0"), ("sin(pi/2)", "1"), ("sin(pi)", "0"), ("sin(-pi)", "0"), ("sin(2*pi)", "0"),
            ("sin(pi/6)", "0.5"), ("cos(0)", "1"), ("cos(pi)", "-1"), ("cos(pi/2)", "0"), ("cos(pi/3)", "0.5"),
            ("tan(0)", "0"), ("tan(pi/4)", "1"), ("tan(pi)", "0"), ("sin(1e-20)", "1e-20"),
            ("sqrt(2)^2", "2"), ("sqrt(2)^2-2", "0"), ("0.1*3", "0.3"),
        ])
    }

    @Test func fullWidthInputFromChineseTyping() {
        check([
            ("２３＊１７", "391"), ("（１＋２）×３", "9"), ("１０÷４", "2.5"), ("３．５＋１", "4.5"), ("５０％", "0.5"),
            ("ｍａｘ（１，２）", "2"), ("max(1，2)", "2"), ("2　+　3", "5"), ("6 − 2", "4"), ("2＾3", "8"), ("2＊＊3", "8"),
            ("１－（－２）", "3"), ("２３×１７＝", "391"),
        ])
        #expect(failure("2××3") == .unexpected("×"))  // × twice isn't a power
    }

    @Test func spacesNumbersAndAnEqualsSign() {
        check([
            (" 1 + 2 ", "3"), ("23*17=", "391"), ("23 * 17 = ", "391"),
            ("1e3", "1000"), ("1.5e-3", "0.0015"), ("2E+2", "200"), ("1e3*2", "2000"), (".5+.5", "1"), ("5.+1", "6"),
            ("007", "7"), ("0.10", "0.1"), ("2.50*2", "5"), ("1.50+1", "2.5"), ("1000/10", "100"),
        ])
    }

    @Test func errors() {
        let table: [(String, CalcError)] = [
            ("", .empty), ("   ", .empty), ("=", .empty),
            ("1/0", .divisionByZero), ("1/(2-2)", .divisionByZero), ("5/0.0", .divisionByZero), ("0^-1", .divisionByZero),
            ("1/sin(0)", .divisionByZero), ("1/(sqrt(2)^2-2)", .divisionByZero),
            ("1+", .incomplete), ("-", .incomplete), ("2^", .incomplete), ("sqrt(", .incomplete),
            ("(1+2", .missingParenthesis), ("max(1, 2", .missingParenthesis),
            ("1+*2", .unexpected("*")), ("(1+2))", .unexpected(")")), (")", .unexpected(")")), ("()", .unexpected(")")),
            ("1,2", .unexpected(",")), ("2 3", .unexpected("3")), ("1.2.3", .unexpected(".3")), ("2pi", .unexpected("pi")),
            ("5元", .unexpected("元")), ("1=2", .unexpected("=")), ("2e", .unexpected("e")), ("max(1,)", .unexpected(")")),
            ("7 & 3", .unexpected("&")),
            ("foo(2)", .unknownName("foo")), ("x+1", .unknownName("x")), ("log10(5)", .unknownName("log10")),
            ("e2", .unknownName("e2")),
            ("pow(2)", .badArguments("pow")), ("sqrt(1, 2)", .badArguments("sqrt")), ("max()", .badArguments("max")),
            ("sqrt 4", .badArguments("sqrt")), ("Sqrt", .badArguments("Sqrt")), ("round(1, 0.5)", .badArguments("round")),
            ("round(1, 2, 3)", .badArguments("round")),
            ("sqrt(-1)", .notFinite), ("ln(0)", .notFinite), ("ln(-1)", .notFinite), ("log(0)", .notFinite),
            ("tan(pi/2)", .notFinite), ("10^400", .notFinite), ("1e400", .notFinite), ("exp(1000)", .notFinite),
            ("(-8)^(1/3)", .notFinite), ("9^9^9", .notFinite),
        ]
        for (expression, error) in table {
            #expect(failure(expression) == error, "\(expression)")
        }
        // A long token is shortened in the message.
        #expect(failure("1 " + String(repeating: "9", count: 40)) == .unexpected(String(repeating: "9", count: 16) + "…"))
        // In English for logs; the input method describes them in the interface language (UIText).
        #expect(CalcError.divisionByZero.errorDescription == "Division by zero")
        #expect(CalcError.unexpected("*").errorDescription == "Invalid expression near \"*\"")
        #expect(CalcError.tooLong.errorDescription == "The expression is too long: 1000 characters at most")
        #expect(CalcError.notFinite.errorDescription == "The result isn't a finite real number")
    }

    @Test func limits() async {
        // Length.
        #expect(calc(String(repeating: "1+", count: 499) + "1") == "500")
        #expect(failure(String(repeating: "1+", count: 500) + "1") == .tooLong)
        #expect(failure(String(repeating: "(", count: 100_000)) == .tooLong)
        // Nesting: parentheses, calls and powers each count.
        func nested(_ n: Int, _ open: String, _ inner: String, _ close: String) -> String {
            String(repeating: open, count: n) + inner + String(repeating: close, count: n)
        }
        let depth = Calculator.maxDepth
        #expect(calc(nested(depth, "(", "1", ")")) == "1")
        #expect(failure(nested(depth + 1, "(", "1", ")")) == .tooDeep)
        #expect(calc(nested(depth, "abs(", "-1", ")")) == "1")
        #expect(failure(nested(depth + 1, "abs(", "-1", ")")) == .tooDeep)
        #expect(calc(Array(repeating: "1", count: depth + 1).joined(separator: "^")) == "1")
        #expect(failure(Array(repeating: "1", count: depth + 2).joined(separator: "^")) == .tooDeep)
        #expect(failure(String(repeating: "(", count: 999)) == .tooDeep)  // stops at once
        // Runs of signs and operators are loops, not recursion.
        #expect(calc(String(repeating: "-", count: 999) + "1") == "-1")
        #expect(calc("0" + String(repeating: "+1", count: 499)) == "499")
        // The deepest allowed nesting is fine on a secondary thread's smaller stack too.
        let deep = nested(depth, "(-", "2", ")")
        let result = await Task.detached { try? Calculator.evaluate(deep) }.value
        #expect(result == "2")
    }

    @Test func formatting() {
        check([
            // Whole numbers of up to 38 digits are written out, exactly.
            ("99999999999999999999+1", "100000000000000000000"),
            ("123456789012345678901234567890*10", "1234567890123456789012345678900"),
            ("2^126", "85070591730234615865843651857942052864"), ("-2^100", "-1267650600228229401496703205376"),
            // Longer ones, and anything not exact: 15 significant digits.
            ("2^127", "1.70141183460469e+38"), ("2^200", "1.60693804425899e+60"), ("10^50", "1e+50"),
            ("123456789012345678.5", "1.23456789012346e+17"), ("sqrt(1e30)", "1e+15"),
            ("exp(10)", "22026.4657948067"), ("-1/3", "-0.333333333333333"),
            // Small numbers: plain down to 1e-9.
            ("1/1000", "0.001"), ("0.1^9", "0.000000001"), ("0.1^10", "1e-10"), ("1/3/1000000000", "3.33333333333333e-10"),
            // Beyond what a Decimal holds: Doubles (Decimal arithmetic would wrap around: 1e-65 * 1e-65 = 1e127).
            ("10^200", "1e+200"), ("2^-500", "3.0549363634996e-151"), ("1e-65*1e-65", "1e-130"), ("1e100*1e100", "1e+200"),
            ("1e300/1e-5", "1e+305"), ("0.5^100000", "0"),
        ])
        #expect(Calculator.format(.double(-0.0)) == "0" && Calculator.format(.decimal(0)) == "0")
    }

    @Test func aStreamLikeTheOtherCommands() async throws {
        var results: [String] = []
        for try await update in Calculator.stream("23*17") {
            #expect(update.isFinal && !update.fromCache)
            results.append(update.result.versions.first?.text ?? "")
        }
        #expect(results == ["391"])
        await #expect(throws: CalcError.divisionByZero) {
            for try await _ in Calculator.stream("1/0") {}
        }
    }

    // MARK: - The command

    @Test func aBuiltInCommandThatRunsInsideATextToo() {
        #expect(Command.builtins.contains(.calc) && Command.calc.kind == .run && CommandPlan.canBeInner(.calc))
        #expect(Command.calc.typesLatin && Command.calc.program == nil)  // ASCII typing; never hidden
        #expect(Command.parse("@calc 23*17")! == (.calc, "23*17"))
        // A custom command named calc gives way to the built-in one, and the editor won't take the name.
        let custom = CustomCommand(name: "calc", type: .run, argv: ["bc", "-l"], stdin: "{input}\n")
        #expect(Command.catalog([custom]).filter { $0.name == "calc" } == [.calc])
        #expect(custom.problem(among: []) == .nameTaken)
        // In the list: "@c" offers it after @claude, "@ca" only it.
        #expect(Command.palette("c", in: Command.builtins, usage: CommandUsage()).map(\.name) == ["claude", "calc"])
        #expect(Command.palette("ca", in: Command.builtins, usage: CommandUsage()) == [.calc])
    }

    func arguments(_ text: String) -> [String] {
        CommandPlan.make(text, commands: Command.builtins).inner.filter { $0.command == .calc }.map(\.argument)
    }

    @Test func insideATextItsArgumentIsTheExpression() {
        let plan = CommandPlan.make("总价是 @calc 23*17 元", commands: Command.builtins)
        #expect(plan.parts == [.text("总价是 "), .inner(0), .text(" 元")])
        #expect(plan.input(outputs: ["391"]) == "总价是 391 元")
        // Spaces, full-width signs and function names are in it; other text, words and sentence punctuation aren't.
        #expect(arguments("总价 @calc 23 * 17 元") == ["23 * 17"])
        #expect(arguments("@calc 2 * pi is about 6.28") == ["2 * pi"])
        #expect(arguments("大约 @calc （１＋２）×３，对吧") == ["（１＋２）×３"])
        #expect(arguments("@calc sqrt(2)+1 左右") == ["sqrt(2)+1"])
        #expect(arguments("@calc max(1, 2), then") == ["max(1, 2)"])
        #expect(arguments("（总价 @calc 23*17）") == ["23*17"])
        #expect(arguments("@calc 5%的利润") == ["5%"])
        #expect(arguments("@calc 1e3 m") == ["1e3"])
        #expect(arguments("@calc 23*17kg") == ["23*17"])
        let period = CommandPlan.make("It is @calc 23*17. Done", commands: Command.builtins)
        #expect(period.inner.map(\.argument) == ["23*17"] && period.input(outputs: ["391"]) == "It is 391. Done")
        // Quotes mark it exactly, as for any command.
        #expect(arguments("@calc「2 * pi」") == ["2 * pi"])
        #expect(arguments(#"@calc "1 + 2" apples"#) == ["1 + 2"])
        // No expression: plain text.
        for text in ["@calc hello", "@calc 现在", "a@calc 1+1", "@calc", "@calc ,1"] {
            #expect(CommandPlan.make(text, commands: Command.builtins).isEmpty, "\(text)")
        }
    }

    // MARK: - In the composer

    let at = KeyEvent(keyCode: 0x13, characters: "@", charactersIgnoringModifiers: "@", modifiers: .shift)
    let tab = KeyEvent(keyCode: VirtualKey.tab, characters: "\t")

    /// Types `text` key by key ("@" and spaces with their keys).
    func typeKeys(_ text: String, _ composer: Composer) {
        for ch in text {
            _ = composer.handleKeyDown(ch == "@" ? at : ch == " " ? spaceKey : k(String(ch)))
        }
    }

    func answer(_ text: String) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ConversionUpdate(result: ConversionResult(versions: [CandidateLine(text)]), rawText: text,
                                                isFinal: true, elapsed: 0, firstTokenLatency: nil, fromCache: false))
            continuation.finish()
        }
    }

    @Test func composerRunsIt() async throws {
        let engine = FakeEngine()
        let c = Composer(engine: engine)
        _ = c.handleKeyDown(at)
        typeKeys("ca", c)
        #expect(c.paletteMatches == [.calc])
        _ = c.handleKeyDown(tab)
        #expect(c.draft == "@calc " && engine.ascii)  // digits and signs come out half-width
        typeKeys("23*17", c)
        #expect(c.markedText == "calc › 23*17")
        let effects = c.handleKeyDown(enterKey).effects
        // A run like @read: the controller refuses it during secure input, else streams Calculator.stream.
        #expect(effects.first == .startRun(.calc, input: "23*17", id: 1) && effects.contains(.commandUsed("calc")))
        #expect(c.activeCommand == .calc)
        for try await update in Calculator.stream("23*17") {
            _ = c.receive(update.result, isFinal: update.isFinal, id: 1)
        }
        // The result is the candidate (0 is the expression as typed); ⏎ inserts it and Chinese comes back.
        #expect(c.choices.map(\.text) == ["23*17", "391"] && c.choices.map(\.kind) == [.original, .answer])
        #expect(c.highlighted == 1)
        #expect(commits(c.handleKeyDown(enterKey)) == ["391"] && !engine.ascii && !c.isComposing)
        // A mistake is a failure to show; Esc goes back to the expression.
        let d = Composer(engine: FakeEngine())
        typeKeys("@calc 1/0", d)
        #expect(d.handleKeyDown(enterKey).effects.first == .startRun(.calc, input: "1/0", id: 1))
        _ = d.fail(CalcError.divisionByZero.errorDescription!, id: 1)
        #expect(d.phase == .failed("Division by zero"))
        _ = d.handleKeyDown(escKey)
        #expect(d.draft == "@calc 1/0" && !d.isLevelTwo)
    }

    @Test func composerRunsItInsideAText() async throws {
        let c = Composer(engine: FakeEngine())
        c.setInputMode(.english)
        typeKeys("@question 总价是 @", c)
        #expect(c.paletteMatches.map(\.name) == ["read", "calc", "py", "js"])  // what runs inside a text
        typeKeys("calc 23*17 元", c)
        #expect(c.draft == "@question 总价是 @calc 23*17 元")
        let effects = c.handleKeyDown(enterKey).effects
        guard case let .startPlan(outer, plan, id)? = effects.first else {
            Issue.record("expected a plan, got \(effects)")
            return
        }
        #expect(outer == .question && id == 1 && plan.inner == [CommandPlan.Inner(command: .calc, argument: "23*17")])
        #expect(effects.contains(.commandUsed("question")) && effects.contains(.commandUsed("calc")))
        #expect(Calculator.failure(in: plan) == nil)
        // The pipeline as the controller runs it: @calc first, then the outer command on the result.
        let stream = CommandPipeline.run(plan, inner: { command, argument in
            command == .calc ? Calculator.stream(argument) : self.answer("?")
        }, outer: { text in self.answer("asked: " + text) })
        var final = ""
        for try await update in stream where update.isFinal { final = update.result.versions.first?.text ?? "" }
        #expect(final == "asked: 总价是 391 元")

        // Even inside @calc's own text.
        let twice = CommandPlan.make("1 + @calc 2*3", commands: Command.builtins)
        var sum = ""
        for try await update in CommandPipeline.run(twice, inner: { Calculator.stream($1) }, outer: { Calculator.stream($0) }) {
            sum = update.result.versions.first?.text ?? ""
        }
        #expect(sum == "7")
    }

    @Test func aMistakeInsideATextIsFoundBeforeRunning() async {
        let plan = CommandPlan.make("总价是 @calc 23/0 元，@read example.com", commands: Command.builtins)
        #expect(plan.inner.map(\.command) == [.calc, .read])
        // The controller reports this at once, in the interface language: "@calc：不能除以 0".
        #expect(Calculator.failure(in: plan) == .divisionByZero)
        #expect(Calculator.failure(in: CommandPlan.make("总价是 @calc 23*17 元", commands: Command.builtins)) == nil)
        #expect(Calculator.failure(in: CommandPlan.make("告诉他 @read example.com", commands: Command.builtins)) == nil)
        // Through the pipeline the error still says which command failed.
        let failing = CommandPipeline.run(CommandPlan.make("@calc 1/0", commands: Command.builtins),
                                          inner: { Calculator.stream($1) }, outer: { self.answer($0) })
        await #expect(throws: CommandPipelineError.inner("calc", "Division by zero")) {
            for try await _ in failing {}
        }
    }
}
