import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

protocol NativeSecureSettingsStoring {
    func persist(_ settings: LegacySecureSettings) throws
}

enum NativeSecureSettingsStoreError: LocalizedError {
    case unavailable
    case writeFailed(key: String, status: Int32)
    case verificationFailed(key: String)
    case conflictingNativeSession

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Secure credential storage is unavailable."
        case .writeFailed(let key, let status):
            "A secure credential could not be stored for \(key) (Keychain status \(status))."
        case .verificationFailed(let key):
            "A secure credential could not be verified after storing \(key)."
        case .conflictingNativeSession:
            "A different native sign-in session already exists and was left unchanged."
        }
    }
}

/// Minimal byte-oriented boundary around secure storage. Keeping this separate
/// from migration policy lets command-line tests exercise the exact native
/// publication implementation without requiring a device Keychain.
protocol NativeSecureKeyValueBacking {
    func upsert(_ value: Data, key: String) throws
    func read(key: String) throws -> Data?
    func remove(key: String) throws
}

struct NativeKeychainBackend: NativeSecureKeyValueBacking {
    static let service = "com.gettradereadyapp.tradeready.native"

    func upsert(_ value: Data, key: String) throws {
        #if canImport(Security)
        let encodedKey = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrGeneric as String: encodedKey
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NativeSecureSettingsStoreError.writeFailed(key: key, status: status)
        }
        #else
        throw NativeSecureSettingsStoreError.unavailable
        #endif
    }

    func read(key: String) throws -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data
        else { throw NativeSecureSettingsStoreError.writeFailed(key: key, status: status) }
        return data
        #else
        throw NativeSecureSettingsStoreError.unavailable
        #endif
    }

    func remove(key: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeSecureSettingsStoreError.writeFailed(key: key, status: status)
        }
        #else
        throw NativeSecureSettingsStoreError.unavailable
        #endif
    }

    func removeAllValues() throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeSecureSettingsStoreError.writeFailed(key: Self.service, status: status)
        }
        #else
        throw NativeSecureSettingsStoreError.unavailable
        #endif
    }
}

/// Generation-based secure value storage. Chunks are fully written and
/// verified before the single pointer item is atomically replaced, so an
/// interrupted publication cannot make a partial generation active.
struct NativeGenerationSecureValueStore {
    static let currentSchemaVersion = 1

    struct ActivePointer: Codable, Equatable {
        let schemaVersion: Int
        let generation: String
        let chunkCount: Int
        let byteLength: Int
        let sha256: String
    }

    let backend: any NativeSecureKeyValueBacking
    let pointerKey: String
    let maximumChunkSize: Int
    let makeGeneration: () -> String

    init(
        backend: any NativeSecureKeyValueBacking,
        pointerKey: String,
        maximumChunkSize: Int = 2_048,
        makeGeneration: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        precondition(maximumChunkSize > 0)
        self.backend = backend
        self.pointerKey = pointerKey
        self.maximumChunkSize = maximumChunkSize
        self.makeGeneration = makeGeneration
    }

    func read() throws -> Data? {
        guard let pointerData = try backend.read(key: pointerKey) else { return nil }
        let pointer: ActivePointer
        do {
            pointer = try JSONDecoder().decode(ActivePointer.self, from: pointerData)
        } catch {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }
        guard pointer.schemaVersion == Self.currentSchemaVersion,
              pointer.chunkCount > 0,
              pointer.byteLength > 0,
              pointer.chunkCount == ((pointer.byteLength - 1) / maximumChunkSize) + 1,
              UUID(uuidString: pointer.generation) != nil,
              pointer.sha256.count == 64
        else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }

