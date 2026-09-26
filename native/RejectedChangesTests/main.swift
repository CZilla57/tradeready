import Foundation

// Phase 12 (12.00b.1, known issue I2, contract §17.2) host tests: the
// rejected-change store (`N/NativeRejectedChangeStore.swift`) — bounded,
// owner-scoped, file-protected, never logged — and its AppStore wiring at
// every account boundary (sign-out, deletion, switch, recovery exits) and in
// the support report. The poison-item, Retry, Discard and cursor scenarios
// run over the real sync stack in `native/PoorNetworkTests/main.swift`.
// Run with TZ=America/Phoenix.

// MARK: - Harness

@MainActor var failures = 0
@MainActor var checks = 0

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func tempDirectory(_ tag: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-rejected-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func item(_ table: String, _ id: String, op: Canonical.MutationOp = .upsert, title: String = "Private title") -> Canonical.MutationItem {
    Canonical.MutationItem(
        table: table,
        op: op,
        recordId: id,
        payload: op == .delete ? nil : .object(["id": .string(id), "title": .string(title)]),
        ts: "2026-09-25T10:00:00.000Z"
    )
}

func rejection(_ table: String, _ id: String, status: Int = 422, title: String = "Private title") -> NativeMutationRejection {
    NativeMutationRejection(item: item(table, id, title: title), statusCode: status)
}

/// A file backing whose reads, writes or removes fail on demand (a locked
/// device, a full disk) and which records every write it accepts.
final class FlakyFiles: NativeRejectedChangeFileBacking {
    let real = NativeProtectedRejectedChangeFiles()
    var failRead = false
    var failWrite = false
    var failRemove = false
    private(set) var writes = 0
    func read(_ url: URL) throws -> Data? {
        if failRead { throw CocoaError(.fileReadNoPermission) }
        return try real.read(url)
    }
    func write(_ data: Data, to url: URL) throws {
        if failWrite { throw CocoaError(.fileWriteNoPermission) }
        writes += 1
        try real.write(data, to: url)
    }
    func remove(_ url: URL) throws {
        if failRemove { throw CocoaError(.fileWriteNoPermission) }
        try real.remove(url)
    }
}

let bindingA = String(repeating: "a", count: 64)
let bindingB = String(repeating: "b", count: 64)
let now = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - 1. The store

@MainActor
func testStoreBasics() throws {
    let dir = tempDirectory("basics")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("rejected-changes.json")
    let store = NativeRejectedChangeStore(fileURL: url)

    // File protection (review prep R15): after first unlock, like the live
    // mutation queue and the canonical snapshot that hold the same payloads,
    // so background sync can read it while the device is locked. Never the
    // `.complete` class, which adds no confidentiality over those files.
    expect(NativeProtectedRejectedChangeFiles.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication),
           "store: written with after-first-unlock file protection")
    expect(!NativeProtectedRejectedChangeFiles.writeOptions.contains(.completeFileProtection),
           "store: not written with complete protection (it would stop background sync while locked)")
    expect(NativeProtectedRejectedChangeFiles.writeOptions.contains(.atomic), "store: written atomically")

    expectEqual(try store.load(binding: bindingA), [], "store: no file reads empty")
    expect(!FileManager.default.fileExists(atPath: url.path), "store: reading creates no file")

    let dropped = try store.settle(
        rejected: [rejection("jobs", "J1", status: 422), rejection("invoices", "I1", status: 409)],
        clearedKeys: [], binding: bindingA, now: now
    )
    expectEqual(dropped, 0, "store: nothing dropped under the cap")
    let loaded = try store.load(binding: bindingA)
    expectEqual(loaded.map(\.key), ["jobs/J1", "invoices/I1"], "store: entries keep rejection order")
    expectEqual(loaded.first?.item, item("jobs", "J1"), "store: the original queued change is kept for Retry")
    expectEqual(loaded.map(\.statusCode), [422, 409], "store: each entry keeps its status")
    expectEqual(loaded.first?.rejectedAt, now, "store: each entry keeps when it was rejected")
    expectEqual(loaded.first?.id, "jobs/J1", "store: an entry's id is its record key")

    // Owner-scoped: the file names its owner by a one-way tag, never the binding.
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    expect(text.contains(NativeRejectedChangeStore.ownerTag(binding: bindingA)), "store: the file carries the owner tag")
    expect(!text.contains(bindingA), "store: the file never carries the raw account binding")
    expectEqual(NativeRejectedChangeStore.ownerTag(binding: bindingA).count, 64, "store: the owner tag is a SHA-256 hex digest")
    expect(NativeRejectedChangeStore.ownerTag(binding: bindingA) != NativeRejectedChangeStore.ownerTag(binding: bindingB),
           "store: owner tags differ by owner")
    expectEqual(try store.load(binding: bindingB), [], "store: another owner reads nothing")
    expectEqual(try store.load(binding: nil), [], "store: no owner reads nothing")
    expectEqual(try store.load(binding: ""), [], "store: an empty binding reads nothing")
    do {
        try store.settle(rejected: [rejection("jobs", "J9")], clearedKeys: [], binding: nil, now: now)
        expect(false, "store: settling without an owner must throw")
    } catch {
        expectEqual(error as? NativeRejectedChangeStoreError, .noOwner, "store: settling without an owner throws noOwner")
    }

    // A later rejection of the same record replaces the entry (newest last).
    let later = now.addingTimeInterval(60)
    try store.settle(rejected: [rejection("jobs", "J1", status: 400, title: "Newer")], clearedKeys: [], binding: bindingA, now: later)
    let replaced = try store.load(binding: bindingA)
    expectEqual(replaced.map(\.key), ["invoices/I1", "jobs/J1"], "store: a repeat rejection replaces and moves to newest")
    expectEqual(replaced.last?.statusCode, 400, "store: the repeat keeps the newest status")
    expectEqual(replaced.last?.rejectedAt, later, "store: the repeat keeps the newest time")
    expectEqual(replaced.last?.item, item("jobs", "J1", title: "Newer"), "store: the repeat keeps the newest change")

    // A change to the same record that the server accepted clears the entry.
    try store.settle(rejected: [], clearedKeys: ["jobs/J1"], binding: bindingA, now: later)
    expectEqual(try store.load(binding: bindingA).map(\.key), ["invoices/I1"], "store: an accepted change clears its entry")

    // Another owner's settle replaces the file: A's entries are never shown to B
    // and never merged into B's list.
    try store.settle(rejected: [rejection("customers", "C1")], clearedKeys: [], binding: bindingB, now: later)
    expectEqual(try store.load(binding: bindingB).map(\.key), ["customers/C1"], "store: B's settle starts from an empty list")
    expectEqual(try store.load(binding: bindingA), [], "store: A's entries are gone once B wrote")

    // Remove one; removing the last removes the file.
    try store.remove(key: "customers/C1", binding: bindingB)
    expectEqual(try store.load(binding: bindingB), [], "store: remove(key:) removes the entry")
    expect(!FileManager.default.fileExists(atPath: url.path), "store: an empty store leaves no file")
    do {
        try store.remove(key: "customers/C1", binding: nil)
        expect(false, "store: remove without an owner must throw")
    } catch {
        expectEqual(error as? NativeRejectedChangeStoreError, .noOwner, "store: remove without an owner throws noOwner")
    }

    // removeAll is idempotent.
    try store.settle(rejected: [rejection("jobs", "J2")], clearedKeys: [], binding: bindingA, now: now)
    try store.removeAll()
    expect(!FileManager.default.fileExists(atPath: url.path), "store: removeAll removes the file")
    try store.removeAll()
    expectEqual(try store.load(binding: bindingA), [], "store: removeAll twice is fine")
}

