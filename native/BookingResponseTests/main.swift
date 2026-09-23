import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Task 8.07 (B1, B4): owner transport fixtures for NativeBookingResponse.
// Oracle: backend-workers/lib/booking/respond.js (frozen §2.2, §7).

private struct Failure: Error {}

private final class RecordingLoader: NativeBookingResponseHTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, Int)] = []
    private var recorded: [URLRequest] = []
    var throwOnCall = false

    func enqueue(_ body: String, status: Int) {
        lock.withLock { responses.append((Data(body.utf8), status)) }
    }

    func enqueueData(_ data: Data, status: Int) {
        lock.withLock { responses.append((data, status)) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if throwOnCall { throw Failure() }
        let next = lock.withLock {
            recorded.append(request)
            return responses.removeFirst()
        }
        return (next.0, HTTPURLResponse(url: request.url!, statusCode: next.1, httpVersion: nil, headerFields: nil)!)
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
}

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func bodyFields(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
}

private let session = Data(#"{"access_token":"verified-owner-jwt","refresh_token":"not-sent"}"#.utf8)
private let freshSession = Data(#"{"access_token":"refreshed-owner-jwt"}"#.utf8)
private let endpoint = URL(string: "https://staging.example/api/booking/respond")!
private let proof = NativeScheduleProof(
    jobId: "job-1", updatedAt: "2026-09-20T12:00:00.000Z", date: "2026-09-22", start: "09:00"
)

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next(_ fresh: Data) -> Data {
        lock.withLock { count += 1 }
        return fresh
    }
    var calls: Int { lock.withLock { count } }
}

@main
struct BookingResponseTests {
    static func main() async throws {
        // Request fixture: resolve carries the publication proof; the body
        // never carries credentials and targets the configured endpoint.
        let loader = RecordingLoader()
        loader.enqueue(#"{"ok":true,"status":"confirmed"}"#, status: 200)
        let service = NativeBookingResponseService(endpoint: endpoint, loader: loader)
        let resolved = try await service.resolveReschedule(requestId: "bk-1", proof: proof, sessionBytes: session)
        expect(resolved == NativeBookingResponseResult(status: "confirmed", alreadyApplied: false),
               "resolve returns the authoritative target status")
        let resolveRequest = loader.requests.first
        expect(resolveRequest?.httpMethod == "POST" && resolveRequest?.url == endpoint,
               "respond uses POST against the configured endpoint")
        expect(resolveRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer verified-owner-jwt",
               "respond uses only the current verified bearer")
        if let fields = try? bodyFields(resolveRequest!),
           let carried = fields["scheduleProof"] as? [String: Any] {
            expect(fields["requestId"] as? String == "bk-1"
                    && fields["action"] as? String == "resolve_reschedule"
                    && carried["jobId"] as? String == "job-1"
                    && carried["updatedAt"] as? String == "2026-09-20T12:00:00.000Z"
                    && carried["date"] as? String == "2026-09-22"
                    && carried["start"] as? String == "09:00"
                    && fields.count == 3,
                   "resolve body carries the exact publication proof")
            expect(!(try! bodyFields(resolveRequest!).description.contains("verified-owner-jwt")),
                   "resolve body never carries credentials")
        } else { expect(false, "resolve body decodes") }

        // Decline carries no proof key at all (never a partial verification).
        let declineLoader = RecordingLoader()
        declineLoader.enqueue(#"{"ok":true,"status":"declined"}"#, status: 200)
        let declined = try await NativeBookingResponseService(endpoint: endpoint, loader: declineLoader)
            .decline(requestId: "bk-2", sessionBytes: session)
        expect(declined == NativeBookingResponseResult(status: "declined", alreadyApplied: false),
               "decline returns the authoritative target status")
        if let fields = try? bodyFields(declineLoader.requests.first!) {
            expect(fields["action"] as? String == "decline"
                    && fields["requestId"] as? String == "bk-2"
                    && fields["scheduleProof"] == nil && fields.count == 2,
                   "decline body carries no proof key")
        } else { expect(false, "decline body decodes") }

        // Success-equivalent (§2.2): a 409 invalid_state echoing the intended
        // target is a success — the retry found a committed transition, and
        // the server performed no second write and no second email.
        for (action, target) in [("resolve", "confirmed"), ("decline", "declined")] {
            let replay = RecordingLoader()
            replay.enqueue(#"{"error":"invalid_state","status":"\#(target)"}"#, status: 409)
            let replayService = NativeBookingResponseService(endpoint: endpoint, loader: replay)
            let outcome: NativeBookingResponseResult
            if action == "resolve" {
                outcome = try await replayService.resolveReschedule(requestId: "bk-3", proof: proof, sessionBytes: session)
            } else {
                outcome = try await replayService.decline(requestId: "bk-3", sessionBytes: session)
            }
            expect(outcome == NativeBookingResponseResult(status: target, alreadyApplied: true),
                   "\(action) retry-after-commit maps to success without new work")
        }

        // A 409 echoing any other status is a definitive refusal.
        let conflictLoader = RecordingLoader()
        conflictLoader.enqueue(#"{"error":"invalid_state","status":"cancelled"}"#, status: 409)
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: conflictLoader)
                .decline(requestId: "bk-4", sessionBytes: session)
            expect(false, "invalid_state for another target must refuse")
        } catch NativeBookingResponseError.invalidState(let current) {
            expect(current == "cancelled", "invalid_state echoes current authority")
        } catch { expect(false, "invalid_state must decode its echo") }

        // schedule_changed is terminal: a superseding edit must not resolve.
        let changedLoader = RecordingLoader()
        changedLoader.enqueue(#"{"error":"schedule_changed","status":"reschedule_requested"}"#, status: 409)
        let changedService = NativeBookingResponseService(endpoint: endpoint, loader: changedLoader)
        do {
            _ = try await changedService.resolveReschedule(requestId: "bk-5", proof: proof, sessionBytes: session)
            expect(false, "schedule_changed must refuse the resolve")
        } catch NativeBookingResponseError.scheduleChanged(let current) {
            expect(current == "reschedule_requested", "schedule_changed echoes current authority")
        } catch { expect(false, "schedule_changed must decode its echo") }

        // Invalid proof shapes fail closed before any network use.
        let badProofLoader = RecordingLoader()
        let badProofs = [
            NativeScheduleProof(jobId: "", updatedAt: "2026-09-20T12:00:00.000Z", date: "2026-09-22", start: "09:00"),
            NativeScheduleProof(jobId: "job-1", updatedAt: "", date: "2026-09-22", start: "09:00"),
            NativeScheduleProof(jobId: "job-1", updatedAt: "2026-09-20T12:00:00.000Z", date: "", start: "09:00"),
        ]
        for bad in badProofs {
            do {
                _ = try await NativeBookingResponseService(endpoint: endpoint, loader: badProofLoader)
                    .resolveReschedule(requestId: "bk-6", proof: bad, sessionBytes: session)
                expect(false, "invalid proof must fail closed")
            } catch NativeBookingResponseError.invalidRequest { expect(true, "invalid proof is classified") }
        }
        expect(badProofLoader.requests.isEmpty, "invalid proof sends no request")
        let blankID = RecordingLoader()
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: blankID)
                .decline(requestId: "  ", sessionBytes: session)
            expect(false, "blank request id must fail closed")
        } catch NativeBookingResponseError.invalidRequest { expect(true, "blank request id is classified") }
        expect(blankID.requests.isEmpty, "blank request id sends no request")

        // Missing configuration and malformed session fail closed.
        let insecure = NativeBookingResponseService(
            endpoint: URL(string: "http://production.example/api/booking/respond")!,
            loader: RecordingLoader()
        )
        do {
            _ = try await insecure.decline(requestId: "bk-7", sessionBytes: session)
            expect(false, "non-local HTTP endpoint must fail")
        } catch NativeBookingResponseError.invalidConfiguration { expect(true, "insecure endpoint is blocked") }
        do {
            _ = try NativeBookingResponseService.resolvedEndpoint()
            expect(false, "unconfigured build must not resolve an endpoint")
        } catch NativeBookingResponseError.invalidConfiguration { expect(true, "missing backend URL is classified") }
        let malformed = RecordingLoader()
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: malformed)
                .decline(requestId: "bk-8", sessionBytes: Data("not json".utf8))
            expect(false, "malformed session must fail closed")
        } catch NativeBookingResponseError.malformedSession { expect(true, "malformed session is classified") }
        expect(malformed.requests.isEmpty, "malformed session sends no request")

        // Auth refresh: 401 answered by a fresh bearer retries once; the
        // first attempt died at authentication so no transition can duplicate.
        let refreshLoader = RecordingLoader()
        refreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        refreshLoader.enqueue(#"{"ok":true,"status":"declined"}"#, status: 200)
        let refreshCalls = RefreshCounter()
        let refreshing = NativeBookingResponseService(
            endpoint: endpoint, loader: refreshLoader,
            refreshSession: { refreshCalls.next(freshSession) }
        )
        let refreshed = try await refreshing.decline(requestId: "bk-9", sessionBytes: session)
        expect(refreshed.status == "declined" && refreshCalls.calls == 1 && refreshLoader.requests.count == 2,
               "401 with a fresh bearer retries once with the new bearer")
        expect(refreshLoader.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-owner-jwt",
               "refresh retry uses the fresh bearer")
        let noRefreshLoader = RecordingLoader()
        noRefreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: noRefreshLoader)
                .decline(requestId: "bk-10", sessionBytes: session)
            expect(false, "401 without refresh must reject the session")
        } catch NativeBookingResponseError.rejectedSession { expect(true, "401 without refresh is classified") }
        expect(noRefreshLoader.requests.count == 1, "rejected session never resends")

        // 404 isolation (foreign is indistinguishable from unknown), 429,
        // malformed/oversized success, and unknown-outcome handling.
        let missing = RecordingLoader()
        missing.enqueue(#"{"error":"Not found"}"#, status: 404)
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: missing)
                .decline(requestId: "foreign-id", sessionBytes: session)
            expect(false, "404 must surface notFound")
        } catch NativeBookingResponseError.notFound { expect(true, "404 is classified") }
        let limited = RecordingLoader()
        limited.enqueue(#"{"error":"Too many"}"#, status: 429)
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: limited)
                .decline(requestId: "bk-11", sessionBytes: session)
            expect(false, "429 must surface rateLimited")
        } catch NativeBookingResponseError.rateLimited { expect(true, "429 is classified") }
        expect(limited.requests.count == 1, "rate limit is never retried automatically")
        for (label, body) in [
            ("garbage", "not json"),
            ("ok-false", #"{"ok":false,"status":"declined"}"#),
            ("missing-status", #"{"ok":true}"#),
        ] {
            let bad = RecordingLoader()
            bad.enqueue(body, status: 200)
            do {
                _ = try await NativeBookingResponseService(endpoint: endpoint, loader: bad)
                    .decline(requestId: "bk-12", sessionBytes: session)
                expect(false, "\(label) success payload must fail closed")
            } catch NativeBookingResponseError.invalidResponse { expect(true, "\(label) is classified") }
        }
        let oversized = RecordingLoader()
        oversized.enqueueData(Data(repeating: 0x41, count: 64 * 1024 + 1), status: 200)
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: oversized)
                .decline(requestId: "bk-13", sessionBytes: session)
            expect(false, "oversized success payload must fail closed")
        } catch NativeBookingResponseError.invalidResponse { expect(true, "oversized payload is classified") }

        // Unknown outcome: 5xx and transport failure after the POST report
        // unknownOutcome with exactly one attempt — never an automatic resend
        // (a decline resend could duplicate the customer email).
        for status in [500, 503] {
            let failed = RecordingLoader()
            failed.enqueue(#"{"error":"Database error"}"#, status: status)
            do {
                _ = try await NativeBookingResponseService(endpoint: endpoint, loader: failed)
                    .decline(requestId: "bk-14", sessionBytes: session)
                expect(false, "\(status) after a respond must surface unknownOutcome")
            } catch NativeBookingResponseError.unknownOutcome { expect(true, "\(status) is classified unknown") }
            expect(failed.requests.count == 1, "\(status) never auto-resends the response")
        }
        let transport = RecordingLoader()
        transport.throwOnCall = true
        do {
            _ = try await NativeBookingResponseService(endpoint: endpoint, loader: transport)
                .resolveReschedule(requestId: "bk-15", proof: proof, sessionBytes: session)
            expect(false, "transport failure after a respond must surface unknownOutcome")
        } catch NativeBookingResponseError.unknownOutcome { expect(true, "transport failure is classified unknown") }

        // No secrets in diagnostics.
        for error: NativeBookingResponseError in [
            .invalidConfiguration, .malformedSession, .rejectedSession, .invalidRequest,
            .notFound, .invalidState(currentStatus: "cancelled"),
            .scheduleChanged(currentStatus: "reschedule_requested"),
            .rateLimited, .invalidResponse, .unavailable, .unknownOutcome,
        ] {
            let text = error.errorDescription ?? ""
            expect(!text.contains("verified-owner-jwt") && !text.contains("bk-1"),
                   "diagnostic for \(error) carries no secret")
        }

        if failures > 0 { Foundation.exit(1) }
        print("PASS: native booking-response transport tests")
    }
}
