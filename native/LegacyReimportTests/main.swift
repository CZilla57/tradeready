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
    func launch() throws -> AppStore {
        AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSourceProvider: { try self.source() },
            legacySourceEraser: eraser,
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
    expectEqual(relaunched.syncStatus.pendingCount, 0, "\(label) [P12-001]: nothing of A's is queued under B")

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
    expectEqual(bLaunch.syncStatus.pendingCount, 0, "\(label) [P12-001]: nothing of A's is queued under B after the relaunch")
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
    for retry in ["relaunch", "retry"] {
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
        expectEqual(Canonical.SnapshotRepository(primaryURL: device.storeURL).pendingAccountScrubScope, .all,
                    "\(label) (\(retry)): the deletion scrub stays pending")
        expectEqual(device.legacySecureStore.legacyItemCount, 2, "\(label) (\(retry)): sanity: the RN SecureStore items remain")

        let blocked = try device.launch()
        expect(blocked.isAccountScrubBlocked, "\(label) (\(retry)): the relaunch stays blocked while the erase fails")
        expectEqual(blocked.customers.map(\.id), [], "\(label) (\(retry)): the blocked relaunch imports nothing")
        expect(!exists(device.journal.fileURL), "\(label) (\(retry)): the blocked relaunch runs no migration")
        expect(nativeSession() == nil, "\(label) (\(retry)): the blocked relaunch publishes no legacy session")
        expect(exists(marker), "\(label) (\(retry)): the deletion is still pending")

        device.legacySecureStore.failRemove = false
        let finished: AppStore
        if retry == "relaunch" {
            finished = try device.launch()
        } else {
            blocked.retryAccountScrub()
            finished = blocked
        }
        expect(!finished.isAccountScrubBlocked && !exists(marker), "\(label) (\(retry)): the deletion finishes")
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
            try await testSignOutThenRelaunch()
            try await testWorkspaceRetainingExits()
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
