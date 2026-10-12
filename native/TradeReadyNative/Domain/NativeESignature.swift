import Foundation

/// Phase 19 (e-signatures with audit trail): the device's side of
/// `docs/superpowers/specs/2026-10-03-esignature-upgrade-design.md`.
///
/// - §3.4 / §11.1 A: the snapshot additions the device builds at create-link
///   time (`scope`, `terms`, `businessContact`, `signature`, `esign`). They are
///   additive: the Phase 25 options and the Phase 32 validity fields are left
///   exactly as the existing builders made them.
/// - §3.7 / §11.1 B: the owner-facing reading of an approval — an approval
///   that claims an e-signature, a typed-name approval from before the audit
///   trail, or a change-order decision the owner recorded on site.
/// - §11.11 (security review 2026-10-04): an approval that claims a signature
///   is UNCONFIRMED until `POST /api/esign/record` returns that sealed record.
///   The job blob (`signatureRecordId`, `signatureEvidence`, `ip`, …) is the
///   owner's own writable copy, so nothing from it is ever shown as a sealed
///   record: the signer, drawing, IP, trail, fingerprint and record id the app
///   shows as signed all come from the Worker's answer.
///
/// Pure: Foundation and the canonical models only. Wording here is
/// owner-facing; it never calls a signature "legally binding" or similar
/// (spec §7, owner decision 19-Q5). The customer-facing disclosure text lives
/// with the Worker and is pending one lawyer review (19-Q2); the app shows
/// only its version.
enum NativeESignature {
    /// `snapshot.esign.version` this build sends.
    static let snapshotVersion = 1
    /// The Worker's create-link limits (`backend-workers/lib/esign/validate.js`),
    /// in UTF-16 code units like JavaScript's `String.length`.
    static let maxScopeLength = 4_000
    static let maxTermsLength = 4_000
    static let maxPhoneLength = 40
    static let maxEmailLength = 254
    static let maxTimeZoneLength = 64
    /// The signing page's drawing box (§3.3).
    static let drawingWidth = 600
    static let drawingHeight = 200
    static let maxDrawingStrokes = 40
    static let maxDrawingPoints = 2_000

    static let typedNameApprovalLabel = "Typed-name approval (before audit trail)"
    static let ownerRecordedLabel = "Recorded by you — not signed by the customer"
    static let termsHelp = "Your own terms. TradeReady doesn't provide legal terms."
    static let accountDeletionWarning = "Signed estimate records are deleted with your account. Save any copies you need first. Your customers keep the copies they downloaded or were emailed."

    // MARK: - Snapshot additions (§3.4)

    enum DocumentKind: Equatable, Sendable {
        case estimate
        case changeOrder
    }

    /// The business settings the additions read. `timeZone` is the owner's
    /// IANA zone for the signature certificate; an unusable one is omitted
    /// (the Worker then falls back to `validUntilTimeZone`, else UTC).
    struct SnapshotInputs: Equatable, Sendable {
        var terms: String
        var businessPhone: String
        var businessEmail: String
        var drawPad: Bool
        var timeZone: String?
    }

    /// Why the additions could not be built. Each message names the fix; the
    /// Worker would refuse the same snapshot with a 400.
    enum SnapshotError: LocalizedError, Equatable {
        case scopeTooLong(DocumentKind)
        case termsTooLong
        case businessPhoneTooLong
        case businessEmailInvalid

        var errorDescription: String? {
            switch self {
            case .scopeTooLong(.estimate):
                "The job description is longer than 4,000 characters. Shorten it, then send the estimate again."
            case .scopeTooLong(.changeOrder):
                "This change order’s description is longer than 4,000 characters. Shorten it, then send it for approval again."
            case .termsTooLong:
                "Your agreement terms are longer than 4,000 characters. Shorten them in Settings › Business Profile, then try again."
            case .businessPhoneTooLong:
                "Your business phone is longer than 40 characters. Shorten it in Settings › Business Profile, then try again."
            case .businessEmailInvalid:
                "Your business email doesn’t look like an email address. Fix it in Settings › Business Profile, then try again."
            }
        }
    }

