import Foundation
import CryptoKit

// Phase 12 (12.00b.1, known issue I2, contract §17.2): the changes the server
// refused. A non-auth 4xx (`NativeMutationPushClassification`) takes a change
// off the live queue and files it here, so it can no longer hold back every
// other change. Settings › Cloud Sync lists these entries (owner decision D3):
// Retry sends one back through the normal queue, and Discard shows the
// server's version.
//
// Each entry holds the queued change itself, so the file is local customer
// data. It is:
// - app-private, next to the queue, and written with after-first-unlock file
//   protection, like the live mutation queue and the canonical snapshot that
//   hold the same payloads (review prep R15). The `.complete` class would add
//   no confidentiality over those files and would stop background sync while
//   the device is locked;
// - owner-scoped: the document carries a one-way tag of the verified owner's
//   binding, and another owner (or no owner) reads nothing. Every account
//   boundary also removes it (`AppStore.scrubRejectedChangesForAccountBoundary`
//   and the full account scrub);
// - bounded: at most `capacity` entries, the newest kept, the overflow counted
//   for the diagnostic;
// - never logged and never reported. Diagnostics carry the table, the status
//   and a count only.

/// One change the server refused.
struct NativeRejectedChange: Codable, Equatable, Identifiable {
    /// The change exactly as it was queued (Retry sends it again).
    var item: Canonical.MutationItem
    /// The HTTP status the server refused it with.
    var statusCode: Int
    /// When this device filed it.
    var rejectedAt: Date

    /// The queue's record key, `<table>/<recordId>`. At most one entry per key.
    var key: String { Self.key(item) }
    var id: String { key }

    static func key(_ item: Canonical.MutationItem) -> String { "\(item.table)/\(item.recordId)" }
}

enum NativeRejectedChangeStoreError: Error, Equatable {
    /// The file exists but could not be read, for example before the first
    /// unlock after a restart, or an I/O error. It is not treated as empty.
    case unreadable
    /// There is no verified owner to file the change under.
    case noOwner
}

/// The file operations the store needs, so a host test can fail them.
protocol NativeRejectedChangeFileBacking {
    /// The bytes, or nil when there is no file.
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
    /// Removes the file. No file is not an error.
    func remove(_ url: URL) throws
}

/// The app's backing: after-first-unlock file protection
/// (`completeFileProtectionUntilFirstUserAuthentication`), so a background
/// sync can read and write it while the device is locked. Before the first
/// unlock after a restart it can be neither read nor written; the store then
/// throws and the caller keeps the change queued (fail closed).
struct NativeProtectedRejectedChangeFiles: NativeRejectedChangeFileBacking {
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: Self.writeOptions)
    }

    func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The owner-scoped, bounded file of refused changes. Callers serialize
/// access (AppStore's main actor, like the mutation queue).
struct NativeRejectedChangeStore {
    /// The most entries kept. On overflow the oldest are dropped and counted.
    static let capacity = 100
    static let ownerTagPrefix = "tradeready.rejected-changes.owner.v1:"
    static let schemaVersion = 1

    let fileURL: URL
    private let files: any NativeRejectedChangeFileBacking

    init(
        fileURL: URL,
        files: any NativeRejectedChangeFileBacking = NativeProtectedRejectedChangeFiles()
    ) {
        self.fileURL = fileURL
        self.files = files
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var ownerTag: String
        var entries: [NativeRejectedChange]
    }

