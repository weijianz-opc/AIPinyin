import Foundation
import Testing
@testable import AllInOneIMECore

/// `ReminderParser` with a stand-in for NSDataDetector (what it would find, without its clock) for the
/// rules, then the real one for what it is used for, relative to now.
struct ReminderParserTests {
    /// Pacific time; "now" is Friday 2026-10-09 16:00.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    let now = ReminderParserTests.date(10, 9, 16)

    static func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func due(_ month: Int, _ day: Int, _ hour: Int? = nil, _ minute: Int? = nil, year: Int = 2026) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    /// A parser whose detector finds each phrase in the text, meaning that date.
    func parser(_ found: [String: Date] = [:]) -> ReminderParser {
        ReminderParser(calendar: Self.calendar) { text in
            found.compactMap { phrase, date in text.range(of: phrase).map { ReminderParser.Match(range: $0, date: date) } }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
    }

    func parse(_ text: String, _ found: [String: Date] = [:]) -> ReminderDraft { parser(found).parse(text, now: now) }

    // MARK: - Titles

    @Test func theTitleIsTheTextWithoutTheDate() {
        let tomorrow3pm = Self.date(10, 10, 15)
        let draft = parse("明天下午3点给张三打电话", ["明天下午3点": tomorrow3pm])
        #expect(draft == ReminderDraft(title: "给张三打电话", due: Self.due(10, 10, 15, 0), hasTime: true))
        // Wherever the date is, and without 「提醒我」 / "remind me to" or a word that led into the date.
        let cases: [(String, String, String)] = [
            ("提醒我明天下午3点给张三打电话", "明天下午3点", "给张三打电话"),
            ("明天下午3点提醒我给张三打电话", "明天下午3点", "给张三打电话"),
            ("给张三打电话，明天下午3点", "明天下午3点", "给张三打电话"),
            ("给张三明天下午3点打电话", "明天下午3点", "给张三打电话"),
            ("在明天下午3点开会", "明天下午3点", "开会"),
            ("开会（明天下午3点）", "明天下午3点", "开会"),
            ("明天下午3点之前交报告", "明天下午3点", "交报告"),
            ("明天下午3点的飞机", "明天下午3点", "飞机"),
            ("提醒我 明天 下午3点 开会", "明天 下午3点", "开会"),
            ("给Bob明天下午3点打电话", "明天下午3点", "给Bob打电话"),
            ("remind me to call Bob tomorrow at 3pm", "tomorrow at 3pm", "call Bob"),
            ("Remind me to call Bob tomorrow at 3pm.", "tomorrow at 3pm", "call Bob"),
            ("tomorrow at 3pm call Bob", "tomorrow at 3pm", "call Bob"),
            ("call Bob tomorrow at 3pm about the report", "tomorrow at 3pm", "call Bob about the report"),
            ("call Bob at 3pm tomorrow", "at 3pm tomorrow", "call Bob"),
        ]
        for (text, phrase, title) in cases {
            #expect(parse(text, [phrase: tomorrow3pm]).title == title, "\(text)")
        }
        // NSDataDetector leaves "at" / "on" out of some phrases ("at [5 pm]", "on [Friday]").
        #expect(parse("Call Bob at 5 pm", ["5 pm": Self.date(10, 9, 17)]).title == "Call Bob")
        let friday = parse("pay rent on Friday", ["Friday": Self.date(10, 16)])
        #expect(friday == ReminderDraft(title: "pay rent", due: Self.due(10, 16), hasTime: false))
    }

    @Test func aDayWithoutATimeHasNoTime() {
        // NSDataDetector puts a day at noon: it stays a day, without a time (and so without an alarm).
        #expect(parse("10月15日交房租", ["10月15日": Self.date(10, 15)])
                == ReminderDraft(title: "交房租", due: Self.due(10, 15), hasTime: false))
        #expect(parse("明天给张三打电话", ["明天": Self.date(10, 10)]).hasTime == false)
        #expect(parse("Oct 15 pay rent", ["Oct 15": Self.date(10, 15)]).due == Self.due(10, 15))
        // A part of the day is a time: 今晚, "tonight", 下午.
        #expect(parse("今晚给妈妈打电话", ["今晚": Self.date(10, 9, 18)]) == ReminderDraft(
            title: "给妈妈打电话", due: Self.due(10, 9, 18, 0), hasTime: true))
        #expect(parse("tonight call mom", ["tonight": Self.date(10, 9, 19)]).hasTime)
    }

    @Test func withoutADateThereIsNoDueDate() {
        #expect(parse("买牛奶") == ReminderDraft(title: "买牛奶"))
        #expect(parse("提醒我买牛奶") == ReminderDraft(title: "买牛奶"))
        #expect(parse("  remind me to buy milk. ") == ReminderDraft(title: "buy milk"))
        #expect(parse("3点开会").due == nil)  // NSDataDetector finds no bare 「3点」 (none found here either)
        // Only a date: nothing to be reminded of (the composer asks for it).
        #expect(parse("明天下午3点", ["明天下午3点": Self.date(10, 10, 15)]).title.isEmpty)
    }

    // MARK: - A time of day that has passed

    @Test func aTimeOfDayAlreadyPastMeansTomorrow() {
        // At 16:00, "下午3点" / "9am" / "15:00" alone are tomorrow's.
        #expect(parse("下午3点开会", ["下午3点": Self.date(10, 9, 15)]).due == Self.due(10, 10, 15, 0))
        #expect(parse("9am standup", ["9am": Self.date(10, 9, 9)]).due == Self.due(10, 10, 9, 0))
        #expect(parse("15:00开会", ["15:00": Self.date(10, 9, 15)]).due == Self.due(10, 10, 15, 0))
        #expect(parse("8点半跑步", ["8点半": Self.date(10, 9, 8, 30)]).due == Self.due(10, 10, 8, 30))
        // Still to come today: today's.
        #expect(parse("下午5点开会", ["下午5点": Self.date(10, 9, 17)]).due == Self.due(10, 9, 17, 0))
        // A day was named: that day, even if it is over (the row then says so).
        let today = parse("今天下午3点开会", ["今天下午3点": Self.date(10, 9, 15)])
        #expect(today.due == Self.due(10, 9, 15, 0) && today.isPast(now: now, calendar: Self.calendar))
        #expect(parse("today at 3pm call Bob", ["today at 3pm": Self.date(10, 9, 15)]).due == Self.due(10, 9, 15, 0))
        #expect(parse("周五下午3点开会", ["周五下午3点": Self.date(10, 9, 15)]).due == Self.due(10, 9, 15, 0))
        #expect(parse("10/9 3pm", ["10/9 3pm": Self.date(10, 9, 15)]).due == Self.due(10, 9, 15, 0))
        // A day without a time is never moved.
        #expect(parse("今天交报告", ["今天": Self.date(10, 9)]).due == Self.due(10, 9))
    }

    @Test func whatAPhraseSays() {
        for phrase in ["下午3点", "9:30", "9：30", "3pm", "5 pm", "at 3", "tonight", "早上7点", "8点半", "十点", "noon"] {
            #expect(ReminderParser.mentionsTime(phrase), "\(phrase)")
        }
        for phrase in ["明天", "10月15日", "下周一", "Friday", "Oct 15", "12/25", "2026-10-15", "next week"] {
            #expect(!ReminderParser.mentionsTime(phrase), "\(phrase)")
        }
        for phrase in ["今晚8点", "明天下午", "后天", "周五", "星期三", "下周一 9:30", "15号", "10月15日", "tomorrow at 3pm",
                       "tonight", "today 5pm", "next Monday 9:30", "Friday 5pm", "Oct 15", "10/15 9:00", "the 15th"] {
            #expect(ReminderParser.mentionsDay(phrase), "\(phrase)")
        }
        for phrase in ["下午3点", "9am", "15:00", "8点半", "晚上9点", "5 pm", "10:30-11:00"] {
            #expect(!ReminderParser.mentionsDay(phrase), "\(phrase)")
        }
    }

    // MARK: - Durations (NSDataDetector misses them)

    @Test func minutesAndHoursFromNow() {
        let cases: [(String, Date, String)] = [
            ("30分钟后关火", Self.date(10, 9, 16, 30), "关火"),
            ("半小时后喝水", Self.date(10, 9, 16, 30), "喝水"),
            ("半个小时后喝水", Self.date(10, 9, 16, 30), "喝水"),
            ("两小时后开会", Self.date(10, 9, 18), "开会"),
            ("两个钟头以后开会", Self.date(10, 9, 18), "开会"),
            ("一个半小时后出发", Self.date(10, 9, 17, 30), "出发"),
            ("十分钟后", Self.date(10, 9, 16, 10), ""),
            ("提醒我二十五分钟之后拿快递", Self.date(10, 9, 16, 25), "拿快递"),
            ("1小时后", Self.date(10, 9, 17), ""),
            ("in 30 minutes check the oven", Self.date(10, 9, 16, 30), "check the oven"),
            ("in 30min check the oven", Self.date(10, 9, 16, 30), "check the oven"),
            ("call mom in 2 hours", Self.date(10, 9, 18), "call mom"),
            ("In an hour and a half: leave", Self.date(10, 9, 17, 30), "leave"),
            ("in half an hour stretch", Self.date(10, 9, 16, 30), "stretch"),
            ("Remind me in 2h to stretch", Self.date(10, 9, 18), "stretch"),
        ]
        for (text, when, title) in cases {
            let draft = parse(text)
            #expect(draft.due == Self.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: when)
                    && draft.hasTime && draft.title == title, "\(text): \(draft)")
        }
        // To the minute.
        let soon = parser().parse("5分钟后", now: Self.date(10, 9, 16).addingTimeInterval(40))
        #expect(soon.due == Self.due(10, 9, 16, 6))
    }

    @Test func daysFromNowAreADay() {
        #expect(parse("3天后交报告") == ReminderDraft(title: "交报告", due: Self.due(10, 12), hasTime: false))
        #expect(parse("两天后体检").due == Self.due(10, 11))
        #expect(parse("1周后复查").due == Self.due(10, 16))
        #expect(parse("in 3 days pay rent") == ReminderDraft(title: "pay rent", due: Self.due(10, 12), hasTime: false))
        // NSDataDetector reads "in 3 days" itself (at noon): the duration rule decides, a day.
        #expect(parse("in 3 days pay rent", ["in 3 days": Self.date(10, 12)]).hasTime == false)
        // With a time of day right after: that day at that time.
        let checkup = parse("两天后下午3点体检", ["下午3点": Self.date(10, 9, 15)])
        #expect(checkup == ReminderDraft(title: "体检", due: Self.due(10, 11, 15, 0), hasTime: true))
        #expect(parse("3天后的上午10点开会", ["上午10点": Self.date(10, 9, 10)]).due == Self.due(10, 12, 10, 0))
        // Not a duration: half a day, no amount, and other words.
        #expect(parse("1.5天后").due == nil && parse("半天后").due == nil && parse("0分钟后").due == nil)
        #expect(parse("within 2 hours").due == nil)
    }

    @Test func smallChineseNumbers() {
        let numbers: [String: Int?] = ["一": 1, "两": 2, "十": 10, "十五": 15, "二十": 20, "三十五": 35, "九十九": 99,
                                       "一百": nil, "一二": nil, "十十": nil]
        for (text, value) in numbers { #expect(ReminderParser.chineseNumber(text) == value, "\(text)") }
    }

    // MARK: - How it is shown

    @Test func whenItIsDue() {
        func when(_ due: DateComponents?, time: Bool, chinese: Bool) -> String {
            ReminderDraft(title: "x", due: due, hasTime: time).when(now: now, calendar: Self.calendar, chinese: chinese)
        }
        #expect(when(Self.due(10, 10, 15, 0), time: true, chinese: true) == "明天 15:00")
        #expect(when(Self.due(10, 10, 15, 0), time: true, chinese: false) == "tomorrow 15:00")
        #expect(when(Self.due(10, 15), time: false, chinese: true) == "10月15日 周四")
        #expect(when(Self.due(10, 15), time: false, chinese: false) == "Thu, Oct 15")
        #expect(when(Self.due(10, 12, 9, 30), time: true, chinese: true) == "10月12日 周一 9:30")
        #expect(when(Self.due(10, 11), time: false, chinese: true) == "后天")
        #expect(when(Self.due(10, 9, 17, 0), time: true, chinese: true) == "今天 17:00")
        #expect(when(nil, time: false, chinese: true) == "没有时间" && when(nil, time: false, chinese: false) == "no date")
        #expect(when(Self.due(1, 5, year: 2027), time: false, chinese: true) == "2027年1月5日 周二")
        #expect(when(Self.due(1, 5, year: 2027), time: false, chinese: false) == "Tue, Jan 5, 2027")
        // Over: 「已过」 / "past". Today's day without a time isn't over yet.
        #expect(when(Self.due(10, 9, 9, 0), time: true, chinese: true) == "今天 9:00 · 已过")
        #expect(when(Self.due(10, 9, 9, 0), time: true, chinese: false) == "today 9:00 · past")
        #expect(when(Self.due(10, 8), time: false, chinese: true) == "昨天 · 已过")
        #expect(when(Self.due(10, 9), time: false, chinese: true) == "今天")
    }

    // MARK: - The real NSDataDetector, relative to now

    func tomorrow(at hour: Int) -> DateComponents {
        let calendar = ReminderParser.localCalendar
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                       from: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!)
    }

    /// Minutes from now, as the parser rounds them.
    func fromNow(_ seconds: TimeInterval, _ draft: ReminderDraft, at now: Date) -> Bool {
        guard let due = draft.due, let date = ReminderParser.localCalendar.date(from: due) else { return false }
        return abs(date.timeIntervalSince(now.addingTimeInterval(seconds))) <= 30 && draft.hasTime
    }

    @Test func theSystemsDetectorInChinese() {
        let now = Date()
        let parser = ReminderParser()
        #expect(parser.parse("明天下午3点给张三打电话", now: now)
                == ReminderDraft(title: "给张三打电话", due: tomorrow(at: 15), hasTime: true))
        let off = parser.parse("30分钟后关火", now: now)
        #expect(off.title == "关火" && fromNow(30 * 60, off, at: now), "\(off)")
        let water = parser.parse("半小时后提醒我喝水", now: now)
        #expect(water.title == "喝水" && fromNow(30 * 60, water, at: now), "\(water)")
        // Only a day: no time.
        let call = parser.parse("明天给张三打电话", now: now)
        #expect(call.title == "给张三打电话" && !call.hasTime && call.due?.hour == nil && call.due?.day == tomorrow(at: 0).day)
    }

    @Test func theSystemsDetectorInEnglish() {
        let now = Date()
        let parser = ReminderParser()
        #expect(parser.parse("remind me to call Bob tomorrow at 3pm", now: now)
                == ReminderDraft(title: "call Bob", due: tomorrow(at: 15), hasTime: true))
        let oven = parser.parse("in 2 hours check the oven", now: now)
        #expect(oven.title == "check the oven" && fromNow(2 * 3600, oven, at: now), "\(oven)")
        #expect(parser.parse("buy milk", now: now) == ReminderDraft(title: "buy milk"))
    }
}
