import Foundation

// Coach prompt + quick-prompt tests (task 10.10, requirements C2, C3).
//
// `buildSystemPrompt` / `getQuickPrompts` live inside `screens/ChatScreen.tsx`
// and have no dedicated RN oracle test file, so these fixtures were pinned by
// running the exact function bodies (copied verbatim, including the
// `TRADE_TYPES` table from `utils/pricingEngine.ts`) through a scratch Node
// probe and recording the actual output — see the 10.10 report for the full
// probe transcript and each fixture's provenance.

private var failures = 0

private func expectEqual(_ actual: String, _ expected: String, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(String(reflecting: expected))\n  actual:   \(String(reflecting: actual))")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected { failures += 1; print("FAIL: \(label) — expected \(expected), got \(actual)") }
}

private func settings(
    businessName: String = "Ace Plumbing",
    contactName: String = "Sam",
    trade: String = "plumbing",
    region: String? = nil,
    laborRate: Decimal = 0,
    materialMarkup: Decimal = 0,
    overheadPercent: Decimal = 0,
    marginPercent: Decimal = 0,
    minimumJobFee: Decimal = 0,
    anthropicKey: String = "",
    groqKey: String = ""
) -> Canonical.Settings {
    let json = """
    {
      "businessName": "\(businessName)", "contactName": "\(contactName)", "phone": "", "email": "", "address": "",
      \(region.map { "\"region\": \"\($0)\"," } ?? "")
      "trade": "\(trade)", "laborRate": \(laborRate), "materialMarkup": \(materialMarkup),
      "overheadPercent": \(overheadPercent), "marginPercent": \(marginPercent), "minimumJobFee": \(minimumJobFee),
      "travelFeePerMile": 0, "emergencyMultiplier": 1, "mileageRate": 0.67,
      "paymentNotes": "", "provider": "stripe", "providerKey": "", "providerKeys": {},
      "rules": [], "autoOutreachEnabled": false, "autoSendEmailEnabled": false,
      "appointmentRemindersEnabled": false, "appointmentConfirmTemplate": "", "onMyWayTemplate": "",
      "estimateFollowUpsEnabled": false, "autoInvoiceOnComplete": false, "autoEmailInvoiceOnComplete": false,
      "anthropicKey": "\(anthropicKey)", "groqKey": "\(groqKey)", "reviewRequestEnabled": false,
      "reviewRequestTemplate": "", "googleReviewLink": "", "reviewRequestDelayHours": 24
    }
    """
    return try! JSONDecoder().decode(Canonical.Settings.self, from: Data(json.utf8))
}

private func topCustomer(_ name: String, lifetime: Decimal, owed: Decimal) -> NativeTopCustomerEntry {
    NativeTopCustomerEntry(name: name, lifetimeSpend: lifetime, amountOwed: owed)
}

private func snapshot(
    asOf: String = "2026-09-22",
    activeJobsByStatus: [String: Int] = [:],
    topCustomers: [NativeTopCustomerEntry] = [],
    overdueCount: Int = 0,
    overdueTotal: Decimal = 0,
    revenueThisMonth: Decimal = 0,
    revenueLastMonth: Decimal = 0,
    outstandingTotal: Decimal = 0,
    totalCustomers: Int = 0,
    avgCompletedJobValue: Decimal = 0,
    tax: NativeTaxSnapshotBlock? = nil
) -> NativeBusinessSnapshot {
    NativeBusinessSnapshot(
        asOf: asOf,
        aggregate: NativeBusinessSnapshotAggregate(
            revenueThisMonth: revenueThisMonth, revenueLastMonth: revenueLastMonth,
            outstandingTotal: outstandingTotal, overdueTotal: overdueTotal, overdueCount: overdueCount,
            activeJobsByStatus: activeJobsByStatus, totalCustomers: totalCustomers,
            topCustomers: topCustomers, avgCompletedJobValue: avgCompletedJobValue
        ),
        tax: tax
    )
}

// MARK: - buildSystemPrompt fixtures (pinned to the Node probe transcript)

private func testNoSnapshotMinimalSettings() {
    let prompt = NativeCoachPrompt.buildSystemPrompt(settings: settings(), snapshot: nil)
    expectEqual(
        prompt,
        "Assistant for Ace Plumbing, Plumbing, Sam. Rates: $85/hr labor, 20% materials markup, " +
            "15% overhead, 20% margin, $75 min fee. Be brief. Itemize estimates. USD only.",
        "no-snapshot, minimal settings: unset rates fall back to their RN defaults"
    )
}

private func testDefaultsAndRegionUnknownTrade() {
    let prompt = NativeCoachPrompt.buildSystemPrompt(
        settings: settings(contactName: "", trade: "unknown_trade", region: "Phoenix, AZ"),
        snapshot: nil
    )
    expectEqual(
        prompt,
        "Assistant for Ace Plumbing, Trades. Region: Phoenix, AZ. Rates: $85/hr labor, 20% materials markup, " +
            "15% overhead, 20% margin, $75 min fee. Be brief. Itemize estimates. USD only.",
        "an unmatched trade id falls back to \"Trades\"; an empty contactName is dropped from \"who\""
    )
}

