import Foundation

// Task 11.09 host tests: crash reporting and redaction (contract §10.1–§10.3,
// C12, C18). The Sentry SDK is never compiled or linked here: the reporter
// runs over a recording fake `NativeCrashReportingSDKAdapter`, and every
// redaction rule is tested on the Foundation payloads the Sentry adapter maps
// SDK events onto. The real AppStore drives the identity and sync call sites.
// Run with TZ=America/Phoenix (the runner defaults it).

// MARK: - Fakes

enum CrashCall: Equatable, CustomStringConvertible {
    case start(NativeCrashReportingOptions)
    case capture(title: String?, domain: String, extras: String, fingerprint: [String])
    case setUser(String?)

    var description: String {
        switch self {
        case .start(let options): return "start(\(options.dsn))"
        case .capture(let title, let domain, let extras, let fingerprint):
            return "capture(\(title ?? "<error>"), \(domain), \(extras), \(fingerprint))"
        case .setUser(let id): return "setUser(\(id ?? "nil"))"
        }
    }
}

func canonicalJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8)
    else { return "<invalid json>" }
    return text
}

final class FakeCrashAdapter: NativeCrashReportingSDKAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CrashCall] = []
    private(set) var reports: [NativeCrashReport] = []
    var startError: Error?

    var calls: [CrashCall] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded.removeAll(); reports.removeAll(); lock.unlock() }

    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {
        lock.lock(); recorded.append(.start(options)); lock.unlock()
        if let startError { throw startError }
    }

    func capture(_ report: NativeCrashReport) throws {
        let ns = report.error as NSError
        lock.lock()
        recorded.append(.capture(title: report.title, domain: ns.domain, extras: canonicalJSON(report.extras), fingerprint: report.fingerprint))
        reports.append(report)
        lock.unlock()
    }

    func setUser(id: String?) throws {
        lock.lock(); recorded.append(.setUser(id)); lock.unlock()
    }
}

struct FakeCrashError: Error {}

final class ThrowingCrashAdapter: NativeCrashReportingSDKAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {}
    func capture(_ report: NativeCrashReport) throws { lock.lock(); count += 1; lock.unlock(); throw FakeCrashError() }
    func setUser(id: String?) throws { lock.lock(); count += 1; lock.unlock(); throw FakeCrashError() }
}

/// Blocks every adapter call until released: a slow SDK. The wait is
/// bounded, so a regression that calls the SDK on the caller's thread fails
/// the timing and timeout checks instead of hanging the runner.
final class BlockingCrashAdapter: NativeCrashReportingSDKAdapter, @unchecked Sendable {
    static let maximumWait: TimeInterval = 3
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var timeouts = 0
    var completed: Int { lock.lock(); defer { lock.unlock() }; return count }
    var timedOut: Int { lock.lock(); defer { lock.unlock() }; return timeouts }
    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {}
    func capture(_ report: NativeCrashReport) throws { block() }
    func setUser(id: String?) throws { block() }
    private func block() {
        let released = gate.wait(timeout: .now() + Self.maximumWait) == .success
        lock.lock()
        if released { count += 1 } else { timeouts += 1 }
        lock.unlock()
    }
}

final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
}

struct NoopReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

@MainActor
final class SubscriptionStub: NativeSubscriptionServing {
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    func logOut() async {}
}

// MARK: - Harness

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func hexBinding(_ tag: String) -> String {
    var s = String(tag.lowercased().map { ("0"..."9").contains($0) || ("a"..."f").contains($0) ? $0 : "0" })
    while s.count < 64 { s += "0" }
    return String(s.prefix(64))
}

func reporter(
    _ adapter: NativeCrashReportingSDKAdapter,
    _ diagnostics: DiagnosticRecorder = DiagnosticRecorder()
) -> NativeCrashReporter {
    NativeCrashReporter(adapter: adapter, diagnostics: { diagnostics.record($0) })
}

@MainActor
func makeStore(_ crashReporting: NativeCrashReporting, tag: String, directory existing: URL? = nil) -> (AppStore, URL) {
    let directory = existing ?? FileManager.default.temporaryDirectory
        .appending(path: "tradeready-error-redaction-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = AppStore(
        fileURL: directory.appending(path: "store.json"),
        seedIfMissing: false,
        subscriptionService: SubscriptionStub(),
        analytics: NativeNoOpAnalytics(),
        crashReporting: crashReporting,
        widgetTimelineReloader: NoopReloader()
    )
    store.coachAdvisoryAnthropicKeyOverride = ""
    store.coachAdvisoryGroqKeyOverride = ""
    return (store, directory)
}

let redaction = NativeErrorRedaction.standard

/// Every secret below must be absent from every redacted payload.
let poison: [(label: String, text: String, leak: String)] = [
    ("stripe secret", "key sk_live_51Habc123DEF456", "sk_live_51Habc123DEF456"),
    ("openai key", "sk-proj-abcdef1234567890", "sk-proj-abcdef1234567890"),
    ("github token", "ghp_abcdefghijklmnop123456", "ghp_abcdefghijklmnop123456"),
    // 11.13 fix round 1 (I1): Square access tokens and application secrets,
    // the values RN `scrubLegacySquareToken` purges from settings.
    ("square access token", "square said EAAAEOuLQObrVwJvCvoio3qx9Bi7MEZ2Ymv2nUx8m2cVYzAh8Kx5yGQZ", "EAAAEOuLQObrVwJvCvoio3qx9Bi7MEZ2Ymv2nUx8m2cVYzAh8Kx5yGQZ"),
    ("square legacy token", "token sq0atp-3_Wb0zJnNx7lzM1nb2eP0g rejected", "sq0atp-3_Wb0zJnNx7lzM1nb2eP0g"),
    ("square sandbox token", "token sq0atb-Hx7lzM1nb2eP0g_3Wb0zJ rejected", "sq0atb-Hx7lzM1nb2eP0g_3Wb0zJ"),
    ("square app secret", "secret sq0csp-Q2lnbmF0dXJlX2V4YW1wbGU rejected", "sq0csp-Q2lnbmF0dXJlX2V4YW1wbGU"),
    ("jwt", "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl", "eyJhbGciOiJIUzI1NiJ9"),
    ("bearer", "Authorization: Bearer abc.def-ghi_123", "abc.def-ghi_123"),
    ("bearer lowercase", "sent bearer QWERTY987654", "QWERTY987654"),
    ("access_token pair", "refresh failed access_token=zzTopSecret99&x=1", "zzTopSecret99"),
    ("email", "customer pat.owner+jobs@example.com replied", "pat.owner+jobs@example.com"),
    ("phone dashes", "call 480-555-0100 today", "480-555-0100"),
    ("phone intl", "call +1 (480) 555-0199 today", "555-0199"),
    ("phone bare", "sms to 4805550123 failed", "4805550123"),
    ("portal url", "GET https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb/pay?t=abc#frag", "Zx9Kq2Lm7Np4Rt6Vw8Yb"),
    ("url query", "GET https://api.gettradereadyapp.com/v1/jobs?customer=Pat%20Owner&code=998877", "Pat%20Owner"),
    ("url fragment", "open https://tradeready.app/estimate/view#access_token=frag123secret", "frag123secret"),
    ("booking marker", "open https://tradeready.app/book/pats-plumbing-slug", "pats-plumbing-slug"),
    ("payment link", "pay at https://buy.stripe.com/28o5kq3Xy9aB", "28o5kq3Xy9aB"),
    ("url userinfo", "sync https://admin:hunter2pass@db.example.com/rest", "hunter2pass"),
    ("data uri", "photo data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ==", "/9j/4AAQSkZJRgABAQ"),
    ("base64 blob", "pdf " + String(repeating: "JVBERi0xLjQK", count: 12), "JVBERi0xLjQKJVBERi0x"),
]

// MARK: - Tests

@main
struct ErrorRedactionTests {
    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")
        gateAndOptions()
        stringRedaction()
        preservedValues()
        idempotenceAndCustomSchemes()
        keyDenyClasses()
        eventRedaction()
        breadcrumbAndSpanRedaction()
        extrasAllowList()
        stringCap()
        wrapperTitles()
        reporterBehaviour()
        identityBoundaries()
        await accountSwitchAndDeletion()
        throwingAndSlowAdapterDoNotAffectCommits()
        syncCallSites()
        sourceChecks(root: root)

