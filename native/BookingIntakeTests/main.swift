import Foundation

// Task 8.02 (B3, P3): pure intake fixtures for NativeBookingIntake.
// Oracle: utils/storage/bookingConversion.ts + __tests__/bookingConversion.test.ts.
// Decisions: D-B3-1…D-B3-4 in docs/native-phase-8-contract-decisions.md.

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

private func decodeCustomer(_ json: String) -> Canonical.Customer {
    try! decoder.decode(Canonical.Customer.self, from: Data(json.utf8))
}

private func decodeSettings() -> Canonical.Settings {
    try! decoder.decode(Canonical.Settings.self, from: Data("""
    {"businessName":"B","contactName":"C","phone":"p","email":"e","address":"a",
     "trade":"plumbing","laborRate":95,"materialMarkup":25,"overheadPercent":10,
     "marginPercent":30,"minimumJobFee":0,"travelFeePerMile":0,"emergencyMultiplier":1,
     "rules":[],"paymentNotes":"","provider":"none"}
    """.utf8))
}

private func encoded(_ value: some Encodable) -> [String: Canonical.JSONValue] {
    try! decoder.decode([String: Canonical.JSONValue].self, from: encoder.encode(value))
}

private func wireEqual(_ lhs: [some Encodable], _ rhs: [some Encodable]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy {
        (try? encoder.encode($0)) == (try? encoder.encode($1))
    }
}

private let settings = decodeSettings()
private let fixedNow = "2026-09-20T12:00:00.000Z"

private func idFactory(_ ids: String...) -> () -> String {
    var queue = ids
    var counter = 0
    return {
        counter += 1
        if !queue.isEmpty { return queue.removeFirst() }
        return "c_test_\(counter)"
    }
}

private let newRequestJSON = """
{"id":"bk1700000000000_a1b2c3","status":"new","name":"Dana Rivers",
 "phone":"555-0142","email":"dana@example.com","address":"12 Elm St",
 "details":"Water heater is leaking","preferredTiming":"Weekday mornings",
 "createdAt":"2026-08-04T15:00:00.000Z"}
"""

private let slotJSON = """
{"date":"2026-08-12","start":"09:00","end":"10:00","timeZone":"America/Chicago",
 "startUtc":"2026-08-12T14:00:00.000Z","endUtc":"2026-08-12T15:00:00.000Z"}
"""

private func bookedRequest(status: String = "booked", id: String = "bk1700000001000_d4e5f6") -> Canonical.BookingRequest {
    decodeRequest("""
    {"id":"\(id)","status":"\(status)","kind":"booked","name":"Sam Ortiz",
     "phone":"555-0177","email":"sam@example.com","address":"9 Oak Ave",
     "details":"Panel inspection","preferredTiming":"",
     "createdAt":"2026-08-07T15:00:00.000Z",
     "slot":\(slotJSON),
     "manageToken":"\(String(repeating: "m", count: 48))",
     "history":[{"at":"2026-08-07T15:00:00.000Z","actor":"customer","event":"booked"}]}
    """)
}

