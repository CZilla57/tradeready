import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

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
    @Published private(set) var pendingAppointmentConfirmationJobID: String?
    @Published private(set) var pendingReviewRequestJobID: String?
    @Published private(set) var pendingEstimateFollowUpJobID: String?
    @Published var migrationMessage: String?
    @Published private(set) var launchMigrationNotice: LegacyLaunchMigrationNotice?
    @Published private(set) var isLegacyMigrationBlocked = false
    @Published private(set) var isAccountScrubBlocked = false
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
    /// Task 10.12 (ruling R5): no-op by default; Phase 11.08 owns transport.
    private let analytics: NativeAnalytics
    /// One bounded, non-PII diagnostic per session per store (brief step 5) —
    /// tracks which stores have already logged their fail-closed diagnostic
    /// so a persistently-corrupt file does not spam.
    private var loggedFailClosedDiagnostics: Set<String> = []
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
    private let appGroupAccountScrubber: NativeAppGroupAccountScrubber
    private var snapshot = Canonical.Snapshot(payload: .init())
    private var isApplyingProjection = false
    private var persistenceWritesBlocked = false
    private var persistenceBlockReason: PersistenceBlockReason?
    private var persistenceBlockDetail: String?
    private var didCheckMigratedAuthenticatedIdentity = false
    private var authenticatedIdentityActivator: NativeAuthenticatedIdentityActivator?
    private var authenticationOperationInFlight = false
    private var identityActivationInFlight = false
    private var identityActivationWaiters: [CheckedContinuation<Void, Never>] = []
    private var didConsumeVerifiedPendingOpenURL = false
    private var migratedAccountBinding: String?
    private var verifiedAccountBinding: String?
    private var authenticatedUserSubject: String?
    private var authenticatedEmail: String?
    private let widgetActionReplayTransport: NativeWidgetActionClaimTransport?
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
    /// Task 8.08 test seam: explicit session bytes for owner transports.
    /// Production passes nil and reads the Keychain; tests inject bytes so
    /// owner rechecks and service calls exercise without a live session.
    var scheduleBookingSessionOverride: Data?
    /// Task 8.08 test seam: explicit sync credentials so the verified-pull
    /// half of intake exercises without a live Keychain session.
    var scheduleBookingTestCredentials: NativeSyncCredentials?

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

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "TradeReadyNative", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(
            fileURL: directory.appending(path: "store.json"),
            seedIfMissing: false,
            automaticallyMigrateLegacyData: true
        )
    }

    /// Injectable persistence location for integration tests and previews.
    init(
        fileURL: URL,
        seedIfMissing: Bool = true,
        automaticallyMigrateLegacyData: Bool = false,
        legacyMigrationSource: LegacyMigrationSource? = nil,
        widgetActionReplayTransport: NativeWidgetActionClaimTransport? = nil,
        appGroupAccountScrubber: NativeAppGroupAccountScrubber = .init(),
        initialSyncService: (any NativeInitialSyncServing)? = nil,
        subscriptionService: NativeSubscriptionServing? = nil,
        jobPhotoTransferService: (any NativeJobPhotoTransferring)? = nil,
        estimateApprovalLinkService: (any NativeEstimateApprovalLinking)? = nil,
        changeOrderApprovalLinkService: (any NativeChangeOrderApprovalLinking)? = nil,
        invoiceDeliveryService: (any NativeInvoiceDelivering)? = nil,
        advisoryAITransport: (any NativeAdvisoryAITransport)? = nil,
        analytics: NativeAnalytics = NativeNoOpAnalytics()
    ) {
        self.analytics = analytics
        self.fileURL = fileURL
        self.repository = Canonical.SnapshotRepository(primaryURL: fileURL)
        self.widgetActionReplayTransport = widgetActionReplayTransport ?? (try? .live())
        self.appGroupAccountScrubber = appGroupAccountScrubber
        self.initialSyncService = initialSyncService
        self.subscriptionService = subscriptionService ?? NativeRevenueCatSubscriptionService()
        self.injectedJobPhotoTransferService = jobPhotoTransferService
        self.injectedEstimateApprovalLinkService = estimateApprovalLinkService
        self.injectedChangeOrderApprovalLinkService = changeOrderApprovalLinkService
        self.injectedInvoiceDeliveryService = invoiceDeliveryService
        self.advisoryAITransport = advisoryAITransport ?? NativeAITransport.live()
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
        self.syncStatus = NativeSyncStatus(pendingCount: self.mutationQueue.load().count)
        var accountScrubRecoveryError: Error?
        if let pendingScope = repository.pendingAccountScrubScope {
            do {
                try appGroupAccountScrubber.scrub()
                switch pendingScope {
                case .live: try repository.removeLiveAccountData()
                case .all: try repository.removeAllAccountData()
                }
                try mutationQueue.removeAll()
                try syncBackfill.removeAll()
                try syncCursorStore.removeAll()
                try customerDuplicateDismissalStore.removeAll()
                try reviewRequestStore.removeAll()
                try reminderPromptStore.removeAll()
                try insightMuteStore.removeAll()
                try setupChecklistStore.removeAll()
                try removeImportHistory()
                try pendingScheduleBookingWorkStore().removeAll()
                let sessionStore = NativeKeychainSecureSettingsStore()
                switch pendingScope {
                case .live: try sessionStore.clearAccountValues()
                case .all: try sessionStore.clearAllValues()
                }
                try repository.finishAccountScrub()
                NativeGoogleSignInProvider.clearLocalCredential()
            } catch {
                accountScrubRecoveryError = error
            }
        }
        let hadNativeSnapshot = FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: repository.backupURL.path)
        var launchOutcome: LegacyMigrationOutcome?
        var launchError: Error?
        if automaticallyMigrateLegacyData && accountScrubRecoveryError == nil {
            do {
                let journalStatus = try migrationJournal.read().entries.last {
                    $0.migration == .reactNativeAsyncStorage
                }?.status
                let shouldAttempt = !hadNativeSnapshot
                    || journalStatus == .started
                    || journalStatus == .failed
                if shouldAttempt {
                    let coordinator = LegacyMigrationCoordinator(repository: repository, journal: migrationJournal)
                    launchOutcome = if let legacyMigrationSource {
                        try coordinator.migrate(currentSettings: settings, source: legacyMigrationSource)
                    } else {
                        try coordinator.migrate(currentSettings: settings)
                    }
                }
            } catch {
                launchError = error
            }
        }

        let completedWithoutSnapshot = launchOutcome?.status == .alreadyCompleted && !hadNativeSnapshot
        if accountScrubRecoveryError == nil {
            load(seedIfMissing: seedIfMissing && launchError == nil && !completedWithoutSnapshot)
        } else {
            applyEmptySnapshot()
            persistenceWritesBlocked = true
            persistenceBlockReason = .accountScrub
            persistenceBlockDetail = nil
            isAccountScrubBlocked = true
            migrationMessage = "A previous sign-out could not be safely completed. Local data remains hidden until cleanup succeeds."
        }
        applyLaunchMigrationState(
            outcome: launchOutcome,
            error: launchError,
            hadNativeSnapshot: hadNativeSnapshot || FileManager.default.fileExists(atPath: repository.backupURL.path)
        )
        syncStatus = NativeSyncStatus(pendingCount: mutationQueue.load().count)
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
                seedIfMissing ? seedDemoData() : applyEmptySnapshot()
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
        repository.diagnostics(for: try repository.load(), journal: try migrationJournal.read())
    }

    /// Creates a metadata-only JSON report that the user can explicitly share
    /// with support. The closed report schema excludes customer records,
    /// identifiers, file paths, errors, credentials, sessions, and raw values.
    func createPersistenceSupportReport(appVersion: String? = nil) throws -> URL {
        let resolvedVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let data = try persistenceDiagnostics().encodedSupportReport(appVersion: resolvedVersion)
        let reportURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("tradeready-support-report.json")
        try data.write(to: reportURL, options: .atomic)
        return reportURL
    }

    @discardableResult
    func upsert(_ value: Customer) -> Bool {
        guard ensurePersistenceWritable() else { return false }
        do {
            var updated = snapshot
            var records = updated.payload.customers ?? []
            let result: Canonical.Customer
            if let baseline = records.first(where: { $0.id == value.id }) {
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = value
                result = try CanonicalUIAdapters.canonical(from: edit)
            } else { result = try CanonicalUIAdapters.canonical(from: value) }
            replaceOrAppend(result, in: &records, id: \Canonical.Customer.id)
            updated.payload.customers = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "customers", recordId: result.id, record: result)
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
        let jobStatusByID = Dictionary(
            uniqueKeysWithValues: (snapshot.payload.jobs ?? []).map { ($0.id, $0.status) })
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
            uniqueKeysWithValues: (snapshot.payload.jobs ?? []).map { ($0.id, $0.title) })
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
        let paidByID = Dictionary(uniqueKeysWithValues: invoices.map { ($0.id, $0.isPaid) })
        let jobStatusByID = Dictionary(
            uniqueKeysWithValues: (snapshot.payload.jobs ?? []).map { ($0.id, $0.status) })
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

    func markReviewRequestSent(jobID: String, fallback: NativeReviewRequestFallbackContact?, now: Date = .now) {
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

    func requestEstimateFollowUpReview(jobID: String) {
        let job = snapshot.payload.jobs?.first { $0.id == jobID }
        guard NativeEstimateFollowUp.canOpenNotification(
            exactOwnerWorkspace: hasExactSignedInWorkspace,
            signedIn: isSignedIn,
            job: job
        ), estimateFollowUpDraft(jobID: jobID) != nil
        else { return }
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
    func refreshStripeStatus() async {
        guard let service = configuredStripeConnectService(), let credentials = currentSyncCredentials() else {
            stripeConnectError = "Stripe status is unavailable until the backend is configured and you are signed in."
            return
        }
        stripeConnectLoading = true
        defer { stripeConnectLoading = false }
        do {
            stripeConnectStatus = try await service.status(sessionBytes: credentials.sessionBytes)
            stripeConnectError = nil
            markSetupTaskDoneIfStripeConnected()
        } catch NativeStripeConnectError.rejectedSession {
            guard await refreshSyncSession(), let retry = currentSyncCredentials() else {
                stripeConnectError = "Your session expired. Sign in again to check the Stripe connection."
                return
            }
            do {
                stripeConnectStatus = try await service.status(sessionBytes: retry.sessionBytes)
                stripeConnectError = nil
                markSetupTaskDoneIfStripeConnected()
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
    private func markSetupTaskDoneIfStripeConnected() {
        guard stripeConnectStatus?.connected == true else { return }
        markSetupTaskDone(.stripe)
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

    /// Phase 7 bulk settlement: resolves the latest selected records and
    /// settles every applicable invoice plus its job reconciliation in ONE
    /// canonical snapshot save. Already-paid and missing records are skipped
    /// and reported, never failed. Settlement IDs are stable per
    /// (invoice, day) so a repeated run cannot double-record.
    @discardableResult
    func commitBulkSettleInvoices(ids: [String], on date: Date = .now) -> (settled: [Invoice], skipped: Int) {
        guard ensurePersistenceWritable() else { return ([], ids.count) }
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
        guard !settledCanonical.isEmpty else { return ([], skipped) }
        do {
            snapshot.payload.invoices = invoiceRecords
            var jobRecords = snapshot.payload.jobs ?? []
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
            snapshot.payload.jobs = jobRecords
            try repository.save(snapshot)
            try apply(snapshot)
            for record in settledCanonical {
                enqueueUpsert(table: "invoices", recordId: record.id, record: record)
            }
            for jobID in advancedJobIDs {
                guard let record = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { continue }
                enqueueUpsert(table: "jobs", recordId: jobID, record: record)
            }
            return (settledPublished, skipped)
        } catch {
            migrationMessage = "Could not mark the invoices paid: \(error.localizedDescription)"
            return ([], ids.count)
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
        snapshot.payload.invoices = records
        refreshAndSave()
        if let record = snapshot.payload.invoices?.first(where: { $0.id == invoiceID }) {
            enqueueUpsert(table: "invoices", recordId: record.id, record: record)
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
        return stampEstimateSent(id: id, from: expectedStatus, on: date)
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

        return stampEstimateSent(id: review.jobID, from: currentStatus, on: date)
            ? .recorded
            : .failed
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
        mutateChangeOrderJob(jobID: jobID) { job in
            try NativeChangeOrders.applyingManualDecision(
                decision,
                to: changeOrderID,
                in: job,
                note: note,
                decidedAt: NativeChangeOrders.recordDateString(for: date)
            )
        }
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
        mutateJob(jobID: jobID) { job in
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
            replaceOrAppend(result, in: &records, id: \Canonical.Job.id)
            updated.payload.jobs = records
            try repository.save(updated)
            try apply(updated)
            enqueueUpsert(table: "jobs", recordId: result.id, record: result)
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
            snapshot.payload.invoices = records; refreshAndSave()
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
                snapshot.payload.invoices = records
                try repository.save(snapshot)
                try apply(snapshot)
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
            snapshot.payload.invoices = records
            try repository.save(snapshot)
            try apply(snapshot)
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
            snapshot.payload.expenses = records; refreshAndSave()
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
        _ = runRecurringJobGeneration()
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
        return commitInvoicePayment(current.applying(payment))
    }

    @discardableResult
    func settleInvoice(invoiceID: String, on date: Date = .now, paymentID: String) -> Result<Invoice, NativeInvoiceEditRefusal> {
        guard let current = invoices.first(where: { $0.id == invoiceID }) else {
            return .failure(.missingRecord)
        }
        // Already settled: idempotent no-op so a repeated submit is safe.
        if current.isPaid { return .success(current) }
        return commitInvoicePayment(current.settlingRemaining(on: date, paymentID: paymentID))
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
        return commitInvoicePayment(current.voidingPayment(id: paymentID, on: date))
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
        return upsert(job)
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
        snapshot.payload.expenses?.removeAll { $0.id == id }; refreshAndSave()
        if existed { enqueueDelete(table: "expenses", recordId: id) }
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

    func handle(url: URL) {
        if let recoveryLink = NativePasswordRecoveryLink.parse(url) {
            Task { await handlePasswordRecoveryLink(recoveryLink) }
            return
        }
        guard let route = NativeDeepLinkParser.parse(url.absoluteString),
              jobs.contains(where: { $0.id == route.jobID })
        else { return }
        switch route {
        case .job(let id): routeToJob(id)
        case .onMyWay(let id): routeToOnMyWay(id)
        }
    }

    func importLegacyData() {
        do {
            let coordinator = LegacyMigrationCoordinator(
                repository: repository,
                journal: migrationJournal
            )
            let result = try coordinator.migrate(currentSettings: settings)
            switch result.status {
            case .noData:
                migrationMessage = "No React Native AsyncStorage data was found on this installation."; return
            case .alreadyCompleted:
                migrationMessage = "React Native data was already imported."; return
            case .nativeSnapshotConflict:
                migrationMessage = "Previous-app data was found, but this app already has data. Nothing was changed."
                launchMigrationNotice = .conflict
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
        do {
            let outcome = try LegacyMigrationCoordinator(
                repository: repository,
                journal: migrationJournal
            ).migrate(currentSettings: settings)
            if outcome.status == .migrated { load(seedIfMissing: false) }
            applyLaunchMigrationState(outcome: outcome, error: nil, hadNativeSnapshot: false)
        } catch {
            applyLaunchMigrationState(outcome: nil, error: error, hadNativeSnapshot: false)
        }
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
        let priorAccountState = authenticatedAccountState
        let priorGateState = authenticationGateState
        let hadVerifiedSubject = authenticatedUserSubject != nil
        let hadVerifiedBinding = verifiedAccountBinding != nil
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

        authenticatedAccountState = .checking
        if isInitialCheck { authenticationGateState = .loading }
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
                verifier: verifier,
                refresher: verifier
            )
            authenticatedIdentityActivator = created
            activator = created
        }
        do {
            let outcome = try await activator.activate()
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
            authenticatedAccountState = .sessionRejected
            authenticationGateState = .signedOut
        } catch NativeAuthenticatedIdentityError.malformedStoredSession {
            authenticatedAccountState = .sessionRejected
            authenticationGateState = .signedOut
        } catch NativeAuthenticatedIdentityError.missingAccessToken {
            authenticatedAccountState = .sessionRejected
            authenticationGateState = .signedOut
        } catch NativeAuthenticatedIdentityError.missingRefreshToken {
            authenticatedAccountState = .sessionRejected
            authenticationGateState = .signedOut
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
        // A verified provider session can still be rejected by the exact-owner
        // gate. Clear Google's Keychain-backed app credential on every exit so
        // the next attempt can actually select a different Google account.
        defer { clearGoogleCredential() }
        guard let activator = authenticatedIdentityActivator else {
            authenticationGateState = .signedOut
            return
        }
        do {
            try await activator.clearSession()
            await subscriptionService.logOut()
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
            // Task 10.09 (B1): account boundary — clear the owner-scoped
            // cached snapshot (never the observer registrations; the 11.01
            // widget mirror registers once and must keep receiving the next
            // owner's publishes after sign-in).
            derivedStatePublisher.reset()
            // Task 10.12 (S4/D4/D5): account boundary — wipe the mute/
            // checklist stores (device-local, owner-scoped) and their
            // in-memory published state so the next account never inherits
            // a dismissal, snooze, or "used once" flag.
            insightMutes = nil
            setupChecklistState = nil
            pendingCoachPrefill = nil
            pendingSettingsDestination = nil
            try? insightMuteStore.removeAll()
            try? setupChecklistStore.removeAll()
            lastShownInsightIDsKey = ""
            notificationsGranted = false
        } catch {
            authenticationGateState = .unavailable
        }
    }

    func signIn(email: String, password: String) async throws {
        guard !authenticationOperationInFlight else {
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
        didCheckMigratedAuthenticatedIdentity = true
        applyAuthenticatedIdentityOutcome(outcome, email: session.email)
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
            didCheckMigratedAuthenticatedIdentity = true
            applyAuthenticatedIdentityOutcome(outcome, email: session.email)
        }
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
        didCheckMigratedAuthenticatedIdentity = true
        applyAuthenticatedIdentityOutcome(outcome, email: session.email)
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
        didCheckMigratedAuthenticatedIdentity = true
        applyAuthenticatedIdentityOutcome(outcome, email: session.email)
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
        let sessionStore = NativeKeychainSecureSettingsStore()
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
        try? await configured.client.revoke(sessionBytes: session)
        try await configured.activator.clearSession()
        try recoveryStore.clear()
        applyRecoverySignedOutState()
    }

    func cancelPasswordRecovery() async {
        guard !authenticationOperationInFlight else { return }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }
        let sessionStore = NativeKeychainSecureSettingsStore()
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

    func dismissInvalidPasswordRecovery() async {
        let recoveryStore = NativePasswordRecoveryStore()
        if (try? recoveryStore.read()?.activeUserSubject) != nil {
            try? NativeKeychainSecureSettingsStore().clearSupabaseSession()
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
            isSubscriptionTrialing = result.entitlement.isActive && result.entitlement.isTrialing
            guard result.entitlement.isActive else { return .noActiveSubscription }
            subscriptionGateGeneration &+= 1
            advancePastSubscriptionGate()
            return .completed
        } catch {
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
        authenticationGateState = .signedIn(email: authenticatedEmail)
        consumeVerifiedPendingOpenURLIfNeeded()
        replayVerifiedWidgetActionsIfPossible()
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

        let sessionStore = NativeKeychainSecureSettingsStore()
        if revokeRemote {
            do {
                let configured = try configuredAuthentication()
                if let session = try sessionStore.readSupabaseSession() {
                    try await configured.client.revoke(sessionBytes: session)
                }
            } catch {
                throw NativeAccountSignOutError.remoteRevocationFailed
            }
        }

        do {
            try performLocalAccountScrub(sessionStore: sessionStore, scope: .live)
        } catch {
            isAccountScrubBlocked = repository.isAccountScrubPending
            throw NativeAccountSignOutError.localScrubFailed
        }

        await subscriptionService.logOut()
        applyCompletedSignOutState()
        NativeGoogleSignInProvider.clearLocalCredential()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    func deleteAccount() async throws {
        guard !authenticationOperationInFlight else {
            throw NativeAccountDeletionError.rejected
        }
        authenticationOperationInFlight = true
        defer { authenticationOperationInFlight = false }

        let endpoint: URL
        do { endpoint = try BuildEnvironment.endpoint("api/delete-account", sendsUserData: true) }
        catch { throw NativeAccountDeletionError.invalidConfiguration }
        guard endpoint.host?.hasSuffix(".invalid") == false else {
            throw NativeAccountDeletionError.invalidConfiguration
        }
        let client = NativeAccountDeletionClient(endpoint: endpoint)
        let sessionStore = NativeKeychainSecureSettingsStore()

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

        do {
            try performLocalAccountScrub(sessionStore: sessionStore, scope: .all)
        } catch {
            // The server-side deletion is already authoritative. Hide all
            // in-memory account state until cleanup can be retried locally.
            persistenceWritesBlocked = true
            persistenceBlockReason = .accountScrub
            persistenceBlockDetail = nil
            isAccountScrubBlocked = true
            applyEmptySnapshot()
            throw NativeAccountSignOutError.localScrubFailed
        }
        await subscriptionService.logOut()
        applyCompletedSignOutState()
        NativeGoogleSignInProvider.clearLocalCredential()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    func retryAccountScrub() {
        guard repository.isAccountScrubPending else {
            isAccountScrubBlocked = false
            return
        }
        do {
            try appGroupAccountScrubber.scrub()
            switch repository.pendingAccountScrubScope ?? .live {
            case .live: try repository.removeLiveAccountData()
            case .all: try repository.removeAllAccountData()
            }
            try mutationQueue.removeAll()
            try syncBackfill.removeAll()
            try syncCursorStore.removeAll()
            try customerDuplicateDismissalStore.removeAll()
            try reviewRequestStore.removeAll()
            try reminderPromptStore.removeAll()
            try insightMuteStore.removeAll()
            try setupChecklistStore.removeAll()
            try removeImportHistory()
            let sessionStore = NativeKeychainSecureSettingsStore()
            switch repository.pendingAccountScrubScope ?? .live {
            case .live: try sessionStore.clearAccountValues()
            case .all: try sessionStore.clearAllValues()
            }
            try repository.finishAccountScrub()
            isAccountScrubBlocked = false
            applyCompletedSignOutState()
            NativeGoogleSignInProvider.clearLocalCredential()
        } catch {
            isAccountScrubBlocked = true
            migrationMessage = "Sign-out cleanup is still incomplete. No local account data was opened."
        }
    }

    private func applyCompletedSignOutState() {
        syncCoordinator?.reset()
        // Task 10.09 (B1): account boundary — clear the owner-scoped cached
        // snapshot only; observer registrations survive (the 11.01 widget
        // mirror registers once at launch and must keep receiving the next
        // owner's publishes after sign-in, not just the one active at
        // registration time).
        derivedStatePublisher.reset()
        isAccountScrubBlocked = false
        persistenceWritesBlocked = false
        persistenceBlockReason = nil
        persistenceBlockDetail = nil
        applyEmptySnapshot()
        selectedTab = .today
        todaySelectedDate = NativeTodayBriefing.todayDateString(now: Date())
        deepLinkedJobID = nil
        deepLinkedCustomerID = nil
        deepLinkedInvoiceID = nil
        pendingOnMyWayJobID = nil
        pendingEstimateFollowUpJobID = nil
        didConsumeVerifiedPendingOpenURL = false
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
        insightMutes = nil
        setupChecklistState = nil
        pendingCoachPrefill = nil
        pendingSettingsDestination = nil
        try? insightMuteStore.removeAll()
        try? setupChecklistStore.removeAll()
        lastShownInsightIDsKey = ""
        notificationsGranted = false
    }

    private func performLocalAccountScrub(
        sessionStore: NativeKeychainSecureSettingsStore,
        scope: Canonical.SnapshotRepository.AccountScrubScope
    ) throws {
        try repository.beginAccountScrub(scope: scope)
        try appGroupAccountScrubber.scrub()
        switch scope {
        case .live: try repository.removeLiveAccountData()
        case .all: try repository.removeAllAccountData()
        }
        // Pending local changes belong to the account being scrubbed. Removing
        // the queue before the scrub marker is cleared means a failure here
        // leaves the marker pending so the next launch retries, and no other
        // account can ever inherit and push this account's queued writes.
        try mutationQueue.removeAll()
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
        switch scope {
        case .live: try sessionStore.clearAccountValues()
        case .all: try sessionStore.clearAllValues()
        }
        try repository.finishAccountScrub()
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

    /// One bounded, non-PII diagnostic per session per store (brief step 5) —
    /// never the record contents, never the account binding, just which
    /// store degraded so a persistently-corrupt file does not spam.
    private func logInsightOrChecklistFailClosedDiagnosticOnce(store: String) {
        guard !loggedFailClosedDiagnostics.contains(store) else { return }
        loggedFailClosedDiagnostics.insert(store)
        #if DEBUG
        print("[TradeReady] \(store) store was unreadable this session; degraded fail-closed.")
        #endif
    }

    private func applyAuthenticatedIdentityOutcome(
        _ outcome: NativeAuthenticatedIdentityActivationOutcome,
        email: String?,
        gateOverride: NativeAuthenticationGateState? = nil,
        activateConsumers: Bool = true,
        allowUnboundWorkspaceAdoption: Bool = false
    ) {
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
                // every later sync generates in the pull hook.)
                refreshRecurringJobs()
                advancePastInitialSync(
                    outcome: outcome,
                    allowUnboundWorkspaceAdoption: !outcome.verificationSource.isOfflineFallback
                        && allowUnboundWorkspaceAdoption
                )
            } else {
                beginInitialSyncGate(
                    outcome: outcome,
                    allowUnboundWorkspaceAdoption: allowUnboundWorkspaceAdoption
                )
            }
        }
        if activateConsumers, case .signedIn = authenticationGateState {
            consumeVerifiedPendingOpenURLIfNeeded()
            replayVerifiedWidgetActionsIfPossible()
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
            return
        }
        guard let supabaseURL = BuildEnvironment.supabaseURL,
              let publishableKey = BuildEnvironment.supabasePublishableKey,
              let sessionBytes = try? NativeKeychainSecureSettingsStore().readSupabaseSession()
        else {
            authenticationGateState = .initialSyncUnavailable(
                message: NativeInitialSyncError.invalidConfiguration.localizedDescription
                    + "\n\nDiagnostic code: preflight/configuration-or-session"
            )
            return
        }
        let service = initialSyncService ?? NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL,
            publishableKey: publishableKey
        )
        initialSyncGateGeneration &+= 1
        let generation = initialSyncGateGeneration
        let subject = outcome.verifiedUserSubject
        let localSnapshot = snapshot
        authenticationGateState = .initialSyncLoading

        Task { [weak self] in
            do {
                let candidate = try await service.pull(
                    sessionBytes: sessionBytes,
                    expectedUserSubject: subject,
                    localSnapshot: localSnapshot
                )
                guard let self,
                      subject == self.authenticatedUserSubject,
                      generation == self.initialSyncGateGeneration
                else { return }

                let previous = self.snapshot
                do {
                    try self.apply(candidate)
                    try self.repository.save(self.snapshot)
                } catch {
                    try? self.apply(previous)
                    throw error
                }
                self.refreshRecurringJobs()
                self.markInitialSyncCompleted(subject: subject)
                self.advancePastInitialSync(
                    outcome: outcome,
                    allowUnboundWorkspaceAdoption: allowUnboundWorkspaceAdoption
                )
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
                if let binding = self.verifiedAccountBinding, subject == self.authenticatedUserSubject {
                    await self.derivedStatePublisher.publish(
                        canonical: self.snapshot, expectedOwnerBinding: binding
                    )
                }
            } catch {
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
            }
        }
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
            consumeVerifiedPendingOpenURLIfNeeded()
            replayVerifiedWidgetActionsIfPossible()
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
        if let baseline = snapshot.payload.settings {
            var edit = try CanonicalUIAdapters.edit(baseline)
            edit.value = updated
            snapshot.payload.settings = try CanonicalUIAdapters.canonical(from: edit)
        } else {
            snapshot.payload.settings = try CanonicalUIAdapters.canonical(from: updated)
        }
        try repository.save(snapshot)
        try apply(snapshot)
    }

    private func commitStartingPoint(_ document: NativeOnboardingDocument) throws {
        guard ensurePersistenceWritable() else { throw NativeOnboardingError.corruptState }
        switch document.stage {
        case .sampleCommit:
            guard let namespace = document.sampleNamespace,
                  let anchor = document.sampleAnchor
            else { throw NativeOnboardingError.corruptState }
            try mergeSampleData(namespace: namespace, anchor: anchor, trade: document.draft.trade)
        case .freshCommit:
            snapshot.payload.customers?.removeAll { Self.isNativeSampleID($0.id) }
            snapshot.payload.jobs?.removeAll { Self.isNativeSampleID($0.id) }
            snapshot.payload.invoices?.removeAll { Self.isNativeSampleID($0.id) }
            snapshot.payload.expenses?.removeAll { Self.isNativeSampleID($0.id) }
        default:
            throw NativeOnboardingError.corruptState
        }
        try repository.save(snapshot)
        try apply(snapshot)
    }

    private func mergeSampleData(
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
        var customerRecords = snapshot.payload.customers ?? []
        let canonicalCustomer: Canonical.Customer
        if let baseline = customerRecords.first(where: { $0.id == customer.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = customer
            canonicalCustomer = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalCustomer = try CanonicalUIAdapters.canonical(from: customer) }
        replaceOrAppend(canonicalCustomer, in: &customerRecords, id: \Canonical.Customer.id)

        var jobRecords = snapshot.payload.jobs ?? []
        let canonicalJob: Canonical.Job
        if let baseline = jobRecords.first(where: { $0.id == job.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = job
            canonicalJob = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalJob = try CanonicalUIAdapters.canonical(from: job) }
        replaceOrAppend(canonicalJob, in: &jobRecords, id: \Canonical.Job.id)

        var invoiceRecords = snapshot.payload.invoices ?? []
        let canonicalInvoice: Canonical.Invoice
        if let baseline = invoiceRecords.first(where: { $0.id == invoice.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = invoice
            canonicalInvoice = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalInvoice = try CanonicalUIAdapters.canonical(from: invoice) }
        replaceOrAppend(canonicalInvoice, in: &invoiceRecords, id: \Canonical.Invoice.id)

        var expenseRecords = snapshot.payload.expenses ?? []
        let canonicalExpense: Canonical.Expense
        if let baseline = expenseRecords.first(where: { $0.id == expense.id }) {
            var edit = try CanonicalUIAdapters.edit(baseline); edit.value = expense
            canonicalExpense = try CanonicalUIAdapters.canonical(from: edit)
        } else { canonicalExpense = try CanonicalUIAdapters.canonical(from: expense) }
        replaceOrAppend(canonicalExpense, in: &expenseRecords, id: \Canonical.Expense.id)

        snapshot.payload.customers = customerRecords
        snapshot.payload.jobs = jobRecords
        snapshot.payload.invoices = invoiceRecords
        snapshot.payload.expenses = expenseRecords
    }

    private static func isNativeSampleID(_ id: String) -> Bool {
        id.hasPrefix("native-sample-v1-")
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
        migratedAccountState = nil
        dismissedCustomerDuplicatePairKeys = []
        pendingCustomerMergeUndo = nil
        pendingRecordDeleteUndo = nil
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
        // Task 10.09 (B1): account boundary — clear the owner-scoped cached
        // snapshot only; observer registrations survive (see
        // `applyCompletedSignOutState`'s identical comment).
        derivedStatePublisher.reset()
        // Task 10.12 (S4/D4/D5): account boundary — wipe the mute/checklist
        // stores and their in-memory published state (see
        // `applyCompletedSignOutState`'s identical comment).
        insightMutes = nil
        setupChecklistState = nil
        pendingCoachPrefill = nil
        pendingSettingsDestination = nil
        try? insightMuteStore.removeAll()
        try? setupChecklistStore.removeAll()
        lastShownInsightIDsKey = ""
        notificationsGranted = false
    }

    /// Claims and commits bounded batches only after exact legacy-owner proof.
    /// The coordinator writes all affected canonical families once before it
    /// acknowledges shared input. Unsupported future actions remain durable.
    private func replayVerifiedWidgetActionsIfPossible() {
        guard isMigratedLocalOwnerVerified,
              let accountBinding = migratedAccountBinding,
              let widgetActionReplayTransport,
              ensurePersistenceWritable()
        else { return }
        let coordinator = NativeWidgetActionReplayCoordinator(
            transport: widgetActionReplayTransport,
            repository: repository
        )
        do {
            // Each claim contains at most 512 actions. Bound foreground work so
            // a continuously-writing extension cannot starve app activation.
            for _ in 0..<8 {
                switch try coordinator.replayNext(
                    snapshot: snapshot,
                    verifiedAccountBinding: accountBinding
                ) {
                case .nothingPending:
                    return
                case .retainedUnsupported(let count):
                    migrationMessage = "Kept \(count) newer widget action(s) for a compatible app update."
                    return
                case .committed(let committed, _, _):
                    try apply(committed)
                }
            }
        } catch {
            // A post-commit acknowledgement failure may leave memory one step
            // behind disk. Reload the verified canonical result before retry.
            if let loaded = try? repository.load() { try? apply(loaded.snapshot) }
            migrationMessage = "Widget actions are still safely queued and will be retried."
        }
    }

    private func consumeVerifiedPendingOpenURLIfNeeded(
        inbox: any NativeAppGroupInbox = NativeUserDefaultsAppGroupInbox(),
        now: Date = Date()
    ) {
        guard isMigratedLocalOwnerVerified, !didConsumeVerifiedPendingOpenURL else { return }
        didConsumeVerifiedPendingOpenURL = true
        _ = NativePendingOpenURLConsumer(inbox: inbox).consume(
            localOwnerVerified: true,
            now: now,
            jobExists: { [jobs] id in jobs.contains(where: { $0.id == id }) },
            routeToJob: { [weak self] id in self?.routeToJob(id) },
            presentOnMyWay: { [weak self] id in self?.routeToOnMyWay(id) }
        )
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
    func requestAppointmentConfirmationReview(jobID: String) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              NativeAppointmentNotifications.canOpenNotification(
                  exactOwnerWorkspace: hasExactSignedInWorkspace,
                  signedIn: isSignedIn,
                  job: job
              )
        else { return }
        selectedTab = .jobs
        deepLinkedJobID = jobID
        pendingAppointmentConfirmationJobID = jobID
    }

    /// Task 10.08 (N6) fix: an archived job now fails closed here too,
    /// matching the estimate/appointment routes — a stale `review_` payload
    /// for a job the owner has since archived must not invent a destination.
    func requestReviewRequestReview(jobID: String) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              let job = snapshot.payload.jobs?.first(where: { $0.id == jobID }),
              (job.archivedAt ?? "").isEmpty,
              reviewRequestDraft(jobID: jobID) != nil else { return }
        selectedTab = .jobs
        deepLinkedJobID = jobID
        pendingReviewRequestJobID = jobID
    }

    /// Phase 7 invoice-tap routing. Validates the exact workspace plus current
    /// record state before opening the review screen; stale payloads fail
    /// closed. Taps never send customer messages.
    func requestInvoiceReminderReview(invoiceID: String, opensOutreach: Bool) {
        guard hasExactSignedInWorkspace,
              isSignedIn,
              invoices.contains(where: { $0.id == invoiceID })
        else { return }
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
        // This explicit user action is allowed to replace an unreadable source.
        persistenceWritesBlocked = false
        persistenceBlockReason = nil
        persistenceBlockDetail = nil
        pendingCustomerMergeUndo = nil
        pendingRecordDeleteUndo = nil
        seedDemoData()
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
            try apply(migrated)
            try repository.save(snapshot)
            try migrationJournal.complete(kind)
        } catch {
            try? migrationJournal.fail(kind)
            throw error
        }
    }

    private func mergeSettingsAndSave() {
        guard ensurePersistenceWritable() else {
            if let canonicalSettings = snapshot.payload.settings {
                isApplyingProjection = true
                settings = CanonicalUIAdapters.settings(from: canonicalSettings)
                isApplyingProjection = false
            }
            return
        }
        do {
            if let baseline = snapshot.payload.settings {
                var edit = try CanonicalUIAdapters.edit(baseline); edit.value = settings
                snapshot.payload.settings = try CanonicalUIAdapters.canonical(from: edit)
            } else { snapshot.payload.settings = try CanonicalUIAdapters.canonical(from: settings) }
            save()
            if let canonicalSettings = snapshot.payload.settings {
                enqueueSettingsUpsert(canonicalSettings)
            }
        } catch { migrationMessage = "Could not update settings: \(error.localizedDescription)" }
    }

    private func refreshAndSave() {
        do { try apply(snapshot); save() }
        catch { migrationMessage = "Could not refresh data: \(error.localizedDescription)" }
    }

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
        ownerBinding: { [weak self] in self?.verifiedAccountBinding }
    )

    /// Task 10.09 output (c): the cached business snapshot for coach cold
    /// start (10.13 reads this). Refreshed after every real committed sync
    /// pass; cleared at the account boundary.
    var cachedBusinessSnapshot: NativeBusinessSnapshot? { derivedStatePublisher.cachedSnapshot }

    /// Task 10.09 output (b): the registration point the Phase 11 widget
    /// mirror (11.01) plugs into. No widget code lives here — this is only
    /// the seam. Returns a token for `unregisterDerivedStateObserver`.
    @discardableResult
    func registerDerivedStateObserver(
        _ observer: @escaping (NativeBusinessSnapshot) throws -> Void
    ) -> UUID {
        derivedStatePublisher.register(observer)
    }

    func unregisterDerivedStateObserver(_ id: UUID) {
        derivedStatePublisher.unregister(id)
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
            pull: { [weak self] in await self?.pullDeltaIfPossible() ?? .skipped },
            statusChanged: { [weak self] status in self?.syncStatus = status }
        )
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
        guard !persistenceWritesBlocked else { return .failed("pull/local-protection") }
        guard let service = deltaSyncServiceIfConfigured() else { return .skipped }
        guard let credentials = currentSyncCredentials() else { return .failed("pull/session") }
        let subject = credentials.subject
        let cursor = syncCursorStore.load()
        let localSnapshot = snapshot

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
            do {
                outcome = try await service.pullDelta(
                    sessionBytes: fresh.sessionBytes,
                    expectedUserSubject: subject,
                    localSnapshot: snapshot,
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
        let previous = snapshot
        do {
            try apply(outcome.snapshot)
            try repository.save(snapshot)
        } catch {
            try? apply(previous)
            return .failed("pull/local-commit")
        }
        do { try syncCursorStore.save(outcome.cursor) }
        catch { return .failed("pull/cursor-commit") }
        // Sync completion is the generation trigger (mirrors RN app-open /
        // foreground): pulled rules and jobs are in the snapshot, so due
        // occurrences materialize before any recurrence-manager refresh reads
        // them. A no-op when nothing is due; never fails the pull.
        refreshRecurringJobs()
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
        if let binding = verifiedAccountBinding, subject == authenticatedUserSubject {
            await derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: binding)
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
    func performPullToRefresh() async -> NativeSyncOutcome? {
        await syncNowAndWait(trigger: .manual)
    }

    /// Foreground ordering matches the React Native oracle: metadata sync first,
    /// then pending byte uploads and missing-file backfill. A second sync makes
    /// newly confirmed `uploadedAt` values visible to the user's other devices.
    func performForegroundRefresh() async {
        let synced = await syncNowAndWait(trigger: .foreground) != nil
        // Mirrors RN's foreground `checkAndGenerateRecurringJobs`: runs after
        // the sync when it succeeds, and on the local snapshot when offline —
        // and before photo transfer or any Batch 2 recurrence-manager refresh.
        refreshRecurringJobs()
        _ = runRecurringInvoiceGeneration()
        rescheduleInvoiceDeliveries()
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
                let previous = snapshot
                do {
                    try apply(committed)
                    try repository.save(snapshot)
                } catch {
                    try? apply(previous)
                    throw error
                }
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

    /// Runs the bounded work behind a BGAppRefreshTask. A suspended process can
    /// reuse its already verified identity. A cold background launch performs
    /// the same server verification/refresh as foreground activation, but it
    /// may attach that identity only to an exact, completed owner-bound local
    /// workspace. It never advances onboarding/subscription UI or adopts an
    /// unbound snapshot while no foreground is present.
    func performBackgroundRefresh() async -> NativeBackgroundRefreshOutcome {
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
                verifier: verifier,
                refresher: verifier
            )
            authenticatedIdentityActivator = created
            activator = created
        }

        do {
            guard let outcome = try await activator.activate(),
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
            return false
        }
    }

    private func scheduleSyncAfterLocalChange() {
        syncNow(trigger: .localChange)
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
              let sessionBytes = try? NativeKeychainSecureSettingsStore().readSupabaseSession()
        else { return nil }
        return NativeSyncCredentials(subject: subject, sessionBytes: sessionBytes)
    }

    /// Refreshes the Supabase session through the same server-verified activator
    /// the rest of the app uses. Returns whether a usable session is now present.
    private func refreshSyncSession() async -> Bool {
        guard let configured = try? configuredAuthentication() else { return false }
        do { return try await configured.activator.activate() != nil }
        catch { return false }
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

    private func applyLaunchMigrationState(
        outcome: LegacyMigrationOutcome?,
        error: Error?,
        hadNativeSnapshot: Bool
    ) {
        if error != nil {
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
        switch outcome.status {
        case .migrated:
            isLegacyMigrationBlocked = false
            launchMigrationNotice = .migrated(
                count: outcome.importedCount,
                adoptedPhotos: outcome.adoptedPhotoCount,
                deferredPhotos: outcome.deferredPhotoCount
            )
        case .nativeSnapshotConflict:
            launchMigrationNotice = .conflict
            migrationMessage = "Previous-app data was found, but this app already has data. Nothing was changed."
        case .alreadyCompleted:
            if !hadNativeSnapshot {
                persistenceWritesBlocked = true
                persistenceBlockReason = .missingMigratedSnapshot
                persistenceBlockDetail = nil
                isLegacyMigrationBlocked = true
                launchMigrationNotice = .failed
                migrationMessage = "The previous-app migration is marked complete, but its native snapshot is unavailable."
            }
        case .noData:
            break
        }
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
            snapshot.payload.invoices = invoiceRecords
            guard let published = try? CanonicalUIAdapters.invoice(from: result) else {
                return .failure(.persistenceUnavailable)
            }
            var jobRecords = snapshot.payload.jobs ?? []
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
            snapshot.payload.jobs = jobRecords
            try repository.save(snapshot)
            try apply(snapshot)
            enqueueUpsert(table: "invoices", recordId: result.id, record: result)
            for jobID in advancedJobIDs {
                guard let record = snapshot.payload.jobs?.first(where: { $0.id == jobID }) else { continue }
                enqueueUpsert(table: "jobs", recordId: jobID, record: record)
            }
            return .success(published)
        } catch {
            migrationMessage = "Could not record the payment: \(error.localizedDescription)"
            return .failure(.persistenceUnavailable)
        }
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

    private func seedDemoData() {
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
            try apply(Canonical.Snapshot(payload: payload)); save()
        } catch { migrationMessage = "Could not create demo data: \(error.localizedDescription)" }
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
        case applied(status: String, alreadyApplied: Bool)
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
        var proofsReady: [String] = []
        var proofsSuperseded: [String] = []
        var retained: Int = 0
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
        return try? NativeKeychainSecureSettingsStore().readSupabaseSession()
    }

    /// Returns the current Supabase session bytes for schedule/booking/portal transports.
    /// Used by tests and views that need to call owner transports directly.
    func scheduleBookingSessionBytes() async throws -> Data {
        if let scheduleBookingSessionOverride { return scheduleBookingSessionOverride }
        if let bytes = try? NativeKeychainSecureSettingsStore().readSupabaseSession() { return bytes }
        throw NativeBookingAdminError.malformedSession
    }

    private func scheduleBookingRefreshedSession(excluding used: Data) async -> Data? {
        guard await refreshSyncSession(),
              let fresh = try? NativeKeychainSecureSettingsStore().readSupabaseSession(),
              fresh != used
        else { return nil }
        return fresh
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func commitScheduleBookingLocal(
        saveSnapshot: () throws -> Void,
        queueWork: () throws -> Void,
        queueStage: String
    ) -> Bool {
        let outcome = NativeScheduleBookingPolicy.commitLocal(
            saveSnapshot: saveSnapshot,
            publishToQueue: queueWork,
            stageRecovery: {}
        )
        switch outcome {
        case .committed:
            scheduleSyncAfterLocalChange()
            return true
        case .snapshotFailed:
            return false
        case .queueFailedRecoveryStaged:
            // The snapshot is durable; the idempotent pull reconciles and
            // the next edit re-enqueues (the `commitCustomerMerge`
            // convention). Capability-sensitive server mutations use the
            // pending-work store instead — see the admin paths below.
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

    /// Atomic intake after a verified pull: serializes overlapping refreshes,
    /// rechecks the owner across the suspension, plans against the fresh
    /// snapshot, revalidates the plan, and commits customers/jobs/requests
    /// in one snapshot transaction. Reminder scheduling flows through the
    /// existing notification infrastructure (the schedule key recomputes
    /// from the committed snapshot) — no second sender is introduced.
    func runBookingIntakeAfterVerifiedPull(
        makeCustomerID: @escaping () -> String = { "c\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))" },
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
        guard scheduleBookingOwnerStillCurrent(capture),
              let settings = snapshot.payload.settings
        else { return .skipped(reason: "owner-changed") }
        let stamp = nowISO?() ?? isoNow()
        let requests = snapshot.payload.bookingRequests ?? []
        guard NativeBookingIntake.needsIntake(requests) else { return .noChange }
        let plan = NativeBookingIntake.plan(
            requests: requests,
            jobs: snapshot.payload.jobs ?? [],
            customers: snapshot.payload.customers ?? [],
            settings: settings,
            makeCustomerID: makeCustomerID,
            nowISO: { stamp }
        )
        guard let rechecked = NativeScheduleBookingPolicy.recheckedIntakePlan(
            plan,
            currentRequests: snapshot.payload.bookingRequests ?? [],
            currentJobs: snapshot.payload.jobs ?? [],
            currentCustomers: snapshot.payload.customers ?? []
        ) else { return .noChange }
        guard ensurePersistenceWritable() else { return .skipped(reason: "read-only") }
        var updated = snapshot
        updated.payload.bookingRequests = rechecked.requests
        updated.payload.jobs = rechecked.jobs
        updated.payload.customers = rechecked.customers
        let drafts = rechecked.drafts
        let committed = commitScheduleBookingLocal(
            saveSnapshot: {
                try self.repository.save(updated)
                try self.apply(updated)
            },
            queueWork: { try self.mutationQueue.enqueueBatch(drafts) },
            queueStage: "enqueue-booking-intake"
        )
        guard committed else {
            migrationMessage = "Could not save converted requests locally."
            return .skipped(reason: "local-commit")
        }
        // Task 10.09 (B1): the booking-intake local commit above is itself a
        // committed canonical sync commit (new customers/jobs/requests from
        // the converted intake), distinct from the pull's own publish
        // earlier in this function (which ran from the PRE-intake snapshot).
        // Publish once more from the just-committed post-intake snapshot so
        // notifications/cache/widget mirror see the converted data, not the
        // stale pre-intake one. `commitScheduleBookingLocal` is synchronous,
        // so no suspension occurred since the owner was last verified above.
        if let binding = verifiedAccountBinding {
            await derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: binding)
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

    /// Explicit owner decline: rechecks the owner and record after the
    /// suspension, sends exactly one POST, and merges ONLY the returned
    /// status into the local request. A 409 refreshes authoritative state
    /// instead of forcing the captured status; an unknown outcome never
    /// resends automatically (a decline may email the customer).
    func declineBookingRequest(
        requestID: String,
        responseService: NativeBookingResponseService? = nil,
        sessionBytes: Data? = nil
    ) async -> OwnerResponseOutcome {
        let capture = scheduleBookingOwnerCapture()
        guard let current = snapshot.payload.bookingRequests?.first(where: { $0.id == requestID }) else {
            return .missing
        }
        _ = current
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
        let result: NativeBookingResponseResult
        do {
            result = try await serviceWithRefresh.decline(requestId: requestID, sessionBytes: bytes)
        } catch let error as NativeBookingResponseError {
            return await mapBookingResponseError(error, requestID: requestID, capture: capture)
        } catch {
            return .failed(reason: "transport")
        }
        guard scheduleBookingOwnerStillCurrent(capture) else { return .failed(reason: "owner-changed") }
        mergeBookingRequestStatus(requestID: requestID, status: result.status)
        return .applied(status: result.status, alreadyApplied: result.alreadyApplied)
    }

    /// Reschedule step 1: durably saves the revised job schedule locally,
    /// enqueues its sync, stages the publication proof as owner-bound pending
    /// work, and waits for the EXACT job-mutation acknowledgment (no pending
    /// queue item for the job + a fresh pull still showing the proven
    /// schedule). A superseding edit refuses instead of resolving wrong.
    func prepareBookingReschedule(
        requestID: String,
        scheduleDraft: NativeScheduleBookingPolicy.ScheduleOnlyDraft,
        writeStamp: String? = nil
    ) async -> ReschedulePrepareOutcome {
        guard scheduleDraft.jobID.isEmpty == false else { return .missing }
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
        _ = await pullDeltaIfPossible()
        guard scheduleBookingOwnerStillCurrent(scheduleBookingOwnerCapture()) else {
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
    func resolveBookingReschedule(
        requestID: String,
        proof: NativeScheduleProof,
        responseService: NativeBookingResponseService? = nil,
        sessionBytes: Data? = nil
    ) async -> RescheduleResolveOutcome {
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
        let result: NativeBookingResponseResult
        do {
            result = try await serviceWithRefresh.resolveReschedule(
                requestId: requestID, proof: proof, sessionBytes: bytes
            )
        } catch let error as NativeBookingResponseError {
            switch error {
            case let .invalidState(currentStatus), let .scheduleChanged(currentStatus):
                _ = await pullDeltaIfPossible()
                return .needsReview(currentStatus: currentStatus)
            case .unknownOutcome:
                return .unknownOutcome
            case .notFound:
                _ = await pullDeltaIfPossible()
                return .missing
            default:
                return .failed(reason: String(describing: error))
            }
        } catch {
            return .failed(reason: "transport")
        }
        guard scheduleBookingOwnerStillCurrent(capture) else { return .failed(reason: "owner-changed") }
        mergeBookingRequestStatus(requestID: requestID, status: result.status)
        if let binding = capture.binding {
            try? pendingScheduleBookingWorkStore().remove {
                if case let .rescheduleProof(req, _, _) = $0.kind { return req == requestID && $0.ownerBinding == binding }
                return false
            }
        }
        return .resolved(status: result.status, alreadyApplied: result.alreadyApplied)
    }

    private func mapBookingResponseError(
        _ error: NativeBookingResponseError,
        requestID: String,
        capture: (subject: String?, binding: String?)
    ) async -> OwnerResponseOutcome {
        switch error {
        case let .invalidState(currentStatus), let .scheduleChanged(currentStatus):
            _ = await pullDeltaIfPossible()
            return .needsReview(currentStatus: currentStatus)
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

    /// Field-scoped lifecycle merge for owner responses: ONLY the server
    /// status is adopted. History, slot, provenance and unknown fields ride
    /// along on the struct copy so a late-arriving server history survives;
    /// the next pull reconciles the rest. Never a whole-stale-blob replay.
    private func mergeBookingRequestStatus(requestID: String, status: String) {
        guard ensurePersistenceWritable(),
              var records = snapshot.payload.bookingRequests,
              let index = records.firstIndex(where: { $0.id == requestID })
        else { return }
        var merged = records[index]
        merged.status = status
        records[index] = merged
        var updated = snapshot
        updated.payload.bookingRequests = records
        do {
            try repository.save(updated)
            try apply(updated)
        } catch {
            migrationMessage = "The response was accepted but the local copy could not be saved."
            return
        }
        enqueueUpsert(table: "bookingRequests", recordId: requestID, record: merged)
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
        guard scheduleBookingOwnerStillCurrent(capture), let binding = capture.binding else {
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
    @discardableResult
    private func mergePortalDisplayFields(customerID: String, token: String?, enabled: Bool?) -> Bool {
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
            migrationMessage = "The portal link was updated on the server but the local copy could not be saved."
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

    /// Recovers owner-bound incomplete work after relaunch or failure:
    /// re-applies display-only mirrors (never repeating a committed server
    /// mutation) and reports reschedule proofs whose exact job-mutation
    /// acknowledgment is now verifiable. Items owned by another binding are
    /// left untouched here — scrubbing is an explicit account-boundary act.
    func recoverScheduleBookingPendingWork(ownerBinding: String) -> PendingWorkRecovery {
        var recovery = PendingWorkRecovery()
        var items = pendingScheduleBookingWorkStore().load()
        for item in items where item.ownerBinding == ownerBinding {
            switch item.kind {
            case let .bookingMirror(token, enabled, _, _):
                if mergeBookingDisplayMirrorForRecovery(token: token, enabled: enabled) {
                    recovery.reappliedMirrors += 1
                    items.removeAll { $0 == item }
                } else {
                    recovery.retained += 1
                }
            case let .portalMirror(customerID, token, enabled, _):
                if mergePortalDisplayFields(customerID: customerID, token: token, enabled: enabled) {
                    recovery.reappliedMirrors += 1
                    items.removeAll { $0 == item }
                } else {
                    recovery.retained += 1
                }
            case let .rescheduleProof(requestID, proof, _):
                let acked = !mutationQueue.load().contains {
                    $0.table == "jobs" && $0.recordId == proof.jobId
                }
                let job = snapshot.payload.jobs?.first(where: { $0.id == proof.jobId })
                if NativeScheduleBookingPolicy.proofMatchesCurrentJob(proof, job: job), acked {
                    recovery.proofsReady.append(requestID)
                } else if !NativeScheduleBookingPolicy.proofMatchesCurrentJob(proof, job: job) {
                    recovery.proofsSuperseded.append(requestID)
                    items.removeAll { $0 == item }
                } else {
                    recovery.retained += 1
                }
            }
        }
        try? pendingScheduleBookingWorkStore().save(items)
        return recovery
    }

    private func mergeBookingDisplayMirrorForRecovery(token: String?, enabled: Bool) -> Bool {
        guard ensurePersistenceWritable(),
              var settings = snapshot.payload.settings
        else { return false }
        do {
            // Recovery never invents a token: a nil-token mirror with no
            // existing link fails closed and stays staged.
            settings = try NativeBookingAdminMirror.apply(to: settings, token: token, enabled: enabled)
            var updated = snapshot
            updated.payload.settings = settings
            try repository.save(updated)
            try apply(updated)
            enqueueSettingsUpsert(settings)
            return true
        } catch {
            return false
        }
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
    var advisoryAnthropicKey: String? {
        guard let bytes = try? NativeKeychainSecureSettingsStore().backend.read(key: "anthropicKey"),
              let value = String(data: bytes, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard draft.taxIncomeRate != nil || draft.vehicleDeductionMethod != nil else { return true }
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
        return true
    }

    /// The canonical tax-settings values the estimator consumes.
    var taxSettingsValues: NativeTaxSettingsValues {
        snapshot.payload.settings.map(NativeTaxSettingsValues.init(from:)) ?? NativeTaxSettingsValues()
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

    /// Task 10.12: wires the persisted `sampleTourDone` value (10.03's
    /// `NativeSetupChecklistStore`, adopted via `activateSetupChecklist`).
    /// `setupChecklistState == nil` (not yet loaded / unreadable) reads as
    /// "not done" here — the hero is the SAFER default when the checklist
    /// store is degraded (worst case: the sample-tour hero shows once more
    /// than intended, never a lost first-run experience).
    var todayHero: NativeTodayHero? {
        NativeTodayBriefing.hero(
            jobs: canonicalJobs,
            customers: canonicalCustomers,
            sampleTourDone: setupChecklistState?.sampleTourDone == true
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
    func markSetupTaskDone(_ task: NativeSetupTaskID) {
        guard let binding = verifiedAccountBinding else { return }
        if let updated = try? setupChecklistStore.markTaskDone(task, for: binding) {
            setupChecklistState = updated
        }
    }

    /// "Hide" — RN's `dismissSetupChecklist()`. Optimistic: the card hides
    /// immediately (the caller reads `todaySetupTasks`/`todaySetupComplete`,
    /// both of which flip the instant this publishes) and the write follows.
    func dismissSetupChecklist() {
        guard let binding = verifiedAccountBinding else { return }
        let optimistic = NativeSetupChecklist.dismissing(setupChecklistState ?? NativeSetupChecklistState())
        setupChecklistState = optimistic
        analytics.track("setup_checklist_dismissed", [
            "doneCount": String(todaySetupTasks?.filter(\.done).count ?? 0),
        ])
        if let persisted = try? setupChecklistStore.dismiss(for: binding) {
            setupChecklistState = persisted
        }
    }

    /// The hero's sample-tour tap (`markSampleTourDone` + `sample_job_opened`
    /// — RN's `TodayScreen.tsx` call sites, task 10.12 owns wiring this). A
    /// no-op for any other hero kind.
    func markSampleTourDoneIfNeeded(for hero: NativeTodayHero) {
        guard hero.kind == .sampleTour, let binding = verifiedAccountBinding else { return }
        let optimistic = NativeSetupChecklist.markingSampleTourDone(setupChecklistState ?? NativeSetupChecklistState())
        setupChecklistState = optimistic
        analytics.track("sample_job_opened")
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
    func applyInsightMute(_ insight: NativeTodayInsight, days: Int?) {
        analytics.track(
            days == nil ? "insight_dismissed" : "insight_snoozed",
            days == nil
                ? ["kind": insight.kind.rawValue, "insightId": insight.id]
                : ["kind": insight.kind.rawValue, "insightId": insight.id, "days": String(days!)]
        )
        let now = Date()
        let liveIDs = Set(todayInsightsAll.map(\.id))
        let optimistic = NativeInsightMutes.applying(
            id: insight.id, now: now, days: days, liveIDs: liveIDs, to: insightMutes ?? []
        )
        insightMutes = optimistic
        guard let binding = verifiedAccountBinding else { return }
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
        analytics.track("insight_shown", [
            "kinds": insights.map(\.kind.rawValue).joined(separator: ","),
            "ids": insights.map(\.id).joined(separator: ","),
        ])
    }

    func trackInsightTapped(_ insight: NativeTodayInsight) {
        analytics.track("insight_tapped", ["kind": insight.kind.rawValue])
    }

    func trackInsightCoachOpened(_ insight: NativeTodayInsight) {
        analytics.track("insight_coach_opened", ["kind": insight.kind.rawValue])
    }

    func trackInsightReasonViewed(_ insight: NativeTodayInsight) {
        analytics.track("insight_reason_viewed", ["kind": insight.kind.rawValue])
    }

    /// RN `SetupChecklistCard.tsx`'s `track("setup_checklist_task_opened",
    /// {task: id})` — fired for every task tap that routes to Settings
    /// (the notifications task never reaches this; it's handled in-card).
    func trackSetupChecklistTaskOpened(_ task: NativeSetupTaskID) {
        analytics.track("setup_checklist_task_opened", ["task": task.rawValue])
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
    /// invoice". `.none` is the fail-closed case: a missing or archived
    /// record, or a malformed date, produces no destination.
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

    /// True when `jobID` names a job that currently exists and is not
    /// archived. The single fail-closed check every job-based
    /// `NativeTodayDestination` case below uses, so "exists but archived"
    /// cannot slip through on some cases and not others.
    private func isLiveTodayJob(_ jobID: String) -> Bool {
        jobs.contains(where: { $0.id == jobID && ($0.archivedAt ?? "").isEmpty })
    }

    /// Executes a Today destination against the live snapshot. Reuses the
    /// exact one-shot exact-ID pattern from `routeToGlobalSearchResult`:
    /// clears every prior deep-link target first, verifies the CURRENT
    /// record exists and is not archived, and only then publishes the new
    /// target — a stale insight/booking-row/hero target for a since-deleted
    /// or since-archived record is a no-op, never an invented destination.
    @discardableResult
    func routeToToday(_ destination: NativeTodayDestination) -> NativeTodayRouteResult {
        switch destination {
        case .job(let id):
            guard isLiveTodayJob(id) else { return .none }
            resetTodayDeepLinkTargets()
            deepLinkedJobID = id
            selectedTab = .jobs
            return .handled
        case .createInvoice(let jobID):
            guard isLiveTodayJob(jobID) else { return .none }
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
            guard isLiveTodayJob(jobID) else { return .none }
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
            guard isLiveTodayJob(jobID) else { return .none }
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
    func testActivateInsightAndChecklistStores(accountBinding: String) {
        activateInsightMutes(accountBinding: accountBinding, migrated: nil)
        activateSetupChecklist(accountBinding: accountBinding, migrated: nil)
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
