import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.isAccountScrubBlocked {
                // Phase 12 (12.00b.2-G, Task 9b review M3): a deletion's
                // cleanup is named as one.
                let isDeletion = store.accountScrubBlockedScope == .all
                ContentUnavailableView {
                    Label(
                        isDeletion ? "Account deletion cleanup paused" : "Sign-out cleanup paused",
                        systemImage: "person.crop.circle.badge.xmark"
                    )
                } description: {
                    Text(isDeletion
                         ? "Your account is deleted. TradeReady is keeping its local data hidden until it can finish removing it safely."
                         : "TradeReady is keeping local account data hidden until it can finish removing it safely.")
                } actions: {
                    Button("Try cleanup again") { store.retryAccountScrub() }
                        .tradeReadyProminentButtonStyle()
                    Link("Contact support", destination: URL(string: isDeletion
                        ? "mailto:support@gettradereadyapp.com?subject=TradeReady%20account%20deletion"
                        : "mailto:support@gettradereadyapp.com?subject=TradeReady%20sign-out")!)
                    // Phase 12 (12.02): Settings is out of reach here, so
                    // the Settings support report comes to the owner. It
                    // writes no owner data.
                    NativeSupportReportAction()
                        .multilineTextAlignment(.center)
                }
            } else if store.isLegacyMigrationBlocked {
                ContentUnavailableView {
                    Label("Data migration paused", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("We couldn't finish moving your previous-app data. Your original data is still safe.")
                } actions: {
                    Button("Try again") { store.retryLegacyMigration() }
                        .tradeReadyProminentButtonStyle()
                    Link("Contact support", destination: URL(string: "mailto:support@gettradereadyapp.com?subject=TradeReady%20migration")!)
                    NativeSupportReportAction()
                        .multilineTextAlignment(.center)
                }
            } else {
                authenticationGate
                    // Phase 12 (L286.4): a pending switch/recovery boundary
                    // step offers its retry above every gate.
                    .safeAreaInset(edge: .top, spacing: 0) { NativeAccountCleanupBanner() }
            }
        }
        .alert(item: Binding(
            get: { store.launchMigrationNotice },
            set: { if $0 == nil { store.dismissLaunchMigrationNotice() } }
        )) { notice in
            switch notice {
            case .migrated(let count, let adoptedPhotos, let deferredPhotos):
                let adoptedMessage = adoptedPhotos == 0
                    ? ""
                    : " Safely copied \(adoptedPhotos) local photo asset(s)."
                let deferredMessage = deferredPhotos == 0
                    ? ""
                    : " Kept \(deferredPhotos) photo reference(s) for later recovery."
                return Alert(
                    title: Text("Your data is ready"),
                    message: Text(
                        "Moved \(count) item(s) from the previous TradeReady app."
                            + adoptedMessage + deferredMessage
                    ),
                    dismissButton: .default(Text("OK")) { store.dismissLaunchMigrationNotice() }
                )
            case .conflict:
                return Alert(
                    title: Text("Both versions contain data"),
                    message: Text("Previous-app data was found, but this app already has data. Nothing was changed."),
                    dismissButton: .default(Text("Continue with current data")) { store.dismissLaunchMigrationNotice() }
                )
            case .failed:
                return Alert(
                    title: Text("Data migration paused"),
                    message: Text("Your previous-app data is still safe. Try again when you're ready."),
                    dismissButton: .default(Text("OK")) { store.dismissLaunchMigrationNotice() }
                )
            }
        }
    }

    @ViewBuilder
    private var authenticationGate: some View {
        switch store.authenticationGateState {
        case .loading:
            NativeContentStateView(
                state: .loading,
                emptyTitle: "",
                emptyMessage: "",
                symbol: "person.crop.circle",
                loadingMessage: "Checking your account…"
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tradeCanvas)
        case .initialSyncLoading:
            NativeContentStateView(
                state: .loading,
                emptyTitle: "",
                emptyMessage: "",
                symbol: "icloud",
                loadingMessage: "Loading your cloud data…"
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tradeCanvas)
        case .initialSyncUnavailable(let message):
            NativeContentStateView(
                state: .error,
                emptyTitle: "",
                emptyMessage: "",
                symbol: "icloud",
                errorTitle: "Cloud data unavailable",
                errorMessage: message,
                retryAction: { Task { await store.retryAuthentication() } },
                secondaryActionTitle: "Use another account",
                secondaryAction: { Task { await store.useAnotherAccount() } }
            )
        case .subscriptionLoading:
            NativeContentStateView(
                state: .loading,
                emptyTitle: "",
                emptyMessage: "",
                symbol: "checkmark.seal",
                loadingMessage: "Checking your subscription…"
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tradeCanvas)
        case .signedOut:
            NativeAuthView()
        case .signedIn:
            mainTabs
                .safeAreaInset(edge: .top, spacing: 0) { NativeSyncBanner() }
                .safeAreaInset(edge: .bottom, spacing: 0) { NativeUndoBanner() }
                // Task 11.06 (contract §6.2 step 6): a widget/Siri link whose
                // job is missing, archived or finished shows the existing
                // Jobs "Job not found" state (same title and symbol as
                // `JobsView`'s navigation destination), never another record.
                .sheet(item: Binding(
                    get: { store.deepLinkUnavailableNotice },
                    set: { if $0 == nil { store.dismissDeepLinkUnavailableNotice() } }
                )) { _ in
                    NavigationStack {
                        ContentUnavailableView {
                            Label("Job not found", systemImage: "questionmark.folder")
                        } description: {
                            Text("This link's job was deleted, archived or already finished.")
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { store.dismissDeepLinkUnavailableNotice() }.keyboardShortcut(.cancelAction)
                            }
                        }
                    }
                    .presentationDetents([.medium])
                }
        case .passwordRecovery(let email):
            NativePasswordRecoveryView(email: email)
        case .invalidPasswordRecovery:
            ContentUnavailableView {
                Label("Reset link unavailable", systemImage: "link.badge.plus")
            } description: {
                Text("This password reset link is invalid or expired. Request a new link and try again.")
            } actions: {
                Button("Return to sign in") {
                    Task { await store.dismissInvalidPasswordRecovery() }
                }
                .tradeReadyProminentButtonStyle()
            }
        case .onboarding(let draft):
            NativeOnboardingView(draft: draft)
        case .paywall(let offering, let message):
            NativePaywallView(offering: offering, loadMessage: message)
        case .startingPoint(let trade):
            NativeStartingPointView(trade: trade)
        case .accountMismatch:
            ContentUnavailableView {
                Label("Different account", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("This device contains data from another account. It remains safely separated. Sign in with the matching account to continue.")
            } actions: {
                Button("Use another account") { Task { await store.useAnotherAccount() } }
                    .tradeReadyProminentButtonStyle()
            }
        case .unavailable:
            NativeContentStateView(
                state: .error,
                emptyTitle: "",
                emptyMessage: "",
                symbol: "wifi.exclamationmark",
                errorTitle: "Can't verify your account",
                errorMessage: "Your saved data is still safe. Check your connection and try again.",
                retryAction: { Task { await store.retryAuthentication() } }
            )
        }
    }

    private var mainTabs: some View {
        TabView(selection: $store.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "calendar") }
                .tag(AppTab.today)
            JobsView()
                .tabItem { Label("Jobs", systemImage: "hammer") }
                .tag(AppTab.jobs)
            InvoicesView()
                .tabItem { Label("Invoices", systemImage: "doc.text") }
                .tag(AppTab.invoices)
            CustomersView()
                .tabItem { Label("Customers", systemImage: "person.2") }
                .tag(AppTab.customers)
            MoneyView()
                .tabItem { Label("Money", systemImage: "dollarsign.circle") }
                .tag(AppTab.money)
            CoachView()
                .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(AppTab.coach)
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    }
}
