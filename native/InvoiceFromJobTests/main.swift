import Foundation

private var failures = 0

private func expect<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    let value = actual()
    guard value == expected else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
        return
    }
}

private func d(_ s: String) -> Decimal { Decimal(string: s)! }

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// hours → a closed session of exactly that length, mirroring
/// `__tests__/autoInvoice.test.ts`'s `closedSession` helper.
private func closedSession(_ hours: Double, start startIso: String = "2026-08-01T08:00:00.000Z") -> JobInvoiceTimeSession {
    let start = isoFormatter.date(from: startIso)!
    let end = start.addingTimeInterval(hours * 3600)
    return JobInvoiceTimeSession(start: startIso, end: isoFormatter.string(from: end))
}

private func approvedCO(_ id: String, _ amount: Decimal) -> NativeJobListChangeOrder {
    NativeJobListChangeOrder(amount: amount, approvalDecision: nil, manualDecision: "approved", isCancelled: false)
}

// The worked example from __tests__/autoInvoice.test.ts's makeJob(): 4h @ $85
// labor ($340), two materials totalling $300 base +20% markup ($360),
// estimateTotal $966 → residual overhead $266.
private let defaultMaterials: [(quantity: Decimal, unitCost: Decimal)] = [(1, 200), (2, 50)]

private func breakdown(
    estimateTotal: Decimal = 966,
    laborHours: Decimal = 4,
    laborRate: Decimal = 85,
    materials: [(quantity: Decimal, unitCost: Decimal)] = defaultMaterials,
    materialMarkup: Decimal = 20,
    directCosts: [JobInvoiceDirectCost] = [],
    status: String = "complete",
    timeSessions: [JobInvoiceTimeSession] = [],
    changeOrders: [NativeJobListChangeOrder] = []
) -> JobInvoiceBillableBreakdown {
    JobInvoiceDomain.computeBillableBreakdown(
        estimateTotal: estimateTotal, laborHours: laborHours, laborRate: laborRate,
        materials: materials, materialMarkup: materialMarkup, directCosts: directCosts,
        status: status, timeSessions: timeSessions, changeOrders: changeOrders
    )
}

// MARK: - billableLaborHours (utils/autoInvoice.ts parity)

do {
    expect(JobInvoiceDomain.shouldAutoInvoice(
        enabled: true, hasInvoice: false, estimateTotal: 966, customerName: "Jane Smith"
    ), true, "auto-invoice gates all met")
    expect(JobInvoiceDomain.shouldAutoInvoice(
        enabled: false, hasInvoice: false, estimateTotal: 966, customerName: "Jane Smith"
    ), false, "auto-invoice toggle off")
    expect(JobInvoiceDomain.shouldAutoInvoice(
        enabled: true, hasInvoice: true, estimateTotal: 966, customerName: "Jane Smith"
    ), false, "deposit invoice stays manual")
    expect(JobInvoiceDomain.shouldAutoInvoice(
        enabled: true, hasInvoice: false, estimateTotal: 0, customerName: "Jane Smith"
    ), false, "zero estimate stays manual")
    expect(JobInvoiceDomain.shouldAutoInvoice(
        enabled: true, hasInvoice: false, estimateTotal: 966, customerName: "  "
    ), false, "blank customer stays manual")

    let sessions = [
        JobInvoiceTimeSession(start: "2026-08-01T08:00:00.000Z", end: "2026-08-01T09:00:00.000Z"),
        JobInvoiceTimeSession(start: "2026-08-01T10:00:00.000Z", end: nil)
    ]
    let clocked = JobInvoiceDomain.clockOutLastOpenSession(sessions, at: "2026-08-01T12:00:00.000Z")
    expect(clocked[0].end, sessions[0].end, "clock-out preserves completed sessions")
    expect(clocked[1].end, "2026-08-01T12:00:00.000Z", "clock-out closes only the last open session")
    let clamped = JobInvoiceDomain.clockOutLastOpenSession(
        [JobInvoiceTimeSession(start: "2026-08-01T10:00:00.000Z", end: nil)],
        at: "2026-08-01T09:00:00.000Z"
    )
    expect(clamped[0].end, "2026-08-01T10:00:00.000Z", "clock-out clamps a backwards device clock")
}

