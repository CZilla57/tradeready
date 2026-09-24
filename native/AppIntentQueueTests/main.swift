import AppIntents
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// App Intents + action-queue contract tests (task 11.04, requirements A1–A3).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale refusals), §4.1–4.5 (action shapes, lock, writer rules,
// `activeTrip`, owner stamping), §5 (ten intents, phrases, expense AppEnum,
// membership, 17.0 floor), §6 (the `pendingOpenUrl` handoff).
// RN oracles: `targets/widget/_shared/SiriIntents.swift`,
// `targets/widget/JobTimer.swift`, `utils/widgetActions.ts`
// (`__tests__/widgetActions.test.js`).
//
// "Replay-planner-valid" is proven against the REAL
// `NativeWidgetActionBatchPlanner` and `NativeWidgetActionReplayer`
// (compiled in from `N/NativeWidgetActionReplay.swift`), never a copy.
// Every App Group touch uses a throwaway suite or an in-memory store plus a
// throwaway lock file: a plain `swiftc` binary has no App Group entitlement.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

// MARK: - Fixtures

private let phoenix = TimeZone(identifier: "America/Phoenix")!
private let posix = Locale(identifier: "en_US_POSIX")
/// RN `NOW = new Date(2026, 7, 3, 12, 0, 0)` in Phoenix = 2026-08-03T19:00:00Z.
private let now = ISO8601DateFormatter().date(from: "2026-08-03T19:00:00Z")!
/// 64-hex, so the real planner accepts it as `verifiedAccountBinding`.
private let ownerBinding = String(repeating: "ab", count: 32)
private let ownerTag = NativeWidgetOwnerTag.make(binding: ownerBinding)
private let otherTag = NativeWidgetOwnerTag.make(binding: "someone-else")
private let decoder = JSONDecoder()

private func iso(_ date: Date) -> String { WidgetSnapshot.isoTimestamp(date) }

private let j9 = WidgetSnapshot.NextJob(
    id: "j9", customerName: "Alice Johnson", title: "Fence repair",
    scheduledDate: "2026-08-04", scheduledStartTime: "10:30", address: "12 Oak St"
)
private let j2Timer = WidgetSnapshot.TimerState(
    jobId: "j2", jobTitle: "Deck build", customerName: "Bob Smith", startedAt: "2026-08-03T10:00:00.000Z"
)

private func snapshotJSON(
    updatedAt: Date = now.addingTimeInterval(-60),
    nextJob: WidgetSnapshot.NextJob? = j9,
    timer: WidgetSnapshot.TimerState? = nil,
    outstandingTotal: Double? = 160,
    ownerTag tag: String? = ownerTag
) -> String {
    try! WidgetSnapshot(
        updatedAt: iso(updatedAt), nextJob: nextJob, timer: timer,
        outstandingTotal: outstandingTotal, ownerTag: tag
    ).encodedJSON()
}

private func tempLockFile(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1104-\(label)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(WidgetAppGroup.lockFileName)
}

/// An in-memory App Group store that PROVES every access happens while the
/// §4.2 advisory lock is held: each access probes the lock file with
/// `LOCK_NB` on a separate descriptor, which only fails while another open
/// file description holds `LOCK_EX`.
private final class ProbingStore: WidgetAppGroupKeyValueStore {
    var values: [String: String]
    let lockFile: URL
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []
    private(set) var unlockedAccesses = 0

    init(_ values: [String: String] = [:], lockFile: URL) {
        self.values = values
        self.lockFile = lockFile
    }

    func string(forKey defaultName: String) -> String? {
        probe(); reads.append(defaultName)
        return values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        probe(); writes.append(defaultName)
        values[defaultName] = value as? String
    }

    func removeObject(forKey defaultName: String) {
        probe(); writes.append(defaultName)
        values[defaultName] = nil
    }

    func resetLog() { reads = []; writes = []; unlockedAccesses = 0 }

    private func probe() {
        try? FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { unlockedAccesses += 1; return }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            unlockedAccesses += 1
        }
    }
}

/// Deterministic UUID-shaped ids ("…0001", "…0002", …).
private final class IDSource {
    private var next = 0
    var fixed: String?
    func make() -> String {
        if let fixed { return fixed }
        next += 1
        return String(format: "00000000-0000-4000-8000-%012d", next)
    }
}

private final class Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private struct Harness {
    let store: ProbingStore
    let ids = IDSource()
    let clock: Clock

    init(snapshot: String? = snapshotJSON(), extra: [String: String] = [:], at date: Date = now) {
        var values = extra
        if let snapshot { values[WidgetAppGroup.snapshotKey] = snapshot }
        store = ProbingStore(values, lockFile: tempLockFile("probe"))
        clock = Clock(date)
    }

    var engine: WidgetIntentEngine {
        let clock = clock, ids = ids
        return WidgetIntentEngine(environment: WidgetIntentEnvironment(
            store: store,
            lockFile: store.lockFile,
            now: { clock.date },
            makeActionID: { ids.make() },
            timeZone: phoenix
        ))
    }

    var queueRaw: String? { store.values[WidgetAppGroup.actionsKey] }
    var trip: String? { store.values[WidgetAppGroup.activeTripKey] }
    var stash: String? { store.values[WidgetAppGroup.pendingOpenURLKey] }

    var queue: [[String: Any]] {
        guard let raw = queueRaw,
              let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        else { return [] }
        return parsed
    }
}

/// Runs the REAL planner over the stored queue text.
private func plan(_ raw: String?) -> Result<NativeWidgetActionBatch, NativeWidgetActionBatchError> {
    do {
        return .success(try NativeWidgetActionBatchPlanner.prepare(
            rawValue: raw ?? "[]", verifiedAccountBinding: ownerBinding
        ))
    } catch let error as NativeWidgetActionBatchError {
        return .failure(error)
    } catch {
        return .failure(.malformedQueue)
    }
}

private func planKinds(_ raw: String?) -> [NativeWidgetActionBatch.Kind]? {
    guard case .success(let batch) = plan(raw) else { return nil }
    return batch.actions.map(\.kind)
}

private func jsonKeys(_ object: [String: Any]) -> Set<String> { Set(object.keys) }

private func job(_ json: String) -> Canonical.Job {
    let base: [String: Any] = [
        "id": "j9", "customerId": "c1", "customerName": "Alice Johnson", "title": "Fence repair",
        "description": "", "status": "scheduled", "scheduledDate": "2026-08-04",
        "scheduledStartTime": "10:30", "scheduledEndTime": NSNull(), "address": "12 Oak St",
        "estimateTotal": 0, "laborHours": 0, "laborRate": 0, "materials": [], "materialMarkup": 0,
        "overhead": 0, "margin": 0, "notes": "", "invoiceId": NSNull(), "createdAt": "2026-08-01",
    ]
    var merged = base
    if let overrides = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
        merged.merge(overrides) { _, new in new }
    }
    let data = try! JSONSerialization.data(withJSONObject: merged)
    return try! decoder.decode(Canonical.Job.self, from: data)
}

// MARK: - 1. Timer intents (widget buttons; both targets)

