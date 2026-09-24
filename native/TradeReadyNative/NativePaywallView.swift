import SwiftUI

struct NativePaywallView: View {
    @EnvironmentObject private var store: AppStore
    let offering: NativeSubscriptionOffering?
    let loadMessage: String?

    @State private var selectedPackageID: String?
    @State private var notice: String?
    @State private var confirmSignOut = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var heroBadgeSize: CGFloat = 72

    private let features = [
        "Unlimited jobs, invoices & customers",
        "Trade pricing calculator with break-even alerts",
        "Stripe payment links — get paid fast",
        "P&L dashboard & expense tracking",
        "AI assistant for estimates & outreach messages",
        "Invoice reminder notifications",
    ]

    init(offering: NativeSubscriptionOffering?, loadMessage: String?) {
        self.offering = offering
        self.loadMessage = loadMessage
        _selectedPackageID = State(initialValue: offering?.preferredPackageID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: heroIconSize, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: heroBadgeSize, height: heroBadgeSize)
                    .background(Color.tradeReady.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                VStack(spacing: 6) {
                    Text("TradeReady")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Everything you need to run your trade business")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let trial = selectedPackage?.trial {
                    Label(trial.badge, systemImage: "gift")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.green.opacity(0.11), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.primary, .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))

                plans

                Button(selectedPackage?.trial == nil ? "Subscribe" : "Start Free Trial") {
                    purchase()
                }
                .tradeReadyProminentButtonStyle()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(selectedPackage == nil || store.subscriptionOperationInFlight)

                Text(selectedPackage?.trial?.detail ?? "Renews automatically. Cancel anytime.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Restore purchases") { restore() }
                    .disabled(store.subscriptionOperationInFlight)
                Button("Sign out", role: .destructive) { confirmSignOut = true }
                    .disabled(store.subscriptionOperationInFlight)

                HStack(spacing: 8) {
                    Link("Privacy Policy", destination: URL(string: "https://gettradereadyapp.com/privacy.html")!)
                    Text("·").foregroundStyle(.secondary)
                    Link("Terms of Service", destination: URL(string: "https://gettradereadyapp.com/terms.html")!)
                }
                .font(.footnote)
                Text("Subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage it in your Apple ID account settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.tradeCanvas)
        .overlay {
            if store.subscriptionOperationInFlight {
                ProgressView().padding(16).background(.regularMaterial, in: Capsule())
            }
        }
        .alert("Subscription", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog("Sign out of TradeReady?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) {
                Task {
                    do { try await store.signOut() }
                    catch { notice = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out does not bypass the subscription gate. You can sign in with another account or restore purchases.")
        }
    }

    @ViewBuilder
    private var plans: some View {
        if let loadMessage {
            VStack(spacing: 12) {
                Text(loadMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { store.retrySubscriptionGate() }
                    .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
        } else if let offering, offering.packages.isEmpty {
            VStack(spacing: 12) {
                Text("Subscription plans aren't available right now. This is usually temporary — please try again in a moment.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { store.retrySubscriptionGate() }
                    .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
        } else if let offering {
            VStack(spacing: 12) {
                ForEach(offering.packages) { package in
                    Button {
                        selectedPackageID = package.id
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: selectedPackageID == package.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.period == .annual ? "Annual" : "Monthly").font(.headline)
                                Text(package.period == .annual ? "billed yearly" : "billed monthly, cancel anytime")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if package.period == .annual {
                                Text("BEST VALUE").font(.caption2.bold()).foregroundStyle(.green)
                            }
                            Text(package.localizedPrice).font(.headline)
                        }
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(selectedPackageID == package.id ? Color.tradeReady : Color.secondary.opacity(0.25), lineWidth: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(package.period == .annual ? "Annual" : "Monthly") plan, \(package.localizedPrice)")
                    .accessibilityAddTraits(selectedPackageID == package.id ? .isSelected : [])
                }
            }
        }
    }

    private var selectedPackage: NativeSubscriptionPackage? {
        offering?.packages.first { $0.id == selectedPackageID }
    }

    private func purchase() {
        guard let selectedPackageID else { return }
        Task {
            switch await store.purchaseSubscription(packageID: selectedPackageID) {
            case .completed, .cancelled: break
            case .noActiveSubscription:
                notice = "The purchase finished, but TradeReady Pro is not active yet. Try Restore purchases in a moment."
            case .failed(let message): notice = message
            }
        }
    }

    private func restore() {
        Task {
            switch await store.restoreSubscription() {
            case .completed: notice = "Your subscription has been restored."
            case .cancelled: break
            case .noActiveSubscription:
                notice = "We couldn't find an active subscription for this account."
            case .failed(let message): notice = message
            }
        }
    }
}
