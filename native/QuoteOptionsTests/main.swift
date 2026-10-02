import Foundation

// Phase 25 good/better/best quote options: canonical shape, pure domain,
// adapters and consumers. Spec: docs/superpowers/specs/2026-10-02-quote-options-design.md

private var failures = 0
private var checks = 0
private let decoder = JSONDecoder()
private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    guard (try? condition()) == true else {
        failures += 1
        print("FAIL: \(label)")
        return
    }
}

private func run(_ label: String, _ body: () throws -> Void) {
    do { try body() }
    catch {
        failures += 1
        print("FAIL: \(label) — \(error)")
    }
}

private func d(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
    try decoder.decode(Canonical.JSONValue.self, from: encoder.encode(value))
}

private func object<T: Encodable>(_ value: T) throws -> [String: Canonical.JSONValue] {
    guard case let .object(fields) = try json(value) else {
        throw NSError(domain: "QuoteOptionsTests", code: 1)
    }
    return fields
}

private func decode<T: Decodable>(_ type: T.Type = T.self, _ value: Canonical.JSONValue) throws -> T {
    try decoder.decode(T.self, from: encoder.encode(value))
}

private func sameJSON<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
    (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
}

/// Recursively true when any object in `value` has `key`.
private func containsKey(_ key: String, in value: Canonical.JSONValue) -> Bool {
    switch value {
    case let .object(fields):
        return fields.keys.contains(key) || fields.values.contains { containsKey(key, in: $0) }
    case let .array(values):
        return values.contains { containsKey(key, in: $0) }
    default:
        return false
    }
}

private func baseJob(
    status: String = "estimate_sent",
    extra: [String: Canonical.JSONValue] = [:]
) throws -> Canonical.Job {
    var fields: [String: Canonical.JSONValue] = [
        "id": .string("job-q"), "customerId": .string("c-1"), "customerName": .string("Grace Hopper"),
        "title": .string("AC replacement"), "description": .string("Replace the failed unit"),
        "status": .string(status), "address": .string("1 Navy Way"),
        "estimateTotal": .number(d("261.25")), "laborHours": .number(2), "laborRate": .number(95),
        "materials": .array([]), "materialMarkup": .number(0), "overhead": .number(10), "margin": .number(20),
        "notes": .string(""), "createdAt": .string("2026-10-01T12:00:00.000Z"),
        "futureJobField": .string("kept")
    ]
    for (key, value) in extra { fields[key] = value }
    return try decode(Canonical.Job.self, .object(fields))
}

private func sequentialIDs(_ prefix: String) -> () -> String {
    var next = 0
    return {
        next += 1
        return "\(prefix)\(next)"
    }
}

private func material(_ id: String, _ name: String, _ quantity: String, _ unitCost: String) throws -> Canonical.Material {
    var value = try CanonicalUIAdapters.newPricingMaterial(id: id)
    value.name = name
    value.quantity = d(quantity)
    value.unitCost = d(unitCost)
    return value
}

private func jobCost(
    _ id: String, label: String, category: String, quantity: String, unitCost: String,
    markupPercent: String, policy: String, visible: Bool, taxable: Bool = false
) throws -> Canonical.JobCost {
    var value = try CanonicalUIAdapters.newPricingJobCost(id: id)
    value.label = label
    value.category = category
    value.quantity = d(quantity)
    value.unitCost = d(unitCost)
    value.markupPercent = d(markupPercent)
    value.markupPolicy = policy
    value.customerVisible = visible
    value.taxable = taxable
    return value
}

// MARK: - Per-tier pricing fixtures (hand-computed goldens)
//
// PricingEngine.calculate (FinancialDomain.swift), with no travel, no
// emergency, no tax, minimum fee 75 (nil settings):
//   subtotal = labor + marked-up materials + in-margin direct costs
//   preTax   = subtotal × (1 + overhead%) / (1 − margin%)
//   total    = max(preTax, 75) + passthrough direct costs
//
// Repair (tier 1): 2 h × 95 = 190; × 1.10 = 209; / 0.80 = 261.25.
// Standard (tier 2): 6 h × 95 = 570; materials 2 × 350.10 = 700.20 × 1.25 =
//   875.25; subtotal 1445.25; × 1.15 = 1662.0375; / 0.75 = 2216.05; + permit
//   120 passthrough = 2336.05.
// High-efficiency (tier 3): 8 h × 110 = 880; materials 2400 + 3 × 15.5 =
//   2446.5 × 1.20 = 2935.8; crane 200 × 1.10 = 220 and haul-off 50 (both in
//   margin base); subtotal 4085.8; × 1.12 = 4576.096; / 0.70 = 6537.28.
private let repairGolden = d("261.25")
private let standardGolden = d("2336.05")
private let premiumGolden = d("6537.28")

private func repairDraft(_ job: Canonical.Job, _ tier: Canonical.QuoteTier) -> NativeJobPricingDraft {
    var draft = NativeJobPricingDraft(job: job, tier: tier, settings: nil)
    draft.laborHours = 2; draft.laborRate = 95; draft.materials = []; draft.materialMarkup = 0
    draft.jobCosts = []; draft.overheadPercent = 10; draft.marginPercent = 20
    return draft
}

private func standardDraft(_ job: Canonical.Job, _ tier: Canonical.QuoteTier) throws -> NativeJobPricingDraft {
    var draft = NativeJobPricingDraft(job: job, tier: tier, settings: nil)
    draft.laborHours = 6; draft.laborRate = 95
    draft.materials = [try material("m-std", "Standard condenser", "2", "350.10")]
    draft.materialMarkup = 25
    draft.jobCosts = [try jobCost("jc-permit", label: "City permit", category: "permit", quantity: "1",
                                  unitCost: "120", markupPercent: "0", policy: "passthrough", visible: true)]
    draft.overheadPercent = 15; draft.marginPercent = 25
    return draft
}

private func premiumDraft(_ job: Canonical.Job, _ tier: Canonical.QuoteTier) throws -> NativeJobPricingDraft {
    var draft = NativeJobPricingDraft(job: job, tier: tier, settings: nil)
    draft.laborHours = 8; draft.laborRate = 110
    draft.materials = [
        try material("m-he", "High-efficiency condenser", "1", "2400"),
        try material("m-pad", "Pad", "3", "15.5")
    ]
    draft.materialMarkup = 20
    draft.jobCosts = [
        try jobCost("jc-crane", label: "Crane rental", category: "rental", quantity: "1", unitCost: "200",
                    markupPercent: "10", policy: "in_margin_base", visible: false, taxable: true),
        try jobCost("jc-haul", label: "Haul-off fee", category: "disposal", quantity: "1", unitCost: "50",
                    markupPercent: "0", policy: "in_margin_base", visible: true, taxable: true)
    ]
    draft.overheadPercent = 12; draft.marginPercent = 30
    return draft
}

