import SwiftUI

// MARK: - View (RN `components/InsightsCard.tsx`)
//
// Presentation policy (visibility, top-3 slicing, mute-availability,
// fail-closed behavior) lives in the pure `Domain/NativeInsightsCardPolicy.swift`
// (task 10.12, requirement S5) — this view only renders what `AppStore`'s
// `today*` wiring, itself backed by that policy, hands it.

/// The "Insights" card — takes the setup checklist's slot once setup is
/// complete (contract §3.1). All policy (visibility, slicing, mute
/// availability) comes from `AppStore`'s `today*` wiring over
/// `NativeInsightsCardPolicy`; this view only renders and forwards taps.
struct NativeInsightsCardView: View {
    @EnvironmentObject private var store: AppStore

    /// `TodayView`'s shared `NativeTodayRouteResult` → sheet-state mapping
    /// (`handleRouteResult`) — an insight's target can resolve to a
    /// `.presentInvoiceFromJob`/`.presentJobEditor` sheet that only the
    /// parent view can present, so a tap cannot route through `AppStore`
    /// alone the way a plain-navigation row can.
    var onRoute: (AppStore.NativeTodayRouteResult) -> Void = { _ in }

    @State private var reasonInsight: NativeTodayInsight?
    @State private var optionsInsight: NativeTodayInsight?

    var body: some View {
        if store.todayInsightsVisible {
            let insights = store.todayVisibleInsights
            VStack(alignment: .leading, spacing: 0) {
                Text("Insights").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
                ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                    row(insight)
                        .overlay(alignment: .top) {
                            if index > 0 { Divider() }
                        }
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary) }
            .onAppear { store.trackTodayInsightsShownIfNeeded(insights) }
            .onChange(of: insights) { _, newValue in store.trackTodayInsightsShownIfNeeded(newValue) }
            .confirmationDialog(
                optionsInsight?.title ?? "",
                isPresented: Binding(get: { optionsInsight != nil }, set: { if !$0 { optionsInsight = nil } }),
                titleVisibility: .visible,
                presenting: optionsInsight
            ) { insight in
                optionsActions(for: insight)
            }
            .alert(
                "Why am I seeing this?",
                isPresented: Binding(get: { reasonInsight != nil }, set: { if !$0 { reasonInsight = nil } }),
                presenting: reasonInsight
            ) { _ in Button("OK") {} } message: { insight in
                Text(insight.reason)
            }
        }
    }

    @ViewBuilder
    private func optionsActions(for insight: NativeTodayInsight) -> some View {
        Button("Why am I seeing this?") {
            store.trackInsightReasonViewed(insight)
            reasonInsight = insight
        }
        if NativeInsightsCardPolicy.isMuteable(insight.kind),
           let days = NativeInsightsCardPolicy.snoozeDays(for: insight.kind) {
            Button("Snooze \(days) days") { store.applyInsightMute(insight, days: days) }
        }
        if NativeInsightsCardPolicy.isMuteable(insight.kind) {
            Button("Dismiss", role: .destructive) { store.applyInsightMute(insight, days: nil) }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func row(_ insight: NativeTodayInsight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: NativeInsightsCardPolicy.symbolName(for: insight.kind))
                .foregroundStyle(Color.tradeReady)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.subheadline.weight(.medium))
                if let detail = insight.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let prompt = insight.coachPrompt {
                    Button {
                        store.trackInsightCoachOpened(insight)
                        store.installPendingCoachPrefill(prompt)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right")
                            Text("Ask coach")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tradeReady)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask coach about \(insight.title)")
                }
            }
            Spacer(minLength: 8)
            if NativeInsightsCardPolicy.isMuteable(insight.kind), NativeInsightsCardPolicy.mutesReadable(store.insightMutes) {
                Button {
                    optionsInsight = insight
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Options for \(insight.title)")
            }
            Text("›").font(.title3).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            store.trackInsightTapped(insight)
            onRoute(store.handleTodayInsightTap(insight))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(insight.title)
        .accessibilityAddTraits(.isButton)
    }
}
