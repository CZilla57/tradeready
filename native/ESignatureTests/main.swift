import Foundation

// Phase 19 (e-signatures with audit trail, spec 2026-10-03 §3.4, §3.7, §6
// "Native", build record §11.1): the snapshot additions and their caps, the
// settings round trip, approval decode with and without the server-owned
// keys, stroke scaling, audit-trail ordering, the legacy and on-site labels,
// the signed-record transport, the copy rules, and the AppStore wiring —
// the review draft, the create-link payload (Phase 25 options and Phase 32
// dates intact), change orders and the owner's signed copy. The estimate
// PDF's terms are covered in `native/EstimatePDFTests/main.swift`.
// Run with TZ=America/Phoenix.

// MARK: - Harness

@MainActor var failures = 0
@MainActor var checks = 0

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func json<T: Encodable>(_ value: T) throws -> [String: Canonical.JSONValue] {
    let decoded = try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(value))
    guard case let .object(fields) = decoded else { return [:] }
    return fields
}

func sortedJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "unencodable"
}

func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

let phoenix = TimeZone(identifier: "America/Phoenix")!
let enUS = Locale(identifier: "en_US_POSIX")

let baseSnapshotJSON = """
{"businessName":"Ada Electric","customerName":"Pat Lee","jobTitle":"Panel upgrade",
 "lineItems":[{"label":"Labor","amount":300}],"total":300,"currency":"USD",
 "validUntil":"2026-11-02","validUntilTimeZone":"America/Phoenix"}
"""

func inputs(
    terms: String = "50% deposit before work starts.",
    phone: String = "555-0100",
    email: String = "ada@example.test",
    drawPad: Bool = true,
    timeZone: String? = "America/Phoenix"
) -> NativeESignature.SnapshotInputs {
    .init(terms: terms, businessPhone: phone, businessEmail: email, drawPad: drawPad, timeZone: timeZone)
}

// MARK: - 1. Snapshot additions and caps (§3.4, §11.1 A)

@MainActor
func testSnapshotAdditions() throws {
    let base = try decode(Canonical.EstimateApprovalSnapshot.self, baseSnapshotJSON)
    let built = try NativeESignature.addingSnapshotFields(
        to: base,
        scope: "  Replace the 100A panel with a 200A panel.\n",
        inputs: inputs(terms: "  50% deposit before work starts.  "),
        kind: .estimate
    )
    let fields = try json(built)
    expectEqual(fields["scope"], .string("Replace the 100A panel with a 200A panel."), "additions: scope is the trimmed description")
    expectEqual(fields["terms"], .string("50% deposit before work starts."), "additions: terms are trimmed")
    expectEqual(fields["businessContact"], .object(["phone": .string("555-0100"), "email": .string("ada@example.test")]),
                "additions: businessContact carries phone and email")
    expectEqual(fields["signature"], .object(["drawPad": .bool(true)]), "additions: signature.drawPad is explicit")
    expectEqual(fields["esign"], .object(["version": .number(1), "timeZone": .string("America/Phoenix")]),
                "additions: esign {version: 1, timeZone}")
    expectEqual(fields["validUntil"], .string("2026-11-02"), "additions: the Phase 32 date is untouched")
    expectEqual(fields["validUntilTimeZone"], .string("America/Phoenix"), "additions: and its zone")
    expectEqual(fields["total"], .number(300), "additions: the total is untouched")
    expect(!fields.values.contains(.null), "additions: nothing is sent as null")

    // Empty values are omitted, never "" (§11.1 A).
    let sparse = try NativeESignature.addingSnapshotFields(
        to: base, scope: "   ", inputs: inputs(terms: " ", phone: "", email: "  ", drawPad: false, timeZone: nil), kind: .estimate
    )
    let sparseFields = try json(sparse)
    expect(sparseFields["scope"] == nil && sparseFields["terms"] == nil && sparseFields["businessContact"] == nil,
           "additions: empty scope, terms and contact are omitted")
    expectEqual(sparseFields["signature"], .object(["drawPad": .bool(false)]), "additions: the pad off is sent as false")
    expectEqual(sparseFields["esign"], .object(["version": .number(1)]), "additions: no zone, no timeZone key")
    let phoneOnly = try NativeESignature.addingSnapshotFields(
        to: base, scope: nil, inputs: inputs(email: ""), kind: .estimate
    )
    expectEqual(try json(phoneOnly)["businessContact"], .object(["phone": .string("555-0100")]),
                "additions: an empty email member is omitted")
    let badZone = try NativeESignature.addingSnapshotFields(
        to: base, scope: nil, inputs: inputs(timeZone: "Mars/Olympus_Mons"), kind: .estimate
    )
    expect(badZone.esign?.timeZone == nil && badZone.esign?.version == 1, "additions: an unknown zone is omitted, not sent")

    // A change order carries its own description and no terms.
    let changeOrder = try NativeESignature.addingSnapshotFields(
        to: base, scope: "Add a sub-panel in the garage.", inputs: inputs(), kind: .changeOrder
    )
    expectEqual(changeOrder.scope, "Add a sub-panel in the garage.", "additions: a change order's scope is its description")
    expect(changeOrder.terms == nil, "additions: a change order carries no terms")
    expect(changeOrder.businessContact != nil && changeOrder.esign != nil, "additions: but the contact and esign keys")

    // Caps, in UTF-16 units like the Worker's `String.length`.
    let emoji = "🔌" // 2 UTF-16 units
    expect((try? NativeESignature.addingSnapshotFields(
        to: base, scope: String(repeating: emoji, count: 2_000), inputs: inputs(), kind: .estimate
    )) != nil, "caps: a 4,000-unit scope is accepted")
    do {
        _ = try NativeESignature.addingSnapshotFields(
            to: base, scope: String(repeating: emoji, count: 2_000) + "a", inputs: inputs(), kind: .estimate
        )
        expect(false, "caps: a 4,001-unit scope is refused")
    } catch let error as NativeESignature.SnapshotError {
        expectEqual(error, .scopeTooLong(.estimate), "caps: scopeTooLong(estimate)")
        expect(error.errorDescription?.contains("job description") == true, "caps: the estimate message names the job description")
    }
    do {
        _ = try NativeESignature.snapshotFields(
            scope: String(repeating: "x", count: 4_001), inputs: inputs(), kind: .changeOrder
        )
        expect(false, "caps: a long change-order description is refused")
    } catch let error as NativeESignature.SnapshotError {
        expectEqual(error, .scopeTooLong(.changeOrder), "caps: scopeTooLong(changeOrder)")
    }
    expect((try? NativeESignature.snapshotFields(
        scope: nil, inputs: inputs(terms: String(repeating: "t", count: 4_000)), kind: .estimate
    )) != nil, "caps: 4,000 characters of terms are accepted")
    expectEqual(errorOf { try NativeESignature.snapshotFields(
        scope: nil, inputs: inputs(terms: String(repeating: "t", count: 4_001)), kind: .estimate
    ) }, .termsTooLong, "caps: 4,001 characters of terms are refused")
    expect((try? NativeESignature.snapshotFields(
        scope: nil, inputs: inputs(terms: String(repeating: "t", count: 4_001)), kind: .changeOrder
    )) != nil, "caps: a change order ignores the terms, so their length")
    expect((try? NativeESignature.snapshotFields(
        scope: nil, inputs: inputs(phone: String(repeating: "5", count: 40)), kind: .estimate
    )) != nil, "caps: a 40-character phone is accepted")
    expectEqual(errorOf { try NativeESignature.snapshotFields(
        scope: nil, inputs: inputs(phone: String(repeating: "5", count: 41)), kind: .estimate
    ) }, .businessPhoneTooLong, "caps: a 41-character phone is refused")
    expectEqual(errorOf { try NativeESignature.snapshotFields(
        scope: nil, inputs: inputs(email: "ada at example"), kind: .estimate
    ) }, .businessEmailInvalid, "caps: a malformed business email is refused")

    // The Worker's email rule.
    for good in ["ada@example.test", "a.b+c@sub.example.co", "o'brien@example.ie"] {
        expect(NativeESignature.isEmailAddress(good), "email: \(good) is accepted")
    }
    for bad in ["ada@example", "@example.test", "ada@@example.test", "ada example@x.test", "ada@ex,ample.test",
                "<ada@example.test>", "ada@example.test\u{0007}", "a@[x].test",
                String(repeating: "a", count: 245) + "@example.test"] {
        expect(!NativeESignature.isEmailAddress(bad), "email: \(bad.prefix(40)) is refused")
    }
}