@MainActor
func testStoreBound() throws {
    let dir = tempDirectory("bound")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = NativeRejectedChangeStore(fileURL: dir.appendingPathComponent("rejected-changes.json"))
    let cap = NativeRejectedChangeStore.capacity
    expectEqual(cap, 100, "bound: the cap is 100 entries")
    let first = (0..<(cap - 3)).map { rejection("jobs", "J\($0)") }
    expectEqual(try store.settle(rejected: first, clearedKeys: [], binding: bindingA, now: now), 0, "bound: under the cap drops nothing")
    let second = (0..<8).map { rejection("invoices", "I\($0)") }
    let dropped = try store.settle(rejected: second, clearedKeys: [], binding: bindingA, now: now.addingTimeInterval(1))
    expectEqual(dropped, 5, "bound: the overflow is counted")
    let kept = try store.load(binding: bindingA)
    expectEqual(kept.count, cap, "bound: the store keeps exactly the cap")
    expectEqual(kept.first?.key, "jobs/J5", "bound: the oldest entries are dropped")
    expectEqual(kept.last?.key, "invoices/I7", "bound: the newest entries are kept")
    // A single settle larger than the cap keeps its own newest entries.
    let flood = (0..<(cap + 20)).map { rejection("expenses", "E\($0)") }
    let floodDropped = try store.settle(rejected: flood, clearedKeys: [], binding: bindingA, now: now.addingTimeInterval(2))
    expectEqual(floodDropped, cap + 20, "bound: a flood drops every older entry and its own oldest")
    let floodKept = try store.load(binding: bindingA)
    expectEqual(floodKept.count, cap, "bound: still exactly the cap")
    expectEqual(floodKept.first?.key, "expenses/E20", "bound: the flood's oldest are dropped")
}

