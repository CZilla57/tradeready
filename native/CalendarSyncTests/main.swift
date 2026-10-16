import Foundation

// Roadmap Phase 26 (calendar sync), the pure half: spec
// docs/superpowers/specs/2026-10-03-calendar-sync-design.md §2.2, §2.5, §4.1,
// §7 "New Swift suite". Busy rules (every §4.1 row, and the strict
// mirrored-job marker test: only this account's parsed marker is skipped), the wire snapshot
// (clipping, minute floor/ceil, merging, truncation at 500, all-day dates
// under injected Phoenix and Auckland calendars, exact JSON, digest), the
// status copy, and the mirror planner (create/update/delete, convergence,
// foreign and unmarked events, window bounds, floating vs zoned, untimed,
// blockWindow ends, the midnight cap and the 200-op cap). The gate's shared
// vectors run in native/AvailabilityTests against the same JSON as Jest.

private var failures = 0
private var checks = 0

private func expect(_ actual: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if actual() { return }
    failures += 1
    print("FAIL: \(label)")
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    checks += 1
    let value = actual()
    if value != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
    }
}

private func at(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: iso) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

private func calendar(_ zone: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal
}

private typealias Busy = NativeCalendarBusy

/// This account's mirror tag, and another account's.
private let ownTag = NativeCalendarMirror.ownerTag16(subject: "user-1")
private let otherTag = NativeCalendarMirror.ownerTag16(subject: "someone-else")

/// Notes exactly as the mirror writes them for `tag`.
private func mirrorNotes(_ tag: String, job: String = "job-1") -> String {
    "Status: Scheduled\n\(NativeCalendarMirror.managedNote)\n\(NativeCalendarMirror.marker(ownerTag: tag, jobID: job))"
}

private func sample(_ start: String, _ end: String, allDay: Bool = false, availability: Busy.Availability = .busy,
                    status: Busy.Status = .confirmed, declined: Bool = false, calendar: String = "cal-work",
                    notes: String? = nil) -> Busy.Sample {
    Busy.Sample(start: at(start), end: at(end), isAllDay: allDay, availability: availability, status: status,
                ownerDeclined: declined, calendarID: calendar, notes: notes)
}

private func counts(_ s: Busy.Sample, excluded: Set<String> = [], mirror: String? = "cal-tradeready",
                    ownerTag: String? = ownTag) -> Bool {
    Busy.countsAsBusy(s, excludedCalendarIDs: excluded, mirrorCalendarID: mirror, mirrorOwnerTag: ownerTag)
}

// MARK: - Busy rules (§4.1)

do {
    let timed = ("2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z")
    expect(counts(sample(timed.0, timed.1)), "timed busy counts")
    expect(counts(sample(timed.0, timed.1, availability: .unavailable)), "timed unavailable counts")
    expect(counts(sample(timed.0, timed.1, availability: .tentative)), "timed tentative counts (conservative)")
    expect(counts(sample(timed.0, timed.1, availability: .notSupported)), "timed notSupported counts")
    expect(!counts(sample(timed.0, timed.1, availability: .free)), "timed free never counts")
    expect(!counts(sample(timed.0, timed.1, status: .canceled)), "a canceled event never counts")
    expect(counts(sample(timed.0, timed.1, status: .tentative)), "a tentative-status event counts")
    expect(!counts(sample(timed.0, timed.1, declined: true)), "an event the owner declined never counts")
    expect(!counts(sample(timed.0, timed.1), excluded: ["cal-work"]), "an excluded calendar is skipped")
    expect(!counts(sample(timed.0, timed.1, calendar: "cal-tradeready")), "the TradeReady mirror calendar is always skipped")
    expect(!counts(sample(timed.0, timed.1, notes: mirrorNotes(ownTag))), "this account's mirrored job in any calendar is skipped")
    expect(!counts(sample(timed.0, timed.0)), "zero duration never counts")
    expect(!counts(sample(timed.1, timed.0)), "negative duration never counts")

    let day = ("2026-10-10T07:00:00Z", "2026-10-11T07:00:00Z")
    expect(counts(sample(day.0, day.1, allDay: true)), "all-day busy counts")
    expect(counts(sample(day.0, day.1, allDay: true, availability: .unavailable)), "all-day unavailable counts")
    expect(!counts(sample(day.0, day.1, allDay: true, availability: .free)), "all-day free (a birthday) does not count")
    expect(!counts(sample(day.0, day.1, allDay: true, availability: .tentative)), "all-day tentative does not count")
    expect(!counts(sample(day.0, day.1, allDay: true, availability: .notSupported)), "all-day notSupported (a holiday) does not count")

    let all = [sample(timed.0, timed.1), sample(timed.0, timed.1, availability: .free),
               sample(day.0, day.1, allDay: true, availability: .free)]
    expectEqual(Busy.busySamples(all, excludedCalendarIDs: [], mirrorCalendarID: nil, mirrorOwnerTag: ownTag).count, 1,
                "busySamples filters by the same rules")
}

// MARK: - Busy rules: mirrored-job markers (review fix)
//
// An event is skipped as "ours" only when NativeCalendarMirror.parseMarker
// accepts its notes and the tag is this account's: the test reconcile uses.
// A loose "tradeready-job:" substring used to hide any event, in any
// calendar, from the booking page (a parser differential).