        var value = Data()
        for index in 0..<pointer.chunkCount {
            let key = chunkKey(generation: pointer.generation, index: index)
            let expectedCount = index == pointer.chunkCount - 1
                ? pointer.byteLength - (index * maximumChunkSize)
                : maximumChunkSize
            guard let chunk = try backend.read(key: key),
                  chunk.count == expectedCount
            else {
                throw NativeSecureSettingsStoreError.verificationFailed(key: key)
            }
            value.append(chunk)
        }
        guard value.count == pointer.byteLength,
              Self.sha256Hex(value) == pointer.sha256
        else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }
        return value
    }

    /// Publishes a new active generation. Conflict policy belongs to the
    /// caller; this primitive only guarantees chunk-first atomic activation.
    func publish(_ value: Data) throws {
        guard !value.isEmpty else { return }
        let generation = makeGeneration()
        guard UUID(uuidString: generation) != nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }

        let chunkCount = (value.count + maximumChunkSize - 1) / maximumChunkSize
        for index in 0..<chunkCount {
            let start = index * maximumChunkSize
            let end = min(start + maximumChunkSize, value.count)
            let chunk = value.subdata(in: start..<end)
            let key = chunkKey(generation: generation, index: index)
            try backend.upsert(chunk, key: key)
            guard try backend.read(key: key) == chunk else {
                throw NativeSecureSettingsStoreError.verificationFailed(key: key)
            }
        }

        let pointer = ActivePointer(
            schemaVersion: Self.currentSchemaVersion,
            generation: generation,
            chunkCount: chunkCount,
            byteLength: value.count,
            sha256: Self.sha256Hex(value)
        )
        let pointerData = try Self.encode(pointer)
        try backend.upsert(pointerData, key: pointerKey)
        guard try backend.read(key: pointerKey) == pointerData,
              try read() == value
        else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }
    }

    /// Remove the active pointer first so an interrupted cleanup can never
    /// make a signed-out session readable again.
    func removeActiveValue() throws {
        guard let pointerData = try backend.read(key: pointerKey) else { return }
        let pointer: ActivePointer
        do {
            pointer = try JSONDecoder().decode(ActivePointer.self, from: pointerData)
        } catch {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }
        guard pointer.schemaVersion == Self.currentSchemaVersion,
              pointer.chunkCount > 0,
              pointer.byteLength > 0,
              pointer.chunkCount == ((pointer.byteLength - 1) / maximumChunkSize) + 1,
              UUID(uuidString: pointer.generation) != nil,
              pointer.sha256.count == 64
        else { throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey) }
        try backend.remove(key: pointerKey)
        guard try backend.read(key: pointerKey) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: pointerKey)
        }
        for index in 0..<pointer.chunkCount {
            try backend.remove(key: chunkKey(generation: pointer.generation, index: index))
        }
    }

    private func chunkKey(generation: String, index: Int) -> String {
        "\(pointerKey).generation.\(generation).chunk.\(index)"
    }

    private static func encode(_ pointer: ActivePointer) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(pointer)
    }

    private static func sha256Hex(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

/// Native destination for migrated provider credentials and the opaque auth
/// session. Provider values remain verified upserts; the session is activated
/// only through its generation pointer.
struct NativeKeychainSecureSettingsStore: NativeSecureSettingsStoring {
    static let service = NativeKeychainBackend.service
    static let passwordRecoveryStateAccount = "password-recovery-state.v1"
    static let verifiedSessionIdentityAccount = "verified-session-identity.v1"

    let backend: any NativeSecureKeyValueBacking

    init(backend: any NativeSecureKeyValueBacking = NativeKeychainBackend()) {
        self.backend = backend
    }

    func persist(_ settings: LegacySecureSettings) throws {
        let sessionStore = makeSessionStore()
        let sessionNeedsPublication: Bool
        if let session = settings.supabaseSession, !session.isEmpty {
            if let existing = try sessionStore.read() {
                guard existing == session else {
                    throw NativeSecureSettingsStoreError.conflictingNativeSession
                }
                sessionNeedsPublication = false
            } else {
                sessionNeedsPublication = true
            }
        } else {
            sessionNeedsPublication = false
        }

        let providerValues: [(String, String?)] = [
            ("providerKey", settings.providerKey),
            ("anthropicKey", settings.anthropicKey),
            ("groqKey", settings.groqKey)
        ]
        for (key, value) in providerValues {
            guard let value, !value.isEmpty else { continue }
            let data = Data(value.utf8)
            try backend.upsert(data, key: key)
            guard try backend.read(key: key) == data else {
                throw NativeSecureSettingsStoreError.verificationFailed(key: key)
            }
        }

        if sessionNeedsPublication, let session = settings.supabaseSession {
            try sessionStore.publish(session)
        }
    }

    /// Phase 3 auth restoration reads the opaque bytes through this boundary;
    /// no business-data snapshot, migration journal, or diagnostic contains it.
    func readSupabaseSession() throws -> Data? {
        try makeSessionStore().read()
    }

    /// Replaces one verified active session with its refreshed successor. The
    /// expected-value guard prevents a stale refresh response from overwriting
    /// a newer sign-in, while generation publication keeps the old session
    /// active until every successor chunk has been written and verified.
    func replaceSupabaseSession(expectedCurrent: Data, with refreshed: Data) throws {
        guard !refreshed.isEmpty else {
            throw NativeSecureSettingsStoreError.verificationFailed(
                key: LegacyDataImporter.supabaseSessionKey
            )
        }
        let sessionStore = makeSessionStore()
        guard let current = try sessionStore.read(), current == expectedCurrent else {
            throw NativeSecureSettingsStoreError.conflictingNativeSession
        }
        guard current != refreshed else { return }
        try sessionStore.publish(refreshed)
    }

    /// An explicit successful sign-in is authoritative and may replace a
    /// rejected session from another account.
    func publishSupabaseSession(_ session: Data) throws {
        guard !session.isEmpty else {
            throw NativeSecureSettingsStoreError.verificationFailed(
                key: LegacyDataImporter.supabaseSessionKey
            )
        }
        try makeSessionStore().publish(session)
    }

    func clearSupabaseSession() throws {
        try makeSessionStore().removeActiveValue()
        try backend.remove(key: Self.verifiedSessionIdentityAccount)
        guard try backend.read(key: Self.verifiedSessionIdentityAccount) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(
                key: Self.verifiedSessionIdentityAccount
            )
        }
    }

    /// Account boundaries clear user-supplied provider credentials together
    /// with the auth session. The device-local HMAC binding key is deliberately
    /// retained because it contains no account identifier or recoverable data.
    func clearAccountValues() throws {
        for key in [
            "providerKey", "anthropicKey", "groqKey", "geminiKey",
            Self.passwordRecoveryStateAccount
        ] {
            try backend.remove(key: key)
            guard try backend.read(key: key) == nil else {
                throw NativeSecureSettingsStoreError.verificationFailed(key: key)
            }
        }
        do {
            try clearSupabaseSession()
        } catch {
            // A malformed pointer is unusable but must not make explicit
            // cleanup impossible. Removing it first keeps every orphaned chunk
            // inactive even when its generation metadata cannot be decoded.
            try backend.remove(key: LegacyDataImporter.supabaseSessionKey)
            guard try backend.read(key: LegacyDataImporter.supabaseSessionKey) == nil else {
                throw NativeSecureSettingsStoreError.verificationFailed(
                    key: LegacyDataImporter.supabaseSessionKey
                )
            }
            try backend.remove(key: Self.verifiedSessionIdentityAccount)
            guard try backend.read(key: Self.verifiedSessionIdentityAccount) == nil else {
                throw NativeSecureSettingsStoreError.verificationFailed(
                    key: Self.verifiedSessionIdentityAccount
                )
            }
        }
    }

    /// Permanent deletion removes the entire native Keychain service, including
    /// inactive session generations and the device-local binding secret.
    func clearAllValues() throws {
        if let keychain = backend as? NativeKeychainBackend {
            try keychain.removeAllValues()
        } else {
            try clearAccountValues()
            try backend.remove(key: "auxiliary-account-binding-key.v1")
        }
    }

    private func makeSessionStore() -> NativeGenerationSecureValueStore {
        NativeGenerationSecureValueStore(
            backend: backend,
            pointerKey: LegacyDataImporter.supabaseSessionKey
        )
    }
}

