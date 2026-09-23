import Foundation

/// Pure port of `utils/todayInsights.ts` (task 10.02, requirement S3).
///
/// Deterministic "proactive insights" rules for the Today screen. Pure — no
/// I/O, injected clock, dependency-free beyond Foundation and the existing
/// pure engines it reuses: `NativeTimeTracking` (labor overrun),
/// `NativeSchedule`/`NativeCalendar` (open slot, unscheduled approved),
/// `NativeChangeOrders` (billable total), `NativeCashBasis`/
/// `NativeMoneyReports`/`PaymentLedger` (due-soon money math). The card
/// (10.12) renders the first 3 of whatever `NativeTodayInsights.select`
/// returns after mute filtering (10.03) — PRIORITY IS THE ORDER THE RULES RUN.
///
/// All local-frame date/month math is pure string/component arithmetic
/// (`NativeSchedule.shiftDate`, `monthsBetween`, `shiftMonth`) — never
/// `Date`-parsing a bare `YYYY-MM-DD` (FA-039).
public enum NativeInsightKind: String, Equatable, Hashable, Codable {
    case laborOverrun = "labor_overrun"
    case lowMarginEstimate = "low_margin_estimate"
    case uninvoicedComplete = "uninvoiced_complete"
    case dueSoon = "due_soon"
    case openSlot = "open_slot"
    case unscheduledApproved = "unscheduled_approved"
    case maintenanceDue = "maintenance_due"
    case expenseAnomaly = "expense_anomaly"
}

/// Mirrors `InsightTarget` — the routing contract 10.04 maps onto
/// `NativeTodayDestination`. Exhaustive and Equatable/Hashable so that
/// mapping is compiler-checked.
public enum NativeInsightTarget: Equatable, Hashable {
    case job(jobId: String)
    case createInvoice(jobId: String)
    case invoice(invoiceId: String)
    case invoices
    case jobs
    case schedule(jobId: String)
    case selectDate(date: String)
    case customer(customerId: String)
    case customers
    case money
}

/// One proactive insight row. `id` is the stable dedup identity the mute
/// policy (`NativeInsightMutes`, task 10.03) hangs dismissals/snoozes on:
/// `kind:recordId`, `kind:all` for aggregate rows, `kind:date`/`kind:period`
/// for time-scoped rows.
public struct NativeTodayInsight: Equatable, Hashable {
    public var kind: NativeInsightKind
    public var id: String
    public var title: String
    public var detail: String?
    public var target: NativeInsightTarget
    /// Deterministic "why am I seeing this" — every number computed in code.
    public var reason: String
    /// Prefills the AI coach input (never auto-sent).
    public var coachPrompt: String?

    public init(
        kind: NativeInsightKind,
        id: String,
        title: String,
        detail: String? = nil,
        target: NativeInsightTarget,
        reason: String,
        coachPrompt: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.detail = detail
        self.target = target
        self.reason = reason
        self.coachPrompt = coachPrompt
    }
}

public enum NativeTodayInsights {

    // MARK: - Constants (frozen — docs/native-phase-10-today-coach-notifications-contract-decisions.md §3)

    /// Quarter-hour floor — sub-15-minute overruns are noise to a trade.
    public static let overrunMinHours = 0.25
    /// Fire when the implied margin is at least this many percentage points
    /// under the Settings target.
    public static let marginTolerancePts = 3.0
    /// How many days ahead (inclusive) "due soon" looks; day +1 belongs to
    /// the Overdue section (due-today is NOT overdue).
    public static let dueSoonDays = 2
    /// Minimum free gap worth surfacing, in minutes.
    public static let minGapMinutes = 120
    /// Fixed cadence for the maintenance-due rule — a constant, not a setting.
    public static let maintenanceDueMonths = 6
    /// Month-to-date spend must exceed this multiple of the prior-3-month
    /// average to surface.
    public static let expenseAnomalyMult = 1.5
    /// Below this month-to-date total the multiple is noise.
    public static let expenseAnomalyMinMTD = 200.0
    /// Default target margin when `targetMarginPercent` is absent.
    public static let defaultTargetMarginPercent = 20.0

    private static let overrunStatuses: Set<String> = ["approved", "scheduled", "in_progress"]
    private static let lowMarginStatuses: Set<String> = ["lead", "estimate_sent"]
    private static let serviceHistoryStatuses: Set<String> = ["complete", "invoiced", "paid"]
    private static let activePipelineStatuses: Set<String> = [
        "lead", "estimate_sent", "approved", "scheduled", "in_progress",
    ]

