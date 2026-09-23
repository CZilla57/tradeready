import SwiftUI

@main
struct TradeReadyNativeApp: App {
    @StateObject private var store: AppStore
    @StateObject private var followUpNotifications: NativeEstimateFollowUpNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    private let backgroundRefreshScheduler: NativeBackgroundRefreshScheduler

    init() {
        let store = AppStore()
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
                    if !NativeGoogleSignInProvider.handle(url) {
                        store.handle(url: url)
                    }
                }
                .task { await store.activateMigratedAuthenticatedIdentity() }
                .task(id: store.estimateFollowUpNotificationScheduleKey) {
                    await followUpNotifications.synchronize()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        backgroundRefreshScheduler.cancelActive()
                        Task {
                            await store.activateMigratedAuthenticatedIdentity()
                            // Pull metadata before mirroring photo bytes so a
                            // cross-device backfill sees the newest records.
                            await store.performForegroundRefresh()
                            await followUpNotifications.synchronize()
                        }
                    case .background:
                        backgroundRefreshScheduler.schedule()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