struct LegacyMigrationSource {
    let asyncStorageDirectory: URL?
    let documentsDirectory: URL
    let secureSettings: LegacySecureSettings
    let appGroupValues: [String: String]
}

enum NativeAuxiliaryStateScope: String, Codable, Equatable {
    case device
    case account
    case perUser
    case unknown
}

enum NativeAuxiliaryStateActivationPolicy: String, Codable, Equatable {
    case restorable
    case activateAfterIdentity
    case preserveOnly
}

/// Lossless, non-canonical storage for opaque React Native state. Entries stay
/// inert until a later identity-aware restoration phase explicitly activates
/// them.
struct NativeAuxiliaryStateArtifact: Codable, Equatable {
    static let currentSchemaVersion = 1

    struct Entry: Codable, Equatable {
        let key: String
        let value: Data
        let scope: NativeAuxiliaryStateScope
        let activationPolicy: NativeAuxiliaryStateActivationPolicy
    }

    let schemaVersion: Int
    let entries: [Entry]

    init(values: [String: Data]) {
        schemaVersion = Self.currentSchemaVersion
        entries = values.map { key, value in
            let classification = Self.classification(for: key)
            return Entry(
                key: key,
                value: value,
                scope: classification.scope,
                activationPolicy: classification.policy
            )
        }.sorted { $0.key < $1.key }
    }

