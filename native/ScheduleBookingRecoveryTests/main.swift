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
// and then checks what the owner sees, what the cloud rows hold, what the
// server holds and whether the item is still on the device.
//
// Characterized before the fix (the test commit before it): nothing
// finished a mirror, so the display copy and the cloud row kept the old
// token or flag and the item stayed; after a lost first Create the owner was
// stuck on this device; a proof outlived a declined, confirmed or deleted
// request. Since the fix, recovery runs for the verified owner at launch
// (the gate-open points) and on every activation: a mirror is re-applied
// only after a fresh `status` read proves it current (never a server
// mutation), and a proof is kept only while a resolve can still succeed.
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

    /// Another device's settings save (its own mirror of a link change).
    func upsertSettings(_ record: [String: Any]) async {
        var request = URLRequest(url: URL(string: "https://project.supabase.co/rest/v1/settings")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": userID, "data": record])
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
        store.scheduleBookingRecoveryAdminService = bookingService
        store.scheduleBookingRecoveryPortalService = portalService
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

    var workStore: NativeScheduleBookingPendingWorkStore {
        NativeScheduleBookingPendingWorkStore(
            fileURL: dir.appendingPathComponent("schedule-booking-pending-work.json")
        )
    }

    /// The pending-work items on the device, every owner's.
    var items: [NativeScheduleBookingPendingWork] { workStore.load() }

    func stage(_ kind: NativeScheduleBookingPendingWork.Kind, binding: String? = nil) {
        do { try workStore.stage(.init(kind: kind, ownerBinding: binding ?? self.binding)) }
        catch { print("FAIL: fixture: the item is staged (\(error))") }
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

    /// A line for the evidence record.
    @MainActor
    static func observed(_ id: String, _ text: String) {
        print("OBSERVED \(id): \(text)")
    }

    @MainActor
    static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        expectEqual(TimeZone.current.identifier, "America/Phoenix", "runner: TZ=America/Phoenix")

        await bookingMintLost()
        await bookingRotateLost()
        await bookingDisableLost()
        await portalRotateLost()
        await portalDisableLost()
        await portalMintLost()
        await supersededMirrorIsDropped()
        await mirrorsThatCanNeverApply()
        await networkDownKeepsTheItem()
        await rescheduleProofOutcomes()
        await terminalProofCleanup()
        await anotherAccountsWorkIsNeverTouched()
        await accountChangeDuringTheStatusRead()
        await closedGateDoesNothing()
        await recoveryIsIdempotent()
        await launchGateOpenRecovers()
        await rescheduleDraftFromTheRequestRows()
        sources(root)

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
    /// relaunches on the same files. `beforeActivation` runs on the new
    /// AppStore before it is activated the way `TradeReadyNativeApp` does on
    /// `.active` (`performForegroundRefresh`); one more push pass follows so
    /// anything queued reaches the cloud.
    @MainActor
    static func stageThenRelaunch(
        _ d: Device, _ id: String,
        beforeActivation: (AppStore) async -> Void = { _ in },
        stage: (AppStore) async -> String
    ) async -> AppStore {
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
        await beforeActivation(relaunched)
        await relaunched.performForegroundRefresh()
        await d.sync()
        return relaunched
    }

    @MainActor
    static func bookingScreen(_ store: AppStore, _ d: Device) async -> String {
        let reconciled = await store.reconcileBookingLinkForSharing(adminService: d.bookingService)
        return linkScreenTitle(shareable: reconciled.shareURL != nil, serverEnabled: reconciled.status?.enabled,
                               localToken: d.localBookingLink?.token)
    }

    @MainActor
    static func bookingDevice(_ tag: String, link: (token: String, enabled: Bool)?) -> Device {
        let d = Device(tag, settings: fixtureSettings(bookingLink: link))
        if let link {
            d.links.bookingToken = link.token
            d.links.bookingEnabled = link.enabled
            d.links.bookingRevision = 1
        }
        return d
    }

    // MARK: B. Booking link

    /// B1: the first Create's local save fails. The server has the link; the
    /// raw token exists only in the staged item (hash-only storage, §1.4).
    /// Characterized: "No link yet" for good (Create answered already_exists).
    @MainActor
    static func bookingMintLost() async {
        let id = "B1 booking mint"
        let d = bookingDevice("b1", link: nil)
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerBookingLink(action: .mint, adminService: d.bookingService))
        }
        let serverToken = d.links.bookingToken
        expect(serverToken != nil && d.links.bookingEnabled, "\(id): the server has an enabled link")
        let reads = d.links.statusReads
        let cloud = await d.cloudBookingLink()
        let title = await bookingScreen(store, d)
        observed(id, "local=\(d.localBookingLink?.token == serverToken ? "server's" : "other") "
                 + "cloud=\(cloud.token == serverToken ? "server's" : "other") items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(reads, 1, "\(id): recovery read the link status once")
        expectEqual(d.localBookingLink?.token, serverToken, "\(id) [P12-013]: the display copy has the server's link")
        expectEqual(d.localBookingLink?.enabled, true, "\(id) [P12-013]: …enabled")
        expectEqual(cloud.token, serverToken, "\(id) [P12-013]: the cloud settings row has it too")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the item is removed")
        expectEqual(title, "Published", "\(id) [P12-013]: the owner sees the verified link")
        let readiness = store.rollbackReadiness()
        expectEqual(readiness.bookingWorkCount, 0, "\(id): the rollback check counts no booking work")
        expect(!readiness.notes.contains(.bookingWorkPending), "\(id): …and has no booking-work note")
    }

    /// B2: a confirmed Rotate's local save fails. The old link is dead.
    /// Characterized: the dead token stayed, locally and in the cloud row.
    @MainActor
    static func bookingRotateLost() async {
        let id = "B2 booking rotate"
        let d = bookingDevice("b2", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerBookingLink(action: .rotate, adminService: d.bookingService))
        }
        let serverToken = d.links.bookingToken
        expect(serverToken != nil && serverToken != bookingTokenA, "\(id): the server has the new link")
        let cloud = await d.cloudBookingLink()
        let title = await bookingScreen(store, d)
        observed(id, "local=\(d.localBookingLink?.token == serverToken ? "new" : "other") "
                 + "cloud=\(cloud.token == serverToken ? "new" : "other") items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(d.localBookingLink?.token, serverToken, "\(id) [P12-013]: the display copy has the new token")
        expectEqual(cloud.token, serverToken, "\(id) [P12-013]: the cloud settings row has the new token")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the item is removed")
        expectEqual(title, "Published", "\(id) [P12-013]: the owner sees the verified link")
        let settings = d.disk?.payload.settings
        expect(settings?.businessName == "Ada Electric" && settings?.laborRate == 95,
               "\(id): only the link's display fields changed")
    }

    /// B3: a Disable's local save fails (a token-less mirror).
    /// Characterized: the display copy and the cloud row still said enabled.
    @MainActor
    static func bookingDisableLost() async {
        let id = "B3 booking disable"
        let d = bookingDevice("b3", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerBookingLink(action: .setEnabled, enabled: false,
                                                                 adminService: d.bookingService))
        }
        expect(!d.links.bookingEnabled, "\(id): the server link is disabled")
        let cloud = await d.cloudBookingLink()
        let title = await bookingScreen(store, d)
        observed(id, "local.enabled=\(d.localBookingLink?.enabled.description ?? "nil") "
                 + "cloud.enabled=\(cloud.enabled?.description ?? "nil") items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(d.localBookingLink?.enabled, false, "\(id) [P12-013]: the display copy says disabled")
        expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id): …and keeps its token")
        expectEqual(cloud.enabled, false, "\(id) [P12-013]: the cloud settings row says disabled")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the item is removed")
        expectEqual(title, "Link ready", "\(id): the screen shows the verified, disabled link")
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
    static func portalScreen(_ store: AppStore, _ d: Device) async -> String {
        let reconciled = await store.reconcilePortalLinkForSharing(customerID: "cust-1", portalService: d.portalService)
        return linkScreenTitle(shareable: reconciled.shareURL != nil, serverEnabled: reconciled.status?.enabled,
                               localToken: d.localPortal?.token)
    }

    /// P1: a confirmed portal Rotate's local save fails.
    /// Characterized: the dead token stayed, locally and in the cloud row.
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
        let title = await portalScreen(store, d)
        observed(id, "local=\(d.localPortal?.token == serverToken ? "new" : "other") "
                 + "cloud=\(cloud.token == serverToken ? "new" : "other") items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(d.localPortal?.token, serverToken, "\(id) [P12-013]: the display copy has the new token")
        expectEqual(cloud.token, serverToken, "\(id) [P12-013]: the cloud customer row has the new token")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the item is removed")
        expectEqual(title, "Published", "\(id) [P12-013]: the owner sees the verified link")
        expectEqual(d.disk?.payload.customers?.first?.name, "Nora", "\(id): only the portal's display fields changed")
    }

    /// P2: a portal Disable's local save fails (a token-less mirror).
    /// Characterized: the display copy and the cloud row still said enabled.
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
        let title = await portalScreen(store, d)
        observed(id, "local.enabled=\(d.localPortal?.enabled.description ?? "nil") "
                 + "cloud.enabled=\(cloud.enabled?.description ?? "nil") items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(d.localPortal?.enabled, false, "\(id) [P12-013]: the display copy says disabled")
        expectEqual(d.localPortal?.token, portalTokenC, "\(id): …and keeps its token")
        expectEqual(cloud.enabled, false, "\(id) [P12-013]: the cloud customer row says disabled")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the item is removed")
    }

    /// P3: the first portal Create's local save fails.
    /// Characterized: "No link yet", Create answered needs-explicit-rotate
    /// and the screen hides Rotate without a local token.
    @MainActor
    static func portalMintLost() async {
        let id = "P3 portal mint"
        let d = portalDevice("p3", portal: nil)
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id) { store in
            String(describing: await store.administerPortalLink(customerID: "cust-1", action: .mint,
                                                                portalService: d.portalService))
        }
        let serverToken = d.links.portals["cust-1"]?.token
        expect(serverToken != nil, "\(id): the server has the portal link")
        let cloud = d.cloudPortal()
        let title = await portalScreen(store, d)
        observed(id, "local=\(d.localPortal?.token == serverToken ? "server's" : "other") "
                 + "cloud=\(cloud.token == serverToken ? "server's" : "other") items=\(d.items.count) screen=\(title)")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(d.localPortal?.token, serverToken, "\(id) [P12-013]: the display copy has the server's link")
        expectEqual(cloud.token, serverToken, "\(id) [P12-013]: the cloud customer row has it too")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the item is removed")
        expectEqual(title, "Published", "\(id) [P12-013]: the owner sees the verified link")
    }

    // MARK: D. A mirror the server no longer backs

    /// The staged token was replaced by a later rotation on another device
    /// (whose own mirror reached the cloud row). The status read says the
    /// staged token is not current, so it is never applied: the item is
    /// dropped and the display copy is the other device's current link.
    @MainActor
    static func supersededMirrorIsDropped() async {
        let id = "D superseded mirror"
        let d = bookingDevice("d", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id, beforeActivation: { _ in
            // Another device rotates and saves its settings.
            let later = d.links.freshToken()
            d.links.bookingToken = later
            d.links.bookingRevision += 1
            if var row = await d.links.settingsRow() {
                row["bookingLink"] = ["token": later, "enabled": true]
                await d.links.upsertSettings(row)
            }
        }) { store in
            String(describing: await store.administerBookingLink(action: .rotate, adminService: d.bookingService))
        }
        let current = d.links.bookingToken
        let staged = d.items.first
        observed(id, "local=\(d.localBookingLink?.token == current ? "current" : "other") items=\(d.items.count)")
        expectEqual(d.links.statusReads >= 1, true, "\(id): recovery read the link status")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expect(staged == nil, "\(id) [P12-013]: the item the server no longer backs is removed")
        expectEqual(d.localBookingLink?.token, current, "\(id): the display copy is the other device's current link")
        expectEqual(await bookingScreen(store, d), "Published", "\(id): …which the screen verifies")
    }

    // MARK: M. Mirrors that can never apply (no network)

    /// A flag-only booking item with no local link, a portal item for a
    /// customer no longer on the device, and a portal item for a customer
    /// the server does not know (404): nothing truthful to mirror, so each
    /// is removed and nothing is written.
    @MainActor
    static func mirrorsThatCanNeverApply() async {
        let id = "M mirrors that cannot apply"
        let d = Device("m", customers: [fixtureCustomer(portal: (portalTokenC, true))])
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        d.stage(.bookingMirror(token: nil, enabled: true, revision: 2, operationId: "op-flag"))
        d.stage(.portalMirror(customerId: "cust-gone", token: d.links.freshToken(), enabled: true, operationId: "op-gone"))
        d.stage(.portalMirror(customerId: "cust-1", token: nil, enabled: false, operationId: "op-unknown"))
        d.links.resetLog()
        await store.performForegroundRefresh()
        observed(id, "items=\(d.items.count) reads=\(d.links.log)")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: all three are removed")
        expectEqual(d.links.log, ["portal/status"], "\(id): only the known customer's status is read (404 here)")
        expect(d.localBookingLink == nil, "\(id): no booking link is invented")
        expectEqual(d.localPortal?.enabled, true, "\(id): the portal the server does not know is left as it was")
        expectEqual(d.queued("settings") + d.queued("customers"), 0, "\(id): nothing is queued")
    }

    // MARK: N. The link service cannot be reached

    /// A read that fails keeps the item for the next activation.
    @MainActor
    static func networkDownKeepsTheItem() async {
        let id = "N link service unreachable"
        let d = bookingDevice("n", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id, beforeActivation: { _ in d.links.unreachable = true }) { store in
            String(describing: await store.administerBookingLink(action: .rotate, adminService: d.bookingService))
        }
        expectEqual(d.items.count, 1, "\(id): the item is kept while the status read fails")
        expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id): nothing is applied")
        d.links.unreachable = false
        await store.performForegroundRefresh()
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the next activation finishes it")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id) [P12-013]: …with the server's token")
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
    /// then relaunches and activates. Characterized: the proof stayed in
    /// every case.
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
        expectEqual(d.links.log, [], "\(id): recovery sends nothing for a proof")
        switch proofCase {
        case .needsReviewDeclinedElsewhere:
            expectEqual(outcome, "needsReview(currentStatus: \"declined\")", "\(id): sanity: the outcome")
            expectEqual(local, "declined", "\(id): the pull brings the declined request")
            expectEqual(kept, 0, "\(id) [P12-013]: no resolve can succeed: the proof is removed")
        case .needsReviewScheduleChanged:
            expectEqual(outcome, "needsReview(currentStatus: \"reschedule_requested\")", "\(id): sanity: the outcome")
            expectEqual(d.disk?.payload.jobs?.first?.scheduledDate, "2026-09-24", "\(id): the pull brings the other schedule")
            expectEqual(kept, 0, "\(id) [P12-013]: the proof no longer matches the job: removed")
        case .missing:
            expectEqual(outcome, "missing", "\(id): sanity: the outcome")
            expectEqual(local, "gone", "\(id): the pull removes the request")
            expectEqual(kept, 0, "\(id) [P12-013]: the request is gone: the proof is removed")
        case .unknownOutcomeCommitted:
            expectEqual(outcome, "unknownOutcome", "\(id): sanity: the outcome")
            expectEqual(server, "confirmed", "\(id): the server confirmed")
            expectEqual(local, "confirmed", "\(id): the next pull brings the confirmed request")
            expectEqual(kept, 0, "\(id) [P12-013]: the request is confirmed: the proof is removed")
        case .unknownOutcomeNotCommitted:
            expectEqual(outcome, "unknownOutcome", "\(id): sanity: the outcome")
            expectEqual(local, "reschedule_requested", "\(id): the request still asks for a reschedule")
            expectEqual(kept, 1, "\(id): the proof stays while a resolve can still succeed (the owner retries)")
            expectEqual(relaunched.rollbackReadiness().bookingWorkCount, 1, "\(id): the rollback check counts it")
        case .failed:
            expectEqual(outcome, "failed(reason: \"rateLimited\")", "\(id): sanity: the outcome")
            expectEqual(local, "reschedule_requested", "\(id): the request still asks for a reschedule")
            expectEqual(kept, 1, "\(id): the proof stays while a resolve can still succeed (the owner retries)")
        case .declineAfterAwaitingAck:
            expectEqual(outcome, "applied(status: \"declined\", alreadyApplied: false)", "\(id): sanity: the decline")
            expectEqual(server, "declined", "\(id): the server declined")
            expectEqual(local, "declined", "\(id): the local request is declined")
            expectEqual(kept, 0, "\(id) [P12-013]: no resolve can succeed: the proof is removed")
        }
    }

    // MARK: T. Terminal-proof cleanup (local state only, no network)

    @MainActor
    static func terminalProofCleanup() async {
        let proof = NativeScheduleProof(jobId: "job-1", updatedAt: writeStamp, date: "2026-09-23", start: "09:00")
        var moved = fixtureJob()
        moved.scheduledDate = "2026-09-23"
        moved.scheduledStartTime = "09:00"
        var elsewhere = moved
        elsewhere.scheduledDate = "2026-09-30"
        let cases: [(id: String, jobs: [Canonical.Job], requests: [Canonical.BookingRequest], offline: Bool, kept: Bool)] = [
            ("T1 request not on the device", [moved], [], false, false),
            ("T2 request declined", [moved], [fixtureRequest(status: "declined")], false, false),
            ("T3 request confirmed", [moved], [fixtureRequest(status: "confirmed")], false, false),
            ("T4 request cancelled", [moved], [fixtureRequest(status: "cancelled")], false, false),
            ("T5 job rescheduled again", [elsewhere], [fixtureRequest()], false, false),
            ("T6 job deleted", [], [fixtureRequest()], false, false),
            ("T7 resolvable, job change acknowledged", [moved], [fixtureRequest()], false, true),
            ("T8 resolvable, job change not yet acknowledged", [moved], [fixtureRequest()], true, true),
        ]
        for (index, c) in cases.enumerated() {
            let d = Device("t\(index)", customers: [fixtureCustomer(portal: nil)], jobs: c.jobs, requests: c.requests)
            defer { d.cleanup() }
            let store = d.launch()
            await d.signIn(store)
            await d.sync()
            d.stage(.rescheduleProof(requestId: "req-1", proof: proof, writeStamp: writeStamp))
            // Another account's proof on the same device is its own (its
            // boundary scrubs it): never touched here.
            let other = String(repeating: "c", count: 64)
            d.stage(.rescheduleProof(requestId: "req-other", proof: proof, writeStamp: writeStamp), binding: other)
            if c.offline {
                d.reach.online = false
                _ = try? d.queue.enqueue(table: "jobs", op: .upsert, recordId: "job-1",
                                     payload: .object(["id": .string("job-1")]))
            }
            d.links.resetLog()
            await store.performForegroundRefresh()
            let mine = d.items.filter { $0.ownerBinding == d.binding }.count
            observed(c.id, "proofKept=\(mine == 1)")
            expectEqual(mine, c.kept ? 1 : 0, "\(c.id) [P12-013]: \(c.kept ? "kept" : "removed")")
            expectEqual(d.items.filter { $0.ownerBinding == other }.count, 1, "\(c.id): another account's proof is untouched")
            expectEqual(d.links.log, [], "\(c.id): nothing is sent")
        }
    }

    // MARK: G. Account boundaries

    /// Account A's items on the device while B is signed in: B's activation
    /// and an explicit recovery for A's binding read nothing and write
    /// nothing, and A's items stay for A's own boundary to scrub.
    @MainActor
    static func anotherAccountsWorkIsNeverTouched() async {
        let id = "G1 another account"
        let d = bookingDevice("g1", link: nil)
        defer { d.cleanup() }
        let bindingA = String(repeating: "a", count: 64)
        let tokenA = d.links.freshToken()
        d.links.bookingToken = tokenA
        d.links.bookingEnabled = true
        d.stage(.bookingMirror(token: tokenA, enabled: true, revision: 1, operationId: "op-a"), binding: bindingA)
        d.stage(.rescheduleProof(requestId: "req-1",
                                 proof: NativeScheduleProof(jobId: "job-1", updatedAt: writeStamp, date: "2026-09-23", start: "09:00"),
                                 writeStamp: writeStamp), binding: bindingA)
        let before = d.items
        let store = d.launch()
        await d.signIn(store)   // B, the device's owner now
        await d.sync()
        d.links.resetLog()
        await store.performForegroundRefresh()
        let explicit = await store.recoverScheduleBookingPendingWork(ownerBinding: bindingA)
        observed(id, "reads=\(d.links.log) items=\(d.items.count)")
        expectEqual(d.links.log, [], "\(id): nothing is read for A")
        expectEqual(d.items, before, "\(id): A's items are untouched")
        expect(d.localBookingLink == nil, "\(id): A's token never reaches B's snapshot")
        expectEqual(d.queued("settings"), 0, "\(id): …nor B's push queue")
        expect(explicit.reappliedMirrors == 0 && explicit.retained == 0 && explicit.proofsReady.isEmpty
               && explicit.proofsSuperseded.isEmpty, "\(id): an explicit recovery for A's binding does nothing")
    }

    /// The owner changes, or an account boundary passes and the same owner
    /// is seeded again (only the account generation tells them apart),
    /// while the recovery's status read is suspended: the pass stops,
    /// applies nothing and keeps the item. The owner's next launch and
    /// activation finish it.
    @MainActor
    static func accountChangeDuringTheStatusRead() async {
        for boundary in ["sign-out", "boundary then the same owner"] {
            let id = "G2 \(boundary) during the status read"
            let d = bookingDevice("g2-\(boundary.count)", link: (bookingTokenA, true))
            defer { d.cleanup() }
            let first = d.launch()
            await d.signIn(first)
            await d.sync()
            d.failSnapshotSaves(true)
            _ = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
            d.failSnapshotSaves(false)
            expectEqual(d.items.count, 1, "\(id): sanity: one item is staged")
            d.links.resetLog()
            let relaunched = d.launch()
            await d.signIn(relaunched)
            d.links.duringNextStatus = {
                if boundary == "sign-out" {
                    relaunched.scheduleBookingTestClearOwner()
                } else {
                    relaunched.testApplyCompletedSignOutState()
                    relaunched.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
                    relaunched.testMarkInitialSyncCompleted(subject: d.subject)
                }
            }
            await relaunched.performForegroundRefresh()
            observed(id, "reads=\(d.links.statusReads) items=\(d.items.count)")
            expectEqual(d.links.statusReads, 1, "\(id): recovery started its status read")
            expectEqual(d.items.count, 1, "\(id) [P12-013]: the item is kept")
            expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id) [P12-013]: nothing is applied")
            expectEqual(d.queued("settings"), 0, "\(id): nothing is queued")
            let next = d.launch()
            await d.signIn(next)
            await next.performForegroundRefresh()
            expectEqual(d.items.count, 0, "\(id): the owner's next activation finishes it")
            expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id): …with the server's token")
        }
    }

    /// Before the initial sync has completed for the signed-in owner, the
    /// activation does not recover.
    @MainActor
    static func closedGateDoesNothing() async {
        let id = "G3 initial sync not completed"
        let d = bookingDevice("g3", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.failSnapshotSaves(true)
        _ = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        d.failSnapshotSaves(false)
        d.links.resetLog()
        let relaunched = d.launch()
        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
            accountBinding: d.binding, stage: .done,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        relaunched.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
        relaunched.scheduleBookingSessionOverride = Device.session
        relaunched.scheduleBookingRecoveryAdminService = d.bookingService
        await relaunched.performForegroundRefresh()
        let explicit = await relaunched.recoverScheduleBookingPendingWork(ownerBinding: d.binding)
        expectEqual(d.links.log, [], "\(id): nothing is read")
        expectEqual(d.items.count, 1, "\(id): the item is kept")
        expectEqual(explicit.reappliedMirrors, 0, "\(id): an explicit recovery does nothing either")
        expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id): nothing is applied")
    }

    // MARK: I. Idempotence

    /// Two activations, and a second recovery started while the first is
    /// suspended in its status read: the item is applied once, the second
    /// pass reads nothing, and nothing more is queued.
    @MainActor
    static func recoveryIsIdempotent() async {
        let id = "I idempotence"
        let d = bookingDevice("i", link: (bookingTokenA, true))
        defer { d.cleanup() }
        var overlapping: AppStore.PendingWorkRecovery?
        let store = await stageThenRelaunch(d, id, beforeActivation: { store in
            d.links.duringNextStatus = {
                overlapping = await store.recoverScheduleBookingPendingWork(ownerBinding: d.binding)
            }
        }) { store in
            String(describing: await store.administerBookingLink(action: .rotate, adminService: d.bookingService))
        }
        expectEqual(d.links.statusReads, 1, "\(id): one status read for the one item")
        expect(overlapping != nil && overlapping?.reappliedMirrors == 0 && overlapping?.retained == 0,
               "\(id): a recovery started meanwhile does nothing (\(String(describing: overlapping)))")
        expectEqual(d.items.count, 0, "\(id): applied")
        let token = d.localBookingLink?.token
        d.links.resetLog()
        await store.performForegroundRefresh()
        let again = await store.recoverScheduleBookingPendingWork(ownerBinding: d.binding)
        expectEqual(d.links.log, [], "\(id): the second activation reads nothing")
        expectEqual(d.queued("settings"), 0, "\(id): …and queues nothing")
        expectEqual(d.localBookingLink?.token, token, "\(id): the display copy is unchanged")
        expect(again.reappliedMirrors == 0 && again.retained == 0, "\(id): the third pass finds nothing to do")
    }

    // MARK: L. Launch: the gate-open points

    /// The first sign-in's starting point opens the signed-in gate (as the
    /// subscription gate and a returning launch do): recovery runs there,
    /// without waiting for a scene activation.
    @MainActor
    static func launchGateOpenRecovers() async {
        let id = "L launch gate open"
        let d = bookingDevice("l", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.failSnapshotSaves(true)
        _ = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        d.failSnapshotSaves(false)
        expectEqual(d.items.count, 1, "\(id): sanity: one item is staged")
        let relaunched = d.launch()
        await d.signIn(relaunched)
        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
            accountBinding: d.binding, stage: .personalized,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        do { try relaunched.completeStartingPoint(.fresh) } catch {
            expect(false, "\(id): sanity: the starting point completes (\(error))")
        }
        for _ in 0..<200 where !d.items.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the gate-open recovery removes the item")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id) [P12-013]: …with the server's token")
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

    // MARK: S. Source pins: where recovery runs, and where it does not

    @MainActor
    static func sources(_ root: URL) {
        func read(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        func body(_ source: String, from start: String, to end: String = "\n    }\n") -> String? {
            guard let lower = source.range(of: start),
                  let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)
            else { return nil }
            return String(source[lower.lowerBound..<upper.upperBound])
        }
        let store = read("native/TradeReadyNative/AppStore.swift")
        let app = read("native/TradeReadyNative/TradeReadyNativeApp.swift")
        expect(!store.isEmpty && !app.isEmpty, "S: sources found")
        let launch = "startScheduleBookingRecoveryIfPossible()"
        // Activation: TradeReadyNativeApp's `.active` task runs the
        // foreground refresh, which recovers after its sync.
        let active = body(app, from: "case .active:", to: "case .background:") ?? ""
        expect(active.contains("await store.performForegroundRefresh()"), "S: activation runs the foreground refresh")
        let foreground = body(store, from: "    func performForegroundRefresh() async {") ?? ""
        expect(foreground.contains("await recoverScheduleBookingPendingWorkIfPossible()"),
               "S [P12-013]: the foreground refresh recovers pending booking and portal work")
        if let sync = foreground.range(of: "await syncNowAndWait(trigger: .foreground)"),
           let recover = foreground.range(of: "await recoverScheduleBookingPendingWorkIfPossible()") {
            expect(sync.lowerBound < recover.lowerBound, "S: …after its sync, so the pulled request states are current")
        }
        // Launch: every point that opens the signed-in gate after the
        // initial sync (the same points that replay widget actions).
        let subscription = body(store, from: "    private func advancePastSubscriptionGate() {") ?? ""
        expect(subscription.contains(launch), "S [P12-013]: the subscription gate's signed-in exit starts recovery")
        let startingPoint = body(store, from: "    func completeStartingPoint(") ?? ""
        expect(startingPoint.contains(launch), "S [P12-013]: the starting point's exit starts recovery")
        let consumers = body(store, from: "        if activateConsumers, case .signedIn = authenticationGateState {",
                             to: "\n        }\n") ?? ""
        expect(consumers.contains(launch), "S [P12-013]: a returning launch's signed-in gate starts recovery")
        // Never from the rollback-readiness check (section L of those
        // tests: the check never removes booking work).
        let readiness = body(store, from: "    private func prepareRollbackReadiness(\n") ?? ""
        expect(!readiness.isEmpty && !readiness.contains("recoverScheduleBookingPendingWork"),
               "S: the rollback-readiness check never recovers")
        // The pass re-checks the account boundary after its awaits.
        let recovery = body(store, from: "    func recoverScheduleBookingPendingWork(") ?? ""
        expect(recovery.contains("accountBoundaryGeneration"), "S: recovery compares the account generation")
    }
}
