import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Widget/Siri owner gating, stale data and sign-in correctness (task 11.05,
// requirement W4).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §2.5 (the single owner predicate `O = AppStore.derivedStatePublishBinding`;
// the "Replay gate" row), C22, §3.1 (write gate and scrub), §3.3 (stale
// window), §4.2 (one lock), §4.5 (owner stamping; replay drops untagged and
// foreign actions BEFORE type dispatch), §4.6 and C8 (quarantine).
//
// Every fixture must end in route-or-discard with no cross-owner leak on the
// widget, Siri or deep-link paths. Everything runs against the REAL code:
// `AppStore` (the replay gate, the scrub paths, the mirror, `handle(url:)`),
// `NativeWidgetActionReplayCoordinator` / claim transport / planner /
// replayer, `NativeAppGroupAccountScrubber`, `NativeWidgetMirror`, and the
// extension's `WidgetIntentEngine`. Every App Group touch uses a throwaway
// suite plus a throwaway lock file (a plain `swiftc` binary has no App Group
// entitlement). Run with TZ=America/Phoenix.

private var failures = 0
/// Recorded gaps owned by a later task: printed, never counted as passing.
private var knownGaps: [String] = []

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
/// RN `NOW = new Date(2026, 7, 3, 12, 0, 0)` in Phoenix = 2026-08-03T19:00:00Z.
private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-03T19:00:00Z")!
/// Two 64-hex account bindings (the shape `verifiedAccountBinding` has).
private let bindingA = String(repeating: "a1", count: 32)
private let bindingB = String(repeating: "b2", count: 32)
private let tagA = NativeWidgetOwnerTag.make(binding: bindingA)
private let tagB = NativeWidgetOwnerTag.make(binding: bindingB)

private func iso(_ date: Date) -> String { WidgetSnapshot.isoTimestamp(date) }

private func tempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1105-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One queued action as the extension writes it (`ownerTag` nil = untagged).
private func action(
    _ id: String, _ type: String, tag: String?, at: String = "2026-08-03T18:00:00.000Z",
    _ extra: [String: Any] = [:]
) -> [String: Any] {
    var fields: [String: Any] = ["id": id, "type": type, "at": at]
    if let tag { fields["ownerTag"] = tag }
    fields.merge(extra) { _, new in new }
    return fields
}

private func queueJSON(_ entries: [Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]), encoding: .utf8)!
}

private let expenseFields: [String: Any] = ["date": "2026-08-03", "amount": 12.5, "category": "fuel"]
private let tripFields: [String: Any] = ["date": "2026-08-03", "odometerStart": 100, "odometerEnd": 110]

private func job(_ id: String, _ overrides: [String: Any] = [:]) -> Canonical.Job {
    var fields: [String: Any] = [
        "id": id, "customerId": "c-\(id)", "customerName": "Customer \(id)", "title": "Job \(id)",
        "description": "", "status": "scheduled", "scheduledDate": "2099-01-01",
        "scheduledStartTime": "10:30", "scheduledEndTime": NSNull(), "address": "1 Main St",
        "estimateTotal": 0, "laborHours": 0, "laborRate": 0, "materials": [], "materialMarkup": 0,
        "overhead": 0, "margin": 0, "notes": "", "invoiceId": NSNull(), "createdAt": "2026-08-01",
        "timeSessions": [],
    ]
    fields.merge(overrides) { _, new in new }
    return try! JSONDecoder().decode(Canonical.Job.self, from: JSONSerialization.data(withJSONObject: fields))
}

private func encoded(_ snapshot: Canonical.Snapshot?) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot?.payload)
}

private func canonical(_ jobs: [Canonical.Job]) -> Canonical.Snapshot {
    Canonical.Snapshot(payload: Canonical.SnapshotPayload(invoices: [], jobs: jobs))
}

/// A throwaway App Group suite, its lock file, the real scrubber and engine.
private final class TempSuite {
    let name = "com.tradeready.owner-gating.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root = tempDirectory("group")
    var lockFile: URL { root.appendingPathComponent(WidgetAppGroup.lockFileName) }

    init(defaults make: (String) -> UserDefaults = { UserDefaults(suiteName: $0)! }) {
        defaults = make(name)
    }

    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(suiteName: name, defaults: defaults, lockFile: lockFile)
    }

    func engine(at date: Date = Date(), store: (any WidgetAppGroupKeyValueStore)? = nil) -> WidgetIntentEngine {
        WidgetIntentEngine(environment: WidgetIntentEnvironment(
            store: store ?? defaults, lockFile: lockFile, now: { date },
            makeActionID: { UUID().uuidString }, timeZone: phoenix
        ))
    }

    func transport(claims: URL) -> NativeWidgetActionClaimTransport {
        NativeWidgetActionClaimTransport(
            queue: NativeUserDefaultsWidgetActionQueue(defaults: defaults),
            claimDirectory: claims,
            lockFile: lockFile
        )
    }

    /// Task 11.06: the real stash consumer on this suite and lock file.
    var pendingOpenURLConsumer: NativePendingOpenURLConsumer {
        NativePendingOpenURLConsumer(inbox: NativeUserDefaultsAppGroupInbox(defaults: defaults), lockFile: lockFile)
    }

    var isEmpty: Bool { WidgetAppGroup.accountKeys.allSatisfy { defaults.object(forKey: $0) == nil } }
    var queue: String? { defaults.string(forKey: WidgetAppGroup.actionsKey) }

    func cleanUp() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class Box<T>: @unchecked Sendable {
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

/// Phase 12 (L132): true while another open file description holds the lock
/// (a `LOCK_NB` probe on a fresh descriptor fails).
private func lockIsHeld(at url: URL) -> Bool {
    let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
    flock(descriptor, LOCK_UN)
    return false
}

/// Phase 12 (12.00b.2-B): holds the lock with an idempotent `release()`.
/// `releaseAfter` is a safety valve, so code that still blocks on the lock
/// fails on timing instead of hanging the run.
private final class LockHolder {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(at url: URL, releaseAfter seconds: TimeInterval) {
        descriptor = holdLock(at: url)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.release() }
    }

    deinit { release() }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { return }
        releaseLock(descriptor)
        self.descriptor = nil
    }
}

/// Phase 12 (L132): counts entries into `removePersistentDomain` (the
/// scrubber's in-lock critical section), so a test can prove the scrub has
/// not reached it yet.
private final class ProbedDefaults: UserDefaults {
    private let entries = Box<Int>()
    var removeEntries: Int { entries.get() ?? 0 }
    override func removePersistentDomain(forName domainName: String) {
        entries.set(removeEntries + 1)
        super.removePersistentDomain(forName: domainName)
    }
}

/// The real UserDefaults, except that `removePersistentDomain` (the
/// scrubber's in-lock critical section) can be paused, so the REAL scrubber
/// holds the REAL lock while writers queue up behind it.
private final class GatedDefaults: UserDefaults {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let armedBox = Box<Bool>()
    func arm() { armedBox.set(true) }

    override func removePersistentDomain(forName domainName: String) {
        if armedBox.get() == true {
            armedBox.set(false)
            entered.signal()
            release.wait()
        }
        super.removePersistentDomain(forName: domainName)
    }
}

/// An App Group store whose `widgetActions` write can be paused mid-append,
/// i.e. while the extension writer holds the lock.
private final class GatedStore: WidgetAppGroupKeyValueStore {
    let base: UserDefaults
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(_ base: UserDefaults) { self.base = base }
    func string(forKey defaultName: String) -> String? { base.string(forKey: defaultName) }
    func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == WidgetAppGroup.actionsKey {
            entered.signal()
            release.wait()
        }
        base.set(value, forKey: defaultName)
    }
    func removeObject(forKey defaultName: String) { base.removeObject(forKey: defaultName) }
}

/// An in-memory queue backing for the transport. `scriptedFirstRead` is
/// returned by the first read only (a queue that changes between lock holds);
/// `blockReads` pauses a read while the transport holds the lock.
private final class MemoryQueue: NativeWidgetActionQueueBacking {
    var value: String?
    var scriptedFirstRead: String?
    var blockReads = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? {
        if blockReads { blockReads = false; entered.signal(); release.wait() }
        if let scripted = scriptedFirstRead { scriptedFirstRead = nil; return scripted }
        return value
    }
    func write(_ value: String?) { self.value = value }
}

@MainActor
private final class SubscriptionStub: NativeSubscriptionServing {
    var onLogOut: () -> Void = {}
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    func logOut() async { onLogOut() }
}

/// Records every timeline reload and what the suite held at that instant.
private final class RecordingReloader: NativeWidgetTimelineReloading {
    var count = 0
    var suiteWasEmptyAtEveryReload = true
    var probe: () -> Bool = { true }
    func reloadAllTimelines() {
        count += 1
        if !probe() { suiteWasEmptyAtEveryReload = false }
    }
}

@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<5 { await Task.yield() }
}

/// A local workspace on disk: canonical jobs plus (optionally) the completed
/// onboarding document that binds it to `binding` — what makes `O` hold for
/// a native-only account.
private struct Workspace {
    let directory = tempDirectory("store")
    var fileURL: URL { directory.appendingPathComponent("store.json") }
    var claims: URL { directory.appendingPathComponent("WidgetActionClaims", isDirectory: true) }

    func write(jobs: [Canonical.Job]) throws {
        try Canonical.SnapshotRepository(primaryURL: fileURL).save(canonical(jobs))
    }

    func bind(_ binding: String, stage: NativeOnboardingDocument.Stage = .done) throws {
        try NativeOnboardingStore(snapshotURL: fileURL).save(NativeOnboardingDocument(
            accountBinding: binding, stage: stage,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
    }

    func load() throws -> Canonical.Snapshot? { try Canonical.SnapshotRepository(primaryURL: fileURL).load()?.snapshot }

    func claimFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: claims.path)) ?? []).sorted()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private func makeStore(
    _ workspace: Workspace,
    suite: TempSuite,
    reloader: RecordingReloader = RecordingReloader(),
    subscription: (any NativeSubscriptionServing)? = nil,
    scrubber: NativeAppGroupAccountScrubber? = nil,
    installMirror: Bool = true,
    // Review M6: the host-only in-memory Keychain, never the login Keychain.
    secureSettingsStore: NativeKeychainSecureSettingsStore = hostTestSecureSettingsStore()
) -> AppStore {
    let store = AppStore(
        fileURL: workspace.fileURL,
        seedIfMissing: false,
        widgetActionReplayTransport: suite.transport(claims: workspace.claims),
        appGroupAccountScrubber: scrubber ?? suite.scrubber,
        pendingOpenURLConsumer: suite.pendingOpenURLConsumer,
        subscriptionService: subscription ?? SubscriptionStub(),
        widgetTimelineReloader: reloader,
        secureSettingsStore: secureSettingsStore
    )
    if installMirror {
        // The mirror's own post-write reloads go to a separate recorder, so
        // `reloader` sees exactly the AppStore's account-scrub reloads.
        store.installWidgetMirror(NativeWidgetMirror(defaults: suite.defaults, lockFile: suite.lockFile, reloader: RecordingReloader()))
    }
    return store
}