    private static func classification(
        for key: String
    ) -> (scope: NativeAuxiliaryStateScope, policy: NativeAuxiliaryStateActivationPolicy) {
        if key == "__themePreference" || key == "tr_import_history_v1" {
            return (.device, .restorable)
        }
        if key.hasPrefix("__initDone_") || key.hasPrefix("__collBackfill_v1_") {
            return (.perUser, .preserveOnly)
        }
        // These values are evidence for a later sync-specific reconciliation,
        // never generic replay candidates. A legacy queue can mutate cloud
        // rows, a cursor can skip a required pull, and the owner marker is an
        // authorization guard written only after a successful initial sync.
        if syncReconciliationKeys.contains(key) {
            return (.account, .preserveOnly)
        }
        if accountKeys.contains(key) {
            return (.account, .activateAfterIdentity)
        }
        return (.unknown, .preserveOnly)
    }

    private static let accountKeys: Set<String> = [
        "onboardingComplete", "onboardingStage", "onboardingDraft",
        "setupChecklistState", "review_requests", "dismissed_duplicate_pairs",
        "insightMutes", "invoiceReminderPromptShown"
    ]

    private static let syncReconciliationKeys: Set<String> = [
        "__syncQueue", "__lastSyncedAt", "__dataOwner"
    ]
}

enum NativeAuxiliaryStateStoreError: Error, Equatable {
    case conflictingExistingArtifact
}

/// Atomically publishes the auxiliary artifact beside `store.json`. Once
/// published it is immutable: an identical retry is a no-op and differing
/// bytes fail closed rather than replacing the recovery point.
struct NativeAuxiliaryStateStore {
    static let filename = "auxiliary-state.json"

    let fileURL: URL
    private let fileManager: FileManager

    init(snapshotURL: URL, fileManager: FileManager = .default) {
        fileURL = snapshotURL.deletingLastPathComponent().appendingPathComponent(Self.filename)
        self.fileManager = fileManager
    }

