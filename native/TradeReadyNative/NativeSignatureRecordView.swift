import SwiftUI

/// Phase 19 (e-signatures with audit trail, spec 2026-10-03 §3.7): the
/// owner's view of a customer's signature, the settings for the signing page,
/// and nothing else. The wording never calls a signature "legally binding"
/// (owner decision 19-Q5).

/// Job detail: the customer's signature on the current estimate. Shows
/// nothing until the customer approves (a decline is not a signature).
struct NativeEstimateSignatureSection: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String

    var body: some View {
        if let evidence = NativeESignature.evidence(for: store.activeEstimateApproval(jobID: jobID)) {
            Section("Customer signature") {
                NativeApprovalEvidenceRows(evidence: evidence, jobID: jobID, changeOrderID: nil)
            }
        }
    }
}

/// Under a decided change-order row: the customer's signature (its details
/// collapsed under the "Signed by" line once the Worker confirms it), a
/// typed-name approval from before the audit trail, or the owner's on-site
/// record.
struct NativeChangeOrderEvidenceRows: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String
    let changeOrderID: String

    var body: some View {
        if let order = store.changeOrders(for: jobID).first(where: { $0.id == changeOrderID }),
           let evidence = NativeESignature.evidence(for: order) {
            NativeApprovalEvidenceRows(
                evidence: evidence, jobID: jobID, changeOrderID: changeOrderID, collapsesDetails: true
            )
        }
    }
}

/// The rows for one approval. Claiming an e-signature: unconfirmed (the
/// customer's name and time as the decision, with the check's status) until
/// `POST /api/esign/record` returns the sealed record; then the "Signed by"
/// line, the drawn mark, "Signed copy" and the audit trail, all from that
/// record (spec §11.11). Before the audit trail: the typed-name label and the
/// name. Recorded on site: the owner-recorded label.
struct NativeApprovalEvidenceRows: View {
    let evidence: NativeESignature.ApprovalEvidence
    let jobID: String
    let changeOrderID: String?
    var collapsesDetails = false

