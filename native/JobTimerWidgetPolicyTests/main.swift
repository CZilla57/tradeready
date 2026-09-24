import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Job Timer widget tests (task 11.03, requirement W3).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale rules: a running timer stays visible with Stop enabled; the
// idle Start button is suppressed), §4.1-4.5 (action shapes, owner-tagged
// pending-action precedence), §6.1 (deep-link grammar). RN oracle:
// `targets/widget/JobTimer.swift`'s `JobTimerState`/`lastPendingTimerType`.
//
// Two halves:
// 1. `JobTimerWidgetPolicy.resolveState`/`deepLinkURL`/`lastPendingTimerType`
//    — pure Foundation fixtures, no App Group needed.
// 2. Start/stop and double-tap idempotency, driven through the REAL 11.04
//    `WidgetIntentEngine` and proven against the REAL
//    `NativeWidgetActionBatchPlanner` (compiled in from
//    `N/NativeWidgetActionReplay.swift`), never a reimplementation.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(actual)")
    }
}

// MARK: - Fixtures

private let phoenix: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}()
private let phoenixZone = TimeZone(identifier: "America/Phoenix")!

/// Same pinned instant as `native/WidgetSnapshotTests/main.swift` and
/// `native/NextJobWidgetPolicyTests/main.swift`: RN's
/// `NOW = new Date(2026, 7, 3, 12, 0, 0)` under `TZ=America/Phoenix`
/// (UTC−7, no DST) = 2026-08-03T19:00:00Z = local Aug 3, 12:00 noon.
private let now = ISO8601DateFormatter().date(from: "2026-08-03T19:00:00Z")!
private let today = "2026-08-03"

/// 64-hex, so the real planner's `verifiedAccountBinding` guard accepts it.
/// Task 11.05 (§4.5): the planner now keeps only actions stamped
/// `NativeWidgetOwnerTag.make(binding:)` of the binding it plans for, so the
/// fixture tag is derived from the binding exactly as the app mirror does.
private let ownerBinding = String(repeating: "ab", count: 32)
private let ownerTag = NativeWidgetOwnerTag.make(binding: ownerBinding)
private let otherOwnerTag = String(repeating: "cd", count: 32)

private func iso(_ date: Date) -> String { WidgetSnapshot.isoTimestamp(date) }

private let j9 = WidgetSnapshot.NextJob(
    id: "j9", customerName: "Alice Johnson", title: "Fence repair",
    scheduledDate: today, scheduledStartTime: "10:30", address: "12 Oak St"
)
private let j2Timer = WidgetSnapshot.TimerState(
    jobId: "j2", jobTitle: "Deck build", customerName: "Bob Smith", startedAt: "2026-08-03T10:00:00.000Z"
)

private func snapshot(
    updatedAt: Date = now.addingTimeInterval(-60),
    nextJob: WidgetSnapshot.NextJob? = nil,
    timer: WidgetSnapshot.TimerState? = nil,
    tag: String? = ownerTag
) -> WidgetSnapshot {
    WidgetSnapshot(updatedAt: iso(updatedAt), nextJob: nextJob, timer: timer, outstandingTotal: 0, ownerTag: tag)
}

private func pendingQueueJSON(_ entries: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: entries)
    return String(data: data, encoding: .utf8)!
}

private func timerAction(_ type: String, tag: String) -> [String: Any] {
    ["id": UUID().uuidString, "type": type, "at": iso(now), "ownerTag": tag]
}

// MARK: - resolveState: missing snapshot

private func testMissingSnapshot() {
    expectEqual(
        JobTimerWidgetPolicy.resolveState(snapshot: nil, pendingActionsJSON: nil, now: now, calendar: phoenix),
        .missing,
        "no snapshot (missing key or undecodable JSON) resolves to .missing"
    )
}

// MARK: - resolveState: running takes precedence over staleness (§3.3)