    @discardableResult
    func persist(_ values: [String: Data]) throws -> NativeAuxiliaryStateArtifact {
        let artifact = NativeAuxiliaryStateArtifact(values: values)
        let bytes = try Self.encode(artifact)
        if fileManager.fileExists(atPath: fileURL.path) {
            guard try Data(contentsOf: fileURL) == bytes else {
                throw NativeAuxiliaryStateStoreError.conflictingExistingArtifact
            }
            return artifact
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: fileURL, options: .atomic)
        return artifact
    }

    func load() throws -> NativeAuxiliaryStateArtifact {
        try JSONDecoder().decode(
            NativeAuxiliaryStateArtifact.self,
            from: Data(contentsOf: fileURL)
        )
    }

    static func encode(_ artifact: NativeAuxiliaryStateArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(artifact)
    }
}

enum LegacyMigrationCheckpoint: Equatable {
    case journaled
    case sourceBackedUp
    case photosAdopted
    case auxiliaryPersisted
    case secretsPersisted
    case snapshotPersisted
}

/// A photo destination must never be silently overwritten or replaced with a
/// different logical asset. The detailed adoption result intentionally stays
/// out of this error so an alert/support report cannot disclose asset paths or
/// record identifiers.
enum LegacyMigrationCoordinatorError: LocalizedError, Equatable {
    case unsafePhotoAdoption

    var errorDescription: String? {
        switch self {
        case .unsafePhotoAdoption:
            "Previous-app photos could not be adopted safely. No native snapshot was saved."
        }
    }
}

struct LegacyMigrationOutcome {
    enum Status: Equatable {
        case noData
        case migrated
        case alreadyCompleted
        case nativeSnapshotConflict
    }

    let status: Status
    let snapshot: Canonical.Snapshot?
    let importedCount: Int
    let missingPhotoCount: Int
    /// Logical assets safely adopted into native-owned media. This is stable
    /// across an interrupted retry, unlike the number of physical copy writes.
    let adoptedPhotoCount: Int
    /// References deliberately retained because their bytes could not be
    /// adopted (for example, missing or unsupported source files).
    let deferredPhotoCount: Int
}

/// Coordinates the irreversible boundary of the Expo-to-native upgrade. Every
/// mutation is either immutable or an idempotent upsert, so `started` journal
/// entries can safely replay the complete sequence after interruption.
struct LegacyMigrationCoordinator {
    let repository: Canonical.SnapshotRepository
    let journal: Canonical.MigrationJournal
    let secureStore: any NativeSecureSettingsStoring

    private let fileManager: FileManager
    private let checkpoint: (LegacyMigrationCheckpoint) throws -> Void

