import Foundation

extension Canonical {
    /// Synchronous, file-backed storage for the canonical snapshot.
    ///
    /// Callers must serialize access (the app uses it from `AppStore`'s main
    /// actor). Every primary write is atomic and retains the previous decodable
    /// snapshot as the last-known-good backup.
    struct SnapshotRepository {
        enum AccountScrubScope: String, Codable {
            case live
            case all
        }

        private struct AccountScrubMarker: Codable {
            let schemaVersion: Int
            let scope: AccountScrubScope
        }

        /// Final review 1a/1b: an owner-boundary step that runs outside the
        /// full account scrub (the account switch keeps the workspace; the
        /// password-recovery exits run no scrub). Each gets its own privacy-
        /// safe marker next to the account-scrub marker, written before the
        /// step and removed only after it succeeds, so a failure stays pending
        /// across launches until a retry completes it.
        enum BoundaryStep: String, CaseIterable {
            /// The App Group suite wipe, timeline reload and claim removal.
            case widgetScrub = "widget-scrub-pending"
            /// The removal of both AI provider keys from the secure store.
            case aiKeyWipe = "ai-key-wipe-pending"
            /// Phase 12 (12.00b.1, I2): the removal of the rejected-change
            /// store (`NativeRejectedChangeStore`).
            case rejectedChangesScrub = "rejected-changes-scrub-pending"
        }

        private struct BoundaryStepMarker: Codable {
            let schemaVersion: Int
        }

        /// Phase 12 (12.00b.2-G, P12-003): see `isLiveWorkspaceClearedByAccountScrub`.
        private struct WorkspaceClearedMarker: Codable {
            let schemaVersion: Int
        }

        enum LoadSource: Equatable {
            case primary
            case recoveredBackup
        }

        struct LoadOutcome {
            let snapshot: Snapshot
            let source: LoadSource
            let quarantinedURL: URL?
        }

        enum RepositoryError: Error {
            case corruptPrimaryNoUsableBackup(primary: Error, backup: Error?)
        }

        /// Phase 12 (12.00b.2-G, Task 9b review M2): a scrub marker that exists
        /// but cannot be read (for example before first unlock) or decoded
        /// (a scope this build does not know). Codes only.
        enum AccountScrubMarkerError: Error, Equatable {
            case unreadable
            case undecodable
        }

        /// Phase 12.00b.2-E fix round 1 (L267.a, Important 1 & 2): the outcome
        /// of raising a copied `LegacyBackups/` file's protection class, so a
        /// caller (and a host test) can observe the failure mode instead of a
        /// printed diagnostic alone. Counts only — never a path or filename.
        enum LegacyFileProtectionOutcome: Equatable {
            case enumeratorUnavailable
            case completed(protected: Int, failed: Int)
        }

        /// Phase 12 (12.02, L267.a): a running, counts-only tally of every
        /// `LegacyFileProtectionOutcome` this process produced (the migration's
        /// own pass and each launch's re-protect), for the support report. A
        /// class so every copy of the repository shares it; bounded; never a
        /// path or filename.
        final class LegacyFileProtectionTally: @unchecked Sendable {
            struct Summary: Equatable {
                var checks = 0
                var enumeratorUnavailable = 0
                var lastProtected = 0
                var lastFailed = 0
                var failedTotal = 0
            }

            static let maximumCount = 9_999
            private let lock = NSLock()
            private var current = Summary()

            var summary: Summary {
                lock.lock(); defer { lock.unlock() }
                return current
            }

            func record(_ outcome: LegacyFileProtectionOutcome) {
                lock.lock(); defer { lock.unlock() }
                current.checks = min(Self.maximumCount, current.checks + 1)
                switch outcome {
                case .enumeratorUnavailable:
                    current.enumeratorUnavailable = min(Self.maximumCount, current.enumeratorUnavailable + 1)
                    current.lastProtected = 0
                    current.lastFailed = 0
                case let .completed(protected, failed):
                    current.lastProtected = min(Self.maximumCount, max(0, protected))
                    current.lastFailed = min(Self.maximumCount, max(0, failed))
                    current.failedTotal = min(Self.maximumCount, current.failedTotal + max(0, failed))
                }
            }
        }

