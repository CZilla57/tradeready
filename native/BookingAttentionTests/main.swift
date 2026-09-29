import Foundation

// Task 8.02 (B3, P3): attention fixtures for NativeBookingAttention.
// Oracle: utils/bookingAttention.ts + __tests__/bookingAttention.test.ts.
// Decisions: D-B3-1 (unconverted-active inspection), D-B3-3 (portal-change
// dismissal), D-B3-4 (late server state preserved on referenced rows).

private var failures = 0
private let decoder = JSONDecoder()
private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func decodeRequest(_ json: String) -> Canonical.BookingRequest {
    try! decoder.decode(Canonical.BookingRequest.self, from: Data(json.utf8))
}

private func decodeJob(_ json: String) -> Canonical.Job {
    try! decoder.decode(Canonical.Job.self, from: Data(json.utf8))
}

private let slotJSON = """
{"date":"2026-08-12","start":"09:00","end":"10:00","timeZone":"America/Phoenix",
 "startUtc":"2026-08-12T16:00:00.000Z","endUtc":"2026-08-12T17:00:00.000Z"}
"""

private func booked(id: String = "bk1", status: String = "booked",
                    stamped: String? = "jbk_bk1") -> Canonical.BookingRequest {
    var request = decodeRequest("""
    {"id":"\(id)","status":"\(status)","kind":"booked","name":"Dana Fox",
     "phone":"","email":"","address":"","details":"Water heater","preferredTiming":"",
     "createdAt":"2026-08-07T15:00:00.000Z","slot":\(slotJSON)}
    """)
    request.convertedJobId = stamped
    return request
}

private func job(id: String = "jbk_bk1", date: String? = "2026-08-12",
                 start: String? = "09:00", status: String = "lead",
                 archivedAt: String? = nil) -> Canonical.Job {
    var record = decodeJob("""
    {"id":"\(id)","customerId":"c1","customerName":"Dana Fox","title":"Booked appointment",
     "description":"","status":"\(status)","address":"","estimateTotal":0,"laborHours":0,
     "laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,"margin":20,
     "notes":"","createdAt":"2026-08-07"}
    """)
    record.scheduledDate = date
    record.scheduledStartTime = start
    record.scheduledEndTime = "10:00"
    record.archivedAt = archivedAt
    return record
}

private func change(id: String = "bkpr_change", handledAt: String? = nil,
                    jobRef: String? = "j1") -> Canonical.BookingRequest {
    var request = decodeRequest("""
    {"id":"\(id)","status":"portal_change_requested","name":"Dana Fox",
     "phone":"","email":"","address":"",
     "details":"Reschedule requested for \\"Water heater swap\\" (2026-08-12) — Tuesday works better",
     "preferredTiming":"","createdAt":"2026-08-10T12:00:00.000Z",
     "source":"portal","sourceCustomerId":"c1","portalKind":"reschedule"}
    """)
    request.jobRef = jobRef
    request.handledAt = handledAt
    return request
}

private func freeNew(id: String = "bk_free") -> Canonical.BookingRequest {
    decodeRequest("""
    {"id":"\(id)","status":"new","name":"Pat Lee","phone":"","email":"","address":"",
     "details":"Quote please","preferredTiming":"","createdAt":"2026-08-04T15:00:00.000Z"}
    """)
}

private func decodeHistory(actor: String, event: String, note: String?) -> Canonical.BookingHistoryEntry {
    let noteJSON = note.map { "\"\($0)\"" } ?? "null"
    return try! decoder.decode(Canonical.BookingHistoryEntry.self, from: Data("""
    {"at":"2026-08-08T10:00:00.000Z","actor":"\(actor)","event":"\(event)","note":\(noteJSON)}
    """.utf8))
}

// 1. Reschedule requests surface with the customer's latest note.
do {
    var request = booked(status: "reschedule_requested")
    request.history = [
        decodeHistory(actor: "customer", event: "booked", note: nil),
        decodeHistory(actor: "customer", event: "request_reschedule", note: "Afternoons only"),
    ]
    let rows = NativeBookingAttention.select(requests: [request], jobs: [job()])
    expect(rows.count == 1, "reschedule surfaces one row")
    expect(rows[0].kind == .rescheduleRequested, "reschedule kind")
    expect(rows[0].jobID == "jbk_bk1" && rows[0].note == "Afternoons only",
           "job link plus latest customer note")
}

// 2. An unconverted reschedule_requested is actionable, not duplicated as unconverted-active.
do {
    var request = booked(id: "bk_rr", status: "reschedule_requested", stamped: nil)
    request.history = [decodeHistory(actor: "customer", event: "request_reschedule", note: "Friday?")]
    let rows = NativeBookingAttention.select(requests: [request], jobs: [])
    expect(rows.count == 1 && rows[0].kind == .rescheduleRequested,
           "unconverted reschedule surfaces once as actionable")
    expect(rows[0].jobID == nil, "no job link before conversion")
}

// 3. Cancellation comparison: surfaces only while the job still holds the slot.
do {
    let cancelled = booked(status: "cancelled")
    expect(NativeBookingAttention.select(requests: [cancelled], jobs: [job()]).count == 1,
           "cancelled surfaces while the job holds the slot")
    var cleared = job(); cleared.scheduledDate = nil; cleared.scheduledStartTime = nil
    cleared.scheduledEndTime = nil
    expect(NativeBookingAttention.select(requests: [cancelled], jobs: [cleared]).isEmpty,
           "cleared schedule self-dismisses")
    expect(NativeBookingAttention.select(requests: [cancelled],
                                         jobs: [job(date: "2026-08-14", start: "11:00")]).isEmpty,
           "moved job self-dismisses")
    expect(NativeBookingAttention.select(requests: [cancelled],
                                         jobs: [job(archivedAt: "2026-08-09")]).isEmpty,
           "archived job self-dismisses")
    expect(NativeBookingAttention.select(requests: [cancelled],
                                         jobs: [job(status: "declined")]).isEmpty,
           "terminal job self-dismisses")
    expect(NativeBookingAttention.select(requests: [booked(status: "declined")],
                                         jobs: [job()]).count == 1,
           "owner-declined behaves like cancellation")
}

