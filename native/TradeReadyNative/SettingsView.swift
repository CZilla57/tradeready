import SwiftUI
import UIKit

enum SettingsDestination: Hashable {
    case business, schedule, pricing, numbering, importData
    case payments, booking, appearance, ai, notifications, reviews
    case sync, subscription, account
}

extension SettingsDestination {
    /// Task 10.12 (D4): the exact settings subpage each setup-checklist task
    /// deep-links to (`SETTINGS_ROUTE_FOR_TASK`, 10.03's `NativeSetupRoute`).
    /// `.settings` (the `notifications` task's route) is unreachable through
    /// this initializer in practice — the checklist card handles
    /// `.notifications` in-card, before it would ever call `route(for:)` —
    /// but the mapping stays total (falls back to `.notifications`) so a
    /// future caller can never end up with no destination at all.
    init(setupRoute: NativeSetupRoute) {
        switch setupRoute {
        case .business: self = .business
        case .pricing: self = .pricing
        case .payments: self = .payments
        case .settings: self = .notifications
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    /// 11.10b A16: the profile avatar grows with its glyph (capped so the
    /// business name keeps most of the row at AX sizes).
    @ScaledMetric(relativeTo: .title2) private var avatarSize: CGFloat = 56
    /// Task 10.12 (D4): a specific subpage to push open immediately, e.g. from
    /// the setup checklist card's task tap. `nil` shows the plain settings
    /// list (the existing gear-icon behavior).
    var initialDestination: SettingsDestination?

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    profileHeader
                    settingsGroup("YOUR BUSINESS", rows: [
                        (.business, "building.2.fill", "Business profile", "Name, trade, contact details, logo"),
                        (.schedule, "clock.fill", "Schedule", "Working hours, job length, time off"),
                        (.pricing, "tag.fill", "Pricing defaults", "Labor, markup, overhead, and margin"),
                        (.numbering, "number.square.fill", "Invoice numbering", "Prefix and starting number"),
                        (.importData, "square.and.arrow.down.fill", "Import data", "Bring records over from CSV or the old app")
                    ])
                    settingsGroup("GETTING PAID", rows: [
                        (.payments, "creditcard.fill", "Payments", "Connect Stripe and payment handles"),
                        (.booking, "calendar.badge.plus", "Booking link", store.settings.bookingEnabled ? "Active — customers can request work" : "Create a link customers can book from")
                    ])
                    settingsGroup("APP", rows: [
                        (.appearance, "circle.lefthalf.filled", "Appearance", "System, light, or dark mode"),
                        (.ai, "sparkles", "AI Assistant", "Coach preferences and data access"),
                        (.notifications, "bell.badge.fill", "Notifications", "Invoices, appointments, and follow-ups"),
                        (.reviews, "star.fill", "Review requests", store.settings.reviewRequestEnabled ? "Automatic requests are on" : "Google review link and message")
                    ])
                    settingsGroup("SUBSCRIPTION & SUPPORT", rows: [
                        (.sync, "icloud.fill", "Cloud sync", syncSubtitle),
                        (.subscription, "diamond.fill", "Subscription", "Plan, billing, and restore purchases"),
                        (.account, "person.crop.circle.fill", "Account", "Profile, data, and sign out")
                    ])
                    supportLinks
                    Text("TradeReady Native · 1.0 foundation")
                        .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.bottom, 24)
                }
                .padding(.horizontal, 16).padding(.top, 10)
            }
            .nativeContentColumn(.scroll)
            .background(Color.tradeCanvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: SettingsDestination.self) { settingsDestination($0) }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.settings)
        }
        .onAppear {
            if let initialDestination, path.isEmpty {
                path.append(initialDestination)
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.tradeReadyFill, .tradeInk], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.white).font(.title2)
            }.frame(width: min(avatarSize, 96), height: min(avatarSize, 96))
            VStack(alignment: .leading, spacing: 3) {
                Text(store.settings.businessName).font(.title3.bold())
                Text([store.settings.trade, store.settings.region].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    private func settingsGroup(_ title: String, rows: [(SettingsDestination, String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary).padding(.leading, 12)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    NavigationLink(value: row.0) {
                        SettingsRow(symbol: row.1, title: row.2, subtitle: row.3)
                    }
                    .buttonStyle(.plain)
                    if index < rows.count - 1 { Divider().padding(.leading, 58) }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary) }
        }
    }

    private var supportLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HELP & LEGAL").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary).padding(.leading, 12)
            VStack(spacing: 0) {
                Link(destination: URL(string: "mailto:support@gettradereadyapp.com?subject=TradeReady%20support")!) { SettingsRow(symbol: "envelope.fill", title: "Contact support", subtitle: "support@gettradereadyapp.com", external: true) }
                Divider().padding(.leading, 58)
                Link(destination: URL(string: "https://gettradereadyapp.com/privacy.html")!) { SettingsRow(symbol: "hand.raised.fill", title: "Privacy policy", subtitle: "How TradeReady handles your data", external: true) }
                Divider().padding(.leading, 58)
                Link(destination: URL(string: "https://gettradereadyapp.com/terms.html")!) { SettingsRow(symbol: "doc.text.fill", title: "Terms of service", subtitle: "Terms for using TradeReady", external: true) }
            }.background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder private func settingsDestination(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .business: BusinessProfileSettings()
        case .schedule: NativeScheduleSettingsView()
        case .pricing: PricingSettings()
        case .numbering: InvoiceNumberSettings()
        case .importData: ImportSettings()
        case .payments: PaymentsSettings()
        case .booking: NativeBookingSettingsView()
        case .appearance: AppearanceSettings()
        case .ai: AISettings()
        case .notifications: NotificationSettings()
        case .reviews: ReviewSettings()
        case .sync: SyncSettings()
        case .subscription: SubscriptionSettings()
        case .account: AccountSettings()
        }
    }

    private var syncSubtitle: String {
        if store.syncStatus.isSyncing { return "Syncing changes…" }
        if store.syncStatus.diagnosticCode != nil { return "Needs attention" }
        // Phase 12 (12.00b.1, D3): refused changes wait for Retry or Discard.
        if !store.rejectedChanges.isEmpty {
            return "\(store.rejectedChanges.count) change\(store.rejectedChanges.count == 1 ? "" : "s") couldn't be saved"
        }
        if store.syncStatus.pendingCount > 0 {
            return "\(store.syncStatus.pendingCount) change\(store.syncStatus.pendingCount == 1 ? "" : "s") waiting"
        }
        return store.syncStatus.lastSuccessfulSyncAt == nil ? "Status and manual retry" : "Up to date"
    }
}