        /// Task 11.13 fix round 3: everything under `LegacyBackups/` is the
        /// exact pre-conversion source, which can hold an RN-era plaintext
        /// Square access token (contract §17.2 G6). It is written with
        /// complete file protection, copied directories get the same class,
        /// and the tree is excluded from device backup.
        static let legacyBackupWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
        static let legacyBackupFileProtection: FileProtectionType = .complete

        let primaryURL: URL
        let backupURL: URL
        let legacyBackupDirectoryURL: URL
        let accountScrubMarkerURL: URL
        let accountScrubClearedMarkerURL: URL
        let liveMediaDirectoryURL: URL
        /// Phase 12 (12.02, L267.a): see `LegacyFileProtectionTally`.
        let legacyFileProtectionTally = LegacyFileProtectionTally()

        private let fileManager: FileManager
        private let now: () -> Date

        /// Phase 12.00b.2-E fix round 1 (Minor): injected like `fileManager`/
        /// `now` instead of a mutable stored test seam. Lets a host test force
        /// the nil-enumerator failure path without a production-visible
        /// boolean var. `FileManager.enumerator(at:includingPropertiesForKeys:)`
        /// is a `@nonobjc` Swift-overlay method and cannot be subclassed or
        /// overridden from outside Foundation on this toolchain, so this
        /// closure is the only way to simulate its failure from a host test.
        /// Defaults to the real `FileManager.enumerator`.
        private let legacyFileEnumerator: (URL) -> FileManager.DirectoryEnumerator?

        init(
            primaryURL: URL,
            backupURL: URL? = nil,
            legacyBackupDirectoryURL: URL? = nil,
            fileManager: FileManager = .default,
            now: @escaping () -> Date = Date.init,
            legacyFileEnumerator: ((URL) -> FileManager.DirectoryEnumerator?)? = nil
        ) {
            self.primaryURL = primaryURL
            self.backupURL = backupURL ?? primaryURL.appendingPathExtension("backup")
            self.legacyBackupDirectoryURL = legacyBackupDirectoryURL
                ?? primaryURL.deletingLastPathComponent().appendingPathComponent("LegacyBackups", isDirectory: true)
            self.accountScrubMarkerURL = primaryURL.appendingPathExtension("account-scrub-pending")
            self.accountScrubClearedMarkerURL = primaryURL.appendingPathExtension("account-scrub-cleared")
            self.liveMediaDirectoryURL = primaryURL.deletingLastPathComponent()
                .appendingPathComponent("Media", isDirectory: true)
            self.fileManager = fileManager
            self.now = now
            self.legacyFileEnumerator = legacyFileEnumerator
                ?? { fileManager.enumerator(at: $0, includingPropertiesForKeys: nil) }
        }

        var isAccountScrubPending: Bool {
            fileManager.fileExists(atPath: accountScrubMarkerURL.path)
        }

        /// The pending scrub's scope, or nil when none is pending.
        ///
        /// Phase 12 (12.00b.2-G, Task 9b review M2): a marker that cannot be
        /// read or decoded throws instead of reading as `.live`. Finishing an
        /// unknown scope as a sign-out would skip a deletion's erase and clear
        /// its marker (P12-001), so callers keep the scrub pending and retry.
        var pendingAccountScrubScope: AccountScrubScope? {
            get throws {
                guard isAccountScrubPending else { return nil }
                let data: Data
                do { data = try Data(contentsOf: accountScrubMarkerURL) }
                catch { throw AccountScrubMarkerError.unreadable }
                // Compatibility with the initial content-free Phase 3 marker.
                guard !data.isEmpty else { return .live }
                do { return try JSONDecoder().decode(AccountScrubMarker.self, from: data).scope }
                catch { throw AccountScrubMarkerError.undecodable }
            }
        }