@MainActor
func testStoreFailsClosed() throws {
    let dir = tempDirectory("fail")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("rejected-changes.json")
    let files = FlakyFiles()
    let store = NativeRejectedChangeStore(fileURL: url, files: files)
    try store.settle(rejected: [rejection("jobs", "J1")], clearedKeys: [], binding: bindingA, now: now)

    // A read failure (before first unlock, or an I/O error) is not "empty".
    files.failRead = true
    do {
        _ = try store.load(binding: bindingA)
        expect(false, "fail: an unreadable file must throw")
    } catch {
        expectEqual(error as? NativeRejectedChangeStoreError, .unreadable, "fail: an unreadable file throws unreadable")
    }
    do {
        try store.settle(rejected: [rejection("jobs", "J2")], clearedKeys: [], binding: bindingA, now: now)
        expect(false, "fail: settling over an unreadable file must throw")
    } catch {
        expectEqual(error as? NativeRejectedChangeStoreError, .unreadable, "fail: settle over an unreadable file throws")
    }
    files.failRead = false
    expectEqual(try store.load(binding: bindingA).map(\.key), ["jobs/J1"], "fail: nothing was lost or overwritten")

    // A write failure throws (the coordinator keeps the change queued).
    files.failWrite = true
    do {
        try store.settle(rejected: [rejection("jobs", "J2")], clearedKeys: [], binding: bindingA, now: now)
        expect(false, "fail: a failed write must throw")
    } catch {
        expect(true, "fail: a failed write throws")
    }
    files.failWrite = false
    expectEqual(try store.load(binding: bindingA).map(\.key), ["jobs/J1"], "fail: a failed write changes nothing")

    // A remove failure throws (the boundary step stays pending).
    files.failRemove = true
    do {
        try store.removeAll()
        expect(false, "fail: a failed removeAll must throw")
    } catch {
        expect(true, "fail: a failed removeAll throws")
    }
    files.failRemove = false

    // A corrupt or foreign-schema file reads as empty (it must never wedge
    // sync the way the poison item did) and the next settle replaces it.
    try Data("not json".utf8).write(to: url)
    expectEqual(try store.load(binding: bindingA), [], "fail: a corrupt file reads as empty")
    try store.settle(rejected: [rejection("jobs", "J3")], clearedKeys: [], binding: bindingA, now: now)
    expectEqual(try store.load(binding: bindingA).map(\.key), ["jobs/J3"], "fail: the next settle replaces a corrupt file")
    try Data(#"{"schemaVersion":99,"ownerTag":"x","entries":[]}"#.utf8).write(to: url)
    expectEqual(try store.load(binding: bindingA), [], "fail: an unknown schema reads as empty")

    // Nothing to settle writes nothing.
    let before = files.writes
    try store.settle(rejected: [], clearedKeys: ["jobs/none"], binding: bindingA, now: now)
    expectEqual(files.writes, before, "fail: a no-op settle does not rewrite the file")
}

@MainActor
func testDisplay() {
    let labels = [
        "jobs": "Job", "invoices": "Invoice", "customers": "Customer", "expenses": "Expense",
        "pricebook": "Price book item", "recurringJobs": "Recurring job", "recurringInvoices": "Recurring invoice",
        "trips": "Trip", "bookingRequests": "Booking request", "jobPhotos": "Job photo",
        "settings": "Business settings", "customer_notes": "Customer note", "unknown": "Record",
    ]
    for (table, label) in labels {
        expectEqual(NativeRejectedChangeDisplay.typeLabel(table: table), label, "display: \(table) type label")
    }
    func object(_ fields: [String: String]) -> Canonical.JSONValue { .object(fields.mapValues { .string($0) }) }
    expectEqual(NativeRejectedChangeDisplay.name(table: "jobs", payload: object(["title": "Kitchen remodel"])), "Kitchen remodel", "display: job title")
    expectEqual(NativeRejectedChangeDisplay.name(table: "jobs", payload: object(["title": " ", "customerName": "Ada"])), "Ada", "display: job falls back to customer")
    expectEqual(NativeRejectedChangeDisplay.name(table: "invoices", payload: object(["number": "INV-0012", "customer": "Ada"])), "INV-0012", "display: invoice number")
    expectEqual(NativeRejectedChangeDisplay.name(table: "customers", payload: object(["name": "Ada Lovelace"])), "Ada Lovelace", "display: customer name")
    expectEqual(NativeRejectedChangeDisplay.name(table: "expenses", payload: object(["description": "Lumber"])), "Lumber", "display: expense description")
    expectEqual(NativeRejectedChangeDisplay.name(table: "pricebook", payload: object(["name": "Faucet swap"])), "Faucet swap", "display: price book name")
    expectEqual(NativeRejectedChangeDisplay.name(table: "trips", payload: object(["purpose": "Supply run"])), "Supply run", "display: trip purpose")
    expectEqual(NativeRejectedChangeDisplay.name(table: "bookingRequests", payload: object(["name": "Grace"])), "Grace", "display: booking name")
    expectEqual(NativeRejectedChangeDisplay.name(table: "recurringInvoices", payload: object(["customerName": "Ada"])), "Ada", "display: recurring invoice customer")
    expectEqual(NativeRejectedChangeDisplay.name(table: "jobs", payload: nil), nil, "display: no payload has no name")
    expectEqual(NativeRejectedChangeDisplay.name(table: "jobPhotos", payload: object(["id": "p1"])), nil, "display: a photo has no name")
}


// MARK: - 2. AppStore wiring

struct NoopReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

@MainActor
final class SubscriptionStub: NativeSubscriptionServing {
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

/// A subscription service whose `logOut` (the last await of an account
/// switch, while `accountSwitchInFlight` is set) runs a hook.
@MainActor
final class LogOutHookSubscription: NativeSubscriptionServing {
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

/// A throwaway App Group suite: a host test never touches the real one.
struct TempAppGroup {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL

    init(_ label: String) {
        suiteName = "com.tradeready.rejected-changes.tests.\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = tempDirectory("group-\(label)")
    }

    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(
            suiteName: suiteName, defaults: defaults,
            lockFile: directory.appendingPathComponent(WidgetAppGroup.lockFileName)
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// One AppStore on `directory` (a second call on the same directory is a relaunch).
@MainActor
func makeAppStore(
    _ directory: URL, group: TempAppGroup, files: FlakyFiles,
    initialSyncService: (any NativeInitialSyncServing)? = nil,
    subscriptionService: (any NativeSubscriptionServing)? = nil
) -> AppStore {
    AppStore(
        fileURL: directory.appendingPathComponent("store.json"),
        seedIfMissing: true,
        appGroupAccountScrubber: group.scrubber,
        initialSyncService: initialSyncService,
        subscriptionService: subscriptionService ?? SubscriptionStub(),
        widgetTimelineReloader: NoopReloader(),
        secureSettingsStore: hostTestSecureSettingsStore(),
        rejectedChangeFiles: files
    )
}

@MainActor
func settlement(_ rejected: [NativeMutationRejection], cleared: [Canonical.MutationItem] = []) -> NativeMutationPushSettlement {
    NativeMutationPushSettlement(rejected: rejected, cleared: cleared)
}

func storeFile(_ directory: URL) -> URL { directory.appendingPathComponent("rejected-changes.json") }
func marker(_ directory: URL) -> URL {
    directory.appendingPathComponent("store.json").appendingPathExtension("rejected-changes-scrub-pending")
}

@MainActor
func testAppStoreSettleAndOwner() async {
    let group = TempAppGroup("settle")
    defer { group.cleanUp() }
    let dir = tempDirectory("settle")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = makeAppStore(dir, group: group, files: FlakyFiles())

    // No owner: the settle step refuses, so the coordinator keeps the change queued.
    do {
        try store.testSettleRejectedChanges(settlement([rejection("jobs", "J1")]))
        expect(false, "settle: without an owner it must throw")
    } catch {
        expect(true, "settle: without an owner it throws")
    }
    expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "settle: without an owner nothing is filed")

    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    do {
        try store.testSettleRejectedChanges(settlement([rejection("jobs", "J1"), rejection("invoices", "I1", status: 409)]))
    } catch {
        expect(false, "settle: the owner's settle threw \(error)")
    }
    expectEqual(store.rejectedChanges.map(\.id), ["jobs/J1", "invoices/I1"], "settle: Cloud Sync lists the refused changes")
    expectEqual(store.rejectedChanges.first.flatMap { store.rejectedChangeName($0) }, "Private title",
                "settle: the entry shows the record's name")
    expectEqual((try? store.persistenceDiagnostics())?.rejectedChangeCount, 2, "settle: the support diagnostics count them")

    // The support report carries the count only, never the change.
    if let url = try? store.createPersistenceSupportReport(appVersion: "test"),
       let text = try? String(contentsOf: url, encoding: .utf8) {
        expect(text.contains("\"rejectedChangeCount\":2"), "report: the support report carries the count")
        expect(text.contains("\"reportSchemaVersion\":2"), "report: the schema version is 2")
        for secret in ["J1", "I1", "Private title", "jobs/", bindingA] {
            expect(!text.contains(secret), "report: the support report never carries '\(secret)'")
        }
    } else {
        expect(false, "report: the support report was written")
    }

    // Another owner (no boundary ran, e.g. a lost scrub) sees nothing.
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: bindingB)
    store.refreshRejectedChanges()
    expectEqual(store.rejectedChanges, [], "owner: another owner sees none of A's entries")
    expectEqual((try? store.persistenceDiagnostics())?.rejectedChangeCount, 0, "owner: …and counts none")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    store.refreshRejectedChanges()
    expectEqual(store.rejectedChanges.count, 2, "owner: A still sees their own")

    // An unwritable store refuses the settle (the change stays queued).
    let flaky = FlakyFiles()
    let lockedDir = tempDirectory("settle-locked")
    defer { try? FileManager.default.removeItem(at: lockedDir) }
    let locked = makeAppStore(lockedDir, group: group, files: flaky)
    locked.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    flaky.failWrite = true
    do {
        try locked.testSettleRejectedChanges(settlement([rejection("jobs", "J1")]))
        expect(false, "settle: an unwritable store must throw")
    } catch {
        expect(true, "settle: an unwritable store throws")
    }
    expectEqual(locked.rejectedChanges, [], "settle: nothing is listed when nothing was filed")

    // A flood past the cap: the oldest are dropped and counted (bounded diagnostic).
    let floodDir = tempDirectory("settle-flood")
    defer { try? FileManager.default.removeItem(at: floodDir) }
    let flood = makeAppStore(floodDir, group: group, files: FlakyFiles())
    flood.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    let many = (0...NativeRejectedChangeStore.capacity).map { rejection("jobs", "F\($0)") }
    do { try flood.testSettleRejectedChanges(settlement(many)) } catch { expect(false, "flood: settle threw \(error)") }
    expectEqual(flood.rejectedChanges.count, NativeRejectedChangeStore.capacity, "flood: the list is bounded")
    expectEqual(flood.rejectedChanges.first?.id, "jobs/F1", "flood: the oldest was dropped")
    expectEqual(flood.rejectedChangeOverflowCount, 1, "flood: the drop is counted")
    // A cleared-only settle with no owner is a no-op (nothing can be listed).
    let noOwnerDir = tempDirectory("settle-no-owner")
    defer { try? FileManager.default.removeItem(at: noOwnerDir) }
    let noOwner = makeAppStore(noOwnerDir, group: group, files: FlakyFiles())
    do {
        try noOwner.testSettleRejectedChanges(settlement([], cleared: [item("jobs", "J1")]))
        expect(true, "settle: a cleared-only settle without an owner is a no-op")
    } catch {
        expect(false, "settle: a cleared-only settle without an owner must not throw")
    }
}

/// A delta pull whose server has a newer title for every job, so any job
/// the pull is not told to keep takes "Server title". Counts its calls.
final class OverwritingDelta: NativeInitialSyncServing, NativeDeltaSyncServing {
    private(set) var deltaCalls = 0
    func pull(sessionBytes: Data, expectedUserSubject: String, localSnapshot: Canonical.Snapshot) async throws -> Canonical.Snapshot {
        localSnapshot
    }
    func pullDelta(
        sessionBytes: Data, expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot, cursor: Canonical.NativeSyncCursor
    ) async throws -> NativeDeltaPullOutcome {
        deltaCalls += 1
        var pulled = localSnapshot
        pulled.payload.jobs = pulled.payload.jobs?.map { job in
            var job = job
            job.title = "Server title"
            return job
        }
        return NativeDeltaPullOutcome(snapshot: pulled, cursor: cursor, failedTables: [], lastDiagnosticCode: nil)
    }
}

/// Fix round 1 (review M2): a subject with no verified account binding (a
/// rejected session keeps the subject) cannot tell whose refused changes the
/// store holds. The pull must not overwrite a refused record then, and a
/// push's cleared-only settle must not silently skip the entry it clears
/// (a later Retry would send the older, refused change over the newer one).
@MainActor
func testNoBindingFailsClosed() async {
    let group = TempAppGroup("no-binding")
    defer { group.cleanUp() }
    let dir = tempDirectory("no-binding")
    defer { try? FileManager.default.removeItem(at: dir) }
    let delta = OverwritingDelta()
    let store = makeAppStore(dir, group: group, files: FlakyFiles(), initialSyncService: delta)
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    store.scheduleBookingTestCredentials = NativeSyncCredentials(subject: "user-a", sessionBytes: Data())
    guard store.jobs.count >= 2 else {
        expect(false, "no-binding: sanity: the demo workspace has at least two jobs")
        return
    }
    let refusedID = store.jobs[0].id, otherID = store.jobs[1].id
    let refusedTitle = store.jobs[0].title
    do { try store.testSettleRejectedChanges(settlement([rejection("jobs", refusedID, title: refusedTitle)])) }
    catch { expect(false, "no-binding: seeding the refusal threw \(error)") }

    // Positive control: with the binding, the pull keeps the refused record
    // and takes the server's version of the rest.
    let bound = await store.testPullDeltaIfPossible()
    expectEqual(bound.state, .completed, "no-binding: sanity: the owner's pull completes")
    expectEqual(store.jobs.first { $0.id == refusedID }?.title, refusedTitle, "no-binding: sanity: the owner's pull keeps the refused record")
    expectEqual(store.jobs.first { $0.id == otherID }?.title, "Server title", "no-binding: sanity: the owner's pull takes the server's other rows")
    let callsBefore = delta.deltaCalls

    // The session is rejected: the subject stays, the binding is gone, and
    // the store file (the owner's refusal) is still on disk.
    store.testApplyRejectedSessionState()
    expect(FileManager.default.fileExists(atPath: storeFile(dir).path), "no-binding: sanity: the store file is present")
    let unbound = await store.testPullDeltaIfPossible()
    expectEqual(unbound, .failed("pull/rejected-store"), "no-binding: the pull fails closed")
    expectEqual(store.jobs.first { $0.id == refusedID }?.title, refusedTitle, "no-binding: the pull does not overwrite the refused record")
    expectEqual(delta.deltaCalls, callsBefore, "no-binding: the pull stops before the network")

    // A push that the server accepted for the refused record (a newer edit)
    // must not settle as cleared while the entry cannot be attributed.
    do {
        try store.testSettleRejectedChanges(settlement([], cleared: [item("jobs", refusedID)]))
        expect(false, "no-binding: a cleared-only settle must throw (the attempt stays queued)")
    } catch {
        expect(true, "no-binding: a cleared-only settle throws (the attempt stays queued)")
    }
    let kept = (try? NativeRejectedChangeStore(fileURL: storeFile(dir)).load(binding: bindingA))?.map(\.key)
    expectEqual(kept, ["jobs/\(refusedID)"], "no-binding: the entry waits for the re-sent attempt")

    // The binding is verified again: the re-sent attempt's settle clears it,
    // so no stale Retry is left.
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    do { try store.testSettleRejectedChanges(settlement([], cleared: [item("jobs", refusedID)])) }
    catch { expect(false, "no-binding: the owner's cleared settle threw \(error)") }
    expectEqual((try? NativeRejectedChangeStore(fileURL: storeFile(dir)).load(binding: bindingA))?.count, 0,
                "no-binding: the owner's re-sent settle clears the entry")
    expectEqual(store.rejectedChanges, [], "no-binding: no stale Retry is listed")
}

@MainActor
func seedEntries(_ store: AppStore) {
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    do { try store.testSettleRejectedChanges(settlement([rejection("jobs", "J1"), rejection("customers", "C1")])) }
    catch { expect(false, "seed: settle threw \(error)") }
}

@MainActor
func testBoundaryScrubs() async {
    // Sign-out (the full .live scrub).
    do {
        let group = TempAppGroup("signout")
        defer { group.cleanUp() }
        let dir = tempDirectory("signout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeAppStore(dir, group: group, files: FlakyFiles())
        seedEntries(store)
        expect(FileManager.default.fileExists(atPath: storeFile(dir).path), "sign-out: sanity: entries are filed")
        do { try await store.signOut(revokeRemote: false) } catch { expect(false, "sign-out threw \(error)") }
        expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "sign-out: the store is removed")
        expectEqual(store.rejectedChanges, [], "sign-out: nothing is listed")
    }

    // Deletion (a pending .all scrub finished by the next launch).
    do {
        let group = TempAppGroup("delete")
        defer { group.cleanUp() }
        let dir = tempDirectory("delete")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeAppStore(dir, group: group, files: FlakyFiles())
        seedEntries(store)
        do {
            try Canonical.SnapshotRepository(primaryURL: dir.appendingPathComponent("store.json")).beginAccountScrub(scope: .all)
        } catch {
            expect(false, "deletion: could not stage the pending scrub: \(error)")
        }
        let relaunched = makeAppStore(dir, group: group, files: FlakyFiles())
        expect(!relaunched.isAccountScrubBlocked, "deletion: the scrub finished at launch")
        expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "deletion: the store is removed")
    }

    // Deletion in process (review fix round 1, M6): the local scrub
    // `deleteAccount` runs once the server confirms (`testSources` pins the
    // call inside `deleteAccount`; its network call cannot run here).
    do {
        let group = TempAppGroup("delete-now")
        defer { group.cleanUp() }
        let dir = tempDirectory("delete-now")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeAppStore(dir, group: group, files: FlakyFiles())
        seedEntries(store)
        expect(FileManager.default.fileExists(atPath: storeFile(dir).path), "deletion now: sanity: entries are filed")
        do { try store.testRunAccountDeletionLocalScrub() } catch { expect(false, "deletion now: the local scrub threw \(error)") }
        expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "deletion now: the store is removed")
    }

    // Account switch (a boundary step outside the full scrub).
    do {
        let group = TempAppGroup("switch")
        defer { group.cleanUp() }
        let dir = tempDirectory("switch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeAppStore(dir, group: group, files: FlakyFiles())
        seedEntries(store)
        store.scheduleBookingTestSeedIdentityActivator()
        await store.useAnotherAccount(clearGoogleCredential: {})
        expectEqual(store.authenticationGateState, .signedOut, "switch: sanity: the switch reached its success path")
        expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "switch: the store is removed")
        expect(!FileManager.default.fileExists(atPath: marker(dir).path), "switch: no step is left pending")
        expectEqual(store.rejectedChanges, [], "switch: nothing is listed")
    }

    // Password-recovery exit.
    do {
        let group = TempAppGroup("recovery")
        defer { group.cleanUp() }
        let dir = tempDirectory("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeAppStore(dir, group: group, files: FlakyFiles())
        seedEntries(store)
        await store.cancelPasswordRecovery()
        expectEqual(store.authenticationGateState, .signedOut, "recovery: sanity: the recovery sign-out ran")
        expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "recovery: the store is removed")
        expectEqual(store.rejectedChanges, [], "recovery: nothing is listed")
    }

    // The invalid-recovery-link exit (review fix round 1, M6). The recovery
    // state lives in an in-memory Keychain stand-in, never the real one.
    // (`updateRecoveredPassword` needs a configured Supabase client; it ends
    // in the same `applyRecoverySignedOutState` as the cancel exit above, and
    // `testSources` pins that.)
    do {
        let group = TempAppGroup("recovery-dismiss")
        defer { group.cleanUp() }
        let dir = tempDirectory("recovery-dismiss")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeAppStore(dir, group: group, files: FlakyFiles())
        seedEntries(store)
        let recovery = NativePasswordRecoveryStore(backend: HostInMemoryKeychain())
        do { try recovery.markActive(userSubject: "user-a") } catch { expect(false, "recovery dismiss: could not mark recovery active: \(error)") }
        expectEqual((try? recovery.read())??.activeUserSubject, "user-a", "recovery dismiss: sanity: a recovery session is active")
        await store.dismissInvalidPasswordRecovery(recoveryStore: recovery)
        let recoveryCleared: Bool = { do { return try recovery.read() == nil } catch { return false } }()
        expect(recoveryCleared, "recovery dismiss: sanity: the recovery state is cleared")
        expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "recovery dismiss: the store is removed")
        expectEqual(store.rejectedChanges, [], "recovery dismiss: nothing is listed")
    }
}

