import Foundation

// Task 11.08 host tests: event parity and the identity lifecycle (contract
// §9.3–§9.5, §9.7). The real AppStore runs with the real
// `NativeAnalyticsTransport` over a recording fake SDK adapter, so every
// assertion below is about what would actually leave the process: the exact
// ordered capture / identify / reset / screen calls, after the privacy
// policy. Run with TZ=America/Phoenix (the runner defaults it).

// MARK: - Fakes

enum AdapterCall: Equatable, CustomStringConvertible {
    case capture(String, [String: NativeAnalyticsValue])
    case identify(String)
    case reset
    case screen(String)

    var description: String {
        switch self {
        case .capture(let event, let properties):
            let body = properties.keys.sorted().map { "\($0)=\(properties[$0]!.legacyStringValue)" }.joined(separator: ",")
            return "capture(\(event){\(body)})"
        case .identify(let id): return "identify(\(id))"
        case .reset: return "reset"
        case .screen(let name): return "screen(\(name))"
        }
    }
}

final class FakeSDKAdapter: NativeAnalyticsSDKAdapter {
    var calls: [AdapterCall] = []
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws { calls.append(.capture(event, properties)) }
    func identify(_ distinctID: String) throws { calls.append(.identify(distinctID)) }
    func reset() throws { calls.append(.reset) }
    func screen(_ name: String) throws { calls.append(.screen(name)) }
}

struct FakeTransportError: Error {}

final class ThrowingSDKAdapter: NativeAnalyticsSDKAdapter {
    var attempts = 0
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws { attempts += 1; throw FakeTransportError() }
    func identify(_ distinctID: String) throws { attempts += 1; throw FakeTransportError() }
    func reset() throws { attempts += 1; throw FakeTransportError() }
    func screen(_ name: String) throws { attempts += 1; throw FakeTransportError() }
}

final class Recorder {
    var diagnostics: [NativeAnalyticsDiagnostic] = []
    var violations: [String] = []
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

func transport(_ adapter: NativeAnalyticsSDKAdapter, _ recorder: Recorder) -> NativeAnalyticsTransport {
    NativeAnalyticsTransport(
        adapter: adapter,
        diagnostics: { recorder.diagnostics.append($0) },
        catalogViolation: { recorder.violations.append($0) }
    )
}

@MainActor
func makeStore(_ analytics: NativeAnalytics, tag: String) -> (AppStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tradeready-analytics-events-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "store.json")
    let store = AppStore(
        fileURL: url,
        seedIfMissing: false,
        subscriptionService: SubscriptionStub(),
        analytics: analytics,
        widgetTimelineReloader: NoopReloader()
    )
    store.coachAdvisoryAnthropicKeyOverride = ""
    store.coachAdvisoryGroqKeyOverride = ""
    return (store, directory)
}

// MARK: - Tests

@main
struct AnalyticsEventTests {
    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")
        catalogParity()
        variantSelectionM2()
        sanitizedNameM3()
        identityLifecycle()
        gatePolicy()
        screenNames(root: root)
        await signInWorkSignOutJourney()
        await accountSwitchAndDeletion(root: root)
        contextualEvents()
        await pullToRefreshOwnerGuard()
        signInLandingOnAccountMismatch()
        screenAppearances(root: root)
        throwingTransportDoesNotAffectCommits()

