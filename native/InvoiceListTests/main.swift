import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

private var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)! // US Pacific: exercises local-frame parsing
private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: d))! }
private func due(_ d: Int) -> String { String(format: "2026-09-%02d", d) }
private func item(_ id: String, amount: Double, paid: Double, due: String, customer: String = "Acme", number: String = "") -> NativeInvoiceListItem {
    .init(id: id, customer: customer, number: number.isEmpty ? "INV-\(id)" : number, amount: amount, amountPaid: paid, due: due)
}

// daysPastDue: local-midnight round semantics (RN parity).
expect(NativeInvoiceList.daysPastDue(due: due(10), now: day(15), calendar: calendar) == 5, "5 days past due")
expect(NativeInvoiceList.daysPastDue(due: due(15), now: day(15), calendar: calendar) == 0, "due today is 0")
expect(NativeInvoiceList.daysPastDue(due: due(20), now: day(15), calendar: calendar) == -5, "future due is negative")
expect(NativeInvoiceList.daysPastDue(due: "not-a-date", now: day(15), calendar: calendar) == nil, "malformed due fails closed")

// Status precedence: paid > overdue > partly > due-today > due-soon.
expect(NativeInvoiceList.status(amount: 100, amountPaid: 100, due: due(1), now: day(15), calendar: calendar) == .paid, "paid wins even when overdue")
expect(NativeInvoiceList.status(amount: 100, amountPaid: 40, due: due(10), now: day(15), calendar: calendar) == .overdue(days: 5), "overdue beats partly-paid")
expect(NativeInvoiceList.status(amount: 100, amountPaid: 40, due: due(15), now: day(15), calendar: calendar) == .partlyPaid, "partly-paid while not past due")
expect(NativeInvoiceList.status(amount: 100, amountPaid: 0, due: due(15), now: day(15), calendar: calendar) == .dueToday, "due today")
expect(NativeInvoiceList.status(amount: 100, amountPaid: 0, due: due(20), now: day(15), calendar: calendar) == .dueSoon, "due soon")
expect(NativeInvoiceList.status(amount: 100, amountPaid: 0, due: "junk", now: day(15), calendar: calendar) == .dueSoon, "malformed due never overdue")

// Epsilon: half-cent-or-less balance reads paid (RN PAID_EPSILON parity).
expect(NativeInvoiceList.isFullyPaid(amount: 100, amountPaid: 99.996), "0.004 balance is paid")
expect(!NativeInvoiceList.isFullyPaid(amount: 100, amountPaid: 99.99), "0.01 balance is unpaid")

// Summary: partly-paid contributes to BOTH collected and outstanding; overdue counts unpaid past-due.
let invoices = [
    item("a", amount: 1000, paid: 0, due: due(10)),   // overdue, unpaid
    item("b", amount: 500, paid: 200, due: due(20)),  // partly, not due
    item("c", amount: 300, paid: 300, due: due(1)),   // paid, old
]
let summary = NativeInvoiceList.summarize(invoices, now: day(15), calendar: calendar)
expect(abs(summary.outstanding - 1300) < 0.001, "outstanding = 1000 + 300 + 0")
expect(abs(summary.collected - 500) < 0.001, "collected = 0 + 200 + 300")
expect(summary.overdueCount == 1, "only the unpaid past-due counts")

// Filters mirror InvoicesView chip semantics.
expect(NativeInvoiceList.counts(invoices, now: day(15), calendar: calendar) == [.all: 3, .unpaid: 2, .overdue: 1, .paid: 1], "chip counts match view semantics")

// Search: customer or number, case-insensitive.
let named = [item("x", amount: 10, paid: 0, due: due(20), customer: "Mesa Bakery"), item("y", amount: 10, paid: 0, due: due(20), customer: "Acme", number: "INV-0042")]
expect(NativeInvoiceList.filter(named, query: "mesa").map(\.id) == ["x"], "customer search case-insensitive")
expect(NativeInvoiceList.filter(named, query: "inv-0042").map(\.id) == ["y"], "number search case-insensitive")
expect(NativeInvoiceList.filter(named, query: "  ").count == 2, "blank query returns all")

// Ordering: due-ascending, malformed last, id tiebreak.
let unordered = [item("m", amount: 1, paid: 0, due: "junk"), item("e", amount: 1, paid: 0, due: due(20)), item("d", amount: 1, paid: 0, due: due(10))]
expect(NativeInvoiceList.sortedByDue(unordered, calendar: calendar).map(\.id) == ["d", "e", "m"], "due-ascending, malformed last")

if failures == 0 { print("InvoiceListTests: all tests passed") } else { print("InvoiceListTests: \(failures) failure(s)") }
exit(failures == 0 ? 0 : 1)
