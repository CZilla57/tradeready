import Foundation

// Job profitability adapter + engine tests.
//
// Ports the T1–T15 fixture vectors from `__tests__/jobProfitability.test.ts`
// and the direct-cost vectors from
// `__tests__/jobProfitabilityDirectCosts.test.ts` through the canonical
// adapter (`NativeJobProfitability` → `ProfitabilityInput` →
// `JobProfitabilityEngine`), plus the display view-model checks from
// `__tests__/profitabilityDisplay.test.ts`.
//
// Unknown ≠ zero: absent data must surface as nil + warning, never zero.
// One deliberate adaptation: the RN T12 vector feeds NaN/Infinity/string
// amounts through a coercing `toAmount`; canonical `Decimal` values are
// always finite, so T12 here pins that zero amounts stay finite and neutral
// instead of poisoning figures.

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

private func decodeJob(_ json: String) throws -> Canonical.Job {
    try JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

private func decodeInvoice(_ json: String) throws -> Canonical.Invoice {
    try JSONDecoder().decode(Canonical.Invoice.self, from: Data(json.utf8))
}

private func decodeExpense(_ json: String) throws -> Canonical.Expense {
    try JSONDecoder().decode(Canonical.Expense.self, from: Data(json.utf8))
}

private func decodeJobCost(_ json: String) throws -> Canonical.JobCost {
    try JSONDecoder().decode(Canonical.JobCost.self, from: Data(json.utf8))
}

private func baseJob(
    status: String = "paid",
    estimateTotal: String = "966",
    laborHours: String = "4",
    materials: String = """
    [{"id":"m1","name":"Heater","quantity":1,"unitCost":200},\
    {"id":"m2","name":"Fittings","quantity":2,"unitCost":50}]
    """
) throws -> Canonical.Job {
    try decodeJob("""
    {"id":"j1","customerId":"c1","customerName":"Dana","title":"Water heater swap",\
    "description":"","status":"\(status)","address":"",\
    "estimateTotal":\(estimateTotal),"laborHours":\(laborHours),"laborRate":85,\
    "materials":\(materials),"materialMarkup":20,"overhead":15,"margin":20,\
    "notes":"","createdAt":"2026-08-01"}
    """)
}

private func invoice(
    id: String = "inv1",
    amount: String = "1166",
    jobId: String? = "j1",
    paid: Bool = false,
    paidAt: String? = nil,
    payments: String? = nil
) throws -> Canonical.Invoice {
    var json = """
    {"id":"\(id)","customer":"Dana","number":"INV-0001","amount":\(amount),\
    "due":"2026-08-10","email":"","phone":"","desc":"","paid":\(paid ? "true" : "false")
    """
    if let jobId { json += ",\"jobId\":\"\(jobId)\"" }
    if let paidAt { json += ",\"paidAt\":\"\(paidAt)\"" }
    if let payments { json += ",\"payments\":\(payments)" }
    json += "}"
    return try decodeInvoice(json)
}

private func expense(
    id: String = "e1",
    amount: String = "340",
    category: String = "materials",
    jobId: String? = "j1",
    description: String = "Supply-house run"
) throws -> Canonical.Expense {
    var json = """
    {"id":"\(id)","createdAt":"2026-08-02","description":"\(description)",\
    "amount":\(amount),"category":"\(category)","date":"2026-08-02","notes":""
    """
    if let jobId { json += ",\"jobId\":\"\(jobId)\"" }
    json += "}"
    return try decodeExpense(json)
}

private func approvedOrder(id: String = "co1", amount: String = "200", title: String = "Extra shutoff valve") -> Canonical.ChangeOrder {
    Canonical.ChangeOrder(
        id: id,
        title: title,
        amount: decimal(amount),
        createdAt: "2026-08-02",
        manualDecision: Canonical.ChangeOrderDecision(decision: "approved", decidedAt: "2026-08-02")
    )
}

private let closedSessions = [
    Canonical.TimeSession(start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T11:00:00.000Z"),
    Canonical.TimeSession(start: "2026-08-03T08:00:00.000Z", end: "2026-08-03T10:30:00.000Z"),
]

private let exampleAPayments = """
[{"id":"p1","amount":300,"date":"2026-08-01","method":"check"},\
{"id":"stripe_cs_1","amount":866,"date":"2026-08-05","method":"stripe"}]
"""

/// Example A from the design doc: tracked, change-ordered, fully collected.
private func exampleA() throws -> (Canonical.Job, [Canonical.Invoice], [Canonical.Expense]) {
    var job = try baseJob()
    job.invoiceId = "inv1"
    job.changeOrders = [approvedOrder()]
    job.timeSessions = closedSessions
    let inv = try invoice(jobId: "j1", paid: true, paidAt: "2026-08-05", payments: exampleAPayments)
    let expenses = [
        try expense(),
        try expense(id: "e2", amount: "25", category: "fuel", description: "Gas"),
    ]
    return (job, [inv], expenses)
}

@main
struct JobProfitabilityTests {
    static func main() throws {
        // MARK: - T1 — Example A: every figure

        do {
            let (job, invoices, expenses) = try exampleA()
            let r = NativeJobProfitability.calculate(job: job, invoices: invoices, expenses: expenses, laborCostRate: nil)

            expectEqual(r.estimatedRevenue, decimal("966"), "T1 estimatedRevenue")
            expectEqual(r.changeOrderRevenue, decimal("200"), "T1 changeOrderRevenue")
            expectEqual(r.finalBillable, decimal("1166"), "T1 finalBillable")
            expectEqual(r.invoicedAmount, decimal("1166"), "T1 invoicedAmount")
            expectEqual(r.cashCollected, decimal("1166"), "T1 cashCollected")
            expectEqual(r.outstandingReceivable, decimal("0"), "T1 outstandingReceivable")
            expectEqual(r.overpaidAmount, decimal("0"), "T1 overpaidAmount")

            expectEqual(r.estimatedLaborHours, decimal("4"), "T1 estimatedLaborHours")
            expectEqual(r.billableLaborRate, decimal("85"), "T1 billableLaborRate")
            expectEqual(r.actualLaborHours, decimal("5.5"), "T1 actualLaborHours")
            expectEqual(r.laborHoursVariance, decimal("1.5"), "T1 laborHoursVariance")
            expect(r.estimatedOwnerLaborCost == nil, "T1 estimatedOwnerLaborCost nil without a rate")
            expect(r.actualOwnerLaborCost == nil, "T1 actualOwnerLaborCost nil without a rate")

            expectEqual(r.estimatedMaterialCost, decimal("300"), "T1 estimatedMaterialCost")
            expectEqual(r.actualMaterialExpense, decimal("340"), "T1 actualMaterialExpense")
            expectEqual(r.otherDirectExpenses, decimal("25"), "T1 otherDirectExpenses")
            expectEqual(r.materialsVariance, decimal("40"), "T1 materialsVariance")

            expectEqual(r.estimatedGrossProfit, decimal("666"), "T1 estimatedGrossProfit")
            expectEqual(r.actualGrossProfitBilled, decimal("801"), "T1 actualGrossProfitBilled")
            expectEqual(r.actualGrossProfitCash, decimal("801"), "T1 actualGrossProfitCash")
            expectEqual(r.effectiveHourlyActual, decimal("145.64"), "T1 effectiveHourlyActual")

            expect(r.processingFees == nil, "T1 processingFees nil — fees never invented")
            expectEqual(r.warnings, [.feesUnknown, .laborCostRateUnset], "T1 warnings exact and ordered")
        }

        // MARK: - T2 — Legacy job: everything unknown stays unknown

        do {
            var job = try baseJob(estimateTotal: "600", laborHours: "3", materials: "[]")
            job.invoiceId = "legacyInv"
            let inv = try invoice(id: "legacyInv", amount: "600", jobId: nil, paid: true)
            let r = NativeJobProfitability.calculate(job: job, invoices: [inv], expenses: [], laborCostRate: nil)

            expectEqual(r.invoicedAmount, decimal("600"), "T2 invoicedAmount")
            expectEqual(r.cashCollected, decimal("600"), "T2 legacy paid fallback collected")
            expectEqual(r.outstandingReceivable, decimal("0"), "T2 outstandingReceivable")
            expect(r.actualLaborHours == nil, "T2 actualLaborHours nil")
            expect(r.laborHoursVariance == nil, "T2 laborHoursVariance nil")
            expect(r.actualMaterialExpense == nil, "T2 actualMaterialExpense nil")
            expect(r.otherDirectExpenses == nil, "T2 otherDirectExpenses nil")
            expect(r.materialsVariance == nil, "T2 materialsVariance nil")
            expect(r.effectiveHourlyActual == nil, "T2 effectiveHourlyActual nil")
            expectEqual(r.estimatedGrossProfit, decimal("600"), "T2 estimatedGrossProfit")
            expectEqual(r.actualGrossProfitBilled, decimal("600"), "T2 billed never fakes a 100% margin")
            expectEqual(
                r.warnings,
                [.hoursUntracked, .expensesUnlinked, .laborCostRateUnset, .legacyInvoiceDates],
                "T2 warnings exact and ordered"
            )
        }

        // MARK: - T3 — Voided payments excluded, overpayment explicit

        do {
            var job = try baseJob(status: "invoiced")
            job.timeSessions = closedSessions
            let inv = try invoice(amount: "500", payments: """
            [{"id":"p1","amount":200,"date":"2026-08-01","method":"cash"},\
            {"id":"p2","amount":200,"date":"2026-08-02","method":"cash","voidedAt":"2026-08-03"},\
            {"id":"p3","amount":350,"date":"2026-08-04","method":"check"}]
            """)
            let r = NativeJobProfitability.calculate(job: job, invoices: [inv], expenses: [], laborCostRate: nil)
            expectEqual(r.cashCollected, decimal("550"), "T3 voided payment excluded")
            expectEqual(r.outstandingReceivable, decimal("0"), "T3 outstanding clamped")
            expectEqual(r.overpaidAmount, decimal("50"), "T3 overpayment explicit")
        }

        // MARK: - T4 — Change-order status gating

        do {
            var job = try baseJob()
            job.changeOrders = [
                Canonical.ChangeOrder(
                    id: "co2", title: "Declined extra", amount: decimal("500"),
                    createdAt: "2026-08-02",
                    manualDecision: Canonical.ChangeOrderDecision(decision: "declined", decidedAt: "2026-08-02")
                ),
                Canonical.ChangeOrder(
                    id: "co3", title: "Cancelled extra", amount: decimal("999"),
                    createdAt: "2026-08-02", cancelledAt: "2026-08-03"
                ),
                approvedOrder(id: "co4", amount: "-150", title: "Descope credit"),
            ]
            let r = NativeJobProfitability.calculate(job: job, invoices: [], expenses: [], laborCostRate: nil)
            expectEqual(r.changeOrderRevenue, decimal("-150"), "T4 only approved COs count; negatives work")
            expectEqual(r.finalBillable, decimal("816"), "T4 finalBillable")
        }

        // MARK: - T5/T6 — Session basis

        do {
            var job = try baseJob()
            job.timeSessions = [
                Canonical.TimeSession(start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T10:00:00.000Z"),
                Canonical.TimeSession(start: "2026-08-07T08:00:00.000Z", end: nil),
            ]
            let r = NativeJobProfitability.calculate(job: job, invoices: [], expenses: [], laborCostRate: nil)
            expectEqual(r.actualLaborHours, decimal("2"), "T5 open session excluded")
            expect(!r.warnings.contains(.hoursUntracked), "T5 sessions present means no hours warning")

            var emptyJob = try baseJob()
            emptyJob.timeSessions = []
            let empty = NativeJobProfitability.calculate(job: emptyJob, invoices: [], expenses: [], laborCostRate: nil)
            let absentJob = try baseJob()
            let absent = NativeJobProfitability.calculate(job: absentJob, invoices: [], expenses: [], laborCostRate: nil)
            for (label, value) in [("empty", empty), ("absent", absent)] {
                expect(value.actualLaborHours == nil, "T6 \(label) sessions mean unknown hours")
                expect(value.laborHoursVariance == nil, "T6 \(label) sessions mean nil variance")
                expect(value.warnings.contains(.hoursUntracked), "T6 \(label) sessions warn")
            }
        }

        // MARK: - T7/T8 — Linked-expense data vs no data

        do {
            let job = try baseJob()
            let linked = [try expense(id: "e2", amount: "25", category: "fuel")]
            let r = NativeJobProfitability.calculate(job: job, invoices: [], expenses: linked, laborCostRate: nil)
            expectEqual(r.actualMaterialExpense, decimal("0"), "T7 linked data makes materials a real $0")
            expectEqual(r.otherDirectExpenses, decimal("25"), "T7 otherDirectExpenses")
            expectEqual(r.materialsVariance, decimal("-300"), "T7 materialsVariance")
            expect(!r.warnings.contains(.expensesUnlinked), "T7 linked data means no expenses warning")

            let overhead = [try expense(jobId: nil)]
            let u = NativeJobProfitability.calculate(job: job, invoices: [], expenses: overhead, laborCostRate: nil)
            expect(u.actualMaterialExpense == nil, "T8 unlinked expenses are invisible (materials)")
            expect(u.otherDirectExpenses == nil, "T8 unlinked expenses are invisible (other)")
            expectEqual(u.warnings.filter { $0 == .expensesUnlinked }.count, 1, "T8 exactly one expenses warning")
        }

        // MARK: - T9 — Double-counting guard

        do {
            let job = try baseJob()
            let r = NativeJobProfitability.calculate(
                job: job, invoices: [], expenses: [try expense()], laborCostRate: nil
            )
            expectEqual(r.actualGrossProfitBilled, decimal("626"), "T9 estimated materials never enter actuals")
        }

        // MARK: - T10 — Invoice linkage union + dedupe + unlinked warning

        do {
            var job = try baseJob(status: "invoiced")
            job.invoiceId = "invA"
            let invA = try invoice(id: "invA", amount: "400", jobId: nil)
            let invB = try invoice(id: "invB", amount: "300")
            let unrelated = try invoice(id: "invC", amount: "999", jobId: nil)
            let all = [invA, invB, unrelated, invA]
            let linked = NativeJobProfitability.linkedInvoices(job: job, invoices: all)
            expectEqual(linked.map(\.id), ["invA", "invB"], "T10 union + dedupe")
            let r = NativeJobProfitability.calculate(job: job, invoices: all, expenses: [], laborCostRate: nil)
            expectEqual(r.invoicedAmount, decimal("700"), "T10 each invoice counted once")
            expect(!r.warnings.contains(.invoiceUnlinked), "T10 linked job does not warn")

            var unlinkedJob = try baseJob(status: "invoiced")
            unlinkedJob.invoiceId = nil
            let manual = try invoice(id: "manual1", jobId: nil)
            let u = NativeJobProfitability.calculate(job: unlinkedJob, invoices: [manual], expenses: [], laborCostRate: nil)
            expectEqual(u.invoicedAmount, decimal("0"), "T10 unlinked invoiced amount zero")
            expect(u.warnings.contains(.invoiceUnlinked), "T10 invoiced job with no linkage warns")

            let early = try baseJob(status: "in_progress")
            let e = NativeJobProfitability.calculate(job: early, invoices: [], expenses: [], laborCostRate: nil)
            expect(!e.warnings.contains(.invoiceUnlinked), "T10 pre-invoice statuses do not warn")
        }

        // MARK: - T11 — Owner labor-cost rate

        do {
            let (job, invoices, expenses) = try exampleA()
            let r = NativeJobProfitability.calculate(
                job: job, invoices: invoices, expenses: expenses, laborCostRate: decimal("40")
            )
            expectEqual(r.estimatedOwnerLaborCost, decimal("160"), "T11 estimated owner cost")
            expectEqual(r.actualOwnerLaborCost, decimal("220"), "T11 actual owner cost")
            expectEqual(r.estimatedGrossProfit, decimal("506"), "T11 estimated profit nets owner pay")
            expectEqual(r.actualGrossProfitBilled, decimal("581"), "T11 billed profit nets owner pay")
            expectEqual(r.actualGrossProfitCash, decimal("581"), "T11 cash profit nets owner pay")
            expectEqual(r.effectiveHourlyActual, decimal("145.64"), "T11 hourly is rate-independent")
            expectEqual(r.warnings, [.feesUnknown], "T11 set rate clears the unset warning")

            let zero = NativeJobProfitability.calculate(
                job: job, invoices: invoices, expenses: expenses, laborCostRate: decimal("0")
            )
            expectEqual(zero.estimatedOwnerLaborCost, decimal("0"), "T11 explicit 0 is set, not unset")
            expectEqual(zero.actualOwnerLaborCost, decimal("0"), "T11 explicit 0 actual")
            expect(!zero.warnings.contains(.laborCostRateUnset), "T11 explicit 0 clears the unset warning")
        }

        // MARK: - T12 (adapted) — Zero amounts never poison figures

        do {
            var job = try baseJob()
            job.timeSessions = closedSessions
            let inv = try invoice(payments: """
            [{"id":"p1","amount":0,"date":"2026-08-01","method":"cash"},\
            {"id":"p2","amount":100,"date":"2026-08-02","method":"cash"}]
            """)
            let expenses = [
                try expense(amount: "0"),
                try expense(id: "e2", amount: "25", category: "fuel"),
            ]
            let r = NativeJobProfitability.calculate(job: job, invoices: [inv], expenses: expenses, laborCostRate: nil)
            expectEqual(r.cashCollected, decimal("100"), "T12 zero payment contributes nothing")
            expectEqual(r.actualMaterialExpense, decimal("0"), "T12 zero material expense is a real $0")
            expectEqual(r.otherDirectExpenses, decimal("25"), "T12 other expenses intact")
            let mirrors: [Decimal?] = [
                r.estimatedRevenue, r.changeOrderRevenue, r.finalBillable, r.invoicedAmount,
                r.cashCollected, r.outstandingReceivable, r.overpaidAmount, r.estimatedLaborHours,
                r.billableLaborRate, r.actualLaborHours, r.laborHoursVariance, r.estimatedOwnerLaborCost,
                r.actualOwnerLaborCost, r.estimatedMaterialCost, r.actualMaterialExpense,
                r.otherDirectExpenses, r.materialsVariance, r.estimatedDirectCost, r.directCostVariance,
                r.estimatedGrossProfit, r.actualGrossProfitBilled, r.actualGrossProfitCash,
                r.effectiveHourlyActual,
            ]
            expect(mirrors.allSatisfy { $0 == nil || ($0! as NSDecimalNumber).doubleValue.isFinite },
                   "T12 every figure finite or nil")
        }

        // MARK: - T13 — No estimate to compare against

        do {
            var job = try baseJob(laborHours: "0")
            job.timeSessions = [
                Canonical.TimeSession(start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T11:00:00.000Z"),
            ]
            let r = NativeJobProfitability.calculate(job: job, invoices: [], expenses: [], laborCostRate: nil)
            expectEqual(r.actualLaborHours, decimal("3"), "T13 actual known without an estimate")
            expect(r.laborHoursVariance == nil, "T13 variance nil without an estimate")
        }

        // MARK: - T14 — Cent-rounding epsilon

        do {
            let job = try baseJob()
            let inv = try invoice(amount: "100", payments: """
            [{"id":"p1","amount":99.999,"date":"2026-08-01","method":"cash"}]
            """)
            let r = NativeJobProfitability.calculate(job: job, invoices: [inv], expenses: [], laborCostRate: nil)
            expectEqual(r.outstandingReceivable, decimal("0"), "T14 epsilon rounds to zero outstanding")
            expectEqual(r.cashCollected, decimal("100"), "T14 epsilon rounds collected up")
        }

        // MARK: - T15 — Determinism

        do {
            let (job, invoices, expenses) = try exampleA()
            let a = NativeJobProfitability.calculate(job: job, invoices: invoices, expenses: expenses, laborCostRate: nil)
            let b = NativeJobProfitability.calculate(job: job, invoices: invoices, expenses: expenses, laborCostRate: nil)
            expectEqual(a, b, "T15 same inputs give identical results")
            expectEqual(a.warnings, b.warnings, "T15 stable warning order")
        }

        // MARK: - Direct costs (Phase 2 basis in the profitability layer)

        do {
            var job = try baseJob(status: "complete", estimateTotal: "700", laborHours: "0", materials: "[]")
            job.jobCosts = [
                try decodeJobCost("""
                {"id":"jc1","label":"Permit","category":"permit","quantity":1,"unitCost":150,\
                "markupPercent":0,"markupPolicy":"passthrough","taxable":false,"customerVisible":true}
                """),
                try decodeJobCost("""
                {"id":"jc2","label":"Sub","category":"subcontractor","quantity":1,"unitCost":500,\
                "markupPercent":10,"markupPolicy":"in_margin_base","taxable":false,"customerVisible":true}
                """),
            ]
            let p = NativeJobProfitability.calculate(job: job, invoices: [], expenses: [], laborCostRate: nil)
            expectEqual(p.estimatedDirectCost, decimal("650"), "direct basis excludes markup")
            expectEqual(p.estimatedGrossProfit, decimal("50"), "direct costs leave no fabricated profit")

            let withActual = NativeJobProfitability.calculate(
                job: job, invoices: [],
                expenses: [try expense(id: "e1", amount: "520", category: "labor", description: "Sub invoice")],
                laborCostRate: nil
            )
            expectEqual(withActual.otherDirectExpenses, decimal("520"), "direct actual from non-materials expenses")
            expectEqual(withActual.directCostVariance, decimal("-130"), "direct variance vs the planned basis")
            expect(p.directCostVariance == nil, "direct variance nil when nothing is linked")

            var plain = try baseJob(status: "complete", estimateTotal: "300", laborHours: "0", materials: "[]")
            plain.jobCosts = nil
            let q = NativeJobProfitability.calculate(job: plain, invoices: [], expenses: [], laborCostRate: nil)
            expectEqual(q.estimatedDirectCost, decimal("0"), "no jobCosts means zero planned direct cost")
            expectEqual(q.estimatedGrossProfit, decimal("300"), "profit unchanged without direct costs")
            expect(q.directCostVariance == nil, "variance nil without direct costs")
        }

        // MARK: - Adapter display model (profitabilityDisplay parity)

        do {
            let paidJob = try baseJob()
            expect(NativeJobProfitability.shouldShow(job: paidJob), "display card visible for a paid job with an estimate")
            var lead = try baseJob(status: "lead")
            lead.invoiceId = nil
            expect(!NativeJobProfitability.shouldShow(job: lead), "display card hidden before in_progress")
            expect(!NativeJobProfitability.shouldShow(status: "paid", estimateTotal: decimal("0")),
                   "display card hidden without an estimate")

            let copies = ProfitabilityWarning.allCases.map(NativeJobProfitability.warningCopy)
            expect(copies.allSatisfy { $0.count > 10 }, "display every warning has user copy")
            expectEqual(Set(copies).count, copies.count, "display warning copy is distinct per warning")

            let (job, invoices, expenses) = try exampleA()
            let p = NativeJobProfitability.calculate(job: job, invoices: invoices, expenses: expenses, laborCostRate: nil)
            let rows = NativeJobProfitability.sectionRows(job: job, profitability: p)
            expectEqual(rows.map(\.key), ["revenue", "hours", "materials", "otherExpenses", "profit", "hourly"],
                        "display row order")
            let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
            expectEqual(byKey["revenue"]?.estimate, "$966", "display revenue estimate is a quote")
            expectEqual(byKey["revenue"]?.actual, "$1,166.00", "display revenue actual is real money")
            expectEqual(byKey["revenue"]?.variance, "+$200.00", "display revenue variance signed")
            expectEqual(byKey["revenue"]?.tone, .good, "display revenue tone")
            expectEqual(byKey["hours"]?.estimate, "4h", "display hours estimate")
            expectEqual(byKey["hours"]?.actual, "5h 30m", "display hours actual")
            expectEqual(byKey["hours"]?.variance, "+1h 30m", "display hours variance signed")
            expectEqual(byKey["hours"]?.tone, .bad, "display hours tone")
            expectEqual(byKey["materials"]?.estimate, "$300", "display materials estimate")
            expectEqual(byKey["materials"]?.actual, "$340.00", "display materials actual")
            expectEqual(byKey["profit"]?.estimate, "$666", "display profit estimate")
            expectEqual(byKey["profit"]?.actual, "$801.00", "display profit actual")
            expectEqual(byKey["hourly"]?.estimate, "$151.50/hr", "display estimate-side hourly")
            expectEqual(byKey["hourly"]?.actual, "$145.64/hr", "display actual hourly")

            expectEqual(
                NativeJobProfitability.collectionSummary(p),
                "Collected $1,166.00 of $1,166.00 invoiced",
                "display fully-collected summary"
            )
            let freshJob = try baseJob(status: "in_progress")
            let untouched = NativeJobProfitability.calculate(
                job: freshJob, invoices: [], expenses: [], laborCostRate: nil
            )
            expect(NativeJobProfitability.collectionSummary(untouched) == nil,
                   "display no summary when nothing invoiced or collected")

            let items = NativeJobProfitability.whatChangedItems(
                job: job, profitability: p,
                linkedExpenses: NativeJobProfitability.linkedExpenses(job: job, expenses: expenses)
            )
            expectEqual(items.map(\.key), ["co:co1", "hours", "exp:e1", "exp:e2"], "display what-changed order")
            expectEqual(items[0].label, "Change order — Extra shutoff valve", "display CO label")
            expectEqual(items[0].amount, "+$200.00", "display CO amount signed")
            expectEqual(items[1].label, "Labor over estimate", "display labor label")
            expectEqual(items[2].label, "Supply-house run (Materials)", "display expense label with category")
            expectEqual(items[3].label, "Gas (Fuel & Transport)", "display fuel category label")

            var legacyJob = try baseJob(estimateTotal: "600", laborHours: "3", materials: "[]")
            legacyJob.invoiceId = "leg"
            let legacyInvoice = try invoice(id: "leg", amount: "600", jobId: nil, paid: true)
            let legacy = NativeJobProfitability.calculate(
                job: legacyJob, invoices: [legacyInvoice], expenses: [], laborCostRate: nil
            )
            let legacyRows = Dictionary(uniqueKeysWithValues: NativeJobProfitability.sectionRows(
                job: legacyJob, profitability: legacy
            ).map { ($0.key, $0) })
            expectEqual(legacyRows["hours"]?.actual, "—", "display unknown hours render as em-dash")
            expect(legacyRows["hours"]?.variance == nil, "display unknown hours carry no variance")
            expectEqual(legacyRows["materials"]?.actual, "—", "display unknown materials render as em-dash")
            expect(legacyRows["otherExpenses"] == nil, "display unknown costs omit the row")
            expect(legacyRows["profit"]?.variance == nil, "display no fake profit delta on legacy work")
            expectEqual(legacyRows["hourly"]?.actual, "—", "display unknown hourly renders as em-dash")

            let state = NativeJobProfitability.sectionState(
                job: job, invoices: invoices, expenses: expenses, laborCostRate: nil
            )
            expectEqual(state?.jobID, "j1", "display section state carries the job")
            expectEqual(
                state?.warnings,
                ["Card-processing fees aren't recorded — collected amounts are gross.",
                 "Profit is before paying yourself — add an owner labor cost rate to include it."],
                "display section warnings use the oracle copy in order"
            )
            expect(NativeJobProfitability.sectionState(
                job: lead, invoices: [], expenses: [], laborCostRate: nil
            ) == nil, "display section state nil when the card stays hidden")
        }

        if failures == 0 {
            print("JobProfitabilityTests: PASS")
        } else {
            print("JobProfitabilityTests: FAIL (\(failures))")
            exit(1)
        }
    }
}
