import CoreGraphics
import Foundation
import ImageIO

// Phase 20 (custom job / inspection forms) pure-domain host tests:
// `Canonical.Form`/`Canonical.FormItem` round-trips and `NativeJobForms`
// (built-in library, trade keys, picker, ids, instantiate, answers, the
// completion rule, reopen, edits and caps, save-as-template, dangling photo
// ids), the forms screens' state rules (`NativeJobFormsPresentation`) and the
// PDF report's document model (`NativeFormPDFDocument`). Spec:
// docs/superpowers/specs/2026-10-02-job-forms-design.md §7. The AppStore
// wiring is covered in native/StoreIntegrationTests.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

/// Runs `body` and checks it throws exactly `expected`.
func expectError<T>(_ expected: NativeJobForms.FormError, _ label: String, _ body: () throws -> T) {
    checks += 1
    do {
        _ = try body()
        failures += 1
        print("FAIL: \(label) (no error; expected \(expected))")
    } catch let error as NativeJobForms.FormError {
        if error != expected {
            failures += 1
            print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(error)")
        }
    } catch {
        failures += 1
        print("FAIL: \(label) (unexpected \(error))")
    }
}

func run(_ label: String, _ body: () throws -> Void) {
    do { try body() } catch {
        failures += 1
        print("FAIL: \(label) threw \(error)")
    }
}

func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
    try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(value))
}

func decode<T: Decodable>(_ type: T.Type, _ value: Canonical.JSONValue) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
}

let now = Date(timeIntervalSince1970: 1_759_420_800) // 2025-10-02T16:00:00Z
let formID = "fm1759420800000_k3x9"
let jobID = "job-1"

func instance(_ key: String = "electrical-safety") throws -> Canonical.Form {
    try NativeJobForms.instantiate(.builtin(key), customTemplates: [], jobID: jobID, formID: formID, now: now)
}

/// A small hand-built instance: section, required check, required pass/fail,
/// required text, photo-required check, optional text, unknown kind.
func sample() -> Canonical.Form {
    Canonical.Form(
        id: formID, kind: "instance", jobId: jobID, templateId: "builtin:site-safety", title: "Sample",
        items: [
            .init(id: "fi_1", kind: "section", label: "Start"),
            .init(id: "fi_2", kind: "check", label: "Ticked", required: true),
            .init(id: "fi_3", kind: "passFail", label: "Tested", required: true),
            .init(id: "fi_4", kind: "text", label: "Reading", required: true),
            .init(id: "fi_5", kind: "check", label: "Photo", photoRequired: true),
            .init(id: "fi_6", kind: "text", label: "Optional"),
            .init(id: "fi_7", kind: "signature", label: "Future kind", required: true, photoRequired: true),
        ],
        createdAt: "2026-10-02T16:00:00.000Z"
    )
}

// MARK: - Canonical round-trip

run("canonical round-trip keeps unknown keys at both levels") {
    guard let path = ProcessInfo.processInfo.environment["CANONICAL_FIXTURE"] else {
        expect(false, "CANONICAL_FIXTURE is set")
        return
    }
    let rich = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    for key in ["form", "formTemplate"] {
        guard let source = rich[key] else { expect(false, "fixture has \(key)"); continue }
        let form = try decode(Canonical.Form.self, source)
        expectEqual(try json(form), source, "\(key) round-trips byte-for-byte in meaning")
    }
    let form = try decode(Canonical.Form.self, rich["form"]!)
    expect(form.preservation.unknownFields["futureFormField"] != nil, "form-level unknown key kept")
    expect(form.items[2].preservation.unknownFields["futureItemField"] == .string("retain-me"), "item-level unknown key kept")
    expectEqual(form.items[4].itemKind, nil, "an unknown item kind has no typed kind")
    expectEqual(form.formKind, .instance, "typed form kind")
    expectEqual(form.templateRef, .builtin("electrical-safety"), "typed template ref")

    // A pure operation keeps every unknown key it does not own.
    let answered = try NativeJobForms.setResult(form, itemID: "fi_3", .pass)
    let encoded = try json(answered)
    guard case let .object(fields) = encoded, case let .array(items)? = fields["items"],
          case let .object(item) = items[2], case let .object(future) = items[4]
    else { expect(false, "encoded form shape"); return }
    expect(fields["futureFormField"] != nil && fields["completedAt"] == .null, "answering keeps form unknowns and explicit null")
    expect(item["futureItemField"] == .string("retain-me") && item["result"] == .string("pass"), "answering keeps item unknowns")
    expect(future["futureSignature"] != nil && future["kind"] == .string("signature"), "an unknown item kind is kept verbatim")

    // A wire form with a kind this version does not know still decodes.
    let unknownKind = try decode(Canonical.Form.self, .object([
        "id": .string("fm1_x"), "kind": .string("checklist-v2"), "title": .string("Later"),
        "items": .array([]), "createdAt": .string("2026-10-02T16:00:00.000Z"),
    ]))
    expect(unknownKind.formKind == nil && !unknownKind.isInstance && !unknownKind.isTemplate, "an unknown form kind decodes and is neither")
}

// MARK: - Built-in library

run("built-in library integrity") {
    let library = NativeJobForms.builtinTemplates
    expectEqual(library.count, 6, "six built-in templates")
    expectEqual(Set(library.map(\.key)).count, library.count, "built-in keys are unique")
    let general = library.filter { $0.trades.contains(NativeJobForms.generalTradeKey) }.map(\.title)
    expectEqual(general, ["Pre-job walkthrough", "Job completion & cleanup", "Site safety checklist"], "three General templates")
    expectEqual(library.filter { $0.trades == ["hvac"] }.map(\.title), ["HVAC maintenance inspection"], "one HVAC template")
    expectEqual(library.filter { $0.trades == ["electrical"] }.map(\.title), ["Electrical safety inspection"], "one Electrical template")
    expectEqual(library.filter { $0.trades == ["plumbing"] }.map(\.title), ["Plumbing / water heater inspection"], "one Plumbing template")
    let forbidden = ["code", "nec", "irc", "upc", "osha", "compliant", "compliance", "comply", "regulation", "certif", "must", "law"]
    for template in library {
        let label = "built-in \(template.key)"
        expect((6 ... 15).contains(template.items.count), "\(label): 6 to 15 items (\(template.items.count))")
        expect(template.key.allSatisfy { $0.isLowercase || $0 == "-" }, "\(label): key is lowercase and dashes")
        expect(!template.trades.isEmpty && template.trades.allSatisfy { NativeJobForms.normalizedTradeKey($0) == $0 },
               "\(label): trades are normalized keys")
        expect(template.title.count <= NativeJobForms.Limits.titleMaxLength, "\(label): title within cap")
        let kinds = Set(template.items.map(\.kind))
        expect(kinds.filter(\.isAnswerable).count >= 2 && kinds.contains(.section), "\(label): a mix of kinds with sections")
        expect(template.items.first?.kind == .section, "\(label): starts with a section")
        expect(template.items.contains { $0.required }, "\(label): has required items")
        expectEqual(Set(template.items.map(\.label)).count, template.items.count, "\(label): labels are unique")
        for item in template.items {
            expect(!item.label.isEmpty && item.label.count <= NativeJobForms.Limits.labelMaxLength, "\(label): label within cap")
            expect(item.kind.isAnswerable || (!item.required && !item.photoRequired), "\(label): sections carry no flags")
            let words = item.label.lowercased().split { !$0.isLetter }.map(String.init)
            expect(!words.contains { word in forbidden.contains { word.hasPrefix($0) } },
                   "\(label): no code citation or compliance claim in \"\(item.label)\"")
        }
        let made = try NativeJobForms.instantiate(.builtin(template.key), customTemplates: [], jobID: jobID, formID: formID, now: now)
        expectEqual(made.items.map(\.id), (1 ... template.items.count).map { "fi_\($0)" }, "\(label): items numbered fi_1…")
        expectEqual(made.items.map(\.label), template.items.map(\.label), "\(label): labels copied in order")
        expectEqual(NativeJobForms.builtinTemplate(key: template.key), template, "\(label): found by key")
    }
    for key in ["pre-job-walkthrough", "job-completion", "hvac-maintenance", "electrical-safety", "plumbing-water-heater"] {
        expect(NativeJobForms.builtinTemplate(key: key)?.items.contains { $0.photoRequired } == true,
               "\(key): an inspection that wants evidence has a photo-required item")
    }
    expect(NativeJobForms.builtinTemplate(key: "hvac-maintenance")?.items.contains { $0.label == "Data plate photo" && $0.photoRequired && $0.required } == true,
           "HVAC has the required data plate photo")
    expectEqual(NativeJobForms.builtinTemplate(key: "nope"), nil, "an unknown key has no template")
}

// MARK: - Trade keys

run("trade normalization") {
    for spelling in ["hvac", "HVAC", "Hvac", " HVAC \n", "Heating & Cooling"] {
        expectEqual(NativeJobForms.normalizedTradeKey(spelling), "hvac", "\"\(spelling)\" -> hvac")
    }
    expectEqual(NativeJobForms.normalizedTradeKey(nil), nil, "nil trade")
    expectEqual(NativeJobForms.normalizedTradeKey("   "), nil, "blank trade")
    // Onboarding writes NativeTypedAccountState.Trade raw values.
    let onboarding = ["plumbing", "electrical", "hvac", "carpenter", "bricklayer", "plasterer",
                      "landscaping", "cleaning", "painting", "handyman", "other"]
    for id in onboarding {
        expectEqual(NativeJobForms.normalizedTradeKey(id), id, "onboarding id \(id) is already a key")
    }
    // SettingsView's Trade picker writes these labels.
    let settingsLabels = ["Plumbing", "Electrical", "HVAC", "Carpentry", "Landscaping", "Cleaning", "Painting", "Handyman", "Other"]
    for label in settingsLabels {
        let key = NativeJobForms.normalizedTradeKey(label)
        expect(key.map(onboarding.contains) == true, "Settings label \(label) maps to an onboarding id (\(key ?? "nil"))")
    }
    expectEqual(NativeJobForms.normalizedTradeKey("Carpentry"), "carpenter", "Carpentry -> carpenter")
    expectEqual(NativeJobForms.normalizedTradeKey("Pool service"), "pool service", "an unknown trade is kept lowercased")
    expectEqual(NativeJobForms.tradeDisplayName("hvac"), "HVAC", "HVAC display name")
    expectEqual(NativeJobForms.tradeDisplayName("electrical"), "Electrical", "Electrical display name")
}

// MARK: - Picker

