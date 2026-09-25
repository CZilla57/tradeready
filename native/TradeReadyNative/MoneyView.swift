import SwiftUI

// MARK: - Money (task 9.09, requirements M1, M2, T2)
//
// Port of `screens/MoneyScreen.tsx`: the date-filter chips, the
// Overview/Expenses segmented control, the cash-basis summary, the collapsible
// analytics sections, and the expenses list. Every card is presented from
// `AppStore.moneyOverview(filter:)` (`NativeMoneyCardModels`), so the screen
// holds no reporting policy of its own.
//
// Every destination on this screen is real: the header export action opens
// 9.13's `NativeExportDataView`, the mileage card opens 9.11's
// `NativeMileageLogView` seeded with the active filter, the pricebook card opens
// 9.12's `NativePricebookView`, and expenses use the full 9.10 editor
// (`NativeExpenseEditor`) — categories, job link, receipt capture, and reviewed
// OCR pre-fill, committed through the 9.08 typed path. The tax card states its
// own IRS windows rather than a destination.

/// Money-screen destinations owned by the phase 9 feature screens. Kept here so
/// the card closures stay one-liners.
enum NativeMoneyDestination: Hashable {
    case mileage
    case pricebook
    case exportData
}

struct MoneyView: View {
    @EnvironmentObject private var store: AppStore

    @State private var filter: NativeMoneyDateFilter = .thisMonth
    @State private var tab: NativeMoneyTab = .overview
    @State private var editorTarget: NativeExpenseEditorTarget?
    @State private var pendingExpenseDeletion: NativeMoneyExpenseRow?
    @State private var destination: NativeMoneyDestination?

