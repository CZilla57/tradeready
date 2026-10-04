import Foundation

// Phase 27 (lead source tracking) host tests: the normalizer and buckets
// (`N/Domain/NativeLeadSource.swift`) and the report + coach block
// (`N/Domain/NativeLeadSourceReport.swift`). Run with TZ=America/Phoenix: the
// local-date edges below assume a west-of-UTC zone (FA-039).

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

// MARK: - Normalize

func testNormalize() {
    expectEqual(NativeLeadSource.normalize(nil), nil, "normalize: nil stays nil")
    expectEqual(NativeLeadSource.normalize(""), nil, "normalize: empty is nil")
    expectEqual(NativeLeadSource.normalize(" \t\n "), nil, "normalize: whitespace is nil")
    expectEqual(NativeLeadSource.normalize("\u{0007}\u{0000}"), nil, "normalize: control characters alone are nil")

    // Every preset key, display name and alias maps to the key, any case.
    for preset in NativeLeadSource.presets {
        expectEqual(NativeLeadSource.normalize(preset.key), preset.key, "normalize: key \(preset.key)")
        expectEqual(NativeLeadSource.normalize(preset.displayName.uppercased()), preset.key,
                    "normalize: display name \(preset.displayName)")
        for alias in preset.aliases {
            expectEqual(NativeLeadSource.normalize("  \(alias.uppercased())  "), preset.key,
                        "normalize: alias \(alias) → \(preset.key)")
        }
    }
    let keys = NativeLeadSource.presets.map(\.key)
    expectEqual(keys, ["referral", "google", "facebook", "nextdoor", "yelp", "thumbtack_angi",
                       "signage", "website", "booking_link", "mailer", "campaign"], "presets: stable wire keys in picker order")
    expectEqual(Set(keys).count, keys.count, "presets: unique keys")
    var owner: [String: String] = [:]
    for preset in NativeLeadSource.presets {
        for spelling in Set([preset.key, preset.displayName.lowercased()] + preset.aliases) {
            expect(owner[spelling] == nil, "presets: \"\(spelling)\" maps to one preset only")
            owner[spelling] = preset.key
        }
    }
    expect(NativeLeadSource.presets.allSatisfy { $0.aliases.allSatisfy { $0 == $0.lowercased() } },
           "presets: aliases are stored lowercased")

    // Spec aliases.
    expectEqual(NativeLeadSource.normalize("Word of mouth"), "referral", "normalize: word of mouth")
    expectEqual(NativeLeadSource.normalize("Google Business Profile"), "google", "normalize: GBP")
    expectEqual(NativeLeadSource.normalize("Angie's List"), "thumbtack_angi", "normalize: Angie's List")
    expectEqual(NativeLeadSource.normalize("HomeAdvisor"), "thumbtack_angi", "normalize: HomeAdvisor")
    expectEqual(NativeLeadSource.normalize("Vehicle   wrap"), "signage", "normalize: internal whitespace collapses before matching")
    expectEqual(NativeLeadSource.normalize("Door hanger"), "mailer", "normalize: door hanger")
    // Phase 33 (campaigns spec §9.2): the additive `campaign` preset.
    expectEqual(NativeLeadSource.campaignKey, "campaign", "campaign key")
    expectEqual(NativeLeadSource.displayName("campaign"), "Text or email campaign", "campaign display name")
    for alias in ["Email campaign", "TEXT CAMPAIGN", "sms campaign", "Email blast", "Newsletter", "Text or email campaign"] {
        expectEqual(NativeLeadSource.normalize(alias), "campaign", "normalize: \(alias) → campaign")
    }
    expectEqual(NativeLeadSource.bucketKey("campaign"), "campaign", "campaign is a preset bucket")

    // Custom labels.
    expectEqual(NativeLeadSource.normalize("  Home   show 2026 "), "Home show 2026", "normalize: custom label trimmed and collapsed")
    expectEqual(NativeLeadSource.normalize("Chamber\u{0007} of commerce"), "Chamber of commerce",
                "normalize: control characters stripped")
    expectEqual(NativeLeadSource.normalize("Line one\nline two"), "Line one line two", "normalize: newlines collapse to spaces")
    let long = String(repeating: "x", count: 45)
    expectEqual(NativeLeadSource.normalize(long), String(repeating: "x", count: 40), "normalize: custom labels cap at 40")
    expectEqual(NativeLeadSource.normalize(String(repeating: "a", count: 39) + " b"),
                String(repeating: "a", count: 39), "normalize: a cap that ends in a space is trimmed")
    expectEqual(NativeLeadSource.normalize("👷‍♂️ Contractor expo"), "👷‍♂️ Contractor expo", "normalize: emoji survive")
}

