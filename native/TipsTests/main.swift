import Foundation

// Phase 28 (tips on online payments, spec 2026-10-03-tips-design.md §6, §8)
// native host tests: the canonical model round trip, ledger invariants,
// `tips` / `received` / `receivedByPeriod`, the Money card caption, the CSV and
// accountant-package tip rows, the tax set-aside, the lead-source control
// total, the UI adapters and the Settings toggle state.
//
// Run with TZ=America/Phoenix: the date-range edges assume a west-of-UTC zone
// (FA-039). The runner also sets CANONICAL_FIXTURES_PATH for the rich settings
// fixture.

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    // A throwing condition (an adapter or encode error) counts as a failure.
    if (try? condition()) != true {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func run(_ label: String, _ body: () throws -> Void) {
    do { try body() } catch { failures += 1; print("FAIL: \(label) — \(error)") }
}

private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! decoder.decode(T.self, from: Data(json.utf8))
}

private func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
    try decoder.decode(Canonical.JSONValue.self, from: encoder.encode(value))
}

private func object<T: Encodable>(_ value: T) throws -> [String: Canonical.JSONValue] {
    guard case let .object(result) = try json(value) else { fatalError("expected object") }
    return result
}

private func invoice(_ json: String) -> Canonical.Invoice { decode(Canonical.Invoice.self, json) }

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    // `month` is 1-based here; NativeCashBasis.localDate is 0-based.
    NativeCashBasis.localDate(year: year, month: month - 1, day: day)
}

private func endOfDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    NativeCashBasis.localDate(year: year, month: month - 1, day: day, hour: 23, minute: 59, second: 59)
}

private let marchStart = day(2026, 3, 1)
private let marchEnd = endOfDay(2026, 3, 31)

// MARK: - Fixtures

