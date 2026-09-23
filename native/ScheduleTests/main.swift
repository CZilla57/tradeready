import Foundation

// Focused oracle/failure tests for NativeSchedule (task 8.01, S1/S2 slices).
// Vectors mirror utils/scheduleConfig, scheduleSmarts and dateHelpers oracles:
// default/null/zero/minute/ISO-day, endpoint-touch, buffer, terminal,
// midnight, blackout, horizon/lead, overlap-cluster inputs, plus the
// no-mutation-by-resolve guarantee.

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

private let decoder = JSONDecoder()
private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()

private func config(_ json: String) -> Canonical.ScheduleConfig? {
    try? decoder.decode(Canonical.ScheduleConfig.self, from: Data(json.utf8))
}

// MARK: - Defaults / null / zero / minute handling

do {
    let resolved = NativeSchedule.resolveSchedule(nil)
    expectEqual(resolved, .defaults, "absent schedule resolves to defaults")
}

do {
    let cfg = config("{\"workDays\":null,\"workDayStart\":null,\"bufferMinutes\":null,\"timeZone\":null,\"bookableSlotsEnabled\":null}")
    let resolved = NativeSchedule.resolveSchedule(cfg)
    expectEqual(resolved, .defaults, "explicit nulls resolve to defaults")
}

do {
    // Valid zero lead/buffer survive (FA-017); zero duration/horizon fall back.
    let cfg = config("{\"bufferMinutes\":0,\"slotLeadHours\":0,\"defaultDurationMinutes\":0,\"slotWindowDays\":0}")
    let r = NativeSchedule.resolveSchedule(cfg)
    expectEqual(r.bufferMinutes, 0, "zero buffer is legal and preserved")
    expectEqual(r.slotLeadHours, 0, "zero lead is legal and preserved")
    expectEqual(r.defaultDurationMinutes, 60, "zero duration falls back to 60")
    expectEqual(r.slotWindowDays, 14, "zero horizon falls back to 14")
}

do {
    // Non-finite / wrong-typed numbers cannot be expressed in the typed
    // canonical model; absent optionals cover the fallback path.
    let cfg = config("{\"defaultDurationMinutes\":-30,\"bufferMinutes\":-5}")
    let r = NativeSchedule.resolveSchedule(cfg)
    expectEqual(r.defaultDurationMinutes, 60, "negative duration falls back")
    expectEqual(r.bufferMinutes, 0, "negative buffer falls back")
}

do {
    // Minute precision retained — resolving never rounds the window.
    let cfg = config("{\"workDayStart\":\"08:30\",\"workDayEnd\":\"17:45\"}")
    let r = NativeSchedule.resolveSchedule(cfg)
    expectEqual(r.workDayStart, "08:30", "minute-precise start retained")
    expectEqual(r.workDayEnd, "17:45", "minute-precise end retained")
}

do {
    // Half-valid window: BOTH revert to defaults.
    let r = NativeSchedule.resolveSchedule(config("{\"workDayStart\":\"18:00\",\"workDayEnd\":\"17:00\"}"))
    expectEqual(r.workDayStart, "08:00", "inverted window reverts start")
    expectEqual(r.workDayEnd, "17:00", "inverted window reverts end")
    let bad = NativeSchedule.resolveSchedule(config("{\"workDayStart\":\"oops\",\"workDayEnd\":\"17:00\"}"))
    expectEqual(bad.workDayStart, "08:00", "malformed start reverts")
    expectEqual(bad.workDayEnd, "17:00", "lone valid end still reverts with bad start")
}

// MARK: - ISO days

do {
    expectEqual(NativeSchedule.isoWeekday("2026-08-10"), 1, "2026-08-10 is Monday (ISO 1)")
    expectEqual(NativeSchedule.isoWeekday("2026-08-09"), 7, "2026-08-09 is Sunday (ISO 7)")
    expectEqual(NativeSchedule.isoWeekday("2026-02-30"), nil, "impossible date has no weekday")
    let sunday: NativeSchedule.ResolvedSchedule = .defaults
    expect(!NativeSchedule.isWorkDay(sunday, date: "2026-08-09"), "Sunday is not a default workday")
    expect(NativeSchedule.isWorkDay(sunday, date: "2026-08-08"), "Saturday is a default workday")
    let sundaysOnly = NativeSchedule.resolveSchedule(config("{\"workDays\":[7,7,0,8]}"))
    expectEqual(sundaysOnly.workDays, [7], "workdays dedupe, sort, drop out-of-range")
    expect(NativeSchedule.isWorkDay(NativeSchedule.ResolvedSchedule(
        timeZone: nil, workDays: [7], workDayStart: "08:00", workDayEnd: "17:00",
        defaultDurationMinutes: 60, bufferMinutes: 0, slotLeadHours: 24,
        slotWindowDays: 14, blackouts: [], bookableSlotsEnabled: false), date: "2026-08-09"),
        "custom Sunday-only schedule matches Sunday")
    let empty = NativeSchedule.resolveSchedule(config("{\"workDays\":[]}"))
    expectEqual(empty.workDays, [1, 2, 3, 4, 5, 6], "empty workdays fall back to defaults")
}

