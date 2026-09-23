import Foundation

// MARK: - Business snapshot (task 10.01, requirements S1, S2)
//
// Pure port of `utils/businessSnapshot.ts` (`aggregateSnapshot` +
// `buildTaxSnapshotBlock`). The snapshot is the compact business summary the AI
// coach may cite, so every figure comes from the shared engines —
// `PaymentLedger` (balances), `NativeCashBasis.collectedByPeriod` (revenue),
// `NativeChangeOrders.billableTotal` (job value), and `TaxEstimateEngine` — and
// nothing here mutates canonical state.
//
// Customer rollup: the join/aggregation *rules* are `NativeCustomerIdentity`'s
// (id → name → derived name key; lifetime spend = Σ amountPaid; owed =
// Σ balanceDue; sorted by lifetime spend, ties in first-seen order). This file
// applies those rules to **canonical** arrays so the snapshot never routes money
// through the UI projection's `Double`s; the money math itself stays the shared
// `PaymentLedger`, not a re-derivation.

/// `TopCustomerEntry`.
struct NativeTopCustomerEntry: Equatable {
    var name: String
    var lifetimeSpend: Decimal
    var amountOwed: Decimal
}

/// `TaxSnapshotBlock` — the tax set-aside figures the coach may cite, paired with
/// the prompt's "guidance only" constraint.
struct NativeTaxSnapshotBlock: Equatable {
    var periodReserve: Decimal
    var yearToDateReserve: Decimal
    /// "Jun 1 – Aug 31"
    var periodLabel: String
    /// "Sep 15"
    var dueLabel: String
    var incomeRateSet: Bool
    var needsVehicleChoice: Bool
    var ratesKnown: Bool
}

/// `BusinessSnapshot` without `asOf`/`tax` — `aggregateSnapshot`'s return shape.
struct NativeBusinessSnapshotAggregate: Equatable {
    var revenueThisMonth: Decimal
    var revenueLastMonth: Decimal
    var outstandingTotal: Decimal
    var overdueTotal: Decimal
    var overdueCount: Int
    /// Only statuses with at least one job, exactly like RN's partial record.
    var activeJobsByStatus: [String: Int]
    var totalCustomers: Int
    var topCustomers: [NativeTopCustomerEntry]
    var avgCompletedJobValue: Decimal
}

/// `BusinessSnapshot` — the aggregate plus the snapshot stamp and the optional
/// tax block (absent, never zeroed, when the tax inputs could not be built).
struct NativeBusinessSnapshot: Equatable {
    var asOf: String
    var aggregate: NativeBusinessSnapshotAggregate
    var tax: NativeTaxSnapshotBlock?

    var revenueThisMonth: Decimal { aggregate.revenueThisMonth }
    var revenueLastMonth: Decimal { aggregate.revenueLastMonth }
    var outstandingTotal: Decimal { aggregate.outstandingTotal }
    var overdueTotal: Decimal { aggregate.overdueTotal }
    var overdueCount: Int { aggregate.overdueCount }
    var activeJobsByStatus: [String: Int] { aggregate.activeJobsByStatus }
    var totalCustomers: Int { aggregate.totalCustomers }
    var topCustomers: [NativeTopCustomerEntry] { aggregate.topCustomers }
    var avgCompletedJobValue: Decimal { aggregate.avgCompletedJobValue }
}

enum NativeBusinessSnapshotEngine {
    /// The canonical statuses `aggregateSnapshot` counts as "active work".
    static let activeStatuses: Set<String> = [
        "lead", "estimate_sent", "approved", "scheduled", "in_progress",
    ]

    /// The canonical statuses that count as delivered work for the average.
    static let doneStatuses: Set<String> = ["complete", "invoiced", "paid"]

    static let topCustomerLimit = 5

    // MARK: aggregateSnapshot