        print("error-redaction tests: \(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }

    // MARK: 1. Gate and exact options (§10.2)

    static func gateAndOptions() {
        let dsn = "https://0123456789abcdef@o123456.ingest.us.sentry.io/4500000000000001"
        let release = "com.gettradereadyapp.tradeready@1.4.0+42"

        func resolve(_ debug: Bool, _ value: String?) -> NativeCrashReportingGate.Resolution {
            NativeCrashReportingGate.resolve(isDebugBuild: debug, dsn: value, environment: "production", releaseName: release)
        }
        expectEqual(resolve(true, dsn), .disabled(.debugBuild), "gate: a Debug build never reports, even with a DSN")
        expectEqual(resolve(false, nil), .disabled(.missingDSN), "gate: no DSN")
        expectEqual(resolve(false, ""), .disabled(.missingDSN), "gate: an empty DSN")
        expectEqual(resolve(false, "  \n"), .disabled(.missingDSN), "gate: a blank DSN")
        expectEqual(resolve(false, "$(TRADEREADY_SENTRY_DSN)"), .disabled(.missingDSN), "gate: an unexpanded build setting")
        expectEqual(resolve(false, "PLACEHOLDER"), .disabled(.placeholderDSN), "gate: PLACEHOLDER")
        expectEqual(resolve(false, "PLACEHOLDER_SENTRY_DSN"), .disabled(.placeholderDSN), "gate: a PLACEHOLDER-prefixed DSN")
        expectEqual(resolve(false, "http://key@o1.ingest.sentry.io/1"), .disabled(.invalidDSN), "gate: plain http is rejected")
        expectEqual(resolve(false, "https://o1.ingest.sentry.io/1"), .disabled(.invalidDSN), "gate: a DSN without a public key")
        expectEqual(resolve(false, "https://key@o1.ingest.sentry.io/"), .disabled(.invalidDSN), "gate: a DSN without a project")
        expectEqual(resolve(false, "https://key@o1.ingest.sentry.io/1?x=1"), .disabled(.invalidDSN), "gate: a DSN with a query")
        expectEqual(resolve(false, "not a url"), .disabled(.invalidDSN), "gate: garbage")

        guard case .enabled(let options) = resolve(false, "  \(dsn) ") else {
            expect(false, "gate: a Release build with a real DSN is enabled")
            return
        }
        expectEqual(options.dsn, dsn, "options: the trimmed DSN")
        expectEqual(options.environment, "production", "options: environment")
        expectEqual(options.releaseName, release, "options: releaseName")

        // Zero reports from every disabled gate: the adapter is never built.
        for reason in [NativeCrashReportingGate.DisabledReason.debugBuild, .missingDSN, .placeholderDSN, .invalidDSN] {
            var built = 0
            let diagnostics = DiagnosticRecorder()
            let crash = NativeCrashReportingGate.makeReporter(
                resolution: .disabled(reason),
                makeAdapter: { built += 1; return FakeCrashAdapter() },
                diagnostics: { diagnostics.record($0) }
            )
            crash.reportError(["message": "boom"], context: ["context": "gate"])
            crash.setUser(id: "user-a")
            crash.waitUntilIdle()
            expectEqual(built, 0, "gate \(reason.rawValue): no adapter is built")
            expect(!crash.isReporting, "gate \(reason.rawValue): the reporter sends nothing")
            expectEqual(diagnostics.all, [reason.rawValue], "gate \(reason.rawValue): one bounded diagnostic")
        }

        // Enabled: the fake adapter receives exactly the §10.2 options.
        let fake = FakeCrashAdapter()
        let crash = NativeCrashReportingGate.makeReporter(resolution: .enabled(options), makeAdapter: { fake })
        expect(crash.isReporting, "enabled: the reporter is live")
        guard case .start(let started)? = fake.calls.first else {
            expect(false, "enabled: start is the first adapter call")
            return
        }
        expectEqual(started.dsn, dsn, "options: dsn")
        expectEqual(started.environment, "production", "options: environment on the adapter")
        expectEqual(started.releaseName, release, "options: releaseName on the adapter")
        expectEqual(started.tracesSampleRate, 0.2, "options: tracesSampleRate 0.2 (RN parity)")
        expectEqual(started.enableAutoSessionTracking, true, "options: auto session tracking on (release health)")
        expectEqual(started.sendDefaultPii, false, "options: sendDefaultPii false")
        expectEqual(started.attachScreenshot, false, "options: no screenshot")
        expectEqual(started.attachViewHierarchy, false, "options: no view hierarchy")
        expectEqual(started.sessionReplaySessionSampleRate, 0, "options: replay session rate 0")
        expectEqual(started.sessionReplayOnErrorSampleRate, 0, "options: replay on-error rate 0")
        expectEqual(started.enableCaptureFailedRequests, false, "options: failed-request capture off")
        expectEqual(started.debug, false, "options: SDK debug logging off")

        // A start failure disables reporting and never crashes.
        let failing = FakeCrashAdapter()
        failing.startError = FakeCrashError()
        let diagnostics = DiagnosticRecorder()
        let failed = NativeCrashReportingGate.makeReporter(
            resolution: .enabled(options), makeAdapter: { failing }, diagnostics: { diagnostics.record($0) }
        )
        failed.reportError(["message": "boom"], context: ["context": "x"])
        failed.waitUntilIdle()
        expect(!failed.isReporting, "start failure: the reporter is inert")
        expectEqual(failing.calls.count, 1, "start failure: nothing after the failed start reaches the adapter")
        expectEqual(diagnostics.all, ["adapter_setup_failed"], "start failure: one bounded diagnostic")
        let unavailable = NativeCrashReportingGate.makeReporter(
            resolution: .enabled(options), makeAdapter: { throw FakeCrashError() }
        )
        expect(!unavailable.isReporting, "no SDK: the reporter is inert")

        expectEqual(
            NativeCrashReportingGate.releaseName(bundleID: "com.gettradereadyapp.tradeready", shortVersion: "1.4.0", build: "42"),
            release, "release: bundle@short+build"
        )
        expectEqual(
            NativeCrashReportingGate.releaseName(bundleID: nil, shortVersion: "$(MARKETING_VERSION)", build: " "),
            "unknown@unknown+unknown", "release: missing parts are 'unknown'"
        )
    }

    // MARK: 2. String scrubbing: every §10.1 value class

    static func stringRedaction() {
        for item in poison {
            let out = redaction.redactString(item.text)
            expect(!out.contains(item.leak), "string \(item.label): '\(item.leak)' is removed (got '\(out)')")
        }
        expectEqual(redaction.redactString("call 480-555-0100 today"), "call [phone] today", "string: a phone becomes [phone]")
        expectEqual(redaction.redactString("mail PAT@EXAMPLE.COM now"), "mail [email] now", "string: an upper-case email")
        expectEqual(redaction.redactString("BEARER abc123"), "Bearer [Filtered]", "string: bearer is case-insensitive")
        expectEqual(redaction.redactString("Access_Token=abc123"), "Access_Token=[Filtered]", "string: key=value is case-insensitive")
        expectEqual(redaction.redactString("x-api-key: abc123"), "x-api-key: [Filtered]", "string: API key header")
        expectEqual(
            redaction.redactURL("https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb/pay?t=abc#frag"),
            "https://api.gettradereadyapp.com/portal/[Filtered]/pay", "url: portal token segment and query removed"
        )
        expectEqual(
            redaction.redactURL("https://api.gettradereadyapp.com/booking/respond/abc?approve=1"),
            "https://api.gettradereadyapp.com/booking/[Filtered]/[Filtered]", "url: booking marker segments"
        )
        expectEqual(
            redaction.redactURL("https://tradeready.app/api/estimate/sk_live_abc123"),
            "https://tradeready.app/api/estimate/[Filtered]", "url: a credential-shaped segment"
        )
        expectEqual(
            redaction.redactURL("https://tradeready.app/api/x/a1b2c3d4e5f6g7h8i9j0k1"),
            "https://tradeready.app/api/x/[Filtered]", "url: a 20+ char token-shaped segment"
        )
        expectEqual(redaction.redactURL("https://paypal.me/PatOwner/25"), "https://paypal.me/[Filtered]", "url: payment handle")
        expectEqual(redaction.redactURL("https://venmo.com/u/pat-owner"), "https://venmo.com/[Filtered]", "url: venmo handle")
        expectEqual(redaction.redactURL("https://admin:pw@db.example.com:8443/rest"), "https://db.example.com:8443/rest", "url: userinfo dropped, port kept")
        expectEqual(redaction.redactURL("https://x.example.com/u/pat@example.com"), "https://x.example.com/u/[email]", "url: email segment")
        expectEqual(redaction.redactURL("https://x.example.com/call/4805550100"), "https://x.example.com/call/[phone]", "url: phone segment")
        expectEqual(redaction.redactString("see https://x.example.com/a?b=c."), "see https://x.example.com/a", "string: URL inside text loses its query")
        expectEqual(redaction.redactString("img data:image/png;base64,iVBORw0KGgo= end"), "img [document] end", "string: data URI")
    }

    static func preservedValues() {
        let keep = [
            "record 123e4567-e89b-12d3-a456-426614174000 failed",
            "job 1700000000000-abc12 failed",
            "id 1700000000000 failed",
            "due 2026-09-24 overdue",
            "at 2026-09-24T10:30:00-07:00",
            "took 12:30:45",
            "count 42 remaining 3",
            "PGRST116 JSON object requested, multiple (or no) rows returned",
            "https://abc.supabase.co/rest/v1/jobs",
            // 11.13 fix round 1 (I1): the Square token prefixes match whole
            // tokens only, not the provider name or an EAAA-free word.
            "provider square link saved for sq0 region EAA",
            // 11.13 fix round 3: `EAAA` needs a 20+ character token tail, so
            // short words that merely start with it are not redacted.
            "code EAAA and EAAAB and EAAAshortword are not tokens",
        ]
        for text in keep {
            expectEqual(redaction.redactString(text), text, "preserve: '\(text)'")
        }
        for word in ["EAAA", "EAAAB", "EAAAshortword", " EAAA1234567890123456789 "] {
            expectEqual(NativeSensitiveData.containsSecret(word), false, "containsSecret: '\(word)' is too short for a Square token")
        }
        let realistic = "EAAAl" + String(repeating: "Zx9_Kq-3", count: 7) + "abc"
        expectEqual(realistic.count, 64, "sanity: the realistic Square token is 64 characters")
        expectEqual(NativeSensitiveData.containsSecret(realistic), true, "containsSecret: a 64-character Square token")
        expectEqual(NativeSensitiveData.containsSecret("EAAA" + String(repeating: "a", count: 20)), true,
                    "containsSecret: EAAA plus a 20-character tail is the minimum token")
        let redactedRealistic = redaction.redactString("square rejected \(realistic) today")
        expectEqual(redactedRealistic.contains("EAAA") || redactedRealistic.contains("Zx9_Kq"), false,
                    "redactString scrubs a realistic 64-character Square token")
        expectEqual(
            redaction.redactURL("https://abc.supabase.co/rest/v1/jobs/123e4567-e89b-12d3-a456-426614174000"),
            "https://abc.supabase.co/rest/v1/jobs/123e4567-e89b-12d3-a456-426614174000",
            "preserve: UUID record ids in paths"
        )
    }

    // MARK: 2b. Idempotence (breadcrumbs pass beforeBreadcrumb, then beforeSend)
    // and custom-scheme deep links (the host is the first route segment)

    static func idempotenceAndCustomSchemes() {
        // The review case: a `[Filtered]` segment that follows no marker.
        let tokenThenPath = "https://tradeready.app/api/x/a1b2c3d4e5f6g7h8i9j0k1/next"
        expectEqual(redaction.redactURL(tokenThenPath), "https://tradeready.app/api/x/[Filtered]/next",
                    "idempotent: first pass filters the token segment")
        expectEqual(redaction.redactURL(redaction.redactURL(tokenThenPath)), "https://tradeready.app/api/x/[Filtered]/next",
                    "idempotent: a second pass keeps [Filtered] (not %5BFiltered%5D)")

        let urls = [
            tokenThenPath,
            "https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb/pay?t=abc#frag",
            "https://api.gettradereadyapp.com/booking/respond/abc?approve=1",
            "https://tradeready.app/api/estimate/sk_live_abc123",
            "https://paypal.me/PatOwner/25",
            "https://venmo.com/u/pat-owner",
            "https://admin:pw@db.example.com:8443/rest",
            "https://x.example.com/u/pat@example.com/more",
            "https://x.example.com/call/4805550100/log",
            "https://x.example.com/a%20b/100%25/c%2Fd",
            "https://Tradeready.APP/Jobs/123e4567-e89b-12d3-a456-426614174000",
            "tradeready://portal/Ab12Cd34/pay",
            "tradeready://job/1700000000000-abc12",
        ]
        for url in urls {
            let once = redaction.redactURL(url)
            expectEqual(redaction.redactURL(once), once, "idempotent url: '\(url)'")
            expectEqual(redaction.redactString("GET \(url) failed"), redaction.redactString(redaction.redactString("GET \(url) failed")),
                        "idempotent string with url: '\(url)'")
        }
        let strings = poison.map(\.text) + [
            "call 480-555-0100 today", "mail PAT@EXAMPLE.COM now", "BEARER abc123", "Access_Token=abc123",
            "x-api-key: abc123", "img data:image/png;base64,iVBORw0KGgo= end",
            "record 123e4567-e89b-12d3-a456-426614174000 failed", "due 2026-09-24 overdue",
            String(repeating: "ab ", count: 2_000), String(repeating: "é日", count: 800),
        ]
        for text in strings {
            let once = redaction.redactString(text)
            expectEqual(redaction.redactString(once), once, "idempotent string: '\(text.prefix(60))'")
        }
        let crumb = NativeCrashBreadcrumbPayload(
            category: "http", type: "http", message: poisonText(),
            data: ["url": tokenThenPath, "to": "tradeready://portal/Ab12Cd34", "status_code": 500]
        )
        let crumbOnce = redaction.redactBreadcrumb(crumb)
        expectEqual(canonicalJSON(redaction.redactBreadcrumb(crumbOnce).jsonObject), canonicalJSON(crumbOnce.jsonObject),
                    "idempotent: beforeBreadcrumb then beforeSend leaves the breadcrumb unchanged")
        var event = NativeCrashEventPayload()
        event.message = poisonText()
        event.breadcrumbs = [crumbOnce]
        event.request = .init(url: tokenThenPath, method: "GET")
        let eventOnce = redaction.redactEvent(event)
        expectEqual(canonicalJSON(redaction.redactEvent(eventOnce).jsonObject), canonicalJSON(eventOnce.jsonObject),
                    "idempotent: a redacted event redacts to itself")

        // Custom schemes: the host is the route, so a short token after a
        // token-bearing route is filtered like a path segment after a marker.
        expectEqual(redaction.redactURL("tradeready://portal/Ab12Cd34"), "tradeready://portal/[Filtered]",
                    "custom scheme: short token after tradeready://portal/")
        expectEqual(redaction.redactURL("tradeready://Portal/Ab12Cd34/pay"), "tradeready://portal/[Filtered]/pay",
                    "custom scheme: the route match ignores case; later segments are checked as usual")
        for route in NativeErrorRedaction.tokenPathMarkers.sorted() {
            expectEqual(redaction.redactURL("tradeready://\(route)/Ab12Cd34"), "tradeready://\(route)/[Filtered]",
                        "custom scheme: short token after tradeready://\(route)/")
            expect(!redaction.redactString("open tradeready://\(route)/Ab12Cd34 failed").contains("Ab12Cd34"),
                   "custom scheme in text: no token after tradeready://\(route)/")
        }
        expectEqual(redaction.redactURL("tradeready://reset-password/Qm7Xz2"), "tradeready://reset-password/[Filtered]",
                    "custom scheme: the reset-password route is token-bearing")
        // Record routes keep their ids; a network host named like a marker is not a route.
        expectEqual(redaction.redactURL("tradeready://job/1700000000000-abc12"), "tradeready://job/1700000000000-abc12",
                    "custom scheme: a job record id survives")
        expectEqual(redaction.redactURL("tradeready://onmyway/job-1"), "tradeready://onmyway/job-1",
                    "custom scheme: an on-my-way record id survives")
        expectEqual(redaction.redactURL("https://portal/status"), "https://portal/status",
                    "network scheme: a host named portal is a host, not a route")
    }

    // MARK: 3. Key classes (§10.1), case-insensitive, nested

    static func keyDenyClasses() {
        let denied = [
            "apiKey", "API_KEY", "x-api-key", "accessToken", "refresh_token", "Authorization", "password", "PASSWD",
            "sessionId", "Cookie", "clientSecret", "sentryDsn", "jwt", "otpCode",
            "email", "customerEmail", "phone", "MobileNumber", "customerName", "Customer_Name", "contactName", "address",
            "streetLine", "postalCode", "zipcode", "notes", "comment", "reviewText", "smsBody", "body", "requestBody",
            "payload", "recipient", "signature", "firstName", "LAST_NAME", "fullName", "username", "businessName",
            "deviceName", "latitude", "geo",
            "pdf", "pdfBase64", "imageBytes", "photo", "receiptImage", "csvExport", "attachment", "documentData",
            "blob", "filePath", "fileName",
            "amount", "balanceRemaining", "total", "unitPrice", "paymentLink",
            "query", "http.query", "http.fragment", "headers",
            "data", "name", "NAME", "text", "request", "response",
        ]
        for key in denied {
            expect(redaction.isDeniedKey(key), "keys: '\(key)' is denied")
        }
        let allowed = ["context", "operation", "collection", "status", "code", "count", "jobId", "invoiceId",
                       "componentStack", "message", "url", "method", "status_code", "category", "reason", "level"]
        for key in allowed {
            expect(!redaction.isDeniedKey(key), "keys: '\(key)' is allowed")
        }
        expect(!redaction.isDeniedKey("name", allowBareName: true), "keys: bare name allowed in platform contexts")

        let nested: [String: Any] = [
            "status": 500,
            "outer": [
                "inner": [
                    "Access_Token": "abc",
                    "customer": ["name": "Pat"],
                    "ok": "fine",
                    "photoData": Data([1, 2, 3]),
                    "deep": ["Email": "pat@example.com", "note": "call 480-555-0100", "detail": "call 480-555-0100"],
                ],
                "list": ["pat@example.com", 7, true, ["token": "x", "status": "ok"]],
            ],
            "raw": Data([0xFF]),
            "when": Date(timeIntervalSince1970: 0),
            "object": NSObject(),
            "nan": Double.nan,
        ]
        let out = redaction.redactDictionary(nested)
        let json = canonicalJSON(out)
        expect(json != "<invalid json>", "nested: the result is valid JSON")
        expect(!json.contains("abc") && !json.contains("Pat") && !json.contains("pat@example.com"),
               "nested: denied keys at depth are removed (\(json))")
        expect(!json.contains("480-555-0100"), "nested: values at depth are scrubbed")
        expect(json.contains("\"ok\":\"fine\""), "nested: safe values at depth survive")
        expect(json.contains("\"detail\":\"call [phone]\""), "nested: an allowed key keeps its scrubbed value")
        expect(json.contains("[\"[email]\",7,true,{\"status\":\"ok\"}]"), "nested: arrays are scrubbed element-wise")
        expect(out["raw"] == nil, "nested: Data (document bytes) is dropped")
        expect(!json.contains("photoData"), "nested: a document key is dropped")
        expectEqual(out["when"] as? String, "1970-01-01T00:00:00Z", "nested: a Date becomes ISO 8601")
        expect(out["object"] == nil, "nested: an arbitrary object is dropped")
        expect(out["nan"] == nil, "nested: a non-finite number is dropped")

        var deep: [String: Any] = ["leaf": "bottom"]
        for _ in 0..<12 { deep = ["level": deep] }
        let capped = canonicalJSON(redaction.redactDictionary(deep))
        expect(!capped.contains("bottom"), "nested: depth is capped at \(NativeErrorRedaction.maxDepth)")
        let long = Array(repeating: "x", count: 500)
        let arrayOut = redaction.redactValue(long) as? [Any]
        expectEqual(arrayOut?.count, NativeErrorRedaction.maxArrayCount, "nested: arrays are capped")
    }

    // MARK: 4. Whole events: exceptions, extras, tags, contexts, request, user

    static func poisonText() -> String {
        poison.map(\.text).joined(separator: " | ")
    }

    static func assertClean(_ json: String, _ label: String) {
        expect(json != "<invalid json>", "\(label): valid JSON")
        for item in poison {
            expect(!json.contains(item.leak), "\(label): no \(item.label) ('\(item.leak)')")
        }
    }

    static func eventRedaction() {
        let text = poisonText()
        var event = NativeCrashEventPayload()
        event.message = text
        event.exceptions = [
            .init(type: "TradeReady.ReportedError", value: text, mechanismDescription: text,
                  mechanismData: ["NSDebugDescription": text, "customerName": "Pat Owner", "requestBody": "{\"a\":1}"]),
        ]
        event.extras = ["context": text, "rawError": ["code": "PGRST", "message": text, "details": "row Pat Owner", "hint": text]]
        event.tags = ["screen": text, "email": "pat@example.com"]
        event.contexts = [
            "os": ["name": "iOS", "version": "26.0"],
            "device": ["name": "Pat Owner's iPhone", "model": "iPhone17,1"],
            "trace": ["op": text],
            "user info": ["NSDebugDescription": text, "customerPhone": "4805550100"],
            "customer": ["id": "c-1"],
        ]
        event.breadcrumbs = [.init(category: "http", type: "http", message: text,
                                   data: ["url": "https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb?t=1",
                                          "http.query": "t=abc", "status_code": 500, "body": "Pat Owner"])]
        event.request = .init(url: "https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb/x?token=abc#f",
                              method: "POST", headers: ["Authorization": "Bearer abc.def-ghi_123"],
                              cookies: "session=abc", queryString: "token=abc", fragment: "f", bodySize: 120)
        event.user = .init(id: "user-a", email: "pat@example.com", username: "patowner", ipAddress: "10.0.0.1",
                           name: "Pat Owner", data: ["phone": "4805550100"])
        event.serverName = "Pat Owner's iPhone"
        event.transaction = "open https://tradeready.app/book/pats-plumbing-slug"

        let out = redaction.redactEvent(event)
        let json = canonicalJSON(out.jsonObject)
        assertClean(json, "event")
        expect(!json.contains("Pat Owner") && !json.contains("patowner") && !json.contains("10.0.0.1"),
               "event: no customer or device-owner name, username or IP (\(json))")
        expect(!json.contains("{\\\"a\\\":1}") && !json.contains("requestBody"), "event: no request body")
        expectEqual(out.exceptions.first?.type, "TradeReady.ReportedError", "event: the exception type survives")
        expect(out.exceptions.first?.mechanismData?["customerName"] == nil, "event: mechanism data loses customer keys")
        expect(out.exceptions.first?.mechanismData?["NSDebugDescription"] != nil, "event: mechanism description text survives, scrubbed")
        expectEqual(out.tags["email"], nil, "event: a denied tag key is dropped")
        expect(out.tags["screen"] != nil, "event: a safe tag survives, scrubbed")
        expectEqual(out.contexts["os"]?["name"] as? String, "iOS", "event: the os context keeps its platform name")
        expect(out.contexts["device"]?["name"] == nil, "event: the device name (a person's name) is dropped")
        expectEqual(out.contexts["device"]?["model"] as? String, "iPhone17,1", "event: the device model survives")
        expect(out.contexts["customer"] == nil, "event: a customer context is dropped")
        expect(out.contexts["user info"]?["customerPhone"] == nil, "event: NSError user info loses PII keys")
        expectEqual(out.request?.url, "https://api.gettradereadyapp.com/portal/[Filtered]/x", "event: request URL has no token or query")
        expect(out.request?.headers == nil && out.request?.cookies == nil, "event: no request headers or cookies")
        expect(out.request?.queryString == nil && out.request?.fragment == nil, "event: no query string or fragment")
        expectEqual(out.request?.bodySize, 120, "event: body size (a number) is kept")
        expectEqual(out.user?.id, "user-a", "event: the user is {id}")
        expect(out.user?.email == nil && out.user?.username == nil && out.user?.ipAddress == nil
               && out.user?.name == nil && out.user?.data == nil, "event: the user is {id} only")
        expect(out.serverName == nil, "event: the server (device) name is dropped")
        expectEqual((out.extras["rawError"] as? [String: Any])?.keys.sorted(), ["code", "hint", "message"],
                    "event: rawError keeps {code, message, hint}")

        var bad = NativeCrashEventPayload()
        bad.user = .init(id: "pat@example.com")
        expect(redaction.redactEvent(bad).user == nil, "event: an email-shaped user id is dropped")
        bad.user = .init(id: "4805550100")
        expect(redaction.redactEvent(bad).user == nil, "event: a phone-shaped user id is dropped")
        bad.user = .init(id: "eyJhbGciOiJIUzI1NiJ9")
        expect(redaction.redactEvent(bad).user == nil, "event: a token-shaped user id is dropped")
    }

    // MARK: 5. Breadcrumbs and spans

    static func breadcrumbAndSpanRedaction() {
        let text = poisonText()
        let crumb = NativeCrashBreadcrumbPayload(
            category: "ui.lifecycle", type: "navigation", message: text,
            data: ["from": "Jobs", "to": text, "url": "https://tradeready.app/l/abcDEF123ghiJKL456mno?x=1",
                   "Customer_Name": "Pat", "nested": ["password": "hunter2", "ok": 1], "bytes": Data([1])]
        )
        let out = redaction.redactBreadcrumb(crumb)
        let json = canonicalJSON(out.jsonObject)
        assertClean(json, "breadcrumb")
        expect(!json.contains("Pat\"") && !json.contains("hunter2"), "breadcrumb: denied keys dropped at every depth")
        expectEqual(out.data?["from"] as? String, "Jobs", "breadcrumb: a safe value survives")
        expectEqual(out.data?["url"] as? String, "https://tradeready.app/l/[Filtered]", "breadcrumb: URL token and query removed")
        expect(out.data?["bytes"] == nil, "breadcrumb: bytes dropped")
        expectEqual(out.category, "ui.lifecycle", "breadcrumb: category survives")

        let span = redaction.redactSpan(
            description: "GET https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb?t=abc",
            data: ["url": "https://api.gettradereadyapp.com/portal/Zx9Kq2Lm7Np4Rt6Vw8Yb", "http.query": "t=abc",
                   "http.fragment": "f", "http.request.method": "GET", "http.response.status_code": 200]
        )
        expectEqual(span.description, "GET https://api.gettradereadyapp.com/portal/[Filtered]", "span: description scrubbed")
        expect(span.data["http.query"] == nil && span.data["http.fragment"] == nil, "span: query and fragment data dropped")
        expectEqual(span.data["url"] as? String, "https://api.gettradereadyapp.com/portal/[Filtered]", "span: url data scrubbed")
        expectEqual(span.data["http.request.method"] as? String, "GET", "span: method survives")
    }

    // MARK: 6. Extras allow-list and rawError (§10.3)

    static func extrasAllowList() {
        let extras: [String: Any] = [
            "context": "saveJob", "operation": "upsert", "collection": "jobs", "status": 409, "code": "23505",
            "count": 3, "jobId": "job-1", "invoiceId": "inv-1", "componentStack": "in JobForm",
            "customerName": "Pat Owner", "amount": 120, "token": "abc", "photo": Data([1]), "email": "pat@example.com",
            "rawError": ["code": "PGRST116", "message": "No rows for pat@example.com", "hint": nil as String? as Any,
                         "details": "Key (email)=(pat@example.com)", "row": ["name": "Pat"]],
        ]
        let out = redaction.redactExtras(extras)
        expectEqual(out.keys.sorted(), ["code", "collection", "componentStack", "context", "count", "invoiceId",
                                        "jobId", "operation", "rawError", "status"], "extras: only the §10.3 keys pass")
        let raw = out["rawError"] as? [String: Any]
        expectEqual(raw?.keys.sorted(), ["code", "message"], "extras: rawError keeps {code, message, hint} (hint absent)")
        expectEqual(raw?["message"] as? String, "No rows for [email]", "extras: rawError.message is scrubbed")
        expect(redaction.redactExtras(["rawError": "just text"])["rawError"] == nil, "extras: a non-object rawError is dropped")
        expect(redaction.redactExtras(["rawError": ["details": "x"]])["rawError"] == nil, "extras: an empty reduced rawError is dropped")
        expectEqual(redaction.redactExtras(["context": "call 480-555-0100"])["context"] as? String, "call [phone]",
                    "extras: allow-listed values are still scrubbed")
    }

    // MARK: 7. 1 KB cap

    static func stringCap() {
        // Words, not one run: a 120+ character alphanumeric run is scrubbed as base64.
        let long = String(repeating: "ab ", count: 2_000)
        let out = redaction.redactString(long)
        expect(out.utf8.count <= NativeErrorRedaction.maxStringBytes, "cap: at most 1 KB (\(out.utf8.count))")
        expect(out.hasSuffix("…"), "cap: a cut string ends with an ellipsis")
        let multibyte = String(repeating: "é日", count: 800)
        let cut = NativeErrorRedaction.capped(multibyte)
        expect(cut.utf8.count <= NativeErrorRedaction.maxStringBytes, "cap: multibyte text fits 1 KB")
        expect(String(data: cut.data(using: .utf8)!, encoding: .utf8) == cut, "cap: cut on a character boundary")
        let exact = String(repeating: "b", count: NativeErrorRedaction.maxStringBytes)
        expectEqual(NativeErrorRedaction.capped(exact), exact, "cap: exactly 1 KB is kept whole")
        var event = NativeCrashEventPayload()
        event.message = long
        event.exceptions = [.init(type: "T", value: long)]
        event.extras = ["context": long]
        event.breadcrumbs = [.init(category: "c", message: long, data: ["k1": long])]
        let redacted = redaction.redactEvent(event)
        expect((redacted.message ?? "").utf8.count <= 1_024, "cap: event message")
        expect((redacted.exceptions.first?.value ?? "").utf8.count <= 1_024, "cap: exception value")
        expect(((redacted.extras["context"] as? String) ?? "").utf8.count <= 1_024, "cap: extras value")
        expect((redacted.breadcrumbs.first?.message ?? "").utf8.count <= 1_024, "cap: breadcrumb message")
        expect(((redacted.breadcrumbs.first?.data?["k1"] as? String) ?? "").utf8.count <= 1_024, "cap: breadcrumb data")
        let longKey = String(repeating: "k", count: 2_000)
        let keyed = redaction.redactDictionary([longKey: "v"])
        expect(keyed.keys.allSatisfy { $0.utf8.count <= 1_024 }, "cap: dictionary keys")
    }

    // MARK: 8. reportError wrapper (§10.3)

    static func wrapperTitles() {
        func title(_ value: Any?) -> String? {
            NativeCrashReportBuilder.report(value, context: ["context": "t"]).title
        }
        expectEqual(title(["code": "PGRST116", "message": "JSON object requested", "details": "d", "hint": nil as String? as Any]),
                    "[PGRST116] JSON object requested", "wrapper: PostgREST object → [code] message")
        expectEqual(title(["code": 42, "message": "numeric code"]), "[42] numeric code", "wrapper: a numeric code")
        expectEqual(title(["code": true, "message": "bool code"]), "bool code", "wrapper: a Bool code is not a code")
        expectEqual(title(["message": "only message"]), "only message", "wrapper: message alone")
        expectEqual(title(["code": "X", "message": ""]), "{\"code\":\"X\",\"message\":\"\"}", "wrapper: an empty message falls back to JSON")
        expectEqual(title(["status": 500, "customerName": "Pat Owner"]), "{\"status\":500}",
                    "wrapper: the JSON title is built from the redacted value")
        expectEqual(title("plain string"), "\"plain string\"", "wrapper: a string is JSON-quoted (RN JSON.stringify)")
        expectEqual(title(7), "7", "wrapper: a number")
        expectEqual(title(nil), "null", "wrapper: nil → null")
        expectEqual(title(NSNull()), "null", "wrapper: NSNull → null")
        struct Secretive { let customer = "Pat Owner"; let token = "sk_live_abc" }
        expectEqual(title(Secretive()), "Non-error value of type Secretive", "wrapper: a non-JSON value names its type only")
        expectEqual(title(["code": "E1", "message": "failed for pat@example.com with sk_live_abc123"]),
                    "[E1] failed for [email] with [Filtered]", "wrapper: the title is redacted")
        let huge = title(["message": String(repeating: "m", count: 4_000)]) ?? ""
        expect(huge.utf8.count <= 1_024, "wrapper: the title is capped")

        for value in [["code": "a", "message": "b"] as Any, "x", 1, ["status": 1]] {
            let report = NativeCrashReportBuilder.report(value, context: ["context": "t"])
            let ns = report.error as NSError
            expectEqual(ns.domain, NativeReportedError.errorDomain, "wrapper: wrapped domain for \(value)")
            let described = ns.userInfo[NSDebugDescriptionErrorKey] as? String
            expect(described == report.title && !(described ?? "").isEmpty, "wrapper: the title is the debug description")
            expect(!(described ?? "").contains("Object captured as exception"), "wrapper: a meaningful title")
        }

        let raw: [String: Any] = ["code": "23505", "message": "dup", "details": "Key (email)=(pat@example.com)"]
        let wrapped = NativeCrashReportBuilder.report(raw, context: ["context": "saveCustomer", "customerName": "Pat"])
        expectEqual(canonicalJSON(wrapped.extras), "{\"context\":\"saveCustomer\",\"rawError\":{\"code\":\"23505\",\"message\":\"dup\"}}",
                    "wrapper: rawError reduced, context allow-listed")
        expectEqual(wrapped.fingerprint, ["{{ default }}", "saveCustomer"], "wrapper: fingerprint by context")
        expectEqual(NativeCrashReportBuilder.report("x", context: [:]).fingerprint, ["{{ default }}", "unspecified"],
                    "wrapper: no context → unspecified")

        let thrown = NSError(domain: "NSURLErrorDomain", code: -1009)
        let passthrough = NativeCrashReportBuilder.report(thrown, context: ["context": "deleteAccount"])
        expect((passthrough.error as NSError) === thrown, "wrapper: an Error is captured as is")
        expect(passthrough.title == nil, "wrapper: an Error is not re-titled")
        expect(passthrough.extras["rawError"] == nil, "wrapper: an Error adds no rawError")
    }

    // MARK: 9. Reporter: async, ordered, never throws

    static func reporterBehaviour() {
        let fake = FakeCrashAdapter()
        let crash = reporter(fake)
        crash.setUser(id: "user-a")
        crash.reportError(["code": "c1", "message": "m1"], context: ["context": "first"])
        crash.setUser(id: nil)
        crash.reportError(FakeCrashError(), context: "second")
        crash.waitUntilIdle()
        let calls = fake.calls
        expectEqual(calls.count, 4, "reporter: every call reaches the adapter")
        expectEqual(calls.first, .setUser("user-a"), "reporter: setUser {id}")
        if calls.count == 4 {
            expectEqual(calls[1], .capture(title: "[c1] m1", domain: NativeReportedError.errorDomain,
                                           extras: "{\"context\":\"first\",\"rawError\":{\"code\":\"c1\",\"message\":\"m1\"}}",
                                           fingerprint: ["{{ default }}", "first"]), "reporter: the wrapped capture")
            expectEqual(calls[2], .setUser(nil), "reporter: setUser(nil)")
            if case .capture(let title, _, let extras, _) = calls[3] {
                expect(title == nil && extras == "{\"context\":\"second\"}", "reporter: an Error with a string context")
            } else {
                expect(false, "reporter: the fourth call is a capture")
            }
        }

        let diagnostics = DiagnosticRecorder()
        let sanitizing = reporter(fake, diagnostics)
        fake.clear()
        sanitizing.setUser(id: "pat@example.com")
        sanitizing.setUser(id: "")
        sanitizing.setUser(id: "Bearer abc")
        sanitizing.waitUntilIdle()
        expectEqual(fake.calls, [.setUser(nil), .setUser(nil), .setUser(nil)], "reporter: a non-identifier id clears the user")
        expectEqual(diagnostics.all, ["invalid_user_id", "invalid_user_id", "invalid_user_id"], "reporter: bounded diagnostics")

        let throwing = ThrowingCrashAdapter()
        let throwDiagnostics = DiagnosticRecorder()
        let failing = reporter(throwing, throwDiagnostics)
        failing.reportError(["message": "m"], context: ["context": "x"])
        failing.setUser(id: "user-a")
        failing.waitUntilIdle()
        expectEqual(throwing.attempts, 2, "throwing adapter: both calls attempted")
        expectEqual(throwDiagnostics.all, ["capture_failed", "set_user_failed"], "throwing adapter: swallowed with codes")

    }

    // MARK: 10. setUser at every identity boundary (§9.4, 11.08 lifecycle)

    @MainActor
    static func identityBoundaries() {
        let fake = FakeCrashAdapter()
        let crash = reporter(fake)
        let (store, directory) = makeStore(crash, tag: "identity")
        defer { try? FileManager.default.removeItem(at: directory) }

        store.testSetAuthenticationGateState(.signedOut)
        store.testFinishInteractiveSignIn(subject: "user-a", binding: hexBinding("a1"), email: "a@example.com", method: .password)
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser("user-a")], "identity: sign-in sets {id}")