struct SettingsRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var external = false
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 32
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold)).foregroundStyle(Color.tradeReady)
                .frame(width: badgeSize, height: badgeSize).background(Color.tradeReady.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.body.weight(.medium)).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 8)
            Image(systemName: external ? "arrow.up.right" : "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.padding(.horizontal, 13).padding(.vertical, 11).contentShape(Rectangle())
    }
}

private struct SettingsPage<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let content: Content
    var body: some View {
        Form { content }.nativeContentColumn(.list).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(Color.tradeCanvas).onDisappear { store.save() }
            .nativeKeyboardDoneBar()
    }
}

struct BusinessProfileSettings: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { SettingsPage(title: "Business Profile", content: Group {
        Section("BUSINESS") {
            LabeledField(label: "Business name") { TextField("Demo Plumbing Co", text: $store.settings.businessName) }
            LabeledField(label: "Your name") { TextField("Owner or contact name", text: $store.settings.contactName) }
            Picker("Trade", selection: $store.settings.trade) { ForEach(["Plumbing", "Electrical", "HVAC", "Carpentry", "Landscaping", "Cleaning", "Painting", "Handyman", "Other"], id: \.self) { Text($0) } }
            LabeledField(label: "Region") { TextField("Phoenix, AZ", text: $store.settings.region) }
        }
        Section("CONTACT") {
            LabeledField(label: "Phone") { TextField("(555) 123-4567", text: $store.settings.phone).keyboardType(.phonePad) }
            LabeledField(label: "Email") { TextField("you@business.com", text: $store.settings.email).keyboardType(.emailAddress).textInputAutocapitalization(.never) }
            LabeledField(label: "Business address") { TextField("Street, city, state ZIP", text: $store.settings.address, axis: .vertical) }
        }
        Section("CUSTOMER DOCUMENTS") {
            LabeledField(label: "Default terms shown on invoices & estimates") {
                TextField("Payment due upon completion. We accept check, card, or bank transfer.", text: $store.settings.paymentNotes, axis: .vertical).lineLimit(3...7)
            }
        }
    })
    .nativeAnalyticsScreen(.settingsBusiness) }
}

