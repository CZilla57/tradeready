import Foundation

/// One line on an invoice draft, before it becomes a `Canonical.InvoiceLineItem`.
struct JobInvoiceLineDraft: Equatable {
    var description: String
    var amount: Decimal
    var category: String
}

/// A customer-visible direct cost, pre-resolved to its final display label
/// (own label, or the category fallback `CanonicalUIAdapters.estimateDirectCostLabel`
/// already applies for the estimate snapshot — resolved by the caller so this
/// file stays decoupled from `Canonical.JobCost` and both surfaces show the
/// exact same wording for the same cost).
struct JobInvoiceDirectCost: Equatable {
    var label: String
    var category: String
    var quantity: Decimal
    var unitCost: Decimal
    var markupPercent: Decimal
    var markupPolicy: String
    var customerVisible: Bool
}

struct JobInvoiceTimeSession: Equatable {
    var start: String
    var end: String?
}

struct JobInvoiceApprovedChangeOrder: Equatable {
    var title: String
    var amount: Decimal
}

struct JobInvoiceBillableBreakdown: Equatable {
    /// Hours on the labor line — tracked when `usedTrackedTime`, else quoted.
    var laborHours: Decimal
    var laborCost: Decimal
    var materialCost: Decimal
    var hasMaterials: Bool
    /// Customer-visible direct-cost lines. Hidden costs are already folded
    /// into `overheadLine`.
    var directCostLines: [JobInvoiceLineDraft]
    /// The residual "overhead & operating costs" line: quoted total minus
    /// labor, materials, and visible direct costs — never re-derived from
    /// overhead/margin percent, so a hand-adjusted quoted total is trusted.
    var overheadLine: Decimal
    var usedTrackedTime: Bool
    /// Σ approved, non-cancelled change-order amounts (0 when none).
    var changeOrderTotal: Decimal
    /// The invoice amount: quoted total ± (tracked-hour delta × labor rate) + change orders.
    var total: Decimal
}

/// Pure "create invoice from job" math ported from `utils/autoInvoice.ts` and
/// `utils/changeOrders.ts`. Deliberately decoupled from `Canonical.Job` —
/// callers resolve canonical fields (including direct-cost labels, so the
/// invoice and the estimate snapshot never drift) into these plain mirror
/// types, matching `NativeJobList`'s existing decoupling. This keeps the math
/// unit-testable and cheap to compile standalone.
enum JobInvoiceDomain {
    /// Tracked time only replaces the estimate's hours once the job is done —
    /// a deposit requested mid-job still bills off the estimate.
    private static let billTrackedStatuses: Set<String> = ["complete", "invoiced", "paid"]

