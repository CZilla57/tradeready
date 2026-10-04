import Foundation

/// Phase 20 (custom job / inspection forms): the `AppStore` API the job-detail
/// "Forms & checklists" section, the form view and Settings › Forms &
/// checklists build on. Spec: `docs/superpowers/specs/2026-10-02-job-forms-design.md`.
///
/// Every write re-reads the stored row by id, applies one pure
/// `NativeJobForms` operation, validates the result and commits it as one
/// `forms` upsert through `commitFormRecord` (durable save, publish, then the
/// mutation queue). Nothing is changed on refusal. Identity fields (`kind`,
/// `jobId`, `templateId`, `createdAt`) and the lifecycle stamps
/// (`completedAt`, `archivedAt`) only change through their own methods.
extension AppStore {
    /// What `completeForm` did.
    enum FormCompletionOutcome: Equatable {
        /// Completed now, or already complete (nothing written then).
        case completed(Canonical.Form)
        /// Refused: what is still missing, in form order. Nothing changed.
        case incomplete([NativeJobForms.MissingItem])
        case failed(NativeJobForms.FormError)
    }

    // MARK: - Reads

    func form(id: String) -> Canonical.Form? {
        formRecords.first { $0.id == id }
    }

    /// The job's form instances, oldest first. Empty for a job that is not on
    /// this device: a deleted job's forms stay stored but hidden.
    func forms(forJob jobID: String) -> [Canonical.Form] {
        guard canonicalJobExists(id: jobID) else { return [] }
        return NativeJobForms.instances(forJob: jobID, in: formRecords)
    }

    /// The owner's custom templates that are not archived, by title.
    var customFormTemplates: [Canonical.Form] {
        NativeJobForms.activeTemplates(in: formRecords)
    }

    /// The "Add form" picker for the owner's trade (Settings' trade, in any
    /// spelling). `showAll` is the "All templates" toggle.
    func formPickerSections(showAll: Bool) -> [NativeJobForms.PickerSection] {
        NativeJobForms.pickerSections(ownerTrade: settings.trade, customTemplates: formRecords, showAll: showAll)
    }

    /// Answered over answerable items ("7/12").
    func formProgress(_ form: Canonical.Form) -> NativeJobForms.Progress {
        NativeJobForms.progress(form)
    }

    /// What blocks "Mark complete" right now (empty when it can complete).
    func formMissingItems(_ form: Canonical.Form) -> [NativeJobForms.MissingItem] {
        NativeJobForms.missingItems(form, existingPhotoIDs: formJobPhotoIDs(form))
    }

    /// The item's photos that still exist on this device, in the item's order.
    /// Ids of deleted photos are skipped.
    func formItemPhotos(formID: String, itemID: String) -> [Canonical.JobPhoto] {
        guard let form = form(id: formID), let jobID = form.jobId,
              let item = form.items.first(where: { $0.id == itemID })
        else { return [] }
        let photos = Dictionary(jobPhotos(for: jobID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (item.photoIds ?? []).compactMap { photos[$0] }
    }

    // MARK: - Create

    /// Adds an in-progress instance of a built-in or custom template to the
    /// job.
    @discardableResult
    func addForm(
        jobID: String,
        templateRef: NativeJobForms.TemplateRef,
        on date: Date = .now
    ) -> Result<Canonical.Form, NativeJobForms.FormError> {
        guard canonicalJobExists(id: jobID) else { return .failure(.jobNotFound) }
        let id = NativeJobForms.makeUniqueFormID(now: date, existingIDs: Set(formRecords.map(\.id)))
        do {
            let form = try NativeJobForms.instantiate(
                templateRef, customTemplates: formRecords, jobID: jobID, formID: id, now: date
            )
            return commitFormRecord(form, mode: .insert)
        } catch {
            return .failure(Self.formError(error))
        }
    }

    /// "Save as template" from any form: a new custom template with the
    /// form's title (or `title`) and items, every response stripped.
    @discardableResult
    func saveFormAsTemplate(
        id: String,
        title: String? = nil,
        on date: Date = .now
    ) -> Result<Canonical.Form, NativeJobForms.FormError> {
        guard let stored = form(id: id) else { return .failure(.notFound) }
        let templateID = NativeJobForms.makeUniqueFormID(now: date, existingIDs: Set(formRecords.map(\.id)))
        do {
            let template = try NativeJobForms.makeTemplate(from: stored, templateID: templateID, title: title, now: date)
            return commitFormRecord(template, mode: .insert)
        } catch {
            return .failure(Self.formError(error))
        }
    }

    // MARK: - Edit

    /// Saves a form's title and items as edited on screen. The stored row is
    /// re-read by id; everything else about it is kept. Refused for a
    /// completed instance (reopen first). An unchanged form writes nothing.
    @discardableResult
    func updateForm(_ form: Canonical.Form) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: form.id) { stored in
            var next = stored
            next.title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
            next.items = form.items
            return next
        }
    }