        if failures > 0 {
            print("Analytics event tests FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
        print("Analytics event tests passed (\(checks) checks)")
    }

    // MARK: 1. Every catalog event, name and property (§9.5)

    /// One typed constructor call per catalog event and per variant. Each
    /// must pass the shipped policy unchanged: same name, every property kept
    /// with its type, no diagnostic (so no missing required key either).
    static let everyEvent: [NativeAnalyticsEvent] = [
        .aiChatSent(.insightPrefill, provider: "backend"),
        .aiChatSent(.organic, provider: "anthropic"),
        .appointmentConfirmOpened,
        .appointmentConfirmSent,
        .bookingRequestOpened,
        .bookingUpdateOpened,
        .bulkInvoiceReminders(channel: .email, count: 3),
        .bulkInvoiceReminders(channel: .text, count: 1),
        .bulkInvoiceReminderRun(channel: .email, presentedCount: 2),
        .bulkInvoiceReminderRun(channel: .text, presentedCount: 0),
        .bulkInvoicesMarkedPaid(count: 2),
        .changeOrderCreated(amount: Decimal(string: "125.50")!),
        .changeOrderDecided(.approved),
        .changeOrderDecided(.declined),
        .changeOrderSent(amount: 80, channel: .text),
        .customerCreated(first: true),
        .customersMerged(jobs: 2, invoices: 1),
        .estimateFollowUpOpened(source: .jobDetail),
        .estimateFollowUpOpened(source: .notification),
        .estimateFollowUpSent(channel: .sms, source: .notification),
        .estimateFollowUpSent(channel: .email, source: .jobDetail),
        .estimateSent,
        .expenseLogged(category: .fuel, linkedToJob: true),
        .firstActionTapped(.addCustomer),
        .firstActionTapped(.createJob),
        .insightCoachOpened(.dueSoon),
        .insightDismissed(.openSlot, insightID: "open_slot:2026-09-24"),
        .insightReasonViewed(.laborOverrun),
        .insightShown(kinds: [.dueSoon, .laborOverrun], ids: ["due_soon:inv-1", "labor_overrun:1727190000000k3j9x"]),
        .insightSnoozed(.maintenanceDue, insightID: "maintenance_due:c1", days: 30),
        .insightTapped(.expenseAnomaly),
        .invoiceCreatedFromJob(mode: .create),
        .invoiceCreatedFromJob(mode: .requestDeposit),
        .invoiceCreatedFromJob(mode: .finalize),
        .invoiceCreatedManually,
        .invoiceCreatedOnCompletion(usedTrackedTime: true, autoEmailQueued: false),
        .invoiceFinalizedFromJob,
        .invoicePaid(amount: 1250.75),
        .jobCreated(first: true, customerID: "1727190000000k3j9x", duplicated: true),
        .jobCreated(first: false, customerID: nil, duplicated: false),
        .jobStatusChanged(from: .inProgress, to: .complete),
        .onMyWaySent,
        .onboardingCompleted(trade: .electrical),
        .onboardingStartChoice(.sample),
        .onboardingStartChoice(.fresh),
        .onboardingStepViewed(.welcome),
        .onboardingStepViewed(.business),
        .onboardingStepViewed(.startingPoint),
        .overdueOutreachOpened(daysPastDue: 7),
        .overdueOutreachOpened(daysPastDue: nil),
        .paymentLinkSent(provider: "stripe", deposit: true),
        .paymentRecorded(amount: 50, method: "Cheque", balanceRemaining: 25.5),
        .paymentVoided(amount: 50, method: "Venmo"),
        .pricebookEntrySaved,
        .pullToRefresh(.money),
        .pullToRefresh(.jobs),
        .receiptScanFailed,
        .receiptScanned(.filled, route: .userKey),
        .receiptScanned(.empty, route: .backend),
        .reviewRequestSent(channel: .email, source: .jobDetail),
        .sampleJobOpened,
        .setupChecklistDismissed(doneCount: 3),
        .setupChecklistTaskOpened(.notifications),
        .signIn(.password),
        .signIn(.apple),
        .signIn(.google),
        .signUp,
        .signUpConfirmationResent,
        .subscriptionPaywallShown(.onboardingGate),
        .subscriptionPaywallShown(.settings),
        .subscriptionPurchased,
        .taxSettingsSaved(hasIncomeRate: true, vehicleMethod: .mileage),
        .taxSettingsSaved(hasIncomeRate: false, vehicleMethod: nil),
        .timeTrackingStarted(jobID: "1727190000000k3j9x"),
        .tripLogged,
        .widgetDeepLinkOpened(type: "job"),
        .widgetDeepLinkOpened(type: "onmyway"),
    ]

    static func catalogParity() {
        guard let catalog = NativeAnalyticsEventCatalog.standard else {
            expect(false, "catalog: the embedded §9.5 fixture parses")
            return
        }
        expectEqual(catalog.events.count, 52, "catalog: 52 events")
        expectEqual(Set(everyEvent.map(\.name)), Set(catalog.events.keys),
                    "catalog: a typed constructor exists for every event name, and no other name")

        var covered: [String: Set<Int>] = [:]
        for event in everyEvent {
            let evaluation = NativeAnalyticsPrivacyPolicy.standard.evaluate(event: event.name, properties: event.properties)
            expectEqual(evaluation.decision, .send(event: event.name, properties: event.properties),
                        "catalog: \(event.name) \(event.properties.keys.sorted()) sends unchanged")
            expect(evaluation.diagnostic == nil, "catalog: \(event.name) has no diagnostic (\(String(describing: evaluation.diagnostic?.issues)))")
            expect(!evaluation.isCatalogViolation, "catalog: \(event.name) is in the catalog")
            for (index, variant) in (catalog.events[event.name] ?? []).enumerated() where matches(event.properties, variant) {
                covered[event.name, default: []].insert(index)
            }
        }
        for (name, variants) in catalog.events {
            expectEqual(covered[name] ?? [], Set(variants.indices), "catalog: every variant of \(name) is built by a constructor")
        }

        // Values the constructors normalize (§9.5 enums, typed numbers).
        expectEqual(NativeAnalyticsEvent.paymentRecorded(amount: 50, method: "Cheque", balanceRemaining: 25.5).properties,
                    ["amount": 50, "method": "check", "balanceRemaining": 25.5], "payment_recorded: cheque → check, numbers")
        expectEqual(NativeAnalyticsEvent.paymentVoided(amount: 50, method: "Venmo").properties["method"], "other",
                    "payment_voided: an unlisted method is other")
        expectEqual(NativeAnalyticsEvent.changeOrderCreated(amount: Decimal(string: "125.50")!).properties["amount"], .number(125.5),
                    "change_order_created: the Decimal amount is a number")
        expectEqual(NativeAnalyticsEvent.jobCreated(first: false, customerID: "", duplicated: false).properties, ["first": false],
                    "job_created: optional keys are omitted, not sent empty or false")
        expectEqual(NativeAnalyticsEvent.taxSettingsSaved(hasIncomeRate: false, vehicleMethod: nil).properties["vehicleMethod"], "unset",
                    "tax_settings_saved: no vehicle method is unset")
        expectEqual(NativeAnalyticsEvent.setupChecklistDismissed(doneCount: 3).properties["doneCount"], .number(3),
                    "handoff: doneCount is a number")
        expectEqual(NativeAnalyticsEvent.insightSnoozed(.dueSoon, insightID: "x", days: 7).properties["days"], .number(7),
                    "handoff: days is a number")
        expectEqual(NativeAnalyticsEvent.insightShown(kinds: [.dueSoon], ids: ["a"]).properties,
                    ["kinds": ["due_soon"], "ids": ["a"]], "handoff: kinds and ids are string arrays")
    }

    static func matches(_ properties: [String: NativeAnalyticsValue], _ variant: NativeAnalyticsEventCatalog.Variant) -> Bool {
        for (key, value) in properties {
            guard let spec = variant[key], NativeAnalyticsPrivacyPolicy.rejection(of: value, for: spec.type) == nil else { return false }
        }
        return variant.allSatisfy { $0.value.isOptional || properties[$0.key] != nil }
    }

    // MARK: 2. m2: variant selection keeps the literal discriminator

    static func variantSelectionM2() {
        let policy = NativeAnalyticsPrivacyPolicy.standard
        let auto = NativeAnalyticsEvent.invoiceCreatedOnCompletion(usedTrackedTime: true, autoEmailQueued: true)
        expectEqual(policy.evaluate(event: auto.name, properties: auto.properties).decision,
                    .send(event: "invoice_created", properties: ["source": "auto_on_complete", "usedTrackedTime": true, "autoEmailQueued": true]),
                    "m2: auto_on_complete keeps source and both flags")
        // A manual invoice carrying the auto variant's flags: before m2 the
        // auto variant kept two keys to manual's one and won, so the event
        // went out with no `source` at all.
        let stray = policy.evaluate(event: "invoice_created",
                                    properties: ["source": "manual", "usedTrackedTime": true, "autoEmailQueued": false])
        expectEqual(stray.decision, .send(event: "invoice_created", properties: ["source": "manual"]),
                    "m2: the matching literal variant wins over a variant keeping more incidental keys")
        expectEqual(stray.diagnostic?.issues, [
            .init(key: "autoEmailQueued", reason: .personalDataKey), .init(key: "usedTrackedTime", reason: .unknownKey),
        ], "m2: the stray keys are diagnosed (the key classifier reads `Email` as personal data)")
        let fromJob = policy.evaluate(event: "invoice_created", properties: ["source": "from_job", "mode": "finalize", "autoEmailQueued": false])
        expectEqual(fromJob.decision, .send(event: "invoice_created", properties: ["source": "from_job", "mode": "finalize"]),
                    "m2: from_job keeps source and mode")
        let failed = policy.evaluate(event: "receipt_scanned", properties: ["outcome": "failed", "route": "backend"])
        expectEqual(failed.decision, .send(event: "receipt_scanned", properties: ["outcome": "failed"]),
                    "m2: receipt_scanned{outcome: failed} keeps the failed literal")
        let filled = policy.evaluate(event: "receipt_scanned", properties: ["outcome": "filled", "route": "user_key"])
        expectEqual(filled.decision, .send(event: "receipt_scanned", properties: ["outcome": "filled", "route": "user_key"]),
                    "m2: filled selects the route variant")
        guard let variants = NativeAnalyticsEventCatalog.standard?.events["invoice_created"] else { return expect(false, "m2: catalog") }
        let scores = variants.map { NativeAnalyticsPrivacyPolicy.discriminatorScore(["source": "manual"], against: $0) }
        expectEqual(scores.sorted(), [-1, -1, 1], "m2: exactly one invoice_created variant matches source=manual")
        expectEqual(NativeAnalyticsPrivacyPolicy.discriminatorScore(["count": 2], against: ["count": .init(type: .number, isOptional: false)]), 0,
                    "m2: variants without literal keys score 0")
    }

    // MARK: 3. m3: logged names never echo a secret

    static func sanitizedNameM3() {
        let redacted = "<redacted>"
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("invoice_created"), "invoice_created", "m3: a catalog name is kept")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("$screen"), "$screen", "m3: an SDK name is kept")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("phc_TESTKEYnotreal"), redacted, "m3: a PostHog-key-shaped name is redacted")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("sk_live_abc123"), redacted, "m3: a Stripe-key-shaped name is redacted")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("AIzaSyD_fake"), redacted, "m3: a Google-key-shaped name is redacted")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("eyJhbGciOi"), redacted, "m3: a JWT header segment is redacted")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("call_4805551234"), redacted, "m3: a phone-length digit run is redacted")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("event_123456"), "event_123456", "m3: a 6-digit run is kept")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName("owner@example.com"), redacted, "m3: an email is redacted")

        // End to end: an unknown secret-shaped event is dropped, and neither
        // the diagnostic nor the Debug catalog-violation message echoes it.
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        transport(adapter, recorder).track("sk_live_51Hsecret", ["k": "v"])
        expectEqual(adapter.calls, [], "m3: the unknown event is dropped")
        let logged = recorder.diagnostics.map(\.message) + recorder.violations
        expect(!logged.isEmpty && logged.allSatisfy { !$0.contains("sk_live") && !$0.contains("51Hsecret") },
               "m3: no diagnostic or violation message echoes the secret-shaped name")
    }

    // MARK: 4. The identity lifecycle policy (§9.4)

    static func identityLifecycle() {
        var lifecycle = NativeAnalyticsIdentityLifecycle()
        expectEqual(lifecycle.verified("user-a"), [.identify("user-a")], "identity: first verification identifies")
        expectEqual(lifecycle.verified("user-a"), [], "identity: the same id again is a no-op")
        expectEqual(lifecycle.verified(""), [], "identity: an empty id is never identified")
        expectEqual(lifecycle.verified("user-b"), [.reset, .identify("user-b")],
                    "identity: a different verified id resets before identifying")
        expectEqual(lifecycle.boundary(), [.reset], "identity: a boundary resets")
        expectEqual(lifecycle.boundary(), [], "identity: back-to-back boundaries reset once")
        expectEqual(lifecycle.identifiedUserID, nil, "identity: a boundary forgets the id")
        expectEqual(lifecycle.verified("user-b"), [.identify("user-b")], "identity: after a boundary, identify without another reset")
        expectEqual(lifecycle.boundary(), [.reset], "identity: a boundary after an identify resets again")
    }

    // MARK: 5. Gate-driven events and root screens

    static func gatePolicy() {
        let draft0 = NativeOnboardingDocument.Draft(businessName: "", contactName: "", trade: .plumbing, step: 0)
        var draft1 = draft0
        draft1.step = 1
        let paywall = NativeAuthenticationGateState.paywall(offering: nil, message: nil)

        var out = NativeAnalyticsGatePolicy.transition(from: .loading, to: .onboarding(draft0), paywallTracked: false)
        expectEqual(out.events, [.onboardingStepViewed(.welcome)], "gate: entering onboarding views welcome")
        expectEqual(out.screen, .onboarding, "gate: onboarding root screen")
        out = NativeAnalyticsGatePolicy.transition(from: .onboarding(draft0), to: .onboarding(draft1), paywallTracked: false)
        expectEqual(out.events, [.onboardingStepViewed(.business)], "gate: step 1 views business")
        expectEqual(out.screen, nil, "gate: a step change is not a new root screen")
        out = NativeAnalyticsGatePolicy.transition(from: .onboarding(draft1), to: .onboarding(draft1), paywallTracked: false)
        expectEqual(out.events, [], "gate: republishing the same step is silent")
        out = NativeAnalyticsGatePolicy.transition(from: .onboarding(draft1), to: paywall, paywallTracked: false)
        expectEqual(out.events, [.subscriptionPaywallShown(.onboardingGate)], "gate: the paywall fires onboarding_gate")
        expectEqual(out.screen, .paywall, "gate: paywall root screen")
        expect(out.paywallTracked, "gate: the paywall presentation is marked tracked")
        out = NativeAnalyticsGatePolicy.transition(from: paywall, to: .subscriptionLoading, paywallTracked: true)
        expect(out.paywallTracked && out.events.isEmpty, "gate: a purchase/retry load keeps the paywall mark")
        out = NativeAnalyticsGatePolicy.transition(from: .subscriptionLoading, to: paywall, paywallTracked: true)
        expectEqual(out.events, [], "gate: returning to the same paywall does not fire again")
        out = NativeAnalyticsGatePolicy.transition(from: paywall, to: .startingPoint(.plumbing), paywallTracked: true)
        expectEqual(out.events, [.onboardingStepViewed(.startingPoint)], "gate: starting point views starting_point")
        expectEqual(out.screen, .startingPoint, "gate: starting point root screen")
        expect(!out.paywallTracked, "gate: leaving the paywall clears the mark")
        out = NativeAnalyticsGatePolicy.transition(from: .signedIn(email: nil), to: .signedOut, paywallTracked: false)
        expectEqual(out.screen, .auth, "gate: signed out shows Auth")
        out = NativeAnalyticsGatePolicy.transition(from: .signedOut, to: .signedIn(email: nil), paywallTracked: false)
        expect(out.screen == nil && out.events.isEmpty, "gate: signed-in screens come from the tab views")
    }

    // MARK: 6. $screen names are RN route names (§9.3)

    static func screenNames(root: URL) {
        let app = (try? String(contentsOf: root.appending(path: "App.tsx"), encoding: .utf8)) ?? ""
        expect(!app.isEmpty, "screens: App.tsx is readable")
        let named = NativeAnalyticsScreen.allCases.compactMap(\.routeName)
        expectEqual(named.count, Set(named).count, "screens: route names are unique")
        for name in named {
            expect(app.contains("name=\"\(name)\""), "screens: \(name) is an RN route name in App.tsx")
            expect(NativeAnalyticsPrivacyPolicy.screenNameRejection(name) == nil, "screens: \(name) passes the screen-name policy")
        }
        expectEqual(NativeAnalyticsScreen.today.routeName, "TodayHome", "screens: Today sends its leaf route")
        expectEqual(NativeAnalyticsScreen.invoiceList.routeName, "InvoiceList", "screens: Invoices sends its leaf route")
        expectEqual(NativeAnalyticsScreen.expenseEditor.routeName, nil, "screens: an RN modal with no route sends nothing")
    }

    // MARK: 7. The real AppStore: sign-in → work → sign-out

    @MainActor
    static func signInWorkSignOutJourney() async {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "journey")
        defer { try? FileManager.default.removeItem(at: directory) }

        store.testSetAuthenticationGateState(.signedOut)
        store.testFinishInteractiveSignIn(subject: "user-a", binding: hexBinding("a1"), email: "a@example.com", method: .password)
        store.trackScreen(.today)

        var customer = Customer()
        customer.name = "Pat Owner"
        customer.phone = "4805550100"
        expect(store.upsert(customer), "journey: customer saved")
        customer.notes = "edited"
        expect(store.upsert(customer), "journey: customer edited")
        var second = Customer()
        second.name = "Sam Second"
        expect(store.upsert(second), "journey: second customer saved")

        var job = Job()
        job.customerId = customer.id
        job.customerName = customer.name
        job.title = "Panel swap"
        job.status = .scheduled
        expect(store.upsert(job), "journey: job saved")
        expect(store.advanceJobLifecycle(id: job.id, from: .scheduled), "journey: job advanced")
        expect(store.clockIn(jobID: job.id), "journey: clocked in")

        var expense = Expense()
        expense.merchant = "Depot"
        expense.amount = 42
        expense.category = .tools
        expense.jobId = job.id
        if case .failure(let refusal) = store.commitExpenseEdit(id: nil, opened: nil, draft: expense) {
            expect(false, "journey: expense saved (\(refusal))")
        }

        var invoice = Invoice()
        invoice.customerId = customer.id
        invoice.customer = customer.name
        invoice.number = "INV-1001"
        invoice.amount = 100
        store.upsert(invoice)
        var payment = Payment()
        payment.amount = 40
        payment.method = "Cash"
        if case .failure = store.recordPayment(invoiceID: invoice.id, payment: payment) { expect(false, "journey: payment recorded") }
        if case .failure = store.recordPayment(invoiceID: invoice.id, payment: payment) { expect(false, "journey: retried payment is idempotent") }
        if case .failure = store.voidPayment(invoiceID: invoice.id, paymentID: payment.id) { expect(false, "journey: payment voided") }
        if case .failure = store.settleInvoice(invoiceID: invoice.id, paymentID: "settle-1") { expect(false, "journey: invoice settled") }

        store.testApplyCompletedSignOutState()

        expectEqual(adapter.calls, [
            .screen("Auth"),
            .identify("user-a"),
            .capture("sign_in", ["method": "password"]),
            .screen("TodayHome"),
            .capture("customer_created", ["first": true]),
            .capture("customer_created", ["first": false]),
            .capture("job_created", ["first": true, "customerId": .string(customer.id)]),
            .capture("job_status_changed", ["from": "scheduled", "to": "in_progress"]),
            .capture("time_tracking_started", ["jobId": .string(job.id)]),
            .capture("expense_logged", ["category": "tools", "linkedToJob": true]),
            .capture("payment_recorded", ["amount": 40, "method": "cash", "balanceRemaining": 60]),
            .capture("payment_voided", ["amount": 40, "method": "cash"]),
            .capture("payment_recorded", ["amount": 100, "method": "other", "balanceRemaining": 0]),
            .capture("invoice_paid", ["amount": 100]),
            .reset,
            .screen("Auth"),
        ], "journey: the exact ordered sequence that leaves the process")
        expect(recorder.diagnostics.isEmpty, "journey: nothing was stripped (\(recorder.diagnostics.map(\.message)))")
        expect(recorder.violations.isEmpty, "journey: every event is in the catalog")
        let identifyIndex = adapter.calls.firstIndex(of: .identify("user-a")) ?? .max
        let firstCapture = adapter.calls.firstIndex { if case .capture = $0 { true } else { false } } ?? -1
        expect(identifyIndex < firstCapture, "journey: identify precedes the owner's first event")
    }

    // MARK: 8. Account switch and deletion boundaries

    @MainActor
    static func accountSwitchAndDeletion(root: URL) async {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "switch")
        defer { try? FileManager.default.removeItem(at: directory) }

        store.testFinishInteractiveSignIn(subject: "user-a", binding: hexBinding("a2"), email: "a@example.com", method: .apple)
        var customer = Customer()
        customer.name = "Owner A customer"
        _ = store.upsert(customer)
        store.scheduleBookingTestSeedIdentityActivator()
        await store.useAnotherAccount(clearGoogleCredential: {})
        store.testFinishInteractiveSignIn(subject: "user-b", binding: hexBinding("b2"), email: "b@example.com", method: .google)
        var other = Customer()
        other.name = "Owner B customer"
        _ = store.upsert(other)

        expectEqual(adapter.calls, [
            .identify("user-a"),
            .capture("sign_in", ["method": "apple"]),
            .capture("customer_created", ["first": true]),
            .reset,
            .screen("Auth"),
            .identify("user-b"),
            .capture("sign_in", ["method": "google"]),
            .capture("customer_created", ["first": false]),
        ], "switch: reset runs before any event from the next owner")

        // A verified id change with no boundary in between (a background
        // activation for another owner) still resets before identifying.
        adapter.calls.removeAll()
        store.testFinishInteractiveSignIn(subject: "user-c", binding: hexBinding("c2"), email: "c@example.com", method: .password)
        expectEqual(adapter.calls, [.reset, .identify("user-c"), .capture("sign_in", ["method": "password"])],
                    "switch: a different verified id resets first")

        // Deletion: the server-confirmed boundary resets once; the sign-out
        // teardown that follows does not reset a second time.
        adapter.calls.removeAll()
        store.testApplyAccountDeletionAnalyticsBoundary()
        store.testApplyCompletedSignOutState()
        expectEqual(adapter.calls, [.reset, .screen("Auth")], "deletion: exactly one reset, then the Auth screen")
        store.testFinishInteractiveSignIn(subject: "user-d", binding: hexBinding("d2"), email: "d@example.com", method: .password)
        expectEqual(Array(adapter.calls.suffix(2)), [.identify("user-d"), .capture("sign_in", ["method": "password"])],
                    "deletion: the next owner is identified without inheriting the deleted id")

        // `deleteAccount` needs the network and Keychain; pin where its
        // boundary sits instead: after the server call, before the local
        // scrub, the RevenueCat logout await and the teardown.
        let source = (try? String(contentsOf: root.appending(path: "native/TradeReadyNative/AppStore.swift"), encoding: .utf8)) ?? ""
        if let start = source.range(of: "    func deleteAccount() async throws {"),
           let end = source.range(of: "    func retryAccountScrub()", range: start.upperBound..<source.endIndex) {
            let body = String(source[start.upperBound..<end.lowerBound])
            func offset(_ needle: String) -> Int {
                body.range(of: needle).map { body.distance(from: body.startIndex, to: $0.lowerBound) } ?? -1
            }
            let serverDelete = offset("try await client.deleteAccount(")
            let boundary = offset("applyAnalyticsIdentityBoundary()")
            let scrub = offset("try performLocalAccountScrub(")
            let logOut = offset("await subscriptionService.logOut()")
            expect(serverDelete >= 0 && boundary > serverDelete, "deletion source: the reset follows the server deletion")
            expect(boundary >= 0 && boundary < scrub && boundary < logOut, "deletion source: the reset precedes the scrub and logout")
            expect(offset("applyCompletedSignOutState()") > logOut, "deletion source: the teardown still runs after logout")
        } else {
            expect(false, "deletion source: deleteAccount is present")
        }
        expect(recorder.diagnostics.isEmpty && recorder.violations.isEmpty, "switch: nothing stripped or outside the catalog")
    }

    // MARK: 9. Contextual events (sources, opens, composer events)

    @MainActor
    static func contextualEvents() {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "context")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.testFinishInteractiveSignIn(subject: "user-ctx", binding: hexBinding("c3"), email: "ctx@example.com", method: .password)

        var customer = Customer()
        customer.name = "Nora Client"
        customer.phone = "4805550111"
        customer.email = "nora@example.com"
        _ = store.upsert(customer)
        var lead = Job()
        lead.customerId = customer.id
        lead.customerName = customer.name
        lead.title = "Estimate"
        lead.status = .estimateSent
        _ = store.upsert(lead)
        var invoice = Invoice()
        invoice.customerId = customer.id
        invoice.customer = customer.name
        invoice.number = "INV-2001"
        invoice.amount = 300
        invoice.due = Date().addingTimeInterval(-10 * 86_400)
        store.upsert(invoice)
        adapter.calls.removeAll()

        // Estimate follow-up: the open carries its source and the send reuses it.
        store.requestEstimateFollowUpReview(jobID: lead.id, source: .jobDetail)
        store.recordEstimateFollowUpSent(channel: .email)
        store.requestEstimateFollowUpReview(jobID: lead.id)
        store.recordEstimateFollowUpSent(channel: .sms)
        store.requestEstimateFollowUpReview(jobID: "missing-job", source: .jobDetail)

        // Review request: the source set at open is carried into the send;
        // a notification open restores the RN default.
        store.requestReviewRequestReview(jobID: lead.id, source: .jobDetail)
        store.markReviewRequestSent(jobID: lead.id, fallback: nil, channel: .email)
        store.requestReviewRequestReview(jobID: lead.id)
        store.markReviewRequestSent(jobID: lead.id, fallback: nil, channel: .sms)

        // Overdue outreach opens only from the outreach notification route.
        store.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: true, daysPastDue: 10)
        store.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: false, daysPastDue: 1)
        // M7: a payload without daysPastDue still sends, with no key (RN
        // sends `{ daysPastDue: undefined }`).
        store.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: true)

        // Appointment confirmation: notification taps only.
        store.requestAppointmentConfirmationReview(jobID: lead.id)
        store.requestAppointmentConfirmationReview(jobID: lead.id, fromNotification: false)

        // Composer-opened events and the explicit payment link.
        store.recordAppointmentComposerOpened(onMyWay: true)
        store.recordAppointmentComposerOpened(onMyWay: false)
        // M6: the view reports the finished chain; the channel mapping and
        // count semantics live in `bulkInvoiceReminderRun`. RN tracks a
        // started run even when it opened no composer (count 0).
        store.recordBulkInvoiceReminderRunCompleted(channel: .email, presentedCount: 2)
        store.recordBulkInvoiceReminderRunCompleted(channel: .text, presentedCount: 0)
        store.recordPaymentLinkSent(provider: .stripe, deposit: false)
        store.recordReceiptScan(nil, state: .failed)

        expectEqual(adapter.calls, [
            .capture("estimate_follow_up_opened", ["source": "job_detail"]),
            .capture("estimate_follow_up_sent", ["channel": "email", "source": "job_detail"]),
            .capture("estimate_follow_up_opened", ["source": "notification"]),
            .capture("estimate_follow_up_sent", ["channel": "sms", "source": "notification"]),
            .capture("review_request_sent", ["channel": "email", "source": "job_detail"]),
            .capture("review_request_sent", ["channel": "sms", "source": "notification"]),
            .capture("overdue_outreach_opened", ["daysPastDue": 10]),
            .capture("overdue_outreach_opened", [:]),
            .capture("appointment_confirm_opened", [:]),
            .capture("on_my_way_sent", [:]),
            .capture("appointment_confirm_sent", [:]),
            .capture("bulk_invoice_reminders", ["channel": "email", "count": 2]),
            .capture("bulk_invoice_reminders", ["channel": "text", "count": 0]),
            .capture("payment_link_sent", ["provider": "stripe", "deposit": false]),
            .capture("receipt_scanned", ["outcome": "failed"]),
        ], "context: sources, guarded opens and composer events")
        expect(recorder.diagnostics.isEmpty, "context: nothing stripped (\(recorder.diagnostics.map(\.message)))")
    }

    // MARK: 11. Pull-to-refresh and the owner guard (M4)

    @MainActor
    static func pullToRefreshOwnerGuard() async {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.testFinishInteractiveSignIn(subject: "user-r", binding: hexBinding("e1"), email: "r@example.com", method: .password)
        adapter.calls.removeAll()

        // The real entry point: with no sync configured the sync returns
        // nil, and the event still fires after it (RN: whatever the result).
        await store.performPullToRefresh(screen: .jobs)
        await store.performPullToRefresh(screen: .money)
        await store.performPullToRefresh()
        expectEqual(adapter.calls, [
            .capture("pull_to_refresh", ["screen": "JobsScreen"]),
            .capture("pull_to_refresh", ["screen": "MoneyScreen"]),
        ], "refresh: Jobs and Money send after the sync; an untagged refresh sends nothing")

        // Unchanged owner through the injected sync: sends.
        adapter.calls.removeAll()
        await store.testPerformPullToRefresh(screen: .jobs) {}
        expectEqual(adapter.calls, [.capture("pull_to_refresh", ["screen": "JobsScreen"])],
                    "refresh: an unchanged owner sends after the sync")

        // Sign-out while the sync is suspended: dropped.
        adapter.calls.removeAll()
        await store.testPerformPullToRefresh(screen: .jobs) {
            store.testApplyCompletedSignOutState()
        }
        expectEqual(adapter.calls, [.reset, .screen("Auth")], "refresh: a sign-out during the sync drops the event")

        // Owner switch while the sync is suspended: dropped, so nothing is
        // attributed to the next owner.
        store.testFinishInteractiveSignIn(subject: "user-r", binding: hexBinding("e1"), email: "r@example.com", method: .password)
        adapter.calls.removeAll()
        await store.testPerformPullToRefresh(screen: .money) {
            store.testApplyCompletedSignOutState()
            store.testFinishInteractiveSignIn(subject: "user-s", binding: hexBinding("e2"), email: "s@example.com", method: .password)
        }
        expectEqual(adapter.calls, [
            .reset,
            .screen("Auth"),
            .identify("user-s"),
            .capture("sign_in", ["method": "password"]),
        ], "refresh: an owner switch during the sync never sends pull_to_refresh under the next owner")
        expect(recorder.diagnostics.isEmpty, "refresh: nothing stripped")
    }

    // MARK: 12. Identify, then a landing on .accountMismatch (M4)

    @MainActor
    static func signInLandingOnAccountMismatch() {
        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "mismatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.testSetAuthenticationGateState(.signedOut)
        adapter.calls.removeAll()

        store.testFinishInteractiveSignIn(
            subject: "user-b", binding: hexBinding("b9"), email: "b@example.com", method: .google,
            landingGate: .accountMismatch
        )
        expect(store.authenticationGateState == .accountMismatch, "mismatch: the sign-in landed on .accountMismatch")
        expectEqual(adapter.calls, [.identify("user-b"), .capture("sign_in", ["method": "google"])],
                    "mismatch: after identify, sign_in is the only event under B (no screen, onboarding or paywall event)")

        // Leaving the mismatch by signing out resets before anything else.
        adapter.calls.removeAll()
        store.testApplyCompletedSignOutState()
        expectEqual(adapter.calls, [.reset, .screen("Auth")], "mismatch: signing out of the mismatch resets, then Auth")
        expect(recorder.diagnostics.isEmpty && recorder.violations.isEmpty, "mismatch: nothing stripped")
    }

    // MARK: 13. $screen appearances: returns and repeat visits (I1)

    /// One destination view as SwiftUI drives it: the real appearance rule
    /// the screen modifier holds, forwarding to the real store.
    @MainActor
    struct SimulatedDestination {
        let destination: NativeAnalyticsScreen
        let store: AppStore
        var appearance = NativeAnalyticsScreenAppearance()

        mutating func onAppear() { if appearance.appear() { store.trackScreen(destination) } }
        mutating func onDisappear() { appearance.disappear() }
    }

    @MainActor
    static func screenAppearances(root: URL) {
        var appearance = NativeAnalyticsScreenAppearance()
        expect(appearance.appear(), "appearance: the first onAppear is an appearance")
        expect(!appearance.appear(), "appearance: a duplicate onAppear in the same appearance is dropped")
        appearance.disappear()
        expect(appearance.appear(), "appearance: onAppear after onDisappear is a new appearance")

        let adapter = FakeSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "screens")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.testFinishInteractiveSignIn(subject: "user-v", binding: hexBinding("f1"), email: "v@example.com", method: .password)

        // JobList -> JobDetail(A) -> back -> JobDetail(B): RN sends all four.
        adapter.calls.removeAll()
        var list = SimulatedDestination(destination: .jobList, store: store)
        list.onAppear()
        list.onAppear() // SwiftUI's duplicate onAppear for the same appearance
        list.onDisappear() // push
        var detailA = SimulatedDestination(destination: .jobDetail, store: store)
        detailA.onAppear()
        detailA.onDisappear() // pop
        list.onAppear()
        list.onDisappear() // push
        var detailB = SimulatedDestination(destination: .jobDetail, store: store)
        detailB.onAppear()
        expectEqual(adapter.calls, [.screen("JobList"), .screen("JobDetail"), .screen("JobList"), .screen("JobDetail")],
                    "screens: list -> detail -> back -> detail sends every step, like RN")

        // A repeat visit of the same pushed page re-sends both the page and
        // the root it returns to.
        adapter.calls.removeAll()
        var settings = SimulatedDestination(destination: .settings, store: store)
        settings.onAppear()
        settings.onDisappear()
        var business = SimulatedDestination(destination: .settingsBusiness, store: store)
        business.onAppear()
        business.onDisappear()
        settings.onAppear()
        settings.onDisappear()
        var businessAgain = SimulatedDestination(destination: .settingsBusiness, store: store)
        businessAgain.onAppear()
        expectEqual(adapter.calls, [
            .screen("Settings"), .screen("SettingsBusiness"), .screen("Settings"), .screen("SettingsBusiness"),
        ], "screens: a repeat visit re-sends")

        // The store no longer dedupes: two calls send twice.
        adapter.calls.removeAll()
        store.trackScreen(.customerDetail)
        store.trackScreen(.customerDetail)
        expectEqual(adapter.calls, [.screen("CustomerDetail"), .screen("CustomerDetail")],
                    "screens: trackScreen sends every call (the only dedupe is per appearance)")

        // Source: every tab root and Settings attach the modifier to the
        // stack's root content (so onAppear re-fires on a pop), never to the
        // NavigationStack itself.
        let views = root.appending(path: "native/TradeReadyNative")
        func source(_ file: String) -> String {
            (try? String(contentsOf: views.appending(path: file), encoding: .utf8)) ?? ""
        }
        for (file, screen) in [
            ("TodayView.swift", "today"), ("JobsView.swift", "jobList"), ("InvoicesView.swift", "invoiceList"),
            ("CustomersView.swift", "customerList"), ("MoneyView.swift", "money"), ("CoachView.swift", "coach"),
            ("SettingsView.swift", "settings"),
        ] {
            let text = source(file)
            expect(text.contains("            .nativeAnalyticsScreen(.\(screen))\n        }\n"),
                   "screens: \(file) attaches .\(screen) inside its NavigationStack")
            expect(!text.contains("        }\n        .nativeAnalyticsScreen(.\(screen))"),
                   "screens: \(file) does not attach .\(screen) to the NavigationStack")
        }

        // Every signed-in destination with an RN route is applied by a view
        // (the gate roots come from the gate transition instead).
        let files = (try? FileManager.default.contentsOfDirectory(atPath: views.path)) ?? []
        let allSource = files.filter { $0.hasSuffix(".swift") }.map(source).joined(separator: "\n")
        let gateRoots: Set<NativeAnalyticsScreen> = [.auth, .onboarding, .paywall, .startingPoint]
        for screen in NativeAnalyticsScreen.allCases where screen.routeName != nil && !gateRoots.contains(screen) {
            expect(allSource.contains(".nativeAnalyticsScreen(.\(screen.rawValue))"),
                   "screens: .\(screen.rawValue) (\(screen.routeName ?? "")) is applied by a view")
        }
        expect(recorder.diagnostics.isEmpty, "screens: nothing stripped")
    }

    // MARK: 10. A throwing transport never affects a commit

    @MainActor
    static func throwingTransportDoesNotAffectCommits() {
        let adapter = ThrowingSDKAdapter()
        let recorder = Recorder()
        let (store, directory) = makeStore(transport(adapter, recorder), tag: "throwing")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.testFinishInteractiveSignIn(subject: "user-t", binding: hexBinding("f4"), email: "t@example.com", method: .password)
        var customer = Customer()
        customer.name = "Durable Customer"
        expect(store.upsert(customer), "throwing: the customer commit succeeds")
        var job = Job()
        job.customerId = customer.id
        job.customerName = customer.name
        job.title = "Durable job"
        job.status = .scheduled
        expect(store.upsert(job), "throwing: the job commit succeeds")
        expect(store.advanceJobLifecycle(id: job.id, from: .scheduled), "throwing: the lifecycle commit succeeds")
        store.testApplyCompletedSignOutState()
        expect(adapter.attempts >= 6, "throwing: every analytics call reached the throwing adapter (\(adapter.attempts))")
        expect(recorder.diagnostics.allSatisfy { $0.issues.first?.reason == .transportFailure },
               "throwing: each failure is a bounded transportFailure diagnostic")

        let relaunched = AppStore(
            fileURL: directory.appending(path: "store.json"),
            seedIfMissing: false,
            subscriptionService: SubscriptionStub(),
            widgetTimelineReloader: NoopReloader()
        )
        expect(relaunched.customers.contains { $0.id == customer.id }, "throwing: the customer is on disk after relaunch")
        expect(relaunched.jobs.first { $0.id == job.id }?.status == .inProgress,
               "throwing: the advanced job status is on disk after relaunch")
    }
}