do {
    let timed = ("2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z")
    let day = ("2026-10-10T07:00:00Z", "2026-10-11T07:00:00Z")

    // 1. Free text or another owner's marker in a normal calendar still counts.
    let stillBusy: [(String, String)] = [
        ("Agenda: sync on the tradeready-job: export", "free text mid-line"),
        ("tradeready-job:", "a bare prefix line"),
        ("tradeready-job: call Sam about the deck", "a prefix line with no tag:job"),
        ("Pasted from TradeReady: tradeready-job:\(ownTag):job-1", "this account's marker inside a sentence"),
        ("TRADEREADY-JOB:\(ownTag):job-1", "a marker in other letter case"),
        ("tradeready-job:\(ownTag):", "a marker with an empty job id"),
        ("tradeready-job::job-1", "a marker with an empty tag"),
        (mirrorNotes(otherTag), "another account's well-formed marker"),
        ("tradeready-job:\(ownTag)x:job-1", "a tag that only starts with this account's"),
    ]
    for (notes, label) in stillBusy {
        expect(counts(sample(timed.0, timed.1, notes: notes)), "timed, \(label): still counts as busy")
        expect(counts(sample(day.0, day.1, allDay: true, calendar: "cal-home", notes: notes)),
               "all-day busy, \(label): still counts as busy")
    }
    expect(counts(sample(timed.0, timed.1, notes: mirrorNotes(ownTag)), ownerTag: nil),
           "with no owner tag, no marker is trusted (fails toward busy)")
    expect(counts(sample(timed.0, timed.1, notes: mirrorNotes(ownTag)), ownerTag: ""),
           "an empty owner tag trusts no marker")
    expect(counts(sample(timed.0, timed.1, notes: mirrorNotes(otherTag)), mirror: nil),
           "another account's marker counts with the mirror off too")
    expect(Busy.isOwnMirrorEvent(sample(timed.0, timed.1, notes: mirrorNotes(otherTag)), mirrorOwnerTag: ownTag) == false,
           "isOwnMirrorEvent rejects another account's tag")

    // What the booking page receives: the invite's block is in the snapshot.
    let invite = sample(timed.0, timed.1, notes: "Join: tradeready-job: planning")
    let foreign = sample("2026-10-07T15:00:00Z", "2026-10-07T16:00:00Z", calendar: "cal-home", notes: mirrorNotes(otherTag))
    let ours = sample("2026-10-08T15:00:00Z", "2026-10-08T16:00:00Z", notes: mirrorNotes(ownTag))
    let window = Busy.window(now: at("2026-10-03T14:05:00Z"), timeZoneID: "America/Chicago", days: 14)!
    let shared = Busy.makeSnapshot(
        samples: Busy.busySamples([invite, foreign, ours], excludedCalendarIDs: [], mirrorCalendarID: "cal-tradeready",
                                  mirrorOwnerTag: ownTag),
        window: window, computedAt: at("2026-10-03T14:05:00Z"), calendar: calendar("America/Phoenix"))
    expectEqual(shared.timed, [
        ["2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z"],
        ["2026-10-07T15:00:00Z", "2026-10-07T16:00:00Z"],
    ], "the invite and the foreign-tagged event reach the booking page as busy; this account's mirrored job does not")

    // 2. This account's correctly tagged mirror event outside the mirror
    //    calendar is still skipped (its job already blocks the slot).
    expect(!counts(sample(timed.0, timed.1, calendar: "cal-home", notes: mirrorNotes(ownTag))),
           "this account's mirrored job copied to another calendar is skipped")
    expect(!counts(sample(day.0, day.1, allDay: true, notes: mirrorNotes(ownTag, job: "job:with:colons"))),
           "an all-day mirrored job (job id with colons) outside the mirror calendar is skipped")
    expect(!counts(sample(timed.0, timed.1, notes: "  tradeready-job:\(ownTag):job-1  \nmore notes")),
           "a marker line with surrounding spaces parses, as reconcile parses it")
    expect(!counts(sample(timed.0, timed.1, notes: mirrorNotes(ownTag)), mirror: nil),
           "this account's mirrored job is skipped with no mirror calendar id")
    expectEqual(sample(timed.0, timed.1, notes: mirrorNotes(ownTag)).markerOwnerTag, ownTag,
                "the sample keeps the parsed tag")
    expectEqual(sample(timed.0, timed.1, notes: "Join: tradeready-job: planning").markerOwnerTag, nil,
                "free text yields no tag")
    expect(sample(timed.0, timed.1, notes: mirrorNotes(ownTag)) == sample(timed.0, timed.1, notes: mirrorNotes(ownTag, job: "job-2")),
           "only the tag is kept, never the notes")

    // 3. The other exclusions are unchanged, whatever the notes say.
    expect(!counts(sample(timed.0, timed.1, calendar: "cal-tradeready", notes: mirrorNotes(otherTag))),
           "the mirror calendar is skipped even with another account's marker")
    expect(!counts(sample(timed.0, timed.1, calendar: "cal-tradeready", notes: "Join: tradeready-job: planning")),
           "the mirror calendar is skipped even with free text")
    expect(!counts(sample(timed.0, timed.1, calendar: "cal-tradeready")), "the mirror calendar is skipped with no notes")
    expect(!counts(sample(timed.0, timed.1, notes: mirrorNotes(otherTag)), excluded: ["cal-work"]),
           "an excluded calendar is skipped whatever the notes")
    expect(!counts(sample(timed.0, timed.1, status: .canceled, notes: "tradeready-job: x")), "canceled still never counts")
    expect(!counts(sample(timed.0, timed.1, declined: true, notes: mirrorNotes(otherTag))), "declined still never counts")
    expect(!counts(sample(timed.0, timed.1, availability: .free, notes: "tradeready-job: x")), "free still never counts")
    expect(!counts(sample(timed.0, timed.0, notes: mirrorNotes(otherTag))), "zero duration still never counts")
    expect(!counts(sample(day.0, day.1, allDay: true, availability: .tentative, notes: mirrorNotes(otherTag))),
           "all-day tentative still never counts")
    expect(counts(sample(timed.0, timed.1, notes: "Dentist, bring forms")), "ordinary notes change nothing")
}

