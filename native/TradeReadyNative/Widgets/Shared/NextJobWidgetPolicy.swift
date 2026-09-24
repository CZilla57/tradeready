import Foundation

// Task 11.02 (W2): Next Job widget policy — pure Foundation, compiled into
// BOTH the app and the TradeReadyWidgets extension via this folder's shared
// synchronized root (11.01 §7 placement rule). State resolution, the
// deep-link URL and the timeline refresh date all live here so
// `NextJobWidgetView` (also Shared) and `NextJobProvider`
// (`native/TradeReadyWidgets/NextJobWidget.swift`, extension-only) only
// render/wire what this resolves — no policy in SwiftUI or in the provider.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale window + the "separately from staleness" scheduledDate rule),
// §6.1 (deep-link grammar, `N/NativeDeepLinkParser.swift`).

/// The Next Job widget's resolved display state. Exactly one case renders at
/// a time; `NextJobWidgetView` switches on it and adds no logic of its own.
enum NextJobWidgetState: Equatable {
    /// No `widgetSnapshot` key, or the stored value does not decode. The
    /// 11.02 brief calls this "missing/blank"; `WidgetSnapshot.load` already
    /// collapses both cases to `nil`, so this is simply "snapshot == nil".
    case missing
    /// `WidgetSnapshot.isStale(now:)` is true (§3.3): age > 86,400 s, a
    /// negative age, or an unparseable `updatedAt`. No customer name or
    /// address, and no job deep link — the whole card opens the app root.
    case stale
    /// Fresh, and there is nothing upcoming: either `nextJob` is nil, or its
    /// `scheduledDate` is before local today (§3.3's rule, separate from
    /// staleness, for a fresh mirror the day has since rolled past).
    case noUpcomingJob
    /// Fresh, with an upcoming job to render and deep-link.
    case job(WidgetSnapshot.NextJob)
}

enum NextJobWidgetPolicy {
    /// Resolves the display state from a raw App Group read.
    static func resolveState(
        snapshot: WidgetSnapshot?,
        now: Date,
        calendar: Calendar = .current
    ) -> NextJobWidgetState {
        guard let snapshot else { return .missing }
        if snapshot.isStale(now: now) { return .stale }
        guard let job = snapshot.nextJob else { return .noUpcomingJob }
        guard job.scheduledDate >= localDateString(now, calendar: calendar) else { return .noUpcomingJob }
        return .job(job)
    }

    /// `tradeready://job/<id>` (§6.1). The id is percent-encoded (with `/`
    /// excluded from the allowed set, so an embedded `/` cannot smuggle a
    /// third path component) and never reformatted — no locale/format
    /// guessing, per the 11.02 brief. A host test feeds the result to the
    /// real `NativeDeepLinkParser.parse` to prove the round trip.
    static func deepLinkURL(jobID: String) -> URL? {
        guard !jobID.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = jobID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "tradeready://job/\(encoded)")
    }

    /// Contract §3.3: "Add an entry at `updatedAt + 86_400` (or the next
    /// local midnight, whichever is first) so the stale state appears
    /// without an app reload." Nil means no self-scheduled reload: the
    /// current entry stands until the app's own mirror write calls
    /// `WidgetCenter.shared.reloadAllTimelines()` (§3.1) — this policy never
    /// schedules background work on its own.
    ///
    /// Nil when the snapshot is missing or already stale (nothing left to
    /// schedule; the terminal state is already showing). Otherwise the
    /// earlier of the staleness deadline and the next local midnight — the
    /// same midnight boundary that flips a today-dated `.job` to
    /// `.noUpcomingJob` once the day rolls over (the "next job boundary").
    static func nextRefreshDate(
        snapshot: WidgetSnapshot?,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let snapshot,
              let updatedAt = snapshot.updatedAtDate,
              !snapshot.isStale(now: now)
        else { return nil }
        let staleDeadline = updatedAt.addingTimeInterval(WidgetSnapshot.staleAfterSeconds)
        let nextMidnight = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        return min(staleDeadline, nextMidnight)
    }

    /// RN `whenLabel` (`targets/widget/Widgets.swift:75-92`), with `now`
    /// injected instead of read live so it is host-testable. "Today"/
    /// "Tomorrow" compare `now`'s calendar day to the job's `startDate`;
    /// anything else falls back to "EEE, MMM d". A time suffix is appended
    /// only when the job has a `scheduledStartTime`. `locale` defaults to the
    /// device locale (RN sets none either); tests pin it for a deterministic
    /// time string.
    static func whenLabel(
        for job: WidgetSnapshot.NextJob,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale? = nil
    ) -> String {
        guard let start = job.startDate(timeZone: calendar.timeZone) else { return job.scheduledDate }

        let dayLabel: String
        if calendar.isDate(start, inSameDayAs: now) {
            dayLabel = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  calendar.isDate(start, inSameDayAs: tomorrow) {
            dayLabel = "Tomorrow"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = calendar
            dayFormatter.timeZone = calendar.timeZone
            dayFormatter.locale = locale
            dayFormatter.dateFormat = "EEE, MMM d"
            dayLabel = dayFormatter.string(from: start)
        }

        guard job.scheduledStartTime != nil else { return dayLabel }
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return "\(dayLabel) \u{00B7} \(timeFormatter.string(from: start))"
    }

    /// `getTodayDateString` equivalent: local `YYYY-MM-DD`, never
    /// `toISOString` (FA-039). Duplicated in miniature from
    /// `N/Domain/NativeWidgetSnapshot.swift` because that file is app-target
    /// only; this one must compile into the extension too.
    private static func localDateString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
