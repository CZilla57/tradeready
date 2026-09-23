import Foundation

// Focused oracle/failure tests for NativeCalendar (task 8.01, S2):
// timed/untimed rows, axis/lane layout, overlap clusters, terminal history,
// per-selector archive behavior, week selectors, and the immutable
// schedule edit-draft input boundary.

private var failures = 0

private func expect(_ actual: @autoclosure () -> Bool, _ label: String) {
    if actual() { return }
    failures += 1
    print("FAIL: \(label)")
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    let value = actual()
    if value != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
    }
}

struct TJob: ScheduleJobLike {
    var scheduleJobId: String
    var scheduledDate: String?
    var scheduledStartTime: String?
    var scheduledEndTime: String?
    var scheduleLaborHours: Double
    var status: String
    var createdAt: String
    var archivedAt: String?
}

private func job(_ id: String, date: String?, start: String?, end: String? = nil,
                 labor: Double = 1, status: String = "scheduled",
                 created: String = "2026-08-01", archived: String? = nil) -> TJob {
    TJob(scheduleJobId: id, scheduledDate: date, scheduledStartTime: start,
         scheduledEndTime: end, scheduleLaborHours: labor, status: status,
         createdAt: created, archivedAt: archived)
}

private let schedule = NativeSchedule.ResolvedSchedule.defaults

// MARK: - Timed / untimed rows

do {
    let jobs = [
        job("timed", date: "2026-08-10", start: "09:00", end: "10:00"),
        job("untimed-empty", date: "2026-08-10", start: ""),
        job("untimed-nil", date: "2026-08-10", start: nil),
        job("other-day", date: "2026-08-11", start: "09:00", end: "10:00"),
    ]
    let day: NativeCalendar.CalendarDay<TJob> = NativeCalendar.buildCalendarDay(jobs: jobs, date: "2026-08-10", schedule: schedule)
    expectEqual(day.timed.map { $0.job.scheduleJobId }, ["timed"], "only jobs with a start time render as blocks")
    expectEqual(day.untimed.map(\.scheduleJobId).sorted(), ["untimed-empty", "untimed-nil"],
                "empty and nil starts are untimed rows, not midnight appointments")
    expectEqual(day.timed.first?.startMinutes, 540, "block start in minutes since midnight")
    expectEqual(day.timed.first?.endMinutes, 600, "block end in minutes since midnight")
}

// MARK: - Terminal history renders but never conflicts

do {
    let jobs = [
        job("done", date: "2026-08-10", start: "09:00", end: "10:00", status: "complete"),
        job("live", date: "2026-08-10", start: "09:30", end: "10:30"),
    ]
    let day: NativeCalendar.CalendarDay<TJob> = NativeCalendar.buildCalendarDay(jobs: jobs, date: "2026-08-10", schedule: schedule)
    expectEqual(day.timed.count, 2, "terminal history still renders on the day")
    let done = day.timed.first { $0.job.scheduleJobId == "done" }!
    let live = day.timed.first { $0.job.scheduleJobId == "live" }!
    expect(done.isTerminal && !done.inConflict, "terminal block flagged terminal, never in conflict")
    expect(!live.isTerminal && !live.inConflict, "live-vs-terminal overlap is not a conflict")
}

// MARK: - Lanes and overlap clusters

do {
    // A 09:00-10:00, B 09:30-10:30 overlap (lanes 0,1 count 2); C 10:30-11:00
    // touches B's end so it stands alone.
    let jobs = [
        job("a", date: "2026-08-10", start: "09:00", end: "10:00"),
        job("b", date: "2026-08-10", start: "09:30", end: "10:30"),
        job("c", date: "2026-08-10", start: "10:30", end: "11:00"),
    ]
    let day: NativeCalendar.CalendarDay<TJob> = NativeCalendar.buildCalendarDay(jobs: jobs, date: "2026-08-10", schedule: schedule)
    let lanes = Dictionary(uniqueKeysWithValues: day.timed.map { ($0.job.scheduleJobId, ($0.lane, $0.laneCount)) })
    expectEqual(lanes["a"]?.0, 0, "first block takes lane 0")
    expectEqual(lanes["b"]?.0, 1, "overlapping block takes lane 1")
    expectEqual(lanes["a"]?.1, 2, "cluster of two shares laneCount 2")
    expectEqual(lanes["b"]?.1, 2, "cluster of two shares laneCount 2")
    expectEqual(lanes["c"]?.0, 0, "endpoint-touching block reuses lane 0")
    expectEqual(lanes["c"]?.1, 1, "endpoint-touching block stands alone")
    expect(day.timed.allSatisfy { $0.inConflict || $0.job.scheduleJobId == "c" },
           "live-vs-live overlap flags both sides")
}

