import SwiftUI

// MARK: - Money card views (task 9.09, requirements M1, M2, T2)
//
// The visual half of the Money overview. Every figure and every gate comes from
// `NativeMoneyCardModels` (host-tested against the RN fixtures); these views own
// only layout and the app palette. Cards whose destination belongs to a later
// task take an optional `onOpen`: with no destination they render as a plain
// summary card (no chevron, no dead affordance) until 9.11/9.12 wire them.

enum NativeMoneyPalette {
    static func color(_ tone: NativeMoneyCardTone) -> Color {
        switch tone {
        case .accent: .tradeReady
        case .success: .green
        case .warning: .orange
        case .danger: .red
        case .neutral: .primary
        case .muted: .secondary
        }
    }
}

/// Shared card chrome: title row, optional badge/chevron, optional data-window
/// caption (`CardScope`), then the card body.
struct NativeMoneyCard<Content: View>: View {
    var title: String
    var badge: String?
    var badgeTone: NativeMoneyCardTone = .muted
    var scope: String?
    var onOpen: (() -> Void)?
    /// RN-matching label for an openable card (with the figure as its value).
    /// Without one, the openable card reads its title and figures in full, as
    /// RN does for cards with no `accessibilityLabel` (11.10a fix round 1).
    var openLabel: String?
    var openValue: String?
    @ViewBuilder var content: Content

    init(
        title: String,
        badge: String? = nil,
        badgeTone: NativeMoneyCardTone = .muted,
        scope: String? = nil,
        onOpen: (() -> Void)? = nil,
        openLabel: String? = nil,
        openValue: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.badgeTone = badgeTone
        self.scope = scope
        self.onOpen = onOpen
        self.openLabel = openLabel
        self.openValue = openValue
        self.content = content()
    }

    var body: some View {
        if let onOpen, let openLabel {
            Button(action: onOpen) { card }
                .buttonStyle(.plain)
                .accessibilityLabel(openLabel)
                .accessibilityValue(openValue ?? "")
        } else if let onOpen {
            Button(action: onOpen) { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NativeMoneyPalette.color(badgeTone))
                }
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if let scope {
                Text(scope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, -6)
            }
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary) }
        .shadow(color: .black.opacity(0.045), radius: 8, y: 3)
    }
}

/// Progress/bar track shared by the category, customer, and funnel rows.
private struct NativeMoneyTrack: View {
    var fraction: Double
    var tone: NativeMoneyCardTone
    var height: CGFloat = 6
    var opacity: Double = 1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(NativeMoneyPalette.color(tone).opacity(opacity))
                    .frame(width: max(0, min(1, fraction / 100)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// `MoneySection` — a collapsible group header. Expansion is per-session, exactly
/// like RN (no persisted key).
struct NativeMoneySectionView<Content: View>: View {
    let title: String
    var defaultExpanded = false
    @ViewBuilder var content: Content

    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, defaultExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.defaultExpanded = defaultExpanded
        self.content = content()
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(NativeAccessibilityAudit.allowsCustomMotion(reduceMotion: reduceMotion) ? .snappy(duration: 0.2) : nil) {
                    expanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(spacing: 12) { content }
            }
        }
    }
}

// MARK: - Summary

struct NativeMoneySummaryCardView: View {
    let card: NativeMoneySummaryCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.periodLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            NativeAccessibilityAdaptiveRow {
                column(
                    label: "Income",
                    amount: NativeMoneyFormat.money(card.income),
                    tone: .success,
                    change: card.incomeChangePercent
                )
                NativeAccessibilityColumnDivider(height: 46, horizontalPadding: 10)
                column(
                    label: "Expenses",
                    amount: NativeMoneyFormat.money(card.expenses),
                    tone: .danger,
                    change: card.expensesChangePercent,
                    inverse: true
                )
                NativeAccessibilityColumnDivider(height: 46, horizontalPadding: 10)
                column(
                    label: "Net Profit",
                    amount: NativeMoneyFormat.money(card.netProfit),
                    tone: card.netProfitTone,
                    change: card.netProfitChangePercent
                )
            }

            if let margin = card.marginPercent {
                VStack(alignment: .leading, spacing: 4) {
                    NativeMoneyTrack(fraction: card.marginFraction, tone: card.netProfitTone, height: 6)
                    Text("\(margin)% margin")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary) }
        .shadow(color: .black.opacity(0.045), radius: 8, y: 3)
    }

