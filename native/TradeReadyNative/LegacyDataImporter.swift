import Foundation
import CryptoKit
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(Security)
import Security
#endif

enum LegacyImportError: LocalizedError {
    case malformedManifest
    case malformedManifestEntry(key: String)
    case missingExternalValue(key: String)
    case photoBackupConflict(relativePath: String)
    case malformedValue(key: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .malformedManifest:
            "The legacy storage manifest could not be read."
        case .malformedManifestEntry(let key):
            "The legacy storage manifest contains an unsupported entry for \(key)."
        case .missingExternalValue(let key):
            "The legacy large value for \(key) is missing or unreadable."
        case .photoBackupConflict(let relativePath):
            "A different photo backup already exists at \(relativePath)."
        case .malformedValue(let key, _):
            "The legacy value for \(key) could not be decoded."
        }
    }
}

/// SecureStore values are carried beside the plain snapshot. The repository
/// must commit these to Keychain before it marks a migration complete; the
/// snapshot codec deliberately strips them from disk.
struct LegacySecureSettings: Equatable {
    var providerKey: String?
    var anthropicKey: String?
    var groqKey: String?
    /// Opaque Supabase bytes. They are never decoded during migration so
    /// future auth fields and token metadata survive byte-for-byte, including
    /// values that are not valid UTF-8.
    var supabaseSession: Data?

    init(
        providerKey: String? = nil,
        anthropicKey: String? = nil,
        groqKey: String? = nil,
        legacyGeminiKey: String? = nil,
        supabaseSession: Data? = nil
    ) {
        self.providerKey = providerKey
        self.anthropicKey = anthropicKey
        self.groqKey = groqKey.flatMap(Self.nonempty) ?? legacyGeminiKey.flatMap(Self.nonempty)
        self.supabaseSession = supabaseSession
    }

    /// Source compatibility for callers that already hold a UTF-8 session.
    /// New migration code must pass `Data` so the read boundary remains lossless.
    init(
        providerKey: String? = nil,
        anthropicKey: String? = nil,
        groqKey: String? = nil,
        legacyGeminiKey: String? = nil,
        supabaseSession: String
    ) {
        self.init(
            providerKey: providerKey,
            anthropicKey: anthropicKey,
            groqKey: groqKey,
            legacyGeminiKey: legacyGeminiKey,
            supabaseSession: Data(supabaseSession.utf8)
        )
    }

    var importedCount: Int {
        [providerKey, anthropicKey, groqKey]
            .compactMap { $0.flatMap(Self.nonempty) }.count
        + (supabaseSession?.isEmpty == false ? 1 : 0)
    }

    private static func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }
}

struct LegacyPhotoInventory: Equatable {
    let referencedPaths: Set<String>
    let existingPaths: Set<String>
    let missingPaths: Set<String>
    /// Every file in the four Expo-owned photo directories, including an
    /// orphan not referenced by the current JSON. Backups use this superset.
    let discoveredPaths: Set<String>
}

enum LegacyPhotoByteFormat: String, Equatable {
    case jpeg
    case png
    case gif
    case webP
    case heif
    case unknown
}

enum LegacyPhotoAdoptionAsset: Equatable {
    case legacyJobPhoto(jobID: String, index: Int)
    case jobPhoto(id: String)
    case expenseReceipt(expenseID: String)
    case businessLogo
}

enum LegacyPhotoAdoptionDeferredReason: Error, Equatable {
    case emptyReference
    case nonFileReference
    case outsideLegacyDocuments
    case notRegularFile
    case missingSource
    case unreadableSource
    case unsupportedFormat(LegacyPhotoByteFormat)
    case conversionFailed(LegacyPhotoByteFormat)
    case invalidPhotoID
    case photoIDCollision
    case unsafeDestination
    case destinationConflict
    case writeFailed
}

struct LegacyPhotoAdoptionDeferred: Equatable {
    let asset: LegacyPhotoAdoptionAsset
    let reason: LegacyPhotoAdoptionDeferredReason
}

/// Result of a non-destructive legacy photo adoption pass. Callers commit the
/// returned snapshot atomically with their migration journal. A deferred item
/// deliberately contains no filesystem path or file bytes, so it is safe to
/// reduce to counts for support diagnostics.
struct LegacyPhotoAdoptionResult {
    let snapshot: Canonical.Snapshot
    let adopted: [LegacyPhotoAdoptionAsset]
    let deferred: [LegacyPhotoAdoptionDeferred]
    let copiedFileCount: Int
    let reusedFileCount: Int
}

typealias LegacyPhotoIDProvider = (_ jobID: String, _ legacyReference: String) -> String
typealias LegacyPhotoDateProvider = (_ jobID: String, _ legacyReference: String) -> Date

enum LegacySecureStoreError: LocalizedError {
    case unreadable(key: String, status: Int32)
    case orphanChunks(key: String)
    case missingChunk(key: String, index: Int)
    case malformedChunk(key: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let key, let status):
            "The legacy secure value for \(key) could not be read (Keychain status \(status))."
        case .orphanChunks(let key):
            "The legacy secure value for \(key) has chunks but no base value."
        case .missingChunk(let key, let index):
            "The legacy secure value for \(key) is missing chunk \(index)."
        case .malformedChunk(let key):
            "The legacy secure value for \(key) contains an invalid chunk."
        }
    }
}

struct LegacyImportResult {
    let snapshot: Canonical.Snapshot
    let importedCount: Int
    /// Non-domain AsyncStorage state retained for the migration coordinator.
    /// Values are intentionally opaque; restoring account/sync cursors requires
    /// policy decisions above this decode boundary.
    let auxiliaryValues: [String: Data]
    let secureSettings: LegacySecureSettings
    /// Raw app-group strings captured by the caller at the same migration step.
    let appGroupValues: [String: String]
    let photoInventory: LegacyPhotoInventory
}

