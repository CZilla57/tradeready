import Foundation

// MARK: - Pricebook presentation (task 9.12, requirements P1-P4)
//
// The screen-level half of `screens/PricebookScreen.tsx` and
// `screens/PricebookEntryScreen.tsx` (+ `components/JobCostsEditor.tsx`):
// the grouped list, the editor's text layer, the direct-cost catalog, the
// template seeding rules, the AI suggestion rows, and the job prefill.
//
// Every stored value still comes from `NativePricebook` (9.05) and the pricing
// engine; this file owns parsing, defaults, and copy only. Nothing here writes
// canonical state.

struct NativePricebookRow: Equatable {
    var id: String
    var name: String
    var description: String?
    /// `formatQuote(estimateTotal)` — whole dollars, or a full cent pair.
    var priceText: String
}

struct NativePricebookSection: Equatable {
    var title: String
    var rows: [NativePricebookRow]
}

enum NativePricebookList {
    static let uncategorized = "Uncategorized"

    /// The list screen's search matches the NAME only (case-insensitive
    /// substring) — `NativePricebook.search` (9.05) also matches category and is
    /// used by the pickers instead.
    static func filtered(_ entries: [Canonical.PricebookEntry], query: String) -> [Canonical.PricebookEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    /// Grouped by `category || "Uncategorized"`, with Uncategorized last and the
    /// rest ordered the way RN's `localeCompare` orders them.
    static func sections(_ entries: [Canonical.PricebookEntry], query: String = "") -> [NativePricebookSection] {
        var grouped: [String: [Canonical.PricebookEntry]] = [:]
        var order: [String] = []
        for entry in filtered(entries, query: query) {
            let key = (entry.category ?? "").isEmpty ? uncategorized : entry.category!
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(entry)
        }
        let sorted = order.sorted { lhs, rhs in
            if lhs == uncategorized { return false }
            if rhs == uncategorized { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return sorted.map { title in
            NativePricebookSection(title: title, rows: (grouped[title] ?? []).map(row))
        }
    }

    static func row(_ entry: Canonical.PricebookEntry) -> NativePricebookRow {
        NativePricebookRow(
            id: entry.id,
            name: entry.name,
            description: (entry.description ?? "").isEmpty ? nil : entry.description,
            priceText: NativeMoneyFormat.quote(entry.estimateTotal)
        )
    }

    /// Distinct non-empty categories, for the editor's category suggestions.
    static func existingCategories(_ entries: [Canonical.PricebookEntry]) -> [String] {
        var seen: [String] = []
        for entry in entries {
            let category = (entry.category ?? "").trimmingCharacters(in: .whitespaces)
            guard !category.isEmpty else { continue }
            if !seen.contains(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) {
                seen.append(category)
            }
        }
        return seen
    }

    /// `filteredCategories`: substring match on the typed text, excluding the
    /// exact text itself.
    static func categorySuggestions(_ entries: [Canonical.PricebookEntry], input: String) -> [String] {
        let needle = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return existingCategories(entries).filter { category in
            let lowered = category.lowercased()
            return lowered.contains(needle) && lowered != needle
        }
    }
}

/// `JOB_COST_CATEGORIES` + `defaultMarkupPolicyForCategory` + `directCostLabel`.
enum NativeJobCostCatalog {
    static let all: [(id: String, label: String)] = [
        ("permit", "Permit"),
        ("disposal", "Disposal"),
        ("rental", "Equipment rental"),
        ("subcontractor", "Subcontractor"),
        ("delivery", "Delivery"),
        ("travel", "Travel"),
        ("other", "Other cost"),
    ]

    static let emptyNote = "Permits, disposal, rental, subcontractors, delivery — costs that aren't labor or materials."

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? "Other cost"
    }

    /// A permit passes through at cost; everything else joins the margin base.
    static func defaultMarkupPolicy(for category: String) -> String {
        category == "permit" ? "passthrough" : "in_margin_base"
    }

    /// The user's own label when they wrote one, else the category's name.
    static func displayLabel(label: String, category: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.label(for: category) : trimmed
    }

    /// The per-line figure the editor shows next to the row: passthrough lines at
    /// cost, everything else with the line's markup applied.
    static func lineAmount(quantity: Decimal, unitCost: Decimal, markupPercent: Decimal, markupPolicy: String) -> Decimal {
        let base = quantity * unitCost
        guard markupPolicy != "passthrough" else { return base }
        return base * (1 + markupPercent / 100)
    }
}

struct NativePricebookMaterialRow: Equatable, Identifiable {
    var id: String
    var name: String
    var quantityText: String
    var unitCostText: String

    /// Canonical record for this row. Built through the shared field decoder
    /// because `Canonical.Material` has no memberwise initializer.
    var material: Canonical.Material? {
        NativePricebook.decode(Canonical.Material.self, [
            "id": .string(id),
            "name": .string(name),
            "quantity": .number(NativePricebookForm.number(quantityText)),
            "unitCost": .number(NativePricebookForm.number(unitCostText)),
        ])
    }
}

struct NativePricebookJobCostRow: Equatable, Identifiable {
    var id: String
    var label: String
    var category: String
    var quantityText: String
    var unitCostText: String
    var markupPercentText: String
    var markupPolicy: String
    var taxable: Bool
    var customerVisible: Bool

    var jobCost: Canonical.JobCost? {
        NativePricebook.decode(Canonical.JobCost.self, [
            "id": .string(id),
            "label": .string(label),
            "category": .string(category),
            "quantity": .number(NativePricebookForm.number(quantityText)),
            "unitCost": .number(NativePricebookForm.number(unitCostText)),
            "markupPercent": .number(NativePricebookForm.number(markupPercentText)),
            "markupPolicy": .string(markupPolicy),
            "taxable": .bool(taxable),
            "customerVisible": .bool(customerVisible),
        ])
    }
}

/// The editor's text layer: every numeric field is a string while the user types,
/// parsed with `parseFloat(x) || 0` semantics on save.
struct NativePricebookForm {
    var name = ""
    var description = ""
    var category = ""
    var laborHoursText = ""
    var laborRateText = ""
    var materialMarkupText = ""
    var overheadText = ""
    var marginText = ""
    var materials: [NativePricebookMaterialRow] = []
    var jobCosts: [NativePricebookJobCostRow] = []
    /// Preserved from the entry being edited; the pricebook screen does not edit
    /// a labor breakdown (RN doesn't either).
    var laborBreakdown: Canonical.LaborTimeBreakdown?

    init() {}

    init(draft: NativePricebookEntryDraft) {
        name = draft.name
        description = draft.description ?? ""
        category = draft.category ?? ""
        laborHoursText = NativePricebookForm.text(draft.laborHours)
        laborRateText = NativePricebookForm.text(draft.laborRate)
        materialMarkupText = NativePricebookForm.text(draft.materialMarkup)
        overheadText = NativePricebookForm.text(draft.overhead)
        marginText = NativePricebookForm.text(draft.margin)
        laborBreakdown = draft.laborBreakdown
        materials = draft.materials.map {
            NativePricebookMaterialRow(
                id: $0.id,
                name: $0.name,
                quantityText: NativePricebookForm.text($0.quantity),
                unitCostText: NativePricebookForm.text($0.unitCost)
            )
        }
        jobCosts = draft.jobCosts.map {
            NativePricebookJobCostRow(
                id: $0.id,
                label: $0.label,
                category: $0.category,
                quantityText: NativePricebookForm.text($0.quantity),
                unitCostText: NativePricebookForm.text($0.unitCost),
                markupPercentText: NativePricebookForm.text($0.markupPercent),
                markupPolicy: $0.markupPolicy,
                taxable: $0.taxable,
                customerVisible: $0.customerVisible
            )
        }
    }

    /// `parseFloat(text) || 0` — junk and blanks are zero, a leading numeric
    /// prefix is kept, and the sign/decimals pass through.
    static func number(_ text: String) -> Decimal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let value = (trimmed as NSString).doubleValue
        guard value.isFinite else { return 0 }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// Numeric text without trailing zeroes ("3", "85.5", "0").
    static func text(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    var laborHours: Decimal { Self.number(laborHoursText) }
    var laborRate: Decimal { Self.number(laborRateText) }
    var materialMarkup: Decimal { Self.number(materialMarkupText) }
    var overhead: Decimal { Self.number(overheadText) }
    var margin: Decimal { Self.number(marginText) }

    var draft: NativePricebookEntryDraft {
        NativePricebookEntryDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: trimmedOrNil(description),
            category: trimmedOrNil(category),
            laborHours: laborHours,
            laborBreakdown: laborBreakdown,
            laborRate: laborRate,
            materials: materials.compactMap(\.material),
            materialMarkup: materialMarkup,
            jobCosts: jobCosts.compactMap(\.jobCost),
            overhead: overhead,
            margin: margin
        )
    }

    /// RN's `Name required` alert.
    static let missingNameMessage = "Give this service a name so you can find it later."

    var validationMessage: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.missingNameMessage : nil
    }

    /// Live "Estimated Total".
    func estimateTotalText(minimumJobFee: Decimal = 75) -> String {
        NativeMoneyFormat.quote(NativePricebook.estimateTotal(draft, minimumJobFee: minimumJobFee))
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Direct-cost rows

extension NativePricebookJobCostRow {
    /// A new line: category "other" with that category's default policy, quantity
    /// 1, no cost, and customer-visible (the documented JobCost default).
    static func new(id: String) -> NativePricebookJobCostRow {
        NativePricebookJobCostRow(
            id: id,
            label: "",
            category: "other",
            quantityText: "1",
            unitCostText: "0",
            markupPercentText: "0",
            markupPolicy: NativeJobCostCatalog.defaultMarkupPolicy(for: "other"),
            taxable: false,
            customerVisible: true
        )
    }

    var displayLabel: String { NativeJobCostCatalog.displayLabel(label: label, category: category) }

    var amount: Decimal {
        NativeJobCostCatalog.lineAmount(
            quantity: NativePricebookForm.number(quantityText),
            unitCost: NativePricebookForm.number(unitCostText),
            markupPercent: NativePricebookForm.number(markupPercentText),
            markupPolicy: markupPolicy
        )
    }

    var amountText: String { NativeMoneyFormat.quote(amount) }
}

// MARK: - Templates (P2)

struct NativeTemplateRow: Equatable {
    var id: String
    var name: String
    /// "Handyman" — the trade list joined for the picker's subtitle.
    var tradesText: String
    var checklistCount: Int
}

enum NativePricebookTemplates {
    static let checklistNote = "Reminders only — fill in every number yourself. Nothing here is saved."
    static let checklistTitle = "Scope reminders"

    static func rows(_ templates: [NativeTradeTemplate] = NativeTradeTemplates.all) -> [NativeTemplateRow] {
        templates.map { template in
            NativeTemplateRow(
                id: template.id,
                name: template.name,
                tradesText: template.trades.map { $0.capitalized }.joined(separator: ", "),
                checklistCount: template.scopeChecklist.count
            )
        }
    }

    /// RN's `handleTemplateSelect`: the template's name only fills a blank name,
    /// its empty editable lines are used only when the form has none (otherwise
    /// they are appended), and its checklist replaces the current one.
    static func applying(
        _ template: NativeTradeTemplate,
        to form: inout NativePricebookForm,
        checklist: inout [String],
        idBase: Int
    ) {
        let seeds = NativeTradeTemplates.applyTemplate(template, idBase: idBase)
        if form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            form.name = template.name
        }
        let seededMaterials = seeds.materials.map {
            NativePricebookMaterialRow(
                id: $0.id, name: $0.name,
                quantityText: NativePricebookForm.text($0.quantity),
                unitCostText: NativePricebookForm.text($0.unitCost)
            )
        }
        form.materials = form.materials.isEmpty ? seededMaterials : form.materials + seededMaterials

        let seededCosts = seeds.jobCosts.map {
            NativePricebookJobCostRow(
                id: $0.id, label: $0.label, category: $0.category,
                quantityText: NativePricebookForm.text($0.quantity),
                unitCostText: NativePricebookForm.text($0.unitCost),
                markupPercentText: NativePricebookForm.text($0.markupPercent),
                markupPolicy: $0.markupPolicy,
                taxable: $0.taxable,
                customerVisible: $0.customerVisible
            )
        }
        form.jobCosts = form.jobCosts.isEmpty ? seededCosts : form.jobCosts + seededCosts
        checklist = template.scopeChecklist
    }
}

// MARK: - AI suggestions (P4, review only)

struct NativePricebookSuggestionRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case laborHours(Decimal)
        case laborRate(Decimal)
        case material(name: String, unitCost: Decimal)
    }

