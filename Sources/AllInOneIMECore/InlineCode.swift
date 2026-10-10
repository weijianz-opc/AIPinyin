import Foundation
import JavaScriptCore

/// `@py` and `@js`: a line of code, run REPL style. When the code ends with an expression, its value is
/// the result (text as it is, anything else written as a literal: `[1, 'a']` in Python, `[1, "a"]` in
/// JavaScript); before it comes what the code printed. Code that ends with a statement gives what it
/// printed. An error (an exception, a failed exit) is shown as one line: its first.
///
/// The code always runs in a child process through `CommandRunner` (timeout, output limit, Esc, the
/// user's shell PATH, the home folder as the working directory), never in the input method: a script
/// that doesn't end couldn't be stopped there. `@py` runs the user's `python3`; `@js` runs in this
/// app's own executable (`runJavaScriptHost`), in JavaScriptCore, which is part of macOS and has nothing
/// but the language (no files, programs, network or timers).
///
/// The code is what the user typed or pasted: it never contains the output of other commands
/// (`Command.isCode`), let alone a model's.
public enum InlineCode {
    /// The interpreter `@py` runs; without it (`CommandRunner.isInstalled`) the command isn't offered.
    static let python = "python3"
    /// The option that makes this app's executable the child process `@js` code runs in.
    public static let javaScriptHostOption = "--run-js"

    /// The program `command` runs, as a `run` definition for `CommandRunner` (the code on standard
    /// input, full-width punctuation as ASCII); nil for a command that isn't code.
    public static func definition(for command: Command,
                                  executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) -> CustomCommand? {
        let argv: [String]
        switch command {
        case .py: argv = [python, "-X", "utf8", "-c", pythonREPL]
        case .js: argv = [executable, javaScriptHostOption]
        default: return nil
        }
        return CustomCommand(name: command.name, type: .run, argv: argv, stdin: CustomCommand.placeholder, ascii: true,
                             timeoutSeconds: CustomCommand.defaultTimeout)
    }

    // MARK: - Python

    /// Runs the code on standard input like IPython does a cell: `ast` splits off a last expression,
    /// the rest is executed, then the expression's value is printed (a str as it is, anything else with
    /// repr; None not at all). An error is printed to standard error as one line, with the line it
    /// happened on when the code has several, and the exit status is 1; `sys.exit` works as usual.
    /// The code runs in a namespace of its own (`__name__` is "__main__"). The working directory (the
    /// home folder) is left out of `sys.path` while this imports its own modules, so an `ast.py` there
    /// can't stand in for them; the code itself can import from it, as with `python3 -c`.
    static let pythonREPL = #"""
        import sys
        cwd = sys.path.pop(0) if sys.path[:1] == [""] else None
        import ast, traceback
        if cwd is not None:
            sys.path.insert(0, cwd)

        def fail(error):
            if isinstance(error, SyntaxError):
                message, line = type(error).__name__ + (": " + error.msg if error.msg else ""), error.lineno
            else:
                message = traceback.format_exception_only(type(error), error)[0]
                lines = [frame.lineno for frame in traceback.extract_tb(error.__traceback__) if frame.filename == "<input>"]
                line = lines[-1] if lines else None
            message = (message.strip().splitlines() or [type(error).__name__])[0]
            if line and "\n" in source.strip():
                message += " (line %d)" % line
            sys.stderr.write(message + "\n")
            sys.exit(1)