// MARK: - Window (§2.2)

do {
    let w = Busy.window(now: at("2026-10-03T14:05:00Z"), timeZoneID: "America/Chicago", days: 14)!
    expectEqual(Busy.instant(w.start), "2026-10-03T05:00:00Z", "windowStart is the start of today in the owner zone")
    expectEqual(Busy.instant(w.end), "2026-10-17T05:00:00Z", "windowEnd is 14 owner days later")
    expectEqual(w.firstDate, "2026-10-03", "first covered owner date")
    expectEqual(w.lastDate, "2026-10-16", "last covered owner date")

    let dst = Busy.window(now: at("2026-10-31T15:00:00Z"), timeZoneID: "America/Chicago", days: 3)!
    expectEqual(Busy.instant(dst.end), "2026-11-03T06:00:00Z", "windowEnd is zone-aware across the fall-back (CST midnight)")
    let capped = Busy.window(now: at("2026-10-03T14:05:00Z"), timeZoneID: "America/Chicago", days: 120)!
    expectEqual(Int(capped.end.timeIntervalSince(capped.start) / 86_400), 62, "a longer booking horizon is cut to 62 days (R10)")
    expect(Busy.window(now: Date(), timeZoneID: "Mars/Olympus", days: 14) == nil, "an invalid zone has no window")
    let auckland = Busy.window(now: at("2026-10-09T21:00:00Z"), timeZoneID: "Pacific/Auckland", days: 3)!
    expectEqual(Busy.instant(auckland.start), "2026-10-09T11:00:00Z", "Auckland today starts at 11:00Z the day before")
}

// MARK: - Snapshot: clipping, rounding, merging, truncation

let chicagoWindow = Busy.window(now: at("2026-10-03T14:05:00Z"), timeZoneID: "America/Chicago", days: 14)!
let phoenix = calendar("America/Phoenix")

do {
    let samples = [
        sample("2026-10-03T03:00:00Z", "2026-10-03T06:00:00Z"),           // starts before the window
        sample("2026-10-06T15:00:30Z", "2026-10-06T16:00:10Z"),           // seconds round outward
        sample("2026-10-06T16:01:00Z", "2026-10-06T17:00:00Z"),           // touches the rounded end
        sample("2026-10-07T15:00:00Z", "2026-10-07T17:00:00Z"),
        sample("2026-10-07T16:00:00Z", "2026-10-07T18:00:00Z"),           // overlaps
        sample("2026-10-16T22:00:00Z", "2026-10-18T00:00:00Z"),           // ends after the window
    ]
    let snap = Busy.makeSnapshot(samples: samples, window: chicagoWindow, computedAt: at("2026-10-03T14:05:42Z"), calendar: phoenix)
    expectEqual(snap.computedAt, "2026-10-03T14:05:00Z", "computedAt is floored to the minute")
    expectEqual(snap.windowStart, "2026-10-03T05:00:00Z", "windowStart on the wire")
    expectEqual(snap.windowEnd, "2026-10-17T05:00:00Z", "windowEnd on the wire")
    expectEqual(snap.timed, [
        ["2026-10-03T05:00:00Z", "2026-10-03T06:00:00Z"],
        ["2026-10-06T15:00:00Z", "2026-10-06T17:00:00Z"],
        ["2026-10-07T15:00:00Z", "2026-10-07T18:00:00Z"],
        ["2026-10-16T22:00:00Z", "2026-10-17T05:00:00Z"],
    ], "clipped to the window, start floored, end ceiled, touching and overlapping blocks merged")
    expect(Busy.validate(snap, nowMillis: Busy.parseInstant("2026-10-03T14:06:00Z")!) != nil, "a built snapshot passes the Worker's validation twin")
}

do {
    var many: [Busy.Sample] = []
    for i in 0..<501 {
        let start = at("2026-10-03T06:00:00Z").addingTimeInterval(Double(i) * 40 * 60)
        many.append(Busy.Sample(start: start, end: start.addingTimeInterval(20 * 60), calendarID: "cal-work"))
    }
    let snap = Busy.makeSnapshot(samples: many, window: chicagoWindow, computedAt: at("2026-10-03T14:05:00Z"), calendar: phoenix)
    expectEqual(snap.timed.count, 500, "truncation keeps the first 500 blocks")
    expectEqual(snap.windowEnd, Busy.instant(many[500].start), "truncation pulls windowEnd back to the 501st block's start")
    expect(Busy.validate(snap, nowMillis: Busy.parseInstant("2026-10-03T14:06:00Z")!) != nil, "a truncated snapshot is still valid")
    expectEqual(snap.timed.last?[1], Busy.instant(many[499].end), "the kept tail ends before the new windowEnd")
}

// MARK: - Snapshot: all-day dates under injected calendars