/// Sanitized App Group state that may be considered by the migration
/// coordinator after it has established the signed-in owner. This boundary is
/// deliberately separate from `Canonical.Snapshot`: App Group values are
/// derived UI state or pending cross-process input, never canonical records.
struct LegacyValidatedAppGroupValues: Equatable {
    struct WidgetAction: Equatable {
        /// The full object is retained so additive action fields and action
        /// types introduced by a newer widget are not lost before replay.
        let fields: [String: Canonical.JSONValue]

        var id: String { stringField("id")! }
        var type: String { stringField("type")! }
        var at: String { stringField("at")! }

        private func stringField(_ name: String) -> String? {
            guard case let .string(value) = fields[name] else { return nil }
            return value
        }
    }

    struct ActiveTrip: Equatable {
        let startedAt: Date
        let odometerStart: Double
    }

    enum PendingOpenURLRoute: Equatable {
        case job(id: String)
        case onMyWay(id: String)
    }

    struct PendingOpenURL: Equatable {
        let url: String
        let at: Date
        let route: PendingOpenURLRoute
    }

    /// A widget snapshot is only a cache derived from canonical records. Its
    /// bytes are intentionally absent from this value; a native app must
    /// regenerate it rather than restore or trust a legacy copy.
    let widgetSnapshotRequiresRegeneration: Bool
    let widgetActions: [WidgetAction]
    let activeTrip: ActiveTrip?
    let pendingOpenURL: PendingOpenURL?
}

enum LegacyDataImporter {
    static let appGroupID = "group.com.gettradereadyapp.tradeready"
    static let appGroupKeys = ["widgetSnapshot", "widgetActions", "activeTrip", "pendingOpenUrl"]
    static let legacySecureStoreServices = ["app:no-auth", "app:auth", "app"]
    static let supabaseSessionKey = "supabase_session"
    static let secureStoreChunkLimitBytes = 2_048