do {
    // Chain A 09-11, B 10-12, C 11-13: every start lands before the cluster
    // max end, so all three share laneCount 2 even though A and C touch.
    let jobs = [
        job("a", date: "2026-08-10", start: "09:00", end: "11:00"),
        job("b", date: "2026-08-10", start: "10:00", end: "12:00"),
        job("c", date: "2026-08-10", start: "11:00", end: "13:00"),
    ]
    let day: NativeCalendar.CalendarDay<TJob> = NativeCalendar.buildCalendarDay(jobs: jobs, date: "2026-08-10", schedule: schedule)
    expect(day.timed.allSatisfy { $0.laneCount == 2 }, "chained cluster shares laneCount 2")
    let lanes = Dictionary(uniqueKeysWithValues: day.timed.map { ($0.job.scheduleJobId, $0.lane) })
    expectEqual(lanes["c"], 0, "freed lane is reused inside the cluster")
}

// MARK: - Buffer-aware conflict flags on the day view

do {
    var buffered = NativeSchedule.ResolvedSchedule.defaults
    buffered.bufferMinutes = 30
    let jobs = [
        job("a", date: "2026-08-10", start: "09:00", end: "10:00"),
        job("b", date: "2026-08-10", start: "10:30", end: "11:30"),
    ]
    let day: NativeCalendar.CalendarDay<TJob> = NativeCalendar.buildCalendarDay(jobs: jobs, date: "2026-08-10", schedule: buffered)
    expect(day.timed.allSatisfy { !$0.inConflict }, "exact-buffer separation shows no warning")
    let tight = [job("a", date: "2026-08-10", start: "09:00", end: "10:00"),
                 job("b", date: "2026-08-10", start: "10:15", end: "11:00")]
    let tightDay: NativeCalendar.CalendarDay<TJob> = NativeCalendar.buildCalendarDay(jobs: tight, date: "2026-08-10", schedule: buffered)
    expect(tightDay.timed.allSatisfy(\.inConflict), "sub-buffer separation warns on both blocks")
}

// MARK: - Axis layout

do {
    let empty = NativeCalendar.buildCalendarDay(jobs: [TJob](), date: "2026-08-10", schedule: schedule)
    expectEqual(NativeCalendar.dayAxis(day: empty, schedule: schedule)?.0, 480, "empty day axis starts at work open")
    expectEqual(NativeCalendar.dayAxis(day: empty, schedule: schedule)?.1, 1020, "empty day axis ends at work close")
    let early = NativeCalendar.buildCalendarDay(
        jobs: [job("e", date: "2026-08-10", start: "06:20", end: "07:10"),
               job("late", date: "2026-08-10", start: "18:00", end: "19:30")],
        date: "2026-08-10", schedule: schedule)
    let axis = NativeCalendar.dayAxis(day: early, schedule: schedule)!
    expectEqual(axis.0, 360, "axis stretches down to the hour of out-of-hours work")
    expectEqual(axis.1, 1200, "axis stretches up past close for late work")
    let midnight = NativeCalendar.buildCalendarDay(
        jobs: [job("m", date: "2026-08-10", start: "23:30", end: nil, labor: 2)],
        date: "2026-08-10", schedule: schedule)
    expectEqual(NativeCalendar.dayAxis(day: midnight, schedule: schedule)?.1, 1440,
                "axis never passes midnight")
}

// MARK: - Week view and queue (per-selector archive behavior)

do {
    let jobs = [
        job("mon", date: "2026-08-10", start: "09:00", end: "10:00"),
        job("wed-untimed", date: "2026-08-12", start: nil),
    ]
    let week: [NativeCalendar.CalendarDay<TJob>] = NativeCalendar.buildCalendarWeek(
        jobs: jobs, anchorDate: "2026-08-12", schedule: schedule)!
    expectEqual(week.count, 7, "week always has seven days")
    expectEqual(week.first?.date, "2026-08-10", "week opens Monday")
    expectEqual(week.last?.date, "2026-08-16", "week closes Sunday")
    expectEqual(week[0].timed.map { $0.job.scheduleJobId }, ["mon"], "Monday block lands on Monday")
    expectEqual(week[2].untimed.map(\.scheduleJobId), ["wed-untimed"], "Wednesday untimed lands on Wednesday")
}

