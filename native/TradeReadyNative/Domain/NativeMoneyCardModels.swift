import Foundation

// MARK: - Money card presentation models (task 9.09, requirements M1, M2, T2)
//
// Port of the Money screen's card layer (`screens/MoneyScreen.tsx` and
// `components/money/*`). Every figure comes from the 9.01 report engine, the
// 9.02 tax engine, or the 9.03 mileage module; this file owns only the
// *presentation* rules RN bakes into its components — the visibility gates, the
// change/percentage math, the sort and slice limits, the singular/plural copy,
// and the semantic colors.
//
// Deliberately free of SwiftUI so the rules stay host-testable.

/// Semantic color a card figure asks for; views map it onto the app palette.
enum NativeMoneyCardTone: Equatable {
    case accent, success, warning, danger, neutral, muted

    /// The tone RN gives a delta arrow: green when the change is *good*.
    static func delta(_ value: Int, inverse: Bool = false) -> NativeMoneyCardTone {
        let isUp = value > 0
        return (inverse ? !isUp : isUp) ? .success : .danger
    }
}

/// `utils/format.ts` plus the rounding helpers the cards use.
enum NativeMoneyFormat {
    /// `formatMoney` — always two decimals ("$2,400.00", "-$500.00").
    static func money(_ value: Decimal) -> String { NativeJobProfitability.money(value) }
    /// `formatQuote`: whole dollars, or a full cent pair ("$2,499", "$87.50").
    static func quote(_ value: Decimal) -> String { NativeJobProfitability.quote(value) }

    /// `Math.round(n)` over JS double semantics.
    static func round(_ value: Double) -> Int { Int(value.rounded()) }

    /// `changePct` from SummaryCard: `null` with no comparable window or a zero
    /// previous value, otherwise a whole percentage of `|prev|`.
    static func changePercent(current: Decimal, previous: Decimal?) -> Int? {
        guard let previous, previous != 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: current - previous).doubleValue
            / abs(NSDecimalNumber(decimal: previous).doubleValue)
        return round(ratio * 100)
    }

    /// `Math.round(fraction * 100)` for a 0…1 ratio.
    static func percentInt(_ fraction: Decimal) -> Int {
        round(NSDecimalNumber(decimal: fraction).doubleValue * 100)
    }

    /// `(part / whole) * 100` clamped to 0…100 for a progress fill.
    static func clampedPercent(part: Decimal, whole: Decimal) -> Double {
        guard whole > 0 else { return 0 }
        let raw = NSDecimalNumber(decimal: part).doubleValue
            / NSDecimalNumber(decimal: whole).doubleValue * 100
        return min(100, max(0, raw))
    }

    /// `formatMiles` ("12.4 mi").
    static func miles(_ value: Decimal) -> String { NativeMileage.formatMiles(value) }

    /// `N trip`/`N trips`, `N service`/`N services`, `N categor(y|ies)`.
    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

/// `DATE_FILTERS` (`utils/moneyUtils.ts`), in RN's order.
enum NativeMoneyDateFilter: String, CaseIterable, Identifiable {
    case thisMonth = "this_month"
    case lastMonth = "last_month"
    case thisYear = "this_year"
    case allTime = "all_time"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMonth: "This Month"
        case .lastMonth: "Last Month"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        }
    }
}

/// The Money screen's segmented control.
enum NativeMoneyTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case expenses = "Expenses"

    var id: String { rawValue }
}

// MARK: - Summary (SummaryCard)

/// `SummaryCard` — income/expenses/net profit for the active filter, with the
/// previous-window comparison and the margin bar.
struct NativeMoneySummaryCard: Equatable {
    var periodLabel: String
    var income: Decimal
    var expenses: Decimal
    var netProfit: Decimal
    var incomeChangePercent: Int?
    var expensesChangePercent: Int?
    var netProfitChangePercent: Int?
    /// Present only when `income > 0` (RN hides the whole margin block otherwise).
    var marginPercent: Int?
    var marginFraction: Double

    var isProfitable: Bool { netProfit >= 0 }
    var netProfitTone: NativeMoneyCardTone { isProfitable ? .success : .danger }

