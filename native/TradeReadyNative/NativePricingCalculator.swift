import Foundation
import SwiftUI

struct NativePricingCalculatorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NativeJobPricingDraft
    private static let ids = LocalIDGenerator()

    init(draft: NativeJobPricingDraft) {
        _draft = State(initialValue: draft)
    }

    private var range: PricingRange { PricingEngine.priceRange(draft.input) }
    private var breakdown: PricingBreakdown { range.breakdown }
    private var advisories: [PricingAdvisory] {
        PricingEngine.advisories(
            draft.input,
            driveHours: draft.laborBreakdown?.driveHours ?? 0
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Price range") {
                    LabeledContent("Recommended", value: money(range.recommended))
                        .font(.headline)
                    LabeledContent("Low", value: money(range.low))
                    LabeledContent("High", value: money(range.high))
                    LabeledContent("Break-even", value: money(PricingEngine.breakEvenPrice(draft.input)))
                    if breakdown.hitMinimum {
                        Label("Minimum job fee applied", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !advisories.isEmpty {
                    Section("Check this estimate") {
                        ForEach(advisories) { advisory in
                            Label(advisory.message, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Labor") {
                    Toggle("Break hours down", isOn: Binding(
                        get: { draft.laborBreakdown != nil },
                        set: { detailed in
                            if detailed {
                                draft.laborBreakdown = try? CanonicalUIAdapters.newLaborBreakdown(
                                    onSiteHours: draft.laborHours
                                )
                            } else {
                                synchronizeLaborTotal()
                                draft.laborBreakdown = nil
                            }
                        }
                    ))
                    if draft.laborBreakdown == nil {
                        DecimalInput("Hours", value: $draft.laborHours)
                    } else {
                        HStack {
                            DecimalInput("On-site", value: laborBucket(\.onSiteHours))
                            DecimalInput("Drive", value: laborBucket(\.driveHours))
                        }
                        HStack {
                            DecimalInput("Supply run", value: laborBucket(\.supplyRunHours))
                            DecimalInput("Setup / cleanup", value: laborBucket(\.setupCleanupHours))
                        }
                        LabeledContent("Total costed hours", value: NSDecimalNumber(decimal: draft.laborHours).stringValue)
                        TextField("Non-billable time note", text: Binding(
                            get: { draft.laborBreakdown?.nonBillableNote ?? "" },
                            set: { draft.laborBreakdown?.nonBillableNote = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    DecimalInput("Hourly rate", value: $draft.laborRate, prefix: "$")
                    Toggle("Emergency pricing", isOn: $draft.isEmergency)
                    if draft.isEmergency {
                        DecimalInput("Emergency multiplier", value: $draft.emergencyMultiplier, suffix: "×")
                    }
                }

                Section("Materials") {
                    if draft.materials.isEmpty {
                        Text("No materials").foregroundStyle(.secondary)
                    }
                    ForEach($draft.materials, id: \.id) { $material in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Material", text: $material.name)
                            HStack {
                                DecimalInput("Qty", value: $material.quantity)
                                DecimalInput("Each", value: $material.unitCost, prefix: "$")
                            }
                        }
                    }
                    .onDelete { draft.materials.remove(atOffsets: $0) }
                    Button("Add material", systemImage: "plus") {
                        if let material = try? CanonicalUIAdapters.newPricingMaterial(id: Self.ids.materialID()) {
                            draft.materials.append(material)
                        }
                    }
                    DecimalInput("Material markup", value: $draft.materialMarkup, suffix: "%")
                }

                Section("Direct costs") {
                    if draft.jobCosts.isEmpty {
                        Text("Permits, disposal, rentals, delivery, and subcontractors.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach($draft.jobCosts, id: \.id) { $cost in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Cost label", text: $cost.label)
                            Picker("Category", selection: $cost.category) {
                                if PricingCostCategory(rawValue: cost.category) == nil {
                                    Text("Other (\(cost.category))").tag(cost.category)
                                }
                                ForEach(PricingCostCategory.allCases, id: \.rawValue) {
                                    Text(categoryTitle($0)).tag($0.rawValue)
                                }
                            }
                            .onChange(of: cost.category) { oldValue, newValue in
                                guard oldValue != newValue,
                                      let category = PricingCostCategory(rawValue: newValue)
                                else { return }
                                cost.markupPolicy = PricingEngine.defaultMarkupPolicy(for: category).rawValue
                            }
                            HStack {
                                DecimalInput("Qty", value: $cost.quantity)
                                DecimalInput("Each", value: $cost.unitCost, prefix: "$")
                            }
                            Toggle("Bill at cost", isOn: Binding(
                                get: { cost.markupPolicy == PricingMarkupPolicy.passthrough.rawValue },
                                set: { cost.markupPolicy = $0 ? PricingMarkupPolicy.passthrough.rawValue : PricingMarkupPolicy.inMarginBase.rawValue }
                            ))
                            if cost.markupPolicy != PricingMarkupPolicy.passthrough.rawValue {
                                DecimalInput("Markup", value: $cost.markupPercent, suffix: "%")
                            }
                            Toggle("Show to customer", isOn: $cost.customerVisible)
                            Toggle("Taxable", isOn: $cost.taxable)
                        }
                    }
                    .onDelete { draft.jobCosts.remove(atOffsets: $0) }
                    Button("Add direct cost", systemImage: "plus") {
                        if let cost = try? CanonicalUIAdapters.newPricingJobCost(id: Self.ids.jobCostID()) {
                            draft.jobCosts.append(cost)
                        }
                    }
                }

                Section("Pricing policy") {
                    DecimalInput("Overhead", value: $draft.overheadPercent, suffix: "%")
                    DecimalInput("Profit margin", value: $draft.marginPercent, suffix: "%")
                    DecimalInput("Minimum job fee", value: $draft.minimumJobFee, prefix: "$")
                    DecimalInput("Travel miles", value: $draft.travelMiles, suffix: "mi")
                    DecimalInput("Travel rate", value: $draft.travelFeePerMile, prefix: "$")
                    DecimalInput("Tax", value: $draft.taxPercent, suffix: "%")
                }

                Section("Breakdown") {
                    LabeledContent("Labor", value: money(breakdown.laborCost))
                    LabeledContent("Materials", value: money(breakdown.materialCost))
                    if breakdown.travelCost != 0 { LabeledContent("Travel", value: money(breakdown.travelCost)) }
                    if breakdown.directCostMarginBase != 0 || breakdown.directCostPassthrough != 0 {
                        LabeledContent("Direct costs", value: money(breakdown.directCostMarginBase + breakdown.directCostPassthrough))
                    }
                    LabeledContent("Overhead", value: money(breakdown.overheadCost))
                    LabeledContent("Profit", value: money(breakdown.profit))
                    if breakdown.taxAmount != 0 { LabeledContent("Tax", value: money(breakdown.taxAmount)) }
                    LabeledContent("Total", value: money(breakdown.total)).font(.headline)
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Pricing Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if store.saveJobPricing(draft) { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .nativeAnalyticsScreen(.pricingCalculator)
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.currency
    }

    private func categoryTitle(_ category: PricingCostCategory) -> String {
        switch category {
        case .permit: "Permit"
        case .disposal: "Disposal"
        case .rental: "Rental"
        case .subcontractor: "Subcontractor"
        case .delivery: "Delivery"
        case .travel: "Travel"
        case .other: "Other"
        }
    }

    private func laborBucket(
        _ keyPath: WritableKeyPath<Canonical.LaborTimeBreakdown, Decimal>
    ) -> Binding<Decimal> {
        Binding(
            get: { draft.laborBreakdown?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard draft.laborBreakdown != nil else { return }
                draft.laborBreakdown?[keyPath: keyPath] = value
                synchronizeLaborTotal()
            }
        )
    }

    private func synchronizeLaborTotal() {
        guard let labor = draft.laborBreakdown else { return }
        draft.laborHours = PricingEngine.laborBreakdownTotal(
            onSite: labor.onSiteHours,
            drive: labor.driveHours,
            supplyRun: labor.supplyRunHours,
            setupCleanup: labor.setupCleanupHours
        )
    }
}

private struct DecimalInput: View {
    let title: String
    @Binding var value: Decimal
    var prefix = ""
    var suffix = ""

    init(_ title: String, value: Binding<Decimal>, prefix: String = "", suffix: String = "") {
        self.title = title
        _value = value
        self.prefix = prefix
        self.suffix = suffix
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 3) {
                if !prefix.isEmpty { Text(prefix).foregroundStyle(.secondary) }
                TextField("0", value: $value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 48)
                if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
            }
        }
    }
}
