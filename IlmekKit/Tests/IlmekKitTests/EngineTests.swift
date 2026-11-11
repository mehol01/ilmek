import Foundation
import Testing
@testable import IlmekKit

func cal(_ tz: String = "Europe/Istanbul", firstWeekday: Int = 2) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    c.firstWeekday = firstWeekday
    return c
}

func d(_ y: Int, _ m: Int, _ day: Int) -> DayKey { DayKey(year: y, month: m, day: day) }

/// Counts of 1 on each listed day.
func logs(_ days: [DayKey], times: Int = 1) -> [DayKey: Int] {
    Dictionary(days.map { ($0, times) }, uniquingKeysWith: +)
}

@Suite("DayKey")
struct DayKeyTests {
    @Test func rawValueRoundTrip() {
        let k = d(2026, 11, 5)
        #expect(k.rawValue == 20261105)
        #expect(DayKey(rawValue: 20261105) == k)
        #expect(DayKey(rawValue: 20260230) == nil)
    }

    @Test func arithmeticAcrossYearAndLeapDay() {
        #expect(d(2026, 12, 31).adding(days: 1) == d(2027, 1, 1))
        #expect(d(2028, 2, 28).adding(days: 1) == d(2028, 2, 29))
        #expect(d(2027, 2, 28).adding(days: 1) == d(2027, 3, 1))
        #expect(d(2026, 1, 1).days(to: d(2027, 1, 1)) == 365)
        #expect(d(2028, 1, 1).days(to: d(2029, 1, 1)) == 366)
    }

    @Test func weekdayMatchesFoundation() {
        let c = cal()
        var k = d(2026, 1, 1)
        for _ in 0..<400 {
            let fw = c.component(.weekday, from: k.startDate(in: c))
            #expect(k.weekday == fw)
            k = k.adding(days: 1)
        }
    }

    @Test func dstDaysStillOneDayApart() {
        // US DST start/end: 23h and 25h days.
        let ny = cal("America/New_York")
        let march8 = d(2026, 3, 8), nov1 = d(2026, 11, 1)
        #expect(DayKey(march8.startDate(in: ny), calendar: ny) == march8)
        #expect(DayKey(nov1.startDate(in: ny).addingTimeInterval(24.5 * 3600), calendar: ny) == nov1)
        #expect(march8.adding(days: 1) == d(2026, 3, 9))
    }

    @Test func dateInitUsesCalendarTimeZone() {
        // 2026-11-05 22:30 UTC is already the 6th in Istanbul (UTC+3).
        let date = ISO8601DateFormatter().date(from: "2026-11-05T22:30:00Z")!
        #expect(DayKey(date, calendar: cal("UTC")) == d(2026, 11, 5))
        #expect(DayKey(date, calendar: cal("Europe/Istanbul")) == d(2026, 11, 6))
    }

    @Test func startOfWeekMondayAndSunday() {
        let thu = d(2026, 11, 5)
        #expect(thu.startOfWeek(firstWeekday: 2) == d(2026, 11, 2))
        #expect(thu.startOfWeek(firstWeekday: 1) == d(2026, 11, 1))
        #expect(d(2026, 11, 2).startOfWeek(firstWeekday: 2) == d(2026, 11, 2))
    }
}

@Suite("Schedule")
struct ScheduleTests {
    let start = d(2026, 11, 2) // Monday

    @Test func weekdays() {
        let s = Schedule(pattern: .weekdays([2, 4, 6])) // Mon, Wed, Fri
        #expect(s.isDue(on: d(2026, 11, 2), start: start))
        #expect(!s.isDue(on: d(2026, 11, 3), start: start))
        #expect(s.isDue(on: d(2026, 11, 4), start: start))
    }

    @Test func notDueBeforeStart() {
        #expect(!Schedule.daily.isDue(on: d(2026, 11, 1), start: start))
    }

    @Test func everyNDays() {
        let s = Schedule(pattern: .everyNDays(3))
        let due = (0..<10).filter { s.isDue(on: start.adding(days: $0), start: start) }
        #expect(due == [0, 3, 6, 9])
    }

    @Test func dayOfMonthClampsToLastDay() {
        let s = Schedule(pattern: .daysOfMonth([31]))
        #expect(s.isDue(on: d(2027, 2, 28), start: start))
        #expect(s.isDue(on: d(2028, 2, 29), start: start))
        #expect(!s.isDue(on: d(2028, 2, 28), start: start))
        #expect(s.isDue(on: d(2026, 11, 30), start: start))
    }