    static func make(
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        start: Date,
        end: Date,
        previousRange: NativeDateRange?,
        label: String
    ) -> NativeMoneySummaryCard {
        let income = NativeCashBasis.collected(invoices: invoices, start: start, end: end)
        let expenseTotal = Self.expenseTotal(expenses, start: start, end: end)
        let profit = income - expenseTotal

        var previousIncome: Decimal?
        var previousProfit: Decimal?
        var previousExpenses: Decimal?
        if let previousRange {
            previousIncome = NativeCashBasis.collected(
                invoices: invoices, start: previousRange.start, end: previousRange.end
            )
            previousExpenses = Self.expenseTotal(
                expenses, start: previousRange.start, end: previousRange.end
            )
            if let previousIncome, let previousExpenses {
                previousProfit = previousIncome - previousExpenses
            }
        }

        let margin = income > 0 ? NativeMoneyFormat.clampedPercent(part: profit, whole: income) : nil
        return NativeMoneySummaryCard(
            periodLabel: label,
            income: income,
            expenses: expenseTotal,
            netProfit: profit,
            incomeChangePercent: NativeMoneyFormat.changePercent(current: income, previous: previousIncome),
            expensesChangePercent: NativeMoneyFormat.changePercent(
                current: expenseTotal, previous: previousExpenses
            ),
            netProfitChangePercent: NativeMoneyFormat.changePercent(
                current: profit, previous: previousProfit
            ),
            marginPercent: margin.map { NativeMoneyFormat.round($0) },
            marginFraction: margin ?? 0
        )
    }

    /// `filteredExpenses.reduce((sum, exp) => sum + (exp.amount || 0), 0)` —
    /// only expenses with an in-range date contribute.
    static func expenseTotal(_ expenses: [Canonical.Expense], start: Date, end: Date) -> Decimal {
        expenses.reduce(Decimal.zero) { total, expense in
            NativeCashBasis.isInRange(expense.date, start: start, end: end)
                ? total + expense.amount
                : total
        }
    }
}

// MARK: - Monthly chart (MonthlyChart)

struct NativeMoneyMonthlyChartRow: Equatable {
    var label: String
    var year: Int
    var month: Int
    var income: Decimal
    var expenses: Decimal

    /// Bar height as a fraction of the chart max (`height / BAR_MAX_HEIGHT`).
    func incomeFraction(max: Decimal) -> Double {
        max > 0 ? NSDecimalNumber(decimal: income).doubleValue / NSDecimalNumber(decimal: max).doubleValue : 0
    }

    func expenseFraction(max: Decimal) -> Double {
        max > 0 ? NSDecimalNumber(decimal: expenses).doubleValue / NSDecimalNumber(decimal: max).doubleValue : 0
    }
}

/// `MonthlyChart` — the last six calendar months, income (cash basis) against
/// expenses bucketed by the expense's own local month.
struct NativeMoneyMonthlyChartCard: Equatable {
    var rows: [NativeMoneyMonthlyChartRow]
    /// `Math.max(...values, 1)`.
    var maxValue: Decimal

    var isEmpty: Bool { rows.allSatisfy { $0.income == 0 && $0.expenses == 0 } }

    static func make(
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        now: Date
    ) -> NativeMoneyMonthlyChartCard {
        let months = NativeCashBasis.last6MonthLabels(now: now)
        let ranges = months.map {
            NativeDateRange(
                start: NativeCashBasis.localDate(year: $0.year, month: $0.month, day: 1),
                end: NativeCashBasis.localDate(year: $0.year, month: $0.month + 1, day: 0)
            )
        }
        let income = NativeCashBasis.collectedByPeriod(invoices: invoices, ranges: ranges)
        let rows = months.enumerated().map { index, month -> NativeMoneyMonthlyChartRow in
            let monthExpenses = expenses.reduce(Decimal.zero) { total, expense in
                guard let date = NativeCashBasis.parseLocalDate(expense.date) else { return total }
                let (year, monthIndex, _) = NativeCashBasis.localComponents(date)
                guard year == month.year, monthIndex == month.month else { return total }
                return total + expense.amount
            }
            return NativeMoneyMonthlyChartRow(
                label: month.label, year: month.year, month: month.month,
                income: income[index], expenses: monthExpenses
            )
        }
        let maxValue = rows.reduce(Decimal(1)) { current, row in
            max(current, max(row.income, row.expenses))
        }
        return NativeMoneyMonthlyChartCard(rows: rows, maxValue: maxValue)
    }
}

// MARK: - Expenses by category (MoneyScreen's ExpenseCategoryCard)

struct NativeMoneyExpenseCategoryRow: Equatable {
    var id: String
    var label: String
    var total: Decimal
    /// `(total / filteredTotal) * 100` — the progress fill width.
    var fraction: Double
}

/// `ExpenseCategoryCard` — hidden entirely when the window has no expenses.
struct NativeMoneyExpenseCategoryCard: Equatable {
    var total: Decimal
    var rows: [NativeMoneyExpenseCategoryRow]

