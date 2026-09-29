import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class RecordingLoader: NativeChangeOrderApprovalHTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, Int)] = []
    private var recorded: [URLRequest] = []

    func enqueue(_ body: String, status: Int) {
        lock.withLock { responses.append((Data(body.utf8), status)) }
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

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func jobWithOrder(
    jobID: String = "j1",
    orderID: String = "co1",
    title: String = "Rotted subfloor",
    amount: String = "850"
) throws -> (Canonical.Job, Canonical.ChangeOrder) {
    let jobData = Data("""
    {
      "id":"\(jobID)","customerId":"c1","customerName":"Dana","title":"Bath remodel",
      "description":"","status":"in_progress","address":"","estimateTotal":2400,
      "laborHours":4,"laborRate":85,"materials":[],"materialMarkup":20,
      "overhead":15,"margin":20,"notes":"","createdAt":"2026-08-01"
    }
    """.utf8)
    let job = try JSONDecoder().decode(Canonical.Job.self, from: jobData)
    let order = Canonical.ChangeOrder(
        id: orderID,
        title: title,
        description: "Whole-home unit",
        amount: decimal(amount),
        createdAt: "2026-08-05"
    )
    return (job, order)
}

private func snapshot(
    order: Canonical.ChangeOrder,
    job: Canonical.Job
) throws -> Canonical.EstimateApprovalSnapshot {
    try NativeChangeOrderApprovalSnapshot.build(
        order: order,
        job: job,
        customerName: "Dana",
        businessName: "Rivera Plumbing"
    )
}

@main
struct ChangeOrderApprovalLinkTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let (job, order) = try jobWithOrder()
        let frozen = try snapshot(order: order, job: job)

        // Frozen snapshot matches the JS buildChangeOrderSnapshot contract.
        expect(frozen.businessName == "Rivera Plumbing", "snapshot freezes the business name")
        expect(frozen.customerName == "Dana", "snapshot freezes the customer name")
        expect(frozen.jobTitle == "Bath remodel", "snapshot freezes the job title")
        expect(frozen.total == decimal("850") && frozen.currency == "USD",
               "snapshot freezes the CO amount as the total")
        expect(frozen.lineItems.count == 1
                && frozen.lineItems.first?.label == "Rotted subfloor"
                && frozen.lineItems.first?.amount == decimal("850"),
               "snapshot carries the single CO line item")
        let fallback = try NativeChangeOrderApprovalSnapshot.build(
            order: order, job: job, customerName: "", businessName: ""
        )
        expect(fallback.businessName == "Your tradesperson" && fallback.customerName == "Dana",
               "snapshot falls back exactly like the JS builder")

        let session = Data(#"{"access_token":"verified-owner-jwt","refresh_token":"not-sent"}"#.utf8)
        let endpoint = URL(string: "https://staging.example/api/estimate/create-link")!
        let token = String(repeating: "ab", count: 24)

        // Success: frozen draft mints {jobId, changeOrderId, snapshot}; the
        // public URL must carry the exact j+co+t triple.
        let loader = RecordingLoader()
        loader.enqueue(
            #"{"url":"https://approve.example/change?j=j1&co=co1&t=\#(token)","token":"\#(token)","sentAt":"2026-09-15T12:00:00.000Z"}"#,
            status: 200
        )
        let service = NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: loader)
        let result = try await service.createLink(
            jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session
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
            expect(fields["jobId"] as? String == "j1"
                    && fields["changeOrderId"] as? String == "co1"
                    && fields["snapshot"] != nil && fields.count == 3,
                   "approval body contains job ID, change-order ID, and the frozen snapshot")
        } else { expect(false, "approval request body decodes") }

        // Stale: a review opened against IDs that no longer resolve fails
        // closed before any network use.
        do {
            _ = try await service.createLink(
                jobID: "  ", changeOrderID: "co1", snapshot: frozen, sessionBytes: session
            )
            expect(false, "blank job ID must fail closed as stale")
        } catch NativeChangeOrderApprovalLinkError.changeOrderStale {
            expect(true, "stale job ID is classified")
        }
        do {
            _ = try await service.createLink(
                jobID: "j1", changeOrderID: "", snapshot: frozen, sessionBytes: session
            )
            expect(false, "blank change-order ID must fail closed as stale")
        } catch NativeChangeOrderApprovalLinkError.changeOrderStale {
            expect(true, "stale change-order ID is classified")
        }
        // Stale review sheet: the authoritative post-sync snapshot no longer
        // equals the frozen draft, so AppStore must refuse the mint.
        var movedOrder = order
        movedOrder.amount = decimal("900")
        let movedSnapshot = try snapshot(order: movedOrder, job: job)
        expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(movedSnapshot, frozen),
               "an edited order no longer equals the frozen review snapshot")

        // Owner-switch mid-await: the backend rejects the bearer (401/403) and
        // the AppStore owner recheck surfaces the same terminal session error.
        let rejectedLoader = RecordingLoader()
        rejectedLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        do {
            _ = try await NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: rejectedLoader)
                .createLink(jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session)
            expect(false, "401 must reject the session")
        } catch NativeChangeOrderApprovalLinkError.rejectedSession { expect(true, "401 is classified") }
        let forbiddenLoader = RecordingLoader()
        forbiddenLoader.enqueue(#"{"error":"forbidden"}"#, status: 403)
        do {
            _ = try await NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: forbiddenLoader)
                .createLink(jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session)
            expect(false, "403 must reject the session")
        } catch NativeChangeOrderApprovalLinkError.rejectedSession { expect(true, "403 is classified") }

        // Malformed success payload fails closed.
        let malformedLoader = RecordingLoader()
        malformedLoader.enqueue(#"{"url":"http://approve.example/x","token":"short","sentAt":"x"}"#, status: 200)
        do {
            _ = try await NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: malformedLoader)
                .createLink(jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session)
            expect(false, "malformed success response must fail closed")
        } catch NativeChangeOrderApprovalLinkError.invalidResponse { expect(true, "invalid success is classified") }

        // Cross-job / cross-order / missing-param public URLs fail closed.
        for (label, url) in [
            ("another job", "https://approve.example/change?j=other&t=\(token)&co=co1"),
            ("another order", "https://approve.example/change?j=j1&co=co9&t=\(token)"),
            ("missing order param", "https://approve.example/change?j=j1&t=\(token)"),
            ("missing token param", "https://approve.example/change?j=j1&co=co1"),
        ] {
            let crossLoader = RecordingLoader()
            crossLoader.enqueue(
                #"{"url":"\#(url)","token":"\#(token)","sentAt":"2026-09-15T12:00:00Z"}"#,
                status: 200
            )
            do {
                _ = try await NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: crossLoader)
                    .createLink(jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session)
                expect(false, "public link for \(label) must fail closed")
            } catch NativeChangeOrderApprovalLinkError.invalidResponse {
                expect(true, "\(label) public link is classified")
            }
        }

        // Already-decided rejection is terminal: 409 never retries the draft.
        let decidedLoader = RecordingLoader()
        decidedLoader.enqueue(#"{"error":"This change was already decided."}"#, status: 409)
        do {
            _ = try await NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: decidedLoader)
                .createLink(jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session)
            expect(false, "409 must surface the terminal already-decided error")
        } catch NativeChangeOrderApprovalLinkError.alreadyDecided {
            expect(true, "already-decided rejection is classified")
        }

        // Unsynced job surfaces the sync-before-mint error.
        let unsyncedLoader = RecordingLoader()
        unsyncedLoader.enqueue(#"{"error":"not synced"}"#, status: 422)
        do {
            _ = try await NativeChangeOrderApprovalLinkService(endpoint: endpoint, loader: unsyncedLoader)
                .createLink(jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session)
            expect(false, "422 must report an unsynced job")
        } catch NativeChangeOrderApprovalLinkError.jobNotSynced { expect(true, "422 is classified") }

        // Insecure endpoint is blocked before any network use.
        let invalidConfiguration = NativeChangeOrderApprovalLinkService(
            endpoint: URL(string: "http://production.example/api/estimate/create-link")!,
            loader: RecordingLoader()
        )
        do {
            _ = try await invalidConfiguration.createLink(
                jobID: "j1", changeOrderID: "co1", snapshot: frozen, sessionBytes: session
            )
            expect(false, "non-local HTTP endpoint must fail")
        } catch NativeChangeOrderApprovalLinkError.invalidConfiguration {
            expect(true, "insecure endpoint is blocked")
        }

        // Durable mirror: only token/sentAt/snapshot land in the exact pending
        // CO; server decision/signature + unknown fields are preserved.
        var pendingJob = job
        pendingJob.changeOrders = [order]
        let mirrored = try NativeChangeOrderApprovalMirror.apply(
            to: pendingJob, changeOrderID: "co1",
            token: token, sentAt: "2026-09-15T12:00:00.000Z", snapshot: frozen
        )
        expect(mirrored.changeOrders?.first?.approval?.token == token
                && mirrored.changeOrders?.first?.approval?.sentAt == "2026-09-15T12:00:00.000Z"
                && CanonicalUIAdapters.estimateApprovalSnapshotsMatch(
                    mirrored.changeOrders!.first!.approval!.snapshot, frozen),
               "mirror writes only the server token, sent time, and frozen snapshot")
        expect(mirrored.estimateTotal == pendingJob.estimateTotal
                && mirrored.id == pendingJob.id,
               "mirror never touches the job baseline")

        var unknownApprovalOrder = order
        unknownApprovalOrder.approval = try JSONDecoder().decode(
            Canonical.EstimateApproval.self,
            from: Data("""
            {"token":"\(String(repeating: "q", count: 20))","sentAt":"2026-09-01T00:00:00Z",\
            "snapshot":{"businessName":"Rivera Plumbing","customerName":"Dana",\
            "jobTitle":"Bath remodel","lineItems":[],"total":850,"currency":"USD"},\
            "serverFuture":true}
            """.utf8)
        )
        unknownApprovalOrder.preservation = Canonical.Preservation(
            unknownFields: ["orderFuture": .string("keep")]
        )
        var unknownJob = job
        unknownJob.changeOrders = [unknownApprovalOrder]
        let remirrored = try NativeChangeOrderApprovalMirror.apply(
            to: unknownJob, changeOrderID: "co1",
            token: token, sentAt: "2026-09-15T12:00:00.000Z", snapshot: frozen
        )
        expect(remirrored.changeOrders?.first?.approval?.preservation.unknownFields["serverFuture"] == .bool(true)
                && remirrored.changeOrders?.first?.preservation.unknownFields["orderFuture"] == .string("keep"),
               "re-mint preserves server and order unknown fields")

        // Mirror fails closed on a moved job/order, a cancelled order, or an
        // already-decided order (manual or server decision).
        do {
            _ = try NativeChangeOrderApprovalMirror.apply(
                to: pendingJob, changeOrderID: "co-missing",
                token: token, sentAt: "2026-09-15T12:00:00.000Z", snapshot: frozen
            )
            expect(false, "moved order must fail closed")
        } catch NativeChangeOrderApprovalLinkError.changeOrderStale {
            expect(true, "moved order is classified stale")
        }
        var cancelledJob = job
        var cancelledOrder = order
        cancelledOrder.cancelledAt = "2026-09-16"
        cancelledJob.changeOrders = [cancelledOrder]
        do {
            _ = try NativeChangeOrderApprovalMirror.apply(
                to: cancelledJob, changeOrderID: "co1",
                token: token, sentAt: "2026-09-15T12:00:00.000Z", snapshot: frozen
            )
            expect(false, "cancelled order must fail closed")
        } catch NativeChangeOrderApprovalLinkError.changeOrderStale {
            expect(true, "cancelled order is classified stale")
        }
        var manualJob = job
        var manualOrder = order
        manualOrder.manualDecision = .init(decision: "approved", decidedAt: "2026-09-16")
        manualJob.changeOrders = [manualOrder]
        do {
            _ = try NativeChangeOrderApprovalMirror.apply(
                to: manualJob, changeOrderID: "co1",
                token: token, sentAt: "2026-09-15T12:00:00.000Z", snapshot: frozen
            )
            expect(false, "manually decided order must fail closed")
        } catch NativeChangeOrderApprovalLinkError.alreadyDecided {
            expect(true, "manual decision is terminal")
        }
        var serverDecidedJob = job
        var serverDecidedOrder = order
        serverDecidedOrder.approval = try JSONDecoder().decode(
            Canonical.EstimateApproval.self,
            from: Data("""
            {"token":"\(String(repeating: "z", count: 20))","sentAt":"2026-09-01T00:00:00Z",\
            "snapshot":{"businessName":"Rivera Plumbing","customerName":"Dana",\
            "jobTitle":"Bath remodel","lineItems":[],"total":850,"currency":"USD"},\
            "decision":"declined","consentAt":"2026-09-02T00:00:00Z"}
            """.utf8)
        )
        serverDecidedJob.changeOrders = [serverDecidedOrder]
        do {
            _ = try NativeChangeOrderApprovalMirror.apply(
                to: serverDecidedJob, changeOrderID: "co1",
                token: token, sentAt: "2026-09-15T12:00:00.000Z", snapshot: frozen
            )
            expect(false, "server-decided order must fail closed")
        } catch NativeChangeOrderApprovalLinkError.alreadyDecided {
            expect(true, "server decision is terminal")
        }

        if failures > 0 { Foundation.exit(1) }
        print("PASS: native change-order approval-link transport tests")
    }
}