/// Review fix round 1 (M6): while an account switch is in flight, a settle
/// that files a refusal throws (the attempt stays queued for the next
/// owner's pass, and the switch's second scrub runs after), and a
/// cleared-only settle is a no-op. Driven from the switch's last await.
@MainActor
func testSwitchInFlightSettle() async {
    let group = TempAppGroup("switch-in-flight")
    defer { group.cleanUp() }
    let dir = tempDirectory("switch-in-flight")
    defer { try? FileManager.default.removeItem(at: dir) }
    let hook = LogOutHookSubscription()
    let store = makeAppStore(dir, group: group, files: FlakyFiles(), subscriptionService: hook)
    seedEntries(store)
    store.scheduleBookingTestSeedIdentityActivator()
    var refusalThrew: Bool?
    var clearedThrew: Bool?
    var filedMidSwitch: Bool?
    hook.onLogOut = {
        do { try store.testSettleRejectedChanges(settlement([rejection("jobs", "J7")])); refusalThrew = false }
        catch { refusalThrew = true }
        do { try store.testSettleRejectedChanges(settlement([], cleared: [item("jobs", "J1")])); clearedThrew = false }
        catch { clearedThrew = true }
        filedMidSwitch = FileManager.default.fileExists(atPath: storeFile(dir).path)
    }
    await store.useAnotherAccount(clearGoogleCredential: {})
    expectEqual(store.authenticationGateState, .signedOut, "switch in flight: sanity: the switch reached its success path")
    expectEqual(refusalThrew, true, "switch in flight: a settle with a refusal throws (the attempt stays queued)")
    expectEqual(clearedThrew, false, "switch in flight: a cleared-only settle is a no-op")
    expectEqual(filedMidSwitch, false, "switch in flight: nothing is filed under the old owner mid-switch")
}