    static func make(
        expenses: [Canonical.Expense],
        start: Date,
        end: Date
    ) -> NativeMoneyExpenseCategoryCard? {
        let filtered = expenses.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }
        let total = filtered.reduce(Decimal.zero) { $0 + $1.amount }
        let rows = NativeExpenseCategories.all.compactMap { category -> NativeMoneyExpenseCategoryRow? in
            let subtotal = filtered
                .filter { $0.category == category.id }
                .reduce(Decimal.zero) { $0 + $1.amount }
            guard subtotal > 0 else { return nil }
            return NativeMoneyExpenseCategoryRow(
                id: category.id,
                label: category.label,
                total: subtotal,
                fraction: NativeMoneyFormat.clampedPercent(part: subtotal, whole: total)
            )
        }
        // `sort((a, b) => b.total - a.total)` over a stable sort: equal totals
        // keep the canonical category order.
        let sorted = rows.enumerated().sorted { lhs, rhs in
            lhs.element.total == rhs.element.total
                ? lhs.offset < rhs.offset
                : lhs.element.total > rhs.element.total
        }.map(\.element)
        guard !sorted.isEmpty else { return nil }
        return NativeMoneyExpenseCategoryCard(total: total, rows: sorted)
    }
}

// MARK: - Seasonal trends (SeasonalTrendsCard)

/// `12-Month Trend` — this year vs last year by month, hidden until one of the
/// two years has collected anything.
struct NativeMoneySeasonalCard: Equatable {
    var trends: NativeSeasonalTrends
    var maxValue: Decimal
    var yoyBadge: String?
    var yoyTone: NativeMoneyCardTone?

    static func make(invoices: [Canonical.Invoice], now: Date) -> NativeMoneySeasonalCard {
        let trends = NativeMoneyReports.computeSeasonalTrends(invoices, now: now)
        let maxValue = trends.months.reduce(Decimal(1)) {
            max($0, max($1.thisYear, $1.lastYear))
        }
        let change = trends.yoyChangePct
        let badge = (change == nil || change == 0) ? nil
            : "\((change ?? 0) > 0 ? "↑" : "↓") \(abs(change ?? 0))% YoY"
        return NativeMoneySeasonalCard(
            trends: trends,
            maxValue: maxValue,
            yoyBadge: badge,
            yoyTone: badge == nil ? nil : ((change ?? 0) > 0 ? .success : .danger)
        )
    }

    var showsCard: Bool { trends.thisYearTotal > 0 || trends.lastYearTotal > 0 }
}

// MARK: - Expense trends (ExpenseTrendsCard)

/// `Expense Trends` — 12-month trailing spend, hidden until anything was spent.
struct NativeMoneyExpenseTrendsCard: Equatable {
    var trends: NativeExpenseTrends
    var maxValue: Decimal
    var trendBadge: String?
    var trendTone: NativeMoneyCardTone?
    /// Per-month month-over-month badge ("↓12"), blank when absent/zero.
    var monthChangeLabels: [String]

    var showsCard: Bool { trends.trailingTotal != 0 }

    static func make(expenses: [Canonical.Expense], now: Date) -> NativeMoneyExpenseTrendsCard {
        let trends = NativeMoneyReports.computeExpenseTrends(expenses, now: now)
        let maxValue = trends.months.reduce(Decimal(1)) { max($0, $1.total) }
        let overall = trends.overallTrend
        let badge = (overall == nil || overall == 0) ? nil
            : "\((overall ?? 0) < 0 ? "↓" : "↑") \(abs(overall ?? 0))%"
        return NativeMoneyExpenseTrendsCard(
            trends: trends,
            maxValue: maxValue,
            trendBadge: badge,
            // Cheaper months are good news, so a decline is green.
            trendTone: badge == nil ? nil : ((overall ?? 0) < 0 ? .success : .danger),
            monthChangeLabels: trends.months.map { month in
                guard let mom = month.momChangePct, mom != 0 else { return "" }
                return "\(mom < 0 ? "↓" : "↑")\(abs(mom))"
            }
        )
    }

    func monthChangeTone(_ index: Int) -> NativeMoneyCardTone {
        guard trends.months.indices.contains(index),
              let mom = trends.months[index].momChangePct, mom != 0
        else { return .muted }
        return mom < 0 ? .success : .danger
    }
}

// MARK: - Top customers (TopCustomersCard)

struct NativeMoneyTopCustomerRow: Equatable {
    var rank: Int
    var name: String
    var amount: Decimal
    /// `amount / topAmount * 100` — the leader always fills the track.
    var fraction: Double
}

/// `Top Customers` — collected revenue per customer in the window, hidden when
/// nothing was collected.
struct NativeMoneyTopCustomersCard: Equatable {
    var rows: [NativeMoneyTopCustomerRow]

    static func make(
        invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> NativeMoneyTopCustomersCard? {
        let top = NativeMoneyReports.topCustomers(invoices, start: start, end: end)
        guard let leader = top.first, leader.amount > 0 else { return nil }
        let rows = top.enumerated().map { index, row in
            NativeMoneyTopCustomerRow(
                rank: index + 1,
                name: row.name,
                amount: row.amount,
                fraction: NativeMoneyFormat.clampedPercent(part: row.amount, whole: leader.amount)
            )
        }
        return NativeMoneyTopCustomersCard(rows: rows)
    }
}

// MARK: - Customer mix (CustomerMixCard)

/// `Customer Mix` — new vs returning revenue in the window, hidden when the
/// window has no invoiced customers at all.
struct NativeMoneyCustomerMixCard: Equatable {
    var mix: NativeCustomerMix
    var newPercent: Int
    var returningPercent: Int
    var totalRevenue: Decimal

