import Foundation

// MARK: - Phase 20: custom job / inspection forms and checklists
//
// Spec: `docs/superpowers/specs/2026-10-02-job-forms-design.md`. Pure rules over
// `Canonical.Form` rows, the synced `forms` collection that holds both the
// owner's custom templates and filled job checklists (told apart by `kind`).
// Nothing here touches the snapshot, the queue or the disk: `AppStore` commits
// each change as one `forms` upsert (`NativeJobFormsStore.swift`).
//
// Dependencies are deliberately only Foundation and the canonical models, so the
// module runs standalone in `native/run-job-forms-tests.sh`.
//
// Rules in one place:
// - A completed instance is read-only until it is reopened: every answer and
//   edit operation refuses it with `.readOnlyCompleted`.
// - Completion (spec §2): every required item is answered (`check` ticked,
//   `passFail` any result, `text` non-blank) and every photo-required item has
//   at least one photo id that still resolves to an existing photo of the job.
// - A `kind` (form or item) or `result` this version does not know is kept
//   verbatim: such an item is never answerable, never blocks completion and is
//   never counted in progress.

enum NativeJobForms {
    // MARK: Kinds

    enum FormKind: String, CaseIterable, Equatable {
        case template
        case instance
    }

    enum ItemKind: String, CaseIterable, Equatable {
        case section
        case check
        case passFail
        case text

        /// Sections are headings; every other kind takes an answer, a note and
        /// photos.
        var isAnswerable: Bool { self != .section }
    }

    enum PassFailResult: String, CaseIterable, Equatable {
        case pass
        case fail
        case na

        var displayName: String {
            switch self {
            case .pass: "Pass"
            case .fail: "Fail"
            case .na: "N/A"
            }
        }
    }

    // MARK: Limits (spec §2)

    enum Limits {
        static let titleMaxLength = 80
        static let itemsMaxCount = 100
        static let labelMaxLength = 200
        static let textMaxLength = 2000
        static let noteMaxLength = 1000
        static let photosPerItemMaxCount = 10
    }

    // MARK: Errors

    /// Why an operation was refused. Every pure operation and every `AppStore`
    /// forms method reports one of these; nothing is changed on refusal.
    enum FormError: Error, Equatable {
        /// No form with that id on this device.
        case notFound
        /// The job the instance belongs to is not on this device.
        case jobNotFound
        /// An answer or completion operation on a template (or unknown kind).
        case notAnInstance
        /// A template-only operation on an instance (or unknown kind).
        case notATemplate
        /// A completed instance: reopen it first.
        case readOnlyCompleted
        /// Reopen on an instance that is still in progress.
        case notCompleted
        /// The built-in key or custom template id does not exist.
        case unknownTemplate(String)
        /// The custom template was archived.
        case templateArchived
        /// The title is blank or longer than 80 characters.
        case invalidTitle
        /// A form needs 1 to 100 items.
        case invalidItemCount
        /// An item label is blank or longer than 200 characters.
        case invalidLabel
        /// A text answer is longer than 2,000 characters.
        case textTooLong
        /// A note is longer than 1,000 characters.
        case noteTooLong
        /// An item already holds 10 photos.
        case tooManyPhotos
        case itemNotFound(String)
        /// The item is a section (or of a kind this version does not know).
        case itemNotAnswerable(String)
        /// The answer does not fit the item's kind (e.g. a result on a check).
        case wrongItemKind(String)
        case duplicateItemID(String)
        case invalidItemID
        /// A form id that is not `fm<ms>_<base36>`.
        case invalidFormID
        /// An empty photo id.
        case invalidPhotoID
        /// A reorder that is not a permutation of the form's item ids.
        case invalidOrder
        /// The form's `kind` is neither `template` nor `instance`.
        case invalidKind
        /// An instance without a job id.
        case missingJob
        /// A new form whose id is already stored.
        case duplicateFormID
        /// This device could not save (read-only local data or a disk
        /// failure); `AppStore.migrationMessage` says why. Nothing changed.
        case notSaved
        /// Completion refused: what is still missing, in form order.
        case incomplete([MissingItem])
    }

    // MARK: Completion reasons

    enum MissingReason: String, CaseIterable, Equatable {
        /// A required check is not ticked.
        case notChecked
        /// A required pass/fail item has no Pass, Fail or N/A.
        case noResult
        /// A required text item is blank.
        case noText
        /// A photo-required item has no photo.
        case noPhoto
        /// A photo-required item's photos are all missing from this device
        /// (deleted, or not synced here yet: this device cannot tell which).
        case photoUnavailable

