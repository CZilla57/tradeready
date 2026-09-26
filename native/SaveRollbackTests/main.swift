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
// every write of the live snapshot inside `apply` and the two commit helpers.
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
        await autoEmailClear()
        await legacyInvoiceExpenseAPIs()
        onboardingCommits()
        demoReset()
        await squareHeal()
        await pullCommit()
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
        let result = store.commitBulkSettleInvoices(ids: [first.id, second.id])
        await settle()
        w.failSnapshotSaves(false)

        expect(result.settled.isEmpty, "\(site): nothing is reported settled")
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
        expectEqual(samplesKept, 1, "\(site): the failed fresh start's removal is not persisted by the next unrelated save")
        let relaunched = w.launch()
        expect(relaunched.settings.businessName != "Onboarded Co", "\(site): after a relaunch the failed personalization is absent")
        expectEqual(relaunched.customers.filter { $0.id.hasPrefix("native-sample-v1-") }.count, 1,
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

    // MARK: 11. Source pin: the live snapshot is written only by the commit helpers

    /// Every write of the live snapshot (`snapshot = …`, `snapshot.payload… = …`,
    /// a mutating call on `snapshot.payload…`, `&snapshot`) sits in `apply`
    /// or one of the two commit helpers (`commitSettings` saves a copy and
    /// keeps it only once saved), and `repository.save(snapshot)` only in
    /// `commitSnapshot`, `save()` (re-saves the unchanged snapshot) and the
    /// Square token heal's backup rotation (after its `commitSettings`). A new
    /// in-place commit fails here.
    static func sourcePin(root: URL) {
        let url = root.appendingPathComponent("native/TradeReadyNative/AppStore.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            expect(false, "pin: AppStore.swift is readable")
            return
        }
        let function = try! NSRegularExpression(
            pattern: #"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|final|override|nonisolated|mutating)\s+)*func\s+(\w+)"#
        )
        let path = #"(?:self\.)?snapshot(?:(?:\.[A-Za-z_]\w*|\[[^\]]*\])\??)*"#
        let write = try! NSRegularExpression(
            pattern: #"(?<![\w.])"# + path + #"\s*(?:=(?!=)|\+=|-=)"#
                + #"|(?<![\w.])(?:self\.)?snapshot(?:(?:\.[A-Za-z_]\w*|\[[^\]]*\])\??)+\.(?:removeAll|removeFirst|removeLast|remove|append|insert|sort|reverse|swapAt)\b"#
                + #"|&(?:self\.)?snapshot\b"#
        )
        let declaration = try! NSRegularExpression(pattern: #"\b(?:let|var)\s+snapshot\b"#)
        let save = try! NSRegularExpression(pattern: #"repository\.save\((?:self\.)?snapshot\)"#)
        // `apply(next); save()` (the old demo-reset shape) keeps `next` in
        // memory when the save fails, so AppStore never calls its own
        // `save()`; only a view's explicit re-save (Settings) does.
        let resave = try! NSRegularExpression(pattern: #"(?<![\w.])(?:self\.)?save\(\)"#)
        var current = "<top level>"
        var writers: [String: Int] = [:]
        var savers: [String: Int] = [:]
        var resavers: [String: Int] = [:]
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            var definesFunction = false
            if let match = function.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line) {
                current = String(line[name])
                definesFunction = true
            }
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || declaration.firstMatch(in: line, range: range) != nil { continue }
            if write.firstMatch(in: line, range: range) != nil { writers[current, default: 0] += 1 }
            savers[current, default: 0] += save.numberOfMatches(in: line, range: range)
            if !definesFunction { resavers[current, default: 0] += resave.numberOfMatches(in: line, range: range) }
        }
        savers = savers.filter { $0.value > 0 }
        resavers = resavers.filter { $0.value > 0 }
        expectEqual(resavers, [:], "pin: AppStore never commits through its own save()")
        expectEqual(Set(writers.keys), ["apply", "commitSnapshot", "commitSettings"],
                    "pin: only apply and the commit helpers write the live snapshot (writers: \(writers))")
        expectEqual(savers, ["commitSnapshot": 1, "save": 1, "scrubLegacySquareToken": 1],
                    "pin: only commitSnapshot, save() and the Square heal's backup rotation save the live snapshot")
    }
}