    @Test func intervalSlots() {
        let r = ReminderRule.interval(minutes: 360, start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 22))
        #expect(r.slots == [TimeOfDay(hour: 8), TimeOfDay(hour: 14), TimeOfDay(hour: 20)])
        #expect(ReminderRule.times([TimeOfDay(hour: 9), TimeOfDay(hour: 9), TimeOfDay(hour: 7)]).slots
                == [TimeOfDay(hour: 7), TimeOfDay(hour: 9)])
    }

    @Test func codableRoundTrip() throws {
        let s = Schedule(pattern: .weekdays([1, 7]), timesPerDay: 3)
        let back = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite("Streaks")
struct StreakTests {
    let start = d(2026, 11, 1)

    @Test func dailyStreakCountsConsecutiveDays() {
        let days = (0..<5).map { start.adding(days: $0) }
        let h = HabitHistory(startDay: start, counts: logs(days))
        let r = StreakEngine.evaluate(h, today: start.adding(days: 4))
        #expect(r.current == 5)
        #expect(r.best == 5)
        #expect(r.isCurrentUnitDone)
    }

    @Test func todayNotDoneYetDoesNotBreak() {
        let days = (0..<5).map { start.adding(days: $0) }
        let h = HabitHistory(startDay: start, counts: logs(days))
        let r = StreakEngine.evaluate(h, today: start.adding(days: 5))
        #expect(r.current == 5)
        #expect(!r.isCurrentUnitDone)
    }

    @Test func missedDayResets() {
        let days = [0, 1, 2, 4, 5].map { start.adding(days: $0) }
        let h = HabitHistory(startDay: start, counts: logs(days))
        let r = StreakEngine.evaluate(h, today: start.adding(days: 5))
        #expect(r.current == 2)
        #expect(r.best == 3)
    }

    @Test func skipIsNeutral() {
        let days = [0, 1, 3, 4].map { start.adding(days: $0) }
        let h = HabitHistory(startDay: start, counts: logs(days), skipped: [start.adding(days: 2)])
        #expect(StreakEngine.evaluate(h, today: start.adding(days: 4)).current == 4)
    }

    @Test func multiplePerDayNeedsFullTarget() {
        let s = Schedule(timesPerDay: 3)
        var counts = logs([start, start.adding(days: 1)], times: 3)
        counts[start.adding(days: 2)] = 2 // only 2 of 3
        let h = HabitHistory(schedule: s, startDay: start, counts: counts)
        let r = StreakEngine.evaluate(h, today: start.adding(days: 3))
        #expect(r.current == 0)
        #expect(r.best == 2)
    }

    @Test func weekdayHabitIgnoresOffDays() {
        // Mon/Wed/Fri, done every due day for two weeks.
        let s = Schedule(pattern: .weekdays([2, 4, 6]))
        let mon = d(2026, 11, 2)
        let due = [0, 2, 4, 7, 9, 11].map { mon.adding(days: $0) }
        let h = HabitHistory(schedule: s, startDay: mon, counts: logs(due))
        // Sunday after: no missed days.
        #expect(StreakEngine.evaluate(h, today: mon.adding(days: 13)).current == 6)
    }

    @Test func weeklyTarget() {
        // 3x per week, weeks starting Monday. Start on Wednesday (partial week).
        let s = Schedule(pattern: .timesPerWeek(3))
        let wed = d(2026, 11, 4)
        // Partial first week: only 1 → neutral. Next two weeks: 3 each.
        let days = [wed, d(2026, 11, 9), d(2026, 11, 10), d(2026, 11, 14),
                    d(2026, 11, 16), d(2026, 11, 18), d(2026, 11, 22)]
        let h = HabitHistory(schedule: s, startDay: wed, counts: logs(days))
        let r = StreakEngine.evaluate(h, today: d(2026, 11, 24))
        #expect(r.unit == .week)
        #expect(r.current == 2)
        #expect(r.progress == 0)
        #expect(r.target == 3)
    }

    @Test func weeklyMissedWeekResets() {
        let s = Schedule(pattern: .timesPerWeek(1))
        let mon = d(2026, 11, 2)
        let h = HabitHistory(schedule: s, startDay: mon, counts: logs([mon, d(2026, 11, 16)]))
        let r = StreakEngine.evaluate(h, today: d(2026, 11, 17))
        #expect(r.current == 1)
        #expect(r.best == 1)
    }

    @Test func monthlyTarget() {
        let s = Schedule(pattern: .timesPerMonth(2))
        let h = HabitHistory(schedule: s, startDay: d(2026, 9, 1),
                             counts: logs([d(2026, 9, 3), d(2026, 9, 20), d(2026, 10, 1), d(2026, 10, 31), d(2026, 11, 2)]))
        let r = StreakEngine.evaluate(h, today: d(2026, 11, 5))
        #expect(r.current == 2)
        #expect(r.progress == 1)
    }

    @Test func longHistoryIsFast() {
        let start = d(2020, 1, 1)
        let days = (0..<2500).map { start.adding(days: $0) }
        let h = HabitHistory(startDay: start, counts: logs(days))
        let clock = ContinuousClock()
        let t = clock.measure { _ = StreakEngine.evaluate(h, today: start.adding(days: 2499)) }
        #expect(StreakEngine.evaluate(h, today: start.adding(days: 2499)).current == 2500)
        #expect(t < .milliseconds(50))
    }

    @Test func summaryCountsDueHabits() {
        let today = d(2026, 11, 5) // Thursday
        let a = HabitHistory(startDay: start, counts: logs([today]))
        let b = HabitHistory(startDay: start)
        let offDay = HabitHistory(schedule: Schedule(pattern: .weekdays([2])), startDay: start)
        let s = StreakEngine.summary([a, b, offDay], on: today)
        #expect(s == DaySummary(done: 1, due: 2))
    }

    // 2026-11-02 is a Monday; weeks start on Monday (firstWeekday 2).
    @Test func openWeeklyHabitDoesNotSpoilRecordedDays() {
        let mon = d(2026, 11, 2)
        let run = HabitHistory(schedule: Schedule(pattern: .timesPerWeek(3)), startDay: d(2026, 10, 26),
                               counts: logs([d(2026, 11, 3), d(2026, 11, 5), d(2026, 11, 7)]))
        let daily = HabitHistory(startDay: d(2026, 10, 26),
                                 counts: logs((0..<7).map { mon.adding(days: $0) }))
        // Today's list still shows the open weekly habit as due…
        #expect(StreakEngine.summary([run, daily], on: mon) == DaySummary(done: 1, due: 2))
        // …but Monday on the record is a full day: the run wasn't owed yet.
        #expect(StreakEngine.summary([run, daily], on: mon, forRecord: true) == DaySummary(done: 1, due: 1))
        // A day with a run counts it as done, even before the weekly target is reached.
        #expect(StreakEngine.summary([run, daily], on: d(2026, 11, 3), forRecord: true) == DaySummary(done: 2, due: 2))
        // The whole week is perfect.
        let timelines = [HabitTimeline(current: run), HabitTimeline(current: daily)]
        #expect(StreakEngine.perfectDayStreak(timelines, today: d(2026, 11, 8)) == 7)
    }

    @Test func weeklyHabitShortAtWeekEndBreaksTheRecord() {
        let run = HabitHistory(schedule: Schedule(pattern: .timesPerWeek(3)), startDay: d(2026, 10, 26),
                               counts: logs([d(2026, 11, 3), d(2026, 11, 5)]))
        let sun = d(2026, 11, 8)
        #expect(StreakEngine.summary([run], on: sun, forRecord: true) == DaySummary(done: 0, due: 1))
        #expect(StreakEngine.summary([run], on: d(2026, 11, 6), forRecord: true) == DaySummary(done: 0, due: 0))
    }
}

@Suite("Reminders")
struct ReminderTests {
    let c = cal()

    func at(_ day: DayKey, _ h: Int, _ m: Int = 0) -> Date {
        c.date(bySettingHour: h, minute: m, second: 0, of: day.startDate(in: c))!
    }

    @Test func skipsPastAndCompletedSlots() {
        let today = d(2026, 11, 5)
        let rule = ReminderRule.times([TimeOfDay(hour: 8), TimeOfDay(hour: 14), TimeOfDay(hour: 20)])
        let h = HabitHistory(schedule: Schedule(timesPerDay: 3), startDay: today, counts: [today: 1])
        let plan = ReminderPlanner.plan([.init(id: "med", history: h, rule: rule)],
                                        now: at(today, 9), calendar: c, horizonDays: 2)
        // Today: 08 is past; 14:00 is slot 1 (not yet done) → kept. 20 kept. Tomorrow: all 3.
        #expect(plan.map(\.slot) == [1, 2, 0, 1, 2])
        #expect(plan.first?.fireDate == at(today, 14))
    }

    @Test func doneTodayMeansNoMoreToday() {
        let today = d(2026, 11, 5)
        let h = HabitHistory(startDay: today, counts: [today: 1])
        let plan = ReminderPlanner.plan([.init(id: "x", history: h, rule: .times([TimeOfDay(hour: 21)]))],
                                        now: at(today, 9), calendar: c, horizonDays: 2)
        #expect(plan.map(\.day) == [today.adding(days: 1)])
    }

    @Test func respectsSystemLimit() {
        let today = d(2026, 11, 5)
        let hourly = ReminderRule.interval(minutes: 60, start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23))
        let h = HabitHistory(schedule: Schedule(timesPerDay: 24), startDay: today)
        let plan = ReminderPlanner.plan([.init(id: "h", history: h, rule: hourly)],
                                        now: at(today, 0, 30), calendar: c, limit: 500)
        #expect(plan.count == ReminderPlanner.systemLimit)
        #expect(plan == plan.sorted { $0.fireDate < $1.fireDate })
    }

    @Test func nearestRemindersWinAcrossHabits() {
        let today = d(2026, 11, 5)
        let hourly = ReminderRule.interval(minutes: 60, start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23))
        let flood = HabitHistory(schedule: Schedule(timesPerDay: 24), startDay: today)
        let morning = HabitHistory(startDay: today)
        let plan = ReminderPlanner.plan([.init(id: "flood", history: flood, rule: hourly),
                                         .init(id: "walk", history: morning, rule: .times([TimeOfDay(hour: 7)]))],
                                        now: at(today, 6), calendar: c)
        #expect(plan.contains { $0.habitID == "walk" && $0.day == today })
    }

    @Test func dstGapMovesToNextValidTime() {
        // New York 2026-03-08: 02:00–03:00 doesn't exist.
        let ny = cal("America/New_York")
        let day = d(2026, 3, 8)
        let fire = ReminderPlanner.date(day, TimeOfDay(hour: 2, minute: 30), ny)
        #expect(fire != nil)
        #expect(DayKey(fire!, calendar: ny) == day)
        #expect(ny.component(.hour, from: fire!) == 3)
    }

    @Test func midnightSlotSameDay() {
        let day = d(2026, 11, 6)
        let fire = ReminderPlanner.date(day, TimeOfDay(hour: 0), c)
        #expect(fire == day.startDate(in: c))
    }

    @Test func weeklyStopsAfterUnitDone() {
        let mon = d(2026, 11, 2)
        let h = HabitHistory(schedule: Schedule(pattern: .timesPerWeek(2)), startDay: mon,
                             counts: logs([mon, d(2026, 11, 3)]))
        let plan = ReminderPlanner.plan([.init(id: "w", history: h, rule: .times([TimeOfDay(hour: 18)]))],
                                        now: at(d(2026, 11, 4), 9), calendar: c, horizonDays: 7)
        // Done for this week (Mon 2 – Sun 8) → next reminder Monday 9th.
        #expect(plan.first?.day == d(2026, 11, 9))
    }
}

