import Foundation

// Money report engine tests (task 9.01).
//
// Ports the load-bearing vectors from the React Native oracle suites:
// __tests__/moneyUtils.test.js, invoiceStats.test.js, invoiceAging.test.js,
// customerMix.test.js, seasonalTrends.test.js, expenseTrends.test.js,
// avgJobValue.test.js, conversionFunnel.test.js, revenueByType.test.js,
// revenueForecast.test.js, profitabilityAggregate.test.ts, and the
// TopCustomersCard / ReceivablesCard read models.
//
// Expectations follow the frozen contract in
// docs/native-phase-9-money-exports-contract-decisions.md: local-time date
// windows over date-only strings, legacy-ledger dating, voided-payment
// exclusion, partial-payment dual counting, overpayment, missing createdAt, and
// the declined-job funnel treatment. No test writes canonical state.

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

private let decoder = JSONDecoder()

private func decodeInvoice(_ json: String) throws -> Canonical.Invoice {
    try decoder.decode(Canonical.Invoice.self, from: Data(json.utf8))
}

private func decodeJob(_ json: String) throws -> Canonical.Job {
    try decoder.decode(Canonical.Job.self, from: Data(json.utf8))
}

private func decodeExpense(_ json: String) throws -> Canonical.Expense {
    try decoder.decode(Canonical.Expense.self, from: Data(json.utf8))
}

/// Minimal valid canonical invoice; override JSON fields to build a vector.
private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"inv1","customer":"Alice","number":"INV-001","amount":1000,"due":"2026-01-01",
     "email":"","phone":"","desc":"","paid":true}
    """
    return try! decodeInvoice(merge(base, overrides))
}

/// Minimal valid canonical job (complete, $1000, 4h @ $100).
private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Test","title":"Job","description":"",
     "status":"complete","address":"","estimateTotal":1000,"laborHours":4,"laborRate":100,
     "materials":[],"materialMarkup":0,"overhead":15,"margin":20,"notes":"",
     "createdAt":"2026-07-01"}
    """
    return try! decodeJob(merge(base, overrides))
}

private func expense(_ overrides: String = "") -> Canonical.Expense {
    let base = """
    {"id":"e1","createdAt":"2026-03-10","description":"test","amount":200,"category":"other",
     "date":"2026-03-10","notes":""}
    """
    return try! decodeExpense(merge(base, overrides))
}

/// Shallow JSON merge: the override object's keys replace the base's. Sufficient
/// for these flat fixtures.
private func merge(_ base: String, _ overrides: String) -> String {
    guard !overrides.isEmpty else { return base }
    func fields(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
               let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }
    let merged = fields(base).merging(fields(overrides)) { _, new in new }
    let body = merged.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    return "{\(body)}"
}

private let june15_2025 = NativeCashBasis.localDate(year: 2025, month: 5, day: 15)
private let july9_2026 = NativeCashBasis.localDate(year: 2026, month: 6, day: 9)

// MARK: - Date ranges (moneyUtils.test.js)