        /// Phase 12 (12.00b.2-G, P12-003): an account scrub removed the live
        /// workspace and nothing has been saved since. A sign-out on a migrated
        /// device removes the snapshot but keeps the completed migration journal
        /// (so no later account re-imports the React Native data); this record
        /// is what tells that signed-out state from a lost snapshot. It is
        /// written before anything is removed, survives relaunches, holds no
        /// account data, and the next `save` removes it.
        var isLiveWorkspaceClearedByAccountScrub: Bool {
            fileManager.fileExists(atPath: accountScrubClearedMarkerURL.path)
        }

        /// Starts an explicit account boundary before deleting any live data.
        /// The privacy-safe marker records only whether exact-owner recovery
        /// artifacts must also be erased. It contains no account data or ID.
        func beginAccountScrub(scope: AccountScrubScope = .live) throws {
            guard !isAccountScrubPending else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try atomicWrite(
                try encoder.encode(AccountScrubMarker(schemaVersion: 1, scope: scope)),
                to: accountScrubMarkerURL
            )
        }

        /// Deletes every repository copy that `load()` could make live again.
        /// Immutable legacy migration backups remain available for recovery
        /// (G6), and the completed migration journal stays, so no later
        /// account re-imports the React Native data.
        ///
        /// Phase 12 (12.00b.2-G fix round 1, P12-005): the RN-era account
        /// state and owner marker go too (the auxiliary artifact and its staged
        /// copy), as RN's sign-out drops every account key and `__dataOwner`
        /// (`utils/storage/lifecycle.ts:106-159`). Kept, its owner marker held
        /// every other account at the exact-owner gate after the sign-out, and
        /// its account state was one owner match away from activation.
        func removeLiveAccountData() throws {
            // Phase 12 (12.00b.2-G, P12-003): recorded first, so a scrub that
            // stops part-way (its marker stays pending and it reruns) can never
            // leave a removed snapshot without this record. A failed write
            // fails the scrub, which then stays pending.
            try atomicWrite(
                try JSONEncoder().encode(WorkspaceClearedMarker(schemaVersion: 1)),
                to: accountScrubClearedMarkerURL
            )
            let directory = primaryURL.deletingLastPathComponent()
            // P12-005: before the snapshot, so nothing activates it meanwhile.
            for url in [
                directory.appendingPathComponent("auxiliary-state.json"),
                directory.appendingPathComponent("AuxiliaryActivation", isDirectory: true)
            ] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            let quarantinePrefix = "\(primaryURL.lastPathComponent).corrupt-"
            let entries = if fileManager.fileExists(atPath: directory.path) {
                try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } else {
                [URL]()
            }
            for url in entries where url.lastPathComponent.hasPrefix(quarantinePrefix) {
                try fileManager.removeItem(at: url)
            }
            for url in [backupURL, primaryURL] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            let onboardingURL = directory.appendingPathComponent("native-account-workspace.json")
            for url in [onboardingURL.appendingPathExtension("backup"), onboardingURL]
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: liveMediaDirectoryURL.path) {
                try fileManager.removeItem(at: liveMediaDirectoryURL)
            }
        }

