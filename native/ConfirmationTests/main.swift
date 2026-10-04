import Foundation

@main
struct ConfirmationTests {
    static func main() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let job = NativeConfirmationRequest.deleteJob(id: "j1", title: "  Repair sink  ")
        expect(job.intent == .deleteJob(recordID: "j1"),
               "job confirmation carries only the stable record ID")
        expect(job.title == "Delete job?" && job.message.contains("Repair sink"),
               "job confirmation has bounded destructive copy")
        expect(job.message.contains("undo for a few seconds"),
               "job confirmation describes the available short undo")
        expect(job.emphasis == .destructive,
               "job deletion is visually destructive")

        let invoice = NativeConfirmationRequest.deleteInvoice(
            id: "i1", number: "INV-0042", customer: "Acme"
        )
        expect(invoice.intent == .deleteInvoice(recordID: "i1"),
               "invoice confirmation carries only the stable record ID")
        expect(invoice.message.contains("payment history"),
               "invoice deletion warns about dependent payment history")
        expect(invoice.message.contains("undo for a few seconds"),
               "invoice confirmation describes the available short undo")

        let customer = NativeConfirmationRequest.deleteCustomer(id: "c1", name: "  Acme  ")
        expect(customer.intent == .deleteCustomer(recordID: "c1"),
               "customer confirmation carries only the stable record ID")
        expect(customer.message.contains("jobs and invoices will remain"),
               "customer deletion explains that linked history is retained")
        expect(customer.message.contains("undo for a few seconds")
               && customer.emphasis == .destructive,
               "customer confirmation describes short undo and destructive emphasis")

        let merge = NativeConfirmationRequest.mergeCustomer(
            loserID: "c-old",
            loserName: "Old Co",
            winnerID: "c-new",
            winnerName: "New Co",
            warnsAboutPortalLink: true
        )
        expect(merge.intent == .mergeCustomer(loserID: "c-old", winnerID: "c-new"),
               "merge confirmation carries both stable customer IDs")
        expect(merge.message.contains("portal link will stop working"),
               "merge confirmation retains the portal invalidation warning")
        expect(merge.message.contains("undo briefly"),
               "merge confirmation describes the existing conflict-safe undo")

        // Phase 20: a job form.
        let form = NativeConfirmationRequest.deleteForm(id: "fm1_a", title: "  Panel inspection ")
        expect(form.intent == .deleteForm(recordID: "fm1_a") && form.id == "delete-form:fm1_a",
               "form confirmation carries only the stable record ID")
        expect(form.title == "Delete form?" && form.message.contains("\"Panel inspection\"")
               && form.actionTitle == "Delete form",
               "form confirmation names the trimmed form title")
        expect(form.message.contains("photos stay in the job's Photos section"),
               "form deletion says its photos are kept")
        expect(form.message.contains("undo for a few seconds") && form.emphasis == .destructive,
               "form confirmation describes short undo and destructive emphasis")
        expect(NativeConfirmationRequest.deleteForm(id: "fm2_b", title: " ").message.contains("\"This form\""),
               "a blank form title uses neutral copy")

        let blank = NativeConfirmationRequest.deleteJob(id: "j2", title: " \n ")
        expect(blank.message.contains("This job"),
               "blank display fields use neutral confirmation copy")

        if failures == 0 { print("PASS: native shared confirmation tests") }
        else { fatalError("\(failures) shared confirmation test(s) failed") }
    }
}