// MARK: - 1. The owner predicate and the replay gate (pure; §2.5, C22)

private func testPureOwnerGate() {
    expectEqual(tagA.count, 64, "the tag is a 64-hex SHA-256")
    expect(tagA != tagB, "different owners get different tags")
    expect(NativeWidgetOwnerTag.matches(tagA, binding: bindingA), "hash(O) matches O")
    expect(!NativeWidgetOwnerTag.matches(tagA, binding: bindingB), "another owner's tag never matches")
    expect(!NativeWidgetOwnerTag.matches(nil, binding: bindingA), "a missing tag never matches (§4.5)")
    expect(!NativeWidgetOwnerTag.matches(tagA.uppercased(), binding: bindingA), "tags compare exactly (no case folding)")
    expect(!NativeWidgetOwnerTag.matches(bindingA, binding: bindingA), "the raw binding is not the tag")

    let gate = NativeWidgetReplayOwnerGate.self
    expectEqual(gate.replayBinding(ownerBinding: bindingA, isSignedIn: true, accountBoundaryOpen: false), bindingA,
                "O + .signedIn + no boundary → replay for O")
    expect(gate.replayBinding(ownerBinding: nil, isSignedIn: true, accountBoundaryOpen: false) == nil,
           "no O → no replay")
    expect(gate.replayBinding(ownerBinding: bindingA, isSignedIn: false, accountBoundaryOpen: false) == nil,
           "O in a post-sign-in gate (paywall, onboarding…) → no replay: replay mutates data")
    expect(gate.replayBinding(ownerBinding: bindingA, isSignedIn: true, accountBoundaryOpen: true) == nil,
           "an open account boundary (scrub in progress/pending) → no replay")
    expect(gate.replayBinding(ownerBinding: "", isSignedIn: true, accountBoundaryOpen: false) == nil,
           "an empty binding is no owner")
}

// MARK: - 2. The planner's owner gate (§4.5): before type dispatch

private func testPlannerOwnerGate() throws {
    let raw = queueJSON([
        action("a-start", "timer_start", tag: tagA, ["jobId": "j1"]),       // previous owner, same job id
        action("b-exp", "expense_log", tag: tagB, expenseFields),           // current owner
        action("u-trip", "trip_log", tag: nil, tripFields),                 // untagged (RN-era)
        42,                                                                 // not an object: no owner
        action("u-future", "future_kind", tag: nil),                        // untagged unknown type
        action("a-future", "future_kind", tag: tagA),                       // foreign unknown type
        action("", "timer_stop", tag: tagA),                                // foreign AND malformed
        action("b-exp", "timer_stop", tag: nil),                            // untagged duplicate of b-exp
        action("b-exp-upper", "expense_log", tag: tagB.uppercased(), expenseFields),
        action("b-raw", "expense_log", tag: bindingB, expenseFields),       // raw binding, not hashed
    ])
    let batch = try NativeWidgetActionBatchPlanner.prepare(rawValue: raw, verifiedAccountBinding: bindingB)
    expectEqual(batch.actions.map(\.id), ["b-exp"], "only the action stamped hash(O) survives")
    expectEqual(batch.ownerDroppedCount, 9, "every untagged/foreign/non-object entry is counted as dropped")
    expect(batch.sourceBytes == Data(raw.utf8), "the claim still covers the exact source bytes (dropped entries are acknowledged)")

    // Only tagged, owner-matched unknown types are retained (§4.6 under §4.5).
    let owned = try NativeWidgetActionBatchPlanner.prepare(
        rawValue: queueJSON([action("b-future", "future_kind", tag: tagB)]), verifiedAccountBinding: bindingB
    )
    expectEqual(owned.actions.map(\.kind), [.unknown("future_kind")], "an owner-matched unknown type is retained")
    let foreignUnknown = try NativeWidgetActionBatchPlanner.prepare(
        rawValue: queueJSON([action("a-future", "future_kind", tag: tagA), action("u-future", "x_kind", tag: nil)]),
        verifiedAccountBinding: bindingB
    )
    expect(foreignUnknown.actions.isEmpty && foreignUnknown.ownerDroppedCount == 2,
           "an untagged or foreign unknown type is dropped, not retained (it cannot hold the claim)")

    // A foreign malformed entry can never wedge the owner's batch…
    do {
        _ = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: queueJSON([action("", "timer_start", tag: tagA), action("b1", "expense_log", tag: tagB, expenseFields)]),
            verifiedAccountBinding: bindingB
        )
    } catch { expect(false, "a foreign malformed entry must not fail the owner's batch (\(error))") }
    // …but the owner's own malformed entry still fails preparation (→ C8).
    do {
        _ = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: queueJSON([action("b1", "timer_start", tag: tagB)]), verifiedAccountBinding: bindingB
        )
        expect(false, "an owner-tagged invalid action still fails preparation")
    } catch let error as NativeWidgetActionBatchError {
        expectEqual(error, .invalidAction(index: 0, field: "jobId"), "the owner's invalid action is reported")
    }
}

// MARK: - 3. The replay gate in AppStore: native-only owner (the §2.5 gap)

@MainActor
private func testReplayGateNativeOwner() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    // B's workspace. "j1" exists here AND is the id an A-era action names.
    try workspace.write(jobs: [job("j1"), job("j2")])
    let store = makeStore(workspace, suite: suite, installMirror: false)
    let queued = queueJSON([
        action("a-exp", "expense_log", tag: tagA, expenseFields),
        action("a-start", "timer_start", tag: tagA, ["jobId": "j1"]),
        action("u-trip", "trip_log", tag: nil, tripFields),
        action("b-start", "timer_start", tag: tagB, ["jobId": "j1"]),
        action("b-exp", "expense_log", tag: tagB, expenseFields),
    ])
    suite.defaults.set(queued, forKey: WidgetAppGroup.actionsKey)

    // Native-only B, workspace not yet bound: O is nil → nothing is claimed.
    store.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    expect(!store.isMigratedLocalOwnerVerified, "sanity: a native-only account (no migrated owner proof)")
    expect(store.derivedStatePublishBinding == nil, "no completed workspace bound to B → O is nil")
    store.testReplayWidgetActions()
    expectEqual(suite.queue, queued, "without O nothing is claimed: the queue is byte-identical")
    expect(workspace.claimFiles().isEmpty, "without O no claim file is written")

    // Bind the completed workspace: O = B. Every gate other than .signedIn
    // still refuses replay (it mutates data), and the queue stays untouched.
    try workspace.bind(bindingB)
    let refusing: [(String, NativeAuthenticationGateState)] = [
        ("paywall", .paywall(offering: nil, message: nil)),
        ("onboarding", .onboarding(.init(businessName: "B", contactName: "B", trade: .other, step: 0))),
        ("startingPoint", .startingPoint(.other)),
        ("subscriptionLoading", .subscriptionLoading),
        ("accountMismatch", .accountMismatch),
        ("unavailable", .unavailable),
        ("signedOut", .signedOut),
        ("loading", .loading),
        ("initialSyncLoading", .initialSyncLoading),
        ("passwordRecovery", .passwordRecovery(email: nil)),
    ]
    for (label, gate) in refusing {
        store.testSetAuthenticationGateState(gate)
        expect(store.widgetActionReplayBinding == nil, "\(label): no replay binding")
        store.testReplayWidgetActions()
        expectEqual(suite.queue, queued, "\(label): replay claims nothing")
    }

    // .signedIn + O: the native-only owner replays (the 11.05 gap is closed).
    store.testSetAuthenticationGateState(.signedIn(email: nil))
    expectEqual(store.derivedStatePublishBinding, bindingB, "O = B through the completed-workspace branch")
    expectEqual(store.widgetActionReplayBinding, bindingB, "the replay gate opens on O for a native-only account")
    store.testReplayWidgetActions()
    let saved = try workspace.load()
    let j1 = saved?.payload.jobs?.first { $0.id == "j1" }
    expectEqual(j1?.timeSessions?.count, 1, "exactly ONE session on j1: B's, never A's same-id action")
    expectEqual(j1?.timeSessions?.first?.start, "2026-08-03T18:00:00.000Z", "the session is B's timer_start")
    expectEqual(j1?.timeSessions?.first?.preservation.unknownFields["__nativeWidgetStartActionID"], .string("b-start"),
                "the applied marker is B's action id")
    expectEqual(saved?.payload.expenses?.map(\.id), ["e_siri_b-exp"], "only B's expense is filed; A's is dropped")
    expect(saved?.payload.trips?.isEmpty ?? true, "the untagged trip is dropped, not filed")
    expect(suite.queue == nil, "the whole claimed queue is acknowledged (dropped entries included)")
    expect(workspace.claimFiles().isEmpty, "the claim is acknowledged")
    expectEqual(store.widgetActionReplayDiagnostics.ownerDroppedActionCount, 3, "three entries dropped, counted without payload")
    expect(store.migrationMessage == nil, "a dropped foreign action surfaces no message")
    expectEqual(store.jobs.first { $0.id == "j1" }?.status, .inProgress, "in-memory state is the committed replay")
    // Final review C1: the replay queues B's writes for sync — only B's, and
    // only once the gate opened on O (the refused gates above queued nothing).
    let queuedWrites = Canonical.NativeMutationQueue(fileURL: workspace.directory.appendingPathComponent("mutation-queue.json"))
        .load().map { "\($0.table)/\($0.recordId)" }
    expectEqual(Set(queuedWrites), ["jobs/j1", "expenses/e_siri_b-exp"],
                "C1: exactly B's replayed records are queued for sync (none of the dropped entries)")
}

// MARK: - 4. Cross-sign-in: A signs out, B signs in (widget, Siri, claims)

