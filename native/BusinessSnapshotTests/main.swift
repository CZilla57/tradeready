import Foundation

// Business snapshot tests (task 10.01, requirements S1, S2).
//
// Ports the load-bearing vectors from the React Native oracle suites
// `__tests__/businessSnapshot.test.js` and `__tests__/estimateSnapshot.test.js`.
// The pinned clock is July 6 2026 (the RN suite pins the same moment), and the
// runner is executed under a west-of-UTC timezone so any accidental UTC date
// parse would surface. No test mutates canonical state.

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

/// `inv()` from the oracle: unpaid by default, due 2026-07-01, amount 0.
private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"i","customer":"C","number":"INV-1","amount":0,"due":"2026-07-01",
     "email":"","phone":"","desc":"","paid":false}
    """
    return try! decoder.decode(Canonical.Invoice.self, from: Data(merge(base, overrides).utf8))
}

private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j","customerId":"","customerName":"","title":"","description":"","status":"lead",
     "address":"","estimateTotal":0,"laborHours":0,"laborRate":85,"materials":[],
     "materialMarkup":20,"overhead":15,"margin":20,"notes":"","createdAt":"2026-07-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

private func customer(_ overrides: String = "") -> Canonical.Customer {
    let base = """
    {"id":"","name":"","email":"","phone":"","address":"","notes":""}
    """
    return try! decoder.decode(Canonical.Customer.self, from: Data(merge(base, overrides).utf8))
}

private func expense(_ overrides: String = "") -> Canonical.Expense {
    let base = """
    {"id":"e1","createdAt":"2026-07-01","description":"","amount":100,"category":"fuel",
     "date":"2026-07-01","notes":""}
    """
    return try! decoder.decode(Canonical.Expense.self, from: Data(merge(base, overrides).utf8))
}

/// `new Date(2026, 6, 6)` — July 6 2026, local midnight (the pinned oracle clock).
private let july6 = NativeCashBasis.localDate(year: 2026, month: 6, day: 6)

private func aggregate(
    invoices: [Canonical.Invoice] = [],
    jobs: [Canonical.Job] = [],
    customers: [Canonical.Customer] = []
) -> NativeBusinessSnapshotAggregate {
    NativeBusinessSnapshotEngine.aggregate(
        invoices: invoices, jobs: jobs, customers: customers, now: july6
    )
}

// MARK: - Revenue windows

private func testRevenueBuckets() {
    let snap = aggregate(invoices: [
        invoice(#"{"id":"i1","paid":true,"paidAt":"2026-07-02","amount":500}"#),
        invoice(#"{"id":"i2","paid":true,"paidAt":"2026-06-30","amount":200}"#),
        invoice(#"{"id":"i3","paid":true,"paidAt":"2026-05-15","amount":100}"#),
    ])
    expectEqual(snap.revenueThisMonth, 500, "this-month revenue buckets by payment date")
    expectEqual(snap.revenueLastMonth, 200, "last-month revenue buckets by payment date")

    let legacy = aggregate(invoices: [
        invoice(#"{"id":"i1","paid":true,"due":"2026-07-05","amount":300}"#),
    ])
    expectEqual(legacy.revenueThisMonth, 300, "a legacy paid invoice falls back to its due date")

    // January rollover: the previous month is December of the prior year.
    let january = NativeCashBasis.localDate(year: 2026, month: 0, day: 15)
    let rollover = NativeBusinessSnapshotEngine.aggregate(
        invoices: [
            invoice(#"{"id":"i1","paid":true,"paidAt":"2026-01-05","amount":400}"#),
            invoice(#"{"id":"i2","paid":true,"paidAt":"2025-12-20","amount":250}"#),
        ],
        jobs: [], customers: [], now: january
    )
    expectEqual(rollover.revenueThisMonth, 400, "January's this-month window")
    expectEqual(rollover.revenueLastMonth, 250, "January's last-month window rolls back a year")
}

// MARK: - Outstanding and overdue

private func testOutstandingAndOverdue() {
    let snap = aggregate(invoices: [
        invoice(#"{"id":"i1","paid":false,"due":"2026-06-01","amount":150}"#),
        invoice(#"{"id":"i2","paid":false,"due":"2026-07-06","amount":100}"#),
        invoice(#"{"id":"i3","paid":false,"due":"2026-08-01","amount":200}"#),
    ])
    expectEqual(snap.outstandingTotal, 450, "outstanding sums every remaining balance")
    expectEqual(snap.overdueTotal, 150, "due today is not overdue")
    expectEqual(snap.overdueCount, 1, "only the past-due invoice counts")

    // A partly-paid invoice contributes revenue AND outstanding, and a voided
    // payment never counts as revenue.
    let partial = aggregate(invoices: [
        invoice(#"{"id":"i1","paid":false,"amount":1000,"due":"2026-06-01","payments":[{"id":"p1","amount":400,"date":"2026-07-02","method":"cash"}]}"#),
    ])
    expectEqual(partial.revenueThisMonth, 400, "revenue counts payments received, not the face value")
    expectEqual(partial.outstandingTotal, 600, "the unpaid remainder is still outstanding")

    let voided = aggregate(invoices: [
        invoice(#"{"id":"i1","paid":false,"amount":1000,"due":"2026-06-01","payments":[{"id":"p1","amount":400,"date":"2026-07-02","method":"cash","voidedAt":"2026-07-03"}]}"#),
    ])
    expectEqual(voided.revenueThisMonth, 0, "a voided payment is not revenue")
    expectEqual(voided.outstandingTotal, 1000, "a voided payment leaves the full balance")

    let overpaid = aggregate(invoices: [
        invoice(#"{"id":"i1","paid":true,"amount":100,"due":"2026-06-01","payments":[{"id":"p1","amount":150,"date":"2026-07-02","method":"cash"}]}"#),
    ])
    expectEqual(overpaid.revenueThisMonth, 150, "an overpayment counts what was actually received")
    expectEqual(overpaid.outstandingTotal, 0, "an overpaid invoice has no balance")
    expectEqual(overpaid.overdueCount, 0, "an overpaid invoice is not overdue")
}

// MARK: - Jobs

private func testActiveJobsAndAverage() {
    let snap = aggregate(jobs: [
        job(#"{"id":"j1","status":"lead"}"#),
        job(#"{"id":"j2","status":"lead"}"#),
        job(#"{"id":"j3","status":"scheduled"}"#),
        job(#"{"id":"j4","status":"complete"}"#),
    ])
    expectEqual(snap.activeJobsByStatus, ["lead": 2, "scheduled": 1], "active jobs bucketed by status; done jobs excluded")

    let average = aggregate(jobs: [
        job(#"{"id":"j1","status":"complete","estimateTotal":1000}"#),
        job(#"{"id":"j2","status":"paid","estimateTotal":500}"#),
        job(#"{"id":"j3","status":"lead","estimateTotal":800}"#),
    ])
    expectEqual(average.avgCompletedJobValue, 750, "average completed job value uses done jobs only")

    let withChangeOrder = aggregate(jobs: [
        job(#"{"id":"j1","status":"complete","estimateTotal":2400,"changeOrders":[{"id":"coA","title":"X","amount":850,"createdAt":"2026-07-01","manualDecision":{"decision":"approved","decidedAt":"2026-07-02"}}]}"#),
    ])
    expectEqual(withChangeOrder.avgCompletedJobValue, 3250, "the average includes APPROVED change orders")

    let unapproved = aggregate(jobs: [
        job(#"{"id":"j1","status":"complete","estimateTotal":2400,"changeOrders":[{"id":"coA","title":"X","amount":850,"createdAt":"2026-07-01"}]}"#),
    ])
    expectEqual(unapproved.avgCompletedJobValue, 2400, "an unapproved change order does not count")

    let zeroTotal = aggregate(jobs: [
        job(#"{"id":"j1","status":"complete","estimateTotal":0}"#),
    ])
    expectEqual(zeroTotal.avgCompletedJobValue, 0, "a zero-total done job does not create an average")
}

// MARK: - Customers

private func testTopCustomers() {
    let snap = aggregate(
        invoices: [
            invoice(#"{"id":"i1","customer":"A","customerId":"cA","amount":500,"paid":true,"paidAt":"2026-01-01"}"#),
            invoice(#"{"id":"i2","customer":"B","customerId":"cB","amount":200,"paid":false,"due":"2026-08-01"}"#),
        ],
        customers: [customer(#"{"id":"cA","name":"A"}"#), customer(#"{"id":"cB","name":"B"}"#)]
    )
    expectEqual(snap.totalCustomers, 2, "every customer record counts")
    expectEqual(snap.topCustomers.count, 2, "top customers are returned in order")
    expectEqual(snap.topCustomers.first?.name, "A", "highest lifetime spend leads")
    expectEqual(snap.topCustomers.first?.lifetimeSpend, 500, "lifetime spend is collected")
    expectEqual(snap.topCustomers.first?.amountOwed, 0, "a paid customer owes nothing")
    expectEqual(snap.topCustomers.last?.name, "B", "the zero-spend customer still appears")
    expectEqual(snap.topCustomers.last?.amountOwed, 200, "the unpaid balance is carried")

    // An invoice-only customer (no record) still joins by normalized name.
    let invoiceOnly = aggregate(invoices: [
        invoice(#"{"id":"i1","customer":"  Casey  ","amount":400,"paid":true,"paidAt":"2026-07-02"}"#),
    ])
    expectEqual(invoiceOnly.totalCustomers, 1, "an invoice-only customer still appears")
    expectEqual(invoiceOnly.topCustomers.first?.name, "Casey", "the derived name is trimmed")

    // Top five only, ranked by lifetime spend.
    let many = aggregate(invoices: (1...7).map {
        invoice(#"{"id":"i\#($0)","customer":"C\#($0)","amount":\#($0 * 100),"paid":true,"paidAt":"2026-07-02"}"#)
    })
    expectEqual(many.topCustomers.count, 5, "the snapshot keeps the top five customers")
    expectEqual(many.topCustomers.map(\.name), ["C7", "C6", "C5", "C4", "C3"], "ranked by lifetime spend")
    expectEqual(many.totalCustomers, 7, "total customers counts all of them")

    let empty = aggregate()
    expectEqual(empty.topCustomers, [], "no customers means an empty list")
    expectEqual(empty.totalCustomers, 0, "and a zero total")
}

// MARK: - Empty inputs

private func testEmptyInputs() {
    let snap = aggregate()
    expectEqual(snap.revenueThisMonth, 0, "empty revenue this month")
    expectEqual(snap.revenueLastMonth, 0, "empty revenue last month")
    expectEqual(snap.outstandingTotal, 0, "empty outstanding")
    expectEqual(snap.overdueTotal, 0, "empty overdue")
    expectEqual(snap.overdueCount, 0, "empty overdue count")
    expectEqual(snap.activeJobsByStatus, [:], "no active jobs means no status keys at all")
    expectEqual(snap.avgCompletedJobValue, 0, "no done jobs means a zero average")
}

// MARK: - Tax block

private func testTaxBlock() {
    let block = NativeBusinessSnapshotEngine.buildTaxBlock(
        invoices: [
            invoice(#"{"id":"i1","amount":10000,"due":"2026-07-01","payments":[{"id":"p1","amount":10000,"date":"2026-06-15","method":"cash"}]}"#),
        ],
        expenses: [], trips: [],
        values: NativeTaxSettingsValues(taxIncomeRate: 10, vehicleDeductionMethod: .mileage),
        mileageRate: decimal("0.7"),
        now: july6
    )
    expectEqual(block.periodLabel, "Jun 1 – Aug 31", "the tax period label")
    expectEqual(block.dueLabel, "Sep 15", "the tax deadline label")
    expect(block.periodReserve > 0, "a positive period reserve")
    expect(block.yearToDateReserve >= block.periodReserve, "YTD is at least the period")
    expectEqual(block.incomeRateSet, true, "an income rate is set")
    expectEqual(block.needsVehicleChoice, false, "a vehicle method is chosen")
    expectEqual(block.ratesKnown, true, "a known tax year has known rates")

    let unset = NativeBusinessSnapshotEngine.buildTaxBlock(
        invoices: [],
        expenses: [expense()],
        trips: [],
        values: NativeTaxSettingsValues(),
        mileageRate: decimal("0.7"),
        now: july6
    )
    expectEqual(unset.incomeRateSet, false, "an unset income rate is flagged for the coach caveat")
    expectEqual(unset.needsVehicleChoice, true, "vehicle inputs with no election are flagged")
}

// MARK: - The live-shaped snapshot

private func testSnapshotStampsAndTaxPresence() {
    let snapshot = NativeBusinessSnapshotEngine.make(
        invoices: [invoice(#"{"id":"i1","paid":true,"paidAt":"2026-07-02","amount":500}"#)],
        jobs: [job(#"{"id":"j1","status":"complete","estimateTotal":1000}"#)],
        customers: [customer(#"{"id":"c1","name":"Ada"}"#)],
        expenses: [], trips: [],
        values: NativeTaxSettingsValues(taxIncomeRate: 10, vehicleDeductionMethod: .mileage),
        mileageRate: decimal("0.7"),
        now: july6
    )
    expectEqual(snapshot.asOf, "2026-07-06", "asOf is the UTC date of the snapshot moment")
    expectEqual(snapshot.revenueThisMonth, 500, "the live snapshot carries the aggregate")
    expectEqual(snapshot.avgCompletedJobValue, 1000, "and the job average")
    expect(snapshot.tax != nil, "the tax block is attached")

    // Late-evening local time is already the NEXT UTC day — asOf follows UTC.
    let lateEvening = NativeCashBasis.localDate(year: 2026, month: 6, day: 6, hour: 20)
    expectEqual(NativeBusinessSnapshotEngine.utcDateString(lateEvening), "2026-07-07",
                "asOf is a UTC stamp, not the local business day")

    let withoutTax = NativeBusinessSnapshotEngine.make(
        invoices: [], jobs: [], customers: [], expenses: [], trips: [],
        values: NativeTaxSettingsValues(), mileageRate: decimal("0.7"),
        now: july6, includeTax: false
    )
    expectEqual(withoutTax.tax, nil, "a failed tax input leaves the block ABSENT, never zeroed")
    expectEqual(withoutTax.revenueThisMonth, 0, "the rest of the snapshot still renders")
}

// MARK: - Runner

testRevenueBuckets()
testOutstandingAndOverdue()
testActiveJobsAndAverage()
testTopCustomers()
testEmptyInputs()
testTaxBlock()
testSnapshotStampsAndTaxPresence()

if failures == 0 {
    print("BusinessSnapshotTests: all checks passed")
} else {
    print("BusinessSnapshotTests: \(failures) failure(s)")
    exit(1)
}