// MARK: - Buckets and names

func testNormalizePlaceholders() {
    for raw in ["Unknown", "UNKNOWN", " unknown ", "Not set", "None", "N/A", "n/a", "NA", "-", "--", "—", "?"] {
        expectEqual(NativeLeadSource.normalize(raw), nil, "normalize: placeholder '\(raw)' is no source")
        expectEqual(NativeLeadSource.bucketKey(raw), NativeLeadSource.unknownBucketKey, "bucket: placeholder '\(raw)' is Unknown")
    }
    expectEqual(NativeLeadSource.normalize("Unknown caller"), "Unknown caller", "normalize: a label that only starts with a placeholder is kept")
    expectEqual(NativeLeadSource.customLabels(in: ["Unknown", "Home show"]), ["Home show"], "custom labels: placeholders are never offered")
}

func testBuckets() {
    expectEqual(NativeLeadSource.bucketKey(nil), "unknown", "bucket: nil is unknown")
    expectEqual(NativeLeadSource.bucketKey("   "), "unknown", "bucket: blank is unknown")
    expectEqual(NativeLeadSource.bucketKey("google"), "google", "bucket: preset key")
    expectEqual(NativeLeadSource.bucketKey("Google Ads"), "google", "bucket: an un-normalized alias still buckets")
    expectEqual(NativeLeadSource.bucketKey("Home show"), "custom:home show", "bucket: custom")
    expectEqual(NativeLeadSource.bucketKey("home  SHOW"), "custom:home show", "bucket: custom spellings merge")

    expectEqual(NativeLeadSource.displayName(nil), "Unknown", "name: unknown")
    expectEqual(NativeLeadSource.displayName("thumbtack_angi"), "Thumbtack / Angi", "name: preset")
    expectEqual(NativeLeadSource.displayName("booking_link"), "Online booking link", "name: booking link")
    expectEqual(NativeLeadSource.displayName("Home show"), "Home show", "name: custom verbatim")
    expect(NativeLeadSource.isCustom("Home show") && !NativeLeadSource.isCustom("yelp") && !NativeLeadSource.isCustom(nil),
           "isCustom")

    expectEqual(NativeLeadSource.customLabels(in: ["google", nil, "Home show", "home show", "Chamber", "", "Yelp", "Bob's referral"]),
                ["Bob's referral", "Chamber", "Home show"],
                "custom labels: presets and blanks excluded, first spelling per bucket, sorted")

    expectEqual(NativeLeadSource.firstTouch(existing: nil, candidate: "Nextdoor"), "nextdoor", "first touch: blank takes the candidate")
    expectEqual(NativeLeadSource.firstTouch(existing: "  ", candidate: "yelp"), "yelp", "first touch: whitespace counts as blank")
    expectEqual(NativeLeadSource.firstTouch(existing: "google", candidate: "yelp"), "google", "first touch: an existing source is kept")
    expectEqual(NativeLeadSource.firstTouch(existing: nil, candidate: nil), nil, "first touch: nothing stays nothing")
}