@MainActor
private func testCrossSignIn() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    let reloader = RecordingReloader()
    reloader.probe = { suite.isEmpty }
    let subscription = SubscriptionStub()
    try workspace.write(jobs: [job("j1", ["customerName": "Alice (A)", "scheduledDate": "2099-01-01"])])
    try workspace.bind(bindingA)
    let storeA = makeStore(workspace, suite: suite, reloader: reloader, subscription: subscription)
    storeA.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    let mirroredA = WidgetSnapshot.load(from: suite.defaults)
    expectEqual(mirroredA?.ownerTag, tagA, "A's snapshot is mirrored, tagged hash(A)")
    expectEqual(mirroredA?.nextJob?.customerName, "Alice (A)", "sanity: A's data is on the widget")

    // A's Siri/widget actions, stash and trip — plus an in-flight claim of A.
    let engine = suite.engine()
    guard case .clockedIn = engine.clockIn() else { return expect(false, "A clocks in via Siri") }
    _ = engine.logExpense(amount: 20, category: .fuel, description: "A fuel")
    _ = engine.startTrip(odometerStart: 10)
    _ = engine.stashOnMyWay()
    _ = try suite.transport(claims: workspace.claims).claim(verifiedAccountBinding: bindingA)
    expect(!workspace.claimFiles().isEmpty, "sanity: A has an in-flight claim (WAL) keyed by bindingA")
    _ = engine.logExpense(amount: 30, category: .tools, description: "A tools") // after the claim

    // During the sign-out's `await logOut()` suspension the boundary is open:
    // no mirror write, no replay, and the suite is already empty + reloaded.
    var duringBoundary: (NativeWidgetMirrorOutcome?, Bool, Int, Bool)?
    subscription.onLogOut = { [weak storeA] in
        guard let storeA else { return }
        let outcome = storeA.refreshWidgetMirror(force: true)
        storeA.testReplayWidgetActions()
        duringBoundary = (outcome, suite.isEmpty, reloader.count, storeA.widgetActionReplayBinding == nil)
    }
    let reloadsBefore = reloader.count
    try await storeA.signOut(revokeRemote: false)
    await settle()

    expectEqual(duringBoundary?.0, .skippedNoOwner, "no mirror write lands inside the sign-out boundary")
    expect(duringBoundary?.1 == true, "the suite is already scrubbed before the boundary's first await")
    expect((duringBoundary?.2 ?? 0) > reloadsBefore, "timelines are reloaded right after the wipe, before the logOut await")
    expect(duringBoundary?.3 == true, "the replay gate is closed inside the boundary")
    expect(reloader.suiteWasEmptyAtEveryReload, "every post-scrub reload saw an empty suite (no stale owner rendered)")
    expect(suite.isEmpty, "sign-out wipes snapshot, queue, trip and stash")
    expect(workspace.claimFiles().isEmpty, "sign-out removes A's in-flight claim (app-private WAL of A's actions)")
    expectEqual(storeA.refreshWidgetMirror(force: true), .skippedNoOwner, "no owner → no snapshot written")
    expect(WidgetSnapshot.load(from: suite.defaults) == nil, "the suite stays empty after sign-out")
    expectEqual(suite.engine().clockIn(), .failed(.signInRequired), "Siri refuses after sign-out (no snapshot/tag)")
    expectEqual(suite.engine().logExpense(amount: 5, category: .fuel, description: nil), .failed(.signInRequired),
                "an expense cannot be queued into the gap between owners")
    expect(suite.isEmpty, "a refused intent writes nothing")

    // B signs in (cold launch on B's workspace). A leftover A-tagged queue and
    // an old-binding claim + quarantine (e.g. from before the gate moved to O)
    // are planted to prove the replay gate fails closed on its own.
    try workspace.write(jobs: [job("j1", ["customerName": "Bob (B)"]), job("j7", ["customerName": "Bob (B)"])])
    try workspace.bind(bindingB)
    suite.defaults.set(queueJSON([action("a-late", "expense_log", tag: tagA, expenseFields),
                                  action("a-start2", "timer_start", tag: tagA, ["jobId": "j1"])]),
                       forKey: WidgetAppGroup.actionsKey)
    let leftoverQueue = MemoryQueue(queueJSON([action("a-old", "expense_log", tag: tagA, expenseFields)]))
    _ = try NativeWidgetActionClaimTransport(queue: leftoverQueue, claimDirectory: workspace.claims, lockFile: suite.lockFile)
        .claim(verifiedAccountBinding: bindingA)
    let quarantineA = MemoryQueue("{broken")
    _ = try NativeWidgetActionClaimTransport(queue: quarantineA, claimDirectory: workspace.claims, lockFile: suite.lockFile)
        .quarantineUnpreparableQueue(verifiedAccountBinding: bindingA)
    expectEqual(workspace.claimFiles().filter { $0.contains(bindingA) }.count, 2,
                "sanity: an old-binding claim and quarantine file are present")

    let storeB = makeStore(workspace, suite: suite, reloader: reloader)
    storeB.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    await settle()
    let mirroredB = WidgetSnapshot.load(from: suite.defaults)
    expectEqual(mirroredB?.ownerTag, tagB, "B's snapshot is tagged hash(B)")
    expectEqual(mirroredB?.nextJob?.customerName, "Bob (B)", "the widget shows only B's data")
    storeB.testReplayWidgetActions()
    let saved = try workspace.load()
    expect(saved?.payload.expenses?.isEmpty ?? true, "no A-tagged expense is applied to B")
    expect(saved?.payload.jobs?.allSatisfy { ($0.timeSessions ?? []).isEmpty } == true,
           "A's timer_start for the shared id j1 is never applied to B's j1")
    expect(workspace.claimFiles().allSatisfy { !$0.contains(bindingA) },
           "the old-binding claim and quarantine are discarded, unread")
    expect(suite.queue == nil, "the foreign queue is acknowledged and gone")
    expectEqual(storeB.widgetActionReplayDiagnostics.ownerDroppedActionCount, 2, "the foreign actions are counted")

    // B's own actions now replay normally.
    let engineB = suite.engine()
    guard case .clockedIn = engineB.clockIn() else { return expect(false, "B clocks in against B's snapshot") }
    storeB.testReplayWidgetActions()
    let afterB = try workspace.load()
    expectEqual(afterB?.payload.jobs?.first { $0.id == "j1" }?.timeSessions?.count, 1, "B's clock-in applies to B's next job")
}

// MARK: - 5. The real scrub race: the real scrubber vs blocked writers

@MainActor
private func testRealScrubRace() async throws {
    // (a) sign-out's scrubber holds the lock mid-wipe while extension writers
    // queue up behind it. They read the snapshot INSIDE their own lock hold,
    // after the wipe, find no owner and write nothing.
    let suite = TempSuite(defaults: { GatedDefaults(suiteName: $0)! })
    let gated = suite.defaults as! GatedDefaults
    let workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    try workspace.write(jobs: [job("j1")])
    try workspace.bind(bindingA)
    let store = makeStore(workspace, suite: suite)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    expectEqual(WidgetSnapshot.load(from: suite.defaults)?.ownerTag, tagA, "sanity: A's snapshot is present")

    let engine = suite.engine()
    let writersBlocked = Box<Bool>()
    let results = Box<[String]>()
    gated.arm()
    Thread {
        gated.entered.wait() // the REAL scrubber is inside its lock hold
        let (expense, expenseDone) = runInBackground { engine.logExpense(amount: 9, category: .fuel, description: nil) }
        let (clockIn, clockInDone) = runInBackground { engine.clockIn() }
        let (trip, tripDone) = runInBackground { engine.startTrip(odometerStart: 5) }
        let (stash, stashDone) = runInBackground { engine.stashOnMyWay() }
        let dones = [expenseDone, clockInDone, tripDone, stashDone]
        Thread.sleep(forTimeInterval: 0.3)
        writersBlocked.set(dones.allSatisfy { $0.wait(timeout: .now()) == .timedOut })
        gated.release.signal()
        dones.forEach { _ = $0.wait(timeout: .now() + 10) }
        results.set([
            "\(String(describing: expense.get()))", "\(String(describing: clockIn.get()))",
            "\(String(describing: trip.get()))", "\(String(describing: stash.get()))",
        ])
    }.start()
    try await store.signOut(revokeRemote: false)
    for _ in 0..<200 where results.get() == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    expect(writersBlocked.get() == true, "every writer was blocked on the lock the real scrubber held")
    expectEqual(results.get()?.filter { $0.contains("signInRequired") }.count, 4,
                "all four writers refuse after the wipe (\(results.get() ?? []))")
    expect(suite.isEmpty, "nothing re-populates the suite after the real scrub")

}

private func testRealScrubRaceWriterFirst() throws {
    // (b) the reverse: an extension writer holds the lock mid-append while the
    // real scrubber waits for it. The append lands first, then the scrub wipes
    // it: no action survives into the next account.
    let suite2 = TempSuite(defaults: { ProbedDefaults(suiteName: $0)! })
    let probed = suite2.defaults as! ProbedDefaults
    defer { suite2.cleanUp() }
    try suite2.defaults.set(WidgetSnapshot(
        updatedAt: iso(Date()), nextJob: nil, timer: nil, outstandingTotal: 0, ownerTag: tagA
    ).encodedJSON(), forKey: WidgetAppGroup.snapshotKey)
    let gatedStore = GatedStore(suite2.defaults)
    let writer = suite2.engine(store: gatedStore)
    let (logged, loggedDone) = runInBackground { writer.logExpense(amount: 11, category: .fuel, description: nil) }
    gatedStore.entered.wait() // the writer holds the lock, mid-append
    let scrubber = suite2.scrubber
    // Phase 12 (L132): prove the scrub is running and parked on the lock, not
    // merely slow to start. It signals right before `scrub()`; after the wait
    // it has not reached its in-lock wipe while the lock is still held, and
    // between entry and that wipe `scrub()` only creates the directory, opens
    // the lock file and acquires the lock.
    let scrubStarted = DispatchSemaphore(value: 0)
    let (scrubbed, scrubDone) = runInBackground { () -> Bool in
        scrubStarted.signal()
        return (try? scrubber.scrub()) != nil
    }
    expect(scrubStarted.wait(timeout: .now() + 5) == .success, "L132: the scrub has started")
    expect(scrubDone.wait(timeout: .now() + 0.3) == .timedOut, "the real scrubber waits for the writer's lock hold")
    expectEqual(probed.removeEntries, 0, "L132: the started scrub has not reached its in-lock wipe")
    expect(lockIsHeld(at: suite2.lockFile), "L132: …because the writer still holds the lock")
    gatedStore.release.signal()
    _ = loggedDone.wait(timeout: .now() + 10)
    _ = scrubDone.wait(timeout: .now() + 10)
    if case .logged = logged.get() {} else { expect(false, "the in-flight append completes (\(String(describing: logged.get())))") }
    expect(scrubbed.get() == true, "the scrub then succeeds")
    expectEqual(probed.removeEntries, 1, "L132: the wipe ran once, after the writer released the lock")
    expect(suite2.isEmpty, "the scrub wipes the just-appended action with everything else")
}