/// Three priced tiers (ids qt_1…qt_3, Repair recommended) and two add-ons
/// (qa_1 haul away $150 with $60 internal cost, qa_2 thermostat $49.99).
private func optionsJob(status: String = "estimate_sent") throws -> Canonical.Job {
    let tierIDs = sequentialIDs("qt_")
    let addOnIDs = sequentialIDs("qa_")
    var job = try NativeQuoteOptions.startOptions(job: try baseJob(status: status), makeTierID: tierIDs)
    job = try NativeQuoteOptions.duplicateTier(job: job, tierID: "qt_2", makeTierID: tierIDs)
    job = try NativeQuoteOptions.renameTier(job: job, tierID: "qt_1", name: "Repair")
    job = try NativeQuoteOptions.renameTier(job: job, tierID: "qt_2", name: "Standard unit")
    job = try NativeQuoteOptions.renameTier(job: job, tierID: "qt_3", name: "High-efficiency unit")
    job = try NativeQuoteOptions.describeTier(job: job, tierID: "qt_1", description: "Replace the failed capacitor.")
    job = try NativeQuoteOptions.tierPricingSaved(job: job, tierID: "qt_1",
                                                  draft: repairDraft(job, job.quoteOptions!.tier(id: "qt_1")!))
    job = try NativeQuoteOptions.tierPricingSaved(job: job, tierID: "qt_2",
                                                  draft: try standardDraft(job, job.quoteOptions!.tier(id: "qt_2")!))
    job = try NativeQuoteOptions.tierPricingSaved(job: job, tierID: "qt_3",
                                                  draft: try premiumDraft(job, job.quoteOptions!.tier(id: "qt_3")!))
    job = try NativeQuoteOptions.addAddOn(
        job: job, draft: NativeQuoteAddOnDraft(label: "Haul away old unit", price: 150, cost: 60), makeAddOnID: addOnIDs
    )
    job = try NativeQuoteOptions.addAddOn(
        job: job,
        draft: NativeQuoteAddOnDraft(label: "Wi-Fi thermostat", description: "Installed and paired.", price: d("49.99")),
        makeAddOnID: addOnIDs
    )
    return job
}

private func pricingMatches(_ job: Canonical.Job, _ tier: Canonical.QuoteTier) -> Bool {
    job.laborHours == tier.laborHours
        && job.laborRate == tier.laborRate
        && job.materialMarkup == tier.materialMarkup
        && job.overhead == tier.overhead
        && job.margin == tier.margin
        && sameJSON(job.materials, tier.materials)
        && sameJSON(job.jobCosts, tier.jobCosts)
        && sameJSON(job.laborBreakdown, tier.laborBreakdown)
}

private func approval(
    for job: Canonical.Job,
    decision: String?,
    selection: Canonical.EstimateSelection? = nil
) throws -> Canonical.EstimateApproval {
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: job, customerName: nil, businessName: "Hopper HVAC"
    )
    var approval = try CanonicalUIAdapters.estimateApprovalAfterLink(
        existing: nil, snapshot: snapshot, token: String(repeating: "t", count: 48),
        sentAt: "2026-10-02T09:00:00.000Z"
    )
    approval.decision = decision
    if decision != nil { approval.consentAt = "2026-10-02T10:30:00.000Z" }
    approval.selection = selection
    return approval
}

// MARK: - Shared selection vectors (spec §3)

