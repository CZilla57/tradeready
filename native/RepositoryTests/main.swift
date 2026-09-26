import Foundation

@main
struct RepositoryTests {
    static func main() throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-repository-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("store.json")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = Canonical.SnapshotRepository(primaryURL: primary, now: { fixedDate })

        let missing = try repository.load()
        expect(missing == nil, "missing repository has no snapshot")

        let first = snapshot(businessName: "First")
        let second = snapshot(businessName: "Second")
        try repository.save(first)
        let initialLoad = try repository.load()
        expect(label(of: initialLoad?.snapshot) == "First", "repository loads primary snapshot")

        try repository.save(second)
        let backup = try Canonical.SnapshotCodec.decode(Data(contentsOf: repository.backupURL))
        expect(label(of: backup) == "First", "save retains previous valid snapshot")

        let corruptBytes = Data("not-json-private-source".utf8)
        try corruptBytes.write(to: primary, options: .atomic)
        let recovered = try repository.load()
        expect(recovered?.source == .recoveredBackup, "corrupt primary recovers from backup")
        expect(label(of: recovered?.snapshot) == "First", "recovery returns last known good data")
        expect(recovered?.quarantinedURL.flatMap { try? Data(contentsOf: $0) } == corruptBytes,
               "recovery quarantines exact corrupt bytes")
        let repaired = try Canonical.SnapshotCodec.decode(Data(contentsOf: primary))
        expect(label(of: repaired) == "First", "recovery repairs primary snapshot")

        try FileManager.default.removeItem(at: primary)
        let restoredMissing = try repository.load()
        expect(restoredMissing?.source == .recoveredBackup && restoredMissing?.quarantinedURL == nil,
               "missing primary restores from backup")

        let legacy = Data("legacy source bytes".utf8)
        let legacyURL = try repository.preserveLegacyBytes(legacy, migration: .legacyNativeSnapshot)
        _ = try repository.preserveLegacyBytes(Data("replacement".utf8), migration: .legacyNativeSnapshot)
        let retainedLegacy = try Data(contentsOf: legacyURL)
        expect(retainedLegacy == legacy, "legacy backup is immutable across retries")

        // Task 11.13 fix round 3: preserved legacy bytes (which can hold an
        // RN-era plaintext Square token) are written with complete file
        // protection and the LegacyBackups tree is excluded from backup.
        // File protection is not observable on a macOS host, so the chosen
        // options are asserted through the seam; device proof is Phase 12.
        func excludedFromBackup(_ url: URL) -> Bool {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        }
        expect(Canonical.SnapshotRepository.legacyBackupWriteOptions == [.atomic, .completeFileProtection],
               "legacy backup writes use atomic + complete file protection")
        expect(Canonical.SnapshotRepository.legacyBackupFileProtection == .complete,
               "copied legacy directories are given complete file protection")
        expect(excludedFromBackup(repository.legacyBackupDirectoryURL),
               "preserveLegacyBytes excludes LegacyBackups from backup")
        do {
            let artifactRoot = root.appendingPathComponent("artifact-case", isDirectory: true)
            let artifactRepository = Canonical.SnapshotRepository(primaryURL: artifactRoot.appendingPathComponent("store.json"))
            _ = try artifactRepository.preserveLegacyArtifact(Data("{}".utf8), migration: .legacyNativeSnapshot,
                                                               filename: "app-group-values.json")
            expect(excludedFromBackup(artifactRepository.legacyBackupDirectoryURL),
                   "preserveLegacyArtifact excludes LegacyBackups from backup")

            let directoryRoot = root.appendingPathComponent("directory-case", isDirectory: true)
            let source = directoryRoot.appendingPathComponent("rn-async-storage", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("{\"providerKeys\":{\"square\":\"EAAA-token\"}}".utf8)
                .write(to: source.appendingPathComponent("manifest.json"), options: .atomic)
            let directoryRepository = Canonical.SnapshotRepository(primaryURL: directoryRoot.appendingPathComponent("store.json"))
            let copied = try directoryRepository.preserveLegacyDirectory(source, migration: .legacyNativeSnapshot,
                                                                         name: "AsyncStorage")
            expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("manifest.json").path),
                   "preserveLegacyDirectory still copies the source")
            expect(excludedFromBackup(directoryRepository.legacyBackupDirectoryURL),
                   "preserveLegacyDirectory excludes LegacyBackups from backup")