private let fullSnapshot = snapshot(
    activeJobsByStatus: ["lead": 2, "estimate_sent": 1, "in_progress": 1],
    topCustomers: [topCustomer("Sam Reilly", lifetime: 4200, owed: 300), topCustomer("Jo Park", lifetime: 1200, owed: 0)],
    overdueCount: 2, overdueTotal: 850,
    revenueThisMonth: 4200, revenueLastMonth: 3100, outstandingTotal: 1200,
    totalCustomers: 8, avgCompletedJobValue: 620,
    tax: NativeTaxSnapshotBlock(
        periodReserve: 900, yearToDateReserve: 3400, periodLabel: "Jun 1 – Aug 31", dueLabel: "Sep 15",
        incomeRateSet: true, needsVehicleChoice: false, ratesKnown: true
    )
)

private func testFullSnapshot() {
    let prompt = NativeCoachPrompt.buildSystemPrompt(
        settings: settings(laborRate: 90, materialMarkup: 25, overheadPercent: 15, marginPercent: 20, minimumJobFee: 75),
        snapshot: fullSnapshot
    )
    expectEqual(
        prompt,
        "Assistant for Ace Plumbing, Plumbing, Sam. Rates: $90/hr labor, 25% materials markup, 15% overhead, " +
            "20% margin, $75 min fee. Be brief. Itemize estimates. USD only." +
            "BUSINESS DATA (2026-09-22):\n" +
            "Revenue: $4200 this month, $3100 last month.\n" +
            "Outstanding: $1200 ($850 overdue, 2 invoices).\n" +
            "Active jobs: 2 lead, 1 estimate sent, 1 in progress.\n" +
            "Customers: 8 total. Top: Sam Reilly ($4200 lifetime, owes $300); Jo Park ($1200 lifetime).\n" +
            "Avg completed job: $620.\n" +
            "Tax set-aside estimate: $900 for Jun 1 – Aug 31 (set aside by Sep 15); $3400 year to date. " +
            "You may cite these as set-aside guidance only — for filing, deduction elections, eligibility, " +
            "or business-entity questions, decline and refer the user to a tax professional.",
        "full snapshot: the BUSINESS DATA block's leading blank line is trimmed away (RN's `.trim()` quirk), " +
            "the tax block keeps its own leading newline, and both known-rate caveats are absent"
    )
}

private func testSnapshotTaxBlockAbsent() {
    let prompt = NativeCoachPrompt.buildSystemPrompt(settings: settings(), snapshot: snapshot(
        activeJobsByStatus: ["lead": 2, "estimate_sent": 1, "in_progress": 1],
        topCustomers: [topCustomer("Sam Reilly", lifetime: 4200, owed: 300), topCustomer("Jo Park", lifetime: 1200, owed: 0)],
        overdueCount: 2, overdueTotal: 850,
        revenueThisMonth: 4200, revenueLastMonth: 3100, outstandingTotal: 1200,
        totalCustomers: 8, avgCompletedJobValue: 620,
        tax: nil
    ))
    expectEqual(
        prompt,
        "Assistant for Ace Plumbing, Plumbing, Sam. Rates: $85/hr labor, 20% materials markup, 15% overhead, " +
            "20% margin, $75 min fee. Be brief. Itemize estimates. USD only." +
            "BUSINESS DATA (2026-09-22):\n" +
            "Revenue: $4200 this month, $3100 last month.\n" +
            "Outstanding: $1200 ($850 overdue, 2 invoices).\n" +
            "Active jobs: 2 lead, 1 estimate sent, 1 in progress.\n" +
            "Customers: 8 total. Top: Sam Reilly ($4200 lifetime, owes $300); Jo Park ($1200 lifetime).\n" +
            "Avg completed job: $620.",
        "an input failure omits the tax block entirely — it is never rendered as zeroed"
    )
}

private func testSnapshotTaxUnknownBothCaveats() {
    let taxUnknown = NativeTaxSnapshotBlock(
        periodReserve: 300, yearToDateReserve: 900, periodLabel: "Jun 1 – Aug 31", dueLabel: "Sep 15",
        incomeRateSet: false, needsVehicleChoice: true, ratesKnown: false
    )
    let prompt = NativeCoachPrompt.buildSystemPrompt(settings: settings(), snapshot: snapshot(
        activeJobsByStatus: ["lead": 2, "estimate_sent": 1, "in_progress": 1],
        topCustomers: [topCustomer("Sam Reilly", lifetime: 4200, owed: 300), topCustomer("Jo Park", lifetime: 1200, owed: 0)],
        overdueCount: 2, overdueTotal: 850,
        revenueThisMonth: 4200, revenueLastMonth: 3100, outstandingTotal: 1200,
        totalCustomers: 8, avgCompletedJobValue: 620,
        tax: taxUnknown
    ))
    expect(prompt.hasSuffix(
        "Tax set-aside estimate: $300 for Jun 1 – Aug 31 (set aside by Sep 15); $900 year to date. " +
            "Income-tax rate not set — figure is SE tax only. Vehicle deduction method not chosen. " +
            "You may cite these as set-aside guidance only — for filing, deduction elections, eligibility, " +
            "or business-entity questions, decline and refer the user to a tax professional."
    ), "tax-unknown snapshot: both caveats appear, income-rate caveat before vehicle caveat")
}

