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

// 14. Phase 27 lead source (spec 2026-10-02-lead-source-design.md §1/§3):
// the link's `?src=` tag (or "booking_link") is the first touch for a created
// customer or a matched customer whose source is blank; portal requests never
// tag one.
do {
    func request(leadSource: String?, extra: String = "") -> Canonical.BookingRequest {
        var fields = """
        {"id":"bk_src","status":"new","name":"Dana Rivers",
         "phone":"555-0142","email":"dana@example.com","address":"12 Elm St",
         "details":"Leak","preferredTiming":"","createdAt":"2026-08-04T15:00:00.000Z"\(extra)
        """
        if let leadSource { fields += ",\"leadSource\":\"\(leadSource)\"" }
        return decodeRequest(fields + "}")
    }
    func createdSource(_ request: Canonical.BookingRequest) -> String? {
        let plan = NativeBookingIntake.plan(
            requests: [request], jobs: [], customers: [],
            settings: settings, makeCustomerID: idFactory("c_new"), nowISO: { fixedNow })
        expect(plan.createdCustomerIDs == ["c_new"], "a customer is created for \(request.leadSource ?? "no tag")")
        return plan.customers.first?.leadSource
    }

    expect(request(leadSource: "nextdoor").leadSource == "nextdoor", "the request decodes its tag")
    expect(createdSource(request(leadSource: "nextdoor")) == "nextdoor", "a ?src= preset tags the new customer")
    expect(createdSource(request(leadSource: nil)) == "booking_link", "no tag defaults to the booking link")
    expect(createdSource(request(leadSource: "Home Show")) == "Home Show", "a custom tag is kept verbatim")
    expect(createdSource(request(leadSource: "Google Ads")) == "google", "a tag alias normalizes to its preset")
    expect(createdSource(request(leadSource: "   ")) == "booking_link", "a blank tag falls back to the booking link")

    let created = NativeBookingIntake.plan(
        requests: [request(leadSource: "yelp")], jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_new"), nowISO: { fixedNow })
    let customerDraft = created.drafts.first { $0.table == "customers" }
    guard case let .object(draftFields)? = customerDraft?.payload else {
        expect(false, "created customer draft present"); exit(1)
    }
    expect(draftFields["leadSource"] == .string("yelp"), "the created customer's upsert carries the source")

    // Matched customer with a blank source: filled, and the match counts as a change.
    let blankMatch = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142",
     "address":"12 Elm St","notes":""}
    """)
    let filled = NativeBookingIntake.plan(
        requests: [request(leadSource: "nextdoor")], jobs: [], customers: [blankMatch],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(filled.customers.count == 1 && filled.customers[0].leadSource == "nextdoor",
           "a matched customer's blank source is filled")
    expect(filled.customersChanged && filled.createdCustomerIDs.isEmpty
           && filled.drafts.contains { $0.table == "customers" && $0.recordId == "c1" },
           "the source-only fill is a published customer change")
    let defaultFill = NativeBookingIntake.plan(
        requests: [request(leadSource: nil)], jobs: [], customers: [blankMatch],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(defaultFill.customers[0].leadSource == "booking_link", "an untagged booking fills a blank source with the booking link")

    // Matched customer with a source: first touch wins, nothing is published for it.
    let sourced = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142",
     "address":"12 Elm St","notes":"","leadSource":"referral"}
    """)
    let kept = NativeBookingIntake.plan(
        requests: [request(leadSource: "nextdoor")], jobs: [], customers: [sourced],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(kept.customers[0].leadSource == "referral", "a matched customer's source is never replaced")
    expect(!kept.customersChanged && !kept.drafts.contains { $0.table == "customers" },
           "an unchanged matched customer is not published")

    // Portal: an existing customer is linked unchanged; a dangling id creates
    // a customer with no source.
    let portalLinked = NativeBookingIntake.plan(
        requests: [request(leadSource: nil, extra: #","source":"portal","sourceCustomerId":"c1""#)],
        jobs: [], customers: [blankMatch],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(portalLinked.customers[0].leadSource == nil && !portalLinked.customersChanged,
           "a portal request leaves its customer's source alone")
    let portalDangling = NativeBookingIntake.plan(
        requests: [request(leadSource: nil, extra: #","source":"portal","sourceCustomerId":"c_gone""#)],
        jobs: [], customers: [],
        settings: settings, makeCustomerID: idFactory("c_portal"), nowISO: { fixedNow })
    expect(portalDangling.createdCustomerIDs == ["c_portal"] && portalDangling.customers[0].leadSource == nil,
           "a portal follow-up with a dangling id creates a customer without a source")
    let portalBlankMatch = NativeBookingIntake.plan(
        requests: [request(leadSource: nil, extra: #","source":"portal","sourceCustomerId":"c_gone""#)],
        jobs: [], customers: [blankMatch],
        settings: settings, makeCustomerID: idFactory("c_dup"), nowISO: { fixedNow })
    expect(portalBlankMatch.customers[0].leadSource == nil && !portalBlankMatch.customersChanged,
           "a portal fallback match never fills a blank source")

    // upsertCustomer's default keeps pre-Phase-27 callers source-free.
    let bare = NativeBookingIntake.upsertCustomer(
        in: [], name: "Bare", email: "", phone: "", address: "",
        makeCustomerID: { "c_bare" }, nowISO: { fixedNow })
    expect(bare.customer?.leadSource == nil && encoded(bare.customer!)["leadSource"] == nil,
           "upsert without a source writes no key")
}

// 15. Phase 34 referrals (spec 2026-10-03-referral-program-design.md §5.3):
// a code from `?r=` makes the booker a referral of the code's owner (first
// touch), self-referral and portal codes are ignored, and an unknown code is a
// referral with no referrer.
do {
    let samCode = "0123456789abcdef"
    let sam = decodeCustomer("""
    {"id":"c_sam","name":"Sam Ortiz","email":"sam@example.com","phone":"(602) 555-0177",
     "address":"9 Oak Ave","notes":"","leadSource":"google","referralCode":"\(samCode)"}
    """)
    func request(name: String = "Dana Rivers", email: String = "dana@example.com", phone: String = "555-0142",
                 code: String?, extra: String = "", status: String = "new") -> Canonical.BookingRequest {
        var fields = """
        {"id":"bk_ref","status":"\(status)","name":"\(name)",
         "phone":"\(phone)","email":"\(email)","address":"12 Elm St",
         "details":"Leak","preferredTiming":"","createdAt":"2026-08-04T15:00:00.000Z"\(extra)
        """
        if let code { fields += ",\"referralCode\":\"\(code)\"" }
        return decodeRequest(fields + "}")
    }
    func plan(_ request: Canonical.BookingRequest, _ customers: [Canonical.Customer]) -> NativeBookingIntake.Plan {
        NativeBookingIntake.plan(requests: [request], jobs: [], customers: customers,
                                 settings: settings, makeCustomerID: idFactory("c_new"), nowISO: { fixedNow })
    }

    expect(request(code: samCode).referralCode == samCode, "the request decodes its referral code")

    // New customer via a code.
    let created = plan(request(code: samCode, extra: #","leadSource":"nextdoor""#), [sam])
    let fresh = created.customers.first { $0.id == "c_new" }
    expect(fresh?.leadSource == "referral" && fresh?.referredByCustomerId == "c_sam",
           "a new customer via a code is a referral of the code's owner (a code wins over ?src=)")
    let draft = created.drafts.first { $0.table == "customers" && $0.recordId == "c_new" }
    guard case let .object(draftFields)? = draft?.payload else { expect(false, "created customer draft present"); exit(1) }
    expect(draftFields["referredByCustomerId"] == .string("c_sam") && draftFields["leadSource"] == .string("referral"),
           "the created customer's upsert carries the referral")
    expect(created.jobs.first.map { !$0.notes.contains("Sam") && !$0.title.contains("Sam") } == true,
           "no referrer name goes into the lead job")

    // Matched customer with a blank source: both fill.
    let blank = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"","phone":"","address":"12 Elm St","notes":""}
    """)
    let filled = plan(request(code: samCode), [sam, blank])
    let filledDana = filled.customers.first { $0.id == "c1" }
    expect(filledDana?.leadSource == "referral" && filledDana?.referredByCustomerId == "c_sam",
           "a matched customer with a blank source becomes a referral of Sam")
    expect(filled.drafts.contains { $0.table == "customers" && $0.recordId == "c1" }, "the fill is published")

    // Matched customer with another source: unchanged (first touch).
    let google = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142","address":"12 Elm St","notes":"","leadSource":"yelp"}
    """)
    let kept = plan(request(code: samCode), [sam, google])
    let keptDana = kept.customers.first { $0.id == "c1" }
    expect(keptDana?.leadSource == "yelp" && keptDana?.referredByCustomerId == nil,
           "a matched customer with another source keeps both fields")
    expect(!kept.drafts.contains { $0.table == "customers" }, "nothing is published for an unchanged match")

    // Matched referral with no referrer: filled.
    let referralNoReferrer = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142","address":"12 Elm St","notes":"","leadSource":"Word of mouth"}
    """)
    let completed = plan(request(code: samCode), [sam, referralNoReferrer])
    expect(completed.customers.first { $0.id == "c1" }?.referredByCustomerId == "c_sam",
           "a matched referral with no referrer gets the referrer")
    // Matched referral that already has a referrer: first touch wins.
    let alreadyReferred = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142","address":"12 Elm St","notes":"","leadSource":"referral","referredByCustomerId":"c_other"}
    """)
    expect(plan(request(code: samCode), [sam, alreadyReferred]).customers.first { $0.id == "c1" }?.referredByCustomerId == "c_other",
           "an existing referrer is never replaced")

    // Self-referral: by name, by email, by phone.
    let byName = plan(request(name: "  sam ortiz", email: "", phone: "", code: samCode), [sam])
    expect(byName.customers.count == 1 && byName.customers[0].referredByCustomerId == nil
           && byName.customers[0].leadSource == "google", "self-referral by name changes nothing")
    let byEmail = plan(request(name: "S Ortiz", email: "SAM@example.com", phone: "", code: samCode), [sam])
    let emailCustomer = byEmail.customers.first { $0.id == "c_new" }
    expect(emailCustomer?.leadSource == "booking_link" && emailCustomer?.referredByCustomerId == nil,
           "self-referral by email is no referral (Phase 27 default)")
    let byPhone = plan(request(name: "S Ortiz", email: "", phone: "602.555.0177", code: samCode), [sam])
    expect(byPhone.customers.first { $0.id == "c_new" }?.referredByCustomerId == nil, "self-referral by phone is no referral")

    // Unknown code: a referral with no referrer.
    let unknown = plan(request(code: "zzzzzzzzzzzzzzzz"), [sam])
    let unknownCustomer = unknown.customers.first { $0.id == "c_new" }
    expect(unknownCustomer?.leadSource == "referral" && unknownCustomer?.referredByCustomerId == nil,
           "an unknown code is a referral with no referrer")
    // A code the device rejects is no code.
    let malformed = plan(request(code: "ILOU456789abcdef"), [sam])
    expect(malformed.customers.first { $0.id == "c_new" }?.leadSource == "booking_link", "a malformed code is no code")

    // A portal request carrying a code: ignored, even on the dangling-id fallback.
    let portal = plan(request(code: samCode, extra: #","source":"portal","sourceCustomerId":"c_gone""#), [sam])
    let portalCustomer = portal.customers.first { $0.id == "c_new" }
    expect(portalCustomer?.leadSource == nil && portalCustomer?.referredByCustomerId == nil, "a portal request's code is ignored")

    // A slot booking carries the code too.
    let slot = plan(request(code: samCode, extra: ",\"kind\":\"booked\",\"slot\":\(slotJSON)", status: "booked"), [sam])
    expect(slot.createdJobIDs == ["jbk_bk_ref"] && slot.customers.first { $0.id == "c_new" }?.referredByCustomerId == "c_sam",
           "a slot booking via a code records the referral")

    // upsertCustomer: a referrer is set only with a referral source, never on itself.
    let notReferral = NativeBookingIntake.upsertCustomer(
        in: [], name: "X", email: "", phone: "", address: "", leadSource: "google", referredByCustomerId: "c_sam",
        makeCustomerID: { "c_x" }, nowISO: { fixedNow })
    expect(notReferral.customer?.referredByCustomerId == nil, "upsert drops a referrer without a referral source")
    let selfRef = NativeBookingIntake.upsertCustomer(
        in: [], name: "X", email: "", phone: "", address: "", leadSource: "referral", referredByCustomerId: "c_x",
        makeCustomerID: { "c_x" }, nowISO: { fixedNow })
    expect(selfRef.customer?.referredByCustomerId == nil, "upsert never makes a customer its own referrer")
}

// 15. Phase 33 campaign code (spec 2026-10-03-campaigns-tags-design.md §9.2):
// `?c=` resolves by exact match among the owner's campaigns. A resolved code
// stamps the lead job's `campaignId`; a customer the booking CREATES gets the
// `campaign` source; a matched past customer's source is never filled; an
// unresolvable or ambiguous code and portal requests change nothing.
do {
    func request(code: String?, src: String? = nil, extra: String = "") -> Canonical.BookingRequest {
        var fields = """
        {"id":"bk_cmp","status":"new","name":"Dana Rivers",
         "phone":"555-0142","email":"dana@example.com","address":"12 Elm St",
         "details":"Tune-up","preferredTiming":"","createdAt":"2026-10-04T15:00:00.000Z"\(extra)
        """
        if let code { fields += ",\"campaignCode\":\"\(code)\"" }
        if let src { fields += ",\"leadSource\":\"\(src)\"" }
        return decodeRequest(fields + "}")
    }
    let campaigns = [
        Canonical.Campaign(id: "cmp_fall", name: "Fall", code: "04hmasw9nf6yy41j", createdAt: "2026-10-01T00:00:00.000Z"),
        Canonical.Campaign(id: "cmp_dup_a", name: "A", code: "dddddddddddddddd", createdAt: "2026-10-01T00:00:00.000Z"),
        Canonical.Campaign(id: "cmp_dup_b", name: "B", code: "dddddddddddddddd", createdAt: "2026-10-01T00:00:00.000Z"),
    ]
    func plan(_ request: Canonical.BookingRequest, customers: [Canonical.Customer] = []) -> NativeBookingIntake.Plan {
        NativeBookingIntake.plan(requests: [request], jobs: [], customers: customers, campaigns: campaigns,
                                 settings: settings, makeCustomerID: idFactory("c_new"), nowISO: { fixedNow })
    }
    func lead(_ plan: NativeBookingIntake.Plan) -> Canonical.Job? { plan.jobs.first { $0.id == "jbk_bk_cmp" } }

    expect(request(code: "04hmasw9nf6yy41j").campaignCode == "04hmasw9nf6yy41j", "the request decodes its code")
    expect(NativeBookingIntake.campaignDecision(for: request(code: "04hmasw9nf6yy41j"), campaigns: campaigns) == "cmp_fall",
           "an exact code resolves to its campaign")
    expect(NativeBookingIntake.campaignDecision(for: request(code: " 04HMASW9NF6YY41J "), campaigns: campaigns) == "cmp_fall",
           "the code is matched lowercased and trimmed, as the Worker stores it")
    expect(NativeBookingIntake.campaignDecision(for: request(code: "zzzzzzzzzzzzzzzz"), campaigns: campaigns) == nil,
           "an unknown code resolves to none")
    expect(NativeBookingIntake.campaignDecision(for: request(code: "dddddddddddddddd"), campaigns: campaigns) == nil,
           "a code shared by two campaigns resolves to none")
    expect(NativeBookingIntake.campaignDecision(for: request(code: ""), campaigns: campaigns) == nil, "an empty code is none")

    // Creates a customer: the lead job is stamped and the customer's source is `campaign` (beats ?src=).
    let created = plan(request(code: "04hmasw9nf6yy41j", src: "nextdoor"))
    expect(lead(created)?.campaignId == "cmp_fall", "a resolved code stamps the lead job's campaignId")
    expect(created.createdCustomerIDs == ["c_new"] && created.customers.first?.leadSource == "campaign",
           "a customer created through a campaign link gets the campaign source")
    let jobDraft = created.drafts.first { $0.table == "jobs" }
    guard case let .object(jobFields)? = jobDraft?.payload else { expect(false, "lead job draft present"); exit(1) }
    expect(jobFields["campaignId"] == .string("cmp_fall"), "the queued lead job carries campaignId")

    // Matches an existing customer: the job is stamped, the source is never filled.
    let blank = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142","address":"12 Elm St","notes":""}
    """)
    let matched = plan(request(code: "04hmasw9nf6yy41j"), customers: [blank])
    expect(lead(matched)?.campaignId == "cmp_fall", "a matched customer's lead job is stamped")
    expect(matched.customers[0].leadSource == nil && !matched.customersChanged
           && !matched.drafts.contains { $0.table == "customers" },
           "a matched past customer's blank source is never filled by a campaign")
    let sourced = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"dana@example.com","phone":"555-0142","address":"12 Elm St","notes":"","leadSource":"yelp"}
    """)
    expect(plan(request(code: "04hmasw9nf6yy41j"), customers: [sourced]).customers[0].leadSource == "yelp",
           "a matched customer's source is unchanged")
    let partial = decodeCustomer("""
    {"id":"c1","name":"Dana Rivers","email":"","phone":"555-0142","address":"","notes":""}
    """)
    let backfilled = plan(request(code: "04hmasw9nf6yy41j"), customers: [partial])
    expect(backfilled.customers[0].email == "dana@example.com" && backfilled.customers[0].leadSource == nil,
           "blank contact fields still fill; the source does not")

    // Unresolvable code: Phase 27 rules, no campaignId.
    let unknown = plan(request(code: "zzzzzzzzzzzzzzzz"))
    expect(lead(unknown)?.campaignId == nil && unknown.customers.first?.leadSource == "booking_link",
           "an unresolvable code changes nothing (booking link default)")
    let unknownMatch = plan(request(code: "zzzzzzzzzzzzzzzz"), customers: [blank])
    expect(unknownMatch.customers[0].leadSource == "booking_link", "an unresolvable code keeps the Phase 27 blank fill")
    let none = plan(request(code: nil, src: "google"))
    expect(lead(none)?.campaignId == nil && (encoded(lead(none)!))["campaignId"] == nil && none.customers.first?.leadSource == "google",
           "no code: no campaignId key, Phase 27 source")

    // Portal: unchanged even with a code.
    let portal = plan(request(code: "04hmasw9nf6yy41j", extra: #","source":"portal","sourceCustomerId":"c1""#), customers: [blank])
    expect(lead(portal)?.campaignId == nil && portal.customers[0].leadSource == nil && !portal.customersChanged,
           "a portal request never takes a campaign")

    // Without campaigns (pre-Phase-33 callers) a code is inert.
    let noCampaigns = NativeBookingIntake.plan(requests: [request(code: "04hmasw9nf6yy41j")], jobs: [], customers: [],
                                               settings: settings, makeCustomerID: idFactory("c_new"), nowISO: { fixedNow })
    expect(lead(noCampaigns)?.campaignId == nil, "the default campaigns list resolves nothing")
}

if failures == 0 { print("PASS: native booking intake tests") }
else { print("\(failures) booking intake test(s) failed"); exit(1) }