struct PricingSettings: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { SettingsPage(title: "Pricing Defaults", content: Group {
        Section("LABOR") { CurrencyField(title: "Billing rate per hour", value: $store.settings.laborRate); CurrencyField(title: "Owner labor cost per hour", value: $store.settings.ownerLaborCostRate) }
        Section("MARKUP & MARGIN") { percent("Material markup", $store.settings.materialMarkup); percent("Overhead", $store.settings.overheadPercent); percent("Profit margin", $store.settings.marginPercent) }
        Section("MINIMUMS & TRAVEL") {
            CurrencyField(title: "Minimum job fee", value: $store.settings.minimumJobFee)
            CurrencyField(title: "Mileage rate", value: $store.settings.mileageRate)
            LabeledContent("Emergency multiplier") {
                HStack(spacing: 2) {
                    TextField("1", value: $store.settings.emergencyMultiplier, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                    Text("×").foregroundStyle(.secondary)
                }
            }
        }
        Section { Text("Defaults prefill new estimates. You can override them on an individual job.").font(.caption).foregroundStyle(.secondary) }
    })
    .onDisappear {
        // Task 10.12 (D4): the setup checklist's `rate` task has no honest
        // live-derivation (RN's `SettingsPricingScreen` records it on save;
        // native's bindings write continuously, so leaving this page stands
        // in for "reviewed the pricing defaults").
        store.markSetupTaskDone(.rate)
    }
    .nativeAnalyticsScreen(.settingsPricing) }
    private func percent(_ title: String, _ value: Binding<Double>) -> some View { HStack { Text(title); Spacer(); TextField("0", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70); Text("%").foregroundStyle(.secondary) } }
}

struct InvoiceNumberSettings: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { SettingsPage(title: "Invoice Numbering", content: Group {
        Section("FORMAT") {
            LabeledContent("Prefix") {
                TextField("INV-", text: $store.settings.invoicePrefix).textInputAutocapitalization(.characters).multilineTextAlignment(.trailing)
            }
            Stepper("Numbers start at \(store.settings.invoiceStart)", value: $store.settings.invoiceStart, in: 1...999999)
        }
        Section("PREVIEW") { LabeledContent("Next invoice", value: store.nextInvoiceNumber()) }
    })
    .nativeAnalyticsScreen(.settingsInvoiceNumbering) }
}

struct ImportSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingResult = false
    var body: some View { SettingsPage(title: "Import Data", content: Group {
        Section { Label("Move your existing business records into TradeReady.", systemImage: "tray.and.arrow.down.fill").foregroundStyle(.secondary) }
        Section("FROM THE PREVIOUS APP") { Button { store.importLegacyData(); showingResult = true } label: { Label("Import React Native data", systemImage: "iphone.and.arrow.forward") }; Text("Available when this build replaces the Expo app using the same bundle identifier.").font(.caption).foregroundStyle(.secondary) }
        Section("FROM A SPREADSHEET") {
            NavigationLink {
                NativeImportView()
            } label: {
                Label("Import from a CSV file", systemImage: "doc.badge.plus")
            }
            Text("Customers, jobs, invoices, or expenses from a Jobber, Housecall Pro, QuickBooks, or spreadsheet export. You review every mapping and confirm before anything is written.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("MIGRATION SUPPORT") {
            NativeSupportReportAction()
        }
    }).alert("Import", isPresented: $showingResult) { Button("OK") {} } message: { Text(store.migrationMessage ?? "Import finished.") }
    .nativeAnalyticsScreen(.settingsImport) }
}

struct SyncSettings: View {
    @EnvironmentObject private var store: AppStore
    /// 11.10b A16: the status badge grows with its `.title2` glyph.
    @ScaledMetric(relativeTo: .title2) private var statusBadgeSize: CGFloat = 42