@MainActor
func errorOf(_ body: () throws -> Any) -> NativeESignature.SnapshotError? {
    do { _ = try body(); return nil } catch { return error as? NativeESignature.SnapshotError }
}

/// The additions sit beside the Phase 25 options and the Phase 32 date the
/// existing builder froze, and survive a wire round trip.
@MainActor
func testAdditionsKeepOptionsAndValidity() throws {
    let job = try decode(Canonical.Job.self, """
    {"id":"job-options","customerId":"c1","customerName":"Pat Lee","title":"Water heater","description":"Swap the 40-gal tank.","status":"lead","scheduledDate":null,"scheduledStartTime":null,"scheduledEndTime":null,"address":"","estimateTotal":1800,"laborHours":4,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"notes":"","invoiceId":null,"createdAt":"2026-07-01",
     "quoteOptions":{"tiers":[
       {"id":"qt_good","name":"Repair","laborHours":2,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"estimateTotal":450},
       {"id":"qt_better","name":"Standard unit","laborHours":4,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"estimateTotal":1800}
     ],"addOns":[{"id":"qa_haul","label":"Haul-away","price":150,"cost":37.25}],"recommendedTierId":"qt_better"}}
    """)
    let base = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: job, customerName: nil, businessName: "Ada Electric",
        validUntil: "2026-11-02", validUntilTimeZone: "America/Phoenix"
    )
    let built = try NativeESignature.addingSnapshotFields(to: base, scope: job.description, inputs: inputs(), kind: .estimate)
    expect(built.options == base.options && built.options?.tiers.count == 2, "options: the Phase 25 tiers are untouched")
    expect(built.lineItems == base.lineItems && built.total == base.total, "options: the recommended lines and total are untouched")
    expect(built.validUntil == "2026-11-02" && built.validUntilTimeZone == "America/Phoenix", "options: the Phase 32 date is untouched")
    expectEqual(built.scope, "Swap the 40-gal tank.", "options: scope is the job description")
    let wire = try json(built)
    expect(wire["options"] != nil && wire["esign"] != nil && wire["terms"] != nil, "options: the wire carries both")

    // Decode → encode is byte-stable, and an unknown key inside `esign`
    // (a newer writer) is preserved.
    var raw = wire
    raw["esign"] = .object(["version": .number(1), "timeZone": .string("America/Phoenix"), "futureKey": .bool(true)])
    let reread = try JSONDecoder().decode(Canonical.EstimateApprovalSnapshot.self, from: JSONEncoder().encode(raw))
    expect(reread.esign?.preservation.unknownFields["futureKey"] == .bool(true), "round trip: an unknown esign key is preserved")
    expect(reread.preservation.unknownFields["scope"] == nil && reread.preservation.unknownFields["esign"] == nil,
           "round trip: the additions decode as typed fields")
    expectEqual(sortedJSON(reread), sortedJSON(Canonical.JSONValue.object(raw)), "round trip: byte-stable")

    // Snapshot equality (the sync-before-mint and declined guards).
    var otherTerms = built
    otherTerms.terms = "Net 30."
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherTerms), "match: different terms differ")
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherTerms, ignoringValidity: true),
           "match: terms are not validity")
    var otherScope = built
    otherScope.scope = "Something else."
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherScope, ignoringValidity: true),
           "match: the scope is what is signed")
    var otherPad = built
    otherPad.signature = .init(drawPad: false)
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherPad), "match: the pad setting differs")
    var otherContact = built
    otherContact.businessContact = .init(phone: "555-0199", email: "ada@example.test")
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherContact), "match: the contact differs")
    var otherZone = built
    otherZone.esign?.timeZone = "America/Denver"
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherZone), "match: the certificate zone compares exactly")
    expect(CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, otherZone, ignoringValidity: true),
           "match: ignoringValidity ignores the zone, like validUntilTimeZone")
    var noESign = built
    noESign.esign = nil
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, noESign, ignoringValidity: true),
           "match: an e-signed snapshot is not a legacy one")
    expect(CanonicalUIAdapters.estimateApprovalSnapshotsMatch(built, built), "match: identical snapshots match")
}

// MARK: - 2. Settings round trip (§3.7)

