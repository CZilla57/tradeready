import Foundation

// Trade template tests (task 9.05).
//
// Ports __tests__/tradeTemplates.test.ts: the catalog shape, the load-bearing
// no-baked-figures guardrail, valid seeded categories/policies, the trade-sorted
// browse order, and the empty seed lines applyTemplate produces.

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

private func testCatalog() {
    expectEqual(NativeTradeTemplates.all.count, 7, "seven templates")
    expectEqual(
        NativeTradeTemplates.all.map(\.id).sorted(),
        ["drywall", "electrical", "flooring", "handyman", "landscaping", "painting", "plumbing"].sorted(),
        "covers all seven article trades"
    )
    for template in NativeTradeTemplates.all {
        expect(!template.name.trimmingCharacters(in: .whitespaces).isEmpty, "\(template.id) has a name")
        expect(!template.scopeChecklist.isEmpty, "\(template.id) has a checklist")
        expect(!template.trades.isEmpty, "\(template.id) names its trades")
    }
}

private func testGuardrail() {
    for template in NativeTradeTemplates.all {
        expect(!NativeTradeTemplates.containsBakedFigures(template), "\(template.id) bakes in no figure")
    }
    // The guardrail must actually be able to fail.
    var poisoned = NativeTradeTemplates.all[0]
    poisoned.scopeChecklist.append("Charge $95 minimum")
    expect(NativeTradeTemplates.containsBakedFigures(poisoned), "guardrail detects an injected price")

    let validCategories: Set<String> = ["permit", "disposal", "rental", "subcontractor", "delivery", "travel", "other"]
    let validPolicies: Set<String> = ["in_margin_base", "passthrough"]
    for template in NativeTradeTemplates.all {
        for cost in template.seedJobCosts {
            expect(validCategories.contains(cost.category), "\(template.id) seeded cost category is valid")
            expect(validPolicies.contains(cost.markupPolicy), "\(template.id) seeded markup policy is valid")
        }
    }
}

private func testBrowseAndSeeds() {
    let plumbing = NativeTradeTemplates.templatesForTrade("plumbing")
    expectEqual(plumbing.count, 7, "browse still lists every template")
    expectEqual(plumbing.first?.id, "plumbing", "relevant trade sorts first")
    // Non-relevant templates keep their catalog order.
    expectEqual(plumbing[1].id, "handyman", "remaining templates keep catalog order")
    expectEqual(NativeTradeTemplates.templatesForTrade("unknown").map(\.id), NativeTradeTemplates.all.map(\.id), "unknown trade keeps catalog order")

    let painting = NativeTradeTemplates.all.first { $0.id == "painting" }!
    let seeds = NativeTradeTemplates.applyTemplate(painting, idBase: 1000)
    expectEqual(seeds.materials.count, 3, "painting seeds three materials")
    expectEqual(seeds.materials[0].id, "m1000-0", "deterministic material id")
    expectEqual(seeds.materials[0].name, "Paint", "material name carried")
    expectEqual(seeds.materials[0].quantity, 1, "material quantity seeds at 1")
    expectEqual(seeds.materials[0].unitCost, 0, "material cost seeds at 0 — the owner fills it")
    expectEqual(seeds.jobCosts.count, 0, "painting seeds no direct costs")

    let electrical = NativeTradeTemplates.all.first { $0.id == "electrical" }!
    let electricalSeeds = NativeTradeTemplates.applyTemplate(electrical, idBase: 7)
    expectEqual(electricalSeeds.jobCosts.count, 1, "electrical seeds one direct cost")
    expectEqual(electricalSeeds.jobCosts[0].label, "Permit fee", "seed label")
    expectEqual(electricalSeeds.jobCosts[0].unitCost, 0, "seeded cost is $0")
    expectEqual(electricalSeeds.jobCosts[0].markupPercent, 0, "seeded markup 0%")
    expectEqual(electricalSeeds.jobCosts[0].taxable, false, "seeded cost non-taxable")
    expectEqual(electricalSeeds.jobCosts[0].customerVisible, true, "seeded cost customer-visible")
    expectEqual(electricalSeeds.jobCosts[0].markupPolicy, "passthrough", "permit is passthrough")
}

testCatalog()
testGuardrail()
testBrowseAndSeeds()

if failures == 0 {
    print("TradeTemplateTests: all checks passed")
} else {
    print("TradeTemplateTests: \(failures) failure(s)")
    exit(1)
}