private func testSnapshotAllEmptyZero() {
    let prompt = NativeCoachPrompt.buildSystemPrompt(
        settings: settings(contactName: ""),
        snapshot: snapshot()
    )
    expectEqual(
        prompt,
        "Assistant for Ace Plumbing, Plumbing. Rates: $85/hr labor, 20% materials markup, 15% overhead, " +
            "20% margin, $75 min fee. Be brief. Itemize estimates. USD only." +
            "BUSINESS DATA (2026-09-22):\n" +
            "Revenue: $0 this month, $0 last month.\n" +
            "Outstanding: $0.\n" +
            "Active jobs: none.\n" +
            "Customers: 0 total.",
        "an all-zero/empty snapshot renders \"none\" for active jobs and omits every optional clause"
    )
}

private func testSnapshotSingleOverdueInvoiceSingular() {
    let prompt = NativeCoachPrompt.buildSystemPrompt(
        settings: settings(contactName: ""),
        snapshot: snapshot(overdueCount: 1, overdueTotal: 150)
    )
    expect(prompt.contains("Outstanding: $0 ($150 overdue, 1 invoice)."), "a single overdue invoice uses the singular \"invoice\", not \"invoices\"")
}

private func testKeyNeverEntersPrompt() {
    let secretAnthropic = "sk-ant-api03-super-secret-value"
    let secretGroq = "gsk_super_secret_groq_value"
    let leaky = settings(anthropicKey: secretAnthropic, groqKey: secretGroq)
    let prompt = NativeCoachPrompt.buildSystemPrompt(settings: leaky, snapshot: fullSnapshot)
    expect(!prompt.contains(secretAnthropic), "the built system prompt never contains the Anthropic key")
    expect(!prompt.contains(secretGroq), "the built system prompt never contains the Groq key")
}

// MARK: - getQuickPrompts fixtures

private func expectPromptIDs(_ prompts: [NativeCoachQuickPrompt], _ expected: [String], _ label: String) {
    expectEqual(prompts.map(\.id), expected, label)
}

private func testQuickPromptsNoSnapshot() {
    let prompts = NativeCoachQuickPrompts.quickPrompts(snapshot: nil)
    expectPromptIDs(prompts, ["month", "unpaid", "estimate", "price"], "no snapshot: both branches fall back")
    expectEqual(prompts[2].text, "Help me write a professional estimate to send to a customer.", "no-overdue fallback text")
    expectEqual(prompts[3].text, "I need help pricing a job. What details do you need from me?", "no-avgJob fallback text")
}

private func testQuickPromptsOverdueAndAvgJob() {
    let prompts = NativeCoachQuickPrompts.quickPrompts(snapshot: fullSnapshot)
    expectPromptIDs(prompts, ["month", "unpaid", "overdue", "profit"], "overdue>0 and avgJob>0 both branch live")
    expectEqual(
        prompts[2].text,
        "I have 2 overdue invoices totaling $850. Write a professional but firm follow-up message I can send.",
        "overdue branch carries the live count/amount, plural \"invoices\""
    )
    expectEqual(
        prompts[3].text,
        "My average completed job is around $620. What are practical ways I can increase my average job value and profit margin?",
        "profit branch carries the live average"
    )
}

private func testQuickPromptsSingleOverdueSingular() {
    let prompts = NativeCoachQuickPrompts.quickPrompts(snapshot: snapshot(overdueCount: 1, overdueTotal: 150))
    expectEqual(
        prompts[2].text,
        "I have 1 overdue invoice totaling $150. Write a professional but firm follow-up message I can send.",
        "a single overdue invoice uses the singular \"invoice\""
    )
    expectEqual(prompts[3].id, "price", "avgJob is 0, so the price fallback is used")
}

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

// MARK: - Runner

testNoSnapshotMinimalSettings()
testDefaultsAndRegionUnknownTrade()
testFullSnapshot()
testSnapshotTaxBlockAbsent()
testSnapshotTaxUnknownBothCaveats()
testSnapshotAllEmptyZero()
testSnapshotSingleOverdueInvoiceSingular()
testKeyNeverEntersPrompt()
testQuickPromptsNoSnapshot()
testQuickPromptsOverdueAndAvgJob()
testQuickPromptsSingleOverdueSingular()

if failures == 0 {
    print("CoachPromptTests: all checks passed")
} else {
    print("CoachPromptTests: \(failures) failure(s)")
    exit(1)
}
