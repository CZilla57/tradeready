import CryptoKit
import Foundation

// Phase 12 (12.00b.2-F, charter G6-Q1, P12-001) host tests. The rule: after
// a PERMANENT account deletion nothing from that account may be re-imported,
// so the deletion (`.all`) scrub erases the React Native sources the launch
// migration reads (`NativeLegacySourceEraser`). A sign-out, the recovery
// exits and the account switch keep them for the Expo rollback build (G6),
// and the completed journal stops a second import. Each scenario builds a
// fixture device (AsyncStorage manifest, Documents photo, legacy SecureStore
// items, App Group values) in a temp directory, migrates it with the real
// launch path, crosses one account boundary with the real AppStore code, and
// relaunches on the same files. Nothing here reads or writes the real
// Keychain, App Group, Documents or network.
// Phase 12 (12.00b.2-G, P12-003): the launch after a sign-out on a migrated
// device is an ordinary signed-out launch (section 2). P12-004 and the Task 9b
// review items M2 and M3: every scrub path clears the same stores, an
// unreadable scrub marker fails closed, and scene activation retries a
// pending scrub (sections 1 and 5).
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
        .appendingPathComponent("tradeready-reimport-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

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

/// A throwaway App Group suite: a host test never touches the real one.
struct TempAppGroup {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL

    init(_ label: String) {
        suiteName = "com.tradeready.legacy-reimport.tests.\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = tempDirectory("group-\(label)")
    }

    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(
            suiteName: suiteName, defaults: defaults,
            lockFile: directory.appendingPathComponent(WidgetAppGroup.lockFileName)
        )
    }

    /// A file where the lock's directory goes: the scrub's App Group step
    /// fails (`WidgetAppGroupLock` cannot create the directory).
    func blockLock() throws {
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
    }

    func unblockLock() throws {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The legacy Expo SecureStore services the importer reads, in memory. It
/// is also the eraser's secure store, and fails on demand (a locked device).
final class FakeLegacySecureStore: LegacySecureStoreServiceErasing {
    var services: [String: [String: Data]] = [:]
    var failRemove = false
    var failRead = false
    /// A delete that reports success but leaves the items.
    var ignoreRemove = false

    func removeAllItems(service: String) throws {
        if failRemove { throw NativeLegacySourceEraseError.secureStoreUnavailable(status: -25308) }
        if ignoreRemove { return }
        services[service] = nil
    }

    func hasItems(service: String) throws -> Bool {
        if failRead { throw NativeLegacySourceEraseError.secureStoreUnavailable(status: -25308) }
        return !(services[service]?.isEmpty ?? true)
    }

    /// Inventories in `LegacyDataImporter.legacySecureStoreServices` order,
    /// exactly what `readSecureSettings` reads from the Keychain.
    var inventories: [[String: Data]] {
        LegacyDataImporter.legacySecureStoreServices.map { services[$0] ?? [:] }
    }

    var legacyItemCount: Int {
        LegacyDataImporter.legacySecureStoreServices.reduce(0) { $0 + (services[$1]?.count ?? 0) }
    }
}

/// Fixture sessions: opaque bytes, never a real token.
let sessionA = Data(#"{"access_token":"fixture-access-a","refresh_token":"fixture-refresh-a","user":{"id":"user-a"}}"#.utf8)
let sessionB = Data(#"{"access_token":"fixture-access-b","refresh_token":"fixture-refresh-b","user":{"id":"user-b"}}"#.utf8)
let providerKeyA = "fixture-provider-key-a"

/// Answers `/auth/v1/user` for the two fixture sessions.
struct FixtureVerifier: NativeAuthenticatedIdentityVerifying {
    func verify(sessionBytes: Data) async throws -> NativeVerifiedAuxiliaryIdentity {
        switch sessionBytes {
        case sessionA: return try NativeVerifiedAuxiliaryIdentity(opaqueSubject: "user-a", email: "a@example.invalid")
        case sessionB: return try NativeVerifiedAuxiliaryIdentity(opaqueSubject: "user-b", email: "b@example.invalid")
        default: throw NativeAuthenticatedIdentityError.rejectedSession
        }
    }
}

struct FixtureBindingProvider: NativeAuxiliaryAccountBindingProviding {
    func keyedBinding(for opaqueSubject: String) throws -> Data {
        Data(SHA256.hash(data: Data("fixture-binding|\(opaqueSubject)".utf8)))
    }
}

/// One installation that ran the Expo app as account A, then upgraded.
@MainActor
final class FixtureDevice {
    let root: URL
    let locations: LegacySourceLocations
    let storeURL: URL
    let group: TempAppGroup
    let legacySecureStore = FakeLegacySecureStore()

    /// `ownerKeys`: the RN app also wrote account-scoped keys and the
    /// `__dataOwner` marker (an owner that finished an initial sync).
    init(_ label: String, ownerKeys: Bool) throws {
        root = tempDirectory(label)
        locations = LegacySourceLocations(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("AppSupport", isDirectory: true),
            documentsDirectory: root.appendingPathComponent("Documents", isDirectory: true),
            bundleID: "com.gettradereadyapp.tradeready"
        )
        storeURL = root.appendingPathComponent("AppSupport/TradeReadyNative/store.json")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        group = TempAppGroup(label)

        var manifest: [String: String] = [
            "customers": #"[{"id":"rn-a-1","name":"Deleted Owner Customer","email":"","phone":"","address":"","notes":""}]"#
        ]
        if ownerKeys {
            manifest["onboardingComplete"] = "true"
            manifest["__dataOwner"] = #""user-a""#
        }
        try writeManifest(manifest)
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture-photo-a".utf8).write(to: photoURL)
        try Data("not the app's".utf8).write(to: unrelatedDocumentURL)
        legacySecureStore.services["app:no-auth"] = [
            LegacyDataImporter.supabaseSessionKey: sessionA,
            "groqKey": Data(providerKeyA.utf8)
        ]
        legacySecureStore.services["com.example.unrelated"] = ["other": Data("kept".utf8)]
        group.defaults.set(#"{"schemaVersion":1}"#, forKey: "widgetSnapshot")
    }

    var asyncStorageDirectory: URL { locations.asyncStorageCandidates[0] }
    var manifestURL: URL { asyncStorageDirectory.appendingPathComponent("manifest.json") }
    var photoURL: URL { locations.documentsDirectory.appendingPathComponent("photos/orphan-a.jpg") }
    var unrelatedDocumentURL: URL { locations.documentsDirectory.appendingPathComponent("unrelated.txt") }
    var appDirectory: URL { storeURL.deletingLastPathComponent() }
    var journal: Canonical.MigrationJournal {
        Canonical.MigrationJournal(fileURL: appDirectory.appendingPathComponent("migration-journal.json"))
    }
    var journalEntryCount: Int { (try? journal.read().entries.count) ?? -1 }
    var journalComplete: Bool { (try? journal.isComplete(.reactNativeAsyncStorage)) == true }
    var auxiliaryURL: URL { appDirectory.appendingPathComponent(NativeAuxiliaryStateStore.filename) }
    var legacyBackupsURL: URL { appDirectory.appendingPathComponent("LegacyBackups", isDirectory: true) }
    var scrubMarkerURL: URL { storeURL.appendingPathExtension("account-scrub-pending") }
    /// Phase 12 (12.00b.2-G, P12-003): the scrub's record that it cleared the
    /// live workspace (`SnapshotRepository.accountScrubClearedMarkerURL`).
    var scrubClearedMarkerURL: URL { storeURL.appendingPathExtension("account-scrub-cleared") }
    /// The record IDs in the push queue on disk (what a sync would send).
    var queuedRecordIDs: [String] {
        Canonical.NativeMutationQueue(fileURL: appDirectory.appendingPathComponent("mutation-queue.json"))
            .load().map(\.recordId)
    }

    func writeManifest(_ manifest: [String: String]) throws {
        try FileManager.default.createDirectory(at: asyncStorageDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
    }

    /// What `liveSource()` would read on this device right now.
    func source() throws -> LegacyMigrationSource {
        LegacyMigrationSource.reading(
            locations,
            secureSettings: try LegacyDataImporter.secureSettings(serviceInventories: legacySecureStore.inventories),
            appGroupValues: LegacyDataImporter.readAppGroupValues(defaults: group.defaults)
        )
    }

    /// The eraser the production convenience init passes (`.live()`), on
    /// this device's locations and legacy secure store.
    var eraser: NativeLegacySourceEraser {
        NativeLegacySourceEraser(locations: locations, secureStore: legacySecureStore)
    }

    /// A cold launch of the native app on this device (the production
    /// convenience init's settings, with host-test stand-ins). The source is
    /// read when the launch migration runs, after any pending scrub, as
    /// `liveSource()` is.
    func launch(repository: Canonical.SnapshotRepository? = nil) throws -> AppStore {
        AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSourceProvider: { try self.source() },
            legacySourceEraser: eraser,
            repository: repository,
            appGroupAccountScrubber: group.scrubber,
            subscriptionService: SubscriptionStub(),
            widgetTimelineReloader: NoopReloader(),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
    }

    /// A verified outcome for `session`, from the real activator on this
    /// device's files (the one sign-in and launch activation both use).
    func signInOutcome(_ session: Data, subject: String) async throws -> NativeAuthenticatedIdentityActivationOutcome {
        try await activator().installVerifiedSession(sessionBytes: session, responseUserSubject: subject)
    }

    func launchOutcome() async throws -> NativeAuthenticatedIdentityActivationOutcome? {
        try await activator().activate()
    }

    private func activator() -> NativeAuthenticatedIdentityActivator {
        NativeAuthenticatedIdentityActivator(
            snapshotURL: storeURL,
            sessionStore: hostTestSecureSettingsStore(),
            verifier: FixtureVerifier(),
            bindingProvider: FixtureBindingProvider()
        )
    }

    func cleanUp() {
        group.cleanUp()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Every scenario starts from an empty in-memory Keychain.
func resetHostKeychain() {
    try? hostTestSecureSettingsStore().clearAllValues()
}

func nativeSession() -> Data? {
    (try? hostTestSecureSettingsStore().readSupabaseSession()) ?? nil
}

func nativeProviderKey() -> Data? {
    (try? HostInMemoryKeychain.shared.read(key: "groqKey")) ?? nil
}

func isMigratedNotice(_ notice: LegacyLaunchMigrationNotice?) -> Bool {
    if case .migrated? = notice { return true }
    return false
}

func isConfigurationPreflight(_ state: NativeAuthenticationGateState) -> Bool {
    if case .initialSyncUnavailable(let message) = state {
        return message.contains("preflight/configuration-or-session")
    }
    return false
}

func isLocalRecoveryPreflight(_ state: NativeAuthenticationGateState, _ reason: String) -> Bool {
    if case .initialSyncUnavailable(let message) = state {
        return message.contains("preflight/local-recovery/\(reason)")
    }
    return false
}

/// The first launch after the upgrade: A's data is migrated.
@MainActor
func migrateFirstLaunch(_ device: FixtureDevice, _ label: String) throws -> AppStore {
    let store = try device.launch()
    expectEqual(store.customers.map(\.id), ["rn-a-1"], "\(label): sanity: the upgrade imports A's customer")
    expect(isMigratedNotice(store.launchMigrationNotice), "\(label): sanity: the upgrade reports a migration")
    expect(device.journalComplete, "\(label): sanity: the migration journal is complete")
    expectEqual(nativeSession(), sessionA, "\(label): sanity: A's legacy session is published to the native Keychain")
    expectEqual(nativeProviderKey(), Data(providerKeyA.utf8), "\(label): sanity: A's provider key is published")
    expect(exists(device.auxiliaryURL), "\(label): sanity: A's auxiliary state is preserved")
    return store
}

// MARK: - 1. Deletion (.all scrub), relaunch, then B

/// The deletion's scrub erases the RN sources with everything else, so the
/// next launch has nothing to import and B never meets A's data.
/// (Characterized before the fix, commit 1: the relaunch re-imported A's
/// records, owner marker, backups, session and provider key; B's sign-in
/// stopped at the account-mismatch gate, and B's launch adopted A's
/// workspace when the RN data had no owner keys.)
@MainActor
func testDeletionThenRelaunch(ownerKeys: Bool) async throws {
    let label = ownerKeys ? "deletion (RN owner keys)" : "deletion (no RN owner keys)"
    resetHostKeychain()
    let device = try FixtureDevice(ownerKeys ? "delete-owner" : "delete-plain", ownerKeys: ownerKeys)
    defer { device.cleanUp() }
    let first = try migrateFirstLaunch(device, label)

    // The local half of `deleteAccount` (its server call cannot run here).
    try first.testRunAccountDeletionLocalScrub()
    expect(!exists(device.storeURL), "\(label): the scrub removes the snapshot")
    expect(!exists(device.journal.fileURL), "\(label): the scrub removes the migration journal")
    expect(!exists(device.auxiliaryURL) && !exists(device.legacyBackupsURL),
           "\(label): the scrub removes the auxiliary state and the legacy backups")
    expect(nativeSession() == nil && nativeProviderKey() == nil, "\(label): the scrub clears the native Keychain")
    expect(LegacyDataImporter.readAppGroupValues(defaults: device.group.defaults).isEmpty,
           "\(label): the scrub wipes the App Group values")
    expect(!exists(device.asyncStorageDirectory), "\(label) [P12-001]: the scrub erases the RN AsyncStorage directory")
    expect(!exists(device.photoURL.deletingLastPathComponent()), "\(label) [P12-001]: the scrub erases the RN Documents photo directory")
    expectEqual(device.legacySecureStore.legacyItemCount, 0, "\(label) [P12-001]: the scrub erases the RN SecureStore items")
    expect(exists(device.unrelatedDocumentURL), "\(label): the scrub leaves other Documents files alone")
    expectEqual(device.legacySecureStore.services["com.example.unrelated"]?.count, 1,
                "\(label): the scrub leaves other Keychain services alone")
    expect(!first.isAccountScrubBlocked && !exists(device.storeURL.appendingPathExtension("account-scrub-pending")),
           "\(label): the scrub finishes")

    // Relaunch: nothing to import.
    let relaunched = try device.launch()
    expectEqual(relaunched.customers.map(\.id), [], "\(label) [P12-001]: the relaunch imports nothing")
    expect(relaunched.launchMigrationNotice == nil, "\(label) [P12-001]: the relaunch reports no migration")
    expect(!relaunched.isLegacyMigrationBlocked, "\(label): the relaunch is not blocked")
    expect(!exists(device.journal.fileURL), "\(label) [P12-001]: the relaunch writes no journal")
    expect(!exists(device.auxiliaryURL) && !exists(device.legacyBackupsURL),
           "\(label) [P12-001]: the relaunch re-creates no auxiliary state or legacy backup")
    expect(nativeSession() == nil, "\(label) [P12-001]: the relaunch publishes no legacy session")
    expect(nativeProviderKey() == nil, "\(label) [P12-001]: the relaunch publishes no provider key")

    // B signs in on the same launch (the interactive gate).
    let bOutcome = try await device.signInOutcome(sessionB, subject: "user-b")
    expectEqual(bOutcome.accountState, .noAuxiliaryArtifact, "\(label): B's activation finds no auxiliary state of A's")
    relaunched.testBindInteractiveOwner(bOutcome, email: "b@example.invalid")
    expect(isConfigurationPreflight(relaunched.authenticationGateState),
           "\(label) [P12-001]: B's sign-in adopts an empty workspace and heads for B's initial sync (got \(relaunched.authenticationGateState))")
    expectEqual(relaunched.customers.map(\.id), [], "\(label) [P12-001]: B sees none of A's records")
    // 12.00b.2-G (Task 9b review M1): the initial sync's completion (an empty
    // cloud here) backfills the local workspace into B's push queue once
    // (`markInitialSyncCompleted`); A's record must not be in it. Driven only
    // where the real app would reach it (the gate heads for the sync).
    if isConfigurationPreflight(relaunched.authenticationGateState) {
        relaunched.testMarkInitialSyncCompleted(subject: "user-b")
        expect(!device.queuedRecordIDs.contains("rn-a-1"),
               "\(label) [P12-001]: B's initial-sync backfill queues none of A's records (queued: \(device.queuedRecordIDs))")
    }

    // B relaunches (the launch activation, which adopts an unbound workspace).
    let bLaunch = try device.launch()
    expect(bLaunch.launchMigrationNotice == nil, "\(label): B's relaunch runs no migration")
    guard let bLaunchOutcome = try await device.launchOutcome() else {
        expect(false, "\(label): B's session is stored")
        return
    }
    expectEqual(bLaunchOutcome.verifiedUserSubject, "user-b", "\(label): the launch verifies B")
    bLaunch.testApplyLaunchIdentityOutcome(bLaunchOutcome)
    expect(isConfigurationPreflight(bLaunch.authenticationGateState),
           "\(label) [P12-001]: B's launch heads for B's initial sync over an empty workspace (got \(bLaunch.authenticationGateState))")
    expectEqual(bLaunch.customers.map(\.id), [], "\(label) [P12-001]: A's customer is not in B's local workspace")
    // The launch path's own completion (M1). Once B's backfill has run above
    // it is stamped for B and runs no second time, as in the app; the queue
    // it filled is still checked. Without the erase, the interactive gate
    // stops at account-mismatch, so this is where A's adopted record would
    // first be queued (12.00b.2-G evidence: m1-mutation-no-eraser.log).
    if isConfigurationPreflight(bLaunch.authenticationGateState) {
        bLaunch.testMarkInitialSyncCompleted(subject: "user-b")
        expect(!device.queuedRecordIDs.contains("rn-a-1"),
               "\(label) [P12-001]: B's launch-path initial-sync backfill queues none of A's records (queued: \(device.queuedRecordIDs))")
    }
}

/// A deletion whose scrub was interrupted is finished by the next launch,
/// erasing the RN sources before that launch's migration step.
@MainActor
func testPendingDeletionFinishedAtLaunch() throws {
    let label = "pending deletion"
    resetHostKeychain()
    let device = try FixtureDevice("pending-delete", ownerKeys: true)
    defer { device.cleanUp() }
    _ = try migrateFirstLaunch(device, label)
    try Canonical.SnapshotRepository(primaryURL: device.storeURL).beginAccountScrub(scope: .all)

    let relaunched = try device.launch()
    expect(!relaunched.isAccountScrubBlocked, "\(label): the launch finishes the pending scrub")
    expect(!exists(device.manifestURL) && device.legacySecureStore.legacyItemCount == 0,
           "\(label) [P12-001]: the launch erases the RN sources")
    expectEqual(relaunched.customers.map(\.id), [], "\(label) [P12-001]: the same launch imports nothing")
    expect(!exists(device.journal.fileURL), "\(label) [P12-001]: the same launch writes no journal")
    expect(nativeSession() == nil, "\(label) [P12-001]: the same launch publishes no legacy session")
}

/// An erase that fails (a locked Keychain) leaves the deletion pending: the
/// relaunch keeps everything hidden and imports nothing, and a later
/// launch, or Retry, finishes it.
@MainActor
func testEraseFailureKeepsDeletionPending() async throws {
    let label = "erase failure"
    for retry in ["relaunch", "retry", "activation"] {
        resetHostKeychain()
        let device = try FixtureDevice("erase-fail-\(retry)", ownerKeys: false)
        defer { device.cleanUp() }
        let first = try migrateFirstLaunch(device, "\(label) (\(retry))")
        let marker = device.storeURL.appendingPathExtension("account-scrub-pending")

        device.legacySecureStore.failRemove = true
        var scrubThrew = false
        do { try first.testRunAccountDeletionLocalScrub() } catch { scrubThrew = true }
        expect(scrubThrew, "\(label) (\(retry)): the scrub reports the failed erase")
        expect(nativeSession() == nil, "\(label) (\(retry)): the deletion's Keychain wipe ran before the erase failed")
        expectEqual(try? Canonical.SnapshotRepository(primaryURL: device.storeURL).pendingAccountScrubScope, .all,
                    "\(label) (\(retry)): the deletion scrub stays pending")
        expectEqual(device.legacySecureStore.legacyItemCount, 2, "\(label) (\(retry)): sanity: the RN SecureStore items remain")

        let blocked = try device.launch()
        expect(blocked.isAccountScrubBlocked, "\(label) (\(retry)): the relaunch stays blocked while the erase fails")
        expectEqual(blocked.customers.map(\.id), [], "\(label) (\(retry)): the blocked relaunch imports nothing")
        expect(!exists(device.journal.fileURL), "\(label) (\(retry)): the blocked relaunch runs no migration")
        expect(nativeSession() == nil, "\(label) (\(retry)): the blocked relaunch publishes no legacy session")
        expect(exists(marker), "\(label) (\(retry)): the deletion is still pending")
        // Task 9b review M3: the blocked screen names a deletion as one.
        expectEqual(blocked.accountScrubBlockedScope, .all, "\(label) (\(retry)) [M3]: the blocked launch knows it is finishing a deletion")
        expect(blocked.migrationMessage?.contains("account deletion") == true,
               "\(label) (\(retry)) [M3]: its message says account deletion (got \(blocked.migrationMessage ?? "nil"))")

        device.legacySecureStore.failRemove = false
        let finished: AppStore
        if retry == "relaunch" {
            finished = try device.launch()
        } else if retry == "retry" {
            blocked.retryAccountScrub()
            finished = blocked
        } else {
            // 12.00b.2-G (Task 9b review M3): the next scene activation, with
            // no tap, as after a locked background launch.
            blocked.retryAccountBoundaryCleanupOnActivation()
            finished = blocked
        }
        expect(!finished.isAccountScrubBlocked && !exists(marker), "\(label) (\(retry)): the deletion finishes")
        expect(finished.accountScrubBlockedScope == nil, "\(label) (\(retry)) [M3]: nothing is left blocked")
        expectEqual(device.legacySecureStore.legacyItemCount, 0, "\(label) (\(retry)): the RN SecureStore items are erased")
        expectEqual(finished.customers.map(\.id), [], "\(label) (\(retry)): nothing is imported")

        let later = try device.launch()
        expectEqual(later.customers.map(\.id), [], "\(label) (\(retry)): a later launch imports nothing")
        expect(later.launchMigrationNotice == nil && !exists(device.journal.fileURL),
               "\(label) (\(retry)): a later launch runs no migration")
    }
}

/// The eraser itself: exactly the set the importer reads, idempotent and
/// verified.
@MainActor
func testEraser() throws {
    let root = tempDirectory("eraser")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = LegacySourceLocations(
        libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
        applicationSupportDirectory: root.appendingPathComponent("AppSupport", isDirectory: true),
        documentsDirectory: root.appendingPathComponent("Documents", isDirectory: true),
        bundleID: "com.gettradereadyapp.tradeready"
    )
    expectEqual(locations.asyncStorageCandidates.count, 6, "eraser: six AsyncStorage candidates")
    expectEqual(locations.photoDirectories.map(\.lastPathComponent), LegacyDataImporter.legacyPhotoDirectories,
                "eraser: the photo directories are the importer's")
    for directory in locations.asyncStorageCandidates + locations.photoDirectories {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("item"))
    }
    let kept = [
        locations.documentsDirectory.appendingPathComponent("unrelated.txt"),
        root.appendingPathComponent("AppSupport/TradeReadyNative/store.json"),
        root.appendingPathComponent("Library/Preferences/other.plist")
    ]
    for url in kept {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: url)
    }
    let secure = FakeLegacySecureStore()
    for service in LegacyDataImporter.legacySecureStoreServices {
        secure.services[service] = ["supabase_session": Data("s".utf8), "supabase_session_chunk_1": Data("c".utf8)]
    }
    secure.services["com.example.unrelated"] = ["other": Data("kept".utf8)]
    let eraser = NativeLegacySourceEraser(locations: locations, secureStore: secure)

    do { try eraser.erase() } catch { expect(false, "eraser: erase threw \(error)") }
    for directory in locations.asyncStorageCandidates + locations.photoDirectories {
        expect(!exists(directory), "eraser: \(directory.lastPathComponent) is erased")
    }
    expectEqual(secure.legacyItemCount, 0, "eraser: every legacy SecureStore item is erased")
    expect(kept.allSatisfy(exists), "eraser: other files are kept")
    expectEqual(secure.services["com.example.unrelated"]?.count, 1, "eraser: other Keychain services are kept")
    do { try eraser.erase() } catch { expect(false, "eraser: a second erase threw \(error)") }

    // Verification: a delete that leaves items, or an unreadable service, throws.
    secure.services["app"] = ["providerKey": Data("p".utf8)]
    secure.ignoreRemove = true
    do {
        try eraser.erase()
        expect(false, "eraser: items left after the delete are reported")
    } catch NativeLegacySourceEraseError.secureStoreItemsRemain {
    } catch { expect(false, "eraser: unexpected error \(error)") }
    secure.ignoreRemove = false
    secure.failRead = true
    do {
        try eraser.erase()
        expect(false, "eraser: an unreadable service is reported")
    } catch NativeLegacySourceEraseError.secureStoreUnavailable {
    } catch { expect(false, "eraser: unexpected error \(error)") }
    secure.failRead = false
    do { try eraser.erase() } catch { expect(false, "eraser: the retry threw \(error)") }
    expectEqual(secure.legacyItemCount, 0, "eraser: the retry erases the rest")

    // The error carries codes only.
    let described = String(describing: NativeLegacySourceEraseError.fileRemains(kind: "async-storage"))
    expect(!described.contains("/"), "eraser: an error names no path")
}

// MARK: - 2. Sign-out (.live scrub)

/// G6: a sign-out keeps the RN sources (the Expo rollback build reads them)
/// and the completed journal, so nothing is imported again. The launches
/// carry the eraser, as the app does; a sign-out never calls it.
///
/// Phase 12 (12.00b.2-G, P12-003): the relaunch after that sign-out is an
/// ordinary signed-out launch (no failed-migration notice, no write block),
/// and the next sign-in, as A or as B, heads for that account's initial sync,
/// which is where A's cloud data comes back. RN clears its local data on
/// sign-out and pulls on the next sign-in. Before the fix the relaunch
/// reported a failed migration and blocked writes, "Try again" did the same,
/// and the sign-in stopped at `preflight/local-recovery/missing-migrated-snapshot`.
@MainActor
func testSignOutThenRelaunch(ownerKeys: Bool, signer: String) async throws {
    let label = "sign-out (\(ownerKeys ? "RN owner keys" : "no RN owner keys"), then \(signer))"
    resetHostKeychain()
    let device = try FixtureDevice("signout-\(ownerKeys ? "owner" : "plain")-\(signer)", ownerKeys: ownerKeys)
    defer { device.cleanUp() }
    let first = try migrateFirstLaunch(device, label)
    let journalEntries = device.journalEntryCount

    try await first.signOut(revokeRemote: false)
    expect(!exists(device.storeURL), "\(label): the sign-out removes the snapshot")
    expect(device.journalComplete && device.journalEntryCount == journalEntries, "\(label): the completed journal is kept")
    expect(exists(device.legacyBackupsURL) && exists(device.auxiliaryURL), "\(label): the exact-owner recovery artifacts are kept")
    expect(exists(device.manifestURL) && exists(device.photoURL), "\(label): the RN files are kept for the Expo rollback build")
    expectEqual(device.legacySecureStore.legacyItemCount, 2, "\(label): the RN SecureStore items are kept for the Expo rollback build")
    expect(nativeSession() == nil, "\(label): the native session is cleared")
    expect(exists(device.scrubClearedMarkerURL), "\(label) [P12-003]: the sign-out records that it cleared the workspace")
    let clearedRecord = (try? Data(contentsOf: device.scrubClearedMarkerURL)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    expect(clearedRecord.map { Set($0.keys) == ["schemaVersion"] } == true,
           "\(label) [P12-003]: that record holds no account data")

    let relaunched = try device.launch()
    expectEqual(relaunched.customers.map(\.id), [], "\(label): the relaunch imports nothing")
    expect(relaunched.launchMigrationNotice == nil,
           "\(label) [P12-003]: the signed-out relaunch reports no failed migration (got \(String(describing: relaunched.launchMigrationNotice)))")
    expect(!relaunched.isLegacyMigrationBlocked, "\(label) [P12-003]: the signed-out relaunch does not block local writes")
    expect(!relaunched.isAccountScrubBlocked, "\(label): the signed-out relaunch has no cleanup pending")
    expectEqual(device.journalEntryCount, journalEntries, "\(label): the relaunch writes no journal entry (the importer did not run)")
    expect(device.journalComplete, "\(label) [P12-003]: the journal stays complete, so no account re-imports A's RN data")
    expect(nativeSession() == nil, "\(label): the relaunch re-publishes no legacy session")

    relaunched.retryLegacyMigration()
    expect(!relaunched.isLegacyMigrationBlocked && relaunched.launchMigrationNotice == nil,
           "\(label) [P12-003]: \"Try again\" leaves the signed-out state usable")
    expectEqual(relaunched.customers.map(\.id), [], "\(label): \"Try again\" imports nothing")
    expectEqual(device.journalEntryCount, journalEntries, "\(label): \"Try again\" writes no journal entry")

    let session = signer == "A" ? sessionA : sessionB
    let subject = signer == "A" ? "user-a" : "user-b"
    let outcome = try await device.signInOutcome(session, subject: subject)
    relaunched.testBindInteractiveOwner(outcome, email: "\(signer.lowercased())@example.invalid")
    if ownerKeys && signer == "B" {
        // Phase 3 rule ("exact legacy-owner mismatch is a blocking root
        // state"), unchanged here: the sign-out keeps A's auxiliary state for
        // A's rollback, and it names A as the owner, so B is held at the
        // account-mismatch gate. Reported by 12.00b.2-G; pinned as observed.
        expectEqual(outcome.accountState, .ownerMismatch, "\(label): A's kept auxiliary state names another owner")
        expectEqual(relaunched.authenticationGateState, .accountMismatch,
                    "\(label) [observed, Phase 3 rule]: B's sign-in is held at the account-mismatch gate")
    } else {
        if ownerKeys {
            expectEqual(outcome.accountState, .staged, "\(label): A's own auxiliary state activates for A")
        }
        expect(isConfigurationPreflight(relaunched.authenticationGateState),
               "\(label) [P12-003]: \(signer)'s sign-in heads for \(signer)'s initial sync (got \(relaunched.authenticationGateState))")
        // The sync's completion (an empty cloud here): its backfill queues
        // none of A's legacy records (Task 9b review M1).
        if isConfigurationPreflight(relaunched.authenticationGateState) {
            relaunched.testMarkInitialSyncCompleted(subject: subject)
            expect(!device.queuedRecordIDs.contains("rn-a-1"),
                   "\(label): \(signer)'s initial-sync backfill queues none of the RN-era records (queued: \(device.queuedRecordIDs))")
        }
    }
    expectEqual(relaunched.customers.map(\.id), [], "\(label): the sign-in shows none of the RN-era local records")

    let later = try device.launch()
    expectEqual(later.customers.map(\.id), [], "\(label): a later launch imports nothing")
    expectEqual(device.journalEntryCount, journalEntries, "\(label): a later launch writes no journal entry")
}

/// P12-003's boundary: a snapshot lost with no account scrub still reads as
/// a lost migrated snapshot (writes blocked, "Try again" too, and a sign-in
/// stops at the local-recovery block). Only the scrub's own record makes an
/// empty workspace after a completed migration legitimate.
@MainActor
func testLostSnapshotStillBlocks() async throws {
    let label = "lost snapshot"
    resetHostKeychain()
    let device = try FixtureDevice("lost-snapshot", ownerKeys: false)
    defer { device.cleanUp() }
    _ = try migrateFirstLaunch(device, label)
    for url in [device.storeURL, device.storeURL.appendingPathExtension("backup")] where exists(url) {
        try FileManager.default.removeItem(at: url)
    }
    expect(!exists(device.scrubClearedMarkerURL), "\(label): sanity: no scrub ran")

    let relaunched = try device.launch()
    expectEqual(relaunched.launchMigrationNotice, .failed, "\(label): the relaunch reports the lost migrated snapshot")
    expect(relaunched.isLegacyMigrationBlocked, "\(label): the relaunch blocks local writes")
    expectEqual(relaunched.customers.map(\.id), [], "\(label): the relaunch imports nothing")
    relaunched.retryLegacyMigration()
    expect(relaunched.isLegacyMigrationBlocked && relaunched.launchMigrationNotice == .failed,
           "\(label): \"Try again\" keeps the block")
    let bOutcome = try await device.signInOutcome(sessionB, subject: "user-b")
    relaunched.testBindInteractiveOwner(bOutcome, email: "b@example.invalid")
    expect(isLocalRecoveryPreflight(relaunched.authenticationGateState, "missing-migrated-snapshot"),
           "\(label): a sign-in stops at the missing-migrated-snapshot block (got \(relaunched.authenticationGateState))")
}

/// The scrub's record lasts only until the next save: once the signed-in
/// account has saved a workspace, losing that snapshot blocks again.
@MainActor
func testSaveEndsTheScrubClearedState() async throws {
    let label = "save after sign-out"
    resetHostKeychain()
    let device = try FixtureDevice("save-after-signout", ownerKeys: false)
    defer { device.cleanUp() }
    let first = try migrateFirstLaunch(device, label)
    try await first.signOut(revokeRemote: false)

    let relaunched = try device.launch()
    let aOutcome = try await device.signInOutcome(sessionA, subject: "user-a")
    relaunched.testBindInteractiveOwner(aOutcome, email: "a@example.invalid")
    expect(relaunched.upsert(Customer(name: "Saved After Sign-In")),
           "\(label) [P12-003]: the signed-out workspace accepts the next account's write")
    expect(exists(device.storeURL), "\(label): the write saves a snapshot")
    expect(!exists(device.scrubClearedMarkerURL), "\(label) [P12-003]: the save ends the scrub-cleared state")

    for url in [device.storeURL, device.storeURL.appendingPathExtension("backup")] where exists(url) {
        try FileManager.default.removeItem(at: url)
    }
    let lost = try device.launch()
    expectEqual(lost.launchMigrationNotice, .failed, "\(label) [P12-003]: a snapshot lost after that save blocks again")
    expect(lost.isLegacyMigrationBlocked, "\(label) [P12-003]: …and blocks local writes")
}

/// A sign-out stopped part-way stays pending (its scrub marker), and the
/// launch or Retry that finishes it records the cleared workspace, so the
/// launch after an interrupted sign-out is never blocked as a lost snapshot.
@MainActor
func testInterruptedSignOutRelaunchesCleanly() async throws {
    for stage in ["marker only", "snapshot removed", "launch scrub failed", "launch scrub failed, activation"] {
        let label = "interrupted sign-out (\(stage))"
        resetHostKeychain()
        let device = try FixtureDevice("interrupted-\(stage.replacingOccurrences(of: " ", with: "-"))", ownerKeys: false)
        defer { device.cleanUp() }
        _ = try migrateFirstLaunch(device, label)
        let repository = Canonical.SnapshotRepository(primaryURL: device.storeURL)
        try repository.beginAccountScrub(scope: .live)
        if stage != "marker only" { try repository.removeLiveAccountData() }

        if stage.hasPrefix("launch scrub failed") {
            try device.group.blockLock()
            let blocked = try device.launch()
            expect(blocked.isAccountScrubBlocked, "\(label): sanity: the launch's scrub fails and blocks")
            expect(!blocked.isLegacyMigrationBlocked && blocked.launchMigrationNotice == nil,
                   "\(label): it is blocked as the scrub, not as a lost snapshot")
            expect(exists(device.scrubMarkerURL), "\(label): the sign-out stays pending")
            try device.group.unblockLock()
            if stage.hasSuffix("activation") {
                // Task 9b review M3: the next scene activation retries it.
                blocked.retryAccountBoundaryCleanupOnActivation()
            } else {
                blocked.retryAccountScrub()
            }
            expect(!blocked.isAccountScrubBlocked && !exists(device.scrubMarkerURL), "\(label): the retry finishes the sign-out")
            expect(!blocked.isLegacyMigrationBlocked && blocked.launchMigrationNotice == nil,
                   "\(label) [P12-003]: Retry leaves the app signed out and usable")
        }

        let relaunched = try device.launch()
        expect(!relaunched.isAccountScrubBlocked && !exists(device.scrubMarkerURL), "\(label): the sign-out is finished")
        expect(!exists(device.storeURL), "\(label): the snapshot is gone")
        expect(relaunched.launchMigrationNotice == nil && !relaunched.isLegacyMigrationBlocked,
               "\(label) [P12-003]: the next launch is an ordinary signed-out launch (notice \(String(describing: relaunched.launchMigrationNotice)))")
        expect(device.journalComplete, "\(label): the journal stays complete")
        expectEqual(relaunched.customers.map(\.id), [], "\(label): nothing is imported")
        expect(nativeSession() == nil, "\(label): the session is cleared")
        let bOutcome = try await device.signInOutcome(sessionB, subject: "user-b")
        relaunched.testBindInteractiveOwner(bOutcome, email: "b@example.invalid")
        expect(isConfigurationPreflight(relaunched.authenticationGateState),
               "\(label) [P12-003]: B's sign-in heads for B's initial sync (got \(relaunched.authenticationGateState))")
    }
}

/// Task 9 (L267.a) in the signed-out state: the launch that skips the
/// migration still re-protects the published legacy backup copy, once.
@MainActor
func testSignedOutLaunchReprotects() async throws {
    let label = "signed-out re-protect"
    resetHostKeychain()
    let device = try FixtureDevice("signout-reprotect", ownerKeys: false)
    defer { device.cleanUp() }
    let first = try migrateFirstLaunch(device, label)
    try await first.signOut(revokeRemote: false)

    final class Counter { var count = 0 }
    let counter = Counter()
    let repository = Canonical.SnapshotRepository(
        primaryURL: device.storeURL,
        legacyFileEnumerator: { url in
            counter.count += 1
            return FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        }
    )
    let relaunched = try device.launch(repository: repository)
    expect(!relaunched.isLegacyMigrationBlocked && relaunched.launchMigrationNotice == nil,
           "\(label) [P12-003]: the signed-out launch is not blocked")
    expectEqual(counter.count, 1, "\(label): the signed-out launch re-protects the legacy backup copy exactly once")
}

// MARK: - 3. Recovery exits and the account switch

/// These exits keep the workspace (and the journal), so a relaunch loads the
/// same snapshot and never runs the importer.
@MainActor
func testWorkspaceRetainingExits() async throws {
    for exitName in ["cancel recovery", "dismiss invalid recovery", "use another account"] {
        resetHostKeychain()
        let device = try FixtureDevice("exit-\(exitName.replacingOccurrences(of: " ", with: "-"))", ownerKeys: false)
        defer { device.cleanUp() }
        let first = try migrateFirstLaunch(device, exitName)
        let journalEntries = device.journalEntryCount
        switch exitName {
        case "cancel recovery":
            await first.cancelPasswordRecovery()
        case "dismiss invalid recovery":
            let recovery = NativePasswordRecoveryStore(backend: HostInMemoryKeychain())
            try recovery.markActive(userSubject: "user-a")
            await first.dismissInvalidPasswordRecovery(recoveryStore: recovery)
        default:
            first.scheduleBookingTestSeedIdentityActivator()
            await first.useAnotherAccount(clearGoogleCredential: {})
        }
        expect(exists(device.storeURL), "\(exitName): the workspace is kept")
        expect(device.journalComplete, "\(exitName): the completed journal is kept")
        expect(exists(device.manifestURL) && device.legacySecureStore.legacyItemCount == 2, "\(exitName): the RN sources are kept")

        let relaunched = try device.launch()
        expectEqual(relaunched.customers.map(\.id), ["rn-a-1"], "\(exitName): the relaunch loads the kept workspace once")
        expect(relaunched.launchMigrationNotice == nil, "\(exitName): the relaunch reports no migration")
        expectEqual(device.journalEntryCount, journalEntries, "\(exitName): the relaunch writes no journal entry (the importer did not run)")
    }
}

// MARK: - 5. Every scrub path, and an unreadable scrub marker

/// P12-004 (12.00b.2-G): a sign-out whose scrub fails and is finished by
/// Retry clears A's pending schedule/booking work (booking and portal link
/// mirrors with their tokens), as the launch recovery and the first attempt
/// do. Characterized before the fix: Retry left A's items on the device,
/// but B could not send or apply them. Every item carries A's exact
/// binding, and B's recovery acts only on B's.
@MainActor
func testRetriedSignOutClearsPendingBookingWork() async throws {
    let label = "retried sign-out"
    resetHostKeychain()
    let device = try FixtureDevice("retry-booking-work", ownerKeys: false)
    defer { device.cleanUp() }
    let first = try migrateFirstLaunch(device, label)
    let aOutcome = try await device.signInOutcome(sessionA, subject: "user-a")
    first.testBindInteractiveOwner(aOutcome, email: "a@example.invalid")
    let bindingA = aOutcome.verifiedAccountBinding
    let work = first.pendingScheduleBookingWorkStore()
    try work.stage(.init(
        kind: .bookingMirror(token: "fixture-booking-token-a", enabled: true, revision: 1, operationId: "op-a-1"),
        ownerBinding: bindingA
    ))
    try work.stage(.init(
        kind: .portalMirror(customerId: "rn-a-1", token: "fixture-portal-token-a", enabled: true, operationId: "op-a-2"),
        ownerBinding: bindingA
    ))
    expectEqual(work.load().count, 2, "\(label): sanity: A has two pending items")

    try device.group.blockLock()
    var threw = false
    do { try await first.signOut(revokeRemote: false) } catch { threw = true }
    expect(threw && first.isAccountScrubBlocked && exists(device.scrubMarkerURL),
           "\(label): sanity: the sign-out's scrub fails and stays pending")
    expectEqual(first.accountScrubBlockedScope, .live, "\(label) [M3]: a blocked sign-out keeps the sign-out wording")
    try device.group.unblockLock()
    first.retryAccountScrub()
    expect(!first.isAccountScrubBlocked && !exists(device.scrubMarkerURL), "\(label): Retry finishes the sign-out")
    expectEqual(work.load().count, 0, "\(label) [P12-004]: Retry clears A's pending booking and portal work")

    // Whatever is left, B can neither send nor apply it.
    let bOutcome = try await device.signInOutcome(sessionB, subject: "user-b")
    first.testBindInteractiveOwner(bOutcome, email: "b@example.invalid")
    expect(bOutcome.verifiedAccountBinding != bindingA, "\(label): sanity: B's binding is not A's")
    let recovery = first.recoverScheduleBookingPendingWork(ownerBinding: bOutcome.verifiedAccountBinding)
    expectEqual(recovery.reappliedMirrors + recovery.retained + recovery.proofsReady.count, 0,
                "\(label) [P12-004]: B's recovery acts on none of A's items")
    expect(work.load().allSatisfy { $0.ownerBinding != bOutcome.verifiedAccountBinding },
           "\(label) [P12-004]: no item is re-owned by B")
    let written = [device.storeURL, device.appDirectory.appendingPathComponent("mutation-queue.json")]
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    expect(!written.contains("fixture-booking-token-a") && !written.contains("fixture-portal-token-a"),
           "\(label) [P12-004]: A's link tokens reach neither B's snapshot nor B's push queue")
}

/// Task 9b review M2 (12.00b.2-G): a deletion whose scrub marker cannot be
/// read (for example before first unlock) stays pending. The launch
/// neither finishes it as a sign-out nor clears it, and nothing is
/// imported. Readable again, the next scene activation (M3) finishes it as
/// the deletion it is. Before the fix the launch read it as a sign-out,
/// cleared it, skipped the erase and re-imported the deleted account.
@MainActor
func testUnreadableDeletionMarkerFailsClosed() async throws {
    let label = "unreadable deletion marker"
    resetHostKeychain()
    let device = try FixtureDevice("unreadable-marker", ownerKeys: false)
    defer { device.cleanUp() }
    let first = try migrateFirstLaunch(device, label)
    device.legacySecureStore.failRemove = true
    do { try first.testRunAccountDeletionLocalScrub() } catch {}
    device.legacySecureStore.failRemove = false
    expectEqual(try? Canonical.SnapshotRepository(primaryURL: device.storeURL).pendingAccountScrubScope, .all,
                "\(label): sanity: the deletion is pending")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: device.scrubMarkerURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: device.scrubMarkerURL.path) }
    expect((try? Data(contentsOf: device.scrubMarkerURL)) == nil, "\(label): sanity: the marker cannot be read")

    let blocked = try device.launch()
    expect(blocked.isAccountScrubBlocked, "\(label) [M2]: the launch stays blocked")
    expect(blocked.accountScrubBlockedScope == nil, "\(label) [M2]: an unknown scope reads as the generic sign-out wording")
    expect(exists(device.scrubMarkerURL), "\(label) [M2]: the marker is kept")
    expectEqual(device.legacySecureStore.legacyItemCount, 2, "\(label) [M2]: no step runs while the scope is unknown")
    expectEqual(blocked.customers.map(\.id), [], "\(label) [M2]: the launch imports nothing")
    expect(!exists(device.journal.fileURL), "\(label) [M2]: the launch runs no migration")
    expect(nativeSession() == nil, "\(label) [M2]: the launch publishes no legacy session")
    blocked.retryAccountScrub()
    expect(blocked.isAccountScrubBlocked && exists(device.scrubMarkerURL), "\(label) [M2]: Retry keeps it pending while unreadable")
    blocked.retryAccountBoundaryCleanupOnActivation()
    expect(blocked.isAccountScrubBlocked && exists(device.scrubMarkerURL), "\(label) [M2]: so does an activation")

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: device.scrubMarkerURL.path)
    blocked.retryAccountBoundaryCleanupOnActivation()
    expect(!blocked.isAccountScrubBlocked && !exists(device.scrubMarkerURL), "\(label) [M3]: the next activation finishes the deletion")
    expectEqual(device.legacySecureStore.legacyItemCount, 0, "\(label) [M2]: …as a deletion: the RN SecureStore items are erased")
    expect(!exists(device.manifestURL), "\(label) [M2]: …and the RN AsyncStorage files")
    let later = try device.launch()
    expectEqual(later.customers.map(\.id), [], "\(label) [M2]: a later launch imports nothing")
    expect(later.launchMigrationNotice == nil && !exists(device.journal.fileURL), "\(label) [M2]: a later launch runs no migration")
}

// MARK: - 4. Source pins

@MainActor
func testSources() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let n = root.appendingPathComponent("native/TradeReadyNative")
    let appStore = (try? String(contentsOf: n.appendingPathComponent("AppStore.swift"), encoding: .utf8)) ?? ""
    let coordinator = (try? String(contentsOf: n.appendingPathComponent("LegacyMigrationCoordinator.swift"), encoding: .utf8)) ?? ""
    let app = (try? String(contentsOf: n.appendingPathComponent("TradeReadyNativeApp.swift"), encoding: .utf8)) ?? ""
    expect(!appStore.isEmpty && !coordinator.isEmpty && !app.isEmpty, "source: the sources are readable")

    // The app's only AppStore is the convenience init, which passes the live eraser.
    expect(app.contains("AppStore(analytics:"), "source: the app builds its store with the convenience init")
    expect(sourceBody(appStore, "convenience init(")?.contains("legacySourceEraser: .live()") == true,
           "source: the convenience init passes the live eraser")

    // Exactly the three `.all` scrub sites erase, each in the `.all` branch
    // right after the deletion's Keychain wipe, inside the scrub marker.
    let lines = appStore.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let erases = lines.indices.filter { lines[$0] == "try eraseLegacySourcesForDeletedAccount()" }
    expectEqual(erases.count, 3, "source: three scrub sites erase the legacy sources")
    expect(erases.allSatisfy { $0 >= 2 && lines[$0 - 1].hasSuffix(".clearAllValues()") && lines[$0 - 2] == "case .all:" },
           "source: each erase is in a .all branch, right after the deletion's Keychain wipe")
    for marker in ["private func performLocalAccountScrub(", "func retryAccountScrub("] {
        if let body = sourceBody(appStore, marker),
           let erase = body.range(of: "try eraseLegacySourcesForDeletedAccount()"),
           let finish = body.range(of: "try repository.finishAccountScrub()") {
            expect(erase.upperBound < finish.lowerBound, "source: \(marker) erases before the scrub marker is cleared")
        } else {
            expect(false, "source: \(marker) erases the legacy sources")
        }
    }
    expect(appStore.components(separatedBy: "case .live: try repository.removeLiveAccountData()").count - 1 == 3,
           "source: the three .live branches are single removals (a sign-out never erases)")

    // P12-004: the three scrub paths share one list of stores.
    for marker in ["private func performLocalAccountScrub(", "func retryAccountScrub("] {
        expect(sourceBody(appStore, marker)?.contains("try removeAccountScrubStores()") == true,
               "source [P12-004]: \(marker) clears the shared list of stores")
    }
    expectEqual(lines.filter { $0 == "try removeAccountScrubStores()" }.count, 3,
                "source [P12-004]: the launch recovery, Retry and the first attempt all clear the shared list")
    expectEqual(lines.filter { $0 == "try pendingScheduleBookingWorkStore().removeAll()" }.count, 1,
                "source [P12-004]: the booking-work removal is in the shared list only")
    // M3: the blocked screen's deletion wording.
    let rootView = (try? String(contentsOf: n.appendingPathComponent("RootView.swift"), encoding: .utf8)) ?? ""
    expect(rootView.contains("store.accountScrubBlockedScope == .all")
           && rootView.contains("\"Account deletion cleanup paused\"")
           && rootView.contains("\"Sign-out cleanup paused\"")
           && rootView.contains("TradeReady%20account%20deletion"),
           "source [M3]: the blocked screen says account deletion for a deletion and sign-out otherwise")
    // M3: activation retries a pending scrub, never on top of a running one.
    let activation = sourceBody(appStore, "func retryAccountBoundaryCleanupOnActivation(") ?? ""
    expect(activation.contains("repository.isAccountScrubPending")
           && activation.contains("guard !authenticationOperationInFlight else { return }")
           && activation.contains("retryAccountScrub()"),
           "source [M3]: activation retries a pending scrub unless a sign-out or deletion is running")

    // One definition of the locations: the importer's live source and the eraser.
    expect(sourceBody(coordinator, "private func liveSource(")?.contains("LegacySourceLocations.live(") == true,
           "source: the launch migration reads the shared locations")
    expect(sourceBody(coordinator, "static func live() -> NativeLegacySourceEraser")?.contains("locations: .live()") == true,
           "source: the live eraser erases the shared locations")
    expect(sourceBody(coordinator, "static func live() -> NativeLegacySourceEraser")?.contains("LegacyKeychainSecureStoreEraser()") == true,
           "source: the live eraser erases the system Keychain's legacy items")
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
struct LegacyReimportTests {
    @MainActor
    static func main() async {
        do {
            try await testDeletionThenRelaunch(ownerKeys: true)
            try await testDeletionThenRelaunch(ownerKeys: false)
            try testPendingDeletionFinishedAtLaunch()
            try await testEraseFailureKeepsDeletionPending()
            try testEraser()
            for ownerKeys in [false, true] {
                for signer in ["A", "B"] {
                    try await testSignOutThenRelaunch(ownerKeys: ownerKeys, signer: signer)
                }
            }
            try await testLostSnapshotStillBlocks()
            try await testSaveEndsTheScrubClearedState()
            try await testInterruptedSignOutRelaunchesCleanly()
            try await testSignedOutLaunchReprotects()
            try await testWorkspaceRetainingExits()
            try await testRetriedSignOutClearsPendingBookingWork()
            try await testUnreadableDeletionMarkerFailsClosed()
        } catch {
            failures += 1
            print("FAIL: threw \(error)")
        }
        testSources()
        resetHostKeychain()
        if failures > 0 {
            print("legacy re-import tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("PASS: legacy re-import tests (\(checks) checks)")
    }
}
