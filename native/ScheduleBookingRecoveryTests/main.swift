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
// Fix round 1: K1 runs the real initial sync; a gate that waited for the owner
// converts nothing from an older pull (K1b); a repeat customer's blank fields
// are filled (K10); a request whose `jbk_` job is already on the device is
// linked to it, as RN links it (K5, K10b).
//
// Section D (12.00b.2-L, P12-017): the owner's decline (and the test-only
// legacy resolve) queued a whole copy of the request after the server wrote
// its status and history, and the next push replaced the server's history
// with the device's. Booking intake's request stamp and repeat-customer fill
// (Task 12d review M6) pushed whole rows over a customer's or another
// device's change that reached the server after the pull. RN pushes nothing
// after a response (`screens/TodayScreen.tsx:559-563`).
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
    /// Task 12c review M2: answer an illegal transition as the committed
    /// Worker does, 409 `invalid_state` with no status
    /// (`backend-workers/lib/booking/respond.js:61`).
    var statuslessConflicts = false
    var unreachable = false
    /// P12-027: how the booking-link and portal-link admin routes answer a
    /// mutation. `lostAfterCommit` commits and then fails the response (a
    /// timeout after the work); `lostBeforeCommit` fails before any change.
    enum AdminMode { case normal, lostAfterCommit, lostBeforeCommit }
    var adminMode = AdminMode.normal
    /// The operation ID each admin mutation carried, in order.
    private(set) var operationIDs: [String] = []
    /// The stored response per operation ID, as the server keeps them for 30
    /// days (contract §1.3): a repeated ID replays instead of mutating again.
    private var replays: [String: (Int, [String: Any])] = [:]
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
        operationIDs = []
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
        var reply: (Int, [String: Any])
        let adminID = body["operationId"] as? String ?? ""
        if (family == "booking" || family == "portal"), action != "status", !adminID.isEmpty {
            operationIDs.append(adminID)
        }
        if (family == "booking" || family == "portal"), action != "status", let stored = replays[adminID] {
            reply = stored
        } else if (family == "booking" || family == "portal"), action != "status", adminMode == .lostBeforeCommit {
            reply = (500, ["error": "Database error"])
        } else {
            switch family {
            case "booking": reply = booking(action, body)
            case "portal": reply = portal(action, body)
            case "respond": reply = await respond(action, body)
            default: reply = (404, ["error": "Not found"])
            }
            if (family == "booking" || family == "portal"), action != "status", reply.0 == 200, !adminID.isEmpty {
                replays[adminID] = reply
            }
            if (family == "booking" || family == "portal"), action != "status", adminMode == .lostAfterCommit,
               reply.0 == 200 {
                reply = (500, ["error": "Database error"])
            }
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
        guard transition.from.contains(current) else {
            return (409, statuslessConflicts ? ["error": "invalid_state"] : ["error": "invalid_state", "status": current])
        }
        if action == "resolve_reschedule", respondMode == .scheduleChanged {
            return (409, ["error": "schedule_changed", "status": current])
        }
        row["status"] = transition.to
        // The Worker appends the owner's entry to the server's history
        // (`backend-workers/lib/booking/respond.js:64-75`).
        var history = row["history"] as? [[String: Any]] ?? []
        history.append(["at": "2026-09-27T12:00:00.000Z", "actor": "owner", "event": action])
        row["history"] = history
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
    case .rescheduleProof, .stagedBatch, .adminOperation: return false
    }
}

