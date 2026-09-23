import Foundation

// MARK: - Job profitability adapter

/// Canonical adapter from the persisted job record into the shared
/// `ProfitabilityInput` consumed by `JobProfitabilityEngine`
/// (`Domain/FinancialDomain.swift`).
///
/// Ported from `utils/jobProfitability.ts` (`linkedInvoicesForJob`,
/// `linkedExpensesForJob`, and the input half of `computeJobProfitability`).
/// The engine owns every figure; this file only resolves *which* canonical
/// data feeds it:
///
/// - Invoices: union of `invoice.jobId == job.id` and the invoice
///   `job.invoiceId` points at, deduped by id (manual invoices carry no
///   jobId and are only attributable through `job.invoiceId`).
/// - Expenses: strictly `expense.jobId == job.id`. Absent jobId is business
///   overhead and stays out of the per-job figures.
/// - Time: closed sessions only — the same deterministic basis billing uses.
///   A running session is a live-UI concern, not a profitability input.
/// - Change orders: approved, non-cancelled, via `NativeChangeOrders` (the
///   same status rule the change-order section and the invoice math use).
/// - Owner labor rate: `settings.laborCostRate` verbatim. `nil` stays `nil`
///   (unknown, never a fake $0); the engine adds the `labor_cost_rate_unset`
///   warning and computes profit before owner pay.
///
/// Unknown stays nil, not zero: no sessions at all (absent or empty) maps to
/// `actualLaborHours == nil`, and no linked expenses maps to
/// `linkedExpenses == nil`, so the engine emits the `hours_untracked` /
/// `expenses_unlinked` warnings exactly like the React Native oracle.
///
/// Display helpers (`shouldShow`, `warningCopy`, section rows, collection
/// summary, what-changed items) mirror `utils/profitabilityDisplay.ts`.
/// Presentation only — every figure comes from the engine.
enum NativeJobProfitability {
    /// Card visibility mirrors `shouldShowProfitability`: pipeline position
    /// plus a built estimate. A job with no estimate has nothing to compare
    /// against, so the card stays hidden.
    static let visibleStatuses: Set<String> = [
        "in_progress", "complete", "invoiced", "paid",
    ]

    static func shouldShow(status: String, estimateTotal: Decimal) -> Bool {
        visibleStatuses.contains(status) && estimateTotal > 0
    }

    static func shouldShow(job: Canonical.Job) -> Bool {
        shouldShow(status: job.status, estimateTotal: job.estimateTotal)
    }

    /// The invoices attributable to a job, in record order, deduped by id.
    static func linkedInvoices(
        job: Canonical.Job,
        invoices: [Canonical.Invoice]
    ) -> [Canonical.Invoice] {
        var seen = Set<String>()
        var linked: [Canonical.Invoice] = []
        for invoice in invoices {
            guard invoice.jobId == job.id || invoice.id == job.invoiceId else { continue }
            guard seen.insert(invoice.id).inserted else { continue }
            linked.append(invoice)
        }
        return linked
    }

    /// The expenses the owner explicitly linked to this job.
    static func linkedExpenses(
        job: Canonical.Job,
        expenses: [Canonical.Expense]
    ) -> [Canonical.Expense] {
        expenses.filter { $0.jobId == job.id }
    }

    /// Closed-session hours, 2-dp, JavaScript `Math.round` semantics for the
    /// non-negative durations this produces. `nil` when there are no sessions
    /// at all (absent or empty) — unknown, never zero. Sessions that exist
    /// but log no completed time (e.g. only a running session) map to zero,
    /// matching the oracle, which warns only when the session list is empty.
    static func actualLaborHours(sessions: [Canonical.TimeSession]?) -> Decimal? {
        guard let sessions, !sessions.isEmpty else { return nil }
        let completedMs = sessions.reduce(0.0) { total, session in
            guard let end = session.end,
                  let startDate = isoDate(session.start),
                  let endDate = isoDate(end)
            else { return total }
            return total + max(0, endDate.timeIntervalSince(startDate) * 1000)
        }
        let hours = completedMs / 3_600_000
        return Decimal(string: String(floor(hours * 100 + 0.5) / 100)) ?? 0
    }