func testExportLabel() {
    expectEqual(NativeLeadSource.exportLabel(nil), "", "export: unknown is empty")
    expectEqual(NativeLeadSource.exportLabel("  "), "", "export: blank is empty")
    expectEqual(NativeLeadSource.exportLabel("thumbtack_angi"), "Thumbtack / Angi", "export: preset display name")
    expectEqual(NativeLeadSource.exportLabel("Home  show"), "Home show", "export: custom label verbatim (normalized)")
    for preset in NativeLeadSource.presets {
        expectEqual(NativeLeadSource.normalize(NativeLeadSource.exportLabel(preset.key)), preset.key,
                    "export: \(preset.key) survives export → re-import")
    }
}

// MARK: - Report fixtures

private func decodeJSON<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(T.self, from: data)
}

private func customer(_ id: String, _ name: String, source: String? = nil, createdAt: String? = nil,
                      archivedAt: String? = nil) -> Canonical.Customer {
    var fields: [String: Any] = ["id": id, "name": name, "email": "", "phone": "", "address": "", "notes": ""]
    if let source { fields["leadSource"] = source }
    if let createdAt { fields["createdAt"] = createdAt }
    if let archivedAt { fields["archivedAt"] = archivedAt }
    return decodeJSON(Canonical.Customer.self, fields)
}

private func job(_ id: String, customerId: String, name: String = "", status: String,
                 sentAt: String? = nil, approvalSentAt: String? = nil, archivedAt: String? = nil) -> Canonical.Job {
    var fields: [String: Any] = [
        "id": id, "customerId": customerId, "customerName": name, "title": "Job", "description": "",
        "status": status, "address": "", "estimateTotal": 1000, "laborHours": 4, "laborRate": 100,
        "materials": [], "materialMarkup": 0, "overhead": 15, "margin": 20, "notes": "",
        "createdAt": "2026-01-02",
    ]
    if let sentAt { fields["estimateSentAt"] = sentAt }
    if let approvalSentAt {
        fields["approval"] = [
            "token": "t-\(id)", "sentAt": approvalSentAt,
            "snapshot": ["businessName": "B", "customerName": name, "jobTitle": "Job", "lineItems": [],
                         "total": 1000, "currency": "USD"],
        ] as [String: Any]
    }
    if let archivedAt { fields["archivedAt"] = archivedAt }
    return decodeJSON(Canonical.Job.self, fields)
}

private func payment(_ id: String, _ amount: Double, _ date: String, voidedAt: String? = nil) -> [String: Any] {
    var fields: [String: Any] = ["id": id, "amount": amount, "date": date, "method": "cash"]
    if let voidedAt { fields["voidedAt"] = voidedAt }
    return fields
}

private func invoice(_ id: String, customerId: String?, name: String, amount: Double = 1000,
                     payments: [[String: Any]] = [], paidAt: String? = nil) -> Canonical.Invoice {
    var fields: [String: Any] = [
        "id": id, "customer": name, "number": "INV-\(id)", "amount": amount, "due": "2026-01-01",
        "email": "", "phone": "", "desc": "", "paid": paidAt != nil,
    ]
    if let customerId { fields["customerId"] = customerId }
    if !payments.isEmpty { fields["payments"] = payments }
    if let paidAt { fields["paidAt"] = paidAt }
    return decodeJSON(Canonical.Invoice.self, fields)
}

/// March 10 2026, local midnight; "this_month" is March 1 – March 31 23:59:59 local.
private let march10 = NativeCashBasis.localDate(year: 2026, month: 2, day: 10)
private let march = NativeCashBasis.range(for: "this_month", now: march10)
private let april = NativeCashBasis.range(for: "this_month", now: NativeCashBasis.localDate(year: 2026, month: 3, day: 10))