    /// Reads the exact UserDefaults suite shared by the Expo app, widget, and
    /// App Intents. It is read-only: pending actions and cold-launch URLs must
    /// remain available until the native migration coordinator commits them.
    static func readAppGroupValues(defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)) -> [String: String] {
        guard let defaults else { return [:] }
        return Dictionary(uniqueKeysWithValues: appGroupKeys.compactMap { key in
            defaults.string(forKey: key).map { (key, $0) }
        })
    }

    /// Parses App Group input without reading or changing UserDefaults. The
    /// caller must still enforce account ownership and replay actions as one
    /// committed batch; this function never applies an action itself.
    static func validateAppGroupValues(
        _ values: [String: String],
        now: Date
    ) -> LegacyValidatedAppGroupValues {
        LegacyValidatedAppGroupValues(
            widgetSnapshotRequiresRegeneration: values["widgetSnapshot"] != nil,
            widgetActions: parseWidgetActions(values["widgetActions"]),
            activeTrip: parseActiveTrip(values["activeTrip"], now: now),
            pendingOpenURL: parsePendingOpenURL(values["pendingOpenUrl"], now: now)
        )
    }

    /// Expo SecureStore 15 uses `app:no-auth` for ordinary values and still
    /// probes the pre-v12 `app` service for compatibility. We mirror that read
    /// order, plus `app:auth`, without deleting or rewriting the old entries.
    /// A locked/inaccessible Keychain is reported as an error rather than being
    /// mistaken for an account with no secrets.
    static func readSecureSettings() throws -> LegacySecureSettings {
        #if canImport(Security)
        return try secureSettings(
            serviceInventories: try legacySecureStoreServices.map(readSecureStoreInventory(service:))
        )
        #else
        return LegacySecureSettings()
        #endif
    }

    #if canImport(Security)
    /// The read rules `readSecureSettings` applies to the three service
    /// inventories, in `legacySecureStoreServices` order. Phase 12 (G6-Q1):
    /// split out so a host test reads a fixture device's legacy secure store
    /// through the same rules the launch migration uses.
    static func secureSettings(serviceInventories inventories: [[String: Data]]) throws -> LegacySecureSettings {
        func readSingle(_ key: String) throws -> String? {
            for inventory in inventories {
                guard let data = inventory[key] else { continue }
                guard let value = String(data: data, encoding: .utf8) else {
                    throw LegacySecureStoreError.unreadable(key: key, status: errSecDecode)
                }
                return value
            }
            return nil
        }

        return try LegacySecureSettings(
            providerKey: readSingle("providerKey"),
            anthropicKey: readSingle("anthropicKey"),
            groqKey: readSingle("groqKey"),
            legacyGeminiKey: readSingle("geminiKey"),
            supabaseSession: try reassembleSecureStoreValue(
                key: supabaseSessionKey,
                serviceInventories: inventories
            )
        )
    }
    #endif

    /// Reconstructs one complete Expo SecureStore value from a single service.
    /// A base item is mandatory; all numbered chunks must be contiguous. This
    /// deliberately accepts arbitrary bytes rather than assuming a JSON/UTF-8
    /// session payload.
    static func reassembleSecureStoreValue(
        key: String,
        inventory: [String: Data]
    ) throws -> Data? {
        let chunkIndices = try secureStoreChunkIndices(key: key, inventory: inventory)
        guard let base = inventory[key] else {
            if !chunkIndices.isEmpty { throw LegacySecureStoreError.orphanChunks(key: key) }
            return nil
        }
        guard isValidSecureStoreChunk(base) else {
            throw LegacySecureStoreError.malformedChunk(key: key)
        }

        guard let finalIndex = chunkIndices.max() else { return base }
        var result = base
        for index in 1...finalIndex {
            guard let chunk = inventory["\(key)_chunk_\(index)"] else {
                throw LegacySecureStoreError.missingChunk(key: key, index: index)
            }
            result.append(chunk)
        }
        return result
    }

    /// Applies the legacy service precedence without ever joining a base from
    /// one service to chunks stored in another. A corrupt higher-priority
    /// service is surfaced instead of silently selecting an older session.
    static func reassembleSecureStoreValue(
        key: String,
        serviceInventories: [[String: Data]]
    ) throws -> Data? {
        for inventory in serviceInventories {
            guard hasSecureStoreEntries(for: key, inventory: inventory) else { continue }
            return try reassembleSecureStoreValue(key: key, inventory: inventory)
        }
        return nil
    }

    private static func hasSecureStoreEntries(for key: String, inventory: [String: Data]) -> Bool {
        inventory[key] != nil || inventory.keys.contains { $0.hasPrefix("\(key)_chunk_") }
    }

    private static func secureStoreChunkIndices(key: String, inventory: [String: Data]) throws -> Set<Int> {
        let prefix = "\(key)_chunk_"
        var result: Set<Int> = []
        for candidate in inventory.keys where candidate.hasPrefix(prefix) {
            let suffix = String(candidate.dropFirst(prefix.count))
            guard let index = Int(suffix), index > 0, suffix == String(index),
                  let data = inventory[candidate], isValidSecureStoreChunk(data)
            else { throw LegacySecureStoreError.malformedChunk(key: key) }
            result.insert(index)
        }
        return result
    }

    private static func isValidSecureStoreChunk(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= secureStoreChunkLimitBytes
    }

    #if canImport(Security)
    /// Reads all Expo-compatible generic-password entries for one service in a
    /// single inventory. `errSecItemNotFound` is an empty service; any other
    /// status is inaccessible and must not be collapsed into "missing".
    private static func readSecureStoreInventory(service: String) throws -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else {
            throw LegacySecureStoreError.unreadable(key: "secure-store", status: status)
        }
        guard let records = item as? [[String: Any]] else {
            throw LegacySecureStoreError.unreadable(key: "secure-store", status: errSecDecode)
        }

        var inventory: [String: Data] = [:]
        for record in records {
            guard let key = secureStoreKeyName(record[kSecAttrAccount as String]),
                  let data = record[kSecValueData as String] as? Data
            else { continue }
            inventory[key] = data
        }
        return inventory
    }

    private static func secureStoreKeyName(_ value: Any?) -> String? {
        switch value {
        case let data as Data:
            String(data: data, encoding: .utf8)
        case let string as String:
            string
        default:
            nil
        }
    }
    #endif

    static func importSnapshot(
        currentSettings: BusinessSettings,
        secureSettings: LegacySecureSettings = .init(),
        appGroupValues: [String: String]? = nil
    ) throws -> LegacyImportResult {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.gettradereadyapp.tradeready"
        let candidates = asyncStorageCandidates(
            libraryDirectory: library,
            applicationSupportDirectory: applicationSupport,
            documentsDirectory: documents,
            bundleID: bundleID
        )
        guard let directory = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path)
        }) else {
            let settings = try CanonicalUIAdapters.canonical(from: currentSettings)
            let snapshot = Canonical.Snapshot(payload: .init(settings: merge(secureSettings, into: settings)))
            return LegacyImportResult(
                snapshot: snapshot,
                importedCount: secureSettings.importedCount,
                auxiliaryValues: [:],
                secureSettings: secureSettings,
                appGroupValues: filteredAppGroupValues(appGroupValues ?? readAppGroupValues()),
                photoInventory: photoInventory(for: snapshot, documentsDirectory: documents)
            )
        }
        return try importSnapshot(
            asyncStorageDirectory: directory,
            documentsDirectory: documents,
            currentSettings: currentSettings,
            secureSettings: secureSettings,
            appGroupValues: appGroupValues ?? readAppGroupValues()
        )
    }

    /// AsyncStorage 2.2 writes under Application Support/[bundle id]. Older
    /// community and Expo builds used three Documents variants; keeping them
    /// as read-only fallbacks covers upgrades that never launched a version
    /// new enough to perform AsyncStorage's own directory migration.
    static func asyncStorageCandidates(
        libraryDirectory: URL,
        applicationSupportDirectory: URL,
        documentsDirectory: URL,
        bundleID: String
    ) -> [URL] {
        [
            applicationSupportDirectory.appending(path: "\(bundleID)/RCTAsyncLocalStorage_V1"),
            applicationSupportDirectory.appending(path: "RCTAsyncLocalStorage_V1"),
            libraryDirectory.appending(path: "RCTAsyncLocalStorage_V1"),
            documentsDirectory.appending(path: "RCTAsyncLocalStorage_V1"),
            documentsDirectory.appending(path: "RNCAsyncLocalStorage_V1"),
            documentsDirectory.appending(path: "RCTAsyncLocalStorage")
        ]
    }

    /// Filesystem entry point kept separate for fixture and interruption tests.
    static func importSnapshot(
        asyncStorageDirectory: URL,
        documentsDirectory: URL,
        currentSettings: BusinessSettings,
        secureSettings: LegacySecureSettings = .init(),
        appGroupValues: [String: String] = [:]
    ) throws -> LegacyImportResult {
        let values = try readAsyncStorageValues(from: asyncStorageDirectory)
        return try decodeSnapshot(
            values: values,
            currentSettings: currentSettings,
            secureSettings: secureSettings,
            appGroupValues: appGroupValues,
            documentsDirectory: documentsDirectory
        )
    }

    /// Reads every manifest entry, not just currently modeled collections. A
    /// null manifest value means AsyncStorage put the bytes in an MD5-named
    /// sidecar. Missing sidecars are corruption, never an absent key.
    static func readAsyncStorageValues(from directory: URL) throws -> [String: Data] {
        let manifestURL = directory.appending(path: "manifest.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) }
        catch { throw LegacyImportError.malformedManifest }

        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw LegacyImportError.malformedManifest }
        guard let manifest = object as? [String: Any] else { throw LegacyImportError.malformedManifest }

        var result: [String: Data] = [:]
        for (key, entry) in manifest {
            if let inline = entry as? String {
                result[key] = Data(inline.utf8)
            } else if entry is NSNull {
                let valueURL = directory.appending(path: md5Filename(for: key))
                do { result[key] = try Data(contentsOf: valueURL) }
                catch { throw LegacyImportError.missingExternalValue(key: key) }
            } else {
                throw LegacyImportError.malformedManifestEntry(key: key)
            }
        }
        return result
    }

    /// Pure import boundary used by integration tests. React Native values are
    /// decoded directly into the canonical wire types so fields unavailable in
    /// today's SwiftUI screens are retained without a lossy prototype hop.
    static func decodeSnapshot(
        values: [String: Data],
        currentSettings: BusinessSettings,
        secureSettings: LegacySecureSettings = .init(),
        appGroupValues: [String: String] = [:],
        documentsDirectory: URL? = nil
    ) throws -> LegacyImportResult {
        let invoices: [Canonical.Invoice] = try decode(values["invoices"], key: "invoices") ?? []
        let jobs: [Canonical.Job] = try decode(values["jobs"], key: "jobs") ?? []
        let customers: [Canonical.Customer] = try decode(values["customers"], key: "customers") ?? []
        let expenses: [Canonical.Expense] = try decode(values["expenses"], key: "expenses") ?? []
        let customerNotes: Canonical.CustomerNotes? = try decode(values["customerNotes"], key: "customerNotes")
        let recurringJobs: [Canonical.RecurringJob]? = try decode(values["recurringJobs"], key: "recurringJobs")
        let recurringInvoices: [Canonical.RecurringInvoice]? = try decode(values["recurringInvoices"], key: "recurringInvoices")
        let trips: [Canonical.Trip]? = try decode(values["trips"], key: "trips")
        let pricebook: [Canonical.PricebookEntry]? = try decode(values["pricebook"], key: "pricebook")
        let bookingRequests: [Canonical.BookingRequest]? = try decode(values["bookingRequests"], key: "bookingRequests")
        let jobPhotos: [Canonical.JobPhoto]? = try decode(values["jobPhotos"], key: "jobPhotos")
        var settings: Canonical.Settings = try decode(values["settings"], key: "settings")
            ?? CanonicalUIAdapters.canonical(from: currentSettings)
        settings = merge(secureSettings, into: settings)

        let payload = Canonical.SnapshotPayload(
            invoices: invoices,
            jobs: jobs,
            customers: customers,
            settings: settings,
            expenses: expenses,
            customerNotes: customerNotes,
            recurringJobs: recurringJobs,
            recurringInvoices: recurringInvoices,
            trips: trips,
            pricebook: pricebook,
            bookingRequests: bookingRequests,
            jobPhotos: jobPhotos
        )
        let count = invoices.count + jobs.count + customers.count + expenses.count
            + (customerNotes?.count ?? 0) + (recurringJobs?.count ?? 0)
            + (recurringInvoices?.count ?? 0) + (trips?.count ?? 0)
            + (pricebook?.count ?? 0) + (bookingRequests?.count ?? 0)
            + (jobPhotos?.count ?? 0) + (values["settings"] == nil ? 0 : 1)
        let snapshot = Canonical.Snapshot(payload: payload)
        let auxiliary = values.filter { !storageKeySet.contains($0.key) }
        let photos = documentsDirectory.map { photoInventory(for: snapshot, documentsDirectory: $0) }
            ?? LegacyPhotoInventory(referencedPaths: [], existingPaths: [], missingPaths: [], discoveredPaths: [])
        return LegacyImportResult(
            snapshot: snapshot,
            importedCount: count + secureSettings.importedCount,
            auxiliaryValues: auxiliary,
            secureSettings: secureSettings,
            appGroupValues: filteredAppGroupValues(appGroupValues),
            photoInventory: photos
        )
    }

    private static let storageKeys = [
        "invoices", "jobs", "customers", "settings", "expenses", "customerNotes",
        "recurringJobs", "recurringInvoices", "trips", "pricebook", "bookingRequests", "jobPhotos"
    ]
    private static let storageKeySet = Set(storageKeys)

    private static func decode<T: Decodable>(_ data: Data?, key: String) throws -> T? {
        guard let data else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LegacyImportError.malformedValue(key: key, underlying: error) }
    }

    // AsyncStorage uses MD5 filenames for values larger than the inline limit.
    static func md5Filename(for key: String) -> String {
        Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func merge(_ secure: LegacySecureSettings, into settings: Canonical.Settings) -> Canonical.Settings {
        var merged = settings
        if let value = secure.providerKey { merged.providerKey = value }
        if let value = secure.anthropicKey { merged.anthropicKey = value }
        if let value = secure.groqKey { merged.groqKey = value }
        return merged
    }

    private static func filteredAppGroupValues(_ values: [String: String]) -> [String: String] {
        values.filter { appGroupKeys.contains($0.key) }
    }

    private static func parseWidgetActions(_ raw: String?) -> [LegacyValidatedAppGroupValues.WidgetAction] {
        guard let raw, let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([Canonical.JSONValue].self, from: data)
        else { return [] }

        return values.compactMap { value in
            guard case let .object(fields) = value,
                  case .string = fields["id"],
                  case .string = fields["type"],
                  case .string = fields["at"]
            else { return nil }
            return LegacyValidatedAppGroupValues.WidgetAction(fields: fields)
        }
    }

    private static func parseActiveTrip(_ raw: String?, now: Date) -> LegacyValidatedAppGroupValues.ActiveTrip? {
        guard let fields = appGroupObject(raw),
              let startedAt = string("startedAt", in: fields),
              let started = parseISO8601(startedAt),
              let odometer = number("odometerStart", in: fields)
        else { return nil }

        let age = now.timeIntervalSince(started)
        guard odometer.isFinite, odometer >= 0,
              age >= 0, age <= 24 * 60 * 60
        else { return nil }
        return LegacyValidatedAppGroupValues.ActiveTrip(startedAt: started, odometerStart: odometer)
    }

    private static func parsePendingOpenURL(_ raw: String?, now: Date) -> LegacyValidatedAppGroupValues.PendingOpenURL? {
        guard let fields = appGroupObject(raw),
              let rawURL = string("url", in: fields),
              let rawDate = string("at", in: fields),
              let date = parseISO8601(rawDate)
        else { return nil }

        let age = now.timeIntervalSince(date)
        guard age >= 0, age <= 5 * 60, let route = parsePendingOpenURLRoute(rawURL) else { return nil }
        return LegacyValidatedAppGroupValues.PendingOpenURL(url: rawURL, at: date, route: route)
    }

    private static func appGroupObject(_ raw: String?) -> [String: Canonical.JSONValue]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Canonical.JSONValue].self, from: data)
    }

    private static func string(_ key: String, in fields: [String: Canonical.JSONValue]) -> String? {
        guard case let .string(value) = fields[key] else { return nil }
        return value
    }

    private static func number(_ key: String, in fields: [String: Canonical.JSONValue]) -> Double? {
        guard case let .number(value) = fields[key] else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Mirrors the legacy JavaScript deep-link grammar while rejecting URL
    /// queries, fragments, extra path segments, malformed escapes, and IDs
    /// that decode to nothing. The raw segment may contain a percent-encoded
    /// slash; it is still one URL segment before decoding.
    private static func parsePendingOpenURLRoute(
        _ rawURL: String
    ) -> LegacyValidatedAppGroupValues.PendingOpenURLRoute? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "tradeready://"
        guard trimmed.count >= prefix.count,
              trimmed.prefix(prefix.count).lowercased() == prefix
        else { return nil }

        let remainder = trimmed.dropFirst(prefix.count)
        let components = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              !components[1].contains("?"),
              !components[1].contains("#"),
              let identifier = String(components[1]).removingPercentEncoding,
              !identifier.isEmpty
        else { return nil }

        switch components[0].lowercased() {
        case "job": return .job(id: identifier)
        case "onmyway": return .onMyWay(id: identifier)
        default: return nil
        }
    }

    /// Stable across interrupted coordinator runs and valid for the existing
    /// backend/local-file photo ID grammar. The source bytes are intentionally
    /// not part of the ID: a temporarily unreadable file must receive the same
    /// identity when a later pass can read it.
    static func stableLegacyPhotoID(jobID: String, legacyReference: String) -> String {
        let identity = Data("\(jobID)\u{0}\(legacyReference)".utf8)
        let digest = SHA256.hash(data: identity).prefix(16)
        return "p0_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Copies legacy photo bytes into deterministic native locations without
    /// changing or deleting the Expo files. The returned snapshot clears only
    /// references whose bytes are safely present at their native destination.
    /// No image is decoded, recompressed, or assigned guessed dimensions.
    static func adoptPhotoFiles(
        in snapshot: Canonical.Snapshot,
        legacyDocumentsDirectory: URL,
        nativePhotoRoot: URL,
        idProvider: LegacyPhotoIDProvider = stableLegacyPhotoID,
        dateProvider: LegacyPhotoDateProvider,
        fileManager: FileManager = .default
    ) -> LegacyPhotoAdoptionResult {
        var next = snapshot
        var adopted: [LegacyPhotoAdoptionAsset] = []
        var deferred: [LegacyPhotoAdoptionDeferred] = []
        var copiedCount = 0
        var reusedCount = 0
        let legacyRoot = legacyDocumentsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let nativeRoot = nativePhotoRoot.resolvingSymlinksInPath().standardizedFileURL

        func deferAsset(_ asset: LegacyPhotoAdoptionAsset, _ reason: LegacyPhotoAdoptionDeferredReason) {
            deferred.append(.init(asset: asset, reason: reason))
        }

        func record(_ outcome: PhotoCopyOutcome, asset: LegacyPhotoAdoptionAsset) -> Bool {
            switch outcome {
            case .copied:
                copiedCount += 1
                adopted.append(asset)
                return true
            case .reused:
                reusedCount += 1
                adopted.append(asset)
                return true
            case .deferred(let reason):
                deferAsset(asset, reason)
                return false
            }
        }

        // Existing JobPhoto records already have a deterministic JPEG contract.
        // Copy their legacy bytes first so a canonical record never points at a
        // file we merely assumed was available.
        for photo in next.payload.jobPhotos ?? [] {
            let asset = LegacyPhotoAdoptionAsset.jobPhoto(id: photo.id)
            guard isValidJobPhotoID(photo.id) else {
                deferAsset(asset, .invalidPhotoID)
                continue
            }
            let source = legacyRoot.appending(path: "job-photos/\(photo.id).jpg")
            let destination = nativeRoot.appending(path: "job-photos/\(photo.id).jpg")
            let sourceExists = fileManager.fileExists(atPath: source.path)
            if !sourceExists, let destinationData = try? Data(contentsOf: destination),
               detectPhotoFormat(destinationData) == .jpeg {
                _ = record(.reused, asset: asset)
                continue
            }
            guard sourceExists else {
                deferAsset(asset, .missingSource)
                continue
            }
            guard containedFile(source, beneath: legacyRoot, fileManager: fileManager) else {
                deferAsset(asset, .outsideLegacyDocuments)
                continue
            }
            guard let data = try? Data(contentsOf: source) else {
                deferAsset(asset, .unreadableSource)
                continue
            }
            switch normalizedJobPhotoBytes(data) {
            case .success(let normalized):
                _ = record(copyExact(normalized, to: destination, beneath: nativeRoot, fileManager: fileManager), asset: asset)
            case .failure(let reason):
                deferAsset(asset, reason)
            }
        }

        var photoRecords = next.payload.jobPhotos ?? []
        let hadPhotoCollection = next.payload.jobPhotos != nil
        let preexistingPhotoIDs = Set(photoRecords.map(\.id))
        var createdIdentityByID: [String: (jobID: String, reference: String)] = [:]

        if var jobs = next.payload.jobs {
            for jobIndex in jobs.indices {
                guard let references = jobs[jobIndex].photos, !references.isEmpty else { continue }
                var kept: [String] = []
                for (referenceIndex, reference) in references.enumerated() {
                    let asset = LegacyPhotoAdoptionAsset.legacyJobPhoto(jobID: jobs[jobIndex].id, index: referenceIndex)
                    guard !reference.isEmpty else {
                        deferAsset(asset, .emptyReference); kept.append(reference); continue
                    }
                    guard let source = sourceURL(for: reference, relativeTo: legacyRoot) else {
                        deferAsset(asset, .nonFileReference); kept.append(reference); continue
                    }
                    guard isContained(source, beneath: legacyRoot) else {
                        deferAsset(asset, .outsideLegacyDocuments); kept.append(reference); continue
                    }
                    guard fileManager.fileExists(atPath: source.path) else {
                        deferAsset(asset, .missingSource); kept.append(reference); continue
                    }
                    guard containedFile(source, beneath: legacyRoot, fileManager: fileManager) else {
                        deferAsset(asset, .outsideLegacyDocuments); kept.append(reference); continue
                    }
                    guard let data = try? Data(contentsOf: source) else {
                        deferAsset(asset, .unreadableSource); kept.append(reference); continue
                    }
                    let normalized: Data
                    switch normalizedJobPhotoBytes(data) {
                    case .success(let value): normalized = value
                    case .failure(let reason):
                        deferAsset(asset, reason); kept.append(reference); continue
                    }

                    let photoID = idProvider(jobs[jobIndex].id, reference)
                    guard isValidJobPhotoID(photoID) else {
                        deferAsset(asset, .invalidPhotoID); kept.append(reference); continue
                    }
                    // A canonical record and legacy reference cannot both be
                    // produced by one atomic snapshot commit, so every ID that
                    // existed on entry is an ambiguous collision. Within this
                    // pass, only an exact duplicate reference may share the one
                    // record just created for it.
                    if preexistingPhotoIDs.contains(photoID) {
                        deferAsset(asset, .photoIDCollision); kept.append(reference); continue
                    }
                    if let identity = createdIdentityByID[photoID],
                       identity.jobID != jobs[jobIndex].id || identity.reference != reference {
                        deferAsset(asset, .photoIDCollision); kept.append(reference); continue
                    }

                    let destination = nativeRoot.appending(path: "job-photos/\(photoID).jpg")
                    let outcome = copyExact(normalized, to: destination, beneath: nativeRoot, fileManager: fileManager)
                    guard record(outcome, asset: asset) else { kept.append(reference); continue }

                    if createdIdentityByID[photoID] == nil {
                        let createdAt = canonicalPhotoTimestamp(dateProvider(jobs[jobIndex].id, reference))
                        photoRecords.append(.init(adoptedID: photoID, jobID: jobs[jobIndex].id, createdAt: createdAt))
                        createdIdentityByID[photoID] = (jobs[jobIndex].id, reference)
                    }
                }
                jobs[jobIndex].photos = kept.isEmpty ? nil : kept
            }
            next.payload.jobs = jobs
        }
        if hadPhotoCollection || !photoRecords.isEmpty { next.payload.jobPhotos = photoRecords }

        // Receipt and logo paths have no separate metadata record. Preserve the
        // original bytes and rewrite only formats whose extension can be stated
        // truthfully. Native-contract paths are accepted on a repeated pass.
        if var expenses = next.payload.expenses {
            for index in expenses.indices {
                guard let reference = expenses[index].receiptUri, !reference.isEmpty else { continue }
                let asset = LegacyPhotoAdoptionAsset.expenseReceipt(expenseID: expenses[index].id)
                if let native = acceptedNativeReference(reference, folder: "receipts", beneath: nativeRoot, fileManager: fileManager) {
                    expenses[index].receiptUri = native.absoluteString
                    _ = record(.reused, asset: asset)
                    continue
                }
                guard let source = sourceURL(for: reference, relativeTo: legacyRoot) else {
                    deferAsset(asset, .nonFileReference); continue
                }
                guard isContained(source, beneath: legacyRoot) else {
                    deferAsset(asset, .outsideLegacyDocuments); continue
                }
                guard fileManager.fileExists(atPath: source.path) else {
                    deferAsset(asset, .missingSource); continue
                }
                guard containedFile(source, beneath: legacyRoot, fileManager: fileManager) else {
                    deferAsset(asset, .outsideLegacyDocuments); continue
                }
                guard let data = try? Data(contentsOf: source) else {
                    deferAsset(asset, .unreadableSource); continue
                }
                let normalized: NativePhotoPayload
                switch normalizedStandalonePhotoBytes(data) {
                case .success(let value): normalized = value
                case .failure(let reason): deferAsset(asset, reason); continue
                }
                let ext = normalized.fileExtension
                let name = "r_\(stableDigest(expenses[index].id + "\u{0}" + reference)).\(ext)"
                let destination = nativeRoot.appending(path: "receipts/\(name)")
                guard record(copyExact(normalized.data, to: destination, beneath: nativeRoot, fileManager: fileManager), asset: asset) else { continue }
                expenses[index].receiptUri = destination.absoluteString
            }
            next.payload.expenses = expenses
        }

        if var settings = next.payload.settings, let reference = settings.logoPhoto, !reference.isEmpty {
            let asset = LegacyPhotoAdoptionAsset.businessLogo
            if let native = acceptedNativeReference(reference, folder: "logos", beneath: nativeRoot, fileManager: fileManager) {
                settings.logoPhoto = native.absoluteString
                _ = record(.reused, asset: asset)
            } else if let source = sourceURL(for: reference, relativeTo: legacyRoot) {
                if !isContained(source, beneath: legacyRoot) {
                    deferAsset(asset, .outsideLegacyDocuments)
                } else if !fileManager.fileExists(atPath: source.path) {
                    deferAsset(asset, .missingSource)
                } else if !containedFile(source, beneath: legacyRoot, fileManager: fileManager) {
                    deferAsset(asset, .outsideLegacyDocuments)
                } else if let data = try? Data(contentsOf: source) {
                    switch normalizedStandalonePhotoBytes(data) {
                    case .success(let normalized):
                        let ext = normalized.fileExtension
                        let destination = nativeRoot.appending(path: "logos/logo_\(stableDigest(reference)).\(ext)")
                        if record(copyExact(normalized.data, to: destination, beneath: nativeRoot, fileManager: fileManager), asset: asset) {
                            settings.logoPhoto = destination.absoluteString
                        }
                    case .failure(let reason): deferAsset(asset, reason)
                    }
                } else { deferAsset(asset, .unreadableSource) }
            } else { deferAsset(asset, .nonFileReference) }
            next.payload.settings = settings
        }

        return .init(
            snapshot: next,
            adopted: adopted,
            deferred: deferred,
            copiedFileCount: copiedCount,
            reusedFileCount: reusedCount
        )
    }

    private enum PhotoCopyOutcome {
        case copied
        case reused
        case deferred(LegacyPhotoAdoptionDeferredReason)
    }

    private static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidJobPhotoID(_ value: String) -> Bool {
        value.range(of: #"^p[0-9]{1,20}_[a-z0-9]{1,32}$"#, options: .regularExpression) != nil
    }

    private static func canonicalPhotoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func sourceURL(for reference: String, relativeTo root: URL) -> URL? {
        if let parsed = URL(string: reference), parsed.scheme != nil {
            return parsed.isFileURL ? parsed.standardizedFileURL : nil
        }
        if reference.hasPrefix("/") { return URL(fileURLWithPath: reference).standardizedFileURL }
        return root.appending(path: reference).standardizedFileURL
    }

    private static func isContained(_ url: URL, beneath root: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func containedFile(_ url: URL, beneath root: URL, fileManager: FileManager) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved, beneath: root) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func detectPhotoFormat(_ data: Data) -> LegacyPhotoByteFormat {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 3, bytes[0...2].elementsEqual([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.count >= 8, bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.count >= 6, String(bytes: bytes[0...5], encoding: .ascii)?.hasPrefix("GIF8") == true { return .gif }
        if bytes.count >= 12, String(bytes: bytes[8...11], encoding: .ascii) == "WEBP" { return .webP }
        if bytes.count >= 12, String(bytes: bytes[4...7], encoding: .ascii) == "ftyp" { return .heif }
        return .unknown
    }

    private static func losslessStandaloneExtension(_ format: LegacyPhotoByteFormat) -> String? {
        switch format {
        case .jpeg: "jpg"
        case .png: "png"
        default: nil
        }
    }

    private struct NativePhotoPayload {
        let data: Data
        let fileExtension: String
    }

    private static func normalizedJobPhotoBytes(
        _ data: Data
    ) -> Result<Data, LegacyPhotoAdoptionDeferredReason> {
        let format = detectPhotoFormat(data)
        if format == .jpeg { return .success(data) }
        guard format != .unknown else { return .failure(.unsupportedFormat(format)) }
        guard let converted = convertFirstFrameToJPEG(data) else {
            return .failure(.conversionFailed(format))
        }
        return .success(converted)
    }

    private static func normalizedStandalonePhotoBytes(
        _ data: Data
    ) -> Result<NativePhotoPayload, LegacyPhotoAdoptionDeferredReason> {
        let format = detectPhotoFormat(data)
        if let ext = losslessStandaloneExtension(format) {
            return .success(.init(data: data, fileExtension: ext))
        }
        guard format != .unknown else { return .failure(.unsupportedFormat(format)) }
        guard let converted = convertFirstFrameToJPEG(data) else {
            return .failure(.conversionFailed(format))
        }
        return .success(.init(data: converted, fileExtension: "jpg"))
    }

    /// The immutable legacy backup remains the lossless source. Native-owned
    /// paths use a broadly decodable, single-frame JPEG so HEIF/WebP/GIF input
    /// cannot strand an otherwise recoverable job, receipt, or logo.
    private static func convertFirstFrameToJPEG(_ data: Data) -> Data? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let converted = output as Data
        return detectPhotoFormat(converted) == .jpeg ? converted : nil
        #else
        return nil
        #endif
    }

    private static func acceptedNativeReference(
        _ reference: String,
        folder: String,
        beneath root: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let url = sourceURL(for: reference, relativeTo: root),
              containedFile(url, beneath: root, fileManager: fileManager),
              url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                == root.appending(path: folder).resolvingSymlinksInPath().standardizedFileURL,
              let data = try? Data(contentsOf: url),
              let ext = losslessStandaloneExtension(detectPhotoFormat(data)),
              url.pathExtension.lowercased() == ext,
              isValidStandaloneFilename(url.deletingPathExtension().lastPathComponent, folder: folder)
        else { return nil }
        return url.standardizedFileURL
    }

    private static func isValidStandaloneFilename(_ stem: String, folder: String) -> Bool {
        let prefix: String
        switch folder {
        case "receipts": prefix = "r_"
        case "logos": prefix = "logo_"
        default: return false
        }
        let digest = String(stem.dropFirst(prefix.count))
        return stem.hasPrefix(prefix) && digest.count == 32
            && digest.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil
    }

    private static func copyExact(
        _ data: Data,
        to destination: URL,
        beneath root: URL,
        fileManager: FileManager
    ) -> PhotoCopyOutcome {
        do {
            let directory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard isContained(directory.resolvingSymlinksInPath(), beneath: root) else {
                return .deferred(.unsafeDestination)
            }
            if fileManager.fileExists(atPath: destination.path) {
                guard containedFile(destination, beneath: root, fileManager: fileManager) else {
                    return .deferred(.unsafeDestination)
                }
                return (try Data(contentsOf: destination)) == data ? .reused : .deferred(.destinationConflict)
            }

            let temporary = directory.appending(path: ".adoption-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: [.atomic])
            // A hard-link publication is atomic and fails if the destination
            // appeared concurrently; unlike rename(2), it can never replace an
            // existing inode. Removing the private temporary name afterwards
            // leaves the completed bytes reachable at the stable path.
            do { try fileManager.linkItem(at: temporary, to: destination) }
            catch {
                if fileManager.fileExists(atPath: destination.path),
                   let existing = try? Data(contentsOf: destination) {
                    return existing == data ? .reused : .deferred(.destinationConflict)
                }
                return .deferred(.writeFailed)
            }
            return .copied
        } catch {
            return .deferred(.writeFailed)
        }
    }

    /// Inventories all document-backed image references without copying or
    /// deleting anything. The repository can back up the existing set and
    /// surface missing references before committing the migration.
    static func photoInventory(
        for snapshot: Canonical.Snapshot,
        documentsDirectory: URL,
        fileManager: FileManager = .default
    ) -> LegacyPhotoInventory {
        var references = Set<String>()
        for path in snapshot.payload.jobs?.flatMap({ $0.photos ?? [] }) ?? [] where !path.isEmpty {
            references.insert(path)
        }
        for path in snapshot.payload.expenses?.compactMap(\.receiptUri) ?? [] where !path.isEmpty {
            references.insert(path)
        }
        if let path = snapshot.payload.settings?.logoPhoto, !path.isEmpty { references.insert(path) }
        for photo in snapshot.payload.jobPhotos ?? [] {
            references.insert(documentsDirectory.appending(path: "job-photos/\(photo.id).jpg").path)
        }

        var existing = Set<String>()
        var missing = Set<String>()
        for rawPath in references {
            let path = URL(string: rawPath)?.isFileURL == true ? URL(string: rawPath)!.path : rawPath
            if fileManager.fileExists(atPath: path) { existing.insert(rawPath) }
            else { missing.insert(rawPath) }
        }
        return LegacyPhotoInventory(
            referencedPaths: references,
            existingPaths: existing,
            missingPaths: missing,
            discoveredPaths: discoverPhotoFiles(in: documentsDirectory, fileManager: fileManager)
        )
    }

    /// Expo writes these paths beneath documentDirectory. Copying the complete
    /// directories (not only live JSON references) protects against an
    /// interrupted legacy photo-adoption pass and lets support inspect orphans.
    static let legacyPhotoDirectories = ["photos", "logos", "receipts", "job-photos"]

    static func discoverPhotoFiles(
        in documentsDirectory: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        var result = Set<String>()
        let resolvedDocuments = documentsDirectory.resolvingSymlinksInPath()
        for name in legacyPhotoDirectories {
            let directory = resolvedDocuments.appending(path: name, directoryHint: .isDirectory)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                result.insert(url.path)
            }
        }
        return result
    }

    /// Non-destructive, idempotent photo backup. Existing identical files are
    /// accepted; a byte mismatch stops the migration instead of overwriting a
    /// prior recovery copy.
    @discardableResult
    static func backupPhotoFiles(
        from documentsDirectory: URL,
        to backupDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        var copied = 0
        let sources = discoverPhotoFiles(in: documentsDirectory, fileManager: fileManager)
        let resolvedDocuments = documentsDirectory.resolvingSymlinksInPath()
        for sourcePath in sources.sorted() {
            let source = URL(fileURLWithPath: sourcePath)
            let prefix = resolvedDocuments.standardizedFileURL.path + "/"
            guard source.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relative = String(source.standardizedFileURL.path.dropFirst(prefix.count))
            let destination = backupDirectory.appending(path: relative)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                let sourceHash = SHA256.hash(data: try Data(contentsOf: source))
                let destinationHash = SHA256.hash(data: try Data(contentsOf: destination))
                guard sourceHash == destinationHash else {
                    throw LegacyImportError.photoBackupConflict(relativePath: relative)
                }
                continue
            }
            try fileManager.copyItem(at: source, to: destination)
            copied += 1
        }
        return copied
    }
}

private extension Canonical.JobPhoto {
    init(adoptedID: String, jobID: String, createdAt: String) {
        self.id = adoptedID
        self.jobId = jobID
        self.createdAt = createdAt
        self.uploadedAt = nil
        self.customerVisible = nil
        self.width = nil
        self.height = nil
        self.preservation = .init()
    }
}