@Suite("Knit")
struct KnitTests {
    @Test func colorLocksAfterDay() {
        let today = d(2026, 11, 5)
        #expect(Knit.canEditColor(of: today, today: today))
        #expect(!Knit.canEditColor(of: today.adding(days: -1), today: today))
        #expect(!Knit.canEditColor(of: today.adding(days: 1), today: today))
    }

    @Test func rowsAreWeeks() {
        let rows = Knit.rows(started: d(2026, 11, 4), today: d(2026, 11, 17))
        #expect(rows.count == 3)
        #expect(rows[0].first == d(2026, 11, 2))
        #expect(rows.allSatisfy { $0.count == 7 })
        #expect(Knit.look(of: d(2026, 11, 3), today: d(2026, 11, 17), started: d(2026, 11, 4), fraction: 1) == .empty)
        #expect(Knit.look(of: d(2026, 11, 17), today: d(2026, 11, 17), started: d(2026, 11, 4), fraction: 0.5) == .onNeedle(fraction: 0.5))
    }
}

@Suite("Schedule change")
struct CarryOverTests {
    @Test func carryOverContinuesStreak() {
        // Was daily with a 10-day streak; switched to Mon/Wed/Fri on Thu 2026-11-05.
        let s = Schedule(pattern: .weekdays([2, 4, 6]))
        let h = HabitHistory(schedule: s, startDay: d(2026, 11, 5),
                             counts: logs([d(2026, 11, 6)]), carryOver: 10, carryBest: 14)
        let r = StreakEngine.evaluate(h, today: d(2026, 11, 8))
        #expect(r.current == 11)
        #expect(r.best == 14)
    }