private let fixtureCustomers = [
    customer("c1", "Ann Lee", source: "google", createdAt: "2026-03-05"),
    // 05:00Z on Apr 1 is 22:00 on Mar 31 in Phoenix: a March customer.
    customer("c2", "Bob Ray", source: "Home show", createdAt: "2026-04-01T05:00:00.000Z"),
    // Same custom bucket, different spelling; archived customers still count.
    customer("c3", "Cat Diaz", source: "home  SHOW", createdAt: "2026-02-27", archivedAt: "2026-03-02"),
    customer("c4", "Dee Fox", createdAt: "2026-03-10"),
    customer("c5", "Eve Gold", source: "Word of mouth", createdAt: "2026-01-15"),
    customer("c6", "Sam Twin", source: "google"),
    customer("c7", "sam twin ", source: "yelp"),
    customer("c8", "Pat Kim", source: "nextdoor"),
]

private let fixtureJobs = [
    job("j1", customerId: "c1", status: "approved", sentAt: "2026-03-03"),
    job("j2", customerId: "c1", status: "declined", sentAt: "2026-03-04"),
    // approval.sentAt is the fallback; 06:30Z Apr 1 is 23:30 Mar 31 local.
    job("j3", customerId: "c1", status: "paid", approvalSentAt: "2026-04-01T06:30:00.000Z"),
    job("j4", customerId: "c2", status: "approved", sentAt: "2026-02-20"),
    // Empty customerId: falls back to the normalized name.
    job("j5", customerId: "", name: "  ANN LEE ", status: "scheduled", sentAt: "2026-03-15"),
    // Dangling id, unmatched name: Unknown.
    job("j6", customerId: "deleted-1", name: "Zed Gone", status: "estimate_sent", sentAt: "2026-03-20"),
    job("j7", customerId: "c1", status: "lead"),
    // An archived job still counts in its cohort.
    job("j8", customerId: "c3", status: "complete", sentAt: "2026-03-12", archivedAt: "2026-03-20"),
    job("j9", customerId: "c1", status: "approved"),
    // estimateSentAt wins over approval.sentAt.
    job("j10", customerId: "c1", status: "approved", sentAt: "2026-02-28", approvalSentAt: "2026-03-05"),
]

private let fixtureInvoices = [
    invoice("i1", customerId: "c1", name: "Ann Lee", payments: [
        payment("p1", 400, "2026-03-05"),
        payment("p2", 100, "2026-03-06", voidedAt: "2026-03-07"),
    ]),
    // Nil customerId: name fallback. Both payments are 23:30 local on Mar 31.
    invoice("i2", customerId: nil, name: "BOB RAY", payments: [
        payment("p3", 250, "2026-04-01T06:30:00.000Z"),
        payment("p4", 50, "2026-03-31T23:30:00"),
    ]),
    // Dangling id (deleted customer) whose name matches a known customer.
    invoice("i3", customerId: "deleted-2", name: "Eve Gold", amount: 300, paidAt: "2026-03-20"),
    // Dangling id, unknown name.
    invoice("i4", customerId: "deleted-3", name: "Nobody", payments: [payment("p5", 50, "2026-03-08")]),
    // Ambiguous name ("Sam Twin" is google and yelp): not guessed.
    invoice("i5", customerId: nil, name: "Sam Twin", payments: [payment("p6", 20, "2026-03-09")]),
    invoice("i6", customerId: "c3", name: "Cat Diaz", payments: [payment("p7", 1000, "2026-02-15")]),
    invoice("i7", customerId: "c5", name: "Eve Gold", payments: [payment("p8", 75, "2026-04-01")]),
]

private func row(_ report: NativeLeadSourceReport, _ key: String) -> NativeLeadSourceReportRow? {
    report.rows.first { $0.bucketKey == key }
}

// MARK: - Report math