/// Review fix round 1 (M6): deleting a refused record on this device queues
/// a delete, which hides the entry (it supersedes the refusal), and the
/// pass that pushes the delete clears the entry.
@MainActor
func testLocalDeleteOfRefusedRecord() {
    let group = TempAppGroup("local-delete")
    defer { group.cleanUp() }
    let dir = tempDirectory("local-delete")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = makeAppStore(dir, group: group, files: FlakyFiles())
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    guard let job = store.jobs.first else {
        expect(false, "local delete: sanity: the demo workspace has a job")
        return
    }
    let key = "jobs/\(job.id)"
    func filed() -> [String]? {
        (try? NativeRejectedChangeStore(fileURL: storeFile(dir)).load(binding: bindingA))?.map(\.key)
    }
    do { try store.testSettleRejectedChanges(settlement([rejection("jobs", job.id, title: job.title)])) }
    catch { expect(false, "local delete: seeding the refusal threw \(error)") }
    expectEqual(store.rejectedChanges.map(\.id), [key], "local delete: sanity: the refusal is listed")

    expect(store.deleteJob(id: job.id), "local delete: sanity: the job is deleted on this device")
    // The same queue file AppStore.init opened.
    let queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
    guard let deletion = queue.load().first(where: { $0.table == "jobs" && $0.recordId == job.id }) else {
        expect(false, "local delete: sanity: the delete is queued")
        return
    }
    store.refreshRejectedChanges()
    expectEqual(store.rejectedChanges, [], "local delete: the queued delete hides the refused entry")
    expectEqual(filed(), [key], "local delete: the entry is kept while the delete is queued")

    // The server accepts the delete: the pass settles it as cleared, then the
    // queue commits the attempt (the coordinator's order).
    do { try store.testSettleRejectedChanges(settlement([], cleared: [deletion])) }
    catch { expect(false, "local delete: the accepted delete's settle threw \(error)") }
    do { _ = try queue.reconcilePush(startedItems: [deletion], remaining: []) }
    catch { expect(false, "local delete: sanity: the queue commit threw \(error)") }
    store.refreshRejectedChanges()
    expectEqual(filed(), [], "local delete: the accepted delete clears the entry")
    expectEqual(store.rejectedChanges, [], "local delete: nothing comes back once the delete has left the queue")
}