    var id: String
    var title: String
    var reasoning: String
    /// The exact text on the row's apply button, or nil for a display-only row.
    var applyTitle: String?
    var kind: Kind?
}

enum NativePricebookSuggestion {
    static let panelTitle = "AI Suggestions"
    static let unavailableTitle = "Couldn't get suggestions"
    static let unavailableMessage = "AI pricing is unavailable right now. Try again later."
    static let missingNameMessage = "Enter a service name so the AI knows what to price."

    /// RN's row copy: "Labor: 3 hrs", "Rate: $85/hr", "<material>: $12", plus the
    /// market range. Nothing is applied without an explicit tap.
    static func rows(_ suggestion: NativeAIPricingSuggestion) -> [NativePricebookSuggestionRow] {
        var rows: [NativePricebookSuggestionRow] = []
        if let hours = suggestion.laborHours.suggested {
            rows.append(NativePricebookSuggestionRow(
                id: "laborHours",
                title: "Labor: \(NativePricebookForm.text(hours)) hrs",
                reasoning: suggestion.laborHours.reasoning ?? "",
                applyTitle: "Apply",
                kind: .laborHours(hours)
            ))
        }
        if let rate = suggestion.laborRate.suggested {
            rows.append(NativePricebookSuggestionRow(
                id: "laborRate",
                title: "Rate: \(NativeMoneyFormat.quote(rate))/hr",
                reasoning: suggestion.laborRate.reasoning ?? "",
                applyTitle: "Apply",
                kind: .laborRate(rate)
            ))
        }
        for material in suggestion.materials {
            let cost = material.suggestedUnitCost
            let costText = cost.map { NativeMoneyFormat.quote($0) } ?? "—"
            rows.append(NativePricebookSuggestionRow(
                id: "material-\(material.name)",
                title: "\(material.name): \(costText)",
                reasoning: material.reasoning ?? "",
                applyTitle: cost == nil ? nil : "Apply",
                kind: cost.map { .material(name: material.name, unitCost: $0) }
            ))
        }
        let range = suggestion.overallRange
        if range.low != nil || range.high != nil {
            let low = range.low.map { NativeMoneyFormat.quote($0) } ?? "—"
            let high = range.high.map { NativeMoneyFormat.quote($0) } ?? "—"
            rows.append(NativePricebookSuggestionRow(
                id: "overallRange",
                title: "Market range: \(low) – \(high)",
                reasoning: range.reasoning ?? "",
                applyTitle: nil,
                kind: nil
            ))
        }
        return rows
    }

