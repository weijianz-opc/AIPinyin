import Foundation
import Testing
@testable import AllInOneIMECore

struct CommandPlanTests {
    let catalog = Command.catalog([
        CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"]),
        CustomCommand(name: "reply", type: .prompt, prompt: "Reply."),
    ])

    func inner(_ text: String) -> [String] {
        CommandPlan.make(text, commands: catalog).inner.map { "@\($0.command.name) \($0.argument)" }
    }

    @Test func findsTheCommandsInsideAText() {
        let plan = CommandPlan.make("告诉他 @stock AAPL 现在多少钱", commands: catalog)
        #expect(plan.parts == [.text("告诉他 "), .inner(0), .text(" 现在多少钱")])
        #expect(plan.input(outputs: ["Apple Inc. AAPL 336.64 USD −1.11%"]) == "告诉他 Apple Inc. AAPL 336.64 USD −1.11% 现在多少钱")
        // Typed without spaces around it, as Chinese usually is.
        #expect(inner("告诉他@stock AAPL现在多少钱") == ["@stock AAPL"])
        #expect(CommandPlan.make("告诉他@stock AAPL现在多少钱", commands: catalog).input(outputs: ["X"]) == "告诉他X现在多少钱")
        // The argument is the ASCII text after it; sentence punctuation stays in the text.
        #expect(inner("@stock AAPL TSLA 哪个涨得多") == ["@stock AAPL TSLA"])
        #expect(inner("看看 @stock aapl, 然后告诉我") == ["@stock aapl"])
        #expect(inner("比较 @stock AAPL 和 @stock 700 的涨幅") == ["@stock AAPL", "@stock 700"])
        #expect(inner("@Stock AAPL") == ["@stock AAPL"])
        // In an English sentence: the symbol, not the words after it.
        #expect(inner("@stock SNDK is good to buy ?") == ["@stock SNDK"])
        #expect(CommandPlan.make("@stock SNDK is good to buy ?", commands: catalog).input(outputs: ["X"]) == "X is good to buy ?")
        #expect(inner("is @stock nvda a buy?") == ["@stock nvda"])
        #expect(inner("@stock 600519 700 怎么样") == ["@stock 600519 700"])
        #expect(inner("@stock aapl tsla") == ["@stock aapl"])  // lowercase words after the first are text…
        #expect(inner("@stock aapl,tsla") == ["@stock aapl,tsla"])  // …write them with commas
        #expect(inner("@stock「aapl tsla」哪个好") == ["@stock aapl tsla"])  // or quote them
        #expect(inner(#"compare @stock "aapl tsla" today"#) == ["@stock aapl tsla"])
        #expect(inner("@stock「」") == [] && inner("@stock「aapl") == [])
    }

    @Test func everythingElseIsText() {
        for text in ["写信给 a@stock AAPL", "@张三 你好", "@stock", "@stock 现在多少", "@reply 好的", "@stockx AAPL", "@open docs"] {
            let plan = CommandPlan.make(text, commands: catalog)
            #expect(plan.isEmpty, "\(text)")
            #expect(plan.input(outputs: []) == text)
        }
    }

    func updates(_ texts: [String], fail: String? = nil) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { c in
            for (i, t) in texts.enumerated() {
                c.yield(ConversionUpdate(result: ConversionResult(versions: [CandidateLine(t)]), rawText: t,
                                         isFinal: i == texts.count - 1, elapsed: 0, firstTokenLatency: nil, fromCache: false))
            }
            if let fail { c.finish(throwing: CommandRunner.RunError.failed(status: 1, message: fail)) } else { c.finish() }
        }
    }

    @Test func runsTheInnerOnesFirst() async throws {
        let plan = CommandPlan.make("比较 @stock AAPL 和 @stock 700", commands: catalog)
        let asked = OSAllocatedUnfairLockBox()
        let stream = CommandPipeline.run(plan, inner: { command, argument in
            asked.append("\(command.name) \(argument)")
            return self.updates(["…", "quote of \(argument)"])
        }, outer: { text in self.updates(["reply to: " + text]) })
        var final = ""
        for try await update in stream where update.isFinal { final = update.result.versions.first?.text ?? "" }
        #expect(final == "reply to: 比较 quote of AAPL 和 quote of 700")
        #expect(asked.values.sorted() == ["stock 700", "stock AAPL"])

        // An inner one failing stops it, saying which.
        let failing = CommandPipeline.run(plan, inner: { _, _ in self.updates([], fail: "XYZ: not found") },
                                          outer: { _ in self.updates(["never"]) })
        await #expect(throws: CommandPipelineError.inner("stock", "XYZ: not found")) {
            for try await _ in failing {}
        }
    }

    @Test func composerRunsAPlan() {
        let c = Composer(engine: FakeEngine(), sentenceMode: false)
        c.setInputMode(.english)
        c.commands = catalog
        // "@reply 告诉他 @stock AAPL" typed in English mode, then the action key (Return).
        let at = KeyEvent(keyCode: 0x13, characters: "@", charactersIgnoringModifiers: "@", modifiers: .shift)
        let space = KeyEvent(keyCode: VirtualKey.space, characters: " ")
        for ch in "@reply 告诉他 @stock AAPL" {
            _ = c.handleKeyDown(ch == "@" ? at : ch == " " ? space : k(String(ch)))
        }
        #expect(c.draft == "@reply 告诉他 @stock AAPL")
        let effects = c.handleKeyDown(KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r")).effects
        guard case let .startPlan(outer, plan, id)? = effects.first else {
            Issue.record("expected a plan, got \(effects)")
            return
        }
        #expect(outer?.name == "reply" && id == 1 && plan.inner.map(\.argument) == ["AAPL"])
        #expect(effects.contains(.commandUsed("reply")) && effects.contains(.commandUsed("stock")))
    }
}

/// Collects strings from several tasks.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
