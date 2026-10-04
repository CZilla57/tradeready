import SwiftUI

/// Phase 34 (referrals, spec 2026-10-03-referral-program-design.md §5.4,
/// §5.7): customer detail's "Referrals" section and the customer editor's
/// "Referred by" picker. Both live here so the shared customer screens only
/// gain one line each.
///
/// The section keeps no state of record: every action goes through `AppStore`
/// (`referralSummary`, `resetReferralCode`, the share and reward sheets),
/// which re-resolves the stored customer by id.
struct NativeCustomerReferralsSection: View {
    @EnvironmentObject private var store: AppStore
    let customerID: String
    let customerName: String

    @State private var showingShare = false
    @State private var confirmingReset = false
    @State private var rewardTarget: RewardTarget?
    @State private var errorMessage: String?

    private struct RewardTarget: Identifiable {
        let id: String
        let name: String
    }

    private var firstName: String {
        let name = NativeReferrals.firstName(customerName)
        return name.isEmpty ? "this customer" : name
    }

    var body: some View {
        if let summary = store.referralSummary(customerID: customerID) {
            Section {
                referredByRow(summary.referredBy)
                if !summary.referred.isEmpty {
                    Text(summary.summaryText)
                        .font(.subheadline.weight(.semibold))
                    if summary.creditOwed > 0 {
                        LabeledContent("Credit owed", value: NativeReferrals.money(summary.creditOwed))
                    }
                    ForEach(summary.referred) { entry in
                        NavigationLink {
                            CustomerDetailView(customerID: entry.id, fallbackName: entry.name)
                        } label: {
                            entryRow(entry)
                        }
                        Button(entry.hasReward ? "Edit thank-you" : "Record thank-you",
                               systemImage: entry.hasReward ? "pencil" : "gift") {
                            rewardTarget = RewardTarget(id: entry.id, name: entry.name)
                        }
                        .accessibilityLabel(entry.hasReward
                                            ? "Edit thank-you for referring \(entry.name)"
                                            : "Record thank-you for referring \(entry.name)")
                    }
                }
                Button("Share referral link", systemImage: "square.and.arrow.up") {
                    showingShare = true
                }
                if summary.hasCode {
                    Button("Reset referral link", systemImage: "arrow.triangle.2.circlepath") {
                        confirmingReset = true
                    }
                    .foregroundStyle(Color.tradeDangerText)
                }
            } header: {
                Text("Referrals")
            } footer: {
                Text("When someone books through \(firstName)'s link, they're recorded as referred by \(firstName). Nothing is sent automatically.")
            }
            .sheet(isPresented: $showingShare) {
                NativeReferralShareView(customerID: customerID)
            }
            .sheet(item: $rewardTarget) { target in
                NativeReferralRewardSheet(
                    referredCustomerID: target.id,
                    referredName: target.name,
                    referrerName: customerName
                )
            }
            .confirmationDialog(
                "Reset \(firstName)'s referral link?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset link", role: .destructive) {
                    if !store.resetReferralCode(customerID: customerID) {
                        errorMessage = store.migrationMessage
                            ?? "The referral link could not be reset. The current link still works."
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Links \(firstName) already shared still open your booking page, but new bookings from them won't be credited to \(firstName).")
            }
            .alert("Referral link not reset", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func referredByRow(_ referredBy: NativeReferralCustomerSummary.ReferredBy) -> some View {
        switch referredBy {
        case .none:
            EmptyView()
        case let .customer(id, name, isArchived):
            NavigationLink {
                CustomerDetailView(customerID: id, fallbackName: name)
            } label: {
                LabeledContent("Referred by", value: isArchived ? "\(name) (Archived)" : name)
            }
        case .formerCustomer:
            LabeledContent("Referred by", value: "A former customer")
        }
    }

    private func entryRow(_ entry: NativeReferralEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            NativeAccessibilityAdaptiveRow(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NativeReferrals.money(entry.collected))
                    .font(.subheadline.monospacedDigit())
                    .layoutPriority(1)
            }
            if let joined = entry.joinedText {
                Text(joined).font(.caption).foregroundStyle(.secondary)
            }
            Label(entry.rewardStatus, systemImage: entry.hasReward ? "checkmark.circle" : "gift")
                .font(.caption)
                .foregroundStyle(entry.hasReward ? Color.tradeSuccessText : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor: "Referred by" (§5.4)

/// The editor row shown while "How they found you" is Referral / word of
/// mouth. Most referrals are recorded here, by word of mouth, with no link.
struct NativeReferredByRow: View {
    @EnvironmentObject private var store: AppStore
    let customerID: String
    @Binding var referredByCustomerId: String?

    private var label: String {
        guard let id = referredByCustomerId, !id.isEmpty else { return "None" }
        guard let referrer = store.customers.first(where: { $0.id == id }) else { return "A former customer" }
        return NativeCustomerIdentity.isArchived(referrer) ? "\(referrer.name) (Archived)" : referrer.name
    }

    var body: some View {
        NavigationLink {
            NativeReferredByPicker(customerID: customerID, selection: $referredByCustomerId)
        } label: {
            LabeledContent("Referred by", value: label)
        }
    }
}

/// Every customer except this one, archived ones included and labelled, plus
/// "None". Picking a row returns to the editor.
struct NativeReferredByPicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let customerID: String
    @Binding var selection: String?
    @State private var search = ""

    private var candidates: [Customer] {
        store.customers
            .filter {
                $0.id != customerID
                    && (search.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(search)
                        || $0.email.localizedCaseInsensitiveContains(search)
                        || $0.phone.localizedCaseInsensitiveContains(search))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                choiceRow(title: "None", detail: nil, isSelected: (selection ?? "").isEmpty) {
                    selection = nil
                }
            }
            Section("Customers") {
                if candidates.isEmpty {
                    Text("No matching customers").foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    choiceRow(
                        title: candidate.name,
                        detail: NativeCustomerIdentity.isArchived(candidate) ? "Archived" : nil,
                        isSelected: selection == candidate.id
                    ) {
                        selection = candidate.id
                    }
                }
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .searchable(text: $search, prompt: "Search customers")
        .navigationTitle("Referred by")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choiceRow(title: String, detail: String?, isSelected: Bool, choose: @escaping () -> Void) -> some View {
        Button {
            choose()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
