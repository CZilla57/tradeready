import Foundation

// Pricebook UI tests (task 9.12, requirements P1-P4).
//
// The CRUD projection, estimate total, search/sort, and template guardrail are
// covered by PricebookTests / TradeTemplateTests / PricebookAITests (9.05).
// These vectors cover what 9.12 owns, ported from `screens/PricebookScreen.tsx`,
// `screens/PricebookEntryScreen.tsx`, `components/JobCostsEditor.tsx`, and the
// AI panel: the grouped list, the editor's text layer, the direct-cost catalog,
// template seeding rules, suggestion rows/apply, and the job prefill.

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

private let decoder = JSONDecoder()

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func entry(_ overrides: String = "") -> Canonical.PricebookEntry {
    let base = """
    {"id":"pb1","name":"Water heater swap","laborHours":4,"laborRate":85,"materials":[],
     "materialMarkup":20,"overhead":15,"margin":20,"estimateTotal":500,
     "createdAt":"2026-03-01T00:00:00.000Z","updatedAt":"2026-03-01T00:00:00.000Z"}
    """
    return try! decoder.decode(Canonical.PricebookEntry.self, from: Data(merge(base, overrides).utf8))
}

private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Alice","title":"Repipe","description":"",
     "status":"approved","address":"","estimateTotal":1000,"laborHours":4,"laborRate":100,
     "materials":[],"materialMarkup":0,"overhead":15,"margin":20,"notes":"","createdAt":"2026-03-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

private func material(_ overrides: String = "") -> Canonical.Material {
    let base = #"{"id":"m1","name":"Part","quantity":1,"unitCost":10}"#
    return try! decoder.decode(Canonical.Material.self, from: Data(merge(base, overrides).utf8))
}

private func merge(_ base: String, _ overrides: String) -> String {
    guard !overrides.isEmpty else { return base }
    func fields(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
               let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }
    let merged = fields(base).merging(fields(overrides)) { _, new in new }
    let body = merged.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    return "{\(body)}"
}

/// `buildEstimateInput` for the editor's expected total (no travel/tax, entry
/// overhead/margin, settings minimum fee).
private func expectedTotal(_ draft: NativePricebookEntryDraft, minimumJobFee: Decimal = 75) -> Decimal {
    NativePricebook.estimateTotal(draft, minimumJobFee: minimumJobFee)
}

// MARK: - List

