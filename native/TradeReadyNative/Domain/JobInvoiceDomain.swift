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

/// Phase 25 review fix (spec 2026-10-02 §12 "Review fixes (2026-10-03)"):
/// the quoted lines exactly as the customer approved them through the link
/// (the frozen approval snapshot, or the tier lines plus add-ons of their
/// option selection), billed in place of lines re-derived from the job's
/// current pricing when those no longer reproduce what was approved — so
/// the lines always add up to the amount the customer agreed to. Built by
/// `NativeQuoteOptions.approvedInvoiceQuote(job:)`.
struct JobInvoiceApprovedQuote: Equatable {
    /// The approved lines in approved order, already categorized. At most
    /// one `labor` line: the quoted labor that tracked time replaces.
    var lines: [JobInvoiceLineDraft]
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
    /// labor, materials, visible direct costs and accepted add-ons — never
    /// re-derived from overhead/margin percent, so a hand-adjusted quoted
    /// total is trusted.
    var overheadLine: Decimal
    /// Phase 25: one line per accepted good/better/best add-on (flat price,
    /// already inside the quoted total). Empty for a single-total estimate.
    var addOnLines: [JobInvoiceLineDraft] = []
    /// Phase 25 review fix: the customer-approved lines when they stand in
    /// for the derived ones (`JobInvoiceApprovedQuote`); `nil` otherwise.
    /// When set, the derived line fields above only summarize them.
    var approvedLines: [JobInvoiceLineDraft]? = nil
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
    ///
    /// Phase 25: `addOnLines` are the accepted add-ons (see
    /// `NativeQuoteOptions.invoiceAddOnLines`). Their prices are already in
    /// `estimateTotal` (invariant M2), so they come out of the residual
    /// overhead line and the total is unchanged.
    static func computeBillableBreakdown(
        estimateTotal: Decimal,
        laborHours: Decimal,
        laborRate: Decimal,
        materials: [(quantity: Decimal, unitCost: Decimal)],
        materialMarkup: Decimal,
        directCosts: [JobInvoiceDirectCost],
        status: String,
        timeSessions: [JobInvoiceTimeSession],
        changeOrders: [NativeJobListChangeOrder],
        addOnLines: [JobInvoiceLineDraft] = [],
        approvedQuote: JobInvoiceApprovedQuote? = nil
    ) -> JobInvoiceBillableBreakdown {
        if let approvedQuote {
            return approvedBreakdown(
                approvedQuote, estimateTotal: estimateTotal, laborHours: laborHours, laborRate: laborRate,
                status: status, timeSessions: timeSessions, changeOrders: changeOrders
            )
        }
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
        let addOnTotal = addOnLines.reduce(Decimal.zero) { $0 + $1.amount }
        let overheadLine = estimateTotal - quotedLaborCost - materialCost - visibleDirectTotal - addOnTotal
        let changeOrderTotal = approvedChangeOrderTotal(changeOrders)

        let (billedHours, usedTrackedTime) = billableLaborHours(
            estimatedHours: laborHours, laborRate: laborRate, status: status, timeSessions: timeSessions
        )

        guard usedTrackedTime else {
            return JobInvoiceBillableBreakdown(
                laborHours: laborHours, laborCost: quotedLaborCost, materialCost: materialCost,
                hasMaterials: !materials.isEmpty, directCostLines: directCostLines, overheadLine: overheadLine,
                addOnLines: addOnLines, usedTrackedTime: false, changeOrderTotal: changeOrderTotal,
                total: FinancialDecimal.javascriptCents(estimateTotal + changeOrderTotal)
            )
        }
        let trackedLaborCost = FinancialDecimal.javascriptCents(billedHours * laborRate)
        return JobInvoiceBillableBreakdown(
            laborHours: billedHours, laborCost: trackedLaborCost, materialCost: materialCost,
            hasMaterials: !materials.isEmpty, directCostLines: directCostLines, overheadLine: overheadLine,
            addOnLines: addOnLines, usedTrackedTime: true, changeOrderTotal: changeOrderTotal,
            total: FinancialDecimal.javascriptCents(estimateTotal + trackedLaborCost - quotedLaborCost + changeOrderTotal)
        )
    }

