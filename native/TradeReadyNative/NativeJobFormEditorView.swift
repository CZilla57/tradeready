import SwiftUI

// MARK: - Phase 20: form edit mode and template management (spec §4)
//
// The items editor (rename, add, edit, delete, reorder, with the spec §2
// caps) serves both an in-progress job form and a custom template; Settings ›
// Forms & checklists lists the owner's templates and archives them. Every
// change is one `AppStore` forms call; refusals come back as typed errors
// shown as text alerts (`NativeJobFormsPresentation.message(for:)`).

/// Edit mode for one form or template. Pushed inside the form sheet's stack
/// or Settings' stack, so it hosts no `NavigationStack` of its own.
struct NativeFormItemsEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let formID: String
    /// The typed title, cleared only once saved. A refused one stays, marked
    /// "Not saved" with its reason, and is handed to the store if the editor
    /// closes (review fix 2026-10-03).
    @State private var titleDraft: String?
    @State private var titleRefusal: NativeJobForms.FormError?
    @FocusState private var titleFocused: Bool
    @State private var itemSheet: NativeFormItemSheetTarget?
    @State private var pendingDeleteID: String?
    @State private var showingArchiveConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let form = store.form(id: formID), form.formKind != nil {
                editor(form)
            } else {
                ContentUnavailableView(
                    "Form unavailable",
                    systemImage: "checklist",
                    description: Text("This form is no longer on this device.")
                )
            }
        }
        .navigationTitle(store.form(id: formID)?.isTemplate == true ? "Edit Template" : "Edit Items")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $itemSheet) { target in
            if let initial = initialDraft(for: target) {
                NativeFormItemSheet(formID: formID, target: target, initial: initial)
            }
        }
        .alert("Not saved", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: restoreHeldTitle)
        .onDisappear(perform: holdUnsavedTitle)
    }

    private func editor(_ form: Canonical.Form) -> some View {
        let editable = !(form.isInstance && form.isCompleted)
        let canDelete = NativeJobFormsPresentation.canDeleteItem(form)
        return List {
            Section("Title") {
                TextField("Form title", text: titleBinding(form))
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { commitTitle() }
                    // Same mechanism as the answer and note fields
                    // (`NativeFormTextField`): save when focus leaves the
                    // field and after a pause in typing (spec §4).
                    .onChange(of: titleFocused) { _, isFocused in
                        if !isFocused { commitTitle() }
                    }
                    .task(id: titleDraft) {
                        guard titleFocused else { return }
                        try? await Task.sleep(for: .seconds(NativeJobFormsPresentation.textCommitDebounceSeconds))
                        guard !Task.isCancelled, titleFocused else { return }
                        commitTitle()
                    }
                    .disabled(!editable)
                    .accessibilityLabel("Form title")
                if let titleRefusal {
                    Label(NativeJobFormsPresentation.unsavedFieldText(titleRefusal), systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.tradeWarningText)
                }
            }
            Section {
                ForEach(Array(form.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        if editable, item.itemKind != nil { itemSheet = .edit(item.id) }
                    } label: {
                        itemRow(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(item.itemKind == nil ? "" : "Edits this item")
                    .accessibilityAction(named: "Move up") { move(index, by: -1, in: form) }
                    .accessibilityAction(named: "Move down") { move(index, by: 1, in: form) }
                }
                .onMove { offsets, destination in
                    report(store.moveFormItems(formID: formID, fromOffsets: offsets, toOffset: destination))
                }
                .onDelete { offsets in
                    guard let index = offsets.first, form.items.indices.contains(index) else { return }
                    pendingDeleteID = form.items[index].id
                }
                .deleteDisabled(!canDelete || !editable)
                .moveDisabled(!editable)
                Button {
                    itemSheet = .add
                } label: {
                    Label("Add item", systemImage: "plus.circle")
                }
                .disabled(!NativeJobFormsPresentation.canAddItem(form))
            } header: {
                Text("Items")
            } footer: {
                Text("\(NativeJobFormsPresentation.itemCapText(form)). Tap an item to change it. Use Edit to reorder or delete.")
            }
            if form.isTemplate {
                Section {
                    Button(role: .destructive) {
                        showingArchiveConfirmation = true
                    } label: {
                        Label("Archive template", systemImage: "archivebox").nativeDestructiveText()
                    }
                } footer: {
                    Text("An archived template is hidden from Add form. Forms already made from it are not changed.")
                }
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .confirmationDialog(
            "Delete this item?",
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeleteID
        ) { itemID in
            Button("Delete item", role: .destructive) {
                pendingDeleteID = nil
                report(store.deleteFormItem(formID: formID, itemID: itemID))
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: { _ in
            Text(form.isTemplate
                 ? "It is removed from this template. Forms already made from it are not changed."
                 : "Its answer and note are removed. Its photos stay in the job's Photos section.")
        }
        .confirmationDialog("Archive template?", isPresented: $showingArchiveConfirmation, titleVisibility: .visible) {
            Button("Archive template", role: .destructive) { archive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(form.title)\" will be hidden from Add form. Forms already made from it are not changed.")
        }
    }

    private func itemRow(_ item: Canonical.FormItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: NativeJobFormsPresentation.kindSymbol(rawKind: item.kind))
                .foregroundStyle(Color.tradeReady)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(item.itemKind == .section ? .body.weight(.semibold) : .body)
                    .foregroundStyle(.primary)
                Text(([NativeJobFormsPresentation.kindName(rawKind: item.kind)]
                      + [NativeJobFormsPresentation.flagsText(item)].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func titleBinding(_ form: Canonical.Form) -> Binding<String> {
        Binding(
            get: { titleDraft ?? form.title },
            set: { titleDraft = String($0.prefix(NativeJobForms.Limits.titleMaxLength)) }
        )
    }

    /// Saves the typed title if it differs from the stored one. It is
    /// cleared only once saved; a new refusal is shown once.
    private func commitTitle(announce: Bool = true) {
        let outcome = NativeJobFormsPresentation.commitTitle(
            titleDraft, refusal: titleRefusal, stored: store.form(id: formID)?.title
        ) { store.renameForm(id: formID, title: $0) }
        if titleDraft != outcome.draft { titleDraft = outcome.draft }
        if titleRefusal != outcome.refusal { titleRefusal = outcome.refusal }
        if announce, let problem = outcome.newProblem {
            errorMessage = NativeJobFormsPresentation.message(for: problem)
        }
    }

    /// A title this editor closed without saving comes back, with a notice.
    private func restoreHeldTitle() {
        guard let held = store.takeHeldFormTitle(formID: formID),
              let title = NativeJobFormsPresentation.restoredTitle(held.title, stored: store.form(id: formID)?.title)
        else { return }
        titleDraft = title
        titleRefusal = held.refusal
        errorMessage = NativeJobFormsPresentation.restoredTitleMessage(reason: held.refusal)
    }

    /// Closing makes a last try; a title still refused is held by the store.
    private func holdUnsavedTitle() {
        commitTitle(announce: false)
        store.holdFormTitle(NativeJobFormsPresentation.titleToHold(titleDraft), refusal: titleRefusal, formID: formID)
    }

    private func move(_ index: Int, by step: Int, in form: Canonical.Form) {
        let target = index + step
        guard form.items.indices.contains(index), form.items.indices.contains(target) else { return }
        // `onMove` semantics: the destination is an index in the original list.
        let destination = step > 0 ? target + 1 : target
        report(store.moveFormItems(formID: formID, fromOffsets: IndexSet(integer: index), toOffset: destination))
    }

    private func archive() {
        switch store.archiveFormTemplate(id: formID) {
        case .success: dismiss()
        case let .failure(error): errorMessage = NativeJobFormsPresentation.message(for: error)
        }
    }

    private func initialDraft(for target: NativeFormItemSheetTarget) -> NativeJobFormsPresentation.ItemDraft? {
        switch target {
        case .add:
            return NativeJobFormsPresentation.ItemDraft()
        case let .edit(itemID):
            guard let item = store.form(id: formID)?.items.first(where: { $0.id == itemID }) else { return nil }
            return NativeJobFormsPresentation.itemDraft(for: item)
        }
    }

    private func report<T>(_ result: Result<T, NativeJobForms.FormError>) {
        if case let .failure(error) = result {
            errorMessage = NativeJobFormsPresentation.message(for: error)
        }
    }
}

enum NativeFormItemSheetTarget: Identifiable, Equatable {
    case add
    case edit(String)

    var id: String {
        switch self {
        case .add: "add"
        case let .edit(itemID): "edit:\(itemID)"
        }
    }
}

/// Add an item (kind, label, required and photo flags) or change one's label
/// and flags. A section heading takes no flags.
struct NativeFormItemSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let formID: String
    let target: NativeFormItemSheetTarget
    @State private var draft: NativeJobFormsPresentation.ItemDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(formID: String, target: NativeFormItemSheetTarget, initial: NativeJobFormsPresentation.ItemDraft) {
        self.formID = formID
        self.target = target
        _draft = State(initialValue: initial)
    }

    private var isAdding: Bool { target == .add }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isAdding {
                        Picker("Type", selection: $draft.kind) {
                            ForEach(NativeJobForms.ItemKind.allCases, id: \.self) { kind in
                                Text(NativeJobFormsPresentation.kindName(kind)).tag(kind)
                            }
                        }
                    } else {
                        LabeledContent("Type", value: NativeJobFormsPresentation.kindName(draft.kind))
                    }
                    LabeledField(label: draft.kind == .section ? "Heading" : "Label") {
                        TextField(
                            draft.kind == .section ? "e.g. Outdoor unit" : "e.g. Filter replaced",
                            text: Binding(
                                get: { draft.label },
                                set: { draft.label = String($0.prefix(NativeJobForms.Limits.labelMaxLength)) }
                            ),
                            axis: .vertical
                        )
                        .lineLimit(1 ... 4)
                        .accessibilityLabel(draft.kind == .section ? "Heading" : "Label")
                    }
                } footer: {
                    Text("Up to \(NativeJobForms.Limits.labelMaxLength) characters.")
                }
                if draft.kind.isAnswerable {
                    Section {
                        Toggle("Required to complete", isOn: $draft.required)
                        Toggle("Photo required", isOn: $draft.photoRequired)
                    } footer: {
                        Text("A form can't be marked complete until its required items are answered and each photo-required item has a photo.")
                    }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(isAdding ? "Add Item" : "Edit Item")
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
                        .disabled(!draft.isValid || isSaving)
                }
            }
            .alert("Not saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard draft.isValid, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let result: Result<Canonical.Form, NativeJobForms.FormError>
        switch target {
        case .add:
            result = store.addFormItem(
                formID: formID,
                kind: draft.kind,
                label: draft.trimmedLabel,
                required: draft.effectiveRequired,
                photoRequired: draft.effectivePhotoRequired
            ).map { $0.form }
        case let .edit(itemID):
            result = store.editFormItem(
                formID: formID,
                itemID: itemID,
                label: draft.trimmedLabel,
                required: draft.kind.isAnswerable ? draft.effectiveRequired : nil,
                photoRequired: draft.kind.isAnswerable ? draft.effectivePhotoRequired : nil
            )
        }
        switch result {
        case .success: dismiss()
        case let .failure(error): errorMessage = NativeJobFormsPresentation.message(for: error)
        }
    }
}

// MARK: - Settings › Forms & checklists

/// The owner's custom templates (edit or archive) and the built-in library
/// for reference. Archived templates are hidden here and from Add form.
struct NativeFormTemplatesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var archiveTarget: NativeFormArchiveTarget?
    @State private var errorMessage: String?

    var body: some View {
        let templates = store.customFormTemplates
        List {
            Section {
                if templates.isEmpty {
                    Text("No saved templates yet. Open a form on any job and choose Save as template.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(templates, id: \.id) { template in
                    NavigationLink {
                        NativeFormItemsEditor(formID: template.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.title)
                            Text(NativeJobFormsPresentation.itemCountLabel(template.items.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if store.hasHeldFormText(formID: template.id) {
                                Label(NativeJobFormsPresentation.unsavedTextLabel, systemImage: "exclamationmark.triangle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.tradeWarningText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            archiveTarget = NativeFormArchiveTarget(id: template.id, title: template.title)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.tradeReadyFill)
                    }
                }
            } header: {
                Text("Your templates")
            } footer: {
                Text("Changing a template never changes forms already added to jobs.")
            }
            Section {
                ForEach(NativeJobForms.builtinTemplates) { template in
                    LabeledContent(template.title, value: NativeJobFormsPresentation.itemCountLabel(template.items.count))
                }
            } header: {
                Text("Built-in")
            } footer: {
                Text("Always available in Add form, with your trade's templates first. General good practice, not a code or compliance check.")
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .navigationTitle("Forms & Checklists")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Archive template?",
            isPresented: Binding(get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } }),
            titleVisibility: .visible,
            presenting: archiveTarget
        ) { target in
            Button("Archive template", role: .destructive) {
                archiveTarget = nil
                if case let .failure(error) = store.archiveFormTemplate(id: target.id) {
                    errorMessage = NativeJobFormsPresentation.message(for: error)
                }
            }
            Button("Cancel", role: .cancel) { archiveTarget = nil }
        } message: { target in
            Text("\"\(target.title)\" will be hidden from Add form. Forms already made from it are not changed.")
        }
        .alert("Couldn't archive template", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct NativeFormArchiveTarget: Identifiable {
    let id: String
    let title: String
}
