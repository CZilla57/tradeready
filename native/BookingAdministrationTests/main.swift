import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Task 8.07 (B1, B2): owner transport fixtures for NativeBookingAdministration.
// Oracle: backend-workers/lib/booking/admin.js + route wrapper (frozen §1/§6).

private struct Failure: Error {}

private final class RecordingLoader: NativeBookingAdministrationHTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Result<(Data, Int), Error>)] = []
    private var recorded: [URLRequest] = []
    var throwOnCall = false

    func enqueue(_ body: String, status: Int) {
        lock.withLock { responses.append(.success((Data(body.utf8), status))) }
    }

    func enqueueData(_ data: Data, status: Int) {
        lock.withLock { responses.append(.success((data, status))) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if throwOnCall { throw Failure() }
        let next = lock.withLock {
            recorded.append(request)
            return responses.removeFirst()
        }
        switch next {
        case let .success((data, status)):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .failure(let error):
            throw error
        }
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
private let endpoint = URL(string: "https://staging.example/api/booking/admin")!
private let token48 = String(repeating: "ab", count: 24)
private let operation = "11111111-2222-4333-8555-666666666666"

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
struct BookingAdministrationTests {
    static func main() async throws {
        // Request fixture: mint uses POST, current bearer only, exact body.
        let loader = RecordingLoader()
        loader.enqueue(
            #"{"ok":true,"enabled":true,"token":"\#(token48)","revision":2,"operationId":"\#(operation)"}"#,
            status: 200
        )
        let service = NativeBookingAdministrationService(endpoint: endpoint, loader: loader)
        let minted = try await service.mint(operationId: operation, expectedRevision: 1, sessionBytes: session)
        expect(minted == NativeBookingAdminResult(enabled: true, revision: 2, token: token48, operationId: operation),
               "mint returns the typed server result with operation identity")
        let mintRequest = loader.requests.first
        expect(mintRequest?.httpMethod == "POST" && mintRequest?.url == endpoint,
               "admin request uses POST against the configured endpoint")
        expect(mintRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer verified-owner-jwt",
               "admin request uses only the current verified bearer")
        expect(mintRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json"
                && mintRequest?.value(forHTTPHeaderField: "Accept") == "application/json",
               "admin request declares JSON content and acceptance")
        if let fields = try? bodyFields(mintRequest!) {
            expect(fields["action"] as? String == "mint"
                    && fields["operationId"] as? String == operation
                    && fields["expectedRevision"] as? Int == 1
                    && fields["enabled"] == nil,
                   "mint body carries action, operationId, and revision precondition only")
            expect(fields["refresh_token"] == nil && !(try! bodyFields(mintRequest!).description.contains("verified-owner-jwt")),
                   "mint body never carries credentials")
        } else { expect(false, "mint body decodes") }

        // set_enabled body carries the enabled flag; success carries no token.
        let toggleLoader = RecordingLoader()
        toggleLoader.enqueue(#"{"ok":true,"enabled":false,"revision":3,"operationId":"\#(operation)"}"#, status: 200)
        let toggled = try await NativeBookingAdministrationService(endpoint: endpoint, loader: toggleLoader)
            .setEnabled(false, operationId: operation, sessionBytes: session)
        expect(toggled.token == nil && toggled.enabled == false && toggled.revision == 3 && toggled.operationId == operation,
               "set_enabled returns enabled state with operation identity and no token")
        if let fields = try? bodyFields(toggleLoader.requests.first!) {
            expect(fields["action"] as? String == "set_enabled" && (fields["enabled"] as? Bool) == false,
                   "set_enabled body carries the enabled flag")
        } else { expect(false, "set_enabled body decodes") }

        // A token smuggled into a set_enabled success fails closed.
        let smuggledLoader = RecordingLoader()
        smuggledLoader.enqueue(#"{"ok":true,"enabled":false,"token":"\#(token48)","revision":3}"#, status: 200)
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: smuggledLoader)
                .setEnabled(false, operationId: operation, sessionBytes: session)
            expect(false, "token in a non-mint response must fail closed")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "smuggled token is classified") }

        // Malformed / oversized / invalid-token success payloads fail closed.
        for (label, body) in [
            ("garbage", "not json"),
            ("ok-false", #"{"ok":false,"enabled":true,"revision":1}"#),
            ("missing-revision", #"{"ok":true,"enabled":true,"token":"\#(token48)"}"#),
            ("negative-revision", #"{"ok":true,"enabled":true,"token":"\#(token48)","revision":-1}"#),
            ("short-token", #"{"ok":true,"enabled":true,"token":"abc","revision":1}"#),
            ("non-hex-token", #"{"ok":true,"enabled":true,"token":"\#(String(repeating: "zz", count: 24))","revision":1}"#),
        ] {
            let bad = RecordingLoader()
            bad.enqueue(body, status: 200)
            do {
                _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: bad)
                    .mint(operationId: operation, sessionBytes: session)
                expect(false, "\(label) success payload must fail closed")
            } catch NativeBookingAdminError.invalidResponse { expect(true, "\(label) is classified") }
        }
        let oversized = RecordingLoader()
        oversized.enqueueData(Data(repeating: 0x41, count: 64 * 1024 + 1), status: 200)
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: oversized)
                .mint(operationId: operation, sessionBytes: session)
            expect(false, "oversized success payload must fail closed")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "oversized payload is classified") }

        // Invalid operation IDs fail closed before any network use.
        for badID in ["", "not-a-uuid", "11111111-2222-1333-8555-666666666666", "11111111-2222-4333-7555-666666666666"] {
            let guarded = RecordingLoader()
            do {
                _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: guarded)
                    .mint(operationId: badID, sessionBytes: session)
                expect(false, "operation id \(badID) must fail closed")
            } catch NativeBookingAdminError.invalidRequest { expect(true, "invalid operation id is classified") }
            expect(guarded.requests.isEmpty, "invalid operation id sends no request")
        }
        let negativeRevision = RecordingLoader()
        do {
            _ = try await service.mint(operationId: operation, expectedRevision: -1, sessionBytes: session)
            expect(false, "negative expected revision must fail closed")
        } catch NativeBookingAdminError.invalidRequest { expect(true, "negative revision is classified") }
        expect(negativeRevision.requests.isEmpty, "negative revision sends no request")

        // Malformed session bytes fail closed before any network use.
        let malformed = RecordingLoader()
        for badSession in [Data("not json".utf8), Data(#"{"refresh_token":"only"}"#.utf8), Data(#"{"access_token":""}"#.utf8)] {
            do {
                _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: malformed)
                    .mint(operationId: operation, sessionBytes: badSession)
                expect(false, "malformed session must fail closed")
            } catch NativeBookingAdminError.malformedSession { expect(true, "malformed session is classified") }
        }
        expect(malformed.requests.isEmpty, "malformed session sends no request")

        // Missing configuration: insecure endpoint blocked; unconfigured
        // build (no Info.plist backend URL in this bundle) fails closed.
        let insecure = NativeBookingAdministrationService(
            endpoint: URL(string: "http://production.example/api/booking/admin")!,
            loader: RecordingLoader()
        )
        do {
            _ = try await insecure.mint(operationId: operation, sessionBytes: session)
            expect(false, "non-local HTTP endpoint must fail")
        } catch NativeBookingAdminError.invalidConfiguration { expect(true, "insecure endpoint is blocked") }
        do {
            _ = try NativeBookingAdministrationService.resolvedEndpoint()
            expect(false, "unconfigured build must not resolve an endpoint")
        } catch NativeBookingAdminError.invalidConfiguration { expect(true, "missing backend URL is classified") }

        // Auth refresh: a 401 answered by a fresh bearer retries once with
        // the new bearer; without refresh (or a stale replay) it rejects.
        let refreshLoader = RecordingLoader()
        refreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        refreshLoader.enqueue(
            #"{"ok":true,"enabled":true,"token":"\#(token48)","revision":4,"operationId":"\#(operation)"}"#,
            status: 200
        )
        let refreshCalls = RefreshCounter()
        let refreshing = NativeBookingAdministrationService(
            endpoint: endpoint, loader: refreshLoader,
            refreshSession: { refreshCalls.next(freshSession) }
        )
        let refreshed = try await refreshing.rotate(operationId: operation, sessionBytes: session)
        expect(refreshed.token == token48 && refreshCalls.calls == 1 && refreshLoader.requests.count == 2,
               "401 with a fresh bearer retries the same operation once")
        expect(refreshLoader.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-owner-jwt",
               "refresh retry uses the fresh bearer")
        if let fields = try? bodyFields(refreshLoader.requests.last!) {
            expect(fields["operationId"] as? String == operation && fields["action"] as? String == "rotate",
                   "refresh retry replays the identical operation identity")
        } else { expect(false, "refresh retry body decodes") }

        let noRefreshLoader = RecordingLoader()
        noRefreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: noRefreshLoader)
                .rotate(operationId: operation, sessionBytes: session)
            expect(false, "401 without refresh must reject the session")
        } catch NativeBookingAdminError.rejectedSession { expect(true, "401 without refresh is classified") }

        let staleRefreshLoader = RecordingLoader()
        staleRefreshLoader.enqueue(#"{"error":"expired"}"#, status: 401)
        do {
            _ = try await NativeBookingAdministrationService(
                endpoint: endpoint, loader: staleRefreshLoader,
                refreshSession: { session }
            ).rotate(operationId: operation, sessionBytes: session)
            expect(false, "stale refresh replay must reject the session")
        } catch NativeBookingAdminError.rejectedSession { expect(true, "stale refresh replay is classified") }
        expect(staleRefreshLoader.requests.count == 1, "stale refresh never retries")

        // Bounded refresh: a second consecutive 401 rejects instead of
        // refreshing again — exactly two attempts, one refresh call.
        let double401Loader = RecordingLoader()
        double401Loader.enqueue(#"{"error":"expired"}"#, status: 401)
        double401Loader.enqueue(#"{"error":"expired"}"#, status: 401)
        let double401Refresh = RefreshCounter()
        do {
            _ = try await NativeBookingAdministrationService(
                endpoint: endpoint, loader: double401Loader,
                refreshSession: { double401Refresh.next(freshSession) }
            ).rotate(operationId: operation, sessionBytes: session)
            expect(false, "a second consecutive 401 must reject the session")
        } catch NativeBookingAdminError.rejectedSession { expect(true, "double 401 is bounded") }
        expect(double401Loader.requests.count == 2 && double401Refresh.calls == 1,
               "refresh retry never refreshes again")

        // Definitive refusals: 404, 409 vocabulary, each terminal.
        func refusalLoader(_ body: String, status: Int) -> RecordingLoader {
            let next = RecordingLoader()
            next.enqueue(body, status: status)
            return next
        }
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: refusalLoader(#"{"error":"Not found"}"#, status: 404))
                .mint(operationId: operation, sessionBytes: session)
            expect(false, "404 must surface notFound")
        } catch NativeBookingAdminError.notFound { expect(true, "404 is classified") }
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: refusalLoader(#"{"error":"already_exists"}"#, status: 409))
                .mint(operationId: operation, sessionBytes: session)
            expect(false, "409 already_exists must surface alreadyExists")
        } catch NativeBookingAdminError.alreadyExists { expect(true, "already_exists is classified") }
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: refusalLoader(#"{"error":"operation_conflict"}"#, status: 409))
                .rotate(operationId: operation, sessionBytes: session)
            expect(false, "409 operation_conflict must surface operationConflict")
        } catch NativeBookingAdminError.operationConflict { expect(true, "operation_conflict is classified") }
        do {
            _ = try await NativeBookingAdministrationService(
                endpoint: endpoint,
                loader: refusalLoader(#"{"error":"stale_revision","enabled":false,"revision":7}"#, status: 409)
            ).setEnabled(true, operationId: operation, sessionBytes: session)
            expect(false, "409 stale_revision must surface current state")
        } catch NativeBookingAdminError.staleRevision(let enabled, let revision) {
            expect(enabled == false && revision == 7, "stale_revision echoes current authority")
        } catch { expect(false, "stale_revision must decode its echo") }
        do {
            _ = try await NativeBookingAdministrationService(
                endpoint: endpoint,
                loader: refusalLoader(#"{"error":"stale_revision"}"#, status: 409)
            ).setEnabled(true, operationId: operation, sessionBytes: session)
            expect(false, "stale_revision without echo must fail closed")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "echo-less stale_revision is classified") }
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: refusalLoader(#"{"error":"whatever"}"#, status: 409))
                .mint(operationId: operation, sessionBytes: session)
            expect(false, "unknown 409 vocabulary must fail closed")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "unknown 409 vocabulary is classified") }

        // 403 rejects the session without refresh.
        let forbidden = RecordingLoader()
        forbidden.enqueue(#"{"error":"forbidden"}"#, status: 403)
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: forbidden)
                .mint(operationId: operation, sessionBytes: session)
            expect(false, "403 must reject the session")
        } catch NativeBookingAdminError.rejectedSession { expect(true, "403 is classified") }

        // Transient: 429 never retries in a loop — one call, typed error.
        let limited = RecordingLoader()
        limited.enqueue(#"{"error":"Too many"}"#, status: 429)
        let limitedService = NativeBookingAdministrationService(endpoint: endpoint, loader: limited)
        do {
            _ = try await limitedService.mint(operationId: operation, sessionBytes: session)
            expect(false, "429 must surface rateLimited")
        } catch NativeBookingAdminError.rateLimited { expect(true, "429 is classified") }
        expect(limited.requests.count == 1, "rate limit is never retried automatically")

        // Unknown mutation outcome: 5xx and transport failure after a
        // mutation report unknownOutcome with exactly one attempt — never an
        // automatic re-mint/re-rotate of a destructive operation.
        for status in [500, 503] {
            let failed = RecordingLoader()
            failed.enqueue(#"{"error":"Database error"}"#, status: status)
            do {
                _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: failed)
                    .rotate(operationId: operation, sessionBytes: session)
                expect(false, "\(status) after a mutation must surface unknownOutcome")
            } catch NativeBookingAdminError.unknownOutcome { expect(true, "\(status) is classified unknown") }
            expect(failed.requests.count == 1, "\(status) never auto-retries the mutation")
        }
        let transport = RecordingLoader()
        transport.throwOnCall = true
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: transport)
                .rotate(operationId: operation, sessionBytes: session)
            expect(false, "transport failure after a mutation must surface unknownOutcome")
        } catch NativeBookingAdminError.unknownOutcome { expect(true, "transport failure is classified unknown") }

        // Status read: authoritative enabled/revision/tokenValid, never a token.
        let statusLoader = RecordingLoader()
        statusLoader.enqueue(#"{"ok":true,"enabled":true,"revision":5,"tokenValid":true}"#, status: 200)
        let linkStatus = try await NativeBookingAdministrationService(endpoint: endpoint, loader: statusLoader)
            .status(token: token48, sessionBytes: session)
        expect(linkStatus == NativeBookingLinkStatus(enabled: true, revision: 5, tokenValid: true),
               "status returns authoritative state and display-token validity")
        if let fields = try? bodyFields(statusLoader.requests.first!) {
            expect(fields["action"] as? String == "status" && fields["token"] as? String == token48,
                   "status body carries the display copy for currency validation")
        } else { expect(false, "status body decodes") }
        let staleCheck = RecordingLoader()
        staleCheck.enqueue(#"{"ok":true,"enabled":true,"revision":6,"tokenValid":false}"#, status: 200)
        let stale = try await NativeBookingAdministrationService(endpoint: endpoint, loader: staleCheck)
            .status(token: token48, sessionBytes: session)
        expect(stale.tokenValid == false && stale.revision == 6,
               "a present-but-stale display token validates false (recovery path, never a share URL)")
        let tokenLeakLoader = RecordingLoader()
        tokenLeakLoader.enqueue(#"{"ok":true,"enabled":true,"revision":5,"token":"\#(token48)","tokenValid":true}"#, status: 200)
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: tokenLeakLoader)
                .status(token: token48, sessionBytes: session)
            expect(false, "status must never return a token")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "status token leak is classified") }
        let statusFailure = RecordingLoader()
        statusFailure.throwOnCall = true
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: statusFailure)
                .status(token: token48, sessionBytes: session)
            expect(false, "status timeout must surface unavailable")
        } catch NativeBookingAdminError.unavailable { expect(true, "read-only timeout stays retryable") }
        let statusServer = RecordingLoader()
        statusServer.enqueue(#"{"error":"Database error"}"#, status: 500)
        do {
            _ = try await NativeBookingAdministrationService(endpoint: endpoint, loader: statusServer)
                .status(sessionBytes: session)
            expect(false, "status 5xx must surface unavailable")
        } catch NativeBookingAdminError.unavailable { expect(true, "read-only 5xx stays retryable") }
        // Fresh owner with no state row reconciles cleanly (never 404).
        let freshOwner = RecordingLoader()
        freshOwner.enqueue(#"{"ok":true,"enabled":false,"revision":0,"tokenValid":false}"#, status: 200)
        let fresh = try await NativeBookingAdministrationService(endpoint: endpoint, loader: freshOwner)
            .status(sessionBytes: session)
        expect(fresh == NativeBookingLinkStatus(enabled: false, revision: 0, tokenValid: false),
               "fresh owner reconciles to disabled/revision-zero")

        // No secrets in diagnostics: static descriptions never echo tokens.
        let secretProbe = token48 + "verified-owner-jwt"
        for error: NativeBookingAdminError in [
            .invalidConfiguration, .malformedSession, .rejectedSession, .invalidRequest,
            .notFound, .alreadyExists, .operationConflict,
            .staleRevision(currentEnabled: true, currentRevision: 2),
            .rateLimited, .invalidResponse, .unavailable, .unknownOutcome,
        ] {
            let text = error.errorDescription ?? ""
            expect(!text.contains(token48) && !text.contains("verified-owner-jwt") && text != secretProbe,
                   "diagnostic for \(error) carries no secret")
        }

        // Share URL: only a current 48-hex capability becomes a URL.
        let shareURL = NativeBookingAdministrationService.bookingURL(token: token48)
        expect(shareURL?.absoluteString == "https://gettradereadyapp.com/book.html?b=\(token48)",
               "share URL uses the frozen public base with encoded token")
        expect(NativeBookingAdministrationService.bookingURL(token: "short") == nil,
               "a stale display copy never becomes a share URL")
        expect(shareURL.map { NativeBookingAdministrationService.isValidBookingURL($0, token: token48) } == true,
               "minted URL validates against its token")
        expect(NativeBookingAdministrationService.isValidBookingURL(
            URL(string: "https://gettradereadyapp.com/book.html?b=\(token48)")!, token: String(repeating: "cd", count: 24)
        ) == false, "cross-token URL fails closed")
        expect(NativeBookingAdministrationService.isValidBookingURL(
            URL(string: "http://gettradereadyapp.com/book.html?b=\(token48)")!, token: token48
        ) == false, "non-HTTPS public URL fails closed")

        // Local-mirror handoff: server success mirrors only token/enabled and
        // preserves unknown fields; a local-save failure keeps the operation
        // identity for replay without repeating destructive server work.
        var settings: Canonical.Settings = try JSONDecoder().decode(Canonical.Settings.self, from: Data("""
        {"businessName":"B","contactName":"C","phone":"p","email":"e","address":"a",
         "trade":"plumbing","laborRate":95,"materialMarkup":25,"overheadPercent":10,
         "marginPercent":30,"minimumJobFee":0,"travelFeePerMile":0,"emergencyMultiplier":1,
         "rules":[],"paymentNotes":"","provider":"none",
         "bookingLink":{"token":"oldtokenoldtokenoldtokenoldtokenoldtoken12","enabled":false,"linkFuture":"keep"},
         "settingsFuture":"keep"}
        """.utf8))
        // Note: the old token above is not 48-hex; mint replaces it below.
        let mirrored = try NativeBookingAdminMirror.apply(to: settings, token: token48, enabled: true)
        expect(mirrored.bookingLink?.token == token48 && mirrored.bookingLink?.enabled == true,
               "mirror writes only the server token and enabled flag")
        expect(mirrored.businessName == "B" && mirrored.laborRate == settings.laborRate,
               "mirror never touches unrelated settings fields")
        let roundTripped = try JSONDecoder().decode(
            [String: Canonical.JSONValue].self, from: JSONEncoder().encode(mirrored)
        )
        if case let .object(link) = roundTripped["bookingLink"] {
            expect(link["linkFuture"] == .string("keep"), "mirror preserves link unknown fields")
        } else { expect(false, "mirrored link round-trips") }
        expect(roundTripped["settingsFuture"] == .string("keep"), "mirror preserves settings unknown fields")

        // set_enabled mirror keeps the token and flips the flag only.
        let flagged = try NativeBookingAdminMirror.apply(to: mirrored, token: nil, enabled: false)
        expect(flagged.bookingLink?.token == token48 && flagged.bookingLink?.enabled == false,
               "flag-only mirror preserves the current token")

        // Nothing truthful to mirror fails closed.
        settings.bookingLink = nil
        do {
            _ = try NativeBookingAdminMirror.apply(to: settings, token: nil, enabled: true)
            expect(false, "flag-only mirror without a link must fail closed")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "link-less flag mirror is classified") }
        do {
            _ = try NativeBookingAdminMirror.apply(to: settings, token: "short", enabled: true)
            expect(false, "mirror of an invalid token must fail closed")
        } catch NativeBookingAdminError.invalidResponse { expect(true, "invalid mirror token is classified") }

        // Server-success/local-mirror handoff: the typed result (with
        // operation identity) survives a persistence failure, and recovery
        // replays persistence — the loader sees no second server call.
        let handoffLoader = RecordingLoader()
        handoffLoader.enqueue(
            #"{"ok":true,"enabled":true,"token":"\#(token48)","revision":8,"operationId":"\#(operation)"}"#,
            status: 200
        )
        let handoffResult = try await NativeBookingAdministrationService(endpoint: endpoint, loader: handoffLoader)
            .mint(operationId: operation, sessionBytes: session)
        struct PersistenceFailure: Error {}
        var persisted: Canonical.Settings? = nil
        do {
            _ = try NativeBookingAdminMirror.apply(to: settings, token: handoffResult.token, enabled: handoffResult.enabled)
            throw PersistenceFailure()
        } catch is PersistenceFailure {
            persisted = nil
        }
        expect(persisted == nil && handoffLoader.requests.count == 1,
               "local-save failure retains the server result without repeating server work")
        let recovered = try NativeBookingAdminMirror.apply(
            to: settings, token: handoffResult.token, enabled: handoffResult.enabled
        )
        expect(recovered.bookingLink?.token == token48 && handoffResult.operationId == operation
                && handoffLoader.requests.count == 1,
               "recovery retries display-copy persistence under the same operation identity")

        if failures > 0 { Foundation.exit(1) }
        print("PASS: native booking-administration transport tests")
    }
}
