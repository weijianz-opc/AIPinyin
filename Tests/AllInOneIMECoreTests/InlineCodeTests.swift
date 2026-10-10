import Foundation
import Testing
@testable import AllInOneIMECore

/// `@py` and `@js` (`InlineCode`): a line of code run in a child process, REPL style.
struct InlineCodeTests {
    let at = KeyEvent(keyCode: 0x13, characters: "@", charactersIgnoringModifiers: "@", modifiers: .shift)
    let tab = KeyEvent(keyCode: VirtualKey.tab, characters: "\t")

    /// Types `text` key by key ("@" with Shift, spaces as the space bar).
    func typeKeys(_ text: String, _ c: Composer) {
        for ch in text { _ = c.handleKeyDown(ch == "@" ? at : ch == " " ? spaceKey : k(String(ch))) }
    }

    // MARK: - The programs

    @Test func definitions() throws {
        let py = try #require(InlineCode.definition(for: .py))
        #expect(py.argv == ["python3", "-X", "utf8", "-c", InlineCode.pythonREPL])
        #expect(py.type == .run && py.typesLatin && py.timeout == CustomCommand.defaultTimeout)
        // The code goes on standard input with full-width punctuation as ASCII; the arguments never change.
        #expect(py.standardInput(for: "print（“牛逼”）") == "print(\"牛逼\")")
        #expect(py.arguments(for: "print（“牛逼”）") == py.argv && py.arguments(for: "{input}") == py.argv)
        // @js: this app's own executable as the child process.
        let js = try #require(InlineCode.definition(for: .js, executable: "/Apps/AllInOneIME.app/Contents/MacOS/AllInOneIME"))
        #expect(js.argv == ["/Apps/AllInOneIME.app/Contents/MacOS/AllInOneIME", "--run-js"])
        #expect(js.arguments(for: "{input}") == js.argv && js.standardInput(for: "[1，2].map(x => x * 2)") == "[1,2].map(x => x * 2)")
        #expect(js.timeout == CustomCommand.defaultTimeout && js.typesLatin)
        // Nothing else is code: not the other built-in commands, not a custom one running python3.
        for command in Command.builtins where !command.isCode { #expect(InlineCode.definition(for: command) == nil) }
        let custom = Command.catalog([CustomCommand(name: "python", type: .run, argv: ["python3", "-c", "{input}"])])
        #expect(InlineCode.definition(for: try #require(custom.last)) == nil)
    }

    @Test func builtInCommands() {
        #expect(Command.builtins.contains(.py) && Command.builtins.contains(.js) && Command.py.kind == .run && Command.js.kind == .run)
        #expect(Command.py.isCode && Command.js.isCode && !Command.read.isCode && !Command.question.isCode)
        #expect(Command.py.typesLatin && Command.js.typesLatin)
        // @py is offered only where python3 runs; @js needs nothing but this app.
        #expect(Command.py.program == "python3" && Command.js.program == nil)
        // Built-in names: the editor refuses them, and a custom command of that name gives way.
        #expect(CustomCommand(name: "py", type: .run, argv: ["python3", "-c", "{input}"]).problem(among: []) == .nameTaken)
        let catalog = Command.catalog([CustomCommand(name: "js", type: .run, argv: ["node", "-p", "{input}"])])
        #expect(catalog.filter { $0.name == "js" } == [.js])
        #expect(CommandPlan.canBeInner(.py) && CommandPlan.canBeInner(.js))
    }

    // MARK: - In the composer

    @Test func pickedFromTheListAndRun() {
        let c = Composer(engine: FakeEngine())  // ⏎ is the action key
        _ = c.handleKeyDown(at)
        typeKeys("p", c)
        #expect(c.paletteMatches.first == .py)
        _ = c.handleKeyDown(tab)
        #expect(c.draft == "@py " && c.engineState.isAsciiMode)  // code is typed as letters
        typeKeys("2**100", c)
        #expect(c.markedText == "py › 2**100")
        let effects = c.handleKeyDown(enterKey).effects
        // A run like a custom program's (the controller refuses `.startRun` during secure input).
        #expect(effects.first == .startRun(.py, input: "2**100", id: 1))
        #expect(effects.contains(.commandUsed("py")) && c.activeCommand == .py && c.phase == .translating(id: 1))
        _ = c.receive(ConversionResult(versions: [CandidateLine("1267650600228229401496703205376")]), isFinal: true, id: 1)
        #expect(c.choices.map(\.kind) == [.original, .answer] && c.highlighted == 1)
        #expect(c.choices.first?.text == "2**100")  // 0: the code as typed
        #expect(commits(c.handleKeyDown(enterKey)) == ["1267650600228229401496703205376"])
        #expect(!c.engineState.isAsciiMode)  // Chinese is back

        let j = Composer(engine: FakeEngine())
        _ = j.handleKeyDown(at)
        typeKeys("j", j)
        #expect(j.paletteMatches == [.js])
        _ = j.handleKeyDown(tab)
        typeKeys("[1,2].map(x => x * 2)", j)
        #expect(j.handleKeyDown(enterKey).effects.first == .startRun(.js, input: "[1,2].map(x => x * 2)", id: 1))
        // Esc while it runs stops it and goes back to the code.
        #expect(j.handleKeyDown(escKey).effects.first == .cancelConversion && j.draft == "@js [1,2].map(x => x * 2)")
    }

    @Test func insideAnotherCommandsText() {
        let catalog = Command.catalog([CustomCommand(name: "reply", type: .prompt, prompt: "Reply.")])
        let engine = FakeEngine()
        let c = Composer(engine: engine)
        c.commands = catalog
        _ = c.handleKeyDown(at)
        typeKeys("rep", c)
        _ = c.handleKeyDown(tab)
        typeKeys("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(at)
        #expect(c.paletteMatches.map(\.name) == ["read", "calc", "py", "js", "search"])  // the commands that run inside a text
        typeKeys("p", c)
        _ = c.handleKeyDown(tab)
        #expect(c.draft == "@reply 你好@py " && engine.ascii)
        typeKeys("2**100", c)
        let effects = c.handleKeyDown(enterKey).effects
        guard case let .startPlan(outer, plan, _)? = effects.first else {
            Issue.record("expected a plan, got \(effects)")
            return
        }
        #expect(outer?.name == "reply" && plan.inner.map(\.command) == [.py] && plan.inner.map(\.argument) == ["2**100"])
        #expect(plan.input(outputs: ["1267650600228229401496703205376"]) == "你好1267650600228229401496703205376")
        #expect(effects.contains(.commandUsed("reply")) && effects.contains(.commandUsed("py")))
        // Code with spaces in it is quoted.
        let quoted = CommandPlan.make("答案是 @py「sum(x * x for x in range(4))」吧，还有 @js \"[1, 2].map(x => x * 2)\"", commands: catalog)
        #expect(quoted.inner.map(\.argument) == ["sum(x * x for x in range(4))", "[1, 2].map(x => x * 2)"])
    }

    @Test func codeRunsExactlyAsTyped() {
        let catalog = Command.catalog([CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])])
        let c = Composer(engine: FakeEngine())
        c.commands = catalog
        c.setInputMode(.english)
        typeKeys("@py x = \"@", c)
        #expect(c.draft == "@py x = \"@" && c.paletteQuery == nil)  // no command list inside code
        typeKeys("stock AAPL\"; x", c)
        #expect(c.markedText == "py › x = \"＠stock AAPL\"; x")  // not shown as a command either
        // No other command runs first: nothing they return (a web page, a program's output) is executed.
        let effects = c.handleKeyDown(enterKey).effects
        #expect(effects.first == .startRun(.py, input: "x = \"@stock AAPL\"; x", id: 1))
        #expect(!effects.contains(.commandUsed("stock")))
        let read = Composer(engine: FakeEngine())
        read.setInputMode(.english)
        typeKeys("@js \"@read https://example.com\"", read)
        #expect(read.handleKeyDown(enterKey).effects.first == .startRun(.js, input: "\"@read https://example.com\"", id: 1))
    }

