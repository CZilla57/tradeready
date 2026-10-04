import Foundation

/// Phase 19 (e-signatures with audit trail): the device's side of
/// `docs/superpowers/specs/2026-10-03-esignature-upgrade-design.md`.
///
/// - §3.4 / §11.1 A: the snapshot additions the device builds at create-link
///   time (`scope`, `terms`, `businessContact`, `signature`, `esign`). They are
///   additive: the Phase 25 options and the Phase 32 validity fields are left
///   exactly as the existing builders made them.
/// - §3.7 / §11.1 B: the owner-facing reading of an approval — signed with an
///   audit trail, a typed-name approval from before the audit trail, or a
///   change-order decision the owner recorded on site — and the audit trail
///   built from the server-owned `signatureEvidence`.
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

    // MARK: - What an approval is (§3.7)

    /// An e-signed approval: the customer agreed to electronic records (or
    /// used an older page without that step), typed their name, and the
    /// Worker sealed a record.
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
        /// The sealed trail plus the signing itself, oldest first.
        let trail: [AuditEvent]

        var methodLabel: String {
            method == "typed_drawn" ? "Typed name and drawn signature" : "Typed name"
        }

        var consentLabel: String {
            consentVersion.map { "Agreed to use electronic records (disclosure version \($0))" }
                ?? "Signed on an older page without the electronic-records step"
        }
    }

    enum ApprovalEvidence: Equatable, Sendable {
        case signed(SignedApproval)
        /// An approval from before the audit trail: the typed name only.
        case typedName(signerName: String?, approvedAt: String?)
        /// A change-order decision the owner recorded on site.
        case recordedByOwner(decision: String, decidedAt: String)
    }

    /// The approved estimate or change-order approval, or `nil` for anything
    /// else (undecided, declined: a decline is not a signature).
    static func evidence(for approval: Canonical.EstimateApproval?) -> ApprovalEvidence? {
        guard let approval, approval.decision == "approved" else { return nil }
        guard let recordID = nonEmpty(approval.signatureRecordId) else {
            return .typedName(signerName: nonEmpty(approval.signerName), approvedAt: nonEmpty(approval.consentAt))
        }
        let evidence: [String: Canonical.JSONValue]
        if case let .object(fields)? = approval.preservation.unknownFields["signatureEvidence"] {
            evidence = fields
        } else {
            evidence = [:]
        }
        var trail: [AuditEvent] = []
        if case let .array(rawEvents)? = evidence["events"] {
            for case let .object(event) in rawEvents {
                guard case let .string(type)? = event["type"], case let .string(at)? = event["at"] else { continue }
                trail.append(AuditEvent(type: type, at: at, ip: string(event["ip"])))
            }
        }
        if let signedAt = nonEmpty(approval.consentAt) {
            trail.append(AuditEvent(type: "signed", at: signedAt, ip: approval.ip))
        }
        return .signed(SignedApproval(
            recordID: recordID,
            recordDigest: nonEmpty(approval.recordDigest),
            signerName: approval.signerName ?? "",
            signedAt: nonEmpty(approval.consentAt),
            method: nonEmpty(approval.signatureMethod),
            ip: nonEmpty(approval.ip),
            userAgent: nonEmpty(approval.userAgent),
            consentVersion: double(evidence["consentVersion"]).map { Int($0) },
            drawing: Drawing(json: evidence["drawn"]),
            trail: orderedTrail(trail)
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
