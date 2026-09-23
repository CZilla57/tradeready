import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private func decodeInvoice(_ json: String) -> Canonical.Invoice {
    try! JSONDecoder().decode(Canonical.Invoice.self, from: Data(json.utf8))
}

private let settings: Canonical.Settings = try! JSONDecoder().decode(Canonical.Settings.self, from: Data("""
{"businessName":"Acme Co","contactName":"Amy","phone":"555-0100","email":"amy@acme.test","address":"1 Main St","trade":"Plumbing","laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,"minimumJobFee":75,"travelFeePerMile":0,"emergencyMultiplier":1.5,"paymentNotes":"Net 30.","provider":"stripe","rules":[]}
""".utf8))

private let renderNow = Date(timeIntervalSince1970: 1_788_000_000) // 2026-08-27 UTC

// Issue date: timestamp IDs supply it, legacy IDs fall back to render date.
let stamped = NativeInvoicePDFDocument.issueDate(forInvoiceID: "inv1756000000000", now: renderNow)
expect(Calendar(identifier: .gregorian).component(.year, from: stamped) == 2025, "timestamp id recovers the issue date")
let legacy = NativeInvoicePDFDocument.issueDate(forInvoiceID: "1-seed", now: renderNow)
expect(legacy == renderNow, "legacy id falls back to the render date")
let implausible = NativeInvoicePDFDocument.issueDate(forInvoiceID: "inv42", now: renderNow)
expect(implausible == renderNow, "non-timestamp digits fall back to the render date")

// Status branches.
let unpaid = NativeInvoicePDFDocument(invoice: decodeInvoice("""
{"id":"inv1756000000000","customer":"Jane","number":"INV-1","amount":1000,"due":"2026-09-01","email":"","phone":"","desc":"Work","paid":false}
"""), settings: settings, now: renderNow)
expect(unpaid.status == .outstanding && unpaid.balance == 1000 && unpaid.paidToDate == 0, "unpaid totals and status")
expect(unpaid.issueDate == NativeInvoicePDFDocument.displayDate(stamped), "issue date renders from the id")
expect(unpaid.due == "Sep 1, 2026", "due date renders in local calendar terms")
expect(unpaid.paymentTerms == "Net 30.", "payment terms ride the document")
expect(unpaid.tableDescription == "Work", "description without lines shows the description")

let partial = NativeInvoicePDFDocument(invoice: decodeInvoice("""
{"id":"inv1756000000000","customer":"Jane","number":"INV-1","amount":1000,"due":"2026-09-01","email":"","phone":"","desc":"Work","paid":false,"payments":[{"id":"p1","amount":400,"date":"2026-08-01","method":"cash"}]}
"""), settings: settings, now: renderNow)
expect(partial.status == .partlyPaid && partial.balance == 600 && partial.paidToDate == 400, "partial totals and status")
expect(partial.history == [NativeInvoicePDFPayment(date: "2026-08-01", methodLabel: "Cash", amount: 400)], "history shows customer-visible payments")

let paid = NativeInvoicePDFDocument(invoice: decodeInvoice("""
{"id":"inv1756000000000","customer":"Jane","number":"INV-1","amount":1000,"due":"2026-09-01","email":"","phone":"","desc":"","paid":true,"payments":[{"id":"p1","amount":400,"date":"2026-08-01","method":"card"},{"id":"p2","amount":600,"date":"2026-08-02","method":"stripe"}]}
"""), settings: settings, now: renderNow)
expect(paid.status == .paid && paid.balance == 0, "paid status and zero balance")
expect(paid.tableDescription == "Services rendered", "blank description without lines falls back")

// History excludes voided and synthetic legacy entries; methods map to labels.
let history = NativeInvoicePDFDocument(invoice: decodeInvoice("""
{"id":"inv1756000000000","customer":"Jane","number":"INV-1","amount":1000,"due":"2026-09-01","email":"","phone":"","desc":"","paid":false,"payments":[{"id":"legacy_inv1756000000000","amount":1000,"date":"2026-08-01","method":"other"},{"id":"p1","amount":100,"date":"2026-08-02","method":"check","voidedAt":"2026-08-03"},{"id":"p2","amount":50,"date":"2026-08-04","method":"bank_transfer"}]}
"""), settings: settings, now: renderNow)
expect(history.history == [NativeInvoicePDFPayment(date: "2026-08-04", methodLabel: "bank_transfer", amount: 50)], "voided and legacy entries stay internal")
expect(NativeInvoicePDFDocument.methodLabel("check") == "Cheque", "cheque label")
expect(NativeInvoicePDFDocument.methodLabel("stripe") == "Card", "stripe maps to card")

// Line-item grouping: labor first, everything else additional.
let grouped = NativeInvoicePDFDocument(invoice: decodeInvoice("""
{"id":"inv1756000000000","customer":"Jane","number":"INV-1","amount":1000,"due":"2026-09-01","email":"","phone":"","desc":"","paid":false,"lineItems":[{"description":"Labor","amount":600,"category":"labor"},{"description":"Parts","amount":300,"category":"materials"},{"description":"Trip","amount":100,"category":"other"}]}
"""), settings: settings, now: renderNow)
expect(grouped.primaryLineItems.map(\.label) == ["Labor"], "labor grouping")
expect(grouped.additionalLineItems.map(\.label) == ["Parts", "Trip"], "additional-charges grouping")

print(failures == 0 ? "PASS: native invoice pdf tests" : "FAILED: \(failures) native invoice pdf test(s)")
if failures != 0 { exit(1) }