do {
    let jobs = [
        job("old", date: nil, start: nil, status: "approved", created: "2026-07-01"),
        job("new", date: nil, start: nil, status: "approved", created: "2026-08-01"),
        job("scheduled", date: "2026-08-10", start: nil, status: "approved", created: "2026-06-01"),
        job("lead", date: nil, start: nil, status: "lead", created: "2026-05-01"),
        job("archived", date: nil, start: nil, status: "approved", created: "2026-04-01", archived: "2026-08-01"),
    ]
    expectEqual(NativeCalendar.selectUnscheduledApproved(jobs: jobs).map(\.scheduleJobId),
                ["old", "new"], "queue is approved, dateless, unarchived, oldest first")
    // …while the day view keeps rendering terminal/archived history: no
    // blanket archive filter where the RN selector has none.
    let history = NativeCalendar.buildCalendarDay(
        jobs: [job("arch", date: "2026-08-10", start: "09:00", end: "10:00",
                   status: "complete", archived: "2026-08-02")],
        date: "2026-08-10", schedule: schedule)
    expectEqual(history.timed.count, 1, "day view renders archived terminal history")
}

// MARK: - Immutable edit-draft input

do {
    let draft = NativeCalendar.ScheduleEditDraft(
        jobId: "j1", baselineDate: "2026-08-10", baselineStart: "09:00",
        baselineEnd: "10:00", baselineStatus: "scheduled",
        date: "2026-08-11", start: "09:00", end: "10:00")
    expect(NativeCalendar.validateScheduleDraft(draft).isEmpty, "retimed draft validates")
    expectEqual(NativeCalendar.changedScheduleFields(draft), [.date], "date-only move marks date only")

    let untimed = NativeCalendar.ScheduleEditDraft(jobId: "j1", date: "2026-08-11", start: nil, end: nil)
    expect(NativeCalendar.validateScheduleDraft(untimed).isEmpty, "untimed dated draft is valid, not midnight")

    let cleared = NativeCalendar.ScheduleEditDraft(jobId: "j1", date: nil, start: nil, end: nil)
    expect(NativeCalendar.validateScheduleDraft(cleared).isEmpty, "clearing date/time is valid")
    expectEqual(NativeCalendar.changedScheduleFields(
        NativeCalendar.ScheduleEditDraft(jobId: "j1", baselineDate: "2026-08-10", date: nil)),
        [.date], "clearing the date marks a date change")

    expectEqual(NativeCalendar.validateScheduleDraft(
        NativeCalendar.ScheduleEditDraft(jobId: "j1", date: nil, start: "09:00")),
        [.timeWithoutDate], "time without a date is rejected")
    expectEqual(NativeCalendar.validateScheduleDraft(
        NativeCalendar.ScheduleEditDraft(jobId: "j1", date: "2026-08-11", end: "10:00")),
        [.endWithoutStart], "end without a start is rejected")
    expectEqual(NativeCalendar.validateScheduleDraft(
        NativeCalendar.ScheduleEditDraft(jobId: "j1", date: "2026-08-11", start: "10:00", end: "10:00")),
        [.endNotAfterStart], "zero-length window is rejected")
    expectEqual(NativeCalendar.validateScheduleDraft(
        NativeCalendar.ScheduleEditDraft(jobId: "j1", date: "2026-02-30", start: "09:00")),
        [.invalidDate("2026-02-30")], "impossible date is rejected")
    expectEqual(NativeCalendar.validateScheduleDraft(
        NativeCalendar.ScheduleEditDraft(jobId: "j1", date: "2026-08-11", start: "25:00")),
        [.invalidTime("25:00")], "out-of-range time is rejected")

    // Value semantics: editing a copy leaves the original draft untouched.
    var copy = draft
    copy.start = "14:00"
    expectEqual(draft.start, "09:00", "drafts are immutable values — edits copy")
    expectEqual(copy.start, "14:00", "edited copy carries the new value")
}

if failures == 0 {
    print("PASS: native calendar tests")
} else {
    print("FAILED: \(failures) native calendar test(s)")
    exit(1)
}