    private static let expenseCategoryLabels: [String: String] = [
        "materials": "Materials",
        "tools": "Tools & Equipment",
        "fuel": "Fuel & Transport",
        "labor": "Subcontractors",
        "insurance": "Insurance",
        "software": "Software & Apps",
        "marketing": "Marketing",
        "other": "Other",
    ]

    // MARK: - Entry point

    /// Concatenates all eight selectors, in the documented priority order.
    /// Absent inputs suppress their rules instead of guessing:
    /// `customers`/`recurringJobs`/`expenses` default to empty arrays.
    public static func select(
        jobs: [Canonical.Job],
        invoices: [Canonical.Invoice],
        now: Date,
        schedule: NativeSchedule.ResolvedSchedule = .defaults,
        targetMarginPercent: Double = NativeTodayInsights.defaultTargetMarginPercent,
        customers: [Canonical.Customer] = [],
        recurringJobs: [Canonical.RecurringJob] = [],
        expenses: [Canonical.Expense] = []
    ) -> [NativeTodayInsight] {
        var out: [NativeTodayInsight] = []
        out.append(contentsOf: selectLaborOverruns(jobs: jobs, now: now))
        out.append(contentsOf: selectLowMarginEstimates(jobs: jobs, targetMarginPercent: targetMarginPercent))
        out.append(contentsOf: selectUninvoicedComplete(jobs: jobs))
        out.append(contentsOf: selectDueSoon(invoices: invoices, now: now))
        out.append(contentsOf: selectScheduleInsights(jobs: jobs, now: now, schedule: schedule))
        // Long-horizon, so it rides last — it must never crowd out today's-money
        // rows given the card's top-3 cap.
        out.append(contentsOf: selectMaintenanceDue(jobs: jobs, customers: customers, recurringJobs: recurringJobs, now: now))
        // Business-level spend trend — lowest priority.
        out.append(contentsOf: selectExpenseAnomaly(expenses: expenses, now: now))
        return out
    }

    // MARK: - 1. labor_overrun

    static func selectLaborOverruns(jobs: [Canonical.Job], now: Date) -> [NativeTodayInsight] {
        var out: [NativeTodayInsight] = []
        for job in jobs {
            guard overrunStatuses.contains(job.status), !isArchived(job.archivedAt) else { continue }
            guard job.laborHours > 0, let sessions = job.timeSessions, !sessions.isEmpty else { continue }
            let native = sessions.map { NativeTimeSession(start: $0.start, end: $0.end) }
            let summary = NativeTimeTracking.summary(sessions: native, estimatedHours: job.laborHours, now: now)
            guard let overUnder = summary.overUnder, double(overUnder) >= overrunMinHours else { continue }
            let laborHint = NativeSchedule.formatLaborHint(double(job.laborHours))
            let overrunLabel = NativeTimeTracking.elapsedLabel(milliseconds: double(overUnder) * 3_600_000)
            let liveLabel = NativeTimeTracking.elapsedLabel(milliseconds: summary.liveMs)
            out.append(NativeTodayInsight(
                kind: .laborOverrun,
                id: "labor_overrun:\(job.id)",
                title: "'\(job.title)' is \(overrunLabel) over its \(laborHint) labor estimate",
                target: .job(jobId: job.id),
                reason: "You've logged \(liveLabel) on '\(job.title)' against a \(laborHint) labor " +
                    "estimate — at least 15 minutes over. This clears on its own when the job is " +
                    "completed or the estimate is updated.",
                coachPrompt: "I'm working on '\(job.title)' and I've logged \(liveLabel) against a " +
                    "\(laborHint) labor estimate at \(formatMoney(double(job.laborRate)))/hr " +
                    "(estimate total \(formatQuote(double(job.estimateTotal)))). How should I handle " +
                    "the overrun — talk to the customer now, absorb it, or adjust the bill?"
            ))
        }
        return out
    }

    // MARK: - 2. low_margin_estimate

    private struct LowMarginHit {
        let job: Canonical.Job
        let impliedPct: Double
        let profit: Double
        let laborCost: Double
        let materialCost: Double
        let overheadAt: Double
    }

