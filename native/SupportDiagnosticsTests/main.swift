import Foundation

// Phase 12 (12.02) host tests: the privacy-safe support report
// (`NativeSupportDiagnostics.swift`, Settings > Prepare support report) and
// the remote monitoring signals the cutover charter reads (§3): TH-1/TH-2
// (`legacyMigration`), TH-3 (`pendingAge`), TH-5 (`pushDiscarded`), TH-6 and
// OI-3 (`syncThrottle`), TH-9 (`invoicePayment`), TH-10 (`purchase`,
// `restorePurchases`), RN `initialSync`, and the blocked account scrub
// (`accountScrub`, P12-001/P12-006). The Sentry SDK is never compiled: a
// recording fake adapter sits behind the real `NativeCrashReporter`, so every
// signal runs through the same builder and redaction the app uses. Nothing
// here touches the network: the dry run's push goes to a stub loader on a
// `.invalid` host. Run with TZ=America/Phoenix (the runner defaults it).

// MARK: - Fakes

struct Captured: Equatable, CustomStringConvertible {
    let title: String?
    let domain: String
    let extras: String
    let fingerprint: [String]

    var description: String { "capture(\(title ?? "<error>"), \(domain), \(extras), \(fingerprint))" }
    var context: String? { fingerprint.count == 2 ? fingerprint[1] : nil }
}

func canonicalJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8)
    else { return "<invalid json>" }
    return text
}

final class RecordingCrashAdapter: NativeCrashReportingSDKAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Captured] = []

    var captures: [Captured] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded.removeAll(); lock.unlock() }

    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {}

    func capture(_ report: NativeCrashReport) throws {
        let ns = report.error as NSError
        lock.lock()
        recorded.append(Captured(
            title: report.title, domain: ns.domain,
            extras: canonicalJSON(report.extras), fingerprint: report.fingerprint
        ))
        lock.unlock()
    }

    func setUser(id: String?) throws {}
}

struct NoopReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

@MainActor
final class SubscriptionStub: NativeSubscriptionServing {
    var purchaseError: Error?
    var restoreError: Error?
    var purchaseCancelled = false

    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        if let purchaseError { throw purchaseError }
        return .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: purchaseCancelled)
    }
    func restore() async throws -> NativeSubscriptionEntitlement {
        if let restoreError { throw restoreError }
        return .init(isActive: false, isTrialing: false)
    }
    func logOut() async {}
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

func hexBinding(_ tag: String) -> String {
    var s = String(tag.lowercased().map { ("0"..."9").contains($0) || ("a"..."f").contains($0) ? $0 : "0" })
    while s.count < 64 { s += "0" }
    return String(s.prefix(64))
}

/// The bounded `{code, message}` capture every new signal sends.
func signal(_ code: String, _ message: String, context: String, extras: [String: Any] = [:]) -> Captured {
    var all = extras
    all["context"] = context
    all["rawError"] = ["code": code, "message": message]
    return Captured(
        title: "[\(code)] \(message)", domain: NativeReportedError.errorDomain,
        extras: canonicalJSON(all), fingerprint: ["{{ default }}", context]
    )
}

/// Seeded secrets: none may reach a capture or the exported report.
let secretFragments = [
    "Riley", "Secretname", "riley.secret", "@example.com", "sk_live_", "sk-ant-", "gsk_", "phc_",
    "eyJ", "Bearer", "/Users/", "JVBERi0", "INV-9001", "user-riley",
]

func assertNoSecrets(_ text: String, _ label: String) {
    for fragment in secretFragments where text.contains(fragment) {
        expect(false, "\(label): never carries '\(fragment)'")
    }
}

/// One scenario's on-disk workspace, its throwaway App Group suite and its
/// crash reporter. The Keychain is the process-wide in-memory host store, so
/// every fixture starts it empty.
@MainActor
final class Fixture {
    let directory: URL
    let suite: String
    let adapter = RecordingCrashAdapter()
    let crash: NativeCrashReporter

    init(_ tag: String) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-support-diagnostics-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "com.tradeready.support-diagnostics.tests.\(UUID().uuidString)"
        crash = NativeCrashReporter(adapter: adapter)
        try? hostTestSecureSettingsStore().clearAllValues()
    }

    var storeURL: URL { directory.appendingPathComponent("store.json") }
    var queueURL: URL { directory.appendingPathComponent("mutation-queue.json") }
    var reportURL: URL { directory.appendingPathComponent("tradeready-support-report.json") }

    func scrubber(blocked: Bool) -> NativeAppGroupAccountScrubber {
        blocked
            ? NativeAppGroupAccountScrubber(suiteName: suite, defaults: nil, lockFile: nil)
            : NativeAppGroupAccountScrubber(
                suiteName: suite,
                defaults: UserDefaults(suiteName: suite) ?? .standard,
                lockFile: directory.appendingPathComponent("app-group.lock")
            )
    }

    func launch(
        seed: Bool = false,
        migrate: Bool = false,
        provider: (() throws -> LegacyMigrationSource)? = nil,
        repository: Canonical.SnapshotRepository? = nil,
        blockedScrubber: Bool = false,
        subscription: NativeSubscriptionServing? = nil
    ) -> AppStore {
        let store = AppStore(
            fileURL: storeURL,
            seedIfMissing: seed,
            automaticallyMigrateLegacyData: migrate,
            legacyMigrationSourceProvider: provider,
            repository: repository,
            appGroupAccountScrubber: scrubber(blocked: blockedScrubber),
            subscriptionService: subscription ?? SubscriptionStub(),
            analytics: NativeNoOpAnalytics(),
            crashReporting: crash,
            widgetTimelineReloader: NoopReloader(),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        store.coachAdvisoryAnthropicKeyOverride = ""
        store.coachAdvisoryGroqKeyOverride = ""
        return store
    }

    func captures() -> [Captured] {
        crash.waitUntilIdle()
        return adapter.captures
    }

    func clear() {
        crash.waitUntilIdle()
        adapter.clear()
    }

    func write(_ text: String, to name: String) {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Data(text.utf8).write(to: url) } catch { expect(false, "fixture: wrote \(name) (\(error))") }
    }

    /// The React Native import's journal entry, completed.
    func completeMigrationJournal() {
        let journal = Canonical.MigrationJournal(fileURL: directory.appendingPathComponent("migration-journal.json"))
        do {
            _ = try journal.begin(.reactNativeAsyncStorage)
            try journal.complete(.reactNativeAsyncStorage)
        } catch {
            expect(false, "fixture: the journal completed (\(error))")
        }
    }

    /// An empty legacy source: nothing to import.
    func emptySource() -> LegacyMigrationSource {
        let documents = directory.appendingPathComponent("LegacyDocuments", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return LegacyMigrationSource(
            asyncStorageDirectory: nil, documentsDirectory: documents,
            secureSettings: LegacySecureSettings(), appGroupValues: [:]
        )
    }

    func setReadOnly(_ readOnly: Bool) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: readOnly ? 0o555 : 0o755], ofItemAtPath: directory.path)
        } catch {
            expect(false, "fixture: permissions changed (\(error))")
        }
    }

    func cleanup() {
        crash.waitUntilIdle()
        setReadOnly(false)
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? hostTestSecureSettingsStore().clearAllValues()
    }
}

/// A verified live outcome for `subject` (what a launch identity check yields).
func verifiedOutcome(_ subject: String, binding: String) -> NativeAuthenticatedIdentityActivationOutcome {
    NativeAuthenticatedIdentityActivationOutcome(
        accountState: .noAccountState, newlyStagedCount: 0, alreadyStagedCount: 0,
        typedAccountState: nil, localOwnerVerified: true,
        accountBinding: binding, verifiedAccountBinding: binding,
        verifiedUserSubject: subject, verifiedEmail: nil, verificationSource: .live
    )
}

/// A sync pass as the coordinator publishes it: running, then ended.
@MainActor
func pass(_ store: AppStore, _ end: NativeSyncStatus) {
    var running = end
    running.isSyncing = true
    store.testApplySyncStatus(running)
    store.testApplySyncStatus(end)
}