do {
    // A Phoenix device's all-day event on 2026-10-10 (floating midnight).
    let phoenixDay = sample("2026-10-10T07:00:00Z", "2026-10-11T07:00:00Z", allDay: true)
    let phoenixSnap = Busy.makeSnapshot(samples: [phoenixDay], window: chicagoWindow, computedAt: at("2026-10-03T14:05:00Z"), calendar: phoenix)
    expectEqual(phoenixSnap.allDay, [["2026-10-10", "2026-10-10"]], "Phoenix: startDate and endDate − 1 s give one date")
    // The same date on an Auckland device (NZDT, +13).
    let aucklandDay = sample("2026-10-09T11:00:00Z", "2026-10-10T11:00:00Z", allDay: true)
    let aucklandSnap = Busy.makeSnapshot(samples: [aucklandDay], window: chicagoWindow, computedAt: at("2026-10-03T14:05:00Z"), calendar: calendar("Pacific/Auckland"))
    expectEqual(aucklandSnap.allDay, [["2026-10-10", "2026-10-10"]], "Auckland: the device calendar reads the same owner date")
    let misread = Busy.makeSnapshot(samples: [aucklandDay], window: chicagoWindow, computedAt: at("2026-10-03T14:05:00Z"), calendar: phoenix)
    expectEqual(misread.allDay, [["2026-10-09", "2026-10-10"]], "the injected calendar decides the dates (Auckland midnights read in Phoenix span two)")

    let multi = [
        sample("2026-10-12T07:00:00Z", "2026-10-14T07:00:00Z", allDay: true),   // 12–13
        sample("2026-10-14T07:00:00Z", "2026-10-15T07:00:00Z", allDay: true),   // 14 (adjacent)
        sample("2026-10-01T07:00:00Z", "2026-10-05T07:00:00Z", allDay: true),   // 1–4, clipped to 3–4
        sample("2026-10-16T07:00:00Z", "2026-10-30T07:00:00Z", allDay: true),   // 16–29, clipped to 16
    ]
    let snap = Busy.makeSnapshot(samples: multi, window: chicagoWindow, computedAt: at("2026-10-03T14:05:00Z"), calendar: phoenix)
    expectEqual(snap.allDay, [["2026-10-03", "2026-10-04"], ["2026-10-12", "2026-10-14"], ["2026-10-16", "2026-10-16"]],
                "all-day ranges are clipped to the window's owner dates and adjacent ranges merge")
}

// MARK: - Snapshot: exact wire JSON and digest