run("picker ordering") {
    let template = Canonical.Form(id: "fm2_custom", kind: "template", title: "Annual walk-through",
                                  items: [.init(id: "fi_1", kind: "check", label: "Gutters")], createdAt: "2026-10-01T00:00:00.000Z")
    var archived = template
    archived.id = "fm3_archived"; archived.title = "Old"; archived.archivedAt = "2026-10-02T00:00:00.000Z"
    let aaa = Canonical.Form(id: "fm4_a", kind: "template", title: "aaa first",
                             items: [.init(id: "fi_1", kind: "text", label: "x")], createdAt: "2026-10-03T00:00:00.000Z")
    let customs = [template, archived, sample(), aaa]

    let hvac = NativeJobForms.pickerSections(ownerTrade: "HVAC", customTemplates: customs, showAll: false)
    expectEqual(hvac.map(\.group), [.custom, .trade("hvac"), .general], "HVAC owner: custom, trade, General")
    expectEqual(hvac[0].entries.map(\.title), ["aaa first", "Annual walk-through"], "custom templates by title, archived and instances excluded")
    expectEqual(hvac[0].entries.map(\.ref), [.custom("fm4_a"), .custom("fm2_custom")], "custom refs")
    expectEqual(hvac[1].title, "HVAC", "trade section titled by display name")
    expectEqual(hvac[1].entries.map(\.ref), [.builtin("hvac-maintenance")], "the owner's trade first")
    expectEqual(hvac[2].entries.map(\.ref), [.builtin("pre-job-walkthrough"), .builtin("job-completion"), .builtin("site-safety")],
                "then General")
    expectEqual(hvac[1].entries.first?.itemCount, NativeJobForms.builtinTemplate(key: "hvac-maintenance")?.items.count, "item count")

    let hvacAll = NativeJobForms.pickerSections(ownerTrade: "hvac", customTemplates: [], showAll: true)
    expectEqual(hvacAll.map(\.group), [.trade("hvac"), .general, .otherTrades], "All templates appends the rest")
    expectEqual(hvacAll.last?.entries.map(\.ref), [.builtin("electrical-safety"), .builtin("plumbing-water-heater")],
                "other trades exclude what is already shown")
    expectEqual(hvacAll.flatMap(\.entries).count, 6, "every built-in appears exactly once with All templates")

    let painter = NativeJobForms.pickerSections(ownerTrade: "Painting", customTemplates: [], showAll: false)
    expectEqual(painter.map(\.group), [.general], "a trade without built-ins starts at General")
    let none = NativeJobForms.pickerSections(ownerTrade: nil, customTemplates: [], showAll: true)
    expectEqual(none.map(\.group), [.general, .otherTrades], "no trade: General then the rest")
    expectEqual(none.last?.entries.count, 3, "no trade: the three trade templates under All")
    let plumbing = NativeJobForms.pickerSections(ownerTrade: " Plumbing", customTemplates: [], showAll: false)
    expectEqual(plumbing.first?.entries.map(\.ref), [.builtin("plumbing-water-heater")], "Settings' \"Plumbing\" finds the plumbing template")
    expectEqual(Set(hvacAll.map(\.id)).count, hvacAll.count, "section ids are unique")
}

// MARK: - Ids

run("id format and uniqueness") {
    let fixed = NativeJobForms.makeFormID(now: now, randomValue: 35)
    expectEqual(fixed, "fm1759420800000_z", "fm<ms>_<base36>")
    expect(NativeJobForms.isValidFormID(fixed), "a generated id is valid")
    var ids = Set<String>()
    for _ in 0 ..< 2000 { ids.insert(NativeJobForms.makeFormID(now: now)) }
    expectEqual(ids.count, 2000, "random suffixes keep same-millisecond ids unique")
    expect(ids.allSatisfy(NativeJobForms.isValidFormID), "every generated id is valid")
    for bad in ["", "fm", "fm_", "fm123", "fm123_", "fm_abc", "fmx1_abc", "fm1_ABC", "p123_abc", "fm1_a-b", "builtin:site-safety"] {
        expect(!NativeJobForms.isValidFormID(bad), "\"\(bad)\" is not a form id")
    }
    let collided = NativeJobForms.makeUniqueFormID(now: now, existingIDs: [fixed], randomValue: 35)
    expect(collided != fixed && NativeJobForms.isValidFormID(collided), "a forced collision retries with fresh randomness")

    expectEqual(NativeJobForms.itemID(7), "fi_7", "item id format")
    expectEqual(NativeJobForms.itemNumber("fi_12"), 12, "item number")
    for bad in ["fi_0", "fi_", "fi_01", "fi_x", "item_3", "fi_-1"] {
        expectEqual(NativeJobForms.itemNumber(bad), nil, "\(bad) has no item number")
    }
    expectEqual(NativeJobForms.nextItemID(existing: []), "fi_1", "first item id")
    expectEqual(NativeJobForms.nextItemID(existing: ["fi_1", "fi_4", "custom"]), "fi_5", "next after the highest")
    expectEqual(NativeJobForms.nextItemID(existing: ["fi_1"], reserved: ["fi_9"]), "fi_10", "a photo's item id is never reused")
    expectEqual(NativeJobForms.TemplateRef(templateId: "builtin:hvac-maintenance"), .builtin("hvac-maintenance"), "builtin ref parses")
    expectEqual(NativeJobForms.TemplateRef(templateId: "fm1_a"), .custom("fm1_a"), "custom ref parses")
    expectEqual(NativeJobForms.TemplateRef(templateId: "builtin:"), nil, "an empty builtin key is no ref")
    expectEqual(NativeJobForms.TemplateRef.builtin("x").templateId, "builtin:x", "builtin ref round-trips")
    expectEqual(NativeJobForms.timestamp(now), "2025-10-02T16:00:00.000Z", "ISO-8601 UTC with milliseconds")
}

// MARK: - Instantiate

run("instantiate") {
    let form = try instance("hvac-maintenance")
    expect(form.isInstance && form.jobId == jobID && form.templateId == "builtin:hvac-maintenance", "instance header")
    expectEqual(form.title, "HVAC maintenance inspection", "title copied")
    expectEqual(form.createdAt, "2025-10-02T16:00:00.000Z", "createdAt stamped")
    expect(form.completedAt == nil && form.archivedAt == nil, "in progress, not archived")
    expect(form.items.allSatisfy { $0.checked == nil && $0.result == nil && $0.text == nil && $0.note == nil && $0.photoIds == nil },
           "no responses")
    expect(form.items.filter { $0.kind == "section" }.allSatisfy { $0.required == nil && $0.photoRequired == nil }, "sections carry no flags")
    expect(form.items.contains { $0.label == "Data plate photo" && $0.photoRequired == true && $0.required == true }, "flags copied")
    expectEqual(NativeJobForms.progress(form), .init(answered: 0, answerable: 11), "HVAC progress starts at 0/11")
    expectEqual(NativeJobForms.progress(form).label, "0/11", "progress label")

    expectError(.unknownTemplate("builtin:nope"), "unknown built-in") {
        try NativeJobForms.instantiate(.builtin("nope"), customTemplates: [], jobID: jobID, formID: formID, now: now)
    }
    expectError(.missingJob, "blank job") {
        try NativeJobForms.instantiate(.builtin("site-safety"), customTemplates: [], jobID: "  ", formID: formID, now: now)
    }
    expectError(.invalidFormID, "malformed form id") {
        try NativeJobForms.instantiate(.builtin("site-safety"), customTemplates: [], jobID: jobID, formID: "builtin-1", now: now)
    }

    // From a custom template: definition copied, stray responses dropped, renumbered.
    var custom = Canonical.Form(id: "fm5_tpl", kind: "template", title: "Walk-through",
                                items: [
                                    .init(id: "fi_3", kind: "section", label: "Roof", required: true),
                                    .init(id: "fi_9", kind: "check", label: "Gutters", required: true, checked: true, note: "stray"),
                                    .init(id: "fi_4", kind: "passFail", label: "Flashing", photoRequired: true, result: "pass", photoIds: ["p1_a"]),
                                ],
                                createdAt: "2026-10-01T00:00:00.000Z")
    custom.items[1].preservation = Canonical.Preservation(unknownFields: ["futureAnswer": .bool(true)])
    let fromCustom = try NativeJobForms.instantiate(.custom("fm5_tpl"), customTemplates: [custom], jobID: jobID, formID: formID, now: now)
    expectEqual(fromCustom.templateId, "fm5_tpl", "templateId is the custom id")
    expectEqual(fromCustom.items.map(\.id), ["fi_1", "fi_2", "fi_3"], "custom items renumbered")
    expectEqual(fromCustom.items.map(\.label), ["Roof", "Gutters", "Flashing"], "custom labels copied")
    expect(fromCustom.items[0].required == nil, "a section's stray flag is dropped")
    expect(fromCustom.items[1].required == true && fromCustom.items[1].checked == nil && fromCustom.items[1].note == nil
           && fromCustom.items[1].preservation.unknownFields.isEmpty, "responses and unknown fields dropped")
    expect(fromCustom.items[2].photoRequired == true && fromCustom.items[2].result == nil && fromCustom.items[2].photoIds == nil,
           "photo flag kept, photo ids dropped")

    var archived = custom
    archived.archivedAt = "2026-10-02T00:00:00.000Z"
    expectError(.templateArchived, "an archived template is not instantiated") {
        try NativeJobForms.instantiate(.custom("fm5_tpl"), customTemplates: [archived], jobID: jobID, formID: formID, now: now)
    }
    expectError(.unknownTemplate(formID), "an instance is not a template") {
        try NativeJobForms.instantiate(.custom(formID), customTemplates: [sample()], jobID: jobID, formID: "fm9_z", now: now)
    }
}

// MARK: - Answers

