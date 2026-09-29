import Foundation

// MARK: - Trade templates (task 9.05, requirements P2)
//
// Port of `utils/tradeTemplates.ts`. A template is STRUCTURE, never market data:
// a scope checklist of QUESTIONS and empty, editable placeholder lines. The
// load-bearing guardrail (pinned below and in the tests) is that no template
// contains a rate, quantity, waste %, coverage figure, minimum, or legal
// requirement — applying one only seeds form state and persists nothing.

struct NativeTradeTemplateJobCost: Equatable {
    var label: String
    var category: String
    var markupPolicy: String
}

struct NativeTradeTemplate: Equatable {
    var id: String
    var name: String
    var trades: [String]
    var scopeChecklist: [String]
    var seedMaterials: [String]
    var seedJobCosts: [NativeTradeTemplateJobCost]
}

struct NativeTemplateSeeds {
    var materials: [Canonical.Material]
    var jobCosts: [Canonical.JobCost]
}

enum NativeTradeTemplates {
    static let all: [NativeTradeTemplate] = [
        NativeTradeTemplate(
            id: "handyman", name: "Handyman job", trades: ["handyman"],
            scopeChecklist: [
                "Does the price cover your minimum visit or trip out?",
                "Are you quoting flat or hourly — and have you decided which to show?",
                "If bundling several small tasks, is each one listed?",
                "Is supply-run and drive time included in the hours?",
            ],
            seedMaterials: [], seedJobCosts: []
        ),
        NativeTradeTemplate(
            id: "painting", name: "Painting job", trades: ["painting"],
            scopeChecklist: [
                "Have you measured the paintable area?",
                "Are surface prep hours counted in labor?",
                "How many coats does this job need?",
                "Are you using an interior or exterior rate?",
                "Have you entered product coverage for paint needed?",
            ],
            seedMaterials: ["Paint", "Primer", "Sundries (tape, filler, sleeves)"],
            seedJobCosts: []
        ),
        NativeTradeTemplate(
            id: "drywall", name: "Drywall job", trades: ["carpenter", "handyman", "plasterer"],
            scopeChecklist: [
                "Which stages does the price cover — hang, finish, texture?",
                "Is the level of finish agreed with the customer?",
                "Are return trips the drying time forces counted as labor?",
                "For a patch, does it meet your minimum job price?",
                "Have you entered a waste allowance for offcuts?",
            ],
            seedMaterials: ["Drywall sheets", "Joint compound", "Tape / corner bead"],
            seedJobCosts: [NativeTradeTemplateJobCost(label: "Debris disposal", category: "disposal", markupPolicy: "in_margin_base")]
        ),
        NativeTradeTemplate(
            id: "flooring", name: "Flooring job", trades: ["carpenter", "handyman"],
            scopeChecklist: [
                "Have you measured the area, including closets and nooks?",
                "Have you entered a waste / overage allowance for the pattern?",
                "Is tear-out priced as its own line, with disposal?",
                "Is a subfloor-prep allowance included or clearly excluded?",
                "Are transitions, trim, and stairs accounted for?",
                "Is the flooring customer-supplied or supplied by you?",
            ],
            seedMaterials: ["Flooring material", "Underlayment / adhesive", "Transitions / trim"],
            seedJobCosts: [
                NativeTradeTemplateJobCost(label: "Old-floor disposal", category: "disposal", markupPolicy: "in_margin_base"),
                NativeTradeTemplateJobCost(label: "Delivery", category: "delivery", markupPolicy: "in_margin_base"),
            ]
        ),
        NativeTradeTemplate(
            id: "landscaping", name: "Landscaping job", trades: ["landscaping"],
            scopeChecklist: [
                "Is on-site time counted for this visit?",
                "Is the drive the stop costs you included?",
                "Does your overhead percent carry equipment and fuel?",
                "For bulk material, have you measured by volume?",
                "Is debris disposal priced as its own line?",
                "Is this a one-off or part of a recurring schedule?",
            ],
            seedMaterials: ["Bulk material (mulch / soil / gravel)", "Plants"],
            seedJobCosts: [NativeTradeTemplateJobCost(label: "Green-waste disposal", category: "disposal", markupPolicy: "in_margin_base")]
        ),
        NativeTradeTemplate(
            id: "electrical", name: "Electrical job", trades: ["electrical"],
            scopeChecklist: [
                "Is a service-call or diagnostic fee included?",
                "Is the permit fee, and the time to pull it, priced?",
                "Is a separate inspection return trip accounted for?",
                "Is this after-hours or an emergency call?",
                "Could this be saved as a reusable flat-rate task?",
            ],
            seedMaterials: ["Wire / cable", "Devices / fixtures"],
            seedJobCosts: [NativeTradeTemplateJobCost(label: "Permit fee", category: "permit", markupPolicy: "passthrough")]
        ),
        NativeTradeTemplate(
            id: "plumbing", name: "Plumbing job", trades: ["plumbing"],
            scopeChecklist: [
                "Is a service-call or trip fee included?",
                "For nights, weekends, or urgent work, is your emergency pricing applied?",
                "Is the permit fee, and the time to pull it, priced?",
                "Is haul-away or disposal of the old unit included?",
                "Is the fixture customer-supplied or supplied by you?",
                "Could this be saved as a reusable flat-rate task?",
            ],
            seedMaterials: ["Fittings / supply lines", "Fixture / unit"],
            seedJobCosts: [
                NativeTradeTemplateJobCost(label: "Permit fee", category: "permit", markupPolicy: "passthrough"),
                NativeTradeTemplateJobCost(label: "Haul-away / disposal", category: "disposal", markupPolicy: "in_margin_base"),
            ]
        ),
    ]

