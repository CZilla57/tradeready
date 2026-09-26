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
// upload, and the migration journal is complete. It fails closed, with nothing
// sent, while writes are blocked, a scrub or boundary step is pending, the
// journal is incomplete, the initial sync has not completed, or the device is
// not the verified signed-in owner. An account change while it is suspended
// in the drain voids the result. The support report carries the last result
// as codes and counts only.
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
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: server
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
                allowsWrites: true, loader: server
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
    "lastCheck", "lastCheckAge", "drainOutcome", "blockers", "pendingChangeCount", "rejectedChangeCount",
    "widgetActionCount", "photosPendingUploadCount", "migrationJournal",
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
        } else {
            expect(false, "J: SyncSettings was found")
        }
        let aggregate = read("native/run-all-domain-tests.sh")
        expect(aggregate.contains(#"sh "$ROOT_DIR/native/run-rollback-readiness-tests.sh""#),
               "J: the aggregate runs this suite")
    }
}