run("answer operations") {
    var form = sample()
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", true)
    expectEqual(form.items[1].checked, true, "check ticks")
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", false)
    expectEqual(form.items[1].checked, nil, "unticking clears the response")
    form = try NativeJobForms.setResult(form, itemID: "fi_3", .na)
    expectEqual(form.items[2].passFailResult, .na, "pass/fail result")
    form = try NativeJobForms.setResult(form, itemID: "fi_3", nil)
    expectEqual(form.items[2].result, nil, "result clears")
    form = try NativeJobForms.setText(form, itemID: "fi_4", "  42 psi ")
    expectEqual(form.items[3].text, "  42 psi ", "text is kept as typed")
    form = try NativeJobForms.setText(form, itemID: "fi_4", "")
    expectEqual(form.items[3].text, nil, "empty text clears")
    let maxText = String(repeating: "t", count: 2000)
    expectEqual(try NativeJobForms.setText(form, itemID: "fi_4", maxText).items[3].text?.count, 2000, "2,000-character text fits")
    expectError(.textTooLong, "2,001-character text") { try NativeJobForms.setText(form, itemID: "fi_4", maxText + "t") }
    form = try NativeJobForms.setNote(form, itemID: "fi_3", "Breaker 14 warm")
    expectEqual(form.items[2].note, "Breaker 14 warm", "any answerable item takes a note")
    expectEqual(try NativeJobForms.setNote(form, itemID: "fi_3", "").items[2].note, nil, "empty note clears")
    let maxNote = String(repeating: "n", count: 1000)
    expectEqual(try NativeJobForms.setNote(form, itemID: "fi_2", maxNote).items[1].note?.count, 1000, "1,000-character note fits")
    expectError(.noteTooLong, "1,001-character note") { try NativeJobForms.setNote(form, itemID: "fi_2", maxNote + "n") }

    expectError(.wrongItemKind("fi_3"), "a tick on a pass/fail item") { try NativeJobForms.setChecked(form, itemID: "fi_3", true) }
    expectError(.wrongItemKind("fi_2"), "a result on a check") { try NativeJobForms.setResult(form, itemID: "fi_2", .pass) }
    expectError(.wrongItemKind("fi_2"), "text on a check") { try NativeJobForms.setText(form, itemID: "fi_2", "x") }
    expectError(.itemNotAnswerable("fi_1"), "a note on a section") { try NativeJobForms.setNote(form, itemID: "fi_1", "x") }
    expectError(.itemNotAnswerable("fi_7"), "an unknown kind takes no answer") { try NativeJobForms.setNote(form, itemID: "fi_7", "x") }
    expectError(.itemNotFound("fi_99"), "a missing item") { try NativeJobForms.setChecked(form, itemID: "fi_99", true) }

    // Photos.
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p1_a")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p1_a")
    expectEqual(form.items[4].photoIds, ["p1_a"], "adding the same photo twice changes nothing")
    for n in 2 ... 10 { form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p\(n)_a") }
    expectEqual(form.items[4].photoIds?.count, 10, "ten photos fit")
    expectError(.tooManyPhotos, "an eleventh photo") { try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p11_a") }
    expectError(.tooManyPhotos, "canAttachPhoto refuses a full item") { try NativeJobForms.canAttachPhoto(form, itemID: "fi_5") }
    expectError(.invalidPhotoID, "an empty photo id") { try NativeJobForms.addPhoto(sample(), itemID: "fi_5", photoID: "") }
    expectError(.itemNotAnswerable("fi_1"), "a photo on a section") { try NativeJobForms.addPhoto(form, itemID: "fi_1", photoID: "p1_b") }
    form = try NativeJobForms.removePhoto(form, itemID: "fi_5", photoID: "p1_a")
    expectEqual(form.items[4].photoIds?.first, "p2_a", "removing keeps the order of the rest")
    var single = try NativeJobForms.addPhoto(sample(), itemID: "fi_2", photoID: "p1_a")
    single = try NativeJobForms.removePhoto(single, itemID: "fi_2", photoID: "p1_a")
    expectEqual(single.items[1].photoIds, nil, "removing the last photo clears the list")
    expectEqual(try NativeJobForms.removePhoto(single, itemID: "fi_2", photoID: "nope"), single, "removing an absent photo changes nothing")

    var template = sample()
    template.kind = "template"; template.jobId = nil
    expectError(.notAnInstance, "a template takes no answers") { try NativeJobForms.setChecked(template, itemID: "fi_2", true) }
}

// MARK: - Completion

run("completion rule: each failure reason") {
    let photos: Set<String> = ["p1_live"]
    let blank = sample()
    let missing = NativeJobForms.missingItems(blank, existingPhotoIDs: photos)
    expectEqual(missing.map(\.itemID), ["fi_2", "fi_3", "fi_4", "fi_5"], "required and photo-required items block, in form order")
    expectEqual(missing.map(\.reasons), [[.notChecked], [.noResult], [.noText], [.noPhoto]], "one typed reason each")
    expectEqual(missing.first?.label, "Ticked", "the label rides along")
    expect(!missing.contains { $0.itemID == "fi_6" || $0.itemID == "fi_7" || $0.itemID == "fi_1" },
           "optional items, sections and unknown kinds never block")

    var form = try NativeJobForms.setChecked(blank, itemID: "fi_2", true)
    form = try NativeJobForms.setResult(form, itemID: "fi_3", .fail)
    form = try NativeJobForms.setText(form, itemID: "fi_4", "   \n")
    expectEqual(NativeJobForms.missingItems(form, existingPhotoIDs: photos).map(\.reasons), [[.noText], [.noPhoto]],
                "a blank text answer does not count; a Fail result does")
    form = try NativeJobForms.setText(form, itemID: "fi_4", "41 psi")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p9_deleted")
    expectEqual(NativeJobForms.missingItems(form, existingPhotoIDs: photos).map(\.reasons), [[.photoUnavailable]],
                "a dangling photo id does not satisfy the photo requirement")
    expectEqual(NativeJobForms.resolvedPhotoIDs(form.items[4], existingPhotoIDs: photos), [], "dangling ids are not shown")
    expectError(.incomplete([.init(itemID: "fi_5", label: "Photo", reasons: [.photoUnavailable])]), "complete refuses with the list") {
        try NativeJobForms.complete(form, existingPhotoIDs: photos, now: now)
    }
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p1_live")
    expectEqual(NativeJobForms.resolvedPhotoIDs(form.items[4], existingPhotoIDs: photos), ["p1_live"], "a live photo resolves")
    expect(NativeJobForms.missingItems(form, existingPhotoIDs: photos).isEmpty, "everything answered")

    // Both reasons on one item.
    var both = sample()
    both.items[1].photoRequired = true
    let bothMissing = NativeJobForms.missingItems(both, existingPhotoIDs: [])
    expectEqual(bothMissing.first?.reasons, [.notChecked, .noPhoto], "an item can miss its answer and its photo")
    expect(bothMissing.first?.message.contains("Not checked") == true && bothMissing.first?.message.contains("photo") == true,
           "the message joins both reasons")
    expect(NativeJobForms.MissingReason.allCases.allSatisfy { !$0.message.isEmpty }, "every reason has a message")

    // A photo of another job does not count: the store passes this job's ids.
    let otherJobPhoto = try decode(Canonical.JobPhoto.self, .object([
        "id": .string("p1_live"), "jobId": .string("job-2"), "createdAt": .string("2026-10-02T00:00:00.000Z"),
    ]))
    let thisJobIDs = NativeJobForms.photoIDs(forJob: jobID, in: [otherJobPhoto])
    expect(!NativeJobForms.missingItems(form, existingPhotoIDs: thisJobIDs).isEmpty, "another job's photo does not resolve")

    // Complete, read-only, reopen.
    let completed = try NativeJobForms.complete(form, existingPhotoIDs: photos, now: now)
    expectEqual(completed.completedAt, "2025-10-02T16:00:00.000Z", "completion stamps completedAt")
    expect(completed.isCompleted, "completed")
    expectError(.readOnlyCompleted, "completing twice") { try NativeJobForms.complete(completed, existingPhotoIDs: photos, now: now) }
    expectError(.readOnlyCompleted, "a completed form takes no answer") { try NativeJobForms.setChecked(completed, itemID: "fi_2", false) }
    expectError(.readOnlyCompleted, "a completed form takes no note") { try NativeJobForms.setNote(completed, itemID: "fi_2", "x") }
    expectError(.readOnlyCompleted, "a completed form takes no photo") { try NativeJobForms.addPhoto(completed, itemID: "fi_2", photoID: "p1_x") }
    expectError(.readOnlyCompleted, "a completed form takes no new item") {
        try NativeJobForms.addItem(completed, kind: .check, label: "More")
    }
    expectError(.readOnlyCompleted, "a completed form cannot be renamed") { try NativeJobForms.rename(completed, title: "New") }
    expectError(.readOnlyCompleted, "a completed form cannot lose items") { try NativeJobForms.deleteItem(completed, itemID: "fi_6") }
    expectError(.readOnlyCompleted, "a completed form cannot be reordered") {
        try NativeJobForms.reorderItems(completed, orderedIDs: completed.items.map(\.id).reversed())
    }
    let reopened = try NativeJobForms.reopen(completed)
    expect(reopened.completedAt == nil && reopened.items == form.items, "reopen clears completedAt and keeps answers")
    expectEqual(try NativeJobForms.setChecked(reopened, itemID: "fi_2", false).items[1].checked, nil, "a reopened form is editable")
    expectError(.notCompleted, "reopening an in-progress form") { try NativeJobForms.reopen(reopened) }
    var template = sample()
    template.kind = "template"; template.jobId = nil
    expectError(.notAnInstance, "a template does not complete") { try NativeJobForms.complete(template, existingPhotoIDs: [], now: now) }
    expectError(.notAnInstance, "a template does not reopen") { try NativeJobForms.reopen(template) }
}

run("progress counts answered over answerable") {
    var form = sample()
    expectEqual(NativeJobForms.progress(form), .init(answered: 0, answerable: 5), "sections and unknown kinds are not answerable")
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", true)
    form = try NativeJobForms.setResult(form, itemID: "fi_3", .pass)
    form = try NativeJobForms.setText(form, itemID: "fi_6", " ")
    expectEqual(NativeJobForms.progress(form).label, "2/5", "a blank text answer is not answered")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p1_a")
    expectEqual(NativeJobForms.progress(form).answered, 2, "a photo alone does not tick a check")
    expectEqual(NativeJobForms.Progress(answered: 0, answerable: 0).fraction, 0, "an empty form has no fraction")
    expectEqual(NativeJobForms.Progress(answered: 3, answerable: 4).fraction, 0.75, "fraction")
}

// MARK: - Edits and caps

run("edit operations and caps") {
    var form = sample()
    let added = try NativeJobForms.addItem(form, kind: .passFail, label: "  Gas valve  ", required: true, photoRequired: true)
    expectEqual(added.itemID, "fi_8", "a new item gets the next id")
    expectEqual(added.form.items.last?.label, "Gas valve", "label trimmed")
    expect(added.form.items.last?.required == true && added.form.items.last?.photoRequired == true, "flags set")
    let section = try NativeJobForms.addItem(form, kind: .section, label: "Outside", required: true, photoRequired: true, after: "fi_1")
    expectEqual(section.form.items[1].id, section.itemID, "inserted after the given item")
    expect(section.form.items[1].required == nil && section.form.items[1].photoRequired == nil, "section flags ignored")
    expectEqual(try NativeJobForms.addItem(form, kind: .check, label: "x", reservedItemIDs: ["fi_20"]).itemID, "fi_21",
                "reserved ids are skipped")
    expectError(.itemNotFound("fi_99"), "inserting after a missing item") {
        try NativeJobForms.addItem(form, kind: .check, label: "x", after: "fi_99")
    }
    expectError(.invalidLabel, "blank label") { try NativeJobForms.addItem(form, kind: .check, label: " \n ") }
    expectEqual(try NativeJobForms.addItem(form, kind: .check, label: String(repeating: "l", count: 200)).form.items.count, 8,
                "a 200-character label fits")
    expectError(.invalidLabel, "a 201-character label") {
        try NativeJobForms.addItem(form, kind: .check, label: String(repeating: "l", count: 201))
    }
    var full = form
    full.items = (1 ... 100).map { .init(id: "fi_\($0)", kind: "check", label: "Item \($0)") }
    expectError(.invalidItemCount, "a 101st item") { try NativeJobForms.addItem(full, kind: .check, label: "One more") }

    form = try NativeJobForms.editItem(form, itemID: "fi_2", label: " Ticked twice ", required: false, photoRequired: true)
    expect(form.items[1].label == "Ticked twice" && form.items[1].required == nil && form.items[1].photoRequired == true,
           "edit item label and flags")
    form = try NativeJobForms.editItem(form, itemID: "fi_1", required: true)
    expectEqual(form.items[0].required, nil, "a section never takes flags")
    expectError(.invalidLabel, "editing to a blank label") { try NativeJobForms.editItem(form, itemID: "fi_2", label: "") }
    expectError(.itemNotFound("fi_0"), "editing a missing item") { try NativeJobForms.editItem(form, itemID: "fi_0", label: "x") }

    form = try NativeJobForms.deleteItem(form, itemID: "fi_6")
    expect(!form.items.contains { $0.id == "fi_6" } && form.items.count == 6, "delete removes one item")
    expectError(.itemNotFound("fi_6"), "deleting twice") { try NativeJobForms.deleteItem(form, itemID: "fi_6") }
    var one = form
    one.items = [form.items[1]]
    expectError(.invalidItemCount, "a form keeps at least one item") { try NativeJobForms.deleteItem(one, itemID: one.items[0].id) }
    expectEqual(NativeJobForms.nextItemID(existing: form.items.map(\.id)), "fi_8", "ids keep climbing after a delete")

    let order = ["fi_7", "fi_1", "fi_2", "fi_5", "fi_3", "fi_4"]
    expectEqual(try NativeJobForms.reorderItems(form, orderedIDs: order).items.map(\.id), order, "reorder by ids")
    expectError(.invalidOrder, "a reorder missing an item") { try NativeJobForms.reorderItems(form, orderedIDs: Array(order.dropLast())) }
    expectError(.invalidOrder, "a reorder with a duplicate") {
        try NativeJobForms.reorderItems(form, orderedIDs: Array(order.dropLast()) + ["fi_7"])
    }
    expectError(.invalidOrder, "a reorder with a stranger") { try NativeJobForms.reorderItems(form, orderedIDs: Array(order.dropLast()) + ["fi_9"]) }

    let ids = form.items.map(\.id) // fi_1 fi_2 fi_3 fi_4 fi_5 fi_7
    expectEqual(try NativeJobForms.moveItems(form, fromOffsets: [0], toOffset: 3).items.map(\.id),
                ["fi_2", "fi_3", "fi_1", "fi_4", "fi_5", "fi_7"], "onMove down")
    expectEqual(try NativeJobForms.moveItems(form, fromOffsets: [4], toOffset: 1).items.map(\.id),
                ["fi_1", "fi_5", "fi_2", "fi_3", "fi_4", "fi_7"], "onMove up")
    expectEqual(try NativeJobForms.moveItems(form, fromOffsets: [1, 2], toOffset: 6).items.map(\.id),
                ["fi_1", "fi_4", "fi_5", "fi_7", "fi_2", "fi_3"], "onMove several to the end")
    expectEqual(try NativeJobForms.moveItems(form, fromOffsets: [2], toOffset: 2).items.map(\.id), ids, "onMove in place")
    expectError(.invalidOrder, "onMove out of range") { try NativeJobForms.moveItems(form, fromOffsets: [9], toOffset: 0) }
    expectError(.invalidOrder, "onMove past the end") { try NativeJobForms.moveItems(form, fromOffsets: [0], toOffset: 7) }

    expectEqual(try NativeJobForms.rename(form, title: "  Panel check ").title, "Panel check", "rename trims")
    expectEqual(try NativeJobForms.rename(form, title: String(repeating: "t", count: 80)).title.count, 80, "an 80-character title fits")
    expectError(.invalidTitle, "an 81-character title") { try NativeJobForms.rename(form, title: String(repeating: "t", count: 81)) }
    expectError(.invalidTitle, "a blank title") { try NativeJobForms.rename(form, title: "   ") }

    // Templates (archived or not) are editable; they take no answers.
    var template = sample()
    template.kind = "template"; template.jobId = nil; template.archivedAt = "2026-10-02T00:00:00.000Z"
    expectEqual(try NativeJobForms.rename(template, title: "Tpl").title, "Tpl", "a template can be renamed")
    expectEqual(try NativeJobForms.addItem(template, kind: .text, label: "More").form.items.count, 8, "a template takes items")
    var unknown = sample()
    unknown.kind = "checklist-v2"
    expectError(.invalidKind, "an unknown form kind is not edited") { try NativeJobForms.rename(unknown, title: "x") }
}

run("validation caps") {
    expectNoThrow("the sample is valid") { try NativeJobForms.validate(sample()) }
    var form = sample()
    form.title = ""
    expectError(.invalidTitle, "blank title") { try NativeJobForms.validate(form) }
    form = sample(); form.title = String(repeating: "x", count: 81)
    expectError(.invalidTitle, "long title") { try NativeJobForms.validate(form) }
    form = sample(); form.items = []
    expectError(.invalidItemCount, "no items") { try NativeJobForms.validate(form) }
    form = sample(); form.items = (1 ... 101).map { .init(id: "fi_\($0)", kind: "check", label: "x") }
    expectError(.invalidItemCount, "101 items") { try NativeJobForms.validate(form) }
    form.items.removeLast()
    expectNoThrow("100 items") { try NativeJobForms.validate(form) }
    form = sample(); form.items[2].id = "fi_2"
    expectError(.duplicateItemID("fi_2"), "duplicate item ids") { try NativeJobForms.validate(form) }
    form = sample(); form.items[2].id = ""
    expectError(.invalidItemID, "empty item id") { try NativeJobForms.validate(form) }
    form = sample(); form.items[2].label = String(repeating: "x", count: 201)
    expectError(.invalidLabel, "long label") { try NativeJobForms.validate(form) }
    form = sample(); form.items[3].text = String(repeating: "x", count: 2001)
    expectError(.textTooLong, "long text") { try NativeJobForms.validate(form) }
    form = sample(); form.items[3].note = String(repeating: "x", count: 1001)
    expectError(.noteTooLong, "long note") { try NativeJobForms.validate(form) }
    form = sample(); form.items[4].photoIds = (1 ... 11).map { "p\($0)_a" }
    expectError(.tooManyPhotos, "eleven photos") { try NativeJobForms.validate(form) }
    form = sample(); form.jobId = nil
    expectError(.missingJob, "an instance needs a job") { try NativeJobForms.validate(form) }
    form = sample(); form.kind = "draft"
    expectError(.invalidKind, "an unknown kind is not written") { try NativeJobForms.validate(form) }
    form = sample(); form.kind = "template"; form.jobId = nil
    expectNoThrow("a template needs no job") { try NativeJobForms.validate(form) }
}

func expectNoThrow(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do { try body() } catch {
        failures += 1
        print("FAIL: \(label) threw \(error)")
    }
}

// MARK: - Save as template, archive

run("save as template strips every response") {
    var form = sample()
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", true)
    form = try NativeJobForms.setResult(form, itemID: "fi_3", .fail)
    form = try NativeJobForms.setText(form, itemID: "fi_4", "41 psi")
    form = try NativeJobForms.setNote(form, itemID: "fi_3", "loose")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p1_a")
    form.items[2].preservation = Canonical.Preservation(unknownFields: ["futureAnswer": .string("x")])
    form.completedAt = "2026-10-02T17:00:00.000Z"

    let template = try NativeJobForms.makeTemplate(from: form, templateID: "fm9_tpl", now: now)
    expect(template.isTemplate && template.jobId == nil && template.templateId == nil && template.completedAt == nil
           && template.archivedAt == nil, "a template header with no job fields (even from a completed form)")
    expectEqual(template.title, form.title, "title copied")
    expectEqual(template.createdAt, "2025-10-02T16:00:00.000Z", "createdAt stamped")
    expectEqual(template.items.map(\.id), form.items.map(\.id), "item ids kept")
    expectEqual(template.items.map(\.label), form.items.map(\.label), "labels kept")
    expectEqual(template.items.map(\.kind), form.items.map(\.kind), "kinds kept")
    expect(template.items.allSatisfy {
        $0.checked == nil && $0.result == nil && $0.text == nil && $0.note == nil && $0.photoIds == nil
            && $0.preservation.unknownFields.isEmpty
    }, "every response and unknown field stripped")
    expect(template.items[1].required == true && template.items[4].photoRequired == true, "flags kept")
    expect(template.items[6].required == nil, "an unknown kind's flags are dropped")
    guard case let .object(encoded) = try json(template), case let .array(items)? = encoded["items"],
          case let .object(first) = items[2]
    else { expect(false, "template encodes"); return }
    expectEqual(Set(first.keys), ["id", "kind", "label", "required"], "a stripped item encodes only its definition")
    expect(encoded["completedAt"] == nil && encoded["jobId"] == nil, "no response keys on the wire")
    expectEqual(try NativeJobForms.makeTemplate(from: form, templateID: "fm9_tpl", title: " Mine ", now: now).title, "Mine",
                "a new title")
    expectError(.invalidTitle, "a blank template title") {
        try NativeJobForms.makeTemplate(from: form, templateID: "fm9_tpl", title: " ", now: now)
    }
    expectError(.invalidFormID, "a malformed template id") { try NativeJobForms.makeTemplate(from: form, templateID: "x", now: now) }

    let archived = try NativeJobForms.archive(template, now: now)
    expectEqual(archived.archivedAt, "2025-10-02T16:00:00.000Z", "archive stamps archivedAt")
    expect(archived.isArchived, "archived")
    expectEqual(try NativeJobForms.archive(archived, now: now.addingTimeInterval(60)), archived, "archiving twice changes nothing")
    expectError(.notATemplate, "an instance is not archived") { try NativeJobForms.archive(sample(), now: now) }
}

// MARK: - Lookups

run("lookups") {
    var a = sample(); a.id = "fm2_b"; a.createdAt = "2026-10-02T17:00:00.000Z"
    var b = sample(); b.id = "fm1_a"; b.createdAt = "2026-10-02T16:00:00.000Z"
    var c = sample(); c.id = "fm3_c"; c.jobId = "job-2"
    var tpl = sample(); tpl.id = "fm4_t"; tpl.kind = "template"; tpl.jobId = jobID
    var future = sample(); future.id = "fm5_f"; future.kind = "checklist-v2"
    let all = [a, b, c, tpl, future]
    expectEqual(NativeJobForms.instances(forJob: jobID, in: all).map(\.id), ["fm1_a", "fm2_b"],
                "a job's instances, oldest first; templates, other jobs and unknown kinds excluded")
    expectEqual(NativeJobForms.activeTemplates(in: all).map(\.id), ["fm4_t"], "templates only")
}

// MARK: - Screen state (Domain/NativeJobFormsPresentation.swift)

typealias Presentation = NativeJobFormsPresentation

let phoenix: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}()

