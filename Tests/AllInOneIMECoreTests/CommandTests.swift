import Foundation
import Testing
@testable import AllInOneIMECore

struct CommandTests {
    @Test func parse() {
        #expect(Command.parse("@question 量子计算是什么")! == (.question, "量子计算是什么"))
        #expect(Command.parse("@Open calc")! == (.open, "calc"))
        #expect(Command.parse("@claude ")! == (.claude, ""))
        #expect(Command.parse("@question") == nil)  // name not finished
        #expect(Command.parse("@john hi") == nil)  // not a command
        #expect(Command.parse("hi @question x") == nil)
        #expect(Command.parse("") == nil)
    }

    @Test func matching() {
        #expect(Command.matching("") == Command.builtins)
        #expect(Command.matching("Q") == [.question])
        #expect(Command.matching("cl") == [.claude])
        #expect(Command.matching("x").isEmpty)
        #expect(Command.builtins.map(\.kind) == [.convert, .generate, .terminal, .search])
    }

    let python = CustomCommand(name: "python", type: .run, argv: ["python3", "-c", "{input}"])
    let reply = CustomCommand(name: "reply", type: .prompt, summary: "Write a reply", prompt: "Write a short, polite reply.")
    let sh = CustomCommand(name: "sh", type: .terminal, argv: ["zsh", "-c", "{input}"])

    @Test func catalogAddsValidCustomCommandsAfterTheBuiltIns() {
        let catalog = Command.catalog([
            python, reply, sh,
            CustomCommand(name: "open", type: .run, argv: ["x"]),           // taken by a built-in
            CustomCommand(name: "Python", type: .run, argv: ["python2"]),  // taken (names are case-insensitive)
            CustomCommand(name: "py3", type: .run, argv: ["python3"]),     // digits pick from the list
            CustomCommand(name: "empty", type: .prompt, prompt: "  "),     // nothing to tell the model
            CustomCommand(name: "noargv", type: .run),
        ])
        #expect(catalog.map(\.name) == ["improve", "question", "claude", "open", "python", "reply", "sh"])
        #expect(catalog.suffix(3).map(\.kind) == [.run, .generate, .terminal])
        #expect(Command.matching("p", in: catalog).map(\.name) == ["python"])
        #expect(Command.parse("@python print(1)", in: catalog)?.command.custom == python)
        #expect(Command.parse("@python print(1)") == nil)  // without the catalog it's not a command
    }

    @Test func inputStaysOneArgument() {
        // Quotes and shell syntax in the text never leave its argument.
        #expect(python.arguments(for: "print('a'); import os") == ["python3", "-c", "print('a'); import os"])
        #expect(sh.arguments(for: "echo hi; rm -rf ~") == ["zsh", "-c", "echo hi; rm -rf ~"])
        let wrapped = CustomCommand(name: "say", type: .run, argv: ["say", "--", "Hi {input}!"], ascii: false)
        #expect(wrapped.arguments(for: "a b") == ["say", "--", "Hi a b!"])
        let calc = CustomCommand(name: "calc", type: .run, argv: ["bc", "-l"], stdin: "{input}\n")
        #expect(calc.standardInput(for: "1+1") == "1+1\n" && python.standardInput(for: "x") == nil)
    }

    @Test func latinCommandsTakeHalfWidthPunctuation() {
        #expect(python.typesLatin && sh.typesLatin && !reply.typesLatin)
        #expect(python.arguments(for: "if True: print（“牛逼”）")[2] == "if True: print(\"牛逼\")")
        #expect(CustomCommand.halfWidth("a，b：c；【1】") == "a,b:c;[1]")
        // A prompt command keeps the text as typed.
        let typed = CustomCommand(name: "t", type: .terminal, argv: ["echo", "{input}"], ascii: false)
        #expect(typed.arguments(for: "你好，世界")[1] == "你好，世界")
    }

    @Test func customPromptGoesToTheModel() throws {
        let command = try #require(Command.catalog([reply]).last)
        let system = Prompt.commandSystem(command)
        #expect(system.contains("inserted at their cursor") && system.hasSuffix("Write a short, polite reply."))
        #expect(!Prompt.commandSystem(.question).contains("polite reply"))
    }

    @Test func configReadsCustomCommands() throws {
        let json = """
            {"customCommands": [{"name": "python", "type": "run", "argv": ["python3", "-c", "{input}"]},
                                {"name": "reply", "type": "prompt", "summary": "Write a reply", "prompt": "Write a short, polite reply."}]}
            """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.customCommands == [python, reply])
        #expect(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).customCommands.isEmpty)
        // Written back as they were (unset fields stay out of the file).
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(again.customCommands == config.customCommands)
        #expect(!String(decoding: try JSONEncoder().encode(python), as: UTF8.self).contains("prompt"))
    }

    @Test func commandRequestShape() throws {
        var config = Config.default
        config.temperature = nil
        let request = Prompt.commandRequest(.question, input: "量子计算是什么", config: config)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)  // no few-shot examples: the text goes as typed
        #expect((messages[0]["content"] as? [[String: Any]])?.first?["text"] as? String == "量子计算是什么")
        let system = try #require((json["system"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(system.contains("inserted at their cursor") && system.contains("Answer the user's question"))
        #expect((json["inferenceConfig"] as? [String: Any])?["temperature"] == nil)
    }

    @Test func answersBecomeOneSafeLine() {
        #expect(Converter.oneLine("  First line.\nSecond\tline.\u{1B}[31m  ") == "First line. Second line. [31m")
    }
}