do {
    let noSessions = JobInvoiceDomain.billableLaborHours(estimatedHours: 4, laborRate: 85, status: "complete", timeSessions: [])
    expect(noSessions.hours, 4, "no sessions bills estimate")
    expect(noSessions.usedTrackedTime, false, "no sessions not tracked")

    let tracked = JobInvoiceDomain.billableLaborHours(estimatedHours: 4, laborRate: 85, status: "complete", timeSessions: [closedSession(5.5)])
    expect(tracked.hours, d("5.5"), "tracked hours")
    expect(tracked.usedTrackedTime, true, "tracked flag set")

    let multi = JobInvoiceDomain.billableLaborHours(
        estimatedHours: 4, laborRate: 85, status: "complete",
        timeSessions: [
            closedSession(2),
            closedSession(1.5, start: "2026-08-01T13:00:00.000Z"),
            JobInvoiceTimeSession(start: "2026-08-01T16:00:00.000Z", end: nil)
        ]
    )
    expect(multi.hours, d("3.5"), "multiple sessions accumulate, open session excluded")
    expect(multi.usedTrackedTime, true, "multi-session tracked flag")

    let flatPriced = JobInvoiceDomain.billableLaborHours(estimatedHours: 0, laborRate: 85, status: "complete", timeSessions: [closedSession(3)])
    expect(flatPriced.hours, 0, "flat-priced job never bills tracked time")
    expect(flatPriced.usedTrackedTime, false, "flat-priced not tracked")

    let noRate = JobInvoiceDomain.billableLaborHours(estimatedHours: 4, laborRate: 0, status: "complete", timeSessions: [closedSession(3)])
    expect(noRate.hours, 4, "zero labor rate never bills tracked time")
    expect(noRate.usedTrackedTime, false, "zero rate not tracked")

    let preComplete = JobInvoiceDomain.billableLaborHours(estimatedHours: 4, laborRate: 85, status: "in_progress", timeSessions: [closedSession(3)])
    expect(preComplete.hours, 4, "pre-complete status bills the estimate")
    expect(preComplete.usedTrackedTime, false, "pre-complete not tracked")

    let rounded = JobInvoiceDomain.billableLaborHours(estimatedHours: 4, laborRate: 85, status: "complete", timeSessions: [closedSession(1.175)])
    expect(rounded.hours, d("1.18"), "tracked hours round to 2 decimals")
    expect(rounded.usedTrackedTime, true, "rounded tracked flag")

    let zeroRounded = JobInvoiceDomain.billableLaborHours(estimatedHours: 4, laborRate: 85, status: "complete", timeSessions: [closedSession(10.0 / 3600.0)])
    expect(zeroRounded.hours, 4, "tracked time rounding to 0.00 falls back to the estimate")
    expect(zeroRounded.usedTrackedTime, false, "zero-rounded not tracked")
}

// MARK: - computeBillableBreakdown

do {
    let b = breakdown()
    expect(b.laborHours, 4, "quoted breakdown labor hours")
    expect(b.laborCost, 340, "quoted breakdown labor cost")
    expect(b.materialCost, 360, "quoted breakdown material cost")
    expect(b.overheadLine, 266, "quoted breakdown overhead line")
    expect(b.usedTrackedTime, false, "quoted breakdown not tracked")
    expect(b.total, 966, "quoted breakdown total")

    let over = breakdown(timeSessions: [closedSession(5.5)])
    expect(over.laborHours, d("5.5"), "tracked-over labor hours")
    expect(over.laborCost, d("467.5"), "tracked-over labor cost")
    expect(over.total, d("1093.5"), "tracked-over total: 966 + 1.5h x $85")
    expect(over.laborCost + over.materialCost + over.overheadLine, over.total, "tracked-over residual invariant")

    let under = breakdown(timeSessions: [closedSession(2)])
    expect(under.laborCost, 170, "tracked-under labor cost")
    expect(under.total, 796, "tracked-under total: 966 - 2h x $85")
    expect(under.laborCost + under.materialCost + under.overheadLine, under.total, "tracked-under residual invariant")
}

// MARK: - buildInvoiceLineItems

