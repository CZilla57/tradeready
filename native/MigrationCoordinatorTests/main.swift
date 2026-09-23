import Foundation

private enum SimulatedSecureWriteError: Error { case beforeWrite }

private final class MemorySecureKeyValueBackend: NativeSecureKeyValueBacking {
    var values: [String: Data] = [:]
    private(set) var writeKeys: [String] = []
    var shouldFailBeforeWrite: ((String) -> Bool)?

    func upsert(_ value: Data, key: String) throws {
        writeKeys.append(key)
        if shouldFailBeforeWrite?(key) == true {
            throw SimulatedSecureWriteError.beforeWrite
        }
        values[key] = value
    }

    func read(key: String) throws -> Data? {
        values[key]
    }

    func remove(key: String) throws {
        values.removeValue(forKey: key)
    }
}

private enum SimulatedInterruption: Error { case afterSnapshotWrite }

@main
struct MigrationCoordinatorTests {
    @MainActor
    static func main() throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let pointerKey = LegacyDataImporter.supabaseSessionKey
        let generationOne = "11111111-1111-4111-8111-111111111111"
        let generationTwo = "22222222-2222-4222-8222-222222222222"
        let generationThree = "33333333-3333-4333-8333-333333333333"
        let secureBackend = MemorySecureKeyValueBackend()
        let generationStore = NativeGenerationSecureValueStore(
            backend: secureBackend,
            pointerKey: pointerKey,
            makeGeneration: { generationOne }
        )
        let rawSession = Data((0..<5_137).map { UInt8($0 % 251) })
        try generationStore.publish(rawSession)
        let reconstructedRawSession = try generationStore.read()
        expect(reconstructedRawSession == rawSession,
               "generation store reconstructs the exact opaque session bytes")
        let activePointer = secureBackend.values[pointerKey]
        let decodedPointer = try JSONDecoder().decode(
            NativeGenerationSecureValueStore.ActivePointer.self,
            from: activePointer!
        )
        expect(decodedPointer.schemaVersion == NativeGenerationSecureValueStore.currentSchemaVersion
               && decodedPointer.byteLength == rawSession.count
               && decodedPointer.chunkCount == 3
               && decodedPointer.sha256.count == 64,
               "active pointer records version, byte length, chunk count, and SHA-256")
        let firstChunkKeys = secureBackend.values.keys.filter {
            $0.contains(".generation.\(generationOne).chunk.")
        }
        expect(firstChunkKeys.count == 3,
               "session bytes are split into the expected generation chunks")
        expect(firstChunkKeys.allSatisfy { (secureBackend.values[$0]?.count ?? 0) <= 2_048 },
               "no native session chunk exceeds 2048 raw bytes")
        expect(activePointer != rawSession && (activePointer?.count ?? 0) < rawSession.count,
               "active pointer contains metadata rather than raw session bytes")

        let interruptedChunkStore = NativeGenerationSecureValueStore(
            backend: secureBackend,
            pointerKey: pointerKey,
            makeGeneration: { generationTwo }
        )
        secureBackend.shouldFailBeforeWrite = {
            $0 == "\(pointerKey).generation.\(generationTwo).chunk.1"
        }
        do {
            try interruptedChunkStore.publish(Data(repeating: 0xa5, count: 5_000))
            expect(false, "injected chunk interruption throws")
        } catch SimulatedSecureWriteError.beforeWrite {}
        expect(secureBackend.values[pointerKey] == activePointer,
               "chunk-write interruption cannot replace the active pointer")
        let sessionAfterChunkInterruption = try generationStore.read()
        expect(sessionAfterChunkInterruption == rawSession,
               "chunk-write interruption leaves the prior active session readable")