    /// Maps one canonical invoice onto the payment-ledger mirror the engine
    /// reads. Unknown method strings fall back to `.other`; the ledger only
    /// special-cases `.stripe` (fees exist but are unknowable) and voided
    /// entries (contribute nothing), so the fallback is safe.
    static func ledgerInvoice(_ invoice: Canonical.Invoice) -> LedgerInvoice {
        LedgerInvoice(
            id: invoice.id,
            amount: invoice.amount,
            due: invoice.due,
            paid: invoice.paid,
            paidAt: invoice.paidAt,
            payments: invoice.payments?.map { payment in
                LedgerPayment(
                    id: payment.id,
                    amount: payment.amount,
                    date: payment.date,
                    method: LedgerPaymentMethod(rawValue: payment.method) ?? .other,
                    note: payment.note,
                    voidedAt: payment.voidedAt
                )
            },
            depositRequest: invoice.depositRequest.map { DepositRequest(amount: $0.amount) }
        )
    }

    /// Builds the engine input from a canonical job and its sibling records.
    /// `laborCostRate` is `settings.laborCostRate` verbatim — `nil` (unset)
    /// flows through as unknown; an explicit zero means labor costs nothing.
    static func input(
        job: Canonical.Job,
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        laborCostRate: Decimal?
    ) -> ProfitabilityInput {
        let linked = linkedInvoices(job: job, invoices: invoices)
        let linkedExp = linkedExpenses(job: job, expenses: expenses)
        let materialBase = job.materials.reduce(Decimal.zero) {
            $0 + $1.quantity * $1.unitCost
        }
        // Raw cost basis actually paid out (Σ qty × unitCost, markup
        // excluded — a marked-up line's markup is margin, not cost), mirroring
        // `computeDirectCosts(...).costBasis` in `utils/pricingEngine.ts`.
        let directBasis = (job.jobCosts ?? []).reduce(Decimal.zero) {
            $0 + $1.quantity * $1.unitCost
        }
        return ProfitabilityInput(
            estimatedRevenue: job.estimateTotal,
            approvedChangeOrderRevenue: NativeChangeOrders.approvedTotal(
                in: job.changeOrders ?? []
            ),
            estimatedLaborHours: job.laborHours,
            billableLaborRate: job.laborRate,
            actualLaborHours: actualLaborHours(sessions: job.timeSessions),
            ownerLaborCostRate: laborCostRate,
            estimatedMaterialCost: materialBase,
            estimatedDirectCost: directBasis,
            linkedExpenses: linkedExp.isEmpty ? nil : linkedExp.map {
                ProfitabilityExpense(amount: $0.amount, category: $0.category)
            },
            linkedInvoices: linked.map(ledgerInvoice),
            expectsInvoice: job.status == "invoiced" || job.status == "paid"
        )
    }

    /// Full pipeline: resolve the canonical records, then run the shared
    /// engine. All math lives in `JobProfitabilityEngine`.
    static func calculate(
        job: Canonical.Job,
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        laborCostRate: Decimal?
    ) -> JobProfitability {
        JobProfitabilityEngine.calculate(input(
            job: job,
            invoices: invoices,
            expenses: expenses,
            laborCostRate: laborCostRate
        ))
    }

    // MARK: - Warning copy

    /// User copy for each warning, verbatim from `warningCopy` in
    /// `utils/profitabilityDisplay.ts`. Honest about what is unknown and
    /// why — never spins missing data as zero. Emission order is the
    /// engine's `ProfitabilityWarning.allCases` order, which matches the
    /// oracle's pinned `WARNING_ORDER`.
    static func warningCopy(_ warning: ProfitabilityWarning) -> String {
        switch warning {
        case .hoursUntracked:
            "No hours tracked on this job — labor actuals are unknown."
        case .expensesUnlinked:
            "No expenses linked to this job — material and cost actuals are unknown."
        case .invoiceUnlinked:
            "No invoice is linked to this job yet."
        case .feesUnknown:
            "Card-processing fees aren't recorded — collected amounts are gross."
        case .laborCostRateUnset:
            "Profit is before paying yourself — add an owner labor cost rate to include it."
        case .legacyInvoiceDates:
            "Some payments predate itemised history, so their dates are approximate."
        }
    }