    var newCount: Int { mix.newCount }
    var returningCount: Int { mix.returningCount }

    static func make(
        invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> NativeMoneyCustomerMixCard? {
        let mix = NativeMoneyReports.computeCustomerMix(invoices, start: start, end: end)
        guard mix.newCount + mix.returningCount > 0 else { return nil }
        let totalRevenue = mix.newRevenue + mix.returningRevenue
        let newPercent = totalRevenue > 0
            ? NativeMoneyFormat.round(
                NSDecimalNumber(decimal: mix.newRevenue).doubleValue
                    / NSDecimalNumber(decimal: totalRevenue).doubleValue * 100
            )
            : 0
        return NativeMoneyCustomerMixCard(
            mix: mix,
            newPercent: newPercent,
            returningPercent: totalRevenue > 0 ? 100 - newPercent : 0,
            totalRevenue: totalRevenue
        )
    }
}

// MARK: - Days to pay (InvoiceAgingCard)

struct NativeMoneySlowPayerRow: Equatable {
    var name: String
    var invoiceCount: Int
    var totalAmount: Decimal
    var averageDays: Int
    var tone: NativeMoneyCardTone
}

/// `Days to Pay` — average days from due date to payment across *paid* invoices.
struct NativeMoneyInvoiceAgingCard: Equatable {
    var aging: NativeInvoiceAging
    var slowPayers: [NativeMoneySlowPayerRow]
    var daysLabel: String
    var daysTone: NativeMoneyCardTone

    var showsCard: Bool { aging.paidCount > 0 }
    var averageSummary: String {
        "avg across \(NativeMoneyFormat.plural(aging.paidCount, "invoice", "invoices"))"
    }

    static func make(invoices: [Canonical.Invoice]) -> NativeMoneyInvoiceAgingCard {
        let aging = NativeMoneyReports.computeInvoiceAging(invoices)
        let slow = aging.customers.filter { $0.avgDays > 0 }.prefix(3).map {
            NativeMoneySlowPayerRow(
                name: $0.name,
                invoiceCount: $0.invoiceCount,
                totalAmount: $0.totalAmount,
                averageDays: $0.avgDays,
                tone: tone(forDays: $0.avgDays)
            )
        }
        return NativeMoneyInvoiceAgingCard(
            aging: aging,
            slowPayers: Array(slow),
            daysLabel: label(forDays: aging.avgDays),
            daysTone: tone(forDays: aging.avgDays)
        )
    }

    /// `daysLabel` — early / on time / late.
    static func label(forDays days: Int) -> String {
        if days < 0 { return "\(abs(days))d early" }
        if days == 0 { return "On time" }
        return "\(days)d late"
    }

    /// `daysColor` — ≤0 green, ≤14 accent, ≤30 warning, else danger.
    static func tone(forDays days: Int) -> NativeMoneyCardTone {
        if days <= 0 { return .success }
        if days <= 14 { return .accent }
        if days <= 30 { return .warning }
        return .danger
    }
}

// MARK: - Receivables (ReceivablesCard)

/// `Money owed to you` — open balances and open pipeline value, hidden when
/// there is neither.
struct NativeMoneyReceivablesCard: Equatable {
    var receivables: NativeReceivables

    var showsCard: Bool { receivables.outstanding != 0 || receivables.pipelineValue != 0 }
    var overdueTone: NativeMoneyCardTone { receivables.overdueCount > 0 ? .danger : .muted }
    var outstandingCountLabel: String {
        NativeMoneyFormat.plural(receivables.unpaidCount, "invoice", "invoices")
    }
    var overdueCountLabel: String {
        NativeMoneyFormat.plural(receivables.overdueCount, "invoice", "invoices")
    }
    var pipelineCountLabel: String {
        NativeMoneyFormat.plural(receivables.pipelineCount, "job", "jobs")
    }

    static func make(
        invoices: [Canonical.Invoice],
        jobs: [Canonical.Job],
        now: Date
    ) -> NativeMoneyReceivablesCard {
        NativeMoneyReceivablesCard(
            receivables: NativeMoneyReports.receivables(invoices, jobs: jobs, now: now)
        )
    }
}

// MARK: - Conversion funnel (ConversionFunnelCard)

struct NativeMoneyFunnelStageRow: Equatable {
    var status: String
    var label: String
    var count: Int
    /// The connector line above this stage ("↓ 50% from Lead"); nil for the top
    /// stage or when the previous stage's rate is unknown.
    var connector: String?
    /// `max(count / maxCount * 100, 6)`.
    var barPercent: Double
}

/// `Job Pipeline` — status funnel over ALL jobs (never the screen filter).
struct NativeMoneyConversionFunnelCard: Equatable {
    var funnel: NativeConversionFunnel
    var stages: [NativeMoneyFunnelStageRow]
    var winRateBadge: String?