    /// The §3.4 keys, validated against the Worker's limits.
    struct SnapshotFields: Equatable {
        var scope: String?
        var terms: String?
        var businessContact: Canonical.EstimateApprovalSnapshot.BusinessContact?
        var signature: Canonical.EstimateApprovalSnapshot.SignatureOptions
        var esign: Canonical.EstimateApprovalSnapshot.ESign
    }

    /// Text is trimmed; an empty value is omitted rather than sent as `""`.
    /// A change order carries no `terms`: the estimate's terms govern the
    /// job, and a change order signed under newer settings text could
    /// contradict them.
    static func snapshotFields(scope: String?, inputs: SnapshotInputs, kind: DocumentKind) throws -> SnapshotFields {
        let scope = trimmed(scope ?? "")
        guard scope.utf16.count <= maxScopeLength else { throw SnapshotError.scopeTooLong(kind) }

        var terms: String?
        if kind == .estimate {
            let text = trimmed(inputs.terms)
            guard text.utf16.count <= maxTermsLength else { throw SnapshotError.termsTooLong }
            terms = text.isEmpty ? nil : text
        }

        let phone = trimmed(inputs.businessPhone)
        guard phone.utf16.count <= maxPhoneLength else { throw SnapshotError.businessPhoneTooLong }
        let email = trimmed(inputs.businessEmail)
        guard email.isEmpty || isEmailAddress(email) else { throw SnapshotError.businessEmailInvalid }

        let zone = inputs.timeZone.map(trimmed) ?? ""
        let usableZone = !zone.isEmpty && zone.utf16.count <= maxTimeZoneLength && TimeZone(identifier: zone) != nil
        return SnapshotFields(
            scope: scope.isEmpty ? nil : scope,
            terms: terms,
            businessContact: phone.isEmpty && email.isEmpty
                ? nil
                : .init(phone: phone.isEmpty ? nil : phone, email: email.isEmpty ? nil : email),
            signature: .init(drawPad: inputs.drawPad),
            esign: .init(version: snapshotVersion, timeZone: usableZone ? zone : nil)
        )
    }

    /// `snapshot` plus the §3.4 additions. Every other key — the Phase 25
    /// options, the Phase 32 validity fields, unknown fields — is untouched.
    static func addingSnapshotFields(
        to snapshot: Canonical.EstimateApprovalSnapshot,
        scope: String?,
        inputs: SnapshotInputs,
        kind: DocumentKind
    ) throws -> Canonical.EstimateApprovalSnapshot {
        let fields = try snapshotFields(scope: scope, inputs: inputs, kind: kind)
        var result = snapshot
        result.scope = fields.scope
        result.terms = fields.terms
        result.businessContact = fields.businessContact
        result.signature = fields.signature
        result.esign = fields.esign
        return result
    }

    /// The Worker's `isEmailAddress`: at most 254 characters, one `@`, a dot
    /// in the domain, none of the address-breaking characters, no controls.
    static func isEmailAddress(_ value: String) -> Bool {
        guard value.utf16.count <= maxEmailLength,
              !value.unicodeScalars.contains(where: isControl)
        else { return false }
        return value.range(of: emailPattern, options: .regularExpression) != nil
    }

    private static let emailPattern = #"^[^\s@<>()\[\]",;:\\]+@[^\s@<>()\[\]",;:\\]+\.[^\s@<>()\[\]",;:\\]+$"#

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Drawn signature (§3.3)

    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// Vector strokes on the signing page's box (y grows downward).
    struct Drawing: Equatable, Sendable {
        let width: Double
        let height: Double
        let strokes: [[Point]]

        /// Reads `{w, h, strokes: [[[x, y, tMs], …], …]}`. A malformed or
        /// oversized drawing, or one with fewer than two points (the Worker's
        /// "not drawn"), is `nil`.
        init?(json: Canonical.JSONValue?) {
            guard case let .object(fields)? = json,
                  let width = NativeESignature.double(fields["w"]), width > 0,
                  let height = NativeESignature.double(fields["h"]), height > 0,
                  case let .array(rawStrokes)? = fields["strokes"],
                  rawStrokes.count <= NativeESignature.maxDrawingStrokes
            else { return nil }
            var strokes: [[Point]] = []
            var total = 0
            for rawStroke in rawStrokes {
                guard case let .array(rawPoints) = rawStroke, !rawPoints.isEmpty else { return nil }
                total += rawPoints.count
                guard total <= NativeESignature.maxDrawingPoints else { return nil }
                var stroke: [Point] = []
                for rawPoint in rawPoints {
                    guard case let .array(coordinates) = rawPoint, coordinates.count >= 2,
                          let x = NativeESignature.double(coordinates[0]),
                          let y = NativeESignature.double(coordinates[1]),
                          (0...width).contains(x), (0...height).contains(y)
                    else { return nil }
                    stroke.append(Point(x: x, y: y))
                }
                strokes.append(stroke)
            }
            guard total >= 2 else { return nil }
            self.width = width
            self.height = height
            self.strokes = strokes
        }

