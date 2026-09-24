import Foundation

// Task 11.06 (L1, L2): the deep-link gate policy, kept pure so the whole state
// machine is host-testable without SwiftUI.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §6.1 (grammar, `NativeDeepLinkParser`), §6.2 (gate order, the tagged
// `pendingOpenUrl` stash, parking), §2.5 and C22 (the single owner predicate
// `O = AppStore.derivedStatePublishBinding`), C10, C11 (P8).
//
// Gate order for every candidate route, warm or cold:
//   1. intercept (Google callback in `NativeOpenURLDispatch`, then the
//      password-recovery link inside `AppStore.handle(url:)`);
//   2. parse (`NativeDeepLinkParser`; malformed/oversized → dropped, no side
//      effect);
//   3. the stash is read AND removed under the shared lock
//      (`NativePendingOpenURLConsumer.take`);
//   4. not `.signedIn` → park (at most one, newest wins);
//   5. exact owner: `O != nil`, the stash tag equals `hash(O)`, a warm URL's
//      arrival binding is nil or equals `O`;
//   6. record: the job exists in the CURRENT owner's data, is not archived
//      (one recorded exception: a `job` link to an archived job whose timer
//      is running, which the Job Timer widget still shows), and (`onmyway`
//      only) is not in a done status.
// AppStore owns applying the decision; nothing here navigates.

/// Where a candidate route came from (§6.2 step 4).
enum NativeDeepLinkSource: Equatable, Sendable {
    /// `onOpenURL`, the launch URL, or the in-process On My Way router.
    case warmURL
    /// The App Group `pendingOpenUrl` stash written by `OnMyWayIntent`.
    case coldStash
}

/// One candidate route, as it arrived or as it is parked.
struct NativeDeepLinkCandidate: Equatable, Sendable {
    let route: NativeDeepLinkParser.Route
    let source: NativeDeepLinkSource
    /// The stash's `ownerTag`. Required for `.coldStash`; for a warm On My Way
    /// URL it is the tag of the matching stash that the warm route removed
    /// (the same Siri run), so the warm route keeps the stash's owner proof.
    let ownerTag: String?
    /// `O` when a warm URL arrived (nil when there was none). Always nil for
    /// the stash, whose owner proof is the tag.
    let arrivalBinding: String?
    /// Arrival time (warm) or the stash's `at` (cold).
    let at: Date
}

/// The gate phases routing cares about (mapped from
/// `NativeAuthenticationGateState` by `AppStore.deepLinkGatePhase`).
enum NativeDeepLinkGatePhase: Equatable, Sendable {
    /// `.signedIn`: routes may apply.
    case signedIn
    /// `.signedOut`, `.accountMismatch`, `.unavailable`: entering one of these
    /// discards a parked route (§6.2 step 4).
    case closed
    /// Every other gate (loading, initial sync, subscription, paywall,
    /// starting point, onboarding, password recovery): a route parks.
    case pending
}

/// What the record lookup found in the current owner's data.
struct NativeDeepLinkRecord: Equatable, Sendable {
    let isArchived: Bool
    let status: String
    /// The job has an open time session (`NativeTimeTracking.activeSession`),
    /// i.e. the Job Timer widget is showing it running.
    let hasRunningTimer: Bool
}

enum NativeDeepLinkDiscardReason: Equatable, Sendable {
    /// `.signedIn` without the exact workspace (`O == nil`).
    case noExactOwner
    /// A stash tag that is not `hash(O)`, or a warm arrival binding that is
    /// not `O`.
    case ownerMismatch
    /// Older than `pendingOpenURLMaximumAge`, or stamped in the future.
    case stale
    case missingRecord
    case archivedRecord
    /// `onmyway` for a job in a done status (native deviation, §6.2 step 6).
    case finishedRecord

    /// Record failures surface the existing "Job not found" state (§6.2
    /// step 6). Owner and freshness failures are dropped silently: showing
    /// anything would describe a link that is not this owner's to open.
    var surfacesNotFound: Bool {
        switch self {
        case .missingRecord, .archivedRecord, .finishedRecord: true
        case .noExactOwner, .ownerMismatch, .stale: false
        }
    }
}