private func testTimerIntents() {
    // Start: one tagged `timer_start`, planner-valid, written under the lock.
    var h = Harness()
    let started = h.engine.startTimer(jobID: "j9")
    guard case .queued(let action) = started else { return expect(false, "startTimer queues (got \(started))") }
    expect(started.wroteQueue, "a queued start reports a queue write (timelines reload outside the lock)")
    let entry = h.queue.first ?? [:]
    expectEqual(h.queue.count, 1, "startTimer appends exactly one action")
    expectEqual(jsonKeys(entry), ["id", "type", "at", "jobId", "ownerTag"], "timer_start carries exactly the §4.1 fields + ownerTag")
    expectEqual(entry["type"] as? String, "timer_start", "timer_start type")
    expectEqual(entry["jobId"] as? String, "j9", "timer_start jobId")
    expectEqual(entry["ownerTag"] as? String, ownerTag, "the action copies the snapshot's ownerTag (§4.5)")
    expectEqual(entry["at"] as? String, "2026-08-03T19:00:00.000Z", "at is the injected clock, ISO fractional")
    expectEqual(action.id, "00000000-0000-4000-8000-000000000001", "the action id comes from the id source")
    expectEqual(planKinds(h.queueRaw), [.timerStart], "the written queue is replay-planner-valid (timer_start)")
    expectEqual(h.store.unlockedAccesses, 0, "every store access of startTimer happens under the advisory lock")
    expect(!h.store.writes.contains(WidgetAppGroup.snapshotKey), "an intent never writes the snapshot")

    // Empty job id: nothing is written, the store is not even touched (RN parity).
    h = Harness()
    expectEqual(h.engine.startTimer(jobID: ""), .ignoredEmptyJobID, "an empty job id writes nothing")
    expect(h.store.reads.isEmpty && h.store.writes.isEmpty, "an empty-id start never touches the App Group")

    // Stop: jobId only when non-empty.
    h = Harness()
    _ = h.engine.stopTimer(jobID: "")
    _ = h.engine.stopTimer(jobID: "j2")
    expectEqual(h.queue.count, 2, "two stops append two actions")
    expectEqual(jsonKeys(h.queue[0]), ["id", "type", "at", "ownerTag"], "an empty-id stop omits jobId")
    expectEqual(h.queue[1]["jobId"] as? String, "j2", "a stop with an id carries jobId")
    expectEqual(planKinds(h.queueRaw), [.timerStop, .timerStop], "timer_stop actions are replay-planner-valid")
    expectEqual(h.store.unlockedAccesses, 0, "every store access of stopTimer happens under the lock")

    // Stale (§3.3): Start refuses (its button is hidden), Stop stays allowed.
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-86_401)))
    expectEqual(h.engine.startTimer(jobID: "j9"), .stale, "a stale snapshot refuses Start")
    expect(h.queueRaw == nil, "a refused Start writes nothing")
    guard case .queued = h.engine.stopTimer(jobID: "j2") else { return expect(false, "Stop is allowed when stale") }
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-86_400)))
    guard case .queued = h.engine.startTimer(jobID: "j9") else { return expect(false, "exactly 86,400 s is fresh") }

    // No owner (§4.5): refuse, write nothing.
    for (label, snapshot) in [
        ("no snapshot", nil),
        ("untagged snapshot", snapshotJSON(ownerTag: nil)),
        ("malformed tag", snapshotJSON(ownerTag: ownerTag.uppercased())),
        ("undecodable snapshot", #"{"version":1}"#),
    ] as [(String, String?)] {
        let refused = Harness(snapshot: snapshot)
        expectEqual(refused.engine.startTimer(jobID: "j9"), .failed(.signInRequired), "\(label) → Start refuses")
        expectEqual(refused.engine.stopTimer(jobID: "j9"), .failed(.signInRequired), "\(label) → Stop refuses")
        expect(refused.store.writes.isEmpty, "\(label) → nothing is written")
    }

    // No container / lock → unavailable, and nothing is written without the lock.
    let noLock = WidgetIntentEngine(environment: WidgetIntentEnvironment(
        store: ProbingStore([WidgetAppGroup.snapshotKey: snapshotJSON()], lockFile: tempLockFile("x")),
        lockFile: nil, now: { now }, makeActionID: { UUID().uuidString }, timeZone: phoenix
    ))
    expectEqual(noLock.startTimer(jobID: "j9"), .failed(.unavailable), "no lock file → unavailable")
    let noStore = WidgetIntentEngine(environment: WidgetIntentEnvironment(
        store: nil, lockFile: tempLockFile("y"), now: { now }, makeActionID: { UUID().uuidString }, timeZone: phoenix
    ))
    expectEqual(noStore.stopTimer(jobID: "j9"), .failed(.unavailable), "no suite → unavailable")
}

// MARK: - 2. Clock In / Clock Out (Siri)

private func testClockInOut() {
    // Clock in to the snapshot's next job; the second ask sees the pending start.
    var h = Harness()
    let clockedIn = h.engine.clockIn()
    guard case .clockedIn(let title, _) = clockedIn else { return expect(false, "clockIn clocks in (got \(clockedIn))") }
    expectEqual(title, "Fence repair", "clock in names the next job")
    expectEqual(SiriIntentDialogs.clockIn(clockedIn), "Clocked in to Fence repair.", "RN clock-in dialog")
    expectEqual(h.queue.first?["jobId"] as? String, "j9", "clock in queues timer_start for nextJob.id")
    expectEqual(h.engine.clockIn(), .alreadyClockedIn, "a pending start beats the snapshot (last action wins)")
    expectEqual(SiriIntentDialogs.clockIn(.alreadyClockedIn), "You're already clocked in.", "already-clocked-in dialog")
    expectEqual(h.queue.count, 1, "already clocked in → nothing appended")

    // Clock out with a pending start and no snapshot timer: no jobId.
    let out = h.engine.clockOut()
    guard case .clockedOut(let stop) = out else { return expect(false, "clockOut after a pending start (got \(out))") }
    expect(stop.fields["jobId"] == nil, "the snapshot has no timer, so the stop omits jobId (replay stops the one running job)")
    expectEqual(SiriIntentDialogs.clockOut(out), "Clocked out.", "clock-out dialog")
    expectEqual(h.engine.clockOut(), .notClockedIn, "a pending stop is the last word → not clocked in")
    expectEqual(SiriIntentDialogs.clockOut(.notClockedIn), "You're not clocked in.", "not-clocked-in dialog")
    expectEqual(planKinds(h.queueRaw), [.timerStart, .timerStop], "clock in/out actions are replay-planner-valid")
    expectEqual(h.store.unlockedAccesses, 0, "clock in/out read the snapshot and queue inside the append's lock hold")

    // Snapshot timer running, empty queue.
    h = Harness(snapshot: snapshotJSON(timer: j2Timer))
    expectEqual(h.engine.clockIn(), .alreadyClockedIn, "a snapshot timer means already clocked in")
    guard case .clockedOut(let stopJ2) = h.engine.clockOut() else { return expect(false, "clockOut with a snapshot timer") }
    expectEqual(stopJ2.fields["jobId"], .string("j2"), "clock out stops the snapshot timer's job")

    // Only this owner's pending actions count (replay drops the rest, §4.5).
    let foreignStart = #"[{"at":"2026-08-03T18:00:00.000Z","id":"legacy-1","jobId":"j9","type":"timer_start"},"#
        + #"{"at":"2026-08-03T18:00:00.000Z","id":"foreign-1","jobId":"j9","ownerTag":"\#(otherTag)","type":"timer_start"}]"#
    h = Harness(extra: [WidgetAppGroup.actionsKey: foreignStart])
    guard case .clockedIn = h.engine.clockIn() else {
        return expect(false, "an untagged or foreign pending start is not 'on the clock'")
    }
    expectEqual(h.engine.clockOut().wroteQueue, true, "…and this owner's own pending start is")

    // ClockIn refusals: stale, no job, a past job, no owner.
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-90_000)))
    expectEqual(h.engine.clockIn(), .stale, "stale → ClockIn refuses")
    expectEqual(SiriIntentDialogs.clockIn(.stale), "Open TradeReady to refresh your schedule.", "the §3.3 stale dialog")
    expect(h.queueRaw == nil, "a stale ClockIn writes nothing")
    h = Harness(snapshot: snapshotJSON(nextJob: nil))
    expectEqual(h.engine.clockIn(), .noUpcomingJob, "no next job → nothing to clock into")
    expectEqual(SiriIntentDialogs.clockIn(.noUpcomingJob), "No upcoming job to clock into.", "no-job dialog")
    var yesterday = j9; yesterday.scheduledDate = "2026-08-02"
    h = Harness(snapshot: snapshotJSON(nextJob: yesterday))
    expectEqual(h.engine.clockIn(), .noUpcomingJob, "a nextJob before local today is never 'next' (§3.3)")
    h = Harness(snapshot: nil)
    expectEqual(h.engine.clockIn(), .failed(.signInRequired), "no snapshot → ClockIn refuses")
    expectEqual(SiriIntentDialogs.clockIn(.failed(.signInRequired)), "Open TradeReady and sign in first.", "§4.5 dialog")

    // ClockOut is NOT refused when stale (§3.3).
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-90_000), timer: j2Timer))
    guard case .clockedOut = h.engine.clockOut() else { return expect(false, "ClockOut is allowed on a stale snapshot") }
}

// MARK: - 3. Writer rules: cap, malformed, duplicates, validation (§4.3)

private func taggedEntry(_ index: Int) -> String {
    #"{"at":"2026-08-03T18:00:00.000Z","id":"pre-\#(index)","ownerTag":"\#(ownerTag)","type":"timer_stop"}"#
}