do {
    let trackedBreakdown = breakdown(timeSessions: [closedSession(5.5)])
    let items = JobInvoiceDomain.buildInvoiceLineItems(
        breakdown: trackedBreakdown, laborRate: 85, materialCount: 2, singleMaterialName: nil, approvedChangeOrders: []
    )
    expect(items.count, 3, "tracked line item count")
    expect(items[0].description, "Labor — 5.5 hrs @ $85/hr", "tracked labor line description")
    expect(items[0].amount, d("467.5"), "tracked labor line amount")
    expect(items[0].category, "labor", "tracked labor line category")
    expect(items[1].amount, 360, "materials line amount")
    expect(items[1].category, "materials", "materials line category")
    expect(items[2].amount, 266, "overhead line amount")
    expect(items[2].category, "overhead", "overhead line category")
    let sum = items.reduce(Decimal.zero) { $0 + $1.amount }
    expect(sum, trackedBreakdown.total, "tracked line items sum to the billable total")

    let untracked = JobInvoiceDomain.buildInvoiceLineItems(
        breakdown: breakdown(), laborRate: 85, materialCount: 2, singleMaterialName: nil, approvedChangeOrders: []
    )
    expect(untracked[0].description, "Labor — 4 hrs @ $85/hr", "untracked labor line description")
    expect(untracked[0].amount, 340, "untracked labor line amount")
}

do {
    // web/src/lib/createInvoiceFromJob.test.ts's fixture — a single named
    // material bills under its own name instead of a generic "Materials" tag.
    let single = breakdown(estimateTotal: 966, laborHours: 4, laborRate: 85, materials: [(1, 300)], materialMarkup: 20)
    expect(single.laborCost, 340, "single-material labor cost")
    expect(single.materialCost, 360, "single-material material cost")
    expect(single.overheadLine, 266, "single-material overhead")
    expect(single.total, 966, "single-material total")

    let items = JobInvoiceDomain.buildInvoiceLineItems(
        breakdown: single, laborRate: 85, materialCount: 1, singleMaterialName: "Heater", approvedChangeOrders: []
    )
    expect(items.map(\.category), ["labor", "materials", "overhead"], "single-material line categories")
    expect(items[1].description, "Heater", "single named material uses its own name")
    expect(items[1].amount, 360, "single material amount")

    let blankName = JobInvoiceDomain.buildInvoiceLineItems(
        breakdown: single, laborRate: 85, materialCount: 1, singleMaterialName: "  ", approvedChangeOrders: []
    )
    expect(blankName[1].description, "Materials", "blank material name falls back to Materials")
}

do {
    // Customer-visible direct costs get their own line (with in_margin_base
    // markup applied); hidden ones fold into the overhead residual instead.
    let visible = JobInvoiceDirectCost(
        label: "Permit fee", category: "permit", quantity: 1, unitCost: 100,
        markupPercent: 10, markupPolicy: PricingMarkupPolicy.inMarginBase.rawValue, customerVisible: true
    )
    let hidden = JobInvoiceDirectCost(
        label: "Disposal", category: "disposal", quantity: 1, unitCost: 50,
        markupPercent: 0, markupPolicy: PricingMarkupPolicy.passthrough.rawValue, customerVisible: false
    )
    let b = breakdown(estimateTotal: 1276, directCosts: [visible, hidden])
    expect(b.directCostLines.count, 1, "only the customer-visible cost becomes its own line")
    expect(b.directCostLines[0].amount, d("110"), "in_margin_base direct cost includes its markup")
    expect(b.directCostLines[0].category, "permit", "direct cost line keeps its category")
    expect(b.overheadLine, 466, "hidden direct cost folds into the overhead residual")
}

// MARK: - Change orders in billing (utils/changeOrders.ts + autoInvoice.ts parity)

do {
    let cos = [approvedCO("coA", 850), NativeJobListChangeOrder(amount: 999, approvalDecision: nil, manualDecision: nil, isCancelled: false)]
    let b = breakdown(estimateTotal: 2400, changeOrders: cos)
    expect(b.changeOrderTotal, 850, "only approved change orders count")
    expect(b.total, 3250, "change order total adds to the breakdown total")
}

