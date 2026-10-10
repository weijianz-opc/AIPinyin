import Foundation
import Testing
@testable import AllInOneIMECore

/// `ReminderParser` with a stand-in for NSDataDetector (what it would find, without its clock) for the
/// rules, then the real one for what it is used for, relative to now. The stand-ins return what the real
/// detector returned on this Mac for the same text (as the parser hands it over: 明晚 → 明天晚上 …).
struct ReminderParserTests {
    /// Pacific time; "now" is Friday 2026-10-09 16:00.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    let now = ReminderParserTests.date(10, 9, 16)
    static let at1am = date(10, 9, 1), at9am = date(10, 9, 9), at9pm = date(10, 9, 21)

    static func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func due(_ month: Int, _ day: Int, _ hour: Int? = nil, _ minute: Int? = nil, year: Int = 2026) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    /// Due then, with its moment.
    static func timed(_ title: String, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> ReminderDraft {
        ReminderDraft(title: title, due: due(month, day, hour, minute), hasTime: true, date: date(month, day, hour, minute))
    }

    /// Due that day, no time.
    static func allDay(_ title: String, _ month: Int, _ day: Int) -> ReminderDraft {
        ReminderDraft(title: title, due: due(month, day), hasTime: false)
    }

    /// A parser whose detector finds each phrase in the text, meaning that date.
    func parser(_ found: [String: Date] = [:]) -> ReminderParser {
        ReminderParser(calendar: Self.calendar) { text in
            found.compactMap { phrase, date in text.range(of: phrase).map { ReminderParser.Match(range: $0, date: date) } }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
    }

    func parse(_ text: String, _ found: [String: Date] = [:], at time: Date? = nil) -> ReminderDraft {
        parser(found).parse(text, now: time ?? now)
    }

    // MARK: - Titles

    @Test func theTitleIsTheTextWithoutTheDate() {
        let tomorrow3pm = Self.date(10, 10, 15)
        #expect(parse("明天下午3点给张三打电话", ["明天下午3点": tomorrow3pm]) == Self.timed("给张三打电话", 10, 10, 15))
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
        #expect(parse("Call Bob at 5 pm", ["5 pm": Self.date(10, 9, 17)]) == Self.timed("Call Bob", 10, 9, 17))
        #expect(parse("pay rent on Friday", ["Friday": Self.date(10, 16)]) == Self.allDay("pay rent", 10, 16))
    }

    @Test func wordsThatOnlyWentWithTheDate() {
        // 「在」 / 「于」 of their own go, not the end of a word (关于, 现在, 对于, 由于).
        #expect(parse("关于明天下午3点的会议", ["明天下午3点": Self.date(10, 10, 15)]) == Self.timed("关于会议", 10, 10, 15))
        #expect(parse("现在下午3点开会", ["下午3点": Self.date(10, 9, 15)], at: Self.at9am) == Self.timed("现在开会", 10, 9, 15))
        #expect(parse("对于明天的安排", ["明天": Self.date(10, 10)]).title == "对于安排")
        #expect(parse("由于明天下雨带伞", ["明天": Self.date(10, 10)]).title == "由于下雨带伞")
        #expect(parse("我在明天下午3点开会", ["明天下午3点": Self.date(10, 10, 15)]).title == "我开会")
        #expect(parse("开会，于明天下午3点", ["明天下午3点": Self.date(10, 10, 15)]).title == "开会")
        // By when: 「前」 / 「之前」 / 「以前」 right after the date (not 前台, 前面 …).
        for text in ["周五前交报告", "周五之前交报告", "周五以前交报告"] {
            #expect(parse(text, ["周五": Self.date(10, 16)]) == Self.allDay("交报告", 10, 16), "\(text)")
        }
        #expect(parse("明天前台见", ["明天": Self.date(10, 10)]).title == "前台见")
        // What only asked for the reminder.
        #expect(parse("提醒我一下明天交报告", ["明天": Self.date(10, 10)]) == Self.allDay("交报告", 10, 10))
        #expect(parse("提醒一下明天交报告", ["明天": Self.date(10, 10)]).title == "交报告")
        #expect(parse("记得明天带伞", ["明天": Self.date(10, 10)]).title == "带伞")
        #expect(parse("提醒我记得带伞").title == "带伞" && parse("提醒我一下").title.isEmpty)
    }

    @Test func mealsTheDetectorReadsAsATimeStayInTheTitle() {
        // It reads "tomorrow lunch" (at 12:00): the reminder is the lunch, tomorrow.
        #expect(parse("tomorrow lunch with Ann", ["tomorrow lunch": Self.date(10, 10, 12)]) == Self.allDay("lunch with Ann", 10, 10))
        #expect(parse("lunch tomorrow with Ann", ["lunch tomorrow": Self.date(10, 10, 12)]) == Self.allDay("lunch with Ann", 10, 10))
        #expect(parse("tomorrow dinner with Bob", ["tomorrow dinner": Self.date(10, 10, 19)]).title == "dinner with Bob")
        // A time written with it stays.
        #expect(parse("at noon tomorrow lunch", ["at noon tomorrow lunch": Self.date(10, 10, 12)]) == Self.timed("lunch", 10, 10, 12))
        #expect(parse("明天午饭和张三", ["明天午饭": Self.date(10, 10, 12)]) == Self.allDay("午饭和张三", 10, 10))
        #expect(parse("明天早餐", ["明天早餐": Self.date(10, 10, 9)]) == Self.allDay("早餐", 10, 10))
        // Only a meal: no date.
        #expect(parse("lunch with Ann", ["lunch": Self.date(10, 9, 12)]) == ReminderDraft(title: "lunch with Ann"))
    }

    @Test func aDayWithoutATimeHasNoTime() {
        // NSDataDetector puts a day at noon: it stays a day, without a time (and so without an alarm).
        #expect(parse("10月15日交房租", ["10月15日": Self.date(10, 15)]) == Self.allDay("交房租", 10, 15))
        #expect(parse("明天给张三打电话", ["明天": Self.date(10, 10)]).hasTime == false)
        #expect(parse("Oct 15 pay rent", ["Oct 15": Self.date(10, 15)]).due == Self.due(10, 15))
        // A part of the day is a time: 今晚, "tonight", 下午.
        #expect(parse("今晚给妈妈打电话", ["今晚": Self.date(10, 9, 18)]) == Self.timed("给妈妈打电话", 10, 9, 18))
        #expect(parse("tonight call mom", ["tonight": Self.date(10, 9, 19)]).hasTime)
    }

    @Test func withoutADateThereIsNoDueDate() {
        #expect(parse("买牛奶") == ReminderDraft(title: "买牛奶"))
        #expect(parse("提醒我买牛奶") == ReminderDraft(title: "买牛奶"))
        #expect(parse("  remind me to buy milk. ") == ReminderDraft(title: "buy milk"))
        // Only a date: nothing to be reminded of (the composer asks for it).
        #expect(parse("明天下午3点", ["明天下午3点": Self.date(10, 10, 15)]).title.isEmpty)
        // Numbers that aren't dates or times (the detector finds none in them either).
        for text in ["买3斤苹果", "订2张票", "转500块", "10.15元", "3号线换乘", "5号楼开会", "第3点意见", "500日元", "3点赞",
                     "买一点水果", "快一点", "有一点累", "一点也不急", "给我一点时间", "早一点到"] {
            #expect(parse(text).due == nil, "\(text)")
        }
        // 「晚一点」 is "a bit later", which the detector reads as 13:00.
        #expect(parse("晚一点出发", ["晚一点": Self.date(10, 9, 13)]) == ReminderDraft(title: "晚一点出发"))
        #expect(parse("明天晚一点开会", ["明天晚一点": Self.date(10, 10, 13)]) == Self.allDay("晚一点开会", 10, 10))
    }

    // MARK: - A time of day that has passed

    @Test func aTimeOfDayAlreadyPastMeansTomorrow() {
        // At 16:00, "下午3点" / "9am" / "15:00" alone are tomorrow's.
        #expect(parse("下午3点开会", ["下午3点": Self.date(10, 9, 15)]).due == Self.due(10, 10, 15, 0))
        #expect(parse("9am standup", ["9am": Self.date(10, 9, 9)]).due == Self.due(10, 10, 9, 0))
        #expect(parse("15:00开会", ["15:00": Self.date(10, 9, 15)]).due == Self.due(10, 10, 15, 0))
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

    // MARK: - A part of the day and a clock time

    @Test func aPartOfTheDayAndAClockTimeAreOneTime() {
        // Written out for the detector, 明晚7点 is 明天晚上7点, which it reads whole.
        #expect(parse("明晚7点吃饭", ["明天晚上7点": Self.date(10, 10, 19)]) == Self.timed("吃饭", 10, 10, 19))
        #expect(parse("明晚八点看电影", ["明天晚上八点": Self.date(10, 10, 20)]) == Self.timed("看电影", 10, 10, 20))
        // Where it reads only the part of the day (18:00), the clock time after it counts, in that half.
        #expect(parse("明晚7点吃饭", ["明天晚上": Self.date(10, 10, 18)]) == Self.timed("吃饭", 10, 10, 19))
        #expect(parse("明晚八点看电影", ["明天晚上": Self.date(10, 10, 18)]) == Self.timed("看电影", 10, 10, 20))
        #expect(parse("明晚7点半吃饭", ["明天晚上": Self.date(10, 10, 18), "7点半": Self.date(10, 9, 19, 30)])
                == Self.timed("吃饭", 10, 10, 19, 30))
        #expect(parse("今天晚上 7点半 吃饭", ["今天晚上": Self.date(10, 9, 18)]) == Self.timed("吃饭", 10, 9, 19, 30))
        #expect(parse("明天早上8点开会", ["明天早上": Self.date(10, 10, 9)]) == Self.timed("开会", 10, 10, 8))
        // It reads 中午 alone (12:00): 十二点 is noon, 1点 just after.
        #expect(parse("中午十二点吃饭", ["中午": Self.date(10, 9, 12)]) == Self.timed("吃饭", 10, 10, 12))  // over at 16:00
        #expect(parse("中午十二点吃饭", ["中午": Self.date(10, 9, 12)], at: Self.at9am) == Self.timed("吃饭", 10, 9, 12))
        #expect(parse("明天中午十二点吃饭", ["明天中午": Self.date(10, 10, 12)]) == Self.timed("吃饭", 10, 10, 12))
        #expect(parse("明天中午1点吃饭", ["明天中午": Self.date(10, 10, 12)]) == Self.timed("吃饭", 10, 10, 13))
        // It finds nothing in these.
        #expect(parse("中午1点开会") == Self.timed("开会", 10, 10, 13))
        #expect(parse("中午12点开会", at: Self.at9am) == Self.timed("开会", 10, 9, 12))
        #expect(parse("傍晚6点散步") == Self.timed("散步", 10, 9, 18))
        #expect(parse("周五傍晚6点散步", ["周五": Self.date(10, 16)]) == Self.timed("散步", 10, 16, 18))
        // Morning and 凌晨 as written; 晚上12点 is midnight, the end of the day.
        #expect(parse("凌晨3点起床") == Self.timed("起床", 10, 10, 3))
        #expect(parse("晚上12点睡觉") == Self.timed("睡觉", 10, 10, 0))
        let hours: [(Int, String, Int)] = [(7, "晚上", 19), (8, "晚", 20), (3, "下午", 15), (6, "傍晚", 18), (12, "晚上", 24),
                                          (12, "中午", 12), (1, "中午", 13), (2, "中午", 14), (11, "中午", 11), (8, "早上", 8),
                                          (10, "上午", 10), (3, "凌晨", 3), (12, "凌晨", 0), (2, "半夜", 2), (12, "半夜", 24),
                                          (20, "晚上", 20)]
        for (hour, part, meant) in hours { #expect(ReminderParser.hour(hour, in: part) == meant, "\(part)\(hour)点") }
    }

    // MARK: - A clock time without its half of the day

    @Test func aBareClockTimeIsTheNextOfMorningAndAfternoon() {
        // h:mm or (h+12):mm, whichever comes first from now, never 0:00–5:59; else tomorrow's first.
        #expect(parse("3点接孩子", at: Self.at1am) == Self.timed("接孩子", 10, 9, 15))
        #expect(parse("8点", at: Self.at9am).due == Self.due(10, 9, 20, 0))
        #expect(parse("8点", at: Self.at9pm).due == Self.due(10, 10, 8, 0))
        #expect(parse("8点开会", at: Self.at1am).due == Self.due(10, 9, 8, 0))
        for (text, hour) in [("十点", 22), ("9点", 21), ("11点", 23), ("8点", 20), ("十一点半", 23)] {
            #expect(parse(text).due?.hour == hour && parse(text).due?.day == 9, "\(text)")
        }
        #expect(parse("4点").due == Self.due(10, 10, 16, 0))  // 16:00 is now: tomorrow's
        // The detector's own guess for the hour doesn't count (it says 03:30 for 3点半 in the morning, 01:30 for 1点半).
        #expect(parse("3点半接孩子", ["3点半": Self.date(10, 9, 3, 30)]) == Self.timed("接孩子", 10, 10, 15, 30))  // 15:30 is over
        #expect(parse("3点半接孩子", ["3点半": Self.date(10, 9, 3, 30)], at: Self.at9am) == Self.timed("接孩子", 10, 9, 15, 30))
        #expect(parse("1点半开会", ["1点半": Self.date(10, 9, 1, 30)], at: Self.at9am).due == Self.due(10, 9, 13, 30))
        #expect(parse("8点半跑步", ["8点半": Self.date(10, 9, 8, 30)]).due == Self.due(10, 9, 20, 30))
        #expect(parse("1:30 call Bob", ["1:30": Self.date(10, 9, 13, 30)], at: Self.at9am) == Self.timed("call Bob", 10, 9, 13, 30))
        #expect(parse("1:30 call Bob", ["1:30": Self.date(10, 9, 13, 30)]) == Self.timed("call Bob", 10, 10, 13, 30))
        // English "at N" (the detector finds nothing there).
        #expect(parse("at 5 leave") == Self.timed("leave", 10, 9, 17))
        #expect(parse("call Bob at 3") == Self.timed("call Bob", 10, 10, 15))
        #expect(parse("call Bob at 3", at: Self.at9am) == Self.timed("call Bob", 10, 9, 15))
        // 12点 is noon.
        #expect(parse("12点吃饭", at: Self.at9am) == Self.timed("吃饭", 10, 9, 12))
        #expect(parse("12点吃饭") == Self.timed("吃饭", 10, 10, 12))
        // 凌晨 / 半夜 written: 3:00 can be meant.
        #expect(parse("3点，凌晨的航班", at: Self.at1am).due == Self.due(10, 9, 3, 0))
        // With a day: that day, the earlier of the two from 6:00 (today: the one still to come).
        #expect(parse("明天3点开会", ["明天3点": Self.date(10, 10, 15)]) == Self.timed("开会", 10, 10, 15))
        #expect(parse("明天8点开会", ["明天8点": Self.date(10, 10, 8)]).due == Self.due(10, 10, 8, 0))
        #expect(parse("今天8点开会", ["今天8点": Self.date(10, 9, 8)], at: Self.at9am).due == Self.due(10, 9, 20, 0))
        #expect(parse("today at 5 call Bob", ["today at 5": Self.date(10, 9, 17)]) == Self.timed("call Bob", 10, 9, 17))
        #expect(parse("Friday at 3", ["Friday at 3": Self.date(10, 16, 15)]).due == Self.due(10, 16, 15, 0))
        #expect(parse("明天一点开会", ["明天": Self.date(10, 10)]) == Self.timed("开会", 10, 10, 13))
    }

    // MARK: - Forms the detector misses

    @Test func formsTheDetectorMisses() {
        // 明早 / 今早 / 早8点 written out (明天早上, 今天早上, 早上8点), which it reads.
        #expect(parse("明早8点开会", ["明天早上8点": Self.date(10, 10, 8)]) == Self.timed("开会", 10, 10, 8))
        #expect(parse("今早9点开会", ["今天早上9点": Self.date(10, 9, 9)]) == Self.timed("开会", 10, 9, 9))  // over: shown so
        #expect(parse("明天早8点开会", ["明天早上8点": Self.date(10, 10, 8)]) == Self.timed("开会", 10, 10, 8))
        #expect(parse("明早8点开会").due == Self.due(10, 10, 8, 0))  // the clock time after 早上 is read here too
        // Days of the month: this month's while still to come (today too), else the next month's.
        #expect(parse("15号交房租") == Self.allDay("交房租", 10, 15))
        #expect(parse("15日交房租").due == Self.due(10, 15) && parse("十五号交房租").due == Self.due(10, 15))
        #expect(parse("9号交房租").due == Self.due(10, 9) && parse("5号交房租").due == Self.due(11, 5))
        #expect(parse("31号交房租", at: Self.date(11, 5)).due == Self.due(12, 31))  // November has no 31st
        #expect(parse("15号下午3点交房租", ["下午3点": Self.date(10, 9, 15)]) == Self.timed("交房租", 10, 15, 15))
        #expect(parse("10月15号交房租", ["10月15号": Self.date(10, 15)]) == Self.allDay("交房租", 10, 15))
        // noon (it reads "at noon" as "noon", and nothing in "noon" alone).
        #expect(parse("lunch at noon", ["noon": Self.date(10, 9, 12)]) == Self.timed("lunch", 10, 10, 12))
        #expect(parse("noon call Bob", at: Self.at9am) == Self.timed("call Bob", 10, 9, 12))
        // Durations in other words.
        let cases: [(String, Int, String)] = [
            ("30 minutes from now check the oven", 30, "check the oven"), ("call mom 2 hours later", 120, "call mom"),
            ("after 30 minutes stretch", 30, "stretch"), ("half an hour later leave", 30, "leave"),
            ("an hour from now call Ann", 60, "call Ann"), ("3日后交报告", 3 * 24 * 60, "交报告"),
        ]
        for (text, minutes, title) in cases {
            let draft = parse(text)
            let when = now.addingTimeInterval(Double(minutes) * 60)
            #expect(draft.title == title && draft.due?.day == Self.calendar.component(.day, from: when), "\(text): \(draft)")
            if minutes < 24 * 60 { #expect(draft.date == when && draft.hasTime, "\(text)") }
        }
    }

    @Test func nextWeekdaySaidAtTheWeekendIsTheComingOne() {
        let saturday = Self.date(10, 10, 12), sunday = Self.date(10, 11, 12), monday = Self.date(10, 12, 12)
        // On a Saturday the detector says 9 days ahead for "next Monday": the coming Monday, like 下周一.
        #expect(parse("next Monday 9:30 standup", ["next Monday 9:30": Self.date(10, 19, 9, 30)], at: saturday)
                == Self.timed("standup", 10, 12, 9, 30))
        #expect(parse("next Tuesday", ["next Tuesday": Self.date(10, 20)], at: saturday).due == Self.due(10, 13))
        #expect(parse("next Sunday", ["next Sunday": Self.date(10, 18)], at: saturday).due == Self.due(10, 18))
        #expect(parse("next Monday call Bob", ["next Monday": Self.date(10, 19)]).due == Self.due(10, 12))  // Friday
        #expect(parse("next Monday call Bob", ["next Monday": Self.date(10, 19)], at: sunday).due == Self.due(10, 12))
        // Monday to Thursday: as it says.
        #expect(parse("next Friday", ["next Friday": Self.date(10, 23)], at: monday).due == Self.due(10, 23))
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
        // Clock times written without their half of the day.
        for phrase in ["3点半", "1:30", "明天3点", "Friday at 3", "today at 5", "十点", "12点", "5 o'clock"] {
            #expect(ReminderParser.bareClock(in: phrase) != nil, "\(phrase)")
        }
        for phrase in ["下午3点", "晚8点", "3pm", "9:30 am", "15:00", "明天", "tonight at 8", "凌晨3点"] {
            #expect(ReminderParser.bareClock(in: phrase) == nil, "\(phrase)")
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
            #expect(draft == ReminderDraft(title: title, due: Self.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: when),
                                           hasTime: true, date: when), "\(text): \(draft)")
        }
        // To the minute.
        let soon = parser().parse("5分钟后", now: Self.date(10, 9, 16).addingTimeInterval(40))
        #expect(soon.due == Self.due(10, 9, 16, 6) && soon.date == Self.date(10, 9, 16, 6))
    }

    @Test func aDurationKeepsItsMomentWhenTheClocksChange() {
        // 2026-11-01 01:50 PDT. 30 minutes on is 01:20 PST: the second 01:20 that night.
        let now = ISO8601DateFormatter().date(from: "2026-11-01T08:50:00Z")!
        let draft = parser().parse("30分钟后关火", now: now)
        #expect(draft.date == now.addingTimeInterval(30 * 60) && draft.due == Self.due(11, 1, 1, 20) && draft.hasTime)
        // The components alone name the first 01:20 (PDT), before now: neither the alarm nor 「已过」 go by them.
        #expect(Self.calendar.date(from: draft.due!)! < now && !draft.isPast(now: now, calendar: Self.calendar))
        #expect(draft.schedule(timeZone: Self.calendar.timeZone).alarm == now.addingTimeInterval(30 * 60))
        #expect(draft.when(now: now, calendar: Self.calendar, chinese: true, clock24: true) == "今天 1:20")
    }

    @Test func daysFromNowAreADay() {
        #expect(parse("3天后交报告") == Self.allDay("交报告", 10, 12))
        #expect(parse("两天后体检").due == Self.due(10, 11))
        #expect(parse("1周后复查").due == Self.due(10, 16))
        #expect(parse("in 3 days pay rent") == Self.allDay("pay rent", 10, 12))
        // NSDataDetector reads "in 3 days" itself (at noon): inside the duration, the duration decides, a day.
        #expect(parse("in 3 days pay rent", ["in 3 days": Self.date(10, 12)]) == Self.allDay("pay rent", 10, 12))
        // With a time of day right after (the detector reads only 下午3点): that day at that time.
        #expect(parse("两天后下午3点体检", ["下午3点": Self.date(10, 9, 15)]) == Self.timed("体检", 10, 11, 15))
        #expect(parse("3天后的上午10点开会", ["上午10点": Self.date(10, 9, 10)]) == Self.timed("开会", 10, 12, 10))
        #expect(parse("3天后3点开会") == Self.timed("开会", 10, 12, 15))
        // In English it reads the duration and the time as one phrase: the time counts, on the duration's day
        // (as of now, not of the detector's clock).
        #expect(parse("pay rent in 3 days at 3pm", ["in 3 days at 3pm": Self.date(10, 12, 15)]) == Self.timed("pay rent", 10, 12, 15))
        #expect(parse("in 2 days at 9am call mom", ["in 2 days at 9am": Self.date(10, 11, 9)]) == Self.timed("call mom", 10, 11, 9))
        #expect(parse("remind me to call Bob in 2 days at 3pm", ["in 2 days at 3pm": Self.date(10, 11, 15)])
                == Self.timed("call Bob", 10, 11, 15))
        #expect(parse("pay rent in 3 days at 3pm", ["in 3 days at 3pm": Self.date(10, 20, 15)]).due == Self.due(10, 12, 15, 0))
        // Not a duration: half a day, no amount, and other words.
        #expect(parse("1.5天后").due == nil && parse("半天后").due == nil && parse("0分钟后").due == nil)
        #expect(parse("within 2 hours").due == nil)
    }

