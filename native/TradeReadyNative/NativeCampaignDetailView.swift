import SwiftUI

// MARK: - Phase 33: campaign detail and results (spec §8, §7.2 resume)
//
// Results are derived on every read (`AppStore.campaignResults`): sent,
// replied, booked (via link or within 30 days), won and collected. Each sent
// recipient's row can be marked Replied or opted out. A campaign in progress
// resumes here at its first pending recipient.

struct NativeCampaignDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let campaignID: String

    @State private var session: NativeCampaignSessionRequest?
    @State private var optingOut: NativeCampaignResults.RecipientRow?
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    @State private var duplicated: String?

    var body: some View {
        Group {
            if let campaign = store.campaign(id: campaignID) {
                let results = store.campaignResults(campaign)
                let status = NativeCampaignQueue.campaignStatus(campaign)
                List {
                    Section {
                        Text(NativeCampaignListView.statusLine(campaign)).foregroundStyle(.secondary)
                        if status == .sending {
                            Button {
                                session = .init(id: campaign.id)
                            } label: {
                                Label("Resume sending", systemImage: "paperplane").frame(maxWidth: .infinity)
                            }
                            .tradeReadyProminentButtonStyle()
                        }
                    }

                    Section {
                        Text(results.headline(formatMoney: { NSDecimalNumber(decimal: $0).doubleValue.currency }))
                            .font(.headline)
                        LabeledContent("Sent", value: "\(results.sent)")
                        LabeledContent("Replied", value: "\(results.replied)")
                        LabeledContent("Booked", value: results.bookedViaLink > 0
                                       ? "\(results.booked) (\(results.bookedViaLink) via link)" : "\(results.booked)")
                        LabeledContent("Won", value: "\(results.won)")
                        LabeledContent("Collected", value: NSDecimalNumber(decimal: results.collected).doubleValue.currency)
                    } header: {
                        Text("Results")
                    } footer: {
                        Text(NativeCampaignResults.footer)
                    }

                    Section {
                        Text("Got a STOP or \"no thanks\" reply? Mark that person opted out.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(results.rows) { row in recipientRow(campaign, row) }
                    } header: {
                        Text("Recipients (\(results.rows.count))")
                    }

                    Section {
                        if let text = campaign.message.text, !text.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Text message").font(.subheadline.weight(.semibold))
                                Text(text).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if let body = campaign.message.emailBody, !body.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Email").font(.subheadline.weight(.semibold))
                                if let subject = campaign.message.emailSubject { Text("Subject: \(subject)") }
                                Text(body).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Message")
                    } footer: {
                        Text(campaign.message.lockedAt == nil
                             ? "The message locks after the first send."
                             : "Locked after the first send. Duplicate the campaign to change it.")
                    }

                    Section {
                        Button("Duplicate campaign", systemImage: "plus.square.on.square") {
                            switch store.duplicateCampaign(id: campaign.id) {
                            case let .success(copy): duplicated = copy.name
                            case .failure: errorMessage = "The copy could not be saved. Nothing was changed."
                            }
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete campaign", systemImage: "trash").nativeDestructiveText()
                        }
                    } footer: {
                        if let duplicated { Text("Saved \"\(duplicated)\" as a draft in Campaigns.") }
                    }
                }
                .nativeContentColumn(.list)
                .tradeReadyListStyle()
                .navigationTitle(campaign.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                EmptyContent(title: "Campaign unavailable", message: "This campaign is no longer on this device.", symbol: "megaphone")
            }
        }
        .fullScreenCover(item: $session) { request in
            NativeCampaignSendView(campaignID: request.id)
        }
        .confirmationDialog(
            "Mark \(optingOut?.name ?? "them") as Do not contact?",
            isPresented: Binding(get: { optingOut != nil }, set: { if !$0 { optingOut = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(NativeMarketingOptOut.Via.pickable, id: \.self) { via in
                Button(via.displayName) {
                    if let row = optingOut, !store.setMarketingOptOut(customerID: row.customerID, via: via) {
                        errorMessage = "That couldn't be saved. Try again."
                    }
                    optingOut = nil
                }
            }
            Button("Cancel", role: .cancel) { optingOut = nil }
        } message: {
            Text("Future campaigns skip them. Invoices and appointment messages still work.")
        }
        .confirmationDialog("Delete this campaign?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete campaign", role: .destructive) {
                if store.deleteCampaign(id: campaignID) { dismiss() } else {
                    errorMessage = "The campaign could not be deleted. Nothing was changed."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its results stop showing. You can undo for a few seconds.")
        }
        .alert("Campaign", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func recipientRow(_ campaign: Canonical.Campaign, _ row: NativeCampaignResults.RecipientRow) -> some View {
        let optedOut = store.canonicalCustomer(id: row.customerID)?.isMarketingOptedOut ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name).font(.body)
                Spacer()
                Text(statusText(row)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let bookedOn = row.bookedOn {
                Label("Booked \(Self.shortDate(bookedOn))", systemImage: "calendar.badge.checkmark")
                    .font(.caption).foregroundStyle(Color.tradeSuccessText)
            }
            if row.status == .sent {
                HStack(spacing: 12) {
                    Button(row.repliedOn == nil ? "Mark replied" : "Replied ✓") {
                        if case .failure = store.setCampaignRecipientReplied(
                            campaignID: campaign.id, customerID: row.customerID, replied: row.repliedOn == nil
                        ) { errorMessage = "That couldn't be saved. Try again." }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(row.repliedOn == nil ? "Mark \(row.name) as replied" : "\(row.name) replied. Tap to clear")
                    if optedOut {
                        Text("No marketing").font(.caption).foregroundStyle(Color.tradeWarningText)
                    } else {
                        Button("Mark opted out") { optingOut = row }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Mark \(row.name) opted out")
                    }
                }
            } else if row.status == .failed, NativeCampaignQueue.campaignStatus(campaign) == .sending {
                Button("Retry") {
                    if case .failure = store.retryCampaignRecipient(campaignID: campaign.id, customerID: row.customerID) {
                        errorMessage = "That couldn't be saved. Try again."
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry \(row.name)")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ row: NativeCampaignResults.RecipientRow) -> String {
        switch row.status {
        case .pending: "Not sent yet"
        case .sent: row.manual ? "Sent (marked)" : "Sent"
        case .failed: "Didn't send"
        case .skipped: "Skipped" + (row.skipReason.map { ": \($0.displayName)" } ?? "")
        }
    }

    /// "Oct 12" from a local `YYYY-MM-DD`.
    static func shortDate(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let date = Int(parts[2]), (1...12).contains(month) else { return day }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month - 1]) \(date)"
    }
}
