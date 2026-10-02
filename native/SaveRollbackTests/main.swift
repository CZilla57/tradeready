import Foundation

// Phase 12 (12.00b.2-H, P12-008) host tests: a canonical snapshot save that
// fails leaves nothing unsaved in memory. The payment, bulk Mark paid and
// invoice editor commits (and every other in-place commit) used to change the
// live snapshot before `repository.save` and keep the change when the save
// threw: the next unrelated save persisted it without ever queueing it for
// push, and the widget mirror showed it. Each scenario drives the real
// AppStore on a throwaway workspace whose snapshot saves fail on demand, then
// an unrelated save, a relaunch and (money paths) a server pull, and prints
// what it observed (`OBSERVED:` lines) beside its checks. A source pin keeps
// every write of the live snapshot inside `apply` and the two commit helpers,
// and every other `apply(X)` directly after `repository.save(X)`. Fix round 1
// (R41) adds the owner-facing outcomes: a failed Settings save (a plain field
// and the Square link) and a failed bulk Mark paid say so, and a failed reset
// to demo data keeps a blocked source blocked.
// No network. Run with TZ=America/Phoenix (the runner defaults it).

// MARK: - Fakes

final class FakeSDKAdapter: NativeAnalyticsSDKAdapter {
    var events: [String] = []
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws { events.append(event) }
    func identify(_ distinctID: String) throws {}
    func reset() throws {}
    func screen(_ name: String) throws {}
}

final class RecordingCrashAdapter: NativeCrashReportingSDKAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    /// The context (the fingerprint's second entry) of every capture, in order.
    var contexts: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded.removeAll(); lock.unlock() }

    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {}
    func capture(_ report: NativeCrashReport) throws {
        lock.lock()
        recorded.append(report.fingerprint.count == 2 ? report.fingerprint[1] : "<none>")
        lock.unlock()
    }
    func setUser(id: String?) throws {}
}

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

/// The server side of a delta pull: `serverRows` rewrites the local snapshot
/// into the rows the server returns (rows it leaves alone did not change on
/// the server and are not in the delta).
final class ServerDelta: NativeInitialSyncServing, NativeDeltaSyncServing {
    var serverRows: (inout Canonical.Snapshot) -> Void = { _ in }
    func pull(sessionBytes: Data, expectedUserSubject: String, localSnapshot: Canonical.Snapshot) async throws -> Canonical.Snapshot {
        localSnapshot
    }
    func pullDelta(
        sessionBytes: Data, expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot, cursor: Canonical.NativeSyncCursor
    ) async throws -> NativeDeltaPullOutcome {
        var pulled = localSnapshot
        serverRows(&pulled)
        return NativeDeltaPullOutcome(snapshot: pulled, cursor: cursor, failedTables: [], lastDiagnosticCode: nil)
    }
}

// MARK: - Harness

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

/// A characterization line: what the code did, printed on every run.
func observed(_ site: String, _ fact: String) {
    print("OBSERVED: \(site): \(fact)")
}

func hexBinding(_ tag: String) -> String {
    var s = String(tag.lowercased().map { ("0"..."9").contains($0) || ("a"..."f").contains($0) ? $0 : "0" })
    while s.count < 64 { s += "0" }
    return String(s.prefix(64))
}

let ownerSubject = "user-p12-008"
let ownerBinding = hexBinding("b8")

/// Fix round 1 (R41): the owner-facing copy the store's failure outcomes carry.
let settingsNotSavedCopy = "Could not save this change. Your saved settings are shown."
let bulkNotSavedCopy = "Could not mark the invoices paid. Nothing was changed and existing data was preserved."
let readOnlyCopy = "Local data is read-only so its recovery source can be preserved."

/// Lets the main-actor widget mirror refresh (scheduled for after the commit
/// turn) run.
@MainActor
func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<5 { await Task.yield() }
}

/// One scenario's workspace. The snapshot repository keeps its last-known-good
/// backup in a separate directory (`SnapshotRepository(backupURL:)`, an
/// existing injection). Once a snapshot exists, every save writes that backup
/// first, so making the directory read-only fails every snapshot save and
/// nothing else: the mutation queue, the onboarding document and the other
/// stores stay writable, as on a device whose snapshot write alone fails.
@MainActor
final class Workspace {
    let directory: URL
    let backupDirectory: URL
    let suiteName: String
    let defaults: UserDefaults
    let analytics = FakeSDKAdapter()
    let crashAdapter = RecordingCrashAdapter()
    let crash: NativeCrashReporter
    let delta = ServerDelta()

    init(_ tag: String) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-save-rollback-\(tag)-\(UUID().uuidString)", isDirectory: true)
        backupDirectory = directory.appendingPathComponent("SnapshotBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        suiteName = "com.tradeready.save-rollback.tests.\(tag).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        crash = NativeCrashReporter(adapter: crashAdapter)
        try? hostTestSecureSettingsStore().clearAllValues()
    }

    var storeURL: URL { directory.appendingPathComponent("store.json") }
    var queueURL: URL { directory.appendingPathComponent("mutation-queue.json") }
    var lockFile: URL { directory.appendingPathComponent(WidgetAppGroup.lockFileName) }

    func repository() -> Canonical.SnapshotRepository {
        Canonical.SnapshotRepository(
            primaryURL: storeURL,
            backupURL: backupDirectory.appendingPathComponent("store.json.backup")
        )
    }

    /// A launch (a second call on the same workspace is a relaunch).
    func launch() -> AppStore {
        AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            repository: repository(),
            appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                suiteName: suiteName, defaults: defaults, lockFile: lockFile
            ),
            initialSyncService: delta,
            subscriptionService: SubscriptionStub(),
            analytics: NativeAnalyticsTransport(adapter: analytics, diagnostics: { _ in }, catalogViolation: { _ in }),
            crashReporting: crash,
            widgetTimelineReloader: NoopReloader(),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
    }

    /// A launch with the owner signed in, sync credentials and the widget mirror.
    func launchSignedIn() async -> AppStore {
        let store = launch()
        signIn(store)
        store.installWidgetMirror(NativeWidgetMirror(defaults: defaults, lockFile: lockFile, reloader: NoopReloader()))
        await settle()
        return store
    }

    func signIn(_ store: AppStore) {
        store.scheduleBookingTestSeedSignedInOwner(subject: ownerSubject, binding: ownerBinding)
        store.scheduleBookingTestCredentials = NativeSyncCredentials(subject: ownerSubject, sessionBytes: Data())
    }

    func failSnapshotSaves(_ fail: Bool) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: fail ? 0o555 : 0o755], ofItemAtPath: backupDirectory.path
            )
        } catch {
            expect(false, "fixture: the backup directory permissions changed (\(error))")
        }
    }

    /// Fails every write into the workspace directory (the snapshot's primary
    /// file included). For a source whose primary cannot be decoded, where a
    /// save writes no backup first and `failSnapshotSaves` has no effect.
    func failWorkspaceWrites(_ fail: Bool) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: fail ? 0o555 : 0o755], ofItemAtPath: directory.path
            )
        } catch {
            expect(false, "fixture: the workspace directory permissions changed (\(error))")
        }
    }

    /// A push that sent everything: the queue is empty.
    func clearQueue() {
        try? FileManager.default.removeItem(at: queueURL)
    }

    var queue: [Canonical.MutationItem] { Canonical.NativeMutationQueue(fileURL: queueURL).load() }

    func queued(_ table: String, _ id: String) -> Canonical.MutationItem? {
        queue.first { $0.table == table && $0.recordId == id }
    }

    /// The snapshot on disk (what a relaunch loads).
    var disk: Canonical.Snapshot? { (try? repository().load())?.snapshot }

    func diskInvoice(_ id: String) -> Canonical.Invoice? { disk?.payload.invoices?.first { $0.id == id } }

    var mirroredOutstanding: Double? { WidgetSnapshot.load(from: defaults)?.outstandingTotal }

    var moneyEvents: [String] {
        analytics.events.filter { ["payment_recorded", "invoice_paid", "bulk_invoices_marked_paid", "payment_voided"].contains($0) }
    }

    var crashContexts: [String] {
        crash.waitUntilIdle()
        return crashAdapter.contexts
    }

    func clearSignals() {
        crash.waitUntilIdle()
        analytics.events.removeAll()
        crashAdapter.clear()
    }

    func cleanup() {
        crash.waitUntilIdle()
        failWorkspaceWrites(false)
        failSnapshotSaves(false)
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try? hostTestSecureSettingsStore().clearAllValues()
    }
}

func invoice(_ number: String, amount: Double, customer: String = "Rollback Customer") -> Invoice {
    var value = Invoice()
    value.customer = customer
    value.number = number
    value.amount = amount
    return value
}

func payment(_ amount: Double, method: String = "Card") -> Payment {
    var value = Payment()
    value.amount = amount
    value.method = method
    return value
}