    static func selectLowMarginEstimates(jobs: [Canonical.Job], targetMarginPercent: Double) -> [NativeTodayInsight] {
        var hits: [LowMarginHit] = []
        for job in jobs {
            guard lowMarginStatuses.contains(job.status), !isArchived(job.archivedAt) else { continue }
            let estimateTotal = double(job.estimateTotal)
            let laborHours = double(job.laborHours)
            let laborRate = double(job.laborRate)
            guard estimateTotal > 0, laborHours > 0, laborRate > 0 else { continue }
            let laborCost = laborHours * laborRate
            let materialBase = job.materials.reduce(0.0) { $0 + double($1.quantity) * double($1.unitCost) }
            let materialCost = materialBase * (1 + double(job.materialMarkup) / 100)
            let costBase = laborCost + materialCost
            guard costBase > 0 else { continue }
            let overheadAt = costBase * (double(job.overhead) / 100)
            let profit = estimateTotal - costBase - overheadAt
            let impliedPct = (profit / (costBase + overheadAt)) * 100
            if impliedPct <= targetMarginPercent - marginTolerancePts {
                hits.append(LowMarginHit(job: job, impliedPct: impliedPct, profit: profit,
                                          laborCost: laborCost, materialCost: materialCost, overheadAt: overheadAt))
            }
        }
        guard !hits.isEmpty else { return [] }
        hits.sort { $0.impliedPct < $1.impliedPct }
        let worst = hits[0]
        let estimateTotal = double(worst.job.estimateTotal)
        let severe = worst.profit < 0
        let pointsUnder = Int((targetMarginPercent - worst.impliedPct).rounded())
        let others = hits.count - 1
        let overheadLabel = jsNumber(double(worst.job.overhead))
        let targetLabel = jsNumber(targetMarginPercent)
        let baseDetail = severe
            ? "\(formatQuote(-worst.profit)) short of break-even"
            : "\(formatQuote(worst.profit)) profit on \(formatQuote(estimateTotal))"
        let detail = others > 0 ? "\(baseDetail) · \(others) more under target" : baseDetail
        let title = severe
            ? "'\(worst.job.title)' is priced below your costs and overhead"
            : "'\(worst.job.title)' is priced \(pointsUnder) points under your \(targetLabel)% margin"
        return [NativeTodayInsight(
            kind: .lowMarginEstimate,
            id: "low_margin_estimate:\(worst.job.id):\(jsNumber(estimateTotal))",
            title: title,
            detail: detail,
            target: .job(jobId: worst.job.id),
            reason: "Priced at \(formatQuote(estimateTotal)): labor \(formatQuote(worst.laborCost)) + " +
                "materials \(formatQuote(worst.materialCost)) + overhead at \(overheadLabel)% " +
                "(\(formatQuote(worst.overheadAt))) leaves \(formatQuote(worst.profit)) — an implied " +
                "margin of \(fixed(worst.impliedPct, 1))% vs your \(targetLabel)% target. Dismissing " +
                "hides this until the price changes.",
            coachPrompt: "My estimate for '\(worst.job.title)' totals \(formatQuote(estimateTotal)): " +
                "labor \(formatQuote(worst.laborCost)), materials \(formatQuote(worst.materialCost)), " +
                "overhead \(formatQuote(worst.overheadAt)) at \(overheadLabel)%. That leaves " +
                "\(formatQuote(worst.profit)) profit — about \(fixed(worst.impliedPct, 0))% margin vs " +
                "my \(targetLabel)% target. Should I raise the price, trim costs, or take it as-is?"
        )]
    }

    // MARK: - 3. uninvoiced_complete

    static func selectUninvoicedComplete(jobs: [Canonical.Job]) -> [NativeTodayInsight] {
        let done = jobs.filter { $0.status == "complete" && ($0.invoiceId ?? "").isEmpty && !isArchived($0.archivedAt) }
        if done.isEmpty { return [] }
        if done.count == 1 {
            let job = done[0]
            let billable = double(NativeChangeOrders.billableTotal(for: job))
            return [NativeTodayInsight(
                kind: .uninvoicedComplete,
                id: "uninvoiced_complete:\(job.id)",
                title: "'\(job.title)' is complete but not invoiced",
                detail: billable > 0 ? "\(formatQuote(billable)) to bill" : nil,
                target: .createInvoice(jobId: job.id),
                reason: "'\(job.title)' is marked complete but has no invoice yet. This clears once an invoice is created."
            )]
        }
        return [NativeTodayInsight(
            kind: .uninvoicedComplete,
            id: "uninvoiced_complete:all",
            title: "\(done.count) completed jobs haven't been invoiced",
            target: .jobs,
            reason: "\(done.count) jobs are marked complete but have no invoice yet. This clears as invoices are created."
        )]
    }

