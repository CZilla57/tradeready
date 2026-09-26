import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Phase 12 (12.00b.2-I, P12-013) host tests: unfinished booking and portal
// work after a relaunch.
//
// Plan 8.08 persists owner-bound incomplete work in
// `NativeScheduleBookingPendingWorkStore` (`schedule-booking-pending-work.json`):
// - a booking-link or portal-link mirror: the server made the change (mint,
//   rotate, enable, disable) but the local display copy was not saved;
// - a reschedule proof: the job's new schedule, staged before the owner's
//   `resolve_reschedule`.
// Each scenario stages its item through the real flow (the server change
// succeeds, the local snapshot save fails), relaunches a fresh AppStore on
// the same files, activates it as the app does (`performForegroundRefresh`),
// and then records what the owner sees, what the cloud rows hold, what the
// server holds and whether the item is still on the device.
//
// Everything here is production code except the network: the real AppStore,
// queue, sync coordinator, push transport and delta pull in front of the
// shared `InMemorySupabase`, and the real booking-admin, portal-manage and
// booking-respond clients in front of `LinkServer`, a stateful stand-in for
// the three endpoints (contract `docs/native-phase-8-contract-decisions.md`
// §§1, 4, 6, 7). Tokens are fixture strings. No network. Run with
// TZ=America/Phoenix.

// MARK: - Harness

final class SwitchReachability: NativeSyncReachability, @unchecked Sendable {
    var online = true
    func isReachable() async -> Bool { online }
}

/// The App Group widget/Siri action queue in memory (the extension's writer side).
final class MemoryWidgetActionQueue: NativeWidgetActionQueueBacking {
    var value: String?
    func read() -> String? { value }
    func write(_ value: String?) { self.value = value }
}