/// $120 invoice paid exactly by a $120 Stripe payment plus an $18 tip.
private let tipped = invoice(#"""
{"id":"inv1","customer":"Alice","customerId":"c1","number":"INV-001","amount":120,"due":"2026-03-05",
 "email":"","phone":"","desc":"Faucet","paid":true,"paidAt":"2026-03-10",
 "payments":[{"id":"stripe_cs_1","amount":120,"date":"2026-03-10","method":"stripe","stripeSessionId":"cs_1","tipAmount":18}]}
"""#)

/// A cash invoice with no tip.
private let plain = invoice(#"""
{"id":"inv2","customer":"Bob","customerId":"c2","number":"INV-002","amount":200,"due":"2026-03-05",
 "email":"","phone":"","desc":"","paid":true,"paidAt":"2026-03-11",
 "payments":[{"id":"p1","amount":200,"date":"2026-03-11","method":"cash"}]}
"""#)

/// A voided Stripe payment: the tip is voided with it.
private let voided = invoice(#"""
{"id":"inv3","customer":"Cy","customerId":"c3","number":"INV-003","amount":100,"due":"2026-03-05",
 "email":"","phone":"","desc":"","paid":false,
 "payments":[{"id":"stripe_cs_3","amount":100,"date":"2026-03-12","method":"stripe","stripeSessionId":"cs_3","voidedAt":"2026-03-13","tipAmount":5}]}
"""#)

/// Tips on the window edges (Phoenix, FA-039): Feb 28 and Apr 1 fall outside March.
private let edges = invoice(#"""
{"id":"inv4","customer":"Di","customerId":"c4","number":"INV-004","amount":40,"due":"2026-03-05",
 "email":"","phone":"","desc":"","paid":true,"paidAt":"2026-04-01",
 "payments":[
  {"id":"stripe_e0","amount":10,"date":"2026-02-28","method":"stripe","tipAmount":2},
  {"id":"stripe_e1","amount":10,"date":"2026-03-01","method":"stripe","tipAmount":1},
  {"id":"stripe_e2","amount":10,"date":"2026-03-31","method":"stripe","tipAmount":4},
  {"id":"stripe_e3","amount":10,"date":"2026-04-01","method":"stripe","tipAmount":8}]}
"""#)

private let allInvoices = [tipped, plain, voided, edges]

// MARK: - Canonical round trip

private func testCanonicalRoundTrip() throws {
    let source = #"{"id":"stripe_cs_1","amount":120,"date":"2026-03-10","method":"stripe","stripeSessionId":"cs_1","tipAmount":12.34,"futureKey":{"a":1}}"#
    let payment = decode(Canonical.Payment.self, source)
    expectEqual(payment.tipAmount, dec("12.34"), "payment: tipAmount decodes as a typed Decimal")
    expect(payment.preservation.unknownFields["tipAmount"] == nil, "payment: tipAmount is typed, not preserved")
    expect(payment.preservation.unknownFields["futureKey"] != nil, "payment: an unknown key next to tipAmount is preserved")
    let sourceJSON = try decoder.decode(Canonical.JSONValue.self, from: Data(source.utf8))
    expect(try json(payment) == sourceJSON, "payment: tipAmount and the unknown key round-trip exactly")

    let whole = decode(Canonical.Payment.self, #"{"id":"s","amount":120,"date":"2026-03-10","method":"stripe","tipAmount":18}"#)
    expectEqual(whole.tipAmount, Decimal(18), "payment: a whole-dollar tip decodes")
    let half = decode(Canonical.Payment.self, #"{"id":"s","amount":120,"date":"2026-03-10","method":"stripe","tipAmount":0.5}"#)
    expectEqual(half.tipAmount, dec("0.5"), "payment: a 50-cent tip decodes")

    let none = decode(Canonical.Payment.self, #"{"id":"p","amount":10,"date":"2026-03-10","method":"cash"}"#)
    expect(none.tipAmount == nil, "payment: no tip key reads nil")
    expect(try object(none)["tipAmount"] == nil, "payment: nil tip is never written back")

    let fixtureRoot = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
    let rich = try decoder.decode(
        [String: Canonical.JSONValue].self,
        from: Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("canonical-rich.json"))
    )
    guard case let .object(settingsBase)? = rich["settings"] else { fatalError("rich fixture has no settings") }
    func settings(_ tips: Canonical.JSONValue?) throws -> (Canonical.Settings, Canonical.JSONValue) {
        var fields = settingsBase
        fields["tipsEnabled"] = tips
        let value = Canonical.JSONValue.object(fields)
        return (try decoder.decode(Canonical.Settings.self, from: encoder.encode(value)), value)
    }
    let absent = try settings(nil)
    expect(try absent.0.tipsEnabled == nil && object(absent.0)["tipsEnabled"] == nil, "settings: absent tipsEnabled stays absent")
    let on = try settings(.bool(true))
    expectEqual(on.0.tipsEnabled, true, "settings: tipsEnabled true decodes")
    expect(on.0.preservation.unknownFields["tipsEnabled"] == nil, "settings: tipsEnabled is typed, not preserved")
    expect(try json(on.0) == on.1, "settings: tipsEnabled true round-trips exactly")
    let off = try settings(.bool(false))
    expectEqual(off.0.tipsEnabled, false, "settings: tipsEnabled false decodes")
    expect(try json(off.0) == off.1, "settings: tipsEnabled false round-trips exactly (not dropped)")
}

// MARK: - Ledger invariants

private func ledger(_ tip: Decimal?) -> LedgerInvoice {
    LedgerInvoice(
        id: "L1", amount: 120, due: "2026-03-05", paid: false, paidAt: nil,
        payments: [LedgerPayment(id: "stripe_cs_1", amount: 120, date: "2026-03-10", method: .stripe, tip: tip)],
        depositRequest: nil
    )
}

private func testLedgerInvariants() {
    let withTip = ledger(18)
    let without = ledger(nil)
    expectEqual(PaymentLedger.amountPaid(withTip), PaymentLedger.amountPaid(without), "ledger: a tip never changes amountPaid")
    expectEqual(PaymentLedger.amountPaid(withTip), Decimal(120), "ledger: amountPaid is the invoice portion only")
    expectEqual(PaymentLedger.balanceDue(withTip), Decimal(0), "ledger: balanceDue ignores the tip")
    expect(PaymentLedger.isFullyPaid(withTip), "ledger: an invoice paid exactly with a tip is fully paid")
    expectEqual(PaymentLedger.overpaidAmount(withTip), Decimal(0), "ledger: a tip is never an overpayment")

    let merged = PaymentLedger.merge(local: withTip, remote: withTip)
    expect(merged.paid, "ledger: merge derives paid from amount only")
    expectEqual(merged.paidAt, "2026-03-10", "ledger: merge derives paidAt from amount only")
    expectEqual(merged.payments?.first?.tip, Decimal(18), "ledger: merge keeps the tip")
    let mergedNoTip = PaymentLedger.merge(local: without, remote: without)
    expectEqual(merged.paid, mergedNoTip.paid, "ledger: merge paid is the same with or without a tip")
    expectEqual(merged.paidAt, mergedNoTip.paidAt, "ledger: merge paidAt is the same with or without a tip")

    // A tip must not close an invoice that the amount alone leaves open.
    var short = withTip
    short.amount = 130
    expect(!PaymentLedger.isFullyPaid(short), "ledger: a tip does not pay down the balance")
    expectEqual(PaymentLedger.balanceDue(short), Decimal(10), "ledger: balance still counts the amount only")
    expect(!PaymentLedger.merge(local: short, remote: short).paid, "ledger: merge does not mark paid because of a tip")

    expectEqual(PaymentLedger.tips(from: [withTip], from: "2026-03-01", through: "2026-03-31"), Decimal(18), "ledger: tips in window")
    expectEqual(PaymentLedger.received(from: [withTip], from: "2026-03-01", through: "2026-03-31"), Decimal(138), "ledger: received = collected + tips")
    expectEqual(PaymentLedger.collected(from: [withTip], from: "2026-03-01", through: "2026-03-31"), Decimal(120), "ledger: collected excludes tips")
    var voidedLedger = withTip
    voidedLedger.payments?[0].voidedAt = "2026-03-11"
    expectEqual(PaymentLedger.tips(from: [voidedLedger], from: "2026-03-01", through: "2026-03-31"), Decimal(0), "ledger: a voided payment voids its tip")
    expectEqual(PaymentLedger.received(from: [voidedLedger], from: "2026-03-01", through: "2026-03-31"), Decimal(0), "ledger: a voided payment contributes no received")
    var zero = withTip
    zero.payments?[0].tip = 0
    expectEqual(PaymentLedger.tips(from: [zero], from: "2026-03-01", through: "2026-03-31"), Decimal(0), "ledger: a zero tip counts nothing")
    var negative = withTip
    negative.payments?[0].tip = -3
    expectEqual(PaymentLedger.tips(from: [negative], from: "2026-03-01", through: "2026-03-31"), Decimal(0), "ledger: a negative tip counts nothing")
}

// MARK: - Cash basis

private func testCashBasis() {
    let tips = NativeCashBasis.tipsCollected(invoices: allInvoices, start: marchStart, end: marchEnd)
    // 18 (tipped) + 1 + 4 (edge payments inside March); the voided 5 and the
    // Feb 28 / Apr 1 tips are out.
    expectEqual(tips, Decimal(23), "cash basis: tipsCollected counts non-voided in-window tips on the edges")
    let collected = NativeCashBasis.collected(invoices: allInvoices, start: marchStart, end: marchEnd)
    // 120 + 200 + 10 + 10 (voided 100 excluded).
    expectEqual(collected, Decimal(340), "cash basis: collected reports the invoice amounts only, tips separate")
    expectEqual(NativeCashBasis.received(invoices: allInvoices, start: marchStart, end: marchEnd), collected + tips,
                "cash basis: received = collected + tips")
    expectEqual(NativeCashBasis.tipsCollected(invoices: [plain, voided], start: marchStart, end: marchEnd), Decimal(0),
                "cash basis: voided tips and no-tip payments report zero tips")
    expectEqual(NativeCashBasis.received(invoices: [voided], start: marchStart, end: marchEnd), Decimal(0),
                "cash basis: a voided payment and its tip contribute no received")

    // Window edges are inclusive local days: a single-day window finds only that day's tip.
    expectEqual(NativeCashBasis.tipsCollected(invoices: [edges], start: day(2026, 3, 1), end: endOfDay(2026, 3, 1)), Decimal(1),
                "cash basis: Mar 1 tip counts on the first day of the window")
    expectEqual(NativeCashBasis.tipsCollected(invoices: [edges], start: day(2026, 3, 31), end: endOfDay(2026, 3, 31)), Decimal(4),
                "cash basis: Mar 31 tip counts on the last day of the window")
    expectEqual(NativeCashBasis.tipsCollected(invoices: [edges], start: day(2026, 4, 1), end: endOfDay(2026, 4, 1)), Decimal(8),
                "cash basis: Apr 1 tip belongs to April")
    expectEqual(NativeCashBasis.tipsCollected(invoices: [edges], start: day(2026, 2, 28), end: endOfDay(2026, 2, 28)), Decimal(2),
                "cash basis: Feb 28 tip belongs to February")

    let ranges = [
        NativeDateRange(start: day(2026, 2, 1), end: endOfDay(2026, 2, 28)),
        NativeDateRange(start: marchStart, end: marchEnd),
        NativeDateRange(start: day(2026, 4, 1), end: endOfDay(2026, 4, 30)),
        // Overlaps March: a payment inside two windows counts in both.
        NativeDateRange(start: day(2026, 3, 10), end: endOfDay(2026, 3, 12)),
    ]
    let byPeriod = NativeCashBasis.receivedByPeriod(invoices: allInvoices, ranges: ranges)
    expectEqual(byPeriod, [Decimal(12), Decimal(363), Decimal(18), Decimal(338)],
                "cash basis: receivedByPeriod adds each payment's tip, skips voided, counts overlapping windows")
    let plainPeriods = NativeCashBasis.collectedByPeriod(invoices: allInvoices, ranges: ranges)
    expectEqual(plainPeriods, [Decimal(10), Decimal(340), Decimal(10), Decimal(320)],
                "cash basis: collectedByPeriod is unchanged by tips")
    expectEqual(byPeriod[1], NativeCashBasis.received(invoices: allInvoices, start: marchStart, end: marchEnd),
                "cash basis: receivedByPeriod agrees with received for the same window")

    // paid is derived from the amount only, through the canonical bridge.
    let bridged = NativeCashBasis.ledgerInvoice(tipped)
    expectEqual(bridged.payments?.first?.tip, Decimal(18), "cash basis: ledgerInvoice carries the tip")
    expect(PaymentLedger.isFullyPaid(bridged) && PaymentLedger.overpaidAmount(bridged) == 0,
           "cash basis: the bridged invoice is paid and not overpaid")
}

// MARK: - Money cards

private func testMoneyCards() {
    let card = NativeMoneySummaryCard.make(
        invoices: allInvoices, expenses: [], start: marchStart, end: marchEnd, previousRange: nil, label: "March"
    )
    expectEqual(card.income, Decimal(363), "money card: income is cash received, tips included")
    expectEqual(card.tips, Decimal(23), "money card: tips carried")
    expectEqual(card.netProfit, Decimal(363), "money card: net profit follows income")
    expectEqual(card.tipsCaption, "Includes $23.00 in tips", "money card: the tips caption")

    let untipped = NativeMoneySummaryCard.make(
        invoices: [plain, voided], expenses: [], start: marchStart, end: marchEnd, previousRange: nil, label: "March"
    )
    expectEqual(untipped.income, Decimal(200), "money card: no tips leaves income unchanged")
    expect(untipped.tipsCaption == nil, "money card: no caption without tips")
    let voidedOnly = NativeMoneySummaryCard.make(
        invoices: [voided], expenses: [], start: marchStart, end: marchEnd, previousRange: nil, label: "March"
    )
    expect(voidedOnly.tipsCaption == nil, "money card: a voided tip shows no caption")

    let previous = NativeDateRange(start: day(2026, 2, 1), end: endOfDay(2026, 2, 28))
    let compared = NativeMoneySummaryCard.make(
        invoices: allInvoices, expenses: [], start: marchStart, end: marchEnd, previousRange: previous, label: "March"
    )
    // Previous window income = 10 + 2 (the Feb 28 payment and its tip) = 12.
    expectEqual(compared.incomeChangePercent, 2925, "money card: the previous-window comparison counts tips too")

    let chart = NativeMoneyMonthlyChartCard.make(invoices: allInvoices, expenses: [], now: day(2026, 3, 20))
    let marchRow = chart.rows.first { $0.income == Decimal(363) }
    expect(marchRow != nil, "money card: the monthly chart income includes tips")
}

// MARK: - CSV income export

private func testCsvIncome() {
    let csv = NativeCSVExport.buildIncomeCsv(invoices: allInvoices, start: marchStart, end: marchEnd)
    let lines = csv.components(separatedBy: "\r\n")
    expectEqual(lines[0], "Date,Customer,Invoice #,Invoice Description,Method,Note,Amount", "csv: the header is unchanged")
    expectEqual(lines[1], "2026-03-01,Di,INV-004,,stripe,,10.00", "csv: first payment row")
    expectEqual(lines[2], "2026-03-01,Di,INV-004,,stripe,Tip,1.00", "csv: its tip row follows right after")
    expectEqual(lines[3], "2026-03-10,Alice,INV-001,Faucet,stripe,,120.00", "csv: a tipped payment row")
    expectEqual(lines[4], "2026-03-10,Alice,INV-001,Faucet,stripe,Tip,18.00", "csv: the tip row repeats Date / Customer / Invoice # / Description / Method")
    expectEqual(lines[5], "2026-03-11,Bob,INV-002,,cash,,200.00", "csv: a no-tip payment adds no extra row")
    expectEqual(lines[6], "2026-03-31,Di,INV-004,,stripe,,10.00", "csv: last-day payment row")
    expectEqual(lines[7], "2026-03-31,Di,INV-004,,stripe,Tip,4.00", "csv: last-day tip row")
    expectEqual(lines.count, 9, "csv: header + 7 rows + trailing newline")
    expect(!csv.contains("5.00"), "csv: a voided payment's tip is excluded")

    let total = lines.dropFirst().compactMap { $0.split(separator: ",", omittingEmptySubsequences: false).last }
        .compactMap { Decimal(string: String($0)) }.reduce(Decimal.zero, +)
    expectEqual(total, NativeCashBasis.received(invoices: allInvoices, start: marchStart, end: marchEnd),
                "csv: Σ Amount = cash actually received")
    expect(!NativeCSVExport.buildIncomeCsv(invoices: [plain], start: marchStart, end: marchEnd).contains("Tip"),
           "csv: no tip rows when there are no tips")
}

// MARK: - Accountant package

private func rows(_ csv: String) -> [String] {
    csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
}

private func testAccountingPackage() {
    let activity = rows(NativeAccountingPackage.buildPaymentActivityCsv(allInvoices, start: marchStart, end: marchEnd))
    expectEqual(activity[0], "Date,Customer,Invoice #,Method,Note,Amount,Voided,Voided At,Source", "package: payment-activity header is unchanged")
    expect(activity.contains("2026-03-10,Alice,INV-001,stripe,,120.00,No,,stripe"), "package: payment-activity payment row")
    expect(activity.contains("2026-03-10,Alice,INV-001,stripe,Tip,18.00,No,,tip"), "package: payment-activity tip row has Source tip")
    expect(activity.contains("2026-03-12,Cy,INV-003,stripe,,100.00,Yes,2026-03-13,stripe"), "package: a voided payment row")
    expect(activity.contains("2026-03-12,Cy,INV-003,stripe,Tip,5.00,Yes,2026-03-13,tip"), "package: a voided payment's tip row shows Voided = Yes")
    let payIndex = activity.firstIndex { $0.hasPrefix("2026-03-10,Alice") && !$0.contains(",Tip,") }!
    expect(activity[payIndex + 1].contains(",Tip,"), "package: the tip row sorts right after its payment")

    let active = rows(NativeCSVExport.buildIncomeCsv(invoices: allInvoices, start: marchStart, end: marchEnd))
    expect(active.contains { $0.contains(",Tip,18.00") }, "package: active-payments carries the tip rows (same builder)")
    expect(!active.contains { $0.contains(",Tip,5.00") }, "package: active-payments excludes a voided tip")

    let invoicesCsv = NativeAccountingPackage.buildInvoicesCsv([tipped], start: marchStart, end: marchEnd)
    expect(invoicesCsv.contains("120.00,120.00,0.00,paid"), "package: invoices.csv Amount Paid excludes the tip and reconciles")
    expect(!invoicesCsv.contains("138"), "package: invoices.csv never shows amount plus tip")

    let input = NativePackageInput(invoices: allInvoices)
    let summary = NativeAccountingPackage.buildSummary(input, start: marchStart, end: marchEnd)
    expectEqual(summary.tipsCollected, Decimal(23), "package: tipsCollected")
    expectEqual(summary.cashCollected, Decimal(363), "package: cash_collected is cash received (tips included)")
    let activeSum = active.dropFirst().compactMap { $0.split(separator: ",", omittingEmptySubsequences: false).last }
        .compactMap { Decimal(string: String($0)) }.reduce(Decimal.zero, +)
    expectEqual(summary.cashCollected, activeSum, "package: cash_collected = Σ active-payments Amount")
    expectEqual(summary.voidedAmount, Decimal(105), "package: voided_amount includes the voided payment's tip")
    expectEqual(summary.netCash, Decimal(363), "package: net_cash follows")

    let jsonText = NativeAccountingPackage.buildSummaryJson(summary)
    expect(jsonText.contains("\"cash_collected\": 363,\n  \"tips_collected\": 23,\n  \"voided_amount\": 105,"),
           "package: tips_collected follows cash_collected in summary.json")
    let empty = NativeAccountingPackage.buildSummaryJson(
        NativeAccountingPackage.buildSummary(NativePackageInput(), start: marchStart, end: marchEnd)
    )
    expect(empty.contains("\"cash_collected\": 0,\n  \"tips_collected\": 0,\n"), "package: tips_collected is always present, even at zero")
    let plainSummary = NativeAccountingPackage.buildSummary(NativePackageInput(invoices: [plain]), start: marchStart, end: marchEnd)
    expectEqual(plainSummary.tipsCollected, Decimal(0), "package: no tips reports zero")
    expect(NativeAccountingPackage.buildSummaryJson(plainSummary).contains("\"tips_collected\": 0,"), "package: a no-tip package still emits the key")

    expect(NativeAccountingPackage.buildReadme(summary).contains(
        "Tips appear as separate rows with Note \"Tip\". They are income but not invoice payments, so invoices.csv Amount Paid excludes them."
    ), "package: README carries the tips line")
}

// MARK: - Tax set-aside, lead-source control total

private func testTaxAndLeadSource() {
    let window = TaxWindowSettings(mileageRate: dec("0.70"), incomeRatePercent: 10, vehicleDeductionMethod: nil)
    func profit(_ invoices: [LedgerInvoice]) -> Decimal {
        TaxEstimateEngine.summarize(invoices: invoices, expenses: [], trips: [], settings: window, on: "2026-03-20").yearToDate.netProfit
    }
    expectEqual(profit([ledger(18)]) - profit([ledger(nil)]), Decimal(18), "tax: income includes tips")

    let report = NativeLeadSourceReport.make(
        customers: [], jobs: [], invoices: allInvoices, start: marchStart, end: marchEnd
    )
    expectEqual(report.totalCollected, NativeCashBasis.collected(invoices: allInvoices, start: marchStart, end: marchEnd),
                "lead source: the control total still equals NativeCashBasis.collected with tips present")
    expect(report.totalCollected != NativeCashBasis.received(invoices: allInvoices, start: marchStart, end: marchEnd),
           "lead source: attribution never counts tips")
}

// MARK: - UI adapters and the Settings toggle

private func testAdaptersAndSettings() throws {
    let canonicalPayment = decode(
        Canonical.Payment.self,
        #"{"id":"stripe_cs_1","amount":120,"date":"2026-03-10","method":"stripe","stripeSessionId":"cs_1","tipAmount":18.25,"futureKey":true}"#
    )
    var edit = try CanonicalUIAdapters.edit(canonicalPayment)
    expectEqual(edit.value.tip, 18.25, "adapter: the UI payment carries the tip")
    expectEqual(edit.value.amount, 120, "adapter: the UI amount stays the invoice portion")

    edit.value.note = "Left a note"
    let noted = try CanonicalUIAdapters.canonical(from: edit)
    expectEqual(noted.tipAmount, dec("18.25"), "adapter: a note edit keeps the tip")
    expect(noted.preservation.unknownFields["futureKey"] != nil, "adapter: a note edit keeps unknown keys")

    var voiding = try CanonicalUIAdapters.edit(canonicalPayment)
    voiding.value.voidedAt = Date(timeIntervalSince1970: 1_773_000_000)
    let voidedPayment = try CanonicalUIAdapters.canonical(from: voiding)
    expectEqual(voidedPayment.tipAmount, dec("18.25"), "adapter: voiding keeps the tip")
    expect(voidedPayment.voidedAt != nil, "adapter: the void is written")

    let untouched = try CanonicalUIAdapters.canonical(from: try CanonicalUIAdapters.edit(canonicalPayment))
    expect(try json(untouched) == (try json(canonicalPayment)), "adapter: an untouched payment round-trips exactly, tip included")

    let fixtureRoot = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
    let rich = try decoder.decode(
        [String: Canonical.JSONValue].self,
        from: Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("canonical-rich.json"))
    )
    let source = try decoder.decode(Canonical.Settings.self, from: encoder.encode(rich["settings"]!))
    expect(source.tipsEnabled == nil, "settings: the rich fixture has no tipsEnabled")
    expect(!BusinessSettings().tipsEnabled, "settings: the UI default is off")

    var toggle = try CanonicalUIAdapters.edit(source)
    expect(!toggle.value.tipsEnabled, "settings: absent projects as off")
    toggle.value.laborRate += 1
    let unrelated = try CanonicalUIAdapters.canonical(from: toggle)
    expect(try unrelated.tipsEnabled == nil && object(unrelated)["tipsEnabled"] == nil,
           "settings: an unrelated edit does not write the default")

    toggle.value.tipsEnabled = true
    let turnedOn = try CanonicalUIAdapters.canonical(from: toggle)
    expectEqual(turnedOn.tipsEnabled, true, "settings: turning the toggle on writes true")
    expect((try object(turnedOn))["tipsEnabled"] == .bool(true), "settings: the key is a JSON boolean")
    var reread = try CanonicalUIAdapters.edit(turnedOn)
    expect(reread.value.tipsEnabled, "settings: a stored true projects as on")

    reread.value.tipsEnabled = false
    let turnedOff = try CanonicalUIAdapters.canonical(from: reread)
    expectEqual(turnedOff.tipsEnabled, false, "settings: turning it off writes false, never a string")
    expect(!(try CanonicalUIAdapters.edit(turnedOff)).value.tipsEnabled, "settings: a stored false projects as off")

    var fresh = BusinessSettings()
    fresh.tipsEnabled = true
    expectEqual(try CanonicalUIAdapters.canonical(from: fresh).tipsEnabled, true, "settings: a new record writes true when on")
    expect(try CanonicalUIAdapters.canonical(from: BusinessSettings()).tipsEnabled == nil, "settings: a new record omits the key when off")

    let encoded = try encoder.encode(fresh)
    expect(try decoder.decode(BusinessSettings.self, from: encoded).tipsEnabled, "settings: the UI model's own Codable keeps the toggle")
    expect(!(try decoder.decode(BusinessSettings.self, from: Data("{}".utf8))).tipsEnabled, "settings: a blob without the key decodes as off")
}

// MARK: - Run

run("canonical round trip") { try testCanonicalRoundTrip() }
run("ledger invariants") { testLedgerInvariants() }
run("cash basis") { testCashBasis() }
run("money cards") { testMoneyCards() }
run("csv income") { testCsvIncome() }
run("accounting package") { testAccountingPackage() }
run("tax and lead source") { testTaxAndLeadSource() }
run("adapters and settings") { try testAdaptersAndSettings() }

if failures > 0 {
    print("TipsTests: \(failures) failure(s) out of \(checks) checks")
    exit(1)
}
print("PASS: tips tests (\(checks) checks)")
