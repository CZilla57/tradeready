import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private let invoice = NativeInvoiceOutreachInvoice(
    customer: "Jane", number: "INV-0042", description: "Work",
    total: 1000, balance: 1000, isPartlyPaid: false, daysPastDue: 5)
private let partly = NativeInvoiceOutreachInvoice(
    customer: "Jane", number: "INV-0042", description: "Work",
    total: 1000, balance: 600, isPartlyPaid: true, daysPastDue: -3)
private let business = NativeInvoiceOutreachBusiness(
    businessName: "Acme", contactName: "Amy", phone: "555-0100", paymentNotes: "Net 30.")

// Text channel mirrors the RN shape exactly.
let text = NativeInvoiceOutreach.message(
    invoice: invoice, channel: .text, business: business,
    paymentLink: "https://pay.test/abc", plan: nil, deposit: nil)
expect(text == "Hi Jane, this is Acme. Invoice INV-0042 — $1,000.00, 5 days overdue. Pay here: https://pay.test/abc — 555-0100",
       "text message shape")

// Partly-paid names BOTH numbers; future due reads "due in N days".
let textPartly = NativeInvoiceOutreach.message(
    invoice: partly, channel: .text, business: business,
    paymentLink: nil, plan: nil, deposit: nil)
expect(textPartly.contains("$600.00 of $1,000.00 still outstanding"), "partly-paid names both numbers")
expect(textPartly.contains("due in 3 days") && !textPartly.contains("Pay here"), "future due without link")

// Email channel: subject line, link section, plan, payment notes, sign-off.
let email = NativeInvoiceOutreach.message(
    invoice: invoice, channel: .email, business: business,
    paymentLink: "https://pay.test/abc",
    plan: NativeInvoiceOutreachPlan(installments: "3", frequency: "Bi-weekly"),
    deposit: NativeDepositAsk(amount: 500, percent: 50))
let (subject, body) = NativeInvoiceOutreach.splitEmailSubject(email, fallbackSubject: "Fallback")
expect(subject == "Payment reminder – INV-0042", "email subject splits")
expect(body.contains("Pay now → https://pay.test/abc"), "email carries the labeled link")
expect(body.contains("We're asking for a deposit of $500.00 (50% of the total) for now — the payment link below is for that amount."),
       "deposit clause pairs with the link")
expect(body.contains("We can also arrange 3 payments of $333.33 bi-weekly if that works better for you."),
       "plan clause with per-installment math")
expect(body.contains("Net 30.") && body.hasSuffix("555-0100"), "notes and sign-off close the email")

// Subject fallback when the template produced none.
let fallback = NativeInvoiceOutreach.splitEmailSubject("plain body", fallbackSubject: "Fallback")
expect(fallback.subject == "Fallback" && fallback.body == "plain body", "subject fallback")

// Due-today wording.
let today = NativeInvoiceOutreach.message(
    invoice: NativeInvoiceOutreachInvoice(
        customer: "Jane", number: "INV-1", description: "", total: 10, balance: 10,
        isPartlyPaid: false, daysPastDue: 0),
    channel: .text, business: business, paymentLink: nil, plan: nil, deposit: nil)
expect(today.contains("due today"), "due-today wording")

// Composer-outcome policy: only an explicit send supersedes automation.
expect(NativeInvoiceOutreach.resolution(for: .sent) == .recordSent, "sent records delivery")
expect(NativeInvoiceOutreach.resolution(for: .cancelled) == .keepDraft, "cancel keeps the draft")
expect(NativeInvoiceOutreach.resolution(for: .saved) == .keepDraftWithSavedNotice, "saved draft is explained, not claimed")
expect(NativeInvoiceOutreach.resolution(for: .failed) == .keepDraftWithFailureNotice, "failure keeps the draft for retry")
expect(NativeInvoiceOutreach.supersedesAutoRequest(.recordSent), "sent supersedes the pending auto request")
expect(!NativeInvoiceOutreach.supersedesAutoRequest(.keepDraft), "non-send never supersedes")

print(failures == 0 ? "PASS: native invoice outreach tests" : "FAILED: \(failures) native invoice outreach test(s)")
if failures != 0 { exit(1) }