    var showsCard: Bool { funnel.totalJobs > 0 }

    static func make(jobs: [Canonical.Job]) -> NativeMoneyConversionFunnelCard {
        let funnel = NativeMoneyReports.computeConversionFunnel(jobs)
        let maxCount = funnel.stages.first?.count ?? 0
        let stages = funnel.stages.enumerated().map { index, stage in
            let percent = maxCount > 0
                ? max(Double(stage.count) / Double(maxCount) * 100, 6)
                : 6
            var connector: String?
            if index > 0, let rate = stage.rate {
                connector = "↓ \(NativeMoneyFormat.percentInt(rate))% from \(funnel.stages[index - 1].label)"
            }
            return NativeMoneyFunnelStageRow(
                status: stage.status, label: stage.label, count: stage.count,
                connector: connector, barPercent: percent
            )
        }
        return NativeMoneyConversionFunnelCard(
            funnel: funnel,
            stages: stages,
            winRateBadge: funnel.winRate.map { "\(NativeMoneyFormat.percentInt($0))% win rate" }
        )
    }
}

// MARK: - Revenue forecast (RevenueForecastCard)

/// `Revenue Forecast` — likely + speculative pipeline, hidden at zero.
struct NativeMoneyRevenueForecastCard: Equatable {
    var forecast: NativeRevenueForecast
    var winRateBadge: String?
    var winRateTone: NativeMoneyCardTone?
    var winRatePercent: Int?
    /// Share of the forecast that is already won ("Likely").
    var likelyFraction: Double
    var projectedCountLabel: String

    var showsCard: Bool { forecast.totalForecast != 0 }

    static func make(jobs: [Canonical.Job]) -> NativeMoneyRevenueForecastCard {
        let forecast = NativeMoneyReports.computeRevenueForecast(jobs)
        let winRatePercent = forecast.winRate.map { NativeMoneyFormat.percentInt($0) }
        let projectedCountLabel: String = {
            let count = NativeMoneyFormat.plural(forecast.speculativeCount, "job", "jobs")
            guard let winRatePercent else { return "\(count) (no win rate)" }
            return "\(count) at \(winRatePercent)%"
        }()
        return NativeMoneyRevenueForecastCard(
            forecast: forecast,
            winRateBadge: winRatePercent.map { "\($0)% win rate" },
            winRateTone: winRatePercent.map { $0 > 50 ? .success : .warning },
            winRatePercent: winRatePercent,
            likelyFraction: forecast.totalForecast > 0
                ? NativeMoneyFormat.clampedPercent(part: forecast.certainValue, whole: forecast.totalForecast)
                : 0,
            projectedCountLabel: projectedCountLabel
        )
    }

    var certainCountLabel: String {
        "\(NativeMoneyFormat.plural(forecast.certainCount, "job", "jobs")) at 100%"
    }
}

// MARK: - Avg job value (AvgJobValueCard)

/// `Avg Job Value` — the window's average, falling back to all time when the
/// window has no completed jobs. Hidden when there are none anywhere.
struct NativeMoneyAvgJobValueCard: Equatable {
    var current: NativeAvgJobValue
    var allTime: NativeAvgJobValue
    var heroValue: Decimal
    var heroCount: Int
    var totalValue: Decimal
    var changePercent: Int?
    var changeTone: NativeMoneyCardTone?
    var showsAllTimeNote: Bool

    var showsCard: Bool { allTime.count > 0 }
    var completedLabel: String { "\(heroCount) jobs" }

