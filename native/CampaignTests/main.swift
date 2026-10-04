import Foundation

// Phase 33 (past-customer campaigns) host tests: segments and the shared
// service history (`NativeCampaignSegments`, `NativeServiceHistory`), merge
// fields, rendering and compliance text (`NativeCampaignMessage`), AI drafting
// (`NativeCampaignDrafting`), the send queue (`NativeCampaignQueue`), results
// and attribution (`NativeCampaignResults`), and the `?c=` code
// (`NativeAttributionCode`). Run with TZ=America/Phoenix: the local-date edges
// below assume a west-of-UTC zone (FA-039).
// Spec: docs/superpowers/specs/2026-10-03-campaigns-tags-design.md §5–§8, §12.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - Fixtures

let decoder = JSONDecoder()

func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! decoder.decode(T.self, from: data)
}

func customer(
    _ id: String,
    _ name: String,
    phone: String = "",
    email: String = "",
    extra: [String: Any] = [:]
) -> Canonical.Customer {
    var fields: [String: Any] = ["id": id, "name": name, "email": email, "phone": phone, "address": "", "notes": ""]
    for (key, value) in extra { fields[key] = value }
    return decode(Canonical.Customer.self, fields)
}

func job(
    _ id: String,
    customer: String,
    status: String = "paid",
    date: String? = nil,
    title: String = "Service call",
    createdAt: String = "2026-01-01",
    extra: [String: Any] = [:]
) -> Canonical.Job {
    var fields: [String: Any] = [
        "id": id, "customerId": customer, "customerName": "", "title": title, "description": "",
        "status": status, "address": "", "estimateTotal": 0, "laborHours": 0, "laborRate": 0,
        "materials": [], "materialMarkup": 0, "overhead": 0, "margin": 0, "notes": "", "createdAt": createdAt,
    ]
    if let date { fields["scheduledDate"] = date }
    for (key, value) in extra { fields[key] = value }
    return decode(Canonical.Job.self, fields)
}

func recurring(_ customerID: String, active: Bool = true) -> Canonical.RecurringJob {
    decode(Canonical.RecurringJob.self, [
        "id": "rj_\(customerID)", "customerId": customerID, "customerName": "", "title": "", "description": "",
        "address": "", "notes": "", "estimateTotal": 0, "laborHours": 0, "laborRate": 0, "materials": [],
        "materialMarkup": 0, "overhead": 0, "margin": 0, "cadence": "monthly", "endCondition": "never",
        "occurrenceCount": 0, "nextDueDate": "2026-11-01", "isActive": active, "createdAt": "2026-01-01",
    ])
}

func invoice(_ id: String, amount: Double, payments: [[String: Any]] = []) -> Canonical.Invoice {
    decode(Canonical.Invoice.self, [
        "id": id, "customer": "", "number": id, "amount": amount, "due": "2026-09-30",
        "email": "", "phone": "", "desc": "", "paid": false, "payments": payments,
    ])
}

/// Sat Oct 3 2026, 10:00 local (Phoenix).
let now = NativeCashBasis.localDate(year: 2026, month: 9, day: 3, hour: 10)

func audience(
    _ segment: Canonical.Campaign.Segment,
    plan: NativeCampaignSegments.ChannelPlan = .textFirst,
    customers: [Canonical.Customer],
    jobs: [Canonical.Job] = [],
    recurringJobs: [Canonical.RecurringJob] = [],
    campaigns: [Canonical.Campaign] = [],
    manual: [String] = [],
    canEmail: Bool = true,
    at date: Date = now
) -> NativeCampaignAudience {
    NativeCampaignSegments.evaluate(
        segment: segment, channelPlan: plan, customers: customers, jobs: jobs, recurringJobs: recurringJobs,
        campaigns: campaigns, manualExclusions: manual, canEmail: canEmail, now: date
    )
}

func ids(_ value: NativeCampaignAudience) -> [String] { value.recipients.map(\.customerID) }

func reason(_ value: NativeCampaignAudience, _ id: String) -> NativeCampaignSegments.ExclusionReason? {
    value.exclusions.first { $0.customerID == id }?.reason
}

/// A sending campaign whose recipients are already sent at `sentAt`.
func sentCampaign(_ id: String, code: String = "0123456789abcdef", sends: [(String, String)]) -> Canonical.Campaign {
    Canonical.Campaign(
        id: id, name: id, code: code, createdAt: "2026-08-01T00:00:00.000Z", status: "sending",
        recipients: sends.map { .init(customerId: $0.0, name: $0.0, channel: "text", status: "sent", sentAt: $0.1) }
    )
}

// MARK: - Segments: service window, keywords, tags, sources (spec §5.2)

func testServiceFilters() {
    let customers = [
        customer("a", "Ana", phone: "6025550101"),
        customer("b", "Ben", phone: "6025550102"),
        customer("c", "Cy", phone: "6025550103"),
        customer("d", "Di", phone: "6025550104"),
    ]
    let jobs = [
        job("ja", customer: "a", status: "paid", date: "2026-03-15", title: "Furnace tune-up"),
        job("jb", customer: "b", status: "invoiced", date: "2025-09-01", title: "AC repair"),
        job("jc", customer: "c", status: "lead", title: "Quote request"),
        job("jd", customer: "d", status: "complete", date: nil, title: "Back porch"),
    ]
    expectEqual(NativeServiceHistory.monthsBetween(from: "2026-03-15", now: now), 6, "months: Mar 15 → Oct 3 is 6")
    expectEqual(NativeServiceHistory.monthsBetween(from: "2025-09-01", now: now), 13, "months: Sep 1 2025 → Oct 3 is 13")
    let served = Canonical.Campaign.Segment(service: "served")
    expectEqual(ids(audience(served, customers: customers, jobs: jobs)), ["a", "b", "d"],
                "served, no bound: any delivered job (an undated one too)")
    var min6 = served; min6.minMonthsSinceService = 6
    expectEqual(ids(audience(min6, customers: customers, jobs: jobs)), ["a", "b"],
                "served ≥ 6 months: an undated delivered job matches only with no bound")
    var window = served; window.minMonthsSinceService = 11; window.maxMonthsSinceService = 13
    expectEqual(ids(audience(window, customers: customers, jobs: jobs)), ["b"], "served 11–13 months (inclusive)")
    var max6 = served; max6.maxMonthsSinceService = 6
    expectEqual(ids(audience(max6, customers: customers, jobs: jobs)), ["a"], "served ≤ 6 months (inclusive)")
    expectEqual(ids(audience(.init(service: "neverServed", excludeOpenWork: false), customers: customers, jobs: jobs)), ["c"],
                "never served: no delivered job at all")
    let neverDefault = audience(.init(service: "neverServed"), customers: customers, jobs: jobs)
    expect(ids(neverDefault).isEmpty && reason(neverDefault, "c") == .openWork,
           "never served with the default guard: an open lead is open work")
    expectEqual(ids(audience(NativeCampaignSegments.Preset.neverBooked.segment, customers: customers, jobs: jobs)), ["c"],
                "the Never booked preset reaches leads (its open-work guard starts off)")
    expectEqual(ids(audience(.init(service: "any", excludeOpenWork: false), customers: customers, jobs: jobs)), ["a", "b", "c", "d"], "any")
    expectEqual(ids(audience(.init(service: "fromTheFuture"), customers: customers, jobs: jobs)), ["a", "b", "d"],
                "an unknown service value reads as served")
    expect(audience(served, customers: customers, jobs: jobs).exclusions.isEmpty,
           "failing a filter is not matched, never an exclusion")
    expectEqual(audience(served, customers: customers, jobs: jobs).counts.matched, 3, "counts: matched")

    // Local-midnight boundary (FA-039): a job on the 3rd, run at 23:30 local on
    // the 2nd (06:30 UTC on the 3rd) vs 00:10 local on the 3rd.
    let edge = [customer("e", "Eve", phone: "6025550105")]
    let edgeJobs = [job("je", customer: "e", date: "2026-04-03")]
    let late2nd = NativeCashBasis.localDate(year: 2026, month: 9, day: 2, hour: 23, minute: 30)
    let early3rd = NativeCashBasis.localDate(year: 2026, month: 9, day: 3, hour: 0, minute: 10)
    expectEqual(ids(audience(min6, customers: edge, jobs: edgeJobs, at: late2nd)), [], "23:30 on the 2nd: 5 months, not matched")
    expectEqual(ids(audience(min6, customers: edge, jobs: edgeJobs, at: early3rd)), ["e"], "00:10 on the 3rd: 6 months, matched")
}

