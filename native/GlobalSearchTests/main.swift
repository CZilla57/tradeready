import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

private let calendar = Calendar(identifier: .gregorian)
private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

let blank = NativeGlobalSearch.search(
    jobs: [Job(title: "Water heater")],
    customers: [Customer(name: "Water Works")],
    invoices: [Invoice(customer: "Water Works")],
    query: "  "
)
expect(blank.total == 0, "blank queries return no records or actions")

let matchingJobs = [
    Job(id: "title", title: "Gutter clean", createdAt: date(2026, 1, 1)),
    Job(id: "customer", customerName: "Gutterson", title: "Other", createdAt: date(2026, 2, 1)),
    Job(id: "address", title: "Other", address: "9 Gutter Ln", createdAt: date(2026, 3, 1)),
    Job(id: "description", title: "Other", description: "Install gutter guards", createdAt: date(2026, 4, 1)),
    Job(id: "notes", title: "Other", notes: "Bring gutter brush", createdAt: date(2026, 5, 1)),
    Job(id: "archived", title: "Gutter archive", createdAt: date(2026, 6, 1), archivedAt: "2026-07-01"),
]
let jobResults = NativeGlobalSearch.search(jobs: matchingJobs, customers: [], invoices: [], query: "GUTTER")
expect(jobResults.jobs.total == 5, "jobs match all five React Native fields and exclude archived records")
expect(jobResults.jobs.items.map(\.id) == ["notes", "description", "address", "customer", "title"],
       "jobs sort newest first")

let customers = [
    Customer(id: "z", name: "Zed", email: "paint@example.com"),
    Customer(id: "a", name: "Al Paint", phone: "555-0199"),
    Customer(id: "archived", name: "Archived Paint", archivedAt: "2026-07-01"),
]
let customerResults = NativeGlobalSearch.search(jobs: [], customers: customers, invoices: [], query: "paint")
expect(customerResults.customers.items.map(\.id) == ["a", "z"],
       "customers search contact fields, exclude archives, and sort alphabetically")

let invoices = [
    Invoice(id: "early", customer: "Alice", number: "INV-0042", amount: 10, due: date(2026, 2, 1)),
    Invoice(id: "late", customer: "Bob", number: "INV-0042-B", amount: 20, due: date(2026, 8, 1)),
]
let invoiceResults = NativeGlobalSearch.search(jobs: [], customers: [], invoices: invoices, query: "0042")
expect(invoiceResults.invoices.items.map(\.id) == ["late", "early"],
       "invoices search number and sort by latest due date")

let many = (0..<11).map { Job(id: "j\($0)", title: "Fence \($0)", createdAt: date(2026, 1, $0 + 1)) }
let capped = NativeGlobalSearch.search(jobs: many, customers: [], invoices: [], query: "fence")
expect(capped.jobs.items.count == NativeGlobalSearch.sectionLimit && capped.jobs.total == 11,
       "sections cap at eight while reporting the true count")

let actions = NativeGlobalSearch.search(jobs: [], customers: [], invoices: [], query: "new")
expect(actions.actions.items.map(\.id) == [.newJob, .newCustomer, .newInvoice],
       "new-job, customer, and invoice actions are searchable")
expect(NativeGlobalSearch.search(jobs: [], customers: [], invoices: [], query: "billing").actions.items.first?.id == .newInvoice,
       "action keywords route to the intended create flow")

if failures == 0 {
    print("PASS: native global search tests")
} else {
    print("\(failures) native global search test(s) failed")
    exit(1)
}