do {
    let snap = Busy.Snapshot(computedAt: "2026-10-03T14:05:00Z", windowStart: "2026-10-03T05:00:00Z",
                             windowEnd: "2026-10-17T05:00:00Z",
                             timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:30:00Z"]],
                             allDay: [["2026-10-10", "2026-10-11"]])
    expectEqual(Busy.encode(snap),
                #"{"v":1,"computedAt":"2026-10-03T14:05:00Z","windowStart":"2026-10-03T05:00:00Z","windowEnd":"2026-10-17T05:00:00Z","timed":[["2026-10-06T15:00:00Z","2026-10-06T16:30:00Z"]],"allDay":[["2026-10-10","2026-10-11"]]}"#,
                "the exact wire JSON (§2.2 key order)")
    let empty = Busy.Snapshot(computedAt: "2026-10-03T14:05:00Z", windowStart: "2026-10-03T05:00:00Z", windowEnd: "2026-10-17T05:00:00Z")
    expectEqual(Busy.encode(empty).hasSuffix(#""timed":[],"allDay":[]}"#), true, "empty lists encode as []")
    let decoded = try? JSONSerialization.jsonObject(with: Data(Busy.encode(snap).utf8)) as? [String: Any]
    expectEqual(decoded?["v"] as? Int, 1, "the wire JSON parses")

    let digest = Busy.digest(snap)
    expectEqual(digest.count, 64, "digest is SHA-256 hex")
    expectEqual(Busy.digest(snap), digest, "digest is stable")
    var later = snap
    later.computedAt = "2026-10-03T14:35:00Z"
    expectEqual(Busy.digest(later), digest, "a newer computedAt alone does not change the digest")
    var moved = snap
    moved.timed = [["2026-10-06T15:00:00Z", "2026-10-06T17:00:00Z"]]
    expect(Busy.digest(moved) != digest, "a changed block changes the digest")
    var shorter = snap
    shorter.windowEnd = "2026-10-16T05:00:00Z"
    expect(Busy.digest(shorter) != digest, "a changed windowEnd changes the digest")
}

// MARK: - Overlay and status copy

do {
    let snap = Busy.makeSnapshot(samples: [sample("2026-10-06T15:00:00Z", "2026-10-06T16:30:00Z")],
                                 window: chicagoWindow, computedAt: at("2026-10-03T14:05:00Z"), calendar: phoenix)
    let overlay = Busy.overlayWindows(snap, timeZoneID: "America/Chicago", nowMillis: Busy.parseInstant("2026-10-03T14:06:00Z")!)
    expectEqual(overlay, [NativeAvailability.BusyWindow(date: "2026-10-06", start: "10:00", end: "11:30")],
                "the overlay runs the booking gate on the local snapshot (what you see is what the page enforces)")

    let now = at("2026-10-03T14:10:00Z")
    expectEqual(Busy.statusText(.shared(updatedAt: at("2026-10-03T14:05:00Z"), days: 14), now: now),
                "Booking page updated 5 min ago · busy times for the next 14 days", "status: shared")
    expectEqual(Busy.statusText(.notShared, now: now), "Not shared: bookable time slots are off", "status: not shared")
    expectEqual(Busy.statusText(.otherDevice(lastUpdate: at("2026-10-03T11:10:00Z")), now: now),
                "Runs on another device · last update 3 h ago", "status: another device")
    expectEqual(Busy.statusText(.outOfDate, now: now),
                "Out of date: your booking page takes requests only until TradeReady checks again", "status: out of date")
    expectEqual(Busy.relativeAge(from: now, to: now), "just now", "age: just now")
    expectEqual(Busy.relativeAge(from: at("2026-10-01T14:10:00Z"), to: now), "2 days ago", "age: days")

    let status = Busy.ServerStatus(enabled: true, thisDevice: false, shared: true, fresh: false,
                                   computedAt: at("2026-10-03T14:10:00Z"), receivedAt: at("2026-10-03T14:05:00Z"))
    expectEqual(status.lastRunAt, at("2026-10-03T14:05:00Z"), "last run is min(computedAt, receivedAt)")
}

// MARK: - Instant parsing

do {
    expectEqual(Busy.parseInstant("2026-10-03T14:05:00Z"), Int64(1_791_036_300_000), "a wire instant parses")
    for bad in ["2026-10-03T14:05:30Z", "2026-10-03T14:05:00.000Z", "2026-02-30T10:00:00Z", "2026-10-03T24:00:00Z",
                "2026-10-03 14:05:00Z", "+026-10-03T14:05:00Z"] {
        expect(Busy.parseInstant(bad) == nil, "not a wire instant: \(bad)")
    }
    expectEqual(Busy.normalizeInstant("2026-10-03T14:05:00+00:00"), "2026-10-03T14:05:00Z", "a PostgREST timestamptz normalizes")
    expectEqual(Busy.normalizeInstant("2026-10-03T14:05:30+00:00"), nil, "seconds do not normalize")
    expectEqual(Busy.parseAnyInstant("2026-10-03T14:06:12.345Z"), Int64(1_791_036_372_345), "received_at keeps milliseconds")
}

// MARK: - Mirror: owner tag and markers

typealias Mirror = NativeCalendarMirror

do {
    let tag = Mirror.ownerTag16(subject: "user-1")
    expectEqual(tag.count, 16, "ownerTag16 is 16 characters")
    expect(tag.allSatisfy { $0.isHexDigit }, "ownerTag16 is hex")
    expectEqual(Mirror.ownerTag16(subject: "user-1"), tag, "ownerTag16 is deterministic across devices")
    expect(Mirror.ownerTag16(subject: "user-2") != tag, "another account has another tag")
    let notes = "Status: Scheduled\n\(Mirror.managedNote)\n\(Mirror.marker(ownerTag: tag, jobID: "job:1"))"
    expect(Mirror.parseMarker(notes).map { $0.ownerTag == tag && $0.jobID == "job:1" } ?? false, "the marker parses, ids may contain colons")
    expect(Mirror.parseMarker("Dentist") == nil, "unmarked notes have no marker")
    expect(Mirror.parseMarker(nil) == nil, "no notes, no marker")
}

// MARK: - Mirror: desired events

struct MJob: MirrorJobLike {
    var scheduleJobId: String
    var scheduledDate: String?
    var scheduledStartTime: String?
    var scheduledEndTime: String?
    var scheduleLaborHours: Double
    var status: String
    var createdAt: String
    var archivedAt: String?
    var mirrorTitle: String
    var mirrorCustomerName: String
    var mirrorAddress: String
}

private func mjob(_ id: String, date: String? = "2026-10-06", start: String? = "09:00", end: String? = "11:00",
                  labor: Double = 1, status: String = "scheduled", archived: String? = nil,
                  title: String = "Panel upgrade", customer: String = "Pat Lee", address: String = "12 Elm St") -> MJob {
    MJob(scheduleJobId: id, scheduledDate: date, scheduledStartTime: start, scheduledEndTime: end,
         scheduleLaborHours: labor, status: status, createdAt: "2026-09-01", archivedAt: archived,
         mirrorTitle: title, mirrorCustomerName: customer, mirrorAddress: address)
}

private let tag = Mirror.ownerTag16(subject: "user-1")
private let today = "2026-10-03"
private var zoned: NativeSchedule.ResolvedSchedule {
    var s = NativeSchedule.ResolvedSchedule.defaults
    s.timeZone = "America/Chicago"
    return s
}

private func desired(_ jobs: [MJob], schedule: NativeSchedule.ResolvedSchedule? = nil) -> [Mirror.DesiredEvent] {
    Mirror.desiredEvents(jobs: jobs, schedule: schedule ?? zoned, today: today, ownerTag: tag)
}

do {
    let events = desired([mjob("j1")])
    expectEqual(events.count, 1, "a scheduled job is mirrored")
    let f = events[0].fields
    expectEqual(f.title, "Panel upgrade — Pat Lee", "title is <job title> — <customer name>")
    expectEqual(f.location, "12 Elm St", "location is the job address")
    expectEqual(f.start, Mirror.NaiveDateTime(date: "2026-10-06", minutes: 540), "timed start")
    expectEqual(f.end, Mirror.NaiveDateTime(date: "2026-10-06", minutes: 660), "timed end")
    expectEqual(f.timeZoneID, "America/Chicago", "a valid schedule zone pins the event")
    expect(!f.isAllDay, "a timed job is not all-day")
    expectEqual(f.url, "tradeready://job/j1", "the URL is the gated job deep link")
    expectEqual(f.notes, "Status: Scheduled\n\(Mirror.managedNote)\ntradeready-job:\(tag):j1", "notes carry status, the managed note and the marker")

    expectEqual(desired([mjob("j1", customer: "")])[0].fields.title, "Panel upgrade", "no customer: just the title")
    expectEqual(desired([mjob("j1", title: "  ", customer: "")])[0].fields.title, "Job", "no title: Job")
    expectEqual(desired([mjob("j1", title: "", customer: "Pat Lee")])[0].fields.title, "Job — Pat Lee", "no title but a customer")
    expectEqual(desired([mjob("j1", address: " ")])[0].fields.location, nil, "an empty address leaves no location")
    expectEqual(desired([mjob("a/b c")])[0].fields.url, "tradeready://job/a%2Fb%20c", "the id is percent-encoded, / included")

    var floating = NativeSchedule.ResolvedSchedule.defaults
    floating.timeZone = nil
    expectEqual(desired([mjob("j1")], schedule: floating)[0].fields.timeZoneID, nil, "no schedule zone: the event floats")
    floating.timeZone = "Mars/Olympus"
    expectEqual(desired([mjob("j1")], schedule: floating)[0].fields.timeZoneID, nil, "an invalid zone floats too")

    let untimed = desired([mjob("j1", start: nil, end: nil)])[0].fields
    expect(untimed.isAllDay, "an untimed job is an all-day event")
    expectEqual(untimed.start, Mirror.NaiveDateTime(date: "2026-10-06", minutes: 0), "all-day starts at the date")
    expectEqual(untimed.end, Mirror.NaiveDateTime(date: "2026-10-07", minutes: 0), "all-day ends at the next date")
    expectEqual(untimed.timeZoneID, nil, "all-day events have no zone")
    expect(desired([mjob("j1", start: "", end: nil)])[0].fields.isAllDay, "an empty start is untimed")

    expectEqual(desired([mjob("j1", end: nil, labor: 2)])[0].fields.end, Mirror.NaiveDateTime(date: "2026-10-06", minutes: 660),
                "a missing end uses start + max(labor, 1 h)")
    expectEqual(desired([mjob("j1", end: nil, labor: 0)])[0].fields.end, Mirror.NaiveDateTime(date: "2026-10-06", minutes: 600),
                "a missing end with no labor uses 1 h")
    expectEqual(desired([mjob("j1", end: "08:00", labor: 1.5)])[0].fields.end, Mirror.NaiveDateTime(date: "2026-10-06", minutes: 630),
                "an end not after the start uses the blockWindow rule")
    expectEqual(desired([mjob("j1", start: "23:30", end: nil, labor: 2)])[0].fields.end, Mirror.NaiveDateTime(date: "2026-10-07", minutes: 0),
                "the derived end is capped at midnight")

    expect(desired([mjob("j1", status: "declined")]).isEmpty, "a declined job is not mirrored")
    expect(desired([mjob("j1", archived: "2026-10-01")]).isEmpty, "an archived job is not mirrored")
    expectEqual(desired([mjob("j1", status: "complete")]).count, 1, "completed jobs stay as history")
    expectEqual(desired([mjob("j1", status: "paid")])[0].fields.notes.hasPrefix("Status: Paid\n"), true, "paid jobs stay, with their status")
    expect(desired([mjob("j1", date: nil)]).isEmpty, "an unscheduled job is not mirrored")
    expect(desired([mjob("j1", date: "2026-02-30")]).isEmpty, "an invalid date is not mirrored")
    expectEqual(desired([mjob("lo", date: "2026-09-03"), mjob("hi", date: "2027-04-01")]).map(\.jobID), ["lo", "hi"],
                "the window includes today − 30 and today + 180")
    expect(desired([mjob("a", date: "2026-09-02"), mjob("b", date: "2027-04-02")]).isEmpty,
           "today − 31 and today + 181 are outside the window")
}

// MARK: - Mirror: plan

private func existing(_ eventID: String, _ event: Mirror.DesiredEvent, external: String? = nil, created: String? = nil,
                      edit: (inout Mirror.Fields) -> Void = { _ in }) -> Mirror.Existing {
    var fields = event.fields
    edit(&fields)
    return Mirror.Existing(eventID: eventID, externalID: external, creationDate: created.map(at), notes: fields.notes, fields: fields)
}

do {
    let want = desired([mjob("j1"), mjob("j2", date: "2026-10-07")])
    expectEqual(Mirror.plan(desired: want, existing: [], ownerTag: tag, today: today),
                [.create(want[0]), .create(want[1])], "no events yet: create each, by start")

    let synced = [existing("e1", want[0]), existing("e2", want[1])]
    expectEqual(Mirror.plan(desired: want, existing: synced, ownerTag: tag, today: today), [], "matching events: nothing to do")

    let edited = [existing("e1", want[0]) { $0.title = "Renamed in Calendar" }, existing("e2", want[1])]
    expectEqual(Mirror.plan(desired: want, existing: edited, ownerTag: tag, today: today),
                [.update(eventID: "e1", want[0])], "a Calendar-app edit is restored (one-way mirror)")
    for (label, change) in [("location", { (f: inout Mirror.Fields) in f.location = nil }),
                            ("start", { (f: inout Mirror.Fields) in f.start.minutes += 30 }),
                            ("end", { (f: inout Mirror.Fields) in f.end.minutes -= 30 }),
                            ("zone", { (f: inout Mirror.Fields) in f.timeZoneID = nil }),
                            ("all-day", { (f: inout Mirror.Fields) in f.isAllDay = true }),
                            ("url", { (f: inout Mirror.Fields) in f.url = "https://example.com" })] {
        let ops = Mirror.plan(desired: [want[0]], existing: [existing("e1", want[0], edit: change)], ownerTag: tag, today: today)
        expectEqual(ops, [.update(eventID: "e1", want[0])], "any field difference updates (\(label))")
    }

    // Declined, archived, unscheduled and deleted jobs are no longer desired.
    for job in [mjob("j1", status: "declined"), mjob("j1", archived: "2026-10-02"), mjob("j1", date: nil)] {
        let ops = Mirror.plan(desired: desired([job]), existing: [existing("e1", want[0])], ownerTag: tag, today: today)
        expectEqual(ops, [.delete(eventID: "e1")], "a job no longer mirrored loses its event (\(job.status), \(job.archivedAt ?? "-"), \(job.scheduledDate ?? "unscheduled"))")
    }
    expectEqual(Mirror.plan(desired: [], existing: [existing("e1", want[0])], ownerTag: tag, today: today),
                [.delete(eventID: "e1")], "a deleted job loses its event")
}

do {
    // Two devices created the same job's event concurrently; each device
    // sees the events in a different order and must pick the same survivor.
    let want = desired([mjob("j1")])
    let a = existing("deviceA-local-1", want[0], external: "EXT-B", created: "2026-10-03T10:00:05Z")
    let b = existing("deviceB-local-9", want[0], external: "EXT-A", created: "2026-10-03T10:00:01Z")
    let c = existing("deviceB-local-2", want[0], external: "EXT-C", created: "2026-10-03T10:00:01Z")
    let onA = Mirror.plan(desired: want, existing: [a, b, c], ownerTag: tag, today: today)
    let onB = Mirror.plan(desired: want, existing: [c, b, a], ownerTag: tag, today: today)
    expectEqual(Set(onA.map { "\($0)" }), Set(["delete(eventID: \"deviceA-local-1\")", "delete(eventID: \"deviceB-local-2\")"]),
                "the earliest creationDate, then the smallest externalID, survives")
    expectEqual(Set(onA.map { "\($0)" }), Set(onB.map { "\($0)" }), "both devices converge on the same survivor")

    let noDates = [existing("z", want[0]), existing("y", want[0])]
    expectEqual(Mirror.plan(desired: want, existing: noDates, ownerTag: tag, today: today), [.delete(eventID: "z")],
                "with no dates or external ids the smallest eventID survives")
}

do {
    let want = desired([mjob("j1")])
    let unmarked = Mirror.Existing(eventID: "u1", externalID: nil, creationDate: nil, notes: "Dentist",
                                   fields: Mirror.Fields(title: "Dentist", location: nil, notes: "Dentist", url: "", isAllDay: false,
                                                        start: .init(date: "2026-10-06", minutes: 540), end: .init(date: "2026-10-06", minutes: 600),
                                                        timeZoneID: nil))
    let foreignTag = Mirror.ownerTag16(subject: "someone-else")
    var foreign = existing("f1", desired([mjob("j9")])[0])
    foreign.notes = foreign.notes?.replacingOccurrences(of: tag, with: foreignTag)
    let ops = Mirror.plan(desired: want, existing: [unmarked, foreign], ownerTag: tag, today: today)
    expectEqual(ops, [.create(want[0])], "unmarked events and another owner's events are never touched")

    let outside = existing("old", desired([mjob("j0", date: "2026-09-03")])[0]) { $0.start.date = "2026-08-01"; $0.end.date = "2026-08-01" }
    expectEqual(Mirror.plan(desired: [], existing: [outside], ownerTag: tag, today: today), [],
                "events starting outside the mirror window are not considered")
}

do {
    let jobs = (0..<250).map { mjob("j\(String(format: "%03d", $0))", date: "2026-10-\(String(format: "%02d", 4 + $0 % 20))") }
    let ops = Mirror.plan(desired: desired(jobs), existing: [], ownerTag: tag, today: today)
    expectEqual(ops.count, 200, "a pass makes at most 200 operations")
    let stale = (0..<5).map { existing("x\($0)", desired([mjob("gone\($0)")])[0]) }
    let mixed = Mirror.plan(desired: desired(jobs), existing: stale, ownerTag: tag, today: today)
    expect(mixed.prefix(5).allSatisfy { if case .delete = $0 { return true } else { return false } }, "deletes come first")
}

// MARK: - Mirror: ownership (adopt and remove decisions, review fix)

private func withTag(_ event: Mirror.Existing, _ newTag: String?) -> Mirror.Existing {
    var copy = event
    copy.notes = newTag.map { event.notes?.replacingOccurrences(of: tag, with: $0) } ?? "Dentist"
    return copy
}

do {
    expect(Mirror.isMirrorCalendarTitle("TradeReady") && Mirror.isMirrorCalendarTitle("TradeReady Jobs")
           && Mirror.isMirrorCalendarTitle("TradeReady Jobs 2") && Mirror.isMirrorCalendarTitle("TradeReady Jobs 17"),
           "the titles the mirror creates are recognised")
    expect(!Mirror.isMirrorCalendarTitle("Work") && !Mirror.isMirrorCalendarTitle("tradeready") && !Mirror.isMirrorCalendarTitle("TradeReady Jobs 1")
           && !Mirror.isMirrorCalendarTitle("TradeReady Jobs X") && !Mirror.isMirrorCalendarTitle("TradeReady (old)"),
           "other titles are not mirror titles")
    expectEqual(Mirror.newCalendarTitle(existingTitles: ["Home", "Work"]), "TradeReady", "a free title is used as is")
    expectEqual(Mirror.newCalendarTitle(existingTitles: ["TradeReady"]), "TradeReady Jobs", "a taken title gets a distinct one")
    expectEqual(Mirror.newCalendarTitle(existingTitles: ["TradeReady", "TradeReady Jobs"]), "TradeReady Jobs 2", "and a taken distinct one is numbered")
    expectEqual(Mirror.newCalendarTitle(existingTitles: ["TradeReady", "TradeReady Jobs", "TradeReady Jobs 2"]), "TradeReady Jobs 3", "numbering continues")

    let want = desired([mjob("j1"), mjob("j2", date: "2026-10-07")])
    let own1 = existing("e1", want[0])
    let own2 = existing("e2", want[1])
    let foreign = withTag(existing("f1", want[0]), otherTag)
    let unmarked = withTag(existing("u1", want[0]), nil)
    func candidate(_ id: String, _ events: [Mirror.Existing], title: String = "TradeReady", writable: Bool = true) -> Mirror.CalendarCandidate {
        Mirror.CalendarCandidate(id: id, title: title, allowsModifications: writable, events: events)
    }

    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [own1, own2])], ownerTag: tag), "c1",
                "a calendar whose every event carries this account's tag is adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [foreign, withTag(own2, otherTag)])], ownerTag: tag), nil,
                "a same-title calendar holding another account's mirror is never adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [unmarked])], ownerTag: tag), nil,
                "a same-title calendar of the owner's own events is never adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [own1, foreign])], ownerTag: tag), nil,
                "a mixed calendar (own and another account's events) is never adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [own1, unmarked])], ownerTag: tag), nil,
                "a calendar with one unmarked event is never adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [])], ownerTag: tag), nil,
                "an empty calendar proves nothing and is never adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [own1], writable: false)], ownerTag: tag), nil,
                "a read-only calendar is never adopted")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [own1], title: "Work")], ownerTag: tag), nil,
                "a calendar with another title is never adopted, even with this account's events")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c1", [own1], title: "TradeReady Jobs 2")], ownerTag: tag), "c1",
                "a numbered mirror title is adoptable on proof")
    expectEqual(Mirror.adoptableCalendarID(candidates: [candidate("c9", [own1]), candidate("c2", [own2]), candidate("c5", [foreign])], ownerTag: tag), "c2",
                "several provable calendars resolve to the smallest id and a foreign one is skipped")

    expectEqual(Mirror.removalDecision(events: [own1, own2], ownerTag: tag), .removeCalendar,
                "every event this account's: the whole calendar goes")
    expectEqual(Mirror.removalDecision(events: [], ownerTag: tag), .removeCalendar, "an empty mirror calendar goes")
    expectEqual(Mirror.removalDecision(events: [own2, foreign, own1, unmarked], ownerTag: tag), .deleteEvents(eventIDs: ["e1", "e2"]),
                "foreign or unmarked events present: only this account's events are deleted, the calendar stays")
    expectEqual(Mirror.removalDecision(events: [foreign, unmarked], ownerTag: tag), .deleteEvents(eventIDs: []),
                "nothing of this account's: nothing is deleted, the calendar stays")
    expect(Mirror.isOwnEvent(notes: own1.notes, ownerTag: tag) && !Mirror.isOwnEvent(notes: foreign.notes, ownerTag: tag)
           && !Mirror.isOwnEvent(notes: "tradeready-job:\(tag)", ownerTag: tag) && !Mirror.isOwnEvent(notes: nil, ownerTag: tag),
           "isOwnEvent is the strict parsed-tag test")
}