private func testWriterRules() {
    // Cap: 511 → the 512th append succeeds; 512 → refused, bytes untouched.
    let q511 = "[" + (0..<511).map(taggedEntry).joined(separator: ",") + "]"
    var h = Harness(extra: [WidgetAppGroup.actionsKey: q511])
    guard case .queued = h.engine.stopTimer(jobID: "") else { return expect(false, "the 512th action is accepted") }
    expectEqual(h.queue.count, 512, "the queue may reach exactly 512")
    guard case .success(let full) = plan(h.queueRaw) else { return expect(false, "a 512-entry queue is planner-valid") }
    expectEqual(full.actions.count, 512, "the planner accepts all 512")
    let before512 = h.queueRaw
    expectEqual(h.engine.stopTimer(jobID: ""), .failed(.queueFull), "a 513th append is refused")
    expectEqual(h.queueRaw, before512, "a refused append leaves the queue byte-for-byte")
    expectEqual(SiriIntentDialogs.clockOut(.failed(.queueFull)),
                "TradeReady has too many pending actions \u{2014} open the app to sync.", "the §4.3 cap dialog")
    expectEqual(plan(before512.map { String($0.dropLast()) + "," + taggedEntry(999) + "]" }).failureValue,
                .tooManyActions, "why: the planner rejects the whole 513-entry batch")

    // An oversized foreign queue is refused too.
    let q600 = "[" + (0..<600).map(taggedEntry).joined(separator: ",") + "]"
    h = Harness(extra: [WidgetAppGroup.actionsKey: q600])
    expectEqual(h.engine.logExpense(amount: 5, category: .fuel, description: nil), .failed(.queueFull),
                "an oversized (600) queue refuses every append")
    expectEqual(h.queueRaw, q600, "the oversized queue is never rewritten")

    // Malformed existing value: refuse and never overwrite (RN treated it as empty).
    for raw in ["not json", "{}", "null", "\"text\"", "[1]", "[{\"id\":\"a\"}, 3]", "[[]]", ""] {
        h = Harness(extra: [WidgetAppGroup.actionsKey: raw])
        expectEqual(h.engine.stopTimer(jobID: "j9"), .failed(.malformedQueue), "malformed queue \(raw.debugDescription) is refused")
        expectEqual(h.engine.logExpense(amount: 5, category: .fuel, description: nil), .failed(.malformedQueue),
                    "malformed queue \(raw.debugDescription) refuses an expense")
        expectEqual(h.queueRaw, raw, "malformed queue \(raw.debugDescription) is left byte-for-byte")
    }
    expectEqual(SiriIntentDialogs.logExpense(.failed(.malformedQueue)),
                "TradeReady couldn't save that \u{2014} open the app and try again.", "malformed → save-failed dialog")

    // Existing bytes are preserved exactly (loss-free splice; a big integer survives).
    let foreign = #"[ {"at":"2026-08-03T18:00:00Z","id":"keep","ownerTag":"\#(ownerTag)","type":"future_kind","big":12345678901234567890} ]"#
    h = Harness(extra: [WidgetAppGroup.actionsKey: foreign])
    _ = h.engine.stopTimer(jobID: "j2")
    let prefix = String(foreign.trimmingCharacters(in: .whitespaces).dropLast())
    expect(h.queueRaw?.hasPrefix(prefix + ",") == true, "existing entries keep their exact bytes (spliced, not re-encoded)")
    expectEqual(planKinds(h.queueRaw), [.unknown("future_kind"), .timerStop], "a future type is retained and the append is valid")

    // Duplicate ids: identical → idempotent success; different → fail, untouched.
    h = Harness()
    h.ids.fixed = "00000000-0000-4000-8000-00000000abcd"
    guard case .queued = h.engine.stopTimer(jobID: "j2") else { return expect(false, "first append with a fixed id") }
    guard case .alreadyQueued = h.engine.stopTimer(jobID: "j2") else {
        return expect(false, "an identical duplicate is an idempotent success")
    }
    expectEqual(h.queue.count, 1, "an identical duplicate appends nothing")
    let beforeConflict = h.queueRaw
    expectEqual(h.engine.stopTimer(jobID: "j3"), .failed(.duplicateConflict), "same id, different content → fail")
    expectEqual(h.queueRaw, beforeConflict, "a conflicting duplicate leaves the queue untouched")
    expect(plan(h.queueRaw).isSuccess, "the queue stays planner-valid (no duplicateActionID wedge)")

    // Unique ids with the live UUID source across many appends.
    let live = ProbingStore([WidgetAppGroup.snapshotKey: snapshotJSON()], lockFile: tempLockFile("uuid"))
    let liveEngine = WidgetIntentEngine(environment: WidgetIntentEnvironment(
        store: live, lockFile: live.lockFile, now: { now }, makeActionID: { UUID().uuidString }, timeZone: phoenix
    ))
    for index in 0..<40 {
        _ = index.isMultiple(of: 2) ? liveEngine.startTimer(jobID: "j\(index)") : liveEngine.stopTimer(jobID: "")
    }
    guard case .success(let uuidBatch) = plan(live.values[WidgetAppGroup.actionsKey]) else {
        return expect(false, "40 live appends are planner-valid (unique ids)")
    }
    expectEqual(Set(uuidBatch.actions.map(\.id)).count, 40, "every appended id is unique")
    expect(uuidBatch.actions.allSatisfy { UUID(uuidString: $0.id) != nil }, "live ids are UUID strings (§4.1)")

    // Validation mirrors the planner: every writer-accepted boundary passes the
    // planner, and each writer-rejected value would have wedged the batch.
    func action(_ extra: [String: WidgetJSONValue], type: String = "expense_log") -> WidgetPendingAction {
        var fields: [String: WidgetJSONValue] = [
            "id": .string("v-1"), "type": .string(type), "at": .string("2026-08-03T19:00:00.000Z"),
            "ownerTag": .string(ownerTag), "date": .string("2026-08-03"),
        ]
        fields.merge(extra) { _, new in new }
        return WidgetPendingAction(fields: fields)
    }
    let expense: [String: WidgetJSONValue] = ["amount": .number(10), "category": .string("fuel")]
    let trip: [String: WidgetJSONValue] = ["odometerStart": .number(0), "odometerEnd": .number(5)]
    let accepted: [(String, WidgetPendingAction)] = [
        ("amount at the planner floor 1e-19", action(expense.merging(["amount": .number(1e-19)]) { $1 })),
        ("amount at the 1,000,000 ceiling", action(expense.merging(["amount": .number(1_000_000)]) { $1 })),
        ("odometer 0", action(trip, type: "trip_log")),
        ("odometer at the 10,000,000 ceiling", action(trip.merging(["odometerEnd": .number(10_000_000)]) { $1 }, type: "trip_log")),
        ("id at 128 bytes", action(expense.merging(["id": .string(String(repeating: "x", count: 128))]) { $1 })),
    ]
    for (label, candidate) in accepted {
        expect((try? WidgetIntentEngine.validate(candidate)) != nil, "writer accepts \(label)")
        expect(plan("[" + (try! candidate.encodedJSON()) + "]").isSuccess, "planner accepts \(label)")
    }
    let rejected: [(String, WidgetPendingAction, String)] = [
        ("amount below the planner floor", action(expense.merging(["amount": .number(9.99e-20)]) { $1 }), "amount"),
        ("amount above the ceiling", action(expense.merging(["amount": .number(1_000_000.01)]) { $1 }), "amount"),
        ("unknown category", action(expense.merging(["category": .string("snacks")]) { $1 }), "category"),
        ("impossible date", action(expense.merging(["date": .string("2026-02-30")]) { $1 }), "date"),
        ("non-strict date", action(expense.merging(["date": .string("2026-8-03")]) { $1 }), "date"),
        ("signed year", action(expense.merging(["date": .string("+026-08-03")]) { $1 }), "date"),
        ("signed month", action(expense.merging(["date": .string("2026-+8-03")]) { $1 }), "date"),
        ("odometer past the ceiling", action(trip.merging(["odometerEnd": .number(1e200)]) { $1 }, type: "trip_log"), "odometerEnd"),
        ("negative odometer", action(trip.merging(["odometerStart": .number(-1)]) { $1 }, type: "trip_log"), "odometerStart"),
        ("missing ownerTag", action(expense.merging(["ownerTag": .null]) { $1 }), "ownerTag"),
        ("bad at", action(expense.merging(["at": .string("yesterday")]) { $1 }), "at"),
        ("id over 128 bytes", action(expense.merging(["id": .string(String(repeating: "x", count: 129))]) { $1 }), "id"),
        ("control character in id", action(expense.merging(["id": .string("a\u{0007}b")]) { $1 }), "id"),
        ("timer_start without jobId", action([:], type: "timer_start"), "jobId"),
        ("unknown type", action([:], type: "future_kind"), "type"),
    ]
    for (label, candidate, field) in rejected {
        do {
            try WidgetIntentEngine.validate(candidate)
            expect(false, "writer rejects \(label)")
        } catch {
            expectEqual(error as? WidgetIntentFailure, .invalidAction(field: field), "writer rejects \(label) on \(field)")
        }
    }
    // One shared rule (fix round 1, I1): the planner refuses the signed
    // pieces too, and both sides call the same predicates.
    // Task 11.05 (§4.5): these fixtures carry the owner's tag. An untagged
    // entry is dropped before validation, so it could never prove a rejection.
    for date in ["+026-08-03", "2026-+8-03", "2026-08-+3", "2026-02-30", "２０２６-08-03"] {
        expect(!WidgetActionFieldRules.isValidLocalDate(date), "shared rule rejects date \(date)")
        expect(!plan(#"[{"ownerTag":"\#(ownerTag)","id":"a","type":"expense_log","at":"2026-08-03T19:00:00Z","date":"\#(date)","amount":5,"category":"fuel"}]"#).isSuccess,
               "the planner rejects date \(date)")
    }
    for date in ["2026-08-03", "2024-02-29", "0001-01-01"] {
        expect(WidgetActionFieldRules.isValidLocalDate(date), "shared rule accepts date \(date)")
        // Task 11.05: the kinds (not bare success) prove the owned action was
        // kept, not dropped by the §4.5 owner gate.
        expect(planKinds(#"[{"ownerTag":"\#(ownerTag)","id":"a","type":"expense_log","at":"2026-08-03T19:00:00Z","date":"\#(date)","amount":5,"category":"fuel"}]"#) == [.expenseLog],
               "the planner accepts date \(date)")
    }
    expectEqual(NativeWidgetActionBatch.maximumIdentifierLength, WidgetActionFieldRules.maximumIdentifierLength,
                "the planner's identifier cap is the shared one")
    expect(!plan(#"[{"ownerTag":"\#(ownerTag)","id":"\#(String(repeating: "x", count: 129))","type":"timer_stop","at":"2026-08-03T19:00:00Z"}]"#).isSuccess,
           "the planner rejects a 129-byte id")

    // Why the native ceilings exist: the planner would fail the WHOLE batch.
    expect(!plan(#"[{"ownerTag":"\#(ownerTag)","id":"a","type":"trip_log","at":"2026-08-03T19:00:00Z","date":"2026-08-03","odometerStart":0,"odometerEnd":1e200}]"#).isSuccess,
           "the planner cannot decode an odometer of 1e200 (would wedge the queue)")
    expect(!plan(#"[{"ownerTag":"\#(ownerTag)","id":"a","type":"expense_log","at":"2026-08-03T19:00:00Z","date":"2026-08-03","amount":9.99e-20,"category":"fuel"}]"#).isSuccess,
           "the planner rejects an amount below its floor")
}

// MARK: - 4. Trip session (§4.4)

private func testTripSession() throws {
    // Start writes ONLY activeTrip.
    var h = Harness()
    let started = h.engine.startTrip(odometerStart: 12_000.5)
    guard case .started(false, let trip) = started else { return expect(false, "startTrip starts (got \(started))") }
    expectEqual(Set(h.store.writes), [WidgetAppGroup.activeTripKey], "Start Trip writes only the private activeTrip key")
    expect(h.queueRaw == nil, "Start Trip never touches the action queue")
    expectEqual(trip.ownerTag, ownerTag, "activeTrip is stamped with the owner tag (§4.5)")
    expectEqual(trip.startedAt, "2026-08-03T19:00:00.000Z", "activeTrip.startedAt is the clock")
    expectEqual(WidgetActiveTrip.decode(h.trip), trip, "the stored session round-trips")
    expectEqual(SiriIntentDialogs.startTrip(started, odometerStart: 12_000.5), "Trip started at 12000.5 miles.", "start dialog")
    expectEqual(h.engine.startTrip(odometerStart: 1), .alreadyRunning, "a fresh trip → already running")
    expectEqual(SiriIntentDialogs.startTrip(.alreadyRunning, odometerStart: 1),
                "A trip is already running. Say 'stop my trip' to finish it.", "already-running dialog")
    expectEqual(h.store.unlockedAccesses, 0, "trip start reads and writes under the lock")

    // Stop an hour later → one trip_log, the session cleared.
    h.clock.date = now.addingTimeInterval(3600)
    let stopped = h.engine.stopTrip(odometerEnd: 12_042.1)
    guard case .logged(let miles, let action) = stopped else { return expect(false, "stopTrip logs (got \(stopped))") }
    expectEqual((miles * 10).rounded() / 10, 41.6, "miles = end − start")
    expectEqual(SiriIntentDialogs.stopTrip(stopped), "Logged 41.6 miles.", "stop dialog")
    expect(h.trip == nil, "Stop Trip clears activeTrip")
    expectEqual(h.queue.count, 1, "Stop Trip appends exactly one action")
    let entry = h.queue.first ?? [:]
    expectEqual(jsonKeys(entry), ["id", "type", "at", "date", "odometerStart", "odometerEnd", "ownerTag"], "trip_log §4.1 fields")
    expectEqual(entry["id"] as? String, trip.id, "trip_log reuses the session's stable id")
    expectEqual(entry["at"] as? String, "2026-08-03T20:00:00.000Z", "trip_log.at is stopAt")
    expectEqual(entry["date"] as? String, "2026-08-03", "trip_log.date is the local start date")
    expectEqual(action.fields["odometerEnd"], .number(12_042.1), "odometerEnd")
    guard case .success(let batch) = plan(h.queueRaw) else { return expect(false, "trip_log is planner-valid") }
    let replayed = try NativeWidgetActionReplayer.apply(batch, to: Canonical.Snapshot(payload: .init()))
    let logged = replayed.snapshot.payload.trips?.first
    expectEqual(logged?.id, "t_siri_\(trip.id ?? "")", "replay files the trip under t_siri_<id>")
    expectEqual(logged?.miles, Decimal(string: "41.6"), "replay computes the same miles")
    expectEqual(h.engine.stopTrip(odometerEnd: 1), .noTrip, "no session → no trip running")
    expectEqual(SiriIntentDialogs.stopTrip(.noTrip), "No trip is running.", "no-trip dialog")

    // FA-039: a trip started at 11:30 pm local is dated that local day.
    h = Harness(at: ISO8601DateFormatter().date(from: "2026-08-04T06:30:00Z")!) // 23:30 Phoenix on 08-03
    _ = h.engine.startTrip(odometerStart: 100)
    h.clock.date = h.clock.date.addingTimeInterval(3600)
    _ = h.engine.stopTrip(odometerEnd: 130)
    expectEqual(h.queue.first?["date"] as? String, "2026-08-03", "a trip crossing local midnight is dated its local start day, never the UTC day")

    // Stale on start (> 86,400 s): replaced, never logged.
    func session(startedAt: String, tag: String? = ownerTag, extra: String = "") -> String {
        let tagField = tag.map { #","ownerTag":"\#($0)""# } ?? ""
        return #"{"id":"trip-1","odometerStart":500,"startedAt":"\#(startedAt)"\#(tagField)\#(extra)}"#
    }
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: iso(now.addingTimeInterval(-86_401)))])
    let replaced = h.engine.startTrip(odometerStart: 900)
    guard case .started(true, let fresh) = replaced else { return expect(false, "a stale trip is replaced (got \(replaced))") }
    expectEqual(SiriIntentDialogs.startTrip(replaced, odometerStart: 900),
                "Your previous trip was never finished \u{2014} starting a new one.", "the §4.4 replaced dialog")
    expect(h.queueRaw == nil, "the stale trip is never logged")
    expectEqual(fresh.odometerStart, 900, "the new session replaces the stale one")
    expect(fresh.id != "trip-1", "the new session has a new id")

    // Exactly 86,400 s is still fresh.
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: iso(now.addingTimeInterval(-86_400)))])
    expectEqual(h.engine.startTrip(odometerStart: 900), .alreadyRunning, "exactly one day old is not stale")

    // Stale on stop: discarded, never logged.
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: iso(now.addingTimeInterval(-2 * 86_400)))])
    expectEqual(h.engine.stopTrip(odometerEnd: 600), .discardedStale, "a stale session is discarded at stop")
    expect(h.queueRaw == nil && h.trip == nil, "…never logged, and cleared")
    expect(SiriIntentDialogs.stopTrip(.discardedStale).contains("wasn't logged"), "the discard dialog says it was not logged")
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: "garbage")])
    expectEqual(h.engine.stopTrip(odometerEnd: 600), .discardedStale, "an unparseable start is stale")
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: "garbage")])
    guard case .started(true, _) = h.engine.startTrip(odometerStart: 1) else { return expect(false, "an undatable trip is replaced") }

    // Crash retry: the persisted id/stopAt/odometerEnd are reused; an
    // already-appended identical action makes the retry idempotent.
    let startedAt = iso(now.addingTimeInterval(-1800))
    let persisted = session(startedAt: startedAt, extra: #","odometerEnd":540,"stopAt":"\#(iso(now.addingTimeInterval(-60)))""#)
    let appended = #"[{"at":"\#(iso(now.addingTimeInterval(-60)))","date":"2026-08-03","id":"trip-1","odometerEnd":540,"odometerStart":500,"ownerTag":"\#(ownerTag)","type":"trip_log"}]"#
    h = Harness(extra: [WidgetAppGroup.activeTripKey: persisted, WidgetAppGroup.actionsKey: appended])
    let retried = h.engine.stopTrip(odometerEnd: 9_999)
    guard case .logged(let retryMiles, _) = retried else { return expect(false, "a crash retry completes (got \(retried))") }
    expectEqual(retryMiles, 40, "the retry reuses the persisted odometerEnd, not the new reading")
    expectEqual(h.queue.count, 1, "the retry is idempotent (exact duplicate id)")
    expect(h.trip == nil, "the retry clears the session")

    // Crash retry with a bad NEW reading (fix round 1, M2): the persisted
    // odometerEnd is what gets logged, so the new value is not validated.
    for bad in [.nan, 1e200, -3] as [Double] {
        h = Harness(extra: [WidgetAppGroup.activeTripKey: persisted])
        let retry = h.engine.stopTrip(odometerEnd: bad)
        guard case .logged(let persistedMiles, _) = retry else {
            expect(false, "a crash retry with reading \(bad) logs the persisted trip (got \(retry))"); continue
        }
        expectEqual(persistedMiles, 40, "the retry with reading \(bad) logs the persisted 540")
        expect(h.trip == nil && plan(h.queueRaw).isSuccess, "…clears the session and stays planner-valid")
    }

    // Persisted but not yet appended → appends with the persisted values.
    h = Harness(extra: [WidgetAppGroup.activeTripKey: persisted])
    _ = h.engine.stopTrip(odometerEnd: 9_999)
    expectEqual(h.queue.first?["id"] as? String, "trip-1", "the persisted id is used")
    expectEqual(h.queue.first?["odometerEnd"] as? Double, 540, "the persisted odometerEnd is used")

    // Conflict or a full queue: the session (with its stable id) is kept.
    let conflicting = appended.replacingOccurrences(of: "\"odometerEnd\":540", with: "\"odometerEnd\":541")
    h = Harness(extra: [WidgetAppGroup.activeTripKey: persisted, WidgetAppGroup.actionsKey: conflicting])
    expectEqual(h.engine.stopTrip(odometerEnd: 540), .failed(.duplicateConflict), "a conflicting id fails")
    expect(h.trip != nil, "the session survives a failed append (no lost odometer)")
    let q512 = "[" + (0..<512).map(taggedEntry).joined(separator: ",") + "]"
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: startedAt), WidgetAppGroup.actionsKey: q512])
    expectEqual(h.engine.stopTrip(odometerEnd: 520), .failed(.queueFull), "a full queue refuses the trip_log")
    expectEqual(SiriIntentDialogs.stopTrip(.failed(.queueFull)),
                "TradeReady has too many pending actions \u{2014} open the app to sync.", "cap dialog on stop")
    let kept = WidgetActiveTrip.decode(h.trip)
    expect(kept?.stopAt != nil && kept?.odometerEnd == 520, "the stable completion payload is persisted for the retry")

    // Another owner's (or an untagged RN) session is discarded, never logged.
    for tag in [otherTag, nil] as [String?] {
        h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: startedAt, tag: tag)])
        expectEqual(h.engine.stopTrip(odometerEnd: 600), .noTrip, "a foreign/untagged session is not this owner's trip")
        expect(h.trip == nil && h.queueRaw == nil, "…it is discarded and never logged")
        h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: startedAt, tag: tag)])
        guard case .started(false, let own) = h.engine.startTrip(odometerStart: 7) else {
            return expect(false, "a foreign session never blocks this owner's start")
        }
        expectEqual(own.ownerTag, ownerTag, "…and is replaced by this owner's session")
    }

    // Invalid odometers write nothing.
    for bad in [-1, .nan, .infinity, 1e200] as [Double] {
        h = Harness()
        expectEqual(h.engine.startTrip(odometerStart: bad), .invalidOdometer, "startTrip rejects odometer \(bad)")
        expect(h.store.writes.isEmpty, "a rejected start writes nothing")
    }
    expectEqual(SiriIntentDialogs.startTrip(.invalidOdometer, odometerStart: -1),
                "That odometer reading doesn't look right. Try again with a number of miles.", "RN bad-odometer dialog")
    h = Harness(extra: [WidgetAppGroup.activeTripKey: session(startedAt: startedAt)])
    let untouched = h.trip
    expectEqual(h.engine.stopTrip(odometerEnd: .nan), .invalidOdometer, "stopTrip rejects a NaN reading")
    expectEqual(h.trip, untouched, "a rejected stop leaves the session untouched")

    // Trips are not refused on a stale snapshot, but need an owner.
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-200_000)))
    guard case .started = h.engine.startTrip(odometerStart: 1) else { return expect(false, "StartTrip ignores staleness (§3.3)") }
    h = Harness(snapshot: snapshotJSON(ownerTag: nil))
    expectEqual(h.engine.startTrip(odometerStart: 1), .failed(.signInRequired), "StartTrip needs a tagged snapshot")
    expectEqual(SiriIntentDialogs.startTrip(.failed(.signInRequired), odometerStart: 1), "Open TradeReady and sign in first.", "§4.5")
    expect(h.trip == nil, "no owner → no session written")
}