/// Booking admin (`/api/booking/admin`), portal manage (`…/portal-manage`)
/// and booking respond (`/api/booking/respond`) with server state. Status
/// reads never change anything and never return a token. Respond reads and
/// writes the request's status in the shared data server, as the real
/// route patches the request row.
final class LinkServer: NativeBookingAdministrationHTTPDataLoading, NativePortalAdministrationHTTPDataLoading,
    NativeBookingResponseHTTPDataLoading, @unchecked Sendable {
    enum RespondMode { case normal, scheduleChanged, lostAfterCommit, lostBeforeCommit, rateLimited }

    let data: InMemorySupabase
    let userID: String
    var bookingToken: String?
    var bookingEnabled = false
    var bookingRevision = 0
    var portals: [String: (token: String, enabled: Bool)] = [:]
    var knownCustomers: Set<String> = []
    var respondMode = RespondMode.normal
    var unreachable = false
    /// Every request as "family/action", for example "booking/status".
    private(set) var log: [String] = []
    /// Runs on the main actor inside the next status read, before it replies.
    var duringNextStatus: (@MainActor () async -> Void)?
    private var minted = 0

    init(data: InMemorySupabase, userID: String) {
        self.data = data
        self.userID = userID
    }

    var statusReads: Int { log.filter { $0.hasSuffix("/status") }.count }
    var mutations: [String] { log.filter { !$0.hasSuffix("/status") } }

    func resetLog() { log = [] }

    /// A new 48-hex capability, never equal to a seeded fixture token.
    func freshToken() -> String {
        minted += 1
        let suffix = String(minted, radix: 16)
        return String(repeating: "e", count: 48 - suffix.count) + suffix
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let action = body["action"] as? String ?? ""
        let path = request.url?.path ?? ""
        let family = path.hasSuffix("/booking/admin") ? "booking"
            : path.hasSuffix("/portal-manage") ? "portal"
            : path.hasSuffix("/booking/respond") ? "respond" : "unknown"
        log.append("\(family)/\(action)")
        if unreachable { throw URLError(.notConnectedToInternet) }
        if action == "status", let hook = duringNextStatus {
            duringNextStatus = nil
            await hook()
        }
        let reply: (Int, [String: Any])
        switch family {
        case "booking": reply = booking(action, body)
        case "portal": reply = portal(action, body)
        case "respond": reply = await respond(action, body)
        default: reply = (404, ["error": "Not found"])
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: reply.1)) ?? Data("{}".utf8)
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (bytes, http)
    }

    private func booking(_ action: String, _ body: [String: Any]) -> (Int, [String: Any]) {
        let operationId = body["operationId"] as? String ?? ""
        if action != "status", let expected = body["expectedRevision"] as? Int, expected != bookingRevision {
            return (409, ["error": "stale_revision", "enabled": bookingEnabled, "revision": bookingRevision])
        }
        switch action {
        case "status":
            let token = body["token"] as? String
            return (200, ["ok": true, "enabled": bookingEnabled, "revision": bookingRevision,
                          "tokenValid": token != nil && token == bookingToken])
        case "mint", "rotate":
            if action == "mint", bookingToken != nil { return (409, ["error": "already_exists"]) }
            let token = freshToken()
            bookingToken = token
            bookingEnabled = true
            bookingRevision += 1
            return (200, ["ok": true, "enabled": true, "token": token, "revision": bookingRevision,
                          "operationId": operationId])
        case "set_enabled":
            bookingEnabled = body["enabled"] as? Bool ?? bookingEnabled
            bookingRevision += 1
            return (200, ["ok": true, "enabled": bookingEnabled, "revision": bookingRevision,
                          "operationId": operationId])
        default:
            return (400, ["error": "Invalid action."])
        }
    }

    private func portal(_ action: String, _ body: [String: Any]) -> (Int, [String: Any]) {
        let customerId = body["customerId"] as? String ?? ""
        let operationId = body["operationId"] as? String ?? ""
        guard knownCustomers.contains(customerId) else { return (404, ["error": "Not found"]) }
        let current = portals[customerId]
        switch action {
        case "status":
            let token = body["token"] as? String
            return (200, ["ok": true, "enabled": current?.enabled ?? false,
                          "tokenValid": token != nil && token == current?.token, "adopted": current != nil])
        case "mint", "rotate":
            if action == "mint", current != nil { return (409, ["error": "already_exists"]) }
            let token = freshToken()
            portals[customerId] = (token, true)
            return (200, ["ok": true, "token": token, "enabled": true, "operationId": operationId])
        case "set_enabled":
            guard var portal = current else { return (404, ["error": "Not found"]) }
            portal.enabled = body["enabled"] as? Bool ?? portal.enabled
            portals[customerId] = portal
            return (200, ["ok": true, "enabled": portal.enabled, "operationId": operationId])
        default:
            return (400, ["error": "Invalid action."])
        }
    }

    /// `backend-workers/lib/booking/respond.js` TRANSITIONS (resolve only
    /// from `reschedule_requested`; decline from booked, confirmed or
    /// reschedule_requested; anything else is 409 `invalid_state`).
    private func respond(_ action: String, _ body: [String: Any]) async -> (Int, [String: Any]) {
        let requestId = body["requestId"] as? String ?? ""
        guard var row = requestRow(requestId), let current = row["status"] as? String else {
            return (404, ["error": "Not found"])
        }
        let transitions: [String: (from: [String], to: String)] = [
            "resolve_reschedule": (["reschedule_requested"], "confirmed"),
            "decline": (["booked", "confirmed", "reschedule_requested"], "declined"),
        ]
        guard let transition = transitions[action] else { return (400, ["error": "Invalid action."]) }
        switch respondMode {
        case .rateLimited: return (429, ["error": "Too many requests"])
        case .lostBeforeCommit: return (500, ["error": "Database error"])
        default: break
        }
        guard transition.from.contains(current) else { return (409, ["error": "invalid_state", "status": current]) }
        if action == "resolve_reschedule", respondMode == .scheduleChanged {
            return (409, ["error": "schedule_changed", "status": current])
        }
        row["status"] = transition.to
        await upsert(table: "bookingRequests", id: requestId, record: row)
        if respondMode == .lostAfterCommit { return (500, ["error": "Database error"]) }
        return (200, ["ok": true, "status": transition.to])
    }

    // MARK: Data-server access (another device, or the respond route)

    func row(_ table: String, _ id: String) -> [String: Any]? {
        guard let stored = data.storedRow(table: table, id: id, userID: userID), !stored.deleted,
              let bytes = try? JSONEncoder().encode(stored.data)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    func requestRow(_ id: String) -> [String: Any]? { row("bookingRequests", id) }

    func upsert(table: String, id: String, record: [String: Any]) async {
        var request = URLRequest(url: URL(string: "https://project.supabase.co/rest/v1/\(table)")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "user_id": userID, "data": record])
        _ = try? await data.data(for: request)
    }

    func delete(table: String, id: String) async {
        var request = URLRequest(url: URL(string: "https://project.supabase.co/rest/v1/\(table)?id=eq.\(id)&user_id=eq.\(userID)")!)
        request.httpMethod = "PATCH"
        _ = try? await data.data(for: request)
    }

    func settingsRow() async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://project.supabase.co/rest/v1/settings?user_id=eq.\(userID)")!)
        request.httpMethod = "GET"
        guard let (bytes, _) = try? await data.data(for: request),
              let rows = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]]
        else { return nil }
        return rows.first?["data"] as? [String: Any]
    }
}

let bookingTokenA = String(repeating: "a", count: 48)
let portalTokenC = String(repeating: "c", count: 48)
let writeStamp = "2026-09-26T12:00:00.000Z"

func decodeRecord<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

