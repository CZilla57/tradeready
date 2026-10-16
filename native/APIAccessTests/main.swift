import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Roadmap Phase 23 (open-API spec §9, §10 "Native"; manage contract §14.1):
// Settings › API access without the AppStore. Domain rules, the manage
// transport (request shaping, endpoint allowlist, refresh-once, every error
// code, Retry-After), the view model (operation-id reuse on retry, no double
// submit, the 429 wait, the show-once key cleared on dismiss) and source
// guards (flag off hides the entry; nothing logs or persists the key).
// Oracle: backend-workers/lib/api/keyAdmin.js, lib/api/keys.js.

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private struct TransportFailure: Error {}

// MARK: - Fixtures

private let rawSecret = "trk_Ab3dE9fQ" + String(repeating: "k", count: 99)
private let rotatedSecret = "trk_Zz9yX8wV" + String(repeating: "m", count: 99)
private let keyID = "6f1c2a3b-4d5e-4f60-8a7b-8c9d0e1f2a3b"
private let newKeyID = "7a2d3b4c-5e6f-4a71-9b8c-9dae0f1a2b3c"
private let opID = "21111111-2222-4333-8555-666666666666"
private let session = Data(#"{"access_token":"verified-owner-jwt","refresh_token":"not-sent"}"#.utf8)
private let freshSession = Data(#"{"access_token":"refreshed-owner-jwt"}"#.utf8)
private let endpoint = URL(string: "https://staging.example/api/api-keys/manage")!
private let iso = ISO8601DateFormatter()
private let now = iso.date(from: "2026-10-03T17:00:00Z")!
private let phoenix = TimeZone(identifier: "America/Phoenix")!
private let enUS = Locale(identifier: "en_US")

private func keyJSON(
    id: String = keyID,
    name: String = "QuickBooks sync",
    prefix: String = "trk_Ab3dE9fQ",
    scopes: [String] = ["customers:read", "invoices:read"],
    createdAt: String? = "2026-10-03T17:00:00.000Z",
    expiresAt: String? = "2027-10-03T17:00:00.000Z",
    revokedAt: String? = nil,
    lastUsedAt: String? = nil,
    replacedBy: String? = nil,
    status: String = "active"
) -> String {
    func q(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
    let scopeList = scopes.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"\#(id)","name":"\#(name)","prefix":"\#(prefix)","scopes":[\#(scopeList)],"createdAt":\#(q(createdAt)),"expiresAt":\#(q(expiresAt)),"revokedAt":\#(q(revokedAt)),"lastUsedAt":\#(q(lastUsedAt)),"replacedBy":\#(q(replacedBy)),"status":"\#(status)"}"#
}

private func summary(
    id: String = keyID,
    name: String = "QuickBooks sync",
    prefix: String = "trk_Ab3dE9fQ",
    scopes: [NativeAPIScope] = [.customers, .invoices],
    expiresAt: Date? = iso.date(from: "2027-10-03T17:00:00Z"),
    revokedAt: Date? = nil,
    lastUsedAt: Date? = nil,
    replacedBy: String? = nil,
    status: NativeAPIKeyStatus = .active
) -> NativeAPIKeySummary {
    NativeAPIKeySummary(
        id: id, name: name, prefix: prefix, scopes: scopes, createdAt: now, expiresAt: expiresAt,
        revokedAt: revokedAt, lastUsedAt: lastUsedAt, replacedBy: replacedBy, status: status
    )
}

private final class RecordingLoader: NativeAPIKeyAdministrationHTTPDataLoading, @unchecked Sendable {
    enum Reply { case http(String, Int, [String: String]); case fail(Error) }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var recorded: [URLRequest] = []

    func enqueue(_ body: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.withLock { replies.append(.http(body, status, headers)) }
    }

    func enqueueFailure(_ error: Error) { lock.withLock { replies.append(.fail(error)) } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? .fail(TransportFailure()) : replies.removeFirst()
        }
        switch reply {
        case let .fail(error): throw error
        case let .http(body, status, headers):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let fresh: Data?
    init(_ fresh: Data?) { self.fresh = fresh }
    func next() -> Data? { lock.withLock { count += 1 }; return fresh }
    var calls: Int { lock.withLock { count } }
}

private func bodyString(_ request: URLRequest?) -> String {
    request?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

private func service(_ loader: RecordingLoader, refresh: RefreshCounter? = nil, url: URL = endpoint) -> NativeAPIKeyAdministrationService {
    NativeAPIKeyAdministrationService(
        endpoint: url, loader: loader,
        refreshSession: refresh.map { counter in { counter.next() } },
        now: { now }
    )
}

private func caught<T>(_ body: () async throws -> T) async -> NativeAPIKeyAdminError? {
    do { _ = try await body(); return nil } catch { return error as? NativeAPIKeyAdminError ?? .invalidResponse }
}

/// Every place a `NativeAPIKeySecret` or the raw key is reachable from
/// `root` by reflection. A positive control proves the walk sees through
/// `@Published` storage.
private func reachableSecrets(_ root: Any, raw: String) -> [String] {
    var found: [String] = []
    var seen = Set<ObjectIdentifier>()
    func visit(_ value: Any, _ path: String, _ depth: Int) {
        guard depth < 14 else { return }
        if value is NativeAPIKeySecret { found.append("\(path) (NativeAPIKeySecret)"); return }
        if let text = value as? String {
            if text.contains(raw) { found.append(path) }
            return
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class {
            let object = value as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
        }
        var current: Mirror? = mirror
        while let level = current {
            for (index, child) in level.children.enumerated() {
                visit(child.value, "\(path).\(child.label ?? "\(index)")", depth + 1)
            }
            current = level.superclassMirror
        }
    }
    visit(root, "root", 0)
    return found
}

// MARK: - Fake manager for the view model

@MainActor
private final class FakeManager: NativeAPIKeyManaging {
    var listResults: [Result<NativeAPIKeyList, Error>] = []
    var createResults: [Result<NativeAPIKeyIssued, Error>] = []
    var rotateResults: [Result<NativeAPIKeyIssued, Error>] = []
    var revokeResults: [Result<NativeAPIKeySummary, Error>] = []
    var activityResults: [Result<[NativeAPIActivityEvent], Error>] = []
    var calls: [String] = []
    var createCalls: [(request: NativeAPIKeyCreateRequest, operationId: String)] = []
    var rotateCalls: [(keyId: String, grace: NativeAPIKeyGrace, operationId: String)] = []
    var holdCreate = false
    private var held: CheckedContinuation<Void, Never>?

    func release() { held?.resume(); held = nil }

    func list() async throws -> NativeAPIKeyList {
        calls.append("list")
        return try (listResults.isEmpty ? .failure(NativeAPIKeyAdminError.offline) : listResults.removeFirst()).get()
    }

    func create(_ request: NativeAPIKeyCreateRequest, operationId: String) async throws -> NativeAPIKeyIssued {
        calls.append("create")
        createCalls.append((request, operationId))
        if holdCreate {
            holdCreate = false
            await withCheckedContinuation { held = $0 }
        }
        return try (createResults.isEmpty ? .failure(NativeAPIKeyAdminError.unknownOutcome) : createResults.removeFirst()).get()
    }

    func rotate(keyId: String, grace: NativeAPIKeyGrace, operationId: String) async throws -> NativeAPIKeyIssued {
        calls.append("rotate")
        rotateCalls.append((keyId, grace, operationId))
        return try (rotateResults.isEmpty ? .failure(NativeAPIKeyAdminError.unknownOutcome) : rotateResults.removeFirst()).get()
    }

    func revoke(keyId: String) async throws -> NativeAPIKeySummary {
        calls.append("revoke:\(keyId)")
        return try (revokeResults.isEmpty ? .failure(NativeAPIKeyAdminError.unknownOutcome) : revokeResults.removeFirst()).get()
    }

    func activity(keyId: String?) async throws -> [NativeAPIActivityEvent] {
        calls.append("activity")
        return try (activityResults.isEmpty ? .failure(NativeAPIKeyAdminError.offline) : activityResults.removeFirst()).get()
    }
}

@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private final class Harness {
    let manager = FakeManager()
    let clock = Clock(now)
    var tracked: [NativeAPIAccessAnalyticsEvent] = []
    var operationIDs: [String] = []
    var sleeps: [TimeInterval] = []
    private var nextID = 0
    lazy var model: NativeAPIAccessModel = NativeAPIAccessModel(
        manager: manager,
        track: { [unowned self] in self.tracked.append($0) },
        now: { [unowned self] in self.clock.now },
        makeOperationID: { [unowned self] in
            self.nextID += 1
            let id = String(format: "%08d-0000-4000-8000-000000000000", self.nextID)
            self.operationIDs.append(id)
            return id
        },
        sleep: { _ in }
    )

    func loaded(_ keys: [NativeAPIKeySummary] = [summary()], max: Int = 5) async {
        manager.listResults.append(.success(NativeAPIKeyList(keys: keys, maxLiveKeys: max)))
        await model.load()
    }
}

private func issued(_ raw: String = rawSecret, key: NativeAPIKeySummary? = nil, previous: NativeAPIKeySummary? = nil) -> NativeAPIKeyIssued {
    NativeAPIKeyIssued(
        key: key ?? summary(id: newKeyID, name: "Zapier", prefix: String(raw.prefix(12)), scopes: NativeAPIScope.allCases),
        secret: NativeAPIKeySecret(raw)!,
        previous: previous
    )
}

private let request = NativeAPIKeyCreateRequest(name: "Zapier", scopes: NativeAPIScope.allCases, expiry: .oneYear)

@main
struct APIAccessTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        domain()
        await transport()
        await errorTable()
        await model()
        sources(root: root)
        if failures > 0 {
            print("API access tests: \(failures) failure(s) of \(checks) checks")
            exit(1)
        }
        print("API access tests passed (\(checks) checks)")
    }

    // MARK: 1. Domain

    static func domain() {
        // Flag (spec §11 stage C): off, and off hides the Settings entry.
        expect(NativeAPIAccessFeature.apiAccessEnabled == true, "flag: apiAccessEnabled is ON")
        expect(NativeAPIAccessFeature.showsSettingsEntry(), "flag: on shows the Settings entry")
        expect(NativeAPIAccessFeature.showsSettingsEntry(flag: true), "flag: on shows the Settings entry")

        // Scopes: the Worker's canonical order and presets (keys.js SCOPES/PRESETS).
        expectEqual(NativeAPIScope.allCases.map(\.rawValue),
                    ["customers:read", "jobs:read", "invoices:read", "expenses:read", "mileage:read"],
                    "scopes: canonical order matches the Worker")
        expectEqual(NativeAPIScopePreset.everything.scopes ?? [], NativeAPIScope.allCases, "preset: Everything is all five")
        expectEqual(NativeAPIScopePreset.bookkeeping.scopes ?? [], [.customers, .invoices, .expenses, .mileage],
                    "preset: Bookkeeping is invoices, expenses, mileage, customers (canonical order)")
        expect(NativeAPIScopePreset.custom.scopes == nil, "preset: Custom has no fixed scopes")
        expectEqual(NativeAPIScopePreset.matching(Set(NativeAPIScope.allCases)), .everything, "preset: all five read as Everything")
        expectEqual(NativeAPIScopePreset.matching([.mileage, .customers, .expenses, .invoices]), .bookkeeping, "preset: Bookkeeping set")
        expectEqual(NativeAPIScopePreset.matching([.jobs]), .custom, "preset: anything else is Custom")
        expectEqual(NativeAPIScope.parse(["mileage:read", "customers:read", "customers:read", "properties:read"]),
                    [.customers, .mileage], "scopes: parse dedupes, orders and skips an unknown later scope")
        expectEqual(NativeAPIKeyExpiry.allCases.map(\.rawValue), ["1y", "90d", "none"], "expiry: wire values")
        expectEqual(NativeAPIKeyExpiry.defaultChoice, .oneYear, "expiry: default 1 year (§2)")
        expectEqual(NativeAPIKeyGrace.allCases.map(\.rawValue), ["24h", "immediate"], "grace: wire values")
        expectEqual(NativeAPIKeyGrace.defaultChoice, .twentyFourHours, "grace: default 24 hours (D3)")

        // Names: keys.js normalizeName (trim, 1–40 UTF-16 units, no control chars).
        expectEqual(try? NativeAPIKeyName.normalize("  QuickBooks sync \n").get(), "QuickBooks sync", "name: trimmed")
        expectEqual(try? NativeAPIKeyName.normalize("\u{FEFF}Zapier").get(), "Zapier", "name: BOM trimmed like JS trim()")
        expect(NativeAPIKeyName.normalize("   ") == .failure(.nameMissing), "name: blank is missing")
        expect((try? NativeAPIKeyName.normalize(String(repeating: "a", count: 40)).get()) != nil, "name: 40 characters allowed")
        expect(NativeAPIKeyName.normalize(String(repeating: "a", count: 41)) == .failure(.nameTooLong), "name: 41 characters refused")
        expect((try? NativeAPIKeyName.normalize(String(repeating: "😀", count: 20)).get()) != nil,
               "name: 20 emoji are 40 UTF-16 units, allowed as in JS")
        expect(NativeAPIKeyName.normalize(String(repeating: "😀", count: 21)) == .failure(.nameTooLong),
               "name: 21 emoji are 42 UTF-16 units, refused as in JS")
        for bad in ["Quick\nBooks", "Bell\u{7}", "Line\u{2028}Sep", "Del\u{7F}", "C1\u{85}"] {
            expect(NativeAPIKeyName.normalize(bad) == .failure(.nameHasControlCharacters), "name: control character refused (\(bad.unicodeScalars.map { String($0.value, radix: 16) }))")
        }
        switch NativeAPIKeyCreateRequest.validated(name: " Books ", scopes: [.mileage, .customers], expiry: .ninetyDays) {
        case let .success(valid):
            expectEqual(valid, NativeAPIKeyCreateRequest(name: "Books", scopes: [.customers, .mileage], expiry: .ninetyDays),
                        "create request: trimmed name, canonical scopes")
        case .failure: expect(false, "create request: valid draft validates")
        }
        expect(NativeAPIKeyCreateRequest.validated(name: "Books", scopes: [], expiry: .oneYear) == .failure(.noScopes),
               "create request: at least one scope")
        for issue in [NativeAPIKeyDraftIssue.nameMissing, .nameTooLong, .nameHasControlCharacters, .noScopes] {
            expect(!issue.message.isEmpty, "draft issue \(issue) has text")
        }

        // The secret: format, and it never prints or reflects.
        expect(NativeAPIKeySecret(rawSecret) != nil, "secret: trk_ + 107 base64url is well formed")
        for bad in ["trk_" + String(repeating: "a", count: 106), "trk_" + String(repeating: "a", count: 108),
                    "trk_" + String(repeating: "a", count: 106) + "+", "trx_" + String(repeating: "a", count: 107),
                    "trk_" + String(repeating: "a", count: 106) + "é", ""] {
            expect(NativeAPIKeySecret(bad) == nil, "secret: malformed value refused (\(bad.count) chars)")
        }
        // The pre-tag format (trk_ + 43) is no longer a key.
        expect(NativeAPIKeySecret("trk_" + String(repeating: "a", count: 43)) == nil, "secret: the untagged 43-character format is refused")
        if let secret = NativeAPIKeySecret(rawSecret) {
            expectEqual(secret.revealedValue, rawSecret, "secret: the sheet can show it")
            var dumped = ""
            dump(secret, to: &dumped)
            for (label, text) in [("description", "\(secret)"), ("debugDescription", String(reflecting: secret)),
                                  ("dump", dumped), ("Mirror", "\(Mirror(reflecting: secret).children.map { "\($0.value)" })"),
                                  ("issued", "\(issued())"), ("optional", "\(Optional(secret) as Any)")] {
                expect(!text.contains(rawSecret) && !text.contains(String(rawSecret.dropFirst(12))),
                       "secret: \(label) never contains the key")
            }
            expect(reachableSecrets(issued(), raw: rawSecret).count == 1,
                   "scanner positive control: finds the one secret inside a create result")
        }

        // Status: the Worker's rule, plus staleness on screen.
        expectEqual(NativeAPIKeyStatus.derive(revokedAt: now, expiresAt: nil, replacedBy: "x", now: now), .revoked, "status: revoked first")
        expectEqual(NativeAPIKeyStatus.derive(revokedAt: nil, expiresAt: now, replacedBy: "x", now: now), .expired, "status: expired at expiresAt")
        expectEqual(NativeAPIKeyStatus.derive(revokedAt: nil, expiresAt: now.addingTimeInterval(60), replacedBy: "x", now: now), .expiring, "status: replaced is expiring")
        expectEqual(NativeAPIKeyStatus.derive(revokedAt: nil, expiresAt: nil, replacedBy: nil, now: now), .active, "status: else active")
        let grace = summary(expiresAt: now.addingTimeInterval(3600), replacedBy: newKeyID, status: .expiring)
        expectEqual(grace.status(at: now.addingTimeInterval(3601)), .expired, "status: a grace key left on screen past its end reads expired")
        expect(!grace.canRotate(at: now) && grace.canRevoke(at: now), "status: a grace key can be revoked, not rotated")
        expect(summary().canRotate(at: now) && summary().canRevoke(at: now), "status: an active key rotates and revokes")
        let revoked = summary(revokedAt: now, status: .revoked)
        expect(!revoked.canRotate(at: now) && !revoked.canRevoke(at: now), "status: a revoked key has no actions")

        // Text: words for every state (no colour-only meaning).
        expectEqual(NativeAPIAccessText.statusDetail(summary(expiresAt: nil), now: now, locale: enUS, timeZone: phoenix), "Never expires", "text: no expiry")
        expect(NativeAPIAccessText.statusDetail(summary(), now: now, locale: enUS, timeZone: phoenix).hasPrefix("Expires Oct 3, 2027"), "text: expiry date")
        expect(NativeAPIAccessText.statusDetail(grace, now: now, locale: enUS, timeZone: phoenix).hasPrefix("Keeps working until Oct 3, 2026"), "text: grace window end")
        expect(NativeAPIAccessText.statusDetail(revoked, now: now, locale: enUS, timeZone: phoenix).hasPrefix("Revoked Oct 3, 2026"), "text: revoked date")
        expectEqual(NativeAPIAccessText.statusTitle(grace, now: now), "Replaced", "text: grace key title")
        expectEqual(NativeAPIAccessText.statusTitle(summary(expiresAt: now.addingTimeInterval(-1)), now: now), "Expired", "text: stale active reads Expired")
        expectEqual(NativeAPIAccessText.lastUsed(summary(), now: now, locale: enUS), "Never used", "text: never used")
        expectEqual(NativeAPIAccessText.lastUsed(summary(lastUsedAt: now.addingTimeInterval(-7200)), now: now, locale: enUS),
                    "Last used 2 hours ago", "text: last used, relative")
        expectEqual(NativeAPIAccessText.scopeSummary(NativeAPIScope.allCases), "Everything", "text: Everything")
        expect(NativeAPIAccessText.scopeSummary([.customers, .invoices, .expenses, .mileage]).hasPrefix("Bookkeeping"), "text: Bookkeeping")
        expectEqual(NativeAPIAccessText.scopeSummary([.jobs, .customers]), "Customers, Jobs and estimates", "text: custom scopes in order")
        let spoken = NativeAPIAccessText.accessibilitySummary(summary(), now: now, locale: enUS, timeZone: phoenix)
        expect(spoken.contains("QuickBooks sync") && spoken.contains("Active") && spoken.contains("trk_Ab3dE9fQ")
               && spoken.contains("Can read Customers, Invoices and payments") && spoken.contains("Never used"),
               "text: one VoiceOver sentence names the key, status, prefix, access and use")
        expect(NativeAPIAccessText.previousKeyNote(grace, now: now)?.contains("keeps working until") == true, "text: rotation grace note")
        expect(NativeAPIAccessText.previousKeyNote(summary(expiresAt: now), now: now)?.contains("stopped") == true, "text: immediate rotation note")
        expectEqual(NativeAPIAccessText.showOnceWarning, "TradeReady can't show this key again.", "text: §9 show-once line")
        expectEqual(NativeAPIAccessText.freshnessNote, "Other tools see your data as of your phone's last sync.", "text: §9 freshness note")
        let event = NativeAPIActivityEvent(id: 0, at: now.addingTimeInterval(-300), keyId: keyID, kind: .denied,
                                           route: "/v1/invoices/:id", status: 403, ip: "203.0.113.9")
        expectEqual(NativeAPIAccessText.activityOutcome(event), "Denied · 403", "text: activity outcome in words and code")
        let eventSpoken = NativeAPIAccessText.activityAccessibility(event, keyName: "QuickBooks sync", now: now, locale: enUS)
        expect(eventSpoken.contains("/v1/invoices/:id") && eventSpoken.contains("Denied, status 403")
               && eventSpoken.contains("5 minutes ago") && eventSpoken.contains("QuickBooks sync") && eventSpoken.contains("203.0.113.9"),
               "text: activity row reads as one sentence")
        expectEqual(NativeAPIActivityKind(raw: "rate_limited"), .rateLimited, "activity: rate_limited kind")
        expectEqual(NativeAPIActivityKind(raw: "later_kind").title, "Other", "activity: unknown kind still has text")

        // Retry-After and the clipboard policy.
        expectEqual(NativeAPIRetryAfter.seconds(from: nil, now: now), 60, "retry-after: absent waits the one-minute window")
        expectEqual(NativeAPIRetryAfter.seconds(from: "17", now: now), 17, "retry-after: delta seconds")
        expectEqual(NativeAPIRetryAfter.seconds(from: "0", now: now), 1, "retry-after: at least one second")
        expectEqual(NativeAPIRetryAfter.seconds(from: "999999", now: now), 3600, "retry-after: capped at an hour")
        expectEqual(NativeAPIRetryAfter.seconds(from: "Sat, 03 Oct 2026 17:00:30 GMT", now: now), 30, "retry-after: HTTP-date")
        expectEqual(NativeAPIRetryAfter.seconds(from: "soon", now: now), 60, "retry-after: unreadable waits the window")
        expect(NativeAPIKeyClipboardPolicy.localOnly, "clipboard: local only (no Universal Clipboard)")
        expectEqual(NativeAPIKeyClipboardPolicy.lifetime, 120, "clipboard: two-minute lifetime")
        expectEqual(NativeAPIKeyClipboardPolicy.expiration(from: now), now.addingTimeInterval(120), "clipboard: expires two minutes after copying")
    }

    // MARK: 2. Transport: request shaping, decoding, refresh

    static func transport() async {
        // list: POST, current bearer, exact body, no cache.
        let loader = RecordingLoader()
        loader.enqueue(#"{"ok":true,"keys":[\#(keyJSON()),\#(keyJSON(id: newKeyID, name: "Old", prefix: "trk_Old00000", scopes: ["mileage:read", "later:read"], createdAt: "2026-01-01T00:00:00Z", expiresAt: "2026-06-01T00:00:00Z", revokedAt: "2026-02-01T00:00:00Z", lastUsedAt: "2026-01-15T10:00:00.123Z", status: "revoked"))],"liveCount":1,"maxLiveKeys":5}"#)
        do {
            let list = try await service(loader).list(sessionBytes: session)
            let first = loader.requests.first
            expect(first?.httpMethod == "POST" && first?.url == endpoint, "list: POST to the manage endpoint")
            expectEqual(first?.value(forHTTPHeaderField: "Authorization"), "Bearer verified-owner-jwt", "list: Supabase JWT bearer only")
            expectEqual(first?.value(forHTTPHeaderField: "Content-Type"), "application/json", "list: JSON body")
            expectEqual(first?.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData, "list: never served from or written to a cache")
            expectEqual(bodyString(first), #"{"action":"list"}"#, "list: exact body")
            expectEqual(list.maxLiveKeys, 5, "list: maxLiveKeys")
            expectEqual(list.keys.count, 2, "list: both keys")
            expectEqual(list.keys.first, summary(), "list: KeySummary decodes exactly (§14.1 example)")
            expectEqual(list.keys.last?.scopes, [.mileage], "list: an unknown later scope is skipped")
            expectEqual(list.keys.last?.status, .revoked, "list: status")
            let fractionalDelta = list.keys.last?.lastUsedAt.flatMap { used in
                iso.date(from: "2026-01-15T10:00:00Z").map { abs(used.timeIntervalSince($0) - 0.123) }
            }
            expect((fractionalDelta ?? 1) < 0.001, "list: fractional timestamps")
        } catch { expect(false, "list decodes (\(error))") }

        // The default loader is ephemeral: no disk cache, no persistent cookies.
        let defaultService = NativeAPIKeyAdministrationService(endpoint: endpoint)
        expect((defaultService.loader as? URLSession) === NativeAPIKeyAdministrationService.ephemeralLoader,
               "transport: the default loader is the ephemeral session")
        expectEqual(NativeAPIKeyAdministrationService.ephemeralLoader.configuration.urlCache?.diskCapacity ?? 0, 0,
                    "transport: the ephemeral session has no disk cache")

        // create: exact body, the secret wrapped, never echoed.
        let createLoader = RecordingLoader()
        createLoader.enqueue(#"{"ok":true,"key":\#(keyJSON()),"secret":"\#(rawSecret)"}"#)
        let createRequest = NativeAPIKeyCreateRequest(name: "QuickBooks sync", scopes: [.customers, .invoices], expiry: .oneYear)
        do {
            let created = try await service(createLoader).create(createRequest, operationId: opID, sessionBytes: session)
            expectEqual(bodyString(createLoader.requests.first),
                        #"{"action":"create","expiry":"1y","name":"QuickBooks sync","operationId":"\#(opID)","scopes":["customers:read","invoices:read"]}"#,
                        "create: exact body with operationId")
            expectEqual(created.key, summary(), "create: key summary")
            expectEqual(created.secret.revealedValue, rawSecret, "create: the secret, once")
            expect(created.previous == nil, "create: no previous key")
            expect(!"\(created)".contains(rawSecret), "create: the result never prints the key")
        } catch { expect(false, "create decodes (\(error))") }

        // rotate: exact body, previous key required.
        let rotateLoader = RecordingLoader()
        rotateLoader.enqueue(#"{"ok":true,"key":\#(keyJSON(id: newKeyID, prefix: "trk_Zz9yX8wV")),"secret":"\#(rotatedSecret)","previous":\#(keyJSON(expiresAt: "2026-10-04T17:00:00.000Z", replacedBy: newKeyID, status: "expiring"))}"#)
        do {
            let rotated = try await service(rotateLoader).rotate(keyId: keyID, grace: .twentyFourHours, operationId: opID, sessionBytes: session)
            expectEqual(bodyString(rotateLoader.requests.first),
                        #"{"action":"rotate","grace":"24h","keyId":"\#(keyID)","operationId":"\#(opID)"}"#, "rotate: exact body")
            expectEqual(rotated.previous?.status, .expiring, "rotate: the old key is in its grace window")
            expectEqual(rotated.previous?.replacedBy, newKeyID, "rotate: the old key names its replacement")
        } catch { expect(false, "rotate decodes (\(error))") }
        let rotateNoPrevious = RecordingLoader()
        rotateNoPrevious.enqueue(#"{"ok":true,"key":\#(keyJSON(id: newKeyID, prefix: "trk_Zz9yX8wV")),"secret":"\#(rotatedSecret)"}"#)
        expectEqual(await caught { try await service(rotateNoPrevious).rotate(keyId: keyID, grace: .immediate, operationId: opID, sessionBytes: session) },
                    .unknownOutcome, "rotate: a 200 without the previous key is an unknown outcome (retry replays)")
        expect(bodyString(rotateNoPrevious.requests.first).contains(#""grace":"immediate""#), "rotate: immediate grace on the wire")

        // revoke / activity bodies.
        let revokeLoader = RecordingLoader()
        revokeLoader.enqueue(#"{"ok":true,"key":\#(keyJSON(revokedAt: "2026-10-03T17:00:00Z", status: "revoked"))}"#)
        let revokedKey = try? await service(revokeLoader).revoke(keyId: keyID, sessionBytes: session)
        expectEqual(bodyString(revokeLoader.requests.first), #"{"action":"revoke","keyId":"\#(keyID)"}"#, "revoke: exact body, no operationId")
        expectEqual(revokedKey?.status, .revoked, "revoke: returns the revoked key")
        let revokeWithSecret = RecordingLoader()
        revokeWithSecret.enqueue(#"{"ok":true,"key":\#(keyJSON()),"secret":"\#(rawSecret)"}"#)
        let revokeWithSecretError = await caught { try await service(revokeWithSecret).revoke(keyId: keyID, sessionBytes: session) }
        expect(revokeWithSecretError != nil, "revoke: a response carrying a secret is refused")
        let revokeOther = RecordingLoader()
        revokeOther.enqueue(#"{"ok":true,"key":\#(keyJSON(id: newKeyID))}"#)
        expectEqual(await caught { try await service(revokeOther).revoke(keyId: keyID, sessionBytes: session) }, .unknownOutcome,
                    "revoke: a different key in the answer is not a confirmation")

        let activityLoader = RecordingLoader()
        activityLoader.enqueue(#"{"ok":true,"events":[{"at":"2026-10-03T16:55:00.000Z","keyId":"\#(keyID)","event":"ok","route":"/v1/invoices","status":200,"ip":"203.0.113.9"},{"at":"2026-10-03T16:50:00.000Z","keyId":"\#(keyID)","event":"rate_limited","route":"/v1/jobs","status":429,"ip":null}]}"#)
        activityLoader.enqueue(#"{"ok":true,"events":[]}"#)
        let events = (try? await service(activityLoader).activity(keyId: nil, sessionBytes: session)) ?? []
        _ = try? await service(activityLoader).activity(keyId: keyID, sessionBytes: session)
        expectEqual(bodyString(activityLoader.requests.first), #"{"action":"activity"}"#, "activity: all keys body")
        expectEqual(bodyString(activityLoader.requests.last), #"{"action":"activity","keyId":"\#(keyID)"}"#, "activity: one key body")
        expectEqual(events.map(\.kind), [.ok, .rateLimited], "activity: event kinds")
        expectEqual(events.map(\.id), [0, 1], "activity: newest-first positions as ids")
        expectEqual(events.first?.route, "/v1/invoices", "activity: route template")
        expect(events.last?.ip == nil, "activity: missing ip stays nil")

        // Endpoint allowlist and session guards: nothing is sent.
        for bad in ["http://staging.example/api/api-keys/manage", "https://staging.example/api/api-keys/manage?x=1",
                    "https://staging.example/api/estimate/portal-manage", "https://user:pw@staging.example/api/api-keys/manage"] {
            let refused = RecordingLoader()
            expectEqual(await caught { try await service(refused, url: URL(string: bad)!).list(sessionBytes: session) },
                        .invalidConfiguration, "allowlist: \(bad) refused")
            expect(refused.requests.isEmpty, "allowlist: nothing sent to \(bad)")
        }
        expect(NativeAPIKeyAdministrationService.isAllowedEndpoint(URL(string: "http://localhost:8787/api/api-keys/manage")!),
               "allowlist: local Worker over http is allowed")
        let malformed = RecordingLoader()
        expectEqual(await caught { try await service(malformed).list(sessionBytes: Data("{}".utf8)) }, .malformedSession,
                    "session: unreadable session bytes")
        expect(malformed.requests.isEmpty, "session: nothing sent without a bearer")

        // Operation ids: v4 only; a bad id or unnormalized request never leaves.
        let guarded = RecordingLoader()
        expectEqual(await caught { try await service(guarded).create(createRequest, operationId: "21111111-2222-1333-8555-666666666666", sessionBytes: session) },
                    .invalidRequest, "operation id: a non-v4 UUID is refused")
        expectEqual(await caught { try await service(guarded).create(NativeAPIKeyCreateRequest(name: " padded ", scopes: [.jobs], expiry: .never), operationId: opID, sessionBytes: session) },
                    .invalidRequest, "create: an unnormalized name is refused before sending")
        expectEqual(await caught { try await service(guarded).create(NativeAPIKeyCreateRequest(name: "x", scopes: [.mileage, .jobs], expiry: .never), operationId: opID, sessionBytes: session) },
                    .invalidRequest, "create: non-canonical scope order is refused before sending")
        expectEqual(await caught { try await service(guarded).rotate(keyId: "not-a-uuid", grace: .immediate, operationId: opID, sessionBytes: session) },
                    .invalidRequest, "rotate: a non-UUID key id is refused")
        expect(guarded.requests.isEmpty, "guards: nothing sent for a refused request")
        let fresh = Set((0..<50).map { _ in NativeAPIKeyAdministrationService.newOperationID() })
        expect(fresh.count == 50 && fresh.allSatisfy(NativeAPIKeyAdministrationService.isValidOperationID),
               "operation id: fresh ids are unique lower-case UUID v4")

        // 401: one refresh, the same bytes (same operationId) once more.
        let refreshLoader = RecordingLoader()
        refreshLoader.enqueue(#"{"error":"unauthorized"}"#, status: 401)
        refreshLoader.enqueue(#"{"ok":true,"key":\#(keyJSON()),"secret":"\#(rawSecret)"}"#)
        let counter = RefreshCounter(freshSession)
        let afterRefresh = try? await service(refreshLoader, refresh: counter).create(createRequest, operationId: opID, sessionBytes: session)
        expect(afterRefresh != nil, "401: succeeds after one refresh")
        expectEqual(counter.calls, 1, "401: refreshed exactly once")
        expectEqual(refreshLoader.requests.count, 2, "401: retried exactly once")
        expectEqual(refreshLoader.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-owner-jwt", "401: retry carries the fresh bearer")
        expectEqual(refreshLoader.requests.first?.httpBody, refreshLoader.requests.last?.httpBody, "401: retry sends the same bytes (same operationId)")
        let twice = RecordingLoader()
        twice.enqueue(#"{"error":"unauthorized"}"#, status: 401)
        twice.enqueue(#"{"error":"unauthorized"}"#, status: 401)
        let twiceCounter = RefreshCounter(freshSession)
        expectEqual(await caught { try await service(twice, refresh: twiceCounter).list(sessionBytes: session) }, .rejectedSession,
                    "401 twice: session rejected")
        expectEqual(twiceCounter.calls, 1, "401 twice: never refreshes a second time")
        expectEqual(twice.requests.count, 2, "401 twice: two requests only")
        let stale = RecordingLoader()
        stale.enqueue(#"{"error":"unauthorized"}"#, status: 401)
        expectEqual(await caught { try await service(stale, refresh: RefreshCounter(session)).list(sessionBytes: session) }, .rejectedSession,
                    "401: a refresh returning the same session does not retry")
        expectEqual(stale.requests.count, 1, "401: no retry with the same bearer")
        let noHook = RecordingLoader()
        noHook.enqueue(#"{"error":"unauthorized"}"#, status: 401)
        expectEqual(await caught { try await service(noHook).list(sessionBytes: session) }, .rejectedSession, "401: no refresh hook")

        // Decoding fails closed.
        let badDate = RecordingLoader()
        badDate.enqueue(#"{"ok":true,"keys":[\#(keyJSON(expiresAt: "next year"))],"maxLiveKeys":5}"#)
        expectEqual(await caught { try await service(badDate).list(sessionBytes: session) }, .invalidResponse,
                    "decode: an unreadable expiresAt never reads as 'never expires'")
        let unknownStatus = RecordingLoader()
        unknownStatus.enqueue(#"{"ok":true,"keys":[\#(keyJSON(expiresAt: "2026-10-01T00:00:00Z", status: "paused"))],"maxLiveKeys":5}"#)
        expectEqual((try? await service(unknownStatus).list(sessionBytes: session))?.keys.first?.status, .expired,
                    "decode: an unknown status is derived with the Worker's rule")
        for (label, body) in [
            ("malformed secret", #"{"ok":true,"key":\#(keyJSON()),"secret":"trk_short"}"#),
            ("secret not matching the prefix", #"{"ok":true,"key":\#(keyJSON(prefix: "trk_Other000")),"secret":"\#(rawSecret)"}"#),
            ("missing secret", #"{"ok":true,"key":\#(keyJSON())}"#),
            ("garbage", "<html>oops</html>"),
        ] {
            let odd = RecordingLoader()
            odd.enqueue(body)
            expectEqual(await caught { try await service(odd).create(createRequest, operationId: opID, sessionBytes: session) }, .unknownOutcome,
                        "create 200 with \(label): unknown outcome, so Retry replays the operation")
        }
        let garbageList = RecordingLoader()
        garbageList.enqueue("<html>oops</html>")
        expectEqual(await caught { try await service(garbageList).list(sessionBytes: session) }, .invalidResponse, "list 200 garbage: invalid response")
        let listWithSecret = RecordingLoader()
        listWithSecret.enqueue(#"{"ok":true,"keys":[],"maxLiveKeys":5,"secret":"\#(rawSecret)"}"#)
        expectEqual(await caught { try await service(listWithSecret).list(sessionBytes: session) }, .invalidResponse,
                    "list: a response carrying a secret is refused")
    }

    // MARK: 3. Every §14.1 error code

    static func errorTable() async {
        let createRequest = NativeAPIKeyCreateRequest(name: "QuickBooks sync", scopes: [.customers], expiry: .oneYear)
        func create(_ body: String, _ status: Int, headers: [String: String] = [:]) async -> NativeAPIKeyAdminError? {
            let loader = RecordingLoader()
            loader.enqueue(body, status: status, headers: headers)
            return await caught { try await service(loader).create(createRequest, operationId: opID, sessionBytes: session) }
        }
        func list(_ body: String, _ status: Int, headers: [String: String] = [:]) async -> NativeAPIKeyAdminError? {
            let loader = RecordingLoader()
            loader.enqueue(body, status: status, headers: headers)
            return await caught { try await service(loader).list(sessionBytes: session) }
        }
        expectEqual(await create(#"{"error":"invalid_request"}"#, 400), .invalidRequest, "400 invalid_request")
        expectEqual(await create(#"{"error":"unauthorized"}"#, 401), .rejectedSession, "401 unauthorized (no refresh hook)")
        expectEqual(await create(#"{"error":"not_found"}"#, 404), .notFound, "404 not_found")
        expectEqual(await create(#"{"error":"method_not_allowed"}"#, 405), .methodNotAllowed, "405 method_not_allowed")
        expectEqual(await create(#"{"error":"key_limit","maxLiveKeys":5}"#, 409), .keyLimit(maxLiveKeys: 5), "409 key_limit")
        expectEqual(await create(#"{"error":"already_completed","key":{"id":"\#(keyID)","prefix":"trk_Ab3dE9fQ"}}"#, 409),
                    .alreadyCompleted(keyId: keyID, prefix: "trk_Ab3dE9fQ"), "409 already_completed carries id and prefix, no secret")
        expectEqual(await create(#"{"error":"already_completed","key":{"id":"x","prefix":"<b>"}}"#, 409),
                    .alreadyCompleted(keyId: "", prefix: ""), "409 already_completed with junk id/prefix keeps neither")
        expectEqual(await create(#"{"error":"operation_conflict"}"#, 409), .operationConflict, "409 operation_conflict")
        expectEqual(await create(#"{"error":"something_new"}"#, 409), .unknownOutcome, "409 unknown code after a mutation: unknown outcome")
        expectEqual(await list(#"{"error":"something_new"}"#, 409), .invalidResponse, "409 unknown code on a read")
        expectEqual(await create(#"{"error":"rate_limited"}"#, 429, headers: ["Retry-After": "17"]), .rateLimited(retryAfter: 17), "429 honours Retry-After")
        expectEqual(await list(#"{"error":"rate_limited"}"#, 429), .rateLimited(retryAfter: 60), "429 without Retry-After waits the window")
        expectEqual(await create(#"{"error":"unavailable"}"#, 503), .unavailable, "503 unavailable (migration not applied)")
        expectEqual(await list(#"{"error":"unavailable"}"#, 503), .unavailable, "503 unavailable on a read")
        expectEqual(await create(#"{"error":"server_error"}"#, 500), .unknownOutcome, "500 after create: unknown outcome")
        expectEqual(await list(#"{"error":"server_error"}"#, 500), .serverError, "500 on a read: server error")
        expectEqual(await create("Bad gateway", 502), .unknownOutcome, "502 after create: unknown outcome")
        expectEqual(await list("Bad gateway", 502), .serverError, "502 on a read")
        expectEqual(await create("", 302), .unknownOutcome, "an unexpected status after create: unknown outcome")

        let lost = RecordingLoader()
        lost.enqueueFailure(URLError(.timedOut))
        expectEqual(await caught { try await service(lost).create(createRequest, operationId: opID, sessionBytes: session) }, .unknownOutcome,
                    "timeout after create: unknown outcome")
        let notSent = RecordingLoader()
        notSent.enqueueFailure(URLError(.notConnectedToInternet))
        expectEqual(await caught { try await service(notSent).create(createRequest, operationId: opID, sessionBytes: session) }, .offline,
                    "no connection: offline, nothing was sent")
        let readLost = RecordingLoader()
        readLost.enqueueFailure(URLError(.timedOut))
        expectEqual(await caught { try await service(readLost).list(sessionBytes: session) }, .offline, "timeout on a read: offline")
        let revokeLost = RecordingLoader()
        revokeLost.enqueueFailure(URLError(.networkConnectionLost))
        expectEqual(await caught { try await service(revokeLost).revoke(keyId: keyID, sessionBytes: session) }, .unknownOutcome,
                    "connection lost after revoke: unknown outcome")

        // Every error has clear text that never carries a key.
        let all: [NativeAPIKeyAdminError] = [
            .invalidConfiguration, .signedOut, .malformedSession, .rejectedSession, .methodNotAllowed, .invalidRequest,
            .notFound, .keyLimit(maxLiveKeys: 5), .alreadyCompleted(keyId: keyID, prefix: "trk_Ab3dE9fQ"), .operationConflict,
            .rateLimited(retryAfter: 30), .unavailable, .serverError, .offline, .unknownOutcome, .invalidResponse, .ownerChanged,
        ]
        for error in all {
            let text = error.errorDescription ?? ""
            expect(text.count > 20 && text.hasSuffix("."), "error text: \(error) reads as a sentence")
            expect(!text.contains("trk_") || text.contains("trk_Ab3dE9fQ…"), "error text: \(error) shows at most the display prefix")
        }
        expect(NativeAPIKeyAdminError.keyLimit(maxLiveKeys: 5).errorDescription?.contains("5 active keys") == true, "error text: the cap")
        expect(NativeAPIKeyAdminError.rateLimited(retryAfter: 30).errorDescription?.contains("30 seconds") == true, "error text: the wait")
        // Which failures keep the operation id for an exact retry.
        let keeps = all.filter(\.keepsPendingOperation)
        expectEqual(Set(keeps.map { "\($0)" }), Set([NativeAPIKeyAdminError.signedOut, .malformedSession, .rejectedSession,
                                                    .rateLimited(retryAfter: 30), .unavailable, .serverError, .offline,
                                                    .unknownOutcome, .invalidResponse, .ownerChanged].map { "\($0)" }),
                    "pending: only outcomes that may have committed (or never reached the RPC) keep the operation id")
    }

    // MARK: 4. View model

    @MainActor
    static func model() async {
        // Load.
        let h = Harness()
        expectEqual(h.model.phase, .idle, "model: idle before load")
        await h.loaded()
        expectEqual(h.model.phase, .loaded, "model: loaded")
        expectEqual(h.model.keys, [summary()], "model: keys from the server")
        expectEqual(h.model.activeCount, 1, "model: active count")
        expect(h.model.canCreate, "model: can create under the cap")

        // Create: one call, the reveal holds the key, analytics carry the count only.
        h.model.presentCreate()
        expectEqual(h.model.sheet, .create, "create: the form opens")
        h.manager.createResults = [.success(issued())]
        await h.model.create(request)
        expectEqual(h.manager.createCalls.count, 1, "create: one request")
        expectEqual(h.manager.createCalls.first?.operationId, h.operationIDs.first, "create: sends a fresh operation id")
        expect(h.model.pending == nil, "create: success clears the pending operation")
        guard case let .reveal(reveal)? = h.model.sheet else { return expect(false, "create: the show-once sheet replaces the form") }
        expectEqual(reveal.secret.revealedValue, rawSecret, "create: the sheet shows the key")
        expectEqual(h.model.keys.first?.id, newKeyID, "create: the new key heads the list")
        expectEqual(h.tracked, [.keyCreated(scopeCount: 5)], "create: api_key_created with the scope count only")
        expect(!reachableSecrets(h.model, raw: rawSecret).isEmpty, "scanner positive control: the model holds the key while the sheet is up")
        h.model.dismissSheet()
        expect(h.model.sheet == nil, "dismiss: the sheet closes")
        expectEqual(reachableSecrets(h.model, raw: rawSecret), [], "dismiss: no reference to the key remains anywhere in the model")
        expect(h.model.alert == nil && h.model.notice?.contains(rawSecret) != true, "dismiss: no alert or notice carries the key")

        // No double submit: a second create while the first is open never sends.
        let d = Harness()
        await d.loaded([])
        d.manager.holdCreate = true
        d.manager.createResults = [.success(issued())]
        let first = Task { await d.model.create(request) }
        while d.manager.createCalls.isEmpty { await Task.yield() }
        expectEqual(d.model.busy, .creating, "double submit: busy while the request is open")
        await d.model.create(request)
        await d.model.retryPending()
        d.model.presentCreate()
        expectEqual(d.manager.createCalls.count, 1, "double submit: the second tap sends nothing")
        d.manager.release()
        await first.value
        expect(d.model.busy == nil, "double submit: idle again afterwards")

        // Unknown outcome: the request freezes; Retry replays the same id and bytes.
        let u = Harness()
        await u.loaded([])
        u.model.presentCreate()
        u.manager.createResults = [.failure(NativeAPIKeyAdminError.unknownOutcome), .success(issued())]
        await u.model.create(request)
        expect(u.model.pending != nil, "unknown outcome: the operation is kept")
        expect(u.model.sheet == nil, "unknown outcome: the form closes; Retry waits on the list")
        expectEqual(u.model.alert?.title, "Not confirmed", "unknown outcome: says so")
        expect(!u.model.canCreate, "unknown outcome: no new create until it's resolved")
        u.model.presentCreate()
        expect(u.model.sheet == nil, "unknown outcome: the create form stays closed")
        await u.model.retryPending()
        expectEqual(u.manager.createCalls.count, 2, "retry: one more request")
        expectEqual(u.manager.createCalls.map(\.operationId), [u.operationIDs[0], u.operationIDs[0]], "retry: the SAME operation id")
        expect(u.manager.createCalls[0].request == u.manager.createCalls[1].request, "retry: the SAME request")
        expect(u.model.pending == nil, "retry: success resolves it")
        if case .reveal? = u.model.sheet {} else { expect(false, "retry: a first commit shows the key") }

        // Retry → already_completed: no secret, offer revoke, reload.
        let a = Harness()
        await a.loaded([])
        a.manager.createResults = [.failure(NativeAPIKeyAdminError.offline),
                                   .failure(NativeAPIKeyAdminError.alreadyCompleted(keyId: newKeyID, prefix: "trk_Ab3dE9fQ"))]
        a.manager.listResults = [.success(NativeAPIKeyList(keys: [summary(id: newKeyID)], maxLiveKeys: 5))]
        await a.model.create(request)
        await a.model.retryPending()
        expect(a.model.pending == nil, "already_completed: resolved, nothing to retry")
        expectEqual(a.model.alert?.revokeKeyId, newKeyID, "already_completed: offers to revoke the key whose secret is lost")
        expect(a.model.alert?.message.contains("can't show it again") == true, "already_completed: explains")
        expect(a.model.sheet == nil, "already_completed: no reveal without a secret")
        expectEqual(a.manager.calls.filter { $0 == "list" }.count, 2, "already_completed: the list reloads to show the key")
        expectEqual(a.tracked, [], "already_completed: no created event (it was never shown)")

        // Dismissing an unresolved request reloads the list.
        let x = Harness()
        await x.loaded([])
        x.manager.createResults = [.failure(NativeAPIKeyAdminError.unknownOutcome)]
        await x.model.create(request)
        x.manager.listResults = [.success(NativeAPIKeyList(keys: [summary(id: newKeyID)], maxLiveKeys: 5))]
        await x.model.dismissPending()
        expect(x.model.pending == nil && x.model.keys.first?.id == newKeyID, "dismiss pending: forgets it and shows what exists")

        // Definitive refusal: the form stays open with an alert; a new attempt gets a new id.
        let k = Harness()
        await k.loaded([])
        k.model.presentCreate()
        k.manager.createResults = [.failure(NativeAPIKeyAdminError.keyLimit(maxLiveKeys: 5)), .success(issued())]
        await k.model.create(request)
        expect(k.model.pending == nil, "key_limit: definitive, nothing pending")
        expectEqual(k.model.sheet, .create, "key_limit: the form stays open")
        expectEqual(k.model.alert?.title, "Couldn't create key", "key_limit: alert")
        expect(k.model.alert?.message.contains("5 active keys") == true, "key_limit: says why")
        await k.model.create(request)
        expectEqual(k.manager.createCalls.map(\.operationId), [k.operationIDs[0], k.operationIDs[1]], "after a refusal a new attempt is a new operation")

        // The cap blocks create locally.
        let c = Harness()
        await c.loaded((0..<5).map { summary(id: "00000000-0000-4000-8000-00000000000\($0)") })
        expect(c.model.isAtKeyLimit && !c.model.canCreate, "cap: five active keys block create")
        await c.model.create(request)
        expect(c.manager.createCalls.isEmpty, "cap: nothing sent")
        let withGrace = Harness()
        await withGrace.loaded((0..<4).map { summary(id: "00000000-0000-4000-8000-00000000000\($0)") }
                               + [summary(id: newKeyID, expiresAt: now.addingTimeInterval(3600), replacedBy: keyID, status: .expiring)])
        expect(withGrace.model.canCreate, "cap: a key in a rotation grace window doesn't count")

        // 429: the Retry-After wait; nothing is sent until it passes.
        let r = Harness()
        await r.loaded()
        r.manager.revokeResults = [.failure(NativeAPIKeyAdminError.rateLimited(retryAfter: 30))]
        await r.model.revoke(keyId: keyID)
        expectEqual(r.model.rateLimitedUntil, now.addingTimeInterval(30), "429: waits Retry-After")
        expect(r.model.isRateLimited() && !r.model.canStartKeyChange, "429: key changes wait")
        expect(r.model.rateLimitText?.contains("30 seconds") == true, "429: the wait in words")
        let sent = r.manager.calls.count
        await r.model.load()
        await r.model.revoke(keyId: keyID)
        await r.model.loadActivity()
        expectEqual(r.manager.calls.count, sent, "429: nothing is sent during the wait")
        r.clock.now = now.addingTimeInterval(29)
        r.model.clearRateLimitIfDue()
        expect(r.model.isRateLimited(), "429: still waiting at 29 s")
        r.clock.now = now.addingTimeInterval(30)
        r.model.clearRateLimitIfDue()
        expect(!r.model.isRateLimited() && r.model.rateLimitedUntil == nil, "429: the wait ends at 30 s")
        r.manager.listResults = [.success(NativeAPIKeyList(keys: [summary()], maxLiveKeys: 5))]
        await r.model.load()
        expectEqual(r.manager.calls.last, "list", "429: requests resume after the wait")
        let slept = SleepRecorder()
        let timed = NativeAPIAccessModel(manager: r.manager, now: { now }, sleep: { await slept.record($0) })
        r.manager.listResults = [.failure(NativeAPIKeyAdminError.rateLimited(retryAfter: 45))]
        await timed.load()
        for _ in 0..<20 { await Task.yield() }
        expectEqual(await slept.values, [45], "429: the timer waits exactly Retry-After before re-enabling")

        // A 429 during create keeps the frozen request for an exact retry.
        let rc = Harness()
        await rc.loaded([])
        rc.manager.createResults = [.failure(NativeAPIKeyAdminError.unknownOutcome), .failure(NativeAPIKeyAdminError.rateLimited(retryAfter: 10))]
        await rc.model.create(request)
        await rc.model.retryPending()
        expect(rc.model.pending != nil, "429 on retry: the first attempt may have committed, so the id is kept")

        // Revoke: confirmation lives in the view; the model sends once, counts once.
        let v = Harness()
        await v.loaded()
        v.manager.revokeResults = [.success(summary(revokedAt: now, status: .revoked)), .success(summary(revokedAt: now, status: .revoked))]
        await v.model.revoke(keyId: keyID)
        expectEqual(v.model.keys.first?.status, .revoked, "revoke: the list shows it revoked")
        expectEqual(v.tracked, [.keyRevoked(scopeCount: 2)], "revoke: api_key_revoked with the scope count only")
        expect(v.model.notice?.contains("revoked") == true, "revoke: says what happened")
        await v.model.revoke(keyId: keyID)
        expectEqual(v.tracked.count, 1, "revoke: revoking a revoked key again is not counted twice")
        let vu = Harness()
        await vu.loaded()
        vu.manager.revokeResults = [.failure(NativeAPIKeyAdminError.unknownOutcome)]
        await vu.model.revoke(keyId: keyID)
        expect(vu.model.alert?.message.contains("revoking twice is safe") == true, "revoke unknown outcome: retry is safe")
        await vu.model.revoke(keyId: "not-a-uuid")
        expectEqual(vu.manager.calls.filter { $0.hasPrefix("revoke") }.count, 1, "revoke: a malformed id is never sent")

        // Rotate: reveal with the previous key's end; a new id per rotation; no created event.
        let o = Harness()
        await o.loaded()
        let previous = summary(expiresAt: now.addingTimeInterval(86_400), replacedBy: newKeyID, status: .expiring)
        o.manager.rotateResults = [.success(issued(rotatedSecret, key: summary(id: newKeyID, prefix: "trk_Zz9yX8wV"), previous: previous))]
        await o.model.rotate(summary(), grace: .twentyFourHours)
        expectEqual(o.manager.rotateCalls.first?.grace, .twentyFourHours, "rotate: grace choice sent")
        expectEqual(o.manager.rotateCalls.first?.operationId, o.operationIDs.first, "rotate: a fresh operation id")
        guard case let .reveal(rotation)? = o.model.sheet else { return expect(false, "rotate: shows the new key once") }
        expectEqual(rotation.previous, previous, "rotate: the sheet knows when the old key stops")
        expectEqual(o.model.keys.first(where: { $0.id == keyID })?.status, .expiring, "rotate: the old key shows its grace window")
        expectEqual(o.tracked, [], "rotate: no analytics event (§9 names create and revoke only)")
        o.model.dismissSheet()
        expectEqual(reachableSecrets(o.model, raw: rotatedSecret), [], "rotate dismiss: no reference to the key remains")
        await o.model.rotate(previous, grace: .immediate)
        expectEqual(o.manager.rotateCalls.count, 1, "rotate: a key already being replaced can't rotate again")

        // Signed out / owner changed: nothing stays on screen.
        let s = Harness()
        s.manager.listResults = [.failure(NativeAPIKeyAdminError.signedOut)]
        await s.model.load()
        expectEqual(s.model.phase, .failed(.signedOut), "signed out: the sign-in state")
        let w = Harness()
        await w.loaded()
        w.manager.createResults = [.failure(NativeAPIKeyAdminError.ownerChanged)]
        await w.model.create(request)
        expect(w.model.keys.isEmpty && w.model.phase == .failed(.ownerChanged), "owner changed: the old account's keys are cleared")
        expect(w.model.sheet == nil, "owner changed: no reveal")
        let f = Harness()
        await f.loaded()
        f.manager.listResults = [.failure(NativeAPIKeyAdminError.offline)]
        await f.model.load()
        expectEqual(f.model.phase, .loaded, "refresh failure: keeps the loaded list")
        expectEqual(f.model.alert?.title, "Couldn't refresh keys", "refresh failure: text alert")
        let g = Harness()
        g.manager.listResults = [.failure(NativeAPIKeyAdminError.unavailable)]
        await g.model.load()
        expectEqual(g.model.phase, .failed(.unavailable), "first load failure: the cloud-required state")

        // Activity.
        let ac = Harness()
        await ac.loaded()
        let logged = NativeAPIActivityEvent(id: 0, at: now, keyId: keyID, kind: .ok, route: "/v1/invoices", status: 200, ip: nil)
        ac.manager.activityResults = [.success([logged]), .failure(NativeAPIKeyAdminError.serverError)]
        await ac.model.loadActivity()
        expectEqual(ac.model.activity, [logged], "activity: events")
        expectEqual(ac.model.keyName(for: keyID.uppercased()), "QuickBooks sync", "activity: rows name their key")
        await ac.model.loadActivity()
        expect(ac.model.activity.isEmpty && ac.model.activityPhase == .failed(.serverError), "activity: failure shows text")
    }

    // MARK: 5. Source guards

    static func sources(root: URL) {
        func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let files = [
            "native/TradeReadyNative/Domain/NativeAPIAccess.swift",
            "native/TradeReadyNative/NativeAPIKeyAdministration.swift",
            "native/TradeReadyNative/NativeAPIAccessModel.swift",
            "native/TradeReadyNative/NativeAPIAccessStore.swift",
            "native/TradeReadyNative/NativeAPIAccessView.swift",
        ]
        let banned = ["print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump(", "UserDefaults", "@AppStorage",
                      "@SceneStorage", "FileManager", "write(to", "Keychain", "NSUbiquitousKeyValueStore", "SentrySDK",
                      "addBreadcrumb", "Codable", "Encodable(", "URLCache.shared", "URLSession.shared"]
        for path in files {
            guard let text = read(path) else { expect(false, "\(path) readable"); continue }
            let code = SourceFile(relativePath: path, text: text).codeText
            for token in banned {
                expect(!code.contains(token), "\(path): no \(token) (the key is never logged or persisted)")
            }
        }
        if let domain = read("native/TradeReadyNative/Domain/NativeAPIAccess.swift") {
            let declaration = domain.components(separatedBy: "\n").first { $0.contains("struct NativeAPIKeySecret") } ?? ""
            expect(!declaration.isEmpty && !declaration.contains("Codable") && !declaration.contains("Encodable")
                   && !declaration.contains("Hashable"), "secret: the type is neither Codable nor Hashable")
            expect(domain.contains("static let apiAccessEnabled = true"), "flag: the source default is on")
        }
        if let settings = read("native/TradeReadyNative/SettingsView.swift") {
            let code = SourceFile(relativePath: "SettingsView.swift", text: settings).codeText
            expectEqual(code.components(separatedBy: ".apiAccess").count - 1, 2,
                        "Settings: .apiAccess appears only in its row helper call and its destination")
            expect(code.contains("] + SettingsDestination.apiAccessRows)"), "Settings: the APP group's row comes from the gated helper")
            expect(code.contains("case .apiAccess: NativeAPIAccessView()"), "Settings: the destination")
        } else { expect(false, "SettingsView.swift readable") }
        if let view = read("native/TradeReadyNative/NativeAPIAccessView.swift") {
            expect(view.contains("NativeAPIAccessFeature.showsSettingsEntry()\n            ? [(.apiAccess,"),
                   "view: the row exists only when the flag is on")
            expect(view.contains("            : []"), "view: flag off gives no row")
            expect(view.contains(".localOnly: NativeAPIKeyClipboardPolicy.localOnly")
                   && view.contains(".expirationDate: NativeAPIKeyClipboardPolicy.expiration(from: Date())"),
                   "view: copy is local-only with a two-minute expiry")
            expect(view.contains(".interactiveDismissDisabled()\n"), "view: the show-once sheet closes only through its button")
            expect(view.contains("NativeAPIKeyRevealSheet(reveal: reveal) { model.dismissSheet() }"), "view: \"I've saved it\" clears the key")
            expect(view.contains("Text(NativeAPIAccessText.showOnceWarning)") || view.contains("Label(NativeAPIAccessText.showOnceWarning"),
                   "view: the show-once warning is shown")
            expect(view.contains("if scenePhase == .active"), "view: the key is hidden from the app-switcher snapshot")
            // System text selection would offer Copy, which writes the key to the general pasteboard with
            // no local-only flag and no expiry. The Copy button is the only path (spec §9).
            let viewCode = SourceFile(relativePath: "NativeAPIAccessView.swift", text: view).codeText
            expect(!viewCode.contains("textSelection"), "view: no .textSelection anywhere (the secret cannot be copied around the clipboard policy)")
            expect(!viewCode.contains("UIPasteboard.general.string") && !viewCode.contains("UIPasteboard.general.strings"),
                   "view: nothing writes the key to the pasteboard without the policy options")
        } else { expect(false, "NativeAPIAccessView.swift readable") }
    }
}

private actor SleepRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}