// MARK: - 5. Log Expense

private func testLogExpense() throws {
    var h = Harness()
    let logged = h.engine.logExpense(amount: 42.1, category: .labor, description: "  Scaffold rental ")
    guard case .logged(_, _, let action) = logged else { return expect(false, "logExpense logs (got \(logged))") }
    expectEqual(SiriIntentDialogs.logExpense(logged), "Logged $42.10 for Subcontractors.", "the dialog speaks the display label")
    let entry = h.queue.first ?? [:]
    expectEqual(jsonKeys(entry), ["id", "type", "at", "date", "amount", "category", "description", "ownerTag"], "expense_log fields")
    expectEqual(entry["category"] as? String, "labor", "category is the RN id")
    expectEqual(entry["description"] as? String, "Scaffold rental", "description is trimmed")
    expectEqual(entry["date"] as? String, "2026-08-03", "date is the local day")
    expect(h.queueRaw?.contains("\"amount\":42.1") == true, "the amount is encoded exactly (42.1, not 42.100000000000001)")
    expectEqual(action.fields["ownerTag"], .string(ownerTag), "expense is owner-stamped")
    guard case .success(let batch) = plan(h.queueRaw) else { return expect(false, "expense_log is planner-valid") }
    var replayed = try NativeWidgetActionReplayer.apply(batch, to: Canonical.Snapshot(payload: .init()))
    var expense = replayed.snapshot.payload.expenses?.first
    expectEqual(expense?.amount, Decimal(string: "42.1"), "replay files the exact amount")
    expectEqual(expense?.description, "Scaffold rental", "replay keeps the description")
    expectEqual(expense?.category, "labor", "replay keeps the category")

    for description in [nil, "", "   "] as [String?] {
        h = Harness()
        _ = h.engine.logExpense(amount: 5, category: .fuel, description: description)
        expect(h.queue.first?["description"] == nil, "an empty/absent description \(String(describing: description)) is omitted")
        guard case .success(let emptyBatch) = plan(h.queueRaw) else { return expect(false, "planner-valid without description") }
        replayed = try NativeWidgetActionReplayer.apply(emptyBatch, to: Canonical.Snapshot(payload: .init()))
        expense = replayed.snapshot.payload.expenses?.first
        expectEqual(expense?.description, "Logged via Siri", "replay files it as 'Logged via Siri'")
    }

    for bad in [0, -5, .nan, .infinity, 1_000_000.01, 1e-20] as [Double] {
        h = Harness()
        expectEqual(h.engine.logExpense(amount: bad, category: .other, description: nil), .invalidAmount, "amount \(bad) is refused")
        expect(h.store.writes.isEmpty && h.store.reads.isEmpty, "a refused amount touches nothing")
    }
    expectEqual(SiriIntentDialogs.logExpense(.invalidAmount), "That amount doesn't look right.", "RN amount dialog")
    h = Harness()
    guard case .logged = h.engine.logExpense(amount: 1_000_000, category: .other, description: nil) else {
        return expect(false, "exactly 1,000,000 is kept (RN cap)")
    }
    expectEqual(SiriIntentDialogs.logExpense(.logged(amount: 12.5, category: .tools, action: .init(fields: [:]))),
                "Logged $12.50 for Tools & Equipment.", "dollars format with cents")

    // Local evening: dated the local day, not the UTC day (FA-039).
    h = Harness(at: ISO8601DateFormatter().date(from: "2026-08-04T06:30:00Z")!)
    _ = h.engine.logExpense(amount: 9, category: .materials, description: nil)
    expectEqual(h.queue.first?["date"] as? String, "2026-08-03", "an 11:30 pm expense belongs to that local day")

    // Not refused when stale; refused without an owner.
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-200_000)))
    guard case .logged = h.engine.logExpense(amount: 3, category: .fuel, description: nil) else {
        return expect(false, "LogExpense ignores staleness (§3.3)")
    }
    h = Harness(snapshot: nil)
    expectEqual(h.engine.logExpense(amount: 3, category: .fuel, description: nil), .failed(.signInRequired), "no snapshot → refuse")
    expect(h.queueRaw == nil, "…and write nothing")
}

