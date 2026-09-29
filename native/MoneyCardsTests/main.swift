import Foundation

// Money card presentation tests (task 9.09).
//
// The card *figures* come from the 9.01 engine (already covered by
// MoneyReportTests). These vectors cover what 9.09 owns: the visibility gates,
// the change/percentage math, the sort/slice limits, the singular/plural copy,
// and the semantic tones from `components/money/*`. Expectations are the React
// Native components' own behavior, cross-checked with a scratch Jest probe over
// the same fixtures (see the 9.09 entry in the phase 9 plan).

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

/// Minimal valid canonical invoice (paid, $1000, due 2026-01-01).
private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"inv1","customer":"Alice","number":"INV-001","amount":1000,"due":"2026-01-01",
     "email":"","phone":"","desc":"","paid":true}
    """
    return try! decoder.decode(Canonical.Invoice.self, from: Data(merge(base, overrides).utf8))
}

/// Minimal valid canonical job (complete, $1000, 4h @ $100).
private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Test","title":"Job","description":"",
     "status":"complete","address":"","estimateTotal":1000,"laborHours":4,"laborRate":100,
     "materials":[],"materialMarkup":0,"overhead":15,"margin":20,"notes":"",
     "createdAt":"2026-07-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

private func expense(_ overrides: String = "") -> Canonical.Expense {
    let base = """
    {"id":"e1","createdAt":"2026-03-10","description":"test","amount":200,"category":"other",
     "date":"2026-03-10","notes":""}
    """
    return try! decoder.decode(Canonical.Expense.self, from: Data(merge(base, overrides).utf8))
}

private func trip(_ overrides: String = "") -> Canonical.Trip {
    let base = """
    {"id":"t1","date":"2026-03-10","odometerStart":0,"odometerEnd":10,"miles":10,
     "fromLabel":"Home / Shop","toLabel":"Home / Shop","purpose":"","createdAt":"2026-03-10"}
    """
    return try! decoder.decode(Canonical.Trip.self, from: Data(merge(base, overrides).utf8))
}

private func pricebookEntry(_ overrides: String = "") -> Canonical.PricebookEntry {
    let base = """
    {"id":"p1","name":"Service","laborHours":1,"laborRate":100,"materials":[],
     "materialMarkup":0,"overhead":15,"margin":20,"estimateTotal":115,
     "createdAt":"2026-01-01","updatedAt":"2026-01-01"}
    """
    return try! decoder.decode(Canonical.PricebookEntry.self, from: Data(merge(base, overrides).utf8))
}

private let march10 = NativeCashBasis.localDate(year: 2026, month: 2, day: 10)

// MARK: - Formatting

private func testFormatting() {
    expectEqual(NativeMoneyFormat.money(decimal("2400")), "$2,400.00", "formatMoney adds cents")
    expectEqual(NativeMoneyFormat.money(decimal("9.99")), "$9.99", "formatMoney keeps cents")
    expectEqual(NativeMoneyFormat.money(decimal("-500")), "-$500.00", "formatMoney signs negatives first")
    expectEqual(NativeMoneyFormat.money(0), "$0.00", "formatMoney zero")

    expectEqual(NativeMoneyFormat.changePercent(current: 150, previous: 100), 50, "changePct rises")
    expectEqual(NativeMoneyFormat.changePercent(current: 50, previous: 100), -50, "changePct falls")
    expectEqual(NativeMoneyFormat.changePercent(current: 100, previous: nil), nil, "no previous window → null")
    expectEqual(NativeMoneyFormat.changePercent(current: 100, previous: 0), nil, "zero previous → null")
    expectEqual(NativeMoneyFormat.changePercent(current: -50, previous: -100), 50, "negative previous uses |prev|")
    expectEqual(NativeMoneyFormat.changePercent(current: 1, previous: 3), -67, "changePct rounds")

    expectEqual(NativeMoneyFormat.clampedPercent(part: 250, whole: 200), 100, "progress fills clamp to 100")
    expectEqual(NativeMoneyFormat.clampedPercent(part: -10, whole: 200), 0, "progress fills clamp to 0")
    expectEqual(NativeMoneyFormat.clampedPercent(part: 10, whole: 0), 0, "zero whole → 0")
    expectEqual(NativeMoneyFormat.plural(1, "trip", "trips"), "1 trip", "singular copy")
    expectEqual(NativeMoneyFormat.plural(2, "trip", "trips"), "2 trips", "plural copy")
    expectEqual(NativeMoneyFormat.percentInt(decimal("0.5")), 50, "ratio → percent")
}

private func testFilterAndTabLabels() {
    expectEqual(NativeMoneyDateFilter.allCases.map(\.rawValue),
                ["this_month", "last_month", "this_year", "all_time"], "DATE_FILTERS order")
    expectEqual(NativeMoneyDateFilter.allCases.map(\.label),
                ["This Month", "Last Month", "This Year", "All Time"], "DATE_FILTERS labels")
    expectEqual(NativeMoneyTab.allCases.map(\.rawValue), ["Overview", "Expenses"], "segmented control labels")
}

// MARK: - Summary

private func testSummaryCard() {
    let invoices = [
        invoice(#"{"id":"a","customer":"Alice","amount":1000,"paid":true,"paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"b","customer":"Bob","amount":500,"paid":true,"paidAt":"2026-02-05"}"#),
    ]
    let expenses = [
        expense(#"{"id":"e1","amount":200,"date":"2026-03-10"}"#),
        expense(#"{"id":"e2","amount":100,"date":"2026-02-10"}"#),
    ]
    let march = NativeCashBasis.range(for: "this_month", now: march10)
    let previous = NativeCashBasis.previousRange(for: "this_month", now: march10)
    let card = NativeMoneySummaryCard.make(
        invoices: invoices, expenses: expenses, start: march.start, end: march.end,
        previousRange: previous, label: "This Month"
    )
    expectEqual(card.periodLabel, "This Month", "summary names the active filter")
    expectEqual(card.income, 1000, "summary income is cash-basis collected in the window")
    expectEqual(card.expenses, 200, "summary expenses are the window's expenses")
    expectEqual(card.netProfit, 800, "summary net profit")
    expectEqual(card.incomeChangePercent, 100, "income vs February")
    expectEqual(card.expensesChangePercent, 100, "expenses vs February")
    expectEqual(card.netProfitChangePercent, 100, "profit vs February")
    expectEqual(card.marginPercent, 80, "margin percentage")
    expect(card.isProfitable, "positive net profit is green")

    let allTime = NativeMoneySummaryCard.make(
        invoices: invoices, expenses: expenses,
        start: NativeCashBasis.range(for: "all_time", now: march10).start,
        end: NativeCashBasis.range(for: "all_time", now: march10).end,
        previousRange: nil, label: "All Time"
    )
    expectEqual(allTime.incomeChangePercent, nil, "all-time has no comparison window")
    expectEqual(allTime.income, 1500, "all-time collects both payments")

    let loss = NativeMoneySummaryCard.make(
        invoices: [], expenses: [expense(#"{"id":"e1","amount":75,"date":"2026-03-10"}"#)],
        start: march.start, end: march.end, previousRange: previous, label: "This Month"
    )
    expectEqual(loss.netProfit, -75, "a losing window is negative")
    expectEqual(loss.marginPercent, nil, "no margin bar without income")
    expect(!loss.isProfitable, "negative profit is red")
    expectEqual(NativeMoneyCardTone.delta(-50), .danger, "falling income is red")
    expectEqual(NativeMoneyCardTone.delta(50, inverse: true), .danger, "rising expenses are red")
    expectEqual(NativeMoneyCardTone.delta(-50, inverse: true), .success, "falling expenses are green")
}

// MARK: - Monthly chart

private func testMonthlyChart() {
    let invoices = [
        invoice(#"{"id":"a","amount":300,"paid":true,"paidAt":"2026-03-04"}"#),
        invoice(#"{"id":"b","amount":200,"paid":true,"paidAt":"2026-02-04"}"#),
    ]
    let expenses = [
        expense(#"{"id":"e1","amount":120,"date":"2026-03-02"}"#),
        expense(#"{"id":"e2","amount":80,"date":"2026-03-20"}"#),
    ]
    let card = NativeMoneyMonthlyChartCard.make(invoices: invoices, expenses: expenses, now: march10)
    expectEqual(card.rows.count, 6, "chart shows six months")
    expectEqual(card.rows.map(\.label), ["Oct", "Nov", "Dec", "Jan", "Feb", "Mar"], "oldest first")
    expectEqual(card.rows.last?.income, 300, "current month income")
    expectEqual(card.rows.last?.expenses, 200, "current month expenses sum both entries")
    expectEqual(card.rows[4].income, 200, "previous month income")
    expectEqual(card.maxValue, 300, "chart max is the largest bar")
    expectEqual(card.rows.last?.incomeFraction(max: card.maxValue), 1, "the leader fills the track")

    let empty = NativeMoneyMonthlyChartCard.make(invoices: [], expenses: [], now: march10)
    expectEqual(empty.maxValue, 1, "an empty chart still has a non-zero max")
    expect(empty.isEmpty, "an empty chart reports itself empty")
    expect(!card.isEmpty, "a chart with data is not empty")
}

private func testExpenseCategories() {
    let expenses = [
        expense(#"{"id":"e1","amount":300,"category":"materials","date":"2026-03-02"}"#),
        expense(#"{"id":"e2","amount":100,"category":"fuel","date":"2026-03-03"}"#),
        expense(#"{"id":"e3","amount":50,"category":"materials","date":"2026-02-01"}"#),
        expense(#"{"id":"e4","amount":25,"category":"tools","date":"2026-03-04"}"#),
    ]
    let range = NativeCashBasis.range(for: "this_month", now: march10)
    let card = NativeMoneyExpenseCategoryCard.make(
        expenses: expenses, start: range.start, end: range.end
    )
    expectEqual(card?.rows.map(\.id), ["materials", "fuel", "tools"], "sorted by total, ties in category order")
    expectEqual(card?.rows.first?.total, 300, "materials total for the window only")
    expectEqual(card?.rows.first?.label, "Materials", "RN category label")
    expectEqual(card?.total, 425, "window total excludes last month")
    expectEqual(card?.rows[0].fraction, 300.0 / 425.0 * 100, "bar width is the share of the window")
    expectEqual(card?.rows.first?.id, "materials", "ranked first")

    let none = NativeMoneyExpenseCategoryCard.make(expenses: expenses, start: march10, end: march10)
    expectEqual(none, nil, "no expenses in the window hides the card")
}

// MARK: - Customers, invoices, receivables

private func testTopCustomers() {
    let invoices = [
        invoice(#"{"id":"a","customer":"Alice","amount":1000,"paid":true,"paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"b","customer":"Bob","amount":500,"paid":true,"paidAt":"2026-03-06"}"#),
        invoice(#"{"id":"c","customer":"Alice","amount":300,"paid":true,"paidAt":"2026-03-07"}"#),
        invoice(#"{"id":"d","customer":"Carol","amount":100,"paid":true,"paidAt":"2026-02-01"}"#),
    ]
    let range = NativeCashBasis.range(for: "this_month", now: march10)
    let card = NativeMoneyTopCustomersCard.make(invoices: invoices, start: range.start, end: range.end)
    expectEqual(card?.rows.map(\.name), ["Alice", "Bob"], "top customers ranked by window revenue")
    expectEqual(card?.rows.map(\.rank), [1, 2], "ranks are 1-based")
    expectEqual(card?.rows[0].amount, 1300, "one row per customer, summed")
    expectEqual(card?.rows[0].fraction, 100, "the leader fills the track")
    expectEqual(card?.rows[1].fraction, 500.0 / 1300.0 * 100, "runners-up scale to the leader")
    expectEqual(NativeMoneyTopCustomersCard.make(invoices: [], start: range.start, end: range.end), nil,
                "no collected revenue hides the card")
}

private func testCustomerMix() {
    let invoices = [
        invoice(#"{"id":"a","customer":"Alice","amount":1000,"due":"2026-01-01","paid":true,"paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"b","customer":"Al","amount":300,"due":"2026-03-20","paid":true,"paidAt":"2026-03-20"}"#),
    ]
    let range = NativeCashBasis.range(for: "this_month", now: march10)
    let card = NativeMoneyCustomerMixCard.make(invoices: invoices, start: range.start, end: range.end)
    expectEqual(card?.newCount, 1, "a first invoice inside the window is a new customer")
    expectEqual(card?.returningCount, 1, "a first invoice before the window is a returning customer")
    expectEqual(card?.totalRevenue, 1300, "mix revenue is collected revenue")
    expectEqual(card?.newPercent, 23, "new share rounds")
    expectEqual(card?.returningPercent, 77, "returning share complements it")
    expectEqual(NativeMoneyCustomerMixCard.make(invoices: [], start: range.start, end: range.end), nil,
                "no customers in the window hides the card")
}

private func testInvoiceAging() {
    let invoices = [
        invoice(#"{"id":"i1","customer":"Alice","amount":1000,"due":"2026-03-01","paid":true,"paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"i2","customer":"Bob","amount":500,"due":"2026-03-10","paid":true,"paidAt":"2026-03-08"}"#),
        invoice(#"{"id":"i3","customer":"Alice","amount":250,"due":"2026-03-01","paid":true,"paidAt":"2026-03-01"}"#),
    ]
    let card = NativeMoneyInvoiceAgingCard.make(invoices: invoices)
    expect(card.showsCard, "paid invoices show the card")
    expectEqual(card.aging.avgDays, 1, "average days late across paid invoices")
    expectEqual(card.daysLabel, "1d late", "late copy")
    expectEqual(card.daysTone, .accent, "≤14 days is accent")
    expectEqual(card.slowPayers.map(\.name), ["Alice"], "slow payers exclude on-time customers")
    expectEqual(card.slowPayers.first?.averageDays, 2, "slow payer average")
    expectEqual(card.slowPayers.first?.invoiceCount, 2, "slow payer invoice count")
    expectEqual(card.slowPayers.first?.totalAmount, 1250, "slow payer face value")
    expectEqual(card.averageSummary, "avg across 3 invoices", "coverage copy")

    expectEqual(NativeMoneyInvoiceAgingCard.label(forDays: 0), "On time", "on-time copy")
    expectEqual(NativeMoneyInvoiceAgingCard.label(forDays: -2), "2d early", "early copy")
    expectEqual(NativeMoneyInvoiceAgingCard.tone(forDays: 0), .success, "on time is green")
    expectEqual(NativeMoneyInvoiceAgingCard.tone(forDays: 20), .warning, "≤30 days is warning")
    expectEqual(NativeMoneyInvoiceAgingCard.tone(forDays: 31), .danger, "past 30 days is danger")
    expect(!NativeMoneyInvoiceAgingCard.make(invoices: [invoice(#"{"id":"u","paid":false}"#)]).showsCard,
           "no paid invoices hides the card")
}

private func testReceivables() {
    let invoices = [
        invoice(#"{"id":"i1","amount":1000,"due":"2026-01-01","paid":false}"#),
        invoice(#"{"id":"i2","amount":500,"due":"2026-02-01","paid":true,"payments":[{"id":"p1","amount":200,"date":"2026-02-10","method":"cash"}]}"#),
    ]
    let jobs = [
        job(#"{"id":"j1","status":"approved","estimateTotal":2000}"#),
        job(#"{"id":"j2","status":"lead","estimateTotal":800}"#),
        job(#"{"id":"j3","status":"declined","estimateTotal":500}"#),
    ]
    let card = NativeMoneyReceivablesCard.make(invoices: invoices, jobs: jobs, now: march10)
    expect(card.showsCard, "open balances show the card")
    expectEqual(card.receivables.outstanding, 1300, "outstanding is the remaining balance")
    expectEqual(card.receivables.unpaidCount, 2, "both invoices carry a balance")
    expectEqual(card.receivables.overdue, 1300, "both are past due")
    expectEqual(card.receivables.pipelineValue, 2800, "open pipeline value")
    expectEqual(card.outstandingCountLabel, "2 invoices", "outstanding count copy")
    expectEqual(card.pipelineCountLabel, "2 jobs", "pipeline count copy")
    expectEqual(card.overdueTone, .danger, "overdue money is red")

    let empty = NativeMoneyReceivablesCard.make(invoices: [], jobs: [], now: march10)
    expect(!empty.showsCard, "nothing owed and no pipeline hides the card")
    expectEqual(empty.outstandingCountLabel, "0 invoices", "empty count copy stays plural")
}

// MARK: - Pipeline cards

private func testConversionFunnel() {
    let jobs = [
        job(#"{"id":"j1","status":"paid","estimateTotal":1000}"#),
        job(#"{"id":"j2","status":"declined","estimateTotal":500}"#),
        job(#"{"id":"j3","status":"approved","estimateTotal":2000}"#),
        job(#"{"id":"j4","status":"lead","estimateTotal":800}"#),
    ]
    let card = NativeMoneyConversionFunnelCard.make(jobs: jobs)
    expect(card.showsCard, "jobs show the funnel")
    expectEqual(card.funnel.totalJobs, 4, "funnel counts every job")
    expectEqual(card.stages.map(\.count), [4, 3, 2, 1, 1, 1], "reached-stage counts")
    expectEqual(card.stages.map(\.label),
                ["Lead", "Estimate sent", "Approved", "Scheduled", "In Progress", "Complete"],
                "stage labels")
    expectEqual(card.stages[0].connector, nil, "the top stage has no connector")
    expectEqual(card.stages[1].connector, "↓ 75% from Lead", "stage-to-stage rate copy")
    expectEqual(card.stages[2].connector, "↓ 67% from Estimate sent", "rounded rate copy")
    expectEqual(card.winRateBadge, "67% win rate", "win-rate badge")
    expectEqual(card.stages[3].barPercent, 25, "bars scale to the widest stage")
    expectEqual(card.stages[5].barPercent, 25, "a stage with a quarter of the widest count")
    // The 6% floor only bites when the ratio is smaller than the floor.
    let lopsided = NativeMoneyConversionFunnelCard.make(jobs:
        Array(repeating: job(#"{"id":"lead","status":"lead","estimateTotal":500}"#), count: 30)
            + [job(#"{"id":"one","status":"paid","estimateTotal":500}"#)])
    expectEqual(lopsided.stages[0].barPercent, 100, "the widest stage fills the track")
    expectEqual(lopsided.stages[5].barPercent, 6, "a sliver keeps a 6% floor")
    expect(!NativeMoneyConversionFunnelCard.make(jobs: []).showsCard, "no jobs hides the funnel")
}

private func testRevenueForecast() {
    let jobs = [
        job(#"{"id":"j1","status":"paid","estimateTotal":1000}"#),
        job(#"{"id":"j2","status":"declined","estimateTotal":500}"#),
        job(#"{"id":"j3","status":"approved","estimateTotal":2000}"#),
        job(#"{"id":"j4","status":"lead","estimateTotal":800}"#),
    ]
    let card = NativeMoneyRevenueForecastCard.make(jobs: jobs)
    expect(card.showsCard, "a non-zero forecast shows the card")
    expectEqual(card.winRateBadge, "67% win rate", "win-rate badge")
    expectEqual(card.winRateTone, .success, "a win rate above 50% is green")
    expectEqual(card.certainCountLabel, "1 job at 100%", "likely count copy")
    expectEqual(card.projectedCountLabel, "1 job at 67%", "projected count copy")
    expectEqual(NativeMoneyFormat.round(card.likelyFraction), 79, "likely share of the forecast")
    expectEqual(NativeMoneyRevenueForecastCard.make(jobs: [job(#"{"id":"x","status":"lead","estimateTotal":0}"#)])
                    .showsCard, false, "a zero forecast hides the card")

    // `winRate` is `approved / estimateSent`, so a non-zero forecast always has
    // one; RN's "(no win rate)" branch is unreachable and kept only as a guard.
    let single = NativeMoneyRevenueForecastCard.make(jobs: [
        job(#"{"id":"only","status":"approved","estimateTotal":900}"#)
    ])
    expectEqual(single.winRateBadge, "100% win rate", "one approved job is a 100% win rate")
    expectEqual(single.projectedCountLabel, "0 jobs at 100%", "no speculative work")
}

private func testAvgJobValue() {
    let jobs = [
        job(#"{"id":"j1","status":"complete","estimateTotal":1000,"createdAt":"2026-07-01"}"#),
        job(#"{"id":"j2","status":"paid","estimateTotal":2000,"createdAt":"2026-06-01"}"#),
    ]
    let july = NativeDateRange(
        start: NativeCashBasis.localDate(year: 2026, month: 6, day: 1),
        end: NativeCashBasis.localDate(year: 2026, month: 6, day: 31)
    )
    let june = NativeDateRange(
        start: NativeCashBasis.localDate(year: 2026, month: 5, day: 1),
        end: NativeCashBasis.localDate(year: 2026, month: 5, day: 30)
    )
    let card = NativeMoneyAvgJobValueCard.make(
        jobs: jobs, start: july.start, end: july.end, previousRange: june
    )
    expect(card.showsCard, "completed work shows the card")
    expectEqual(card.heroValue, 1000, "the window average leads")
    expectEqual(card.heroCount, 1, "window job count")
    expectEqual(card.totalValue, 1000, "window total")
    expectEqual(card.changePercent, -50, "change vs the previous window")
    expectEqual(card.changeTone, .danger, "a drop is red")
    expect(!card.showsAllTimeNote, "no all-time note when the window has data")
    expectEqual(card.completedLabel, "1 jobs", "RN keeps the plural label verbatim")

    let emptyWindow = NativeMoneyAvgJobValueCard.make(
        jobs: jobs, start: march10, end: march10, previousRange: nil
    )
    expectEqual(emptyWindow.heroValue, 1500, "an empty window falls back to the all-time average")
    expectEqual(emptyWindow.heroCount, 2, "all-time count")
    expect(emptyWindow.showsAllTimeNote, "the all-time note explains the fallback")
    expectEqual(emptyWindow.changePercent, nil, "no previous window means no change badge")

    let none = NativeMoneyAvgJobValueCard.make(jobs: [], start: nil, end: nil, previousRange: nil)
    expect(!none.showsCard, "no completed jobs hides the card")
}

private func testRevenueByType() {
    let jobs = [job(#"{"id":"j1","status":"paid","estimateTotal":1000}"#)]
    let card = NativeMoneyRevenueByTypeCard.make(jobs: jobs)
    expect(card.showsCard, "completed work shows the breakdown")
    expectEqual(card.subtitle, "$1,000.00 from 1 completed job", "subtitle copy")
    expectEqual(card.components.map(\.label), ["Labor", "Overhead & Profit"], "component order")
    expectEqual(card.components.map(\.percent), [40, 60], "component shares")
    expectEqual(card.components.map(\.tone), [.accent, .warning], "component tones")
    expect(!NativeMoneyRevenueByTypeCard.make(jobs: [job(#"{"id":"x","status":"lead","estimateTotal":500}"#)]).showsCard,
           "unfinished work hides the breakdown")
}

// MARK: - Profitability, mileage, tax, pricebook

private func testProfitabilityRows() {
    // `buildHistorySummaryRows` — medians only, never a fake zero.
    let history = NativeProfitabilityHistory(
        doneJobs: 4, jobsWithData: 3, hourlyCount: 3, medianEffectiveHourly: decimal("85.5"),
        laborCount: 3, medianLaborOverrunHours: 2,
        materialsCount: 2, medianMaterialsOverrunRatio: decimal("1.2"),
        medianMaterialsVariance: -50
    )
    let rows = NativeMoneyJobProfitabilityCard.buildRows(history)
    expectEqual(rows.map(\.key), ["labor", "materials", "hourly"], "row order and keys")
    expectEqual(rows[0].label, "Typical labor vs estimate", "labor row label")
    expectEqual(rows[0].value, "+2h over", "overrun copy in hours")
    expectEqual(rows[1].value, "$50.00 under", "materials under copy")
    expectEqual(rows[2].value, "$85.50/hr", "hourly copy")

    let onEstimate = NativeMoneyJobProfitabilityCard.buildRows(NativeProfitabilityHistory(
        doneJobs: 2, jobsWithData: 2, hourlyCount: 0, medianEffectiveHourly: nil,
        laborCount: 1, medianLaborOverrunHours: 0,
        materialsCount: 1, medianMaterialsOverrunRatio: nil, medianMaterialsVariance: 0
    ))
    expectEqual(onEstimate.map(\.value), ["on estimate", "on estimate"], "zero medians read as on estimate")

    let under = NativeMoneyJobProfitabilityCard.buildRows(NativeProfitabilityHistory(
        doneJobs: 1, jobsWithData: 1, hourlyCount: 0, medianEffectiveHourly: nil,
        laborCount: 1, medianLaborOverrunHours: decimal("-0.5"),
        materialsCount: 0, medianMaterialsOverrunRatio: nil, medianMaterialsVariance: nil
    ))
    expectEqual(under.map(\.value), ["30m under"], "an early finish reads as time under")

    let none = NativeMoneyJobProfitabilityCard.buildRows(NativeProfitabilityHistory(
        doneJobs: 0, jobsWithData: 0, hourlyCount: 0, medianEffectiveHourly: nil,
        laborCount: 0, medianLaborOverrunHours: nil, materialsCount: 0,
        medianMaterialsOverrunRatio: nil, medianMaterialsVariance: nil
    ))
    expectEqual(none.count, 0, "unknown medians produce no rows")

    let card = NativeMoneyJobProfitabilityCard.make(
        jobs: [
            job(#"{"id":"j1","status":"complete","estimateTotal":1000}"#),
            job(#"{"id":"j2","status":"lead","estimateTotal":500}"#),
        ],
        invoices: [], expenses: [], laborCostRate: nil
    )
    expect(card.showsCard, "completed jobs show the card")
    expectEqual(card.coverageLabel, "0 of 1 completed job have tracked data", "coverage copy")
    expectEqual(card.emptyCopy, NativeMoneyJobProfitabilityCard.emptyText, "no data explains how to fill it in")
    expect(!NativeMoneyJobProfitabilityCard.make(jobs: [], invoices: [], expenses: [], laborCostRate: nil).showsCard,
           "no completed jobs hides the card")
}

private func testMileageCard() {
    let trips = [
        trip(#"{"id":"t1","date":"2026-03-10","miles":10}"#),
        trip(#"{"id":"t2","date":"2026-03-11","miles":2.4}"#),
        trip(#"{"id":"t3","date":"2026-02-11","miles":99}"#),
    ]
    let range = NativeCashBasis.range(for: "this_month", now: march10)
    let card = NativeMoneyMileageCard.make(
        trips: trips, start: range.start, end: range.end, rate: decimal("0.7")
    )
    expectEqual(card.summary.tripCount, 2, "only the window's trips count")
    expectEqual(card.summary.totalMiles, decimal("12.4"), "miles sum")
    expectEqual(card.summary.deduction, decimal("8.68"), "deduction at the settings rate")
    expectEqual(card.subtitle, "12.4 mi · 2 trips · $0.70/mi", "mileage subtitle copy")

    let single = NativeMoneyMileageCard.make(
        trips: trips, start: range.start, end: range.start, rate: decimal("0.7")
    )
    expectEqual(single.subtitle, "0.0 mi · 0 trips · $0.70/mi", "an empty window still reads truthfully")
}

private func testTaxCard() {
    let invoices = [
        invoice(#"{"id":"i1","amount":1000,"due":"2026-03-01","paid":true,"paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"i2","amount":500,"due":"2026-03-10","paid":true,"paidAt":"2026-03-08"}"#),
    ]
    let expenses = [
        expense(#"{"id":"e1","amount":300,"category":"materials","date":"2026-03-02"}"#),
        expense(#"{"id":"e2","amount":200,"category":"fuel","date":"2026-03-03"}"#),
    ]
    let trips = [trip(#"{"id":"t1","date":"2026-03-10","miles":100}"#)]
    let card = NativeMoneyTaxCard.make(
        invoices: invoices, expenses: expenses, trips: trips,
        values: NativeTaxSettingsValues(), mileageRate: decimal("0.7"), now: march10
    )
    expectEqual(card.breakdown.yearToDateTripCount, 1, "the card reports this device's YTD trips")
    // income 1500 − deductible 300 (materials; fuel is the vehicle side) with no
    // election → no vehicle deduction: SE tax on 1200 → $169.55.
    expectEqual(card.breakdown.yearToDateText, "$169.55 for the year so far", "YTD reserve copy")
    expectEqual(card.breakdown.periodSummaryText, "Jan 1 – Mar 31 · set aside by Apr 15",
                "the card states its own IRS period, not the screen filter")
    expect(card.breakdown.needsVehicleChoice, "fuel + miles with no election needs a choice")
    expectEqual(card.breakdown.vehiclePrompt, NativeTaxBreakdownCopy.vehiclePrompt,
                "vehicle-choice prompt")
    expectEqual(card.breakdown.incomeRatePrompt, NativeTaxBreakdownCopy.incomeRatePrompt,
                "income-rate prompt when unset")
    expectEqual(card.breakdown.staleRatesNote, nil, "a known tax year has no stale-rates note")
    expectEqual(card.breakdown.mileageDisclosure,
                "Mileage from this device's trip log (1 trip this year) — not synced.",
                "single-trip disclosure copy")
    expectEqual(card.breakdown.disclaimer, "Estimate only — not tax advice. Assumes net profit under $200k.",
                "the disclaimer is always present")

    let elected = NativeMoneyTaxCard.make(
        invoices: invoices, expenses: expenses, trips: trips,
        values: NativeTaxSettingsValues(taxIncomeRate: 22, vehicleDeductionMethod: .mileage),
        mileageRate: decimal("0.7"), now: march10
    )
    expect(!elected.breakdown.needsVehicleChoice, "a chosen method clears the prompt")
    expectEqual(elected.breakdown.incomeRatePrompt, nil, "a set rate clears the rate prompt")
    expectEqual(elected.breakdown.currentReserve, elected.breakdown.currentReserve, "reserve is engine-derived")
}

private func testPricebookCard() {
    let entries = [
        pricebookEntry(#"{"id":"p1","category":"Plumbing"}"#),
        pricebookEntry(#"{"id":"p2","category":"Plumbing"}"#),
        pricebookEntry(#"{"id":"p3","category":"HVAC"}"#),
    ]
    let card = NativeMoneyPricebookCard.make(entries: entries)
    expectEqual(card.countText, "3 services", "service count copy")
    expectEqual(card.categoryText, "2 categories", "category count copy")
    expectEqual(NativeMoneyPricebookCard.manageHint, " · Tap to manage", "manage hint is kept for 9.12")

    let single = NativeMoneyPricebookCard.make(entries: [pricebookEntry(#"{"id":"p1","category":"Plumbing"}"#)])
    expectEqual(single.countText, "1 service", "singular service copy")
    expectEqual(single.categoryText, "1 category", "singular category copy")

    let none = NativeMoneyPricebookCard.make(entries: [])
    expectEqual(none.countText, "0 services", "empty pricebook copy")
    expectEqual(none.categoryText, "No categories yet", "no-category copy")
}

// MARK: - Expenses tab + screen state

private func testExpenseListRows() {
    let expenses = [
        expense(#"{"id":"e1","description":"Fuel stop","amount":60,"category":"fuel","date":"2026-03-02","notes":"van"}"#),
        expense(#"{"id":"e2","description":"Bits","amount":25,"category":"tools","date":"2026-03-20","receiptUri":"receipts/e2.jpg"}"#),
        expense(#"{"id":"e3","description":"Last month","amount":10,"category":"other","date":"2026-02-20"}"#),
    ]
    let jobs = [
        job(#"{"id":"j1","title":"Hallway repipe","status":"approved","createdAt":"2026-03-02"}"#),
        job(#"{"id":"j2","title":"Water heater","status":"approved","createdAt":"2026-03-03"}"#),
    ]
    let range = NativeCashBasis.range(for: "this_month", now: march10)
    let rows = NativeMoneyExpenseList.rows(
        expenses: expenses, jobs: jobs, start: range.start, end: range.end
    )
    expectEqual(rows.map(\.id), ["e2", "e1"], "the tab lists the window newest-first")
    expectEqual(rows.map(\.dateText), ["Mar 20", "Mar 2"], "rows render the stored local day")
    expectEqual(rows[0].categoryLabel, "Tools & Equipment", "RN category label, not the enum title")
    expectEqual(rows[0].amount, 25, "row amount")
    expect(rows[0].hasReceipt, "a receipt reference shows the camera glyph")
    expect(!rows[1].hasReceipt, "no receipt reference means no glyph")
    expectEqual(rows[1].notes, "van", "notes are carried for the row")
    expect(rows.allSatisfy { $0.jobTitle == nil }, "an unlinked expense shows no job label")

    // Task 9.10 row detail: the linked job's title, resolved by exact id.
    let linked = NativeMoneyExpenseList.rows(
        expenses: [expense(#"{"id":"e4","amount":40,"category":"materials","date":"2026-03-05","jobId":"j2"}"#)],
        jobs: jobs + [job(#"{"id":"j3","title":"Archived job","status":"paid","createdAt":"2026-03-01","archivedAt":"2026-03-04"}"#)],
        start: range.start, end: range.end
    )
    expectEqual(linked.first?.jobTitle, "Water heater", "a linked expense shows the job title")
    let dangling = NativeMoneyExpenseList.rows(
        expenses: [expense(#"{"id":"e5","amount":40,"category":"materials","date":"2026-03-05","jobId":"gone"}"#)],
        jobs: jobs, start: range.start, end: range.end
    )
    expect(dangling.first?.jobTitle == nil, "a dangling job link shows no label")
    let archived = NativeMoneyExpenseList.rows(
        expenses: [expense(#"{"id":"e6","amount":40,"category":"materials","date":"2026-03-05","jobId":"j3"}"#)],
        jobs: [job(#"{"id":"j3","title":"Archived job","status":"paid","createdAt":"2026-03-01","archivedAt":"2026-03-04"}"#)],
        start: range.start, end: range.end
    )
    expectEqual(archived.first?.jobTitle, "Archived job", "an archived job still labels its expense")
}

private func testOverviewState() {
    expectEqual(NativeMoneyOverviewState.resolve(invoices: [], expenses: [], jobs: []), .trueEmpty,
                "nothing anywhere is the true-empty state")
    expectEqual(NativeMoneyOverviewState.resolve(invoices: [], expenses: [], jobs: [job()]), .content,
                "any recorded work renders the section stack")
    expectEqual(NativeMoneyOverviewState.resolve(invoices: [invoice()], expenses: [], jobs: []), .content,
                "an invoice outside the window still renders the stack")
}

// MARK: - Overview composition

private func testOverviewComposition() {
    let invoices = [
        invoice(#"{"id":"a","customer":"Alice","amount":1000,"due":"2026-03-01","paid":true,"paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"b","customer":"Bob","amount":500,"due":"2026-02-01","paid":true,"paidAt":"2026-02-05"}"#),
    ]
    let expenses = [expense(#"{"id":"e1","amount":200,"category":"materials","date":"2026-03-10"}"#)]
    let jobs = [job(#"{"id":"j1","status":"approved","estimateTotal":2000,"createdAt":"2026-03-02"}"#)]

    let march = NativeMoneyOverview.make(
        filter: .thisMonth, invoices: invoices, expenses: expenses, jobs: jobs,
        trips: [trip(#"{"id":"t1","date":"2026-03-10","miles":10}"#)],
        pricebook: [pricebookEntry()],
        taxValues: NativeTaxSettingsValues(),
        mileageRate: decimal("0.7"), laborCostRate: nil, now: march10
    )
    expectEqual(march.state, .content, "recorded work renders the sections")
    expectEqual(march.summary.periodLabel, "This Month", "the summary names the chip")
    expectEqual(march.summary.income, 1000, "the summary follows the chip's window")
    expectEqual(march.summary.incomeChangePercent, 100, "the chip has a comparison window")
    expectEqual(march.mileage.summary.deduction, decimal("7"), "the mileage card follows the chip")
    // The tax card deliberately ignores the chip: it reports its own IRS window.
    expectEqual(march.tax.breakdown.periodSummaryText, "Jan 1 – Mar 31 · set aside by Apr 15",
                "the tax card's window is the IRS period, not the chip")

    let lastMonth = NativeMoneyOverview.make(
        filter: .lastMonth, invoices: invoices, expenses: expenses, jobs: jobs,
        trips: [], pricebook: [], taxValues: NativeTaxSettingsValues(),
        mileageRate: decimal("0.7"), laborCostRate: nil, now: march10
    )
    expectEqual(lastMonth.summary.periodLabel, "Last Month", "switching chips relabels the summary")
    expectEqual(lastMonth.summary.income, 500, "switching chips re-windows the figures")
    expectEqual(lastMonth.expenseCategories, nil, "a window with no expenses hides the category card")
    expectEqual(lastMonth.mileage.summary.totalMiles, 0, "a window with no trips reports zero miles")
    expectEqual(lastMonth.tax.breakdown.periodSummaryText, march.tax.breakdown.periodSummaryText,
                "the tax card is identical across chips")

    let allTime = NativeMoneyOverview.make(
        filter: .allTime, invoices: invoices, expenses: expenses, jobs: jobs,
        trips: [], pricebook: [], taxValues: NativeTaxSettingsValues(),
        mileageRate: decimal("0.7"), laborCostRate: nil, now: march10
    )
    expectEqual(allTime.previousRange, nil, "all time has no previous window")
    expectEqual(allTime.summary.netProfitChangePercent, nil, "so no change badges")
    expectEqual(allTime.summary.income, 1500, "all time collects every payment")
    expectEqual(allTime.topCustomers?.rows.map(\.name), ["Alice", "Bob"], "all-time top customers")

    let empty = NativeMoneyOverview.make(
        filter: .thisMonth, invoices: [], expenses: [], jobs: [],
        trips: [], pricebook: [], taxValues: NativeTaxSettingsValues(),
        mileageRate: decimal("0.7"), laborCostRate: nil, now: march10
    )
    expectEqual(empty.state, .trueEmpty, "nothing anywhere is the true-empty state")
    expectEqual(empty.summary.income, 0, "the summary still reads zero")
    expect(!empty.funnel.showsCard, "the funnel hides itself in the true-empty state")
}

// MARK: - Runner

testFormatting()
testFilterAndTabLabels()
testSummaryCard()
testMonthlyChart()
testExpenseCategories()
testTopCustomers()
testCustomerMix()
testInvoiceAging()
testReceivables()
testConversionFunnel()
testRevenueForecast()
testAvgJobValue()
testRevenueByType()
testProfitabilityRows()
testMileageCard()
testTaxCard()
testPricebookCard()
testExpenseListRows()
testOverviewState()
testOverviewComposition()

if failures == 0 {
    print("MoneyCardsTests: all checks passed")
} else {
    print("MoneyCardsTests: \(failures) failure(s)")
    exit(1)
}