        var message: String {
            switch self {
            case .notChecked: "Not checked"
            case .noResult: "Needs Pass, Fail or N/A"
            case .noText: "Needs an answer"
            case .noPhoto: "Needs a photo"
            case .photoUnavailable: "Its photo isn't on this device. Add another"
            }
        }
    }

    struct MissingItem: Equatable, Identifiable {
        let itemID: String
        let label: String
        /// One or two reasons (an unanswered required item can also miss its
        /// photo), in the order of `MissingReason.allCases`.
        let reasons: [MissingReason]

        var id: String { itemID }
        var message: String { reasons.map(\.message).joined(separator: " · ") }
    }

    /// Answered over answerable items, e.g. "7/12".
    struct Progress: Equatable {
        let answered: Int
        let answerable: Int

        var label: String { "\(answered)/\(answerable)" }
        var fraction: Double { answerable == 0 ? 0 : Double(answered) / Double(answerable) }
    }

    // MARK: Template references

    /// What an instance was made from: a built-in (never stored) or a custom
    /// template row. Stored on the instance as `templateId`.
    enum TemplateRef: Equatable, Hashable {
        case builtin(String)
        case custom(String)

        static let builtinPrefix = "builtin:"

        init?(templateId: String) {
            if templateId.hasPrefix(Self.builtinPrefix) {
                let key = String(templateId.dropFirst(Self.builtinPrefix.count))
                guard !key.isEmpty else { return nil }
                self = .builtin(key)
            } else {
                guard !templateId.isEmpty else { return nil }
                self = .custom(templateId)
            }
        }

        var templateId: String {
            switch self {
            case let .builtin(key): Self.builtinPrefix + key
            case let .custom(id): id
            }
        }
    }

    // MARK: - Built-in library (spec §3)

    struct BuiltinItem: Equatable {
        let kind: ItemKind
        let label: String
        let required: Bool
        let photoRequired: Bool

        static func section(_ label: String) -> BuiltinItem {
            .init(kind: .section, label: label, required: false, photoRequired: false)
        }
        static func check(_ label: String, required: Bool = false, photo: Bool = false) -> BuiltinItem {
            .init(kind: .check, label: label, required: required, photoRequired: photo)
        }
        static func passFail(_ label: String, required: Bool = false, photo: Bool = false) -> BuiltinItem {
            .init(kind: .passFail, label: label, required: required, photoRequired: photo)
        }
        static func text(_ label: String, required: Bool = false) -> BuiltinItem {
            .init(kind: .text, label: label, required: required, photoRequired: false)
        }
    }

    struct BuiltinTemplate: Equatable, Identifiable {
        let key: String
        let title: String
        /// Normalized trade keys; `general` is the General group.
        let trades: [String]
        let items: [BuiltinItem]

        var id: String { key }
        var templateRef: TemplateRef { .builtin(key) }
    }

    static let generalTradeKey = "general"