// MARK: - 6. On My Way handoff (§5.1, §6.2)

private func testOnMyWayStash() {
    var h = Harness()
    let outcome = h.engine.stashOnMyWay()
    guard case .opening(let url, let customer, let stashJSON) = outcome else {
        return expect(false, "On My Way stashes and opens (got \(outcome))")
    }
    expectEqual(url, "tradeready://onmyway/j9", "the deep link is tradeready://onmyway/<nextJob.id>")
    expectEqual(customer, "Alice Johnson", "the dialog names the customer")
    expectEqual(SiriIntentDialogs.onMyWay(outcome), "Opening a message for Alice Johnson.", "RN on-my-way dialog")
    let expected = #"{"at":"2026-08-03T19:00:00.000Z","ownerTag":"\#(ownerTag)","url":"tradeready://onmyway/j9"}"#
    expectEqual(h.stash, expected, "the stash is exactly {url, at, ownerTag}, sorted, unescaped slashes")
    expectEqual(stashJSON, expected, "the outcome reports the verified stash")
    expectEqual(NativeDeepLinkParser.parse(url), .onMyWay(id: "j9"), "the URL parses with the existing grammar")
    let parsed = NativeDeepLinkParser.parsePendingOpenURL(expected, now: now.addingTimeInterval(299))
    expectEqual(parsed?.route, .onMyWay(id: "j9"), "the existing consumer parses the tagged stash (extra key ignored)")
    expect(NativeDeepLinkParser.parsePendingOpenURL(expected, now: now.addingTimeInterval(301)) == nil,
           "the stash is a 5-minute handoff, never a queue")
    expectEqual(Set(h.store.writes), [WidgetAppGroup.pendingOpenURLKey], "On My Way writes only the stash")
    expect(h.queueRaw == nil, "On My Way never queues an action (nothing is ever sent)")
    expectEqual(h.store.unlockedAccesses, 0, "the nextJob/ownerTag read and the stash write share one lock hold")

    // An id with reserved characters survives the round trip exactly.
    var odd = j9; odd.id = "job 7/a%b?c#d"
    h = Harness(snapshot: snapshotJSON(nextJob: odd))
    guard case .opening(let oddURL, _, _) = h.engine.stashOnMyWay() else { return expect(false, "odd id stashes") }
    expectEqual(NativeDeepLinkParser.parse(oddURL), .onMyWay(id: "job 7/a%b?c#d"), "a percent-encoded id decodes back exactly")

    // Refusals write nothing and speak no data.
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-86_401)))
    expectEqual(h.engine.stashOnMyWay(), .stale, "stale → On My Way refuses")
    expectEqual(SiriIntentDialogs.onMyWay(.stale), "Open TradeReady to refresh your schedule.", "stale dialog")
    h = Harness(snapshot: snapshotJSON(nextJob: nil))
    expectEqual(h.engine.stashOnMyWay(), .noUpcomingJob, "no next job → nothing to open")
    expectEqual(SiriIntentDialogs.onMyWay(.noUpcomingJob), "You have no upcoming jobs scheduled.", "RN no-job dialog")
    h = Harness(snapshot: snapshotJSON(ownerTag: nil))
    expectEqual(h.engine.stashOnMyWay(), .failed(.signInRequired), "untagged → refuse")
    expectEqual(SiriIntentDialogs.onMyWay(.failed(.signInRequired)), "Open TradeReady and sign in first.", "§4.5")
    expect(h.stash == nil, "a refused On My Way writes no stash")
}

