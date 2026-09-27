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
// Fix round 1 (review I1): a mirror is read and merged only after a pull
// has committed since the identity was applied or the foreground refresh
// began, and a flag-only mirror's read carries the local token (W1, W2, X,
// L2): a merge queues the whole settings or customer record, and the push
// runs before the pull.
//
// Section F (12.00b.2-J, P12-015): the owner accepts a customer's reschedule
// request from the Today and Requests rows. Characterized before its fix
// (the test commit before it): both rows built a schedule draft from the
// request's original slot with the request's status as the job's baseline,
// which always conflicted, so nothing was sent, nothing was shown and the
// conflict text was left in `migrationMessage`. Since the fix, both rows call
// `acceptBookingReschedule`: it writes nothing to the job, resolves with a
// proof of the job's current schedule once the owner's move has reached the
// server, and every outcome is shown on the screen the owner acted on.
//
// Section K (12.00b.2-K, P12-016): a customer's booking arrives through a pull
// (as the Worker writes the request row) on a native-only account. Plan 8.08's
// atomic intake (`runBookingIntakeAfterVerifiedPull`) had no production
// caller, so neither a cold launch nor a warm activation turned the booking
// into a lead job and a customer, and a later reschedule accept answered
// `notLinkedToJob`. RN converts at launch after the initial sync and after
// every foreground sync (`App.tsx:396`, `context/AuthContext.tsx:118-120`).
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

/// The data server as the delta pull reads it (12.00b.2-K). It can run a hook
/// inside the next read of one table (an account change during the pull's
/// network await) and can stop answering reads (a pull started after that
/// point fails). The push writes to the data server directly.
final class PullLoader: NativeInitialSyncHTTPDataLoading, @unchecked Sendable {
    let data: InMemorySupabase
    var duringNextRead: (table: String, hook: @MainActor () async -> Void)?
    var readsFail = false