    // MARK: - 4. due_soon

    private static func dueLabel(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days == -1 { return "tomorrow" }
        return "in \(-days) days"
    }

    static func selectDueSoon(invoices: [Canonical.Invoice], now: Date) -> [NativeTodayInsight] {
        let soon: [(invoice: Canonical.Invoice, days: Int)] = invoices.compactMap { invoice in
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            guard !PaymentLedger.isFullyPaid(ledger) else { return nil }
            let days = NativeMoneyReports.daysPastDue(invoice.due, now: now)
            guard days <= 0, days >= -dueSoonDays else { return nil }
            return (invoice, days)
        }
        if soon.isEmpty { return [] }
        if soon.count == 1 {
            let (invoice, days) = soon[0]
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            let balance = double(PaymentLedger.balanceDue(ledger))
            let label = dueLabel(days)
            return [NativeTodayInsight(
                kind: .dueSoon,
                id: "due_soon:\(invoice.id)",
                title: "Invoice \(invoice.number) (\(formatMoney(balance))) is due \(label)",
                target: .invoice(invoiceId: invoice.id),
                reason: "Invoice \(invoice.number) still has a balance and is due \(label) " +
                    "(within the \(dueSoonDays)-day heads-up window). Once past due it moves to the Overdue section."
            )]
        }
        let total = soon.reduce(0.0) { partial, entry in
            partial + double(PaymentLedger.balanceDue(NativeCashBasis.ledgerInvoice(entry.invoice)))
        }
        return [NativeTodayInsight(
            kind: .dueSoon,
            id: "due_soon:all",
            title: "\(formatMoney(total)) across \(soon.count) invoices is due within \(dueSoonDays) days",
            target: .invoices,
            reason: "\(soon.count) invoices still carry a balance and fall due within \(dueSoonDays) days. " +
                "Once past due they move to the Overdue section."
        )]
    }

    // MARK: - 5 & 6. open_slot, unscheduled_approved

    static func selectScheduleInsights(
        jobs: [Canonical.Job],
        now: Date,
        schedule: NativeSchedule.ResolvedSchedule
    ) -> [NativeTodayInsight] {
        var out: [NativeTodayInsight] = []
        let today = NativeCashBasis.ymd(now)
        guard let tomorrow = NativeSchedule.shiftDate(today, days: 1) else { return out }

        let unscheduled = NativeCalendar.selectUnscheduledApproved(jobs: jobs)

        var fittedJobId: String?
        let tomorrowIsOpen = NativeSchedule.isWorkDay(schedule, date: tomorrow)
            && !NativeSchedule.isBlackoutDate(schedule, date: tomorrow)
        let gap = tomorrowIsOpen
            ? NativeSchedule.largestFreeGap(jobs: jobs, date: tomorrow, dayStart: schedule.workDayStart, dayEnd: schedule.workDayEnd)
            : nil

        if let gap, gap.minutes >= minGapMinutes {
            let gapLabel = NativeSchedule.formatLaborHint(Double(gap.minutes) / 60.0)
            let fit = unscheduled
                .filter { double($0.laborHours) > 0 && double($0.laborHours) * 60 <= Double(gap.minutes) }
                .sorted { $0.laborHours > $1.laborHours }
                .first
            let gapReason = "Tomorrow (\(tomorrow)) has \(gapLabel) free between your working hours " +
                "\(schedule.workDayStart)–\(schedule.workDayEnd) — at least 2 hours."
            if let fit {
                fittedJobId = fit.id
                let fitHint = NativeSchedule.formatLaborHint(double(fit.laborHours))
                out.append(NativeTodayInsight(
                    kind: .openSlot,
                    id: "open_slot:\(tomorrow)",
                    title: "Tomorrow has a \(gapLabel) open slot — '\(fit.title)' (\(fitHint)) would fit",
                    target: .schedule(jobId: fit.id),
                    reason: "\(gapReason) '\(fit.title)' is approved, unscheduled, and its \(fitHint) " +
                        "labor estimate fits the gap."
                ))
            } else {
                out.append(NativeTodayInsight(
                    kind: .openSlot,
                    id: "open_slot:\(tomorrow)",
                    title: "Tomorrow has a \(gapLabel) open slot",
                    target: .selectDate(date: tomorrow),
                    reason: gapReason
                ))
            }
        }

        let remaining = unscheduled.filter { $0.id != fittedJobId }
        if remaining.count == 1 {
            let job = remaining[0]
            out.append(NativeTodayInsight(
                kind: .unscheduledApproved,
                id: "unscheduled_approved:\(job.id)",
                title: "'\(job.title)' is approved but not scheduled",
                target: .schedule(jobId: job.id),
                reason: "'\(job.title)' is approved but has no date on the schedule. This clears once it's scheduled."
            ))
        } else if remaining.count > 1 {
            out.append(NativeTodayInsight(
                kind: .unscheduledApproved,
                id: "unscheduled_approved:all",
                title: "\(remaining.count) approved jobs aren't on the schedule yet",
                target: .jobs,
                reason: "\(remaining.count) approved jobs have no date on the schedule. This clears as they're scheduled."
            ))
        }
        return out
    }