func jobPhoto(_ id: String, job: String = jobID) throws -> Canonical.JobPhoto {
    try decode(Canonical.JobPhoto.self, .object([
        "id": .string(id), "jobId": .string(job), "createdAt": .string("2026-10-02T16:00:00.000Z"),
    ]))
}

run("presentation: job detail rows and status") {
    var form = sample()
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", true)
    let open = Presentation.rowSummary(form)
    expectEqual(open.progressLabel, "1/5", "row progress is answered over answerable (sections and unknown kinds excluded)")
    expectEqual(open.statusLabel, "In progress", "an open form's badge says In progress")
    expect(!open.isCompleted, "not completed")
    expectEqual(open.accessibilityLabel, "Sample, 1 of 5 answered, in progress", "the row reads as one sentence")
    expectEqual(open.unsavedLabel, nil, "no unsaved text")
    let unsaved = Presentation.rowSummary(form, hasUnsavedText: true)
    expectEqual(unsaved.unsavedLabel, "Unsaved text", "a form whose screen closed with unsaved text says so in text")
    expectEqual(unsaved.accessibilityLabel, "Sample, 1 of 5 answered, in progress, unsaved text", "and VoiceOver reads it")
    expectEqual(open.id, formID, "rows are identified by form id")
    expectEqual(Presentation.statusText(form, calendar: phoenix), "In progress", "status text while open")
    expect(Presentation.isEditable(form), "an open instance is editable")

    form.completedAt = "2025-10-03T03:00:00.000Z"
    let done = Presentation.rowSummary(form)
    expectEqual(done.statusLabel, "Completed", "a completed form's badge says Completed (text, not color)")
    expectEqual(done.accessibilityLabel, "Sample, 1 of 5 answered, completed", "completed row reads its status")
    expectEqual(Presentation.statusText(form, calendar: phoenix), "Completed Oct 2, 2025",
                "the completed date is the owner's local date (03:00Z is still Oct 2 in Phoenix)")
    form.completedAt = "2025-10-03T03:00:00Z"
    expectEqual(Presentation.statusText(form, calendar: phoenix), "Completed Oct 2, 2025", "a stamp without fractions parses")
    form.completedAt = "not a date"
    expectEqual(Presentation.statusText(form, calendar: phoenix), "Completed", "an unreadable stamp still says Completed")
    expect(!Presentation.isEditable(form), "a completed instance is read-only")
    var template = sample(); template.kind = "template"
    expect(!Presentation.isEditable(template), "a template takes no answers")
    expectEqual(Presentation.progressText(.init(answered: 7, answerable: 12)), "7 of 12 answered", "long progress text")
}

