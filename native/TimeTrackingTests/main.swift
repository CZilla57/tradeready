import Foundation

// Fixtures ported from `__tests__/timeTracking.test.js`. All timestamps are UTC
// and `now` is injected, so every rollup is deterministic.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private let minuteMs = 60_000.0
private let hourMs = 3_600_000.0

private func session(_ start: String, _ end: String? = nil) -> NativeTimeSession {
    NativeTimeSession(start: start, end: end)
}

private func date(_ iso: String) -> Date {
    NativeTimeTracking.date(from: iso)!
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func close(_ value: Double, _ expected: Double, tolerance: Double = 0.000_001) -> Bool {
    abs(value - expected) < tolerance
}

@main
struct TimeTrackingTests {
    static func main() {
        // MARK: - getActiveSession

        expect(NativeTimeTracking.activeSession(in: []) == nil, "no sessions has no active session")
        expect(
            NativeTimeTracking.activeSession(in: [session("a", "b")]) == nil,
            "all sessions ended leaves nothing active"
        )
        let active = session("z")
        expect(
            NativeTimeTracking.activeSession(in: [session("a", "b"), active]) == active,
            "last session without an end is active"
        )
        expect(
            NativeTimeTracking.activeSession(in: [session("z", nil)]) == active,
            "an explicit nil end also counts as active"
        )

        // MARK: - formatElapsed

        expect(NativeTimeTracking.elapsedLabel(milliseconds: 0) == "just now",
               "zero elapsed is 'just now'")
        expect(NativeTimeTracking.elapsedLabel(milliseconds: 59 * 1000) == "just now",
               "under a minute is 'just now'")
        expect(NativeTimeTracking.elapsedLabel(milliseconds: minuteMs) == "1m", "one minute reads 1m")
        expect(NativeTimeTracking.elapsedLabel(milliseconds: 30 * minuteMs) == "30m", "30 minutes reads 30m")
        expect(NativeTimeTracking.elapsedLabel(milliseconds: hourMs) == "1h 0m", "one hour reads 1h 0m")
        expect(NativeTimeTracking.elapsedLabel(milliseconds: hourMs + 30 * minuteMs) == "1h 30m",
               "hour and minutes read 1h 30m")

        // MARK: - computeTimeTracking

        let idle = NativeTimeTracking.summary(sessions: [], estimatedHours: 2, now: date("2026-07-04T00:00:01Z"))
        expect(idle.activeSession == nil && !idle.isClocked
               && idle.completedMs == 0 && idle.liveMs == 0
               && idle.timer == "0m" && idle.trackedHours == 0
               && idle.overUnder == -2 && idle.sessionCount == 0,
               "no sessions is idle and zeroed, with the estimate driving the variance")

        let ended = [session("2026-07-04T09:00:00.000Z", "2026-07-04T10:30:00.000Z")]
        let rolledUp = NativeTimeTracking.summary(
            sessions: ended, estimatedHours: 2, now: date("2026-07-04T12:00:00.000Z")
        )
        expect(!rolledUp.isClocked
               && close(rolledUp.completedMs, 90 * minuteMs)
               && close(rolledUp.liveMs, 90 * minuteMs)
               && rolledUp.timer == "1h 30m"
               && rolledUp.trackedHours == decimal("1.5")
               && rolledUp.overUnder == decimal("-0.5")
               && rolledUp.sessionCount == 1,
               "one ended session rolls up into an idle Hh MMm readout")

        let running = session("2026-07-04T10:30:00.000Z")
        let clocked = NativeTimeTracking.summary(
            sessions: [session("2026-07-04T08:00:00.000Z", "2026-07-04T09:00:00.000Z"), running],
            estimatedHours: 2,
            now: date("2026-07-04T11:00:00.000Z")
        )
        expect(clocked.isClocked && clocked.activeSession == running
               && close(clocked.completedMs, hourMs)
               && close(clocked.liveMs, hourMs + 30 * minuteMs)
               && clocked.timer == "1:30:00"
               && clocked.sessionCount == 2,
               "a running session adds live time and switches to an H:MM:SS readout")

        let shortSession = NativeTimeTracking.summary(
            sessions: [session("2026-07-04T11:00:00.000Z")],
            estimatedHours: 0,
            now: date("2026-07-04T11:05:30.000Z")
        )
        expect(shortSession.timer == "5:30" && shortSession.sessionCount == 1,
               "a running session under an hour uses M:SS")

        expect(
            NativeTimeTracking.summary(
                sessions: [session("2026-07-04T09:00:00.000Z", "2026-07-04T10:00:00.000Z")],
                estimatedHours: 0,
                now: date("2026-07-04T10:00:00.000Z")
            ).overUnder == nil,
            "without an estimate the variance is unavailable"
        )

        let unreadable = NativeTimeTracking.summary(
            sessions: [session("not-a-timestamp", "2026-07-04T10:00:00.000Z")],
            estimatedHours: 0,
            now: date("2026-07-04T10:00:00.000Z")
        )
        expect(unreadable.completedMs == 0 && unreadable.liveMs == 0 && unreadable.timer == "0m",
               "an unreadable timestamp contributes nothing instead of a NaN rollup")

        // MARK: - TIME_TRACKING_STATUSES

        for status in [JobLifecycleStatus.approved, .scheduled, .inProgress, .complete, .invoiced] {
            expect(NativeTimeTracking.offers(for: status), "\(status.rawValue) offers time tracking")
        }
        for status in [JobLifecycleStatus.lead, .estimateSent, .paid, .declined] {
            expect(!NativeTimeTracking.offers(for: status), "\(status.rawValue) hides time tracking")
        }

        // MARK: - clockIn

        let started = NativeTimeTracking.clockIn(
            sessions: [], status: .scheduled, at: "2026-07-04T09:00:00.000Z"
        )
        expect(started?.sessions == [session("2026-07-04T09:00:00.000Z")],
               "clock in appends one open session")
        expect(started?.status == .inProgress,
               "clock in advances scheduled through the shared lifecycle chain")

        for status in [JobLifecycleStatus.approved, .complete, .invoiced, .paid, .declined] {
            let applied = NativeTimeTracking.clockIn(
                sessions: [], status: status, at: "2026-07-04T09:00:00.000Z"
            )
            expect(applied?.status == status && applied?.sessions.count == 1,
                   "clock in on \(status.rawValue) starts the timer without touching status")
        }

        expect(
            NativeTimeTracking.clockIn(
                sessions: [session("2026-07-04T08:00:00.000Z")],
                status: .inProgress,
                at: "2026-07-04T09:00:00.000Z"
            ) == nil,
            "clock in refuses when a session is already running"
        )

        let existing = [session("2026-07-04T08:00:00.000Z", "2026-07-04T08:30:00.000Z")]
        _ = NativeTimeTracking.clockIn(sessions: existing, status: .inProgress, at: "2026-07-04T09:00:00.000Z")
        expect(existing == [session("2026-07-04T08:00:00.000Z", "2026-07-04T08:30:00.000Z")],
               "clock in never mutates the caller's sessions")

        // MARK: - clockOut

        let closing = [session("2026-07-04T09:00:00.000Z")]
        expect(
            NativeTimeTracking.clockOut(sessions: closing, at: "2026-07-04T10:00:00.000Z")
                == [session("2026-07-04T09:00:00.000Z", "2026-07-04T10:00:00.000Z")],
            "clock out closes the running session with the given end"
        )
        expect(
            NativeTimeTracking.clockOut(sessions: closing, at: "2026-07-04T08:00:00.000Z")
                == [session("2026-07-04T09:00:00.000Z", "2026-07-04T09:00:00.000Z")],
            "clock out clamps an earlier end to the session start"
        )
        expect(NativeTimeTracking.clockOut(sessions: [], at: "2026-07-04T10:00:00.000Z") == nil,
               "clock out with no sessions does nothing")
        expect(
            NativeTimeTracking.clockOut(
                sessions: [session("a", "b")], at: "2026-07-04T10:00:00.000Z"
            ) == nil,
            "clock out with nothing running does nothing"
        )
        let earlierClosed = session("2026-07-04T07:00:00.000Z", "2026-07-04T08:00:00.000Z")
        let closedBoth = NativeTimeTracking.clockOut(
            sessions: [earlierClosed, closing[0]], at: "2026-07-04T10:00:00.000Z"
        )
        expect(closedBoth?.first == earlierClosed,
               "clock out leaves earlier ended sessions untouched")

        // MARK: - wire timestamps

        let stamp = NativeTimeTracking.timestamp(date("2026-07-04T09:00:00.250Z"))
        expect(stamp == "2026-07-04T09:00:00.250Z",
               "clock timestamps use the React Native millisecond UTC wire shape")
        expect(NativeTimeTracking.date(from: stamp) == date("2026-07-04T09:00:00.250Z"),
               "written timestamps round-trip through the shared parser")
        expect(NativeTimeTracking.date(from: "2026-07-04T09:00:00Z") != nil,
               "a timestamp without fractional seconds still parses")

        if failures == 0 {
            print("PASS: native time tracking tests")
        } else {
            print("\(failures) native time tracking test(s) failed")
            exit(1)
        }
    }
}