run("shared selection vectors") {
    guard let path = ProcessInfo.processInfo.environment["QUOTE_SELECTION_VECTORS"] else {
        throw NSError(domain: "QuoteOptionsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "QUOTE_SELECTION_VECTORS is not set"])
    }
    let root = try decoder.decode(Canonical.JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard case let .object(fixture) = root,
          case let .object(snapshotFields)? = fixture["snapshots"],
          case let .array(vectors)? = fixture["vectors"]
    else { throw NSError(domain: "QuoteOptionsTests", code: 3) }
    let snapshots = try snapshotFields.mapValues { try decode(Canonical.EstimateApprovalSnapshot.Options.self, $0) }

    var asserted = 0
    var expectedCount = 0
    for case let .object(vector) in vectors {
        guard case let .string(name)? = vector["name"] else { continue }
        if case .bool(true)? = vector["jsOnly"] { continue }
        expectedCount += 1
        guard case let .string(snapshotName)? = vector["snapshot"],
              let options = snapshots[snapshotName],
              case let .object(input)? = vector["input"],
              case let .object(expected)? = vector["expect"]
        else { expect(false, "\(name): vector is well formed"); continue }

        var tierID: String?
        if case let .string(value)? = input["tierId"] { tierID = value }
        var addOnIDs: [String] = []
        if case let .array(values)? = input["addOnIds"] {
            addOnIDs = values.compactMap { if case let .string(id) = $0 { return id }; return nil }
            expect(addOnIDs.count == values.count, "\(name): Swift vectors carry only string add-on ids")
        }

        let result = NativeQuoteOptions.resolveSelection(snapshotOptions: options, tierId: tierID, addOnIds: addOnIDs)
        switch (expected["ok"], result) {
        case (.bool(true)?, .success(let selection)):
            let expectedIDs: [String] = {
                guard case let .array(ids)? = expected["addOnIds"] else { return [] }
                return ids.compactMap { if case let .string(id) = $0 { return id }; return nil }
            }()
            let expectedLines: [Canonical.EstimateApprovalSnapshot.LineItem] = {
                guard case let .array(lines)? = expected["lineItems"] else { return [] }
                return (try? lines.map { try decode(Canonical.EstimateApprovalSnapshot.LineItem.self, $0) }) ?? []
            }()
            expect(selection.tierId == tierID, "\(name): tier id")
            expect(expected["tierName"] == .string(selection.tierName), "\(name): tier name")
            expect(selection.addOnIds == expectedIDs, "\(name): add-on ids normalized to snapshot order")
            expect(selection.addOns.map(\.id) == expectedIDs, "\(name): add-on details follow the ids")
            expect(expected["total"] == .number(selection.total), "\(name): integer-cent total \(selection.total)")
            expect(selection.lineItems == expectedLines, "\(name): tier lines then add-on lines")
            asserted += 1
        case (.bool(false)?, .failure(let error)):
            expect(expected["error"] == .string(error.rawValue), "\(name): error code \(error.rawValue)")
            asserted += 1
        default:
            expect(false, "\(name): expected ok=\(String(describing: expected["ok"])), got \(result)")
        }
    }
    expect(expectedCount == 10 && asserted == expectedCount, "every Swift-expressible vector is asserted (\(asserted)/\(expectedCount))")
    expect(NativeQuoteSelectionError.chooseOption.message == "Please choose an option."
           && NativeQuoteSelectionError.invalidAddOns.message == "Invalid add-on selection.",
           "selection errors carry the Worker's copy")
}

run("selection total is computed in integer cents") {
    expect(NativeQuoteOptions.selectionTotal(tierTotal: d("0.1"), addOnAmounts: [d("0.2")]) == d("0.3"), "0.1 + 0.2 = 0.3")
    expect(NativeQuoteOptions.selectionTotal(tierTotal: d("100.1"), addOnAmounts: [d("0.2"), d("0.1")]) == d("100.4"),
           "100.1 + 0.2 + 0.1 = 100.4")
    expect(NativeQuoteOptions.selectionTotal(tierTotal: d("1850.5"), addOnAmounts: []) == d("1850.5"), "tier only")
}

// MARK: - Per-tier engine goldens and M1

run("per-tier PricingEngine goldens") {
    let job = try optionsJob()
    let options = job.quoteOptions!
    expect(options.tiers.map(\.id) == ["qt_1", "qt_2", "qt_3"], "three tiers in order")
    expect(options.tiers.map(\.name) == ["Repair", "Standard unit", "High-efficiency unit"], "tier names")
    expect(options.tier(id: "qt_1")?.estimateTotal == repairGolden, "Repair tier total 261.25")
    expect(options.tier(id: "qt_2")?.estimateTotal == standardGolden, "Standard tier total 2336.05")
    expect(options.tier(id: "qt_3")?.estimateTotal == premiumGolden, "High-efficiency tier total 6537.28")
    let tier = options.tier(id: "qt_3")!
    expect(PricingEngine.calculate(try premiumDraft(job, tier).input).total == premiumGolden,
           "engine golden matches the stored tier total")
    expect(tier.materials.count == 2 && tier.jobCosts?.count == 2 && tier.laborRate == 110,
           "tier stores the calculator block")
    expect(options.tier(id: "qt_2")?.jobCosts?.first?.markupPolicy == "passthrough",
           "tier stores direct-cost policies")
}

run("M1: before acceptance the job mirrors the recommended tier") {
    var job = try optionsJob()
    let recommended = job.quoteOptions!.tier(id: "qt_1")!
    expect(job.quoteOptions?.recommendedTierId == "qt_1", "starting options recommends tier 1")
    expect(pricingMatches(job, recommended) && job.estimateTotal == repairGolden,
           "saving the recommended tier mirrors it; saving other tiers leaves the job alone")

    job = try NativeQuoteOptions.setRecommendedTier(job: job, tierID: "qt_2")
    let standard = job.quoteOptions!.tier(id: "qt_2")!
    expect(pricingMatches(job, standard) && job.estimateTotal == standardGolden,
           "setting the recommended tier mirrors its pricing and total")

    // The job-level calculator writes the recommended tier too.
    var draft = NativeJobPricingDraft(job: job, settings: nil)
    draft.laborHours = 7
    let saved = try CanonicalUIAdapters.canonical(from: draft, baseline: job)
    let expectedTotal = PricingEngine.calculate(draft.input).total
    expect(saved.estimateTotal == expectedTotal && saved.laborHours == 7, "job-level save prices the job")
    expect(saved.quoteOptions?.tier(id: "qt_2")?.laborHours == 7
           && saved.quoteOptions?.tier(id: "qt_2")?.estimateTotal == expectedTotal,
           "job-level save writes the recommended tier (M1)")
    expect(pricingMatches(saved, saved.quoteOptions!.tier(id: "qt_2")!), "job and recommended tier stay equal")
    expect(sameJSON(saved.quoteOptions?.tier(id: "qt_1"), job.quoteOptions?.tier(id: "qt_1"))
           && sameJSON(saved.quoteOptions?.tier(id: "qt_3"), job.quoteOptions?.tier(id: "qt_3")),
           "job-level save leaves other tiers untouched")
    expect(saved.preservation.unknownFields["futureJobField"] == .string("kept"), "unknown job fields survive")

    // Plain jobs keep the pre-Phase-25 behavior exactly.
    let plain = try baseJob()
    let plainSaved = try CanonicalUIAdapters.canonical(
        from: NativeJobPricingDraft(job: plain, settings: nil), baseline: plain
    )
    expect(plainSaved.quoteOptions == nil && plainSaved.estimateTotal == repairGolden, "single-total save is unchanged")
    expect((try object(plainSaved))["quoteOptions"] == nil, "single-total job never gains a quoteOptions key")

    do {
        _ = try CanonicalUIAdapters.canonical(from: draft, tierID: "qt_missing", baseline: job)
        expect(false, "tier save to an unknown tier throws")
    } catch CanonicalUIAdapterError.invalidCanonicalRecord("quote-tier-id") {
        expect(true, "unknown tier is rejected")
    }
}

// MARK: - Acceptance, M2 and M3

run("M2: acceptance mirrors the accepted tier plus add-ons") {
    let job = try optionsJob()
    let accepted = try NativeQuoteOptions.applyAcceptance(
        job: job, tierId: "qt_3", addOnIds: ["qa_2", "qa_1", "qa_2"],
        acceptedAt: "2026-10-02T11:00:00.000Z", source: Canonical.QuoteAcceptance.sourceOwner
    )
    let tier = accepted.quoteOptions!.tier(id: "qt_3")!
    let acceptance = accepted.quoteOptions!.acceptance!
    expect(pricingMatches(accepted, tier), "accepted tier pricing becomes the job's")
    expect(accepted.estimateTotal == d("6737.27") && acceptance.total == d("6737.27"),
           "estimateTotal = tier 6537.28 + 150 + 49.99")
    expect(acceptance.tierId == "qt_3" && acceptance.addOnIds == ["qa_1", "qa_2"]
           && acceptance.source == "owner" && acceptance.acceptedAt == "2026-10-02T11:00:00.000Z",
           "acceptance records de-duplicated ids in add-on order")
    expect(accepted.status == job.status, "applyAcceptance never changes status")

    // Job-level calculator after acceptance writes the accepted tier.
    var draft = NativeJobPricingDraft(job: accepted, settings: nil)
    draft.laborHours = 9
    let saved = try CanonicalUIAdapters.canonical(from: draft, baseline: accepted)
    let engine = PricingEngine.calculate(draft.input).total
    expect(saved.quoteOptions?.tier(id: "qt_3")?.estimateTotal == engine
           && saved.quoteOptions?.tier(id: "qt_3")?.laborHours == 9,
           "post-acceptance job save writes the accepted tier")
    expect(saved.estimateTotal == NativeQuoteOptions.selectionTotal(tierTotal: engine, addOnAmounts: [150, d("49.99")]),
           "post-acceptance estimateTotal = engine total + accepted add-ons")
    expect(sameJSON(saved.quoteOptions?.tier(id: "qt_1"), accepted.quoteOptions?.tier(id: "qt_1")),
           "post-acceptance job save leaves the recommended tier alone")
    expect(sameJSON(saved.quoteOptions?.acceptance, accepted.quoteOptions?.acceptance),
           "a calculator save never rewrites the acceptance")

    // Tier-targeted saves: the accepted tier mirrors, another tier does not.
    var tierDraft = NativeJobPricingDraft(job: accepted, tier: tier, settings: nil)
    tierDraft.laborHours = 10
    let tierSaved = try NativeQuoteOptions.tierPricingSaved(job: accepted, tierID: "qt_3", draft: tierDraft)
    let tierEngine = PricingEngine.calculate(tierDraft.input).total
    expect(tierSaved.laborHours == 10
           && tierSaved.estimateTotal == NativeQuoteOptions.selectionTotal(tierTotal: tierEngine, addOnAmounts: [150, d("49.99")]),
           "saving the accepted tier mirrors it with the add-ons")
    var otherDraft = NativeJobPricingDraft(job: accepted, tier: accepted.quoteOptions!.tier(id: "qt_1")!, settings: nil)
    otherDraft.laborHours = 3
    let otherSaved = try NativeQuoteOptions.tierPricingSaved(job: accepted, tierID: "qt_1", draft: otherDraft)
    expect(otherSaved.quoteOptions?.tier(id: "qt_1")?.laborHours == 3
           && otherSaved.estimateTotal == accepted.estimateTotal
           && otherSaved.laborHours == accepted.laborHours,
           "saving a non-mirrored tier leaves the job alone")
}

run("M3: acceptance is written once and options lock") {
    let job = try optionsJob()
    let accepted = try NativeQuoteOptions.applyAcceptance(
        job: job, tierId: "qt_2", addOnIds: [], acceptedAt: "2026-10-02T11:00:00.000Z", source: "owner"
    )
    let again = try NativeQuoteOptions.applyAcceptance(
        job: accepted, tierId: "qt_3", addOnIds: ["qa_1"], acceptedAt: "2026-10-03T11:00:00.000Z",
        source: "link", consentedTotal: 999
    )
    expect(sameJSON(again, accepted), "re-applying an acceptance is a no-op")
    expect(NativeQuoteOptions.isReadOnly(accepted) && !NativeQuoteOptions.isReadOnly(job), "acceptance makes options read-only")

    let refusals: [(String, () throws -> Canonical.Job)] = [
        ("rename", { try NativeQuoteOptions.renameTier(job: accepted, tierID: "qt_1", name: "New") }),
        ("describe", { try NativeQuoteOptions.describeTier(job: accepted, tierID: "qt_1", description: "x") }),
        ("recommend", { try NativeQuoteOptions.setRecommendedTier(job: accepted, tierID: "qt_3") }),
        ("duplicate", { try NativeQuoteOptions.duplicateTier(job: accepted, tierID: "qt_1") }),
        ("delete", { try NativeQuoteOptions.deleteTier(job: accepted, tierID: "qt_3") }),
        ("remove", { try NativeQuoteOptions.removeOptions(job: accepted, keepingTierID: "qt_2") }),
        ("add add-on", { try NativeQuoteOptions.addAddOn(job: accepted, draft: .init(label: "X", price: 1)) }),
        ("edit add-on", { try NativeQuoteOptions.editAddOn(job: accepted, addOnID: "qa_1", draft: .init(label: "X", price: 1)) }),
        ("delete add-on", { try NativeQuoteOptions.deleteAddOn(job: accepted, addOnID: "qa_1") })
    ]
    for (name, attempt) in refusals {
        do { _ = try attempt(); expect(false, "\(name) is refused after acceptance") }
        catch NativeQuoteOptionsError.readOnly { expect(true, "\(name) is refused after acceptance") }
    }

    var approvedOnly = job
    approvedOnly.approval = try approval(for: job, decision: "approved")
    expect(NativeQuoteOptions.isReadOnly(approvedOnly), "an approved approval locks options before reconciliation")
    do { _ = try NativeQuoteOptions.renameTier(job: approvedOnly, tierID: "qt_1", name: "New"); expect(false, "rename after approval") }
    catch NativeQuoteOptionsError.readOnly { expect(true, "edits are refused once the customer approved") }
    do { _ = try NativeQuoteOptions.startOptions(job: try baseJob(extra: ["approval": try json(approvedOnly.approval!)])); expect(false, "start after approval") }
    catch NativeQuoteOptionsError.readOnly { expect(true, "options cannot start on an approved estimate") }
}

run("applyAcceptance: tier drift, missing tier, and owner validation") {
    let job = try optionsJob()
    // Tier drift: the tier was edited after sending; the consented price wins.
    let drifted = try NativeQuoteOptions.applyAcceptance(
        job: job, tierId: "qt_2", addOnIds: ["qa_1"], acceptedAt: "2026-10-02T10:30:00.000Z",
        source: Canonical.QuoteAcceptance.sourceLink, consentedTotal: d("2400.5")
    )
    expect(pricingMatches(drifted, job.quoteOptions!.tier(id: "qt_2")!), "drift keeps the current tier pricing")
    expect(drifted.estimateTotal == d("2400.5") && drifted.quoteOptions?.acceptance?.total == d("2400.5"),
           "drift uses the consented total, not the current tier + add-ons")
    expect(drifted.quoteOptions?.acceptance?.source == "link", "link source recorded")

    // Missing tier: pricing stays, consented total and acceptance recorded.
    let missing = try NativeQuoteOptions.applyAcceptance(
        job: job, tierId: "qt_gone", addOnIds: ["qa_2", "qa_unknown"], acceptedAt: "2026-10-02T10:30:00.000Z",
        source: "link", consentedTotal: d("1999.99")
    )
    expect(pricingMatches(missing, job.quoteOptions!.tier(id: "qt_1")!), "a missing tier leaves the job pricing as it was")
    expect(missing.estimateTotal == d("1999.99"), "a missing tier still sets the consented total")
    expect(missing.quoteOptions?.acceptance?.tierId == "qt_gone"
           && missing.quoteOptions?.acceptance?.addOnIds == ["qa_2", "qa_unknown"],
           "a missing tier still records the acceptance (unknown ids last)")

    do {
        _ = try NativeQuoteOptions.applyAcceptance(job: job, tierId: "qt_gone", addOnIds: [], acceptedAt: "x", source: "owner")
        expect(false, "owner acceptance needs a real tier")
    } catch NativeQuoteOptionsError.tierNotFound { expect(true, "owner acceptance of a missing tier is refused") }
    do {
        _ = try NativeQuoteOptions.applyAcceptance(job: job, tierId: "qt_1", addOnIds: ["qa_x"], acceptedAt: "x", source: "owner")
        expect(false, "owner acceptance needs real add-ons")
    } catch NativeQuoteOptionsError.addOnNotFound { expect(true, "owner acceptance of a missing add-on is refused") }
    do {
        _ = try NativeQuoteOptions.applyAcceptance(job: try baseJob(), tierId: "qt_1", addOnIds: [], acceptedAt: "x", source: "owner")
        expect(false, "a single-total job has nothing to accept")
    } catch NativeQuoteOptionsError.noOptions { expect(true, "applyAcceptance requires options") }
}

// MARK: - Snapshot shapes

run("snapshot options: shape, recommended top level, no cost leak") {
    let job = try optionsJob()
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(job: job, customerName: nil, businessName: "Hopper HVAC")
    guard let options = snapshot.options else { expect(false, "unaccepted options produce snapshot.options"); return }
    expect(options.recommendedTierId == "qt_1" && options.tiers.map(\.id) == ["qt_1", "qt_2", "qt_3"],
           "options carry every tier and the recommended id")
    expect(options.tiers.map(\.total) == [repairGolden, standardGolden, premiumGolden], "tier totals are the stored engine totals")
    let recommended = options.tiers[0]
    expect(snapshot.lineItems == recommended.lineItems && snapshot.total == recommended.total,
           "top-level lines and total are the recommended tier's")
    expect(recommended.description == "Replace the failed capacitor." && options.tiers[1].description == nil,
           "descriptions are frozen when set and omitted otherwise")

    let premium = options.tiers[2]
    let premiumLabels = premium.lineItems.map(\.label)
    expect(premiumLabels == ["Labor (8 hrs @ $110/hr)", "Materials (2 items)", "Haul-off fee", "Overhead & operating costs"],
           "tier lines use today's derivation on the tier's own pricing")
    expect(premium.lineItems.map(\.amount) == [880, d("2935.8"), 50, d("2671.48")],
           "hidden crane rental folds into the residual (6537.28 − 880 − 2935.8 − 50)")
    let standard = options.tiers[1]
    expect(standard.lineItems.map(\.label) == ["Labor (6 hrs @ $95/hr)", "Materials (1 item)", "City permit", "Overhead & operating costs"]
           && standard.lineItems.last?.amount == d("770.8"),
           "standard tier residual = 2336.05 − 570 − 875.25 − 120")

    expect(options.addOns.map(\.id) == ["qa_1", "qa_2"] && options.addOns.map(\.amount) == [150, d("49.99")],
           "add-ons carry their price as amount")
    expect(options.addOns[0].description == nil && options.addOns[1].description == "Installed and paired.",
           "add-on descriptions frozen when set")
    let encoded = try json(snapshot)
    expect(!containsKey("cost", in: encoded) && !containsKey("price", in: encoded),
           "the frozen snapshot never carries the add-on cost or the job-side price key")
    expect(!containsKey("acceptance", in: encoded) && !containsKey("laborRate", in: encoded),
           "the snapshot carries no job-side option internals")
    guard case let .object(snapshotFields) = encoded,
          case let .object(optionFields)? = snapshotFields["options"],
          case let .array(addOnValues)? = optionFields["addOns"],
          case let .object(firstAddOn)? = addOnValues.first
    else { expect(false, "snapshot encodes options"); return }
    expect(Set(firstAddOn.keys) == ["id", "label", "amount"], "an add-on without a description has exactly id, label, amount")

    let direct = try NativeQuoteOptions.snapshotOptions(job: job)
    expect(direct == options, "snapshotOptions(job:) equals the builder's options")
    expect(try NativeQuoteOptions.snapshotOptions(job: try baseJob()) == nil, "single-total job has no options")

    // Device-built snapshot resolves like the shared vectors.
    if case let .success(selection) = NativeQuoteOptions.resolveSelection(
        snapshotOptions: options, tierId: "qt_3", addOnIds: ["qa_2", "qa_1"]
    ) {
        expect(selection.total == d("6737.27") && selection.addOnIds == ["qa_1", "qa_2"]
               && selection.lineItems.count == premium.lineItems.count + 2,
               "a device-built snapshot resolves to tier + add-ons")
    } else { expect(false, "device-built snapshot resolves") }

    // Exact comparison covers the typed options.
    expect(CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, snapshot), "identical option snapshots match")
    var renamed = snapshot
    renamed.options?.tiers[1].name = "Standard"
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, renamed), "a tier rename breaks the exact match")
    var repriced = snapshot
    repriced.options?.addOns[0].amount = 151
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, repriced), "an add-on price change breaks the exact match")
    var stripped = snapshot
    stripped.options = nil
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, stripped), "dropping options breaks the exact match")

    // Invalid shapes are refused before they reach the Worker.
    var broken = job
    broken.quoteOptions?.recommendedTierId = "qt_nope"
    do { _ = try CanonicalUIAdapters.estimateApprovalSnapshot(job: broken, customerName: nil, businessName: "B"); expect(false, "missing recommended tier throws") }
    catch CanonicalUIAdapterError.invalidCanonicalRecord("quote-options") { expect(true, "missing recommended tier is refused") }
    var oneTier = job
    oneTier.quoteOptions?.tiers = [job.quoteOptions!.tiers[0]]
    oneTier.quoteOptions?.recommendedTierId = "qt_1"
    do { _ = try CanonicalUIAdapters.estimateApprovalSnapshot(job: oneTier, customerName: nil, businessName: "B"); expect(false, "one tier throws") }
    catch CanonicalUIAdapterError.invalidCanonicalRecord("quote-options") { expect(true, "a single tier is refused") }
}