        /// The strokes scaled into a `targetWidth` × `targetHeight` box:
        /// `x * W / w`, `y * H / h`. A one-point stroke stays one point (a dot).
        func scaledStrokes(targetWidth: Double, targetHeight: Double) -> [[Point]] {
            strokes.map { stroke in
                stroke.map { Point(x: $0.x * targetWidth / width, y: $0.y * targetHeight / height) }
            }
        }

        /// The drawing's width-to-height ratio (3 for the 600 × 200 pad).
        var aspectRatio: Double { width / height }
    }

    // MARK: - Audit trail (§3.5 events, §3.7)

    struct AuditEvent: Equatable, Sendable {
        let type: String
        let at: String
        let ip: String?

        init(type: String, at: String, ip: String? = nil) {
            self.type = type
            self.at = at
            self.ip = ip?.isEmpty == true ? nil : ip
        }

        var label: String {
            switch type {
            case "link_created": "Approval link created by you"
            case "viewed": "Customer opened the link"
            case "declined": "Customer declined"
            case "signed": "Customer signed"
            case "copy_emailed": "Signed copy emailed to the customer"
            case "copy_email_failed": "Signed copy email didn’t send"
            case "copy_downloaded": "Signed copy downloaded"
            default: Self.sentenceCase(type.replacingOccurrences(of: "_", with: " "))
            }
        }

        private static func sentenceCase(_ text: String) -> String {
            guard let first = text.first else { return "Event" }
            return String(first).uppercased() + String(text.dropFirst())
        }
    }