    static func make(
        jobs: [Canonical.Job],
        start: Date?,
        end: Date?,
        previousRange: NativeDateRange?
    ) -> NativeMoneyAvgJobValueCard {
        let current = NativeMoneyReports.computeAvgJobValue(jobs, start: start, end: end)
        let allTime = NativeMoneyReports.computeAvgJobValue(jobs)
        let previous = previousRange.map {
            NativeMoneyReports.computeAvgJobValue(jobs, start: $0.start, end: $0.end)
        }
        let change: Int? = {
            guard let previous, previous.avgValue > 0 else { return nil }
            return NativeMoneyFormat.changePercent(current: current.avgValue, previous: previous.avgValue)
        }()
        let showsAllTime = current.count == 0 && allTime.count > 0
        return NativeMoneyAvgJobValueCard(
            current: current,
            allTime: allTime,
            heroValue: current.count > 0 ? current.avgValue : allTime.avgValue,
            heroCount: current.count > 0 ? current.count : allTime.count,
            totalValue: current.count > 0 ? current.totalValue : allTime.totalValue,
            changePercent: change,
            changeTone: (change == nil || change == 0) ? nil : ((change ?? 0) > 0 ? .success : .danger),
            showsAllTimeNote: showsAllTime
        )
    }
}

// MARK: - Revenue by type (RevenueByTypeCard)

struct NativeMoneyRevenueComponentRow: Equatable {
    var label: String
    var total: Decimal
    var percent: Int
    var tone: NativeMoneyCardTone
}

/// `Revenue Breakdown` — labor / materials / overhead split of completed work.
struct NativeMoneyRevenueByTypeCard: Equatable {
    var totalRevenue: Decimal
    var jobCount: Int
    var components: [NativeMoneyRevenueComponentRow]
    var subtitle: String

    var showsCard: Bool { jobCount > 0 }

    static func make(jobs: [Canonical.Job]) -> NativeMoneyRevenueByTypeCard {
        let data = NativeMoneyReports.computeRevenueByType(jobs)
        let components = data.components.map { component in
            NativeMoneyRevenueComponentRow(
                label: component.label,
                total: component.total,
                percent: component.pct,
                tone: Self.tone(forKey: component.color)
            )
        }
        return NativeMoneyRevenueByTypeCard(
            totalRevenue: data.totalRevenue,
            jobCount: data.jobCount,
            components: components,
            subtitle: "\(NativeMoneyFormat.money(data.totalRevenue)) from "
                + NativeMoneyFormat.plural(data.jobCount, "completed job", "completed jobs")
        )
    }

    /// RN reads the component's `color` straight out of the theme.
    static func tone(forKey key: String) -> NativeMoneyCardTone {
        switch key {
        case "accent": .accent
        case "success": .success
        case "warning": .warning
        case "danger": .danger
        default: .neutral
        }
    }
}

// MARK: - Job profitability (JobProfitabilityCard)

struct NativeMoneyProfitabilityRow: Equatable {
    var key: String
    var label: String
    var value: String
}

/// `Job Profitability` — medians across completed jobs that carry tracked data.
/// `buildHistorySummaryRows` from `utils/profitabilityDisplay.ts`.
struct NativeMoneyJobProfitabilityCard: Equatable {
    var history: NativeProfitabilityHistory
    var rows: [NativeMoneyProfitabilityRow]
    var coverageLabel: String
    var emptyCopy: String?

    var showsCard: Bool { history.doneJobs > 0 }

    static let emptyText = "Track hours and link expenses on jobs to see how your "
        + "estimates hold up in reality."

    static func make(
        jobs: [Canonical.Job],
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        laborCostRate: Decimal?
    ) -> NativeMoneyJobProfitabilityCard {
        let history = NativeMoneyReports.computeProfitabilityHistory(
            jobs: jobs, invoices: invoices, expenses: expenses, laborCostRate: laborCostRate
        )
        let rows = buildRows(history)
        return NativeMoneyJobProfitabilityCard(
            history: history,
            rows: rows,
            coverageLabel: "\(history.jobsWithData) of "
                + NativeMoneyFormat.plural(history.doneJobs, "completed job", "completed jobs")
                + " have tracked data",
            emptyCopy: rows.isEmpty ? emptyText : nil
        )
    }

    /// `buildHistorySummaryRows` — never a fake zero: a row exists only when the
    /// corresponding median is known.
    static func buildRows(_ history: NativeProfitabilityHistory) -> [NativeMoneyProfitabilityRow] {
        var rows: [NativeMoneyProfitabilityRow] = []
        if history.laborCount > 0, let overrun = history.medianLaborOverrunHours {
            let value = overrun == 0
                ? "on estimate"
                : overrun > 0
                    ? "+\(NativeJobProfitability.laborHint(overrun)) over"
                    : "\(NativeJobProfitability.laborHint(-overrun)) under"
            rows.append(.init(key: "labor", label: "Typical labor vs estimate", value: value))
        }
        if history.materialsCount > 0, let variance = history.medianMaterialsVariance {
            let value = variance == 0
                ? "on estimate"
                : variance > 0
                    ? "+\(NativeMoneyFormat.money(variance)) over"
                    : "\(NativeMoneyFormat.money(-variance)) under"
            rows.append(.init(key: "materials", label: "Typical materials vs estimate", value: value))
        }
        if history.hourlyCount > 0, let hourly = history.medianEffectiveHourly {
            rows.append(.init(
                key: "hourly",
                label: "Typical earned per hour",
                value: "\(NativeMoneyFormat.money(hourly))/hr"
            ))
        }
        return rows
    }
}

// MARK: - Mileage (MileageCard)

/// `Mileage deduction` — the window's trips at the settings rate. The card body
/// stays useful before 9.11 wires the log screen.
struct NativeMoneyMileageCard: Equatable {
    var summary: NativeMileageSummary
    var rate: Decimal
    var deductionText: String
    var subtitle: String