// MARK: - 7. Read-only intents: Next Job, Outstanding

private func testReadOnlyIntents() {
    func dialogNext(_ h: Harness) -> String {
        // `.short` time style emits U+202F before AM/PM on current ICU; normalize for comparison.
        SiriIntentDialogs.nextJob(h.engine.nextJob(), locale: posix)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    var h = Harness()
    let before = h.store.values
    expectEqual(dialogNext(h), "Your next job is Fence repair for Alice Johnson, tomorrow at 10:30 AM, at 12 Oak St.",
                "Next Job speaks the projected fields")
    expectEqual(SiriIntentDialogs.outstanding(h.engine.outstanding()), "You're owed $160 in outstanding invoices.",
                "Outstanding speaks outstandingTotal")
    expect(h.store.writes.isEmpty, "Next Job and Outstanding write nothing")
    expectEqual(h.engine.nextJob(), .nextJob(j9, now: now, timeZone: phoenix),
                "the outcome carries the engine's own clock and zone (fix round 1, M4)")
    expectEqual(Set(h.store.reads), [WidgetAppGroup.snapshotKey], "they read only the snapshot key (no queue, trip or records)")
    expectEqual(h.store.values, before, "the App Group is unchanged")

    var today = j9; today.scheduledDate = "2026-08-03"; today.scheduledStartTime = nil; today.address = ""
    h = Harness(snapshot: snapshotJSON(nextJob: today))
    expectEqual(dialogNext(h), "Your next job is Fence repair for Alice Johnson, today.", "no time, no address")
    var later = j9; later.scheduledDate = "2026-08-10"; later.scheduledStartTime = "14:30"
    h = Harness(snapshot: snapshotJSON(nextJob: later))
    expectEqual(dialogNext(h), "Your next job is Fence repair for Alice Johnson, Monday, August 10 at 2:30 PM, at 12 Oak St.",
                "a later day is spelled out")
    // Seconds before local midnight: the engine's upcoming check and the
    // spoken day both use the engine clock, so a job dated today is "today".
    var tonight = j9; tonight.scheduledDate = "2026-08-03"; tonight.scheduledStartTime = nil
    h = Harness(snapshot: snapshotJSON(updatedAt: now, nextJob: tonight),
                at: ISO8601DateFormatter().date(from: "2026-08-04T06:59:59Z")!) // 23:59:59 Phoenix
    expectEqual(dialogNext(h), "Your next job is Fence repair for Alice Johnson, today, at 12 Oak St.",
                "at 23:59:59 local, today's job is still spoken as today")
    h.clock.date = ISO8601DateFormatter().date(from: "2026-08-04T07:00:01Z")! // 00:00:01 the next day
    expectEqual(dialogNext(h), "You have no upcoming jobs scheduled.", "after local midnight it is no longer next")
    var past = j9; past.scheduledDate = "2026-08-02"
    h = Harness(snapshot: snapshotJSON(nextJob: past))
    expectEqual(dialogNext(h), "You have no upcoming jobs scheduled.", "a past nextJob is never 'next'")
    h = Harness(snapshot: snapshotJSON(nextJob: nil))
    expectEqual(dialogNext(h), "You have no upcoming jobs scheduled.", "RN no-job dialog")

    for (total, spoken) in [(1234.56, "You're owed $1234.56 in outstanding invoices."),
                            (0, "Nothing outstanding \u{2014} you're fully collected."),
                            (nil, "Nothing outstanding \u{2014} you're fully collected.")] as [(Double?, String)] {
        h = Harness(snapshot: snapshotJSON(outstandingTotal: total))
        expectEqual(SiriIntentDialogs.outstanding(h.engine.outstanding()), spoken, "outstanding \(String(describing: total))")
    }

    // Refusals: stale and no owner speak no data and write nothing.
    h = Harness(snapshot: snapshotJSON(updatedAt: now.addingTimeInterval(-86_401)))
    expectEqual(dialogNext(h), "Open TradeReady to refresh your schedule.", "stale → Next Job refuses")
    expectEqual(SiriIntentDialogs.outstanding(h.engine.outstanding()), "Open TradeReady to refresh your schedule.",
                "stale → Outstanding refuses")
    for snapshot in [nil, snapshotJSON(ownerTag: nil)] as [String?] {
        h = Harness(snapshot: snapshot)
        expectEqual(dialogNext(h), "Open TradeReady and sign in first.", "no owner → Next Job refuses")
        expectEqual(SiriIntentDialogs.outstanding(h.engine.outstanding()), "Open TradeReady and sign in first.",
                    "no owner → Outstanding refuses")
        expect(h.store.writes.isEmpty, "a refused read-only intent writes nothing")
    }
    let noStore = WidgetIntentEngine(environment: WidgetIntentEnvironment(
        store: nil, lockFile: nil, now: { now }, makeActionID: { "x" }, timeZone: phoenix
    ))
    expectEqual(SiriIntentDialogs.outstanding(noStore.outstanding()),
                "TradeReady couldn't check that \u{2014} open the app and try again.", "no container → a read failure, not 'couldn't save'")
}

// MARK: - 8. Lock discipline on a real suite (§4.2, §4.5 scrub race)

private final class TempSuite {
    let name = "com.tradeready.app-intents.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let lockFile = tempLockFile("suite")
    init() { defaults = UserDefaults(suiteName: name)! }
    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(suiteName: name, defaults: defaults, lockFile: lockFile)
    }
    var engine: WidgetIntentEngine { engine(at: now) }
    func engine(at date: Date) -> WidgetIntentEngine {
        WidgetIntentEngine(environment: WidgetIntentEnvironment(
            store: defaults, lockFile: lockFile, now: { date }, makeActionID: { UUID().uuidString }, timeZone: phoenix
        ))
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: lockFile.deletingLastPathComponent())
    }
}

private func holdLock(at url: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    precondition(descriptor >= 0 && flock(descriptor, LOCK_EX) == 0)
    return descriptor
}

private func releaseLock(_ descriptor: Int32) {
    flock(descriptor, LOCK_UN)
    close(descriptor)
}