func fixtureSettings(bookingLink: (token: String, enabled: Bool)?) -> Canonical.Settings {
    var json = """
    {"businessName":"Ada Electric","contactName":"Ada","phone":"p","email":"e","address":"a",
     "trade":"electrical","laborRate":95,"materialMarkup":25,"overheadPercent":10,
     "marginPercent":30,"minimumJobFee":0,"travelFeePerMile":0,"emergencyMultiplier":1,
     "rules":[],"paymentNotes":"","provider":"none"
    """
    if let bookingLink {
        json += ",\"bookingLink\":{\"token\":\"\(bookingLink.token)\",\"enabled\":\(bookingLink.enabled)}"
    }
    return decodeRecord(Canonical.Settings.self, json + "}")
}

func fixtureCustomer(portal: (token: String, enabled: Bool)?) -> Canonical.Customer {
    var json = #"{"id":"cust-1","name":"Nora","email":"nora@example.test","phone":"p","address":"a","notes":"n""#
    if let portal { json += ",\"portal\":{\"token\":\"\(portal.token)\",\"enabled\":\(portal.enabled)}" }
    return decodeRecord(Canonical.Customer.self, json + "}")
}

func fixtureJob() -> Canonical.Job {
    decodeRecord(Canonical.Job.self, """
    {"id":"job-1","customerId":"cust-1","customerName":"Nora","title":"Panel swap",
     "description":"d","status":"scheduled","address":"1 Main","estimateTotal":400,"laborHours":2,
     "laborRate":95,"materials":[],"materialMarkup":25,"overhead":10,"margin":30,"notes":"keep-me",
     "createdAt":"2026-09-01T00:00:00.000Z","scheduledDate":"2026-09-22",
     "scheduledStartTime":"09:00","scheduledEndTime":"10:00"}
    """)
}

func fixtureRequest(status: String = "reschedule_requested") -> Canonical.BookingRequest {
    decodeRecord(Canonical.BookingRequest.self, """
    {"id":"req-1","status":"\(status)","kind":"booked","name":"Sam Ortiz","phone":"555-0177",
     "email":"sam@example.test","address":"9 Oak Ave","details":"Panel inspection","preferredTiming":"",
     "createdAt":"2026-09-10T00:00:00.000Z","convertedJobId":"job-1",
     "slot":{"date":"2026-09-23","start":"09:00","end":"10:00","timeZone":"America/Phoenix",
             "startUtc":"2026-09-23T16:00:00.000Z","endUtc":"2026-09-23T17:00:00.000Z"}}
    """)
}

/// The owner's reschedule of job-1 onto the request's slot, opened against
/// the job's current schedule.
let rescheduleDraft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
    jobID: "job-1", baselineDate: "2026-09-22", baselineStart: "09:00", baselineEnd: "10:00",
    baselineStatus: "scheduled", date: "2026-09-23", start: "09:00", end: "10:00"
)

/// One device: the app's files in a temporary directory, the data server and
/// the link server. `launch()` again is a relaunch on the same files.
@MainActor
final class Device {
    static let supabaseURL = URL(string: "https://project.supabase.co")!
    static let session = Data(#"{"access_token":"host-test-access-token"}"#.utf8)

    let subject: String
    let binding: String
    let dir: URL
    let backupDir: URL
    let suite: String
    let data = InMemorySupabase()
    let links: LinkServer
    let reach = SwitchReachability()
    let widgetQueue = MemoryWidgetActionQueue()
    private(set) var coordinator: NativeSyncCoordinator?

    var storeURL: URL { dir.appendingPathComponent("store.json") }
    var queue: Canonical.NativeMutationQueue {
        Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
    }
    var bookingService: NativeBookingAdministrationService {
        NativeBookingAdministrationService(endpoint: URL(string: "https://links.example.test/api/booking/admin")!, loader: links)
    }
    var portalService: NativePortalAdministrationService {
        NativePortalAdministrationService(endpoint: URL(string: "https://links.example.test/api/estimate/portal-manage")!, loader: links)
    }
    var respondService: NativeBookingResponseService {
        NativeBookingResponseService(endpoint: URL(string: "https://links.example.test/api/booking/respond")!, loader: links)
    }

    init(
        _ tag: String,
        subject: String = "11111111-2222-3333-4444-555555555555",
        binding: String = String(repeating: "b", count: 64),
        settings: Canonical.Settings = fixtureSettings(bookingLink: nil),
        customers: [Canonical.Customer] = [],
        jobs: [Canonical.Job] = [],
        requests: [Canonical.BookingRequest] = []
    ) {
        self.subject = subject
        self.binding = binding
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-schedule-booking-recovery-\(tag)-\(UUID().uuidString)", isDirectory: true)
        backupDir = dir.appendingPathComponent("SnapshotBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        suite = "com.tradeready.schedule-booking-recovery.tests.\(UUID().uuidString)"
        links = LinkServer(data: data, userID: subject)
        let snapshot = Canonical.Snapshot(payload: Canonical.SnapshotPayload(
            jobs: jobs, customers: customers, settings: settings, bookingRequests: requests))
        do { try repository().save(snapshot) } catch { print("FAIL: fixture: the snapshot is written (\(error))") }
    }

    func repository() -> Canonical.SnapshotRepository {
        Canonical.SnapshotRepository(
            primaryURL: storeURL,
            backupURL: backupDir.appendingPathComponent("store.json.backup")
        )
    }

    /// A launch. Each call builds a fresh AppStore on the same files.
    func launch() -> AppStore {
        let lock = dir.appendingPathComponent("app-group.lock")
        return AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            repository: repository(),
            widgetActionReplayTransport: NativeWidgetActionClaimTransport(
                queue: widgetQueue,
                claimDirectory: dir.appendingPathComponent("WidgetActionClaims", isDirectory: true),
                lockFile: lock
            ),
            appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                suiteName: suite,
                defaults: UserDefaults(suiteName: suite) ?? .standard,
                lockFile: lock
            ),
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: data
            ),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
    }

