import SwiftUI

/// Phase 25 (spec §6.5): the good/better/best editor for one job.
///
/// The sheet keeps no state of record. It re-reads
/// `AppStore.quoteOptionsState(jobID:)` on every render, and every action
/// re-resolves the canonical job inside the store, so a customer approval that
/// lands while the sheet is open turns the next edit into a refusal (M3)
/// instead of overwriting the choice.
struct NativeQuoteOptionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String

    @State private var tierPricing: NativeQuoteTierPricingDraft?
    @State private var addOnEditor: NativeQuoteAddOnEditorDraft?
    @State private var tierPendingDelete: NativeQuoteOptionsState.Tier?
    @State private var showingRemoveOptions = false
    @State private var errorMessage: String?

    private var state: NativeQuoteOptionsState? { store.quoteOptionsState(jobID: jobID) }

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    form(state)
                } else {
                    ContentUnavailableView("Job not found", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle("Quote options")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .sheet(item: $tierPricing) { pricing in
                NativePricingCalculatorView(draft: pricing.draft, tierID: pricing.tierID, tierName: pricing.tierName)
            }
            .sheet(item: $addOnEditor) { draft in
                NativeQuoteAddOnEditorView(jobID: jobID, draft: draft)
            }
            .confirmationDialog(
                "Delete \u{201C}\(tierPendingDelete?.name ?? "")\u{201D}?",
                isPresented: Binding(
                    get: { tierPendingDelete != nil },
                    set: { if !$0 { tierPendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: tierPendingDelete
            ) { tier in
                Button("Delete option", role: .destructive) {
                    perform { store.deleteQuoteTier(jobID: jobID, tierID: tier.id) }
                }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("Its pricing is removed from this estimate.")
            }
            .confirmationDialog(
                "Remove options?",
                isPresented: $showingRemoveOptions,
                titleVisibility: .visible
            ) {
                ForEach(state?.tiers ?? []) { tier in
                    Button("Keep \u{201C}\(tier.name)\u{201D} (\(money(tier.total)))") {
                        perform { store.removeQuoteOptions(jobID: jobID, keepingTierID: tier.id) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The estimate goes back to a single price. Choose the option whose pricing to keep; the others and all add-ons are removed.")
            }
            .alert("Couldn’t update options", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
            .nativeAnalyticsScreen(.quoteOptions)
        }
    }

    @ViewBuilder
    private func form(_ state: NativeQuoteOptionsState) -> some View {
        Form {
            if state.linkShowsEarlierVersion && state.isEditable {
                // Phase 25 review fix: edits stay allowed, but the live link
                // still offers what was sent, and an approval of it wins.
                Section {
                    Label(
                        "Your customer’s approval link still shows the estimate you sent earlier. Re-send it from Review & send so they see these changes. If they approve the earlier version first, that is what the job uses.",
                        systemImage: "exclamationmark.bubble"
                    )
                }
            }
            if !state.hasOptions {
                startSection(state)
            } else {
                if let acceptance = state.acceptance {
                    acceptanceSection(acceptance)
                } else if state.approvedWithoutChoice {
                    Section {
                        Label("The customer approved this estimate without choosing an option, so the job keeps the recommended option’s price.",
                              systemImage: "checkmark.seal")
                    }
                } else if state.isReadOnly {
                    Section {
                        Label("The customer approved this estimate. Their choice is applied on the next sync.",
                              systemImage: "checkmark.seal")
                    }
                }
                if state.isEditable {
                    ForEach(Array(state.tiers.enumerated()), id: \.element.id) { index, tier in
                        editableTierSection(tier, number: index + 1, state: state)
                    }
                } else {
                    readOnlyTiersSection(state)
                }
                addOnsSection(state)
                if state.isEditable {
                    Section {
                        Button(role: .destructive) {
                            showingRemoveOptions = true
                        } label: {
                            Label("Remove options", systemImage: "rectangle.stack.badge.minus")
                                .nativeDestructiveText()
                        }
                    } footer: {
                        Text("Go back to a single price, keeping one option’s pricing.")
                    }
                }
            }
        }
        .nativeContentColumn(.list)
        .scrollContentBackground(.hidden)
        .background(Color.tradeCanvas)
    }

    // MARK: - Sections

    @ViewBuilder
    private func startSection(_ state: NativeQuoteOptionsState) -> some View {
        Section {
            Text("Give the customer 2 or 3 options to choose from, like repair, standard or high-efficiency, plus optional add-ons they can tick on the approval page.")
            if state.isEditable {
                Button("Start options", systemImage: "square.stack.3d.up") {
                    perform { store.startQuoteOptions(jobID: jobID) }
                }
            }
        } footer: {
            if state.isEditable {
                Text("Your current pricing (\(money(state.jobTotal))) becomes the first option and a copy becomes the second. Edit the copy’s pricing to make it different.")
            } else {
                Text("Options can be added while the job is a lead or an estimate awaiting a reply.")
            }
        }
    }

    private func acceptanceSection(_ acceptance: NativeQuoteOptionsState.Acceptance) -> some View {
        Section {
            LabeledContent("Option", value: acceptance.tierName)
            if !acceptance.addOnLabels.isEmpty {
                LabeledContent("Add-ons", value: acceptance.addOnLabels.joined(separator: ", "))
            }
            LabeledContent("Accepted total", value: money(acceptance.total))
                .font(.headline)
        } header: {
            Text("Customer’s choice")
        } footer: {
            Text(acceptance.viaLink
                 ? "Chosen on the approval page. The job, invoice and deposit use this price."
                 : "Recorded by you. The job, invoice and deposit use this price.")
        }
    }

    private func editableTierSection(
        _ tier: NativeQuoteOptionsState.Tier,
        number: Int,
        state: NativeQuoteOptionsState
    ) -> some View {
        Section {
            NativeQuoteTierTextFields(jobID: jobID, tier: tier, onFailure: { errorMessage = $0 })
                .id(tier.id)
            LabeledContent("Price", value: money(tier.total))
                .font(.headline)
            Toggle("Recommended", isOn: Binding(
                get: { tier.isRecommended },
                set: { recommended in
                    guard recommended else { return }
                    perform { store.setRecommendedQuoteTier(jobID: jobID, tierID: tier.id) }
                }
            ))
            .disabled(tier.isRecommended)
            .accessibilityHint(tier.isRecommended
                               ? "This option is pre-selected for the customer"
                               : "Pre-selects this option for the customer and uses its price for the job")
            Button("Edit pricing", systemImage: "function") {
                openPricing(for: tier)
            }
            Button("Duplicate option", systemImage: "plus.square.on.square") {
                perform { store.duplicateQuoteTier(jobID: jobID, tierID: tier.id) }
            }
            .disabled(!state.canDuplicateTier)
            Button(role: .destructive) {
                tierPendingDelete = tier
            } label: {
                Label("Delete option", systemImage: "trash")
                    .nativeDestructiveText()
            }
            .disabled(!state.canDeleteTier)
        } header: {
            Text("Option \(number)")
        } footer: {
            if number == state.tiers.count {
                Text("The recommended option is pre-selected for the customer and is the job’s price until they choose. Up to 3 options.")
            }
        }
    }

    private func readOnlyTiersSection(_ state: NativeQuoteOptionsState) -> some View {
        Section("Options") {
            ForEach(state.tiers) { tier in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tier.name).font(.body.weight(.semibold))
                        if !tier.description.isEmpty {
                            Text(tier.description).font(.footnote).foregroundStyle(.secondary)
                        }
                        if tier.isAccepted {
                            Label("Chosen", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.tradeSuccessText)
                        } else if tier.isRecommended && state.acceptance == nil {
                            Text("Recommended").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(money(tier.total)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func addOnsSection(_ state: NativeQuoteOptionsState) -> some View {
        Section {
            if state.addOns.isEmpty {
                Text("No add-ons").foregroundStyle(.secondary)
            }
            ForEach(state.addOns) { addOn in
                if state.isEditable {
                    Button {
                        addOnEditor = NativeQuoteAddOnEditorDraft(addOn: addOn)
                    } label: {
                        addOnRow(addOn, showsAccepted: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edits this add-on")
                } else {
                    addOnRow(addOn, showsAccepted: state.acceptance != nil)
                }
            }
            .onDelete(perform: state.isEditable ? { offsets in
                let ids = offsets.map { state.addOns[$0].id }
                for id in ids {
                    guard perform({ store.deleteQuoteAddOn(jobID: jobID, addOnID: id) }) else { break }
                }
            } : nil)
            if state.isEditable {
                Button("Add add-on", systemImage: "plus") {
                    addOnEditor = NativeQuoteAddOnEditorDraft()
                }
                .disabled(!state.canAddAddOn)
            }
        } header: {
            Text("Optional add-ons")
        } footer: {
            if state.isEditable {
                Text("Customers can tick these on the approval page. Prices are flat and all-in. Your internal cost stays private. Up to 10.")
            }
        }
    }

    private func addOnRow(_ addOn: NativeQuoteOptionsState.AddOn, showsAccepted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(addOn.label)
                if !addOn.description.isEmpty {
                    Text(addOn.description).font(.footnote).foregroundStyle(.secondary)
                }
                if showsAccepted {
                    Text(addOn.isAccepted ? "Added by the customer" : "Not chosen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text("+\(money(addOn.price))").monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func openPricing(for tier: NativeQuoteOptionsState.Tier) {
        guard let draft = store.quoteTierPricingDraft(jobID: jobID, tierID: tier.id) else {
            errorMessage = "That option no longer exists. Nothing was changed."
            return
        }
        tierPricing = NativeQuoteTierPricingDraft(tierID: tier.id, tierName: tier.name, draft: draft)
    }

    /// Runs one store edit and shows its refusal, if any.
    @discardableResult
    private func perform(_ action: () -> Bool) -> Bool {
        let saved = action()
        if !saved { errorMessage = store.migrationMessage ?? "The options could not be updated." }
        return saved
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.currency
    }
}

/// The calculator sheet's item for one tier.
struct NativeQuoteTierPricingDraft: Identifiable {
    let tierID: String
    let tierName: String
    let draft: NativeJobPricingDraft

    var id: String { tierID }
}

/// A tier's customer-facing name and description. Each field commits on
/// Return or when focus leaves it; a refused value (blank or too long) snaps
/// back to the saved text and the parent explains why.
private struct NativeQuoteTierTextFields: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String
    let tier: NativeQuoteOptionsState.Tier
    let onFailure: (String) -> Void

    @State private var name: String
    @State private var description: String
    @FocusState private var focus: Field?

    private enum Field { case name, description }

    init(jobID: String, tier: NativeQuoteOptionsState.Tier, onFailure: @escaping (String) -> Void) {
        self.jobID = jobID
        self.tier = tier
        self.onFailure = onFailure
        _name = State(initialValue: tier.name)
        _description = State(initialValue: tier.description)
    }

    var body: some View {
        TextField("Option name", text: $name)
            .font(.body.weight(.semibold))
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .focused($focus, equals: .name)
            .onSubmit(commitName)
            .accessibilityLabel("Option name")
        TextField("Description the customer sees (optional)", text: $description, axis: .vertical)
            .lineLimit(1...4)
            .focused($focus, equals: .description)
            .accessibilityLabel("Option description")
            .onChange(of: focus) { previous, _ in
                if previous == .name { commitName() }
                if previous == .description { commitDescription() }
            }
            .onChange(of: tier.name) { _, saved in if focus != .name { name = saved } }
            .onChange(of: tier.description) { _, saved in if focus != .description { description = saved } }
            .onDisappear {
                commitName()
                commitDescription()
            }
    }

    private func commitName() {
        guard name != tier.name else { return }
        if !store.renameQuoteTier(jobID: jobID, tierID: tier.id, name: name) {
            name = tier.name
            onFailure(store.migrationMessage ?? "The option name could not be saved.")
        }
    }

    private func commitDescription() {
        guard description != tier.description else { return }
        if !store.describeQuoteTier(jobID: jobID, tierID: tier.id, description: description) {
            description = tier.description
            onFailure(store.migrationMessage ?? "The option description could not be saved.")
        }
    }
}

// MARK: - Add-on editor

/// The add-on sheet's editable copy; `addOnID` nil means a new add-on.
struct NativeQuoteAddOnEditorDraft: Identifiable {
    let addOnID: String?
    /// The id a new add-on is saved under, minted once per editor sheet, so
    /// a repeated Save (a double tap) rewrites that same add-on instead of
    /// creating a second one (`NativeQuoteOptions.addAddOn`).
    let newAddOnID: String
    var label: String
    var description: String
    var price: Decimal?
    var cost: Decimal?

    var id: String { addOnID ?? newAddOnID }

    init(newAddOnID: String = NativeQuoteOptions.newAddOnID()) {
        addOnID = nil
        self.newAddOnID = newAddOnID
        label = ""
        description = ""
    }

    init(addOn: NativeQuoteOptionsState.AddOn) {
        addOnID = addOn.id
        newAddOnID = addOn.id
        label = addOn.label
        description = addOn.description
        price = addOn.price
        cost = addOn.cost
    }
}

struct NativeQuoteAddOnEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var draft: NativeQuoteAddOnEditorDraft
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(jobID: String, draft: NativeQuoteAddOnEditorDraft) {
        self.jobID = jobID
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Surge protector", text: $draft.label)
                        .textInputAutocapitalization(.sentences)
                    TextField("Description the customer sees (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(1...4)
                    LabeledContent("Price") {
                        HStack(spacing: 3) {
                            Text("$").foregroundStyle(.secondary)
                            TextField("0", value: $draft.price, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 64)
                                .accessibilityLabel("Price")
                        }
                    }
                } footer: {
                    Text("A flat, all-in price added to whichever option the customer chooses.")
                }
                Section {
                    LabeledContent("Your cost") {
                        HStack(spacing: 3) {
                            Text("$").foregroundStyle(.secondary)
                            TextField("Optional", value: $draft.cost, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 64)
                                .accessibilityLabel("Your cost")
                        }
                    }
                } footer: {
                    Text("Private. Used only for job profitability; never shown to the customer.")
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(draft.addOnID == nil ? "New add-on" : "Edit add-on")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(isSaving)
                }
            }
            .alert("Couldn’t save add-on", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
            .nativeAnalyticsScreen(.quoteAddOnEditor)
        }
    }

    private func save() {
        // A second tap before the sheet closes is ignored; the add-on id is
        // fixed per sheet as well, so even a repeated save cannot duplicate.
        guard !isSaving else { return }
        isSaving = true
        let value = NativeQuoteAddOnDraft(
            label: draft.label,
            description: draft.description,
            price: draft.price ?? 0,
            cost: draft.cost
        )
        let saved = if let addOnID = draft.addOnID {
            store.editQuoteAddOn(jobID: jobID, addOnID: addOnID, draft: value)
        } else {
            store.addQuoteAddOn(jobID: jobID, draft: value, addOnID: draft.newAddOnID)
        }
        if saved {
            dismiss()
        } else {
            isSaving = false
            errorMessage = store.migrationMessage ?? "The add-on could not be saved."
        }
    }
}

// MARK: - Owner-recorded choice

/// Spec §6.4 manual approval: "Mark as approved by customer" on a sent
/// estimate with options asks which option (and add-ons) the customer
/// agreed to, then records it and approves the job in one commit.
struct NativeQuoteOwnerChoiceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String

    @State private var tierID: String?
    @State private var addOnIDs: Set<String> = []
    @State private var errorMessage: String?

    private var state: NativeQuoteOptionsState? { store.quoteOptionsState(jobID: jobID) }

    var body: some View {
        NavigationStack {
            Form {
                if let state {
                    Section("Which option did they choose?") {
                        ForEach(state.tiers) { tier in
                            Button {
                                tierID = tier.id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedTierID(state) == tier.id
                                          ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(Color.tradeReady)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tier.name)
                                        if tier.isRecommended {
                                            Text("Recommended").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(money(tier.total)).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(selectedTierID(state) == tier.id ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    if !state.addOns.isEmpty {
                        Section("Add-ons they want") {
                            ForEach(state.addOns) { addOn in
                                Toggle(isOn: Binding(
                                    get: { addOnIDs.contains(addOn.id) },
                                    set: { on in
                                        if on { addOnIDs.insert(addOn.id) } else { addOnIDs.remove(addOn.id) }
                                    }
                                )) {
                                    LabeledContent(addOn.label, value: "+\(money(addOn.price))")
                                }
                            }
                        }
                    }
                    Section {
                        LabeledContent("Total", value: total(state).map(money) ?? "—")
                            .font(.headline)
                    } footer: {
                        Text("Approves the job at this price. The invoice and any deposit use it.")
                    }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Customer’s choice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve", action: record)
                        .fontWeight(.semibold)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(state.map { selectedTierID($0) == nil } ?? true)
                }
            }
            .alert("Couldn’t record approval", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
            .nativeAnalyticsScreen(.quoteOwnerChoice)
        }
    }

    /// The picked tier, defaulting to the recommended one.
    private func selectedTierID(_ state: NativeQuoteOptionsState) -> String? {
        tierID ?? state.tiers.first(where: \.isRecommended)?.id
    }

    private func total(_ state: NativeQuoteOptionsState) -> Decimal? {
        guard let id = selectedTierID(state), let tier = state.tiers.first(where: { $0.id == id }) else { return nil }
        let amounts = state.addOns.filter { addOnIDs.contains($0.id) }.map(\.price)
        return NativeQuoteOptions.selectionTotal(tierTotal: tier.total, addOnAmounts: amounts)
    }

    private func record() {
        guard let state, let tierID = selectedTierID(state) else { return }
        let ordered = state.addOns.map(\.id).filter(addOnIDs.contains)
        if store.recordOwnerQuoteAcceptance(jobID: jobID, tierID: tierID, addOnIDs: ordered) {
            dismiss()
        } else {
            errorMessage = store.migrationMessage ?? "The approval could not be recorded."
        }
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.currency
    }
}
