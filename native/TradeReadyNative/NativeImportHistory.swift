import Foundation

// MARK: - Device-local import history (task 9.07, requirement I2)
//
// Port of `utils/importHistory.ts`. Deliberately NOT synced: this is per-device
// operational metadata (the same-file re-import warning and the report history),
// not business data. Persistence is a single JSON file written atomically, and a
// corrupt/unreadable file degrades to "no history" rather than failing a save.

struct NativeImportBatchRecord: Codable, Equatable {
    var batchId: String
    var entity: String
    var fileHash: String
    var date: String
    var counts: NativeImportCountsCodable
}

/// Codable mirror of `NativeImportCounts`.
struct NativeImportCountsCodable: Codable, Equatable {
    var ok: Int
    var skip: Int
    var flag: Int
    var created: Int
    var matched: Int

    init(_ counts: NativeImportCounts) {
        ok = counts.ok; skip = counts.skip; flag = counts.flag
        created = counts.created; matched = counts.matched
    }

    var counts: NativeImportCounts {
        NativeImportCounts(ok: ok, skip: skip, flag: flag, created: created, matched: matched)
    }
}

enum NativeImportHistory {
    /// The AsyncStorage key the React Native build used, kept as the on-disk
    /// filename so the store's identity is unambiguous in support exports.
    static let storageKey = "tr_import_history_v1"

    /// Batch ids are `imp_<ms>_<counter>`: monotonic within a run so two imports
    /// in the same millisecond cannot collide.
    static func newBatchID(nowMs: Int64, counter: Int) -> String {
        "imp_\(nowMs)_\(counter)"
    }

    /// Crash-safe read: a missing or unreadable file means "no history".
    static func load(from directory: URL) -> [NativeImportBatchRecord] {
        let url = directory.appendingPathComponent(storageKey)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([NativeImportBatchRecord].self, from: data)) ?? []
    }

    /// Prepend the new batch and persist atomically (temp file + replace), so a
    /// crash mid-write cannot leave a truncated history file.
    @discardableResult
    static func record(_ record: NativeImportBatchRecord, in directory: URL) -> Bool {
        let history = load(from: directory)
        return write([record] + history, to: directory)
    }

    static func findBatch(entity: String, fileHash: String, in directory: URL) -> NativeImportBatchRecord? {
        load(from: directory).first { $0.entity == entity && $0.fileHash == fileHash }
    }

    /// Undo bookkeeping: forget one batch (it is no longer undoable).
    @discardableResult
    static func remove(batchID: String, in directory: URL) -> Bool {
        write(load(from: directory).filter { $0.batchId != batchID }, to: directory)
    }

    private static func write(_ history: [NativeImportBatchRecord], to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(history)
            let target = directory.appendingPathComponent(storageKey)
            let temporary = directory.appendingPathComponent("\(storageKey).tmp-\(UUID().uuidString)")
            try data.write(to: temporary, options: .atomic)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            return true
        } catch {
            return false
        }
    }
}