    static func make(
        trips: [Canonical.Trip],
        start: Date,
        end: Date,
        rate: Decimal
    ) -> NativeMoneyMileageCard {
        let summary = NativeMileage.summary(trips: trips, start: start, end: end, rate: rate)
        let tripLabel = NativeMoneyFormat.plural(summary.tripCount, "trip", "trips")
        return NativeMoneyMileageCard(
            summary: summary,
            rate: rate,
            deductionText: NativeMoneyFormat.money(summary.deduction),
            subtitle: "\(NativeMoneyFormat.miles(summary.totalMiles)) · \(tripLabel) · "
                + "\(NativeMoneyFormat.money(rate))/mi"
        )
    }
}

// MARK: - Tax set-aside (TaxSetAsideCard)

/// `Tax set-aside` — deliberately independent of the screen's date filter: its
/// windows are the IRS payment periods plus calendar YTD, and the card body
/// states its own range.
struct NativeMoneyTaxCard: Equatable {
    var breakdown: NativeTaxBreakdown
    var reserveText: String
    var ytdLabel: String

    static func make(
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        trips: [Canonical.Trip],
        values: NativeTaxSettingsValues,
        mileageRate: Decimal,
        now: Date
    ) -> NativeMoneyTaxCard {
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
        let breakdown = NativeTaxBreakdown.make(summary: summary, values: values)
        return NativeMoneyTaxCard(
            breakdown: breakdown,
            reserveText: NativeMoneyFormat.money(breakdown.currentReserve),
            ytdLabel: breakdown.yearToDateText
        )
    }
}

// MARK: - Pricebook (PricebookCard)

/// `Pricebook` — how many services and categories exist. `manageHint` is the RN
/// subtitle tail; views show it only once 9.12 wires the destination.
struct NativeMoneyPricebookCard: Equatable {
    var entryCount: Int
    var categoryCount: Int
    var countText: String
    var categoryText: String

    static let manageHint = " · Tap to manage"

    static func make(entries: [Canonical.PricebookEntry]) -> NativeMoneyPricebookCard {
        let categories = Set(entries.compactMap { entry -> String? in
            guard let category = entry.category, !category.isEmpty else { return nil }
            return category
        })
        return NativeMoneyPricebookCard(
            entryCount: entries.count,
            categoryCount: categories.count,
            countText: NativeMoneyFormat.plural(entries.count, "service", "services"),
            categoryText: categories.isEmpty
                ? "No categories yet"
                : NativeMoneyFormat.plural(categories.count, "category", "categories")
        )
    }
}

// MARK: - Expenses tab (ExpenseRow)

/// One row of the Expenses tab.
struct NativeMoneyExpenseRow: Equatable {
    var id: String
    var merchant: String
    var categoryId: String
    var categoryLabel: String
    /// `new Date(date).toLocaleDateString("en-US", { month: "short", day: "numeric" })`
    var dateText: String
    var amount: Decimal
    var notes: String
    var hasReceipt: Bool
    /// Title of the linked job, resolved by exact id. Native-only row detail
    /// (the RN `ExpenseRow` renders a receipt glyph but no job name).
    var jobTitle: String?
}

/// The Expenses tab's filtered, newest-first list ("the period" the chip names).
enum NativeMoneyExpenseList {
    static func rows(
        expenses: [Canonical.Expense],
        jobs: [Canonical.Job] = [],
        start: Date,
        end: Date,
        calendar: Calendar = NativeCashBasis.localCalendar
    ) -> [NativeMoneyExpenseRow] {
        expenses
            .filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }
            .sorted { lhs, rhs in
                guard let left = NativeCashBasis.parseLocalDate(lhs.date),
                      let right = NativeCashBasis.parseLocalDate(rhs.date)
                else { return lhs.date > rhs.date }
                return left > right
            }
            .map { expense in
                NativeMoneyExpenseRow(
                    id: expense.id,
                    merchant: expense.description,
                    categoryId: expense.category,
                    categoryLabel: NativeExpenseCategories.label(for: expense.category),
                    dateText: shortDate(expense.date, calendar: calendar),
                    amount: expense.amount,
                    notes: expense.notes,
                    hasReceipt: !(expense.receiptUri ?? "").isEmpty,
                    jobTitle: NativeExpenseComposer.jobTitle(id: expense.jobId, in: jobs)
                )
            }
    }