func queuedItem(_ id: String, table: String = "jobs", age: TimeInterval) -> Canonical.MutationItem {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return Canonical.MutationItem(
        table: table, op: .upsert, recordId: id,
        payload: .object(["id": .string(id), "title": .string("Riley Secretname's panel")]),
        ts: formatter.string(from: Date().addingTimeInterval(-age))
    )
}

/// The fixture error a failing legacy read throws: a path and an email in
/// its user info, neither of which may leave the device.
let fixtureError = NSError(domain: "com.example.Fixture", code: 7, userInfo: [
    NSFilePathErrorKey: "/Users/riley/Library/secret.sqlite",
    NSLocalizedDescriptionKey: "Could not read riley.secret@example.com",
])

/// The stub network behind the dry run's real push service: every request is
/// answered here by status only. It is never a real host.
final class DryRunLink: NativeMutationPushHTTPLoading, NativeSyncReachability, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let status: (String) -> Int
    /// Runs while the first request is in flight (a trigger that arrives
    /// mid-pass, which the coordinator coalesces into a rerun).
    var duringFirstRequest: (@MainActor @Sendable () async -> Void)?

    init(status: @escaping (String) -> Int) { self.status = status }

    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }

    func isReachable() async -> Bool { true }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); count += 1; let hook = count == 1 ? duringFirstRequest : nil; lock.unlock()
        if let hook { await hook() }
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://dry-run.invalid")!,
            statusCode: status(body), httpVersion: nil, headerFields: nil
        )!
        return (Data("[]".utf8), response)
    }
}

