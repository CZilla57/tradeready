import Foundation

@main
struct RecordDeletionTests {
    static func main() throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let fixtureRoot = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
        let fixtureURL = URL(fileURLWithPath: fixtureRoot).appendingPathComponent("canonical-rich.json")
        let fixture = try JSONDecoder().decode(
            [String: Canonical.JSONValue].self,
            from: Data(contentsOf: fixtureURL)
        )
        func field<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONEncoder().encode(fixture[key]!))
        }

        let richJob: Canonical.Job = try field("job")
        var earlierJob = richJob
        earlierJob.id = "job-before"
        earlierJob.title = "Earlier job"
        let richInvoice: Canonical.Invoice = try field("invoice")
        let richCustomer: Canonical.Customer = try field("customer")
        let original = Canonical.Snapshot(
            payload: .init(
                invoices: [richInvoice],
                jobs: [earlierJob, richJob],
                customers: [richCustomer],
                unknownFields: ["futurePayload": .bool(true)]
            ),
            unknownFields: ["futureEnvelope": .string("retained")]
        )

        let deletedJob = try NativeRecordDeletion.deleteJob(
            snapshot: original,
            recordID: richJob.id,
            undoID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        expect(deletedJob.snapshot.payload.jobs?.map(\.id) == [earlierJob.id],
               "job deletion removes only the exact canonical ID")
        expect(deletedJob.snapshot.payload.invoices?.first?.id == richInvoice.id,
               "job deletion leaves other collections unchanged")
        expect(deletedJob.snapshot.payload.unknownFields["futurePayload"] == .bool(true)
               && deletedJob.snapshot.unknownFields["futureEnvelope"] == .string("retained"),
               "job deletion preserves unknown snapshot fields")
        expect(deletedJob.mutation.op == .delete
               && deletedJob.mutation.table == "jobs"
               && deletedJob.mutation.recordId == richJob.id,
               "job deletion plans one payload-free tombstone")

        let restoredJob = try NativeRecordDeletion.undo(
            snapshot: deletedJob.snapshot,
            token: deletedJob.undo
        )
        let restoredJobValue = restoredJob.snapshot.payload.jobs?[1]
        expect(restoredJobValue?.id == richJob.id,
               "job undo restores the original collection position")
        expect(restoredJobValue?.preservation.unknownFields == richJob.preservation.unknownFields,
               "job undo restores canonical unknown fields")
        expect(restoredJob.mutation.op == .upsert
               && restoredJob.mutation.payload == deletedJob.undo.preservedRecord,
               "job undo replaces the tombstone with the exact preserved payload")

        var conflictedJobSnapshot = deletedJob.snapshot
        var newerJob = richJob
        newerJob.title = "Newer recreation"
        conflictedJobSnapshot.payload.jobs?.append(newerJob)
        do {
            _ = try NativeRecordDeletion.undo(snapshot: conflictedJobSnapshot, token: deletedJob.undo)
            expect(false, "job undo must reject an ID recreated after deletion")
        } catch NativeRecordDeletionError.undoConflict {}

        let deletedInvoice = try NativeRecordDeletion.deleteInvoice(
            snapshot: original,
            recordID: richInvoice.id
        )
        expect(deletedInvoice.snapshot.payload.invoices?.isEmpty == true,
               "invoice deletion removes only the exact canonical ID")
        let restoredInvoice = try NativeRecordDeletion.undo(
            snapshot: deletedInvoice.snapshot,
            token: deletedInvoice.undo
        )
        let restoredInvoiceValue = restoredInvoice.snapshot.payload.invoices?.first
        expect(restoredInvoiceValue?.payments?.count == richInvoice.payments?.count,
               "invoice undo restores the complete payment ledger")
        expect(restoredInvoiceValue?.preservation.unknownFields == richInvoice.preservation.unknownFields,
               "invoice undo restores canonical unknown fields")
        expect(restoredInvoice.mutation.table == "invoices"
               && restoredInvoice.mutation.op == .upsert,
               "invoice undo plans a replacement upsert")

        let deletedCustomer = try NativeRecordDeletion.deleteCustomer(
            snapshot: original,
            recordID: richCustomer.id
        )
        expect(deletedCustomer.snapshot.payload.customers?.isEmpty == true,
               "customer deletion removes only the exact canonical customer")
        expect(deletedCustomer.snapshot.payload.jobs?.map(\.id) == [earlierJob.id, richJob.id]
               && deletedCustomer.snapshot.payload.invoices?.first?.id == richInvoice.id,
               "customer deletion leaves linked job and invoice history untouched")
        let restoredCustomer = try NativeRecordDeletion.undo(
            snapshot: deletedCustomer.snapshot,
            token: deletedCustomer.undo
        )
        let restoredCustomerValue = restoredCustomer.snapshot.payload.customers?.first
        expect(restoredCustomerValue?.preservation.unknownFields == richCustomer.preservation.unknownFields,
               "customer undo restores canonical unknown fields")
        expect(restoredCustomer.mutation.table == "customers"
               && restoredCustomer.mutation.payload == deletedCustomer.undo.preservedRecord,
               "customer undo plans the exact preserved upsert")

        do {
            _ = try NativeRecordDeletion.deleteJob(snapshot: original, recordID: "missing")
            expect(false, "missing job deletion must fail closed")
        } catch NativeRecordDeletionError.recordNotFound {}

        if failures == 0 { print("PASS: native record deletion and undo tests") }
        else { fatalError("\(failures) record deletion test(s) failed") }
    }
}