    /// The verified owner (a native-only account: the session plus a
    /// completed workspace document) after its initial sync, with the real
    /// sync coordinator wired to the data server.
    func signIn(_ store: AppStore, subject: String? = nil, binding: String? = nil) async {
        let subject = subject ?? self.subject
        let binding = binding ?? self.binding
        try? NativeOnboardingStore(snapshotURL: storeURL).save(NativeOnboardingDocument(
            accountBinding: binding, stage: .done,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        store.testSeedNativeSignedInOwner(subject: subject, binding: binding)
        store.scheduleBookingTestCredentials = NativeSyncCredentials(subject: subject, sessionBytes: Self.session)
        store.scheduleBookingSessionOverride = Self.session
        store.testMarkInitialSyncCompleted(subject: subject)
        for _ in 0..<20 { await Task.yield() }
        connect(store, subject: subject)
    }

    func connect(_ store: AppStore, subject: String) {
        let credentials = NativeSyncCredentials(subject: subject, sessionBytes: Self.session)
        let coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key",
                allowsWrites: true, loader: data
            ),
            queue: queue,
            reachability: reach,
            credentialsProvider: { credentials },
            refreshSession: { false },
            settleRejected: { try store.testSettleRejectedChanges($0) },
            pull: { await store.testPullDeltaIfPossible() },
            statusChanged: { status in store.testApplySyncStatus(status) }
        )
        self.coordinator = coordinator
        store.testUseSyncCoordinator(coordinator)
    }

    @discardableResult
    func sync() async -> NativeSyncOutcome? { await coordinator?.sync(trigger: .manual) }