        source = sys.stdin.buffer.read().decode("utf-8", "replace")
        try:
            tree = ast.parse(source, "<input>")
            last = tree.body.pop() if tree.body and isinstance(tree.body[-1], ast.Expr) else None
            scope = {"__name__": "__main__"}
            exec(compile(tree, "<input>", "exec"), scope)
            if last is not None:
                value = eval(compile(ast.Expression(last.value), "<input>", "eval"), scope)
                if value is not None:
                    print(value if isinstance(value, str) else repr(value))
        except SystemExit:
            raise
        except BaseException as error:
            fail(error)
        """#

    // MARK: - JavaScript

    /// Defines `console` (log, info, debug, dir: printed; warn, error, trace: warnings) over the native
    /// `write(text, isWarning)` it is called with, and returns `show` (a value as inserted: text and
    /// numbers as they are, anything else as a literal like the browser console's) and `describe` (a
    /// thrown value as text).
    static let javaScriptPrelude = #"""
        (function (write) {
          function key(name) {
            return /^[A-Za-z_$][\w$]*$/.test(name) ? name : JSON.stringify(name);
          }
          function literal(value, depth, seen) {
            switch (typeof value) {
              case "string": return JSON.stringify(value);
              case "bigint": return value + "n";
              case "number": return Object.is(value, -0) ? "-0" : String(value);
              case "symbol": return value.toString();
              case "function": return "[Function" + (value.name ? ": " + value.name : "") + "]";
              case "object": break;
              default: return String(value);
            }
            if (value === null) return "null";
            if (seen.indexOf(value) >= 0) return "[Circular]";
            if (value instanceof Date) return isNaN(value) ? "Invalid Date" : value.toISOString();
            if (value instanceof RegExp || value instanceof Error) return String(value);
            if (depth > 4) return Array.isArray(value) ? "[Array]" : "[Object]";
            var inner = function (item) { return literal(item, depth + 1, seen.concat([value])); };
            if (Array.isArray(value)) return "[" + Array.from(value, inner).join(", ") + "]";
            if (value instanceof Map) {
              return "Map {" + Array.from(value, function (entry) {
                return inner(entry[0]) + " => " + inner(entry[1]);
              }).join(", ") + "}";
            }
            if (value instanceof Set) return "Set {" + Array.from(value, inner).join(", ") + "}";
            if (ArrayBuffer.isView(value) && "length" in value) {
              return value.constructor.name + " [" + Array.from(value, inner).join(", ") + "]";
            }
            var prototype = Object.getPrototypeOf(value);
            var name = value[Symbol.toStringTag] || (prototype === Object.prototype || prototype === null ? ""
              : (prototype.constructor && prototype.constructor.name) || "");
            var body = "{" + Object.keys(value).map(function (k) { return key(k) + ": " + inner(value[k]); }).join(", ") + "}";
            return name ? name + " " + body : body;
          }
          function show(value) {
            return typeof value === "string" ? value : typeof value === "bigint" ? String(value) : literal(value, 0, []);
          }
          function line(args) { return Array.prototype.map.call(args, show).join(" "); }
          var print = function () { write(line(arguments), false); };
          var warn = function () { write(line(arguments), true); };
          globalThis.console = { log: print, info: print, debug: print, dir: print, warn: warn, error: warn, trace: warn };
          return {
            show: show,
            describe: function (error) {
              try { return error instanceof Error ? String(error) : show(error); } catch (_) { return "error"; }
            }
          };
        })
        """#

    /// Runs `code` REPL style in a fresh JavaScriptCore context: `console.log` lines go to `print` as they
    /// are logged, then the value of the last statement (the script's completion value, as in the browser
    /// console; none for `undefined`); `console.warn` and `console.error` lines go to `warn`. Code in
    /// braces is an object literal when it can be one (`{a: 1}`), as in Node's REPL. Throws the error as
    /// one line. Only for the child process (`runJavaScriptHost`) and tests: a script that never ends
    /// can't be stopped in the process it runs in.
    static func runJavaScript(_ code: String, print: @escaping (String) -> Void, warn: @escaping (String) -> Void) throws {
        guard let context = JSContext() else { throw InlineCodeError("JavaScript is not available") }
        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        let write: @convention(block) (String, Bool) -> Void = { text, isWarning in isWarning ? warn(text) : print(text) }
        guard let helpers = context.evaluateScript(javaScriptPrelude)?.call(withArguments: [write]), thrown == nil,
              let show = helpers.objectForKeyedSubscript("show"), let describe = helpers.objectForKeyedSubscript("describe")
        else { throw InlineCodeError("JavaScript is not available") }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let asObject = trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && parses("(" + trimmed + ")", in: context)
        let value = context.evaluateScript(asObject ? "(" + trimmed + ")" : code)
        if thrown == nil, let value, !value.isUndefined {
            let text = show.call(withArguments: [value])
            if thrown == nil, let text = text?.toString() { print(text) }
        }
        guard let exception = thrown else { return }
        var message = describe.call(withArguments: [exception])?.toString() ?? "error"
        message = message.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if message.isEmpty { message = "error" }
        if trimmed.contains(where: \.isNewline), let line = exception.objectForKeyedSubscript("line"), line.isNumber {
            message += " (line \(line.toInt32()))"
        }
        throw InlineCodeError(message)
    }

    /// Whether `source` is a valid script (nothing runs).
    private static func parses(_ source: String, in context: JSContext) -> Bool {
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, nil)
    }

    /// `runJavaScript`, with what it prints collected: one line each.
    static func evaluateJavaScript(_ code: String) throws -> String {
        var lines: [String] = []
        try runJavaScript(code, print: { lines.append($0) }, warn: { _ in })
        return lines.joined(separator: "\n")
    }

    /// `AllInOneIME --run-js`: the child process `@js` code runs in. The code comes on standard input; what
    /// it prints goes to standard output as it comes (so the runner's output limit applies), warnings and
    /// an error message to standard error (exit status 1).
    public static func runJavaScriptHost() -> Int32 {
        func write(_ text: String, to handle: FileHandle) { handle.write(Data((text + "\n").utf8)) }
        let code = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        do {
            try runJavaScript(code, print: { write($0, to: .standardOutput) }, warn: { write($0, to: .standardError) })
            return 0
        } catch {
            write((error as? LocalizedError)?.errorDescription ?? "\(error)", to: .standardError)
            return 1
        }
    }
}

/// Code that failed, with its error as one line ("ReferenceError: Can't find variable: x").
public struct InlineCodeError: Error, LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}