    /// All templates with the ones relevant to `trade` sorted first (stable).
    static func templatesForTrade(_ trade: String) -> [NativeTradeTemplate] {
        all.enumerated().sorted { lhs, rhs in
            let lhsRelevant = lhs.element.trades.contains(trade) ? 0 : 1
            let rhsRelevant = rhs.element.trades.contains(trade) ? 0 : 1
            return lhsRelevant == rhsRelevant ? lhs.offset < rhs.offset : lhsRelevant < rhsRelevant
        }.map(\.element)
    }

    /// Empty, editable seed lines. Materials seed at qty 1 / $0; direct costs
    /// seed at qty 1 / $0 / 0% markup, visible + non-taxable. The template
    /// supplies NO amount.
    static func applyTemplate(_ template: NativeTradeTemplate, idBase: Int) -> NativeTemplateSeeds {
        let materials: [Canonical.Material] = template.seedMaterials.enumerated().compactMap { index, name in
            NativePricebook.decode(Canonical.Material.self, [
                "id": .string("m\(idBase)-\(index)"),
                "name": .string(name),
                "quantity": .number(1),
                "unitCost": .number(0),
            ])
        }
        let jobCosts: [Canonical.JobCost] = template.seedJobCosts.enumerated().compactMap { index, seed in
            NativePricebook.decode(Canonical.JobCost.self, [
                "id": .string("jc\(idBase)-\(index)"),
                "label": .string(seed.label),
                "category": .string(seed.category),
                "quantity": .number(1),
                "unitCost": .number(0),
                "markupPercent": .number(0),
                "markupPolicy": .string(seed.markupPolicy),
                "taxable": .bool(false),
                "customerVisible": .bool(true),
            ])
        }
        return NativeTemplateSeeds(materials: materials, jobCosts: jobCosts)
    }

    /// The guardrail, expressed as code: true when a template bakes in a number,
    /// dollar amount, or percent.
    static func containsBakedFigures(_ template: NativeTradeTemplate) -> Bool {
        func hasFigure(_ value: String) -> Bool {
            value.contains(where: { $0.isNumber || $0 == "$" || $0 == "%" })
        }
        if hasFigure(template.name) { return true }
        if template.scopeChecklist.contains(where: hasFigure) { return true }
        if template.seedMaterials.contains(where: hasFigure) { return true }
        if template.seedJobCosts.contains(where: { hasFigure($0.label) }) { return true }
        return false
    }
}