private func testRunningStaysVisibleWhenStale() {
    let since = WidgetSnapshot.parseISODate(j2Timer.startedAt)!

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: now.addingTimeInterval(-60), timer: j2Timer),
            pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .running(j2Timer, since: since),
        "a fresh snapshot with a running timer resolves to .running"
    )

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: now.addingTimeInterval(-90_000), timer: j2Timer),
            pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .running(j2Timer, since: since),
        "§3.3: a running timer stays visible even when the snapshot itself is stale"
    )
}

// MARK: - resolveState: stale + no timer suppresses the idle Start button (§3.3)

private func testSyncNeededWhenStaleWithNoTimer() {
    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: now.addingTimeInterval(-86_401), nextJob: j9),
            pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .syncNeeded,
        "§3.3: stale + no timer suppresses Start even though there is a next job — 'Open app to sync'"
    )

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: now.addingTimeInterval(-86_401), nextJob: nil),
            pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .syncNeeded,
        "stale + no timer + no next job is still .syncNeeded, not .noJob"
    )

    // Boundary parity with 11.02: exactly 86,400s is fresh.
    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: now.addingTimeInterval(-86_400), nextJob: j9),
            pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .idle(j9),
        "age exactly 86,400s is fresh (§3.3 boundary)"
    )
}

// MARK: - resolveState: idle / no-job, including the "separately from staleness" rule

private func testIdleAndNoJob() {
    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(nextJob: j9), pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .idle(j9),
        "fresh, no timer, an upcoming job → .idle"
    )

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(nextJob: nil), pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .noJob,
        "fresh, no timer, no next job → .noJob"
    )

    let yesterdayJob = WidgetSnapshot.NextJob(
        id: "j5", customerName: "Dana Lee", title: "Gutter clean",
        scheduledDate: "2026-08-02", scheduledStartTime: nil, address: ""
    )
    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot(nextJob: yesterdayJob), pendingActionsJSON: nil, now: now, calendar: phoenix
        ),
        .noJob,
        "§3.3: a fresh snapshot whose nextJob.scheduledDate is before local today is .noJob, not .idle"
    )
}

// MARK: - resolveState: owner-tagged pending-action precedence (§4.5)

private func testPendingActionPrecedence() {
    let runningSnapshot = snapshot(timer: j2Timer)
    let idleSnapshot = snapshot(nextJob: j9)

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: runningSnapshot,
            pendingActionsJSON: pendingQueueJSON([timerAction("timer_stop", tag: ownerTag)]),
            now: now, calendar: phoenix
        ),
        .pendingStop,
        "a queued, owner-tagged stop overrides an otherwise-running snapshot"
    )

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: idleSnapshot,
            pendingActionsJSON: pendingQueueJSON([timerAction("timer_start", tag: ownerTag)]),
            now: now, calendar: phoenix
        ),
        .pendingStart,
        "a queued, owner-tagged start overrides an otherwise-idle snapshot"
    )

    expectEqual(
        JobTimerWidgetPolicy.resolveState(
            snapshot: runningSnapshot,
            pendingActionsJSON: pendingQueueJSON([timerAction("timer_stop", tag: otherOwnerTag)]),
            now: now, calendar: phoenix
        ),
        .running(j2Timer, since: WidgetSnapshot.parseISODate(j2Timer.startedAt)!),
        "§4.5: a foreign-owner-tagged action is not a pending change — replay would drop it unapplied"
    )

    // Last one wins (RN `lastPendingTimerType`), only counting this owner's entries.
    let startThenStop = pendingQueueJSON([
        timerAction("timer_start", tag: ownerTag),
        timerAction("timer_stop", tag: ownerTag),
    ])
    expectEqual(
        JobTimerWidgetPolicy.resolveState(snapshot: idleSnapshot, pendingActionsJSON: startThenStop, now: now, calendar: phoenix),
        .pendingStop,
        "start then stop: the later queued action wins"
    )

    let stopThenStart = pendingQueueJSON([
        timerAction("timer_stop", tag: ownerTag),
        timerAction("timer_start", tag: ownerTag),
    ])
    expectEqual(
        JobTimerWidgetPolicy.resolveState(snapshot: idleSnapshot, pendingActionsJSON: stopThenStart, now: now, calendar: phoenix),
        .pendingStart,
        "stop then start: the later queued action wins"
    )

    expect(
        JobTimerWidgetPolicy.lastPendingTimerType(pendingActionsJSON: "not json", ownerTag: ownerTag) == nil,
        "a malformed queue read for display purposes degrades to nil (no pending action), never a crash"
    )
    expect(
        JobTimerWidgetPolicy.lastPendingTimerType(pendingActionsJSON: nil, ownerTag: ownerTag) == nil,
        "no queue means no pending action"
    )
    expect(
        JobTimerWidgetPolicy.lastPendingTimerType(pendingActionsJSON: pendingQueueJSON([timerAction("timer_start", tag: ownerTag)]), ownerTag: nil) == nil,
        "no owner tag on the snapshot means no pending action can be attributed to it"
    )
}