// MARK: - Mirror: plan matches by job id, not by window (review fix)

do {
    let want = desired([mjob("j1")])
    // The adapter's fetch window is in the device zone, so a job on the edge
    // date can start outside it, or (here) outside the date window itself:
    // the planner must still find its event by the job id in the marker.
    for date in ["2026-09-02", "2026-09-03", "2026-04-01", "2027-06-01", "2026-04-02"] {
        let moved = existing("e1", want[0]) { $0.start.date = date; $0.end.date = date }
        let ops = Mirror.plan(desired: want, existing: [moved], ownerTag: tag, today: today)
        expectEqual(ops, [.update(eventID: "e1", want[0])], "an event of a wanted job is matched by id wherever it starts (\(date)): updated, not duplicated")
    }
    let edge = desired([mjob("j1", date: "2026-09-03", start: "00:30", end: "01:30")])
    let synced = existing("e1", edge[0])
    expectEqual(Mirror.plan(desired: edge, existing: [synced], ownerTag: tag, today: today), [],
                "an edge-date job whose event is fetched makes no operations on repeated passes")
    // A duplicate outside the window still collapses onto one survivor.
    let far = existing("e0", want[0], created: "2026-10-01T00:00:00Z") { $0.start.date = "2026-04-01"; $0.end.date = "2026-04-01" }
    let near = existing("e1", want[0], created: "2026-10-02T00:00:00Z")
    expectEqual(Mirror.plan(desired: want, existing: [far, near], ownerTag: tag, today: today), [.delete(eventID: "e1"), .update(eventID: "e0", want[0])],
                "duplicates of a wanted job collapse onto the earliest, wherever they start")
    // History outside the window for a job that is not wanted is left alone;
    // inside the window it is removed.
    let oldHistory = existing("old", desired([mjob("j0")])[0]) { $0.start.date = "2026-09-02"; $0.end.date = "2026-09-02" }
    let recentOrphan = existing("recent", desired([mjob("j0")])[0]) { $0.start.date = "2026-09-04"; $0.end.date = "2026-09-04" }
    expectEqual(Mirror.plan(desired: [], existing: [oldHistory, recentOrphan], ownerTag: tag, today: today), [.delete(eventID: "recent")],
                "an event of a job that is not wanted is deleted only inside the mirror window")
}

if failures == 0 {
    print("PASS: native calendar sync tests (\(checks) checks)")
} else {
    print("FAILED: \(failures) of \(checks) native calendar sync checks")
    exit(1)
}
