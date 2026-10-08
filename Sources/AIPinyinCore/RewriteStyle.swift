import Foundation

/// A preset for the level-two rewrites ("润色", "简洁", …), written in the language the sentence was
/// typed in. Which presets are offered, and in which order, comes from `Config.rewriteStyles`.
public struct RewriteStyle: Equatable, Sendable {
    /// Shown in the candidate panel and the input menu; also what `Config.rewriteStyles` lists.
    public let name: String
    /// Line tag the model answers with, e.g. "CONCISE: …".
    public let tag: String
    /// One-line description for the input menu.
    public let summary: String
    /// What the model should do for this style.
    let instruction: String
    /// Rewrites of the few-shot inputs in this style (same order as `Prompt.examples`).
    let exampleRewrites: [String]

    public static let catalog: [RewriteStyle] = [
        RewriteStyle(
            name: "润色", tag: "POLISH", summary: "语气不变，更自然通顺",
            instruction: "the way a skilled native writer would put it: better words, a smoother structure, "
                + "a more natural phrasing, in the user's own tone; adds no apologies or thanks",
            exampleRewrites: [
                "辛苦啦！",
                "这个功能用起来太别扭了。",
                "不好意思，家里有点事，明天的会我可能去不了了。",
                "老板觉得这个方案还不够好，让我们再改改。",
                "I'd really like to go home tomorrow.",
                "This bug is blocking us, so your team needs to fix it as soon as possible.",
            ]),
        RewriteStyle(
            name: "简洁", tag: "CONCISE", summary: "更短，去掉多余的话",
            instruction: "as short as possible while keeping every point, apology and request: cut filler "
                + "words, repetition and padding; the user's tone",
            exampleRewrites: [
                "辛苦！",
                "这功能太难用。",
                "抱歉，家里有事，明天的会可能去不了。",
                "老板说方案不够好，再改一下。",
                "Want to go home tomorrow.",
                "Blocker bug: your team needs to fix it ASAP.",
            ]),
        RewriteStyle(
            name: "正式", tag: "FORMAL", summary: "适合发给领导、客户",
            instruction: "for a manager, client or colleague: polite, professional wording; courteous words "
                + "such as 请、麻烦、您 and a brief courtesy formula such as 谢谢 or 敬请谅解 are welcome",
            exampleRewrites: [
                "您辛苦了！",
                "该功能使用起来非常不便。",
                "非常抱歉，因家中有事，明天的会议我可能无法参加。",
                "领导认为该方案仍有待完善，需要再修改一下。",
                "I would like to return home tomorrow.",
                "This issue is a blocker; could your team please prioritize a fix as soon as possible?",
            ]),
        RewriteStyle(
            name: "口语", tag: "CASUAL", summary: "像跟朋友聊天",
            instruction: "relaxed and conversational, like chatting with a friend: everyday words and "
                + "particles such as 吧、啦、呀, nothing stiff",
            exampleRewrites: [
                "辛苦辛苦！",
                "这功能也太难用了吧！",
                "不好意思哈，家里有点事，明天的会我估计去不了了。",
                "老板说这方案还不行，得再改改。",
                "I wanna go home tomorrow.",
                "Heads up, this bug's a blocker, so your team's gotta fix it ASAP.",
            ]),
        RewriteStyle(
            name: "委婉", tag: "TACTFUL", summary: "更客气，语气缓和",
            instruction: "softer and more considerate: tone down bluntness, criticism or refusal so it is "
                + "easy to accept, while keeping the point; courteous phrases are welcome",
            exampleRewrites: [
                "真是辛苦你了。",
                "这个功能用起来好像不太顺手。",
                "真不好意思，家里有点事，明天的会我可能没办法参加了，还请见谅。",
                "老板觉得这个方案还有提升空间，我们再完善一下吧。",
                "If possible, I'd like to go home tomorrow.",
                "This bug seems to be blocking us. Would your team be able to take a look soon?",
            ]),
        RewriteStyle(
            name: "黑话", tag: "JARGON", summary: "大厂黑话，英文是 Amazon 腔",
            instruction: "tongue-in-cheek big-tech corporate jargon. Chinese becomes 互联网大厂黑话 (对齐、拉通、"
                + "抓手、赋能、闭环、沉淀、颗粒度、链路、owner、bandwidth…); English becomes Amazon-style corporate "
                + "speak (bandwidth, align, dive deep, circle back, action item, OOO, Day 1, disagree and commit…). "
                + "Bad news is sugarcoated into a cheerful understatement: a big problem is called a small one "
                + "(\"this is a blocker bug\" becomes \"Oh! Looks like your team has the bandwidth to fix this "
                + "minor issue!\", 太慢了 becomes 还有提速空间); the real point stays recognizable, and the "
                + "jargon replaces plain words rather than adding deadlines or other details",
            exampleRewrites: [
                "感谢你的强力支持，这波辛苦了！",
                "这个功能的用户体验链路还有很大的优化空间。",
                "不好意思，明天家里有个 P0 事项需要我 own 一下，会议这边可能没有 bandwidth 参加。",
                "老板觉得这个方案的颗粒度还不够细，抓手不够清晰，我们再迭代一版。",
                "Heads up: I'm planning to be OOO tomorrow to head home.",
                "Oh! Looks like your team has the bandwidth to fix this minor issue ASAP!",
            ]),
    ]

    public static let defaultNames = ["润色", "简洁", "正式"]

    /// The 黑话 preset (it can use the user's own jargon list).
    public static let jargonTag = "JARGON"
    public static let jargonName = "黑话"

    public static func named(_ name: String) -> RewriteStyle? {
        let key = name.trimmingCharacters(in: .whitespaces)
        return catalog.first { $0.name == key || $0.tag.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// The presets for configured names, in the configured order (unknown names and repeats skipped).
    public static func resolve(_ names: [String]) -> [RewriteStyle] {
        var seen = Set<String>()
        return names.compactMap(named).filter { seen.insert($0.tag).inserted }
    }

    /// Matches an answer line's tag (e.g. "CONCISE", "简洁") to a preset; older tag spellings included.
    static func forTag(_ tag: String) -> RewriteStyle? {
        switch tag {
        case "POLISHED", "优化": return named("润色")
        default: return named(tag)
        }
    }
}
