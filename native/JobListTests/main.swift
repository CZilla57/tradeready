import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

private let calendar = Calendar(identifier: .gregorian)
private func date(_ day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
}

private func item(
    _ id: String,
    _ status: String,
    day: Int,
    title: String = "Job",
    customer: String = "Customer",
    total: Double = 0,
    archived: Bool = false,
    recurring: Bool = false
) -> NativeJobListItem {
    .init(
        id: id,
        title: title,
        customerName: customer,
        description: "",
        status: status,
        createdAt: date(day),
        billableTotal: total,
        isArchived: archived,
        isRecurring: recurring
    )
}

let jobs = [
    item("lead", "lead", day: 1, title: "Kitchen faucet", total: 100.01),
    item("sent", "estimate_sent", day: 2, customer: "Mesa Bakery", total: 250),
    item("approved", "approved", day: 3),
    item("scheduled", "scheduled", day: 4),
    item("progress", "in_progress", day: 5, recurring: true),
    item("complete", "complete", day: 6),
    item("invoiced", "invoiced", day: 7),
    item("paid", "paid", day: 8),
    item("declined", "declined", day: 9),
    item("archived", "lead", day: 10, archived: true),
]

let active = NativeJobList.state(items: jobs, selectedFilter: .active, query: "")
expect(active.items.map(\.id) == ["progress", "scheduled", "approved", "sent", "lead"],
       "Active spans every in-flight status, excludes archives, and sorts newest first")
expect(active.stats.activeCount == 7, "active stat excludes only invoiced and paid non-archived jobs")
expect(active.stats.openEstimateCount == 2, "open estimates include lead and estimate-sent jobs")
expect(active.stats.pendingValue == 350.01, "pending value sums rounded display totals to cents")
expect(active.nonArchivedCount == 9, "non-archived count excludes hidden history")

let counts = Dictionary(uniqueKeysWithValues: active.filters.map { ($0.filter, $0.count) })
expect(counts[.active] == 5 && counts[.quotes] == 2 && counts[.complete] == 2,
       "grouped lifecycle filters report React Native parity counts")
expect(counts[.paid] == 1 && counts[.declined] == 1 && counts[.all] == 9 && counts[.archived] == 1,
       "paid, declined, all, and archived counts use the correct archive boundary")

let quotes = NativeJobList.state(items: jobs, selectedFilter: .quotes, query: "mesa")
expect(quotes.items.map(\.id) == ["sent"], "search matches customer names within the selected lifecycle filter")
let titleSearch = NativeJobList.state(items: jobs, selectedFilter: .all, query: "  FAUCET ")
expect(titleSearch.items.map(\.id) == ["lead"], "search trims whitespace and matches job titles case-insensitively")

let noRareStates = jobs.filter { $0.id != "declined" && $0.id != "archived" }
let declinedFallback = NativeJobList.state(items: noRareStates, selectedFilter: .declined, query: "")
expect(declinedFallback.effectiveFilter == .active, "a vanished Declined chip falls back to Active")
expect(!declinedFallback.filters.contains { $0.filter == .declined }, "empty Declined chips stay hidden")
let archiveFallback = NativeJobList.state(items: noRareStates, selectedFilter: .archived, query: "")
expect(archiveFallback.effectiveFilter == .active, "a vanished Archived chip falls back to Active")
expect(!archiveFallback.filters.contains { $0.filter == .archived }, "empty Archived chips stay hidden")

expect(NativeJobList.quickActionLabel(status: "lead") == "Build estimate →", "lead action starts estimate work")
expect(NativeJobList.quickActionLabel(status: "in_progress") == "Mark complete →", "in-progress action advances completion")
expect(NativeJobList.quickActionLabel(status: "unknown") == nil, "unknown statuses do not invent an action")

let billable = NativeJobList.billableTotal(
    estimate: Decimal(string: "2400")!,
    changeOrders: [
        .init(amount: 500, approvalDecision: "approved", manualDecision: nil, isCancelled: false),
        .init(amount: 350, approvalDecision: nil, manualDecision: "approved", isCancelled: false),
        .init(amount: 90, approvalDecision: "declined", manualDecision: "approved", isCancelled: false),
        .init(amount: 75, approvalDecision: "approved", manualDecision: nil, isCancelled: true),
    ]
)
expect(billable == 3250, "billable total honors approved decisions, link precedence, and cancellation")
let halfCentBillable = NativeJobList.billableTotal(
    estimate: Decimal(string: "1234.567890123456789")!,
    changeOrders: [
        .init(
            amount: Decimal(string: "199.995")!,
            approvalDecision: nil,
            manualDecision: "approved",
            isCancelled: false
        )
    ]
)
expect(abs(halfCentBillable - 1434.57) < 0.000_001,
       "approved subtotal rounds before the final billable total like React Native")
let negativeHalfCentBillable = NativeJobList.billableTotal(
    estimate: 100,
    changeOrders: [
        .init(
            amount: Decimal(string: "-1.005")!,
            approvalDecision: nil,
            manualDecision: "approved",
            isCancelled: false
        )
    ]
)
expect(negativeHalfCentBillable == 99,
       "negative half-cent subtotal follows JavaScript Math.round")

if failures == 0 {
    print("PASS: native job list tests")
} else {
    print("\(failures) native job list test(s) failed")
    exit(1)
}
