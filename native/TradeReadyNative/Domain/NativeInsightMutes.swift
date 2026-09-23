import Foundation

// MARK: - Insight mutes (task 10.03, requirements S4)
//
// Pure port of `utils/insightMutes.ts`: per-insight dismiss/snooze policy for the
// Today insights card. Mutes are DEVICE-LOCAL by design (they embed this
// account's record ids, so a stale mute leaking into the next account would
// silently hide its legitimate insights) and every date here is local-frame
// (FA-039): a snooze `until` is a local "YYYY-MM-DD" and expires once
// `today >= until`.

/// One stored mute. `until` absent = permanent dismiss.
struct NativeInsightMute: Codable, Equatable {
    var id: String
    /// ISO timestamp of when the mute was created (informational).
    var mutedAt: String
    /// Local "YYYY-MM-DD" the snooze expires; absent = permanent dismiss.
    var until: String?
}

enum NativeInsightMutes {
    /// The AsyncStorage key the React Native build used, kept as the on-disk
    /// filename so the store's identity is unambiguous in support exports.
    static let storageKey = "insightMutes"

    /// `makeMute` — `days` set (> 0) = snooze until today + days; otherwise a
    /// permanent dismiss with no `until` key at all.
    static func makeMute(id: String, now: Date, days: Int? = nil) -> NativeInsightMute {
        var mute = NativeInsightMute(
            id: id,
            mutedAt: ISO8601DateFormatter.nativeFractional.string(from: now),
            until: nil
        )
        if let days, days > 0 {
            mute.until = shift(dateString: NativeCashBasis.ymd(now), days: days)
        }
        return mute
    }

    /// `isMuteActive` — a permanent dismiss is always active; a snooze is active
    /// strictly before its `until` day.
    static func isMuteActive(_ mute: NativeInsightMute, today: String) -> Bool {
        guard let until = mute.until else { return true }
        return until > today
    }

    /// `filterMutedInsights` — drop actively-muted items, preserving order. Runs
    /// BEFORE the card's top-3 slice so muting a row promotes the next one.
    static func filterMuted<T>(
        _ items: [T],
        mutes: [NativeInsightMute],
        now: Date,
        id: (T) -> String
    ) -> [T] {
        guard !mutes.isEmpty else { return items }
        let active = activeMutedIDs(mutes, now: now)
        return items.filter { !active.contains(id($0)) }
    }

    /// The ids a set of mutes currently hides.
    static func activeMutedIDs(_ mutes: [NativeInsightMute], now: Date) -> Set<String> {
        let today = NativeCashBasis.ymd(now)
        return Set(mutes.filter { isMuteActive($0, today: today) }.map(\.id))
    }

    /// `pruneMutes` — keep only active mutes and, when `liveIDs` is provided, only
    /// ids the engine can still emit (bounds growth).
    static func prune(
        _ mutes: [NativeInsightMute],
        today: String,
        liveIDs: Set<String>? = nil
    ) -> [NativeInsightMute] {
        mutes.filter { mute in
            guard isMuteActive(mute, today: today) else { return false }
            guard let liveIDs else { return true }
            return liveIDs.contains(mute.id)
        }
    }

    /// `muteInsight` — the stored array after applying a new mute: prune (against
    /// the live ids when known), drop any existing mute for the same id, then
    /// append. One write, and a re-mute replaces instead of stacking.
    static func applying(
        id: String,
        now: Date,
        days: Int? = nil,
        liveIDs: Set<String>? = nil,
        to existing: [NativeInsightMute]
    ) -> [NativeInsightMute] {
        let today = NativeCashBasis.ymd(now)
        let kept = prune(existing, today: today, liveIDs: liveIDs).filter { $0.id != id }
        return kept + [makeMute(id: id, now: now, days: days)]
    }

    /// Read tolerance, mirroring `loadInsightMutes`: entries without a string id
    /// are dropped rather than failing the whole read.
    static func sanitized(_ mutes: [NativeInsightMute]) -> [NativeInsightMute] {
        mutes.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// `shiftDate` (`utils/dateHelpers.ts`) — local-frame, month-boundary safe.
    static func shift(dateString: String, days: Int) -> String {
        guard let date = NativeCashBasis.parseLocalDate(dateString) else { return dateString }
        let calendar = NativeCashBasis.localCalendar
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return dateString }
        return NativeCashBasis.ymd(shifted)
    }
}

extension ISO8601DateFormatter {
    /// `new Date().toISOString()` shape (fractional seconds, `Z`).
    static let nativeFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