do {
    let cos = [approvedCO("coA", 850), approvedCO("coB", -100)]
    let b = breakdown(estimateTotal: 2400, changeOrders: cos)
    let titled = [(title: "CO coA", order: cos[0]), (title: "CO coB", order: cos[1])]
    let items = JobInvoiceDomain.buildInvoiceLineItems(
        breakdown: b, laborRate: 85, materialCount: 2, singleMaterialName: nil,
        approvedChangeOrders: JobInvoiceDomain.approvedChangeOrders(titled)
    )
    let coLines = items.filter { $0.category == "other" }
    expect(coLines.count, 2, "one line per approved change order")
    expect(coLines[0].description, "Change order — CO coA", "change order line description A")
    expect(coLines[0].amount, 850, "change order line amount A")
    expect(coLines[1].description, "Change order — CO coB", "change order line description B")
    expect(coLines[1].amount, -100, "change order line amount B (credit)")
    let sum = items.reduce(Decimal.zero) { $0 + $1.amount }
    expect(sum, b.total, "line items sum to total with change orders")
}

do {
    let b = breakdown(estimateTotal: 2400, changeOrders: [])
    expect(b.changeOrderTotal, 0, "no change orders means zero total")
    expect(b.total, 2400, "no change orders leaves total unchanged")
    let items = JobInvoiceDomain.buildInvoiceLineItems(breakdown: b, laborRate: 85, materialCount: 2, singleMaterialName: nil, approvedChangeOrders: [])
    expect(items.contains { $0.category == "other" }, false, "no other-category line without change orders")
}

do {
    // Quoted: 4h @ $85 ($340) baked into estimateTotal 966. Tracked time
    // replaces those 4h with 5.5h ($467.50), and an approved $500 CO adds on
    // top — both deltas must land in the same total.
    let b = breakdown(estimateTotal: 966, timeSessions: [closedSession(5.5)], changeOrders: [approvedCO("coA", 500)])
    expect(b.usedTrackedTime, true, "tracked+CO usedTrackedTime")
    expect(b.laborHours, d("5.5"), "tracked+CO labor hours")
    expect(b.laborCost, d("467.5"), "tracked+CO labor cost")
    expect(b.changeOrderTotal, 500, "tracked+CO change order total")
    expect(b.total, d("1593.5"), "tracked+CO composed total")
}

do {
    let linkWins = NativeJobListChangeOrder(amount: 100, approvalDecision: "approved", manualDecision: "declined", isCancelled: false)
    expect(JobInvoiceDomain.approvedChangeOrderTotal([linkWins]), 100, "link decision outranks manual decision")

    let manualOnly = NativeJobListChangeOrder(amount: 100, approvalDecision: nil, manualDecision: "approved", isCancelled: false)
    expect(JobInvoiceDomain.approvedChangeOrderTotal([manualOnly]), 100, "manual decision counts when no link decision exists")

    let cancelledWins = NativeJobListChangeOrder(amount: 100, approvalDecision: "approved", manualDecision: "approved", isCancelled: true)
    expect(JobInvoiceDomain.approvedChangeOrderTotal([cancelledWins]), 0, "cancellation outranks both decisions")

    let pending = NativeJobListChangeOrder(amount: 100, approvalDecision: nil, manualDecision: nil, isCancelled: false)
    expect(JobInvoiceDomain.approvedChangeOrderTotal([pending]), 0, "pending change order excluded")

    let halfCent = NativeJobListChangeOrder(
        amount: d("199.995"), approvalDecision: nil, manualDecision: "approved", isCancelled: false
    )
    expect(JobInvoiceDomain.approvedChangeOrderTotal([halfCent]), d("200"),
           "approved subtotal rounds before invoice total reconciliation")
    let negativeHalfCent = NativeJobListChangeOrder(
        amount: d("-1.005"), approvalDecision: nil, manualDecision: "approved", isCancelled: false
    )
    expect(JobInvoiceDomain.approvedChangeOrderTotal([negativeHalfCent]), d("-1"),
           "invoice subtotal follows JavaScript negative half-cent rounding")
}

// MARK: - defaultDueDate

do {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = isoFormatter.date(from: "2026-08-03T12:00:00.000Z")!
    let due = JobInvoiceDomain.defaultDueDate(from: now, calendar: utc)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    expect(formatter.string(from: due), "2026-09-02", "default due date is 30 days out")
}

if failures == 0 {
    print("PASS: native create-invoice-from-job golden tests")
} else {
    print("FAILED: \(failures) native create-invoice-from-job golden test(s)")
    exit(1)
}