run("presentation: item groups by section") {
    let groups = Presentation.itemGroups(sample())
    expectEqual(groups.map(\.id), ["fi_1"], "one group, keyed by its heading")
    expectEqual(groups.first?.title, "Start", "the heading is the group title")
    expectEqual(groups.first?.items.map(\.id), ["fi_2", "fi_3", "fi_4", "fi_5", "fi_6", "fi_7"],
                "every non-heading item, unknown kinds included (the screen explains them)")
    let mixed = Canonical.Form(
        id: formID, kind: "instance", jobId: jobID, title: "Mixed",
        items: [
            .init(id: "fi_1", kind: "check", label: "Before any heading"),
            .init(id: "fi_2", kind: "section", label: "Empty"),
            .init(id: "fi_3", kind: "section", label: "Outside"),
            .init(id: "fi_4", kind: "passFail", label: "Unit"),
            .init(id: "fi_5", kind: "section", label: "Trailing"),
        ],
        createdAt: "2026-10-02T16:00:00.000Z"
    )
    let mixedGroups = Presentation.itemGroups(mixed)
    expectEqual(mixedGroups.map(\.id), ["start", "fi_3"], "an empty or trailing heading makes no group")
    expectEqual(mixedGroups.map(\.title), [nil, "Outside"], "items before the first heading have no title")
    expectEqual(mixedGroups.map { $0.items.map(\.id) }, [["fi_1"], ["fi_4"]], "items stay in form order")
}

run("presentation: kinds and flags") {
    expectEqual(NativeJobForms.ItemKind.allCases.map(Presentation.kindName),
                ["Section heading", "Checkbox", "Pass / Fail / N/A", "Text answer"], "kind names")
    expectEqual(Presentation.kindName(rawKind: "signature"), "Unsupported item", "an unknown kind is named")
    expectEqual(Set(["section", "check", "passFail", "text", "x"].map(Presentation.kindSymbol)).count, 5, "distinct kind symbols")
    let items = sample().items
    expectEqual(Presentation.flagsText(items[1]), "Required", "required flag")
    expectEqual(Presentation.flagsText(items[4]), "Photo required", "photo flag")
    expectEqual(Presentation.flagsText(items[5]), nil, "no flags")
    expectEqual(Presentation.flagsText(items[6]), nil, "an unknown kind's flags are not shown")
    var both = items[3]; both.photoRequired = true
    expectEqual(Presentation.flagsText(both), "Required · Photo required", "both flags")
    var section = items[0]; section.required = true
    expectEqual(Presentation.flagsText(section), nil, "a section heading shows no flags")
}

run("presentation: text drafts commit only real changes") {
    expectEqual(Presentation.textToCommit(draft: "", stored: nil), nil, "empty equals absent")
    expectEqual(Presentation.textToCommit(draft: "41 psi", stored: "41 psi"), nil, "unchanged")
    expectEqual(Presentation.textToCommit(draft: "42 psi", stored: "41 psi"), "42 psi", "changed")
    expectEqual(Presentation.textToCommit(draft: "", stored: "41 psi"), "", "clearing is a change")
    expectEqual(Presentation.textToCommit(draft: " ", stored: nil), " ", "whitespace is kept as typed")
    expectEqual(Presentation.clamped(String(repeating: "a", count: 2_005), field: .answer).count, 2_000, "answers stop at 2,000")
    expectEqual(Presentation.clamped(String(repeating: "n", count: 1_200), field: .note).count, 1_000, "notes stop at 1,000")
    expectEqual(Presentation.clamped("short", field: .note), "short", "short text is untouched")
    expectEqual(Presentation.TextSlot.answer.limit, NativeJobForms.Limits.textMaxLength, "answer cap")
    expectEqual(Presentation.TextSlot.note.limit, NativeJobForms.Limits.noteMaxLength, "note cap")

    var form = sample()
    form = try NativeJobForms.setText(form, itemID: "fi_4", "41 psi")
    form = try NativeJobForms.setNote(form, itemID: "fi_2", "old")
    let drafts: [Presentation.DraftKey: String] = [
        .init(itemID: "fi_6", field: .answer): "later item",
        .init(itemID: "fi_4", field: .answer): "41 psi",
        .init(itemID: "fi_2", field: .note): "new note",
        .init(itemID: "fi_99", field: .answer): "gone",
        .init(itemID: "fi_3", field: .note): "",
    ]
    expectEqual(Presentation.commitOrder(drafts: drafts, form: form).map { "\($0.itemID)/\($0.field.rawValue)" },
                ["fi_2/note", "fi_3/note", "fi_4/answer", "fi_6/answer", "fi_99/answer"],
                "drafts commit in form order, answer before note; a gone item's draft comes last")
    expectEqual(Presentation.draftCommitStep(.init(itemID: "fi_2", field: .note), draft: "new note", form: form),
                .write("new note"), "a changed note is written")
    expectEqual(Presentation.draftCommitStep(.init(itemID: "fi_4", field: .answer), draft: "41 psi", form: form),
                .clear, "an unchanged answer is cleared without a write")
    expectEqual(Presentation.draftCommitStep(.init(itemID: "fi_3", field: .note), draft: "", form: form),
                .clear, "an empty note over no note is unchanged")
    expectEqual(Presentation.draftCommitStep(.init(itemID: "fi_99", field: .answer), draft: "gone", form: form),
                .itemGone, "an item that is gone takes nothing")
    expectEqual(Presentation.draftCommitStep(.init(itemID: "fi_2", field: .note), draft: "x", form: nil),
                .itemGone, "a form that is gone takes nothing")
    expectEqual(Presentation.storedText(form.items[3], field: .answer), "41 psi", "stored answer")
    expectEqual(Presentation.storedText(form.items[3], field: .note), "", "absent note reads empty")
    expect(Presentation.showsNote(form.items[1], opened: false), "an item with a note shows it")
    expect(!Presentation.showsNote(form.items[2], opened: false), "no note, not opened: the Add note button shows")
    expect(Presentation.showsNote(form.items[2], opened: true), "an opened note shows")
    expect(Presentation.textCommitDebounceSeconds >= 1 && Presentation.textCommitDebounceSeconds <= 3,
           "text commits after a short pause, not per keystroke")
}

