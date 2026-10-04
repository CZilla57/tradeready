import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Phase 19 (spec 2026-10-03 §3.5 "New routes", §11.1 C): the owner app's
/// client for `POST /api/esign/record`, which returns a signed approval's
/// sealed record, its live event log and the signed PDF. Same bearer auth
/// as `create-link`; the device sends no owner identifier.
enum NativeESignatureRecordError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case rejectedSession
    case notFound
    case pending
    case rateLimited
    case invalidResponse
    case unavailable
    /// The signed-in account changed while the copy was being fetched.
    case accountChanged
    /// The PDF arrived but could not be written for the share sheet.
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Signed copies aren’t available in this build."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again, then try again."
        case .notFound:
            "No signed record was found for this approval. Pull down to refresh the job, then try again."
        case .pending:
            "The signed record is still being prepared. Try again in a few minutes."
        case .rateLimited:
            "Too many signed copies were requested. Wait a moment and try again."
        case .invalidResponse:
            "The signature service returned an unexpected response."
        case .unavailable:
            "The signature service is unavailable. Check your connection and try again."
        case .accountChanged:
            "The signed-in account changed, so the signed copy wasn’t opened."
        case .saveFailed:
            "The signed copy couldn’t be prepared on this device. Try again."
        }
    }
}

/// One signed record as the owner app uses it: the fingerprint, the live
/// audit trail and the signed PDF's bytes.
struct NativeSignedRecord: Equatable, Sendable {
    let recordID: String
    let recordDigest: String
    let documentType: String
    let signedAt: String
    let signatureMethod: String?
    let sealKeyID: String?
    /// The live event log for the link, oldest first (unsealed; includes
    /// later copy downloads and emails).
    let events: [NativeESignature.AuditEvent]
    let pdfFilename: String
    let pdfData: Data
}

protocol NativeESignatureRecordFetching: Sendable {
    func fetchRecord(
        jobID: String,
        changeOrderID: String?,
        recordID: String,
        sessionBytes: Data
    ) async throws -> NativeSignedRecord
}

struct NativeESignatureRecordService: NativeESignatureRecordFetching {
    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct Body: Encodable {
        let jobId: String
        let changeOrderId: String?
        let recordId: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(jobId, forKey: .jobId)
            // Omitted for the estimate (§11.1 C), never sent as null.
            try container.encodeIfPresent(changeOrderId, forKey: .changeOrderId)
            try container.encode(recordId, forKey: .recordId)
        }

        enum CodingKeys: String, CodingKey { case jobId, changeOrderId, recordId }
    }

    private struct ResponseBody: Decodable {
        struct Seal: Decodable { let keyId: String? }
        struct Event: Decodable {
            let type: String
            let at: String?
            let ip: String?
        }
        struct PDF: Decodable {
            let filename: String?
            let contentType: String?
            let base64: String
        }
        let recordId: String
        let recordDigest: String
        let documentType: String
        let jobId: String
        let changeOrderId: String?
        let signedAt: String
        let signatureMethod: String?
        let seal: Seal?
        let events: [Event]?
        let pdf: PDF
    }

    private struct ErrorBody: Decodable { let code: String? }

    let endpoint: URL
    let loader: any NativeEstimateApprovalHTTPDataLoading

    init(endpoint: URL, loader: any NativeEstimateApprovalHTTPDataLoading = URLSession.shared) {
        self.endpoint = endpoint
        self.loader = loader
    }

    func fetchRecord(
        jobID: String,
        changeOrderID: String?,
        recordID: String,
        sessionBytes: Data
    ) async throws -> NativeSignedRecord {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativeESignatureRecordError.invalidConfiguration }
        guard Self.isValidID(jobID),
              changeOrderID.map(Self.isValidID) ?? true,
              Self.isRecordID(recordID)
        else { throw NativeESignatureRecordError.notFound }
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty
        else { throw NativeESignatureRecordError.malformedSession }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Body(jobId: jobID, changeOrderId: changeOrderID, recordId: recordID))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw NativeESignatureRecordError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw NativeESignatureRecordError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw NativeESignatureRecordError.rejectedSession
        case 404: throw NativeESignatureRecordError.notFound
        case 429: throw NativeESignatureRecordError.rateLimited
        case 503:
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.code
            throw code == "record_pending" ? NativeESignatureRecordError.pending : NativeESignatureRecordError.unavailable
        default: throw NativeESignatureRecordError.unavailable
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              decoded.recordId == recordID,
              decoded.jobId == jobID,
              decoded.changeOrderId == changeOrderID,
              Self.isDigest(decoded.recordDigest),
              ["estimate", "change_order"].contains(decoded.documentType),
              (decoded.documentType == "change_order") == (changeOrderID != nil),
              decoded.pdf.contentType == nil || decoded.pdf.contentType == "application/pdf",
              let pdfData = Data(base64Encoded: decoded.pdf.base64),
              pdfData.starts(with: Data("%PDF-".utf8))
        else { throw NativeESignatureRecordError.invalidResponse }

        let events = (decoded.events ?? []).compactMap { event -> NativeESignature.AuditEvent? in
            guard let at = event.at, !event.type.isEmpty else { return nil }
            return NativeESignature.AuditEvent(type: event.type, at: at, ip: event.ip)
        }
        return NativeSignedRecord(
            recordID: decoded.recordId,
            recordDigest: decoded.recordDigest,
            documentType: decoded.documentType,
            signedAt: decoded.signedAt,
            signatureMethod: decoded.signatureMethod,
            sealKeyID: decoded.seal?.keyId,
            events: NativeESignature.orderedTrail(events),
            pdfFilename: Self.safeFilename(decoded.pdf.filename, documentType: decoded.documentType),
            pdfData: pdfData
        )
    }

    /// The server's filename when it is a plain `*.pdf` name, else a fixed one.
    static func safeFilename(_ value: String?, documentType: String) -> String {
        let fallback = documentType == "change_order" ? "signed-change-order.pdf" : "signed-estimate.pdf"
        guard let value, (5...100).contains(value.count), value.lowercased().hasSuffix(".pdf"),
              !value.hasPrefix("."),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return fallback }
        return value
    }

    static func isRecordID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    static func isDigest(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func isValidID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200
    }

    private static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
}
