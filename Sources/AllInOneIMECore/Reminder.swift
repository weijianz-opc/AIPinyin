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
    /// The moment it is due, with a time: what the alarm and `isPast` go by. The components can't always
    /// say it: the night summer time ends, 1:20 comes twice, and "30分钟后" said at 1:50 means the second.
    public var date: Date?

    public init(title: String, due: DateComponents? = nil, hasTime: Bool = false, date: Date? = nil) {
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.date = date
    }

    /// Whether the time it is due (without a time: the day) is over at `now`.
    public func isPast(now: Date, calendar: Calendar = ReminderParser.localCalendar) -> Bool {
        if hasTime, let date { return date < now }
        guard let due, let day = calendar.date(from: due) else { return false }
        return hasTime ? day < now : calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    /// When it is due, as the panel and the notice say it: 「明天 15:00」 (「明天 下午3:00」 with the 12-hour
    /// clock), 「10月15日 周四」, 「未设时间」 ("tomorrow 3:00 PM", "Thu, Oct 15", "no date"), with 「已过」 /
    /// "overdue" once that time is over.
    public func when(now: Date, calendar: Calendar = ReminderParser.localCalendar, chinese: Bool,
                     clock24: Bool = ReminderDraft.systemUses24HourClock) -> String {
        guard let due, let date = calendar.date(from: due) else { return chinese ? "未设时间" : "no date" }
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
        if hasTime, let hour = due.hour, let minute = due.minute {
            text += " " + Self.clock(hour: hour, minute: minute, chinese: chinese, clock24: clock24)
        }
        if isPast(now: now, calendar: calendar) { text += chinese ? " · 已过" : " · overdue" }
        return text
    }

    /// A time of day the way this Mac shows times: "15:00" with the 24-hour clock, else 「下午3:00」 / "3:00 PM".
    public static func clock(hour: Int, minute: Int, chinese: Bool, clock24: Bool) -> String {
        if clock24 { return String(format: "%d:%02d", hour, minute) }
        let time = String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute)
        if chinese { return (hour < 12 ? "上午" : "下午") + time }
        return time + (hour < 12 ? " AM" : " PM")
    }

    /// Whether this Mac shows times with the 24-hour clock (System Settings → General → Date & Time).
    /// Read each time: the setting can change while the input method runs.
    public static var systemUses24HourClock: Bool {
        switch Locale.autoupdatingCurrent.hourCycle {
        case .zeroToTwentyThree, .oneToTwentyFour: return true
        default: return false
        }
    }
}

/// What goes to Apple Reminders for a draft (`ReminderDraft.schedule`).
public struct ReminderSchedule: Equatable, Sendable {
    /// The due date as EventKit takes it (with the Gregorian calendar, without which it raises an
    /// exception): a day without a time is all day and floats; a time keeps the zone it was written in.
    public var due: DateComponents?
    /// When the alarm goes off: the moment it is due, for a draft with a time.
    public var alarm: Date?
}

