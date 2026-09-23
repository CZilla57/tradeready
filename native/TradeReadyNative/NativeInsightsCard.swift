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
        reasonButton(for: insight)
        muteButtons(for: insight)
        Button("Cancel", role: .cancel) {}
    }

    /// Fix round 1 (I3): always offered — the reason sheet must be reachable
    /// for every row, muteable or not, matching RN's long-press. This is the
    /// one place that fires `insight_reason_viewed`, whether reached through
    /// the ellipsis dialog or the row's `.contextMenu`.
    private func reasonButton(for insight: NativeTodayInsight) -> some View {
        Button("Why am I seeing this?") {
            store.trackInsightReasonViewed(insight)
            reasonInsight = insight
        }
    }

    /// Fix round 1 (I3): snooze/dismiss, gated on the single policy-layer
    /// decision (`NativeInsightsCardPolicy.muteControlsAvailable`) instead of
    /// the view re-deriving `isMuteable && mutesReadable` ad hoc.
    @ViewBuilder
    private func muteButtons(for insight: NativeTodayInsight) -> some View {
        if NativeInsightsCardPolicy.muteControlsAvailable(for: insight.kind, mutes: store.insightMutes) {
            if let days = NativeInsightsCardPolicy.snoozeDays(for: insight.kind) {
                Button("Snooze \(days) days") { store.applyInsightMute(insight, days: days) }
            }
            Button("Dismiss", role: .destructive) { store.applyInsightMute(insight, days: nil) }
        }
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
            if NativeInsightsCardPolicy.muteControlsAvailable(for: insight.kind, mutes: store.insightMutes) {
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
        // Fix round 1 (I3): long-press/context-menu equivalent of the
        // ellipsis dialog, attached to every row unconditionally so the
        // reason is reachable even when there are no mute controls to show.
        .contextMenu {
            optionsActions(for: insight)
        }
        // Fix round 1 (I3 accessibility minor): `.accessibilityElement(children:
        // .combine)` merges the row into one VoiceOver element, which makes
        // the nested "Ask coach" and "Options" buttons unreachable as
        // separate swipe targets. Exposing them as accessibility actions
        // (plus the reason, always) keeps the row a single element for
        // swipe navigation while restoring access to every action through
        // VoiceOver's actions rotor, matching RN's equivalent affordances.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(insight.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Why am I seeing this?")) {
            store.trackInsightReasonViewed(insight)
            reasonInsight = insight
        }
        .modifier(InsightCoachAccessibilityAction(insight: insight, store: store))
        .modifier(InsightMuteAccessibilityActions(insight: insight, store: store))
    }
}

/// Fix round 1 (I3 accessibility minor): the "Ask coach" action, exposed only
/// when the insight actually carries a coach prompt — split into its own
/// `ViewModifier` because `accessibilityAction` isn't conditionally
/// applicable inline without one.
private struct InsightCoachAccessibilityAction: ViewModifier {
    let insight: NativeTodayInsight
    let store: AppStore

    func body(content: Content) -> some View {
        if let prompt = insight.coachPrompt {
            content.accessibilityAction(named: Text("Ask coach")) {
                store.trackInsightCoachOpened(insight)
                store.installPendingCoachPrefill(prompt)
            }
        } else {
            content
        }
    }
}

/// Fix round 1 (I3 accessibility minor): snooze/dismiss actions, gated on the
/// same policy-layer decision as the ellipsis button and the context menu.
private struct InsightMuteAccessibilityActions: ViewModifier {
    let insight: NativeTodayInsight
    let store: AppStore

    func body(content: Content) -> some View {
        if NativeInsightsCardPolicy.muteControlsAvailable(for: insight.kind, mutes: store.insightMutes) {
            content
                .accessibilityAction(named: Text("Dismiss")) {
                    store.applyInsightMute(insight, days: nil)
                }
                .modifier(InsightSnoozeAccessibilityAction(insight: insight, store: store))
        } else {
            content
        }
    }
}

private struct InsightSnoozeAccessibilityAction: ViewModifier {
    let insight: NativeTodayInsight
    let store: AppStore

    func body(content: Content) -> some View {
        if let days = NativeInsightsCardPolicy.snoozeDays(for: insight.kind) {
            content.accessibilityAction(named: Text("Snooze \(days) days")) {
                store.applyInsightMute(insight, days: days)
            }
        } else {
            content
        }
    }
}