    /// Oldest first by timestamp; ties and unreadable timestamps keep their
    /// original order, and unreadable ones go last.
    static func orderedTrail(_ events: [AuditEvent]) -> [AuditEvent] {
        events.enumerated().sorted { lhs, rhs in
            switch (date(lhs.element.at), date(rhs.element.at)) {
            case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - What an approval is (§3.7, §11.11)

    /// A signature as the Worker sealed it: read from the sealed record that
    /// `POST /api/esign/record` returned, never from the job blob.
    struct SealedRecord: Equatable, Sendable {
        let recordID: String
        let recordDigest: String
        let signerName: String
        let signedAt: String
        let method: String?
        let ip: String?
        let userAgent: String?
        /// The disclosure version agreed to; `nil` when the customer signed on
        /// a page from before the consent step.
        let consentVersion: Int?
        let drawing: Drawing?
        /// The trail sealed into the record (before the signing itself).
        let sealedEvents: [AuditEvent]
        /// The route's live log for the link, oldest first (unsealed).
        let liveEvents: [AuditEvent]
        let sealKeyID: String?
    }

    /// Reads the sealed canonical record (`record` in the answer of
    /// `POST /api/esign/record`, spec §3.5 record version 1). `nil` when it
    /// is not a version-1 record with the expected id and a typed name: a
    /// confirmation is never assembled from a partial or mismatched record.
    static func sealedRecord(
        recordID: String,
        recordDigest: String,
        sealKeyID: String?,
        record: Canonical.JSONValue,
        liveEvents: [AuditEvent]
    ) -> SealedRecord? {
        guard case let .object(fields) = record,
              double(fields["recordVersion"]) == 1,
              string(fields["recordId"]) == recordID,
              case let .object(signer)? = fields["signer"],
              let signerName = string(signer["typedName"]),
              let signedAt = string(fields["signedAt"])
        else { return nil }
        var consentVersion: Int?
        if case let .object(consent)? = fields["consent"], let version = double(consent["version"]) {
            consentVersion = Int(version)
        }
        var sealedEvents: [AuditEvent] = []
        if case let .array(rawEvents)? = fields["events"] {
            for case let .object(event) in rawEvents {
                guard let type = string(event["type"]), let at = string(event["at"]) else { continue }
                sealedEvents.append(AuditEvent(type: type, at: at, ip: string(event["ip"])))
            }
        }
        return SealedRecord(
            recordID: recordID,
            recordDigest: recordDigest,
            signerName: signerName,
            signedAt: signedAt,
            method: string(fields["signatureMethod"]),
            ip: string(fields["ip"]),
            userAgent: string(fields["userAgent"]),
            consentVersion: consentVersion,
            drawing: Drawing(json: signer["drawn"]),
            sealedEvents: sealedEvents,
            liveEvents: liveEvents,
            sealKeyID: sealKeyID
        )
    }

    /// A confirmed e-signature: built only from a `SealedRecord`.
    struct SignedApproval: Equatable, Sendable {
        let recordID: String
        let recordDigest: String?
        let signerName: String
        let signedAt: String?
        let method: String?
        let ip: String?
        let userAgent: String?
        /// The disclosure version agreed to; `nil` when the customer signed on
        /// a page from before the consent step.
        let consentVersion: Int?
        let drawing: Drawing?
        /// The live log when the Worker sent one, else the sealed trail plus
        /// the signing itself, oldest first.
        let trail: [AuditEvent]

        init(sealed: SealedRecord) {
            recordID = sealed.recordID
            recordDigest = sealed.recordDigest
            signerName = sealed.signerName
            signedAt = sealed.signedAt
            method = sealed.method
            ip = sealed.ip
            userAgent = sealed.userAgent
            consentVersion = sealed.consentVersion
            drawing = sealed.drawing
            trail = sealed.liveEvents.isEmpty
                ? NativeESignature.orderedTrail(sealed.sealedEvents + [AuditEvent(type: "signed", at: sealed.signedAt, ip: sealed.ip)])
                : NativeESignature.orderedTrail(sealed.liveEvents)
        }

        var methodLabel: String {
            method == "typed_drawn" ? "Typed name and drawn signature" : "Typed name"
        }

        var consentLabel: String {
            consentVersion.map { "Agreed to use electronic records (disclosure version \($0))" }
                ?? "Signed on an older page without the electronic-records step"
        }
    }

    /// What the job blob says about an approved link decision that claims an
    /// e-signature. Owner-writable, so it is only a reason to ask the Worker;
    /// it is never displayed as a signature record.
    struct ClaimedSignature: Equatable, Sendable {
        let recordID: String
        /// The approval's typed name and time, shown only as the decision
        /// ("Approved by …"), never as sealed evidence.
        let signerName: String?
        let approvedAt: String?
    }

    enum ApprovalEvidence: Equatable, Sendable {
        /// An approval that claims an e-signature: unconfirmed until the
        /// Worker returns its sealed record (`SignatureConfirmation`).
        case claimedSignature(ClaimedSignature)
        /// An approval from before the audit trail: the typed name only.
        case typedName(signerName: String?, approvedAt: String?)
        /// A change-order decision the owner recorded on site.
        case recordedByOwner(decision: String, decidedAt: String)
    }

    /// The approved estimate or change-order approval, or `nil` for anything
    /// else (undecided, declined: a decline is not a signature). Reads only
    /// what decides which question to ask; `signatureEvidence`, `ip` and the
    /// stored fingerprint are deliberately not read.
    static func evidence(for approval: Canonical.EstimateApproval?) -> ApprovalEvidence? {
        guard let approval, approval.decision == "approved" else { return nil }
        guard let recordID = nonEmpty(approval.signatureRecordId) else {
            return .typedName(signerName: nonEmpty(approval.signerName), approvedAt: nonEmpty(approval.consentAt))
        }
        return .claimedSignature(ClaimedSignature(
            recordID: recordID,
            signerName: nonEmpty(approval.signerName),
            approvedAt: nonEmpty(approval.consentAt)
        ))
    }

    /// A change order: the owner's on-site decision wins (the Worker refuses
    /// a link on a decided order), otherwise its link approval.
    static func evidence(for order: Canonical.ChangeOrder) -> ApprovalEvidence? {
        if let manual = order.manualDecision {
            return .recordedByOwner(decision: manual.decision, decidedAt: manual.decidedAt)
        }
        return evidence(for: order.approval)
    }

    // MARK: - Confirming a claimed signature (§11.11)

    /// The answer of `POST /api/esign/record` for one claimed record.
    enum RecordCheck: Equatable, Sendable {
        case found(SealedRecord)
        /// 404: the Worker holds no signature for this approval.
        case notFound
        /// 503 `record_pending`: the Worker holds it but it isn't sealed yet.
        case pending
        /// Anything else (offline, session, unexpected answer): not checked.
        case failed(String)
    }

    enum SignatureConfirmation: Equatable, Sendable {
        /// Not checked yet, or being checked.
        case unconfirmed
        case confirmed(SignedApproval)
        case sealing
        /// Downgraded: no Worker-held signature exists for this approval.
        case noRecord
        /// The check failed; still unconfirmed, with the reason.
        case unverifiable(String)

        var isConfirmed: Bool {
            if case .confirmed = self { return true }
            return false
        }
    }

    static let unconfirmedLabel = "Signature record not confirmed yet"
    static let sealingLabel = "Signature record still being sealed"
    static let noRecordLabel = "No signature record found for this approval"
    static let unverifiableLabel = "Couldn’t check the signature record"

    /// The confirmation a check yields for a claim. Only a sealed record with
    /// the claimed id confirms; anything else leaves the approval unconfirmed
    /// or downgrades it.
    static func confirmation(for claim: ClaimedSignature, check: RecordCheck) -> SignatureConfirmation {
        switch check {
        case let .found(sealed):
            guard sealed.recordID == claim.recordID else {
                return .unverifiable("The signature service returned a different record.")
            }
            return .confirmed(SignedApproval(sealed: sealed))
        case .notFound: return .noRecord
        case .pending: return .sealing
        case let .failed(reason): return .unverifiable(reason)
        }
    }

    /// The status line for an approval that isn't confirmed.
    static func statusLabel(_ confirmation: SignatureConfirmation) -> String? {
        switch confirmation {
        case .confirmed: nil
        case .unconfirmed: unconfirmedLabel
        case .sealing: sealingLabel
        case .noRecord: noRecordLabel
        case .unverifiable: unverifiableLabel
        }
    }

    /// The explanation under that status line.
    static func statusDetail(_ confirmation: SignatureConfirmation) -> String? {
        switch confirmation {
        case .confirmed: nil
        case .unconfirmed: "Checking with TradeReady…"
        case .sealing: "The customer’s signature was received and will be sealed shortly. Check again in a few minutes."
        case .noRecord: "TradeReady holds no signed record for this approval, so treat it as an approval without a signature record."
        case let .unverifiable(reason): reason
        }
    }

    // MARK: - Display

    /// "Signed by Pat Lee · Oct 3, 2026 at 7:05 AM" (the name alone when the
    /// time is unknown).
    static func signedTitle(
        signerName: String,
        signedAt: String?,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let name = signerName.isEmpty ? "the customer" : signerName
        guard let signedAt else { return "Signed by \(name)" }
        return "Signed by \(name) · \(displayTimestamp(signedAt, timeZone: timeZone, locale: locale))"
    }

    /// A server timestamp in the owner's zone ("Oct 3, 2026 at 7:05 AM");
    /// the raw text when it can't be read.
    static func displayTimestamp(
        _ value: String,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        guard let date = date(value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The record fingerprint in groups of eight for reading aloud or
    /// comparing by eye.
    static func fingerprintGroups(_ digest: String) -> String {
        var groups: [String] = []
        var current = ""
        for character in digest {
            current.append(character)
            if current.count == 8 {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.joined(separator: " ")
    }

    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func string(_ value: Canonical.JSONValue?) -> String? {
        if case let .string(text)? = value, !text.isEmpty { return text }
        return nil
    }

    private static func double(_ value: Canonical.JSONValue?) -> Double? {
        guard case let .number(number)? = value else { return nil }
        let result = NSDecimalNumber(decimal: number).doubleValue
        return result.isFinite ? result : nil
    }
}