    @Test func smallChineseNumbers() {
        let numbers: [String: Int?] = ["一": 1, "两": 2, "十": 10, "十五": 15, "二十": 20, "三十五": 35, "九十九": 99, "零五": 5,
                                       "一百": nil, "一二": nil, "十十": nil]
        for (text, value) in numbers { #expect(ReminderParser.chineseNumber(text) == value, "\(text)") }
        #expect(parse("3点零五开会").due == Self.due(10, 10, 15, 5) && parse("三点一刻", at: Self.at9am).due == Self.due(10, 9, 15, 15))
        #expect(parse("3点15开会", at: Self.at9am).due == Self.due(10, 9, 15, 15))
    }

    // MARK: - How it is shown, and what goes to Reminders

    @Test func whenItIsDue() {
        func when(_ due: DateComponents?, time: Bool, chinese: Bool, clock24: Bool = true) -> String {
            ReminderDraft(title: "x", due: due, hasTime: time).when(now: now, calendar: Self.calendar, chinese: chinese, clock24: clock24)
        }
        #expect(when(Self.due(10, 10, 15, 0), time: true, chinese: true) == "明天 15:00")
        #expect(when(Self.due(10, 10, 15, 0), time: true, chinese: false) == "tomorrow 15:00")
        #expect(when(Self.due(10, 15), time: false, chinese: true) == "10月15日 周四")
        #expect(when(Self.due(10, 15), time: false, chinese: false) == "Thu, Oct 15")
        #expect(when(Self.due(10, 12, 9, 30), time: true, chinese: true) == "10月12日 周一 9:30")
        #expect(when(Self.due(10, 11), time: false, chinese: true) == "后天")
        #expect(when(Self.due(10, 9, 17, 0), time: true, chinese: true) == "今天 17:00")
        #expect(when(nil, time: false, chinese: true) == "未设时间" && when(nil, time: false, chinese: false) == "no date")
        #expect(when(Self.due(1, 5, year: 2027), time: false, chinese: true) == "2027年1月5日 周二")
        #expect(when(Self.due(1, 5, year: 2027), time: false, chinese: false) == "Tue, Jan 5, 2027")
        // Over: 「已过」 / "overdue". Today's day without a time isn't over yet.
        #expect(when(Self.due(10, 9, 9, 0), time: true, chinese: true) == "今天 9:00 · 已过")
        #expect(when(Self.due(10, 9, 9, 0), time: true, chinese: false) == "today 9:00 · overdue")
        #expect(when(Self.due(10, 8), time: false, chinese: true) == "昨天 · 已过")
        #expect(when(Self.due(10, 9), time: false, chinese: true) == "今天")
        // With the 12-hour clock, when the Mac uses it.
        #expect(when(Self.due(10, 10, 15, 0), time: true, chinese: true, clock24: false) == "明天 下午3:00")
        #expect(when(Self.due(10, 10, 15, 0), time: true, chinese: false, clock24: false) == "tomorrow 3:00 PM")
        #expect(when(Self.due(10, 12, 9, 30), time: true, chinese: true, clock24: false) == "10月12日 周一 上午9:30")
        #expect(when(Self.due(10, 9, 9, 0), time: true, chinese: false, clock24: false) == "today 9:00 AM · overdue")
        #expect(ReminderDraft.clock(hour: 0, minute: 5, chinese: false, clock24: false) == "12:05 AM"
                && ReminderDraft.clock(hour: 12, minute: 0, chinese: true, clock24: false) == "下午12:00"
                && ReminderDraft.clock(hour: 9, minute: 5, chinese: true, clock24: true) == "9:05")
    }