    /// Makes every snapshot save fail (the backup directory is read-only),
    /// as a full disk or a locked data-protection class would.
    func failSnapshotSaves(_ fail: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: fail ? 0o555 : 0o755], ofItemAtPath: backupDir.path
        )
    }

    /// The pending-work items on the device, every owner's.
    var items: [NativeScheduleBookingPendingWork] {
        NativeScheduleBookingPendingWorkStore(
            fileURL: dir.appendingPathComponent("schedule-booking-pending-work.json")
        ).load()
    }

    var disk: Canonical.Snapshot? { (try? repository().load())?.snapshot }

    var localBookingLink: Canonical.Settings.BookingLink? { disk?.payload.settings?.bookingLink }
    var localPortal: Canonical.Customer.Portal? { disk?.payload.customers?.first { $0.id == "cust-1" }?.portal }
    var localRequestStatus: String? { disk?.payload.bookingRequests?.first { $0.id == "req-1" }?.status }

    func queued(_ table: String) -> Int { queue.load().filter { $0.table == table }.count }

    /// The booking link in the cloud settings row (what other devices and
    /// the Expo rollback build read).
    func cloudBookingLink() async -> (token: String?, enabled: Bool?) {
        let link = (await links.settingsRow())?["bookingLink"] as? [String: Any]
        return (link?["token"] as? String, link?["enabled"] as? Bool)
    }

    func cloudPortal() -> (token: String?, enabled: Bool?) {
        let portal = links.row("customers", "cust-1")?["portal"] as? [String: Any]
        return (portal?["token"] as? String, portal?["enabled"] as? Bool)
    }

    func cleanup() {
        failSnapshotSaves(false)
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

/// `NativeBookingSettingsView.stateTitle` and `NativeCustomerPortalView.stateTitle`:
/// what the owner's link screen shows after its status read.
func linkScreenTitle(shareable: Bool, serverEnabled: Bool?, localToken: String?) -> String {
    if shareable { return serverEnabled == true ? "Published" : "Link ready" }
    if serverEnabled == nil { return "Unavailable" }
    return localToken == nil ? "No link yet" : "Needs recovery"
}

// MARK: - Tests

@main
struct ScheduleBookingRecoveryTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(label)") }
    }

    @MainActor
    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    /// A line for the characterization record (the evidence file keeps it).
    @MainActor
    static func observed(_ id: String, _ text: String) {
        print("OBSERVED \(id): \(text)")
    }

    @MainActor
    static func main() async throws {
        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")

        await bookingMintLost()
        await bookingRotateLost()
        await bookingDisableLost()
        await portalRotateLost()
        await portalDisableLost()
        await portalMintLost()
        await rescheduleProofOutcomes()
        await rescheduleDraftFromTheRequestRows()

        if failures == 0 {
            print("PASS: schedule booking recovery tests (\(checks) checks)")
        } else {
            print("schedule booking recovery tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }

    // MARK: Staging and relaunch

    /// Signs in, pushes the workspace, runs `stage` with snapshot saves
    /// failing (the server change succeeds, the local save does not), then
    /// relaunches on the same files and activates the new AppStore the way
    /// `TradeReadyNativeApp` does on `.active` (`performForegroundRefresh`),
    /// followed by one more push pass so anything queued reaches the cloud.
    @MainActor
    static func stageThenRelaunch(_ d: Device, _ id: String, stage: (AppStore) async -> String) async -> AppStore {
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        expectEqual(d.queue.load().count, 0, "\(id): sanity: the workspace is pushed before the change")
        d.failSnapshotSaves(true)
        let outcome = await stage(first)
        d.failSnapshotSaves(false)
        expectEqual(outcome, "recoveryStaged", "\(id): sanity: the server change is made and the local save fails")
        expectEqual(d.items.count, 1, "\(id): sanity: one item is staged")
        d.links.resetLog()
        let relaunched = d.launch()
        await d.signIn(relaunched)
        await relaunched.performForegroundRefresh()
        await d.sync()
        return relaunched
    }

    // MARK: B. Booking link

    /// B1: the first Create's local save fails. The server has the link; the
    /// raw token exists only in the staged item (hash-only storage, §1.4).
    @MainActor
    static func bookingMintLost() async {
        let id = "B1 booking mint"
        let d = Device("b1")
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerBookingLink(action: .mint, adminService: d.bookingService))
        }
        let serverToken = d.links.bookingToken
        expect(serverToken != nil && d.links.bookingEnabled, "\(id): the server has an enabled link")
        let local = d.localBookingLink
        let cloud = await d.cloudBookingLink()
        let reconciled = await store.reconcileBookingLinkForSharing(adminService: d.bookingService)
        let title = linkScreenTitle(shareable: reconciled.shareURL != nil, serverEnabled: reconciled.status?.enabled,
                                    localToken: local?.token)
        observed(id, "local=\(local?.token == nil ? "none" : "token") cloud=\(cloud.token == nil ? "none" : "token") "
                 + "items=\(d.items.count) screen=\(title) mutationsAfterRelaunch=\(d.links.mutations)")
        expectEqual(d.links.mutations, [], "\(id): nothing after the relaunch changes the server")
        expect(local == nil, "\(id) [P12-013 characterized]: the display copy has no link")
        expect(cloud.token == nil, "\(id) [P12-013 characterized]: the cloud settings row has no link")
        expectEqual(d.items.count, 1, "\(id) [P12-013 characterized]: the item stays on the device")
        expectEqual(title, "No link yet", "\(id) [P12-013 characterized]: the owner sees No link yet")
        // The screen offers Create only (no local token). Create is refused:
        // the owner cannot reach the existing link from this device.
        let create = await store.administerBookingLink(action: .mint, adminService: d.bookingService)
        observed(id, "Create after the relaunch -> \(create)")
        expectEqual(create, .alreadyExists, "\(id) [P12-013 characterized]: Create answers already_exists")
        expect(d.localBookingLink == nil, "\(id) [P12-013 characterized]: …and the display copy still has no link")
        expectEqual(d.links.bookingToken, serverToken, "\(id): the refused Create changes nothing on the server")
    }

    /// B2: a confirmed Rotate's local save fails. The old link is dead.
    @MainActor
    static func bookingRotateLost() async {
        let id = "B2 booking rotate"
        let d = Device("b2", settings: fixtureSettings(bookingLink: (bookingTokenA, true)))
        defer { d.cleanup() }
        d.links.bookingToken = bookingTokenA
        d.links.bookingEnabled = true
        d.links.bookingRevision = 1
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerBookingLink(action: .rotate, adminService: d.bookingService))
        }
        let serverToken = d.links.bookingToken
        expect(serverToken != nil && serverToken != bookingTokenA, "\(id): the server has the new link")
        let local = d.localBookingLink
        let cloud = await d.cloudBookingLink()
        let reconciled = await store.reconcileBookingLinkForSharing(adminService: d.bookingService)
        let title = linkScreenTitle(shareable: reconciled.shareURL != nil, serverEnabled: reconciled.status?.enabled,
                                    localToken: local?.token)
        observed(id, "local=\(local?.token == bookingTokenA ? "old" : "other") cloud=\(cloud.token == bookingTokenA ? "old" : "other") "
                 + "items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): nothing after the relaunch changes the server")
        expectEqual(local?.token, bookingTokenA, "\(id) [P12-013 characterized]: the display copy keeps the dead token")
        expectEqual(cloud.token, bookingTokenA, "\(id) [P12-013 characterized]: the cloud settings row keeps the dead token")
        expectEqual(d.items.count, 1, "\(id) [P12-013 characterized]: the item stays on the device")
        expectEqual(title, "Needs recovery", "\(id) [P12-013 characterized]: the owner is told to rotate again")
        expect(reconciled.shareURL == nil, "\(id): the dead token is never offered for sharing")
    }

    /// B3: a Disable's local save fails (a token-less mirror).
    @MainActor
    static func bookingDisableLost() async {
        let id = "B3 booking disable"
        let d = Device("b3", settings: fixtureSettings(bookingLink: (bookingTokenA, true)))
        defer { d.cleanup() }
        d.links.bookingToken = bookingTokenA
        d.links.bookingEnabled = true
        d.links.bookingRevision = 1
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerBookingLink(action: .setEnabled, enabled: false,
                                                                 adminService: d.bookingService))
        }
        expect(!d.links.bookingEnabled, "\(id): the server link is disabled")
        let local = d.localBookingLink
        let cloud = await d.cloudBookingLink()
        let reconciled = await store.reconcileBookingLinkForSharing(adminService: d.bookingService)
        let title = linkScreenTitle(shareable: reconciled.shareURL != nil, serverEnabled: reconciled.status?.enabled,
                                    localToken: local?.token)
        observed(id, "local.enabled=\(local?.enabled.description ?? "nil") cloud.enabled=\(cloud.enabled?.description ?? "nil") "
                 + "items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): nothing after the relaunch changes the server")
        expectEqual(local?.enabled, true, "\(id) [P12-013 characterized]: the display copy still says enabled")
        expectEqual(cloud.enabled, true, "\(id) [P12-013 characterized]: the cloud settings row still says enabled")
        expectEqual(d.items.count, 1, "\(id) [P12-013 characterized]: the item stays on the device")
        expectEqual(title, "Link ready", "\(id): the screen reads the server (disabled) after its status read")
    }

    // MARK: P. Customer portal link

    @MainActor
    static func portalDevice(_ tag: String, portal: (token: String, enabled: Bool)?) -> Device {
        let d = Device(tag, customers: [fixtureCustomer(portal: portal)])
        d.links.knownCustomers = ["cust-1"]
        if let portal { d.links.portals["cust-1"] = portal }
        return d
    }

    @MainActor
    static func portalScreen(_ store: AppStore, _ d: Device) async -> (title: String, shareable: Bool) {
        let reconciled = await store.reconcilePortalLinkForSharing(customerID: "cust-1", portalService: d.portalService)
        return (linkScreenTitle(shareable: reconciled.shareURL != nil, serverEnabled: reconciled.status?.enabled,
                                localToken: d.localPortal?.token), reconciled.shareURL != nil)
    }

    /// P1: a confirmed portal Rotate's local save fails.
    @MainActor
    static func portalRotateLost() async {
        let id = "P1 portal rotate"
        let d = portalDevice("p1", portal: (portalTokenC, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerPortalLink(customerID: "cust-1", action: .rotate,
                                                                portalService: d.portalService))
        }
        let serverToken = d.links.portals["cust-1"]?.token
        expect(serverToken != nil && serverToken != portalTokenC, "\(id): the server has the new link")
        let cloud = d.cloudPortal()
        let screen = await portalScreen(store, d)
        observed(id, "local=\(d.localPortal?.token == portalTokenC ? "old" : "other") cloud=\(cloud.token == portalTokenC ? "old" : "other") "
                 + "items=\(d.items.count) screen=\(screen.title)")
        expectEqual(d.links.mutations, [], "\(id): nothing after the relaunch changes the server")
        expectEqual(d.localPortal?.token, portalTokenC, "\(id) [P12-013 characterized]: the display copy keeps the dead token")
        expectEqual(cloud.token, portalTokenC, "\(id) [P12-013 characterized]: the cloud customer row keeps the dead token")
        expectEqual(d.items.count, 1, "\(id) [P12-013 characterized]: the item stays on the device")
        expectEqual(screen.title, "Needs recovery", "\(id) [P12-013 characterized]: the owner is told to rotate again")
    }

    /// P2: a portal Disable's local save fails (a token-less mirror).
    @MainActor
    static func portalDisableLost() async {
        let id = "P2 portal disable"
        let d = portalDevice("p2", portal: (portalTokenC, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerPortalLink(customerID: "cust-1", action: .setEnabled, enabled: false,
                                                                portalService: d.portalService))
        }
        expectEqual(d.links.portals["cust-1"]?.enabled, false, "\(id): the server portal is disabled")
        let cloud = d.cloudPortal()
        let screen = await portalScreen(store, d)
        observed(id, "local.enabled=\(d.localPortal?.enabled.description ?? "nil") cloud.enabled=\(cloud.enabled?.description ?? "nil") "
                 + "items=\(d.items.count) screen=\(screen.title)")
        expectEqual(d.links.mutations, [], "\(id): nothing after the relaunch changes the server")
        expectEqual(d.localPortal?.enabled, true, "\(id) [P12-013 characterized]: the display copy still says enabled")
        expectEqual(cloud.enabled, true, "\(id) [P12-013 characterized]: the cloud customer row still says enabled")
        expectEqual(d.items.count, 1, "\(id) [P12-013 characterized]: the item stays on the device")
    }

    /// P3: the first portal Create's local save fails.
    @MainActor
    static func portalMintLost() async {
        let id = "P3 portal mint"
        let d = portalDevice("p3", portal: nil)
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerPortalLink(customerID: "cust-1", action: .mint,
                                                                portalService: d.portalService))
        }
        expect(d.links.portals["cust-1"] != nil, "\(id): the server has the portal link")
        let cloud = d.cloudPortal()
        let screen = await portalScreen(store, d)
        observed(id, "local=\(d.localPortal == nil ? "none" : "token") cloud=\(cloud.token == nil ? "none" : "token") "
                 + "items=\(d.items.count) screen=\(screen.title)")
        expect(d.localPortal == nil, "\(id) [P12-013 characterized]: the display copy has no link")
        expect(cloud.token == nil, "\(id) [P12-013 characterized]: the cloud customer row has no link")
        expectEqual(d.items.count, 1, "\(id) [P12-013 characterized]: the item stays on the device")
        expectEqual(screen.title, "No link yet", "\(id) [P12-013 characterized]: the owner sees No link yet")
        // Create is refused and the only way on is Rotate, which the screen
        // hides while there is no local token (NativeCustomerPortalView).
        let create = await store.administerPortalLink(customerID: "cust-1", action: .mint, portalService: d.portalService)
        observed(id, "Create after the relaunch -> \(create)")
        expectEqual(create, .needsExplicitRotate, "\(id) [P12-013 characterized]: Create answers needs-explicit-rotate")
        expect(d.localPortal == nil, "\(id) [P12-013 characterized]: …and the display copy still has no link")
    }

    // MARK: R. Reschedule proofs

    enum ProofCase: String, CaseIterable {
        case needsReviewDeclinedElsewhere = "R1 needsReview (declined on another device)"
        case needsReviewScheduleChanged = "R2 needsReview (schedule changed on another device)"
        case missing = "R3 missing (request deleted)"
        case unknownOutcomeCommitted = "R4 unknownOutcome (the server committed)"
        case unknownOutcomeNotCommitted = "R5 unknownOutcome (the server did not commit)"
        case failed = "R6 failed (rate limited)"
        case declineAfterAwaitingAck = "R7 decline after awaitingAck"
    }

    @MainActor
    static func rescheduleProofOutcomes() async {
        for proofCase in ProofCase.allCases {
            await rescheduleProof(proofCase)
        }
    }

    /// Prepares the reschedule (the proof is staged), produces the outcome,
    /// then relaunches and activates.
    @MainActor
    static func rescheduleProof(_ proofCase: ProofCase) async {
        let id = proofCase.rawValue
        let d = Device("r-\(ProofCase.allCases.firstIndex(of: proofCase) ?? 0)",
                       customers: [fixtureCustomer(portal: nil)], jobs: [fixtureJob()], requests: [fixtureRequest()])
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        expectEqual(d.links.requestRow("req-1")?["status"] as? String, "reschedule_requested",
                    "\(id): sanity: the server has the request")
        if proofCase == .declineAfterAwaitingAck { d.reach.online = false }
        let prepared = await store.prepareBookingReschedule(requestID: "req-1", scheduleDraft: rescheduleDraft,
                                                            writeStamp: writeStamp)
        expectEqual(d.items.count, 1, "\(id): sanity: the proof is staged")
        var outcome = ""
        switch proofCase {
        case .declineAfterAwaitingAck:
            expectEqual(prepared, .awaitingAck, "\(id): sanity: offline, the job change is not acknowledged")
            outcome = String(describing: await store.declineBookingRequest(requestID: "req-1",
                                                                           responseService: d.respondService))
            d.reach.online = true
        default:
            guard case let .proofReady(proof) = prepared else {
                expect(false, "\(id): sanity: the proof is ready (\(prepared))")
                return
            }
            switch proofCase {
            case .needsReviewDeclinedElsewhere:
                if var row = d.links.requestRow("req-1") {
                    row["status"] = "declined"
                    await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
                }
            case .needsReviewScheduleChanged:
                if var row = d.links.row("jobs", "job-1") {
                    row["scheduledDate"] = "2026-09-24"
                    row["scheduledStartTime"] = "13:00"
                    await d.links.upsert(table: "jobs", id: "job-1", record: row)
                }
                d.links.respondMode = .scheduleChanged
            case .missing:
                await d.links.delete(table: "bookingRequests", id: "req-1")
            case .unknownOutcomeCommitted:
                d.links.respondMode = .lostAfterCommit
            case .unknownOutcomeNotCommitted:
                d.links.respondMode = .lostBeforeCommit
            case .failed:
                d.links.respondMode = .rateLimited
            case .declineAfterAwaitingAck:
                break
            }
            outcome = String(describing: await store.resolveBookingReschedule(
                requestID: "req-1", proof: proof, responseService: d.respondService))
        }
        d.links.respondMode = .normal
        d.links.resetLog()

        let relaunched = d.launch()
        await d.signIn(relaunched)
        await relaunched.performForegroundRefresh()
        await d.sync()
        let server = d.links.requestRow("req-1")?["status"] as? String ?? "deleted"
        let local = d.localRequestStatus ?? "gone"
        let kept = d.items.count
        observed(id, "outcome=\(outcome) server=\(server) local=\(local) proofKept=\(kept == 1)")
        expectEqual(d.links.mutations, [], "\(id): nothing after the relaunch sends a respond call")
        switch proofCase {
        case .needsReviewDeclinedElsewhere:
            expectEqual(outcome, "needsReview(currentStatus: \"declined\")", "\(id): sanity: the outcome")
            expectEqual(local, "declined", "\(id): the pull brings the declined request")
            expectEqual(kept, 1, "\(id) [P12-013 characterized]: the proof outlives the request")
        case .needsReviewScheduleChanged:
            expectEqual(outcome, "needsReview(currentStatus: \"reschedule_requested\")", "\(id): sanity: the outcome")
            expectEqual(d.disk?.payload.jobs?.first?.scheduledDate, "2026-09-24", "\(id): the pull brings the other schedule")
            expectEqual(kept, 1, "\(id) [P12-013 characterized]: the proof for the old schedule stays")
        case .missing:
            expectEqual(outcome, "missing", "\(id): sanity: the outcome")
            expectEqual(local, "gone", "\(id): the pull removes the request")
            expectEqual(kept, 1, "\(id) [P12-013 characterized]: the proof outlives the request")
        case .unknownOutcomeCommitted:
            expectEqual(outcome, "unknownOutcome", "\(id): sanity: the outcome")
            expectEqual(server, "confirmed", "\(id): the server confirmed")
            expectEqual(local, "confirmed", "\(id): the next pull brings the confirmed request")
            expectEqual(kept, 1, "\(id) [P12-013 characterized]: the proof outlives the confirmation")
        case .unknownOutcomeNotCommitted:
            expectEqual(outcome, "unknownOutcome", "\(id): sanity: the outcome")
            expectEqual(local, "reschedule_requested", "\(id): the request still asks for a reschedule")
            expectEqual(kept, 1, "\(id): the proof stays while a resolve can still succeed")
        case .failed:
            expectEqual(outcome, "failed(reason: \"rateLimited\")", "\(id): sanity: the outcome")
            expectEqual(local, "reschedule_requested", "\(id): the request still asks for a reschedule")
            expectEqual(kept, 1, "\(id): the proof stays while a resolve can still succeed")
        case .declineAfterAwaitingAck:
            expectEqual(outcome, "applied(status: \"declined\", alreadyApplied: false)", "\(id): sanity: the decline")
            expectEqual(server, "declined", "\(id): the server declined")
            expectEqual(local, "declined", "\(id): the local request is declined")
            expectEqual(kept, 1, "\(id) [P12-013 characterized]: the proof outlives the declined request")
        }
    }

    // MARK: F. Separate finding (not P12-013)

    /// Pinned and labelled as a separate finding: the Today and Requests
    /// rows (`TodayView.resolveBookingReschedule`,
    /// `NativeBookingRequestsView.resolveReschedule`) open the draft with
    /// nil baselines and the REQUEST's status as the job baseline, so a
    /// scheduled job refuses it as a baseline conflict and no proof is ever
    /// staged from those rows.
    @MainActor
    static func rescheduleDraftFromTheRequestRows() async {
        let id = "F request-row draft"
        let d = Device("f", customers: [fixtureCustomer(portal: nil)], jobs: [fixtureJob()], requests: [fixtureRequest()])
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        let request = fixtureRequest()
        let rowDraft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
            jobID: "job-1", baselineDate: nil, baselineStart: nil, baselineEnd: nil,
            baselineStatus: request.status,
            date: request.slot?.date, start: request.slot?.start, end: request.slot?.end
        )
        let prepared = await store.prepareBookingReschedule(requestID: "req-1", scheduleDraft: rowDraft)
        observed(id, "prepare from the row's draft -> \(prepared); proofs staged=\(d.items.count)")
        expectEqual(prepared, .scheduleConflict, "\(id) [separate finding]: the row's draft is a baseline conflict")
        expectEqual(d.items.count, 0, "\(id) [separate finding]: no proof is staged")
    }
}
