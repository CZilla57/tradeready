import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Phase 12 (12.06) host tests: the rollback-readiness check (charter §6 item 2:
// "the native build drains its mutation queue before any rollback advisory").
//
// Before support tells an owner to install the Expo rollback build, the owner
// runs Settings › Cloud Sync › "Check everything is saved"
// (`AppStore.prepareRollbackReadiness`). It forces one push pass (after the
// widget/Siri replay, then the photo uploads), then says whether this account
// is safe to roll back: the queue is empty, the I2 rejected store is empty (or
// its entries are listed as needing Retry or Discard, never discarded by the
// check), the widget/Siri replay queue is empty, no photo is waiting to
// upload, no booking or portal link work is unfinished, and the migration
// journal is complete. It fails closed, with nothing sent, while writes are
// blocked, a scrub or boundary step is pending, an account operation is in
// flight, the journal is incomplete or the migration blocked, the initial
// sync has not completed, or the device is not the verified signed-in owner
// (section K covers each private flag, table-driven; K2 the second tap). An
// account change while it is suspended in the drain voids the result. The
// support report carries the last result as codes and counts only.
//
// Everything here is production code except the network: the real AppStore,
// the real durable queue, the real `NativeSyncCoordinator` (wired as
// `syncCoordinatorIfConfigured` wires it) and push transport, and the real
// widget claim transport, in front of the shared `InMemorySupabase`. Run with
// TZ=America/Phoenix.

// MARK: - Harness

final class SwitchReachability: NativeSyncReachability, @unchecked Sendable {
    var online = true
    func isReachable() async -> Bool { online }
}

/// The App Group widget/Siri action queue in memory (the extension's writer side).
final class MemoryWidgetActionQueue: NativeWidgetActionQueueBacking {
    var value: String?
    func read() -> String? { value }
    func write(_ value: String?) { self.value = value }
}

/// The server behind a request counter: "nothing sent" means no request at
/// all (no push, no pull), not only no row.
final class CountingLoader: NativeInitialSyncHTTPDataLoading, NativeMutationPushHTTPLoading, @unchecked Sendable {
    let server: InMemorySupabase
    private(set) var requests = 0
    init(_ server: InMemorySupabase) { self.server = server }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        return try await server.data(for: request)
    }
}

/// The photo worker: records uploads, or refuses them.
final class FakePhotoTransfer: NativeJobPhotoTransferring, @unchecked Sendable {
    var refuseUploads = false
    private(set) var uploaded: [String] = []
    func upload(photoID: String, bytes: Data, sessionBytes: Data) async throws -> String {
        if refuseUploads { throw URLError(.networkConnectionLost) }
        uploaded.append(photoID)
        return "2026-09-26T12:00:00.000Z"
    }
    func download(photoID: String, sessionBytes: Data) async throws -> Data {
        throw URLError(.fileDoesNotExist)
    }
}

@MainActor
final class Harness {
    static let supabaseURL = URL(string: "https://project.supabase.co")!

    let subject: String
    let binding: String
    let dir: URL
    let store: AppStore
    let server: InMemorySupabase
    let wire: CountingLoader
    let reach = SwitchReachability()
    let widgetQueue = MemoryWidgetActionQueue()
    let photos = FakePhotoTransfer()
    let queue: Canonical.NativeMutationQueue
    private(set) var coordinator: NativeSyncCoordinator?

    var storeURL: URL { dir.appendingPathComponent("store.json") }
    var journalURL: URL { dir.appendingPathComponent("migration-journal.json") }
    var queueURL: URL { dir.appendingPathComponent("mutation-queue.json") }
    var rejectedURL: URL { dir.appendingPathComponent("rejected-changes.json") }
    var repository: Canonical.SnapshotRepository { Canonical.SnapshotRepository(primaryURL: storeURL) }