    /// The breakdown over customer-approved lines: the quoted labor is the
    /// approved labor line, and tracked time (same rule as the derived path)
    /// replaces it at the job's rate, moving the total by the same delta.
    /// The other approved lines bill exactly as approved.
    private static func approvedBreakdown(
        _ quote: JobInvoiceApprovedQuote,
        estimateTotal: Decimal,
        laborHours: Decimal,
        laborRate: Decimal,
        status: String,
        timeSessions: [JobInvoiceTimeSession],
        changeOrders: [NativeJobListChangeOrder]
    ) -> JobInvoiceBillableBreakdown {
        func sum(_ category: String) -> Decimal {
            quote.lines.filter { $0.category == category }.reduce(Decimal.zero) { $0 + $1.amount }
        }
        let quotedLaborCost = sum("labor")
        let changeOrderTotal = approvedChangeOrderTotal(changeOrders)
        let (billedHours, usedTrackedTime) = billableLaborHours(
            estimatedHours: laborHours, laborRate: laborRate, status: status, timeSessions: timeSessions
        )
        let laborCost = usedTrackedTime ? FinancialDecimal.javascriptCents(billedHours * laborRate) : quotedLaborCost
        return JobInvoiceBillableBreakdown(
            laborHours: billedHours, laborCost: laborCost, materialCost: sum("materials"),
            hasMaterials: quote.lines.contains { $0.category == "materials" }, directCostLines: [],
            overheadLine: sum("overhead"), addOnLines: [], approvedLines: quote.lines,
            usedTrackedTime: usedTrackedTime, changeOrderTotal: changeOrderTotal,
            total: FinancialDecimal.javascriptCents(estimateTotal + laborCost - quotedLaborCost + changeOrderTotal)
        )
    }

    /// The invoice line items for a job — extracted from
    /// `CreateInvoiceFromJobScreen`'s save path, tracked-time-aware via
    /// `computeBillableBreakdown`. Customer-approved lines
    /// (`breakdown.approvedLines`) bill as approved, with tracked labor in
    /// place of the approved labor line.
    static func buildInvoiceLineItems(
        breakdown: JobInvoiceBillableBreakdown,
        laborRate: Decimal,
        materialCount: Int,
        singleMaterialName: String?,
        approvedChangeOrders: [JobInvoiceApprovedChangeOrder]
    ) -> [JobInvoiceLineDraft] {
        var items: [JobInvoiceLineDraft] = []
        if let approvedLines = breakdown.approvedLines {
            for line in approvedLines {
                guard line.category == "labor" else { items.append(line); continue }
                guard breakdown.laborCost > 0 else { continue }
                items.append(breakdown.usedTrackedTime
                    ? laborLine(hours: breakdown.laborHours, rate: laborRate, amount: breakdown.laborCost)
                    : line)
            }
            items.append(contentsOf: changeOrderLines(approvedChangeOrders))
            return items
        }
        if breakdown.laborCost > 0 {
            items.append(laborLine(hours: breakdown.laborHours, rate: laborRate, amount: breakdown.laborCost))
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
        // Phase 25: accepted add-ons follow the quoted lines, matching the
        // accepted estimate's line order (tier lines, then add-ons).
        items.append(contentsOf: breakdown.addOnLines)
        items.append(contentsOf: changeOrderLines(approvedChangeOrders))
        return items
    }

    private static func laborLine(hours: Decimal, rate: Decimal, amount: Decimal) -> JobInvoiceLineDraft {
        JobInvoiceLineDraft(
            description: "Labor — \(NSDecimalNumber(decimal: hours).stringValue) hrs @ \(currencyText(rate))/hr",
            amount: amount,
            category: "labor"
        )
    }

    private static func changeOrderLines(_ changeOrders: [JobInvoiceApprovedChangeOrder]) -> [JobInvoiceLineDraft] {
        changeOrders.map {
            JobInvoiceLineDraft(description: "Change order — \($0.title)", amount: $0.amount, category: "other")
        }
    }

    // MARK: Referral credit (Phase 34, spec 2026-10-03-referral-program-design.md §5.6)

    /// Must equal `NativeReferrals.creditLineCategory`/`creditLineDescription`
    /// (pinned by the referral suite); duplicated so this file keeps its
    /// standalone compile.
    static let referralCreditCategory = "referral_credit"
    static let referralCreditDescription = "Referral credit \u{2014} thank you!"

    /// The invoice-from-job lines with referral credits kept and added: the
    /// job's recomputed lines, then (finalize) every `referral_credit` line
    /// the existing invoice already carries, so a recompute never drops an
    /// applied credit, then one new `-credit` line when `credit > 0`.
    static func appendingReferralCredit(
        _ jobLines: [JobInvoiceLineDraft],
        existingInvoiceLines: [JobInvoiceLineDraft],
        credit: Decimal
    ) -> [JobInvoiceLineDraft] {
        var lines = jobLines.filter { $0.category != referralCreditCategory }
        lines.append(contentsOf: existingInvoiceLines.filter { $0.category == referralCreditCategory })
        if credit > 0 {
            lines.append(JobInvoiceLineDraft(
                description: referralCreditDescription,
                amount: -FinancialDecimal.javascriptCents(credit),
                category: referralCreditCategory
            ))
        }
        return lines
    }

    /// Σ of the (negative) `referral_credit` line amounts.
    static func referralCreditTotal(_ lines: [JobInvoiceLineDraft]) -> Decimal {
        lines.reduce(Decimal.zero) { $0 + ($1.category == referralCreditCategory ? $1.amount : 0) }
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
