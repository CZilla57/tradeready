import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func draft(
    customer: String = "  Mesa Bakery ",
    number: String = " INV-0042 ",
    amount: Double = 1500,
    due: String = "2026-10-15",
    email: String = "  jane@example.com ",
    phone: String = " (555) 123-4567 ",
    description: String = " Phase 2 "
) -> NativeInvoiceDraft {
    .init(customer: customer, customerId: "c1", number: number, amount: amount, due: due, email: email, phone: phone, description: description)
}

// Normalization trims without mutating amount.
let norm = NativeInvoiceEditing.normalized(draft())
expect(norm.customer == "Mesa Bakery", "customer trimmed")
expect(norm.number == "INV-0042", "number trimmed")
expect(norm.email == "jane@example.com", "email trimmed")
expect(norm.amount == 1500, "amount untouched")

// Validation mirrors AddInvoiceScreen guards; invalid never dismisses (value, not throw).
expect(NativeInvoiceEditing.validationReasons(draft(customer: "   ")) == [.missingCustomer], "blank customer refused")
expect(NativeInvoiceEditing.validationReasons(draft(amount: 0)) == [.invalidAmount], "zero amount refused")
expect(NativeInvoiceEditing.validationReasons(draft(amount: .nan)) == [.invalidAmount], "NaN amount refused")
expect(NativeInvoiceEditing.validationReasons(draft()) == [], "valid draft passes")

// Commit: blank number resolves via injected generator; explicit number kept.
switch NativeInvoiceEditing.commit(draft(number: "  "), baselineExists: true, baselineChangedSinceOpened: false, resolveNumber: "INV-0043") {
case .success(let edit): expect(edit.number == "INV-0043" && edit.numberWasResolved, "blank number resolves at commit")
case .failure: expect(false, "blank number should resolve, not refuse")
}
switch NativeInvoiceEditing.commit(draft(number: "INV-0007"), baselineExists: true, baselineChangedSinceOpened: false, resolveNumber: "INV-9999") {
case .success(let edit): expect(edit.number == "INV-0007" && !edit.numberWasResolved, "explicit number never overwritten")
case .failure: expect(false, "explicit number should commit")
}

// Refusals: missing baseline, concurrent move, invalid draft.
switch NativeInvoiceEditing.commit(draft(), baselineExists: false, baselineChangedSinceOpened: false, resolveNumber: "INV-1") {
case .failure(.missingRecord): break
default: expect(false, "vanished record fails closed, never recreates")
}
switch NativeInvoiceEditing.commit(draft(), baselineExists: true, baselineChangedSinceOpened: true, resolveNumber: "INV-1") {
case .failure(.conflictingRecord): break
default: expect(false, "concurrent move refuses instead of overwriting")
}
switch NativeInvoiceEditing.commit(draft(customer: "", amount: -5), baselineExists: true, baselineChangedSinceOpened: false, resolveNumber: "INV-1") {
case .failure(.invalidDraft(let reasons)): expect(reasons == [.missingCustomer, .invalidAmount], "both reasons reported, draft retained")
default: expect(false, "invalid draft refused with reasons")
}

var cal = Calendar(identifier: .gregorian)
let sample = cal.date(from: DateComponents(year: 2026, month: 10, day: 5))!
expect(NativeInvoiceEditing.dayString(sample, calendar: cal) == "2026-10-05", "due day-string formats local midnight")
expect(NativeInvoiceEditing.date(fromDayString: "2026-10-05", calendar: cal).map { NativeInvoiceEditing.dayString($0, calendar: cal) } == "2026-10-05", "due day-string round-trips")
expect(NativeInvoiceEditing.date(fromDayString: "junk", calendar: cal) == nil, "malformed due fails closed to nil")

if failures == 0 { print("InvoiceEditingTests: all tests passed") } else { print("InvoiceEditingTests: \(failures) failure(s)") }
exit(failures == 0 ? 0 : 1)