// MARK: - deepLinkURL: §6.1 grammar round trip through the real parser

private func testDeepLinkRoundTrip() {
    let runningState = JobTimerWidgetState.running(j2Timer, since: now)
    guard let runningURL = JobTimerWidgetPolicy.deepLinkURL(for: runningState) else {
        return expect(false, "a running state produces a deep link")
    }
    expectEqual(
        NativeDeepLinkParser.parse(runningURL.absoluteString), .job(id: j2Timer.jobId),
        "the running state's fallback URL round-trips through the real parser to the timer's own job"
    )

    guard let idleURL = JobTimerWidgetPolicy.deepLinkURL(for: .idle(j9)) else {
        return expect(false, "an idle state produces a deep link")
    }
    expectEqual(
        NativeDeepLinkParser.parse(idleURL.absoluteString), .job(id: j9.id),
        "the idle state's fallback URL round-trips through the real parser to the upcoming job"
    )

    for state: JobTimerWidgetState in [.missing, .pendingStop, .pendingStart, .noJob, .syncNeeded] {
        expect(
            JobTimerWidgetPolicy.deepLinkURL(for: state) == nil,
            "\(state) produces no deep link — WidgetKit falls back to opening the app root"
        )
    }
}

// MARK: - nextRefreshDate: reuses 11.02's snapshot-generic staleness math

private func testNextRefreshDateReusesNextJobPolicy() {
    let recent = snapshot(updatedAt: now.addingTimeInterval(-82_800))
    expectEqual(
        JobTimerWidgetPolicy.nextRefreshDate(snapshot: recent, now: now, calendar: phoenix),
        NextJobWidgetPolicy.nextRefreshDate(snapshot: recent, now: now, calendar: phoenix),
        "Job Timer's refresh date is NextJobWidgetPolicy's — one staleness-window implementation, not two"
    )
    expect(
        JobTimerWidgetPolicy.nextRefreshDate(snapshot: nil, now: now, calendar: phoenix) == nil,
        "no snapshot means no self-scheduled refresh"
    )
}

// MARK: - Engine-driven: start/stop are exactly what the real planner accepts

private final class InMemoryWidgetStore: WidgetAppGroupKeyValueStore {
    var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func string(forKey defaultName: String) -> String? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? String }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

private final class FixedIDSource {
    private var next = 0
    var fixed: String?
    func make() -> String {
        if let fixed { return fixed }
        next += 1
        return String(format: "00000000-0000-4000-8000-%012d", next)
    }
}

private func tempLockFile(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1103-\(label)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(WidgetAppGroup.lockFileName)
}

private struct EngineHarness {
    let store: InMemoryWidgetStore
    let ids = FixedIDSource()

    init(nextJob: WidgetSnapshot.NextJob? = j9, timer: WidgetSnapshot.TimerState? = nil) {
        let snap = snapshot(nextJob: nextJob, timer: timer)
        store = InMemoryWidgetStore([WidgetAppGroup.snapshotKey: try! snap.encodedJSON()])
    }

    var engine: WidgetIntentEngine {
        let ids = ids
        return WidgetIntentEngine(environment: WidgetIntentEnvironment(
            store: store, lockFile: tempLockFile("engine"), now: { now }, makeActionID: { ids.make() }, timeZone: phoenixZone
        ))
    }

