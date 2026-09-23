import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Task 8.07 (P1): owner transport fixtures for NativePortalAdministration.
// Oracle: backend-workers/lib/estimate/portalManage.js (frozen §4, §6).

private struct Failure: Error {}

private final class RecordingLoader: NativePortalAdministrationHTTPDataLoading, @unchecked Sendable {
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
private let endpoint = URL(string: "https://staging.example/api/estimate/portal-manage")!
private let token48 = String(repeating: "cd", count: 24)
private let operation = "21111111-2222-4333-8555-666666666666"

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
struct PortalAdministrationTests {
    static func main() async throws {
        // Request fixture: mint uses POST, current bearer only, exact body.
        let loader = RecordingLoader()
        loader.enqueue(#"{"ok":true,"token":"\#(token48)"}"#, status: 200)
        let service = NativePortalAdministrationService(endpoint: endpoint, loader: loader)
        let minted = try await service.mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
        expect(minted == NativePortalAdminResult(customerId: "cust-1", token: token48, enabled: nil, operationId: operation),
               "mint returns the typed server result with operation identity")
        let mintRequest = loader.requests.first
        expect(mintRequest?.httpMethod == "POST" && mintRequest?.url == endpoint,
               "portal-manage uses POST against the configured endpoint")
        expect(mintRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer verified-owner-jwt",
               "portal-manage uses only the current verified bearer")
        if let fields = try? bodyFields(mintRequest!) {
            expect(fields["action"] as? String == "mint"
                    && fields["customerId"] as? String == "cust-1"
                    && fields["operationId"] as? String == operation
                    && fields["enabled"] == nil,
                   "mint body carries action, customer id, and operation identity")
        } else { expect(false, "mint body decodes") }

        // set_enabled body carries the flag; rotate works from zero rows.
        let toggleLoader = RecordingLoader()
        toggleLoader.enqueue(#"{"ok":true,"enabled":false}"#, status: 200)
        let toggled = try await NativePortalAdministrationService(endpoint: endpoint, loader: toggleLoader)
            .setEnabled(false, customerId: "cust-1", operationId: operation, sessionBytes: session)
        expect(toggled == NativePortalAdminResult(customerId: "cust-1", token: nil, enabled: false, operationId: operation),
               "set_enabled returns the flag with operation identity and no token")
        let rotateLoader = RecordingLoader()
        rotateLoader.enqueue(#"{"ok":true,"token":"\#(token48)"}"#, status: 200)
        let rotated = try await NativePortalAdministrationService(endpoint: endpoint, loader: rotateLoader)
            .rotate(customerId: "cust-new", operationId: operation, sessionBytes: session)
        expect(rotated.token == token48 && rotated.customerId == "cust-new",
               "rotate returns a fresh capability scoped to the customer")

        // Malformed / oversized / invalid-token success payloads fail closed.
        for (label, body) in [
            ("garbage", "not json"),
            ("ok-false", #"{"ok":false,"token":"\#(token48)"}"#),
            ("short-token", #"{"ok":true,"token":"abc"}"#),
            ("non-hex-token", #"{"ok":true,"token":"\#(String(repeating: "zz", count: 24))"}"#),
        ] {
            let bad = RecordingLoader()
            bad.enqueue(body, status: 200)
            do {
                _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: bad)
                    .mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
                expect(false, "\(label) success payload must fail closed")
            } catch NativePortalAdminError.invalidResponse { expect(true, "\(label) is classified") }
        }
        let oversized = RecordingLoader()
        oversized.enqueueData(Data(repeating: 0x41, count: 64 * 1024 + 1), status: 200)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: oversized)
                .mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "oversized success payload must fail closed")
        } catch NativePortalAdminError.invalidResponse { expect(true, "oversized payload is classified") }

        // Invalid customer and operation IDs fail closed before network use.
        let guarded = RecordingLoader()
        for badCustomer in ["", "  "] {
            do {
                _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: guarded)
                    .mint(customerId: badCustomer, operationId: operation, sessionBytes: session)
                expect(false, "blank customer id must fail closed")
            } catch NativePortalAdminError.invalidRequest { expect(true, "blank customer id is classified") }
        }
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: guarded)
                .mint(customerId: "cust-1", operationId: "not-a-uuid", sessionBytes: session)
            expect(false, "non-UUID operation id must fail closed")
        } catch NativePortalAdminError.invalidRequest { expect(true, "non-UUID operation id is classified") }
        expect(guarded.requests.isEmpty, "invalid ids send no request")