// MARK: - 6. C8 quarantine

private func coordinator(_ queue: MemoryQueue, _ root: URL, lockFile: URL) -> NativeWidgetActionReplayCoordinator {
    NativeWidgetActionReplayCoordinator(
        transport: NativeWidgetActionClaimTransport(
            queue: queue, claimDirectory: root.appendingPathComponent("claims"), lockFile: lockFile
        ),
        repository: Canonical.SnapshotRepository(primaryURL: root.appendingPathComponent("store.json")),
        enqueueWrittenRecords: { _, _ in }
    )
}

private func testQuarantine() throws {
    let root = tempDirectory("quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    let lockFile = root.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
    let base = canonical([job("j1")])
    let transport = { (queue: MemoryQueue) in
        NativeWidgetActionClaimTransport(queue: queue, claimDirectory: root.appendingPathComponent("claims"), lockFile: lockFile)
    }

    let wedges: [(String, String, NativeWidgetActionQuarantineReason)] = [
        ("malformed queue", "{not json", .malformedQueue),
        ("non-array queue", #"{"id":"x"}"#, .malformedQueue),
        ("duplicate owned ids", queueJSON([action("d", "timer_stop", tag: tagB), action("d", "timer_stop", tag: tagB)]), .duplicateActionID),
        ("owned invalid action", queueJSON([action("s", "timer_start", tag: tagB)]), .invalidAction),
        ("owned malformed action", queueJSON([action("", "timer_stop", tag: tagB)]), .malformedAction),
        ("more than 512 entries", queueJSON((0..<513).map { action("f\($0)", "timer_stop", tag: tagA) }), .tooManyActions),
    ]
    for (label, raw, reason) in wedges {
        let queue = MemoryQueue(raw)
        let replay = coordinator(queue, root, lockFile: lockFile)
        guard case .quarantined(let got) = try replay.replayNext(snapshot: base, verifiedAccountBinding: bindingB) else {
            expect(false, "\(label): quarantined instead of retried forever"); continue
        }
        expectEqual(got, reason, "\(label): reason")
        expect(queue.value == nil, "\(label): the shared queue is cleared only after the quarantine file is verified")
        let kept = try transport(queue).quarantinedQueues(accountBinding: bindingB)
        expect(kept.contains { $0.sourceBytes == Data(raw.utf8) && $0.reason == reason && $0.accountBinding == bindingB },
               "\(label): the exact bytes are kept in an owner-scoped quarantine file")
        // Not wedged: the owner's next action applies.
        queue.value = queueJSON([action("next-\(label.count)", "timer_start", tag: tagB, ["jobId": "j1"])])
        guard case .committed(_, 1, 0, 0) = try replay.replayNext(snapshot: base, verifiedAccountBinding: bindingB) else {
            expect(false, "\(label): a later action is no longer blocked"); continue
        }
    }
    // Bounded retention: at most 4 records per owner, oldest evicted.
    expectEqual(try transport(MemoryQueue()).quarantinedQueues(accountBinding: bindingB).count,
                NativeWidgetActionClaimTransport.maximumQuarantineFilesPerOwner, "quarantine retention is bounded per owner")

    // Oversized: digest and size only, never unbounded bytes.
    let huge = MemoryQueue("[" + String(repeating: " ", count: NativeWidgetActionClaimTransport.maximumQuarantinedBytes) + "x")
    let hugeRoot = tempDirectory("quarantine-huge")
    defer { try? FileManager.default.removeItem(at: hugeRoot) }
    _ = try coordinator(huge, hugeRoot, lockFile: lockFile).replayNext(snapshot: base, verifiedAccountBinding: bindingB)
    let hugeRecord = try NativeWidgetActionClaimTransport(
        queue: huge, claimDirectory: hugeRoot.appendingPathComponent("claims"), lockFile: lockFile
    ).quarantinedQueues(accountBinding: bindingB).first
    expect(hugeRecord?.sourceBytes == nil && hugeRecord?.sourceByteCount == NativeWidgetActionClaimTransport.maximumQuarantinedBytes + 2,
           "an oversized queue keeps only its digest and byte count")

    // A foreign malformed entry is NOT a reason to quarantine the owner's queue.
    let mixed = MemoryQueue(queueJSON([action("", "timer_start", tag: tagA), 7, action("ok", "timer_start", tag: tagB, ["jobId": "j1"])]))
    let mixedRoot = tempDirectory("quarantine-mixed")
    defer { try? FileManager.default.removeItem(at: mixedRoot) }
    guard case .committed(_, 1, 0, 2) = try coordinator(mixed, mixedRoot, lockFile: lockFile)
        .replayNext(snapshot: base, verifiedAccountBinding: bindingB) else {
        return expect(false, "foreign junk is dropped and the owner's action applies")
    }

    // The queue changed between the two lock holds and prepares now: nothing
    // is quarantined, the fresh queue is claimed and applied.
    let racing = MemoryQueue(queueJSON([action("r1", "timer_start", tag: tagB, ["jobId": "j1"])]))
    racing.scriptedFirstRead = "{broken"
    let racingRoot = tempDirectory("quarantine-race")
    defer { try? FileManager.default.removeItem(at: racingRoot) }
    guard case .committed(_, 1, 0, 0) = try coordinator(racing, racingRoot, lockFile: lockFile)
        .replayNext(snapshot: base, verifiedAccountBinding: bindingB) else {
        return expect(false, "a queue that became valid is claimed, not quarantined")
    }
    let racingKept = try NativeWidgetActionClaimTransport(queue: racing, claimDirectory: racingRoot.appendingPathComponent("claims"), lockFile: lockFile)
        .quarantinedQueues(accountBinding: bindingB)
    expect(racingKept.isEmpty, "…and no quarantine file is written")

    // A corrupt claim WAL is claim corruption, never a queue to quarantine.
    let corruptRoot = tempDirectory("quarantine-corrupt-claim")
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let pending = queueJSON([action("c1", "timer_stop", tag: tagB)])
    let corruptQueue = MemoryQueue(pending)
    let corruptTransport = NativeWidgetActionClaimTransport(
        queue: corruptQueue, claimDirectory: corruptRoot.appendingPathComponent("claims"), lockFile: lockFile
    )
    _ = try corruptTransport.claim(verifiedAccountBinding: bindingB)
    let claimFile = try FileManager.default.contentsOfDirectory(at: corruptRoot.appendingPathComponent("claims"), includingPropertiesForKeys: nil).first!
    try Data("corrupt".utf8).write(to: claimFile)
    corruptQueue.value = queueJSON([action("c2", "timer_stop", tag: tagB)])
    do {
        _ = try coordinator(corruptQueue, corruptRoot, lockFile: lockFile).replayNext(snapshot: base, verifiedAccountBinding: bindingB)
        expect(false, "a corrupt claim fails closed")
    } catch NativeWidgetActionClaimError.invalidClaim {
        expect(corruptQueue.value != nil, "…and the shared queue is left untouched (not quarantined)")
    }
}

@MainActor
private func testQuarantineInAppStore() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    try workspace.write(jobs: [job("j1")])
    try workspace.bind(bindingB)
    let store = makeStore(workspace, suite: suite, installMirror: false)
    store.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    suite.defaults.set(queueJSON([action("d", "timer_stop", tag: tagB), action("d", "timer_stop", tag: tagB)]),
                       forKey: WidgetAppGroup.actionsKey)
    store.testReplayWidgetActions()
    expectEqual(store.migrationMessage, NativeWidgetActionReplayCoordinator.quarantinedMessage, "a bounded message is surfaced")
    expect(store.migrationMessage?.contains("\"d\"") == false && store.migrationMessage?.contains(tagB) == false,
           "the message carries no id or owner value")
    expectEqual(store.widgetActionReplayDiagnostics.quarantinedQueueCount, 1, "the quarantine is counted")
    expect(suite.queue == nil, "the wedged queue left the shared suite")
    expectEqual(workspace.claimFiles().filter { $0.hasPrefix("quarantine-\(bindingB)-") }.count, 1,
                "one owner-scoped quarantine file")
    // Not wedged: the next Siri action replays on the next activation.
    try suite.defaults.set(WidgetSnapshot(updatedAt: iso(Date()), nextJob: nil, timer: nil, outstandingTotal: 0, ownerTag: tagB)
        .encodedJSON(), forKey: WidgetAppGroup.snapshotKey)
    guard case .logged = suite.engine().logExpense(amount: 7, category: .fuel, description: nil) else {
        return expect(false, "B logs an expense after the quarantine")
    }
    store.testReplayWidgetActions()
    expectEqual(try workspace.load()?.payload.expenses?.count, 1, "the later action applies (the queue is no longer wedged)")
    // Sign-out removes the quarantine with the claims (it is B's data).
    try await store.signOut(revokeRemote: false)
    expect(workspace.claimFiles().isEmpty, "sign-out removes the quarantine files")
}

// MARK: - 7. Stale snapshots and records that no longer exist (§3.3)

private func snapshot(age: TimeInterval?, updatedAt raw: String? = nil, timer: WidgetSnapshot.TimerState? = nil,
                      nextJobID: String = "j1") -> WidgetSnapshot {
    WidgetSnapshot(
        updatedAt: raw ?? iso(fixedNow.addingTimeInterval(-(age ?? 0))),
        nextJob: .init(id: nextJobID, customerName: "C", title: "T", scheduledDate: "2026-08-03",
                       scheduledStartTime: "20:00", address: ""),
        timer: timer, outstandingTotal: 50, ownerTag: tagB
    )
}

private func testStaleWindow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = phoenix
    let boundary: [(String, WidgetSnapshot, Bool)] = [
        ("86,399 s", snapshot(age: 86_399), false),
        ("exactly 86,400 s", snapshot(age: 86_400), false),
        ("86,401 s", snapshot(age: 86_401), true),
        ("negative age", snapshot(age: -1), true),
        ("garbage updatedAt", snapshot(age: nil, updatedAt: "yesterday-ish"), true),
        ("empty updatedAt", snapshot(age: nil, updatedAt: ""), true),
        ("plain ISO, fresh", snapshot(age: nil, updatedAt: "2026-08-03T18:00:00Z"), false),
    ]
    for (label, value, stale) in boundary {
        expectEqual(value.isStale(now: fixedNow), stale, "\(label): stale == \(stale)")
        let suite = TempSuite()
        defer { suite.cleanUp() }
        suite.defaults.set(try! value.encodedJSON(), forKey: WidgetAppGroup.snapshotKey)
        let engine = suite.engine(at: fixedNow)
        if stale {
            expectEqual(engine.nextJob(), .stale, "\(label): Next Job refuses (no data spoken)")
            expectEqual(engine.outstanding(), .stale, "\(label): Outstanding refuses")
            expectEqual(engine.clockIn(), .stale, "\(label): Clock In refuses (no job id from a stale snapshot)")
            expectEqual(engine.stashOnMyWay(), .stale, "\(label): On My Way refuses (no stale deep link)")
            expectEqual(engine.startTimer(jobID: "j1"), .stale, "\(label): the widget Start button refuses")
            expect(suite.queue == nil && suite.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) == nil,
                   "\(label): a stale refusal writes nothing")
            expectEqual(NextJobWidgetPolicy.resolveState(snapshot: value, now: fixedNow, calendar: calendar), .stale,
                        "\(label): the Next Job widget shows its stale state (no job link)")
            expectEqual(JobTimerWidgetPolicy.resolveState(snapshot: value, pendingActionsJSON: nil, now: fixedNow, calendar: calendar),
                        .syncNeeded, "\(label): the idle Job Timer shows 'Open app to sync' (no job link)")
            expect(JobTimerWidgetPolicy.deepLinkURL(for: .syncNeeded) == nil, "\(label): no deep link from the stale timer card")
        } else {
            if case .nextJob = engine.nextJob() {} else { expect(false, "\(label): a fresh snapshot answers Next Job") }
        }
    }
}