run("accepted snapshot: one estimate of the accepted tier plus add-on lines") {
    let accepted = try NativeQuoteOptions.applyAcceptance(
        job: try optionsJob(), tierId: "qt_3", addOnIds: ["qa_1", "qa_2"],
        acceptedAt: "2026-10-02T11:00:00.000Z", source: "owner"
    )
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(job: accepted, customerName: nil, businessName: "Hopper HVAC")
    expect(snapshot.options == nil, "an accepted estimate has no options")
    expect(snapshot.total == d("6737.27"), "total is the accepted total")
    expect(snapshot.lineItems.map(\.label) == [
        "Labor (8 hrs @ $110/hr)", "Materials (2 items)", "Haul-off fee", "Overhead & operating costs",
        "Haul away old unit", "Wi-Fi thermostat"
    ], "accepted tier lines then one line per accepted add-on")
    expect(snapshot.lineItems.map(\.amount) == [880, d("2935.8"), 50, d("2671.48"), 150, d("49.99")],
           "add-ons are subtracted before the residual line")
    let sum = snapshot.lineItems.reduce(Decimal.zero) { $0 + $1.amount }
    expect(sum == snapshot.total, "accepted lines sum to the total")
    expect(!containsKey("cost", in: try json(snapshot)), "accepted snapshot never carries add-on cost")

    let plain = try baseJob()
    let legacy = try CanonicalUIAdapters.estimateApprovalSnapshot(job: plain, customerName: nil, businessName: "Hopper HVAC")
    expect(legacy.options == nil && legacy.lineItems.map(\.label) == ["Labor (2 hrs @ $95/hr)", "Overhead & operating costs"]
           && legacy.lineItems.last?.amount == d("71.25"),
           "single-total snapshot is unchanged")
    expect((try object(legacy))["options"] == nil, "single-total snapshot has no options key")
}