    var body: some View {
        SettingsPage(title: "Cloud Sync", content: Group {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.title2)
                        .foregroundStyle(statusColor)
                        .frame(width: statusBadgeSize, height: statusBadgeSize)
                        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle).font(.headline)
                        Text(statusMessage).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            // Phase 12 (12.00b.1, known issue I2; owner decision D3): the
            // changes the cloud refused, with Retry and Discard.
            if !store.rejectedChanges.isEmpty {
                Section {
                    NavigationLink {
                        NativeRejectedChangesView()
                    } label: {
                        Label(rejectedChangesTitle, systemImage: "exclamationmark.icloud.fill")
                            .foregroundStyle(Color.tradeWarningText)
                    }
                } footer: {
                    Text("Everything else keeps syncing. Open the list to retry or discard each change.")
                }
            }
            Section("SYNC DETAILS") {
                LabeledContent("Pending changes", value: "\(store.syncStatus.pendingCount)")
                LabeledContent("Last completed", value: lastCompletedText)
                if let retry = store.syncStatus.nextEarliestAttempt, retry > Date() {
                    LabeledContent("Automatic retry", value: retry.formatted(date: .omitted, time: .shortened))
                }
                if let code = store.syncStatus.diagnosticCode {
                    LabeledContent("Diagnostic code") {
                        Text(code).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section {
                Button {
                    Task { await store.syncNowAndWait() }
                } label: {
                    if store.syncStatus.isSyncing {
                        HStack { ProgressView(); Text("Syncing…") }
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(store.syncStatus.isSyncing)
            } footer: {
                Text("Pending changes stay on this device and retry automatically. Diagnostic codes contain no customer data, account identifiers, or credentials.")
            }
        })
        .task { store.refreshRejectedChanges() }
    }

    private var isOffline: Bool {
        if case .offline? = store.syncStatus.lastOutcome { return true }
        return false
    }

    private var rejectedChangesTitle: String {
        let count = store.rejectedChanges.count
        return "\(count) change\(count == 1 ? "" : "s") couldn't be saved"
    }

    private var statusTitle: String {
        if store.syncStatus.isSyncing { return "Syncing" }
        if isOffline { return "You're offline" }
        if store.syncStatus.diagnosticCode != nil { return "Sync needs attention" }
        if store.syncStatus.pendingCount > 0 { return "Changes are waiting" }
        // Phase 12 (12.00b.1 review fix round 1, M7): never "Up to date"
        // while the list below shows changes the cloud refused.
        if !store.rejectedChanges.isEmpty { return "Some changes couldn't be saved" }
        if store.syncStatus.lastSuccessfulSyncAt != nil { return "Up to date" }
        return "Ready to sync"
    }

    private var statusMessage: String {
        if store.syncStatus.isSyncing { return "Uploading local changes and checking the cloud." }
        if isOffline { return "Your changes are safe here and will retry automatically." }
        if store.syncStatus.diagnosticCode != nil { return "Try again. If it keeps failing, share the diagnostic code with support." }
        if store.syncStatus.pendingCount > 0 { return "TradeReady will retry automatically, or you can sync now." }
        if !store.rejectedChanges.isEmpty { return "Everything else keeps syncing. Retry or discard each change below." }
        if store.syncStatus.lastSuccessfulSyncAt != nil { return "Local and cloud changes completed successfully." }
        return "No sync has completed since this app was opened."
    }

    private var statusSymbol: String {
        if store.syncStatus.isSyncing { return "arrow.triangle.2.circlepath" }
        if isOffline { return "icloud.slash.fill" }
        if store.syncStatus.diagnosticCode != nil { return "exclamationmark.triangle.fill" }
        if store.syncStatus.pendingCount > 0 { return "icloud.and.arrow.up.fill" }
        if !store.rejectedChanges.isEmpty { return "exclamationmark.icloud.fill" }
        return "icloud.fill"
    }

    private var statusColor: Color {
        if isOffline || store.syncStatus.diagnosticCode != nil { return Color.tradeWarningText }
        if store.syncStatus.pendingCount > 0 || store.syncStatus.isSyncing { return .tradeReady }
        if !store.rejectedChanges.isEmpty { return Color.tradeWarningText }
        return Color.tradeSuccessText
    }

    private var lastCompletedText: String {
        guard let date = store.syncStatus.lastSuccessfulSyncAt else { return "Not this session" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct PaymentsSettings: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var onboardBusy = false
    @State private var disconnectBusy = false
    @State private var confirmingDisconnect = false
    @State private var actionError: String?
    @State private var squareDraft = ""
    @State private var squareFeedback: (message: String, isError: Bool)?

    private var providers: [(id: String, label: String)] {
        [("stripe", "Stripe"), ("square", "Square"), ("paypal", "PayPal.Me"), ("venmo", "Venmo"), ("custom", "Custom URL")]
    }

    private var providerHint: String? {
        switch store.settings.paymentProvider {
        case "square": "Paste your Square payment link (create one in Square Dashboard → Payment Links, e.g. https://square.link/u/abc123)"
        case "paypal": "Enter your PayPal.Me username (e.g. johndoe)"
        case "venmo": "Enter your Venmo username"
        case "custom": "Paste your payment page URL"
        default: nil
        }
    }

    var body: some View { SettingsPage(title: "Payments", content: Group {
        Section("PROVIDER") {
            ForEach(providers, id: \.id) { provider in
                Button { store.settings.paymentProvider = provider.id } label: {
                    HStack {
                        Text(provider.label).foregroundStyle(.primary)
                        Spacer()
                        if store.settings.paymentProvider == provider.id {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.tradeReady)
                        }
                    }
                }
                .accessibilityLabel(provider.label)
            }
        }
        if store.settings.paymentProvider == "stripe" {
            Section("STRIPE") {
                if let status = store.stripeConnectStatus, status.connected {
                    HStack(spacing: 8) {
                        Circle().fill(Color.tradeSuccessText).frame(width: 8, height: 8)
                        Text(status.displayName.map { "Connected — \($0)" } ?? "Connected")
                            .fontWeight(.semibold).foregroundStyle(Color.tradeSuccessText)
                    }
                    if !status.detailsSubmitted {
                        Text("Tap below to complete your Stripe account setup before accepting payments.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { Task { await connect() } } label: {
                            HStack {
                                Text("Complete setup")
                                if onboardBusy { Spacer(); ProgressView() }
                            }
                        }.disabled(onboardBusy)
                    }
                    Button { confirmingDisconnect = true } label: {
                        HStack {
                            Text("Disconnect").foregroundStyle(Color.tradeDangerText)
                            if disconnectBusy { Spacer(); ProgressView() }
                        }
                    }.disabled(disconnectBusy)
                } else if store.stripeConnectLoading {
                    ProgressView()
                } else {
                    Text("Connect your Stripe account to generate payment links for your customers. Payments go directly to your Stripe account.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await connect() } } label: {
                        HStack {
                            Text("Connect Stripe account")
                            if onboardBusy { Spacer(); ProgressView() }
                        }
                    }.disabled(onboardBusy)
                }
                if let error = actionError ?? store.stripeConnectError {
                    Text(error).font(.caption).foregroundStyle(Color.tradeDangerText)
                }
            }
            .confirmationDialog("Disconnect Stripe?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        disconnectBusy = true
                        defer { disconnectBusy = false }
                        if await store.disconnectStripe() {
                            actionError = nil
                        } else {
                            actionError = store.stripeConnectError
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Stripe account will be unlinked. Payment links will stop working until you reconnect.")
            }
        } else if let provider = providers.first(where: { $0.id == store.settings.paymentProvider }) {
            Section(provider.label.uppercased()) {
                if let hint = providerHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if provider.id == NativeSquareProviderKeyPolicy.providerID {
                    // Fix round 2 (G5): the Square field is a draft saved
                    // explicitly, so a pasted access token is refused before
                    // it can persist or sync (never saved per keystroke).
                    TextField("Paste link or username here", text: $squareDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveSquareDraft)
                        .onAppear { squareDraft = store.settings.providerKey(for: provider.id) }
                    Button("Save link", action: saveSquareDraft)
                        .disabled(squareDraft == store.settings.providerKey(for: provider.id))
                    if let squareFeedback {
                        Text(squareFeedback.message)
                            .font(.caption)
                            .foregroundStyle(squareFeedback.isError ? Color.tradeDangerText : Color.secondary)
                    }
                } else {
                    TextField(
                        "Paste link or username here",
                        text: Binding(
                            get: { store.settings.providerKey(for: store.settings.paymentProvider) },
                            set: { store.setPaymentProviderKey($0, for: store.settings.paymentProvider) }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                Text("This appears in the payment links you send to customers — never paste a password, API key, or access token here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("PRIVACY") { Text("Review a prompt before sending. Secure provider credentials are never written to the local business-data file.").font(.caption).foregroundStyle(.secondary) }
    })
    .task { await store.refreshStripeStatus() }
    .onChange(of: scenePhase) { _, phase in
        // Returning from the browser onboarding is a refresh trigger only.
        if phase == .active { Task { await store.refreshStripeStatus() } }
    }
    .nativeAnalyticsScreen(.settingsPayments)
    }

    private func saveSquareDraft() {
        switch store.setPaymentProviderKey(squareDraft, for: NativeSquareProviderKeyPolicy.providerID) {
        case let .save(value):
            squareDraft = value
            squareFeedback = (value.isEmpty ? "Square link cleared." : "Square link saved.", false)
        case let .reject(message):
            // Fix round 3: a refused value (a pasted token) is not left on screen.
            squareDraft = ""
            squareFeedback = (message, true)
        }
    }

    private func connect() async {
        onboardBusy = true
        defer { onboardBusy = false }
        if let url = await store.beginStripeOnboarding() {
            actionError = nil
            openURL(url)
        } else {
            actionError = store.stripeConnectError
        }
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { SettingsPage(title: "Appearance", content: Group {
        Section { ForEach(Appearance.allCases) { appearance in Button { store.settings.appearance = appearance } label: { HStack { Image(systemName: appearance == .system ? "iphone" : appearance == .light ? "sun.max.fill" : "moon.fill").frame(width: 26); Text(appearance.title); Spacer(); if store.settings.appearance == appearance { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.tradeReady) } }.foregroundStyle(.primary) } } }
        Section { Text("System follows your iPhone or iPad appearance automatically.").font(.caption).foregroundStyle(.secondary) }
    })
    .nativeAnalyticsScreen(.settingsAppearance) }
}

/// Final-review I4: the former "Use business context" toggle was an
/// unpersisted `@State` nothing read (RN's SettingsAIScreen has no such
/// control) while the coach always sends the business summary — a false
/// privacy control, so it is removed and the privacy copy says what is sent.
/// The provider rows come from `AppStore.coachProviderSummary`, the same
/// precedence the coach transport routes by.
///
/// Task 11.15: RN's "Advanced" switch reveals Groq and Anthropic key entry
/// (secure fields, RN copy). Keys go only to the Keychain through
/// `AppStore.setAIProviderKey` / `clearAIProviderKey`; the page shows only
/// "Saved" for a stored key. Policy: `NativeAIProviderKeyPolicy`.
struct AISettings: View {
    @EnvironmentObject private var store: AppStore
    /// RN `useState(false)`: Advanced starts collapsed on every visit.
    @State private var showAdvanced = false
    var body: some View {
        let provider = store.coachProviderSummary
        SettingsPage(title: "AI Assistant", content: Group {
            Section {
                Text(NativeAIProviderKeyPolicy.introHint).font(.caption).foregroundStyle(.secondary)
                Toggle(NativeAIProviderKeyPolicy.advancedTitle, isOn: $showAdvanced)
                    .tint(Color.tradeReady)
                    .accessibilityLabel(NativeAIProviderKeyPolicy.advancedAccessibilityLabel)
            }
            if showAdvanced {
                ForEach(NativeAIProviderKeyKind.allCases, id: \.self) { kind in
                    AIProviderKeySection(kind: kind)
                }
            }
            Section("PROVIDER") { LabeledContent("Service", value: provider.service); LabeledContent("Connection", value: provider.connection) }
            Section("PRIVACY") {
                Text("Each coach message includes a summary of your business data (revenue, outstanding and overdue invoices, active jobs, top customers, tax estimate) so the coach can answer questions about your business. It is sent to the provider above.").font(.caption).foregroundStyle(.secondary)
                Text("Secure provider credentials are never written to the local business-data file.").font(.caption).foregroundStyle(.secondary)
            }
        })
        .nativeAnalyticsScreen(.settingsAI)
    }
}

/// One provider's key card. The typed key lives only in this view's state
/// until Save; a completed save or remove empties the field.
private struct AIProviderKeySection: View {
    @EnvironmentObject private var store: AppStore
    let kind: NativeAIProviderKeyKind
    @State private var entry = ""
    @State private var feedback: NativeAIProviderKeyChange?
    /// Phase 12 (L205.g): read from the Keychain on appear, after a save or
    /// remove, and when a boundary step starts or finishes — never in `body`.
    @State private var state: NativeAIProviderKeyPolicy.SavedState?

    var body: some View {
        Section {
            Text(kind.hint).font(.caption).foregroundStyle(.secondary)
            LabeledContent(
                NativeAIProviderKeyPolicy.statusTitle(for: kind),
                value: state.map(NativeAIProviderKeyPolicy.savedStatus) ?? ""
            )
            SecureField(kind.placeholder, text: $entry)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityLabel(kind.accessibilityLabel)
            Button(NativeAIProviderKeyPolicy.saveButtonTitle, action: save)
                .disabled(!NativeAIProviderKeyPolicy.canSubmit(entry))
            if let state, NativeAIProviderKeyPolicy.offersRemove(state) {
                Button(role: .destructive) {
                    finish(store.clearAIProviderKey(kind))
                } label: {
                    Text(NativeAIProviderKeyPolicy.removeButtonTitle).nativeDestructiveText()
                }
            }
            if let feedback {
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(feedback.isError ? Color.tradeDangerText : Color.secondary)
            }
        } footer: {
            Text(NativeAIProviderKeyPolicy.storageNote)
        }
        .onAppear(perform: refreshState)
        .onChange(of: store.isAccountBoundaryCleanupPending) { _, _ in refreshState() }
    }

    private func save() {
        guard NativeAIProviderKeyPolicy.canSubmit(entry) else { return }
        finish(store.setAIProviderKey(kind, entry: entry))
    }

    private func finish(_ change: NativeAIProviderKeyChange) {
        if change.clearsEntry { entry = "" }
        feedback = change
        refreshState()
    }

    private func refreshState() {
        state = store.aiProviderKeyState(kind)
    }
}

struct NotificationSettings: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var followUpNotifications: NativeEstimateFollowUpNotificationCoordinator
    @Environment(\.openURL) private var openURL
    var body: some View { SettingsPage(title: "Notifications", content: Group {
        Section {
            Toggle("Overdue invoice reminders", isOn: $store.settings.autoOutreachEnabled)
            Toggle("Email the first reminder automatically", isOn: $store.settings.autoSendEmailEnabled)
                .disabled(!store.settings.autoOutreachEnabled)
        } header: {
            Text("INVOICES")
        } footer: {
            Text("When an invoice becomes overdue, TradeReady can email the customer the first reminder without asking you.")
        }
        Section {
            Toggle("Appointment reminders", isOn: $store.settings.appointmentRemindersEnabled)
            Toggle("Estimate follow-ups", isOn: $store.settings.estimateFollowUpsEnabled)
            Toggle("Create invoice when complete", isOn: $store.settings.autoInvoiceOnComplete)
        } header: {
            Text("JOBS")
        } footer: {
            Text("Follow-up notifications remind you to contact customers; they never send a message automatically. Completing an eligible job can create its invoice automatically.")
        }
        Section("SYSTEM PERMISSION") {
            switch followUpNotifications.permissionState {
            case .authorized:
                Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.tradeSuccessText)
            case .notRequested, .unknown:
                Button("Enable notifications", systemImage: "bell.badge") {
                    Task {
                        if await followUpNotifications.requestAuthorization() {
                            await followUpNotifications.synchronize()
                        }
                    }
                }
            case .denied:
                Button("Open notification settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
        .task { await followUpNotifications.refreshPermissionState() }
    })
    .nativeAnalyticsScreen(.settingsNotifications) }
}

struct ReviewSettings: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { SettingsPage(title: "Review Requests", content: Group {
        Section { Toggle("Send review requests", isOn: $store.settings.reviewRequestEnabled) }
        Section("GOOGLE") {
            LabeledField(label: "Google review link") { TextField("https://g.page/r/…", text: $store.settings.googleReviewLink).keyboardType(.URL).textInputAutocapitalization(.never) }
            Stepper("Send \(store.settings.reviewRequestDelayHours) hour\(store.settings.reviewRequestDelayHours == 1 ? "" : "s") after completion", value: $store.settings.reviewRequestDelayHours, in: 0...168)
        }
        Section("MESSAGE TEMPLATE") { TextEditor(text: $store.settings.reviewRequestTemplate).frame(minHeight: 130); Text("Available fields: {customerName}, {businessName}, {googleReviewLink}").font(.caption).foregroundStyle(.secondary) }
    })
    .nativeAnalyticsScreen(.settingsReviews) }
}

struct SubscriptionSettings: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    @State private var notice: String?

    var body: some View { SettingsPage(title: "Subscription", content: Group {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "diamond.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.tradeReady)
                Text("TradeReady Pro").font(.title2.bold())
                Label(
                    store.isSubscriptionTrialing ? "Free trial active" : "Subscription active",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(store.isSubscriptionTrialing ? Color.tradeWarningText : Color.tradeSuccessText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
        Section {
            Button("Manage subscription") {
                let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!
                openURL(url) { accepted in
                    if !accepted {
                        notice = "Open the Settings app, tap your name, then tap Subscriptions to change or cancel TradeReady Pro."
                    }
                }
            }
            Button("Restore purchases") {
                Task {
                    switch await store.restoreSubscription() {
                    case .completed:
                        notice = "Your subscription has been restored."
                    case .noActiveSubscription:
                        notice = "We couldn't find an active subscription for this account."
                    case .failed(let message):
                        notice = message
                    case .cancelled:
                        break
                    }
                }
            }
            .disabled(store.subscriptionOperationInFlight)
        }
    })
    .alert("Subscription", isPresented: Binding(
        get: { notice != nil },
        set: { if !$0 { notice = nil } }
    )) {
        Button("OK") { notice = nil }
    } message: {
        Text(notice ?? "")
    }
    .nativeAnalyticsScreen(.settingsSubscription)
    }
}

struct AccountSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var resetConfirmation = false
    @State private var signOutConfirmation = false
    @State private var unsyncedSignOutConfirmation = false
    @State private var syncBeforeSignOutFailure = false
    @State private var remoteSignOutFailure = false
    @State private var localSignOutFailure = false
    @State private var isSigningOut = false
    @State private var deleteConfirmationPresented = false
    @State private var deleteConfirmationText = ""
    @State private var deleteFailurePresented = false
    @State private var deleteFailureMessage = ""
    @State private var isDeleting = false
    var body: some View { SettingsPage(title: "Account", content: Group {
        Section("PROFILE") { LabeledContent("Name", value: store.settings.contactName.isEmpty ? "Not set" : store.settings.contactName); LabeledContent("Email", value: store.settings.email.isEmpty ? "Not set" : store.settings.email); LabeledContent("Migrated session", value: store.authenticatedAccountState.displayValue) }
        Section("DATA") { Button { resetConfirmation = true } label: { Label("Reset demo data", systemImage: "arrow.counterclockwise") }.foregroundStyle(Color.tradeDangerText) }
        Section {
            Button(role: .destructive) {
                if store.syncStatus.pendingCount > 0 {
                    unsyncedSignOutConfirmation = true
                } else {
                    signOutConfirmation = true
                }
            } label: {
                Text("Sign out").nativeDestructiveText()
            }
                .disabled(isSigningOut)
            Button(role: .destructive) {
                deleteConfirmationText = ""
                deleteConfirmationPresented = true
            } label: {
                Text(isDeleting ? "Deleting account…" : "Delete account").nativeDestructiveText()
            }
                .disabled(isDeleting)
        } footer: {
            Text("TradeReady syncs saved changes to your account. Signing out removes this account's local records after giving pending changes a chance to upload. Deleting your account permanently removes its server data and local records.")
        }
    })
    .confirmationDialog(
        "Replace local records with demo data?",
        isPresented: $resetConfirmation,
        titleVisibility: .visible
    ) {
        Button("Reset", role: .destructive) { store.resetDemoData() }
        Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
        "Sign out and remove local data?",
        isPresented: $signOutConfirmation,
        titleVisibility: .visible
    ) {
        Button("Sign out", role: .destructive) { performSignOut(revokeRemote: true) }
        Button("Cancel", role: .cancel) {}
    } message: {
        Text("This account's local records will be removed from this device.")
    }
    .confirmationDialog(
        "Unsynced changes",
        isPresented: $unsyncedSignOutConfirmation,
        titleVisibility: .visible
    ) {
        Button("Sync & sign out") { performSyncAndSignOut() }
        Button("Sign out anyway", role: .destructive) { performSignOut(revokeRemote: true) }
        Button("Cancel", role: .cancel) {}
    } message: {
        Text("\(store.syncStatus.pendingCount) change\(store.syncStatus.pendingCount == 1 ? "" : "s") haven't reached the cloud yet. Sync first to keep them.")
    }
    .alert("Changes are still waiting", isPresented: $syncBeforeSignOutFailure) {
        Button("Try again") { performSyncAndSignOut() }
        Button("Keep me signed in", role: .cancel) {}
    } message: {
        Text("TradeReady kept you signed in and preserved the pending changes on this device. Check your connection and try again.")
    }
    .alert("Session could not be revoked", isPresented: $remoteSignOutFailure) {
        Button("Sign out on this device", role: .destructive) {
            performSignOut(revokeRemote: false)
        }
        Button("Keep me signed in", role: .cancel) {}
    } message: {
        Text("Your local data is still intact. You can retry later or explicitly remove the account from this device without contacting the server.")
    }
    .alert("Sign-out cleanup incomplete", isPresented: $localSignOutFailure) {
        Button("OK", role: .cancel) {}
    } message: {
        Text("TradeReady kept account access blocked where possible. Try signing out again before another person uses this device.")
    }
    .alert("Account not deleted", isPresented: $deleteFailurePresented) {
        Button("OK", role: .cancel) {}
    } message: {
        Text(deleteFailureMessage)
    }
    .sheet(isPresented: $deleteConfirmationPresented) {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes your account and all server and device data, including jobs, invoices, customers, and expenses. This cannot be undone.")
                        .foregroundStyle(.secondary)
                }
                Section("TYPE DELETE TO CONFIRM") {
                    TextField(NativeAccountDeletionConfirmation.phrase, text: $deleteConfirmationText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type DELETE to confirm account deletion")
                }
            }
            .nativeContentColumn(.list)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isDeleting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { deleteConfirmationPresented = false }
                        .disabled(isDeleting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) { performDeleteAccount() } label: {
                        Text("Delete").nativeDestructiveText()
                    }
                        .disabled(
                            isDeleting
                                || !NativeAccountDeletionConfirmation.matches(deleteConfirmationText)
                        )
                }
            }
        }
    }
    .nativeAnalyticsScreen(.settingsAccount)
    }

    private func performSignOut(revokeRemote: Bool) {
        isSigningOut = true
        Task {
            defer { isSigningOut = false }
            do {
                try await store.signOut(revokeRemote: revokeRemote)
            } catch NativeAccountSignOutError.remoteRevocationFailed {
                remoteSignOutFailure = true
            } catch {
                localSignOutFailure = true
            }
        }
    }

    private func performSyncAndSignOut() {
        isSigningOut = true
        Task {
            _ = await store.syncNowAndWait()
            guard store.syncStatus.pendingCount == 0,
                  store.syncStatus.diagnosticCode == nil
            else {
                isSigningOut = false
                syncBeforeSignOutFailure = true
                return
            }
            do {
                try await store.signOut(revokeRemote: true)
            } catch NativeAccountSignOutError.remoteRevocationFailed {
                remoteSignOutFailure = true
            } catch {
                localSignOutFailure = true
            }
            isSigningOut = false
        }
    }

    private func performDeleteAccount() {
        guard NativeAccountDeletionConfirmation.matches(deleteConfirmationText) else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await store.deleteAccount()
                deleteConfirmationPresented = false
            } catch {
                // Task 11.09: RN `SettingsAccountScreen.tsx:61` reports here.
                store.reportError(error, context: ["context": "deleteAccount"])
                deleteConfirmationPresented = false
                deleteFailureMessage = error.localizedDescription
                deleteFailurePresented = true
            }
        }
    }
}
