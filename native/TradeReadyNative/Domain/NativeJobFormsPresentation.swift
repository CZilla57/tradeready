import Foundation

// MARK: - Phase 20: job forms screen state (pure)
//
// Spec: `docs/superpowers/specs/2026-10-02-job-forms-design.md` §4. The text,
// grouping and state rules the forms screens (`N/NativeJobFormsView.swift`,
// `N/NativeJobFormEditorView.swift`) show, kept out of SwiftUI so the host
// suite (`native/run-job-forms-tests.sh`) drives them. Foundation and the
// canonical models only, like `NativeJobForms`.

enum NativeJobFormsPresentation {
    // MARK: - Job detail rows

    /// One row of the job detail "Forms & checklists" section.
    struct RowSummary: Equatable, Identifiable {
        let formID: String
        let title: String
        /// "7/12": answered over answerable items.
        let progressLabel: String
        /// "Completed" or "In progress": the badge is text, never color alone.
        let statusLabel: String
        let isCompleted: Bool
        /// "Unsaved text" when the form's screen closed with text it could
        /// not save (held by the store until the form opens again), else nil.
        let unsavedLabel: String?
        /// VoiceOver reads the row as one element.
        let accessibilityLabel: String

        var id: String { formID }
    }

    static let unsavedTextLabel = "Unsaved text"

    static func rowSummary(_ form: Canonical.Form, hasUnsavedText: Bool = false) -> RowSummary {
        let progress = NativeJobForms.progress(form)
        let status = statusLabel(form)
        let unsaved = hasUnsavedText ? unsavedTextLabel : nil
        return RowSummary(
            formID: form.id,
            title: form.title,
            progressLabel: progress.label,
            statusLabel: status,
            isCompleted: form.isCompleted,
            unsavedLabel: unsaved,
            accessibilityLabel: "\(form.title), \(progressText(progress)), \(status.lowercased())"
                + (unsaved.map { ", \($0.lowercased())" } ?? "")
        )
    }

    static func statusLabel(_ form: Canonical.Form) -> String {
        form.isCompleted ? "Completed" : "In progress"
    }

    /// "7 of 12 answered" (the spoken and long form of "7/12").
    static func progressText(_ progress: NativeJobForms.Progress) -> String {
        "\(progress.answered) of \(progress.answerable) answered"
    }

    /// "Completed Oct 3, 2026", or "In progress". An unreadable stamp still
    /// says "Completed".
    static func statusText(_ form: Canonical.Form, calendar: Calendar = .current) -> String {
        guard form.isCompleted else { return "In progress" }
        guard let stamp = form.completedAt, let date = displayDate(isoTimestamp: stamp, calendar: calendar) else {
            return "Completed"
        }
        return "Completed \(date)"
    }

