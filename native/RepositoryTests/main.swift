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

            // L267.a (Phase 12.00b.2-E): `protectCopiedLegacyFiles` (the gate
            // that raises copied `LegacyBackups/` files — which can hold the
            // G6 legacy Square/session-token residual — to complete file
            // protection) must treat a nil `FileManager.enumerator` the same
            // as a per-file `setAttributes` failure: a bounded diagnostic,
            // never a throw, never blocking the copy.
            // `FileManager.enumerator(at:includingPropertiesForKeys:)` cannot
            // be overridden from outside Foundation on this toolchain (it is
            // a `@nonobjc` extension method), so there is no way to force a
            // real nil enumerator from a host test; `testForcesNilLegacyFileProtectionEnumerator`
            // is the small internal seam that stands in for it. Production
            // never sets it (defaults to `false`).
            let nilEnumeratorRoot = root.appendingPathComponent("nil-enumerator-case", isDirectory: true)
            let nilEnumeratorSource = nilEnumeratorRoot.appendingPathComponent("rn-async-storage", isDirectory: true)
            try FileManager.default.createDirectory(at: nilEnumeratorSource, withIntermediateDirectories: true)
            try Data("{\"providerKeys\":{\"square\":\"EAAA-token\"}}".utf8)
                .write(to: nilEnumeratorSource.appendingPathComponent("manifest.json"), options: .atomic)
            var nilEnumeratorRepository = Canonical.SnapshotRepository(
                primaryURL: nilEnumeratorRoot.appendingPathComponent("store.json")
            )
            nilEnumeratorRepository.testForcesNilLegacyFileProtectionEnumerator = true
            let nilEnumeratorCopied = try nilEnumeratorRepository.preserveLegacyDirectory(
                nilEnumeratorSource, migration: .legacyNativeSnapshot, name: "AsyncStorage"
            )
            expect(FileManager.default.fileExists(
                       atPath: nilEnumeratorCopied.appendingPathComponent("manifest.json").path),
                   "L267.a a nil enumerator does not block the legacy directory copy (best effort, same as a per-file failure)")

            // The behavior above (no throw, copy still completes) is
            // identical whether or not the diagnostic fires, so it alone
            // cannot distinguish "logs a diagnostic" from "returns silently".
            // Pin the actual source: the nil-enumerator guard's failure body
            // must contain the exact same bounded log line the per-file
            // failure path below it already uses, not a new or absent one.
            let repositorySource = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("TradeReadyNative/Domain/SnapshotRepository.swift"),
                encoding: .utf8
            )
            if let functionStart = repositorySource.range(of: "private func protectCopiedLegacyFiles(in directory: URL) {"),
               let functionEnd = repositorySource.range(
                   of: "private func atomicWrite(", range: functionStart.upperBound..<repositorySource.endIndex
               )
            {
                let body = String(repositorySource[functionStart.upperBound..<functionEnd.lowerBound])
                let perFileFailureLog = "print(\"TradeReadyLegacyBackup stage=file-protection\")"
                expect(body.contains(perFileFailureLog),
                       "L267.a sanity: the per-file failure path logs the bounded diagnostic")
                if let guardStart = body.range(of: "guard "),
                   let guardElseStart = body.range(of: "else {", range: guardStart.upperBound..<body.endIndex),
                   let guardElseEnd = body.range(of: "}", range: guardElseStart.upperBound..<body.endIndex)
                {
                    let guardFailureBody = String(body[guardElseStart.upperBound..<guardElseEnd.lowerBound])
                    expect(guardFailureBody.contains(perFileFailureLog),
                           "L267.a a nil enumerator logs the same bounded diagnostic as a per-file failure, not a silent return")
                } else {
                    expect(false, "L267.a: the nil-enumerator guard-else body is locatable for the pin")
                }
            } else {
                expect(false, "L267.a: SnapshotRepository.swift source is readable for the nil-enumerator pin")
            }
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
        try scrubRepository.removeLiveAccountData()
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
