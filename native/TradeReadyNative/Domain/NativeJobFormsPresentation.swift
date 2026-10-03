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
        /// VoiceOver reads the row as one element.
        let accessibilityLabel: String

        var id: String { formID }
    }

    static func rowSummary(_ form: Canonical.Form) -> RowSummary {
        let progress = NativeJobForms.progress(form)
        let status = statusLabel(form)
        return RowSummary(
            formID: form.id,
            title: form.title,
            progressLabel: progress.label,
            statusLabel: status,
            isCompleted: form.isCompleted,
            accessibilityLabel: "\(form.title), \(progressText(progress)), \(status.lowercased())"
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

    /// The drafts that differ from the stored form, in form order. A draft for
    /// an item that is gone is dropped.
    static func pendingCommits(drafts: [DraftKey: String], form: Canonical.Form) -> [(key: DraftKey, value: String)] {
        var result: [(key: DraftKey, value: String)] = []
        for item in form.items {
            for field in TextSlot.allCases {
                let key = DraftKey(itemID: item.id, field: field)
                guard let draft = drafts[key] else { continue }
                let stored: String? = field == .answer ? item.text : item.note
                if let value = textToCommit(draft: draft, stored: stored) {
                    result.append((key, value))
                }
            }
        }
        return result
    }

    /// Whether the note field shows: an item with a note, or one the owner
    /// opened a note on.
    static func showsNote(_ item: Canonical.FormItem, opened: Bool) -> Bool {
        opened || !(item.note ?? "").isEmpty
    }

    // MARK: - Photos

    /// An item's photo ids against the job's photos on this device.
    struct PhotoSlots: Equatable {
        /// Ids that still resolve, in stored order (what the screen shows).
        let resolvedIDs: [String]
        /// Ids of photos deleted from the job: kept in the row, never shown.
        let danglingIDs: [String]
        /// How many more photos the item shows room for (10 minus resolved).
        let remaining: Int

        var isFull: Bool { remaining == 0 }
        var storedCount: Int { resolvedIDs.count + danglingIDs.count }
    }

    static func photoSlots(_ item: Canonical.FormItem, existingPhotoIDs: Set<String>) -> PhotoSlots {
        let resolved = NativeJobForms.resolvedPhotoIDs(item, existingPhotoIDs: existingPhotoIDs)
        let resolvedSet = Set(resolved)
        let dangling = (item.photoIds ?? []).filter { !resolvedSet.contains($0) }
        return PhotoSlots(
            resolvedIDs: resolved,
            danglingIDs: dangling,
            remaining: max(0, NativeJobForms.Limits.photosPerItemMaxCount - resolved.count)
        )
    }

    /// The domain caps the stored ids, deleted ones included. Before `adding`
    /// new photos, these dangling ids are detached so the shown room is real.
    static func danglingIDsToDetach(_ slots: PhotoSlots, adding count: Int) -> [String] {
        let overflow = slots.storedCount + max(0, count) - NativeJobForms.Limits.photosPerItemMaxCount
        guard overflow > 0 else { return [] }
        return Array(slots.danglingIDs.prefix(overflow))
    }

    /// "2 of 10 photos".
    static func photoCountLabel(_ slots: PhotoSlots) -> String {
        "\(slots.resolvedIDs.count) of \(NativeJobForms.Limits.photosPerItemMaxCount) photos"
    }

    /// VoiceOver label of one thumbnail: "Photo 2 of 3, Data plate photo".
    static func photoAccessibilityLabel(index: Int, count: Int, itemLabel: String, isAvailable: Bool) -> String {
        let base = "Photo \(index + 1) of \(count), \(itemLabel)"
        return isAvailable ? base : base + ", waiting for download"
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