private final class Box<T> {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

private func runInBackground<T>(_ body: @escaping () -> T) -> (Box<T>, DispatchSemaphore) {
    let box = Box<T>(), done = DispatchSemaphore(value: 0)
    Thread { box.set(body()); done.signal() }.start()
    return (box, done)
}

private func testLockDiscipline() {
    // A holder (the app's replay claim or mirror write) blocks the append.
    var suite = TempSuite()
    suite.defaults.set(snapshotJSON(), forKey: WidgetAppGroup.snapshotKey)
    var held = holdLock(at: suite.lockFile)
    let engine = suite.engine
    let (clockIn, clockInDone) = runInBackground { engine.clockIn() }
    expect(clockInDone.wait(timeout: .now() + 0.25) == .timedOut, "the append waits while another process holds the lock")
    expect(suite.defaults.string(forKey: WidgetAppGroup.actionsKey) == nil, "nothing is written while the lock is held elsewhere")
    releaseLock(held)
    _ = clockInDone.wait(timeout: .now() + 5)
    expect(clockIn.get()?.wroteQueue == true, "after release the append lands")
    suite.cleanUp()

    // Scrub race: the writer is blocked on the lock when sign-out wipes the
    // suite (the scrubber's in-lock critical section). Because the snapshot
    // read happens INSIDE the writer's lock hold, it sees no owner and writes
    // nothing — the action can never survive into the next account.
    suite = TempSuite()
    suite.defaults.set(snapshotJSON(), forKey: WidgetAppGroup.snapshotKey)
    held = holdLock(at: suite.lockFile)
    let racer = suite.engine
    let (expense, expenseDone) = runInBackground { racer.logExpense(amount: 20, category: .fuel, description: nil) }
    let (trip, tripDone) = runInBackground { racer.startTrip(odometerStart: 10) }
    let (stash, stashDone) = runInBackground { racer.stashOnMyWay() }
    Thread.sleep(forTimeInterval: 0.2)
    suite.defaults.removePersistentDomain(forName: suite.name)
    releaseLock(held)
    for done in [expenseDone, tripDone, stashDone] { _ = done.wait(timeout: .now() + 5) }
    expectEqual(expense.get(), .failed(.signInRequired), "a writer blocked across the scrub refuses (expense)")
    expectEqual(trip.get(), .failed(.signInRequired), "a writer blocked across the scrub refuses (trip)")
    expectEqual(stash.get(), .failed(.signInRequired), "a writer blocked across the scrub refuses (stash)")
    expect(WidgetAppGroup.accountKeys.allSatisfy { suite.defaults.object(forKey: $0) == nil },
           "nothing re-populates the suite after the scrub")
    suite.cleanUp()

    // The real scrubber wipes every intent-owned key, after which intents refuse.
    suite = TempSuite()
    suite.defaults.set(snapshotJSON(), forKey: WidgetAppGroup.snapshotKey)
    _ = suite.engine.clockIn()
    _ = suite.engine.startTrip(odometerStart: 1)
    _ = suite.engine.stashOnMyWay()
    expect([WidgetAppGroup.actionsKey, WidgetAppGroup.activeTripKey, WidgetAppGroup.pendingOpenURLKey]
        .allSatisfy { suite.defaults.string(forKey: $0) != nil }, "sanity: the intents wrote queue, trip and stash")
    do { try suite.scrubber.scrub() } catch { expect(false, "scrub succeeds (\(error))") }
    expect(WidgetAppGroup.accountKeys.allSatisfy { suite.defaults.object(forKey: $0) == nil },
           "the scrubber wipes the queue, the trip session and the stash")
    expectEqual(suite.engine.clockOut(), .failed(.signInRequired), "after the scrub every writer refuses")
    suite.cleanUp()
}

// MARK: - 9. Router + AppStore: the on-my-way review, and end-to-end replay

@MainActor
private final class SubscriptionStub: NativeSubscriptionServing {
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    func logOut() async {}
}

private final class CountingReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<5 { await Task.yield() }
}

@MainActor
private func testRouter() {
    let router = NativeIntentURLRouter()
    var delivered: [URL] = []
    router.open(URL(string: "tradeready://onmyway/old")!)
    router.open(URL(string: "tradeready://onmyway/new")!)
    expectEqual(router.heldURL, URL(string: "tradeready://onmyway/new")!, "before install one URL is held (newest wins)")
    router.install { delivered.append($0) }
    expectEqual(delivered, [URL(string: "tradeready://onmyway/new")!], "install delivers the held URL once")
    expect(router.heldURL == nil, "…and clears it")
    router.open(URL(string: "tradeready://onmyway/next")!)
    expectEqual(delivered.count, 2, "after install a URL is delivered immediately")
}

@MainActor
private func testAppStoreHandoffAndReplay() async throws {
    let suite = TempSuite()
    defer { suite.cleanUp() }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1104-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("store.json")
    let jobs = [job(#"{"id":"j9","scheduledDate":"2099-01-01","scheduledStartTime":"08:00"}"#)]
    let canonical = Canonical.Snapshot(payload: Canonical.SnapshotPayload(invoices: [], jobs: jobs))
    try Canonical.SnapshotRepository(primaryURL: fileURL).save(canonical)
    let store = AppStore(
        fileURL: fileURL,
        seedIfMissing: false,
        appGroupAccountScrubber: suite.scrubber,
        subscriptionService: SubscriptionStub(),
        widgetTimelineReloader: CountingReloader()
    )
    store.installWidgetMirror(NativeWidgetMirror(defaults: suite.defaults, lockFile: suite.lockFile, reloader: CountingReloader()))
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-11.04", binding: ownerBinding)
    await settle()
    expectEqual(WidgetSnapshot.load(from: suite.defaults)?.ownerTag, ownerTag, "sanity: the app mirrored a snapshot tagged for the owner")

    // The intents stamp exactly the tag the app wrote (the extension never derives one).
    // The mirror stamps `updatedAt` with the real clock, so the engine runs on it too.
    let clockedAt = Date()
    let engine = suite.engine(at: clockedAt)
    guard case .clockedIn = engine.clockIn() else { return expect(false, "clock in against the app-written snapshot") }
    _ = engine.logExpense(amount: 18.75, category: .materials, description: "Screws")
    _ = engine.startTrip(odometerStart: 1000)
    _ = engine.stopTrip(odometerEnd: 1012)
    let raw = suite.defaults.string(forKey: WidgetAppGroup.actionsKey)
    guard case .success(let batch) = plan(raw) else { return expect(false, "the intents' queue is planner-valid for the owner") }
    expect(batch.actions.allSatisfy { $0.fields["ownerTag"] == .string(ownerTag) }, "every action carries hash(O) (§4.5)")
    let replayed = try NativeWidgetActionReplayer.apply(batch, to: canonical)
    let session = replayed.snapshot.payload.jobs?.first?.timeSessions?.last
    expectEqual(session?.start, WidgetSnapshot.isoTimestamp(clockedAt), "replay clocks j9 in at the action's time")
    expect(session?.end == nil, "the replayed session is open")
    expectEqual(replayed.snapshot.payload.jobs?.first?.status, "in_progress", "replay moves a scheduled job to in_progress")
    expectEqual(replayed.snapshot.payload.expenses?.count, 1, "replay files the expense")
    expectEqual(replayed.snapshot.payload.trips?.first?.miles, 12, "replay files the trip")
    expectEqual(replayed.changedActionCount, 3, "all three actions apply through the normal replay path")

    // On My Way → router → handle(url:) → the editable review, never sent.
    let bytesBefore = try Data(contentsOf: fileURL)
    guard case .opening(let url, _, _) = engine.stashOnMyWay(), let route = URL(string: url) else {
        return expect(false, "On My Way opens for the app-written snapshot")
    }
    let router = NativeIntentURLRouter()
    router.open(route) // arrives before the store is wired (cold path)
    expect(store.pendingOnMyWayJobID == nil, "nothing is presented before the router is installed")
    router.install { [weak store] in store?.handle(url: $0) }
    expectEqual(store.pendingOnMyWayJobID, "j9", "the review for j9 is requested (editable review sheet)")
    expectEqual(store.deepLinkedJobID, "j9", "the job is deep-linked")
    expectEqual(store.selectedTab, .jobs, "the Jobs tab is selected")
    await settle()
    expectEqual(try Data(contentsOf: fileURL), bytesBefore, "routing mutates no canonical data (nothing is sent or saved)")
    store.dismissPendingOnMyWay(jobID: "j9")
    expect(store.pendingOnMyWayJobID == nil, "the review can be dismissed without sending")
    expect(suite.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) != nil,
           "the tagged stash stays for the cold-launch consumer (11.06)")

    // Sign-out: the scrubber wipes everything the intents wrote; intents then refuse.
    try await store.signOut(revokeRemote: false)
    await settle()
    expect(WidgetAppGroup.accountKeys.allSatisfy { suite.defaults.object(forKey: $0) == nil },
           "sign-out wipes the queue, trip, stash and snapshot")
    expectEqual(engine.clockIn(), .failed(.signInRequired), "after sign-out the intents refuse and write nothing")
    expect(suite.defaults.string(forKey: WidgetAppGroup.actionsKey) == nil, "no action survives into the next account")
}

// MARK: - 10. Declarations: ten intents, once each; phrases; AppEnum; floor

private let expectedIntentFiles: [String: String] = [
    "StartTimerIntent": "Widgets/Shared/WidgetIntents.swift",
    "StopTimerIntent": "Widgets/Shared/WidgetIntents.swift",
    "OnMyWayIntent": "Intents/OnMyWayIntent.swift",
    "NextJobIntent": "Intents/JobActionIntents.swift",
    "StartTripIntent": "Intents/JobActionIntents.swift",
    "StopTripIntent": "Intents/JobActionIntents.swift",
    "ClockInIntent": "Intents/JobActionIntents.swift",
    "ClockOutIntent": "Intents/JobActionIntents.swift",
    "LogExpenseIntent": "Intents/JobActionIntents.swift",
    "OutstandingIntent": "Intents/JobActionIntents.swift",
]

private func swiftSources(under root: URL) -> [(path: String, text: String)] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var result: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            result.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), text))
        }
    }
    return result
}