    @Test func missAfterChangeStillResets() {
        let h = HabitHistory(startDay: d(2026, 11, 5), counts: [:], carryOver: 10, carryBest: 10)
        let r = StreakEngine.evaluate(h, today: d(2026, 11, 7))
        #expect(r.current == 0)
        #expect(r.best == 10)
    }

    @Test func fractionBeforeStartShowsLogs() {
        let h = HabitHistory(startDay: d(2026, 11, 5), counts: [d(2026, 11, 1): 1])
        #expect(StreakEngine.fraction(h, on: d(2026, 11, 1)) == 1)
        #expect(StreakEngine.fraction(h, on: d(2026, 11, 2)) == 0)
    }
}

@Suite("Timeline")
struct TimelineTests {
    @Test func pastDaysUseOldSchedule() {
        // Daily until 2026-11-05, then Mondays only.
        let cur = HabitHistory(schedule: Schedule(pattern: .weekdays([2])), startDay: d(2026, 11, 5),
                               counts: logs([d(2026, 11, 3)]))
        let t = HabitTimeline(current: cur, past: [ScheduleSegment(from: d(2026, 11, 1), schedule: .daily)])
        // Tue 3rd judged as daily → due & done; Wed 4th due & missed.
        #expect(StreakEngine.summary([t], on: d(2026, 11, 3)) == DaySummary(done: 1, due: 1))
        #expect(StreakEngine.summary([t], on: d(2026, 11, 4)) == DaySummary(done: 0, due: 1))
        // Thu 6th: Mondays only → not due.
        #expect(StreakEngine.summary([t], on: d(2026, 11, 6)) == DaySummary(done: 0, due: 0))
        #expect(t.history(on: d(2026, 10, 31)) == nil)
    }