    var body: some View {
        // One report pass per render, against the real clock (RN recomputes
        // `getDateRange()` on every render rather than caching a window).
        let overview = store.moneyOverview(filter: filter, now: Date())
        NavigationStack {
            VStack(spacing: 0) {
                filterChips
                Divider().overlay(Color.tradeInk.opacity(0.06))
                tabPicker
                Divider().overlay(Color.tradeInk.opacity(0.06))
                switch tab {
                case .overview: overviewTab(overview)
                case .expenses: expensesTab
                }
            }
            .background(Color.tradeCanvas)
            .navigationTitle("Money")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        destination = .exportData
                    } label: {
                        Label("Export data", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $editorTarget) { target in
                NativeExpenseEditor(target: target, opened: openedRecord(for: target))
            }
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .mileage: NativeMileageLogView(initialFilter: filter)
                case .pricebook: NativePricebookView()
                case .exportData: NativeExportDataView()
                }
            }
            .confirmationDialog(
                "Delete Expense",
                isPresented: Binding(
                    get: { pendingExpenseDeletion != nil },
                    set: { if !$0 { pendingExpenseDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let row = pendingExpenseDeletion { store.deleteExpenseRecord(id: row.id) }
                    pendingExpenseDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingExpenseDeletion = nil }
            } message: {
                Text("Remove \"\(pendingExpenseDeletion?.merchant ?? "")\"?")
            }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.money)
        }
    }

    // MARK: Filter chips + tabs

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NativeMoneyDateFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Text(option.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                filter == option ? Color.tradeReadyFill : Color.tradeInk.opacity(0.06),
                                in: Capsule()
                            )
                            .foregroundStyle(filter == option ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .nativeContentColumnFrame()
    }

    private var tabPicker: some View {
        Picker("Money view", selection: $tab) {
            ForEach(NativeMoneyTab.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .nativeContentColumnFrame()
        .accessibilityLabel("Money view")
    }

    // MARK: Overview

    private func overviewTab(_ overview: NativeMoneyOverview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                NativeMoneySummaryCardView(card: overview.summary)

                if overview.state == .trueEmpty {
                    NativeMoneyTrueEmptyState()
                } else {
                    cashFlowSection(overview)
                    customersSection(overview)
                    pipelineSection(overview)
                    toolsSection(overview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .nativeContentColumn(.scroll)
        .refreshable {
            await store.performPullToRefresh(screen: .money)
        }
        .background(Color.tradeCanvas)
    }

    private func cashFlowSection(_ overview: NativeMoneyOverview) -> some View {
        NativeMoneySectionView(title: "Cash flow", defaultExpanded: true) {
            NativeMoneyMonthlyChartCardView(card: overview.monthlyChart)
            if overview.seasonal.showsCard {
                NativeMoneySeasonalCardView(card: overview.seasonal)
            }
            if let categories = overview.expenseCategories {
                NativeMoneyExpenseCategoryCardView(card: categories)
            }
            if overview.expenseTrends.showsCard {
                NativeMoneyExpenseTrendsCardView(card: overview.expenseTrends)
            }
        }
    }

    private func customersSection(_ overview: NativeMoneyOverview) -> some View {
        NativeMoneySectionView(title: "Customers & invoices") {
            if let top = overview.topCustomers {
                NativeMoneyTopCustomersCardView(card: top)
            }
            if let mix = overview.customerMix {
                NativeMoneyCustomerMixCardView(card: mix)
            }
            if overview.invoiceAging.showsCard {
                NativeMoneyInvoiceAgingCardView(card: overview.invoiceAging)
            }
        }
    }

    private func pipelineSection(_ overview: NativeMoneyOverview) -> some View {
        NativeMoneySectionView(title: "Job pipeline") {
            if overview.receivables.showsCard {
                NativeMoneyReceivablesCardView(card: overview.receivables)
            }
            if overview.funnel.showsCard {
                NativeMoneyConversionFunnelCardView(card: overview.funnel)
            }
            if overview.forecast.showsCard {
                NativeMoneyRevenueForecastCardView(card: overview.forecast)
            }
            if overview.avgJobValue.showsCard {
                NativeMoneyAvgJobValueCardView(card: overview.avgJobValue)
            }
            if overview.revenueByType.showsCard {
                NativeMoneyRevenueByTypeCardView(card: overview.revenueByType)
            }
            if overview.profitability.showsCard {
                NativeMoneyJobProfitabilityCardView(card: overview.profitability)
            }
        }
    }

    private func toolsSection(_ overview: NativeMoneyOverview) -> some View {
        NativeMoneySectionView(title: "Tools") {
            NativeMoneyMileageCardView(card: overview.mileage) { destination = .mileage }
            // The tax card ignores the screen filter on purpose: its windows are
            // the IRS periods + calendar YTD, and it states its own range.
            NativeMoneyTaxCardView(card: overview.tax)
            NativeMoneyPricebookCardView(card: overview.pricebook) { destination = .pricebook }
        }
    }

    // MARK: Expenses

    /// The stale-copy baseline for an edit: nil for a new expense, the record as
    /// the user opened it otherwise.
    private func openedRecord(for target: NativeExpenseEditorTarget) -> Expense? {
        guard case .edit(let id) = target else { return nil }
        return store.expenseRecord(id: id)
    }

    private var expensesTab: some View {
        let rows = store.moneyExpenseRows(filter: filter, now: Date())
        return List {
            Section {
                Button {
                    editorTarget = .create
                } label: {
                    Label("Expense", systemImage: "plus.circle.fill")
                }
            }
            ForEach(rows, id: \.id) { row in
                Button {
                    editorTarget = .edit(row.id)
                } label: {
                    NativeMoneyExpenseRowView(row: row)
                }
                .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { pendingExpenseDeletion = row } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .overlay {
            if rows.isEmpty {
                NativeContentStateView(
                    state: .empty,
                    emptyTitle: "No expenses logged",
                    emptyMessage: "Tap \"+ Expense\" to log your first expense for this period.",
                    symbol: "receipt"
                )
            }
        }
        .refreshable {
            await store.performPullToRefresh(screen: .money)
        }
    }
}

/// RN's true-empty overview state (`invoices && expenses && jobs` all empty).
private struct NativeMoneyTrueEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No financial data yet", systemImage: "dollarsign.circle")
        } description: {
            Text("Mark invoices as paid and log your expenses to see your P&L here.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// One Expenses-tab row (`ExpenseRow.tsx`): icon, merchant, category · date,
/// optional notes and receipt glyph, amount.
struct NativeMoneyExpenseRowView: View {
    let row: NativeMoneyExpenseRow
    /// 11.10b A16: the category badge grows with the text beside it.
    @ScaledMetric(relativeTo: .callout) private var iconBadgeSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: NativeMoneyCategorySymbol.symbol(for: row.categoryId))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: iconBadgeSize, height: iconBadgeSize)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.merchant).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(row.categoryLabel) · \(row.dateText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.hasReceipt {
                        Image(systemName: "camera")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !row.notes.isEmpty {
                    Text(row.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let jobTitle = row.jobTitle {
                    Label(jobTitle, systemImage: "briefcase")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(NativeMoneyFormat.money(row.amount))
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