func testReportMath() {
    let report = NativeLeadSourceReport.make(
        customers: fixtureCustomers, jobs: fixtureJobs, invoices: fixtureInvoices,
        start: march.start, end: march.end
    )
    expectEqual(report.rows.map(\.bucketKey),
                ["google", "custom:home show", "referral", "nextdoor", "yelp", "unknown"],
                "sort: collected desc, then new customers, then name; Unknown last despite $70")
    expect(report.hasAnySource, "has a source")

    let google = row(report, "google")
    expectEqual(google?.displayName, "Google", "google: preset display name")
    expectEqual(google?.newCustomers, 1, "google: one customer created in March")
    expectEqual(google?.estimatesSent, 4, "google: j1, j2, j3 (approval fallback) and j5 (name fallback) sent in March")
    expectEqual(google?.jobsWon, 3, "google: declined j2 is sent but not won")
    expectEqual(google?.closeRate, Decimal(3) / Decimal(4), "google: close rate 3/4")
    expectEqual(google?.collected, Decimal(400), "google: the voided payment is excluded")

    let homeShow = row(report, "custom:home show")
    expectEqual(homeShow?.displayName, "Home show", "custom: first-seen spelling")
    expectEqual(homeShow?.newCustomers, 1, "custom: the UTC-stamped customer is March local; the Feb one is not new")
    expectEqual(homeShow?.estimatesSent, 1, "custom: the archived customer's archived job counts; Feb send does not")
    expectEqual(homeShow?.jobsWon, 1, "custom: complete is won")
    expectEqual(homeShow?.collected, Decimal(300), "custom: both 23:30-local payments on the last day count")

    let referral = row(report, "referral")
    expectEqual(referral?.displayName, "Referral / word of mouth", "referral: alias normalized to the preset")
    expectEqual(referral?.newCustomers, 0, "referral: created in January")
    expectEqual(referral?.estimatesSent, 0, "referral: nothing sent")
    expect(referral?.closeRate == nil, "referral: close rate is nil when nothing was sent")
    expectEqual(referral?.collected, Decimal(300), "referral: a dangling id falls back to the name (legacy paidAt)")

    for key in ["nextdoor", "yelp"] {
        let quiet = row(report, key)
        expect(quiet != nil, "\(key): a source with customers but no activity still has a row")
        expectEqual(quiet?.collected, Decimal(0), "\(key): zero collected")
        expect(quiet?.closeRate == nil, "\(key): no close rate")
    }

    let unknown = row(report, "unknown")
    expectEqual(unknown?.displayName, "Unknown", "unknown: display name")
    expectEqual(unknown?.newCustomers, 1, "unknown: the March customer with no source")
    expectEqual(unknown?.estimatesSent, 1, "unknown: the dangling, unmatched job")
    expectEqual(unknown?.jobsWon, 0, "unknown: estimate_sent is not won")
    expectEqual(unknown?.closeRate, Decimal(0), "unknown: 0 of 1 is a 0% close rate, not nil")
    expectEqual(unknown?.collected, Decimal(70), "unknown: dangling-unmatched plus ambiguous-name payments")

    let control = NativeCashBasis.collected(invoices: fixtureInvoices, start: march.start, end: march.end)
    expectEqual(control, Decimal(1070), "control: NativeCashBasis March total")
    expectEqual(report.totalCollected, control, "control total: Σ bucket collected == NativeCashBasis.collected")

    let allTime = NativeCashBasis.range(for: "all_time", now: march10)
    let lifetime = NativeLeadSourceReport.make(
        customers: fixtureCustomers, jobs: fixtureJobs, invoices: fixtureInvoices,
        start: allTime.start, end: allTime.end
    )
    expectEqual(lifetime.totalCollected,
                NativeCashBasis.collected(invoices: fixtureInvoices, start: allTime.start, end: allTime.end),
                "control total holds all time")
    expectEqual(row(lifetime, "custom:home show")?.collected, Decimal(1300), "all time: the archived customer's revenue")
}