    @Test func archivedHabitStopsCounting() {
        let t = HabitTimeline(current: HabitHistory(startDay: d(2026, 11, 1)), endDay: d(2026, 11, 4))
        #expect(StreakEngine.summary([t], on: d(2026, 11, 3)).due == 1)
        #expect(StreakEngine.summary([t], on: d(2026, 11, 4)).due == 0)
    }
}

@Suite("Social")
struct SocialTests {
    @Test func perfectDayStreak() {
        let start = d(2026, 11, 1)
        let a = HabitTimeline(current: HabitHistory(startDay: start,
                                                    counts: logs((0..<5).map { start.adding(days: $0) })))
        let weekdaysOnly = HabitTimeline(current: HabitHistory(
            schedule: Schedule(pattern: .weekdays([2, 3, 4, 5, 6])), startDay: start,
            counts: logs([d(2026, 11, 2), d(2026, 11, 3), d(2026, 11, 4)])))
        // Nov 1 Sun: only a due → done. Nov 2–4 both done. Nov 5 Thu: weekdays habit missed.
        #expect(StreakEngine.perfectDayStreak([a, weekdaysOnly], today: d(2026, 11, 4)) == 4)
        #expect(StreakEngine.perfectDayStreak([a, weekdaysOnly], today: d(2026, 11, 5)) == 4)
        #expect(StreakEngine.perfectDayStreak([a, weekdaysOnly], today: d(2026, 11, 6)) == 0)
    }

    @Test func codes() {
        for _ in 0..<100 {
            let c = GroupCode.random()
            #expect(GroupCode.normalize(c) == c)
            #expect(GroupCode.normalize(GroupCode.display(c).lowercased()) == c)
        }
        #expect(GroupCode.normalize("k7qf 29xm") == "K7QF29XM")
        #expect(GroupCode.normalize("K7QF-29X0") == nil)   // 0 isn't in the alphabet
        #expect(GroupCode.normalize("short") == nil)
    }