// MARK: - Decision reconciler (spec §6.3)

run("reconciler: approval applies status and the link selection once") {
    let job = try optionsJob()
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(job: job, customerName: nil, businessName: "Hopper HVAC")
    guard case let .success(selection) = NativeQuoteOptions.resolveSelection(
        snapshotOptions: snapshot.options!, tierId: "qt_2", addOnIds: ["qa_1"]
    ) else { expect(false, "selection resolves"); return }
    var pending = job
    pending.approval = try approval(for: job, decision: "approved", selection: selection)

    guard let reconciled = NativeQuoteOptions.reconcileEstimateDecision(job: pending) else {
        expect(false, "an approved decision changes the job"); return
    }
    expect(reconciled.status == "approved", "estimate_sent → approved")
    let acceptance = reconciled.quoteOptions?.acceptance
    expect(acceptance?.tierId == "qt_2" && acceptance?.addOnIds == ["qa_1"] && acceptance?.source == "link"
           && acceptance?.acceptedAt == "2026-10-02T10:30:00.000Z" && acceptance?.total == d("2486.05"),
           "link selection recorded with consentAt and the consented total")
    expect(reconciled.estimateTotal == d("2486.05") && pricingMatches(reconciled, job.quoteOptions!.tier(id: "qt_2")!),
           "M2 after reconciliation")
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: reconciled) == nil, "second run is a no-op (idempotent)")

    // Selection applied once: a later tier edit never re-applies it.
    var edited = reconciled
    edited.quoteOptions?.tiers[1].estimateTotal = 1
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: edited) == nil, "an existing acceptance is never re-applied")

    // A lead with an approval also moves straight to approved.
    var lead = pending
    lead.status = "lead"
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: lead)?.status == "approved", "lead → approved")

    // The owner already advanced the status: selection still applies, status stays.
    var scheduled = pending
    scheduled.status = "scheduled"
    let scheduledResult = NativeQuoteOptions.reconcileEstimateDecision(job: scheduled)
    expect(scheduledResult?.status == "scheduled" && scheduledResult?.quoteOptions?.acceptance?.tierId == "qt_2",
           "status never moves backwards; an unapplied selection still applies")

    // Legacy approval without options: status only.
    var legacy = try baseJob()
    legacy.approval = try approval(for: legacy, decision: "approved")
    let legacyResult = NativeQuoteOptions.reconcileEstimateDecision(job: legacy)
    expect(legacyResult?.status == "approved" && legacyResult?.quoteOptions == nil
           && legacyResult?.estimateTotal == legacy.estimateTotal,
           "single-total approval only advances status")

    // An approval without a server selection (e.g. a Vercel rollback) advances
    // status and keeps the recommended tier.
    var noSelection = job
    noSelection.approval = try approval(for: job, decision: "approved")
    let noSelectionResult = NativeQuoteOptions.reconcileEstimateDecision(job: noSelection)
    expect(noSelectionResult?.status == "approved" && noSelectionResult?.quoteOptions?.acceptance == nil
           && noSelectionResult?.estimateTotal == repairGolden,
           "no selection: status only, recommended tier kept")
}

run("reconciler: declines, other statuses and non-decisions") {
    let job = try optionsJob()
    var declined = job
    declined.approval = try approval(for: job, decision: "declined")
    let result = NativeQuoteOptions.reconcileEstimateDecision(job: declined)
    expect(result?.status == "declined" && result?.quoteOptions?.acceptance == nil
           && sameJSON(result?.quoteOptions, job.quoteOptions),
           "estimate_sent → declined; options stay for revision")
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: result!) == nil, "declined is idempotent")

    for status in ["approved", "scheduled", "in_progress", "complete", "invoiced", "paid", "server_future_status"] {
        var other = declined
        other.status = status
        expect(NativeQuoteOptions.reconcileEstimateDecision(job: other) == nil, "a decline never moves \(status)")
    }
    var undecided = job
    undecided.approval = try approval(for: job, decision: nil)
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: undecided) == nil, "no decision, no change")
    var unknown = job
    unknown.approval = try approval(for: job, decision: "server_future_decision")
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: unknown) == nil, "unknown decision values are ignored")
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: job) == nil, "no approval, no change")
}