func testReportLocalDateEdges() {
    let report = NativeLeadSourceReport.make(
        customers: fixtureCustomers, jobs: fixtureJobs, invoices: fixtureInvoices,
        start: april.start, end: april.end
    )
    expectEqual(row(report, "custom:home show")?.collected, Decimal(0),
                "April: the 06:30Z Apr 1 payment is Mar 31 local, not April")
    expectEqual(row(report, "custom:home show")?.newCustomers, 0, "April: the 05:00Z Apr 1 customer is March")
    expectEqual(row(report, "google")?.estimatesSent, 0, "April: the 06:30Z Apr 1 approval is March")
    expectEqual(row(report, "referral")?.collected, Decimal(75), "April: a bare Apr 1 date is April")
    expectEqual(report.totalCollected,
                NativeCashBasis.collected(invoices: fixtureInvoices, start: april.start, end: april.end),
                "April control total")
    expectEqual(row(report, "unknown")?.collected, Decimal(0), "April: Unknown (a customer with no source) is zero")
    let sourced = fixtureCustomers.filter { $0.leadSource != nil }
    let sourcedOnly = NativeLeadSourceReport.make(customers: sourced, jobs: [], invoices: [],
                                                  start: april.start, end: april.end)
    expect(row(sourcedOnly, "unknown") == nil, "no unsourced customer and no unattributable activity: no Unknown row")
}

func testReportAttributionEdges() {
    let customers = [
        customer("a1", "Lee Pair", source: "facebook"),
        customer("a2", " lee pair", source: "Facebook Ads"),
        customer("a3", "Solo", source: "mailer"),
    ]
    let invoices = [
        // Same name, same bucket: not ambiguous.
        invoice("x1", customerId: nil, name: "LEE PAIR", payments: [payment("q1", 10, "2026-03-02")]),
        // A resolvable id wins over a name that points elsewhere.
        invoice("x2", customerId: "a3", name: "Lee Pair", payments: [payment("q2", 20, "2026-03-02")]),
        // Empty id and empty name: Unknown.
        invoice("x3", customerId: "", name: "  ", payments: [payment("q3", 5, "2026-03-02")]),
    ]
    let report = NativeLeadSourceReport.make(customers: customers, jobs: [], invoices: invoices,
                                             start: march.start, end: march.end)
    expectEqual(report.rows.map(\.bucketKey), ["mailer", "facebook", "unknown"], "attribution: buckets and order")
    expectEqual(row(report, "facebook")?.collected, Decimal(10), "attribution: duplicate names in one bucket resolve")
    expectEqual(row(report, "mailer")?.collected, Decimal(20), "attribution: the id beats the name")
    expectEqual(row(report, "unknown")?.collected, Decimal(5), "attribution: nothing to match is Unknown")
    expectEqual(row(report, "unknown")?.newCustomers, 0, "attribution: Unknown with no customers")

    let empty = NativeLeadSourceReport.make(customers: [], jobs: [], invoices: [], start: march.start, end: march.end)
    expectEqual(empty.rows.count, 0, "empty inputs: no rows")
    expect(!empty.hasAnySource, "empty inputs: no source")
}

func testReportCustomLabelSpelling() {
    let customers = [
        customer("s1", "One", source: "home  SHOW"),
        customer("s2", "Two", source: "Home show"),
        customer("s3", "Three", source: "Zeta expo"),
        customer("s4", "Four", source: "alpha fair"),
    ]
    let report = NativeLeadSourceReport.make(customers: customers, jobs: [], invoices: [],
                                             start: march.start, end: march.end)
    expectEqual(report.rows.map(\.displayName), ["alpha fair", "home SHOW", "Zeta expo"],
                "custom: case-merged, first-seen spelling, ties sorted by name case-insensitively")
}

func testReportWithoutSources() {
    let report = NativeLeadSourceReport.make(
        customers: [customer("n1", "Nia", createdAt: "2026-03-02"), customer("n2", "Ola")],
        jobs: [job("nj", customerId: "n1", status: "approved", sentAt: "2026-03-03")],
        invoices: [invoice("ni", customerId: "n1", name: "Nia", payments: [payment("np", 90, "2026-03-04")])],
        start: march.start, end: march.end
    )
    expect(!report.hasAnySource, "no sources: flagged for the setup hint")
    expectEqual(report.rows.map(\.bucketKey), ["unknown"], "no sources: only Unknown")
    expectEqual(report.rows.first?.newCustomers, 1, "no sources: Unknown counts the new customer")
    expectEqual(report.rows.first?.collected, Decimal(90), "no sources: Unknown carries the revenue")
}