@MainActor
func testSettingsRoundTrip() throws {
    let plain = try CanonicalUIAdapters.canonical(from: BusinessSettings())
    let plainFields = try json(plain)
    expect(plainFields["estimateTerms"] == nil && plainFields["signatureDrawPad"] == nil,
           "settings: a new default record writes neither key")
    let projected = CanonicalUIAdapters.settings(from: plain)
    expect(projected.estimateTerms == "" && projected.signatureDrawPad, "settings: absent reads as no terms and the pad on")

    var custom = BusinessSettings()
    custom.estimateTerms = "Net 15."
    custom.signatureDrawPad = false
    let created = try CanonicalUIAdapters.canonical(from: custom)
    expect(created.estimateTerms == "Net 15." && created.signatureDrawPad == false, "settings: a custom new record writes both")
    expect(created.preservation.unknownFields["estimateTerms"] == nil, "settings: typed fields, not unknown ones")

    let edit = CanonicalUIEdit<BusinessSettings, Canonical.Settings>(value: projected, baseline: plain)
    var unrelated = edit
    unrelated.value.businessName = "Ada Electric LLC"
    let unrelatedFields = try json(CanonicalUIAdapters.canonical(from: unrelated))
    expect(unrelatedFields["estimateTerms"] == nil && unrelatedFields["signatureDrawPad"] == nil,
           "settings: an unrelated edit writes neither key")

    var withTerms = edit
    withTerms.value.estimateTerms = "50% deposit."
    withTerms.value.signatureDrawPad = false
    let changed = try CanonicalUIAdapters.canonical(from: withTerms)
    expect(changed.estimateTerms == "50% deposit." && changed.signatureDrawPad == false, "settings: both edits are written")

    var cleared = CanonicalUIEdit<BusinessSettings, Canonical.Settings>(
        value: CanonicalUIAdapters.settings(from: changed), baseline: changed
    )
    expect(cleared.value.estimateTerms == "50% deposit." && !cleared.value.signatureDrawPad, "settings: stored values project")
    cleared.value.estimateTerms = ""
    cleared.value.signatureDrawPad = true
    let clearedFields = try json(CanonicalUIAdapters.canonical(from: cleared))
    expect(clearedFields["estimateTerms"] == nil, "settings: cleared terms remove the key")
    expectEqual(clearedFields["signatureDrawPad"], .bool(true), "settings: turning the pad back on writes true")

    // A synced record from another device decodes the same way.
    var fields = plainFields
    fields["estimateTerms"] = .string("Synced terms.")
    fields["signatureDrawPad"] = .bool(false)
    let synced = try JSONDecoder().decode(Canonical.Settings.self, from: JSONEncoder().encode(Canonical.JSONValue.object(fields)))
    expect(synced.estimateTerms == "Synced terms." && synced.signatureDrawPad == false, "settings: synced keys decode")
    expectEqual(sortedJSON(synced), sortedJSON(Canonical.JSONValue.object(fields)), "settings: byte-stable round trip")

    // The legacy prototype store (BusinessSettings Codable) keeps them too.
    let legacy = try JSONDecoder().decode(BusinessSettings.self, from: JSONEncoder().encode(custom))
    expect(legacy.estimateTerms == "Net 15." && !legacy.signatureDrawPad, "settings: the UI model's own Codable round-trips")
    let oldLegacy = try decode(BusinessSettings.self, #"{"businessName":"Old"}"#)
    expect(oldLegacy.estimateTerms == "" && oldLegacy.signatureDrawPad, "settings: an old UI record defaults")
}

// MARK: - 3. Approval decode (§11.1 B)

let signedApprovalJSON = """
{"token":"tok_esign_0123456789abcdef","sentAt":"2026-10-01T16:00:00.000Z",
 "snapshot":\(baseSnapshotJSON),
 "decision":"approved","consentAt":"2026-10-03T14:05:09.000Z","signerName":"Pat Lee",
 "ip":null,"userAgent":"Mozilla/5.0 (iPhone)",
 "signatureRecordId":"3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b",
 "recordDigest":"\(String(repeating: "ab", count: 32))",
 "signatureMethod":"typed_drawn",
 "signatureEvidence":{"v":1,"consentVersion":1,
   "drawn":{"w":600,"h":200,"strokes":[[[0,0,0],[600,200,40]],[[300,100,90]]]},
   "email":"pat@example.test",
   "events":[{"type":"viewed","at":"2026-10-03T14:01:00.000Z","ip":"203.0.113.9"},
             {"type":"link_created","at":"2026-10-01T16:00:00.000Z","actor":"owner"},
             {"type":"viewed","at":"2026-10-03T14:01:00.000Z","ip":"198.51.100.4"}]}}
"""

/// The sealed canonical record (spec §3.5) as `POST /api/esign/record`
/// returns it. Deliberately different from `signedApprovalJSON`'s blob
/// (signer, IP, user agent, trail) so a test can tell which one is shown.
func sealedRecordJSON(
    recordId: String = "3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b",
    typedName: String = "Pat Q. Lee",
    consent: String = #"{"version":1,"text":"…","textSha256":"00","acceptedAt":"2026-10-03T14:05:09.000Z"}"#,
    drawn: String = #"{"w":600,"h":200,"strokes":[[[0,0,0],[600,200,40]],[[300,100,90]]]}"#,
    method: String = "typed_drawn",
    events: String = """
    [{"type":"viewed","at":"2026-10-03T14:01:00.000Z","ip":"203.0.113.9"},
     {"type":"link_created","at":"2026-10-01T16:00:00.000Z","actor":"owner"},
     {"type":"viewed","at":"2026-10-03T14:01:00.000Z","ip":"198.51.100.4"}]
    """
) -> String {
    """
    {"recordVersion":1,"recordId":"\(recordId)","documentType":"estimate","jobId":"job-1","changeOrderId":null,
     "approvalTokenSha256":"00","document":{},"documentDigest":"00","selection":null,
     "consent":\(consent),"intent":null,
     "signer":{"typedName":"\(typedName)","drawn":\(drawn),"email":null},
     "signatureMethod":"\(method)","signedAt":"2026-10-03T14:05:09.000Z","ip":"203.0.113.9",
     "userAgent":"Mozilla/5.0 (Sealed)","context":"remote_link","events":\(events),"renderer":"pdf-v1"}
    """
}

@MainActor
func testApprovalDecode() throws {
    let legacy = try decode(Canonical.EstimateApproval.self, """
    {"token":"tok_legacy_0123456789abcdef","sentAt":"2026-09-01T16:00:00.000Z","snapshot":\(baseSnapshotJSON),
     "decision":"approved","consentAt":"2026-09-02T16:00:00.000Z","signerName":"Pat Lee","ip":"203.0.113.1","userAgent":"UA"}
    """)
    expect(legacy.signatureRecordId == nil && legacy.recordDigest == nil && legacy.signatureMethod == nil,
           "decode: a legacy approval has none of the keys")
    expectEqual(NativeESignature.evidence(for: legacy),
                .typedName(signerName: "Pat Lee", approvedAt: "2026-09-02T16:00:00.000Z"),
                "decode: a legacy approval is a typed-name approval")

    let signed = try decode(Canonical.EstimateApproval.self, signedApprovalJSON)
    expectEqual(signed.signatureRecordId, "3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b", "decode: signatureRecordId is typed")
    expectEqual(signed.recordDigest, String(repeating: "ab", count: 32), "decode: recordDigest is typed")
    expectEqual(signed.signatureMethod, "typed_drawn", "decode: signatureMethod is typed")
    expect(signed.ip == nil, "decode: a null edge IP reads as nil")
    expect(signed.preservation.unknownFields["signatureEvidence"] != nil, "decode: signatureEvidence stays opaque")
    let original = try decode(Canonical.JSONValue.self, signedApprovalJSON)
    expectEqual(sortedJSON(signed), sortedJSON(original), "decode: the approval re-encodes byte for byte (null ip kept)")

    var tampered = signed
    tampered.recordDigest = String(repeating: "cd", count: 32)
    expect(!CanonicalUIAdapters.estimateApprovalsMatch(signed, tampered), "decode: approvals compare the fingerprint")
    expect(CanonicalUIAdapters.estimateApprovalsMatch(signed, signed), "decode: an approval matches itself")

    // Review P2 (§11.11): the blob's signature keys are the owner's own
    // writable copy. An approval that claims a signature is only a CLAIM:
    // nothing from signatureEvidence, ip, userAgent or the stored fingerprint
    // is read, and it is unconfirmed until the Worker returns the record.
    expectEqual(NativeESignature.evidence(for: signed),
                .claimedSignature(.init(recordID: "3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b",
                                        signerName: "Pat Lee", approvedAt: "2026-10-03T14:05:09.000Z")),
                "evidence: a blob that claims a signature is a claim, not a signature")
    guard case let .claimedSignature(claim)? = NativeESignature.evidence(for: signed) else {
        expect(false, "evidence: a claimed signature reads as a claim"); return
    }
    expectEqual(NativeESignature.statusLabel(.unconfirmed), "Signature record not confirmed yet",
                "evidence: an unchecked claim says it is unconfirmed")
    expect(NativeESignature.statusLabel(.unconfirmed)?.hasPrefix("Signed by") == false,
           "evidence: an unchecked claim never reads \"Signed by\"")

    // A planted blob that the Worker holds no record for is downgraded.
    expectEqual(NativeESignature.confirmation(for: claim, check: .notFound), .noRecord,
                "confirm: no Worker-held record downgrades the claim")
    expectEqual(NativeESignature.statusLabel(.noRecord), "No signature record found for this approval",
                "confirm: and says so")
    expectEqual(NativeESignature.confirmation(for: claim, check: .pending), .sealing, "confirm: 503 record_pending is sealing")
    expectEqual(NativeESignature.confirmation(for: claim, check: .failed("offline")), .unverifiable("offline"),
                "confirm: a failed check stays unconfirmed")
    expect(!NativeESignature.confirmation(for: claim, check: .failed("offline")).isConfirmed, "confirm: not confirmed")

    // Only the sealed record confirms, and everything shown comes from it,
    // not from the blob (whose signer, IP and trail differ here).
    guard let sealed = NativeESignature.sealedRecord(
        recordID: "3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b", recordDigest: String(repeating: "ef", count: 32),
        sealKeyID: "k2026-10", record: try decode(Canonical.JSONValue.self, sealedRecordJSON()), liveEvents: []
    ) else { expect(false, "confirm: the sealed record reads"); return }
    guard case let .confirmed(evidence) = NativeESignature.confirmation(for: claim, check: .found(sealed)) else {
        expect(false, "confirm: the matching sealed record confirms"); return
    }
    expectEqual(evidence.recordID, "3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b", "evidence: record id")
    expectEqual(evidence.recordDigest, String(repeating: "ef", count: 32), "evidence: the fingerprint is the Worker's, not the blob's")
    expectEqual(evidence.signerName, "Pat Q. Lee", "evidence: signer from the sealed record")
    expectEqual(evidence.consentVersion, 1, "evidence: consent version")
    expectEqual(evidence.methodLabel, "Typed name and drawn signature", "evidence: method label")
    expect(evidence.consentLabel.contains("version 1"), "evidence: consent label names the version")
    expect(evidence.ip == "203.0.113.9" && evidence.userAgent == "Mozilla/5.0 (Sealed)", "evidence: IP and user agent from the record")
    expect(evidence.drawing != nil, "evidence: the drawn mark is read from the sealed record")
    // Audit trail: sealed events + the signing, oldest first, ties in order.
    expectEqual(evidence.trail.map(\.type), ["link_created", "viewed", "viewed", "signed"], "trail: oldest first")
    expectEqual(evidence.trail.map(\.ip), [nil, "203.0.113.9", "198.51.100.4", "203.0.113.9"], "trail: equal times keep their order")
    expectEqual(evidence.trail.first?.label, "Approval link created by you", "trail: owner event label")
    // The live log, when the Worker sent one, is the trail shown.
    let live = [NativeESignature.AuditEvent(type: "copy_downloaded", at: "2026-10-04T10:00:00.000Z"),
                NativeESignature.AuditEvent(type: "signed", at: "2026-10-03T14:05:09.000Z")]
    let withLive = NativeESignature.sealedRecord(
        recordID: claim.recordID, recordDigest: digest, sealKeyID: nil,
        record: try decode(Canonical.JSONValue.self, sealedRecordJSON()), liveEvents: live
    )
    expectEqual(withLive.map { NativeESignature.SignedApproval(sealed: $0).trail.map(\.type) }, ["signed", "copy_downloaded"],
                "trail: the live log, oldest first")

    // A different record never confirms the claim.
    guard let other = NativeESignature.sealedRecord(
        recordID: "11111111-2222-4333-8444-555555555555", recordDigest: digest, sealKeyID: nil,
        record: try decode(Canonical.JSONValue.self, sealedRecordJSON(recordId: "11111111-2222-4333-8444-555555555555")),
        liveEvents: []
    ) else { expect(false, "confirm: the other record reads"); return }
    expect(!NativeESignature.confirmation(for: claim, check: .found(other)).isConfirmed,
           "confirm: another record id never confirms the claim")
    // A record that isn't a full version-1 record with that id is refused.
    for (label, text) in [
        ("an id mismatch", sealedRecordJSON(recordId: "11111111-2222-4333-8444-555555555555")),
        ("no typed name", sealedRecordJSON(typedName: "")),
        ("another version", sealedRecordJSON().replacingOccurrences(of: #""recordVersion":1"#, with: #""recordVersion":2"#)),
        ("a bare stub", #"{"recordVersion":1}"#),
    ] {
        let raw = try decode(Canonical.JSONValue.self, text)
        expect(NativeESignature.sealedRecord(
            recordID: claim.recordID, recordDigest: digest, sealKeyID: nil, record: raw, liveEvents: []
        ) == nil, "sealed record: \(label) is refused")
    }

    let typedOnly = NativeESignature.sealedRecord(
        recordID: claim.recordID, recordDigest: digest, sealKeyID: nil,
        record: try decode(Canonical.JSONValue.self, sealedRecordJSON(consent: "null", drawn: "null", method: "typed", events: "[]")),
        liveEvents: []
    ).map(NativeESignature.SignedApproval.init(sealed:))
    guard let older = typedOnly else { expect(false, "evidence: an older-page record reads"); return }
    expect(older.consentVersion == nil && older.consentLabel.contains("older page"), "evidence: no consent step is said plainly")
    expect(older.drawing == nil && older.methodLabel == "Typed name", "evidence: typed only")
    expectEqual(older.trail.map(\.type), ["signed"], "evidence: the signing alone")

    var declined = signed
    declined.decision = "declined"
    expect(NativeESignature.evidence(for: declined) == nil, "evidence: a decline is not a signature")
    var open = legacy
    open.decision = nil
    expect(NativeESignature.evidence(for: open) == nil, "evidence: an open approval shows nothing")
    expect(NativeESignature.evidence(for: nil as Canonical.EstimateApproval?) == nil, "evidence: no approval, nothing")
}

// MARK: - 4. Stroke scaling (§3.3, §11.1 B)

@MainActor
func testStrokeScaling() throws {
    let drawn = try decode(Canonical.JSONValue.self, #"{"w":600,"h":200,"strokes":[[[0,0,0],[600,200,10],[300,50,20]],[[150,100,30]]]}"#)
    guard let drawing = NativeESignature.Drawing(json: drawn) else {
        expect(false, "strokes: a valid drawing reads"); return
    }
    expectEqual(drawing.aspectRatio, 3, "strokes: the 600 × 200 pad is 3:1")
    let scaled = drawing.scaledStrokes(targetWidth: 300, targetHeight: 100)
    expectEqual(scaled.count, 2, "strokes: two strokes")
    expectEqual(scaled[0], [.init(x: 0, y: 0), .init(x: 300, y: 100), .init(x: 150, y: 25)], "strokes: x * W / 600, y * H / 200")
    expectEqual(scaled[1], [.init(x: 75, y: 50)], "strokes: a one-point stroke stays a dot")
    let wide = drawing.scaledStrokes(targetWidth: 900, targetHeight: 300)
    expectEqual(wide[0][1], .init(x: 900, y: 300), "strokes: scales up too")

    func reads(_ text: String) -> Bool {
        NativeESignature.Drawing(json: try? decode(Canonical.JSONValue.self, text)) != nil
    }
    expect(!reads(#"{"w":600,"h":200,"strokes":[[[10,10,0]]]}"#), "strokes: a single dot is not drawn")
    expect(!reads(#"{"w":600,"h":200,"strokes":[]}"#), "strokes: empty is not drawn")
    expect(!reads(#"{"w":600,"h":200,"strokes":[[[601,10,0],[5,5,1]]]}"#), "strokes: out of the box is refused")
    expect(!reads(#"{"w":600,"h":200,"strokes":[[[1,"a",0],[5,5,1]]]}"#), "strokes: a malformed point is refused")
    expect(!reads(#"{"w":0,"h":200,"strokes":[[[0,0,0],[5,5,1]]]}"#), "strokes: a zero box is refused")
    expect(!reads(#"null"#), "strokes: null is not drawn")
    let many = "[" + Array(repeating: "[[1,1,0],[2,2,1]]", count: 41).joined(separator: ",") + "]"
    expect(!reads(#"{"w":600,"h":200,"strokes":"# + many + "}"), "strokes: more than 40 strokes is refused")
}

// MARK: - 5. Audit trail ordering and labels (§3.5 events, §3.7)

@MainActor
func testAuditTrail() {
    let events: [NativeESignature.AuditEvent] = [
        .init(type: "copy_downloaded", at: "2026-10-03T15:00:00.000Z"),
        .init(type: "mystery_event", at: "not a date"),
        .init(type: "signed", at: "2026-10-03T14:05:09Z", ip: "203.0.113.9"),
        .init(type: "viewed", at: "2026-10-03T14:01:00.000Z", ip: ""),
        .init(type: "link_created", at: "2026-10-01T16:00:00.000Z"),
        .init(type: "copy_emailed", at: "2026-10-03T14:05:09.000Z"),
    ]
    let ordered = NativeESignature.orderedTrail(events)
    expectEqual(ordered.map(\.type), ["link_created", "viewed", "signed", "copy_emailed", "copy_downloaded", "mystery_event"],
                "trail: by time, ties in order, unreadable last")
    expect(ordered[1].ip == nil, "trail: an empty IP reads as none")
    let labels = Dictionary(uniqueKeysWithValues: ordered.map { ($0.type, $0.label) })
    expectEqual(labels["viewed"], "Customer opened the link", "labels: viewed")
    expectEqual(labels["signed"], "Customer signed", "labels: signed")
    expectEqual(labels["copy_emailed"], "Signed copy emailed to the customer", "labels: emailed")
    expectEqual(labels["copy_downloaded"], "Signed copy downloaded", "labels: downloaded")
    expectEqual(labels["mystery_event"], "Mystery event", "labels: an unknown type reads plainly")
    expectEqual(NativeESignature.AuditEvent(type: "copy_email_failed", at: "").label, "Signed copy email didn’t send", "labels: email failed")
    expectEqual(NativeESignature.AuditEvent(type: "declined", at: "").label, "Customer declined", "labels: declined")

    // ICU puts a narrow no-break space before AM on newer systems.
    func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
    expectEqual(plain(NativeESignature.displayTimestamp("2026-10-03T14:05:09.000Z", timeZone: phoenix, locale: enUS)),
                "Oct 3, 2026 at 7:05 AM", "display: the owner's zone")
    expectEqual(NativeESignature.displayTimestamp("garbled", timeZone: phoenix, locale: enUS), "garbled", "display: raw when unreadable")
    expectEqual(plain(NativeESignature.signedTitle(signerName: "Pat Lee", signedAt: "2026-10-03T14:05:09Z", timeZone: phoenix, locale: enUS)),
                "Signed by Pat Lee · Oct 3, 2026 at 7:05 AM", "display: Signed by {name} · {date}")
    expectEqual(NativeESignature.signedTitle(signerName: "", signedAt: nil), "Signed by the customer", "display: no name, no time")
    expectEqual(NativeESignature.fingerprintGroups(String(repeating: "0123456789abcdef", count: 4)),
                "01234567 89abcdef 01234567 89abcdef 01234567 89abcdef 01234567 89abcdef", "display: fingerprint in eights")
}

// MARK: - 6. Legacy and on-site labels (§3.7)

@MainActor
func testLegacyAndManualLabels() throws {
    expectEqual(NativeESignature.typedNameApprovalLabel, "Typed-name approval (before audit trail)", "labels: legacy")
    expectEqual(NativeESignature.ownerRecordedLabel, "Recorded by you — not signed by the customer", "labels: on site")

    let manual = try decode(Canonical.ChangeOrder.self, """
    {"id":"co-1","title":"Extra outlet","amount":120,"createdAt":"2026-10-02",
     "manualDecision":{"decision":"approved","decidedAt":"2026-10-02T18:00:00.000Z","note":"Agreed on site"}}
    """)
    expectEqual(NativeESignature.evidence(for: manual), .recordedByOwner(decision: "approved", decidedAt: "2026-10-02T18:00:00.000Z"),
                "labels: an on-site decision is recorded by the owner")
    let declinedOnSite = try decode(Canonical.ChangeOrder.self, """
    {"id":"co-2","title":"Skip it","amount":50,"createdAt":"2026-10-02",
     "manualDecision":{"decision":"declined","decidedAt":"2026-10-02T18:00:00.000Z"}}
    """)
    expectEqual(NativeESignature.evidence(for: declinedOnSite), .recordedByOwner(decision: "declined", decidedAt: "2026-10-02T18:00:00.000Z"),
                "labels: an on-site decline is the owner's record too")
    let signedOrder = try decode(Canonical.ChangeOrder.self, """
    {"id":"co-3","title":"Sub-panel","amount":900,"createdAt":"2026-10-02","approval":\(signedApprovalJSON)}
    """)
    guard case .claimedSignature? = NativeESignature.evidence(for: signedOrder) else {
        expect(false, "labels: a change order signed through its link claims a signature"); return
    }
    let pending = try decode(Canonical.ChangeOrder.self, #"{"id":"co-4","title":"Pending","amount":10,"createdAt":"2026-10-02"}"#)
    expect(NativeESignature.evidence(for: pending) == nil, "labels: a pending change order shows nothing")
}

// MARK: - 7. Signed-record transport (§11.1 C)

final class FakeLoader: NativeEstimateApprovalHTTPDataLoading, @unchecked Sendable {
    var status = 200
    var body = Data()
    var error: Error?
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

let recordID = "3f0c1a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
let digest = String(repeating: "ab", count: 32)
let pdfBase64 = Data("%PDF-1.4\n% signed\n".utf8).base64EncodedString()

func recordBody(
    recordId: String = recordID,
    jobId: String = "job-1",
    changeOrderId: String? = nil,
    documentType: String = "estimate",
    pdf: String = pdfBase64,
    filename: String = "signed-estimate-3f0c1a2b.pdf"
) -> Data {
    let co = changeOrderId.map { "\"\($0)\"" } ?? "null"
    return Data("""
    {"recordId":"\(recordId)","recordDigest":"\(digest)","documentType":"\(documentType)","jobId":"\(jobId)","changeOrderId":\(co),
     "signedAt":"2026-10-03T14:05:09.000Z","signatureMethod":"typed","seal":{"alg":"Ed25519","keyId":"k2026-10","signature":"c2ln"},
     "record":\(sealedRecordJSON(recordId: recordId)),
     "events":[{"type":"signed","at":"2026-10-03T14:05:09.000Z","ip":"203.0.113.9"},{"type":"link_created","at":"2026-10-01T16:00:00.000Z","ip":null},
               {"type":"copy_downloaded","at":"2026-10-03T15:00:00.000Z","ip":"203.0.113.9"}],
     "pdf":{"filename":"\(filename)","contentType":"application/pdf","base64":"\(pdf)"}}
    """.utf8)
}

let session = Data(#"{"access_token":"private-access-token"}"#.utf8)
let endpoint = URL(string: "https://worker.example/api/esign/record")!

@MainActor
func testTransport() async throws {
    let loader = FakeLoader()
    let service = NativeESignatureRecordService(endpoint: endpoint, loader: loader)
    loader.body = recordBody()
    let record = try await service.fetchRecord(jobID: "job-1", changeOrderID: nil, recordID: recordID, sessionBytes: session)
    let request = loader.requests.last
    expectEqual(request?.httpMethod, "POST", "transport: POST")
    expectEqual(request?.url, endpoint, "transport: the record route")
    expectEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer private-access-token", "transport: bearer auth")
    let sent = request?.httpBody.flatMap { try? JSONDecoder().decode(Canonical.JSONValue.self, from: $0) }
    expectEqual(sent, .object(["jobId": .string("job-1"), "recordId": .string(recordID)]),
                "transport: the estimate body omits changeOrderId")
    expectEqual(record.recordDigest, digest, "transport: the fingerprint")
    expectEqual(record.events.map(\.type), ["link_created", "signed", "copy_downloaded"], "transport: live events, oldest first")
    expectEqual(record.pdfFilename, "signed-estimate-3f0c1a2b.pdf", "transport: the server filename")
    expect(record.pdfData.starts(with: Data("%PDF-".utf8)), "transport: the PDF bytes")
    expectEqual(record.sealKeyID, "k2026-10", "transport: the seal key id")
    expectEqual(record.sealed.signerName, "Pat Q. Lee", "transport: the signer is read from the sealed record")
    expectEqual(record.sealed.recordDigest, digest, "transport: the sealed view carries the route's fingerprint")
    expectEqual(record.sealed.liveEvents, record.events, "transport: with the live log")

    loader.body = recordBody(changeOrderId: "co-1", documentType: "change_order")
    _ = try await service.fetchRecord(jobID: "job-1", changeOrderID: "co-1", recordID: recordID, sessionBytes: session)
    let coBody = loader.requests.last?.httpBody.flatMap { try? JSONDecoder().decode(Canonical.JSONValue.self, from: $0) }
    expectEqual(coBody, .object(["jobId": .string("job-1"), "changeOrderId": .string("co-1"), "recordId": .string(recordID)]),
                "transport: a change order sends its id")

    func failure(_ configure: () -> Void, changeOrderID: String? = nil, sessionBytes: Data = session,
                 service override: NativeESignatureRecordService? = nil) async -> NativeESignatureRecordError? {
        loader.status = 200
        loader.body = recordBody()
        loader.error = nil
        configure()
        do {
            _ = try await (override ?? service).fetchRecord(
                jobID: "job-1", changeOrderID: changeOrderID, recordID: recordID, sessionBytes: sessionBytes
            )
            return nil
        } catch {
            return error as? NativeESignatureRecordError
        }
    }
    expectEqual(await failure({ loader.status = 404 }), .notFound, "transport: 404 record_not_found")
    expectEqual(await failure({ loader.status = 401 }), .rejectedSession, "transport: 401")
    expectEqual(await failure({ loader.status = 429 }), .rateLimited, "transport: 429")
    expectEqual(await failure({ loader.status = 503; loader.body = Data(#"{"error":"x","code":"record_pending"}"#.utf8) }),
                .pending, "transport: 503 record_pending")
    expectEqual(await failure({ loader.status = 503; loader.body = Data("{}".utf8) }), .unavailable, "transport: other 503")
    expectEqual(await failure({ loader.status = 500 }), .unavailable, "transport: 500")
    expectEqual(await failure({ loader.error = URLError(.notConnectedToInternet) }), .unavailable, "transport: offline")
    expectEqual(await failure({ loader.body = recordBody(recordId: "11111111-2222-4333-8444-555555555555") }),
                .invalidResponse, "transport: another record is refused")
    expectEqual(await failure({ loader.body = recordBody(jobId: "job-2") }), .invalidResponse, "transport: another job is refused")
    expectEqual(await failure({ loader.body = recordBody(changeOrderId: "co-9", documentType: "change_order") }),
                .invalidResponse, "transport: a change-order record for the estimate is refused")
    expectEqual(await failure({ loader.body = recordBody(pdf: Data("<html>".utf8).base64EncodedString()) }),
                .invalidResponse, "transport: a non-PDF body is refused")
    expectEqual(await failure({ loader.body = Data("{}".utf8) }), .invalidResponse, "transport: a malformed body is refused")
    expectEqual(await failure({
        loader.body = Data(String(decoding: recordBody(), as: UTF8.self)
            .replacingOccurrences(of: #""recordId":"\#(recordID)","documentType""#, with: #""recordId":"11111111-2222-4333-8444-555555555555","documentType""#).utf8)
    }), .invalidResponse, "transport: a sealed record naming another id is refused")
    expectEqual(await failure({}, sessionBytes: Data("{}".utf8)), .malformedSession, "transport: no session")
    expectEqual(await failure({}, service: NativeESignatureRecordService(
        endpoint: URL(string: "http://worker.example/api/esign/record")!, loader: loader
    )), .invalidConfiguration, "transport: plain http off localhost is refused")
    loader.body = recordBody(filename: "../../etc/passwd.pdf")
    let unsafe = try await service.fetchRecord(jobID: "job-1", changeOrderID: nil, recordID: recordID, sessionBytes: session)
    expectEqual(unsafe.pdfFilename, "signed-estimate.pdf", "transport: an unsafe filename falls back")
    expectEqual(NativeESignatureRecordService.safeFilename(nil, documentType: "change_order"), "signed-change-order.pdf",
                "transport: change-order fallback filename")
    let before = loader.requests.count
    do {
        _ = try await service.fetchRecord(jobID: "job-1", changeOrderID: nil, recordID: "not-a-uuid", sessionBytes: session)
        expect(false, "transport: a malformed record id is refused")
    } catch {
        expectEqual(error as? NativeESignatureRecordError, .notFound, "transport: a malformed record id is not found")
    }
    expectEqual(loader.requests.count, before, "transport: nothing sent for a malformed record id")
}

// MARK: - 8. Copy rules (§7, 19-Q5)

/// No owner-facing string in the Phase 19 sources makes a claim from the
/// must-not-say list. Comments may quote the list; string literals may not.
@MainActor
func testCopyRules(root: URL) {
    let files = [
        "native/TradeReadyNative/Domain/NativeESignature.swift",
        "native/TradeReadyNative/NativeESignatureStore.swift",
        "native/TradeReadyNative/NativeESignatureTransport.swift",
        "native/TradeReadyNative/NativeSignatureRecordView.swift",
    ]
    let banned = ["legally binding", "legally-binding", "enforceable", "court-admissible", "court admissible", "court-proof",
                  "guaranteed", "compliant", "notarized", "certified", "qualified signature", "identity verified",
                  "as valid as docusign", "more legal"]
    let literal = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    var scanned = 0
    for path in files {
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            expect(false, "copy: \(path) is readable"); continue
        }
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let ns = code as NSString
        for match in literal.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            scanned += 1
            let value = ns.substring(with: match.range).lowercased()
            for phrase in banned where value.contains(phrase) {
                expect(false, "copy: \(path) says \"\(phrase)\" in \(value.prefix(80))")
            }
        }
    }
    expect(scanned >= 40, "copy: the Phase 19 string literals are scanned (\(scanned))")
    expect(NativeESignature.accountDeletionWarning.contains("Save any copies you need first"), "copy: the 19-Q6 export warning")
    expect(NativeESignature.termsHelp == "Your own terms. TradeReady doesn't provide legal terms.", "copy: the terms helper line")
}

// MARK: - 9. AppStore wiring

final class AlwaysReachable: NativeSyncReachability, @unchecked Sendable {
    func isReachable() async -> Bool { true }
}

final class RecordingLinkService: NativeEstimateApprovalLinking, @unchecked Sendable {
    private(set) var snapshots: [Canonical.EstimateApprovalSnapshot] = []

    func createLink(jobID: String, snapshot: Canonical.EstimateApprovalSnapshot, sessionBytes: Data) async throws -> NativeEstimateApprovalLink {
        snapshots.append(snapshot)
        let token = "tok_esign_store_0123456789"
        return NativeEstimateApprovalLink(
            url: URL(string: "https://tradeready.example/estimate.html?j=\(jobID)&t=\(token)")!,
            token: token,
            sentAt: "2026-10-03T19:00:00.000Z"
        )
    }

    func beginDeclinedRevision(jobID: String, approvalToken: String, sessionBytes: Data) async throws -> Canonical.Job {
        throw NativeEstimateApprovalLinkError.unavailable
    }
}

final class FakeRecordService: NativeESignatureRecordFetching, @unchecked Sendable {
    var results: [Result<NativeSignedRecord, NativeESignatureRecordError>] = []
    var beforeReturn: (@MainActor () -> Void)?
    private(set) var calls: [(jobID: String, changeOrderID: String?, recordID: String)] = []

    func fetchRecord(jobID: String, changeOrderID: String?, recordID: String, sessionBytes: Data) async throws -> NativeSignedRecord {
        calls.append((jobID, changeOrderID, recordID))
        if let hook = beforeReturn { await hook() }
        let next = results.isEmpty ? .failure(.unavailable) : results.removeFirst()
        return try next.get()
    }
}

@MainActor
struct StoreHarness {
    static let subject = "19191919-1919-1919-1919-191919191919"
    static let binding = String(repeating: "e", count: 64)
    static let supabaseURL = URL(string: "https://project.supabase.co")!

    let dir: URL
    let store: AppStore
    let links: RecordingLinkService
    let records: FakeRecordService

    init(tag: String) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-esign-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.json")
        let server = InMemorySupabase()
        links = RecordingLinkService()
        records = FakeRecordService()
        store = AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: server
            ),
            estimateApprovalLinkService: links,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        try? NativeOnboardingStore(snapshotURL: storeURL).save(NativeOnboardingDocument(
            accountBinding: Self.binding, stage: .done,
            draft: .init(businessName: "Ada Electric", contactName: "Ada", trade: .electrical, step: 1)
        ))
        store.testSeedNativeSignedInOwner(subject: Self.subject, binding: Self.binding)
        let credentials = NativeSyncCredentials(subject: Self.subject, sessionBytes: session)
        store.scheduleBookingTestCredentials = credentials
        store.esignRecordServiceOverride = records
        let queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
        let store = store
        let coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: server
            ),
            queue: queue,
            reachability: AlwaysReachable(),
            credentialsProvider: { credentials },
            refreshSession: { false },
            settleRejected: { try store.testSettleRejectedChanges($0) },
            pull: { await store.testPullDeltaIfPossible() },
            statusChanged: { status in store.testApplySyncStatus(status) }
        )
        store.testUseSyncCoordinator(coordinator)
        store.settings.businessName = "Ada Electric"
        store.settings.phone = "555-0100"
        store.settings.email = "ada@example.test"
        store.settings.estimateTerms = "50% deposit before work starts."
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func lead(_ title: String, description: String = "Replace the 100A panel.") -> String? {
        let customer = Customer(name: "Pat Lee", email: "pat@example.test", phone: "555-0199")
        let job = Job(customerId: customer.id, customerName: customer.name, title: title, description: description,
                      status: .lead, laborRate: 100)
        guard store.upsert(customer), store.upsert(job), var pricing = store.jobPricingDraft(jobID: job.id) else { return nil }
        pricing.laborHours = 3
        guard store.saveJobPricing(pricing) else { return nil }
        return job.id
    }
}

let storeNow = ISO8601DateFormatter().date(from: "2026-10-03T19:00:00Z")!

@MainActor
func testReviewDraftAndLink() async throws {
    let h = StoreHarness(tag: "draft")
    defer { h.cleanup() }
    expectEqual(TimeZone.current.identifier, "America/Phoenix", "store: the runner pins TZ=America/Phoenix")
    guard let id = h.lead("Panel upgrade") else { expect(false, "store: the lead saves"); return }
    guard let draft = h.store.estimateReviewDraft(jobID: id, now: storeNow) else {
        expect(false, "store: the review opens"); return
    }
    let snapshot = draft.snapshot
    expectEqual(snapshot.scope, "Replace the 100A panel.", "store: scope is the job description")
    expectEqual(snapshot.terms, "50% deposit before work starts.", "store: terms from settings")
    expectEqual(snapshot.businessContact, .init(phone: "555-0100", email: "ada@example.test"), "store: contact from settings")
    expectEqual(snapshot.signature, .init(drawPad: true), "store: the pad defaults on")
    expectEqual(snapshot.esign, .init(version: 1, timeZone: "America/Phoenix"), "store: esign with the device zone")
    expectEqual(snapshot.validUntil, "2026-11-02", "store: the Phase 32 date is still proposed")
    expectEqual(snapshot.validUntilTimeZone, "America/Phoenix", "store: with its zone")

    // The link mints exactly the reviewed snapshot (sync-before-mint rebuilds
    // it with the review's own zone and finds no change).
    let outcome = await h.store.createEstimateApprovalLink(for: draft, on: storeNow)
    guard case .success = outcome else { expect(false, "store: the link mints (\(outcome))"); return }
    guard let sent = h.links.snapshots.last else { expect(false, "store: create-link was called"); return }
    expectEqual(sortedJSON(sent), sortedJSON(snapshot), "store: create-link receives the reviewed snapshot with the additions")
    let wire = try json(sent)
    for key in ["scope", "terms", "businessContact", "signature", "esign", "validUntil", "validUntilTimeZone", "lineItems", "total"] {
        expect(wire[key] != nil, "store: the create-link body carries \(key)")
    }
    let mirrored = h.store.activeEstimateApproval(jobID: id)?.snapshot
    expect(mirrored.map { CanonicalUIAdapters.estimateApprovalSnapshotsMatch($0, snapshot) } == true,
           "store: the local approval mirrors the minted snapshot")

    // A settings change while the review is open is a change to what is signed.
    guard let second = h.lead("Rewire garage") , let review = h.store.estimateReviewDraft(jobID: second, now: storeNow) else {
        expect(false, "store: a second review opens"); return
    }
    h.store.settings.estimateTerms = "Net 15."
    let stale = await h.store.createEstimateApprovalLink(for: review, on: storeNow)
    expectEqual(stale, .failure(.estimateChanged), "store: new terms while the review is open fail closed")

    // Pad off and no terms flow into the next review.
    h.store.settings.signatureDrawPad = false
    h.store.settings.estimateTerms = ""
    let plain = h.store.estimateReviewDraft(jobID: second, now: storeNow)?.snapshot
    expect(plain?.signature == .init(drawPad: false) && plain?.terms == nil, "store: pad off and no terms are frozen")

    // A settings value the Worker would refuse explains itself before any network call.
    h.store.settings.phone = String(repeating: "5", count: 41)
    h.store.migrationMessage = nil
    expect(h.store.estimateReviewDraft(jobID: second, now: storeNow) == nil, "store: a too-long phone blocks the review")
    expectEqual(h.store.migrationMessage, NativeESignature.SnapshotError.businessPhoneTooLong.errorDescription,
                "store: with the fix-it message")
}

@MainActor
func testChangeOrderSnapshot() throws {
    let h = StoreHarness(tag: "change-order")
    defer { h.cleanup() }
    let customer = Customer(name: "Pat Lee")
    let job = Job(customerId: customer.id, customerName: customer.name, title: "Panel upgrade",
                  description: "Replace the panel.", status: .approved, laborRate: 100)
    guard h.store.upsert(customer), h.store.upsert(job),
          case .success(var draft) = h.store.changeOrderDraft(jobID: job.id)
    else { expect(false, "co: the approved job takes a change order"); return }
    draft.title = "Garage sub-panel"
    draft.description = "  Add a 60A sub-panel in the garage. "
    draft.amountText = "900"
    guard case .created(let orderID) = h.store.commitChangeOrder(draft) else {
        expect(false, "co: the change order saves"); return
    }
    guard let approvalDraft = h.store.changeOrderApprovalDraft(jobID: job.id, changeOrderID: orderID) else {
        expect(false, "co: the approval draft builds"); return
    }
    let snapshot = approvalDraft.snapshot
    expectEqual(snapshot.scope, "Add a 60A sub-panel in the garage.", "co: scope is the change order's description")
    expect(snapshot.terms == nil, "co: no terms on a change order")
    expectEqual(snapshot.esign, .init(version: 1, timeZone: "America/Phoenix"), "co: esign")
    expectEqual(snapshot.businessContact?.email, "ada@example.test", "co: the paper-copy contact")
    expectEqual(snapshot.lineItems.first?.label, "Garage sub-panel", "co: the existing line is untouched")
    expect(h.store.changeOrderESignProblem(jobID: job.id, changeOrderID: orderID) == nil, "co: no problem with good settings")

    h.store.settings.email = "not an address"
    expect(h.store.changeOrderApprovalDraft(jobID: job.id, changeOrderID: orderID) == nil, "co: a bad business email blocks the draft")
    expectEqual(h.store.changeOrderESignProblem(jobID: job.id, changeOrderID: orderID),
                NativeESignature.SnapshotError.businessEmailInvalid.errorDescription, "co: and explains why")
    expect(h.store.changeOrderESignProblem(jobID: job.id, changeOrderID: "missing") == nil, "co: an unknown order has no e-sign problem")
}

func testSealedRecord(recordId: String = recordID) -> NativeESignature.SealedRecord {
    NativeESignature.sealedRecord(
        recordID: recordId, recordDigest: digest, sealKeyID: "k2026-10",
        record: (try? decode(Canonical.JSONValue.self, sealedRecordJSON(recordId: recordId))) ?? .null,
        liveEvents: []
    )!
}

/// Review P2 (§11.11): the app confirms a claimed signature only through
/// the Worker; a 404 downgrades it, and only a found record is remembered.
@MainActor
func testSignatureCheck() async throws {
    let h = StoreHarness(tag: "check")
    defer { h.cleanup() }
    func signedRecord(_ id: String = recordID) -> NativeSignedRecord {
        NativeSignedRecord(
            recordID: id, recordDigest: digest, documentType: "estimate", signedAt: "2026-10-03T14:05:09.000Z",
            signatureMethod: "typed", sealKeyID: "k2026-10", events: [], sealed: testSealedRecord(recordId: id),
            pdfFilename: "signed-estimate.pdf", pdfData: Data("%PDF-1.4\n".utf8)
        )
    }

    h.records.results = [.failure(.notFound)]
    expectEqual(await h.store.checkSignatureRecord(jobID: "job-1", changeOrderID: nil, recordID: recordID), .notFound,
                "check: a blob-only claim the Worker never captured is not found")
    h.records.results = [.failure(.pending)]
    expectEqual(await h.store.checkSignatureRecord(jobID: "job-1", changeOrderID: nil, recordID: recordID), .pending,
                "check: 503 record_pending")
    h.records.results = [.failure(.unavailable)]
    guard case .failed = await h.store.checkSignatureRecord(jobID: "job-1", changeOrderID: nil, recordID: recordID) else {
        expect(false, "check: offline is a failed check"); return
    }
    expectEqual(h.records.calls.count, 3, "check: nothing is remembered until a record is found")

    h.records.results = [.success(signedRecord())]
    expectEqual(await h.store.checkSignatureRecord(jobID: "job-1", changeOrderID: "co-1", recordID: recordID),
                .found(testSealedRecord()), "check: the Worker's sealed record")
    expectEqual(h.records.calls.last?.changeOrderID, "co-1", "check: for that change order's record")
    expectEqual(await h.store.checkSignatureRecord(jobID: "job-1", changeOrderID: "co-1", recordID: recordID),
                .found(testSealedRecord()), "check: a found record is remembered")
    expectEqual(h.records.calls.count, 4, "check: without asking again")
    h.records.results = [.failure(.notFound)]
    expectEqual(await h.store.checkSignatureRecord(jobID: "job-1", changeOrderID: nil, recordID: recordID), .notFound,
                "check: the cache is per link (the estimate is asked separately)")

    // The account changes mid-check: nothing is confirmed or remembered.
    h.records.results = [.success(signedRecord())]
    h.records.beforeReturn = { h.store.testSeedNativeSignedInOwner(subject: "another-subject", binding: StoreHarness.binding) }
    guard case .failed = await h.store.checkSignatureRecord(jobID: "job-2", changeOrderID: nil, recordID: recordID) else {
        expect(false, "check: an account switch mid-check confirms nothing"); return
    }
}

@MainActor
func testSignedCopy() async throws {
    let h = StoreHarness(tag: "copy")
    defer { h.cleanup() }
    let record = NativeSignedRecord(
        recordID: recordID, recordDigest: digest, documentType: "estimate", signedAt: "2026-10-03T14:05:09.000Z",
        signatureMethod: "typed", sealKeyID: "k2026-10",
        events: [.init(type: "signed", at: "2026-10-03T14:05:09.000Z", ip: "203.0.113.9")],
        sealed: testSealedRecord(),
        pdfFilename: "signed-estimate-3f0c1a2b.pdf", pdfData: Data("%PDF-1.4\n".utf8)
    )
    h.records.results = [.success(record)]
    let result = await h.store.fetchSignedCopy(jobID: "job-1", changeOrderID: nil, recordID: recordID)
    guard case let .success(copy) = result else { expect(false, "copy: the signed copy is fetched (\(result))"); return }
    expectEqual(copy.fileURL.lastPathComponent, "signed-estimate-3f0c1a2b.pdf", "copy: written under the record's filename")
    expectEqual(try? Data(contentsOf: copy.fileURL), record.pdfData, "copy: with the PDF bytes")
    expectEqual(h.records.calls.last?.recordID, recordID, "copy: for the approval's record")
    copy.discard()
    expect(!FileManager.default.fileExists(atPath: copy.fileURL.path), "copy: discarded after the share sheet")

    h.records.results = [.failure(.pending)]
    expectEqual(await h.store.fetchSignedCopy(jobID: "job-1", changeOrderID: nil, recordID: recordID), .failure(.pending),
                "copy: a pending record says so")
    h.records.results = [.failure(.rejectedSession)]
    expectEqual(await h.store.fetchSignedCopy(jobID: "job-1", changeOrderID: "co-1", recordID: recordID), .failure(.rejectedSession),
                "copy: a rejected session that can't refresh asks to sign in")
    expectEqual(h.records.calls.last?.changeOrderID, "co-1", "copy: a change order's record")

    // The account changes while the copy is in flight: nothing is shown.
    h.records.results = [.success(record)]
    h.records.beforeReturn = { h.store.testSeedNativeSignedInOwner(subject: "another-subject", binding: StoreHarness.binding) }
    expectEqual(await h.store.fetchSignedCopy(jobID: "job-1", changeOrderID: nil, recordID: recordID), .failure(.accountChanged),
                "copy: an account switch mid-fetch shows nothing")
}

// MARK: - Main

@main
struct ESignatureTests {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        try testSnapshotAdditions()
        try testAdditionsKeepOptionsAndValidity()
        try testSettingsRoundTrip()
        try testApprovalDecode()
        try testStrokeScaling()
        testAuditTrail()
        try testLegacyAndManualLabels()
        try await testTransport()
        testCopyRules(root: root)
        try await testReviewDraftAndLink()
        try testChangeOrderSnapshot()
        try await testSignedCopy()
        try await testSignatureCheck()
        if failures == 0 {
            print("PASS: e-signature tests (\(checks) checks)")
        } else {
            print("e-signature tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }
}
