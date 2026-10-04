import PhotosUI
import SwiftUI
import UIKit

// MARK: - Phase 20: job forms owner flows (spec §4)
//
// Job detail › "Forms & checklists", the "Add form" picker and the fill
// screen. Every change goes through the `AppStore` forms API
// (`NativeJobFormsStore.swift`), which re-reads the stored form and commits
// one `forms` upsert; these views keep only what is being typed. The text,
// grouping and state rules are pure and host-tested in
// `Domain/NativeJobFormsPresentation.swift`.

/// Job detail › "Forms & checklists" (just before Photos): the job's form
/// instances with progress ("7/12") and a text status badge, and "Add form".
struct NativeJobFormsSection: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String
    @State private var showingPicker = false
    @State private var addedFormID: String?
    @State private var openForm: NativeOpenForm?
    @State private var confirmationRequest: NativeConfirmationRequest?
    @State private var errorMessage: String?

    var body: some View {
        let forms = store.forms(forJob: jobID)
        Section {
            if forms.isEmpty {
                Text("No forms yet. Add a checklist or inspection to fill in on site.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(forms, id: \.id) { form in
                let summary = NativeJobFormsPresentation.rowSummary(
                    form, hasUnsavedText: store.hasHeldFormText(formID: form.id)
                )
                Button {
                    openForm = NativeOpenForm(id: form.id)
                } label: {
                    NativeJobFormRow(summary: summary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summary.accessibilityLabel)
                .accessibilityHint("Opens the form")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        confirmationRequest = .deleteForm(id: form.id, title: form.title)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.tradeDangerFill)
                }
            }
            Button {
                showingPicker = true
            } label: {
                Label("Add form", systemImage: "plus.circle")
            }
        } header: {
            Text("Forms & checklists")
        }
        .sheet(isPresented: $showingPicker, onDismiss: openAddedForm) {
            NativeFormPickerView(jobID: jobID) { addedFormID = $0 }
        }
        .sheet(item: $openForm) { target in
            NativeJobFormView(formID: target.id)
        }
        .nativeConfirmation($confirmationRequest) { intent in
            guard case .deleteForm(let recordID) = intent else { return }
            if !store.deleteForm(id: recordID) {
                errorMessage = "The form could not be deleted. Nothing was changed."
            }
        }
        .alert("Couldn't delete form", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// A form added from the picker opens as soon as the picker closes.
    private func openAddedForm() {
        guard let id = addedFormID else { return }
        addedFormID = nil
        openForm = NativeOpenForm(id: id)
    }
}

private struct NativeOpenForm: Identifiable {
    let id: String
}

private struct NativeJobFormRow: View {
    let summary: NativeJobFormsPresentation.RowSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .foregroundStyle(Color.tradeReady)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .foregroundStyle(.primary)
                NativeAccessibilityAdaptiveRow(alignment: .center, spacing: 8) {
                    Text("\(summary.progressLabel) answered")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    NativeFormStatusBadge(isCompleted: summary.isCompleted, label: summary.statusLabel)
                }
                if let unsaved = summary.unsavedLabel {
                    NativeFormUnsavedLabel(text: unsaved)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.forward")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// "Completed" or "In progress", as text with a symbol: never color alone.
private struct NativeFormStatusBadge: View {
    let isCompleted: Bool
    let label: String

    var body: some View {
        Label(label, systemImage: isCompleted ? "checkmark.seal.fill" : "circle.dashed")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isCompleted ? Color.tradeSuccessText : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isCompleted ? Color.tradeSuccessText : Color.secondary).opacity(0.12), in: Capsule())
    }
}

// MARK: - Add form picker

/// The owner's custom templates, then the built-ins for the owner's trade,
/// then General; "Show every trade" appends the rest (spec §3).
struct NativeFormPickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    let onAdded: (String) -> Void
    @State private var showAll = false
    @State private var addingID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.formPickerSections(showAll: showAll)) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            Button {
                                add(entry)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).foregroundStyle(.primary)
                                        Text(NativeJobFormsPresentation.itemCountLabel(entry.itemCount))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if addingID == entry.id {
                                        ProgressView()
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(addingID != nil)
                            .accessibilityLabel(NativeJobFormsPresentation.pickerEntryAccessibilityLabel(entry))
                            .accessibilityHint("Adds this form to the job")
                        }
                    }
                }
                Section {
                    Toggle("Show templates for every trade", isOn: $showAll)
                } footer: {
                    Text("Built-in templates are general good practice, not a code or compliance check. Save any form as your own template from the form.")
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle("Add Form")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .alert("Couldn't add form", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func add(_ entry: NativeJobForms.PickerEntry) {
        guard addingID == nil else { return }
        addingID = entry.id
        switch store.addForm(jobID: jobID, templateRef: entry.ref) {
        case let .success(form):
            onAdded(form.id)
            dismiss()
        case let .failure(error):
            addingID = nil
            errorMessage = NativeJobFormsPresentation.message(for: error)
        }
    }
}

// MARK: - Fill screen

/// One form, filled in on site: items grouped by section, an answer control
/// per kind, a note and photos on every answerable item, then Mark complete
/// (or Reopen), Share PDF, Edit items, Save as template and Delete.
struct NativeJobFormView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let formID: String

    /// What is being typed, by item and field; committed on end-edit, after a
    /// pause, and before any action that reads the form. A draft is cleared
    /// only once it is saved: a refused one stays, marked "Not saved" with
    /// its reason, and is handed to the store if the screen closes.
    @State private var drafts: [NativeJobFormsPresentation.DraftKey: String] = [:]
    @State private var draftRefusals: [NativeJobFormsPresentation.DraftKey: NativeJobForms.FormError] = [:]
    @State private var unsavedOnClose: String?
    @State private var openedNotes: Set<String> = []
    /// After a refused "Mark complete", each missing item says what it needs.
    @State private var showsMissing = false
    @State private var notice: NativeFormNotice?
    @State private var isCompleting = false
    @State private var isExportingPDF = false
    @State private var pdfShare: NativeFormPDFShare?
    @State private var pdfCleanupURL: URL?
    @State private var confirmationRequest: NativeConfirmationRequest?
    @State private var showingTemplatePrompt = false
    @State private var templateTitle = ""
    @State private var cameraTarget: NativeFormItemTarget?
    @State private var photoAction: NativeFormPhotoTarget?
    @State private var viewerPhoto: NativeFormPhotoTarget?

    private var form: Canonical.Form? { store.form(id: formID) }

    var body: some View {
        NavigationStack {
            Group {
                if let form, let job = store.jobs.first(where: { $0.id == form.jobId }) {
                    content(form, job: job)
                } else {
                    ContentUnavailableView(
                        "Form unavailable",
                        systemImage: "checklist",
                        description: Text("This form is no longer on this device.")
                    )
                }
            }
            .navigationTitle(form?.title ?? "Form")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                        .fontWeight(.semibold)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .alert(
                NativeJobFormsPresentation.unsavedTextTitle,
                isPresented: Binding(get: { unsavedOnClose != nil }, set: { if !$0 { unsavedOnClose = nil } })
            ) {
                Button("Keep editing", role: .cancel) { unsavedOnClose = nil }
                Button("Close") {
                    unsavedOnClose = nil
                    dismiss()
                }
            } message: {
                Text(unsavedOnClose ?? "")
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                presenting: notice
            ) { _ in
                Button("OK", role: .cancel) { notice = nil }
            } message: { notice in
                Text(notice.message)
            }
            .nativeConfirmation($confirmationRequest) { intent in
                guard case .deleteForm(let recordID) = intent else { return }
                drafts = [:]
                draftRefusals = [:]
                if store.deleteForm(id: recordID) {
                    dismiss()
                } else {
                    notice = .init(title: "Couldn't delete form", message: "The form could not be deleted. Nothing was changed.")
                }
            }
            .sheet(item: $pdfShare, onDismiss: cleanupPDFShare) { share in
                NativeActivitySheet(items: [share.url])
                    .ignoresSafeArea()
            }
            .sheet(item: $cameraTarget) { target in
                NativeJobCamera { data, width, height in
                    importPhoto(data, width: width, height: height, itemID: target.itemID)
                    cameraTarget = nil
                }
                .ignoresSafeArea()
            }
            .sheet(item: $viewerPhoto) { target in
                if let photo = store.jobPhotos(for: target.jobID).first(where: { $0.id == target.photoID }) {
                    NativeJobPhotoViewer(photo: photo, bytes: store.jobPhotoBytes(photoID: photo.id))
                }
            }
        }
        .onAppear(perform: restoreHeldDrafts)
        .onDisappear(perform: holdUnsavedDrafts)
    }

    // MARK: Content

    private func content(_ form: Canonical.Form, job: Job) -> some View {
        let editable = NativeJobFormsPresentation.isEditable(form)
        let existing = Set(store.jobPhotos(for: job.id).map(\.id))
        let missing = showsMissing
            ? NativeJobFormsPresentation.missingByItem(store.formMissingItems(form)) : [:]
        return List {
            summarySection(form, job: job)
            ForEach(NativeJobFormsPresentation.itemGroups(form)) { group in
                Section {
                    ForEach(group.items, id: \.id) { item in
                        itemRow(item, jobID: job.id, editable: editable, existing: existing, missing: missing[item.id])
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
            actionsSection(form, job: job, editable: editable)
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .alert("Save as template", isPresented: $showingTemplatePrompt) {
            TextField("Template name", text: $templateTitle)
            Button("Save") { saveTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this form's title and items, without answers, notes or photos, so you can add it to other jobs.")
        }
        .confirmationDialog(
            "Photo",
            isPresented: Binding(get: { photoAction != nil }, set: { if !$0 { photoAction = nil } }),
            titleVisibility: .hidden,
            presenting: photoAction
        ) { target in
            if target.isResolved {
                Button("View photo") { viewerPhoto = target }
            }
            if editable {
                Button("Remove from this item", role: .destructive) {
                    report(store.removeFormItemPhoto(formID: formID, itemID: target.itemID, photoID: target.photoID))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(NativeJobFormsPresentation.photoActionMessage(isResolved: target.isResolved, editable: editable))
        }
    }

    private func summarySection(_ form: Canonical.Form, job: Job) -> some View {
        let progress = store.formProgress(form)
        let jobLine = [job.title, job.customerName].filter { !$0.isEmpty }.joined(separator: " · ")
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                if !jobLine.isEmpty {
                    Text(jobLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress.fraction)
                    .accessibilityHidden(true)
                NativeAccessibilityAdaptiveRow(alignment: .center, spacing: 8) {
                    Text(NativeJobFormsPresentation.progressText(progress))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                    Spacer(minLength: 4)
                    NativeFormStatusBadge(
                        isCompleted: form.isCompleted,
                        label: NativeJobFormsPresentation.statusText(form)
                    )
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if form.isCompleted {
                Label(NativeJobFormsPresentation.readOnlyNotice, systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionsSection(_ form: Canonical.Form, job: Job, editable: Bool) -> some View {
        Group {
            Section {
                if form.isCompleted {
                    Button {
                        reopen()
                    } label: {
                        Label("Reopen form", systemImage: "arrow.uturn.backward.circle")
                    }
                } else {
                    Button {
                        markComplete()
                    } label: {
                        Label(isCompleting ? "Checking…" : "Mark complete", systemImage: "checkmark.seal")
                    }
                    .disabled(isCompleting)
                }
                Button {
                    sharePDF(job: job)
                } label: {
                    Label(isExportingPDF ? "Preparing PDF…" : "Share PDF", systemImage: "square.and.arrow.up")
                }
                .disabled(isExportingPDF)
                NavigationLink {
                    NativeFormItemsEditor(formID: formID)
                } label: {
                    Label("Edit items", systemImage: "list.bullet.rectangle")
                }
                .disabled(!editable)
                Button {
                    // A new refusal's notice comes first; the prompt can wait.
                    guard commitDrafts().newProblem == nil else { return }
                    templateTitle = NativeJobFormsPresentation.defaultTemplateTitle(form)
                    showingTemplatePrompt = true
                } label: {
                    Label("Save as template", systemImage: "square.and.arrow.down.on.square")
                }
            } footer: {
                if form.isCompleted {
                    Text("Reopen the form to change its answers or items.")
                }
            }
            Section {
                Button(role: .destructive) {
                    confirmationRequest = .deleteForm(id: form.id, title: form.title)
                } label: {
                    Label("Delete form", systemImage: "trash").nativeDestructiveText()
                }
            }
        }
    }

    // MARK: Item rows

    @ViewBuilder
    private func itemRow(
        _ item: Canonical.FormItem,
        jobID: String,
        editable: Bool,
        existing: Set<String>,
        missing: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.itemKind {
            case .check:
                Toggle(isOn: checkedBinding(item)) { itemLabel(item) }
                    .disabled(!editable)
            case .passFail:
                itemLabel(item)
                Picker("Result for \(item.label)", selection: resultBinding(item)) {
                    ForEach(NativeJobForms.PassFailResult.allCases, id: \.self) { result in
                        Text(result.displayName).tag(Optional(result))
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!editable)
                if editable, item.passFailResult != nil {
                    Button("Clear result") {
                        report(store.setFormItemResult(formID: formID, itemID: item.id, nil))
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
            case .text:
                itemLabel(item)
                let answerKey = NativeJobFormsPresentation.DraftKey(itemID: item.id, field: .answer)
                NativeFormTextField(
                    prompt: "Answer",
                    accessibilityTitle: "Answer for \(item.label)",
                    text: draftBinding(item, .answer),
                    isEditable: editable,
                    onCommit: { commitDraft(answerKey) }
                )
                if let refusal = draftRefusals[answerKey] {
                    NativeFormUnsavedLabel(text: NativeJobFormsPresentation.unsavedFieldText(refusal))
                }
            case .section, nil:
                itemLabel(item)
                Text(NativeJobFormsPresentation.unsupportedItemMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if item.itemKind?.isAnswerable == true {
                noteArea(item, editable: editable)
                photoArea(item, jobID: jobID, editable: editable, existing: existing)
            }
            if let missing {
                Label(missing, systemImage: "exclamationmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.tradeWarningText)
                    .accessibilityLabel("Still needed: \(missing)")
            }
        }
        .padding(.vertical, 4)
    }

    private func itemLabel(_ item: Canonical.FormItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.label)
            if let flags = NativeJobFormsPresentation.flagsText(item) {
                Text(flags)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func noteArea(_ item: Canonical.FormItem, editable: Bool) -> some View {
        let key = NativeJobFormsPresentation.DraftKey(itemID: item.id, field: .note)
        if NativeJobFormsPresentation.showsNote(item, opened: openedNotes.contains(item.id) || drafts[key] != nil) {
            NativeFormTextField(
                prompt: "Note",
                accessibilityTitle: "Note for \(item.label)",
                text: draftBinding(item, .note),
                isEditable: editable,
                onCommit: { commitDraft(key) }
            )
            .font(.subheadline)
            if let refusal = draftRefusals[key] {
                NativeFormUnsavedLabel(text: NativeJobFormsPresentation.unsavedFieldText(refusal))
            }
        } else if editable {
            Button {
                openedNotes.insert(item.id)
            } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func photoArea(_ item: Canonical.FormItem, jobID: String, editable: Bool, existing: Set<String>) -> some View {
        let slots = NativeJobFormsPresentation.photoSlots(item, existingPhotoIDs: existing)
        if slots.storedCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(slots.resolvedIDs.enumerated()), id: \.element) { index, photoID in
                        let bytes = store.jobPhotoBytes(photoID: photoID)
                        Button {
                            photoAction = NativeFormPhotoTarget(jobID: jobID, itemID: item.id, photoID: photoID, isResolved: true)
                        } label: {
                            NativeFormPhotoThumbnail(photoID: photoID, bytes: bytes)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(NativeJobFormsPresentation.photoAccessibilityLabel(
                            index: index, count: slots.storedCount, itemLabel: item.label, isAvailable: bytes != nil
                        ))
                        .accessibilityHint("Shows photo actions")
                    }
                    // Linked photos whose record is not here (deleted, or not
                    // synced yet): shown, counted, and only removed by the owner.
                    ForEach(Array(slots.unresolvedIDs.enumerated()), id: \.element) { offset, photoID in
                        Button {
                            photoAction = NativeFormPhotoTarget(jobID: jobID, itemID: item.id, photoID: photoID, isResolved: false)
                        } label: {
                            NativeFormUnresolvedPhotoTile()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(NativeJobFormsPresentation.unresolvedPhotoAccessibilityLabel(
                            index: slots.resolvedIDs.count + offset, count: slots.storedCount, itemLabel: item.label
                        ))
                        .accessibilityHint("Shows photo actions")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        if editable {
            NativeAccessibilityAdaptiveRow(alignment: .center, spacing: 16) {
                if slots.isFull {
                    Text("This item has the most photos it can hold.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NativeFormPhotoButtons(
                        itemLabel: item.label,
                        remaining: slots.remaining,
                        onImport: { data, width, height in
                            importPhoto(data, width: width, height: height, itemID: item.id)
                        },
                        onCamera: { cameraTarget = NativeFormItemTarget(itemID: item.id) },
                        onReadFailure: {
                            notice = .init(title: "Photo not added", message: "A selected image could not be read.")
                        }
                    )
                }
                if slots.storedCount > 0 || item.isPhotoRequired {
                    Text(NativeJobFormsPresentation.photoCountLabel(slots))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Bindings

    private func checkedBinding(_ item: Canonical.FormItem) -> Binding<Bool> {
        Binding(
            get: { item.checked == true },
            set: { report(store.setFormItemChecked(formID: formID, itemID: item.id, $0)) }
        )
    }

    private func resultBinding(_ item: Canonical.FormItem) -> Binding<NativeJobForms.PassFailResult?> {
        Binding(
            get: { item.passFailResult },
            set: { report(store.setFormItemResult(formID: formID, itemID: item.id, $0)) }
        )
    }

    private func draftBinding(_ item: Canonical.FormItem, _ field: NativeJobFormsPresentation.TextSlot) -> Binding<String> {
        let key = NativeJobFormsPresentation.DraftKey(itemID: item.id, field: field)
        return Binding(
            get: { drafts[key] ?? NativeJobFormsPresentation.storedText(item, field: field) },
            set: { drafts[key] = NativeJobFormsPresentation.clamped($0, field: field) }
        )
    }

    // MARK: Actions

    /// Writes one typed answer or note if it differs from what is stored.
    private func commitDraft(_ key: NativeJobFormsPresentation.DraftKey) {
        commitDrafts(only: [key])
    }

    /// Writes the typed answers and notes that differ from what is stored. A
    /// draft is cleared only once saved; a refused one stays with its reason
    /// (`NativeJobFormsPresentation.commitDrafts`), and a new refusal is
    /// shown once.
    @discardableResult
    private func commitDrafts(
        only keys: [NativeJobFormsPresentation.DraftKey]? = nil,
        announce: Bool = true
    ) -> NativeJobFormsPresentation.DraftCommitOutcome {
        let outcome = NativeJobFormsPresentation.commitDrafts(
            drafts, refusals: draftRefusals, only: keys, form: form
        ) { key, value in
            switch key.field {
            case .answer: store.setFormItemText(formID: formID, itemID: key.itemID, value)
            case .note: store.setFormItemNote(formID: formID, itemID: key.itemID, value)
            }
        }
        if drafts != outcome.drafts { drafts = outcome.drafts }
        if draftRefusals != outcome.refusals { draftRefusals = outcome.refusals }
        if announce, let problem = outcome.newProblem {
            notice = .init(title: NativeJobFormsPresentation.unsavedTextTitle, message: NativeJobFormsPresentation.message(for: problem))
        }
        return outcome
    }

    /// Done: closes once every typed text is saved. Otherwise the owner
    /// chooses Keep editing, or Close, which hands the text to the store.
    private func done() {
        let outcome = commitDrafts(announce: false)
        if outcome.isAllSaved, outcome.dropped.isEmpty {
            dismiss()
        } else if outcome.isAllSaved, let problem = outcome.newProblem {
            // Text for an item removed meanwhile: say so before closing.
            notice = .init(title: NativeJobFormsPresentation.unsavedTextTitle, message: NativeJobFormsPresentation.message(for: problem))
        } else {
            unsavedOnClose = NativeJobFormsPresentation.unsavedOnCloseMessage(
                count: outcome.drafts.count,
                reason: NativeJobFormsPresentation.firstRefusal(outcome.refusals, form: form)
            )
        }
    }

    /// Text this form's screen closed without saving comes back into its
    /// fields, still marked "Not saved", with a notice.
    private func restoreHeldDrafts() {
        guard let held = store.takeHeldFormDrafts(formID: formID) else { return }
        let restoration = NativeJobFormsPresentation.draftRestoration(drafts: held.drafts, refusals: held.refusals, form: form)
        guard let message = restoration.message else { return }
        drafts.merge(restoration.drafts) { current, _ in current }
        draftRefusals.merge(restoration.refusals) { current, _ in current }
        notice = .init(title: NativeJobFormsPresentation.unsavedTextTitle, message: message)
    }

    /// Closing (Done, a swipe, or the job going away) makes a last try; what
    /// is still refused is held by the store, never dropped silently.
    private func holdUnsavedDrafts() {
        let outcome = commitDrafts(announce: false)
        store.holdFormDrafts(outcome.drafts, refusals: outcome.refusals, formID: formID)
    }

    private func markComplete() {
        guard !isCompleting else { return }
        isCompleting = true
        defer { isCompleting = false }
        // Completing locks the form: every typed text must be saved first.
        let outcome = commitDrafts()
        guard outcome.isAllSaved, outcome.newProblem == nil else {
            if outcome.newProblem == nil, let reason = NativeJobFormsPresentation.firstRefusal(outcome.refusals, form: form) {
                notice = .init(title: NativeJobFormsPresentation.unsavedTextTitle, message: NativeJobFormsPresentation.message(for: reason))
            }
            return
        }
        switch store.completeForm(id: formID) {
        case .completed:
            showsMissing = false
        case let .incomplete(missing):
            showsMissing = true
            notice = .init(
                title: NativeJobFormsPresentation.incompleteTitle,
                message: NativeJobFormsPresentation.incompleteMessage(missing)
            )
        case let .failed(error):
            notice = .init(title: "Couldn't complete form", message: NativeJobFormsPresentation.message(for: error))
        }
    }

    private func reopen() {
        switch store.reopenForm(id: formID) {
        case .success:
            // Text kept while the form was read-only can be saved now.
            commitDrafts()
        case let .failure(error):
            notice = .init(title: "Couldn't reopen form", message: NativeJobFormsPresentation.message(for: error))
        }
    }

    private func saveTemplate() {
        switch store.saveFormAsTemplate(id: formID, title: templateTitle) {
        case let .success(template):
            notice = .init(title: "Template saved", message: NativeJobFormsPresentation.templateSavedMessage(template))
        case let .failure(error):
            notice = .init(title: "Couldn't save template", message: NativeJobFormsPresentation.message(for: error))
        }
    }

    /// Captured bytes go through the job-photo pipeline stamped with this form
    /// item, so the photo also shows in the job's Photos section.
    private func importPhoto(_ data: Data, width: Int?, height: Int?, itemID: String) {
        guard let form, let jobID = form.jobId,
              let item = form.items.first(where: { $0.id == itemID })
        else { return }
        let existing = Set(store.jobPhotos(for: jobID).map(\.id))
        let slots = NativeJobFormsPresentation.photoSlots(item, existingPhotoIDs: existing)
        // Every stored link counts, so this matches the domain's cap. Links to
        // photos not on this device are never detached here: they may not
        // have synced yet (review fix 2026-10-03).
        guard !slots.isFull else {
            notice = .init(title: "Photo not added", message: NativeJobFormsPresentation.message(for: .tooManyPhotos))
            return
        }
        guard store.createJobPhoto(
            jobID: jobID, sourceData: data, width: width, height: height, formID: formID, formItemID: itemID
        ) != nil else {
            notice = .init(
                title: "Photo not added",
                message: "The photo could not be added to this item. Use a smaller image and try again."
            )
            return
        }
    }

    /// Renders the stored form off the main thread into a temporary file kept
    /// alive through the share sheet and removed on dismissal.
    private func sharePDF(job: Job) {
        guard !isExportingPDF else { return }
        // A new refusal's notice comes first. Text already marked "Not
        // saved" (say, on a form completed elsewhere) doesn't block sharing
        // the saved form.
        guard commitDrafts().newProblem == nil else { return }
        guard let current = store.form(id: formID) else { return }
        isExportingPDF = true
        cleanupPDFShare()
        let photos = store.jobPhotos(for: job.id)
        let referenced = Set(current.items.flatMap { $0.photoIds ?? [] })
        // Only where each photo's bytes are: the render task reads and
        // downscales them one at a time (review fix 2026-10-03).
        var files: [String: URL] = [:]
        for photo in photos where referenced.contains(photo.id) {
            if let url = store.jobPhotoFileURL(photoID: photo.id) { files[photo.id] = url }
        }
        let settings = store.settings
        let document = NativeFormPDFDocument(
            form: current,
            jobTitle: job.title,
            customerName: job.customerName,
            jobAddress: job.address,
            businessName: settings.businessName,
            businessContactName: settings.contactName,
            businessPhone: settings.phone,
            businessEmail: settings.email,
            businessAddress: settings.address,
            jobPhotos: photos,
            availablePhotoIDs: Set(files.keys)
        )
        let logo = settings.logoPhoto
        let photoFiles = files
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let data = try NativeFormPDFRenderer.data(for: document, logoReference: logo, photoFiles: photoFiles)
                    let directory = FileManager.default.temporaryDirectory
                        .appending(path: "TradeReadyFormExports", directoryHint: .isDirectory)
                        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appending(path: document.filename, directoryHint: .notDirectory)
                    try data.write(to: url, options: .atomic)
                    return url
                }.value
                pdfCleanupURL = url
                pdfShare = NativeFormPDFShare(url: url)
            } catch {
                notice = .init(
                    title: "Couldn't create PDF",
                    message: (error as? LocalizedError)?.errorDescription
                        ?? "The form PDF could not be created. Your form was not changed."
                )
            }
            isExportingPDF = false
        }
    }

    private func cleanupPDFShare() {
        pdfShare = nil
        guard let url = pdfCleanupURL else { return }
        pdfCleanupURL = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func report<T>(_ result: Result<T, NativeJobForms.FormError>) {
        if case let .failure(error) = result {
            notice = .init(title: "Not saved", message: NativeJobFormsPresentation.message(for: error))
        }
    }
}

// MARK: - Fill screen pieces

private struct NativeFormNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct NativeFormItemTarget: Identifiable {
    let itemID: String
    var id: String { itemID }
}

private struct NativeFormPhotoTarget: Identifiable {
    let jobID: String
    let itemID: String
    let photoID: String
    /// False for a linked photo whose record is not on this device.
    let isResolved: Bool
    var id: String { "\(itemID)/\(photoID)" }
}

/// "Not saved…" or "Unsaved text": a symbol and text, never color alone.
private struct NativeFormUnsavedLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.tradeWarningText)
    }
}

/// One frozen PDF share: the temp file lives through the share sheet and is
/// removed on dismissal.
private struct NativeFormPDFShare: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// A multi-line answer or note. It commits when editing ends and after a
/// pause in typing, never on every keystroke (spec §4).
private struct NativeFormTextField: View {
    let prompt: String
    let accessibilityTitle: String
    @Binding var text: String
    let isEditable: Bool
    let onCommit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(1 ... 8)
            .focused($focused)
            .disabled(!isEditable)
            .accessibilityLabel(accessibilityTitle)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit() }
            }
            .task(id: text) {
                guard focused else { return }
                try? await Task.sleep(for: .seconds(NativeJobFormsPresentation.textCommitDebounceSeconds))
                guard !Task.isCancelled, focused else { return }
                onCommit()
            }
    }
}

/// Library and camera capture for one form item. The library picker never
/// offers more photos than the item has room for.
private struct NativeFormPhotoButtons: View {
    let itemLabel: String
    let remaining: Int
    let onImport: (Data, Int?, Int?) -> Void
    let onCamera: () -> Void
    let onReadFailure: () -> Void
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        HStack(spacing: 16) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, remaining), matching: .images) {
                Label("Library", systemImage: "photo.on.rectangle.angled")
            }
            .accessibilityLabel("Add photos from the library for \(itemLabel)")
            .onChange(of: pickerItems) { _, items in load(items) }
            Button(action: onCamera) {
                Label("Camera", systemImage: "camera")
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            .accessibilityLabel("Take a photo for \(itemLabel)")
        }
        .font(.footnote)
        .buttonStyle(.borderless)
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        for item in items {
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        await MainActor.run { onReadFailure() }
                        return
                    }
                    await MainActor.run { onImport(data, nil, nil) }
                } catch {
                    await MainActor.run { onReadFailure() }
                }
            }
        }
    }
}

/// A linked photo whose record is not on this device (deleted, or not synced
/// here yet): a same-size tile that says so in text.
private struct NativeFormUnresolvedPhotoTile: View {
    @ScaledMetric(relativeTo: .caption2) private var scaledSide: CGFloat = 72

    private var side: CGFloat { min(max(scaledSide, 72), 120) }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "questionmark.square.dashed")
                .font(.title3)
            Text(NativeJobFormsPresentation.unresolvedPhotoTileText)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.secondary)
        .padding(6)
        .frame(width: side, height: side)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A form item's photo, decoded to a small thumbnail off the row's render.
private struct NativeFormPhotoThumbnail: View {
    let photoID: String
    let bytes: Data?
    @ScaledMetric(relativeTo: .caption2) private var scaledSide: CGFloat = 72
    @State private var image: UIImage?

    private var side: CGFloat { min(max(scaledSide, 72), 120) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.12)
                Image(systemName: bytes == nil ? "arrow.down.circle" : "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: photoID) {
            guard let bytes, let full = UIImage(data: bytes) else { return }
            image = await full.byPreparingThumbnail(ofSize: CGSize(width: 240, height: 240)) ?? full
        }
    }
}