    @Test func scarfPayloadRoundTrip() {
        let p = ScarfPayload(start: d(2026, 11, 1), days: [(0, 255), (3, 128), (9, 0)])
        let back = ScarfPayload(data: p.data)
        #expect(back == p)
        #expect(back?.last == d(2026, 11, 3))
        #expect(back?.entry(on: d(2026, 11, 2))?.color == 3)
        #expect(ScarfPayload(data: Data([1, 2, 3])) == nil)
    }
}

@Suite("Stats")
struct StatsTests {
    private func s(_ done: Int, _ due: Int) -> DaySummary { DaySummary(done: done, due: due) }

    @Test func streaksIgnoreRestDaysAndUnfinishedToday() {
        // full, full, miss, full, rest, full, full, today 1/2
        let st = ProgressStats(days: [s(2, 2), s(1, 1), s(0, 2), s(2, 2), s(0, 0), s(2, 2), s(1, 1), s(1, 2)])
        #expect(st.currentStreak == 3)
        #expect(st.bestStreak == 3)
        #expect(st.perfectDays == 5)
    }

    @Test func finishedTodayCounts() {
        let st = ProgressStats(days: [s(1, 1), s(1, 1)])
        #expect(st.currentStreak == 2)
        #expect(st.rate7 == 1)
    }

    @Test func ratesSkipUnfinishedToday() {
        // Yesterday 1/2, today 0/2 (in progress) → 50%, not 25%.
        let st = ProgressStats(days: [s(1, 2), s(0, 2)])
        #expect(st.rate7 == 0.5)
        #expect(ProgressStats(days: [s(0, 2)]).rate7 == nil)
        // Over-logging a day doesn't push the rate above 100%.
        #expect(ProgressStats(days: [s(5, 2), s(0, 0)]).rate30 == 1)
    }

    @Test func rateWindow() {
        let days = Array(repeating: s(0, 1), count: 23) + Array(repeating: s(1, 1), count: 8)
        let st = ProgressStats(days: days)   // last element (today) is done
        #expect(st.rate7 == 1)
        #expect(st.rate30 == 8.0 / 30)
    }

    @Test func habitCells() {
        let start = d(2026, 11, 2)   // Monday
        let t = HabitTimeline(current: HabitHistory(
            schedule: Schedule(pattern: .weekdays([2, 4]), timesPerDay: 2), startDay: start,
            counts: [start: 1, d(2026, 11, 3): 1]))
        #expect(t.cell(on: d(2026, 11, 1), today: d(2026, 11, 5)) == .none)       // before start
        #expect(t.cell(on: start, today: d(2026, 11, 5)) == .value(0.5))
        #expect(t.cell(on: d(2026, 11, 3), today: d(2026, 11, 5)) == .value(1))   // extra day logged
        #expect(t.cell(on: d(2026, 11, 4), today: d(2026, 11, 5)) == .value(0))
        #expect(t.cell(on: d(2026, 11, 5), today: d(2026, 11, 5)) == .rest)
        #expect(t.cell(on: d(2026, 11, 6), today: d(2026, 11, 5)) == .none)       // future
    }
}

@Suite("Performance")
struct PerformanceTests {
    /// 20 habits with two years of history: what the stats tab and scarf compute on every render.
    @Test func twoYearsOfHistory() {
        let today = d(2026, 11, 8)
        let start = today.adding(days: -730)
        var timelines: [HabitTimeline] = []
        for i in 0..<20 {
            var counts: [DayKey: Int] = [:]
            var day = start
            var n = 0
            while day <= today {
                if (n + i) % 5 != 0 { counts[day] = 1 + (i % 3 == 0 ? 2 : 0) }
                day = day.adding(days: 1); n += 1
            }
            let schedule: Schedule = switch i % 4 {
            case 0: Schedule(timesPerDay: 3)
            case 1: Schedule(pattern: .weekdays([2, 3, 4, 5, 6]))
            case 2: Schedule(pattern: .timesPerWeek(3))
            default: .daily
            }
            timelines.append(HabitTimeline(current: HabitHistory(schedule: schedule, startDay: start, counts: counts),
                                           past: i % 2 == 0 ? [] : [ScheduleSegment(from: start, schedule: .daily)]))
        }

        let clock = ContinuousClock()
        var summaries: [DaySummary] = []
        let t1 = clock.measure {
            var day = start
            while day <= today {
                summaries.append(StreakEngine.summary(timelines, on: day))
                day = day.adding(days: 1)
            }
        }
        var stats: ProgressStats?
        let t2 = clock.measure {
            stats = ProgressStats(days: summaries)
            _ = StreakEngine.perfectDayStreak(timelines, today: today)
            for t in timelines {
                _ = StreakEngine.evaluate(t.current, today: today)
                for k in 0..<731 { _ = t.cell(on: start.adding(days: k), today: today) }
            }
        }
        print("PERF summaries(731 days × 20 habits): \(t1), stats+streaks+cells: \(t2)")
        #expect(stats != nil)
        #expect(t1 < .seconds(2))
    }
}