func testKeywordsTagsSources() {
    let customers = [
        customer("a", "Ana", phone: "6025550101", extra: ["tags": ["VIP", "AC"], "leadSource": "google"]),
        customer("b", "Ben", phone: "6025550102", extra: ["tags": ["Pool"], "leadSource": "Referral"]),
        customer("c", "Cy", phone: "6025550103", extra: ["leadSource": "Home show"]),
        customer("d", "Di", phone: "6025550104"),
    ]
    let jobs = [
        job("ja", customer: "a", date: "2026-01-01", title: "Furnace tune-up"),
        job("jb", customer: "b", date: "2026-01-01", title: "AC repair"),
        job("jc", customer: "c", date: "2026-01-01", title: "Back porch"),
        job("jd", customer: "d", date: "2026-01-01", title: "Two furnaces serviced"),
        job("jl", customer: "c", status: "declined", title: "AC install"),
    ]
    func keywords(_ words: [String]) -> [String] {
        ids(audience(.init(service: "served", jobKeywords: words), customers: customers, jobs: jobs))
    }
    expectEqual(keywords(["furnace"]), ["a", "d"], "keywords: a whole word or its plural, any case")
    expectEqual(keywords(["AC"]), ["b"], "keywords: 'AC' never matches inside 'Back' (and lead titles never count)")
    expectEqual(keywords(["tune up"]), ["a"], "keywords: several words match in order across punctuation")
    expectEqual(keywords(["Fúrnace", "porch"]), ["a", "c", "d"], "keywords: any of, diacritic-insensitive")
    expectEqual(keywords(["   "]), ["a", "b", "c", "d"], "keywords: a blank keyword is no filter")
    let suggestions = NativeCampaignSegments.keywordSuggestions(jobs: jobs + [job("jx", customer: "x", title: "The furnace and AC")])
    expect(suggestions.first == "furnace" && !suggestions.contains("the") && !suggestions.contains("and") && !suggestions.contains("ac"),
           "keyword suggestions: most frequent first, stop words and words under 3 characters removed (\(suggestions))")

    expectEqual(ids(audience(.init(service: "served", tagsAny: ["vip", "pool"]), customers: customers, jobs: jobs)), ["a", "b"],
                "tags any of")
    expectEqual(ids(audience(.init(service: "served", tagsNone: ["VIP"]), customers: customers, jobs: jobs)), ["b", "c", "d"],
                "tags none of (any spelling)")
    expectEqual(ids(audience(.init(service: "served", leadSources: ["google", "unknown"]), customers: customers, jobs: jobs)),
                ["a", "d"], "lead sources by bucket key, including unknown")
    expectEqual(ids(audience(.init(service: "served", leadSources: ["custom:home show"]), customers: customers, jobs: jobs)),
                ["c"], "a custom lead source bucket")
    expectEqual(ids(audience(.init(service: "served", referral: "cameFromReferral"), customers: customers, jobs: jobs)), ["b"],
                "came from a referral (normalized source)")
    let referred = customers + [customer("r", "Rae", phone: "6025550199", extra: ["referredByCustomerId": "c"])]
    let referralJobs = jobs + [job("jr", customer: "r", date: "2026-01-01")]
    expectEqual(ids(audience(.init(service: "served", referral: "hasReferred"), customers: referred, jobs: referralJobs)), ["c"],
                "has referred someone (Phase 34's typed referredByCustomerId)")
    expect(NativeCampaignSegments.referralDataAvailable(referred) && !NativeCampaignSegments.referralDataAvailable(customers),
           "has-referred is offered only once referral data exists")
}

// MARK: - Segments: exclusions, guards, reachability, duplicates (spec §5.2)

