import Foundation

// Tax set-aside settings + card tests (task 9.02).
//
// Ports the summarizeTaxWindow vectors from __tests__/taxEstimate.test.js and
// the settings-sheet rules from TaxSettingsModal.tsx, plus the TaxSetAsideCard
// copy. Engine math is already covered by native/DomainTests; these checks pin
// the settings mapping, optional semantics, and displayed strings.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func settings(_ extra: String = "") -> Canonical.Settings {
    let tail = extra.isEmpty ? "" : ",\(extra)"
    let base = """
    {"businessName":"B","contactName":"","phone":"","email":"","address":"","trade":"Plumbing",
     "laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,"minimumJobFee":75,
     "travelFeePerMile":0,"emergencyMultiplier":1.5,"paymentNotes":"","provider":"stripe","rules":[]\(tail)}
    """
    return try! JSONDecoder().decode(Canonical.Settings.self, from: Data(base.utf8))
}

private func invoice(_ json: String) -> LedgerInvoice {
    try! JSONDecoder().decode(LedgerInvoice.self, from: Data(json.utf8))
}

// MARK: - canonical mapping + optional semantics

private func testCanonicalMapping() {
    let unset = NativeTaxSettingsValues(from: settings())
    expect(unset.taxIncomeRate == nil, "absent rate stays absent (not zero)")
    expect(unset.vehicleDeductionMethod == nil, "absent method stays absent")

    let configured = NativeTaxSettingsValues(from: settings(#""taxIncomeRate":12.5,"vehicleDeductionMethod":"actual""#))
    expectEqual(configured.taxIncomeRate, decimal("12.5"), "rate read from canonical")
    expectEqual(configured.vehicleDeductionMethod, .actual, "method read from canonical")

    let zeroRate = NativeTaxSettingsValues(from: settings(#""taxIncomeRate":0"#))
    expect(NativeTaxSettings.incomeRateSet(zeroRate), "0 counts as set")
    expect(!NativeTaxSettings.incomeRateSet(unset), "absent is not set")

    let engineSettings = configured.taxWindowSettings
    expectEqual(engineSettings.incomeRatePercent, decimal("12.5"), "engine rate")
    expectEqual(engineSettings.vehicleDeductionMethod, .actual, "engine method")
    expectEqual(engineSettings.mileageRate, decimal("0.70"), "engine mileage default")
}

// MARK: - sheet validation + merge semantics

private func testDraftRules() {
    expectEqual(NativeTaxSettings.parseRateInput(""), .success(nil), "blank rate means no change")
    expectEqual(NativeTaxSettings.parseRateInput("   "), .success(nil), "whitespace rate means no change")
    expectEqual(NativeTaxSettings.parseRateInput("0"), .success(0), "zero is valid")
    expectEqual(NativeTaxSettings.parseRateInput("60"), .success(60), "sixty is the upper bound")
    expectEqual(NativeTaxSettings.parseRateInput("12.5"), .success(decimal("12.5")), "decimal rate")
    expectEqual(NativeTaxSettings.parseRateInput("60.5"), .failure(.rateOutOfRange), "above 60 refused")
    expectEqual(NativeTaxSettings.parseRateInput("-1"), .failure(.rateOutOfRange), "negative refused")
    expectEqual(NativeTaxSettings.parseRateInput("abc"), .failure(.rateOutOfRange), "non-numeric refused")

    let noChange = NativeTaxSettings.applying(NativeTaxSettingsDraft(), to: ["businessName": .string("B")])
    expect(!noChange.keys.contains("taxIncomeRate"), "no-change draft does not invent the rate key")
    expect(!noChange.keys.contains("vehicleDeductionMethod"), "no-change draft does not invent the method key")
    expectEqual(noChange["businessName"], .string("B"), "unrelated fields survive")

    let withRate = NativeTaxSettings.applying(NativeTaxSettingsDraft(taxIncomeRate: 18), to: [:])
    expectEqual(withRate["taxIncomeRate"], .number(18), "rate written")
    expect(!withRate.keys.contains("vehicleDeductionMethod"), "method still absent")

    let existing = NativeTaxSettings.applying(
        NativeTaxSettingsDraft(vehicleDeductionMethod: .mileage),
        to: ["taxIncomeRate": .number(9), "trade": .string("Plumbing")]
    )
    expectEqual(existing["vehicleDeductionMethod"], .string("mileage"), "method written")
    expectEqual(existing["taxIncomeRate"], .number(9), "existing rate preserved")

    let fullFields = NativeTaxSettings.canonicalFields(NativeTaxSettingsValues(taxIncomeRate: 0))
    expectEqual(fullFields["taxIncomeRate"], .number(0), "explicit zero is written")
    expect(!fullFields.keys.contains("vehicleDeductionMethod"), "absent method not written in a full write")
}

// MARK: - summarizeTaxWindow + card copy (taxEstimate.test.js)

private func summarize(settings taxSettings: TaxWindowSettings) -> TaxWindowSummary {
    let invoices = [
        invoice(#"{"id":"i1","amount":5000,"due":"2026-07-01","paid":false,"payments":[{"id":"p1","amount":1000,"date":"2026-06-15","method":"cash"},{"id":"p2","amount":500,"date":"2026-02-10","method":"cash"}]}"#),
        invoice(#"{"id":"i2","amount":800,"due":"2026-04-20","paid":true,"paidAt":"2026-04-20"}"#),
    ]
    let expenses = [
        TaxExpense(amount: 300, category: "materials", date: "2026-07-02"),
        TaxExpense(amount: 200, category: "fuel", date: "2026-07-01"),
        TaxExpense(amount: 100, category: "tools", date: "2026-03-01"),
    ]
    let trips = [
        TaxTrip(date: "2026-06-20", miles: 100),
        TaxTrip(date: "2026-01-15", miles: 50),
    ]
    return TaxEstimateEngine.summarize(
        invoices: invoices, expenses: expenses, trips: trips, settings: taxSettings, on: "2026-07-18"
    )
}

private func testTaxWindowAndCopy() {
    let values = NativeTaxSettingsValues(taxIncomeRate: 10, vehicleDeductionMethod: .mileage)
    let mileage = summarize(settings: values.taxWindowSettings)
    expectEqual(mileage.period.quarter, 3, "July 18 2026 is period 3")
    expectEqual(mileage.current.netProfit, decimal("630"), "Q3 net profit with mileage deduction")
    expectEqual(mileage.yearToDate.netProfit, decimal("1795"), "YTD net profit")
    expect(!mileage.needsVehicleChoice, "mileage chosen")
    expect(mileage.incomeRateSet, "rate set")
    expectEqual(mileage.yearToDateTripCount, 2, "YTD trip count")

    let actual = summarize(settings: NativeTaxSettingsValues(taxIncomeRate: 10, vehicleDeductionMethod: .actual).taxWindowSettings)
    expectEqual(actual.current.netProfit, decimal("500"), "actual method deducts fuel instead")

    let unset = summarize(settings: NativeTaxSettingsValues().taxWindowSettings)
    expectEqual(unset.current.netProfit, decimal("700"), "unset method deducts neither")
    expect(unset.needsVehicleChoice, "unset method flags the choice")
    expect(!unset.incomeRateSet, "unset rate flagged")
    expectEqual(unset.current.incomeTax, 0, "unset rate yields no income tax")

    let card = NativeTaxBreakdown.make(summary: unset, values: NativeTaxSettingsValues())
    expectEqual(card.periodRangeText, "Jun 1 – Aug 31", "period range text")
    expectEqual(card.deadlineText, "Sep 15", "deadline text")
    expectEqual(card.periodSummaryText, "Jun 1 – Aug 31 · set aside by Sep 15", "period summary line")
    expectEqual(card.vehiclePrompt, NativeTaxBreakdownCopy.vehiclePrompt, "vehicle prompt shown")
    expectEqual(card.incomeRatePrompt, NativeTaxBreakdownCopy.incomeRatePrompt, "income-rate prompt shown")
    expect(card.staleRatesNote == nil, "rates are known for 2026")
    expect(card.yearToDateText.hasSuffix(" for the year so far"), "YTD line formats money and labels the year")
    expectEqual(card.disclaimer, "Estimate only — not tax advice. Assumes net profit under $200k.", "disclaimer")
    expectEqual(card.mileageDisclosure, "Mileage from this device's trip log (2 trips this year) — not synced.", "disclosure plural")
    expectEqual(NativeTaxBreakdownCopy.mileageDisclosure(tripCount: 1), "Mileage from this device's trip log (1 trip this year) — not synced.", "disclosure singular")

    let configured = NativeTaxBreakdown.make(summary: mileage, values: values)
    expect(configured.vehiclePrompt == nil, "no vehicle prompt once chosen")
    expect(configured.incomeRatePrompt == nil, "no rate prompt once set")
    expectEqual(configured.currentReserve, mileage.current.reserve, "reserve surfaced")

    // A Q4 date in an unknown tax year: the deadline lands in the next year and
    // the versioned wage-base table has no entry, so the stale-rates note shows.
    let unknown = TaxEstimateEngine.summarize(
        invoices: [], expenses: [], trips: [],
        settings: NativeTaxSettingsValues(taxIncomeRate: 0).taxWindowSettings,
        on: "2030-10-05"
    )
    let unknownCard = NativeTaxBreakdown.make(summary: unknown, values: NativeTaxSettingsValues(taxIncomeRate: 0))
    expectEqual(unknownCard.staleRatesNote, NativeTaxBreakdownCopy.staleRatesNote, "stale rates note for unknown year")
    expectEqual(unknownCard.deadlineText, "Jan 15, 2031", "Q4 deadline carries the year")
    expectEqual(unknownCard.periodRangeText, "Sep 1 – Dec 31", "Q4 period range")

    let voided = TaxEstimateEngine.summarize(
        invoices: [invoice(#"{"id":"i3","amount":1000,"due":"2026-07-01","paid":false,"payments":[{"id":"p9","amount":1000,"date":"2026-06-15","method":"cash","voidedAt":"2026-06-16"}]}"#)],
        expenses: [], trips: [],
        settings: TaxWindowSettings(), on: "2026-07-18"
    )
    expectEqual(voided.current.netProfit, 0, "voided payment excluded")
    expectEqual(voided.current.reserve, 0, "voided payment yields a zero reserve")
}

// MARK: - run

testCanonicalMapping()
testDraftRules()
testTaxWindowAndCopy()

if failures == 0 {
    print("TaxSettingsTests: all checks passed")
} else {
    print("TaxSettingsTests: \(failures) failure(s)")
    exit(1)
}