run("rebase graft keeps a server decision on a pending local edit") {
    let job = try optionsJob()
    var local = job
    local.approval = try approval(for: job, decision: nil)
    local.notes = "local pending edit"
    var server = job
    server.approval = try approval(for: job, decision: "approved")
    let historic = try approval(for: job, decision: "declined")
    server.approvalHistory = [historic]
    let grafted = NativeQuoteOptions.graftingServerDecision(onto: local, from: server)
    expect(grafted?.approval?.decision == "approved" && grafted?.notes == "local pending edit"
           && grafted?.approvalHistory?.count == 1,
           "server decision and longer history graft onto the local record")
    var otherToken = server
    otherToken.approval?.token = String(repeating: "z", count: 48)
    expect(NativeQuoteOptions.graftingServerDecision(onto: local, from: otherToken) == nil, "different token: no graft")
    expect(NativeQuoteOptions.graftingServerDecision(onto: server, from: server) == nil, "local already decided: no graft")
    expect(NativeQuoteOptions.graftingServerDecision(onto: local, from: local) == nil, "server undecided: no graft")
}

// MARK: - Consumers

run("invoice add-on lines and residual") {
    let accepted = try NativeQuoteOptions.applyAcceptance(
        job: try optionsJob(), tierId: "qt_3", addOnIds: ["qa_1", "qa_2"],
        acceptedAt: "2026-10-02T11:00:00.000Z", source: "owner"
    )
    let addOnLines = NativeQuoteOptions.invoiceAddOnLines(job: accepted)
    expect(addOnLines == [
        JobInvoiceLineDraft(description: "Haul away old unit", amount: 150, category: "other"),
        JobInvoiceLineDraft(description: "Wi-Fi thermostat", amount: d("49.99"), category: "other")
    ], "one invoice line per accepted add-on, in add-on order")
    expect(NativeQuoteOptions.invoiceAddOnLines(job: try optionsJob()).isEmpty, "no add-on lines before acceptance")

    let directCosts = (accepted.jobCosts ?? []).map { cost in
        JobInvoiceDirectCost(
            label: CanonicalUIAdapters.estimateDirectCostLabel(cost), category: cost.category,
            quantity: cost.quantity, unitCost: cost.unitCost, markupPercent: cost.markupPercent,
            markupPolicy: cost.markupPolicy, customerVisible: cost.customerVisible
        )
    }
    let materials = accepted.materials.map { (quantity: $0.quantity, unitCost: $0.unitCost) }
    let breakdown = JobInvoiceDomain.computeBillableBreakdown(
        estimateTotal: accepted.estimateTotal, laborHours: accepted.laborHours, laborRate: accepted.laborRate,
        materials: materials, materialMarkup: accepted.materialMarkup, directCosts: directCosts,
        status: "complete", timeSessions: [], changeOrders: [], addOnLines: addOnLines
    )
    expect(breakdown.overheadLine == d("2671.48"), "add-ons are subtracted before the residual overhead line")
    expect(breakdown.total == d("6737.27") && breakdown.addOnLines == addOnLines, "invoice total is the accepted total")
    let lines = JobInvoiceDomain.buildInvoiceLineItems(
        breakdown: breakdown, laborRate: accepted.laborRate, materialCount: accepted.materials.count,
        singleMaterialName: nil, approvedChangeOrders: [JobInvoiceApprovedChangeOrder(title: "Extra vent", amount: 80)]
    )
    expect(lines.map(\.category) == ["labor", "materials", "disposal", "overhead", "other", "other", "other"]
           && lines[4].description == "Haul away old unit" && lines[6].description == "Change order — Extra vent",
           "add-on lines follow the quoted lines and precede change orders")
    let quotedSum = lines.dropLast().reduce(Decimal.zero) { $0 + $1.amount }
    expect(quotedSum == accepted.estimateTotal, "invoice lines (before change orders) sum to the accepted total")

    let legacy = JobInvoiceDomain.computeBillableBreakdown(
        estimateTotal: accepted.estimateTotal, laborHours: accepted.laborHours, laborRate: accepted.laborRate,
        materials: materials, materialMarkup: accepted.materialMarkup, directCosts: directCosts,
        status: "complete", timeSessions: [], changeOrders: []
    )
    expect(legacy.overheadLine == d("2871.47") && legacy.addOnLines.isEmpty,
           "callers that pass no add-on lines keep today's residual (add-ons absorbed)")
}

run("profitability includes accepted add-on cost") {
    let unaccepted = try optionsJob()
    let accepted = try NativeQuoteOptions.applyAcceptance(
        job: unaccepted, tierId: "qt_3", addOnIds: ["qa_1", "qa_2"],
        acceptedAt: "2026-10-02T11:00:00.000Z", source: "owner"
    )
    expect(NativeQuoteOptions.acceptedAddOnCost(job: accepted) == 60, "only the add-on with a cost counts (60 + unset)")
    expect(NativeQuoteOptions.acceptedAddOnCost(job: unaccepted) == 0, "no add-on cost before acceptance")
    let input = NativeJobProfitability.input(job: accepted, invoices: [], expenses: [], laborCostRate: nil)
    expect(input.estimatedDirectCost == 310, "direct cost = crane 200 + haul-off 50 + add-on cost 60")
    expect(input.estimatedRevenue == d("6737.27"), "revenue is the accepted total")
    let before = NativeJobProfitability.input(job: unaccepted, invoices: [], expenses: [], laborCostRate: nil)
    expect(before.estimatedDirectCost == 0, "recommended Repair tier has no direct costs")
}

run("duplicate whitelist copies options without acceptance") {
    var source = try NativeQuoteOptions.applyAcceptance(
        job: try optionsJob(), tierId: "qt_3", addOnIds: ["qa_1"],
        acceptedAt: "2026-10-02T11:00:00.000Z", source: "owner"
    )
    source.approval = try approval(for: try optionsJob(), decision: "approved")
    source.quoteOptions?.preservation.unknownFields["futureOptionsField"] = .string("lifecycle")
    source.quoteOptions?.tiers[0].preservation.unknownFields["futureTierField"] = .string("tier")
    let draft = try CanonicalUIAdapters.duplicateJob(
        source, id: "job-copy", createdAt: ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    )
    let duplicate = draft.canonicalTemplate
    guard let options = duplicate.quoteOptions else { expect(false, "duplicate keeps quote options"); return }
    expect(options.acceptance == nil, "acceptance is not duplicated")
    expect(options.tiers.map(\.id) == ["qt_1", "qt_2", "qt_3"] && options.addOns.map(\.id) == ["qa_1", "qa_2"]
           && options.recommendedTierId == "qt_1", "tiers, add-ons and recommendation are copied")
    expect(sameJSON(options.tiers[2], source.quoteOptions!.tiers[2]) && sameJSON(options.addOns, source.quoteOptions!.addOns),
           "tier and add-on records are copied exactly (cost included)")
    expect(options.tiers[0].preservation.unknownFields["futureTierField"] == .string("tier"),
           "nested tier metadata is kept like nested materials")
    expect(options.preservation.unknownFields["futureOptionsField"] == nil, "the options container starts clean")
    expect(pricingMatches(duplicate, options.tiers[0]) && duplicate.estimateTotal == repairGolden,
           "the unaccepted copy mirrors the recommended tier (M1)")
    expect(duplicate.approval == nil && duplicate.status == "lead", "lifecycle still starts fresh")
    let plain = try CanonicalUIAdapters.duplicateJob(
        try baseJob(), id: "job-plain", createdAt: ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    )
    expect(try plain.canonicalTemplate.quoteOptions == nil && object(plain.canonicalTemplate)["quoteOptions"] == nil,
           "single-total duplicates gain no options key")
}