        let interruptedPointerStore = NativeGenerationSecureValueStore(
            backend: secureBackend,
            pointerKey: pointerKey,
            makeGeneration: { generationThree }
        )
        secureBackend.shouldFailBeforeWrite = { $0 == pointerKey }
        do {
            try interruptedPointerStore.publish(Data(repeating: 0x5a, count: 4_500))
            expect(false, "injected pointer interruption throws")
        } catch SimulatedSecureWriteError.beforeWrite {}
        secureBackend.shouldFailBeforeWrite = nil
        expect(secureBackend.values[pointerKey] == activePointer,
               "failure before pointer publication preserves the prior pointer")
        let sessionAfterPointerInterruption = try generationStore.read()
        expect(sessionAfterPointerInterruption == rawSession,
               "failure before pointer publication preserves the prior active session")

        let nativeSettingsStore = NativeKeychainSecureSettingsStore(backend: secureBackend)
        let nativeSettings = LegacySecureSettings(
            providerKey: "provider-secret",
            anthropicKey: "anthropic-secret",
            groqKey: "groq-secret",
            supabaseSession: rawSession
        )
        let sessionWriteCountBeforeIdempotentPersist = secureBackend.writeKeys.filter {
            $0 == pointerKey || $0.contains("\(pointerKey).generation.")
        }.count
        try nativeSettingsStore.persist(nativeSettings)
        let sessionWriteCountAfterIdempotentPersist = secureBackend.writeKeys.filter {
            $0 == pointerKey || $0.contains("\(pointerKey).generation.")
        }.count
        expect(sessionWriteCountAfterIdempotentPersist == sessionWriteCountBeforeIdempotentPersist,
               "identical active session persistence is an idempotent no-op")
        expect(secureBackend.values["providerKey"] == Data("provider-secret".utf8)
               && secureBackend.values["anthropicKey"] == Data("anthropic-secret".utf8)
               && secureBackend.values["groqKey"] == Data("groq-secret".utf8),
               "provider credentials remain verified byte-oriented upserts")
        let providerBeforeConflict = secureBackend.values["providerKey"]
        do {
            try nativeSettingsStore.persist(LegacySecureSettings(
                providerKey: "must-not-replace-provider",
                supabaseSession: Data("different-session".utf8)
            ))
            expect(false, "different active session must conflict")
        } catch NativeSecureSettingsStoreError.conflictingNativeSession {}
        expect(secureBackend.values["providerKey"] == providerBeforeConflict,
               "session conflict is detected before provider credentials mutate")
        let sessionAfterConflict = try nativeSettingsStore.readSupabaseSession()
        expect(sessionAfterConflict == rawSession,
               "session conflict leaves the existing active generation unchanged")