        store.testFinishInteractiveSignIn(subject: "user-a", binding: hexBinding("a1"), email: "a@example.com", method: .password)
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser("user-a")], "identity: re-verifying the same id is a no-op")

        store.testApplyCompletedSignOutState()
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser("user-a"), .setUser(nil)], "identity: sign-out clears the user")

        store.testApplyCompletedSignOutState()
        crash.waitUntilIdle()
        expectEqual(fake.calls.count, 2, "identity: a second boundary does not clear again")

        fake.clear()
        store.testFinishInteractiveSignIn(subject: "user-b", binding: hexBinding("b1"), email: "b@example.com", method: .apple)
        store.testFinishInteractiveSignIn(subject: "user-c", binding: hexBinding("c1"), email: "c@example.com", method: .google)
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser("user-b"), .setUser(nil), .setUser("user-c")],
                    "identity: a different verified id clears before setting")
        for call in fake.calls {
            if case .setUser(let id?) = call {
                expect(!id.contains("@"), "identity: never an email as the user")
            }
        }
    }

    @MainActor
    static func accountSwitchAndDeletion() async {
        let fake = FakeCrashAdapter()
        let crash = reporter(fake)
        let (store, directory) = makeStore(crash, tag: "switch")
        defer { try? FileManager.default.removeItem(at: directory) }

        store.testFinishInteractiveSignIn(subject: "user-a", binding: hexBinding("a2"), email: "a@example.com", method: .apple)
        store.scheduleBookingTestSeedIdentityActivator()
        await store.useAnotherAccount(clearGoogleCredential: {})
        store.testFinishInteractiveSignIn(subject: "user-b", binding: hexBinding("b2"), email: "b@example.com", method: .google)
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser("user-a"), .setUser(nil), .setUser("user-b")],
                    "switch: the user is cleared before the next owner")

        fake.clear()
        store.testApplyAccountDeletionAnalyticsBoundary()
        store.testApplyCompletedSignOutState()
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser(nil)], "deletion: exactly one clear")
        store.testFinishInteractiveSignIn(subject: "user-d", binding: hexBinding("d2"), email: "d@example.com", method: .password)
        crash.waitUntilIdle()
        expectEqual(fake.calls, [.setUser(nil), .setUser("user-d")], "deletion: the next owner is set without the deleted id")
    }

    // MARK: 11. Reporting never blocks or rolls back a commit

    @MainActor
    static func throwingAndSlowAdapterDoNotAffectCommits() {
        let throwing = ThrowingCrashAdapter()
        let crash = reporter(throwing)
        let (store, directory) = makeStore(crash, tag: "throwing")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.testFinishInteractiveSignIn(subject: "user-t", binding: hexBinding("f4"), email: "t@example.com", method: .password)
        var customer = Customer()
        customer.name = "Durable Customer"
        expect(store.upsert(customer), "throwing: the customer commit succeeds")
        store.reportError(["code": "x", "message": "after commit"], context: ["context": "saveCustomer"])
        var job = Job()
        job.customerId = customer.id
        job.customerName = customer.name
        job.title = "Durable job"
        job.status = .scheduled
        expect(store.upsert(job), "throwing: the job commit succeeds after a failed report")
        store.testApplyCompletedSignOutState()
        crash.waitUntilIdle()
        expect(throwing.attempts >= 3, "throwing: set, report and clear all reached the adapter (\(throwing.attempts))")
        let relaunched = AppStore(
            fileURL: directory.appending(path: "store.json"),
            seedIfMissing: false,
            subscriptionService: SubscriptionStub(),
            widgetTimelineReloader: NoopReloader()
        )
        expect(relaunched.customers.contains { $0.id == customer.id }, "throwing: the customer is on disk after relaunch")
        expect(relaunched.jobs.contains { $0.id == job.id }, "throwing: the job is on disk after relaunch")

        // A slow SDK: every adapter call blocks until released. The commit and
        // the report calls return immediately on the main actor.
        let blocking = BlockingCrashAdapter()
        let slow = reporter(blocking)
        let (slowStore, slowDirectory) = makeStore(slow, tag: "slow")
        defer { try? FileManager.default.removeItem(at: slowDirectory) }
        let started = Date()
        slowStore.testFinishInteractiveSignIn(subject: "user-s", binding: hexBinding("f5"), email: "s@example.com", method: .password)
        slowStore.reportError(["message": "one"], context: ["context": "slow"])
        slowStore.reportError(["message": "two"], context: ["context": "slow"])
        var slowCustomer = Customer()
        slowCustomer.name = "Slow SDK customer"
        expect(slowStore.upsert(slowCustomer), "slow: the commit succeeds while the SDK is blocked")
        let elapsed = Date().timeIntervalSince(started)
        expect(elapsed < 2, "slow: nothing waited on the blocked SDK (\(elapsed)s)")
        expectEqual(blocking.completed, 0, "slow: the SDK had not finished any call")
        for _ in 0..<3 { blocking.gate.signal() }
        slow.waitUntilIdle()
        expectEqual(blocking.timedOut, 0, "slow: no SDK call waited out its bound (none ran on the caller)")
        expectEqual(blocking.completed, 3, "slow: the queued calls finish once the SDK frees up")
    }

    // MARK: 12. Sync call sites (RN utils/sync.ts pushQueue / pullRemote)

    @MainActor
    static func syncCallSites() {
        let fake = FakeCrashAdapter()
        let crash = reporter(fake)
        let (store, directory) = makeStore(crash, tag: "sync")
        defer { try? FileManager.default.removeItem(at: directory) }

        func pass(_ end: NativeSyncStatus) {
            var running = end
            running.isSyncing = true
            store.testApplySyncStatus(running)
            store.testApplySyncStatus(end)
        }
        func captures() -> [CrashCall] {
            crash.waitUntilIdle()
            return fake.calls.filter { if case .capture = $0 { true } else { false } }
        }

        var failed = NativeSyncStatus()
        failed.lastOutcome = .failed(remaining: 3)
        failed.diagnosticCode = "push/http_503"
        pass(failed)
        expectEqual(captures(), [.capture(
            title: "[push/http_503] Sync push left changes queued", domain: NativeReportedError.errorDomain,
            extras: "{\"context\":\"pushQueue\",\"count\":3,\"rawError\":{\"code\":\"push/http_503\",\"message\":\"Sync push left changes queued\"}}",
            fingerprint: ["{{ default }}", "pushQueue"]
        )], "sync: a failed push reports pushQueue once")
        store.testApplySyncStatus(failed)
        expectEqual(captures().count, 1, "sync: republishing the ended status does not report again")

        fake.clear()
        var partial = NativeSyncStatus()
        partial.lastOutcome = .partial(pushed: 1, remaining: 2, authRefreshed: false)
        pass(partial)
        if case .capture(let title, _, let extras, _)? = captures().first {
            expectEqual(title, "[push/unavailable] Sync push left changes queued", "sync: a partial push without a code")
            expect(extras.contains("\"count\":2"), "sync: the remaining count is reported")
        } else {
            expect(false, "sync: a partial push reports")
        }

        fake.clear()
        var pulled = NativeSyncStatus()
        pulled.lastOutcome = .completed(pushed: 0, authRefreshed: false)
        pulled.lastPullResult = .failed("pull/jobs/http_500")
        pass(pulled)
        expectEqual(captures(), [.capture(
            title: "[pull/jobs/http_500] Sync pull did not complete", domain: NativeReportedError.errorDomain,
            extras: "{\"context\":\"pullRemote\",\"rawError\":{\"code\":\"pull/jobs/http_500\",\"message\":\"Sync pull did not complete\"}}",
            fingerprint: ["{{ default }}", "pullRemote"]
        )], "sync: a failed pull reports pullRemote")

        fake.clear()
        pulled.lastPullResult = .partial(nil)
        pass(pulled)
        expectEqual(captures().count, 1, "sync: a partial pull reports")

        fake.clear()
        for quiet in [NativeSyncOutcome.completed(pushed: 2, authRefreshed: false), .idleNoChanges, .offline,
                      .notAuthenticated, .backoffDeferred, .alreadyRunning] {
            var status = NativeSyncStatus()
            status.lastOutcome = quiet
            status.lastPullResult = .completed
            status.diagnosticCode = "stale/code"
            pass(status)
        }
        var skipped = NativeSyncStatus()
        skipped.lastOutcome = .completed(pushed: 0, authRefreshed: false)
        skipped.lastPullResult = .skipped
        pass(skipped)
        expectEqual(captures().count, 0, "sync: completed passes and early exits never report")
        expectEqual(store.syncStatus.lastPullResult, .skipped, "sync: the status is still published")
    }

    // MARK: 13. Wiring, linkage and manifests (source checks)

    /// Runs the dSYM script against a fake `sentry-cli` that records its
    /// arguments: the no-op paths send nothing, and `--include-sources` is
    /// passed only when `SENTRY_INCLUDE_SOURCES=1`.
    static func dsymScriptBehaviour(root: URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "tradeready-dsym-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: work) }
        let dsyms = work.appending(path: "dSYMs/TradeReadyNative.app.dSYM", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dsyms, withIntermediateDirectories: true)
        let argsFile = work.appending(path: "cli-args.txt")
        let cli = work.appending(path: "fake-sentry-cli")
        try? "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsFile.path)'\n".write(to: cli, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        func run(_ environment: [String: String]) -> (status: Int32, output: String, args: [String]?) {
            try? fm.removeItem(at: argsFile)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [root.appending(path: "native/scripts/upload-sentry-dsyms.sh").path, work.path]
            var env = ["PATH": "/usr/bin:/bin", "SENTRY_CLI": cli.path]
            env.merge(environment) { _, new in new }
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return (-1, "", nil) }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let args = (try? String(contentsOf: argsFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
            return (process.terminationStatus, output, args)
        }

        let noToken = run([:])
        expect(noToken.status == 0 && noToken.args == nil && noToken.output.contains("SENTRY_AUTH_TOKEN is not set"),
               "dSYM script: no token exits 0 and sends nothing")
        let emptyOrg = run(["SENTRY_AUTH_TOKEN": "test-only", "SENTRY_ORG": ""])
        expect(emptyOrg.status == 0 && emptyOrg.args == nil && emptyOrg.output.contains("SENTRY_ORG is empty"),
               "dSYM script: an empty SENTRY_ORG exits 0 and sends nothing")
        let emptyProject = run(["SENTRY_AUTH_TOKEN": "test-only", "SENTRY_PROJECT": ""])
        expect(emptyProject.status == 0 && emptyProject.args == nil && emptyProject.output.contains("SENTRY_PROJECT is empty"),
               "dSYM script: an empty SENTRY_PROJECT exits 0 and sends nothing")
        let plain = run(["SENTRY_AUTH_TOKEN": "test-only"])
        expectEqual(plain.args, ["debug-files", "upload", "--org", "tradeready-3r", "--project", "tradeready-ios",
                                 work.appending(path: "dSYMs").path],
                    "dSYM script: default upload has the default slugs and no --include-sources")
        expect(!(plain.args ?? []).contains("test-only"), "dSYM script: the token is never an argument")
        let withSources = run(["SENTRY_AUTH_TOKEN": "test-only", "SENTRY_INCLUDE_SOURCES": "1"])
        expect((withSources.args ?? []).contains("--include-sources"), "dSYM script: SENTRY_INCLUDE_SOURCES=1 opts in to source bundles")
        let otherValue = run(["SENTRY_AUTH_TOKEN": "test-only", "SENTRY_INCLUDE_SOURCES": "yes"])
        expect(otherValue.args != nil && !(otherValue.args ?? []).contains("--include-sources"),
               "dSYM script: only the value 1 opts in to source bundles")
    }

    static func read(_ root: URL, _ path: String) -> String {
        (try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? ""
    }

    static func sourceChecks(root: URL) {
        let settings = read(root, "native/TradeReadyNative/SettingsView.swift")
        expect(settings.contains("store.reportError(error, context: [\"context\": \"deleteAccount\"])"),
               "wiring: account deletion failures report (RN SettingsAccountScreen)")
        let app = read(root, "native/TradeReadyNative/TradeReadyNativeApp.swift")
        let live = app.range(of: "NativeCrashReporter.live()")
        let storeInit = app.range(of: "AppStore(analytics: NativeAnalyticsTransport.live(), crashReporting: crashReporter)")
        expect(live != nil && storeInit != nil && live!.lowerBound < storeInit!.lowerBound,
               "wiring: crash reporting starts before the store and is injected into it")
        let appStore = read(root, "native/TradeReadyNative/AppStore.swift")
        expect(appStore.contains("crashReporting.setUser(id: userID)") && appStore.contains("crashReporting.setUser(id: nil)"),
               "wiring: setUser rides the 11.08 identity actions")
        expectEqual(appStore.components(separatedBy: "crashReporting.setUser(").count - 1, 2,
                    "wiring: no second identity path")
        expect(read(root, "native/TradeReadyNative/NativeAnalytics.swift").contains("NativeSensitiveData."),
               "shared: analytics forwards to the shared sensitive-data screens")

        // Only one file imports the SDK, and the widget compiles none of it.
        var importers: [String] = []
        for folder in ["native/TradeReadyNative", "native/TradeReadyWidgets"] {
            let base = root.appending(path: folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if text.contains("import Sentry") { importers.append(file.lastPathComponent) }
                expect(!text.contains("ingest.sentry.io") && !text.contains("ingest.us.sentry.io"),
                       "no DSN: \(file.lastPathComponent) holds no Sentry DSN")
            }
        }
        expectEqual(importers, ["NativeCrashReportingSentry.swift"], "linkage: one file imports Sentry")

        let pbx = read(root, "native/TradeReadyNative.xcodeproj/project.pbxproj")
        expect(pbx.contains("repositoryURL = \"https://github.com/getsentry/sentry-cocoa\";"), "linkage: sentry-cocoa package")
        expect(pbx.contains("kind = exactVersion;\n\t\t\t\tversion = 9.29.0;"), "linkage: exactVersion 9.29.0")
        expectEqual(pbx.components(separatedBy: "/* Sentry in Frameworks */").count - 1, 2,
                    "linkage: one Sentry build file, used once")
        if let widgetPhase = pbx.range(of: "C11000000000000000000008 /* Frameworks */ = {"),
           let end = pbx.range(of: "};", range: widgetPhase.upperBound..<pbx.endIndex) {
            expect(!pbx[widgetPhase.upperBound..<end.lowerBound].contains("Sentry"), "linkage: the widget links no Sentry")
        } else {
            expect(false, "linkage: the widget Frameworks phase is present")
        }
        if let appPhase = pbx.range(of: "A00000000000000000000006 /* Frameworks */ = {"),
           let end = pbx.range(of: "};", range: appPhase.upperBound..<pbx.endIndex) {
            expect(pbx[appPhase.upperBound..<end.lowerBound].contains("Sentry in Frameworks"), "linkage: the app links Sentry")
        }
        expect(!pbx.contains("TRADEREADY_SENTRY_DSN"), "no DSN: no build setting assigns TRADEREADY_SENTRY_DSN")
        expect(!pbx.lowercased().contains("sentry-cli") && !pbx.contains("upload-sentry-dsyms"),
               "dSYM: no run-script build phase uploads symbols")
        let resolved = read(root, "native/TradeReadyNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        expect(resolved.contains("\"identity\" : \"sentry-cocoa\"") && resolved.contains("\"version\" : \"9.29.0\""),
               "linkage: Package.resolved pins sentry-cocoa 9.29.0")

        let info = read(root, "native/Info.plist")
        expect(info.contains("<key>TradeReadySentryDSN</key><string>$(TRADEREADY_SENTRY_DSN)</string>"),
               "no DSN: Info.plist reads the build setting only")
        expect(!info.contains("sentry.io"), "no DSN: Info.plist holds no DSN")
        expect(pbx.contains("https://staging.invalid"), "staging stays https://staging.invalid")

        let script = read(root, "native/scripts/upload-sentry-dsyms.sh")
        expect(script.contains("tradeready-3r") && script.contains("tradeready-ios"), "dSYM: org and native project slug")
        expect(script.contains("SENTRY_AUTH_TOKEN is not set; skipping"), "dSYM: no-op without a token")
        let assignments = script.split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("SENTRY_AUTH_TOKEN=") }
        expect(!script.contains("sntrys_") && assignments.isEmpty, "dSYM: no token in the repo")
        dsymScriptBehaviour(root: root)

        // Privacy manifests (§8).
        func plist(_ path: String) -> [String: Any] {
            guard let data = try? Data(contentsOf: root.appending(path: path)),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return [:] }
            return object
        }
        let manifest = plist("native/TradeReadyNative/PrivacyInfo.xcprivacy")
        expectEqual(manifest["NSPrivacyTracking"] as? Bool, false, "manifest: no tracking")
        expectEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, "manifest: no tracking domains")
        var apis: [String: [String]] = [:]
        for entry in manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
            apis[entry["NSPrivacyAccessedAPIType"] as? String ?? "?"] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        expectEqual(apis, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        ], "manifest: required-reason APIs")
        var collected: [String: String] = [:]
        for entry in manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [] {
            let type = (entry["NSPrivacyCollectedDataType"] as? String ?? "?").replacingOccurrences(of: "NSPrivacyCollectedDataType", with: "")
            let purposes = (entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [])
                .map { $0.replacingOccurrences(of: "NSPrivacyCollectedDataTypePurpose", with: "") }.joined(separator: "+")
            let linked = entry["NSPrivacyCollectedDataTypeLinked"] as? Bool
            let tracking = entry["NSPrivacyCollectedDataTypeTracking"] as? Bool
            collected[type] = "linked=\(linked.map(String.init) ?? "?") tracking=\(tracking.map(String.init) ?? "?") \(purposes)"
        }
        expectEqual(collected, [
            "UserID": "linked=true tracking=false Analytics+AppFunctionality",
            "ProductInteraction": "linked=true tracking=false Analytics",
            "OtherUsageData": "linked=true tracking=false Analytics",
            "OtherFinancialInfo": "linked=true tracking=false Analytics",
            "PurchaseHistory": "linked=true tracking=false Analytics",
            "CrashData": "linked=true tracking=false AppFunctionality",
            "PerformanceData": "linked=true tracking=false AppFunctionality",
            "OtherDiagnosticData": "linked=true tracking=false AppFunctionality",
        ], "manifest: collected-data types (§8.2 + §8.3 decisions; no Device ID)")
        let widget = plist("native/TradeReadyWidgets/PrivacyInfo.xcprivacy")
        expectEqual((widget["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "widget manifest: still no collected data")
    }
}