@MainActor
private func testStaleAndMissingRecordsFailClosed() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    try workspace.write(jobs: [
        job("live"),
        job("archived", ["archivedAt": "2026-08-02T00:00:00Z"]),
        job("done", ["status": "complete"]),
        job("running", ["status": "in_progress", "timeSessions": [["start": "2026-08-03T15:00:00Z", "end": NSNull()]]]),
    ])
    try workspace.bind(bindingB)
    let store = makeStore(workspace, suite: suite, installMirror: false)
    store.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    let before = try workspace.load()

    // Actions built from a stale snapshot that names records which no longer
    // qualify: the replayer re-resolves the exact id and ignores them.
    suite.defaults.set(queueJSON([
        action("s-missing", "timer_start", tag: tagB, ["jobId": "deleted-job"]),
        action("s-archived", "timer_start", tag: tagB, ["jobId": "archived"]),
        action("s-done", "timer_start", tag: tagB, ["jobId": "done"]),
        action("x-missing", "timer_stop", tag: tagB, ["jobId": "deleted-job"]),
    ]), forKey: WidgetAppGroup.actionsKey)
    store.testReplayWidgetActions()
    let after = try workspace.load() ?? before
    let unchanged = try encoded(after) == encoded(before)
    expect(unchanged, "no stale/missing-record action touches ANY record (none is redirected elsewhere)")
    expect(suite.queue == nil && workspace.claimFiles().isEmpty, "the ignored actions are acknowledged, not retried forever")
    expect(after?.payload.jobs?.first { $0.id == "running" }?.timeSessions?.last?.end == nil,
           "a stop naming a missing job never stops a different running job")

    // Stale widget deep links re-resolve the exact id in the current owner's
    // data: a missing id is discarded, an existing one routes to exactly it.
    let staleRunning = WidgetSnapshot.TimerState(jobId: "deleted-job", jobTitle: "Old", customerName: "Old", startedAt: "2026-08-01T15:00:00Z")
    let staleLink = JobTimerWidgetPolicy.deepLinkURL(for: .running(staleRunning, since: fixedNow))
    expect(staleLink != nil, "sanity: a stale running timer still deep-links its job id (§3.3 keeps Stop visible)")
    store.handle(url: staleLink!)
    store.handle(url: URL(string: "tradeready://onmyway/deleted-job")!)
    expect(store.deepLinkedJobID == nil && store.pendingOnMyWayJobID == nil,
           "a link to a job that no longer exists is discarded (no route, no review)")
    expectEqual(store.selectedTab, .today, "…and does not even switch tabs")
    store.handle(url: NextJobWidgetPolicy.deepLinkURL(jobID: "live")!)
    expectEqual(store.deepLinkedJobID, "live", "an existing id routes to exactly that record")
}

// MARK: - 8. A widget deep link opened while signed out (brief item 4)

@MainActor
private func testDeepLinkWhileSignedOut() async throws {
    // (a) After an explicit sign-out the local data is gone: a warm widget
    // link is discarded, and nothing re-appears when another owner signs in.
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    try workspace.write(jobs: [job("j1", ["customerName": "Alice (A)"])])
    try workspace.bind(bindingA)
    let store = makeStore(workspace, suite: suite)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    guard case .opening = suite.engine().stashOnMyWay() else { return expect(false, "sanity: A stashes an On My Way link") }
    try await store.signOut(revokeRemote: false)
    await settle()
    expect(suite.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) == nil,
           "A's tagged cold-launch stash is scrubbed at sign-out (B can never consume it)")
    store.handle(url: URL(string: "tradeready://job/j1")!)
    store.handle(url: URL(string: "tradeready://onmyway/j1")!)
    expect(store.deepLinkedJobID == nil && store.pendingOnMyWayJobID == nil, "signed out: the widget link sets no route")
    expectEqual(store.parkedDeepLink?.route, .onMyWay(id: "j1"), "Task 11.06: it parks (newest wins)")
    expect(store.parkedDeepLink?.arrivalBinding == nil, "…with no arrival owner: nobody was signed in")
    try workspace.write(jobs: [job("j1", ["customerName": "Bob (B)"])])
    try workspace.bind(bindingB)
    store.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    await settle()
    // §6.2 step 4: a nil-arrival warm URL may apply for the next owner, but
    // the step-6 lookup is ONLY in the current in-memory data, which sign-out
    // emptied; A's j1 is never what it resolves to. (A nil-arrival URL that
    // resolves to the new owner's own record is covered in DeepLinkRoutingTests.)
    expect(store.parkedDeepLink == nil, "B signs in: the parked link is resolved, not kept")
    expect(store.deepLinkedJobID == nil && store.pendingOnMyWayJobID == nil,
           "after B signs in, no route from the signed-out link appears (no record in the current data)")
    // Fix round 1 (M1, deliberate): the link arrived with no owner, so B is
    // not told "Job not found" for a tap B did not make; it is dropped silently.
    expect(store.deepLinkUnavailableNotice == nil, "…and B sees no not-found state for A's tap")

    // (b) Task 11.06: a cold-launch stash is read and removed under the lock
    // whatever the gate, parks with A's tag while signed out, and is
    // discarded (never applied) when a different owner B signs in, even
    // though B has a same-id j1.
    let suite2 = TempSuite(), workspace2 = Workspace()
    defer { suite2.cleanUp(); workspace2.cleanUp() }
    try workspace2.write(jobs: [job("j1", ["customerName": "Bob (B)"])])
    try workspace2.bind(bindingB)
    let coldStore = makeStore(workspace2, suite: suite2)
    coldStore.testSetAuthenticationGateState(.signedOut)
    let stash = try WidgetJSONValue.encodeJSON(WidgetPendingOpenURLStash(url: "tradeready://job/j1", at: iso(Date().addingTimeInterval(-1)), ownerTag: tagA))
    suite2.defaults.set(stash, forKey: WidgetAppGroup.pendingOpenURLKey)
    coldStore.consumePendingOpenURLStash()
    expect(suite2.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) == nil, "the stash is read and removed at once")
    expectEqual(coldStore.parkedDeepLink?.ownerTag, tagA, "signed out: it parks with A's tag")
    expect(coldStore.deepLinkedJobID == nil, "…and routes nothing")
    coldStore.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    await settle()
    expect(coldStore.parkedDeepLink == nil && coldStore.deepLinkedJobID == nil && coldStore.pendingOnMyWayJobID == nil,
           "B signs in: A's tagged stash is discarded, never routed into B's same-id j1")
    suite2.defaults.set(stash, forKey: WidgetAppGroup.pendingOpenURLKey)
    try suite2.scrubber.scrub()
    expect(suite2.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) == nil, "the account scrub discards the stash")

    // (c) Expired session (no scrub): A's data is retained behind the gate.
    // Task 11.06: a link opened while signed out PARKS (it never sets a route
    // field); the newest link wins; the REAL explicit sign-out discards it.
    let suite3 = TempSuite(), workspace3 = Workspace()
    defer { suite3.cleanUp(); workspace3.cleanUp() }
    try workspace3.write(jobs: [job("j1", ["customerName": "Alice (A)"])])
    try workspace3.bind(bindingA)
    let expired = makeStore(workspace3, suite: suite3)
    expired.testSetAuthenticationGateState(.signedOut)
    expired.handle(url: URL(string: "tradeready://job/j1")!)
    expectEqual(expired.parkedDeepLink?.route, .job(id: "j1"), "signed out (expired, data retained): the link parks the exact id")
    expect(expired.deepLinkedJobID == nil && expired.selectedTab == .today, "…and sets no route field or tab while parked")
    expect(expired.parkedDeepLink?.arrivalBinding == nil, "…with no arrival owner (none was signed in)")
    expired.handle(url: URL(string: "tradeready://onmyway/j1")!)
    expectEqual(expired.parkedDeepLink?.route, .onMyWay(id: "j1"), "at most one parked route: the newest wins")
    expect(expired.pendingOnMyWayJobID == nil, "no On My Way review while parked")
    // The REAL explicit sign-out is the account boundary.
    try await expired.signOut(revokeRemote: false)
    expect(expired.parkedDeepLink == nil, "a real signOut discards the parked route from A's session")
    expect(expired.deepLinkedJobID == nil && expired.pendingOnMyWayJobID == nil, "…and holds no route field")
    try workspace3.write(jobs: [job("j1", ["customerName": "Bob (B)"])])
    try workspace3.bind(bindingB)
    expired.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    await settle()
    expect(expired.deepLinkedJobID == nil && expired.pendingOnMyWayJobID == nil,
           "after B signs in on the same store, A's link does not route into B's same-id j1")

    // (d) Task 11.06 (11.05 handoff d): the REAL "use another account" is
    // an account boundary for every held route. A is signed in and has a
    // live job route and an On My Way review; the gate then moves to
    // initial-sync-unavailable (which offers "Use another account") and one
    // more link parks.
    let suite4 = TempSuite(), workspace4 = Workspace()
    defer { suite4.cleanUp(); workspace4.cleanUp() }
    try workspace4.write(jobs: [job("j1", ["customerName": "Alice (A)"]), job("j2")])
    try workspace4.bind(bindingA)
    let switching = makeStore(workspace4, suite: suite4)
    switching.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    switching.handle(url: URL(string: "tradeready://job/j1")!)
    switching.handle(url: URL(string: "tradeready://onmyway/j1")!)
    expectEqual(switching.deepLinkedJobID, "j1", "sanity: A's route is held before the switch")
    expectEqual(switching.pendingOnMyWayJobID, "j1", "sanity: A's On My Way review is held before the switch")
    switching.testSetAuthenticationGateState(.initialSyncUnavailable(message: "offline"))
    switching.handle(url: URL(string: "tradeready://job/j2")!)
    expectEqual(switching.parkedDeepLink?.route, .job(id: "j2"), "sanity: a link parks behind the unavailable gate")
    switching.scheduleBookingTestSeedIdentityActivator()
    await switching.useAnotherAccount {}
    expectEqual(switching.authenticationGateState, .signedOut, "sanity: useAnotherAccount reached its success path")
    expect(switching.deepLinkedJobID == nil, "useAnotherAccount drops A's job route")
    expect(switching.pendingOnMyWayJobID == nil, "useAnotherAccount drops A's On My Way review")
    expect(switching.parkedDeepLink == nil, "useAnotherAccount drops the parked route")

    // (e) The same owner comes back: the parked route is A's own exact record.
    let suite5 = TempSuite(), workspace5 = Workspace()
    defer { suite5.cleanUp(); workspace5.cleanUp() }
    try workspace5.write(jobs: [job("j1", ["customerName": "Alice (A)"])])
    try workspace5.bind(bindingA)
    let again = makeStore(workspace5, suite: suite5)
    again.testSetAuthenticationGateState(.signedOut)
    again.handle(url: URL(string: "tradeready://job/j1")!)
    again.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    expect(again.parkedDeepLink == nil, "A signs in: the parked route is applied, not kept")
    expectEqual(again.deepLinkedJobID, "j1", "A signs back in: the parked route is still the exact id")
    expectEqual(again.jobs.first { $0.id == "j1" }?.customerName, "Alice (A)", "…and it resolves to A's own record")
}