    /// Pure aggregation. `now` is injected so month windows are deterministic.
    static func aggregate(
        invoices: [Canonical.Invoice],
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        now: Date
    ) -> NativeBusinessSnapshotAggregate {
        let (year, month, _) = NativeCashBasis.localComponents(now)
        let lastYear = month == 0 ? year - 1 : year
        let lastMonth = month == 0 ? 11 : month - 1

        // `new Date(y, m, 1) … new Date(y, m+1, 0)` — local midnight bounds, so a
        // date-only payment on the last day of the month still lands in it.
        let thisMonthRange = NativeDateRange(
            start: NativeCashBasis.localDate(year: year, month: month, day: 1),
            end: NativeCashBasis.localDate(year: year, month: month + 1, day: 0)
        )
        let lastMonthRange = NativeDateRange(
            start: NativeCashBasis.localDate(year: lastYear, month: lastMonth, day: 1),
            end: NativeCashBasis.localDate(year: lastYear, month: lastMonth + 1, day: 0)
        )
        let revenue = NativeCashBasis.collectedByPeriod(
            invoices: invoices, ranges: [thisMonthRange, lastMonthRange]
        )

        var outstandingTotal = Decimal.zero
        var overdueTotal = Decimal.zero
        var overdueCount = 0
        for invoice in invoices {
            // Not either/or: a partly-paid invoice contributes revenue for what
            // arrived AND outstanding for what is still owed.
            let balance = PaymentLedger.balanceDue(NativeCashBasis.ledgerInvoice(invoice))
            outstandingTotal += balance
            if balance > 0, NativeMoneyReports.isOverdue(invoice, now: now) {
                overdueTotal += balance
                overdueCount += 1
            }
        }

        var activeJobsByStatus: [String: Int] = [:]
        var completedJobTotal = Decimal.zero
        var completedJobCount = 0
        for job in jobs {
            if activeStatuses.contains(job.status) {
                activeJobsByStatus[job.status, default: 0] += 1
            }
            if doneStatuses.contains(job.status) {
                let billable = NativeChangeOrders.billableTotal(for: job)
                if billable > 0 {
                    completedJobTotal += billable
                    completedJobCount += 1
                }
            }
        }

        let list = customerRollup(invoices: invoices, customers: customers)
        let top = list.prefix(topCustomerLimit).map {
            NativeTopCustomerEntry(name: $0.name, lifetimeSpend: $0.lifetimeSpend, amountOwed: $0.amountOwed)
        }

        return NativeBusinessSnapshotAggregate(
            revenueThisMonth: revenue.first ?? 0,
            revenueLastMonth: revenue.count > 1 ? revenue[1] : 0,
            outstandingTotal: outstandingTotal,
            overdueTotal: overdueTotal,
            overdueCount: overdueCount,
            activeJobsByStatus: activeJobsByStatus,
            totalCustomers: list.count,
            topCustomers: Array(top),
            avgCompletedJobValue: completedJobCount > 0
                ? completedJobTotal / Decimal(completedJobCount)
                : 0
        )
    }

    // MARK: buildTaxSnapshotBlock

    /// Reduce the shared tax window summary to the compact prompt block.
    static func buildTaxBlock(
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        trips: [Canonical.Trip],
        values: NativeTaxSettingsValues,
        mileageRate: Decimal,
        now: Date
    ) -> NativeTaxSnapshotBlock {
        var settings = values.taxWindowSettings
        settings.mileageRate = mileageRate
        let summary = TaxEstimateEngine.summarize(
            invoices: invoices.map(NativeCashBasis.ledgerInvoice),
            expenses: expenses.map {
                TaxExpense(amount: $0.amount, category: $0.category, date: $0.date)
            },
            trips: trips.map { TaxTrip(date: $0.date, miles: $0.miles) },
            settings: settings,
            on: NativeCashBasis.ymd(now)
        )
        return NativeTaxSnapshotBlock(
            periodReserve: summary.current.reserve,
            yearToDateReserve: summary.yearToDate.reserve,
            periodLabel: NativeTaxBreakdown.periodRange(summary.period),
            dueLabel: NativeTaxBreakdown.deadlineText(summary.period),
            incomeRateSet: values.taxIncomeRate != nil,
            needsVehicleChoice: summary.needsVehicleChoice,
            ratesKnown: summary.current.ratesKnown
        )
    }