    // MARK: - 7. maintenance_due

    /// Whole calendar months elapsed from a local `YYYY-MM-DD` to `now` —
    /// pure component math, never Date-parsing the string (FA-039).
    static func monthsBetween(from: String, now: Date) -> Int {
        guard let (y, m, d) = NativeSchedule.parseDateComponents(from) else { return 0 }
        let (ny, nmZeroBased, nd) = NativeCashBasis.localComponents(now)
        var months = (ny - y) * 12 + (nmZeroBased + 1 - m)
        if nd < d { months -= 1 }
        return months
    }

    private struct MaintenanceDue {
        let customer: Canonical.Customer
        let months: Int
        let lastDate: String
        let lastTitle: String
    }

    static func selectMaintenanceDue(
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        recurringJobs: [Canonical.RecurringJob],
        now: Date
    ) -> [NativeTodayInsight] {
        var due: [MaintenanceDue] = []
        for customer in customers {
            guard !customer.id.isEmpty, !isArchived(customer.archivedAt) else { continue }
            let hasContact = !customer.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !customer.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasContact else { continue }
            let theirJobs = jobs.filter { $0.customerId == customer.id }
            if theirJobs.contains(where: { activePipelineStatuses.contains($0.status) && !isArchived($0.archivedAt) }) { continue }
            if recurringJobs.contains(where: { $0.isActive && $0.customerId == customer.id }) { continue }
            var lastDate = ""
            var lastTitle = ""
            for job in theirJobs {
                guard serviceHistoryStatuses.contains(job.status), let scheduledDate = job.scheduledDate, !scheduledDate.isEmpty else { continue }
                if scheduledDate > lastDate {
                    lastDate = scheduledDate
                    lastTitle = job.title
                }
            }
            guard !lastDate.isEmpty else { continue }
            let months = monthsBetween(from: lastDate, now: now)
            if months >= maintenanceDueMonths {
                due.append(MaintenanceDue(customer: customer, months: months, lastDate: lastDate, lastTitle: lastTitle))
            }
        }
        if due.isEmpty { return [] }
        due.sort { $0.months > $1.months }
        if due.count == 1 {
            let entry = due[0]
            let customer = entry.customer
            let trimmedName = customer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstName = trimmedName.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? customer.name
            let hasLastTitle = !entry.lastTitle.isEmpty
            return [NativeTodayInsight(
                kind: .maintenanceDue,
                id: "maintenance_due:\(customer.id)",
                title: "It's been \(entry.months) months since you worked for \(customer.name)",
                detail: hasLastTitle ? "Last job: \(entry.lastTitle)" : nil,
                target: .customer(customerId: customer.id),
                reason: "Your last delivered job for \(customer.name)\(hasLastTitle ? " ('\(entry.lastTitle)')" : "") was " +
                    "\(entry.lastDate) — \(entry.months) months ago (threshold: \(maintenanceDueMonths)). They have no " +
                    "upcoming or in-progress work and no active recurring plan. Snoozing hides this for 30 days.",
                coachPrompt: "It's been \(entry.months) months since I did\(hasLastTitle ? " '\(entry.lastTitle)'" : " a job") for " +
                    "\(firstName). Draft a short, friendly check-in text offering to schedule their next service."
            )]
        }
        return [NativeTodayInsight(
            kind: .maintenanceDue,
            id: "maintenance_due:all",
            title: "\(due.count) customers haven't been serviced in \(maintenanceDueMonths)+ months",
            target: .customers,
            reason: "\(due.count) customers had their last delivered job over \(maintenanceDueMonths) months " +
                "ago and have no upcoming work or active recurring plan. Snoozing hides this for 30 days."
        )]
    }

