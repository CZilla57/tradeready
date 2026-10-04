import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class RecordingLoader: NativeEstimateApprovalHTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, Int)] = []
    private var recorded: [URLRequest] = []

    func enqueue(_ body: String, status: Int) {
        lock.withLock { responses.append((Data(body.utf8), status)) }
    }

    func enqueue(_ body: Data, status: Int) {
        lock.withLock { responses.append((body, status)) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let next = lock.withLock {
            recorded.append(request)
            return responses.removeFirst()
        }
        return (
            next.0,
            HTTPURLResponse(url: request.url!, statusCode: next.1, httpVersion: nil, headerFields: nil)!
        )
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
}

@main
struct EstimateApprovalLinkTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let fixtureURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANONICAL_FIXTURE"]!)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let snapshotData = try JSONSerialization.data(withJSONObject: object["job"] as! [String: Any])
        let job = try JSONDecoder().decode(Canonical.Job.self, from: snapshotData)
        let approvalSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
            job: job,
            customerName: "Ada Lovelace",
            businessName: "Ada Electric"
        )
        let session = Data(#"{"access_token":"verified-owner-jwt","refresh_token":"not-sent"}"#.utf8)
        let endpoint = URL(string: "https://staging.example/api/estimate/create-link")!
        let loader = RecordingLoader()
        let token = String(repeating: "ab", count: 24)
        loader.enqueue(
            #"{"url":"https://approve.example/estimate?j=\#(job.id)&t=\#(token)","token":"\#(token)","sentAt":"2026-09-15T12:00:00.000Z"}"#,
            status: 200
        )
        let service = NativeEstimateApprovalLinkService(endpoint: endpoint, loader: loader)
        let result = try await service.createLink(
            jobID: job.id,
            snapshot: approvalSnapshot,
            sessionBytes: session
        )
        expect(result.token == token && result.sentAt == "2026-09-15T12:00:00.000Z",
               "successful response returns the server-minted token and sent time")
        expect(result.url.host == "approve.example", "successful response validates the public HTTPS URL")
        let request = loader.requests.first
        expect(request?.httpMethod == "POST" && request?.url == endpoint,
               "approval request uses the configured endpoint")
        expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer verified-owner-jwt",
               "approval request uses only the current Supabase bearer")
        expect(request?.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("refresh_token") == false,
               "approval body never contains refresh credentials")
        if let body = request?.httpBody,
           let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            expect(fields["jobId"] as? String == job.id && fields["snapshot"] != nil && fields.count == 2,
                   "approval body contains only job ID and the frozen snapshot")
        } else { expect(false, "approval request body decodes") }

        var declinedApproval = job.approval!
        declinedApproval.token = String(repeating: "r", count: 48)
        declinedApproval.decision = "declined"
        declinedApproval.declineReason = "Please revise the scope"
        var revisedJob = job
        revisedJob.status = JobStatus.lead.rawValue
        revisedJob.estimateSentAt = nil
        revisedJob.approval = nil
        revisedJob.approvalHistory = [declinedApproval]
        let revisedJobObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(revisedJob))
        let revisionResponse = try JSONSerialization.data(withJSONObject: ["job": revisedJobObject])
        let revisionLoader = RecordingLoader()
        revisionLoader.enqueue(revisionResponse, status: 200)
        let revised = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: revisionLoader)
            .beginDeclinedRevision(
                jobID: job.id,
                approvalToken: declinedApproval.token,
                sessionBytes: session
            )
        expect(revised.status == JobStatus.lead.rawValue
               && revised.approval == nil
               && revised.approvalHistory?.first?.declineReason == "Please revise the scope",
               "declined revision accepts only a lead job with the exact approval archived")
        let revisionRequest = revisionLoader.requests.first
        expect(revisionRequest?.url?.path == "/api/estimate/revise-declined",
               "revision uses the sibling authenticated backend endpoint")
        expect(revisionRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer verified-owner-jwt",
               "revision uses only the current Supabase bearer")
        if let body = revisionRequest?.httpBody,
           let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            expect(fields["jobId"] as? String == job.id
                   && fields["approvalToken"] as? String == declinedApproval.token
                   && fields.count == 2,
                   "revision body carries only the job and exact capability target")
        } else { expect(false, "revision request body decodes") }

        let conflictLoader = RecordingLoader()
        conflictLoader.enqueue(#"{"error":"changed"}"#, status: 409)
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: conflictLoader)
                .beginDeclinedRevision(
                    jobID: job.id,
                    approvalToken: declinedApproval.token,
                    sessionBytes: session
                )
            expect(false, "409 must preserve a racing customer decision")
        } catch NativeEstimateApprovalLinkError.revisionConflict {
            expect(true, "revision conflict is classified")
        }

        let rejectedLoader = RecordingLoader()
        rejectedLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: rejectedLoader)
                .createLink(jobID: job.id, snapshot: approvalSnapshot, sessionBytes: session)
            expect(false, "401 must reject the session")
        } catch NativeEstimateApprovalLinkError.rejectedSession { expect(true, "401 is classified") }

        let unsyncedLoader = RecordingLoader()
        unsyncedLoader.enqueue(#"{"error":"not synced"}"#, status: 422)
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: unsyncedLoader)
                .createLink(jobID: job.id, snapshot: approvalSnapshot, sessionBytes: session)
            expect(false, "422 must report an unsynced job")
        } catch NativeEstimateApprovalLinkError.jobNotSynced { expect(true, "422 is classified") }

        // Phase 32 (spec 2026-10-03 §6.10): a 400 from create-link is the
        // Worker refusing the snapshot's details (e.g. a past valid-until
        // date), never "unavailable".
        let datedSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
            job: job,
            customerName: "Ada Lovelace",
            businessName: "Ada Electric",
            validUntil: "2026-11-02",
            validUntilTimeZone: "America/Phoenix"
        )
        let rejectedDetailsLoader = RecordingLoader()
        rejectedDetailsLoader.enqueue(#"{"error":"The valid-until date is in the past."}"#, status: 400)
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: rejectedDetailsLoader)
                .createLink(jobID: job.id, snapshot: datedSnapshot, sessionBytes: session)
            expect(false, "400 must report rejected estimate details")
        } catch NativeEstimateApprovalLinkError.estimateRejected {
            expect(true, "400 is classified as estimateRejected")
        }
        expect(NativeEstimateApprovalLinkError.estimateRejected.errorDescription
               == "The approval service couldn't accept this estimate's details. Review the estimate, check its valid-until date, and try again.",
               "estimateRejected copy names the valid-until date")
        if let body = rejectedDetailsLoader.requests.first?.httpBody,
           let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any],
           let snapshotFields = fields["snapshot"] as? [String: Any] {
            expect(snapshotFields["validUntil"] as? String == "2026-11-02"
                   && snapshotFields["validUntilTimeZone"] as? String == "America/Phoenix",
                   "the dated snapshot is sent with its date and zone")
        } else { expect(false, "dated approval request body decodes") }
        let serverErrorLoader = RecordingLoader()
        serverErrorLoader.enqueue(#"{"error":"boom"}"#, status: 500)
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: serverErrorLoader)
                .createLink(jobID: job.id, snapshot: datedSnapshot, sessionBytes: session)
            expect(false, "500 must report unavailable")
        } catch NativeEstimateApprovalLinkError.unavailable { expect(true, "500 stays unavailable") }

        let malformedLoader = RecordingLoader()
        malformedLoader.enqueue(#"{"url":"http://approve.example/x","token":"short","sentAt":"x"}"#, status: 200)
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: malformedLoader)
                .createLink(jobID: job.id, snapshot: approvalSnapshot, sessionBytes: session)
            expect(false, "malformed success response must fail closed")
        } catch NativeEstimateApprovalLinkError.invalidResponse { expect(true, "invalid success is classified") }

        let mismatchedURLLoader = RecordingLoader()
        mismatchedURLLoader.enqueue(
            #"{"url":"https://approve.example/estimate?j=another-job&t=\#(token)","token":"\#(token)","sentAt":"2026-09-15T12:00:00Z"}"#,
            status: 200
        )
        do {
            _ = try await NativeEstimateApprovalLinkService(endpoint: endpoint, loader: mismatchedURLLoader)
                .createLink(jobID: job.id, snapshot: approvalSnapshot, sessionBytes: session)
            expect(false, "public link for another job must fail closed")
        } catch NativeEstimateApprovalLinkError.invalidResponse { expect(true, "mismatched public job is classified") }

        let invalidConfiguration = NativeEstimateApprovalLinkService(
            endpoint: URL(string: "http://production.example/api/estimate/create-link")!,
            loader: RecordingLoader()
        )
        do {
            _ = try await invalidConfiguration.createLink(
                jobID: job.id,
                snapshot: approvalSnapshot,
                sessionBytes: session
            )
            expect(false, "non-local HTTP endpoint must fail")
        } catch NativeEstimateApprovalLinkError.invalidConfiguration { expect(true, "insecure endpoint is blocked") }

        if failures > 0 { Foundation.exit(1) }
        print("PASS: native estimate approval-link transport tests")
    }
}