// MARK: - Tier and add-on editing

run("tier editing limits") {
    let ids = sequentialIDs("qt_")
    let base = try baseJob()
    var job = try NativeQuoteOptions.startOptions(job: base, makeTierID: ids)
    let options = job.quoteOptions!
    expect(options.tiers.map(\.name) == ["Good", "Better"] && options.addOns.isEmpty && options.recommendedTierId == "qt_1",
           "start: Good (the job's pricing) recommended, Better a duplicate")
    expect(options.tiers.allSatisfy { $0.estimateTotal == base.estimateTotal && pricingMatches(base, $0) },
           "both starting tiers carry the job's pricing and stored total")
    expect(job.estimateTotal == base.estimateTotal && pricingMatches(job, options.tiers[0]), "starting options keeps M1")
    do { _ = try NativeQuoteOptions.startOptions(job: job); expect(false, "start twice") }
    catch NativeQuoteOptionsError.alreadyHasOptions { expect(true, "options start once") }
    let defaultStart = try NativeQuoteOptions.startOptions(job: base)
    expect(defaultStart.quoteOptions!.tiers.allSatisfy { $0.id.hasPrefix("qt_") && $0.id.count == 39 },
           "default tier ids are qt_<uuid>")

    job = try NativeQuoteOptions.duplicateTier(job: job, tierID: "qt_1", makeTierID: ids)
    expect(job.quoteOptions?.tiers.last?.name == "Best" && job.quoteOptions?.tiers.last?.id == "qt_3",
           "the third tier defaults to Best")
    do { _ = try NativeQuoteOptions.duplicateTier(job: job, tierID: "qt_1", makeTierID: ids); expect(false, "fourth tier") }
    catch NativeQuoteOptionsError.tierLimitReached { expect(true, "max three tiers") }

    // Deleting the recommended tier recommends and mirrors the first remaining.
    var repriced = job
    repriced.quoteOptions?.tiers[1].estimateTotal = 500
    repriced.quoteOptions?.tiers[1].laborHours = 4
    let afterDelete = try NativeQuoteOptions.deleteTier(job: repriced, tierID: "qt_1")
    expect(afterDelete.quoteOptions?.recommendedTierId == "qt_2" && afterDelete.estimateTotal == 500
           && afterDelete.laborHours == 4, "deleting the recommended tier mirrors the new recommendation")
    do { _ = try NativeQuoteOptions.deleteTier(job: afterDelete, tierID: "qt_2"); expect(false, "below two tiers") }
    catch NativeQuoteOptionsError.tierMinimumReached { expect(true, "min two tiers") }
    let reNamed = try NativeQuoteOptions.duplicateTier(job: afterDelete, tierID: "qt_2", makeTierID: ids)
    expect(reNamed.quoteOptions?.tiers.last?.name == "Good", "a duplicate takes the first unused default name")

    let removed = try NativeQuoteOptions.removeOptions(job: repriced, keepingTierID: "qt_2")
    expect(removed.quoteOptions == nil && removed.estimateTotal == 500 && removed.laborHours == 4,
           "remove options keeps that tier's pricing as the job's")
    expect((try object(removed))["quoteOptions"] == nil, "remove options drops the key")
    do { _ = try NativeQuoteOptions.removeOptions(job: repriced, keepingTierID: "qt_nope"); expect(false, "remove keeping unknown") }
    catch NativeQuoteOptionsError.tierNotFound { expect(true, "remove options needs a real tier") }

    let named = try NativeQuoteOptions.renameTier(job: job, tierID: "qt_2", name: "  Standard unit  ")
    expect(named.quoteOptions?.tier(id: "qt_2")?.name == "Standard unit", "names are trimmed")
    for bad in ["", "   ", String(repeating: "x", count: 61), String(repeating: "🔥", count: 31)] {
        do { _ = try NativeQuoteOptions.renameTier(job: job, tierID: "qt_2", name: bad); expect(false, "bad name \(bad.count)") }
        catch NativeQuoteOptionsError.invalidTierName { expect(true, "invalid name refused") }
    }
    expect((try? NativeQuoteOptions.renameTier(job: job, tierID: "qt_2", name: String(repeating: "x", count: 60))) != nil,
           "60 characters is allowed")
    let described = try NativeQuoteOptions.describeTier(job: job, tierID: "qt_2", description: "  ")
    expect(described.quoteOptions?.tier(id: "qt_2")?.description == nil, "a blank description clears it")
    do { _ = try NativeQuoteOptions.describeTier(job: job, tierID: "qt_2", description: String(repeating: "d", count: 301)); expect(false, "long description") }
    catch NativeQuoteOptionsError.tierDescriptionTooLong { expect(true, "descriptions cap at 300") }
    do { _ = try NativeQuoteOptions.renameTier(job: job, tierID: "qt_9", name: "X"); expect(false, "unknown tier") }
    catch NativeQuoteOptionsError.tierNotFound { expect(true, "unknown tier refused") }
    do { _ = try NativeQuoteOptions.renameTier(job: base, tierID: "qt_1", name: "X"); expect(false, "no options") }
    catch NativeQuoteOptionsError.noOptions { expect(true, "editing needs options") }
    expect(NativeQuoteOptions.lowestTierTotal(repriced) == base.estimateTotal && NativeQuoteOptions.lowestTierTotal(base) == nil,
           "lowest tier total for 'from $X' copy")
}