private func testDateRanges() {
    let thisMonth = NativeCashBasis.range(for: "this_month", now: june15_2025)
    expectEqual(thisMonth.start, NativeCashBasis.localDate(year: 2025, month: 5, day: 1), "this_month start")
    expectEqual(thisMonth.end, NativeCashBasis.localDate(year: 2025, month: 6, day: 0, hour: 23, minute: 59, second: 59), "this_month end")

    let lastMonth = NativeCashBasis.range(for: "last_month", now: june15_2025)
    expectEqual(lastMonth.start, NativeCashBasis.localDate(year: 2025, month: 4, day: 1), "last_month start")
    expectEqual(lastMonth.end, NativeCashBasis.localDate(year: 2025, month: 5, day: 0, hour: 23, minute: 59, second: 59), "last_month end")

    let thisYear = NativeCashBasis.range(for: "this_year", now: june15_2025)
    expectEqual(thisYear.start, NativeCashBasis.localDate(year: 2025, month: 0, day: 1), "this_year start")
    expectEqual(thisYear.end, NativeCashBasis.localDate(year: 2025, month: 11, day: 31, hour: 23, minute: 59, second: 59), "this_year end")

    let allTime = NativeCashBasis.range(for: "all_time", now: june15_2025)
    expectEqual(allTime.start, Date(timeIntervalSince1970: 0), "all_time start is the epoch")
    expectEqual(NativeCashBasis.range(for: "bogus", now: june15_2025).start, Date(timeIntervalSince1970: 0), "unknown filter falls back to all_time")
    expect(thisMonth.start < thisMonth.end, "this_month start is strictly before end")

    let prevThisMonth = NativeCashBasis.previousRange(for: "this_month", now: june15_2025)
    expectEqual(prevThisMonth?.start, NativeCashBasis.localDate(year: 2025, month: 4, day: 1), "previous this_month start")
    expectEqual(prevThisMonth?.end, NativeCashBasis.localDate(year: 2025, month: 5, day: 0, hour: 23, minute: 59, second: 59), "previous this_month end")

    let prevLastMonth = NativeCashBasis.previousRange(for: "last_month", now: june15_2025)
    expectEqual(prevLastMonth?.start, NativeCashBasis.localDate(year: 2025, month: 3, day: 1), "previous last_month start")

    let prevThisYear = NativeCashBasis.previousRange(for: "this_year", now: june15_2025)
    expectEqual(prevThisYear?.start, NativeCashBasis.localDate(year: 2024, month: 0, day: 1), "previous this_year start")
    expectEqual(prevThisYear?.end, NativeCashBasis.localDate(year: 2024, month: 11, day: 31, hour: 23, minute: 59, second: 59), "previous this_year end")

    expect(NativeCashBasis.previousRange(for: "all_time", now: june15_2025) == nil, "previous all_time is nil")
    expect(NativeCashBasis.previousRange(for: "bogus", now: june15_2025) == nil, "previous unknown is nil")
}

// MARK: - Export presets (csvExport.ts exportDateRange)

private func testExportRanges() {
    let thisMonth = NativeCashBasis.exportRange(for: "this_month", now: june15_2025)
    expectEqual(thisMonth.start, NativeCashBasis.localDate(year: 2025, month: 5, day: 1), "export this_month start")
    expectEqual(thisMonth.end, NativeCashBasis.localDate(year: 2025, month: 6, day: 0, hour: 23, minute: 59, second: 59), "export this_month end")

    let quarter = NativeCashBasis.exportRange(for: "this_quarter", now: june15_2025)
    expectEqual(quarter.start, NativeCashBasis.localDate(year: 2025, month: 3, day: 1), "export this_quarter start (Apr 1)")
    expectEqual(quarter.end, NativeCashBasis.localDate(year: 2025, month: 6, day: 0, hour: 23, minute: 59, second: 59), "export this_quarter end (Jun 30)")

    let lastYear = NativeCashBasis.exportRange(for: "last_year", now: june15_2025)
    expectEqual(lastYear.start, NativeCashBasis.localDate(year: 2024, month: 0, day: 1), "export last_year start")
    expectEqual(lastYear.end, NativeCashBasis.localDate(year: 2024, month: 11, day: 31, hour: 23, minute: 59, second: 59), "export last_year end")

    // January lands in Q1.
    let jan = NativeCashBasis.localDate(year: 2025, month: 0, day: 20)
    let q1 = NativeCashBasis.exportRange(for: "this_quarter", now: jan)
    expectEqual(q1.start, NativeCashBasis.localDate(year: 2025, month: 0, day: 1), "Q1 starts Jan 1")
    expectEqual(q1.end, NativeCashBasis.localDate(year: 2025, month: 3, day: 0, hour: 23, minute: 59, second: 59), "Q1 ends Mar 31")
}

// MARK: - isInRange local-frame boundary (moneyUtils.test.js timezone edge)