run("presentation: photo slots") {
    var item = sample().items[4]
    item.photoIds = ["p1", "p_unsynced", "p2"]
    let slots = Presentation.photoSlots(item, existingPhotoIDs: ["p1", "p2", "p_other"])
    expectEqual(slots.resolvedIDs, ["p1", "p2"], "resolved in stored order")
    expectEqual(slots.unresolvedIDs, ["p_unsynced"], "a link whose photo record is not here is unresolved")
    expectEqual(slots.remaining, 7, "room counts every stored link, as the domain cap does")
    expect(!slots.isFull, "not full")
    expectEqual(slots.storedCount, 3, "three links")
    expectEqual(Presentation.photoCountLabel(slots), "3 of 10 photos", "the count matches the tiles shown, unresolved included")

    // Review fix (2026-10-03): a photo captured on another device can reach
    // this device's form before its record does (photos and forms pull as
    // separate tables). Its link must survive a capture here.
    item.photoIds = (1 ... 9).map { "p\($0)" } + ["p_from_other_device"]
    let crowded = Presentation.photoSlots(item, existingPhotoIDs: Set((1 ... 9).map { "p\($0)" }))
    expect(crowded.isFull && crowded.remaining == 0, "nine shown plus one not synced yet: the item is full")
    var form = sample()
    form.items[4].photoIds = item.photoIds
    expectError(.tooManyPhotos, "the screen's room agrees with the domain: an eleventh link is refused") {
        try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p10")
    }
    expectEqual(form.items[4].photoIds?.last, "p_from_other_device", "the unsynced link is never detached automatically")
    let synced = Presentation.photoSlots(item, existingPhotoIDs: Set((1 ... 9).map { "p\($0)" } + ["p_from_other_device"]))
    expectEqual(synced.resolvedIDs.last, "p_from_other_device", "once its record syncs, the same link resolves in place")
    form = try NativeJobForms.removePhoto(form, itemID: "fi_5", photoID: "p_from_other_device")
    let freed = Presentation.photoSlots(form.items[4], existingPhotoIDs: Set((1 ... 9).map { "p\($0)" }))
    expectEqual(freed.remaining, 1, "the owner removing an unresolved link frees its place")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p10")
    expectEqual(form.items[4].photoIds?.count, 10, "and the domain accepts the new photo")

    item.photoIds = (1 ... 10).map { "p\($0)" }
    let full = Presentation.photoSlots(item, existingPhotoIDs: Set((1 ... 10).map { "p\($0)" }))
    expect(full.isFull && full.remaining == 0, "ten shown photos fill the item")
    item.photoIds = nil
    expectEqual(Presentation.photoSlots(item, existingPhotoIDs: []).remaining, 10, "no photos: ten slots")
    expectEqual(Presentation.photoAccessibilityLabel(index: 1, count: 3, itemLabel: "Panel", isAvailable: true),
                "Photo 2 of 3, Panel", "thumbnail label")
    expectEqual(Presentation.photoAccessibilityLabel(index: 0, count: 1, itemLabel: "Panel", isAvailable: false),
                "Photo 1 of 1, Panel, waiting for download", "a photo without bytes says so")
    expectEqual(Presentation.unresolvedPhotoAccessibilityLabel(index: 2, count: 3, itemLabel: "Panel"),
                "Photo 3 of 3, Panel, not on this device", "an unresolved link says so")
    expectEqual(Presentation.unresolvedPhotoTileText, "Not on this device", "the tile says it in text")
    expect(Presentation.photoActionMessage(isResolved: false, editable: true).contains("still be syncing")
           && Presentation.photoActionMessage(isResolved: false, editable: true).hasSuffix("frees its place."),
           "an unresolved link explains both causes and what removing it does")
    expect(!Presentation.photoActionMessage(isResolved: false, editable: false).contains("Removing"),
           "a read-only form offers no removal")
    expectEqual(Presentation.photoActionMessage(isResolved: true, editable: true),
                "Removing it from this item keeps it in the job's Photos section.", "a resolved photo")
    expectEqual(Presentation.photoActionMessage(isResolved: true, editable: false),
                "This form is complete and read-only.", "a resolved photo on a completed form")
}

// MARK: - Saving typed text (review fix 2026-10-03)

/// A stand-in for the store's text writes: applies the pure operation to
/// `stored` and refuses as the store does (a completed form is read-only).
final class FakeFormWriter {
    var stored: Canonical.Form?
    var refuseWith: NativeJobForms.FormError?
    var writes: [String] = []

    init(_ form: Canonical.Form?) { stored = form }

    func write(_ key: Presentation.DraftKey, _ value: String) -> Result<Canonical.Form, NativeJobForms.FormError> {
        writes.append("\(key.itemID)/\(key.field.rawValue)=\(value)")
        if let refuseWith { return .failure(refuseWith) }
        guard let form = stored else { return .failure(.notFound) }
        guard !form.isCompleted else { return .failure(.readOnlyCompleted) }
        do {
            let next = key.field == .answer
                ? try NativeJobForms.setText(form, itemID: key.itemID, value)
                : try NativeJobForms.setNote(form, itemID: key.itemID, value)
            stored = next
            return .success(next)
        } catch {
            return .failure((error as? NativeJobForms.FormError) ?? .notSaved)
        }
    }

    func commit(
        _ drafts: [Presentation.DraftKey: String],
        refusals: [Presentation.DraftKey: NativeJobForms.FormError] = [:],
        only keys: [Presentation.DraftKey]? = nil
    ) -> Presentation.DraftCommitOutcome {
        Presentation.commitDrafts(drafts, refusals: refusals, only: keys, form: stored) { write($0, $1) }
    }
}

let answer4 = Presentation.DraftKey(itemID: "fi_4", field: .answer)
let note2 = Presentation.DraftKey(itemID: "fi_2", field: .note)
let answer6 = Presentation.DraftKey(itemID: "fi_6", field: .answer)

run("presentation: a typed draft is cleared only once saved") {
    let writer = FakeFormWriter(sample())
    let saved = writer.commit([answer6: "later", answer4: "41 psi", note2: "loose"])
    expectEqual(writer.writes, ["fi_2/note=loose", "fi_4/answer=41 psi", "fi_6/answer=later"], "one write per changed draft, in form order")
    expect(saved.isAllSaved && saved.refusals.isEmpty && saved.dropped.isEmpty && saved.newProblem == nil, "saved drafts are cleared")
    expectEqual(writer.stored?.items[3].text, "41 psi", "the answer is stored")

    writer.writes = []
    let unchanged = writer.commit([answer4: "41 psi"])
    expect(unchanged.isAllSaved && writer.writes.isEmpty, "a draft that matches what is stored is cleared without a write")

    // Bug 4: another device completes the form while the owner types.
    writer.stored?.completedAt = "2026-10-03T16:00:00.000Z"
    let refused = writer.commit([answer4: "42 psi", note2: "tightened"])
    expectEqual(refused.drafts, [answer4: "42 psi", note2: "tightened"], "refused drafts keep the typed text")
    expectEqual(refused.refusals, [answer4: .readOnlyCompleted, note2: .readOnlyCompleted], "each with its reason")
    expectEqual(refused.newProblem, .readOnlyCompleted, "the refusal is reported")
    expect(!refused.isAllSaved, "not all saved")
    expectEqual(writer.stored?.items[3].text, "41 psi", "nothing was written")

    let again = writer.commit(refused.drafts, refusals: refused.refusals)
    expectEqual(again.drafts, refused.drafts, "a retry that is refused again still keeps the text")
    expectEqual(again.newProblem, nil, "the same refusal is not announced twice")
    writer.refuseWith = .notSaved
    let other = writer.commit(again.drafts, refusals: again.refusals)
    expectEqual(other.newProblem, .notSaved, "a new reason is announced")
    expectEqual(other.refusals[answer4], .notSaved, "and replaces the old one")
    writer.refuseWith = nil

    // Reopen, then the kept text saves.
    writer.stored?.completedAt = nil
    let reopened = writer.commit(other.drafts, refusals: other.refusals)
    expect(reopened.isAllSaved && reopened.refusals.isEmpty && reopened.newProblem == nil, "after reopening, the kept text saves")
    expectEqual(writer.stored?.items[3].text, "42 psi", "the typed answer is stored")
    expectEqual(writer.stored?.items[1].note, "tightened", "the typed note is stored")
}

run("presentation: one field commits alone; gone items are dropped and reported") {
    let writer = FakeFormWriter(sample())
    writer.refuseWith = .jobNotFound
    let first = writer.commit([answer4: "41 psi", answer6: "x"], only: [answer4])
    expectEqual(writer.writes, ["fi_4/answer=41 psi"], "only the field that ended editing is written")
    expectEqual(first.drafts, [answer4: "41 psi", answer6: "x"], "the other draft is untouched")
    expectEqual(first.refusals, [answer4: .jobNotFound], "only the attempted field has a reason")
    writer.refuseWith = nil
    let second = writer.commit(first.drafts, refusals: first.refusals, only: [answer6])
    expectEqual(second.drafts, [answer4: "41 psi"], "the saved field is cleared, the refused one kept")
    expectEqual(second.refusals, [answer4: .jobNotFound], "a field not attempted keeps its reason")
    expectEqual(second.newProblem, nil, "nothing new to say")

    let gone = Presentation.DraftKey(itemID: "fi_99", field: .note)
    let dropped = writer.commit([gone: "orphan", answer4: "41 psi"])
    expectEqual(dropped.dropped, [gone], "a draft whose item is gone is dropped")
    expect(dropped.isAllSaved && dropped.drafts[gone] == nil, "it is not kept, since nothing can take it")
    expectEqual(dropped.newProblem, .itemNotFound("fi_99"), "and the owner is told")
    expectEqual(Presentation.message(for: dropped.newProblem!), "That item is no longer on this form.", "in words")

    let noForm = Presentation.commitDrafts([answer4: "x"], form: nil) { _, _ in .failure(.notSaved) }
    expect(noForm.isAllSaved && noForm.dropped == [answer4] && noForm.newProblem == .notFound, "a form that is gone takes nothing")
    let stale = Presentation.commitDrafts([:], refusals: [answer4: .notSaved], form: sample()) { _, _ in .failure(.notSaved) }
    expect(stale.refusals.isEmpty, "a reason without a draft is dropped")
}

run("presentation: unsaved text notices") {
    expectEqual(Presentation.unsavedFieldText(.readOnlyCompleted),
                "Not saved. This form is complete. Reopen it to make changes.", "the field marker says why")
    expectEqual(Presentation.unsavedTextTitle, "Text not saved", "notice title")
    let one = Presentation.unsavedOnCloseMessage(count: 1, reason: .readOnlyCompleted)
    expect(one.hasPrefix("1 answer or note isn't saved. This form is complete.") && one.contains("Close keeps the text"),
           "Done with one unsaved field says what Close does")
    expect(Presentation.unsavedOnCloseMessage(count: 3, reason: nil).hasPrefix("3 answers or notes aren't saved. Close"), "plural")
    expectEqual(Presentation.firstRefusal([answer6: .notSaved, note2: .readOnlyCompleted], form: sample()), .readOnlyCompleted,
                "the first refusal is in form order")
    expectEqual(Presentation.firstRefusal([:], form: sample()), nil, "no refusals")

    var form = sample()
    form = try NativeJobForms.setText(form, itemID: "fi_4", "41 psi")
    let held: [Presentation.DraftKey: String] = [
        answer4: "42 psi", note2: "tightened", answer6: "", .init(itemID: "fi_99", field: .answer): "gone",
    ]
    let restoration = Presentation.draftRestoration(
        drafts: held, refusals: [answer4: .readOnlyCompleted, note2: .readOnlyCompleted, answer6: .notSaved], form: form
    )
    expectEqual(restoration.drafts, [answer4: "42 psi", note2: "tightened"],
                "held text comes back only where it still differs and its item exists")
    expectEqual(restoration.refusals, [answer4: .readOnlyCompleted, note2: .readOnlyCompleted], "with its reasons")
    expectEqual(restoration.message,
                "2 answers or notes weren't saved when this form was closed. They're back in their fields, marked Not saved. This form is complete. Reopen it to make changes.",
                "the restore notice")
    let single = Presentation.draftRestoration(drafts: [note2: "x"], refusals: [:], form: form)
    expectEqual(single.message, "1 answer or note wasn't saved when this form was closed. It's back in its field, marked Not saved.",
                "singular, no reason")
    let nothing = Presentation.draftRestoration(drafts: [answer4: "41 psi"], refusals: [:], form: form)
    expect(nothing.drafts.isEmpty && nothing.message == nil, "text that now matches what is stored needs no notice")
    expect(Presentation.draftRestoration(drafts: held, refusals: [:], form: nil).message == nil, "a form that is gone restores nothing")

    expect(Presentation.HeldText().isEmpty, "nothing held")
    expect(!Presentation.HeldText(drafts: [answer4: ""]).isEmpty && !Presentation.HeldText(title: "T").isEmpty, "drafts or a title")
}