    @Test func codeThatPrintsNothing() {
        func ran(_ code: String, messages: Composer.Messages = .chinese) -> Composer {
            let c = Composer(engine: FakeEngine())
            c.messages = messages
            c.setInputMode(.english)
            typeKeys(code, c)
            _ = c.handleKeyDown(enterKey)
            _ = c.receive(.empty, isFinal: true, id: 1)
            return c
        }
        #expect(ran("@py x = 5").phase == .failed("代码没有输出：最后写一个表达式，或者把结果打印出来"))
        #expect(ran("@js let y = 1", messages: .english).phase
            == .failed("The code printed nothing: end it with an expression, or print the result"))
        #expect(ran("@read example.com").phase == .failed("没有得到结果"))  // other commands as before
    }

    @Test func hiddenWithoutTheirProgram() {
        // The controller leaves out the commands whose program isn't installed (`setCommands`)…
        let missing = Set(Command.builtins.compactMap { command in
            command.program.flatMap { CommandRunner.isInstalled($0, path: "/nowhere") ? nil : command.name }
        })
        #expect(missing == ["claude", "py"])  // @js needs no program
        let c = Composer(engine: FakeEngine())
        c.commands = Command.builtins.filter { !missing.contains($0.name) }
        // …so the list doesn't offer @py, and "@py …" is plain text.
        _ = c.handleKeyDown(at)
        typeKeys("p", c)
        #expect(!c.paletteMatches.contains(.py) && !c.paletteMatches.isEmpty)
        #expect(Command.parse("@py 1+1", in: c.commands) == nil && Command.parse("@js 1+1", in: c.commands)?.command == .js)
    }

    // MARK: - Developer tool stand-ins

    @Test func standInsCountOnlyWithTheDeveloperTools() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("inline-code-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let standIn = folder.appendingPathComponent("stand-in")
        let other = folder.appendingPathComponent("other")
        try Data("#!/bin/sh\n".utf8).write(to: standIn)
        try Data("#!/bin/sh\n".utf8).write(to: other)
        let hardLink = folder.appendingPathComponent("python3")
        try fm.linkItem(at: standIn, to: hardLink)
        let symbolicLink = folder.appendingPathComponent("git")
        try fm.createSymbolicLink(at: symbolicLink, withDestinationURL: hardLink)
        // One file under several names, also through a symbolic link.
        #expect(DeveloperTools.isStandIn(hardLink, standIn: standIn.path) && DeveloperTools.isStandIn(symbolicLink, standIn: standIn.path))
        #expect(!DeveloperTools.isStandIn(other, standIn: standIn.path))
        #expect(!DeveloperTools.isStandIn(folder.appendingPathComponent("missing"), standIn: standIn.path))
        // The tools are there when a developer folder has its usr/bin.
        let tools = folder.appendingPathComponent("CommandLineTools")
        try fm.createDirectory(at: tools.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        #expect(DeveloperTools.installed(in: [folder.appendingPathComponent("Xcode").path, tools.path]))
        #expect(!DeveloperTools.installed(in: [folder.appendingPathComponent("Xcode").path]) && !DeveloperTools.installed(in: []))
        #expect(DeveloperTools.folders.suffix(2) == ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"])
        // /usr/bin/python3 is a stand-in: it counts only with Xcode or the command line tools.
        #expect(!CommandRunner.isInstalled("python3", path: "/usr/bin", developerFolders: []))
        #expect(CommandRunner.isInstalled("python3", path: "/usr/bin", developerFolders: [tools.path])
            == fm.isExecutableFile(atPath: "/usr/bin/python3"))
        #expect(CommandRunner.isInstalled("sh", path: "/bin", developerFolders: []))  // a program of its own
        #expect(!CommandRunner.isInstalled("no-such-program-here", path: "/bin:/usr/bin"))
    }

    // MARK: - Python

    /// The folders with a python3 that would run (none: the Python tests are skipped), one per interpreter.
    static let pythons: [String] = {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":" + ShellEnvironment.fallbackPath
        var seen = Set<String>()
        return path.split(separator: ":").map(String.init).filter { folder in
            guard CommandRunner.isInstalled("python3", path: folder),
                  let url = CommandRunner.resolve("python3", path: folder) else { return false }
            return seen.insert(url.resolvingSymlinksInPath().path).inserted
        }
    }()

    /// `code` through `@py`'s program, the way the input method runs it, with the python3 in `folder`.
    func python(_ code: String, in folder: String, timeout: Double? = nil) async -> Result<String, Error> {
        guard var definition = InlineCode.definition(for: .py) else { return .failure(InlineCodeError("no definition")) }
        if let timeout { definition.timeoutSeconds = timeout }
        do {
            var text = ""
            let environment = ["PATH": folder, "HOME": NSHomeDirectory()]
            for try await update in CommandRunner.run(definition, input: code, environment: environment) where update.isFinal {
                text = update.result.versions.first?.text ?? ""
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    @Test(.enabled(if: !InlineCodeTests.pythons.isEmpty)) func pythonIsREPLStyle() async throws {
        let cases: [(code: String, result: String)] = [
            ("2**100", "1267650600228229401496703205376"),  // the value of the last expression
            ("'abc'.upper()", "ABC"),  // a str as it is
            ("[1, 'a', None]", "[1, 'a', None]"),  // anything else with repr
            ("b'x'", "b'x'"),
            ("x = 6; x * 7", "42"),
            ("1; 2", "2"),  // only the last expression
            ("print('hi')", "hi"),  // its value, None, isn't printed
            ("print('a'); 1 + 1", "a\n2"),  // what it printed, then the value
            ("for i in range(3): print(i)", "0\n1\n2"),  // statements: what they print
            ("x = 5", ""),
            ("import math; math.sqrt(16)", "4.0"),
            ("import sys; print('warning', file=sys.stderr); 42", "42"),  // standard error doesn't count when it works
            ("'你好' * 2", "你好你好"),
            ("print（“牛逼”）", "牛逼"),  // full-width punctuation from Chinese typing
            ("__name__", "__main__"),
            ("[k for k in globals() if not k.startswith('__')]", "[]"),  // a namespace of its own
            ("exit()", ""),
        ]
        for folder in Self.pythons {
            for (code, result) in cases {
                let got = await python(code, in: folder)
                #expect((try? got.get()) == result, "\(code) with the python3 in \(folder): \(got)")
            }
        }
    }

    @Test(.enabled(if: !InlineCodeTests.pythons.isEmpty)) func pythonErrorsAreOneLine() async throws {
        let cases: [(code: String, error: CommandRunner.RunError)] = [
            ("1/0", .failed(status: 1, message: "ZeroDivisionError: division by zero")),
            ("raise ValueError('first line\\nsecond line')", .failed(status: 1, message: "ValueError: first line")),
            ("x = 1\ny = 0\nx / y", .failed(status: 1, message: "ZeroDivisionError: division by zero (line 3)")),
            ("input()", .failed(status: 1, message: "EOFError: EOF when reading a line")),  // no standard input to read
            ("import sys; sys.exit('bad input')", .failed(status: 1, message: "bad input")),
            ("import sys; sys.exit(3)", .failed(status: 3, message: "")),
        ]
        for folder in Self.pythons {
            for (code, error) in cases {
                let got = await python(code, in: folder)
                #expect(got.runError == error, "\(code) with the python3 in \(folder): \(got)")
            }
            // The wording of syntax errors changes between Python versions.
            guard case let .failed(status, message)? = await python("print(", in: folder).runError else {
                Issue.record("print( didn't fail with the python3 in \(folder)")
                continue
            }
            #expect(status == 1 && message.hasPrefix("SyntaxError: ") && !message.contains("\n"), "\(message)")
            #expect(await python("while True: pass", in: folder, timeout: 0.5).runError == .timedOut(0.5))
        }
    }

    @Test(.enabled(if: !InlineCodeTests.pythons.isEmpty)) func pythonIgnoresLookalikeModulesInTheWorkingDirectory() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("inline-code-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for name in ["ast", "traceback"] {
            try Data("raise ImportError('not the standard \(name)')\n".utf8).write(to: folder.appendingPathComponent("\(name).py"))
        }
        try Data("VALUE = 42\n".utf8).write(to: folder.appendingPathComponent("helper.py"))
        let argv = try #require(InlineCode.definition(for: .py)?.argv)
        for python in Self.pythons {
            // Run there (the input method runs in the home folder), the code on standard input.
            let process = Process()
            process.executableURL = CommandRunner.resolve("python3", path: python)
            process.arguments = Array(argv.dropFirst())
            process.currentDirectoryURL = folder
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data("import helper; helper.VALUE + 1".utf8))
            try input.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            // Its own modules are the standard ones; the code still imports from the folder, as with `python3 -c`.
            #expect(process.terminationStatus == 0 && text == "43\n", "the python3 in \(python): \(text)")
        }
    }

    // MARK: - JavaScript

    @Test func javaScriptIsREPLStyle() throws {
        let cases: [(code: String, result: String)] = [
            ("1 + 1", "2"),  // the value of the last statement
            ("'abc'.toUpperCase()", "ABC"),  // text as it is
            ("[1, 'a', [2, null]]", "[1, \"a\", [2, null]]"),  // anything else as a literal
            ("{a: 1, 'b-c': [true]}", "{a: 1, \"b-c\": [true]}"),  // braces: an object when they can be one…
            ("{ let x = 2; x * 3 }", "6"),  // …a block otherwise
            ("var x = 6; x * 7", "42"),
            ("let y = 1", ""),  // no value
            ("for (let i = 0; i < 3; i++) console.log(i)", "0\n1\n2"),
            ("console.log('hi', [1], {b: 2}); 42", "hi [1] {b: 2}\n42"),  // what it logged, then the value
            ("console.warn('w'); console.error('e'); 'ok'", "ok"),  // warnings aren't the result
            ("2n ** 100n", "1267650600228229401496703205376"),
            ("[1n, -0, NaN, undefined]", "[1n, -0, NaN, undefined]"),
            ("new Map([['k', 1]])", "Map {\"k\" => 1}"),
            ("new Set([1, 'a'])", "Set {1, \"a\"}"),
            ("new Date(0)", "1970-01-01T00:00:00.000Z"),
            ("var o = {}; o.self = o; o", "{self: [Circular]}"),
            ("class Point { constructor() { this.x = 1 } }; new Point()", "Point {x: 1}"),
            ("function f() {}; f", "[Function: f]"),
            ("'你好'.repeat(2)", "你好你好"),
        ]
        for (code, result) in cases {
            #expect(try InlineCode.evaluateJavaScript(code) == result, "\(code)")
        }
    }

    @Test func javaScriptHasNothingButTheLanguage() throws {
        let globals = "[typeof require, typeof process, typeof fetch, typeof XMLHttpRequest, typeof setTimeout, typeof importScripts].join()"
        #expect(try InlineCode.evaluateJavaScript(globals) == Array(repeating: "undefined", count: 6).joined(separator: ","))
        // Warnings go their own way (to standard error in the child process).
        var printed: [String] = [], warned: [String] = []
        try InlineCode.runJavaScript("console.log('a'); console.error('b', 1); 'c'", print: { printed.append($0) }, warn: { warned.append($0) })
        #expect(printed == ["a", "c"] && warned == ["b 1"])
        // Every run starts afresh.
        _ = try InlineCode.evaluateJavaScript("var kept = 1")
        #expect(try InlineCode.evaluateJavaScript("typeof kept") == "undefined")
    }

    @Test func javaScriptErrorsAreOneLine() {
        let cases: [(code: String, error: String)] = [
            ("x.y", "ReferenceError: Can't find variable: x"),
            ("throw new Error('first line\\nsecond line')", "Error: first line"),
            ("throw 'oops'", "oops"),
            ("throw {code: 1}", "{code: 1}"),
            ("1 +", "SyntaxError: Unexpected end of script"),
            ("1\n2\nnope", "ReferenceError: Can't find variable: nope (line 3)"),
            ("({get a() { throw new RangeError('no') }})", "RangeError: no"),  // showing the value failed
        ]
        for (code, error) in cases {
            #expect(throws: InlineCodeError(error), "\(code)") { try InlineCode.evaluateJavaScript(code) }
        }
    }
}

private extension Result where Failure == Error {
    var runError: CommandRunner.RunError? {
        if case let .failure(error) = self { return error as? CommandRunner.RunError }
        return nil
    }
}