private func testInRange() {
    let start = NativeCashBasis.localDate(year: 2025, month: 5, day: 1)
    let end = NativeCashBasis.localDate(year: 2025, month: 5, day: 30, hour: 23, minute: 59, second: 59)

    expect(NativeCashBasis.isInRange("2025-06-15", start: start, end: end), "mid-month in range")
    expect(NativeCashBasis.isInRange("2025-06-01", start: start, end: end), "first day of period in range")
    expect(NativeCashBasis.isInRange("2025-06-30", start: start, end: end), "last day of period in range")
    expect(!NativeCashBasis.isInRange("2025-05-31", start: start, end: end), "day before period out of range")
    expect(!NativeCashBasis.isInRange("2025-07-01", start: start, end: end), "day after period out of range")
    expect(NativeCashBasis.isInRange("2025-06-15T00:00:00", start: start, end: end), "local datetime in range")
    expect(!NativeCashBasis.isInRange("", start: start, end: end), "empty date out of range")
    expect(!NativeCashBasis.isInRange("not-a-date", start: start, end: end), "unparseable date out of range")

    // The point of the local-frame fix: a date-only boundary day must not shift.
    expectEqual(NativeCashBasis.parseLocalDate("2025-06-01"), start, "date-only parses as local midnight")
}

// MARK: - summarizeInvoices (invoiceStats.test.js)

