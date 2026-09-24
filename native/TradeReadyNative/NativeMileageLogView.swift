import SwiftUI

// MARK: - Mileage log (task 9.11, requirements T1, T2 rates)
//
// Port of `screens/MileageLogScreen.tsx`: the period chips, the "Estimated
// deduction" card, the rate row, the newest-first trip list, the empty state,
// and "+ Add trip". Rows open `NativeTripEditor`, which commits through the
// typed 9.08 `commitTripEdit` path; this screen holds no mileage policy of its
// own (see `NativeMileageLog` + `NativeMileage`).

struct NativeMileageLogView: View {
    @EnvironmentObject private var store: AppStore

    /// Seed from the Money screen's active filter (RN passes `initialFilter`).
    let initialFilter: NativeMoneyDateFilter

    @State private var filter: NativeMoneyDateFilter
    @State private var editorTarget: NativeTripEditorTarget?
    @State private var pendingDeletion: NativeTripLogRow?

    init(initialFilter: NativeMoneyDateFilter = .thisYear) {
        self.initialFilter = initialFilter
        _filter = State(initialValue: initialFilter)
    }

    private var range: NativeDateRange { NativeCashBasis.range(for: filter.rawValue, now: Date()) }
    private var rows: [NativeTripLogRow] {
        NativeMileageLog.rows(trips: store.canonicalTrips, start: range.start, end: range.end)
    }

    var body: some View {
        List {
            Section { filterChips.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0)) }
                .listRowBackground(Color.clear)

            Section {
                summaryCard
                rateRow
            }

            Section {
                Button { editorTarget = .create } label: {
                    Label("Add trip", systemImage: "plus.circle.fill")
                }
            }

            Section("Trips") {
                ForEach(rows, id: \.id) { row in
                    Button { editorTarget = .edit(row.id) } label: {
                        NativeTripLogRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { pendingDeletion = row } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .tradeReadyListStyle()
        .overlay {
            if rows.isEmpty {
                NativeContentStateView(
                    state: .empty,
                    emptyTitle: "No trips logged",
                    emptyMessage: "Tap \"+ Add trip\" to log your first business drive for this period.",
                    symbol: "car"
                )
            }
        }
        .navigationTitle("Mileage log")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.performPullToRefresh() }
        .sheet(item: $editorTarget) { target in
            NativeTripEditor(target: target, opened: openedTrip(for: target))
        }
        .confirmationDialog(
            "Delete trip",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDeletion { store.deleteTripRecord(id: row.id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Remove this trip from your mileage log?")
        }
        .nativeAnalyticsScreen(.mileageLog)
    }

    // MARK: Pieces

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NativeMoneyDateFilter.allCases) { option in
                    Button { filter = option } label: {
                        Text(option.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                filter == option ? Color.tradeReady : Color.tradeInk.opacity(0.06),
                                in: Capsule()
                            )
                            .foregroundStyle(filter == option ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? [.isSelected] : [])
                    .accessibilityLabel(option.label)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var summaryCard: some View {
        let card = NativeMileageLog.summaryCard(
            trips: store.canonicalTrips,
            start: range.start,
            end: range.end,
            rate: store.effectiveMileageRate
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(card.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(card.deductionText)
                .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.tradeReady)
            Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// The rate the deduction actually uses. 9.02 owns the canonical field (and
    /// Settings already exposes it); this is the same stored value, editable
    /// here so the number on the card can be understood where it is read.
    private var rateRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            CurrencyField(title: "Mileage rate", value: $store.settings.mileageRate)
            Text(NativeMileageLog.rateDisclosure)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func openedTrip(for target: NativeTripEditorTarget) -> Canonical.Trip? {
        guard case .edit(let id) = target else { return nil }
        return store.canonicalTrips.first { $0.id == id }
    }
}

/// One trip row: route, date · purpose, miles.
struct NativeTripLogRowView: View {
    let row: NativeTripLogRow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.routeText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(row.purpose.isEmpty ? row.dateText : "\(row.dateText) · \(row.purpose)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.milesText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