    /// Applying a row is an explicit, caller-driven edit of form state. Labor
    /// hours/rate replace the field; a material cost updates the matching row by
    /// name or appends a new one at quantity 1 (RN's rule).
    static func applying(_ row: NativePricebookSuggestionRow, to form: inout NativePricebookForm, idBase: Int) {
        switch row.kind {
        case .laborHours(let hours):
            form.laborHoursText = NativePricebookForm.text(hours)
        case .laborRate(let rate):
            form.laborRateText = NativePricebookForm.text(rate)
        case .material(let name, let unitCost):
            if let index = form.materials.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                form.materials[index].unitCostText = NativePricebookForm.text(unitCost)
            } else {
                form.materials.append(NativePricebookMaterialRow(
                    id: "m\(idBase)-\(form.materials.count)",
                    name: name,
                    quantityText: "1",
                    unitCostText: NativePricebookForm.text(unitCost)
                ))
            }
        case nil:
            break
        }
    }
}

// MARK: - Job prefill (P3)

enum NativePricebookPrefill {
    /// Loads a saved service into a job's pricing form. Only the entry's own
    /// pricing fields move; the job's travel, emergency multiplier, minimum fee,
    /// and tax stay exactly as the job had them.
    static func applying(_ draft: NativePricebookEntryDraft, to jobDraft: NativeJobPricingDraft) -> NativeJobPricingDraft {
        var updated = jobDraft
        updated.laborHours = draft.laborHours
        updated.laborBreakdown = draft.laborBreakdown
        updated.laborRate = draft.laborRate
        updated.materials = draft.materials
        updated.materialMarkup = draft.materialMarkup
        updated.jobCosts = draft.jobCosts
        updated.overheadPercent = draft.overhead
        updated.marginPercent = draft.margin
        return updated
    }
}
