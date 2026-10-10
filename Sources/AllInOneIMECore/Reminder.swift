import Foundation

/// A reminder read from an `@reminder` text, shown to confirm before it goes into Apple Reminders:
/// "明天下午3点给张三打电话" → 「给张三打电话」, due tomorrow at 15:00 with an alarm then.
public struct ReminderDraft: Equatable, Sendable {
    /// What to be reminded of: the text without its date and time.
    public var title: String
    /// When it is due, in the Gregorian calendar: year, month and day, plus hour and minute with
    /// `hasTime`. Nil: no date.
    public var due: DateComponents?
    /// A time of day was written: due then, with an alarm. Without one it is due that day, no alarm.
    public var hasTime: Bool

    public init(title: String, due: DateComponents? = nil, hasTime: Bool = false) {
        self.title = title
        self.due = due
        self.hasTime = hasTime
    }

    /// Whether the time it is due (without a time: the day) is over at `now`.
    public func isPast(now: Date, calendar: Calendar = ReminderParser.localCalendar) -> Bool {
        guard let due, let date = calendar.date(from: due) else { return false }
        return hasTime ? date < now : calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
    }

    /// When it is due, as the panel and the notice say it: 「明天 15:00」, 「10月15日 周四」, 「没有时间」
    /// ("tomorrow 15:00", "Thu, Oct 15", "no date"), with 「已过」 / "past" once that time is over.
    public func when(now: Date, calendar: Calendar = ReminderParser.localCalendar, chinese: Bool) -> String {
        guard let due, let date = calendar.date(from: due) else { return chinese ? "没有时间" : "no date" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        var text: String
        switch days {
        case 0: text = chinese ? "今天" : "today"
        case 1: text = chinese ? "明天" : "tomorrow"
        case 2 where chinese: text = "后天"
        case -1: text = chinese ? "昨天" : "yesterday"
        default:
            // Fixed wording rather than the locale's formats: it sits next to the Chinese or English panel text.
            let weekday = calendar.component(.weekday, from: date) - 1
            let (year, month, day) = (calendar.component(.year, from: date), calendar.component(.month, from: date),
                                      calendar.component(.day, from: date))
            let otherYear = year != calendar.component(.year, from: now)
            if chinese {
                text = (otherYear ? "\(year)年" : "") + "\(month)月\(day)日 " + ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][weekday]
            } else {
                let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                text = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday] + ", \(months[month - 1]) \(day)"
                    + (otherYear ? ", \(year)" : "")
            }
        }
        if hasTime, let hour = due.hour, let minute = due.minute { text += " " + String(format: "%d:%02d", hour, minute) }
        if isPast(now: now, calendar: calendar) { text += chinese ? " · 已过" : " · past" }
        return text
    }
}

/// Reads the date and time in a reminder's text, on this Mac: nothing is sent anywhere.
///
/// NSDataDetector finds dates and times ("明天下午3点", "下周一 9:30", "tomorrow at 3pm"); durations it
/// misses are read here ("30分钟后", "半小时后", "两小时后", "3天后", "in 2 hours"), and a number of days
/// followed by a time of day combine ("3天后下午3点"). A time of day without a day ("下午3点", "9am")
/// that has already passed today means tomorrow. The first date in the text is the reminder's; the
/// rest of the text is its title, without a leading 「提醒我」 / "remind me to".
public struct ReminderParser: Sendable {
    /// A date or time found in a text: where it is written and the moment it means.
    public struct Match: Equatable, Sendable {
        public var range: Range<String.Index>
        public var date: Date

        public init(range: Range<String.Index>, date: Date) {
            self.range = range
            self.date = date
        }
    }

    /// Finds the dates and times in a text. The system's (`dataDetector`) works from the real clock;
    /// tests pass their own, so what they expect doesn't depend on today's date.
    public var detect: @Sendable (String) -> [Match]
    /// What the due date's components are in (Gregorian, in the Mac's time zone).
    public var calendar: Calendar

    public init(calendar: Calendar = ReminderParser.localCalendar,
                detect: @escaping @Sendable (String) -> [Match] = ReminderParser.dataDetector) {
        self.calendar = calendar
        self.detect = detect
    }

