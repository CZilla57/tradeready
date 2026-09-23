import SwiftUI

// MARK: - Pricebook entry editor (task 9.12, requirements P1-P4)
//
// Port of `screens/PricebookEntryScreen.tsx` (+ `components/JobCostsEditor.tsx`):
// the trade-template seeds and scope checklist, the service fields with category
// suggestions, labor, materials, direct costs, markup/overhead/margin, the live
// estimated total, the advisory AI panel, and save/delete.
//
// All policy lives in `NativePricebook` (9.05) and `NativePricebookPresentation`.
// The AI panel is review-only: a suggestion edits form text, and only an explicit
// Apply per row (then Save) can reach the canonical record.

/// Which service the editor is working on.
enum NativePricebookEditorTarget: Identifiable, Equatable {
    case create
    case edit(String)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit-\(id)"
        }
    }
}

struct NativePricebookEntryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let target: NativePricebookEditorTarget
    /// The canonical record as opened (nil when creating).
    let opened: Canonical.PricebookEntry?

    @State private var form: NativePricebookForm
    @State private var checklist: [String] = []
    @State private var checklistOpen = false
    @State private var showingTemplates = false
    @State private var showingJobPicker = false
    @State private var prefillJobDraft: NativeJobPricingDraft?
    @State private var suggestion: NativeAIPricingSuggestion?
    @State private var isSuggesting = false
    @State private var alert: NativePricebookAlert?
    @State private var showingDeleteConfirmation = false
    /// Stable base for locally minted child ids (`m<base>-<n>`, `jc<base>-<n>`).
    private let idBase: Int

    init(target: NativePricebookEditorTarget, opened: Canonical.PricebookEntry? = nil) {
        self.target = target
        self.opened = opened
        self.idBase = Int(Date().timeIntervalSince1970 * 1000)
        if let opened {
            _form = State(initialValue: NativePricebookForm(draft: NativePricebook.jobPrefill(from: opened)))
        } else {
            _form = State(initialValue: NativePricebookForm())
        }
    }

    private var isEditing: Bool { if case .edit = target { return true }; return false }
    private var title: String { isEditing ? "Edit Service" : "New Service" }
    private var suggestions: [String] {
        NativePricebookList.categorySuggestions(store.canonicalPricebook, input: form.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !checklist.isEmpty { checklistSection }

                Section {
                    Button { showingTemplates = true } label: {
                        Label("Start from a template", systemImage: "square.grid.2x2")
                    }
                }

                Section("Service") {
                    LabeledField(label: "Service name") {
                        TextField("e.g. Water Heater Install", text: $form.name)
                    }
                    LabeledField(label: "Description") {
                        TextField("Optional notes about this service", text: $form.description, axis: .vertical)
                    }
                    LabeledField(label: "Category") {
                        TextField("e.g. Plumbing, Electrical", text: $form.category)
                    }
                    if !suggestions.isEmpty {
                        ForEach(suggestions, id: \.self) { category in
                            Button(category) { form.category = category }
                                .font(.footnote)
                        }
                    }
                }

                Section("Pricing") {
                    LabeledField(label: "Labor hours") {
                        TextField("0", text: $form.laborHoursText).keyboardType(.decimalPad)
                    }
                    LabeledField(label: "Labor rate ($/hr)") {
                        TextField("85", text: $form.laborRateText).keyboardType(.decimalPad)
                    }
                }

                materialsSection
                jobCostsSection

                Section("Markup & margin") {
                    LabeledField(label: "Material markup %") {
                        TextField("20", text: $form.materialMarkupText).keyboardType(.decimalPad)
                    }
                    LabeledField(label: "Overhead %") {
                        TextField("15", text: $form.overheadText).keyboardType(.decimalPad)
                    }
                    LabeledField(label: "Profit margin %") {
                        TextField("20", text: $form.marginText).keyboardType(.decimalPad)
                    }
                }

                Section {
                    LabeledContent("Estimated Total") {
                        Text(form.estimateTotalText(minimumJobFee: store.minimumJobFee))
                            .font(.headline.monospacedDigit())
                    }
                    .accessibilityLabel("Estimated total \(form.estimateTotalText(minimumJobFee: store.minimumJobFee))")
                }

                aiSection

                Section {
                    Button { showingJobPicker = true } label: {
                        Label("Use in a job", systemImage: "briefcase")
                    }
                } footer: {
                    Text("Loads this service's labor, materials, and direct costs into a job's pricing calculator for review. Nothing is saved until you save the job.")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                            Label("Delete Service", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
            .alert(alert?.title ?? "", isPresented: showingAlert, presenting: alert) { _ in
                Button("OK", role: .cancel) { alert = nil }
            } message: { value in
                Text(value.message)
            }
            .sheet(isPresented: $showingTemplates) {
                NativeTemplatePickerView { template in
                    NativePricebookTemplates.applying(
                        template, to: &form, checklist: &checklist, idBase: idBase
                    )
                    checklistOpen = true
                }
            }
            .sheet(isPresented: $showingJobPicker) {
                NativePricebookJobPickerView(jobs: store.canonicalJobs) { job in
                    guard let draft = store.jobPricingDraft(jobID: job.id) else { return }
                    prefillJobDraft = NativePricebookPrefill.applying(form.draft, to: draft)
                }
            }
            .sheet(item: $prefillJobDraft) { NativePricingCalculatorView(draft: $0) }
            .confirmationDialog(
                "Delete Service",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \"\(form.name)\" from your Pricebook?")
            }
        }
    }

    // MARK: Sections

    private var checklistSection: some View {
        Section {
            DisclosureGroup(isExpanded: $checklistOpen) {
                ForEach(checklist, id: \.self) { question in
                    Label(question, systemImage: "circle.dashed")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(NativePricebookTemplates.checklistNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } label: {
                Label(NativePricebookTemplates.checklistTitle, systemImage: "checklist")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var materialsSection: some View {
        Section("Materials") {
            ForEach($form.materials) { $material in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Item name", text: $material.name)
                    HStack(spacing: 10) {
                        TextField("Qty", text: $material.quantityText)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 90)
                        TextField("$ each", text: $material.unitCostText)
                            .keyboardType(.decimalPad)
                        Text(NativeMoneyFormat.quote(
                            NativePricebookForm.number(material.quantityText)
                                * NativePricebookForm.number(material.unitCostText)
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            .onDelete { indices in form.materials.remove(atOffsets: indices) }

            Button {
                form.materials.append(NativePricebookMaterialRow(
                    id: "m\(idBase)-\(form.materials.count)",
                    name: "",
                    quantityText: "1",
                    unitCostText: "0"
                ))
            } label: {
                Label("Add material", systemImage: "plus")
            }
        }
    }

    private var jobCostsSection: some View {
        Section("Direct costs") {
            if form.jobCosts.isEmpty {
                Text(NativeJobCostCatalog.emptyNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach($form.jobCosts) { $cost in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Label (e.g. City permit)", text: $cost.label)
                        Text(costAmountText(cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Picker("Category", selection: $cost.category) {
                        ForEach(NativeJobCostCatalog.all, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .onChange(of: cost.category) { _, category in
                        // Changing the category resets the policy to that
                        // category's default; the toggle below still overrides.
                        cost.markupPolicy = NativeJobCostCatalog.defaultMarkupPolicy(for: category)
                    }
                    HStack(spacing: 10) {
                        TextField("Qty", text: $cost.quantityText)
                            .keyboardType(.decimalPad)
                        TextField("$ each", text: $cost.unitCostText)
                            .keyboardType(.decimalPad)
                        TextField("Markup %", text: $cost.markupPercentText)
                            .keyboardType(.decimalPad)
                    }
                    Toggle("Pass through at cost", isOn: Binding(
                        get: { cost.markupPolicy == "passthrough" },
                        set: { cost.markupPolicy = $0 ? "passthrough" : "in_margin_base" }
                    ))
                    .font(.footnote)
                    Toggle("Taxable", isOn: $cost.taxable).font(.footnote)
                    Toggle("Show on estimate", isOn: $cost.customerVisible).font(.footnote)
                }
                .padding(.vertical, 2)
            }
            .onDelete { indices in form.jobCosts.remove(atOffsets: indices) }

            Button {
                form.jobCosts.append(.new(id: "jc\(idBase)-\(form.jobCosts.count)"))
            } label: {
                Label("Add direct cost", systemImage: "plus")
            }
        }
    }

    private func costAmountText(_ cost: NativePricebookJobCostRow) -> String {
        // Recomputed per render so the figure tracks the text buffers.
        NativeMoneyFormat.quote(cost.amount)
    }

    private var aiSection: some View {
        Section {
            Button {
                requestSuggestions()
            } label: {
                if isSuggesting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Getting suggestions...")
                    }
                } else {
                    Label("Get AI Pricing Suggestions", systemImage: "sparkles")
                }
            }
            .disabled(isSuggesting)

            if let suggestion {
                ForEach(NativePricebookSuggestion.rows(suggestion), id: \.id) { row in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.subheadline.weight(.medium))
                            if !row.reasoning.isEmpty {
                                Text(row.reasoning).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if let applyTitle = row.applyTitle {
                            Button(applyTitle) {
                                NativePricebookSuggestion.applying(row, to: &form, idBase: idBase)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Apply \(row.title)")
                        }
                    }
                }
            }
        } header: {
            Text(suggestion == nil ? "AI pricing" : NativePricebookSuggestion.panelTitle)
        } footer: {
            Text("Suggestions are advisory. Apply a line, then Save to keep it — nothing is written until you save.")
        }
    }

    // MARK: Actions

    private func requestSuggestions() {
        guard form.validationMessage == nil else {
            alert = .validation(NativePricebookSuggestion.missingNameMessage)
            return
        }
        isSuggesting = true
        suggestion = nil
        let input = NativePricebookAIInput(
            serviceName: form.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: form.description,
            category: form.category,
            materials: form.draft.materials,
            laborHours: form.laborHours,
            laborRate: form.laborRate,
            trade: store.settings.trade.isEmpty ? "general" : store.settings.trade,
            region: store.settings.region
        )
        Task {
            let result = await store.pricebookSuggestion(input)
            isSuggesting = false
            if let result {
                suggestion = result
            } else {
                alert = .failure(
                    title: NativePricebookSuggestion.unavailableTitle,
                    message: NativePricebookSuggestion.unavailableMessage
                )
            }
        }
    }

    private func save() {
        if let message = form.validationMessage {
            alert = .validation(message)
            return
        }
        switch store.commitPricebookEdit(id: opened?.id, opened: opened, draft: form.draft) {
        case .success:
            dismiss()
        case .failure(let refusal):
            alert = .failure(title: "Couldn't Save", message: Self.refusalCopy(refusal))
        }
    }

    private func delete() {
        guard case .edit(let id) = target else { return }
        if store.deletePricebookEntry(id: id) {
            dismiss()
        } else {
            alert = .failure(
                title: "Couldn't Delete",
                message: "That service couldn't be deleted. Nothing was changed."
            )
        }
    }

    static func refusalCopy(_ refusal: NativeMoneyRecordRefusal) -> String {
        switch refusal {
        case .persistenceUnavailable: "Your service couldn't be saved. Nothing was changed."
        case .missingRecord: "That service is no longer available. Reopen the Pricebook."
        case .staleEditorCopy: "This service changed on another device. Reopen it and try again."
        case .conflictingRecord: "That service already exists."
        case .invalidDraft(let message): message
        }
    }

    private var showingAlert: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )
    }
}

/// RN's `Alert.alert` cases from the pricebook entry screen.
private enum NativePricebookAlert: Equatable {
    case validation(String)
    case failure(title: String, message: String)

    var title: String {
        switch self {
        case .validation: "Name required"
        case .failure(let title, _): title
        }
    }

    var message: String {
        switch self {
        case .validation(let message): message
        case .failure(_, let message): message
        }
    }
}