func testExclusionsAndGuards() {
    let customers = [
        customer("arch", "Archie", phone: "6025550101", extra: ["archivedAt": "2026-01-01"]),
        customer("opt", "Opal", phone: "6025550102", extra: ["marketingOptOutOn": "2026-02-01", "marketingOptOutVia": "asked"]),
        customer("both", "Bo", phone: "6025550103",
                 extra: ["archivedAt": "2026-01-01", "marketingOptOutOn": "2026-02-01"]),
        customer("open", "Oz", phone: "6025550104"),
        customer("plan", "Pat", phone: "6025550105"),
        customer("recent", "Rio", phone: "6025550106"),
        customer("ok", "Kai", phone: "6025550107"),
        customer("none", "Nia", phone: "555-1234", email: "nia@"),
    ]
    let jobs = customers.map { job("j_\($0.id)", customer: $0.id, date: "2026-01-10") }
        + [job("j_open2", customer: "open", status: "scheduled")]
    let recurringJobs = [recurring("plan"), recurring("ok", active: false)]
    let earlier = sentCampaign("cmp_old", sends: [("recent", "2026-09-20T17:00:00.000Z")])
    let served = Canonical.Campaign.Segment(service: "served")
    let result = audience(served, customers: customers, jobs: jobs, recurringJobs: recurringJobs, campaigns: [earlier])
    expectEqual(ids(result), ["ok"], "only the eligible customer remains")
    expectEqual(reason(result, "arch"), .archived, "fixed: archived")
    expectEqual(reason(result, "opt"), .optedOut, "fixed: opted out (O1)")
    expectEqual(reason(result, "both"), .archived, "the first failing rule is the reason")
    expectEqual(reason(result, "open"), .openWork, "guard: open work")
    expectEqual(reason(result, "plan"), .maintenancePlan, "guard: active maintenance plan (an inactive one does not count)")
    expectEqual(reason(result, "recent"), .recentlyContacted, "guard: contacted in the last 30 days")
    expectEqual(reason(result, "none"), .noContact, "reachability: 7 digits and a malformed email are unusable")
    expectEqual(result.counts.excludedByReason["archived"], 2, "counts per reason")

    var relaxed = served
    relaxed.excludeOpenWork = false
    relaxed.excludeMaintenancePlans = false
    relaxed.excludeContactedWithinDays = 0
    let open = audience(relaxed, customers: customers, jobs: jobs, recurringJobs: recurringJobs, campaigns: [earlier])
    expectEqual(ids(open), ["ok", "open", "plan", "recent"], "every guard can be turned off; fixed exclusions cannot")

    // The recently-contacted boundary, in local days (Phoenix).
    func contacted(_ sentAt: String, days: Int = 30) -> Bool {
        var segment = served
        segment.excludeContactedWithinDays = days
        let campaign = sentCampaign("cmp_b", sends: [("ok", sentAt)])
        return reason(audience(segment, customers: [customers[6]], jobs: jobs, campaigns: [campaign]), "ok") == .recentlyContacted
    }
    expect(contacted("2026-09-04T17:00:00.000Z"), "sent 29 days ago: still skipped")
    expect(!contacted("2026-09-03T17:00:00.000Z"), "sent 30 days ago: eligible again")
    expect(!contacted("2026-09-04T05:30:00.000Z"), "05:30Z on Sep 4 is 22:30 on Sep 3 in Phoenix: 30 local days, eligible")
    expect(!contacted("2026-10-01T17:00:00.000Z", days: 0), "0 days turns the guard off")
    let skippedOnly = Canonical.Campaign(id: "cmp_s", name: "s", code: "x", createdAt: "", status: "sending",
                                         recipients: [.init(customerId: "ok", name: "Kai", channel: "text", status: "skipped")])
    expectEqual(ids(audience(served, customers: [customers[6]], jobs: jobs, campaigns: [skippedOnly])), ["ok"],
                "only a sent recipient counts as contacted")
}

func testReachabilityMatrix() {
    let customers = [
        customer("p", "Pia", phone: "(602) 555-0101"),
        customer("e", "Eli", email: "eli@example.com"),
        customer("pe", "Pax", phone: "+1 602 555 0103", email: "pax@example.com"),
        customer("n", "Neo", phone: "555-0104", email: "not-an-email"),
    ]
    let jobs = customers.map { job("j_\($0.id)", customer: $0.id, date: "2026-01-10") }
    let served = Canonical.Campaign.Segment(service: "served")
    func channels(_ plan: NativeCampaignSegments.ChannelPlan, canEmail: Bool = true) -> [String: String] {
        let result = audience(served, plan: plan, customers: customers, jobs: jobs, canEmail: canEmail)
        var out = Dictionary(uniqueKeysWithValues: result.recipients.map { ($0.customerID, $0.channel.rawValue) })
        for exclusion in result.exclusions where exclusion.reason == .noContact { out[exclusion.customerID] = "none" }
        return out
    }
    expectEqual(channels(.textFirst), ["p": "text", "e": "email", "pe": "text", "n": "none"], "text_first")
    expectEqual(channels(.emailFirst), ["p": "text", "e": "email", "pe": "email", "n": "none"], "email_first")
    expectEqual(channels(.textOnly), ["p": "text", "e": "none", "pe": "text", "n": "none"], "text_only")
    expectEqual(channels(.emailOnly), ["p": "none", "e": "email", "pe": "email", "n": "none"], "email_only")
    expectEqual(channels(.textFirst, canEmail: false), ["p": "text", "e": "none", "pe": "text", "n": "none"],
                "no Business address: email is unreachable")
    expectEqual(channels(.emailFirst, canEmail: false), ["p": "text", "e": "none", "pe": "text", "n": "none"],
                "no Business address: email_first falls back to text")
    let blocked = audience(served, plan: .textFirst, customers: customers, jobs: jobs, canEmail: false)
    expectEqual(blocked.counts.reachableOnceAddressSet, 1, "the audience reports who email would reach once the address is set")
    let open = audience(served, plan: .textFirst, customers: customers, jobs: jobs)
    expect(open.counts.byText == 2 && open.counts.byEmail == 1 && open.counts.reachable == 3, "counts by channel")
    expectEqual(open.recipients.first { $0.customerID == "p" }?.contact, "(602) 555-0101", "the contact is the live phone as typed")
    expect(NativeCampaignContact.isTextable("602-555-0101") && !NativeCampaignContact.isTextable("555-0101"),
           "a phone counts with 10 or more digits")
    expect(NativeCampaignContact.isEmailable(" a@b.co ") && !NativeCampaignContact.isEmailable("a@b")
           && !NativeCampaignContact.isEmailable("a b@c.d"), "the booking validator's EMAIL_RE shape")
}

func testDuplicatesManualAndCap() {
    let customers = [
        customer("c2", "Dana Ortiz", phone: "602-555-0101", extra: ["createdAt": "2025-01-01T00:00:00Z"]),
        customer("c1", "Dana O.", phone: "+1 (602) 555-0101", extra: ["createdAt": "2025-06-01T00:00:00Z"]),
        customer("c3", "Sam", email: "SAM@x.com", extra: ["createdAt": "2025-01-01T00:00:00Z"]),
        customer("c4", "Sammy", email: "sam@x.com", extra: ["createdAt": "2025-01-01T00:00:00Z"]),
        customer("c5", "Lee", phone: "6025550199", email: "lee@x.com"),
        customer("c6", "Lee B", email: "lee@x.com"),
    ]
    let jobs = [
        job("j1", customer: "c1", date: "2026-05-01"), job("j2", customer: "c2", date: "2026-05-01"),
        job("j3", customer: "c3", date: "2026-02-01"), job("j4", customer: "c4", date: "2026-02-01"),
        job("j5", customer: "c5", date: "2026-01-01"), job("j6", customer: "c6", date: "2026-03-01"),
    ]
    let result = audience(.init(service: "served"), customers: customers, jobs: jobs)
    expectEqual(Set(ids(result)), ["c2", "c3", "c6"], "duplicates collapse to one per phone or email")
    expectEqual(reason(result, "c1"), .duplicateContact(ofCustomerID: "c2", ofName: "Dana Ortiz"),
                "same service date: the earliest createdAt is kept")
    expectEqual(reason(result, "c4"), .duplicateContact(ofCustomerID: "c3", ofName: "Sam"),
                "same date and createdAt: the smallest id is kept (email case-insensitive)")
    expectEqual(reason(result, "c5"), .duplicateContact(ofCustomerID: "c6", ofName: "Lee B"),
                "the most recent service date is kept, across channels")
    expectEqual(result.exclusions.first { $0.customerID == "c1" }?.reason.label, "Same phone or email as Dana Ortiz",
                "the exclusion names the kept customer")

    let manual = audience(.init(service: "served"), customers: customers, jobs: jobs, manual: ["c3"])
    expectEqual(Set(ids(manual)), ["c2", "c6"], "manual exclusions leave the list")
    expectEqual(reason(manual, "c3"), .removedByOwner, "manual exclusion reason")
    expectEqual(ids(result), ["c2", "c6", "c3"].sorted { a, b in
        let names = ["c2": "Dana Ortiz", "c6": "Lee B", "c3": "Sam"]
        return names[a]! < names[b]!
    }, "recipients are sorted by name")

    let many = (0..<201).map { customer("m\(String(format: "%03d", $0))", "M \($0)", phone: "602555\(String(format: "%04d", $0))") }
    let manyJobs = many.map { job("j\($0.id)", customer: $0.id, date: "2026-01-01") }
    let big = audience(.init(service: "served"), customers: many, jobs: manyJobs)
    expect(big.recipients.count == 201 && big.exceedsCap, "C4: over 200 is flagged")
    let draft = Canonical.Campaign(id: "cmp_big", name: "Big", code: "0123456789abcdef", createdAt: "")
    do {
        _ = try NativeCampaignQueue.freeze(draft, audience: big, blockingIssues: [], today: "2026-10-03")
        expect(false, "C4: freezing 201 recipients is refused")
    } catch {
        expectEqual(error as? NativeCampaignError, .tooManyRecipients(201), "C4: freezing 201 recipients is refused")
    }
    let capped = audience(.init(service: "served"), customers: many, jobs: manyJobs, manual: ["m000"])
    expect(!capped.exceedsCap && capped.recipients.count == 200, "C4: exactly 200 is allowed")
}