    /// A medium en-US date ("Oct 3, 2026") in the calendar's time zone, for
    /// an ISO-8601 stamp with or without fractional seconds.
    static func displayDate(isoTimestamp: String, calendar: Calendar = .current) -> String? {
        guard let date = parseTimestamp(isoTimestamp) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Answers and edits are open: an in-progress instance. A completed
    /// instance is read-only until it is reopened.
    static func isEditable(_ form: Canonical.Form) -> Bool {
        form.isInstance && !form.isCompleted
    }

    // MARK: - Fill screen groups

    /// Items under one section heading. `title` is nil for the items before
    /// the first heading.
    struct ItemGroup: Equatable, Identifiable {
        let id: String
        let title: String?
        let items: [Canonical.FormItem]
    }

    /// The fill screen's sections: each `section` item starts a group with
    /// its label as the title. Empty groups (a heading followed directly by
    /// another heading, or at the end) are left out.
    static func itemGroups(_ form: Canonical.Form) -> [ItemGroup] {
        var groups: [ItemGroup] = []
        var currentID = "start"
        var currentTitle: String?
        var currentItems: [Canonical.FormItem] = []
        func flush() {
            if !currentItems.isEmpty {
                groups.append(ItemGroup(id: currentID, title: currentTitle, items: currentItems))
            }
        }
        for item in form.items {
            if item.itemKind == .section {
                flush()
                currentID = item.id
                currentTitle = item.label
                currentItems = []
            } else {
                currentItems.append(item)
            }
        }
        flush()
        return groups
    }

    // MARK: - Item kinds

    static func kindName(_ kind: NativeJobForms.ItemKind) -> String {
        switch kind {
        case .section: "Section heading"
        case .check: "Checkbox"
        case .passFail: "Pass / Fail / N/A"
        case .text: "Text answer"
        }
    }

    /// The editor's kind name, including a kind this version does not know.
    static func kindName(rawKind: String) -> String {
        NativeJobForms.ItemKind(rawValue: rawKind).map(kindName) ?? "Unsupported item"
    }

    static func kindSymbol(rawKind: String) -> String {
        switch NativeJobForms.ItemKind(rawValue: rawKind) {
        case .section: "list.bullet"
        case .check: "checkmark.square"
        case .passFail: "plusminus.circle"
        case .text: "text.alignleft"
        case nil: "questionmark.square"
        }
    }

    /// "Required · Photo required", or nil for an item with neither flag.
    static func flagsText(_ item: Canonical.FormItem) -> String? {
        var parts: [String] = []
        if item.isRequired { parts.append("Required") }
        if item.isPhotoRequired { parts.append("Photo required") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Shown in place of the controls of an item this version cannot answer.
    static let unsupportedItemMessage = "Update TradeReady to answer this item."

    // MARK: - Text answers and notes

    enum TextSlot: String, CaseIterable, Hashable {
        case answer
        case note

        var limit: Int {
            switch self {
            case .answer: NativeJobForms.Limits.textMaxLength
            case .note: NativeJobForms.Limits.noteMaxLength
            }
        }
    }

    /// One text field being typed in: an item's answer or its note.
    struct DraftKey: Hashable {
        let itemID: String
        let field: TextSlot
    }

    /// Text fields commit after this pause in typing, and on end-edit
    /// (spec §4: never per keystroke).
    static let textCommitDebounceSeconds: Double = 1.5

    static func storedText(_ item: Canonical.FormItem, field: TextSlot) -> String {
        switch field {
        case .answer: item.text ?? ""
        case .note: item.note ?? ""
        }
    }

    /// The value to write, or nil when the draft matches what is stored (an
    /// absent answer equals an empty one).
    static func textToCommit(draft: String, stored: String?) -> String? {
        draft == (stored ?? "") ? nil : draft
    }

    /// Typing stops at the field's cap instead of failing on save.
    static func clamped(_ text: String, field: TextSlot) -> String {
        text.count > field.limit ? String(text.prefix(field.limit)) : text
    }

    // MARK: - Saving typed text (review fix 2026-10-03)
    //
    // A typed answer, note or title is cleared only once its write succeeds,
    // or when it already matches what is stored. A refused write keeps it on
    // screen, marked "Not saved", and the owner is told once per reason. Text
    // a closing screen still could not save is held by the store
    // (`AppStore.heldFormText`, memory only) and comes back, with a notice,
    // the next time the form or its editor opens.

    /// What committing one draft does, decided before any write.
    enum DraftCommitStep: Equatable {
        /// The draft matches what is stored: clear it, nothing to write.
        case clear
        /// Write this value. The draft is cleared only if the write succeeds.
        case write(String)
        /// The item (or the whole form) is gone: nothing can take this text.
        case itemGone
    }

    static func draftCommitStep(_ key: DraftKey, draft: String, form: Canonical.Form?) -> DraftCommitStep {
        guard let item = form?.items.first(where: { $0.id == key.itemID }) else { return .itemGone }
        guard let value = textToCommit(draft: draft, stored: storedText(item, field: key.field)) else { return .clear }
        return .write(value)
    }

    /// The drafts in form order (answer, then note), then any whose item is
    /// gone, so commits and notices are deterministic.
    static func commitOrder(drafts: [DraftKey: String], form: Canonical.Form?) -> [DraftKey] {
        var order: [DraftKey] = []
        var seen = Set<DraftKey>()
        for item in form?.items ?? [] {
            for field in TextSlot.allCases {
                let key = DraftKey(itemID: item.id, field: field)
                if drafts[key] != nil, seen.insert(key).inserted { order.append(key) }
            }
        }
        let rest = drafts.keys.filter { !seen.contains($0) }.sorted {
            $0.itemID == $1.itemID ? $0.field.rawValue < $1.field.rawValue : $0.itemID < $1.itemID
        }
        return order + rest
    }

    /// What a batch of draft commits left behind.
    struct DraftCommitOutcome: Equatable {
        /// Every draft not cleared: the text still unsaved.
        var drafts: [DraftKey: String]
        /// Why each unsaved draft's last write was refused.
        var refusals: [DraftKey: NativeJobForms.FormError]
        /// Drafts dropped because their item (or the form) is gone.
        var dropped: [DraftKey]
        /// What to tell the owner: the first refusal not already shown for
        /// that field (a new field, or a new reason), else a dropped draft's
        /// reason. Nil when there is nothing new to say.
        var newProblem: NativeJobForms.FormError?

        var isAllSaved: Bool { drafts.isEmpty }
    }

    /// Commits `drafts` (only `keys`, when given) through `write`, one store
    /// call per changed draft. A draft is cleared only when it matches what
    /// is stored or its write succeeds; a refused write keeps it with its
    /// reason. A draft whose item is gone is dropped and reported.
    static func commitDrafts(
        _ drafts: [DraftKey: String],
        refusals: [DraftKey: NativeJobForms.FormError] = [:],
        only keys: [DraftKey]? = nil,
        form: Canonical.Form?,
        write: (DraftKey, String) -> Result<Canonical.Form, NativeJobForms.FormError>
    ) -> DraftCommitOutcome {
        var remaining = drafts
        var reasons = refusals.filter { drafts[$0.key] != nil }
        var dropped: [DraftKey] = []
        var newProblem: NativeJobForms.FormError?
        for key in commitOrder(drafts: drafts, form: form) where keys?.contains(key) ?? true {
            guard let draft = drafts[key] else { continue }
            switch draftCommitStep(key, draft: draft, form: form) {
            case .clear:
                remaining[key] = nil
                reasons[key] = nil
            case .itemGone:
                remaining[key] = nil
                reasons[key] = nil
                dropped.append(key)
                newProblem = newProblem ?? (form == nil ? .notFound : .itemNotFound(key.itemID))
            case let .write(value):
                switch write(key, value) {
                case .success:
                    remaining[key] = nil
                    reasons[key] = nil
                case let .failure(error):
                    if reasons[key] != error { newProblem = newProblem ?? error }
                    reasons[key] = error
                }
            }
        }
        return DraftCommitOutcome(drafts: remaining, refusals: reasons, dropped: dropped, newProblem: newProblem)
    }

    /// The first refusal in form order (what a notice about unsaved text says).
    static func firstRefusal(
        _ refusals: [DraftKey: NativeJobForms.FormError],
        form: Canonical.Form?
    ) -> NativeJobForms.FormError? {
        commitOrder(drafts: refusals.mapValues { _ in "" }, form: form).lazy.compactMap { refusals[$0] }.first
    }

    static let unsavedTextTitle = "Text not saved"

    /// Under a field whose text is not saved yet.
    static func unsavedFieldText(_ error: NativeJobForms.FormError) -> String {
        "Not saved. \(message(for: error))"
    }

    /// Done with text still unsaved: the alert offers Keep editing or Close.
    static func unsavedOnCloseMessage(count: Int, reason: NativeJobForms.FormError?) -> String {
        let what = count == 1 ? "1 answer or note isn't saved." : "\(count) answers or notes aren't saved."
        let why = reason.map { " \(message(for: $0))" } ?? ""
        return what + why + " Close keeps the text and puts it back when you next open this form, as long as TradeReady stays open."
    }

    /// Text a form screen closed without saving, held by the store (memory
    /// only) by form id until the form, or its editor, opens again.
    struct HeldText: Equatable {
        /// The fill screen's answers and notes, and why each was refused.
        var drafts: [DraftKey: String] = [:]
        var refusals: [DraftKey: NativeJobForms.FormError] = [:]
        /// The editor's title, and why it was refused.
        var title: String?
        var titleRefusal: NativeJobForms.FormError?

        var isEmpty: Bool { drafts.isEmpty && title == nil }
    }

    /// What the fill screen puts back from held text: only drafts whose item
    /// is still on the form and that still differ from what is stored, with
    /// their reasons and the notice to show (nil when nothing comes back).
    struct DraftRestoration: Equatable {
        var drafts: [DraftKey: String]
        var refusals: [DraftKey: NativeJobForms.FormError]
        var message: String?
    }

    static func draftRestoration(
        drafts held: [DraftKey: String],
        refusals: [DraftKey: NativeJobForms.FormError],
        form: Canonical.Form?
    ) -> DraftRestoration {
        let restored = held.filter {
            if case .write = draftCommitStep($0.key, draft: $0.value, form: form) { return true }
            return false
        }
        let reasons = refusals.filter { restored[$0.key] != nil }
        guard !restored.isEmpty else { return DraftRestoration(drafts: [:], refusals: [:], message: nil) }
        let what = restored.count == 1
            ? "1 answer or note wasn't saved when this form was closed. It's back in its field"
            : "\(restored.count) answers or notes weren't saved when this form was closed. They're back in their fields"
        let why = firstRefusal(reasons, form: form).map { " \(message(for: $0))" } ?? ""
        return DraftRestoration(drafts: restored, refusals: reasons, message: "\(what), marked Not saved.\(why)")
    }

    /// The editor's title, decided before any write: cleared when it matches
    /// the stored title (trimmed) or the form is gone.
    static func titleCommitStep(draft: String, stored: String?) -> DraftCommitStep {
        guard let stored else { return .itemGone }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) == stored ? .clear : .write(draft)
    }

    /// What one title commit left behind.
    struct TitleCommitOutcome: Equatable {
        /// The title still unsaved, or nil.
        var draft: String?
        var refusal: NativeJobForms.FormError?
        /// A refusal not already shown, for the alert.
        var newProblem: NativeJobForms.FormError?
    }

    static func commitTitle(
        _ draft: String?,
        refusal: NativeJobForms.FormError?,
        stored: String?,
        write: (String) -> Result<Canonical.Form, NativeJobForms.FormError>
    ) -> TitleCommitOutcome {
        guard let draft else { return TitleCommitOutcome(draft: nil, refusal: nil, newProblem: nil) }
        switch titleCommitStep(draft: draft, stored: stored) {
        case .clear, .itemGone:
            return TitleCommitOutcome(draft: nil, refusal: nil, newProblem: nil)
        case let .write(value):
            switch write(value) {
            case .success:
                return TitleCommitOutcome(draft: nil, refusal: nil, newProblem: nil)
            case let .failure(error):
                return TitleCommitOutcome(draft: draft, refusal: error, newProblem: refusal == error ? nil : error)
            }
        }
    }

    /// The title a closing editor holds: a blank title can never be saved
    /// and carries no typed text, so the stored title simply stays.
    static func titleToHold(_ draft: String?) -> String? {
        guard let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return draft
    }

    /// The held title the editor puts back (nil when the form is gone or the
    /// stored title already matches it).
    static func restoredTitle(_ held: String?, stored: String?) -> String? {
        guard let held, case .write = titleCommitStep(draft: held, stored: stored) else { return nil }
        return held
    }

    static func restoredTitleMessage(reason: NativeJobForms.FormError?) -> String {
        "Your new title wasn't saved when you left this screen. It's back in the title field."
            + (reason.map { " \(message(for: $0))" } ?? "")
    }

    /// Whether the note field shows: an item with a note, or one the owner
    /// opened a note on.
    static func showsNote(_ item: Canonical.FormItem, opened: Bool) -> Bool {
        opened || !(item.note ?? "").isEmpty
    }

    // MARK: - Photos

    /// An item's photo ids against the job's photos on this device.
    ///
    /// Review fix (2026-10-03): an id whose photo record is not on this
    /// device may be a deleted photo or one that has not synced here yet
    /// (photos and forms pull as separate tables, so a form can arrive
    /// first). This device keeps no record of deletions and cannot tell the
    /// two apart, so no such link is ever detached automatically: it shows
    /// as a "Not on this device" tile the owner can remove, and it counts
    /// toward the item's 10, exactly as the domain cap does.
    struct PhotoSlots: Equatable {
        /// Ids that resolve to a job photo here, in stored order.
        let resolvedIDs: [String]
        /// Ids whose photo record is not on this device, in stored order.
        let unresolvedIDs: [String]
        /// How many more photos the item can take: 10 minus every stored id,
        /// so it matches the domain cap.
        let remaining: Int

        var isFull: Bool { remaining == 0 }
        var storedCount: Int { resolvedIDs.count + unresolvedIDs.count }
    }

    static func photoSlots(_ item: Canonical.FormItem, existingPhotoIDs: Set<String>) -> PhotoSlots {
        let resolved = NativeJobForms.resolvedPhotoIDs(item, existingPhotoIDs: existingPhotoIDs)
        let resolvedSet = Set(resolved)
        let unresolved = (item.photoIds ?? []).filter { !resolvedSet.contains($0) }
        return PhotoSlots(
            resolvedIDs: resolved,
            unresolvedIDs: unresolved,
            remaining: max(0, NativeJobForms.Limits.photosPerItemMaxCount - resolved.count - unresolved.count)
        )
    }

    /// "2 of 10 photos": every tile the item shows, unresolved ones included.
    static func photoCountLabel(_ slots: PhotoSlots) -> String {
        "\(slots.storedCount) of \(NativeJobForms.Limits.photosPerItemMaxCount) photos"
    }

    /// VoiceOver label of one thumbnail: "Photo 2 of 3, Data plate photo".
    static func photoAccessibilityLabel(index: Int, count: Int, itemLabel: String, isAvailable: Bool) -> String {
        let base = "Photo \(index + 1) of \(count), \(itemLabel)"
        return isAvailable ? base : base + ", waiting for download"
    }

    /// VoiceOver label of a linked photo whose record is not on this device.
    static func unresolvedPhotoAccessibilityLabel(index: Int, count: Int, itemLabel: String) -> String {
        "Photo \(index + 1) of \(count), \(itemLabel), not on this device"
    }

    static let unresolvedPhotoTileText = "Not on this device"

    /// The photo actions' explanation.
    static func photoActionMessage(isResolved: Bool, editable: Bool) -> String {
        guard isResolved else {
            let why = "This photo isn't on this device. It may still be syncing from another device, or it was deleted."
            return editable ? why + " Removing it from this item frees its place." : why
        }
        return editable ? "Removing it from this item keeps it in the job's Photos section." : "This form is complete and read-only."
    }

    // MARK: - Completion

    static let incompleteTitle = "Can't mark complete yet"

    /// Item id → what it still needs ("Needs a photo"), for the rows.
    static func missingByItem(_ missing: [NativeJobForms.MissingItem]) -> [String: String] {
        Dictionary(missing.map { ($0.itemID, $0.message) }, uniquingKeysWith: { first, _ in first })
    }

    /// The refusal alert: every missing item, in form order, with its reasons
    /// ("• Panel photo: Needs a photo"), capped at `limit` lines.
    static func incompleteMessage(_ missing: [NativeJobForms.MissingItem], limit: Int = 6) -> String {
        guard !missing.isEmpty else { return "Every required item is answered." }
        let count = missing.count
        let head = count == 1 ? "1 item still needs attention:" : "\(count) items still need attention:"
        let lines = missing.prefix(max(1, limit)).map { "• \($0.label): \($0.message)" }
        var message = ([head] + lines).joined(separator: "\n")
        let hidden = count - lines.count
        if hidden > 0 { message += "\n… and \(hidden) more, marked in the list." }
        return message
    }

    /// Shown above a completed form's items.
    static let readOnlyNotice = "This form is complete and read-only. Reopen it to make changes."

    // MARK: - Errors

    /// The text alert for a refused or failed forms operation.
    static func message(for error: NativeJobForms.FormError) -> String {
        switch error {
        case .notFound: "This form is no longer on this device."
        case .jobNotFound: "This job is no longer on this device."
        case .notAnInstance, .notATemplate, .invalidKind:
            "This form can't be changed in this version of TradeReady."
        case .readOnlyCompleted: "This form is complete. Reopen it to make changes."
        case .notCompleted: "This form is already open for changes."
        case .unknownTemplate: "That template is no longer available."
        case .templateArchived: "That template was archived, so it can't be added."
        case .invalidTitle: "Enter a title of up to \(NativeJobForms.Limits.titleMaxLength) characters."
        case .invalidItemCount:
            "A form needs at least 1 and at most \(NativeJobForms.Limits.itemsMaxCount) items."
        case .invalidLabel: "Enter a label of up to \(NativeJobForms.Limits.labelMaxLength) characters."
        case .textTooLong: "An answer can be up to 2,000 characters."
        case .noteTooLong: "A note can be up to 1,000 characters."
        case .tooManyPhotos: "An item can hold up to \(NativeJobForms.Limits.photosPerItemMaxCount) photos."
        case .itemNotFound: "That item is no longer on this form."
        case .itemNotAnswerable, .wrongItemKind: "That item can't take this answer."
        case .missingJob: "This form isn't attached to a job."
        case .notSaved: "This device couldn't save the change. Nothing was changed."
        case let .incomplete(missing): incompleteMessage(missing)
        case .duplicateItemID, .invalidItemID, .invalidFormID, .invalidPhotoID, .invalidOrder, .duplicateFormID:
            "The form couldn't be updated. Nothing was changed."
        }
    }

    // MARK: - Add or edit an item

    struct ItemDraft: Equatable {
        var kind: NativeJobForms.ItemKind
        var label: String
        var required: Bool
        var photoRequired: Bool

        init(kind: NativeJobForms.ItemKind = .check, label: String = "", required: Bool = false, photoRequired: Bool = false) {
            self.kind = kind
            self.label = label
            self.required = required
            self.photoRequired = photoRequired
        }

        var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// Flags only apply to an answerable kind.
        var effectiveRequired: Bool { kind.isAnswerable && required }
        var effectivePhotoRequired: Bool { kind.isAnswerable && photoRequired }

        /// Why Save is off, or nil when the draft can be saved.
        var validationMessage: String? {
            if trimmedLabel.isEmpty { return "Enter a label." }
            if trimmedLabel.count > NativeJobForms.Limits.labelMaxLength {
                return "A label can be up to \(NativeJobForms.Limits.labelMaxLength) characters."
            }
            return nil
        }

        var isValid: Bool { validationMessage == nil }
    }

    /// The edit sheet's starting draft for an existing item (nil for a kind
    /// this version does not know: such an item can be moved or deleted, not
    /// edited).
    static func itemDraft(for item: Canonical.FormItem) -> ItemDraft? {
        guard let kind = item.itemKind else { return nil }
        return ItemDraft(kind: kind, label: item.label, required: item.isRequired, photoRequired: item.isPhotoRequired)
    }

    // MARK: - Editor caps and templates

    static func itemCountLabel(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// "12 of 100 items" under the editor's list.
    static func itemCapText(_ form: Canonical.Form) -> String {
        "\(form.items.count) of \(NativeJobForms.Limits.itemsMaxCount) items"
    }

    static func canAddItem(_ form: Canonical.Form) -> Bool {
        form.items.count < NativeJobForms.Limits.itemsMaxCount && !(form.isInstance && form.isCompleted)
    }

    /// A form keeps at least one item.
    static func canDeleteItem(_ form: Canonical.Form) -> Bool {
        form.items.count > 1 && !(form.isInstance && form.isCompleted)
    }

    /// The picker row's spoken label: "Pre-job walkthrough, 10 items".
    static func pickerEntryAccessibilityLabel(_ entry: NativeJobForms.PickerEntry) -> String {
        "\(entry.title), \(itemCountLabel(entry.itemCount))"
    }

    /// The "Save as template" title field starts with the form's title.
    static func defaultTemplateTitle(_ form: Canonical.Form) -> String {
        String(form.title.prefix(NativeJobForms.Limits.titleMaxLength))
    }

    static func templateSavedMessage(_ template: Canonical.Form) -> String {
        "\"\(template.title)\" is in your templates. Add it to any job from Add form, and manage it in Settings › Forms & checklists."
    }
}