    // MARK: getBusinessSnapshot

    /// The live-shaped snapshot: aggregate + `asOf` + tax. `asOf` is the **UTC**
    /// calendar date of `now`, matching RN's
    /// `now.toISOString().split("T")[0]` (the one deliberate UTC use in this
    /// feature — it stamps when the snapshot was taken, not a business window).
    /// Pass `includeTax: false` to model an input failure; the block is then
    /// absent rather than zeroed, exactly as RN leaves `tax` undefined.
    static func make(
        invoices: [Canonical.Invoice],
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        expenses: [Canonical.Expense],
        trips: [Canonical.Trip],
        values: NativeTaxSettingsValues,
        mileageRate: Decimal,
        now: Date,
        includeTax: Bool = true
    ) -> NativeBusinessSnapshot {
        NativeBusinessSnapshot(
            asOf: utcDateString(now),
            aggregate: aggregate(invoices: invoices, jobs: jobs, customers: customers, now: now),
            tax: includeTax
                ? buildTaxBlock(
                    invoices: invoices, expenses: expenses, trips: trips,
                    values: values, mileageRate: mileageRate, now: now
                )
                : nil
        )
    }

    /// `now.toISOString().split("T")[0]`.
    static func utcDateString(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    // MARK: Customer rollup (NativeCustomerIdentity rules, canonical inputs)

    struct CustomerRollupEntry: Equatable {
        var id: String
        var name: String
        var lifetimeSpend: Decimal
        var amountOwed: Decimal
    }

    /// `buildCustomerList`'s join and aggregation over canonical records.
    static func customerRollup(
        invoices: [Canonical.Invoice],
        customers: [Canonical.Customer]
    ) -> [CustomerRollupEntry] {
        var entries: [String: CustomerRollupEntry] = [:]
        var order: [String] = []
        var idByName: [String: String] = [:]

        for customer in customers where !customer.id.isEmpty {
            if entries[customer.id] == nil { order.append(customer.id) }
            entries[customer.id] = CustomerRollupEntry(
                id: customer.id,
                name: customer.name.trimmingCharacters(in: .whitespacesAndNewlines),
                lifetimeSpend: 0,
                amountOwed: 0
            )
            let key = NativeCustomerIdentity.normalizedName(customer.name)
            if !key.isEmpty { idByName[key] = customer.id }
        }

        for invoice in invoices {
            let nameKey = NativeCustomerIdentity.normalizedName(invoice.customer)
            var id = invoice.customerId ?? ""
            if id.isEmpty, let matched = idByName[nameKey] { id = matched }
            if id.isEmpty {
                guard !nameKey.isEmpty else { continue }
                id = nameKey
                idByName[nameKey] = id
            }
            if entries[id] == nil {
                order.append(id)
                entries[id] = CustomerRollupEntry(
                    id: id,
                    name: invoice.customer.trimmingCharacters(in: .whitespacesAndNewlines),
                    lifetimeSpend: 0,
                    amountOwed: 0
                )
            }
            guard var entry = entries[id] else { continue }
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            entry.lifetimeSpend += PaymentLedger.amountPaid(ledger)
            entry.amountOwed += PaymentLedger.balanceDue(ledger)
            entries[id] = entry
        }

        let insertion = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.compactMap { entries[$0] }.enumerated().sorted { lhs, rhs in
            if lhs.element.lifetimeSpend != rhs.element.lifetimeSpend {
                return lhs.element.lifetimeSpend > rhs.element.lifetimeSpend
            }
            return (insertion[lhs.element.id] ?? 0) < (insertion[rhs.element.id] ?? 0)
        }.map(\.element)
    }
}