// 4. Missing job: converted booking whose job is gone surfaces for reconciliation.
do {
    let rows = NativeBookingAttention.select(requests: [booked(status: "cancelled")], jobs: [])
    expect(rows.count == 1 && rows[0].kind == .missingJob, "deleted linked job becomes missing-job")
    expect(rows[0].jobID == "jbk_bk1", "missing row keeps the expected job id")
    let bookedRows = NativeBookingAttention.select(requests: [booked()], jobs: [])
    expect(bookedRows.count == 1 && bookedRows[0].kind == .missingJob,
           "converted booked row with no job is missing, not silent")
}

// 5. Portal follow-up states: unhandled surfaces, handled hides, dangling jobRef is missing.
do {
    let rows = NativeBookingAttention.select(requests: [change()], jobs: [job(id: "j1")])
    expect(rows.count == 1 && rows[0].kind == .portalChange, "portal change surfaces while unhandled")
    expect(rows[0].jobID == "j1", "portal row carries jobRef")
    expect(rows[0].note?.contains("Tuesday works better") == true, "templated details carried as note")
    expect(NativeBookingAttention.select(
        requests: [change(handledAt: "2026-08-10T13:00:00.000Z")], jobs: []).isEmpty,
        "handled portal change hides")
    let dangling = NativeBookingAttention.select(requests: [change()], jobs: [])
    expect(dangling.count == 1 && dangling[0].kind == .missingJob,
           "portal change with deleted job surfaces as missing-job")
}

// 6. Unconverted-active inspection (D-B3-1): new and unconverted slot rows surface;
//    converted quiet states and unknown statuses stay silent.
do {
    let rows = NativeBookingAttention.select(
        requests: [freeNew(), booked(id: "bk_u", status: "booked", stamped: nil),
                   booked(id: "bk_c", status: "confirmed", stamped: nil)], jobs: [])
    expect(rows.count == 3 && rows.allSatisfy({ $0.kind == .unconvertedActive }),
           "unconverted new/booked/confirmed surface for inspection")
    let quiet = NativeBookingAttention.select(requests: [
        booked(id: "bk_q", status: "booked", stamped: "jbk_bk_q"),
        decodeRequest("""
        {"id":"bk_x","status":"weird_future","kind":"booked","name":"Z","phone":"","email":"",
         "address":"","details":"d","preferredTiming":"","createdAt":"2026-08-10T12:00:00.000Z",
         "mystery":"kept"}
        """),
    ], jobs: [job(id: "jbk_bk_q")])
    expect(quiet.isEmpty, "converted quiet states and unknown statuses stay silent")
}

// 7. Sort: reschedule, portal change, cancelled, missing, unconverted-active; then slot date.
do {
    let rows = NativeBookingAttention.select(requests: [
        booked(id: "c1", status: "cancelled", stamped: "jbk_c1"),
        change(),
        booked(id: "r1", status: "reschedule_requested", stamped: "jbk_r1"),
        booked(id: "m1", status: "booked"),
        freeNew(id: "u1"),
    ], jobs: [job(id: "jbk_c1"), job(id: "jbk_r1"), job(id: "j1")])
    expect(rows.map(\.kind) == [.rescheduleRequested, .portalChange, .cancelled,
                                .missingJob, .unconvertedActive],
           "attention ranks actionable before inspection")
}

// 8. Handled dismissal plan: stamps once, then no-ops (caller must not write on nil).
do {
    let stamped = NativeBookingAttention.stampedHandled(change(), nowISO: "2026-08-10T13:00:00.000Z")
    expect(stamped?.handledAt == "2026-08-10T13:00:00.000Z", "dismissal stamps handledAt")
    expect(stamped?.status == "portal_change_requested", "dismissal never rewrites lifecycle")
    let again = NativeBookingAttention.stampedHandled(
        change(handledAt: "2026-08-10T13:00:00.000Z"), nowISO: "2026-08-10T14:00:00.000Z")
    expect(again == nil, "already-handled dismissal is a no-op")
}

// 9. Referenced server state rides along: history and slot survive selection untouched.
do {
    var request = booked(status: "reschedule_requested")
    request.history = [decodeHistory(actor: "customer", event: "request_reschedule", note: "n")]
    let rows = NativeBookingAttention.select(requests: [request], jobs: [job()])
    expect(rows[0].request.history?.count == 1, "server history preserved on the row")
    expect(rows[0].request.slot?.date == "2026-08-12", "slot preserved on the row")
}

// 10. A duplicated job id (corrupt/duplicate row) must not trap Today's render;
// the first job wins, matching the schedule-key dedupe.
do {
    let first = job()
    let second = job(date: "2026-09-01")
    let rows = NativeBookingAttention.select(
        requests: [booked(status: "reschedule_requested")], jobs: [first, second])
    expect(rows.count == 1 && rows[0].jobID == "jbk_bk1", "duplicate job id selects without trapping")
}

if failures == 0 { print("PASS: native booking attention tests") }
else { print("\(failures) booking attention test(s) failed"); exit(1) }
