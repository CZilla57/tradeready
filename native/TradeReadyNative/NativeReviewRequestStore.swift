import Foundation

enum NativeReviewRequestStoreError: Error, Equatable {
    case invalidAccountBinding
    case accountBindingMismatch
    case invalidRecord
    case unreadableStore
    case unsupportedSchema
}

/// Exact-owner-bound mutable repository for review-request records.
///
/// Durable local state holding per-job one-shot records (including customer
/// name/phone/email snapshots), so it must never survive sign-out or leak
/// across accounts. This is deliberately separate from
/// `NativeTypedAccountState`, which is migration-only read truth staged after
/// live identity verification: on activation the migrated `review_requests`
/// seed this store once (existing owner records win), and every subsequent
/// read/write goes through this store under the verified account binding.
///
/// Records never sync: they stay on-device like the RN `review_requests`
/// AsyncStorage ledger, and the notification sweep re-derives pending nudges
/// from them.
struct NativeReviewRequestStore {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let accountBinding: String
        let records: [NativeReviewRequestRecord]
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }

    func load(for accountBinding: String) throws -> [NativeReviewRequestRecord] {
        try validateAccountBinding(accountBinding)
        if fileManager.fileExists(atPath: fileURL.path) {
            return try decode(Data(contentsOf: fileURL), accountBinding: accountBinding)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            return try decode(Data(contentsOf: backupURL), accountBinding: accountBinding)
        }
        return []
    }

    func save(_ records: [NativeReviewRequestRecord], for accountBinding: String) throws {
        try validateAccountBinding(accountBinding)
        let normalized = try normalize(records)

        if fileManager.fileExists(atPath: fileURL.path) {
            let current = try Data(contentsOf: fileURL)
            _ = try decode(current, accountBinding: accountBinding)
            try atomicWrite(current, to: backupURL)
        }

        let document = Document(
            schemaVersion: Document.currentSchemaVersion,
            accountBinding: accountBinding,
            records: normalized
        )
        try atomicWrite(try JSONEncoder().encode(document), to: fileURL)
    }

    /// Merges migration-seeded records under an already-verified binding.
    /// Stored owner records win on `jobId` conflict (they carry live `sentAt`
    /// state); seeded records fill only genuinely new jobs.
    func mergeSeeded(_ seeded: [NativeReviewRequestRecord], for accountBinding: String) throws -> [NativeReviewRequestRecord] {
        let stored = try load(for: accountBinding)
        let storedIds = Set(stored.map(\.jobId))
        let fresh = try normalize(seeded).filter { !storedIds.contains($0.jobId) }
        guard !fresh.isEmpty else { return stored }
        let merged = try normalize(stored + fresh)
        try save(merged, for: accountBinding)
        return merged
    }

    func removeAll() throws {
        for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func decode(_ data: Data, accountBinding: String) throws -> [NativeReviewRequestRecord] {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw NativeReviewRequestStoreError.unreadableStore }
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw NativeReviewRequestStoreError.unsupportedSchema
        }
        guard document.accountBinding == accountBinding else {
            throw NativeReviewRequestStoreError.accountBindingMismatch
        }
        return try normalize(document.records)
    }

    private func normalize(_ records: [NativeReviewRequestRecord]) throws -> [NativeReviewRequestRecord] {
        var seen = Set<String>()
        for record in records {
            let jobId = record.jobId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jobId.isEmpty,
                  jobId.utf8.count <= 256,
                  !seen.contains(jobId),
                  record.scheduledAt.utf8.count <= 64,
                  (record.sentAt ?? "").utf8.count <= 64,
                  record.customerId.utf8.count <= 256,
                  record.customerName.utf8.count <= 512,
                  record.customerPhone.utf8.count <= 256,
                  record.customerEmail.utf8.count <= 512
            else { throw NativeReviewRequestStoreError.invalidRecord }
            seen.insert(jobId)
        }
        return records.sorted { $0.jobId < $1.jobId }
    }

    private func validateAccountBinding(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw NativeReviewRequestStoreError.invalidAccountBinding }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