    // MARK: - 8. expense_anomaly

    /// The `YYYY-MM` string `offset` whole months before another — pure
    /// component math, never Date-parsing the string (FA-039).
    static func shiftMonth(_ ym: String, offset: Int) -> String {
        let y0 = Int(ym.prefix(4)) ?? 0
        let m0 = Int(ym.suffix(2)) ?? 1
        var y = y0
        var m = m0 - offset
        while m <= 0 { m += 12; y -= 1 }
        while m > 12 { m -= 12; y += 1 }
        return String(format: "%04d-%02d", y, m)
    }

    static func selectExpenseAnomaly(expenses: [Canonical.Expense], now: Date) -> [NativeTodayInsight] {
        let today = NativeCashBasis.ymd(now)
        let currentYM = String(today.prefix(7))
        let priorYMs = [shiftMonth(currentYM, offset: 1), shiftMonth(currentYM, offset: 2), shiftMonth(currentYM, offset: 3)]

        var mtd = 0.0
        var priorTotals = [0.0, 0.0, 0.0]
        var mtdByCat: [String: Double] = [:]
        var priorByCat: [String: Double] = [:]

        for expense in expenses {
            let date = expense.date
            let ym = String(date.prefix(7))
            let amount = double(expense.amount)
            if ym == currentYM && date <= today {
                mtd += amount
                mtdByCat[expense.category, default: 0] += amount
            } else if let idx = priorYMs.firstIndex(of: ym) {
                priorTotals[idx] += amount
                priorByCat[expense.category, default: 0] += amount
            }
        }

        guard priorTotals.allSatisfy({ $0 > 0 }) else { return [] }
        let avg = (priorTotals[0] + priorTotals[1] + priorTotals[2]) / 3
        guard avg > 0, mtd >= expenseAnomalyMinMTD, mtd > expenseAnomalyMult * avg else { return [] }

        let pct = Int(((mtd - avg) / avg * 100).rounded())

        var topCat: String?
        var topDelta = -Double.infinity
        var topMtd = 0.0
        var topAvg = 0.0
        for (id, cMtd) in mtdByCat {
            let cAvg = (priorByCat[id] ?? 0) / 3
            let delta = cMtd - cAvg
            if delta > topDelta {
                topDelta = delta
                topCat = id
                topMtd = cMtd
                topAvg = cAvg
            }
        }
        let catLabel = topCat.flatMap { expenseCategoryLabels[$0] } ?? "Other"

        return [NativeTodayInsight(
            kind: .expenseAnomaly,
            id: "expense_anomaly:\(currentYM)",
            title: "Spending is running \(pct)% above your recent monthly average",
            detail: "\(formatMoney(mtd)) so far vs \(formatMoney(avg)) average",
            target: .money,
            reason: "This month you've spent \(formatMoney(mtd)) through \(today), versus a " +
                "\(formatMoney(avg)) average over the prior three months " +
                "(\(priorYMs[0]), \(priorYMs[1]), \(priorYMs[2])) — \(pct)% higher. Biggest driver: " +
                "\(catLabel) (\(formatMoney(topMtd)) vs \(formatMoney(topAvg)) average). " +
                "Dismissing hides this for the rest of the month."
        )]
    }

    // MARK: - Helpers

    static func isArchived(_ archivedAt: String?) -> Bool {
        !(archivedAt ?? "").isEmpty
    }

    static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// JS's default `${number}` stringification for the plain integers/halves
    /// this module deals in (margin targets, overhead percents).
    static func jsNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// `value.toFixed(digits)` — fixed decimal places, matching JS's default
    /// rounding for the finite, non-huge values this module computes.
    static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// `formatMoney` — always two decimals ("$2,400.00", "-$500.00").
    static func formatMoney(_ value: Double) -> String {
        moneyFormatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    /// `formatQuote` — whole dollars, or a full cent pair ("$2,499", "$87.50").
    static func formatQuote(_ value: Double) -> String {
        let cents = (value * 100).rounded() / 100
        let hasCents = cents.truncatingRemainder(dividingBy: 1) != 0
        let formatter = hasCents ? moneyFormatter : quoteWholeFormatter
        return formatter.string(from: NSNumber(value: cents)) ?? (hasCents ? "$0.00" : "$0")
    }

    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let quoteWholeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
