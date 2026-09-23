import Foundation

// MARK: - Insights card presentation policy (task 10.12, requirement S5)
//
// Pure port of `components/InsightsCard.tsx`'s gating/slicing/mute-affordance
// rules (contract §3.1). No I/O, no SwiftUI — kept in `Domain/` (unlike the
// view files it's used from, `NativeInsightsCard.swift`) so `AppStore.swift`
// can depend on it without pulling SwiftUI into the pure-logic host-test
// compile paths. `AppStore` is the sole caller of `visibleInsights`/`isVisible`;
// the view only reads `AppStore`'s published wiring.
enum NativeInsightsCardPolicy {
    /// `VISIBLE_LIMIT`.
    static let visibleLimit = 3

    /// `MUTEABLE_KINDS` — long-horizon conditions that can't self-clear.
    /// The other five kinds deliberately have no dismiss/snooze affordance;
    /// they disappear on their own as their condition resolves.
    static let muteableKinds: Set<NativeInsightKind> = [
        .lowMarginEstimate, .maintenanceDue, .expenseAnomaly,
    ]

    /// `SNOOZE_DAYS` — only `maintenance_due` offers "Snooze"; the other two
    /// muteable kinds are dismiss-only (their ids are already time/price
    /// scoped, so a plain dismiss naturally expires).
    static let snoozeDaysByKind: [NativeInsightKind: Int] = [.maintenanceDue: 30]

    static func isMuteable(_ kind: NativeInsightKind) -> Bool {
        muteableKinds.contains(kind)
    }

    static func snoozeDays(for kind: NativeInsightKind) -> Int? {
        snoozeDaysByKind[kind]
    }

    /// SF Symbol per kind (RN's `KIND_ICONS`, translated from Ionicons names
    /// to their closest SF Symbol equivalents — a recorded native choice,
    /// not a byte-for-byte icon-asset port).
    static func symbolName(for kind: NativeInsightKind) -> String {
        switch kind {
        case .laborOverrun: return "timer"
        case .lowMarginEstimate: return "chart.line.downtrend.xyaxis"
        case .uninvoicedComplete: return "receipt"
        case .dueSoon: return "alarm"
        case .openSlot: return "calendar.badge.clock"
        case .unscheduledApproved: return "calendar"
        case .maintenanceDue: return "wrench.and.screwdriver"
        case .expenseAnomaly: return "chart.line.uptrend.xyaxis"
        }
    }

    /// `filterMutedInsights(all, mutes, now).slice(0, VISIBLE_LIMIT)` — mute
    /// filter runs BEFORE the top-3 slice, so muting a row promotes the next
    /// one into view.
    ///
    /// Fail-closed (brief step 5, decision row 17): `mutes == nil` means the
    /// mute store could not be read. RN would degrade to `[]` (an EMPTY mute
    /// list, which is unsafe here — it would let an actively-dismissed row
    /// resurrect). Native instead renders ONLY the five non-muteable
    /// (self-resolving) kinds, unfiltered — those kinds have no persisted
    /// mute state to begin with, so omitting mute-filtering for them cannot
    /// resurrect a dismissal. Muteable-kind rows are hidden entirely rather
    /// than risk showing a dismissed one.
    static func visibleInsights(
        all: [NativeTodayInsight],
        mutes: [NativeInsightMute]?,
        now: Date
    ) -> [NativeTodayInsight] {
        guard let mutes else {
            return Array(all.filter { !isMuteable($0.kind) }.prefix(visibleLimit))
        }
        let filtered = NativeInsightMutes.filterMuted(all, mutes: mutes, now: now) { $0.id }
        return Array(filtered.prefix(visibleLimit))
    }

    /// Whether the mute store was readable — controls whether dismiss/snooze
    /// controls render at all (fail-closed: no controls when we can't
    /// durably record their effect).
    static func mutesReadable(_ mutes: [NativeInsightMute]?) -> Bool { mutes != nil }

    /// `!!settings && state !== null && mutes !== null && isSetupComplete(...)
    /// && insights.length > 0`, PLUS decision row 18: hidden while the
    /// first-action hero is shown. `setupComplete` already folds in "checklist
    /// store unreadable → treated as incomplete" (brief step 5) — the caller
    /// computes that once and shares it with the checklist card's own gate.
    static func isVisible(
        setupComplete: Bool,
        hero: NativeTodayHero?,
        insights: [NativeTodayInsight]
    ) -> Bool {
        guard setupComplete, hero == nil else { return false }
        return !insights.isEmpty
    }
}
