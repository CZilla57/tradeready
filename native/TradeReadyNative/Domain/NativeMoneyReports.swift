import Foundation

// MARK: - Money report engines (task 9.01, requirements M1 + M2)
//
// Pure ports of the React Native report derivations behind the Money tab:
// utils/invoiceStats.ts, invoiceAging.ts, customerMix.ts, seasonalTrends.ts,
// expenseTrends.ts, avgJobValue.ts, conversionFunnel.ts, revenueByType.ts,
// revenueForecast.ts, profitabilityAggregate.ts, plus the TopCustomersCard and
// ReceivablesCard read models. Every function is pure over canonical arrays and
// performs no I/O; results reproduce the RN oracle
// (docs/native-phase-9-money-exports-contract-decisions.md section 3).
//
// Split across three files: this one holds the shared result types, helpers, and
// the invoice/expense reports; `NativeMoneyReportsJobs.swift` holds the job-based
// reports; `NativeMoneyReportsReadModels.swift` holds the two card read models.

// MARK: Result types

/// Distinct from `NativeInvoiceSummary` in `NativeInvoiceList.swift` (that one
/// feeds the invoice-list header in `Double`; this is the cash-basis report
/// shape in `Decimal`).
struct NativeMoneyInvoiceSummary: Equatable {
    var outstanding: Decimal
    var overdueCount: Int
    var collected: Decimal
}

struct NativeCustomerPaySpeed: Equatable {
    var name: String
    var avgDays: Int
    var invoiceCount: Int
    var totalAmount: Decimal
}

struct NativeInvoiceAging: Equatable {
    var avgDays: Int
    var paidCount: Int
    var customers: [NativeCustomerPaySpeed]
}

struct NativeCustomerMix: Equatable {
    var newCount: Int
    var newRevenue: Decimal
    var returningCount: Int
    var returningRevenue: Decimal
}

struct NativeMonthlyTrend: Equatable {
    var label: String
    var month: Int
    var year: Int
    var thisYear: Decimal
    var lastYear: Decimal
}

struct NativeSeasonalTrends: Equatable {
    var months: [NativeMonthlyTrend]
    var thisYearTotal: Decimal
    var lastYearTotal: Decimal
    var yoyChangePct: Int?
}

struct NativeMonthlyExpense: Equatable {
    var label: String
    var month: Int
    var year: Int
    var total: Decimal
    var momChangePct: Int?
}

struct NativeExpenseTrends: Equatable {
    var months: [NativeMonthlyExpense]
    var trailingTotal: Decimal
    var avgMonthly: Int
    var overallTrend: Int?
}

struct NativeAvgJobValue: Equatable {
    var avgValue: Decimal
    var count: Int
    var totalValue: Decimal
}

struct NativeFunnelStage: Equatable {
    var status: String
    var label: String
    var count: Int
    var rate: Decimal?
}

struct NativeConversionFunnel: Equatable {
    var stages: [NativeFunnelStage]
    var totalJobs: Int
    var winRate: Decimal?
}

struct NativeRevenueComponent: Equatable {
    var label: String
    var total: Decimal
    var pct: Int
    var color: String
}

struct NativeRevenueByType: Equatable {
    var totalRevenue: Decimal
    var jobCount: Int
    var components: [NativeRevenueComponent]
}

struct NativeRevenueForecast: Equatable {
    var certainValue: Decimal
    var certainCount: Int
    var speculativeValue: Decimal
    var speculativeCount: Int
    var winRate: Decimal?
    var projectedValue: Decimal
    var totalForecast: Decimal
}

struct NativeProfitabilityHistory: Equatable {
    var doneJobs: Int
    var jobsWithData: Int
    var hourlyCount: Int
    var medianEffectiveHourly: Decimal?
    var laborCount: Int
    var medianLaborOverrunHours: Decimal?
    var materialsCount: Int
    var medianMaterialsOverrunRatio: Decimal?
    var medianMaterialsVariance: Decimal?
}

struct NativeTopCustomerRow: Equatable {
    var name: String
    var amount: Decimal
}

struct NativeReceivables: Equatable {
    var outstanding: Decimal
    var unpaidCount: Int
    var overdue: Decimal
    var overdueCount: Int
    var pipelineValue: Decimal
    var pipelineCount: Int
}

// MARK: Engine

enum NativeMoneyReports {
    /// `Math.round(n * 100) / 100` — the RN `round` helper.
    static func jsCents(_ value: Decimal) -> Decimal {
        FinancialDecimal.javascriptCents(value)
    }