    // MARK: - Section read model

    /// Builds the job-detail section state, or `nil` when the card stays
    /// hidden (`shouldShow`). Pure presentation of already-computed figures.
    static func sectionState(
        job: Canonical.Job,
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        laborCostRate: Decimal?
    ) -> NativeJobProfitabilitySectionState? {
        guard shouldShow(job: job) else { return nil }
        let profitability = calculate(
            job: job,
            invoices: invoices,
            expenses: expenses,
            laborCostRate: laborCostRate
        )
        let linkedExp = linkedExpenses(job: job, expenses: expenses)
        return NativeJobProfitabilitySectionState(
            jobID: job.id,
            rows: sectionRows(job: job, profitability: profitability),
            collectionSummary: collectionSummary(profitability),
            warnings: profitability.warnings.map(warningCopy),
            whatChanged: whatChangedItems(
                job: job,
                profitability: profitability,
                linkedExpenses: linkedExp
            )
        )
    }

    /// The est/actual/variance rows for the job-detail card, in render order.
    /// Mirrors `buildProfitabilityRows`: estimate-side figures are quotes,
    /// actual-side figures are real money, unknowns render as "—", never $0.
    static func sectionRows(
        job: Canonical.Job,
        profitability p: JobProfitability
    ) -> [NativeJobProfitabilityRow] {
        var rows: [NativeJobProfitabilityRow] = []

        rows.append(.init(
            key: "revenue",
            label: "Revenue",
            estimate: quote(p.estimatedRevenue),
            actual: money(p.finalBillable),
            variance: p.changeOrderRevenue != 0 ? signedMoney(p.changeOrderRevenue) : nil,
            // A won change order grows the job; a descope credit is a recorded
            // agreement, not a failure — neutral, not bad.
            tone: p.changeOrderRevenue > 0 ? .good : p.changeOrderRevenue < 0 ? .neutral : nil
        ))

        rows.append(.init(
            key: "hours",
            label: "Labor hours",
            estimate: p.estimatedLaborHours > 0 ? laborHint(p.estimatedLaborHours) : unknown,
            actual: p.actualLaborHours.map(laborHint) ?? unknown,
            variance: p.laborHoursVariance.map { $0 != 0 ? signedHours($0) : nil } ?? nil,
            tone: p.laborHoursVariance.map {
                $0 != 0 ? ($0 > 0 ? .bad : .good) : nil
            } ?? nil
        ))

        rows.append(.init(
            key: "materials",
            label: "Materials cost",
            estimate: quote(p.estimatedMaterialCost),
            actual: p.actualMaterialExpense.map(money) ?? unknown,
            variance: p.materialsVariance.map { $0 != 0 ? signedMoney($0) : nil } ?? nil,
            tone: p.materialsVariance.map {
                $0 != 0 ? ($0 > 0 ? .bad : .good) : nil
            } ?? nil
        ))

        // Direct costs. The row appears when there is a planned direct cost
        // OR an actual non-materials expense. The variance only compares when
        // a plan exists — an unplanned "other" expense isn't an overrun of a
        // zero plan.
        let hasEstimatedDirect = p.estimatedDirectCost > 0
        let hasActualOther = (p.otherDirectExpenses ?? 0) > 0
        if hasEstimatedDirect || hasActualOther {
            let variance = (hasEstimatedDirect
                && p.directCostVariance != nil
                && p.directCostVariance != 0) ? p.directCostVariance : nil
            rows.append(.init(
                key: "otherExpenses",
                label: hasEstimatedDirect ? "Direct costs" : "Other job expenses",
                estimate: hasEstimatedDirect ? quote(p.estimatedDirectCost) : unknown,
                actual: p.otherDirectExpenses.map(money) ?? unknown,
                variance: variance.map(signedMoney),
                tone: variance.map { $0 > 0 ? .bad : .good } ?? nil
            ))
        }

        let profitDelta = FinancialDecimal.javascriptCents(
            p.actualGrossProfitBilled - p.estimatedGrossProfit
        )
        rows.append(.init(
            key: "profit",
            label: "Gross profit",
            estimate: quote(p.estimatedGrossProfit),
            actual: money(p.actualGrossProfitBilled),
            variance: profitDelta != 0 ? signedMoney(profitDelta) : nil,
            tone: profitDelta > 0 ? .good : profitDelta < 0 ? .bad : nil
        ))

        // Estimate-side effective hourly mirrors the pricing engine's
        // definition: (total − charged materials − direct costs) / hours.
        let estimatedHourly = estimatedEffectiveHourly(
            job: job,
            estimatedRevenue: p.estimatedRevenue
        )
        rows.append(.init(
            key: "hourly",
            label: "Earned per hour",
            estimate: estimatedHourly.map { "\(money($0))/hr" } ?? unknown,
            actual: p.effectiveHourlyActual.map { "\(money($0))/hr" } ?? unknown,
            variance: nil,
            tone: nil
        ))

        return rows
    }