extension ReminderDraft {
    /// The due date and alarm for Reminders. The alarm is the exact moment (`date`), not the components
    /// read again: those can name the hour that comes twice when summer time ends.
    public func schedule(timeZone: TimeZone = .current) -> ReminderSchedule {
        guard var due else { return ReminderSchedule(due: nil, alarm: nil) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        due.calendar = calendar
        guard hasTime else {
            (due.hour, due.minute, due.second, due.nanosecond, due.timeZone) = (nil, nil, nil, nil, nil)
            return ReminderSchedule(due: due, alarm: nil)
        }
        due.timeZone = timeZone
        return ReminderSchedule(due: due, alarm: date ?? calendar.date(from: due))
    }

    /// A reminder as Reminders keeps it, read in `calendar` (this Mac's zone): a time written in another
    /// zone keeps its moment (and is shown in this one); a day without a time stays that day.
    public init(stored title: String, due components: DateComponents?, calendar: Calendar = ReminderParser.localCalendar) {
        self.init(title: title)
        guard let components, let year = components.year, let month = components.month, let day = components.day else { return }
        guard components.hour != nil else {
            due = DateComponents(year: year, month: month, day: day)
            return
        }
        var written = components.calendar ?? Calendar(identifier: .gregorian)
        written.timeZone = components.timeZone ?? calendar.timeZone
        guard let moment = written.date(from: components) else { return }
        due = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
        hasTime = true
        date = moment
    }
}

/// Reads the date and time in a reminder's text, on this Mac: nothing is sent anywhere.
///
/// NSDataDetector finds most dates and times ("明天下午3点", "下周一 9:30", "tomorrow at 3pm"). What it misses
/// or gets wrong is read here:
/// - 明早 / 今早 / 明晚 and 早8点, which it reads written out (明天早上, 早上8点);
/// - a part of the day and a clock time after it, in that half of the day ("中午十二点", "傍晚6点"; it reads
///   中午 alone, or nothing);
/// - a clock time without its half of the day ("3点半", "8点", "1:30", "at 5"): the next of h:mm and
///   (h+12):mm, never 0:00–5:59 unless 凌晨 / 半夜 is written;
/// - "15号" (the next 15th), "noon", and durations ("30分钟后", "半小时后", "3天后", "in 2 hours",
///   "30 minutes from now", "2 hours later"), with a time of day after a number of days ("3天后下午3点",
///   "in 3 days at 3pm");
/// - "next Monday" said Friday to Sunday is the coming one, like 下周一; a meal ("tomorrow lunch") stays in
///   the title.
/// A time of day without a day that has already passed today means tomorrow. The first date in the text is
/// the reminder's; the rest of the text is its title, without a leading 「提醒我」 / "remind me to".
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
    /// tests pass their own, so what they expect doesn't depend on today's date. It is given the text
    /// as the rules read it (`Written`: 明晚 → 明天晚上 …).
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
        let written = Written(text)
        let source = written.text
        let night = source.contains("凌晨") || source.contains("半夜")
        var durations = Self.durations(in: source)
        var phrases = Self.merged(detected(in: source, now: now) + own(in: source, now: now), in: source)
        // A date read inside a duration is the duration's ("in 3 days", which the detector reads too). One that
        // covers it and goes on with a time ("in 3 days at 3pm"), or a time right after it ("3天后下午3点"),
        // is that day's time.
        for index in durations.indices {
            let duration = durations[index]
            phrases.removeAll { phrase in
                guard phrase.range.overlaps(duration.range) else { return false }
                if duration.isDays, durations[index].time == nil, phrase.range.upperBound > duration.range.upperBound,
                   let time = phrase.time {
                    durations[index].time = time
                    durations[index].extent = duration.range.lowerBound..<phrase.range.upperBound
                }
                return true
            }
            if duration.isDays, durations[index].time == nil,
               let next = phrases.firstIndex(where: { $0.range.lowerBound >= duration.range.upperBound }),
               phrases[next].day == nil, let time = phrases[next].time,
               Self.onlyJoins(source[duration.range.upperBound..<phrases[next].range.lowerBound]) {
                durations[index].time = time
                durations[index].extent = duration.range.lowerBound..<phrases[next].range.upperBound
                phrases.remove(at: next)
            }
        }
        let firstPhrase = phrases.first
        if let duration = durations.first, firstPhrase.map({ duration.range.lowerBound <= $0.range.lowerBound }) ?? true {
            return draft(written, duration: duration, now: now, night: night)
        }
        guard let phrase = firstPhrase, let (date, hasTime) = moment(of: phrase, now: now, night: night) else {
            return ReminderDraft(title: Self.title(text, without: nil))
        }
        return draft(written, range: phrase.range, date: date, hasTime: hasTime)
    }

    private func draft(_ written: Written, range: Range<String.Index>, date: Date, hasTime: Bool) -> ReminderDraft {
        let fields: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        return ReminderDraft(title: Self.title(written.original, without: written.originalRange(range)),
                             due: calendar.dateComponents(fields, from: date), hasTime: hasTime, date: hasTime ? date : nil)
    }

    /// Minutes and hours from now are a time (to the minute, the moment itself: the alarm goes off then, also
    /// across a change of the clocks); days and weeks are a day, or that day at the time written with them.
    private func draft(_ written: Written, duration: Duration, now: Date, night: Bool) -> ReminderDraft {
        switch duration.unit {
        case .minute, .hour:
            let seconds = duration.amount * (duration.unit == .minute ? 60 : 3600)
            let date = Date(timeIntervalSinceReferenceDate: ((now.timeIntervalSinceReferenceDate + seconds) / 60).rounded() * 60)
            return draft(written, range: duration.range, date: date, hasTime: true)
        case .day, .week:
            let days = Int(duration.amount) * (duration.unit == .week ? 7 : 1)
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            if let time = duration.time, let date = moment(time, on: day, now: now, night: night) {
                return draft(written, range: duration.extent, date: date, hasTime: true)
            }
            return draft(written, range: duration.range, date: day, hasTime: false)
        }
    }

    // MARK: - When a phrase is

    /// A date or time read from the text (as the rules read it): where, the day it names (year, month,
    /// day), and the time of day it gives.
    struct Phrase {
        var range: Range<String.Index>
        var day: DateComponents?
        var time: Time?
        /// Found by the detector (for the same words, its reading stands).
        var detected = false
    }

    /// A time of day as written. `ambiguous`: without its half of the day ("3点", "1:30", "at 5"), so h or
    /// h+12. An hour of 24 is midnight at the end of the day (晚上12点).
    struct Time: Equatable {
        var hour: Int
        var minute: Int
        var ambiguous = false
    }

    /// When `phrase` is: its day (all day), its time of day on that day, or a time of day alone, the next one.
    private func moment(of phrase: Phrase, now: Date, night: Bool) -> (date: Date, hasTime: Bool)? {
        let day = phrase.day.flatMap { calendar.date(from: $0) }
        guard let time = phrase.time else { return day.map { ($0, false) } }
        return moment(time, on: day, now: now, night: night).map { ($0, true) }
    }

    /// The moment `time` means: on `day` (still that day if it is over, and today the one still to come), or
    /// without a day the next such time from now. A clock time without its half of the day is h:mm or
    /// (h+12):mm, never 0:00–5:59 unless `night` (凌晨 / 半夜 is written); 12点 is noon.
    private func moment(_ time: Time, on day: Date?, now: Date, night: Bool) -> Date? {
        var hours = [time.hour]
        if time.ambiguous, time.hour < 12 { hours = [time.hour, time.hour + 12].filter { night || $0 >= 6 } }
        func candidates(on day: Date) -> [Date] {
            hours.compactMap { hour in
                calendar.date(byAdding: .day, value: hour / 24, to: day).flatMap {
                    calendar.date(bySettingHour: hour % 24, minute: time.minute, second: 0, of: $0)
                }
            }.sorted()
        }
        if let day {
            let all = candidates(on: day)
            return calendar.isDate(day, inSameDayAs: now) ? all.first { $0 > now } ?? all.last : all.first
        }
        let today = calendar.startOfDay(for: now)
        if let next = candidates(on: today).first(where: { $0 > now }) { return next }
        return calendar.date(byAdding: .day, value: 1, to: today).flatMap { candidates(on: $0).first }
    }

    /// What the detector found, each read again here: the day if it names one, the time of day (a clock time
    /// written without its half of the day is read here: the detector guesses), "next Monday".
    private func detected(in source: String, now: Date) -> [Phrase] {
        detect(source).compactMap { match -> Phrase? in
            // A meal it takes for a time ("tomorrow lunch", 「明天午饭」) is what the reminder is for; 「晚一点」
            // ("a bit later"), which it reads as 13:00, is no time.
            let range = Self.withoutALittle(Self.withoutMeal(match.range, in: source), in: source)
            guard !range.isEmpty else { return nil }
            let phrase = String(source[range])
            var time: Time?
            if let clock = Self.bareClock(in: phrase) {
                time = clock
            } else if Self.mentionsTime(phrase) {
                let parts = calendar.dateComponents([.hour, .minute], from: match.date)
                time = Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            }
            var day: DateComponents?
            if Self.mentionsDay(phrase) || time == nil { day = calendar.dateComponents([.year, .month, .day], from: match.date) }
            if let coming = comingWeekday(in: phrase, now: now) { day = coming }
            return Phrase(range: range, day: day, time: time, detected: true)
        }
    }

    /// What the detector misses, read here: clock times (with the part of the day before them, if any),
    /// "noon", and days of the month ("15号").
    private func own(in source: String, now: Date) -> [Phrase] {
        var found: [Phrase] = []
        for clock in Self.clocks(in: source) {
            if clock.meridiem == nil, let part = Self.partOfDay(before: clock.range.lowerBound, in: source) {
                // 中午十二点, 傍晚6点, 晚上 7点半: that half of the day.
                guard let hour = Self.hour(clock.hour, in: part.word) else { continue }
                found.append(Phrase(range: part.start..<clock.range.upperBound, time: Time(hour: hour, minute: clock.minute)))
            } else {
                found.append(Phrase(range: clock.range, time: clock.time))
            }
        }
        for match in Self.noon.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range, in: source) { found.append(Phrase(range: range, time: Time(hour: 12, minute: 0))) }
        }
        for (range, number) in Self.daysOfMonth(in: source) {
            if let day = dayOfMonth(number, now: now) { found.append(Phrase(range: range, day: day)) }
        }
        return found
    }

    /// Phrases that overlap are one (the detector's 「明天中午」 and 「中午十二点」 read here); a day and a time
    /// of day right next to each other too ("15号下午3点", "周五 傍晚6点"). In order.
    static func merged(_ phrases: [Phrase], in source: String) -> [Phrase] {
        let sorted = phrases.sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            if $0.range.upperBound != $1.range.upperBound { return $0.range.upperBound > $1.range.upperBound }
            return $0.detected && !$1.detected
        }
        var out: [Phrase] = []
        for phrase in sorted {
            guard var last = out.last else {
                out.append(phrase)
                continue
            }
            if phrase.range.lowerBound < last.range.upperBound {
                // Inside the one before: that reading stands (the detector's, for the same words).
                guard phrase.range.upperBound > last.range.upperBound else { continue }
                // Going on past it: the later one reads the clock time (「中午」 + 「中午十二点」).
                last.range = last.range.lowerBound..<phrase.range.upperBound
                last.day = last.day ?? phrase.day
                last.time = phrase.time ?? last.time
            } else if onlyJoins(source[last.range.upperBound..<phrase.range.lowerBound]),
                      last.day != nil && last.time == nil && phrase.day == nil && phrase.time != nil
                        || last.time != nil && last.day == nil && phrase.day != nil && phrase.time == nil {
                last.range = last.range.lowerBound..<phrase.range.upperBound
                last.day = last.day ?? phrase.day
                last.time = last.time ?? phrase.time
            } else {
                out.append(phrase)
                continue
            }
            out[out.count - 1] = last
        }
        return out
    }

    /// Only spaces or a 「的」 between two phrases ("3天后的下午3点"): they go together.
    static func onlyJoins(_ text: Substring) -> Bool { text.allSatisfy { $0.isWhitespace || $0 == "的" } }

    /// "next Monday" said on a Friday, Saturday or Sunday: the coming Monday, like 下周一 (the detector skips
    /// a week for some days, e.g. 9 days ahead on a Saturday).
    private func comingWeekday(in phrase: String, now: Date) -> DateComponents? {
        guard let match = Self.nextWeekday.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
              let range = Range(match.range(withName: "day"), in: phrase),
              let offset = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].firstIndex(of: phrase[range].lowercased()) else { return nil }
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)  // 1 Sunday … 6 Friday, 7 Saturday
        guard [6, 7, 1].contains(weekday), let date = calendar.date(byAdding: .day, value: (9 - weekday) % 7 + offset, to: today) else {
            return nil
        }
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// The next 15th for "15号": this month's if it is still to come (today counts), else the next month that has one.
    private func dayOfMonth(_ number: Int, now: Date) -> DateComponents? {
        let today = calendar.startOfDay(for: now)
        var month = calendar.dateComponents([.year, .month], from: today)
        for _ in 0..<12 {
            if let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: number)),
               calendar.component(.day, from: date) == number, date >= today {
                return calendar.dateComponents([.year, .month, .day], from: date)
            }
            guard let next = calendar.date(from: DateComponents(year: month.year, month: (month.month ?? 1) + 1, day: 1)) else { return nil }
            month = calendar.dateComponents([.year, .month], from: next)
        }
        return nil
    }

    private static let nextWeekday = try! NSRegularExpression(pattern: "\\bnext\\s+(?<day>mon|tue|wed|thu|fri|sat|sun)[a-z]*\\b",
                                                              options: .caseInsensitive)

    // MARK: - Clock times

    /// A clock time read here: where, the hour and minute as written, and "am" / "pm" when written ("a" / "p").
    struct Clock {
        var range: Range<String.Index>
        var hour: Int
        var minute: Int
        var meridiem: Character?

        /// With am / pm, or 0 and 13–24: exact. 1–12 without: either half of the day.
        var time: Time {
            if let meridiem { return Time(hour: hour % 12 + (meridiem == "p" ? 12 : 0), minute: minute) }
            return Time(hour: hour, minute: minute, ambiguous: (1...12).contains(hour))
        }
    }

    /// 3点, 3点半, 3点15(分), 三点一刻, 十点, 3点钟; not 第3点, 0.5点.
    private static let chineseClock = try! NSRegularExpression(pattern:
        "(?<![0-9.．:：第周期拜零〇一二两三四五六七八九十百千万])(?<h>[0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\\s*[点點]"
        + "(?:\\s*(?:(?<half>半)|(?<quarter>[一三])\\s*刻|(?<m>[0-9]{1,2}(?![0-9])|[零〇一二三四五六七八九十]{1,3})\\s*分?|钟|整))?")
    /// The other forms, each with the groups it has: 9:30 (am / pm), 15时30分, at 5 (:30, pm), 5 o'clock, 5pm.
    private static let latinClocks: [(NSRegularExpression, [String])] = [
        ("(?<![0-9:：.])(?<h>[0-9]{1,2})\\s*[:：]\\s*(?<m>[0-9]{2})(?![0-9])(?:\\s*(?<ampm>[ap])\\.?\\s*m\\b\\.?)?", ["h", "m", "ampm"]),
        ("(?<![0-9.])(?<h>[0-9]{1,2})\\s*[时時](?:\\s*(?<m>[0-9]{1,2})\\s*分)?(?![间候期代长差段])", ["h", "m"]),
        ("\\bat\\s+(?<h>[0-9]{1,2})(?:[:.](?<m>[0-9]{2}))?(?![0-9%])(?:\\s*(?<ampm>[ap])\\.?\\s*m\\b\\.?)?(?!\\s*o['’]?clock)",
         ["h", "m", "ampm"]),
        ("\\b(?:at\\s+)?(?<h>[0-9]{1,2})\\s*o['’]?clock\\b", ["h"]),
        ("\\b(?<h>[0-9]{1,2})\\s*(?<ampm>[ap])\\.?\\s*m\\b\\.?", ["h", "ampm"]),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    private static let noon = try! NSRegularExpression(pattern: "\\b(?:at\\s+)?(?:noon|midday)\\b", options: .caseInsensitive)

    /// 「点」 starting a word of its own after a number: 3点赞, 点评 — not a time.
    private static let wordsWithDian: Set<Character> = ["击", "赞", "评", "名", "菜", "单", "数", "子", "心", "滴", "缀", "播", "燃", "亮", "破", "头"]
    /// 「一点」 is mostly "a little": 买一点水果, 快一点, 晚一点, 有一点, 一点也不, 一点儿, 给我一点时间.
    private static let aLittleBefore: Set<Character> = Set("有早晚快慢多少好大小高低长短近远轻重稍差这那买吃喝带拿要留省加放写看学点些再又更还就找做用弄存赚花剩挤让来去走跑睡起")
    private static let aLittleAfter: Set<Character> = Set("儿点也都些时钱事东水吧啊呀")

    /// The clock times in `text`, in order; where two readings overlap ("at 5:30" and "5:30"), the longer.
    static func clocks(in text: String) -> [Clock] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Clock] = chineseClock.matches(in: text, range: whole).compactMap { readChineseClock($0, in: text) }
        for (regex, names) in latinClocks {
            for match in regex.matches(in: text, range: whole) {
                func group(_ name: String) -> Substring? {
                    names.contains(name) ? Range(match.range(withName: name), in: text).map { text[$0] } : nil
                }
                guard let range = Range(match.range, in: text), let hour = group("h").flatMap({ Int($0) }), hour <= 24,
                      case let minute = group("m").flatMap({ Int($0) }) ?? 0, minute < 60 else { continue }
                let meridiem = group("ampm")?.lowercased().first
                if meridiem != nil, !(1...12).contains(hour) { continue }
                found.append(Clock(range: range, hour: hour, minute: minute, meridiem: meridiem))
            }
        }
        found.sort { ($0.range.lowerBound, $1.range.upperBound) < ($1.range.lowerBound, $0.range.upperBound) }
        var out: [Clock] = []
        for clock in found where !(out.last.map { clock.range.lowerBound < $0.range.upperBound } ?? false) { out.append(clock) }
        return out
    }

    private static func readChineseClock(_ match: NSTextCheckingResult, in text: String) -> Clock? {
        func group(_ name: String) -> String? { Range(match.range(withName: name), in: text).map { String(text[$0]) } }
        guard let range = Range(match.range, in: text), let written = group("h"), let hour = number(written), hour <= 24 else { return nil }
        var minute = 0
        if group("half") != nil {
            minute = 30
        } else if let quarter = group("quarter") {
            minute = quarter == "一" ? 15 : 45
        } else if let m = group("m") {
            guard let value = number(m), value < 60 else { return nil }
            minute = value
        }
        // Ends at 「点」: it may start another word (点赞), or be "a little" (一点).
        if let last = text[range].last, last == "点" || last == "點" {
            if let next = text[range.upperBound...].first, wordsWithDian.contains(next) { return nil }
            if written == "一" {
                if let before = text[..<range.lowerBound].last, aLittleBefore.contains(before) { return nil }
                if let after = text[range.upperBound...].first, aLittleAfter.contains(after) { return nil }
            }
        }
        return Clock(range: range, hour: hour, minute: minute, meridiem: nil)
    }

    /// A clock time written without its half of the day ("3点半", "1:30", "明天3点", "Friday at 3"): it may be
    /// in the morning or the afternoon. Nil when the phrase says which (下午, 晚, am, tonight, …) or has none.
    static func bareClock(in phrase: String) -> Time? {
        guard !saysHalfOfDay(phrase), let time = clocks(in: phrase).first?.time, time.ambiguous else { return nil }
        return time
    }

    /// Whether a phrase says which half of the day: 早, 晚, 午, 夜, 晨 (上午, 傍晚, 凌晨 …), am, pm, tonight, noon …
    static func saysHalfOfDay(_ phrase: String) -> Bool {
        if phrase.contains(where: { "早晚午夜晨".contains($0) }) { return true }
        return phrase.range(of: "\\b(a\\.?m|p\\.?m|morning|afternoon|evening|night|tonight|noon|midday|midnight)\\b|[0-9]\\s*[ap]\\.?m\\b",
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Parts of the day a clock time can follow, longest first.
    private static let partsOfDay = ["早上", "早晨", "清晨", "上午", "中午", "正午", "下午", "傍晚", "晚上", "夜里", "夜间", "凌晨",
                                     "半夜", "午夜", "今晚", "明晚", "今早", "明早", "早", "晚"]

    /// The part of the day written right before `index` (spaces between are fine), and where it starts.
    static func partOfDay(before index: String.Index, in text: String) -> (word: String, start: String.Index)? {
        var end = index
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        let before = text[..<end]
        guard let word = partsOfDay.first(where: { before.hasSuffix($0) }) else { return nil }
        return (word, text.index(end, offsetBy: -word.count))
    }

    /// The hour `hour` means after `part`: 晚上 / 下午 / 傍晚 1–11 are after noon (晚上12点 is midnight, the
    /// day's end); 中午 12 is noon and 1–2 just after; 早上 / 上午 / 凌晨 as written (凌晨12点: the start of the
    /// day); 半夜 / 夜里 as written (12: midnight). Nil for an hour no clock has.
    static func hour(_ hour: Int, in part: String) -> Int? {
        guard hour <= 24 else { return nil }
        switch part {
        case "下午", "傍晚":
            return (1...11).contains(hour) ? hour + 12 : hour
        case "晚上", "晚", "今晚", "明晚":
            return (1...11).contains(hour) ? hour + 12 : hour == 12 ? 24 : hour
        case "中午", "正午":
            return (1...2).contains(hour) ? hour + 12 : hour
        case "半夜", "午夜", "夜里", "夜间":
            return hour == 12 ? 24 : hour
        case "凌晨":
            return hour == 12 ? 0 : hour
        default:
            return hour
        }
    }

    // MARK: - Days of the month

    /// 15号, 15日, 十五号; not 3号线, 5号楼, 500日元, 10月15日 (the detector reads that).
    private static let dayOfMonthPattern: NSRegularExpression = {
        let notADay = "楼樓线線门門床位房馆館厅廳机機车車桌口码碼窗台柜櫃店院厂廠箱球字座舱艙站道元币幣游遊队隊员員件包罐框键鍵文内"
        return try! NSRegularExpression(pattern:
            "(?<![0-9０-９月第./-])(?<d>[0-9]{1,2})\\s*[号號日](?![\(notADay)])"
            + "|(?<![零〇一二两三四五六七八九十月第])(?<c>[一二三四五六七八九十]{1,3})\\s*[号號](?![\(notADay)])")
    }()

    static func daysOfMonth(in text: String) -> [(Range<String.Index>, Int)] {
        dayOfMonthPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let digits = Range(match.range(withName: "d"), in: text).flatMap { Int(text[$0]) }
            let chinese = Range(match.range(withName: "c"), in: text).flatMap { chineseNumber(String(text[$0])) }
            guard let day = digits ?? chinese, (1...31).contains(day) else { return nil }
            return (range, day)
        }
    }

    // MARK: - Meals

    private static let meals = ["breakfast", "brunch", "lunch", "dinner", "supper", "早饭", "早餐", "午饭", "午餐", "中饭", "晚饭", "晚餐"]

    /// The detector's phrase without a meal at either end ("tomorrow lunch", "lunch tomorrow", 「明天午饭」): the
    /// meal is what the reminder is for, and stays in the title.
    static func withoutMeal(_ range: Range<String.Index>, in source: String) -> Range<String.Index> {
        var phrase = source[range]
        if let found = meals.lazy.compactMap({ phrase.range(of: $0, options: [.caseInsensitive, .anchored, .backwards]) }).first,
           found.lowerBound == phrase.startIndex || !isLatin(phrase[phrase.index(before: found.lowerBound)]) {
            phrase = phrase[..<found.lowerBound]
        }
        if let found = meals.lazy.compactMap({ phrase.range(of: $0, options: [.caseInsensitive, .anchored]) }).first,
           found.upperBound == phrase.endIndex || !isLatin(phrase[found.upperBound]) {
            phrase = phrase[found.upperBound...]
        }
        while let first = phrase.first, first.isWhitespace { phrase = phrase.dropFirst() }
        while let last = phrase.last, last.isWhitespace { phrase = phrase.dropLast() }
        return phrase.startIndex..<phrase.endIndex
    }

    /// The detector's phrase without a 「晚一点」 / 「早一点」 at its end ("a bit later / earlier": 「明天晚一点」 is
    /// tomorrow, no time).
    static func withoutALittle(_ range: Range<String.Index>, in source: String) -> Range<String.Index> {
        var phrase = source[range]
        if phrase.hasSuffix("儿") { phrase = phrase.dropLast() }
        guard phrase.hasSuffix("晚一点") || phrase.hasSuffix("早一点") else { return range }
        phrase = phrase.dropLast(3)
        while let last = phrase.last, last.isWhitespace { phrase = phrase.dropLast() }
        return phrase.startIndex..<phrase.endIndex
    }

    // MARK: - The text as the rules read it

    /// The text with what the detector misses written out (明早 → 明天早上, 今早 → 今天早上, 明晚 → 明天晚上,
    /// 早8点 → 早上8点), and the way back to the text as typed for the title.
    struct Written {
        let original: String
        let text: String
        /// For each Character of `text`: the Characters (offsets) of `original` it stands for.
        private let origins: [Range<Int>]

        private static let words = ["明早": "明天早上", "今早": "今天早上", "明晚": "明天晚上"]

        init(_ original: String) {
            self.original = original
            let chars = Array(original)
            var text = "", origins: [Range<Int>] = []
            var i = 0
            while i < chars.count {
                var replacement: (word: String, length: Int)?
                if i + 1 < chars.count, let word = Self.words[String(chars[i...(i + 1)])] {
                    replacement = (word, 2)
                } else if chars[i] == "早", Self.clockFollows(chars, from: i + 1) {
                    replacement = ("早上", 1)
                }
                if let (word, length) = replacement {
                    text += word
                    origins += Array(repeating: i..<(i + length), count: word.count)
                    i += length
                } else {
                    text.append(chars[i])
                    origins.append(i..<(i + 1))
                    i += 1
                }
            }
            self.text = text
            self.origins = origins
        }

        /// 早 + 8点 / 八点 / 8:30 (not 早一点: "a bit earlier").
        private static func clockFollows(_ chars: [Character], from start: Int) -> Bool {
            var i = start
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            let digits = i
            while i < chars.count, chars[i].isASCII && chars[i].isNumber || "零〇一二两三四五六七八九十".contains(chars[i]) { i += 1 }
            guard i > digits, i < chars.count, !(i == digits + 1 && chars[digits] == "一") else { return false }
            return "点點:：".contains(chars[i])
        }

        /// The range of the text as typed that `range` (in `text`) came from.
        func originalRange(_ range: Range<String.Index>) -> Range<String.Index> {
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            let from = lower < origins.count ? origins[lower].lowerBound : original.count
            let to = upper > lower ? origins[min(upper, origins.count) - 1].upperBound : from
            return original.index(original.startIndex, offsetBy: from)..<original.index(original.startIndex, offsetBy: to)
        }
    }

    // MARK: - Durations

    /// "30分钟后", "in 2 hours": an amount of time from now.
    struct Duration: Equatable {
        enum Unit: Equatable { case minute, hour, day, week }
        var range: Range<String.Index>
        var amount: Double
        var unit: Unit
        /// A time of day written with a number of days ("3天后下午3点", "in 3 days at 3pm"), and the whole of it.
        var time: Time?
        var extent: Range<String.Index>

        init(range: Range<String.Index>, amount: Double, unit: Unit) {
            self.range = range
            self.amount = amount
            self.unit = unit
            extent = range
        }

        var isDays: Bool { unit == .day || unit == .week }
    }

    private static let chineseDuration = try! NSRegularExpression(pattern:
        "(?:(?<n>[0-9]+(?:\\.[0-9]+)?|[零〇一二两三四五六七八九十]+)\\s*个?\\s*(?<plushalf>半)?|(?<half>半)\\s*个?)"
        + "\\s*(?<unit>分钟|小时|钟头|天|日|周|星期|礼拜)\\s*(?:以后|之后|后)")
    /// An amount of time in English: "30 minutes", "30min", "2h", "an hour and a half", "half an hour", "3 days".
    private static let englishAmount =
        "(?:(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*|(?<w>an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|"
        + "twelve|fifteen|twenty|thirty|forty-five|forty|fifty|sixty|ninety)\\s+|(?<half>half\\s+an?)\\s+)"
        + "(?<unit>minutes?|mins?|m|hours?|hrs?|h|days?|weeks?)(?<plushalf>\\s+and\\s+a\\s+half)?"
    /// "in 30 minutes", "after 2 hours"; "30 minutes from now", "2 hours later".
    private static let englishDurations = [
        "\\b(?:in|after)\\s+" + englishAmount + "\\b",
        "\\b" + englishAmount + "\\s+(?:from\\s+now|later)\\b",
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    private static let englishNumbers: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
        "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    /// The durations in `text`, in order. Half a unit only for minutes and hours ("半小时后", "in half an hour").
    static func durations(in text: String) -> [Duration] {
        let whole = NSRange(text.startIndex..., in: text)
        return ([(chineseDuration, false)] + englishDurations.map { ($0, true) }).flatMap { regex, english in
            regex.matches(in: text, range: whole).compactMap { match -> Duration? in
                func group(_ name: String) -> String? {
                    // The Chinese pattern has no "w" group (asking for one it lacks raises an exception).
                    guard english || name != "w" else { return nil }
                    return Range(match.range(withName: name), in: text).map { String(text[$0]).lowercased() }
                }
                guard let range = Range(match.range, in: text), let unitWord = group("unit") else { return nil }
                let unit: Duration.Unit
                switch unitWord {
                case "分钟", "minute", "minutes", "min", "mins", "m": unit = .minute
                case "小时", "钟头", "hour", "hours", "hr", "hrs", "h": unit = .hour
                case "天", "日", "day", "days": unit = .day
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

    /// 一 … 九十九 ("两" for 2, 零五 for 5): what people write for small numbers.
    static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                        "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(text)
        guard let ten = chars.firstIndex(of: "十") else {
            if chars.count == 2, chars[0] == "零" || chars[0] == "〇" { return digits[chars[1]] }  // 3点零五
            return chars.count == 1 ? digits[chars[0]] : nil
        }
        let before = chars[..<ten], after = chars[(ten + 1)...]
        guard before.count <= 1, after.count <= 1 else { return nil }
        let tens = before.first.map { digits[$0] } ?? 1, ones = after.first.map { digits[$0] } ?? 0
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    }

    /// A number as written: 12 or 十二.
    private static func number(_ text: String) -> Int? { Int(text) ?? chineseNumber(text) }

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

    /// The text without the date phrase at `range` (and a word that only led into it: "at", "on", a 「在」 /
    /// 「于」 of its own, or what only went with it: 「之前」 / 「以前」 / 「前」, a 「的」), trimmed of spaces and
    /// punctuation, without a leading 「提醒我（一下）」 / 「提醒一下」 / 「记得」 / "remind me to".
    static func title(_ text: String, without range: Range<String.Index>?) -> String {
        var result = text
        if let range {
            var before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let dangling = before.range(of: "(^|\\s)(at|on|by|around)$", options: [.regularExpression, .caseInsensitive]) {
                before.removeSubrange(dangling)
            } else if let last = before.last, last == "在" || last == "于", standsAlone(before.dropLast()) {
                // Not the end of a word (现在, 正在, 关于, 对于, 由于).
                before.removeLast()
            }
            // By when ("周五前交报告", "明天下午3点之前"), or a 「的」 that tied the date to the rest (「…的会议」).
            if let lead = ["之前", "以前", "的"].first(where: after.hasPrefix) {
                after.removeFirst(lead.count)
            } else if after.hasPrefix("前"), !(after.dropFirst().first.map(wordsWithQian.contains) ?? false) {
                after.removeFirst()
            }
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
        // What only asked for the reminder.
        while true {
            if let lead = ["提醒我一下", "提醒一下", "提醒我", "记得"].first(where: result.hasPrefix) {
                result = trimmed(String(result.dropFirst(lead.count)))
            } else if let lead = result.range(of: "^remind me(\\s+to)?\\b", options: [.regularExpression, .caseInsensitive]) {
                result.removeSubrange(lead)
                result = trimmed(result)
            } else {
                return result
            }
        }
    }

    /// Whether a 「在」 / 「于」 after `prefix` is a word of its own: at the start, after a space or punctuation,
    /// or after 我 ("提醒我在明天…").
    private static func standsAlone(_ prefix: Substring) -> Bool {
        guard let last = prefix.last else { return true }
        return last.isWhitespace || last.isPunctuation || last == "我"
    }

    /// 「前」 starting a word of its own after the date: 前台, 前面, 前往 … (not "by then").
    private static let wordsWithQian: Set<Character> = Set("台面往门排任端提方辈进线后夕景途锋妻夫天年者身额沿卫列")

    private static let trimmedCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。、；：！？,.;:!?…·~～-—–"))

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: trimmedCharacters) }

    private static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
}