// MARK: - Parity with maintenance_due (spec §5.3, §12)

func testMaintenanceParity() {
    let customers = [
        customer("due1", "Ava", phone: "6025550101"),
        customer("due2", "Bea", email: "bea@example.com"),
        customer("short", "Cal", phone: "6025550103"),
        customer("open", "Del", phone: "6025550104"),
        customer("plan", "Eve", phone: "6025550105"),
        customer("arch", "Fay", phone: "6025550106", extra: ["archivedAt": "2026-01-01"]),
        customer("opted", "Gil", phone: "6025550107", extra: ["marketingOptOutOn": "2026-03-01"]),
        customer("undated", "Hal", phone: "6025550108"),
        customer("never", "Ida", phone: "6025550109"),
        customer("due3", "Jo", phone: "6025550110"),
    ]
    let jobs = [
        job("a", customer: "due1", status: "paid", date: "2026-04-03", title: "Furnace tune-up"),
        job("b", customer: "due2", status: "complete", date: "2025-02-11"),
        job("c", customer: "short", status: "paid", date: "2026-04-04"),
        job("d1", customer: "open", status: "paid", date: "2025-01-01"),
        job("d2", customer: "open", status: "estimate_sent"),
        job("e", customer: "plan", status: "paid", date: "2025-01-01"),
        job("f", customer: "arch", status: "paid", date: "2025-01-01"),
        job("g", customer: "opted", status: "paid", date: "2025-01-01"),
        job("h", customer: "undated", status: "paid"),
        job("i", customer: "never", status: "lead"),
        job("j1", customer: "due3", status: "invoiced", date: "2025-12-31"),
        job("j2", customer: "due3", status: "in_progress", extra: ["archivedAt": "2026-02-01"]),
    ]
    let recurringJobs = [recurring("plan")]
    var insightSet = Set<String>()
    for one in customers {
        let rows = NativeTodayInsights.selectMaintenanceDue(jobs: jobs, customers: [one], recurringJobs: recurringJobs, now: now)
        if rows.first?.id == "maintenance_due:\(one.id)" { insightSet.insert(one.id) }
    }
    let preset = NativeCampaignSegments.Preset.dueForMaintenance
    let presetSet = Set(ids(audience(preset.segment, customers: customers, jobs: jobs, recurringJobs: recurringJobs)))
    expectEqual(presetSet, insightSet, "parity: the Due for maintenance preset selects exactly maintenance_due's customers")
    expectEqual(presetSet, ["due1", "due2", "due3"], "parity: the shared fixture's due set")
    let aggregate = NativeTodayInsights.selectMaintenanceDue(jobs: jobs, customers: customers, recurringJobs: recurringJobs, now: now)
    expectEqual(aggregate.first?.target, .newCampaign(preset: preset.rawValue), "the aggregate row opens this preset")
    expectEqual(NativeCampaignSegments.Preset(rawValue: NativeInsightTarget.dueForMaintenancePreset), preset,
                "the insight's preset key names the preset")

    expectEqual(NativeCampaignSegments.Preset.annualCheckIn.segment.minMonthsSinceService, 11, "preset: annual check-in min")
    expectEqual(NativeCampaignSegments.Preset.annualCheckIn.segment.maxMonthsSinceService, 13, "preset: annual check-in max")
    expectEqual(NativeCampaignSegments.Preset.itsBeenAWhile.segment.minMonthsSinceService, 18, "preset: it's been a while")
    expectEqual(NativeCampaignSegments.Preset.neverBooked.segment.service, "neverServed", "preset: never booked")
    expect(NativeCampaignSegments.Preset.allCases.allSatisfy {
        ($0.segment.excludeOpenWork || $0 == .neverBooked) && $0.segment.excludeMaintenancePlans
            && $0.segment.excludeContactedWithinDays == 30
    }, "presets keep the default-on guards (D7); Never booked starts with open work allowed")
    expect(!NativeCampaignSegments.Preset.neverBooked.segment.excludeOpenWork, "Never booked: the open-work guard starts off")
}

// MARK: - Merge fields, rendering and compliance text (spec §6.1, §6.3)

let business = NativeCampaignMessage.Business(
    businessName: "Ortiz Heating", ownerName: "Rafa", phone: "602-555-0199", address: "PO Box 12\nMesa, AZ 85201"
)

func testFirstName() {
    let cases: [(String, String)] = [
        ("Dana Ortiz", "Dana"), ("  Mary-Ann  Lee ", "Mary-Ann"), ("O'Neil", "O'Neil"),
        ("Ortiz Plumbing LLC", "there"), ("Acme Inc.", "there"), ("Smith & Co", "there"), ("Big Company", "there"),
        ("Mr. Smith", "there"), ("J.R. Smith", "there"), ("123 Main", "there"), ("", "there"), ("D", "there"),
        ("Dana, Ortiz", "Dana"),
    ]
    for (name, expected) in cases {
        expectEqual(NativeCampaignMessage.firstName(name), expected, "firstName: \"\(name)\"")
    }
}