    /// Generic good practice only: no code citations and no compliance claims
    /// (spec §8). Never stored as rows: instantiating one stamps
    /// `templateId: "builtin:<key>"`.
    static let builtinTemplates: [BuiltinTemplate] = [
        BuiltinTemplate(
            key: "pre-job-walkthrough", title: "Pre-job walkthrough", trades: [generalTradeKey],
            items: [
                .section("Arrival"),
                .check("Confirmed the scope of work with the customer", required: true),
                .check("Confirmed access, parking and working hours"),
                .text("Customer requests or concerns"),
                .section("Existing conditions"),
                .passFail("Work area is clear and accessible", required: true),
                .check("Photos of existing conditions before starting", required: true, photo: true),
                .text("Existing damage or defects noted"),
                .check("Protected floors and furnishings near the work area"),
                .check("Located the shut-offs this job may need"),
            ]
        ),
        BuiltinTemplate(
            key: "job-completion", title: "Job completion & cleanup", trades: [generalTradeKey],
            items: [
                .section("Work"),
                .passFail("Work completed as agreed", required: true),
                .check("Tested and confirmed everything works", required: true),
                .check("Photos of the finished work", required: true, photo: true),
                .section("Cleanup"),
                .check("Removed debris and packaging", required: true),
                .check("Cleaned the work area"),
                .check("Returned furniture and belongings to their place"),
                .section("Handover"),
                .check("Walked the customer through the finished work", required: true),
                .text("Care or maintenance instructions given"),
                .text("Follow-up needed"),
            ]
        ),
        BuiltinTemplate(
            key: "site-safety", title: "Site safety checklist", trades: [generalTradeKey],
            items: [
                .section("Hazards"),
                .passFail("Walkways and exits are clear", required: true),
                .passFail("Ladders and tools are in good condition", required: true),
                .passFail("Extension cords and leads are undamaged"),
                .check("Work area kept apart from customers, children and pets"),
                .section("Protection"),
                .check("Protective equipment for the task is on hand", required: true),
                .check("First-aid kit on site"),
                .check("Know the nearest exit and shut-offs"),
                .text("Hazards found and how they were handled"),
            ]
        ),
        BuiltinTemplate(
            key: "hvac-maintenance", title: "HVAC maintenance inspection", trades: ["hvac"],
            items: [
                .section("Equipment"),
                .check("Data plate photo", required: true, photo: true),
                .text("Model and serial number"),
                .section("Airflow"),
                .passFail("Air filter condition", required: true),
                .check("Replaced or cleaned the air filter"),
                .passFail("Blower and fan run smoothly and quietly", required: true),
                .section("Heating and cooling"),
                .passFail("Thermostat responds and cycles the system", required: true),
                .passFail("Condensate drain flows freely", required: true),
                .passFail("Outdoor unit clear of debris and plants"),
                .passFail("Wiring connections tight with no signs of overheating"),
                .text("Supply and return air temperatures"),
                .text("Recommendations for the customer"),
            ]
        ),
        BuiltinTemplate(
            key: "electrical-safety", title: "Electrical safety inspection", trades: ["electrical"],
            items: [
                .section("Panel"),
                .check("Panel photo with the cover off", required: true, photo: true),
                .passFail("Breakers and fuses are labelled", required: true),
                .passFail("No signs of overheating, scorching or corrosion", required: true),
                .passFail("Panel cover and blanks in place"),
                .section("Devices"),
                .passFail("Outlets tested for power and polarity", required: true),
                .passFail("Ground-fault protected outlets trip and reset"),
                .passFail("Switches and fixtures work normally"),
                .passFail("Smoke and CO alarms present and sounding"),
                .section("Findings"),
                .text("Issues found"),
                .text("Recommendations for the customer"),
            ]
        ),
        BuiltinTemplate(
            key: "plumbing-water-heater", title: "Plumbing / water heater inspection", trades: ["plumbing"],
            items: [
                .section("Water heater"),
                .check("Water heater data plate photo", required: true, photo: true),
                .text("Age, capacity and fuel type"),
                .passFail("No leaks or corrosion at the tank and fittings", required: true),
                .passFail("Relief valve and its discharge pipe in place", required: true),
                .passFail("Venting intact and secure (fuel-burning units)"),
                .text("Hot water temperature at the nearest fixture"),
                .section("Supply and drains"),
                .passFail("Main shut-off located and operates", required: true),
                .passFail("No visible leaks under sinks or at fixtures", required: true),
                .passFail("Drains flow freely"),
                .text("Water pressure reading"),
                .text("Recommendations for the customer"),
            ]
        ),
    ]

    static func builtinTemplate(key: String) -> BuiltinTemplate? {
        builtinTemplates.first { $0.key == key }
    }

    // MARK: - Trade keys