            // L267.a (Phase 12.00b.2-E fix round 1): review found the round-0
            // fix only made the nil-enumerator failure visible; it never
            // closed the fail-open. `preserveLegacyDirectory` protects a
            // published `LegacyBackups/` copy once (which can hold the G6
            // legacy Square/session-token residual); its only other caller,
            // `LegacyMigrationCoordinator.migrate`, short-circuits to
            // `.alreadyCompleted` once the journal is complete, so nothing
            // ever re-protected a copy that failed on its first pass.
            // `protectCopiedLegacyFiles` now reports an outcome instead of
            // `Void`, and `reprotectPublishedLegacyDirectory` re-runs it on an
            // already-published copy so a later launch heals a failed pass.
            // The nil-enumerator seam is now an init-injected closure
            // (`legacyFileEnumerator`), like `fileManager`/`now`, instead of a
            // mutable stored var — `FileManager.enumerator(at:includingPropertiesForKeys:)`
            // is a `@nonobjc` Swift-overlay method and cannot be subclassed or
            // overridden from outside Foundation on this toolchain, so this
            // closure is still the only way to force a real nil enumerator.
            let reprotectRoot = root.appendingPathComponent("reprotect-case", isDirectory: true)
            let reprotectSource = reprotectRoot.appendingPathComponent("rn-async-storage", isDirectory: true)
            try FileManager.default.createDirectory(at: reprotectSource, withIntermediateDirectories: true)
            try Data("{\"providerKeys\":{\"square\":\"EAAA-token\"}}".utf8)
                .write(to: reprotectSource.appendingPathComponent("manifest.json"), options: .atomic)
            try Data("second-file-bytes".utf8)
                .write(to: reprotectSource.appendingPathComponent("second.json"), options: .atomic)

            // A counting wrapper around the real enumerator lets the test
            // observe *that* protection was re-run (not just its result),
            // which is how the early-return and `.alreadyCompleted` call
            // sites are verified below without touching `private` internals.
            final class EnumeratorCallCounter { var count = 0 }
            let reprotectCounter = EnumeratorCallCounter()
            let reprotectRepository = Canonical.SnapshotRepository(
                primaryURL: reprotectRoot.appendingPathComponent("store.json"),
                legacyFileEnumerator: { url in
                    reprotectCounter.count += 1
                    return FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                }
            )
            let reprotectCopied = try reprotectRepository.preserveLegacyDirectory(
                reprotectSource, migration: .legacyNativeSnapshot, name: "AsyncStorage"
            )
            expect(FileManager.default.fileExists(atPath: reprotectCopied.appendingPathComponent("manifest.json").path),
                   "L267.a reprotect fixture: the legacy directory is published")
            expect(reprotectCounter.count == 1, "L267.a reprotect fixture: the first publish protects once")

            // Important 1, the published-destination early return
            // (SnapshotRepository.swift :281 pre-fix): a second call for a
            // name that already exists must re-protect, not just return the
            // URL silently.
            let secondPublish = try reprotectRepository.preserveLegacyDirectory(
                reprotectSource, migration: .legacyNativeSnapshot, name: "AsyncStorage"
            )
            expect(secondPublish == reprotectCopied,
                   "L267.a a second preserveLegacyDirectory call for the same name is still idempotent")
            expect(reprotectCounter.count == 2,
                   "L267.a the published-destination early return re-protects instead of returning silently")

            // Important 2, point 1: an enumerator failure is reported through
            // the outcome, not only logged.
            let enumeratorFailureRepository = Canonical.SnapshotRepository(
                primaryURL: reprotectRoot.appendingPathComponent("store.json"),
                legacyFileEnumerator: { _ in nil }
            )
            let enumeratorFailureOutcome = enumeratorFailureRepository.reprotectPublishedLegacyDirectory(
                migration: .legacyNativeSnapshot, name: "AsyncStorage"
            )
            expect(enumeratorFailureOutcome == .enumeratorUnavailable,
                   "L267.a a nil enumerator is reported as .enumeratorUnavailable through the outcome, not only logged")

            // Important 2, point 2: re-running the hook with a real enumerator
            // heals the copy — 0 failures, every file protected.
            let healedOutcome = reprotectRepository.reprotectPublishedLegacyDirectory(
                migration: .legacyNativeSnapshot, name: "AsyncStorage"
            )
            expect(healedOutcome == .completed(protected: 2, failed: 0),
                   "L267.a re-protecting an already-published copy protects every file with zero failures")