func testRendering() {
    typealias M = NativeCampaignMessage
    let template = "Hi {firstName} ({name}), {ownerName} at {businessName}.\nCall {businessPhone}.\nLast: {lastJob} in {lastServiceMonth}. Book: {bookingLink}"
    let link = M.campaignLink(base: URL(string: "https://gettradereadyapp.com/book.html?b=tok123")!, code: "0123456789abcdef")
    expectEqual(link?.absoluteString, "https://gettradereadyapp.com/book.html?b=tok123&c=0123456789abcdef", "booking link gains c")
    expectEqual(M.campaignLink(base: URL(string: "https://x.test/book.html?b=t&c=old")!, code: "new0000000000000")?.absoluteString,
                "https://x.test/book.html?b=t&c=new0000000000000", "an existing c is replaced")
    let rendered = M.render(kind: .text, body: template, recipient: .init(name: "Dana Ortiz", lastJobTitle: "Furnace tune-up",
                                                                            lastServiceDate: "2026-03-14"),
                            business: business, bookingLink: link)
    expectEqual(rendered.body,
                "Hi Dana (Dana Ortiz), Rafa at Ortiz Heating.\nCall 602-555-0199.\nLast: Furnace tune-up in March 2026. Book: https://gettradereadyapp.com/book.html?b=tok123&c=0123456789abcdef\n\nReply STOP to opt out.",
                "every merge field renders, then the opt-out line")
    expectEqual(rendered.fallbacks, [], "no fallbacks")
    expectEqual(rendered.subject, nil, "a text has no subject")

    let bare = M.Business(businessName: "Ortiz Heating", ownerName: "", phone: "", address: "")
    let fallback = M.render(kind: .text, body: template, recipient: .init(name: "Ortiz Plumbing LLC"), business: bare, bookingLink: nil)
    expectEqual(fallback.body,
                "Hi there (Ortiz Plumbing LLC), Ortiz Heating at Ortiz Heating.\nLast: your last service in a while back. Book:\n\nReply STOP to opt out.",
                "fallbacks: there, business name for owner, the phone line dropped, your last service, a while back")
    expectEqual(fallback.fallbacks, [.firstName, .ownerName, .businessPhone, .lastJob, .lastServiceMonth], "fallbacks are listed")

    let sneaky = M.render(kind: .text, body: "Hi {name}", recipient: .init(name: "{businessName}"), business: business, bookingLink: nil)
    expectEqual(sneaky.body, "Hi {businessName}\n\nReply STOP to opt out.", "a value is never substituted again (single pass)")

    let email = M.render(kind: .email, body: "Hi {firstName},\nSee you soon.", subject: "Tune-up for {firstName}",
                         recipient: .init(name: "Dana Ortiz"), business: business, bookingLink: nil)
    expectEqual(email.subject, "Tune-up for Dana", "the subject renders")
    expectEqual(email.body,
                "Hi Dana,\nSee you soon.\n\n—\nOrtiz Heating · PO Box 12, Mesa, AZ 85201\nYou're getting this because you're a past customer of Ortiz Heating.\nReply \"unsubscribe\" and we won't email you about offers again.",
                "the exact email footer, address on one line")
    expectEqual(M.complianceText(kind: .text, business: business), "Reply STOP to opt out.", "the exact text compliance line")

    let long = M.render(kind: .text, body: String(repeating: "x", count: 300), recipient: .init(name: "A"), business: business, bookingLink: nil)
    expect(long.isLongText, "a rendered text over 320 characters is flagged")
}

func testValidation() {
    typealias M = NativeCampaignMessage
    expectEqual(M.validate(kind: .text, body: "Hi {firstName}"), [], "a clean text")
    expectEqual(M.validate(kind: .text, body: "Hi {first name} and {price}"),
                [.unknownToken("{first name}"), .unknownToken("{price}")], "unknown tokens block")
    expect(M.validate(kind: .text, body: "Hi {price}").allSatisfy(\.isBlocking), "unknown tokens are blocking")
    expectEqual(M.validate(kind: .text, body: "  \n"), [.emptyBody], "an empty body blocks")
    for subject in ["Re: your furnace", "FW: tune-up", "fwd:hello"] {
        expect(M.validate(kind: .email, body: "Hi", subject: subject).contains(.deceptiveSubject), "subject prefix blocks: \(subject)")
    }
    expect(!M.validate(kind: .email, body: "Hi", subject: "Re-roof special").contains(.deceptiveSubject), "Re-roof is not a reply prefix")
    expect(M.validate(kind: .email, body: "Hi", subject: " ").contains(.emptySubject), "an email needs a subject")
    let warn = M.validate(kind: .text, body: String(repeating: "y", count: 300))
    expectEqual(warn, [.longText(324)], "the 320-character warning counts the opt-out line")
    expect(!M.Issue.longText(324).isBlocking && !M.Issue.missingBusinessPhone.isBlocking, "warnings never block")
    expectEqual(M.validate(kind: .text, body: String(repeating: "y", count: 296)), [], "296 + the opt-out line is 320: no warning")

    let noName = M.Business(businessName: " ", ownerName: "", phone: "", address: "")
    expectEqual(M.contextIssues(kind: .email, body: "{bookingLink} {businessPhone}", business: noName, bookingLinkReady: false),
                [.missingBusinessName, .bookingLinkUnavailable, .emailNeedsAddress, .missingBusinessPhone],
                "context issues: name, link, address (email) and the phone warning")
    expectEqual(M.contextIssues(kind: .text, body: "Hi", business: business, bookingLinkReady: false), [],
                "no context issue without the fields; texts need no address")

    let sms = M.smsURL(phone: "(602) 555-0101", body: "Hi & bye? 100%")?.absoluteString ?? ""
    expect(sms.hasPrefix("sms:6025550101&body=") && sms.contains("Hi%20%26%20bye%3F%20100%25"), "sms: one recipient, encoded body (\(sms))")
    let mail = M.mailtoURL(email: "dana@example.com", subject: "Tune-up", body: "Line one\nLine two")?.absoluteString ?? ""
    expect(mail.hasPrefix("mailto:dana@example.com?subject=Tune-up&body=Line%20one%0ALine%20two"), "mailto: one recipient (\(mail))")
}

// MARK: - AI drafting (spec §6.2)

