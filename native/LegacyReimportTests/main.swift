import CryptoKit
import Foundation

// Phase 12 (12.00b.2-F, charter G6-Q1) host tests: does a permanent account
// deletion leave the React Native sources the launch migration reads, so the
// next launch re-imports the deleted account? Each scenario builds a fixture
// device (AsyncStorage manifest, Documents photo, legacy SecureStore items,
// App Group values) in a temp directory, migrates it with the real launch
// path, crosses one account boundary with the real AppStore code, and
// relaunches on the same files. Nothing here reads or writes the real
// Keychain, App Group, Documents or network.
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

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The legacy Expo SecureStore services the importer reads, in memory.
final class FakeLegacySecureStore {
    var services: [String: [String: Data]] = [:]

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

    /// A cold launch of the native app on this device (the production
    /// convenience init's settings, with host-test stand-ins).
    func launch() throws -> AppStore {
        AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: try source(),
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

/// CHARACTERIZATION (commit 1): pins what the code does today. P12-001 is
/// reproduced when these pass: the deleted account's data comes back.
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

    // Observed: the RN sources survive the deletion.
    expect(exists(device.manifestURL), "\(label) [P12-001]: the RN AsyncStorage manifest survives the deletion")
    expect(exists(device.photoURL), "\(label) [P12-001]: the RN Documents photo survives the deletion")
    expectEqual(device.legacySecureStore.legacyItemCount, 2, "\(label) [P12-001]: the RN SecureStore items survive the deletion")

    // Relaunch: no snapshot and no journal, so the importer runs again.
    let relaunched = try device.launch()
    expectEqual(relaunched.customers.map(\.id), ["rn-a-1"], "\(label) [P12-001]: the relaunch re-imports the deleted account's customer")
    expect(isMigratedNotice(relaunched.launchMigrationNotice), "\(label) [P12-001]: the relaunch reports a fresh migration")
    expect(device.journalComplete, "\(label) [P12-001]: the relaunch writes a completed journal again")
    expect(exists(device.auxiliaryURL) && exists(device.legacyBackupsURL),
           "\(label) [P12-001]: the relaunch re-creates the auxiliary state and the legacy backups")
    expectEqual(nativeSession(), sessionA, "\(label) [P12-001]: the relaunch re-publishes the deleted account's legacy session")
    expectEqual(nativeProviderKey(), Data(providerKeyA.utf8), "\(label) [P12-001]: the relaunch re-publishes the deleted account's provider key")

    // B signs in on the same launch (the interactive gate).
    let bOutcome = try await device.signInOutcome(sessionB, subject: "user-b")
    expectEqual(bOutcome.accountState, ownerKeys ? .ownerMismatch : .noAccountState,
                "\(label): B's activation reads the re-imported owner marker")
    relaunched.testBindInteractiveOwner(bOutcome, email: "b@example.invalid")
    expectEqual(relaunched.authenticationGateState, .accountMismatch,
                "\(label) [P12-001]: B's sign-in stops at the account-mismatch gate over A's re-imported data")

    // B relaunches (the launch activation adopts an unbound workspace).
    let bLaunch = try device.launch()
    expect(bLaunch.launchMigrationNotice == nil, "\(label): B's relaunch runs no second migration")
    guard let bLaunchOutcome = try await device.launchOutcome() else {
        expect(false, "\(label): B's session is stored")
        return
    }
    expectEqual(bLaunchOutcome.verifiedUserSubject, "user-b", "\(label): the launch verifies B")
    bLaunch.testApplyLaunchIdentityOutcome(bLaunchOutcome)
    if ownerKeys {
        expectEqual(bLaunch.authenticationGateState, .accountMismatch,
                    "\(label) [P12-001]: B's launch stops at the account-mismatch gate (A's owner marker)")
    } else {
        expect(isConfigurationPreflight(bLaunch.authenticationGateState),
               "\(label) [P12-001]: B's launch adopts A's re-imported workspace and heads for B's initial sync (got \(bLaunch.authenticationGateState))")
    }
    expectEqual(bLaunch.customers.map(\.id), ["rn-a-1"], "\(label) [P12-001]: A's customer is in B's local workspace")
}

/// A deletion whose scrub was interrupted is finished by the next launch,
/// which then runs the migration in the same launch.
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
    expectEqual(relaunched.customers.map(\.id), ["rn-a-1"], "\(label) [P12-001]: the same launch re-imports the deleted account's customer")
    expect(device.journalComplete, "\(label) [P12-001]: the same launch writes a completed journal")
    expectEqual(nativeSession(), sessionA, "\(label) [P12-001]: the same launch re-publishes the deleted account's session")
}

// MARK: - 2. Sign-out (.live scrub)

/// G6: a sign-out keeps the RN sources (the Expo rollback build reads them)
/// and the completed journal, so nothing is imported again.
@MainActor
func testSignOutThenRelaunch() async throws {
    let label = "sign-out"
    resetHostKeychain()
    let device = try FixtureDevice("signout", ownerKeys: false)
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

    let relaunched = try device.launch()
    expectEqual(relaunched.customers.map(\.id), [], "\(label): the relaunch imports nothing")
    // Observed, a separate finding (not P12-001, reported to the controller):
    // a completed journal with no snapshot reads as a failed migration
    // (`applyLaunchMigrationState`, `.alreadyCompleted` without a snapshot)
    // and blocks local writes until a snapshot exists again.
    expectEqual(relaunched.launchMigrationNotice, .failed,
                "\(label) [separate finding]: the relaunch reports the completed-journal-without-snapshot block")
    expect(relaunched.isLegacyMigrationBlocked, "\(label) [separate finding]: the relaunch blocks local writes")
    expectEqual(device.journalEntryCount, journalEntries, "\(label): the relaunch writes no journal entry (the importer did not run)")
    expect(nativeSession() == nil, "\(label): the relaunch re-publishes no legacy session")

    let bOutcome = try await device.signInOutcome(sessionB, subject: "user-b")
    relaunched.testBindInteractiveOwner(bOutcome, email: "b@example.invalid")
    expect(relaunched.authenticationGateState != .accountMismatch, "\(label): B's sign-in is not gated by A's data")
    // Observed, a separate finding (not P12-001, reported to the controller):
    // B's first sign-in after that relaunch stops at the local-recovery block.
    expect(isLocalRecoveryPreflight(relaunched.authenticationGateState, "missing-migrated-snapshot"),
           "\(label) [separate finding]: B's sign-in stops at the missing-migrated-snapshot block (got \(relaunched.authenticationGateState))")
    expectEqual(relaunched.customers.map(\.id), [], "\(label): B sees none of A's records")
    expectEqual(relaunched.syncStatus.pendingCount, 0, "\(label): nothing of A's is queued under B")

    let bLaunch = try device.launch()
    expectEqual(bLaunch.customers.map(\.id), [], "\(label): B's relaunch imports nothing")
    expectEqual(device.journalEntryCount, journalEntries, "\(label): B's relaunch writes no journal entry")
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

// MARK: - Main

@main
struct LegacyReimportTests {
    @MainActor
    static func main() async {
        do {
            try await testDeletionThenRelaunch(ownerKeys: true)
            try await testDeletionThenRelaunch(ownerKeys: false)
            try testPendingDeletionFinishedAtLaunch()
            try await testSignOutThenRelaunch()
            try await testWorkspaceRetainingExits()
        } catch {
            failures += 1
            print("FAIL: threw \(error)")
        }
        resetHostKeychain()
        if failures > 0 {
            print("legacy re-import tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("PASS: legacy re-import tests (\(checks) checks)")
    }
}