private func testList() {
    let entries = [
        entry(#"{"id":"a","name":"Drain snaking","category":"Plumbing","estimateTotal":250}"#),
        entry(#"{"id":"b","name":"Panel upgrade","category":"Electrical","estimateTotal":1800}"#),
        entry(#"{"id":"c","name":"Odd job","estimateTotal":80}"#),
        entry(#"{"id":"d","name":"Water heater swap","category":"Plumbing","estimateTotal":1299.5}"#),
    ]

    let sections = NativePricebookList.sections(entries)
    expectEqual(sections.map(\.title), ["Electrical", "Plumbing", "Uncategorized"],
                "sections sort by category with Uncategorized last")
    expectEqual(sections[1].rows.map(\.id), ["a", "d"], "entries keep their input order inside a category")
    expectEqual(sections[0].rows.first?.priceText, "$1,800", "whole-dollar totals render without cents")
    expectEqual(sections[1].rows.last?.priceText, "$1,299.50", "a cent total renders a full cent pair")
    expectEqual(sections[2].rows.first?.priceText, "$80", "uncategorized entries are grouped")

    // The list screen searches the NAME only (9.05's `search` also matches
    // category and is used by the pickers instead).
    let byName = NativePricebookList.filtered(entries, query: "water")
    expectEqual(byName.map(\.id), ["d"], "search matches the name, case-insensitively")
    expect(NativePricebookList.filtered(entries, query: "plumbing").isEmpty,
           "the list search does not match the category")
    expectEqual(NativePricebookList.sections(entries, query: "plumbing").count, 0,
                "a search with no name matches yields no sections")

    let row = NativePricebookList.row(entry(#"{"id":"x","name":"Repipe","description":"2 baths","estimateTotal":100}"#))
    expectEqual(row.description, "2 baths", "the row carries the description")
    expect(NativePricebookList.row(entry(#"{"id":"y","name":"Repipe","description":"","estimateTotal":100}"#)).description == nil,
           "an empty description is omitted")

    expectEqual(NativePricebookList.existingCategories(entries), ["Plumbing", "Electrical"],
                "existing categories are distinct and keep first-seen order")
    expectEqual(NativePricebookList.categorySuggestions(entries, input: "plu"), ["Plumbing"],
                "category suggestions are substring matches")
    expect(NativePricebookList.categorySuggestions(entries, input: "Plumbing").isEmpty,
           "an exact category is not suggested again")
    expect(NativePricebookList.categorySuggestions(entries, input: "").isEmpty,
           "an empty category input has no suggestions")
}

// MARK: - Editor text layer

private func testForm() {
    let form = NativePricebookForm()
    expectEqual(form.validationMessage, "Give this service a name so you can find it later.",
                "a nameless service is refused with the RN copy")
    // The pricing engine floors every estimate at the minimum job fee, so an
    // empty form prices at that floor rather than at zero (RN's
    // `calculateEstimate` receives the same `minimumJobFee`).
    expectEqual(NativePricebookForm().estimateTotalText(), "$75", "an empty form prices at the minimum job fee")
    expectEqual(NativePricebookForm().estimateTotalText(minimumJobFee: 0), "$0", "with no minimum fee an empty form is zero")

    // parseFloat(x) || 0
    expectEqual(NativePricebookForm.number("3"), decimal("3"), "integer text")
    expectEqual(NativePricebookForm.number("85.5"), decimal("85.5"), "decimal text")
    expectEqual(NativePricebookForm.number("20abc"), decimal("20"), "leading numeric prefix is kept")
    expectEqual(NativePricebookForm.number(""), decimal("0"), "blank is zero")
    expectEqual(NativePricebookForm.number("abc"), decimal("0"), "junk is zero")
    expectEqual(NativePricebookForm.number("0"), decimal("0"), "zero stays zero")
    expectEqual(NativePricebookForm.text(decimal("30.50")), "30.5", "numeric text drops trailing zeroes")

    let seeded = NativePricebookForm(draft: NativePricebook.jobPrefill(from: entry(#"{"id":"z","name":"Repipe","laborHours":4,"laborRate":85.5,"materialMarkup":20,"overhead":15,"margin":20,"materials":[{"id":"m1","name":"PEX","quantity":2,"unitCost":3.25}],"jobCosts":[{"id":"jc1","label":"Permit","category":"permit","quantity":1,"unitCost":120,"markupPercent":0,"markupPolicy":"passthrough","taxable":false,"customerVisible":true}],"estimateTotal":500}"#)))
    expectEqual(seeded.laborHoursText, "4", "edit seeds labor hours")
    expectEqual(seeded.laborRateText, "85.5", "edit seeds a fractional rate")
    expectEqual(seeded.materials.first?.name, "PEX", "edit seeds materials")
    expectEqual(seeded.materials.first?.unitCostText, "3.25", "edit seeds material unit cost")
    expectEqual(seeded.jobCosts.first?.markupPolicy, "passthrough", "edit seeds the direct-cost policy")
    expectEqual(seeded.jobCosts.first?.amountText, "$120", "a passthrough line shows at cost")

    // Round-trip: the text layer parses back to the same canonical values.
    let roundTripped = seeded.draft
    expectEqual(roundTripped.name, "Repipe", "name round-trips")
    expectEqual(roundTripped.laborHours, decimal("4"), "labor hours round-trip")
    expectEqual(roundTripped.materials.first?.quantity, decimal("2"), "material quantity round-trips")
    expectEqual(roundTripped.materials.first?.unitCost, decimal("3.25"), "material unit cost round-trips")
    expectEqual(roundTripped.jobCosts.first?.unitCost, decimal("120"), "direct-cost unit cost round-trips")
    expectEqual(roundTripped.jobCosts.first?.markupPolicy, "passthrough", "policy round-trips")

    // Blank optional text becomes absent, not an empty string.
    var blanks = NativePricebookForm()
    blanks.name = "  Snaking  "
    blanks.description = "   "
    blanks.category = ""
    let trimmed = blanks.draft
    expectEqual(trimmed.name, "Snaking", "the name is trimmed")
    expect(trimmed.description == nil, "a blank description is absent")
    expect(trimmed.category == nil, "a blank category is absent")

    // The live total is the pricing engine's own number.
    var priced = NativePricebookForm(draft: NativePricebook.jobPrefill(from: entry(#"{"id":"q","name":"Repipe","laborHours":2,"laborRate":100,"materials":[{"id":"m1","name":"Parts","quantity":1,"unitCost":50}],"materialMarkup":0,"overhead":0,"margin":0,"estimateTotal":0}"#)))
    expectEqual(priced.estimateTotalText(), NativeMoneyFormat.quote(expectedTotal(priced.draft)), "live total matches the engine")
    expectEqual(priced.estimateTotalText(), "$250", "labor + materials with no markup")
    priced.overheadText = "10"
    expect(priced.estimateTotalText() != "$250", "changing overhead moves the live total")
}

// MARK: - Direct costs

private func testJobCosts() {
    expectEqual(NativeJobCostCatalog.label(for: "rental"), "Equipment rental", "catalog label")
    expectEqual(NativeJobCostCatalog.label(for: "unknown"), "Other cost", "unknown category falls back")
    expectEqual(NativeJobCostCatalog.defaultMarkupPolicy(for: "permit"), "passthrough", "permits pass through")
    expectEqual(NativeJobCostCatalog.defaultMarkupPolicy(for: "disposal"), "in_margin_base", "everything else joins the margin base")
    expectEqual(NativeJobCostCatalog.displayLabel(label: "  ", category: "delivery"), "Delivery",
                "an unlabeled line shows its category")
    expectEqual(NativeJobCostCatalog.displayLabel(label: "Dump fee", category: "disposal"), "Dump fee",
                "the owner's label wins")

    let new = NativePricebookJobCostRow.new(id: "jc1")
    expectEqual(new.category, "other", "a new line starts as Other cost")
    expectEqual(new.quantityText, "1", "a new line starts at quantity 1")
    expectEqual(new.markupPolicy, "in_margin_base", "a new line joins the margin base")
    expect(new.customerVisible, "a new line is customer-visible by default")
    expect(!new.taxable, "a new line is not taxable by default")
    expectEqual(new.amountText, "$0", "a new line costs nothing yet")

    var marked = new
    marked.quantityText = "2"
    marked.unitCostText = "50"
    marked.markupPercentText = "10"
    expectEqual(marked.amountText, "$110", "margin-base lines apply their markup")
    marked.markupPolicy = "passthrough"
    expectEqual(marked.amountText, "$100", "a passthrough line ignores markup")
    expectEqual(NativeJobCostCatalog.lineAmount(quantity: 2, unitCost: 50, markupPercent: 10, markupPolicy: "in_margin_base"),
                decimal("110"), "line amount math")

    // A blank label still round-trips through the canonical record.
    var blank = new
    blank.label = "  "
    expect(blank.jobCost != nil, "a blank label still builds a record")
    expectEqual(blank.jobCost?.label, "  ", "the record keeps the raw label")
}

// MARK: - Templates

private func testTemplates() {
    let rows = NativePricebookTemplates.rows()
    expectEqual(rows.count, NativeTradeTemplates.all.count, "every template has a picker row")
    expect(!rows.isEmpty, "the catalog is not empty")
    expect(rows.allSatisfy { !$0.tradesText.isEmpty }, "every row names its trades")
    expect(rows.allSatisfy { $0.checklistCount > 0 }, "every row has at least one scope reminder")

    // Seeding rules: name only when blank; lines only when the form has none.
    let painting = NativeTradeTemplates.all.first { $0.id == "painting" }!
    var form = NativePricebookForm()
    var checklist: [String] = []
    NativePricebookTemplates.applying(painting, to: &form, checklist: &checklist, idBase: 7)
    expectEqual(form.name, "Painting job", "a template names an unnamed service")
    expectEqual(form.materials.map(\.name), painting.seedMaterials, "seeded material lines")
    expectEqual(checklist, painting.scopeChecklist, "the scope checklist is attached")
    expect(form.materials.allSatisfy { $0.quantityText == "1" && $0.unitCostText == "0" },
           "seeded lines carry no quantities or prices")
    expect(form.jobCosts.isEmpty, "painting seeds no direct costs")

    var named = NativePricebookForm()
    named.name = "My own name"
    named.materials = [NativePricebookMaterialRow(id: "m1", name: "Existing", quantityText: "1", unitCostText: "5")]
    var secondChecklist: [String] = []
    NativePricebookTemplates.applying(painting, to: &named, checklist: &secondChecklist, idBase: 9)
    expectEqual(named.name, "My own name", "a template never overwrites a typed name")
    expectEqual(named.materials.count, 1 + painting.seedMaterials.count, "seeded lines append to existing work")

    // The guardrail holds in the UI path too: no seeded value carries a figure.
    let drywall = NativeTradeTemplates.all.first { $0.id == "drywall" }!
    var drywallForm = NativePricebookForm()
    var drywallChecklist: [String] = []
    NativePricebookTemplates.applying(drywall, to: &drywallForm, checklist: &drywallChecklist, idBase: 3)
    let seededText = (drywallForm.materials.map(\.name) + drywallForm.jobCosts.map(\.label)
        + drywallChecklist).joined(separator: " ")
    expect(!seededText.contains("$") && !seededText.contains("%"), "seeded structure carries no money or percent figures")
    expect(drywallForm.jobCosts.count == drywall.seedJobCosts.count, "seeded direct costs")
    expect(drywallForm.jobCosts.allSatisfy { $0.unitCostText == "0" && $0.markupPercentText == "0" },
           "seeded direct costs carry no prices or markups")
}

// MARK: - AI suggestion panel

private func testSuggestionRows() {
    let suggestion = NativeAIPricingSuggestion(
        laborHours: .init(suggested: decimal("3"), reasoning: "Typical for this scope."),
        laborRate: .init(suggested: decimal("95"), reasoning: "Local market rate."),
        materials: [.init(name: "PEX", suggestedUnitCost: decimal("3.5"), reasoning: "Supplier average.")],
        overallRange: .init(low: decimal("800"), mid: decimal("1000"), high: decimal("1300"), reasoning: "Regional range.")
    )
    let rows = NativePricebookSuggestion.rows(suggestion)
    expectEqual(rows.map(\.id), ["laborHours", "laborRate", "material-PEX", "overallRange"],
                "rows render in RN's order")
    expectEqual(rows[0].title, "Labor: 3 hrs", "labor hours row copy")
    expectEqual(rows[1].title, "Rate: $95/hr", "labor rate row copy")
    expectEqual(rows[2].title, "PEX: $3.50", "material row copy")
    expectEqual(rows[3].title, "Market range: $800 – $1,300", "range row copy")
    expectEqual(rows[3].reasoning, "Regional range.", "reasoning is carried")
    expect(rows[3].applyTitle == nil, "the market range is display-only")

    var form = NativePricebookForm()
    form.name = "Repipe"
    NativePricebookSuggestion.applying(rows[0], to: &form, idBase: 1)
    expectEqual(form.laborHoursText, "3", "applying labor hours edits only that field")
    expectEqual(form.laborRateText, "", "applying hours does not touch the rate")
    NativePricebookSuggestion.applying(rows[1], to: &form, idBase: 1)
    expectEqual(form.laborRateText, "95", "applying the rate")
    NativePricebookSuggestion.applying(rows[2], to: &form, idBase: 1)
    expectEqual(form.materials.count, 1, "an unknown material is appended at quantity 1")
    expectEqual(form.materials.first?.quantityText, "1", "appended material quantity")
    expectEqual(form.materials.first?.unitCostText, "3.5", "appended material cost")

    // Applying again updates the matching row instead of duplicating it.
    let updateRows = NativePricebookSuggestion.rows(NativeAIPricingSuggestion(
        laborHours: .init(suggested: nil, reasoning: nil),
        laborRate: .init(suggested: nil, reasoning: nil),
        materials: [.init(name: "pex", suggestedUnitCost: decimal("4"), reasoning: nil)],
        overallRange: .init(low: nil, mid: nil, high: nil, reasoning: nil)
    ))
    NativePricebookSuggestion.applying(updateRows[0], to: &form, idBase: 1)
    expectEqual(form.materials.count, 1, "a case-insensitive name match updates in place")
    expectEqual(form.materials.first?.unitCostText, "4", "the matched material cost is replaced")

    // A suggestion with nothing used reports no rows (never a fake row).
    let empty = NativePricebookSuggestion.rows(NativeAIPricingSuggestion(
        laborHours: .init(suggested: nil, reasoning: nil),
        laborRate: .init(suggested: nil, reasoning: nil),
        materials: [],
        overallRange: .init(low: nil, mid: nil, high: nil, reasoning: nil)
    ))
    expect(empty.isEmpty, "an empty suggestion has no rows")

    // A material without a cost is display-only.
    let noCost = NativePricebookSuggestion.rows(NativeAIPricingSuggestion(
        laborHours: .init(suggested: nil, reasoning: nil),
        laborRate: .init(suggested: nil, reasoning: nil),
        materials: [.init(name: "Tape", suggestedUnitCost: nil, reasoning: "Check locally.")],
        overallRange: .init(low: nil, mid: nil, high: nil, reasoning: nil)
    ))
    expect(noCost.count == 1 && noCost[0].applyTitle == nil, "a costless material cannot be applied")
    expectEqual(noCost[0].title, "Tape: —", "a costless material shows a dash")
}

// MARK: - Job prefill

private func testJobPrefill() {
    let draft = NativePricebookEntryDraft(
        name: "Water heater swap",
        description: nil,
        category: "Plumbing",
        laborHours: decimal("3"),
        laborBreakdown: nil,
        laborRate: decimal("95"),
        materials: [material(#"{"id":"m1","name":"Tank","quantity":1,"unitCost":600}"#)],
        materialMarkup: decimal("10"),
        jobCosts: [],
        overhead: decimal("12"),
        margin: decimal("18")
    )
    let jobDraft = NativeJobPricingDraft(job: job(), settings: nil)
    let prefilled = NativePricebookPrefill.applying(draft, to: jobDraft)

    expectEqual(prefilled.jobID, jobDraft.jobID, "the prefill targets the chosen job")
    expectEqual(prefilled.laborHours, decimal("3"), "labor hours move")
    expectEqual(prefilled.laborRate, decimal("95"), "labor rate moves")
    expectEqual(prefilled.materials.first?.name, "Tank", "materials move")
    expectEqual(prefilled.materialMarkup, decimal("10"), "material markup moves")
    expectEqual(prefilled.overheadPercent, decimal("12"), "overhead moves")
    expectEqual(prefilled.marginPercent, decimal("18"), "margin moves")
    expectEqual(prefilled.minimumJobFee, jobDraft.minimumJobFee, "the job's own minimum fee is kept")
    expectEqual(prefilled.travelMiles, jobDraft.travelMiles, "travel miles are untouched")
    expectEqual(prefilled.travelFeePerMile, jobDraft.travelFeePerMile, "travel rate is untouched")
    expectEqual(prefilled.emergencyMultiplier, jobDraft.emergencyMultiplier, "the emergency multiplier is untouched")
    expectEqual(prefilled.taxPercent, jobDraft.taxPercent, "tax stays untouched")
    expect(prefilled.isEmergency == jobDraft.isEmergency, "the emergency flag is untouched")

    // A job that already has its own values keeps them until the prefill runs.
    let untouched = NativeJobPricingDraft(job: job(#"{"id":"j2","laborHours":8,"laborRate":120}"#), settings: nil)
    expectEqual(untouched.laborHours, decimal("8"), "a job keeps its own hours before any prefill")
}

// MARK: - Run

testList()
testForm()
testJobCosts()
testTemplates()
testSuggestionRows()
testJobPrefill()

if failures == 0 {
    print("Pricebook UI tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