    /// `Math.round(n)` for the whole-number percentage figures RN keeps.
    /// `NSDecimalRound(.plain)` is half away from zero, matching JS for the
    /// non-negative values these reports produce.
    static func jsRound(_ value: Decimal) -> Int {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 0, .plain)
        return NSDecimalNumber(decimal: output).intValue
    }

    /// `Number.toFixed`-free rounding to whole integers, half away from zero —
    /// matches JS `Math.round` for the non-negative figures these reports emit.
    static func roundInt(_ value: Double) -> Int {
        Int(value.rounded())
    }

    static let doneStatuses: Set<String> = ["complete", "invoiced", "paid"]

    static let pipelineStatuses: Set<String> = [
        "lead", "estimate_sent", "approved", "scheduled", "in_progress", "complete",
    ]

    static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    static func monthLabel(_ month: Int) -> String {
        (0..<12).contains(month) ? monthNames[month] : ""
    }

    // MARK: invoiceStats

    /// `daysPastDue` — local-frame day count, DST-safe (round, not floor).
    static func daysPastDue(_ dueDate: String, now: Date) -> Int {
        guard let due = NativeCashBasis.parseLocalDate(dueDate) else { return 0 }
        let calendar = NativeCashBasis.localCalendar
        let dueMidnight = calendar.startOfDay(for: due)
        let nowMidnight = calendar.startOfDay(for: now)
        return Int((nowMidnight.timeIntervalSince(dueMidnight) / 86_400).rounded())
    }

    static func isOverdue(_ invoice: Canonical.Invoice, now: Date) -> Bool {
        let ledger = NativeCashBasis.ledgerInvoice(invoice)
        guard !PaymentLedger.isFullyPaid(ledger) else { return false }
        return daysPastDue(invoice.due, now: now) > 0
    }

    /// `summarizeInvoices` — partly-paid invoices count in BOTH collected and
    /// outstanding.
    static func summarizeInvoices(_ invoices: [Canonical.Invoice], now: Date) -> NativeMoneyInvoiceSummary {
        var outstanding = Decimal.zero
        var overdueCount = 0
        var collected = Decimal.zero
        for invoice in invoices {
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            collected += PaymentLedger.amountPaid(ledger)
            outstanding += PaymentLedger.balanceDue(ledger)
            if isOverdue(invoice, now: now) { overdueCount += 1 }
        }
        return NativeMoneyInvoiceSummary(outstanding: outstanding, overdueCount: overdueCount, collected: collected)
    }

    // MARK: invoiceAging

    /// `computeInvoiceAging` — face value, not collected; fully-paid only.
    static func computeInvoiceAging(_ invoices: [Canonical.Invoice]) -> NativeInvoiceAging {
        var byCustomer: [String: (totalDays: Int, count: Int, totalAmount: Decimal)] = [:]
        var order: [String] = []
        var totalDays = 0
        var paidCount = 0

        for invoice in invoices {
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            guard PaymentLedger.isFullyPaid(ledger),
                  let paidAt = invoice.paidAt, !invoice.due.isEmpty,
                  let dueDate = NativeCashBasis.parseLocalDate(invoice.due),
                  let paidDate = NativeCashBasis.parseLocalDate(paidAt)
            else { continue }

            let days = roundInt(paidDate.timeIntervalSince(dueDate) / 86_400)
            totalDays += days
            paidCount += 1

            let name = invoice.customer.isEmpty ? "Unknown" : invoice.customer
            if var entry = byCustomer[name] {
                entry.totalDays += days
                entry.count += 1
                entry.totalAmount += invoice.amount
                byCustomer[name] = entry
            } else {
                byCustomer[name] = (days, 1, invoice.amount)
                order.append(name)
            }
        }

        var customers: [NativeCustomerPaySpeed] = order.map { name in
            let entry = byCustomer[name]!
            return NativeCustomerPaySpeed(
                name: name,
                avgDays: roundInt(Double(entry.totalDays) / Double(entry.count)),
                invoiceCount: entry.count,
                totalAmount: entry.totalAmount
            )
        }
        // `customers.sort((a, b) => b.avgDays - a.avgDays)` — JS Array.sort is
        // stable, so equal avgDays keep first-seen order.
        customers = customers.enumerated().sorted { lhs, rhs in
            lhs.element.avgDays == rhs.element.avgDays
                ? lhs.offset < rhs.offset
                : lhs.element.avgDays > rhs.element.avgDays
        }.map(\.element)

        return NativeInvoiceAging(
            avgDays: paidCount > 0 ? roundInt(Double(totalDays) / Double(paidCount)) : 0,
            paidCount: paidCount,
            customers: customers
        )
    }

    // MARK: customerMix

    static func computeCustomerMix(
        _ invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> NativeCustomerMix {
        var firstInvoiceDate: [String: Date] = [:]
        for invoice in invoices {
            guard !invoice.due.isEmpty else { continue }
            let name = invoice.customer.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            guard let date = NativeCashBasis.parseLocalDate(invoice.due) else { continue }
            if let existing = firstInvoiceDate[name], existing <= date { continue }
            firstInvoiceDate[name] = date
        }

        var revenueByCustomer: [String: Decimal] = [:]
        var order: [String] = []
        for invoice in invoices {
            let name = invoice.customer.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            let collected = NativeCashBasis.collected(invoices: [invoice], start: start, end: end)
            if collected == 0 { continue }
            if revenueByCustomer[name] == nil { order.append(name) }
            revenueByCustomer[name, default: 0] += collected
        }

        var newCount = 0
        var newRevenue = Decimal.zero
        var returningCount = 0
        var returningRevenue = Decimal.zero
        for name in order {
            guard let first = firstInvoiceDate[name], let revenue = revenueByCustomer[name] else { continue }
            if first >= start && first <= end {
                newCount += 1
                newRevenue += revenue
            } else {
                returningCount += 1
                returningRevenue += revenue
            }
        }
        return NativeCustomerMix(
            newCount: newCount,
            newRevenue: newRevenue,
            returningCount: returningCount,
            returningRevenue: returningRevenue
        )
    }

    // MARK: seasonalTrends

    static func computeSeasonalTrends(_ invoices: [Canonical.Invoice], now: Date) -> NativeSeasonalTrends {
        let (nowYear, nowMonth, _) = NativeCashBasis.localComponents(now)
        var windows: [NativeDateRange] = []
        var meta: [(year: Int, month: Int)] = []
        for offset in stride(from: 11, through: 0, by: -1) {
            let anchor = NativeCashBasis.localDate(year: nowYear, month: nowMonth - offset, day: 1)
            let (year, month, _) = NativeCashBasis.localComponents(anchor)
            meta.append((year, month))
            windows.append(NativeDateRange(
                start: NativeCashBasis.localDate(year: year, month: month, day: 1),
                end: NativeCashBasis.localDate(year: year, month: month + 1, day: 0)
            ))
            windows.append(NativeDateRange(
                start: NativeCashBasis.localDate(year: year - 1, month: month, day: 1),
                end: NativeCashBasis.localDate(year: year - 1, month: month + 1, day: 0)
            ))
        }

        let totals = NativeCashBasis.collectedByPeriod(invoices: invoices, ranges: windows)
        var months: [NativeMonthlyTrend] = []
        var thisYearTotal = Decimal.zero
        var lastYearTotal = Decimal.zero
        for (index, entry) in meta.enumerated() {
            let thisYear = totals[2 * index]
            let lastYear = totals[2 * index + 1]
            thisYearTotal += thisYear
            lastYearTotal += lastYear
            months.append(NativeMonthlyTrend(
                label: monthLabel(entry.month),
                month: entry.month,
                year: entry.year,
                thisYear: thisYear,
                lastYear: lastYear
            ))
        }
        let yoyChangePct = lastYearTotal > 0
            ? jsRound((thisYearTotal - lastYearTotal) / lastYearTotal * 100)
            : nil
        return NativeSeasonalTrends(
            months: months,
            thisYearTotal: thisYearTotal,
            lastYearTotal: lastYearTotal,
            yoyChangePct: yoyChangePct
        )
    }

    // MARK: expenseTrends

    /// `expensesInMonth` — RN buckets by `new Date(exp.date)` (UTC midnight) then
    /// reads LOCAL year/month, so a date-only expense can fall in the prior local
    /// month west of UTC. Reproduced exactly.
    static func utcParsedLocalMonth(_ dateString: String) -> (year: Int, month: Int)? {
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        let (year, month, _) = NativeCashBasis.localComponents(date)
        return (year, month)
    }

    static func computeExpenseTrends(_ expenses: [Canonical.Expense], now: Date) -> NativeExpenseTrends {
        let (nowYear, nowMonth, _) = NativeCashBasis.localComponents(now)
        var months: [NativeMonthlyExpense] = []
        var trailingTotal = Decimal.zero

        for offset in stride(from: 11, through: 0, by: -1) {
            let anchor = NativeCashBasis.localDate(year: nowYear, month: nowMonth - offset, day: 1)
            let (year, month, _) = NativeCashBasis.localComponents(anchor)
            var total = Decimal.zero
            for expense in expenses where !expense.date.isEmpty {
                guard let parsed = utcParsedLocalMonth(expense.date) else { continue }
                if parsed.year == year && parsed.month == month { total += expense.amount }
            }
            trailingTotal += total
            months.append(NativeMonthlyExpense(
                label: monthLabel(month), month: month, year: year, total: total, momChangePct: nil
            ))
        }

        for index in 1..<months.count {
            let prior = months[index - 1].total
            if prior > 0 {
                months[index].momChangePct = jsRound((months[index].total - prior) / prior * 100)
            }
        }

        let oldest = months[0].total
        let newest = months[months.count - 1].total
        let overallTrend = oldest > 0 ? jsRound((newest - oldest) / oldest * 100) : nil

        return NativeExpenseTrends(
            months: months,
            trailingTotal: trailingTotal,
            avgMonthly: jsRound(trailingTotal / 12),
            overallTrend: overallTrend
        )
    }
}
