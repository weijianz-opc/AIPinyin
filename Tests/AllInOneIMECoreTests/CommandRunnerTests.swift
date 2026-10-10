import Foundation
import Testing
@testable import AllInOneIMECore

struct CommandRunnerTests {
    let environment = ["PATH": "/usr/bin:/bin"]

    func run(_ command: CustomCommand, _ input: String) async -> Result<String, Error> {
        do {
            var text = ""
            for try await update in CommandRunner.run(command, input: input, environment: environment) where update.isFinal {
                text = update.result.versions.first?.text ?? ""
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    @Test func printsBecomeTheResult() async throws {
        let echo = CustomCommand(name: "echo", type: .run, argv: ["echo", "{input}"])
        #expect(try await run(echo, "hello; world").get() == "hello; world")  // no shell: ";" is just text
        let multi = CustomCommand(name: "sh", type: .run, argv: ["sh", "-c", "{input}"])
        #expect(try await run(multi, "printf 'a\\n\\033[31mb\\033[0m\\n\\n'").get() == "a\nb")  // colors and trailing lines dropped
    }

    /// What goes into a terminal (it runs every line): one line, nothing that would run or complete.
    @Test func oneLineForATerminal() {
        let result = ConversionResult(versions: [CandidateLine("0\n1\n2"), CandidateLine("a\tb\u{2028}c", isComplete: false),
                                                 CandidateLine("你好\n世界\nok")])
        let line = CommandRunner.oneLine(result)
        #expect(line.versions.map(\.text) == ["0 1 2", "a b c", "你好世界 ok"])
        #expect(line.versions.map(\.isComplete) == [true, false, true])
        #expect(CommandRunner.oneLine(ConversionResult(versions: [CandidateLine("391")])).versions.map(\.text) == ["391"])
    }

    @Test func standardInput() async throws {
        let rev = CustomCommand(name: "rev", type: .run, argv: ["rev"], stdin: "{input}\n")
        #expect(try await run(rev, "abc").get() == "cba")
    }

    @Test func failuresSayWhatWentWrong() async {
        let sh = CustomCommand(name: "sh", type: .run, argv: ["sh", "-c", "{input}"])
        let failed = await run(sh, "echo first >&2; echo 'the reason' >&2; echo '  ~~^~~' >&2; exit 3")
        #expect(failed.error == .failed(status: 3, message: "the reason"))
        let missing = CustomCommand(name: "x", type: .run, argv: ["no-such-program-here"])
        #expect(await run(missing, "").error == .notFound("no-such-program-here"))
    }

    @Test func slowProgramsAreStopped() async {
        let sleep = CustomCommand(name: "sleep", type: .run, argv: ["sleep", "{input}"], timeoutSeconds: 0.3)
        let started = Date()
        #expect(await run(sleep, "5").error == .timedOut(0.3))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func endlessOutputIsStopped() async {
        let yes = CustomCommand(name: "yes", type: .run, argv: ["yes"], timeoutSeconds: 5)
        #expect(await run(yes, "").error == .tooMuchOutput)
    }

    @Test func cancellingStopsTheProgram() async throws {
        let sleep = CustomCommand(name: "sleep", type: .run, argv: ["sleep", "5"])
        let started = Date()
        let task = Task { await run(sleep, "") }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.value
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func resolvesProgramsOnPath() {
        #expect(CommandRunner.resolve("sh", path: "/nowhere:/bin")?.path == "/bin/sh")
        #expect(CommandRunner.resolve("/bin/sh", path: nil)?.path == "/bin/sh")
        #expect(CommandRunner.resolve("sh", path: "/nowhere") == nil)
    }
}

private extension Result where Failure == Error {
    var error: CommandRunner.RunError? {
        if case let .failure(error) = self { return error as? CommandRunner.RunError }
        return nil
    }
}
