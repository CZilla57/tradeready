import Foundation

// Focused oracle/failure tests for NativeAvailability (task 8.01, S1):
// defaults parity, grid/duration fit, workday/blackout/lead/horizon,
// busy windows (jobs + reservations), buffer exactness, terminal/missing
// handling, and the IANA zone boundary (DST spring gap, fall fold, shared
// JSON fixtures with RN/Workers).

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
                 labor: Double = 1, status: String = "scheduled") -> TJob {
    TJob(scheduleJobId: id, scheduledDate: date, scheduledStartTime: start,
         scheduledEndTime: end, scheduleLaborHours: labor, status: status,
         createdAt: "2026-08-01", archivedAt: nil)
}

private let decoder = JSONDecoder()

private func config(_ json: String) -> Canonical.ScheduleConfig {
    try! decoder.decode(Canonical.ScheduleConfig.self, from: Data(json.utf8))
}

private func openSchedule(_ json: String = "{}") -> NativeSchedule.ResolvedSchedule {
    var r = NativeSchedule.resolveSchedule(config(json))
    r.slotLeadHours = 0 // tests inject their own `now`; lead covered separately
    return r
}

// Monday 2026-08-10, 08:00-17:00, 60-min duration, no jobs, no lead.
private func mondayInput(_ schedule: NativeSchedule.ResolvedSchedule) -> NativeAvailability.AvailabilityInput<TJob> {
    NativeAvailability.AvailabilityInput(schedule: schedule, jobs: [TJob](),
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
}

// MARK: - Defaults parity, grid, duration fit

do {
    let slots = NativeAvailability.computeCandidateSlots(input: mondayInput(openSchedule()))
    expectEqual(slots.count, 17, "open Monday offers 08:00-16:00 on the 30-min grid")
    expectEqual(slots.first, NativeAvailability.CandidateSlot(date: "2026-08-10", start: "08:00", end: "09:00"),
                "first slot starts at work open")
    expectEqual(slots.last?.start, "16:00", "last 60-min slot starts at 16:00")
    // Consecutive grid starts produce overlapping candidates by design.
    expect(slots.contains { $0.start == "09:00" } && slots.contains { $0.start == "09:30" },
           "overlapping consecutive candidates are both offered (server claims)")
}

do {
    // Entire duration must fit: 30-min gap takes no 60-min slot.
    var narrow = openSchedule("{\"workDayStart\":\"08:00\",\"workDayEnd\":\"09:30\"}")
    narrow.slotLeadHours = 0
    let jobs = [job("a", date: "2026-08-10", start: "08:00", end: "09:00")]
    let input = NativeAvailability.AvailabilityInput(schedule: narrow, jobs: jobs,
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    expect(NativeAvailability.computeCandidateSlots(input: input).isEmpty,
           "duration must fit entirely inside the gap")
}

// MARK: - Workdays, blackouts, horizon

do {
    // Sunday: not a default workday.
    let sunday = NativeAvailability.AvailabilityInput(schedule: openSchedule(), jobs: [TJob](),
        fromDate: "2026-08-09", days: 1, now: (date: "2026-08-09", minutes: 0))
    expect(NativeAvailability.computeCandidateSlots(input: sunday).isEmpty, "Sunday offers nothing by default")
}

do {
    var blacked = openSchedule("{\"blackouts\":[{\"id\":\"b1\",\"start\":\"2026-08-10\",\"end\":\"2026-08-10\"}]}")
    blacked.slotLeadHours = 0
    expect(NativeAvailability.computeCandidateSlots(input: mondayInput(blacked)).isEmpty,
           "blackout day offers nothing")
}

do {
    // Horizon: days=1 covers only fromDate (a Monday); days=2 adds Tuesday.
    let one = NativeAvailability.AvailabilityInput(schedule: openSchedule(), jobs: [TJob](),
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    let two = NativeAvailability.AvailabilityInput(schedule: openSchedule(), jobs: [TJob](),
        fromDate: "2026-08-10", days: 2, now: (date: "2026-08-10", minutes: 0))
    expectEqual(NativeAvailability.computeCandidateSlots(input: one).count, 17, "one-day horizon")
    expectEqual(NativeAvailability.computeCandidateSlots(input: two).count, 34, "two-day horizon adds Tuesday")
}

// MARK: - Lead time, including equality

do {
    var leaded = NativeSchedule.resolveSchedule(config("{}")) // lead 24 by default
    let input = NativeAvailability.AvailabilityInput(schedule: leaded, jobs: [TJob](),
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    expect(NativeAvailability.computeCandidateSlots(input: input).isEmpty,
           "24h lead suppresses same-day Monday slots at midnight")
    // Exact lead equality is offered: now 07:00 + 1h lead == 08:00 slot.
    leaded.slotLeadHours = 1
    let exact = NativeAvailability.AvailabilityInput(schedule: leaded, jobs: [TJob](),
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 420))
    let slots = NativeAvailability.computeCandidateSlots(input: exact)
    expectEqual(slots.first?.start, "08:00", "slot exactly at the lead boundary is offered")
    // One minute later and 08:00 drops while 08:30 stays.
    let late = NativeAvailability.AvailabilityInput(schedule: leaded, jobs: [TJob](),
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 421))
    let lateSlots = NativeAvailability.computeCandidateSlots(input: late)
    expectEqual(lateSlots.first?.start, "08:30", "lead is minute-exact")
}

// MARK: - Busy windows: jobs, reservations, buffer, terminal, missing ends

do {
    let busy = [job("a", date: "2026-08-10", start: "09:00", end: "11:00")]
    let input = NativeAvailability.AvailabilityInput(schedule: openSchedule(), jobs: busy,
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    let slots = NativeAvailability.computeCandidateSlots(input: input)
    expect(!slots.contains { $0.start == "09:00" || $0.start == "10:30" },
           "slots overlapping a live job are gone")
    expect(slots.contains { $0.start == "08:00" } && slots.contains { $0.start == "11:00" },
           "slots around a live job survive")
}

do {
    // Server-passed reservations block like jobs.
    let extra = [NativeAvailability.BusyWindow(date: "2026-08-10", start: "09:00", end: "11:00")]
    let input = NativeAvailability.AvailabilityInput(schedule: openSchedule(), jobs: [TJob](), extraBusy: extra,
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    let slots = NativeAvailability.computeCandidateSlots(input: input)
    expect(!slots.contains { $0.start == "09:00" }, "extra busy window blocks offers")
}

do {
    // Buffer pads busy both sides, merged; a candidate exactly buffer-away is legal.
    var buffered = openSchedule("{\"bufferMinutes\":30}")
    buffered.slotLeadHours = 0
    let busy = [job("a", date: "2026-08-10", start: "09:00", end: "10:00")]
    let input = NativeAvailability.AvailabilityInput(schedule: buffered, jobs: busy,
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    let starts = Set(NativeAvailability.computeCandidateSlots(input: input).map(\.start))
    // 08:00-09:00 ends exactly at the job start: still inside the 30-min
    // buffer, so it is correctly gone (no double separation is about the
    // 10:30 candidate, exactly buffer-away on the far side).
    expect(!starts.contains("08:00"), "slot ending at a buffered job start is blocked")
    expect(!starts.contains("08:30"), "slot inside padded busy is gone")
    expect(starts.contains("10:30"), "candidate exactly buffer-away is legal — no double separation")
    // One minute more buffer removes the touching candidate.
    var wider = openSchedule("{\"bufferMinutes\":31}")
    wider.slotLeadHours = 0
    let widerInput = NativeAvailability.AvailabilityInput(schedule: wider, jobs: busy,
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    expect(!Set(NativeAvailability.computeCandidateSlots(input: widerInput).map(\.start)).contains("10:30"),
           "buffer is minute-exact, not doubled")
}

do {
    let jobs = [
        job("done", date: "2026-08-10", start: "09:00", end: "17:00", status: "complete"),
        job("no-start", date: "2026-08-10", start: nil),
        job("open-ended", date: "2026-08-10", start: "09:00", end: nil, labor: 2),
    ]
    let input = NativeAvailability.AvailabilityInput(schedule: openSchedule(), jobs: jobs,
        fromDate: "2026-08-10", days: 1, now: (date: "2026-08-10", minutes: 0))
    let starts = Set(NativeAvailability.computeCandidateSlots(input: input).map(\.start))
    // The 09:00-17:00 terminal job and the missing-start job block nothing
    // (08:00/08:30 offered); the live open-ended 09:00 blocks max(2h,1h).
    expect(starts.contains("08:00") && !starts.contains("08:30"),
           "terminal and missing-start jobs do not block; live block still applies")
    expect(!starts.contains("09:00") && !starts.contains("10:30"),
           "missing end blocks max(labor, 1h): 09:00+2h")
    expect(starts.contains("11:00"), "offers resume after the derived block")
}

// MARK: - Slot configuration gate (S1)

do {
    var enabled = NativeSchedule.ResolvedSchedule.defaults
    enabled.bookableSlotsEnabled = true
    enabled.timeZone = "America/Chicago"
    expectEqual(NativeAvailability.validateSlotConfiguration(enabled), nil,
                "valid zone with slots enabled passes")
    enabled.timeZone = "Mars/Olympus"
    expectEqual(NativeAvailability.validateSlotConfiguration(enabled), .invalidTimeZone,
                "invalid zone surfaces a configuration error, never fabricated offers")
    enabled.timeZone = nil
    expectEqual(NativeAvailability.validateSlotConfiguration(enabled), .invalidTimeZone,
                "missing zone with slots enabled is a configuration error")
    var disabled = NativeSchedule.ResolvedSchedule.defaults
    disabled.timeZone = "Mars/Olympus"
    expectEqual(NativeAvailability.validateSlotConfiguration(disabled), nil,
                "slots off: existing invalid zone stays recoverable without error")
    expect(!NativeAvailability.isValidIANAZone("Mars/Olympus"), "bogus zone rejected")
    expect(NativeAvailability.isValidIANAZone("America/Chicago"), "real IANA zone accepted")
}

// MARK: - Shared JSON fixtures (RN/Workers parity)

do {
    let fixturesURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCHEDULE_FIXTURES_PATH"]
        ?? "native/ScheduleTests/Fixtures/scheduleVectors.json")
    let data = try! Data(contentsOf: fixturesURL)
    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

    let defaults = (json["defaults"] as! [String: Any])
    expectEqual(defaults["workDayStart"] as? String, "08:00", "shared fixture pins work open")
    expectEqual((defaults["workDays"] as? [Int]), [1, 2, 3, 4, 5, 6], "shared fixture pins ISO days")
    let resolved = NativeSchedule.resolveSchedule(nil)
    expectEqual(resolved.workDays, (defaults["workDays"] as? [Int])!, "native defaults match shared fixture")
    expectEqual(resolved.defaultDurationMinutes, (defaults["defaultDurationMinutes"] as? Int)!,
                "native duration matches shared fixture")

    for vector in json["zoneVectors"] as! [[String: Any]] {
        let date = vector["date"] as! String
        let time = vector["time"] as! String
        let zone = vector["zone"] as! String
        let expected = vector["startUtc"] as? String
        expectEqual(NativeAvailability.zonedTimeToUtc(date: date, time: time, timeZoneID: zone), expected,
                    "shared zone vector \(date) \(time) \(zone)")
    }
    for vector in json["nowVectors"] as! [[String: Any]] {
        let zone = vector["zone"] as! String
        let utcIso = vector["utcIso"] as! String
        let millis = NativeAvailability.iso8601ToMillis(utcIso)!
        let clock = NativeAvailability.nowInZone(timeZoneID: zone, utcMillis: millis)!
        expectEqual(clock.date, (vector["date"] as! String), "shared now vector date \(zone)")
        expectEqual(clock.minutes, (vector["minutes"] as! Int), "shared now vector minutes \(zone)")
    }
}

// MARK: - DST/zone boundary details

do {
    // Spring gap: start nonexistent → slot dropped; end in gap → naive-duration fallback.
    let gapped = [
        NativeAvailability.CandidateSlot(date: "2026-03-08", start: "01:30", end: "02:30"),
        NativeAvailability.CandidateSlot(date: "2026-03-08", start: "02:30", end: "03:30"),
        NativeAvailability.CandidateSlot(date: "2026-03-08", start: "09:00", end: "10:00"),
    ]
    let resolved = NativeAvailability.resolveSlotsUtc(slots: gapped, timeZoneID: "America/Chicago")
    expectEqual(resolved.map(\.start), ["01:30", "09:00"], "nonexistent spring-forward start is dropped")
    // 01:30-02:30 on Mar 8: end 02:30 does not exist → start + 60 naive minutes.
    // Start 01:30 CST (UTC-6) = 07:30Z; +60min = 08:30Z (CDT now active).
    expectEqual(resolved.first?.endUtc, "2026-03-08T08:30:00.000Z",
                "gap end falls back to start plus naive duration")
    expectEqual(resolved.last?.startUtc, "2026-03-08T14:00:00.000Z",
                "post-transition morning resolves on the new offset")
}

do {
    // Fall fold: ambiguous 01:30 resolves to the FIRST occurrence (CDT).
    expectEqual(NativeAvailability.zonedTimeToUtc(date: "2026-11-01", time: "01:30",
                timeZoneID: "America/Chicago"), "2026-11-01T06:30:00.000Z",
                "ambiguous fall-back time takes the earlier occurrence")
    // Local scheduling stays representable even where UTC has a gap.
    expect(NativeSchedule.toMinutes("02:30") == 150, "gap time is still valid owner-naive input")
}

if failures == 0 {
    print("PASS: native availability tests")
} else {
    print("FAILED: \(failures) native availability test(s)")
    exit(1)
}