// 1. Free-text `new` converts to customer + unscheduled lead with exact defaults/provenance.
do {
    let plan = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_dana"), nowISO: { fixedNow })
    expect(plan.changed, "new request produces a plan")
    expect(plan.customers.count == 1 && plan.customers[0].id == "c_dana", "customer created with injected id")
    let customer = plan.customers[0]
    expect(customer.name == "Dana Rivers" && customer.email == "dana@example.com"
           && customer.phone == "555-0142" && customer.address == "12 Elm St",
           "customer carries full contact info")
    expect(plan.jobs.count == 1, "one lead job created")
    let job = plan.jobs[0]
    expect(job.id == "jbk_bk1700000000000_a1b2c3", "deterministic job id jbk_<requestId>")
    expect(job.status == "lead" && job.title == "Quote request", "free-text becomes unscheduled lead")
    expect(job.customerId == "c_dana" && job.customerName == "Dana Rivers", "lead links the new customer")
    expect(job.description == "Water heater is leaking" && job.address == "12 Elm St", "description/address carried")
    expect(job.scheduledDate == nil && job.scheduledStartTime == nil, "free-text lead stays unscheduled")
    expect(job.notes == "Preferred timing: Weekday mornings\nCame in via booking link 2026-08-04",
           "exact RN provenance note")
    expect(job.createdAt == "2026-08-04", "lead createdAt is the request date")
    expect(job.estimateTotal == 0 && job.laborHours == 0 && job.materials.isEmpty, "zeroed pricing base")
    expect(job.laborRate == 95 && job.materialMarkup == 25
           && job.overhead == 10 && job.margin == 30, "settings pricing parity with fallbacks")
    let stamped = plan.requests[0]
    expect(stamped.status == "converted", "new flips to converted")
    expect(stamped.convertedJobId == job.id && stamped.convertedCustomerId == "c_dana",
           "conversion ids stamped")
    expect(plan.convertedRequestIDs == ["bk1700000000000_a1b2c3"], "plan names the converted request")
    expect(plan.createdJobIDs == [job.id] && plan.createdCustomerIDs == ["c_dana"],
           "plan names created records")
    expect(plan.drafts.count == 3, "drafts cover customer + job + request")
}

// 2. Repeat/no-op: a second run over plan output changes nothing and enqueues nothing.
do {
    let first = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_dana"), nowISO: { fixedNow })
    let second = NativeBookingIntake.plan(
        requests: first.requests, jobs: first.jobs, customers: first.customers,
        settings: settings, makeCustomerID: idFactory("c_other"), nowISO: { fixedNow })
    expect(!second.changed, "rerun is a no-op")
    expect(second.drafts.isEmpty, "no-op enqueues nothing")
    expect(wireEqual(second.requests, first.requests) && wireEqual(second.jobs, first.jobs)
           && wireEqual(second.customers, first.customers), "no-op returns identical collections")
    expect(!NativeBookingIntake.needsIntake(second.requests), "gating helper clears after conversion")
}

// 3. Existing job (crash between saves): no duplicate lead, request still stamped.
do {
    let first = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_dana"), nowISO: { fixedNow })
    let rerun = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: first.jobs, customers: first.customers,
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(rerun.jobs.count == 1, "crash recovery creates no duplicate job")
    expect(!rerun.jobsChanged, "job collection untouched on recovery")
    expect(rerun.requests[0].status == "converted"
           && rerun.requests[0].convertedJobId == "jbk_bk1700000000000_a1b2c3",
           "recovery still stamps the request")
    expect(rerun.createdCustomerIDs.isEmpty, "recovery creates no duplicate customer")
}