    @Test func whatGoesToReminders() {
        let zone = Self.calendar.timeZone
        // A time: in the zone it was written in, the alarm at its moment.
        let timed = Self.timed("开会", 10, 10, 15).schedule(timeZone: zone)
        #expect(timed.alarm == Self.date(10, 10, 15))
        #expect(timed.due?.calendar?.identifier == .gregorian && timed.due?.timeZone == zone)
        #expect(timed.due?.year == 2026 && timed.due?.month == 10 && timed.due?.day == 10 && timed.due?.hour == 15 && timed.due?.minute == 0)
        // A day: all day and floating, no alarm.
        let day = Self.allDay("交房租", 10, 15).schedule(timeZone: zone)
        #expect(day.alarm == nil && day.due?.timeZone == nil && day.due?.hour == nil && day.due?.minute == nil)
        #expect(day.due?.calendar?.identifier == .gregorian && day.due?.day == 15)
        #expect(ReminderDraft(title: "买牛奶").schedule() == ReminderSchedule(due: nil, alarm: nil))
        // Without its moment (made elsewhere): the components' moment.
        #expect(ReminderDraft(title: "x", due: Self.due(10, 10, 15, 0), hasTime: true).schedule(timeZone: zone).alarm == Self.date(10, 10, 15))
    }