    init(
        repository: Canonical.SnapshotRepository,
        journal: Canonical.MigrationJournal,
        secureStore: any NativeSecureSettingsStoring = NativeKeychainSecureSettingsStore(),
        fileManager: FileManager = .default,
        checkpoint: @escaping (LegacyMigrationCheckpoint) throws -> Void = { _ in }
    ) {
        self.repository = repository
        self.journal = journal
        self.secureStore = secureStore
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    func migrate(currentSettings: BusinessSettings) throws -> LegacyMigrationOutcome {
        let source = try liveSource()
        return try migrate(currentSettings: currentSettings, source: source)
    }

    func migrate(
        currentSettings: BusinessSettings,
        source: LegacyMigrationSource
    ) throws -> LegacyMigrationOutcome {
        let kind = Canonical.MigrationKind.reactNativeAsyncStorage
        if try journal.isComplete(kind) {
            return .init(
                status: .alreadyCompleted, snapshot: nil, importedCount: 0,
                missingPhotoCount: 0, adoptedPhotoCount: 0, deferredPhotoCount: 0
            )
        }

        let result: LegacyImportResult
        if let asyncStorageDirectory = source.asyncStorageDirectory {
            result = try LegacyDataImporter.importSnapshot(
                asyncStorageDirectory: asyncStorageDirectory,
                documentsDirectory: source.documentsDirectory,
                currentSettings: currentSettings,
                secureSettings: source.secureSettings,
                appGroupValues: source.appGroupValues
            )
        } else {
            result = try LegacyDataImporter.decodeSnapshot(
                values: [:],
                currentSettings: currentSettings,
                secureSettings: source.secureSettings,
                appGroupValues: source.appGroupValues,
                documentsDirectory: source.documentsDirectory
            )
        }

        let hasSourceData = result.importedCount > 0
            || !result.auxiliaryValues.isEmpty
            || !result.appGroupValues.isEmpty
            || !result.photoInventory.discoveredPaths.isEmpty
        guard hasSourceData else {
            return .init(
                status: .noData, snapshot: nil, importedCount: 0,
                missingPhotoCount: 0, adoptedPhotoCount: 0, deferredPhotoCount: 0
            )
        }

        let latestStatus = try journal.read().entries.last(where: { $0.migration == kind })?.status
        let isInterruptedMigration = latestStatus == .started || latestStatus == .failed
        if fileManager.fileExists(atPath: repository.primaryURL.path), !isInterruptedMigration {
            // No migration provenance means this may contain newer native edits.
            // Never create media or replace the snapshot in that case.
            return .init(
                status: .nativeSnapshotConflict,
                snapshot: nil,
                importedCount: result.importedCount,
                missingPhotoCount: result.photoInventory.missingPaths.count,
                adoptedPhotoCount: 0,
                deferredPhotoCount: 0
            )
        }

        _ = try journal.begin(kind)
        do {
            try checkpoint(.journaled)
            let backupRoot = repository.legacyBackupDirectoryURL
                .appendingPathComponent(kind.rawValue, isDirectory: true)
            if let asyncStorageDirectory = source.asyncStorageDirectory {
                try repository.preserveLegacyDirectory(
                    asyncStorageDirectory,
                    migration: kind,
                    name: "AsyncStorage"
                )
            }
            let appGroupData = try Self.encodeAppGroupValues(result.appGroupValues)
            try repository.preserveLegacyArtifact(
                appGroupData,
                migration: kind,
                filename: "app-group-values.json"
            )
            _ = try LegacyDataImporter.backupPhotoFiles(
                from: source.documentsDirectory,
                to: backupRoot.appendingPathComponent("Documents", isDirectory: true),
                fileManager: fileManager
            )
            try checkpoint(.sourceBackedUp)

            // Media lives beside the canonical snapshot, not in Documents: the
            // latter remains the immutable Expo source throughout recovery.
            // The fixed date makes a restart produce byte-identical canonical
            // JobPhoto records rather than changing them at each retry.
            let nativePhotoRoot = repository.primaryURL.deletingLastPathComponent()
                .appendingPathComponent("Media", isDirectory: true)
            let snapshotWithDeviceState = try Self.applyingRestorableDeviceState(
                to: result.snapshot,
                auxiliaryValues: result.auxiliaryValues,
                currentSettings: currentSettings
            )
            let adoption = LegacyDataImporter.adoptPhotoFiles(
                in: snapshotWithDeviceState,
                legacyDocumentsDirectory: source.documentsDirectory,
                nativePhotoRoot: nativePhotoRoot,
                dateProvider: { _, _ in Date(timeIntervalSince1970: 0) },
                fileManager: fileManager
            )
            guard !Self.hasUnsafePhotoDeferral(adoption.deferred) else {
                throw LegacyMigrationCoordinatorError.unsafePhotoAdoption
            }
            try checkpoint(.photosAdopted)

            if fileManager.fileExists(atPath: repository.primaryURL.path) {
                let existingMatchesAdoption: Bool
                if let existingBytes = try? Data(contentsOf: repository.primaryURL),
                   let existing = try? Canonical.SnapshotCodec.decode(existingBytes),
                   let normalizedExisting = try? Canonical.SnapshotCodec.encode(existing),
                   let normalizedAdoption = try? Canonical.SnapshotCodec.encode(adoption.snapshot) {
                    existingMatchesAdoption = normalizedExisting == normalizedAdoption
                } else {
                    existingMatchesAdoption = false
                }
                guard existingMatchesAdoption else {
                    // The source backups and any media copies remain immutable,
                    // but the canonical snapshot is never overwritten.
                    try? journal.fail(kind)
                    return .init(
                        status: .nativeSnapshotConflict,
                        snapshot: nil,
                        importedCount: result.importedCount,
                        missingPhotoCount: result.photoInventory.missingPaths.count,
                        adoptedPhotoCount: adoption.adopted.count,
                        deferredPhotoCount: adoption.deferred.count
                    )
                }
            }

            let auxiliaryStore = NativeAuxiliaryStateStore(
                snapshotURL: repository.primaryURL,
                fileManager: fileManager
            )
            try auxiliaryStore.persist(result.auxiliaryValues)
            try checkpoint(.auxiliaryPersisted)

            try secureStore.persist(result.secureSettings)
            try checkpoint(.secretsPersisted)

            try repository.save(adoption.snapshot)
            try checkpoint(.snapshotPersisted)
            try journal.complete(kind)
            return .init(
                status: .migrated,
                snapshot: adoption.snapshot,
                importedCount: result.importedCount,
                missingPhotoCount: result.photoInventory.missingPaths.count,
                adoptedPhotoCount: adoption.adopted.count,
                deferredPhotoCount: adoption.deferred.count
            )
        } catch {
            try? journal.fail(kind)
            throw error
        }
    }

    private func liveSource() throws -> LegacyMigrationSource {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidates = LegacyDataImporter.asyncStorageCandidates(
            libraryDirectory: library,
            applicationSupportDirectory: applicationSupport,
            documentsDirectory: documents,
            bundleID: Bundle.main.bundleIdentifier ?? "com.gettradereadyapp.tradeready"
        )
        let asyncStorageDirectory = candidates.first {
            fileManager.fileExists(atPath: $0.appending(path: "manifest.json").path)
        }
        return LegacyMigrationSource(
            asyncStorageDirectory: asyncStorageDirectory,
            documentsDirectory: documents,
            secureSettings: try LegacyDataImporter.readSecureSettings(),
            appGroupValues: LegacyDataImporter.readAppGroupValues()
        )
    }

    private static func encodeAppGroupValues(_ values: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(values)
    }

    /// Device-global state can be restored before authentication, but only
    /// after exact semantic validation. Account-bound auxiliary bytes remain
    /// inert in their immutable artifact until a verified owner is available.
    private static func applyingRestorableDeviceState(
        to snapshot: Canonical.Snapshot,
        auxiliaryValues: [String: Data],
        currentSettings: BusinessSettings
    ) throws -> Canonical.Snapshot {
        guard let rawTheme = auxiliaryValues["__themePreference"],
              let themeValue = String(data: rawTheme, encoding: .utf8),
              let appearance = Appearance(rawValue: themeValue)
        else { return snapshot }

        var next = snapshot
        if let canonicalSettings = next.payload.settings {
            var edit = try CanonicalUIAdapters.edit(canonicalSettings)
            edit.value.appearance = appearance
            next.payload.settings = try CanonicalUIAdapters.canonical(from: edit)
        } else {
            var settings = currentSettings
            settings.appearance = appearance
            next.payload.settings = try CanonicalUIAdapters.canonical(from: settings)
        }
        return next
    }

    private static func hasUnsafePhotoDeferral(_ deferred: [LegacyPhotoAdoptionDeferred]) -> Bool {
        deferred.contains {
            switch $0.reason {
            case .photoIDCollision, .unsafeDestination, .destinationConflict, .writeFailed:
                true
            case .emptyReference, .nonFileReference, .outsideLegacyDocuments,
                 .notRegularFile, .missingSource, .unreadableSource,
                 .unsupportedFormat, .conversionFailed, .invalidPhotoID:
                false
            }
        }
    }
}