// MARK: - 8b. Use another account is an App Group boundary (fix round 1, I1)

@MainActor
private func testUseAnotherAccountScrubsWidgetState() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    let reloader = RecordingReloader()
    let subscription = SubscriptionStub()
    try workspace.write(jobs: [job("j1", ["customerName": "Alice (A)"])])
    try workspace.bind(bindingA)
    let store = makeStore(workspace, suite: suite, reloader: reloader, subscription: subscription)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    suite.defaults.set(queueJSON([action("b-foreign", "expense_log", tag: tagB, expenseFields)]), forKey: WidgetAppGroup.actionsKey)
    store.testReplayWidgetActions()
    expectEqual(store.widgetActionReplayDiagnostics.ownerDroppedActionCount, 1, "sanity: A's session counted a dropped action")
    let engine = suite.engine()
    guard case .nextJob(let spoken, _, _) = engine.nextJob(), spoken.customerName == "Alice (A)" else {
        return expect(false, "sanity: Siri speaks A's next job before the switch")
    }
    guard case .started = engine.startTrip(odometerStart: 10) else { return expect(false, "sanity: A starts a trip") }
    guard case .opening = engine.stashOnMyWay() else { return expect(false, "sanity: A stashes a link") }
    _ = engine.logExpense(amount: 4, category: .fuel, description: nil)
    _ = try suite.transport(claims: workspace.claims).claim(verifiedAccountBinding: bindingA)
    expect(!workspace.claimFiles().isEmpty, "sanity: A has an in-flight claim")
    expect(suite.defaults.string(forKey: WidgetAppGroup.activeTripKey) != nil
           && suite.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) != nil,
           "sanity: A's trip and stash are in the suite")

    reloader.probe = { suite.isEmpty }
    let reloadsBefore = reloader.count
    var atLogOut: (Bool, Int, NativeWidgetMirrorOutcome?)?
    subscription.onLogOut = { [weak store] in
        atLogOut = (suite.isEmpty, reloader.count, store?.refreshWidgetMirror(force: true))
    }
    store.scheduleBookingTestSeedIdentityActivator()
    await store.useAnotherAccount {}
    expectEqual(store.authenticationGateState, .signedOut, "sanity: useAnotherAccount reached its success path")

    expect(atLogOut?.0 == true, "the suite is wiped before the logOut await")
    expect((atLogOut?.1 ?? 0) > reloadsBefore, "timelines are reloaded right after the wipe, before the logOut await")
    expectEqual(atLogOut?.2, .skippedNoOwner, "no mirror write lands inside the account-switch boundary")
    expect(reloader.count > reloadsBefore && reloader.suiteWasEmptyAtEveryReload,
           "every reload came after the wipe (no widget re-renders A)")
    expect(WidgetSnapshot.load(from: suite.defaults) == nil, "no snapshot for A remains")
    expect(suite.defaults.string(forKey: WidgetAppGroup.activeTripKey) == nil, "no trip for A remains")
    expect(suite.defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) == nil, "no stash for A remains")
    expect(suite.isEmpty, "the whole account key set is empty")
    expect(workspace.claimFiles().isEmpty, "A's claims are removed")
    expectEqual(suite.engine().nextJob(), .failed(.signInRequired), "Next Job speaks nothing of A")
    expectEqual(suite.engine().outstanding(), .failed(.signInRequired), "Outstanding speaks nothing of A")
    expectEqual(suite.engine().stopTrip(odometerEnd: 20), .failed(.signInRequired), "A's trip cannot be finished by anyone")
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "no owner after the switch → nothing re-written")
    expectEqual(store.widgetActionReplayDiagnostics.accountSwitchScrubFailureCount, 0, "the wipe succeeded")
    expect(store.widgetActionReplayDiagnostics.ownerDroppedActionCount == 0
           && store.widgetActionReplayDiagnostics.quarantinedQueueCount == 0, "per-owner diagnostics are reset")
    let local = try workspace.load()
    expectEqual(local?.payload.jobs?.first?.customerName, "Alice (A)",
                "the local workspace is retained (only the widget/Siri surface is an account boundary here)")
}

// MARK: - 8c. Use another account: a failed App Group wipe fails closed (final review 1a)