// MARK: - No mutation merely by resolving legacy config

do {
    let raw = "{\"workDayStart\":\"08:30\",\"zzzFuture\":\"keep-me\",\"bookableSlotsEnabled\":true}"
    let cfg = config(raw)!
    let before = try! encoder.encode(cfg)
    _ = NativeSchedule.resolveSchedule(cfg)
    let after = try! encoder.encode(cfg)
    expectEqual(after, before, "resolving a legacy config does not mutate it")
    let roundTrip = try! JSONSerialization.jsonObject(with: after) as! [String: Any]
    expectEqual(roundTrip["zzzFuture"] as? String, "keep-me", "unknown legacy field preserved")
    expect(roundTrip["workDays"] == nil, "resolve does not write defaults back into the record")
}

// MARK: - Conflicts: endpoint touch, buffer, terminal, missing start/end

do {
    let jobs = [job("a", date: "2026-08-10", start: "09:00", end: "11:00")]
    let touch = NativeSchedule.findScheduleConflicts(jobs: jobs, query: .init(
        date: "2026-08-10", start: "11:00", end: "13:00", laborHours: 2))
    expect(touch.isEmpty, "touching endpoints are legal (strict overlap)")
    let overlap = NativeSchedule.findScheduleConflicts(jobs: jobs, query: .init(
        date: "2026-08-10", start: "10:59", end: "13:00", laborHours: 2))
    expectEqual(overlap.map(\.scheduleJobId), ["a"], "one-minute overlap conflicts")
}

do {
    let jobs = [job("a", date: "2026-08-10", start: "09:00", end: "10:00")]
    let exactBuffer = NativeSchedule.findScheduleConflicts(jobs: jobs, query: .init(
        date: "2026-08-10", start: "10:30", end: "11:30", laborHours: 1, bufferMinutes: 30))
    expect(exactBuffer.isEmpty, "gap exactly equal to buffer is legal")
    let underBuffer = NativeSchedule.findScheduleConflicts(jobs: jobs, query: .init(
        date: "2026-08-10", start: "10:29", end: "11:30", laborHours: 1, bufferMinutes: 30))
    expectEqual(underBuffer.map(\.scheduleJobId), ["a"], "gap smaller than buffer conflicts")
}

do {
    let jobs = [
        job("t1", date: "2026-08-10", start: "09:00", end: "12:00", status: "complete"),
        job("t2", date: "2026-08-10", start: "09:00", end: "12:00", status: "invoiced"),
        job("t3", date: "2026-08-10", start: "09:00", end: "12:00", status: "paid"),
        job("t4", date: "2026-08-10", start: "09:00", end: "12:00", status: "declined"),
        job("live", date: "2026-08-10", start: "09:00", end: "12:00", status: "approved"),
    ]
    let hits = NativeSchedule.findScheduleConflicts(jobs: jobs, query: .init(
        date: "2026-08-10", start: "10:00", end: "10:30", laborHours: 1))
    expectEqual(hits.map(\.scheduleJobId), ["live"], "terminal statuses never conflict; live ones do")
}

do {
    let jobs = [job("nostart", date: "2026-08-10", start: nil)]
    let hits = NativeSchedule.findScheduleConflicts(jobs: jobs, query: .init(
        date: "2026-08-10", start: "09:00", end: "10:00", laborHours: 1))
    expect(hits.isEmpty, "missing-start jobs never block")
    expectEqual(NativeSchedule.blockWindow(start: "09:00", end: nil, laborHours: 0.5)?.1, 600,
                "missing end with 0.5h labor blocks one hour")
    expectEqual(NativeSchedule.blockWindow(start: "09:00", end: nil, laborHours: 2)?.1, 660,
                "missing end with 2h labor blocks two hours")
    expectEqual(NativeSchedule.blockWindow(start: "23:30", end: nil, laborHours: 2)?.1, 1440,
                "missing-end window caps at midnight")
    expectEqual(NativeSchedule.minutesToLabel(1440), "24:00", "axis label does not clamp midnight")
}

// MARK: - Blackouts (inclusive both bounds)