    /// The Gregorian calendar in the Mac's time zone as of now (it may change when travelling). Not
    /// `Calendar.current`, which can be another calendar: Reminders takes Gregorian components.
    public static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// The system's date detection (NSDataDetector).
    public static let dataDetector: @Sendable (String) -> [Match] = { text in
        guard let detector = sharedDetector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let date = result.date, let range = Range(result.range, in: text) else { return nil }
            return Match(range: range, date: date)
        }
    }

    /// Made once (that takes a few milliseconds) and shared: like any NSRegularExpression it is immutable.
    private static let sharedDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The reminder in `text`, as of `now`.
    public func parse(_ text: String, now: Date) -> ReminderDraft {
        let durations = Self.durations(in: text)
        // Where a duration was read here, what the detector made of the same words doesn't count.
        let detected = detect(text).filter { match in !durations.contains { $0.range.overlaps(match.range) } }
        let first = (durations.map(\.range.lowerBound) + detected.map(\.range.lowerBound)).min()
        if let duration = durations.first(where: { $0.range.lowerBound == first }) {
            return resolve(duration, in: text, followedBy: detected.first { $0.range.lowerBound >= duration.range.upperBound },
                           now: now)
        }
        guard let match = detected.first(where: { $0.range.lowerBound == first }) else {
            return ReminderDraft(title: Self.title(text, without: nil))
        }
        let phrase = String(text[match.range])
        let hasTime = Self.mentionsTime(phrase)
        var date = match.date
        // "下午3点" at 16:00: tomorrow's. "今天上午9点" at 10:00 stays today's (and shows it is past).
        if hasTime, !Self.mentionsDay(phrase), date <= now, let next = calendar.date(byAdding: .day, value: 1, to: date) {
            date = next
        }
        return draft(text, range: match.range, date: date, hasTime: hasTime)
    }

    private func draft(_ text: String, range: Range<String.Index>, date: Date, hasTime: Bool) -> ReminderDraft {
        let fields: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        return ReminderDraft(title: Self.title(text, without: range), due: calendar.dateComponents(fields, from: date),
                             hasTime: hasTime)
    }

    // MARK: - Durations

    /// "30分钟后", "in 2 hours": an amount of time from now.
    struct Duration: Equatable {
        enum Unit: Equatable { case minute, hour, day, week }
        var range: Range<String.Index>
        var amount: Double
        var unit: Unit
    }

    /// Minutes and hours from now are a time (to the minute); days and weeks are a day, unless a time
    /// of day follows right after ("3天后下午3点").
    private func resolve(_ duration: Duration, in text: String, followedBy next: Match?, now: Date) -> ReminderDraft {
        switch duration.unit {
        case .minute, .hour:
            let seconds = duration.amount * (duration.unit == .minute ? 60 : 3600)
            let date = Date(timeIntervalSinceReferenceDate: ((now.timeIntervalSinceReferenceDate + seconds) / 60).rounded() * 60)
            return draft(text, range: duration.range, date: date, hasTime: true)
        case .day, .week:
            let days = Int(duration.amount) * (duration.unit == .week ? 7 : 1)
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            // "3天后下午3点", "3天后的下午3点": that day at that time.
            if let next, text[duration.range.upperBound..<next.range.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "的" }) {
                let phrase = String(text[next.range])
                let time = calendar.dateComponents([.hour, .minute], from: next.date)
                if Self.mentionsTime(phrase), !Self.mentionsDay(phrase),
                   let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) {
                    return draft(text, range: duration.range.lowerBound..<next.range.upperBound, date: date, hasTime: true)
                }
            }
            return draft(text, range: duration.range, date: day, hasTime: false)
        }
    }

    private static let chineseDuration = try! NSRegularExpression(pattern:
        "(?:(?<n>[0-9]+(?:\\.[0-9]+)?|[零〇一二两三四五六七八九十]+)\\s*个?\\s*(?<plushalf>半)?|(?<half>半)\\s*个?)"
        + "\\s*(?<unit>分钟|小时|钟头|天|周|星期|礼拜)\\s*(?:以后|之后|后)")
    /// "in 30 minutes", "in 30min", "in 2h", "in an hour and a half", "in half an hour", "in 3 days".
    private static let englishDuration = try! NSRegularExpression(pattern:
        "\\bin\\s+(?:(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*|(?<w>an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|"
        + "twelve|fifteen|twenty|thirty|forty-five|forty|fifty|sixty|ninety)\\s+|(?<half>half\\s+an?)\\s+)"
        + "(?<unit>minutes?|mins?|m|hours?|hrs?|h|days?|weeks?)(?<plushalf>\\s+and\\s+a\\s+half)?\\b",
        options: .caseInsensitive)
    private static let englishNumbers: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
        "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    /// The durations in `text`, in order. Half a unit only for minutes and hours ("半小时后", "in half an hour").
    static func durations(in text: String) -> [Duration] {
        let whole = NSRange(text.startIndex..., in: text)
        return [chineseDuration, englishDuration].flatMap { regex in
            regex.matches(in: text, range: whole).compactMap { match -> Duration? in
                func group(_ name: String) -> String? {
                    Range(match.range(withName: name), in: text).map { String(text[$0]).lowercased() }
                }
                guard let range = Range(match.range, in: text), let unitWord = group("unit") else { return nil }
                let unit: Duration.Unit
                switch unitWord {
                case "分钟", "minute", "minutes", "min", "mins", "m": unit = .minute
                case "小时", "钟头", "hour", "hours", "hr", "hrs", "h": unit = .hour
                case "天", "day", "days": unit = .day
                default: unit = .week
                }
                var amount: Double
                if group("half") != nil {
                    amount = 0.5
                } else if let n = group("n") ?? group("w"),
                          let value = Double(n) ?? englishNumbers[n] ?? chineseNumber(n).map(Double.init) {
                    amount = value + (group("plushalf") != nil ? 0.5 : 0)
                } else {
                    return nil
                }
                // A day count is whole ("1.5天后" is no day); half a day or week isn't read either.
                if unit == .day || unit == .week { guard amount == amount.rounded() else { return nil } }
                guard amount > 0, amount <= 10_000 else { return nil }
                return Duration(range: range, amount: amount, unit: unit)
            }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 一 … 九十九 ("两" for 2): what people write for small numbers.
    static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                        "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(text)
        guard let ten = chars.firstIndex(of: "十") else {
            return chars.count == 1 ? digits[chars[0]] : nil
        }
        let before = chars[..<ten], after = chars[(ten + 1)...]
        guard before.count <= 1, after.count <= 1 else { return nil }
        let tens = before.first.map { digits[$0] } ?? 1, ones = after.first.map { digits[$0] } ?? 0
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    }

    // MARK: - What a date phrase says

    /// Whether a date phrase gives a time of day ("下午3点", "9:30", "3pm", "tonight"), not just a day.
    static func mentionsTime(_ phrase: String) -> Bool {
        let lower = phrase.lowercased()
        let words = ["凌晨", "早上", "早晨", "上午", "中午", "正午", "下午", "傍晚", "晚", "夜", "早",
                     "noon", "midnight", "morning", "afternoon", "evening", "tonight", "night"]
        if words.contains(where: lower.contains) { return true }
        let clock = "[0-9][\\s]*[:：][\\s]*[0-9]|[0-9零〇一二两三四五六七八九十][\\s]*[点點时時]|[0-9][\\s]*(am|pm|a\\.m\\.|p\\.m\\.)"
            + "|\\bat\\s+[0-9]|o'?clock"
        return lower.range(of: clock, options: .regularExpression) != nil
    }

    /// Whether a date phrase names a day: 今 / 明 / 后天 / 周X / 星期X / 下周 / 号 / 日 / 月, today /
    /// tonight / tomorrow, a weekday, a month or a date in digits. Without one, a time that has passed
    /// today means tomorrow.
    static func mentionsDay(_ phrase: String) -> Bool {
        let chinese = ["今", "明", "昨", "后天", "前天", "周", "星期", "礼拜", "号", "日", "月", "年"]
        if chinese.contains(where: phrase.contains) { return true }
        let lower = phrase.lowercased()
        let english = ["today", "tonight", "tomorrow", "yesterday", "this", "next", "last", "week", "month", "year",
                       "mon", "tue", "wed", "thu", "fri", "sat", "sun",
                       "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let words = lower.split(whereSeparator: { !$0.isLetter })
        if words.contains(where: { word in english.contains(where: { word.hasPrefix($0) }) }) { return true }
        // 10/15, 2026-10-15, 15th (not a time range like 10:30-11:00).
        return lower.range(of: "(?<![:0-9])[0-9]{1,4}\\s*[/-]\\s*[0-9]{1,2}(?![:0-9])|[0-9](st|nd|rd|th)\\b",
                           options: .regularExpression) != nil
    }

    // MARK: - Title

    /// The text without the date phrase at `range` (and a word that only led into it: "at", "on", 「在」,
    /// or a 「的」 after it), trimmed of spaces and punctuation, without a leading 「提醒我」 / "remind me to".
    static func title(_ text: String, without range: Range<String.Index>?) -> String {
        var result = text
        if let range {
            var before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let dangling = before.range(of: "(^|\\s)(at|on|by|around)$", options: [.regularExpression, .caseInsensitive]) {
                before.removeSubrange(dangling)
            } else if before.hasSuffix("在") || before.hasSuffix("于") {
                before.removeLast()
            }
            if let lead = ["之前", "以前", "的"].first(where: after.hasPrefix) { after.removeFirst(lead.count) }
            before = before.trimmingCharacters(in: .whitespaces)
            after = after.trimmingCharacters(in: .whitespaces)
            // One space where the text set the phrase off with spaces ("call Bob tomorrow at 3pm about it"),
            // or where two Latin words would run together; none between Chinese words written together.
            let spaced = text[..<range.lowerBound].last?.isWhitespace == true && text[range.upperBound...].first?.isWhitespace == true
            var joint = ""
            if let last = before.last, let first = after.first, !first.isPunctuation, !"([（【「“".contains(last),
               spaced || isLatin(last) && isLatin(first) {
                joint = " "
            }
            result = before + joint + after
            // Brackets that only held the date: "开会（明天下午3点）".
            for empty in ["（）", "()", "【】", "[]", "「」"] { result = result.replacingOccurrences(of: empty, with: "") }
        }
        result = trimmed(result)
        if result.hasPrefix("提醒我") {
            result = trimmed(String(result.dropFirst(3)))
        } else if let lead = result.range(of: "^remind me(\\s+to)?\\b", options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(lead)
            result = trimmed(result)
        }
        return result
    }

    private static let trimmedCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。、；：！？,.;:!?…·~～-—–"))

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: trimmedCharacters) }

    private static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
}