    private func column(
        label: String,
        amount: String,
        tone: NativeMoneyCardTone,
        change: Int?,
        inverse: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(amount)
                .font(.system(.headline, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(NativeMoneyPalette.color(tone))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let change, change != 0 {
                Text("\(change > 0 ? "↑" : "↓") \(abs(change))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NativeMoneyPalette.color(.delta(change, inverse: inverse)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Monthly chart

struct NativeMoneyMonthlyChartCardView: View {
    let card: NativeMoneyMonthlyChartCard

    var body: some View {
        NativeMoneyCard(title: "Last 6 Months", scope: nil) {
            HStack(spacing: 14) {
                legend("Income", tone: .success)
                legend("Expenses", tone: .danger)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            bar(row.incomeFraction(max: card.maxValue), tone: .success)
                            bar(row.expenseFraction(max: card.maxValue), tone: .danger)
                        }
                        .frame(height: 80, alignment: .bottom)
                        Text(row.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func legend(_ label: String, tone: NativeMoneyCardTone) -> some View {
        HStack(spacing: 5) {
            Circle().fill(NativeMoneyPalette.color(tone)).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bar(_ fraction: Double, tone: NativeMoneyCardTone) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(NativeMoneyPalette.color(tone))
            .frame(width: 8, height: max(2, min(1, fraction) * 80))
    }
}

// MARK: - Expenses by category

struct NativeMoneyExpenseCategoryCardView: View {
    let card: NativeMoneyExpenseCategoryCard
    @ScaledMetric(relativeTo: .caption) private var iconBadgeSize: CGFloat = 22

    var body: some View {
        NativeMoneyCard(title: "Expenses by Category", scope: nil) {
            ForEach(card.rows, id: \.id) { row in
                HStack(spacing: 10) {
                    Image(systemName: NativeMoneyCategorySymbol.symbol(for: row.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: iconBadgeSize, height: iconBadgeSize)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.label).font(.subheadline)
                            Spacer(minLength: 8)
                            Text(NativeMoneyFormat.money(row.total))
                                .font(.subheadline.monospacedDigit())
                        }
                        NativeMoneyTrack(fraction: row.fraction, tone: .accent, height: 5)
                    }
                }
            }
        }
    }
}

/// SF Symbol stand-ins for RN's Ionicons per category.
enum NativeMoneyCategorySymbol {
    static func symbol(for categoryID: String) -> String {
        switch categoryID {
        case "materials": "square.stack.3d.up"
        case "tools": "wrench.and.screwdriver"
        case "fuel": "car"
        case "labor": "person.2"
        case "insurance": "checkmark.shield"
        case "software": "laptopcomputer"
        case "marketing": "megaphone"
        default: "shippingbox"
        }
    }
}

// MARK: - Seasonal trends

struct NativeMoneySeasonalCardView: View {
    let card: NativeMoneySeasonalCard

    var body: some View {
        NativeMoneyCard(title: "12-Month Trend", badge: card.yoyBadge, badgeTone: card.yoyTone ?? .muted) {
            HStack(spacing: 14) {
                legend("This year", tone: .accent)
                legend("Last year", tone: .neutral, faded: true)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(card.trends.months.enumerated()), id: \.offset) { _, month in
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(.quaternary)
                                .frame(width: 6, height: height(month.lastYear))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.tradeReady)
                                .frame(width: 6, height: height(month.thisYear))
                        }
                        .frame(height: 80, alignment: .bottom)
                        Text(month.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            NativeAccessibilityAdaptiveRow(alignment: .center) {
                total("This Year", amount: card.trends.thisYearTotal, tone: .accent)
                if card.trends.lastYearTotal > 0 {
                    NativeAccessibilityColumnDivider(height: 30)
                    total("Last Year", amount: card.trends.lastYearTotal, tone: .neutral)
                }
            }
        }
    }

    private func height(_ value: Decimal) -> CGFloat {
        guard card.maxValue > 0 else { return 0 }
        let fraction = NSDecimalNumber(decimal: value).doubleValue
            / NSDecimalNumber(decimal: card.maxValue).doubleValue
        return max(2, min(1, fraction) * 80)
    }

    private func legend(_ label: String, tone: NativeMoneyCardTone, faded: Bool = false) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(faded ? AnyShapeStyle(.quaternary) : AnyShapeStyle(NativeMoneyPalette.color(tone)))
                .frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func total(_ label: String, amount: Decimal, tone: NativeMoneyCardTone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(NativeMoneyFormat.money(amount))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(NativeMoneyPalette.color(tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Expense trends

struct NativeMoneyExpenseTrendsCardView: View {
    let card: NativeMoneyExpenseTrendsCard
    @ScaledMetric(relativeTo: .caption2) private var microSize: CGFloat = 8

    var body: some View {
        NativeMoneyCard(
            title: "Expense Trends",
            badge: card.trendBadge,
            badgeTone: card.trendTone ?? .muted,
            scope: "Last 12 months"
        ) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(card.trends.months.enumerated()), id: \.offset) { index, month in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.red)
                            .frame(height: barHeight(month.total))
                            .frame(height: 80, alignment: .bottom)
                        Text(month.label.prefix(1))
                            .font(.system(size: microSize))
                            .foregroundStyle(.secondary)
                        Text(card.monthChangeLabels[index].isEmpty ? " " : card.monthChangeLabels[index])
                            .font(.system(size: microSize).monospacedDigit())
                            .foregroundStyle(NativeMoneyPalette.color(card.monthChangeTone(index)))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            NativeAccessibilityAdaptiveRow(alignment: .center) {
                total("12-Mo Total", amount: card.trends.trailingTotal, tone: .danger)
                NativeAccessibilityColumnDivider(height: 30)
                total("Monthly Avg", amount: Decimal(card.trends.avgMonthly), tone: .neutral)
            }
        }
    }

    private func barHeight(_ total: Decimal) -> CGFloat {
        guard card.maxValue > 0 else { return 0 }
        let fraction = NSDecimalNumber(decimal: total).doubleValue
            / NSDecimalNumber(decimal: card.maxValue).doubleValue
        return max(2, min(1, fraction) * 80)
    }

    private func total(_ label: String, amount: Decimal, tone: NativeMoneyCardTone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(NativeMoneyFormat.money(amount))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(NativeMoneyPalette.color(tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Top customers

struct NativeMoneyTopCustomersCardView: View {
    let card: NativeMoneyTopCustomersCard
    @ScaledMetric(relativeTo: .caption) private var rankWidth: CGFloat = 16

    var body: some View {
        NativeMoneyCard(title: "Top Customers") {
            ForEach(card.rows, id: \.rank) { row in
                HStack(spacing: 10) {
                    Text("\(row.rank)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: rankWidth)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.name).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(NativeMoneyFormat.money(row.amount))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        NativeMoneyTrack(fraction: row.fraction, tone: .success, height: 5)
                    }
                }
            }
        }
    }
}

// MARK: - Customer mix

struct NativeMoneyCustomerMixCardView: View {
    let card: NativeMoneyCustomerMixCard

    var body: some View {
        NativeMoneyCard(title: "Customer Mix") {
            NativeAccessibilityAdaptiveRow(alignment: .center) {
                column(count: card.newCount, label: "New", revenue: card.mix.newRevenue, tone: .accent)
                NativeAccessibilityColumnDivider(height: 40)
                column(count: card.returningCount, label: "Returning", revenue: card.mix.returningRevenue, tone: .success)
            }
            if card.totalRevenue > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if card.mix.newRevenue > 0 {
                            Rectangle().fill(Color.tradeReady)
                                .frame(width: geometry.size.width * Double(card.newPercent) / 100)
                        }
                        if card.mix.returningRevenue > 0 {
                            Rectangle().fill(Color.green)
                                .frame(width: geometry.size.width * Double(card.returningPercent) / 100)
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
                HStack(spacing: 12) {
                    if card.mix.newRevenue > 0 {
                        Text("\(card.newPercent)% new").font(.caption2).foregroundStyle(Color.tradeReady)
                    }
                    if card.mix.returningRevenue > 0 {
                        Text("\(card.returningPercent)% returning").font(.caption2).foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func column(count: Int, label: String, revenue: Decimal, tone: NativeMoneyCardTone) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)")
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(NativeMoneyPalette.color(tone))
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(NativeMoneyFormat.money(revenue)).font(.subheadline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Days to pay

struct NativeMoneyInvoiceAgingCardView: View {
    let card: NativeMoneyInvoiceAgingCard

    var body: some View {
        NativeMoneyCard(title: "Days to Pay", scope: "All paid invoices") {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.daysLabel)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(NativeMoneyPalette.color(card.daysTone))
                Text(card.averageSummary).font(.caption).foregroundStyle(.secondary)
            }
            if !card.slowPayers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Slowest Payers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(card.slowPayers, id: \.name) { payer in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(payer.name).font(.subheadline).lineLimit(1)
                                Text("\(payer.invoiceCount) inv · \(NativeMoneyFormat.money(payer.totalAmount))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text("\(payer.averageDays)d")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(NativeMoneyPalette.color(payer.tone))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Receivables

struct NativeMoneyReceivablesCardView: View {
    let card: NativeMoneyReceivablesCard

    var body: some View {
        NativeMoneyCard(title: "Money owed to you", scope: "All open") {
            NativeAccessibilityAdaptiveRow {
                column(
                    label: "Outstanding",
                    amount: card.receivables.outstanding,
                    sub: card.outstandingCountLabel,
                    tone: .neutral
                )
                NativeAccessibilityColumnDivider(height: 44, horizontalPadding: 10)
                column(
                    label: "Overdue",
                    amount: card.receivables.overdue,
                    sub: card.overdueCountLabel,
                    tone: card.overdueTone
                )
                NativeAccessibilityColumnDivider(height: 44, horizontalPadding: 10)
                column(
                    label: "Pipeline",
                    amount: card.receivables.pipelineValue,
                    sub: card.pipelineCountLabel,
                    tone: .accent
                )
            }
        }
    }

    private func column(label: String, amount: Decimal, sub: String, tone: NativeMoneyCardTone) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(NativeMoneyFormat.money(amount))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(NativeMoneyPalette.color(tone))
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Job pipeline

struct NativeMoneyConversionFunnelCardView: View {
    let card: NativeMoneyConversionFunnelCard
    @ScaledMetric(relativeTo: .subheadline) private var countWidth: CGFloat = 26

    var body: some View {
        NativeMoneyCard(
            title: "Job Pipeline",
            badge: card.winRateBadge,
            badgeTone: .muted,
            scope: "All jobs"
        ) {
            ForEach(Array(card.stages.enumerated()), id: \.offset) { index, stage in
                VStack(alignment: .leading, spacing: 4) {
                    if let connector = stage.connector {
                        Text(connector)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("\(stage.count)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .frame(minWidth: countWidth, alignment: .leading)
                        Text(stage.label).font(.subheadline)
                    }
                    NativeMoneyTrack(
                        fraction: stage.barPercent,
                        tone: NativeMoneyPalette.tone(forStatus: stage.status),
                        height: 8
                    )
                }
                .padding(.bottom, index == card.stages.count - 1 ? 0 : 2)
            }
        }
    }
}

extension NativeMoneyPalette {
    /// RN colors each funnel stage by job status.
    static func tone(forStatus status: String) -> NativeMoneyCardTone {
        switch status {
        case "lead": .muted
        case "estimate_sent": .warning
        case "approved": .accent
        case "scheduled": .accent
        case "in_progress": .accent
        case "complete": .success
        default: .neutral
        }
    }
}

struct NativeMoneyRevenueForecastCardView: View {
    let card: NativeMoneyRevenueForecastCard

    var body: some View {
        NativeMoneyCard(
            title: "Revenue Forecast",
            badge: card.winRateBadge,
            badgeTone: card.winRateTone ?? .muted,
            scope: "Open pipeline"
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NativeMoneyFormat.money(card.forecast.totalForecast))
                    .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.tradeReady)
                Text("Forecasted Revenue").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.tradeReady)
                        .frame(width: geometry.size.width * card.likelyFraction / 100)
                    Rectangle().fill(Color.tradeReady.opacity(0.25))
                        .frame(width: geometry.size.width * (1 - card.likelyFraction / 100))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            NativeAccessibilityAdaptiveRow {
                breakdown(
                    label: "Likely",
                    amount: card.forecast.certainValue,
                    sub: card.certainCountLabel,
                    tone: .accent,
                    outlined: false
                )
                NativeAccessibilityColumnDivider(height: 40)
                breakdown(
                    label: "Projected",
                    amount: card.forecast.projectedValue,
                    sub: card.projectedCountLabel,
                    tone: .accent,
                    outlined: true
                )
            }
        }
    }

    private func breakdown(
        label: String,
        amount: Decimal,
        sub: String,
        tone: NativeMoneyCardTone,
        outlined: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if outlined {
                    Circle().stroke(NativeMoneyPalette.color(tone), lineWidth: 1).frame(width: 8, height: 8)
                } else {
                    Circle().fill(NativeMoneyPalette.color(tone)).frame(width: 8, height: 8)
                }
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(NativeMoneyFormat.money(amount)).font(.subheadline.monospacedDigit().weight(.semibold))
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Avg job value

struct NativeMoneyAvgJobValueCardView: View {
    let card: NativeMoneyAvgJobValueCard

    var body: some View {
        NativeMoneyCard(
            title: "Avg Job Value",
            badge: card.changeTone == nil ? nil : card.changeBadgeText,
            badgeTone: card.changeTone ?? .muted
        ) {
            Text(NativeMoneyFormat.money(card.heroValue))
                .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
            NativeAccessibilityAdaptiveRow(alignment: .center) {
                detail("Completed", value: card.completedLabel)
                NativeAccessibilityColumnDivider(height: 30)
                detail("Total Value", value: NativeMoneyFormat.money(card.totalValue))
            }
            if card.showsAllTimeNote {
                Text("Showing all-time average").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NativeMoneyAvgJobValueCard {
    /// `↑ 12%` / `↓ 12%` (RN hides the badge for nil or zero).
    var changeBadgeText: String? {
        guard let changePercent, changePercent != 0 else { return nil }
        return "\(changePercent > 0 ? "↑" : "↓") \(abs(changePercent))%"
    }
}

// MARK: - Revenue by type

struct NativeMoneyRevenueByTypeCardView: View {
    let card: NativeMoneyRevenueByTypeCard

    var body: some View {
        NativeMoneyCard(title: "Revenue Breakdown") {
            Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(card.components.enumerated()), id: \.offset) { _, component in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(component.label).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(NativeMoneyFormat.money(component.total))
                            .font(.subheadline.monospacedDigit())
                    }
                    NativeMoneyTrack(fraction: Double(component.percent), tone: component.tone, height: 6)
                    Text("\(component.percent)%").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Job profitability

struct NativeMoneyJobProfitabilityCardView: View {
    let card: NativeMoneyJobProfitabilityCard

    var body: some View {
        NativeMoneyCard(title: "Job Profitability", scope: "Completed jobs, all time") {
            Text(card.coverageLabel).font(.caption).foregroundStyle(.secondary)
            if let emptyCopy = card.emptyCopy {
                Text(emptyCopy).font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(card.rows, id: \.key) { row in
                    HStack {
                        Text(row.label).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(row.value).font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
    }
}

// MARK: - Mileage, tax, pricebook

struct NativeMoneyMileageCardView: View {
    let card: NativeMoneyMileageCard
    var onOpen: (() -> Void)?

    var body: some View {
        NativeMoneyCard(title: "Mileage deduction", onOpen: onOpen) {
            Text(card.deductionText)
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
            Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NativeMoneyTaxCardView: View {
    let card: NativeMoneyTaxCard
    var onOpen: (() -> Void)?

    var body: some View {
        NativeMoneyCard(
            title: "Tax set-aside",
            onOpen: onOpen,
            openLabel: NativeAccessibilityAudit.Label.taxSetAsideOpen,
            openValue: card.reserveText
        ) {
            Text(card.reserveText)
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
            Text(card.breakdown.periodSummaryText).font(.caption).foregroundStyle(.secondary)
            Text(card.ytdLabel).font(.caption).foregroundStyle(.secondary)
            if let prompt = card.breakdown.vehiclePrompt {
                Text(prompt).font(.caption).foregroundStyle(.orange)
            }
            if let prompt = card.breakdown.incomeRatePrompt {
                Text(prompt).font(.caption).foregroundStyle(.secondary)
            }
            if let note = card.breakdown.staleRatesNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Text(card.breakdown.mileageDisclosure).font(.caption2).foregroundStyle(.secondary)
            Text(card.breakdown.disclaimer).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct NativeMoneyPricebookCardView: View {
    let card: NativeMoneyPricebookCard
    var onOpen: (() -> Void)?

    var body: some View {
        NativeMoneyCard(title: "Pricebook", onOpen: onOpen) {
            Text(card.countText)
                .font(.system(.title3, design: .rounded, weight: .bold))
            Text(onOpen == nil ? card.categoryText : card.categoryText + NativeMoneyPricebookCard.manageHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