run("presentation: the editor's title is cleared only once saved") {
    var writes: [String] = []
    func succeed(_ title: String) -> Result<Canonical.Form, NativeJobForms.FormError> { writes.append(title); return .success(sample()) }
    func refuse(_ error: NativeJobForms.FormError) -> (String) -> Result<Canonical.Form, NativeJobForms.FormError> {
        { writes.append($0); return .failure(error) }
    }
    expectEqual(Presentation.commitTitle(nil, refusal: nil, stored: "Sample", write: succeed),
                .init(draft: nil, refusal: nil, newProblem: nil), "no draft, no write")
    expectEqual(Presentation.commitTitle(" Sample ", refusal: nil, stored: "Sample", write: succeed),
                .init(draft: nil, refusal: nil, newProblem: nil), "a title that matches once trimmed is cleared")
    expect(writes.isEmpty, "without a write")
    expectEqual(Presentation.commitTitle("Panel check", refusal: .notSaved, stored: "Sample", write: succeed),
                .init(draft: nil, refusal: nil, newProblem: nil), "a saved title is cleared with its old reason")
    expectEqual(writes, ["Panel check"], "one write")
    let refused = Presentation.commitTitle("Panel check", refusal: nil, stored: "Sample", write: refuse(.readOnlyCompleted))
    expectEqual(refused, .init(draft: "Panel check", refusal: .readOnlyCompleted, newProblem: .readOnlyCompleted),
                "a refused title keeps the typed text and reports why")
    expectEqual(Presentation.commitTitle("Panel check", refusal: .readOnlyCompleted, stored: "Sample", write: refuse(.readOnlyCompleted)).newProblem,
                nil, "the same refusal is not announced twice")
    expectEqual(Presentation.commitTitle("Panel check", refusal: nil, stored: nil, write: succeed).draft, nil,
                "a form that is gone takes nothing")
    expectEqual(Presentation.titleToHold("Panel check"), "Panel check", "a closing editor holds a typed title")
    expectEqual(Presentation.titleToHold("   "), nil, "a blank title is never held: the stored title stays")
    expectEqual(Presentation.titleToHold(nil), nil, "nothing typed")
    expectEqual(Presentation.restoredTitle("Panel check", stored: "Sample"), "Panel check", "a held title comes back")
    expectEqual(Presentation.restoredTitle("Panel check", stored: "Panel check"), nil, "unless the form already has it")
    expectEqual(Presentation.restoredTitle("Panel check", stored: nil), nil, "or the form is gone")
    expect(Presentation.restoredTitleMessage(reason: .readOnlyCompleted).hasSuffix("Reopen it to make changes."),
           "the restore notice says why")
}

run("presentation: completion refusal messages") {
    let missing = NativeJobForms.missingItems(sample(), existingPhotoIDs: [])
    let byItem = Presentation.missingByItem(missing)
    expectEqual(byItem["fi_2"], "Not checked", "a row's missing reason")
    expectEqual(byItem["fi_5"], "Needs a photo", "a photo reason")
    expectEqual(byItem["fi_7"], nil, "an unknown kind never blocks")
    expectEqual(Presentation.incompleteMessage(missing),
                "4 items still need attention:\n• Ticked: Not checked\n• Tested: Needs Pass, Fail or N/A\n• Reading: Needs an answer\n• Photo: Needs a photo",
                "every missing item, typed, in form order")
    expectEqual(Presentation.incompleteMessage(Array(missing.prefix(1))), "1 item still needs attention:\n• Ticked: Not checked",
                "singular")
    let capped = Presentation.incompleteMessage(missing, limit: 2)
    expect(capped.hasSuffix("… and 2 more, marked in the list."), "a long list is capped and points at the rows")
    expectEqual(capped.components(separatedBy: "\n").count, 4, "head, two lines and the rest")
    expectEqual(Presentation.incompleteMessage([]), "Every required item is answered.", "nothing missing")
    expect(Presentation.incompleteTitle.contains("complete"), "refusal title")
}

run("presentation: every error has a text message") {
    let errors: [NativeJobForms.FormError] = [
        .notFound, .jobNotFound, .notAnInstance, .notATemplate, .readOnlyCompleted, .notCompleted,
        .unknownTemplate("builtin:x"), .templateArchived, .invalidTitle, .invalidItemCount, .invalidLabel,
        .textTooLong, .noteTooLong, .tooManyPhotos, .itemNotFound("fi_1"), .itemNotAnswerable("fi_1"),
        .wrongItemKind("fi_1"), .duplicateItemID("fi_1"), .invalidItemID, .invalidFormID, .invalidPhotoID,
        .invalidOrder, .invalidKind, .missingJob, .duplicateFormID, .notSaved,
        .incomplete([.init(itemID: "fi_2", label: "Ticked", reasons: [.notChecked])]),
    ]
    for error in errors {
        let message = Presentation.message(for: error)
        expect(!message.isEmpty && message.hasSuffix(".") || message.contains("•"), "\(error): a sentence")
        expect(!message.contains("fi_") && !message.contains("builtin:"), "\(error): no internal ids in the message")
    }
    expectEqual(Presentation.message(for: .readOnlyCompleted), "This form is complete. Reopen it to make changes.", "read-only")
    expectEqual(Presentation.message(for: .tooManyPhotos), "An item can hold up to 10 photos.", "photo cap")
    expectEqual(Presentation.message(for: .invalidTitle), "Enter a title of up to 80 characters.", "title cap")
    expect(Presentation.message(for: .invalidItemCount).contains("100"), "item cap")
    expect(Presentation.message(for: .notSaved).contains("Nothing was changed"), "a failed save says nothing changed")
    expect(Presentation.message(for: .incomplete([.init(itemID: "fi_2", label: "Ticked", reasons: [.notChecked])]))
           .contains("• Ticked: Not checked"), "incomplete lists the item")
}

run("presentation: item drafts and editor caps") {
    var draft = Presentation.ItemDraft()
    expectEqual(draft.kind, .check, "a new item starts as a checkbox")
    expectEqual(draft.validationMessage, "Enter a label.", "a blank label cannot save")
    draft.label = "   "
    expect(!draft.isValid, "whitespace is blank")
    draft.label = "  Filter replaced  "
    expect(draft.isValid && draft.trimmedLabel == "Filter replaced", "trimmed label saves")
    draft.label = String(repeating: "x", count: 201)
    expect(!draft.isValid && draft.validationMessage?.contains("200") == true, "a long label cannot save")
    draft = .init(kind: .section, label: "Outdoor", required: true, photoRequired: true)
    expect(!draft.effectiveRequired && !draft.effectivePhotoRequired, "a heading takes no flags")
    draft.kind = .passFail
    expect(draft.effectiveRequired && draft.effectivePhotoRequired, "answerable kinds keep the flags")
    let items = sample().items
    expectEqual(Presentation.itemDraft(for: items[1]), .init(kind: .check, label: "Ticked", required: true, photoRequired: false),
                "edit draft from an item")
    expectEqual(Presentation.itemDraft(for: items[6]), nil, "an unknown kind is not edited")

    var form = sample()
    expectEqual(Presentation.itemCapText(form), "7 of 100 items", "cap text")
    expect(Presentation.canAddItem(form) && Presentation.canDeleteItem(form), "room to add and delete")
    form.items = (1 ... 100).map { .init(id: "fi_\($0)", kind: "check", label: "Item \($0)") }
    expect(!Presentation.canAddItem(form), "100 items: no more")
    form.items = [.init(id: "fi_1", kind: "check", label: "Only")]
    expect(!Presentation.canDeleteItem(form), "the last item stays")
    var completed = sample(); completed.completedAt = "2026-10-02T17:00:00.000Z"
    expect(!Presentation.canAddItem(completed) && !Presentation.canDeleteItem(completed), "a completed form is not edited")
    var template = sample(); template.kind = "template"; template.completedAt = "2026-10-02T17:00:00.000Z"
    expect(Presentation.canAddItem(template), "a template is always editable")
    expectEqual(Presentation.itemCountLabel(1), "1 item", "singular count")
    expectEqual(Presentation.itemCountLabel(12), "12 items", "plural count")
    let entry = NativeJobForms.PickerEntry(ref: .builtin("site-safety"), title: "Site safety checklist", itemCount: 9)
    expectEqual(Presentation.pickerEntryAccessibilityLabel(entry), "Site safety checklist, 9 items", "picker row label")
    var long = sample(); long.title = String(repeating: "T", count: 80)
    expectEqual(Presentation.defaultTemplateTitle(long).count, 80, "template title starts as the form title")
    let saved = try NativeJobForms.makeTemplate(from: sample(), templateID: "fm9_tpl", title: "Mine", now: now)
    expect(Presentation.templateSavedMessage(saved).contains("\"Mine\"")
           && Presentation.templateSavedMessage(saved).contains("Settings › Forms & checklists"), "saved notice names the template and where it lives")
}

// MARK: - PDF document model (N/NativeFormPDF.swift)

func pdfDocument(
    _ form: Canonical.Form,
    photos: [Canonical.JobPhoto] = [],
    available: Set<String> = []
) -> NativeFormPDFDocument {
    NativeFormPDFDocument(
        form: form, jobTitle: " Panel upgrade ", customerName: "Pat O'Brien", jobAddress: "10 Main St",
        businessName: " Rector Electric ", businessContactName: "Chad", businessPhone: "555-0100",
        businessEmail: "hello@example.test", businessAddress: "20 Trade Ave",
        jobPhotos: photos, availablePhotoIDs: available, calendar: phoenix
    )
}

