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
        #expect(Command.matching("") == Command.allCases)
        #expect(Command.matching("Q") == [.question])
        #expect(Command.matching("cl") == [.claude])
        #expect(Command.matching("x").isEmpty)
        #expect(Command.allCases.map(\.kind) == [.convert, .generate, .terminal, .search])
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