    /// A one-way tag of the owner's binding (the pattern of
    /// `NativeAIProviderKeyOwnerTag`): the file never holds the binding.
    static func ownerTag(binding: String) -> String {
        SHA256.hash(data: Data((ownerTagPrefix + binding).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The owner's entries, oldest first. No owner, no file, another owner's
    /// file, or a file that does not decode (corrupt, unknown schema) reads as
    /// empty: a damaged file must never wedge sync the way the poison change
    /// did, and the next settle replaces it. A file that cannot be read throws
    /// `unreadable`.
    func load(binding: String?) throws -> [NativeRejectedChange] {
        guard let binding, !binding.isEmpty else { return [] }
        return try document(binding: binding) ?? []
    }

    /// Files the refused changes (a later refusal of the same record replaces
    /// its entry and becomes the newest) and clears the entries of records
    /// whose newer change the server accepted. Returns how many of the oldest
    /// entries were dropped to stay within `capacity`. Throws before changing
    /// anything when there is no owner or the file cannot be read or written.
    @discardableResult
    func settle(
        rejected: [NativeMutationRejection],
        clearedKeys: Set<String>,
        binding: String?,
        now: Date
    ) throws -> Int {
        guard let binding, !binding.isEmpty else { throw NativeRejectedChangeStoreError.noOwner }
        var entries = try document(binding: binding) ?? []
        let before = entries
        entries.removeAll { clearedKeys.contains($0.key) }
        for rejection in rejected {
            let entry = NativeRejectedChange(item: rejection.item, statusCode: rejection.statusCode, rejectedAt: now)
            entries.removeAll { $0.key == entry.key }
            entries.append(entry)
        }
        // The overflow counts every entry pushed out, including ones this
        // settle filed itself (a flood larger than the cap).
        let dropped = max(0, entries.count - Self.capacity)
        if dropped > 0 { entries.removeFirst(dropped) }
        guard entries != before else { return dropped }
        try save(entries, binding: binding)
        return dropped
    }

    /// Removes one entry (Discard, or a Retry the server then accepted).
    func remove(key: String, binding: String?) throws {
        guard let binding, !binding.isEmpty else { throw NativeRejectedChangeStoreError.noOwner }
        var entries = try document(binding: binding) ?? []
        let count = entries.count
        entries.removeAll { $0.key == key }
        guard entries.count != count else { return }
        try save(entries, binding: binding)
    }

    /// Removes the file (every account boundary). Idempotent.
    func removeAll() throws {
        try files.remove(fileURL)
    }

    private func document(binding: String) throws -> [NativeRejectedChange]? {
        let data: Data?
        do { data = try files.read(fileURL) } catch { throw NativeRejectedChangeStoreError.unreadable }
        guard let data, !data.isEmpty,
              let document = try? Self.decoder.decode(Document.self, from: data),
              document.schemaVersion == Self.schemaVersion,
              document.ownerTag == Self.ownerTag(binding: binding)
        else { return nil }
        return document.entries
    }

    private func save(_ entries: [NativeRejectedChange], binding: String) throws {
        guard !entries.isEmpty else {
            try files.remove(fileURL)
            return
        }
        let document = Document(
            schemaVersion: Self.schemaVersion,
            ownerTag: Self.ownerTag(binding: binding),
            entries: entries
        )
        try files.write(try Self.encoder.encode(document), to: fileURL)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// What the Cloud Sync list shows for an entry: the record type and the
/// record's display name, read from the change itself. Shown on screen only.
enum NativeRejectedChangeDisplay {
    static func typeLabel(table: String) -> String {
        switch table {
        case "jobs": "Job"
        case "invoices": "Invoice"
        case "customers": "Customer"
        case "expenses": "Expense"
        case "pricebook": "Price book item"
        case "recurringJobs": "Recurring job"
        case "recurringInvoices": "Recurring invoice"
        case "trips": "Trip"
        case "bookingRequests": "Booking request"
        case "jobPhotos": "Job photo"
        case "settings": "Business settings"
        case "customer_notes": "Customer note"
        default: "Record"
        }
    }

    /// The record's display name from a queued payload, or nil when it has
    /// none (a delete, a photo, a note, settings).
    static func name(table: String, payload: Canonical.JSONValue?) -> String? {
        guard case let .object(fields)? = payload else { return nil }
        let candidates: [String]
        switch table {
        case "jobs", "recurringJobs": candidates = ["title", "customerName"]
        case "invoices": candidates = ["number", "customer"]
        case "customers", "pricebook", "bookingRequests": candidates = ["name"]
        case "expenses": candidates = ["description"]
        case "recurringInvoices": candidates = ["customerName", "description"]
        case "trips": candidates = ["purpose", "toLabel"]
        default: candidates = []
        }
        for field in candidates {
            if case let .string(value)? = fields[field] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