        // Missing configuration and malformed session fail closed.
        let insecure = NativePortalAdministrationService(
            endpoint: URL(string: "http://production.example/api/estimate/portal-manage")!,
            loader: RecordingLoader()
        )
        do {
            _ = try await insecure.mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "non-local HTTP endpoint must fail")
        } catch NativePortalAdminError.invalidConfiguration { expect(true, "insecure endpoint is blocked") }
        do {
            _ = try NativePortalAdministrationService.resolvedEndpoint()
            expect(false, "unconfigured build must not resolve an endpoint")
        } catch NativePortalAdminError.invalidConfiguration { expect(true, "missing backend URL is classified") }
        let malformed = RecordingLoader()
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: malformed)
                .mint(customerId: "cust-1", operationId: operation, sessionBytes: Data(#"{"access_token":""}"#.utf8))
            expect(false, "malformed session must fail closed")
        } catch NativePortalAdminError.malformedSession { expect(true, "malformed session is classified") }
        expect(malformed.requests.isEmpty, "malformed session sends no request")

        // Auth refresh: 401 answered by a fresh bearer retries once with the
        // new bearer and identical operation identity.
        let refreshLoader = RecordingLoader()
        refreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        refreshLoader.enqueue(#"{"ok":true,"enabled":true}"#, status: 200)
        let refreshCalls = RefreshCounter()
        let refreshing = NativePortalAdministrationService(
            endpoint: endpoint, loader: refreshLoader,
            refreshSession: { refreshCalls.next(freshSession) }
        )
        let refreshed = try await refreshing.setEnabled(true, customerId: "cust-1", operationId: operation, sessionBytes: session)
        expect(refreshed.enabled == true && refreshCalls.calls == 1 && refreshLoader.requests.count == 2,
               "401 with a fresh bearer retries the same operation once")
        expect(refreshLoader.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-owner-jwt",
               "refresh retry uses the fresh bearer")
        let noRefreshLoader = RecordingLoader()
        noRefreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: noRefreshLoader)
                .rotate(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "401 without refresh must reject the session")
        } catch NativePortalAdminError.rejectedSession { expect(true, "401 without refresh is classified") }

        // Bounded refresh: a second consecutive 401 rejects instead of
        // refreshing again — exactly two attempts, one refresh call.
        let double401Loader = RecordingLoader()
        double401Loader.enqueue(#"{"error":"expired"}"#, status: 401)
        double401Loader.enqueue(#"{"error":"expired"}"#, status: 401)
        let double401Refresh = RefreshCounter()
        do {
            _ = try await NativePortalAdministrationService(
                endpoint: endpoint, loader: double401Loader,
                refreshSession: { double401Refresh.next(freshSession) }
            ).status(customerId: "cust-1", sessionBytes: session)
            expect(false, "a second consecutive 401 must reject the session")
        } catch NativePortalAdminError.rejectedSession { expect(true, "double 401 is bounded") }
        expect(double401Loader.requests.count == 2 && double401Refresh.calls == 1,
               "refresh retry never refreshes again")

        // Definitive refusals: unknown/foreign customer 404, stale-Create
        // 409 already_exists, operation_conflict — each terminal, no retry.
        let missing = RecordingLoader()
        missing.enqueue(#"{"error":"Not found"}"#, status: 404)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: missing)
                .mint(customerId: "foreign-id", operationId: operation, sessionBytes: session)
            expect(false, "404 must surface notFound")
        } catch NativePortalAdminError.notFound { expect(true, "404 is classified") }
        let exists = RecordingLoader()
        exists.enqueue(#"{"error":"already_exists"}"#, status: 409)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: exists)
                .mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "409 already_exists must surface alreadyExists")
        } catch NativePortalAdminError.alreadyExists { expect(true, "already_exists is classified") }
        expect(exists.requests.count == 1, "stale Create never implicitly rotates")
        let conflict = RecordingLoader()
        conflict.enqueue(#"{"error":"operation_conflict"}"#, status: 409)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: conflict)
                .rotate(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "409 operation_conflict must surface operationConflict")
        } catch NativePortalAdminError.operationConflict { expect(true, "operation_conflict is classified") }

        // Transient 429 and unknown-outcome 5xx/transport after a mutation.
        let limited = RecordingLoader()
        limited.enqueue(#"{"error":"Too many"}"#, status: 429)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: limited)
                .mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "429 must surface rateLimited")
        } catch NativePortalAdminError.rateLimited { expect(true, "429 is classified") }
        expect(limited.requests.count == 1, "rate limit is never retried automatically")
        for status in [500, 503] {
            let failed = RecordingLoader()
            failed.enqueue(#"{"error":"Database error"}"#, status: status)
            do {
                _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: failed)
                    .rotate(customerId: "cust-1", operationId: operation, sessionBytes: session)
                expect(false, "\(status) after a mutation must surface unknownOutcome")
            } catch NativePortalAdminError.unknownOutcome { expect(true, "\(status) is classified unknown") }
            expect(failed.requests.count == 1, "\(status) never auto-retries the mutation")
        }
        let transport = RecordingLoader()
        transport.throwOnCall = true
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: transport)
                .mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
            expect(false, "transport failure after a mutation must surface unknownOutcome")
        } catch NativePortalAdminError.unknownOutcome { expect(true, "transport failure is classified unknown") }

        // Status read: authoritative enabled/tokenValid/adopted, never a token.
        let statusLoader = RecordingLoader()
        statusLoader.enqueue(#"{"ok":true,"enabled":true,"tokenValid":true,"adopted":true}"#, status: 200)
        let linkStatus = try await NativePortalAdministrationService(endpoint: endpoint, loader: statusLoader)
            .status(customerId: "cust-1", token: token48, sessionBytes: session)
        expect(linkStatus == NativePortalLinkStatus(customerId: "cust-1", enabled: true, tokenValid: true, adopted: true),
               "status returns authoritative state, validity, and adoption")
        if let fields = try? bodyFields(statusLoader.requests.first!) {
            expect(fields["action"] as? String == "status"
                    && fields["customerId"] as? String == "cust-1"
                    && fields["token"] as? String == token48,
                   "status body carries the customer and display copy")
        } else { expect(false, "status body decodes") }
        let unadoptedLoader = RecordingLoader()
        unadoptedLoader.enqueue(#"{"ok":true,"enabled":true,"tokenValid":true,"adopted":false}"#, status: 200)
        let unadopted = try await NativePortalAdministrationService(endpoint: endpoint, loader: unadoptedLoader)
            .status(customerId: "cust-1", token: "legacy-blob-copy", sessionBytes: session)
        expect(unadopted.adopted == false && unadopted.tokenValid == true,
               "unadopted display copy validates through the legacy path")
        let staleLoader = RecordingLoader()
        staleLoader.enqueue(#"{"ok":true,"enabled":true,"tokenValid":false,"adopted":true}"#, status: 200)
        let stale = try await NativePortalAdministrationService(endpoint: endpoint, loader: staleLoader)
            .status(customerId: "cust-1", token: token48, sessionBytes: session)
        expect(stale.tokenValid == false, "a present-but-stale display token validates false (recovery path)")
        let tokenLeakLoader = RecordingLoader()
        tokenLeakLoader.enqueue(#"{"ok":true,"enabled":true,"token":"\#(token48)","tokenValid":true,"adopted":true}"#, status: 200)
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: tokenLeakLoader)
                .status(customerId: "cust-1", sessionBytes: session)
            expect(false, "status must never return a token")
        } catch NativePortalAdminError.invalidResponse { expect(true, "status token leak is classified") }
        let statusFailure = RecordingLoader()
        statusFailure.throwOnCall = true
        do {
            _ = try await NativePortalAdministrationService(endpoint: endpoint, loader: statusFailure)
                .status(customerId: "cust-1", sessionBytes: session)
            expect(false, "status timeout must surface unavailable")
        } catch NativePortalAdminError.unavailable { expect(true, "read-only timeout stays retryable") }

        // No secrets in diagnostics.
        for error: NativePortalAdminError in [
            .invalidConfiguration, .malformedSession, .rejectedSession, .invalidRequest,
            .notFound, .alreadyExists, .operationConflict, .rateLimited,
            .invalidResponse, .unavailable, .unknownOutcome, .customerChanged,
        ] {
            let text = error.errorDescription ?? ""
            expect(!text.contains("verified-owner-jwt") && !text.contains(token48),
                   "diagnostic for \(error) carries no secret")
        }

        // Share URL: only a current 48-hex capability becomes a URL.
        let shareURL = NativePortalAdministrationService.portalURL(token: token48)
        expect(shareURL?.absoluteString == "https://gettradereadyapp.com/portal.html?p=\(token48)",
               "share URL uses the frozen public base with encoded token")
        expect(NativePortalAdministrationService.portalURL(token: "legacy-blob-copy") == nil,
               "a legacy display copy never becomes a share URL without validation")
        expect(shareURL.map { NativePortalAdministrationService.isValidPortalURL($0, token: token48) } == true,
               "minted URL validates against its token")
        expect(NativePortalAdministrationService.isValidPortalURL(
            URL(string: "https://gettradereadyapp.com/portal.html?p=\(token48)")!,
            token: String(repeating: "ef", count: 24)
        ) == false, "cross-token URL fails closed")

        // Local-mirror handoff: server success mirrors only token/enabled on
        // the EXACT customer and preserves unknown fields; a local-save
        // failure keeps the operation identity without repeating server work.
        let customer: Canonical.Customer = try JSONDecoder().decode(Canonical.Customer.self, from: Data("""
        {"id":"cust-1","name":"Dana","email":"d@example.com","phone":"p",
         "address":"a","notes":"n","portal":{"token":"old","enabled":false,"portalFuture":"keep"},
         "customerFuture":"keep"}
        """.utf8))
        let mirrored = try NativePortalAdminMirror.apply(to: customer, customerId: "cust-1", token: token48, enabled: true)
        expect(mirrored.portal?.token == token48 && mirrored.portal?.enabled == true,
               "mirror writes only the server token and enabled flag")
        expect(mirrored.name == "Dana" && mirrored.email == "d@example.com",
               "mirror never touches unrelated customer fields")
        let roundTripped = try JSONDecoder().decode(
            [String: Canonical.JSONValue].self, from: JSONEncoder().encode(mirrored)
        )
        if case let .object(portal) = roundTripped["portal"] {
            expect(portal["portalFuture"] == .string("keep"), "mirror preserves portal unknown fields")
        } else { expect(false, "mirrored portal round-trips") }
        expect(roundTripped["customerFuture"] == .string("keep"), "mirror preserves customer unknown fields")

        // Exact-ID recheck at the mirror boundary.
        do {
            _ = try NativePortalAdminMirror.apply(to: customer, customerId: "cust-other", token: token48, enabled: true)
            expect(false, "mirror for another customer must fail closed")
        } catch NativePortalAdminError.customerChanged { expect(true, "cross-customer mirror is classified") }

        // Flag-only mirror preserves the token; link-less flag mirror fails.
        let flagged = try NativePortalAdminMirror.apply(to: mirrored, customerId: "cust-1", token: nil, enabled: false)
        expect(flagged.portal?.token == token48 && flagged.portal?.enabled == false,
               "flag-only mirror preserves the current token")
        var linkless = customer
        linkless.portal = nil
        do {
            _ = try NativePortalAdminMirror.apply(to: linkless, customerId: "cust-1", token: nil, enabled: true)
            expect(false, "flag-only mirror without a portal copy must fail closed")
        } catch NativePortalAdminError.invalidResponse { expect(true, "portal-less flag mirror is classified") }

        // Server-success/local-mirror handoff: the typed result survives a
        // persistence failure; recovery replays persistence only.
        let handoffLoader = RecordingLoader()
        handoffLoader.enqueue(#"{"ok":true,"token":"\#(token48)"}"#, status: 200)
        let handoffResult = try await NativePortalAdministrationService(endpoint: endpoint, loader: handoffLoader)
            .mint(customerId: "cust-1", operationId: operation, sessionBytes: session)
        struct PersistenceFailure: Error {}
        do {
            _ = try NativePortalAdminMirror.apply(
                to: customer, customerId: handoffResult.customerId,
                token: handoffResult.token, enabled: true
            )
            throw PersistenceFailure()
        } catch is PersistenceFailure {
            expect(handoffLoader.requests.count == 1,
                   "local-save failure retains the server result without repeating server work")
        }
        let recovered = try NativePortalAdminMirror.apply(
            to: customer, customerId: handoffResult.customerId,
            token: handoffResult.token, enabled: true
        )
        expect(recovered.portal?.token == token48 && handoffResult.operationId == operation
                && handoffLoader.requests.count == 1,
               "recovery retries display-copy persistence under the same operation identity")

        if failures > 0 { Foundation.exit(1) }
        print("PASS: native portal-administration transport tests")
    }
}
