import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Cold and warm deep-link routing with authentication gates (task 11.06,
// requirements L1 and L2).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §6.1 (grammar), §6.2 (gate order, the tagged `pendingOpenUrl` stash,
// parking), §2.5 and C22 (the single owner predicate
// `O = AppStore.derivedStatePublishBinding`), C11 (P8).
//
// Every fixture runs against the REAL code: `NativeDeepLinkRoutingPolicy`,
// `NativeOpenURLDispatch`, `NativeDeepLinkParser`, `NativePendingOpenURLConsumer`
// and `AppStore` (`handle(url:)`, `consumePendingOpenURLStash`, the gate
// didSet, `useAnotherAccount`, `requestEstimateFollowUpReview`). Every App
// Group touch uses a throwaway suite plus a throwaway lock file. Run with
// TZ=America/Phoenix.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

// MARK: - Fixtures

private let bindingA = String(repeating: "a1", count: 32)
private let bindingB = String(repeating: "b2", count: 32)
private let tagA = NativeWidgetOwnerTag.make(binding: bindingA)
private let tagB = NativeWidgetOwnerTag.make(binding: bindingB)

private func iso(_ date: Date) -> String { WidgetSnapshot.isoTimestamp(date) }

private func tempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1106-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func job(_ id: String, _ overrides: [String: Any] = [:]) -> Canonical.Job {
    var fields: [String: Any] = [
        "id": id, "customerId": "c1", "customerName": "Dave Smith", "title": "Job \(id)",
        "description": "", "status": "scheduled", "scheduledDate": "2099-01-01",
        "scheduledStartTime": "10:30", "scheduledEndTime": NSNull(), "address": "1 Main St",
        "estimateTotal": 850, "laborHours": 0, "laborRate": 0, "materials": [], "materialMarkup": 0,
        "overhead": 0, "margin": 0, "notes": "", "invoiceId": NSNull(), "createdAt": "2026-08-01",
        "timeSessions": [],
    ]
    fields.merge(overrides) { _, new in new }
    return try! JSONDecoder().decode(Canonical.Job.self, from: JSONSerialization.data(withJSONObject: fields))
}

private func customer(_ id: String, name: String, phone: String) -> Canonical.Customer {
    let fields: [String: Any] = [
        "id": id, "name": name, "email": "", "phone": phone, "address": "", "notes": "",
    ]
    return try! JSONDecoder().decode(Canonical.Customer.self, from: JSONSerialization.data(withJSONObject: fields))
}

/// The routing workspace: a live job, an archived job, an archived job with a
/// running timer, a finished job, an archived estimate_sent job.
private let archivedAt = "2026-08-02T10:00:00.000Z"
private let fixtureJobs: [Canonical.Job] = [
    job("live"),
    job("archived", ["archivedAt": archivedAt]),
    job("archived-timer", [
        "archivedAt": archivedAt, "status": "in_progress",
        "timeSessions": [["start": "2026-08-03T15:00:00.000Z", "end": NSNull()]],
    ]),
    job("complete", ["status": "complete"]),
    job("paid", ["status": "paid"]),
    job("estimate-archived", ["status": "estimate_sent", "estimateSentAt": "2026-08-01", "archivedAt": archivedAt]),
]

private final class TempSuite {
    let name = "com.tradeready.deep-link.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root = tempDirectory("group")
    var lockFile: URL { root.appendingPathComponent(WidgetAppGroup.lockFileName) }

    init() { defaults = UserDefaults(suiteName: name)! }

    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(suiteName: name, defaults: defaults, lockFile: lockFile)
    }

    var consumer: NativePendingOpenURLConsumer {
        NativePendingOpenURLConsumer(inbox: NativeUserDefaultsAppGroupInbox(defaults: defaults), lockFile: lockFile)
    }

    var stash: String? { defaults.string(forKey: WidgetAppGroup.pendingOpenURLKey) }

    /// `at` defaults to one second ago: `isoTimestamp` rounds to the
    /// millisecond, so a "now" stamp can read back up to 0.5 ms in the
    /// future, which the strict `0 ≤ age` rule rightly calls stale.
    func writeStash(_ url: String, at: Date = Date().addingTimeInterval(-1), tag: String?) {
        // An untagged stash is the RN-era/foreign shape `{url, at}`.
        let raw = tag.map { try! WidgetJSONValue.encodeJSON(WidgetPendingOpenURLStash(url: url, at: iso(at), ownerTag: $0)) }
            ?? #"{"url":"\#(url)","at":"\#(iso(at))"}"#
        defaults.set(raw, forKey: WidgetAppGroup.pendingOpenURLKey)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct Workspace {
    let directory = tempDirectory("store")
    var fileURL: URL { directory.appendingPathComponent("store.json") }
    var claims: URL { directory.appendingPathComponent("WidgetActionClaims", isDirectory: true) }

    func write(jobs: [Canonical.Job], customers: [Canonical.Customer] = []) throws {
        try Canonical.SnapshotRepository(primaryURL: fileURL).save(Canonical.Snapshot(
            payload: Canonical.SnapshotPayload(invoices: [], jobs: jobs, customers: customers)
        ))
    }

    func bind(_ binding: String) throws {
        try NativeOnboardingStore(snapshotURL: fileURL).save(NativeOnboardingDocument(
            accountBinding: binding, stage: .done,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private final class RecordingAnalytics: NativeAnalytics {
    var events: [(String, [String: String])] = []
    // Task 11.08 (m1): only the typed `track` is a requirement now.
    func track(_ event: String, _ properties: [String: NativeAnalyticsValue]) {
        events.append((event, properties.mapValues(\.legacyStringValue)))
    }
    var deepLinkTypes: [String] {
        events.filter { $0.0 == "widget_deep_link_opened" }.compactMap { $0.1["type"] }
    }
}

private struct NoopReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

@MainActor
private final class SubscriptionStub: NativeSubscriptionServing {
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    /// Fix round 1 (M4): runs inside `useAnotherAccount`, between its
    /// `clearSession` and the owner teardown.
    var onLogOut: () -> Void = {}
    func logOut() async { onLogOut() }
}

@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<5 { await Task.yield() }
}

/// One store over a fresh workspace (bound to `binding`) and a fresh suite.
@MainActor
private final class Harness {
    let suite = TempSuite()
    let workspace = Workspace()
    let analytics = RecordingAnalytics()
    let subscription = SubscriptionStub()
    let store: AppStore

    init(bound binding: String = bindingA, jobs: [Canonical.Job] = fixtureJobs,
         customers: [Canonical.Customer] = [customer("c1", name: "Dave Smith", phone: "555-0100")]) throws {
        try workspace.write(jobs: jobs, customers: customers)
        try workspace.bind(binding)
        store = AppStore(
            fileURL: workspace.fileURL,
            seedIfMissing: false,
            widgetActionReplayTransport: NativeWidgetActionClaimTransport(
                queue: NativeUserDefaultsWidgetActionQueue(defaults: suite.defaults),
                claimDirectory: workspace.claims,
                lockFile: suite.lockFile
            ),
            appGroupAccountScrubber: suite.scrubber,
            pendingOpenURLConsumer: suite.consumer,
            subscriptionService: subscription,
            analytics: analytics,
            widgetTimelineReloader: NoopReloader(),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
    }

    func signIn(_ binding: String = bindingA) {
        store.testSeedNativeSignedInOwner(subject: "user-\(binding.prefix(2))", binding: binding)
    }

    /// Re-binds the SAME workspace to another owner (B has a same-id `live`).
    func rebind(_ binding: String) throws { try workspace.bind(binding) }

    var noRoute: Bool {
        store.deepLinkedJobID == nil && store.pendingOnMyWayJobID == nil && store.selectedTab == .today
    }

    func resetRoute() {
        store.deepLinkedJobID = nil
        if let id = store.pendingOnMyWayJobID { store.dismissPendingOnMyWay(jobID: id) }
        store.selectedTab = .today
        store.dismissDeepLinkUnavailableNotice()
    }

    func cleanUp() { suite.cleanUp(); workspace.cleanUp() }
}

private let now = Date()
private func candidate(
    _ route: NativeDeepLinkParser.Route, _ source: NativeDeepLinkSource,
    tag: String? = nil, arrival: String? = nil, age: TimeInterval = 0
) -> NativeDeepLinkCandidate {
    NativeDeepLinkCandidate(route: route, source: source, ownerTag: tag, arrivalBinding: arrival,
                            at: now.addingTimeInterval(-age))
}

private let liveRecord = NativeDeepLinkRecord(isArchived: false, status: "scheduled", hasRunningTimer: false)

// MARK: - 1. The pure policy matrix

private func testPolicyMatrix() {
    func decide(_ c: NativeDeepLinkCandidate, _ phase: NativeDeepLinkGatePhase = .signedIn,
                owner: String? = bindingA, record: NativeDeepLinkRecord? = liveRecord) -> NativeDeepLinkDecision {
        NativeDeepLinkRoutingPolicy.decide(c, phase: phase, ownerBinding: owner, now: now, record: { _ in record })
    }
    for route in [NativeDeepLinkParser.Route.job(id: "j1"), .onMyWay(id: "j1")] {
        let name = "\(route)"
        // Authenticate, else park (both sources).
        for source in [NativeDeepLinkSource.warmURL, .coldStash] {
            let c = candidate(route, source, tag: tagA)
            expectEqual(decide(c, .pending), .park, "\(name) \(source): a pending gate parks")
            expectEqual(decide(c, .closed), .park, "\(name) \(source): a closed gate parks (discard is on ENTERING it)")
            expectEqual(decide(c, .pending, owner: nil), .park, "\(name) \(source): parking needs no owner yet")
            expectEqual(decide(c, owner: nil), .discard(.noExactOwner), "\(name) \(source): signed in without O fails closed")
            expectEqual(decide(c, owner: ""), .discard(.noExactOwner), "\(name) \(source): an empty O fails closed")
            expectEqual(decide(candidate(route, source, tag: tagA, age: 301), .pending), .discard(.stale),
                        "\(name) \(source): freshness is checked before parking")
            expectEqual(decide(candidate(route, source, tag: tagA, age: -1)), .discard(.stale),
                        "\(name) \(source): a future stamp is stale")
            expectEqual(decide(candidate(route, source, tag: tagA, age: 300)), .apply(route),
                        "\(name) \(source): exactly 300 s is still fresh")
        }
        // Cold stash: the tag is the owner proof.
        expectEqual(decide(candidate(route, .coldStash, tag: tagA)), .apply(route), "\(name) cold: tag == hash(O) routes")
        expectEqual(decide(candidate(route, .coldStash, tag: tagB)), .discard(.ownerMismatch), "\(name) cold: another owner's tag")
        expectEqual(decide(candidate(route, .coldStash, tag: nil)), .discard(.ownerMismatch), "\(name) cold: an untagged stash")
        expectEqual(decide(candidate(route, .coldStash, tag: tagA.uppercased())), .discard(.ownerMismatch),
                    "\(name) cold: tags compare exactly")
        // Warm URL: arrival binding nil or O; a carried stash tag must match.
        expectEqual(decide(candidate(route, .warmURL)), .apply(route), "\(name) warm: nil arrival routes for the current owner")
        expectEqual(decide(candidate(route, .warmURL, arrival: bindingA)), .apply(route), "\(name) warm: arrival == O routes")
        expectEqual(decide(candidate(route, .warmURL, arrival: bindingB)), .discard(.ownerMismatch),
                    "\(name) warm: arrived under B, applied under A")
        expectEqual(decide(candidate(route, .warmURL, tag: tagB, arrival: bindingA)), .discard(.ownerMismatch),
                    "\(name) warm: a carried stash tag for another owner")
        expectEqual(decide(candidate(route, .warmURL, tag: tagA, arrival: bindingA)), .apply(route),
                    "\(name) warm: a carried matching stash tag routes")
        // Record, in the current owner's data.
        expectEqual(decide(candidate(route, .warmURL, arrival: bindingA), record: nil), .discard(.missingRecord),
                    "\(name): a missing job for a link that arrived under O")
        expectEqual(decide(candidate(route, .coldStash, tag: tagA), record: nil), .discard(.missingRecord),
                    "\(name): a missing job for O's own tagged stash")
        expectEqual(decide(candidate(route, .warmURL), record: nil), .discard(.missingRecordUnownedArrival),
                    "\(name): a missing job for a link that arrived with no owner (M1)")
        expectEqual(decide(candidate(route, .warmURL), record: .init(isArchived: true, status: "scheduled", hasRunningTimer: false)),
                    .discard(.archivedRecord), "\(name): an archived job")
        // The owner is checked BEFORE the record: another owner's link never learns whether a record exists.
        expectEqual(decide(candidate(route, .coldStash, tag: tagB), record: nil), .discard(.ownerMismatch),
                    "\(name): owner is gated before the record lookup")
    }
    let timer = NativeDeepLinkRecord(isArchived: true, status: "in_progress", hasRunningTimer: true)
    expectEqual(decide(candidate(.job(id: "j1"), .warmURL), record: timer), .apply(.job(id: "j1")),
                "job: an archived job with a running timer routes (Job Timer widget, recorded native difference)")
    expectEqual(decide(candidate(.onMyWay(id: "j1"), .warmURL), record: timer), .discard(.archivedRecord),
                "onmyway: never gets the running-timer exception")
    for status in ["complete", "invoiced", "paid", "declined"] {
        let done = NativeDeepLinkRecord(isArchived: false, status: status, hasRunningTimer: false)
        expectEqual(decide(candidate(.onMyWay(id: "j1"), .warmURL), record: done), .discard(.finishedRecord),
                    "onmyway refuses DONE_STATUSES: \(status)")
        expectEqual(decide(candidate(.job(id: "j1"), .warmURL), record: done), .apply(.job(id: "j1")),
                    "job routes on any non-archived status: \(status)")
    }
    for status in ["scheduled", "in_progress", "estimate_sent", "approved"] {
        let open = NativeDeepLinkRecord(isArchived: false, status: status, hasRunningTimer: false)
        expectEqual(decide(candidate(.onMyWay(id: "j1"), .warmURL), record: open), .apply(.onMyWay(id: "j1")),
                    "onmyway routes for open work: \(status)")
    }
    // Which failures surface the not-found state.
    let surfaced: [NativeDeepLinkDiscardReason] = [.missingRecord, .archivedRecord, .finishedRecord]
    let silent: [NativeDeepLinkDiscardReason] = [.noExactOwner, .ownerMismatch, .stale, .missingRecordUnownedArrival]
    expect(surfaced.allSatisfy(\.surfacesNotFound), "record failures surface the not-found state")
    expect(!silent.contains(where: \.surfacesNotFound), "owner and freshness failures are silent")
    // Parking discard rule.
    expect(NativeDeepLinkRoutingPolicy.discardsParked(entering: .closed, gateChanged: true, ownerWasActive: true),
           "leaving an owner's session for a closed gate discards")
    expect(!NativeDeepLinkRoutingPolicy.discardsParked(entering: .closed, gateChanged: true, ownerWasActive: false),
           "the launch resolution (no owner yet) into a closed gate keeps it (I1)")
    expect(!NativeDeepLinkRoutingPolicy.discardsParked(entering: .closed, gateChanged: false, ownerWasActive: true),
           "staying closed keeps it")
    expect(!NativeDeepLinkRoutingPolicy.discardsParked(entering: .pending, gateChanged: true, ownerWasActive: true),
           "a pending gate keeps it")
    expect(!NativeDeepLinkRoutingPolicy.discardsParked(entering: .signedIn, gateChanged: true, ownerWasActive: true),
           "signing in never discards")
    expectEqual(NativeDeepLinkRoutingPolicy.analyticsType(.job(id: "x")), "job", "analytics type: job")
    expectEqual(NativeDeepLinkRoutingPolicy.analyticsType(.onMyWay(id: "x")), "onmyway", "analytics type: onmyway")
}

@MainActor
private func testGatePhaseMapping() {
    let map: [(NativeAuthenticationGateState, NativeDeepLinkGatePhase)] = [
        (.signedIn(email: nil), .signedIn), (.signedIn(email: "a@b.c"), .signedIn),
        (.signedOut, .closed), (.accountMismatch, .closed), (.unavailable, .closed),
        (.loading, .pending), (.initialSyncLoading, .pending), (.initialSyncUnavailable(message: "x"), .pending),
        (.subscriptionLoading, .pending), (.passwordRecovery(email: nil), .pending), (.invalidPasswordRecovery, .pending),
        (.paywall(offering: nil, message: nil), .pending), (.startingPoint(.electrical), .pending),
    ]
    for (gate, phase) in map {
        expectEqual(AppStore.deepLinkGatePhase(gate), phase, "gate \(gate) routes as \(phase)")
    }
}

// MARK: - 2. Intercept order (Google callback first)

@MainActor
private func testDispatchOrder() throws {
    var calls: [String] = []
    let google = URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=abc")!
    let outcome = NativeOpenURLDispatch.dispatch(
        google, googleSignIn: { _ in calls.append("google"); return true }, app: { _ in calls.append("app") }
    )
    expectEqual(outcome, .googleSignIn, "a claimed Google callback is Google's")
    expectEqual(calls, ["google"], "…and never reaches the widget-link gate")
    calls = []
    let widget = URL(string: "tradeready://job/live")!
    expectEqual(NativeOpenURLDispatch.dispatch(widget, googleSignIn: { _ in calls.append("google"); return false },
                                               app: { _ in calls.append("app") }), .app, "an unclaimed URL goes to the app")
    expectEqual(calls, ["google", "app"], "Google is offered the URL first, then the app, once")

    // A Google callback that somehow reaches handle(url:) has no side effect.
    let h = try Harness()
    defer { h.cleanUp() }
    h.signIn()
    h.suite.writeStash("tradeready://onmyway/live", tag: tagA)
    h.store.handle(url: google)
    expect(h.noRoute && h.store.parkedDeepLink == nil && h.store.deepLinkUnavailableNotice == nil,
           "a Google callback is not a widget link")
    expect(h.suite.stash != nil, "…and never touches the stash")
    expect(h.analytics.events.isEmpty, "…nor analytics")
}

@MainActor
private func testRecoveryLinkKeepsPriority() async throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.store.testSetAuthenticationGateState(.signedOut)
    h.store.handle(url: URL(string: "tradeready://reset-password")!)
    expect(h.store.parkedDeepLink == nil && h.noRoute, "the recovery link is never parsed as a widget link")
    await settle()
    let gate = h.store.authenticationGateState
    expect(gate == .invalidPasswordRecovery || gate == .passwordRecovery(email: nil),
           "the recovery link reaches the recovery handler first (got \(gate))")
}

// MARK: - 3. Malformed, oversized and stale links: dropped, no side effects

@MainActor
private func testMalformedAndOversized() throws {
    let h = try Harness()
    defer { h.cleanUp() }
    let longID = String(repeating: "x", count: 129)
    let bad: [String] = [
        "tradeready://job/", "tradeready://job", "tradeready://onmyway/live/extra", "tradeready://job/live?x=1",
        "tradeready://job/live#frag", "tradeready://invoice/live", "https://example.com/job/live",
        "tradeready://job/\(longID)", "tradeready://onmyway/%00live", "tradeready://job/%E2%80",
        "tradeready://job/" + String(repeating: "a", count: 1020),
    ]
    var tested = 0
    for signedIn in [false, true] {
        if signedIn { h.signIn() } else { h.store.testSetAuthenticationGateState(.signedOut) }
        h.suite.writeStash("tradeready://onmyway/live", tag: tagA)
        for raw in bad {
            guard let url = URL(string: raw) else {
                expect(false, "fixture: \(raw.prefix(60)) must be a constructible URL (else it tests nothing)")
                continue
            }
            tested += 1
            h.store.handle(url: url)
            expect(h.noRoute && h.store.parkedDeepLink == nil && h.store.deepLinkUnavailableNotice == nil,
                   "signedIn=\(signedIn): \(raw.prefix(60)) is dropped with no route, park or notice")
        }
        expect(h.suite.stash != nil, "signedIn=\(signedIn): malformed links never touch the stash")
        expect(h.analytics.events.isEmpty, "signedIn=\(signedIn): no analytics for dropped links")
        h.suite.defaults.removeObject(forKey: WidgetAppGroup.pendingOpenURLKey)
    }
    expectEqual(tested, bad.count * 2, "every malformed link was actually handled, signed out and signed in (M3)")
    // Malformed / untagged / stale / oversized stashes: removed, nothing routed.
    h.signIn()
    let badStashes: [(String, String)] = [
        ("not json", "not json"),
        ("untagged", #"{"url":"tradeready://job/live","at":"\#(iso(Date()))"}"#),
        ("stale", try WidgetJSONValue.encodeJSON(WidgetPendingOpenURLStash(url: "tradeready://job/live",
                                                                            at: iso(Date().addingTimeInterval(-301)), ownerTag: tagA))),
        ("future", try WidgetJSONValue.encodeJSON(WidgetPendingOpenURLStash(url: "tradeready://job/live",
                                                                             at: iso(Date().addingTimeInterval(60)), ownerTag: tagA))),
        ("bad grammar", try WidgetJSONValue.encodeJSON(WidgetPendingOpenURLStash(url: "tradeready://job/live/x", at: iso(Date()), ownerTag: tagA))),
        ("oversized", #"{"url":"tradeready://job/live","at":"\#(iso(Date()))","ownerTag":"\#(tagA)","pad":"\#(String(repeating: "p", count: 4096))"}"#),
    ]
    for (label, raw) in badStashes {
        h.suite.defaults.set(raw, forKey: WidgetAppGroup.pendingOpenURLKey)
        h.store.consumePendingOpenURLStash()
        expect(h.suite.stash == nil, "\(label) stash is removed")
        expect(h.noRoute && h.store.parkedDeepLink == nil && h.store.deepLinkUnavailableNotice == nil,
               "\(label) stash routes, parks and shows nothing")
    }
    expect(h.analytics.events.isEmpty, "no analytics for any dropped stash")
}

// MARK: - 4. The cold × warm × gate × owner × record matrix through AppStore

private enum Arrival: String, CaseIterable { case cold, warm }

@MainActor
private func deliver(_ h: Harness, _ arrival: Arrival, _ route: String, tag: String? = tagA) {
    switch arrival {
    case .cold:
        h.suite.writeStash("tradeready://\(route)", tag: tag)
        h.store.consumePendingOpenURLStash()
    case .warm:
        h.store.handle(url: URL(string: "tradeready://\(route)")!)
    }
}

@MainActor
private func testSignedInMatrix() throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.signIn()
    for arrival in Arrival.allCases {
        // job → the job's detail.
        h.resetRoute()
        deliver(h, arrival, "job/live")
        expectEqual(h.store.deepLinkedJobID, "live", "\(arrival) job: routes the exact id")
        expectEqual(h.store.selectedTab, .jobs, "\(arrival) job: selects Jobs")
        expect(h.store.pendingOnMyWayJobID == nil, "\(arrival) job: presents no On My Way review")
        expect(h.suite.stash == nil, "\(arrival) job: no stash is left")
        // onmyway → the editable review, never sent.
        h.resetRoute()
        deliver(h, arrival, "onmyway/live")
        expectEqual(h.store.pendingOnMyWayJobID, "live", "\(arrival) onmyway: requests the editable review")
        expectEqual(h.store.deepLinkedJobID, "live", "\(arrival) onmyway: deep-links the job")
        // Record failures → the not-found notice, no route.
        let failuresByRoute: [(String, NativeDeepLinkDiscardReason)] = [
            ("job/missing", .missingRecord), ("onmyway/missing", .missingRecord),
            ("job/archived", .archivedRecord), ("onmyway/archived", .archivedRecord),
            ("onmyway/archived-timer", .archivedRecord),
            ("onmyway/complete", .finishedRecord), ("onmyway/paid", .finishedRecord),
        ]
        for (route, reason) in failuresByRoute {
            h.resetRoute()
            deliver(h, arrival, route)
            expect(h.noRoute, "\(arrival) \(route): fails closed (no route, no review)")
            expectEqual(h.store.deepLinkUnavailableNotice?.reason, reason, "\(arrival) \(route): shows the not-found state")
        }
        // Allowed on the job route.
        for route in ["job/archived-timer", "job/complete", "job/paid"] {
            h.resetRoute()
            deliver(h, arrival, route)
            expectEqual(h.store.deepLinkedJobID, String(route.dropFirst(4)), "\(arrival) \(route): routes")
            expect(h.store.deepLinkUnavailableNotice == nil, "\(arrival) \(route): no not-found state")
        }
    }
    // Owner mismatch on the cold path: silent, removed.
    for tag in [tagB, nil] as [String?] {
        h.resetRoute()
        deliver(h, .cold, "job/live", tag: tag)
        expect(h.noRoute && h.store.deepLinkUnavailableNotice == nil, "cold tag \(tag == nil ? "nil" : "B"): silent discard")
        expect(h.suite.stash == nil, "…and the stash is gone")
    }
    // A warm On My Way whose matching stash carries B's tag is refused.
    h.resetRoute()
    h.suite.writeStash("tradeready://onmyway/live", tag: tagB)
    h.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    expect(h.noRoute && h.store.deepLinkUnavailableNotice == nil, "warm onmyway carrying B's stash tag: silent discard")
    expect(h.suite.stash == nil, "…and the matching stash is removed")
    // A warm On My Way leaves a stash for a DIFFERENT link alone.
    h.resetRoute()
    h.suite.writeStash("tradeready://onmyway/complete", tag: tagA)
    h.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    expectEqual(h.store.pendingOnMyWayJobID, "live", "warm onmyway routes")
    expect(h.suite.stash != nil, "…and leaves a non-matching stash in place")
    h.suite.defaults.removeObject(forKey: WidgetAppGroup.pendingOpenURLKey)
    // Analytics: one event per applied route, with its type, none for failures.
    let applied = h.analytics.deepLinkTypes
    expectEqual(applied.filter { $0 == "job" }.count, 8, "one widget_deep_link_opened{job} per applied job route")
    expectEqual(applied.filter { $0 == "onmyway" }.count, 3, "one widget_deep_link_opened{onmyway} per applied review")
    expect(h.analytics.events.allSatisfy { $0.0 == "widget_deep_link_opened" && $0.1.count == 1 },
           "no other event, no extra property")
}

@MainActor
private func testSignedInWithoutExactOwner() throws {
    // Signed in but the workspace is bound to someone else: O is nil.
    let h = try Harness(bound: bindingB)
    defer { h.cleanUp() }
    h.signIn(bindingA)
    for arrival in Arrival.allCases {
        for route in ["job/live", "onmyway/live"] {
            h.resetRoute()
            deliver(h, arrival, route)
            expect(h.noRoute && h.store.parkedDeepLink == nil && h.store.deepLinkUnavailableNotice == nil,
                   "\(arrival) \(route) with no exact workspace: silent discard")
        }
    }
    expect(h.analytics.events.isEmpty, "no analytics without the exact owner")
}

@MainActor
private func testSignedOutParksThenOwnerDecides() async throws {
    for arrival in Arrival.allCases {
        for route in ["job/live", "onmyway/live"] {
            // Same owner signs in → applies.
            let same = try Harness()
            same.store.testSetAuthenticationGateState(.signedOut)
            deliver(same, arrival, route)
            expect(same.noRoute, "\(arrival) \(route) signed out: routes nothing")
            expect(same.store.parkedDeepLink != nil, "\(arrival) \(route) signed out: parks")
            expect(same.suite.stash == nil, "\(arrival) \(route): the stash is removed when read, even while parked")
            same.signIn(bindingA)
            expectEqual(same.store.deepLinkedJobID, "live", "\(arrival) \(route): A signs in → A's route applies")
            expect(same.store.parkedDeepLink == nil, "\(arrival) \(route): …and is no longer parked")
            expectEqual(same.analytics.deepLinkTypes.count, 1, "\(arrival) \(route): one analytics event")
            same.cleanUp()

            // A different owner signs in on the same workspace (same-id `live`).
            let other = try Harness()
            other.store.testSetAuthenticationGateState(.signedOut)
            deliver(other, arrival, route)
            try other.rebind(bindingB)
            other.signIn(bindingB)
            if arrival == .cold {
                expect(other.noRoute && other.store.deepLinkUnavailableNotice == nil,
                       "cold \(route): B signs in → A's tagged stash is discarded silently")
            } else {
                // §6.2 step 4: a warm URL that arrived with no owner applies
                // for whoever signs in, looked up in THEIR data only.
                expectEqual(other.store.deepLinkedJobID, "live",
                            "warm \(route): nil-arrival link resolves in B's own data (never A's)")
            }
            expect(other.store.parkedDeepLink == nil, "\(arrival) \(route): nothing stays parked")
            other.cleanUp()
        }
    }
}

@MainActor
private func testParkingLifecycle() throws {
    let h = try Harness()
    defer { h.cleanUp() }
    // Pending gate (subscription loading) with O = A: the warm link records A.
    h.signIn()
    h.store.testSetAuthenticationGateState(.subscriptionLoading)
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    expectEqual(h.store.parkedDeepLink?.arrivalBinding, bindingA, "a pending-gate arrival records O")
    expect(h.noRoute, "…and routes nothing yet")
    // Newest wins.
    h.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    expectEqual(h.store.parkedDeepLink?.route, .onMyWay(id: "live"), "at most one parked route: the newest wins")
    // Pending → pending keeps it.
    h.store.testSetAuthenticationGateState(.paywall(offering: nil, message: nil))
    h.store.testSetAuthenticationGateState(.startingPoint(.electrical))
    expect(h.store.parkedDeepLink != nil, "moving between pending gates keeps the parked route")
    // Same owner reaches .signedIn → applies.
    h.store.testSetAuthenticationGateState(.signedIn(email: nil))
    expectEqual(h.store.pendingOnMyWayJobID, "live", "reaching .signedIn applies the parked route")
    expect(h.store.parkedDeepLink == nil, "…exactly once")

    // Arrived under A, applied under B: discarded.
    h.resetRoute()
    h.store.testSetAuthenticationGateState(.subscriptionLoading)
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    try h.rebind(bindingB)
    h.signIn(bindingB)
    expect(h.noRoute && h.store.deepLinkUnavailableNotice == nil, "a route parked under A never applies under B")
    expect(h.store.parkedDeepLink == nil, "…and is discarded")
    try h.rebind(bindingA)
    h.signIn(bindingA)

    // Entering a closed gate discards; staying there does not.
    for closed in [NativeAuthenticationGateState.signedOut, .accountMismatch, .unavailable] {
        h.resetRoute()
        h.store.testSetAuthenticationGateState(.loading)
        h.store.handle(url: URL(string: "tradeready://job/live")!)
        expect(h.store.parkedDeepLink != nil, "sanity: parked behind .loading")
        h.store.testSetAuthenticationGateState(closed)
        expect(h.store.parkedDeepLink == nil, "entering \(closed) discards the parked route")
        h.store.handle(url: URL(string: "tradeready://job/live")!)
        h.store.testSetAuthenticationGateState(closed)
        expect(h.store.parkedDeepLink != nil, "a link that arrived while already \(closed) stays parked")
        h.store.testSetAuthenticationGateState(.signedIn(email: nil))
        expectEqual(h.store.deepLinkedJobID, "live", "…and applies at sign-in (same owner)")
    }

    // Backgrounding discards.
    h.resetRoute()
    h.store.testSetAuthenticationGateState(.loading)
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    h.store.discardParkedDeepLink()
    h.store.testSetAuthenticationGateState(.signedIn(email: nil))
    expect(h.noRoute, "a route discarded at background never applies")

    // A parked route that ages past 300 s is stale at sign-in.
    h.resetRoute()
    h.store.testSetAuthenticationGateState(.loading)
    h.store.handle(url: URL(string: "tradeready://job/live")!, now: Date().addingTimeInterval(-301))
    expect(h.store.parkedDeepLink != nil, "sanity: parked (fresh at its own arrival)")
    h.store.testSetAuthenticationGateState(.signedIn(email: nil))
    expect(h.noRoute && h.store.parkedDeepLink == nil && h.store.deepLinkUnavailableNotice == nil,
           "a parked route older than the stash window is discarded silently")

    // A parked record failure surfaces at sign-in.
    h.resetRoute()
    h.store.testSetAuthenticationGateState(.loading)
    h.store.handle(url: URL(string: "tradeready://job/archived")!)
    h.store.testSetAuthenticationGateState(.signedIn(email: nil))
    expectEqual(h.store.deepLinkUnavailableNotice?.reason, .archivedRecord, "a parked archived link shows not-found at sign-in")
    h.store.testSetAuthenticationGateState(.signedOut)
    expect(h.store.deepLinkUnavailableNotice == nil, "leaving for a closed gate drops the notice")
}

// MARK: - 5. No double On My Way presentation (11.04 handoff)

@MainActor
private func testNoDoubleOnMyWay() throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.signIn()
    // The intent writes the tagged stash, then hands the same link to the router.
    h.suite.writeStash("tradeready://onmyway/live", tag: tagA)
    let router = NativeIntentURLRouter()
    router.install { [weak store = h.store] in store?.handle(url: $0) }
    router.open(URL(string: "tradeready://onmyway/live")!)
    expectEqual(h.store.pendingOnMyWayJobID, "live", "the warm route presents the review")
    expect(h.suite.stash == nil, "…and removes the matching stash in the same lock hold")
    h.store.dismissPendingOnMyWay(jobID: "live")
    h.store.consumePendingOpenURLStash()
    h.store.consumePendingOpenURLStash()
    expect(h.store.pendingOnMyWayJobID == nil, "activation after dismissal never re-presents the review")
    expectEqual(h.analytics.deepLinkTypes, ["onmyway"], "exactly one presentation is recorded")

    // Cold first (no warm URL was delivered): the stash presents once, only once.
    h.suite.writeStash("tradeready://onmyway/live", tag: tagA)
    h.store.consumePendingOpenURLStash()
    expectEqual(h.store.pendingOnMyWayJobID, "live", "the cold stash presents the review")
    h.store.dismissPendingOnMyWay(jobID: "live")
    h.store.consumePendingOpenURLStash()
    expect(h.store.pendingOnMyWayJobID == nil, "…and a second activation finds nothing")

    // The review is navigation only: nothing is written to disk.
    let before = try Data(contentsOf: h.workspace.fileURL)
    h.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    expectEqual(try Data(contentsOf: h.workspace.fileURL), before, "routing sends and saves nothing")
}

// MARK: - 6. Account boundaries

@MainActor
private func testUseAnotherAccountClears() async throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.signIn()
    h.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    h.store.requestEstimateFollowUpReview(jobID: "estimate-archived")
    expectEqual(h.store.pendingOnMyWayJobID, "live", "sanity: a review is held")
    h.store.testSetAuthenticationGateState(.initialSyncUnavailable(message: "offline"))
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    expect(h.store.parkedDeepLink != nil, "sanity: a link is parked")
    // No activator: the early-exit path must clear too.
    await h.store.useAnotherAccount {}
    expect(h.store.deepLinkedJobID == nil && h.store.pendingOnMyWayJobID == nil
           && h.store.pendingEstimateFollowUpJobID == nil && h.store.parkedDeepLink == nil
           && h.store.deepLinkUnavailableNotice == nil,
           "useAnotherAccount (no activator) drops every held and parked route")
    expectEqual(h.store.authenticationGateState, .signedOut, "sanity: signed out")
}

/// Phase 12 (L286.7): a stored session rejected at re-verification ends the
/// session like sign-out: the verified binding and every held route are
/// dropped. The parked route follows the §6.3 parking rule (discarded when an
/// owner was active; kept by the launch resolution `.loading` → `.signedOut`).
@MainActor
private func testRejectedSessionClearsRoutes() async throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.signIn()
    h.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    h.store.deepLinkedJobID = "live"
    h.store.requestEstimateFollowUpReview(jobID: "estimate-archived")
    expectEqual(h.store.pendingOnMyWayJobID, "live", "sanity: a review is held")
    expectEqual(h.store.coachConversationTicket().ownerBinding, bindingA, "sanity: the verified binding is A")
    h.store.testSetAuthenticationGateState(.initialSyncUnavailable(message: "offline"))
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    expect(h.store.parkedDeepLink != nil, "sanity: a link is parked")
    h.store.testApplyRejectedSessionState()
    expectEqual(h.store.authenticationGateState, .signedOut, "sanity: the rejected session signs out")
    expect(h.store.deepLinkedJobID == nil && h.store.pendingOnMyWayJobID == nil
           && h.store.pendingEstimateFollowUpJobID == nil && h.store.parkedDeepLink == nil
           && h.store.deepLinkUnavailableNotice == nil,
           "L286.7: a rejected session drops every held and parked route")
    expect(h.store.coachConversationTicket().ownerBinding == nil, "L286.7: …and the verified binding")

    // The launch resolution keeps a parked route for the sign-in that follows.
    let launch = try Harness()
    defer { launch.cleanUp() }
    launch.store.handle(url: URL(string: "tradeready://job/live")!)
    expect(launch.store.parkedDeepLink != nil, "sanity: parked behind .loading")
    launch.store.testApplyRejectedSessionState()
    expect(launch.store.parkedDeepLink != nil, "L286.7: the launch resolution keeps the parked route (§6.3)")
    launch.signIn()
    expectEqual(launch.store.deepLinkedJobID, "live", "…and it applies when the same owner signs in")
}

// MARK: - 6b. Launch resolution is not an account boundary (fix round 1, I1)

private enum LaunchPath: String, CaseIterable { case stash, launchURL }

/// The real launch order: the store starts at `.loading`, the stash is
/// consumed (or the launch URL delivered) BEFORE activation resolves, then
/// activation with no session sets `.signedOut`, then an owner signs in.
@MainActor
private func launch(_ h: Harness, _ path: LaunchPath, _ route: String, tag: String = tagA,
                    at: Date = Date().addingTimeInterval(-1), consumedAt: Date = Date()) {
    switch path {
    case .stash:
        h.suite.writeStash("tradeready://\(route)", at: at, tag: tag)
        h.store.consumePendingOpenURLStash(now: consumedAt)
    case .launchURL:
        h.store.handle(url: URL(string: "tradeready://\(route)")!, now: consumedAt)
    }
}

@MainActor
private func testLaunchResolutionKeepsParkedRoute() throws {
    for path in LaunchPath.allCases {
        // .loading → park → .signedOut → .signedIn(A): A's record opens.
        let a = try Harness()
        expectEqual(a.store.authenticationGateState, .loading, "\(path): sanity: a fresh store starts at .loading")
        launch(a, path, "job/live")
        expect(a.store.parkedDeepLink != nil && a.noRoute, "\(path): parks during .loading")
        a.store.testSetAuthenticationGateState(.signedOut)
        expectEqual(a.store.parkedDeepLink?.route, .job(id: "live"),
                    "\(path): the launch resolution .loading → .signedOut keeps the parked route (I1)")
        a.signIn(bindingA)
        expectEqual(a.store.deepLinkedJobID, "live", "\(path): A signs in → A's record opens")
        expectEqual(a.analytics.deepLinkTypes, ["job"], "\(path): …exactly once")
        a.cleanUp()

        // The same sequence with B signing in: discarded, silently. B's data
        // has no `live` (only A had it); the stash is A-tagged.
        let b = try Harness(bound: bindingB, jobs: [job("b-only")])
        launch(b, path, "job/live")
        b.store.testSetAuthenticationGateState(.signedOut)
        expect(b.store.parkedDeepLink != nil, "\(path) B: still parked after the launch resolution")
        b.signIn(bindingB)
        expect(b.noRoute && b.store.parkedDeepLink == nil, "\(path) B: B signing in gets no route")
        expect(b.store.deepLinkUnavailableNotice == nil,
               "\(path) B: …and no \"Job not found\" for a tap B did not make (M1 / owner mismatch)")
        expect(b.analytics.events.isEmpty, "\(path) B: no analytics")
        b.cleanUp()

        // Older than the freshness window when it is finally applied.
        let stale = try Harness()
        launch(stale, path, "job/live", at: Date().addingTimeInterval(-400), consumedAt: Date().addingTimeInterval(-350))
        expect(stale.store.parkedDeepLink != nil, "\(path) stale: fresh when it arrived, so it parks")
        stale.store.testSetAuthenticationGateState(.signedOut)
        stale.signIn(bindingA)
        expect(stale.noRoute && stale.store.parkedDeepLink == nil && stale.store.deepLinkUnavailableNotice == nil,
               "\(path) stale: past 300 s at apply time → discarded silently")
        stale.cleanUp()

        // A launch that resolves to .accountMismatch is not a boundary either.
        let mismatch = try Harness()
        launch(mismatch, path, "job/live")
        mismatch.store.testSetAuthenticationGateState(.accountMismatch)
        expect(mismatch.store.parkedDeepLink != nil, "\(path): launch → .accountMismatch keeps the parked route")
        mismatch.cleanUp()
    }

    // Leaving a session in which an owner WAS active is a boundary.
    let h = try Harness()
    defer { h.cleanUp() }
    for closed in [NativeAuthenticationGateState.signedOut, .accountMismatch, .unavailable] {
        h.signIn(bindingA)
        h.store.testSetAuthenticationGateState(.subscriptionLoading)
        h.store.handle(url: URL(string: "tradeready://job/live")!)
        expect(h.store.parkedDeepLink != nil, "sanity: parked behind .subscriptionLoading with O = A")
        h.store.testSetAuthenticationGateState(closed)
        expect(h.store.parkedDeepLink == nil, "after A was active, entering \(closed) discards the parked route")
    }
    // The owner flag survives an intermediate pending gate (signedIn → loading → signedOut).
    h.signIn(bindingA)
    h.store.testSetAuthenticationGateState(.loading)
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    h.store.testSetAuthenticationGateState(.signedOut)
    expect(h.store.parkedDeepLink == nil, "signedIn → .loading → .signedOut still discards (A was active)")
    // …and is consumed by that boundary: the next launch-like resolution keeps a new route.
    h.store.testSetAuthenticationGateState(.loading)
    h.store.handle(url: URL(string: "tradeready://job/live")!)
    h.store.testSetAuthenticationGateState(.signedOut)
    expect(h.store.parkedDeepLink != nil, "after the boundary, a new .loading → .signedOut keeps a new route")
}

// MARK: - 6c. The second useAnotherAccount clear (fix round 1, M4)

@MainActor
private func testUseAnotherAccountSecondClear() async throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.signIn(bindingA)
    var heldDuringSwitch: String?
    h.subscription.onLogOut = { [weak store = h.store] in
        // A link arrives after `clearSession` and the first clear, while A's
        // owner fields are still set (the teardown runs after `logOut`).
        store?.handle(url: URL(string: "tradeready://onmyway/live")!)
        heldDuringSwitch = store?.pendingOnMyWayJobID
    }
    h.store.scheduleBookingTestSeedIdentityActivator()
    await h.store.useAnotherAccount {}
    expectEqual(heldDuringSwitch, "live", "sanity: the mid-switch link was applied while A's fields were still set")
    expectEqual(h.store.authenticationGateState, .signedOut, "sanity: the switch reached its success path")
    expect(h.store.pendingOnMyWayJobID == nil && h.store.deepLinkedJobID == nil && h.store.parkedDeepLink == nil,
           "the clear after the awaits drops a route that arrived between clearSession and logOut")
}

// MARK: - 6d. A verified owner behind a pending gate (final review item 2)

/// O is nil at `.initialSyncLoading`/`.initialSyncUnavailable` (and before a
/// workspace is bound), yet the account IS verified. A warm link that parks
/// there must carry that owner, and leaving that session is a boundary.
@MainActor
private func testVerifiedOwnerBehindPendingGate() async throws {
    // The workspace belongs to B (B's data has a `live` job). A signs in
    // first: verified, but A's workspace is not bound here, so O stays nil.
    for viaSignedOut in [false, true] {
        let label = viaSignedOut ? "via .signedOut" : "direct"
        let h = try Harness(bound: bindingB)
        defer { h.cleanUp() }
        h.signIn(bindingA)
        expect(h.store.derivedStatePublishBinding == nil, "\(label): sanity: O is nil for A (no bound workspace)")
        h.store.testSetAuthenticationGateState(.initialSyncLoading)
        h.store.handle(url: URL(string: "tradeready://job/live")!)
        expectEqual(h.store.parkedDeepLink?.arrivalBinding, bindingA,
                    "\(label): a link parked behind the initial sync records the verified owner A")
        h.store.testSetAuthenticationGateState(.initialSyncUnavailable(message: "offline"))
        expect(h.store.parkedDeepLink != nil, "\(label): sanity: still parked behind the unavailable gate")
        if viaSignedOut {
            h.store.testSetAuthenticationGateState(.signedOut)
            expect(h.store.parkedDeepLink == nil, "\(label): A was verified, so leaving A's session discards the route")
        }
        h.signIn(bindingB)
        expectEqual(h.store.derivedStatePublishBinding, bindingB, "\(label): sanity: O = B")
        expect(h.noRoute && h.store.parkedDeepLink == nil,
               "\(label): B never gets the link that parked in A's session (B's same-id job stays closed)")
        expect(h.store.deepLinkUnavailableNotice == nil, "\(label): …and sees no notice for a tap B did not make")
    }

    // The password-recovery exits are an account boundary for held routes.
    let r = try Harness()
    defer { r.cleanUp() }
    r.signIn(bindingA)
    r.store.handle(url: URL(string: "tradeready://onmyway/live")!)
    expectEqual(r.store.pendingOnMyWayJobID, "live", "recovery: sanity: A's review is held")
    r.store.testSetAuthenticationGateState(.passwordRecovery(email: nil))
    await r.store.cancelPasswordRecovery()
    expectEqual(r.store.authenticationGateState, .signedOut, "recovery: sanity: the recovery sign-out ran")
    expect(r.store.deepLinkedJobID == nil && r.store.pendingOnMyWayJobID == nil && r.store.parkedDeepLink == nil,
           "recovery: the recovery sign-out drops every held route")
}

// MARK: - 7. P8: an archived estimate's est_ notification opens

@MainActor
private func testP8ArchivedEstimateNotification() throws {
    let h = try Harness()
    defer { h.cleanUp() }
    h.store.requestEstimateFollowUpReview(jobID: "estimate-archived")
    expect(h.store.pendingEstimateFollowUpJobID == nil, "signed out: the est_ tap is inert")
    h.signIn()
    h.store.requestEstimateFollowUpReview(jobID: "estimate-archived")
    expectEqual(h.store.pendingEstimateFollowUpJobID, "estimate-archived", "P8: the archived estimate's review opens")
    expectEqual(h.store.deepLinkedJobID, "estimate-archived", "…on the exact job")
    expectEqual(h.store.selectedTab, .jobs, "…in Jobs")
    h.store.dismissPendingEstimateFollowUp(jobID: "estimate-archived")
    h.store.requestEstimateFollowUpReview(jobID: "live")
    expect(h.store.pendingEstimateFollowUpJobID == nil, "a job that is not estimate_sent still fails closed")
    h.store.requestEstimateFollowUpReview(jobID: "missing")
    expect(h.store.pendingEstimateFollowUpJobID == nil, "a missing job still fails closed")
}

// MARK: - Main

@main
struct DeepLinkRoutingTests {
    @MainActor
    static func main() async throws {
        func run(_ label: String, _ body: () throws -> Void) {
            do { try body() } catch { failures += 1; print("FAIL: \(label) threw \(error)") }
        }
        func runAsync(_ label: String, _ body: () async throws -> Void) async {
            do { try await body() } catch { failures += 1; print("FAIL: \(label) threw \(error)") }
        }
        testPolicyMatrix()
        testGatePhaseMapping()
        run("dispatch order", testDispatchOrder)
        await runAsync("recovery link priority", testRecoveryLinkKeepsPriority)
        run("malformed and oversized", testMalformedAndOversized)
        run("signed-in matrix", testSignedInMatrix)
        run("signed in without exact owner", testSignedInWithoutExactOwner)
        await runAsync("signed-out parking", testSignedOutParksThenOwnerDecides)
        run("parking lifecycle", testParkingLifecycle)
        run("no double On My Way", testNoDoubleOnMyWay)
        await runAsync("use another account", testUseAnotherAccountClears)
        await runAsync("rejected session", testRejectedSessionClearsRoutes)
        run("P8", testP8ArchivedEstimateNotification)
        run("launch resolution", testLaunchResolutionKeepsParkedRoute)
        await runAsync("second useAnotherAccount clear", testUseAnotherAccountSecondClear)
        await runAsync("verified owner behind a pending gate", testVerifiedOwnerBehindPendingGate)
        if failures == 0 {
            print("Deep-link routing tests passed")
        } else {
            print("Deep-link routing tests: \(failures) failure(s)")
            exit(1)
        }
    }
}