run("pdf: header, status and progress") {
    var form = sample()
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", true)
    let open = pdfDocument(form)
    expectEqual(open.businessName, "Rector Electric", "business name trimmed")
    expectEqual(open.jobTitle, "Panel upgrade", "job title trimmed")
    expectEqual(open.customerName, "Pat O'Brien", "customer")
    expectEqual(open.jobAddress, "10 Main St", "address")
    expectEqual(open.formTitle, "Sample", "form title")
    expectEqual(open.statusText, "In progress", "an open form says In progress")
    expectEqual(open.progressText, "1 of 5 answered", "progress")
    form.completedAt = "2025-10-03T03:00:00.000Z"
    expectEqual(pdfDocument(form).statusText, "Completed Oct 2, 2025", "the completed date in the owner's time zone")
}

run("pdf: sections and answered/unanswered text") {
    let blank = pdfDocument(sample())
    expectEqual(blank.sections.map(\.title), ["Start"], "one section")
    let rows = blank.sections[0].rows
    expectEqual(rows.map(\.itemID), ["fi_2", "fi_3", "fi_4", "fi_5", "fi_6"], "answerable items only; the unknown kind is left out")
    expectEqual(rows.map(\.badge), [.notChecked, .noResult, nil, .notChecked, nil], "unanswered badges")
    expectEqual(rows.map(\.answer), ["", "", "No answer", "", "No answer"], "unanswered text items say No answer")
    expect(rows.allSatisfy { !$0.isAnswered && $0.note.isEmpty && $0.photos.isEmpty }, "nothing answered yet")

    var form = sample()
    form = try NativeJobForms.setChecked(form, itemID: "fi_2", true)
    form = try NativeJobForms.setResult(form, itemID: "fi_3", .fail)
    form = try NativeJobForms.setText(form, itemID: "fi_4", "  41 psi \n")
    form = try NativeJobForms.setNote(form, itemID: "fi_3", "  Loose lug at slot 4  ")
    form = try NativeJobForms.setText(form, itemID: "fi_6", "   ")
    let answered = pdfDocument(form).sections[0].rows
    expectEqual(answered.map(\.badge), [.checked, .fail, nil, .notChecked, nil], "answered badges")
    expectEqual(answered[2].answer, "41 psi", "a text answer is trimmed")
    expect(answered[2].isAnswered, "the text item is answered")
    expectEqual(answered[4].answer, "No answer", "a blank answer reads as unanswered")
    expect(!answered[4].isAnswered, "and is not answered")
    expectEqual(answered[1].note, "Loose lug at slot 4", "the note is trimmed")
    for result in NativeJobForms.PassFailResult.allCases {
        let set = try NativeJobForms.setResult(sample(), itemID: "fi_3", result)
        let badge = pdfDocument(set).sections[0].rows[1].badge
        expectEqual(badge?.label, result == .na ? "N/A" : result.rawValue.uppercased(), "\(result) badge text")
    }

    let mixed = Canonical.Form(
        id: formID, kind: "instance", jobId: jobID, title: "Mixed",
        items: [
            .init(id: "fi_1", kind: "text", label: "Before any heading", text: "first"),
            .init(id: "fi_2", kind: "section", label: "Only future"),
            .init(id: "fi_3", kind: "signature", label: "Future"),
            .init(id: "fi_4", kind: "section", label: "Outside"),
            .init(id: "fi_5", kind: "passFail", label: "Unit", result: "pass"),
        ],
        createdAt: "2026-10-02T16:00:00.000Z"
    )
    let sections = pdfDocument(mixed).sections
    expectEqual(sections.map(\.title), ["", "Outside"], "untitled lead section; a heading with only unknown items is dropped")
    expectEqual(sections.map { $0.rows.map(\.itemID) }, [["fi_1"], ["fi_5"]], "rows by section")
}

run("pdf: badges are text with a palette tone") {
    let all: [NativeFormPDFBadge] = [.pass, .fail, .na, .checked, .notChecked, .noResult]
    expectEqual(all.map(\.label), ["PASS", "FAIL", "N/A", "CHECKED", "NOT CHECKED", "NO RESULT"], "badge labels")
    expectEqual(Set(all.map(\.label)).count, all.count, "every badge reads differently without color")
    expectEqual(all.map(\.tone), [.success, .danger, .neutral, .success, .neutral, .neutral], "badge tones")
}

run("pdf: photo resolution") {
    var form = sample()
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p_here")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p_gone")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p_remote")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_5", photoID: "p_other_job")
    form = try NativeJobForms.addPhoto(form, itemID: "fi_2", photoID: "p_first")
    form.items[4].photoIds?.append("p_here")
    let photos = [try jobPhoto("p_here"), try jobPhoto("p_remote"), try jobPhoto("p_first"),
                  try jobPhoto("p_other_job", job: "job-2")]
    let document = pdfDocument(form, photos: photos, available: ["p_here", "p_first", "p_other_job"])
    let rows = document.sections[0].rows
    expectEqual(rows[3].photos, [.init(id: "p_here", isAvailable: true), .init(id: "p_remote", isAvailable: false)],
                "deleted and other-job ids are left out, a duplicate once; a photo without bytes is a placeholder")
    expectEqual(rows[0].photos, [.init(id: "p_first", isAvailable: true)], "a check item's photo")
    expectEqual(document.photoIDs, ["p_first", "p_here", "p_remote"], "every drawn photo, in document order")
    expect(NativeFormPDFDocument.photoUnavailableText == "Photo not available on this device", "placeholder text (spec §5)")
}

// MARK: - PDF photo downscaling (review fix 2026-10-03)

struct ImageFixtureError: Error {}

let imageFixtureDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("tradeready-job-forms-images-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

/// A JPEG of `width`×`height` stored pixels with an EXIF orientation, drawn
/// with a gradient so it compresses like a photo rather than a flat fill.
func writeJPEG(_ name: String, width: Int, height: Int, orientation: Int = 1) throws -> URL {
    try FileManager.default.createDirectory(at: imageFixtureDirectory, withIntermediateDirectories: true)
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw ImageFixtureError() }
    for x in stride(from: 0, to: width, by: 8) {
        let shade = CGFloat(x % 256) / 255
        context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: CGFloat((x * 7) % 256) / 255, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 8, height: height))
    }
    guard let image = context.makeImage() else { throw ImageFixtureError() }
    let url = imageFixtureDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw ImageFixtureError()
    }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImagePropertyOrientation: orientation,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError() }
    return url
}

run("pdf: photos are read from their files and downscaled one at a time") {
    defer { try? FileManager.default.removeItem(at: imageFixtureDirectory) }
    expectEqual(NativeFormPDFPhotoScaling.maxPixelSize, 320, "160 pt at 2x (spec §5)")
    expectEqual(NativeFormPDFPhotoScaling.jpegQuality, 0.7, "the PDF's JPEG quality is unchanged")

    let landscape = try writeJPEG("landscape.jpg", width: 3_000, height: 2_000)
    guard let thumbnail = NativeFormPDFPhotoScaling.thumbnail(at: landscape) else {
        expect(false, "a photo file downscales")
        return
    }
    expectEqual([thumbnail.width, thumbnail.height], [320, 213], "the longest side is capped at 320 px, aspect kept")

    // EXIF orientation 6: stored landscape, shown portrait.
    let rotated = try writeJPEG("rotated.jpg", width: 3_000, height: 2_000, orientation: 6)
    let upright = NativeFormPDFPhotoScaling.thumbnail(at: rotated)
    expectEqual(upright.map { [$0.width, $0.height] }, [213, 320], "the photo's orientation is applied")

    let small = try writeJPEG("small.jpg", width: 120, height: 90)
    let unscaled = NativeFormPDFPhotoScaling.thumbnail(at: small)
    expect(unscaled.map { max($0.width, $0.height) <= 320 } == true, "a small photo stays within the cap")

    guard let jpeg = NativeFormPDFPhotoScaling.jpegData(thumbnail) else {
        expect(false, "the thumbnail recompresses as JPEG")
        return
    }
    expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]), "the recompressed photo is a JPEG")
    let source = try Data(contentsOf: landscape)
    expect(jpeg.count * 4 < source.count, "and far smaller than the full-size file (\(jpeg.count) vs \(source.count) bytes)")
    let decoded = CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    expectEqual(decoded.map { [$0.width, $0.height] }, [320, 213], "it decodes at the downscaled size")

    let missing = imageFixtureDirectory.appendingPathComponent("missing.jpg")
    expect(NativeFormPDFPhotoScaling.thumbnail(at: missing) == nil, "a missing file draws the placeholder")
    let text = imageFixtureDirectory.appendingPathComponent("not-an-image.jpg")
    try Data("not an image".utf8).write(to: text)
    expect(NativeFormPDFPhotoScaling.thumbnail(at: text) == nil, "a file that is not an image draws the placeholder")
}

run("pdf: filename") {
    expectEqual(pdfDocument(try instance()).filename, "Form-Electrical-safety-inspection-Pat-O-Brien.pdf",
                "Form-<title>-<customer>.pdf in ASCII letters and digits")
    var accented = sample(); accented.title = "Café / bâtiment №5"
    expectEqual(NativeFormPDFDocument(
        form: accented, jobTitle: "", customerName: "", jobAddress: "", businessName: "", businessContactName: "",
        businessPhone: "", businessEmail: "", businessAddress: "", jobPhotos: [], availablePhotoIDs: []
    ).filename, "Form-Caf-b-timent-5.pdf", "non-ASCII characters separate words")
    var symbols = sample(); symbols.title = "!!!"
    expectEqual(NativeFormPDFDocument(
        form: symbols, jobTitle: "", customerName: " ", jobAddress: "", businessName: "", businessContactName: "",
        businessPhone: "", businessEmail: "", businessAddress: "", jobPhotos: [], availablePhotoIDs: []
    ).filename, "Form.pdf", "nothing usable: Form.pdf")
    expectEqual(NativeFormPDFDocument.filenameComponent(String(repeating: "a", count: 90)).count, 60, "components stop at 60")
}

run("pdf: every built-in renders every answerable item") {
    for template in NativeJobForms.builtinTemplates {
        let form = try NativeJobForms.instantiate(.builtin(template.key), customTemplates: [], jobID: jobID, formID: formID, now: now)
        let document = pdfDocument(form)
        let rows = document.sections.flatMap(\.rows)
        expectEqual(rows.count, template.items.filter { $0.kind.isAnswerable }.count, "\(template.key): one row per answerable item")
        expectEqual(document.sections.map(\.title), template.items.filter { $0.kind == .section }.map(\.label),
                    "\(template.key): one section per heading")
        expect(rows.allSatisfy { $0.badge != nil || $0.answer == NativeFormPDFDocument.unansweredText },
               "\(template.key): every row shows a badge or the unanswered text")
    }
}

if failures == 0 {
    print("PASS: job forms domain, screen state and PDF document tests (\(checks) checks)")
} else {
    print("FAILED: \(failures) of \(checks) job forms checks")
    exit(1)
}
