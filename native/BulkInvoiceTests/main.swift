import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private let invoices = [
    NativeBulkRemindableItem(id: "a", isPaid: false, email: "a@test.com", phone: ""),
    NativeBulkRemindableItem(id: "b", isPaid: false, email: "", phone: "555-0100"),
    NativeBulkRemindableItem(id: "c", isPaid: true, email: "c@test.com", phone: "555-0102"),
    NativeBulkRemindableItem(id: "d", isPaid: false, email: "", phone: ""),
]

let email = NativeInvoiceBulk.splitRemindable(invoices, selectedIDs: ["a", "b", "c", "d"], channel: .email)
expect(email.eligible.map(\.id) == ["a"], "email reaches only addressed unpaid")
expect(email.skippedNoContact.map(\.id) == ["b", "d"], "email skips contact-less unpaid")
expect(!email.eligible.contains(where: { $0.id == "c" }), "paid invoices are silently ignored")

let text = NativeInvoiceBulk.splitRemindable(invoices, selectedIDs: ["a", "b", "c", "d"], channel: .text)
expect(text.eligible.map(\.id) == ["b"], "text reaches only phoned unpaid")
expect(text.skippedNoContact.map(\.id) == ["a", "d"], "text skips contact-less unpaid")

let partial = NativeInvoiceBulk.splitRemindable(invoices, selectedIDs: ["b"], channel: .email)
expect(partial.eligible.isEmpty && partial.skippedNoContact.map(\.id) == ["b"], "single unreachable selection skips")

print(failures == 0 ? "PASS: native bulk invoice tests" : "FAILED: \(failures) native bulk invoice test(s)")
if failures != 0 { exit(1) }