func testDrafting() {
    typealias D = NativeCampaignDrafting
    let fixture = [
        customer("x1", "Dana Ortiz", phone: "602-555-0101", email: "dana@example.com", extra: ["address": "12 Saguaro Ln"]),
        customer("x2", "Sam Lee", phone: "480-555-0102", email: "sam@lee.org", extra: ["address": "9 Mesa Dr"]),
    ]
    let brief = D.Brief(goal: .tuneUp, tone: .friendly, kind: .text, details: "$89 AC tune-up, book by April 30")
    let system = D.systemPrompt(businessName: "Ortiz Heating", trade: "hvac", brief: brief, bookingLinkReady: false)
    let user = D.userMessage(brief: brief)
    let prompt = system + "\n" + user
    for person in fixture {
        for value in [person.name, person.phone, person.email, person.address, "Dana", "Ortiz Ln"] where !value.isEmpty {
            expect(!prompt.contains(value) || value == "Ortiz", "the prompt carries no customer data: \(value)")
        }
    }
    expect(!prompt.contains("602-555") && !prompt.contains("@example.com") && !prompt.contains("Saguaro"),
           "no phone, email or address reaches the AI")
    expect(prompt.contains("Ortiz Heating") && prompt.contains("hvac") && prompt.contains("Seasonal tune-up")
           && prompt.contains("friendly") && prompt.contains("$89 AC tune-up, book by April 30"),
           "exactly the business name, trade, goal, tone and details are sent")
    expect(!system.contains("{bookingLink}") && D.systemPrompt(businessName: "B", trade: "t", brief: brief, bookingLinkReady: true)
        .contains("{bookingLink}"), "the booking link field is offered only when the link is ready")
    expect(system.contains("BODY:") && !system.contains("SUBJECT:"), "a text reply format has no subject")
    expect(D.systemPrompt(businessName: "B", trade: "t", brief: .init(goal: .offer, tone: .professional, kind: .email, details: ""),
                          bookingLinkReady: false).contains("SUBJECT:"), "an email reply format has a subject")
    expect(user.count < 600, "one short user message")

    expectEqual(D.parse("BODY: Hi {FirstName}, tune-up time!\nReply STOP to opt out.", kind: .text),
                .init(subject: nil, body: "Hi {firstName}, tune-up time!"),
                "parse: text body, placeholders canonicalized, an added opt-out line removed")
    expectEqual(D.parse("Sure!\n**SUBJECT:** Re: Fwd: Tune-up time\n**BODY:**\nHi {firstName},\nSee you.", kind: .email),
                .init(subject: "Tune-up time", body: "Hi {firstName},\nSee you."),
                "parse: email with markdown markers; reply prefixes stripped from the subject")
    expectEqual(D.parse("Hi there, no markers", kind: .text), nil, "parse: no BODY marker fails")
    expectEqual(D.parse("BODY: Hi", kind: .email), nil, "parse: an email without a subject fails")
    expectEqual(D.parse("BODY:   ", kind: .text), nil, "parse: an empty body fails")

    let fallback = D.result(reply: nil, brief: brief)
    expect(fallback.source == .template && fallback.notice == D.fallbackNotice && fallback.draft == D.template(goal: .tuneUp, kind: .text),
           "a transport failure starts from the goal's template with the notice")
    let garbage = D.result(reply: "I can't help with that.", brief: brief)
    expect(garbage.source == .template, "an unparseable reply falls back")
    let good = D.result(reply: "BODY: Hi {firstName}! Our $79 tune-up is back. Book by April 30.", brief: brief)
    expect(good.source == .ai && good.notice == nil, "a parsed reply is used")
    expectEqual(good.warnings, ["The draft mentions $79. Your details said $89. Check it before sending."], "fact check: $79 vs $89")
    expectEqual(D.factCheck(draft: .init(subject: nil, body: "Save 15% through 4/30, $89.00 tune-up"), details: brief.details),
                ["The draft mentions 15%, which isn't in your details. Check it before sending."],
                "fact check: a new percentage warns; 4/30 matches April 30 and $89.00 matches $89")
    expectEqual(D.factCheck(draft: .init(subject: nil, body: "Book by May 5th"), details: brief.details),
                ["The draft mentions May 5th. Your details said April 30. Check it before sending."], "fact check: a different date")

    for goal in D.Goal.allCases {
        for kind in NativeCampaignMessage.Kind.allCases {
            let template = D.template(goal: goal, kind: kind)
            let issues = NativeCampaignMessage.validate(kind: kind, body: template.body, subject: template.subject).filter(\.isBlocking)
            expectEqual(issues, [], "template \(goal.rawValue)/\(kind.rawValue) has no blocking issue")
        }
    }
}

// MARK: - The send queue (spec §7)

func frozenCampaign() -> Canonical.Campaign {
    let customers = [
        customer("r1", "Ana", phone: "6025550101"), customer("r2", "Ben", phone: "6025550102"),
        customer("r3", "Cy", email: "cy@example.com"),
    ]
    let jobs = customers.map { job("j_\($0.id)", customer: $0.id, date: "2026-01-10") }
    let draft = Canonical.Campaign(id: "cmp_q", name: "Q", code: "0123456789abcdef", createdAt: "2026-10-01T00:00:00.000Z",
                                   message: .init(text: "Hi {firstName}"))
    return try! NativeCampaignQueue.freeze(draft, audience: audience(.init(service: "served"), customers: customers, jobs: jobs),
                                          blockingIssues: [], today: "2026-10-03")
}

