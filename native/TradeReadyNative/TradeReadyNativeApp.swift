import SwiftUI

@main
struct TradeReadyNativeApp: App {
    @StateObject private var store: AppStore
    @StateObject private var followUpNotifications: NativeEstimateFollowUpNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    private let backgroundRefreshScheduler: NativeBackgroundRefreshScheduler

    init() {
        // Task 11.07 (contract §9.2): the analytics transport. Debug, a
        // missing key or a `PLACEHOLDER` key yields one that emits nothing.
        let store = AppStore(analytics: NativeAnalyticsTransport.live())
        _store = StateObject(wrappedValue: store)
        let coordinator = NativeEstimateFollowUpNotificationCoordinator(
            center: NativeSystemEstimateFollowUpNotificationCenter(),
            exactWorkspaceBinding: { [weak store] in
                store?.exactSignedInWorkspaceNotificationBinding
            },
            notificationPlan: { [weak store] now in
                store?.estimateFollowUpNotifications(now: now) ?? []
            },
            namespacePlans: [
                .init(namespace: .appointment) { [weak store] now in
                    store?.appointmentConfirmationNotifications(now: now) ?? []
                },
                .init(namespace: .review) { [weak store] now in
                    store?.reviewRequestNotifications(now: now) ?? []
                },
                .init(namespace: .invoiceReminder) { [weak store] now in
                    store?.invoiceReminderNotifications(now: now) ?? []
                },
                .init(namespace: .recurringInvoice) { [weak store] now in
                    store?.recurringInvoiceReminderNotifications(now: now) ?? []
                }
            ],
            openFollowUp: { [weak store] jobID in
                store?.requestEstimateFollowUpReview(jobID: jobID)
            },
            openOwnedRoute: { [weak store] route in
                switch route {
                case .appointmentConfirm(let jobID):
                    store?.requestAppointmentConfirmationReview(jobID: jobID)
                case .reviewRequest(let jobID):
                    store?.requestReviewRequestReview(jobID: jobID)
                case .invoiceReminder(let invoiceID, _, let opensOutreach):
                    store?.requestInvoiceReminderReview(invoiceID: invoiceID, opensOutreach: opensOutreach)
                case .recurringInvoiceReminder(let ruleID):
                    store?.requestRecurringInvoiceReview(ruleID: ruleID)
                case .estimateFollowUp:
                    break
                }
            },
            wasReminderPromptShown: { [weak store] in
                store?.wasInvoiceReminderPromptShown() ?? true
            },
            markReminderPromptShown: { [weak store] in
                store?.markInvoiceReminderPromptShown()
            }
        )
        // Task 10.05 (N1): register the five per-family categories exactly
        // once, right here at launch — decoupled from `synchronize()`, which
        // can run many times over the app's life.
        coordinator.registerCategoriesIfNeeded()
        // Task 10.05 (N1): AppStore cannot hold a reference to the coordinator
        // (the coordinator already holds a weak reference to the store for its
        // notification-plan/routing closures above), so the hand-off runs the
        // other way: the store calls this closure after a genuinely new
        // invoice is created, and it forwards into the coordinator's one-shot
        // contextual prompt.
        store.onInvoiceCreatedContextualPrompt = { [weak coordinator] in
            Task { @MainActor in
                _ = await coordinator?.promptForInvoiceRemindersIfNeeded()
            }
        }
        _followUpNotifications = StateObject(wrappedValue: coordinator)
        // Task 10.09 (B1 output a): the post-sync-commit seam's only path to
        // notification reconciliation. AppStore cannot hold the coordinator
        // directly (see the hand-off note above this init), so it calls out
        // through this hook after every real committed sync pass, foreground
        // or background — not a second reconcile path, the same
        // `synchronize(now:)` the reactive `.task(id:)` below already uses.
        store.notificationSynchronizeHook = { [weak coordinator] now in
            await coordinator?.synchronize(now: now)
        }
        // Task 11.01 (W1, contract §3.1): the App Group widget snapshot
        // writer. Installing it registers the 10.09 seam observer; the store
        // also mirrors after canonical writes, gate changes and foreground/
        // background refresh, always gated on the §2.5 owner predicate.
        store.installWidgetMirror(.live())
        // Task 11.04 (A1, contract §5.1): `OnMyWayIntent` runs in this process
        // (`openAppWhenRun`) and hands `tradeready://onmyway/<id>` to this
        // router, which feeds the same `handle(url:)` path as `.onOpenURL`
        // (→ `routeToOnMyWay`, an editable review that is never auto-sent).
        // A URL that arrived before this line is held and delivered now.
        NativeIntentURLRouter.shared.install { [weak store] url in
            store?.handle(url: url)
        }
        let scheduler = NativeBackgroundRefreshScheduler { [weak store] in
            guard let store else { return .skipped }
            return await store.performBackgroundRefresh()
        }
        scheduler.register()
        backgroundRefreshScheduler = scheduler
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(followUpNotifications)
                .tint(.tradeReady)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .onOpenURL { url in
                    // Task 11.06 (contract §6.2 step 1): Google Sign-In sees
                    // the URL first; a claimed callback never reaches the
                    // widget-link gate.
                    NativeOpenURLDispatch.dispatch(
                        url,
                        googleSignIn: NativeGoogleSignInProvider.handle,
                        app: { store.handle(url: $0) }
                    )
                }
                .task {
                    // Task 11.06 (§6.2 step 3): read-and-remove the cold-launch
                    // stash first; before sign-in it parks with its owner tag.
                    store.consumePendingOpenURLStash()
                    await store.activateMigratedAuthenticatedIdentity()
                }
                .task(id: store.estimateFollowUpNotificationScheduleKey) {
                    await followUpNotifications.synchronize()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        backgroundRefreshScheduler.cancelActive()
                        // Task 11.06 (§2.5 gap): consume on EVERY activation.
                        store.consumePendingOpenURLStash()
                        Task {
                            await store.activateMigratedAuthenticatedIdentity()
                            // Pull metadata before mirroring photo bytes so a
                            // cross-device backfill sees the newest records.
                            await store.performForegroundRefresh()
                            await followUpNotifications.synchronize()
                        }
                    case .background:
                        // Task 11.06 (§6.2 step 4): a route parked before the
                        // gate opened does not survive backgrounding.
                        store.discardParkedDeepLink()
                        backgroundRefreshScheduler.schedule()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
                // Task 10.05 fix round 1 (N1): RN's pre-permission rationale,
                // copied verbatim from `promptForInvoiceReminders()` in
                // `utils/notifications.ts`. The coordinator has already
                // stamped the owner-bound one-shot flag by the time this can
                // appear, so it is presented at most once; "Turn on" is the
                // only path that fires the real OS permission dialog.
                .alert(
                    "Invoice reminders",
                    isPresented: Binding(
                        get: { followUpNotifications.pendingInvoiceReminderPrompt },
                        set: { isPresented in
                            if !isPresented {
                                followUpNotifications.dismissInvoiceReminderPrompt()
                            }
                        }
                    )
                ) {
                    Button("Not now", role: .cancel) {
                        followUpNotifications.dismissInvoiceReminderPrompt()
                    }
                    Button("Turn on") {
                        Task { await followUpNotifications.confirmInvoiceReminderPrompt() }
                    }
                } message: {
                    Text(
                        "Want a heads-up before invoices go overdue? TradeReady can notify you so nothing slips through the cracks."
                    )
                }
        }
    }
}