@Suite("Pause")
struct PauseTests {
    @Test func skippedHabitIsNotDueThatDay() {
        let day = d(2026, 11, 9)
        let a = HabitHistory(startDay: day.adding(days: -3), counts: [day: 1])
        let b = HabitHistory(startDay: day.adding(days: -3), skipped: [day])
        #expect(StreakEngine.summary([a, b], on: day) == DaySummary(done: 1, due: 1))
        // Done anyway on a skipped day still counts.
        let c = HabitHistory(startDay: day.adding(days: -3), counts: [day: 1], skipped: [day])
        #expect(StreakEngine.summary([a, c], on: day) == DaySummary(done: 2, due: 2))
    }

    @Test func vacationKeepsPerfectStreak() {
        let start = d(2026, 11, 1)
        let today = d(2026, 11, 10)
        let paused = Set(Pause.days(from: d(2026, 11, 4), through: d(2026, 11, 7)))
        var counts: [DayKey: Int] = [:]
        for k in 0...9 where !paused.contains(start.adding(days: k)) { counts[start.adding(days: k)] = 1 }
        let t = HabitTimeline(current: HabitHistory(startDay: start, counts: counts, skipped: paused))
        #expect(StreakEngine.perfectDayStreak([t], today: today) == 6)
        #expect(StreakEngine.evaluate(t.current, today: today).current == 6)
    }

    @Test func pausedThrough() {
        let today = d(2026, 11, 9)
        let run = Set(Pause.days(from: today, through: d(2026, 11, 12)))
        #expect(Pause.pausedThrough(run, today: today) == d(2026, 11, 12))
        #expect(Pause.pausedThrough([today], today: today) == nil)          // a plain skip
        #expect(Pause.pausedThrough(run, today: d(2026, 11, 13)) == nil)    // over
        #expect(Pause.days(from: today, through: today.adding(days: -1)).isEmpty)
    }
}

@Suite("DayPart")
struct DayPartTests {
    @Test func fromFirstReminder() {
        #expect(DayPart(.none) == .anytime)
        #expect(DayPart(.times([TimeOfDay(hour: 21), TimeOfDay(hour: 8)])) == .morning)   // earliest wins
        #expect(DayPart(.times([TimeOfDay(hour: 12)])) == .afternoon)
        #expect(DayPart(.times([TimeOfDay(hour: 16, minute: 59)])) == .afternoon)
        #expect(DayPart(.times([TimeOfDay(hour: 17)])) == .evening)
        #expect(DayPart(.times([TimeOfDay(hour: 1)])) == .evening)
        #expect(DayPart(.interval(minutes: 480, start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 22))) == .morning)
    }

    @Test func lateNightSortsLast() {
        #expect(DayPart.sortKey(.times([TimeOfDay(hour: 1)])) > DayPart.sortKey(.times([TimeOfDay(hour: 23)])))
        #expect(DayPart.sortKey(.none) == .max)
    }
}

@Suite("PeriodStats")
struct PeriodStatsTests {
    private func s(_ done: Int, _ due: Int) -> DaySummary { DaySummary(done: done, due: due) }

    @Test func weekWithPrevious() {
        let today = d(2026, 11, 14)            // Saturday
        let start = today.adding(days: -13)
        // Previous week: half done. This week: all done, today in progress.
        let days = Array(repeating: s(1, 2), count: 7) + Array(repeating: s(2, 2), count: 6) + [s(0, 2)]
        let r = PeriodReport(summaries: days, start: start, today: today, period: .week)
        #expect(r.range == today.adding(days: -6)...today)
        #expect(r.rate == 1)                    // unfinished today left out
        #expect(r.previousRate == 0.5)
        #expect(r.perfectDays == 6)
        #expect(r.completed == 12)
        #expect(r.trend.count == 7)
        #expect(r.trend.last?.rate == nil)       // today, still open
    }

