import Foundation

// Pricebook CRUD + prefill tests (task 9.05).
//
// Pins the canonical field projection (create stamps createdAt/updatedAt, edit
// preserves createdAt and unknown fields), the pricing-engine estimate total,
// delete-by-id, search/sort, and the job-prefill projection.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func material(_ id: String, _ name: String, qty: String, cost: String) -> Canonical.Material {
    NativePricebook.decode(Canonical.Material.self, [
        "id": .string(id), "name": .string(name), "quantity": .number(decimal(qty)), "unitCost": .number(decimal(cost)),
    ])!
}

private func draft(name: String = "Faucet swap", hours: String = "2", rate: String = "100") -> NativePricebookEntryDraft {
    NativePricebookEntryDraft(
        name: name, description: "Replace a kitchen faucet", category: "plumbing",
        laborHours: decimal(hours), laborBreakdown: nil, laborRate: decimal(rate),
        materials: [material("m1", "Faucet", qty: "1", cost: "120")],
        materialMarkup: 20, jobCosts: [], overhead: 15, margin: 20
    )
}

private func testCreate() {
    let fields = NativePricebook.createFields(draft: draft(), id: "pb1", now: "2026-03-01T10:00:00.000Z")
    expectEqual(fields["id"], .string("pb1"), "id stamped")
    expectEqual(fields["createdAt"], .string("2026-03-01T10:00:00.000Z"), "createdAt stamped")
    expectEqual(fields["updatedAt"], .string("2026-03-01T10:00:00.000Z"), "updatedAt stamped")
    expectEqual(fields["name"], .string("Faucet swap"), "name stored")
    expectEqual(fields["materials"], .array([.object([
        "id": .string("m1"), "name": .string("Faucet"), "quantity": .number(1), "unitCost": .number(120),
    ])]), "materials nested canonically")

    // Estimate total comes from the shared pricing engine, not a hand sum.
    let expected = PricingEngine.calculate(NativePricebook.pricingInput(draft(), minimumJobFee: 75)).total
    expectEqual(fields["estimateTotal"], .number(expected), "estimate total = engine total")
    expect(expected > 0, "estimate total is positive")

    guard let entry = NativePricebook.decode(Canonical.PricebookEntry.self, fields) else {
        expect(false, "create fields decode into a canonical entry")
        return
    }
    expectEqual(entry.name, "Faucet swap", "decoded entry name")
    expectEqual(entry.materials.count, 1, "decoded entry materials")
}

private func testEditPreserves() {
    let original = NativePricebook.createFields(draft: draft(name: "Old name"), id: "pb1", now: "2026-01-01T00:00:00.000Z")
    // Simulate a forward-compatible field written by another app version.
    var baseline = original
    baseline["futureField"] = .object(["nested": .string("keep me")])

    let edited = NativePricebook.appliedFields(
        draft: draft(name: "New name"),
        to: baseline,
        now: "2026-03-01T10:00:00.000Z"
    )
    expectEqual(edited["createdAt"], .string("2026-01-01T00:00:00.000Z"), "edit preserves createdAt")
    expectEqual(edited["updatedAt"], .string("2026-03-01T10:00:00.000Z"), "edit stamps updatedAt")
    expectEqual(edited["name"], .string("New name"), "edit updates name")
    expectEqual(edited["futureField"], .object(["nested": .string("keep me")]), "unknown nested field preserved")
    expectEqual(edited["id"], .string("pb1"), "id unchanged")
}

private func testDeleteSearchSort() {
    let a = NativePricebook.decode(Canonical.PricebookEntry.self, NativePricebook.createFields(draft: draft(name: "Zebra"), id: "pb1", now: "2026-01-01"))!
    let b = NativePricebook.decode(Canonical.PricebookEntry.self, NativePricebook.createFields(draft: draft(name: "apple"), id: "pb2", now: "2026-01-01"))!

    expectEqual(NativePricebook.delete([a, b], id: "pb1").map(\.id), ["pb2"], "delete removes by id")
    expectEqual(NativePricebook.sortedByName([a, b]).map(\.name), ["apple", "Zebra"], "sort by name is case-insensitive")
    expectEqual(NativePricebook.search([a, b], query: "ZEB").map(\.id), ["pb1"], "search is case-insensitive")
    expectEqual(NativePricebook.search([a, b], query: "plumbing").count, 2, "search matches category")
    expectEqual(NativePricebook.search([a, b], query: "  ").count, 2, "blank search returns everything")
}

private func testJobPrefill() {
    let fields = NativePricebook.createFields(draft: draft(), id: "pb1", now: "2026-01-01")
    let entry = NativePricebook.decode(Canonical.PricebookEntry.self, fields)!
    let prefill = NativePricebook.jobPrefill(from: entry)
    expectEqual(prefill.name, entry.name, "prefill carries the name")
    expectEqual(prefill.laborHours, entry.laborHours, "prefill carries labor hours")
    expectEqual(prefill.laborRate, entry.laborRate, "prefill carries labor rate")
    expectEqual(prefill.materials.count, entry.materials.count, "prefill carries materials")
    expectEqual(prefill.overhead, entry.overhead, "prefill carries overhead")
    expectEqual(prefill.margin, entry.margin, "prefill carries margin")
    expectEqual(prefill.jobCosts.count, 0, "prefill invents no job costs")
    expectEqual(NativePricebook.estimateTotal(prefill), entry.estimateTotal, "prefill reproduces the stored total")
}

testCreate()
testEditPreserves()
testDeleteSearchSort()
testJobPrefill()

if failures == 0 {
    print("PricebookTests: all checks passed")
} else {
    print("PricebookTests: \(failures) failure(s)")
    exit(1)
}
