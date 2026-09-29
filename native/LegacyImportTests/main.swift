import Foundation

@main
struct LegacyImportTests {
    static func main() throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!)
        let richData = try Data(contentsOf: fixtureRoot.appendingPathComponent("canonical-rich.json"))
        let rich = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: richData)
        func encoded(_ key: String, array: Bool = false) throws -> Data {
            try JSONEncoder().encode(array ? .array([rich[key]!]) : rich[key]!)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-legacy-import-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("RCTAsyncLocalStorage_V1", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsData = try encoded("settings")
        let jobsData = try encoded("job", array: true)
        let settingsString = String(decoding: settingsData, as: UTF8.self)
        let manifest: [String: Any] = [
            "settings": settingsString,
            "jobs": NSNull(),
            "__syncQueue": "[{\"id\":\"queued\"}]",
            "onboardingStage": "done"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: storage.appendingPathComponent("manifest.json"))
        try jobsData.write(to: storage.appendingPathComponent(LegacyDataImporter.md5Filename(for: "jobs")))

        let secure = LegacySecureSettings(
            providerKey: "provider-secret",
            anthropicKey: "anthropic-secret",
            legacyGeminiKey: "legacy-groq-secret",
            supabaseSession: "{\"access_token\":\"private-session-token\"}"
        )
        let imported = try LegacyDataImporter.importSnapshot(
            asyncStorageDirectory: storage,
            documentsDirectory: documents,
            currentSettings: BusinessSettings(),
            secureSettings: secure,
            appGroupValues: [
                "widgetSnapshot": "{\"version\":1}",
                "widgetActions": "[]",
                "notTradeReady": "discarded"
            ]
        )
        expect(imported.snapshot.payload.jobs?.count == 1, "file-backed AsyncStorage value decodes")
        expect(imported.auxiliaryValues.keys.sorted() == ["__syncQueue", "onboardingStage"],
               "all non-domain AsyncStorage values are retained opaquely")
        expect(imported.secureSettings.groqKey == "legacy-groq-secret", "gemini key falls back to groq key")
        expect(imported.secureSettings.supabaseSession == Data("{\"access_token\":\"private-session-token\"}".utf8),
               "opaque Supabase session stays beside secure settings")
        expect(imported.snapshot.payload.settings?.providerKey == "provider-secret", "secure setting merges in memory")
        expect(imported.snapshot.payload.settings?.anthropicKey == "anthropic-secret", "anthropic setting merges in memory")
        expect(imported.snapshot.payload.settings?.groqKey == "legacy-groq-secret", "legacy groq setting merges in memory")
        expect(imported.appGroupValues.keys.sorted() == ["widgetActions", "widgetSnapshot"],
               "only same-suite app-group contract keys are retained")

        let appGroupNow = Date(timeIntervalSince1970: 1_700_000_000)
        let iso8601 = ISO8601DateFormatter()
        func stamp(_ secondsBeforeNow: TimeInterval) -> String {
            iso8601.string(from: appGroupNow.addingTimeInterval(-secondsBeforeNow))
        }
        let appGroupFixture = [
            "widgetSnapshot": "{\"private\":\"derived-only\"}",
            "widgetActions": """
            [
              {"id":"timer-1","type":"timer_start","at":"2023-11-14T22:13:20Z","jobId":"job-1"},
              {"id":"future-1","type":"a_new_action_type","at":"2023-11-14T22:13:20Z","futureField":"preserved"},
              {"id":"missing-type","at":"2023-11-14T22:13:20Z"},
              "not-an-object"
            ]
            """,
            "activeTrip": "{\"startedAt\":\"\(stamp(24 * 60 * 60))\",\"odometerStart\":12.5}",
            "pendingOpenUrl": "{\"url\":\"tradeready://onmyway/job%2Fencoded\",\"at\":\"\(stamp(4 * 60 + 59))\"}"
        ]
        let validated = LegacyDataImporter.validateAppGroupValues(appGroupFixture, now: appGroupNow)
        expect(validated.widgetSnapshotRequiresRegeneration,
               "widget snapshot is explicitly treated as derived state")
        expect(validated.widgetActions.count == 2
               && validated.widgetActions[1].type == "a_new_action_type"
               && validated.widgetActions[1].fields["futureField"] == .string("preserved"),
               "valid widget actions retain unknown fields and open action types")
        expect(validated.activeTrip?.odometerStart == 12.5,
               "active trip at exactly 24 hours remains eligible")
        expect(validated.pendingOpenURL?.route == .onMyWay(id: "job/encoded"),
               "fresh one-segment pending URL decodes its record ID")
        expect(appGroupFixture["widgetActions"]?.contains("missing-type") == true,
               "validation is pure and never partially replays or rewrites actions")

        let staleActiveTrip = LegacyDataImporter.validateAppGroupValues([
            "activeTrip": "{\"startedAt\":\"\(stamp(24 * 60 * 60 + 1))\",\"odometerStart\":12}"
        ], now: appGroupNow)
        expect(staleActiveTrip.activeTrip == nil,
               "active trip older than 24 hours is rejected")
        let futureActiveTrip = LegacyDataImporter.validateAppGroupValues([
            "activeTrip": "{\"startedAt\":\"\(appGroupNow.addingTimeInterval(1).ISO8601Format())\",\"odometerStart\":12}"
        ], now: appGroupNow)
        expect(futureActiveTrip.activeTrip == nil,
               "future active trip is rejected")
        let invalidActiveTrip = LegacyDataImporter.validateAppGroupValues([
            "activeTrip": "{\"startedAt\":\"not-a-date\",\"odometerStart\":-1}"
        ], now: appGroupNow)
        expect(invalidActiveTrip.activeTrip == nil,
               "malformed or negative active trip is rejected")

        let stalePendingURL = LegacyDataImporter.validateAppGroupValues([
            "pendingOpenUrl": "{\"url\":\"tradeready://job/job-1\",\"at\":\"\(stamp(5 * 60 + 1))\"}"
        ], now: appGroupNow)
        expect(stalePendingURL.pendingOpenURL == nil,
               "pending URL older than five minutes is rejected")
        let futurePendingURL = LegacyDataImporter.validateAppGroupValues([
            "pendingOpenUrl": "{\"url\":\"tradeready://job/job-1\",\"at\":\"\(appGroupNow.addingTimeInterval(1).ISO8601Format())\"}"
        ], now: appGroupNow)
        expect(futurePendingURL.pendingOpenURL == nil,
               "future pending URL is rejected")
        for malformedURL in [
            "tradeready://job/job-1/extra",
            "tradeready://job/job-1?next=bad",
            "tradeready://job/job-1#fragment",
            "tradeready://job/%ZZ",
            "tradeready://job/"
        ] {
            let result = LegacyDataImporter.validateAppGroupValues([
                "pendingOpenUrl": "{\"url\":\"\(malformedURL)\",\"at\":\"\(stamp(1))\"}"
            ], now: appGroupNow)
            expect(result.pendingOpenURL == nil, "malformed pending URL route is rejected")
        }
        let malformedAppGroupJSON = LegacyDataImporter.validateAppGroupValues([
            "widgetActions": "not-json",
            "activeTrip": "[]",
            "pendingOpenUrl": "{\"url\":7,\"at\":false}"
        ], now: appGroupNow)
        expect(malformedAppGroupJSON.widgetActions.isEmpty
               && malformedAppGroupJSON.activeTrip == nil
               && malformedAppGroupJSON.pendingOpenURL == nil,
               "malformed app-group JSON and field types are rejected")

        let plainSnapshot = try Canonical.SnapshotCodec.encode(imported.snapshot)
        let plainText = String(decoding: plainSnapshot, as: UTF8.self)
        expect(!plainText.contains("provider-secret") && !plainText.contains("anthropic-secret")
               && !plainText.contains("legacy-groq-secret") && !plainText.contains("private-session-token"),
               "credentials and auth sessions never enter plain snapshot bytes")

        let sessionKey = LegacyDataImporter.supabaseSessionKey
        let shortSession = try LegacyDataImporter.reassembleSecureStoreValue(
            key: sessionKey,
            inventory: [sessionKey: Data("{\"token\":\"abc\"}".utf8)]
        )
        expect(shortSession == Data("{\"token\":\"abc\"}".utf8),
               "single-item secure session is read exactly")

        let nonUTF8Session = try LegacyDataImporter.reassembleSecureStoreValue(
            key: sessionKey,
            inventory: [
                sessionKey: Data([0xFF, 0x00]),
                "\(sessionKey)_chunk_1": Data([0xC3]),
                "\(sessionKey)_chunk_2": Data([0x28, 0x80])
            ]
        )
        expect(nonUTF8Session == Data([0xFF, 0x00, 0xC3, 0x28, 0x80]),
               "non-UTF8 secure session bytes survive reconstruction exactly")

        let emojiSession = Data(String(repeating: "😀", count: 513).utf8)
        let emojiItems = [
            sessionKey: Data(emojiSession.prefix(2_047)),
            "\(sessionKey)_chunk_1": Data(emojiSession.dropFirst(2_047))
        ]
        let reassembledEmoji = try LegacyDataImporter.reassembleSecureStoreValue(
            key: sessionKey,
            inventory: emojiItems
        )
        expect(reassembledEmoji == emojiSession,
               "chunks that split multibyte UTF-8 preserve their original bytes")

        var manyChunks: [String: Data] = [sessionKey: Data([0])]
        for index in 1...128 { manyChunks["\(sessionKey)_chunk_\(index)"] = Data([UInt8(index % 251)]) }
        let reassembledMany = try LegacyDataImporter.reassembleSecureStoreValue(key: sessionKey, inventory: manyChunks)
        expect(reassembledMany?.count == 129 && reassembledMany?.last == UInt8(128),
               "more than one hundred contiguous chunks are reassembled")

        do {
            _ = try LegacyDataImporter.reassembleSecureStoreValue(
                key: sessionKey,
                inventory: ["\(sessionKey)_chunk_1": Data([1])]
            )
            expect(false, "orphan secure chunks must fail")
        } catch LegacySecureStoreError.orphanChunks(let key) {
            expect(key == sessionKey, "orphan error identifies the key without exposing secret bytes")
        }

        do {
            _ = try LegacyDataImporter.reassembleSecureStoreValue(
                key: sessionKey,
                inventory: [
                    sessionKey: Data([0]),
                    "\(sessionKey)_chunk_2": Data([2])
                ]
            )
            expect(false, "an interior secure chunk gap must fail")
        } catch LegacySecureStoreError.missingChunk(let key, let index) {
            expect(key == sessionKey && index == 1,
                   "missing-chunk error identifies only key and gap index")
        }

        for malformedInventory in [
            [sessionKey: Data([1]), "\(sessionKey)_chunk_0": Data([2])],
            [sessionKey: Data([1]), "\(sessionKey)_chunk_01": Data([2])],
            [sessionKey: Data([1]), "\(sessionKey)_chunk_x": Data([2])],
            [sessionKey: Data([1]), "\(sessionKey)_chunk_1": Data()],
            [sessionKey: Data([1]), "\(sessionKey)_chunk_1": Data(repeating: 2, count: 2_049)]
        ] {
            do {
                _ = try LegacyDataImporter.reassembleSecureStoreValue(key: sessionKey, inventory: malformedInventory)
                expect(false, "malformed, empty, or oversized session chunks must fail closed")
            } catch LegacySecureStoreError.malformedChunk(let key) {
                expect(key == sessionKey, "invalid chunk error excludes session contents")
            }
        }

        let fallbackSession = try LegacyDataImporter.reassembleSecureStoreValue(
            key: sessionKey,
            serviceInventories: [
                [:],
                [sessionKey: Data([1]), "\(sessionKey)_chunk_1": Data([2])]
            ]
        )
        expect(fallbackSession == Data([1, 2]),
               "a complete lower-priority secure service is used when higher services are empty")

        let noMixSession = try LegacyDataImporter.reassembleSecureStoreValue(
            key: sessionKey,
            serviceInventories: [
                [sessionKey: Data([1])],
                ["\(sessionKey)_chunk_1": Data([2])]
            ]
        )
        expect(noMixSession == Data([1]),
               "a lower-service chunk is never mixed into a higher-service base")

        do {
            _ = try LegacyDataImporter.reassembleSecureStoreValue(
                key: sessionKey,
                serviceInventories: [
                    ["\(sessionKey)_chunk_x": Data([1])],
                    [sessionKey: Data([2])]
                ]
            )
            expect(false, "a corrupt higher-priority service must not fall through")
        } catch LegacySecureStoreError.malformedChunk(let key) {
            expect(key == sessionKey, "higher-priority corruption is surfaced without secret bytes")
        }

        let missingStorage = root.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missingStorage, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["jobs": NSNull()]).write(
            to: missingStorage.appendingPathComponent("manifest.json")
        )
        do {
            _ = try LegacyDataImporter.readAsyncStorageValues(from: missingStorage)
            expect(false, "missing external value must fail")
        } catch LegacyImportError.missingExternalValue(let key) {
            expect(key == "jobs", "missing external value identifies key without exposing contents")
        }

        let malformedStorage = root.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedStorage, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["jobs": 7]).write(
            to: malformedStorage.appendingPathComponent("manifest.json")
        )
        do {
            _ = try LegacyDataImporter.readAsyncStorageValues(from: malformedStorage)
            expect(false, "unsupported manifest entry must fail")
        } catch LegacyImportError.malformedManifestEntry(let key) {
            expect(key == "jobs", "malformed manifest identifies key")
        }

        let photosDirectory = documents.appendingPathComponent("photos", isDirectory: true)
        let receiptsDirectory = documents.appendingPathComponent("receipts", isDirectory: true)
        let orphan = photosDirectory.appendingPathComponent("orphan.jpg")
        let receipt = receiptsDirectory.appendingPathComponent("receipt.jpg")
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiptsDirectory, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)
        try Data("receipt".utf8).write(to: receipt)

        var photoSnapshot = imported.snapshot
        var expense: Canonical.Expense = try JSONDecoder().decode(Canonical.Expense.self, from: encoded("expense"))
        expense.receiptUri = receipt.absoluteString
        photoSnapshot.payload.expenses = [expense]
        let inventory = LegacyDataImporter.photoInventory(for: photoSnapshot, documentsDirectory: documents)
        expect(inventory.existingPaths.contains(receipt.absoluteString), "file URL photo reference is found")
        expect(inventory.discoveredPaths.contains(where: { $0.hasSuffix("/photos/orphan.jpg") }),
               "unreferenced legacy photo is included in backup set")

        let firstBackupCount = try LegacyDataImporter.backupPhotoFiles(from: documents, to: backup)
        expect(firstBackupCount == 2, "first photo backup copies every discovered file")
        let repeatedBackupCount = try LegacyDataImporter.backupPhotoFiles(from: documents, to: backup)
        expect(repeatedBackupCount == 0, "photo backup is idempotent for identical files")
        try Data("changed".utf8).write(to: orphan)
        do {
            _ = try LegacyDataImporter.backupPhotoFiles(from: documents, to: backup)
            expect(false, "photo backup conflict must fail")
        } catch LegacyImportError.photoBackupConflict(let relativePath) {
            expect(relativePath == "photos/orphan.jpg", "photo conflict identifies only relative path")
        }

        // Lossless photo adoption uses byte signatures, not filename claims.
        let adoptionLegacy = root.appendingPathComponent("AdoptionLegacy", isDirectory: true)
        let adoptionNative = root.appendingPathComponent("AdoptionNative", isDirectory: true)
        let legacyPhotos = adoptionLegacy.appendingPathComponent("photos", isDirectory: true)
        let legacyJobPhotos = adoptionLegacy.appendingPathComponent("job-photos", isDirectory: true)
        let legacyReceipts = adoptionLegacy.appendingPathComponent("receipts", isDirectory: true)
        let legacyLogos = adoptionLegacy.appendingPathComponent("logos", isDirectory: true)
        for directory in [legacyPhotos, legacyJobPhotos, legacyReceipts, legacyLogos] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x01, 0x02, 0xFF, 0xD9])
        let secondJPEGBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x03, 0x04, 0xFF, 0xD9])
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let gifBytes = Data("GIF89a-not-losslessly-contracted".utf8)
        let adoptableLegacyPhoto = legacyPhotos.appendingPathComponent("legacy-mislabeled.png")
        let unsupportedLegacyPhoto = legacyPhotos.appendingPathComponent("legacy-png.jpg")
        let convertibleLegacyPhoto = legacyPhotos.appendingPathComponent("valid-photo.png")
        let missingLegacyPhoto = legacyPhotos.appendingPathComponent("missing.jpg")
        let outsidePhoto = root.appendingPathComponent("outside.jpg")
        let escapingSymlink = legacyPhotos.appendingPathComponent("escape.jpg")
        try jpegBytes.write(to: adoptableLegacyPhoto)
        try pngBytes.write(to: unsupportedLegacyPhoto)
        let validPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try validPNG.write(to: convertibleLegacyPhoto)
        try jpegBytes.write(to: outsidePhoto)
        try FileManager.default.createSymbolicLink(at: escapingSymlink, withDestinationURL: outsidePhoto)

        func decodedJobPhoto(id: String, jobID: String, createdAt: String = "2026-01-01T00:00:00.000Z") throws -> Canonical.JobPhoto {
            let object: [String: Any] = ["id": id, "jobId": jobID, "createdAt": createdAt]
            return try JSONDecoder().decode(
                Canonical.JobPhoto.self,
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }

        var adoptionSnapshot = imported.snapshot
        let adoptionJobID = adoptionSnapshot.payload.jobs![0].id
        adoptionSnapshot.payload.jobs![0].photos = [
            adoptableLegacyPhoto.absoluteString,
            missingLegacyPhoto.absoluteString,
            unsupportedLegacyPhoto.absoluteString,
            outsidePhoto.absoluteString,
            escapingSymlink.absoluteString,
            convertibleLegacyPhoto.absoluteString
        ]
        let existingPhotoID = "p123_existing"
        adoptionSnapshot.payload.jobPhotos = [try decodedJobPhoto(id: existingPhotoID, jobID: adoptionJobID)]
        try secondJPEGBytes.write(to: legacyJobPhotos.appendingPathComponent("\(existingPhotoID).jpg"))

        var adoptedExpense = expense
        adoptedExpense.id = "expense-adopted"
        let legacyReceipt = legacyReceipts.appendingPathComponent("receipt-wrong-extension.png")
        try jpegBytes.write(to: legacyReceipt)
        adoptedExpense.receiptUri = legacyReceipt.absoluteString
        var deferredExpense = expense
        deferredExpense.id = "expense-deferred"
        let unsupportedReceipt = legacyReceipts.appendingPathComponent("receipt.gif")
        try gifBytes.write(to: unsupportedReceipt)
        deferredExpense.receiptUri = unsupportedReceipt.absoluteString
        adoptionSnapshot.payload.expenses = [adoptedExpense, deferredExpense]

        let legacyLogo = legacyLogos.appendingPathComponent("logo.jpg")
        try pngBytes.write(to: legacyLogo)
        adoptionSnapshot.payload.settings!.logoPhoto = legacyLogo.absoluteString
        let fixedAdoptionDate = Date(timeIntervalSince1970: 1_700_000_000)
        let stableID = LegacyDataImporter.stableLegacyPhotoID(
            jobID: adoptionJobID,
            legacyReference: adoptableLegacyPhoto.absoluteString
        )
        let convertedID = LegacyDataImporter.stableLegacyPhotoID(
            jobID: adoptionJobID,
            legacyReference: convertibleLegacyPhoto.absoluteString
        )
        expect(stableID == LegacyDataImporter.stableLegacyPhotoID(
            jobID: adoptionJobID,
            legacyReference: adoptableLegacyPhoto.absoluteString
        ) && stableID.range(of: #"^p[0-9]+_[a-z0-9]+$"#, options: .regularExpression) != nil,
               "legacy photo IDs are stable and satisfy the upload grammar")

        let adoption = LegacyDataImporter.adoptPhotoFiles(
            in: adoptionSnapshot,
            legacyDocumentsDirectory: adoptionLegacy,
            nativePhotoRoot: adoptionNative,
            dateProvider: { _, _ in fixedAdoptionDate }
        )
        let keptReferences = adoption.snapshot.payload.jobs![0].photos ?? []
        expect(keptReferences == Array(adoptionSnapshot.payload.jobs![0].photos![1...4]),
               "only successfully adopted Job.photos references are cleared")
        expect(adoption.snapshot.payload.jobPhotos?.map(\.id).sorted()
               == [existingPhotoID, stableID, convertedID].sorted(),
               "lossless and converted legacy bytes create non-duplicated JobPhoto records")
        let createdRecord = adoption.snapshot.payload.jobPhotos?.first(where: { $0.id == stableID })
        expect(createdRecord?.jobId == adoptionJobID
               && createdRecord?.createdAt == "2023-11-14T22:13:20.000Z"
               && createdRecord?.width == nil && createdRecord?.height == nil
               && createdRecord?.uploadedAt == nil,
               "adopted JobPhoto records use the deterministic date without guessed metadata")
        let adoptedJobPath = adoptionNative.appendingPathComponent("job-photos/\(stableID).jpg")
        let convertedJobPath = adoptionNative.appendingPathComponent("job-photos/\(convertedID).jpg")
        let adoptedExistingPath = adoptionNative.appendingPathComponent("job-photos/\(existingPhotoID).jpg")
        expect((try? Data(contentsOf: adoptedJobPath)) == jpegBytes
               && (try? Data(contentsOf: adoptedExistingPath)) == secondJPEGBytes,
               "new and existing deterministic JobPhoto bytes are copied exactly")
        let convertedJobBytes = try Data(contentsOf: convertedJobPath)
        expect(convertedJobBytes.starts(with: [0xFF, 0xD8, 0xFF]),
               "a decodable PNG job photo is converted into the native JPEG contract")
        expect((try? Data(contentsOf: adoptableLegacyPhoto)) == jpegBytes
               && (try? Data(contentsOf: legacyJobPhotos.appendingPathComponent("\(existingPhotoID).jpg"))) == secondJPEGBytes,
               "adoption never deletes or rewrites legacy files")
        expect(adoption.deferred.contains(.init(
            asset: .legacyJobPhoto(jobID: adoptionJobID, index: 1), reason: .missingSource
        )) && adoption.deferred.contains(.init(
            asset: .legacyJobPhoto(jobID: adoptionJobID, index: 2), reason: .conversionFailed(.png)
        )) && adoption.deferred.contains(.init(
            asset: .legacyJobPhoto(jobID: adoptionJobID, index: 3), reason: .outsideLegacyDocuments
        )) && adoption.deferred.contains(.init(
            asset: .legacyJobPhoto(jobID: adoptionJobID, index: 4), reason: .outsideLegacyDocuments
        )), "missing, unsupported, outside, and symlink-escaped job photos are typed deferrals")

        let adoptedReceiptURL = URL(string: adoption.snapshot.payload.expenses![0].receiptUri!)!
        let adoptedLogoURL = URL(string: adoption.snapshot.payload.settings!.logoPhoto!)!
        expect(adoptedReceiptURL.path.hasPrefix(adoptionNative.appendingPathComponent("receipts").path)
               && adoptedReceiptURL.pathExtension == "jpg"
               && (try? Data(contentsOf: adoptedReceiptURL)) == jpegBytes,
               "receipt bytes are signature-detected, copied losslessly, and rewritten")
        expect(adoptedLogoURL.path.hasPrefix(adoptionNative.appendingPathComponent("logos").path)
               && adoptedLogoURL.pathExtension == "png"
               && (try? Data(contentsOf: adoptedLogoURL)) == pngBytes,
               "PNG logo bytes keep a truthful extension after lossless rewrite")
        expect(adoption.snapshot.payload.expenses![1].receiptUri == unsupportedReceipt.absoluteString
               && adoption.deferred.contains(.init(
                    asset: .expenseReceipt(expenseID: "expense-deferred"), reason: .conversionFailed(.gif)
               )), "unsupported receipt bytes keep their legacy reference for a later capable migrator")

        let repeated = LegacyDataImporter.adoptPhotoFiles(
            in: adoption.snapshot,
            legacyDocumentsDirectory: adoptionLegacy,
            nativePhotoRoot: adoptionNative,
            dateProvider: { _, _ in fixedAdoptionDate }
        )
        expect(repeated.copiedFileCount == 0
               && repeated.snapshot.payload.jobPhotos?.map(\.id).sorted()
                  == [existingPhotoID, stableID, convertedID].sorted(),
               "a completed adoption rerun copies nothing and creates no duplicate records")
        expect(repeated.snapshot.payload.expenses![0].receiptUri == adoption.snapshot.payload.expenses![0].receiptUri
               && repeated.snapshot.payload.settings!.logoPhoto == adoption.snapshot.payload.settings!.logoPhoto,
               "native receipt and logo rewrites are stable across reruns")

        // A destination with different bytes is never overwritten and cannot
        // produce a metadata record or clear the legacy reference.
        var conflictSnapshot = imported.snapshot
        conflictSnapshot.payload.jobs![0].photos = [adoptableLegacyPhoto.absoluteString]
        conflictSnapshot.payload.jobPhotos = []
        let conflictID = LegacyDataImporter.stableLegacyPhotoID(
            jobID: adoptionJobID,
            legacyReference: adoptableLegacyPhoto.absoluteString
        )
        let conflictRoot = root.appendingPathComponent("ConflictNative", isDirectory: true)
        let conflictDestination = conflictRoot.appendingPathComponent("job-photos/\(conflictID).jpg")
        try FileManager.default.createDirectory(at: conflictDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try secondJPEGBytes.write(to: conflictDestination)
        let conflict = LegacyDataImporter.adoptPhotoFiles(
            in: conflictSnapshot,
            legacyDocumentsDirectory: adoptionLegacy,
            nativePhotoRoot: conflictRoot,
            dateProvider: { _, _ in fixedAdoptionDate }
        )
        expect(conflict.snapshot.payload.jobs![0].photos == [adoptableLegacyPhoto.absoluteString]
               && conflict.snapshot.payload.jobPhotos?.isEmpty == true
               && (try? Data(contentsOf: conflictDestination)) == secondJPEGBytes,
               "different destination bytes remain untouched and the source reference remains retryable")
        expect(conflict.deferred.contains(.init(
            asset: .legacyJobPhoto(jobID: adoptionJobID, index: 0), reason: .destinationConflict
        )), "destination byte mismatch is returned as a typed deferral")

        let blockedNativeRoot = root.appendingPathComponent("BlockedNative")
        try Data("not-a-directory".utf8).write(to: blockedNativeRoot)
        let writeDeferred = LegacyDataImporter.adoptPhotoFiles(
            in: conflictSnapshot,
            legacyDocumentsDirectory: adoptionLegacy,
            nativePhotoRoot: blockedNativeRoot,
            dateProvider: { _, _ in fixedAdoptionDate }
        )
        expect(writeDeferred.snapshot.payload.jobs![0].photos == [adoptableLegacyPhoto.absoluteString]
               && writeDeferred.snapshot.payload.jobPhotos?.isEmpty == true
               && writeDeferred.deferred.contains(.init(
                    asset: .legacyJobPhoto(jobID: adoptionJobID, index: 0), reason: .writeFailed
               )), "a transient native write failure keeps the legacy reference and creates no record")

        var collisionSnapshot = conflictSnapshot
        collisionSnapshot.payload.jobPhotos = [try decodedJobPhoto(id: conflictID, jobID: "different-job")]
        let collision = LegacyDataImporter.adoptPhotoFiles(
            in: collisionSnapshot,
            legacyDocumentsDirectory: adoptionLegacy,
            nativePhotoRoot: root.appendingPathComponent("CollisionNative"),
            dateProvider: { _, _ in fixedAdoptionDate }
        )
        expect(collision.snapshot.payload.jobs![0].photos == [adoptableLegacyPhoto.absoluteString]
               && collision.snapshot.payload.jobPhotos?.count == 1
               && collision.deferred.contains(.init(
                    asset: .legacyJobPhoto(jobID: adoptionJobID, index: 0), reason: .photoIDCollision
               )), "an existing ID owned by another job fails closed without adding a record")

        expect(LegacyDataImporter.appGroupID == "group.com.gettradereadyapp.tradeready",
               "native importer uses the production app-group suite")
        expect(LegacyDataImporter.legacySecureStoreServices == ["app:no-auth", "app:auth", "app"],
               "native importer probes current and legacy Expo SecureStore services in order")
        let candidates = LegacyDataImporter.asyncStorageCandidates(
            libraryDirectory: root.appendingPathComponent("Library"),
            applicationSupportDirectory: root.appendingPathComponent("Library/Application Support"),
            documentsDirectory: documents,
            bundleID: "com.gettradereadyapp.tradeready"
        )
        expect(candidates.first?.path.hasSuffix("Application Support/com.gettradereadyapp.tradeready/RCTAsyncLocalStorage_V1") == true,
               "AsyncStorage 2.2 bundle-scoped Application Support path is preferred")
        expect(candidates.map(\.lastPathComponent).contains("RNCAsyncLocalStorage_V1") &&
               candidates.map(\.lastPathComponent).contains("RCTAsyncLocalStorage"),
               "historical community and Expo storage directories remain readable")
        expect(LegacyDataImporter.md5Filename(for: "jobs") == "27a06a9e3d5e7f67eb604a39536208c9",
               "AsyncStorage MD5 filename compatibility")

        if failures == 0 { print("PASS: legacy import boundary tests") }
        else { print("FAILED: \(failures) legacy import test(s)"); exit(1) }
    }
}