do {
    let schedule = NativeSchedule.resolveSchedule(config(
        "{\"blackouts\":[{\"id\":\"b1\",\"start\":\"2026-08-12\",\"end\":\"2026-08-14\",\"reason\":\"Fair\"}," +
        "{\"id\":\"bad\",\"start\":\"2026-08-20\",\"end\":\"2026-08-19\"}," +
        "{\"id\":\"\",\"start\":\"2026-08-20\",\"end\":\"2026-08-21\"}]}"))
    expectEqual(schedule.blackouts.map(\.id), ["b1"], "reversed/blank blackouts dropped")
    expect(NativeSchedule.isBlackoutDate(schedule, date: "2026-08-12"), "blackout start inclusive")
    expect(NativeSchedule.isBlackoutDate(schedule, date: "2026-08-14"), "blackout end inclusive")
    expect(!NativeSchedule.isBlackoutDate(schedule, date: "2026-08-15"), "day after blackout is open")
}

// MARK: - Smart defaults, hints, gaps, week selectors

do {
    expectEqual(NativeSchedule.defaultStartTime(scheduledDate: "2026-08-11", now: (date: "2026-08-10", minutes: 550)), "08:00",
                "non-today date defaults to 08:00")
    expectEqual(NativeSchedule.defaultStartTime(scheduledDate: "2026-08-10", now: (date: "2026-08-10", minutes: 550)), "09:30",
                "today rounds up to next half hour")
    expectEqual(NativeSchedule.defaultStartTime(scheduledDate: "2026-08-10", now: (date: "2026-08-10", minutes: 1425)), "23:30",
                "today start clamps to 23:30")
    expectEqual(NativeSchedule.defaultEndTime(start: "09:00", laborHours: 0), "10:00",
                "empty labor falls back to one hour for end default")
    expectEqual(NativeSchedule.addLaborToStart("09:10", laborHours: 1), "10:15",
                "labor end rounds UP to quarter hour")
    expectEqual(NativeSchedule.formatLaborHint(2), "2h", "whole-hour hint")
    expectEqual(NativeSchedule.formatLaborHint(2.5), "2h 30m", "half-hour hint")
    expectEqual(NativeSchedule.formatLaborHint(0.25), "15m", "quarter-hour hint")
}

do {
    expectEqual(NativeSchedule.largestFreeGap(jobs: [TJob](), date: "2026-08-10"), nil,
                "empty day is not an open slot")
    let jobs = [
        job("a", date: "2026-08-10", start: "09:00", end: "10:00"),
        job("b", date: "2026-08-10", start: "13:00", end: "14:00"),
    ]
    // Gaps: 08:00-09:00 (60), 10:00-13:00 (180), 14:00-17:00 (180) → earlier equal gap wins.
    expectEqual(NativeSchedule.largestFreeGap(jobs: jobs, date: "2026-08-10"),
                NativeSchedule.FreeGap(start: "10:00", minutes: 180), "earlier equal gap wins")
}

do {
    expectEqual(NativeSchedule.weekDates(anchor: "2026-08-12"),
                ["2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13",
                 "2026-08-14", "2026-08-15", "2026-08-16"],
                "week runs Monday to Sunday")
    expectEqual(NativeSchedule.weekDates(anchor: "2026-08-09")?.first, "2026-08-03",
                "Sunday anchor still opens on Monday")
    expectEqual(NativeSchedule.shiftDate("2026-08-31", days: 1), "2026-09-01",
                "shift crosses month boundary")
    expectEqual(NativeSchedule.shiftDate("2026-03-08", days: -1), "2026-03-07",
                "negative shift across DST boundary stays naive")
}

// MARK: - Canonical seam: real Canonical.Job drives conflicts

do {
    let jobJSON = """
    {"id":"cj1","customerId":"c1","customerName":"Ann","title":"Fix","description":"d",\
    "status":"scheduled","scheduledDate":"2026-08-10","scheduledStartTime":"09:00",\
    "scheduledEndTime":"10:00","address":"1 Main","estimateTotal":100,"laborHours":1,\
    "laborRate":85,"materials":[],"materialMarkup":0,"overhead":0,"margin":0,\
    "notes":"","createdAt":"2026-08-01"}
    """
    let canonical = try! decoder.decode(Canonical.Job.self, from: Data(jobJSON.utf8))
    let hits = NativeSchedule.findScheduleConflicts(jobs: [canonical], query: .init(
        date: "2026-08-10", start: "09:30", end: "11:00", laborHours: 1))
    expectEqual(hits.map(\.scheduleJobId), ["cj1"], "canonical jobs drive conflict detection")
}

if failures == 0 {
    print("PASS: native schedule tests")
} else {
    print("FAILED: \(failures) native schedule test(s)")
    exit(1)
}