private func matches(_ pattern: String, in text: String) -> [[String]] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

private func testDeclarations() {
    guard let rootPath = ProcessInfo.processInfo.environment["TRADEREADY_ROOT"] else {
        return expect(false, "TRADEREADY_ROOT is set by the runner")
    }
    let appRoot = URL(fileURLWithPath: rootPath).appendingPathComponent("native/TradeReadyNative")
    let widgetRoot = URL(fileURLWithPath: rootPath).appendingPathComponent("native/TradeReadyWidgets")
    let sources = swiftSources(under: appRoot)

    // Each intent type is defined exactly once, in its contract file (§5.4).
    var found: [String: [String]] = [:]
    var providers: [String] = []
    for (path, text) in sources {
        for match in matches(#"(?m)^\s*struct\s+(\w+)\s*:\s*AppIntent\b"#, in: text) { found[match[1], default: []].append(path) }
        for _ in matches(#"(?m)^\s*struct\s+\w+\s*:\s*AppShortcutsProvider\b"#, in: text) { providers.append(path) }
    }
    expectEqual(Set(found.keys), Set(expectedIntentFiles.keys), "exactly the ten contract intents exist")
    for (name, file) in expectedIntentFiles {
        expectEqual(found[name] ?? [], [file], "\(name) is defined once, in \(file)")
    }
    expectEqual(providers, ["NativeAppIntents.swift"], "one AppShortcutsProvider, in the app-only NativeAppIntents.swift")
    let widgetOnly = swiftSources(under: widgetRoot)
    expect(widgetOnly.allSatisfy { !$0.text.contains("AppIntent") && !$0.text.contains("AppShortcutsProvider") },
           "the extension-only root defines no intent (timer intents come from Shared/)")

    // One 17.0 floor, no mixed availability (§5.4).
    for path in Set(expectedIntentFiles.values).union(["NativeAppIntents.swift"]) {
        guard let text = sources.first(where: { $0.path == path })?.text else { expect(false, "\(path) exists"); continue }
        let declarations = matches(#"(?m)^\s*(?:struct|enum)\s+\w+\s*:\s*(?:AppIntent|AppEnum|AppShortcutsProvider)\b"#, in: text).count
        let floors = matches(#"@available\(iOS 17\.0, \*\)\s*\n\s*(?:struct|enum)\s+\w+\s*:\s*(?:AppIntent|AppEnum|AppShortcutsProvider)\b"#, in: text).count
        expectEqual(floors, declarations, "\(path): every App Intents type carries exactly @available(iOS 17.0, *)")
        let availabilities = Set(matches(#"@available\(([^)]*)\)"#, in: text).map { $0[1] })
        expect(availabilities.isSubset(of: ["iOS 17.0, *"]), "\(path): no other availability floor (\(availabilities))")
    }

    // Fix round 1 (I1): the string field rules exist once, in the shared file.
    let actionQueueFiles: Set<String> = [
        "NativeWidgetActionReplay.swift", "Widgets/Shared/WidgetActionQueue.swift",
        "Widgets/Shared/WidgetIntents.swift", "Intents/JobActionIntents.swift", "Intents/OnMyWayIntent.swift",
    ]
    expectEqual(Set(sources.map(\.path)).intersection(actionQueueFiles), actionQueueFiles, "scan sees the action-queue files")
    for (path, text) in sources where actionQueueFiles.contains(path) {
        expect(!text.contains("CharacterSet.controlCharacters.contains") && !text.contains("rebuilt.year == year"),
               "\(path) does not re-implement the action field rules")
    }

    // Phrases, short titles and symbols (§5.2), in provider order.
    let shortcutsText = sources.first(where: { $0.path == "NativeAppIntents.swift" })?.text ?? ""
    let shortcuts = matches(#"intent:\s*(\w+)\(\),\s*phrases:\s*\[\s*"([^"]+)",\s*"([^"]+)",\s*\],\s*shortTitle:\s*"([^"]+)",\s*systemImageName:\s*"([^"]+)""#, in: shortcutsText)
        .map { Array($0.dropFirst()) }
    let app = #"\(.applicationName)"#
    expectEqual(shortcuts, [
        ["NextJobIntent", "What's my next job in \(app)", "What's next in \(app)", "Next Job", "calendar"],
        ["StartTripIntent", "Start a trip in \(app)", "Start tracking miles in \(app)", "Start Trip", "car"],
        ["StopTripIntent", "Stop my trip in \(app)", "Finish my trip in \(app)", "Stop Trip", "car.fill"],
        ["OnMyWayIntent", "I'm on my way in \(app)", "Tell my customer I'm on my way in \(app)", "On My Way", "message"],
        ["ClockInIntent", "Clock in in \(app)", "Start the clock in \(app)", "Clock In", "play.circle"],
        ["ClockOutIntent", "Clock out in \(app)", "Stop the clock in \(app)", "Clock Out", "stop.circle"],
        ["LogExpenseIntent", "Log an expense in \(app)", "Add an expense in \(app)", "Log Expense", "dollarsign.circle"],
        ["OutstandingIntent", "How much am I owed in \(app)", "What's outstanding in \(app)", "Outstanding", "banknote"],
    ], "the eight Siri shortcuts carry the §5.2 phrases, titles and symbols")

    guard #available(macOS 14.0, iOS 17.0, *) else { return expect(false, "host supports App Intents") }
    expectEqual(TradeReadyShortcuts.appShortcuts.count, 8, "the provider registers eight shortcuts (timers have none)")

    // Compiled type facts.
    func title(_ resource: LocalizedStringResource) -> String { String(localized: resource) }
    expectEqual(title(NextJobIntent.title), "Next Job", "title")
    expectEqual(title(StartTripIntent.title), "Start Mileage Trip", "title")
    expectEqual(title(StopTripIntent.title), "Stop Mileage Trip", "title")
    expectEqual(title(OnMyWayIntent.title), "On My Way", "title")
    expectEqual(title(ClockInIntent.title), "Clock In", "title")
    expectEqual(title(ClockOutIntent.title), "Clock Out", "title")
    expectEqual(title(LogExpenseIntent.title), "Log Expense", "title")
    expectEqual(title(OutstandingIntent.title), "Outstanding Invoices", "title")
    expectEqual(title(StartTimerIntent.title), "Start Job Timer", "title")
    expectEqual(title(StopTimerIntent.title), "Stop Job Timer", "title")
    expect(!StartTimerIntent.isDiscoverable && !StopTimerIntent.isDiscoverable, "timer intents are not discoverable")
    expect(OnMyWayIntent.openAppWhenRun, "On My Way opens the app")
    expect(![NextJobIntent.openAppWhenRun, StartTripIntent.openAppWhenRun, StopTripIntent.openAppWhenRun,
             ClockInIntent.openAppWhenRun, ClockOutIntent.openAppWhenRun, LogExpenseIntent.openAppWhenRun,
             OutstandingIntent.openAppWhenRun, StartTimerIntent.openAppWhenRun, StopTimerIntent.openAppWhenRun]
        .contains(true), "every other intent runs without opening the app")
    expectEqual(StartTimerIntent(jobId: "j9").jobId, "j9", "the widget button passes its job id")

    // Expense AppEnum (§5.3): raw values = RN ids; labels = the app's display labels.
    let contractIDs = ["materials", "tools", "fuel", "labor", "insurance", "software", "marketing", "other"]
    expectEqual(SiriExpenseCategory.allCases.map(\.rawValue), contractIDs, "AppEnum raw values are the RN ids, in order")
    expectEqual(WidgetExpenseCategory.allCases.map(\.rawValue), contractIDs, "queue categories are the RN ids")
    let labels = ["Materials", "Tools & Equipment", "Fuel & Transport", "Subcontractors",
                  "Insurance", "Software & Apps", "Marketing", "Other"]
    for (index, category) in SiriExpenseCategory.allCases.enumerated() {
        let shown = SiriExpenseCategory.caseDisplayRepresentations[category].map { title($0.title) }
        expectEqual(shown, labels[index], "Siri shows the §5.3 label for \(category.rawValue)")
        expectEqual(category.queueCategory.rawValue, category.rawValue, "\(category.rawValue) queues as itself")
        expectEqual(category.queueCategory.label, labels[index], "the spoken label matches what Siri shows")
    }
}

// MARK: - Main

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
    var failureValue: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}

@main
struct AppIntentQueueTests {
    @MainActor
    static func main() async throws {
        testTimerIntents()
        testClockInOut()
        testWriterRules()
        try testTripSession()
        try testLogExpense()
        testOnMyWayStash()
        testReadOnlyIntents()
        testLockDiscipline()
        testRouter()
        try await testAppStoreHandoffAndReplay()
        testDeclarations()

        if failures > 0 {
            print("App intent queue tests: \(failures) failure(s)")
            exit(1)
        }
        print("App intent queue tests passed")
    }
}