    /// Settings' trade is synced in mixed spellings: onboarding writes the
    /// trade id (`hvac`, `carpenter`), Settings › Business profile writes the
    /// label ("HVAC", "Carpentry"). Every spelling maps to the onboarding id
    /// (`NativeTypedAccountState.Trade`); a blank trade is nil and an unknown
    /// one is kept lowercased.
    static func normalizedTradeKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        return tradeAliases[lowered] ?? lowered
    }

    private static let tradeAliases: [String: String] = [
        "carpentry": "carpenter",
        "bricklaying": "bricklayer",
        "plastering": "plasterer",
        "heating & cooling": "hvac",
        "heating and cooling": "hvac",
    ]

    static func tradeDisplayName(_ key: String) -> String {
        switch key {
        case "hvac": "HVAC"
        case "carpenter": "Carpentry"
        case "bricklayer": "Bricklaying"
        case "plasterer": "Plastering"
        case generalTradeKey: "General"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    // MARK: - Picker

    enum PickerGroup: Equatable {
        /// The owner's own non-archived templates.
        case custom
        /// Built-ins tagged with the owner's (normalized) trade.
        case trade(String)
        case general
        /// Every other built-in; shown only with "All templates".
        case otherTrades
    }

    struct PickerEntry: Equatable, Identifiable {
        let ref: TemplateRef
        let title: String
        let itemCount: Int

        var id: String { ref.templateId }
    }

    struct PickerSection: Equatable, Identifiable {
        let group: PickerGroup
        let title: String
        let entries: [PickerEntry]

        var id: String {
            switch group {
            case .custom: "custom"
            case let .trade(key): "trade:\(key)"
            case .general: "general"
            case .otherTrades: "other"
            }
        }
    }

    /// The "Add form" picker: the owner's custom templates, then the built-ins
    /// for the owner's trade, then General. `showAll` (the "All templates"
    /// toggle) appends every remaining built-in. Empty sections are omitted.
    static func pickerSections(
        ownerTrade: String?,
        customTemplates: [Canonical.Form],
        showAll: Bool
    ) -> [PickerSection] {
        var sections: [PickerSection] = []
        let custom = activeTemplates(in: customTemplates).map {
            PickerEntry(ref: .custom($0.id), title: $0.title, itemCount: $0.items.count)
        }
        if !custom.isEmpty {
            sections.append(.init(group: .custom, title: "Your templates", entries: custom))
        }
        func entry(_ template: BuiltinTemplate) -> PickerEntry {
            .init(ref: template.templateRef, title: template.title, itemCount: template.items.count)
        }
        var shown = Set<String>()
        if let trade = normalizedTradeKey(ownerTrade), trade != generalTradeKey {
            let matches = builtinTemplates.filter { $0.trades.contains(trade) }
            if !matches.isEmpty {
                sections.append(.init(group: .trade(trade), title: tradeDisplayName(trade), entries: matches.map(entry)))
                shown.formUnion(matches.map(\.key))
            }
        }
        let general = builtinTemplates.filter { $0.trades.contains(generalTradeKey) && !shown.contains($0.key) }
        if !general.isEmpty {
            sections.append(.init(group: .general, title: "General", entries: general.map(entry)))
            shown.formUnion(general.map(\.key))
        }
        if showAll {
            let others = builtinTemplates.filter { !shown.contains($0.key) }
            if !others.isEmpty {
                sections.append(.init(group: .otherTrades, title: "Other trades", entries: others.map(entry)))
            }
        }
        return sections
    }

    // MARK: - Ids and timestamps

    /// `fm<ms>_<base36 random>`. The `forms` primary key is global across
    /// accounts (spec §0), so the id is never derived from content.
    static func makeFormID(now: Date = Date(), randomValue: UInt64? = nil) -> String {
        let millis = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
        let random = randomValue ?? UInt64.random(in: 0 ... UInt64.max)
        return "fm\(millis)_\(String(random, radix: 36, uppercase: false))"
    }

    /// A fresh id that is not in `existingIDs` (bounded retries with fresh
    /// randomness; the injected value is only a first attempt).
    static func makeUniqueFormID(now: Date = Date(), existingIDs: Set<String>, randomValue: UInt64? = nil) -> String {
        var id = makeFormID(now: now, randomValue: randomValue)
        var attempts = 0
        while existingIDs.contains(id), attempts < 16 {
            attempts += 1
            id = makeFormID(now: now)
        }
        return id
    }

    static func isValidFormID(_ id: String) -> Bool {
        guard id.hasPrefix("fm") else { return false }
        let parts = id.dropFirst(2).split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[0].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[1].allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."z").contains($0)) }
    }

    static func itemID(_ number: Int) -> String { "fi_\(number)" }

    /// The `n` of `fi_<n>`, or nil for any other id.
    static func itemNumber(_ id: String) -> Int? {
        guard id.hasPrefix("fi_"), let number = Int(id.dropFirst(3)), number > 0,
              id == itemID(number)
        else { return nil }
        return number
    }

    /// The next `fi_<n>` after every id in `existing` and `reserved` (ids a
    /// photo still points at through `formItemId`), so a deleted item's id
    /// is not handed to a new item while its photos remain.
    static func nextItemID(existing: [String], reserved: Set<String> = []) -> String {
        let highest = (existing + Array(reserved)).compactMap(itemNumber).max() ?? 0
        return itemID(highest + 1)
    }

    /// ISO-8601 UTC with milliseconds, the stamp every JS client writes.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    // MARK: - Lookups

    /// The job's form instances, oldest first.
    static func instances(forJob jobID: String, in forms: [Canonical.Form]) -> [Canonical.Form] {
        forms
            .filter { $0.isInstance && $0.jobId == jobID }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    /// Non-archived custom templates, by title.
    static func activeTemplates(in forms: [Canonical.Form]) -> [Canonical.Form] {
        forms
            .filter { $0.isTemplate && !$0.isArchived }
            .sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// The ids of the job's photos on this device.
    static func photoIDs(forJob jobID: String, in photos: [Canonical.JobPhoto]) -> Set<String> {
        Set(photos.filter { $0.jobId == jobID }.map(\.id))
    }

    /// The item's photo ids that still resolve, in stored order. Ids of
    /// deleted photos are kept in the row but never shown or counted.
    static func resolvedPhotoIDs(_ item: Canonical.FormItem, existingPhotoIDs: Set<String>) -> [String] {
        (item.photoIds ?? []).filter { existingPhotoIDs.contains($0) }
    }

    // MARK: - Instantiate

    /// A new in-progress instance for `jobID` from a built-in or a custom
    /// template. Items are numbered `fi_1…fi_n` and carry no responses.
    static func instantiate(
        _ ref: TemplateRef,
        customTemplates: [Canonical.Form],
        jobID: String,
        formID: String,
        now: Date
    ) throws -> Canonical.Form {
        let trimmedJob = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJob.isEmpty else { throw FormError.missingJob }
        guard isValidFormID(formID) else { throw FormError.invalidFormID }
        let title: String
        let items: [Canonical.FormItem]
        switch ref {
        case let .builtin(key):
            guard let template = builtinTemplate(key: key) else { throw FormError.unknownTemplate(ref.templateId) }
            title = template.title
            items = template.items.enumerated().map { index, item in
                Canonical.FormItem(
                    id: itemID(index + 1),
                    kind: item.kind.rawValue,
                    label: item.label,
                    required: item.kind.isAnswerable && item.required ? true : nil,
                    photoRequired: item.kind.isAnswerable && item.photoRequired ? true : nil
                )
            }
        case let .custom(id):
            guard let template = customTemplates.first(where: { $0.id == id && $0.isTemplate }) else {
                throw FormError.unknownTemplate(id)
            }
            guard !template.isArchived else { throw FormError.templateArchived }
            title = template.title
            items = template.items.enumerated().map { index, item in
                var blank = strippedItem(item)
                blank.id = itemID(index + 1)
                return blank
            }
        }
        let form = Canonical.Form(
            id: formID,
            kind: FormKind.instance.rawValue,
            jobId: trimmedJob,
            templateId: ref.templateId,
            title: title,
            items: items,
            createdAt: timestamp(now)
        )
        try validate(form)
        return form
    }

    // MARK: - Answers (instances only, not while completed)

    static func setChecked(_ form: Canonical.Form, itemID: String, _ checked: Bool) throws -> Canonical.Form {
        var next = form
        let index = try answerableIndex(next, itemID: itemID, kind: .check)
        // Absent = unanswered: unticking clears the response.
        next.items[index].checked = checked ? true : nil
        return next
    }

    static func setResult(_ form: Canonical.Form, itemID: String, _ result: PassFailResult?) throws -> Canonical.Form {
        var next = form
        let index = try answerableIndex(next, itemID: itemID, kind: .passFail)
        next.items[index].result = result?.rawValue
        return next
    }

    /// An empty string clears the answer. Whitespace is kept as typed, but a
    /// blank answer does not count as answered.
    static func setText(_ form: Canonical.Form, itemID: String, _ text: String?) throws -> Canonical.Form {
        var next = form
        let index = try answerableIndex(next, itemID: itemID, kind: .text)
        let value = (text?.isEmpty ?? true) ? nil : text
        if let value, value.count > Limits.textMaxLength { throw FormError.textTooLong }
        next.items[index].text = value
        return next
    }

    /// Any answerable item can take a note (e.g. why it failed). An empty
    /// string clears it.
    static func setNote(_ form: Canonical.Form, itemID: String, _ note: String?) throws -> Canonical.Form {
        var next = form
        let index = try answerableIndex(next, itemID: itemID, kind: nil)
        let value = (note?.isEmpty ?? true) ? nil : note
        if let value, value.count > Limits.noteMaxLength { throw FormError.noteTooLong }
        next.items[index].note = value
        return next
    }

    /// Appends a job photo id to an answerable item (at most 10). Adding an
    /// id the item already holds changes nothing.
    static func addPhoto(_ form: Canonical.Form, itemID: String, photoID: String) throws -> Canonical.Form {
        var next = form
        let index = try answerableIndex(next, itemID: itemID, kind: nil)
        guard !photoID.isEmpty else { throw FormError.invalidPhotoID }
        var ids = next.items[index].photoIds ?? []
        guard !ids.contains(photoID) else { return next }
        guard ids.count < Limits.photosPerItemMaxCount else { throw FormError.tooManyPhotos }
        ids.append(photoID)
        next.items[index].photoIds = ids
        return next
    }

    /// Removes a photo id from an item. The job photo itself is untouched.
    static func removePhoto(_ form: Canonical.Form, itemID: String, photoID: String) throws -> Canonical.Form {
        var next = form
        let index = try answerableIndex(next, itemID: itemID, kind: nil)
        guard var ids = next.items[index].photoIds, ids.contains(photoID) else { return next }
        ids.removeAll { $0 == photoID }
        next.items[index].photoIds = ids.isEmpty ? nil : ids
        return next
    }

    /// Whether a photo can still be attached to the item now (the store checks
    /// this before writing any photo bytes).
    static func canAttachPhoto(_ form: Canonical.Form, itemID: String) throws {
        let index = try answerableIndex(form, itemID: itemID, kind: nil)
        guard (form.items[index].photoIds ?? []).count < Limits.photosPerItemMaxCount else {
            throw FormError.tooManyPhotos
        }
    }

    // MARK: - Edits (templates and instances, not while completed)

    /// Adds an item after `afterItemID` (or at the end). `required` and
    /// `photoRequired` are ignored for a section. Returns the new item's id.
    static func addItem(
        _ form: Canonical.Form,
        kind: ItemKind,
        label: String,
        required: Bool = false,
        photoRequired: Bool = false,
        after afterItemID: String? = nil,
        reservedItemIDs: Set<String> = []
    ) throws -> (form: Canonical.Form, itemID: String) {
        try requireEditable(form)
        guard form.items.count < Limits.itemsMaxCount else { throw FormError.invalidItemCount }
        let trimmed = try validLabel(label)
        let id = nextItemID(existing: form.items.map(\.id), reserved: reservedItemIDs)
        let item = Canonical.FormItem(
            id: id,
            kind: kind.rawValue,
            label: trimmed,
            required: kind.isAnswerable && required ? true : nil,
            photoRequired: kind.isAnswerable && photoRequired ? true : nil
        )
        var next = form
        if let afterItemID {
            guard let index = next.items.firstIndex(where: { $0.id == afterItemID }) else {
                throw FormError.itemNotFound(afterItemID)
            }
            next.items.insert(item, at: index + 1)
        } else {
            next.items.append(item)
        }
        return (next, id)
    }

    /// Changes an item's label and flags; nil leaves a value as it is. Flags
    /// on a section stay unset. Responses are kept.
    static func editItem(
        _ form: Canonical.Form,
        itemID: String,
        label: String? = nil,
        required: Bool? = nil,
        photoRequired: Bool? = nil
    ) throws -> Canonical.Form {
        try requireEditable(form)
        guard let index = form.items.firstIndex(where: { $0.id == itemID }) else {
            throw FormError.itemNotFound(itemID)
        }
        var next = form
        if let label { next.items[index].label = try validLabel(label) }
        let answerable = next.items[index].itemKind?.isAnswerable == true
        if let required, answerable { next.items[index].required = required ? true : nil }
        if let photoRequired, answerable { next.items[index].photoRequired = photoRequired ? true : nil }
        return next
    }

    /// Deletes one item. A form keeps at least one item. The item's photos
    /// stay in the job's Photos section.
    static func deleteItem(_ form: Canonical.Form, itemID: String) throws -> Canonical.Form {
        try requireEditable(form)
        guard let index = form.items.firstIndex(where: { $0.id == itemID }) else {
            throw FormError.itemNotFound(itemID)
        }
        guard form.items.count > 1 else { throw FormError.invalidItemCount }
        var next = form
        next.items.remove(at: index)
        return next
    }

    /// Puts the items in `orderedIDs` order, which must name every item once.
    static func reorderItems(_ form: Canonical.Form, orderedIDs: [String]) throws -> Canonical.Form {
        try requireEditable(form)
        guard orderedIDs.count == form.items.count,
              Set(orderedIDs) == Set(form.items.map(\.id)),
              Set(orderedIDs).count == orderedIDs.count
        else { throw FormError.invalidOrder }
        let byID = Dictionary(form.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = form
        next.items = orderedIDs.compactMap { byID[$0] }
        return next
    }

    /// SwiftUI `onMove` semantics: moves the items at `offsets` to before
    /// the item at `destination` (in the original indexing).
    static func moveItems(_ form: Canonical.Form, fromOffsets offsets: IndexSet, toOffset destination: Int) throws -> Canonical.Form {
        try requireEditable(form)
        guard !offsets.isEmpty, offsets.allSatisfy({ form.items.indices.contains($0) }),
              (0 ... form.items.count).contains(destination)
        else { throw FormError.invalidOrder }
        let moving = offsets.map { form.items[$0] }
        var remaining: [Canonical.FormItem] = []
        var insertAt = 0
        for (index, item) in form.items.enumerated() where !offsets.contains(index) {
            if index < destination { insertAt += 1 }
            remaining.append(item)
        }
        remaining.insert(contentsOf: moving, at: insertAt)
        var next = form
        next.items = remaining
        return next
    }

    static func rename(_ form: Canonical.Form, title: String) throws -> Canonical.Form {
        try requireEditable(form)
        var next = form
        next.title = try validTitle(title)
        return next
    }

    // MARK: - Progress and completion

    /// Whether an answerable item is answered: `check` ticked, `passFail` any
    /// result, `text` non-blank. Sections and unknown kinds never are.
    static func isAnswered(_ item: Canonical.FormItem) -> Bool {
        switch item.itemKind {
        case .check: item.checked == true
        case .passFail: !(item.result ?? "").isEmpty
        case .text: !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .section, nil: false
        }
    }

    static func progress(_ form: Canonical.Form) -> Progress {
        let answerable = form.items.filter { $0.itemKind?.isAnswerable == true }
        return Progress(answered: answerable.filter(isAnswered).count, answerable: answerable.count)
    }

    /// What blocks completion, in form order. `existingPhotoIDs` is the job's
    /// photos on this device (`photoIDs(forJob:in:)`): a photo id that no
    /// longer resolves does not satisfy a photo requirement.
    static func missingItems(_ form: Canonical.Form, existingPhotoIDs: Set<String>) -> [MissingItem] {
        form.items.compactMap { item -> MissingItem? in
            guard let kind = item.itemKind, kind.isAnswerable else { return nil }
            var reasons: [MissingReason] = []
            if item.required == true, !isAnswered(item) {
                switch kind {
                case .check: reasons.append(.notChecked)
                case .passFail: reasons.append(.noResult)
                case .text: reasons.append(.noText)
                case .section: break
                }
            }
            if item.photoRequired == true, resolvedPhotoIDs(item, existingPhotoIDs: existingPhotoIDs).isEmpty {
                reasons.append((item.photoIds ?? []).isEmpty ? .noPhoto : .photoUnavailable)
            }
            return reasons.isEmpty ? nil : MissingItem(itemID: item.id, label: item.label, reasons: reasons)
        }
    }

    /// Marks an in-progress instance complete, or throws `.incomplete` with
    /// what is missing.
    static func complete(_ form: Canonical.Form, existingPhotoIDs: Set<String>, now: Date) throws -> Canonical.Form {
        guard form.isInstance else { throw FormError.notAnInstance }
        guard !form.isCompleted else { throw FormError.readOnlyCompleted }
        let missing = missingItems(form, existingPhotoIDs: existingPhotoIDs)
        guard missing.isEmpty else { throw FormError.incomplete(missing) }
        var next = form
        next.completedAt = timestamp(now)
        return next
    }

    /// Clears `completedAt`; answers are kept.
    static func reopen(_ form: Canonical.Form) throws -> Canonical.Form {
        guard form.isInstance else { throw FormError.notAnInstance }
        guard form.isCompleted else { throw FormError.notCompleted }
        var next = form
        next.completedAt = nil
        return next
    }

    // MARK: - Templates

    /// "Save as template": a new template row with the form's title (or
    /// `title`) and items, every response stripped. Item fields this version
    /// does not know are dropped too, since they may be responses.
    static func makeTemplate(
        from form: Canonical.Form,
        templateID: String,
        title: String? = nil,
        now: Date
    ) throws -> Canonical.Form {
        guard isValidFormID(templateID) else { throw FormError.invalidFormID }
        let template = Canonical.Form(
            id: templateID,
            kind: FormKind.template.rawValue,
            title: try validTitle(title ?? form.title),
            items: form.items.map(strippedItem),
            createdAt: timestamp(now)
        )
        try validate(template)
        return template
    }

    /// Hides a custom template from the picker. Instances made from it are
    /// unaffected. Archiving an archived template changes nothing.
    static func archive(_ template: Canonical.Form, now: Date) throws -> Canonical.Form {
        guard template.isTemplate else { throw FormError.notATemplate }
        guard !template.isArchived else { return template }
        var next = template
        next.archivedAt = timestamp(now)
        return next
    }

    // MARK: - Validation

    /// The caps of spec §2, checked before every local write. Items of a kind
    /// this version does not know pass as long as their id and label do.
    static func validate(_ form: Canonical.Form) throws {
        guard let kind = form.formKind else { throw FormError.invalidKind }
        if kind == .instance {
            guard !(form.jobId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FormError.missingJob
            }
        }
        _ = try validTitle(form.title)
        guard (1 ... Limits.itemsMaxCount).contains(form.items.count) else { throw FormError.invalidItemCount }
        var seen = Set<String>()
        for item in form.items {
            guard !item.id.isEmpty else { throw FormError.invalidItemID }
            guard seen.insert(item.id).inserted else { throw FormError.duplicateItemID(item.id) }
            _ = try validLabel(item.label)
            if let text = item.text, text.count > Limits.textMaxLength { throw FormError.textTooLong }
            if let note = item.note, note.count > Limits.noteMaxLength { throw FormError.noteTooLong }
            if (item.photoIds ?? []).count > Limits.photosPerItemMaxCount { throw FormError.tooManyPhotos }
        }
    }

    // MARK: - Private

    private static func validTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Limits.titleMaxLength else { throw FormError.invalidTitle }
        return trimmed
    }

    private static func validLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Limits.labelMaxLength else { throw FormError.invalidLabel }
        return trimmed
    }

    private static func requireEditable(_ form: Canonical.Form) throws {
        guard form.formKind != nil else { throw FormError.invalidKind }
        if form.isInstance, form.isCompleted { throw FormError.readOnlyCompleted }
    }

    /// The index of an answerable item of `kind` (any answerable kind when
    /// nil) on an in-progress instance.
    private static func answerableIndex(_ form: Canonical.Form, itemID: String, kind: ItemKind?) throws -> Int {
        guard form.isInstance else { throw FormError.notAnInstance }
        guard !form.isCompleted else { throw FormError.readOnlyCompleted }
        guard let index = form.items.firstIndex(where: { $0.id == itemID }) else {
            throw FormError.itemNotFound(itemID)
        }
        guard let itemKind = form.items[index].itemKind, itemKind.isAnswerable else {
            throw FormError.itemNotAnswerable(itemID)
        }
        if let kind, itemKind != kind { throw FormError.wrongItemKind(itemID) }
        return index
    }

    /// The item's definition only: no response and no unknown field.
    private static func strippedItem(_ item: Canonical.FormItem) -> Canonical.FormItem {
        let answerable = item.itemKind?.isAnswerable == true
        return Canonical.FormItem(
            id: item.id,
            kind: item.kind,
            label: item.label,
            required: answerable && item.required == true ? true : nil,
            photoRequired: answerable && item.photoRequired == true ? true : nil
        )
    }
}

// MARK: - Typed accessors

extension Canonical.Form {
    /// Nil for a kind this version does not know (such a row is never listed).
    var formKind: NativeJobForms.FormKind? { NativeJobForms.FormKind(rawValue: kind) }
    var isInstance: Bool { formKind == .instance }
    var isTemplate: Bool { formKind == .template }
    var isCompleted: Bool { !(completedAt ?? "").isEmpty }
    var isArchived: Bool { !(archivedAt ?? "").isEmpty }
    var templateRef: NativeJobForms.TemplateRef? { templateId.flatMap(NativeJobForms.TemplateRef.init(templateId:)) }
}

extension Canonical.FormItem {
    /// Nil for a kind this version does not know.
    var itemKind: NativeJobForms.ItemKind? { NativeJobForms.ItemKind(rawValue: kind) }
    var passFailResult: NativeJobForms.PassFailResult? { result.flatMap(NativeJobForms.PassFailResult.init(rawValue:)) }
    var isRequired: Bool { required == true && itemKind?.isAnswerable == true }
    var isPhotoRequired: Bool { photoRequired == true && itemKind?.isAnswerable == true }
}