            // Nothing published yet: no directory to re-protect, and the hook
            // must not claim work was done.
            let neverPublishedRepository = Canonical.SnapshotRepository(
                primaryURL: root.appendingPathComponent("never-published-case/store.json")
            )
            expect(neverPublishedRepository.reprotectPublishedLegacyDirectory(
                       migration: .legacyNativeSnapshot, name: "AsyncStorage") == nil,
                   "L267.a re-protect is a no-op when nothing has been published yet")
        }

        let brokenPrimary = root.appendingPathComponent("broken.json")
        let brokenRepository = Canonical.SnapshotRepository(primaryURL: brokenPrimary)
        try Data("bad-primary".utf8).write(to: brokenPrimary, options: .atomic)
        try Data("bad-backup".utf8).write(to: brokenRepository.backupURL, options: .atomic)
        do {
            _ = try brokenRepository.load()
            expect(false, "two corrupt copies throw")
        } catch Canonical.SnapshotRepository.RepositoryError.corruptPrimaryNoUsableBackup {
            // Expected.
        }

        let journalURL = root.appendingPathComponent("migration-journal.json")
        let journal = Canonical.MigrationJournal(fileURL: journalURL, now: { fixedDate })
        let firstBegin = try journal.begin(.reactNativeAsyncStorage)
        let resumedBegin = try journal.begin(.reactNativeAsyncStorage)
        expect(firstBegin == .started, "journal records migration start")
        expect(resumedBegin == .resumed, "started migration resumes without duplicate")
        try journal.fail(.reactNativeAsyncStorage)
        let restartedBegin = try journal.begin(.reactNativeAsyncStorage)
        expect(restartedBegin == .started, "failed migration can restart")
        try journal.complete(.reactNativeAsyncStorage)
        try journal.complete(.reactNativeAsyncStorage)
        let completedBegin = try journal.begin(.reactNativeAsyncStorage)
        expect(completedBegin == .alreadyCompleted, "completed migration is idempotent")
        let document = try journal.read()
        expect(document.entries.map(\.status) == [.started, .failed, .started, .completed],
               "journal retains minimal lifecycle history")

        let journalObject = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        let entryObjects = journalObject?["entries"] as? [[String: Any]] ?? []
        expect(entryObjects.allSatisfy { Set($0.keys) == ["migration", "status", "timestamp"] },
               "journal schema cannot contain customer data or secrets")

        let diagnostics = repository.diagnostics(for: restoredMissing, journal: document)
        expect(diagnostics.snapshotSchemaVersion == Canonical.Snapshot.currentSchemaVersion,
               "diagnostics report snapshot schema")
        expect(diagnostics.snapshotStatus == .recovered && diagnostics.backupAvailable,
               "diagnostics report recovery and backup status")
        expect(diagnostics.migrations.first(where: { $0.migration == .reactNativeAsyncStorage })?.status == .completed,
               "diagnostics report latest migration status")
        let diagnosticObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics)) as? [String: Any]
        expect(Set(diagnosticObject?.keys.map { $0 } ?? []) == [
            "snapshotSchemaVersion", "snapshotStatus", "backupAvailable", "counts", "migrations",
            // Phase 12 (12.00b.1, I2): the refused-change count, a count only.
            "rejectedChangeCount"
        ], "diagnostics expose counts and status only")

        let supportReport = try diagnostics.encodedSupportReport(appVersion: "2.4.1")
        let repeatedSupportReport = try diagnostics.encodedSupportReport(appVersion: "2.4.1")
        expect(supportReport == repeatedSupportReport, "support report bytes are deterministic")
        let expectedSupportReport = "{\"appVersion\":\"2.4.1\",\"backupAvailable\":true,\"migrationStatuses\":[{\"migration\":\"canonical-snapshot-v0-to-v1\",\"status\":null},{\"migration\":\"legacy-native-snapshot-to-v1\",\"status\":null},{\"migration\":\"react-native-async-storage-to-v1\",\"status\":\"completed\"}],\"recordCounts\":{\"bookingRequests\":0,\"customerNotes\":0,\"customers\":0,\"expenses\":0,\"invoices\":0,\"jobPhotos\":0,\"jobs\":0,\"pricebook\":0,\"recurringInvoices\":0,\"recurringJobs\":0,\"trips\":0},\"rejectedChangeCount\":0,\"reportSchemaVersion\":2,\"snapshotSchemaVersion\":1,\"snapshotStatus\":\"recovered\"}"
        expect(supportReport == Data(expectedSupportReport.utf8),
               "support report matches canonical sorted JSON bytes")

        let supportObject = try JSONSerialization.jsonObject(with: supportReport) as? [String: Any]
        expect(Set(supportObject?.keys.map { $0 } ?? []) == [
            "reportSchemaVersion", "appVersion", "snapshotSchemaVersion", "snapshotStatus",
            "backupAvailable", "recordCounts", "migrationStatuses", "rejectedChangeCount"
        ], "support report has a closed top-level schema")
        expect(Canonical.PersistenceSupportReport.currentSchemaVersion == 2,
               "support report schema v2 (12.00b.1 adds rejectedChangeCount)")
        var withRefusals = diagnostics
        withRefusals.rejectedChangeCount = 3
        let refusalReport = String(decoding: try withRefusals.encodedSupportReport(appVersion: "2.4.1"), as: UTF8.self)
        expect(refusalReport.contains("\"rejectedChangeCount\":3"), "support report carries the refused-change count")
        let decodedReport = try JSONDecoder().decode(Canonical.PersistenceSupportReport.self, from: Data(refusalReport.utf8))
        expect(decodedReport == .init(appVersion: "2.4.1", diagnostics: withRefusals), "support report v2 round-trips")
        expect(supportObject?["reportSchemaVersion"] as? Int == Canonical.PersistenceSupportReport.currentSchemaVersion,
               "support report identifies its schema")
        expect(supportObject?["appVersion"] as? String == "2.4.1",
               "support report identifies the app version")

        let reportCounts = supportObject?["recordCounts"] as? [String: Any]
        expect(Set(reportCounts?.keys.map { $0 } ?? []) == [
            "invoices", "jobs", "customers", "expenses", "customerNotes", "recurringJobs",
            "recurringInvoices", "trips", "pricebook", "bookingRequests", "jobPhotos"
        ], "support report exposes record counts only")
        let reportMigrations = supportObject?["migrationStatuses"] as? [[String: Any]] ?? []
        expect(reportMigrations.count == Canonical.MigrationKind.allCases.count,
               "support report includes every migration status")
        expect(reportMigrations.allSatisfy { Set($0.keys) == ["migration", "status"] },
               "support report migration entries have a closed schema")
        let migrationNames = reportMigrations.compactMap { $0["migration"] as? String }
        expect(migrationNames == migrationNames.sorted(), "support report migration order is stable")

        let reportText = String(decoding: supportReport, as: UTF8.self)
        let forbiddenReportValues = [
            root.path, "First", "not-json-private-source", "legacy source bytes",
            "fixture-customer-id", "fixture-provider-secret", "customerName", "providerKey"
        ]
        expect(forbiddenReportValues.allSatisfy { !reportText.contains($0) },
               "support report contains no paths, raw data, customer fields, IDs, or secrets")

        let scrubPrimary = root.appendingPathComponent("Scrub/store.json")
        let scrubRepository = Canonical.SnapshotRepository(primaryURL: scrubPrimary)
        try scrubRepository.save(first)
        try scrubRepository.save(second)
        let quarantine = scrubPrimary.deletingLastPathComponent()
            .appendingPathComponent("store.json.corrupt-1700000000000")
        try Data("private-corrupt-copy".utf8).write(to: quarantine, options: .atomic)
        let retained = try scrubRepository.preserveLegacyBytes(
            Data("immutable-recovery-source".utf8), migration: .reactNativeAsyncStorage
        )
        try FileManager.default.createDirectory(
            at: scrubRepository.liveMediaDirectoryURL, withIntermediateDirectories: true
        )
        try Data("adopted-photo".utf8).write(
            to: scrubRepository.liveMediaDirectoryURL.appendingPathComponent("photo.jpg")
        )
        let workspace = scrubPrimary.deletingLastPathComponent()
            .appendingPathComponent("native-account-workspace.json")
        try Data("account-bound-onboarding".utf8).write(to: workspace, options: .atomic)
        try Data("account-bound-onboarding-backup".utf8).write(
            to: workspace.appendingPathExtension("backup"), options: .atomic
        )
        try scrubRepository.beginAccountScrub()
        expect(scrubRepository.isAccountScrubPending
               && scrubRepository.pendingAccountScrubScope == .live,
               "account scrub publishes its crash-recovery marker first")
        expect(!scrubRepository.isLiveWorkspaceClearedByAccountScrub,
               "P12-003: sanity: no scrub-cleared record before the removal")
        try scrubRepository.removeLiveAccountData()
        // Phase 12 (12.00b.2-G, P12-003): the removal records that a scrub
        // cleared the live workspace, with no account data in the record.
        expect(scrubRepository.isLiveWorkspaceClearedByAccountScrub,
               "P12-003: removing the live workspace records that a scrub cleared it")
        let clearedRecord = (try? Data(contentsOf: scrubRepository.accountScrubClearedMarkerURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        expect(clearedRecord.map { Set($0.keys) == ["schemaVersion"] } == true,
               "P12-003: the scrub-cleared record holds only its schema version")
        expect(!FileManager.default.fileExists(atPath: scrubPrimary.path)
               && !FileManager.default.fileExists(atPath: scrubRepository.backupURL.path)
               && !FileManager.default.fileExists(atPath: quarantine.path)
               && !FileManager.default.fileExists(atPath: scrubRepository.liveMediaDirectoryURL.path)
               && !FileManager.default.fileExists(atPath: workspace.path)
               && !FileManager.default.fileExists(atPath: workspace.appendingPathExtension("backup").path),
               "account scrub removes snapshots, quarantines, live media, and onboarding state")
        expect((try? Data(contentsOf: retained)) == Data("immutable-recovery-source".utf8),
               "account scrub preserves the immutable migration recovery source")
        expect(scrubRepository.isAccountScrubPending,
               "account scrub marker remains until other account surfaces are cleared")
        try scrubRepository.finishAccountScrub()
        let scrubbedLoad = try scrubRepository.load()
        expect(!scrubRepository.isAccountScrubPending && scrubbedLoad == nil,
               "finished account scrub cannot recover signed-out data")
        expect(Canonical.SnapshotRepository(primaryURL: scrubPrimary).isLiveWorkspaceClearedByAccountScrub,
               "P12-003: the scrub-cleared record outlives the scrub (the next launch reads it)")
        try scrubRepository.save(first)
        expect(!scrubRepository.isLiveWorkspaceClearedByAccountScrub
               && !FileManager.default.fileExists(atPath: scrubRepository.accountScrubClearedMarkerURL.path),
               "P12-003: the next save ends the scrub-cleared state")
        try scrubRepository.save(second)
        expect(!scrubRepository.isLiveWorkspaceClearedByAccountScrub,
               "P12-003: a later save leaves no scrub-cleared record")

        let deletionPrimary = root.appendingPathComponent("Deletion/store.json")
        let deletionRepository = Canonical.SnapshotRepository(primaryURL: deletionPrimary)
        try deletionRepository.save(first)
        let deletionLegacy = try deletionRepository.preserveLegacyBytes(
            Data("delete-me".utf8), migration: .reactNativeAsyncStorage
        )
        let deletionDirectory = deletionPrimary.deletingLastPathComponent()
        for path in ["auxiliary-state.json", "migration-journal.json", "tradeready-support-report.json"] {
            try Data("delete-me".utf8).write(
                to: deletionDirectory.appendingPathComponent(path), options: .atomic
            )
        }
        try deletionRepository.beginAccountScrub(scope: .all)
        expect(deletionRepository.pendingAccountScrubScope == .all,
               "permanent deletion survives interruption without storing an account identifier")
        try deletionRepository.removeAllAccountData()
        expect(!FileManager.default.fileExists(atPath: deletionLegacy.path)
               && !FileManager.default.fileExists(
                    atPath: deletionDirectory.appendingPathComponent("auxiliary-state.json").path
               ), "permanent deletion removes recovery and activation artifacts")
        expect(!deletionRepository.isLiveWorkspaceClearedByAccountScrub,
               "P12-003: permanent deletion leaves no scrub-cleared record (its journal is gone too)")
        try deletionRepository.finishAccountScrub()

        if failures == 0 { print("PASS: snapshot repository and migration journal tests") }
        else { print("FAILED: \(failures) repository test(s)"); exit(1) }
    }

    private static func snapshot(businessName: String) -> Canonical.Snapshot {
        Canonical.Snapshot(payload: .init(unknownFields: [
            "testLabel": .string(businessName),
            "customerName": .string("Fixture Customer"),
            "customerId": .string("fixture-customer-id"),
            "providerKey": .string("fixture-provider-secret")
        ]))
    }

    private static func label(of snapshot: Canonical.Snapshot?) -> String? {
        guard case let .string(value)? = snapshot?.payload.unknownFields["testLabel"] else { return nil }
        return value
    }
}