/// A scrubber whose lock sits under a regular file, so taking it fails until
/// `unblock()` removes that file (the same lock path then works).
private struct BlockableScrubber {
    let root = tempDirectory("blocked-lock")
    var blocker: URL { root.appendingPathComponent("blocker") }
    func scrubber(_ suite: TempSuite) -> NativeAppGroupAccountScrubber {
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        return NativeAppGroupAccountScrubber(
            suiteName: suite.name, defaults: suite.defaults,
            lockFile: blocker.appendingPathComponent(WidgetAppGroup.lockFileName)
        )
    }
    func block() {
        // A successful scrub created the lock's directory at this path.
        try? FileManager.default.removeItem(at: blocker)
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
    }
    func unblock() { try? FileManager.default.removeItem(at: blocker) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func testUseAnotherAccountScrubFailureFailsClosed() async throws {
    let suite = TempSuite(), workspace = Workspace(), blockable = BlockableScrubber()
    defer { suite.cleanUp(); workspace.cleanUp(); blockable.cleanUp() }
    let marker = workspace.fileURL.appendingPathExtension("widget-scrub-pending")
    try workspace.write(jobs: [job("j1", ["customerName": "Alice (A)"])])
    try workspace.bind(bindingA)
    let reloader = RecordingReloader()
    let scrubber = blockable.scrubber(suite)
    let store = makeStore(workspace, suite: suite, reloader: reloader, scrubber: scrubber)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    expect(WidgetSnapshot.load(from: suite.defaults) != nil, "sanity: A's snapshot is mirrored")

    store.scheduleBookingTestSeedIdentityActivator()
    await store.useAnotherAccount {}
    expectEqual(store.authenticationGateState, .signedOut, "sanity: the switch reached its success path")
    expectEqual(store.widgetActionReplayDiagnostics.accountSwitchScrubFailureCount, 1, "the failed wipe is counted")
    expect(FileManager.default.fileExists(atPath: marker.path), "1a: the failed wipe leaves a durable pending marker")

    // B signs in on the same (retained) workspace. The wipe is still pending,
    // so nothing may be mirrored over A's stale App Group state.
    try workspace.bind(bindingB)
    store.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    await settle()
    expectEqual(store.derivedStatePublishBinding, bindingB, "sanity: O = B")
    expect(store.widgetMirrorOwnerBinding == nil, "1a: while the wipe is pending the mirror has no owner")
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "1a: …and writes nothing")

    // A relaunch keeps it pending while the container is still unavailable.
    let relaunched = makeStore(workspace, suite: suite, reloader: RecordingReloader(), scrubber: scrubber)
    relaunched.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    expect(relaunched.widgetMirrorOwnerBinding == nil, "1a: the pending wipe survives a relaunch")

    // The retry succeeds once the container is available again.
    blockable.unblock()
    let reloadsBefore = reloader.count
    store.retryAccountScrub()
    expect(!FileManager.default.fileExists(atPath: marker.path), "1a: a successful retry clears the marker")
    expect(reloader.count > reloadsBefore, "1a: timelines are reloaded after the successful retry")
    expect(suite.isEmpty, "1a: A's App Group state is gone")
    expectEqual(store.widgetMirrorOwnerBinding, bindingB, "1a: the mirror reopens for B")

    // Launch retry: pending at launch with the container available → wiped.
    blockable.block()
    try workspace.bind(bindingA)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await store.useAnotherAccount {}
    expect(FileManager.default.fileExists(atPath: marker.path), "1a: sanity: pending again")
    blockable.unblock()
    let launchReloader = RecordingReloader()
    let launched = makeStore(workspace, suite: suite, reloader: launchReloader, scrubber: scrubber)
    expect(!FileManager.default.fileExists(atPath: marker.path), "1a: the launch retry clears the marker")
    expect(launchReloader.count > 0, "1a: the launch retry reloads timelines")
    _ = launched

    // Sign-in retry: pending when an interactive sign-in finishes → wiped first.
    blockable.block()
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await store.useAnotherAccount {}
    expect(FileManager.default.fileExists(atPath: marker.path), "1a: sanity: pending once more")
    blockable.unblock()
    try workspace.bind(bindingB)
    store.testFinishInteractiveSignIn(subject: "user-b", binding: bindingB, email: "b@example.test", method: .password)
    expect(!FileManager.default.fileExists(atPath: marker.path), "1a: the sign-in retry clears the marker")
}

// MARK: - 8c2. The widget wipe survives a double failure (Phase 12, L286.5b)

/// An in-memory Keychain (the system Keychain is never written by this
/// fixture).
private final class MemoryKeychain: NativeSecureKeyValueBacking {
    var values: [String: Data] = [:]
    func upsert(_ value: Data, key: String) throws { values[key] = value }
    func read(key: String) throws -> Data? { values[key] }
    func remove(key: String) throws { values.removeValue(forKey: key) }
    var boundaryRecords: [String] { values.keys.filter { $0.hasPrefix("account-boundary-") }.sorted() }
}

/// Makes `directory` refuse new entries, so a boundary-step file marker
/// cannot be written there (a full or read-only volume). False when the
/// environment ignores the permission (for example, running as root).
private func makeReadOnly(_ directory: URL) -> Bool {
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    let probe = directory.appendingPathComponent("probe-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return true }
    try? FileManager.default.removeItem(at: probe)
    return false
}

private func makeWritable(_ directory: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
}

/// L286.5b (S1): for every (marker write fails) × (wipe fails) combination
/// followed by a relaunch — a fresh store on the same workspace, App Group
/// suite and Keychain — the previous owner's App Group state is unreadable
/// through the mirror and replay gates (the wipe still reads as pending, or
/// the state is gone), and a later successful retry clears the pending state
/// and reopens both gates for the next owner.
@MainActor
private func testWidgetScrubSurvivesDoubleFailureAndRelaunch() async throws {
    for markerFails in [false, true] {
        for wipeFails in [false, true] {
            let label = "L286.5b widget-scrub (marker \(markerFails ? "fails" : "ok"), wipe \(wipeFails ? "fails" : "ok"))"
            let suite = TempSuite(), workspace = Workspace(), blockable = BlockableScrubber()
            defer { makeWritable(workspace.directory); suite.cleanUp(); workspace.cleanUp(); blockable.cleanUp() }
            let marker = workspace.fileURL.appendingPathExtension("widget-scrub-pending")
            let keychain = MemoryKeychain()
            let secure = NativeKeychainSecureSettingsStore(backend: keychain)
            try workspace.write(jobs: [job("j1", ["customerName": "Alice (A)"])])
            try workspace.bind(bindingA)
            let scrubber = blockable.scrubber(suite)
            let store = makeStore(workspace, suite: suite, scrubber: scrubber, secureSettingsStore: secure)
            store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
            await settle()
            expect(!suite.isEmpty, "\(label): sanity: A's snapshot is mirrored")

            // `scrubber(_:)` starts blocked; the wipe succeeds only unblocked.
            if wipeFails { blockable.block() } else { blockable.unblock() }
            if markerFails {
                // No replay claim is held, so only the marker write needs the
                // directory (a full volume still allows removals).
                try? FileManager.default.removeItem(at: workspace.claims)
                expect(makeReadOnly(workspace.directory), "\(label): sanity: the marker write can be made to fail")
            }
            store.scheduleBookingTestSeedIdentityActivator()
            await store.useAnotherAccount {}
            expectEqual(store.authenticationGateState, .signedOut, "\(label): sanity: the switch reached its success path")
            expectEqual(store.isAccountBoundaryCleanupPending, wipeFails, "\(label): the cleanup retry is offered exactly while the wipe is pending")
            if markerFails {
                expect(!FileManager.default.fileExists(atPath: marker.path), "\(label): sanity: no file marker was written")
                expect(store.boundaryStepMarkerWriteFailureCount >= 1, "\(label): the marker write failure is counted")
            }

            // Relaunch after the volume recovered; B completes onboarding on
            // the retained workspace and signs in.
            makeWritable(workspace.directory)
            try workspace.bind(bindingB)
            let relaunched = makeStore(workspace, suite: suite, scrubber: scrubber, secureSettingsStore: secure)
            relaunched.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
            await settle()
            expectEqual(relaunched.derivedStatePublishBinding, bindingB, "\(label): sanity: O = B")
            if wipeFails {
                expect(!suite.isEmpty, "\(label): sanity: A's App Group state is still there")
                expect(relaunched.widgetMirrorOwnerBinding == nil, "\(label): after the relaunch the mirror has no owner")
                expect(relaunched.widgetActionReplayBinding == nil, "\(label): …and replay is closed")
                expectEqual(relaunched.refreshWidgetMirror(force: true), .skippedNoOwner, "\(label): …and nothing is written over A's state")
                expect(relaunched.isAccountBoundaryCleanupPending, "\(label): the relaunch offers the cleanup retry")
            } else {
                expect(!relaunched.isAccountBoundaryCleanupPending, "\(label): nothing is pending after the relaunch")
                expectEqual(relaunched.widgetMirrorOwnerBinding, bindingB, "\(label): A's state was wiped, so the mirror is B's")
            }

            // A later successful retry clears the pending state and reopens
            // both gates.
            blockable.unblock()
            relaunched.retryAccountScrub()
            if wipeFails { expect(suite.isEmpty, "\(label): the retry wiped A's App Group state") }
            await settle()
            expect(!FileManager.default.fileExists(atPath: marker.path), "\(label): no file marker remains")
            expect(keychain.boundaryRecords.isEmpty, "\(label): no Keychain boundary record remains")
            expect(!relaunched.isAccountBoundaryCleanupPending, "\(label): the cleanup retry is no longer offered")
            expectEqual(relaunched.widgetMirrorOwnerBinding, bindingB, "\(label): the mirror reopens for B")
            expectEqual(relaunched.widgetActionReplayBinding, bindingB, "\(label): replay reopens for B")
        }
    }
}

// MARK: - 8d. An account switch is exclusive (final review 1c)

@MainActor
private final class HoldingSubscription: NativeSubscriptionServing {
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = true
    private(set) var isHolding = false
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    /// The first `logOut` suspends until `release()`; later ones return.
    func logOut() async {
        guard holdNext else { return }
        holdNext = false
        isHolding = true
        await withCheckedContinuation { held = $0 }
        isHolding = false
    }
    func release() { held?.resume(); held = nil }
}

@MainActor
private func testAccountSwitchIsExclusive() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    try workspace.write(jobs: [job("j1")])
    try workspace.bind(bindingA)
    let subscription = HoldingSubscription()
    let store = makeStore(workspace, suite: suite, subscription: subscription)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    store.scheduleBookingTestSeedIdentityActivator()
    await settle()
    var firstClears = 0, secondClears = 0
    let first = Task { await store.useAnotherAccount { firstClears += 1 } }
    for _ in 0..<500 where !subscription.isHolding { await Task.yield() }
    expect(subscription.isHolding, "1c: sanity: the first switch is suspended in logOut")

    await store.useAnotherAccount { secondClears += 1 }
    expectEqual(secondClears, 0, "1c: a second switch while the first is suspended is a no-op")
    expectEqual(store.authenticationGateState, .signedIn(email: nil), "1c: …it tears nothing down mid-switch")
    expect(store.widgetActionReplayBinding == nil, "1c: the first switch's boundary still holds")
    do {
        try await store.signIn(email: "b@example.test", password: "password-b")
        expect(false, "1c: signIn during a switch is refused")
    } catch NativeSupabaseAuthError.rejected(let message) {
        expectEqual(message, "Another sign-in request is still running.", "1c: signIn during a switch is refused")
    } catch {
        expect(false, "1c: signIn during a switch is refused before any provider call (got \(error))")
    }

    subscription.release()
    await first.value
    expectEqual(firstClears, 1, "1c: the first switch completes its own exit")
    expectEqual(store.authenticationGateState, .signedOut, "1c: the first switch completes")
}

// MARK: - 9. The write gate (brief item 1, §3.1)

@MainActor
private func testWriteGate() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    try workspace.write(jobs: [job("j1")])
    let store = makeStore(workspace, suite: suite)
    store.testSeedNativeSignedInOwner(subject: "user-b", binding: bindingB)
    await settle()
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "no completed workspace bound to B → no snapshot")
    try workspace.bind(bindingB, stage: .drafting)
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "an unfinished workspace is not exact → no snapshot")
    try workspace.bind(bindingA)
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "a workspace bound to another account → no snapshot")
    expect(WidgetSnapshot.load(from: suite.defaults) == nil, "nothing was written without an exact signed-in workspace")

    try workspace.bind(bindingB)
    let closed: [(String, NativeAuthenticationGateState)] = [
        ("loading", .loading), ("signedOut", .signedOut), ("accountMismatch", .accountMismatch),
        ("unavailable", .unavailable), ("initialSyncLoading", .initialSyncLoading),
        ("initialSyncUnavailable", .initialSyncUnavailable(message: "x")),
        ("passwordRecovery", .passwordRecovery(email: nil)), ("invalidPasswordRecovery", .invalidPasswordRecovery),
    ]
    for (label, gate) in closed {
        store.testSetAuthenticationGateState(gate)
        expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "\(label): no snapshot")
    }
    await settle()
    expect(WidgetSnapshot.load(from: suite.defaults) == nil, "no closed gate wrote a snapshot")
    store.testSetAuthenticationGateState(.paywall(offering: nil, message: nil))
    expectEqual(store.refreshWidgetMirror(force: true), .written, "post-sign-in gate with O: the writer may run (§2.5)")
    expect(store.widgetActionReplayBinding == nil, "…but replay may not (it needs .signedIn)")
    expectEqual(WidgetSnapshot.load(from: suite.defaults)?.ownerTag, tagB, "the snapshot is tagged hash(O)")

    // Launch recovery and retry: a pending scrub marker wipes the suite,
    // reloads timelines and removes claims before anything else happens.
    let claimsTransport = suite.transport(claims: workspace.claims)
    suite.defaults.set(queueJSON([action("b1", "timer_stop", tag: tagB)]), forKey: WidgetAppGroup.actionsKey)
    _ = try claimsTransport.claim(verifiedAccountBinding: bindingB)
    try Canonical.SnapshotRepository(primaryURL: workspace.fileURL).beginAccountScrub(scope: .live)
    let reloader = RecordingReloader()
    reloader.probe = { suite.isEmpty }
    let recovered = makeStore(workspace, suite: suite, reloader: reloader, installMirror: false)
    expect(suite.isEmpty && reloader.count == 1 && reloader.suiteWasEmptyAtEveryReload,
           "launch recovery: wiped, then reloaded once, with the suite already empty")
    expect(workspace.claimFiles().isEmpty, "launch recovery removes the scrubbed account's claims")
    _ = recovered

    try Canonical.SnapshotRepository(primaryURL: workspace.fileURL).beginAccountScrub(scope: .live)
    try suite.defaults.set(WidgetSnapshot(updatedAt: iso(Date()), nextJob: nil, timer: nil, outstandingTotal: 0, ownerTag: tagB)
        .encodedJSON(), forKey: WidgetAppGroup.snapshotKey)
    let retryReloader = RecordingReloader()
    retryReloader.probe = { suite.isEmpty }
    let retrying = AppStore(
        fileURL: workspace.fileURL, seedIfMissing: false,
        widgetActionReplayTransport: suite.transport(claims: workspace.claims),
        appGroupAccountScrubber: NativeAppGroupAccountScrubber(suiteName: suite.name, defaults: suite.defaults, lockFile: nil),
        subscriptionService: SubscriptionStub(), widgetTimelineReloader: retryReloader,
        secureSettingsStore: hostTestSecureSettingsStore()
    )
    expect(retrying.isAccountScrubBlocked, "sanity: an unavailable container blocks the launch scrub")
    expect(retrying.widgetMirrorOwnerBinding == nil && retrying.widgetActionReplayBinding == nil,
           "a blocked scrub closes the mirror and replay gates")
    expectEqual(retryReloader.count, 0, "no reload while the wipe has not happened")
}

