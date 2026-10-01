import Foundation
import os

enum NativeAccountSignOutError: LocalizedError {
    case remoteRevocationFailed
    case localScrubFailed

    var errorDescription: String? {
        switch self {
        case .remoteRevocationFailed:
            "TradeReady could not revoke this device's session. Your local data is still intact."
        case .localScrubFailed:
            "TradeReady could not safely finish removing this account from the device. Try again before signing in as someone else."
        }
    }
}

/// Local persistence refused a job-scoped write before any mutation ran. The
/// message is already user-safe (the read-only guard's own explanation).
private struct NativeJobMutationWriteFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum LegacyLaunchMigrationNotice: Identifiable, Equatable {
    case migrated(count: Int, adoptedPhotos: Int, deferredPhotos: Int)
    case conflict
    case failed

    var id: String {
        switch self {
        case .migrated: "migrated"
        case .conflict: "conflict"
        case .failed: "failed"
        }
    }
}

enum NativeAuthenticatedAccountState: Equatable {
    case notChecked
    case checking
    case noMigratedSession
    case verified
    case verifiedAndStaged
    case ownerMismatch
    case sessionRejected
    case unavailable

    var displayValue: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking…"
        case .noMigratedSession: "Not signed in"
        case .verified: "Verified"
        case .verifiedAndStaged: "Verified · migrated settings ready"
        case .ownerMismatch: "Verified · previous account data kept separate"
        case .sessionRejected: "Sign-in expired"
        case .unavailable: "Could not verify"
        }
    }
}

enum NativeAuthenticationGateState: Equatable {
    case loading
    case initialSyncLoading
    case initialSyncUnavailable(message: String)
    case subscriptionLoading
    case signedOut
    case signedIn(email: String?)
    case passwordRecovery(email: String?)
    case invalidPasswordRecovery
    case onboarding(NativeOnboardingDocument.Draft)
    case paywall(offering: NativeSubscriptionOffering?, message: String?)
    case startingPoint(NativeTypedAccountState.Trade)
    case accountMismatch
    case unavailable
}

func nativeShouldPreserveSignedInGateDuringTemporaryOutage(
    isInitialCheck: Bool,
    accountState: NativeAuthenticatedAccountState,
    gateState: NativeAuthenticationGateState,
    hasVerifiedSubject: Bool,
    hasVerifiedBinding: Bool
) -> Bool {
    guard !isInitialCheck, hasVerifiedSubject, hasVerifiedBinding else { return false }
    guard accountState == .verified || accountState == .verifiedAndStaged else { return false }
    if case .signedIn = gateState { return true }
    return false
}

enum NativeSubscriptionActionOutcome: Equatable {
    case completed
    case cancelled
    case noActiveSubscription
    case failed(message: String)
}

enum NativeEstimateApprovalLinkOutcome: Equatable {
    case success(NativeEstimateApprovalLink)
    case failure(NativeEstimateApprovalLinkError)
}

enum NativeEstimateRevisionOutcome: Equatable {
    case revised
    case failure(NativeEstimateApprovalLinkError)
}

enum NativeChangeOrderApprovalLinkOutcome: Equatable {
    case success(NativeChangeOrderApprovalLink)
    case failure(NativeChangeOrderApprovalLinkError)
}

enum NativeJobCompletionOutcome: Equatable {
    case completed
    case autoInvoiced(invoiceID: String)
    case failed

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// A typed refusal from a Phase 9 money-record write. The associated message for
/// `.invalidDraft` is already user-safe (it mirrors the RN alert copy).
enum NativeMoneyRecordRefusal: Error, Equatable {
    case persistenceUnavailable
    case missingRecord
    case staleEditorCopy
    case conflictingRecord
    case invalidDraft(String)
}

@MainActor
final class AppStore: ObservableObject {
    private static let changeOrderIDGenerator = LocalIDGenerator()

    // These are screen projections. `snapshot` is the only persisted business-data truth.
    @Published private(set) var customers: [Customer] = []
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var invoices: [Invoice] = []
    @Published private(set) var expenses: [Expense] = []
    /// Phase 9 canonical reads for the money UI (mileage + pricebook have no
    /// UI projection yet — the editors work from the pure draft contracts).
    @Published private(set) var trips: [Canonical.Trip] = []
    @Published private(set) var pricebookEntries: [Canonical.PricebookEntry] = []
    @Published var settings = BusinessSettings() {
        didSet { if !isApplyingProjection { mergeSettingsAndSave() } }
    }
    /// P12-008 review (fix round 1, R41): why the last Settings edit was not
    /// saved (writes are blocked, or the save failed), shown wherever the
    /// owner edits settings while the fields show the saved settings. Cleared
    /// by the next Settings edit that saves, and whenever `apply` shows a
    /// whole snapshot (launch, reset, import, pull, account scrub, a commit).
    @Published private(set) var settingsSaveFailure: String?
    @Published var selectedTab: AppTab = .today
    /// RN's Today `selectedDate` state (task 10.11): the week-strip/schedule
    /// anchor. Starts at launch-time "today" and only changes on explicit
    /// navigation (day tap, prev/next week, or a `.selectDate` destination) —
    /// it does not auto-advance across a midnight rollover while foregrounded,
    /// matching RN's `useState(todayString)` behavior exactly.
    @Published var todaySelectedDate: String = NativeTodayBriefing.todayDateString(now: Date())
    @Published var deepLinkedJobID: String?
    @Published var deepLinkedCustomerID: String?
    @Published var deepLinkedInvoiceID: String?
    /// One-shot request to open the payment outreach sheet for an invoice
    /// (from an `overdue_outreach` notification tap). Consumed by the detail
    /// view on appear; never auto-sends.
    @Published var deepLinkedOutreachInvoiceID: String?
    @Published private(set) var pendingOnMyWayJobID: String?
    /// Task 11.06 (contract §6.2 step 6): the shown-once "Job not found"
    /// notice for a widget/Siri link whose record is missing, archived or (for
    /// `onmyway`) finished. Never names a different record.
    @Published private(set) var deepLinkUnavailableNotice: NativeDeepLinkUnavailableNotice?
    @Published private(set) var pendingAppointmentConfirmationJobID: String?
    @Published private(set) var pendingReviewRequestJobID: String?
    @Published private(set) var pendingEstimateFollowUpJobID: String?
    @Published var migrationMessage: String?
    @Published private(set) var launchMigrationNotice: LegacyLaunchMigrationNotice?
    @Published private(set) var isLegacyMigrationBlocked = false
    @Published private(set) var isAccountScrubBlocked = false {
        // Phase 12 (12.02): an unblocked cleanup ends the reported episode,
        // so the next blocked one reports again (`markAccountScrubBlocked`).
        didSet { if !isAccountScrubBlocked { accountScrubBlockedReported = false } }
    }
    /// Phase 12 (12.00b.2-G, Task 9b review M3): what the blocked cleanup is
    /// finishing, so the blocked screen says "account deletion" for a
    /// deletion (`.all`). Nil when nothing is blocked or the marker cannot be
    /// read (the sign-out wording).
    @Published private(set) var accountScrubBlockedScope: Canonical.SnapshotRepository.AccountScrubScope?
    /// Phase 12 (L286.4): a switch/recovery boundary step (widget wipe, AI-key
    /// wipe) is still pending. Drives the non-blocking "Try cleanup again"
    /// banner; `retryAccountScrub` runs the pending steps.
    @Published private(set) var isAccountBoundaryCleanupPending = false
    /// Phase 12 (12.06): the last "Check everything is saved" result
    /// (`prepareRollbackReadiness`). Read it through
    /// `currentRollbackReadinessCheck`, which hides a result made before the
    /// last account boundary.
    @Published private(set) var rollbackReadinessCheck: NativeRollbackReadinessCheck?
    @Published private(set) var isRollbackReadinessCheckRunning = false
    @Published private(set) var authenticatedAccountState: NativeAuthenticatedAccountState = .notChecked
    @Published private(set) var authenticationGateState: NativeAuthenticationGateState = .loading {
        didSet {
            // Every path that reaches a usable authenticated state funnels a
            // push here, so a sign-in flushes edits made while signed out or
            // migrated locally without wiring a trigger into each call site.
            if Self.isSyncEligible(authenticationGateState),
               !Self.isSyncEligible(oldValue) {
                syncNow(trigger: .signedIn)
            }
            // Task 11.01 (contract §3.1): a gate change can open or close the
            // §2.5 owner predicate, so re-mirror (a closed gate is a no-op).
            scheduleWidgetMirrorRefresh()
            // Task 11.06 (contract §6.2 step 4): entering a closed gate
            // discards a parked deep link; entering `.signedIn` applies it.
            handleDeepLinkGateChange(from: oldValue)
            // Task 11.08 (§9.3–§9.5): onboarding steps, the paywall and the
            // root screens are gate moments.
            emitAnalyticsForGateChange(from: oldValue)
            // Phase 12 (12.00b.2-K fix round 1, review M3): a gate that waits
            // for the owner can hold for minutes. Bookings then convert only
            // after a full pull taken once the gate has opened, never from an
            // older one whose push could replace another device's newer edit
            // of the same `jbk_` job. Since the final review (M1) a booking or
            // portal mirror waits the same way: its merge queues the whole
            // settings or customer record.
            if Self.gateWaitsForOwner(authenticationGateState) {
                bookingIntakePullMark = nil
                scheduleBookingRecoveryPullMark = nil
            }
        }
    }
    @Published private(set) var migratedAccountState: NativeTypedAccountState?
    @Published private(set) var dismissedCustomerDuplicatePairKeys: Set<String> = []
    @Published private(set) var reviewRequestRecords: [NativeReviewRequestRecord] = []
    /// Task 10.12 (S4): `nil` means the mute store could not be read this
    /// session (fail-closed — see `NativeInsightsCardPolicy.visibleInsights`);
    /// an empty array means it was read and holds no active mutes.
    @Published private(set) var insightMutes: [NativeInsightMute]?
    /// Task 10.12 (D4/D5): `nil` means either not-yet-loaded or unreadable —
    /// both cases hide the checklist card and (brief step 5) gate the
    /// insights card as "setup incomplete".
    @Published private(set) var setupChecklistState: NativeSetupChecklistState?
    /// Task 10.12 (ruling R4): one-shot coach prefill installed by an
    /// insight's "Ask coach" action. 10.13 consumes and clears this — it is
    /// never auto-sent.
    @Published var pendingCoachPrefill: String?
    /// Task 10.13 fix round 1: bumped by `bumpCoachConversationGeneration()`
    /// on every "New chat" tap and at every account boundary
    /// (`resetTodayOwnerState()`). `CoachView.send()` captures a
    /// `NativeCoachConversationTicket` (this generation + `verifiedAccountBinding`)
    /// before its network await and re-checks it via `coachReplyStillValid(_:)`
    /// after — the fix for the stale-reply bug where a reply resolving after
    /// "New chat"/sign-out/account-switch used to land in a transcript (or
    /// account) it no longer belonged to.
    @Published private(set) var coachConversationGeneration = 0
    /// Task 10.12 (D4): one-shot settings deep-link installed by the setup
    /// checklist card's task tap. Typed as the pure `NativeSetupRoute` (10.03)
    /// rather than the UI-layer `SettingsDestination` so `AppStore` carries no
    /// SwiftUI-file dependency; `TodayView` converts via
    /// `SettingsDestination(setupRoute:)` and presents `SettingsView` with it
    /// as `initialDestination`, then clears this.
    @Published var pendingSettingsDestination: NativeSetupRoute?
    /// Task 10.12 (D4): the `notifications` task's live derivation. `AppStore`
    /// has no notification-coordinator dependency of its own (it lives at the
    /// app root as a sibling `EnvironmentObject`), so `TodayView` mirrors
    /// `NativeEstimateFollowUpNotificationCoordinator.permissionState` into
    /// this field — the same pattern `deepLinkedJobID` uses for view-owned
    /// one-shot state.
    @Published var notificationsGranted = false
    @Published private(set) var pendingCustomerMergeUndo: NativeCustomerMergeUndo?
    @Published private(set) var pendingRecordDeleteUndo: NativeRecordDeleteUndo?
    @Published private(set) var isMigratedLocalOwnerVerified = false
    @Published private(set) var subscriptionOperationInFlight = false
    @Published private(set) var isSubscriptionTrialing = false
    @Published private(set) var syncStatus = NativeSyncStatus()
    @Published private(set) var invoiceDeliveryFailures: [String: String] = [:]
    @Published private(set) var stripeConnectStatus: NativeStripeConnectStatus?
    @Published private(set) var stripeConnectLoading = false
    @Published private(set) var stripeConnectError: String?
    /// Phase 12 (12.00b.1, I2; owner decision D3): the changes the server
    /// refused that are waiting for Retry or Discard in Settings › Cloud Sync.
    @Published private(set) var rejectedChanges: [NativeRejectedChange] = []

    private let fileURL: URL
    private let repository: Canonical.SnapshotRepository
    private let migrationJournal: Canonical.MigrationJournal
    private let mutationQueue: Canonical.NativeMutationQueue
    private let syncBackfill: Canonical.NativeSyncBackfill
    private let syncCursorStore: Canonical.NativeSyncCursorStore
    private let customerDuplicateDismissalStore: NativeCustomerDuplicateDismissalStore
    private let reviewRequestStore: NativeReviewRequestStore
    /// Task 10.05 (N1): owner-bound one-shot contextual invoice-reminder
    /// prompt flag (10.03's `NativeReminderPromptStore`). Same durability
    /// contract as `reviewRequestStore` — device-local, wiped at the account
    /// boundary.
    private let reminderPromptStore: NativeReminderPromptStore
    /// Task 10.12 (S4): owner-bound insight dismiss/snooze store (10.03's
    /// `NativeInsightMuteStore`). Same durability contract as
    /// `reviewRequestStore` — device-local, wiped at the account boundary
    /// (mute ids embed this account's record ids).
    private let insightMuteStore: NativeInsightMuteStore
    /// Task 10.12 (D4/D5): owner-bound setup-checklist store (10.03's
    /// `NativeSetupChecklistStore`).
    private let setupChecklistStore: NativeSetupChecklistStore
    /// Phase 12 (12.00b.1, I2): the owner-scoped, bounded, file-protected
    /// store of refused changes (`NativeRejectedChangeStore`).
    private let rejectedChangeStore: NativeRejectedChangeStore
    /// Task 10.12 (ruling R5): no-op by default; the app injects
    /// `NativeAnalyticsTransport.live()`. Every emission goes through
    /// `emitAnalytics(_:)` (task 11.08).
    private let analytics: NativeAnalytics
    /// Task 11.09 (contract §10.2–§10.3): no-op by default; the app injects
    /// `NativeCrashReporter.live()`. Identity rides the 11.08 lifecycle
    /// (`applyAnalyticsIdentityActions`); errors go through `reportError`.
    /// The reporter never throws and hands work to its own queue, so it can
    /// neither block nor roll back a save.
    private let crashReporting: NativeCrashReporting
    /// Task 11.08 (contract §9.4): the last identified Supabase user id.
    private var analyticsIdentity = NativeAnalyticsIdentityLifecycle()
    /// Task 11.08: `subscription_paywall_shown` fires once per paywall
    /// presentation (RN: once per `PaywallScreen` mount).
    private var analyticsPaywallTracked = false
    /// Task 11.08: where the open review-request / estimate follow-up flow
    /// came from (RN route param `source`, default `notification`).
    private var reviewRequestAnalyticsSource: NativeAnalyticsEvent.MessageSource = .notification
    private var estimateFollowUpAnalyticsSource: NativeAnalyticsEvent.MessageSource = .notification
    /// One bounded, non-PII diagnostic per session per store (brief step 5) —
    /// tracks which stores have already logged their fail-closed diagnostic
    /// so a persistently-corrupt file does not spam.
    private var loggedFailClosedDiagnostics: Set<String> = []
    /// Fix round 1 (I6): test/observability seam for the diagnostics above —
    /// every code this session has emitted, in order, readable without
    /// scraping unified logging. Production also emits each one through
    /// `Self.diagnosticsLogger`, which survives Release builds (the prior
    /// `#if DEBUG print(...)` did not).
    private(set) var recordedDiagnostics: [String] = []
    /// Task 10.12 (R5): dedup key for `insight_shown` — RN's `lastShownKey`
    /// ref. Reset at the account boundary alongside the mute/checklist state.
    private var lastShownInsightIDsKey = ""
    /// Task 10.05 (N1) hand-off to the shared notification coordinator: fired
    /// after a genuinely new invoice is created (never on edit), mirroring RN's
    /// `promptForInvoiceReminders()` call sites in `AddInvoiceScreen.tsx` and
    /// `CreateInvoiceFromJobScreen.tsx`. `TradeReadyNativeApp` wires this to
    /// `NativeEstimateFollowUpNotificationCoordinator.promptForInvoiceRemindersIfNeeded()`.
    /// Fire-and-forget by design (RN does not await its call either); nil in
    /// previews/tests that never construct the coordinator.
    var onInvoiceCreatedContextualPrompt: (@MainActor () -> Void)?
    /// App Store rating hand-off (native-only): fired beside each committed
    /// owner `invoicePaid`/`estimateSent` analytics emission, so a deduped,
    /// refused, or synced-in change is never a win. `TradeReadyNativeApp`
    /// wires it to `NativeAppRatingPromptCoordinator.recordWin`; nil in tests
    /// and previews that never construct the coordinator.
    var onAppRatingWin: (@MainActor (NativeAppRatingWin) -> Void)?
    private let appGroupAccountScrubber: NativeAppGroupAccountScrubber
    /// Phase 12 (12.00b.2-F, P12-001): erases the React Native sources the
    /// launch migration reads when an account is permanently deleted. The app
    /// passes `.live()` (the convenience init); nil in host tests and previews,
    /// so they never touch this machine's Documents or Keychain.
    private let legacySourceEraser: NativeLegacySourceEraser?
    /// Phase 12 (12.00b.2-G): a host test's fixture source, read by the launch
    /// migration and by "Try again" alike (`migrateLegacySource`). The app
    /// passes neither, and both read the device's live legacy data.
    private let legacyMigrationSource: LegacyMigrationSource?
    private let legacyMigrationSourceProvider: (() throws -> LegacyMigrationSource)?
    /// Task 11.15: the one secure store for the auth session and the user's
    /// provider keys (`NativeKeychainSecureSettingsStore`, the system Keychain
    /// in production). The account-scrub paths wipe the same store the AI
    /// key entry writes to; host tests inject an in-memory backing.
    private let secureSettingsStore: NativeKeychainSecureSettingsStore
    /// Task 11.01: the WidgetKit reload seam used after every App Group wipe
    /// (sign-out, account deletion, scrub retry/recovery). Injectable so host
    /// tests observe reloads.
    private let widgetTimelineReloader: any NativeWidgetTimelineReloading
    /// Task 11.01 (contract §3.1): the App Group snapshot writer. Nil until
    /// `installWidgetMirror(_:)` (production: `TradeReadyNativeApp.init`), so
    /// previews and host tests never touch the real App Group container.
    private var widgetMirror: NativeWidgetMirror?
    private var widgetMirrorObserverToken: UUID?
    private var widgetMirrorRefreshScheduled = false
    /// Phase 12 (12.00b.2-B, charter L74): true while the latest mirror write
    /// found the App Group lock busy and wrote nothing. A write that reaches
    /// the writer (written, unchanged) or finds no owner clears it.
    private(set) var isWidgetMirrorDirty = false
    /// Bounded, payload-free count of busy mirror writes.
    private(set) var widgetMirrorLockBusyCount = 0
    private static let widgetMirrorLockBusyCap = 9_999
    /// Delays of the scheduled retries while the mirror is dirty: each retry
    /// that is busy again takes the next delay; after the last, the next
    /// trigger (canonical write, gate change, seam, foreground, background
    /// refresh) retries. Host tests shorten it.
    var widgetMirrorBusyRetryDelays: [TimeInterval] = [0.5, 2, 8]
    private var widgetMirrorBusyRetryAttempt = 0
    private var widgetMirrorBusyRetryScheduled = false
    /// Task 11.01: true from the moment an explicit sign-out/deletion starts
    /// scrubbing until it finishes. The §2.5 predicate stays non-nil during
    /// the post-scrub `await subscriptionService.logOut()`, and the in-memory
    /// snapshot still holds the old owner's records, so without this a
    /// queued write could re-populate the just-scrubbed suite.
    private var widgetMirrorSuspendedForAccountBoundary = false
    /// Task 11.01 fix round 1 (contract §3.2 amendment): bumped on every
    /// canonical write, so a seam delivery can tell whether the live snapshot
    /// moved on while its publish was suspended in `notifySynchronize`.
    private var canonicalWriteRevision: UInt64 = 0
    /// The canonical revision captured by the most recently started
    /// `publishDerivedState` (only the latest-started publish can deliver:
    /// the publisher's generation guard stops older ones). Nil when no
    /// AppStore publish is in flight (e.g. a direct publisher call).
    private var widgetSeamCapture: (token: UUID, revision: UInt64)?
    /// Which canonical the last seam write projected; host tests only.
    private(set) var lastWidgetSeamSource: NativeWidgetSeamSource?
    private var snapshot = Canonical.Snapshot(payload: .init()) {
        didSet {
            canonicalWriteRevision &+= 1
            // Task 11.01 (contract §3.1 trigger 1): every canonical write
            // (jobs, time sessions, invoices, payments — and replayed widget
            // actions) lands here, through `apply` or `commitSettings` (since
            // Phase 12, P12-008, nothing edits the live snapshot in place).
            // Coalesced to one write per main-actor turn, after the save has
            // run.
            scheduleWidgetMirrorRefresh()
        }
    }
    private var isApplyingProjection = false
    private var persistenceWritesBlocked = false
    private var persistenceBlockReason: PersistenceBlockReason?
    private var persistenceBlockDetail: String?
    private var didCheckMigratedAuthenticatedIdentity = false
    private var authenticatedIdentityActivator: NativeAuthenticatedIdentityActivator?
    private var authenticationOperationInFlight = false
    /// Task 11.15 fix round 1: the gate stays `.signedIn` across
    /// `useAnotherAccount`'s `clearSession`/`logOut` awaits, so this closes the
    /// AI provider key gate for the whole switch. (Since final review 1c the
    /// switch also holds `authenticationOperationInFlight` throughout; this
    /// flag additionally makes a second switch a no-op.)
    private var accountSwitchInFlight = false
    private var identityActivationInFlight = false
    private var identityActivationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Phase 12 (12.00b.2-G fix round 1, R31): advanced by every account
    /// boundary (an account scrub once its marker is written, a completed
    /// sign-out or deletion, an account switch; since fix round 2 the
    /// password-recovery exits, before they clear the session, and their
    /// shared recovery sign-out). Each identity check reads it
    /// before its activator await and drops its result if it moved, so a
    /// check that resumes afterwards never overwrites the boundary
    /// (`discardIdentityActivationOvertakenByAccountBoundary`).
    private var accountBoundaryGeneration: UInt64 = 0
    /// Task 11.06 (contract §6.2 step 4): at most one route parked across
    /// the auth/onboarding/subscription gate (newest wins). Read-only outside
    /// the store so host tests can observe parking.
    private(set) var parkedDeepLink: NativeDeepLinkCandidate?
    /// Fix round 1 (I1): an owner (O) was active at some gate since the last
    /// closed-gate boundary. Only leaving such a session discards a parked
    /// route; the launch resolution `.loading` → `.signedOut` does not.
    private var deepLinkOwnerWasActive = false
    /// Task 11.06 (contract §6.2 step 3): the App Group `pendingOpenUrl`
    /// consumer (read-and-remove under the shared lock). Nil in previews and
    /// host tests unless injected, so they never touch the real container.
    private let pendingOpenURLConsumer: NativePendingOpenURLConsumer?
    private var migratedAccountBinding: String?
    private var verifiedAccountBinding: String?
    private var authenticatedUserSubject: String?
    private var authenticatedEmail: String?
    private let widgetActionReplayTransport: NativeWidgetActionClaimTransport?
    /// Task 11.05 (§4.5, C8): bounded, payload-free replay counters.
    private(set) var widgetActionReplayDiagnostics = NativeWidgetActionReplayDiagnostics()
    /// Final review 1a/1b: boundary steps pending without a file marker (it
    /// could not be written). Phase 12 (L286.5b): each is also recorded in
    /// the Keychain (`NativeAccountBoundaryStepRecord.swift`), and a record
    /// found at launch lands here, so the step fails closed across a relaunch.
    private var boundaryStepsPendingInMemory: Set<Canonical.SnapshotRepository.BoundaryStep> = []
    /// Phase 12 (L286.5b): steps whose Keychain record could not be read. They
    /// gate as pending, but their body runs only once a retry can read the
    /// record: it never wipes the current owner's data on a guess.
    private var boundaryStepsUnverified: Set<Canonical.SnapshotRepository.BoundaryStep> = []
    /// Phase 12 (12.00b.2-G fix round 1, P12-006): a permanent deletion whose
    /// account-scrub marker could not be written, so none of its steps ran.
    /// It is also recorded in the Keychain (`recordAccountDeletionScrub`).
    /// Retry, scene activation and the launch write the marker from it first
    /// and run the whole `.all` scrub; until then the deletion stays blocked.
    private var accountDeletionPendingWithoutMarker = false
    /// That Keychain record could not be read at launch; scene activation
    /// re-reads it.
    private var accountDeletionRecordUnverified = false
    /// Final review 1b: bounded, payload-free count of failed boundary AI-key
    /// wipes (no key material, no account).
    private(set) var aiProviderKeyWipeFailureCount = 0
    private static let aiProviderKeyWipeFailureCap = 99
    /// Phase 12 (12.00b.1, I2): bounded, payload-free counts of failed
    /// boundary scrubs of the rejected-change store, and of refused changes
    /// dropped because the store was full (the oldest go first).
    private(set) var rejectedChangeScrubFailureCount = 0
    private(set) var rejectedChangeOverflowCount = 0
    private static let rejectedChangeCounterCap = 9_999
    /// Phase 12 (L286.5b): bounded, payload-free counts of boundary-step file
    /// markers that could not be written, and of Keychain step records that
    /// could not be written, read or removed (the log line carries the stage
    /// and step codes only).
    private(set) var boundaryStepMarkerWriteFailureCount = 0
    private(set) var boundaryStepRecordFailureCount = 0
    private static let boundaryStepFailureCap = 99
    /// Phase 12 (12.02): the support report's and the charter monitors'
    /// state (`NativeSupportDiagnostics.swift`). Codes and bounded counts
    /// only: the codes `reportError` sent, the sync monitor's streaks and
    /// totals, the last launch-migration result, and the blocked account
    /// scrub's attempts (reported once per blocked episode).
    private(set) var supportCodeHistory = NativeSupportCodeHistory()
    private(set) var syncMonitor = NativeSyncMonitor()
    private(set) var legacyMigrationSummary = NativeLegacyMigrationSummary()
    private(set) var accountScrubBlockedCount = 0
    private var accountScrubBlockedReported = false
    private let initialSyncService: (any NativeInitialSyncServing)?
    private let subscriptionService: NativeSubscriptionServing
    private let injectedJobPhotoTransferService: (any NativeJobPhotoTransferring)?
    private let injectedEstimateApprovalLinkService: (any NativeEstimateApprovalLinking)?
    private let injectedChangeOrderApprovalLinkService: (any NativeChangeOrderApprovalLinking)?
    private let injectedInvoiceDeliveryService: (any NativeInvoiceDelivering)?
    /// Advisory receipt-OCR / pricebook-suggestion transport. Injected so tests
    /// and previews never touch the network; defaults to the live client-key +
    /// backend-bearer implementation.
    private let advisoryAITransport: any NativeAdvisoryAITransport
    /// Task 10.13 (C1): the coach transport, constructed once (mirrors
    /// `NativeInvoiceDeliveryService`'s injectable-per-instance shape).
    /// Injectable so host tests exercise `sendCoachMessage` without a live
    /// network call.
    private let coachTransport: NativeCoachTransport
    private var jobPhotoTransferInFlight = false
    private var initialSyncGateGeneration: UInt64 = 0
    private var initialSyncCompletedSubject: String?
    private var postSubscriptionDestination: PostSubscriptionDestination?
    private var subscriptionGateGeneration: UInt64 = 0
    // Phase 8 task 8.08: serialize overlapping booking-intake refreshes and
    // per-target link administrations. @MainActor isolation alone does not
    // serialize overlapping Tasks, so these flags gate re-entry explicitly.
    private var bookingIntakeInFlight = false
    private var bookingAdminInFlight = false
    private var portalAdminInFlight: Set<String> = []
    /// Phase 12 (12.00b.2-I, P12-013): one pending-work recovery pass at a
    /// time (launch and activation can both start one).
    private var scheduleBookingRecoveryInFlight = false
    /// Phase 12 (12.00b.2-I fix round 1, review I1): the owner and account
    /// generation of a pull that committed the settings and customer tables
    /// since the identity was last applied or the foreground refresh last
    /// began, or nil. A booking or portal mirror merges into this device's
    /// copy of the settings or customer record and queues the whole record,
    /// and the push runs before the pull, so a mirror is read and merged
    /// only while this mark is current. Since the final review (M1) it
    /// follows the intake mark's rules below: the generation is the one the
    /// pull started under, a pull taken before or while the gate waits for
    /// the owner does not count, and the scene entering the background
    /// clears it (`sceneDidEnterBackground`).
    private var scheduleBookingRecoveryPullMark: (generation: UInt64, subject: String)?
    /// Phase 12 (12.00b.2-K, P12-016): the owner and account generation of a
    /// pull that committed every table, started under that generation, since
    /// the identity was last applied or the foreground refresh last began, or
    /// nil. Booking intake converts only while this mark is current, and it
    /// converts from that pull instead of pulling again. A partial pull does
    /// not count: one that missed the jobs table could miss the job another
    /// device already made from a booking, and the push after a conversion
    /// would replace it. Nor does a pull taken before, or while, the gate
    /// waits for the owner (fix round 1, review M3; `gateWaitsForOwner`).
    private var bookingIntakePullMark: (generation: UInt64, subject: String)?
    /// Phase 12 final review (M1, R54 N1): advanced each time the scene
    /// enters the background. A pull captures it when it starts and sets a
    /// pull mark only if it has not moved, so a pull still in flight when
    /// the scene left (it can resume after the next activation has begun,
    /// before that activation's own pull) never marks.
    private var pullMarkPeriod: UInt64 = 0
    /// Phase 12 final review (M3): the per-table watermarks (the latest server
    /// `updated_at` read) of the initial sync committed in this process, with
    /// the account generation and owner it was pulled for. The initial sync
    /// saves no delta cursor, so without these a cold launch's intake guarded
    /// its stamp with the previous session's watermark and every booking
    /// that arrived while the app was closed had its stamp dropped
    /// (`intakeGuardWatermarks`).
    private var initialSyncWatermarks: (generation: UInt64, subject: String, tables: [String: String])?
    /// Task 8.08 test seam: explicit session bytes for owner transports.
    /// Production passes nil and reads the Keychain; tests inject bytes so
    /// owner rechecks and service calls exercise without a live session.
    var scheduleBookingSessionOverride: Data?
    /// Task 8.08 test seam: explicit sync credentials so the verified-pull
    /// half of intake exercises without a live Keychain session.
    var scheduleBookingTestCredentials: NativeSyncCredentials?
    /// Phase 12 (12.00b.2-I) test seams: the booking-admin and portal-manage
    /// clients pending-work recovery reads `status` through. Production
    /// leaves them nil and resolves the configured endpoints.
    var scheduleBookingRecoveryAdminService: NativeBookingAdministrationService?
    var scheduleBookingRecoveryPortalService: NativePortalAdministrationService?
    /// Task 10.13 test seam: overrides for the coach provider keys so host
    /// tests can force each provider-precedence branch deterministically,
    /// the same way `scheduleBookingSessionOverride` avoids the real
    /// Keychain for the session bytes. `nil` (the default) falls through to
    /// `advisoryAnthropicKey`/`advisoryGroqKey`.
    var coachAdvisoryAnthropicKeyOverride: String?
    var coachAdvisoryGroqKeyOverride: String?

    private enum PostSubscriptionDestination {
        case startingPoint(NativeTypedAccountState.Trade)
        case signedIn
    }

    private enum PersistenceBlockReason: String {
        case accountScrub = "account-scrub"
        case newerSchema = "newer-schema"
        case unreadableSnapshot = "unreadable-snapshot"
        case legacyMigration = "legacy-migration"
        case missingMigratedSnapshot = "missing-migrated-snapshot"
    }

    private struct SnapshotProjectionError: Error {
        let family: String
        let underlying: Error
    }

    /// Task 11.07: `analytics` is the app's `NativeAnalyticsTransport.live()`;
    /// the no-op default keeps every other caller unchanged. Task 11.09:
    /// `crashReporting` is the app's `NativeCrashReporter.live()`, same rule.
    convenience init(
        analytics: NativeAnalytics = NativeNoOpAnalytics(),
        crashReporting: NativeCrashReporting = NativeNoOpCrashReporting()
    ) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "TradeReadyNative", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(
            fileURL: directory.appending(path: "store.json"),
            seedIfMissing: false,
            automaticallyMigrateLegacyData: true,
            legacySourceEraser: .live(),
            pendingOpenURLConsumer: .live(),
            analytics: analytics,
            crashReporting: crashReporting,
            recordsNativeRun: true
        )
    }

    /// Injectable persistence location for integration tests and previews.
    init(
        fileURL: URL,
        seedIfMissing: Bool = true,
        automaticallyMigrateLegacyData: Bool = false,
        legacyMigrationSource: LegacyMigrationSource? = nil,
        legacyMigrationSourceProvider: (() throws -> LegacyMigrationSource)? = nil,
        legacySourceEraser: NativeLegacySourceEraser? = nil,
        repository injectedRepository: Canonical.SnapshotRepository? = nil,
        widgetActionReplayTransport: NativeWidgetActionClaimTransport? = nil,
        appGroupAccountScrubber: NativeAppGroupAccountScrubber = .init(),
        pendingOpenURLConsumer: NativePendingOpenURLConsumer? = nil,
        initialSyncService: (any NativeInitialSyncServing)? = nil,
        subscriptionService: NativeSubscriptionServing? = nil,
        jobPhotoTransferService: (any NativeJobPhotoTransferring)? = nil,
        estimateApprovalLinkService: (any NativeEstimateApprovalLinking)? = nil,
        changeOrderApprovalLinkService: (any NativeChangeOrderApprovalLinking)? = nil,
        invoiceDeliveryService: (any NativeInvoiceDelivering)? = nil,
        advisoryAITransport: (any NativeAdvisoryAITransport)? = nil,
        coachTransport: NativeCoachTransport? = nil,
        analytics: NativeAnalytics = NativeNoOpAnalytics(),
        crashReporting: NativeCrashReporting = NativeNoOpCrashReporting(),
        widgetTimelineReloader: any NativeWidgetTimelineReloading = NativeWidgetCenterTimelineReloader(),
        secureSettingsStore: NativeKeychainSecureSettingsStore = .init(),
        rejectedChangeFiles: (any NativeRejectedChangeFileBacking)? = nil,
        recordsNativeRun: Bool = false
    ) {
        self.analytics = analytics
        self.secureSettingsStore = secureSettingsStore
        self.crashReporting = crashReporting
        self.widgetTimelineReloader = widgetTimelineReloader
        self.fileURL = fileURL
        // Phase 12.00b.2-E fix round 2 (L267.a): injectable so a host test can
        // observe the launch path's re-protect call with a counting
        // `legacyFileEnumerator`, the same seam `SnapshotRepository` already
        // exposes. Defaults to the real repository for every other caller.
        self.repository = injectedRepository ?? Canonical.SnapshotRepository(primaryURL: fileURL)
        self.widgetActionReplayTransport = widgetActionReplayTransport ?? (try? .live())
        self.appGroupAccountScrubber = appGroupAccountScrubber
        self.legacySourceEraser = legacySourceEraser
        self.legacyMigrationSource = legacyMigrationSource
        self.legacyMigrationSourceProvider = legacyMigrationSourceProvider
        self.pendingOpenURLConsumer = pendingOpenURLConsumer
        self.initialSyncService = initialSyncService
        self.subscriptionService = subscriptionService ?? NativeRevenueCatSubscriptionService()
        self.injectedJobPhotoTransferService = jobPhotoTransferService
        self.injectedEstimateApprovalLinkService = estimateApprovalLinkService
        self.injectedChangeOrderApprovalLinkService = changeOrderApprovalLinkService
        self.injectedInvoiceDeliveryService = invoiceDeliveryService
        self.advisoryAITransport = advisoryAITransport ?? NativeAITransport.live()
        self.coachTransport = coachTransport ?? NativeCoachTransport(backendBaseURL: BuildEnvironment.backendBaseURL)
        self.migrationJournal = Canonical.MigrationJournal(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
        )
        self.mutationQueue = Canonical.NativeMutationQueue(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("mutation-queue.json")
        )
        self.syncBackfill = Canonical.NativeSyncBackfill(
            stateURL: fileURL.deletingLastPathComponent().appendingPathComponent("sync-backfill.json")
        )
        self.syncCursorStore = Canonical.NativeSyncCursorStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("sync-cursor.json")
        )
        self.customerDuplicateDismissalStore = NativeCustomerDuplicateDismissalStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("customer-duplicate-dismissals.json")
        )
        self.reviewRequestStore = NativeReviewRequestStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("review-requests.json")
        )
        self.reminderPromptStore = NativeReminderPromptStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("invoice-reminder-prompt.json")
        )
        self.insightMuteStore = NativeInsightMuteStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("insight-mutes.json")
        )
        self.setupChecklistStore = NativeSetupChecklistStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("setup-checklist.json")
        )
        self.rejectedChangeStore = NativeRejectedChangeStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("rejected-changes.json"),
            files: rejectedChangeFiles ?? NativeProtectedRejectedChangeFiles()
        )
        self.syncStatus = NativeSyncStatus(pendingCount: self.mutationQueue.load().count)
        // Phase 12 (L286.5b): a step whose file marker could not be written
        // was recorded in the Keychain instead; it is pending from launch.
        for step in Canonical.SnapshotRepository.BoundaryStep.allCases {
            loadBoundaryStepRecord(step)
        }
        // Phase 12 (12.00b.2-G fix round 1, P12-006): a deletion whose marker
        // could not be written was recorded in the Keychain instead.
        loadAccountDeletionRecord()
        var accountScrubRecoveryError: Error?
        do {
            // P12-006: its marker first (a failure blocks the launch below,
            // with nothing loaded), then the ordinary `.all` recovery.
            if accountDeletionPendingWithoutMarker {
                try repository.beginAccountScrub(scope: .all)
            }
            // Phase 12 (12.00b.2-G, Task 9b review M2): a marker that cannot
            // be read throws here, before any step runs. Its scope is unknown,
            // so the scrub stays pending (blocked) and is retried later.
            if let pendingScope = try pendingAccountScrubScope() {
                try scrubWidgetAccountState()
                switch pendingScope {
                case .live: try repository.removeLiveAccountData()
                case .all: try repository.removeAllAccountData()
                }
                try removeAccountScrubStores()
                switch pendingScope {
                case .live: try secureSettingsStore.clearAccountValues()
                case .all:
                    try secureSettingsStore.clearAllValues()
                    try eraseLegacySourcesForDeletedAccount()
                }
                try repository.finishAccountScrub()
                accountDeletionPendingWithoutMarker = false
                NativeGoogleSignInProvider.clearLocalCredential()
                // Task 11.05: widgets were reloaded right after the App Group
                // wipe inside `scrubWidgetAccountState()`.
            }
        } catch {
            accountScrubRecoveryError = error
        }
        if accountScrubRecoveryError == nil {
            // Final review 1a/1b: a boundary step left pending by an earlier
            // session (widget wipe, AI-key wipe) is retried at launch.
            retryPendingBoundarySteps()
        }
        refreshAccountBoundaryCleanupPending()
        let hadNativeSnapshot = FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: repository.backupURL.path)
        var launchOutcome: LegacyMigrationOutcome?
        var launchError: Error?
        var migratedWorkspaceClearedByScrub = false
        if automaticallyMigrateLegacyData && accountScrubRecoveryError == nil {
            do {
                let journalStatus = try migrationJournal.read().entries.last {
                    $0.migration == .reactNativeAsyncStorage
                }?.status
                // Phase 12 (12.00b.2-G, P12-003): a migrated device after a
                // sign-out (completed journal, no snapshot, the scrub's own
                // record) is signed out, not missing its snapshot. It takes the
                // steady-state branch below: no migration attempt, no Keychain
                // read, the re-protect still runs. A snapshot lost with no scrub
                // still attempts and lands in `missingMigratedSnapshot`.
                migratedWorkspaceClearedByScrub = !hadNativeSnapshot
                    && isMigratedWorkspaceClearedByAccountScrub(journalStatus: journalStatus)
                let shouldAttempt = (!hadNativeSnapshot && !migratedWorkspaceClearedByScrub)
                    || journalStatus == .started
                    || journalStatus == .failed
                if shouldAttempt {
                    // Phase 12 (G6-Q1): the injected store (the same system
                    // Keychain in the app), so a host test never publishes a
                    // fixture's legacy secrets into the real Keychain.
                    let coordinator = LegacyMigrationCoordinator(
                        repository: repository,
                        journal: migrationJournal,
                        secureStore: secureSettingsStore
                    )
                    // Task 11.12: a LegacyMigration signpost around the same
                    // synchronous call (a throw ends it as failed and rethrows).
                    launchOutcome = try NativePerformanceMetrics.shared.measure(.legacyMigration) {
                        try self.migrateLegacySource(with: coordinator)
                    }
                } else {
                    // Phase 12.00b.2-E fix round 2 (L267.a, Important 1): once a
                    // migration has completed, this automatic launch path never
                    // calls `coordinator.migrate` again — `shouldAttempt` stays
                    // false on every later launch, so the `.alreadyCompleted`
                    // re-protect hook inside `migrate` is unreachable here. Run
                    // the same re-protect directly so a protection failure from
                    // the original pass still heals on a later launch. Best
                    // effort: `reprotectPublishedLegacyDirectory` never throws,
                    // so this never blocks launch or changes launchOutcome/
                    // launchError; a bounded diagnostic already prints from
                    // inside it on failure (no path or filename).
                    _ = repository.reprotectPublishedLegacyDirectory(
                        migration: .reactNativeAsyncStorage,
                        name: "AsyncStorage"
                    )
                }
            } catch {
                launchError = error
            }
        }

        // Phase 12 (12.06, P12-011): an adopted native state seeds nothing
        // either (the signed-out steady state of a device with no completed
        // migration, or a snapshot that survives as its backup).
        let completedWithoutSnapshot = (launchOutcome?.status == .alreadyCompleted && !hadNativeSnapshot)
            || migratedWorkspaceClearedByScrub
            || launchOutcome?.status == .nativeStateAdopted
        if accountScrubRecoveryError == nil {
            // Task 11.12: a SnapshotLoad signpost (record count, and failed
            // when the stored snapshot could not be read).
            let snapshotLoad = NativePerformanceMetrics.shared.begin(.snapshotLoad)
            load(seedIfMissing: seedIfMissing && launchError == nil && !completedWithoutSnapshot)
            NativePerformanceMetrics.shared.end(
                snapshotLoad,
                outcome: persistenceWritesBlocked ? .failed : .completed,
                count: performanceRecordCount()
            )
        } else {
            applyEmptySnapshot()
            persistenceWritesBlocked = true
            persistenceBlockReason = .accountScrub
            persistenceBlockDetail = nil
            markAccountScrubBlocked(scope: try? pendingAccountScrubScope(), operation: "launch")
            migrationMessage = accountScrubBlockedScope == .all
                ? "A previous account deletion could not be safely completed. Local data remains hidden until cleanup succeeds."
                : "A previous sign-out could not be safely completed. Local data remains hidden until cleanup succeeds."
        }
        applyLaunchMigrationState(
            outcome: launchOutcome,
            error: launchError,
            hadNativeSnapshot: hadNativeSnapshot || FileManager.default.fileExists(atPath: repository.backupURL.path),
            operation: "launch"
        )
        syncStatus = NativeSyncStatus(pendingCount: mutationQueue.load().count)
        // Phase 12 (12.06 fix round 2, R45a): the app's launch tells the
        // Expo rollback build that a native build ran (playbook §5.3 E-1),
        // after the launch work and whatever it found. Not a snapshot write.
        if recordsNativeRun { recordNativeRun() }
    }

    /// Best effort: a failed write leaves the marker at the last run, so
    /// the Expo build sees no new run for this launch. A bounded line, no path.
    private func recordNativeRun() {
        do {
            try NativeRunMarkerStore(directory: fileURL.deletingLastPathComponent()).recordRun()
        } catch {
            Self.stageLogger.error("TradeReadyNativeRunMarker stage=record failed=true")
        }
    }

    func load() { load(seedIfMissing: true) }

    private func load(seedIfMissing: Bool) {
        let originalData = try? Data(contentsOf: fileURL)
        let outcome: Canonical.SnapshotRepository.LoadOutcome
        do {
            guard let loaded = try repository.load() else {
                persistenceWritesBlocked = false
                persistenceBlockReason = nil
                persistenceBlockDetail = nil
                if seedIfMissing { seedDemoData() } else { applyEmptySnapshot() }
                return
            }
            outcome = loaded
        } catch let canonicalLoadError {
            var legacyStage = "decode"
            do {
                guard let originalData else { throw canonicalLoadError }
                // One-way compatibility read for the first native prototype.
                let legacy = try Self.legacyDecoder.decode(LegacyNativeStoreSnapshot.self, from: originalData)
                legacyStage = "conversion"
                let canonical = try Self.canonicalSnapshot(from: legacy)
                legacyStage = "migration"
                try migrateFileSnapshot(
                    canonical,
                    sourceData: originalData,
                    kind: .legacyNativeSnapshot
                )
                return
            } catch let loadError {
                persistenceWritesBlocked = true
                persistenceBlockReason = .unreadableSnapshot
                persistenceBlockDetail = "canonical-\(Self.snapshotFailureCode(canonicalLoadError))/legacy-\(legacyStage)-\(Self.snapshotFailureCode(loadError))"
                migrationMessage = "Stored data could not be read: \(loadError.localizedDescription)"
                // Never overwrite an unreadable source. Demo seeding is only
                // valid when the repository positively reports no stored data.
                applyEmptySnapshot()
                return
            }
        }

        persistenceWritesBlocked = false
        persistenceBlockReason = nil
        persistenceBlockDetail = nil
        do {
            if outcome.snapshot.schemaVersion > Canonical.Snapshot.currentSchemaVersion {
                try apply(outcome.snapshot)
                persistenceWritesBlocked = true
                persistenceBlockReason = .newerSchema
                persistenceBlockDetail = nil
                migrationMessage = "Local data was created by a newer app version. Saving is disabled to preserve it."
                return
            }
            if outcome.snapshot.schemaVersion == 0 {
                // Repository recovery may have replaced a corrupt primary with
                // this schema-0 backup, so preserve the repaired source bytes.
                let migrationSourceData = try Data(contentsOf: fileURL)
                try migrateFileSnapshot(
                    outcome.snapshot,
                    sourceData: migrationSourceData,
                    kind: .canonicalSnapshotV0
                )
            } else {
                try apply(outcome.snapshot)
            }
            if outcome.source == .recoveredBackup {
                migrationMessage = "Recovered local data from the last known good backup."
            }
        } catch let canonicalProjectionError {
            persistenceWritesBlocked = true
            persistenceBlockReason = .unreadableSnapshot
            persistenceBlockDetail = "canonical-\(Self.snapshotFailureCode(canonicalProjectionError))"
            migrationMessage = "Stored data could not be projected: \(canonicalProjectionError.localizedDescription)"
            applyEmptySnapshot()
        }
    }

    func save() {
        guard !persistenceWritesBlocked else {
            migrationMessage = "Local data is unreadable. Saving is disabled to preserve the recovery source."
            return
        }
        do {
            try repository.save(snapshot)
        } catch { migrationMessage = "Could not save data: \(error.localizedDescription)" }
    }

    func persistenceDiagnostics() throws -> Canonical.PersistenceDiagnostics {
        var diagnostics = repository.diagnostics(for: try repository.load(), journal: try migrationJournal.read())
        // Phase 12 (12.00b.1): the monitored count (a count only). An
        // unreadable store falls back to the list last shown.
        diagnostics.rejectedChangeCount = (try? visibleRejectedChanges())?.count ?? rejectedChanges.count
        return diagnostics
    }

    /// Creates a metadata-only JSON report that the user can explicitly share
    /// with support. The closed report schema excludes customer records,
    /// identifiers, file paths, errors, credentials, sessions, and raw values.
    ///
    /// Phase 12 (12.02; 12.06: v4): the v4 report (`NativeSupportReport`), with the v2
    /// persistence report nested under `persistence`. Versions, booleans,
    /// bounded counts, age buckets and bounded codes only, within
    /// `NativeSupportDiagnostics.maximumReportBytes`.
    func createPersistenceSupportReport(appVersion: String? = nil, appBuild: String? = nil) throws -> URL {
        let data = try NativeSupportDiagnostics.encode(supportReport(appVersion: appVersion, appBuild: appBuild))
        let reportURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("tradeready-support-report.json")
        try data.write(to: reportURL, options: .atomic)
        return reportURL
    }

    /// Phase 12 (12.02): the support report's contents. Every string is a
    /// `NativeSupportCode`; nothing here reads a record, a credential or a
    /// marker's bytes (the scrub marker's scope, and whether it could be read,
    /// is reported as a code; the Keychain deletion record as its presence).
    func supportReport(appVersion: String? = nil, appBuild: String? = nil) -> NativeSupportReport {
        let now = Date()
        let version = NativeSupportCode(appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown")
        let build = NativeSupportCode(appBuild
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown")
        let count = NativeSupportDiagnostics.boundedCount

        var persistence: Canonical.PersistenceSupportReport?
        var persistenceUnavailableCode = NativeSupportCode(nil)
        do {
            persistence = Canonical.PersistenceSupportReport(
                appVersion: version.value, diagnostics: try persistenceDiagnostics()
            )
        } catch {
            persistenceUnavailableCode = NativeSupportCode(NativeSupportDiagnostics.errorCode(error))
        }

        let migration = legacyMigrationSummary
        let launchMigration = NativeSupportReport.LaunchMigration(
            notice: NativeSupportCode(launchMigrationNotice?.id),
            blocked: isLegacyMigrationBlocked,
            persistenceBlockReason: NativeSupportCode(persistenceBlockReason?.rawValue),
            persistenceBlockDetail: NativeSupportCode(persistenceBlockDetail),
            lastOutcome: NativeSupportCode(migration.outcome),
            lastOperation: NativeSupportCode(migration.operation),
            lastFailureCode: NativeSupportCode(migration.failureCode),
            importedCount: count(migration.importedCount),
            missingPhotoCount: count(migration.missingPhotoCount),
            adoptedPhotoCount: count(migration.adoptedPhotoCount),
            deferredPhotoCount: count(migration.deferredPhotoCount)
        )

        let scrubPendingScope: String
        do {
            scrubPendingScope = try repository.pendingAccountScrubScope?.rawValue ?? NativeSupportDiagnostics.none
        } catch Canonical.SnapshotRepository.AccountScrubMarkerError.undecodable {
            scrubPendingScope = "undecodable"
        } catch {
            scrubPendingScope = "unreadable"
        }
        let deletionRecord: String
        do {
            deletionRecord = try secureSettingsStore.isAccountDeletionScrubRecorded() ? "present" : "absent"
        } catch {
            deletionRecord = "unreadable"
        }
        let accountBoundary = NativeSupportReport.AccountBoundary(
            scrubPending: repository.isAccountScrubPending,
            scrubPendingScope: NativeSupportCode(scrubPendingScope),
            scrubBlocked: isAccountScrubBlocked,
            scrubBlockedScope: NativeSupportCode(isAccountScrubBlocked
                ? accountScrubBlockedScope?.rawValue ?? "unknown"
                : NativeSupportDiagnostics.none),
            scrubBlockedCount: count(accountScrubBlockedCount),
            deletionPendingWithoutMarker: accountDeletionPendingWithoutMarker,
            deletionRecordUnverified: accountDeletionRecordUnverified,
            deletionRecord: NativeSupportCode(deletionRecord),
            workspaceClearedRecord: repository.isLiveWorkspaceClearedByAccountScrub,
            cleanupPending: isAccountBoundaryCleanupPending,
            boundarySteps: Canonical.SnapshotRepository.BoundaryStep.allCases.map {
                NativeSupportReport.BoundaryStep(
                    step: NativeSupportCode($0.rawValue),
                    pending: isBoundaryStepPending($0),
                    unverified: boundaryStepsUnverified.contains($0)
                )
            },
            boundaryStepMarkerWriteFailureCount: count(boundaryStepMarkerWriteFailureCount),
            boundaryStepRecordFailureCount: count(boundaryStepRecordFailureCount),
            aiProviderKeyWipeFailureCount: count(aiProviderKeyWipeFailureCount)
        )

        let queued = mutationQueue.load()
        let oldestQueued = queued.compactMap { NativeSupportDiagnostics.queuedDate($0.ts) }.min()
        let status = syncStatus
        // Refused changes on file for this owner, including one hidden while a
        // newer change for its record is queued (the persistence part counts
        // the ones Cloud Sync shows). The list last shown if unreadable.
        let rejectedOnFile = (try? rejectedChangeStore.load(binding: verifiedAccountBinding))?.count
            ?? rejectedChanges.count
        let sync = NativeSupportReport.Sync(
            pendingCount: count(queued.count),
            oldestPendingAge: NativeSupportCode(NativeSupportDiagnostics.ageBucket(from: oldestQueued, now: now)),
            isSyncing: status.isSyncing,
            consecutiveFailures: count(status.consecutiveFailures),
            lastOutcome: NativeSupportCode(Self.supportCode(for: status.lastOutcome)),
            diagnosticCode: NativeSupportCode(status.diagnosticCode),
            lastPullState: NativeSupportCode(Self.supportCode(for: status.lastPullResult?.state)),
            lastPullCode: NativeSupportCode(status.lastPullResult?.diagnosticCode),
            backoffActive: status.nextEarliestAttempt.map { $0 > now } ?? false,
            lastSuccessfulSyncAge: NativeSupportCode(
                NativeSupportDiagnostics.ageBucket(from: status.lastSuccessfulSyncAt, now: now)
            ),
            rejectedChangeCount: count(rejectedOnFile),
            rejectedChangeOverflowCount: count(rejectedChangeOverflowCount),
            rejectedChangeScrubFailureCount: count(rejectedChangeScrubFailureCount),
            discardedChangeCount: count(syncMonitor.discardedChangeCount),
            throttledPassCount: count(syncMonitor.throttledPassCount),
            consecutiveThrottledPasses: count(syncMonitor.consecutiveThrottledPasses),
            maxConsecutiveThrottledPasses: count(syncMonitor.maxConsecutiveThrottledPasses),
            recentCodes: supportCodeHistory.entries,
            recentCodesOmitted: count(supportCodeHistory.omittedCount)
        )

        let replay = widgetActionReplayDiagnostics
        let widgets = NativeSupportReport.Widgets(
            mirrorDirty: isWidgetMirrorDirty,
            mirrorLockBusyCount: count(widgetMirrorLockBusyCount),
            ownerDroppedActionCount: count(replay.ownerDroppedActionCount),
            quarantinedQueueCount: count(replay.quarantinedQueueCount),
            accountSwitchScrubFailureCount: count(replay.accountSwitchScrubFailureCount),
            setAsideActionCount: count(replay.setAsideActionCount),
            quarantinedClaimCount: count(replay.quarantinedClaimCount),
            unreadableClaimCount: count(replay.unreadableClaimCount)
        )

        // Phase 12 (12.06): the last rollback-readiness check for this
        // account, as codes and counts (never a refused change's key).
        let rollback: NativeSupportReport.RollbackReadiness
        if let check = currentRollbackReadinessCheck {
            let readiness = check.readiness
            rollback = .init(
                lastCheck: readiness.isReady ? "ready" : "not-ready",
                lastCheckAge: NativeSupportCode(NativeSupportDiagnostics.ageBucket(from: check.checkedAt, now: now)),
                drainOutcome: NativeSupportCode(check.drainOutcome),
                blockers: readiness.blockers.map { NativeSupportCode($0.rawValue) },
                notes: readiness.notes.map { NativeSupportCode($0.rawValue) },
                pendingChangeCount: count(readiness.pendingChangeCount),
                rejectedChangeCount: count(readiness.rejectedChangeCount),
                widgetActionCount: count(readiness.widgetActionCount),
                photosPendingUploadCount: count(readiness.photosPendingUploadCount),
                bookingWorkCount: count(readiness.bookingWorkCount),
                migrationJournal: NativeSupportCode(readiness.migrationJournal.rawValue)
            )
        } else {
            rollback = .init(
                lastCheck: "none", lastCheckAge: "none", drainOutcome: "none", blockers: [], notes: [],
                pendingChangeCount: 0, rejectedChangeCount: 0, widgetActionCount: 0,
                photosPendingUploadCount: 0, bookingWorkCount: 0, migrationJournal: "none"
            )
        }

        let protection = repository.legacyFileProtectionTally.summary
        return NativeSupportReport(
            app: .init(version: version, build: build),
            persistence: persistence,
            persistenceUnavailableCode: persistenceUnavailableCode,
            launchMigration: launchMigration,
            accountBoundary: accountBoundary,
            sync: sync,
            widgets: widgets,
            legacyBackupProtection: .init(
                checks: count(protection.checks),
                enumeratorUnavailable: count(protection.enumeratorUnavailable),
                lastProtectedFiles: count(protection.lastProtected),
                lastFailedFiles: count(protection.lastFailed),
                failedFileTotal: count(protection.failedTotal)
            ),
            rollbackReadiness: rollback
        )
    }

    private static func supportCode(for outcome: NativeSyncOutcome?) -> String {
        switch outcome {
        case nil: NativeSupportDiagnostics.none
        case .idleNoChanges?: "idle-no-changes"
        case .offline?: "offline"
        case .notAuthenticated?: "not-authenticated"
        case .backoffDeferred?: "backoff-deferred"
        case .alreadyRunning?: "already-running"
        case .completed?: "completed"
        case .partial?: "partial"
        case .failed?: "failed"
        }
    }

    private static func supportCode(for state: NativeSyncPullResult.State?) -> String {
        switch state {
        case nil: NativeSupportDiagnostics.none
        case .completed?: "completed"
        case .partial?: "partial"
        case .failed?: "failed"
        case .skipped?: "skipped"
        }
    }

    @discardableResult
    func upsert(_ value: Customer) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.customers ?? []
            let result: Canonical.Customer
            // Task 11.08: RN `customer_created{first}` fires for a new record
            // only; `first` = no prior non-sample customer before this save.
            let isNewRecord = !records.contains(where: { $0.id == value.id })
            let isFirstRealCustomer = !records.contains(where: { !Self.isAnalyticsSampleID($0.id) })
            if let baseline = records.first(where: { $0.id == value.id }) {
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = value
                result = try CanonicalUIAdapters.canonical(from: edit)
            } else { result = try CanonicalUIAdapters.canonical(from: value) }
            replaceOrAppend(result, in: &records, id: \Canonical.Customer.id)
            updated.payload.customers = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "customers", recordId: result.id, record: result)
            if isNewRecord { emitAnalytics(.customerCreated(first: isFirstRealCustomer)) }
            return true
        } catch {
            migrationMessage = "Could not update customer: \(error.localizedDescription)"
            return false
        }
    }

    /// Saves canonical local truth before publishing the new screen projection.
    /// The editor only dismisses after this succeeds, matching the customer
    /// workflow's recoverable local-first commit boundary.
    @discardableResult
    func upsert(_ value: Job) -> Bool {
        persistJob(value, newRecordTemplate: nil)
    }

    /// Commits a duplicate only while its freshly minted ID remains absent.
    /// This keeps a delayed sheet from overwriting a record introduced by a
    /// concurrent pull, and retains the canonical pricing fields hidden from
    /// the current editor.
    @discardableResult
    func createDuplicatedJob(_ value: Job, template: Canonical.Job) -> Bool {
        guard template.id == value.id else {
            migrationMessage = "The duplicate draft is no longer valid. Nothing was saved."
            return false
        }
        return persistJob(value, newRecordTemplate: template)
    }

    func duplicateJobDraft(sourceID: String, createdAt: Date = .now) -> NativeJobDuplicateDraft? {
        guard let source = snapshot.payload.jobs?.first(where: { $0.id == sourceID }) else { return nil }
        do {
            return try CanonicalUIAdapters.duplicateJob(
                source,
                id: Job().id,
                createdAt: createdAt
            )
        } catch {
            migrationMessage = "The job could not be prepared for duplication. Nothing was changed."
            return nil
        }
    }

    func jobPricingDraft(jobID: String) -> NativeJobPricingDraft? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        return NativeJobPricingDraft(job: job, settings: snapshot.payload.settings)
    }

    func estimateReviewDraft(jobID: String) -> NativeEstimateReviewDraft? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              let status = JobStatus(rawValue: job.status)
        else { return nil }
        let customer = NativeCustomerIdentity.resolve(
            customers: customers,
            customerID: job.customerId,
            customerName: job.customerName
        )
        do {
            let reviewedSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
                job: job,
                customerName: customer?.name,
                businessName: settings.businessName
            )
            if status == .lead,
               job.approval == nil,
               let declined = job.approvalHistory?.last(where: { $0.decision == "declined" }),
               CanonicalUIAdapters.estimateApprovalSnapshotsMatch(reviewedSnapshot, declined.snapshot) {
                migrationMessage = "Revise the declined estimate before sending it again. The previous customer decision is preserved in estimate history."
                return nil
            }
            return NativeEstimateReviewDraft(
                jobID: jobID,
                expectedStatus: status,
                snapshot: reviewedSnapshot,
                customerEmail: customer?.email ?? "",
                customerPhone: customer?.phone ?? "",
                customerAddress: customer?.address ?? "",
                businessContactName: settings.contactName,
                businessPhone: settings.phone,
                businessEmail: settings.email,
                businessAddress: settings.address,
                businessLogoReference: snapshot.payload.settings?.logoPhoto,
                jobDescription: job.description
            )
        } catch {
            migrationMessage = "The estimate could not be prepared. Nothing was changed."
            return nil
        }
    }

    /// Task 10.08 (N5): every field read by the five notification selectors
    /// (`estimateFollowUpNotifications`, `appointmentConfirmationNotifications`,
    /// `reviewRequestNotifications`, `invoiceReminderNotifications`,
    /// `recurringInvoiceReminderNotifications`) plus their enable toggles must
    /// be represented here, so a `.task(id:)` bound to this key re-runs
    /// `synchronize()` whenever scheduling *or displayed copy* could change.
    /// Fields the selectors do not read (insight mutes, setup-checklist
    /// state, expenses, …) are deliberately absent — folding them in would
    /// only cause redundant reconciles (10.08 resolution). Permission-state
    /// changes are NOT folded in here: every call site that can change OS
    /// permission (`SettingsView`'s request button, the invoice-reminder
    /// soft-ask's "Turn on", and the `scenePhase == .active` foreground path)
    /// already calls `synchronize()` explicitly afterward.
    var estimateFollowUpNotificationScheduleKey: String {
        guard let binding = exactSignedInWorkspaceNotificationBinding else { return "inactive" }
        // Final-review m3: `uniquingKeysWith` (first record wins), never
        // `uniqueKeysWithValues` — this key is evaluated on every root body
        // render, so one duplicate job id in a pulled/corrupt snapshot would
        // otherwise trap the app in a crash loop.
        let jobStatusByID = Dictionary(
            (snapshot.payload.jobs ?? []).map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        // est_: title uses customerName, body uses job title.
        let rows = (snapshot.payload.jobs ?? []).compactMap { job -> String? in
            guard job.status == "estimate_sent" else { return nil }
            let sent = job.estimateSentAt ?? job.approval?.sentAt ?? ""
            return "\(job.id)|\(sent)|\(job.archivedAt ?? "")|\(job.customerName)|\(job.title)"
        }
        // appt_: title/body use the resolved customer's name (hashed via
        // appointmentContacts below); the job row itself needs status
        // membership, scheduledDate, and the ids used to resolve that customer.
        let appointments = (snapshot.payload.jobs ?? []).compactMap { job -> String? in
            guard job.status == "approved" || job.status == "scheduled" || job.status == "in_progress" else { return nil }
            return "\(job.id)|\(job.scheduledDate ?? "")|\(job.customerId)|\(job.customerName)|\(job.archivedAt ?? "")"
        }
        let appointmentContacts = (snapshot.payload.customers ?? []).map {
            "\($0.id)|\($0.name)|\($0.phone)|\($0.email)"
        }.joined(separator: ";")
        // review_: body uses the record's customerName and job title; the
        // rebuilt fire date depends on reviewRequestDelayHours (folded into
        // the shared toggle prefix below).
        let jobTitleByID = Dictionary(
            (snapshot.payload.jobs ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let reviews = reviewRequestRecords.map {
            let sentAt = $0.sentAt ?? ""
            let title = jobTitleByID[$0.jobId] ?? ""
            return "\($0.jobId)|\($0.scheduledAt)|\(sentAt)|\($0.customerName)|\(title)"
        }.joined(separator: ";")
        // inv_: title/body use invoice.customer/number; eligibility depends
        // on the linked job's status (isJobDunningEligible), not just its id.
        let invoiceRows = (snapshot.payload.invoices ?? []).map { invoice in
            let linkedStatus = invoice.jobId.flatMap { jobStatusByID[$0] } ?? ""
            return "\(invoice.id)|\(invoice.due)|\(invoice.paid)|\(invoice.jobId ?? "")|\(invoice.importBatchId ?? "")|\(invoice.customer)|\(invoice.number)|\(linkedStatus)"
        }.joined(separator: ";")
        let invoiceRules = (snapshot.payload.settings?.rules ?? []).map { "\($0.days)" }.joined(separator: ",")
        // rinv_: body uses rule.customerName.
        let recurringRules = (snapshot.payload.recurringInvoices ?? []).map {
            "\($0.id)|\($0.nextDueDate)|\($0.isActive)|\($0.customerName)"
        }.joined(separator: ";")
        return "\(binding)|\(settings.estimateFollowUpsEnabled)|\(settings.appointmentRemindersEnabled)|\(settings.reviewRequestEnabled)|\(settings.autoOutreachEnabled)|\(settings.reviewRequestDelayHours)|"
            + rows.joined(separator: ";") + "|" + appointments.joined(separator: ";") + "|" + appointmentContacts + "|" + reviews
            + "|" + invoiceRows + "|" + invoiceRules + "|" + recurringRules
    }

    var exactSignedInWorkspaceNotificationBinding: String? {
        guard hasExactSignedInWorkspace else { return nil }
        return verifiedAccountBinding
    }

    /// Task 10.05 (N1): has the owner-bound one-shot contextual
    /// invoice-reminder prompt already been shown/settled for the signed-in
    /// workspace? Reads `NativeReminderPromptStore` directly (no in-memory
    /// cache to drift) and fails closed to "already shown" — with no exact
    /// signed-in workspace or an unreadable store, the coordinator must never
    /// ask, matching the store's fail-closed contract.
    func wasInvoiceReminderPromptShown() -> Bool {
        guard let binding = exactSignedInWorkspaceNotificationBinding else { return true }
        return (try? reminderPromptStore.wasShown(for: binding)) ?? true
    }

    /// Stamps the flag for the signed-in workspace. Called by the coordinator
    /// BEFORE any permission request so a dismissed/undecided prompt never
    /// repeats. A silent no-op without an exact signed-in workspace.
    func markInvoiceReminderPromptShown() {
        guard let binding = exactSignedInWorkspaceNotificationBinding else { return }
        _ = try? reminderPromptStore.markShown(for: binding)
    }

    func estimateFollowUpNotifications(now: Date = .now) -> [NativeEstimateFollowUpNotification] {
        guard hasExactSignedInWorkspace else { return [] }
        return NativeEstimateFollowUp.notificationPlan(
            jobs: snapshot.payload.jobs ?? [],
            now: now,
            enabled: settings.estimateFollowUpsEnabled
        )
    }

    func appointmentConfirmationNotifications(now: Date = .now) -> [NativeNotificationPlanItem] {
        guard hasExactSignedInWorkspace else { return [] }
        return NativeAppointmentNotifications.notificationPlan(
            jobs: snapshot.payload.jobs ?? [],
            customers: snapshot.payload.customers ?? [],
            enabled: settings.appointmentRemindersEnabled,
            now: now
        )
    }

    /// Task 10.07 (N4/B2) fix: rebuilds pending `review_` one-shots from the
    /// durable records on every call — this IS the sweep-survival mechanism
    /// (RN's `syncNotifications` rebuild branch). `record.scheduledAt` is
    /// always written with fractional seconds (`armReviewRequestIfEligible`,
    /// `markReviewRequestSent`), so the reading formatter must accept that
    /// exact format too; a plain `ISO8601DateFormatter()` silently fails to
    /// parse it and drops every pending record from the rebuilt plan — this
    /// was the bug this fix closes.
    func reviewRequestNotifications(now: Date = .now) -> [NativeNotificationPlanItem] {
        guard hasExactSignedInWorkspace, settings.reviewRequestEnabled else { return [] }
        let jobs = snapshot.payload.jobs ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return reviewRequestRecords.compactMap { record in
            guard record.sentAt == nil,
                  let job = jobs.first(where: { $0.id == record.jobId }),
                  let scheduledAt = formatter.date(from: record.scheduledAt) else { return nil }
            let item = NativeReviewRequests.planItem(
                jobId: record.jobId,
                customerName: record.customerName,
                jobTitle: job.title,
                scheduledAt: scheduledAt,
                delayHours: settings.reviewRequestDelayHours
            )
            return item.fireDate > now ? item : nil
        }
    }

    /// Phase 7 `inv_` reminders. Rules come from the synced canonical
    /// settings (RN `settings.rules` parity); paid state derives from the
    /// payment ledger, not the stored flag.
    func invoiceReminderNotifications(now: Date = .now) -> [NativeNotificationPlanItem] {
        guard hasExactSignedInWorkspace else { return [] }
        // Final-review m3: duplicate ids must not trap (first record wins).
        let paidByID = Dictionary(invoices.map { ($0.id, $0.isPaid) }, uniquingKeysWith: { first, _ in first })
        let jobStatusByID = Dictionary(
            (snapshot.payload.jobs ?? []).map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let items = NativeInvoiceNotifications.reminders(
            invoices: (snapshot.payload.invoices ?? []).map { record in
                NativeInvoiceNotificationInvoice(
                    id: record.id, customer: record.customer, number: record.number,
                    isPaid: paidByID[record.id] ?? record.paid, due: record.due,
                    jobID: record.jobId, importBatchId: record.importBatchId)
            },
            ruleDays: (snapshot.payload.settings?.rules ?? []).map(\.days),
            autoOutreachEnabled: settings.autoOutreachEnabled,
            jobStatusByID: jobStatusByID,
            now: now)
        return items.map { item in
            NativeNotificationPlanItem(
                identifier: item.identifier, jobID: item.invoiceID,
                title: item.title, body: item.body,
                route: .invoiceReminder(
                    invoiceID: item.invoiceID, daysPastDue: item.daysPastDueRule,
                    opensOutreach: item.opensOutreach),
                fireDate: item.fireDate)
        }
    }

    /// Phase 7 `rinv_` reminders — one per active plan at 9 a.m. on its next
    /// generation date. Generation itself runs on foreground after sync.
    func recurringInvoiceReminderNotifications(now: Date = .now) -> [NativeNotificationPlanItem] {
        guard hasExactSignedInWorkspace else { return [] }
        return NativeInvoiceNotifications.recurringReminders(
            rules: (snapshot.payload.recurringInvoices ?? []).map { rule in
                NativeRecurringInvoiceNotificationRule(
                    id: rule.id, customerName: rule.customerName,
                    isActive: rule.isActive, nextDueDate: rule.nextDueDate)
            },
            now: now).map { item in
                NativeNotificationPlanItem(
                    identifier: item.identifier, jobID: item.ruleID,
                    title: item.title, body: item.body,
                    route: .recurringInvoiceReminder(ruleID: item.ruleID),
                    fireDate: item.fireDate)
            }
    }

    func reviewRequestDraft(jobID: String) -> NativeReviewRequestDraft? {
        guard hasExactSignedInWorkspace,
              let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        let live = NativeCustomerIdentity.resolve(
            customers: customers,
            customerID: job.customerId,
            customerName: job.customerName
        )
        let record = reviewRequestRecords.first(where: { $0.jobId == jobID })
        let contact = NativeReviewRequests.preferredContact(
            liveName: live?.name ?? job.customerName,
            livePhone: live?.phone ?? "",
            liveEmail: live?.email ?? "",
            record: record
        )
        let message = NativeReviewRequests.buildMessage(
            template: settings.reviewRequestTemplate,
            businessName: settings.businessName,
            customerName: contact.name,
            googleReviewLink: settings.googleReviewLink
        )
        return NativeReviewRequestDraft(
            jobID: jobID,
            jobTitle: job.title,
            customerID: live?.id ?? record?.customerId ?? job.customerId,
            customerName: contact.name,
            customerPhone: contact.phone,
            customerEmail: contact.email,
            message: message,
            missingLink: NativeReviewRequests.messageMissingLink(
                template: settings.reviewRequestTemplate,
                googleReviewLink: settings.googleReviewLink
            ),
            fallback: NativeReviewRequestFallbackContact(
                customerId: live?.id ?? record?.customerId ?? job.customerId,
                customerName: contact.name,
                customerPhone: contact.phone,
                customerEmail: contact.email
            )
        )
    }

    func markReviewRequestSent(
        jobID: String,
        fallback: NativeReviewRequestFallbackContact?,
        channel: NativeAnalyticsEvent.MessageChannel,
        now: Date = .now
    ) {
        guard let binding = verifiedAccountBinding else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let records = NativeReviewRequests.recordsMarkingSent(
            reviewRequestRecords,
            jobId: jobID,
            fallback: fallback,
            nowISO: formatter.string(from: now)
        )
        do {
            try reviewRequestStore.save(records, for: binding)
            reviewRequestRecords = records
            // Task 11.08: RN `ReviewRequestScreen.tsx:125/139`, after the one-shot save.
            emitAnalytics(.reviewRequestSent(channel: channel, source: reviewRequestAnalyticsSource))
        } catch {
            migrationMessage = "The review request was sent, but its one-shot record could not be saved."
        }
    }

    func awaitingEstimateFollowUpCount(now: Date = .now) -> Int {
        guard hasExactSignedInWorkspace, settings.estimateFollowUpsEnabled else { return 0 }
        return NativeEstimateFollowUp.awaitingResponse(
            jobs: snapshot.payload.jobs ?? [],
            now: now
        ).count
    }

    func estimateFollowUpDraft(jobID: String) -> NativeEstimateFollowUpDraft? {
        guard hasExactSignedInWorkspace,
              let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              let customer = NativeCustomerIdentity.resolve(
                customers: customers,
                customerID: job.customerId,
                customerName: job.customerName
              )
        else { return nil }
        return NativeEstimateFollowUp.draft(
            job: job,
            customerName: customer.name,
            customerPhone: customer.phone,
            customerEmail: customer.email,
            businessName: settings.businessName
        )
    }

    func requestEstimateFollowUpReview(
        jobID: String,
        source: NativeAnalyticsEvent.MessageSource = .notification
    ) {
        let job = snapshot.payload.jobs?.first { $0.id == jobID }
        guard NativeEstimateFollowUp.canOpenNotification(
            exactOwnerWorkspace: hasExactSignedInWorkspace,
            signedIn: isSignedIn,
            job: job
        ), estimateFollowUpDraft(jobID: jobID) != nil
        else { return }
        // Task 11.08: RN `App.tsx:420` / `JobDetailScreen.tsx:644`.
        estimateFollowUpAnalyticsSource = source
        emitAnalytics(.estimateFollowUpOpened(source: source))
        selectedTab = .jobs
        deepLinkedJobID = jobID
        pendingEstimateFollowUpJobID = jobID
    }

    func dismissPendingEstimateFollowUp(jobID: String) {
        guard pendingEstimateFollowUpJobID == jobID else { return }
        pendingEstimateFollowUpJobID = nil
    }

    func estimateApprovalHistory(jobID: String) -> [Canonical.EstimateApproval] {
        snapshot.payload.jobs?.first(where: { $0.id == jobID })?.approvalHistory ?? []
    }

    func activeEstimateApproval(jobID: String) -> Canonical.EstimateApproval? {
        snapshot.payload.jobs?.first(where: { $0.id == jobID })?.approval
    }

    /// Prefills the create/requestDeposit/finalize sheet for a job, mirroring
    /// `CreateInvoiceFromJobScreen`'s prefill `useEffect` exactly — including
    /// finalize mode's "keep the existing invoice's amount unless an approved
    /// change order changed it" rule. Line items are deliberately NOT part of
    /// this draft: like the RN screen, they're always recomputed fresh from
    /// the job at commit time (see `commitInvoiceFromJob`), never edited here.
    func invoiceFromJobDraft(jobID: String) -> NativeInvoiceFromJobDraft? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              let currentStatus = JobLifecycleStatus(rawValue: job.status)
        else { return nil }
        let hasInvoice = !(job.invoiceId ?? "").isEmpty
        guard let mode = JobLifecycleRules.invoiceScreenMode(status: currentStatus, hasInvoice: hasInvoice) else {
            migrationMessage = "This job's invoice is already open — find it from the Invoices tab."
            return nil
        }

        if mode == .finalize {
            guard let invoiceID = job.invoiceId,
                  let existing = snapshot.payload.invoices?.first(where: { $0.id == invoiceID })
            else {
                migrationMessage = "The deposit invoice for this job could not be found."
                return nil
            }
            let changeOrderDelta = JobInvoiceDomain.approvedChangeOrderTotal(changeOrderMirrors(job))
            let amount = changeOrderDelta != 0 ? billableBreakdown(for: job).total : existing.amount
            return NativeInvoiceFromJobDraft(
                jobID: jobID, mode: .finalize, existingInvoiceID: invoiceID,
                customer: existing.customer, customerID: existing.customerId ?? "",
                number: existing.number, amount: amount, due: JobInvoiceDomain.defaultDueDate(),
                email: existing.email, phone: existing.phone, desc: existing.desc,
                billedFromTracked: false, finalizeChangeOrderDelta: changeOrderDelta,
                prefillReferenceAmount: 0
            )
        }

        let customer = NativeCustomerIdentity.resolve(customers: customers, customerID: job.customerId, customerName: job.customerName)
        let breakdown = billableBreakdown(for: job)
        let changeOrderTotal = JobInvoiceDomain.approvedChangeOrderTotal(changeOrderMirrors(job))
        return NativeInvoiceFromJobDraft(
            jobID: jobID, mode: mode, existingInvoiceID: nil,
            customer: job.customerName, customerID: customer?.id ?? job.customerId,
            number: nextInvoiceNumber(), amount: breakdown.total, due: JobInvoiceDomain.defaultDueDate(),
            email: customer?.email ?? "", phone: customer?.phone ?? "", desc: job.title,
            billedFromTracked: breakdown.usedTrackedTime, finalizeChangeOrderDelta: 0,
            // Mirrors `jobBillableTotal` (estimateTotal + approved change
            // orders) exactly — the plain display figure the "pre-filled from
            // job estimate" banner quotes, not the tracked-time-aware `amount`.
            prefillReferenceAmount: job.estimateTotal + changeOrderTotal
        )
    }

    /// Commits a create/requestDeposit/finalize invoice draft atomically with
    /// its job-status change, following the same single-snapshot pattern as
    /// `stampEstimateSent`. Re-derives the job's invoice-screen mode from its
    /// CURRENT record before writing anything — a job that changed status
    /// while the sheet was open must not silently misfile. Line items are
    /// recomputed fresh from that current record too, never carried from the
    /// draft — mirroring `CreateInvoiceFromJobScreen.handleCreate`'s "build
    /// from the freshly-loaded row" comment: a sync pull that landed while the
    /// sheet sat open must not be silently overwritten with stale data.
    @discardableResult
    func commitInvoiceFromJob(_ draft: NativeInvoiceFromJobDraft) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var jobRecords = updated.payload.jobs ?? []
            guard let jobIndex = jobRecords.firstIndex(where: { $0.id == draft.jobID }) else {
                migrationMessage = "This job could not be found. Nothing was saved."
                return false
            }
            let job = jobRecords[jobIndex]
            guard let currentStatus = JobLifecycleStatus(rawValue: job.status),
                  JobLifecycleRules.invoiceScreenMode(
                      status: currentStatus, hasInvoice: !(job.invoiceId ?? "").isEmpty
                  ) == draft.mode
            else {
                migrationMessage = "The job changed while this invoice was open. Review it again before saving."
                return false
            }

            let lineItems = try CanonicalUIAdapters.invoiceLineItems(from: invoiceLineDrafts(for: job))
            var invoiceRecords = updated.payload.invoices ?? []
            let resultInvoice: Canonical.Invoice
            let invoicePaid: Bool

            if draft.mode == .finalize {
                guard let existingInvoiceID = draft.existingInvoiceID,
                      let invoiceIndex = invoiceRecords.firstIndex(where: { $0.id == existingInvoiceID })
                else {
                    migrationMessage = "The deposit invoice for this job could not be found."
                    return false
                }
                var edit = try CanonicalUIAdapters.edit(invoiceRecords[invoiceIndex])
                edit.value.customer = draft.customer
                if !draft.customerID.isEmpty { edit.value.customerId = draft.customerID }
                edit.value.number = draft.number
                edit.value.amount = NSDecimalNumber(decimal: draft.amount).doubleValue
                edit.value.due = draft.due
                edit.value.email = draft.email
                edit.value.phone = draft.phone
                edit.value.description = draft.desc
                var result = try CanonicalUIAdapters.canonical(from: edit)
                // Falls back to the existing lineItems only if recompute
                // yields nothing (matches the RN save path exactly).
                if !lineItems.isEmpty { result.lineItems = lineItems }
                result.jobId = draft.jobID
                // `canonical(from edit:)` only re-derives paid/paidAt when
                // `payments` itself changed — but the amount just did, so
                // reconcile explicitly (same reasoning as `AddInvoiceScreen`'s
                // handleSave in the RN app).
                let ledger = PaymentLedger.reconcilePaidFields(edit.value.workflowLedger)
                result.paid = ledger.paid
                result.paidAt = ledger.paidAt
                invoiceRecords[invoiceIndex] = result
                resultInvoice = result
                invoicePaid = result.paid
            } else {
                let screenInvoice = Invoice(
                    customerId: draft.customerID, customer: draft.customer, number: draft.number,
                    amount: NSDecimalNumber(decimal: draft.amount).doubleValue, due: draft.due,
                    email: draft.email, phone: draft.phone, description: draft.desc
                )
                var result = try CanonicalUIAdapters.canonical(from: screenInvoice)
                result.lineItems = lineItems.isEmpty ? nil : lineItems
                result.jobId = draft.jobID
                invoiceRecords.append(result)
                resultInvoice = result
                invoicePaid = false
            }

            let changes = JobLifecycleRules.changesAfterInvoiceSave(
                mode: draft.mode, invoiceID: resultInvoice.id, invoicePaid: invoicePaid
            )
            jobRecords[jobIndex].invoiceId = changes.invoiceID
            if let status = changes.status { jobRecords[jobIndex].status = status.rawValue }
            let resultJob = jobRecords[jobIndex]

            updated.payload.invoices = invoiceRecords
            updated.payload.jobs = jobRecords
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "invoices", recordId: resultInvoice.id, record: resultInvoice)
            enqueueUpsert(table: "jobs", recordId: resultJob.id, record: resultJob)
            // Contextual permission ask (task 10.05, N1): `.finalize` edits the
            // existing deposit invoice, while `.create`/`.requestDeposit` mint a
            // brand-new one — mirroring RN's `promptForInvoiceReminders()` call
            // in `CreateInvoiceFromJobScreen.tsx`, which only fires outside its
            // `mode === "finalize"` branch. Fire-and-forget, exactly like RN.
            if draft.mode != .finalize { onInvoiceCreatedContextualPrompt?() }
            // Task 11.08: RN `CreateInvoiceFromJobScreen.tsx:226`/`:245`.
            emitAnalytics(draft.mode == .finalize
                ? .invoiceFinalizedFromJob
                : .invoiceCreatedFromJob(mode: draft.mode))
            return true
        } catch {
            migrationMessage = "Could not save this invoice: \(error.localizedDescription)"
            return false
        }
    }

    /// Completes an in-progress job and, when the owner opted in and every RN
    /// gate is met, creates its final invoice in the same durable snapshot.
    /// Preparation failures degrade to the ordinary completed state; a
    /// persistence failure publishes neither transition.
    @discardableResult
    func completeJob(
        id: String,
        from expectedStatus: JobStatus = .inProgress,
        on date: Date = .now
    ) -> NativeJobCompletionOutcome {
        guard expectedStatus == .inProgress, ensurePersistenceWritable() else { return .failed }
        let baseline = snapshot
        var completedRecords = baseline.payload.jobs ?? []
        guard let jobIndex = completedRecords.firstIndex(where: { $0.id == id }),
              completedRecords[jobIndex].status == expectedStatus.rawValue
        else { return .failed }
        completedRecords[jobIndex].status = JobStatus.complete.rawValue
        let completedWithoutAutomation = completedRecords[jobIndex]

        func persistCompletedOnly() -> NativeJobCompletionOutcome {
            do {
                var completedSnapshot = baseline
                completedSnapshot.payload.jobs = completedRecords
                try repository.save(completedSnapshot)
                try apply(completedSnapshot)
                enqueueUpsert(
                    table: "jobs",
                    recordId: completedWithoutAutomation.id,
                    record: completedWithoutAutomation
                )
                armReviewRequestIfEligible(
                    previousStatus: expectedStatus.rawValue,
                    job: completedWithoutAutomation,
                    baseline: baseline,
                    at: date
                )
                // Task 11.08: RN `JobDetailScreen.tsx:842`.
                emitAnalytics(.jobStatusChanged(from: expectedStatus, to: .complete))
                return .completed
            } catch {
                migrationMessage = "Could not complete this job: \(error.localizedDescription)"
                return .failed
            }
        }

        let settingEnabled = baseline.payload.settings?.autoInvoiceOnComplete ?? false
        let shouldAutoCreate = JobInvoiceDomain.shouldAutoInvoice(
            enabled: settingEnabled,
            hasInvoice: !(completedWithoutAutomation.invoiceId ?? "").isEmpty,
            estimateTotal: completedWithoutAutomation.estimateTotal,
            customerName: completedWithoutAutomation.customerName
        )
        guard shouldAutoCreate else { return persistCompletedOnly() }

        do {
            var updated = baseline
            var jobRecords = completedRecords

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let completedAt = formatter.string(from: date)
            let plainSessions = (jobRecords[jobIndex].timeSessions ?? []).map {
                JobInvoiceTimeSession(start: $0.start, end: $0.end)
            }
            let clockedSessions = JobInvoiceDomain.clockOutLastOpenSession(plainSessions, at: completedAt)
            if let last = jobRecords[jobIndex].timeSessions?.indices.last,
               jobRecords[jobIndex].timeSessions?[last].end == nil,
               let clockedEnd = clockedSessions.last?.end {
                jobRecords[jobIndex].timeSessions?[last].end = clockedEnd
            }

            let completedJob = jobRecords[jobIndex]
            let matchingCustomer = NativeCustomerIdentity.resolve(
                customers: customers,
                customerID: completedJob.customerId,
                customerName: completedJob.customerName
            )
            var customerRecords = updated.payload.customers ?? []
            let invoiceCustomer: Canonical.Customer
            var createdCustomer: Canonical.Customer?
            if let matchingCustomer,
               let canonical = customerRecords.first(where: { $0.id == matchingCustomer.id }) {
                invoiceCustomer = canonical
            } else {
                let newCustomer = Customer(name: completedJob.customerName.trimmingCharacters(in: .whitespacesAndNewlines))
                let canonical = try CanonicalUIAdapters.canonical(from: newCustomer)
                customerRecords.append(canonical)
                invoiceCustomer = canonical
                createdCustomer = canonical
            }

            let breakdown = billableBreakdown(for: completedJob)
            guard breakdown.total > 0 else {
                // The RN path treats a non-positive derived total as an unmet
                // gate even when the quoted estimate itself was positive.
                return persistCompletedOnly()
            }

            let screenInvoice = Invoice(
                customerId: invoiceCustomer.id,
                customer: completedJob.customerName.trimmingCharacters(in: .whitespacesAndNewlines),
                number: nextInvoiceNumber(),
                amount: NSDecimalNumber(decimal: breakdown.total).doubleValue,
                due: JobInvoiceDomain.defaultDueDate(from: date),
                email: invoiceCustomer.email,
                phone: invoiceCustomer.phone,
                description: completedJob.title
            )
            var resultInvoice = try CanonicalUIAdapters.canonical(from: screenInvoice)
            let lineItems = try CanonicalUIAdapters.invoiceLineItems(from: invoiceLineDrafts(for: completedJob))
            resultInvoice.lineItems = lineItems.isEmpty ? nil : lineItems
            resultInvoice.jobId = completedJob.id
            if baseline.payload.settings?.autoEmailInvoiceOnComplete == true,
               Self.isPlausibleEmail(resultInvoice.email) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resultInvoice.autoEmailRequestedAt = formatter.string(from: date)
            }

            jobRecords[jobIndex].invoiceId = resultInvoice.id
            jobRecords[jobIndex].status = JobStatus.invoiced.rawValue
            let resultJob = jobRecords[jobIndex]
            var invoiceRecords = updated.payload.invoices ?? []
            invoiceRecords.append(resultInvoice)
            updated.payload.customers = customerRecords
            updated.payload.invoices = invoiceRecords
            updated.payload.jobs = jobRecords

            try repository.save(updated)
            try apply(updated)
            if let createdCustomer {
                enqueueUpsert(table: "customers", recordId: createdCustomer.id, record: createdCustomer)
            }
            enqueueUpsert(table: "invoices", recordId: resultInvoice.id, record: resultInvoice)
            enqueueUpsert(table: "jobs", recordId: resultJob.id, record: resultJob)
            scheduleNativeInvoiceDelivery(invoiceID: resultInvoice.id)
            armReviewRequestIfEligible(
                previousStatus: expectedStatus.rawValue,
                job: completedWithoutAutomation,
                baseline: baseline,
                at: date
            )
            // Task 11.08: the status change, then RN `utils/autoInvoice.ts:337`.
            emitAnalytics(.jobStatusChanged(from: expectedStatus, to: .complete))
            emitAnalytics(.invoiceCreatedOnCompletion(
                usedTrackedTime: breakdown.usedTrackedTime,
                autoEmailQueued: resultInvoice.autoEmailRequestedAt != nil
            ))
            return .autoInvoiced(invoiceID: resultInvoice.id)
        } catch {
            // Automatic preparation/delivery is optional. If customer or
            // invoice canonicalization fails, retain the primary lifecycle
            // action and expose the ordinary manual invoice path.
            return persistCompletedOnly()
        }
    }

    private static func isPlausibleEmail(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, value.contains("@"), value.contains("."),
              !value.contains(where: { $0.isWhitespace || ",;<>\"".contains($0) }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Delivery is deliberately post-commit and best effort. Each network
    /// await is followed by a fresh canonical read before merging only the
    /// delivery field, so payment and sync edits cannot be clobbered.
    /// Per-invoice runs are serialized; the owner binding is rechecked across
    /// every await so another account's invoice is never prepared.
    private var invoiceDeliveryInFlight: Set<String> = []

    private func scheduleNativeInvoiceDelivery(invoiceID: String) {
        guard snapshot.payload.invoices?.contains(where: { $0.id == invoiceID && $0.autoEmailRequestedAt != nil }) == true else { return }
        Task { [weak self] in await self?.deliverNativeInvoice(invoiceID: invoiceID) }
    }

    /// Relaunch/offline recovery: re-prepares every stamped, unpaid,
    /// non-imported invoice. Called on foreground refresh; per-invoice
    /// serialization makes overlapping scans safe.
    private func rescheduleInvoiceDeliveries() {
        for invoice in snapshot.payload.invoices ?? [] where invoice.autoEmailRequestedAt != nil {
            scheduleNativeInvoiceDelivery(invoiceID: invoice.id)
        }
    }

    private func configuredInvoiceDeliveryService() -> (any NativeInvoiceDelivering)? {
        if let injectedInvoiceDeliveryService { return injectedInvoiceDeliveryService }
        guard let payment = try? BuildEnvironment.endpoint("api/create-payment-link", sendsUserData: true),
              let pdf = try? BuildEnvironment.endpoint("api/invoice-pdf", sendsUserData: true) else { return nil }
        return NativeInvoiceDeliveryService(paymentLinkEndpoint: payment, pdfEndpoint: pdf)
    }

    private func deliverNativeInvoice(invoiceID: String) async {
        #if canImport(UIKit)
        guard !invoiceDeliveryInFlight.contains(invoiceID) else { return }
        invoiceDeliveryInFlight.insert(invoiceID)
        defer { invoiceDeliveryInFlight.remove(invoiceID) }
        guard let service = configuredInvoiceDeliveryService(), let credentials = currentSyncCredentials(),
              var latest = snapshot.payload.invoices?.first(where: { $0.id == invoiceID }),
              let settings = snapshot.payload.settings,
              // Imported historical invoices are never auto-prepared.
              latest.importBatchId == nil
        else { return }
        let owner = authenticatedUserSubject
        do {
            guard Self.ledgerBalance(latest) > PaymentLedger.paidEpsilon else { return }
            do {
                let link = try await service.createPaymentLink(
                    invoice: latest, amount: Self.ledgerBalance(latest), sessionBytes: credentials.sessionBytes)
                guard authenticatedUserSubject == owner,
                      let current = snapshot.payload.invoices?.first(where: {
                          $0.id == invoiceID && $0.autoEmailRequestedAt != nil
                      })
                else { return }
                if abs(Self.ledgerBalance(current) - Self.ledgerBalance(latest)) <= PaymentLedger.paidEpsilon {
                    latest = current
                    latest.paymentLinkUrl = link.absoluteString
                    latest.paymentLinkAmount = Self.ledgerBalance(latest)
                    try persistInvoiceDeliveryFields(latest)
                }
            } catch NativeInvoiceDeliveryError.rejectedSession {
                // One verified-refresh retry, then give up until the next scan.
                guard await refreshSyncSession(),
                      authenticatedUserSubject == owner,
                      let retry = currentSyncCredentials(),
                      let current = snapshot.payload.invoices?.first(where: {
                          $0.id == invoiceID && $0.autoEmailRequestedAt != nil
                      })
                else { return }
                let link = try await service.createPaymentLink(
                    invoice: current, amount: Self.ledgerBalance(current), sessionBytes: retry.sessionBytes)
                guard authenticatedUserSubject == owner else { return }
                latest = current
                latest.paymentLinkUrl = link.absoluteString
                latest.paymentLinkAmount = Self.ledgerBalance(current)
                try persistInvoiceDeliveryFields(latest)
            }
            guard authenticatedUserSubject == owner,
                  snapshot.payload.invoices?.contains(where: {
                      $0.id == invoiceID && $0.autoEmailRequestedAt != nil
                  }) == true,
                  let uploadCredentials = currentSyncCredentials()
            else { return }
            let document = NativeInvoicePDFDocument(invoice: latest, settings: settings)
            let pdf = try NativeInvoicePDFRenderer.data(for: document, logoReference: settings.logoPhoto)
            try await service.uploadPDF(invoiceID: invoiceID, pdf: pdf, sessionBytes: uploadCredentials.sessionBytes)
        } catch {
            invoiceDeliveryFailures[invoiceID] = String(describing: error)
            if invoiceDeliveryFailures.count > 16, let oldest = invoiceDeliveryFailures.keys.sorted().first {
                invoiceDeliveryFailures.removeValue(forKey: oldest)
            }
            print("TradeReadyInvoiceDelivery unavailable: \(error)")
        }
        #endif
    }

    private static func ledgerBalance(_ invoice: Canonical.Invoice) -> Decimal {
        PaymentLedger.balanceDue(LedgerInvoice(
            id: invoice.id, amount: invoice.amount, due: invoice.due, paid: invoice.paid,
            paidAt: invoice.paidAt, payments: invoice.payments?.map {
                LedgerPayment(id: $0.id, amount: $0.amount, date: $0.date, method: .other, note: $0.note, voidedAt: $0.voidedAt)
            }, depositRequest: nil))
    }

    private func persistInvoiceDeliveryFields(_ invoice: Canonical.Invoice) throws {
        var updated = snapshot; var invoices = updated.payload.invoices ?? []
        guard let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
        var current = invoices[index]
        current.paymentLinkUrl = invoice.paymentLinkUrl; current.paymentLinkAmount = invoice.paymentLinkAmount
        invoices[index] = current; updated.payload.invoices = invoices
        try repository.save(updated); try apply(updated); enqueueUpsert(table: "invoices", recordId: current.id, record: current)
    }

    // MARK: - Phase 7 Stripe Connect + payment links

    private func configuredStripeConnectService() -> NativeStripeConnectService? {
        guard let status = try? BuildEnvironment.endpoint("api/stripe/connect-status", sendsUserData: true),
              let connect = try? BuildEnvironment.endpoint("api/stripe/create-connect-account", sendsUserData: true),
              let disconnect = try? BuildEnvironment.endpoint("api/stripe/disconnect", sendsUserData: true)
        else { return nil }
        return NativeStripeConnectService(statusEndpoint: status, connectEndpoint: connect, disconnectEndpoint: disconnect)
    }

    /// Reads the current Connect state. Surfaces authentication rejection
    /// through one verified-refresh retry, matching the sync boundary.
    ///
    /// Fix round 1 (I4): `verifiedAccountBinding` is captured immediately
    /// before each `await service.status(...)` and re-checked immediately
    /// after, so an account switch that lands mid-await can never write the
    /// `stripe` task done under the account that's live by the time the
    /// response arrives.
    func refreshStripeStatus() async {
        guard let service = configuredStripeConnectService(), let credentials = currentSyncCredentials() else {
            stripeConnectError = "Stripe status is unavailable until the backend is configured and you are signed in."
            return
        }
        stripeConnectLoading = true
        defer { stripeConnectLoading = false }
        let bindingBeforeAwait = verifiedAccountBinding
        do {
            stripeConnectStatus = try await service.status(sessionBytes: credentials.sessionBytes)
            stripeConnectError = nil
            markSetupTaskDoneIfStripeConnected(verifiedAccountBindingBeforeAwait: bindingBeforeAwait)
        } catch NativeStripeConnectError.rejectedSession {
            guard await refreshSyncSession(), let retry = currentSyncCredentials() else {
                stripeConnectError = "Your session expired. Sign in again to check the Stripe connection."
                return
            }
            let bindingBeforeRetryAwait = verifiedAccountBinding
            do {
                stripeConnectStatus = try await service.status(sessionBytes: retry.sessionBytes)
                stripeConnectError = nil
                markSetupTaskDoneIfStripeConnected(verifiedAccountBindingBeforeAwait: bindingBeforeRetryAwait)
            } catch {
                stripeConnectError = "Could not check the Stripe connection. Please try again."
            }
        } catch {
            stripeConnectError = "Could not check the Stripe connection. Please try again."
        }
    }

    /// Task 10.12 (D4): mirrors `utils/stripeStatus.ts`'s
    /// `if (data?.connected) markSetupTaskDone("stripe")` — the `stripe` task
    /// has no other honest derivation (unlike `contact`/`logo`/`notifications`,
    /// which read live settings/permission state directly).
    ///
    /// Fix round 1 (I4): the connected-check is now paired with
    /// `Self.stripeTaskWriteAllowed`, a pure predicate that also requires the
    /// account binding to be unchanged since the await started.
    private func markSetupTaskDoneIfStripeConnected(verifiedAccountBindingBeforeAwait: String?) {
        guard Self.stripeTaskWriteAllowed(
            connected: stripeConnectStatus?.connected == true,
            bindingBeforeAwait: verifiedAccountBindingBeforeAwait,
            currentBinding: verifiedAccountBinding
        ) else { return }
        markSetupTaskDone(.stripe)
    }

    /// Fix round 1 (I4): pure stale-write guard for
    /// `markSetupTaskDoneIfStripeConnected`, factored out so it's directly
    /// testable without driving a real network await — `configuredStripeConnectService()`
    /// performs real network I/O and has no injectable seam today, so the
    /// full async race isn't exercised end-to-end (see the fix-round-1 report
    /// section for why). This predicate is what the guard actually decides:
    /// write only when Stripe reports connected AND the verified account
    /// binding captured before the `await` still matches the one live now.
    static func stripeTaskWriteAllowed(connected: Bool, bindingBeforeAwait: String?, currentBinding: String?) -> Bool {
        connected && bindingBeforeAwait != nil && bindingBeforeAwait == currentBinding
    }

    /// Starts (or resumes) onboarding. The caller opens the returned URL in
    /// the system browser and refreshes status on foreground return; the
    /// return itself is never treated as proof of connection.
    func beginStripeOnboarding() async -> URL? {
        guard let service = configuredStripeConnectService(), let credentials = currentSyncCredentials() else {
            stripeConnectError = "Stripe onboarding needs a configured backend and an active sign-in."
            return nil
        }
        stripeConnectLoading = true
        defer { stripeConnectLoading = false }
        do {
            let url = try await service.beginOnboarding(sessionBytes: credentials.sessionBytes)
            stripeConnectError = nil
            return url
        } catch NativeStripeConnectError.rejectedSession {
            stripeConnectError = "Your session expired. Sign in again to connect Stripe."
            return nil
        } catch {
            stripeConnectError = "Could not start Stripe onboarding. Please try again."
            return nil
        }
    }

    func disconnectStripe() async -> Bool {
        guard let service = configuredStripeConnectService(), let credentials = currentSyncCredentials() else {
            stripeConnectError = "Stripe disconnect needs an active sign-in."
            return false
        }
        stripeConnectLoading = true
        defer { stripeConnectLoading = false }
        do {
            try await service.disconnect(sessionBytes: credentials.sessionBytes)
            stripeConnectStatus = NativeStripeConnectStatus(connected: false, detailsSubmitted: false, displayName: nil)
            stripeConnectError = nil
            return true
        } catch {
            stripeConnectError = "Could not disconnect Stripe. Please try again."
            return false
        }
    }

    /// A bulk settlement's result. P12-008 review (fix round 1, R41):
    /// `failure` says why nothing was settled when the commit did not happen
    /// (writes are blocked, or the save failed), so the Invoices list never
    /// reports a failed save as "already paid"; nil when the run saved or
    /// only skipped.
    typealias BulkSettleResult = (settled: [Invoice], skipped: Int, failure: String?)

    /// Phase 7 bulk settlement: resolves the latest selected records and
    /// settles every applicable invoice plus its job reconciliation in ONE
    /// canonical snapshot save. Already-paid and missing records are skipped
    /// and reported, never failed. Settlement IDs are stable per
    /// (invoice, day) so a repeated run cannot double-record.
    @discardableResult
    func commitBulkSettleInvoices(ids: [String], on date: Date = .now) -> BulkSettleResult {
        guard ensurePersistenceWritable() else { return ([], ids.count, Self.persistenceReadOnlyMessage) }
        let day = NativeInvoiceEditing.dayString(date)
        var invoiceRecords = snapshot.payload.invoices ?? []
        var settledCanonical: [Canonical.Invoice] = []
        var settledPublished: [Invoice] = []
        var skipped = 0
        for id in ids {
            guard let current = invoices.first(where: { $0.id == id }) else { skipped += 1; continue }
            if current.isPaid { skipped += 1; continue }
            guard let baseline = invoiceRecords.first(where: { $0.id == id }) else { skipped += 1; continue }
            do {
                var edit = try CanonicalUIAdapters.edit(baseline)
                edit.value = current.settlingRemaining(on: date, paymentID: "bulk-settle-\(id)-\(day)")
                var result = try CanonicalUIAdapters.canonical(from: edit)
                Self.reconcileInvoicePaidFields(&result)
                replaceOrAppend(result, in: &invoiceRecords, id: \Canonical.Invoice.id)
                settledCanonical.append(result)
                if let published = try? CanonicalUIAdapters.invoice(from: result) {
                    settledPublished.append(published)
                }
            } catch {
                skipped += 1
            }
        }
        guard !settledCanonical.isEmpty else { return ([], skipped, nil) }
        do {
            // P12-008: built on a copy and committed through `commitSnapshot`
            // (see `commitInvoicePayment`).
            var next = snapshot
            next.payload.invoices = invoiceRecords
            var jobRecords = next.payload.jobs ?? []
            var advancedJobIDs: [String] = []
            let currentJobs = jobs.map(\.lifecycleJob)
            let advanced = JobLifecycleRules.advancePaidInvoiceJobs(
                currentJobs,
                invoices: settledPublished.map(\.workflowLedger))
            for (before, after) in zip(currentJobs, advanced) where before.status != after.status {
                guard let index = jobRecords.firstIndex(where: { $0.id == after.id }),
                      var job = try? CanonicalUIAdapters.job(from: jobRecords[index])
                else { continue }
                job.status = JobStatus(lifecycleStatus: after.status)
                var jobEdit = try CanonicalUIAdapters.edit(jobRecords[index])
                jobEdit.value = job
                jobRecords[index] = try CanonicalUIAdapters.canonical(from: jobEdit)
                advancedJobIDs.append(after.id)
            }
            next.payload.jobs = jobRecords
            try commitSnapshot(next)
            for record in settledCanonical {
                enqueueUpsert(table: "invoices", recordId: record.id, record: record)
            }
            for jobID in advancedJobIDs {
                guard let record = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { continue }
                enqueueUpsert(table: "jobs", recordId: jobID, record: record)
            }
            // Task 11.08: RN `InvoicesScreen.tsx:239`/`:241`.
            for invoice in settledPublished { emitAnalytics(.invoicePaid(amount: invoice.amount)) }
            emitAnalytics(.bulkInvoicesMarkedPaid(count: settledPublished.count))
            // One owner action, one win, however many invoices it settled.
            if !settledPublished.isEmpty { onAppRatingWin?(.invoicePaid) }
            return (settledPublished, skipped, nil)
        } catch {
            migrationMessage = "Could not mark the invoices paid: \(error.localizedDescription)"
            reportInvoicePaymentFailure(
                code: "invoice-payment/bulkMarkPaid/\(NativeSupportDiagnostics.errorCode(error))",
                operation: "bulkMarkPaid", count: settledCanonical.count
            )
            return ([], ids.count, Self.bulkSettleNotSavedMessage)
        }
    }

    /// Display-side twin of the link cache gate: returns the stored link only
    /// when it was minted for the amount being requested now, so a link
    /// minted before a partial payment is never presented as current.
    func cachedInvoicePaymentLink(invoiceID: String, amount: Decimal) -> String? {
        guard let record = snapshot.payload.invoices?.first(where: { $0.id == invoiceID }) else { return nil }
        let requested = NSDecimalNumber(decimal: amount).doubleValue
        let cachedAmount = record.paymentLinkAmount.map { NSDecimalNumber(decimal: $0).doubleValue }
        guard NativeInvoicePaymentLinks.cachedLinkMatches(url: record.paymentLinkUrl, amount: cachedAmount, requested: requested),
              let link = record.paymentLinkUrl, !link.isEmpty
        else { return nil }
        return link
    }

    /// Resolves a payment link for the requested amount: reuses the cached
    /// link only when it was minted for exactly this amount, mints a fresh
    /// Stripe link through the backend otherwise, and builds offline links
    /// for the other providers. Persists the minted link against its amount
    /// and returns the URL. Throws for unconfigured providers.
    func generateInvoicePaymentLink(
        invoiceID: String,
        amount: Decimal,
        provider: NativePaymentProvider
    ) async throws -> URL {
        guard amount > 0,
              let record = snapshot.payload.invoices?.first(where: { $0.id == invoiceID })
        else { throw NativeInvoiceDeliveryError.invalidAmount }
        let requested = NSDecimalNumber(decimal: amount).doubleValue
        let cachedAmount = record.paymentLinkAmount.map { NSDecimalNumber(decimal: $0).doubleValue }
        if NativeInvoicePaymentLinks.cachedLinkMatches(
            url: record.paymentLinkUrl, amount: cachedAmount, requested: requested),
           let cached = record.paymentLinkUrl, let url = URL(string: cached) {
            return url
        }
        let key = settings.providerKey(for: provider.rawValue)
        if provider != .stripe {
            let link = try NativeInvoicePaymentLinks.offlineLink(
                invoiceNumber: record.number,
                description: record.desc,
                provider: provider,
                providerKey: key,
                amount: requested)
            guard let url = URL(string: link) else { throw NativeInvoiceDeliveryError.invalidResponse }
            var updated = record
            updated.paymentLinkUrl = link
            updated.paymentLinkAmount = amount
            try persistInvoiceDeliveryFields(updated)
            return url
        }
        guard let service = configuredInvoiceDeliveryService(), let credentials = currentSyncCredentials() else {
            throw NativeInvoiceDeliveryError.invalidConfiguration
        }
        // Recheck the request across the network await so a concurrent
        // payment cannot leave a stale-amount link persisted as current.
        let owner = authenticatedUserSubject
        let url = try await service.createPaymentLink(invoice: record, amount: amount, sessionBytes: credentials.sessionBytes)
        guard authenticatedUserSubject == owner,
              let latest = snapshot.payload.invoices?.first(where: { $0.id == invoiceID })
        else { throw NativeInvoiceDeliveryError.rejectedSession }
        let latestBalance = PaymentLedger.balanceDue(Self.ledgerInvoice(latest))
        let latestBalanceDouble = NSDecimalNumber(decimal: latestBalance).doubleValue
        guard abs(latestBalanceDouble - requested) <= NativeInvoicePaymentLinks.epsilon else {
            throw NativeInvoiceDeliveryError.invalidAmount
        }
        var updated = latest
        updated.paymentLinkUrl = url.absoluteString
        updated.paymentLinkAmount = amount
        try persistInvoiceDeliveryFields(updated)
        return url
    }

    /// Frozen customer-facing invoice content built from the latest canonical
    /// record, so sharing or exporting can never mutate invoice state or
    /// imply delivery.
    func invoicePDFDocument(invoiceID: String) -> NativeInvoicePDFDocument? {
        guard let record = snapshot.payload.invoices?.first(where: { $0.id == invoiceID }),
              let settings = snapshot.payload.settings
        else { return nil }
        return NativeInvoicePDFDocument(invoice: record, settings: settings)
    }

    /// Logo file reference for document rendering; a missing or unreadable
    /// reference omits only the logo.
    func invoicePDFLogoReference() -> String? {
        snapshot.payload.settings?.logoPhoto
    }

    /// Best-effort supersede of a pending automatic send after a manual
    /// compose outcome that counts as sent (`clearAutoEmailRequest` parity).
    /// Never throws: a failed clear must not disturb the reviewed composer.
    func clearInvoiceAutoEmailRequest(invoiceID: String) {
        guard ensurePersistenceWritable() else { return }
        var records = snapshot.payload.invoices ?? []
        guard let index = records.firstIndex(where: { $0.id == invoiceID }),
              records[index].autoEmailRequestedAt != nil
        else { return }
        records[index].autoEmailRequestedAt = nil
        let record = records[index]
        var next = snapshot
        next.payload.invoices = records
        do {
            // P12-008: queued only once saved; a failed clear changes nothing.
            try commitSnapshot(next)
            enqueueUpsert(table: "invoices", recordId: record.id, record: record)
        } catch {
            migrationMessage = "Could not save data: \(error.localizedDescription)"
        }
    }

    private static func ledgerInvoice(_ record: Canonical.Invoice) -> LedgerInvoice {        LedgerInvoice(
            id: record.id, amount: record.amount, due: record.due, paid: record.paid,
            paidAt: record.paidAt,
            payments: record.payments?.map {
                LedgerPayment(id: $0.id, amount: $0.amount, date: $0.date, method: .other, note: $0.note, voidedAt: $0.voidedAt)
            },
            depositRequest: nil)
    }

    private func armReviewRequestIfEligible(
        previousStatus: String,
        job: Canonical.Job,
        baseline: Canonical.Snapshot,
        at date: Date
    ) {
        let live = NativeCustomerIdentity.resolve(
            customers: (baseline.payload.customers ?? []).compactMap { try? CanonicalUIAdapters.customer(from: $0) },
            customerID: job.customerId,
            customerName: job.customerName
        )
        let phone = live?.phone ?? ""
        let email = live?.email ?? ""
        guard NativeReviewRequests.shouldSchedule(
            previousStatusRaw: previousStatus,
            currentStatusRaw: JobStatus.complete.rawValue,
            reviewRequestEnabled: baseline.payload.settings?.reviewRequestEnabled ?? false,
            customerPhone: phone,
            customerEmail: email,
            hasExistingRecord: reviewRequestRecords.contains(where: { $0.jobId == job.id })
        ) else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = NativeReviewRequestRecord(
            jobId: job.id,
            customerId: live?.id ?? job.customerId,
            customerName: live?.name ?? job.customerName,
            customerPhone: phone,
            customerEmail: email,
            scheduledAt: formatter.string(from: date),
            sentAt: nil
        )
        do {
            guard let binding = verifiedAccountBinding else { return }
            let records = try reviewRequestStore.mergeSeeded([record], for: binding)
            reviewRequestRecords = records
        } catch {
            migrationMessage = "The job was completed, but its review reminder could not be scheduled."
        }
    }

    /// Begins a declined-estimate revision through the authoritative backend.
    /// The server atomically archives the exact active approval, clears its
    /// capability, and returns the job to lead under an updated-at condition.
    /// No local mutation occurs until that server result has been validated.
    func beginDeclinedEstimateRevision(jobID: String) async -> NativeEstimateRevisionOutcome {
        guard let subject = authenticatedUserSubject,
              let binding = verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              let service = configuredEstimateApprovalLinkService()
        else { return .failure(.rejectedSession) }

        guard await syncNowAndWait(trigger: .manual) != nil else {
            return .failure(.jobNotSynced)
        }
        guard subject == authenticatedUserSubject,
              binding == verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              syncStatus.lastPullResult?.state == .completed,
              !mutationQueue.load().contains(where: {
                  $0.table == "jobs" && $0.recordId == jobID
              }),
              let current = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              let currentStatus = JobStatus(rawValue: current.status),
              let approval = current.approval,
              approval.decision == "declined",
              [.lead, .estimateSent, .declined].contains(currentStatus)
        else { return .failure(.revisionConflict) }

        func request(_ credentials: NativeSyncCredentials) async throws -> Canonical.Job {
            try await service.beginDeclinedRevision(
                jobID: jobID,
                approvalToken: approval.token,
                sessionBytes: credentials.sessionBytes
            )
        }

        let revised: Canonical.Job
        do {
            guard let credentials = currentSyncCredentials(), credentials.subject == subject else {
                return .failure(.malformedSession)
            }
            do {
                revised = try await request(credentials)
            } catch NativeEstimateApprovalLinkError.rejectedSession {
                guard await refreshSyncSession(),
                      let fresh = currentSyncCredentials(),
                      fresh.subject == subject,
                      subject == authenticatedUserSubject
                else { return .failure(.rejectedSession) }
                revised = try await request(fresh)
            }
        } catch let error as NativeEstimateApprovalLinkError {
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }

        let priorHistoryPreserved = (current.approvalHistory ?? []).allSatisfy { prior in
            revised.approvalHistory?.contains(where: {
                CanonicalUIAdapters.estimateApprovalsMatch($0, prior)
            }) == true
        }
        guard subject == authenticatedUserSubject,
              binding == verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              ensurePersistenceWritable(),
              revised.id == current.id,
              revised.status == JobStatus.lead.rawValue,
              revised.approval == nil,
              revised.estimateSentAt == nil,
              let archived = revised.approvalHistory?.first(where: { $0.token == approval.token }),
              CanonicalUIAdapters.estimateApprovalsMatch(archived, approval),
              priorHistoryPreserved
        else { return .failure(.invalidResponse) }

        do {
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            guard let index = records.firstIndex(where: { $0.id == jobID }),
                  CanonicalUIAdapters.canonicalJobsMatch(records[index], current)
            else { return .failure(.revisionConflict) }
            records[index] = revised
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            return .revised
        } catch {
            migrationMessage = "The server preserved the declined estimate, but this device could not save the revision. Refresh before trying again."
            return .failure(.invalidResponse)
        }
    }

    /// Marks a reviewed lead estimate as sent only if the canonical job still
    /// has the status shown when the review opened. This is a local-first stamp:
    /// the snapshot commits before the UI reports success or queues the upsert.
    @discardableResult
    func markEstimateSent(
        id: String,
        from expectedStatus: JobStatus,
        on date: Date = .now
    ) -> Bool {
        guard expectedStatus == .lead else { return false }
        guard stampEstimateSent(id: id, from: expectedStatus, on: date) else { return false }
        // Task 11.08: RN `SendEstimateScreen.markAsSent` / `PricingCalculatorScreen`.
        emitAnalytics(.estimateSent)
        onAppRatingWin?(.estimateSent)
        return true
    }

    /// Records only a composer-confirmed send. The latest canonical estimate
    /// is compared with the reviewed customer-facing snapshot before stamping,
    /// so a delayed composer callback cannot claim that newer pricing was sent.
    /// Cancelled, saved, and failed composer outcomes never call this method.
    func recordEstimateDelivery(
        for review: NativeEstimateReviewDraft,
        on date: Date = .now
    ) -> NativeEstimateDeliveryRecordOutcome {
        guard [.lead, .estimateSent].contains(review.expectedStatus),
              ensurePersistenceWritable(),
              let currentJob = snapshot.payload.jobs?.first(where: { $0.id == review.jobID }),
              let currentStatus = JobStatus(rawValue: currentJob.status)
        else { return .preservedNewerState }

        let allowedCurrentStatus = switch (review.expectedStatus, currentStatus) {
        case (.lead, .lead), (.lead, .estimateSent), (.estimateSent, .estimateSent): true
        default: false
        }
        guard allowedCurrentStatus else { return .preservedNewerState }

        let currentCustomer = NativeCustomerIdentity.resolve(
            customers: customers,
            customerID: currentJob.customerId,
            customerName: currentJob.customerName
        )
        let currentReviewSnapshot: Canonical.EstimateApprovalSnapshot
        do {
            currentReviewSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
                job: currentJob,
                customerName: currentCustomer?.name,
                businessName: settings.businessName
            )
        } catch {
            return .preservedNewerState
        }
        guard CanonicalUIAdapters.estimateApprovalSnapshotsMatch(
            currentReviewSnapshot,
            review.snapshot
        ) else { return .preservedNewerState }

        guard stampEstimateSent(id: review.jobID, from: currentStatus, on: date) else { return .failed }
        // Task 11.08: the composer-confirmed stamp is native's estimate-sent
        // commit (contract §9.7).
        emitAnalytics(.estimateSent)
        onAppRatingWin?(.estimateSent)
        return .recorded
    }

    private func stampEstimateSent(
        id: String,
        from expectedStatus: JobStatus,
        on date: Date
    ) -> Bool {
        guard [.lead, .estimateSent].contains(expectedStatus), ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records[index].status == expectedStatus.rawValue
            else {
                migrationMessage = "The job changed while this estimate was open. Review it again before marking it sent."
                return false
            }
            records[index].status = JobStatus.estimateSent.rawValue
            records[index].estimateSentAt = date.dateOnlyString
            let result = records[index]
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "jobs", recordId: id, record: result)
            return true
        } catch {
            migrationMessage = "The estimate could not be marked sent. Nothing was changed."
            return false
        }
    }

    /// Syncs the locally stamped estimate first, then asks the trusted backend
    /// to mint/refresh its approval capability. Exact verified owner state is
    /// checked before and after every await; the device never supplies a user ID.
    func createEstimateApprovalLink(
        for review: NativeEstimateReviewDraft,
        on date: Date = .now
    ) async -> NativeEstimateApprovalLinkOutcome {
        guard let subject = authenticatedUserSubject,
              let binding = verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              [.lead, .estimateSent].contains(review.expectedStatus)
        else { return .failure(.rejectedSession) }
        guard let service = configuredEstimateApprovalLinkService() else {
            return .failure(.invalidConfiguration)
        }

        guard stampEstimateSent(
            id: review.jobID,
            from: review.expectedStatus,
            on: date
        ) else { return .failure(.jobNotSynced) }

        guard await syncNowAndWait(trigger: .manual) != nil else {
            return .failure(.jobNotSynced)
        }
        guard subject == authenticatedUserSubject,
              binding == verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              syncStatus.lastPullResult?.state == .completed,
              !mutationQueue.load().contains(where: {
                  $0.table == "jobs" && $0.recordId == review.jobID
              })
        else { return .failure(.jobNotSynced) }

        // The push is followed by an authoritative pull. Rebuild from that
        // fresh canonical state before minting so another device's pricing,
        // customer, or business-profile edit cannot be hidden behind the
        // already-open review sheet.
        guard let currentJob = snapshot.payload.jobs?.first(where: { $0.id == review.jobID }),
              currentJob.status == JobStatus.estimateSent.rawValue
        else { return .failure(.estimateChanged) }
        let currentCustomer = NativeCustomerIdentity.resolve(
            customers: customers,
            customerID: currentJob.customerId,
            customerName: currentJob.customerName
        )
        let currentApprovalSnapshot: Canonical.EstimateApprovalSnapshot
        do {
            currentApprovalSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
                job: currentJob,
                customerName: currentCustomer?.name,
                businessName: settings.businessName
            )
        } catch {
            return .failure(.estimateChanged)
        }
        guard CanonicalUIAdapters.estimateApprovalSnapshotsMatch(
            currentApprovalSnapshot,
            review.snapshot
        ) else { return .failure(.estimateChanged) }

        func request(_ credentials: NativeSyncCredentials) async throws -> NativeEstimateApprovalLink {
            try await service.createLink(
                jobID: review.jobID,
                snapshot: review.snapshot,
                sessionBytes: credentials.sessionBytes
            )
        }

        let link: NativeEstimateApprovalLink
        do {
            guard let credentials = currentSyncCredentials(), credentials.subject == subject else {
                return .failure(.malformedSession)
            }
            do {
                link = try await request(credentials)
            } catch NativeEstimateApprovalLinkError.rejectedSession {
                guard await refreshSyncSession(),
                      let fresh = currentSyncCredentials(),
                      fresh.subject == subject,
                      subject == authenticatedUserSubject
                else { return .failure(.rejectedSession) }
                link = try await request(fresh)
            }
        } catch let error as NativeEstimateApprovalLinkError {
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }

        guard subject == authenticatedUserSubject,
              binding == verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              ensurePersistenceWritable()
        else { return .failure(.rejectedSession) }
        do {
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            guard let index = records.firstIndex(where: { $0.id == review.jobID }),
                  records[index].status == JobStatus.estimateSent.rawValue
            else { return .failure(.estimateChanged) }
            records[index].approval = try CanonicalUIAdapters.estimateApprovalAfterLink(
                existing: records[index].approval,
                snapshot: review.snapshot,
                token: link.token,
                sentAt: link.sentAt
            )
            let result = records[index]
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "jobs", recordId: review.jobID, record: result)
            // Task 11.08: RN `SendEstimateScreen.createLink` success.
            emitAnalytics(.estimateSent)
            onAppRatingWin?(.estimateSent)
            _ = await syncNowAndWait(trigger: .localChange)
            return .success(link)
        } catch {
            return .failure(.invalidResponse)
        }
    }

    /// Frozen customer-facing snapshot for ONE change order, taken when the
    /// review opens. The draft carries the exact snapshot the link must mint
    /// so the sync-before-mint round trip can prove the order did not move.
    func changeOrderApprovalDraft(jobID: String, changeOrderID: String) -> NativeChangeOrderApprovalDraft? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              let order = (job.changeOrders ?? []).first(where: { $0.id == changeOrderID }),
              NativeChangeOrderStatus.isApprovalEligible(order)
        else { return nil }
        let customer = NativeCustomerIdentity.resolve(
            customers: customers,
            customerID: job.customerId,
            customerName: job.customerName
        )
        guard let frozen = try? NativeChangeOrderApprovalSnapshot.build(
            order: order,
            job: job,
            customerName: customer?.name,
            businessName: settings.businessName
        ) else { return nil }
        return NativeChangeOrderApprovalDraft(jobID: jobID, changeOrderID: changeOrderID, snapshot: frozen)
    }

    /// Syncs the locally saved change order first, then asks the trusted
    /// backend to mint/refresh its approval capability for public
    /// `change.html`. Exact verified owner state is checked before and after
    /// every await; the device never supplies a user ID. The frozen snapshot
    /// is rebuilt from the authoritative post-sync record and must equal the
    /// review draft exactly, or the mint fails closed as stale. Only the
    /// server token/sentAt/snapshot are mirrored into the exact pending CO;
    /// server decision/signature fields and unknown forward-compatible fields
    /// survive via `NativeChangeOrderApprovalMirror`.
    func createChangeOrderApprovalLink(
        for draft: NativeChangeOrderApprovalDraft
    ) async -> NativeChangeOrderApprovalLinkOutcome {
        guard let subject = authenticatedUserSubject,
              let binding = verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding)
        else { return .failure(.rejectedSession) }
        guard let service = configuredChangeOrderApprovalLinkService() else {
            return .failure(.invalidConfiguration)
        }

        guard await syncNowAndWait(trigger: .manual) != nil else {
            return .failure(.jobNotSynced)
        }
        guard subject == authenticatedUserSubject,
              binding == verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              syncStatus.lastPullResult?.state == .completed,
              !mutationQueue.load().contains(where: {
                  $0.table == "jobs" && $0.recordId == draft.jobID
              })
        else { return .failure(.jobNotSynced) }

        // Authoritative post-sync state: the exact job AND the exact pending
        // order must still exist, and the frozen snapshot must equal the
        // review draft — another device's edit, an on-site decision, or a
        // cancellation fails closed here, never behind a stale link.
        guard let currentJob = snapshot.payload.jobs?.first(where: { $0.id == draft.jobID }),
              let currentOrder = (currentJob.changeOrders ?? []).first(where: { $0.id == draft.changeOrderID }),
              (currentOrder.cancelledAt ?? "").isEmpty
        else { return .failure(.changeOrderStale) }
        // A decision that landed while the review was open is terminal: the
        // backend would 409, and the review must not silently re-mint over it.
        if currentOrder.manualDecision != nil || currentOrder.approval?.decision != nil {
            return .failure(.alreadyDecided)
        }
        let currentCustomer = NativeCustomerIdentity.resolve(
            customers: customers,
            customerID: currentJob.customerId,
            customerName: currentJob.customerName
        )
        guard let currentSnapshot = try? NativeChangeOrderApprovalSnapshot.build(
            order: currentOrder,
            job: currentJob,
            customerName: currentCustomer?.name,
            businessName: settings.businessName
        ), CanonicalUIAdapters.estimateApprovalSnapshotsMatch(currentSnapshot, draft.snapshot)
        else { return .failure(.changeOrderStale) }

        func request(_ credentials: NativeSyncCredentials) async throws -> NativeChangeOrderApprovalLink {
            try await service.createLink(
                jobID: draft.jobID,
                changeOrderID: draft.changeOrderID,
                snapshot: draft.snapshot,
                sessionBytes: credentials.sessionBytes
            )
        }

        let link: NativeChangeOrderApprovalLink
        do {
            guard let credentials = currentSyncCredentials(), credentials.subject == subject else {
                return .failure(.malformedSession)
            }
            do {
                link = try await request(credentials)
            } catch NativeChangeOrderApprovalLinkError.rejectedSession {
                guard await refreshSyncSession(),
                      let fresh = currentSyncCredentials(),
                      fresh.subject == subject,
                      subject == authenticatedUserSubject
                else { return .failure(.rejectedSession) }
                link = try await request(fresh)
            }
        } catch let error as NativeChangeOrderApprovalLinkError {
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }

        // Owner-switch mid-await: the account that minted is not the account
        // holding the device now — never mirror another owner's capability.
        guard subject == authenticatedUserSubject,
              binding == verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              ensurePersistenceWritable()
        else { return .failure(.rejectedSession) }
        do {
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            guard let index = records.firstIndex(where: { $0.id == draft.jobID }) else {
                return .failure(.changeOrderStale)
            }
            records[index] = try NativeChangeOrderApprovalMirror.apply(
                to: records[index],
                changeOrderID: draft.changeOrderID,
                token: link.token,
                sentAt: link.sentAt,
                snapshot: draft.snapshot
            )
            let result = records[index]
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "jobs", recordId: draft.jobID, record: result)
            _ = await syncNowAndWait(trigger: .localChange)
            return .success(link)
        } catch let error as NativeChangeOrderApprovalLinkError {
            return .failure(error)
        } catch {
            return .failure(.invalidResponse)
        }
    }

    /// Re-resolves the current canonical job at commit time and replaces only
    /// calculator-owned fields, so unrelated sync changes that arrived while
    /// the sheet was open survive the save.
    @discardableResult
    func saveJobPricing(_ pricing: NativeJobPricingDraft) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            guard let baseline = records.first(where: { $0.id == pricing.jobID }) else {
                migrationMessage = "The job no longer exists. Pricing was not saved."
                return false
            }
            let result = try CanonicalUIAdapters.canonical(from: pricing, baseline: baseline)
            replaceOrAppend(result, in: &records, id: \Canonical.Job.id)
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "jobs", recordId: result.id, record: result)
            return true
        } catch {
            migrationMessage = "Could not save job pricing: \(error.localizedDescription)"
            return false
        }
    }

    /// Canonical read model for the change-order section. Callers receive a
    /// value copy, so an open sheet cannot mutate or later overwrite the
    /// snapshot without going back through the ID-based commit methods below.
    func changeOrders(for jobID: String) -> [Canonical.ChangeOrder] {
        snapshot.payload.jobs?.first(where: { $0.id == jobID })?.changeOrders ?? []
    }

    /// Per-job estimated-vs-actual profitability, projected from the canonical
    /// job plus its linked invoices/expenses and `settings.laborCostRate`.
    /// Nil when the job is gone. Math lives in `JobProfitabilityEngine`;
    /// `NativeJobProfitability` only resolves the canonical inputs, so an
    /// unknown stays nil (with its warning) instead of a fake zero.
    func jobProfitability(jobID: String) -> JobProfitability? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        return NativeJobProfitability.calculate(
            job: job,
            invoices: snapshot.payload.invoices ?? [],
            expenses: snapshot.payload.expenses ?? [],
            laborCostRate: snapshot.payload.settings?.laborCostRate
        )
    }

    /// Job-detail "Estimate vs actual" card read model. Nil when the job is
    /// gone or the card stays hidden (pre-estimate or pre-in-progress work
    /// has nothing to compare yet).
    func jobProfitabilitySection(jobID: String) -> NativeJobProfitabilitySectionState? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        return NativeJobProfitability.sectionState(
            job: job,
            invoices: snapshot.payload.invoices ?? [],
            expenses: snapshot.payload.expenses ?? [],
            laborCostRate: snapshot.payload.settings?.laborCostRate
        )
    }

    /// Adds against the job's current canonical status and total, then saves
    /// the whole job locally before replacing its last-writer-wins queue item.
    @discardableResult
    func createChangeOrder(
        jobID: String,
        title: String,
        description: String,
        amountText: String,
        on date: Date = .now
    ) -> String? {
        let orderID = Self.changeOrderIDGenerator.changeOrderID()
        let saved = mutateChangeOrderJob(jobID: jobID) { job in
            try NativeChangeOrders.adding(
                to: job,
                id: orderID,
                title: title,
                description: description,
                amountText: amountText,
                createdAt: NativeChangeOrders.recordDateString(for: date)
            )
        }
        return saved ? orderID : nil
    }

    /// Editing is pending-only and re-resolves both job and order by ID at the
    /// commit boundary, preserving a link or decision that arrived meanwhile.
    @discardableResult
    func updateChangeOrder(
        jobID: String,
        changeOrderID: String,
        title: String,
        description: String,
        amountText: String
    ) -> Bool {
        mutateChangeOrderJob(jobID: jobID) { job in
            try NativeChangeOrders.editing(
                changeOrderID,
                in: job,
                title: title,
                description: description,
                amountText: amountText
            )
        }
    }

    @discardableResult
    func recordManualChangeOrderDecision(
        jobID: String,
        changeOrderID: String,
        decision: NativeChangeOrderManualDecision,
        note: String,
        on date: Date = .now
    ) -> Bool {
        let applied = mutateChangeOrderJob(jobID: jobID) { job in
            try NativeChangeOrders.applyingManualDecision(
                decision,
                to: changeOrderID,
                in: job,
                note: note,
                decidedAt: NativeChangeOrders.recordDateString(for: date)
            )
        }
        // Task 11.08: RN `ChangeOrdersSection.tsx:176`, when it changed.
        if applied { emitAnalytics(.changeOrderDecided(decision)) }
        return applied
    }

    @discardableResult
    func cancelChangeOrder(
        jobID: String,
        changeOrderID: String,
        on date: Date = .now
    ) -> Bool {
        mutateChangeOrderJob(jobID: jobID) { job in
            try NativeChangeOrders.cancelling(
                changeOrderID,
                in: job,
                cancelledAt: NativeChangeOrders.recordDateString(for: date)
            )
        }
    }

    @discardableResult
    func deletePendingChangeOrder(jobID: String, changeOrderID: String) -> Bool {
        mutateChangeOrderJob(jobID: jobID) { job in
            try NativeChangeOrders.deletingPending(changeOrderID, in: job)
        }
    }

    // MARK: - Time tracking

    /// Job-detail timer read model, projected from the canonical job exactly as
    /// `computeTimeTracking` reads `job.timeSessions`. Nil when the job is gone.
    func timeTrackingSummary(jobID: String, now: Date = .now) -> NativeTimeTrackingSummary? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        return NativeTimeTracking.summary(
            sessions: Self.sessionMirrors(of: job),
            estimatedHours: job.laborHours,
            now: now
        )
    }

    /// Starts a timer. A job still sitting at `.scheduled` advances to its
    /// shared next status, never a hardcoded one. Refuses when a session is
    /// already running, so a replayed widget/Siri clock-in cannot double-start.
    @discardableResult
    func clockIn(jobID: String, on date: Date = .now) -> Bool {
        let started = mutateJob(jobID: jobID) { job in
            guard let status = JobLifecycleStatus(rawValue: job.status) else {
                throw NativeTimeTrackingError.jobNotFound
            }
            guard let applied = NativeTimeTracking.clockIn(
                sessions: Self.sessionMirrors(of: job),
                status: status,
                at: NativeTimeTracking.timestamp(date)
            ) else { throw NativeTimeTrackingError.sessionAlreadyRunning }
            var updated = job
            updated.status = applied.status.rawValue
            // Append only: every existing session keeps its preservation fields.
            updated.timeSessions = (job.timeSessions ?? [])
                + [.init(start: applied.sessions[applied.sessions.count - 1].start)]
            return updated
        }
        // Task 11.08: RN `JobDetailScreen.tsx:1036`.
        if started { emitAnalytics(.timeTrackingStarted(jobID: jobID)) }
        return started
    }

    /// Closes the running timer. The end time clamps to the session start when
    /// the device clock or a replayed action would otherwise create a negative
    /// duration, and only the last open session is touched.
    @discardableResult
    func clockOut(jobID: String, on date: Date = .now) -> Bool {
        mutateJob(jobID: jobID) { job in
            guard let closed = NativeTimeTracking.clockOut(
                sessions: Self.sessionMirrors(of: job),
                at: NativeTimeTracking.timestamp(date)
            ), let clampEnd = closed.last?.end else { throw NativeTimeTrackingError.noRunningSession }
            var updated = job
            guard var sessions = updated.timeSessions, let last = sessions.indices.last,
                  sessions[last].end == nil
            else { throw NativeTimeTrackingError.noRunningSession }
            sessions[last].end = clampEnd
            updated.timeSessions = sessions
            return updated
        }
    }

    /// Read-only mirror of a job's canonical sessions for the pure rules.
    private static func sessionMirrors(of job: Canonical.Job) -> [NativeTimeSession] {
        (job.timeSessions ?? []).map { NativeTimeSession(start: $0.start, end: $0.end) }
    }

    /// The job-detail change-order section read model, projected from the
    /// canonical job the same way `ChangeOrdersSection` reads `job.changeOrders`.
    func changeOrderSectionState(jobID: String) -> NativeChangeOrderSectionState? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        return NativeChangeOrders.sectionState(
            jobID: job.id,
            status: job.status,
            changeOrders: job.changeOrders ?? []
        )
    }

    /// Editor draft for a new or still-pending change order. `AddChangeOrderScreen`
    /// alerts and closes on these same conditions at mount; returning the typed
    /// refusal keeps the sheet from opening a form that cannot save.
    func changeOrderDraft(
        jobID: String,
        changeOrderID: String? = nil
    ) -> Result<NativeChangeOrderDraft, NativeChangeOrderError> {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else {
            return .failure(.jobNotFound)
        }
        guard let changeOrderID else {
            guard NativeChangeOrders.canAdd(to: job.status) else { return .failure(.jobNotEligible) }
            return .success(.init(
                jobID: job.id,
                editingID: nil,
                title: "",
                description: "",
                amountText: ""
            ))
        }
        guard let order = (job.changeOrders ?? []).first(where: { $0.id == changeOrderID }) else {
            return .failure(.changeOrderNotFound)
        }
        guard NativeChangeOrders.status(of: order) == .pending else {
            return .failure(.changeOrderNotPending)
        }
        return .success(.init(
            jobID: job.id,
            editingID: order.id,
            title: order.title,
            description: order.description ?? "",
            amountText: NSDecimalNumber(decimal: order.amount).stringValue
        ))
    }

    /// Commits an editor draft through the same local-first transaction as the
    /// targeted APIs, but reports the exact refusal so the sheet can explain
    /// itself without a second validation model. Nothing is written when the
    /// job or the order moved on while the form was open.
    func commitChangeOrder(_ draft: NativeChangeOrderDraft) -> NativeChangeOrderCommitOutcome {
        let outcome = performChangeOrderCommit(draft)
        // Task 11.08: RN `AddChangeOrderScreen.tsx:118`, new orders only; the
        // amount is the committed canonical value.
        if case .created(let id) = outcome,
           let order = snapshot.payload.jobs?.first(where: { $0.id == draft.jobID })?
               .changeOrders?.first(where: { $0.id == id }) {
            emitAnalytics(.changeOrderCreated(amount: order.amount))
        }
        return outcome
    }

    private func performChangeOrderCommit(_ draft: NativeChangeOrderDraft) -> NativeChangeOrderCommitOutcome {
        let outcome: Result<NativeChangeOrderCommitOutcome, Error>
        if let editingID = draft.editingID {
            outcome = Result {
                try performJobMutation(jobID: draft.jobID) { job in
                    try NativeChangeOrders.editing(
                        editingID,
                        in: job,
                        title: draft.title,
                        description: draft.description,
                        amountText: draft.amountText
                    )
                }
            }.map { .updated }
        } else {
            let orderID = Self.changeOrderIDGenerator.changeOrderID()
            outcome = Result {
                try performJobMutation(jobID: draft.jobID) { job in
                    try NativeChangeOrders.adding(
                        to: job,
                        id: orderID,
                        title: draft.title,
                        description: draft.description,
                        amountText: draft.amountText,
                        createdAt: NativeChangeOrders.recordDateString(for: .now)
                    )
                }
            }.map { .created(id: orderID) }
        }
        switch outcome {
        case let .success(committed):
            return committed
        case let .failure(error):
            return (error as? NativeChangeOrderError).map(NativeChangeOrderCommitOutcome.refused)
                ?? .failed(Self.jobMutationFailureMessage(error, generic: "Could not update the change order"))
        }
    }

    /// Every job-scoped mutation — change orders, timers — funnels through one
    /// local-first transaction. MainActor serialization plus a fresh snapshot
    /// lookup gives each action an exact stale-state guard without a separate
    /// UI revision counter.
    private func performJobMutation(
        jobID: String,
        transform: (Canonical.Job) throws -> Canonical.Job
    ) throws {
        guard ensurePersistenceWritable() else {
            throw NativeJobMutationWriteFailure(message: Self.persistenceReadOnlyMessage)
        }
        var updated = snapshot
        var records = updated.payload.jobs ?? []
        guard let index = records.firstIndex(where: { $0.id == jobID }) else {
            throw NativeChangeOrderError.jobNotFound
        }
        let result = try transform(records[index])
        records[index] = result
        updated.payload.jobs = records
        try repository.save(updated)
        try apply(updated)
        enqueueUpsert(table: "jobs", recordId: result.id, record: result)
    }

    @discardableResult
    private func mutateChangeOrderJob(
        jobID: String,
        transform: (Canonical.Job) throws -> Canonical.Job
    ) -> Bool {
        do {
            try performJobMutation(jobID: jobID, transform: transform)
            return true
        } catch {
            migrationMessage = Self.jobMutationFailureMessage(
                error, generic: "Could not update the change order"
            )
            return false
        }
    }

    @discardableResult
    private func mutateJob(
        jobID: String,
        transform: (Canonical.Job) throws -> Canonical.Job
    ) -> Bool {
        do {
            try performJobMutation(jobID: jobID, transform: transform)
            return true
        } catch {
            migrationMessage = Self.jobMutationFailureMessage(
                error, generic: "Could not update the job"
            )
            return false
        }
    }

    /// The bounded, user-safe message a failed job mutation publishes through
    /// `migrationMessage`. Typed refusals explain themselves and are never
    /// prefixed; the generic case keeps each caller's historical wording.
    private static func jobMutationFailureMessage(_ error: Error, generic: String) -> String {
        switch error {
        case let typed as NativeChangeOrderError:
            typed.localizedDescription
        case let typed as NativeTimeTrackingError:
            typed.localizedDescription
        case let write as NativeJobMutationWriteFailure:
            write.message
        default:
            "\(generic): \(error.localizedDescription)"
        }
    }

    private func persistJob(_ value: Job, newRecordTemplate: Canonical.Job?) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            let result: Canonical.Job
            if let baseline = records.first(where: { $0.id == value.id }) {
                guard newRecordTemplate == nil else {
                    migrationMessage = "A job with this duplicate's ID already exists. Nothing was overwritten."
                    return false
                }
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = value
                result = try CanonicalUIAdapters.canonical(from: edit)
            } else if let template = newRecordTemplate {
                var edit = try CanonicalUIAdapters.edit(template); edit.value = value
                result = try CanonicalUIAdapters.canonical(from: edit)
            } else {
                result = try CanonicalUIAdapters.canonical(from: value)
            }
            // Task 11.08: RN `job_created` (AddJobScreen.tsx:400) fires for a
            // new record only; `first` counts prior non-sample jobs.
            let isNewRecord = !records.contains(where: { $0.id == result.id })
            let isFirstRealJob = !records.contains(where: { !Self.isAnalyticsSampleID($0.id) })
            replaceOrAppend(result, in: &records, id: \Canonical.Job.id)
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "jobs", recordId: result.id, record: result)
            if isNewRecord {
                emitAnalytics(.jobCreated(
                    first: isFirstRealJob,
                    customerID: result.customerId,
                    duplicated: newRecordTemplate != nil
                ))
            }
            return true
        } catch {
            migrationMessage = "Could not update job: \(error.localizedDescription)"
            return false
        }
    }

    func upsert(_ value: Invoice) {
        guard ensurePersistenceWritable() else { return }
        do {
            var records = snapshot.payload.invoices ?? []
            let result: Canonical.Invoice
            if let baseline = records.first(where: { $0.id == value.id }) {
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = value
                result = try CanonicalUIAdapters.canonical(from: edit)
            } else { result = try CanonicalUIAdapters.canonical(from: value) }
            replaceOrAppend(result, in: &records, id: \Canonical.Invoice.id)
            // P12-008: saved before it is queued; a failed save changes nothing.
            var next = snapshot
            next.payload.invoices = records
            try commitSnapshot(next)
            enqueueUpsert(table: "invoices", recordId: result.id, record: result)
        } catch { migrationMessage = "Could not update invoice: \(error.localizedDescription)" }
    }

    /// Phase 7 typed invoice create/edit commit. The editor owns only its
    /// scalar fields; payments, job/recurrence linkage, delivery metadata,
    /// import markers and unknown fields are preserved from the latest
    /// canonical baseline, so a webhook payment that lands while the editor
    /// is open is retained. Reports success only after durable persistence;
    /// callers must keep the draft visible on failure.
    ///
    /// - `id`: nil creates a new invoice; otherwise the record must exist.
    /// - `opened`: the editor's copy at open time; scalar drift underneath
    ///   (another device editing the same fields) fails closed.
    func commitInvoiceEdit(
        id: String?,
        opened: Invoice?,
        draft: NativeInvoiceDraft,
        calendar: Calendar = .current
    ) -> Result<Invoice, NativeInvoiceEditRefusal> {
        let result = performInvoiceEdit(id: id, opened: opened, draft: draft, calendar: calendar)
        // Task 11.08: RN `AddInvoiceScreen.tsx:109`, new invoices only.
        if case .success = result, id == nil { emitAnalytics(.invoiceCreatedManually) }
        return result
    }

    private func performInvoiceEdit(
        id: String?,
        opened: Invoice?,
        draft: NativeInvoiceDraft,
        calendar: Calendar
    ) -> Result<Invoice, NativeInvoiceEditRefusal> {
        guard ensurePersistenceWritable() else { return .failure(.persistenceUnavailable) }
        var records = snapshot.payload.invoices ?? []
        if let id {
            guard let baseline = records.first(where: { $0.id == id }) else {
                return .failure(.missingRecord)
            }
            guard let current = try? CanonicalUIAdapters.invoice(from: baseline, calendar: calendar) else {
                return .failure(.persistenceUnavailable)
            }
            let conflict = opened.map {
                Self.invoiceEditorScalarsChanged(between: $0, and: current, calendar: calendar)
            } ?? false
            let decision = NativeInvoiceEditing.commit(
                draft, baselineExists: true, baselineChangedSinceOpened: conflict,
                resolveNumber: nextInvoiceNumber())
            guard case .success(let validated) = decision else {
                if case .failure(let refusal) = decision { return .failure(refusal) }
                return .failure(.invalidDraft([]))
            }
            var merged = current
            merged.customerId = validated.customerId
            merged.customer = validated.customer
            merged.number = validated.number
            merged.amount = validated.amount
            merged.due = NativeInvoiceEditing.date(fromDayString: validated.due, calendar: calendar) ?? current.due
            merged.email = validated.email
            merged.phone = validated.phone
            merged.description = validated.description
            do {
                var edit = try CanonicalUIAdapters.edit(baseline)
                edit.value = merged
                var result = try CanonicalUIAdapters.canonical(from: edit)
                Self.reconcileInvoicePaidFields(&result)
                replaceOrAppend(result, in: &records, id: \Canonical.Invoice.id)
                // P12-008: a failed save changes nothing in memory.
                var next = snapshot
                next.payload.invoices = records
                try commitSnapshot(next)
                enqueueUpsert(table: "invoices", recordId: result.id, record: result)
                guard let published = try? CanonicalUIAdapters.invoice(from: result, calendar: calendar) else {
                    return .failure(.persistenceUnavailable)
                }
                return .success(published)
            } catch {
                migrationMessage = "Could not update invoice: \(error.localizedDescription)"
                return .failure(.persistenceUnavailable)
            }
        }
        let decision = NativeInvoiceEditing.commit(
            draft, baselineExists: true, baselineChangedSinceOpened: false,
            resolveNumber: nextInvoiceNumber())
        guard case .success(let validated) = decision else {
            if case .failure(let refusal) = decision { return .failure(refusal) }
            return .failure(.invalidDraft([]))
        }
        // The default `Invoice()` id mints through the same generator as every
        // other manual invoice; a collision fails closed instead of overwriting.
        var value = Invoice()
        guard !records.contains(where: { $0.id == value.id }) else { return .failure(.conflictingRecord) }
        value.customerId = validated.customerId
        value.customer = validated.customer
        value.number = validated.number
        value.amount = validated.amount
        value.due = NativeInvoiceEditing.date(fromDayString: validated.due, calendar: calendar) ?? Date()
        value.email = validated.email
        value.phone = validated.phone
        value.description = validated.description
        do {
            var result = try CanonicalUIAdapters.canonical(from: value)
            Self.reconcileInvoicePaidFields(&result)
            records.append(result)
            // P12-008: a failed save leaves no phantom invoice in memory (a
            // retry would otherwise add a second one with the same number).
            var next = snapshot
            next.payload.invoices = records
            try commitSnapshot(next)
            enqueueUpsert(table: "invoices", recordId: result.id, record: result)
            guard let published = try? CanonicalUIAdapters.invoice(from: result, calendar: calendar) else {
                return .failure(.persistenceUnavailable)
            }
            // Contextual permission ask (task 10.05, N1): a brand-new invoice
            // (never an edit — this branch only runs when `id == nil`) is the
            // moment overdue reminders become concretely useful, mirroring RN's
            // `promptForInvoiceReminders()` call in `AddInvoiceScreen.tsx`.
            // Fire-and-forget, exactly like the RN call site.
            onInvoiceCreatedContextualPrompt?()
            return .success(published)
        } catch {
            migrationMessage = "Could not update invoice: \(error.localizedDescription)"
            return .failure(.persistenceUnavailable)
        }
    }

    /// Editor-owned scalar drift check: payments, delivery metadata and other
    /// non-editor state are merged, never conflicts.
    private static func invoiceEditorScalarsChanged(between opened: Invoice, and current: Invoice, calendar: Calendar) -> Bool {
        opened.customerId != current.customerId
            || opened.customer != current.customer
            || opened.number != current.number
            || opened.amount != current.amount
            || NativeInvoiceEditing.dayString(opened.due, calendar: calendar)
                != NativeInvoiceEditing.dayString(current.due, calendar: calendar)
            || opened.email != current.email
            || opened.phone != current.phone
            || opened.description != current.description
    }

    /// Re-derive stored `paid`/`paidAt` from the ledger (RN `reconcilePaidFields`
    /// parity for amount edits); method detail is irrelevant here so every
    /// payment maps to `.other`, matching the delivery path precedent.
    private static func reconcileInvoicePaidFields(_ record: inout Canonical.Invoice) {
        let ledger = LedgerInvoice(
            id: record.id, amount: record.amount, due: record.due, paid: record.paid,
            paidAt: record.paidAt,
            payments: record.payments?.map {
                LedgerPayment(id: $0.id, amount: $0.amount, date: $0.date, method: .other, note: $0.note, voidedAt: $0.voidedAt)
            },
            depositRequest: nil)
        let reconciled = PaymentLedger.reconcilePaidFields(ledger)
        record.paid = reconciled.paid
        record.paidAt = reconciled.paidAt
    }

    func upsert(_ value: Expense) {
        guard ensurePersistenceWritable() else { return }
        do {
            var records = snapshot.payload.expenses ?? []
            let result: Canonical.Expense
            if let baseline = records.first(where: { $0.id == value.id }) {
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = value
                result = try CanonicalUIAdapters.canonical(from: edit)
            } else { result = try CanonicalUIAdapters.canonical(from: value) }
            replaceOrAppend(result, in: &records, id: \Canonical.Expense.id)
            // P12-008: saved before it is queued; a failed save changes nothing.
            var next = snapshot
            next.payload.expenses = records
            try commitSnapshot(next)
            enqueueUpsert(table: "expenses", recordId: result.id, record: result)
        } catch { migrationMessage = "Could not update expense: \(error.localizedDescription)" }
    }

    // MARK: - Recurring jobs

    private static let recurringJobIDGenerator = LocalIDGenerator()

    /// The stored recurrence rules. There is no UI-model projection yet (the
    /// Batch 2 manager owns that); mutations here work on canonical records
    /// directly, exactly as the sync merge does.
    var recurringJobRules: [Canonical.RecurringJob] {
        snapshot.payload.recurringJobs ?? []
    }

    func recurringRule(forJobID jobID: String) -> Canonical.RecurringJob? {
        guard let recurringID = snapshot.payload.jobs?.first(where: { $0.id == jobID })?.recurringJobId else { return nil }
        return recurringJobRules.first(where: { $0.id == recurringID })
    }

    func latestGeneratedJob(forRecurringID recurringID: String) -> Job? {
        guard let record = snapshot.payload.jobs?.last(where: { $0.recurringJobId == recurringID }) else { return nil }
        return try? CanonicalUIAdapters.job(from: record)
    }

    func recurringJobDraft(
        from jobID: String,
        cadence: RecurrenceCadence = .monthly,
        endCondition: RecurrenceEndCondition = .never,
        endCount: Int? = nil,
        endDate: String? = nil
    ) -> Canonical.RecurringJob? {
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { return nil }
        let start = job.scheduledDate ?? NativeRecurringJobs.todayString()
        do {
            return try CanonicalUIAdapters.recurringJob(
                from: job,
                id: "rj_\(Date().timeIntervalSince1970)",
                startDate: start,
                cadence: cadence,
                endCondition: endCondition,
                endCount: endCount,
                endDate: endDate,
                createdAt: NativeRecurringJobs.todayString()
            )
        } catch {
            migrationMessage = "This job could not be prepared for repeating."
            return nil
        }
    }

    /// Creates a recurrence rule. The id must be fresh: a retry or replay
    /// carrying an already-stored id is refused rather than duplicated.
    @discardableResult
    func createRecurringJob(_ rule: Canonical.RecurringJob) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        guard !(snapshot.payload.recurringJobs ?? []).contains(where: { $0.id == rule.id }) else {
            migrationMessage = "That recurring series already exists. Nothing was saved."
            return false
        }
        do {
            var updated = snapshot
            var records = updated.payload.recurringJobs ?? []
            records.append(rule)
            updated.payload.recurringJobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringJobs", recordId: rule.id, record: rule)
            return true
        } catch {
            migrationMessage = "Could not save this recurring series: \(error.localizedDescription)"
            return false
        }
    }

    /// Replaces a rule wholesale. The fresh canonical record is resolved by
    /// id first, so an update for a rule a sync pull just removed fails
    /// instead of resurrecting it.
    @discardableResult
    func updateRecurringJob(_ rule: Canonical.RecurringJob) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringJobs ?? []
            guard let index = records.firstIndex(where: { $0.id == rule.id }) else {
                migrationMessage = "That recurring series could not be found. Nothing was saved."
                return false
            }
            records[index] = rule
            updated.payload.recurringJobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringJobs", recordId: rule.id, record: rule)
            return true
        } catch {
            migrationMessage = "Could not save this recurring series: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes a rule. Generated occurrences stay untouched — they are
    /// ordinary jobs once created, matching the RN cancel-series behavior.
    @discardableResult
    func deleteRecurringJob(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringJobs ?? []
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            records.remove(at: index)
            updated.payload.recurringJobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueDelete(table: "recurringJobs", recordId: id)
            return true
        } catch {
            migrationMessage = "The recurring series could not be deleted safely. Nothing was changed."
            return false
        }
    }

    /// Pauses a rule against the fresh canonical record. Paused rules
    /// generate nothing until resumed; already-paused is a no-op success.
    @discardableResult
    func pauseRecurringJob(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringJobs ?? []
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            guard records[index].isActive else { return true }
            records[index].isActive = false
            let result = records[index]
            updated.payload.recurringJobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringJobs", recordId: result.id, record: result)
            return true
        } catch {
            migrationMessage = "The recurring series could not be paused. Nothing was changed."
            return false
        }
    }

    /// Resumes a paused rule against the fresh canonical record. Elapsed due
    /// dates generate on the next generation pass (catch-up), mirroring the
    /// RN engine which keys off `nextDueDate <= today`.
    @discardableResult
    func resumeRecurringJob(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringJobs ?? []
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            guard !records[index].isActive else { return true }
            records[index].isActive = true
            let result = records[index]
            updated.payload.recurringJobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringJobs", recordId: result.id, record: result)
            return true
        } catch {
            migrationMessage = "The recurring series could not be resumed. Nothing was changed."
            return false
        }
    }

    /// Runs the pure `NativeRecurringJobs` generator over the current
    /// snapshot and commits the result atomically: generated jobs plus
    /// updated rules persist in one snapshot write, then each new job and
    /// each changed rule is queued for sync under its own collection. A run
    /// with nothing due (or every rule paused) persists and queues nothing.
    /// Returns whether anything changed.
    @discardableResult
    func runRecurringJobGeneration(
        today: String? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        let resolvedToday = today ?? NativeRecurringJobs.todayString(calendar: calendar)
        let generation = NativeRecurringJobs.generate(
            rules: snapshot.payload.recurringJobs ?? [],
            jobs: snapshot.payload.jobs ?? [],
            today: resolvedToday,
            makeJobID: { ruleID, occurrence in
                Self.recurringJobIDGenerator.recurringJobID(ruleID: ruleID, occurrence: occurrence)
            },
            calendar: calendar
        )
        guard generation.didChange else { return false }
        do {
            var updated = snapshot
            var jobRecords = updated.payload.jobs ?? []
            jobRecords.append(contentsOf: generation.newJobs)
            var ruleRecords = updated.payload.recurringJobs ?? []
            for rule in generation.updatedRules {
                if let index = ruleRecords.firstIndex(where: { $0.id == rule.id }) {
                    ruleRecords[index] = rule
                } else {
                    ruleRecords.append(rule)
                }
            }
            updated.payload.jobs = jobRecords
            updated.payload.recurringJobs = ruleRecords
            try repository.save(updated)
            try apply(updated)
            for job in generation.newJobs {
                enqueueUpsert(table: "jobs", recordId: job.id, record: job)
            }
            for rule in generation.updatedRules {
                enqueueUpsert(table: "recurringJobs", recordId: rule.id, record: rule)
            }
            return true
        } catch {
            migrationMessage = "Recurring jobs could not be generated: \(error.localizedDescription)"
            return false
        }
    }

    /// App-open/foreground entry point mirroring RN's
    /// `checkAndGenerateRecurringJobs`. The Batch 2 recurrence manager calls
    /// this before its own refresh so generated occurrences are visible to it.
    func refreshRecurringJobs() {
        guard mayGenerateRecurringRecords else { return }
        _ = runRecurringJobGeneration()
    }

    /// Foreground entry point for maintenance-plan invoices, gated like
    /// `refreshRecurringJobs`.
    private func refreshRecurringInvoices() {
        guard mayGenerateRecurringRecords else { return }
        _ = runRecurringInvoiceGeneration()
    }

    /// Task 11.12 fix round 3 (controller ruling): recurring generation runs
    /// only in the signed-in, post-initial-sync, exact-workspace state that
    /// derived-state publishing and widget replay also require. Before the
    /// initial sync commits, the snapshot is incomplete: generating against
    /// it can repeat an occurrence another device already generated, and an
    /// occurrence generated during the initial-sync await is dropped by that
    /// commit while it stays queued, so it would be generated again under a
    /// new id (job ids carry a timestamp; invoice ids are random).
    private var mayGenerateRecurringRecords: Bool {
        derivedStatePublishBinding != nil
    }

    /// The initial sync's post-commit generation (jobs and invoices), run
    /// once its gate has advanced so `mayGenerateRecurringRecords` can hold.
    private func runRecurringGenerationAfterInitialSync() {
        refreshRecurringJobs()
        refreshRecurringInvoices()
    }

    private static let recurringInvoiceIDGenerator = LocalIDGenerator()

    /// Stored maintenance-plan rules, newest last.
    var recurringInvoiceRules: [Canonical.RecurringInvoice] {
        snapshot.payload.recurringInvoices ?? []
    }

    /// Creates a maintenance-plan rule. The id must be fresh: a retry or
    /// replay carrying an already-stored id is refused rather than duplicated.
    @discardableResult
    func createRecurringInvoice(_ rule: Canonical.RecurringInvoice) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        guard !(snapshot.payload.recurringInvoices ?? []).contains(where: { $0.id == rule.id }) else {
            migrationMessage = "That maintenance plan already exists. Nothing was saved."
            return false
        }
        do {
            var updated = snapshot
            var records = updated.payload.recurringInvoices ?? []
            records.append(rule)
            updated.payload.recurringInvoices = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringInvoices", recordId: rule.id, record: rule)
            return true
        } catch {
            migrationMessage = "Could not save this maintenance plan: \(error.localizedDescription)"
            return false
        }
    }

    /// Replaces a rule wholesale, resolved by id first so an update for a
    /// rule a sync pull just removed fails instead of resurrecting it.
    /// Generated invoices are never touched by rule edits.
    @discardableResult
    func updateRecurringInvoice(_ rule: Canonical.RecurringInvoice) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringInvoices ?? []
            guard let index = records.firstIndex(where: { $0.id == rule.id }) else {
                migrationMessage = "That maintenance plan could not be found. Nothing was saved."
                return false
            }
            records[index] = rule
            updated.payload.recurringInvoices = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringInvoices", recordId: rule.id, record: rule)
            return true
        } catch {
            migrationMessage = "Could not save this maintenance plan: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes a rule. Invoices it already generated are real receivables and
    /// are never touched.
    @discardableResult
    func deleteRecurringInvoice(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringInvoices ?? []
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            records.remove(at: index)
            updated.payload.recurringInvoices = records
            try repository.save(updated)
            try apply(updated)
            enqueueDelete(table: "recurringInvoices", recordId: id)
            return true
        } catch {
            migrationMessage = "The maintenance plan could not be deleted safely. Nothing was changed."
            return false
        }
    }

    /// Pauses or resumes a rule against the fresh canonical record. Resume
    /// fast-forwards `nextDueDate` past today first, so the engine never
    /// catch-up-generates (and back-bills) occurrences that elapsed while
    /// paused; skipped periods do not count as billed occurrences. Pause
    /// changes nothing beyond the flag.
    @discardableResult
    func setRecurringInvoiceActive(id: String, isActive: Bool, today: String? = nil, calendar: Calendar = .current) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.recurringInvoices ?? []
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            var rule = records[index]
            if isActive {
                let resolvedToday = today ?? NativeRecurringJobs.todayString(calendar: calendar)
                rule.nextDueDate = RecurrenceRules.fastForwardedInvoiceDate(
                    RecurrenceState(
                        endCondition: RecurrenceEndCondition(rawValue: rule.endCondition) ?? .never,
                        endCount: rule.endCount,
                        endDate: rule.endDate,
                        occurrenceCount: rule.occurrenceCount,
                        nextDueDate: rule.nextDueDate),
                    cadence: RecurrenceCadence(rawValue: rule.cadence) ?? .monthly,
                    through: resolvedToday,
                    calendar: calendar)
            }
            rule.isActive = isActive
            records[index] = rule
            updated.payload.recurringInvoices = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "recurringInvoices", recordId: rule.id, record: rule)
            return true
        } catch {
            migrationMessage = "The maintenance plan could not be updated safely. Nothing was changed."
            return false
        }
    }

    /// Phase 7 recurring-invoice generation, mirroring RN's
    /// `checkAndGenerateRecurringInvoices`. Runs after the verified workspace
    /// and initial sync are ready (callers gate on that); overlapping runs
    /// are serialized by the caller's generation flag. Generated invoices and
    /// advanced rules commit atomically; stamped auto-send invoices are handed
    /// to the same delivery preparation as job-completion invoices.
    @discardableResult
    func runRecurringInvoiceGeneration(
        today: String? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        let resolvedToday = today ?? NativeRecurringJobs.todayString(calendar: calendar)
        var contactsByID: [String: NativeRecurringInvoiceContact] = [:]
        var contactsByName: [String: NativeRecurringInvoiceContact] = [:]
        for customer in snapshot.payload.customers ?? [] {
            let contact = NativeRecurringInvoiceContact(email: customer.email, phone: customer.phone)
            contactsByID[customer.id] = contact
            if contactsByName[customer.name] == nil { contactsByName[customer.name] = contact }
        }
        let numbering = InvoiceNumberOptions(
            prefix: settings.invoicePrefix, startingNumber: Double(settings.invoiceStart))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let generation = NativeRecurringInvoices.generate(
            rules: snapshot.payload.recurringInvoices ?? [],
            invoices: snapshot.payload.invoices ?? [],
            contactsByID: contactsByID,
            contactsByName: contactsByName,
            existingNumbers: (snapshot.payload.invoices ?? []).map { Optional($0.number) },
            today: resolvedToday,
            makeInvoiceID: { Self.recurringInvoiceIDGenerator.generatedInvoiceID() },
            resolveNumber: { InvoiceNumberRules.nextNumber(existingNumbers: $0, options: numbering) },
            autoSendMasterEnabled: settings.autoSendRecurringInvoicesEnabled,
            stampedAt: formatter.string(from: Date()),
            calendar: calendar)
        guard generation.didChange else { return false }
        do {
            var updated = snapshot
            var invoiceRecords = updated.payload.invoices ?? []
            invoiceRecords.append(contentsOf: generation.newInvoices)
            var ruleRecords = updated.payload.recurringInvoices ?? []
            for rule in generation.updatedRules {
                if let index = ruleRecords.firstIndex(where: { $0.id == rule.id }) {
                    ruleRecords[index] = rule
                } else {
                    ruleRecords.append(rule)
                }
            }
            updated.payload.invoices = invoiceRecords
            updated.payload.recurringInvoices = ruleRecords
            try repository.save(updated)
            try apply(updated)
            for invoice in generation.newInvoices {
                enqueueUpsert(table: "invoices", recordId: invoice.id, record: invoice)
            }
            for rule in generation.updatedRules {
                enqueueUpsert(table: "recurringInvoices", recordId: rule.id, record: rule)
            }
            for invoiceID in generation.autoSendInvoiceIDs {
                scheduleNativeInvoiceDelivery(invoiceID: invoiceID)
            }
            return true
        } catch {
            migrationMessage = "Recurring invoices could not be generated: \(error.localizedDescription)"
            return false
        }
    }

    /// Payment mutations resolve the invoice again by ID so a sheet or alert
    /// cannot overwrite a payment that arrived after it was presented.
    /// Payment IDs are caller-stable: retries reuse the same ID and the
    /// ledger dedupes, so a double submit records exactly one payment.
    @discardableResult
    func recordPayment(invoiceID: String, payment: Payment) -> Result<Invoice, NativeInvoiceEditRefusal> {
        guard let current = invoices.first(where: { $0.id == invoiceID }) else {
            return .failure(.missingRecord)
        }
        let result = commitInvoicePayment(current.applying(payment))
        // Task 11.08: RN `InvoicesScreen.tsx:359`/`:365`. A retried submit
        // that the ledger deduped recorded nothing, so it tracks nothing.
        if case .success(let next) = result,
           !current.effectivePayments.contains(where: { $0.id == payment.id }) {
            emitAnalytics(.paymentRecorded(amount: payment.amount, method: payment.method, balanceRemaining: next.balance))
            if next.isPaid && !current.isPaid {
                emitAnalytics(.invoicePaid(amount: next.amount))
                onAppRatingWin?(.invoicePaid)
            }
        }
        return result
    }

    @discardableResult
    func settleInvoice(invoiceID: String, on date: Date = .now, paymentID: String) -> Result<Invoice, NativeInvoiceEditRefusal> {
        guard let current = invoices.first(where: { $0.id == invoiceID }) else {
            return .failure(.missingRecord)
        }
        // Already settled: idempotent no-op so a repeated submit is safe.
        if current.isPaid { return .success(current) }
        let result = commitInvoicePayment(current.settlingRemaining(on: date, paymentID: paymentID))
        // Task 11.08: RN `InvoicesScreen.tsx:335`/`:340` (`method: other`,
        // `balanceRemaining: 0`, the balance before settling as `amount`).
        if case .success = result {
            emitAnalytics(.paymentRecorded(amount: current.balance, method: "other", balanceRemaining: 0))
            emitAnalytics(.invoicePaid(amount: current.amount))
            onAppRatingWin?(.invoicePaid)
        }
        return result
    }

    @discardableResult
    func voidPayment(invoiceID: String, paymentID: String, on date: Date = .now) -> Result<Invoice, NativeInvoiceEditRefusal> {
        guard let current = invoices.first(where: { $0.id == invoiceID }) else {
            return .failure(.missingRecord)
        }
        guard current.effectivePayments.contains(where: { $0.id == paymentID && $0.voidedAt == nil }) else {
            // Unknown or already-voided: nothing to do, not a failure.
            return .success(current)
        }
        // Voiding restores the invoice balance but deliberately does not
        // regress a linked job that has already advanced to paid.
        let voided = current.effectivePayments.first(where: { $0.id == paymentID })
        let result = commitInvoicePayment(current.voidingPayment(id: paymentID, on: date))
        // Task 11.08: RN `InvoicesScreen.tsx:407`.
        if case .success = result, let voided {
            emitAnalytics(.paymentVoided(amount: voided.amount, method: voided.method))
        }
        return result
    }

    @discardableResult
    func deleteJob(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            let result = try NativeRecordDeletion.deleteJob(snapshot: snapshot, recordID: id)
            try commitRecordDeletion(result)
            pendingCustomerMergeUndo = nil
            pendingRecordDeleteUndo = result.undo
            scheduleRecordDeleteUndoExpiration(id: result.undo.id)
            return true
        } catch NativeRecordDeletionError.recordNotFound {
            return false
        } catch {
            migrationMessage = "The job could not be deleted safely. Nothing was changed."
            return false
        }
    }
    @discardableResult
    func deleteInvoice(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            let result = try NativeRecordDeletion.deleteInvoice(snapshot: snapshot, recordID: id)
            try commitRecordDeletion(result)
            pendingCustomerMergeUndo = nil
            pendingRecordDeleteUndo = result.undo
            scheduleRecordDeleteUndoExpiration(id: result.undo.id)
            return true
        } catch NativeRecordDeletionError.recordNotFound {
            return false
        } catch {
            migrationMessage = "The invoice could not be deleted safely. Nothing was changed."
            return false
        }
    }
    @discardableResult
    func deleteCustomer(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            let result = try NativeRecordDeletion.deleteCustomer(snapshot: snapshot, recordID: id)
            try commitRecordDeletion(result)
            pendingCustomerMergeUndo = nil
            pendingRecordDeleteUndo = result.undo
            scheduleRecordDeleteUndoExpiration(id: result.undo.id)
            return true
        } catch NativeRecordDeletionError.recordNotFound {
            return false
        } catch {
            migrationMessage = "The customer could not be deleted safely. Nothing was changed."
            return false
        }
    }
    func setCustomerArchived(id: String, archived: Bool, on date: Date = .now) {
        guard var customer = customers.first(where: { $0.id == id }) else { return }
        guard NativeCustomerIdentity.isArchived(customer) != archived else { return }
        customer.archivedAt = archived ? date.dateOnlyString : nil
        upsert(customer)
    }
    @discardableResult
    func setJobArchived(id: String, archived: Bool, on date: Date = .now) -> Bool {
        guard var job = jobs.first(where: { $0.id == id }) else { return false }
        let currentlyArchived = !(job.archivedAt ?? "").isEmpty
        guard currentlyArchived != archived else { return true }
        job.archivedAt = archived ? date.dateOnlyString : nil
        return upsert(job)
    }

    // MARK: - Job photos (local-first capture/import pipeline)

    func jobPhotos(for jobID: String) -> [Canonical.JobPhoto] {
        (snapshot.payload.jobPhotos ?? [])
            .filter { $0.jobId == jobID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func jobPhotoBytes(photoID: String) -> Data? {
        guard let url = try? NativeJobPhotoStorage.photoURL(
            root: repository.liveMediaDirectoryURL,
            photoID: photoID
        ) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Captures already-normalized image bytes for a job: validates/converts to
    /// the JPEG `<= 6 MiB` transfer contract, mints a `p<digits>_<base36>` ID,
    /// atomically writes `<media-root>/job-photos/<id>.jpg` (local bytes win;
    /// an existing file is never overwritten), then durably commits the
    /// `Canonical.JobPhoto` (fail-closed `customerVisible: false`) before
    /// publishing and enqueuing the `jobPhotos` upsert. Returns the committed
    /// record, or nil when validation or persistence fails.
    @discardableResult
    func createJobPhoto(
        jobID: String,
        sourceData: Data,
        width: Int? = nil,
        height: Int? = nil,
        on date: Date = .now
    ) -> Canonical.JobPhoto? {
        guard ensurePersistenceWritable() else { return nil }
        let mediaRoot = repository.liveMediaDirectoryURL
        let existingIDs = Set((snapshot.payload.jobPhotos ?? []).map(\.id))
        let captured: NativeJobPhotoImport.CapturedPhoto
        do {
            captured = try NativeJobPhotoImport.capture(
                jobID: jobID,
                sourceData: sourceData,
                width: width,
                height: height,
                root: mediaRoot,
                now: date,
                existingIDs: existingIDs
            )
        } catch {
            migrationMessage = "The photo could not be saved. Nothing was changed."
            return nil
        }
        do {
            // Re-resolve against the current snapshot so a concurrent pull that
            // introduced the same ID cannot be silently duplicated.
            guard !(snapshot.payload.jobPhotos ?? []).contains(where: { $0.id == captured.photo.id }) else {
                migrationMessage = "The photo could not be saved. Nothing was changed."
                return nil
            }
            let effect = try NativeJobPhotoMutations.create(snapshot: snapshot, photo: captured.photo)
            try repository.save(effect.snapshot)
            try apply(effect.snapshot)
            do {
                try mutationQueue.enqueueBatch([effect.draft])
                scheduleSyncAfterLocalChange()
            } catch {
                print("TradeReadyMutationQueue stage=enqueue table=jobPhotos")
                recordLocalSyncFailure("queue/enqueue-job-photos")
            }
            return captured.photo
        } catch {
            migrationMessage = "The photo could not be saved. Nothing was changed."
            return nil
        }
    }

    /// Flips one photo's portal visibility, re-resolving the canonical record
    /// by ID and mutating only `customerVisible`. Durable commit precedes
    /// publish; the `jobPhotos` upsert is enqueued after the save.
    @discardableResult
    func setJobPhotoVisibility(photoID: String, visible: Bool) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            let effect = try NativeJobPhotoMutations.setVisibility(
                snapshot: snapshot,
                photoID: photoID,
                visible: visible
            )
            try repository.save(effect.snapshot)
            try apply(effect.snapshot)
            do {
                try mutationQueue.enqueueBatch([effect.draft])
                scheduleSyncAfterLocalChange()
            } catch {
                print("TradeReadyMutationQueue stage=enqueue table=jobPhotos")
                recordLocalSyncFailure("queue/enqueue-job-photos")
            }
            return true
        } catch NativeJobPhotoImportError.recordNotFound {
            return false
        } catch {
            migrationMessage = "The photo visibility could not be changed. Nothing was changed."
            return false
        }
    }

    /// Deletes one photo everywhere local: re-resolves the canonical record by
    /// ID, durably commits its removal, enqueues the `jobPhotos` delete, then
    /// best-effort removes the deterministic local bytes. A missing file never
    /// fails the metadata delete; sibling files are never touched.
    @discardableResult
    func deleteJobPhoto(photoID: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            let effect = try NativeJobPhotoMutations.delete(snapshot: snapshot, photoID: photoID)
            try repository.save(effect.snapshot)
            try apply(effect.snapshot)
            do {
                try mutationQueue.enqueueBatch([effect.draft])
                scheduleSyncAfterLocalChange()
            } catch {
                print("TradeReadyMutationQueue stage=enqueue-delete table=jobPhotos")
                recordLocalSyncFailure("queue/enqueue-delete-job-photos")
            }
            NativeJobPhotoImport.removeBytesIfPresent(
                root: repository.liveMediaDirectoryURL,
                photoID: photoID
            )
            return true
        } catch NativeJobPhotoImportError.recordNotFound {
            return false
        } catch {
            migrationMessage = "The photo could not be deleted safely. Nothing was changed."
            return false
        }
    }

    /// Fail-closed visibility read for callers: only an explicit `true` counts
    /// as customer-visible.
    func isJobPhotoCustomerVisible(photoID: String) -> Bool {
        guard let photo = snapshot.payload.jobPhotos?.first(where: { $0.id == photoID }) else { return false }
        return NativeJobPhotoImport.isCustomerVisible(photo)
    }

    /// Applies only the direct, one-step lifecycle actions whose dependent
    /// screen work is already complete. The expected status is an exact stale-
    /// UI guard, so a delayed tap cannot overwrite a newer sync transition.
    @discardableResult
    func advanceJobLifecycle(id: String, from expectedStatus: JobStatus) -> Bool {
        if expectedStatus == .inProgress {
            return completeJob(id: id, from: expectedStatus).succeeded
        }
        guard var job = jobs.first(where: { $0.id == id }), job.status == expectedStatus else {
            return false
        }
        guard [.estimateSent, .scheduled].contains(expectedStatus),
              let next = expectedStatus.lifecycleStatus.next
        else { return false }
        job.status = JobStatus(lifecycleStatus: next)
        guard upsert(job) else { return false }
        // Task 11.08: RN `JobDetailScreen.tsx:842`, after `updateJob`.
        emitAnalytics(.jobStatusChanged(from: expectedStatus, to: job.status))
        return true
    }

    /// List-only projection of canonical job metadata. Recurrence and approved
    /// change-order value are intentionally not copied into the editable UI
    /// model, which keeps an ordinary job edit from flattening richer records.
    var jobListItems: [NativeJobListItem] {
        let canonicalByID = Dictionary(
            (snapshot.payload.jobs ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return jobs.map { job in
            let canonical = canonicalByID[job.id]
            let billable = NativeJobList.billableTotal(
                estimate: canonical?.estimateTotal ?? Decimal(job.estimateTotal),
                changeOrders: (canonical?.changeOrders ?? []).map {
                    NativeJobListChangeOrder(
                        amount: $0.amount,
                        approvalDecision: $0.approval?.decision,
                        manualDecision: $0.manualDecision?.decision,
                        isCancelled: !($0.cancelledAt ?? "").isEmpty
                    )
                }
            )
            return NativeJobListItem(
                id: job.id,
                title: job.title,
                customerName: job.customerName,
                description: job.description,
                status: job.status.rawValue,
                createdAt: job.createdAt,
                billableTotal: billable,
                isArchived: !(canonical?.archivedAt ?? job.archivedAt ?? "").isEmpty,
                isRecurring: !(canonical?.recurringJobId ?? "").isEmpty
            )
        }
    }
    func dismissCustomerDuplicatePair(_ key: String) {
        guard let accountBinding = verifiedAccountBinding,
              NativeCustomerIdentity.duplicatePairs(in: customers).contains(where: { $0.key == key }),
              !dismissedCustomerDuplicatePairKeys.contains(key)
        else { return }

        var updated = dismissedCustomerDuplicatePairKeys
        updated.insert(key)
        do {
            try customerDuplicateDismissalStore.save(updated, for: accountBinding)
            dismissedCustomerDuplicatePairKeys = updated
        } catch {
            migrationMessage = "The duplicate suggestion could not be dismissed safely. No customer records were changed."
        }
    }
    @discardableResult
    func mergeCustomer(loserID: String, into winnerID: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            let result = try NativeCustomerIdentity.merge(
                snapshot: snapshot,
                winnerID: winnerID,
                loserID: loserID
            )
            try commitCustomerMerge(result)
            pendingRecordDeleteUndo = nil
            pendingCustomerMergeUndo = result.undo
            scheduleCustomerMergeUndoExpiration(id: result.undo.id)
            // Task 11.08: RN `CustomerDetailScreen.tsx:419`.
            emitAnalytics(.customersMerged(jobs: result.undo.counts.jobs, invoices: result.undo.counts.invoices))
            return true
        } catch {
            migrationMessage = "The customers could not be merged safely. Nothing was changed."
            return false
        }
    }

    func undoCustomerMerge() {
        guard ensurePersistenceWritable(), let token = pendingCustomerMergeUndo else { return }
        do {
            let result = try NativeCustomerIdentity.undo(snapshot: snapshot, token: token)
            try commitCustomerMerge(result)
            pendingCustomerMergeUndo = nil
        } catch NativeCustomerMergeError.undoConflict {
            pendingCustomerMergeUndo = nil
            migrationMessage = "Undo stopped because one of the merged records changed afterward. Your newer changes were preserved."
        } catch {
            pendingCustomerMergeUndo = nil
            migrationMessage = "The customer merge could not be undone safely. Your current records were preserved."
        }
    }

    func dismissCustomerMergeUndo() {
        pendingCustomerMergeUndo = nil
    }

    func undoRecordDeletion() {
        guard ensurePersistenceWritable(), let token = pendingRecordDeleteUndo else { return }
        do {
            let result = try NativeRecordDeletion.undo(snapshot: snapshot, token: token)
            try commitRecordDeletion(result)
            pendingRecordDeleteUndo = nil
        } catch NativeRecordDeletionError.undoConflict {
            pendingRecordDeleteUndo = nil
            migrationMessage = "Undo stopped because that record was recreated afterward. The newer record was preserved."
        } catch {
            pendingRecordDeleteUndo = nil
            migrationMessage = "The deletion could not be undone safely. Your current records were preserved."
        }
    }

    func dismissRecordDeleteUndo() {
        pendingRecordDeleteUndo = nil
    }
    func deleteExpense(id: String) {
        guard ensurePersistenceWritable() else { return }
        let existed = snapshot.payload.expenses?.contains { $0.id == id } ?? false
        var next = snapshot
        next.payload.expenses?.removeAll { $0.id == id }
        do {
            // P12-008: the delete is queued only once saved.
            try commitSnapshot(next)
            if existed { enqueueDelete(table: "expenses", recordId: id) }
        } catch {
            migrationMessage = "Could not delete expense: \(error.localizedDescription)"
        }
    }

    func nextInvoiceNumber() -> String {
        InvoiceNumberRules.nextNumber(existingNumbers: invoices.map { Optional($0.number) },
            options: InvoiceNumberOptions(prefix: settings.invoicePrefix, startingNumber: Double(settings.invoiceStart)))
    }

    func customerRollup(_ customer: Customer) -> (revenue: Double, owed: Double) {
        let matches = invoices.filter { $0.customerId == customer.id || $0.customer.caseInsensitiveCompare(customer.name) == .orderedSame }
        return (matches.reduce(0) { $0 + $1.amountPaid }, matches.reduce(0) { $0 + $1.balance })
    }

    func customerHasPortalLink(id: String) -> Bool {
        snapshot.payload.customers?.first(where: { $0.id == id })?.portal != nil
    }

    func routeToGlobalSearchResult(_ destination: NativeGlobalSearchDestination) {
        deepLinkedJobID = nil
        deepLinkedCustomerID = nil
        deepLinkedInvoiceID = nil
        deepLinkedOutreachInvoiceID = nil

        switch destination {
        case .job(let id):
            guard jobs.contains(where: { $0.id == id && ($0.archivedAt ?? "").isEmpty }) else { return }
            deepLinkedJobID = id
            selectedTab = .jobs
        case .customer(let id):
            guard customers.contains(where: { $0.id == id && ($0.archivedAt ?? "").isEmpty }) else { return }
            deepLinkedCustomerID = id
            selectedTab = .customers
        case .invoice(let id):
            guard invoices.contains(where: { $0.id == id }) else { return }
            deepLinkedInvoiceID = id
            selectedTab = .invoices
        }
    }

    /// A warm URL: `onOpenURL` (after `NativeOpenURLDispatch` offered it to
    /// Google Sign-In), the launch URL, or the in-process On My Way router.
    /// Task 11.06 (contract §6.2): the password-recovery link keeps its
    /// priority; everything else is parsed strictly (malformed or oversized →
    /// dropped with no side effect) and then gated by
    /// `NativeDeepLinkRoutingPolicy` — authenticate (else park), exact owner,
    /// then a live, non-archived record in the current owner's data.
    func handle(url: URL, now: Date = Date()) {
        if let recoveryLink = NativePasswordRecoveryLink.parse(url) {
            Task { await handlePasswordRecoveryLink(recoveryLink) }
            return
        }
        guard let route = NativeDeepLinkParser.parse(url.absoluteString) else { return }
        // 11.04 handoff: `OnMyWayIntent` stashes this same link and hands it
        // to the router. Remove the matching stash now (RN `App.tsx` drops it
        // after navigating from the live URL) so the next activation cannot
        // present the review a second time; the warm route keeps the stash's
        // owner tag as extra proof.
        var stashOwnerTag: String?
        if case .onMyWay = route, let pendingOpenURLConsumer {
            stashOwnerTag = pendingOpenURLConsumer.takeMatching(route).ownerTag
        }
        resolveDeepLink(
            NativeDeepLinkCandidate(
                route: route,
                source: .warmURL,
                ownerTag: stashOwnerTag,
                arrivalBinding: deepLinkSessionOwnerBinding,
                at: now
            ),
            now: now
        )
    }

    /// Task 11.06 (contract §6.2): reads and removes the cold-launch
    /// `pendingOpenUrl` stash under the shared lock, whatever the gate. Not
    /// signed in → the route parks with its owner tag (cold-launch parking);
    /// signed in → it is gated now. `TradeReadyNativeApp` calls this at launch
    /// and on every activation; the `.signedIn` arrivals call it too.
    func consumePendingOpenURLStash(now: Date = Date()) {
        guard let pendingOpenURLConsumer,
              case .pending(let pending) = pendingOpenURLConsumer.take(now: now)
        else { return }
        resolveDeepLink(
            NativeDeepLinkCandidate(
                route: pending.route,
                source: .coldStash,
                ownerTag: pending.ownerTag,
                arrivalBinding: nil,
                at: pending.at
            ),
            now: now
        )
    }

    /// §6.2 step 4: the app backgrounded before the gate opened.
    func discardParkedDeepLink() {
        parkedDeepLink = nil
    }

    func dismissDeepLinkUnavailableNotice() {
        deepLinkUnavailableNotice = nil
    }

    /// The routing phase of a gate state. Exhaustive on purpose: a new gate
    /// must decide whether it parks, discards or routes.
    static func deepLinkGatePhase(_ gate: NativeAuthenticationGateState) -> NativeDeepLinkGatePhase {
        switch gate {
        case .signedIn:
            .signedIn
        case .signedOut, .accountMismatch, .unavailable:
            .closed
        case .loading, .initialSyncLoading, .initialSyncUnavailable, .subscriptionLoading,
             .passwordRecovery, .invalidPasswordRecovery, .onboarding, .paywall, .startingPoint:
            .pending
        }
    }

    /// Decides and applies one candidate. Synchronous on the main actor: the
    /// gate phase, `O` and the record are read at the same instant the route
    /// is applied, with no suspension point in between.
    private func resolveDeepLink(_ candidate: NativeDeepLinkCandidate, now: Date) {
        let decision = NativeDeepLinkRoutingPolicy.decide(
            candidate,
            phase: Self.deepLinkGatePhase(authenticationGateState),
            ownerBinding: derivedStatePublishBinding,
            now: now,
            record: { [snapshot] id in
                guard let job = snapshot.payload.jobs?.first(where: { $0.id == id }) else { return nil }
                let sessions = (job.timeSessions ?? []).map { NativeTimeSession(start: $0.start, end: $0.end) }
                return NativeDeepLinkRecord(
                    isArchived: !(job.archivedAt ?? "").isEmpty,
                    status: job.status,
                    hasRunningTimer: NativeTimeTracking.activeSession(in: sessions) != nil
                )
            }
        )
        switch decision {
        case .park:
            // At most one parked route; the newest arrival wins (RN
            // `pendingDeepLinkRef`).
            parkedDeepLink = candidate
        case .apply(let route):
            deepLinkUnavailableNotice = nil
            switch route {
            case .job(let id): routeToJob(id)
            case .onMyWay(let id): routeToOnMyWay(id)
            }
            emitAnalytics(.widgetDeepLinkOpened(type: NativeDeepLinkRoutingPolicy.analyticsType(route)))
        case .discard(let reason):
            if reason.surfacesNotFound {
                deepLinkUnavailableNotice = NativeDeepLinkUnavailableNotice(reason: reason)
            }
        }
    }

    /// Applies (or discards) the parked route once the gate allows; keeps it
    /// parked while the gate is still pending.
    private func flushParkedDeepLink(now: Date = Date()) {
        guard let parked = parkedDeepLink else { return }
        parkedDeepLink = nil
        resolveDeepLink(parked, now: now)
    }

    private func handleDeepLinkGateChange(from oldValue: NativeAuthenticationGateState) {
        let phase = Self.deepLinkGatePhase(authenticationGateState)
        let gateChanged = oldValue != authenticationGateState
        if NativeDeepLinkRoutingPolicy.discardsParked(
            entering: phase,
            gateChanged: gateChanged,
            ownerWasActive: deepLinkOwnerWasActive
        ) {
            parkedDeepLink = nil
            deepLinkUnavailableNotice = nil
        }
        if phase == .closed, gateChanged {
            // The boundary is consumed; a later closed gate needs a new owner.
            deepLinkOwnerWasActive = false
        } else if deepLinkSessionOwnerBinding != nil {
            deepLinkOwnerWasActive = true
        }
        if phase == .signedIn, Self.deepLinkGatePhase(oldValue) != .signedIn {
            flushParkedDeepLink()
        }
    }

    /// Final review item 2: the session a link arrives in (and the session a
    /// boundary leaves) is the verified account, not only a completed-workspace
    /// owner `O`. `O` is nil behind `.initialSyncLoading`/`.initialSyncUnavailable`
    /// and the recovery gates, yet the signed-in account is already known, so
    /// a link parked there is stamped with that account and dropped when the
    /// session ends instead of resolving later in another account's data.
    /// Closed gates and `.loading` (a re-verification whose outcome may be a
    /// different account) never borrow a possibly stale verified binding.
    private var deepLinkSessionOwnerBinding: String? {
        if let derivedStatePublishBinding { return derivedStatePublishBinding }
        guard authenticationGateState != .loading,
              Self.deepLinkGatePhase(authenticationGateState) != .closed
        else { return nil }
        return verifiedAccountBinding
    }

    /// Task 11.06 (11.05 handoff d): every held route and one-shot target
    /// from the previous session is dropped at each account boundary
    /// (sign-out, deletion, scrub retry, use another account).
    private func clearDeepLinkRouteState() {
        parkedDeepLink = nil
        deepLinkUnavailableNotice = nil
        deepLinkedJobID = nil
        deepLinkedCustomerID = nil
        deepLinkedInvoiceID = nil
        deepLinkedOutreachInvoiceID = nil
        pendingOnMyWayJobID = nil
        pendingAppointmentConfirmationJobID = nil
        pendingReviewRequestJobID = nil
        pendingEstimateFollowUpJobID = nil
    }

    func importLegacyData() {
        do {
            let coordinator = LegacyMigrationCoordinator(
                repository: repository,
                journal: migrationJournal,
                secureStore: secureSettingsStore
            )
            // Phase 12 (12.06): the same one read of the legacy source as the
            // launch and "Try again" (the live source in the app), so a host
            // test drives this button on its fixture device.
            let result = try migrateLegacySource(with: coordinator)
            switch result.status {
            case .noData:
                migrationMessage = "No React Native AsyncStorage data was found on this installation."; return
            case .alreadyCompleted:
                migrationMessage = "React Native data was already imported."; return
            case .nativeSnapshotConflict:
                migrationMessage = "Previous-app data was found, but this app already has data. Nothing was changed."
                launchMigrationNotice = .conflict
                return
            case .nativeStateAdopted:
                // Phase 12 (12.06, P12-011): never over this device's native state.
                migrationMessage = "This device already has data from this app, so previous-app data was not imported. Nothing was changed."
                return
            case .migrated:
                break
            }
            guard let importedSnapshot = result.snapshot else { return }
            try apply(importedSnapshot)
            persistenceWritesBlocked = false
            persistenceBlockReason = nil
            persistenceBlockDetail = nil
            let photoWarning = result.missingPhotoCount == 0
                ? ""
                : " \(result.missingPhotoCount) referenced photo(s) were not present."
            migrationMessage = "Imported \(result.importedCount) items from the React Native app.\(photoWarning)"
        } catch { migrationMessage = "Import failed: \(error.localizedDescription)" }
    }

    func retryLegacyMigration() {
        // Phase 12 (12.00b.2-G, P12-003): the launch gate's signed-out case.
        // There is nothing to migrate, so nothing is read; the empty
        // workspace opens.
        let journalStatus = try? migrationJournal.read().entries.last {
            $0.migration == .reactNativeAsyncStorage
        }?.status
        if !FileManager.default.fileExists(atPath: fileURL.path),
           !FileManager.default.fileExists(atPath: repository.backupURL.path),
           isMigratedWorkspaceClearedByAccountScrub(journalStatus: journalStatus) {
            load(seedIfMissing: false)
            isLegacyMigrationBlocked = false
            launchMigrationNotice = nil
            migrationMessage = nil
            return
        }
        do {
            let outcome = try migrateLegacySource(with: LegacyMigrationCoordinator(
                repository: repository,
                journal: migrationJournal,
                secureStore: secureSettingsStore
            ))
            // Phase 12 (12.06, P12-011): an adopted native state opens as it
            // is (recovered from its backup, or the empty signed-out workspace).
            if outcome.status == .migrated || outcome.status == .nativeStateAdopted { load(seedIfMissing: false) }
            if outcome.status == .nativeStateAdopted { migrationMessage = nil }
            applyLaunchMigrationState(outcome: outcome, error: nil, hadNativeSnapshot: false, operation: "retry")
        } catch {
            applyLaunchMigrationState(outcome: nil, error: error, hadNativeSnapshot: false, operation: "retry")
        }
    }

    /// Phase 12 (12.00b.2-G, P12-003): with no snapshot on disk, whether the
    /// migration completed and an account scrub then cleared its workspace
    /// (`SnapshotRepository.isLiveWorkspaceClearedByAccountScrub`) — the
    /// signed-out state of a migrated device — rather than the snapshot having
    /// been lost.
    private func isMigratedWorkspaceClearedByAccountScrub(
        journalStatus: Canonical.MigrationJournalStatus?
    ) -> Bool {
        journalStatus == .completed && repository.isLiveWorkspaceClearedByAccountScrub
    }

    /// The launch migration's and "Try again"'s one read of the legacy source:
    /// a host test's fixture source when one was injected (Phase 12.00b.2-F:
    /// the provider is read here, after any pending scrub, as `liveSource()`
    /// is), otherwise the device's live legacy data.
    private func migrateLegacySource(
        with coordinator: LegacyMigrationCoordinator
    ) throws -> LegacyMigrationOutcome {
        // Phase 12 (12.06, P12-011): a completed journal or an adopted native
        // state is decided before any legacy source is read.
        if let settled = try coordinator.settledOutcome() { return settled }
        if let legacyMigrationSource {
            return try coordinator.migrate(currentSettings: settings, source: legacyMigrationSource)
        }
        if let legacyMigrationSourceProvider {
            return try coordinator.migrate(currentSettings: settings, source: try legacyMigrationSourceProvider())
        }
        return try coordinator.migrate(currentSettings: settings)
    }

    func dismissLaunchMigrationNotice() {
        launchMigrationNotice = nil
    }

    /// Revalidates an imported Supabase session with Auth. During a temporary
    /// outage, an exact-session Keychain cache may reopen only a workspace that
    /// was already bound after a completed online bootstrap.
    func activateMigratedAuthenticatedIdentity() async {
        guard !authenticationOperationInFlight else { return }
        if identityActivationInFlight {
            await withCheckedContinuation { continuation in
                identityActivationWaiters.append(continuation)
            }
            // A background-only preparation intentionally leaves routing at
            // loading. If foreground activation was waiting behind it, run the
            // normal gate pipeline now that the shared verifier is free.
            if case .loading = authenticationGateState {
                await activateMigratedAuthenticatedIdentity()
            }
            return
        }
        identityActivationInFlight = true
        defer { finishIdentityActivation() }
        let isInitialCheck = !didCheckMigratedAuthenticatedIdentity
        didCheckMigratedAuthenticatedIdentity = true
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else {
            authenticatedAccountState = .unavailable
            authenticationGateState = .unavailable
            return
        }

        let recoveryState: NativePasswordRecoveryState?
        do {
            recoveryState = try NativePasswordRecoveryStore().read()
        } catch NativePasswordRecoveryError.corruptState {
            do {
                try NativePasswordRecoveryStore().clear()
                recoveryState = nil
            } catch {
                authenticatedAccountState = .unavailable
                authenticationGateState = .unavailable
                return
            }
        } catch {
            authenticatedAccountState = .unavailable
            authenticationGateState = .unavailable
            return
        }

        let verifier = NativeSupabaseAuthenticatedIdentityVerifier(
            supabaseURL: supabaseURL,
            publishableKey: publishableKey
        )
        let activator: NativeAuthenticatedIdentityActivator
        if let existing = authenticatedIdentityActivator {
            activator = existing
        } else {
            let created = NativeAuthenticatedIdentityActivator(
                snapshotURL: fileURL,
                sessionStore: secureSettingsStore,
                verifier: verifier,
                refresher: verifier
            )
            authenticatedIdentityActivator = created
            activator = created
        }
        await completeIdentityActivation(
            activator,
            recoveryState: recoveryState,
            isInitialCheck: isInitialCheck
        )
    }

    /// The identity check's verifier await and its outcome: the part of
    /// `activateMigratedAuthenticatedIdentity` after its guards, shared with
    /// the host-test seam `testRunIdentityActivation`.
    ///
    /// Phase 12 (12.00b.2-G fix round 1, R31): the check can be suspended in
    /// `/auth/v1/user` while an account boundary finishes (scene activation's
    /// retry of a pending sign-out, the Retry button, a sign-out, a deletion,
    /// an account switch, a password-recovery exit). The boundary is final: a
    /// result, or an error, that arrives after it is dropped rather than
    /// applied over it.
    private func completeIdentityActivation(
        _ activator: NativeAuthenticatedIdentityActivator,
        recoveryState: NativePasswordRecoveryState?,
        isInitialCheck: Bool
    ) async {
        let priorAccountState = authenticatedAccountState
        let priorGateState = authenticationGateState
        let hadVerifiedSubject = authenticatedUserSubject != nil
        let hadVerifiedBinding = verifiedAccountBinding != nil
        authenticatedAccountState = .checking
        if isInitialCheck { authenticationGateState = .loading }
        let boundaryGeneration = accountBoundaryGeneration
        let activation: Result<NativeAuthenticatedIdentityActivationOutcome?, Error>
        do { activation = .success(try await activator.activate()) } catch { activation = .failure(error) }
        guard accountBoundaryGeneration == boundaryGeneration else {
            discardIdentityActivationOvertakenByAccountBoundary()
            return
        }
        do {
            let outcome = try activation.get()
            guard let outcome else {
                if recoveryState?.activeUserSubject != nil {
                    try NativePasswordRecoveryStore().clear()
                }
                authenticatedAccountState = .noMigratedSession
                authenticationGateState = .signedOut
                return
            }
            if let recoverySubject = recoveryState?.activeUserSubject {
                guard recoverySubject == outcome.verifiedUserSubject else {
                    try NativePasswordRecoveryStore().clear()
                    applyAuthenticatedIdentityOutcome(
                        outcome,
                        email: nil,
                        allowUnboundWorkspaceAdoption: true
                    )
                    return
                }
                applyAuthenticatedIdentityOutcome(
                    outcome,
                    email: nil,
                    gateOverride: .passwordRecovery(email: nil),
                    activateConsumers: false
                )
            } else {
                applyAuthenticatedIdentityOutcome(
                    outcome,
                    email: nil,
                    allowUnboundWorkspaceAdoption: true
                )
            }
        } catch NativeAuthenticatedIdentityError.rejectedSession {
            applyRejectedSessionState()
        } catch NativeAuthenticatedIdentityError.malformedStoredSession {
            applyRejectedSessionState()
        } catch NativeAuthenticatedIdentityError.missingAccessToken {
            applyRejectedSessionState()
        } catch NativeAuthenticatedIdentityError.missingRefreshToken {
            applyRejectedSessionState()
        } catch NativeAuthenticatedIdentityError.temporarilyUnavailable {
            if nativeShouldPreserveSignedInGateDuringTemporaryOutage(
                isInitialCheck: isInitialCheck,
                accountState: priorAccountState,
                gateState: priorGateState,
                hasVerifiedSubject: hadVerifiedSubject,
                hasVerifiedBinding: hadVerifiedBinding
            ) {
                authenticatedAccountState = priorAccountState
                authenticationGateState = priorGateState
            } else {
                authenticatedAccountState = .unavailable
                authenticationGateState = .unavailable
            }
        } catch {
            // Network, Keychain, artifact, and validation failures all remain
            // non-activating and intentionally disclose no account details.
            authenticatedAccountState = .unavailable
            authenticationGateState = .unavailable
        }
    }

    /// Phase 12 (L286.7): the four session-rejected outcomes of
    /// `activateMigratedAuthenticatedIdentity` end the session the way
    /// sign-out and the recovery exits do: the verified binding and every held
    /// route are dropped (defense in depth — `deepLinkSessionOwnerBinding`
    /// already ignores `.signedOut`). The parked route is left to the gate
    /// change's contract §6.3 rule instead: discarded when an owner was active,
    /// kept by the launch resolution `.loading` → `.signedOut` for the sign-in
    /// that follows (its tag and freshness checks still apply there).
    private func applyRejectedSessionState() {
        verifiedAccountBinding = nil
        authenticatedAccountState = .sessionRejected
        authenticationGateState = .signedOut
        let keptByParkingRule = parkedDeepLink
        clearDeepLinkRouteState()
        parkedDeepLink = keptByParkingRule
    }

    /// Phase 12 (12.00b.2-G fix round 1, R31): an identity check an account
    /// boundary overtook leaves the state as the boundary set it. Its
    /// activator stored the checked session's verified identity in the
    /// Keychain cache after the await, possibly after the boundary had
    /// cleared it, so the cache is cleared too unless it describes the
    /// session stored now. Best effort: a cache left behind names a session
    /// that is no longer stored, is read only for that exact session, and is
    /// replaced at the next sign-in.
    private func discardIdentityActivationOvertakenByAccountBoundary() {
        let cache = NativeVerifiedSessionIdentityCache(backend: secureSettingsStore.backend)
        if let current = try? secureSettingsStore.readSupabaseSession(),
           (try? cache.identity(forExactSession: current)) != nil {
            return
        }
        try? cache.clear()
    }

    private func finishIdentityActivation() {
        identityActivationInFlight = false
        let waiters = identityActivationWaiters
        identityActivationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func retryAuthentication() async {
        didCheckMigratedAuthenticatedIdentity = false
        authenticationGateState = .loading
        await activateMigratedAuthenticatedIdentity()
    }

    func useAnotherAccount(
        clearGoogleCredential: @MainActor () -> Void = {
            NativeGoogleSignInProvider.clearLocalCredential()
        }
    ) async {
        // Final review 1c: one account boundary at a time. A second tap while
        // a switch (or a sign-in/sign-out/deletion) is suspended is a no-op;
        // otherwise its exit would reopen the first switch's gates mid-await.
        // The switch holds `authenticationOperationInFlight` throughout, so
        // no sign-in can start (and bind an owner) until it has finished.
        guard !accountSwitchInFlight, !authenticationOperationInFlight else { return }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        // A verified provider session can still be rejected by the exact-owner
        // gate. Clear Google's Keychain-backed app credential on every exit so
        // the next attempt can actually select a different Google account.
        defer { clearGoogleCredential() }
        // Phase 12 (12.00b.2-G fix round 1, R31): a suspended identity check
        // of the session being cleared drops its result.
        accountBoundaryGeneration &+= 1
        // Phase 12 final review (M4): as a completed sign-out does, so a push
        // still on the wire drops its result instead of settling this
        // owner's refusals into the store after the next owner signs in.
        // The durable queue stays (the workspace is retained).
        syncCoordinator?.reset()
        // Task 11.06 (11.05 handoff d): an account switch is an account
        // boundary for every held route. Cleared before the first await, so
        // nothing parked or deep-linked in the previous session can surface
        // for whoever signs in next.
        clearDeepLinkRouteState()
        // Task 11.08 (§9.4): an account switch is an analytics identity
        // boundary too — reset before the first await, so nothing the next
        // owner does can be attributed to this one.
        applyAnalyticsIdentityBoundary()
        // Task 11.15 fix round 1 (controller ruling): AI provider keys are
        // owner-bound, and the switch can end with a different owner. No key
        // may be saved for the whole switch, and both keys (entered or
        // migrated) are wiped before the first await and again after the last.
        accountSwitchInFlight = true
        defer { accountSwitchInFlight = false }
        wipeAIProviderKeysForAccountBoundary()
        // Phase 12 (12.00b.1): the refused changes belong to the old owner.
        scrubRejectedChangesForAccountBoundary()
        guard let activator = authenticatedIdentityActivator else {
            authenticationGateState = .signedOut
            return
        }
        // Task 11.05 (fix round 1, I1): no mirror write or replay may land
        // between the App Group wipe below and the owner teardown.
        widgetMirrorSuspendedForAccountBoundary = true
        defer { widgetMirrorSuspendedForAccountBoundary = false }
        do {
            try await activator.clearSession()
            // Task 11.05 (I1, contract §3.1): an account switch is an account
            // boundary for the widget/Siri surface even though the local
            // workspace is retained. The extension cannot know `O`, so the
            // previous owner's snapshot, trip and stash are wiped, timelines
            // reloaded at once (before the `logOut` await) and the replay
            // claims removed. Losing that owner's unreplayed actions is
            // accepted (no current users). A wipe failure does not keep the
            // cleared session's owner in memory; it is counted, and (final
            // review 1a) its durable marker keeps the mirror closed until a
            // retry succeeds (`scrubWidgetAccountState`).
            do {
                try scrubWidgetAccountState()
            } catch {
                widgetActionReplayDiagnostics.recordAccountSwitchScrubFailure()
            }
            await subscriptionService.logOut()
            // Task 11.15 fix round 1: and again after the awaits — a key that
            // landed during `clearSession`/`logOut` belonged to the old owner.
            wipeAIProviderKeysForAccountBoundary()
            scrubRejectedChangesForAccountBoundary()
            // Final review (M4): and a pass started during those awaits.
            syncCoordinator?.reset()
        migratedAccountState = nil
        dismissedCustomerDuplicatePairKeys = []
        reviewRequestRecords = []
        pendingCustomerMergeUndo = nil
        pendingRecordDeleteUndo = nil
        isMigratedLocalOwnerVerified = false
            migratedAccountBinding = nil
            verifiedAccountBinding = nil
            authenticatedUserSubject = nil
            authenticatedEmail = nil
            initialSyncCompletedSubject = nil
            initialSyncGateGeneration &+= 1
            authenticatedAccountState = .noMigratedSession
            authenticationGateState = .signedOut
            // Task 11.06: and again after the awaits — a route that arrived
            // during `clearSession`/`logOut` belonged to the cleared session.
            clearDeepLinkRouteState()
            // Task 10.09 (B1): account boundary — clear the owner-scoped
            // cached snapshot (never the observer registrations; the 11.01
            // widget mirror registers once and must keep receiving the next
            // owner's publishes after sign-in).
            derivedStatePublisher.reset()
            // Task 10.12 (S4/D4/D5): account boundary — wipe the mute/
            // checklist stores (device-local, owner-scoped) and their
            // in-memory published state so the next account never inherits
            // a dismissal, snooze, or "used once" flag.
            resetTodayOwnerState()
            // Task 11.05 (I1): replay diagnostics are per owner. The wipe's
            // failure count above survives the reset so it stays visible.
            widgetActionReplayDiagnostics.resetForAccountBoundary()
        } catch {
            authenticationGateState = .unavailable
        }
    }

    func signIn(email: String, password: String) async throws {
        // Final review 1c: never during an account switch either.
        guard !authenticationOperationInFlight, !accountSwitchInFlight else {
            throw NativeSupabaseAuthError.rejected(message: "Another sign-in request is still running.")
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        let configured = try configuredAuthentication()
        let session = try await configured.client.signIn(email: email, password: password)
        let outcome = try await configured.activator.installVerifiedSession(
            sessionBytes: session.bytes,
            responseUserSubject: session.userSubject
        )
        try NativePasswordRecoveryStore().clear()
        finishInteractiveSignIn(outcome, email: session.email, method: .password)
    }

    func signUp(email: String, password: String) async throws -> NativeSupabaseSignUpResult {
        guard !authenticationOperationInFlight else {
            throw NativeSupabaseAuthError.rejected(message: "Another sign-in request is still running.")
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        let configured = try configuredAuthentication()
        let result = try await configured.client.signUp(
            email: email,
            password: password,
            redirectTo: BuildEnvironment.emailConfirmationURL
        )
        if case .signedIn(let session) = result {
            let outcome = try await configured.activator.installVerifiedSession(
                sessionBytes: session.bytes,
                responseUserSubject: session.userSubject
            )
            try NativePasswordRecoveryStore().clear()
            // Phase 12 (L286.4): the same pre-bind retry as sign-in.
            bindInteractiveOwner(outcome, email: session.email)
        }
        // RN `AuthScreen.tsx:130`: after the sign-up call succeeds, in both
        // the confirmation-pending and the signed-in case.
        emitAnalytics(.signUp)
        return result
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws {
        guard !authenticationOperationInFlight else {
            throw NativeSupabaseAuthError.rejected(message: "Another sign-in request is still running.")
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        let configured = try configuredAuthentication()
        let session = try await configured.client.signInWithApple(
            idToken: idToken, rawNonce: rawNonce
        )
        let outcome = try await configured.activator.installVerifiedSession(
            sessionBytes: session.bytes,
            responseUserSubject: session.userSubject
        )
        try NativePasswordRecoveryStore().clear()
        finishInteractiveSignIn(outcome, email: session.email, method: .apple)
    }

    func signInWithGoogle(idToken: String, rawNonce: String) async throws {
        guard !authenticationOperationInFlight else {
            throw NativeSupabaseAuthError.rejected(message: "Another sign-in request is still running.")
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        let configured = try configuredAuthentication()
        let session = try await configured.client.signInWithGoogle(
            idToken: idToken, rawNonce: rawNonce
        )
        let outcome = try await configured.activator.installVerifiedSession(
            sessionBytes: session.bytes,
            responseUserSubject: session.userSubject
        )
        try NativePasswordRecoveryStore().clear()
        finishInteractiveSignIn(outcome, email: session.email, method: .google)
    }

    func requestPasswordReset(email: String) async throws {
        guard !authenticationOperationInFlight else {
            throw NativePasswordRecoveryError.unavailable
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        let configured = try configuredAuthentication()
        guard BuildEnvironment.passwordResetURL?.scheme?.lowercased() == "tradeready" else {
            throw NativeSupabaseAuthError.invalidConfiguration
        }
        let pkce = try NativePasswordRecoveryPKCE.generate()
        let recoveryStore = NativePasswordRecoveryStore()
        try recoveryStore.savePending(verifier: pkce.verifier)
        do {
            try await configured.client.requestPasswordReset(
                email: email,
                redirectTo: BuildEnvironment.passwordResetURL,
                codeChallenge: pkce.challenge
            )
        } catch {
            try? recoveryStore.clearPending(expectedVerifier: pkce.verifier)
            throw error
        }
    }

    func updateRecoveredPassword(_ password: String) async throws {
        guard !authenticationOperationInFlight else {
            throw NativePasswordRecoveryError.unavailable
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }

        let configured = try configuredAuthentication()
        let recoveryStore = NativePasswordRecoveryStore()
        guard let subject = try recoveryStore.read()?.activeUserSubject else {
            throw NativePasswordRecoveryError.expiredLink
        }
        let sessionStore = secureSettingsStore
        guard let session = try sessionStore.readSupabaseSession() else {
            throw NativePasswordRecoveryError.expiredLink
        }
        try await configured.client.updatePassword(
            password,
            sessionBytes: session,
            expectedUserSubject: subject
        )

        // The password update is already authoritative. Remote revocation is
        // best effort, but local recovery credentials are always removed and
        // business data is retained behind the normal identity gate.
        // Phase 12 (12.00b.2-G fix round 2, R31): the recovery session ends
        // here. Advanced before it is cleared, so a check suspended in
        // `/auth/v1/user` that resumes at any point from now on (the actor
        // may let it cache its identity after `clearSession`) is dropped.
        accountBoundaryGeneration &+= 1
        try? await configured.client.revoke(sessionBytes: session)
        try await configured.activator.clearSession()
        try recoveryStore.clear()
        applyRecoverySignedOutState()
    }

    func cancelPasswordRecovery() async {
        guard !authenticationOperationInFlight else { return }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        // Phase 12 (12.00b.2-G fix round 2, R31): see `updateRecoveredPassword`.
        accountBoundaryGeneration &+= 1
        let sessionStore = secureSettingsStore
        if let session = try? sessionStore.readSupabaseSession(),
           let configured = try? configuredAuthentication()
        {
            try? await configured.client.revoke(sessionBytes: session)
            try? await configured.activator.clearSession()
        } else {
            try? sessionStore.clearSupabaseSession()
        }
        try? NativePasswordRecoveryStore().clear()
        applyRecoverySignedOutState()
    }

    /// `recoveryStore` is the Keychain-backed default in the app; a host test
    /// passes an in-memory one (review fix round 1, M6), because host runners
    /// never touch the real Keychain (`HostInMemoryKeychain`).
    func dismissInvalidPasswordRecovery(
        recoveryStore: NativePasswordRecoveryStore = NativePasswordRecoveryStore()
    ) async {
        if (try? recoveryStore.read()?.activeUserSubject) != nil {
            // Phase 12 (12.00b.2-G fix round 2, R31): it drops the recovery
            // session, so a suspended check must not re-apply the recovery
            // gate over it (the fresh check below decides the gate). Without
            // an active recovery session nothing is cleared and the stored
            // session stays: no boundary.
            accountBoundaryGeneration &+= 1
            try? secureSettingsStore.clearSupabaseSession()
            // Task 11.15 fix round 1: dropping the recovery session is an
            // account boundary too (same rule as the two recovery exits).
            wipeAIProviderKeysForAccountBoundary()
            scrubRejectedChangesForAccountBoundary()
        }
        try? recoveryStore.clear()
        didCheckMigratedAuthenticatedIdentity = false
        authenticationGateState = .loading
        await activateMigratedAuthenticatedIdentity()
    }

    func resendSignUpConfirmation(email: String) async throws {
        let configured = try configuredAuthentication()
        try await configured.client.resendSignUpConfirmation(
            email: email,
            redirectTo: BuildEnvironment.emailConfirmationURL
        )
        emitAnalytics(.signUpConfirmationResent)
    }

    func saveOnboardingDraft(_ draft: NativeOnboardingDocument.Draft) throws {
        guard let binding = verifiedAccountBinding else {
            throw NativeOnboardingError.invalidAccountBinding
        }
        let store = NativeOnboardingStore(snapshotURL: fileURL)
        guard var document = try store.load(), document.accountBinding == binding,
              document.stage == .drafting
        else { throw NativeOnboardingError.accountMismatch }
        document.draft = draft
        try store.save(document)
        authenticationGateState = .onboarding(draft)
    }

    func completeOnboardingPersonalization(
        _ draft: NativeOnboardingDocument.Draft
    ) throws {
        guard let binding = verifiedAccountBinding else {
            throw NativeOnboardingError.invalidAccountBinding
        }
        let validated = try draft.validated()
        let store = NativeOnboardingStore(snapshotURL: fileURL)
        guard var document = try store.load(), document.accountBinding == binding,
              document.stage == .drafting
        else { throw NativeOnboardingError.accountMismatch }
        document.draft = validated
        document.stage = .personalizationCommit
        try store.save(document)
        try commitOnboardingSettings(validated)
        document.stage = .personalized
        try store.save(document)
        // RN `OnboardingScreen.tsx:116`: after the personalization saves,
        // before the subscription gate.
        emitAnalytics(.onboardingCompleted(trade: validated.trade))
        beginSubscriptionGate(destination: .startingPoint(validated.trade))
    }

    func retrySubscriptionGate() {
        guard let destination = postSubscriptionDestination else { return }
        beginSubscriptionGate(destination: destination, forceLoading: true)
    }

    func purchaseSubscription(packageID: String) async -> NativeSubscriptionActionOutcome {
        guard !subscriptionOperationInFlight else {
            return .failed(message: "Another subscription request is still running.")
        }
        subscriptionOperationInFlight = true
        defer { subscriptionOperationInFlight = false }
        do {
            let result = try await subscriptionService.purchase(packageID: packageID)
            if result.userCancelled { return .cancelled }
            // RN `PaywallScreen.tsx:90`: `purchasePackage` resolved without a
            // cancel or throw (RN does not re-check the entitlement first).
            emitAnalytics(.subscriptionPurchased)
            isSubscriptionTrialing = result.entitlement.isActive && result.entitlement.isTrialing
            guard result.entitlement.isActive else { return .noActiveSubscription }
            subscriptionGateGeneration &+= 1
            advancePastSubscriptionGate()
            return .completed
        } catch {
            // Phase 12 (12.02, TH-10): RN `PaywallScreen.tsx:94`.
            if !nativeSubscriptionIsUserCancellation(error) {
                reportError(error, context: ["context": "purchase"])
            }
            return .failed(message: subscriptionMessage(for: error))
        }
    }

    func restoreSubscription() async -> NativeSubscriptionActionOutcome {
        guard !subscriptionOperationInFlight else {
            return .failed(message: "Another subscription request is still running.")
        }
        subscriptionOperationInFlight = true
        defer { subscriptionOperationInFlight = false }
        do {
            let entitlement = try await subscriptionService.restore()
            isSubscriptionTrialing = entitlement.isActive && entitlement.isTrialing
            guard entitlement.isActive else {
                return .noActiveSubscription
            }
            subscriptionGateGeneration &+= 1
            advancePastSubscriptionGate()
            return .completed
        } catch {
            // Phase 12 (12.02, TH-10): RN `PaywallScreen.tsx:115`.
            reportError(error, context: ["context": "restorePurchases"])
            return .failed(message: subscriptionMessage(for: error))
        }
    }

    func completeStartingPoint(_ choice: NativeStartingPointChoice) throws {
        guard let binding = verifiedAccountBinding else {
            throw NativeOnboardingError.invalidAccountBinding
        }
        let store = NativeOnboardingStore(snapshotURL: fileURL)
        guard var document = try store.load(), document.accountBinding == binding,
              document.stage == .personalized
        else { throw NativeOnboardingError.accountMismatch }
        document.stage = choice == .sample ? .sampleCommit : .freshCommit
        if choice == .sample {
            document.sampleNamespace = UUID().uuidString.lowercased()
            document.sampleAnchor = .now
        }
        try store.save(document)
        try commitStartingPoint(document)
        document.stage = .done
        try store.save(document)
        // RN `StartingPointScreen.tsx:62`: after `completeStartChoice`.
        emitAnalytics(.onboardingStartChoice(choice))
        authenticationGateState = .signedIn(email: authenticatedEmail)
        consumePendingDeepLinks()
        replayVerifiedWidgetActionsIfPossible()
        // Phase 12 (12.00b.2-K fix round 1, review M3/M4): no booking intake
        // here. The starting point is a gate that waited for the owner, which
        // cleared the pull mark and kept any pull from setting it, so a pass
        // could never convert; the next activation's pull does.
        // Phase 12 (12.00b.2-I, P12-013): unfinished booking/portal work.
        startScheduleBookingRecoveryIfPossible()
    }

    /// Explicit sign-out is the only auth transition allowed to remove local
    /// business data. Automatic expiry remains non-destructive so offline work
    /// is never erased by a transient or rejected session.
    func signOut(revokeRemote: Bool = true) async throws {
        guard !authenticationOperationInFlight else {
            throw NativeAccountSignOutError.remoteRevocationFailed
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        defer { widgetMirrorSuspendedForAccountBoundary = false }

        if revokeRemote {
            do {
                let configured = try configuredAuthentication()
                if let session = try secureSettingsStore.readSupabaseSession() {
                    try await configured.client.revoke(sessionBytes: session)
                }
            } catch {
                throw NativeAccountSignOutError.remoteRevocationFailed
            }
        }

        // Task 11.01: no mirror write may land between the scrub below and
        // the owner teardown in `applyCompletedSignOutState`.
        widgetMirrorSuspendedForAccountBoundary = true
        do {
            try performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .live)
        } catch {
            if repository.isAccountScrubPending {
                markAccountScrubBlocked(scope: try? repository.pendingAccountScrubScope, operation: "signOut")
            } else {
                isAccountScrubBlocked = false
                accountScrubBlockedScope = nil
            }
            throw NativeAccountSignOutError.localScrubFailed
        }

        await subscriptionService.logOut()
        applyCompletedSignOutState()
        NativeGoogleSignInProvider.clearLocalCredential()
        // Task 11.05: timelines were reloaded right after the App Group wipe
        // (`scrubWidgetAccountState()`), before the `logOut` await above.
    }

    func deleteAccount() async throws {
        guard !authenticationOperationInFlight else {
            throw NativeAccountDeletionError.rejected
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        defer { widgetMirrorSuspendedForAccountBoundary = false }

        let endpoint: URL
        do { endpoint = try BuildEnvironment.endpoint("api/delete-account", sendsUserData: true) }
        catch { throw NativeAccountDeletionError.invalidConfiguration }
        guard endpoint.host?.hasSuffix(".invalid") == false else {
            throw NativeAccountDeletionError.invalidConfiguration
        }
        let client = NativeAccountDeletionClient(endpoint: endpoint)
        let sessionStore = secureSettingsStore

        func currentSession() throws -> Data {
            guard let session = try sessionStore.readSupabaseSession() else {
                throw NativeAccountDeletionError.missingSession
            }
            return session
        }

        do {
            try await client.deleteAccount(sessionBytes: try currentSession())
        } catch NativeAccountDeletionError.sessionExpired {
            // A foreground can race the token's short expiry. Reuse the same
            // independently verified refresh boundary and retry exactly once.
            let configured: (client: NativeSupabaseEmailAuthClient, activator: NativeAuthenticatedIdentityActivator)
            do { configured = try configuredAuthentication() }
            catch { throw NativeAccountDeletionError.sessionExpired }
            do {
                guard try await configured.activator.activate() != nil else {
                    throw NativeAccountDeletionError.sessionExpired
                }
                try await client.deleteAccount(sessionBytes: try currentSession())
            } catch {
                throw (error as? NativeAccountDeletionError) ?? .sessionExpired
            }
        }

        try await finishAccountDeletionLocally()
    }

    /// `deleteAccount` once the server has confirmed the deletion: the local
    /// `.all` scrub and the teardown. Its caller holds the account-operation
    /// flag; a host-test seam drives it (the server call cannot run there).
    private func finishAccountDeletionLocally() async throws {
        // Task 11.08 (§9.4): the server deletion is authoritative, so the
        // deleted account's analytics identity resets now, before the local
        // scrub, the RevenueCat logout await or any later event can run. The
        // teardown's own boundary below is then a no-op.
        applyAnalyticsIdentityBoundary()
        // Task 11.01: see `signOut` — suspend the mirror across the wipe.
        widgetMirrorSuspendedForAccountBoundary = true
        do {
            try performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .all)
        } catch {
            // Phase 12 (12.00b.2-G fix round 1, P12-006): no marker means no
            // step ran, and nothing on disk says the deletion is pending.
            if !repository.isAccountScrubPending {
                recordAccountDeletionPendingWithoutMarker()
            }
            // The server-side deletion is already authoritative. Hide all
            // in-memory account state until cleanup can be retried locally.
            persistenceWritesBlocked = true
            persistenceBlockReason = .accountScrub
            persistenceBlockDetail = nil
            markAccountScrubBlocked(scope: .all, operation: "deleteAccount")
            applyEmptySnapshot()
            throw NativeAccountSignOutError.localScrubFailed
        }
        await subscriptionService.logOut()
        applyCompletedSignOutState()
        NativeGoogleSignInProvider.clearLocalCredential()
        // Task 11.05: see `signOut` — reloaded right after the wipe.
    }

    func retryAccountScrub() {
        // Phase 12 (12.00b.2-G fix round 1, P12-006): a deletion recorded
        // without its marker is pending too; it used to take this branch and
        // unblock without scrubbing.
        guard repository.isAccountScrubPending || accountDeletionPendingWithoutMarker else {
            isAccountScrubBlocked = false
            accountScrubBlockedScope = nil
            // Final review 1a/1b: a pending switch/recovery boundary step.
            retryPendingBoundarySteps()
            scheduleWidgetMirrorRefresh()
            return
        }
        // Phase 12 (12.00b.2-G fix round 1, R31): the pending scrub is a
        // boundary for a suspended identity check too.
        accountBoundaryGeneration &+= 1
        var scope: Canonical.SnapshotRepository.AccountScrubScope? = accountDeletionPendingWithoutMarker ? .all : nil
        do {
            // P12-006: the marker first, so a step that fails below leaves it
            // pending as usual (and a marker that still cannot be written
            // leaves the deletion as it was).
            if accountDeletionPendingWithoutMarker {
                try repository.beginAccountScrub(scope: .all)
            }
            // Phase 12 (12.00b.2-G, Task 9b review M2): read once. A marker
            // that cannot be read throws before any step runs, so an unknown
            // scope is never finished as a sign-out; the scrub stays pending.
            let pendingScope = try pendingAccountScrubScope() ?? .live
            scope = pendingScope
            try scrubWidgetAccountState()
            switch pendingScope {
            case .live: try repository.removeLiveAccountData()
            case .all: try repository.removeAllAccountData()
            }
            // Phase 12 (12.00b.2-G, P12-004): the shared list, which now
            // includes the pending schedule/booking work this path skipped.
            try removeAccountScrubStores()
            switch pendingScope {
            case .live: try secureSettingsStore.clearAccountValues()
            case .all:
                try secureSettingsStore.clearAllValues()
                try eraseLegacySourcesForDeletedAccount()
            }
            try repository.finishAccountScrub()
            accountDeletionPendingWithoutMarker = false
            isAccountScrubBlocked = false
            accountScrubBlockedScope = nil
            // Phase 12 (L286.4): a switch/recovery step still pending (the
            // AI-key wipe) is retried with the scrub, not left for a sign-in.
            retryPendingBoundarySteps()
            applyCompletedSignOutState()
            NativeGoogleSignInProvider.clearLocalCredential()
            // Task 11.05: widgets were reloaded right after the App Group
            // wipe inside `scrubWidgetAccountState()`.
        } catch {
            markAccountScrubBlocked(scope: scope, operation: "retry")
            migrationMessage = scope == .all
                ? "Account deletion cleanup is still incomplete. No local account data was opened."
                : "Sign-out cleanup is still incomplete. No local account data was opened."
        }
    }

    /// The pending account scrub's scope: `.all` for a deletion recorded
    /// without its marker (P12-006), whatever a marker says; otherwise the
    /// marker's (nil when none is pending; an unreadable one throws, M2).
    private func pendingAccountScrubScope() throws -> Canonical.SnapshotRepository.AccountScrubScope? {
        if accountDeletionPendingWithoutMarker { return .all }
        return try repository.pendingAccountScrubScope
    }

    /// Phase 12 (12.00b.2-G fix round 1, P12-006): the deletion's second
    /// record, as `recordBoundaryStepPending` does for a boundary step. If the
    /// Keychain write fails too, it is held in memory only: Retry and scene
    /// activation still finish it, a relaunch first does not (counted, and
    /// logged with a stage code).
    private func recordAccountDeletionPendingWithoutMarker() {
        accountDeletionPendingWithoutMarker = true
        // R31: a boundary for a suspended identity check, as the scrub's own
        // marker is (`performLocalAccountScrub`).
        accountBoundaryGeneration &+= 1
        do { try secureSettingsStore.recordAccountDeletionScrub() } catch {
            countAccountDeletionRecordFailure(stage: "record-write")
        }
    }

    /// Phase 12 (12.00b.2-G fix round 1, P12-006): reads the deletion's
    /// Keychain record. An unreadable record is not taken as pending (every
    /// launch reads it, and the snapshot it guards is unreadable in the same
    /// before-first-unlock window); scene activation re-reads it.
    private func loadAccountDeletionRecord() {
        do {
            if try secureSettingsStore.isAccountDeletionScrubRecorded() {
                accountDeletionPendingWithoutMarker = true
            }
            accountDeletionRecordUnverified = false
        } catch {
            accountDeletionRecordUnverified = true
            countAccountDeletionRecordFailure(stage: "record-read")
        }
    }

    private func countAccountDeletionRecordFailure(stage: String) {
        boundaryStepRecordFailureCount = min(Self.boundaryStepFailureCap, boundaryStepRecordFailureCount + 1)
        Self.stageLogger.error("TradeReadyAccountBoundary stage=\(stage, privacy: .public) step=account-deletion-scrub")
    }

    /// Phase 12 (12.00b.2-G, Task 9b review M3): the blocked cleanup screen,
    /// with the scope it is finishing (nil reads as a sign-out).
    ///
    /// Phase 12 (12.02, P12-001/P12-006): the first blocked attempt of an
    /// episode reports `account-scrub/blocked/<live|all|unknown>` (plus
    /// `/without-marker` for a deletion recorded only in the Keychain), with
    /// the operation and the running attempt count. A retry that stays
    /// blocked does not report again; an unblocked cleanup re-arms it
    /// (`isAccountScrubBlocked`'s `didSet`). The scope is a code, never the
    /// marker's bytes.
    private func markAccountScrubBlocked(
        scope: Canonical.SnapshotRepository.AccountScrubScope?,
        operation: String
    ) {
        accountScrubBlockedCount = min(Self.boundaryStepFailureCap, accountScrubBlockedCount + 1)
        isAccountScrubBlocked = true
        accountScrubBlockedScope = scope
        guard !accountScrubBlockedReported else { return }
        accountScrubBlockedReported = true
        let scopeCode = scope?.rawValue ?? "unknown"
        let markerCode = repository.isAccountScrubPending ? "" : "/without-marker"
        reportError(
            ["code": "account-scrub/blocked/\(scopeCode)\(markerCode)", "message": "Account cleanup could not finish"],
            context: ["context": "accountScrub", "operation": operation, "count": accountScrubBlockedCount]
        )
    }

    /// Phase 12 (review M1): every scene activation retries the pending
    /// boundary steps. A step whose Keychain record was unreadable at launch
    /// (for example before first unlock) is re-read, so the owner's gates
    /// reopen without a tap, a sign-in or a relaunch; a pending step is
    /// re-run (it is idempotent). Nothing runs when nothing is pending.
    ///
    /// Phase 12 (12.00b.2-G, Task 9b review M3): a pending account scrub (a
    /// sign-out or deletion that a locked launch could not finish) is retried
    /// here too, through the same `retryAccountScrub` as the "Try cleanup
    /// again" button; a successful one retries the steps itself, a failed one
    /// leaves them, as the launch does. Never while a sign-out or deletion is
    /// running: that call owns the marker and reports its own result.
    func retryAccountBoundaryCleanupOnActivation() {
        // Phase 12 (12.00b.2-G fix round 1, P12-006): a deletion record that
        // was unreadable at launch is re-read; a recorded one is retried here.
        if accountDeletionRecordUnverified { loadAccountDeletionRecord() }
        if repository.isAccountScrubPending || accountDeletionPendingWithoutMarker {
            guard !authenticationOperationInFlight else { return }
            retryAccountScrub()
            return
        }
        retryPendingBoundarySteps()
    }

    private func applyCompletedSignOutState() {
        // Phase 12 (12.00b.2-G fix round 1, R31): a completed sign-out or
        // deletion is never overwritten by a suspended identity check.
        accountBoundaryGeneration &+= 1
        // Phase 12 (12.02): the next account starts a new throttle streak
        // and pending-age episode; the counts stay for the support report.
        syncMonitor.resetForAccountBoundary()
        // Task 11.08 (§9.4): sign-out, completed deletion, the paywall
        // sign-out and a retried scrub all end here — reset first.
        applyAnalyticsIdentityBoundary()
        syncCoordinator?.reset()
        // Task 10.09 (B1): account boundary — clear the owner-scoped cached
        // snapshot only; observer registrations survive (the 11.01 widget
        // mirror registers once at launch and must keep receiving the next
        // owner's publishes after sign-in, not just the one active at
        // registration time).
        derivedStatePublisher.reset()
        isAccountScrubBlocked = false
        accountScrubBlockedScope = nil
        persistenceWritesBlocked = false
        persistenceBlockReason = nil
        persistenceBlockDetail = nil
        applyEmptySnapshot()
        selectedTab = .today
        todaySelectedDate = NativeTodayBriefing.todayDateString(now: Date())
        clearDeepLinkRouteState()
        widgetActionReplayDiagnostics = NativeWidgetActionReplayDiagnostics()
        migratedAccountState = nil
        dismissedCustomerDuplicatePairKeys = []
        reviewRequestRecords = []
        pendingCustomerMergeUndo = nil
        pendingRecordDeleteUndo = nil
        rejectedChanges = []
        isMigratedLocalOwnerVerified = false
        migratedAccountBinding = nil
        verifiedAccountBinding = nil
        authenticatedUserSubject = nil
        authenticatedEmail = nil
        initialSyncCompletedSubject = nil
        initialSyncGateGeneration &+= 1
        postSubscriptionDestination = nil
        subscriptionGateGeneration &+= 1
        subscriptionOperationInFlight = false
        isSubscriptionTrialing = false
        stripeConnectStatus = nil
        stripeConnectLoading = false
        stripeConnectError = nil
        deepLinkedOutreachInvoiceID = nil
        authenticatedAccountState = .noMigratedSession
        authenticationGateState = .signedOut
        // Task 10.12 (S4/D4/D5): account boundary — wipe the mute/checklist
        // stores and their in-memory published state (see `useAnotherAccount`'s
        // identical comment).
        resetTodayOwnerState()
    }

    /// Task 11.05 (W4, contract §3.1): the widget/Siri part of every account
    /// scrub (sign-out, deletion, retry, launch recovery). It wipes the App
    /// Group suite under the shared lock, then reloads widget timelines AT
    /// ONCE — before any later scrub step or `await` — so no widget keeps
    /// rendering the scrubbed owner's cached timeline while the boundary
    /// completes, and no later owner can read it. It then removes the
    /// app-private replay claims and quarantine files, which hold the scrubbed
    /// owner's actions. A failure leaves the scrub marker pending (retried).
    ///
    /// Final review 1a: it runs under its own durable `.widgetScrub` marker,
    /// because the account switch retains the workspace and so has no
    /// account-scrub marker. While it is pending the mirror has no owner and
    /// replay is closed; `retryPendingBoundarySteps` retries it.
    private func scrubWidgetAccountState() throws {
        try runDurableBoundaryStep(.widgetScrub) {
            try appGroupAccountScrubber.scrub()
            widgetTimelineReloader.reloadAllTimelines()
            try widgetActionReplayTransport?.removeAllAccountClaims()
        }
    }

    /// Final review 1a/1b: the account-scrub marker pattern
    /// (`beginAccountScrub` … `finishAccountScrub`) for one boundary step that
    /// runs outside the full scrub. The step is recorded as pending before it
    /// runs and the record is removed only after it succeeds.
    ///
    /// Phase 12 (L286.5b): the record is the file marker; if that cannot be
    /// written, the step is held in memory AND recorded in the Keychain, so a
    /// failure of the step itself still survives a relaunch. Only a failure of
    /// all three (file, Keychain, step) followed by a relaunch before any retry
    /// loses it, and each of those failures is counted and logged.
    private func runDurableBoundaryStep(
        _ step: Canonical.SnapshotRepository.BoundaryStep,
        _ body: () throws -> Void
    ) throws {
        defer { refreshAccountBoundaryCleanupPending() }
        recordBoundaryStepPending(step)
        try body()
        finishBoundaryStepRecords(step)
    }

    private func recordBoundaryStepPending(_ step: Canonical.SnapshotRepository.BoundaryStep) {
        do {
            try repository.beginBoundaryStep(step)
            return
        } catch {
            boundaryStepMarkerWriteFailureCount = min(Self.boundaryStepFailureCap, boundaryStepMarkerWriteFailureCount + 1)
            Self.stageLogger.error("TradeReadyAccountBoundary stage=marker-write step=\(step.rawValue, privacy: .public)")
        }
        boundaryStepsPendingInMemory.insert(step)
        do { try secureSettingsStore.recordBoundaryStep(step) } catch {
            countBoundaryStepRecordFailure(stage: "record-write", step)
        }
    }

    private func finishBoundaryStepRecords(_ step: Canonical.SnapshotRepository.BoundaryStep) {
        if boundaryStepsPendingInMemory.contains(step) || boundaryStepsUnverified.contains(step) {
            do {
                try secureSettingsStore.removeBoundaryStepRecord(step)
                boundaryStepsPendingInMemory.remove(step)
                boundaryStepsUnverified.remove(step)
            } catch {
                // Still recorded: the step stays pending and the retry reruns
                // it (idempotent) until the record can be removed.
                countBoundaryStepRecordFailure(stage: "record-remove", step)
            }
        }
        // A marker that cannot be removed stays pending: the retry reruns the
        // (idempotent) step and it keeps failing closed meanwhile.
        try? repository.finishBoundaryStep(step)
    }

    /// Phase 12 (L286.5b): reads the step's Keychain record. A recorded step
    /// is pending; an unreadable record leaves the step unverified (gated as
    /// pending, body not run) until a retry can read it.
    private func loadBoundaryStepRecord(_ step: Canonical.SnapshotRepository.BoundaryStep) {
        do {
            if try secureSettingsStore.isBoundaryStepRecorded(step) {
                boundaryStepsPendingInMemory.insert(step)
            }
            boundaryStepsUnverified.remove(step)
        } catch {
            boundaryStepsUnverified.insert(step)
            countBoundaryStepRecordFailure(stage: "record-read", step)
        }
    }

    private func countBoundaryStepRecordFailure(stage: String, _ step: Canonical.SnapshotRepository.BoundaryStep) {
        boundaryStepRecordFailureCount = min(Self.boundaryStepFailureCap, boundaryStepRecordFailureCount + 1)
        Self.stageLogger.error(
            "TradeReadyAccountBoundary stage=\(stage, privacy: .public) step=\(step.rawValue, privacy: .public)"
        )
    }

    private func isBoundaryStepPending(_ step: Canonical.SnapshotRepository.BoundaryStep) -> Bool {
        boundaryStepsPendingInMemory.contains(step)
            || boundaryStepsUnverified.contains(step)
            || repository.isBoundaryStepPending(step)
    }

    private func refreshAccountBoundaryCleanupPending() {
        let pending = Canonical.SnapshotRepository.BoundaryStep.allCases.contains { isBoundaryStepPending($0) }
        if isAccountBoundaryCleanupPending != pending { isAccountBoundaryCleanupPending = pending }
    }

    /// Final review 1a/1b: retries every pending boundary step — at launch,
    /// from `retryAccountScrub` (both branches, Phase 12 L286.4) and before an
    /// interactive sign-in or sign-up binds the next owner. A step that fails
    /// again stays pending (still fail-closed). A new step adds a
    /// `BoundaryStep` case and its body to the switch below.
    private func retryPendingBoundarySteps() {
        defer { refreshAccountBoundaryCleanupPending() }
        for step in Canonical.SnapshotRepository.BoundaryStep.allCases {
            if boundaryStepsUnverified.contains(step) { loadBoundaryStepRecord(step) }
            // Still unverified: stay closed without running on a guess.
            guard boundaryStepsPendingInMemory.contains(step) || repository.isBoundaryStepPending(step) else { continue }
            switch step {
            case .widgetScrub:
                // Timelines are reloaded inside it, right after the wipe.
                do { try scrubWidgetAccountState() } catch {
                    print("TradeReadyAccountBoundary stage=retry-widget-scrub")
                }
            case .aiKeyWipe:
                wipeAIProviderKeysForAccountBoundary()
            case .rejectedChangesScrub:
                scrubRejectedChangesForAccountBoundary()
            }
        }
    }

    /// Phase 12 (12.00b.2-F, P12-001, charter §5.4 G6-Q1): the last step of a
    /// permanent-deletion (`.all`) scrub, at launch recovery, `retryAccountScrub`
    /// and `performLocalAccountScrub`. It runs after everything else is wiped
    /// and before the scrub marker is cleared, so a failure (a locked Keychain)
    /// leaves the deletion pending: the launch migration does not run while it
    /// is pending, and the next launch or Retry erases again. A sign-out never
    /// erases: G6 keeps the sources for a live account's Expo rollback build.
    private func eraseLegacySourcesForDeletedAccount() throws {
        try legacySourceEraser?.erase()
    }

    /// Phase 12 (12.00b.2-G, P12-004): the account-owned stores every account
    /// scrub clears, in one list for all three paths (`performLocalAccountScrub`,
    /// `retryAccountScrub` and the launch recovery), so a store added later
    /// cannot be missed by one of them. It runs after the snapshot removal and
    /// before the Keychain step, under the scrub marker: a failure leaves the
    /// scrub pending, and the next launch or Retry runs the whole list again.
    private func removeAccountScrubStores() throws {
        // Pending local changes belong to the account being scrubbed. Removing
        // the queue before the scrub marker is cleared means a failure here
        // leaves the marker pending so the next launch retries, and no other
        // account can ever inherit and push this account's queued writes.
        try mutationQueue.removeAll()
        // Phase 12 (12.00b.1): refused changes are this account's queued
        // writes too; they go with the queue, under the same marker.
        try rejectedChangeStore.removeAll()
        try syncBackfill.removeAll()
        try syncCursorStore.removeAll()
        try customerDuplicateDismissalStore.removeAll()
        try reviewRequestStore.removeAll()
        try reminderPromptStore.removeAll()
        try insightMuteStore.removeAll()
        try setupChecklistStore.removeAll()
        // Phase 9 task 9.08: device-local import history is per-account
        // operational metadata and must not leak across the account boundary.
        try removeImportHistory()
        // Phase 8 task 8.08: owner-bound capability work (staged link mirrors,
        // reschedule proofs) belongs to the scrubbed account and can never be
        // inherited by the next one.
        try pendingScheduleBookingWorkStore().removeAll()
    }

    private func performLocalAccountScrub(
        sessionStore: NativeKeychainSecureSettingsStore,
        scope: Canonical.SnapshotRepository.AccountScrubScope
    ) throws {
        try repository.beginAccountScrub(scope: scope)
        // Phase 12 (12.00b.2-G fix round 1, R31): from here the account's
        // local data is going, so a suspended identity check drops its result
        // (it could otherwise resume during `signOut`'s or `deleteAccount`'s
        // RevenueCat logout await, before their teardown).
        accountBoundaryGeneration &+= 1
        try scrubWidgetAccountState()
        switch scope {
        case .live: try repository.removeLiveAccountData()
        case .all: try repository.removeAllAccountData()
        }
        try removeAccountScrubStores()
        switch scope {
        case .live: try sessionStore.clearAccountValues()
        case .all:
            try sessionStore.clearAllValues()
            try eraseLegacySourcesForDeletedAccount()
        }
        try repository.finishAccountScrub()
        // Phase 12 (review M1): a switch/recovery step still pending is run
        // now (its data is already gone), so the sign-in screen that follows
        // shows no cleanup banner for it.
        retryPendingBoundarySteps()
    }

    private func configuredAuthentication() throws -> (
        client: NativeSupabaseEmailAuthClient,
        activator: NativeAuthenticatedIdentityActivator
    ) {
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else { throw NativeSupabaseAuthError.invalidConfiguration }
        let verifier = NativeSupabaseAuthenticatedIdentityVerifier(
            supabaseURL: supabaseURL,
            publishableKey: publishableKey
        )
        let activator: NativeAuthenticatedIdentityActivator
        if let existing = authenticatedIdentityActivator {
            activator = existing
        } else {
            let created = NativeAuthenticatedIdentityActivator(
                snapshotURL: fileURL,
                sessionStore: secureSettingsStore,
                verifier: verifier,
                refresher: verifier
            )
            authenticatedIdentityActivator = created
            activator = created
        }
        return (
            NativeSupabaseEmailAuthClient(
                supabaseURL: supabaseURL,
                publishableKey: publishableKey
            ),
            activator
        )
    }

    private func activateCustomerDuplicateDismissals(
        accountBinding: String,
        migratedKeys: [String]?
    ) {
        do {
            let stored = try customerDuplicateDismissalStore.load(for: accountBinding)
            var merged = Set(stored)
            merged.formUnion(migratedKeys ?? [])
            if merged != Set(stored) {
                try customerDuplicateDismissalStore.save(merged, for: accountBinding)
            }
            dismissedCustomerDuplicatePairKeys = merged
        } catch {
            dismissedCustomerDuplicatePairKeys = []
            migrationMessage = "Duplicate-suggestion history could not be opened safely. Customer records are unchanged."
        }
    }

    private func activateReviewRequests(
        accountBinding: String,
        migrated: [NativeTypedAccountState.ReviewRequest]?
    ) {
        do {
            let seeded = (migrated ?? []).map { review in
                NativeReviewRequestRecord(
                    jobId: review.jobId,
                    customerId: review.customerId,
                    customerName: review.customerName,
                    customerPhone: review.customerPhone,
                    customerEmail: review.customerEmail,
                    scheduledAt: review.scheduledAt,
                    sentAt: review.sentAt
                )
            }
            reviewRequestRecords = try reviewRequestStore.mergeSeeded(seeded, for: accountBinding)
        } catch {
            reviewRequestRecords = []
            migrationMessage = "Review-request history could not be opened safely. Pending review reminders were cleared."
        }
    }

    /// Task 10.05 (N1): adopts the migrated `invoiceReminderPromptShown` seed
    /// into `NativeReminderPromptStore` once at activation, the same pattern
    /// as `activateReviewRequests` above. A live owner flag always wins — the
    /// store's `mergeSeeded` can only ever move `false` to `true`, never the
    /// reverse, so a prompt already answered on this device is never re-armed
    /// by an older seed. Failure degrades silently (no `migrationMessage`):
    /// worst case is one extra contextual ask, never data loss.
    private func activateReminderPromptFlag(
        accountBinding: String,
        migratedShown: Bool?
    ) {
        _ = try? reminderPromptStore.mergeSeeded(migratedShown ?? false, for: accountBinding)
    }

    /// Task 10.12 (S4): adopts the migrated `insightMutes` seed into
    /// `NativeInsightMuteStore` once at activation, the same pattern as
    /// `activateReviewRequests`. With no seed (the common case) this is
    /// simply "load the current owner mutes or fail closed" — `mergeSeeded`
    /// still calls through `load`, so an unreadable/corrupt file surfaces the
    /// same way whether or not a migration seed exists.
    ///
    /// Fail-closed (brief step 5, decision row 17): on any failure,
    /// `insightMutes` is set to `nil` — `NativeInsightsCardPolicy` reads that
    /// as "render only the five non-muteable kinds, no mute controls" rather
    /// than an unfiltered list that could resurrect a dismissed row.
    private func activateInsightMutes(
        accountBinding: String,
        migrated: [NativeTypedAccountState.InsightMute]?
    ) {
        do {
            let seeded = (migrated ?? []).map { mute in
                NativeInsightMute(
                    id: mute.id,
                    mutedAt: mute.mutedAt ?? ISO8601DateFormatter.nativeFractional.string(from: Date()),
                    until: mute.until
                )
            }
            insightMutes = try insightMuteStore.mergeSeeded(seeded, for: accountBinding)
        } catch {
            insightMutes = nil
            logInsightOrChecklistFailClosedDiagnosticOnce(store: "insightMutes")
        }
    }

    /// Task 10.12 (D4/D5): adopts the migrated `setupChecklistState` seed
    /// into `NativeSetupChecklistStore` once at activation.
    ///
    /// Fail-closed (brief step 5, decision row 17): on any failure,
    /// `setupChecklistState` is set to `nil` — the checklist card hides
    /// entirely, and the insights card's shared `isSetupComplete` gate reads
    /// `nil` as "incomplete" rather than guessing.
    private func activateSetupChecklist(
        accountBinding: String,
        migrated: NativeTypedAccountState.SetupChecklistState?
    ) {
        do {
            var done: [String: Bool] = [:]
            if let migratedDone = migrated?.done {
                if migratedDone.contact == true { done[NativeSetupTaskID.contact.rawValue] = true }
                if migratedDone.logo == true { done[NativeSetupTaskID.logo.rawValue] = true }
                if migratedDone.rate == true { done[NativeSetupTaskID.rate.rawValue] = true }
                if migratedDone.stripe == true { done[NativeSetupTaskID.stripe.rawValue] = true }
                if migratedDone.notifications == true { done[NativeSetupTaskID.notifications.rawValue] = true }
            }
            let seed = NativeSetupChecklistState(
                dismissed: migrated?.dismissed,
                done: done.isEmpty ? nil : done,
                sampleTourDone: migrated?.sampleTourDone
            )
            setupChecklistState = try setupChecklistStore.mergeSeeded(seed, for: accountBinding)
        } catch {
            setupChecklistState = nil
            logInsightOrChecklistFailClosedDiagnosticOnce(store: "setupChecklistState")
        }
    }

    /// `os.Logger` sink for the fail-closed diagnostics below. Category
    /// mirrors the two owner-bound stores this task added; no other AppStore
    /// diagnostic sink existed to reuse (fix round 1, I6).
    private static let diagnosticsLogger = Logger(subsystem: "com.tradeready.native", category: "today-owner-state")
    /// Phase 12 final review (M6): the Phase 12 `stage=` diagnostics. `print`
    /// never reaches the unified log in a TestFlight or App Store build; this
    /// does (Console, a sysdiagnose). Every interpolated value is an integer,
    /// a Bool or a fixed code (a stage, step, table or reason name), marked
    /// public so a Release build shows it instead of `<private>`.
    private static let stageLogger = Logger(subsystem: "com.tradeready.native", category: "diagnostics")

    /// One bounded, non-PII diagnostic per session per code (brief step 5,
    /// fix round 1 I6) — never the record contents, never the account
    /// binding, just a fixed code identifying which store/operation
    /// degraded, so a persistently-corrupt file does not spam. Emitted
    /// through `os.Logger` (survives Release builds, unlike the prior
    /// `#if DEBUG print(...)`) and appended to `recordedDiagnostics` so tests
    /// can observe both the emission and the once-per-session dedup without
    /// scraping unified logging.
    private func logInsightOrChecklistFailClosedDiagnosticOnce(store: String) {
        guard !loggedFailClosedDiagnostics.contains(store) else { return }
        loggedFailClosedDiagnostics.insert(store)
        recordedDiagnostics.append(store)
        Self.diagnosticsLogger.error("today owner-state store degraded fail-closed: \(store, privacy: .public)")
    }

    /// Task 10.12 (S4/D4/D5), extracted in fix round 1 (I8): the one shared
    /// account-boundary reset for the insight-mute/setup-checklist
    /// owner-bound stores and their dependent one-shot/mirror state — wipes
    /// the in-memory published state and the on-disk files so the next
    /// account never inherits a dismissal, snooze, or "used once" flag.
    /// Called at every real sign-out/account-switch path (`useAnotherAccount`,
    /// `applyCompletedSignOutState`, `applyRecoverySignedOutState`) so this
    /// logic exists exactly once instead of three times.
    ///
    /// A `removeAll()` failure is now routed to the same fail-closed
    /// diagnostic as an unreadable store (I6) rather than silently dropped
    /// via bare `try?`. The in-memory state is cleared either way — worst
    /// case a stale on-disk file for the previous owner lingers, but it can
    /// never be read back in for a *different* account because both stores
    /// fail closed on an account-binding mismatch.
    private func resetTodayOwnerState() {
        insightMutes = nil
        setupChecklistState = nil
        pendingCoachPrefill = nil
        pendingSettingsDestination = nil
        // Task 10.13 fix round 1: belt-and-suspenders alongside the
        // `ownerBinding` check already in `NativeCoachConversationTicket` —
        // a coach reply in flight across this account boundary is invalid
        // by generation even if a future refactor ever let `ownerBinding`
        // alone through.
        bumpCoachConversationGeneration()
        do {
            try insightMuteStore.removeAll()
        } catch {
            logInsightOrChecklistFailClosedDiagnosticOnce(store: "insightMutesRemoveAllFailed")
        }
        do {
            try setupChecklistStore.removeAll()
        } catch {
            logInsightOrChecklistFailClosedDiagnosticOnce(store: "setupChecklistRemoveAllFailed")
        }
        lastShownInsightIDsKey = ""
        notificationsGranted = false
    }

    private func applyAuthenticatedIdentityOutcome(
        _ outcome: NativeAuthenticatedIdentityActivationOutcome,
        email: String?,
        gateOverride: NativeAuthenticationGateState? = nil,
        activateConsumers: Bool = true,
        allowUnboundWorkspaceAdoption: Bool = false
    ) {
        // Phase 12 (12.00b.2-I fix round 1, review I1): an activation or
        // sign-in begins here. The consumer block below and the subscription
        // gate's exit start recovery passes before this period's pull lands,
        // so no mirror is merged until a pull commits again.
        scheduleBookingRecoveryPullMark = nil
        // Phase 12 (12.00b.2-K, P12-016): likewise, no booking converts until
        // this period's pull has committed.
        bookingIntakePullMark = nil
        // Invalidates any same-account entitlement request that was suspended
        // while a stronger auth/recovery/onboarding state transition completed.
        subscriptionGateGeneration &+= 1
        initialSyncGateGeneration &+= 1
        migratedAccountState = outcome.typedAccountState
        isMigratedLocalOwnerVerified = outcome.localOwnerVerified
        migratedAccountBinding = outcome.accountBinding
        verifiedAccountBinding = outcome.verifiedAccountBinding
        authenticatedUserSubject = outcome.verifiedUserSubject
        authenticatedEmail = email ?? outcome.verifiedEmail ?? authenticatedEmail
        // Task 11.08 (§9.4): identify the verified Supabase user id before
        // any gate transition below can emit an event for this owner. A
        // different id than the last identified one resets first.
        applyAnalyticsIdentityVerified(outcome.verifiedUserSubject)
        authenticatedAccountState = switch outcome.accountState {
        case .noAuxiliaryArtifact, .noAccountState: .verified
        case .staged: .verifiedAndStaged
        case .ownerMismatch: .ownerMismatch
        }
        let mayActivateLocalConsumers = outcome.accountState != .ownerMismatch
            && (allowUnboundWorkspaceAdoption
                || outcome.localOwnerVerified
                || !hasLocalAccountData
                || hasPersistedWorkspace(binding: outcome.verifiedAccountBinding))
        if mayActivateLocalConsumers {
            activateCustomerDuplicateDismissals(
                accountBinding: outcome.verifiedAccountBinding,
                migratedKeys: outcome.typedAccountState?.dismissedDuplicatePairs
            )
            activateReviewRequests(
                accountBinding: outcome.verifiedAccountBinding,
                migrated: outcome.typedAccountState?.reviewRequests
            )
            activateReminderPromptFlag(
                accountBinding: outcome.verifiedAccountBinding,
                migratedShown: outcome.typedAccountState?.invoiceReminderPromptShown
            )
            activateInsightMutes(
                accountBinding: outcome.verifiedAccountBinding,
                migrated: outcome.typedAccountState?.insightMutes
            )
            activateSetupChecklist(
                accountBinding: outcome.verifiedAccountBinding,
                migrated: outcome.typedAccountState?.setupChecklistState
            )
        } else {
            dismissedCustomerDuplicatePairKeys = []
            reviewRequestRecords = []
            pendingCustomerMergeUndo = nil
            pendingRecordDeleteUndo = nil
            insightMutes = nil
            setupChecklistState = nil
        }
        if let gateOverride {
            authenticationGateState = gateOverride
        } else if outcome.accountState == .ownerMismatch {
            authenticationGateState = .accountMismatch
        } else {
            let mayAdoptWorkspace = allowUnboundWorkspaceAdoption
                || isMigratedLocalOwnerVerified
                || !hasLocalAccountData
            guard mayAdoptWorkspace else {
                authenticatedAccountState = .ownerMismatch
                authenticationGateState = .accountMismatch
                return
            }
            let offlineWorkspaceReady = outcome.verificationSource.isOfflineFallback
                && hasPersistedWorkspace(binding: outcome.verifiedAccountBinding)
            if initialSyncCompletedSubject == outcome.verifiedUserSubject
                || offlineWorkspaceReady
            {
                if offlineWorkspaceReady {
                    markInitialSyncCompleted(subject: outcome.verifiedUserSubject)
                }
                // Returning-user app open with a previously completed sync:
                // mirror RN's session-mount generation on the local snapshot.
                // (First syncs generate in the initial-sync task above, and
                // every later sync generates in the pull hook.) Fix round 3:
                // after the gate advances, since generation is gated on it.
                // Phase 12.00b.2-E (L237.d): RN's session-mount `useEffect`
                // calls `checkAndGenerateRecurringJobs` AND
                // `checkAndGenerateRecurringInvoices` together
                // (`context/AuthContext.tsx:101-104`) — this path was missing
                // the invoice half.
                advancePastInitialSync(
                    outcome: outcome,
                    allowUnboundWorkspaceAdoption: !outcome.verificationSource.isOfflineFallback
                        && allowUnboundWorkspaceAdoption
                )
                refreshRecurringJobs()
                refreshRecurringInvoices()
                // Fix round 2 (G5): RN runs its Square token heal on every
                // sign-in (`App.tsx`); gated like generation, after the gate.
                scrubLegacySquareToken()
            } else {
                beginInitialSyncGate(
                    outcome: outcome,
                    allowUnboundWorkspaceAdoption: allowUnboundWorkspaceAdoption
                )
            }
        }
        if activateConsumers, case .signedIn = authenticationGateState {
            consumePendingDeepLinks()
            replayVerifiedWidgetActionsIfPossible()
            // Phase 12 (12.00b.2-K fix round 1, review M4): no booking intake
            // here. This call cleared the pull mark above with nothing to set
            // it since, so a pass could never convert; the activation's
            // `performForegroundRefresh` does, after its pull.
            // Phase 12 (12.00b.2-I, P12-013): unfinished booking/portal work.
            startScheduleBookingRecoveryIfPossible()
        }
    }

    private func beginInitialSyncGate(
        outcome: NativeAuthenticatedIdentityActivationOutcome,
        allowUnboundWorkspaceAdoption: Bool
    ) {
        NativeSupabaseInitialSyncService.clearDiagnostic()
        guard !persistenceWritesBlocked else {
            let reason = persistenceBlockReason?.rawValue ?? "unknown"
            let detail = persistenceBlockDetail.map { "/\($0)" } ?? ""
            authenticationGateState = .initialSyncUnavailable(
                message: "Local data must be recovered before cloud data can be safely applied.\n\nDiagnostic code: preflight/local-recovery/\(reason)\(detail)"
            )
            reportInitialSyncUnavailable(code: "preflight/local-recovery/\(reason)\(detail)", operation: "preflight")
            return
        }
        guard let service = initialSyncServiceIfConfigured(),
              let sessionBytes = try? secureSettingsStore.readSupabaseSession()
        else {
            authenticationGateState = .initialSyncUnavailable(
                message: NativeInitialSyncError.invalidConfiguration.localizedDescription
                    + "\n\nDiagnostic code: preflight/configuration-or-session"
            )
            reportInitialSyncUnavailable(code: "preflight/configuration-or-session", operation: "preflight")
            return
        }
        initialSyncGateGeneration &+= 1
        let generation = initialSyncGateGeneration
        let subject = outcome.verifiedUserSubject
        let localSnapshot = snapshot
        // Phase 12 (12.00b.2-K, P12-016): the account generation the pull
        // starts under, for the pull marks below (the recovery mark too since
        // the final review, M1), and the period (`pullMarkPeriod`).
        let boundaryGeneration = accountBoundaryGeneration
        let markPeriod = pullMarkPeriod
        authenticationGateState = .initialSyncLoading
        // Task 11.12: an InitialSync signpost from the gate to the commit.
        // Ending is idempotent: the explicit ends below win, and the deferred
        // end only closes a pass that a stale account or generation dropped.
        let initialSync = NativePerformanceMetrics.shared.begin(.initialSync)

        Task { [weak self] in
            defer { NativePerformanceMetrics.shared.end(initialSync, outcome: .skipped) }
            do {
                let pulled = try await service.pullWithWatermarks(
                    sessionBytes: sessionBytes,
                    expectedUserSubject: subject,
                    localSnapshot: localSnapshot
                )
                let candidate = pulled.snapshot
                guard let self,
                      subject == self.authenticatedUserSubject,
                      generation == self.initialSyncGateGeneration
                else { return }

                try self.commitSnapshot(candidate)
                // Phase 12 final review (M3): this commit saves no delta
                // cursor, so booking intake guards with these watermarks
                // until a delta pull has moved past them.
                self.initialSyncWatermarks = (boundaryGeneration, subject, pulled.watermarks)
                NativePerformanceMetrics.shared.end(initialSync, count: self.performanceRecordCount())
                self.markScheduleBookingRecoveryPullCommitted(
                    subject: subject, generation: boundaryGeneration, period: markPeriod
                )
                self.markBookingIntakePullCommitted(subject: subject, generation: boundaryGeneration, period: markPeriod)
                self.markInitialSyncCompleted(subject: subject)
                self.advancePastInitialSync(
                    outcome: outcome,
                    allowUnboundWorkspaceAdoption: allowUnboundWorkspaceAdoption
                )
                // Fix round 3: generation waits for the gate to advance (it is
                // gated on the post-initial-sync state). Synchronous, so no
                // suspension is added before the publish below.
                self.runRecurringGenerationAfterInitialSync()
                // Fix round 2 (G5): the first sign-in's synced settings may
                // carry a Square token; heal it before anything publishes.
                self.scrubLegacySquareToken()
                // Task 10.09 (B1) fix round 2: the initial full sync's commit
                // above never routes through `pullDeltaIfPossible` — it is
                // its own, structurally separate committed canonical sync
                // commit (`service.pull`, not `service.pullDelta`) — so it
                // needs its own publish call, not a ride on
                // `markInitialSyncCompleted`'s later fire-and-forget delta
                // pull (which is a second, later commit of its own).
                //
                // Published AFTER the gate work above (not before) on
                // purpose: `publish` awaits `notifySynchronize`, a genuine
                // suspension point in production. A publish placed before
                // `markInitialSyncCompleted`/`advancePastInitialSync` would
                // let a sign-out / useAnotherAccount / recovery-cancel /
                // foreground-reactivation that lands during that await race
                // ahead of the gate work: `publish` would correctly bail on
                // its own owner guard, but the *stale* task would then
                // resume and stamp `initialSyncCompletedSubject`, kick a
                // backfill and `syncNowAndWait`, and let
                // `advancePastInitialSync` overwrite
                // `authenticationGateState` from the outcome captured before
                // the race — all for a subject/generation that is no longer
                // current. Publishing last keeps the gate-advancement
                // sequence free of any new suspension between its own
                // subject/generation guard (above) and its completion, so
                // there is nothing for a concurrent identity change to race
                // against there. The publish itself still checks the owner
                // binding inside `derivedStatePublisher.publish`, so it
                // safely no-ops if the account changed between the gate
                // finishing and this line running.
                // Final-review I6: `derivedStatePublishBinding`, not the bare
                // `verifiedAccountBinding` — `advancePastInitialSync` may have
                // just ended in `.accountMismatch`/`.unavailable`, where
                // `snapshot` is pulled data merged into another owner's
                // workspace and must never reach an observer.
                if let binding = self.derivedStatePublishBinding, subject == self.authenticatedUserSubject {
                    await self.publishDerivedState(expectedOwnerBinding: binding)
                }
            } catch {
                NativePerformanceMetrics.shared.end(initialSync, outcome: .failed)
                guard let self,
                      subject == self.authenticatedUserSubject,
                      generation == self.initialSyncGateGeneration
                else { return }
                let message = (error as? NativeInitialSyncError)?.localizedDescription
                    ?? NativeInitialSyncError.unavailable.localizedDescription
                let diagnosticCode = NativeSupabaseInitialSyncService.lastDiagnosticCode
                    ?? "service/unknown"
                self.authenticationGateState = .initialSyncUnavailable(
                    message: message + "\n\nDiagnostic code: \(diagnosticCode)"
                )
                self.reportInitialSyncUnavailable(code: diagnosticCode, operation: "pull")
            }
        }
    }

    /// Phase 12 (12.02): RN `initialSync` (`reportError(err, {context:
    /// 'initialSync'})`). The gate's refusal, as the bounded diagnostic code
    /// its screen shows; "preflight" before the network, "pull" after it.
    private func reportInitialSyncUnavailable(code: String, operation: String) {
        reportError(
            ["code": code, "message": "Initial sync did not complete"],
            context: ["context": "initialSync", "operation": operation]
        )
    }

    /// The initial-sync service: the injected one (host tests), or one built
    /// from BuildEnvironment, or nil for an unconfigured build. Phase 12
    /// (12.00b.2-K fix round 1, review item 7): as `deltaSyncServiceIfConfigured`,
    /// so a host test runs the real initial-sync gate. The app injects none.
    private func initialSyncServiceIfConfigured() -> (any NativeInitialSyncServing)? {
        if let initialSyncService { return initialSyncService }
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else { return nil }
        return NativeSupabaseInitialSyncService(supabaseURL: supabaseURL, publishableKey: publishableKey)
    }

    private func advancePastInitialSync(
        outcome: NativeAuthenticatedIdentityActivationOutcome,
        allowUnboundWorkspaceAdoption: Bool
    ) {
        do {
            let document = try resolveOnboarding(
                binding: outcome.verifiedAccountBinding,
                imported: outcome.typedAccountState,
                allowUnboundWorkspaceAdoption: allowUnboundWorkspaceAdoption
            )
            switch document.stage {
            case .drafting, .personalizationCommit:
                authenticationGateState = .onboarding(document.draft)
            case .personalized, .sampleCommit, .freshCommit:
                beginSubscriptionGate(destination: .startingPoint(document.draft.trade))
            case .done:
                beginSubscriptionGate(destination: .signedIn)
            }
        } catch NativeOnboardingError.accountMismatch {
            authenticatedAccountState = .ownerMismatch
            authenticationGateState = .accountMismatch
        } catch {
            authenticatedAccountState = .unavailable
            authenticationGateState = .unavailable
        }
    }

    private func beginSubscriptionGate(
        destination: PostSubscriptionDestination,
        forceLoading: Bool = false
    ) {
        guard let subject = authenticatedUserSubject else {
            authenticationGateState = .unavailable
            return
        }
        postSubscriptionDestination = destination
        subscriptionGateGeneration &+= 1
        let generation = subscriptionGateGeneration
        let alreadyPastGate: Bool
        switch authenticationGateState {
        case .signedIn, .startingPoint: alreadyPastGate = true
        default: alreadyPastGate = false
        }
        if forceLoading || !alreadyPastGate {
            authenticationGateState = .subscriptionLoading
        }
        Task { [weak self] in
            await self?.resolveSubscriptionGate(for: subject, generation: generation)
        }
    }

    private func resolveSubscriptionGate(for subject: String, generation: UInt64) async {
        guard subject == authenticatedUserSubject,
              generation == subscriptionGateGeneration
        else { return }
        let resolution = await resolveNativeSubscriptionGate(
            appUserID: subject,
            apiKey: BuildEnvironment.revenueCatAPIKey,
            entitlementID: BuildEnvironment.revenueCatEntitlementID,
            service: subscriptionService
        )
        guard subject == authenticatedUserSubject,
              generation == subscriptionGateGeneration
        else { return }
        switch resolution {
        case .advance(let isTrialing):
            isSubscriptionTrialing = isTrialing
            advancePastSubscriptionGate()
        case .paywall(let offering):
            isSubscriptionTrialing = false
            authenticationGateState = .paywall(offering: offering, message: nil)
        case .paywallError(let message):
            isSubscriptionTrialing = false
            authenticationGateState = .paywall(
                offering: nil,
                message: message
            )
        }
    }

    private func advancePastSubscriptionGate() {
        guard let destination = postSubscriptionDestination else { return }
        postSubscriptionDestination = nil
        switch destination {
        case .startingPoint(let trade):
            authenticationGateState = .startingPoint(trade)
        case .signedIn:
            authenticationGateState = .signedIn(email: authenticatedEmail)
            consumePendingDeepLinks()
            replayVerifiedWidgetActionsIfPossible()
            // Phase 12 (12.00b.2-K, P12-016): pulled bookings become jobs. A
            // cold launch lands here right after the initial sync's commit,
            // so they convert here (RN: once bootstrapping ends,
            // `App.tsx:396`); the only launch point that can. A warm
            // activation lands here before its pull, and an exit from the
            // paywall follows a wait (fix round 1, review M3), so those
            // leave it to `performForegroundRefresh`.
            startBookingIntakeIfPossible()
            // Phase 12 (12.00b.2-I, P12-013): unfinished booking/portal work,
            // once the initial sync has committed (a cold launch lands here).
            // A warm activation lands here too, before its pull: that pass
            // leaves mirrors to `performForegroundRefresh` (fix round 1).
            startScheduleBookingRecoveryIfPossible()
        }
    }

    private func subscriptionMessage(for error: Error) -> String {
        nativeSubscriptionMessage(for: error)
    }

    private func resolveOnboarding(
        binding: String,
        imported: NativeTypedAccountState?,
        allowUnboundWorkspaceAdoption: Bool
    ) throws -> NativeOnboardingDocument {
        let store = NativeOnboardingStore(snapshotURL: fileURL)
        var document = try store.establish(
            accountBinding: binding,
            imported: imported,
            hasPersonalizedSettings: settings.businessName != "Your Business Name"
                || !settings.contactName.isEmpty,
            allowCreation: allowUnboundWorkspaceAdoption
                || isMigratedLocalOwnerVerified
                || !hasLocalAccountData
        )
        switch document.stage {
        case .personalizationCommit:
            let validated = try document.draft.validated()
            try commitOnboardingSettings(validated)
            document.draft = validated
            document.stage = .personalized
            try store.save(document)
        case .sampleCommit, .freshCommit:
            try commitStartingPoint(document)
            document.stage = .done
            try store.save(document)
        case .drafting, .personalized, .done:
            break
        }
        return document
    }

    private var hasLocalAccountData: Bool {
        !customers.isEmpty || !jobs.isEmpty || !invoices.isEmpty || !expenses.isEmpty
            || settings.businessName != "Your Business Name" || !settings.contactName.isEmpty
    }

    private func hasPersistedWorkspace(binding: String) -> Bool {
        guard let document = try? NativeOnboardingStore(snapshotURL: fileURL).load() else {
            return false
        }
        return document.accountBinding == binding
    }

    private func hasCompletedPersistedWorkspace(binding: String) -> Bool {
        guard let document = try? NativeOnboardingStore(snapshotURL: fileURL).load() else {
            return false
        }
        return NativeBackgroundRefreshPolicy.canAttachVerifiedIdentity(
            verifiedAccountBinding: binding,
            workspaceAccountBinding: document.accountBinding,
            workspaceIsComplete: document.stage == .done
        )
    }

    private var isSignedIn: Bool {
        if case .signedIn = authenticationGateState { return true }
        return false
    }

    /// Local notifications may reveal customer/job titles on the lock screen.
    /// Require both the active verified session and the exact persisted
    /// workspace binding before deriving, displaying, or routing any of them.
    private var hasExactSignedInWorkspace: Bool {
        guard isSignedIn, let binding = verifiedAccountBinding else { return false }
        return isMigratedLocalOwnerVerified || hasCompletedPersistedWorkspace(binding: binding)
    }

    private func commitOnboardingSettings(
        _ draft: NativeOnboardingDocument.Draft
    ) throws {
        guard ensurePersistenceWritable() else { throw NativeOnboardingError.corruptState }
        var updated = settings
        updated.businessName = draft.businessName
        updated.contactName = draft.contactName
        updated.trade = draft.trade.rawValue
        if updated.email.isEmpty { updated.email = authenticatedEmail ?? "" }
        // P12-008: a failed save changes nothing in memory, so the next
        // unrelated save cannot persist the personalization unqueued.
        var next = snapshot
        if let baseline = next.payload.settings {
            var edit = try CanonicalUIAdapters.edit(baseline)
            edit.value = updated
            next.payload.settings = try CanonicalUIAdapters.canonical(from: edit)
        } else {
            next.payload.settings = try CanonicalUIAdapters.canonical(from: updated)
        }
        try commitSnapshot(next)
    }

    private func commitStartingPoint(_ document: NativeOnboardingDocument) throws {
        guard ensurePersistenceWritable() else { throw NativeOnboardingError.corruptState }
        // P12-008: built on a copy; a failed save changes nothing in memory.
        var next = snapshot
        switch document.stage {
        case .sampleCommit:
            guard let namespace = document.sampleNamespace,
                  let anchor = document.sampleAnchor
            else { throw NativeOnboardingError.corruptState }
            try mergeSampleData(into: &next, namespace: namespace, anchor: anchor, trade: document.draft.trade)
        case .freshCommit:
            next.payload.customers?.removeAll { Self.isNativeSampleID($0.id) }
            next.payload.jobs?.removeAll { Self.isNativeSampleID($0.id) }
            next.payload.invoices?.removeAll { Self.isNativeSampleID($0.id) }
            next.payload.expenses?.removeAll { Self.isNativeSampleID($0.id) }
        default:
            throw NativeOnboardingError.corruptState
        }
        try commitSnapshot(next)
    }

    private func mergeSampleData(
        into next: inout Canonical.Snapshot,
        namespace: String,
        anchor: Date,
        trade: NativeTypedAccountState.Trade
    ) throws {
        let customerID = "native-sample-v1-\(namespace)-customer"
        let jobID = "native-sample-v1-\(namespace)-job"
        let invoiceID = "native-sample-v1-\(namespace)-invoice"
        let expenseID = "native-sample-v1-\(namespace)-expense"
        let customer = Customer(
            id: customerID,
            name: "Riverside Bakery",
            email: "owner@riversidebakery.com",
            phone: "(555) 301-2200",
            address: "142 Mill St, Austin TX 78701",
            notes: "Sample customer — replace with your own when ready.",
            createdAt: anchor
        )
        let job = Job(
            id: jobID,
            customerId: customerID,
            customerName: customer.name,
            title: Self.sampleJobTitle(for: trade),
            description: "Sample job for exploring TradeReady.",
            status: .scheduled,
            scheduledAt: Calendar.current.date(byAdding: .day, value: 1, to: anchor),
            scheduledEnd: Calendar.current.date(byAdding: .day, value: 1, to: anchor)
                .flatMap { Calendar.current.date(byAdding: .hour, value: 2, to: $0) },
            address: customer.address,
            estimateTotal: 285,
            laborHours: 2,
            laborRate: settings.laborRate,
            notes: "Sample data",
            createdAt: anchor
        )
        let invoice = Invoice(
            id: invoiceID,
            customerId: customerID,
            customer: customer.name,
            number: "INV-SAMPLE",
            amount: 285,
            due: Calendar.current.date(byAdding: .day, value: 14, to: anchor) ?? anchor,
            email: customer.email,
            phone: customer.phone,
            description: Self.sampleJobTitle(for: trade)
        )
        let expense = Expense(
            id: expenseID,
            merchant: "Sample Supply House",
            amount: 42.75,
            date: anchor,
            category: .materials,
            notes: "Sample expense"
        )
        var customerRecords = next.payload.customers ?? []
        let canonicalCustomer: Canonical.Customer
        if let baseline = customerRecords.first(where: { $0.id == customer.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = customer
            canonicalCustomer = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalCustomer = try CanonicalUIAdapters.canonical(from: customer) }
        replaceOrAppend(canonicalCustomer, in: &customerRecords, id: \Canonical.Customer.id)

        var jobRecords = next.payload.jobs ?? []
        let canonicalJob: Canonical.Job
        if let baseline = jobRecords.first(where: { $0.id == job.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = job
            canonicalJob = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalJob = try CanonicalUIAdapters.canonical(from: job) }
        replaceOrAppend(canonicalJob, in: &jobRecords, id: \Canonical.Job.id)

        var invoiceRecords = next.payload.invoices ?? []
        let canonicalInvoice: Canonical.Invoice
        if let baseline = invoiceRecords.first(where: { $0.id == invoice.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = invoice
            canonicalInvoice = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalInvoice = try CanonicalUIAdapters.canonical(from: invoice) }
        replaceOrAppend(canonicalInvoice, in: &invoiceRecords, id: \Canonical.Invoice.id)

        var expenseRecords = next.payload.expenses ?? []
        let canonicalExpense: Canonical.Expense
        if let baseline = expenseRecords.first(where: { $0.id == expense.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = expense
            canonicalExpense = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalExpense = try CanonicalUIAdapters.canonical(from: expense) }
        replaceOrAppend(canonicalExpense, in: &expenseRecords, id: \Canonical.Expense.id)

        next.payload.customers = customerRecords
        next.payload.jobs = jobRecords
        next.payload.invoices = invoiceRecords
        next.payload.expenses = expenseRecords
    }

    private static func isNativeSampleID(_ id: String) -> Bool {
        id.hasPrefix("native-sample-v1-")
    }

    /// Task 11.08: RN `isSampleId` (legacy seed ids) or a native sample seed.
    private static func isAnalyticsSampleID(_ id: String) -> Bool {
        NativeTodayBriefing.isSampleId(id) || isNativeSampleID(id)
    }

    private static func sampleJobTitle(for trade: NativeTypedAccountState.Trade) -> String {
        switch trade {
        case .plumbing: "Replace kitchen faucet"
        case .electrical: "Install a new outlet"
        case .hvac: "Seasonal system service"
        case .carpenter: "Repair an exterior door"
        case .bricklayer: "Repoint a garden wall"
        case .plasterer: "Repair a damaged ceiling"
        case .landscaping: "Seasonal yard cleanup"
        case .cleaning: "Deep-clean service"
        case .painting: "Repaint two rooms"
        case .handyman: "Complete a home repair visit"
        case .other: "Complete a service call"
        }
    }

    private func handlePasswordRecoveryLink(_ link: NativePasswordRecoveryLink) async {
        guard !authenticationOperationInFlight else { return }
        guard case .code(let code) = link else {
            if (try? NativePasswordRecoveryStore().read()?.activeUserSubject) != nil {
                authenticationGateState = .passwordRecovery(email: nil)
                return
            }
            authenticationGateState = .invalidPasswordRecovery
            return
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        authenticationGateState = .loading

        let recoveryStore = NativePasswordRecoveryStore()
        do {
            guard let verifier = try recoveryStore.read()?.codeVerifier else {
                throw NativePasswordRecoveryError.expiredLink
            }
            let configured = try configuredAuthentication()
            let session = try await configured.client.exchangePasswordRecoveryCode(
                code,
                codeVerifier: verifier
            )
            // Publish the recovery marker before the session. A crash can
            // therefore leave a harmless marker without credentials, never a
            // recovery session that normal launch could expose as signed in.
            try recoveryStore.markActive(userSubject: session.userSubject)
            do {
                let outcome = try await configured.activator.installVerifiedSession(
                    sessionBytes: session.bytes,
                    responseUserSubject: session.userSubject
                )
                didCheckMigratedAuthenticatedIdentity = true
                applyAuthenticatedIdentityOutcome(
                    outcome,
                    email: session.email,
                    gateOverride: .passwordRecovery(email: session.email),
                    activateConsumers: false
                )
            } catch {
                try? recoveryStore.clear()
                throw error
            }
        } catch {
            authenticationGateState = .invalidPasswordRecovery
        }
    }

    private func applyRecoverySignedOutState() {
        // Phase 12 (12.00b.2-G fix round 2, R31): as `applyCompletedSignOutState`,
        // a completed recovery exit is never overwritten by a suspended check.
        accountBoundaryGeneration &+= 1
        // Phase 12 final review (M4): and, as there, a push still on the wire
        // settles nothing under the next owner.
        syncCoordinator?.reset()
        migratedAccountState = nil
        dismissedCustomerDuplicatePairKeys = []
        pendingCustomerMergeUndo = nil
        pendingRecordDeleteUndo = nil
        rejectedChanges = []
        isMigratedLocalOwnerVerified = false
        migratedAccountBinding = nil
        verifiedAccountBinding = nil
        authenticatedUserSubject = nil
        authenticatedEmail = nil
        initialSyncCompletedSubject = nil
        initialSyncGateGeneration &+= 1
        postSubscriptionDestination = nil
        isSubscriptionTrialing = false
        authenticatedAccountState = .noMigratedSession
        authenticationGateState = .signedOut
        // Final review item 2: a recovery exit is an account boundary like
        // sign-out; no route held in the recovered session survives it.
        clearDeepLinkRouteState()
        // Task 11.15 fix round 1 (controller ruling): both recovery exits
        // (`updateRecoveredPassword`, `cancelPasswordRecovery`) end here and
        // tear down the account boundary, so the next owner may differ.
        wipeAIProviderKeysForAccountBoundary()
        // Phase 12 (12.00b.1): and so do the refused changes.
        scrubRejectedChangesForAccountBoundary()
        // Task 10.09 (B1): account boundary — clear the owner-scoped cached
        // snapshot only; observer registrations survive (see
        // `applyCompletedSignOutState`'s identical comment).
        derivedStatePublisher.reset()
        // Task 10.12 (S4/D4/D5): account boundary — wipe the mute/checklist
        // stores and their in-memory published state (see
        // `applyCompletedSignOutState`'s identical comment).
        resetTodayOwnerState()
    }

    /// Task 11.05 (contract §2.5 "Replay gate", C22): the binding widget/Siri
    /// replay may run for — the single owner predicate `O`
    /// (`derivedStatePublishBinding`) with the `.signedIn` gate, closed while
    /// an explicit account boundary is scrubbing or a scrub is pending or
    /// blocked. It no longer requires the migrated owner, so a native-only
    /// account (every account: there are no current users) replays.
    var widgetActionReplayBinding: String? {
        NativeWidgetReplayOwnerGate.replayBinding(
            ownerBinding: derivedStatePublishBinding,
            isSignedIn: isSignedIn,
            accountBoundaryOpen: widgetMirrorSuspendedForAccountBoundary
                || isAccountScrubBlocked
                || repository.isAccountScrubPending
                || isBoundaryStepPending(.widgetScrub)
        )
    }

    /// Claims and commits bounded batches only for the exact signed-in owner.
    /// The coordinator writes all affected canonical families once before it
    /// acknowledges shared input. Unsupported future actions remain durable.
    /// Task 11.05: actions not stamped `hash(O)` are dropped before dispatch
    /// (§4.5) and an unpreparable queue is quarantined (C8).
    ///
    /// Phase 12 12.00b.2-C: a bad owned entry is set aside alone while the
    /// rest of its batch applies (L130), and an unusable claim file is set
    /// aside so the pass continues (L131). A message is shown only when
    /// something was set aside: the entry count, or the coarse quarantine
    /// message, which takes precedence within a pass.
    ///
    /// Fix round 1: that one-time message also wins over a later
    /// retained-unsupported result or failure in the same pass (Minor 1), and
    /// a claim file that stays unreadable fails the pass closed, counted once
    /// per pass with one fixed line (I2b).
    ///
    /// Final review C1: a replay is a local write like any other (RN routes
    /// it through saveJobs/saveTrips/saveExpenses, `utils/widgetActions.ts`).
    /// `apply` bypasses the per-write enqueue hooks, so the coordinator hands
    /// every record the batch wrote to `enqueueWidgetReplayWrites` after the
    /// canonical save and before the claim is acknowledged. The records are
    /// then pending, so a pull cannot replace them with the server copy.
    private func replayVerifiedWidgetActionsIfPossible() {
        guard let accountBinding = widgetActionReplayBinding,
              let widgetActionReplayTransport,
              ensurePersistenceWritable()
        else { return }
        var enqueuedWrites = false
        let coordinator = NativeWidgetActionReplayCoordinator(
            transport: widgetActionReplayTransport,
            repository: repository,
            enqueueWrittenRecords: { [unowned self] records, committed in
                try self.enqueueWidgetReplayWrites(records, from: committed, accountBinding: accountBinding)
                enqueuedWrites = true
            }
        )
        defer {
            if enqueuedWrites {
                scheduleSyncAfterLocalChange()
                scheduleWidgetMirrorRefresh()
            }
        }
        var setAsideThisPass = 0
        var quarantinedThisPass = false
        var passMessage: String?
        do {
            // Each claim contains at most 512 actions. Bound foreground work so
            // a continuously-writing extension cannot starve app activation.
            for _ in 0..<8 {
                // The loop never suspends, but re-verify the exact owner before
                // every claim anyway: a batch is only ever applied to `O`.
                guard widgetActionReplayBinding == accountBinding else { return }
                switch try coordinator.replayNext(
                    snapshot: snapshot,
                    verifiedAccountBinding: accountBinding
                ) {
                case .nothingPending:
                    return
                case .retainedUnsupported(let count):
                    migrationMessage = passMessage ?? "Kept \(count) newer widget action(s) for a compatible app update."
                    return
                case .committed(let committed, _, _, let ownerDropped, let setAside):
                    widgetActionReplayDiagnostics.recordOwnerDropped(ownerDropped)
                    widgetActionReplayDiagnostics.recordSetAsideActions(setAside)
                    if setAside > 0 {
                        setAsideThisPass += setAside
                        if !quarantinedThisPass {
                            passMessage = NativeWidgetActionReplayCoordinator
                                .setAsideMessage(actionCount: setAsideThisPass)
                            migrationMessage = passMessage
                        }
                    }
                    try apply(committed)
                case .quarantined(let reason):
                    widgetActionReplayDiagnostics.recordQuarantine(reason)
                    quarantinedThisPass = true
                    passMessage = NativeWidgetActionReplayCoordinator.quarantinedMessage(for: reason)
                    migrationMessage = passMessage
                }
            }
        } catch {
            if case NativeWidgetActionClaimError.unreadableClaim = error {
                // Fix round 1 (I2b): payload-free, once per pass (the throw
                // ends the pass). The claim stays until it can be read.
                widgetActionReplayDiagnostics.recordUnreadableClaim()
                Self.stageLogger.error("TradeReadyWidgetReplay stage=unreadable-claim")
            }
            // A post-commit acknowledgement failure may leave memory one step
            // behind disk. Reload the verified canonical result before retry.
            if let loaded = try? repository.load() { try? apply(loaded.snapshot) }
            migrationMessage = passMessage ?? "Widget actions are still safely queued and will be retried."
        }
    }

    /// Final review C1: queues one upsert per record a replayed batch wrote,
    /// read from the committed snapshot, in one atomic last-writer-wins queue
    /// save. Refuses (throws) unless the replay owner is still `O`, so the
    /// claim stays unacknowledged. A failure is recorded like every other
    /// local write's enqueue failure and rethrown, so the claim is retried.
    private func enqueueWidgetReplayWrites(
        _ records: [NativeWidgetActionRecordKey],
        from committed: Canonical.Snapshot,
        accountBinding: String
    ) throws {
        do {
            guard widgetActionReplayBinding == accountBinding else {
                throw NativeWidgetActionReplayEnqueueError.ownerChanged
            }
            let drafts = try records.map { key -> Canonical.MutationDraft in
                let payload: Canonical.JSONValue?
                switch key.table {
                case NativeWidgetActionRecordKey.jobsTable:
                    payload = try committed.payload.jobs?.first { $0.id == key.recordID }.map(Self.mutationPayload)
                case NativeWidgetActionRecordKey.tripsTable:
                    payload = try committed.payload.trips?.first { $0.id == key.recordID }.map(Self.mutationPayload)
                case NativeWidgetActionRecordKey.expensesTable:
                    payload = try committed.payload.expenses?.first { $0.id == key.recordID }.map(Self.mutationPayload)
                default:
                    payload = nil
                }
                guard let payload else { throw NativeWidgetActionReplayEnqueueError.missingRecord }
                return Canonical.MutationDraft(table: key.table, op: .upsert, recordId: key.recordID, payload: payload)
            }
            try mutationQueue.enqueueBatch(drafts)
        } catch {
            print("TradeReadyMutationQueue stage=enqueue-widget-replay count=\(records.count)")
            recordLocalSyncFailure("queue/enqueue-widget-replay")
            throw error
        }
    }

    /// Task 11.06 (contract §2.5, §6.2; C22): runs at every `.signedIn`
    /// arrival and after every activation — no once-per-session latch. The
    /// parked route is flushed first, then the stash is read-and-removed
    /// (the newest route applies last). Both go through the same gate: O plus
    /// `.signedIn`, the owner tag, and the record.
    private func consumePendingDeepLinks(now: Date = Date()) {
        flushParkedDeepLink(now: now)
        consumePendingOpenURLStash(now: now)
    }

    private func routeToJob(_ id: String) {
        selectedTab = .jobs
        deepLinkedJobID = id
    }

    private func routeToOnMyWay(_ id: String) {
        selectedTab = .jobs
        deepLinkedJobID = id
        requestOnMyWayReview(jobID: id)
    }

    func requestOnMyWayReview(jobID: String) {
        guard jobs.contains(where: { $0.id == jobID }) else { return }
        pendingOnMyWayJobID = jobID
    }

    /// Notification taps use the exact job route but intentionally do not
    /// require the visible appointment-button status gate. The review sheet
    /// still refuses to draft when contact data is unavailable.
    func requestAppointmentConfirmationReview(jobID: String, fromNotification: Bool = true) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              NativeAppointmentNotifications.canOpenNotification(
                  exactOwnerWorkspace: hasExactSignedInWorkspace,
                  signedIn: isSignedIn,
                  job: job
              )
        else { return }
        // Task 11.08: RN `App.tsx:434` tracks notification taps only.
        if fromNotification { emitAnalytics(.appointmentConfirmOpened) }
        selectedTab = .jobs
        deepLinkedJobID = jobID
        pendingAppointmentConfirmationJobID = jobID
    }

    /// Fails closed only for a missing job or a non-exact (foreign/signed-out)
    /// workspace, or when no draft can be built. Final-review I1 (RN parity,
    /// contract §9.6): an archived job routes normally — `review_` requests
    /// are still scheduled for archived jobs (RN `utils/archive.ts` keeps
    /// notifications seeing them) and RN's `review_request` tap navigates
    /// with no archive check, so a delivered notification is never a dead tap.
    func requestReviewRequestReview(
        jobID: String,
        source: NativeAnalyticsEvent.MessageSource = .notification
    ) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              snapshot.payload.jobs?.contains(where: { $0.id == jobID }) == true,
              reviewRequestDraft(jobID: jobID) != nil else { return }
        // Task 11.08: the `source` RN passes as a ReviewRequest route param.
        reviewRequestAnalyticsSource = source
        selectedTab = .jobs
        deepLinkedJobID = jobID
        pendingReviewRequestJobID = jobID
    }

    /// Phase 7 invoice-tap routing. Validates the exact workspace plus current
    /// record state before opening the review screen; stale payloads fail
    /// closed. Taps never send customer messages.
    func requestInvoiceReminderReview(invoiceID: String, opensOutreach: Bool, daysPastDue: Int? = nil) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              invoices.contains(where: { $0.id == invoiceID })
        else { return }
        // Task 11.08: RN `App.tsx:427` (`overdue_outreach` taps open Outreach).
        if opensOutreach {
            emitAnalytics(.overdueOutreachOpened(daysPastDue: daysPastDue))
        }
        selectedTab = .invoices
        deepLinkedInvoiceID = invoiceID
        deepLinkedOutreachInvoiceID = opensOutreach ? invoiceID : nil
    }

    /// Task 10.08 (N6) fix: mirrors `App.tsx`'s `recurring_invoice` tap route —
    /// generation runs on foreground after sync, so by tap time the newest
    /// generated invoice usually already exists. Resolve it (highest
    /// `occurrenceNumber` among invoices with `recurringInvoiceId == ruleID`)
    /// and deep-link straight to it, exactly like `requestInvoiceReminderReview`;
    /// when none has generated yet, fall back to the plain Invoices tab
    /// (RN's `InvoiceList` with no `openInvoiceId`) rather than inventing a
    /// destination. A missing rule (deleted) or absent exact workspace fails
    /// closed — no tab switch at all.
    func requestRecurringInvoiceReview(ruleID: String) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              (snapshot.payload.recurringInvoices ?? []).contains(where: { $0.id == ruleID })
        else { return }
        selectedTab = .invoices
        let generated = (snapshot.payload.invoices ?? []).filter { $0.recurringInvoiceId == ruleID }
        let latest = generated.max { ($0.occurrenceNumber ?? 0) < ($1.occurrenceNumber ?? 0) }
        if let latest {
            deepLinkedInvoiceID = latest.id
            deepLinkedOutreachInvoiceID = nil
        } else {
            // Final-review m5: the plain-Invoices fallback must not leave an
            // earlier one-shot invoice/outreach target armed, or the Invoices
            // tab would open that unrelated invoice instead of its list.
            deepLinkedInvoiceID = nil
            deepLinkedOutreachInvoiceID = nil
        }
    }

    /// Consumes a pending outreach deep link for the given invoice. Returns
    /// whether the caller should open the reviewed outreach sheet.
    func consumeOutreachDeepLink(invoiceID: String) -> Bool {
        guard deepLinkedOutreachInvoiceID == invoiceID else { return false }
        deepLinkedOutreachInvoiceID = nil
        return true
    }

    func dismissPendingReviewRequest(jobID: String) {
        guard pendingReviewRequestJobID == jobID else { return }
        pendingReviewRequestJobID = nil
    }

    func dismissPendingAppointmentConfirmation(jobID: String) {
        guard pendingAppointmentConfirmationJobID == jobID else { return }
        pendingAppointmentConfirmationJobID = nil
    }

    func dismissPendingOnMyWay(jobID: String) {
        guard pendingOnMyWayJobID == jobID else { return }
        pendingOnMyWayJobID = nil
    }

    func resetDemoData() {
        // This explicit user action is allowed to replace an unreadable source,
        // but only once the demo data is saved (P12-008 review, fix round 1
        // R41): a failed reset keeps the data it could not replace, so writes
        // stay blocked (the next save cannot overwrite the recovery source)
        // and the undo offers still match what is on screen.
        guard seedDemoData() else { return }
        persistenceWritesBlocked = false
        persistenceBlockReason = nil
        persistenceBlockDetail = nil
        pendingCustomerMergeUndo = nil
        pendingRecordDeleteUndo = nil
    }

    private func apply(_ value: Canonical.Snapshot) throws {
        let cs = try project("customers") {
            try (value.payload.customers ?? []).map { try CanonicalUIAdapters.customer(from: $0) }
        }
        let js = try project("jobs") {
            try (value.payload.jobs ?? []).map { try CanonicalUIAdapters.job(from: $0) }
        }
        let ins = try project("invoices") {
            try (value.payload.invoices ?? []).map { try CanonicalUIAdapters.invoice(from: $0) }
        }
        let es = try project("expenses") {
            try (value.payload.expenses ?? []).map { try CanonicalUIAdapters.expense(from: $0) }
        }
        let canonicalSettings = try project("settings") {
            try value.payload.settings ?? CanonicalUIAdapters.canonical(from: BusinessSettings())
        }
        snapshot = value; snapshot.schemaVersion = Canonical.Snapshot.currentSchemaVersion
        snapshot.payload.settings = canonicalSettings
        isApplyingProjection = true
        customers = cs; jobs = js; invoices = ins; expenses = es
        trips = value.payload.trips ?? []
        pricebookEntries = value.payload.pricebook ?? []
        settings = CanonicalUIAdapters.settings(from: canonicalSettings)
        isApplyingProjection = false
        // P12-008 review (fix round 1, R41): the fields now show this
        // snapshot's saved settings, so an earlier edit's failure (or a
        // read-only notice a reset or import has since lifted) is stale.
        settingsSaveFailure = nil
        if let pendingEstimateFollowUpJobID,
           !NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: hasExactSignedInWorkspace,
                signedIn: isSignedIn,
                job: snapshot.payload.jobs?.first { $0.id == pendingEstimateFollowUpJobID }
           ) {
            self.pendingEstimateFollowUpJobID = nil
        }
    }

    private func project<T>(_ family: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw SnapshotProjectionError(family: family, underlying: error) }
    }

    /// Phase 12 (12.00b.2-H, P12-008): the commit for a change to the live
    /// snapshot. The other ways in are `commitSettings` (Settings alone), the
    /// copy sites that save and then `apply` what they saved, and the
    /// allowlisted applies of a snapshot saved elsewhere. `next` is projected
    /// (so a snapshot the screens cannot show is never saved), saved, and
    /// only then kept; when the projection or the save throws, the previous
    /// snapshot, the screens and the pending estimate follow-up are restored
    /// before the error is rethrown. Callers build `next` on a copy (`var next = snapshot`) and
    /// queue, emit and prompt only after this returns, so a change that was
    /// not saved is never queued, tracked, shown or mirrored to the widget,
    /// and the next unrelated save cannot persist it without queueing it.
    /// (RN `saveInvoices` persists and queues together and re-upserts every
    /// record on each save, `utils/storage/collections.ts:26-35`,
    /// `utils/sync.ts:108-124`, so it never persists a change unqueued.)
    /// The widget mirror refresh `snapshot.didSet` schedules runs on a later
    /// main-actor turn and reads the restored snapshot. A source pin
    /// (`native/SaveRollbackTests`) keeps every live-snapshot write in
    /// `apply` and the two commit helpers, and every other `apply(X)` (bar a
    /// named allowlist) directly after `repository.save(X)`.
    private func commitSnapshot(_ next: Canonical.Snapshot) throws {
        let previous = snapshot
        let previousFollowUp = pendingEstimateFollowUpJobID
        do {
            try apply(next)
            try repository.save(snapshot)
        } catch {
            if (try? apply(previous)) == nil { snapshot = previous }
            pendingEstimateFollowUpJobID = previousFollowUp
            throw error
        }
    }

    /// P12-008: the settings-only commit (a Settings edit, the Square token
    /// heal). Saved first and kept only once saved, like `commitSnapshot`,
    /// but without re-projecting every record on each Settings keystroke;
    /// the caller owns the published `settings`.
    private func commitSettings(_ value: Canonical.Settings) throws {
        var next = snapshot
        next.payload.settings = value
        try repository.save(next)
        snapshot = next
    }

    /// Shows the saved settings (a blocked or failed Settings save).
    private func showSavedSettings() {
        isApplyingProjection = true
        settings = snapshot.payload.settings.map { CanonicalUIAdapters.settings(from: $0) } ?? BusinessSettings()
        isApplyingProjection = false
    }

    private func applyEmptySnapshot() {
        do { try apply(Canonical.Snapshot(payload: .init())) }
        catch { migrationMessage = "Could not initialize data: \(error.localizedDescription)" }
    }

    private func migrateFileSnapshot(
        _ migrated: Canonical.Snapshot,
        sourceData: Data,
        kind: Canonical.MigrationKind
    ) throws {
        _ = try migrationJournal.begin(kind)
        do {
            try repository.preserveLegacyBytes(sourceData, migration: kind)
            try commitSnapshot(migrated)
            try migrationJournal.complete(kind)
        } catch {
            try? migrationJournal.fail(kind)
            throw error
        }
    }

    /// P12-008 review (fix round 1, R41): what became of a payment provider
    /// key entry, so the Payments page never reports a save that failed.
    enum ProviderKeySaveOutcome: Equatable {
        /// Saved as this value (empty clears the field).
        case saved(String)
        /// Refused by the Square policy (a pasted token); nothing was written.
        case rejected(String)
        /// Valid but not saved (writes are blocked, or the save failed): the
        /// fields show the saved settings, and this says why.
        case notSaved(String)
    }

    /// Task 11.13 fix round 2 (G5): the only Settings write path for a
    /// payment provider key. A Square value `isSquarePaymentLink` refuses (a
    /// pasted access token) is rejected and never reaches the snapshot, disk
    /// or the mutation queue; an empty Square entry clears the field; every
    /// other provider keeps RN's unvalidated save. P12-008 review: returns
    /// `.notSaved` when the settings save does not happen.
    @discardableResult
    func setPaymentProviderKey(_ entry: String, for provider: String) -> ProviderKeySaveOutcome {
        switch NativeSquareProviderKeyPolicy.validate(entry, provider: provider) {
        case let .reject(message):
            return .rejected(message)
        case let .save(value):
            isApplyingProjection = true
            settings.setProviderKey(value, for: provider)
            isApplyingProjection = false
            guard mergeSettingsAndSave() else {
                return .notSaved(settingsSaveFailure ?? Self.settingsNotSavedMessage)
            }
            return .saved(value)
        }
    }

    /// Task 11.13 fix round 2 (G4/G5): the port of RN `scrubLegacySquareToken`
    /// (`utils/storage/settings.ts`; run on every sign-in, `App.tsx`). A stored
    /// Square value `isSquarePaymentLink` refuses is deleted from
    /// `providerKeys`, and the cleaned blob is queued so the cloud copy (the
    /// push replaces the whole settings `data` blob) is overwritten too.
    /// Native runs it at sign-in and after every commit of synced settings
    /// (initial sync, delta pull), because a pull can resurrect an unscrubbed
    /// blob from another device or an old queue. Idempotent: a run that finds
    /// nothing writes nothing. Gated on the exact signed-in workspace (the
    /// recurring-generation gate) so it never queues a write that another
    /// owner's session could upload.
    @discardableResult
    func scrubLegacySquareToken() -> Bool {
        guard derivedStatePublishBinding != nil, !persistenceWritesBlocked,
              let current = snapshot.payload.settings,
              let cleaned = NativeSquareProviderKeyPolicy.scrubbed(current.providerKeys)
        else { return false }
        var healed = current
        healed.providerKeys = cleaned
        do {
            try commitSettings(healed)
        } catch {
            print("TradeReadySquareTokenScrub stage=save")
            return false
        }
        // The repository keeps the previous generation as its `.backup`, which
        // still holds the credential; a second write rotates the healed
        // snapshot into it. Best effort: the primary is already healed.
        do { try repository.save(snapshot) } catch { print("TradeReadySquareTokenScrub stage=backup") }
        showSavedSettings()
        enqueueSettingsUpsert(healed)
        return true
    }

    /// Saves the published settings and returns whether they were saved.
    /// P12-008 review (fix round 1, R41): when they were not, the fields go
    /// back to the saved settings and `settingsSaveFailure` says why.
    @discardableResult
    private func mergeSettingsAndSave() -> Bool {
        guard ensurePersistenceWritable() else {
            if snapshot.payload.settings != nil { showSavedSettings() }
            settingsSaveFailure = Self.persistenceReadOnlyMessage
            return false
        }
        // Fix round 2 (G5): a Square value that is not a payment link never
        // persists, whatever path wrote it (`setPaymentProviderKey` rejects it
        // first; this is the persist-time guard behind it).
        if let cleaned = NativeSquareProviderKeyPolicy.scrubbed(settings.paymentProviderKeys) {
            isApplyingProjection = true
            settings.paymentProviderKeys = cleaned
            isApplyingProjection = false
        }
        let merged: Canonical.Settings
        do {
            if let baseline = snapshot.payload.settings {
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = settings
                merged = try CanonicalUIAdapters.canonical(from: edit)
            } else { merged = try CanonicalUIAdapters.canonical(from: settings) }
        } catch {
            migrationMessage = "Could not update settings: \(error.localizedDescription)"
            settingsSaveFailure = Self.settingsNotSavedMessage
            showSavedSettings()
            return false
        }
        do {
            try commitSettings(merged)
        } catch {
            // P12-008: a failed save is neither kept nor queued, and the
            // screen goes back to the saved settings (as when writes are
            // blocked above) instead of showing an edit that was not saved.
            migrationMessage = "Could not update settings: \(error.localizedDescription)"
            settingsSaveFailure = Self.settingsNotSavedMessage
            showSavedSettings()
            return false
        }
        settingsSaveFailure = nil
        enqueueSettingsUpsert(merged)
        return true
    }

    /// P12-008 review (fix round 1, R41): the owner-facing copy for a Settings
    /// edit or a bulk Mark paid whose save failed.
    private static let settingsNotSavedMessage =
        "Could not save this change. Your saved settings are shown."
    private static let bulkSettleNotSavedMessage =
        "Could not mark the invoices paid. Nothing was changed and existing data was preserved."

    private static let persistenceReadOnlyMessage =
        "Local data is read-only so its recovery source can be preserved."

    private func ensurePersistenceWritable() -> Bool {
        guard persistenceWritesBlocked else { return true }
        migrationMessage = Self.persistenceReadOnlyMessage
        return false
    }

    private func commitCustomerMerge(_ result: NativeCustomerMergeResult) throws {
        // Encode every pending wire payload before publishing the snapshot (the
        // pure planner does this), then durably commit local truth in one write.
        // Queue publication follows the same local-first boundary as all other
        // edits: a queue failure never rolls back or hides the saved records.
        try repository.save(result.snapshot)
        try apply(result.snapshot)
        do {
            try mutationQueue.enqueueBatch(result.mutations)
            scheduleSyncAfterLocalChange()
        } catch {
            print("TradeReadyMutationQueue stage=enqueue-customer-merge")
            recordLocalSyncFailure("queue/enqueue-customer-merge")
        }
    }

    private func commitRecordDeletion(_ result: NativeRecordDeletionResult) throws {
        // The canonical snapshot is durable before the queue is changed. The
        // queue's LWW key then replaces a delete with an undo upsert (or vice
        // versa), while a queue failure never rolls back local truth.
        try repository.save(result.snapshot)
        try apply(result.snapshot)
        do {
            try mutationQueue.enqueueBatch([result.mutation])
            scheduleSyncAfterLocalChange()
        } catch {
            print("TradeReadyMutationQueue stage=enqueue-record-deletion")
            recordLocalSyncFailure("queue/enqueue-record-deletion")
        }
    }

    private func scheduleCustomerMergeUndoExpiration(id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self?.pendingCustomerMergeUndo?.id == id else { return }
            self?.pendingCustomerMergeUndo = nil
        }
    }

    private func scheduleRecordDeleteUndoExpiration(id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self?.pendingRecordDeleteUndo?.id == id else { return }
            self?.pendingRecordDeleteUndo = nil
        }
    }

    // MARK: - Phase 4 outbound sync queue

    /// Records a local record write for the next cloud push. A failed enqueue
    /// never surfaces to the user or blocks the local save that already
    /// succeeded: the next edit re-enqueues and the idempotent pull reconciles.
    private func enqueueUpsert<Record: Encodable>(
        table: String,
        recordId: String,
        record: Record
    ) {
        do {
            try mutationQueue.enqueue(
                table: table,
                op: .upsert,
                recordId: recordId,
                payload: try Self.mutationPayload(record)
            )
            scheduleSyncAfterLocalChange()
        } catch {
            print("TradeReadyMutationQueue stage=enqueue table=\(table)")
            recordLocalSyncFailure("queue/enqueue")
        }
    }

    /// Enqueues a settings upsert, scrubbing every secure credential key before
    /// the value can reach the plain queue file — the same boundary the snapshot
    /// codec enforces and the push transport re-enforces on the wire.
    private func enqueueSettingsUpsert(_ settings: Canonical.Settings) {
        do {
            var payload = try Self.mutationPayload(settings)
            if case var .object(fields) = payload {
                for key in Canonical.SnapshotCodec.secureSettingsKeys {
                    fields.removeValue(forKey: key)
                }
                payload = .object(fields)
            }
            try mutationQueue.enqueue(
                table: "settings",
                op: .upsert,
                recordId: Self.settingsMutationRecordID,
                payload: payload
            )
            scheduleSyncAfterLocalChange()
        } catch {
            print("TradeReadyMutationQueue stage=enqueue table=settings")
            recordLocalSyncFailure("queue/enqueue-settings")
        }
    }

    private func enqueueDelete(table: String, recordId: String) {
        do {
            try mutationQueue.enqueue(table: table, op: .delete, recordId: recordId, payload: nil)
            scheduleSyncAfterLocalChange()
        } catch {
            print("TradeReadyMutationQueue stage=enqueue-delete table=\(table)")
            recordLocalSyncFailure("queue/enqueue-delete")
        }
    }

    private static let settingsMutationRecordID = "settings"

    private static func mutationPayload<Record: Encodable>(
        _ record: Record
    ) throws -> Canonical.JSONValue {
        try JSONDecoder().decode(Canonical.JSONValue.self, from: mutationEncoder.encode(record))
    }

    private static let mutationEncoder = JSONEncoder()

    // MARK: - Phase 4 outbound sync scheduler

    private var syncCoordinator: NativeSyncCoordinator?
    private lazy var syncReachability: any NativeSyncReachability = Self.makeSyncReachability()

    // MARK: - Task 10.09: post-sync-commit derived-state seam (B1)

    /// Task 10.09 output (a): set by `TradeReadyNativeApp` at launch to call
    /// the 10.08 `NativeEstimateFollowUpNotificationCoordinator.synchronize(now:)`.
    /// AppStore cannot hold a direct reference to the coordinator (it already
    /// holds a weak reference back to the store for its own notification-plan
    /// closures), so the hand-off runs the other way — mirrors the existing
    /// `onInvoiceCreatedContextualPrompt` pattern. `nil` until wired (e.g. in
    /// a host test that never sets it); the seam then simply skips output (a).
    var notificationSynchronizeHook: ((Date) async -> Void)?

    /// The post-sync-commit seam (B1). Instantiated once. Contract: publish
    /// exactly once per committed canonical sync commit, not from a single
    /// call site — there are several legitimate publish sites, each firing
    /// right after its own commit durably lands: `pullDeltaIfPossible`
    /// (delta pulls, including the booking-intake re-publish after its own
    /// local commit), the initial full sync's commit in
    /// `beginInitialSyncGate`, and `prepareBookingReschedule`'s follow-up
    /// pull. A monotonic `generation` counter inside
    /// `NativeDerivedStatePublisher` (plus its owner-binding check) orders
    /// concurrent publishes so a stale-resuming one never overwrites a
    /// newer commit's result.
    private(set) lazy var derivedStatePublisher = NativeDerivedStatePublisher<Canonical.Snapshot, NativeBusinessSnapshot>(
        notifySynchronize: { [weak self] now in
            await self?.notificationSynchronizeHook?(now)
        },
        makeSnapshot: { [weak self] canonical, now in
            guard let self else { throw NativeDerivedStatePublisherOwnerUnavailable() }
            return self.makeCachedBusinessSnapshot(from: canonical, now: now)
        },
        // Final-review I6: the publisher's owner check (before and after
        // every await, and on every cache read) uses the exact-workspace
        // binding, not the bare verified binding — so an account mismatch
        // or unavailable gate that lands mid-publish also stops every output.
        ownerBinding: { [weak self] in self?.derivedStatePublishBinding }
    )

    /// Final-review I6: the ONE predicate every derived-state publish site
    /// (`beginInitialSyncGate`'s initial full sync, `pullDeltaIfPossible`,
    /// the booking-intake commit) and the publisher's own owner re-check use.
    /// Returns the verified binding only for an exact workspace: the local
    /// workspace is proven to belong to that binding (migrated-owner
    /// verification or a completed onboarding document bound to it) and the
    /// gate is not in a failed/signed-out state. In particular
    /// `.accountMismatch` (the snapshot is pulled data merged into ANOTHER
    /// owner's local workspace) and `.unavailable` never publish, so the
    /// 11.01 widget mirror can never write a mixed-owner snapshot into the
    /// App Group. The gate switch is exhaustive on purpose: a new gate state
    /// must decide here whether it may publish. The post-sign-in gates
    /// (`.subscriptionLoading`, `.paywall`, `.startingPoint`, `.onboarding`)
    /// are allowed because the initial-sync publish runs right after
    /// `advancePastInitialSync` moves the gate there; the workspace-ownership
    /// check still has to hold.
    var derivedStatePublishBinding: String? {
        guard let binding = verifiedAccountBinding else { return nil }
        switch authenticationGateState {
        case .signedIn, .subscriptionLoading, .paywall, .startingPoint, .onboarding:
            break
        case .accountMismatch, .unavailable, .signedOut, .loading, .initialSyncLoading,
             .initialSyncUnavailable, .passwordRecovery, .invalidPasswordRecovery:
            return nil
        }
        guard isMigratedLocalOwnerVerified || hasCompletedPersistedWorkspace(binding: binding) else { return nil }
        return binding
    }

    /// Task 10.09 output (c): the cached business snapshot, refreshed after
    /// every real committed sync pass for an exact workspace and cleared at
    /// the account boundary. Final-review I2: the coach no longer reads it
    /// (see `coachBusinessSnapshot()`); it stays for the derived-state
    /// observers (the 11.01 widget mirror) and diagnostics.
    var cachedBusinessSnapshot: NativeBusinessSnapshot? { derivedStatePublisher.cachedSnapshot }

    /// Final-review I2 (RN parity: `screens/ChatScreen.tsx` recomputes
    /// `getBusinessSnapshot()` from local storage on every focus): ALWAYS
    /// builds from the live in-memory canonical `snapshot`, through the same
    /// 10.01 builder `derivedStatePublisher` uses — never the sync-time
    /// cache, which only refreshes after a committed pull and would cite
    /// stale revenue/outstanding/overdue figures after a local edit (mark
    /// paid, new job) or while offline/in backoff. `asOf` and "this month"
    /// are therefore always the current time, too. Fails closed to `nil`
    /// with no verified owner — `NativeCoachQuickPrompts` and
    /// `NativeCoachPrompt` both treat `nil` as their documented "no data
    /// yet" fallback.
    func coachBusinessSnapshot(now: Date = Date()) -> NativeBusinessSnapshot? {
        guard verifiedAccountBinding != nil else { return nil }
        return makeCachedBusinessSnapshot(from: snapshot, now: now)
    }

    /// Task 10.09 output (b): the registration point the Phase 11 widget
    /// mirror (11.01) plugs into. No widget code lives here — this is only
    /// the seam. Returns a token for `unregisterDerivedStateObserver`.
    ///
    /// Owner contract (final-review I6, an explicit 11.01 entry
    /// precondition): observers fire ONLY for an exact owner workspace
    /// (verified binding + local workspace bound to it + a gate past sign-in
    /// that is not failed) — every publish site gates on
    /// `derivedStatePublishBinding`,
    /// and the publisher re-checks that same binding after each await before
    /// calling any observer. An observer is never called while the gate is
    /// `.accountMismatch`, `.unavailable`, signed out, or in recovery, and
    /// never with a snapshot built for a different binding than the one
    /// current when it runs. Observers survive `reset()` (app lifetime), so
    /// an observer that persists output (the widget mirror) must still key
    /// or clear that output at the account boundary itself.
    @discardableResult
    func registerDerivedStateObserver(
        _ observer: @escaping (NativeBusinessSnapshot) throws -> Void
    ) -> UUID {
        derivedStatePublisher.register(observer)
    }

    /// Task 11.01 (contract §3.2, C5): the additive overload. Same owner
    /// contract as above; the observer also receives the committed canonical
    /// snapshot the output was built from and the `expectedOwnerBinding` the
    /// publisher verified, so it never reads stale in-memory collections and
    /// never needs a separate binding accessor.
    @discardableResult
    func registerDerivedStateObserver(
        committed observer: @escaping (Canonical.Snapshot, NativeBusinessSnapshot, String) throws -> Void
    ) -> UUID {
        derivedStatePublisher.register(committed: observer)
    }

    func unregisterDerivedStateObserver(_ id: UUID) {
        derivedStatePublisher.unregister(id)
    }

    /// Every AppStore publish site goes through here: publishes the live
    /// canonical snapshot and records its revision, so the widget seam
    /// observer can detect a local write that landed while the publish was
    /// suspended (task 11.01 fix round 1, contract §3.2 amendment).
    func publishDerivedState(expectedOwnerBinding binding: String) async {
        let token = UUID()
        widgetSeamCapture = (token, canonicalWriteRevision)
        defer { if widgetSeamCapture?.token == token { widgetSeamCapture = nil } }
        await derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: binding)
    }

    // MARK: Widget mirror (task 11.01, contract §3.1)

    /// The owner binding the widget mirror may write for: the single §2.5
    /// predicate `derivedStatePublishBinding`, closed while an explicit
    /// account boundary is scrubbing or a scrub is pending/blocked.
    var widgetMirrorOwnerBinding: String? {
        guard !widgetMirrorSuspendedForAccountBoundary,
              !isAccountScrubBlocked,
              !repository.isAccountScrubPending,
              // Final review 1a: the previous owner's App Group state may remain.
              !isBoundaryStepPending(.widgetScrub)
        else { return nil }
        return derivedStatePublishBinding
    }

    /// Installs the App Group writer once at launch: registers the 10.09
    /// seam observer (trigger 3) and mirrors immediately (a no-op until the
    /// owner is verified). Re-installing replaces the previous writer.
    func installWidgetMirror(_ mirror: NativeWidgetMirror) {
        if let token = widgetMirrorObserverToken {
            unregisterDerivedStateObserver(token)
        }
        widgetMirror = mirror
        widgetMirrorObserverToken = registerDerivedStateObserver(committed: { [weak self] canonical, business, binding in
            self?.writeWidgetMirrorFromSeam(canonical: canonical, business: business, expectedOwnerBinding: binding)
        })
        refreshWidgetMirror(force: true)
    }

    /// Triggers 1–2: projects the live canonical snapshot for `O` and writes
    /// it. Returns nil when no writer is installed.
    @discardableResult
    func refreshWidgetMirror(force: Bool, now: Date = Date()) -> NativeWidgetMirrorOutcome? {
        guard let widgetMirror else { return nil }
        guard let binding = widgetMirrorOwnerBinding else { return noteWidgetMirrorOutcome(.skippedNoOwner) }
        let projection = NativeWidgetSnapshotProjection.project(
            jobs: snapshot.payload.jobs ?? [],
            business: makeCachedBusinessSnapshot(from: snapshot, now: now),
            now: now
        )
        return noteWidgetMirrorOutcome(widgetMirror.write(
            projection: projection,
            ownerBinding: binding,
            isCurrentOwner: { [weak self] candidate in self?.widgetMirrorOwnerBinding == candidate },
            force: force,
            now: now
        ))
    }

    /// Phase 12 (12.00b.2-B, charter L74): the mirror runs on the main actor,
    /// so its lock wait is bounded (100 ms). A busy write wrote nothing: the
    /// mirror stays dirty, one payload-free diagnostic is emitted, and a
    /// retry is scheduled; every later trigger retries too. A write that
    /// reaches the writer, or finds no owner, settles it. A retry re-projects
    /// the live snapshot through the owner gate, so it never writes for an
    /// owner that is no longer current. `.skippedOwnerChanged`,
    /// `.unavailable`, `.lockFailed` and `.encodingFailed` leave the flag as
    /// it was.
    @discardableResult
    private func noteWidgetMirrorOutcome(_ outcome: NativeWidgetMirrorOutcome) -> NativeWidgetMirrorOutcome {
        switch outcome {
        case .busy:
            isWidgetMirrorDirty = true
            widgetMirrorLockBusyCount = min(Self.widgetMirrorLockBusyCap, widgetMirrorLockBusyCount + 1)
            Self.stageLogger.notice("TradeReadyWidgetLock stage=busy site=mirror count=\(self.widgetMirrorLockBusyCount, privacy: .public)")
            reportError(
                ["code": "widget-lock/busy", "message": "App Group lock busy"],
                context: ["context": "widgetLock", "operation": "mirror"]
            )
            scheduleWidgetMirrorBusyRetry()
        case .written, .unchanged, .skippedNoOwner:
            isWidgetMirrorDirty = false
            widgetMirrorBusyRetryAttempt = 0
        case .skippedOwnerChanged, .unavailable, .lockFailed, .encodingFailed:
            break
        }
        return outcome
    }

    /// Schedules the next busy retry, at most one at a time and at most one
    /// per `widgetMirrorBusyRetryDelays` entry per dirty episode. Non-forced:
    /// a forced write differs only in `updatedAt`, and the writer's 1-hour
    /// dedupe still rewrites an aged mirror.
    private func scheduleWidgetMirrorBusyRetry() {
        guard !widgetMirrorBusyRetryScheduled,
              widgetMirrorBusyRetryAttempt < widgetMirrorBusyRetryDelays.count
        else { return }
        let delay = widgetMirrorBusyRetryDelays[widgetMirrorBusyRetryAttempt]
        widgetMirrorBusyRetryAttempt += 1
        widgetMirrorBusyRetryScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self else { return }
            self.widgetMirrorBusyRetryScheduled = false
            guard self.isWidgetMirrorDirty else { return }
            self.refreshWidgetMirror(force: false)
        }
    }

    /// Trigger 3 (the 10.09 seam), stamped for the publish's
    /// `expectedOwnerBinding`, which must still equal `O` inside the lock.
    ///
    /// Contract §3.2 amendment (fix round 1): the seam projects the NEWEST
    /// canonical for the delivered owner. The publish captured its canonical
    /// before awaiting `notifySynchronize`; a local write (e.g. a clock-in)
    /// that landed during that suspension has already been mirrored by
    /// trigger 1, so writing the delivered canonical would roll the mirror
    /// back. When the revision moved on, project the live snapshot instead;
    /// otherwise project the delivered canonical and its business snapshot.
    /// Non-forced: the writer's 1-hour dedupe skips an unchanged mirror.
    private func writeWidgetMirrorFromSeam(
        canonical: Canonical.Snapshot,
        business: NativeBusinessSnapshot,
        expectedOwnerBinding: String,
        now: Date = Date()
    ) {
        guard let widgetMirror else { return }
        let movedOn = widgetSeamCapture.map { $0.revision != canonicalWriteRevision } ?? false
        let projection: WidgetSnapshot
        if movedOn {
            lastWidgetSeamSource = .live
            projection = NativeWidgetSnapshotProjection.project(
                jobs: snapshot.payload.jobs ?? [],
                business: makeCachedBusinessSnapshot(from: snapshot, now: now),
                now: now
            )
        } else {
            lastWidgetSeamSource = .delivered
            projection = NativeWidgetSnapshotProjection.project(
                jobs: canonical.payload.jobs ?? [],
                business: business,
                now: now
            )
        }
        noteWidgetMirrorOutcome(widgetMirror.write(
            projection: projection,
            ownerBinding: expectedOwnerBinding,
            isCurrentOwner: { [weak self] candidate in self?.widgetMirrorOwnerBinding == candidate },
            force: false,
            now: now
        ))
    }

    /// Coalesces trigger-1 writes to one per main-actor turn, so a burst of
    /// committed writes mirrors once, after the saves that preceded them.
    private func scheduleWidgetMirrorRefresh() {
        guard widgetMirror != nil, !widgetMirrorRefreshScheduled else { return }
        widgetMirrorRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.widgetMirrorRefreshScheduled = false
            self.refreshWidgetMirror(force: false)
        }
    }

    /// Thrown by the `makeSnapshot` closure above only in the theoretical case
    /// where `self` has already been deallocated when the seam fires; the
    /// publisher's own failure isolation treats it exactly like any other
    /// build failure (skip (b)/(c), leave the prior cache untouched).
    private struct NativeDerivedStatePublisherOwnerUnavailable: Error {}

    private func makeCachedBusinessSnapshot(
        from canonical: Canonical.Snapshot, now: Date
    ) -> NativeBusinessSnapshot {
        NativeBusinessSnapshotEngine.make(
            invoices: canonical.payload.invoices ?? [],
            jobs: canonical.payload.jobs ?? [],
            customers: canonical.payload.customers ?? [],
            expenses: canonical.payload.expenses ?? [],
            trips: canonical.payload.trips ?? [],
            values: canonical.payload.settings.map(NativeTaxSettingsValues.init(from:))
                ?? NativeTaxSettingsValues(),
            mileageRate: NativeMileage.effectiveRate(canonical.payload.settings),
            now: now
        )
    }

    private static func isSyncEligible(_ state: NativeAuthenticationGateState) -> Bool {
        switch state {
        case .signedIn, .startingPoint: return true
        default: return false
        }
    }

    private static func makeSyncReachability() -> any NativeSyncReachability {
        #if canImport(Network)
        NativeNetworkPathReachability()
        #else
        NativeAlwaysReachable()
        #endif
    }

    /// Builds the push coordinator once Supabase is configured and reuses it
    /// thereafter. Credentials are supplied lazily on every pass so the current
    /// Keychain session and verified subject are always used, never a stale copy.
    private func syncCoordinatorIfConfigured() -> NativeSyncCoordinator? {
        if let syncCoordinator { return syncCoordinator }
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else { return nil }
        let coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: supabaseURL,
                publishableKey: publishableKey,
                allowsWrites: BuildEnvironment.allowsSupabaseDataWrites
            ),
            queue: mutationQueue,
            reachability: syncReachability,
            credentialsProvider: { [weak self] in self?.currentSyncCredentials() },
            refreshSession: { [weak self] in await self?.refreshSyncSession() ?? false },
            // Phase 12 (12.00b.1, I2): a refused change leaves the queue for
            // the rejected-change store. Without an owner the change stays queued.
            settleRejected: { [weak self] settlement in
                guard let self else { throw NativeRejectedChangeStoreError.noOwner }
                try self.settleRejectedChanges(settlement)
            },
            pull: { [weak self] in await self?.pullDeltaIfPossible() ?? .skipped },
            statusChanged: { [weak self] status in self?.applySyncStatus(status) }
        )
        // Mirrored by the poor-network host harness (native/PoorNetworkTests,
        // `Harness.init`), which has no BuildEnvironment: keep the two in step.
        syncCoordinator = coordinator
        syncStatus = coordinator.status()
        return coordinator
    }

    /// The cursor-driven incremental pull the coordinator runs after each push.
    /// Reuses the injected initial-sync service when it supports delta pulls
    /// (tests inject one), otherwise builds the concrete Supabase service.
    private func deltaSyncServiceIfConfigured() -> (any NativeDeltaSyncServing)? {
        if let injected = initialSyncService as? any NativeDeltaSyncServing { return injected }
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else { return nil }
        return NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL,
            publishableKey: publishableKey
        )
    }

    /// Pulls remote changes since the stored cursor, merges them into the local
    /// snapshot, and atomically commits the merged snapshot with the advanced
    /// cursor. Best-effort: any failure leaves the snapshot and cursor untouched,
    /// so the next pass retries. An auth rejection refreshes the session once and
    /// retries the pull from the original cursor and snapshot (no partial commit).
    private func pullDeltaIfPossible() async -> NativeSyncPullResult {
        // Task 11.12: a DeltaPull signpost around the unchanged pull and
        // commit below; its outcome word is the pull result's state.
        let deltaPull = NativePerformanceMetrics.shared.begin(.deltaPull)
        let result = await pullDeltaAndCommit()
        NativePerformanceMetrics.shared.end(
            deltaPull,
            outcome: Self.performanceOutcome(result),
            count: performanceRecordCount()
        )
        return result
    }

    private func pullDeltaAndCommit() async -> NativeSyncPullResult {
        guard !persistenceWritesBlocked else { return .failed("pull/local-protection") }
        guard let service = deltaSyncServiceIfConfigured() else { return .skipped }
        guard let credentials = currentSyncCredentials() else { return .failed("pull/session") }
        let subject = credentials.subject
        // Phase 12 (12.00b.2-K, P12-016): the account generation this pull
        // starts under. A pull that spans an account boundary never lets
        // booking intake convert, even when the same owner is back, nor
        // (final review M1) a mirror merge; nor one that spans the scene
        // entering the background (`pullMarkPeriod`).
        let boundaryGeneration = accountBoundaryGeneration
        let markPeriod = pullMarkPeriod
        let cursor = syncCursorStore.load()
        let localSnapshot = snapshot
        // The snapshot the pulled candidate was merged into (11.12 Finding D):
        // the commit below rebases the delta from this base onto the live one.
        var pullBase = localSnapshot
        // Keys with a change waiting to reach the server when this pull read
        // its base (11.12 fix round 2, review I1). A direct caller is not
        // single-flight with the coordinator, so one of these can be pushed,
        // and leave the queue, while this pull is in flight.
        var pendingAtStart = pendingMutationKeys()
        // Phase 12 (12.00b.1): a refused change's record keeps its local
        // version until Retry or Discard. If the store cannot be read (a
        // device not yet unlocked since a restart), those records are
        // unknown: skip this pull rather than overwrite one.
        let rejectedAtStart: Set<String>
        do { rejectedAtStart = try rejectedChangeKeys() } catch { return .failed("pull/rejected-store") }

        let outcome: NativeDeltaPullOutcome
        do {
            outcome = try await service.pullDelta(
                sessionBytes: credentials.sessionBytes,
                expectedUserSubject: subject,
                localSnapshot: localSnapshot,
                cursor: cursor
            )
        } catch NativeInitialSyncError.rejectedSession {
            guard await refreshSyncSession(),
                  let fresh = currentSyncCredentials(),
                  fresh.subject == subject,
                  subject == authenticatedUserSubject
            else { return .failed("pull/authentication") }
            pullBase = snapshot
            pendingAtStart.formUnion(pendingMutationKeys())
            do {
                outcome = try await service.pullDelta(
                    sessionBytes: fresh.sessionBytes,
                    expectedUserSubject: subject,
                    localSnapshot: pullBase,
                    cursor: cursor
                )
            } catch {
                return .failed(Self.pullDiagnosticCode(for: error))
            }
        } catch {
            return .failed(Self.pullDiagnosticCode(for: error))
        }

        // The account or workspace may have changed during the network await;
        // never apply another owner's rows or write over a blocked workspace.
        guard subject == authenticatedUserSubject, !persistenceWritesBlocked else { return .skipped }
        // 11.12 Finding D (fix rounds 1 and 2): the candidate was merged into
        // the snapshot read before the network await, and local edits (or a
        // push of a queued edit) may have happened since. Merge the pulled
        // delta into the LIVE snapshot instead. The server's version of a record
        // is taken only when this device has not touched it: not pending at
        // this pull's start or now, and unchanged locally since the base (the
        // coordinator's rule: a pull never overwrites a record waiting to reach
        // the server, or one that just reached it). Where a local record is kept
        // over a server row this pull fetched, that table's watermark stays
        // where it was, so the next pull fetches the row again. No await between
        // here and the commit. If the rebase cannot be done, discard the
        // candidate and keep the cursor, so the next pull refetches.
        //
        // Phase 12 (12.00b.1, I2; contract §17.2 item 5): the pull now also
        // runs while changes are queued, so a record kept for a change that
        // is still queued at commit, or refused, must not hold its table's
        // watermark: a change that keeps failing, or a refusal waiting for
        // the owner, would pin that table's cursor forever and every pass
        // would refetch the same rows. Neither needs the refetch: a queued
        // change replaces the server's row when it lands (last writer wins),
        // and Discard fetches the refused record's current row itself. A
        // record pending at the start but pushed during the pull (11.12 I1)
        // still holds, as before.
        let pendingNow = pendingMutationKeys()
        let rejectedNow: Set<String>
        do { rejectedNow = try rejectedChangeKeys() } catch { return .failed("pull/rejected-store") }
        let rebase: PulledDeltaRebase
        do {
            rebase = try Self.rebasePulledDelta(
                base: pullBase,
                pulled: outcome.snapshot,
                live: snapshot,
                protectedKeys: pendingAtStart.union(pendingNow).union(rejectedAtStart).union(rejectedNow),
                unheldKeys: pendingNow.union(rejectedNow)
            )
        } catch {
            return .failed("pull/local-rebase")
        }
        var committedCursor = outcome.cursor
        for table in rebase.heldCursorTables {
            committedCursor.tables[table] = cursor.tables[table]
        }
        do { try commitSnapshot(rebase.snapshot) }
        catch { return .failed("pull/local-commit") }
        do { try syncCursorStore.save(committedCursor) }
        catch { return .failed("pull/cursor-commit") }
        // Phase 12 (12.00b.2-I fix round 1, review I1): pending booking and
        // portal mirrors may merge once a pull has brought the settings and
        // customer rows. A partial pull that missed either does not count.
        if outcome.failedTables.allSatisfy({ !Self.scheduleBookingMirrorTables.contains($0) }) {
            markScheduleBookingRecoveryPullCommitted(subject: subject, generation: boundaryGeneration, period: markPeriod)
        }
        // Phase 12 (12.00b.2-K, P12-016): booking intake may convert from
        // this pull only when every table committed.
        if outcome.failedTables.isEmpty {
            markBookingIntakePullCommitted(subject: subject, generation: boundaryGeneration, period: markPeriod)
        }
        // Sync completion is the generation trigger (mirrors RN app-open /
        // foreground): pulled rules and jobs are in the snapshot, so due
        // occurrences materialize before any recurrence-manager refresh reads
        // them. A no-op when nothing is due; never fails the pull.
        refreshRecurringJobs()
        // Fix round 2 (G5): a pull can resurrect a Square token from another
        // device's (or an old RN build's) settings blob; heal it locally and
        // queue the cleaned blob. A no-op when nothing needs scrubbing.
        scrubLegacySquareToken()
        // Task 10.09 (B1): the post-sync-commit seam, invoked exactly once
        // per commit this call makes — never on an offline/signed-out/
        // pre-commit-failed pass: every such pass returns above, before ever
        // reaching this line. `pullDeltaIfPossible` has several call sites
        // (the coordinator's own pull closure, plus direct calls from the
        // booking response/reschedule/portal-admin recovery paths) — each
        // one that reaches here is its own commit and publishes once, from
        // ITS committed snapshot; this is not a single funnel, and a caller
        // that performs two separate commits (e.g. `prepareBookingReschedule`
        // calling `syncNowAndWait` and then this function directly)
        // correctly publishes twice. `NativeDerivedStatePublisher`'s
        // generation guard keeps those publishes ordered even if an older
        // one resumes, after suspending here, later than a newer one. A
        // partial pull (`outcome.failedTables` non-empty) still committed
        // whatever tables it did and publishes from that committed snapshot.
        // Reads `snapshot`, the just-committed canonical truth (including any
        // recurring-job materialization just above), never a stale copy read
        // separately. The owner binding is the one verified for this exact
        // pass, just above; the seam re-verifies it again before touching
        // each output and after its own awaits.
        // Final-review I6: exact-workspace binding only (see
        // `derivedStatePublishBinding`); a gate that moved to
        // `.accountMismatch`/`.unavailable` during the pull await skips it.
        if let binding = derivedStatePublishBinding, subject == authenticatedUserSubject {
            await publishDerivedState(expectedOwnerBinding: binding)
        }
        if !outcome.failedTables.isEmpty {
            return .partial(outcome.lastDiagnosticCode)
        }
        return .completed
    }

    /// Runs one push pass in the background. A missing configuration, an empty
    /// queue, or a signed-out device all resolve to a clean no-op inside the
    /// coordinator, so callers never need to pre-check.
    func syncNow(trigger: NativeSyncTrigger = .manual) {
        guard let coordinator = syncCoordinatorIfConfigured() else {
            syncStatus = NativeSyncStatus(
                pendingCount: mutationQueue.load().count,
                diagnosticCode: "sync/configuration"
            )
            return
        }
        syncStatus = coordinator.status()
        Task { await coordinator.sync(trigger: trigger) }
    }

    /// Manual/status-screen entry point that waits for the pass to finish. It
    /// is also used by the unsynced-change sign-out path so cleanup never races
    /// an in-flight upload.
    @discardableResult
    func syncNowAndWait(trigger: NativeSyncTrigger = .manual) async -> NativeSyncOutcome? {
        guard let coordinator = syncCoordinatorIfConfigured() else {
            syncStatus = NativeSyncStatus(
                pendingCount: mutationQueue.load().count,
                diagnosticCode: "sync/configuration"
            )
            return nil
        }
        let outcome = await coordinator.sync(trigger: trigger)
        if outcome == .alreadyRunning {
            return await coordinator.waitUntilIdle()
        }
        return outcome
    }

    /// Pull-to-refresh mirrors React Native's awaited sync before a local
    /// reload. Native screens already observe the canonical in-memory snapshot,
    /// so the completed delta-pull publication is the reload boundary here.
    @discardableResult
    func performPullToRefresh(
        screen: NativeAnalyticsEvent.RefreshScreen? = nil
    ) async -> NativeSyncOutcome? {
        await performPullToRefresh(screen: screen) { await self.syncNowAndWait(trigger: .manual) }
    }

    /// The pull-to-refresh body with its sync step injected, so the host tests
    /// can change the owner while the sync is suspended.
    private func performPullToRefresh(
        screen: NativeAnalyticsEvent.RefreshScreen?,
        sync: () async -> NativeSyncOutcome?
    ) async -> NativeSyncOutcome? {
        let owner = authenticatedUserSubject
        let outcome = await sync()
        // Task 11.08: RN `hooks/useRefresh.ts:17` — after the sync and
        // reload, whatever the result, only for Money and Jobs. An owner
        // change during the await drops it so the event can never be
        // attributed to the next identity (§9.4).
        if let screen, owner != nil, owner == authenticatedUserSubject {
            emitAnalytics(.pullToRefresh(screen))
        }
        return outcome
    }

    /// Phase 12 final review (M1, R54 N1): the scene entered the background.
    /// Clears both pull marks, and advances the period so a pull in flight
    /// cannot set them when it commits. The next activation's gate sites
    /// (its identity apply, a subscription gate still resolving from this
    /// period) start passes before that activation's pull, so they must not
    /// see this period's mark. Called by `TradeReadyNativeApp` on
    /// `.background`.
    func sceneDidEnterBackground() {
        pullMarkPeriod &+= 1
        scheduleBookingRecoveryPullMark = nil
        bookingIntakePullMark = nil
    }

    /// Foreground ordering matches the React Native oracle: metadata sync first,
    /// then pending byte uploads and missing-file backfill. A second sync makes
    /// newly confirmed `uploadedAt` values visible to the user's other devices.
    func performForegroundRefresh() async {
        // Task 11.01 (contract §3.1 trigger 2): foreground re-mirror.
        // Activation (which replays widget actions) runs before this in
        // `TradeReadyNativeApp`, so a just-replayed `timer_start` is
        // reflected. Runs on every exit path. Non-forced (fix round 1): the
        // seam already wrote any pulled change, and the 1-hour dedupe still
        // rewrites a mirror that is an hour old, so a stale one is refreshed.
        defer { refreshWidgetMirror(force: false) }
        // Phase 12 (12.00b.2-I fix round 1, review I1): only this refresh's
        // own pull (or a later one) lets the recovery below merge a mirror.
        scheduleBookingRecoveryPullMark = nil
        // Phase 12 (12.00b.2-K, P12-016): and lets the intake below convert.
        bookingIntakePullMark = nil
        let synced = await syncNowAndWait(trigger: .foreground) != nil
        // Mirrors RN's foreground `checkAndGenerateRecurringJobs`: runs after
        // the sync when it succeeds, and on the local snapshot when offline —
        // and before photo transfer or any Batch 2 recurrence-manager refresh.
        // Both are gated on the initial sync having committed (fix round 3):
        // an activation during the initial-sync await generates nothing.
        refreshRecurringJobs()
        refreshRecurringInvoices()
        rescheduleInvoiceDeliveries()
        // Phase 12 (12.00b.2-K, P12-016): customer bookings the pull brought
        // become lead jobs and customers (RN: `syncIfOnline`, then
        // `applyBookingRequests`, `context/AuthContext.tsx:118-120`). Only
        // when this refresh's pull (or a later one) committed every table,
        // and from that pull: no second pull. Before recovery: intake makes
        // no network call and commits without waiting, so the new jobs do not
        // wait on recovery's status reads, and it converts from the pull that
        // just committed before those reads give another activation (which
        // clears the mark) time to begin. Each builds its write from the live
        // snapshot at its own commit, so neither drops the other's change.
        await runBookingIntakeIfPossible()
        // Phase 12 (12.00b.2-I, P12-013): finish unfinished booking/portal
        // link work and clear reschedule proofs that can no longer resolve,
        // after the sync so the pulled request and job states are current.
        // This owns a warm activation's mirrors (fix round 1): the passes
        // the activation's gate sites started could not merge one. If this
        // refresh's pull did not commit (offline, or a failed settings or
        // customers table), mirrors are not read and wait for a later pass.
        await recoverScheduleBookingPendingWorkIfPossible()
        guard synced else { return }
        let photos = await performJobPhotoTransfer()
        if photos.uploadedCount > 0 {
            _ = await syncNowAndWait(trigger: .localChange)
        }
    }

    /// Mirrors local-first JobPhoto bytes through the authenticated worker.
    /// Metadata plus deterministic file presence form the durable resume state:
    /// a crash before `uploadedAt` is committed safely repeats the idempotent PUT,
    /// while each atomically installed download disappears from the next pass.
    @discardableResult
    func performJobPhotoTransfer() async -> NativeJobPhotoTransferOutcome {
        var result = NativeJobPhotoTransferOutcome()
        guard !jobPhotoTransferInFlight, !persistenceWritesBlocked,
              let subject = authenticatedUserSubject,
              let binding = verifiedAccountBinding,
              hasCompletedPersistedWorkspace(binding: binding),
              let service = configuredJobPhotoTransferService()
        else { return result }

        jobPhotoTransferInFlight = true
        result.didRun = true
        defer { jobPhotoTransferInFlight = false }

        let mediaRoot = repository.liveMediaDirectoryURL
        func ownerIsCurrent() -> Bool {
            subject == authenticatedUserSubject
                && binding == verifiedAccountBinding
                && !persistenceWritesBlocked
                && hasCompletedPersistedWorkspace(binding: binding)
        }

        // Uploads are sequential and bounded by the current canonical set.
        // Never remove or rewrite the local source bytes after a server result.
        let uploadCandidates = (snapshot.payload.jobPhotos ?? []).filter { $0.uploadedAt == nil }
        for candidate in uploadCandidates {
            guard !Task.isCancelled, ownerIsCurrent() else { return result }
            let bytes: Data
            do {
                guard let local = try NativeJobPhotoStorage.uploadBytes(
                    root: mediaRoot,
                    photoID: candidate.id
                ) else { continue }
                bytes = local
            } catch {
                result.failedCount += 1
                continue
            }
            guard let credentials = currentSyncCredentials(), credentials.subject == subject else {
                return result
            }
            let uploadedAt: String
            do {
                uploadedAt = try await service.upload(
                    photoID: candidate.id,
                    bytes: bytes,
                    sessionBytes: credentials.sessionBytes
                )
            } catch {
                result.failedCount += 1
                continue
            }
            guard !Task.isCancelled, ownerIsCurrent(),
                  var photos = snapshot.payload.jobPhotos,
                  let index = photos.firstIndex(where: {
                      $0.id == candidate.id && $0.jobId == candidate.jobId
                  }),
                  photos[index].uploadedAt == nil
            else { continue }

            photos[index].uploadedAt = uploadedAt
            var committed = snapshot
            committed.payload.jobPhotos = photos
            do {
                // Queue first. If the following snapshot commit fails, the
                // confirmed metadata still reaches the owner-scoped server and
                // returns through a later pull; no successful upload is lost.
                try mutationQueue.enqueue(
                    table: "jobPhotos",
                    op: .upsert,
                    recordId: photos[index].id,
                    payload: try Self.mutationPayload(photos[index])
                )
                try commitSnapshot(committed)
                result.uploadedCount += 1
            } catch {
                result.failedCount += 1
                recordLocalSyncFailure("photo/commit")
            }
        }

        // Re-read after uploads so concurrent canonical changes are respected.
        let downloadCandidates = (snapshot.payload.jobPhotos ?? []).filter { $0.uploadedAt != nil }
        for candidate in downloadCandidates {
            guard !Task.isCancelled, ownerIsCurrent() else { return result }
            let destination: URL
            do { destination = try NativeJobPhotoStorage.photoURL(root: mediaRoot, photoID: candidate.id) }
            catch {
                result.failedCount += 1
                continue
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            guard let credentials = currentSyncCredentials(), credentials.subject == subject else {
                return result
            }
            let bytes: Data
            do {
                bytes = try await service.download(
                    photoID: candidate.id,
                    sessionBytes: credentials.sessionBytes
                )
            } catch {
                result.failedCount += 1
                continue
            }
            guard !Task.isCancelled, ownerIsCurrent(),
                  snapshot.payload.jobPhotos?.contains(where: {
                      $0.id == candidate.id && $0.jobId == candidate.jobId && $0.uploadedAt != nil
                  }) == true
            else { continue }
            do {
                if try NativeJobPhotoStorage.installDownloadedBytes(
                    bytes,
                    root: mediaRoot,
                    photoID: candidate.id
                ) == .installed {
                    result.downloadedCount += 1
                }
            } catch {
                result.failedCount += 1
            }
        }
        if result.failedCount > 0 {
            print("TradeReadyJobPhotoTransfer stage=partial")
        }
        return result
    }

    // MARK: Phase 12 (12.06): rollback readiness

    /// The last check for the account now on this device, or nil (none yet,
    /// or it was made before an account boundary).
    var currentRollbackReadinessCheck: NativeRollbackReadinessCheck? {
        guard let check = rollbackReadinessCheck, check.accountGeneration == accountBoundaryGeneration else {
            return nil
        }
        return check
    }

    /// Phase 12 (12.06, charter §6 item 2): whether this account is safe to
    /// move to the Expo rollback build, from local state only (no network,
    /// no write). Each fail-closed condition is a blocker of its own; so is
    /// anything still only on this device. A refused change is listed for
    /// Retry or Discard (Settings › Cloud Sync), never dropped.
    ///
    /// RN parity: the Expo build pushes its own AsyncStorage `__syncQueue`
    /// before it pulls (`utils/sync.ts:316-326`), and it never sees this
    /// device's native queue, refused changes, widget replay queue or native
    /// photo files; so all of them must be empty here first. Booking/portal
    /// link work is reported as a note only (fix round 2, R46).
    func rollbackReadiness() -> NativeRollbackReadiness {
        var readiness = NativeRollbackReadiness()
        let binding = verifiedAccountBinding
        if !hasExactSignedInWorkspace { readiness.block(.notVerifiedOwner) }
        if authenticatedUserSubject == nil || initialSyncCompletedSubject != authenticatedUserSubject {
            readiness.block(.initialSyncIncomplete)
        }
        if persistenceWritesBlocked { readiness.block(.writesBlocked) }
        if repository.isAccountScrubPending || isAccountScrubBlocked
            || accountDeletionPendingWithoutMarker || accountDeletionRecordUnverified {
            readiness.block(.accountScrubPending)
        }
        if isAccountBoundaryCleanupPending || widgetMirrorSuspendedForAccountBoundary
            || Canonical.SnapshotRepository.BoundaryStep.allCases.contains(where: isBoundaryStepPending) {
            readiness.block(.boundaryStepPending)
        }
        if accountSwitchInFlight || authenticationOperationInFlight || identityActivationInFlight {
            readiness.block(.accountOperationInFlight)
        }

        do {
            switch try migrationJournal.read().entries.last(where: { $0.migration == .reactNativeAsyncStorage })?.status {
            case .completed?: readiness.migrationJournal = .completed
            case nil: readiness.migrationJournal = .noEntry
            case .started?:
                readiness.migrationJournal = .started
                readiness.block(.migrationIncomplete)
            case .failed?:
                readiness.migrationJournal = .failed
                readiness.block(.migrationIncomplete)
            }
        } catch {
            readiness.migrationJournal = .unreadable
            readiness.block(.migrationUnreadable)
        }
        if isLegacyMigrationBlocked { readiness.block(.migrationIncomplete) }

        if let queued = mutationQueue.loadIfReadable() {
            readiness.pendingChangeCount = queued.count
            if !queued.isEmpty { readiness.block(.pendingChanges) }
        } else {
            readiness.block(.pendingChangesUnreadable)
        }

        // Every entry on file, including one hidden while its Retry is
        // queued. A file with no entry for this owner is another owner's or
        // does not decode (the store removes an emptied file): never "none".
        do {
            let refused = try rejectedChangeStore.load(binding: binding)
            readiness.rejectedChangeCount = refused.count
            readiness.rejectedChangeIDs = refused.map(\.id)
            if !refused.isEmpty { readiness.block(.rejectedChanges) }
            if refused.isEmpty && rejectedChangeStore.fileIsPresent() { readiness.block(.rejectedChangesUnreadable) }
        } catch {
            readiness.block(.rejectedChangesUnreadable)
        }

        if let binding {
            if let widgetActionReplayTransport,
               let pending = try? widgetActionReplayTransport.pendingActionCount(verifiedAccountBinding: binding) {
                readiness.widgetActionCount = pending
                if pending > 0 { readiness.block(.widgetActionsPending) }
            } else {
                readiness.block(.widgetActionsUnreadable)
            }
            // 8.08 booking/portal link work: a note, never a blocker (fix
            // round 2, R46). A mirror item records a change the server
            // already made; a reschedule proof guards a server resolve whose
            // job change is in the ordinary queue (counted above). Neither
            // holds business data the Expo build would miss. Activation and
            // launch recover them (12.00b.2-I, P12-013), never this check:
            // an item still here is a mirror whose status read has not
            // succeeded yet, or a proof whose resolve can still succeed.
            // Another binding's items are that account's (its boundary
            // scrubs them), never this one's.
            if let work = pendingScheduleBookingWorkStore().loadIfReadable() {
                // A staged record batch (P12-028) is business data saved on
                // this device and not yet queued, so it is a waiting change
                // and blocks; mirrors and proofs stay a note.
                var stagedCount = 0
                var noteCount = 0
                for item in work where item.ownerBinding == binding {
                    if case let .stagedBatch(drafts, _) = item.kind { stagedCount += drafts.count } else { noteCount += 1 }
                }
                if stagedCount > 0 {
                    readiness.pendingChangeCount += stagedCount
                    readiness.block(.pendingChanges)
                }
                readiness.bookingWorkCount = noteCount
                if readiness.bookingWorkCount > 0 { readiness.note(.bookingWorkPending) }
            } else {
                readiness.note(.bookingWorkUnreadable)
            }
        }

        // A photo never uploaded whose bytes are still here. One whose bytes
        // are gone cannot upload from anywhere, so it cannot hold the check.
        let mediaRoot = repository.liveMediaDirectoryURL
        readiness.photosPendingUploadCount = (snapshot.payload.jobPhotos ?? []).filter { photo in
            guard photo.uploadedAt == nil,
                  let url = try? NativeJobPhotoStorage.photoURL(root: mediaRoot, photoID: photo.id)
            else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }.count
        if readiness.photosPendingUploadCount > 0 { readiness.block(.photosPendingUpload) }
        return readiness
    }

    /// Phase 12 (12.06): "Check everything is saved" (Settings › Cloud Sync),
    /// run before support advises installing the Expo rollback build. Unless
    /// a fail-closed condition holds (then nothing is sent), it replays the
    /// widget/Siri queue, forces a push pass, uploads waiting photos (and
    /// pushes their metadata), then reads `rollbackReadiness()`. Returns nil
    /// while a check is already running.
    @discardableResult
    func prepareRollbackReadiness() async -> NativeRollbackReadinessCheck? {
        await prepareRollbackReadiness { await self.drainForRollbackReadiness() }
    }

    /// The forced push pass: `manual` bypasses the backoff window. Returns
    /// the pass's outcome code (the second pass's when photos uploaded).
    private func drainForRollbackReadiness() async -> String {
        guard let outcome = await syncNowAndWait(trigger: .manual) else { return "not-configured" }
        let photos = await performJobPhotoTransfer()
        if photos.uploadedCount > 0, let metadata = await syncNowAndWait(trigger: .localChange) {
            return Self.supportCode(for: metadata)
        }
        return Self.supportCode(for: outcome)
    }

    /// The check with its drain injected, so a host test can change the
    /// owner while it is suspended. An account boundary, or any change of
    /// the verified subject or binding, during the await voids the result:
    /// it reports `accountChanged` only (nothing about the account now on
    /// the device) and is kept under the account it started with, so the
    /// next account never sees it.
    private func prepareRollbackReadiness(
        drain: () async -> String
    ) async -> NativeRollbackReadinessCheck? {
        guard !isRollbackReadinessCheckRunning else { return nil }
        isRollbackReadinessCheckRunning = true
        defer { isRollbackReadinessCheckRunning = false }
        let generation = accountBoundaryGeneration
        let subject = authenticatedUserSubject
        let binding = verifiedAccountBinding
        var drainOutcome = "skipped"
        if !rollbackReadiness().failsClosed {
            replayVerifiedWidgetActionsIfPossible()
            drainOutcome = await drain()
        }
        var readiness: NativeRollbackReadiness
        if generation != accountBoundaryGeneration || subject != authenticatedUserSubject
            || binding != verifiedAccountBinding {
            readiness = NativeRollbackReadiness()
            readiness.block(.accountChanged)
        } else {
            readiness = rollbackReadiness()
        }
        let check = NativeRollbackReadinessCheck(
            readiness: readiness, drainOutcome: drainOutcome, checkedAt: Date(), accountGeneration: generation
        )
        rollbackReadinessCheck = check
        Self.stageLogger.notice(
            "TradeReadyRollbackReadiness stage=checked ready=\(readiness.isReady, privacy: .public) blockers=\(readiness.blockers.count, privacy: .public)"
        )
        return check
    }

    /// Runs the bounded work behind a BGAppRefreshTask. A suspended process can
    /// reuse its already verified identity. A cold background launch performs
    /// the same server verification/refresh as foreground activation, but it
    /// may attach that identity only to an exact, completed owner-bound local
    /// workspace. It never advances onboarding/subscription UI or adopts an
    /// unbound snapshot while no foreground is present.
    func performBackgroundRefresh() async -> NativeBackgroundRefreshOutcome {
        // Task 11.12: a BackgroundRefresh signpost around the unchanged pass.
        // A background-only cold launch has no root view to end the Launch
        // interval; end it here as skipped (a no-op after a foreground launch).
        NativePerformanceMetrics.shared.endLaunchInBackground()
        let backgroundRefresh = NativePerformanceMetrics.shared.begin(.backgroundRefresh)
        let outcome = await runBackgroundRefresh()
        NativePerformanceMetrics.shared.end(backgroundRefresh, outcome: Self.performanceOutcome(outcome))
        return outcome
    }

    private func runBackgroundRefresh() async -> NativeBackgroundRefreshOutcome {
        guard !Task.isCancelled else { return .failed }
        guard !persistenceWritesBlocked else { return .failed }
        guard await prepareBackgroundIdentityIfNeeded() else { return .skipped }
        guard !Task.isCancelled else { return .failed }
        guard let refreshSubject = authenticatedUserSubject,
              let refreshBinding = verifiedAccountBinding
        else { return .skipped }

        guard await syncNowAndWait(trigger: .periodic) != nil else { return .failed }
        guard !Task.isCancelled else { return .failed }
        guard refreshSubject == authenticatedUserSubject,
              refreshBinding == verifiedAccountBinding
        else { return .skipped }

        let photos = await performJobPhotoTransfer()
        guard !Task.isCancelled else { return .failed }
        guard refreshSubject == authenticatedUserSubject,
              refreshBinding == verifiedAccountBinding
        else { return .skipped }
        if photos.uploadedCount > 0 {
            guard await syncNowAndWait(trigger: .periodic) != nil else { return .failed }
        }

        // Match the React Native task order: cloud sync first, then safely
        // commit/acknowledge any exact-owner widget or Siri actions. Offline
        // sync is a no-op, but local action replay must still get its chance.
        replayVerifiedWidgetActionsIfPossible()
        // Task 11.01 (contract §3.1 trigger 2): re-mirror after replay.
        // Non-forced (fix round 1): see `performForegroundRefresh`.
        refreshWidgetMirror(force: false)
        return .completed
    }

    private func prepareBackgroundIdentityIfNeeded() async -> Bool {
        if authenticatedUserSubject != nil,
           let binding = verifiedAccountBinding,
           hasCompletedPersistedWorkspace(binding: binding)
        {
            return true
        }
        guard !identityActivationInFlight, !authenticationOperationInFlight else { return false }
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else { return false }

        identityActivationInFlight = true
        defer { finishIdentityActivation() }
        let activator: NativeAuthenticatedIdentityActivator
        if let existing = authenticatedIdentityActivator {
            activator = existing
        } else {
            let verifier = NativeSupabaseAuthenticatedIdentityVerifier(
                supabaseURL: supabaseURL,
                publishableKey: publishableKey
            )
            let created = NativeAuthenticatedIdentityActivator(
                snapshotURL: fileURL,
                sessionStore: secureSettingsStore,
                verifier: verifier,
                refresher: verifier
            )
            authenticatedIdentityActivator = created
            activator = created
        }

        // Phase 12 (12.00b.2-G fix round 1, R31): see `completeIdentityActivation`.
        let boundaryGeneration = accountBoundaryGeneration
        do {
            let activated = try await activator.activate()
            guard accountBoundaryGeneration == boundaryGeneration else {
                discardIdentityActivationOvertakenByAccountBoundary()
                return false
            }
            guard let outcome = activated,
                  !Task.isCancelled,
                  outcome.accountState != .ownerMismatch,
                  hasCompletedPersistedWorkspace(binding: outcome.verifiedAccountBinding)
            else { return false }

            // These fields are the minimum credentials/owner evidence consumed
            // by sync and durable widget replay. Foreground activation still
            // owns all routing, initial-sync, onboarding, and subscription UI.
            migratedAccountState = outcome.typedAccountState
            isMigratedLocalOwnerVerified = outcome.localOwnerVerified
            migratedAccountBinding = outcome.accountBinding
            verifiedAccountBinding = outcome.verifiedAccountBinding
            authenticatedUserSubject = outcome.verifiedUserSubject
            authenticatedEmail = outcome.verifiedEmail ?? authenticatedEmail
            // Task 11.08 (§9.4): a background-verified owner is identified
            // like a foreground one (a different id resets first).
            applyAnalyticsIdentityVerified(outcome.verifiedUserSubject)
            activateCustomerDuplicateDismissals(
                accountBinding: outcome.verifiedAccountBinding,
                migratedKeys: outcome.typedAccountState?.dismissedDuplicatePairs
            )
            activateReviewRequests(
                accountBinding: outcome.verifiedAccountBinding,
                migrated: outcome.typedAccountState?.reviewRequests
            )
            activateReminderPromptFlag(
                accountBinding: outcome.verifiedAccountBinding,
                migratedShown: outcome.typedAccountState?.invoiceReminderPromptShown
            )
            activateInsightMutes(
                accountBinding: outcome.verifiedAccountBinding,
                migrated: outcome.typedAccountState?.insightMutes
            )
            activateSetupChecklist(
                accountBinding: outcome.verifiedAccountBinding,
                migrated: outcome.typedAccountState?.setupChecklistState
            )
            return true
        } catch {
            if accountBoundaryGeneration != boundaryGeneration {
                discardIdentityActivationOvertakenByAccountBoundary()
            }
            return false
        }
    }

    private func scheduleSyncAfterLocalChange() {
        syncNow(trigger: .localChange)
    }

    // MARK: Phase 12 (12.00b.1, I2): refused changes

    /// The settle step `syncCoordinatorIfConfigured` hands the coordinator:
    /// files the refused changes of one push attempt in the owner's
    /// rejected-change store and clears the entries of records whose newer
    /// change the server accepted. Throwing keeps the whole attempt queued
    /// (the coordinator re-sends it next pass), so a refusal is never lost:
    /// there must be a verified owner, and no account switch or pending
    /// boundary scrub (that file is about to be removed). An attempt with no
    /// refusal needs no owner while no file is on disk. With a file but no
    /// verified binding (a rejected session keeps the subject; review M2)
    /// it throws too: the entry its accepted change clears cannot be found,
    /// and skipping it would leave a Retry that sends the older change.
    private func settleRejectedChanges(_ settlement: NativeMutationPushSettlement) throws {
        try refetchRowsOfSupersededChanges(settlement.superseded)
        let ownerChanging = accountSwitchInFlight || isBoundaryStepPending(.rejectedChangesScrub)
        if settlement.rejected.isEmpty {
            guard !ownerChanging else { return }
            guard verifiedAccountBinding != nil else {
                if rejectedChangeStore.fileIsPresent() { throw NativeRejectedChangeStoreError.noOwner }
                return
            }
        }
        guard !ownerChanging else { throw NativeRejectedChangeStoreError.noOwner }
        let dropped = try rejectedChangeStore.settle(
            rejected: settlement.rejected,
            clearedKeys: Set(settlement.cleared.map(NativeRejectedChange.key)),
            supersededChanges: settlement.superseded,
            binding: verifiedAccountBinding,
            now: Date()
        )
        reportRejectedChanges(settlement.rejected, dropped: dropped)
        refreshRejectedChanges()
    }

    /// Phase 12 (12.00b.2-L, P12-017): a guarded change the server did not
    /// apply (its row was written after this device's pull) has left the
    /// queue. The pull that follows must fetch that row again, although a
    /// pull while the change was queued may have moved the table's watermark
    /// past it (a record with a queued change keeps its local version and
    /// does not hold the watermark, `pullDeltaAndCommit`). So the table's
    /// watermark goes back to the change's guard, the watermark it was made
    /// from: the row's later write is at or after it. Nothing is queued for
    /// the record any more, so that pull's rebase takes the server's row.
    /// Throwing keeps the attempt queued (the coordinator sends it again).
    private func refetchRowsOfSupersededChanges(_ superseded: [Canonical.MutationItem]) throws {
        guard !superseded.isEmpty else { return }
        var cursor = syncCursorStore.load()
        var lowered = false
        for item in superseded {
            guard let since = item.ifUnchangedSince, let current = cursor.tables[item.table] else { continue }
            guard let sinceDate = Canonical.NativeSyncCursor.parse(since) else {
                // Unreadable: fetch the whole table again.
                cursor.tables[item.table] = nil
                lowered = true
                continue
            }
            if let currentDate = Canonical.NativeSyncCursor.parse(current), currentDate <= sinceDate { continue }
            cursor.tables[item.table] = since
            lowered = true
        }
        if lowered { try syncCursorStore.save(cursor) }
    }

    /// One bounded report per settle with a refusal, through the Phase 11
    /// redaction path: the first refusal's table and status and the count,
    /// never a record, name or payload. Its own context, so refusals group
    /// apart from `pushQueue` (changes still queued).
    private func reportRejectedChanges(_ rejected: [NativeMutationRejection], dropped: Int) {
        if let first = rejected.first {
            let code = "rejected/\(first.item.table)/\(first.statusCode)"
            Self.stageLogger.notice(
                "TradeReadyRejectedChanges stage=filed table=\(first.item.table, privacy: .public) status=\(first.statusCode, privacy: .public) count=\(rejected.count, privacy: .public)"
            )
            reportError(
                ["code": code, "message": "Sync push refused changes"],
                context: ["context": "pushRejected", "collection": first.item.table,
                          "status": first.statusCode, "count": rejected.count]
            )
        }
        guard dropped > 0 else { return }
        rejectedChangeOverflowCount = min(Self.rejectedChangeCounterCap, rejectedChangeOverflowCount + dropped)
        Self.stageLogger.error("TradeReadyRejectedChanges stage=overflow count=\(dropped, privacy: .public)")
        reportError(
            ["code": "rejected-store/overflow", "message": "Refused changes over the limit were dropped"],
            context: ["context": "pushRejected", "count": dropped]
        )
    }

    /// The owner's entries shown in Settings › Cloud Sync, oldest first: none
    /// while the owner is changing, and none for a record that has a change
    /// queued (a Retry, or a newer edit, which supersedes the refusal).
    private func visibleRejectedChanges() throws -> [NativeRejectedChange] {
        guard !accountSwitchInFlight, !isBoundaryStepPending(.rejectedChangesScrub) else { return [] }
        let entries = try rejectedChangeStore.load(binding: verifiedAccountBinding)
        guard !entries.isEmpty else { return [] }
        let queued = pendingMutationKeys()
        return entries.filter { !queued.contains($0.key) }
    }

    /// Reloads `rejectedChanges`. An unreadable store (before the first
    /// unlock after a restart) keeps the list last shown.
    func refreshRejectedChanges() {
        guard let visible = try? visibleRejectedChanges() else { return }
        if rejectedChanges != visible { rejectedChanges = visible }
    }

    /// Every refused record's key, including one hidden while its Retry is
    /// queued. The pull keeps these records' local versions. Throws when the
    /// store cannot be read, or when a file is on disk but no binding says
    /// whose it is (review M2), so the pull can fail closed.
    private func rejectedChangeKeys() throws -> Set<String> {
        guard verifiedAccountBinding != nil else {
            if rejectedChangeStore.fileIsPresent() { throw NativeRejectedChangeStoreError.noOwner }
            return []
        }
        return Set(try rejectedChangeStore.load(binding: verifiedAccountBinding).map(\.key))
    }

    /// The name the Cloud Sync list shows for an entry: from the change
    /// itself, or, for a delete, the record still on this device.
    func rejectedChangeName(_ change: NativeRejectedChange) -> String? {
        let table = change.item.table
        if let name = NativeRejectedChangeDisplay.name(table: table, payload: change.item.payload) { return name }
        let id = change.item.recordId
        switch table {
        case "jobs": return jobs.first { $0.id == id }?.title
        case "invoices": return invoices.first { $0.id == id }?.number
        case "customers": return customers.first { $0.id == id }?.name
        case "expenses": return expenses.first { $0.id == id }?.merchant
        default: return nil
        }
    }

    /// Retry (owner decision D3): sends the refused change again through the
    /// normal queue, so it coalesces with any newer edit of the record (last
    /// writer wins) and its entry is hidden while queued. The push files it
    /// again if the server refuses again; the pass that sends it never sends
    /// it twice. Returns false when nothing was queued.
    @discardableResult
    func retryRejectedChange(id: String) -> Bool {
        guard !persistenceWritesBlocked,
              let entry = (try? visibleRejectedChanges())?.first(where: { $0.id == id })
        else { return false }
        do {
            try mutationQueue.enqueue(
                table: entry.item.table,
                op: entry.item.op,
                recordId: entry.item.recordId,
                payload: entry.item.payload,
                ifUnchangedSince: entry.item.ifUnchangedSince
            )
        } catch {
            Self.stageLogger.error("TradeReadyMutationQueue stage=enqueue-retry table=\(entry.item.table, privacy: .public)")
            recordLocalSyncFailure("queue/enqueue-retry")
            return false
        }
        refreshRejectedChanges()
        scheduleSyncAfterLocalChange()
        return true
    }

    static let rejectedChangeUnavailableMessage =
        "Cloud Sync isn't available right now. Nothing was changed."
    static let rejectedChangeGoneMessage =
        "This change is no longer waiting. Nothing was changed."
    static let rejectedChangeOfflineMessage =
        "Couldn't load the cloud version. Nothing was changed. Try again when you're online."
    static let rejectedChangeRaceMessage =
        "This record changed while its cloud version was loading. Nothing was changed. Try again."
    static let rejectedChangeCommitMessage =
        "Couldn't show the cloud version. Nothing was changed."
    static let rejectedChangeClearMessage =
        "The cloud version is shown, but this entry couldn't be cleared. Try Discard again."

    /// Discard (owner decision D3): drops the refused change and shows the
    /// server's current version of the record. One targeted fetch of that
    /// record (not a cursor rewind): the server's row replaces this device's
    /// copy, and a record the server does not have (a refused insert) is
    /// removed from this device. Nothing is queued. Returns nil on success,
    /// or a message when nothing was changed.
    func discardRejectedChange(id: String) async -> String? {
        guard ensurePersistenceWritable() else { return Self.persistenceReadOnlyMessage }
        guard let binding = verifiedAccountBinding, let subject = authenticatedUserSubject
        else { return Self.rejectedChangeUnavailableMessage }
        let entry: NativeRejectedChange
        do {
            guard let found = try visibleRejectedChanges().first(where: { $0.id == id }) else {
                return Self.rejectedChangeGoneMessage
            }
            entry = found
        } catch {
            return Self.rejectedChangeUnavailableMessage
        }
        guard let fetcher = serverRecordFetcherIfConfigured(),
              let credentials = currentSyncCredentials(), credentials.subject == subject
        else { return Self.rejectedChangeUnavailableMessage }
        let table = entry.item.table, recordId = entry.item.recordId

        let record: NativeServerRecord
        do {
            record = try await fetcher.fetchServerRecord(
                table: table, recordId: recordId,
                sessionBytes: credentials.sessionBytes, expectedUserSubject: subject
            )
        } catch NativeInitialSyncError.rejectedSession {
            guard await refreshSyncSession(),
                  let fresh = currentSyncCredentials(), fresh.subject == subject,
                  subject == authenticatedUserSubject
            else { return Self.rejectedChangeOfflineMessage }
            do {
                record = try await fetcher.fetchServerRecord(
                    table: table, recordId: recordId,
                    sessionBytes: fresh.sessionBytes, expectedUserSubject: subject
                )
            } catch {
                return Self.rejectedChangeOfflineMessage
            }
        } catch {
            return Self.rejectedChangeOfflineMessage
        }

        // After the await: the same owner, a writable workspace, and the
        // same entry, still not superseded by a queued change.
        guard subject == authenticatedUserSubject, binding == verifiedAccountBinding,
              !persistenceWritesBlocked,
              (try? visibleRejectedChanges())?.first(where: { $0.id == id }) == entry
        else { return Self.rejectedChangeRaceMessage }
        do {
            let next = try fetcher.applyingServerRecord(record, table: table, recordId: recordId, to: snapshot)
            try commitSnapshot(next)
        } catch {
            return Self.rejectedChangeCommitMessage
        }
        // Fix round 2 (G5) rule: a settings row from the server can carry a
        // Square token; heal it locally like after a pull.
        if table == "settings" { scrubLegacySquareToken() }
        do {
            try rejectedChangeStore.remove(key: id, binding: binding)
        } catch {
            refreshRejectedChanges()
            return Self.rejectedChangeClearMessage
        }
        refreshRejectedChanges()
        return nil
    }

    /// Discard's one-record fetch: the injected initial-sync service when it
    /// supports it (tests inject one), otherwise the configured Supabase service.
    private func serverRecordFetcherIfConfigured() -> (any NativeServerRecordFetching)? {
        if let injected = initialSyncService as? any NativeServerRecordFetching { return injected }
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey
        else { return nil }
        return NativeSupabaseInitialSyncService(supabaseURL: supabaseURL, publishableKey: publishableKey)
    }

    /// Removes the rejected-change store at an account boundary that does not
    /// run the full scrub (account switch, password-recovery exits), under
    /// the durable `.rejectedChangesScrub` marker like the AI-key wipe: a
    /// failure leaves it pending, nothing is listed or filed meanwhile, and
    /// the retry runs at launch, on activation, before a sign-in and from
    /// `retryAccountScrub`. Counted and logged without data.
    private func scrubRejectedChangesForAccountBoundary() {
        do {
            try runDurableBoundaryStep(.rejectedChangesScrub) {
                try rejectedChangeStore.removeAll()
            }
        } catch {
            rejectedChangeScrubFailureCount = min(Self.rejectedChangeCounterCap, rejectedChangeScrubFailureCount + 1)
            Self.stageLogger.error("TradeReadyRejectedChanges stage=boundary-scrub")
        }
        if !rejectedChanges.isEmpty { rejectedChanges = [] }
    }

    // MARK: 11.12 Finding D: rebase a pulled delta onto the live snapshot

    /// The keys (`<table>/<recordId>`, the queue's `MutationKey`) of every
    /// change still waiting to reach the server.
    private func pendingMutationKeys() -> Set<String> {
        Set(mutationQueue.load().map { "\($0.table)/\($0.recordId)" })
    }

    struct PulledDeltaRebase {
        var snapshot: Canonical.Snapshot
        /// Collection tables (cursor keys) whose watermark must stay at its
        /// pre-pull value: the commit kept a local record over a server row
        /// this pull fetched, so the next pull must fetch that row again.
        var heldCursorTables: Set<String>
    }

    /// A three-way merge of a pull's delta onto the live snapshot. `base` is
    /// the snapshot the pull merged into, `pulled` its candidate, `live` the
    /// snapshot at commit time. Per record key `<table>/<id>` (the queue's
    /// key; settings `settings/settings`, notes `customer_notes/<key>`), the
    /// pulled (server) state is taken only when this device has not touched
    /// the record: the key is not in `protectedKeys` (pending at the pull's
    /// start or at commit) and its live state still equals the base. Every
    /// other record keeps its live state, including a pending delete and a
    /// local create. Records keep their live order; rows only the pull has
    /// (new remote rows) follow in pulled order. With nothing protected or
    /// changed locally in a table, that table is `pulled` exactly. A record
    /// kept for a key in `unheldKeys` (12.00b.1: still queued at commit, or
    /// refused) never holds its table's watermark.
    static func rebasePulledDelta(
        base: Canonical.Snapshot,
        pulled: Canonical.Snapshot,
        live: Canonical.Snapshot,
        protectedKeys: Set<String>,
        unheldKeys: Set<String> = []
    ) throws -> PulledDeltaRebase {
        var result = pulled
        var held = Set<String>()
        let b = base.payload, p = pulled.payload, l = live.payload
        func rebase<R: Encodable>(_ table: String, _ id: KeyPath<R, String>, _ base: [R]?, _ pulled: [R]?, _ live: [R]?) throws -> [R]?? {
            let merged = try rebaseRecords(
                table: table, id: id, base: base, pulled: pulled, live: live,
                protectedKeys: protectedKeys, unheldKeys: unheldKeys
            )
            if merged.holdsCursor { held.insert(table) }
            return merged.records
        }
        if let v = try rebase("jobs", \Canonical.Job.id, b.jobs, p.jobs, l.jobs) { result.payload.jobs = v }
        if let v = try rebase("invoices", \Canonical.Invoice.id, b.invoices, p.invoices, l.invoices) { result.payload.invoices = v }
        if let v = try rebase("customers", \Canonical.Customer.id, b.customers, p.customers, l.customers) { result.payload.customers = v }
        if let v = try rebase("expenses", \Canonical.Expense.id, b.expenses, p.expenses, l.expenses) { result.payload.expenses = v }
        if let v = try rebase("pricebook", \Canonical.PricebookEntry.id, b.pricebook, p.pricebook, l.pricebook) { result.payload.pricebook = v }
        if let v = try rebase("recurringJobs", \Canonical.RecurringJob.id, b.recurringJobs, p.recurringJobs, l.recurringJobs) { result.payload.recurringJobs = v }
        if let v = try rebase("recurringInvoices", \Canonical.RecurringInvoice.id, b.recurringInvoices, p.recurringInvoices, l.recurringInvoices) { result.payload.recurringInvoices = v }
        if let v = try rebase("trips", \Canonical.Trip.id, b.trips, p.trips, l.trips) { result.payload.trips = v }
        if let v = try rebase("bookingRequests", \Canonical.BookingRequest.id, b.bookingRequests, p.bookingRequests, l.bookingRequests) { result.payload.bookingRequests = v }
        if let v = try rebase("jobPhotos", \Canonical.JobPhoto.id, b.jobPhotos, p.jobPhotos, l.jobPhotos) { result.payload.jobPhotos = v }

        // Settings and customer notes have no cursor: every pass refetches them.
        if try protectedKeys.contains("settings/\(settingsMutationRecordID)") || !sameEncoding(l.settings, b.settings) {
            result.payload.settings = l.settings
        }
        let noteKeys = Set((b.customerNotes ?? [:]).keys).union((p.customerNotes ?? [:]).keys).union((l.customerNotes ?? [:]).keys)
        var notes = p.customerNotes ?? [:]
        var notesChanged = false
        for key in noteKeys {
            let local = l.customerNotes?[key], original = b.customerNotes?[key]
            let takesServer = !protectedKeys.contains("customer_notes/\(key)") && local == original
            if !takesServer, notes[key] != local {
                notes[key] = local
                notesChanged = true
            }
        }
        if notesChanged {
            result.payload.customerNotes = (notes.isEmpty && p.customerNotes == nil) ? l.customerNotes : notes
        }
        return PulledDeltaRebase(snapshot: result, heldCursorTables: held)
    }

    /// One collection's rebase. `records` is nil (outer) when the pulled
    /// collection can be committed unchanged: nothing protected in `table` and
    /// the live collection still equals the base.
    private static func rebaseRecords<R: Encodable>(
        table: String,
        id: KeyPath<R, String>,
        base: [R]?,
        pulled: [R]?,
        live: [R]?,
        protectedKeys: Set<String>,
        unheldKeys: Set<String> = []
    ) throws -> (records: [R]??, holdsCursor: Bool) {
        let prefix = "\(table)/"
        if !protectedKeys.contains(where: { $0.hasPrefix(prefix) }), try sameEncoding(live, base) {
            return (nil, false)
        }
        func index(_ records: [R]?) -> [String: R] {
            Dictionary((records ?? []).map { ($0[keyPath: id], $0) }, uniquingKeysWith: { first, _ in first })
        }
        let baseByID = index(base), liveByID = index(live), pulledByID = index(pulled)
        // The server's version wins only for a record this device has not touched.
        func takesServer(_ key: String) throws -> Bool {
            try !protectedKeys.contains(prefix + key) && sameEncoding(liveByID[key], baseByID[key])
        }
        // A kept local record over a server row this pull fetched: hold the cursor.
        var holdsCursor = false
        func keptOverServer(_ key: String) throws {
            guard !unheldKeys.contains(prefix + key) else { return }
            if try !sameEncoding(pulledByID[key], baseByID[key]), try !sameEncoding(pulledByID[key], liveByID[key]) {
                holdsCursor = true
            }
        }
        var records: [R] = []
        var seen = Set<String>()
        for record in live ?? [] {
            let key = record[keyPath: id]
            guard seen.insert(key).inserted else { continue }
            if try takesServer(key) {
                if let server = pulledByID[key] { records.append(server) } // absent: a server tombstone
            } else {
                records.append(record)
                try keptOverServer(key)
            }
        }
        for record in pulled ?? [] {
            let key = record[keyPath: id]
            guard seen.insert(key).inserted else { continue }
            if try takesServer(key) {
                records.append(record)
            } else {
                try keptOverServer(key) // deleted on this device (pending or pushed)
            }
        }
        if pulled == nil, live == nil { return (.some(nil), holdsCursor) }
        return (.some(records), holdsCursor)
    }

    private static func sameEncoding<T: Encodable>(_ a: T?, _ b: T?) throws -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return try rebaseEncoder.encode(a) == rebaseEncoder.encode(b)
        default: return false
        }
    }

    private static let rebaseEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    // MARK: Task 11.12 signpost metadata (counts and outcome words only)

    /// The number of canonical records in memory: the only size a signpost
    /// carries (no ids, names or values).
    private func performanceRecordCount() -> Int {
        let payload = snapshot.payload
        return (payload.jobs?.count ?? 0)
            + (payload.invoices?.count ?? 0)
            + (payload.customers?.count ?? 0)
            + (payload.expenses?.count ?? 0)
            + (payload.recurringJobs?.count ?? 0)
            + (payload.recurringInvoices?.count ?? 0)
            + (payload.trips?.count ?? 0)
            + (payload.pricebook?.count ?? 0)
            + (payload.bookingRequests?.count ?? 0)
            + (payload.jobPhotos?.count ?? 0)
    }

    private static func performanceOutcome(_ result: NativeSyncPullResult) -> NativePerformanceOutcome {
        switch result.state {
        case .completed: .completed
        case .partial: .partial
        case .failed: .failed
        case .skipped: .skipped
        }
    }

    private static func performanceOutcome(_ outcome: NativeBackgroundRefreshOutcome) -> NativePerformanceOutcome {
        switch outcome {
        case .completed: .completed
        case .skipped: .skipped
        case .failed: .failed
        }
    }

    private func configuredJobPhotoTransferService() -> (any NativeJobPhotoTransferring)? {
        if let injectedJobPhotoTransferService { return injectedJobPhotoTransferService }
        guard let endpoint = try? BuildEnvironment.endpoint("api/photos", sendsUserData: true)
        else { return nil }
        return NativeJobPhotoTransferService(endpointBaseURL: endpoint)
    }

    private func configuredEstimateApprovalLinkService() -> (any NativeEstimateApprovalLinking)? {
        if let injectedEstimateApprovalLinkService { return injectedEstimateApprovalLinkService }
        guard let endpoint = try? BuildEnvironment.endpoint(
            "api/estimate/create-link",
            sendsUserData: true
        ) else { return nil }
        return NativeEstimateApprovalLinkService(endpoint: endpoint)
    }

    private func configuredChangeOrderApprovalLinkService() -> (any NativeChangeOrderApprovalLinking)? {
        if let injectedChangeOrderApprovalLinkService { return injectedChangeOrderApprovalLinkService }
        guard let endpoint = try? BuildEnvironment.endpoint(
            "api/estimate/create-link",
            sendsUserData: true
        ) else { return nil }
        return NativeChangeOrderApprovalLinkService(endpoint: endpoint)
    }

    /// Records that the initial sync finished for `subject` and, exactly once per
    /// account, enqueues every local record that entered the snapshot via legacy
    /// migration or sample-seeding rather than a user edit — the records the
    /// per-write enqueue hooks never saw — then kicks a push. Backfill failure
    /// never blocks sign-in: the flag is stamped only on success, so the next
    /// completion retries, and the enqueue is idempotent if it partially ran.
    private func markInitialSyncCompleted(subject: String) {
        initialSyncCompletedSubject = subject
        do {
            try syncBackfill.backfillIfNeeded(
                subject: subject,
                snapshot: snapshot,
                queue: mutationQueue
            )
        } catch {
            print("TradeReadyMutationQueue stage=backfill")
            recordLocalSyncFailure("queue/backfill")
        }
        Task { [weak self] in
            guard let self else { return }
            guard await self.syncNowAndWait(trigger: .signedIn) != nil else { return }
            let photos = await self.performJobPhotoTransfer()
            if photos.uploadedCount > 0 {
                _ = await self.syncNowAndWait(trigger: .localChange)
            }
        }
    }

    /// The verified subject and Keychain session for a push, or nil when the
    /// device is not authenticated. Ownership is re-verified per item on the
    /// wire; this only gates whether a pass runs at all.
    private func currentSyncCredentials() -> NativeSyncCredentials? {
        if let scheduleBookingTestCredentials { return scheduleBookingTestCredentials }
        guard let subject = authenticatedUserSubject,
              let sessionBytes = try? secureSettingsStore.readSupabaseSession()
        else { return nil }
        return NativeSyncCredentials(subject: subject, sessionBytes: sessionBytes)
    }

    /// Refreshes the Supabase session through the same server-verified activator
    /// the rest of the app uses. Returns whether a usable session is now present.
    private func refreshSyncSession() async -> Bool {
        guard let configured = try? configuredAuthentication() else { return false }
        // Phase 12 (12.00b.2-G fix round 1, R31): see `completeIdentityActivation`
        // (here only the Keychain cache the activator wrote is at stake).
        let boundaryGeneration = accountBoundaryGeneration
        let refreshed = (try? await configured.activator.activate()) != nil
        guard accountBoundaryGeneration == boundaryGeneration else {
            discardIdentityActivationOvertakenByAccountBoundary()
            return false
        }
        return refreshed
    }

    private func recordLocalSyncFailure(_ code: String) {
        if let coordinator = syncCoordinatorIfConfigured() {
            coordinator.recordLocalFailure(code)
        } else {
            syncStatus = NativeSyncStatus(
                pendingCount: mutationQueue.load().count,
                diagnosticCode: code
            )
        }
    }

    private static func pullDiagnosticCode(for error: Error) -> String {
        if let code = NativeSupabaseInitialSyncService.lastDiagnosticCode { return code }
        switch error {
        case NativeInitialSyncError.invalidConfiguration: return "pull/configuration"
        case NativeInitialSyncError.malformedSession: return "pull/session"
        case NativeInitialSyncError.rejectedSession: return "pull/authentication"
        case NativeInitialSyncError.invalidResponse: return "pull/contract"
        default: return "pull/unavailable"
        }
    }

    /// Phase 12 (12.02, charter TH-1/TH-2): `operation` is "launch" or
    /// "retry" (the blocked screen's Try again). A failed migration reports
    /// `legacy-migration/failed/<domain>/<code>` and a completed journal with
    /// no snapshot reports `legacy-migration/missing-migrated-snapshot`, each
    /// under `legacyMigration`. The P12-003 signed-out steady state never
    /// reaches here with an outcome, so it stays silent. Every outcome is also
    /// kept for the support report (`legacyMigrationSummary`), counts only.
    private func applyLaunchMigrationState(
        outcome: LegacyMigrationOutcome?,
        error: Error?,
        hadNativeSnapshot: Bool,
        operation: String
    ) {
        if let error {
            let failureCode = NativeSupportDiagnostics.errorCode(error)
            legacyMigrationSummary = NativeLegacyMigrationSummary(
                outcome: "failed", operation: operation, failureCode: failureCode
            )
            reportLegacyMigrationFailure(code: "legacy-migration/failed/\(failureCode)", operation: operation)
            migrationMessage = "We couldn't finish moving your previous-app data. The source data is still safe."
            if !hadNativeSnapshot {
                persistenceWritesBlocked = true
                persistenceBlockReason = .legacyMigration
                persistenceBlockDetail = nil
                isLegacyMigrationBlocked = true
                launchMigrationNotice = .failed
            }
            return
        }
        guard let outcome else { return }
        var summary = NativeLegacyMigrationSummary(
            outcome: "no-data", operation: operation,
            importedCount: NativeSupportDiagnostics.boundedCount(outcome.importedCount),
            missingPhotoCount: NativeSupportDiagnostics.boundedCount(outcome.missingPhotoCount),
            adoptedPhotoCount: NativeSupportDiagnostics.boundedCount(outcome.adoptedPhotoCount),
            deferredPhotoCount: NativeSupportDiagnostics.boundedCount(outcome.deferredPhotoCount)
        )
        switch outcome.status {
        case .migrated:
            summary.outcome = "migrated"
            isLegacyMigrationBlocked = false
            launchMigrationNotice = .migrated(
                count: outcome.importedCount,
                adoptedPhotos: outcome.adoptedPhotoCount,
                deferredPhotos: outcome.deferredPhotoCount
            )
        case .nativeSnapshotConflict:
            summary.outcome = "conflict"
            launchMigrationNotice = .conflict
            migrationMessage = "Previous-app data was found, but this app already has data. Nothing was changed."
        case .alreadyCompleted:
            summary.outcome = "already-completed"
            if !hadNativeSnapshot {
                summary.outcome = "missing-migrated-snapshot"
                reportLegacyMigrationFailure(code: "legacy-migration/missing-migrated-snapshot", operation: operation)
                persistenceWritesBlocked = true
                persistenceBlockReason = .missingMigratedSnapshot
                persistenceBlockDetail = nil
                isLegacyMigrationBlocked = true
                launchMigrationNotice = .failed
                migrationMessage = "The previous-app migration is marked complete, but its native snapshot is unavailable."
            }
        case .nativeStateAdopted:
            // Phase 12 (12.06, P12-011): nothing was imported and nothing is
            // missing. Silent, like the P12-003 signed-out steady state.
            summary.outcome = "native-state-adopted"
            isLegacyMigrationBlocked = false
            launchMigrationNotice = nil
        case .noData:
            break
        }
        legacyMigrationSummary = summary
    }

    /// Phase 12 (12.02): TH-1/TH-2's remote signal. A bounded code only:
    /// never the error's message, path or user info.
    private func reportLegacyMigrationFailure(code: String, operation: String) {
        reportError(
            ["code": code, "message": "Previous-app data migration did not finish"],
            context: ["context": "legacyMigration", "operation": operation]
        )
    }

    /// Phase 7 atomic payment commit. The invoice mutation and the resulting
    /// linked-job transitions land in ONE canonical snapshot save (plus one
    /// batched queue publication), so a crash cannot leave an invoice saved
    /// with its job unadvanced. The invoice is merged through the same
    /// edit-boundary as `commitInvoiceEdit`, preserving delivery metadata,
    /// linkage and unknown fields. Job advancement only moves invoiced→paid
    /// on full settlement and never regresses (void-safe).
    @discardableResult
    func commitInvoicePayment(_ invoice: Invoice) -> Result<Invoice, NativeInvoiceEditRefusal> {
        guard ensurePersistenceWritable() else { return .failure(.persistenceUnavailable) }
        var invoiceRecords = snapshot.payload.invoices ?? []
        guard let baseline = invoiceRecords.first(where: { $0.id == invoice.id }) else {
            return .failure(.missingRecord)
        }
        do {
            var edit = try CanonicalUIAdapters.edit(baseline)
            edit.value = invoice
            var result = try CanonicalUIAdapters.canonical(from: edit)
            Self.reconcileInvoicePaidFields(&result)
            replaceOrAppend(result, in: &invoiceRecords, id: \Canonical.Invoice.id)
            guard let published = try? CanonicalUIAdapters.invoice(from: result) else {
                reportInvoicePaymentFailure(code: "invoice-payment/projection", operation: "commit")
                return .failure(.persistenceUnavailable)
            }
            // P12-008: built on a copy and committed through `commitSnapshot`,
            // so a save that throws leaves the live snapshot, the screens and
            // the widget mirror exactly as they were: nothing unsaved for the
            // next unrelated save to persist without queueing it.
            var next = snapshot
            next.payload.invoices = invoiceRecords
            var jobRecords = next.payload.jobs ?? []
            var advancedJobIDs: [String] = []
            let currentJobs = jobs.map(\.lifecycleJob)
            let advanced = JobLifecycleRules.advancePaidInvoiceJobs(
                currentJobs,
                invoices: [published.workflowLedger]
            )
            for (before, after) in zip(currentJobs, advanced) where before.status != after.status {
                guard let index = jobRecords.firstIndex(where: { $0.id == after.id }),
                      var job = try? CanonicalUIAdapters.job(from: jobRecords[index])
                else { continue }
                job.status = JobStatus(lifecycleStatus: after.status)
                var jobEdit = try CanonicalUIAdapters.edit(jobRecords[index])
                jobEdit.value = job
                jobRecords[index] = try CanonicalUIAdapters.canonical(from: jobEdit)
                advancedJobIDs.append(after.id)
            }
            next.payload.jobs = jobRecords
            try commitSnapshot(next)
            enqueueUpsert(table: "invoices", recordId: result.id, record: result)
            for jobID in advancedJobIDs {
                guard let record = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { continue }
                enqueueUpsert(table: "jobs", recordId: jobID, record: record)
            }
            return .success(published)
        } catch {
            migrationMessage = "Could not record the payment: \(error.localizedDescription)"
            reportInvoicePaymentFailure(
                code: "invoice-payment/commit/\(NativeSupportDiagnostics.errorCode(error))", operation: "commit"
            )
            return .failure(.persistenceUnavailable)
        }
    }

    /// Phase 12 (12.02, charter TH-9): a payment the owner entered that could
    /// not be saved. The operation, the error's domain and code, and (bulk)
    /// how many invoices it was settling: never an invoice, id or amount.
    private func reportInvoicePaymentFailure(code: String, operation: String, count: Int? = nil) {
        var context: [String: Any] = ["context": "invoicePayment", "operation": operation]
        if let count { context["count"] = count }
        reportError(["code": code, "message": "Payment could not be saved"], context: context)
    }

    /// The same "link decision beats on-site decision, cancellation beats
    /// both" mirror `jobListItems` already builds for the job list's billable
    /// total — reused here so `JobInvoiceDomain` never touches `Canonical.
    /// ChangeOrder` directly.
    private func changeOrderMirrors(_ job: Canonical.Job) -> [NativeJobListChangeOrder] {
        (job.changeOrders ?? []).map {
            NativeJobListChangeOrder(
                amount: $0.amount,
                approvalDecision: $0.approval?.decision,
                manualDecision: $0.manualDecision?.decision,
                isCancelled: !($0.cancelledAt ?? "").isEmpty
            )
        }
    }

    private func billableBreakdown(for job: Canonical.Job) -> JobInvoiceBillableBreakdown {
        let materials = job.materials.map { (quantity: $0.quantity, unitCost: $0.unitCost) }
        let directCosts = (job.jobCosts ?? []).map { cost in
            JobInvoiceDirectCost(
                label: CanonicalUIAdapters.estimateDirectCostLabel(cost),
                category: cost.category, quantity: cost.quantity, unitCost: cost.unitCost,
                markupPercent: cost.markupPercent, markupPolicy: cost.markupPolicy,
                customerVisible: cost.customerVisible
            )
        }
        let sessions = (job.timeSessions ?? []).map { JobInvoiceTimeSession(start: $0.start, end: $0.end) }
        return JobInvoiceDomain.computeBillableBreakdown(
            estimateTotal: job.estimateTotal, laborHours: job.laborHours, laborRate: job.laborRate,
            materials: materials, materialMarkup: job.materialMarkup, directCosts: directCosts,
            status: job.status, timeSessions: sessions, changeOrders: changeOrderMirrors(job)
        )
    }

    /// A job's invoice line items, recomputed fresh from its current
    /// canonical record — see `commitInvoiceFromJob`.
    private func invoiceLineDrafts(for job: Canonical.Job) -> [JobInvoiceLineDraft] {
        let approvedChangeOrders = JobInvoiceDomain.approvedChangeOrders(
            (job.changeOrders ?? []).map { order in
                (title: order.title, order: NativeJobListChangeOrder(
                    amount: order.amount, approvalDecision: order.approval?.decision,
                    manualDecision: order.manualDecision?.decision,
                    isCancelled: !(order.cancelledAt ?? "").isEmpty
                ))
            }
        )
        let singleMaterialName = job.materials.count == 1 ? job.materials[0].name : nil
        return JobInvoiceDomain.buildInvoiceLineItems(
            breakdown: billableBreakdown(for: job), laborRate: job.laborRate,
            materialCount: job.materials.count, singleMaterialName: singleMaterialName,
            approvedChangeOrders: approvedChangeOrders
        )
    }

    private func replaceOrAppend<T>(_ value: T, in values: inout [T], id: KeyPath<T, String>) {
        if let index = values.firstIndex(where: { $0[keyPath: id] == value[keyPath: id] }) { values[index] = value }
        else { values.append(value) }
    }

    /// Returns whether the demo data was saved.
    @discardableResult
    private func seedDemoData() -> Bool {
        do {
            let calendar = Calendar.current
            let tom = Customer(name: "Tom Nguyen", email: "tom.nguyen@gmail.com", phone: "(555) 874-9900", address: "88 Oak Lane, Austin TX 78745", notes: "Dog in backyard — keep gate closed.")
            let bakery = Customer(name: "Riverside Bakery", email: "owner@riversidebakery.com", phone: "(555) 301-2200", address: "142 Mill St, Austin TX 78701", notes: "Side entrance is easiest. Ask for Maria.")
            let dental = Customer(name: "Patel Family Dental", email: "admin@pateldental.com", phone: "(555) 440-1133", address: "310 Congress Ave, Austin TX 78701", notes: "Call ahead — visitor badge required.")
            let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now)
            let demoJobs = [
                Job(customerId: tom.id, customerName: tom.name, title: "Replace kitchen faucet", description: "Install owner-selected faucet and dispose of old unit.", status: .scheduled, scheduledAt: nine, scheduledEnd: nine.flatMap { calendar.date(byAdding: .hour, value: 2, to: $0) }, address: tom.address, estimateTotal: 285, laborHours: 2),
                Job(customerId: bakery.id, customerName: bakery.name, title: "Fix leaking drain pipe", description: "Replace the elbow below the three-compartment sink.", status: .estimateSent, address: bakery.address, estimateTotal: 340, laborHours: 2.5, notes: "After business hours preferred."),
                Job(customerId: dental.id, customerName: dental.name, title: "Water heater replacement", description: "Inspect and quote a 50-gallon gas replacement.", address: dental.address)
            ]
            let demoInvoices = [
                Invoice(customerId: bakery.id, customer: bakery.name, number: "INV-0038", amount: 2400, due: calendar.date(byAdding: .day, value: -8, to: .now) ?? .now, email: bakery.email, phone: bakery.phone, description: "Emergency pipe repair"),
                Invoice(customerId: tom.id, customer: tom.name, number: "INV-0039", amount: 650, due: calendar.date(byAdding: .day, value: 14, to: .now) ?? .now, email: tom.email, phone: tom.phone, description: "Fixture installation", payments: [Payment(amount: 250, method: "Card")]),
                Invoice(customerId: dental.id, customer: dental.name, number: "INV-0037", amount: 875, due: .now, email: dental.email, phone: dental.phone, description: "Service call", payments: [Payment(amount: 875, method: "ACH")])
            ]
            let demoSettings = BusinessSettings(businessName: "Rector Plumbing", contactName: "Chad", phone: "(555) 555-0134", email: "hello@example.com", address: "Austin, TX")
            let payload = Canonical.SnapshotPayload(
                invoices: try demoInvoices.map { try CanonicalUIAdapters.canonical(from: $0) },
                jobs: try demoJobs.map { try CanonicalUIAdapters.canonical(from: $0) },
                customers: try [tom, bakery, dental].map { try CanonicalUIAdapters.canonical(from: $0) },
                settings: try CanonicalUIAdapters.canonical(from: demoSettings),
                expenses: try [Expense(merchant: "Ferguson", amount: 126.42, date: .now, category: .materials, notes: "Faucet supplies")].map { try CanonicalUIAdapters.canonical(from: $0) })
            // P12-008: a failed save keeps the data the owner already had.
            try commitSnapshot(Canonical.Snapshot(payload: payload))
            return true
        } catch {
            migrationMessage = "Could not create demo data: \(error.localizedDescription)"
            return false
        }
    }

    /// Returns only error kind and whitelisted schema keys. Dynamic dictionary
    /// keys, record identifiers, values, and debug descriptions are discarded.
    private static func snapshotFailureCode(_ error: Error) -> String {
        if let projectionError = error as? SnapshotProjectionError {
            if let adapterError = projectionError.underlying as? CanonicalUIAdapterError {
                switch adapterError {
                case let .invalidDate(field, _):
                    let safeField = safeAdapterDiagnosticFields.contains(field) ? field : "field"
                    return "projection-\(projectionError.family)-invalid-date-\(safeField)"
                case .invalidCanonicalRecord:
                    return "projection-\(projectionError.family)-invalid-record"
                }
            }
            return "projection-\(projectionError.family)-\(snapshotFailureCode(projectionError.underlying))"
        }
        if let repositoryError = error as? Canonical.SnapshotRepository.RepositoryError {
            switch repositoryError {
            case let .corruptPrimaryNoUsableBackup(primary, backup):
                let primaryCode = snapshotFailureCode(primary)
                guard let backup else { return "primary-\(primaryCode)-no-backup" }
                return "primary-\(primaryCode)-backup-\(snapshotFailureCode(backup))"
            }
        }
        if let snapshotError = error as? Canonical.SnapshotError {
            switch snapshotError {
            case .missingSchemaVersion: return "missing-schema-version"
            case .nullPayload: return "null-payload"
            }
        }
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return decodingCode(
                kind: "key-not-found",
                path: context.codingPath + [key]
            )
        case let DecodingError.valueNotFound(_, context):
            return decodingCode(kind: "value-not-found", path: context.codingPath)
        case let DecodingError.typeMismatch(_, context):
            return decodingCode(kind: "type-mismatch", path: context.codingPath)
        case let DecodingError.dataCorrupted(context):
            return decodingCode(kind: "data-corrupted", path: context.codingPath)
        default:
            return (error as NSError).domain == NSCocoaErrorDomain ? "io-error" : "other"
        }
    }

    private static func decodingCode(kind: String, path: [any CodingKey]) -> String {
        let safePath = path.prefix(8).map { key -> String in
            if key.intValue != nil { return "item" }
            return safeSnapshotDiagnosticKeys.contains(key.stringValue)
                ? key.stringValue
                : "field"
        }
        return ([kind] + safePath).joined(separator: "-")
    }

    private static let safeSnapshotDiagnosticKeys: Set<String> = [
        "payload", "schemaVersion", "legacySnapshot",
        "invoices", "jobs", "customers", "settings", "expenses",
        "customerNotes", "recurringJobs", "recurringInvoices", "trips",
        "pricebook", "bookingRequests", "jobPhotos",
        "id", "name", "email", "phone", "address", "notes", "createdAt",
        "customerId", "customerName", "customer", "title", "description",
        "status", "scheduledAt", "scheduledEnd", "estimateTotal", "laborHours",
        "laborRate", "invoiceId", "number", "amount", "due", "payments",
        "date", "method", "note", "voidedAt", "merchant", "category",
        "businessName", "contactName", "region", "trade", "paymentNotes",
        "materialMarkup", "overheadPercent", "marginPercent", "minimumJobFee",
        "emergencyMultiplier", "mileageRate", "ownerLaborCostRate", "workDayStart",
        "workDayEnd", "workDays", "appointmentMinutes", "bufferMinutes",
        "invoicePrefix", "invoiceStart", "autoOutreachEnabled", "autoSendEmailEnabled",
        "appointmentRemindersEnabled", "appointmentConfirmTemplate", "onMyWayTemplate",
        "estimateFollowUpsEnabled", "autoInvoiceOnComplete", "bookingEnabled",
        "bookableSlotsEnabled", "reviewRequestEnabled", "googleReviewLink",
        "reviewRequestDelayHours", "reviewRequestTemplate", "appearance"
    ]

    private static let safeAdapterDiagnosticFields: Set<String> = [
        "customer.createdAt", "job.scheduledStart", "job.scheduledEnd", "job.createdAt",
        "payment.date", "payment.voidedAt", "invoice.paidAt", "invoice.due", "expense.date"
    ]

    private static let legacyDecoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()

    private static func canonicalSnapshot(from legacy: LegacyNativeStoreSnapshot) throws -> Canonical.Snapshot {
        Canonical.Snapshot(payload: .init(
            invoices: try legacy.invoices.map { try CanonicalUIAdapters.canonical(from: $0) },
            jobs: try legacy.jobs.map { try CanonicalUIAdapters.canonical(from: $0) },
            customers: try legacy.customers.map { try CanonicalUIAdapters.canonical(from: $0) },
            settings: try CanonicalUIAdapters.canonical(from: legacy.settings),
            expenses: try legacy.expenses.map { try CanonicalUIAdapters.canonical(from: $0) }
        ))
    }
}

// MARK: - Phase 8 schedule/booking/portal integration (task 8.08)

/// Typed outcomes for the task 8.08 canonical integration entry points.
/// Every case is explicit: no placeholder action counts as done, and a
/// refused/stale action always names the recovery (refresh, review,
/// explicit retry, or the rotation recovery path).
extension AppStore {

    enum ScheduleOnlyOutcome: Equatable {
        case saved(conflictingJobIDs: [String])
        case baselineConflict
        case missing
        case failed
    }

    enum ScheduleSettingsOutcome: Equatable {
        case saved
        case baselineConflict
        case failed
    }

    enum BookingIntakeOutcome: Equatable {
        case applied(convertedRequestIDs: [String])
        case noChange
        case alreadyRunning
        case skipped(reason: String)
    }

    enum BookingHandledOutcome: Equatable {
        case handled
        case alreadyHandled
        case missing
        case failed
    }

    enum OwnerResponseOutcome: Equatable {
        /// `savedLocally` is false when the server declined but this device
        /// could not save the status (fix round 1, review Minor 2).
        case applied(status: String, alreadyApplied: Bool, savedLocally: Bool = true)
        /// Phase 12 (12.00b.2-L, P12-017): a change to the request has not
        /// reached the server. Nothing was sent.
        case awaitingAck(OwnerResponseWait)
        case needsReview(currentStatus: String)
        case unknownOutcome
        case missing
        case failed(reason: String)
    }

    enum ReschedulePrepareOutcome: Equatable {
        case proofReady(proof: NativeScheduleProof)
        case awaitingAck
        case scheduleConflict
        case superseded
        case missing
        case failed
    }

    enum RescheduleResolveOutcome: Equatable {
        case resolved(status: String, alreadyApplied: Bool)
        /// Phase 12 (12.00b.2-L, P12-017): as `OwnerResponseOutcome.awaitingAck`.
        case awaitingAck(OwnerResponseWait)
        case needsReview(currentStatus: String)
        case superseded
        case unknownOutcome
        case missing
        case failed(reason: String)
    }

    enum BookingLinkAdminOutcome: Equatable {
        case applied(revision: Int, sharesURL: Bool)
        case stale(currentEnabled: Bool)
        case alreadyExists
        case recoveryStaged
        case unknownOutcome
        case failed(reason: String)
    }

    enum PortalLinkAdminOutcome: Equatable {
        case applied
        case alreadyExists(adoptedCurrent: Bool)
        case needsExplicitRotate
        case recoveryStaged
        case unknownOutcome
        case missingCustomer
        case alreadyRunning
        case failed(reason: String)
    }

    struct PendingWorkRecovery: Equatable {
        var reappliedMirrors: Int = 0
        /// Phase 12 (12.00b.2-I): mirrors removed without a write, because a
        /// fresh `status` read says the server no longer backs them (a later
        /// change replaced the staged token, or the server does not know the
        /// customer) or because there is nothing to merge them into.
        var droppedMirrors: Int = 0
        /// P12-028: staged record batches finished (queued, or found already
        /// queued, superseded or gone).
        var replayedBatches: Int = 0
        var proofsReady: [String] = []
        var proofsSuperseded: [String] = []
        /// Phase 12 (12.00b.2-I): proofs whose request no longer asks for a
        /// reschedule (resolved, declined, cancelled or gone). The server
        /// resolves only from `reschedule_requested`, so none can succeed.
        var proofsClosed: [String] = []
        var retained: Int = 0
        /// Phase 12 (12.00b.2-I): the pass stopped at an account boundary or
        /// owner change; what it had not finished waits for the owner's next
        /// pass.
        var stoppedForAccountChange = false
    }

    // MARK: State and seams

    func pendingScheduleBookingWorkStore() -> NativeScheduleBookingPendingWorkStore {
        NativeScheduleBookingPendingWorkStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("schedule-booking-pending-work.json")
        )
    }

    private func scheduleBookingOwnerCapture() -> (subject: String?, binding: String?) {
        (authenticatedUserSubject, verifiedAccountBinding)
    }

    private func scheduleBookingOwnerStillCurrent(_ capture: (subject: String?, binding: String?)) -> Bool {
        guard let subject = capture.subject, let binding = capture.binding,
              !subject.isEmpty, !binding.isEmpty
        else { return false }
        return subject == authenticatedUserSubject
            && binding == verifiedAccountBinding
            && hasExactSignedInWorkspace
            && !persistenceWritesBlocked
    }

    private func scheduleBookingSessionBytes(explicit: Data?) -> Data? {
        if let explicit { return explicit }
        if let scheduleBookingSessionOverride { return scheduleBookingSessionOverride }
        return try? secureSettingsStore.readSupabaseSession()
    }

    /// Returns the current Supabase session bytes for schedule/booking/portal transports.
    /// Used by tests and views that need to call owner transports directly.
    func scheduleBookingSessionBytes() async throws -> Data {
        if let scheduleBookingSessionOverride { return scheduleBookingSessionOverride }
        if let bytes = try? secureSettingsStore.readSupabaseSession() { return bytes }
        throw NativeBookingAdminError.malformedSession
    }

    private func scheduleBookingRefreshedSession(excluding used: Data) async -> Data? {
        guard await refreshSyncSession(),
              let fresh = try? secureSettingsStore.readSupabaseSession(),
              fresh != used
        else { return nil }
        return fresh
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// P12-028 (fix plan F10): the exact batch is staged in the pending-work
    /// store BEFORE the snapshot is saved (`commitLocalStaged`), so a queue
    /// failure or the app ending between the save and the queue write leaves a
    /// durable record that a launch or activation pass replays. A batch that
    /// cannot be staged is not committed at all.
    private func commitScheduleBookingLocal(
        drafts: [Canonical.MutationDraft],
        saveSnapshot: () throws -> Void,
        queueStage: String
    ) -> Bool {
        guard let binding = verifiedAccountBinding, !binding.isEmpty else { return false }
        let store = pendingScheduleBookingWorkStore()
        let item = NativeScheduleBookingPendingWork(
            kind: .stagedBatch(drafts: drafts.map(NativeScheduleBookingStagedDraft.init), stage: queueStage),
            ownerBinding: binding
        )
        let outcome = NativeScheduleBookingPolicy.commitLocalStaged(
            stageBatch: { try store.stage(item) },
            saveSnapshot: saveSnapshot,
            publishToQueue: { try self.mutationQueue.enqueueBatch(drafts) },
            clearStage: { try? store.remove { $0 == item } }
        )
        switch outcome {
        case .committed:
            scheduleSyncAfterLocalChange()
            return true
        case .stageFailed, .snapshotFailed:
            return false
        case .queueFailedStaged:
            // The snapshot is durable and the batch is staged: the next
            // launch or activation pass queues it.
            print("TradeReadyMutationQueue stage=\(queueStage)")
            recordLocalSyncFailure("queue/\(queueStage)")
            scheduleSyncAfterLocalChange()
            return true
        }
    }

    // MARK: Schedule-only commit (S3)

    /// Typed schedule-only commit: re-resolves the CURRENT job, merges only
    /// schedule fields (plus the single automatic `approved → scheduled`
    /// transition), and preserves every unrelated field. The editor only
    /// dismisses on `.saved`; `.baselineConflict` keeps the draft.
    @discardableResult
    func commitScheduleOnly(
        _ draft: NativeScheduleBookingPolicy.ScheduleOnlyDraft
    ) -> ScheduleOnlyOutcome {
        guard ensurePersistenceWritable() else { return .failed }
        guard let current = snapshot.payload.jobs?.first(where: { $0.id == draft.jobID }) else {
            migrationMessage = "This job could not be found. Nothing was saved."
            return .missing
        }
        switch NativeScheduleBookingPolicy.applyScheduleOnly(
            current: current,
            jobs: snapshot.payload.jobs ?? [],
            draft: draft
        ) {
        case let .apply(job, conflictingJobIDs):
            var updated = snapshot
            var records = updated.payload.jobs ?? []
            guard let index = records.firstIndex(where: { $0.id == job.id }) else { return .missing }
            records[index] = job
            updated.payload.jobs = records
            do {
                try repository.save(updated)
                try apply(updated)
            } catch {
                migrationMessage = "Could not save this schedule: \(error.localizedDescription)"
                return .failed
            }
            enqueueUpsert(table: "jobs", recordId: job.id, record: job)
            return .saved(conflictingJobIDs: conflictingJobIDs)
        case .baselineConflict:
            migrationMessage = "The job changed while this schedule was open. Review the latest schedule before saving."
            return .baselineConflict
        case .missing:
            migrationMessage = "This job could not be found. Nothing was saved."
            return .missing
        }
    }

    // MARK: - Phase 8 task 8.09 read-only calendar projection (S2)

    /// Canonical schedule rows for the calendar UI lane. Views must read
    /// these — never the lossy `Job.scheduledAt` projection, which cannot
    /// distinguish an untimed dated job from a midnight appointment and
    /// rounds working hours to whole integers.
    func calendarScheduleJobs() -> [Canonical.Job] {
        snapshot.payload.jobs ?? []
    }

    func calendarJob(id: String) -> Canonical.Job? {
        snapshot.payload.jobs?.first(where: { $0.id == id })
    }

    /// Resolved owner schedule (ISO days, minute-precise hours, blackouts)
    /// for axis, nonworking-day and time-off rendering.
    func calendarResolvedSchedule() -> NativeSchedule.ResolvedSchedule {
        NativeSchedule.resolveSchedule(snapshot.payload.settings?.schedule)
    }

    /// Builds a schedule-only draft pinned to the CURRENT canonical record,
    /// or nil when the record is gone (the editor shows its missing state).
    func scheduleOnlyDraft(jobID: String) -> NativeScheduleBookingPolicy.ScheduleOnlyDraft? {
        guard let job = calendarJob(id: jobID) else { return nil }
        return NativeScheduleBookingPolicy.ScheduleOnlyDraft(
            jobID: job.id,
            baselineDate: job.scheduledDate,
            baselineStart: job.scheduledStartTime,
            baselineEnd: job.scheduledEndTime,
            baselineStatus: job.status,
            date: job.scheduledDate,
            start: job.scheduledStartTime,
            end: job.scheduledEndTime
        )
    }

    /// Today's date string in YYYY-MM-DD format for route filtering.
    var todayDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Current owner binding for preview staleness checking.
    var ownerID: String? {
        exactSignedInWorkspaceNotificationBinding
    }

    /// Local display copy of the portal link for a customer.
    /// This is display data, never authority: share/adopt only after a fresh
    /// `status` read proves the token current.
    func portalLinkLocalDisplay(customerID: String) -> (token: String?, enabled: Bool?) {
        let customer = snapshot.payload.customers?.first(where: { $0.id == customerID })
        return (customer?.portal?.token, customer?.portal?.enabled)
    }

    // MARK: Phase 8 task 8.10 read-only settings seams (S4, B2)

    /// Raw canonical schedule block the settings draft pins as its baseline.
    /// Nil means "no schedule block yet" (first save writes only owned
    /// fields). Read-only: the settings view copies this into its draft and
    /// never mutates the snapshot through it.
    func scheduleSettingsBaseline() -> Canonical.ScheduleConfig? {
        snapshot.payload.settings?.schedule
    }

    /// Local display copy of the booking link. This is display data, never
    /// authority: share/adopt only after a fresh `status` read proves the
    /// token current (`reconcileBookingLinkForSharing`). A settings save
    /// preserves this copy by construction (8.08 field-scoped merge).
    func bookingLinkLocalDisplay() -> (token: String?, enabled: Bool) {
        let link = snapshot.payload.settings?.bookingLink
        return (link?.token, link?.enabled ?? false)
    }

    // MARK: Schedule-settings commit (S4)

    /// Typed schedule-settings commit: merges ONLY owned schedule fields
    /// into the latest settings. Booking credentials and unknown fields
    /// survive by construction; enabling slots keeps the existing valid zone
    /// policy owned by the caller (the draft carries the resolved zone).
    @discardableResult
    func commitScheduleSettings(
        _ draft: NativeScheduleBookingPolicy.ScheduleSettingsDraft
    ) -> ScheduleSettingsOutcome {
        guard ensurePersistenceWritable() else { return .failed }
        let current: Canonical.Settings
        do {
            current = try snapshot.payload.settings
                ?? CanonicalUIAdapters.canonical(from: BusinessSettings())
        } catch {
            migrationMessage = "Could not read schedule settings: \(error.localizedDescription)"
            return .failed
        }
        switch NativeScheduleBookingPolicy.applyScheduleSettings(current: current, draft: draft) {
        case let .apply(settings):
            var updated = snapshot
            updated.payload.settings = settings
            do {
                try repository.save(updated)
                try apply(updated)
            } catch {
                migrationMessage = "Could not save schedule settings: \(error.localizedDescription)"
                return .failed
            }
            enqueueSettingsUpsert(settings)
            return .saved
        case .baselineConflict:
            migrationMessage = "Schedule settings changed on another device. Review the latest settings before saving."
            return .baselineConflict
        }
    }

    // MARK: Atomic intake + handled timestamp (B3, P3)

    /// Read-only attention selector (task 8.02 policy) over the live
    /// snapshot for the request UI lane. No writes occur here.
    func bookingAttentionRows() -> [NativeBookingAttention.Row] {
        NativeBookingAttention.select(
            requests: snapshot.payload.bookingRequests ?? [],
            jobs: snapshot.payload.jobs ?? []
        )
    }

    /// Atomic intake after a verified pull, with a pull of its own:
    /// serializes overlapping refreshes, pulls, rechecks the owner across the
    /// suspension, then runs the shared intake (`applyBookingIntake`).
    ///
    /// Phase 12 (12.00b.2-K, P12-016): production does not call this. The
    /// launch and activation points call `runBookingIntakeIfPossible`, which
    /// converts from the pull that just committed instead of pulling again.
    /// It stays as the entry the plan 8.08 and 10.09 host tests
    /// (`native/StoreIntegrationTests/main.swift`) drive a real committed pull
    /// through; both entries run the same intake after their pull. Nothing in
    /// the app may call it (fix round 1, review M5: pinned by
    /// `native/ScheduleBookingRecoveryTests` section K): it lacks the gate and
    /// the pull mark.
    func runBookingIntakeAfterVerifiedPull(
        makeCustomerID: (() -> String)? = nil,
        nowISO: (() -> String)? = nil
    ) async -> BookingIntakeOutcome {
        guard !bookingIntakeInFlight else { return .alreadyRunning }
        guard hasExactSignedInWorkspace else { return .skipped(reason: "not-signed-in") }
        bookingIntakeInFlight = true
        defer { bookingIntakeInFlight = false }
        let capture = scheduleBookingOwnerCapture()
        let pull = await pullDeltaIfPossible()
        guard pull.state == .completed else {
            return .skipped(reason: pull.diagnosticCode ?? "pull/failed")
        }
        guard scheduleBookingOwnerStillCurrent(capture) else { return .skipped(reason: "owner-changed") }
        return await applyBookingIntake(makeCustomerID: makeCustomerID, nowISO: nowISO)
    }

    /// Phase 12 (12.00b.2-K, P12-016): booking intake at launch and on every
    /// activation (RN: once bootstrapping ends, `App.tsx:396`, and after each
    /// foreground sync, `context/AuthContext.tsx:118-120`). It runs only for
    /// the gated owner (the recovery gate: the exact signed-in workspace, the
    /// `.signedIn` gate, no account boundary open, the initial sync committed
    /// for this subject, writable persistence) and only while a pull that
    /// committed every table in this launch or activation is current
    /// (`bookingIntakePullMark`). It converts from that pull and never pulls
    /// itself. Nothing awaits between these checks and the commit, so no
    /// owner change can land in between.
    @discardableResult
    private func runBookingIntakeIfPossible() async -> BookingIntakeOutcome {
        guard !bookingIntakeInFlight else { return .alreadyRunning }
        guard scheduleBookingRecoveryBinding != nil else { return .skipped(reason: "gate") }
        guard bookingIntakePullCommitted else { return .skipped(reason: "no-committed-pull") }
        bookingIntakeInFlight = true
        defer { bookingIntakeInFlight = false }
        return await applyBookingIntake(makeCustomerID: nil, nowISO: nil)
    }

    /// Phase 12 (12.00b.2-K, P12-016): launch. Called where the subscription
    /// gate opens the signed-in gate, before recovery; starts a pass only when
    /// a booking is waiting to convert and the pull mark is current. On a cold
    /// launch the initial sync's commit set the mark, so bookings convert
    /// here. On a warm activation this runs before its pull (applying the
    /// identity cleared the mark), and after the paywall the mark was cleared
    /// by the wait (review M3), so `performForegroundRefresh` converts them.
    private func startBookingIntakeIfPossible() {
        guard scheduleBookingRecoveryBinding != nil, bookingIntakePullCommitted,
              NativeBookingIntake.needsIntake(snapshot.payload.bookingRequests ?? [])
        else { return }
        Task { [weak self] in
            await self?.runBookingIntakeIfPossible()
        }
    }

    /// Records that a pull for `subject`, started under account generation
    /// `generation` and mark period `period`, committed every table (the
    /// initial sync, or a delta pull with no failed table), unless the gate
    /// waits for the owner or the scene has entered the background since the
    /// pull began (final review M1).
    private func markBookingIntakePullCommitted(subject: String, generation: UInt64, period: UInt64) {
        guard period == pullMarkPeriod, !Self.gateWaitsForOwner(authenticationGateState) else { return }
        bookingIntakePullMark = (generation, subject)
    }

    /// Phase 12 final review (M3): the watermark per table that booking
    /// intake guards the request stamp and a repeat customer's fill with
    /// (`NativeScheduleBookingPolicy.recheckedIntakePlan`): the later of the
    /// saved delta cursor's and the watermark of this owner's initial sync in
    /// this process. The initial sync saves no cursor, so on a cold launch
    /// the saved one is the previous session's: a booking that arrived while
    /// the app was closed is newer than it, and a stamp guarded with it
    /// matched no row and was dropped (drop and redo). The initial sync read
    /// that booking, so its watermark covers it. Taking the later of the two
    /// never guards a row with a watermark older than a pull this device
    /// committed; a row written after both still makes the guard refuse.
    private func intakeGuardWatermarks() -> [String: String] {
        var tables = syncCursorStore.load().tables
        if let initial = initialSyncWatermarks,
           initial.generation == accountBoundaryGeneration, initial.subject == authenticatedUserSubject {
            for (table, watermark) in initial.tables {
                tables[table] = Canonical.NativeSyncCursor.later(tables[table], watermark)
            }
        }
        return tables
    }

    /// Phase 12 (12.00b.2-K fix round 1, review M3): the gates that wait for
    /// the owner, as long as the owner takes: onboarding, the starting point
    /// and the paywall. Entering one clears the intake mark (and, since the
    /// final review M1, the recovery mark), and no pull sets either while the
    /// gate is there.
    private static func gateWaitsForOwner(_ state: NativeAuthenticationGateState) -> Bool {
        switch state {
        case .onboarding, .startingPoint, .paywall: return true
        default: return false
        }
    }

    /// Whether such a pull has committed for the current owner, under the
    /// current account generation, since the identity was applied, the
    /// foreground refresh began, the scene entered the background or the
    /// gate waited for the owner.
    private var bookingIntakePullCommitted: Bool {
        guard let mark = bookingIntakePullMark else { return false }
        return mark.generation == accountBoundaryGeneration && mark.subject == authenticatedUserSubject
    }

    /// RN's customer id shape, `c<Date.now()>_…` (limitation L3: time-based).
    private static func intakeCustomerID() -> String {
        "c\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))"
    }

    /// The intake both entries run once their pull has committed and the
    /// owner is checked, holding `bookingIntakeInFlight`: plans against the
    /// live snapshot, revalidates the plan, and commits customers, jobs and
    /// requests in one snapshot transaction, then queues the drafts (the
    /// P12-008 commit rule: save, apply, queue). Nothing awaits between the
    /// plan and the commit. Reminder scheduling flows through the existing
    /// notification infrastructure (the publish below; the schedule key
    /// recomputes from the committed snapshot); no second sender.
    ///
    /// Phase 12 (12.00b.2-K, P12-016): it runs with no screen of the owner's
    /// behind it, so a failed save is reported with the sync status's
    /// bounded code (`intake/local-commit`), never in `migrationMessage`,
    /// which an unrelated screen would show later. Nothing was written, and
    /// the next pass tries again. A pass that found a booking to convert
    /// prints one line of counts and a fixed reason.
    private func applyBookingIntake(
        makeCustomerID: (() -> String)?,
        nowISO: (() -> String)?
    ) async -> BookingIntakeOutcome {
        let requests = snapshot.payload.bookingRequests ?? []
        guard NativeBookingIntake.needsIntake(requests) else { return .noChange }
        var converted = 0
        var jobs = 0
        var customers = 0
        var reason = "none"
        defer {
            Self.stageLogger.notice(
                "TradeReadyBookingIntake stage=pass converted=\(converted, privacy: .public) jobs=\(jobs, privacy: .public) customers=\(customers, privacy: .public) skipped=\(reason, privacy: .public)"
            )
        }
        guard !persistenceWritesBlocked else {
            reason = "read-only"
            return .skipped(reason: reason)
        }
        guard let settings = snapshot.payload.settings else {
            reason = "no-settings"
            return .skipped(reason: reason)
        }
        let stamp = nowISO?() ?? isoNow()
        let plan = NativeBookingIntake.plan(
            requests: requests,
            jobs: snapshot.payload.jobs ?? [],
            customers: snapshot.payload.customers ?? [],
            settings: settings,
            makeCustomerID: makeCustomerID ?? Self.intakeCustomerID,
            nowISO: { stamp }
        )
        // Contract §8 D-B3-2 and RN parity (fix round 1, review I1 and M1): a
        // request whose `jbk_` job is already on the device is linked to it
        // and the job is never touched; a repeat customer's blank fields are
        // filled, never replaced. With no suspension since the plan, the
        // recheck keeps everything the plan made.
        //
        // Phase 12 (12.00b.2-L, P12-017; Task 12d review M6): the request
        // stamp and a repeat customer's fill are guarded upserts with the
        // tables' watermarks from the pull that just committed, so a
        // customer's cancel or another device's edit that reaches the server
        // before they are pushed is never overwritten.
        guard let rechecked = NativeScheduleBookingPolicy.recheckedIntakePlan(
            plan,
            currentRequests: snapshot.payload.bookingRequests ?? [],
            currentJobs: snapshot.payload.jobs ?? [],
            currentCustomers: snapshot.payload.customers ?? [],
            guardSince: intakeGuardWatermarks()
        ) else {
            reason = "no-change"
            return .noChange
        }
        var updated = snapshot
        updated.payload.bookingRequests = rechecked.requests
        updated.payload.jobs = rechecked.jobs
        updated.payload.customers = rechecked.customers
        let drafts = rechecked.drafts
        let committed = commitScheduleBookingLocal(
            drafts: drafts,
            saveSnapshot: {
                try self.repository.save(updated)
                try self.apply(updated)
            },
            queueStage: "enqueue-booking-intake"
        )
        guard committed else {
            reason = "local-commit"
            recordLocalSyncFailure("intake/local-commit")
            return .skipped(reason: reason)
        }
        converted = rechecked.convertedRequestIDs.count
        jobs = rechecked.createdJobIDs.count
        customers = rechecked.createdCustomerIDs.count
        // Task 10.09 (B1): the booking-intake local commit above is itself a
        // committed canonical sync commit (new customers/jobs/requests from
        // the converted intake), distinct from the pull's own publish (which
        // ran from the PRE-intake snapshot). Publish once more from the
        // just-committed post-intake snapshot so notifications/cache/widget
        // mirror see the converted data, not the stale pre-intake one.
        // `commitScheduleBookingLocal` is synchronous, so no suspension
        // occurred since the caller last verified the owner.
        if let binding = derivedStatePublishBinding {
            await publishDerivedState(expectedOwnerBinding: binding)
        }
        return .applied(convertedRequestIDs: rechecked.convertedRequestIDs)
    }

    /// Field-scoped `handledAt` dismissal for portal change requests
    /// (and any unhandled row): merges ONLY the timestamp, preserves server
    /// lifecycle/history, and enqueues nothing when already handled.
    @discardableResult
    func stampBookingRequestHandled(requestID: String, nowISO: String? = nil) -> BookingHandledOutcome {
        guard ensurePersistenceWritable() else { return .failed }
        guard let current = snapshot.payload.bookingRequests?.first(where: { $0.id == requestID }) else {
            return .missing
        }
        guard let stamped = NativeBookingAttention.stampedHandled(current, nowISO: nowISO ?? isoNow()) else {
            return .alreadyHandled
        }
        // Never publish a whole stale booking request to repair one owned
        // field: the stamped copy differs ONLY in `handledAt` (struct copy).
        var updated = snapshot
        var records = updated.payload.bookingRequests ?? []
        guard let index = records.firstIndex(where: { $0.id == requestID }) else { return .missing }
        records[index] = stamped
        updated.payload.bookingRequests = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Could not dismiss this request: \(error.localizedDescription)"
            return .failed
        }
        enqueueUpsert(table: "bookingRequests", recordId: stamped.id, record: stamped)
        return .handled
    }

    // MARK: Owner responses (B4)

    /// Explicit owner decline: sends exactly one POST and takes ONLY the
    /// returned status into the local request. A 409 refreshes authoritative
    /// state instead of forcing the captured status; an unknown outcome never
    /// resends automatically (a decline may email the customer).
    ///
    /// Phase 12 (12.00b.2-L, P12-017): the server writes the status and
    /// appends the owner's entry to the request's history
    /// (`backend-workers/lib/booking/respond.js:64-75`). RN then updates the
    /// request in memory only and pushes nothing
    /// (`screens/TodayScreen.tsx:559-563`). So does this: the status is saved
    /// on the device and the request is not queued
    /// (`saveServerBookingRequestStatus`). With nothing queued for it, the
    /// next pull's rebase takes the server's row, history included
    /// (`rebasePulledDelta`). Before the POST it pushes what is queued, so a
    /// queued copy of the request reaches the server first and the server
    /// appends to it. While a change to the request is still queued, or
    /// refused and waiting in Settings › Cloud Sync, it sends nothing
    /// (`.awaitingAck`): pushed after the decline, that copy would put the
    /// old status and history back. It re-checks the account generation and
    /// the owner after every await, and applies nothing once either changed.
    func declineBookingRequest(
        requestID: String,
        responseService: NativeBookingResponseService? = nil,
        sessionBytes: Data? = nil
    ) async -> OwnerResponseOutcome {
        guard snapshot.payload.bookingRequests?.contains(where: { $0.id == requestID }) == true else {
            return .missing
        }
        guard !persistenceWritesBlocked else { return .failed(reason: "read-only") }
        let generation = accountBoundaryGeneration
        let capture = scheduleBookingOwnerCapture()
        let stillCurrent = { [unowned self] in
            accountBoundaryGeneration == generation && scheduleBookingOwnerStillCurrent(capture)
        }
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else {
            return .failed(reason: "session")
        }
        let service: NativeBookingResponseService
        do {
            service = try responseService ?? NativeBookingResponseService(
                endpoint: NativeBookingResponseService.resolvedEndpoint()
            )
        } catch { return .failed(reason: "configuration") }
        let serviceWithRefresh = NativeBookingResponseService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        // The owner's tap is explicit: `.manual` runs past a backoff, as the
        // accept's does.
        _ = await syncNowAndWait(trigger: .manual)
        guard stillCurrent() else { return .failed(reason: "owner-changed") }
        guard snapshot.payload.bookingRequests?.contains(where: { $0.id == requestID }) == true else {
            return .missing
        }
        if let wait = ownerResponseWait(for: ["bookingRequests/\(requestID)"]) { return .awaitingAck(wait) }
        let result: NativeBookingResponseResult
        do {
            result = try await serviceWithRefresh.decline(requestId: requestID, sessionBytes: bytes)
        } catch let error as NativeBookingResponseError {
            guard stillCurrent() else { return .failed(reason: "owner-changed") }
            let outcome = await mapBookingResponseError(error, requestID: requestID, capture: capture)
            // Fix round 1 (review Minor 1): the refusal paths pull; nothing
            // they read counts once the account changed during that await.
            guard stillCurrent() else { return .failed(reason: "owner-changed") }
            return outcome
        } catch {
            return .failed(reason: "transport")
        }
        guard stillCurrent() else { return .failed(reason: "owner-changed") }
        // Fix round 1 (review Minor 2): a failed save is said on the acting
        // screen, as the accept says it; the next pull brings the server's row.
        let saved = saveServerBookingRequestStatus(requestID: requestID, status: result.status)
        return .applied(status: result.status, alreadyApplied: result.alreadyApplied, savedLocally: saved)
    }

    /// Reschedule step 1: durably saves the revised job schedule locally,
    /// enqueues its sync, stages the publication proof as owner-bound pending
    /// work, and waits for the EXACT job-mutation acknowledgment (no pending
    /// queue item for the job + a fresh pull still showing the proven
    /// schedule). A superseding edit refuses instead of resolving wrong.
    ///
    /// TEST-ONLY since P12-015 (Phase 12 12.00b.2-L, Task 12c review M9): no
    /// screen may call this or `resolveBookingReschedule`. Both reschedule
    /// row actions call `acceptBookingReschedule`, which writes nothing to
    /// the job. A draft built from `request.slot` (the original booked slot)
    /// would move the job back and prove it (the P12-015 S1 warning). They
    /// stay because Task 12b's R cases and store-integration 8.08 stage
    /// proofs through them; backlog P12-018 removes them or moves those
    /// tests onto `acceptBookingReschedule`.
    func prepareBookingReschedule(
        requestID: String,
        scheduleDraft: NativeScheduleBookingPolicy.ScheduleOnlyDraft,
        writeStamp: String? = nil
    ) async -> ReschedulePrepareOutcome {
        guard scheduleDraft.jobID.isEmpty == false else { return .missing }
        // Review M9: the owner and account generation before the awaits,
        // compared after them (the check compared a fresh capture with
        // itself before).
        let generation = accountBoundaryGeneration
        let capture = scheduleBookingOwnerCapture()
        let stamp = writeStamp ?? isoNow()
        switch commitScheduleOnly(scheduleDraft) {
        case .saved:
            break
        case .baselineConflict:
            return .scheduleConflict
        case .missing:
            return .missing
        case .failed:
            return .failed
        }
        guard let job = snapshot.payload.jobs?.first(where: { $0.id == scheduleDraft.jobID }),
              let proof = NativeScheduleBookingPolicy.rescheduleProof(job: job, writeStamp: stamp)
        else { return .failed }
        if let binding = verifiedAccountBinding {
            try? pendingScheduleBookingWorkStore().stage(
                .init(kind: .rescheduleProof(requestId: requestID, proof: proof, writeStamp: stamp),
                      ownerBinding: binding)
            )
        }
        _ = await syncNowAndWait(trigger: .localChange)
        guard accountBoundaryGeneration == generation, scheduleBookingOwnerStillCurrent(capture) else {
            return .failed
        }
        _ = await pullDeltaIfPossible()
        guard accountBoundaryGeneration == generation, scheduleBookingOwnerStillCurrent(capture) else {
            return .failed
        }
        let pendingAck = mutationQueue.load().contains {
            $0.table == "jobs" && $0.recordId == proof.jobId
        }
        guard !pendingAck else { return .awaitingAck }
        guard let currentJob = snapshot.payload.jobs?.first(where: { $0.id == proof.jobId }),
              NativeScheduleBookingPolicy.proofMatchesCurrentJob(proof, job: currentJob)
        else {
            if let binding = verifiedAccountBinding {
                try? pendingScheduleBookingWorkStore().remove {
                    if case let .rescheduleProof(req, _, _) = $0.kind { return req == requestID && $0.ownerBinding == binding }
                    return false
                }
            }
            return .superseded
        }
        return .proofReady(proof: proof)
    }

    /// Reschedule step 2: rechecks the owner/record AND the proof against the
    /// current job after the suspension, then resolves with the exact proof.
    /// `schedule_changed` refreshes and refuses; unknown outcome keeps the
    /// staged proof for an explicit later retry — never an automatic resend.
    ///
    /// TEST-ONLY since P12-015 (Task 12c review M9): see
    /// `prepareBookingReschedule`. Phase 12 (12.00b.2-L): it re-checks the
    /// account generation with the owner after its await, as the decline does.
    func resolveBookingReschedule(
        requestID: String,
        proof: NativeScheduleProof,
        responseService: NativeBookingResponseService? = nil,
        sessionBytes: Data? = nil
    ) async -> RescheduleResolveOutcome {
        let generation = accountBoundaryGeneration
        let capture = scheduleBookingOwnerCapture()
        guard snapshot.payload.bookingRequests?.contains(where: { $0.id == requestID }) == true else {
            return .missing
        }
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else {
            return .failed(reason: "session")
        }
        let service: NativeBookingResponseService
        do {
            service = try responseService ?? NativeBookingResponseService(
                endpoint: NativeBookingResponseService.resolvedEndpoint()
            )
        } catch { return .failed(reason: "configuration") }
        let serviceWithRefresh = NativeBookingResponseService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        guard scheduleBookingOwnerStillCurrent(capture) else { return .failed(reason: "owner-changed") }
        guard let currentJob = snapshot.payload.jobs?.first(where: { $0.id == proof.jobId }),
              NativeScheduleBookingPolicy.proofMatchesCurrentJob(proof, job: currentJob)
        else { return .superseded }
        // Phase 12 (12.00b.2-L, P12-017): as the decline.
        if let wait = ownerResponseWait(for: ["bookingRequests/\(requestID)"]) { return .awaitingAck(wait) }
        let result: NativeBookingResponseResult
        do {
            result = try await serviceWithRefresh.resolveReschedule(
                requestId: requestID, proof: proof, sessionBytes: bytes
            )
        } catch let error as NativeBookingResponseError {
            // Fix round 1 (review Minor 1): the account generation and owner
            // are re-checked after each refusal's pull, as the decline does.
            let stillCurrent = { [unowned self] in
                accountBoundaryGeneration == generation && scheduleBookingOwnerStillCurrent(capture)
            }
            switch error {
            case let .invalidState(currentStatus), let .scheduleChanged(currentStatus):
                _ = await pullDeltaIfPossible()
                guard stillCurrent() else { return .failed(reason: "owner-changed") }
                return .needsReview(currentStatus: currentStatus)
            case .unknownOutcome:
                return .unknownOutcome
            case .notFound:
                _ = await pullDeltaIfPossible()
                guard stillCurrent() else { return .failed(reason: "owner-changed") }
                return .missing
            default:
                return .failed(reason: String(describing: error))
            }
        } catch {
            return .failed(reason: "transport")
        }
        guard accountBoundaryGeneration == generation, scheduleBookingOwnerStillCurrent(capture) else {
            return .failed(reason: "owner-changed")
        }
        // Phase 12 (12.00b.2-L, P12-017): saved, not queued, as the decline.
        _ = saveServerBookingRequestStatus(requestID: requestID, status: result.status)
        if let binding = capture.binding {
            try? pendingScheduleBookingWorkStore().remove {
                if case let .rescheduleProof(req, _, _) = $0.kind { return req == requestID && $0.ownerBinding == binding }
                return false
            }
        }
        return .resolved(status: result.status, alreadyApplied: result.alreadyApplied)
    }

    /// Phase 12 (12.00b.2-J, P12-015): the owner accepts a customer's
    /// reschedule request from a request row ("I've rescheduled it" on
    /// Today, "Resolve" on Requests). RN's order: the owner moves the job in
    /// the schedule editor first, and that save queues its own sync; this
    /// only confirms it (`screens/TodayScreen.tsx:607-616` →
    /// `utils/bookingRespond.ts:20-46`, "resolve_reschedule after moving the
    /// job", `:3`).
    ///
    /// - It writes nothing to the job. `request.slot` is the original booked
    ///   slot, immutable history (contract §7), and never a target.
    /// - Contract §7 step 1: it syncs and pulls, then requires that no
    ///   change to the job, or to the request, is still queued or refused
    ///   and waiting in Settings › Cloud Sync (`.awaitingAck` otherwise;
    ///   12.00b.2-L, review M1).
    /// - The proof is the job's CURRENT `(date, start)` after that pull
    ///   (`NativeScheduleBookingPolicy.acceptProof`), staged as owner-bound
    ///   pending work before the ack check, as `prepareBookingReschedule`
    ///   stages it. Success removes it, as `resolveBookingReschedule` does;
    ///   every other outcome leaves it to the recovery rules (Task 12b).
    /// - A job still at the request's slot is resolved too, as RN resolves
    ///   it: the Worker reads no proof
    ///   (`backend-workers/src/routes/booking/respond.js:35-40`) and §7's
    ///   check is the job's own `(date, start)`. The notice says so.
    /// - It re-checks the account generation and the owner after every
    ///   await, and applies nothing once either changed.
    /// - The local request takes only the server's status, saved without
    ///   queueing the request (`saveServerBookingRequestStatus`).
    /// - The outcome is for the acting screen (`ownerNotice`), never
    ///   `migrationMessage`.
    func acceptBookingReschedule(
        requestID: String,
        responseService: NativeBookingResponseService? = nil,
        sessionBytes: Data? = nil
    ) async -> BookingRescheduleAcceptOutcome {
        guard !persistenceWritesBlocked else { return .readOnly }
        let generation = accountBoundaryGeneration
        let capture = scheduleBookingOwnerCapture()
        let stillCurrent = { [unowned self] in
            accountBoundaryGeneration == generation && scheduleBookingOwnerStillCurrent(capture)
        }
        let stopped = { [unowned self] () -> BookingRescheduleAcceptOutcome in
            persistenceWritesBlocked ? .readOnly : .accountChanged
        }
        guard stillCurrent() else { return .failed(.rejectedSession) }
        guard snapshot.payload.bookingRequests?.contains(where: { $0.id == requestID }) == true else {
            return .missing
        }
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else {
            return .failed(.malformedSession)
        }
        let service: NativeBookingResponseService
        do {
            service = try responseService ?? NativeBookingResponseService(
                endpoint: NativeBookingResponseService.resolvedEndpoint()
            )
        } catch { return .failed(.invalidConfiguration) }
        let serviceWithRefresh = NativeBookingResponseService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        // The owner's tap is explicit, as pull-to-refresh is: `.manual` runs
        // past a backoff an earlier offline attempt left, so a retry once the
        // connection is back pushes the move instead of answering awaitingAck.
        _ = await syncNowAndWait(trigger: .manual)
        guard stillCurrent() else { return stopped() }
        _ = await pullDeltaIfPossible()
        guard stillCurrent() else { return stopped() }
        guard let request = snapshot.payload.bookingRequests?.first(where: { $0.id == requestID }) else {
            return .missing
        }
        guard request.status == "reschedule_requested" else { return .needsReview(currentStatus: request.status) }
        guard let jobID = request.convertedJobId, !jobID.isEmpty,
              let job = snapshot.payload.jobs?.first(where: { $0.id == jobID })
        else { return .notLinkedToJob }
        guard let proof = NativeScheduleBookingPolicy.acceptProof(job: job, request: request) else {
            return .jobUnscheduled
        }
        if let binding = capture.binding {
            try? pendingScheduleBookingWorkStore().stage(
                .init(kind: .rescheduleProof(requestId: requestID, proof: proof, writeStamp: proof.updatedAt),
                      ownerBinding: binding)
            )
        }
        // The request too: a queued copy pushed after the server's resolve
        // would put the old status back on the server row. A change the
        // server refused waits in Cloud Sync and has not reached it either
        // (12.00b.2-L, review M1: §7 step 1 wants the exact job change
        // acknowledged; a Retry of a refused request copy would push it
        // after the resolve).
        if let wait = ownerResponseWait(for: ["jobs/\(jobID)", "bookingRequests/\(requestID)"]) {
            return .awaitingAck(wait)
        }
        let result: NativeBookingResponseResult
        do {
            result = try await serviceWithRefresh.resolveReschedule(
                requestId: requestID, proof: proof, sessionBytes: bytes
            )
        } catch let error as NativeBookingResponseError {
            guard stillCurrent() else { return stopped() }
            switch error {
            case let .invalidState(echoed):
                _ = await pullDeltaIfPossible()
                guard stillCurrent() else { return stopped() }
                return .needsReview(currentStatus: statusAfterRefusal(
                    echoed, requestID: requestID, from: ["reschedule_requested"]))
            case let .scheduleChanged(echoed):
                _ = await pullDeltaIfPossible()
                guard stillCurrent() else { return stopped() }
                return .needsReview(currentStatus: statusAfterRefusal(echoed, requestID: requestID, from: []))
            case .notFound:
                _ = await pullDeltaIfPossible()
                return stillCurrent() ? .missing : stopped()
            case .unknownOutcome:
                return .unknownOutcome
            default:
                return .failed(error)
            }
        } catch {
            // Only the request encoding throws anything else, before sending.
            return .failed(.invalidRequest)
        }
        guard stillCurrent() else { return stopped() }
        let saved = saveServerBookingRequestStatus(requestID: requestID, status: result.status)
        if let binding = capture.binding {
            try? pendingScheduleBookingWorkStore().remove {
                if case let .rescheduleProof(req, _, _) = $0.kind { return req == requestID && $0.ownerBinding == binding }
                return false
            }
        }
        return .confirmed(.init(
            status: result.status,
            alreadyApplied: result.alreadyApplied,
            date: proof.date,
            start: proof.start,
            end: job.scheduledEndTime,
            keptOriginalTime: request.slot.map { $0.date == proof.date && $0.start == proof.start } ?? false,
            savedLocally: saved
        ))
    }

    /// Phase 12 (12.00b.2-J, P12-015; 12.00b.2-L, P12-017 for the decline and
    /// the legacy resolve): takes the server's status into the local request
    /// after an owner response the server accepted. Saved first, then shown,
    /// and not queued: the server already wrote the request's status and
    /// history, and pushing this copy would replace them with this device's
    /// older history (contract §2.6: never replay a whole stale request). RN
    /// clears it in memory the same way (`screens/TodayScreen.tsx:559-563`);
    /// the next pull brings the server's row. False when nothing was saved.
    private func saveServerBookingRequestStatus(requestID: String, status: String) -> Bool {
        guard !persistenceWritesBlocked,
              var records = snapshot.payload.bookingRequests,
              let index = records.firstIndex(where: { $0.id == requestID })
        else { return false }
        records[index].status = status
        var updated = snapshot
        updated.payload.bookingRequests = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            return false
        }
        return true
    }

    private func mapBookingResponseError(
        _ error: NativeBookingResponseError,
        requestID: String,
        capture: (subject: String?, binding: String?)
    ) async -> OwnerResponseOutcome {
        switch error {
        case let .invalidState(echoed), let .scheduleChanged(echoed):
            _ = await pullDeltaIfPossible()
            return .needsReview(currentStatus: statusAfterRefusal(
                echoed, requestID: requestID, from: ["booked", "confirmed", "reschedule_requested"]))
        case .unknownOutcome:
            return .unknownOutcome
        case .notFound:
            _ = await pullDeltaIfPossible()
            return .missing
        case .rejectedSession, .malformedSession:
            return .failed(reason: "session")
        case .invalidConfiguration:
            return .failed(reason: "configuration")
        case .invalidRequest:
            return .failed(reason: "invalid-request")
        case .rateLimited, .unavailable, .invalidResponse:
            return .failed(reason: "transient")
        }
    }

    /// Phase 12 (12.00b.2-L, Task 12c review M2): the committed Worker's 409
    /// `invalid_state` carries no status (`backend-workers/lib/booking/respond.js:61`),
    /// which the respond client reads as `unknown`. The pull the caller has
    /// just run knows the request's status: that is the answer, unless it is
    /// still one the action starts from (`sourceStatuses`), which means the
    /// pull did not bring the change and tells nothing.
    private func statusAfterRefusal(_ echoed: String, requestID: String, from sourceStatuses: Set<String>) -> String {
        guard echoed == "unknown",
              let local = snapshot.payload.bookingRequests?.first(where: { $0.id == requestID })?.status,
              !sourceStatuses.contains(local)
        else { return echoed }
        return local
    }

    /// Phase 12 (12.00b.2-L, P12-017): why an owner response to a booking
    /// request must wait, or nil. A change to one of these records
    /// (`<table>/<recordId>`) that is still queued would reach the server
    /// after the response and put an older copy back (`.queued`); one the
    /// server refused waits in Settings › Cloud Sync, where a Retry would do
    /// the same (`.refused`). A rejected-change store that cannot be read
    /// counts as waiting (fail closed): `.unreadable` (fix round 1, review
    /// Minor 5), whose notice does not blame the connection.
    private func ownerResponseWait(for keys: Set<String>) -> OwnerResponseWait? {
        guard pendingMutationKeys().isDisjoint(with: keys) else { return .queued }
        guard let refused = try? rejectedChangeKeys() else { return .unreadable }
        return refused.isDisjoint(with: keys) ? nil : .refused
    }

    // MARK: Booking-link administration (B2)

    /// Server-first booking-link administration: reconciles authority with a
    /// fresh `status` read, mutates with the server revision (native always
    /// sends `expectedRevision`), and merges ONLY the returned display fields
    /// into the latest settings after rechecking the owner. A server success
    /// followed by a local-save failure stages owner-bound pending mirror
    /// work and reports `.recoveryStaged` — the mutation is replayed by
    /// operation ID, never repeated as a new capability.
    func administerBookingLink(
        action: NativeBookingAdminAction,
        enabled: Bool? = nil,
        operationId: String = UUID().uuidString,
        adminService: NativeBookingAdministrationService? = nil,
        sessionBytes: Data? = nil
    ) async -> BookingLinkAdminOutcome {
        // P12-027: the operation ID is durable. `operationId` is only the ID
        // for a NEW operation; an unfinished operation of the same action is
        // retried under its own staged ID, and a different action waits.
        guard action != .status, !bookingAdminInFlight, hasExactSignedInWorkspace,
              let binding = verifiedAccountBinding, !binding.isEmpty
        else {
            return await performBookingLinkAdmin(
                action: action, enabled: enabled, operationId: operationId,
                adminService: adminService, sessionBytes: sessionBytes)
        }
        let begun = beginAdminOperation(
            target: Self.bookingAdminTarget, action: Self.adminActionName(action), enabled: enabled,
            proposedID: operationId, binding: binding)
        guard case let .run(id, created) = begun else { return .failed(reason: begun.failureReason) }
        let outcome = await performBookingLinkAdmin(
            action: action, enabled: enabled, operationId: id,
            adminService: adminService, sessionBytes: sessionBytes)
        let settled: Bool
        switch outcome {
        case .applied, .stale, .alreadyExists, .recoveryStaged:
            settled = true
        case .unknownOutcome:
            settled = false
        case let .failed(reason):
            settled = NativeScheduleBookingPolicy.adminOutcomeSettlesOperation(
                failureReason: reason, unknown: false, createdThisCall: created)
        }
        if settled { finishAdminOperation(target: Self.bookingAdminTarget, operationId: id, binding: binding) }
        return outcome
    }

    private func performBookingLinkAdmin(
        action: NativeBookingAdminAction,
        enabled: Bool?,
        operationId: String,
        adminService: NativeBookingAdministrationService?,
        sessionBytes: Data?
    ) async -> BookingLinkAdminOutcome {
        guard !bookingAdminInFlight else { return .failed(reason: "already-running") }
        guard hasExactSignedInWorkspace else { return .failed(reason: "not-signed-in") }
        bookingAdminInFlight = true
        defer { bookingAdminInFlight = false }
        let capture = scheduleBookingOwnerCapture()
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else {
            return .failed(reason: "session")
        }
        let service: NativeBookingAdministrationService
        do {
            service = try adminService ?? NativeBookingAdministrationService(
                endpoint: NativeBookingAdministrationService.resolvedEndpoint()
            )
        } catch { return .failed(reason: "configuration") }
        let wired = NativeBookingAdministrationService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        let displayToken = snapshot.payload.settings?.bookingLink?.token
        let status: NativeBookingLinkStatus
        do {
            status = try await wired.status(token: displayToken, sessionBytes: bytes)
        } catch {
            return .failed(reason: "status-unavailable")
        }
        guard scheduleBookingOwnerStillCurrent(capture) else { return .failed(reason: "owner-changed") }
        let result: NativeBookingAdminResult
        do {
            switch action {
            case .mint:
                result = try await wired.mint(operationId: operationId, expectedRevision: status.revision, sessionBytes: bytes)
            case .setEnabled:
                guard let enabled else { return .failed(reason: "invalid-request") }
                result = try await wired.setEnabled(enabled, operationId: operationId, expectedRevision: status.revision, sessionBytes: bytes)
            case .rotate:
                result = try await wired.rotate(operationId: operationId, expectedRevision: status.revision, sessionBytes: bytes)
            case .status:
                return .applied(revision: status.revision, sharesURL: NativeScheduleBookingPolicy.mayAdoptDisplayToken(displayToken: displayToken, status: status))
            }
        } catch let error as NativeBookingAdminError {
            switch error {
            case let .staleRevision(currentEnabled, _):
                // Another device won: adopt the authoritative flag into the
                // display mirror and report stale — never force our intent.
                mergeBookingDisplayMirror(token: nil, enabled: currentEnabled, forceEnabledOnly: true)
                return .stale(currentEnabled: currentEnabled)
            case .alreadyExists:
                return .alreadyExists
            case .unknownOutcome:
                return .unknownOutcome
            default:
                return .failed(reason: String(describing: error))
            }
        } catch {
            return .failed(reason: "transport")
        }
        guard scheduleBookingOwnerStillCurrent(capture), capture.binding != nil else {
            // Committed server-side for an owner we can no longer publish
            // for: stage the mirror under the captured binding so recovery —
            // never a blind re-mint — can finish it after re-verification.
            if let binding = capture.binding {
                try? pendingScheduleBookingWorkStore().stage(.init(
                    kind: .bookingMirror(token: result.token, enabled: result.enabled,
                                         revision: result.revision, operationId: result.operationId ?? operationId),
                    ownerBinding: binding))
            }
            return .recoveryStaged
        }
        guard var settings = snapshot.payload.settings else { return .failed(reason: "no-settings") }
        do {
            settings = try NativeBookingAdminMirror.apply(
                to: settings, token: result.token, enabled: result.enabled
            )
        } catch {
            if let binding = capture.binding {
                try? pendingScheduleBookingWorkStore().stage(.init(
                    kind: .bookingMirror(token: result.token, enabled: result.enabled,
                                         revision: result.revision, operationId: result.operationId ?? operationId),
                    ownerBinding: binding))
            }
            return .recoveryStaged
        }
        var updated = snapshot
        updated.payload.settings = settings
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            if let binding = capture.binding {
                try? pendingScheduleBookingWorkStore().stage(.init(
                    kind: .bookingMirror(token: result.token, enabled: result.enabled,
                                         revision: result.revision, operationId: result.operationId ?? operationId),
                    ownerBinding: binding))
            }
            migrationMessage = "The booking link was updated on the server but the local copy could not be saved."
            return .recoveryStaged
        }
        enqueueSettingsUpsert(settings)
        if let binding = capture.binding {
            try? pendingScheduleBookingWorkStore().remove {
                if case .bookingMirror = $0.kind { return $0.ownerBinding == binding }
                return false
            }
        }
        let displayTokenAfter = settings.bookingLink?.token
        // Shareable only when the display copy is a validated capability
        // token: a stale or missing token takes the rotation-recovery path,
        // never a share URL.
        let sharesURL = displayTokenAfter
            .flatMap(NativeBookingAdministrationService.bookingURL(token:)) != nil
            && (result.token != nil || status.tokenValid)
        return .applied(revision: result.revision, sharesURL: sharesURL)
    }

    /// Reconciles link authority before adopting or sharing a local display
    /// copy: share/adopt ONLY on a fresh `tokenValid:true` read. A stale or
    /// missing token reports the rotation-recovery path instead of a URL.
    func reconcileBookingLinkForSharing(
        adminService: NativeBookingAdministrationService? = nil,
        sessionBytes: Data? = nil
    ) async -> (status: NativeBookingLinkStatus?, shareURL: URL?) {
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else { return (nil, nil) }
        let service: NativeBookingAdministrationService
        do {
            service = try adminService ?? NativeBookingAdministrationService(
                endpoint: NativeBookingAdministrationService.resolvedEndpoint()
            )
        } catch { return (nil, nil) }
        let displayToken = snapshot.payload.settings?.bookingLink?.token
        guard let status = try? await service.status(token: displayToken, sessionBytes: bytes) else {
            return (nil, nil)
        }
        guard NativeScheduleBookingPolicy.mayAdoptDisplayToken(displayToken: displayToken, status: status),
              let token = displayToken,
              let url = NativeBookingAdministrationService.bookingURL(token: token)
        else { return (status, nil) }
        return (status, url)
    }

    /// Display-only mirror merge for reconciliation paths: `set_enabled`
    /// results (no token) update the flag only and fail closed with no link;
    /// a token always replaces the display copy after capability validation.
    private func mergeBookingDisplayMirror(token: String?, enabled: Bool, forceEnabledOnly: Bool) {
        guard ensurePersistenceWritable(),
              var settings = snapshot.payload.settings else { return }
        do {
            if forceEnabledOnly, token == nil {
                guard settings.bookingLink != nil else { return }
            }
            settings = try NativeBookingAdminMirror.apply(to: settings, token: token, enabled: enabled)
            var updated = snapshot
            updated.payload.settings = settings
            try repository.save(updated)
            try apply(updated)
            enqueueSettingsUpsert(settings)
        } catch {
            migrationMessage = "The booking link changed on another device and the local copy could not be updated."
        }
    }

    // MARK: Durable admin operation IDs (P12-027)

    static let bookingAdminTarget = "booking"
    static func portalAdminTarget(_ customerID: String) -> String { "portal/\(customerID)" }

    fileprivate static func adminActionName(_ action: NativeBookingAdminAction) -> String {
        switch action {
        case .mint: return "mint"
        case .setEnabled: return "set_enabled"
        case .rotate: return "rotate"
        case .status: return "status"
        }
    }

    fileprivate static func adminActionName(_ action: NativePortalAdminAction) -> String {
        switch action {
        case .mint: return "mint"
        case .setEnabled: return "set_enabled"
        case .rotate: return "rotate"
        case .status: return "status"
        }
    }

    fileprivate enum AdminOperationStart {
        case run(id: String, created: Bool)
        case blocked
        case persistFailed

        var failureReason: String {
            switch self {
            case .blocked: return "operation-pending"
            case .persistFailed: return "persist"
            case .run: return ""
            }
        }
    }

    /// The unfinished operation for `target`, for the screen to offer Retry.
    /// Expired ones (past the server's replay window) are not offered.
    func pendingAdminOperation(target: String) -> NativeScheduleBookingPolicy.PendingAdminOperation? {
        guard let binding = verifiedAccountBinding else { return nil }
        let pending = storedAdminOperation(target: target, binding: binding)
        guard let pending else { return nil }
        let plan = NativeScheduleBookingPolicy.planAdminOperation(
            pending: pending, action: pending.action, enabled: pending.enabled, proposedID: "", now: Date())
        if case .reuse = plan { return pending }
        return nil
    }

    private func storedAdminOperation(
        target: String, binding: String
    ) -> NativeScheduleBookingPolicy.PendingAdminOperation? {
        for item in pendingScheduleBookingWorkStore().load() where item.ownerBinding == binding {
            if case let .adminOperation(t, action, enabled, operationId, stagedAt) = item.kind, t == target {
                return .init(target: t, action: action, enabled: enabled, operationId: operationId, stagedAt: stagedAt)
            }
        }
        return nil
    }

    /// Decides the operation ID for one administration call and, for a new
    /// operation, stages it BEFORE the request is sent. A staging failure
    /// refuses the call: a mutation whose ID cannot be remembered must not be
    /// sent (a lost response would leave no way to replay it).
    fileprivate func beginAdminOperation(
        target: String, action: String, enabled: Bool?, proposedID: String, binding: String
    ) -> AdminOperationStart {
        let plan = NativeScheduleBookingPolicy.planAdminOperation(
            pending: storedAdminOperation(target: target, binding: binding),
            action: action, enabled: enabled, proposedID: proposedID, now: Date())
        switch plan {
        case .blocked:
            return .blocked
        case let .reuse(id):
            return .run(id: id, created: false)
        case let .fresh(id):
            do {
                try pendingScheduleBookingWorkStore().stage(.init(
                    kind: .adminOperation(target: target, action: action, enabled: enabled,
                                          operationId: id, stagedAt: isoNow()),
                    ownerBinding: binding))
            } catch {
                return .persistFailed
            }
            return .run(id: id, created: true)
        }
    }

    /// Clears an operation once its outcome is definite. Matches by ID, so a
    /// newer operation staged meanwhile is never removed.
    fileprivate func finishAdminOperation(target: String, operationId: String, binding: String) {
        try? pendingScheduleBookingWorkStore().remove {
            if case let .adminOperation(t, _, _, id, _) = $0.kind {
                return t == target && id == operationId && $0.ownerBinding == binding
            }
            return false
        }
    }

    // MARK: Portal-link administration (P1)

    /// Server-first per-customer portal administration with per-customer
    /// serialization. Requires a saved customer (invoice-derived identities
    /// must be promoted first); re-resolves the customer after every
    /// suspension and merges ONLY the returned portal display fields — never
    /// a re-saved captured array. `already_exists` refreshes authority and
    /// adopts only a matching current display copy, never an implicit
    /// rotate. A missing raw token surfaces the explicit recovery rotation.
    func administerPortalLink(
        customerID: String,
        action: NativePortalAdminAction,
        enabled: Bool? = nil,
        operationId: String = UUID().uuidString,
        portalService: NativePortalAdministrationService? = nil,
        sessionBytes: Data? = nil
    ) async -> PortalLinkAdminOutcome {
        // P12-027: see `administerBookingLink`; one pending operation per customer.
        guard action != .status, !portalAdminInFlight.contains(customerID), hasExactSignedInWorkspace,
              snapshot.payload.customers?.contains(where: { $0.id == customerID }) == true,
              let binding = verifiedAccountBinding, !binding.isEmpty
        else {
            return await performPortalLinkAdmin(
                customerID: customerID, action: action, enabled: enabled, operationId: operationId,
                portalService: portalService, sessionBytes: sessionBytes)
        }
        let target = Self.portalAdminTarget(customerID)
        let begun = beginAdminOperation(
            target: target, action: Self.adminActionName(action), enabled: enabled,
            proposedID: operationId, binding: binding)
        guard case let .run(id, created) = begun else { return .failed(reason: begun.failureReason) }
        let outcome = await performPortalLinkAdmin(
            customerID: customerID, action: action, enabled: enabled, operationId: id,
            portalService: portalService, sessionBytes: sessionBytes)
        let settled: Bool
        switch outcome {
        case .applied, .alreadyExists, .needsExplicitRotate, .recoveryStaged, .missingCustomer:
            settled = true
        case .unknownOutcome, .alreadyRunning:
            settled = false
        case let .failed(reason):
            settled = NativeScheduleBookingPolicy.adminOutcomeSettlesOperation(
                failureReason: reason, unknown: false, createdThisCall: created)
        }
        if settled { finishAdminOperation(target: target, operationId: id, binding: binding) }
        return outcome
    }

    private func performPortalLinkAdmin(
        customerID: String,
        action: NativePortalAdminAction,
        enabled: Bool?,
        operationId: String,
        portalService: NativePortalAdministrationService?,
        sessionBytes: Data?
    ) async -> PortalLinkAdminOutcome {
        guard !portalAdminInFlight.contains(customerID) else { return .alreadyRunning }
        guard hasExactSignedInWorkspace else { return .failed(reason: "not-signed-in") }
        guard snapshot.payload.customers?.contains(where: { $0.id == customerID }) == true else {
            return .missingCustomer
        }
        portalAdminInFlight.insert(customerID)
        defer { portalAdminInFlight.remove(customerID) }
        let capture = scheduleBookingOwnerCapture()
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else {
            return .failed(reason: "session")
        }
        let service: NativePortalAdministrationService
        do {
            service = try portalService ?? NativePortalAdministrationService(
                endpoint: NativePortalAdministrationService.resolvedEndpoint()
            )
        } catch { return .failed(reason: "configuration") }
        let wired = NativePortalAdministrationService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        let result: NativePortalAdminResult
        do {
            switch action {
            case .mint:
                result = try await wired.mint(customerId: customerID, operationId: operationId, sessionBytes: bytes)
            case .setEnabled:
                guard let enabled else { return .failed(reason: "invalid-request") }
                result = try await wired.setEnabled(enabled, customerId: customerID, operationId: operationId, sessionBytes: bytes)
            case .rotate:
                result = try await wired.rotate(customerId: customerID, operationId: operationId, sessionBytes: bytes)
            case .status:
                return .applied
            }
        } catch let error as NativePortalAdminError {
            switch error {
            case .alreadyExists:
                return await resolvePortalAlreadyExists(
                    customerID: customerID, wired: wired, bytes: bytes, capture: capture
                )
            case .unknownOutcome:
                return .unknownOutcome
            case .notFound:
                _ = await pullDeltaIfPossible()
                return .missingCustomer
            default:
                return .failed(reason: String(describing: error))
            }
        } catch {
            return .failed(reason: "transport")
        }
        guard scheduleBookingOwnerStillCurrent(capture), let binding = capture.binding else {
            if let binding = capture.binding {
                try? pendingScheduleBookingWorkStore().stage(.init(
                    kind: .portalMirror(customerId: customerID, token: result.token,
                                        enabled: result.enabled, operationId: result.operationId),
                    ownerBinding: binding))
            }
            return .recoveryStaged
        }
        guard mergePortalDisplayFields(customerID: customerID, token: result.token, enabled: result.enabled) else {
            try? pendingScheduleBookingWorkStore().stage(.init(
                kind: .portalMirror(customerId: customerID, token: result.token,
                                    enabled: result.enabled, operationId: result.operationId),
                ownerBinding: binding))
            return .recoveryStaged
        }
        try? pendingScheduleBookingWorkStore().remove {
            if case let .portalMirror(id, _, _, _) = $0.kind { return id == customerID && $0.ownerBinding == binding }
            return false
        }
        return .applied
    }

    private func resolvePortalAlreadyExists(
        customerID: String,
        wired: NativePortalAdministrationService,
        bytes: Data,
        capture: (subject: String?, binding: String?)
    ) async -> PortalLinkAdminOutcome {
        guard let status = try? await wired.status(
            customerId: customerID,
            token: snapshot.payload.customers?.first(where: { $0.id == customerID })?.portal?.token,
            sessionBytes: bytes
        ), scheduleBookingOwnerStillCurrent(capture)
        else { return .failed(reason: "status-unavailable") }
        let displayToken = snapshot.payload.customers?.first(where: { $0.id == customerID })?.portal?.token
        if NativeScheduleBookingPolicy.adoptAfterAlreadyExists(displayToken: displayToken, status: status) {
            _ = mergePortalDisplayFields(customerID: customerID, token: nil, enabled: status.enabled)
            return .alreadyExists(adoptedCurrent: true)
        }
        // A present-but-stale token needs the same recovery handling as a
        // missing one: explicit confirmed rotate, never silent re-mint.
        return .needsExplicitRotate
    }

    /// Merges ONLY the returned portal display fields into the LATEST
    /// customer record (re-resolved by stable ID — never a re-saved captured
    /// array). A nil token keeps the existing display token (server
    /// `set_enabled` shape); a provided token replaces it after capability
    /// validation. Unknown/preserved customer fields survive by struct copy.
    /// `automatic` (the recovery pass, final review M5): nothing runs on a
    /// screen the owner is using, so a failed save records the bounded code
    /// `recovery/local-commit` in the sync status instead of writing
    /// `migrationMessage`, which would surface later on an unrelated screen.
    @discardableResult
    private func mergePortalDisplayFields(
        customerID: String, token: String?, enabled: Bool?, automatic: Bool = false
    ) -> Bool {
        guard ensurePersistenceWritable(),
              var records = snapshot.payload.customers,
              let index = records.firstIndex(where: { $0.id == customerID })
        else { return false }
        var merged = records[index]
        do {
            if let token {
                guard NativePortalAdministrationService.isValidCapabilityToken(token) else { return false }
                merged.portal = try decodeCustomerPortal(token: token, enabled: enabled ?? merged.portal?.enabled ?? true)
            } else if let enabled {
                guard var portal = merged.portal else { return false }
                portal.enabled = enabled
                merged.portal = portal
            } else {
                return true
            }
        } catch {
            return false
        }
        records[index] = merged
        var updated = snapshot
        updated.payload.customers = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            if automatic {
                recordLocalSyncFailure(Self.recoveryLocalCommitCode)
            } else {
                migrationMessage = "The portal link was updated on the server but the local copy could not be saved."
            }
            return false
        }
        enqueueUpsert(table: "customers", recordId: customerID, record: merged)
        return true
    }

    private func decodeCustomerPortal(token: String, enabled: Bool) throws -> Canonical.Customer.Portal {
        let fields: [String: AnyCodableValue] = [
            "token": AnyCodableValue(token),
            "enabled": AnyCodableValue(enabled),
        ]
        let data = try JSONEncoder().encode(fields)
        return try JSONDecoder().decode(Canonical.Customer.Portal.self, from: data)
    }

    /// Authoritative portal reconciliation read (§6): share or adopt a
    /// display token ONLY on a fresh `tokenValid:true` read.
    func reconcilePortalLinkForSharing(
        customerID: String,
        portalService: NativePortalAdministrationService? = nil,
        sessionBytes: Data? = nil
    ) async -> (status: NativePortalLinkStatus?, shareURL: URL?) {
        guard let bytes = scheduleBookingSessionBytes(explicit: sessionBytes) else { return (nil, nil) }
        let service: NativePortalAdministrationService
        do {
            service = try portalService ?? NativePortalAdministrationService(
                endpoint: NativePortalAdministrationService.resolvedEndpoint()
            )
        } catch { return (nil, nil) }
        let displayToken = snapshot.payload.customers?.first(where: { $0.id == customerID })?.portal?.token
        guard let status = try? await service.status(customerId: customerID, token: displayToken, sessionBytes: bytes) else {
            return (nil, nil)
        }
        guard NativeScheduleBookingPolicy.mayAdoptPortalDisplayToken(displayToken: displayToken, status: status),
              let token = displayToken,
              let url = NativePortalAdministrationService.portalURL(token: token)
        else { return (status, nil) }
        return (status, url)
    }

    // MARK: Pending-work recovery and scrub

    /// Phase 12 (12.00b.2-I, P12-013): the owner binding pending-work
    /// recovery may run for, or nil. The same owner gate as widget/Siri
    /// replay (the exact signed-in workspace, the `.signedIn` gate, no
    /// account boundary open, pending or blocked), plus a committed initial
    /// sync for this subject (so request and job states are the pulled
    /// ones) and writable persistence.
    private var scheduleBookingRecoveryBinding: String? {
        guard let binding = widgetActionReplayBinding,
              binding == verifiedAccountBinding,
              let subject = authenticatedUserSubject,
              initialSyncCompletedSubject == subject,
              hasExactSignedInWorkspace,
              !persistenceWritesBlocked
        else { return nil }
        return binding
    }

    /// Phase 12 (12.00b.2-I fix round 1, review I1): the tables a booking or
    /// portal mirror merges into.
    private static let scheduleBookingMirrorTables: Set<String> = ["settings", "customers"]

    /// Phase 12 (12.00b.2-I fix round 1, review I1): records that a pull for
    /// `subject` committed the settings and customer tables (the initial
    /// sync, or a delta pull), so pending mirrors may be read and merged.
    /// Final review (M1): the mark carries the account generation the pull
    /// started under (as intake's does), so a pull that began before an
    /// account boundary never counts; and, as for intake, no pull marks while
    /// the gate waits for the owner or once the scene has entered the
    /// background since the pull began.
    private func markScheduleBookingRecoveryPullCommitted(subject: String, generation: UInt64, period: UInt64) {
        guard period == pullMarkPeriod, !Self.gateWaitsForOwner(authenticationGateState) else { return }
        scheduleBookingRecoveryPullMark = (generation, subject)
    }

    /// Whether such a pull has committed for the current owner and account
    /// generation since the identity was applied, the foreground refresh
    /// began, the scene entered the background or the gate waited for the
    /// owner.
    private var scheduleBookingRecoveryPullCommitted: Bool {
        guard let mark = scheduleBookingRecoveryPullMark else { return false }
        return mark.generation == accountBoundaryGeneration && mark.subject == authenticatedUserSubject
    }

    /// Phase 12 (12.00b.2-I, P12-013): launch. Called where the signed-in
    /// gate opens after the initial sync (the points that also replay
    /// widget actions). Starts a pass only when the owner has items, so a
    /// launch with nothing staged does no work. On a cold launch the initial
    /// sync's pull has committed, so the pass may merge mirrors; on a warm
    /// activation these points fire before the foreground pull, so the pass
    /// handles proofs and leaves mirrors to `performForegroundRefresh`.
    private func startScheduleBookingRecoveryIfPossible() {
        guard let binding = scheduleBookingRecoveryBinding,
              pendingScheduleBookingWorkStore().load().contains(where: { $0.ownerBinding == binding })
        else { return }
        Task { [weak self] in
            await self?.recoverScheduleBookingPendingWorkIfPossible()
        }
    }

    /// Phase 12 (12.00b.2-I, P12-013): activation (`performForegroundRefresh`)
    /// and launch. Recovers the verified owner's pending work, or does
    /// nothing while the gate is closed.
    @discardableResult
    func recoverScheduleBookingPendingWorkIfPossible() async -> PendingWorkRecovery? {
        guard let binding = scheduleBookingRecoveryBinding else { return nil }
        return await recoverScheduleBookingPendingWork(ownerBinding: binding)
    }

    /// Recovers owner-bound incomplete work after relaunch or failure.
    /// Items owned by another binding are left untouched here — scrubbing is
    /// an explicit account-boundary act.
    ///
    /// Phase 12 (12.00b.2-I, P12-013), replacing the uncalled synchronous
    /// pass:
    /// - It runs only for the gated owner (`scheduleBookingRecoveryBinding`)
    ///   and re-checks the account generation, the owner and the gate after
    ///   every `await`; on any change it stops and keeps what is left.
    /// - A mirror is read and merged only after a pull has committed since
    ///   the identity was applied or the foreground refresh began (fix round
    ///   1, review I1): the merge queues the whole settings or customer
    ///   record, and the push runs before the pull. Until then it waits.
    /// - A mirror is applied only after a fresh `status` read (contract §6)
    ///   says the token it would write is current: the staged token (mint,
    ///   rotate), or for a flag-only item (enable, disable) the local link's
    ///   token, which the merge writes back with the flag. The flag written
    ///   is the server's current one. A mirror the server no longer backs,
    ///   or with nothing to merge into, is removed without a write. It never
    ///   sends a mutation: an operation ID replays for 30 days only (§1.3),
    ///   and the server already holds the change.
    /// - A proof is kept only while a resolve can still succeed: its request
    ///   still asks for a reschedule and the job still has the proven
    ///   schedule. Recovery never resolves; the owner does (RN resolves only
    ///   on a tap, `utils/bookingRespond.ts:20-46`).
    /// - Writes follow the commit rule: save a copy, then apply, then queue.
    /// - One pass at a time; an item is removed by value, so an item staged
    ///   again meanwhile stays.
    /// - A pass with items logs one counts-only line (review M6).
    func recoverScheduleBookingPendingWork(ownerBinding: String) async -> PendingWorkRecovery {
        var recovery = PendingWorkRecovery()
        guard !scheduleBookingRecoveryInFlight,
              scheduleBookingRecoveryBinding == ownerBinding
        else { return recovery }
        scheduleBookingRecoveryInFlight = true
        defer { scheduleBookingRecoveryInFlight = false }
        let generation = accountBoundaryGeneration
        let capture = scheduleBookingOwnerCapture()
        let stillCurrent = { [unowned self] in
            accountBoundaryGeneration == generation
                && scheduleBookingOwnerStillCurrent(capture)
                && scheduleBookingRecoveryBinding == ownerBinding
        }
        let pullCommitted = { [unowned self] in scheduleBookingRecoveryPullCommitted }
        let store = pendingScheduleBookingWorkStore()
        let owned = store.load().filter { $0.ownerBinding == ownerBinding }
        var unfinished = 0
        defer {
            if !owned.isEmpty {
                let applied = recovery.reappliedMirrors + recovery.replayedBatches
                let dropped = recovery.droppedMirrors + recovery.proofsSuperseded.count + recovery.proofsClosed.count
                let kept = recovery.retained + recovery.proofsReady.count
                Self.stageLogger.notice(
                    "TradeReadyScheduleBookingRecovery stage=pass applied=\(applied, privacy: .public) dropped=\(dropped, privacy: .public) kept=\(kept, privacy: .public) stopped=\(unfinished, privacy: .public)"
                )
            }
        }
        for (index, item) in owned.enumerated() {
            guard stillCurrent() else {
                recovery.stoppedForAccountChange = true
                unfinished = owned.count - index
                return recovery
            }
            // Removed meanwhile (an admin action finished it): nothing to do.
            guard store.load().contains(item) else { continue }
            let step: PendingWorkStep
            switch item.kind {
            case let .bookingMirror(token, _, _, _):
                step = await recoverBookingMirror(token: token, stillCurrent: stillCurrent, pullCommitted: pullCommitted)
            case let .portalMirror(customerID, token, _, _):
                step = await recoverPortalMirror(
                    customerID: customerID, token: token, stillCurrent: stillCurrent, pullCommitted: pullCommitted
                )
            case let .rescheduleProof(requestID, proof, _):
                step = recoverRescheduleProof(requestID: requestID, proof: proof)
            case let .stagedBatch(drafts, _):
                step = replayStagedBatch(drafts)
            case let .adminOperation(target, action, enabled, operationId, stagedAt):
                // Retried only by the owner's Retry (the screen replays the
                // exact ID); the pass drops it once the server's replay row
                // can no longer exist.
                let plan = NativeScheduleBookingPolicy.planAdminOperation(
                    pending: .init(target: target, action: action, enabled: enabled,
                                   operationId: operationId, stagedAt: stagedAt),
                    action: action, enabled: enabled, proposedID: "", now: Date())
                if case .reuse = plan { step = .retained } else { step = .dropped }
            }
            switch step {
            case .applied:
                recovery.reappliedMirrors += 1
            case .replayed:
                recovery.replayedBatches += 1
            case .dropped:
                recovery.droppedMirrors += 1
            case let .proofReady(requestID):
                recovery.proofsReady.append(requestID)
            case let .proofSuperseded(requestID):
                recovery.proofsSuperseded.append(requestID)
            case let .proofClosed(requestID):
                recovery.proofsClosed.append(requestID)
            case .retained:
                recovery.retained += 1
            case .stopped:
                recovery.stoppedForAccountChange = true
                unfinished = owned.count - index
                return recovery
            }
            if step.removesItem {
                try? store.remove { $0 == item }
            }
        }
        return recovery
    }

    private enum PendingWorkStep {
        case applied, dropped, retained, stopped
        case replayed
        case proofReady(String), proofSuperseded(String), proofClosed(String)

        var removesItem: Bool {
            switch self {
            case .applied, .replayed, .dropped, .proofSuperseded, .proofClosed: return true
            case .retained, .stopped, .proofReady: return false
            }
        }
    }

    /// A booking-link mirror. A staged token (mint or rotate) is applied only
    /// if the server still reads it as current; a flag-only item (enable or
    /// disable) takes the server's current flag and needs an existing link
    /// (recovery never invents a token) that the server reads as current,
    /// because the merge writes that token back with the flag (fix round 1,
    /// review I1). Nothing is read or merged until a pull has committed.
    private func recoverBookingMirror(
        token: String?,
        stillCurrent: () -> Bool,
        pullCommitted: () -> Bool
    ) async -> PendingWorkStep {
        guard !bookingAdminInFlight else { return .retained }
        if let token, !NativeBookingAdministrationService.isValidCapabilityToken(token) { return .dropped }
        guard let readToken = token ?? snapshot.payload.settings?.bookingLink?.token,
              NativeBookingAdministrationService.isValidDisplayToken(readToken)
        else { return .dropped }
        guard pullCommitted() else { return .retained }
        guard let bytes = scheduleBookingSessionBytes(explicit: nil),
              let service = scheduleBookingRecoveryAdminService
                ?? (try? NativeBookingAdministrationService(endpoint: NativeBookingAdministrationService.resolvedEndpoint()))
        else { return .retained }
        let wired = NativeBookingAdministrationService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        bookingAdminInFlight = true
        defer { bookingAdminInFlight = false }
        let status: NativeBookingLinkStatus
        do {
            status = try await wired.status(token: readToken, sessionBytes: bytes)
        } catch {
            return stillCurrent() ? .retained : .stopped
        }
        guard stillCurrent() else { return .stopped }
        guard pullCommitted() else { return .retained }
        // Not current: a later change replaced it. Nothing is written; the
        // pull brings the current link once that change's own save lands.
        guard status.tokenValid else { return .dropped }
        if token == nil {
            // The flag-only merge writes back the local token: it must still
            // be the one just confirmed. Replaced meanwhile: the next pass.
            guard let local = snapshot.payload.settings?.bookingLink?.token else { return .dropped }
            guard local == readToken else { return .retained }
        }
        return mergeBookingDisplayMirrorForRecovery(token: token, enabled: status.enabled) ? .applied : .retained
    }

    /// A portal-link mirror, with the same rules per customer. A customer no
    /// longer on the device, or one the server does not know, is dropped.
    private func recoverPortalMirror(
        customerID: String,
        token: String?,
        stillCurrent: () -> Bool,
        pullCommitted: () -> Bool
    ) async -> PendingWorkStep {
        guard !portalAdminInFlight.contains(customerID) else { return .retained }
        if let token, !NativePortalAdministrationService.isValidCapabilityToken(token) { return .dropped }
        guard let customer = snapshot.payload.customers?.first(where: { $0.id == customerID }) else { return .dropped }
        guard let readToken = token ?? customer.portal?.token,
              NativePortalAdministrationService.isValidDisplayToken(readToken)
        else { return .dropped }
        guard pullCommitted() else { return .retained }
        guard let bytes = scheduleBookingSessionBytes(explicit: nil),
              let service = scheduleBookingRecoveryPortalService
                ?? (try? NativePortalAdministrationService(endpoint: NativePortalAdministrationService.resolvedEndpoint()))
        else { return .retained }
        let wired = NativePortalAdministrationService(
            endpoint: service.endpoint,
            loader: service.loader,
            refreshSession: { [weak self] in await self?.scheduleBookingRefreshedSession(excluding: bytes) }
        )
        portalAdminInFlight.insert(customerID)
        defer { portalAdminInFlight.remove(customerID) }
        let status: NativePortalLinkStatus
        do {
            status = try await wired.status(customerId: customerID, token: readToken, sessionBytes: bytes)
        } catch NativePortalAdminError.notFound {
            return stillCurrent() ? .dropped : .stopped
        } catch {
            return stillCurrent() ? .retained : .stopped
        }
        guard stillCurrent() else { return .stopped }
        guard pullCommitted() else { return .retained }
        guard status.tokenValid,
              let current = snapshot.payload.customers?.first(where: { $0.id == customerID })
        else { return .dropped }
        if token == nil {
            guard let local = current.portal?.token else { return .dropped }
            guard local == readToken else { return .retained }
        }
        return mergePortalDisplayFields(customerID: customerID, token: token, enabled: status.enabled, automatic: true)
            ? .applied : .retained
    }

    /// P12-028: a staged record batch from a local commit whose queue write
    /// did not finish. Needs no pull and no network: it reads the device's own
    /// records and queue. Drafts whose record changed or vanished since, or
    /// that the queue already holds, are not queued (see
    /// `stagedDraftsToReplay`). The item is removed only after the queue
    /// accepted what remained; a queue that still cannot be written keeps it.
    private func replayStagedBatch(_ staged: [NativeScheduleBookingStagedDraft]) -> PendingWorkStep {
        let payloads = currentRecordPayloads()
        let drafts = NativeScheduleBookingPolicy.stagedDraftsToReplay(
            staged,
            currentPayload: { table, id in payloads[table]?[id] },
            queued: mutationQueue.load()
        )
        if !drafts.isEmpty {
            do { try mutationQueue.enqueueBatch(drafts) } catch {
                recordLocalSyncFailure("recovery/queue")
                return .retained
            }
            scheduleSyncAfterLocalChange()
        }
        return .replayed
    }

    /// The canonical upsert payload of each record a staged batch can name,
    /// keyed by table and id.
    private func currentRecordPayloads() -> [String: [String: Canonical.JSONValue]] {
        func payloads<Record: Encodable>(_ table: String, _ records: [Record]?, id: (Record) -> String)
            -> [String: Canonical.JSONValue] {
            var out: [String: Canonical.JSONValue] = [:]
            for record in records ?? [] {
                if let payload = NativeScheduleBookingPolicy.mutationDraft(table: table, id: id(record), record: record).payload {
                    out[id(record)] = payload
                }
            }
            return out
        }
        return [
            "jobs": payloads("jobs", snapshot.payload.jobs, id: { $0.id }),
            "customers": payloads("customers", snapshot.payload.customers, id: { $0.id }),
            "bookingRequests": payloads("bookingRequests", snapshot.payload.bookingRequests, id: { $0.id }),
        ]
    }

    /// A reschedule proof, from local state only. At the foreground refresh
    /// the pull has just committed; at a gate site (identity apply, the
    /// subscription or starting-point exit) the pass runs before that
    /// activation's pull, which is safe because a proof check writes no
    /// record and queues nothing (playbook §5.1). The server resolves only
    /// from `reschedule_requested` (`backend-workers/lib/booking/respond.js`
    /// TRANSITIONS) and only while
    /// the job has the proven schedule, so any other state is terminal:
    /// `.missing`, `needsReview` after another device declined or confirmed,
    /// a committed unknown outcome once the pull shows `confirmed`, and a
    /// decline after `awaitingAck`. A proof that can still succeed stays for
    /// the owner's retry (`unknownOutcome` not committed, `failed`); the
    /// store holds one per request.
    private func recoverRescheduleProof(requestID: String, proof: NativeScheduleProof) -> PendingWorkStep {
        let request = snapshot.payload.bookingRequests?.first(where: { $0.id == requestID })
        guard request?.status == "reschedule_requested" else { return .proofClosed(requestID) }
        let job = snapshot.payload.jobs?.first(where: { $0.id == proof.jobId })
        guard NativeScheduleBookingPolicy.proofMatchesCurrentJob(proof, job: job) else {
            return .proofSuperseded(requestID)
        }
        let acked = !mutationQueue.load().contains {
            $0.table == "jobs" && $0.recordId == proof.jobId
        }
        return acked ? .proofReady(requestID) : .retained
    }

    /// The bounded code a recovery pass records when its local save fails
    /// (final review M5); the item stays for the next pass.
    private static let recoveryLocalCommitCode = "recovery/local-commit"

    private func mergeBookingDisplayMirrorForRecovery(token: String?, enabled: Bool) -> Bool {
        guard ensurePersistenceWritable(),
              var settings = snapshot.payload.settings
        else { return false }
        // Recovery never invents a token: a nil-token mirror with no
        // existing link fails closed (the recovery pass drops that item
        // before it reads status).
        do {
            settings = try NativeBookingAdminMirror.apply(to: settings, token: token, enabled: enabled)
        } catch {
            return false
        }
        var updated = snapshot
        updated.payload.settings = settings
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            // Final review M5: as the portal merge, a bounded code only.
            recordLocalSyncFailure(Self.recoveryLocalCommitCode)
            return false
        }
        enqueueSettingsUpsert(settings)
        return true
    }

    /// Scrubs exactly one binding's pending capability work. Called on the
    /// account boundary so a stale response or proof can never act for
    /// another account.
    func scrubScheduleBookingPendingWork(binding: String) {
        try? pendingScheduleBookingWorkStore().scrubOwnerBoundWork(binding: binding)
    }

    // MARK: - Phase 9 money records (task 9.08)

    private static let tripIDGenerator = LocalIDGenerator()
    private static let importBatchIDGenerator = LocalIDGenerator()
    /// `new Date().toISOString()` shape for canonical timestamp fields.
    private static let canonicalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Device-local, unsynced import history lives beside the snapshot, exactly
    /// like the other device-local stores (dismissals, review requests).
    private var importHistoryDirectory: URL { fileURL.deletingLastPathComponent() }

    /// Removes the import-history file. History is per-device operational
    /// metadata (report history and the same-file re-import warning); the account
    /// boundary must not let one account's import report surface under the next.
    private func removeImportHistory() throws {
        let url = importHistoryDirectory.appendingPathComponent(NativeImportHistory.storageKey)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Expenses (E1)

    /// Typed, ID-scoped expense commit — create when `id` is nil, edit otherwise.
    ///
    /// The editor owns its scalar fields plus the optional job link and receipt
    /// reference. `createdAt`, `importBatchId` and any unknown/forward-compatible
    /// fields come from the LATEST canonical baseline, so a concurrent refresh,
    /// webhook, or sync pull touching the same record is merged rather than
    /// overwritten. When `opened` is supplied and another device has moved one of
    /// the editor-owned scalars, the write fails closed and the caller keeps the
    /// draft visible. Success is reported only after the durable write and
    /// projection; the wire upsert is enqueued last and a queue failure never
    /// rolls back the local save.
    func commitExpenseEdit(
        id: String?,
        opened: Expense?,
        draft: Expense,
        calendar: Calendar = .current
    ) -> Result<Expense, NativeMoneyRecordRefusal> {
        let result = performExpenseEdit(id: id, opened: opened, draft: draft, calendar: calendar)
        // Task 11.08: RN `useMoneyData.ts:84` / `JobProfitabilitySection.tsx:110`,
        // new expenses only.
        if case .success(let saved) = result, id == nil {
            emitAnalytics(.expenseLogged(category: saved.category, linkedToJob: saved.jobId != nil))
        }
        return result
    }

    private func performExpenseEdit(
        id: String?,
        opened: Expense?,
        draft: Expense,
        calendar: Calendar
    ) -> Result<Expense, NativeMoneyRecordRefusal> {
        guard ensurePersistenceWritable() else { return .failure(.persistenceUnavailable) }
        var records = snapshot.payload.expenses ?? []
        if let id {
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return .failure(.missingRecord)
            }
            let baseline = records[index]
            guard let current = try? CanonicalUIAdapters.expense(from: baseline, calendar: calendar) else {
                return .failure(.persistenceUnavailable)
            }
            if let opened,
               Self.expenseEditorScalarsChanged(between: opened, and: current) {
                return .failure(.staleEditorCopy)
            }
            do {
                var edit = try CanonicalUIAdapters.edit(baseline, calendar: calendar)
                var value = draft
                value.id = baseline.id
                edit.value = value
                let result = try CanonicalUIAdapters.canonical(from: edit)
                records[index] = result
                var updated = snapshot
                updated.payload.expenses = records
                try repository.save(updated)
                try apply(updated)
                enqueueUpsert(table: "expenses", recordId: result.id, record: result)
                guard let published = try? CanonicalUIAdapters.expense(from: result, calendar: calendar) else {
                    return .failure(.persistenceUnavailable)
                }
                return .success(published)
            } catch {
                migrationMessage = "Could not update expense: \(error.localizedDescription)"
                return .failure(.persistenceUnavailable)
            }
        }
        guard !records.contains(where: { $0.id == draft.id }) else { return .failure(.conflictingRecord) }
        do {
            let result = try CanonicalUIAdapters.canonical(from: draft, calendar: calendar)
            // A new expense is prepended, matching the RN money hook's ordering.
            records.insert(result, at: 0)
            var updated = snapshot
            updated.payload.expenses = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "expenses", recordId: result.id, record: result)
            guard let published = try? CanonicalUIAdapters.expense(from: result, calendar: calendar) else {
                return .failure(.persistenceUnavailable)
            }
            return .success(published)
        } catch {
            migrationMessage = "Could not save expense: \(error.localizedDescription)"
            return .failure(.persistenceUnavailable)
        }
    }

    /// Deletes one expense by exact id. Reports whether a record was removed so
    /// the caller can offer an undo; the durable local removal happens before the
    /// queue delete, so a queue failure never resurrects the record.
    @discardableResult
    func deleteExpenseRecord(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        var records = snapshot.payload.expenses ?? []
        guard records.contains(where: { $0.id == id }) else { return false }
        records.removeAll { $0.id == id }
        var updated = snapshot
        updated.payload.expenses = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Could not delete expense: \(error.localizedDescription)"
            return false
        }
        enqueueDelete(table: "expenses", recordId: id)
        return true
    }

    /// Editor-owned scalar drift check. `importBatchId` is provenance, not
    /// editor state, so it is deliberately excluded.
    private static func expenseEditorScalarsChanged(
        between opened: Expense,
        and current: Expense
    ) -> Bool {
        opened.merchant != current.merchant
            || opened.amount != current.amount
            || opened.category != current.category
            || NativeCashBasis.ymd(opened.date) != NativeCashBasis.ymd(current.date)
            || opened.notes != current.notes
            || opened.jobId != current.jobId
            || opened.receiptUri != current.receiptUri
    }

    // MARK: Receipts (E2, task 9.10)

    /// Normalizes picked/captured bytes to the OCR contract and writes them at
    /// the deterministic `<media-root>/receipts/<id>.jpg`, returning the local
    /// reference the expense should carry. Existing bytes win, so a repeated
    /// attach (or a legacy adoption pass) can never overwrite the user's photo.
    /// Returns nil — nothing written, nothing referenced — when the image cannot
    /// be brought under the contract.
    func persistReceipt(sourceData: Data, on date: Date = .now) -> String? {
        guard ensurePersistenceWritable() else { return nil }
        guard let jpeg = NativeReceiptMedia.normalizedJPEGBytes(from: sourceData) else {
            migrationMessage = "That image couldn't be used for a receipt."
            return nil
        }
        let receiptID = NativeReceiptMedia.makeReceiptID(now: date)
        do {
            _ = try NativeReceiptMedia.installBytes(
                jpeg, root: repository.liveMediaDirectoryURL, receiptID: receiptID
            )
            return try NativeReceiptMedia.receiptURL(
                root: repository.liveMediaDirectoryURL, receiptID: receiptID
            ).absoluteString
        } catch {
            migrationMessage = "The receipt could not be saved."
            return nil
        }
    }

    // MARK: Business logo

    /// Stores a picked or captured image as the business logo, like RN's
    /// `promptForLogo`: capped at 512px, written as PNG under `logos/`, and the
    /// local reference saved in `settings.logoPhoto` (which syncs as part of the
    /// settings blob; the bytes stay on this device). The previous logo file is
    /// removed only after the new reference is saved, and the new file is removed
    /// again if the save fails, so a failed pick changes nothing.
    @discardableResult
    func setBusinessLogo(sourceData: Data) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        guard let png = NativeLogoMedia.normalizedPNGBytes(from: sourceData) else {
            migrationMessage = "That image couldn't be used as a logo."
            return false
        }
        let root = repository.liveMediaDirectoryURL
        let reference: String
        do {
            let logoID = NativeLogoMedia.makeLogoID()
            _ = try NativeLogoMedia.installBytes(png, root: root, logoID: logoID)
            reference = try NativeLogoMedia.logoURL(root: root, logoID: logoID).absoluteString
        } catch {
            migrationMessage = "The logo could not be saved."
            return false
        }
        let previous = settings.logoPhoto
        settings.logoPhoto = reference
        guard settingsSaveFailure == nil, settings.logoPhoto == reference else {
            NativeLogoMedia.removeFile(reference: reference, root: root)
            return false
        }
        NativeLogoMedia.removeFile(reference: previous, root: root)
        return true
    }

    /// Clears the logo reference and, once that is saved, the file it named.
    func removeBusinessLogo() {
        let previous = settings.logoPhoto
        guard !previous.isEmpty else { return }
        settings.logoPhoto = ""
        guard settingsSaveFailure == nil, settings.logoPhoto.isEmpty else { return }
        NativeLogoMedia.removeFile(reference: previous, root: repository.liveMediaDirectoryURL)
    }

    /// The `data:` URI for an already-stored receipt. Accepts both the native
    /// `file://` reference and a bare path (a legacy record can carry either) and
    /// returns nil when the bytes are unreadable — the scan then says so instead
    /// of failing silently.
    func receiptDataUri(receiptUri: String) -> String? {
        guard !receiptUri.isEmpty else { return nil }
        let url: URL
        if let parsed = URL(string: receiptUri), parsed.isFileURL {
            url = parsed
        } else {
            url = URL(fileURLWithPath: receiptUri)
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return nil
        }
        let ext = url.pathExtension.lowercased()
        let mediaType = ext == "png" ? "image/png" : "image/jpeg"
        return "data:\(mediaType);base64,\(data.base64EncodedString())"
    }

    /// The user's own Anthropic key, read from the secure store (never from the
    /// business snapshot). Nil means "no client key" — the transport then takes
    /// the backend bearer path.
    /// Final review 1b: nil while a boundary wipe is pending, so the next
    /// owner's coach never uses the previous owner's key.
    /// Phase 12 (L286.5b review I1): and nil unless the key was saved by the
    /// verified owner (`NativeAIProviderKeyOwnerTag`), so a key whose wipe and
    /// pending state were both lost is still never read for another owner.
    var advisoryAnthropicKey: String? {
        isBoundaryStepPending(.aiKeyWipe) ? nil : secureSettingsStore.readAIProviderKey(.anthropic, ownerBinding: verifiedAccountBinding)
    }

    /// The user's own Groq key, read from the secure store — mirrors
    /// `advisoryAnthropicKey` exactly (task 10.13, coach provider routing).
    var advisoryGroqKey: String? {
        isBoundaryStepPending(.aiKeyWipe) ? nil : secureSettingsStore.readAIProviderKey(.groq, ownerBinding: verifiedAccountBinding)
    }

    // MARK: AI provider key entry (task 11.15)

    /// Settings › AI Assistant: whether a key is saved (the page shows only
    /// "Saved", never the key).
    func aiProviderKeyIsSaved(_ kind: NativeAIProviderKeyKind) -> Bool {
        !isBoundaryStepPending(.aiKeyWipe)
            && secureSettingsStore.readAIProviderKey(kind, ownerBinding: verifiedAccountBinding) != nil
    }

    /// The status row's state; a Keychain read error is `.unreadable`.
    ///
    /// Phase 12 (L286.5a): while the account-boundary wipe is pending, the key
    /// in the Keychain may be the previous owner's, so the row reads "Not set"
    /// without reading it — what it reads once the wipe completes, and what a
    /// kind the previous owner never saved reads — and offers no Remove. That
    /// matches the closed change gate (`canChangeAIProviderKeys`) and the
    /// coach, which already treats both keys as absent (`advisory*Key`).
    /// Review I1: another owner's key, or an untagged one, reads "Not set" too.
    func aiProviderKeyState(_ kind: NativeAIProviderKeyKind) -> NativeAIProviderKeyPolicy.SavedState {
        isBoundaryStepPending(.aiKeyWipe)
            ? .notSet
            : secureSettingsStore.aiProviderKeyState(kind, ownerBinding: verifiedAccountBinding)
    }

    /// Saves (or, for an empty entry, clears) a user key in the secure store
    /// the coach reads. The page, `coachProviderSummary` and the next coach
    /// send all follow at once. Policy: `NativeAIProviderKeyPolicy`.
    func setAIProviderKey(_ kind: NativeAIProviderKeyKind, entry: String) -> NativeAIProviderKeyChange {
        applyAIProviderKey(NativeAIProviderKeyPolicy.outcome(for: entry, kind: kind, canChange: canChangeAIProviderKeys), kind: kind)
    }

    /// The explicit Remove action.
    func clearAIProviderKey(_ kind: NativeAIProviderKeyKind) -> NativeAIProviderKeyChange {
        applyAIProviderKey(NativeAIProviderKeyPolicy.clearOutcome(canChange: canChangeAIProviderKeys), kind: kind)
    }

    /// Keys are owner-bound: they change only for a signed-in owner and never
    /// while an account boundary (sign-out, deletion, scrub, account switch)
    /// is running or its AI-key wipe is still pending a retry, so a write
    /// cannot land after — or be wiped by the retry of — the boundary's wipe.
    /// Review I1: a save is tagged with the verified owner, so one is required.
    private var canChangeAIProviderKeys: Bool {
        isSignedIn && verifiedAccountBinding != nil
            && !authenticationOperationInFlight && !accountSwitchInFlight
            && !isAccountScrubBlocked && !repository.isAccountScrubPending
            && !isBoundaryStepPending(.aiKeyWipe)
    }

    /// Task 11.15 fix round 1: removes both provider keys (entered or migrated)
    /// from the injected secure store at an account boundary that does not run
    /// the full scrub (account switch, password-recovery exits). Each account
    /// is removed independently with a verified remove, and every account is
    /// attempted even when one fails. Phase 12 (L205.e): the migrated legacy
    /// `providerKey`/`geminiKey` fields are removed the same way.
    ///
    /// Final review 1b: a failure is not fatal to the boundary, but it is not
    /// silent either. The wipe runs under the durable `.aiKeyWipe` marker, so
    /// a failure leaves it pending: the coach reads no client key
    /// (`advisory*Key`) and no key can be saved (`canChangeAIProviderKeys`)
    /// until a retry succeeds — at launch, before an interactive sign-in, from
    /// `retryAccountScrub`, or the switch's own second wipe. The failure is
    /// counted and logged without key material or account.
    private func wipeAIProviderKeysForAccountBoundary() {
        do {
            try runDurableBoundaryStep(.aiKeyWipe) {
                var firstFailure: Error?
                for account in NativeKeychainSecureSettingsStore.accountBoundaryAIKeyAccounts {
                    do { try secureSettingsStore.clearAccountBoundaryAIKey(account: account) } catch {
                        firstFailure = firstFailure ?? error
                    }
                }
                if let firstFailure { throw firstFailure }
            }
        } catch {
            aiProviderKeyWipeFailureCount = min(Self.aiProviderKeyWipeFailureCap, aiProviderKeyWipeFailureCount + 1)
            print("TradeReadyAIProviderKey stage=boundary-wipe")
        }
        objectWillChange.send()
    }

    private func applyAIProviderKey(
        _ outcome: NativeAIProviderKeyPolicy.Outcome,
        kind: NativeAIProviderKeyKind
    ) -> NativeAIProviderKeyChange {
        let store = secureSettingsStore
        let ownerBinding = verifiedAccountBinding
        let change = NativeAIProviderKeyPolicy.apply(
            outcome,
            kind: kind,
            save: {
                // `canChangeAIProviderKeys` already required the owner.
                guard let ownerBinding else { throw NativeSecureSettingsStoreError.unavailable }
                try store.saveAIProviderKey($0, kind: kind, ownerBinding: ownerBinding)
            },
            clear: { try store.clearAIProviderKey(kind) }
        )
        // `coachProviderSummary` and `aiProviderKeyIsSaved` read the store.
        objectWillChange.send()
        return change
    }

    /// Advisory receipt extraction. NEVER throws and never writes: nil means the
    /// editor keeps manual entry untouched. The blocking transport call runs off
    /// the main actor so a slow network cannot freeze the sheet.
    func scanReceipt(receiptUri: String) async -> NativeReceiptScanResult? {
        guard let dataUri = receiptDataUri(receiptUri: receiptUri) else { return nil }
        let transport = advisoryAITransport
        let anthropicKey = advisoryAnthropicKey
        return await Task.detached(priority: .userInitiated) {
            NativeReceiptOCR.extractReceipt(
                dataUri: dataUri, anthropicKey: anthropicKey, transport: transport
            )
        }.value
    }

    /// The UI projection for one expense, used as the editor's stale-copy
    /// baseline (`opened`) when editing an existing record.
    func expenseRecord(id: String) -> Expense? {
        guard let record = canonicalExpenses.first(where: { $0.id == id }) else { return nil }
        return try? CanonicalUIAdapters.expense(from: record)
    }

    /// The configured minimum job fee, shared by the pricing engine, the
    /// pricebook estimate total, and the pricing calculator.
    var minimumJobFee: Decimal { snapshot.payload.settings?.minimumJobFee ?? 75 }

    /// Advisory pricebook suggestion (P4). NEVER throws and never writes: nil is
    /// the typed "no suggestion" the panel shows as unavailable. The blocking
    /// transport call runs off the main actor.
    func pricebookSuggestion(_ input: NativePricebookAIInput) async -> NativeAIPricingSuggestion? {
        let transport = advisoryAITransport
        let anthropicKey = advisoryAnthropicKey
        let backendAvailable = BuildEnvironment.backendBaseURL != nil
        return await Task.detached(priority: .userInitiated) {
            NativePricebookAI.suggestion(
                input,
                anthropicKey: anthropicKey,
                backendAvailable: backendAvailable,
                transport: transport
            )
        }.value
    }

    // MARK: Mileage (T1)

    /// Typed, ID-scoped trip commit. Validation, miles math, and the owned-field
    /// projection come from `NativeMileage`; editing preserves the original
    /// `createdAt` and every unknown field on the baseline record. A new trip is
    /// prepended, matching the RN log's ordering.
    func commitTripEdit(
        id: String?,
        opened: Canonical.Trip?,
        draft: NativeTripDraft,
        now: Date = Date()
    ) -> Result<Canonical.Trip, NativeMoneyRecordRefusal> {
        let result = performTripEdit(id: id, opened: opened, draft: draft, now: now)
        // Task 11.08: RN `AddTripScreen.tsx:115` tracks create and edit alike.
        if case .success = result { emitAnalytics(.tripLogged) }
        return result
    }

    private func performTripEdit(
        id: String?,
        opened: Canonical.Trip?,
        draft: NativeTripDraft,
        now: Date
    ) -> Result<Canonical.Trip, NativeMoneyRecordRefusal> {
        guard ensurePersistenceWritable() else { return .failure(.persistenceUnavailable) }
        if let validation = NativeMileage.validationError(draft) {
            return .failure(.invalidDraft(Self.tripValidationMessage(validation)))
        }
        var records = snapshot.payload.trips ?? []
        do {
            let record: Canonical.Trip
            if let id {
                guard let index = records.firstIndex(where: { $0.id == id }) else {
                    return .failure(.missingRecord)
                }
                let baseline = records[index]
                if let opened, Self.tripEditorScalarsChanged(between: opened, and: baseline) {
                    return .failure(.staleEditorCopy)
                }
                let projected = NativeMileage.projectedFields(
                    draft: draft, existing: baseline, tripID: baseline.id, createdAt: baseline.createdAt
                )
                // Apply the owned fields OVER the baseline's field bag so unknown
                // and forward-compatible fields survive an edit.
                var fields = NativeImportEngine.fields(baseline)
                for (key, value) in projected { fields[key] = value }
                guard let applied = NativeImportEngine.decode(Canonical.Trip.self, fields) else {
                    return .failure(.persistenceUnavailable)
                }
                record = applied
                records[index] = record
            } else {
                let projected = NativeMileage.projectedFields(
                    draft: draft,
                    existing: nil,
                    tripID: Self.tripIDGenerator.tripID(),
                    createdAt: Self.canonicalTimestampFormatter.string(from: now)
                )
                guard let created = NativeImportEngine.decode(Canonical.Trip.self, projected) else {
                    return .failure(.persistenceUnavailable)
                }
                record = created
                records.insert(record, at: 0)
            }
            var updated = snapshot
            updated.payload.trips = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "trips", recordId: record.id, record: record)
            return .success(record)
        } catch {
            migrationMessage = "Could not save trip: \(error.localizedDescription)"
            return .failure(.persistenceUnavailable)
        }
    }

    /// Removes one trip by exact id; the queue delete follows the local write.
    @discardableResult
    func deleteTripRecord(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        var records = snapshot.payload.trips ?? []
        guard records.contains(where: { $0.id == id }) else { return false }
        records.removeAll { $0.id == id }
        var updated = snapshot
        updated.payload.trips = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Could not delete trip: \(error.localizedDescription)"
            return false
        }
        enqueueDelete(table: "trips", recordId: id)
        return true
    }

    private static func tripEditorScalarsChanged(
        between opened: Canonical.Trip,
        and current: Canonical.Trip
    ) -> Bool {
        opened.date != current.date
            || opened.odometerStart != current.odometerStart
            || opened.odometerEnd != current.odometerEnd
            || opened.fromJobId != current.fromJobId
            || opened.fromLabel != current.fromLabel
            || opened.toJobId != current.toJobId
            || opened.toLabel != current.toLabel
            || opened.purpose != current.purpose
    }

    /// RN alert copy from `screens/AddTripScreen.tsx`.
    private static func tripValidationMessage(_ error: NativeTripValidationError) -> String {
        switch error {
        case .invalidDate: "Enter the trip date as YYYY-MM-DD."
        case .missingReadings: "Enter both start and end odometer readings."
        case .endBeforeStart: "End reading must be greater than or equal to the start reading."
        }
    }

    // MARK: Pricebook (P1, P3)

    /// Typed, ID-scoped pricebook commit. Create stamps `createdAt`/`updatedAt`;
    /// edit preserves `createdAt` and every unknown/nested field on the baseline
    /// record. The stored `estimateTotal` is always the shared pricing engine's
    /// output for the draft, never a hand-rolled sum.
    func commitPricebookEdit(
        id: String?,
        opened: Canonical.PricebookEntry?,
        draft: NativePricebookEntryDraft,
        now: Date = Date()
    ) -> Result<Canonical.PricebookEntry, NativeMoneyRecordRefusal> {
        let result = performPricebookEdit(id: id, opened: opened, draft: draft, now: now)
        // Task 11.08: RN `PricebookEntryScreen.tsx:171`, after the save.
        if case .success = result { emitAnalytics(.pricebookEntrySaved) }
        return result
    }

    private func performPricebookEdit(
        id: String?,
        opened: Canonical.PricebookEntry?,
        draft: NativePricebookEntryDraft,
        now: Date
    ) -> Result<Canonical.PricebookEntry, NativeMoneyRecordRefusal> {
        guard ensurePersistenceWritable() else { return .failure(.persistenceUnavailable) }
        var normalized = draft
        normalized.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.name.isEmpty else {
            return .failure(.invalidDraft("Give this service a name so you can find it later."))
        }
        let minimumJobFee = snapshot.payload.settings?.minimumJobFee ?? 75
        let timestamp = Self.canonicalTimestampFormatter.string(from: now)
        var records = snapshot.payload.pricebook ?? []
        do {
            let record: Canonical.PricebookEntry
            if let id {
                guard let index = records.firstIndex(where: { $0.id == id }) else {
                    return .failure(.missingRecord)
                }
                let baseline = records[index]
                if let opened,
                   Self.pricebookEditorScalarsChanged(between: opened, and: baseline, minimumJobFee: minimumJobFee) {
                    return .failure(.staleEditorCopy)
                }
                let fields = NativePricebook.appliedFields(
                    draft: normalized,
                    to: NativePricebook.fields(baseline),
                    now: timestamp,
                    minimumJobFee: minimumJobFee
                )
                guard let applied = NativePricebook.decode(Canonical.PricebookEntry.self, fields) else {
                    return .failure(.persistenceUnavailable)
                }
                record = applied
                records[index] = record
            } else {
                let identifier = "pb-\(Int64(now.timeIntervalSince1970 * 1000))"
                guard !records.contains(where: { $0.id == identifier }) else {
                    return .failure(.conflictingRecord)
                }
                let fields = NativePricebook.createFields(
                    draft: normalized, id: identifier, now: timestamp, minimumJobFee: minimumJobFee
                )
                guard let created = NativePricebook.decode(Canonical.PricebookEntry.self, fields) else {
                    return .failure(.persistenceUnavailable)
                }
                record = created
                records.append(record)
            }
            var updated = snapshot
            updated.payload.pricebook = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "pricebook", recordId: record.id, record: record)
            return .success(record)
        } catch {
            migrationMessage = "Could not save pricebook entry: \(error.localizedDescription)"
            return .failure(.persistenceUnavailable)
        }
    }

    /// Deletes one pricebook entry by exact id; the queue delete follows the
    /// durable local removal.
    @discardableResult
    func deletePricebookEntry(id: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        let records = snapshot.payload.pricebook ?? []
        guard records.contains(where: { $0.id == id }) else { return false }
        var updated = snapshot
        updated.payload.pricebook = NativePricebook.delete(records, id: id)
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Could not delete pricebook entry: \(error.localizedDescription)"
            return false
        }
        enqueueDelete(table: "pricebook", recordId: id)
        return true
    }

    /// Editor-owned drift check over the pricing inputs the entry sheet can
    /// change (`createdAt`/`updatedAt` and unknowns are excluded).
    private static func pricebookEditorScalarsChanged(
        between opened: Canonical.PricebookEntry,
        and current: Canonical.PricebookEntry,
        minimumJobFee: Decimal
    ) -> Bool {
        ownedPricebookFields(opened, minimumJobFee: minimumJobFee)
            != ownedPricebookFields(current, minimumJobFee: minimumJobFee)
    }

    private static func ownedPricebookFields(
        _ entry: Canonical.PricebookEntry,
        minimumJobFee: Decimal
    ) -> [String: Canonical.JSONValue] {
        var fields = NativePricebook.createFields(
            draft: NativePricebook.jobPrefill(from: entry),
            id: entry.id,
            now: "",
            minimumJobFee: minimumJobFee
        )
        fields["id"] = nil
        fields["createdAt"] = nil
        fields["updatedAt"] = nil
        return fields
    }

    // MARK: Tax set-aside settings (T2)

    /// Writes ONLY the two tax settings fields onto the latest canonical settings
    /// record. A nil draft field means "leave unchanged" (the RN sheet merges
    /// `{ ...full, ...draft }`), so an unset field may stay absent — it is never
    /// coerced to a value or an explicit null. Reports success only after the
    /// durable write; the (credential-scrubbed) settings upsert is enqueued last.
    @discardableResult
    func commitTaxSettings(_ draft: NativeTaxSettingsDraft) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        // An unset draft is the sheet's "nothing changed" case: it writes no
        // field and therefore publishes nothing (no queue churn, no revision).
        // RN still saves and tracks it, so the event fires here too.
        guard draft.taxIncomeRate != nil || draft.vehicleDeductionMethod != nil else {
            emitTaxSettingsSaved(draft)
            return true
        }
        guard let canonical = snapshot.payload.settings else { return false }
        let fields = NativeTaxSettings.applying(draft, to: NativeImportEngine.fields(canonical))
        guard let merged = NativeImportEngine.decode(Canonical.Settings.self, fields) else { return false }
        var updated = snapshot
        updated.payload.settings = merged
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Could not update settings: \(error.localizedDescription)"
            return false
        }
        enqueueSettingsUpsert(merged)
        emitTaxSettingsSaved(draft)
        return true
    }

    /// RN `TaxSetAsideCard.tsx:61`, after `saveSettings`.
    private func emitTaxSettingsSaved(_ draft: NativeTaxSettingsDraft) {
        emitAnalytics(.taxSettingsSaved(
            hasIncomeRate: draft.taxIncomeRate != nil,
            vehicleMethod: draft.vehicleDeductionMethod
        ))
    }

    /// The canonical tax-settings values the estimator consumes.
    var taxSettingsValues: NativeTaxSettingsValues {
        snapshot.payload.settings.map(NativeTaxSettingsValues.init(from:)) ?? NativeTaxSettingsValues()
    }

    /// The tax settings sheet's seed (12.00b.3, G2), read fresh each time the
    /// Money tax card opens it (RN `TaxSettingsModal.tsx:55-63`). It keeps the
    /// stored method string as-is, which `taxSettingsValues` cannot.
    var taxSettingsEditor: NativeTaxSettingsEditor {
        NativeTaxSettingsEditor(settings: snapshot.payload.settings)
    }

    /// Canonical reads for the Money reports (task 9.09). The report engine runs
    /// on canonical records, never on the screen projections, so no figure is
    /// re-derived from a lossy UI type.
    var canonicalCustomers: [Canonical.Customer] { snapshot.payload.customers ?? [] }
    var canonicalJobs: [Canonical.Job] { snapshot.payload.jobs ?? [] }
    var canonicalInvoices: [Canonical.Invoice] { snapshot.payload.invoices ?? [] }
    var canonicalExpenses: [Canonical.Expense] { snapshot.payload.expenses ?? [] }
    var canonicalTrips: [Canonical.Trip] { snapshot.payload.trips ?? [] }
    var canonicalPricebook: [Canonical.PricebookEntry] { snapshot.payload.pricebook ?? [] }

    // MARK: - Today screen (task 10.11, requirements D1, D2, D3, D6)
    //
    // Thin pass-through wiring over the pure 10.04 projection
    // (`NativeTodayBriefing`) and the existing Phase 8 booking-attention
    // selector (`bookingAttentionRows()`). No selection/cap/order/label
    // policy lives here — every computed value below just forwards the live
    // canonical snapshot and `todaySelectedDate` into the pure module.

    /// Today's local date string, recomputed on every access (never cached)
    /// so a day rollover while the app stays foregrounded is reflected
    /// immediately — mirrors RN's `getTodayDateString()` being called fresh
    /// on every render, as distinct from `todaySelectedDate` below (RN's
    /// `selectedDate` state), which only changes on explicit navigation.
    var todayString: String { NativeTodayBriefing.todayDateString(now: Date()) }

    var todayHeader: NativeTodayHeader {
        NativeTodayBriefing.header(now: Date(), todayDateString: todayString)
    }

    var todayWeekStrip: NativeWeekStrip? {
        NativeTodayBriefing.weekStrip(
            selectedDate: todaySelectedDate,
            today: todayString,
            jobDates: NativeTodayBriefing.jobDates(canonicalJobs)
        )
    }

    var todayIsSelectedDateToday: Bool { todaySelectedDate == todayString }

    var todayScheduleSectionTitle: String {
        NativeTodayBriefing.scheduleSectionTitle(selectedDate: todaySelectedDate, today: todayString)
    }

    var todaySelectedDaySchedule: [Canonical.Job] {
        NativeTodayBriefing.scheduleRows(canonicalJobs, date: todaySelectedDate)
    }

    var todayEarnings: Decimal { NativeTodayBriefing.earnings(for: todayString, jobs: canonicalJobs) }

    var todayOverdueInvoices: [Canonical.Invoice] {
        NativeTodayBriefing.overdueInvoices(canonicalInvoices, now: Date())
    }

    var todayOverdueTotal: Decimal { NativeTodayBriefing.overdueTotal(todayOverdueInvoices) }

    var todayOverdueCapped: NativeCappedSection<Canonical.Invoice> {
        NativeTodayBriefing.capped(todayOverdueInvoices, limit: NativeTodayBriefing.invoiceLimit)
    }

    var todayLeadJobs: [Canonical.Job] { NativeTodayBriefing.leadJobs(canonicalJobs) }

    var todayLeadCapped: NativeCappedSection<Canonical.Job> {
        NativeTodayBriefing.capped(todayLeadJobs, limit: NativeTodayBriefing.leadLimit)
    }

    /// "ABSENT means ON" (never truthiness) — `settings.estimateFollowUpsEnabled`
    /// already resolves that default at decode time (see the canonical
    /// adapter), so this reads it directly rather than re-deriving.
    var todayAwaitingEstimatesRow: NativeAwaitingEstimatesRow? {
        NativeTodayBriefing.awaitingEstimatesRow(
            jobs: canonicalJobs, now: Date(), followUpsEnabled: settings.estimateFollowUpsEnabled
        )
    }

    /// Task 10.12 (fix round 1, I1): wires the persisted `sampleTourDone`
    /// value (10.03's `NativeSetupChecklistStore`, adopted via
    /// `activateSetupChecklist`). Contract §1.5 requires
    /// `checklistState == nil -> no hero`, matching RN's `checklistState &&`
    /// gate — an unreadable/not-yet-loaded checklist store must not show any
    /// hero (including the sample-tour one), not fall back to "not done".
    var todayHero: NativeTodayHero? {
        guard let state = setupChecklistState else { return nil }
        return NativeTodayBriefing.hero(
            jobs: canonicalJobs,
            customers: canonicalCustomers,
            sampleTourDone: state.sampleTourDone == true
        )
    }

    /// Reuses the existing Phase 8 read-only selector directly — Today shows
    /// the same rows the Booking Requests screen shows, just condensed.
    var todayBookingAttentionRows: [NativeBookingAttention.Row] { bookingAttentionRows() }

    // MARK: - Setup checklist + insights cards (task 10.12, D4, D5, S4, S5)
    //
    // Thin pass-through wiring over the pure 10.02/10.03/10.04 engines and
    // `NativeInsightsCardPolicy` (this file). No selection/gating/mute policy
    // lives in `NativeSetupChecklistCard.swift`/`NativeInsightsCard.swift` —
    // those views only render what these properties/methods hand them.

    /// The settings snapshot the checklist derivation reads. `nil` when no
    /// settings have loaded yet (matches RN's `!settings` guard).
    private var todaySetupChecklistInput: NativeSetupChecklistInput? {
        guard let settings = snapshot.payload.settings else { return nil }
        return NativeSetupChecklistInput(settings: settings)
    }

    /// Whether the OS notification permission is currently granted — the
    /// `notifications` task's live derivation (no stored `done` flag).
    /// Synced from `NativeEstimateFollowUpNotificationCoordinator.permissionState`
    /// by `TodayView` into `notificationsGranted` (see that property's doc).
    private var todayNotificationsGranted: Bool { notificationsGranted }

    /// The rendered checklist rows, or `nil` when the store hasn't loaded /
    /// is unreadable (brief step 5: checklist stays hidden in that case) or
    /// settings haven't loaded yet.
    var todaySetupTasks: [NativeSetupTask]? {
        guard let input = todaySetupChecklistInput, let state = setupChecklistState else { return nil }
        return input.tasks(state: state, notificationsGranted: todayNotificationsGranted)
    }

    /// The one shared "Finish setting up card is off the screen" gate
    /// (contract §3.1, decision row 6) — both cards read this. Folds in
    /// "checklist store unreadable/not-yet-loaded → treated as incomplete"
    /// (brief step 5): a `nil` `setupChecklistState` can never be read as
    /// "done", which would wrongly reveal the insights card.
    var todaySetupComplete: Bool {
        guard let input = todaySetupChecklistInput, let state = setupChecklistState else { return false }
        return input.isSetupComplete(state: state, notificationsGranted: todayNotificationsGranted)
    }

    /// The full, un-muted, un-sliced engine output (10.02's
    /// `NativeTodayInsights.select`), in priority order.
    var todayInsightsAll: [NativeTodayInsight] {
        NativeTodayInsights.select(
            jobs: canonicalJobs,
            invoices: canonicalInvoices,
            now: Date(),
            schedule: calendarResolvedSchedule(),
            targetMarginPercent: (snapshot.payload.settings?.marginPercent).map(Self.doubleValue)
                ?? NativeTodayInsights.defaultTargetMarginPercent,
            customers: canonicalCustomers,
            recurringJobs: snapshot.payload.recurringJobs ?? [],
            expenses: canonicalExpenses
        )
    }

    /// Mute-filtered, top-3 slice — what the card actually renders (contract
    /// §3.1: mute filter runs BEFORE the top-3 slice). Fail-closed per brief
    /// step 5 when `insightMutes == nil` (see `NativeInsightsCardPolicy`).
    var todayVisibleInsights: [NativeTodayInsight] {
        NativeInsightsCardPolicy.visibleInsights(all: todayInsightsAll, mutes: insightMutes, now: Date())
    }

    /// The insights card's full visibility gate: setup complete (shared with
    /// the checklist), no first-action hero showing (decision row 18), and at
    /// least one insight to show.
    var todayInsightsVisible: Bool {
        NativeInsightsCardPolicy.isVisible(setupComplete: todaySetupComplete, hero: todayHero, insights: todayVisibleInsights)
    }

    private static func doubleValue(_ decimal: Decimal) -> Double { NSDecimalNumber(decimal: decimal).doubleValue }

    /// Records a completed setup task through the owner-bound store.
    /// Best-effort: a write failure leaves the in-memory state unchanged
    /// (worst case the task re-prompts; never a fabricated completion).
    ///
    /// Fix round 1 (I1): no-op when `setupChecklistState == nil` — an
    /// unreadable/not-yet-activated store must never be conjured into
    /// existence by a mutator; `?? NativeSetupChecklistState()` previously
    /// did exactly that, flipping a degraded store into live state.
    func markSetupTaskDone(_ task: NativeSetupTaskID) {
        guard setupChecklistState != nil, let binding = verifiedAccountBinding else { return }
        if let updated = try? setupChecklistStore.markTaskDone(task, for: binding) {
            setupChecklistState = updated
        }
    }

    /// "Hide" — RN's `dismissSetupChecklist()`. Optimistic: the card hides
    /// immediately (the caller reads `todaySetupTasks`/`todaySetupComplete`,
    /// both of which flip the instant this publishes) and the write follows.
    ///
    /// Fix round 1 (I1): no-op when `setupChecklistState == nil` (see
    /// `markSetupTaskDone`'s identical note).
    func dismissSetupChecklist() {
        guard let state = setupChecklistState, let binding = verifiedAccountBinding else { return }
        let optimistic = NativeSetupChecklist.dismissing(state)
        setupChecklistState = optimistic
        emitAnalytics(.setupChecklistDismissed(doneCount: todaySetupTasks?.filter(\.done).count ?? 0))
        if let persisted = try? setupChecklistStore.dismiss(for: binding) {
            setupChecklistState = persisted
        }
    }

    /// The hero's sample-tour tap (`markSampleTourDone` + `sample_job_opened`
    /// — RN's `TodayScreen.tsx` call sites, task 10.12 owns wiring this). A
    /// no-op for any other hero kind.
    ///
    /// Fix round 1 (I1): also a no-op when `setupChecklistState == nil` (see
    /// `markSetupTaskDone`'s identical note) — in practice `todayHero` is
    /// already `nil` whenever the store is unreadable, so this only guards a
    /// caller that constructs/passes a hero value directly (as tests do).
    func markSampleTourDoneIfNeeded(for hero: NativeTodayHero) {
        guard hero.kind == .sampleTour, let state = setupChecklistState,
            let binding = verifiedAccountBinding
        else { return }
        let optimistic = NativeSetupChecklist.markingSampleTourDone(state)
        setupChecklistState = optimistic
        emitAnalytics(.sampleJobOpened)
        if let persisted = try? setupChecklistStore.markSampleTourDone(for: binding) {
            setupChecklistState = persisted
        }
    }

    /// Every Today destination routed through the hero card. Marks the
    /// sample tour done first (so the write races the navigation, never
    /// after it), then routes normally.
    @discardableResult
    func handleTodayHeroTap(_ hero: NativeTodayHero) -> NativeTodayRouteResult {
        markSampleTourDoneIfNeeded(for: hero)
        trackFirstActionIfNeeded(for: hero)
        return routeToToday(hero.destination)
    }

    /// An insight row's tap — routes through the same `NativeTodayDestination`
    /// mapping every other Today action uses (10.04's exhaustive switch).
    @discardableResult
    func handleTodayInsightTap(_ insight: NativeTodayInsight) -> NativeTodayRouteResult {
        routeToToday(NativeTodayBriefing.destination(for: insight.target))
    }

    /// Applies a dismiss (`days == nil`) or snooze (`days` > 0) through the
    /// owner-bound mute store. Optimistic: the row drops from
    /// `todayVisibleInsights` immediately (the policy re-filters on every
    /// read), persisted behind it — mirrors RN's `applyMute`.
    ///
    /// Fix round 1 (I2): fail-closed at the store layer, not just the view.
    /// `insightMutes == nil` (unreadable) is now a no-op — `?? []` previously
    /// let a mute exist purely in memory on top of a degraded store, which
    /// `NativeInsightsCardPolicy` would then read as "readable" on the next
    /// pass (the in-memory value is non-nil) despite nothing durable backing
    /// it. The owner-binding guard also now runs BEFORE the optimistic
    /// mutation, so a mute can never be applied in memory without a binding
    /// to persist it under.
    func applyInsightMute(_ insight: NativeTodayInsight, days: Int?) {
        guard let mutes = insightMutes, let binding = verifiedAccountBinding else { return }
        if let days {
            emitAnalytics(.insightSnoozed(insight.kind, insightID: insight.id, days: days))
        } else {
            emitAnalytics(.insightDismissed(insight.kind, insightID: insight.id))
        }
        let now = Date()
        let liveIDs = Set(todayInsightsAll.map(\.id))
        let optimistic = NativeInsightMutes.applying(
            id: insight.id, now: now, days: days, liveIDs: liveIDs, to: mutes
        )
        insightMutes = optimistic
        if let persisted = try? insightMuteStore.applyMute(id: insight.id, now: now, days: days, liveIDs: liveIDs, for: binding) {
            insightMutes = persisted
        }
    }

    /// Installs the one-shot coach prefill (ruling R4) and switches to the
    /// Coach tab. 10.13 consumes and clears `pendingCoachPrefill`; it never
    /// auto-sends.
    func installPendingCoachPrefill(_ prompt: String) {
        pendingCoachPrefill = prompt
        selectedTab = .coach
    }

    /// Task 10.13 (ruling R4): atomically reads and clears the one-shot
    /// coach prefill so `CoachView` can call this from BOTH `.onAppear`
    /// (view mounts after the prefill was already installed) and
    /// `.onChange(of: pendingCoachPrefill)` (view is already on screen when
    /// an insight installs one) without ever filling the input twice or
    /// re-firing after the first consume. Returns `nil` when nothing is
    /// pending — safe to call unconditionally from both call sites.
    @discardableResult
    func consumePendingCoachPrefill() -> String? {
        guard let prompt = pendingCoachPrefill else { return nil }
        pendingCoachPrefill = nil
        return prompt
    }

    /// Task 10.13 (C1/C2): one coach turn, routed through 10.10's transport.
    /// `history` must already include the just-appended user message —
    /// `MAX_HISTORY` slicing happens inside `NativeCoachTransport`, so this
    /// method does not re-slice or otherwise touch the transcript.
    func sendCoachMessage(history: [NativeCoachMessage]) async throws -> String {
        guard let canonicalSettings = coachCanonicalSettings() else {
            throw NativeCoachTransportError.unavailable
        }
        let systemPrompt = NativeCoachPrompt.buildSystemPrompt(
            settings: canonicalSettings, snapshot: coachBusinessSnapshot()
        )
        // Reuses the same test-only override seam `scheduleBookingSessionBytes`
        // already established (falls back to the real Keychain read when no
        // override is set) rather than reading the Keychain directly, so host
        // tests never depend on live system Keychain state.
        let sessionBytes = scheduleBookingSessionBytes(explicit: nil)
        return try await coachTransport.sendMessage(
            messages: history,
            systemPrompt: systemPrompt,
            anthropicKey: effectiveAdvisoryAnthropicKey ?? "",
            groqKey: effectiveAdvisoryGroqKey ?? "",
            sessionBytes: sessionBytes
        )
    }

    /// Test-only (task 10.13): the exact system prompt `sendCoachMessage`
    /// would build for the current canonical settings + business snapshot,
    /// without making a network call — proves the wiring (which settings,
    /// which snapshot) independently of 10.10's own `NativeCoachPrompt`
    /// format fixtures.
    func coachTestSystemPrompt() -> String? {
        guard let canonicalSettings = coachCanonicalSettings() else { return nil }
        return NativeCoachPrompt.buildSystemPrompt(settings: canonicalSettings, snapshot: coachBusinessSnapshot())
    }

    private var effectiveAdvisoryAnthropicKey: String? { coachAdvisoryAnthropicKeyOverride ?? advisoryAnthropicKey }
    private var effectiveAdvisoryGroqKey: String? { coachAdvisoryGroqKeyOverride ?? advisoryGroqKey }

    /// The canonical settings for the coach system prompt. Prefers the live
    /// in-memory canonical snapshot (so the exact trade id / rate values
    /// match what the rest of the app just synced); falls back to converting
    /// the published `BusinessSettings` projection only in the rare case the
    /// canonical snapshot has never carried a settings record (e.g.
    /// `applyEmptySnapshot()`'s bootstrap state before onboarding completes).
    private func coachCanonicalSettings() -> Canonical.Settings? {
        if let existing = snapshot.payload.settings { return existing }
        return try? CanonicalUIAdapters.canonical(from: settings)
    }

    /// RN's `ai_chat_sent` event (`screens/ChatScreen.tsx#send`). `source`
    /// distinguishes an insight-originated prefill from an organic send
    /// (ruling R4); `provider` mirrors RN's `settings?.anthropicKey ?
    /// 'anthropic' : settings?.groqKey ? 'groq' : 'backend'` via 10.10's own
    /// provider-precedence rule, so the two can never disagree.
    func trackCoachMessageSent(sourceIsInsightPrefill: Bool) {
        emitAnalytics(.aiChatSent(
            sourceIsInsightPrefill ? .insightPrefill : .organic,
            provider: coachProviderSummary.analyticsName
        ))
    }

    /// Final-review I4: the provider the coach will actually route to right
    /// now, for Settings › AI Assistant — the same key inputs
    /// `sendCoachMessage` passes to `NativeCoachTransport.provider(...)`, so
    /// the label can never disagree with the real routing. Key-free.
    var coachProviderSummary: NativeCoachProviderSummary {
        NativeCoachProviderSummary(provider: NativeCoachTransport.provider(
            anthropicKey: effectiveAdvisoryAnthropicKey ?? "",
            groqKey: effectiveAdvisoryGroqKey ?? ""))
    }

    /// Task 10.13 fix round 1: call on every "New chat" tap so a reply
    /// captured under the OLD ticket (`coachConversationTicket()`, taken
    /// before this bump) can never pass `coachReplyStillValid(_:)` again,
    /// even if `CoachView` also cancels its in-flight `Task`. Also bumped
    /// by `resetTodayOwnerState()` at every account boundary as a
    /// belt-and-suspenders measure alongside the `ownerBinding` check
    /// already baked into the ticket.
    func bumpCoachConversationGeneration() {
        coachConversationGeneration &+= 1
    }

    /// Task 10.13 fix round 1: the ticket `CoachView.send()` must capture
    /// immediately before starting its network await.
    func coachConversationTicket() -> NativeCoachConversationTicket {
        NativeCoachConversationTicket(generation: coachConversationGeneration, ownerBinding: verifiedAccountBinding)
    }

    /// Task 10.13 fix round 1: the ticket `CoachView.send()` must re-check
    /// immediately after its network await resolves, before appending the
    /// reply to the transcript. `false` means "New chat", a sign-out, or an
    /// account switch happened while the request was in flight — the caller
    /// must discard the reply instead of appending it.
    func coachReplyStillValid(_ ticket: NativeCoachConversationTicket) -> Bool {
        NativeCoachConversationGuard.shouldAppend(sent: ticket, current: coachConversationTicket())
    }

    /// Installs a one-shot settings deep-link (the checklist card's task tap)
    /// and requests the Settings sheet. `TodayView` observes
    /// `pendingSettingsDestination` to present `SettingsView(initialDestination:)`.
    func routeToTodaySettings(_ route: NativeSetupRoute) {
        pendingSettingsDestination = route
    }

    // MARK: - Analytics (task 10.12, ruling R5)
    //
    // `insight_shown` fires once per distinct visible id set, not per render
    // — `lastShownInsightIDsKey` mirrors RN's `lastShownKey` ref.

    func trackTodayInsightsShownIfNeeded(_ insights: [NativeTodayInsight]) {
        let key = insights.map(\.id).joined(separator: ",")
        guard !key.isEmpty, key != lastShownInsightIDsKey else { return }
        lastShownInsightIDsKey = key
        // Task 11.08: typed string arrays (the 11.07 handoff), not
        // comma-joined strings.
        emitAnalytics(.insightShown(kinds: insights.map(\.kind), ids: insights.map(\.id)))
    }

    func trackInsightTapped(_ insight: NativeTodayInsight) {
        emitAnalytics(.insightTapped(insight.kind))
    }

    func trackInsightCoachOpened(_ insight: NativeTodayInsight) {
        emitAnalytics(.insightCoachOpened(insight.kind))
    }

    func trackInsightReasonViewed(_ insight: NativeTodayInsight) {
        emitAnalytics(.insightReasonViewed(insight.kind))
    }

    /// RN `SetupChecklistCard.tsx`'s `track("setup_checklist_task_opened",
    /// {task: id})` — fired for every task tap that routes to Settings
    /// (the notifications task never reaches this; it's handled in-card).
    func trackSetupChecklistTaskOpened(_ task: NativeSetupTaskID) {
        emitAnalytics(.setupChecklistTaskOpened(task))
    }

    // MARK: - Analytics emission and identity (task 11.08, contract §9.3–§9.5)
    //
    // Every event is built by a `NativeAnalyticsEvent` constructor and sent
    // through `emitAnalytics(_:)`, after the durable commit it describes. The
    // seam never throws and the transport swallows adapter failures, so
    // analytics can neither block nor roll back a save.

    private func emitAnalytics(_ event: NativeAnalyticsEvent) {
        analytics.track(event)
    }

    private func applyAnalyticsIdentityVerified(_ userID: String) {
        applyAnalyticsIdentityActions(analyticsIdentity.verified(userID))
    }

    private func applyAnalyticsIdentityBoundary() {
        applyAnalyticsIdentityActions(analyticsIdentity.boundary())
        analyticsPaywallTracked = false
    }

    /// Task 11.09 (§9.4): the one identity lifecycle drives both SDKs, like
    /// RN's `identifyUser`/`resetUser` (PostHog identify + `Sentry.setUser({id})`,
    /// reset + `Sentry.setUser(null)`).
    private func applyAnalyticsIdentityActions(_ actions: [NativeAnalyticsIdentityLifecycle.Action]) {
        for action in actions {
            switch action {
            case .identify(let userID):
                analytics.identify(userID)
                crashReporting.setUser(id: userID)
            case .reset:
                analytics.reset()
                crashReporting.setUser(id: nil)
            }
        }
    }

    // MARK: - Error reporting (task 11.09, contract §10.3)

    /// RN `reportError(error, context)`. Call it after the commit it
    /// describes, never inside one: the reporter swallows every failure and
    /// runs off the caller's thread. Only the §10.3 extra keys survive.
    ///
    /// Phase 12 (12.02): each report's context and code (never its message)
    /// also land in `supportCodeHistory`, the support report's recent codes.
    func reportError(_ value: Any?, context: [String: Any]) {
        crashReporting.reportError(value, context: context)
        supportCodeHistory.record(
            context: context["context"] as? String,
            code: NativeSupportDiagnostics.reportedCode(value)
        )
    }

    /// RN `utils/sync.ts` `reportError(firstError, {context: 'pushQueue'})`
    /// and `{context: 'pullRemote'}`. The coordinator reduces failures to
    /// bounded diagnostic codes, so the report is a PostgREST-shaped object
    /// (`{code, message}`) that the wrapper titles `"[<code>] <message>"`.
    /// It runs once per pass, when the coordinator's status leaves
    /// `isSyncing`, and only for a pass that really attempted the network
    /// (`offline`, `backoffDeferred` and the other early exits never report).
    private func applySyncStatus(_ status: NativeSyncStatus) {
        let passEnded = syncStatus.isSyncing && !status.isSyncing
        syncStatus = status
        guard passEnded else { return }
        // Phase 12 (12.00b.1): the Cloud Sync list follows each pass (a
        // change queued for a refused record hides its entry).
        refreshRejectedChanges()
        reportSyncPassFailure(status)
        monitorSyncPass(status)
    }

    private func reportSyncPassFailure(_ status: NativeSyncStatus) {
        let code = status.diagnosticCode
        switch status.lastOutcome {
        case .failed(let remaining)?, .partial(_, let remaining, _)?:
            reportError(
                ["code": code ?? "push/unavailable", "message": "Sync push left changes queued"],
                context: ["context": "pushQueue", "count": remaining]
            )
            // Phase 12 (12.00b.1): the pull also runs after a partial or
            // failed push now (RN `syncIfOnline`: `pushQueue`, then
            // `pullRemote`, each reporting its own failure).
            guard let pull = status.lastPullResult, pull.state == .failed || pull.state == .partial else { return }
            reportError(
                ["code": pull.diagnosticCode ?? "pull/unavailable", "message": "Sync pull did not complete"],
                context: ["context": "pullRemote"]
            )
        case .completed?:
            guard let pull = status.lastPullResult, pull.state == .failed || pull.state == .partial else { return }
            reportError(
                ["code": code ?? pull.diagnosticCode ?? "pull/unavailable", "message": "Sync pull did not complete"],
                context: ["context": "pullRemote"]
            )
        default:
            return
        }
    }

    /// Phase 12 (12.02): the charter's cross-pass signals
    /// (`NativeSyncMonitor`), after the per-pass reports above: TH-5
    /// `pushDiscarded` (a change dropped as unsendable, which the pass
    /// otherwise reports as completed), TH-6/OI-3 `syncThrottle` (three
    /// throttled network passes in a row, once per streak) and TH-3
    /// `pendingAge` (a change queued over 24 hours at the end of a network
    /// pass, once until the queue moves on). Counts and table names only.
    /// Every ended pass goes to the monitor: a discard counts even when the
    /// pass's coalesced rerun ended early (review fix 1); the monitor itself
    /// limits the throttle and age rules to network passes.
    private func monitorSyncPass(_ status: NativeSyncStatus) {
        let oldest = NativeSyncMonitor.isNetworkPass(status.lastOutcome)
            ? mutationQueue.load().compactMap { NativeSupportDiagnostics.queuedDate($0.ts) }.min()
            : nil
        for signal in syncMonitor.recordPass(status, oldestPendingAt: oldest, now: Date()) {
            switch signal {
            case let .discarded(table, count):
                reportError(
                    ["code": "record-contract/\(table)", "message": "Sync push dropped unsendable changes"],
                    context: ["context": "pushDiscarded", "collection": table, "count": count]
                )
            case let .throttled(passes):
                reportError(
                    ["code": "throttle/consecutive-passes", "message": "Sync passes throttled in a row"],
                    context: ["context": "syncThrottle", "count": passes]
                )
            case let .pendingAge(count):
                reportError(
                    ["code": "pending-age/over-24h", "message": "Changes pending for over 24 hours"],
                    context: ["context": "pendingAge", "count": count]
                )
            }
        }
    }

    /// The gate `didSet` hook: onboarding steps, the paywall and the root
    /// screens (`NativeAnalyticsGatePolicy`). Entering `.signedIn` from any
    /// other gate also re-asserts the identity, which is a no-op for the id
    /// already identified at verification.
    private func emitAnalyticsForGateChange(from oldValue: NativeAuthenticationGateState) {
        let wasSignedIn = if case .signedIn = oldValue { true } else { false }
        if !wasSignedIn, case .signedIn = authenticationGateState, let subject = authenticatedUserSubject {
            applyAnalyticsIdentityVerified(subject)
        }
        let output = NativeAnalyticsGatePolicy.transition(
            from: oldValue,
            to: authenticationGateState,
            paywallTracked: analyticsPaywallTracked
        )
        analyticsPaywallTracked = output.paywallTracked
        if let screen = output.screen { trackScreen(screen) }
        output.events.forEach(emitAnalytics)
    }

    /// Sends `$screen` with the RN route name (§9.3). Destinations without an
    /// RN route send nothing. Like RN's `useNavigationTracker`, every call
    /// sends: a return to a list and a repeat visit both count. The only
    /// dedupe is per appearance (`NativeAnalyticsScreenAppearance`), for
    /// SwiftUI's duplicate `onAppear`.
    func trackScreen(_ destination: NativeAnalyticsScreen) {
        guard let name = destination.routeName else { return }
        analytics.screen(name)
    }

    /// Shared tail of the three interactive sign-in paths: apply the verified
    /// identity (which identifies it), then `sign_in` (RN `AuthScreen.tsx:122`,
    /// `:172`, `:181`, after the provider call succeeds).
    private func finishInteractiveSignIn(
        _ outcome: NativeAuthenticatedIdentityActivationOutcome,
        email: String?,
        method: NativeAnalyticsEvent.SignInMethod,
        gateOverride: NativeAuthenticationGateState? = nil
    ) {
        bindInteractiveOwner(outcome, email: email, gateOverride: gateOverride)
        emitAnalytics(.signIn(method))
    }

    /// The shared tail of every interactive path that binds a freshly
    /// verified owner: the three sign-ins and (Phase 12, L286.4) sign-up's
    /// immediate session. Final review 1a/1b: a boundary step still pending
    /// from a switch or recovery exit is retried before the owner is bound.
    private func bindInteractiveOwner(
        _ outcome: NativeAuthenticatedIdentityActivationOutcome,
        email: String?,
        gateOverride: NativeAuthenticationGateState? = nil
    ) {
        retryPendingBoundarySteps()
        didCheckMigratedAuthenticatedIdentity = true
        applyAuthenticatedIdentityOutcome(outcome, email: email, gateOverride: gateOverride)
    }

    /// RN `TodayScreen.tsx:761`/`:766`: the first-action hero taps.
    private func trackFirstActionIfNeeded(for hero: NativeTodayHero) {
        switch hero.kind {
        case .addCustomer: emitAnalytics(.firstActionTapped(.addCustomer))
        case .createJob: emitAnalytics(.firstActionTapped(.createJob))
        case .sampleTour: break
        }
    }

    /// The composer for an on-my-way / appointment-confirmation message
    /// opened (RN tracks only when `sendAppointmentMessage` opened one).
    func recordAppointmentComposerOpened(onMyWay: Bool) {
        emitAnalytics(onMyWay ? .onMyWaySent : .appointmentConfirmSent)
    }

    /// The change-order approval composer opened (RN `ChangeOrdersSection`
    /// tracks when the composer opened). The amount is read from the
    /// canonical change order, never from the view.
    func recordChangeOrderComposerOpened(
        jobID: String,
        changeOrderID: String,
        channel: NativeAnalyticsEvent.ComposerChannel
    ) {
        guard let order = snapshot.payload.jobs?.first(where: { $0.id == jobID })?
            .changeOrders?.first(where: { $0.id == changeOrderID })
        else { return }
        emitAnalytics(.changeOrderSent(amount: order.amount, channel: channel))
    }

    /// The system composer reported `.sent` for an estimate follow-up.
    func recordEstimateFollowUpSent(channel: NativeAnalyticsEvent.MessageChannel) {
        emitAnalytics(.estimateFollowUpSent(
            channel: channel,
            source: estimateFollowUpAnalyticsSource
        ))
    }

    /// A bulk reminder chain that started (it had an eligible invoice) has
    /// finished after presenting `presentedCount` outreach sheets. The event
    /// shape and count semantics live in `bulkInvoiceReminderRun`.
    func recordBulkInvoiceReminderRunCompleted(channel: NativeBulkRemindChannel, presentedCount: Int) {
        emitAnalytics(.bulkInvoiceReminderRun(channel: channel, presentedCount: presentedCount))
    }

    /// An explicit payment-link generation succeeded (RN
    /// `OutreachScreen.tsx:211`; automatic regeneration does not count).
    func recordPaymentLinkSent(provider: NativePaymentProvider, deposit: Bool) {
        emitAnalytics(.paymentLinkSent(provider: provider.rawValue, deposit: deposit))
    }

    /// A receipt scan finished and was applied (RN `AddExpenseModal.tsx:150`,
    /// `:158`, `:184`). `result == nil` is a failed scan; otherwise the
    /// editor's applied state decides `filled` / `empty`.
    func recordReceiptScan(_ result: NativeReceiptScanResult?, state: NativeExpenseScanState) {
        guard let result else {
            emitAnalytics(.receiptScanFailed)
            return
        }
        let route: NativeAnalyticsEvent.ReceiptRoute = result.route == "user_key" ? .userKey : .backend
        emitAnalytics(.receiptScanned(state == .filled ? .filled : .empty, route: route))
    }

    /// RN's `setSelectedDate`. Refuses a malformed date rather than adopting
    /// a value the week-strip/schedule projection cannot parse.
    func selectTodayDate(_ date: String) {
        guard NativeSchedule.parseDateComponents(date) != nil else { return }
        todaySelectedDate = date
    }

    /// RN's `prevWeek`/`nextWeek` (`shiftDate(selectedDate, ±7)`).
    func shiftTodaySelectedWeek(by days: Int) {
        guard let shifted = NativeTodayBriefing.shiftDate(todaySelectedDate, days: days) else { return }
        todaySelectedDate = shifted
    }

    /// Classification of every `NativeTodayDestination` case (10.04) for
    /// `routeToToday` below. Two shapes: `.handled` cases already mutated
    /// store state themselves (tab switch + one-shot deep link, exactly the
    /// `routeToGlobalSearchResult` pattern); the `.present*` cases have no
    /// existing cross-tab one-shot sheet field to deep-link into an editor on
    /// another tab, so they hand the view a typed instruction to present the
    /// editor directly from Today — the same thing `NativeGlobalSearchView`'s
    /// inline action sheet already does for "New job"/"New customer"/"New
    /// invoice". `.none` is the fail-closed case: a missing job/invoice, an
    /// archived customer (insights never target one), or a malformed date,
    /// produces no destination. Archived JOBS route normally (final-review
    /// I1, contract §9.6): RN `utils/archive.ts` keeps archived records on
    /// Today and in notifications, and RN's Today taps open JobDetail for
    /// them, so a shown row must never be a dead tap.
    enum NativeTodayRouteResult: Equatable {
        case handled
        case presentJobEditor(jobID: String)
        case presentNewJobEditor
        case presentNewCustomerEditor
        case presentInvoiceFromJob(jobID: String)
        case presentRoute
        case presentCalendar
        case presentSearch
        case presentSettings
        case none
    }

    /// True when `jobID` names a job that currently exists in this
    /// workspace's snapshot, archived or not. The single fail-closed check
    /// every job-based `NativeTodayDestination` case below uses. Final-review
    /// I1 (RN parity, contract §9.6): archiving does not hide a job from
    /// Today (`NativeTodayBriefing.scheduleRows`/`leadJobs` keep it, exactly
    /// like RN `utils/archive.ts`), so the tap must route too — only a
    /// missing record fails closed. `JobsView` opens an archived job through
    /// `deepLinkedJobID` like any other.
    private func todayJobExists(_ jobID: String) -> Bool {
        jobs.contains(where: { $0.id == jobID })
    }

    /// Executes a Today destination against the live snapshot. Reuses the
    /// exact one-shot exact-ID pattern from `routeToGlobalSearchResult`:
    /// clears every prior deep-link target first, verifies the CURRENT
    /// record exists, and only then publishes the new target — a stale
    /// insight/booking-row/hero target for a since-deleted record is a no-op,
    /// never an invented destination. Archived jobs route normally (I1).
    @discardableResult
    func routeToToday(_ destination: NativeTodayDestination) -> NativeTodayRouteResult {
        switch destination {
        case .job(let id):
            guard todayJobExists(id) else { return .none }
            resetTodayDeepLinkTargets()
            deepLinkedJobID = id
            selectedTab = .jobs
            return .handled
        case .createInvoice(let jobID):
            guard todayJobExists(jobID) else { return .none }
            return .presentInvoiceFromJob(jobID: jobID)
        case .invoice(let id):
            guard invoices.contains(where: { $0.id == id }) else { return .none }
            resetTodayDeepLinkTargets()
            deepLinkedInvoiceID = id
            selectedTab = .invoices
            return .handled
        case .invoices:
            selectedTab = .invoices
            return .handled
        case .jobs:
            selectedTab = .jobs
            return .handled
        case .schedule(let jobID):
            guard todayJobExists(jobID) else { return .none }
            return .presentJobEditor(jobID: jobID)
        case .selectDate(let date):
            guard NativeSchedule.parseDateComponents(date) != nil else { return .none }
            selectTodayDate(date)
            return .handled
        case .customer(let id):
            guard customers.contains(where: { $0.id == id && ($0.archivedAt ?? "").isEmpty }) else { return .none }
            resetTodayDeepLinkTargets()
            deepLinkedCustomerID = id
            selectedTab = .customers
            return .handled
        case .customers:
            selectedTab = .customers
            return .handled
        case .money:
            selectedTab = .money
            return .handled
        case .calendar:
            return .presentCalendar
        case .search:
            return .presentSearch
        case .settings:
            return .presentSettings
        case .route:
            return .presentRoute
        case .onMyWay(let jobID):
            // Deliberate native difference (recorded in the 10.11 report):
            // RN pre-fills the OS SMS/email composer and still requires the
            // owner to hit send there (`utils/appointmentSend.ts`,
            // `utils/messaging.ts`) — it is not a silent background send.
            // Native routes through the same on-my-way review sheet the
            // notification-tap path already uses (`requestOnMyWayReview`)
            // rather than duplicating that composer-launch logic — both
            // paths still require the owner to review and send.
            guard todayJobExists(jobID) else { return .none }
            requestOnMyWayReview(jobID: jobID)
            return .handled
        case .newJob:
            return .presentNewJobEditor
        case .newCustomer:
            return .presentNewCustomerEditor
        }
    }

    private func resetTodayDeepLinkTargets() {
        deepLinkedJobID = nil
        deepLinkedCustomerID = nil
        deepLinkedInvoiceID = nil
        deepLinkedOutreachInvoiceID = nil
    }

    /// Every Overview-tab card for one date filter, in one value.
    func moneyOverview(filter: NativeMoneyDateFilter, now: Date = Date()) -> NativeMoneyOverview {
        NativeMoneyOverview.make(
            filter: filter,
            invoices: canonicalInvoices,
            expenses: canonicalExpenses,
            jobs: canonicalJobs,
            trips: canonicalTrips,
            pricebook: canonicalPricebook,
            taxValues: taxSettingsValues,
            mileageRate: snapshot.payload.settings?.mileageRate ?? NativeMileage.defaultMileageRate,
            laborCostRate: snapshot.payload.settings?.laborCostRate,
            now: now
        )
    }

    /// The Expenses tab's rows for one date filter.
    func moneyExpenseRows(
        filter: NativeMoneyDateFilter,
        now: Date = Date()
    ) -> [NativeMoneyExpenseRow] {
        let range = NativeCashBasis.range(for: filter.rawValue, now: now)
        return NativeMoneyExpenseList.rows(
            expenses: canonicalExpenses, jobs: canonicalJobs, start: range.start, end: range.end
        )
    }

    /// `settings.mileageRate ?? DEFAULT_MILEAGE_RATE` — the rate the mileage
    /// summary, the tax estimate, and the log screen all read.
    var effectiveMileageRate: Decimal {
        NativeMileage.effectiveRate(snapshot.payload.settings)
    }

    // MARK: CSV import commit + undo (I1–I3)

    /// Per-row report for one committed import batch.
    struct NativeImportCommitReport: Equatable {
        var batchID: String
        var entity: NativeImportEntity
        var fileHash: String
        var counts: NativeImportCounts
        var outcomes: [NativeRowOutcome]
        var truncated: Bool
    }

    /// Commits one parsed CSV import against the LATEST canonical collections.
    ///
    /// The pure engine (task 9.07) builds the next arrays and stamps
    /// `importBatchId` on newly created records only, so matched/pre-existing
    /// records keep their own provenance and are never captured by a later undo.
    /// The durable write happens before the report/undo is offered and before the
    /// queue upserts; history is recorded last, because the RN screen surfaces
    /// the report even when the operational metadata write fails.
    func commitImport(
        entity: NativeImportEntity,
        rows: [[String]],
        mapping: [String?],
        dateFormat: NativeDateFormat?,
        fileHash: String,
        truncated: Bool = false,
        environment: NativeImportEnvironment = .live()
    ) -> Result<NativeImportCommitReport, NativeMoneyRecordRefusal> {
        guard ensurePersistenceWritable() else { return .failure(.persistenceUnavailable) }
        let batchID = Self.importBatchIDGenerator.importBatchID()
        var updated = snapshot
        var createdCustomers: [Canonical.Customer] = []
        var createdJobs: [Canonical.Job] = []
        var createdInvoices: [Canonical.Invoice] = []
        var createdExpenses: [Canonical.Expense] = []
        let counts: NativeImportCounts
        let outcomes: [NativeRowOutcome]

        switch entity {
        case .customers:
            let result = NativeImportEngine.buildCustomerImport(
                rows: rows, mapping: mapping,
                existing: updated.payload.customers ?? [],
                batchID: batchID, environment: environment
            )
            createdCustomers = result.records.filter { $0.importBatchId == batchID }
            updated.payload.customers = result.records
            counts = result.counts
            outcomes = result.outcomes
        case .jobs:
            let result = NativeImportEngine.buildJobImport(
                rows: rows, mapping: mapping,
                existingCustomers: updated.payload.customers ?? [],
                existingJobs: updated.payload.jobs ?? [],
                batchID: batchID, dateFormat: dateFormat, environment: environment
            )
            createdCustomers = result.customers.filter { $0.importBatchId == batchID }
            createdJobs = result.jobs.filter { $0.importBatchId == batchID }
            updated.payload.customers = result.customers
            updated.payload.jobs = result.jobs
            counts = result.counts
            outcomes = result.outcomes
        case .invoices:
            let settings = updated.payload.settings
            let result = NativeImportEngine.buildInvoiceImport(
                rows: rows, mapping: mapping,
                existingCustomers: updated.payload.customers ?? [],
                existingInvoices: updated.payload.invoices ?? [],
                batchID: batchID, dateFormat: dateFormat,
                invoicePrefix: settings?.invoicePrefix, invoiceStartNumber: settings?.invoiceStartNumber,
                environment: environment
            )
            createdCustomers = result.customers.filter { $0.importBatchId == batchID }
            createdInvoices = result.invoices.filter { $0.importBatchId == batchID }
            updated.payload.customers = result.customers
            updated.payload.invoices = result.invoices
            counts = result.counts
            outcomes = result.outcomes
        case .expenses:
            let result = NativeImportEngine.buildExpenseImport(
                rows: rows, mapping: mapping,
                existingExpenses: updated.payload.expenses ?? [],
                batchID: batchID, dateFormat: dateFormat, environment: environment
            )
            createdExpenses = result.expenses.filter { $0.importBatchId == batchID }
            updated.payload.expenses = result.expenses
            counts = result.counts
            outcomes = result.outcomes
        }

        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Import failed. Nothing was changed."
            return .failure(.persistenceUnavailable)
        }
        for record in createdCustomers { enqueueUpsert(table: "customers", recordId: record.id, record: record) }
        for record in createdJobs { enqueueUpsert(table: "jobs", recordId: record.id, record: record) }
        for record in createdInvoices { enqueueUpsert(table: "invoices", recordId: record.id, record: record) }
        for record in createdExpenses { enqueueUpsert(table: "expenses", recordId: record.id, record: record) }
        // History is operational metadata: a failed write never hides a durable
        // import or its undo affordance.
        NativeImportHistory.record(
            NativeImportBatchRecord(
                batchId: batchID, entity: entity.rawValue, fileHash: fileHash,
                date: environment.today(), counts: NativeImportCountsCodable(counts)
            ),
            in: importHistoryDirectory
        )
        return .success(NativeImportCommitReport(
            batchID: batchID, entity: entity, fileHash: fileHash,
            counts: counts, outcomes: outcomes, truncated: truncated
        ))
    }

    /// Undoes one import batch. Strips ONLY that batch's own created records
    /// (RN `stripBatch` semantics — only the entity's own collection, and any
    /// record still carrying the batch's provenance), then forgets the batch
    /// from device-local history.
    @discardableResult
    func undoImport(batchID: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        guard let batch = NativeImportHistory.load(from: importHistoryDirectory)
            .first(where: { $0.batchId == batchID }),
            let entity = NativeImportEntity(rawValue: batch.entity)
        else { return false }
        var updated = snapshot
        var removed: [(table: String, id: String)] = []
        switch entity {
        case .customers:
            let records = updated.payload.customers ?? []
            removed = records.filter { $0.importBatchId == batchID }.map { ("customers", $0.id) }
            updated.payload.customers = NativeImportEngine.stripBatch(records, batchID: batchID) { $0.importBatchId }
        case .jobs:
            let records = updated.payload.jobs ?? []
            removed = records.filter { $0.importBatchId == batchID }.map { ("jobs", $0.id) }
            updated.payload.jobs = NativeImportEngine.stripBatch(records, batchID: batchID) { $0.importBatchId }
        case .invoices:
            let records = updated.payload.invoices ?? []
            removed = records.filter { $0.importBatchId == batchID }.map { ("invoices", $0.id) }
            updated.payload.invoices = NativeImportEngine.stripBatch(records, batchID: batchID) { $0.importBatchId }
        case .expenses:
            let records = updated.payload.expenses ?? []
            removed = records.filter { $0.importBatchId == batchID }.map { ("expenses", $0.id) }
            updated.payload.expenses = NativeImportEngine.stripBatch(records, batchID: batchID) { $0.importBatchId }
        }
        guard !removed.isEmpty else {
            // Nothing left to strip (already undone): forget the batch so the row
            // cannot be offered again.
            _ = NativeImportHistory.remove(batchID: batchID, in: importHistoryDirectory)
            return false
        }
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "Could not undo the import: \(error.localizedDescription)"
            return false
        }
        for record in removed { enqueueDelete(table: record.table, recordId: record.id) }
        _ = NativeImportHistory.remove(batchID: batchID, in: importHistoryDirectory)
        return true
    }

    /// Device-local import history, newest first.
    var importHistory: [NativeImportBatchRecord] {
        NativeImportHistory.load(from: importHistoryDirectory)
    }

    /// Same-file re-import warning lookup.
    func importBatch(entity: NativeImportEntity, fileHash: String) -> NativeImportBatchRecord? {
        NativeImportHistory.findBatch(entity: entity.rawValue, fileHash: fileHash, in: importHistoryDirectory)
    }

    // MARK: Test seams (task 8.08)

    /// Test-only: seeds the verified owner identity so intake/response/admin
    /// paths exercise owner capture and rechecks without a live session.
    /// Production never calls this; it changes no sync or persistence
    /// behavior beyond the seeded identity.
    func scheduleBookingTestSeedSignedInOwner(subject: String, binding: String) {
        authenticatedUserSubject = subject
        verifiedAccountBinding = binding
        isMigratedLocalOwnerVerified = true
        authenticationGateState = .signedIn(email: nil)
    }

    /// Test-only (task 10.07): invokes the REAL `activateReviewRequests`
    /// reload — the exact method a live launch's
    /// `applyAuthenticatedIdentityOutcome` calls to repopulate
    /// `reviewRequestRecords` from the on-disk `NativeReviewRequestStore` for
    /// the verified owner — without standing up a full mocked sign-in flow.
    /// `scheduleBookingTestSeedSignedInOwner` alone only seeds the identity
    /// fields; it does not reload owner-bound side-stores, so a test that
    /// needs a genuine "relaunch reads its persisted review_ records back"
    /// proof must call this too. Production never calls this directly.
    func scheduleBookingTestReloadReviewRequests(accountBinding: String) {
        activateReviewRequests(accountBinding: accountBinding, migrated: nil)
    }

    /// Test-only (task 10.12): the same real-reload pattern as
    /// `scheduleBookingTestReloadReviewRequests`, for the insight-mute and
    /// setup-checklist stores. Production never calls this directly.
    ///
    /// Fix round 1 (I5): the two `migrated*` parameters drive the REAL
    /// migration-seed adoption path (`mergeSeeded`, via `activateInsightMutes`/
    /// `activateSetupChecklist`) with actual seed content — the prior
    /// `migrated: nil` calls only ever exercised the "no seed" branch, so
    /// seed adoption itself was untested despite the task 10.12 report
    /// originally claiming otherwise. Defaulted to `nil` so every existing
    /// call site is unaffected.
    func testActivateInsightAndChecklistStores(
        accountBinding: String,
        migratedInsightMutes: [NativeTypedAccountState.InsightMute]? = nil,
        migratedSetupChecklistState: NativeTypedAccountState.SetupChecklistState? = nil
    ) {
        activateInsightMutes(accountBinding: accountBinding, migrated: migratedInsightMutes)
        activateSetupChecklist(accountBinding: accountBinding, migrated: migratedSetupChecklistState)
    }

    /// Test-only (fix round 1, I7a): drives the real `applyCompletedSignOutState()`
    /// body directly. The public `signOut()`/`deleteAccount()`/
    /// `retryAccountScrub()` callers all wrap it in a real Keychain-backed
    /// local account scrub (and, for `signOut(revokeRemote: true)`, a network
    /// revoke call) that this host-test binary cannot drive deterministically
    /// — this seam isolates exactly the state-reset behavior
    /// `applyCompletedSignOutState()` itself owns, including this task's
    /// `resetTodayOwnerState()` call, the same way `scheduleBookingTestReloadReviewRequests`
    /// isolates a different private activation method elsewhere in this file.
    /// Production never calls this directly.
    func testApplyCompletedSignOutState() {
        applyCompletedSignOutState()
    }

    /// Test-only (final-review I6): forces the auth gate to a given state
    /// (e.g. `.accountMismatch`) while a real pull is suspended, so the
    /// exact-workspace publish guard can be driven through the real
    /// `pullDeltaIfPossible` commit path. Production never calls this.
    func testSetAuthenticationGateState(_ state: NativeAuthenticationGateState) {
        authenticationGateState = state
    }

    /// Test-only (task 11.12 fix round 3): runs the post-commit recurring
    /// generation the initial-sync task calls once its gate advances (that
    /// task is not drivable in the host binary). Production never calls this.
    func testRunRecurringGenerationAfterInitialSync() {
        runRecurringGenerationAfterInitialSync()
    }

    /// Test-only (task 11.12): runs the real `pullDeltaIfPossible`, the pull
    /// closure `syncCoordinatorIfConfigured` hands the coordinator. The
    /// poor-network suite builds that same coordinator around it, because
    /// the host harness has no `BuildEnvironment`. Production never calls this.
    func testPullDeltaIfPossible() async -> NativeSyncPullResult {
        await pullDeltaIfPossible()
    }

    /// Test-only (Phase 12 12.00b.2-K fix round 1, review M3): whether the
    /// booking-intake pull mark is current, so a pass could convert now. The
    /// paywall's exit, the gate-open point the mark rule protects, needs a
    /// RevenueCat key this host binary does not have, so the host tests walk
    /// the gate through its states and read the mark. Production never calls
    /// this.
    var testBookingIntakePullCommitted: Bool { bookingIntakePullCommitted }

    /// Test-only (Phase 12 final review M1/M2): whether the recovery pull
    /// mark is current, so a pass could merge a booking or portal mirror now.
    /// Production never calls this.
    var testScheduleBookingRecoveryPullCommitted: Bool { scheduleBookingRecoveryPullCommitted }

    /// Test-only (task 11.05): seeds a NATIVE-ONLY signed-in owner: no
    /// migrated RN owner proof (`isMigratedLocalOwnerVerified == false`,
    /// `migratedAccountBinding == nil`), which is what every real account now
    /// is. The §2.5 predicate `O` then holds only when a completed workspace
    /// document bound to `binding` is on disk. Production never calls this.
    func testSeedNativeSignedInOwner(subject: String, binding: String) {
        authenticatedUserSubject = subject
        verifiedAccountBinding = binding
        isMigratedLocalOwnerVerified = false
        migratedAccountBinding = nil
        authenticationGateState = .signedIn(email: nil)
    }

    /// Test-only (task 11.08): runs the real shared tail of the three
    /// interactive sign-in paths (`finishInteractiveSignIn`) with a verified
    /// live outcome, as `signIn`/Apple/Google do after their provider call.
    /// The provider calls themselves need the network and Keychain, which
    /// this host-test binary cannot drive. Production never calls this.
    /// `landingGate` replaces the `.signedIn` landing (for example
    /// `.accountMismatch`) to pin what the sign-in emits there.
    func testFinishInteractiveSignIn(
        subject: String,
        binding: String,
        email: String,
        method: NativeAnalyticsEvent.SignInMethod,
        landingGate: NativeAuthenticationGateState? = nil
    ) {
        let outcome = NativeAuthenticatedIdentityActivationOutcome(
            accountState: .noAccountState,
            newlyStagedCount: 0,
            alreadyStagedCount: 0,
            typedAccountState: nil,
            localOwnerVerified: true,
            accountBinding: binding,
            verifiedAccountBinding: binding,
            verifiedUserSubject: subject,
            verifiedEmail: email,
            verificationSource: .live
        )
        finishInteractiveSignIn(
            outcome, email: email, method: method, gateOverride: landingGate ?? .signedIn(email: email)
        )
    }

    /// Test-only (Phase 12, L286.4): runs the real tail of `signUp`'s
    /// immediate-session branch (`bindInteractiveOwner`) with a verified live
    /// outcome, as `signUp` does after `installVerifiedSession`. The provider
    /// call needs the network, which this host-test binary cannot drive.
    /// Production never calls this.
    func testBindSignedUpOwner(subject: String, binding: String, email: String) {
        let outcome = NativeAuthenticatedIdentityActivationOutcome(
            accountState: .noAccountState,
            newlyStagedCount: 0,
            alreadyStagedCount: 0,
            typedAccountState: nil,
            localOwnerVerified: true,
            accountBinding: binding,
            verifiedAccountBinding: binding,
            verifiedUserSubject: subject,
            verifiedEmail: email,
            verificationSource: .live
        )
        bindInteractiveOwner(outcome, email: email, gateOverride: .signedIn(email: email))
    }

    /// Test-only (Phase 12.00b.2-E, L237.d): runs the real "returning user,
    /// previously completed sync" tail of `applyAuthenticatedIdentityOutcome`
    /// — the branch `activateMigratedAuthenticatedIdentity()` reaches on a
    /// cold app-open once a prior sync has already completed for this
    /// subject, mirroring RN's session-mount `useEffect`
    /// (`context/AuthContext.tsx:101-104`, which calls
    /// `checkAndGenerateRecurringJobs` AND `checkAndGenerateRecurringInvoices`
    /// together). Marks the initial sync completed for `subject` first, since
    /// only a real prior sync (or the offline-fallback branch) would have
    /// before this runs. The real reactivation needs a configured Supabase
    /// build, which this host-test binary does not have. Production never
    /// calls this.
    func testActivateReturningUserSession(subject: String, binding: String) {
        initialSyncCompletedSubject = subject
        let outcome = NativeAuthenticatedIdentityActivationOutcome(
            accountState: .noAccountState,
            newlyStagedCount: 0,
            alreadyStagedCount: 0,
            typedAccountState: nil,
            localOwnerVerified: true,
            accountBinding: binding,
            verifiedAccountBinding: binding,
            verifiedUserSubject: subject,
            verifiedEmail: nil,
            verificationSource: .live
        )
        applyAuthenticatedIdentityOutcome(outcome, email: nil)
    }

    /// Test-only (Phase 12, L286.7): runs the real teardown the four
    /// session-rejected catches of `activateMigratedAuthenticatedIdentity`
    /// share. That activation needs a configured Supabase build, which this
    /// host-test binary does not have. Production never calls this.
    func testApplyRejectedSessionState() {
        applyRejectedSessionState()
    }

    /// Test-only (task 11.08 fix round 1): the real pull-to-refresh tail with
    /// `duringSync` standing in for the network sync, so a test can sign out
    /// or switch owner while the sync is suspended.
    @discardableResult
    func testPerformPullToRefresh(
        screen: NativeAnalyticsEvent.RefreshScreen?,
        duringSync: () async -> Void
    ) async -> NativeSyncOutcome? {
        await performPullToRefresh(screen: screen) {
            await duringSync()
            return nil
        }
    }

    /// Test-only (task 11.08): the analytics boundary `deleteAccount` applies
    /// once the server confirms the deletion (its network call cannot run
    /// here). Production never calls this.
    func testApplyAccountDeletionAnalyticsBoundary() {
        applyAnalyticsIdentityBoundary()
    }

    /// Test-only (Phase 12 12.00b.1 review fix round 1, M6): the local scrub
    /// `deleteAccount` runs once the server confirms the deletion (its
    /// network call cannot run here). Production never calls this.
    func testRunAccountDeletionLocalScrub() throws {
        try performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .all)
    }

    /// Test-only (Phase 12 12.00b.2-G fix round 1, P12-006): `deleteAccount`
    /// after its server call (which cannot run here): the real local half,
    /// its failure handling included, under the same account-operation flag.
    /// Production never calls this.
    func testFinishAccountDeletionLocally() async throws {
        guard !authenticationOperationInFlight else { throw NativeAccountDeletionError.rejected }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        defer { widgetMirrorSuspendedForAccountBoundary = false }
        try await finishAccountDeletionLocally()
    }

    /// Test-only (Phase 12, G6-Q1): binds a verified outcome through the real
    /// shared tail of the interactive sign-ins and sign-up
    /// (`bindInteractiveOwner`), with no landing override, so the real
    /// exact-owner and workspace-adoption gates decide. The provider calls
    /// before it need the network. Production never calls this.
    func testBindInteractiveOwner(_ outcome: NativeAuthenticatedIdentityActivationOutcome, email: String?) {
        bindInteractiveOwner(outcome, email: email)
    }

    /// Test-only (Phase 12, G6-Q1): applies a verified outcome exactly as a
    /// launch's `activateMigratedAuthenticatedIdentity` does with no password
    /// recovery pending (`allowUnboundWorkspaceAdoption: true`). That path
    /// needs a configured Supabase build, which this host binary does not
    /// have. Production never calls this.
    func testApplyLaunchIdentityOutcome(_ outcome: NativeAuthenticatedIdentityActivationOutcome) {
        applyAuthenticatedIdentityOutcome(outcome, email: nil, allowUnboundWorkspaceAdoption: true)
    }

    /// Test-only (Phase 12 12.00b.2-G fix round 1, R31): the identity check a
    /// scene activation runs (`activateMigratedAuthenticatedIdentity` past its
    /// guards: the shared `completeIdentityActivation`), with an injected
    /// activator and not the initial check. `recoveryState` stands for the
    /// password-recovery state the public entry reads from the Keychain (fix
    /// round 2: nil, none pending, unless a test passes one). The public entry
    /// needs a configured Supabase build, which this host binary does not
    /// have. Production never calls this.
    func testRunIdentityActivation(
        _ activator: NativeAuthenticatedIdentityActivator,
        recoveryState: NativePasswordRecoveryState? = nil
    ) async {
        guard !authenticationOperationInFlight, !identityActivationInFlight else { return }
        identityActivationInFlight = true
        defer { finishIdentityActivation() }
        authenticatedIdentityActivator = activator
        await completeIdentityActivation(activator, recoveryState: recoveryState, isInitialCheck: false)
    }

    /// Test-only (Phase 12 12.00b.2-G, Task 9b review M1): the real
    /// `markInitialSyncCompleted` an initial sync runs once its pull commits.
    /// Its once-per-account backfill queues the local workspace for the push,
    /// so a host test can check what would be sent under the new account. The
    /// pull before it needs the network. Production never calls this.
    func testMarkInitialSyncCompleted(subject: String) {
        markInitialSyncCompleted(subject: subject)
    }

    /// Test-only (task 11.09): feeds one sync-coordinator status through the
    /// real `statusChanged` handler (the coordinator needs a configured
    /// Supabase project that this host binary does not have). Production
    /// never calls this.
    func testApplySyncStatus(_ status: NativeSyncStatus) {
        applySyncStatus(status)
    }

    /// Test-only (12.00b.1): the rejected-change settle step
    /// `syncCoordinatorIfConfigured` hands the coordinator. The poor-network
    /// harness builds that same coordinator around it. Production never
    /// calls this.
    func testSettleRejectedChanges(_ settlement: NativeMutationPushSettlement) throws {
        try settleRejectedChanges(settlement)
    }

    /// Test-only (Phase 12 12.06): the sync coordinator this build would
    /// configure from BuildEnvironment, which this host binary does not have.
    /// The rollback-readiness host tests wire it exactly as
    /// `syncCoordinatorIfConfigured` does, so the real drain runs through it.
    /// Production never calls this.
    func testUseSyncCoordinator(_ coordinator: NativeSyncCoordinator) {
        syncCoordinator = coordinator
        syncStatus = coordinator.status()
    }

    /// Test-only (Phase 12 12.06): the real rollback-readiness check with
    /// `afterDrain` run once its real drain returns, while the check is
    /// still suspended, so a test can sign out or switch the owner there.
    /// Production never calls this.
    @discardableResult
    func testPrepareRollbackReadiness(
        afterDrain: () async -> Void
    ) async -> NativeRollbackReadinessCheck? {
        await prepareRollbackReadiness {
            let outcome = await self.drainForRollbackReadiness()
            await afterDrain()
            return outcome
        }
    }

    /// Test-only (Phase 12 12.06 fix round 1): the private flags
    /// `rollbackReadiness()` fails closed on that no host path sets alone
    /// (a blocked scrub keeps its marker, a blocked migration also blocks
    /// writes, cleanup-pending mirrors a pending boundary step: each of which
    /// the check also reads).
    enum TestRollbackReadinessFlag: String, CaseIterable {
        case accountSwitchInFlight, authenticationOperationInFlight, identityActivationInFlight
        case accountScrubBlocked, accountDeletionPendingWithoutMarker, accountDeletionRecordUnverified
        case widgetMirrorSuspended, boundaryCleanupPending, legacyMigrationBlocked
    }

    /// Test-only (Phase 12 12.06 fix round 1): sets one of those flags, so
    /// the table-driven fail-closed test isolates each condition. Production
    /// never calls this.
    func testSetRollbackReadinessFlag(_ flag: TestRollbackReadinessFlag, _ value: Bool) {
        switch flag {
        case .accountSwitchInFlight: accountSwitchInFlight = value
        case .authenticationOperationInFlight: authenticationOperationInFlight = value
        case .identityActivationInFlight: identityActivationInFlight = value
        case .accountScrubBlocked: isAccountScrubBlocked = value
        case .accountDeletionPendingWithoutMarker: accountDeletionPendingWithoutMarker = value
        case .accountDeletionRecordUnverified: accountDeletionRecordUnverified = value
        case .widgetMirrorSuspended: widgetMirrorSuspendedForAccountBoundary = value
        case .boundaryCleanupPending: isAccountBoundaryCleanupPending = value
        case .legacyMigrationBlocked: isLegacyMigrationBlocked = value
        }
    }

    /// Test-only (task 11.05): runs the real widget/Siri replay trigger body
    /// (the same private method every production trigger calls).
    /// Production never calls this.
    func testReplayWidgetActions() {
        replayVerifiedWidgetActionsIfPossible()
    }

    /// Test-only: clears the seeded owner identity (simulates sign-out for
    /// stale-response/account-switch coverage).
    func scheduleBookingTestClearOwner() {
        authenticatedUserSubject = nil
        verifiedAccountBinding = nil
        isMigratedLocalOwnerVerified = false
        authenticationGateState = .signedOut
    }

    /// Test-only (task 10.09 fix round 1): injects a minimal
    /// `NativeAuthenticatedIdentityActivator` so `useAnotherAccount()` can be
    /// exercised for real without a live Supabase configuration.
    /// `useAnotherAccount()`'s success path only ever calls
    /// `activator.clearSession()` (Keychain-only; no network, no App Group
    /// filesystem access), so the injected verifier below is never actually
    /// invoked — it exists only to satisfy the activator's initializer.
    /// Production never calls this.
    func scheduleBookingTestSeedIdentityActivator() {
        struct NoopVerifier: NativeAuthenticatedIdentityVerifying {
            func verify(sessionBytes: Data) async throws -> NativeVerifiedAuxiliaryIdentity {
                throw NativeAuthenticatedIdentityError.temporarilyUnavailable
            }
        }
        authenticatedIdentityActivator = NativeAuthenticatedIdentityActivator(
            snapshotURL: fileURL,
            sessionStore: secureSettingsStore,
            verifier: NoopVerifier()
        )
    }

    /// Test-only (task 10.08): links an invoice to a job at the canonical
    /// layer (`invoice.jobId`), the field the editable `Invoice` view model
    /// does not expose (real linkage goes through `commitInvoiceFromJob`'s
    /// job-status-gated flow instead). Lets a schedule-key test change ONLY
    /// the linked job's status and observe its effect on `inv_` dunning
    /// eligibility without exercising the full invoice-creation flow.
    /// Production never calls this.
    @discardableResult
    func scheduleBookingTestLinkInvoiceToJob(invoiceID: String, jobID: String) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        var updated = snapshot
        var records = updated.payload.invoices ?? []
        guard let index = records.firstIndex(where: { $0.id == invoiceID }) else { return false }
        records[index].jobId = jobID
        updated.payload.invoices = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch { return false }
        return true
    }

    /// Test-only (task 10.08): the canonical `recurringInvoiceId`/
    /// `occurrenceNumber` linkage the view-model `Invoice` does not expose.
    /// Mirrors exactly what `requestRecurringInvoiceReview` resolves, so a
    /// test can assert the tap-routing result against ground truth without
    /// reaching into the private `snapshot`. Production never calls this.
    func scheduleBookingTestLatestGeneratedInvoiceID(ruleID: String) -> String? {
        (snapshot.payload.invoices ?? [])
            .filter { $0.recurringInvoiceId == ruleID }
            .max { ($0.occurrenceNumber ?? 0) < ($1.occurrenceNumber ?? 0) }?
            .id
    }
}

/// Minimal `Any`-free codable box for building a portal display value from
/// validated fields without inventing unknown content.
private struct AnyCodableValue: Codable {
    let string: String?
    let bool: Bool?

    init(_ string: String) { self.string = string; self.bool = nil }
    init(_ bool: Bool) { self.string = nil; self.bool = bool }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        string = try? container.decode(String.self)
        bool = try? container.decode(Bool.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string { try container.encode(string) }
        else if let bool { try container.encode(bool) }
    }
}