func testQueue() {
    typealias Q = NativeCampaignQueue
    var campaign = frozenCampaign()
    expect(campaign.status == "sending" && campaign.frozenOn == "2026-10-03", "freeze: sending, frozen today")
    expectEqual(campaign.recipients?.map(\.customerId), ["r1", "r2", "r3"], "freeze: recipients from the audience, by name")
    expect(campaign.recipients?.allSatisfy { $0.status == "pending" } == true, "freeze: everyone starts pending")
    expectEqual(campaign.recipients?.map(\.channel), ["text", "text", "email"], "freeze: each recipient's channel")
    let draft = Canonical.Campaign(id: "d", name: "D", code: "x", createdAt: "")
    do {
        _ = try Q.freeze(campaign, audience: .init(recipients: [], exclusions: [], counts: .init()), blockingIssues: [], today: "")
        expect(false, "freeze: only a draft")
    } catch { expectEqual(error as? NativeCampaignError, .notADraft, "freeze: only a draft") }
    do {
        _ = try Q.freeze(draft, audience: .init(recipients: [], exclusions: [], counts: .init()), blockingIssues: [], today: "")
        expect(false, "freeze: an empty audience is refused")
    } catch { expectEqual(error as? NativeCampaignError, .emptyAudience, "freeze: an empty audience is refused") }
    do {
        _ = try Q.freeze(draft, audience: .init(recipients: [], exclusions: [], counts: .init()), blockingIssues: [.emptyBody], today: "")
        expect(false, "freeze: a blocking issue is refused")
    } catch { expectEqual(error as? NativeCampaignError, .invalidMessage([.emptyBody]), "freeze: a blocking issue is refused") }

    expectEqual(Q.nextPendingIndex(campaign), 0, "resume: the first pending")
    // .cancelled: stays pending, no advance (the pause point).
    let cancelled = try! Q.apply(.cancelled, to: campaign, customerID: "r1", autoAdvance: true, nowISO: "2026-10-03T17:00:00.000Z")
    expect(cancelled.campaign == campaign && !cancelled.advances && cancelled.notice == nil, "cancelled: nothing changes, no advance")
    // .saved: stays pending with the Mail draft notice.
    let saved = try! Q.apply(.saved, to: campaign, customerID: "r1", autoAdvance: true, nowISO: "2026-10-03T17:00:00.000Z")
    expect(saved.campaign == campaign && !saved.advances && saved.notice == Q.savedDraftNotice, "saved: pending, the notice")
    // .sent: sent, sentAt, the first send locks the message, advance when on.
    let sent = try! Q.apply(.sent, to: campaign, customerID: "r1", autoAdvance: true, nowISO: "2026-10-03T17:00:00.000Z")
    campaign = sent.campaign
    expect(sent.advances, "sent: advances when the toggle is on")
    expect(campaign.recipients?[0].status == "sent" && campaign.recipients?[0].sentAt == "2026-10-03T17:00:00.000Z", "sent: recorded")
    expectEqual(campaign.message.lockedAt, "2026-10-03T17:00:00.000Z", "C3: the first send sets lockedAt")
    expectEqual(Q.nextPendingIndex(campaign), 1, "resume: past the sent one")
    do {
        _ = try Q.apply(.sent, to: campaign, customerID: "r1", autoAdvance: true, nowISO: "x")
        expect(false, "a sent recipient is not sent again")
    } catch { expectEqual(error as? NativeCampaignError, .recipientNotPending, "a sent recipient is not sent again") }
    // .failed: failed, Retry makes it pending, no advance.
    let failed = try! Q.apply(.failed, to: campaign, customerID: "r2", autoAdvance: true, nowISO: "2026-10-03T17:05:00.000Z")
    expect(failed.campaign.recipients?[1].status == "failed" && !failed.advances && failed.notice == Q.failedNotice, "failed: marked")
    campaign = failed.campaign
    let noAdvance = try! Q.apply(.sent, to: try! Q.retry(campaign, customerID: "r2"), customerID: "r2", autoAdvance: false,
                                 nowISO: "2026-10-03T17:06:00.000Z")
    expect(!noAdvance.advances, "sent with the toggle off: no advance")
    expectEqual(noAdvance.campaign.message.lockedAt, "2026-10-03T17:00:00.000Z", "C3: lockedAt keeps the first send")
    campaign = try! Q.retry(campaign, customerID: "r2")
    expectEqual(campaign.recipients?[1].status, "pending", "retry: failed becomes pending")

    // Skips, the manual send and End.
    let skipped = try! Q.skip(campaign, customerID: "r2", reason: .optedOut, nowISO: "x")
    expect(skipped.recipients?[1].status == "skipped" && skipped.recipients?[1].skipReason == "opted_out", "skip with a reason")
    let manual = try! Q.markSent(skipped, customerID: "r3", nowISO: "2026-10-03T18:00:00.000Z")
    expect(manual.recipients?[2].status == "sent" && manual.recipients?[2].manual == true, "Mark as sent is manual")
    expectEqual(manual.status, "done", "the campaign is done once nobody is pending or failed")
    expectEqual(Q.summary(manual), "Sent 2 · Skipped 1: 1 opted out", "the done summary")
    let replied = try! Q.markReplied(manual, customerID: "r1", on: "2026-10-04")
    expectEqual(replied.recipients?[0].repliedOn, "2026-10-04", "replied is owner-marked on a sent recipient")
    do {
        _ = try Q.markReplied(manual, customerID: "r2", on: "2026-10-04")
        expect(false, "a skipped recipient cannot reply")
    } catch { expectEqual(error as? NativeCampaignError, .recipientNotPending, "a skipped recipient cannot reply") }

    var ending = frozenCampaign()
    ending = try! Q.apply(.sent, to: ending, customerID: "r1", autoAdvance: true, nowISO: "2026-10-03T17:00:00.000Z").campaign
    ending = try! Q.apply(.failed, to: ending, customerID: "r2", autoAdvance: true, nowISO: "x").campaign
    let ended = try! Q.end(ending, nowISO: "2026-10-03T19:00:00.000Z")
    expectEqual(ended.recipients?.map(\.status), ["sent", "skipped", "skipped"], "End: pending and failed are skipped")
    expectEqual(ended.recipients?.compactMap(\.skipReason), ["ended", "ended"], "End: the reason is ended")
    expect(ended.status == "done" && ended.endedAt == "2026-10-03T19:00:00.000Z", "End: done, endedAt")
    do {
        _ = try Q.apply(.sent, to: ended, customerID: "r2", autoAdvance: true, nowISO: "x")
        expect(false, "a done campaign takes no outcome")
    } catch { expectEqual(error as? NativeCampaignError, .notSending, "a done campaign takes no outcome") }

    let copy = Q.duplicate(ended, id: "cmp_copy", code: "fedcba9876543210", createdAt: "2026-10-04T00:00:00.000Z")
    expect(copy.status == "draft" && copy.recipients == nil && copy.message.lockedAt == nil && copy.name == "Q (copy)"
           && copy.code == "fedcba9876543210" && copy.message.text == ended.message.text && copy.segment == ended.segment,
           "Duplicate: an editable draft with the same rules and message (C3, D12)")
}

func testLiveCheck() {
    typealias Q = NativeCampaignQueue
    let text = Canonical.Campaign.Recipient(customerId: "r1", name: "Ana", channel: "text")
    let mail = Canonical.Campaign.Recipient(customerId: "r1", name: "Ana", channel: "email")
    expectEqual(Q.liveCheck(text, customers: []), .skip(.deleted), "live: a deleted customer")
    expectEqual(Q.liveCheck(text, customers: [customer("r1", "Ana", phone: "6025550101", extra: ["archivedAt": "2026-10-01"])]),
                .skip(.archived), "live: archived since the freeze")
    expectEqual(Q.liveCheck(text, customers: [customer("r1", "Ana", phone: "6025550101", extra: ["marketingOptOutOn": "2026-10-02"])]),
                .skip(.optedOut), "live: opted out since the freeze (O1)")
    expectEqual(Q.liveCheck(text, customers: [customer("r1", "Ana", phone: "")]), .skip(.noContact), "live: the phone was removed")
    expectEqual(Q.liveCheck(mail, customers: [customer("r1", "Ana", email: "ana@")]), .skip(.noContact), "live: the email is unusable")
    expectEqual(Q.liveCheck(text, customers: [customer("r1", "Ana", phone: " 480-555-0000 ")]), .ready(contact: "480-555-0000"),
                "live: the composer uses the live contact, not a snapshot")
}

func testQuietHours() {
    typealias Q = NativeCampaignQueue
    func at(_ hour: Int, _ minute: Int) -> String? {
        Q.quietHoursWarning(now: NativeCashBasis.localDate(year: 2026, month: 9, day: 3, hour: hour, minute: minute))
    }
    expect(at(7, 59)?.hasPrefix("It's 7:59 AM.") == true, "quiet hours: 7:59 warns")
    expectEqual(at(8, 0), nil, "quiet hours: 8:00 is fine")
    expectEqual(at(19, 59), nil, "quiet hours: 19:59 is fine")
    expect(at(20, 0)?.hasPrefix("It's 8:00 PM.") == true, "quiet hours: 20:00 warns")
    expectEqual(at(21, 14), "It's 9:14 PM. Many states restrict marketing texts in the evening. Consider resuming tomorrow.",
                "quiet hours: the evening text")
    expect(at(0, 5)?.hasPrefix("It's 12:05 AM.") == true, "quiet hours: just after midnight")
    expect(Q.largeTextSendHint(textCount: 51) != nil && Q.largeTextSendHint(textCount: 50) == nil, "the carrier hint above 50 texts")
}