@MainActor
func testFailedScrubFailsClosedAndRetries() async {
    let group = TempAppGroup("scrub-fail")
    defer { group.cleanUp() }
    let dir = tempDirectory("scrub-fail")
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = FlakyFiles()
    let store = makeAppStore(dir, group: group, files: files)
    seedEntries(store)
    store.scheduleBookingTestSeedIdentityActivator()
    files.failRemove = true
    await store.useAnotherAccount(clearGoogleCredential: {})
    expectEqual(store.authenticationGateState, .signedOut, "scrub-fail: sanity: the switch reached its success path")
    expect(FileManager.default.fileExists(atPath: storeFile(dir).path), "scrub-fail: sanity: the file could not be removed")
    expect(FileManager.default.fileExists(atPath: marker(dir).path), "scrub-fail: the failed scrub leaves a durable pending marker")
    expect(store.isAccountBoundaryCleanupPending, "scrub-fail: the cleanup retry is offered")
    expect(store.rejectedChangeScrubFailureCount >= 1, "scrub-fail: the failure is counted")

    // While pending: nothing is listed or counted, and nothing new is filed.
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: bindingA)
    store.refreshRejectedChanges()
    expectEqual(store.rejectedChanges, [], "scrub-fail: while pending nothing is listed, even for the same owner")
    do {
        try store.testSettleRejectedChanges(settlement([rejection("jobs", "J9")]))
        expect(false, "scrub-fail: a settle while pending must throw")
    } catch {
        expect(true, "scrub-fail: a settle while pending throws (the change stays queued)")
    }

    // A relaunch keeps it pending while removal still fails.
    let relaunched = makeAppStore(dir, group: group, files: files)
    expect(FileManager.default.fileExists(atPath: marker(dir).path), "scrub-fail: the pending step survives a relaunch")
    expect(relaunched.isAccountBoundaryCleanupPending, "scrub-fail: …and is still offered after it")

    // The retry clears it.
    files.failRemove = false
    store.retryAccountScrub()
    expect(!FileManager.default.fileExists(atPath: marker(dir).path), "scrub-fail: the retry clears the marker")
    expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "scrub-fail: …after removing the store")
    expect(!store.isAccountBoundaryCleanupPending, "scrub-fail: the retry is no longer offered")

    // The launch retry clears a pending step too.
    seedEntries(store)
    files.failRemove = true
    await store.cancelPasswordRecovery()
    expect(FileManager.default.fileExists(atPath: marker(dir).path), "scrub-fail: a recovery exit's failed scrub is pending")
    files.failRemove = false
    _ = makeAppStore(dir, group: group, files: files)
    expect(!FileManager.default.fileExists(atPath: marker(dir).path), "scrub-fail: the launch retry clears the marker")
    expect(!FileManager.default.fileExists(atPath: storeFile(dir).path), "scrub-fail: …after removing the store")
}

