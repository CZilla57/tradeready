import Foundation

// Task 11.07 (P1, P4): analytics transport and privacy controls.
//
// Drives `NativeAnalyticsTransport` / `NativeAnalyticsGate` /
// `NativeAnalyticsPrivacyPolicy` through a fake `NativeAnalyticsSDKAdapter`
// (the PostHog SDK is never linked here), and the real `AppStore` call sites
// through the same transport. Run with TZ=America/Phoenix. The first argument
// is the repository root (for the contract, Info.plist and project fixtures).

// MARK: - Fakes

enum FakeCall: Equatable {
    case capture(String, [String: NativeAnalyticsValue])
    case identify(String)
    case reset
    case screen(String)
}

final class FakeSDKAdapter: NativeAnalyticsSDKAdapter {
    var calls: [FakeCall] = []
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws {
        calls.append(.capture(event, properties))
    }
    func identify(_ distinctID: String) throws { calls.append(.identify(distinctID)) }
    func reset() throws { calls.append(.reset) }
    func screen(_ name: String) throws { calls.append(.screen(name)) }
}

struct FakeTransportError: Error {}

final class ThrowingSDKAdapter: NativeAnalyticsSDKAdapter {
    var attempts = 0
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws {
        attempts += 1
        throw FakeTransportError()
    }
    func identify(_ distinctID: String) throws { attempts += 1; throw FakeTransportError() }
    func reset() throws { attempts += 1; throw FakeTransportError() }
    func screen(_ name: String) throws { attempts += 1; throw FakeTransportError() }
}

/// Task 11.08 (m1): a conformer that implements only the single typed
/// requirement. Before m1 the protocol had two `track` requirements whose
/// defaults called each other, so a conformer implementing neither compiled
/// and recursed forever; now the typed one is the only requirement and every
/// convenience overload funnels into it.
final class TypedOnlyAnalytics: NativeAnalytics {
    var events: [(String, [String: NativeAnalyticsValue])] = []
    func track(_ event: String, _ properties: [String: NativeAnalyticsValue]) { events.append((event, properties)) }
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
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult { throw FakeTransportError() }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    func logOut() async {}
}

final class Recorder {
    var diagnostics: [NativeAnalyticsDiagnostic] = []
    var violations: [String] = []
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

func enabledTransport(
    _ adapter: NativeAnalyticsSDKAdapter,
    recorder: Recorder
) -> NativeAnalyticsTransport {
    NativeAnalyticsGate.makeTransport(
        resolution: NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: "phc_TESTKEYnotreal", host: nil),
        makeAdapter: { _ in adapter },
        diagnostics: { recorder.diagnostics.append($0) },
        catalogViolation: { recorder.violations.append($0) }
    )
}

/// Everything that left the process or was logged, as one string, so leak
/// checks cover the payloads and the diagnostics together.
func everythingObserved(_ adapter: FakeSDKAdapter, _ recorder: Recorder) -> String {
    let calls = adapter.calls.map { call -> String in
        switch call {
        case .capture(let event, let properties):
            let object = properties.mapValues(\.jsonObject)
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return "\(event) \(String(decoding: data, as: UTF8.self))"
        case .identify(let id): return "identify \(id)"
        case .reset: return "reset"
        case .screen(let name): return "screen \(name)"
        }
    }
    return (calls + recorder.diagnostics.map(\.message)).joined(separator: "\n")
}