        let savedFirstChunk = secureBackend.values[
            "\(pointerKey).generation.\(generationOne).chunk.0"
        ]!
        secureBackend.values["\(pointerKey).generation.\(generationOne).chunk.0"] = Data([0xff])
        do {
            _ = try nativeSettingsStore.readSupabaseSession()
            expect(false, "tampered session chunk must fail validation")
        } catch NativeSecureSettingsStoreError.verificationFailed {}
        secureBackend.values["\(pointerKey).generation.\(generationOne).chunk.0"] = savedFirstChunk
        secureBackend.values.removeValue(
            forKey: "\(pointerKey).generation.\(generationOne).chunk.1"
        )
        do {
            _ = try nativeSettingsStore.readSupabaseSession()
            expect(false, "missing active session chunk must fail validation")
        } catch NativeSecureSettingsStoreError.verificationFailed {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-migration-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let auxiliarySnapshotURL = root.appendingPathComponent("Auxiliary/store.json")
        let auxiliaryStore = NativeAuxiliaryStateStore(snapshotURL: auxiliarySnapshotURL)
        let accountKeys = [
            "onboardingComplete", "onboardingStage", "onboardingDraft",
            "setupChecklistState", "review_requests", "dismissed_duplicate_pairs",
            "insightMutes", "invoiceReminderPromptShown"
        ]
        var auxiliaryValues = Dictionary(uniqueKeysWithValues: accountKeys.map {
            ($0, Data("value-for-\($0)".utf8))
        })
        auxiliaryValues["__themePreference"] = Data("dark".utf8)
        auxiliaryValues["tr_import_history_v1"] = Data("[]".utf8)
        auxiliaryValues["__syncQueue"] = Data("[{\"id\":\"queued\"}]".utf8)
        auxiliaryValues["__lastSyncedAt"] = Data("{\"version\":2,\"tables\":{}}".utf8)
        auxiliaryValues["__dataOwner"] = Data("\"user-1\"".utf8)
        auxiliaryValues["__initDone_user-1"] = Data("true".utf8)
        auxiliaryValues["__collBackfill_v1_user-1"] = Data("done".utf8)
        let opaqueBytes = Data([0x00, 0xff, 0x80, 0x0a, 0x7b])
        auxiliaryValues["future-opaque-key"] = opaqueBytes

        let firstArtifact = try auxiliaryStore.persist(auxiliaryValues)
        let firstArtifactBytes = try Data(contentsOf: auxiliaryStore.fileURL)
        let loadedArtifact = try auxiliaryStore.load()
        let loadedValues = Dictionary(uniqueKeysWithValues: loadedArtifact.entries.map { ($0.key, $0.value) })
        expect(loadedArtifact.schemaVersion == NativeAuxiliaryStateArtifact.currentSchemaVersion,
               "auxiliary artifact identifies its schema version")
        expect(loadedValues == auxiliaryValues && loadedValues["future-opaque-key"] == opaqueBytes,
               "auxiliary artifact round-trips every exact binary value")
        expect(loadedArtifact.entries.map(\.key) == auxiliaryValues.keys.sorted(),
               "auxiliary artifact entries use deterministic key order")
        let reversedValues = Dictionary(
            uniqueKeysWithValues: auxiliaryValues.keys.sorted(by: >).map { ($0, auxiliaryValues[$0]!) }
        )
        let reversedBytes = try NativeAuxiliaryStateStore.encode(
            NativeAuxiliaryStateArtifact(values: reversedValues)
        )
        expect(reversedBytes == firstArtifactBytes,
               "auxiliary encoding is deterministic across input insertion order")

        let entriesByKey = Dictionary(uniqueKeysWithValues: firstArtifact.entries.map { ($0.key, $0) })
        expect(entriesByKey["__themePreference"]?.scope == .device
               && entriesByKey["__themePreference"]?.activationPolicy == .restorable,
               "theme preference is device-scoped and restorable")
        expect(entriesByKey["tr_import_history_v1"]?.scope == .device
               && entriesByKey["tr_import_history_v1"]?.activationPolicy == .restorable,
               "CSV import history remains device-scoped")
        expect(accountKeys.allSatisfy {
            entriesByKey[$0]?.scope == .account
                && entriesByKey[$0]?.activationPolicy == .activateAfterIdentity
        }, "known account state waits for established identity")
        expect(entriesByKey["__initDone_user-1"]?.scope == .perUser
               && entriesByKey["__initDone_user-1"]?.activationPolicy == .preserveOnly
               && entriesByKey["__collBackfill_v1_user-1"]?.scope == .perUser
               && entriesByKey["__collBackfill_v1_user-1"]?.activationPolicy == .preserveOnly,
               "legacy per-user markers are preserved but never activated")
        expect(["__syncQueue", "__lastSyncedAt", "__dataOwner"].allSatisfy {
            entriesByKey[$0]?.scope == .account
                && entriesByKey[$0]?.activationPolicy == .preserveOnly
        }, "legacy sync state remains inert pending a sync-specific reconciler")
        expect(entriesByKey["future-opaque-key"]?.scope == .unknown
               && entriesByKey["future-opaque-key"]?.activationPolicy == .preserveOnly,
               "unknown auxiliary state remains opaque and inactive")

        _ = try auxiliaryStore.persist(reversedValues)
        let idempotentArtifactBytes = try Data(contentsOf: auxiliaryStore.fileURL)
        expect(idempotentArtifactBytes == firstArtifactBytes,
               "identical auxiliary retry leaves artifact bytes unchanged")
        var conflictingValues = auxiliaryValues
        conflictingValues["future-opaque-key"] = Data("changed".utf8)
        do {
            _ = try auxiliaryStore.persist(conflictingValues)
            expect(false, "conflicting auxiliary retry must fail")
        } catch NativeAuxiliaryStateStoreError.conflictingExistingArtifact {}
        let artifactBytesAfterConflict = try Data(contentsOf: auxiliaryStore.fileURL)
        expect(artifactBytesAfterConflict == firstArtifactBytes,
               "conflicting auxiliary retry cannot replace the artifact")

        let asyncStorage = root.appendingPathComponent("RCTAsyncLocalStorage_V1", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: asyncStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

        let fixtureRoot = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
        let richData = try Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("canonical-rich.json"))
        let rich = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: richData)
        let customerArray = try JSONEncoder().encode(Canonical.JSONValue.array([rich["customer"]!]))
        let richObject = try JSONSerialization.jsonObject(with: richData) as! [String: Any]
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x01, 0x02, 0xFF, 0xD9])
        let existingJPEGBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x03, 0x04, 0xFF, 0xD9])
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let legacyPhoto = documents.appendingPathComponent("photos/legacy.jpg")
        let missingPhoto = documents.appendingPathComponent("photos/missing.jpg")
        let legacyReceipt = documents.appendingPathComponent("receipts/receipt.png")
        let legacyLogo = documents.appendingPathComponent("logos/logo.png")
        let existingPhotoID = "p123_existing"
        let existingPhoto = documents.appendingPathComponent("job-photos/\(existingPhotoID).jpg")

        var jobObject = richObject["job"] as! [String: Any]
        jobObject["photos"] = [legacyPhoto.absoluteString, missingPhoto.absoluteString]
        let jobID = jobObject["id"] as! String
        var expenseObject = richObject["expense"] as! [String: Any]
        expenseObject["receiptUri"] = legacyReceipt.absoluteString
        var settingsObject = richObject["settings"] as! [String: Any]
        settingsObject["logoPhoto"] = legacyLogo.absoluteString
        let existingJobPhoto: [String: Any] = [
            "id": existingPhotoID,
            "jobId": jobID,
            "createdAt": "2026-01-01T00:00:00.000Z"
        ]
        let jobData = try JSONSerialization.data(withJSONObject: [jobObject], options: [.sortedKeys])
        let expenseData = try JSONSerialization.data(withJSONObject: [expenseObject], options: [.sortedKeys])
        let jobPhotoData = try JSONSerialization.data(withJSONObject: [existingJobPhoto], options: [.sortedKeys])
        let settingsData = try JSONSerialization.data(withJSONObject: settingsObject, options: [.sortedKeys])
        let manifest: [String: Any] = [
            "customers": String(decoding: customerArray, as: UTF8.self),
            "jobs": String(decoding: jobData, as: UTF8.self),
            "expenses": String(decoding: expenseData, as: UTF8.self),
            "jobPhotos": String(decoding: jobPhotoData, as: UTF8.self),
            "settings": String(decoding: settingsData, as: UTF8.self),
            "syncCursor": "opaque-cursor-value",
            "onboardingStage": "auxiliary-private-value",
            "__themePreference": "dark"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: asyncStorage.appendingPathComponent("manifest.json"), options: .atomic)
        let orphanBytes = Data("unmodeled-side-file".utf8)
        try orphanBytes.write(to: asyncStorage.appendingPathComponent("orphan-sidecar"), options: .atomic)

        for directoryName in LegacyDataImporter.legacyPhotoDirectories {
            let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(directoryName)-bytes".utf8).write(
                to: directory.appendingPathComponent("asset.bin"), options: .atomic
            )
        }
        try jpegBytes.write(to: legacyPhoto, options: .atomic)
        try pngBytes.write(to: legacyReceipt, options: .atomic)
        try pngBytes.write(to: legacyLogo, options: .atomic)
        try existingJPEGBytes.write(to: existingPhoto, options: .atomic)

        let primary = root.appendingPathComponent("Native/store.json")
        let repository = Canonical.SnapshotRepository(primaryURL: primary)
        let journal = Canonical.MigrationJournal(
            fileURL: primary.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
        )
        let coordinatorSecureBackend = MemorySecureKeyValueBackend()
        let secureStore = NativeKeychainSecureSettingsStore(backend: coordinatorSecureBackend)
        var shouldInterrupt = true
        var checkpoints: [LegacyMigrationCheckpoint] = []
        let coordinator = LegacyMigrationCoordinator(
            repository: repository,
            journal: journal,
            secureStore: secureStore,
            checkpoint: { point in
                checkpoints.append(point)
                if point == .snapshotPersisted, shouldInterrupt {
                    shouldInterrupt = false
                    throw SimulatedInterruption.afterSnapshotWrite
                }
            }
        )
        let source = LegacyMigrationSource(
            asyncStorageDirectory: asyncStorage,
            documentsDirectory: documents,
            secureSettings: .init(
                providerKey: "provider-secret",
                anthropicKey: "anthropic-secret",
                groqKey: "groq-secret",
                supabaseSession: Data(
                    "{\"access_token\":\"access-secret\",\"refresh_token\":\"refresh-secret\"}".utf8
                )
            ),
            appGroupValues: [
                "widgetSnapshot": "private-widget-state",
                "pendingOpenUrl": "tradeready://job/private-id"
            ]
        )

        do {
            _ = try coordinator.migrate(currentSettings: BusinessSettings(), source: source)
            expect(false, "simulated interruption throws")
        } catch SimulatedInterruption.afterSnapshotWrite {}
        let incomplete = try journal.isComplete(.reactNativeAsyncStorage)
        expect(!incomplete, "interrupted migration remains incomplete")
        expect(coordinatorSecureBackend.writeKeys.filter { $0 == pointerKey }.count == 1,
               "secure session was atomically committed before interruption")
        expect(Array(checkpoints.prefix(5)) == [
            .journaled, .sourceBackedUp, .photosAdopted, .auxiliaryPersisted, .secretsPersisted
        ], "photos are adopted only after backups and before auxiliary state and secrets")

        let migratedAuxiliaryStore = NativeAuxiliaryStateStore(snapshotURL: primary)
        let migratedAuxiliary = try migratedAuxiliaryStore.load()
        let migratedAuxiliaryValues = Dictionary(
            uniqueKeysWithValues: migratedAuxiliary.entries.map { ($0.key, $0.value) }
        )
        expect(migratedAuxiliaryValues["onboardingStage"] == Data("auxiliary-private-value".utf8)
               && migratedAuxiliaryValues["syncCursor"] == Data("opaque-cursor-value".utf8),
               "coordinator captures every imported auxiliary value exactly")
        expect(migratedAuxiliary.entries.first(where: { $0.key == "syncCursor" })?.scope == .unknown,
               "unrecognized imported state is preserved without activation")

        let retried = try coordinator.migrate(currentSettings: BusinessSettings(), source: source)
        expect(retried.status == .migrated, "interrupted migration resumes")
        expect(retried.adoptedPhotoCount == 4 && retried.deferredPhotoCount == 1,
               "retry reports adopted and deliberately deferred logical photo assets")
        let complete = try journal.isComplete(.reactNativeAsyncStorage)
        expect(complete, "retry completes journal")
        expect(coordinatorSecureBackend.writeKeys.filter { $0 == "groqKey" }.count == 2
               && coordinatorSecureBackend.values["groqKey"] == Data("groq-secret".utf8),
               "secure upserts replay without duplication or loss")
        let migratedSecureSession = try secureStore.readSupabaseSession()
        expect(coordinatorSecureBackend.writeKeys.filter { $0 == pointerKey }.count == 1
               && migratedSecureSession == source.secureSettings.supabaseSession,
               "opaque Supabase bytes migrate once through the secure checkpoint")

        let storedBytes = try Data(contentsOf: primary)
        let stored = try Canonical.SnapshotCodec.decode(storedBytes)
        expect(stored.payload.customers?.count == 1, "retry replaces snapshot without duplicate records")
        expect(stored.payload.settings.map(CanonicalUIAdapters.settings(from:))?.appearance == .dark,
               "strictly validated device theme is restored into native canonical settings")
        let stableLegacyPhotoID = LegacyDataImporter.stableLegacyPhotoID(
            jobID: jobID,
            legacyReference: legacyPhoto.absoluteString
        )
        expect(stored.payload.jobPhotos?.map(\.id).sorted()
               == [existingPhotoID, stableLegacyPhotoID].sorted(),
               "interrupted retry creates no duplicate JobPhoto metadata")
        expect(stored.payload.jobs?.first?.photos == [missingPhoto.absoluteString],
               "missing legacy photo reference remains recoverable in the canonical snapshot")
        let nativeMedia = primary.deletingLastPathComponent().appendingPathComponent("Media")
        let adoptedLegacyBytes = try Data(
            contentsOf: nativeMedia.appendingPathComponent("job-photos/\(stableLegacyPhotoID).jpg")
        )
        let adoptedExistingBytes = try Data(
            contentsOf: nativeMedia.appendingPathComponent("job-photos/\(existingPhotoID).jpg")
        )
        let preservedLegacyPhotoBytes = try Data(contentsOf: legacyPhoto)
        let preservedLegacyReceiptBytes = try Data(contentsOf: legacyReceipt)
        let preservedLegacyLogoBytes = try Data(contentsOf: legacyLogo)
        expect(adoptedLegacyBytes == jpegBytes,
               "legacy job photo bytes are copied exactly to their deterministic native path")
        expect(adoptedExistingBytes == existingJPEGBytes,
               "existing JobPhoto bytes are preserved exactly")
        expect(preservedLegacyPhotoBytes == jpegBytes
               && preservedLegacyReceiptBytes == pngBytes
               && preservedLegacyLogoBytes == pngBytes,
               "photo adoption never deletes or changes Expo source files")
        let storedText = String(decoding: storedBytes, as: UTF8.self)
        expect(!storedText.contains("provider-secret") && !storedText.contains("anthropic-secret")
               && !storedText.contains("groq-secret") && !storedText.contains("access-secret")
               && !storedText.contains("refresh-secret")
               && !storedText.contains("auxiliary-private-value")
               && !storedText.contains("opaque-cursor-value"),
               "plain snapshot excludes credentials, auth session, and auxiliary state")

        let diagnostics = repository.diagnostics(for: try repository.load(), journal: try journal.read())
        let supportReport = try diagnostics.encodedSupportReport(appVersion: "migration-test")
        let supportText = String(decoding: supportReport, as: UTF8.self)
        expect(!supportText.contains("onboardingStage")
               && !supportText.contains("auxiliary-private-value")
               && !supportText.contains("syncCursor")
               && !supportText.contains("opaque-cursor-value"),
               "support report excludes auxiliary keys and values")

        let backupRoot = repository.legacyBackupDirectoryURL
            .appendingPathComponent(Canonical.MigrationKind.reactNativeAsyncStorage.rawValue, isDirectory: true)
        let asyncBackup = backupRoot.appendingPathComponent("AsyncStorage", isDirectory: true)
        let backedManifest = try Data(contentsOf: asyncBackup.appendingPathComponent("manifest.json"))
        let backedOrphan = try Data(contentsOf: asyncBackup.appendingPathComponent("orphan-sidecar"))
        expect(backedManifest == manifestData, "whole AsyncStorage manifest is backed up exactly")
        expect(backedOrphan == orphanBytes, "whole AsyncStorage directory includes unreferenced sidecars")
        for directoryName in LegacyDataImporter.legacyPhotoDirectories {
            let backedUp = backupRoot.appendingPathComponent("Documents/\(directoryName)/asset.bin")
            expect(FileManager.default.fileExists(atPath: backedUp.path), "\(directoryName) photo directory is backed up")
        }
        let appGroupBackup = try Data(contentsOf: backupRoot.appendingPathComponent("app-group-values.json"))
        let appGroupObject = try JSONDecoder().decode([String: String].self, from: appGroupBackup)
        expect(appGroupObject == source.appGroupValues, "raw app-group values are backed up")

        let completedReplay = try coordinator.migrate(currentSettings: BusinessSettings(), source: source)
        expect(completedReplay.status == .alreadyCompleted, "completed migration re-run is a no-op")
        expect(coordinatorSecureBackend.writeKeys.filter { $0 == "groqKey" }.count == 2,
               "completed re-run does not touch Keychain")

        let conflictRoot = root.appendingPathComponent("PhotoConflict", isDirectory: true)
        let conflictDocuments = conflictRoot.appendingPathComponent("Documents", isDirectory: true)
        let conflictAsyncStorage = conflictRoot.appendingPathComponent("AsyncStorage", isDirectory: true)
        let conflictPhoto = conflictDocuments.appendingPathComponent("photos/source.jpg")
        try FileManager.default.createDirectory(
            at: conflictPhoto.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: conflictAsyncStorage, withIntermediateDirectories: true)
        try jpegBytes.write(to: conflictPhoto, options: .atomic)
        var conflictJob = jobObject
        conflictJob["photos"] = [conflictPhoto.absoluteString]
        let conflictJobData = try JSONSerialization.data(withJSONObject: [conflictJob], options: [.sortedKeys])
        let conflictManifest: [String: Any] = [
            "jobs": String(decoding: conflictJobData, as: UTF8.self)
        ]
        try JSONSerialization.data(withJSONObject: conflictManifest, options: [.sortedKeys]).write(
            to: conflictAsyncStorage.appendingPathComponent("manifest.json"), options: .atomic
        )
        let conflictPrimary = conflictRoot.appendingPathComponent("Native/store.json")
        let conflictRepository = Canonical.SnapshotRepository(primaryURL: conflictPrimary)
        let conflictJournal = Canonical.MigrationJournal(
            fileURL: conflictPrimary.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
        )
        let conflictID = LegacyDataImporter.stableLegacyPhotoID(
            jobID: jobID, legacyReference: conflictPhoto.absoluteString
        )
        let conflictDestination = conflictPrimary.deletingLastPathComponent()
            .appendingPathComponent("Media/job-photos/\(conflictID).jpg")
        try FileManager.default.createDirectory(
            at: conflictDestination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try existingJPEGBytes.write(to: conflictDestination, options: .atomic)
        let conflictCoordinator = LegacyMigrationCoordinator(
            repository: conflictRepository,
            journal: conflictJournal,
            secureStore: NativeKeychainSecureSettingsStore(backend: MemorySecureKeyValueBackend())
        )
        do {
            _ = try conflictCoordinator.migrate(
                currentSettings: BusinessSettings(),
                source: .init(
                    asyncStorageDirectory: conflictAsyncStorage,
                    documentsDirectory: conflictDocuments,
                    secureSettings: .init(),
                    appGroupValues: [:]
                )
            )
            expect(false, "different bytes at a deterministic photo destination must fail")
        } catch LegacyMigrationCoordinatorError.unsafePhotoAdoption {}
        expect(!FileManager.default.fileExists(atPath: conflictPrimary.path),
               "photo destination conflict prevents canonical snapshot publication")
        let preservedConflictSource = try Data(contentsOf: conflictPhoto)
        let preservedConflictDestination = try Data(contentsOf: conflictDestination)
        expect(preservedConflictSource == jpegBytes
               && preservedConflictDestination == existingJPEGBytes,
               "photo destination conflict preserves both source and existing destination bytes")

        if failures == 0 { print("PASS: resumable React Native migration coordinator tests") }
        else { print("FAILED: \(failures) migration coordinator test(s)"); exit(1) }
    }
}
