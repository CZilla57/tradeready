import Foundation

// MARK: - Pricebook CRUD projection (task 9.05, requirements P1, P3)
//
// Pure field projections over the canonical `PricebookEntry` record. Create
// stamps `createdAt`/`updatedAt`; edit preserves `createdAt` (and any unknown or
// nested fields, because the projection is applied over the existing field bag);
// delete removes by exact id. The estimate total is the shared pricing engine's
// output, not a hand-rolled sum.

struct NativePricebookEntryDraft {
    var name: String
    var description: String?
    var category: String?
    var laborHours: Decimal
    var laborBreakdown: Canonical.LaborTimeBreakdown?
    var laborRate: Decimal
    var materials: [Canonical.Material]
    var materialMarkup: Decimal
    var jobCosts: [Canonical.JobCost]
    var overhead: Decimal
    var margin: Decimal
}

enum NativePricebook {
    static func fields<T: Encodable>(_ value: T) -> [String: Canonical.JSONValue] {
        NativeImportEngine.fields(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Canonical.JSONValue]) -> T? {
        NativeImportEngine.decode(type, fields)
    }

    /// The engine input for a draft, mirroring `buildEstimateInput` in
    /// PricebookEntryScreen: the entry's own overhead/margin, no travel or tax.
    static func pricingInput(_ draft: NativePricebookEntryDraft, minimumJobFee: Decimal) -> PricingInput {
        PricingInput(
            laborHours: draft.laborHours,
            laborRate: draft.laborRate,
            materials: draft.materials.map { PricingMaterial(name: $0.name, quantity: $0.quantity, unitCost: $0.unitCost) },
            materialMarkup: draft.materialMarkup,
            jobCosts: draft.jobCosts.map { cost in
                PricingDirectCost(
                    id: cost.id,
                    label: cost.label,
                    category: PricingCostCategory(rawValue: cost.category) ?? .other,
                    quantity: cost.quantity,
                    unitCost: cost.unitCost,
                    markupPercent: cost.markupPercent,
                    markupPolicy: PricingMarkupPolicy(rawValue: cost.markupPolicy),
                    taxable: cost.taxable,
                    customerVisible: cost.customerVisible
                )
            },
            overheadPercent: draft.overhead,
            marginPercent: draft.margin,
            minimumJobFee: minimumJobFee
        )
    }

    /// Stored estimate total = the pricing engine's `total`.
    static func estimateTotal(_ draft: NativePricebookEntryDraft, minimumJobFee: Decimal = 75) -> Decimal {
        PricingEngine.calculate(pricingInput(draft, minimumJobFee: minimumJobFee)).total
    }

    static func createFields(
        draft: NativePricebookEntryDraft,
        id: String,
        now: String,
        minimumJobFee: Decimal = 75
    ) -> [String: Canonical.JSONValue] {
        var fields = ownedFields(draft, minimumJobFee: minimumJobFee)
        fields["id"] = .string(id)
        fields["createdAt"] = .string(now)
        fields["updatedAt"] = .string(now)
        return fields
    }

    /// Edit projection over the existing record's field bag: `createdAt` and any
    /// unknown/nested fields survive; only owned fields change.
    static func appliedFields(
        draft: NativePricebookEntryDraft,
        to existing: [String: Canonical.JSONValue],
        now: String,
        minimumJobFee: Decimal = 75
    ) -> [String: Canonical.JSONValue] {
        var fields = existing
        for (key, value) in ownedFields(draft, minimumJobFee: minimumJobFee) {
            fields[key] = value
        }
        fields["updatedAt"] = .string(now)
        return fields
    }

    private static func ownedFields(
        _ draft: NativePricebookEntryDraft,
        minimumJobFee: Decimal
    ) -> [String: Canonical.JSONValue] {
        [
            "name": .string(draft.name),
            "description": draft.description.map { Canonical.JSONValue.string($0) } ?? .null,
            "category": draft.category.map { Canonical.JSONValue.string($0) } ?? .null,
            "laborHours": .number(draft.laborHours),
            "laborBreakdown": draft.laborBreakdown.map { Canonical.JSONValue.object(fields($0)) } ?? .null,
            "laborRate": .number(draft.laborRate),
            "materials": .array(draft.materials.map { Canonical.JSONValue.object(fields($0)) }),
            "materialMarkup": .number(draft.materialMarkup),
            "jobCosts": .array(draft.jobCosts.map { Canonical.JSONValue.object(fields($0)) }),
            "overhead": .number(draft.overhead),
            "margin": .number(draft.margin),
            "estimateTotal": .number(estimateTotal(draft, minimumJobFee: minimumJobFee)),
        ]
    }

    static func delete(_ entries: [Canonical.PricebookEntry], id: String) -> [Canonical.PricebookEntry] {
        entries.filter { $0.id != id }
    }

    /// Case-insensitive name/category search, matching the list screen's filter.
    static func search(_ entries: [Canonical.PricebookEntry], query: String) -> [Canonical.PricebookEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return entries }
        return entries.filter {
            $0.name.lowercased().contains(needle) || ($0.category ?? "").lowercased().contains(needle)
        }
    }

    /// Name-ascending, stable.
    static func sortedByName(_ entries: [Canonical.PricebookEntry]) -> [Canonical.PricebookEntry] {
        NativeCSVExport.stableSorted(entries) { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: Job prefill (P3)

    /// Project a saved pricebook entry into job/estimate form state. Nothing is
    /// invented: every value comes from the entry, and the estimate total is the
    /// entry's own stored total.
    static func jobPrefill(from entry: Canonical.PricebookEntry) -> NativePricebookEntryDraft {
        NativePricebookEntryDraft(
            name: entry.name,
            description: entry.description,
            category: entry.category,
            laborHours: entry.laborHours,
            laborBreakdown: entry.laborBreakdown,
            laborRate: entry.laborRate,
            materials: entry.materials,
            materialMarkup: entry.materialMarkup,
            jobCosts: entry.jobCosts ?? [],
            overhead: entry.overhead,
            margin: entry.margin
        )
    }
}