    @Test func remindersReadBackFromReminders() {
        // A day: that day.
        #expect(ReminderDraft(stored: "交房租", due: Self.due(10, 15), calendar: Self.calendar) == Self.allDay("交房租", 10, 15))
        // A time written in Tokyo: the same moment, here (09:00 there is 17:00 the day before in Pacific time).
        var tokyo = DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 0)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")
        tokyo.calendar = Calendar(identifier: .gregorian)
        let call = ReminderDraft(stored: "打电话", due: tokyo, calendar: Self.calendar)
        #expect(call == Self.timed("打电话", 10, 9, 17))
        #expect(!call.isPast(now: now, calendar: Self.calendar) && call.isPast(now: Self.date(10, 9, 18), calendar: Self.calendar))
        // Without a zone: this one's.
        let morning = ReminderDraft(stored: "x", due: Self.due(10, 9, 9, 0), calendar: Self.calendar)
        #expect(morning == Self.timed("x", 10, 9, 9) && morning.isPast(now: now, calendar: Self.calendar))
        #expect(ReminderDraft(stored: "x", due: nil) == ReminderDraft(title: "x"))
        #expect(ReminderDraft(stored: "x", due: DateComponents(hour: 9)) == ReminderDraft(title: "x"))
    }

    // MARK: - The real NSDataDetector, relative to now

    /// Now, not in the last seconds of a day: the detector reads its own clock, and the expectations below
    /// are worked out from this `now`; across midnight the two would be different days.
    static func realNow() -> Date {
        let calendar = ReminderParser.localCalendar
        let now = Date()
        let left = calendar.dateInterval(of: .day, for: now)!.end.timeIntervalSince(now)
        guard left < 5 else { return now }
        Thread.sleep(forTimeInterval: left + 1)
        return Date()
    }

    /// `days` after `now`'s day at that time, as the draft's components.
    static func on(_ days: Int, at hour: Int, _ minute: Int = 0, from now: Date) -> DateComponents {
        let calendar = ReminderParser.localCalendar
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                       from: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!)
    }

    /// Today's `hour:minute` if still to come at `now`, else tomorrow's.
    static func next(_ hour: Int, _ minute: Int = 0, from now: Date) -> DateComponents {
        let today = on(0, at: hour, minute, from: now)
        return ReminderParser.localCalendar.date(from: today)! > now ? today : on(1, at: hour, minute, from: now)
    }

    /// Minutes from now, as the parser rounds them.
    func fromNow(_ seconds: TimeInterval, _ draft: ReminderDraft, at now: Date) -> Bool {
        guard let date = draft.date else { return false }
        return abs(date.timeIntervalSince(now.addingTimeInterval(seconds))) <= 30 && draft.hasTime
    }

    @Test func theSystemsDetectorInChinese() {
        let now = Self.realNow()
        let parser = ReminderParser()
        func parse(_ text: String) -> ReminderDraft { parser.parse(text, now: now) }
        let call = parse("明天下午3点给张三打电话")
        #expect(call.title == "给张三打电话" && call.due == Self.on(1, at: 15, from: now) && call.hasTime, "\(call)")
        let off = parse("30分钟后关火")
        #expect(off.title == "关火" && fromNow(30 * 60, off, at: now), "\(off)")
        let water = parse("半小时后提醒我喝水")
        #expect(water.title == "喝水" && fromNow(30 * 60, water, at: now), "\(water)")
        // Only a day: no time.
        let day = parse("明天给张三打电话")
        #expect(day.title == "给张三打电话" && !day.hasTime && day.due?.hour == nil && day.due?.day == Self.on(1, at: 0, from: now).day)
        // What it misses or reads wrong.
        let dinner = parse("明晚7点吃饭")
        #expect(dinner.title == "吃饭" && dinner.due == Self.on(1, at: 19, from: now), "\(dinner)")
        let meeting = parse("明早8点开会")
        #expect(meeting.title == "开会" && meeting.due == Self.on(1, at: 8, from: now), "\(meeting)")
        let lunch = parse("中午十二点吃饭")
        #expect(lunch.title == "吃饭" && lunch.due == Self.next(12, from: now), "\(lunch)")
        let pickUp = parse("3点半接孩子")
        #expect(pickUp.title == "接孩子" && pickUp.due == Self.next(15, 30, from: now), "\(pickUp)")
        #expect(parse("关于明天下午3点的会议").title == "关于会议")
        let report = parse("周五前交报告")
        #expect(report.title == "交报告" && !report.hasTime && report.due.flatMap { ReminderParser.localCalendar.date(from: $0) }
                .map { ReminderParser.localCalendar.component(.weekday, from: $0) } == 6, "\(report)")
        #expect(parse("提醒我一下明天交报告").title == "交报告")
        #expect(parse("买3斤苹果") == ReminderDraft(title: "买3斤苹果") && parse("晚一点出发").due == nil)
    }

    @Test func theSystemsDetectorInEnglish() {
        let now = Self.realNow()
        let parser = ReminderParser()
        func parse(_ text: String) -> ReminderDraft { parser.parse(text, now: now) }
        let call = parse("remind me to call Bob tomorrow at 3pm")
        #expect(call.title == "call Bob" && call.due == Self.on(1, at: 15, from: now), "\(call)")
        let oven = parse("in 2 hours check the oven")
        #expect(oven.title == "check the oven" && fromNow(2 * 3600, oven, at: now), "\(oven)")
        #expect(parse("buy milk") == ReminderDraft(title: "buy milk"))
        let rent = parse("pay rent in 3 days at 3pm")
        #expect(rent.title == "pay rent" && rent.due == Self.on(3, at: 15, from: now), "\(rent)")
        let lunch = parse("tomorrow lunch with Ann")
        #expect(lunch.title == "lunch with Ann" && !lunch.hasTime && lunch.due?.day == Self.on(1, at: 0, from: now).day, "\(lunch)")
        let leave = parse("at 5 leave")
        #expect(leave.title == "leave" && leave.due == Self.next(17, from: now), "\(leave)")
        let standup = parse("next Monday 9:30 standup")
        let weekday = ReminderParser.localCalendar.component(.weekday, from: now)
        #expect(standup.title == "standup" && standup.due?.hour == 9 && standup.due?.minute == 30, "\(standup)")
        if [6, 7, 1].contains(weekday) {  // Friday to Sunday: the coming Monday
            #expect(standup.due == Self.on((9 - weekday) % 7, at: 9, 30, from: now), "\(standup)")
        }
    }
}