run("add-on validation and editing") {
    let ids = sequentialIDs("qa_")
    var job = try NativeQuoteOptions.startOptions(job: try baseJob(), makeTierID: sequentialIDs("qt_"))
    job = try NativeQuoteOptions.addAddOn(
        job: job, draft: NativeQuoteAddOnDraft(label: "  Surge protector ", description: " ", price: d("89.5"), cost: 40),
        makeAddOnID: ids
    )
    let added = job.quoteOptions!.addOns[0]
    expect(added.id == "qa_1" && added.label == "Surge protector" && added.description == nil
           && added.price == d("89.5") && added.cost == 40, "add-on stored trimmed with its cost")
    expect(job.estimateTotal == d("261.25"), "add-ons never change the unaccepted job total")
    let defaultID = try NativeQuoteOptions.addAddOn(job: job, draft: .init(label: "X", price: 1))
    expect(defaultID.quoteOptions!.addOns[1].id.hasPrefix("qa_") && defaultID.quoteOptions!.addOns[1].id.count == 39,
           "default add-on ids are qa_<uuid>")

    let invalid: [(NativeQuoteAddOnDraft, NativeQuoteOptionsError)] = [
        (.init(label: "", price: 1), .invalidAddOnLabel),
        (.init(label: String(repeating: "l", count: 81), price: 1), .invalidAddOnLabel),
        (.init(label: "X", description: String(repeating: "d", count: 201), price: 1), .addOnDescriptionTooLong),
        (.init(label: "X", price: 0), .invalidAddOnPrice),
        (.init(label: "X", price: -5), .invalidAddOnPrice),
        (.init(label: "X", price: d("0.001")), .invalidAddOnPrice),
        (.init(label: "X", price: d("1000000.01")), .invalidAddOnPrice),
        (.init(label: "X", price: 1, cost: -1), .invalidAddOnCost),
        (.init(label: "X", price: 1, cost: d("2.345")), .invalidAddOnCost)
    ]
    for (draft, error) in invalid {
        do { _ = try NativeQuoteOptions.addAddOn(job: job, draft: draft); expect(false, "\(error) expected") }
        catch let thrown as NativeQuoteOptionsError { expect(thrown == error, "\(error) for \(draft)") }
    }
    expect((try? NativeQuoteOptions.validated(.init(label: String(repeating: "l", count: 80), price: 1_000_000, cost: 0))) != nil,
           "limits are inclusive (80-char label, 1,000,000 price, zero cost)")

    var full = job
    for _ in 1..<NativeQuoteOptions.maxAddOns {
        full = try NativeQuoteOptions.addAddOn(job: full, draft: .init(label: "Extra", price: 5), makeAddOnID: ids)
    }
    expect(full.quoteOptions?.addOns.count == 10, "ten add-ons allowed")
    do { _ = try NativeQuoteOptions.addAddOn(job: full, draft: .init(label: "Eleventh", price: 5)); expect(false, "eleventh") }
    catch NativeQuoteOptionsError.addOnLimitReached { expect(true, "max ten add-ons") }

    var tagged = job
    tagged.quoteOptions?.addOns[0].preservation.unknownFields["futureAddOnField"] = .bool(true)
    let edited = try NativeQuoteOptions.editAddOn(
        job: tagged, addOnID: "qa_1", draft: .init(label: "Whole-home surge", description: "Panel mounted", price: 120)
    )
    let editedAddOn = edited.quoteOptions!.addOns[0]
    expect(editedAddOn.id == "qa_1" && editedAddOn.label == "Whole-home surge" && editedAddOn.description == "Panel mounted"
           && editedAddOn.price == 120 && editedAddOn.cost == nil
           && editedAddOn.preservation.unknownFields["futureAddOnField"] == .bool(true),
           "edit replaces owner fields and keeps id and metadata")
    let deleted = try NativeQuoteOptions.deleteAddOn(job: edited, addOnID: "qa_1")
    expect(deleted.quoteOptions?.addOns.isEmpty == true, "delete removes the add-on")
    do { _ = try NativeQuoteOptions.deleteAddOn(job: deleted, addOnID: "qa_1"); expect(false, "delete twice") }
    catch NativeQuoteOptionsError.addOnNotFound { expect(true, "unknown add-on refused") }
}

run("rich canonical fixture is reproduced by the device builders") {
    guard let path = ProcessInfo.processInfo.environment["CANONICAL_FIXTURE"] else {
        throw NSError(domain: "QuoteOptionsTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "CANONICAL_FIXTURE is not set"])
    }
    guard case let .object(rich) = try decoder.decode(Canonical.JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path))),
          let raw = rich["quoteOptionsJob"]
    else { throw NSError(domain: "QuoteOptionsTests", code: 5) }
    let job = try decode(Canonical.Job.self, raw)
    guard let options = job.quoteOptions, let acceptance = options.acceptance,
          let frozen = job.approval?.snapshot.options, let selection = job.approval?.selection
    else { expect(false, "fixture carries options, acceptance, snapshot options and selection"); return }

    var unaccepted = job
    unaccepted.quoteOptions?.acceptance = nil
    expect(try CanonicalUIAdapters.estimateApprovalSnapshotOptions(job: unaccepted) == frozen,
           "the device snapshot builder reproduces the fixture's frozen options")
    let resolved = NativeQuoteOptions.resolveSelection(
        snapshotOptions: frozen, tierId: selection.tierId, addOnIds: selection.addOnIds
    )
    expect((try? resolved.get()) == selection, "resolveSelection reproduces the fixture's server selection")
    expect(pricingMatches(job, options.tier(id: acceptance.tierId)!) && job.estimateTotal == acceptance.total
           && acceptance.total == selection.total,
           "the fixture job satisfies M2")
    expect(NativeQuoteOptions.reconcileEstimateDecision(job: job) == nil, "an already reconciled fixture job is left alone")
}

// MARK: - Canonical preservation

run("canonical quote types preserve absence, nulls and unknown keys") {
    let raw = """
    {"tiers":[
      {"id":"qt_a","name":"A","description":null,"laborHours":1,"laborRate":100.125,"materials":[{"id":"m","name":"Part","quantity":1,"unitCost":9.99,"futureMaterialField":1}],
       "materialMarkup":10,"overhead":15,"margin":20,"estimateTotal":150.55,"futureTierField":{"x":[1,null]}},
      {"id":"qt_b","name":"B","laborHours":2,"laborBreakdown":{"onSiteHours":2,"driveHours":0,"supplyRunHours":0,"setupCleanupHours":0},"laborRate":100,
       "materials":[],"materialMarkup":0,"jobCosts":[],"overhead":15,"margin":20,"estimateTotal":300.1}],
     "addOns":[{"id":"qa_a","label":"Add","price":12.5,"cost":null,"futureAddOnField":"y"}],
     "recommendedTierId":"qt_a",
     "acceptance":{"tierId":"qt_b","addOnIds":["qa_a"],"total":312.6,"acceptedAt":"2026-10-02T10:30:00.000Z","source":"link","futureAcceptanceField":true},
     "futureOptionsField":[1,2,3]}
    """
    let source = try decoder.decode(Canonical.JSONValue.self, from: Data(raw.utf8))
    let options = try decode(Canonical.QuoteOptions.self, source)
    expect(try json(options) == source, "quote options round-trip semantically")
    expect(options.tiers[0].description == nil && options.addOns[0].cost == nil, "explicit nulls decode as nil")
    expect(options.acceptance?.total == d("312.6") && options.tiers[0].laborRate == d("100.125"), "Decimal precision kept")
    var mutated = options
    mutated.tiers[1].name = "B2"
    let mutatedJSON = try json(mutated)
    guard case let .object(fields) = mutatedJSON, case let .array(tiers)? = fields["tiers"],
          case let .object(first)? = tiers.first else { expect(false, "mutated options encode"); return }
    expect(first["description"] == .null && first["futureTierField"] != nil && fields["futureOptionsField"] != nil,
           "mutation keeps explicit nulls and unknown fields")

    let selectionRaw = """
    {"tierId":"qt_b","tierName":"B","addOnIds":["qa_a"],"addOns":[{"id":"qa_a","label":"Add","amount":12.5}],
     "lineItems":[{"label":"Labor","amount":300.1},{"label":"Add","amount":12.5}],"total":312.6,"futureSelectionField":"z"}
    """
    let selectionSource = try decoder.decode(Canonical.JSONValue.self, from: Data(selectionRaw.utf8))
    let selection = try decode(Canonical.EstimateSelection.self, selectionSource)
    expect(try json(selection) == selectionSource, "selection round-trips semantically")
    var approvalValue = try approval(for: try optionsJob(), decision: "approved", selection: selection)
    expect(CanonicalUIAdapters.estimateApprovalsMatch(approvalValue, approvalValue), "identical approvals match")
    var other = approvalValue
    other.selection?.total = 313
    expect(!CanonicalUIAdapters.estimateApprovalsMatch(approvalValue, other), "a selection change breaks the approval match")
    approvalValue.selection = nil
    expect(!CanonicalUIAdapters.estimateApprovalsMatch(approvalValue, other), "a missing selection breaks the approval match")
}

if failures == 0 {
    print("PASS: native quote options tests (\(checks) checks)")
} else {
    print("FAILED: \(failures) native quote options test(s)")
    exit(1)
}
