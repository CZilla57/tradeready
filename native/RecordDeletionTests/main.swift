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

        // Phase 20: a form (instance or template) deletes and restores exactly,
        // and deleting a job never touches its forms (no cascade).
        let richForm: Canonical.Form = try field("form")
        let richTemplate: Canonical.Form = try field("formTemplate")
        var withForms = original
        withForms.payload.forms = [richTemplate, richForm]
        let deletedForm = try NativeRecordDeletion.deleteForm(snapshot: withForms, recordID: richForm.id)
        expect(deletedForm.snapshot.payload.forms?.map(\.id) == [richTemplate.id],
               "form deletion removes only the exact form")
        expect(deletedForm.mutation.table == "forms" && deletedForm.mutation.op == .delete
               && deletedForm.mutation.recordId == richForm.id && deletedForm.mutation.payload == nil,
               "form deletion plans one forms tombstone")
        expect(deletedForm.undo.kind == .form && deletedForm.undo.bannerMessage == "Deleted form Electrical safety inspection",
               "form deletion offers the shared undo with the form title")
        let restoredForm = try NativeRecordDeletion.undo(snapshot: deletedForm.snapshot, token: deletedForm.undo)
        expect(restoredForm.snapshot.payload.forms == withForms.payload.forms,
               "form undo restores the exact form, answers and unknown keys, in place")
        expect(restoredForm.mutation.table == "forms" && restoredForm.mutation.op == .upsert
               && restoredForm.mutation.payload == deletedForm.undo.preservedRecord,
               "form undo plans the exact preserved forms upsert")
        var recreatedForm = deletedForm.snapshot
        recreatedForm.payload.forms?.append(richForm)
        do {
            _ = try NativeRecordDeletion.undo(snapshot: recreatedForm, token: deletedForm.undo)
            expect(false, "form undo must reject a form recreated after deletion")
        } catch NativeRecordDeletionError.undoConflict {}
        let jobWithForms = try NativeRecordDeletion.deleteJob(snapshot: withForms, recordID: richJob.id)
        expect(jobWithForms.snapshot.payload.forms == withForms.payload.forms,
               "deleting a job leaves its forms stored (hidden, no cascade)")
        var untitled = richForm
        untitled.title = "  "
        var untitledSnapshot = original
        untitledSnapshot.payload.forms = [untitled]
        let untitledDeletion = try NativeRecordDeletion.deleteForm(snapshot: untitledSnapshot, recordID: untitled.id)
        expect(untitledDeletion.undo.displayName == "Untitled form", "a blank form title falls back")
        do {
            _ = try NativeRecordDeletion.deleteForm(snapshot: original, recordID: richForm.id)
            expect(false, "deleting a form from a snapshot without forms must fail closed")
        } catch NativeRecordDeletionError.recordNotFound {}

        // Phase 21: nested property and equipment deletes upsert the
        // customer and share the same undo, exact and in place.
        guard let richCustomer = original.payload.customers?.first(where: { $0.properties != nil }),
              let rental = richCustomer.properties?.first(where: { $0.primary != true }),
              let furnace = richCustomer.properties?.first?.equipment?.first
        else { fatalError("the rich fixture customer carries properties and equipment") }
        let deletedEquipment = try NativeRecordDeletion.deleteEquipment(
            snapshot: original, customerID: richCustomer.id, propertyID: NativePropertiesEquipment.implicitPrimaryID,
            equipmentID: furnace.id, primaryID: "pr_unused"
        )
        expect(deletedEquipment.mutation.table == "customers" && deletedEquipment.mutation.op == .upsert
               && deletedEquipment.mutation.recordId == richCustomer.id,
               "an equipment delete plans one customer upsert, never a tombstone")
        expect(deletedEquipment.undo.kind == .equipment && deletedEquipment.undo.bannerMessage == "Deleted equipment Furnace"
               && deletedEquipment.undo.propertyID == richCustomer.properties?.first?.id,
               "an equipment delete offers the shared undo, naming the type and the stored property")
        let sortedEncoder = JSONEncoder()
        sortedEncoder.outputFormatting = .sortedKeys
        let originalCustomers = try sortedEncoder.encode(original.payload.customers)
        let restoredEquipment = try NativeRecordDeletion.undo(snapshot: deletedEquipment.snapshot, token: deletedEquipment.undo)
        let restoredEquipmentCustomers = try sortedEncoder.encode(restoredEquipment.snapshot.payload.customers)
        expect(restoredEquipmentCustomers == originalCustomers,
               "equipment undo restores the item, its unknown keys and its place")
        let deletedProperty = try NativeRecordDeletion.deleteProperty(
            snapshot: original, customerID: richCustomer.id, propertyID: rental.id, primaryID: "pr_unused"
        )
        expect(deletedProperty.undo.kind == .property && deletedProperty.undo.bannerMessage == "Deleted property Rental on Elm",
               "a property delete offers the shared undo with its name")
        let restoredProperty = try NativeRecordDeletion.undo(snapshot: deletedProperty.snapshot, token: deletedProperty.undo)
        let restoredPropertyCustomers = try sortedEncoder.encode(restoredProperty.snapshot.payload.customers)
        expect(restoredPropertyCustomers == originalCustomers, "property undo restores it exactly")
        expect(NativeRecordDeletionKind.property.table == "customers" && NativeRecordDeletionKind.equipment.table == "customers",
               "nested kinds belong to the customers table")
        // Phase 33: a campaign deletes and restores exactly (recipients and
        // unknown keys included); jobs it booked keep their campaignId.
        let richCampaign: Canonical.Campaign = try field("campaign")
        var withCampaign = original
        withCampaign.payload.campaigns = [richCampaign]
        let deletedCampaign = try NativeRecordDeletion.deleteCampaign(snapshot: withCampaign, recordID: richCampaign.id)
        expect(deletedCampaign.snapshot.payload.campaigns == [], "campaign deletion removes the campaign")
        expect(deletedCampaign.mutation.table == "campaigns" && deletedCampaign.mutation.op == .delete
               && deletedCampaign.mutation.recordId == richCampaign.id && deletedCampaign.mutation.payload == nil,
               "campaign deletion plans one campaigns tombstone")
        expect(deletedCampaign.undo.kind == .campaign && deletedCampaign.undo.bannerMessage == "Deleted campaign Fall furnace tune-up",
               "campaign deletion offers the shared undo with the campaign name")
        expect(deletedCampaign.snapshot.payload.jobs?.map(\.id) == withCampaign.payload.jobs?.map(\.id),
               "campaign deletion leaves jobs untouched")
        let restoredCampaign = try NativeRecordDeletion.undo(snapshot: deletedCampaign.snapshot, token: deletedCampaign.undo)
        expect(restoredCampaign.snapshot.payload.campaigns == withCampaign.payload.campaigns,
               "campaign undo restores the exact campaign")
        expect(restoredCampaign.mutation.table == "campaigns" && restoredCampaign.mutation.op == .upsert
               && restoredCampaign.mutation.payload == deletedCampaign.undo.preservedRecord,
               "campaign undo plans the exact preserved upsert")
        do {
            _ = try NativeRecordDeletion.deleteCampaign(snapshot: original, recordID: richCampaign.id)
            expect(false, "deleting a missing campaign must fail closed")
        } catch NativeRecordDeletionError.recordNotFound {}

        if failures == 0 { print("PASS: native record deletion and undo tests") }
        else { fatalError("\(failures) record deletion test(s) failed") }
    }
}