// MARK: - Coach block

func testSnapshotBlock() {
    let presets = ["referral", "google", "facebook", "nextdoor", "yelp", "thumbtack_angi", "signage", "website"]
    var customers: [Canonical.Customer] = []
    var invoices: [Canonical.Invoice] = []
    for (index, key) in presets.enumerated() {
        customers.append(customer("y\(index)", "Cust \(index)", source: key))
        // referral collects 100, google 200, …, website 800 (all this year).
        invoices.append(invoice("yi\(index)", customerId: "y\(index)", name: "Cust \(index)",
                                payments: [payment("yp\(index)", Double((index + 1) * 100), "2026-02-0\(index + 1)")]))
    }
    // Last year's money is outside year to date.
    invoices.append(invoice("old", customerId: "y0", name: "Cust 0", payments: [payment("op", 5000, "2025-12-31")]))
    let jobs = [
        job("yj1", customerId: "y7", status: "approved", sentAt: "2026-01-05"),
        job("yj2", customerId: "y7", status: "declined", sentAt: "2026-01-06"),
        job("yj3", customerId: "y7", status: "lead", sentAt: "2026-01-07"),
    ]

    let withoutUnknown = NativeLeadSourceReport.snapshotBlock(customers: customers, jobs: jobs, invoices: invoices, now: march10)
    expectEqual(withoutUnknown?.rows.map(\.name),
                ["Website", "Truck or yard sign", "Thumbtack / Angi", "Yelp", "Nextdoor", "Facebook"],
                "coach block: top 6 by year-to-date collected; Unknown omitted when it collected nothing")
    expectEqual(withoutUnknown?.rows.first,
                NativeLeadSourceSnapshotRow(name: "Website", collected: 800, won: 1, sent: 3,
                                            closeRate: Decimal(1) / Decimal(3)),
                "coach block: collected, won, sent and close rate")
    expect(withoutUnknown?.rows[1].closeRate == nil, "coach block: nil close rate when nothing was sent")

    let unknownInvoice = invoice("u", customerId: "gone", name: "Stranger", payments: [payment("up", 1, "2026-03-01")])
    let withUnknown = NativeLeadSourceReport.snapshotBlock(customers: customers, jobs: jobs,
                                                           invoices: invoices + [unknownInvoice], now: march10)
    expectEqual(withUnknown?.rows.count, 7, "coach block: 6 sources plus Unknown")
    expectEqual(withUnknown?.rows.last?.name, "Unknown", "coach block: Unknown last when it collected money")
    expectEqual(withUnknown?.rows.last?.collected, Decimal(1), "coach block: Unknown's collected")

    let none = NativeLeadSourceReport.snapshotBlock(
        customers: [customer("z", "Zoe")], jobs: [], invoices: [unknownInvoice], now: march10
    )
    expect(none == nil, "coach block: absent (not zeroed) when no customer has a source")

    let few = NativeLeadSourceReport.snapshotBlock(
        customers: [customer("f", "Fay", source: "yelp")], jobs: [], invoices: [], now: march10
    )
    expectEqual(few?.rows, [NativeLeadSourceSnapshotRow(name: "Yelp", collected: 0, won: 0, sent: 0, closeRate: nil)],
                "coach block: a source with no activity still reads as zero")
}

testNormalize()
testNormalizePlaceholders()
testBuckets()
testExportLabel()
testReportMath()
testReportLocalDateEdges()
testReportAttributionEdges()
testReportCustomLabelSpelling()
testReportWithoutSources()
testSnapshotBlock()

if failures == 0 {
    print("PASS: lead source tests (\(checks) checks)")
} else {
    print("lead source tests: \(failures) of \(checks) checks FAILED")
    exit(1)
}