/// `AppStore.syncCoordinatorIfConfigured`'s coordinator, minus
/// BuildEnvironment: the real push service and coordinator, the store's own
/// queue file, settle step and status handler, and a stub link.
@MainActor
func dryRunCoordinator(_ store: AppStore, queue: Canonical.NativeMutationQueue, link: DryRunLink) -> NativeSyncCoordinator {
    let credentials = NativeSyncCredentials(
        subject: "dry-run-subject", sessionBytes: Data(#"{"access_token":"dry-run-placeholder"}"#.utf8)
    )
    return NativeSyncCoordinator(
        push: NativeSupabaseMutationPushService(
            supabaseURL: URL(string: "https://dry-run.invalid")!, publishableKey: "dry-run-placeholder",
            allowsWrites: true, loader: link
        ),
        queue: queue,
        reachability: link,
        credentialsProvider: { credentials },
        refreshSession: { false },
        settleRejected: { try store.testSettleRejectedChanges($0) },
        statusChanged: { store.testApplySyncStatus($0) }
    )
}

/// Writes the support report exactly as Settings does and parses it.
@MainActor
func reportJSON(_ store: AppStore, version: String = "9.9.9", build: String = "99") throws -> (json: [String: Any], bytes: Int) {
    let url = try store.createPersistenceSupportReport(appVersion: version, appBuild: build)
    let data = try Data(contentsOf: url)
    return ((try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:], data.count)
}

func section(_ json: [String: Any], _ key: String) -> [String: Any] {
    (json[key] as? [String: Any]) ?? [:]
}

/// The closed report schema (v3). A new key must be added here on purpose.
let reportKeys: [String: Set<String>] = [
    "top": ["reportSchemaVersion", "app", "persistence", "persistenceUnavailableCode", "launchMigration",
            "accountBoundary", "sync", "widgets", "legacyBackupProtection"],
    "app": ["version", "build"],
    "launchMigration": ["notice", "blocked", "persistenceBlockReason", "persistenceBlockDetail", "lastOutcome",
                        "lastOperation", "lastFailureCode", "importedCount", "missingPhotoCount",
                        "adoptedPhotoCount", "deferredPhotoCount"],
    "accountBoundary": ["scrubPending", "scrubPendingScope", "scrubBlocked", "scrubBlockedScope", "scrubBlockedCount",
                        "deletionPendingWithoutMarker", "deletionRecordUnverified", "deletionRecord",
                        "workspaceClearedRecord", "cleanupPending", "boundarySteps",
                        "boundaryStepMarkerWriteFailureCount", "boundaryStepRecordFailureCount",
                        "aiProviderKeyWipeFailureCount"],
    "boundaryStep": ["step", "pending", "unverified"],
    "sync": ["pendingCount", "oldestPendingAge", "isSyncing", "consecutiveFailures", "lastOutcome", "diagnosticCode",
             "lastPullState", "lastPullCode", "backoffActive", "lastSuccessfulSyncAge", "rejectedChangeCount",
             "rejectedChangeOverflowCount", "rejectedChangeScrubFailureCount", "discardedChangeCount",
             "throttledPassCount", "consecutiveThrottledPasses", "maxConsecutiveThrottledPasses", "recentCodes",
             "recentCodesOmitted"],
    "recentCode": ["context", "code", "count"],
    "widgets": ["mirrorDirty", "mirrorLockBusyCount", "ownerDroppedActionCount", "quarantinedQueueCount",
                "accountSwitchScrubFailureCount", "setAsideActionCount", "quarantinedClaimCount", "unreadableClaimCount"],
    "legacyBackupProtection": ["checks", "enumeratorUnavailable", "lastProtectedFiles", "lastFailedFiles", "failedFileTotal"],
    "persistence": ["reportSchemaVersion", "appVersion", "snapshotSchemaVersion", "snapshotStatus", "backupAvailable",
                    "recordCounts", "migrationStatuses", "rejectedChangeCount"],
]

// MARK: - Tests

@main
struct SupportDiagnosticsTests {
    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")
        codeSanitizing()
        codeHistory()
        syncMonitorRules()
        legacyFileProtectionTally()
        try exportBoundsAndExclusions()
        try reportEncodingCap()
        try boundaryStateInReport()
        try launchMigrationInReport()
        legacyMigrationFailureSignal()
        missingMigratedSnapshotSignal()
        signedOutSteadyStateIsSilent()
        accountScrubBlockedSignal()
        await accountDeletionBlockedSignal()
        await purchaseAndRestoreSignals()
        invoicePaymentSignals()
        throttleSignal()
        pendingAgeSignal()
        initialSyncSignal()
        discardedSignal()
        await coalescedPassDiscardSignal()
        sourceChecks(root: root)
        try await dryRun()

        print("support-diagnostics tests: \(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }

    // MARK: 1. TH-1/TH-2: a migration that fails reports, at launch and on retry

    @MainActor
    static func legacyMigrationFailureSignal() {
        let f = Fixture("migration-failed")
        defer { f.cleanup() }
        let store = f.launch(migrate: true, provider: { throw fixtureError })
        expect(store.isLegacyMigrationBlocked, "migration: sanity: the failed launch migration blocks")
        let code = "legacy-migration/failed/com.example.Fixture/7"
        let message = "Previous-app data migration did not finish"
        expectEqual(f.captures(), [signal(code, message, context: "legacyMigration", extras: ["operation": "launch"])],
                    "migration: a failed launch migration reports once, with the error's domain and code only")
        f.clear()
        store.retryLegacyMigration()
        expectEqual(f.captures(), [signal(code, message, context: "legacyMigration", extras: ["operation": "retry"])],
                    "migration: a failed retry reports again, as a retry")
        assertNoSecrets("\(f.adapter.captures)", "migration")
    }

    // MARK: 2. TH-2: the "marked complete, snapshot unavailable" block reports

    @MainActor
    static func missingMigratedSnapshotSignal() {
        let f = Fixture("missing-snapshot")
        defer { f.cleanup() }
        f.completeMigrationJournal()
        let source = f.emptySource()
        let store = f.launch(migrate: true, provider: { source })
        expect(store.isLegacyMigrationBlocked, "missing snapshot: sanity: the launch blocks")
        let code = "legacy-migration/missing-migrated-snapshot"
        let message = "Previous-app data migration did not finish"
        expectEqual(f.captures(), [signal(code, message, context: "legacyMigration", extras: ["operation": "launch"])],
                    "missing snapshot: a completed journal with no snapshot and no scrub record reports at launch")
        f.clear()
        store.retryLegacyMigration()
        expectEqual(f.captures(), [signal(code, message, context: "legacyMigration", extras: ["operation": "retry"])],
                    "missing snapshot: Try again reports it again, as a retry")

        // The initial sync's local-recovery refusal reports too (RN
        // `initialSync`), under its preflight operation.
        f.clear()
        store.testApplyLaunchIdentityOutcome(verifiedOutcome("user-missing", binding: hexBinding("a1")))
        expectEqual(f.captures(), [signal(
            "preflight/local-recovery/missing-migrated-snapshot", "Initial sync did not complete",
            context: "initialSync", extras: ["operation": "preflight"]
        )], "missing snapshot: the blocked initial sync reports its preflight code")
    }

    // MARK: 3. P12-003: the signed-out steady state never reports

    @MainActor
    static func signedOutSteadyStateIsSilent() {
        let f = Fixture("steady-state")
        defer { f.cleanup() }
        f.completeMigrationJournal()
        f.write(#"{"schemaVersion":1}"#, to: "store.json.account-scrub-cleared")
        var providerReads = 0
        let store = f.launch(migrate: true, provider: {
            providerReads += 1
            throw fixtureError
        })
        expect(!store.isLegacyMigrationBlocked, "steady state: sanity: a signed-out migrated device opens")
        store.retryLegacyMigration()
        expectEqual(providerReads, 0, "steady state: the legacy source is never read")
        expectEqual(f.captures(), [], "steady state: a completed journal, no snapshot and the scrub's record report nothing")
    }

    // MARK: 4. P12-001: a blocked account scrub reports once per episode

    @MainActor
    static func accountScrubBlockedSignal() {
        let f = Fixture("scrub-blocked")
        defer { f.cleanup() }
        // A marker whose scope this build cannot decode (review M2).
        f.write(#"{"schemaVersion":1,"scope":"galaxy"}"#, to: "store.json.account-scrub-pending")
        let store = f.launch()
        expect(store.isAccountScrubBlocked, "scrub: sanity: an undecodable marker blocks the launch")
        let message = "Account cleanup could not finish"
        expectEqual(f.captures(), [signal(
            "account-scrub/blocked/unknown", message, context: "accountScrub",
            extras: ["operation": "launch", "count": 1]
        )], "scrub: a blocked launch cleanup reports once, scope unknown")

        f.clear()
        store.retryAccountScrub()
        expect(store.isAccountScrubBlocked, "scrub: sanity: the retry is still blocked")
        expectEqual(f.captures(), [], "scrub: a retry that stays blocked does not report again")

        // A readable marker: the retry finishes, and the next blocked episode
        // reports again.
        f.write(#"{"schemaVersion":1,"scope":"live"}"#, to: "store.json.account-scrub-pending")
        store.retryAccountScrub()
        expect(!store.isAccountScrubBlocked, "scrub: sanity: the retry finished the cleanup")
        f.write(#"{"schemaVersion":1,"scope":"galaxy"}"#, to: "store.json.account-scrub-pending")
        store.retryAccountScrub()
        expectEqual(f.captures(), [signal(
            "account-scrub/blocked/unknown", message, context: "accountScrub",
            extras: ["operation": "retry", "count": 3]
        )], "scrub: a new blocked episode reports again, with the running count")
    }

    // MARK: 5. P12-006: a deletion whose cleanup is blocked reports

    @MainActor
    static func accountDeletionBlockedSignal() async {
        let message = "Account cleanup could not finish"
        do {
            let f = Fixture("deletion-blocked")
            defer { f.cleanup() }
            let store = f.launch(seed: true, blockedScrubber: true)
            f.clear()
            do {
                try await store.testFinishAccountDeletionLocally()
                expect(false, "deletion: sanity: the blocked widget wipe fails the local deletion")
            } catch {}
            expectEqual(f.captures(), [signal(
                "account-scrub/blocked/all", message, context: "accountScrub",
                extras: ["operation": "deleteAccount", "count": 1]
            )], "deletion: a blocked deletion cleanup reports its scope")
        }
        do {
            // The marker itself cannot be written (a read-only volume): the
            // deletion is recorded in the Keychain only (P12-006).
            let f = Fixture("deletion-no-marker")
            defer { f.cleanup() }
            let store = f.launch(seed: true)
            f.clear()
            f.setReadOnly(true)
            do {
                try await store.testFinishAccountDeletionLocally()
                expect(false, "deletion: sanity: an unwritable marker fails the local deletion")
            } catch {}
            f.setReadOnly(false)
            expectEqual(f.captures(), [signal(
                "account-scrub/blocked/all/without-marker", message, context: "accountScrub",
                extras: ["operation": "deleteAccount", "count": 1]
            )], "deletion: a deletion pending without its marker says so")
        }
    }

    // MARK: 6. TH-10: RN `purchase` and `restorePurchases`

    @MainActor
    static func purchaseAndRestoreSignals() async {
        let f = Fixture("subscription")
        defer { f.cleanup() }
        let stub = SubscriptionStub()
        let store = f.launch(subscription: stub)

        stub.purchaseCancelled = true
        _ = await store.purchaseSubscription(packageID: "annual")
        expectEqual(f.captures(), [], "subscription: a cancelled purchase reports nothing (RN: !err.userCancelled)")

        let storeProblem = NSError(domain: "RevenueCat.ErrorCode", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Store problem for riley.secret@example.com",
        ])
        stub.purchaseError = storeProblem
        stub.restoreError = NSError(domain: "RevenueCat.ErrorCode", code: 10, userInfo: [:])
        let purchase = await store.purchaseSubscription(packageID: "annual")
        let restore = await store.restoreSubscription()
        if case .failed = purchase {} else { expect(false, "subscription: sanity: the purchase failed") }
        if case .failed = restore {} else { expect(false, "subscription: sanity: the restore failed") }
        expectEqual(f.captures(), [
            Captured(title: nil, domain: "RevenueCat.ErrorCode", extras: #"{"context":"purchase"}"#,
                     fingerprint: ["{{ default }}", "purchase"]),
            Captured(title: nil, domain: "RevenueCat.ErrorCode", extras: #"{"context":"restorePurchases"}"#,
                     fingerprint: ["{{ default }}", "restorePurchases"]),
        ], "subscription: a failed purchase and a failed restore report the error, as RN PaywallScreen does")
    }

    // MARK: 7. TH-9: a payment that could not be saved reports

    @MainActor
    static func invoicePaymentSignals() {
        let f = Fixture("payment")
        defer { f.cleanup() }
        let store = f.launch()
        var invoice = Invoice()
        invoice.customer = "Riley Secretname"
        invoice.number = "INV-9001"
        invoice.amount = 80
        store.upsert(invoice)
        f.clear()

        f.setReadOnly(true)
        var payment = Payment()
        payment.amount = 80
        payment.method = "Card"
        if case .success = store.recordPayment(invoiceID: invoice.id, payment: payment) {
            expect(false, "payment: sanity: a read-only store refuses the payment")
        }
        let bulk = store.commitBulkSettleInvoices(ids: [invoice.id])
        f.setReadOnly(false)
        expect(bulk.settled.isEmpty, "payment: sanity: bulk Mark paid saved nothing")

        let captures = f.captures()
        expectEqual(captures.map(\.context), ["invoicePayment", "invoicePayment"],
                    "payment: the failed payment and the failed bulk Mark paid each report once")
        if captures.count == 2 {
            expect(captures[0].title?.hasPrefix("[invoice-payment/commit/NSCocoaErrorDomain/") == true
                   && captures[0].extras.contains(#""operation":"commit""#),
                   "payment: the commit reports the error's domain and code (\(captures[0]))")
            expect(captures[1].title?.hasPrefix("[invoice-payment/bulkMarkPaid/NSCocoaErrorDomain/") == true
                   && captures[1].extras.contains(#""operation":"bulkMarkPaid""#)
                   && captures[1].extras.contains(#""count":1"#),
                   "payment: bulk Mark paid reports its operation and count (\(captures[1]))")
        }
        assertNoSecrets("\(captures)", "payment")
        expect(!"\(captures)".contains(invoice.id), "payment: the invoice id never leaves")
        expect(!"\(captures)".contains("\"amount\""), "payment: no amount leaves")
    }

    // MARK: 8. TH-6 / OI-3: three throttled passes in a row report once

    @MainActor
    static func throttleSignal() {
        let f = Fixture("throttle")
        defer { f.cleanup() }
        let store = f.launch()
        f.clear()
        var throttled = NativeSyncStatus()
        throttled.pendingCount = 2
        throttled.lastOutcome = .partial(pushed: 0, remaining: 2, authRefreshed: false)
        throttled.diagnosticCode = "http-response/jobs/429"
        let burst = signal("throttle/consecutive-passes", "Sync passes throttled in a row",
                           context: "syncThrottle", extras: ["count": 3])
        func throttleCaptures() -> [Captured] { f.captures().filter { $0.context == "syncThrottle" } }

        pass(store, throttled)
        pass(store, throttled)
        expectEqual(throttleCaptures(), [], "throttle: two throttled passes are not a burst yet")
        pass(store, throttled)
        expectEqual(throttleCaptures(), [burst], "throttle: the third throttled pass in a row reports")
        pass(store, throttled)
        expectEqual(throttleCaptures(), [burst], "throttle: the same streak reports once")

        // A clean pass ends the streak; offline and other early exits do not.
        var clean = NativeSyncStatus()
        clean.lastOutcome = .completed(pushed: 2, authRefreshed: false)
        clean.lastPullResult = .completed
        pass(store, clean)
        f.clear()
        var offline = NativeSyncStatus()
        offline.lastOutcome = .offline
        offline.diagnosticCode = "http-response/jobs/429"
        pass(store, throttled)
        pass(store, offline)
        pass(store, throttled)
        // A pull throttled after a clean push counts as a throttled pass.
        var pullThrottled = NativeSyncStatus()
        pullThrottled.lastOutcome = .completed(pushed: 0, authRefreshed: false)
        pullThrottled.lastPullResult = .failed("pull/jobs/429")
        pass(store, pullThrottled)
        expectEqual(throttleCaptures(), [burst], "throttle: a new streak reports again; offline passes do not break it")
    }

    // MARK: 9. TH-3: changes pending for over 24 hours report once

    @MainActor
    static func pendingAgeSignal() {
        let f = Fixture("pending-age")
        defer { f.cleanup() }
        let store = f.launch()
        let queue = Canonical.NativeMutationQueue(fileURL: f.queueURL)
        do { try queue.save([queuedItem("old-job", age: 30 * 3_600), queuedItem("new-job", age: 60)]) } catch {
            expect(false, "pending age: the queue was seeded (\(error))")
        }
        f.clear()
        var stuck = NativeSyncStatus()
        stuck.pendingCount = 2
        stuck.lastOutcome = .partial(pushed: 0, remaining: 2, authRefreshed: false)
        stuck.diagnosticCode = "http-response/jobs/503"
        let aged = signal("pending-age/over-24h", "Changes pending for over 24 hours",
                          context: "pendingAge", extras: ["count": 2])
        func ageCaptures() -> [Captured] { f.captures().filter { $0.context == "pendingAge" } }

        var offline = NativeSyncStatus()
        offline.pendingCount = 2
        offline.lastOutcome = .offline
        pass(store, offline)
        expectEqual(ageCaptures(), [], "pending age: an offline device does not report (TH-3: signed in and online)")
        pass(store, stuck)
        expectEqual(ageCaptures(), [aged], "pending age: a network pass with a change queued over 24 h reports")
        pass(store, stuck)
        expectEqual(ageCaptures(), [aged], "pending age: it reports once while the change stays queued")

        // The queue drains, then an old change is stuck again: re-armed.
        try? queue.save([])
        var drained = NativeSyncStatus()
        drained.lastOutcome = .completed(pushed: 2, authRefreshed: false)
        drained.lastPullResult = .completed
        pass(store, drained)
        try? queue.save([queuedItem("older-job", age: 50 * 3_600), queuedItem("new-job", age: 60)])
        pass(store, stuck)
        expectEqual(ageCaptures(), [aged, aged], "pending age: a new stuck change after the queue drained reports again")
        assertNoSecrets("\(f.captures())", "pending age")
    }

    // MARK: 10. RN `initialSync`: the gate's refusal reports

    @MainActor
    static func initialSyncSignal() {
        let f = Fixture("initial-sync")
        defer { f.cleanup() }
        let store = f.launch()
        f.clear()
        store.testApplyLaunchIdentityOutcome(verifiedOutcome("user-initial", binding: hexBinding("b1")))
        if case .initialSyncUnavailable = store.authenticationGateState {} else {
            expect(false, "initial sync: sanity: this host binary has no Supabase configuration")
        }
        expectEqual(f.captures(), [signal(
            "preflight/configuration-or-session", "Initial sync did not complete",
            context: "initialSync", extras: ["operation": "preflight"]
        )], "initial sync: an unavailable initial sync reports its bounded code")
    }

    // MARK: 11. Source checks: the sites a host test cannot reach

    static func read(_ root: URL, _ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    static func sourceChecks(root: URL) {
        let store = read(root, "native/TradeReadyNative/AppStore.swift")
        expect(!store.isEmpty, "source: AppStore.swift is readable from the runner's root")
        // The initial sync's pull failure (after the network call) reports
        // through the same helper as the preflight refusals.
        expect(store.contains(#"reportInitialSyncUnavailable(code: diagnosticCode, operation: "pull")"#),
               "source: the initial sync's pull failure reports under initialSync/pull")
        expectEqual(store.components(separatedBy: #"operation: "preflight")"#).count - 1, 2,
                    "source: both initial-sync preflight refusals report")
    }

    // MARK: 12. Codes, ages and counts (pure)

    static func codeSanitizing() {
        let d = NativeSupportDiagnostics.self
        expectEqual(d.sanitizedCode(nil), "none", "code: nil reads as none")
        expectEqual(d.sanitizedCode(""), "none", "code: empty reads as none")
        for kept in ["http-response/jobs/429", "record-contract/customer_notes", "rejected/jobs/422", "pull/jobs/http_500",
                     "preflight/local-recovery/unreadable-snapshot/canonical-io-error", "NSCocoaErrorDomain/513",
                     "com.example.Fixture/7", "throttle/consecutive-passes"] {
            expectEqual(d.sanitizedCode(kept), kept, "code: a bounded code is kept (\(kept))")
        }
        for bad in ["push/sk_live_51Habc123DEF456", "phc_abcdefghijklmnopqrstuvwxyz", "pull/riley.secret@example.com",
                    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2ln", "push failed for Riley", "push/4805550123",
                    "jobs/3f2504e0-4f89-11d3-9a0c-0305e82c3301", String(repeating: "a", count: 97),
                    "https://dry-run.invalid/x", "push/\n", "push/Ø"] {
            expectEqual(d.sanitizedCode(bad), "unrecognized", "code: an unbounded value is replaced (\(bad.prefix(24)))")
        }
        expectEqual(d.errorCode(fixtureError), "com.example.Fixture/7", "code: an error is its domain and code only")
        expectEqual(d.errorCode(NSError(domain: NSCocoaErrorDomain, code: 513)), "NSCocoaErrorDomain/513",
                    "code: a Cocoa error")
        expectEqual(d.errorCode(NSError(domain: "riley.secret@example.com", code: 3)), "unrecognized/3",
                    "code: a domain that is not a bounded code keeps only the number")
        expect(d.errorCode(Canonical.SnapshotRepository.AccountScrubMarkerError.undecodable)
                .hasSuffix("AccountScrubMarkerError/1"), "code: a Swift error is its type and case index")

        let now = Date()
        expectEqual(d.ageBucket(from: nil, now: now), "none", "age: none")
        expectEqual(d.ageBucket(from: now.addingTimeInterval(120), now: now), "under-1h", "age: a clock skewed ahead reads as fresh")
        expectEqual(d.ageBucket(from: now.addingTimeInterval(-30 * 60), now: now), "under-1h", "age: under an hour")
        expectEqual(d.ageBucket(from: now.addingTimeInterval(-2 * 3_600), now: now), "1h-to-24h", "age: hours")
        expectEqual(d.ageBucket(from: now.addingTimeInterval(-25 * 3_600), now: now), "over-24h", "age: over a day")
        expect(d.queuedDate("2026-09-25T10:00:00.000Z") != nil, "age: a queued timestamp with fractional seconds parses")
        expect(d.queuedDate("2026-09-25T10:00:00Z") != nil, "age: a queued timestamp without them parses")
        expect(d.queuedDate("not a date") == nil, "age: anything else does not")

        expect(d.isThrottleCode("http-response/jobs/429") && d.isThrottleCode("pull/jobs/429"), "throttle: a /429 code")
        expect(!d.isThrottleCode(nil) && !d.isThrottleCode("http-response/jobs/4290")
               && !d.isThrottleCode("http-response/jobs/503"), "throttle: nothing else")
        expectEqual(d.boundedCount(-4), 0, "count: never negative")
        expectEqual(d.boundedCount(123_456), d.maximumCount, "count: capped")
    }

    static func codeHistory() {
        var history = NativeSupportCodeHistory()
        history.record(context: "pushQueue", code: "http-response/jobs/429")
        history.record(context: "pushQueue", code: "http-response/jobs/429")
        history.record(context: "customerSave riley.secret@example.com", code: "push/sk_live_51Habc123DEF456")
        expectEqual(history.entries.map { "\($0.context) \($0.code) \($0.count)" },
                    ["pushQueue http-response/jobs/429 2", "unrecognized unrecognized 1"],
                    "history: a repeat merges; an unbounded context or code is replaced")
        for index in 0..<(NativeSupportDiagnostics.maximumRecentCodes + 4) {
            history.record(context: "site\(index % 2)", code: "code/\(index)")
        }
        expectEqual(history.entries.count, NativeSupportDiagnostics.maximumRecentCodes, "history: bounded")
        expectEqual(history.omittedCount, 6, "history: the dropped oldest entries are counted")
        expectEqual(history.entries.last?.code, "code/\(NativeSupportDiagnostics.maximumRecentCodes + 3)", "history: newest last")
        var busy = NativeSupportCodeHistory()
        for _ in 0..<(NativeSupportDiagnostics.maximumCount + 5) { busy.record(context: "pullRemote", code: "pull/jobs/429") }
        expectEqual(busy.entries.first?.count, NativeSupportDiagnostics.maximumCount, "history: a repeat count is capped")
    }

    static func syncMonitorRules() {
        var monitor = NativeSyncMonitor()
        let now = Date()
        var throttled = NativeSyncStatus()
        throttled.pendingCount = 4
        throttled.lastOutcome = .partial(pushed: 0, remaining: 4, authRefreshed: false)
        throttled.diagnosticCode = "http-response/jobs/429"
        expectEqual(monitor.recordPass(throttled, oldestPendingAt: nil, now: now), [], "monitor: one throttled pass")
        expectEqual(monitor.recordPass(throttled, oldestPendingAt: nil, now: now), [], "monitor: two")
        expectEqual(monitor.recordPass(throttled, oldestPendingAt: nil, now: now), [.throttled(passes: 3)], "monitor: three in a row")
        expectEqual(monitor.recordPass(throttled, oldestPendingAt: nil, now: now), [], "monitor: once per streak")
        expect(monitor.throttledPassCount == 4 && monitor.consecutiveThrottledPasses == 4
               && monitor.maxConsecutiveThrottledPasses == 4, "monitor: the counters")
        var offline = NativeSyncStatus()
        offline.lastOutcome = .offline
        expectEqual(monitor.recordPass(offline, oldestPendingAt: now.addingTimeInterval(-90_000), now: now), [],
                    "monitor: an early exit is not a network pass")
        expectEqual(monitor.consecutiveThrottledPasses, 4, "monitor: an early exit leaves the streak")
        // Review fix 1 (Important 1): a pass whose coalesced rerun ended early
        // (offline, backoff) still reports the first run's discards.
        var deferredAfterDrop = NativeSyncStatus()
        deferredAfterDrop.lastOutcome = .backoffDeferred
        deferredAfterDrop.discardedCount = 1
        deferredAfterDrop.discardedTable = "jobs"
        expectEqual(monitor.recordPass(deferredAfterDrop, oldestPendingAt: now.addingTimeInterval(-90_000), now: now),
                    [.discarded(table: "jobs", count: 1)],
                    "monitor: a discard is reported even when the pass ended on an early exit (no age signal)")
        expect(monitor.discardedChangeCount == 1 && monitor.consecutiveThrottledPasses == 4,
               "monitor: …counted, and the early exit still leaves the streak")
        var failed = NativeSyncStatus()
        failed.pendingCount = 4
        failed.lastOutcome = .failed(remaining: 4)
        failed.diagnosticCode = "push/unavailable"
        expectEqual(monitor.recordPass(failed, oldestPendingAt: nil, now: now), [], "monitor: a failure that is not a 429")
        expect(monitor.consecutiveThrottledPasses == 0 && monitor.maxConsecutiveThrottledPasses == 4,
               "monitor: any other network pass ends the streak; the maximum stays")

        var dropped = NativeSyncStatus()
        dropped.pendingCount = 3
        dropped.lastOutcome = .completed(pushed: 1, authRefreshed: false)
        dropped.discardedCount = 2
        dropped.discardedTable = "customer_notes"
        expectEqual(monitor.recordPass(dropped, oldestPendingAt: now.addingTimeInterval(-90_000), now: now),
                    [.discarded(table: "customer_notes", count: 2), .pendingAge(count: 3)],
                    "monitor: a pass that discarded changes, with a change queued over a day")
        expectEqual(monitor.recordPass(dropped, oldestPendingAt: now.addingTimeInterval(-90_000), now: now),
                    [.discarded(table: "customer_notes", count: 2)],
                    "monitor: every discard reports; the age reports once")
        expectEqual(monitor.discardedChangeCount, 5, "monitor: discards are totalled")
        _ = monitor.recordPass(failed, oldestPendingAt: now.addingTimeInterval(-60), now: now)
        expectEqual(monitor.recordPass(failed, oldestPendingAt: now.addingTimeInterval(-90_000), now: now),
                    [.pendingAge(count: 4)], "monitor: a fresh oldest change re-arms the age signal")

        _ = monitor.recordPass(throttled, oldestPendingAt: nil, now: now)
        monitor.resetForAccountBoundary()
        expect(monitor.consecutiveThrottledPasses == 0 && monitor.throttledPassCount == 5
               && monitor.discardedChangeCount == 5, "monitor: an account boundary ends the streak and keeps the totals")
        _ = monitor.recordPass(throttled, oldestPendingAt: nil, now: now)
        _ = monitor.recordPass(throttled, oldestPendingAt: nil, now: now)
        expectEqual(monitor.recordPass(throttled, oldestPendingAt: nil, now: now), [.throttled(passes: 3)],
                    "monitor: the next account's streak reports again")
    }

    static func legacyFileProtectionTally() {
        let tally = Canonical.SnapshotRepository.LegacyFileProtectionTally()
        tally.record(.completed(protected: 3, failed: 2))
        tally.record(.enumeratorUnavailable)
        tally.record(.completed(protected: 4, failed: 0))
        let summary = tally.summary
        expect(summary.checks == 3 && summary.enumeratorUnavailable == 1 && summary.lastProtected == 4
               && summary.lastFailed == 0 && summary.failedTotal == 2,
               "L267.a: the tally keeps counts only (\(summary))")
    }

    // MARK: 13. The export: bounded, closed, and free of seeded secrets

    @MainActor
    static func exportBoundsAndExclusions() throws {
        let f = Fixture("export")
        defer { f.cleanup() }
        // Secrets the device holds: a session with a JWT, and AI provider keys.
        try hostTestSecureSettingsStore().persist(LegacySecureSettings(
            providerKey: "sk_live_51Habc123DEF456",
            anthropicKey: "sk-ant-api03-secretsecretsecret",
            groqKey: "gsk_secretsecretsecretsecret",
            supabaseSession: Data(#"{"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLXJpbGV5In0.c2ln","refresh_token":"phc_refreshsecret","user":{"email":"riley.secret@example.com"}}"#.utf8)
        ))
        let store = f.launch(seed: true)
        store.scheduleBookingTestSeedSignedInOwner(subject: "user-riley", binding: hexBinding("e5"))
        var customer = Customer()
        customer.name = "Riley Secretname"
        customer.email = "riley.secret@example.com"
        customer.phone = "480-555-0100"
        customer.notes = "key sk_live_51Habc123DEF456 phc_projectkey Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2ln"
        store.upsert(customer)
        // A refused change that names the customer.
        try store.testSettleRejectedChanges(NativeMutationPushSettlement(rejected: [NativeMutationRejection(
            item: Canonical.MutationItem(
                table: "customers", op: .upsert, recordId: customer.id,
                payload: .object(["id": .string(customer.id), "name": .string("Riley Secretname"),
                                  "email": .string("riley.secret@example.com")]),
                ts: "2026-09-25T10:00:00.000Z"
            ), statusCode: 422
        )], cleared: []))
        // Document bytes in the legacy backup.
        f.write(String(repeating: "JVBERi0xLjQK", count: 20), to: "LegacyBackups/react-native-async-storage-to-v1/AsyncStorage/invoice.b64")
        // Reported errors whose text carries secrets, and a malicious sync code.
        store.reportError(["code": "push/sk_live_51Habc123DEF456", "message": "Riley Secretname riley.secret@example.com"],
                          context: ["context": "customerSave riley.secret@example.com"])
        store.reportError(fixtureError, context: ["context": "deleteAccount"])
        var status = NativeSyncStatus()
        status.pendingCount = 1
        status.lastOutcome = .failed(remaining: 1)
        status.diagnosticCode = "push/sk_live_51Habc123DEF456 riley.secret@example.com"
        pass(store, status)

        let url = try store.createPersistenceSupportReport(appVersion: "1.2.3", appBuild: "45")
        expectEqual(url.lastPathComponent, "tradeready-support-report.json", "export: the file Settings shares")
        expectEqual(url.deletingLastPathComponent().lastPathComponent, f.directory.lastPathComponent,
                    "export: written next to store.json")
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        expect(data.count <= NativeSupportDiagnostics.maximumReportBytes,
               "export: within the \(NativeSupportDiagnostics.maximumReportBytes)-byte cap (\(data.count))")
        assertNoSecrets(text, "export")
        for value in [customer.id, hexBinding("e5"), "480-555-0100", f.directory.path, "rk_", "access_token"] {
            expect(!text.contains(value), "export: never carries '\(value.prefix(24))'")
        }

        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        expectEqual(Set(json.keys), reportKeys["top"]!, "export: the closed top-level schema")
        for key in ["app", "launchMigration", "accountBoundary", "sync", "widgets", "legacyBackupProtection", "persistence"] {
            expectEqual(Set(section(json, key).keys), reportKeys[key]!, "export: the closed \(key) schema")
        }
        for step in (section(json, "accountBoundary")["boundarySteps"] as? [[String: Any]]) ?? [] {
            expectEqual(Set(step.keys), reportKeys["boundaryStep"]!, "export: the closed boundary-step schema")
        }
        let recent = (section(json, "sync")["recentCodes"] as? [[String: Any]]) ?? []
        for entry in recent {
            expectEqual(Set(entry.keys), reportKeys["recentCode"]!, "export: the closed recent-code schema")
        }
        expectEqual(json["reportSchemaVersion"] as? Int, 3, "export: schema 3")
        expectEqual(section(json, "persistence")["reportSchemaVersion"] as? Int, 2, "export: the persistence part is the v2 report")
        expectEqual(section(json, "app")["version"] as? String, "1.2.3", "export: app version")
        expectEqual(section(json, "app")["build"] as? String, "45", "export: build")
        expectEqual(section(json, "persistence")["appVersion"] as? String, "1.2.3", "export: the v2 part's version")
        expect(((section(json, "persistence")["recordCounts"] as? [String: Any])?["customers"] as? Int ?? 0) >= 1,
               "export: record counts, not records")
        expectEqual(json["persistenceUnavailableCode"] as? String, "none", "export: persistence was readable")
        let sync = section(json, "sync")
        expectEqual(sync["diagnosticCode"] as? String, "unrecognized", "export: a malicious sync code is replaced")
        expectEqual(sync["lastOutcome"] as? String, "failed", "export: the last outcome")
        expectEqual(sync["rejectedChangeCount"] as? Int, 1, "export: the I2 rejected count")
        let codes = recent.map { "\($0["context"] as? String ?? "?") \($0["code"] as? String ?? "?") \($0["count"] as? Int ?? -1)" }
        expect(codes.contains("pushRejected rejected/customers/422 1"), "export: the refusal's code (\(codes))")
        expect(codes.contains("unrecognized unrecognized 1"), "export: a reported secret is replaced (\(codes))")
        expect(codes.contains("deleteAccount com.example.Fixture/7 1"), "export: an error is its domain and code (\(codes))")
        expect(codes.contains("pushQueue unrecognized 1"), "export: the malicious sync code is replaced in the history (\(codes))")

        // A version or build that is not a bounded code is replaced.
        let hostile = try reportJSON(store, version: "1.2.3 (riley.secret@example.com)", build: "45\nBearer abc")
        expectEqual(section(hostile.json, "app")["version"] as? String, "unrecognized", "export: a hostile version")
        expectEqual(section(hostile.json, "app")["build"] as? String, "unrecognized", "export: a hostile build")
        expectEqual(section(hostile.json, "persistence")["appVersion"] as? String, "unrecognized", "export: …in the v2 part too")

        // An unreadable snapshot still exports everything else.
        f.write("{not json", to: "store.json")
        try? FileManager.default.removeItem(at: f.storeURL.appendingPathExtension("backup"))
        let broken = try reportJSON(store)
        expect(broken.json["persistence"] is NSNull, "export: an unreadable snapshot exports null persistence")
        let unavailable = broken.json["persistenceUnavailableCode"] as? String ?? "none"
        expect(unavailable != "none" && NativeSupportDiagnostics.sanitizedCode(unavailable) == unavailable,
               "export: …with a bounded code (\(unavailable))")
        expectEqual(Set(broken.json.keys), reportKeys["top"]!, "export: the same closed schema")
    }

    @MainActor
    static func reportEncodingCap() throws {
        let f = Fixture("cap")
        defer { f.cleanup() }
        let store = f.launch()
        var report = store.supportReport(appVersion: "1.0", appBuild: "1")
        var history = NativeSupportCodeHistory()
        for index in 0..<NativeSupportDiagnostics.maximumRecentCodes {
            history.record(context: "pullRemote", code: "pull/table\(index)/http_500")
        }
        report.sync.recentCodes = history.entries
        let full = try NativeSupportDiagnostics.encode(report)
        expect(full.count <= NativeSupportDiagnostics.maximumReportBytes, "cap: a full history fits the cap (\(full.count))")
        let tight = try NativeSupportDiagnostics.encode(report, maximumBytes: full.count - 1)
        let decoded = (try JSONSerialization.jsonObject(with: tight) as? [String: Any]) ?? [:]
        let kept = (section(decoded, "sync")["recentCodes"] as? [[String: Any]]) ?? []
        expect(tight.count <= full.count - 1, "cap: over the cap, the oldest codes are dropped")
        expectEqual(kept.last?["code"] as? String, "pull/table\(NativeSupportDiagnostics.maximumRecentCodes - 1)/http_500",
                    "cap: the newest code is kept")
        expectEqual(section(decoded, "sync")["recentCodesOmitted"] as? Int,
                    NativeSupportDiagnostics.maximumRecentCodes - kept.count, "cap: the drop is counted")
        do {
            _ = try NativeSupportDiagnostics.encode(report, maximumBytes: 200)
            expect(false, "cap: a report that cannot fit throws")
        } catch NativeSupportDiagnosticsError.reportTooLarge {
        } catch {
            expect(false, "cap: the too-large error (\(error))")
        }
    }

    // MARK: 14. Boundary and migration state in the report

    @MainActor
    static func boundaryStateInReport() throws {
        do {
            let f = Fixture("report-undecodable")
            defer { f.cleanup() }
            f.write(#"{"schemaVersion":1,"scope":"galaxy"}"#, to: "store.json.account-scrub-pending")
            let store = f.launch()
            let boundary = section(try reportJSON(store).json, "accountBoundary")
            expectEqual(boundary["scrubPending"] as? Bool, true, "boundary: the marker is pending")
            expectEqual(boundary["scrubPendingScope"] as? String, "undecodable", "boundary: an undecodable marker, as a code")
            expectEqual(boundary["scrubBlocked"] as? Bool, true, "boundary: blocked")
            expectEqual(boundary["scrubBlockedScope"] as? String, "unknown", "boundary: the blocked scope is unknown")
            expectEqual(boundary["scrubBlockedCount"] as? Int, 1, "boundary: one blocked attempt")
            expectEqual(boundary["deletionRecord"] as? String, "absent", "boundary: no deletion record")
            expectEqual(boundary["workspaceClearedRecord"] as? Bool, false, "boundary: no cleared record")
        }
        do {
            let f = Fixture("report-unreadable")
            defer { f.cleanup() }
            // A marker that exists but cannot be read.
            try FileManager.default.createDirectory(
                at: f.directory.appendingPathComponent("store.json.account-scrub-pending"), withIntermediateDirectories: true
            )
            let store = f.launch()
            let boundary = section(try reportJSON(store).json, "accountBoundary")
            expectEqual(boundary["scrubPendingScope"] as? String, "unreadable", "boundary: an unreadable marker, as a code")
        }
        do {
            // P12-006: a deletion recorded in the Keychain; the widget wipe is
            // blocked, and a widget step was left pending by an earlier session.
            let f = Fixture("report-deletion")
            defer { f.cleanup() }
            try hostTestSecureSettingsStore().recordAccountDeletionScrub()
            f.write(#"{"schemaVersion":1}"#, to: "store.json.widget-scrub-pending")
            let store = f.launch(blockedScrubber: true)
            expectEqual(f.captures(), [signal(
                "account-scrub/blocked/all", "Account cleanup could not finish", context: "accountScrub",
                extras: ["operation": "launch", "count": 1]
            )], "boundary: the recorded deletion blocked at launch reports its scope")
            let boundary = section(try reportJSON(store).json, "accountBoundary")
            expectEqual(boundary["deletionPendingWithoutMarker"] as? Bool, true, "boundary: the P12-006 flag")
            expectEqual(boundary["deletionRecord"] as? String, "present", "boundary: the Keychain record's presence only")
            expectEqual(boundary["scrubPendingScope"] as? String, "all", "boundary: the pending scope")
            expectEqual(boundary["scrubBlockedScope"] as? String, "all", "boundary: the blocked scope")
            expectEqual(boundary["cleanupPending"] as? Bool, true, "boundary: the cleanup banner's state")
            let steps = (boundary["boundarySteps"] as? [[String: Any]]) ?? []
            expectEqual(steps.map { "\($0["step"] as? String ?? "?") \($0["pending"] as? Bool ?? false)" },
                        ["widget-scrub-pending true", "ai-key-wipe-pending false", "rejected-changes-scrub-pending false"],
                        "boundary: every step's pending flag")
        }
    }

    @MainActor
    static func launchMigrationInReport() throws {
        do {
            let f = Fixture("report-migration-failed")
            defer { f.cleanup() }
            let store = f.launch(migrate: true, provider: { throw fixtureError })
            let migration = section(try reportJSON(store).json, "launchMigration")
            expectEqual(migration["lastOutcome"] as? String, "failed", "migration report: failed")
            expectEqual(migration["lastOperation"] as? String, "launch", "migration report: at launch")
            expectEqual(migration["lastFailureCode"] as? String, "com.example.Fixture/7", "migration report: the code only")
            expectEqual(migration["notice"] as? String, "failed", "migration report: the notice")
            expectEqual(migration["blocked"] as? Bool, true, "migration report: blocked")
            expectEqual(migration["persistenceBlockReason"] as? String, "legacy-migration", "migration report: the block reason")
        }
        do {
            let f = Fixture("report-missing")
            defer { f.cleanup() }
            f.completeMigrationJournal()
            let source = f.emptySource()
            let store = f.launch(migrate: true, provider: { source })
            store.retryLegacyMigration()
            let json = try reportJSON(store).json
            let migration = section(json, "launchMigration")
            expectEqual(migration["lastOutcome"] as? String, "missing-migrated-snapshot", "migration report: missing snapshot")
            expectEqual(migration["lastOperation"] as? String, "retry", "migration report: after Try again")
            expectEqual(migration["persistenceBlockReason"] as? String, "missing-migrated-snapshot", "migration report: blocked")
            let statuses = (section(json, "persistence")["migrationStatuses"] as? [[String: Any]]) ?? []
            expect(statuses.contains { $0["migration"] as? String == "react-native-async-storage-to-v1" && $0["status"] as? String == "completed" },
                   "migration report: the journal state")
        }
        do {
            // P12-003 steady state, with the L267.a re-protect unable to list
            // the published backup (a nil enumerator).
            let f = Fixture("report-steady")
            defer { f.cleanup() }
            f.completeMigrationJournal()
            f.write(#"{"schemaVersion":1}"#, to: "store.json.account-scrub-cleared")
            f.write("{}", to: "LegacyBackups/react-native-async-storage-to-v1/AsyncStorage/manifest.json")
            let repository = Canonical.SnapshotRepository(primaryURL: f.storeURL, legacyFileEnumerator: { _ in nil })
            let store = f.launch(migrate: true, provider: { throw fixtureError }, repository: repository)
            let json = try reportJSON(store).json
            expectEqual(section(json, "launchMigration")["lastOutcome"] as? String, "not-attempted",
                        "steady state report: nothing was attempted")
            expectEqual(section(json, "accountBoundary")["workspaceClearedRecord"] as? Bool, true,
                        "steady state report: the P12-003 record's presence")
            let protection = section(json, "legacyBackupProtection")
            expect(protection["checks"] as? Int == 1 && protection["enumeratorUnavailable"] as? Int == 1
                   && protection["failedFileTotal"] as? Int == 0,
                   "L267.a: the launch re-protect's failure is counted (\(protection))")
            expectEqual(f.captures(), [], "steady state report: still silent")
        }
    }

    // MARK: 15. TH-5: a discarded change reports

    @MainActor
    static func discardedSignal() {
        let f = Fixture("discarded")
        defer { f.cleanup() }
        let store = f.launch()
        f.clear()
        var status = NativeSyncStatus()
        status.lastOutcome = .completed(pushed: 1, authRefreshed: false)
        status.lastPullResult = .completed
        status.diagnosticCode = "record-contract/jobs"
        status.discardedCount = 1
        status.discardedTable = "jobs"
        pass(store, status)
        expectEqual(f.captures(), [signal(
            "record-contract/jobs", "Sync push dropped unsendable changes", context: "pushDiscarded",
            extras: ["collection": "jobs", "count": 1]
        )], "discarded: a completed pass that dropped a change reports it (TH-5)")
    }

    /// Review fix 1 (Important 1): the coordinator runs a trigger that
    /// arrived mid-pass as a rerun inside the same pass, and the pass's status
    /// then carries the rerun's outcome. After a partial push the rerun is
    /// backoff-deferred, so the pass ends `.backoffDeferred` with the first
    /// run's discard still counted: it must report exactly once.
    @MainActor
    static func coalescedPassDiscardSignal() async {
        let f = Fixture("coalesced-discard")
        defer { f.cleanup() }
        let store = f.launch()
        store.scheduleBookingTestSeedSignedInOwner(subject: "dry-run-subject", binding: hexBinding("f3"))
        let queue = Canonical.NativeMutationQueue(fileURL: f.queueURL)
        var mismatch = queuedItem("coalesced-mismatch", age: 60)
        mismatch.payload = .object(["id": .string("DIFFERENT")])
        do {
            try queue.save([queuedItem("coalesced-ok", age: 60), queuedItem("coalesced-throttled", age: 60), mismatch])
        } catch {
            expect(false, "coalesced: the queue was written (\(error))")
        }
        final class Throttle: @unchecked Sendable { var on = true }
        let throttle = Throttle()
        let link = DryRunLink { throttle.on && $0.contains("coalesced-throttled") ? 429 : 201 }
        let coordinator = dryRunCoordinator(store, queue: queue, link: link)
        var midPass: NativeSyncOutcome?
        link.duringFirstRequest = { midPass = await coordinator.sync(trigger: .foreground) }
        f.clear()

        let outcome = await coordinator.sync(trigger: .manual)
        let status = coordinator.status()
        expectEqual(midPass, .alreadyRunning, "coalesced: sanity: the mid-pass trigger was coalesced")
        expectEqual(outcome, .backoffDeferred, "coalesced: sanity: the rerun was deferred by the backoff")
        expect(status.discardedCount == 1 && status.discardedTable == "jobs" && queue.load().count == 1,
               "coalesced: sanity: the first run discarded one change and kept the throttled one (\(status))")
        let discardReports = f.captures().filter { $0.context == "pushDiscarded" }
        expectEqual(discardReports, [signal(
            "record-contract/jobs", "Sync push dropped unsendable changes", context: "pushDiscarded",
            extras: ["collection": "jobs", "count": 1]
        )], "coalesced: the discard reports exactly once although the pass ended deferred (TH-5)")
        let afterFirst = section((try? reportJSON(store))?.json ?? [:], "sync")
        expectEqual(afterFirst["discardedChangeCount"] as? Int, 1, "coalesced: the report counts the discard once")

        // The next pass drains the throttled change: no discard, no new report.
        throttle.on = false
        f.clear()
        _ = await coordinator.sync(trigger: .manual)
        expectEqual(f.captures().filter { $0.context == "pushDiscarded" }, [],
                    "coalesced: a later pass does not report the earlier discard again")
        let afterSecond = section((try? reportJSON(store))?.json ?? [:], "sync")
        expectEqual(afterSecond["discardedChangeCount"] as? Int, 1, "coalesced: …and the count stays 1")
    }

    // MARK: 16. Dry run on synthetic fixtures (12.02 deliverable)

    @MainActor
    static func dryRun() async throws {
        print("DRY-RUN: 12.02 synthetic fixtures (host only, stub link on dry-run.invalid, no network)")

        do {
            let f = Fixture("dry-migration")
            defer { f.cleanup() }
            let store = f.launch(migrate: true, provider: { throw fixtureError })
            for capture in f.captures() {
                print("DRY-RUN: failed migration -> sentry context=\(capture.context ?? "?") title=\(capture.title ?? "?")")
            }
            let report = try reportJSON(store)
            print("DRY-RUN: failed migration -> report launchMigration=\(canonicalJSON(section(report.json, "launchMigration")))")
            expectEqual(f.captures().map(\.context), ["legacyMigration"], "dry run: the failed migration reports")
        }

        do {
            let f = Fixture("dry-poison")
            defer { f.cleanup() }
            let store = f.launch()
            store.scheduleBookingTestSeedSignedInOwner(subject: "dry-run-subject", binding: hexBinding("f1"))
            let queue = Canonical.NativeMutationQueue(fileURL: f.queueURL)
            var mismatch = queuedItem("dry-mismatch", age: 60)
            mismatch.payload = .object(["id": .string("DIFFERENT"), "title": .string("Riley Secretname's panel")])
            try queue.save([queuedItem("dry-ok", age: 60), queuedItem("dry-refused", age: 60), mismatch])
            let link = DryRunLink { $0.contains("dry-refused") ? 422 : 201 }
            let coordinator = dryRunCoordinator(store, queue: queue, link: link)
            f.clear()
            let outcome = await coordinator.sync(trigger: .manual)
            let status = coordinator.status()
            print("DRY-RUN: poison item -> outcome=\(outcome) requests=\(link.requests) code=\(status.diagnosticCode ?? "none") discarded=\(status.discardedCount) queued=\(queue.load().count)")
            for capture in f.captures() {
                print("DRY-RUN: poison item -> sentry context=\(capture.context ?? "?") title=\(capture.title ?? "?") extras=\(capture.extras)")
            }
            let report = try reportJSON(store)
            let sync = section(report.json, "sync")
            print("DRY-RUN: poison item -> report rejectedChangeCount=\(sync["rejectedChangeCount"] ?? "?") discardedChangeCount=\(sync["discardedChangeCount"] ?? "?")")
            expectEqual(f.captures().map(\.context), ["pushRejected", "pushDiscarded"],
                        "dry run: the refused change (I2) and the unsendable one (TH-5) each report")
            expect(queue.load().isEmpty, "dry run: neither stays queued")
            expectEqual(store.rejectedChanges.count, 1, "dry run: the refused change waits in Cloud Sync")
            expect(sync["discardedChangeCount"] as? Int == 1 && sync["rejectedChangeCount"] as? Int == 1,
                   "dry run: the report counts both")
            assertNoSecrets(report.json.description + "\(f.captures())", "dry run poison")
        }

        do {
            let f = Fixture("dry-429")
            defer { f.cleanup() }
            let store = f.launch()
            store.scheduleBookingTestSeedSignedInOwner(subject: "dry-run-subject", binding: hexBinding("f2"))
            let queue = Canonical.NativeMutationQueue(fileURL: f.queueURL)
            try queue.save([queuedItem("dry-a", age: 60), queuedItem("dry-b", table: "invoices", age: 60)])
            let link = DryRunLink { _ in 429 }
            let coordinator = dryRunCoordinator(store, queue: queue, link: link)
            f.clear()
            for index in 1...3 {
                let before = link.requests
                let outcome = await coordinator.sync(trigger: .manual)
                print("DRY-RUN: 429 burst pass \(index) -> outcome=\(outcome) pushRequests=\(link.requests - before) code=\(coordinator.status().diagnosticCode ?? "none")")
            }
            for capture in f.captures() {
                print("DRY-RUN: 429 burst -> sentry context=\(capture.context ?? "?") title=\(capture.title ?? "?")")
            }
            let sync = section(try reportJSON(store).json, "sync")
            print("DRY-RUN: 429 burst -> report throttledPassCount=\(sync["throttledPassCount"] ?? "?") consecutiveThrottledPasses=\(sync["consecutiveThrottledPasses"] ?? "?") pendingCount=\(sync["pendingCount"] ?? "?")")
            expectEqual(link.requests, 6, "dry run: each throttled pass sends every queued change once (N = 2)")
            expectEqual(f.captures().map(\.context), ["pushQueue", "pushQueue", "pushQueue", "syncThrottle"],
                        "dry run: three throttled passes report each pass and one burst")
            expectEqual(sync["consecutiveThrottledPasses"] as? Int, 3, "dry run: the report shows the streak")
        }

        do {
            let f = Fixture("dry-crash")
            defer { f.cleanup() }
            let store = f.launch()
            f.clear()
            store.reportError(fixtureError, context: ["context": "deleteAccount"])
            for capture in f.captures() {
                print("DRY-RUN: crash-style error -> sentry context=\(capture.context ?? "?") domain=\(capture.domain) extras=\(capture.extras)")
            }
            // What the Sentry adapter's beforeSend does to a crash event.
            var event = NativeCrashEventPayload()
            event.message = "Fatal: could not open /Users/riley/Library/secret.sqlite for riley.secret@example.com"
            event.exceptions = [.init(type: "NSInvalidArgumentException",
                                      value: "unrecognized selector; token sk_live_51Habc123DEF456",
                                      mechanismDescription: nil, mechanismData: nil)]
            event.user = .init(id: "11111111-2222-3333-4444-555555555555", email: "riley.secret@example.com",
                               username: nil, ipAddress: "10.0.0.1", name: "Riley Secretname", data: nil)
            let redacted = canonicalJSON(NativeErrorRedaction.standard.redactEvent(event).jsonObject)
            print("DRY-RUN: crash event -> redacted=\(redacted)")
            // Finding (12.02 dry run): the Phase 11 redaction (contract §10.3)
            // has no file-path rule, so a crash message keeps a path. On iOS
            // that is the app container (`/private/var/mobile/Containers/...`),
            // with no user name; the monitoring doc records it as a follow-up.
            // Every other seeded secret must be gone.
            print("DRY-RUN: finding -> the crash message keeps its file path: \(redacted.contains("/Users/"))")
            for fragment in secretFragments where fragment != "/Users/" && redacted.contains(fragment) {
                expect(false, "dry run crash event: never carries '\(fragment)'")
            }
            let report = try reportJSON(store)
            print("DRY-RUN: crash-style error -> report recentCodes=\(canonicalJSON(section(report.json, "sync")["recentCodes"] ?? []))")
            print("DRY-RUN: report -> bytes=\(report.bytes) cap=\(NativeSupportDiagnostics.maximumReportBytes) sections=\(report.json.keys.sorted())")
            expect(report.bytes <= NativeSupportDiagnostics.maximumReportBytes, "dry run: the report is within the cap")
        }
    }
}