    init(data: InMemorySupabase) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod == "GET" {
            if readsFail { throw URLError(.notConnectedToInternet) }
            if let pending = duringNextRead, pending.table == request.url?.lastPathComponent {
                duringNextRead = nil
                await pending.hook()
            }
        }
        return try await data.data(for: request)
    }
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
    /// The token each status read carried (nil when it sent none).
    private(set) var statusTokens: [String?] = []
    /// Runs on the main actor inside the next status read, before it replies.
    var duringNextStatus: (@MainActor () async -> Void)?
    /// Runs on the main actor inside the next respond call, before the
    /// server reads the request (P12-015: an account change or another
    /// device's decision during the resolve's await).
    var duringNextRespond: (@MainActor () async -> Void)?
    /// The `scheduleProof` each `resolve_reschedule` carried, as
    /// "jobId date start updatedAt" ("none" when it sent none).
    private(set) var respondProofs: [String] = []
    private var minted = 0

    init(data: InMemorySupabase, userID: String) {
        self.data = data
        self.userID = userID
    }

    var statusReads: Int { log.filter { $0.hasSuffix("/status") }.count }
    var mutations: [String] { log.filter { !$0.hasSuffix("/status") } }

    func resetLog() {
        log = []
        statusTokens = []
        respondProofs = []
    }

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
        if action == "status" { statusTokens.append(body["token"] as? String) }
        if unreachable { throw URLError(.notConnectedToInternet) }
        if action == "status", let hook = duringNextStatus {
            duringNextStatus = nil
            await hook()
        }
        if family == "respond", action == "resolve_reschedule" {
            if let proof = body["scheduleProof"] as? [String: Any] {
                respondProofs.append(["jobId", "date", "start", "updatedAt"]
                    .map { proof[$0] as? String ?? "?" }.joined(separator: " "))
            } else {
                respondProofs.append("none")
            }
        }
        if family == "respond", let hook = duringNextRespond {
            duringNextRespond = nil
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

func fixtureRequest(status: String = "reschedule_requested", converted: Bool = true) -> Canonical.BookingRequest {
    decodeRecord(Canonical.BookingRequest.self, """
    {"id":"req-1","status":"\(status)","kind":"booked","name":"Sam Ortiz","phone":"555-0177",
     "email":"sam@example.test","address":"9 Oak Ave","details":"Panel inspection","preferredTiming":"",
     "createdAt":"2026-09-10T00:00:00.000Z"\(converted ? #","convertedJobId":"job-1""# : ""),
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

/// A proof whose request is not on the device: any pass removes it (T1),
/// after the items staged before it. A test stages it last and waits for it
/// to go, to know that a pass started at a gate site has finished.
let passMarkerProof = NativeScheduleBookingPendingWork.Kind.rescheduleProof(
    requestId: "req-pass-marker",
    proof: NativeScheduleProof(jobId: "job-pass-marker", updatedAt: writeStamp, date: "2026-09-23", start: "09:00"),
    writeStamp: writeStamp
)

func isPassMarker(_ item: NativeScheduleBookingPendingWork) -> Bool {
    if case let .rescheduleProof(requestId, _, _) = item.kind { return requestId == "req-pass-marker" }
    return false
}

func isMirror(_ item: NativeScheduleBookingPendingWork) -> Bool {
    switch item.kind {
    case .bookingMirror, .portalMirror: return true
    case .rescheduleProof: return false
    }
}

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
    let pullLoader: PullLoader
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
        pullLoader = PullLoader(data: data)
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
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: pullLoader
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
        prepareOwner(store, subject: subject, binding: binding)
        store.testSeedNativeSignedInOwner(subject: subject, binding: binding)
        store.testMarkInitialSyncCompleted(subject: subject)
        for _ in 0..<20 { await Task.yield() }
        connect(store, subject: subject)
    }

    /// The owner's completed workspace document, session and link clients on
    /// a launched AppStore. The gate stays where the launch left it.
    func prepareOwner(_ store: AppStore, subject: String? = nil, binding: String? = nil) {
        let subject = subject ?? self.subject
        let binding = binding ?? self.binding
        try? NativeOnboardingStore(snapshotURL: storeURL).save(NativeOnboardingDocument(
            accountBinding: binding, stage: .done,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        store.scheduleBookingTestCredentials = NativeSyncCredentials(subject: subject, sessionBytes: Self.session)
        store.scheduleBookingSessionOverride = Self.session
        store.scheduleBookingRecoveryAdminService = bookingService
        store.scheduleBookingRecoveryPortalService = portalService
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

    var hasPassMarker: Bool { items.contains(where: isPassMarker) }

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
        await returningLaunchGateRecovers()
        await warmActivationBookingMirror()
        await warmActivationPortalMirror()
        await flagOnlyMirrorWithADeadLocalLink()
        await acceptAfterTheOwnerMovedTheJob()
        await acceptBeforeTheOwnerMovedTheJob()
        await acceptOutcomesOnTheActingScreen()
        await accountChangeDuringTheResolve()
        await s1GuardTheResolveNeverMovesTheJobBack()
        acceptNoticesOnBothScreens()
        await coldLaunchConvertsAfterTheInitialSync()
        await warmActivationConvertsAfterItsPull()
        await failedOrPartialPullConvertsNothing()
        await intakeIsIdempotent()
        await anExistingLeadJobIsNeverOverwritten()
        await accountChangeDuringTheIntakePull()
        await nothingBeforeTheInitialSync()
        await nothingWhileReadOnly()
        await aFailedIntakeSaveLeavesNoMessage()
        await acceptAfterIntakeIsLinkedToTheJob()
        sources(root)
        intakeSources(root)

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
    /// without waiting for a scene activation. The initial sync's pull has
    /// committed by then (fix round 1: a mirror needs a committed pull).
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
        // The initial sync's committed pull. This host binary cannot run the
        // full pull (`beginInitialSyncGate` needs a configured build), so the
        // real delta pull and commit stand in for it.
        _ = await relaunched.testPullDeltaIfPossible()
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

    @MainActor
    static func isSignedIn(_ store: AppStore) -> Bool {
        if case .signedIn = store.authenticationGateState { return true }
        return false
    }

    /// Waits (bounded) until a pass started at a gate site has finished: the
    /// pass-marker proof, staged last, is gone.
    @MainActor
    static func waitForGateSitePass(_ d: Device) async {
        for _ in 0..<200 where d.hasPassMarker {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// L2 (review M5): a returning launch. The owner's sync completed on an
    /// earlier launch (the offline-fallback cold launch, or a warm process
    /// verified again), so no initial sync runs: the identity is applied
    /// (`applyAuthenticatedIdentityOutcome`'s returning-user branch, through
    /// `testActivateReturningUserSession`) and the subscription gate's exit
    /// opens the signed-in gate. The pass runs there, before any activation:
    /// the proof that can no longer resolve is removed. The mirror waits,
    /// unread and unmerged, because no pull has committed since the identity
    /// was applied; the activation's pull, then its pass, applies it.
    /// Characterized at b974125: that pass read and merged the mirror into
    /// the pre-pull snapshot.
    @MainActor
    static func returningLaunchGateRecovers() async {
        let id = "L2 returning launch"
        let d = bookingDevice("l2", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.failSnapshotSaves(true)
        _ = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        d.failSnapshotSaves(false)
        d.stage(passMarkerProof)
        expectEqual(d.items.count, 2, "\(id): sanity: a mirror and a proof are staged")
        d.links.resetLog()
        let relaunched = d.launch()
        d.prepareOwner(relaunched)
        expect(!isSignedIn(relaunched), "\(id): sanity: the launch starts with the signed-in gate closed")
        relaunched.testActivateReturningUserSession(subject: d.subject, binding: d.binding)
        await waitForGateSitePass(d)
        let reads = d.links.log
        observed(id, "gate=\(isSignedIn(relaunched) ? "signedIn" : "closed") proofRemoved=\(!d.hasPassMarker) "
                 + "reads=\(reads) items=\(d.items.count)")
        expect(isSignedIn(relaunched), "\(id): sanity: the subscription gate's exit opened the signed-in gate")
        expect(!d.hasPassMarker, "\(id) [P12-013]: the gate-open pass removes the proof that can no longer resolve")
        expectEqual(reads, [], "\(id) [I1]: …and reads no mirror status before a pull")
        expectEqual(d.items.filter(isMirror).count, 1, "\(id) [I1]: the mirror waits")
        expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id) [I1]: nothing is merged")
        expectEqual(d.queued("settings"), 0, "\(id) [I1]: nothing is queued")
        d.connect(relaunched, subject: d.subject)
        await relaunched.performForegroundRefresh()
        expectEqual(d.links.statusReads, 1, "\(id): the activation's pass reads the status once")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the activation's pull, then its pass, applies the mirror")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id) [P12-013]: …with the server's token")
    }

    // MARK: W. A warm activation: a mirror merges only after the pull (review I1)

    /// The first half of a warm activation. `TradeReadyNativeApp`'s `.active`
    /// task verifies the identity again (`activateMigratedAuthenticatedIdentity`,
    /// which stops at its `BuildEnvironment` guard in this host binary) and
    /// applies it through `applyAuthenticatedIdentityOutcome`'s returning-user
    /// branch while the gate is already signed in: its consumer block, and
    /// the subscription gate it resolves again, both start a pass before the
    /// foreground refresh runs. Waits for that pass to finish.
    @MainActor
    static func applyIdentityAgain(_ store: AppStore, _ d: Device) async {
        expect(isSignedIn(store), "sanity: a warm activation starts with the signed-in gate open")
        store.testActivateReturningUserSession(subject: d.subject, binding: d.binding)
        await waitForGateSitePass(d)
        expect(!d.hasPassMarker, "sanity: the warm activation's gate-site pass ran")
    }

    /// W1: a flag-only booking mirror (a Disable whose local save failed) is
    /// on the device, and another device has since rotated the link and
    /// saved its settings with another field changed. The warm activation's
    /// gate-site pass starts before the foreground pull, so it reads and
    /// merges nothing: a merge queues the whole settings record, and the push
    /// runs before the pull. The foreground refresh pulls, then its pass reads
    /// the status with the pulled local token and merges the server's flag.
    /// The other device's field and token survive in the cloud row.
    /// Characterized at b974125: the gate-site pass merged into the pre-pull
    /// settings, and the push wrote the old token and name over the row.
    @MainActor
    static func warmActivationBookingMirror() async {
        let id = "W1 warm activation, booking"
        let d = bookingDevice("w1", link: (bookingTokenA, true))
        defer { d.cleanup() }
        var later = ""
        var readsBeforeRefresh = -1
        var queuedBeforeRefresh = -1
        var keptBeforeRefresh = -1
        _ = await stageThenRelaunch(d, id, beforeActivation: { store in
            later = d.links.freshToken()
            d.links.bookingToken = later
            d.links.bookingEnabled = true
            d.links.bookingRevision += 1
            if var row = await d.links.settingsRow() {
                row["businessName"] = "Ada Electric & Sons"
                row["bookingLink"] = ["token": later, "enabled": true]
                await d.links.upsertSettings(row)
            }
            d.stage(passMarkerProof)
            await applyIdentityAgain(store, d)
            readsBeforeRefresh = d.links.statusReads
            queuedBeforeRefresh = d.queued("settings")
            keptBeforeRefresh = d.items.filter(isMirror).count
        }) { store in
            String(describing: await store.administerBookingLink(action: .setEnabled, enabled: false,
                                                                 adminService: d.bookingService))
        }
        let row = await d.links.settingsRow()
        let cloud = await d.cloudBookingLink()
        observed(id, "before the refresh: reads=\(readsBeforeRefresh) queued=\(queuedBeforeRefresh) "
                 + "mirrors=\(keptBeforeRefresh); cloud name=\(row?["businessName"] as? String ?? "nil") "
                 + "token=\(cloud.token == later ? "other device's" : "other") items=\(d.items.count)")
        expectEqual(readsBeforeRefresh, 0, "\(id) [I1]: the gate-site pass reads nothing before the pull")
        expectEqual(queuedBeforeRefresh, 0, "\(id) [I1]: …and queues no settings record")
        expectEqual(keptBeforeRefresh, 1, "\(id) [I1]: …and keeps the mirror for a pass after the pull")
        expectEqual(row?["businessName"] as? String, "Ada Electric & Sons",
                    "\(id) [I1]: the other device's field survives in the cloud row")
        expectEqual(cloud.token, later, "\(id) [I1]: …and so does its token")
        expectEqual(cloud.enabled, true, "\(id): the cloud row has the server's flag")
        expectEqual(d.links.statusTokens, [later], "\(id) [I1]: the one status read carries the pulled local token")
        expectEqual(d.localBookingLink?.token, later, "\(id): the display copy has the current token")
        expectEqual(d.disk?.payload.settings?.businessName, "Ada Electric & Sons",
                    "\(id): …and the other device's field")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the mirror is applied after the pull and removed")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
    }

    /// W2: the same for a portal: a flag-only portal mirror, and another
    /// device has since rotated the portal and saved the customer with its
    /// notes changed. A portal merge queues the whole customer record.
    /// Characterized at b974125: the push wrote the old token and notes over
    /// the cloud customer row.
    @MainActor
    static func warmActivationPortalMirror() async {
        let id = "W2 warm activation, portal"
        let d = portalDevice("w2", portal: (portalTokenC, true))
        defer { d.cleanup() }
        var later = ""
        var readsBeforeRefresh = -1
        var queuedBeforeRefresh = -1
        var keptBeforeRefresh = -1
        _ = await stageThenRelaunch(d, id, beforeActivation: { store in
            later = d.links.freshToken()
            d.links.portals["cust-1"] = (later, true)
            if var row = d.links.row("customers", "cust-1") {
                row["notes"] = "Gate code 4411"
                row["portal"] = ["token": later, "enabled": true]
                await d.links.upsert(table: "customers", id: "cust-1", record: row)
            }
            d.stage(passMarkerProof)
            await applyIdentityAgain(store, d)
            readsBeforeRefresh = d.links.statusReads
            queuedBeforeRefresh = d.queued("customers")
            keptBeforeRefresh = d.items.filter(isMirror).count
        }) { store in
            String(describing: await store.administerPortalLink(customerID: "cust-1", action: .setEnabled, enabled: false,
                                                                portalService: d.portalService))
        }
        let row = d.links.row("customers", "cust-1")
        let cloud = d.cloudPortal()
        observed(id, "before the refresh: reads=\(readsBeforeRefresh) queued=\(queuedBeforeRefresh) "
                 + "mirrors=\(keptBeforeRefresh); cloud notes=\(row?["notes"] as? String ?? "nil") "
                 + "token=\(cloud.token == later ? "other device's" : "other") items=\(d.items.count)")
        expectEqual(readsBeforeRefresh, 0, "\(id) [I1]: the gate-site pass reads nothing before the pull")
        expectEqual(queuedBeforeRefresh, 0, "\(id) [I1]: …and queues no customer record")
        expectEqual(keptBeforeRefresh, 1, "\(id) [I1]: …and keeps the mirror for a pass after the pull")
        expectEqual(row?["notes"] as? String, "Gate code 4411",
                    "\(id) [I1]: the other device's field survives in the cloud customer row")
        expectEqual(cloud.token, later, "\(id) [I1]: …and so does its portal token")
        expectEqual(cloud.enabled, true, "\(id): the cloud row has the server's flag")
        expectEqual(d.links.statusTokens, [later], "\(id) [I1]: the one status read carries the pulled local token")
        expectEqual(d.localPortal?.token, later, "\(id): the display copy has the current token")
        expectEqual(d.disk?.payload.customers?.first?.notes, "Gate code 4411", "\(id): …and the other device's notes")
        expectEqual(d.items.count, 0, "\(id) [P12-013]: the mirror is applied after the pull and removed")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
    }

    /// X: a flag-only booking mirror whose local link the server no longer
    /// has. Another device rotated the link and then disabled it, and neither
    /// of its settings saves reached the cloud, so the pull brings nothing.
    /// The status read carries the local token and the server says it is not
    /// current, so recovery applies nothing and drops the item: it never
    /// writes back a token the server did not confirm. The screen shows the
    /// local link as needing recovery; the other device's own save brings
    /// the current one.
    /// Characterized at b974125: the read sent no token, the server's flag
    /// was merged into the dead link and the push wrote it to the cloud row.
    @MainActor
    static func flagOnlyMirrorWithADeadLocalLink() async {
        let id = "X flag-only mirror, dead local link"
        let d = bookingDevice("x", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let store = await stageThenRelaunch(d, id, beforeActivation: { _ in
            d.links.bookingToken = d.links.freshToken()
            d.links.bookingEnabled = false
            d.links.bookingRevision += 2
        }) { store in
            String(describing: await store.administerBookingLink(action: .setEnabled, enabled: false,
                                                                 adminService: d.bookingService))
        }
        let recoveryReads = d.links.statusTokens
        let cloud = await d.cloudBookingLink()
        let title = await bookingScreen(store, d)
        observed(id, "read token=\(recoveryReads.map { $0 == bookingTokenA ? "local" : ($0 == nil ? "none" : "other") }) "
                 + "local.enabled=\(d.localBookingLink?.enabled.description ?? "nil") "
                 + "cloud.enabled=\(cloud.enabled?.description ?? "nil") items=\(d.items.count) screen=\(title)")
        expectEqual(recoveryReads, [bookingTokenA], "\(id) [I1]: the one status read carries the local token")
        expectEqual(d.items.count, 0, "\(id): the server does not confirm it: the item is dropped")
        expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id): the display copy keeps its token (none is invented)")
        expectEqual(d.localBookingLink?.enabled, true, "\(id) [I1]: …and nothing is merged into the dead link")
        expectEqual(cloud.token, bookingTokenA, "\(id): the cloud row keeps its token")
        expectEqual(cloud.enabled, true, "\(id) [I1]: …and recovery writes nothing back to it")
        expectEqual(d.links.mutations, [], "\(id): recovery never changes the server")
        expectEqual(title, "Needs recovery", "\(id): the owner's screen never offers the dead link")
    }

    // MARK: F. Accepting a customer's reschedule from the request rows (P12-015)

    /// The two screens with a reschedule row action.
    enum RescheduleRow: String, CaseIterable {
        case today = "Today"
        case requests = "Requests"

        /// The button the owner taps: Today's alert action (RN
        /// `screens/TodayScreen.tsx:613`) or the Requests row's button.
        var actionLabel: String { self == .today ? "I've rescheduled it" : "Resolve" }
    }

    /// What the owner's tap did, as the acting screen shows it.
    struct RowTap {
        var outcome: String
        /// The acting screen's alert, or nil when it shows nothing.
        var title: String? = nil
        var message: String? = nil
    }

    /// The owner's tap on a reschedule row, running the code that screen runs:
    /// `TodayView.resolveBookingReschedule` and
    /// `NativeBookingRequestsView.resolveReschedule` both call
    /// `acceptBookingReschedule(requestID:)` and show its `ownerNotice` for
    /// their own button (the S pins hold them to it). The one difference is
    /// the injected respond client.
    ///
    /// Characterization (the test commit before the fix) ran the code those
    /// actions had at 52ba5ac instead: without a job both returned silently;
    /// otherwise both built a schedule draft with nil baselines, the
    /// REQUEST's status as the job's baseline and `request.slot` (the
    /// original booked slot) as the target, resolved only on `.proofReady`,
    /// and showed nothing for any outcome.
    @MainActor
    static func tap(_ row: RescheduleRow, _ store: AppStore, _ d: Device) async -> RowTap {
        guard let attention = store.bookingAttentionRows().first(where: { $0.request.id == "req-1" }) else {
            return RowTap(outcome: "no row")
        }
        let outcome = await store.acceptBookingReschedule(requestID: attention.request.id,
                                                          responseService: d.respondService)
        let notice = outcome.ownerNotice(actionLabel: row.actionLabel)
        return RowTap(outcome: String(describing: outcome), title: notice.title, message: notice.message)
    }

    /// `fixtureRequest`'s slot (the original booked slot) and the time the
    /// owner moves the job to, as the acting screen writes them.
    static let requestSlotWhen = "Wednesday, September 23, 9:00 AM – 10:00 AM"
    static let movedWhen = "Friday, September 25, 1:00 PM – 2:00 PM"
    static let failureTitle = "Couldn't update booking"

    /// A device with job-1 and a reschedule request for it, signed in, with
    /// the workspace pushed.
    @MainActor
    static func rescheduleDevice(
        _ tag: String, job: Canonical.Job = fixtureJob(), converted: Bool = true
    ) async -> (Device, AppStore) {
        let d = Device(tag, customers: [fixtureCustomer(portal: nil)], jobs: [job],
                       requests: [fixtureRequest(converted: converted)])
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        return (d, store)
    }

    /// The owner moves job-1 in the schedule editor: `NativeScheduleEditorView`
    /// saves `commitScheduleOnly` with a draft pinned to the current record.
    @MainActor
    static func ownerMovesTheJob(_ store: AppStore) -> Bool {
        guard var draft = store.scheduleOnlyDraft(jobID: "job-1") else { return false }
        draft.date = "2026-09-25"
        draft.start = "13:00"
        draft.end = "14:00"
        return store.commitScheduleOnly(draft) == .saved(conflictingJobIDs: [])
    }

    /// job-1's "date start end" on the device and in the cloud row.
    @MainActor
    static func jobSchedule(_ d: Device) -> (local: String, cloud: String) {
        let local = d.disk?.payload.jobs?.first { $0.id == "job-1" }
        let cloud = d.links.row("jobs", "job-1")
        return (
            [local?.scheduledDate, local?.scheduledStartTime, local?.scheduledEndTime].map { $0 ?? "-" }.joined(separator: " "),
            ["scheduledDate", "scheduledStartTime", "scheduledEndTime"].map { cloud?[$0] as? String ?? "-" }.joined(separator: " ")
        )
    }

    /// F1: the owner has moved the job, in RN's order ("View job", move it,
    /// then "I've rescheduled it", `screens/TodayScreen.tsx:607-616`). The
    /// tap resolves with a proof of the job's CURRENT schedule, writes
    /// nothing to the job and says what it did on the acting screen.
    /// Characterized: `.scheduleConflict` from the row's draft, nothing
    /// sent, nothing shown, and the conflict text left in `migrationMessage`.
    @MainActor
    static func acceptAfterTheOwnerMovedTheJob() async {
        for row in RescheduleRow.allCases {
            let id = "F1 \(row.rawValue): the owner moved the job"
            let (d, store) = await rescheduleDevice("f1-\(row.rawValue)")
            defer { d.cleanup() }
            expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
            expectEqual(store.migrationMessage, nil, "\(id): sanity: no message before the tap")
            d.links.resetLog()
            let tapped = await tap(row, store, d)
            let schedule = jobSchedule(d)
            observed(id, "outcome=\(tapped.outcome) shown=\(tapped.message ?? "nothing") "
                     + "migrationMessage=\(store.migrationMessage ?? "nil") sent=\(d.links.log) "
                     + "server=\(d.links.requestRow("req-1")?["status"] as? String ?? "?") job=\(schedule.local)")
            expectEqual(d.links.log, ["respond/resolve_reschedule"], "\(id) [P12-015]: one resolve is sent")
            expectEqual(d.links.respondProofs, ["job-1 2026-09-25 13:00 2026-09-10T00:00:00.000Z"],
                        "\(id) [P12-015]: its proof is the job's current schedule, stamped with the request's createdAt")
            expectEqual(d.links.requestRow("req-1")?["status"] as? String, "confirmed",
                        "\(id) [P12-015]: the server confirms the booking")
            expectEqual(tapped.title, "Booking updated", "\(id) [P12-015]: the acting screen says so")
            expectEqual(tapped.message, "The booking is confirmed for the job's new time, \(movedWhen).",
                        "\(id) [P12-015]: …with the job's new time")
            expectEqual(store.migrationMessage, nil, "\(id) [P12-015]: nothing goes to migrationMessage")
            expectEqual(schedule.local, "2026-09-25 13:00 14:00", "\(id) [P12-015]: the job keeps the owner's time")
            expectEqual(schedule.cloud, "2026-09-25 13:00 14:00", "\(id) [P12-015]: …in the cloud row too")
            expectEqual(d.queued("jobs"), 0, "\(id) [P12-015]: the move reached the server and the resolve queues no job write")
            expectEqual(d.queued("bookingRequests"), 0, "\(id) [P12-015]: …nor a copy of the request (the server wrote it)")
            expect(!store.bookingAttentionRows().contains { $0.request.id == "req-1" }, "\(id) [P12-015]: the row clears")
            expectEqual(d.items.count, 0, "\(id) [P12-015]: the proof is removed once the server confirms")
            expectEqual(store.rollbackReadiness().bookingWorkCount, 0, "\(id): the rollback check counts no booking work")
            await d.sync()
            expectEqual(d.localRequestStatus, "confirmed",
                        "\(id) [P12-015]: after the pull the request no longer asks for a reschedule")
            expectEqual(jobSchedule(d).local, "2026-09-25 13:00 14:00", "\(id) [P12-015]: …and the job keeps the owner's time")
        }
    }

    /// F2: the owner taps before moving the job, which is still at the
    /// request's original slot. RN sends the resolve regardless
    /// (`screens/TodayScreen.tsx:613-616`); the Worker reads no proof
    /// (`backend-workers/src/routes/booking/respond.js:35-40`) and contract
    /// §7's check is the job's own `(date, start)`, so a move is not
    /// required: native sends it too and says plainly that the time did not
    /// change.
    @MainActor
    static func acceptBeforeTheOwnerMovedTheJob() async {
        for row in RescheduleRow.allCases {
            let id = "F2 \(row.rawValue): the job is still at the original slot"
            var job = fixtureJob()
            job.scheduledDate = "2026-09-23"
            let (d, store) = await rescheduleDevice("f2-\(row.rawValue)", job: job)
            defer { d.cleanup() }
            d.links.resetLog()
            let tapped = await tap(row, store, d)
            let schedule = jobSchedule(d)
            observed(id, "outcome=\(tapped.outcome) shown=\(tapped.message ?? "nothing") "
                     + "migrationMessage=\(store.migrationMessage ?? "nil") sent=\(d.links.log)")
            expectEqual(d.links.log, ["respond/resolve_reschedule"], "\(id) [P12-015]: the resolve is sent, as RN sends it")
            expectEqual(d.links.respondProofs, ["job-1 2026-09-23 09:00 2026-09-10T00:00:00.000Z"],
                        "\(id) [P12-015]: its proof is the job's current schedule")
            expectEqual(d.links.requestRow("req-1")?["status"] as? String, "confirmed", "\(id) [P12-015]: the server confirms")
            expectEqual(tapped.title, "Booking updated", "\(id) [P12-015]: the acting screen says so")
            expectEqual(tapped.message,
                        "The job wasn't moved, so the booking is confirmed for its original time, \(requestSlotWhen).",
                        "\(id) [P12-015]: …and that the time did not change")
            expectEqual(store.migrationMessage, nil, "\(id) [P12-015]: nothing goes to migrationMessage")
            expectEqual(schedule.local, "2026-09-23 09:00 10:00", "\(id): the job's schedule is unchanged")
            expectEqual(schedule.cloud, "2026-09-23 09:00 10:00", "\(id): …in the cloud row too")
            expectEqual(d.queued("jobs") + d.queued("bookingRequests"), 0, "\(id): nothing is queued")
        }
    }

    /// Every outcome other than a confirmation, from each acting screen.
    enum AcceptCase: String, CaseIterable {
        case unscheduledJob = "F3a the job has no start time"
        case noJob = "F3b the request has no job"
        case notAcknowledged = "F3c the move has not reached the server"
        case declinedBeforeTheTap = "F3d declined on another device before the tap"
        case declinedDuringTheResolve = "F3e declined on another device during the resolve"
        case scheduleChanged = "F3f the server says the schedule changed"
        case deletedBeforeTheTap = "F3g the request was deleted before the tap"
        case deletedDuringTheResolve = "F3h the request was deleted during the resolve"
        case lostAfterCommit = "F3i unknown outcome (the server committed)"
        case lostBeforeCommit = "F3j unknown outcome (the server did not commit)"
        case unreachable = "F3k the resolve cannot reach the server"
        case rateLimited = "F3l rate limited"
        case requestCopyQueued = "F3m a copy of the request has not reached the server"
    }

    /// F3: each non-success outcome is shown on the acting screen in plain
    /// words (title as RN's failure alert, `screens/TodayScreen.tsx:557`),
    /// nothing goes to `migrationMessage`, and the job's schedule is never
    /// changed by the tap. A proof is staged just before the resolve is sent
    /// and kept or removed only by the rules that were already there (the
    /// success path, and Task 12b's recovery). Characterized: nothing shown
    /// in every case.
    @MainActor
    static func acceptOutcomesOnTheActingScreen() async {
        for acceptCase in AcceptCase.allCases {
            for row in RescheduleRow.allCases {
                await acceptOutcome(acceptCase, row)
            }
        }
    }

    @MainActor
    static func acceptOutcome(_ acceptCase: AcceptCase, _ row: RescheduleRow) async {
        let id = "\(acceptCase.rawValue) (\(row.rawValue))"
        let tag = "f3-\(AcceptCase.allCases.firstIndex(of: acceptCase) ?? 0)-\(row.rawValue)"
        var job = fixtureJob()
        if acceptCase == .unscheduledJob {
            job.scheduledDate = "2026-09-25"
            job.scheduledStartTime = nil
            job.scheduledEndTime = nil
        }
        let (d, store) = await rescheduleDevice(tag, job: job, converted: acceptCase != .noJob)
        defer { d.cleanup() }
        if acceptCase == .notAcknowledged { d.reach.online = false }
        if acceptCase != .unscheduledJob, acceptCase != .noJob {
            expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
        }
        let movedSchedule = acceptCase == .unscheduledJob ? "2026-09-25 - -"
            : acceptCase == .noJob ? "2026-09-22 09:00 10:00" : "2026-09-25 13:00 14:00"
        switch acceptCase {
        case .requestCopyQueued:
            // The move has reached the server; an older copy of the request
            // has not (pushed after the resolve, it would put the old status
            // back on the server row).
            await d.sync()
            d.reach.online = false
            _ = try? d.queue.enqueue(table: "bookingRequests", op: .upsert, recordId: "req-1",
                                     payload: .object(["id": .string("req-1")]))
        case .declinedBeforeTheTap:
            if var row = d.links.requestRow("req-1") {
                row["status"] = "declined"
                await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
            }
        case .declinedDuringTheResolve:
            d.links.duringNextRespond = {
                if var row = d.links.requestRow("req-1") {
                    row["status"] = "declined"
                    await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
                }
            }
        case .deletedBeforeTheTap:
            await d.links.delete(table: "bookingRequests", id: "req-1")
        case .deletedDuringTheResolve:
            d.links.duringNextRespond = { await d.links.delete(table: "bookingRequests", id: "req-1") }
        case .scheduleChanged: d.links.respondMode = .scheduleChanged
        case .lostAfterCommit: d.links.respondMode = .lostAfterCommit
        case .lostBeforeCommit: d.links.respondMode = .lostBeforeCommit
        case .rateLimited: d.links.respondMode = .rateLimited
        case .unreachable: d.links.unreachable = true
        case .unscheduledJob, .noJob, .notAcknowledged: break
        }
        d.links.resetLog()
        let tapped = await tap(row, store, d)
        d.links.respondMode = .normal
        d.links.unreachable = false
        let label = row.actionLabel
        let unknown = "We couldn't tell whether the booking was updated. "
            + "Check your connection, then pull down to refresh before trying again."
        let expected: (sent: Bool, message: String, proofKept: Bool) = switch acceptCase {
        case .unscheduledJob: (false, "Give the job a date and start time first, then tap “\(label)” again.", false)
        case .noJob: (false, "This booking isn't linked to a job on this device yet. Pull down to refresh, then try again.", false)
        case .notAcknowledged, .requestCopyQueued:
            (false, "Your latest changes haven't reached the server yet. Check your connection, then tap “\(label)” again.", true)
        case .declinedBeforeTheTap: (false, "This booking was already declined.", false)
        case .declinedDuringTheResolve: (true, "This booking was already declined.", true)
        case .scheduleChanged:
            (true, "The job's time on the server doesn't match this device. "
                + "Pull down to refresh, check the job, then tap “\(label)” again.", true)
        case .deletedBeforeTheTap: (false, "This booking request wasn't found. It may have been removed on another device.", false)
        case .deletedDuringTheResolve: (true, "This booking request wasn't found. It may have been removed on another device.", true)
        case .lostAfterCommit, .lostBeforeCommit, .unreachable: (true, unknown, true)
        case .rateLimited: (true, "Too many booking responses. Wait a moment and try again.", true)
        }
        observed(id, "outcome=\(tapped.outcome) shown=\(tapped.message ?? "nothing") "
                 + "migrationMessage=\(store.migrationMessage ?? "nil") sent=\(d.links.log) proofs=\(d.items.count)")
        expectEqual(d.links.log, expected.sent ? ["respond/resolve_reschedule"] : [],
                    "\(id) [P12-015]: \(expected.sent ? "one resolve is sent" : "nothing is sent")")
        expectEqual(tapped.title, failureTitle, "\(id) [P12-015]: the acting screen shows the failure")
        expectEqual(tapped.message, expected.message, "\(id) [P12-015]: …in plain words")
        expectEqual(store.migrationMessage, nil, "\(id) [P12-015]: nothing goes to migrationMessage")
        expectEqual(jobSchedule(d).local, movedSchedule, "\(id): the tap never changes the job's schedule")
        expectEqual(d.items.count, expected.proofKept ? 1 : 0,
                    "\(id): \(expected.proofKept ? "the staged proof stays for Task 12b's rules" : "no proof is staged")")
        expectEqual(d.queued("bookingRequests"), acceptCase == .requestCopyQueued ? 1 : 0,
                    "\(id): the tap queues no copy of the request")
        switch acceptCase {
        case .notAcknowledged:
            expectEqual(store.rollbackReadiness().bookingWorkCount, 1, "\(id): the rollback check counts the staged proof")
            // Back online, the owner taps again: the move is pushed first,
            // then the resolve succeeds and the proof goes.
            d.reach.online = true
            d.links.resetLog()
            let retried = await tap(row, store, d)
            expectEqual(retried.title, "Booking updated", "\(id) [P12-015]: the owner's retry confirms the booking")
            expectEqual(d.links.requestRow("req-1")?["status"] as? String, "confirmed", "\(id) [P12-015]: …on the server")
            expectEqual(jobSchedule(d).cloud, "2026-09-25 13:00 14:00", "\(id) [P12-015]: …after the move reached it")
            expectEqual(d.items.count, 0, "\(id): …and the proof goes")
        case .declinedDuringTheResolve:
            expectEqual(d.localRequestStatus, "declined", "\(id): the refresh brings the declined request")
            // Task 12b: the next activation removes a proof whose request is closed.
            await store.performForegroundRefresh()
            expectEqual(d.items.count, 0, "\(id): the next activation removes the proof (Task 12b)")
        case .lostAfterCommit:
            expectEqual(d.links.requestRow("req-1")?["status"] as? String, "confirmed", "\(id): the server confirmed")
        case .lostBeforeCommit, .unreachable, .rateLimited:
            expectEqual(d.links.requestRow("req-1")?["status"] as? String, "reschedule_requested",
                        "\(id): the server still has the request")
        default:
            break
        }
    }

    /// F4: the account changes while the resolve's request is out (a
    /// sign-out, or an account boundary that brings the same owner back,
    /// which only the account generation tells apart). Nothing is applied
    /// to the device, and the acting screen says why.
    @MainActor
    static func accountChangeDuringTheResolve() async {
        for boundary in ["sign-out", "boundary then the same owner"] {
            for row in RescheduleRow.allCases {
                let id = "F4 \(row.rawValue): \(boundary) during the resolve"
                let (d, store) = await rescheduleDevice("f4-\(boundary.count)-\(row.rawValue)")
                defer { d.cleanup() }
                expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
                d.links.duringNextRespond = {
                    if boundary == "sign-out" {
                        store.scheduleBookingTestClearOwner()
                    } else {
                        store.testApplyCompletedSignOutState()
                        store.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
                        store.testMarkInitialSyncCompleted(subject: d.subject)
                    }
                }
                d.links.resetLog()
                let tapped = await tap(row, store, d)
                observed(id, "outcome=\(tapped.outcome) shown=\(tapped.message ?? "nothing") sent=\(d.links.log) "
                         + "local=\(d.localRequestStatus ?? "gone")")
                expectEqual(d.links.log, ["respond/resolve_reschedule"], "\(id): sanity: the resolve was out")
                expect(d.localRequestStatus != "confirmed", "\(id) [P12-015]: nothing is applied to the device")
                if boundary == "sign-out" {
                    expect(store.bookingAttentionRows().contains { $0.request.id == "req-1" },
                           "\(id) [P12-015]: …nor to the live snapshot (the row is still there)")
                }
                expectEqual(d.queued("bookingRequests"), 0, "\(id) [P12-015]: nothing is queued")
                expectEqual(tapped.title, failureTitle, "\(id) [P12-015]: the acting screen says so")
                expectEqual(tapped.message, "The signed-in account changed, so nothing was saved on this device.",
                            "\(id) [P12-015]: …in plain words")
                expectEqual(store.migrationMessage, nil, "\(id) [P12-015]: nothing goes to migrationMessage")
            }
        }
    }

    /// F5 [S1 guard]: `request.slot` is the ORIGINAL booked slot, immutable
    /// history (contract §7; `request_reschedule` changes only status and
    /// history, `backend-workers/lib/booking/manage.js:24`). After the
    /// owner's move and the resolve, the job's date and start are the
    /// owner's moved values and never `request.slot`: on the device, in the
    /// cloud row, after the pull, and after a relaunch and activation. A fix
    /// that took `request.slot` as the target would move the job back to the
    /// original slot and prove it.
    @MainActor
    static func s1GuardTheResolveNeverMovesTheJobBack() async {
        for row in RescheduleRow.allCases {
            let id = "F5 [S1 guard] \(row.rawValue)"
            let (d, store) = await rescheduleDevice("f5-\(row.rawValue)")
            defer { d.cleanup() }
            let slot = fixtureRequest().slot
            expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
            _ = await tap(row, store, d)
            expectEqual(d.links.requestRow("req-1")?["status"] as? String, "confirmed", "\(id): sanity: the resolve succeeded")
            func check(_ stage: String) {
                let schedule = jobSchedule(d)
                expectEqual(schedule.local, "2026-09-25 13:00 14:00", "\(id) \(stage): the device's job has the owner's moved time")
                expectEqual(schedule.cloud, "2026-09-25 13:00 14:00", "\(id) \(stage): the cloud job has the owner's moved time")
                let local = d.disk?.payload.jobs?.first { $0.id == "job-1" }
                expect(!(local?.scheduledDate == slot?.date && local?.scheduledStartTime == slot?.start),
                       "\(id) \(stage): the job is never at request.slot")
                expectEqual(d.disk?.payload.bookingRequests?.first?.slot?.date, "2026-09-23",
                            "\(id) \(stage): request.slot is untouched history")
            }
            check("after the resolve")
            await d.sync()
            check("after the pull")
            let relaunched = d.launch()
            await d.signIn(relaunched)
            await relaunched.performForegroundRefresh()
            await d.sync()
            check("after a relaunch and activation")
        }
    }

    /// F6: every accept outcome has a plain notice for both screens, and
    /// where the owner should try again it names that screen's button. The
    /// cases the F flows do not reach (read-only data, a signed-out session,
    /// a missing build configuration, another device's confirm, the
    /// customer's cancel, a local save that fails after the server confirmed)
    /// are checked on the mapping itself.
    @MainActor
    static func acceptNoticesOnBothScreens() {
        let saved = AppStore.BookingRescheduleConfirmation(
            status: "confirmed", alreadyApplied: false, date: "2026-09-25", start: "13:00", end: "14:00",
            keptOriginalTime: false, savedLocally: true)
        var notSaved = saved
        notSaved.savedLocally = false
        let outcomes: [AppStore.BookingRescheduleAcceptOutcome] = [
            .confirmed(saved), .confirmed(notSaved), .notLinkedToJob, .jobUnscheduled, .awaitingAck,
            .needsReview(currentStatus: "declined"), .needsReview(currentStatus: "cancelled"),
            .needsReview(currentStatus: "confirmed"), .needsReview(currentStatus: "reschedule_requested"),
            .needsReview(currentStatus: "unknown"), .unknownOutcome, .missing, .accountChanged, .readOnly,
            .failed(.rejectedSession), .failed(.malformedSession), .failed(.invalidConfiguration),
            .failed(.invalidRequest), .failed(.rateLimited), .failed(.unavailable), .failed(.invalidResponse),
        ]
        let tapAgain: [AppStore.BookingRescheduleAcceptOutcome] = [
            .jobUnscheduled, .awaitingAck, .needsReview(currentStatus: "reschedule_requested"),
        ]
        for row in RescheduleRow.allCases {
            for outcome in outcomes {
                let id = "F6 \(row.rawValue) \(outcome)"
                let notice = outcome.ownerNotice(actionLabel: row.actionLabel)
                expect(!notice.message.isEmpty, "\(id) [P12-015]: a message")
                if case .confirmed = outcome {
                    expectEqual(notice.title, "Booking updated", "\(id) [P12-015]: the success title")
                } else {
                    expectEqual(notice.title, failureTitle, "\(id) [P12-015]: RN's failure title")
                }
            }
            for outcome in tapAgain {
                expect(outcome.ownerNotice(actionLabel: row.actionLabel).message.contains("tap \u{201C}\(row.actionLabel)\u{201D} again"),
                       "F6 \(row.rawValue) \(outcome) [P12-015]: names this screen's button")
            }
        }
        func message(_ outcome: AppStore.BookingRescheduleAcceptOutcome) -> String {
            outcome.ownerNotice(actionLabel: "Resolve").message
        }
        expectEqual(message(.confirmed(notSaved)),
                    "The booking is confirmed for the job's new time, \(movedWhen). "
                        + "This device couldn't save the change yet. Pull down to refresh.",
                    "F6 [P12-015]: a local save failure after the server confirmed")
        expectEqual(message(.readOnly), "This device can't save changes right now. Nothing changed on this device.",
                    "F6 [P12-015]: read-only data")
        expectEqual(message(.failed(.rejectedSession)),
                    "Your session has expired. Sign in again before responding to bookings.",
                    "F6 [P12-015]: a signed-out session")
        expectEqual(message(.needsReview(currentStatus: "cancelled")), "The customer cancelled this booking.",
                    "F6 [P12-015]: the customer's cancel")
        expectEqual(message(.needsReview(currentStatus: "confirmed")), "This booking is already confirmed.",
                    "F6 [P12-015]: another device's confirm")
    }

    // MARK: K. Customer bookings become jobs (P12-016)

    static let leadJobID = "jbk_req-1"

    /// The request row the Worker's reserve route writes for a booking
    /// (`backend-workers/lib/booking/reserve.js:123-139`): kind and status
    /// "booked", the slot the customer chose and no `convertedJobId`. The
    /// manage token is a fixture string.
    static func workerBooking() -> [String: Any] {
        [
            "id": "req-1", "status": "booked", "kind": "booked",
            "name": "Sam Ortiz", "phone": "555-0177", "email": "sam@example.test",
            "address": "9 Oak Ave", "details": "Panel inspection", "preferredTiming": "",
            "slot": ["date": "2026-09-23", "start": "09:00", "end": "10:00", "timeZone": "America/Phoenix",
                     "startUtc": "2026-09-23T16:00:00.000Z", "endUtc": "2026-09-23T17:00:00.000Z"],
            "manageToken": String(repeating: "d", count: 48),
            "history": [["at": "2026-09-10T00:00:00.000Z", "actor": "customer", "event": "booked"]],
            "createdAt": "2026-09-10T00:00:00.000Z",
        ]
    }

    /// The customer books: the Worker writes the request row.
    @MainActor
    static func customerBooks(_ d: Device) async {
        await d.links.upsert(table: "bookingRequests", id: "req-1", record: workerBooking())
    }

    /// A native-only account signed in after its initial sync, with its
    /// workspace pushed; then the customer books while the app is in the
    /// background.
    @MainActor
    static func intakeDevice(_ tag: String) async -> (Device, AppStore) {
        let d = Device(tag)
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        await customerBooks(d)
        return (d, store)
    }

    @MainActor
    static func leadJob(_ d: Device) -> Canonical.Job? {
        d.disk?.payload.jobs?.first { $0.id == leadJobID }
    }

    @MainActor
    static func bookedCustomers(_ d: Device) -> [Canonical.Customer] {
        (d.disk?.payload.customers ?? []).filter { $0.name == "Sam Ortiz" }
    }

    @MainActor
    static func bookingRequest(_ d: Device) -> Canonical.BookingRequest? {
        d.disk?.payload.bookingRequests?.first { $0.id == "req-1" }
    }

    @MainActor
    static func intakeState(_ d: Device) -> String {
        "job=\(leadJob(d).map { $0.status } ?? "none") customers=\(bookedCustomers(d).count) "
            + "linked=\(bookingRequest(d)?.convertedJobId ?? "no") queued=jobs:\(d.queued("jobs")),"
            + "customers:\(d.queued("customers")),requests:\(d.queued("bookingRequests"))"
    }

    /// The booking became the lead job `jbk_req-1` on its slot and one
    /// customer, and the request links both, keeping its status (D-B3-1).
    @MainActor
    static func expectConverted(_ d: Device, _ id: String) {
        let job = leadJob(d)
        let request = bookingRequest(d)
        let customers = bookedCustomers(d)
        expect(job != nil, "\(id) [P12-016]: the booking is the lead job \(leadJobID)")
        expectEqual(job?.status, "lead", "\(id) [P12-016]: …in the lead stage")
        expectEqual(job?.title, "Booked appointment", "\(id) [P12-016]: …titled as RN titles a booking")
        expectEqual([job?.scheduledDate, job?.scheduledStartTime, job?.scheduledEndTime].map { $0 ?? "-" }
                        .joined(separator: " "), "2026-09-23 09:00 10:00",
                    "\(id) [P12-016]: …on the booked slot (calendar and route)")
        expectEqual(customers.count, 1, "\(id) [P12-016]: one customer is created for the booking")
        expectEqual(request?.convertedJobId, leadJobID, "\(id) [P12-016]: the request links the job")
        expect(request?.convertedCustomerId != nil && request?.convertedCustomerId == customers.first?.id
               && job?.customerId == customers.first?.id, "\(id) [P12-016]: …and the customer, as the job does")
        expectEqual(request?.status, "booked", "\(id) [P12-016]: the request keeps its status (D-B3-1)")
    }

    /// Waits (bounded) for a pass a gate site started.
    @MainActor
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Gives a pass a gate site might have started time to run.
    @MainActor
    static func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// K1: a cold launch. The initial sync's pull brings the booking, then the
    /// signed-in gate opens: the booking becomes a lead job and a customer
    /// there, before any scene activation (RN converts once bootstrapping ends,
    /// `App.tsx:396`). The device goes offline right after the pull, so the
    /// drafts stay queued; the next push brings the job, the customer and the
    /// linked request to the cloud.
    /// Characterized at 9a4d845: nothing converts.
    @MainActor
    static func coldLaunchConvertsAfterTheInitialSync() async {
        let id = "K1 cold launch"
        let d = Device("k1")
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        await customerBooks(d)
        let relaunched = d.launch()
        await d.signIn(relaunched)
        // The initial sync's committed pull. This host binary cannot run the
        // full pull (`beginInitialSyncGate` needs a configured build), so the
        // real delta pull and commit stand in for it (as in L).
        _ = await relaunched.testPullDeltaIfPossible()
        expect(bookingRequest(d) != nil && bookingRequest(d)?.convertedJobId == nil,
               "\(id): sanity: the pull brought the booking, unconverted")
        expect(leadJob(d) == nil, "\(id): sanity: the pull alone converts nothing")
        d.reach.online = false
        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
            accountBinding: d.binding, stage: .personalized,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        do { try relaunched.completeStartingPoint(.fresh) } catch {
            expect(false, "\(id): sanity: the starting point completes (\(error))")
        }
        await waitUntil { leadJob(d) != nil }
        observed(id, intakeState(d))
        expectConverted(d, id)
        expectEqual(d.queued("jobs"), 1, "\(id) [P12-016]: the lead job is queued for the push")
        expectEqual(d.queued("customers"), 1, "\(id) [P12-016]: …and the customer")
        expectEqual(d.queued("bookingRequests"), 1, "\(id) [P12-016]: …and the linked request")
        d.reach.online = true
        await d.sync()
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead",
                    "\(id) [P12-016]: the cloud has the lead job")
        expectEqual(d.links.requestRow("req-1")?["convertedJobId"] as? String, leadJobID,
                    "\(id) [P12-016]: …and the linked request")
        expectEqual(d.data.liveRowCount(table: "customers", userID: d.subject), 1,
                    "\(id) [P12-016]: …and the customer")
        expectEqual(d.queue.load().count, 0, "\(id): everything reached the server")
    }

    /// K2: a warm activation. The activation's identity tail runs the gate
    /// sites first, before any pull, and they convert nothing, even with an
    /// unconverted booking already on the device (K2b: a pull-to-refresh
    /// brought it; RN converts only at launch and after a foreground sync).
    /// The foreground refresh's own pull then commits, and the booking becomes
    /// a lead job and a customer in the same activation (RN: sync, then
    /// convert, `context/AuthContext.tsx:118-120`). K2a: the booking arrives
    /// in that pull, and once it has committed the data server stops
    /// answering reads, so intake converts from that pull, not from a pull
    /// of its own.
    /// Characterized at 9a4d845: nothing converts.
    @MainActor
    static func warmActivationConvertsAfterItsPull() async {
        for localBeforeActivation in [false, true] {
            let id = localBeforeActivation ? "K2b warm activation, booking already on the device"
                : "K2a warm activation, booking in the refresh's pull"
            let (d, store) = await intakeDevice(localBeforeActivation ? "k2b" : "k2a")
            defer { d.cleanup() }
            if localBeforeActivation {
                await d.sync()
                expect(bookingRequest(d) != nil && leadJob(d) == nil,
                       "\(id): sanity: a pull-to-refresh brought the booking and converted nothing")
            }
            d.stage(passMarkerProof)
            await applyIdentityAgain(store, d)
            let atGateSites = intakeState(d)
            let convertedAtGateSites = leadJob(d) != nil || !bookedCustomers(d).isEmpty
            var readsStopped = false
            if !localBeforeActivation {
                store.notificationSynchronizeHook = { _ in
                    guard !readsStopped else { return }
                    readsStopped = true
                    d.pullLoader.readsFail = true
                }
            }
            await store.performForegroundRefresh()
            observed(id, "at the gate sites: \(atGateSites); after the refresh: \(intakeState(d))")
            expect(!convertedAtGateSites, "\(id) [P12-016]: the gate sites, before this activation's pull, convert nothing")
            if !localBeforeActivation {
                expect(readsStopped, "\(id): sanity: the refresh's pull committed, then reads stopped")
            }
            expectConverted(d, id)
            d.pullLoader.readsFail = false
            await d.sync()
            expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead",
                        "\(id) [P12-016]: after the push the cloud has the lead job")
        }
    }

    /// K3: a foreground refresh whose pull failed (offline) or was partial
    /// (the jobs table failed) converts nothing, even with the unconverted
    /// booking on the device. A partial pull can miss the job another device
    /// already made from the booking, and the push after a conversion would
    /// overwrite it. Once sync works again (the owner's pull to refresh, which
    /// converts nothing itself, clears the backoff), the next activation
    /// converts the booking.
    @MainActor
    static func failedOrPartialPullConvertsNothing() async {
        for partial in [false, true] {
            let id = partial ? "K3b partial pull" : "K3a failed pull"
            let (d, store) = await intakeDevice(partial ? "k3b" : "k3a")
            defer { d.cleanup() }
            if partial {
                d.data.injectStatusOnce = (method: "GET", table: "jobs", status: 500)
            } else {
                await d.sync()
                expect(bookingRequest(d) != nil, "\(id): sanity: the booking is on the device")
                d.reach.online = false
            }
            await store.performForegroundRefresh()
            let afterFailedRefresh = intakeState(d)
            let arrived = bookingRequest(d) != nil
            let convertedAfterFailedRefresh = leadJob(d) != nil || !bookedCustomers(d).isEmpty
                || bookingRequest(d)?.convertedJobId != nil
            d.reach.online = true
            await d.sync()
            let convertedByPullToRefresh = leadJob(d) != nil
            await store.performForegroundRefresh()
            observed(id, "after the refresh: \(afterFailedRefresh); after the next activation: \(intakeState(d))")
            expect(arrived, "\(id): sanity: the booking is on the device, unconverted")
            expect(!convertedAfterFailedRefresh, "\(id) [P12-016]: the refresh converts nothing")
            expect(!convertedByPullToRefresh, "\(id): a pull to refresh converts nothing (RN parity)")
            expectConverted(d, "\(id): the next activation")
        }
    }

    /// K4: idempotence. After the conversion, another activation, and a
    /// relaunch with its activation, create nothing new and queue nothing.
    /// Two overlapping activations convert a new booking once.
    @MainActor
    static func intakeIsIdempotent() async {
        let id = "K4 idempotence"
        let (d, store) = await intakeDevice("k4")
        defer { d.cleanup() }
        await store.performForegroundRefresh()
        await d.sync()
        expectConverted(d, id)
        let jobs = d.disk?.payload.jobs?.count
        let customers = (d.disk?.payload.customers ?? []).map(\.id)
        await store.performForegroundRefresh()
        expectEqual(d.disk?.payload.jobs?.count, jobs, "\(id): a second activation creates no job")
        expectEqual((d.disk?.payload.customers ?? []).map(\.id), customers, "\(id): …and no customer")
        expectEqual(d.queue.load().count, 0, "\(id): …and queues nothing")
        let relaunched = d.launch()
        await d.signIn(relaunched)
        await relaunched.performForegroundRefresh()
        observed(id, "after a second activation and a relaunch: \(intakeState(d))")
        expectEqual(d.disk?.payload.jobs?.count, jobs, "\(id): the relaunch's activation creates no job")
        expectEqual((d.disk?.payload.customers ?? []).map(\.id), customers, "\(id): …and no customer")
        expectEqual(d.queue.load().count, 0, "\(id): …and queues nothing")
        expectConverted(d, "\(id): after the relaunch")

        let overlapID = "K4 overlapping activations"
        let (d2, store2) = await intakeDevice("k4-overlap")
        defer { d2.cleanup() }
        async let firstRefresh: Void = store2.performForegroundRefresh()
        async let secondRefresh: Void = store2.performForegroundRefresh()
        _ = await (firstRefresh, secondRefresh)
        await d2.sync()
        observed(overlapID, intakeState(d2))
        expectConverted(d2, overlapID)
        expectEqual(d2.data.liveRowCount(table: "customers", userID: d2.subject), 1,
                    "\(overlapID) [P12-016]: one customer reaches the cloud")
        expectEqual(d2.data.liveRowCount(table: "jobs", userID: d2.subject), 1,
                    "\(overlapID) [P12-016]: …and one job")
    }

    /// The lead job the Expo build made from the booking on the owner's other
    /// device, since scheduled and priced there.
    static func otherDevicesLeadJob() -> [String: Any] {
        [
            "id": leadJobID, "customerId": "c-other-1", "customerName": "Sam Ortiz", "title": "Booked appointment",
            "description": "Panel inspection", "status": "scheduled", "address": "9 Oak Ave", "estimateTotal": 350,
            "laborHours": 2, "laborRate": 95, "materials": [], "materialMarkup": 25, "overhead": 10, "margin": 30,
            "notes": "Priced on the other device", "createdAt": "2026-09-10",
            "scheduledDate": "2026-09-23", "scheduledStartTime": "09:00", "scheduledEndTime": "10:00",
        ]
    }

    /// K5: the Expo build on the owner's other device converted the booking
    /// first. Its lead job `jbk_req-1` (since scheduled and priced there) and
    /// its customer reached the cloud; its request stamp has not. Native
    /// links the request to that job and customer and never replaces the job:
    /// nothing is queued for it, and after the push the cloud job is still
    /// the other device's. Both clients use the same deterministic job ID
    /// (D-B3-2).
    /// Characterized at 9a4d845: the request is never linked.
    @MainActor
    static func anExistingLeadJobIsNeverOverwritten() async {
        let id = "K5 existing lead job"
        let (d, store) = await intakeDevice("k5")
        defer { d.cleanup() }
        await d.links.upsert(table: "customers", id: "c-other-1", record: [
            "id": "c-other-1", "name": "Sam Ortiz", "email": "sam@example.test", "phone": "555-0177",
            "address": "9 Oak Ave", "notes": "", "createdAt": "2026-09-10T00:00:05.000Z",
        ])
        await d.links.upsert(table: "jobs", id: leadJobID, record: otherDevicesLeadJob())
        // Offline once the refresh's pull has committed, so what intake
        // queues stays in the queue to be read.
        var pulled = false
        store.notificationSynchronizeHook = { _ in
            guard !pulled else { return }
            pulled = true
            d.reach.online = false
        }
        await store.performForegroundRefresh()
        let job = leadJob(d)
        observed(id, intakeState(d) + " customer=\(bookingRequest(d)?.convertedCustomerId ?? "none")")
        expectEqual(job?.status, "scheduled", "\(id) [D-B3-2]: the other device's job is kept")
        expectEqual(job?.notes, "Priced on the other device", "\(id) [D-B3-2]: …with its notes")
        expectEqual(job?.estimateTotal, Decimal(350), "\(id) [D-B3-2]: …and its price")
        expectEqual(bookingRequest(d)?.convertedJobId, leadJobID, "\(id) [P12-016]: the request links that job")
        expectEqual(bookingRequest(d)?.convertedCustomerId, "c-other-1",
                    "\(id) [P12-016]: …and its customer (found by name: no duplicate)")
        expectEqual(bookedCustomers(d).count, 1, "\(id): one customer on the device")
        expectEqual(d.queued("jobs"), 0, "\(id) [D-B3-2]: nothing is queued for the job")
        expectEqual(d.queued("customers"), 0, "\(id): …or the customer")
        expectEqual(d.queued("bookingRequests"), 1, "\(id) [P12-016]: the linked request is queued")
        d.reach.online = true
        await d.sync()
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "scheduled",
                    "\(id) [D-B3-2]: after the push the cloud job is still the other device's")
        expectEqual(d.links.requestRow("req-1")?["convertedJobId"] as? String, leadJobID,
                    "\(id) [P12-016]: …and the cloud request links it")
    }

    /// K6: the account changes while the foreground refresh's pull is in its
    /// network await (reading the booking table): a sign-out; a switch to
    /// account B with B's gate open (workspace, sign-in, initial sync); or an
    /// account boundary after which the same owner is signed in again (only
    /// the account generation tells them apart). Nothing is converted into
    /// either account's snapshot or queue. In the last case the pull still
    /// commits (the subject is the same) but began before the boundary, so
    /// it does not count; the owner's next launch and activation convert the
    /// booking.
    @MainActor
    static func accountChangeDuringTheIntakePull() async {
        let subjectB = "99999999-8888-7777-6666-555555555555"
        let bindingB = String(repeating: "c", count: 64)
        for boundary in ["sign-out", "account B", "boundary then the same owner"] {
            let id = "K6 \(boundary) during the pull"
            let (d, store) = await intakeDevice("k6-\(boundary.count)")
            defer { d.cleanup() }
            var changed = false
            d.pullLoader.duringNextRead = ("bookingRequests", {
                changed = true
                switch boundary {
                case "sign-out":
                    store.scheduleBookingTestClearOwner()
                case "account B":
                    store.testApplyCompletedSignOutState()
                    try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
                        accountBinding: bindingB, stage: .done,
                        draft: .init(businessName: "Biz B", contactName: "Owner B", trade: .electrical, step: 1)
                    ))
                    store.testSeedNativeSignedInOwner(subject: subjectB, binding: bindingB)
                    store.testMarkInitialSyncCompleted(subject: subjectB)
                default:
                    store.testApplyCompletedSignOutState()
                    store.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
                    store.testMarkInitialSyncCompleted(subject: d.subject)
                }
            })
            await store.performForegroundRefresh()
            observed(id, intakeState(d))
            expect(changed, "\(id): sanity: the account changed during the pull")
            if boundary == "account B" {
                expect(isSignedIn(store), "\(id): sanity: B is signed in with the gate open")
            }
            expect(leadJob(d) == nil, "\(id) [P12-016]: no lead job in the snapshot")
            expect(bookedCustomers(d).isEmpty, "\(id) [P12-016]: …no customer")
            expect(bookingRequest(d)?.convertedJobId == nil, "\(id) [P12-016]: …the request is not linked")
            expectEqual(d.queued("jobs") + d.queued("customers") + d.queued("bookingRequests"), 0,
                        "\(id) [P12-016]: …and nothing is queued")
            if boundary == "boundary then the same owner" {
                expect(bookingRequest(d) != nil, "\(id): sanity: the same owner's pull committed the booking")
                let next = d.launch()
                await d.signIn(next)
                await next.performForegroundRefresh()
                expectConverted(d, "\(id): the owner's next activation")
            }
        }
    }

    /// K7: before the initial sync has completed for the signed-in owner,
    /// nothing converts: not the activation (its pull commits and brings the
    /// booking) and not a gate site (the starting point opening the gate).
    /// Once the initial sync has completed, the next activation converts.
    @MainActor
    static func nothingBeforeTheInitialSync() async {
        let id = "K7 before the initial sync"
        let d = Device("k7")
        defer { d.cleanup() }
        await customerBooks(d)
        let store = d.launch()
        d.prepareOwner(store)
        store.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
        d.connect(store, subject: d.subject)
        await store.performForegroundRefresh()
        let pulled = bookingRequest(d) != nil
        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
            accountBinding: d.binding, stage: .personalized,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        do { try store.completeStartingPoint(.fresh) } catch {
            expect(false, "\(id): sanity: the starting point completes (\(error))")
        }
        await settle()
        let before = intakeState(d)
        let convertedBefore = leadJob(d) != nil || !bookedCustomers(d).isEmpty
        store.testMarkInitialSyncCompleted(subject: d.subject)
        await store.performForegroundRefresh()
        observed(id, "before the initial sync: \(before); after: \(intakeState(d))")
        expect(pulled, "\(id): sanity: the activation's pull brought the booking")
        expect(!convertedBefore, "\(id) [P12-016]: nothing converts before the initial sync")
        expectConverted(d, "\(id): after the initial sync, the next activation")
    }

    /// K7b: read-only. The launch found a snapshot written by a newer app
    /// version, so it keeps it and blocks writes. With an unconverted booking
    /// in it, neither an activation nor a gate site converts, and nothing is
    /// written or queued for a job or customer.
    @MainActor
    static func nothingWhileReadOnly() async {
        let id = "K7b read-only"
        let d = Device("k7b")
        defer { d.cleanup() }
        let future = Canonical.Snapshot(
            schemaVersion: Canonical.Snapshot.currentSchemaVersion + 1,
            payload: Canonical.SnapshotPayload(settings: fixtureSettings(bookingLink: nil),
                                               bookingRequests: [fixtureRequest(status: "booked", converted: false)])
        )
        do { try Canonical.SnapshotCodec.encode(future).write(to: d.storeURL, options: .atomic) } catch {
            expect(false, "\(id): fixture: the newer snapshot is written (\(error))")
        }
        let bytes = try? Data(contentsOf: d.storeURL)
        let store = d.launch()
        expect(store.rollbackReadiness().blockers.contains(.writesBlocked), "\(id): sanity: the launch blocked writes")
        await d.signIn(store)
        await customerBooks(d)
        await store.performForegroundRefresh()
        store.testActivateReturningUserSession(subject: d.subject, binding: d.binding)
        await settle()
        observed(id, "queued=jobs:\(d.queued("jobs")),customers:\(d.queued("customers")) "
                 + "unchanged=\((try? Data(contentsOf: d.storeURL)) == bytes)")
        expect((try? Data(contentsOf: d.storeURL)) == bytes, "\(id) [P12-016]: nothing is written")
        expectEqual(d.queued("jobs") + d.queued("customers"), 0, "\(id) [P12-016]: no job or customer is queued")
        let linkedRequestQueued = d.queue.load().contains { item in
            item.table == "bookingRequests"
                && String(decoding: (try? JSONEncoder().encode(item.payload)) ?? Data(), as: UTF8.self).contains(leadJobID)
        }
        expect(!linkedRequestQueued, "\(id) [P12-016]: no linked request is queued")
    }

    /// K8: the intake's local save fails after the refresh's pull committed.
    /// Nothing is converted or queued; nothing is left in `migrationMessage`
    /// to show later on an unrelated screen (the P12-015 lesson); the sync
    /// status carries the bounded code `intake/local-commit`. The next
    /// activation converts the booking.
    @MainActor
    static func aFailedIntakeSaveLeavesNoMessage() async {
        let id = "K8 intake save fails"
        let (d, store) = await intakeDevice("k8")
        defer { d.cleanup() }
        var armed = true
        store.notificationSynchronizeHook = { _ in
            guard armed else { return }
            armed = false
            d.failSnapshotSaves(true)
        }
        await store.performForegroundRefresh()
        d.failSnapshotSaves(false)
        let code = store.syncStatus.diagnosticCode
        observed(id, intakeState(d) + " migrationMessage=\(store.migrationMessage ?? "nil") code=\(code ?? "nil")")
        expect(!armed, "\(id): sanity: the refresh's pull committed before saves failed")
        expect(bookingRequest(d) != nil, "\(id): sanity: the pull brought the booking")
        expect(leadJob(d) == nil && bookedCustomers(d).isEmpty && bookingRequest(d)?.convertedJobId == nil,
               "\(id): nothing is converted")
        expectEqual(d.queued("jobs") + d.queued("customers") + d.queued("bookingRequests"), 0,
                    "\(id): nothing is queued")
        expectEqual(store.migrationMessage, nil, "\(id) [P12-016]: nothing is left in migrationMessage")
        expectEqual(code, "intake/local-commit", "\(id) [P12-016]: the sync status carries the bounded code")
        await store.performForegroundRefresh()
        expectConverted(d, "\(id): the next activation")
    }

    /// K9 (with P12-015): after intake, the customer asks to reschedule, and
    /// the owner accepts from Today without moving the job. The request is
    /// linked to the lead job, so the accept resolves with a proof of the
    /// job's schedule instead of answering `notLinkedToJob` ("Pull down to
    /// refresh, then try again", which never helped).
    /// Characterized at 9a4d845: `notLinkedToJob`.
    @MainActor
    static func acceptAfterIntakeIsLinkedToTheJob() async {
        let id = "K9 accept after intake"
        let (d, store) = await intakeDevice("k9")
        defer { d.cleanup() }
        await store.performForegroundRefresh()
        await d.sync()
        if var row = d.links.requestRow("req-1") {
            row["status"] = "reschedule_requested"
            await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
        }
        await store.performForegroundRefresh()
        d.links.resetLog()
        let tapped = await tap(.today, store, d)
        observed(id, "outcome=\(tapped.outcome) shown=\(tapped.message ?? "nothing") sent=\(d.links.log)")
        expect(!tapped.outcome.contains("notLinkedToJob") && tapped.outcome != "no row",
               "\(id) [P12-016]: the accept no longer answers notLinkedToJob (\(tapped.outcome))")
        expectEqual(d.links.respondProofs, ["\(leadJobID) 2026-09-23 09:00 2026-09-10T00:00:00.000Z"],
                    "\(id) [P12-016]: it resolves with a proof of the lead job's schedule")
        expectEqual(d.links.requestRow("req-1")?["status"] as? String, "confirmed",
                    "\(id) [P12-016]: the server confirms the booking")
        expectEqual(tapped.title, "Booking updated", "\(id) [P12-016]: Today says so")
        expectEqual(tapped.message,
                    "The job wasn't moved, so the booking is confirmed for its original time, \(requestSlotWhen).",
                    "\(id) [P12-016]: …for the booked time")
    }

    // MARK: K pins: where intake runs, and where it does not (P12-016)

    @MainActor
    static func intakeSources(_ root: URL) {
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
        expect(!store.isEmpty, "S-K: sources found")
        let start = "startBookingIntakeIfPossible()"
        let recover = "startScheduleBookingRecoveryIfPossible()"
        let sync = "await syncNowAndWait(trigger: .foreground)"
        // Activation: after the refresh's own sync, before recovery.
        let foreground = body(store, from: "    func performForegroundRefresh() async {") ?? ""
        if let synced = foreground.range(of: sync),
           let intake = foreground.range(of: "await runBookingIntakeIfPossible()"),
           let recovery = foreground.range(of: "await recoverScheduleBookingPendingWorkIfPossible()") {
            expect(synced.upperBound < intake.lowerBound && intake.upperBound < recovery.lowerBound,
                   "S-K [P12-016]: the foreground refresh converts after its sync, before recovery")
        } else {
            expect(false, "S-K [P12-016]: the foreground refresh converts bookings")
        }
        let resetMark = "bookingIntakePullMark = nil"
        if let reset = foreground.range(of: resetMark), let synced = foreground.range(of: sync) {
            expect(reset.upperBound < synced.lowerBound, "S-K: the foreground refresh clears the intake mark before its sync")
        } else {
            expect(false, "S-K: the foreground refresh clears the intake mark")
        }
        let outcome = body(store, from: "    private func applyAuthenticatedIdentityOutcome(") ?? ""
        if let reset = outcome.range(of: resetMark), let consumers = outcome.range(of: start) {
            expect(reset.upperBound < consumers.lowerBound,
                   "S-K: applying the identity clears the intake mark before its consumer block starts intake")
        } else {
            expect(false, "S-K: applying the identity clears the intake mark")
        }
        // Launch: the three points that open the signed-in gate after the
        // initial sync, intake first, then recovery.
        let gateSites = [
            ("the subscription gate's signed-in exit", body(store, from: "    private func advancePastSubscriptionGate() {") ?? ""),
            ("the starting point's exit", body(store, from: "    func completeStartingPoint(") ?? ""),
            ("a returning launch's signed-in gate",
             body(store, from: "        if activateConsumers, case .signedIn = authenticationGateState {", to: "\n        }\n") ?? ""),
        ]
        for (site, text) in gateSites {
            if let intake = text.range(of: start), let recovery = text.range(of: recover) {
                expect(intake.upperBound < recovery.lowerBound, "S-K [P12-016]: \(site) starts intake, then recovery")
            } else {
                expect(false, "S-K [P12-016]: \(site) starts intake")
            }
        }
        // The mark: set by the initial sync's commit, and by a delta pull
        // that committed every table.
        let setMark = "markBookingIntakePullCommitted("
        let initialSync = body(store, from: "    private func beginInitialSyncGate(") ?? ""
        if let commit = initialSync.range(of: "try self.commitSnapshot(candidate)"),
           let mark = initialSync.range(of: "self." + setMark) {
            expect(commit.upperBound < mark.lowerBound, "S-K: the initial sync marks its committed pull for intake")
        } else {
            expect(false, "S-K: the initial sync marks its committed pull for intake")
        }
        let deltaPull = body(store, from: "    private func pullDeltaAndCommit() async -> NativeSyncPullResult {") ?? ""
        if let commit = deltaPull.range(of: "do { try syncCursorStore.save(committedCursor) }"),
           let mark = deltaPull.range(of: setMark) {
            expect(commit.upperBound < mark.lowerBound, "S-K: a delta pull marks its commit for intake")
            expect(deltaPull[commit.upperBound..<mark.lowerBound].contains("outcome.failedTables.isEmpty"),
                   "S-K [P12-016]: …only when every table committed")
        } else {
            expect(false, "S-K: a delta pull marks its commit for intake")
        }
        // The wired entry reuses the committed pull, for the gated owner only.
        let entry = body(store, from: "    private func runBookingIntakeIfPossible(") ?? ""
        expect(!entry.isEmpty, "S-K: the wired intake entry exists")
        expect(!entry.isEmpty && !entry.contains("pullDeltaIfPossible"),
               "S-K [P12-016]: it reuses the committed pull (no second pull)")
        expect(entry.contains("scheduleBookingRecoveryBinding") && entry.contains("bookingIntakePullCommitted"),
               "S-K: it runs only for the gated owner after a committed pull")
        // The shared apply: nothing to migrationMessage; one counts-only line.
        let apply = body(store, from: "    private func applyBookingIntake(") ?? ""
        expect(!apply.isEmpty, "S-K: the shared intake apply exists")
        expect(!apply.isEmpty && !apply.contains("migrationMessage") && !apply.contains("ensurePersistenceWritable()"),
               "S-K [P12-016]: an intake pass never writes migrationMessage")
        let lines = apply.components(separatedBy: "\n").filter { $0.contains("TradeReadyBookingIntake stage=pass") }
        expectEqual(lines.count, 1, "S-K [P12-016]: an intake pass that found work logs one diagnostic line")
        let line = lines.first?.lowercased() ?? ""
        expect(!line.isEmpty && !["name", "email", "phone", "token", "request", "subject", "binding"].contains(where: line.contains),
               "S-K: …with counts and a fixed reason only")
        // Never from the rollback-readiness check.
        let readiness = body(store, from: "    private func prepareRollbackReadiness(\n") ?? ""
        expect(!readiness.isEmpty && !readiness.contains("BookingIntake"), "S-K: the rollback-readiness check never converts")
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
        // Fix round 1 (review I1): the textual order below is not what keeps
        // a mirror out of a pre-pull snapshot (the gate sites also start
        // passes, before this refresh runs). A mirror is read and merged only
        // after a pull commits since the identity was applied or this refresh
        // began: W1, W2 and L2 prove it behaviourally; the pins below only
        // locate the mark's reset and set points.
        if let sync = foreground.range(of: "await syncNowAndWait(trigger: .foreground)"),
           let recover = foreground.range(of: "await recoverScheduleBookingPendingWorkIfPossible()") {
            expect(sync.lowerBound < recover.lowerBound, "S: the foreground refresh's own pass follows its sync (textual)")
        }
        let resetMark = "scheduleBookingRecoveryPullMark = nil"
        let setMark = "markScheduleBookingRecoveryPullCommitted(subject: subject)"
        if let reset = foreground.range(of: resetMark),
           let sync = foreground.range(of: "await syncNowAndWait(trigger: .foreground)") {
            expect(reset.upperBound < sync.lowerBound, "S [I1]: the foreground refresh clears the pull mark before its sync")
        } else {
            expect(false, "S [I1]: the foreground refresh clears the pull mark")
        }
        let outcome = body(store, from: "    private func applyAuthenticatedIdentityOutcome(") ?? ""
        if let reset = outcome.range(of: resetMark), let consumers = outcome.range(of: launch) {
            expect(reset.upperBound < consumers.lowerBound,
                   "S [I1]: applying the identity clears the pull mark before its consumer block starts a pass")
        } else {
            expect(false, "S [I1]: applying the identity clears the pull mark")
        }
        let initialSync = body(store, from: "    private func beginInitialSyncGate(") ?? ""
        if let commit = initialSync.range(of: "try self.commitSnapshot(candidate)"),
           let mark = initialSync.range(of: "self." + setMark) {
            expect(commit.upperBound < mark.lowerBound, "S [I1]: the initial sync marks its committed pull")
        } else {
            expect(false, "S [I1]: the initial sync marks its committed pull")
        }
        let deltaPull = body(store, from: "    private func pullDeltaAndCommit() async -> NativeSyncPullResult {") ?? ""
        if let commit = deltaPull.range(of: "do { try syncCursorStore.save(committedCursor) }"),
           let mark = deltaPull.range(of: setMark) {
            expect(commit.upperBound < mark.lowerBound, "S [I1]: a delta pull marks its commit")
        } else {
            expect(false, "S [I1]: a delta pull marks its commit")
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
        // Review M6: one bounded, counts-only line per pass.
        let lines = recovery.components(separatedBy: "\n").filter { $0.contains("TradeReadyScheduleBookingRecovery stage=pass") }
        expectEqual(lines.count, 1, "S [M6]: a pass logs one diagnostic line")
        let line = lines.first?.lowercased() ?? ""
        expect(!line.isEmpty && !["token", "customer", "request", "binding", "subject", "item"].contains(where: line.contains),
               "S [M6]: …with counts only (no token, customer, request or owner)")

        // P12-015: both reschedule row actions call the one entry point the
        // F tests drive and show its notice on their own screen. The entry
        // point writes nothing to the job, sends nothing through
        // migrationMessage and compares the account generation.
        let today = read("native/TradeReadyNative/TodayView.swift")
        let requests = read("native/TradeReadyNative/NativeBookingRequestsView.swift")
        let rowActions = [
            ("Today", body(today, from: "    private func resolveBookingReschedule(") ?? "", "I've rescheduled it"),
            ("Requests", body(requests, from: "    private func resolveReschedule(") ?? "", "Resolve"),
        ]
        for (screen, action, label) in rowActions {
            expect(action.contains("store.acceptBookingReschedule(requestID: row.request.id)"),
                   "S [P12-015]: the \(screen) row action calls acceptBookingReschedule")
            expect(action.contains("ownerNotice(actionLabel: \"\(label)\")"),
                   "S [P12-015]: …and shows its notice on that screen")
            expect(!action.isEmpty && !action.contains("prepareBookingReschedule") && !action.contains("slot"),
                   "S [P12-015]: …and never builds a schedule draft from request.slot")
        }
        let accept = body(store, from: "    func acceptBookingReschedule(") ?? ""
        expect(!accept.isEmpty, "S [P12-015]: the accept entry point exists")
        expect(accept.contains("accountBoundaryGeneration"), "S [P12-015]: it compares the account generation")
        for forbidden in ["commitScheduleOnly", "migrationMessage", "enqueueUpsert", "payload.jobs =",
                          "scheduledDate =", "scheduledStartTime ="] {
            expect(!accept.contains(forbidden), "S [P12-015]: it never uses `\(forbidden)`")
        }
    }
}