// MARK: - Results and attribution (spec §8)

func testResults() {
    let customers = [customer("a", "Ana"), customer("b", "Ben"), customer("c", "Cy"), customer("new", "New Person")]
    // Phoenix: 05:30Z on Sep 1 is 22:30 on Aug 31 locally, so the window is Aug 31–Sep 30.
    var x = sentCampaign("cmp_x", code: "x000000000000000", sends: [("a", "2026-09-01T05:30:00.000Z"), ("b", "2026-09-01T05:30:00.000Z")])
    x.recipients?[0].repliedOn = "2026-09-02"
    x.recipients?.append(.init(customerId: "c", name: "Cy", channel: "text", status: "skipped", skipReason: "opted_out"))
    let y = sentCampaign("cmp_y", code: "y000000000000000", sends: [("b", "2026-09-10T17:00:00.000Z")])
    let jobs = [
        job("in30", customer: "a", status: "approved", createdAt: "2026-09-30", extra: ["invoiceId": "inv1"]),
        job("out31", customer: "a", status: "paid", createdAt: "2026-10-01"),
        job("before", customer: "a", status: "paid", createdAt: "2026-08-30"),
        job("sameDay", customer: "a", status: "lead", createdAt: "2026-08-31"),
        job("recur", customer: "a", status: "paid", createdAt: "2026-09-05", extra: ["recurringJobId": "rj1"]),
        job("archived", customer: "a", status: "paid", createdAt: "2026-09-05", extra: ["archivedAt": "2026-09-20"]),
        job("bEarly", customer: "b", status: "declined", createdAt: "2026-09-05"),
        job("bLate", customer: "b", status: "scheduled", createdAt: "2026-09-12", extra: ["invoiceId": "missing"]),
        job("link", customer: "new", status: "lead", createdAt: "2026-09-03", extra: ["campaignId": "cmp_x"]),
        job("linkB", customer: "b", status: "paid", createdAt: "2026-09-15", extra: ["campaignId": "cmp_x", "invoiceId": "inv2"]),
        job("skipped", customer: "c", status: "paid", createdAt: "2026-09-05"),
        job("gone", customer: "a", status: "paid", createdAt: "2026-09-06", extra: ["campaignId": "cmp_deleted"]),
    ]
    let invoices = [
        invoice("inv1", amount: 500, payments: [
            ["id": "p1", "amount": 200, "date": "2026-09-30", "method": "card"],
            ["id": "p2", "amount": 300, "date": "2026-10-01", "method": "card", "voidedAt": "2026-10-02T00:00:00Z"],
        ]),
        invoice("inv2", amount: 120, payments: [["id": "p3", "amount": 120, "date": "2026-09-20", "method": "cash"]]),
    ]
    let all = [x, y]
    let rx = NativeCampaignResults.make(campaign: x, campaigns: all, jobs: jobs, invoices: invoices, customers: customers, now: now)
    expectEqual(rx.jobIDs, ["bEarly", "in30", "link", "linkB", "sameDay"],
                "attribution: day 30 in, day 31 out, before the send out, recurring and archived out, skipped out, last touch")
    expectEqual(rx.bookedViaLink, 2, "booked via link, including a new person on a forwarded link")
    expectEqual(rx.booked, 5, "booked = link + window")
    expectEqual(rx.won, 2, "won: approved or later (declined is not)")
    expectEqual(rx.collected, 320, "collected: non-voided payments on the attributed jobs' invoices")
    expectEqual(rx.sent, 2, "sent")
    expectEqual(rx.replied, 1, "replied")
    expectEqual(rx.rows.map(\.customerID), ["a", "b", "c"], "a row per recipient")
    expectEqual(rx.rows.first?.bookedOn, "2026-08-31", "Booked badge: the earliest attributed job")
    expectEqual(rx.rows.last?.bookedOn, nil, "no badge for a skipped recipient")
    expectEqual(rx.headline(formatMoney: { "$\($0)" }), "Sent 2 · Replied 1 · Booked 5 (2 via link) · Won 2 · $320 collected", "headline")

    let ry = NativeCampaignResults.make(campaign: y, campaigns: all, jobs: jobs, invoices: invoices, customers: customers, now: now)
    expectEqual(ry.jobIDs, ["bLate"], "last touch: the later campaign wins the later job; a link job is never window-attributed")
    expectEqual(ry.collected, 0, "a deleted invoice collects nothing")
    let attribution = NativeCampaignResults.attribute(campaigns: all, jobs: jobs)
    expectEqual(Set(attribution.keys).count, attribution.count, "each job is counted once across campaigns")
    expectEqual(attribution["gone"], nil, "a job explicitly attributed to a deleted campaign is never re-attributed")
    expectEqual(NativeCampaignResults.footer,
                "Counts jobs booked through this campaign's link, or created for someone within 30 days of their message.",
                "the attribution footer")
}

// MARK: - The ?c= code (spec §9.2)

func testAttributionCode() {
    typealias C = NativeAttributionCode
    let zeros = C.makeCode { Array(repeating: 0, count: $0) }
    expectEqual(zeros, "0000000000000000", "code: 10 zero bytes")
    let ones = C.makeCode { Array(repeating: 0xff, count: $0) }
    expectEqual(ones, "zzzzzzzzzzzzzzzz", "code: 10 0xff bytes")
    let mixed = C.makeCode { _ in [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x10, 0x32] }
    expectEqual(mixed, "04hmasw9nf6yy41j", "code: 5 bits per character, Crockford alphabet")
    for _ in 0..<50 {
        let code = C.makeCode()
        expect(C.isValid(code) && code.count == 16 && !code.contains { "ilou".contains($0) }, "code: random codes are valid (\(code))")
    }
    expect(C.isValid(" 04HMASW9NF6YY41J "), "valid after trimming and lowercasing, as the Worker does")
    expect(!C.isValid("04hmasw9nf6yy41") && !C.isValid("04hmasw9nf6yy41jk") && !C.isValid("04hmasw9nf6yy41u"),
           "wrong length or a u is invalid")
    let unique = C.makeUniqueCode(existing: ["0000000000000000"]) { Array(repeating: 0, count: $0) }
    expect(unique != "0000000000000000" && C.isValid(unique), "a taken code is never reused")
}

testServiceFilters()
testKeywordsTagsSources()
testExclusionsAndGuards()
testReachabilityMatrix()
testDuplicatesManualAndCap()
testMaintenanceParity()
testFirstName()
testRendering()
testValidation()
testDrafting()
testQueue()
testLiveCheck()
testQuietHours()
testResults()
testAttributionCode()

if failures == 0 {
    print("PASS: campaign tests (\(checks) checks)")
} else {
    print("campaign tests: \(failures) of \(checks) checks FAILED")
    exit(1)
}
