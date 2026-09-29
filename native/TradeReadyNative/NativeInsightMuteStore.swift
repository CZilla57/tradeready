import Foundation

enum NativeInsightMuteStoreError: Error, Equatable {
    case invalidAccountBinding
    case accountBindingMismatch
    case invalidRecord
    case unreadableStore
    case unsupportedSchema
}

/// Exact-owner-bound store for insight dismissals/snoozes (task 10.03, S4).
///
/// Mirrors `NativeReviewRequestStore`: one versioned document per verified
/// account binding, a last-known-good backup, atomic writes, and fail-closed
/// handling of an unreadable file, an unsupported schema, or a mismatched
/// binding. Mute ids embed this account's record ids, so the file never syncs and
/// is wiped at every account boundary.
///
/// Order is the array order (RN appends the newest mute last, and a re-mute
/// replaces in place) — `NativeInsightMutes` owns the policy; this type owns
/// durability.
struct NativeInsightMuteStore {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let accountBinding: String
        let mutes: [NativeInsightMute]
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }

    func load(for accountBinding: String) throws -> [NativeInsightMute] {
        try validateAccountBinding(accountBinding)
        if fileManager.fileExists(atPath: fileURL.path) {
            return try decode(Data(contentsOf: fileURL), accountBinding: accountBinding)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            return try decode(Data(contentsOf: backupURL), accountBinding: accountBinding)
        }
        return []
    }

    func save(_ mutes: [NativeInsightMute], for accountBinding: String) throws {
        try validateAccountBinding(accountBinding)
        let normalized = try normalize(mutes)

        if fileManager.fileExists(atPath: fileURL.path) {
            let current = try Data(contentsOf: fileURL)
            _ = try decode(current, accountBinding: accountBinding)
            try atomicWrite(current, to: backupURL)
        }

        let document = Document(
            schemaVersion: Document.currentSchemaVersion,
            accountBinding: accountBinding,
            mutes: normalized
        )
        try atomicWrite(try JSONEncoder().encode(document), to: fileURL)
    }

    /// Applies one mute through the policy and persists the result. Returns the
    /// stored array so callers can update their state optimistically.
    @discardableResult
    func applyMute(
        id: String,
        now: Date,
        days: Int? = nil,
        liveIDs: Set<String>? = nil,
        for accountBinding: String
    ) throws -> [NativeInsightMute] {
        let current = try load(for: accountBinding)
        let updated = NativeInsightMutes.applying(
            id: id, now: now, days: days, liveIDs: liveIDs, to: current
        )
        try save(updated, for: accountBinding)
        return updated
    }

    /// Adopts migration-seeded mutes once, under an already-verified binding.
    /// Existing owner records win per id (they carry live state); seeded records
    /// fill only ids this device has never muted.
    func mergeSeeded(
        _ seeded: [NativeInsightMute],
        for accountBinding: String
    ) throws -> [NativeInsightMute] {
        let stored = try load(for: accountBinding)
        let storedIDs = Set(stored.map(\.id))
        let fresh = try normalize(seeded).filter { !storedIDs.contains($0.id) }
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

    private func decode(_ data: Data, accountBinding: String) throws -> [NativeInsightMute] {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw NativeInsightMuteStoreError.unreadableStore }
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw NativeInsightMuteStoreError.unsupportedSchema
        }
        guard document.accountBinding == accountBinding else {
            throw NativeInsightMuteStoreError.accountBindingMismatch
        }
        return try normalize(document.mutes)
    }

    /// Shape validation. A duplicate id keeps the LAST occurrence (the newest
    /// write) rather than failing the read or silently dropping a snooze.
    private func normalize(_ mutes: [NativeInsightMute]) throws -> [NativeInsightMute] {
        var result: [NativeInsightMute] = []
        var indexByID: [String: Int] = [:]
        for mute in NativeInsightMutes.sanitized(mutes) {
            let id = mute.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.utf8.count <= 256,
                  mute.mutedAt.utf8.count <= 64,
                  (mute.until ?? "").utf8.count <= 64
            else { throw NativeInsightMuteStoreError.invalidRecord }
            var record = mute
            record.id = id
            if let existing = indexByID[id] {
                result[existing] = record
            } else {
                indexByID[id] = result.count
                result.append(record)
            }
        }
        return result
    }

    private func validateAccountBinding(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw NativeInsightMuteStoreError.invalidAccountBinding }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