    /// One-line invoicing/cash summary. `nil` when the job has no invoiced or
    /// collected money at all. Invoiced and collected are never summed — they
    /// are stated side by side.
    static func collectionSummary(_ p: JobProfitability) -> String? {
        guard p.invoicedAmount > 0 || p.cashCollected > 0 else { return nil }
        var line = "Collected \(money(p.cashCollected)) of \(money(p.invoicedAmount)) invoiced"
        if p.outstandingReceivable > 0 {
            line += " · \(money(p.outstandingReceivable)) outstanding"
        }
        if p.overpaidAmount > 0 {
            line += " · overpaid \(money(p.overpaidAmount))"
        }
        return line
    }

    /// The "What changed?" contributors, in stable order: approved change
    /// orders, the labor delta, each linked expense, then money not yet
    /// collected. Pure presentation of already-computed figures.
    static func whatChangedItems(
        job: Canonical.Job,
        profitability p: JobProfitability,
        linkedExpenses: [Canonical.Expense]
    ) -> [NativeJobProfitabilityWhatChangedItem] {
        var items: [NativeJobProfitabilityWhatChangedItem] = []

        for order in job.changeOrders ?? [] {
            guard NativeChangeOrders.status(of: order) == .approved else { continue }
            items.append(.init(
                key: "co:\(order.id)",
                label: "Change order — \(order.title)",
                amount: signedMoney(order.amount),
                tone: order.amount > 0 ? .good : .neutral
            ))
        }

        if let variance = p.laborHoursVariance, variance != 0 {
            let over = variance > 0
            items.append(.init(
                key: "hours",
                label: over ? "Labor over estimate" : "Labor under estimate",
                amount: signedHours(variance),
                tone: over ? .bad : .good
            ))
        }

        for expense in linkedExpenses {
            items.append(.init(
                key: "exp:\(expense.id)",
                label: "\(expense.description) (\(expenseCategoryLabel(expense.category)))",
                amount: money(expense.amount),
                tone: .neutral
            ))
        }

        if p.outstandingReceivable > 0 {
            items.append(.init(
                key: "outstanding",
                label: "Not yet collected",
                amount: money(p.outstandingReceivable),
                tone: .bad
            ))
        }

        return items
    }

    // MARK: - Estimate-side helpers

    /// `(total − charged materials − direct costs) / hours` on the saved job,
    /// mirroring the pricing engine's `effectiveHourlyRate`. Charged materials
    /// are the marked-up figure (revenue-side); direct lines use the same
    /// per-line amounts the estimate breakdown renders.
    static func estimatedEffectiveHourly(
        job: Canonical.Job,
        estimatedRevenue: Decimal
    ) -> Decimal? {
        guard job.laborHours > 0 else { return nil }
        let materialBase = job.materials.reduce(Decimal.zero) {
            $0 + $1.quantity * $1.unitCost
        }
        let materialCost = materialBase * (1 + job.materialMarkup / 100)
        let directTotal = (job.jobCosts ?? []).reduce(Decimal.zero) {
            $0 + directLineAmount($1)
        }
        return FinancialDecimal.javascriptCents(
            (estimatedRevenue - materialCost - directTotal) / job.laborHours
        )
    }