    /// "Sep 10" — the local frame, never the UTC instant.
    static func shortDate(_ dateString: String, calendar: Calendar = NativeCashBasis.localCalendar) -> String {
        guard let date = NativeCashBasis.parseLocalDate(dateString) else { return "" }
        return shortDateFormatter.string(from: date)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

// MARK: - Screen state

/// RN hides the whole analytics stack (and shows the empty state) only when
/// *nothing* exists anywhere — an empty filtered window still renders the
/// summary and lets every card hide itself.
enum NativeMoneyOverviewState: Equatable {
    case trueEmpty
    case content

    static func resolve(
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        jobs: [Canonical.Job]
    ) -> NativeMoneyOverviewState {
        invoices.isEmpty && expenses.isEmpty && jobs.isEmpty ? .trueEmpty : .content
    }
}

// MARK: - Overview composition

/// Every card the Overview tab renders, for one date filter. The view stays a
/// pure layout of this value; all figure/gate/copy decisions live here.
struct NativeMoneyOverview: Equatable {
    var filter: NativeMoneyDateFilter
    var range: NativeDateRange
    var previousRange: NativeDateRange?
    var state: NativeMoneyOverviewState
    var summary: NativeMoneySummaryCard
    var monthlyChart: NativeMoneyMonthlyChartCard
    var expenseCategories: NativeMoneyExpenseCategoryCard?
    var seasonal: NativeMoneySeasonalCard
    var expenseTrends: NativeMoneyExpenseTrendsCard
    var topCustomers: NativeMoneyTopCustomersCard?
    var customerMix: NativeMoneyCustomerMixCard?
    var invoiceAging: NativeMoneyInvoiceAgingCard
    var receivables: NativeMoneyReceivablesCard
    var funnel: NativeMoneyConversionFunnelCard
    var forecast: NativeMoneyRevenueForecastCard
    var avgJobValue: NativeMoneyAvgJobValueCard
    var revenueByType: NativeMoneyRevenueByTypeCard
    var profitability: NativeMoneyJobProfitabilityCard
    var mileage: NativeMoneyMileageCard
    var tax: NativeMoneyTaxCard
    var pricebook: NativeMoneyPricebookCard

    static func make(
        filter: NativeMoneyDateFilter,
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        jobs: [Canonical.Job],
        trips: [Canonical.Trip],
        pricebook: [Canonical.PricebookEntry],
        taxValues: NativeTaxSettingsValues,
        mileageRate: Decimal,
        laborCostRate: Decimal?,
        now: Date
    ) -> NativeMoneyOverview {
        let range = NativeCashBasis.range(for: filter.rawValue, now: now)
        let previous = NativeCashBasis.previousRange(for: filter.rawValue, now: now)
        return NativeMoneyOverview(
            filter: filter,
            range: range,
            previousRange: previous,
            state: NativeMoneyOverviewState.resolve(invoices: invoices, expenses: expenses, jobs: jobs),
            summary: NativeMoneySummaryCard.make(
                invoices: invoices, expenses: expenses, start: range.start, end: range.end,
                previousRange: previous, label: filter.label
            ),
            monthlyChart: NativeMoneyMonthlyChartCard.make(invoices: invoices, expenses: expenses, now: now),
            expenseCategories: NativeMoneyExpenseCategoryCard.make(
                expenses: expenses, start: range.start, end: range.end
            ),
            seasonal: NativeMoneySeasonalCard.make(invoices: invoices, now: now),
            expenseTrends: NativeMoneyExpenseTrendsCard.make(expenses: expenses, now: now),
            topCustomers: NativeMoneyTopCustomersCard.make(
                invoices: invoices, start: range.start, end: range.end
            ),
            customerMix: NativeMoneyCustomerMixCard.make(
                invoices: invoices, start: range.start, end: range.end
            ),
            invoiceAging: NativeMoneyInvoiceAgingCard.make(invoices: invoices),
            receivables: NativeMoneyReceivablesCard.make(invoices: invoices, jobs: jobs, now: now),
            funnel: NativeMoneyConversionFunnelCard.make(jobs: jobs),
            forecast: NativeMoneyRevenueForecastCard.make(jobs: jobs),
            avgJobValue: NativeMoneyAvgJobValueCard.make(
                jobs: jobs, start: range.start, end: range.end, previousRange: previous
            ),
            revenueByType: NativeMoneyRevenueByTypeCard.make(jobs: jobs),
            profitability: NativeMoneyJobProfitabilityCard.make(
                jobs: jobs, invoices: invoices, expenses: expenses, laborCostRate: laborCostRate
            ),
            mileage: NativeMoneyMileageCard.make(
                trips: trips, start: range.start, end: range.end, rate: mileageRate
            ),
            tax: NativeMoneyTaxCard.make(
                invoices: invoices, expenses: expenses, trips: trips,
                values: taxValues, mileageRate: mileageRate, now: now
            ),
            pricebook: NativeMoneyPricebookCard.make(entries: pricebook)
        )
    }
}