    var body: some View {
        switch evidence {
        case let .claimedSignature(claim):
            NativeClaimedSignatureRows(
                claim: claim, jobID: jobID, changeOrderID: changeOrderID, collapsesDetails: collapsesDetails
            )
        case let .typedName(signerName, approvedAt):
            Label(NativeESignature.typedNameApprovalLabel, systemImage: "character.cursor.ibeam")
            if let signerName {
                LabeledContent("Customer", value: signerName)
            }
            if let approvedAt {
                LabeledContent("Approved", value: NativeESignature.displayTimestamp(approvedAt))
            }
        case let .recordedByOwner(_, decidedAt):
            VStack(alignment: .leading, spacing: 2) {
                Label(NativeESignature.ownerRecordedLabel, systemImage: "person.crop.circle.badge.checkmark")
                Text("Recorded \(NativeESignature.displayTimestamp(decidedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// An approval whose job blob claims an e-signature. Nothing from the blob is
/// shown as a signature: the rows ask the Worker for the sealed record and
/// show "Signed by" only from its answer.
struct NativeClaimedSignatureRows: View {
    @EnvironmentObject private var store: AppStore
    let claim: NativeESignature.ClaimedSignature
    let jobID: String
    let changeOrderID: String?
    var collapsesDetails = false

    @State private var confirmation: NativeESignature.SignatureConfirmation = .unconfirmed
    @State private var isChecking = false

    var body: some View {
        Group {
            if case let .confirmed(signed) = confirmation {
                if collapsesDetails {
                    DisclosureGroup {
                        NativeSignedRecordRows(signed: signed, jobID: jobID, changeOrderID: changeOrderID)
                    } label: {
                        NativeSignedTitle(signed: signed)
                    }
                } else {
                    NativeSignedTitle(signed: signed)
                    NativeSignedRecordRows(signed: signed, jobID: jobID, changeOrderID: changeOrderID)
                }
            } else {
                unconfirmedRows
            }
        }
        .task(id: claim.recordID) { await check() }
    }

    @ViewBuilder
    private var unconfirmedRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(NativeESignature.statusLabel(confirmation) ?? NativeESignature.unconfirmedLabel,
                  systemImage: confirmation == .noRecord ? "exclamationmark.triangle" : "clock")
            if let detail = NativeESignature.statusDetail(confirmation) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        if let signerName = claim.signerName {
            LabeledContent("Customer", value: signerName)
        }
        if let approvedAt = claim.approvedAt {
            LabeledContent("Approved", value: NativeESignature.displayTimestamp(approvedAt))
        }
        switch confirmation {
        case .sealing, .unverifiable:
            Button {
                Task { await check() }
            } label: {
                Label(isChecking ? "Checking…" : "Check again", systemImage: "arrow.clockwise")
            }
            .disabled(isChecking)
        default:
            EmptyView()
        }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        let result = await store.checkSignatureRecord(
            jobID: jobID, changeOrderID: changeOrderID, recordID: claim.recordID
        )
        isChecking = false
        confirmation = NativeESignature.confirmation(for: claim, check: result)
    }
}

/// A confirmed signature's mark, "Signed copy" (the sealed PDF through the
/// share sheet) and audit trail, all from the Worker's sealed record.
struct NativeSignedRecordRows: View {
    @EnvironmentObject private var store: AppStore
    let signed: NativeESignature.SignedApproval
    let jobID: String
    let changeOrderID: String?

    @State private var isFetchingCopy = false
    @State private var signedCopy: NativeSignedCopy?
    @State private var liveTrail: [NativeESignature.AuditEvent]?
    @State private var copyError: String?

    var body: some View {
        if let drawing = signed.drawing {
            NativeSignatureMark(drawing: drawing, signerName: signed.signerName)
        }
        signedCopyButton
        DisclosureGroup("Audit trail") {
            auditTrail
        }
    }

    private var signedCopyButton: some View {
        Button {
            fetchCopy()
        } label: {
            if isFetchingCopy {
                Label("Preparing signed copy…", systemImage: "hourglass")
            } else {
                Label("Signed copy", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(isFetchingCopy)
        .accessibilityHint("Shares the signed PDF with its signature certificate")
        .sheet(item: $signedCopy, onDismiss: discardCopy) { copy in
            NativeActivitySheet(items: [copy.fileURL])
        }
        .alert("Couldn’t get the signed copy", isPresented: Binding(
            get: { copyError != nil },
            set: { if !$0 { copyError = nil } }
        )) {
            Button("OK", role: .cancel) { copyError = nil }
        } message: {
            Text(copyError ?? "Please try again.")
        }
    }

    @ViewBuilder
    private var auditTrail: some View {
        ForEach(Array((liveTrail ?? signed.trail).enumerated()), id: \.offset) { _, event in
            VStack(alignment: .leading, spacing: 2) {
                Text(event.label)
                Text(eventDetail(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        LabeledContent("Consent", value: signed.consentLabel)
        LabeledContent("Signature", value: signed.methodLabel)
        if let ip = signed.ip {
            LabeledContent("IP address", value: ip)
        }
        if let userAgent = signed.userAgent {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browser")
                Text(userAgent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
        if let digest = signed.recordDigest {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fingerprint (SHA-256)")
                Text(NativeESignature.fingerprintGroups(digest))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("Record ID")
            Text(signed.recordID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func eventDetail(_ event: NativeESignature.AuditEvent) -> String {
        let time = NativeESignature.displayTimestamp(event.at)
        guard let ip = event.ip else { return time }
        return "\(time) · IP \(ip)"
    }

    private func fetchCopy() {
        guard !isFetchingCopy else { return }
        isFetchingCopy = true
        Task {
            let result = await store.fetchSignedCopy(
                jobID: jobID,
                changeOrderID: changeOrderID,
                recordID: signed.recordID
            )
            isFetchingCopy = false
            switch result {
            case let .success(copy):
                if !copy.record.events.isEmpty { liveTrail = copy.record.events }
                signedCopy = copy
            case let .failure(error):
                copyError = error.errorDescription
            }
        }
    }

    private func discardCopy() {
        signedCopy?.discard()
        signedCopy = nil
    }
}

/// "Signed by Pat Lee · Oct 3, 2026 at 7:05 AM" over the signature method,
/// read as one element.
struct NativeSignedTitle: View {
    let signed: NativeESignature.SignedApproval

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(NativeESignature.signedTitle(signerName: signed.signerName, signedAt: signed.signedAt))
                Text(signed.methodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "signature")
        }
        .accessibilityElement(children: .combine)
    }
}

/// The customer's drawn mark, redrawn from its vector strokes with `Path`.
struct NativeSignatureMark: View {
    let drawing: NativeESignature.Drawing
    let signerName: String

    var body: some View {
        NativeSignatureShape(drawing: drawing)
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .aspectRatio(drawing.aspectRatio, contentMode: .fit)
            .frame(maxWidth: 280)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
            .accessibilityElement()
            .accessibilityLabel(signerName.isEmpty ? "Drawn signature" : "Drawn signature of \(signerName)")
            .accessibilityAddTraits(.isImage)
    }
}

private struct NativeSignatureShape: Shape {
    let drawing: NativeESignature.Drawing

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let strokes = drawing.scaledStrokes(targetWidth: Double(rect.width), targetHeight: Double(rect.height))
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            let start = CGPoint(x: rect.minX + first.x, y: rect.minY + first.y)
            if stroke.count == 1 {
                path.addEllipse(in: CGRect(x: start.x - 1, y: start.y - 1, width: 2, height: 2))
                continue
            }
            path.move(to: start)
            for point in stroke.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.x, y: rect.minY + point.y))
            }
        }
        return path
    }
}

/// Settings ▸ Business Profile ▸ Customer documents: the signing page's
/// optional drawn signature and the owner's own agreement terms. Both are
/// settings-blob fields; the next approval link freezes them.
struct NativeESignatureSettingsRows: View {
    @EnvironmentObject private var store: AppStore

    private var termsBinding: Binding<String> {
        Binding(
            get: { store.settings.estimateTerms },
            set: { store.settings.estimateTerms = Self.capped($0) }
        )
    }

    var body: some View {
        Toggle(isOn: $store.settings.signatureDrawPad) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Signature pad")
                Text("Customers can add a drawn signature when they approve online. Their typed name is always their signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        LabeledField(label: "Agreement terms") {
            TextField("Optional", text: termsBinding, axis: .vertical)
                .lineLimit(3...10)
                .accessibilityHint("Shown on your estimates and on the page where customers approve them")
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(NativeESignature.termsHelp)
            if store.settings.estimateTerms.utf16.count > 3_000 {
                Text("\(store.settings.estimateTerms.utf16.count.formatted()) of 4,000 characters")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// At most 4,000 UTF-16 units (the Worker's limit), cut on a character
    /// boundary.
    static func capped(_ text: String) -> String {
        guard text.utf16.count > NativeESignature.maxTermsLength else { return text }
        var result = ""
        var units = 0
        for character in text {
            let width = String(character).utf16.count
            guard units + width <= NativeESignature.maxTermsLength else { break }
            result.append(character)
            units += width
        }
        return result
    }
}
