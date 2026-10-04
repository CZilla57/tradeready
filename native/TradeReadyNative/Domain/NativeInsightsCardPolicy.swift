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
    /// The other kinds deliberately have no dismiss/snooze affordance; they
    /// disappear on their own as their condition resolves. Phase 21's
    /// `warranty_expiring` is muteable (spec §4).
    ///
    /// Phase 32 (spec 2026-10-03 §6.8): `quote_expired` is dismiss-only (its
    /// id carries the date, so an extension re-arms it); `quote_expiring`
    /// resolves on its own and is not muteable.
    static let muteableKinds: Set<NativeInsightKind> = [
        .lowMarginEstimate, .maintenanceDue, .warrantyExpiring, .expenseAnomaly, .quoteExpired,
    ]

    /// `SNOOZE_DAYS` — `maintenance_due` (30 days) and Phase 21's
    /// `warranty_expiring` (14 days, spec §4) offer "Snooze"; the other
    /// muteable kinds are dismiss-only (their ids are already time/price/date
    /// scoped, so a plain dismiss naturally expires).
    static let snoozeDaysByKind: [NativeInsightKind: Int] = [.maintenanceDue: 30, .warrantyExpiring: 14]

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
        case .warrantyExpiring: return "shield.lefthalf.filled"
        case .expenseAnomaly: return "chart.line.uptrend.xyaxis"
        case .quoteExpiring: return "hourglass"
        case .quoteExpired: return "hourglass.bottomhalf.filled"
        }
    }

    /// `filterMutedInsights(all, mutes, now).slice(0, VISIBLE_LIMIT)` — mute
    /// filter runs BEFORE the top-3 slice, so muting a row promotes the next
    /// one into view.
    ///
    /// Fail-closed (brief step 5, decision row 17): `mutes == nil` means the
    /// mute store could not be read. RN would degrade to `[]` (an EMPTY mute
    /// list, which is unsafe here — it would let an actively-dismissed row
    /// resurrect). Native instead renders ONLY the non-muteable
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

    /// Fix round 1 (I3): the single gating decision for whether a row shows
    /// mute/snooze controls at all — `isMuteable(kind) && mutesReadable(mutes)`.
    /// Lives here (not ad hoc in `NativeInsightsCard.swift`) so the view has
    /// one call to make and the rule can't drift between the ellipsis button
    /// and any future mute-affordance. The "Why am I seeing this?" reason is
    /// NOT gated by this — every row offers it, muteable or not.
    static func muteControlsAvailable(for kind: NativeInsightKind, mutes: [NativeInsightMute]?) -> Bool {
        isMuteable(kind) && mutesReadable(mutes)
    }

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
