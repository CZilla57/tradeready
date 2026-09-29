import Foundation

/// Clock-in/out session math, ported from `utils/timeTracking.ts`. Pure: the
/// caller injects `now`, so rollups and timer strings stay deterministic.
///
/// Sessions are mirrored into a dependency-free value type (the same approach
/// `NativeJobListChangeOrder` takes for change orders) because `Canonical.
/// TimeSession` carries preservation metadata that only the store may write.
struct NativeTimeSession: Equatable {
    /// ISO-8601 timestamp when the worker clocked in.
    let start: String
    /// ISO-8601 timestamp when they clocked out, or nil while still running.
    let end: String?
}

/// Rollup for the job-detail timer card. Field-for-field port of React Native's
/// `TimeTracking`, with exact `Decimal` durations instead of IEEE-754 ones.
struct NativeTimeTrackingSummary: Equatable {
    /// The still-running session (last entry with no end), or nil.
    let activeSession: NativeTimeSession?
    let isClocked: Bool
    /// Total logged milliseconds across all *ended* sessions.
    let completedMs: Double
    /// `completedMs` plus the running session's elapsed time when clocked in.
    let liveMs: Double
    /// Human readout — "H:MM:SS"/"M:SS" while running, "Hh MMm"/"Mm"/"0m" idle.
    let timer: String
    /// `liveMs` in hours.
    let trackedHours: Decimal
    /// The job's quoted labor hours — zero means "no estimate".
    let estimatedHours: Decimal
    /// `trackedHours − estimatedHours`, or nil when there is no estimate.
    let overUnder: Decimal?
    /// Ended sessions, plus one for the active session.
    let sessionCount: Int
}

/// Result of a successful clock-in: the new session list plus the status the
/// job must carry afterwards.
struct NativeTimeTrackingClockIn: Equatable {
    let sessions: [NativeTimeSession]
    /// `.scheduled` advances through the shared lifecycle chain; every other
    /// status is left exactly as it was.
    let status: JobLifecycleStatus
}

enum NativeTimeTrackingError: LocalizedError, Equatable {
    case sessionAlreadyRunning
    case noRunningSession
    case jobNotFound

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyRunning: "A timer is already running on this job."
        case .noRunningSession: "No timer is running on this job."
        case .jobNotFound: "The job no longer exists. Nothing was changed."
        }
    }
}

enum NativeTimeTracking {
    /// Job statuses during which the timer card is offered, mirroring
    /// `TIME_TRACKING_STATUSES`. "complete" and "invoiced" are included:
    /// finishing paperwork is still field time.
    static let offeredStatuses: Set<JobLifecycleStatus> = [
        .approved, .scheduled, .inProgress, .complete, .invoiced
    ]

    static func offers(for status: JobLifecycleStatus) -> Bool {
        offeredStatuses.contains(status)
    }

    /// The last session counts as active only while it has no end time. A
    /// missing end field is active for the same reason as an explicit nil.
    static func activeSession(in sessions: [NativeTimeSession]) -> NativeTimeSession? {
        guard let last = sessions.last, last.end == nil else { return nil }
        return last
    }

    /// Coarse elapsed-duration label: "2h 30m" / "45m" / "just now".
    static func elapsedLabel(milliseconds: Double) -> String {
        let totalMinutes = Int(floor(milliseconds / 60_000))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "just now"
    }

    static func summary(
        sessions: [NativeTimeSession],
        estimatedHours: Decimal,
        now: Date
    ) -> NativeTimeTrackingSummary {
        let active = activeSession(in: sessions)
        let completedMs = sessions.reduce(0.0) { total, session in
            guard let end = session.end else { return total }
            return total + durationMs(from: session.start, to: end)
        }
        let liveMs = active.map { completedMs + durationMs(from: $0.start, to: now) } ?? completedMs
        let trackedHours = Decimal(liveMs) / 3_600_000
        return NativeTimeTrackingSummary(
            activeSession: active,
            isClocked: active != nil,
            completedMs: completedMs,
            liveMs: liveMs,
            timer: timerText(liveMs: liveMs, isClocked: active != nil),
            trackedHours: trackedHours,
            estimatedHours: estimatedHours,
            overUnder: estimatedHours > 0 ? trackedHours - estimatedHours : nil,
            sessionCount: sessions.filter { $0.end != nil }.count + (active != nil ? 1 : 0)
        )
    }

    /// Appends a new open session. Returns nil only when a session is already
    /// running. Deliberately has no status guard: `offeredStatuses` already
    /// governs which statuses render the Clock In button, and done-job policy
    /// for the widget/Siri replay path belongs to that caller.
    static func clockIn(
        sessions: [NativeTimeSession],
        status: JobLifecycleStatus,
        at iso: String
    ) -> NativeTimeTrackingClockIn? {
        guard activeSession(in: sessions) == nil else { return nil }
        return NativeTimeTrackingClockIn(
            sessions: sessions + [NativeTimeSession(start: iso, end: nil)],
            status: status == .scheduled ? (status.next ?? status) : status
        )
    }

    /// Closes the last open session, clamping to its start when `iso` is
    /// earlier (clock skew, or a replayed widget/Siri action arriving out of
    /// order). Returns nil when nothing is running; earlier ended sessions are
    /// returned untouched.
    static func clockOut(sessions: [NativeTimeSession], at iso: String) -> [NativeTimeSession]? {
        guard let active = activeSession(in: sessions) else { return nil }
        let end = isEarlier(iso, than: active.start) ? active.start : iso
        var result = sessions
        result[result.count - 1] = NativeTimeSession(start: active.start, end: end)
        return result
    }

    // MARK: - Time

    /// Elapsed milliseconds from `start` to `now`; 0 when the timestamp cannot
    /// be parsed. React Native would produce NaN here, which would poison the
    /// whole readout, so an unreadable stamp contributes nothing instead.
    static func durationMs(from start: String, to now: Date) -> Double {
        guard let startDate = date(from: start) else { return 0 }
        return max(0, now.timeIntervalSince(startDate) * 1000)
    }

    /// Duration between two ISO timestamps; 0 when either cannot be parsed.
    static func durationMs(from start: String, to end: String) -> Double {
        guard let startDate = date(from: start), let endDate = date(from: end) else { return 0 }
        return max(0, endDate.timeIntervalSince(startDate) * 1000)
    }

    static func date(from value: String) -> Date? {
        isoWithFractional.date(from: value) ?? isoPlain.date(from: value)
    }

    /// The `new Date().toISOString()` wire shape — millisecond precision, UTC.
    /// Sessions written here stay byte-comparable with React Native's.
    static func timestamp(_ date: Date) -> String {
        isoWithFractional.string(from: date)
    }

    private static func isEarlier(_ candidate: String, than reference: String) -> Bool {
        if let candidateDate = date(from: candidate), let referenceDate = date(from: reference) {
            return candidateDate < referenceDate
        }
        // Unparseable stamps fall back to React Native's lexical comparison.
        return candidate < reference
    }

    private static func timerText(liveMs: Double, isClocked: Bool) -> String {
        let totalSeconds = Int(floor(max(0, liveMs) / 1000))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if isClocked {
            return hours > 0
                ? "\(hours):\(padded(minutes)):\(padded(seconds))"
                : "\(minutes):\(padded(seconds))"
        }
        if hours > 0 { return "\(hours)h \(padded(minutes))m" }
        return liveMs > 0 ? "\(minutes)m" : "0m"
    }

    private static func padded(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