    /// Applies one pure `NativeJobForms` operation to the stored form and
    /// commits it, e.g. `store.mutateForm(id: id) { try NativeJobForms.setChecked($0, itemID: item, true) }`.
    @discardableResult
    func mutateForm(
        id: String,
        _ change: (Canonical.Form) throws -> Canonical.Form
    ) -> Result<Canonical.Form, NativeJobForms.FormError> {
        guard let stored = form(id: id) else { return .failure(.notFound) }
        if stored.isInstance {
            guard let jobID = stored.jobId, canonicalJobExists(id: jobID) else { return .failure(.jobNotFound) }
            guard !stored.isCompleted else { return .failure(.readOnlyCompleted) }
        }
        do {
            let changed = try change(stored)
            var next = stored
            next.title = changed.title
            next.items = changed.items
            try NativeJobForms.validate(next)
            guard next != stored else { return .success(stored) }
            return commitFormRecord(next, mode: .replace)
        } catch {
            return .failure(Self.formError(error))
        }
    }

    @discardableResult
    func setFormItemChecked(formID: String, itemID: String, _ checked: Bool) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.setChecked($0, itemID: itemID, checked) }
    }

    @discardableResult
    func setFormItemResult(
        formID: String,
        itemID: String,
        _ result: NativeJobForms.PassFailResult?
    ) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.setResult($0, itemID: itemID, result) }
    }

    /// Commit on end-edit or after a debounce, not per keystroke (spec §4).
    @discardableResult
    func setFormItemText(formID: String, itemID: String, _ text: String?) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.setText($0, itemID: itemID, text) }
    }

    /// Commit on end-edit or after a debounce, not per keystroke (spec §4).
    @discardableResult
    func setFormItemNote(formID: String, itemID: String, _ note: String?) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.setNote($0, itemID: itemID, note) }
    }

    /// Detaches a photo from the item. The job photo itself stays; delete it
    /// with `deleteJobPhoto`.
    @discardableResult
    func removeFormItemPhoto(formID: String, itemID: String, photoID: String) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.removePhoto($0, itemID: itemID, photoID: photoID) }
    }

    /// Adds an item (edit mode). Returns the form and the new item's id. A
    /// new id never reuses one a photo of this form still points at.
    @discardableResult
    func addFormItem(
        formID: String,
        kind: NativeJobForms.ItemKind,
        label: String,
        required: Bool = false,
        photoRequired: Bool = false,
        after afterItemID: String? = nil
    ) -> Result<(form: Canonical.Form, itemID: String), NativeJobForms.FormError> {
        guard let stored = form(id: formID) else { return .failure(.notFound) }
        let reserved = Set(
            (stored.jobId.map { jobPhotos(for: $0) } ?? [])
                .filter { $0.formId == formID }
                .compactMap(\.formItemId)
        )
        var newItemID = ""
        let result = mutateForm(id: formID) { current in
            let added = try NativeJobForms.addItem(
                current, kind: kind, label: label, required: required, photoRequired: photoRequired,
                after: afterItemID, reservedItemIDs: reserved
            )
            newItemID = added.itemID
            return added.form
        }
        return result.map { ($0, newItemID) }
    }

    @discardableResult
    func editFormItem(
        formID: String,
        itemID: String,
        label: String? = nil,
        required: Bool? = nil,
        photoRequired: Bool? = nil
    ) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) {
            try NativeJobForms.editItem($0, itemID: itemID, label: label, required: required, photoRequired: photoRequired)
        }
    }

    @discardableResult
    func deleteFormItem(formID: String, itemID: String) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.deleteItem($0, itemID: itemID) }
    }

    /// SwiftUI `onMove` semantics.
    @discardableResult
    func moveFormItems(formID: String, fromOffsets offsets: IndexSet, toOffset destination: Int) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: formID) { try NativeJobForms.moveItems($0, fromOffsets: offsets, toOffset: destination) }
    }

    @discardableResult
    func renameForm(id: String, title: String) -> Result<Canonical.Form, NativeJobForms.FormError> {
        mutateForm(id: id) { try NativeJobForms.rename($0, title: title) }
    }

    // MARK: - Lifecycle

    /// "Mark complete": refused with what is missing (spec §2). A form that is
    /// already complete is returned as it is.
    @discardableResult
    func completeForm(id: String, on date: Date = .now) -> FormCompletionOutcome {
        guard let stored = form(id: id) else { return .failed(.notFound) }
        guard stored.isInstance else { return .failed(.notAnInstance) }
        guard !stored.isCompleted else { return .completed(stored) }
        guard let jobID = stored.jobId, canonicalJobExists(id: jobID) else { return .failed(.jobNotFound) }
        do {
            let completed = try NativeJobForms.complete(stored, existingPhotoIDs: formJobPhotoIDs(stored), now: date)
            switch commitFormRecord(completed, mode: .replace) {
            case let .success(form): return .completed(form)
            case let .failure(error): return .failed(error)
            }
        } catch let NativeJobForms.FormError.incomplete(missing) {
            return .incomplete(missing)
        } catch {
            return .failed(Self.formError(error))
        }
    }

    /// "Reopen": clears `completedAt` so the form can be edited again.
    @discardableResult
    func reopenForm(id: String) -> Result<Canonical.Form, NativeJobForms.FormError> {
        guard let stored = form(id: id) else { return .failure(.notFound) }
        if let jobID = stored.jobId, stored.isInstance, !canonicalJobExists(id: jobID) {
            return .failure(.jobNotFound)
        }
        do {
            return commitFormRecord(try NativeJobForms.reopen(stored), mode: .replace)
        } catch {
            return .failure(Self.formError(error))
        }
    }

    /// Hides a custom template from the picker and the Settings list.
    /// Instances made from it are unaffected.
    @discardableResult
    func archiveFormTemplate(id: String, on date: Date = .now) -> Result<Canonical.Form, NativeJobForms.FormError> {
        guard let stored = form(id: id) else { return .failure(.notFound) }
        do {
            let archived = try NativeJobForms.archive(stored, now: date)
            guard archived != stored else { return .success(stored) }
            return commitFormRecord(archived, mode: .replace)
        } catch {
            return .failure(Self.formError(error))
        }
    }

    // `deleteForm(id:)` is in AppStore.swift: it sets the shared deletion undo.

    // MARK: - Unsaved text (review fix 2026-10-03)
    //
    // A form screen that closes with text it could not save (a refused
    // commit) hands it here instead of dropping it. The fill screen and the
    // items editor take it back when they next open the form, and the job's
    // form row says "Unsaved text" meanwhile. Memory only: cleared with the
    // snapshot at an account boundary (`applyEmptySnapshot`).

    /// Whether a form's screen closed with text it could not save.
    func hasHeldFormText(formID: String) -> Bool {
        heldFormText[formID]?.isEmpty == false
    }

    /// Holds the fill screen's unsaved answers and notes for `formID`,
    /// replacing what was held for them. Empty `drafts` releases them.
    func holdFormDrafts(
        _ drafts: [NativeJobFormsPresentation.DraftKey: String],
        refusals: [NativeJobFormsPresentation.DraftKey: NativeJobForms.FormError],
        formID: String
    ) {
        var held = heldFormText[formID] ?? .init()
        held.drafts = drafts
        held.refusals = refusals.filter { drafts[$0.key] != nil }
        setHeldFormText(held, formID: formID)
    }

    /// Takes back (and releases) the answers and notes held for `formID`.
    func takeHeldFormDrafts(formID: String) -> (
        drafts: [NativeJobFormsPresentation.DraftKey: String],
        refusals: [NativeJobFormsPresentation.DraftKey: NativeJobForms.FormError]
    )? {
        guard var held = heldFormText[formID], !held.drafts.isEmpty else { return nil }
        let taken = (held.drafts, held.refusals)
        held.drafts = [:]
        held.refusals = [:]
        setHeldFormText(held, formID: formID)
        return taken
    }

    /// Holds the items editor's unsaved title for `formID`; nil releases it.
    func holdFormTitle(_ title: String?, refusal: NativeJobForms.FormError?, formID: String) {
        var held = heldFormText[formID] ?? .init()
        held.title = title
        held.titleRefusal = title == nil ? nil : refusal
        setHeldFormText(held, formID: formID)
    }

    /// Takes back (and releases) the title held for `formID`.
    func takeHeldFormTitle(formID: String) -> (title: String, refusal: NativeJobForms.FormError?)? {
        guard var held = heldFormText[formID], let title = held.title else { return nil }
        let refusal = held.titleRefusal
        held.title = nil
        held.titleRefusal = nil
        setHeldFormText(held, formID: formID)
        return (title, refusal)
    }

    /// Publishes only a real change, so closing a screen with nothing held
    /// redraws nothing.
    private func setHeldFormText(_ held: NativeJobFormsPresentation.HeldText, formID: String) {
        let next = held.isEmpty ? nil : held
        guard heldFormText[formID] != next else { return }
        heldFormText[formID] = next
    }

    // MARK: - Private

    /// The ids of the photos of the form's job on this device.
    private func formJobPhotoIDs(_ form: Canonical.Form) -> Set<String> {
        guard let jobID = form.jobId else { return [] }
        return Set(jobPhotos(for: jobID).map(\.id))
    }

    private static func formError(_ error: Error) -> NativeJobForms.FormError {
        (error as? NativeJobForms.FormError) ?? .notSaved
    }
}
