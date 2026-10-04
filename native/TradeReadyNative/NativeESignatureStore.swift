import Foundation

/// A signed copy written to a temporary file for the share sheet. The
/// presenting view removes it (`discard()`) when the sheet closes.
struct NativeSignedCopy: Identifiable, Equatable {
    let record: NativeSignedRecord
    let fileURL: URL
    var id: String { record.recordID }

    func discard() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

/// Phase 19 (e-signatures with audit trail, spec 2026-10-03 §3.4, §3.7):
/// the AppStore side — the snapshot additions every approval link carries,
/// and the owner's signed copy from `POST /api/esign/record`.
extension AppStore {
    // MARK: Snapshot additions (§3.4)

    /// The business settings the additions read. `timeZone` is the owner's
    /// zone for the signature certificate: the device zone for a new review,
    /// the reviewed snapshot's own zone when that review is rebuilt to prove
    /// nothing changed.
    func esignSnapshotInputs(timeZone: String?) -> NativeESignature.SnapshotInputs {
        NativeESignature.SnapshotInputs(
            terms: settings.estimateTerms,
            businessPhone: settings.phone,
            businessEmail: settings.email,
            drawPad: settings.signatureDrawPad,
            timeZone: timeZone
        )
    }

    /// An estimate snapshot (`CanonicalUIAdapters.estimateApprovalSnapshot`)
    /// plus the additions: `scope` is the job's description.
    func esignEstimateSnapshot(
        _ base: Canonical.EstimateApprovalSnapshot,
        job: Canonical.Job,
        timeZone: String?
    ) throws -> Canonical.EstimateApprovalSnapshot {
        try NativeESignature.addingSnapshotFields(
            to: base,
            scope: job.description,
            inputs: esignSnapshotInputs(timeZone: timeZone),
            kind: .estimate
        )
    }

    /// A change-order snapshot (`NativeChangeOrderApprovalSnapshot.build`)
    /// plus the additions: `scope` is the change order's description.
    func esignChangeOrderSnapshot(
        _ base: Canonical.EstimateApprovalSnapshot,
        order: Canonical.ChangeOrder,
        timeZone: String?
    ) throws -> Canonical.EstimateApprovalSnapshot {
        try NativeESignature.addingSnapshotFields(
            to: base,
            scope: order.description,
            inputs: esignSnapshotInputs(timeZone: timeZone),
            kind: .changeOrder
        )
    }

    /// Why a change order's approval link can't be prepared from the current
    /// settings and description, or `nil` when the additions are fine.
    func changeOrderESignProblem(jobID: String, changeOrderID: String) -> String? {
        guard let order = changeOrders(for: jobID).first(where: { $0.id == changeOrderID }),
              NativeChangeOrderStatus.isApprovalEligible(order)
        else { return nil }
        do {
            _ = try NativeESignature.snapshotFields(
                scope: order.description,
                inputs: esignSnapshotInputs(timeZone: TimeZone.current.identifier),
                kind: .changeOrder
            )
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
        }
    }

    // MARK: Signed copy (§3.7, §11.1 C)

    /// Fetches the signed record and PDF for one e-signed approval and writes
    /// the PDF for the share sheet. Read-only on the server and on this
    /// device; the verified owner is rechecked after the await so a copy
    /// fetched for one account is never shown to the next.
    func fetchSignedCopy(
        jobID: String,
        changeOrderID: String?,
        recordID: String
    ) async -> Result<NativeSignedCopy, NativeESignatureRecordError> {
        guard let subject = esignOwnerSubject else { return .failure(.rejectedSession) }
        guard let service = configuredESignatureRecordService() else { return .failure(.invalidConfiguration) }

        func request(_ credentials: NativeSyncCredentials) async throws -> NativeSignedRecord {
            try await service.fetchRecord(
                jobID: jobID,
                changeOrderID: changeOrderID,
                recordID: recordID,
                sessionBytes: credentials.sessionBytes
            )
        }

        let record: NativeSignedRecord
        do {
            guard let credentials = esignOwnerCredentials(), credentials.subject == subject else {
                return .failure(.malformedSession)
            }
            do {
                record = try await request(credentials)
            } catch NativeESignatureRecordError.rejectedSession {
                guard await esignRefreshOwnerSession(),
                      let fresh = esignOwnerCredentials(),
                      fresh.subject == subject,
                      subject == esignOwnerSubject
                else { return .failure(.rejectedSession) }
                record = try await request(fresh)
            }
        } catch let error as NativeESignatureRecordError {
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }
        guard subject == esignOwnerSubject else { return .failure(.accountChanged) }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "TradeReadySignedCopies", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: record.pdfFilename, directoryHint: .notDirectory)
            try record.pdfData.write(to: url, options: .atomic)
            return .success(NativeSignedCopy(record: record, fileURL: url))
        } catch {
            return .failure(.saveFailed)
        }
    }

    private func configuredESignatureRecordService() -> (any NativeESignatureRecordFetching)? {
        if let esignRecordServiceOverride { return esignRecordServiceOverride }
        guard let endpoint = try? BuildEnvironment.endpoint("api/esign/record") else { return nil }
        return NativeESignatureRecordService(endpoint: endpoint)
    }
}
