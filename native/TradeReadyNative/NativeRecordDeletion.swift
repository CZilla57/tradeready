import Foundation

enum NativeRecordDeletionKind: String, Equatable {
    case job
    case invoice
    case customer

    var table: String {
        switch self {
        case .job: "jobs"
        case .invoice: "invoices"
        case .customer: "customers"
        }
    }
}

enum NativeRecordDeletionError: Error, Equatable {
    case recordNotFound
    case undoConflict
    case invalidPreservedRecord
}

struct NativeRecordDeleteUndo: Identifiable {
    let id: UUID
    let kind: NativeRecordDeletionKind
    let recordID: String
    let displayName: String
    let originalIndex: Int
    let preservedRecord: Canonical.JSONValue

    var bannerMessage: String {
        switch kind {
        case .job: "Deleted job \(displayName)"
        case .invoice: "Deleted invoice \(displayName)"
        case .customer: "Deleted customer \(displayName)"
        }
    }
}

struct NativeRecordDeletionResult {
    let snapshot: Canonical.Snapshot
    let undo: NativeRecordDeleteUndo
    let mutation: Canonical.MutationDraft
}

/// Exact-record deletion and restoration at the canonical boundary. Undo
/// restores the preserved JSON value only while its ID is still absent, so a
/// newer pull or local recreation can never be overwritten by a stale token.
enum NativeRecordDeletion {
    static func deleteJob(
        snapshot: Canonical.Snapshot,
        recordID: String,
        undoID: UUID = UUID()
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard var records = updated.payload.jobs,
              let index = records.firstIndex(where: { $0.id == recordID })
        else { throw NativeRecordDeletionError.recordNotFound }
        let record = records.remove(at: index)
        let preserved = try encodedValue(record)
        updated.payload.jobs = records
        return .init(
            snapshot: updated,
            undo: .init(
                id: undoID,
                kind: .job,
                recordID: recordID,
                displayName: displayName(record.title, fallback: "Untitled job"),
                originalIndex: index,
                preservedRecord: preserved
            ),
            mutation: .init(table: "jobs", op: .delete, recordId: recordID, payload: nil)
        )
    }

    static func deleteInvoice(
        snapshot: Canonical.Snapshot,
        recordID: String,
        undoID: UUID = UUID()
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard var records = updated.payload.invoices,
              let index = records.firstIndex(where: { $0.id == recordID })
        else { throw NativeRecordDeletionError.recordNotFound }
        let record = records.remove(at: index)
        let preserved = try encodedValue(record)
        updated.payload.invoices = records
        return .init(
            snapshot: updated,
            undo: .init(
                id: undoID,
                kind: .invoice,
                recordID: recordID,
                displayName: displayName(record.number, fallback: "Untitled invoice"),
                originalIndex: index,
                preservedRecord: preserved
            ),
            mutation: .init(table: "invoices", op: .delete, recordId: recordID, payload: nil)
        )
    }

    static func deleteCustomer(
        snapshot: Canonical.Snapshot,
        recordID: String,
        undoID: UUID = UUID()
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard var records = updated.payload.customers,
              let index = records.firstIndex(where: { $0.id == recordID })
        else { throw NativeRecordDeletionError.recordNotFound }
        let record = records.remove(at: index)
        let preserved = try encodedValue(record)
        updated.payload.customers = records
        return .init(
            snapshot: updated,
            undo: .init(
                id: undoID,
                kind: .customer,
                recordID: recordID,
                displayName: displayName(record.name, fallback: "Unnamed customer"),
                originalIndex: index,
                preservedRecord: preserved
            ),
            mutation: .init(table: "customers", op: .delete, recordId: recordID, payload: nil)
        )
    }

    static func undo(
        snapshot: Canonical.Snapshot,
        token: NativeRecordDeleteUndo
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        switch token.kind {
        case .job:
            var records = updated.payload.jobs ?? []
            guard !records.contains(where: { $0.id == token.recordID })
            else { throw NativeRecordDeletionError.undoConflict }
            let restored: Canonical.Job = try decodedRecord(token)
            guard restored.id == token.recordID
            else { throw NativeRecordDeletionError.invalidPreservedRecord }
            records.insert(restored, at: min(token.originalIndex, records.count))
            updated.payload.jobs = records
        case .invoice:
            var records = updated.payload.invoices ?? []
            guard !records.contains(where: { $0.id == token.recordID })
            else { throw NativeRecordDeletionError.undoConflict }
            let restored: Canonical.Invoice = try decodedRecord(token)
            guard restored.id == token.recordID
            else { throw NativeRecordDeletionError.invalidPreservedRecord }
            records.insert(restored, at: min(token.originalIndex, records.count))
            updated.payload.invoices = records
        case .customer:
            var records = updated.payload.customers ?? []
            guard !records.contains(where: { $0.id == token.recordID })
            else { throw NativeRecordDeletionError.undoConflict }
            let restored: Canonical.Customer = try decodedRecord(token)
            guard restored.id == token.recordID
            else { throw NativeRecordDeletionError.invalidPreservedRecord }
            records.insert(restored, at: min(token.originalIndex, records.count))
            updated.payload.customers = records
        }
        return .init(
            snapshot: updated,
            undo: token,
            mutation: .init(
                table: token.kind.table,
                op: .upsert,
                recordId: token.recordID,
                payload: token.preservedRecord
            )
        )
    }

    private static func encodedValue<Record: Encodable>(_ record: Record) throws -> Canonical.JSONValue {
        try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(record))
    }

    private static func decodedRecord<Record: Codable>(_ token: NativeRecordDeleteUndo) throws -> Record {
        do {
            let record = try JSONDecoder().decode(
                Record.self,
                from: JSONEncoder().encode(token.preservedRecord)
            )
            let encoded = try encodedValue(record)
            guard encoded == token.preservedRecord else {
                throw NativeRecordDeletionError.invalidPreservedRecord
            }
            return record
        } catch let error as NativeRecordDeletionError {
            throw error
        } catch {
            throw NativeRecordDeletionError.invalidPreservedRecord
        }
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