        /// Permanent account deletion also removes the recovery-only artifacts
        /// that a sign-out retains: the legacy backups (G6), the migration
        /// journal and the support report. (The auxiliary artifact and its
        /// staged copy go with the live data: P12-005.)
        func removeAllAccountData() throws {
            try removeLiveAccountData()
            let directory = primaryURL.deletingLastPathComponent()
            let deletionTargets = [
                legacyBackupDirectoryURL,
                directory.appendingPathComponent("migration-journal.json"),
                directory.appendingPathComponent("tradeready-support-report.json"),
                // Phase 12 (12.00b.2-G): with the journal gone the record
                // means nothing; a deletion leaves nothing behind.
                accountScrubClearedMarkerURL
            ]
            for url in deletionTargets where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        func finishAccountScrub() throws {
            guard isAccountScrubPending else { return }
            try fileManager.removeItem(at: accountScrubMarkerURL)
        }

        func boundaryStepMarkerURL(_ step: BoundaryStep) -> URL {
            primaryURL.appendingPathExtension(step.rawValue)
        }

        func isBoundaryStepPending(_ step: BoundaryStep) -> Bool {
            fileManager.fileExists(atPath: boundaryStepMarkerURL(step).path)
        }

        /// Same shape as `beginAccountScrub`: no account data or ID.
        func beginBoundaryStep(_ step: BoundaryStep) throws {
            guard !isBoundaryStepPending(step) else { return }
            try atomicWrite(
                try JSONEncoder().encode(BoundaryStepMarker(schemaVersion: 1)),
                to: boundaryStepMarkerURL(step)
            )
        }

        func finishBoundaryStep(_ step: BoundaryStep) throws {
            guard isBoundaryStepPending(step) else { return }
            try fileManager.removeItem(at: boundaryStepMarkerURL(step))
        }

        func load() throws -> LoadOutcome? {
            guard fileManager.fileExists(atPath: primaryURL.path) else {
                guard fileManager.fileExists(atPath: backupURL.path) else { return nil }
                let backupBytes = try Data(contentsOf: backupURL)
                let recovered = try SnapshotCodec.decode(backupBytes)
                try atomicWrite(backupBytes, to: primaryURL)
                return LoadOutcome(snapshot: recovered, source: .recoveredBackup, quarantinedURL: nil)
            }

            let primaryBytes = try Data(contentsOf: primaryURL)
            do {
                return LoadOutcome(snapshot: try SnapshotCodec.decode(primaryBytes), source: .primary, quarantinedURL: nil)
            } catch let primaryError {
                guard fileManager.fileExists(atPath: backupURL.path) else {
                    throw RepositoryError.corruptPrimaryNoUsableBackup(primary: primaryError, backup: nil)
                }
                let backupBytes: Data
                let recovered: Snapshot
                do {
                    backupBytes = try Data(contentsOf: backupURL)
                    recovered = try SnapshotCodec.decode(backupBytes)
                } catch let backupError {
                    throw RepositoryError.corruptPrimaryNoUsableBackup(
                        primary: primaryError,
                        backup: backupError
                    )
                }
                let quarantineURL = try quarantine(primaryBytes)
                try atomicWrite(backupBytes, to: primaryURL)
                return LoadOutcome(snapshot: recovered, source: .recoveredBackup, quarantinedURL: quarantineURL)
            }
        }

        func save(_ snapshot: Snapshot) throws {
            let newBytes = try SnapshotCodec.encode(snapshot)
            try createParentDirectory(for: primaryURL)

            // A malformed primary is never allowed to replace a usable backup.
            if let currentBytes = try? Data(contentsOf: primaryURL),
               let currentSnapshot = try? SnapshotCodec.decode(currentBytes) {
                try atomicWrite(try SnapshotCodec.encode(currentSnapshot), to: backupURL)
            }

            try atomicWrite(newBytes, to: primaryURL)

            // Phase 12 (12.00b.2-G, P12-003): a saved workspace is no longer
            // the one a scrub cleared. Removed after the write, so a crash in
            // between never leaves an empty workspace without the record. Best
            // effort: the snapshot is already saved, a leftover record matters
            // only if this snapshot is later lost with no save in between, and
            // the next save retries.
            if fileManager.fileExists(atPath: accountScrubClearedMarkerURL.path) {
                do { try fileManager.removeItem(at: accountScrubClearedMarkerURL) }
                catch { print("TradeReadySnapshotRepository stage=scrub-cleared-record") }
            }
        }

        /// Retains the exact pre-conversion source bytes. Existing backups are
        /// immutable so retrying a migration cannot destroy its recovery point.
        @discardableResult
        func preserveLegacyBytes(_ data: Data, migration: MigrationKind) throws -> URL {
            try prepareLegacyBackupDirectory(legacyBackupDirectoryURL)
            let destination = legacyBackupDirectoryURL.appendingPathComponent("\(migration.rawValue).json")
            if !fileManager.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: Self.legacyBackupWriteOptions)
            }
            return destination
        }

        @discardableResult
        func preserveLegacyArtifact(
            _ data: Data,
            migration: MigrationKind,
            filename: String
        ) throws -> URL {
            let directory = legacyBackupDirectoryURL.appendingPathComponent(migration.rawValue, isDirectory: true)
            try prepareLegacyBackupDirectory(directory)
            let destination = directory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: Self.legacyBackupWriteOptions)
            }
            return destination
        }

        /// Atomically publishes an immutable directory backup. A staging copy
        /// may remain after process termination, but it is never mistaken for
        /// the completed recovery point and a retry safely creates a new one.
        @discardableResult
        func preserveLegacyDirectory(
            _ source: URL,
            migration: MigrationKind,
            name: String
        ) throws -> URL {
            let migrationDirectory = legacyBackupDirectoryURL
                .appendingPathComponent(migration.rawValue, isDirectory: true)
            try prepareLegacyBackupDirectory(migrationDirectory)
            let destination = migrationDirectory.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                // Phase 12.00b.2-E fix round 1 (L267.a, Important 1): a
                // completed migration's only other caller
                // (`LegacyMigrationCoordinator.migrate`) short-circuits to
                // `.alreadyCompleted` once the journal is complete and never
                // calls this again, so this early return is the other path
                // that must heal a protection failure from the original pass
                // rather than silently returning.
                _ = reprotectPublishedLegacyDirectory(migration: migration, name: name)
                return destination
            }

            let staging = migrationDirectory
                .appendingPathComponent(".\(name)-staging-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.copyItem(at: source, to: staging)
                _ = protectCopiedLegacyFiles(in: staging)
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
            return destination
        }

        /// Phase 12.00b.2-E fix round 1 (L267.a, Important 1): re-runs file
        /// protection on an already-published `LegacyBackups/<migration>/<name>`
        /// copy. `LegacyMigrationCoordinator.migrate` short-circuits to
        /// `.alreadyCompleted` once the journal is complete and never calls
        /// `preserveLegacyDirectory` again, so this is the only path that can
        /// heal a protection failure from the original pass on a later
        /// launch. Returns `nil` when nothing has been published yet (nothing
        /// to protect). Never throws; touches only the copied `LegacyBackups/`
        /// tree, never the RN source files it was copied from (charter G6
        /// §5.4 item 1).
        @discardableResult
        func reprotectPublishedLegacyDirectory(
            migration: MigrationKind,
            name: String
        ) -> LegacyFileProtectionOutcome? {
            let destination = legacyBackupDirectoryURL
                .appendingPathComponent(migration.rawValue, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: destination.path) else { return nil }
            return protectCopiedLegacyFiles(in: destination)
        }

        func diagnostics(
            for outcome: LoadOutcome?,
            journal: MigrationJournalDocument
        ) -> PersistenceDiagnostics {
            let payload = outcome?.snapshot.payload
            let latestStatuses = Dictionary(
                journal.entries.map { ($0.migration, $0.status) },
                uniquingKeysWith: { _, latest in latest }
            )
            return PersistenceDiagnostics(
                snapshotSchemaVersion: outcome?.snapshot.schemaVersion,
                snapshotStatus: outcome.map {
                    $0.source == .primary ? .primary : .recovered
                } ?? .missing,
                backupAvailable: fileManager.fileExists(atPath: backupURL.path),
                counts: .init(
                    invoices: payload?.invoices?.count ?? 0,
                    jobs: payload?.jobs?.count ?? 0,
                    customers: payload?.customers?.count ?? 0,
                    expenses: payload?.expenses?.count ?? 0,
                    customerNotes: payload?.customerNotes?.count ?? 0,
                    recurringJobs: payload?.recurringJobs?.count ?? 0,
                    recurringInvoices: payload?.recurringInvoices?.count ?? 0,
                    trips: payload?.trips?.count ?? 0,
                    pricebook: payload?.pricebook?.count ?? 0,
                    bookingRequests: payload?.bookingRequests?.count ?? 0,
                    jobPhotos: payload?.jobPhotos?.count ?? 0
                ),
                migrations: MigrationKind.allCases.map {
                    .init(migration: $0, status: latestStatuses[$0])
                }
            )
        }

        private func quarantine(_ data: Data) throws -> URL {
            let milliseconds = Int64(now().timeIntervalSince1970 * 1_000)
            let baseName = "\(primaryURL.lastPathComponent).corrupt-\(milliseconds)"
            var candidate = primaryURL.deletingLastPathComponent().appendingPathComponent(baseName)
            var suffix = 1
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = primaryURL.deletingLastPathComponent()
                    .appendingPathComponent("\(baseName)-\(suffix)")
                suffix += 1
            }
            try atomicWrite(data, to: candidate)
            return candidate
        }

        /// Creates `directory` (under `LegacyBackups/`) and excludes the whole
        /// `LegacyBackups/` tree from device backup. A failure to set the flag
        /// never fails the import; it logs a bounded stage code only (no path).
        private func prepareLegacyBackupDirectory(_ directory: URL) throws {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = legacyBackupDirectoryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do { try root.setResourceValues(values) } catch {
                print("TradeReadyLegacyBackup stage=exclude-from-backup")
            }
        }

        /// A copied directory keeps the source's protection class; raise every
        /// copied file to `legacyBackupFileProtection`. Best effort, bounded
        /// log — never a throw: protection is hardening on top of the copy
        /// `preserveLegacyDirectory` already made, not a correctness gate, so
        /// neither a nil enumerator nor a per-file failure may block or retry
        /// the migration. Phase 12.00b.2-E fix round 1 (Important 1 & 2):
        /// returns an outcome instead of `Void` so a caller can re-protect a
        /// published copy later, and a host test can assert the failure mode
        /// behaviourally instead of pinning this function's source text.
        @discardableResult
        private func protectCopiedLegacyFiles(in directory: URL) -> LegacyFileProtectionOutcome {
            guard let files = legacyFileEnumerator(directory) else {
                print("TradeReadyLegacyBackup stage=file-protection")
                legacyFileProtectionTally.record(.enumeratorUnavailable)
                return .enumeratorUnavailable
            }
            var protected = 0
            var failed = 0
            for case let file as URL in files where !file.hasDirectoryPath {
                do {
                    try fileManager.setAttributes([.protectionKey: Self.legacyBackupFileProtection],
                                                  ofItemAtPath: file.path)
                    protected += 1
                } catch { failed += 1 }
            }
            if failed > 0 { print("TradeReadyLegacyBackup stage=file-protection") }
            legacyFileProtectionTally.record(.completed(protected: protected, failed: failed))
            return .completed(protected: protected, failed: failed)
        }

        private func atomicWrite(_ data: Data, to url: URL) throws {
            try createParentDirectory(for: url)
            try data.write(to: url, options: .atomic)
        }

        private func createParentDirectory(for url: URL) throws {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    enum MigrationKind: String, Codable, CaseIterable {
        case canonicalSnapshotV0 = "canonical-snapshot-v0-to-v1"
        case legacyNativeSnapshot = "legacy-native-snapshot-to-v1"
        case reactNativeAsyncStorage = "react-native-async-storage-to-v1"
    }

    struct PersistenceDiagnostics: Codable, Equatable {
        enum SnapshotStatus: String, Codable {
            case missing
            case primary
            case recovered
        }

        struct Counts: Codable, Equatable {
            let invoices: Int
            let jobs: Int
            let customers: Int
            let expenses: Int
            let customerNotes: Int
            let recurringJobs: Int
            let recurringInvoices: Int
            let trips: Int
            let pricebook: Int
            let bookingRequests: Int
            let jobPhotos: Int
        }

        struct Migration: Codable, Equatable {
            let migration: MigrationKind
            let status: MigrationJournalStatus?
        }

        let snapshotSchemaVersion: Int?
        let snapshotStatus: SnapshotStatus
        let backupAvailable: Bool
        let counts: Counts
        let migrations: [Migration]
        /// Phase 12 (12.00b.1, I2): how many refused changes are waiting in
        /// Settings › Cloud Sync. A count only.
        var rejectedChangeCount = 0

        /// Produces canonical JSON that is safe to attach to a support request.
        /// The report is rebuilt from this closed diagnostics schema so paths,
        /// errors, record identifiers, customer fields, and stored values can
        /// never be copied into the exported bytes.
        func encodedSupportReport(appVersion: String) throws -> Data {
            try PersistenceSupportReport.encode(
                .init(appVersion: appVersion, diagnostics: self)
            )
        }
    }

    struct PersistenceSupportReport: Codable, Equatable {
        /// 2: Phase 12 (12.00b.1, I2) adds `rejectedChangeCount`.
        static let currentSchemaVersion = 2

        struct MigrationStatus: Codable, Equatable {
            let migration: MigrationKind
            let status: MigrationJournalStatus?

            private enum CodingKeys: String, CodingKey {
                case migration
                case status
            }

            init(migration: MigrationKind, status: MigrationJournalStatus?) {
                self.migration = migration
                self.status = status
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                migration = try values.decode(MigrationKind.self, forKey: .migration)
                status = try values.decodeIfPresent(MigrationJournalStatus.self, forKey: .status)
            }

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(migration, forKey: .migration)
                if let status {
                    try values.encode(status, forKey: .status)
                } else {
                    try values.encodeNil(forKey: .status)
                }
            }
        }

        let reportSchemaVersion: Int
        let appVersion: String
        let snapshotSchemaVersion: Int?
        let snapshotStatus: PersistenceDiagnostics.SnapshotStatus
        let backupAvailable: Bool
        let recordCounts: PersistenceDiagnostics.Counts
        let migrationStatuses: [MigrationStatus]
        /// How many refused changes wait in Settings › Cloud Sync. A count
        /// only: never a table, record, name or payload.
        let rejectedChangeCount: Int

        init(appVersion: String, diagnostics: PersistenceDiagnostics) {
            reportSchemaVersion = Self.currentSchemaVersion
            self.appVersion = appVersion
            snapshotSchemaVersion = diagnostics.snapshotSchemaVersion
            snapshotStatus = diagnostics.snapshotStatus
            backupAvailable = diagnostics.backupAvailable
            recordCounts = diagnostics.counts
            migrationStatuses = diagnostics.migrations
                .map { .init(migration: $0.migration, status: $0.status) }
                .sorted { $0.migration.rawValue < $1.migration.rawValue }
            rejectedChangeCount = diagnostics.rejectedChangeCount
        }

        private enum CodingKeys: String, CodingKey {
            case reportSchemaVersion
            case appVersion
            case snapshotSchemaVersion
            case snapshotStatus
            case backupAvailable
            case recordCounts
            case migrationStatuses
            case rejectedChangeCount
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            reportSchemaVersion = try values.decode(Int.self, forKey: .reportSchemaVersion)
            appVersion = try values.decode(String.self, forKey: .appVersion)
            snapshotSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .snapshotSchemaVersion)
            snapshotStatus = try values.decode(PersistenceDiagnostics.SnapshotStatus.self, forKey: .snapshotStatus)
            backupAvailable = try values.decode(Bool.self, forKey: .backupAvailable)
            recordCounts = try values.decode(PersistenceDiagnostics.Counts.self, forKey: .recordCounts)
            migrationStatuses = try values.decode([MigrationStatus].self, forKey: .migrationStatuses)
            // A v1 report has no count.
            rejectedChangeCount = try values.decodeIfPresent(Int.self, forKey: .rejectedChangeCount) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(reportSchemaVersion, forKey: .reportSchemaVersion)
            try values.encode(appVersion, forKey: .appVersion)
            if let snapshotSchemaVersion {
                try values.encode(snapshotSchemaVersion, forKey: .snapshotSchemaVersion)
            } else {
                try values.encodeNil(forKey: .snapshotSchemaVersion)
            }
            try values.encode(snapshotStatus, forKey: .snapshotStatus)
            try values.encode(backupAvailable, forKey: .backupAvailable)
            try values.encode(recordCounts, forKey: .recordCounts)
            try values.encode(migrationStatuses, forKey: .migrationStatuses)
            try values.encode(rejectedChangeCount, forKey: .rejectedChangeCount)
        }

        fileprivate static func encode(_ report: PersistenceSupportReport) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(report)
        }
    }

    enum MigrationJournalStatus: String, Codable {
        case started
        case completed
        case failed
    }

    struct MigrationJournalEntry: Codable, Equatable {
        let migration: MigrationKind
        let status: MigrationJournalStatus
        let timestamp: Date
    }

    struct MigrationJournalDocument: Codable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int = currentSchemaVersion
        var entries: [MigrationJournalEntry] = []
    }

    /// A deliberately metadata-only journal: its closed schema has no place for
    /// customer data, credentials, imported values, or free-form error text.
    struct MigrationJournal {
        enum BeginDisposition: Equatable {
            case started
            case resumed
            case alreadyCompleted
        }

        let fileURL: URL
        private let fileManager: FileManager
        private let now: () -> Date

        init(
            fileURL: URL,
            fileManager: FileManager = .default,
            now: @escaping () -> Date = Date.init
        ) {
            self.fileURL = fileURL
            self.fileManager = fileManager
            self.now = now
        }

        func read() throws -> MigrationJournalDocument {
            guard fileManager.fileExists(atPath: fileURL.path) else { return MigrationJournalDocument() }
            return try Self.decoder.decode(MigrationJournalDocument.self, from: Data(contentsOf: fileURL))
        }

        @discardableResult
        func begin(_ migration: MigrationKind) throws -> BeginDisposition {
            var document = try read()
            switch document.entries.last(where: { $0.migration == migration })?.status {
            case .completed: return .alreadyCompleted
            case .started: return .resumed
            case .failed, .none:
                document.entries.append(.init(migration: migration, status: .started, timestamp: now()))
                try write(document)
                return .started
            }
        }

        func complete(_ migration: MigrationKind) throws {
            var document = try read()
            guard document.entries.last(where: { $0.migration == migration })?.status != .completed else { return }
            document.entries.append(.init(migration: migration, status: .completed, timestamp: now()))
            try write(document)
        }

        func fail(_ migration: MigrationKind) throws {
            var document = try read()
            guard document.entries.last(where: { $0.migration == migration })?.status != .failed else { return }
            document.entries.append(.init(migration: migration, status: .failed, timestamp: now()))
            try write(document)
        }

        func isComplete(_ migration: MigrationKind) throws -> Bool {
            try read().entries.last(where: { $0.migration == migration })?.status == .completed
        }

        private func write(_ document: MigrationJournalDocument) throws {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(document).write(to: fileURL, options: .atomic)
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()

        private static let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
    }
}