// MARK: - 9b. Sign-out behind a busy lock (Phase 12, 12.00b.2-B)

/// The account scrub runs on the main actor, so it takes the bounded
/// main-thread acquire. Busy maps to the scrub's existing lock failure: the
/// sign-out fails closed within the budget (widget step pending, mirror
/// gated, nothing wiped or half-wiped) and the retry finishes it once the
/// lock is free. The scrub's lock order and code are unchanged.
@MainActor
private func testSignOutBehindBusyLockFailsClosed() async throws {
    let suite = TempSuite(), workspace = Workspace()
    defer { suite.cleanUp(); workspace.cleanUp() }
    let marker = workspace.fileURL.appendingPathExtension("widget-scrub-pending")
    try workspace.write(jobs: [job("j1")])
    try workspace.bind(bindingA)
    let reloader = RecordingReloader()
    let store = makeStore(workspace, suite: suite, reloader: reloader)
    store.testSeedNativeSignedInOwner(subject: "user-a", binding: bindingA)
    await settle()
    expectEqual(WidgetSnapshot.load(from: suite.defaults)?.ownerTag, tagA, "sanity: A's snapshot is mirrored")

    let holder = LockHolder(at: suite.lockFile, releaseAfter: 2)
    let start = ProcessInfo.processInfo.systemUptime
    var thrown: Error?
    do { try await store.signOut(revokeRemote: false) } catch { thrown = error }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    if case NativeAccountSignOutError.localScrubFailed? = thrown as? NativeAccountSignOutError {} else {
        expect(false, "a sign-out behind a busy lock fails with localScrubFailed (got \(String(describing: thrown)))")
    }
    expect(elapsed < 0.5, "the main actor was not held past the lock budget (took \(elapsed) s)")
    expect(FileManager.default.fileExists(atPath: marker.path), "the widget wipe stays pending (durable marker)")
    expectEqual(WidgetSnapshot.load(from: suite.defaults)?.ownerTag, tagA, "nothing in the suite was touched while busy")
    expectEqual(reloader.count, 0, "no post-wipe reload ran")
    expect(store.widgetMirrorOwnerBinding == nil, "the mirror is gated while the wipe is pending")
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "…and writes nothing")

    holder.release()
    store.retryAccountScrub()
    expect(!FileManager.default.fileExists(atPath: marker.path), "the retry clears the marker once the lock is free")
    expect(suite.isEmpty, "the retry wipes A's App Group state")
    expect(reloader.count > 0, "the retry reloads timelines after the wipe")
    expectEqual(store.authenticationGateState, .signedOut, "the retry completes the sign-out")

    // Structure: no blocking acquire remains in the one shared lock.
    let lock = source("Widgets/Shared/WidgetAppGroup.swift")
    expect(!lock.isEmpty, "sanity: the lock source is readable")
    expect(lock.contains("LOCK_EX | LOCK_NB"), "the shared lock acquires with LOCK_NB")
    expect(!lock.contains("LOCK_EX)"), "the shared lock has no blocking LOCK_EX acquire")

    // Review fix M3: the stash consumer (take, takeMatching) and the scrubber
    // each emit one payload-free busy line (a fixed literal, no interpolation).
    // The host suites have no stdout seam, so this is a source check.
    let inbox = source("NativeAppGroupInbox.swift")
    expect(!inbox.isEmpty, "sanity: the inbox source is readable")
    expectEqual(inbox.components(separatedBy: "catch WidgetAppGroupLockError.busy {").count - 1, 3,
                "take, takeMatching and scrub each catch busy")
    expectEqual(inbox.components(separatedBy: #"print("TradeReadyWidgetLock stage=busy site=stash")"#).count - 1, 2,
                "take and takeMatching log one fixed stash line")
    expectEqual(inbox.components(separatedBy: #"print("TradeReadyWidgetLock stage=busy site=scrub")"#).count - 1, 1,
                "the scrubber logs one fixed scrub line")
}

// MARK: - 10. One lock (deferred 11.01 minor) and scrub-path structure

private func source(_ relative: String) -> String {
    let root = ProcessInfo.processInfo.environment["TRADEREADY_ROOT"] ?? FileManager.default.currentDirectoryPath
    return (try? String(contentsOfFile: root + "/native/TradeReadyNative/" + relative, encoding: .utf8)) ?? ""
}

private func testOneLock() {
    let replay = source("NativeWidgetActionReplay.swift")
    expect(!replay.isEmpty, "sanity: the replay source is readable")
    expect(!replay.contains("flock("), "the claim transport has no flock of its own")
    expect(!replay.contains("static let lockFileName"), "the claim transport has no lock file name of its own")
    expect(replay.contains("WidgetAppGroupLock.withExclusiveLock"), "the claim transport takes the one shared lock")
    let appStore = source("AppStore.swift")
    expectEqual(appStore.components(separatedBy: "appGroupAccountScrubber.scrub()").count - 1, 1,
                "the App Group wipe is called from exactly one place (scrubWidgetAccountState)")
    expectEqual(appStore.components(separatedBy: "try scrubWidgetAccountState()").count - 1, 5,
                "every scrub path (launch recovery, retry, sign-out/deletion, use another account, pending-step retry) goes through it")
    expectEqual(appStore.components(separatedBy: "reloadAllTimelines()").count - 1, 1,
                "timelines are reloaded from exactly one place (right after the wipe)")
    expect(!appStore.contains("guard isMigratedLocalOwnerVerified,\n              let accountBinding = migratedAccountBinding"),
           "the replay gate no longer requires the migrated owner")

    // Behavior: the transport and the extension writer exclude each other on
    // the SAME lock file.
    let root = tempDirectory("one-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let lockFile = root.appendingPathComponent(WidgetAppGroup.lockFileName)
    let queue = MemoryQueue(queueJSON([action("b1", "timer_stop", tag: tagB)]))
    let transport = NativeWidgetActionClaimTransport(queue: queue, claimDirectory: root.appendingPathComponent("claims"), lockFile: lockFile)
    let held = holdLock(at: lockFile)
    let (_, claimDone) = runInBackground { try? transport.claim(verifiedAccountBinding: bindingB) }
    expect(claimDone.wait(timeout: .now() + 0.25) == .timedOut, "a replay claim waits while another holder has WidgetAppGroup's lock")
    releaseLock(held)
    expect(claimDone.wait(timeout: .now() + 5) == .success, "…and proceeds once it is released")

    let suite = TempSuite()
    defer { suite.cleanUp() }
    suite.defaults.set(try! snapshot(age: 60).encodedJSON(), forKey: WidgetAppGroup.snapshotKey)
    let blocking = MemoryQueue(queueJSON([action("b2", "timer_stop", tag: tagB)]))
    blocking.blockReads = true
    let claimer = NativeWidgetActionClaimTransport(queue: blocking, claimDirectory: root.appendingPathComponent("claims2"), lockFile: suite.lockFile)
    let (_, claimingDone) = runInBackground { try? claimer.claim(verifiedAccountBinding: bindingB) }
    blocking.entered.wait() // the claim holds the lock
    let writer = suite.engine(at: fixedNow)
    let (_, appendDone) = runInBackground { writer.stopTimer(jobID: "") }
    expect(appendDone.wait(timeout: .now() + 0.25) == .timedOut, "an extension append waits while a replay claim holds the lock")
    blocking.release.signal()
    _ = claimingDone.wait(timeout: .now() + 5)
    expect(appendDone.wait(timeout: .now() + 5) == .success, "…and lands after the claim releases it")
}

// MARK: - Main

@main
struct WidgetOwnerGatingTests {
    @MainActor
    static func main() async throws {
        // A thrown error is a failure of that fixture, not a crash that
        // would skip every later fixture.
        func run(_ label: String, _ body: () throws -> Void) {
            do { try body() } catch { failures += 1; print("FAIL: \(label) threw \(error)") }
        }
        func runAsync(_ label: String, _ body: () async throws -> Void) async {
            do { try await body() } catch { failures += 1; print("FAIL: \(label) threw \(error)") }
        }
        testPureOwnerGate()
        run("planner owner gate", testPlannerOwnerGate)
        await runAsync("replay gate (native owner)", testReplayGateNativeOwner)
        await runAsync("cross sign-in", testCrossSignIn)
        await runAsync("real scrub race", testRealScrubRace)
        run("real scrub race (writer first)", testRealScrubRaceWriterFirst)
        run("quarantine", testQuarantine)
        await runAsync("quarantine in AppStore", testQuarantineInAppStore)
        testStaleWindow()
        await runAsync("stale/missing records", testStaleAndMissingRecordsFailClosed)
        await runAsync("deep link while signed out", testDeepLinkWhileSignedOut)
        await runAsync("use another account", testUseAnotherAccountScrubsWidgetState)
        await runAsync("use another account scrub failure", testUseAnotherAccountScrubFailureFailsClosed)
        await runAsync("widget scrub double failure and relaunch", testWidgetScrubSurvivesDoubleFailureAndRelaunch)
        await runAsync("account switch is exclusive", testAccountSwitchIsExclusive)
        await runAsync("write gate", testWriteGate)
        await runAsync("sign-out behind a busy lock", testSignOutBehindBusyLockFailsClosed)
        testOneLock()
        for gap in knownGaps { print("KNOWN GAP (not asserted; handed off): \(gap)") }
        if failures == 0 {
            print("Widget owner gating tests passed")
        } else {
            print("Widget owner gating tests: \(failures) failure(s)")
            exit(1)
        }
    }
}