// MARK: - 3. Discard's server record (settings and notes)

@MainActor
func testServerRecordApply() throws {
    let service = NativeSupabaseInitialSyncService(
        supabaseURL: URL(string: "https://project.supabase.co")!, publishableKey: "publishable-key"
    )
    var base = Canonical.Snapshot(payload: .init())
    base.payload.customerNotes = ["cust-1": "Local-only note", "cust-2": "Keep"]
    let removed = try service.applyingServerRecord(.absent, table: "customer_notes", recordId: "cust-1", to: base)
    expectEqual(removed.payload.customerNotes, ["cust-2": "Keep"], "apply: a note the server lacks is removed")
    let replaced = try service.applyingServerRecord(.present(.string("Server note")), table: "customer_notes", recordId: "cust-1", to: base)
    expectEqual(replaced.payload.customerNotes?["cust-1"], "Server note", "apply: a note takes the server's text")
    do {
        _ = try service.applyingServerRecord(.present(.number(1)), table: "customer_notes", recordId: "cust-1", to: base)
        expect(false, "apply: a malformed note must throw")
    } catch {
        expect(true, "apply: a malformed note throws")
    }
    let kept = try service.applyingServerRecord(.absent, table: "settings", recordId: "settings", to: base)
    expectEqual(kept.payload.settings == nil, base.payload.settings == nil, "apply: settings the server lacks stay local")
    do {
        _ = try service.applyingServerRecord(.absent, table: "nope", recordId: "x", to: base)
        expect(false, "apply: an unknown table must throw")
    } catch {
        expect(true, "apply: an unknown table throws")
    }
}

// MARK: - 4. Source checks

