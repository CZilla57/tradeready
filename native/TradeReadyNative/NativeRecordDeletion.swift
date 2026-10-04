import Foundation

enum NativeRecordDeletionKind: String, Equatable {
    case job
    case invoice
    case customer
    /// Phase 20: a form instance or custom template (`forms`).
    case form
    /// Phase 21: a non-primary property, nested in its customer.
    case property
    /// Phase 21: one piece of equipment, nested in its customer's property.
    case equipment

    var table: String {
        switch self {
        case .job: "jobs"
        case .invoice: "invoices"
        case .customer, .property, .equipment: "customers"
        case .form: "forms"
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
    /// Phase 21 nested kinds: the customer that holds the item, and for
    /// equipment the property. `recordID` is the item's own id.
    var customerID: String?
    var propertyID: String?

    var bannerMessage: String {
        switch kind {
        case .job: "Deleted job \(displayName)"
        case .invoice: "Deleted invoice \(displayName)"
        case .customer: "Deleted customer \(displayName)"
        case .form: "Deleted form \(displayName)"
        case .property: "Deleted property \(displayName)"
        case .equipment: "Deleted equipment \(displayName)"
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

    /// Phase 20: removes one `forms` row (an instance or a custom template).
    /// Photos captured from it stay in the job's Photos section.
    static func deleteForm(
        snapshot: Canonical.Snapshot,
        recordID: String,
        undoID: UUID = UUID()
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard var records = updated.payload.forms,
              let index = records.firstIndex(where: { $0.id == recordID })
        else { throw NativeRecordDeletionError.recordNotFound }
        let record = records.remove(at: index)
        let preserved = try encodedValue(record)
        updated.payload.forms = records
        return .init(
            snapshot: updated,
            undo: .init(
                id: undoID,
                kind: .form,
                recordID: recordID,
                displayName: displayName(record.title, fallback: "Untitled form"),
                originalIndex: index,
                preservedRecord: preserved
            ),
            mutation: .init(table: "forms", op: .delete, recordId: recordID, payload: nil)
        )
    }

    /// Phase 21: removes one non-primary property from its customer. The
    /// customer is upserted (properties are nested, D1); jobs that point at
    /// the property keep their id, which no longer resolves (P3).
    static func deleteProperty(
        snapshot: Canonical.Snapshot,
        customerID: String,
        propertyID: String,
        primaryID: String,
        undoID: UUID = UUID()
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard var customers = updated.payload.customers,
              let customerIndex = customers.firstIndex(where: { $0.id == customerID })
        else { throw NativeRecordDeletionError.recordNotFound }
        let removal: (customer: Canonical.Customer, removed: Canonical.Property, index: Int)
        do {
            removal = try NativePropertiesEquipment.removeProperty(
                from: customers[customerIndex], propertyID: propertyID, primaryID: primaryID
            )
        } catch NativePropertiesEquipment.PropertyError.propertyNotFound {
            throw NativeRecordDeletionError.recordNotFound
        }
        customers[customerIndex] = removal.customer
        updated.payload.customers = customers
        let name = removal.removed.label ?? removal.removed.address ?? ""
        return .init(
            snapshot: updated,
            undo: .init(
                id: undoID,
                kind: .property,
                recordID: propertyID,
                displayName: displayName(name, fallback: "Property"),
                originalIndex: removal.index,
                preservedRecord: try encodedValue(removal.removed),
                customerID: customerID
            ),
            mutation: .init(table: "customers", op: .upsert, recordId: customerID, payload: try encodedValue(removal.customer))
        )
    }

    /// Phase 21: removes one piece of equipment (an entry made by mistake;
    /// removed or replaced equipment is archived instead).
    static func deleteEquipment(
        snapshot: Canonical.Snapshot,
        customerID: String,
        propertyID: String,
        equipmentID: String,
        primaryID: String,
        undoID: UUID = UUID()
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard var customers = updated.payload.customers,
              let customerIndex = customers.firstIndex(where: { $0.id == customerID })
        else { throw NativeRecordDeletionError.recordNotFound }
        let removal: (customer: Canonical.Customer, removed: Canonical.Equipment, index: Int)
        do {
            removal = try NativePropertiesEquipment.removeEquipment(
                from: customers[customerIndex], propertyID: propertyID, equipmentID: equipmentID, primaryID: primaryID
            )
        } catch NativePropertiesEquipment.PropertyError.equipmentNotFound {
            throw NativeRecordDeletionError.recordNotFound
        }
        let holder = removal.customer.properties?.first {
            $0.id == propertyID || (propertyID == NativePropertiesEquipment.implicitPrimaryID && $0.primary == true)
        }
        customers[customerIndex] = removal.customer
        updated.payload.customers = customers
        return .init(
            snapshot: updated,
            undo: .init(
                id: undoID,
                kind: .equipment,
                recordID: equipmentID,
                displayName: displayName(NativePropertiesEquipment.typeDisplayName(removal.removed.type), fallback: "Equipment"),
                originalIndex: removal.index,
                preservedRecord: try encodedValue(removal.removed),
                customerID: customerID,
                propertyID: holder?.id ?? propertyID
            ),
            mutation: .init(table: "customers", op: .upsert, recordId: customerID, payload: try encodedValue(removal.customer))
        )
    }

    static func undo(
        snapshot: Canonical.Snapshot,
        token: NativeRecordDeleteUndo
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        switch token.kind {
        case .property, .equipment:
            return try undoNested(snapshot: snapshot, token: token)
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
        case .form:
            var records = updated.payload.forms ?? []
            guard !records.contains(where: { $0.id == token.recordID })
            else { throw NativeRecordDeletionError.undoConflict }
            let restored: Canonical.Form = try decodedRecord(token)
            guard restored.id == token.recordID
            else { throw NativeRecordDeletionError.invalidPreservedRecord }
            records.insert(restored, at: min(token.originalIndex, records.count))
            updated.payload.forms = records
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

    /// Re-inserts a deleted property or equipment item into its customer's
    /// current record, only while its id is still absent (a recreated item is
    /// never overwritten) and its customer (and property) are still there.
    private static func undoNested(
        snapshot: Canonical.Snapshot,
        token: NativeRecordDeleteUndo
    ) throws -> NativeRecordDeletionResult {
        var updated = snapshot
        guard let customerID = token.customerID,
              var customers = updated.payload.customers,
              let customerIndex = customers.firstIndex(where: { $0.id == customerID }),
              var list = customers[customerIndex].properties
        else { throw NativeRecordDeletionError.recordNotFound }
        guard !NativePropertiesEquipment.allIDs(in: customers[customerIndex]).contains(token.recordID)
        else { throw NativeRecordDeletionError.undoConflict }
        switch token.kind {
        case .property:
            let restored: Canonical.Property = try decodedRecord(token)
            guard restored.id == token.recordID, restored.primary != true
            else { throw NativeRecordDeletionError.invalidPreservedRecord }
            list.insert(restored, at: min(max(token.originalIndex, 1), list.count))
        case .equipment:
            let restored: Canonical.Equipment = try decodedRecord(token)
            guard restored.id == token.recordID,
                  let propertyIndex = list.firstIndex(where: { $0.id == token.propertyID })
            else { throw NativeRecordDeletionError.invalidPreservedRecord }
            var items = list[propertyIndex].equipment ?? []
            items.insert(restored, at: min(token.originalIndex, items.count))
            list[propertyIndex].equipment = items
        default:
            throw NativeRecordDeletionError.invalidPreservedRecord
        }
        customers[customerIndex].properties = list
        updated.payload.customers = customers
        return .init(
            snapshot: updated,
            undo: token,
            mutation: .init(
                table: "customers",
                op: .upsert,
                recordId: customerID,
                payload: try encodedValue(customers[customerIndex])
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