    @Test func weekdayRates() {
        let start = d(2026, 11, 2)              // Monday
        // Mondays done, everything else missed, over two weeks.
        let days = (0..<14).map { start.adding(days: $0).weekday == 2 ? s(1, 1) : s(0, 1) }
        let r = PeriodReport(summaries: days, start: start, today: start.adding(days: 13), period: .month)
        #expect(r.weekdayRates[2] == 1)
        #expect(r.weekdayRates[3] == 0)
        #expect(r.previousRate == nil)           // no history before
    }

    @Test func allTimeUsesMonthsWhenLong() {
        let start = d(2026, 1, 15)
        let today = d(2026, 11, 14)
        let days = Array(repeating: s(1, 1), count: start.days(to: today) + 1)
        let r = PeriodReport(summaries: days, start: start, today: today, period: .all)
        #expect(r.trend.count == 11)            // Jan…Nov
        #expect(r.trend.first?.start == start)  // clipped to the first day
        #expect(r.rate == 1)
    }

    @Test func restDaysAreIgnored() {
        let today = d(2026, 11, 14)
        let r = PeriodReport(summaries: [s(0, 0), s(1, 1)], start: today.adding(days: -1), today: today, period: .week)
        #expect(r.activeDays == 1)
        #expect(r.rate == 1)
    }

    @Test func hours() {
        let h = CheckInHours.histogram([7, 8, 8, 9, 21, 25, -1])
        #expect(h[8] == 2 && h.reduce(0, +) == 5)
        #expect(CheckInHours.peak(h) == .morning)
        #expect(CheckInHours.peak(CheckInHours.histogram([7])) == nil)
    }
}

@Suite("Calendars")
struct NonGregorianCalendarTests {
    private func calendar(_ id: Calendar.Identifier) -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }

    /// A phone set to another calendar must still log the same Gregorian day.
    @Test(arguments: [Calendar.Identifier.buddhist, .islamicUmmAlQura, .hebrew, .persian, .japanese])
    func dayKeyIsAlwaysGregorian(id: Calendar.Identifier) {
        let greg = calendar(.gregorian)
        let date = greg.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15))!
        let key = DayKey(date, calendar: calendar(id))
        #expect(key == d(2026, 11, 10))
        #expect(DayKey(rawValue: key.rawValue) == key)
        #expect(key.weekday == greg.component(.weekday, from: date))
        // And back: the day's start is the same instant in either calendar.
        #expect(key.startDate(in: calendar(id)) == greg.startOfDay(for: date))
    }

    @Test func remindersOnABuddhistPhone() {
        let cal = calendar(.buddhist)
        let now = calendar(.gregorian).date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 8))!
        let h = HabitHistory(startDay: d(2026, 11, 1))
        let plan = ReminderPlanner.plan([.init(id: "a", history: h, rule: .times([TimeOfDay(hour: 9)]))],
                                        now: now, calendar: cal, horizonDays: 2)
        #expect(plan.map(\.day) == [d(2026, 11, 10), d(2026, 11, 11)])
    }
}

@Suite("Untrusted scarf data")
struct ScarfPayloadHardeningTests {
    private func raw(start: UInt32, days: Int) -> Data {
        var d = Data([UInt8(start >> 24), UInt8((start >> 16) & 0xFF), UInt8((start >> 8) & 0xFF), UInt8(start & 0xFF)])
        d.append(contentsOf: Array(repeating: UInt8(1), count: days * 2))
        return d
    }

    @Test func acceptsWhatTheAppSends() {
        #expect(ScarfPayload(data: raw(start: 2026_11_01, days: 1096))?.days.count == 1096)
    }

    @Test func rejectsAbsurdPayloads() {
        #expect(ScarfPayload(data: raw(start: 2026_11_01, days: 200_000)) == nil)   // far too long
        #expect(ScarfPayload(data: raw(start: 0001_01_01, days: 10)) == nil)        // year 1
        #expect(ScarfPayload(data: raw(start: 9999_12_31, days: 10)) == nil)        // year 9999
        #expect(ScarfPayload(data: raw(start: 0xFFFF_FFFF, days: 10)) == nil)       // not a date at all
        #expect(ScarfPayload(data: raw(start: 2026_13_40, days: 10)) == nil)        // month 13
    }
}
