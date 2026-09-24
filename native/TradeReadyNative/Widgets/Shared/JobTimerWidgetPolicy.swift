import Foundation

// Task 11.03 (W3): Job Timer widget policy — pure Foundation, compiled into
// BOTH the app and the TradeReadyWidgets extension via this folder's shared
// synchronized root (11.01 §7 placement rule). State resolution (including
// the queued-action precedence) and the deep-link URL live here so
// `JobTimerWidgetView` (also Shared) and `JobTimerProvider`
// (`native/TradeReadyWidgets/JobTimerWidget.swift`, extension-only) only
// render/wire what this resolves — no policy in SwiftUI or in the provider.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale rules for the Job Timer widget specifically: a running timer
// stays visible with Stop enabled; the idle Start button is suppressed),
// §4.5 (owner stamping: only entries tagged for this snapshot's owner count
// toward "on the clock", matching what replay will actually apply),
// §6.1 (deep-link grammar, `N/NativeDeepLinkParser.swift`).
//
// RN oracle: `targets/widget/JobTimer.swift`'s `JobTimerState` (running /
// pendingStop / pendingStart / idle / empty) and `lastPendingTimerType`.
// This adds `.missing` and `.syncNeeded` for the native-only staleness rule
// (§3.3), which RN's widget never applied (it doesn't read `updatedAt`).

/// The Job Timer widget's resolved display state. Exactly one case renders
/// at a time; `JobTimerWidgetView` switches on it and adds no logic of its
/// own. Precedence (highest first): a queued action beats the mirrored
/// timer (it is fresher local truth than a snapshot that hasn't replayed
/// yet); a mirrored running timer beats staleness (§3.3: "stays visible");
/// staleness beats the idle/no-job split (§3.3: "Start button is
/// suppressed").
enum JobTimerWidgetState: Equatable {
    /// No `widgetSnapshot` key, or the stored value does not decode.
    case missing
    /// A session is running per the snapshot, with nothing queued against it.
    case running(WidgetSnapshot.TimerState, since: Date)
    /// A stop is queued (§4.5 owner-tagged): elapsed is frozen until the app
    /// replays it. Shown regardless of the snapshot's own staleness — the
    /// queued action is newer than whatever the mirror last said.
    case pendingStop
    /// A start is queued (§4.5 owner-tagged): the session doesn't exist in
    /// the mirror yet.
    case pendingStart
    /// Fresh, nothing running or queued, and there is a job worth clocking
    /// into (§3.3's "separately from staleness" scheduledDate rule applies).
    case idle(WidgetSnapshot.NextJob)
    /// Fresh, nothing running or queued, and nothing scheduled.
    case noJob
    /// Stale (§3.3) with no running session: the idle Start button is
    /// suppressed rather than offered against a mirror that might already
    /// be wrong. "Open app to sync" — never a specific job or customer.
    case syncNeeded
}

enum JobTimerWidgetPolicy {
    /// Resolves the display state from a raw App Group read. `pendingActionsJSON`
    /// is the raw `widgetActions` string (or nil); reading it for display does
    /// not require the advisory lock (§4.5 binds writers building an action,
    /// not a read-only timeline render).
    static func resolveState(
        snapshot: WidgetSnapshot?,
        pendingActionsJSON: String?,
        now: Date,
        calendar: Calendar = .current
    ) -> JobTimerWidgetState {
        guard let snapshot else { return .missing }

        switch lastPendingTimerType(pendingActionsJSON: pendingActionsJSON, ownerTag: snapshot.ownerTag) {
        case .timerStop: return .pendingStop
        case .timerStart: return .pendingStart
        case .tripLog, .expenseLog, nil: break
        }

        if let timer = snapshot.timer {
            let since = WidgetSnapshot.parseISODate(timer.startedAt) ?? now
            return .running(timer, since: since)
        }
        if snapshot.isStale(now: now) { return .syncNeeded }
        guard let job = snapshot.nextJob, isUpcoming(job, now: now, calendar: calendar) else { return .noJob }
        return .idle(job)
    }

    /// RN `lastPendingTimerType`/`siriIsOnTheClock` (§4.5): the most recent
    /// queued timer action for THIS snapshot's owner, last one wins. Only
    /// owner-tagged entries count — replay drops every other entry
    /// unapplied, so an untagged or foreign action is not a pending change.
    static func lastPendingTimerType(
        pendingActionsJSON: String?,
        ownerTag: String?
    ) -> WidgetPendingActionType? {
        guard let ownerTag, let pendingActionsJSON,
              case .array(let values)? = WidgetJSONValue.decodeJSON(pendingActionsJSON)
        else { return nil }

        var last: WidgetPendingActionType?
        for value in values {
            guard case .object(let fields) = value,
                  fields["ownerTag"]?.stringValue == ownerTag,
                  let typeRaw = fields["type"]?.stringValue,
                  let type = WidgetPendingActionType(rawValue: typeRaw),
                  type == .timerStart || type == .timerStop
            else { continue }
            last = type
        }
        return last
    }

    /// `tradeready://job/<id>` (§6.1), for the states that carry a job:
    /// `.running` deep-links its own job, `.idle` deep-links the upcoming
    /// job. Every other state opens the app root (WidgetKit's default for a
    /// nil `widgetURL`) — the read-only fallback for when interactive
    /// widgets are unavailable. Reuses `NextJobWidgetPolicy.deepLinkURL`:
    /// no second encoder (11.03 brief).
    static func deepLinkURL(for state: JobTimerWidgetState) -> URL? {
        switch state {
        case .running(let timer, _):
            return NextJobWidgetPolicy.deepLinkURL(jobID: timer.jobId)
        case .idle(let job):
            return NextJobWidgetPolicy.deepLinkURL(jobID: job.id)
        case .missing, .pendingStop, .pendingStart, .noJob, .syncNeeded:
            return nil
        }
    }

    /// The staleness-deadline/next-midnight math is snapshot-generic (not
    /// Next-Job-specific despite the type name), so this reuses
    /// `NextJobWidgetPolicy.nextRefreshDate` rather than duplicating it.
    static func nextRefreshDate(
        snapshot: WidgetSnapshot?,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        NextJobWidgetPolicy.nextRefreshDate(snapshot: snapshot, now: now, calendar: calendar)
    }

    /// §3.3: a `nextJob` scheduled before local today is never "next".
    /// Duplicated in miniature from `WidgetIntentEngine.upcomingJob` (private
    /// there) and `NextJobWidgetPolicy` (same rule, its own case) because
    /// none of those are a shared, Foundation-only, cross-target home for a
    /// two-line date-string compare.
    private static func isUpcoming(_ job: WidgetSnapshot.NextJob, now: Date, calendar: Calendar) -> Bool {
        job.scheduledDate >= localDateString(now, calendar: calendar)
    }

    private static func localDateString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