@MainActor func stagedBatches(_ d: Device) -> [[NativeScheduleBookingStagedDraft]] {
    d.items.compactMap { item in
        if case let .stagedBatch(drafts, _) = item.kind { return drafts }
        return nil
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
    /// This device's own Keychain (12.00b.2-K fix round 1), for a launch that
    /// runs the real initial sync, which reads the Supabase session from it.
    /// Nil: the process-wide host Keychain every other case uses.
    var keychain: HostInMemoryKeychain?
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
            secureSettingsStore: keychain.map { NativeKeychainSecureSettingsStore(backend: $0) }
                ?? hostTestSecureSettingsStore()
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

    /// Makes the mutation queue's file unwritable (a directory stands where
    /// the file is, as a full disk or a lost data-protection class would),
    /// or restores it. A blocked queue reads as empty and refuses writes.
    func blockQueue(_ block: Bool) {
        let url = dir.appendingPathComponent("mutation-queue.json")
        try? FileManager.default.removeItem(at: url)
        if block { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    /// The same for the pending-work store's file, so nothing can be staged.
    func blockWorkStore(_ block: Bool) {
        let url = dir.appendingPathComponent("schedule-booking-pending-work.json")
        try? FileManager.default.removeItem(at: url)
        if block { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

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
        await backgroundClearsThePullMarks(root)
        await aPullAcrossABoundaryLeavesMirrorsUnread()
        await waitingGatesClearTheRecoveryMark()
        await aWaitingGatesExitLeavesMirrorsForTheNextPull()
        await applyingTheIdentityClearsTheRecoveryMark()
        await aFailedForegroundPullKeepsTheMirror()
        await aPartialPullKeepsTheMirror()
        await aFailedRecoverySaveLeavesNoMessage()
        await acceptAfterTheOwnerMovedTheJob()
        await acceptBeforeTheOwnerMovedTheJob()
        await acceptOutcomesOnTheActingScreen()
        await accountChangeDuringTheResolve()
        await statuslessConflictUsesThePulledStatus()
        await s1GuardTheResolveNeverMovesTheJobBack()
        acceptNoticesOnBothScreens()
        await coldLaunchConvertsAfterTheInitialSync()
        await coldLaunchWithBookingHistoryStampsOnce()
        await gateThatWaitsForTheOwnerConvertsAfterItsNextPull()
        await waitingGatesClearTheMark()
        await warmActivationConvertsAfterItsPull()
        await failedOrPartialPullConvertsNothing()
        await intakeIsIdempotent()
        await anExistingLeadJobIsNeverOverwritten()
        await aRepeatCustomersBlankFieldsAreFilled()
        recheckRules()
        await accountChangeDuringTheIntakePull()
        await nothingBeforeTheInitialSync()
        await nothingWhileReadOnly()
        await aFailedIntakeSaveLeavesNoMessage()
        await aLostBookingCreateIsReplayedByItsOperationID()
        await aLostBookingRotateNeverIssuesASecondLink()
        await aDifferentActionWaitsForAnUnknownOne()
        await definiteFailuresClearAndRetriesKeepTheOperation()
        await aLostPortalCreateIsReplayedByItsOperationID()
        await anExpiredOperationStartsFresh()
        await anOperationThatCannotBeRememberedIsNotSent()
        adminOperationRules()
        adminOperationSources(root)
        await aDeletedJobsRowsCanBeAnsweredOrCleared()
        missingJobSources(root)
        await aFailedIntakeQueueWriteIsStagedAndReplayed()
        await anIntakeThatCannotStageCommitsNothing()
        await aSupersededStagedDraftIsNotReplayed()
        await stagedReplayNeverQueuesTwice()
        await aStagedBatchBlocksRollbackReadiness()
        await anEndedCommitIsReplayedAtLaunch()
        await anOlderQueuedUpsertIsReplacedByTheStagedOne()
        await anUnreadableQueueKeepsTheStagedBatch()
        await aPullThatRevertedAGuardedStampStillReplaysIt()
        stagedCommitKeepsTheStageUntilSavedWorkIsQueued()
        await acceptAfterIntakeIsLinkedToTheJob()
        await declineKeepsTheServersHistory()
        await aQueuedCopyNeverOverwritesTheDecline()
        await legacyResolveKeepsTheServersHistory()
        await intakeStampNeverOverwritesTheServer()
        await intakeFillNeverOverwritesTheServer()
        await aSupersededChangeRefetchesItsRow()
        intakeGuardsOnlyRecordsAlreadyOnTheServer()
        await legacyPrepareStopsOnAnAccountChange()
        await aLongQueuedStampRefetchesItsRow()
        attentionFindsTheLeadJobOfAnUnlinkedBooking()
        await aRefusalsPullStopsOnAnAccountChange()
        await aDeclineWhoseLocalSaveFailsSaysSo()
        await anUnreadableRejectedStoreSaysWaitAMoment()
        sources(root)
        intakeSources(root)
        declineNoticesAndPins(root)

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
            expectEqual(outcome, "applied(status: \"declined\", alreadyApplied: false, savedLocally: true)", "\(id): sanity: the decline")
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

    // MARK: Z. The pull mark's windows, and a failed recovery save (final review M1, M2, M5)

    /// A booking Rotate whose local save failed (a staged mirror), then a
    /// relaunch with the owner signed in and the sync coordinator connected,
    /// before any pull or activation on the new AppStore.
    @MainActor
    static func mirrorOnRelaunch(_ tag: String) async -> (Device, AppStore) {
        let d = bookingDevice(tag, link: (bookingTokenA, true))
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.failSnapshotSaves(true)
        _ = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        d.failSnapshotSaves(false)
        expectEqual(d.items.filter(isMirror).count, 1, "\(tag): sanity: one mirror is staged")
        d.links.resetLog()
        let relaunched = d.launch()
        await d.signIn(relaunched)
        return (d, relaunched)
    }

    /// Both pull marks at once: (recovery, intake).
    @MainActor
    static func marks(_ store: AppStore) -> String {
        "recovery=\(store.testScheduleBookingRecoveryPullCommitted) intake=\(store.testBookingIntakePullCommitted)"
    }

    /// Z1 (review M1, R54 N1): the scene goes to the background. Both marks
    /// are cleared, so no pass of the next activation (its gate sites run
    /// before its pull) can merge a mirror or convert a booking from this
    /// period's pull. A pull still in flight when the scene left (it can
    /// resume after the next activation began) does not set them when it
    /// commits. The next pull does.
    /// Characterized at 7890ee5: the marks survived the background, and the
    /// pull in flight set them again.
    @MainActor
    static func backgroundClearsThePullMarks(_ root: URL) async {
        let id = "Z1 background"
        let (d, store) = await intakeDevice("z1")
        defer { d.cleanup() }
        _ = await store.testPullDeltaIfPossible()
        let beforeBackground = marks(store)
        store.sceneDidEnterBackground()
        let afterBackground = marks(store)
        var left = false
        d.pullLoader.duringNextRead = ("bookingRequests", {
            left = true
            store.sceneDidEnterBackground()
        })
        _ = await store.testPullDeltaIfPossible()
        let afterPullInFlight = marks(store)
        _ = await store.testPullDeltaIfPossible()
        let afterNextPull = marks(store)
        observed(id, "before=\(beforeBackground) background=\(afterBackground) "
                 + "inFlight=\(afterPullInFlight) next=\(afterNextPull)")
        expect(left, "\(id): sanity: the scene left during the pull")
        expectEqual(beforeBackground, "recovery=true intake=true", "\(id): sanity: a committed pull sets both marks")
        expectEqual(afterBackground, "recovery=false intake=false", "\(id) [M1]: the background clears both marks")
        expectEqual(afterPullInFlight, "recovery=false intake=false",
                    "\(id) [M1]: a pull in flight when the scene left does not set them")
        expectEqual(afterNextPull, "recovery=true intake=true", "\(id) [M1]: the next pull sets them again")
        let app = (try? String(contentsOf: root.appendingPathComponent("native/TradeReadyNative/TradeReadyNativeApp.swift"),
                                   encoding: .utf8)) ?? ""
        let background = app.components(separatedBy: "case .background:").dropFirst().first?
            .components(separatedBy: "case .inactive:").first ?? ""
        expect(background.contains("store.sceneDidEnterBackground()"),
               "\(id) [M1]: the app tells the store when the scene enters the background")
    }

    /// Z2 (review M1): a pull that began before an account boundary never
    /// lets a mirror merge, even when the same owner is back by the time it
    /// commits (the recovery mark now carries the account generation the
    /// pull started under, as the intake mark already did, K6). The mirror
    /// waits, unread; the owner's next activation applies it.
    /// Characterized at 7890ee5: the mark took the generation at the commit,
    /// so the refresh's pass read the mirror's status.
    @MainActor
    static func aPullAcrossABoundaryLeavesMirrorsUnread() async {
        let id = "Z2 boundary then the same owner during the pull"
        let (d, store) = await mirrorOnRelaunch("z2")
        defer { d.cleanup() }
        var changed = false
        d.pullLoader.duringNextRead = ("bookingRequests", {
            changed = true
            store.testApplyCompletedSignOutState()
            store.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
            store.testMarkInitialSyncCompleted(subject: d.subject)
            // The sync re-seeding starts is coalesced into a rerun of the
            // pass in flight; offline, the pull in flight is the only one.
            d.reach.online = false
        })
        await store.performForegroundRefresh()
        let reads = d.links.statusReads
        observed(id, "\(marks(store)) reads=\(reads) mirrors=\(d.items.filter(isMirror).count)")
        expect(changed, "\(id): sanity: the account changed during the pull")
        expect(isSignedIn(store), "\(id): sanity: the same owner is signed in with the gate open")
        expect(!store.testScheduleBookingRecoveryPullCommitted,
               "\(id) [M1]: a pull that began before the boundary does not set the recovery mark")
        expectEqual(reads, 0, "\(id) [M1]: the refresh's pass reads no mirror status")
        expectEqual(d.items.filter(isMirror).count, 1, "\(id) [M1]: the mirror waits")
        d.reach.online = true
        let next = d.launch()
        await d.signIn(next)
        await next.performForegroundRefresh()
        expectEqual(d.items.filter(isMirror).count, 0, "\(id): the owner's next activation applies the mirror")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id): …with the server's token")
    }

    /// Z3 (review M1, R54 N1 (c)): the recovery mark follows the intake
    /// mark's waiting-gate rule (K1c). A pull with the gate open counts;
    /// entering a gate that waits for the owner (the paywall, the starting
    /// point, onboarding) clears it; a pull while the gate waits does not
    /// count, nor once the gate has opened again; the next pull does. So the
    /// pass the gate's exit starts cannot merge a mirror into a pull taken
    /// minutes earlier.
    /// Characterized at 7890ee5: only the intake mark was cleared.
    @MainActor
    static func waitingGatesClearTheRecoveryMark() async {
        let states: [(String, NativeAuthenticationGateState)] = [
            ("paywall", .paywall(offering: nil, message: nil)),
            ("starting point", .startingPoint(.electrical)),
            ("onboarding", .onboarding(.init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1))),
        ]
        for (name, waiting) in states {
            let id = "Z3 \(name)"
            let (d, store) = await intakeDevice("z3-\(name.count)")
            defer { d.cleanup() }
            _ = await store.testPullDeltaIfPossible()
            let gateOpen = store.testScheduleBookingRecoveryPullCommitted
            store.testSetAuthenticationGateState(waiting)
            let entered = store.testScheduleBookingRecoveryPullCommitted
            _ = await store.testPullDeltaIfPossible()
            let pulledWhileWaiting = store.testScheduleBookingRecoveryPullCommitted
            store.testSetAuthenticationGateState(.signedIn(email: nil))
            let reopened = store.testScheduleBookingRecoveryPullCommitted
            _ = await store.testPullDeltaIfPossible()
            let nextPull = store.testScheduleBookingRecoveryPullCommitted
            observed(id, "open=\(gateOpen) entered=\(entered) whileWaiting=\(pulledWhileWaiting) "
                     + "reopened=\(reopened) nextPull=\(nextPull)")
            expect(gateOpen, "\(id): sanity: a pull with the gate open counts")
            expect(!entered, "\(id) [M1]: entering the waiting gate clears the recovery mark")
            expect(!pulledWhileWaiting, "\(id) [M1]: a pull while the gate waits does not count")
            expect(!reopened, "\(id) [M1]: …nor once the gate has opened again")
            expect(nextPull, "\(id) [M1]: the next pull with the gate open counts")
        }
    }

    /// Z4 (review M1 (c), behavioural): the starting point waits for the
    /// owner, and its exit starts a recovery pass. That pass removes the
    /// proof that cannot resolve but reads no mirror status: neither the pull
    /// before the wait nor one during it counts. The next activation's pull,
    /// then its pass, applies the mirror.
    /// Characterized at 7890ee5: the exit's pass read the status and merged
    /// the mirror into the pull taken before the wait.
    @MainActor
    static func aWaitingGatesExitLeavesMirrorsForTheNextPull() async {
        let id = "Z4 starting point exit"
        let (d, store) = await mirrorOnRelaunch("z4")
        defer { d.cleanup() }
        _ = await store.testPullDeltaIfPossible()
        store.testSetAuthenticationGateState(.startingPoint(.electrical))
        _ = await store.testPullDeltaIfPossible()
        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
            accountBinding: d.binding, stage: .personalized,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        d.stage(passMarkerProof)
        do { try store.completeStartingPoint(.fresh) } catch {
            expect(false, "\(id): sanity: the starting point completes (\(error))")
        }
        await waitForGateSitePass(d)
        let readsAtTheExit = d.links.statusReads
        let mirrorsAtTheExit = d.items.filter(isMirror).count
        await store.performForegroundRefresh()
        observed(id, "at the exit: reads=\(readsAtTheExit) mirrors=\(mirrorsAtTheExit); "
                 + "after the next activation: reads=\(d.links.statusReads) items=\(d.items.count)")
        expect(isSignedIn(store), "\(id): sanity: the exit opened the signed-in gate")
        expect(!d.hasPassMarker, "\(id): sanity: the exit's pass ran")
        expectEqual(readsAtTheExit, 0, "\(id) [M1]: the exit's pass reads no mirror status")
        expectEqual(mirrorsAtTheExit, 1, "\(id) [M1]: …and the mirror waits")
        expectEqual(d.items.count, 0, "\(id): the next activation applies the mirror")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id): …with the server's token")
    }

    /// Z5 (review M2, R54 N2): the reset at identity apply, on one AppStore.
    /// A pull commits (the mark is set); the identity is then applied again
    /// (a warm activation). Its gate-site pass reads no mirror status: the
    /// earlier pull no longer counts. W1, W2 and L2 start from a fresh
    /// AppStore with no mark, so they could not catch a lost reset.
    @MainActor
    static func applyingTheIdentityClearsTheRecoveryMark() async {
        let id = "Z5 pull, then the identity applied again"
        let (d, store) = await mirrorOnRelaunch("z5")
        defer { d.cleanup() }
        _ = await store.testPullDeltaIfPossible()
        let marked = store.testScheduleBookingRecoveryPullCommitted
        d.stage(passMarkerProof)
        await applyIdentityAgain(store, d)
        observed(id, "marked=\(marked) reads=\(d.links.statusReads) mirrors=\(d.items.filter(isMirror).count)")
        expect(marked, "\(id): sanity: the pull set the mark")
        expectEqual(d.links.statusReads, 0, "\(id) [M2]: the activation's gate-site pass reads no mirror status")
        expectEqual(d.items.filter(isMirror).count, 1, "\(id) [M2]: the mirror waits")
        expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id) [M2]: nothing is merged")
        expectEqual(d.queued("settings"), 0, "\(id) [M2]: nothing is queued")
    }

    /// Z6 (review M2, R52 invariant): the reset at the foreground refresh's
    /// start, on one AppStore. A pull commits, then the device goes offline
    /// and the refresh's own pull cannot run: the mirror is kept and unread.
    /// Online again, the next activation applies it.
    @MainActor
    static func aFailedForegroundPullKeepsTheMirror() async {
        let id = "Z6 pull, then an offline refresh"
        let (d, store) = await mirrorOnRelaunch("z6")
        defer { d.cleanup() }
        _ = await store.testPullDeltaIfPossible()
        let marked = store.testScheduleBookingRecoveryPullCommitted
        d.reach.online = false
        await store.performForegroundRefresh()
        let readsOffline = d.links.statusReads
        let mirrorsOffline = d.items.filter(isMirror).count
        let queuedOffline = d.queued("settings")
        d.reach.online = true
        await syncAndWait(d)
        await store.performForegroundRefresh()
        observed(id, "marked=\(marked) offline: reads=\(readsOffline) mirrors=\(mirrorsOffline); "
                 + "online: reads=\(d.links.statusReads) items=\(d.items.count)")
        expect(marked, "\(id): sanity: the pull set the mark")
        expectEqual(readsOffline, 0, "\(id) [M2]: the offline refresh's pass reads no mirror status")
        expectEqual(mirrorsOffline, 1, "\(id) [M2]: …and keeps the mirror")
        expectEqual(queuedOffline, 0, "\(id) [M2]: …and queues nothing")
        expectEqual(d.items.count, 0, "\(id): online, the next activation applies the mirror")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken, "\(id): …with the server's token")
    }

    /// Z7 (review M2): a partial pull. A booking mirror merges into the
    /// settings record (a portal mirror into the customer record), so a
    /// refresh whose pull missed the settings or the customers table leaves
    /// the mirror unread. A pull that missed another table (jobs) still
    /// counts.
    @MainActor
    static func aPartialPullKeepsTheMirror() async {
        for table in ["settings", "customers", "jobs"] {
            let counts = table != "jobs"
            let id = "Z7 partial pull, \(table) failed"
            let (d, store) = await mirrorOnRelaunch("z7-\(table)")
            defer { d.cleanup() }
            d.data.injectStatusOnce = (method: "GET", table: table, status: 500)
            await store.performForegroundRefresh()
            observed(id, "reads=\(d.links.statusReads) mirrors=\(d.items.filter(isMirror).count)")
            expect(d.data.injectStatusOnce == nil, "\(id): sanity: the pull read the \(table) table and it failed")
            if counts {
                expectEqual(d.links.statusReads, 0, "\(id) [M2]: the refresh's pass reads no mirror status")
                expectEqual(d.items.filter(isMirror).count, 1, "\(id) [M2]: …and keeps the mirror")
                expectEqual(d.localBookingLink?.token, bookingTokenA, "\(id) [M2]: nothing is merged")
            } else {
                expectEqual(d.links.statusReads, 1, "\(id): a pull that missed only the jobs table counts")
                expectEqual(d.items.filter(isMirror).count, 0, "\(id): …and the mirror is applied")
            }
        }
    }

    /// Z8 (review M5): a recovery pass whose local save fails. The pass runs
    /// automatically, so it says nothing on a screen (`migrationMessage`
    /// would surface later on an unrelated one): it keeps the item, records a
    /// bounded code in the sync status, and the next pass applies it. The
    /// portal merge wrote `migrationMessage`; the booking merge now records
    /// the same code.
    /// Characterized at 7890ee5: the portal pass left "The portal link was
    /// updated on the server but the local copy could not be saved." there.
    @MainActor
    static func aFailedRecoverySaveLeavesNoMessage() async {
        for kind in ["portal", "booking"] {
            let id = "Z8 \(kind) recovery save fails"
            let d = kind == "portal" ? portalDevice("z8-p", portal: (portalTokenC, true))
                : bookingDevice("z8-b", link: (bookingTokenA, true))
            defer { d.cleanup() }
            let first = d.launch()
            await d.signIn(first)
            await d.sync()
            d.failSnapshotSaves(true)
            if kind == "portal" {
                _ = await first.administerPortalLink(customerID: "cust-1", action: .rotate, portalService: d.portalService)
            } else {
                _ = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
            }
            d.failSnapshotSaves(false)
            expectEqual(d.items.filter(isMirror).count, 1, "\(id): sanity: one mirror is staged")
            let store = d.launch()
            await d.signIn(store)
            var armed = true
            store.notificationSynchronizeHook = { _ in
                guard armed else { return }
                armed = false
                d.failSnapshotSaves(true)
            }
            await store.performForegroundRefresh()
            d.failSnapshotSaves(false)
            let message = store.migrationMessage
            let code = store.syncStatus.diagnosticCode
            let kept = d.items.filter(isMirror).count
            store.notificationSynchronizeHook = nil
            await store.performForegroundRefresh()
            let local = kind == "portal" ? d.localPortal?.token : d.localBookingLink?.token
            let server = kind == "portal" ? d.links.portals["cust-1"]?.token : d.links.bookingToken
            observed(id, "migrationMessage=\(message ?? "nil") code=\(code ?? "nil") kept=\(kept) "
                     + "after the next pass: items=\(d.items.count)")
            expect(!armed, "\(id): sanity: the refresh's pull committed before saves failed")
            expectEqual(message, nil, "\(id) [M5]: nothing is left in migrationMessage")
            expectEqual(code, "recovery/local-commit", "\(id) [M5]: the sync status carries the bounded code")
            expectEqual(kept, 1, "\(id) [M5]: the item is kept")
            expectEqual(d.items.count, 0, "\(id): the next pass applies it")
            expectEqual(local, server, "\(id): …with the server's token")
        }
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
        case moveRefused = "F3n the server refused the move (Cloud Sync)"
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
        // Review M1: the server refuses the move; it waits in Cloud Sync.
        if acceptCase == .moveRefused { d.data.injectStatusOnce = (method: "POST", table: "jobs", status: 422) }
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
        case .unscheduledJob, .noJob, .notAcknowledged, .moveRefused: break
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
        case .noJob:
            (false, "This booking doesn't have a job on this device yet. New bookings become jobs the next time "
                + "you open the app and it syncs, so try again then. If you deleted its job, decline the booking "
                + "or contact the customer instead.", false)
        case .notAcknowledged, .requestCopyQueued:
            (false, "Your latest changes haven't reached the server yet. Check your connection, then tap “\(label)” again.", true)
        case .moveRefused:
            (false, "The server refused a change to this booking or its job. Review it in Settings \u{203A} Cloud Sync, "
                + "then tap “\(label)” again.", true)
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
        let subjectB = "99999999-8888-7777-6666-555555555555"
        let bindingB = String(repeating: "c", count: 64)
        for boundary in ["sign-out", "boundary then the same owner", "account B"] {
            for row in RescheduleRow.allCases {
                let id = "F4 \(row.rawValue): \(boundary) during the resolve"
                let (d, store) = await rescheduleDevice("f4-\(boundary.count)-\(row.rawValue)")
                defer { d.cleanup() }
                expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
                // What B has the moment B is signed in (review M6).
                var snapshotAtSwitch: Data?
                var queueAtSwitch: [Canonical.MutationItem] = []
                d.links.duringNextRespond = {
                    switch boundary {
                    case "sign-out":
                        store.scheduleBookingTestClearOwner()
                    case "account B":
                        // Task 12c review M6: a different account signs in.
                        store.testApplyCompletedSignOutState()
                        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
                            accountBinding: bindingB, stage: .done,
                            draft: .init(businessName: "Biz B", contactName: "Owner B", trade: .electrical, step: 1)
                        ))
                        store.testSeedNativeSignedInOwner(subject: subjectB, binding: bindingB)
                        store.testMarkInitialSyncCompleted(subject: subjectB)
                        // Fix round 1 (review Minor 7): B has its own request
                        // with the same id, so an accept that went on after
                        // the switch would write A's result into B's record.
                        var requestB = fixtureRequest()
                        requestB.name = "Bea B"
                        try? d.repository().save(Canonical.Snapshot(payload: Canonical.SnapshotPayload(
                            settings: fixtureSettings(bookingLink: nil), bookingRequests: [requestB])))
                        store.load()
                        snapshotAtSwitch = try? Data(contentsOf: d.storeURL)
                        queueAtSwitch = d.queue.load()
                    default:
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
                if boundary == "account B" {
                    expect(isSignedIn(store), "\(id): sanity: B is signed in with the gate open")
                    expect(snapshotAtSwitch != nil && (try? Data(contentsOf: d.storeURL)) == snapshotAtSwitch,
                           "\(id) [M6]: B's snapshot on disk is untouched by the accept")
                    expectEqual(d.queue.load(), queueAtSwitch, "\(id) [M6]: …and so is B's queue")
                    expectEqual(store.bookingAttentionRows().first { $0.request.id == "req-1" }?.request.status,
                                "reschedule_requested", "\(id) [Minor 7]: B's own request with that id is untouched")
                    expectEqual(d.items.count, 1, "\(id) [Minor 7]: A's staged proof is kept (only a success removes it)")
                    expect(d.items.allSatisfy { $0.ownerBinding == d.binding },
                           "\(id) [M6]: the staged proof stays A's (nothing is staged for B)")
                }
            }
        }
    }

    /// F7 (Task 12c review M2): the committed Worker answers an illegal
    /// transition with 409 `invalid_state` and no status
    /// (`backend-workers/lib/booking/respond.js:61`), which the respond client
    /// reads as `unknown`. Another device confirms or declines while the
    /// resolve is out; the pull after the 409 knows, and the notice says so.
    /// When the pull cannot tell (it fails), the notice stays generic.
    /// Characterized at 5f30dd2: the generic "changed on another device"
    /// notice every time.
    @MainActor
    static func statuslessConflictUsesThePulledStatus() async {
        let cases: [(change: String, server: String, title: String, message: String)] = [
            ("confirmed", "confirmed", "Booking confirmed", "This booking is already confirmed."),
            ("declined", "declined", failureTitle, "This booking was already declined."),
            ("confirmed, the pull fails", "confirmed", failureTitle,
             "This booking changed on another device. Pull down to refresh and check it."),
        ]
        for (index, entry) in cases.enumerated() {
            let id = "F7 status-less 409, \(entry.change) on another device during the resolve"
            let (d, store) = await rescheduleDevice("f7-\(index)")
            defer { d.cleanup() }
            expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
            d.links.statuslessConflicts = true
            d.links.duringNextRespond = {
                if var row = d.links.requestRow("req-1") {
                    row["status"] = entry.server
                    await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
                }
                if index == 2 { d.pullLoader.readsFail = true }
            }
            d.links.resetLog()
            let tapped = await tap(.today, store, d)
            d.pullLoader.readsFail = false
            observed(id, "outcome=\(tapped.outcome) shown=\(tapped.title ?? "-"): \(tapped.message ?? "nothing")")
            expectEqual(d.links.log, ["respond/resolve_reschedule"], "\(id): sanity: the resolve was sent")
            expectEqual(tapped.title, entry.title, "\(id) [M2]: the notice's title")
            expectEqual(tapped.message, entry.message, "\(id) [M2]: …and message")
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
            .confirmed(saved), .confirmed(notSaved), .notLinkedToJob, .jobUnscheduled, .awaitingAck(.queued),
            .awaitingAck(.refused),
            .needsReview(currentStatus: "declined"), .needsReview(currentStatus: "cancelled"),
            .needsReview(currentStatus: "confirmed"), .needsReview(currentStatus: "reschedule_requested"),
            .needsReview(currentStatus: "unknown"), .unknownOutcome, .missing, .accountChanged, .readOnly,
            .failed(.rejectedSession), .failed(.malformedSession), .failed(.invalidConfiguration),
            .failed(.invalidRequest), .failed(.rateLimited), .failed(.unavailable), .failed(.invalidResponse),
        ]
        let tapAgain: [AppStore.BookingRescheduleAcceptOutcome] = [
            .jobUnscheduled, .awaitingAck(.queued), .awaitingAck(.refused),
            .needsReview(currentStatus: "reschedule_requested"),
        ]
        for row in RescheduleRow.allCases {
            for outcome in outcomes {
                let id = "F6 \(row.rawValue) \(outcome)"
                let notice = outcome.ownerNotice(actionLabel: row.actionLabel)
                expect(!notice.message.isEmpty, "\(id) [P12-015]: a message")
                if case .confirmed = outcome {
                    expectEqual(notice.title, "Booking updated", "\(id) [P12-015]: the success title")
                } else if case .needsReview("confirmed") = outcome {
                    expectEqual(notice.title, "Booking confirmed", "\(id) [M4]: already confirmed is not a failure")
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
        expect(message(.awaitingAck(.refused)).contains("Settings \u{203A} Cloud Sync"),
               "F6 [M1]: a refused change points to Cloud Sync")
        expect(!message(.notLinkedToJob).contains("Pull down to refresh"),
               "F6 [M5]: no booking is sent round a pull to refresh that never links it")
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
        await syncAndWait(d)
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
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Gives a pass a gate site might have started time to run.
    @MainActor
    static func settle() async {
        for _ in 0..<60 { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// A push-and-pull pass (a pull to refresh) that also waits out a pass
    /// already running, such as the one a local commit starts, so the queue
    /// has drained when it returns.
    @MainActor
    static func syncAndWait(_ d: Device) async {
        await d.sync()
        _ = await d.coordinator?.waitUntilIdle()
    }

    /// The launch identity a live verification produces for this device's
    /// owner, as `activateMigratedAuthenticatedIdentity` applies it.
    static func liveOutcome(_ d: Device) -> NativeAuthenticatedIdentityActivationOutcome {
        NativeAuthenticatedIdentityActivationOutcome(
            accountState: .noAccountState, newlyStagedCount: 0, alreadyStagedCount: 0,
            typedAccountState: nil, localOwnerVerified: true, accountBinding: d.binding,
            verifiedAccountBinding: d.binding, verifiedUserSubject: d.subject, verifiedEmail: nil,
            verificationSource: .live
        )
    }

    /// A cold launch that runs the real initial sync (fix round 1, review
    /// item 7): a fresh AppStore on the device's files, with the owner's
    /// session in this device's Keychain, applies the live launch identity.
    /// No sync has completed in this process, so the identity outcome begins
    /// the initial-sync gate: the real full pull (`beginInitialSyncGate`,
    /// through the injected service in front of the data server), its
    /// commit, then the onboarding and subscription gates. Offline, the
    /// coordinator's pushes keep what they would send queued; the initial
    /// sync itself reads the data server directly.
    @MainActor
    static func coldLaunch(_ d: Device, onboarding stage: NativeOnboardingDocument.Stage,
                           online: Bool) -> AppStore {
        d.keychain = HostInMemoryKeychain()
        let store = d.launch()
        d.prepareOwner(store)
        try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
            accountBinding: d.binding, stage: stage,
            draft: .init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1)
        ))
        do {
            try NativeKeychainSecureSettingsStore(backend: d.keychain!).publishSupabaseSession(Device.session)
        } catch {
            expect(false, "fixture: the session is in the device's Keychain (\(error))")
        }
        d.reach.online = online
        d.connect(store, subject: d.subject)
        store.testApplyLaunchIdentityOutcome(liveOutcome(d))
        return store
    }

    /// K1: a cold launch through the real initial sync (fix round 1, review
    /// item 7; at badabed modelled with a delta pull and the starting point).
    /// The initial sync's full pull brings the booking, and the subscription
    /// gate then opens the signed-in gate: the booking becomes a lead job and
    /// a customer there, before any scene activation (RN converts once
    /// bootstrapping ends, `App.tsx:396`). The three drafts stay queued while
    /// offline; the next push brings the job, the customer and the linked
    /// request to the cloud.
    /// Characterized at 9a4d845: nothing converts.
    @MainActor
    static func coldLaunchConvertsAfterTheInitialSync() async {
        let id = "K1 cold launch"
        let d = Device("k1")
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await syncAndWait(d)
        await customerBooks(d)
        let relaunched = coldLaunch(d, onboarding: .done, online: false)
        let atStart = relaunched.authenticationGateState
        await waitUntil { isSignedIn(relaunched) && leadJob(d) != nil }
        observed(id, "gate at start=\(atStart) signedIn=\(isSignedIn(relaunched)) \(intakeState(d))")
        expectEqual(atStart, .initialSyncLoading, "\(id): sanity: the launch runs the real initial sync")
        expect(isSignedIn(relaunched), "\(id): sanity: the subscription gate opened the signed-in gate")
        expect(bookingRequest(d) != nil, "\(id): sanity: the initial sync's pull brought the booking")
        expectConverted(d, id)
        expectEqual(d.queued("jobs"), 1, "\(id) [P12-016]: the lead job is queued for the push")
        expectEqual(d.queued("customers"), 1, "\(id) [P12-016]: …and the customer")
        expectEqual(d.queued("bookingRequests"), 1, "\(id) [P12-016]: …and the linked request")
        d.reach.online = true
        await syncAndWait(d)
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead",
                    "\(id) [P12-016]: the cloud has the lead job")
        expectEqual(d.links.requestRow("req-1")?["convertedJobId"] as? String, leadJobID,
                    "\(id) [P12-016]: …and the linked request")
        expectEqual(d.data.liveRowCount(table: "customers", userID: d.subject), 1,
                    "\(id) [P12-016]: …and the customer")
        expectEqual(d.queue.load().count, 0, "\(id): everything reached the server")
    }

    /// K1d (final review M3): K1 on a device with booking history. An
    /// earlier session's delta pull saved a `bookingRequests` watermark (a
    /// booking the owner handled before), and the new booking arrives while
    /// the app is closed, after that watermark. The initial sync saves no
    /// cursor, so the stamp used to be guarded with the old watermark: its
    /// PATCH matched no row and was dropped, the next pull reverted the
    /// stamp, and the booking stayed unlinked until the next activation. The
    /// guard is now the initial sync's own watermark for the table (the
    /// latest `updated_at` it read), so the first push's stamp lands.
    /// Characterized at 7890ee5: the stamp was guarded with the earlier
    /// session's watermark and dropped (`superseded`).
    @MainActor
    static func coldLaunchWithBookingHistoryStampsOnce() async {
        let id = "K1d cold launch with booking history"
        let d = Device("k1d")
        defer { d.cleanup() }
        var handled = workerBooking()
        handled["id"] = "req-0"
        handled["status"] = "cancelled"
        await d.links.upsert(table: "bookingRequests", id: "req-0", record: handled)
        let first = d.launch()
        await d.signIn(first)
        await syncAndWait(d)
        let cursorFile = Canonical.NativeSyncCursorStore(fileURL: d.dir.appendingPathComponent("sync-cursor.json"))
        let earlierWatermark = cursorFile.load().tables["bookingRequests"]
        await customerBooks(d)
        let serverStamp = d.data.storedRow(table: "bookingRequests", id: "req-1", userID: d.subject)?.updatedAt
        let relaunched = coldLaunch(d, onboarding: .done, online: false)
        await waitUntil { isSignedIn(relaunched) && leadJob(d) != nil }
        let guardSince = d.queue.load().first { $0.table == "bookingRequests" && $0.recordId == "req-1" }?.ifUnchangedSince
        d.reach.online = true
        await syncAndWait(d)
        let cloudLinked = d.links.requestRow("req-1")?["convertedJobId"] as? String
        observed(id, "earlier watermark=\(earlierWatermark != nil) guard=\(guardSince == serverStamp ? "the initial sync's" : guardSince == earlierWatermark ? "the earlier session's" : "other") "
                 + "cloudLinked=\(cloudLinked ?? "no") localLinked=\(bookingRequest(d)?.convertedJobId ?? "no")")
        expect(earlierWatermark != nil, "\(id): sanity: an earlier pull saved a bookingRequests watermark")
        expect(serverStamp != nil && serverStamp != earlierWatermark, "\(id): sanity: the booking arrived after it")
        expectEqual(guardSince, serverStamp, "\(id) [M3]: the stamp is guarded with the initial sync's watermark")
        expectEqual(cloudLinked, leadJobID, "\(id) [M3]: the first push's stamp lands on the cloud row")
        expectEqual(bookingRequest(d)?.convertedJobId, leadJobID, "\(id) [M3]: …and the pull after it keeps it on the device")
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead", "\(id): the cloud has the lead job")
        expectEqual(d.queue.load().count, 0, "\(id): everything reached the server")
    }

    /// K1b (review M3): the same cold launch, but the gate waits for the owner
    /// after the initial sync (here the starting point; onboarding and the
    /// paywall wait the same way), for as long as the owner takes. Nothing
    /// converts from a pull taken before the gate opened: not the initial
    /// sync's, and not one that commits during the wait (the sync the gate
    /// change starts, or a background pass). Otherwise the push after a late
    /// conversion could replace another device's newer edit of the same
    /// `jbk_` job. The first activation after the gate opens pulls and
    /// converts.
    /// Characterized at badabed (with the initial-sync seam): the starting
    /// point's exit converted from the older pull.
    @MainActor
    static func gateThatWaitsForTheOwnerConvertsAfterItsNextPull() async {
        let id = "K1b gate waits for the owner"
        let d = Device("k1b")
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await syncAndWait(d)
        await customerBooks(d)
        let relaunched = coldLaunch(d, onboarding: .personalized, online: true)
        await waitUntil {
            if case .startingPoint = relaunched.authenticationGateState { return true }
            return false
        }
        let waiting: Bool
        if case .startingPoint = relaunched.authenticationGateState { waiting = true } else { waiting = false }
        let pulledBeforeWait = bookingRequest(d) != nil
        // A pull that commits while the gate waits (as the syncs the gate
        // changes start do, online).
        _ = await relaunched.testPullDeltaIfPossible()
        do { try relaunched.completeStartingPoint(.fresh) } catch {
            expect(false, "\(id): sanity: the starting point completes (\(error))")
        }
        await settle()
        let atTheGate = intakeState(d)
        let convertedAtTheGate = leadJob(d) != nil || !bookedCustomers(d).isEmpty
        await relaunched.performForegroundRefresh()
        observed(id, "at the gate: \(atTheGate); after the next activation: \(intakeState(d))")
        expect(waiting, "\(id): sanity: the gate waits at the starting point")
        expect(pulledBeforeWait, "\(id): sanity: the initial sync's pull brought the booking")
        expect(isSignedIn(relaunched), "\(id): sanity: the starting point opened the signed-in gate")
        expect(!convertedAtTheGate, "\(id) [M3]: nothing converts from a pull taken before the gate opened")
        expectConverted(d, "\(id): the next activation")
    }

    /// K1c (review M3): the mark rule on its own, for each gate that waits
    /// for the owner. The paywall's exit is the gate-open point this protects
    /// (a purchase or restore after minutes on the paywall), and it needs a
    /// RevenueCat key this host binary does not have, so the gate is walked
    /// through its states and the mark read. A full pull with the gate open
    /// counts; entering the waiting state clears it; a pull while waiting
    /// does not count, nor after the gate opens again; the next full pull
    /// does.
    @MainActor
    static func waitingGatesClearTheMark() async {
        let states: [(String, NativeAuthenticationGateState)] = [
            ("paywall", .paywall(offering: nil, message: nil)),
            ("starting point", .startingPoint(.electrical)),
            ("onboarding", .onboarding(.init(businessName: "Biz", contactName: "Owner", trade: .electrical, step: 1))),
        ]
        for (name, waiting) in states {
            let id = "K1c \(name)"
            let (d, store) = await intakeDevice("k1c-\(name.count)")
            defer { d.cleanup() }
            _ = await store.testPullDeltaIfPossible()
            let gateOpen = store.testBookingIntakePullCommitted
            store.testSetAuthenticationGateState(waiting)
            let entered = store.testBookingIntakePullCommitted
            _ = await store.testPullDeltaIfPossible()
            let pulledWhileWaiting = store.testBookingIntakePullCommitted
            store.testSetAuthenticationGateState(.signedIn(email: nil))
            let reopened = store.testBookingIntakePullCommitted
            _ = await store.testPullDeltaIfPossible()
            let nextPull = store.testBookingIntakePullCommitted
            observed(id, "open=\(gateOpen) entered=\(entered) whileWaiting=\(pulledWhileWaiting) "
                     + "reopened=\(reopened) nextPull=\(nextPull)")
            expect(gateOpen, "\(id): sanity: a full pull with the gate open counts")
            expect(!entered, "\(id) [M3]: entering the waiting gate clears the mark")
            expect(!pulledWhileWaiting, "\(id) [M3]: a pull while the gate waits does not count")
            expect(!reopened, "\(id) [M3]: …nor once the gate has opened again")
            expect(nextPull, "\(id) [M3]: the next full pull with the gate open counts")
        }
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
                await syncAndWait(d)
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
            await syncAndWait(d)
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
                await syncAndWait(d)
                expect(bookingRequest(d) != nil, "\(id): sanity: the booking is on the device")
                d.reach.online = false
            }
            await store.performForegroundRefresh()
            let afterFailedRefresh = intakeState(d)
            let arrived = bookingRequest(d) != nil
            let convertedAfterFailedRefresh = leadJob(d) != nil || !bookedCustomers(d).isEmpty
                || bookingRequest(d)?.convertedJobId != nil
            d.reach.online = true
            await syncAndWait(d)
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
        await syncAndWait(d)
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
        await syncAndWait(d2)
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
    /// its customer reached the cloud; its request stamp has not (a stamp
    /// still in flight, or a conversion that stopped between saving the job
    /// and the request). As RN does (`utils/storage/bookingConversion.ts:66-111`;
    /// the "crash recovery" oracles, `__tests__/bookingConversion.test.ts:147-152`,
    /// `:218-224`), native links the request to that job and that customer
    /// and never touches the job: nothing is queued for it, and after the
    /// push the cloud job is still the other device's. Both clients use the
    /// same deterministic job ID (D-B3-2).
    /// Characterized at 9a4d845: the request is never linked. At badabed the
    /// recheck still dropped this conversion (review M1).
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
        expect(pulled, "\(id): sanity: the refresh's pull committed")
        expectEqual(job?.status, "scheduled", "\(id) [D-B3-2]: the other device's job is kept")
        expectEqual(job?.notes, "Priced on the other device", "\(id) [D-B3-2]: …with its notes")
        expectEqual(job?.estimateTotal, Decimal(350), "\(id) [D-B3-2]: …and its price")
        expectEqual(bookingRequest(d)?.convertedJobId, leadJobID, "\(id) [M1]: the request links that job")
        expectEqual(bookingRequest(d)?.convertedCustomerId, "c-other-1",
                    "\(id) [M1]: …and its customer (found by name: no duplicate)")
        expectEqual(bookedCustomers(d).count, 1, "\(id): one customer on the device")
        expectEqual(d.queued("jobs"), 0, "\(id) [D-B3-2]: nothing is queued for the job")
        expectEqual(d.queued("customers"), 0, "\(id): …or the customer")
        expectEqual(d.queued("bookingRequests"), 1, "\(id) [M1]: the linked request is queued")
        d.reach.online = true
        await syncAndWait(d)
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "scheduled",
                    "\(id) [D-B3-2]: after the push the cloud job is still the other device's")
        expectEqual(d.links.requestRow("req-1")?["convertedJobId"] as? String, leadJobID,
                    "\(id) [M1]: …and the cloud request links it")
        expectEqual(d.data.liveRowCount(table: "jobs", userID: d.subject), 1, "\(id): …the only job")
        expectEqual(d.data.liveRowCount(table: "customers", userID: d.subject), 1, "\(id): …with one customer")
    }

    /// A customer already on the device for the person who books: same name,
    /// a phone number but no email or address.
    static func repeatCustomer() -> Canonical.Customer {
        decodeRecord(Canonical.Customer.self, #"{"id":"cust-sam","name":"Sam Ortiz","email":"","phone":"555-0100","address":"","notes":"repeat"}"#)
    }

    /// K10 (review I1): a repeat customer books. The booking matches the
    /// customer by name, and its email and address fill that customer's blank
    /// fields; the phone the customer already has is kept (a fill never
    /// replaces a value). RN saves this (`upsertCustomerInList`,
    /// `utils/storage/customers.ts:69-86`; `bookingConversion.ts:140`; oracle
    /// `__tests__/bookingConversion.test.ts:201-206`). The filled customer is
    /// saved with the conversion and queued; no second customer is made.
    /// Characterized at badabed: the fill was planned, then dropped by the
    /// recheck, and never redone once the request was stamped.
    @MainActor
    static func aRepeatCustomersBlankFieldsAreFilled() async {
        let id = "K10 repeat customer"
        let d = Device("k10", customers: [repeatCustomer()])
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await syncAndWait(d)
        await customerBooks(d)
        var pulled = false
        first.notificationSynchronizeHook = { _ in
            guard !pulled else { return }
            pulled = true
            d.reach.online = false
        }
        await first.performForegroundRefresh()
        let customers = bookedCustomers(d)
        observed(id, intakeState(d) + " email=\(customers.first?.email.isEmpty == false ? "set" : "blank") "
                 + "address=\(customers.first?.address.isEmpty == false ? "set" : "blank")")
        expect(pulled, "\(id): sanity: the refresh's pull committed")
        expectEqual(customers.count, 1, "\(id): no second customer is made")
        expectEqual(customers.first?.id, "cust-sam", "\(id): the booking is linked to the repeat customer")
        expectEqual(bookingRequest(d)?.convertedCustomerId, "cust-sam", "\(id): …as the request says")
        expectEqual(leadJob(d)?.customerId, "cust-sam", "\(id): …and the job")
        expectEqual(customers.first?.email, "sam@example.test", "\(id) [I1]: the blank email is filled from the booking")
        expectEqual(customers.first?.address, "9 Oak Ave", "\(id) [I1]: …and the blank address")
        expectEqual(customers.first?.phone, "555-0100", "\(id) [I1]: the phone the customer had is kept")
        expectEqual(customers.first?.notes, "repeat", "\(id): …and every other field")
        expectEqual(d.queued("customers"), 1, "\(id) [I1]: the filled customer is queued")
        expectEqual(d.queued("jobs") + d.queued("bookingRequests"), 2, "\(id): …with the job and the linked request")
        d.reach.online = true
        await syncAndWait(d)
        let cloud = d.links.row("customers", "cust-sam")
        expectEqual(cloud?["email"] as? String, "sam@example.test", "\(id) [I1]: the cloud customer has the email")
        expectEqual(cloud?["phone"] as? String, "555-0100", "\(id) [I1]: …and keeps its phone")
        expectEqual(d.data.liveRowCount(table: "customers", userID: d.subject), 1, "\(id): one customer in the cloud")
    }

    /// K10b (review I1, M1): the recheck on its own, with records that changed
    /// between the plan and the commit (AppStore's intake plans and commits
    /// with no suspension, so there it always sees the plan's own records).
    @MainActor
    static func recheckRules() {
        let id = "K10b recheck"
        let settings = fixtureSettings(bookingLink: nil)
        guard let bookingData = try? JSONSerialization.data(withJSONObject: workerBooking()),
              let request = try? JSONDecoder().decode(Canonical.BookingRequest.self, from: bookingData),
              let jobData = try? JSONSerialization.data(withJSONObject: otherDevicesLeadJob()),
              let otherJob = try? JSONDecoder().decode(Canonical.Job.self, from: jobData)
        else {
            expect(false, "\(id): fixture: the booking and the other device's job decode")
            return
        }
        let known = repeatCustomer()
        func plan(jobs: [Canonical.Job]) -> NativeBookingIntake.Plan {
            NativeBookingIntake.plan(requests: [request], jobs: jobs, customers: [known], settings: settings,
                                     makeCustomerID: { "c-new" }, nowISO: { writeStamp })
        }
        func recheck(_ plan: NativeBookingIntake.Plan, jobs: [Canonical.Job],
                     customers: [Canonical.Customer]) -> NativeBookingIntake.Plan? {
            NativeScheduleBookingPolicy.recheckedIntakePlan(plan, currentRequests: [request],
                                                            currentJobs: jobs, currentCustomers: customers)
        }
        func customer(_ plan: NativeBookingIntake.Plan?) -> Canonical.Customer? {
            plan?.customers.first { $0.id == "cust-sam" }
        }
        let fresh = plan(jobs: [])
        let same = recheck(fresh, jobs: [], customers: [known])
        expectEqual(customer(same)?.email, "sam@example.test", "\(id) [I1]: nothing changed: the fill is carried")
        expectEqual(customer(same)?.phone, "555-0100", "\(id) [I1]: …the customer's phone is kept")
        expect(same?.drafts.contains { $0.table == "customers" && $0.recordId == "cust-sam" } == true,
               "\(id) [I1]: …and the filled customer has a draft")
        var filledMeanwhile = known
        filledMeanwhile.email = "sam.work@example.test"
        filledMeanwhile.phone = "555-0199"
        let raced = recheck(fresh, jobs: [], customers: [filledMeanwhile])
        expectEqual(customer(raced)?.email, "sam.work@example.test",
                    "\(id) [I1]: an email set after the plan is never replaced")
        expectEqual(customer(raced)?.phone, "555-0199", "\(id) [I1]: …nor a phone changed after the plan")
        expectEqual(customer(raced)?.address, "9 Oak Ave", "\(id) [I1]: …a field still blank is filled")
        let linkedPlan = plan(jobs: [otherJob])
        let linked = recheck(linkedPlan, jobs: [otherJob], customers: [known])
        expectEqual(linked?.requests.first?.convertedJobId, leadJobID,
                    "\(id) [M1]: a job already on the device when planned: the request is linked")
        expectEqual(linked?.jobs.first?.status, "scheduled", "\(id) [M1]: …the job is untouched")
        expect(linked?.drafts.contains { $0.table == "jobs" } == false, "\(id) [M1]: …and not queued")
        expect(recheck(linkedPlan, jobs: [], customers: [known]) == nil,
               "\(id) [M1]: that job deleted before the commit: nothing is converted")
        expect(recheck(fresh, jobs: [otherJob], customers: [known]) == nil,
               "\(id): the plan's lead appeared meanwhile (another device won): nothing is converted")
    }

    /// K6: the account changes while the foreground refresh's pull is in its
    /// network await (reading the booking table): a sign-out; a switch to
    /// account B with B's gate open (workspace, sign-in, initial sync); or an
    /// account boundary after which the same owner is signed in again (only
    /// the account generation tells them apart). Nothing is converted into
    /// either account's snapshot or queue. In the last case the pull still
    /// commits (the subject is the same) but began before the boundary, so
    /// it does not count (no pull starts after the boundary: the rerun the
    /// re-seeding coalesces into the pass cannot reach the server); the
    /// owner's next launch and activation convert the booking.
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
                    // The sync that re-seeding starts is coalesced into a
                    // rerun of the pass in flight; a pull in that rerun would
                    // start after the boundary and count. Offline, it cannot
                    // run, so the pull in flight is the only one.
                    d.reach.online = false
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
                d.reach.online = true
                let next = d.launch()
                await d.signIn(next)
                await next.performForegroundRefresh()
                expectConverted(d, "\(id): the owner's next activation")
            }
        }
    }

    /// K7: before the initial sync has completed for the signed-in owner,
    /// nothing converts, even though the activation's pull commits and brings
    /// the booking (the gate-open point is reached only after the initial
    /// sync). Once the initial sync has completed, the next activation
    /// converts.
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

    // MARK: Section M (12.00b.2-M, P12-028): stage before save, replay after

    /// M1: the snapshot save succeeds and the queue write fails. Before the
    /// fix the closure that should have staged recovery was empty: the
    /// converted job, customer and request stayed on this device only (the
    /// next intake pass saw the request linked and queued nothing, and a
    /// pull never pushes local records). Now the exact batch is staged before
    /// the save, stays after the failed queue write, and the next activation
    /// queues it and the push brings it to the cloud.
    @MainActor
    static func aFailedIntakeQueueWriteIsStagedAndReplayed() async {
        let id = "M1 queue write fails"
        let (d, store) = await intakeDevice("m1")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        let code = store.syncStatus.diagnosticCode
        observed(id, intakeState(d) + " staged=\(stagedBatches(d).map(\.count)) code=\(code ?? "nil")")
        expectConverted(d, "\(id): the records are saved on the device")
        expectEqual(stagedBatches(d).map(\.count), [3], "\(id) [P12-028]: the three upserts are staged durably")
        expectEqual(Set(stagedBatches(d).first?.map(\.table) ?? []), ["jobs", "customers", "bookingRequests"],
                    "\(id) [P12-028]: …for the job, the customer and the request")
        // The refresh's own recovery pass also fails to queue it and records the
        // later bounded code; either way a queue failure is what the status shows.
        expect(code == "queue/enqueue-booking-intake" || code == "recovery/queue",
               "\(id): the sync status carries a bounded queue code (\(code ?? "nil"))")
        expectEqual(store.migrationMessage, nil, "\(id): nothing is left in migrationMessage")
        d.blockQueue(false)
        await store.performForegroundRefresh()
        await syncAndWait(d)
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead",
                    "\(id) [P12-028]: the next activation queued the batch, and the cloud has the lead job")
        expectEqual(d.links.requestRow("req-1")?["convertedJobId"] as? String, leadJobID,
                    "\(id) [P12-028]: …and the linked request")
        expectEqual(d.data.liveRowCount(table: "customers", userID: d.subject), 1, "\(id) [P12-028]: …and the customer")
        expectEqual(stagedBatches(d).count, 0, "\(id) [P12-028]: the staged batch is cleared once queued")
        expectEqual(d.queue.load().count, 0, "\(id): everything reached the server")
    }

    /// M2: a batch that cannot be staged is not committed. Success is never
    /// reported for records with no durable trace: nothing is saved, nothing
    /// is queued, and the next pass converts normally.
    @MainActor
    static func anIntakeThatCannotStageCommitsNothing() async {
        let id = "M2 stage fails"
        let (d, store) = await intakeDevice("m2")
        defer { d.cleanup() }
        d.blockWorkStore(true)
        await store.performForegroundRefresh()
        let code = store.syncStatus.diagnosticCode
        observed(id, intakeState(d) + " code=\(code ?? "nil")")
        expect(bookingRequest(d) != nil, "\(id): sanity: the pull brought the booking")
        expect(leadJob(d) == nil && bookedCustomers(d).isEmpty && bookingRequest(d)?.convertedJobId == nil,
               "\(id) [P12-028]: nothing is converted")
        expectEqual(d.queued("jobs") + d.queued("customers") + d.queued("bookingRequests"), 0,
                    "\(id): nothing is queued")
        expectEqual(code, "intake/local-commit", "\(id): the sync status carries the bounded code")
        expectEqual(store.migrationMessage, nil, "\(id): nothing is left in migrationMessage")
        d.blockWorkStore(false)
        await store.performForegroundRefresh()
        expectConverted(d, "\(id): the next activation")
        expectEqual(stagedBatches(d).count, 0, "\(id): nothing stays staged after a clean commit")
    }

    /// M3: a staged draft is replayed only while the record on the device
    /// still equals it. A record edited since queued its own newer upsert
    /// (replaying the old one could overwrite it), so the old draft is not
    /// queued; the others are.
    @MainActor
    static func aSupersededStagedDraftIsNotReplayed() async {
        let id = "M3 superseded draft"
        let (d, store) = await intakeDevice("m3")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        d.blockQueue(false)
        expectEqual(stagedBatches(d).map(\.count), [3], "\(id): sanity: the batch is staged")
        // The staged job is an older copy: the job on the device has moved on.
        let current = d.items
        try? d.workStore.removeAll()
        for var item in current {
            if case .stagedBatch(var drafts, let stage) = item.kind,
               let index = drafts.firstIndex(where: { $0.table == "jobs" }) {
                drafts[index].payload = .object(["id": .string(leadJobID), "title": .string("An older title")])
                item.kind = .stagedBatch(drafts: drafts, stage: stage)
            }
            try? d.workStore.stage(item)
        }
        let recovery = await store.recoverScheduleBookingPendingWorkIfPossible()
        observed(id, "queued jobs=\(d.queued("jobs")) customers=\(d.queued("customers")) requests=\(d.queued("bookingRequests"))")
        expectEqual(recovery?.replayedBatches, 1, "\(id): the pass finished the batch")
        expectEqual(d.queued("jobs"), 0, "\(id) [P12-028]: the superseded job draft is not queued")
        expectEqual(d.queued("customers"), 1, "\(id): the customer draft is")
        expectEqual(d.queued("bookingRequests"), 1, "\(id): …and the request draft")
        expectEqual(stagedBatches(d).count, 0, "\(id): the item is cleared")
    }

    /// M4: replay is idempotent. A second pass, and a batch staged twice,
    /// queue nothing again; a record the queue already holds is skipped.
    @MainActor
    static func stagedReplayNeverQueuesTwice() async {
        let id = "M4 replay is idempotent"
        let (d, store) = await intakeDevice("m4")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        d.blockQueue(false)
        let staged = d.items
        let first = await store.recoverScheduleBookingPendingWorkIfPossible()
        let after = d.queue.load().count
        expectEqual(first?.replayedBatches, 1, "\(id): the first pass replays")
        expectEqual(after, 3, "\(id): three upserts are queued")
        // The app ended after the queue write and before the stage was cleared.
        for item in staged { try? d.workStore.stage(item) }
        expectEqual(stagedBatches(d).count, 1, "\(id): sanity: the batch is staged again")
        let second = await store.recoverScheduleBookingPendingWorkIfPossible()
        expectEqual(second?.replayedBatches, 1, "\(id): the second pass finishes the item")
        expectEqual(d.queue.load().count, after, "\(id) [P12-028]: nothing is queued twice")
        expectEqual(stagedBatches(d).count, 0, "\(id): and the item is cleared")
        // The same commit retried stages one item, not two.
        for _ in 0..<2 { for item in staged { try? d.workStore.stage(item) } }
        expectEqual(stagedBatches(d).count, 1, "\(id): an identical batch staged twice is one item")
    }

    /// M5: a staged batch is business data that only this device holds, so
    /// the rollback-readiness check counts its drafts as waiting changes and
    /// is not Ready (a mirror or a proof stays a note).
    @MainActor
    static func aStagedBatchBlocksRollbackReadiness() async {
        let id = "M5 rollback readiness"
        let (d, store) = await intakeDevice("m5")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        let blocked = store.rollbackReadiness()
        observed(id, "blockers=\(blocked.blockers) pending=\(blocked.pendingChangeCount) work=\(blocked.bookingWorkCount)")
        expect(blocked.blockers.contains(.pendingChanges), "\(id) [P12-028]: staged records block the check")
        expectEqual(blocked.pendingChangeCount, 3, "\(id): …counted as three waiting changes")
        expectEqual(blocked.bookingWorkCount, 0, "\(id): …and not as a link-work note")
        d.blockQueue(false)
        await store.performForegroundRefresh()
        await syncAndWait(d)
        expect(!store.rollbackReadiness().blockers.contains(.pendingChanges), "\(id): clear once everything reached the server")
    }

    /// M6: the app ended after the snapshot save and before any queue write
    /// (nothing ran after the save). The stage written before the save is
    /// all that is left; a fresh launch queues it.
    @MainActor
    static func anEndedCommitIsReplayedAtLaunch() async {
        let id = "M6 ended commit"
        let (d, store) = await intakeDevice("m6")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        d.blockQueue(false)
        expectEqual(d.queue.load().count, 0, "\(id): sanity: nothing was queued")
        let relaunched = d.launch()
        await d.signIn(relaunched)
        // The pass the signed-in gate starts at launch (its wiring is pinned
        // by `launchGateOpenRecovers`).
        let pass = await relaunched.recoverScheduleBookingPendingWorkIfPossible()
        expectEqual(pass?.replayedBatches, 1, "\(id): the launch pass replays the batch")
        await syncAndWait(d)
        expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead",
                    "\(id) [P12-028]: a fresh launch queued the staged batch and the cloud has the lead job")
        expectEqual(stagedBatches(d).count, 0, "\(id): the stage is cleared")
    }

    // MARK: Section N (12.00b.2-N, P12-027): durable operation IDs

    /// N1: a first Create whose response is lost. Before the fix each tap sent
    /// a new operation ID and an unknown outcome recorded nothing, so no retry
    /// reused one: the second Create answered `already_exists` and, with no
    /// local token, the screen offered only Create, so no native device could
    /// get a shareable link. Now the ID is staged before the request, survives
    /// a relaunch, and the retry replays it: the server answers with the SAME
    /// stored response (the raw token), and nothing is minted twice.
    @MainActor
    static func aLostBookingCreateIsReplayedByItsOperationID() async {
        let id = "N1 lost Create"
        let d = bookingDevice("n1", link: nil)
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.links.adminMode = .lostAfterCommit
        let lost = await first.administerBookingLink(action: .mint, adminService: d.bookingService)
        let sent = d.links.operationIDs
        expectEqual(lost, .unknownOutcome, "\(id): sanity: the response is lost after the server committed")
        expect(d.links.bookingToken != nil && d.localBookingLink?.token == nil,
               "\(id): sanity: the server has a link and this device has no copy")
        expectEqual(sent.count, 1, "\(id): one request was sent")
        expectEqual(first.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, sent.first,
                    "\(id) [P12-027]: its operation ID is kept")
        let relaunched = d.launch()
        await d.signIn(relaunched)
        expectEqual(relaunched.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, sent.first,
                    "\(id) [P12-027]: …across a relaunch")
        d.links.adminMode = .normal
        let retry = await relaunched.administerBookingLink(action: .mint, adminService: d.bookingService)
        observed(id, "retry=\(retry) ids=\(d.links.operationIDs.count) revision=\(d.links.bookingRevision)")
        expectEqual(d.links.operationIDs, sent + sent, "\(id) [P12-027]: the retry carries the same operation ID")
        expectEqual(d.links.bookingRevision, 1, "\(id) [P12-027]: the server minted once")
        expect({ if case .applied = retry { return true } else { return false } }(), "\(id): the retry is applied")
        expectEqual(d.localBookingLink?.token, d.links.bookingToken,
                    "\(id) [P12-027]: the owner has the link the first request made")
        expectEqual(relaunched.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, nil,
                    "\(id): the operation is cleared once settled")
        expectEqual(d.items.count, 0, "\(id): nothing is left on the device")
    }

    /// N2: a lost Rotate is retried under its ID: one rotation, not two. The
    /// old behaviour made a second new link on the next tap.
    @MainActor
    static func aLostBookingRotateNeverIssuesASecondLink() async {
        let id = "N2 lost Rotate"
        let d = bookingDevice("n2", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.links.adminMode = .lostAfterCommit
        let lost = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        expectEqual(lost, .unknownOutcome, "\(id): sanity: the response is lost")
        let rotatedTo = d.links.bookingToken
        expect(rotatedTo != nil && rotatedTo != bookingTokenA, "\(id): sanity: the server rotated")
        d.links.adminMode = .normal
        let retry = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        expect({ if case .applied = retry { return true } else { return false } }(), "\(id): the retry is applied")
        expectEqual(d.links.bookingRevision, 2, "\(id) [P12-027]: exactly one rotation reached the server")
        expectEqual(d.links.bookingToken, rotatedTo, "\(id) [P12-027]: the server link is the first rotation's")
        expectEqual(d.localBookingLink?.token, rotatedTo, "\(id): …and so is this device's copy")
        expectEqual(Set(d.links.operationIDs).count, 1, "\(id): both requests carried one operation ID")
    }

    /// N3: while a change may be in flight on the server, a different change
    /// waits (nothing is sent). The same change retries.
    @MainActor
    static func aDifferentActionWaitsForAnUnknownOne() async {
        let id = "N3 different action waits"
        let d = bookingDevice("n3", link: (bookingTokenA, true))
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.links.adminMode = .lostAfterCommit
        _ = await first.administerBookingLink(action: .setEnabled, enabled: false, adminService: d.bookingService)
        d.links.adminMode = .normal
        d.links.resetLog()
        let rotate = await first.administerBookingLink(action: .rotate, adminService: d.bookingService)
        let enable = await first.administerBookingLink(action: .setEnabled, enabled: true, adminService: d.bookingService)
        expectEqual(rotate, .failed(reason: "operation-pending"), "\(id) [P12-027]: Rotate waits")
        expectEqual(enable, .failed(reason: "operation-pending"), "\(id): …and so does the opposite Enable")
        expectEqual(d.links.mutations, [], "\(id): neither sent anything")
        let retry = await first.administerBookingLink(action: .setEnabled, enabled: false, adminService: d.bookingService)
        expect({ if case .applied = retry { return true } else { return false } }(), "\(id): the same change retries")
        expectEqual(d.links.bookingEnabled, false, "\(id): the link is disabled")
        expectEqual(first.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, nil,
                    "\(id): and the operation is cleared")
    }

    /// N4: a new request that fails before it is sent leaves nothing pending;
    /// a retry that fails before it is sent leaves the ORIGINAL pending.
    @MainActor
    static func definiteFailuresClearAndRetriesKeepTheOperation() async {
        let id = "N4 definite failures"
        let d = bookingDevice("n4", link: nil)
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        d.links.unreachable = true
        let offline = await store.administerBookingLink(action: .mint, adminService: d.bookingService)
        expectEqual(offline, .failed(reason: "status-unavailable"), "\(id): sanity: the status read fails")
        expectEqual(store.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, nil,
                    "\(id) [P12-027]: a request never sent leaves nothing pending")
        d.links.unreachable = false
        d.links.adminMode = .lostBeforeCommit
        let lost = await store.administerBookingLink(action: .mint, adminService: d.bookingService)
        let original = store.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId
        expectEqual(lost, .unknownOutcome, "\(id): sanity: the mutation's response is an error")
        expect(original != nil, "\(id): it is pending")
        d.links.unreachable = true
        let again = await store.administerBookingLink(action: .mint, adminService: d.bookingService)
        expectEqual(again, .failed(reason: "status-unavailable"), "\(id): a retry that cannot start")
        expectEqual(store.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, original,
                    "\(id) [P12-027]: …keeps the original operation")
        d.links.unreachable = false
        d.links.adminMode = .normal
        let done = await store.administerBookingLink(action: .mint, adminService: d.bookingService)
        expect({ if case .applied = done { return true } else { return false } }(), "\(id): the retry is applied")
        expectEqual(d.links.operationIDs.last, original, "\(id): it carried the original ID")
        expectEqual(d.links.bookingRevision, 1, "\(id): the server minted once (the first never committed)")
    }

    /// N5: the same for a portal link, per customer.
    @MainActor
    static func aLostPortalCreateIsReplayedByItsOperationID() async {
        let id = "N5 lost portal Create"
        let d = portalDevice("n5", portal: nil)
        defer { d.cleanup() }
        let first = d.launch()
        await d.signIn(first)
        await d.sync()
        d.links.adminMode = .lostAfterCommit
        let lost = await first.administerPortalLink(customerID: "cust-1", action: .mint, portalService: d.portalService)
        let sent = d.links.operationIDs
        expectEqual(lost, .unknownOutcome, "\(id): sanity: the response is lost")
        let target = AppStore.portalAdminTarget("cust-1")
        expectEqual(first.pendingAdminOperation(target: target)?.operationId, sent.first, "\(id) [P12-027]: its ID is kept")
        expectEqual(first.pendingAdminOperation(target: AppStore.portalAdminTarget("cust-2")) == nil, true,
                    "\(id): …for that customer only")
        let relaunched = d.launch()
        await d.signIn(relaunched)
        d.links.adminMode = .normal
        let retry = await relaunched.administerPortalLink(customerID: "cust-1", action: .mint, portalService: d.portalService)
        expectEqual(retry, .applied, "\(id): the retry is applied")
        expectEqual(d.links.operationIDs, sent + sent, "\(id) [P12-027]: the retry carries the same operation ID")
        expectEqual(d.localPortal?.token, d.links.portals["cust-1"]?.token,
                    "\(id) [P12-027]: the owner has the link the first request made")
        expectEqual(relaunched.pendingAdminOperation(target: target)?.operationId, nil, "\(id): cleared once settled")
    }

    /// N6: past the server's 30-day replay window an old ID is not retried
    /// (it would be a new mutation under an old ID): a new operation starts.
    @MainActor
    static func anExpiredOperationStartsFresh() async {
        let id = "N6 expired operation"
        let d = bookingDevice("n6", link: nil)
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-31 * 24 * 60 * 60))
        d.stage(.adminOperation(target: AppStore.bookingAdminTarget, action: "mint", enabled: nil,
                                operationId: "old-operation", stagedAt: old))
        expectEqual(store.pendingAdminOperation(target: AppStore.bookingAdminTarget)?.operationId, nil,
                    "\(id): an expired operation is not offered for Retry")
        let outcome = await store.administerBookingLink(action: .mint, operationId: "5e5e5e5e-0000-4000-8000-000000000001", adminService: d.bookingService)
        observed(id, "outcome=\(outcome)")
        expect({ if case .applied = outcome { return true } else { return false } }(), "\(id): a new Create works")
        expectEqual(d.links.operationIDs, ["5e5e5e5e-0000-4000-8000-000000000001"], "\(id) [P12-027]: it used a new ID")
    }

    /// N7: a mutation whose ID cannot be remembered is not sent (a lost
    /// response would leave nothing to replay).
    @MainActor
    static func anOperationThatCannotBeRememberedIsNotSent() async {
        let id = "N7 cannot stage"
        let d = bookingDevice("n7", link: nil)
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        d.blockWorkStore(true)
        d.links.resetLog()
        let outcome = await store.administerBookingLink(action: .mint, adminService: d.bookingService)
        expectEqual(outcome, .failed(reason: "persist"), "\(id) [P12-027]: the change is refused")
        expectEqual(d.links.mutations, [], "\(id): nothing was sent")
        expectEqual(d.links.bookingToken, nil, "\(id): the server has no link")
    }

    /// The pure rules: which operation a call uses and which outcomes settle it.
    @MainActor
    static func adminOperationRules() {
        let id = "N8 rules"
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let pending = NativeScheduleBookingPolicy.PendingAdminOperation(
            target: "booking", action: "rotate", enabled: nil, operationId: "p1", stagedAt: iso)
        typealias P = NativeScheduleBookingPolicy
        expectEqual(P.planAdminOperation(pending: nil, action: "mint", enabled: nil, proposedID: "n", now: now),
                    .fresh("n"), "\(id): nothing pending: a new operation")
        expectEqual(P.planAdminOperation(pending: pending, action: "rotate", enabled: nil, proposedID: "n", now: now),
                    .reuse("p1"), "\(id): the same action reuses its ID")
        expectEqual(P.planAdminOperation(pending: pending, action: "mint", enabled: nil, proposedID: "n", now: now),
                    .blocked(pendingAction: "rotate"), "\(id): another action waits")
        var toggle = pending
        toggle.action = "set_enabled"; toggle.enabled = false
        expectEqual(P.planAdminOperation(pending: toggle, action: "set_enabled", enabled: true, proposedID: "n", now: now),
                    .blocked(pendingAction: "set_enabled"), "\(id): the opposite toggle waits")
        expectEqual(P.planAdminOperation(pending: pending, action: "rotate", enabled: nil, proposedID: "n",
                                         now: now.addingTimeInterval(30 * 24 * 60 * 60)),
                    .fresh("n"), "\(id): past the replay window it is a new operation")
        expect(P.adminOutcomeSettlesOperation(failureReason: nil, unknown: false, createdThisCall: false),
               "\(id): success settles")
        expect(!P.adminOutcomeSettlesOperation(failureReason: nil, unknown: true, createdThisCall: true),
               "\(id): an unknown outcome never settles")
        expect(P.adminOutcomeSettlesOperation(failureReason: "status-unavailable", unknown: false, createdThisCall: true),
               "\(id): a new request that never left settles")
        expect(!P.adminOutcomeSettlesOperation(failureReason: "status-unavailable", unknown: false, createdThisCall: false),
               "\(id): a retry that never left does not")
        expect(P.adminOutcomeSettlesOperation(failureReason: "operationConflict", unknown: false, createdThisCall: false),
               "\(id): an ID the server rejects settles")
        expect(!P.adminOutcomeSettlesOperation(failureReason: "transport", unknown: false, createdThisCall: true),
               "\(id): a transport failure stays pending")
        expect(!P.adminOutcomeSettlesOperation(failureReason: "no-settings", unknown: false, createdThisCall: true),
               "\(id): a failure after the server committed stays pending")
    }

    /// The screens: Retry, the blocked other changes, and Replace for a link
    /// the server has and this device does not.
    @MainActor
    static func adminOperationSources(_ root: URL) {
        func read(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        for (name, path, target) in [
            ("booking", "native/TradeReadyNative/NativeBookingSettingsView.swift", "AppStore.bookingAdminTarget"),
            ("portal", "native/TradeReadyNative/NativeCustomerPortalView.swift", "AppStore.portalAdminTarget(customerID)"),
        ] {
            let view = read(path)
            expect(!view.isEmpty, "N9: the \(name) screen is readable")
            expect(view.contains("store.pendingAdminOperation(target: \(target))"),
                   "N9 [P12-027]: the \(name) screen reads the pending operation")
            expect(view.contains("retryPending(") && view.contains("Retry \\("),
                   "N9 [P12-027]: …and offers Retry")
            expect(view.contains("changesBlocked"), "N9 [P12-027]: …and holds other changes while one is pending")
            expect(view.contains("serverHasLinkWithoutLocalCopy") && view.contains("Replace link"),
                   "N9 [P12-027]: …and offers Replace when the server has a link this device lacks")
            expect(!view.contains("Check the status before trying again"),
                   "N9: …and no longer tells the owner to give up on the request")
        }
    }

    // MARK: Section O (12.00b.2-O, P12-026): rows whose job was deleted

    /// O1: a booking whose linked job was deleted on another device. Today
    /// offered only "View job" and "OK", so the row could never be cleared.
    /// Dismiss stamps `handledAt` (queued as an upsert of the request) and the
    /// row stops surfacing; a reschedule request is answered with Decline.
    @MainActor
    static func aDeletedJobsRowsCanBeAnsweredOrCleared() async {
        let id = "O1 deleted job"
        var cancelled = fixtureRequest(status: "cancelled")
        cancelled.convertedJobId = "job-gone"
        var reschedule = fixtureRequest(status: "reschedule_requested")
        reschedule.id = "req-2"
        reschedule.convertedJobId = "job-gone"
        let d = Device("o1", requests: [cancelled, reschedule])
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await d.sync()
        let rows = store.bookingAttentionRows()
        observed(id, "rows=\(rows.map { "\($0.kind):\($0.request.id)" })")
        expectEqual(rows.filter { $0.kind == .missingJob }.count, 2, "\(id): sanity: both rows surface as missing-job")
        expectEqual(NativeBookingAttention.missingJobAction(for: cancelled), .dismiss, "\(id) [P12-026]: the booking is dismissed")
        expectEqual(NativeBookingAttention.missingJobAction(for: reschedule), .decline, "\(id) [P12-026]: the reschedule is declined")
        let outcome = store.stampBookingRequestHandled(requestID: "req-1")
        expectEqual(outcome, .handled, "\(id) [P12-026]: Dismiss stamps the request")
        expectEqual(store.bookingAttentionRows().map(\.request.id), ["req-2"],
                    "\(id) [P12-026]: the dismissed row stops surfacing; the reschedule stays")
        expect(d.disk?.payload.bookingRequests?.first { $0.id == "req-1" }?.handledAt?.isEmpty == false,
               "\(id): the stamp is saved on the device")
        expectEqual(d.queued("bookingRequests"), 1, "\(id): …and queued for the server")
        // The reschedule row is answered by the owner's decline; the stamp never clears it.
        _ = store.stampBookingRequestHandled(requestID: "req-2")
        expectEqual(store.bookingAttentionRows().map(\.request.id), ["req-2"],
                    "\(id) [P12-026]: a reschedule request stays until it is answered")
    }

    /// Today's dialog for a missing-job row carries the action for its kind and
    /// always a way to clear it.
    @MainActor
    static func missingJobSources(_ root: URL) {
        let today = (try? String(contentsOf: root.appendingPathComponent("native/TradeReadyNative/TodayView.swift"),
                                 encoding: .utf8)) ?? ""
        let start = today.range(of: "        case .missingJob:\n            // P12-026")
        let end = today.range(of: "        case .unconvertedActive:")
        expect(start != nil && end != nil, "O2: Today's missing-job dialog exists")
        let block = (start != nil && end != nil && start!.lowerBound < end!.lowerBound)
            ? String(today[start!.lowerBound..<end!.lowerBound]) : ""
        expect(block.contains("NativeBookingAttention.missingJobAction(for: row.request)"),
               "O2 [P12-026]: it asks the domain which action the row gets")
        expect(block.contains("case .decline:") && block.contains("declineBooking(row)"), "O2: Decline booking for a reschedule request")
        expect(block.contains("case .markDone:") && block.contains("Button(\"Done\")"), "O2: Done for a portal change")
        expect(block.contains("case .dismiss:") && block.contains("Button(\"Dismiss\")"), "O2: Dismiss for any other booking")
        expect(block.contains("Button(\"View job\")"), "O2: View job stays")
    }

    /// M7 (review): an older upsert of the same record is already queued when
    /// the batch is replayed (the app ended after the save, before the queue
    /// write). Matching on the record alone treated it as the staged change,
    /// removed the batch and left the stale payload to be pushed. Now the
    /// staged payload replaces it.
    @MainActor
    static func anOlderQueuedUpsertIsReplacedByTheStagedOne() async {
        let id = "M7 older queued upsert"
        let (d, store) = await intakeDevice("m7")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        d.blockQueue(false)
        let stagedJob = stagedBatches(d).first?.first { $0.table == "jobs" }?.payload
        expect(stagedJob != nil, "\(id): sanity: the job draft is staged")
        _ = try? d.queue.enqueue(table: "jobs", op: .upsert, recordId: leadJobID,
                                 payload: .object(["id": .string(leadJobID), "title": .string("An older queued copy")]))
        _ = await store.recoverScheduleBookingPendingWorkIfPossible()
        let queued = d.queue.load().first { $0.table == "jobs" && $0.recordId == leadJobID }
        expectEqual(d.queued("jobs"), 1, "\(id): one job upsert is queued")
        expectEqual(queued?.payload, stagedJob, "\(id) [review]: it carries the staged payload, not the older copy")
        expectEqual(stagedBatches(d).count, 0, "\(id): the batch is cleared")
    }

    /// M8 (review): an unreadable queue file is never published over. The
    /// staged batch is kept and the file is left as it was.
    @MainActor
    static func anUnreadableQueueKeepsTheStagedBatch() async {
        let id = "M8 unreadable queue"
        let (d, store) = await intakeDevice("m8")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        let recovery = await store.recoverScheduleBookingPendingWorkIfPossible()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: d.dir.appendingPathComponent("mutation-queue.json").path, isDirectory: &isDirectory)
        expect(exists && isDirectory.boolValue, "\(id) [review]: the unreadable queue is left as it was")
        expectEqual(recovery?.replayedBatches, 0, "\(id): nothing was replayed")
        expectEqual(recovery?.retained, 1, "\(id): the item is retained")
        expectEqual(stagedBatches(d).map(\.count), [3], "\(id) [review]: the staged batch is kept")
    }

    /// M9 (review): after the snapshot saved but the queue write failed, a
    /// cold launch pulls before recovery, and the pull puts the server's
    /// unstamped copy of the request back. The staged request stamp is
    /// guarded (`ifUnchangedSince`), so it is still queued, and the server
    /// drops it if the row moved; skipping it would repeat intake and never
    /// send the stamp.
    @MainActor
    static func aPullThatRevertedAGuardedStampStillReplaysIt() async {
        let id = "M9 guarded stamp after a pull"
        let (d, store) = await intakeDevice("m9")
        defer { d.cleanup() }
        d.blockQueue(true)
        await store.performForegroundRefresh()
        d.blockQueue(false)
        let stamp = stagedBatches(d).first?.first { $0.table == "bookingRequests" }
        expect(stamp?.ifUnchangedSince != nil, "\(id): sanity: the staged stamp is guarded")
        // The pull's effect: the local copy is the server's, unstamped.
        if var snapshot = d.disk {
            snapshot.payload.bookingRequests = snapshot.payload.bookingRequests?.map {
                var request = $0; request.convertedJobId = nil; request.convertedCustomerId = nil; return request
            }
            try? d.repository().save(snapshot)
        }
        _ = await store.recoverScheduleBookingPendingWorkIfPossible()
        expectEqual(d.queued("bookingRequests"), 1, "\(id) [review]: the guarded stamp is queued")
        expectEqual(d.queue.load().first { $0.table == "bookingRequests" }?.ifUnchangedSince, stamp?.ifUnchangedSince,
                    "\(id): …still guarded, so a moved server row drops it")
        expectEqual(stagedBatches(d).count, 0, "\(id): the batch is cleared")
    }

    /// M10 (review): the stage is cleared only when nothing durable is left to
    /// send. A snapshot that saved and then failed to APPLY must not lose it
    /// before the queue write.
    @MainActor
    static func stagedCommitKeepsTheStageUntilSavedWorkIsQueued() {
        let id = "M10 staged commit"
        struct Boom: Error {}
        var cleared = 0
        var queued = 0
        typealias P = NativeScheduleBookingPolicy
        let applyFails = P.commitLocalStaged(
            stageBatch: {}, saveSnapshot: {}, applyState: { throw Boom() },
            publishToQueue: { queued += 1 }, clearStage: { cleared += 1 })
        expectEqual(applyFails, .savedNotApplied, "\(id) [review]: saved but not applied is its own outcome")
        expectEqual(queued, 1, "\(id): …and the batch is still queued")
        expectEqual(cleared, 1, "\(id): …after which the stage is cleared")
        cleared = 0; queued = 0
        let queueAlsoFails = P.commitLocalStaged(
            stageBatch: {}, saveSnapshot: {}, applyState: { throw Boom() },
            publishToQueue: { throw Boom() }, clearStage: { cleared += 1 })
        expectEqual(queueAlsoFails, .queueFailedStaged, "\(id): a failed queue write after a failed apply")
        expectEqual(cleared, 0, "\(id) [review]: keeps the stage")
        let saveFails = P.commitLocalStaged(
            stageBatch: {}, saveSnapshot: { throw Boom() }, applyState: {},
            publishToQueue: { queued += 1 }, clearStage: { cleared += 1 })
        expectEqual(saveFails, .snapshotFailed, "\(id): a failed save")
        expectEqual(cleared, 1, "\(id): clears the stage (nothing was saved)")
        expectEqual(queued, 0, "\(id): and queues nothing")
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
        await syncAndWait(d)
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

    // MARK: D. The owner's responses keep the server's booking history (P12-017)

    /// The customer's history on the server row before the owner responds:
    /// booked, then asked to reschedule (`backend-workers/lib/booking/manage.js:83-108`).
    static let customerHistory = ["customer/booked", "customer/request_reschedule"]

    /// The request's history in the cloud row, as "actor/event".
    @MainActor
    static func serverHistory(_ d: Device) -> [String] {
        (d.links.requestRow("req-1")?["history"] as? [[String: Any]] ?? []).map {
            "\($0["actor"] as? String ?? "?")/\($0["event"] as? String ?? "?")"
        }
    }

    /// …and on the device.
    @MainActor
    static func localHistory(_ d: Device) -> [String] {
        (bookingRequest(d)?.history ?? []).map { "\($0.actor)/\($0.event)" }
    }

    @MainActor
    static func serverRequestStatus(_ d: Device) -> String {
        d.links.requestRow("req-1")?["status"] as? String ?? "gone"
    }

    /// The customer acts on the manage page, as the Worker writes it
    /// (`backend-workers/lib/booking/manage.js:83-108`): the new status and a
    /// customer entry appended to the history of the cloud row.
    @MainActor
    static func customerActs(_ d: Device, event: String, status: String) async {
        guard var row = d.links.requestRow("req-1") else {
            expect(false, "fixture: the request is in the cloud")
            return
        }
        var history = row["history"] as? [[String: Any]] ?? []
        history.append(["at": "2026-09-20T00:00:00.000Z", "actor": "customer", "event": event])
        row["history"] = history
        row["status"] = status
        await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
    }

    /// A reschedule-request device (`rescheduleDevice`) whose cloud request
    /// carries the customer's history, as the Worker wrote it, and which has
    /// pulled that row.
    @MainActor
    static func declineDevice(_ tag: String) async -> (Device, AppStore) {
        let (d, store) = await rescheduleDevice(tag)
        if var row = d.links.requestRow("req-1") {
            row["history"] = [
                ["at": "2026-09-10T00:00:00.000Z", "actor": "customer", "event": "booked"],
                ["at": "2026-09-18T00:00:00.000Z", "actor": "customer", "event": "request_reschedule"],
            ]
            await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
        }
        await syncAndWait(d)
        expectEqual(localHistory(d), customerHistory, "\(tag): sanity: the device has the customer's history")
        return (d, store)
    }

    /// Queues a copy of the device's request as it was before the owner's
    /// response, as Today's "Done" does (`stampBookingRequestHandled` queues
    /// the whole row with `handledAt` set). Nothing pushes it here.
    @MainActor
    static func enqueueRequestCopy(_ d: Device) {
        guard let request = bookingRequest(d),
              let bytes = try? JSONEncoder().encode(request),
              case var .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: bytes)
        else {
            expect(false, "fixture: the request copy encodes")
            return
        }
        fields["handledAt"] = .string("2026-09-19T00:00:00.000Z")
        do {
            try d.queue.enqueue(table: "bookingRequests", op: .upsert, recordId: "req-1", payload: .object(fields))
        } catch {
            expect(false, "fixture: the request copy is queued (\(error))")
        }
    }

    /// Back online after an offline stretch: waits out a pass a local commit
    /// started while offline (it ends offline and would defer a rerun), then
    /// runs a pull to refresh (a forced push, then a pull).
    @MainActor
    static func backOnline(_ d: Device) async {
        _ = await d.coordinator?.waitUntilIdle()
        d.reach.online = true
        await syncAndWait(d)
    }

    /// D1: "Decline booking" (`N/TodayView.swift` → `declineBookingRequest`).
    /// The Worker writes the status and appends the owner's decline entry
    /// (`backend-workers/lib/booking/respond.js:64-75`). RN then updates the
    /// request in memory only and pushes nothing: "the server already wrote
    /// status + history … Saving here would push a whole-blob copy"
    /// (`screens/TodayScreen.tsx:559-563`); the next pull brings the server's
    /// row. Characterized at 1dd697b: native queued a whole copy of the
    /// request after the server's write, and the next push replaced the
    /// server's history with the device's, dropping the owner's entry.
    @MainActor
    static func declineKeepsTheServersHistory() async {
        let id = "D1 decline"
        let (d, store) = await declineDevice("d1")
        defer { d.cleanup() }
        d.links.resetLog()
        let outcome = String(describing: await store.declineBookingRequest(
            requestID: "req-1", responseService: d.respondService))
        let queuedAfter = d.queued("bookingRequests")
        let localAfter = d.localRequestStatus
        await syncAndWait(d)
        observed(id, "outcome=\(outcome) sent=\(d.links.log) queuedAfterDecline=\(queuedAfter) "
                 + "server=\(serverRequestStatus(d)) serverHistory=\(serverHistory(d)) "
                 + "local=\(d.localRequestStatus ?? "gone") localHistory=\(localHistory(d))")
        expectEqual(outcome, "applied(status: \"declined\", alreadyApplied: false, savedLocally: true)", "\(id): sanity: the server declined")
        expectEqual(d.links.log, ["respond/decline"], "\(id): one decline is sent")
        expectEqual(queuedAfter, 0, "\(id) [P12-017]: nothing is queued for the request after the server's write")
        expectEqual(localAfter, "declined", "\(id) [P12-017]: the device shows declined straight away")
        expectEqual(serverRequestStatus(d), "declined", "\(id): the cloud row stays declined")
        expectEqual(serverHistory(d), customerHistory + ["owner/decline"],
                    "\(id) [P12-017]: after the next push the cloud row keeps the owner's decline entry")
        expectEqual(d.localRequestStatus, "declined", "\(id) [P12-017]: after the next pull the device shows declined")
        expectEqual(localHistory(d), customerHistory + ["owner/decline"],
                    "\(id) [P12-017]: …with the server's history")
        expectEqual(d.queue.load().count, 0, "\(id): nothing is left queued")
    }

    enum QueuedCopyCase: String, CaseIterable {
        case online = "D2a a copy of the request is queued, online"
        case cannotReachTheServer = "D2b a queued copy of the request cannot reach the server"
        case refused = "D2c the server refused a change to the request (Cloud Sync)"
    }

    /// D2: a copy of the request from before the decline is still queued.
    /// Pushed after the server's decline, it would put the old status and
    /// history back on the cloud row. The rule (P12-017): the decline pushes
    /// what is queued first, so the server appends its entry to that copy;
    /// while a change to the request is still queued, or refused and waiting
    /// in Settings › Cloud Sync (a Retry would push it later), the decline
    /// sends nothing and says why. Characterized at 1dd697b: the decline was
    /// sent at once, the queued copy was replaced by a declined copy of the
    /// device's record, and that was pushed over the server's row.
    @MainActor
    static func aQueuedCopyNeverOverwritesTheDecline() async {
        for copyCase in QueuedCopyCase.allCases {
            let id = copyCase.rawValue
            let (d, store) = await declineDevice("d2-\(QueuedCopyCase.allCases.firstIndex(of: copyCase) ?? 0)")
            defer { d.cleanup() }
            enqueueRequestCopy(d)
            switch copyCase {
            case .online:
                break
            case .cannotReachTheServer:
                d.reach.online = false
            case .refused:
                d.data.injectStatusOnce = (method: "POST", table: "bookingRequests", status: 422)
                await syncAndWait(d)
                expectEqual(d.queued("bookingRequests"), 0, "\(id): sanity: the refused copy left the queue")
                expectEqual(store.rejectedChanges.map(\.key), ["bookingRequests/req-1"],
                            "\(id): sanity: it waits in Cloud Sync")
            }
            d.links.resetLog()
            let outcome = String(describing: await store.declineBookingRequest(
                requestID: "req-1", responseService: d.respondService))
            let sent = d.links.log
            let serverAfter = serverRequestStatus(d)
            let historyAfter = serverHistory(d)
            let queuedAfter = d.queued("bookingRequests")
            observed(id, "outcome=\(outcome) sent=\(sent) server=\(serverAfter) serverHistory=\(historyAfter) "
                     + "queued=\(queuedAfter)")
            switch copyCase {
            case .online:
                expectEqual(outcome, "applied(status: \"declined\", alreadyApplied: false, savedLocally: true)", "\(id): the server declined")
                expectEqual(sent, ["respond/decline"], "\(id): one decline is sent")
                expectEqual(d.links.requestRow("req-1")?["handledAt"] as? String, "2026-09-19T00:00:00.000Z",
                            "\(id) [P12-017]: the queued copy reached the server before the decline")
                expectEqual(queuedAfter, 0, "\(id) [P12-017]: nothing is queued after the decline")
                await syncAndWait(d)
                expectEqual(serverRequestStatus(d), "declined", "\(id) [P12-017]: after the next push the cloud row stays declined")
                expectEqual(serverHistory(d), customerHistory + ["owner/decline"],
                            "\(id) [P12-017]: …and keeps the owner's decline entry")
                expectEqual(localHistory(d), customerHistory + ["owner/decline"],
                            "\(id) [P12-017]: after the next pull the device has the server's history")
            case .cannotReachTheServer, .refused:
                expect(outcome.contains("awaitingAck"),
                       "\(id) [P12-017]: the decline waits for the change to the request (\(outcome))")
                expectEqual(sent, [], "\(id) [P12-017]: …and sends nothing")
                expectEqual(serverAfter, "reschedule_requested", "\(id) [P12-017]: the server still has the request")
                expectEqual(d.localRequestStatus, "reschedule_requested", "\(id): the device still shows it")
                expectEqual(queuedAfter, copyCase == .cannotReachTheServer ? 1 : 0,
                            "\(id): the waiting change is kept where it was")
                // The owner clears what waits (back online; or Discard in
                // Cloud Sync), then declines again.
                if copyCase == .cannotReachTheServer {
                    d.reach.online = true
                } else if let entry = store.rejectedChanges.first {
                    let discarded = await store.discardRejectedChange(id: entry.id)
                    expectEqual(discarded, nil, "\(id): sanity: Discard shows the server's version")
                }
                d.links.resetLog()
                let retried = String(describing: await store.declineBookingRequest(
                    requestID: "req-1", responseService: d.respondService))
                await syncAndWait(d)
                expectEqual(retried, "applied(status: \"declined\", alreadyApplied: false, savedLocally: true)",
                            "\(id) [P12-017]: then the decline goes through")
                expectEqual(serverHistory(d), customerHistory + ["owner/decline"],
                            "\(id) [P12-017]: …and the cloud row keeps the owner's decline entry")
                expectEqual(d.queue.load().count, 0, "\(id): nothing is left queued")
            }
        }
    }

    /// D3: the legacy two-step accept (`prepareBookingReschedule`, then
    /// `resolveBookingReschedule`; test-only since P12-015, the entry Task
    /// 12b's R cases stage proofs through) keeps the server's history the
    /// same way, and refuses while a copy of the request is still queued.
    /// Characterized at 1dd697b: the resolve queued a whole copy of the
    /// request after the server's write.
    @MainActor
    static func legacyResolveKeepsTheServersHistory() async {
        for queuedCopy in [false, true] {
            let id = queuedCopy ? "D3b legacy resolve, a copy of the request still queued" : "D3a legacy resolve"
            let (d, store) = await declineDevice(queuedCopy ? "d3b" : "d3a")
            defer { d.cleanup() }
            let prepared = await store.prepareBookingReschedule(requestID: "req-1", scheduleDraft: rescheduleDraft,
                                                                writeStamp: writeStamp)
            guard case let .proofReady(proof) = prepared else {
                expect(false, "\(id): sanity: the proof is ready (\(prepared))")
                continue
            }
            if queuedCopy {
                d.reach.online = false
                enqueueRequestCopy(d)
            }
            d.links.resetLog()
            let outcome = String(describing: await store.resolveBookingReschedule(
                requestID: "req-1", proof: proof, responseService: d.respondService))
            let sent = d.links.log
            let queuedAfter = d.queued("bookingRequests")
            await backOnline(d)
            observed(id, "outcome=\(outcome) sent=\(sent) queuedAfter=\(queuedAfter) server=\(serverRequestStatus(d)) "
                     + "serverHistory=\(serverHistory(d)) localHistory=\(localHistory(d))")
            if queuedCopy {
                expect(outcome.contains("awaitingAck"), "\(id) [P12-017]: the resolve waits for the copy (\(outcome))")
                expectEqual(sent, [], "\(id) [P12-017]: …and sends nothing")
                expectEqual(serverRequestStatus(d), "reschedule_requested", "\(id): the request still asks for a reschedule")
            } else {
                expectEqual(outcome, "resolved(status: \"confirmed\", alreadyApplied: false)", "\(id): sanity: the server confirmed")
                expectEqual(queuedAfter, 0, "\(id) [P12-017]: nothing is queued for the request after the server's write")
                expectEqual(serverHistory(d), customerHistory + ["owner/resolve_reschedule"],
                            "\(id) [P12-017]: after the next push the cloud row keeps the owner's entry")
                expectEqual(localHistory(d), customerHistory + ["owner/resolve_reschedule"],
                            "\(id) [P12-017]: after the next pull the device has the server's history")
                expectEqual(d.localRequestStatus, "confirmed", "\(id): the device shows confirmed")
            }
        }
    }

    /// D4 (Task 12d review M6, ruling R56): intake stamps the request with its
    /// lead job after a pull, and the stamp is pushed later. A customer's
    /// cancel or reschedule request that reaches the server in between must
    /// survive. RN pushes a whole copy there (`saveBookingRequests`,
    /// `utils/storage/bookingConversion.ts:140-142`), which would put `booked`
    /// back and drop the customer's entry, and on native intake runs by
    /// itself at every activation. With nothing in between, the stamp lands.
    /// Characterized at 1dd697b: the stamp's whole-row push overwrote the
    /// customer's change.
    @MainActor
    static func intakeStampNeverOverwritesTheServer() async {
        for change in ["cancel", "request_reschedule", "none"] {
            let id = change == "none" ? "D4c intake stamp, nothing changed on the server"
                : "D4\(change == "cancel" ? "a" : "b") intake stamp, the customer's \(change) arrives before its push"
            let (d, store) = await intakeDevice("d4-\(change)")
            defer { d.cleanup() }
            var pulled = false
            store.notificationSynchronizeHook = { _ in
                guard !pulled else { return }
                pulled = true
                d.reach.online = false
            }
            await store.performForegroundRefresh()
            expect(pulled, "\(id): sanity: the refresh's pull committed")
            expectEqual(bookingRequest(d)?.convertedJobId, leadJobID, "\(id): sanity: intake stamped the request")
            expectEqual(d.queued("bookingRequests"), 1, "\(id): sanity: the stamp waits to be pushed")
            let target = change == "cancel" ? "cancelled" : change == "request_reschedule" ? "reschedule_requested" : "booked"
            _ = await d.coordinator?.waitUntilIdle()
            if change != "none" { await customerActs(d, event: change, status: target) }
            await backOnline(d)
            let cloud = d.links.requestRow("req-1")
            observed(id, "server=\(serverRequestStatus(d)) serverHistory=\(serverHistory(d)) "
                     + "serverLinked=\(cloud?["convertedJobId"] as? String ?? "no") local=\(d.localRequestStatus ?? "gone") "
                     + intakeState(d))
            expectEqual(serverRequestStatus(d), target,
                        "\(id) [P12-017]: the cloud row keeps the customer's status")
            expectEqual(serverHistory(d), ["customer/booked"] + (change == "none" ? [] : ["customer/\(change)"]),
                        "\(id) [P12-017]: …and the customer's history")
            expectEqual(d.localRequestStatus, target, "\(id) [P12-017]: after the sync the device shows the server's status")
            expectEqual(d.queued("bookingRequests"), 0, "\(id): nothing is left queued for the request")
            expectEqual(d.links.row("jobs", leadJobID)?["status"] as? String, "lead", "\(id): the lead job reached the cloud")
            if change == "none" {
                expectEqual(cloud?["convertedJobId"] as? String, leadJobID, "\(id) [P12-017]: the stamp lands on the cloud row")
            }
            // Fix round 1 (review I1): the stamp was dropped, so the request
            // is linked neither on the server nor on the device, while its
            // lead job still holds the slot on the calendar and route. Today
            // still shows the request's current state, on that job.
            let row = store.bookingAttentionRows().first { $0.request.id == "req-1" }
            if change == "cancel" {
                expectEqual(row?.kind, .cancelled, "\(id) [I1]: Today shows the customer's cancel")
                expectEqual(row?.jobID, leadJobID, "\(id) [I1]: …on the lead job that still holds the slot")
            }
            if change == "request_reschedule" {
                expectEqual(row?.kind, .rescheduleRequested, "\(id) [I1]: Today shows the reschedule request")
                expectEqual(row?.jobID, leadJobID, "\(id) [I1]: …with View job on the lead job")
            }
            if change == "request_reschedule" {
                // The next activation links the request to the job on the
                // device again (`recheckedIntakePlan`, review M1), and with
                // nothing in between that stamp lands.
                await store.performForegroundRefresh()
                await syncAndWait(d)
                expectEqual(d.links.requestRow("req-1")?["convertedJobId"] as? String, leadJobID,
                            "\(id) [P12-017]: the next activation's stamp lands")
                expectEqual(serverRequestStatus(d), "reschedule_requested", "\(id) [P12-017]: …keeping the customer's status")
                expectEqual(serverHistory(d), ["customer/booked", "customer/request_reschedule"],
                            "\(id) [P12-017]: …and history")
            }
        }
    }

    /// D5 (Task 12d review M6): the same for the repeat customer's blank-field
    /// fill (Task 12d fix round 1): another device's edit of that customer
    /// that reaches the server between the pull and the push survives.
    /// Characterized at 1dd697b: the fill's whole-row push put this device's
    /// older copy of the customer back.
    @MainActor
    static func intakeFillNeverOverwritesTheServer() async {
        let id = "D5 repeat customer edited on another device"
        let d = Device("d5", customers: [repeatCustomer()])
        defer { d.cleanup() }
        let store = d.launch()
        await d.signIn(store)
        await syncAndWait(d)
        await customerBooks(d)
        var pulled = false
        store.notificationSynchronizeHook = { _ in
            guard !pulled else { return }
            pulled = true
            d.reach.online = false
        }
        await store.performForegroundRefresh()
        expect(pulled, "\(id): sanity: the refresh's pull committed")
        expectEqual(bookedCustomers(d).first?.email, "sam@example.test", "\(id): sanity: the fill is on the device")
        expectEqual(d.queued("customers"), 1, "\(id): sanity: the filled customer waits to be pushed")
        _ = await d.coordinator?.waitUntilIdle()
        if var row = d.links.row("customers", "cust-sam") {
            row["phone"] = "555-0142"
            row["notes"] = "gate code 4411"
            await d.links.upsert(table: "customers", id: "cust-sam", record: row)
        }
        await backOnline(d)
        let cloud = d.links.row("customers", "cust-sam")
        let local = bookedCustomers(d).first
        observed(id, "cloud phone=\(cloud?["phone"] as? String ?? "?") notes=\(cloud?["notes"] as? String ?? "?") "
                 + "email=\((cloud?["email"] as? String ?? "").isEmpty ? "blank" : "set") local notes=\(local?.notes ?? "?")")
        expectEqual(cloud?["phone"] as? String, "555-0142", "\(id) [P12-017]: the other device's phone survives")
        expectEqual(cloud?["notes"] as? String, "gate code 4411", "\(id) [P12-017]: …and its notes")
        expectEqual(local?.notes, "gate code 4411", "\(id) [P12-017]: after the sync the device shows the other device's edit")
        expectEqual(d.queued("customers"), 0, "\(id): nothing is left queued for the customer")
        expectEqual(d.data.liveRowCount(table: "customers", userID: d.subject), 1, "\(id): one customer in the cloud")
    }

    /// D6: a guarded change the server did not apply sends the table's
    /// watermark back to its guard, so the next pull fetches the row again
    /// although a pull while it was queued may have passed it; a later guard
    /// never moves the watermark forward. A refused guarded change keeps its
    /// guard through Settings › Cloud Sync's Retry.
    @MainActor
    static func aSupersededChangeRefetchesItsRow() async {
        let id = "D6 superseded change"
        let (d, store) = await declineDevice("d6")
        defer { d.cleanup() }
        let cursorStore = Canonical.NativeSyncCursorStore(fileURL: d.dir.appendingPathComponent("sync-cursor.json"))
        let watermark = cursorStore.load().tables["bookingRequests"]
        expect(watermark != nil, "\(id): sanity: the pulls left a watermark")
        let earlier = "2025-09-01T00:00:00.000Z"  // before the data server's first stamp
        func item(_ since: String) -> Canonical.MutationItem {
            Canonical.MutationItem(table: "bookingRequests", op: .upsert, recordId: "req-1",
                                   payload: .object(["id": .string("req-1")]), ts: writeStamp, ifUnchangedSince: since)
        }
        do {
            try store.testSettleRejectedChanges(.init(rejected: [], cleared: [], superseded: [item(earlier)]))
        } catch {
            expect(false, "\(id): the settle step takes it (\(error))")
        }
        expectEqual(cursorStore.load().tables["bookingRequests"], earlier,
                    "\(id) [P12-017]: the watermark goes back to the change's guard")
        do {
            try store.testSettleRejectedChanges(.init(rejected: [], cleared: [], superseded: [item("2099-01-01T00:00:00.000Z")]))
        } catch {
            expect(false, "\(id): the settle step takes a later guard (\(error))")
        }
        expectEqual(cursorStore.load().tables["bookingRequests"], earlier,
                    "\(id) [P12-017]: a later guard never moves the watermark forward")
        await syncAndWait(d)
        expectEqual(localHistory(d), customerHistory, "\(id): the pull from the earlier watermark changes nothing it had")

        let refused = item(earlier)
        do {
            try store.testSettleRejectedChanges(.init(rejected: [NativeMutationRejection(item: refused, statusCode: 400)],
                                                      cleared: [], superseded: []))
        } catch {
            expect(false, "\(id): sanity: the refusal is filed (\(error))")
        }
        _ = store.retryRejectedChange(id: "bookingRequests/req-1")
        expectEqual(d.queue.load().first { $0.recordId == "req-1" }?.ifUnchangedSince, earlier,
                    "\(id) [P12-017]: Retry sends the refused change with its guard")
        // Fix round 1 (review Minor 4): the row moved on since that guard, so
        // the Retry is superseded. It can never succeed, so its Cloud Sync
        // entry goes too, and the pull brings the server's row.
        await syncAndWait(d)
        expectEqual(d.queue.load().count, 0, "\(id) [Minor 4]: the superseded Retry left the queue")
        expectEqual(store.rejectedChanges.map(\.key), [], "\(id) [Minor 4]: …and its Cloud Sync entry is cleared")
        expectEqual(localHistory(d), customerHistory, "\(id) [Minor 4]: the device keeps the server's row")
    }

    /// D7: which intake drafts are guarded. The request stamp and a repeat
    /// customer's fill (records already on the server) carry the watermark of
    /// their table; the lead job and a created customer (new rows) do not; a
    /// table with no watermark yet (a cold launch's conversion, before the
    /// first delta pull) is a plain upsert, as RN pushes it.
    @MainActor
    static func intakeGuardsOnlyRecordsAlreadyOnTheServer() {
        let id = "D7 intake guards"
        let settings = fixtureSettings(bookingLink: nil)
        guard let bookingData = try? JSONSerialization.data(withJSONObject: workerBooking()),
              let request = try? JSONDecoder().decode(Canonical.BookingRequest.self, from: bookingData)
        else {
            expect(false, "\(id): fixture: the booking decodes")
            return
        }
        let marks = ["bookingRequests": "2026-09-27T10:00:00.123456+00:00", "customers": "2026-09-27T09:00:00.000Z"]
        func drafts(customers: [Canonical.Customer], guardSince: [String: String]?) -> [String: String] {
            let plan = NativeBookingIntake.plan(requests: [request], jobs: [], customers: customers, settings: settings,
                                                makeCustomerID: { "c-new" }, nowISO: { writeStamp })
            let rechecked = NativeScheduleBookingPolicy.recheckedIntakePlan(
                plan, currentRequests: [request], currentJobs: [], currentCustomers: customers, guardSince: guardSince)
            return Dictionary(uniqueKeysWithValues: (rechecked?.drafts ?? []).map {
                ("\($0.table)/\($0.recordId)", $0.ifUnchangedSince ?? "plain")
            })
        }
        let repeatCase = drafts(customers: [repeatCustomer()], guardSince: marks)
        expectEqual(repeatCase, ["bookingRequests/req-1": marks["bookingRequests"]!, "jobs/\(leadJobID)": "plain",
                                 "customers/cust-sam": marks["customers"]!],
                    "\(id) [P12-017]: the stamp and the fill are guarded; the lead job is not")
        let newCustomer = drafts(customers: [], guardSince: marks)
        expectEqual(newCustomer, ["bookingRequests/req-1": marks["bookingRequests"]!, "jobs/\(leadJobID)": "plain",
                                  "customers/c-new": "plain"],
                    "\(id) [P12-017]: a created customer is not guarded")
        let noWatermark = drafts(customers: [repeatCustomer()], guardSince: [:])
        expectEqual(Set(noWatermark.values), ["plain"], "\(id): a table with no watermark yet is a plain upsert")
    }

    /// D9 (Task 12c review M9): the test-only legacy prepare compares the
    /// owner and the account generation it started under after its awaits.
    /// An account change during its pull stops it. Characterized at 5f30dd2:
    /// it compared a fresh capture with itself and went on (`superseded`
    /// against the other snapshot).
    @MainActor
    static func legacyPrepareStopsOnAnAccountChange() async {
        let subjectB = "99999999-8888-7777-6666-555555555555"
        let bindingB = String(repeating: "c", count: 64)
        for boundary in ["account B", "boundary then the same owner"] {
            let id = "D9 legacy prepare, \(boundary) during its pull"
            let (d, store) = await rescheduleDevice("d9-\(boundary.count)")
            defer { d.cleanup() }
            var changed = false
            d.pullLoader.duringNextRead = ("bookingRequests", {
                changed = true
                store.testApplyCompletedSignOutState()
                if boundary == "account B" {
                    try? NativeOnboardingStore(snapshotURL: d.storeURL).save(NativeOnboardingDocument(
                        accountBinding: bindingB, stage: .done,
                        draft: .init(businessName: "Biz B", contactName: "Owner B", trade: .electrical, step: 1)
                    ))
                    store.testSeedNativeSignedInOwner(subject: subjectB, binding: bindingB)
                    store.testMarkInitialSyncCompleted(subject: subjectB)
                } else {
                    store.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
                    store.testMarkInitialSyncCompleted(subject: d.subject)
                }
            })
            let prepared = await store.prepareBookingReschedule(requestID: "req-1", scheduleDraft: rescheduleDraft,
                                                                writeStamp: writeStamp)
            observed(id, "outcome=\(prepared)")
            expect(changed, "\(id): sanity: the account changed during the prepare's pull")
            expectEqual(String(describing: prepared), "failed", "\(id) [M9]: the prepare stops")
        }
    }

    /// D10 (fix round 1, review Minor 8): a guarded stamp stays queued (its
    /// push keeps failing) while pulls go on, and those pulls move the
    /// bookingRequests watermark more than the cursor's 5-minute overlap past
    /// the stamp's guard. The customer's cancel landed just after the guard.
    /// When the push finally runs, the stamp is superseded; lowering the
    /// watermark to the guard, not the overlap, makes the next pull fetch the
    /// cancelled row, so the device shows it.
    @MainActor
    static func aLongQueuedStampRefetchesItsRow() async {
        let id = "D10 a stamp queued while the watermark moved on"
        let (d, store) = await intakeDevice("d10")
        defer { d.cleanup() }
        var pulled = false
        store.notificationSynchronizeHook = { _ in
            guard !pulled else { return }
            pulled = true
            d.reach.online = false
        }
        await store.performForegroundRefresh()
        _ = await d.coordinator?.waitUntilIdle()
        let guardStamp = d.queue.load().first { $0.table == "bookingRequests" }?.ifUnchangedSince
        expect(guardStamp != nil, "\(id): sanity: the stamp waits, guarded")
        await customerActs(d, event: "cancel", status: "cancelled")
        // Ten minutes later a second booking arrives, so the next pull moves
        // the watermark far past the guard.
        d.data.advanceClock(seconds: 600)
        var second = workerBooking()
        second["id"] = "req-2"
        await d.links.upsert(table: "bookingRequests", id: "req-2", record: second)
        // The stamp's push keeps failing while the pulls run.
        d.data.failRequests = (method: "PATCH", table: "bookingRequests", status: 503)
        d.reach.online = true
        await syncAndWait(d)
        let cursorStore = Canonical.NativeSyncCursorStore(fileURL: d.dir.appendingPathComponent("sync-cursor.json"))
        let moved = cursorStore.load().tables["bookingRequests"]
        var gap: TimeInterval = 0
        if let movedDate = moved.flatMap(InMemorySupabase.parse),
           let guardDate = guardStamp.flatMap(InMemorySupabase.parse) {
            gap = movedDate.timeIntervalSince(guardDate)
        }
        expect(gap > 300, "\(id): sanity: the watermark moved more than 5 minutes past the guard (\(gap) s)")
        expectEqual(d.queued("bookingRequests"), 1, "\(id): sanity: the stamp is still queued")
        expectEqual(d.localRequestStatus, "booked", "\(id): sanity: while queued the device keeps its stamped copy")
        d.data.failRequests = nil
        await syncAndWait(d)
        observed(id, "server=\(serverRequestStatus(d)) local=\(d.localRequestStatus ?? "gone") "
                 + "watermarkGap=\(Int(gap))s " + intakeState(d))
        expectEqual(serverRequestStatus(d), "cancelled", "\(id) [P12-017]: the cloud keeps the customer's cancel")
        expectEqual(d.queued("bookingRequests"), 0, "\(id): the superseded stamp left the queue")
        expectEqual(d.localRequestStatus, "cancelled",
                    "\(id) [Minor 8]: the lowered watermark makes the next pull bring the cancelled row")
        expectEqual(store.bookingAttentionRows().first { $0.request.id == "req-1" }?.kind, .cancelled,
                    "\(id) [I1]: …and Today shows the cancel")
    }

    /// D11 (fix round 1, review I1): the attention selector on its own. A
    /// booking whose stamp never landed is still shown through its lead job,
    /// whose id is deterministic (`jbk_<requestId>`, RN
    /// `utils/storage/bookingConversion.ts:66`); a stamp wins over it, and a
    /// row still self-dismisses as RN's does (`utils/bookingAttention.ts:33-43`).
    @MainActor
    static func attentionFindsTheLeadJobOfAnUnlinkedBooking() {
        let id = "D11 attention"
        guard let leadData = try? JSONSerialization.data(withJSONObject: otherDevicesLeadJob()),
              let lead = try? JSONDecoder().decode(Canonical.Job.self, from: leadData)
        else {
            expect(false, "\(id): fixture: the lead job decodes")
            return
        }
        func request(_ status: String, stamp: String? = nil) -> Canonical.BookingRequest {
            var fields = workerBooking()
            fields["status"] = status
            if let stamp { fields["convertedJobId"] = stamp }
            let data = try! JSONSerialization.data(withJSONObject: fields)
            return try! JSONDecoder().decode(Canonical.BookingRequest.self, from: data)
        }
        func rows(_ request: Canonical.BookingRequest, _ jobs: [Canonical.Job]) -> [String] {
            NativeBookingAttention.select(requests: [request], jobs: jobs).map { "\($0.kind.rawValue) \($0.jobID ?? "-")" }
        }
        expectEqual(rows(request("cancelled"), [lead]), ["cancelled \(leadJobID)"],
                    "\(id) [I1]: a cancelled booking with no stamp shows on its lead job")
        expectEqual(rows(request("declined"), [lead]), ["cancelled \(leadJobID)"],
                    "\(id) [I1]: …and so does a declined one")
        expectEqual(rows(request("cancelled"), []), [], "\(id): with no lead job there is nothing to show (RN)")
        var moved = lead
        moved.scheduledDate = "2026-09-30"
        expectEqual(rows(request("cancelled"), [moved]), [], "\(id): a lead job moved off the slot self-dismisses the row (RN)")
        var stamped = lead
        stamped.id = "job-9"
        expectEqual(rows(request("cancelled", stamp: "job-9"), [stamped, lead]), ["cancelled job-9"],
                    "\(id) [I1]: a stamp wins over the lead job's id")
        expectEqual(rows(request("reschedule_requested"), [lead]), ["rescheduleRequested \(leadJobID)"],
                    "\(id) [I1]: a reschedule request with no stamp opens its lead job")
        expectEqual(rows(request("confirmed"), [lead]), [],
                    "\(id) [I1]: a confirmed booking whose lead job exists is not waiting to be scheduled")
        expectEqual(rows(request("confirmed"), []), ["unconvertedActive -"],
                    "\(id): one with no job still is (D-B3-1)")
    }

    /// D12 (fix round 1, review Minor 1): the decline's and the legacy
    /// resolve's error paths pull after a refusal. The account changes during
    /// that pull: the outcome says so, not "changed on another device".
    @MainActor
    static func aRefusalsPullStopsOnAnAccountChange() async {
        for flow in ["decline", "legacy resolve"] {
            let id = "D12 \(flow): the account changes during the pull after a refusal"
            let (d, store) = await declineDevice("d12-\(flow.count)")
            defer { d.cleanup() }
            var proof: NativeScheduleProof?
            if flow == "legacy resolve" {
                guard case let .proofReady(ready) = await store.prepareBookingReschedule(
                    requestID: "req-1", scheduleDraft: rescheduleDraft, writeStamp: writeStamp) else {
                    expect(false, "\(id): sanity: the proof is ready")
                    continue
                }
                proof = ready
            }
            var changed = false
            d.links.duringNextRespond = {
                // The customer cancels first (the server answers 409)…
                if var row = d.links.requestRow("req-1") {
                    row["status"] = "cancelled"
                    await d.links.upsert(table: "bookingRequests", id: "req-1", record: row)
                }
                // …and an account boundary passes during the pull after it.
                d.pullLoader.duringNextRead = ("bookingRequests", {
                    changed = true
                    store.testApplyCompletedSignOutState()
                    store.testSeedNativeSignedInOwner(subject: d.subject, binding: d.binding)
                    store.testMarkInitialSyncCompleted(subject: d.subject)
                })
            }
            let outcome: String
            if let proof {
                outcome = String(describing: await store.resolveBookingReschedule(
                    requestID: "req-1", proof: proof, responseService: d.respondService))
            } else {
                outcome = String(describing: await store.declineBookingRequest(
                    requestID: "req-1", responseService: d.respondService))
            }
            observed(id, "outcome=\(outcome)")
            expect(changed, "\(id): sanity: the account changed during the pull")
            expectEqual(outcome, "failed(reason: \"owner-changed\")", "\(id) [Minor 1]: the outcome says the account changed")
        }
    }

    /// D13 (fix round 1, review Minor 2): the server declined, but this
    /// device could not save the status. The acting screen says so, as the
    /// accept does; nothing is queued, and the next pull brings the row.
    @MainActor
    static func aDeclineWhoseLocalSaveFailsSaysSo() async {
        let id = "D13 decline, the local save fails"
        let (d, store) = await declineDevice("d13")
        defer { d.cleanup() }
        d.failSnapshotSaves(true)
        let outcome = await store.declineBookingRequest(requestID: "req-1", responseService: d.respondService)
        d.failSnapshotSaves(false)
        let notice = outcome.declineNotice(actionLabel: "Decline booking")
        observed(id, "outcome=\(outcome) shown=\(notice?.title ?? "-"): \(notice?.message ?? "nothing")")
        expectEqual(serverRequestStatus(d), "declined", "\(id): sanity: the server declined")
        expect(String(describing: outcome).contains("savedLocally: false"),
               "\(id) [Minor 2]: the outcome says this device did not save it")
        expect(notice?.message.contains("This device couldn't save the change yet. Pull down to refresh.") == true,
               "\(id) [Minor 2]: the acting screen says so, as the accept does")
        expectEqual(d.queued("bookingRequests"), 0, "\(id) [P12-017]: nothing is queued")
        await syncAndWait(d)
        expectEqual(d.localRequestStatus, "declined", "\(id): the next pull brings the declined row")
    }

    /// D14 (fix round 1, review Minor 5): the rejected-change store cannot be
    /// read (before the first unlock after a restart, or no verified owner
    /// for a file on disk). The response waits, fail closed, but the notice
    /// does not send the owner to check the connection.
    @MainActor
    static func anUnreadableRejectedStoreSaysWaitAMoment() async {
        for flow in ["decline", "accept"] {
            let id = "D14 \(flow), the rejected-change store cannot be read"
            let (d, store) = await declineDevice("d14-\(flow.count)")
            defer { d.cleanup() }
            if flow == "accept" {
                expect(ownerMovesTheJob(store), "\(id): sanity: the schedule editor saves the move")
                await syncAndWait(d)
            }
            let other = Canonical.MutationItem(table: "jobs", op: .upsert, recordId: "job-other",
                                               payload: .object(["id": .string("job-other")]), ts: writeStamp)
            do {
                try store.testSettleRejectedChanges(.init(rejected: [NativeMutationRejection(item: other, statusCode: 422)],
                                                          cleared: []))
            } catch {
                expect(false, "\(id): sanity: a refusal of another record is filed (\(error))")
            }
            let file = d.dir.appendingPathComponent("rejected-changes.json")
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            d.links.resetLog()
            let outcome: String
            let message: String
            if flow == "accept" {
                let tapped = await tap(.today, store, d)
                outcome = tapped.outcome
                message = tapped.message ?? ""
            } else {
                let result = await store.declineBookingRequest(requestID: "req-1", responseService: d.respondService)
                outcome = String(describing: result)
                message = result.declineNotice(actionLabel: "Decline booking")?.message ?? ""
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            observed(id, "outcome=\(outcome) shown=\(message) sent=\(d.links.log)")
            expectEqual(d.links.log, [], "\(id): nothing is sent (fail closed)")
            expect(outcome.contains("unreadable"), "\(id) [Minor 5]: the wait says the store could not be read")
            expect(message.contains("moment") && !message.contains("connection"),
                   "\(id) [Minor 5]: the notice says to try again in a moment, not to check the connection")
        }
    }

    /// D8: every decline outcome but a decline has a plain notice for both
    /// screens (RN's failure alert, `screens/TodayScreen.tsx:557`); the
    /// screens show it; neither the decline nor the legacy resolve queues
    /// the request.
    @MainActor
    static func declineNoticesAndPins(_ root: URL) {
        let id = "D8 decline notices"
        let labels = ["Decline booking", "Decline"]
        let outcomes: [AppStore.OwnerResponseOutcome] = [
            .awaitingAck(.queued), .awaitingAck(.refused), .needsReview(currentStatus: "declined"),
            .needsReview(currentStatus: "cancelled"), .needsReview(currentStatus: "unknown"), .unknownOutcome, .missing,
            .failed(reason: "session"), .failed(reason: "configuration"), .failed(reason: "owner-changed"),
            .failed(reason: "read-only"), .failed(reason: "invalid-request"), .failed(reason: "transient"),
            .failed(reason: "transport"),
        ]
        for label in labels {
            expect(AppStore.OwnerResponseOutcome.applied(status: "declined", alreadyApplied: false)
                    .declineNotice(actionLabel: label) == nil, "\(id) \(label) [P12-017]: a decline shows nothing (RN)")
            for outcome in outcomes {
                let notice = outcome.declineNotice(actionLabel: label)
                expect(notice?.message.isEmpty == false, "\(id) \(label) \(outcome) [P12-017]: a message")
                if case .needsReview("declined") = outcome {
                    expectEqual(notice?.title, "Booking declined", "\(id) \(label): already declined is not a failure")
                } else {
                    expectEqual(notice?.title, failureTitle, "\(id) \(label) \(outcome) [P12-017]: RN's failure title")
                }
            }
            expect(AppStore.OwnerResponseOutcome.awaitingAck(.queued).declineNotice(actionLabel: label)?.message
                    .contains("tap \u{201C}\(label)\u{201D} again") == true, "\(id) \(label) [P12-017]: names this screen's button")
            expect(AppStore.OwnerResponseOutcome.awaitingAck(.refused).declineNotice(actionLabel: label)?.message
                    .contains("Cloud Sync") == true, "\(id) \(label) [P12-017]: a refused change points to Cloud Sync")
        }
        func read(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        func body(_ source: String, from start: String) -> String {
            guard let lower = source.range(of: start),
                  let upper = source.range(of: "\n    }\n", range: lower.upperBound..<source.endIndex)
            else { return "" }
            return String(source[lower.lowerBound..<upper.upperBound])
        }
        let today = body(read("native/TradeReadyNative/TodayView.swift"), from: "    private func declineBooking(")
        let requests = body(read("native/TradeReadyNative/NativeBookingRequestsView.swift"), from: "    private func decline(")
        expect(today.contains("declineNotice(actionLabel: \"Decline booking\")"), "S-D [P12-017]: Today shows the decline's notice")
        expect(requests.contains("declineNotice(actionLabel: \"Decline\")"), "S-D [P12-017]: Requests shows the decline's notice")
        let store = read("native/TradeReadyNative/AppStore.swift")
        for (name, start) in [("the decline", "    func declineBookingRequest("),
                              ("the legacy resolve", "    func resolveBookingReschedule(")] {
            let text = body(store, from: start)
            expect(!text.isEmpty && !text.contains("enqueue") && !text.contains("mergeBookingRequestStatus"),
                   "S-D [P12-017]: \(name) queues nothing for the request")
            expect(text.contains("saveServerBookingRequestStatus(") && text.contains("ownerResponseWait(for:"),
                   "S-D [P12-017]: \(name) saves the server's status locally and waits for a change to the request")
        }
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
        if let reset = outcome.range(of: resetMark), let gate = outcome.range(of: "advancePastInitialSync(") {
            expect(reset.upperBound < gate.lowerBound,
                   "S-K: applying the identity clears the intake mark before it can open the gate")
        } else {
            expect(false, "S-K: applying the identity clears the intake mark")
        }
        // Launch: the subscription gate's signed-in exit, the point a cold
        // launch reaches right after the initial sync, starts intake, then
        // recovery.
        let subscription = body(store, from: "    private func advancePastSubscriptionGate() {") ?? ""
        if let intake = subscription.range(of: start), let recovery = subscription.range(of: recover) {
            expect(intake.upperBound < recovery.lowerBound,
                   "S-K [P12-016]: the subscription gate's signed-in exit starts intake, then recovery")
        } else {
            expect(false, "S-K [P12-016]: the subscription gate's signed-in exit starts intake")
        }
        // Review M4 and M3: the other two gate-open points could never
        // convert, so they start no intake. A returning launch's consumer
        // block runs in the same synchronous call that cleared the mark, and
        // the starting point's exit follows a gate that waited for the owner.
        let neverConvert = [
            ("a returning launch's signed-in gate",
             body(store, from: "        if activateConsumers, case .signedIn = authenticationGateState {", to: "\n        }\n") ?? ""),
            ("the starting point's exit", body(store, from: "    func completeStartingPoint(") ?? ""),
        ]
        for (site, text) in neverConvert {
            expect(!text.isEmpty && text.contains(recover) && !text.contains(start),
                   "S-K [M4]: \(site) starts recovery but no intake")
        }
        // Review M3: a gate that waits for the owner clears the mark, and no
        // pull marks while it waits.
        let gateState = body(store, from: "    @Published private(set) var authenticationGateState") ?? ""
        let waitingClear = gateState.components(separatedBy: "if Self.gateWaitsForOwner(authenticationGateState) {")
            .dropFirst().first?.components(separatedBy: "}").first ?? ""
        expect(waitingClear.contains("bookingIntakePullMark = nil"),
               "S-K [M3]: entering a gate that waits for the owner clears the intake mark")
        expect(waitingClear.contains("scheduleBookingRecoveryPullMark = nil"),
               "S-K [final review M1]: …and the recovery mark")
        let waits = body(store, from: "    private static func gateWaitsForOwner(") ?? ""
        expect([".onboarding", ".startingPoint", ".paywall"].allSatisfy(waits.contains),
               "S-K [M3]: onboarding, the starting point and the paywall wait for the owner")
        let waitingGuard = "guard period == pullMarkPeriod, !Self.gateWaitsForOwner(authenticationGateState) else { return }"
        for function in ["markBookingIntakePullCommitted(", "markScheduleBookingRecoveryPullCommitted("] {
            let mark = body(store, from: "    private func " + function) ?? ""
            expect(mark.contains(waitingGuard),
                   "S-K [M3, final review M1]: \(function)) marks nothing while the gate waits or after the background")
        }
        // Review M5: the own-pull entry is a host-test entry only.
        let sourceRoot = root.appendingPathComponent("native", isDirectory: true)
        var productionCalls: [String] = []
        for folder in ["TradeReadyNative", "TradeReadyWidgets"] {
            let enumerator = FileManager.default.enumerator(at: sourceRoot.appendingPathComponent(folder),
                                                            includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.components(separatedBy: "\n")
                where line.contains("runBookingIntakeAfterVerifiedPull(") && !line.contains("func runBookingIntakeAfterVerifiedPull(") {
                    productionCalls.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        expectEqual(productionCalls, [], "S-K [M5]: nothing in the app calls runBookingIntakeAfterVerifiedPull")
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
        let setMark = "markScheduleBookingRecoveryPullCommitted("
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
        // Final review M1: both pulls hand the recovery mark the account
        // generation and the period they started under (Z1 and Z2 prove the
        // delta pull's behaviourally; the initial sync is pinned here).
        let startedUnder = "subject: subject, generation: boundaryGeneration, period: markPeriod"
        for (name, text) in [("the initial sync", initialSync), ("a delta pull", deltaPull)] {
            expect(text.contains("let boundaryGeneration = accountBoundaryGeneration")
                   && text.contains("let markPeriod = pullMarkPeriod")
                   && text.components(separatedBy: startedUnder).count - 1 == 2,
                   "S [final review M1]: \(name) marks with the generation and period it started under")
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