    /// `beforeLaunch` writes files before the AppStore opens them.
    /// `lockFile` replaces the App Group lock (a missing directory makes it unusable).
    init(
        tag: String,
        subject: String = "11111111-2222-3333-4444-555555555555",
        binding: String = String(repeating: "b", count: 64),
        server: InMemorySupabase = InMemorySupabase(),
        lockFile: URL? = nil,
        beforeLaunch: (URL) throws -> Void = { _ in }
    ) {
        self.subject = subject
        self.binding = binding
        self.server = server
        let wire = CountingLoader(server)
        self.wire = wire
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-rollback-readiness-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? beforeLaunch(dir)
        let suite = "com.tradeready.rollback-readiness.tests.\(UUID().uuidString)"
        let lock = lockFile ?? dir.appendingPathComponent("app-group.lock")
        store = AppStore(
            fileURL: dir.appendingPathComponent("store.json"),
            seedIfMissing: false,
            widgetActionReplayTransport: NativeWidgetActionClaimTransport(
                queue: widgetQueue,
                claimDirectory: dir.appendingPathComponent("WidgetActionClaims", isDirectory: true),
                lockFile: lock
            ),
            appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                suiteName: suite,
                defaults: UserDefaults(suiteName: suite) ?? .standard,
                lockFile: dir.appendingPathComponent("app-group.lock")
            ),
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: wire
            ),
            jobPhotoTransferService: photos,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
    }

    /// A native-only signed-in owner (every real account): the verified
    /// session plus a completed workspace document bound to it.
    func signIn(initialSync: Bool = true) async {
        try? NativeOnboardingStore(snapshotURL: storeURL).save(NativeOnboardingDocument(
            accountBinding: binding, stage: .done,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        store.testSeedNativeSignedInOwner(subject: subject, binding: binding)
        store.scheduleBookingTestCredentials = NativeSyncCredentials(
            subject: subject, sessionBytes: Data(#"{"access_token":"private-access-token"}"#.utf8)
        )
        if initialSync {
            store.testMarkInitialSyncCompleted(subject: subject)
            // Its follow-up sync task finds no configured coordinator yet.
            for _ in 0..<20 { await Task.yield() }
        }
    }

    /// Wires the real coordinator exactly as `syncCoordinatorIfConfigured`
    /// does (the poor-network harness mirrors the same wiring).
    func connect() {
        let store = store
        let credentials = NativeSyncCredentials(
            subject: subject, sessionBytes: Data(#"{"access_token":"private-access-token"}"#.utf8)
        )
        let coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key",
                allowsWrites: true, loader: wire
            ),
            queue: queue,
            reachability: reach,
            credentialsProvider: { credentials },
            refreshSession: { false },
            settleRejected: { try store.testSettleRejectedChanges($0) },
            pull: { await store.testPullDeltaIfPossible() },
            statusChanged: { status in store.testApplySyncStatus(status) }
        )
        self.coordinator = coordinator
        store.testUseSyncCoordinator(coordinator)
    }

    /// A synced device: connects and pushes whatever the sign-in queued
    /// (the once-per-account backfill queues the workspace settings).
    func syncBaseline() async -> [String] {
        connect()
        _ = await coordinator?.sync(trigger: .manual)
        return queue.load().map { "\($0.table)/\($0.recordId)" }
    }

    func serverRows(_ table: String) -> Int { server.liveRowCount(table: table, userID: subject) }

    func report() -> [String: Any] {
        guard let data = try? NativeSupportDiagnostics.encode(store.supportReport(appVersion: "1.0", appBuild: "7")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    func reportText() -> String {
        guard let data = try? NativeSupportDiagnostics.encode(store.supportReport(appVersion: "1.0", appBuild: "7"))
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

func section(_ json: [String: Any], _ key: String) -> [String: Any] {
    (json[key] as? [String: Any]) ?? [:]
}

let rollbackReportKeys: Set<String> = [
    "lastCheck", "lastCheckAge", "drainOutcome", "blockers", "notes", "pendingChangeCount", "rejectedChangeCount",
    "widgetActionCount", "photosPendingUploadCount", "bookingWorkCount", "migrationJournal",
]

// MARK: - Tests

@main
struct RollbackReadinessTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(label)") }
    }

    @MainActor
    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")

        try await pendingItemsAreNotReady()
        try await successfulDrainIsReady()
        try await rejectedItemsAreListedNeverDiscarded()
        try await widgetActionsReplayThroughTheCheck()
        try await photosUploadThroughTheCheck()
        try await failsClosedWithNothingSent()
        try await unreadableStateIsNotReady()
        try await accountChangeDuringTheDrain()
        try await everyFailClosedFlagSendsNothing()
        try await secondTapIsRefused()
        try await bookingWorkIsANoteNotABlocker()
        try await nativeRunMarker()
        reportBeforeAnyCheck()
        sources(root)

        if failures == 0 {
            print("PASS: rollback readiness tests (\(checks) checks)")
        } else {
            print("rollback readiness tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }

    // MARK: A. Pending items: not ready, with counts

    @MainActor
    static func pendingItemsAreNotReady() async throws {
        let h = Harness(tag: "pending")
        defer { h.cleanup() }
        await h.signIn()
        expectEqual(await h.syncBaseline(), [], "A: sanity: the device starts synced")
        // Offline: the edits' own sync attempts, then the check's forced
        // push pass, cannot drain.
        h.reach.online = false
        let customer = Customer(name: "Ada Electric", email: "ada@example.test")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Panel upgrade", laborRate: 95)
        expect(h.store.upsert(customer) && h.store.upsert(job), "A: two local edits save")
        for _ in 0..<20 { await Task.yield() }

        let before = h.store.rollbackReadiness()
        expect(!before.isReady, "A: queued changes: not ready")
        expectEqual(before.blockers, [.pendingChanges], "A: the only blocker is the queue")
        expectEqual(before.pendingChangeCount, 2, "A: with its count")
        expectEqual(before.migrationJournal, .noEntry, "A: a native-only install has no journal entry")

        let check = await h.store.prepareRollbackReadiness()
        expectEqual(check?.drainOutcome, "offline", "A: the forced push pass ran and was offline")
        expectEqual(check?.readiness.blockers, [.pendingChanges], "A: still not ready")
        expectEqual(check?.readiness.pendingChangeCount, 2, "A: both changes are still queued")
        expectEqual(h.serverRows("customers") + h.serverRows("jobs"), 0, "A: nothing reached the server")
        expectEqual(h.store.currentRollbackReadinessCheck, check, "A: Settings shows this result")
        let summary = check.map { NativeRollbackReadinessCopy.summary($0.readiness) } ?? ""
        expect(summary.hasPrefix("Not ready yet:") && summary.contains("2 changes waiting to upload"),
               "A: the Settings line says what is left (\(summary))")

        let report = section(h.report(), "rollbackReadiness")
        expectEqual(Set(report.keys), rollbackReportKeys, "A: the closed rollbackReadiness schema")
        expectEqual(report["lastCheck"] as? String, "not-ready", "A: report: not ready")
        expectEqual(report["blockers"] as? [String], ["pending-changes"], "A: report: the blocker code")
        expectEqual(report["pendingChangeCount"] as? Int, 2, "A: report: the count")
        expectEqual(report["drainOutcome"] as? String, "offline", "A: report: the drain outcome")
        expectEqual(report["migrationJournal"] as? String, "no-entry", "A: report: the journal state")
        expectEqual(report["lastCheckAge"] as? String, "under-1h", "A: report: the check's age bucket")
    }

    // MARK: B. After a successful drain: ready

    @MainActor
    static func successfulDrainIsReady() async throws {
        let h = Harness(tag: "drained")
        defer { h.cleanup() }
        await h.signIn()
        expectEqual(await h.syncBaseline(), [], "B: sanity: the device starts synced")
        // A migrated device: the journal says the import completed.
        let journal = Canonical.MigrationJournal(fileURL: h.journalURL)
        _ = try journal.begin(.reactNativeAsyncStorage)
        try journal.complete(.reactNativeAsyncStorage)
        let customer = Customer(name: "Birch Plumbing", email: "birch@example.test")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Water heater", laborRate: 90)
        expect(h.store.upsert(customer) && h.store.upsert(job), "B: two local edits save")
        expectEqual(h.store.rollbackReadiness().pendingChangeCount, 2, "B: sanity: two changes queued")

        let check = await h.store.prepareRollbackReadiness()
        expectEqual(check?.drainOutcome, "completed", "B: the forced push pass completed")
        expect(check?.readiness.isReady == true, "B: after a successful drain: ready (\(check?.readiness.blockers ?? []))")
        expectEqual(check?.readiness.pendingChangeCount, 0, "B: nothing queued")
        expectEqual(check?.readiness.rejectedChangeCount, 0, "B: nothing refused")
        expectEqual(check?.readiness.widgetActionCount, 0, "B: no widget action waiting")
        expectEqual(check?.readiness.photosPendingUploadCount, 0, "B: no photo waiting")
        expectEqual(check?.readiness.migrationJournal, .completed, "B: the journal is complete")
        expectEqual(h.serverRows("customers"), 1, "B: the customer reached the server")
        expectEqual(h.serverRows("jobs"), 1, "B: the job reached the server")
        expect(h.queue.load().isEmpty, "B: the durable queue is empty")
        let summary = check.map { NativeRollbackReadinessCopy.summary($0.readiness) } ?? ""
        expectEqual(summary, "Ready: everything on this device is saved to the cloud.", "B: the Settings line")

        let report = section(h.report(), "rollbackReadiness")
        expectEqual(report["lastCheck"] as? String, "ready", "B: report: ready")
        expectEqual(report["blockers"] as? [String], [], "B: report: no blocker")
        expectEqual(report["migrationJournal"] as? String, "completed", "B: report: the journal state")
        expectEqual(h.report()["reportSchemaVersion"] as? Int, 4, "B: the v4 report")
    }

    // MARK: C. Rejected items: not ready, listed for Retry/Discard

    @MainActor
    static func rejectedItemsAreListedNeverDiscarded() async throws {
        let h = Harness(tag: "rejected")
        defer { h.cleanup() }
        await h.signIn()
        expectEqual(await h.syncBaseline(), [], "C: sanity: the device starts synced")
        let customer = Customer(name: "Cedar HVAC", email: "cedar@example.test")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Private furnace title", laborRate: 85)
        expect(h.store.upsert(customer) && h.store.upsert(job), "C: two local edits save")
        h.server.injectStatusOnce = (method: "POST", table: "jobs", status: 422)

        let check = await h.store.prepareRollbackReadiness()
        let key = "jobs/\(job.id)"
        expectEqual(check?.drainOutcome, "completed", "C: the pass completed (a refusal is not a failure)")
        expectEqual(check?.readiness.blockers, [.rejectedChanges], "C: the refused change keeps it not ready")
        expectEqual(check?.readiness.pendingChangeCount, 0, "C: the queue drained")
        expectEqual(check?.readiness.rejectedChangeCount, 1, "C: with its count")
        expectEqual(check?.readiness.rejectedChangeIDs, [key], "C: listed as needing Retry or Discard")
        expectEqual(h.store.rejectedChanges.map(\.id), [key], "C: Cloud Sync still lists it")
        let summary = check.map { NativeRollbackReadinessCopy.summary($0.readiness) } ?? ""
        expect(summary.contains("1 change the cloud refused needs Retry or Discard above"),
               "C: the Settings line points at Retry or Discard (\(summary))")

        // A second check never discards or re-sends it.
        let again = await h.store.prepareRollbackReadiness()
        expectEqual(again?.readiness.rejectedChangeIDs, [key], "C: a second check keeps it listed")
        let onFile = (try? NativeRejectedChangeStore(fileURL: h.rejectedURL).load(binding: h.binding)) ?? []
        expectEqual(onFile.map(\.key), [key], "C: the rejected store still holds it (never auto-discarded)")
        expectEqual(h.serverRows("jobs"), 0, "C: the check never re-sent the refused change")

        let text = h.reportText()
        let report = section(h.report(), "rollbackReadiness")
        expectEqual(report["rejectedChangeCount"] as? Int, 1, "C: report: the count")
        expectEqual(report["blockers"] as? [String], ["rejected-changes"], "C: report: the blocker code")
        expect(!text.contains(job.id) && !text.contains("Private furnace title"),
               "C: the report never carries the refused change")

        // The owner's Retry, then the check: ready.
        expect(h.store.retryRejectedChange(id: key), "C: Retry queues it again")
        let retried = await h.store.prepareRollbackReadiness()
        expect(retried?.readiness.isReady == true, "C: after Retry reaches the server: ready (\(retried?.readiness.blockers ?? []))")
        expectEqual(h.serverRows("jobs"), 1, "C: the retried change reached the server")
    }

    // MARK: D. Widget/Siri actions

    @MainActor
    static func widgetActionsReplayThroughTheCheck() async throws {
        let h = Harness(tag: "widget")
        defer { h.cleanup() }
        await h.signIn()
        expectEqual(await h.syncBaseline(), [], "D: sanity: the device starts synced")
        let tag = NativeWidgetOwnerTag.make(binding: h.binding)
        h.widgetQueue.value = #"[{"ownerTag":"\#(tag)","id":"d-trip","type":"trip_log","at":"2026-09-24T16:05:00.000Z","date":"2026-09-24","odometerStart":100,"odometerEnd":112}]"#

        let before = h.store.rollbackReadiness()
        expectEqual(before.blockers, [.widgetActionsPending], "D: a queued widget action: not ready")
        expectEqual(before.widgetActionCount, 1, "D: with its count")

        let check = await h.store.prepareRollbackReadiness()
        expect(h.widgetQueue.value == nil, "D: the check replayed the action")
        expect(check?.readiness.isReady == true, "D: then drained it: ready (\(check?.readiness.blockers ?? []))")
        expectEqual(h.serverRows("trips"), 1, "D: the replayed trip reached the server")
    }

    // MARK: E. Photos waiting to upload

    @MainActor
    static func photosUploadThroughTheCheck() async throws {
        let h = Harness(tag: "photos")
        defer { h.cleanup() }
        await h.signIn()
        expectEqual(await h.syncBaseline(), [], "E: sanity: the device starts synced")
        let customer = Customer(name: "Dune Roofing", email: "dune@example.test")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Roof", laborRate: 80)
        expect(h.store.upsert(customer) && h.store.upsert(job), "E: the job saves")
        let photo = h.store.createJobPhoto(jobID: job.id, sourceData: Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]))
        expect(photo != nil, "E: a photo saves on this device")
        expectEqual(h.store.rollbackReadiness().photosPendingUploadCount, 1, "E: its bytes are not uploaded yet")

        h.photos.refuseUploads = true
        let refused = await h.store.prepareRollbackReadiness()
        expectEqual(refused?.readiness.blockers, [.photosPendingUpload], "E: an upload that fails: not ready")
        expectEqual(refused?.readiness.photosPendingUploadCount, 1, "E: with its count")

        h.photos.refuseUploads = false
        let check = await h.store.prepareRollbackReadiness()
        expectEqual(h.photos.uploaded, photo.map { [$0.id] } ?? [], "E: the check uploaded the photo")
        expect(check?.readiness.isReady == true, "E: and pushed its metadata: ready (\(check?.readiness.blockers ?? []))")
    }

    // MARK: F. Fail closed, nothing sent

    @MainActor
    static func failsClosedWithNothingSent() async throws {
        let queued = { (dir: URL) throws -> Void in
            _ = try Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json")).enqueue(
                table: "customers", op: .upsert, recordId: "c-queued",
                payload: .object(["id": .string("c-queued"), "name": .string("Queued")])
            )
        }
        func expectSkipped(_ h: Harness, _ blocker: NativeRollbackReadiness.Blocker, _ label: String) async {
            h.connect()
            let check = await h.store.prepareRollbackReadiness()
            expect(check?.readiness.blockers.contains(blocker) == true,
                   "F \(label): blocked by \(blocker.rawValue) (\(check?.readiness.blockers ?? []))")
            expect(check?.readiness.isReady == false, "F \(label): not ready")
            expectEqual(check?.drainOutcome, "skipped", "F \(label): no push pass ran")
            expectEqual(h.serverRows("customers"), 0, "F \(label): nothing was sent")
            let report = section(h.report(), "rollbackReadiness")
            expect((report["blockers"] as? [String])?.contains(blocker.rawValue) == true, "F \(label): report: the blocker code")
        }

        do {
            let h = Harness(tag: "signed-out", beforeLaunch: queued)
            defer { h.cleanup() }
            await expectSkipped(h, .notVerifiedOwner, "signed out")
        }
        do {
            let h = Harness(tag: "other-gate", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn()
            h.store.testSetAuthenticationGateState(.signedOut)
            await expectSkipped(h, .notVerifiedOwner, "not the signed-in gate")
        }
        do {
            let h = Harness(tag: "no-initial-sync", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn(initialSync: false)
            await expectSkipped(h, .initialSyncIncomplete, "initial sync not complete")
        }
        do {
            let h = Harness(tag: "writes-blocked") { dir in
                try queued(dir)
                try Data("{not a snapshot".utf8).write(to: dir.appendingPathComponent("store.json"))
            }
            defer { h.cleanup() }
            await h.signIn()
            await expectSkipped(h, .writesBlocked, "writes blocked")
        }
        do {
            let h = Harness(tag: "scrub", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn()
            try h.repository.beginAccountScrub(scope: .live)
            await expectSkipped(h, .accountScrubPending, "scrub pending")
        }
        do {
            let h = Harness(tag: "boundary-step", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn()
            try h.repository.beginBoundaryStep(.widgetScrub)
            await expectSkipped(h, .boundaryStepPending, "boundary step pending")
        }
        do {
            let h = Harness(tag: "journal-started", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn()
            _ = try Canonical.MigrationJournal(fileURL: h.journalURL).begin(.reactNativeAsyncStorage)
            await expectSkipped(h, .migrationIncomplete, "journal started")
            expectEqual(h.store.rollbackReadiness().migrationJournal, .started, "F journal started: its state")
        }
        do {
            let h = Harness(tag: "journal-failed", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn()
            let journal = Canonical.MigrationJournal(fileURL: h.journalURL)
            _ = try journal.begin(.reactNativeAsyncStorage)
            try journal.fail(.reactNativeAsyncStorage)
            await expectSkipped(h, .migrationIncomplete, "journal failed")
            expectEqual(h.store.rollbackReadiness().migrationJournal, .failed, "F journal failed: its state")
        }
        do {
            let h = Harness(tag: "journal-unreadable", beforeLaunch: queued)
            defer { h.cleanup() }
            await h.signIn()
            try Data("{not a journal".utf8).write(to: h.journalURL)
            await expectSkipped(h, .migrationUnreadable, "journal unreadable")
        }
    }

    // MARK: G. Unreadable state is never "empty"

    @MainActor
    static func unreadableStateIsNotReady() async throws {
        do {
            let h = Harness(tag: "queue-unreadable")
            defer { h.cleanup() }
            await h.signIn()
            expectEqual(await h.syncBaseline(), [], "G: sanity: the device starts synced")
            try Data("{not a queue".utf8).write(to: h.queueURL)
            let readiness = h.store.rollbackReadiness()
            expectEqual(readiness.blockers, [.pendingChangesUnreadable], "G: an unreadable queue is not an empty one")
        }
        do {
            let h = Harness(tag: "rejected-unreadable")
            defer { h.cleanup() }
            await h.signIn()
            expectEqual(await h.syncBaseline(), [], "G: sanity: the device starts synced")
            try Data("{not a store".utf8).write(to: h.rejectedURL)
            let readiness = h.store.rollbackReadiness()
            expectEqual(readiness.blockers, [.rejectedChangesUnreadable], "G: an unreadable rejected store is not an empty one")
        }
        do {
            // The lock's directory is a regular file: the App Group lock
            // cannot be taken, so the widget queue cannot be checked.
            let notADirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-rollback-lock-blocker-\(UUID().uuidString)")
            try Data("file".utf8).write(to: notADirectory)
            let h = Harness(tag: "widget-unreadable", lockFile: notADirectory.appendingPathComponent("app-group.lock"))
            defer { h.cleanup(); try? FileManager.default.removeItem(at: notADirectory) }
            await h.signIn()
            expectEqual(await h.syncBaseline(), [], "G: sanity: the device starts synced")
            let readiness = h.store.rollbackReadiness()
            expectEqual(readiness.blockers, [.widgetActionsUnreadable], "G: a widget queue that cannot be checked is not an empty one")
        }
    }

    // MARK: H. An account change during the drain voids the result

    @MainActor
    static func accountChangeDuringTheDrain() async throws {
        do {
            let h = Harness(tag: "signout-during")
            defer { h.cleanup() }
            await h.signIn()
            expect(h.store.upsert(Customer(name: "Elm Electric", email: "elm@example.test")), "H: a local edit saves")
            h.connect()
            let check = await h.store.testPrepareRollbackReadiness(afterDrain: { h.store.testApplyCompletedSignOutState() })
            expectEqual(check?.readiness.blockers, [.accountChanged], "H: a sign-out during the drain: account changed only")
            expect(check?.readiness.isReady == false, "H: never ready")
            expectEqual(check?.readiness.pendingChangeCount, 0, "H: it reports nothing about the account now on the device")
            expect(h.store.currentRollbackReadinessCheck == nil, "H: the next account never sees it")
            expectEqual(section(h.report(), "rollbackReadiness")["lastCheck"] as? String, "none",
                        "H: the report shows no check for the next account")
        }
        do {
            let h = Harness(tag: "switch-during")
            defer { h.cleanup() }
            await h.signIn()
            h.connect()
            let other = "99999999-8888-7777-6666-555555555555"
            let check = await h.store.testPrepareRollbackReadiness(afterDrain: {
                h.store.testSeedNativeSignedInOwner(subject: other, binding: String(repeating: "c", count: 64))
            })
            expectEqual(check?.readiness.blockers, [.accountChanged], "H: an owner switch during the drain: account changed")
        }
    }

    // MARK: K. Every other fail-closed flag, table-driven (fix round 1)

    /// Each private flag `rollbackReadiness()` fails closed on, alone, over a
    /// device that is otherwise only waiting on a queued change and a widget
    /// action: the check sends nothing (no request, no replay) and names the
    /// flag's blocker.
    @MainActor
    static func everyFailClosedFlagSendsNothing() async throws {
        let rows: [(flag: AppStore.TestRollbackReadinessFlag, blocker: NativeRollbackReadiness.Blocker, label: String)] = [
            (.accountSwitchInFlight, .accountOperationInFlight, "account switch in flight"),
            (.authenticationOperationInFlight, .accountOperationInFlight, "sign-in, sign-out or deletion in flight"),
            (.identityActivationInFlight, .accountOperationInFlight, "identity check in flight"),
            (.accountScrubBlocked, .accountScrubPending, "scrub blocked"),
            (.accountDeletionPendingWithoutMarker, .accountScrubPending, "deletion pending without its marker"),
            (.accountDeletionRecordUnverified, .accountScrubPending, "deletion record unverified"),
            (.widgetMirrorSuspended, .boundaryStepPending, "widget mirror suspended"),
            (.boundaryCleanupPending, .boundaryStepPending, "boundary cleanup pending"),
            (.legacyMigrationBlocked, .migrationIncomplete, "legacy migration blocked"),
        ]
        expectEqual(Set(rows.map(\.flag)), Set(AppStore.TestRollbackReadinessFlag.allCases), "K: the table covers every flag")
        for row in rows {
            let h = Harness(tag: "flag-\(row.flag.rawValue)")
            defer { h.cleanup() }
            await h.signIn()
            expectEqual(await h.syncBaseline(), [], "K \(row.label): sanity: the device starts synced")
            _ = try h.queue.enqueue(
                table: "customers", op: .upsert, recordId: "c-queued",
                payload: .object(["id": .string("c-queued"), "name": .string("Queued")])
            )
            let tag = NativeWidgetOwnerTag.make(binding: h.binding)
            let action = #"[{"ownerTag":"\#(tag)","id":"k-trip","type":"trip_log","at":"2026-09-24T16:05:00.000Z","date":"2026-09-24","odometerStart":100,"odometerEnd":112}]"#
            h.widgetQueue.value = action
            let open = h.store.rollbackReadiness()
            expectEqual(open.blockers, [.pendingChanges, .widgetActionsPending],
                        "K \(row.label): sanity: without the flag the check would drain")

            h.store.testSetRollbackReadinessFlag(row.flag, true)
            let sent = h.wire.requests
            let check = await h.store.prepareRollbackReadiness()
            expectEqual(check?.readiness.blockers, [row.blocker, .pendingChanges, .widgetActionsPending],
                        "K \(row.label): blocked by \(row.blocker.rawValue)")
            expect(check?.readiness.failsClosed == true, "K \(row.label): fails closed")
            expectEqual(check?.drainOutcome, "skipped", "K \(row.label): no push pass ran")
            expectEqual(h.wire.requests, sent, "K \(row.label): nothing was sent (no request at all)")
            expectEqual(h.widgetQueue.value, action, "K \(row.label): the widget action was not replayed")
            expectEqual(h.queue.load().count, 1, "K \(row.label): the queued change is still queued")
            expectEqual(h.photos.uploaded, [], "K \(row.label): no photo upload")
            let report = section(h.report(), "rollbackReadiness")
            expect((report["blockers"] as? [String])?.contains(row.blocker.rawValue) == true,
                   "K \(row.label): report: the blocker code")
            h.store.testSetRollbackReadinessFlag(row.flag, false)
        }
    }

    // MARK: K2. A second tap while a check runs is refused, with nothing sent

    @MainActor
    static func secondTapIsRefused() async throws {
        let h = Harness(tag: "second-tap")
        defer { h.cleanup() }
        await h.signIn()
        expectEqual(await h.syncBaseline(), [], "K2: sanity: the device starts synced")
        _ = try h.queue.enqueue(
            table: "customers", op: .upsert, recordId: "c-first",
            payload: .object(["id": .string("c-first"), "name": .string("First")])
        )
        let tag = NativeWidgetOwnerTag.make(binding: h.binding)
        let action = #"[{"ownerTag":"\#(tag)","id":"k2-trip","type":"trip_log","at":"2026-09-24T16:05:00.000Z","date":"2026-09-24","odometerStart":100,"odometerEnd":112}]"#
        var second: NativeRollbackReadinessCheck?? = .none
        var sentBefore = 0
        var sentAfter = 0
        var runningDuring = false
        let first = await h.store.testPrepareRollbackReadiness(afterDrain: {
            // While the first check is suspended: a new change and a widget
            // action arrive, and the owner taps again.
            _ = try? h.queue.enqueue(
                table: "customers", op: .upsert, recordId: "c-second",
                payload: .object(["id": .string("c-second"), "name": .string("Second")])
            )
            h.widgetQueue.value = action
            runningDuring = h.store.isRollbackReadinessCheckRunning
            sentBefore = h.wire.requests
            second = .some(await h.store.prepareRollbackReadiness())
            sentAfter = h.wire.requests
        })
        expect(runningDuring, "K2: sanity: the first check is running when the second tap lands")
        expect(second == .some(nil), "K2: the second tap is refused (nil)")
        expectEqual(sentAfter, sentBefore, "K2: the second tap sent nothing (no request at all)")
        expectEqual(h.widgetQueue.value, action, "K2: the second tap replayed nothing")
        expectEqual(h.serverRows("customers"), 1, "K2: only the first check's drain reached the server")
        expectEqual(first?.drainOutcome, "completed", "K2: the first check's drain ran")
        expectEqual(first?.readiness.blockers, [.pendingChanges, .widgetActionsPending],
                    "K2: the first check reports what arrived after its drain")
        expect(!h.store.isRollbackReadinessCheckRunning, "K2: the running flag clears")
        let third = await h.store.prepareRollbackReadiness()
        expect(third?.readiness.isReady == true, "K2: a later tap runs and drains both (\(third?.readiness.blockers ?? []))")
    }

    // MARK: L. Booking and portal link work: a note, never a blocker (fix round 2, R46)

    @MainActor
    static func bookingWorkIsANoteNotABlocker() async throws {
        do {
            let h = Harness(tag: "booking-work")
            defer { h.cleanup() }
            await h.signIn()
            expectEqual(await h.syncBaseline(), [], "L: sanity: the device starts synced")
            let work = h.store.pendingScheduleBookingWorkStore()
            expectEqual(work.fileURL.deletingLastPathComponent().path, h.dir.path,
                        "L: sanity: the file the booking flows stage into, next to store.json")
            try work.stage(.init(
                kind: .portalMirror(customerId: "c-portal-private", token: nil, enabled: false, operationId: "op-private"),
                ownerBinding: h.binding
            ))
            // Another account's item is not this account's (its own boundary
            // scrubs it).
            try work.stage(.init(
                kind: .bookingMirror(token: nil, enabled: false, revision: 2, operationId: "op-other"),
                ownerBinding: String(repeating: "c", count: 64)
            ))

            let before = h.store.rollbackReadiness()
            expectEqual(before.blockers, [], "L: booking work alone does not block")
            expect(before.isReady, "L: booking work alone leaves the check ready")
            expectEqual(before.notes, [.bookingWorkPending], "L: it is reported as a note")
            expectEqual(before.bookingWorkCount, 1, "L: counting only this owner's item")

            let check = await h.store.prepareRollbackReadiness()
            expectEqual(check?.drainOutcome, "completed", "L: the forced push pass ran")
            expect(check?.readiness.isReady == true,
                   "L: with booking work left the check reads Ready (\(check?.readiness.blockers ?? []))")
            expectEqual(check?.readiness.notes, [.bookingWorkPending], "L: the note stays after the drain")
            expectEqual(check?.readiness.bookingWorkCount, 1, "L: with its count")
            expectEqual(work.load().count, 2, "L: the check never removes booking work")
            let summary = check.map { NativeRollbackReadinessCopy.summary($0.readiness) } ?? ""
            expectEqual(summary, NativeRollbackReadinessCopy.ready, "L: the result line is the Ready line")
            let note = check.flatMap { NativeRollbackReadinessCopy.note($0.readiness) } ?? ""
            expect(note.contains("1 booking or portal link update hasn't finished on this device")
                   && note.contains("doesn't change the result"),
                   "L: a neutral note line says what is left (\(note))")
            let report = section(h.report(), "rollbackReadiness")
            expectEqual(Set(report.keys), rollbackReportKeys, "L: the closed rollbackReadiness schema")
            expectEqual(report["lastCheck"] as? String, "ready", "L: report: ready")
            expectEqual(report["blockers"] as? [String], [], "L: report: no blocker")
            expectEqual(report["notes"] as? [String], ["booking-work-pending"], "L: report: the note code")
            expectEqual(report["bookingWorkCount"] as? Int, 1, "L: report: the count")
            let text = h.reportText()
            expect(!text.contains("c-portal-private") && !text.contains("op-private"),
                   "L: the report never carries the work item")

            // A real blocker still decides the result; the note stays beside it.
            h.reach.online = false
            expect(h.store.upsert(Customer(name: "Cedar Roofing", email: "cedar@example.test")),
                   "L: an offline edit saves")
            let blocked = await h.store.prepareRollbackReadiness()
            expectEqual(blocked?.readiness.blockers, [.pendingChanges], "L: the waiting change blocks")
            expectEqual(blocked?.readiness.notes, [.bookingWorkPending], "L: the note is still reported")
            let blockedSummary = blocked.map { NativeRollbackReadinessCopy.summary($0.readiness) } ?? ""
            expect(blockedSummary.hasPrefix("Not ready yet:") && !blockedSummary.contains("booking"),
                   "L: the result line names only the blocker (\(blockedSummary))")
            h.reach.online = true

            // Finished (the flow that staged it removes it): no note.
            try work.remove { $0.ownerBinding == h.binding }
            let finished = await h.store.prepareRollbackReadiness()
            expect(finished?.readiness.isReady == true, "L: ready (\(finished?.readiness.blockers ?? []))")
            expectEqual(finished?.readiness.notes, [], "L: once finished: no note")
            expectEqual(finished?.readiness.bookingWorkCount, 0, "L: nothing of this owner's left")
            expectEqual(finished.flatMap { NativeRollbackReadinessCopy.note($0.readiness) }, nil,
                        "L: and no note line")
        }
        do {
            let h = Harness(tag: "booking-unreadable")
            defer { h.cleanup() }
            await h.signIn()
            expectEqual(await h.syncBaseline(), [], "L: sanity: the device starts synced")
            let url = h.store.pendingScheduleBookingWorkStore().fileURL
            try Data("{not booking work".utf8).write(to: url)
            let torn = h.store.rollbackReadiness()
            expectEqual(torn.blockers, [], "L: an unreadable booking-work file does not block")
            expect(torn.isReady, "L: …so the check is ready")
            expectEqual(torn.notes, [.bookingWorkUnreadable], "L: it is noted as unreadable, never as empty")
            let note = NativeRollbackReadinessCopy.note(torn) ?? ""
            expect(note.contains("booking and portal link updates can't be checked"), "L: its note line (\(note))")
            try Data(#"{"schemaVersion":2,"items":[]}"#.utf8).write(to: url)
            expectEqual(h.store.rollbackReadiness().notes, [.bookingWorkUnreadable],
                        "L: a schema this build does not know is unreadable")
            try h.store.pendingScheduleBookingWorkStore().removeAll()
            expectEqual(h.store.rollbackReadiness().notes, [], "L: an emptied booking-work file is empty: no note")
        }
    }

    // MARK: M. The native run marker (fix round 2, R45a)

    /// The file the Expo rollback build reads to tell one native run from
    /// the next (playbook §5.3 E-1): written by every production launch,
    /// advanced by the next, never touched by an account boundary.
    @MainActor
    static func nativeRunMarker() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-native-run-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.json")
        let markerURL = dir.appendingPathComponent("native-run-marker.json")
        let markers = NativeRunMarkerStore(directory: dir)
        func launch(recordsNativeRun: Bool = true) -> AppStore {
            AppStore(
                fileURL: storeURL,
                seedIfMissing: false,
                secureSettingsStore: hostTestSecureSettingsStore(),
                recordsNativeRun: recordsNativeRun
            )
        }
        func markerKeys() -> Set<String> {
            guard let data = try? Data(contentsOf: markerURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return Set(json.keys)
        }

        expectEqual(markers.fileURL.path, markerURL.path, "M: the marker sits beside store.json")
        _ = launch(recordsNativeRun: false)
        expectEqual(markers.load(), nil, "M: a store that does not record runs (host tests) writes nothing")

        var store = launch()
        expectEqual(markers.load(), NativeRunMarker(schemaVersion: 1, run: 1), "M: the first launch writes run 1")
        expectEqual(markerKeys(), ["run", "schemaVersion"], "M: it holds a run counter and its schema only")
        expect(!FileManager.default.fileExists(atPath: storeURL.path), "M: recording the run writes no snapshot")

        store = launch()
        expectEqual(markers.load()?.run, 2, "M: the next launch advances it")

        // Sign-out (the `.live` scrub) leaves it alone.
        try? NativeOnboardingStore(snapshotURL: storeURL).save(NativeOnboardingDocument(
            accountBinding: String(repeating: "b", count: 64), stage: .done,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        store.testSeedNativeSignedInOwner(subject: "11111111-2222-3333-4444-555555555555",
                                          binding: String(repeating: "b", count: 64))
        expect(store.upsert(Customer(name: "Dune Glass", email: "dune@example.test")), "M: sanity: a signed-in save")
        expect(FileManager.default.fileExists(atPath: storeURL.path), "M: sanity: the workspace is on disk")
        do { try await store.signOut(revokeRemote: false) } catch { expect(false, "M: signOut threw \(error)") }
        expect(!FileManager.default.fileExists(atPath: storeURL.path), "M: sanity: the sign-out removed store.json")
        expectEqual(markers.load()?.run, 2, "M: the sign-out does not touch it")
        try Canonical.SnapshotRepository(primaryURL: storeURL).removeLiveAccountData()
        expectEqual(markers.load()?.run, 2, "M: the `.live` scrub does not touch it")

        // A signed-out launch is a native run too.
        store = launch()
        expectEqual(markers.load()?.run, 3, "M: a signed-out launch advances it")

        // Decision (R45a): `.all` keeps it, so the counter never repeats.
        try Canonical.SnapshotRepository(primaryURL: storeURL).removeAllAccountData()
        expectEqual(markers.load()?.run, 3, "M: the `.all` scrub keeps it")
        store = launch()
        expectEqual(markers.load()?.run, 4, "M: …and the next launch continues from it")

        // A launch whose snapshot cannot be read (writes blocked) still runs.
        try Data("{not a snapshot".utf8).write(to: storeURL)
        store = launch()
        expect(store.rollbackReadiness().blockers.contains(.writesBlocked), "M: sanity: this launch blocked writes")
        expectEqual(markers.load()?.run, 5, "M: a blocked launch advances it")
        expectEqual(try? Data(contentsOf: storeURL), Data("{not a snapshot".utf8), "M: …and leaves the snapshot alone")

        // An unreadable marker starts again at 1 (E-1 compares for inequality).
        try Data("{torn".utf8).write(to: markerURL)
        _ = launch()
        expectEqual(markers.load()?.run, 1, "M: an unreadable marker is replaced, starting at 1")
        _ = store
    }

    // MARK: I. The report before any check

    @MainActor
    static func reportBeforeAnyCheck() {
        let h = Harness(tag: "report")
        defer { h.cleanup() }
        let json = h.report()
        expectEqual(json["reportSchemaVersion"] as? Int, 4, "I: the v4 report")
        let report = section(json, "rollbackReadiness")
        expectEqual(Set(report.keys), rollbackReportKeys, "I: the closed rollbackReadiness schema")
        expectEqual(report["lastCheck"] as? String, "none", "I: no check yet")
        expectEqual(report["lastCheckAge"] as? String, "none", "I: no age")
        expectEqual(report["drainOutcome"] as? String, "none", "I: no drain")
        expectEqual(report["blockers"] as? [String], [], "I: no blockers listed")
        expectEqual(report["pendingChangeCount"] as? Int, 0, "I: zero counts")
        expectEqual(report["bookingWorkCount"] as? Int, 0, "I: zero booking work")
        expectEqual(report["notes"] as? [String], [], "I: no notes listed")
    }

    // MARK: J. Sources

    @MainActor
    static func sources(_ root: URL) {
        func read(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let store = read("native/TradeReadyNative/AppStore.swift")
        let settings = read("native/TradeReadyNative/SettingsView.swift")
        expect(!store.isEmpty && !settings.isEmpty, "J: sources found")
        if let start = store.range(of: "private func prepareRollbackReadiness("),
           let end = store.range(of: "\n    }\n", range: start.upperBound..<store.endIndex) {
            let body = String(store[start.lowerBound..<end.upperBound])
            expect(!body.contains("discardRejectedChange") && !body.contains("rejectedChangeStore.settle")
                   && !body.contains("removeAll"),
                   "J: the check never discards a refused change or clears a store")
            expect(body.contains("accountBoundaryGeneration"), "J: the check compares the account generation after its await")
        } else {
            expect(false, "J: prepareRollbackReadiness was found")
        }
        if let start = settings.range(of: "struct SyncSettings: View {"),
           let end = settings.range(of: "struct PaymentsSettings: View {", range: start.upperBound..<settings.endIndex) {
            let body = String(settings[start.lowerBound..<end.lowerBound])
            expect(body.contains("store.prepareRollbackReadiness()"), "J: Settings › Cloud Sync runs the check")
            expect(body.contains("NativeRollbackReadinessCopy.summary("), "J: …and shows its result line")
            expect(body.contains("NativeRollbackReadinessCopy.note("), "J: …and its note line (fix round 2)")
        } else {
            expect(false, "J: SyncSettings was found")
        }
        // Fix round 2 (R45a): the app's launch (the convenience init the app
        // uses, `TradeReadyNativeApp`) records the run.
        if let start = store.range(of: "    convenience init(\n        analytics: NativeAnalytics"),
           let end = store.range(of: "\n    }\n", range: start.upperBound..<store.endIndex) {
            expect(store[start.lowerBound..<end.upperBound].contains("recordsNativeRun: true"),
                   "J: the production launch records the native run")
        } else {
            expect(false, "J: the production convenience init was found")
        }
        let app = read("native/TradeReadyNative/TradeReadyNativeApp.swift")
        expect(app.contains("AppStore(analytics:"), "J: the app launches through that convenience init")
        let aggregate = read("native/run-all-domain-tests.sh")
        expect(aggregate.contains(#"sh "$ROOT_DIR/native/run-rollback-readiness-tests.sh""#),
               "J: the aggregate runs this suite")
    }
}