func json(_ properties: [String: NativeAnalyticsValue]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: properties.mapValues(\.jsonObject), options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

@main
struct AnalyticsTransportTests {
    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        catalogFixture(root: root)
        gateAndConfiguration(root: root)
        configuredReleasePayloads()
        redaction()
        identityScreenAndSDKEvents()
        transportFailuresAreSwallowed()
        await existingCallSitesUnchanged()

        if failures > 0 {
            print("Analytics transport tests FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
        print("Analytics transport tests passed (\(checks) checks)")
    }

    // MARK: 1. §9.5 catalog fixture is verbatim and parses

    static func catalogFixture(root: URL) {
        let contract = root.appending(path: "docs/native-phase-11-platform-hardening-contract-decisions.md")
        guard let text = try? String(contentsOf: contract, encoding: .utf8),
              let marker = text.range(of: "**Event-catalog fixture.**"),
              let open = text.range(of: "```json\n", range: marker.upperBound..<text.endIndex),
              let close = text.range(of: "\n```", range: open.upperBound..<text.endIndex)
        else {
            expect(false, "catalog: the contract §9.5 JSON fixture block is readable at \(contract.path)")
            return
        }
        let docJSON = String(text[open.upperBound..<close.lowerBound])
        let docObject = try? JSONSerialization.jsonObject(with: Data(docJSON.utf8)) as? NSDictionary
        let embeddedObject = try? JSONSerialization.jsonObject(with: Data(NativeAnalyticsCatalogFixture.json.utf8)) as? NSDictionary
        expect(docObject != nil && embeddedObject != nil, "catalog: both fixtures parse as JSON objects")
        expect(docObject == embeddedObject, "catalog: the embedded fixture equals the contract §9.5 JSON block exactly")
        expectEqual(
            docJSON.trimmingCharacters(in: .whitespacesAndNewlines),
            NativeAnalyticsCatalogFixture.json.trimmingCharacters(in: .whitespacesAndNewlines),
            "catalog: the embedded fixture is byte-identical to the contract block"
        )

        guard let catalog = NativeAnalyticsEventCatalog.standard else {
            expect(false, "catalog: the standard catalog parses")
            return
        }
        expectEqual(catalog.catalogVersion, 1, "catalog: version 1")
        expectEqual(catalog.events.count, 52, "catalog: 52 events")
        expectEqual(catalog.events["invoice_created"]?.count, 3, "catalog: invoice_created has three variants")
        expectEqual(catalog.events["job_created"]?.first?["duplicated"],
                    .init(type: .trueLiteral, isOptional: true), "catalog: `duplicated?: true` is an optional literal")
        expectEqual(catalog.events["insight_shown"]?.first?["ids"], .init(type: .strings, isOptional: false),
                    "catalog: ids is string[]")
        expectEqual(catalog.events["change_order_decided"]?.first?["channel"],
                    .init(type: .oneOf(["manual"]), isOptional: false), "catalog: a single token is a fixed literal")
        expect((try? NativeAnalyticsEventCatalog(json: Data(#"{"catalogVersion":1,"enums":{},"events":{"x":[{"k":"enum:Nope"}]}}"#.utf8))) == nil,
               "catalog: an unknown enum reference fails to parse")

        // A catalog that failed to parse fails closed.
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let closed = NativeAnalyticsTransport(
            adapter: adapter, policy: NativeAnalyticsPrivacyPolicy(catalog: nil),
            diagnostics: { recorder.diagnostics.append($0) }, catalogViolation: { recorder.violations.append($0) })
        closed.track("estimate_sent")
        expect(adapter.calls.isEmpty, "catalog: no catalog → no events")
        expectEqual(recorder.diagnostics.first?.issues.first?.reason, .catalogUnavailable, "catalog: missing catalog is diagnosed")
    }

    // MARK: 2. Gate: Debug, missing and PLACEHOLDER keys emit nothing

    static func gateAndConfiguration(root: URL) {
        let us = URL(string: "https://us.i.posthog.com")!
        expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: true, apiKey: "phc_TESTKEYnotreal", host: nil),
                    .disabled(.disabledDebugBuild), "gate: Debug with a real-looking key is disabled")
        for missing in [nil, "", "   \n", "$(TRADEREADY_POSTHOG_API_KEY)"] as [String?] {
            expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: missing, host: nil),
                        .disabled(.disabledMissingKey), "gate: missing key \(String(describing: missing)) is disabled")
        }
        for placeholder in ["PLACEHOLDER", "PLACEHOLDER_POSTHOG_KEY", "  PLACEHOLDER-x  "] {
            expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: placeholder, host: nil),
                        .disabled(.disabledPlaceholderKey), "gate: \(placeholder) is disabled")
        }
        expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: " phc_TESTKEYnotreal ", host: nil),
                    .enabled(.init(apiKey: "phc_TESTKEYnotreal", host: us)), "gate: release + key → enabled, default US host, trimmed")
        expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: "phc_k", host: "$(TRADEREADY_POSTHOG_HOST)"),
                    .enabled(.init(apiKey: "phc_k", host: us)), "gate: an unexpanded host falls back to the default")
        expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: "phc_k", host: "https://eu.i.posthog.com"),
                    .enabled(.init(apiKey: "phc_k", host: URL(string: "https://eu.i.posthog.com")!)), "gate: explicit https host")
        for bad in ["http://us.i.posthog.com", "https://x.test/path", "https://x.test?token=1", "https://user:pw@x.test", "not a url"] {
            expectEqual(NativeAnalyticsGate.resolve(isDebugBuild: false, apiKey: "phc_k", host: bad),
                        .disabled(.disabledInvalidHost), "gate: host \(bad) disables analytics")
        }
        expectEqual(NativeAnalyticsGate.defaultHost, "https://us.i.posthog.com", "gate: RN host (App.tsx:824)")

        let disabledCases: [NativeAnalyticsGate.Resolution] = [
            .disabled(.disabledDebugBuild), .disabled(.disabledMissingKey),
            .disabled(.disabledPlaceholderKey), .disabled(.disabledInvalidHost),
        ]
        for resolution in disabledCases {
            let adapter = FakeSDKAdapter()
            let recorder = Recorder()
            var factoryCalls = 0
            let transport = NativeAnalyticsGate.makeTransport(
                resolution: resolution,
                makeAdapter: { _ in factoryCalls += 1; return adapter },
                diagnostics: { recorder.diagnostics.append($0) },
                catalogViolation: { recorder.violations.append($0) }
            )
            transport.track("payment_recorded", ["amount": 10, "method": "cash", "balanceRemaining": 0])
            transport.track("sample_job_opened")
            transport.track("insight_tapped", ["kind": "due_soon"])
            transport.identify("3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11")
            transport.screen("Today")
            transport.reset()
            expectEqual(factoryCalls, 0, "gate \(resolution): the SDK adapter is never built")
            expect(!transport.isEmitting, "gate \(resolution): transport is not emitting")
            expect(adapter.calls.isEmpty, "gate \(resolution): zero emits")
            expectEqual(recorder.diagnostics.filter { $0.operation == .setup }.count, 1,
                        "gate \(resolution): exactly one bounded setup diagnostic")
        }

        // An adapter that fails to set up leaves analytics off, without a crash.
        let recorder = Recorder()
        let failed = NativeAnalyticsGate.makeTransport(
            resolution: .enabled(.init(apiKey: "phc_k", host: us)),
            makeAdapter: { _ in throw FakeTransportError() },
            diagnostics: { recorder.diagnostics.append($0) }
        )
        failed.track("estimate_sent")
        failed.identify("user-1")
        expect(!failed.isEmitting, "gate: a failed adapter setup yields a non-emitting transport")
        expectEqual(recorder.diagnostics.first?.issues.first?.reason, .adapterSetupFailed, "gate: setup failure is diagnosed")

        // Configuration path: Info.plist mirrors the RN key through a build
        // setting; no committed configuration carries a key.
        let plist = (try? String(contentsOf: root.appending(path: "native/Info.plist"), encoding: .utf8)) ?? ""
        expect(plist.contains("<key>\(NativeAnalyticsGate.apiKeyInfoKey)</key><string>$(TRADEREADY_POSTHOG_API_KEY)</string>"),
               "config: Info.plist maps TradeReadyPostHogAPIKey to the build setting")
        expect(plist.contains("<key>\(NativeAnalyticsGate.hostInfoKey)</key><string>$(TRADEREADY_POSTHOG_HOST)</string>"),
               "config: Info.plist maps TradeReadyPostHogHost to the build setting")
        let project = (try? String(contentsOf: root.appending(path: "native/TradeReadyNative.xcodeproj/project.pbxproj"), encoding: .utf8)) ?? ""
        expect(!project.isEmpty, "config: project file readable")
        expect(!project.contains("TRADEREADY_POSTHOG_API_KEY"), "config: neither build configuration sets a PostHog key")
        expect(!project.contains("phc_") && !plist.contains("phc_"), "config: no PostHog project key is committed in native config")
        expect(project.contains("repositoryURL = \"https://github.com/PostHog/posthog-ios\";"), "config: PostHog package reference")
        if let refRange = project.range(of: "XCRemoteSwiftPackageReference \"posthog-ios\" */ = {") {
            let block = project[refRange.upperBound...].prefix(260)
            expect(block.contains("kind = exactVersion;") && block.contains("version = 3.81.0;"),
                   "config: PostHog pinned exactVersion 3.81.0")
        } else {
            expect(false, "config: PostHog package reference block present")
        }
        if let widget = project.range(of: "name = TradeReadyWidgets;\n\t\t\tpackageProductDependencies = (\n\t\t\t);") {
            expect(!widget.isEmpty, "config: the widget extension links no package")
        } else {
            expect(false, "config: the widget extension links no package (packageProductDependencies empty)")
        }
        let appTarget = project.range(of: "name = TradeReadyNative;\n\t\t\tpackageProductDependencies = (")
        let appDeps = appTarget.map { project[$0.upperBound...].prefix(400) } ?? ""
        expect(appDeps.contains("/* PostHog */"), "config: the app target links PostHog")
    }

    // MARK: 3. A configured release emits the exact payload

    static func configuredReleasePayloads() {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let transport = enabledTransport(adapter, recorder: recorder)
        expect(transport.isEmitting, "release: a configured key yields an emitting transport")

        transport.track("payment_recorded", ["amount": 125.5, "method": "cash", "balanceRemaining": 0])
        transport.track("invoice_created", ["source": "auto_on_complete", "usedTrackedTime": true, "autoEmailQueued": false])
        transport.track("invoice_created", ["source": "manual"])
        transport.track("invoice_created", ["source": "from_job", "mode": "requestDeposit"])
        transport.track("job_created", ["duplicated": true, "customerId": "1727190000000k3j9x", "first": false])
        transport.track("job_created", ["first": true])
        transport.track("insight_shown", ["kinds": ["due_soon", "labor_overrun"],
                                          "ids": ["due_soon:inv-1", "labor_overrun:1727190000000k3j9x"]])
        transport.track("insight_snoozed", ["kind": "open_slot", "insightId": "open_slot:2026-09-24", "days": 30])
        transport.track("receipt_scanned", ["outcome": "filled", "route": "backend"])
        transport.track("receipt_scanned", ["outcome": "failed"])
        transport.track("estimate_sent")
        transport.track("on_my_way_sent", [String: NativeAnalyticsValue]())
        transport.track("widget_deep_link_opened", ["type": "onmyway"])
        transport.track("pull_to_refresh", ["screen": "MoneyScreen"])
        transport.track("time_tracking_started", ["jobId": "3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11"])

        let expected: [FakeCall] = [
            .capture("payment_recorded", ["amount": 125.5, "method": "cash", "balanceRemaining": 0]),
            .capture("invoice_created", ["source": "auto_on_complete", "usedTrackedTime": true, "autoEmailQueued": false]),
            .capture("invoice_created", ["source": "manual"]),
            .capture("invoice_created", ["source": "from_job", "mode": "requestDeposit"]),
            .capture("job_created", ["duplicated": true, "customerId": "1727190000000k3j9x", "first": false]),
            .capture("job_created", ["first": true]),
            .capture("insight_shown", ["kinds": ["due_soon", "labor_overrun"],
                                       "ids": ["due_soon:inv-1", "labor_overrun:1727190000000k3j9x"]]),
            .capture("insight_snoozed", ["kind": "open_slot", "insightId": "open_slot:2026-09-24", "days": 30]),
            .capture("receipt_scanned", ["outcome": "filled", "route": "backend"]),
            .capture("receipt_scanned", ["outcome": "failed"]),
            .capture("estimate_sent", [:]),
            .capture("on_my_way_sent", [:]),
            .capture("widget_deep_link_opened", ["type": "onmyway"]),
            .capture("pull_to_refresh", ["screen": "MoneyScreen"]),
            .capture("time_tracking_started", ["jobId": "3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11"]),
        ]
        expectEqual(adapter.calls, expected, "release: the exact event/property payloads reach the SDK, in order")
        expect(recorder.diagnostics.isEmpty, "release: a clean catalog payload produces no diagnostic")
        expect(recorder.violations.isEmpty, "release: no catalog violation")

        // Wire form handed to PostHog: integral numbers are integers.
        expectEqual(json(["amount": 125.5, "method": "cash", "balanceRemaining": 0]),
                    #"{"amount":125.5,"balanceRemaining":0,"method":"cash"}"#, "release: JSON wire form")
        expectEqual(json(["days": 30]), #"{"days":30}"#, "release: an integral number serializes without .0")

        transport.identify("3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11")
        transport.screen("JobDetail")
        transport.reset()
        expectEqual(Array(adapter.calls.suffix(3)),
                    [.identify("3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11"), .screen("JobDetail"), .reset],
                    "release: identify (id only), screen and reset pass through")
    }

    // MARK: 4. Secure fields, PII, documents and oversize payloads

    static func redaction() {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let transport = enabledTransport(adapter, recorder: recorder)

        // Every secure/PII/document value class in a catalog `string` slot.
        let deniedValues: [(String, NativeAnalyticsDiagnostic.Reason)] = [
            ("sk-ant-api03-AbCdEf0123456789", .secretValue),          // Anthropic
            ("gsk_AbCdEf0123456789", .secretValue),                   // Groq
            ("AIzaSyA-legacyGeminiKey0123", .secretValue),            // legacy Gemini
            ("sk_live_51AbCdEf0123456789", .secretValue),             // Stripe secret
            ("sk_test_51AbCdEf0123456789", .secretValue),
            ("rk_live_51AbCdEf0123456789", .secretValue),             // Stripe restricted
            ("pk_live_51AbCdEf0123456789", .secretValue),             // Stripe publishable
            ("whsec_AbCdEf0123456789", .secretValue),                 // Stripe webhook
            ("appl_AbCdEf0123456789", .secretValue),                  // RevenueCat Apple
            ("goog_AbCdEf0123456789", .secretValue),                  // RevenueCat Google
            ("phc_AbCdEf0123456789", .secretValue),                   // PostHog project key
            ("sb_secret_AbCdEf0123456789", .secretValue),             // Supabase secret
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig", .secretValue), // Supabase access token (JWT)
            ("Bearer abc.def.ghi", .secretValue),                     // Authorization header
            ("refresh_token=abc", .secretValue),
            ("owner@example.com", .personalDataValue),                // email
            ("(555) 010-0100", .personalDataValue),                   // phone
            ("+15550100100", .personalDataValue),
            ("5550100", .personalDataValue),
            ("Dave Smith", .freeTextValue),                           // customer name
            ("12 Main St, Phoenix AZ", .freeTextValue),               // address
            ("Customer said the leak is back", .freeTextValue),       // notes / message body
            ("data:application/pdf;base64,JVBERi0xLjQK", .documentValue), // PDF bytes
            ("data:image/jpeg;base64,/9j/4AAQSkZJRg", .documentValue),     // receipt/job photo
            ("https://portal.example/p/abc?token=xyz", .documentValue),    // tokenized link
            ("JVBERi0xLjQKJcfsj6IKNSAwIG9iago8PC9MZW5ndGggNiAwIFI+Pgo=", .freeTextValue), // raw base64
            (String(repeating: "a", count: 129), .oversizeValue),
        ]
        for (value, reason) in deniedValues {
            adapter.calls.removeAll()
            recorder.diagnostics.removeAll()
            transport.track("insight_dismissed", ["kind": "due_soon", "insightId": .string(value)])
            expectEqual(adapter.calls, [.capture("insight_dismissed", ["kind": "due_soon"])],
                        "redaction: \(reason) value is stripped and the event still sends")
            expectEqual(recorder.diagnostics.first?.issues, [.init(key: "insightId", reason: reason)],
                        "redaction: \(value.prefix(12))… diagnosed as \(reason)")
            let observed = everythingObserved(adapter, recorder)
            expect(!observed.contains(value), "redaction: the \(reason) value appears nowhere in payloads or diagnostics")
        }
        // Identifier shapes that must still pass.
        for allowed in ["1727190000000k3j9x", "3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11", "low_margin_estimate:j1:1234.5",
                        "open_slot:2026-09-24", "s1a2b3c4d5", "17271900000001234"] {
            adapter.calls.removeAll()
            transport.track("insight_dismissed", ["kind": "due_soon", "insightId": .string(allowed)])
            expectEqual(adapter.calls, [.capture("insight_dismissed", ["kind": "due_soon", "insightId": .string(allowed)])],
                        "redaction: id \(allowed) passes")
        }

        // Every secure-field KEY class is stripped even alongside valid data.
        adapter.calls.removeAll()
        recorder.diagnostics.removeAll()
        transport.track("payment_link_sent", [
            "provider": "stripe", "deposit": true,
            "providerKey": "acct_live_backend_token", "anthropicKey": "sk-ant-x", "groqKey": "gsk_x",
            "rcAppleApiKey": "appl_x", "accessToken": "eyJx.y.z", "Authorization": "Bearer x",
            "customerName": "Dave Smith", "email": "owner@example.com", "phone": "555-0100",
            "notes": "gate code 1234", "pdfData": "JVBERi0", "receiptImage": "data:image/png;base64,iVBOR",
            "whatever": 1,
        ])
        expectEqual(adapter.calls, [.capture("payment_link_sent", ["provider": "stripe", "deposit": true])],
                    "redaction: only the catalog keys of payment_link_sent leave the device")
        let keyIssues = recorder.diagnostics.first
        expectEqual(keyIssues?.issues.count, NativeAnalyticsDiagnostic.maxIssues, "redaction: the diagnostic holds at most 8 issues")
        expectEqual(keyIssues?.omittedIssueCount, 5, "redaction: the rest are counted, not listed")
        expect((keyIssues?.message.count ?? .max) <= NativeAnalyticsDiagnostic.maxMessageLength, "redaction: bounded message")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("anthropicKey"), .secureKey, "key: anthropicKey")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("groqKey"), .secureKey, "key: groqKey")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("geminiKey"), .secureKey, "key: geminiKey")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("providerKeys"), .secureKey, "key: providerKeys")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("TradeReadyRevenueCatAPIKey"), .secureKey, "key: RevenueCat")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("refresh_token"), .secureKey, "key: refresh token")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("customerEmail"), .personalDataKey, "key: email")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("reviewText"), .personalDataKey, "key: review text")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("photoBase64"), .documentKey, "key: photo bytes")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("csvExport"), .documentKey, "key: CSV export")
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey("whatever"), .unknownKey, "key: other")
        let observedKeys = everythingObserved(adapter, recorder)
        for secret in ["acct_live_backend_token", "sk-ant-x", "gsk_x", "appl_x", "eyJx.y.z", "Bearer x", "Dave Smith",
                       "owner@example.com", "555-0100", "gate code", "JVBERi0", "iVBOR"] {
            expect(!observedKeys.contains(secret), "redaction: \(secret) never observed")
        }

        // A key that is itself PII is not echoed in the diagnostic.
        recorder.diagnostics.removeAll()
        transport.track("estimate_sent", ["dave@example.com": true])
        expectEqual(recorder.diagnostics.first?.issues.first?.key, "<redacted>", "redaction: a PII-shaped key is not echoed")
        expect(!everythingObserved(adapter, recorder).contains("dave@example.com"), "redaction: PII key never observed")

        // Wrong type / enum / literal / non-finite are stripped; the event still sends.
        adapter.calls.removeAll()
        recorder.diagnostics.removeAll()
        transport.track("setup_checklist_dismissed", ["doneCount": "3"])
        transport.track("sign_in", ["method": "facebook"])
        transport.track("job_created", ["duplicated": false, "first": true])
        transport.track("payment_voided", ["amount": .number(.nan), "method": "card"])
        transport.track("payment_voided", ["amount": .number(.infinity), "method": "card"])
        transport.track("insight_shown", ["kinds": ["due_soon", "not_a_kind"], "ids": ["a"]])
        expectEqual(adapter.calls, [
            .capture("setup_checklist_dismissed", [:]),
            .capture("sign_in", [:]),
            .capture("job_created", ["first": true]),
            .capture("payment_voided", ["method": "card"]),
            .capture("payment_voided", ["method": "card"]),
            .capture("insight_shown", ["ids": ["a"]]),
        ], "redaction: invalid values are stripped, events still send")
        expectEqual(recorder.diagnostics.map { $0.issues.first?.reason }, [
            .wrongType, .notInCatalogEnum, .notInCatalogEnum, .nonFiniteNumber, .nonFiniteNumber, .notInCatalogEnum,
        ], "redaction: each strip is diagnosed")

        // Oversize: an array over 64 items, and a payload over 4 KB.
        adapter.calls.removeAll()
        recorder.diagnostics.removeAll()
        transport.track("insight_shown", ["kinds": ["due_soon"], "ids": .strings((0..<65).map { "id\($0)" })])
        expectEqual(adapter.calls, [.capture("insight_shown", ["kinds": ["due_soon"]])], "oversize: 65 ids are stripped")
        expectEqual(recorder.diagnostics.first?.issues, [.init(key: "ids", reason: .oversizeValue)], "oversize: diagnosed")
        adapter.calls.removeAll()
        recorder.diagnostics.removeAll()
        let bigIDs = (0..<64).map { "id\($0)-" + String(repeating: "x", count: 100) }
        transport.track("insight_shown", ["kinds": ["due_soon"], "ids": .strings(bigIDs)])
        expect(adapter.calls.isEmpty, "oversize: a payload over 4 KB is rejected whole")
        expectEqual(recorder.diagnostics.first?.issues, [.init(key: "", reason: .payloadTooLarge)], "oversize: diagnosed")
        expect(!everythingObserved(adapter, recorder).contains("xxxxxxxxxx"), "oversize: nothing of the payload observed")

        // Unknown events are dropped and flagged (Debug asserts through this hook).
        adapter.calls.removeAll()
        recorder.diagnostics.removeAll()
        recorder.violations.removeAll()
        transport.track("screen_viewed", ["name": "Today"])
        transport.track("owner@example.com")
        expect(adapter.calls.isEmpty, "unknown event: dropped")
        expectEqual(recorder.violations.count, 2, "unknown event: the catalog-violation hook fires (Debug assert)")
        expectEqual(recorder.diagnostics.map(\.event), ["screen_viewed", "<redacted>"], "unknown event: name sanitized")
        expect(!recorder.violations.joined().contains("owner@example.com"), "unknown event: PII name not echoed")
    }

    // MARK: 5. identify / screen validation and the SDK-event allow-list

    static func identityScreenAndSDKEvents() {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let transport = enabledTransport(adapter, recorder: recorder)
        for bad in ["", "owner@example.com", "Dave Smith", "eyJhbGciOiJIUzI1NiJ9.x.y", String(repeating: "a", count: 129)] {
            transport.identify(bad)
        }
        expect(adapter.calls.isEmpty, "identify: emails, names, tokens and oversize ids never reach the SDK")
        expectEqual(recorder.diagnostics.map { $0.issues.first?.reason }, Array(repeating: .invalidIdentity, count: 5),
                    "identify: each rejection is diagnosed")
        expect(!everythingObserved(adapter, recorder).contains("owner@example.com"), "identify: rejected id not logged")

        recorder.diagnostics.removeAll()
        for bad in ["", "Job Detail", "JobDetail/abc", "dave@example.com", "1Today", String(repeating: "A", count: 65)] {
            transport.screen(bad)
        }
        expect(adapter.calls.isEmpty, "screen: non-route names never reach the SDK")
        expectEqual(recorder.diagnostics.count, 6, "screen: each rejection is diagnosed")

        let policy = NativeAnalyticsPrivacyPolicy.standard
        for allowed in ["$screen", "$identify", "Application Installed", "Application Updated", "Application Opened",
                        "Application Backgrounded", "estimate_sent", "ai_chat_sent"] {
            expect(policy.permitsOutgoingEvent(allowed), "beforeSend: \(allowed) permitted")
        }
        for denied in ["$autocapture", "$rageclick", "$exception", "Deep Link Opened", "$push_notification_opened",
                       "$feature_flag_called", "$snapshot", "$set", "$create_alias", "$groupidentify", "custom"] {
            expect(!policy.permitsOutgoingEvent(denied), "beforeSend: \(denied) dropped")
        }
    }

    // MARK: 6. Transport failures are swallowed

    static func transportFailuresAreSwallowed() {
        let adapter = ThrowingSDKAdapter()
        let recorder = Recorder()
        let transport = enabledTransport(adapter, recorder: recorder)
        transport.track("estimate_sent")
        transport.track("insight_tapped", ["kind": "due_soon"])
        transport.identify("3f7b8f2e-8d7c-4c1e-9f1a-2b1f0d9e6a11")
        transport.screen("Today")
        transport.reset()
        expectEqual(adapter.attempts, 5, "failures: every call still reached the adapter")
        expectEqual(recorder.diagnostics.map { $0.issues.first?.reason }, Array(repeating: .transportFailure, count: 5),
                    "failures: each throw is swallowed with a bounded diagnostic")
        expect(recorder.diagnostics.allSatisfy { !$0.message.contains("FakeTransportError") },
               "failures: the error description is not logged")
    }

    // MARK: 7. Call sites after the 11.08 handoff (typed values, m1)

    @MainActor
    static func existingCallSitesUnchanged() async {
        // (a) m1: the single typed requirement receives every overload.
        let typed = TypedOnlyAnalytics()
        let seam: NativeAnalytics = typed
        seam.track("sample_job_opened")
        seam.track("insight_tapped", ["kind": "due_soon"])
        seam.track(.insightShown(kinds: [.dueSoon, .openSlot], ids: ["a", "b"]))
        seam.track(.setupChecklistDismissed(doneCount: 3))
        seam.identify("u"); seam.reset(); seam.screen("Today")
        expectEqual(typed.events.map(\.0), ["sample_job_opened", "insight_tapped", "insight_shown", "setup_checklist_dismissed"],
                    "typed conformer: receives every track call")
        expectEqual(typed.events[2].1, ["kinds": ["due_soon", "open_slot"], "ids": ["a", "b"]], "typed conformer: arrays stay arrays")
        expectEqual(typed.events[3].1, ["doneCount": 3], "typed conformer: doneCount is a number")
        expectEqual(typed.events[3].1.mapValues(\.legacyStringValue), ["doneCount": "3"], "legacy view: integral number without .0")
        let noop: NativeAnalytics = NativeNoOpAnalytics()
        noop.track("estimate_sent"); noop.track("x", ["k": "v"]); noop.track(.estimateSent)
        noop.identify("u"); noop.reset(); noop.screen("Today")

        // (b) The 11.07 handoff is closed: the formerly stringified
        // `doneCount`/`days` and joined `kinds`/`ids` are typed constructors
        // now, so they reach the adapter intact with no diagnostic.
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let transport = enabledTransport(adapter, recorder: recorder)
        let analytics: NativeAnalytics = transport
        analytics.track(.setupChecklistDismissed(doneCount: 2))
        analytics.track(.sampleJobOpened)
        let insight = NativeTodayInsight(kind: .dueSoon, id: "due_soon:inv-1", title: "Invoice due",
                                         target: .invoices, reason: "Due in 2 days")
        analytics.track(.insightSnoozed(insight.kind, insightID: insight.id, days: 30))
        analytics.track(.insightDismissed(insight.kind, insightID: insight.id))
        analytics.track(.widgetDeepLinkOpened(type: NativeDeepLinkRoutingPolicy.analyticsType(.job(id: "j1"))))
        expectEqual(adapter.calls, [
            .capture("setup_checklist_dismissed", ["doneCount": 2]),
            .capture("sample_job_opened", [:]),
            .capture("insight_snoozed", ["kind": "due_soon", "insightId": "due_soon:inv-1", "days": 30]),
            .capture("insight_dismissed", ["kind": "due_soon", "insightId": "due_soon:inv-1"]),
            .capture("widget_deep_link_opened", ["type": "job"]),
        ], "call sites: typed constructors keep numbers as numbers")
        expect(recorder.diagnostics.isEmpty, "call sites: nothing is stripped once the values are typed")

        // (c) The real AppStore, constructed with the transport, fires its
        // unchanged call sites through it.
        adapter.calls.removeAll()
        recorder.diagnostics.removeAll()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tradeready-analytics-transport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(
            fileURL: directory.appending(path: "store.json"),
            seedIfMissing: true,
            subscriptionService: SubscriptionStub(),
            analytics: transport,
            widgetTimelineReloader: NoopReloader()
        )
        store.coachAdvisoryAnthropicKeyOverride = ""
        store.coachAdvisoryGroqKeyOverride = ""
        store.trackInsightTapped(insight)
        store.trackInsightCoachOpened(insight)
        store.trackInsightReasonViewed(insight)
        store.trackSetupChecklistTaskOpened(.rate)
        store.trackCoachMessageSent(sourceIsInsightPrefill: true)
        store.trackCoachMessageSent(sourceIsInsightPrefill: false)
        store.trackTodayInsightsShownIfNeeded([insight])
        expectEqual(adapter.calls, [
            .capture("insight_tapped", ["kind": "due_soon"]),
            .capture("insight_coach_opened", ["kind": "due_soon"]),
            .capture("insight_reason_viewed", ["kind": "due_soon"]),
            .capture("setup_checklist_task_opened", ["task": "rate"]),
            .capture("ai_chat_sent", ["source": "insight_prefill", "provider": "backend"]),
            .capture("ai_chat_sent", ["source": "organic", "provider": "backend"]),
            // Task 11.08: string arrays, no longer comma-joined strings.
            .capture("insight_shown", ["kinds": ["due_soon"], "ids": ["due_soon:inv-1"]]),
        ], "AppStore: call sites emit through the transport")
        expect(recorder.diagnostics.isEmpty, "AppStore: insight_shown's typed arrays pass the policy unstripped")
        expect(recorder.violations.isEmpty, "AppStore: every existing event name is in the catalog")
    }
}