    /// Mirrors `shouldAutoInvoice` in `utils/autoInvoice.ts`. Automatic
    /// creation is deliberately limited to a clean final invoice: an existing
    /// deposit still needs the reviewed finalize screen, and incomplete quote
    /// identity/amount falls back to the manual completion flow.
    static func shouldAutoInvoice(
        enabled: Bool,
        hasInvoice: Bool,
        estimateTotal: Decimal,
        customerName: String
    ) -> Bool {
        enabled
            && !hasInvoice
            && estimateTotal > 0
            && !customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Closes only the last open session, matching `applyClockOut`. A device
    /// clock earlier than the session start clamps to the start so completing
    /// work can never create a negative duration.
    static func clockOutLastOpenSession(
        _ sessions: [JobInvoiceTimeSession],
        at end: String
    ) -> [JobInvoiceTimeSession] {
        guard let last = sessions.indices.last, sessions[last].end == nil else { return sessions }
        var result = sessions
        let clampedEnd: String
        if let startDate = isoDate(sessions[last].start),
           let endDate = isoDate(end),
           endDate < startDate {
            clampedEnd = sessions[last].start
        } else {
            clampedEnd = end
        }
        result[last].end = clampedEnd
        return result
    }

    /// Hours to bill for a job's labor line. Tracked timer time applies ONLY
    /// when the estimate actually priced labor hourly (`estimatedHours > 0 &&
    /// laborRate > 0` — a flat-priced job never gains a tracked-labor charge
    /// on top of its quoted total), the job is done, and at least one
    /// COMPLETED session logged time. Tracked hours round to 2 decimals.
    static func billableLaborHours(
        estimatedHours: Decimal,
        laborRate: Decimal,
        status: String,
        timeSessions: [JobInvoiceTimeSession]
    ) -> (hours: Decimal, usedTrackedTime: Bool) {
        guard estimatedHours > 0, laborRate > 0, billTrackedStatuses.contains(status) else {
            return (estimatedHours, false)
        }
        let completedMs = timeSessions.reduce(0.0) { sum, session in
            guard let end = session.end,
                  let startDate = isoDate(session.start),
                  let endDate = isoDate(end)
            else { return sum }
            return sum + endDate.timeIntervalSince(startDate) * 1000
        }
        guard completedMs > 0 else { return (estimatedHours, false) }
        let roundedHours = (completedMs / 3_600_000 * 100).rounded() / 100
        // Rounding can land back on 0 (e.g. 10 tracked seconds) — not a
        // billable replacement for the estimate. `Decimal(string:)` avoids
        // `Decimal(Double)`'s binary round-trip (1.18 → 1.1799999999999998…).
        guard roundedHours > 0, let tracked = Decimal(string: String(format: "%.2f", roundedHours)) else {
            return (estimatedHours, false)
        }
        return (tracked, true)
    }

    /// A link decision outranks an on-site decision, and cancellation
    /// outranks both — mirrors `NativeJobList.billableTotal`'s decision rule
    /// exactly (the single source both `approvedChangeOrderTotal` and
    /// `approvedChangeOrders` filter through, so the two never drift).
    private static func isApproved(_ order: NativeJobListChangeOrder) -> Bool {
        !order.isCancelled && (order.approvalDecision ?? order.manualDecision) == "approved"
    }

    /// Σ approved, non-cancelled change-order amounts.
    static func approvedChangeOrderTotal(_ changeOrders: [NativeJobListChangeOrder]) -> Decimal {
        FinancialDecimal.javascriptCents(changeOrders.reduce(Decimal.zero) { total, order in
            isApproved(order) ? total + order.amount : total
        })
    }

    /// The approved, non-cancelled change orders as invoice line items — one
    /// "Change order — <title>" line per entry, in job-record order.
    static func approvedChangeOrders(
        _ changeOrders: [(title: String, order: NativeJobListChangeOrder)]
    ) -> [JobInvoiceApprovedChangeOrder] {
        changeOrders.compactMap { entry in
            isApproved(entry.order) ? JobInvoiceApprovedChangeOrder(title: entry.title, amount: entry.order.amount) : nil
        }
    }

    /// The billable version of the estimate breakdown: identical to the
    /// quoted breakdown until tracked time applies, at which point only the
    /// labor line moves and the total shifts by the same delta — materials
    /// and the residual overhead line stay as quoted.
    static func computeBillableBreakdown(
        estimateTotal: Decimal,
        laborHours: Decimal,
        laborRate: Decimal,
        materials: [(quantity: Decimal, unitCost: Decimal)],
        materialMarkup: Decimal,
        directCosts: [JobInvoiceDirectCost],
        status: String,
        timeSessions: [JobInvoiceTimeSession],
        changeOrders: [NativeJobListChangeOrder]
    ) -> JobInvoiceBillableBreakdown {
        let quotedLaborCost = laborHours * laborRate
        let materialBase = materials.reduce(Decimal.zero) { $0 + $1.quantity * $1.unitCost }
        let materialCost = materialBase * (1 + materialMarkup / 100)
        let directCostLines = directCosts.compactMap { cost -> JobInvoiceLineDraft? in
            guard cost.customerVisible else { return nil }
            let base = cost.quantity * cost.unitCost
            let amount = cost.markupPolicy == PricingMarkupPolicy.inMarginBase.rawValue
                ? base * (1 + cost.markupPercent / 100)
                : base
            return JobInvoiceLineDraft(description: cost.label, amount: amount, category: cost.category)
        }
        let visibleDirectTotal = directCostLines.reduce(Decimal.zero) { $0 + $1.amount }
        let overheadLine = estimateTotal - quotedLaborCost - materialCost - visibleDirectTotal
        let changeOrderTotal = approvedChangeOrderTotal(changeOrders)

        let (billedHours, usedTrackedTime) = billableLaborHours(
            estimatedHours: laborHours, laborRate: laborRate, status: status, timeSessions: timeSessions
        )

        guard usedTrackedTime else {
            return JobInvoiceBillableBreakdown(
                laborHours: laborHours, laborCost: quotedLaborCost, materialCost: materialCost,
                hasMaterials: !materials.isEmpty, directCostLines: directCostLines, overheadLine: overheadLine,
                usedTrackedTime: false, changeOrderTotal: changeOrderTotal,
                total: FinancialDecimal.javascriptCents(estimateTotal + changeOrderTotal)
            )
        }
        let trackedLaborCost = FinancialDecimal.javascriptCents(billedHours * laborRate)
        return JobInvoiceBillableBreakdown(
            laborHours: billedHours, laborCost: trackedLaborCost, materialCost: materialCost,
            hasMaterials: !materials.isEmpty, directCostLines: directCostLines, overheadLine: overheadLine,
            usedTrackedTime: true, changeOrderTotal: changeOrderTotal,
            total: FinancialDecimal.javascriptCents(estimateTotal + trackedLaborCost - quotedLaborCost + changeOrderTotal)
        )
    }

    /// The invoice line items for a job — extracted from
    /// `CreateInvoiceFromJobScreen`'s save path, tracked-time-aware via
    /// `computeBillableBreakdown`.
    static func buildInvoiceLineItems(
        breakdown: JobInvoiceBillableBreakdown,
        laborRate: Decimal,
        materialCount: Int,
        singleMaterialName: String?,
        approvedChangeOrders: [JobInvoiceApprovedChangeOrder]
    ) -> [JobInvoiceLineDraft] {
        var items: [JobInvoiceLineDraft] = []
        if breakdown.laborCost > 0 {
            let hours = NSDecimalNumber(decimal: breakdown.laborHours).stringValue
            let rate = currencyText(laborRate)
            items.append(JobInvoiceLineDraft(
                description: "Labor — \(hours) hrs @ \(rate)/hr",
                amount: breakdown.laborCost,
                category: "labor"
            ))
        }
        if breakdown.hasMaterials {
            let label: String
            if materialCount == 1 {
                let name = singleMaterialName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                label = name.isEmpty ? "Materials" : name
            } else {
                label = "Materials (\(materialCount) items)"
            }
            items.append(JobInvoiceLineDraft(description: label, amount: breakdown.materialCost, category: "materials"))
        }
        items.append(contentsOf: breakdown.directCostLines)
        if breakdown.overheadLine > 1 {
            items.append(JobInvoiceLineDraft(
                description: "Overhead & operating costs", amount: breakdown.overheadLine, category: "overhead"
            ))
        }
        for changeOrder in approvedChangeOrders {
            items.append(JobInvoiceLineDraft(
                description: "Change order — \(changeOrder.title)", amount: changeOrder.amount, category: "other"
            ))
        }
        return items
    }

    /// Default payment terms: 30 days from today.
    static func defaultDueDate(from now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 30, to: now) ?? now
    }

    /// Deliberately not `Models.swift`'s `Double.currency` — that extension
    /// (and everything it would drag in transitively) would break this file's
    /// standalone `swiftc` compile (see the file-level doc comment above).
    private static func currencyText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue
            .formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    private static func isoDate(_ value: String) -> Date? {
        isoWithFractional.date(from: value) ?? iso.date(from: value)
    }
}