@MainActor
func testSources() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let n = root.appendingPathComponent("native/TradeReadyNative")
    let storeSource = (try? String(contentsOf: n.appendingPathComponent("NativeRejectedChangeStore.swift"), encoding: .utf8)) ?? ""
    expect(!storeSource.isEmpty, "source: the store source is readable")
    expect(!storeSource.contains("print(") && !storeSource.contains("Logger") && !storeSource.contains("os_log"),
           "source: the store never logs")
    let appStore = (try? String(contentsOf: n.appendingPathComponent("AppStore.swift"), encoding: .utf8)) ?? ""
    let wipes = appStore.components(separatedBy: "wipeAIProviderKeysForAccountBoundary()").count - 1
    let scrubs = appStore.components(separatedBy: "scrubRejectedChangesForAccountBoundary()").count - 1
    expect(wipes >= 5, "source: sanity: the AI-key wipe call sites are found")
    expectEqual(scrubs, wipes, "source: every switch/recovery boundary that wipes AI keys also scrubs the rejected store")
    // Phase 12 (12.00b.2-G, P12-004): the full scrub, its retry and launch
    // recovery clear one shared list of stores, so the removal is written
    // there once instead of three times.
    let sharedScrubStores = sourceBody(appStore, "private func removeAccountScrubStores(") ?? ""
    expect(sharedScrubStores.contains("try rejectedChangeStore.removeAll()"),
           "source: the shared account-scrub list removes the store")
    expectEqual(appStore.components(separatedBy: "try removeAccountScrubStores()").count - 1, 3,
                "source: the full scrub, its retry and launch recovery all run the shared list")
    let boundaryScrub = sourceBody(appStore, "private func scrubRejectedChangesForAccountBoundary(") ?? ""
    expect(boundaryScrub.contains("try rejectedChangeStore.removeAll()"), "source: the boundary step removes the store")

    // Review fix round 1 (M6): the exits no host test can drive end in a path
    // one does. `updateRecoveredPassword` needs a configured Supabase client;
    // it ends in the recovery sign-out the cancel exit runs (tested above).
    // `deleteAccount` needs the network; after the server deletion it runs
    // the local scrub `testRunAccountDeletionLocalScrub` runs (tested above).
    if let update = sourceBody(appStore, "func updateRecoveredPassword("),
       let clear = update.range(of: "try recoveryStore.clear()"),
       let signOut = update.range(of: "applyRecoverySignedOutState()") {
        expect(clear.upperBound < signOut.lowerBound, "source: the recovery update ends in the recovery sign-out")
    } else {
        expect(false, "source: updateRecoveredPassword ends in applyRecoverySignedOutState")
    }
    expect(sourceBody(appStore, "private func applyRecoverySignedOutState(")?.contains("scrubRejectedChangesForAccountBoundary()") == true,
           "source: the recovery sign-out scrubs the store")
    if let deletion = sourceBody(appStore, "func deleteAccount("),
       let server = deletion.range(of: "try await client.deleteAccount("),
       let scrub = deletion.range(of: "try performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .all)") {
        expect(server.upperBound < scrub.lowerBound, "source: deleteAccount runs the local .all scrub after the server deletion")
    } else {
        expect(false, "source: deleteAccount runs the local .all scrub")
    }
    // Review fix round 1 (M7): Cloud Sync never reads "Up to date" (or
    // "Ready to sync") while refused changes are listed.
    let settings = (try? String(contentsOf: n.appendingPathComponent("SettingsView.swift"), encoding: .utf8)) ?? ""
    for property in ["private var statusTitle:", "private var statusMessage:", "private var statusSymbol:", "private var statusColor:"] {
        if let body = sourceBody(settings, property), let refused = body.range(of: "!store.rejectedChanges.isEmpty") {
            let settled = [body.range(of: "lastSuccessfulSyncAt"), body.range(of: "return \"icloud.fill\""),
                           body.range(of: "return Color.tradeSuccessText")].compactMap { $0 }
            expect(!settled.isEmpty && settled.allSatisfy { refused.lowerBound < $0.lowerBound },
                   "source: \(property) checks refused changes before any settled state")
        } else {
            expect(false, "source: \(property) accounts for refused changes")
        }
    }
    expect(sourceBody(appStore, "func testRunAccountDeletionLocalScrub(")?
            .contains("try performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .all)") == true,
           "source: the deletion seam runs deleteAccount's exact local scrub")
}

/// The text of the declaration that starts at `marker`, through its closing
/// brace (the parameter list is skipped, since a default argument can hold
/// parentheses).
func sourceBody(_ text: String, _ marker: String) -> String? {
    guard let start = text.range(of: marker) else { return nil }
    var index = start.upperBound
    if marker.hasSuffix("(") {
        var parens = 1
        while index < text.endIndex, parens > 0 {
            if text[index] == "(" { parens += 1 }
            if text[index] == ")" { parens -= 1 }
            index = text.index(after: index)
        }
    }
    guard let open = text[index...].firstIndex(of: "{") else { return nil }
    var depth = 0
    index = open
    while index < text.endIndex {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" {
            depth -= 1
            if depth == 0 { return String(text[start.lowerBound...index]) }
        }
        index = text.index(after: index)
    }
    return nil
}

// MARK: - Main

@main
struct RejectedChangesTests {
    @MainActor
    static func main() async {
        do {
            try testStoreBasics()
            try testStoreBound()
            try testStoreFailsClosed()
        } catch {
            failures += 1
            print("FAIL: store threw \(error)")
        }
        testDisplay()
        await testAppStoreSettleAndOwner()
        await testNoBindingFailsClosed()
        await testBoundaryScrubs()
        await testSwitchInFlightSettle()
        testLocalDeleteOfRefusedRecord()
        await testFailedScrubFailsClosedAndRetries()
        do { try testServerRecordApply() } catch {
            failures += 1
            print("FAIL: server record apply threw \(error)")
        }
        testSources()
        if failures > 0 {
            print("rejected-changes tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("PASS: rejected-changes tests (\(checks) checks)")
    }
}