    /// One estimate line's customer-facing amount: the base marked up when
    /// the policy says so, at cost otherwise. The default policy is
    /// category-derived exactly like `defaultMarkupPolicyForCategory` in
    /// `utils/pricingEngine.ts` (permit passes through, everything else joins
    /// the margin base). Rounded per line like the breakdown's `round`.
    static func directLineAmount(_ cost: Canonical.JobCost) -> Decimal {
        let policy = cost.markupPolicy.isEmpty
            ? (cost.category == "permit" ? "passthrough" : "in_margin_base")
            : cost.markupPolicy
        let base = cost.quantity * cost.unitCost
        let amount = policy == "in_margin_base"
            ? base * (1 + cost.markupPercent / 100)
            : base
        return FinancialDecimal.javascriptCents(amount)
    }

    /// Expense category labels, mirroring `EXPENSE_CATEGORIES` in
    /// `utils/moneyUtils.ts`. Unknown ids fall back to "Other".
    static func expenseCategoryLabel(_ id: String) -> String {
        switch id {
        case "materials": "Materials"
        case "tools": "Tools & Equipment"
        case "fuel": "Fuel & Transport"
        case "labor": "Subcontractors"
        case "insurance": "Insurance"
        case "software": "Software & Apps"
        case "marketing": "Marketing"
        default: "Other"
        }
    }

    // MARK: - Formatting (mirrors utils/format.ts + formatLaborHint)

    static let unknown = "—"

    /// Actual money: always cents (`$2,400.00`, `-$500.00`).
    static func money(_ value: Decimal) -> String {
        moneyFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }

    /// Estimate/quote headline: whole dollars, cents only when not round
    /// (`$2,400` but `$2,499.50`).
    static func quote(_ value: Decimal) -> String {
        let cents = FinancialDecimal.javascriptCents(value)
        let number = NSDecimalNumber(decimal: cents)
        if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
            return quoteWholeFormatter.string(from: number) ?? "$0"
        }
        return money(cents)
    }

    /// `2` → `"2h"`, `2.5` → `"2h 30m"`, `0.25` → `"15m"` — mirrors
    /// `formatLaborHint` in `utils/scheduleSmarts.ts`.
    static func laborHint(_ hours: Decimal) -> String {
        let totalMinutes = Int((NSDecimalNumber(decimal: hours).doubleValue * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    static func signedMoney(_ value: Decimal) -> String {
        value > 0 ? "+\(money(value))" : money(value)
    }

    static func signedHours(_ value: Decimal) -> String {
        value > 0 ? "+\(laborHint(value))" : "-\(laborHint(-value))"
    }

    // MARK: - Time

    private static func isoDate(_ value: String) -> Date? {
        isoWithFractional.date(from: value) ?? isoPlain.date(from: value)
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let quoteWholeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

/// Variance tone for a profitability row or what-changed item, mirroring the
/// oracle's good/bad/neutral chips.
enum NativeProfitabilityTone: String, Equatable {
    case good, bad, neutral
}

/// One est/actual/variance row of the job-detail card. Unknown sides render
/// as "—" (`.unknown`), never $0; a `nil` variance renders no chip.
struct NativeJobProfitabilityRow: Equatable {
    let key: String
    let label: String
    let estimate: String
    let actual: String
    let variance: String?
    let tone: NativeProfitabilityTone?
}

/// One "What changed?" drill-down entry.
struct NativeJobProfitabilityWhatChangedItem: Equatable {
    let key: String
    let label: String
    let amount: String
    let tone: NativeProfitabilityTone
}

/// The job-detail "Estimate vs actual" card read model.
struct NativeJobProfitabilitySectionState: Equatable {
    let jobID: String
    let rows: [NativeJobProfitabilityRow]
    /// One-line invoicing/cash summary, or `nil` when there is nothing to
    /// summarise.
    let collectionSummary: String?
    /// User-facing unknown-data copy, in canonical warning order.
    let warnings: [String]
    let whatChanged: [NativeJobProfitabilityWhatChangedItem]
}