private func testSummarizeInvoices() {
    let now = NativeCashBasis.localDate(year: 2026, month: 0, day: 15)
    let legacyPaid = invoice(#"{"id":"invA","amount":1000,"due":"2026-01-01","paid":true}"#)
    let partlyPaid = invoice(#"{"id":"invB","amount":600,"due":"2026-01-01","paid":false,"payments":[{"id":"p1","amount":300,"date":"2026-01-05","method":"cash"}]}"#)
    let overpaid = invoice(#"{"id":"invC","amount":100,"due":"2026-02-01","paid":false,"payments":[{"id":"p1","amount":150,"date":"2026-01-20","method":"card"}]}"#)

    let summary = NativeMoneyReports.summarizeInvoices([legacyPaid, partlyPaid, overpaid], now: now)
    expectEqual(summary.collected, decimal("1450"), "collected sums all amountPaid")
    expectEqual(summary.outstanding, decimal("300"), "outstanding sums remaining balances")
    expectEqual(summary.overdueCount, 1, "only the partly-paid past-due invoice is overdue")

    // Overpayment is surfaced separately and never folded into balance due.
    expectEqual(PaymentLedger.overpaidAmount(NativeCashBasis.ledgerInvoice(overpaid)), decimal("50"), "overpaid amount")
    expectEqual(PaymentLedger.balanceDue(NativeCashBasis.ledgerInvoice(overpaid)), 0, "overpaid balance due clamps to zero")

    // A legacy paid invoice is settled, so it is never overdue even past its due date.
    expect(!NativeMoneyReports.isOverdue(legacyPaid, now: now), "legacy paid invoice is not overdue")
}

// MARK: - invoice aging (invoiceAging.test.js)

private func testAging() {
    let first = invoice(#"{"id":"i1","customer":"Alice","amount":1000,"due":"2026-01-01","paid":true,"paidAt":"2026-01-11"}"#)
    let second = invoice(#"{"id":"i2","customer":"Alice","amount":500,"due":"2026-02-01","paid":true,"paidAt":"2026-02-06"}"#)
    // Partly paid: still aging, so excluded.
    let partly = invoice(#"{"id":"i3","customer":"Bob","amount":500,"due":"2026-01-01","paid":false,"paidAt":"2026-01-20","payments":[{"id":"p1","amount":100,"date":"2026-01-20","method":"cash"}]}"#)

    let aging = NativeMoneyReports.computeInvoiceAging([first, second, partly])
    expectEqual(aging.paidCount, 2, "only fully-paid invoices age")
    expectEqual(aging.avgDays, 8, "avgDays = round((10+5)/2)")
    expectEqual(aging.customers.count, 1, "one customer bucket")
    expectEqual(aging.customers.first?.name, "Alice", "customer name")
    expectEqual(aging.customers.first?.avgDays, 8, "customer avgDays")
    expectEqual(aging.customers.first?.invoiceCount, 2, "customer invoice count")
    expectEqual(aging.customers.first?.totalAmount, decimal("1500"), "customer total is FACE value")
}

// MARK: - customer mix (customerMix.test.js)

private func testCustomerMix() {
    let start = NativeCashBasis.localDate(year: 2026, month: 5, day: 1)
    let end = NativeCashBasis.localDate(year: 2026, month: 5, day: 30, hour: 23, minute: 59, second: 59)
    let newCo = invoice(#"{"id":"i1","customer":"NewCo","amount":200,"due":"2026-06-10","paid":true,"paidAt":"2026-06-10"}"#)
    let oldCoFirst = invoice(#"{"id":"i2","customer":"OldCo","amount":100,"due":"2025-01-10","paid":true,"paidAt":"2025-01-10"}"#)
    let oldCoJune = invoice(#"{"id":"i3","customer":"OldCo","amount":300,"due":"2026-06-20","paid":true,"paidAt":"2026-06-20"}"#)

    let mix = NativeMoneyReports.computeCustomerMix([newCo, oldCoFirst, oldCoJune], start: start, end: end)
    expectEqual(mix.newCount, 1, "one new customer")
    expectEqual(mix.newRevenue, decimal("200"), "new revenue = June payment")
    expectEqual(mix.returningCount, 1, "one returning customer")
    expectEqual(mix.returningRevenue, decimal("300"), "returning revenue = June payment")
}

// MARK: - seasonal trends (seasonalTrends.test.js)

private func testSeasonalTrends() {
    let empty = NativeMoneyReports.computeSeasonalTrends([], now: july9_2026)
    expectEqual(empty.months.count, 12, "12 months")
    expectEqual(empty.months.first?.label, "Aug", "window starts Aug")
    expectEqual(empty.months.first?.year, 2025, "window starts 2025")
    expectEqual(empty.months.last?.label, "Jul", "window ends Jul")
    expectEqual(empty.months.last?.year, 2026, "window ends 2026")
    expect(empty.yoyChangePct == nil, "yoy is nil with no last-year revenue")

    let july = invoice(#"{"id":"i1","paid":true,"amount":300,"due":"2026-07-05","paidAt":"2026-07-05"}"#)
    let june = invoice(#"{"id":"i2","paid":true,"amount":200,"due":"2026-06-15","paidAt":"2026-06-15"}"#)
    let result = NativeMoneyReports.computeSeasonalTrends([july, june], now: july9_2026)
    expectEqual(result.months.first { $0.label == "Jul" && $0.year == 2026 }?.thisYear, decimal("300"), "July bucket")
    expectEqual(result.months.first { $0.label == "Jun" && $0.year == 2026 }?.thisYear, decimal("200"), "June bucket")
    expectEqual(result.thisYearTotal, decimal("500"), "this-year total")
    expect(result.yoyChangePct == nil, "yoy nil when last year is zero")

    let lastJuly = invoice(#"{"id":"i3","paid":true,"amount":250,"due":"2025-07-10","paidAt":"2025-07-10"}"#)
    let withLastYear = NativeMoneyReports.computeSeasonalTrends([july, june, lastJuly], now: july9_2026)
    expectEqual(withLastYear.lastYearTotal, decimal("250"), "last-year total")
    expectEqual(withLastYear.yoyChangePct, 100, "yoy = (500-250)/250*100")
}

// MARK: - expense trends (expenseTrends.test.js)

private func testExpenseTrends() {
    let empty = NativeMoneyReports.computeExpenseTrends([], now: july9_2026)
    expectEqual(empty.months.count, 12, "12 months of expenses")
    expectEqual(empty.trailingTotal, 0, "empty trailing total")
    expectEqual(empty.avgMonthly, 0, "empty average")
    expect(empty.overallTrend == nil, "empty overall trend is nil")

    let march = expense(#"{"id":"e1","date":"2026-03-10","amount":200}"#)
    let march2 = expense(#"{"id":"e2","date":"2026-03-20","amount":100}"#)
    let april = expense(#"{"id":"e3","date":"2026-04-05","amount":50}"#)
    let result = NativeMoneyReports.computeExpenseTrends([march, march2, april], now: july9_2026)
    expectEqual(result.months.first { $0.label == "Mar" && $0.year == 2026 }?.total, decimal("300"), "March total")
    expectEqual(result.months.first { $0.label == "Apr" && $0.year == 2026 }?.total, decimal("50"), "April total")
    expectEqual(result.trailingTotal, decimal("350"), "trailing total")
    expectEqual(result.avgMonthly, 29, "avgMonthly = round(350/12)")

    let m1 = expense(#"{"id":"e4","date":"2026-03-10","amount":200}"#)
    let m2 = expense(#"{"id":"e5","date":"2026-04-10","amount":300}"#)
    let mom = NativeMoneyReports.computeExpenseTrends([m1, m2], now: july9_2026)
    expectEqual(mom.months.first { $0.label == "Apr" && $0.year == 2026 }?.momChangePct, 50, "MoM +50%")

    let single = NativeMoneyReports.computeExpenseTrends(
        [expense(#"{"id":"e6","date":"2026-05-10","amount":100}"#)], now: july9_2026
    )
    expect(single.months.first { $0.label == "May" && $0.year == 2026 }?.momChangePct == nil, "MoM nil when prior month is zero")
    expect(single.months[0].momChangePct == nil, "earliest month has no MoM")

    let oldest = expense(#"{"id":"e7","date":"2025-08-10","amount":100}"#)
    let newest = expense(#"{"id":"e8","date":"2026-07-05","amount":150}"#)
    let trend = NativeMoneyReports.computeExpenseTrends([oldest, newest], now: july9_2026)
    expectEqual(trend.overallTrend, 50, "overall trend +50%")
}

// MARK: - avg job value (avgJobValue.test.js)

private func testAvgJobValue() {
    let done = job(#"{"id":"j1","status":"complete","estimateTotal":1000}"#)
    let lead = job(#"{"id":"j2","status":"lead","estimateTotal":1000}"#)
    let zero = job(#"{"id":"j3","status":"complete","estimateTotal":0}"#)

    let all = NativeMoneyReports.computeAvgJobValue([done, lead, zero])
    expectEqual(all.count, 1, "only done + positive jobs count")
    expectEqual(all.avgValue, decimal("1000"), "average value")
    expectEqual(all.totalValue, decimal("1000"), "total value")

    // Windowed: createdAt outside the window is excluded; missing createdAt is included.
    let start = NativeCashBasis.localDate(year: 2026, month: 6, day: 1)
    let end = NativeCashBasis.localDate(year: 2026, month: 6, day: 31, hour: 23, minute: 59, second: 59)
    let inWindow = job(#"{"id":"j4","status":"complete","estimateTotal":400,"createdAt":"2026-07-10"}"#)
    let outWindow = job(#"{"id":"j5","status":"complete","estimateTotal":900,"createdAt":"2025-01-01"}"#)
    let missing = job(#"{"id":"j6","status":"complete","estimateTotal":600,"createdAt":""}"#)
    let windowed = NativeMoneyReports.computeAvgJobValue([inWindow, outWindow, missing], start: start, end: end)
    expectEqual(windowed.count, 2, "window excludes out-of-range createdAt, keeps missing")
    expectEqual(windowed.totalValue, decimal("1000"), "windowed total = in-window + missing")

    // Approved change orders raise the billable total.
    // A change order only counts once approved (pending/awaiting do not).
    let withChangeOrder = job(#"{"id":"j7","status":"complete","estimateTotal":900,"changeOrders":[{"id":"co1","title":"Extra","amount":100,"createdAt":"2026-07-02","manualDecision":{"decision":"approved","decidedAt":"2026-07-02"}}]}"#)
    let billable = NativeMoneyReports.computeAvgJobValue([withChangeOrder])
    expectEqual(billable.totalValue, decimal("1000"), "billable total includes approved CO")

    let pendingChangeOrder = job(#"{"id":"j8","status":"complete","estimateTotal":900,"changeOrders":[{"id":"co2","title":"Extra","amount":100,"createdAt":"2026-07-02"}]}"#)
    let pending = NativeMoneyReports.computeAvgJobValue([pendingChangeOrder])
    expectEqual(pending.totalValue, decimal("900"), "pending change order does not count")
}

// MARK: - conversion funnel (conversionFunnel.test.js)

private func testConversionFunnel() {
    let jobs = [
        job(#"{"id":"j1","status":"lead","estimateTotal":100}"#),
        job(#"{"id":"j2","status":"estimate_sent","estimateTotal":200}"#),
        job(#"{"id":"j3","status":"approved","estimateTotal":300}"#),
        job(#"{"id":"j4","status":"declined","estimateTotal":400}"#),
        job(#"{"id":"j5","status":"complete","estimateTotal":500}"#),
    ]
    let funnel = NativeMoneyReports.computeConversionFunnel(jobs)
    expectEqual(funnel.totalJobs, 5, "total jobs")
    expectEqual(funnel.stages.first { $0.status == "lead" }?.count, 5, "lead reaches everyone")
    expectEqual(funnel.stages.first { $0.status == "estimate_sent" }?.count, 4, "declined still counts as estimate sent")
    expectEqual(funnel.stages.first { $0.status == "approved" }?.count, 2, "approved reached by 2")
    expectEqual(funnel.stages.first { $0.status == "scheduled" }?.count, 1, "scheduled reached by 1")
    expectEqual(funnel.winRate, decimal("0.5"), "winRate = approved / estimate sent")
    expectEqual(funnel.stages.first { $0.status == "estimate_sent" }?.rate, decimal("0.8"), "estimate-sent conversion rate")
}

// MARK: - revenue by type (revenueByType.test.js)

private func testRevenueByType() {
    let empty = NativeMoneyReports.computeRevenueByType([])
    expectEqual(empty.totalRevenue, 0, "no jobs → zero revenue")
    expectEqual(empty.jobCount, 0, "no jobs → zero count")
    expect(empty.components.isEmpty, "no components")

    let laborOnly = NativeMoneyReports.computeRevenueByType([job(#"{"id":"j1","status":"complete","estimateTotal":1000}"#)])
    expectEqual(laborOnly.jobCount, 1, "labor-only job counted")
    expectEqual(laborOnly.totalRevenue, decimal("1000"), "labor-only total")
    expectEqual(laborOnly.components.first { $0.label == "Labor" }?.total, decimal("400"), "labor 4h*$100")
    expectEqual(laborOnly.components.first { $0.label == "Labor" }?.pct, 40, "labor 40%")
    expectEqual(laborOnly.components.first { $0.label == "Overhead & Profit" }?.total, decimal("600"), "overhead residual")

    let nonDone = NativeMoneyReports.computeRevenueByType([
        job(#"{"id":"j1","status":"lead"}"#),
        job(#"{"id":"j2","status":"in_progress"}"#),
    ])
    expectEqual(nonDone.jobCount, 0, "non-done jobs skipped")

    let zeroTotal = NativeMoneyReports.computeRevenueByType([job(#"{"id":"j1","estimateTotal":0}"#)])
    expectEqual(zeroTotal.jobCount, 0, "zero-estimate job skipped")

    let withMaterials = job(#"{"id":"j1","estimateTotal":1000,"materials":[{"id":"m1","name":"Heater","quantity":1,"unitCost":200},{"id":"m2","name":"Fittings","quantity":2,"unitCost":50}]}"#)
    let materialJob = NativeMoneyReports.computeRevenueByType([withMaterials])
    expectEqual(materialJob.components.first { $0.label == "Materials" }?.total, decimal("300"), "materials 200+100")
    expectEqual(materialJob.components.first { $0.label == "Overhead & Profit" }?.total, decimal("300"), "overhead residual after materials")
}

// MARK: - revenue forecast (revenueForecast.test.js)

private func testRevenueForecast() {
    let jobs = [
        job(#"{"id":"j1","status":"approved","estimateTotal":1000}"#),
        job(#"{"id":"j2","status":"estimate_sent","estimateTotal":400}"#),
    ]
    let forecast = NativeMoneyReports.computeRevenueForecast(jobs)
    expectEqual(forecast.certainValue, decimal("1000"), "certain = approved/scheduled/in_progress")
    expectEqual(forecast.certainCount, 1, "certain count")
    expectEqual(forecast.speculativeValue, decimal("400"), "speculative = lead/estimate_sent")
    expectEqual(forecast.speculativeCount, 1, "speculative count")
    expectEqual(forecast.winRate, decimal("0.5"), "winRate = 1/2")
    expectEqual(forecast.projectedValue, decimal("200"), "projected = speculative * winRate")
    expectEqual(forecast.totalForecast, decimal("1200"), "total forecast")

    // winRate === null propagates: no projection at all.
    let noEstimateSent = NativeMoneyReports.computeRevenueForecast([
        job(#"{"id":"j1","status":"lead","estimateTotal":750}"#),
    ])
    expect(noEstimateSent.winRate == nil, "winRate nil with no estimate sent")
    expectEqual(noEstimateSent.projectedValue, 0, "projected value zero when winRate is nil")
    expectEqual(noEstimateSent.totalForecast, 0, "total forecast zero when winRate is nil")
}

// MARK: - profitability history (profitabilityAggregate.test.ts)

private func testProfitabilityHistory() {
    let active = job(#"{"id":"j1","status":"complete","estimateTotal":1000,"timeSessions":[{"id":"t1","start":"2026-07-01T08:00:00.000Z","end":"2026-07-01T13:00:00.000Z"}]}"#)
    let archived = job(#"{"id":"j2","status":"complete","estimateTotal":500,"archivedAt":"2026-01-01"}"#)
    let noEstimate = job(#"{"id":"j3","status":"complete","estimateTotal":0}"#)

    let history = NativeMoneyReports.computeProfitabilityHistory(
        jobs: [active, archived, noEstimate],
        invoices: [],
        expenses: [],
        laborCostRate: nil
    )
    expectEqual(history.doneJobs, 1, "archived + zero-estimate jobs excluded")
    expectEqual(history.jobsWithData, 1, "job with tracked time counts as having data")
    expectEqual(history.hourlyCount, 1, "one hourly sample")
    expect(history.medianEffectiveHourly != nil, "median effective hourly present")

    let noData = job(#"{"id":"j9","status":"complete","estimateTotal":1000}"#)
    let empty = NativeMoneyReports.computeProfitabilityHistory(
        jobs: [noData], invoices: [], expenses: [], laborCostRate: nil
    )
    expectEqual(empty.doneJobs, 1, "done job counted without data")
    expectEqual(empty.jobsWithData, 0, "no tracked data")
    expectEqual(empty.hourlyCount, 0, "no hourly sample")
    expect(empty.medianEffectiveHourly == nil, "median nil when no data")
    expect(empty.medianLaborOverrunHours == nil, "labor median nil when no data")
    expect(empty.medianMaterialsVariance == nil, "materials median nil when no data")
}

// MARK: - legacy ledger dating + voided exclusion

private func testLegacyAndVoidedPayments() {
    let start = NativeCashBasis.localDate(year: 2026, month: 2, day: 1)
    let end = NativeCashBasis.localDate(year: 2026, month: 2, day: 31, hour: 23, minute: 59, second: 59)

    let legacyPaidAt = invoice(#"{"id":"invL1","amount":400,"paid":true,"paidAt":"2026-03-15","due":"2026-04-01"}"#)
    expectEqual(
        NativeCashBasis.collected(invoices: [legacyPaidAt], start: start, end: end),
        decimal("400"),
        "legacy income lands on paidAt"
    )

    let legacyDue = invoice(#"{"id":"invL2","amount":400,"paid":true,"due":"2026-03-20"}"#)
    expectEqual(
        NativeCashBasis.collected(invoices: [legacyDue], start: start, end: end),
        decimal("400"),
        "legacy income falls back to due when paidAt is absent"
    )

    let voidedInvoice = invoice(#"{"id":"invV","amount":300,"paid":false,"due":"2026-03-05","payments":[{"id":"p1","amount":300,"date":"2026-03-05","method":"cash"},{"id":"p2","amount":100,"date":"2026-03-05","method":"cash","voidedAt":"2026-03-06"}]}"#)
    expectEqual(
        NativeCashBasis.collected(invoices: [voidedInvoice], start: start, end: end),
        decimal("300"),
        "voided payments are excluded from collected"
    )
    expectEqual(
        PaymentLedger.amountPaid(NativeCashBasis.ledgerInvoice(voidedInvoice)),
        decimal("300"),
        "voided payments are excluded from amountPaid"
    )
    // History callers still see the voided entry itself.
    expectEqual(NativeCashBasis.paymentsInRange(voidedInvoice, start: start, end: end).count, 2, "paymentsInRange keeps voided entries")
}

// MARK: - Top customers + receivables read models

private func testTopCustomersAndReceivables() {
    let start = NativeCashBasis.localDate(year: 2026, month: 5, day: 1)
    let end = NativeCashBasis.localDate(year: 2026, month: 5, day: 30, hour: 23, minute: 59, second: 59)
    let a1 = invoice(#"{"id":"i1","customer":"A","amount":100,"paid":true,"due":"2026-06-05","paidAt":"2026-06-05"}"#)
    let b1 = invoice(#"{"id":"i2","customer":"B","amount":300,"paid":true,"due":"2026-06-07","paidAt":"2026-06-07"}"#)
    let a2 = invoice(#"{"id":"i3","customer":"A","amount":200,"paid":true,"due":"2026-06-08","paidAt":"2026-06-08"}"#)

    let top = NativeMoneyReports.topCustomers([a1, b1, a2], start: start, end: end)
    expectEqual(top.count, 2, "two customers with collections")
    expectEqual(top.first?.name, "A", "tie broken by first-seen order")
    expectEqual(top.first?.amount, decimal("300"), "A collected 100+200")
    expectEqual(top.last?.name, "B", "B second")

    let now = NativeCashBasis.localDate(year: 2026, month: 6, day: 15)
    let overdueInvoice = invoice(#"{"id":"r1","amount":100,"paid":false,"due":"2000-01-01"}"#)
    let openInvoice = invoice(#"{"id":"r2","amount":50,"paid":false,"due":"2099-01-01"}"#)
    let paidInvoice = invoice(#"{"id":"r3","amount":500,"paid":true,"due":"2026-01-01","paidAt":"2026-01-01"}"#)
    let pipelineJob = job(#"{"id":"p1","status":"lead","estimateTotal":500}"#)
    let declinedJob = job(#"{"id":"p2","status":"declined","estimateTotal":900}"#)

    let receivables = NativeMoneyReports.receivables(
        [overdueInvoice, openInvoice, paidInvoice],
        jobs: [pipelineJob, declinedJob],
        now: now
    )
    expectEqual(receivables.unpaidCount, 2, "only invoices with a balance are unpaid")
    expectEqual(receivables.outstanding, decimal("150"), "outstanding = 100 + 50")
    expectEqual(receivables.overdueCount, 1, "one overdue invoice")
    expectEqual(receivables.overdue, decimal("100"), "overdue balance")
    expectEqual(receivables.pipelineCount, 1, "declined job excluded from pipeline")
    expectEqual(receivables.pipelineValue, decimal("500"), "pipeline value")
}

// MARK: - run

testDateRanges()
testExportRanges()
testInRange()
testSummarizeInvoices()
testAging()
testCustomerMix()
testSeasonalTrends()
testExpenseTrends()
testAvgJobValue()
testConversionFunnel()
testRevenueByType()
testRevenueForecast()
testProfitabilityHistory()
testLegacyAndVoidedPayments()
testTopCustomersAndReceivables()

if failures == 0 {
    print("MoneyReportTests: all checks passed")
} else {
    print("MoneyReportTests: \(failures) failure(s)")
    exit(1)
}