// 4. Already-stamped slot booking is untouched on replay (never overwrites the job).
do {
    var converted = bookedRequest()
    converted.convertedJobId = "jbk_bk1700000001000_d4e5f6"
    converted.convertedCustomerId = "c_sam"
    let existingJob = decodeJob("""
    {"id":"jbk_bk1700000001000_d4e5f6","customerId":"c_sam","customerName":"Sam Ortiz",
     "title":"Booked appointment","description":"edited by owner","status":"scheduled",
     "scheduledDate":"2026-08-12","scheduledStartTime":"09:00","scheduledEndTime":"10:00",
     "address":"9 Oak Ave","estimateTotal":100,"laborHours":2,"laborRate":95,
     "materials":[],"materialMarkup":25,"overhead":10,"margin":30,"notes":"owner note",
     "createdAt":"2026-08-07"}
    """)
    let plan = NativeBookingIntake.plan(
        requests: [converted], jobs: [existingJob],
        customers: [decodeCustomer("""
        {"id":"c_sam","name":"Sam Ortiz","email":"sam@example.com","phone":"555-0177",
         "address":"9 Oak Ave","notes":""}
        """)],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(!plan.changed, "stamped slot booking replays as no-op")
    expect(plan.jobs[0].description == "edited by owner"
           && plan.jobs[0].status == "scheduled", "existing job never overwritten")
    expect(plan.untouchedRequestIDs == ["bk1700000001000_d4e5f6"], "plan names the untouched request")
}

// 5. Slot lead: booked becomes a lead WITH the slot schedule, status preserved.
do {
    let plan = NativeBookingIntake.plan(
        requests: [bookedRequest()], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_sam"), nowISO: { fixedNow })
    let job = plan.jobs[0]
    expect(job.id == "jbk_bk1700000001000_d4e5f6", "slot job keeps deterministic id")
    expect(job.status == "lead" && job.title == "Booked appointment", "slot booking enters as lead")
    expect(job.scheduledDate == "2026-08-12" && job.scheduledStartTime == "09:00"
           && job.scheduledEndTime == "10:00", "slot schedule lands on the lead exactly")
    expect(job.notes.contains("Booked online for 2026-08-12 09:00"), "booked line in provenance")
    let stamped = plan.requests[0]
    expect(stamped.status == "booked", "slot status preserved (manage page keeps reading it)")
    expect(stamped.convertedJobId == job.id, "convertedJobId is the done marker")
    expect(stamped.history?.count == 1 && stamped.history?[0].event == "booked",
           "server history survives conversion (D-B3-4)")
    expect(stamped.manageToken?.count == 48, "manage capability untouched")
}

// 6. Confirmed-before-conversion (D-B3-1 intentional difference): confirmed converts, status kept.
do {
    let plan = NativeBookingIntake.plan(
        requests: [bookedRequest(status: "confirmed")], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_sam"), nowISO: { fixedNow })
    expect(plan.changed && plan.jobs.count == 1, "confirmed slot booking converts on first pass")
    expect(plan.requests[0].status == "confirmed", "confirmed status preserved, not flipped")
    expect(plan.jobs[0].scheduledDate == "2026-08-12", "confirmed slot schedule still lands on the lead")
}

// 7. Reschedule-requested-before-conversion (D-B3-1): converts, status kept.
do {
    let plan = NativeBookingIntake.plan(
        requests: [bookedRequest(status: "reschedule_requested", id: "bk_rr_1")], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_sam"), nowISO: { fixedNow })
    expect(plan.changed, "reschedule_requested converts on first pass")
    expect(plan.requests[0].status == "reschedule_requested", "reschedule status preserved")
    expect(plan.jobs[0].id == "jbk_bk_rr_1", "deterministic id for the reschedule row")
}

// 8. Portal follow-up `new` converts and retains sourceCustomerId linkage.
do {
    let existing = decodeCustomer("""
    {"id":"c_dana","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142",
     "address":"12 Elm St","notes":""}
    """)
    let followup = decodeRequest("""
    {"id":"bkpr_followup","status":"new","name":"Dana Rivers",
     "phone":"555-0142","email":"dana@example.com","address":"12 Elm St",
     "details":"Fence needs painting too","preferredTiming":"",
     "createdAt":"2026-08-10T12:00:00.000Z","source":"portal","sourceCustomerId":"c_dana"}
    """)
    let plan = NativeBookingIntake.plan(
        requests: [followup], jobs: [], customers: [existing],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(plan.changed, "portal follow-up converts")
    expect(!plan.customersChanged && plan.customers.count == 1, "existing customer linked, no new record")
    expect(plan.jobs[0].customerId == "c_dana", "lead links the portal customer")
    expect(plan.jobs[0].notes.contains("Came in via customer portal")
           && !plan.jobs[0].notes.contains("booking link"), "portal provenance line")
    expect(plan.requests[0].convertedCustomerId == "c_dana", "conversion retains sourceCustomerId")
}

// 9. Deleted source customer: dangling id falls back to the name-keyed upsert.
do {
    var orphan = decodeRequest(newRequestJSON)
    orphan.sourceCustomerId = "c_gone"
    let plan = NativeBookingIntake.plan(
        requests: [orphan], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_fallback"), nowISO: { fixedNow })
    expect(plan.changed && plan.customers.count == 1, "dangling id falls back to upsert")
    expect(plan.customers[0].name == "Dana Rivers", "fallback matches by normalized name")
    expect(plan.jobs[0].customerId == "c_fallback", "lead follows the fallback customer")
}

// 10. Malformed requests stay for inspection: blank name, empty id.
do {
    let blank = decodeRequest("""
    {"id":"bk_blank","status":"new","name":"   ","phone":"","email":"","address":"",
     "details":"x","preferredTiming":"","createdAt":"2026-08-04T15:00:00.000Z"}
    """)
    var emptyID = decodeRequest(newRequestJSON)
    emptyID.id = ""
    let plan = NativeBookingIntake.plan(
        requests: [blank, emptyID], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_x", "c_y"), nowISO: { fixedNow })
    expect(!plan.changed, "malformed rows never convert")
    expect(plan.jobs.isEmpty && plan.customers.isEmpty, "no records invented for malformed rows")
    expect(plan.requests[0].status == "new", "blank-name row left for inspection")
}

// 11. Portal-change inertness + unknown-status preservation (incl. unknown fields).
do {
    let change = decodeRequest("""
    {"id":"bkpr_change","status":"portal_change_requested","name":"Dana Rivers",
     "phone":"","email":"","address":"","details":"Reschedule requested for \\"Swap\\" (2026-08-12)",
     "preferredTiming":"","createdAt":"2026-08-10T12:00:00.000Z","source":"portal",
     "sourceCustomerId":"c_dana","jobRef":"j1","portalKind":"reschedule"}
    """)
    let unknown = decodeRequest("""
    {"id":"bk_future","status":"escalated","kind":"booked","name":"Zed",
     "phone":"","email":"","address":"","details":"future flow","preferredTiming":"",
     "createdAt":"2026-08-10T12:00:00.000Z","futureField":"keep-me"}
    """)
    let plan = NativeBookingIntake.plan(
        requests: [change, unknown], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_x"), nowISO: { fixedNow })
    expect(!plan.changed, "portal changes and unknown statuses never convert")
    expect(plan.requests[0].status == "portal_change_requested", "portal change stays intact")
    expect(plan.requests[1].status == "escalated", "unknown status stays intact")
    expect(encoded(plan.requests[1])["futureField"] == .string("keep-me"),
           "unknown server fields preserved through intake")
    expect(!NativeBookingIntake.needsIntake(plan.requests), "inert rows do not trip the gate")
}

// 12. Backfill blanks only — never clobbers existing contact data.
do {
    let existing = decodeCustomer("""
    {"id":"c1","name":"dana rivers","email":"keep@example.com","phone":"","address":"",
     "notes":"","mystery":"preserved"}
    """)
    let plan = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: [], customers: [existing],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(plan.customers.count == 1 && plan.jobs[0].customerId == "c1", "name match joins, no duplicate")
    expect(plan.customers[0].email == "keep@example.com", "existing email never clobbered")
    expect(plan.customers[0].phone == "555-0142", "blank phone backfilled")
    expect(encoded(plan.customers[0])["mystery"] == .string("preserved"),
           "unknown customer fields survive backfill")
}

// 13. L3 limitation pin: deterministic job id, time-based customer ids.
// Two devices converting the same request with different clocks create one
// job id but two customer records — surfaced via duplicate merge, by design.
do {
    let planA = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: [], customers: [],
        settings: settings, makeCustomerID: { "c_deviceA_1" }, nowISO: { fixedNow })
    let planB = NativeBookingIntake.plan(
        requests: [decodeRequest(newRequestJSON)], jobs: [], customers: [],
        settings: settings, makeCustomerID: { "c_deviceB_1" }, nowISO: { fixedNow })
    expect(planA.jobs[0].id == planB.jobs[0].id
           && planA.jobs[0].id == "jbk_bk1700000000000_a1b2c3",
           "job identity converges across devices (L3 pin)")
    expect(planA.customers[0].id != planB.customers[0].id,
           "customer creation stays time-based per device (L3 limitation retained)")
}

if failures == 0 { print("PASS: native booking intake tests") }
else { print("\(failures) booking intake test(s) failed"); exit(1) }
