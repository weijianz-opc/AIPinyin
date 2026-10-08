import Testing
@testable import AIPinyinCore

struct CandidateParserTests {
    let full = """
        EN: I'm feeling a bit under the weather today.
        EN: I'm not feeling great today.
        EN: I'm a little off today.
        POLISH: 我今天身体有点不适。
        CONCISE: 今天不舒服。
        FORMAL: 今天身体略有不适。
        """

    @Test func parsesWellFormedOutput() {
        let r = CandidateParser.parse(full, isFinal: true)
        #expect(r.versions.map(\.text) == [
            "I'm feeling a bit under the weather today.",
            "I'm not feeling great today.",
            "I'm a little off today.",
        ])
        let allComplete = r.versions.allSatisfy { $0.isComplete }
        #expect(allComplete)
        #expect(r.rewrites == [
            Rewrite(style: "润色", line: CandidateLine("我今天身体有点不适。")),
            Rewrite(style: "简洁", line: CandidateLine("今天不舒服。")),
            Rewrite(style: "正式", line: CandidateLine("今天身体略有不适。")),
        ])
        #expect(r.rewrite("简洁")?.text == "今天不舒服。")
    }

    @Test func everyPresetTagIsRecognized() {
        let text = RewriteStyle.catalog.map { "\($0.tag): \($0.name)版" }.joined(separator: "\n")
        let r = CandidateParser.parse(text, isFinal: true)
        #expect(r.rewrites.map(\.style) == RewriteStyle.catalog.map(\.name))
        #expect(r.rewrites.map(\.line.text) == RewriteStyle.catalog.map { "\($0.name)版" })
    }

    @Test func chineseTagsAndOldSpellings() {
        let r = CandidateParser.parse("EN: Hi.\n润色：你好呀！\n正式：您好！\n口语: 嗨～", isFinal: true)
        #expect(r.rewrites.map(\.style) == ["润色", "正式", "口语"])
        #expect(CandidateParser.parse("POLISHED: 好呀", isFinal: true).rewrite("润色")?.text == "好呀")
        #expect(CandidateParser.parse("优化：好呀", isFinal: true).rewrite("润色")?.text == "好呀")
    }

    @Test func keepsTheFirstLinePerStyleInArrivalOrder() {
        let r = CandidateParser.parse("FORMAL: 您好！\nPOLISH: 你好呀！\nFORMAL: 您好。", isFinal: true)
        #expect(r.rewrites.map(\.style) == ["正式", "润色"])
        #expect(r.rewrite("正式")?.text == "您好！")
    }

    @Test func streamingRewrites() {
        let partial = CandidateParser.parse("EN: Hi.\nPOLISH: 你好呀！\nFORMAL: 您", isFinal: false)
        #expect(partial.rewrites == [
            Rewrite(style: "润色", line: CandidateLine("你好呀！")),
            Rewrite(style: "正式", line: CandidateLine("您", isComplete: false)),
        ])
        #expect(CandidateParser.parse("EN: Hi.\nCONC", isFinal: false).rewrites.isEmpty)
    }

    @Test func wordingKeyIgnoresPunctuationAndSpaces() {
        #expect("我今天有点不舒服。".wordingKey == "我今天有点不舒服".wordingKey)
        #expect("不好意思，刚才在开会！".wordingKey == "不好意思刚才在开会".wordingKey)
        #expect("“好的”…… OK?".wordingKey == "好的ok")
        #expect("我今天身体不太舒服".wordingKey != "我今天有点不舒服".wordingKey)
        #expect("👋你好".wordingKey == "👋你好")
    }

    @Test func streamingPrefixes() {
        #expect(CandidateParser.parse("", isFinal: false) == .empty)
        #expect(CandidateParser.parse("E", isFinal: false) == .empty)
        #expect(CandidateParser.parse("EN: I'm feel", isFinal: false)
            == ConversionResult(versions: [CandidateLine("I'm feel", isComplete: false)]))
        let partialTag = CandidateParser.parse("EN: Hi.\nPOL", isFinal: false)
        #expect(partialTag == ConversionResult(versions: [CandidateLine("Hi.")]))
        let lineDone = CandidateParser.parse("EN: Hi.\n", isFinal: false)
        #expect(lineDone.versions == [CandidateLine("Hi.")])
    }

    @Test func toleratesFormattingVariations() {
        let r = CandidateParser.parse("""
            - EN: “Have you eaten yet?”
            2. EN: "Did you have dinner?"
            **EN:** Have you had a meal?
            **CONCISE:** 吃了吗？
            en : `Eaten?`
            """, isFinal: true)
        #expect(r.versions.map(\.text) == ["Have you eaten yet?", "Did you have dinner?", "Have you had a meal?"])
        #expect(r.rewrite("简洁")?.text == "吃了吗？")
    }

    @Test func ignoresOldStyleChineseLineAndUnknownTags() {
        let r = CandidateParser.parse("ZH: 你好\nEN: Hello.\nPOETIC: 君安否", isFinal: true)
        #expect(r == ConversionResult(versions: [CandidateLine("Hello.")]))
    }

    @Test func chineseOutputReadsZHLinesAndIgnoresEnglishOnes() {
        let text = "ZH: 我今天不太舒服。\n中文：今天身体有点不适。\nEN: I'm unwell.\nJARGON: 今天身体 bandwidth 不足。"
        let r = CandidateParser.parse(text, isFinal: true, output: .chinese)
        #expect(r.versions.map(\.text) == ["我今天不太舒服。", "今天身体有点不适。"])
        #expect(r.rewrite("黑话")?.text == "今天身体 bandwidth 不足。")
        let streaming = CandidateParser.parse("ZH: 我今天", isFinal: false, output: .chinese)
        #expect(streaming.versions == [CandidateLine("我今天", isComplete: false)])
    }

    @Test func keepsColonsInsideCandidates() {
        let r = CandidateParser.parse("EN: Heads up: I'll be late.\nPOLISH: 注意：我会迟到", isFinal: true)
        #expect(r.versions.first?.text == "Heads up: I'll be late.")
        #expect(r.rewrite("润色")?.text == "注意：我会迟到")
    }

    @Test func dedupesAndCaps() {
        let r = CandidateParser.parse("EN: Hi.\nEN: hi.\nEN: Hello.\nEN: Hey.\nEN: Yo.", isFinal: true)
        #expect(r.versions.map(\.text) == ["Hi.", "Hello.", "Hey."])
    }

    @Test func fallsBackToUntaggedLinesWhenFinal() {
        let text = "I'm not feeling well today.\nI'm a bit under the weather."
        #expect(CandidateParser.parse(text, isFinal: false) == .empty)
        #expect(CandidateParser.parse(text, isFinal: true).versions.map(\.text)
            == ["I'm not feeling well today.", "I'm a bit under the weather."])
    }

    @Test func ignoresUntaggedChatterWhenTaggedLinesExist() {
        let r = CandidateParser.parse("Sure! Here you go:\nEN: OK.", isFinal: true)
        #expect(r.versions.map(\.text) == ["OK."])
    }

    @Test func handlesCRLF() {
        let r = CandidateParser.parse("EN: OK.\r\nPOLISH: 好嘞。\r\n", isFinal: true)
        #expect(r == ConversionResult(versions: [CandidateLine("OK.")],
                                      rewrites: [Rewrite(style: "润色", line: CandidateLine("好嘞。"))]))
    }

    @Test func stripsControlCharacters() {
        let r = CandidateParser.parse(
            "EN: echo hi\u{1B}[2J\u{7}\nEN: a\u{2028}b\u{0085}c\tdone\nPOLISH: 好\u{202E}的", isFinal: true)
        #expect(r.versions.map(\.text) == ["echo hi [2J", "a b c done"])
        #expect(r.rewrite("润色")?.text == "好的")
        let untagged = CandidateParser.parse("plain\u{1B}text", isFinal: true)
        #expect(untagged.versions.map(\.text) == ["plain text"])
    }
}