    var queueRaw: String? { store.values[WidgetAppGroup.actionsKey] }

    var queueCount: Int {
        guard let raw = queueRaw, case .array(let values)? = WidgetJSONValue.decodeJSON(raw) else { return 0 }
        return values.count
    }
}

/// Runs the REAL planner over the stored queue text — the same oracle
/// `native/AppIntentQueueTests/main.swift` (task 11.04) uses.
private func plan(_ raw: String?) -> Result<NativeWidgetActionBatch, NativeWidgetActionBatchError> {
    do {
        return .success(try NativeWidgetActionBatchPlanner.prepare(rawValue: raw ?? "[]", verifiedAccountBinding: ownerBinding))
    } catch let error as NativeWidgetActionBatchError {
        return .failure(error)
    } catch {
        return .failure(.malformedQueue)
    }
}

private extension Result where Failure == NativeWidgetActionBatchError {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

private func testStartAndStopProducePlannerValidJSON() {
    let h = EngineHarness()
    guard case .queued = h.engine.startTimer(jobID: "j9") else {
        return expect(false, "startTimer queues against a fresh, owned snapshot")
    }
    guard case .queued = h.engine.stopTimer(jobID: "j9") else {
        return expect(false, "stopTimer queues against a fresh, owned snapshot")
    }
    expectEqual(h.queueCount, 2, "two button taps append exactly two actions")

    guard case .success(let batch) = plan(h.queueRaw) else {
        return expect(false, "the real NativeWidgetActionBatchPlanner accepts the widget-written queue")
    }
    expectEqual(batch.actions.map(\.kind), [.timerStart, .timerStop], "the batch decodes as exactly timer_start then timer_stop")
}

private func testDoubleTapIsIdempotentSafe() {
    // Start, tapped twice with the same underlying action id (the real
    // failure mode a double tap risks: the OS delivering the intent twice
    // before the first `reloadAllTimelines()` lands).
    var h = EngineHarness()
    h.ids.fixed = "00000000-0000-4000-8000-00000000abcd"
    guard case .queued = h.engine.startTimer(jobID: "j9") else {
        return expect(false, "first Start tap queues")
    }
    guard case .alreadyQueued = h.engine.startTimer(jobID: "j9") else {
        return expect(false, "a duplicate Start tap (same action id) is an idempotent success, not a second entry")
    }
    expectEqual(h.queueCount, 1, "an identical duplicate start appends nothing")
    expect(plan(h.queueRaw).isSuccess, "the deduplicated queue stays planner-valid")

    // Stop, same story, on a running timer.
    h = EngineHarness(nextJob: nil, timer: j2Timer)
    h.ids.fixed = "00000000-0000-4000-8000-00000000beef"
    guard case .queued = h.engine.stopTimer(jobID: "j2") else {
        return expect(false, "first Stop tap queues")
    }
    guard case .alreadyQueued = h.engine.stopTimer(jobID: "j2") else {
        return expect(false, "a duplicate Stop tap (same action id) is an idempotent success, not a second entry")
    }
    expectEqual(h.queueCount, 1, "an identical duplicate stop appends nothing")
    guard case .success(let batch) = plan(h.queueRaw) else {
        return expect(false, "the deduplicated stop queue is planner-valid")
    }
    expectEqual(batch.actions.map(\.kind), [.timerStop], "exactly one timer_stop survives the double tap")
}

// MARK: - Main

@main
struct JobTimerWidgetPolicyTests {
    static func main() {
        testMissingSnapshot()
        testRunningStaysVisibleWhenStale()
        testSyncNeededWhenStaleWithNoTimer()
        testIdleAndNoJob()
        testPendingActionPrecedence()
        testDeepLinkRoundTrip()
        testNextRefreshDateReusesNextJobPolicy()
        testStartAndStopProducePlannerValidJSON()
        testDoubleTapIsIdempotentSafe()

        if failures > 0 {
            print("Job Timer widget tests: \(failures) failure(s)")
            exit(1)
        }
        print("Job Timer widget tests passed")
    }
}