enum NativeDeepLinkDecision: Equatable, Sendable {
    case apply(NativeDeepLinkParser.Route)
    case park
    case discard(NativeDeepLinkDiscardReason)
}

/// The shown-once "Job not found" notice for a record failure.
struct NativeDeepLinkUnavailableNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let reason: NativeDeepLinkDiscardReason
}

enum NativeDeepLinkRoutingPolicy {
    /// `onmyway` refuses the widget projection's `DONE_STATUSES` (RN
    /// `utils/widgetBridge.ts`): no on-my-way review for finished work.
    static let onMyWayRefusedStatuses = NativeWidgetSnapshotProjection.doneStatuses

    /// The whole gate, for a new arrival and for a parked route alike.
    ///
    /// - Parameters:
    ///   - ownerBinding: the §2.5 predicate `O` at this instant.
    ///   - record: the lookup in the CURRENT owner's data (never another's).
    static func decide(
        _ candidate: NativeDeepLinkCandidate,
        phase: NativeDeepLinkGatePhase,
        ownerBinding: String?,
        now: Date,
        record: (String) -> NativeDeepLinkRecord?
    ) -> NativeDeepLinkDecision {
        // Freshness bounds the life of every candidate, parked or not: a
        // route older than the stash window never applies (§6.1).
        let age = now.timeIntervalSince(candidate.at)
        guard age >= 0, age <= NativeDeepLinkParser.pendingOpenURLMaximumAge else {
            return .discard(.stale)
        }
        // Step 4: authenticate, else park.
        guard phase == .signedIn else { return .park }
        // Step 5: the exact owner.
        guard let ownerBinding, !ownerBinding.isEmpty else { return .discard(.noExactOwner) }
        if candidate.source == .coldStash || candidate.ownerTag != nil {
            guard NativeWidgetOwnerTag.matches(candidate.ownerTag, binding: ownerBinding) else {
                return .discard(.ownerMismatch)
            }
        }
        if let arrival = candidate.arrivalBinding, arrival != ownerBinding {
            return .discard(.ownerMismatch)
        }
        // Step 6: the record, in the current owner's data only.
        let id = candidate.route.jobID
        guard let found = record(id) else { return .discard(.missingRecord) }
        // Archived fails closed, with ONE recorded exception (contract §6.2,
        // native difference): the Job Timer widget keeps showing a running
        // clock on an archived job (§2.2 parity, `activeTimer` does not filter
        // archived), and its tap is `tradeready://job/<id>`. A link the app's
        // own widget is rendering is never a dead tap, the same rule P8
        // applies to `est_` notifications. `onmyway` never gets the exception:
        // Next Job never selects an archived job.
        if found.isArchived {
            guard case .job = candidate.route, found.hasRunningTimer else {
                return .discard(.archivedRecord)
            }
        }
        if case .onMyWay = candidate.route, onMyWayRefusedStatuses.contains(found.status) {
            return .discard(.finishedRecord)
        }
        return .apply(candidate.route)
    }

    /// §6.2 step 4: a parked route is discarded when the gate ENTERS
    /// `.signedOut`, `.accountMismatch` or `.unavailable`. A route that
    /// arrived while the gate was already there stays parked until sign-in.
    static func discardsParked(entering newPhase: NativeDeepLinkGatePhase, gateChanged: Bool) -> Bool {
        newPhase == .closed && gateChanged
    }

    /// `widget_deep_link_opened {type}` (§9.5; RN `App.tsx:503`).
    static func analyticsType(_ route: NativeDeepLinkParser.Route) -> String {
        switch route {
        case .job: "job"
        case .onMyWay: "onmyway"
        }
    }
}

/// §6.2 step 1: the `.onOpenURL` order. The Google Sign-In callback is
/// offered to Google first and, when claimed, never reaches `handle(url:)`, so
/// it can never be consumed as a widget link.
enum NativeOpenURLDispatch {
    enum Outcome: Equatable {
        case googleSignIn
        case app
    }

    @discardableResult
    static func dispatch(
        _ url: URL,
        googleSignIn: (URL) -> Bool,
        app: (URL) -> Void
    ) -> Outcome {
        if googleSignIn(url) { return .googleSignIn }
        app(url)
        return .app
    }
}