/// The unrelated save every scenario makes after the failed one.
@MainActor
func unrelatedSave(_ store: AppStore, _ site: String) {
    var customer = Customer()
    customer.name = "Unrelated Customer \(site)"
    expect(store.upsert(customer), "\(site): sanity: the unrelated save succeeds")
}

// MARK: - Tests

@main
struct SaveRollbackTests {
    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")
        seamSanity()
        await recordedPayment()
        await bulkMarkPaid()
        await invoiceEdit()
        await invoiceCreate()
        await settingsEdit()
        await squareLinkSave()
        await autoEmailClear()
        await legacyInvoiceExpenseAPIs()
        onboardingCommits()
        demoReset()
        demoResetWhileBlocked()
        await squareHeal()
        await pullCommit()
        failureNoticeSources(root: root)
        pinScopes()
        pinSaveFirstProbe()
        sourcePin(root: root)

        print("save-rollback tests: \(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }

    // MARK: 0. The seam fails the snapshot save and nothing else

    @MainActor
    static func seamSanity() {
        let w = Workspace("seam")
        defer { w.cleanup() }
        let store = w.launch()
        unrelatedSave(store, "seam")
        w.failSnapshotSaves(true)
        do {
            try w.repository().save(Canonical.Snapshot(payload: .init()))
            expect(false, "seam: a snapshot save fails while the backup directory is read-only")
        } catch {
            expect(true, "seam: a snapshot save fails while the backup directory is read-only")
        }
        do {
            try Canonical.NativeMutationQueue(fileURL: w.queueURL).enqueue(
                table: "jobs", op: .upsert, recordId: "seam-probe", payload: .object(["id": .string("seam-probe")])
            )
            expect(true, "seam: the mutation queue stays writable")
        } catch {
            expect(false, "seam: the mutation queue stays writable (\(error))")
        }
        w.failSnapshotSaves(false)
    }

    // MARK: 1. A recorded payment (commitInvoicePayment)

    @MainActor
    static func recordedPayment() async {
        let site = "payment"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        let target = invoice("INV-8001", amount: 80)
        store.upsert(target)
        await settle()
        expectEqual(w.mirroredOutstanding, 80, "\(site): sanity: the widget shows the open balance")
        w.clearQueue()
        w.clearSignals()

        w.failSnapshotSaves(true)
        let paid = payment(80)
        let failed = store.recordPayment(invoiceID: target.id, payment: paid)
        await settle()
        w.failSnapshotSaves(false)

        // What the user sees.
        if case .success = failed { expect(false, "\(site): the payment reports failure") }
        expect(store.migrationMessage?.hasPrefix("Could not record the payment") == true, "\(site): the store reports the error")
        let shown = store.invoices.first { $0.id == target.id }
        expect(shown?.isPaid == false && shown?.balance == 80 && shown?.payments.isEmpty == true,
               "\(site): the invoice still shows unpaid, balance 80, no payment")
        expectEqual(w.mirroredOutstanding, 80, "\(site): the widget mirror still shows the open balance")
        observed(site, "after the failed save the widget mirror shows outstanding \(w.mirroredOutstanding.map { "\($0)" } ?? "nil")")
        expectEqual(w.moneyEvents, [], "\(site): no payment_recorded or invoice_paid for a failed save")
        expectEqual(w.crashContexts, ["invoicePayment"], "\(site): the failed save reports invoicePayment exactly once")

        // The next unrelated save, then a relaunch.
        unrelatedSave(store, site)
        let shownAfter = store.invoices.first { $0.id == target.id }
        observed(site, "after an unrelated save the screen shows paid=\(shownAfter?.isPaid ?? false), balance \(shownAfter?.balance ?? -1)")
        expect(shownAfter?.isPaid == false, "\(site): the unrelated save does not show the unsaved payment")
        let onDisk = w.diskInvoice(target.id)
        let persisted = onDisk?.payments?.contains { $0.id == paid.id } ?? false
        let queued = w.queued("invoices", target.id) != nil
        observed(site, "after an unrelated save the payment is on disk=\(persisted), queued=\(queued), paid on disk=\(onDisk?.paid ?? false)")
        expect(!persisted, "\(site): the failed payment is not persisted by the next unrelated save")
        expect(!queued, "\(site): nothing is queued for the failed payment")

        let relaunched = w.launch()
        let afterRelaunch = relaunched.invoices.first { $0.id == target.id }
        observed(site, "after relaunch paid=\(afterRelaunch?.isPaid ?? false), payments=\(afterRelaunch?.payments.count ?? -1)")
        expect(afterRelaunch?.isPaid == false && afterRelaunch?.payments.isEmpty == true,
               "\(site): after a relaunch the invoice is unpaid with no payment")

        // Server pulls: the server never received the payment.
        w.signIn(relaunched)
        w.delta.serverRows = { _ in }
        _ = await relaunched.testPullDeltaIfPossible()
        let unchangedRow = relaunched.invoices.first { $0.id == target.id }
        observed(site, "pull with the server row unchanged: local paid=\(unchangedRow?.isPaid ?? false); the server copy is unpaid")
        expect(unchangedRow?.isPaid == false, "\(site): a pull that leaves the row alone agrees with the server (unpaid)")
        w.delta.serverRows = { snapshot in
            snapshot.payload.invoices = snapshot.payload.invoices?.map { record in
                guard record.id == target.id else { return record }
                var server = record
                server.payments = server.payments?.filter { $0.id != paid.id }
                server.paid = false
                server.paidAt = nil
                server.desc = "Edited on another device"
                return server
            }
        }
        let pulled = await relaunched.testPullDeltaIfPossible()
        expectEqual(pulled.state, .completed, "\(site): sanity: the pull completes")
        let changedRow = relaunched.invoices.first { $0.id == target.id }
        observed(site, "pull with the server row changed: local paid=\(changedRow?.isPaid ?? false), payments=\(changedRow?.payments.count ?? -1); the server copy is unpaid")
        expect(changedRow?.isPaid == false && changedRow?.description == "Edited on another device",
               "\(site): the pull and the local copy agree (unpaid)")

        // A retry once saves work records it, queues it and tracks it once.
        w.clearSignals()
        if case .failure = relaunched.recordPayment(invoiceID: target.id, payment: paid) {
            expect(false, "\(site): the retried payment is recorded")
        }
        expect(w.queued("invoices", target.id) != nil, "\(site): the retried payment is queued")
        expectEqual(w.moneyEvents, ["payment_recorded", "invoice_paid"], "\(site): the retry tracks the payment once")
    }

    // MARK: 2. Bulk Mark paid (commitBulkSettleInvoices)

    @MainActor
    static func bulkMarkPaid() async {
        let site = "bulk"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        let first = invoice("INV-8101", amount: 120)
        let second = invoice("INV-8102", amount: 45.5)
        store.upsert(first)
        store.upsert(second)
        var job = Job()
        job.customerName = "Rollback Customer"
        job.title = "Invoiced job"
        job.status = .invoiced
        job.invoiceId = first.id
        expect(store.upsert(job), "\(site): sanity: the invoiced job is saved")
        await settle()
        expectEqual(w.mirroredOutstanding, 165.5, "\(site): sanity: the widget shows both open balances")
        w.clearQueue()
        w.clearSignals()

        w.failSnapshotSaves(true)
        let result: AppStore.BulkSettleResult = store.commitBulkSettleInvoices(ids: [first.id, second.id])
        await settle()
        w.failSnapshotSaves(false)

        expect(result.settled.isEmpty, "\(site): nothing is reported settled")
        // Fix round 1 (R41 carry-forward): the result carries the failure the
        // Invoices list shows, so a failed save no longer reads as "already paid".
        observed(site, "the failed run reports failure=\(result.failure ?? "nil")")
        expectEqual(result.failure, bulkNotSavedCopy, "\(site): the result reports the failed save")
        expect(store.migrationMessage?.hasPrefix("Could not mark the invoices paid") == true, "\(site): the store reports the error")
        expect(store.invoices.filter { [first.id, second.id].contains($0.id) }.allSatisfy { !$0.isPaid },
               "\(site): both invoices still show unpaid")
        expectEqual(store.jobs.first { $0.id == job.id }?.status, .invoiced, "\(site): the job still shows invoiced")
        expectEqual(w.mirroredOutstanding, 165.5, "\(site): the widget mirror still shows both open balances")
        observed(site, "after the failed save the widget mirror shows outstanding \(w.mirroredOutstanding.map { "\($0)" } ?? "nil")")
        expectEqual(w.moneyEvents, [], "\(site): no invoice_paid or bulk_invoices_marked_paid for a failed save")
        expectEqual(w.crashContexts, ["invoicePayment"], "\(site): the failed save reports invoicePayment exactly once")

        unrelatedSave(store, site)
        let paidOnDisk = [first.id, second.id].filter { w.diskInvoice($0)?.paid == true }.count
        let jobOnDisk = w.disk?.payload.jobs?.first { $0.id == job.id }?.status
        let queuedCount = [("invoices", first.id), ("invoices", second.id), ("jobs", job.id)]
            .filter { w.queued($0.0, $0.1) != nil }.count
        observed(site, "after an unrelated save \(paidOnDisk) of 2 invoices are paid on disk, job on disk=\(jobOnDisk ?? "nil"), queued records=\(queuedCount)")
        expectEqual(paidOnDisk, 0, "\(site): the failed settlement is not persisted by the next unrelated save")
        expectEqual(jobOnDisk, "invoiced", "\(site): the job's unsaved advance is not persisted")
        expectEqual(queuedCount, 0, "\(site): nothing is queued for the failed settlement")

        let relaunched = w.launch()
        expect(relaunched.invoices.filter { [first.id, second.id].contains($0.id) }.allSatisfy { !$0.isPaid },
               "\(site): after a relaunch both invoices are unpaid")
        expectEqual(relaunched.jobs.first { $0.id == job.id }?.status, .invoiced, "\(site): after a relaunch the job is invoiced")

        w.signIn(relaunched)
        w.delta.serverRows = { snapshot in
            snapshot.payload.invoices = snapshot.payload.invoices?.map { record in
                guard record.id == first.id else { return record }
                var server = record
                server.payments = []
                server.paid = false
                server.paidAt = nil
                server.desc = "Edited on another device"
                return server
            }
        }
        _ = await relaunched.testPullDeltaIfPossible()
        let firstAfterPull = relaunched.invoices.first { $0.id == first.id }
        let secondAfterPull = relaunched.invoices.first { $0.id == second.id }
        observed(site, "pull with one server row changed: changed row paid=\(firstAfterPull?.isPaid ?? false), unchanged row paid=\(secondAfterPull?.isPaid ?? false) (server: both unpaid)")
        expect(firstAfterPull?.isPaid == false && secondAfterPull?.isPaid == false,
               "\(site): after a pull the local copy agrees with the server (both unpaid)")

        // With saves working the run settles both and reports no failure; a run
        // over invoices that are already paid is a skip, not a failure.
        let settledRun: AppStore.BulkSettleResult = relaunched.commitBulkSettleInvoices(ids: [first.id, second.id])
        expect(settledRun.settled.count == 2 && settledRun.failure == nil,
               "\(site): a later run settles both and reports no failure")
        let paidRun: AppStore.BulkSettleResult = relaunched.commitBulkSettleInvoices(ids: [first.id, second.id])
        expect(paidRun.settled.isEmpty && paidRun.skipped == 2 && paidRun.failure == nil,
               "\(site): a run over paid invoices skips them and reports no failure")
    }

    // MARK: 3. The invoice editor, edit (performInvoiceEdit)

    @MainActor
    static func invoiceEdit() async {
        let site = "invoice-edit"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        let target = invoice("INV-8201", amount: 100)
        store.upsert(target)
        if case .failure = store.recordPayment(invoiceID: target.id, payment: payment(50)) {
            expect(false, "\(site): sanity: the part payment is recorded")
        }
        guard let opened = store.invoices.first(where: { $0.id == target.id }) else {
            expect(false, "\(site): sanity: the invoice is listed")
            return
        }
        w.clearQueue()
        w.clearSignals()

        // Lowering the amount to the amount paid settles the invoice.
        let draft = NativeInvoiceDraft(
            customer: opened.customer, customerId: opened.customerId, number: opened.number, amount: 50,
            due: NativeInvoiceEditing.dayString(opened.due), email: opened.email, phone: opened.phone,
            description: opened.description
        )
        w.failSnapshotSaves(true)
        let failed = store.commitInvoiceEdit(id: target.id, opened: opened, draft: draft)
        await settle()
        w.failSnapshotSaves(false)

        expectEqual(failed, .failure(.persistenceUnavailable), "\(site): the edit reports failure")
        let shown = store.invoices.first { $0.id == target.id }
        expect(shown?.amount == 100 && shown?.isPaid == false, "\(site): the invoice still shows 100, part paid")
        expectEqual(w.mirroredOutstanding, 50, "\(site): the widget mirror still shows the 50 balance")

        unrelatedSave(store, site)
        let onDisk = w.diskInvoice(target.id)
        let queued = w.queued("invoices", target.id) != nil
        observed(site, "after an unrelated save the amount on disk=\(onDisk.map { "\($0.amount)" } ?? "nil"), paid on disk=\(onDisk?.paid ?? false), queued=\(queued)")
        expectEqual(onDisk?.amount, 100, "\(site): the failed edit is not persisted by the next unrelated save")
        expect(onDisk?.paid == false, "\(site): the stored paid flag is unchanged")
        expect(!queued, "\(site): nothing is queued for the failed edit")

        let relaunched = w.launch()
        let afterRelaunch = relaunched.invoices.first { $0.id == target.id }
        expect(afterRelaunch?.amount == 100 && afterRelaunch?.isPaid == false, "\(site): after a relaunch the invoice is 100, part paid")
    }

    // MARK: 4. The invoice editor, create (performInvoiceEdit)

    @MainActor
    static func invoiceCreate() async {
        let site = "invoice-create"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        unrelatedSave(store, "\(site)-setup")
        w.clearQueue()
        let draft = NativeInvoiceDraft(
            customer: "Create Customer", customerId: "", number: "", amount: 240,
            due: "2026-10-15", email: "", phone: "", description: "Created while saves fail"
        )

        // The owner taps Save while saves fail, then taps Save again once they work.
        w.failSnapshotSaves(true)
        let failed = store.commitInvoiceEdit(id: nil, opened: nil, draft: draft)
        await settle()
        w.failSnapshotSaves(false)
        expectEqual(failed, .failure(.persistenceUnavailable), "\(site): the create reports failure")
        expect(!store.invoices.contains { $0.customer == "Create Customer" }, "\(site): the list shows no new invoice")
        expectEqual(w.mirroredOutstanding, 0, "\(site): the widget mirror shows no new balance")

        let retried = store.commitInvoiceEdit(id: nil, opened: nil, draft: draft)
        guard case .success(let created) = retried else {
            expect(false, "\(site): the retried create succeeds")
            return
        }
        let listed = store.invoices.filter { $0.customer == "Create Customer" }
        observed(site, "after the retry the list shows \(listed.count) invoice(s) numbered \(listed.map(\.number)); queued=\(w.queue.filter { $0.table == "invoices" }.count)")
        expectEqual(listed.map(\.id), [created.id], "\(site): the retry creates exactly one invoice")
        expectEqual(w.queue.filter { $0.table == "invoices" }.map(\.recordId), [created.id], "\(site): only the saved invoice is queued")

        // A failed create followed by an unrelated save and a relaunch.
        let w2 = Workspace("\(site)-unrelated")
        defer { w2.cleanup() }
        let second = w2.launch()
        w2.signIn(second)
        unrelatedSave(second, "\(site)-setup-2")
        w2.clearQueue()
        w2.failSnapshotSaves(true)
        _ = second.commitInvoiceEdit(id: nil, opened: nil, draft: draft)
        w2.failSnapshotSaves(false)
        unrelatedSave(second, site)
        let onDisk = w2.disk?.payload.invoices?.filter { $0.customer == "Create Customer" } ?? []
        observed(site, "after an unrelated save \(onDisk.count) failed invoice(s) on disk, queued=\(w2.queue.filter { $0.table == "invoices" }.count)")
        expect(onDisk.isEmpty, "\(site): the failed create is not persisted by the next unrelated save")
        expect(w2.queue.allSatisfy { $0.table != "invoices" }, "\(site): nothing is queued for the failed create")
        expect(!w2.launch().invoices.contains { $0.customer == "Create Customer" }, "\(site): after a relaunch there is no such invoice")
    }

    // MARK: 5. A Settings edit (mergeSettingsAndSave)

    @MainActor
    static func settingsEdit() async {
        let site = "settings"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        store.settings.businessName = "Saved Name"
        expectEqual(w.disk?.payload.settings?.businessName, "Saved Name", "\(site): sanity: a settings edit saves")
        expectEqual(store.settingsSaveFailure, nil, "\(site): sanity: a saved edit reports no failure")
        w.clearQueue()

        w.failSnapshotSaves(true)
        store.settings.businessName = "Unsaved Name"
        w.failSnapshotSaves(false)
        let queuedName = w.queued("settings", "settings").flatMap { item -> String? in
            if case let .object(fields) = item.payload, case let .string(name)? = fields["businessName"] { return name }
            return nil
        }
        observed(site, "after the failed save the screen shows '\(store.settings.businessName)', queued name=\(queuedName ?? "nil")")
        expectEqual(store.settings.businessName, "Saved Name", "\(site): the screen goes back to the saved settings")
        expect(store.migrationMessage?.hasPrefix("Could not update settings") == true, "\(site): the store reports the error")
        // Fix round 1 (R41, Minor 2): the Settings screens show the failure.
        observed(site, "after the failed save the Settings failure is '\(store.settingsSaveFailure ?? "nil")'")
        expectEqual(store.settingsSaveFailure, settingsNotSavedCopy, "\(site): the Settings screens say the edit was not saved")
        expectEqual(queuedName, nil, "\(site): nothing is queued for the failed edit")

        unrelatedSave(store, site)
        let onDisk = w.disk?.payload.settings?.businessName
        observed(site, "after an unrelated save the name on disk is '\(onDisk ?? "nil")'")
        expectEqual(onDisk, "Saved Name", "\(site): the failed edit is not persisted by the next unrelated save")
        expectEqual(w.launch().settings.businessName, "Saved Name", "\(site): after a relaunch the saved name shows")

        // Once saves work, the next edit saves and queues as before.
        store.settings.businessName = "Later Name"
        expectEqual(w.disk?.payload.settings?.businessName, "Later Name", "\(site): a later edit saves")
        expect(w.queued("settings", "settings") != nil, "\(site): a later edit is queued")
        expectEqual(store.settingsSaveFailure, nil, "\(site): a later saved edit clears the failure")
    }

    // MARK: 5b. The Square link (setPaymentProviderKey), fix round 1 (R41, Minor 2)

    /// The Payments page said "Square link saved." whenever the link passed
    /// validation, even when the save failed and the screen went back to the
    /// saved link. The setter now returns what happened to the save.
    @MainActor
    static func squareLinkSave() async {
        let site = "square-save"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        let saved = "https://square.link/u/p12saved"
        let unsaved = "https://square.link/u/p12unsaved"
        let first: AppStore.ProviderKeySaveOutcome = store.setPaymentProviderKey(saved, for: "square")
        expectEqual(first, .saved(saved), "\(site): sanity: a Square link saves")
        expectEqual(w.disk?.payload.settings?.providerKeys["square"], saved, "\(site): sanity: the link is on disk")
        w.clearQueue()

        w.failSnapshotSaves(true)
        let outcome: AppStore.ProviderKeySaveOutcome = store.setPaymentProviderKey(unsaved, for: "square")
        w.failSnapshotSaves(false)
        observed(site, "a failed save returns \(outcome); the screen shows '\(store.settings.providerKey(for: "square"))'")
        expectEqual(outcome, .notSaved(settingsNotSavedCopy), "\(site): a failed save is reported as not saved")
        expectEqual(store.settings.providerKey(for: "square"), saved, "\(site): the screen shows the saved link")
        expectEqual(store.settingsSaveFailure, settingsNotSavedCopy, "\(site): the Payments page shows the failure")
        expect(w.queued("settings", "settings") == nil, "\(site): nothing is queued for the failed save")
        unrelatedSave(store, site)
        expectEqual(w.disk?.payload.settings?.providerKeys["square"], saved,
                    "\(site): the unsaved link is not persisted by the next unrelated save")

        // A refused token is a validation result, not a failed save.
        let token: AppStore.ProviderKeySaveOutcome = store.setPaymentProviderKey("EAAAp12token", for: "square")
        expectEqual(token, .rejected(NativeSquareProviderKeyPolicy.rejectionMessage), "\(site): a pasted token is rejected")

        let retried: AppStore.ProviderKeySaveOutcome = store.setPaymentProviderKey(unsaved, for: "square")
        expectEqual(retried, .saved(unsaved), "\(site): once saves work the link saves")
        expectEqual(store.settingsSaveFailure, nil, "\(site): a saved link clears the failure")
        expectEqual(w.disk?.payload.settings?.providerKeys["square"], unsaved, "\(site): the saved link is on disk")
        expect(w.queued("settings", "settings") != nil, "\(site): the saved link is queued")
    }

    // MARK: 6. Clearing an automatic send (clearInvoiceAutoEmailRequest)

    @MainActor
    static func autoEmailClear() async {
        let site = "auto-email"
        let w = Workspace(site)
        defer { w.cleanup() }
        var store = w.launch()
        let target = invoice("INV-8301", amount: 60)
        store.upsert(target)
        // Fixture: an automatic send is pending (set on the stored record).
        if var fixture = w.disk, let index = fixture.payload.invoices?.firstIndex(where: { $0.id == target.id }) {
            fixture.payload.invoices?[index].autoEmailRequestedAt = "2026-09-26T12:00:00.000Z"
            do { try w.repository().save(fixture) } catch { expect(false, "\(site): fixture saved (\(error))") }
        }
        store = await w.launchSignedIn()
        w.clearQueue()

        w.failSnapshotSaves(true)
        store.clearInvoiceAutoEmailRequest(invoiceID: target.id)
        w.failSnapshotSaves(false)
        let queued = w.queued("invoices", target.id) != nil
        observed(site, "after the failed save queued=\(queued)")
        expect(!queued, "\(site): nothing is queued for the failed clear")

        unrelatedSave(store, site)
        let onDisk = w.diskInvoice(target.id)?.autoEmailRequestedAt
        observed(site, "after an unrelated save the request on disk is \(onDisk ?? "nil")")
        expectEqual(onDisk, "2026-09-26T12:00:00.000Z", "\(site): the failed clear is not persisted by the next unrelated save")
        _ = w.launch()
        expect(w.queued("invoices", target.id) == nil, "\(site): after a relaunch nothing is queued for the failed clear")

        // Once saves work, the clear saves and is queued.
        store.clearInvoiceAutoEmailRequest(invoiceID: target.id)
        expect(w.diskInvoice(target.id)?.autoEmailRequestedAt == nil && w.queued("invoices", target.id) != nil,
               "\(site): a later clear saves and is queued")
    }

    // MARK: 7. The older invoice/expense store calls (upsert, deleteExpense)

    @MainActor
    static func legacyInvoiceExpenseAPIs() async {
        let site = "store-calls"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        var target = invoice("INV-8401", amount: 70)
        store.upsert(target)
        var expense = Expense()
        expense.merchant = "Saved Supplier"
        expense.amount = 12
        store.upsert(expense)
        var doomed = Expense()
        doomed.merchant = "Kept Supplier"
        doomed.amount = 9
        store.upsert(doomed)
        w.clearQueue()

        w.failSnapshotSaves(true)
        target.amount = 75
        store.upsert(target)
        expense.amount = 15
        store.upsert(expense)
        store.deleteExpense(id: doomed.id)
        w.failSnapshotSaves(false)
        let queuedIDs = w.queue.map { "\($0.table)/\($0.recordId)" }
        observed(site, "after the failed saves the screens show invoice \(store.invoices.first { $0.id == target.id }?.amount ?? -1), expense \(store.expenses.first { $0.id == expense.id }?.amount ?? -1), deleted expense listed=\(store.expenses.contains { $0.id == doomed.id }); queued=\(queuedIDs)")
        expectEqual(store.invoices.first { $0.id == target.id }?.amount, 70, "\(site): the invoice still shows the saved amount")
        expectEqual(store.expenses.first { $0.id == expense.id }?.amount, 12, "\(site): the expense still shows the saved amount")
        expect(store.expenses.contains { $0.id == doomed.id }, "\(site): the expense that could not be deleted is still listed")
        expectEqual(queuedIDs, [], "\(site): nothing is queued for the failed saves")

        unrelatedSave(store, site)
        let disk = w.disk?.payload
        observed(site, "after an unrelated save the disk holds invoice \(disk?.invoices?.first { $0.id == target.id }.map { "\($0.amount)" } ?? "nil"), expense \(disk?.expenses?.first { $0.id == expense.id }.map { "\($0.amount)" } ?? "nil"), deleted expense present=\(disk?.expenses?.contains { $0.id == doomed.id } ?? false)")
        expectEqual(disk?.invoices?.first { $0.id == target.id }?.amount, 70, "\(site): the failed invoice edit is not persisted")
        expectEqual(disk?.expenses?.first { $0.id == expense.id }?.amount, 12, "\(site): the failed expense edit is not persisted")
        expect(disk?.expenses?.contains { $0.id == doomed.id } == true, "\(site): the failed delete is not persisted")
        let relaunched = w.launch()
        expect(relaunched.invoices.first { $0.id == target.id }?.amount == 70
                   && relaunched.expenses.first { $0.id == expense.id }?.amount == 12
                   && relaunched.expenses.contains { $0.id == doomed.id },
               "\(site): after a relaunch the saved invoice, expense and undeleted expense show")
        expect(w.queue.allSatisfy { $0.table == "customers" }, "\(site): after a relaunch only the unrelated save is queued")
    }

    // MARK: 8. Onboarding (commitOnboardingSettings, commitStartingPoint)

    @MainActor
    static func onboardingCommits() {
        let site = "onboarding"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = w.launch()
        unrelatedSave(store, "\(site)-setup")
        store.scheduleBookingTestSeedSignedInOwner(subject: ownerSubject, binding: ownerBinding)
        let onboarding = NativeOnboardingStore(snapshotURL: w.storeURL)
        let draft = NativeOnboardingDocument.Draft(businessName: "Onboarded Co", contactName: "Riley", trade: .electrical, step: 1)
        func setStage(_ stage: NativeOnboardingDocument.Stage) {
            do { try onboarding.save(NativeOnboardingDocument(accountBinding: ownerBinding, stage: stage, draft: draft)) }
            catch { expect(false, "\(site): fixture: the onboarding document is saved (\(error))") }
        }

        // Personalization.
        setStage(.drafting)
        w.failSnapshotSaves(true)
        do {
            try store.completeOnboardingPersonalization(draft)
            expect(false, "\(site): personalization reports failure")
        } catch {
            expect(true, "\(site): personalization reports failure")
        }
        w.failSnapshotSaves(false)
        unrelatedSave(store, "\(site)-personalization")
        let savedName = w.disk?.payload.settings?.businessName
        observed(site, "after a failed personalization and an unrelated save the name on disk is '\(savedName ?? "nil")'")
        expect(savedName != "Onboarded Co", "\(site): the failed personalization is not persisted by the next unrelated save")

        // Starting point with sample data.
        setStage(.personalized)
        w.failSnapshotSaves(true)
        do {
            try store.completeStartingPoint(.sample)
            expect(false, "\(site): the sample starting point reports failure")
        } catch {
            expect(true, "\(site): the sample starting point reports failure")
        }
        w.failSnapshotSaves(false)
        expect(!store.customers.contains { $0.id.hasPrefix("native-sample-v1-") }, "\(site): the screens show no sample data")
        unrelatedSave(store, "\(site)-sample")
        let samplesOnDisk = w.disk?.payload.customers?.filter { $0.id.hasPrefix("native-sample-v1-") }.count ?? 0
        observed(site, "after a failed sample start and an unrelated save \(samplesOnDisk) sample customer(s) on disk")
        expectEqual(samplesOnDisk, 0, "\(site): the failed sample start is not persisted by the next unrelated save")

        // Starting fresh over sample data: the removal must not be persisted either.
        setStage(.personalized)
        do { try store.completeStartingPoint(.sample) } catch { expect(false, "\(site): sanity: the sample start saves (\(error))") }
        setStage(.personalized)
        w.failSnapshotSaves(true)
        do {
            try store.completeStartingPoint(.fresh)
            expect(false, "\(site): the fresh starting point reports failure")
        } catch {
            expect(true, "\(site): the fresh starting point reports failure")
        }
        w.failSnapshotSaves(false)
        unrelatedSave(store, "\(site)-fresh")
        let samplesKept = w.disk?.payload.customers?.filter { $0.id.hasPrefix("native-sample-v1-") }.count ?? 0
        observed(site, "after a failed fresh start and an unrelated save \(samplesKept) sample customer(s) on disk")
        expectEqual(samplesKept, 6, "\(site): the failed fresh start's removal is not persisted by the next unrelated save")
        let relaunched = w.launch()
        expect(relaunched.settings.businessName != "Onboarded Co", "\(site): after a relaunch the failed personalization is absent")
        expectEqual(relaunched.customers.filter { $0.id.hasPrefix("native-sample-v1-") }.count, 6,
                    "\(site): after a relaunch the saved sample customer shows")
        expect(w.queue.allSatisfy { $0.table == "customers" && !$0.recordId.hasPrefix("native-sample-v1-") },
               "\(site): nothing but the unrelated saves is queued")
    }

    // MARK: 9. Reset to demo data (seedDemoData)

    @MainActor
    static func demoReset() {
        let site = "demo-reset"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = w.launch()
        unrelatedSave(store, "\(site)-setup")
        w.failSnapshotSaves(true)
        store.resetDemoData()
        w.failSnapshotSaves(false)
        observed(site, "after the failed reset the screens show \(store.customers.count) customer(s)")
        expect(store.customers.map(\.name) == ["Unrelated Customer \(site)-setup"], "\(site): the screens keep the saved data")
        unrelatedSave(store, site)
        let names = Set(w.disk?.payload.customers?.map(\.name) ?? [])
        observed(site, "after an unrelated save the disk holds \(names.sorted())")
        expect(!names.contains("Tom Nguyen"), "\(site): the failed reset is not persisted by the next unrelated save")
        expect(!w.launch().customers.contains { $0.name == "Tom Nguyen" }, "\(site): after a relaunch no demo data shows")
    }

    // MARK: 9a. Reset to demo data over a blocked source, fix round 1 (R41, Minor 3)

    /// `resetDemoData` may replace a source the launch refused to overwrite
    /// (an unreadable file, or data from a newer app version), but it cleared
    /// the write block before its save: a failed reset left the blocked
    /// contents in memory with writes allowed, and the next save overwrote the
    /// recovery source. The block now lifts only once the demo data is saved.
    @MainActor
    static func demoResetWhileBlocked() {
        for source in ["unreadable-snapshot", "newer-schema"] {
            let site = "demo-reset-blocked/\(source)"
            let w = Workspace("demo-reset-blocked-\(source)")
            defer { w.cleanup() }
            let sourceBytes: Data
            if source == "unreadable-snapshot" {
                sourceBytes = Data("{ not a snapshot".utf8)
            } else {
                let future = Canonical.Snapshot(
                    schemaVersion: Canonical.Snapshot.currentSchemaVersion + 1,
                    payload: .init(unknownFields: ["futurePayload": .string("retain")])
                )
                sourceBytes = (try? Canonical.SnapshotCodec.encode(future)) ?? Data()
            }
            do { try sourceBytes.write(to: w.storeURL, options: .atomic) } catch {
                expect(false, "\(site): fixture written (\(error))")
            }
            let store = w.launch()
            let blockedAt = store.supportReport().launchMigration
            expectEqual(blockedAt.persistenceBlockReason.value, source, "\(site): sanity: the launch blocks writes")

            // The reset's save fails. An undecodable primary gets no backup
            // first, so its save is failed at the workspace directory.
            func failSave(_ fail: Bool) {
                if source == "unreadable-snapshot" { w.failWorkspaceWrites(fail) } else { w.failSnapshotSaves(fail) }
            }
            failSave(true)
            store.resetDemoData()
            failSave(false)
            let resetMessage = store.migrationMessage

            let afterReset = store.supportReport().launchMigration
            var unrelated = Customer()
            unrelated.name = "Unrelated Customer \(source)"
            let unrelatedSaved = store.upsert(unrelated)
            let onDisk = try? Data(contentsOf: w.storeURL)
            observed(site, "after the failed reset: block reason=\(afterReset.persistenceBlockReason.value), unrelated save allowed=\(unrelatedSaved), recovery source unchanged=\(onDisk == sourceBytes)")
            expect(resetMessage?.hasPrefix("Could not create demo data") == true, "\(site): the store reports the failed reset")
            expect(!store.customers.contains { $0.name == "Tom Nguyen" }, "\(site): no demo data shows")
            expectEqual(afterReset.persistenceBlockReason, blockedAt.persistenceBlockReason, "\(site): the block reason is intact")
            expectEqual(afterReset.persistenceBlockDetail, blockedAt.persistenceBlockDetail, "\(site): the block detail is intact")
            expect(!unrelatedSaved, "\(site): writes are still blocked (an unrelated save is refused)")
            expect(onDisk == sourceBytes, "\(site): the recovery source on disk is unchanged after the attempted save")
            let bulk: AppStore.BulkSettleResult = store.commitBulkSettleInvoices(ids: ["any-invoice"])
            expectEqual(bulk.failure, readOnlyCopy, "\(site): bulk Mark paid on blocked data reports the read-only failure")
            let shownName = store.settings.businessName
            store.settings.businessName = "Blocked Edit"
            expectEqual(store.settings.businessName, shownName, "\(site): a Settings edit on blocked data goes back to the saved settings")
            expectEqual(store.settingsSaveFailure, readOnlyCopy, "\(site): the Settings screens say the data is read-only")

            // The explicit reset may still replace the blocked source once it saves.
            store.resetDemoData()
            expect(store.customers.contains { $0.name == "Tom Nguyen" }, "\(site): a reset that saves shows the demo data")
            expectEqual(store.supportReport().launchMigration.persistenceBlockReason, NativeSupportCode(nil),
                        "\(site): a reset that saves lifts the block")
            expectEqual(store.settingsSaveFailure, nil, "\(site): a reset that saves clears the read-only notice")
            expect(store.upsert(unrelated), "\(site): after a saved reset an unrelated save is allowed")
        }
    }

    // MARK: 9b. The Square token heal (scrubLegacySquareToken, already rolled back)

    @MainActor
    static func squareHeal() async {
        let site = "square-heal"
        let w = Workspace(site)
        defer { w.cleanup() }
        var store = w.launch()
        unrelatedSave(store, "\(site)-setup")
        let refused = "not-a-square-link-p12-008"
        if var fixture = w.disk {
            fixture.payload.settings?.providerKeys = ["square": refused, "venmo": "@p12"]
            do { try w.repository().save(fixture) } catch { expect(false, "\(site): fixture saved (\(error))") }
        }
        store = await w.launchSignedIn()
        expectEqual(w.disk?.payload.settings?.providerKeys["square"], refused, "\(site): sanity: the refused value is stored")
        w.clearQueue()

        w.failSnapshotSaves(true)
        let healed = store.scrubLegacySquareToken()
        w.failSnapshotSaves(false)
        expect(!healed, "\(site): the heal reports that it did not save")
        expect(w.queued("settings", "settings") == nil, "\(site): nothing is queued for the failed heal")
        unrelatedSave(store, site)
        expectEqual(w.disk?.payload.settings?.providerKeys["venmo"], "@p12", "\(site): the unrelated save keeps the other providers")
        expect(w.queue.allSatisfy { $0.table == "customers" }, "\(site): only the unrelated save is queued")

        // Once saves work, the heal saves and queues the cleaned settings.
        expect(store.scrubLegacySquareToken(), "\(site): a later heal runs")
        expect(w.disk?.payload.settings?.providerKeys["square"] == nil && w.queued("settings", "settings") != nil,
               "\(site): a later heal saves and is queued")
    }

    // MARK: 10. A pull whose commit fails (pullDeltaAndCommit, already rolled back)

    @MainActor
    static func pullCommit() async {
        let site = "pull"
        let w = Workspace(site)
        defer { w.cleanup() }
        let store = await w.launchSignedIn()
        let target = invoice("INV-8501", amount: 30)
        store.upsert(target)
        w.clearQueue()
        w.delta.serverRows = { snapshot in
            snapshot.payload.invoices = snapshot.payload.invoices?.map { record in
                var server = record
                if record.id == target.id { server.desc = "Server description" }
                return server
            }
        }
        w.failSnapshotSaves(true)
        let failed = await store.testPullDeltaIfPossible()
        w.failSnapshotSaves(false)
        expectEqual(failed, .failed("pull/local-commit"), "\(site): the pull reports the failed commit")
        expectEqual(store.invoices.first { $0.id == target.id }?.description, "", "\(site): the screens keep the saved record")
        unrelatedSave(store, site)
        expectEqual(w.diskInvoice(target.id)?.desc, "", "\(site): the failed pull is not persisted by the next unrelated save")
        let retried = await store.testPullDeltaIfPossible()
        expectEqual(retried.state, .completed, "\(site): the next pull completes")
        expectEqual(w.diskInvoice(target.id)?.desc, "Server description", "\(site): the next pull saves the server row")
    }

    // MARK: 10b. Where the owner sees a failed save (fix round 1, R41)

    /// The views that show these outcomes are not host-testable, so their
    /// branches are pinned on the source: the Invoices list shows the bulk
    /// result's failure before its "already paid" notice, the Payments page
    /// never says "Square link saved." for a link that was not saved, and
    /// every surface where the owner edits settings shows the store's
    /// Settings save failure.
    static func failureNoticeSources(root: URL) {
        func source(_ file: String) -> [UInt8] {
            let url = root.appendingPathComponent("native/TradeReadyNative/\(file)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "notice: \(file) is readable")
                return []
            }
            return Array(text.utf8)
        }
        let invoices = source("InvoicesView.swift")
        let bulk = functionBody(invoices, "private func runBulkSettle()")
        let failureBranch = bulk.range(of: "if let failure = result.failure")
        let alreadyPaid = bulk.range(of: "Nothing to settle")
        expect(failureBranch != nil && bulk.contains("bulkNotice = failure"),
               "notice: InvoicesView.runBulkSettle shows the bulk result's failure")
        expect(failureBranch.map { branch in alreadyPaid.map { branch.lowerBound < $0.lowerBound } ?? true } ?? false,
               "notice: the failure branch comes before the \"already paid\" notice")

        let settingsView = source("SettingsView.swift")
        let square = functionBody(settingsView, "private func saveSquareDraft()")
        let notSaved = square.range(of: "case let .notSaved(")
        let notSavedCase = notSaved.map { start -> Substring in
            let rest = square[start.upperBound...]
            return rest.range(of: "case ").map { rest[..<$0.lowerBound] } ?? rest
        }
        expect(notSavedCase.map { $0.contains("squareFeedback = (") && $0.contains(", true)") && !$0.contains("Square link saved") } ?? false,
               "notice: saveSquareDraft shows a link that was not saved as an error, never \"Square link saved.\"")
        expect(functionBody(settingsView, "private struct SettingsPage<Content: View>: View").contains("store.settingsSaveFailure"),
               "notice: every Settings page (SettingsPage) shows the Settings save failure")
        for file in ["NativeRecurringInvoicesView.swift", "NativeMileageLogView.swift"] {
            expect(String(decoding: source(file), as: UTF8.self).contains("store.settingsSaveFailure"),
                   "notice: \(file), which edits a setting, shows the Settings save failure")
        }
    }

    /// The raw text of the brace-delimited body that follows `signature`
    /// (braces counted on the sanitized source, so a brace in a string or a
    /// comment does not count).
    static func functionBody(_ bytes: [UInt8], _ signature: String) -> String {
        let sanitized = sanitizedSwift(bytes)
        let code = Array(sanitized.utf8)
        guard let found = sanitized.range(of: signature),
              let open = code[sanitized.utf8.distance(from: sanitized.startIndex, to: found.lowerBound)...]
                .firstIndex(of: UInt8(ascii: "{"))
        else { return "" }
        var depth = 0
        for index in open..<code.count {
            if code[index] == UInt8(ascii: "{") { depth += 1 }
            if code[index] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(decoding: bytes[open...index], as: UTF8.self) }
            }
        }
        return ""
    }

    // MARK: 11. Source pin: the live snapshot changes only through a save-first commit

    /// The `apply(X)` calls exempt from rule 4 of `sourcePin`, by scope, with
    /// the reason each one shows a snapshot that is already saved (or needs
    /// no save).
    static let applyAllowlist: [String: String] = [
        "commitSnapshot": "the commit itself: projects `next`, saves it, and re-applies the previous snapshot when the save throws",
        "load": "shows the snapshot just read from disk (nothing new to save)",
        "applyEmptySnapshot": "shows an empty workspace (no stored data, an unreadable source, an account scrub): nothing to keep",
        "replayVerifiedWidgetActionsIfPossible": "shows `committed`, which the widget replay coordinator saved first (NativeWidgetActionReplay.swift, `repository.save(result.snapshot)`), and reloads the saved snapshot from disk after a failed acknowledgement",
        "importLegacyData": "shows the snapshot the legacy migration coordinator saved first (LegacyMigrationCoordinator.swift, `repository.save(adoption.snapshot)`)",
    ]

    /// Standard-library mutating methods a `snapshot…` path could be changed
    /// through. `sourcePin` adds every `mutating func` declared under
    /// `native/TradeReadyNative`.
    static let standardMutators = [
        "removeAll", "removeFirst", "removeLast", "remove", "removeValue", "removeSubrange",
        "append", "insert", "sort", "reverse", "swapAt", "shuffle", "partition",
        "merge", "updateValue", "formUnion", "formIntersection", "formSymmetricDifference", "subtract",
        "popLast", "popFirst", "replaceSubrange", "reserveCapacity", "toggle", "negate",
    ]

    /// Fix round 1 (R41, Minor 1). The pin reads AppStore.swift with comments
    /// removed and string contents blanked (interpolated code kept), and
    /// attributes each offset to its innermost function-like scope: `func`,
    /// `init`, `deinit`, `subscript`, a computed property and each accessor or
    /// observer (`get`, `set`, `didSet`, `willSet`). A nested function is a
    /// scope of its own (`outer.inner`), and the outer function resumes after
    /// its closing brace.
    ///
    /// 1. Every write of the live snapshot (`snapshot = …` or a compound
    ///    assignment, `snapshot.payload… = …` through `?`, `!` and subscripts,
    ///    a mutating call on a `snapshot…` path, `&snapshot`, a `\.snapshot`
    ///    key path) sits in `apply` or one of the two commit helpers
    ///    (`commitSnapshot`; `commitSettings` saves a copy and keeps it only
    ///    once saved).
    /// 2. `repository.save(snapshot)` appears only in `commitSnapshot`,
    ///    `save()` (re-saves the unchanged snapshot) and the Square token
    ///    heal's backup rotation (after its `commitSettings`).
    /// 3. AppStore never calls its own `save()`: `apply(next); save()` (the
    ///    old demo-reset shape) kept `next` in memory when the save failed.
    /// 4. Every `apply(X)` outside `applyAllowlist` directly follows
    ///    `repository.save(X)` (only whitespace, `;` and `try` between), so a
    ///    copy site shows only what it saved: `try apply(next); try
    ///    repository.save(next)` and a bare `try apply(next)` both fail, and
    ///    `apply` is never referenced without being called. Since the final
    ///    review (M8) that save must also open its statement, with nothing
    ///    but whitespace and a plain `try` before it: `try? repository.save(X)`,
    ///    `try! …` and `_ = try? …` swallow or trap on the failure and fail
    ///    the pin (`pinSaveFirstProbe`).
    ///
    /// What a lexical pin cannot close (none of these occurs today):
    /// - a mutating method the pin does not know: one declared outside
    ///   `native/TradeReadyNative` and missing from `standardMutators`;
    /// - aliasing: a closure, a key path held in a variable or a pointer that
    ///   writes through to `snapshot` from elsewhere (`&snapshot` and
    ///   `\.snapshot` literals are caught where they are formed);
    /// - rule 4 compares `X` as text, so `repository.save(makeNext())` then
    ///   `apply(makeNext())` passes although the two calls may build different
    ///   values (every copy site passes a local or a local result's property);
    /// - a local `let`/`var snapshot` shadow is skipped only at its
    ///   declaration: later writes to it count as live-snapshot writes (a
    ///   false alarm, never a miss).
    /// `snapshot` and `apply` are `private` members of AppStore, visible only
    /// in AppStore.swift, so no other file can write the live snapshot.
    static func sourcePin(root: URL) {
        let url = root.appendingPathComponent("native/TradeReadyNative/AppStore.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            expect(false, "pin: AppStore.swift is readable")
            return
        }
        let declared = declaredMutatingMethods(under: root.appendingPathComponent("native/TradeReadyNative"))
        expect(declared.contains("setProviderKey"), "pin: sanity: the app's mutating methods are collected")
        let mutators = Array(Set(standardMutators).union(declared)).sorted { $0.count > $1.count }
        let source = ScopedSource(sanitizedSwift(Array(text.utf8)))
        let code = source.code
        let full = NSRange(location: 0, length: code.length)
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try! NSRegularExpression(pattern: pattern)).matches(in: code as String, range: full)
        }
        func tally(_ pattern: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            for match in matches(pattern) { counts[source.scope(at: match.range.location), default: 0] += 1 }
            return counts
        }

        let unshadowed = #"(?<!\b(?:let|var)\s{1,8})(?<![\w.])"#
        let path = #"(?:self[?!]?\.)?snapshot(?:[?!]?(?:\.[A-Za-z_]\w*|\[[^\]\n]*\]))*"#
        let writers = tally(
            unshadowed + path + #"(?:[?!](?=\s+=))?\s*(?:[-+*/%&|^]|&[-+*]|<<|>>)?=(?!=)"#
                + "|" + unshadowed + path + #"[?!]?\.(?:"# + mutators.joined(separator: "|") + #")\b"#
                + #"|(?<![&\w])&(?:self[?!]?\.)?snapshot\b"#
                + #"|\\(?:[A-Za-z_]\w*)?\.snapshot\b"#
        )
        let savers = tally(#"(?<![\w.])(?:self[?!]?\.)?repository\.save\(\s*(?:self[?!]?\.)?snapshot\s*\)"#)
        let resavers = tally(#"(?<!func )(?<![\w.])(?:self[?!]?\.)?save\(\s*\)"#)
        expectEqual(Set(writers.keys), ["apply", "commitSnapshot", "commitSettings"],
                    "pin: only apply and the commit helpers write the live snapshot (writers: \(writers))")
        expectEqual(savers, ["commitSnapshot": 1, "save": 1, "scrubLegacySquareToken": 1],
                    "pin: only commitSnapshot, save() and the Square heal's backup rotation save the live snapshot")
        expectEqual(resavers, [:], "pin: AppStore never commits through its own save()")

        // Rule 4: save first, then apply what was saved.
        let (saveFirst, allowlisted, unsaved) = saveFirstApplies(source, allowlist: applyAllowlist)
        observed("pin", "\(saveFirst) apply(X) call(s) follow repository.save(X); allowlisted: \(allowlisted.sorted { $0.key < $1.key })")
        expectEqual(unsaved, [], "pin: every apply(X) outside the allowlist directly follows repository.save(X)")
        expectEqual(Set(allowlisted.keys), Set(applyAllowlist.keys),
                    "pin: every allowlisted scope still applies a snapshot (the allowlist is not stale)")
        expect(saveFirst > 0, "pin: sanity: the save-first copy sites are found")
        let references = matches(#"(?<!func )(?<![\w.])(?:self[?!]?\.)?apply\b(?!\s*\()"#)
            .map { "\(source.scope(at: $0.range.location)) (line \(source.line(at: $0.range.location)))" }
        expectEqual(references, [], "pin: apply is only ever called, never passed or stored")
    }

    /// Rule 4 of `sourcePin`, on any sanitized source: every `apply(X)`
    /// outside `allowlist` must directly follow `repository.save(X)`. Returns
    /// the count that do, the allowlisted calls per scope, and each call
    /// that does not.
    static func saveFirstApplies(
        _ source: ScopedSource, allowlist: [String: String]
    ) -> (saveFirst: Int, allowlisted: [String: Int], unsaved: [String]) {
        let code = source.code
        var saveFirst = 0
        var allowlisted: [String: Int] = [:]
        var unsaved: [String] = []
        let calls = (try! NSRegularExpression(pattern: #"(?<!func )(?<![\w.])(?:self[?!]?\.)?apply\s*\("#))
            .matches(in: code as String, range: NSRange(location: 0, length: code.length))
        for call in calls {
            let scope = source.scope(at: call.range.location)
            if allowlist[scope] != nil { allowlisted[scope, default: 0] += 1; continue }
            let argument = source.balancedArgument(openingAt: call.range.location + call.range.length - 1)
            let words = argument.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let before = code.substring(to: call.range.location)
            // Final review M8: the save opens its statement (only spaces and
            // a plain `try` since the last line break, `;` or `{`), so a
            // `try?` or `try!` save, or one inside an expression, fails.
            let saved = words.isEmpty ? nil : try! NSRegularExpression(
                pattern: #"(?:\A|[\n;{])[ \t]*(?:try[ \t]+)?(?:self[?!]?\.)?repository\.save\(\s*"#
                    + words.joined(separator: #"\s+"#)
                    + #"\s*\)\s*;?\s*(?:try[?!]?\s+)?$"#
            ).firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
            if saved != nil { saveFirst += 1 } else {
                unsaved.append("\(scope) (line \(source.line(at: call.range.location))): apply(\(argument))")
            }
        }
        return (saveFirst, allowlisted, unsaved)
    }

    /// Final review M8 (§C 11b.1): rule 4 on a fixed probe. The save must be
    /// a plain `try repository.save(X)`: a `try?` or `try!` save swallows (or
    /// traps on) the failure, so the `apply(X)` after it could keep an
    /// unsaved snapshot in memory, which is what the P12-008 rule forbids.
    static func pinSaveFirstProbe() {
        func unsaved(_ body: String) -> [String] {
            let probe = "final class Probe {\n    func copy() throws {\n" + body + "\n    }\n}\n"
            return saveFirstApplies(ScopedSource(sanitizedSwift(Array(probe.utf8))), allowlist: [:]).unsaved
        }
        expectEqual(unsaved("        try repository.save(next); try apply(next)"), [],
                    "pin probe: a plain `try repository.save(X)` then `try apply(X)` passes")
        expectEqual(unsaved("        try self.repository.save(next)\n        try self.apply(next)"), [],
                    "pin probe: …also through self and on two lines")
        expectEqual(unsaved("        saveSnapshot: { try self.repository.save(next); try self.apply(next) }").count, 0,
                    "pin probe: …and inside a closure's braces")
        for rejected in [
            "        try? repository.save(next); try apply(next)",
            "        try! repository.save(next); try apply(next)",
            "        try? self.repository.save(next)\n        try self.apply(next)",
            "        _ = try? repository.save(next); try apply(next)",
            "        let saved = (try? repository.save(next)) != nil; try apply(next)",
        ] {
            expectEqual(unsaved(rejected).count, 1,
                        "pin probe [M8]: the pin rejects `\(rejected.trimmingCharacters(in: .whitespaces))`")
        }
    }

    /// The pin's scope attribution on a fixed probe: a nested function does
    /// not hide the rest of its outer function (the earlier line-based pin
    /// attributed `performJobPhotoTransfer`'s save to its nested
    /// `ownerIsCurrent`), and
    /// `init`, observers and accessors are scopes of their own; comments and
    /// string contents are not code, interpolated code is.
    static func pinScopes() {
        let probe = #"""
        final class Probe {
            var value = 0 { didSet { snapshot = value } }
            func outer() throws {
                func inner() -> Bool { true }
                try repository.save(next); try apply(next)
            }
            init() { snapshot.payload.invoices![0].paid = true }
            var computed: Int { get { 1 } set { snapshot.payload.x = newValue } }
            func literal() { let s = "apply(a) { \(apply(b)) }" // apply(c) {
                /* apply(d) { */ let r = #"apply(e) { "# }
        }
        """#
        let source = ScopedSource(sanitizedSwift(Array(probe.utf8)))
        let code = source.code
        func scope(of needle: String) -> String {
            let range = code.range(of: needle)
            return range.location == NSNotFound ? "<missing \(needle)>" : source.scope(at: range.location)
        }
        expectEqual(scope(of: "snapshot = value"), "didSet", "pin scopes: a didSet is its own scope")
        expectEqual(scope(of: "true }"), "outer.inner", "pin scopes: a nested function is its own scope")
        expectEqual(scope(of: "repository.save(next)"), "outer", "pin scopes: the outer function resumes after a nested function")
        expectEqual(scope(of: "snapshot.payload.invoices!"), "init", "pin scopes: init is its own scope")
        expectEqual(scope(of: "snapshot.payload.x"), "computed.set", "pin scopes: a setter is its own scope")
        expectEqual(scope(of: "let r"), "literal", "pin scopes: braces in comments and strings do not open scopes")
        expect(code.range(of: "apply(b)").location != NSNotFound, "pin scopes: interpolated code is kept")
        expect(["apply(a)", "apply(c)", "apply(d)", "apply(e)"].allSatisfy { code.range(of: $0).location == NSNotFound },
               "pin scopes: comments and string contents are blanked")
    }

    /// Every `mutating func` name declared in the app's Swift sources.
    static func declaredMutatingMethods(under directory: URL) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\bmutating\s+func\s+([A-Za-z_]\w*)"#)
        var names = Set<String>()
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = sanitizedSwift(Array(text.utf8))
            for match in regex.matches(in: code, range: NSRange(location: 0, length: (code as NSString).length)) {
                names.insert((code as NSString).substring(with: match.range(at: 1)))
            }
        }
        return names
    }

    /// Swift source as ASCII of the same length in bytes (one UTF-16 unit
    /// each): comments and string literal contents (plain, multiline, raw)
    /// blanked with newlines kept, interpolated code kept, non-ASCII bytes
    /// blanked.
    static func sanitizedSwift(_ source: [UInt8]) -> String {
        let n = source.count
        var out = source.map { $0 >= 0x80 ? UInt8(ascii: " ") : $0 }
        let newline = UInt8(ascii: "\n"), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
        let open = UInt8(ascii: "("), close = UInt8(ascii: ")")
        enum Mode { case code(parens: Int), literal(hashes: Int, multiline: Bool) }
        var modes: [Mode] = [.code(parens: 0)]
        func at(_ k: Int) -> UInt8 { k < n ? source[k] : 0 }
        func blank(_ k: Int) { if k < n, source[k] != newline { out[k] = UInt8(ascii: " ") } }
        func run(_ start: Int, _ byte: UInt8, _ count: Int) -> Bool { (0..<count).allSatisfy { at(start + $0) == byte } }
        var i = 0
        while i < n {
            switch modes[modes.count - 1] {
            case let .code(parens):
                if at(i) == slash, at(i + 1) == slash {
                    while i < n, source[i] != newline { blank(i); i += 1 }
                    continue
                }
                if at(i) == slash, at(i + 1) == star {
                    var depth = 0
                    repeat {
                        if at(i) == slash, at(i + 1) == star { depth += 1; blank(i); blank(i + 1); i += 2 }
                        else if at(i) == star, at(i + 1) == slash { depth -= 1; blank(i); blank(i + 1); i += 2 }
                        else { blank(i); i += 1 }
                    } while depth > 0 && i < n
                    continue
                }
                var hashes = 0
                while at(i + hashes) == hash { hashes += 1 }
                if at(i + hashes) == quote {
                    let multiline = run(i + hashes, quote, 3)
                    modes.append(.literal(hashes: hashes, multiline: multiline))
                    i += hashes + (multiline ? 3 : 1)
                    continue
                }
                if modes.count > 1 {
                    if at(i) == open { modes[modes.count - 1] = .code(parens: parens + 1) }
                    else if at(i) == close {
                        if parens == 0 { modes.removeLast(); blank(i) }
                        else { modes[modes.count - 1] = .code(parens: parens - 1) }
                    }
                }
                i += 1
            case let .literal(hashes, multiline):
                if at(i) == backslash, run(i + 1, hash, hashes) {
                    let next = i + 1 + hashes
                    for k in i...next { blank(k) }
                    if at(next) == open { modes.append(.code(parens: 0)) }
                    i = next + 1
                    continue
                }
                let closing = multiline ? 3 : 1
                if run(i, quote, closing), run(i + closing, hash, hashes) {
                    modes.removeLast()
                    i += closing + hashes
                    continue
                }
                blank(i)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Sanitized source with the innermost function-like scope of every offset.
    struct ScopedSource {
        let code: NSString
        private let scopeAt: [Int32]
        private let names: [String]
        private let lineStarts: [Int]

        init(_ sanitized: String) {
            let code = sanitized as NSString
            self.code = code
            let full = NSRange(location: 0, length: code.length)
            struct Declaration { let offset: Int; let label: String; let isType: Bool }
            var declarations: [Declaration] = []
            func collect(_ pattern: String, isType: Bool = false, _ label: (NSTextCheckingResult) -> String) {
                for match in (try! NSRegularExpression(pattern: pattern)).matches(in: sanitized, range: full) {
                    declarations.append(Declaration(offset: match.range.location, label: label(match), isType: isType))
                }
            }
            func group(_ match: NSTextCheckingResult) -> String { code.substring(with: match.range(at: 1)) }
            collect(#"\bfunc\s+([A-Za-z_]\w*)"#, group)
            collect(#"(?<![\w.])init\s*[?!]?\s*[(<]"#) { _ in "init" }
            collect(#"(?<![\w.])deinit\s*\{"#) { _ in "deinit" }
            collect(#"(?<![\w.])subscript\s*[(<]"#) { _ in "subscript" }
            collect(#"(?<![\w.])(didSet|willSet|get|set|_read|_modify)\s*(?:\(\s*\w+\s*\))?\s*(?:async\s+)?(?:throws\s*)?\{"#, group)
            collect(#"(?<![\w.])var\s+([A-Za-z_]\w*)\s*:[^=\n{}]*\{"#, group)
            collect(#"\b(?:class|struct|enum|extension|actor|protocol)\s+(?!func\b|var\b|let\b)([A-Za-z_][\w.]*)"#, isType: true) {
                "<type \(group($0))>"
            }
            declarations.sort { $0.offset < $1.offset }

            struct Frame { let label: String?; let isType: Bool }
            var frames: [Frame] = []
            var names = ["<top level>"]
            var ids = ["<top level>": Int32(0)]
            func currentID() -> Int32 {
                var parts: [String] = []
                var name = "<top level>"
                for frame in frames.reversed() {
                    guard let label = frame.label else { continue }
                    if frame.isType { name = label; break }
                    parts.append(label)
                }
                if !parts.isEmpty { name = parts.reversed().joined(separator: ".") }
                if let id = ids[name] { return id }
                names.append(name)
                ids[name] = Int32(names.count - 1)
                return Int32(names.count - 1)
            }
            let bytes = Array(sanitized.utf8)
            var scopeAt = [Int32](repeating: 0, count: bytes.count)
            var pending: (label: String, isType: Bool, depth: Int)?
            var next = 0
            var depth = 0
            var current: Int32 = 0
            var lineStarts = [0]
            for offset in 0..<bytes.count {
                while next < declarations.count, declarations[next].offset <= offset {
                    pending = (declarations[next].label, declarations[next].isType, depth)
                    next += 1
                }
                switch bytes[offset] {
                case UInt8(ascii: "("), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"): depth -= 1
                case UInt8(ascii: "{"):
                    if let declaration = pending, declaration.depth == depth {
                        frames.append(Frame(label: declaration.label, isType: declaration.isType))
                        pending = nil
                    } else {
                        frames.append(Frame(label: nil, isType: false))
                    }
                    current = currentID()
                case UInt8(ascii: "}"):
                    if !frames.isEmpty { frames.removeLast() }
                    current = currentID()
                case UInt8(ascii: "\n"): lineStarts.append(offset + 1)
                default: break
                }
                scopeAt[offset] = current
            }
            self.scopeAt = scopeAt
            self.names = names
            self.lineStarts = lineStarts
        }

        func scope(at offset: Int) -> String { names[Int(scopeAt[offset])] }

        func line(at offset: Int) -> Int { lineStarts.lastIndex { $0 <= offset }.map { $0 + 1 } ?? 1 }

        /// The text inside the parentheses that open at `offset`.
        func balancedArgument(openingAt offset: Int) -> String {
            var depth = 0
            var index = offset
            while index < code.length {
                let unit = code.character(at: index)
                if unit == 0x28 { depth += 1 }
                if unit == 0x29 {
                    depth -= 1
                    if depth == 0 { return code.substring(with: NSRange(location: offset + 1, length: index - offset - 1)) }
                }
                index += 1
            }
            return ""
        }
    }
}
