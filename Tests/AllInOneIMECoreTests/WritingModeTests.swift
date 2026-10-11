import Foundation
import Testing
@testable import AllInOneIMECore

struct WritingModeTests {
    func config(_ outputs: [OutputLanguage], styles: [String] = ["润色", "简洁"]) -> Config {
        var config = Config.default
        config.setOrder(outputs)
        config.rewriteStyles = styles
        return config
    }

    @Test func theCommandsAndBothTogether() {
        #expect(WritingMode.parse(.improve, "你好") == (.improve, "你好"))
        #expect(WritingMode.parse(nil, "你好") == (.improve, "你好"))
        #expect(WritingMode.parse(.translate, "你好") == (.translate, "你好"))
        // Written together, either way round: one request with both.
        #expect(WritingMode.parse(.translate, "@improve 牛的啊") == (.both, "牛的啊"))
        #expect(WritingMode.parse(.improve, "@translate 牛的啊") == (.both, "牛的啊"))
        #expect(WritingMode.parse(.improve, "牛的啊 @translate") == (.both, "牛的啊"))
        // An address or a word that only contains the name isn't the command.
        #expect(WritingMode.parse(.improve, "mail a@translate.com") == (.improve, "mail a@translate.com"))
    }

    @Test func whatEachModeAsksFor() {
        let three = config([OutputLanguage("ja"), .english, .chinese])
        // @improve: polished in the sentence's own language, plus the styles; nothing translated.
        let improve = WritingPlan.make(.improve, text: "牛的啊", config: three)
        #expect(improve.versions == .chinese && improve.translations.isEmpty && improve.styles.map(\.name) == ["润色", "简洁"])
        // @translate: a line in each added language but the sentence's own, in the user's order; no styles.
        let translate = WritingPlan.make(.translate, text: "牛的啊", config: three)
        #expect(translate.versions == nil && translate.translations == [OutputLanguage("ja"), .english] && translate.styles.isEmpty)
        // One language to translate into: three versions in it.
        let one = WritingPlan.make(.translate, text: "牛的啊", config: config([.english, .chinese]))
        #expect(one.versions == .english && one.translations.isEmpty)
        // Both: the translations and the styles.
        let both = WritingPlan.make(.both, text: "牛的啊", config: three)
        #expect(both.translations == [OutputLanguage("ja"), .english] && both.styles.count == 2)
        // Nothing else to translate into: polished instead.
        let only = WritingPlan.make(.translate, text: "牛的啊", config: config([.chinese]))
        #expect(only.versions == .chinese && only.translations.isEmpty)
    }

    @Test func oneRequestForSeveralLanguages() {
        let three = config([OutputLanguage("ja"), .english, .chinese])
        let request = Prompt.request(for: "牛的啊", mode: .both, config: three)
        let system = request.system.first?.text ?? ""
        #expect(system.contains("\nJA: <the sentence in Japanese") && system.contains("\nEN: <the sentence in English")
                && !system.contains("\nZH: ") && system.contains("\nPOLISH: ") && system.contains("\nCONCISE: "))
        // Examples need Japanese, which they aren't written in: the sentence goes alone.
        #expect(request.messages.count == 1)
        // English and Chinese only: the examples are answered the same way (a line per language).
        let two = Prompt.request(for: "牛的啊", mode: .translate, config: config([.english, OutputLanguage("zh-Hant"), .chinese]))
        #expect(two.messages.count == 1)
        let polish = Prompt.request(for: "牛的啊", mode: .improve, config: three)
        #expect((polish.system.first?.text ?? "").contains("\nZH: <how a native Simplified Chinese speaker") && polish.messages.count > 1)

        let answer = "EN: That's awesome\nJA: すごいね\nPOLISH: 太厉害了\nZH: 牛\nCONCISE: 牛"
        let parsed = CandidateParser.parse(answer, isFinal: true, output: nil, translations: [OutputLanguage("ja"), .english])
        // In the user's order, whatever order the model answered in; a line in another language is ignored.
        #expect(parsed.translations.map(\.language.code) == ["ja", "en"] && parsed.translations.map(\.line.text) == ["すごいね", "That's awesome"])
        #expect(parsed.versions.isEmpty && parsed.rewrites.map(\.style) == ["润色", "简洁"])
    }
}
