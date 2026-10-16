import SwiftUI
import UIKit

// MARK: - Phase 33: the send session (spec §7.2–§7.4, D1)
//
// Full screen, one recipient at a time. "Open in Messages/Mail" re-checks the
// live customer, then presents Apple's composer with exactly ONE recipient and
// the fully rendered message; the owner reviews it and taps Send there. Only a
// `.sent` outcome (or the owner's "Mark as sent") records a send. With "Open
// the next one automatically" on, the next composer opens once the previous
// sheet has gone (the InvoicesView `onDismiss` chain). Every outcome is saved
// in the synced campaign right away, so Pause, an app kill or another device
// resumes at the first pending recipient.

struct NativeCampaignSendView: View {
    private struct ComposerItem: Identifiable {
        let id = UUID()
        let customerID: String
        let name: String
        let draft: NativeAppointmentMessageDraft
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let campaignID: String

    @State private var bookingLink: AppStore.CampaignBookingLinkState = .unknown
    @State private var isCheckingLink = false
    @State private var autoAdvance = true
    @State private var composer: ComposerItem?
    @State private var composerGone = true
    @State private var advanceAfterDismiss = false
    @State private var awaitingFallbackFor: String?
    @State private var isWorking = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var copiedFor: String?
    @State private var confirmingMarkSent = false
    @State private var confirmingStop = false
    @State private var confirmingEnd = false

    private var campaign: Canonical.Campaign? { store.campaign(id: campaignID) }

    private var current: Canonical.Campaign.Recipient? {
        guard let campaign, let index = NativeCampaignQueue.nextPendingIndex(campaign) else { return nil }
        return campaign.recipients?[index]
    }

    var body: some View {
        NavigationStack {
            List {
                if let campaign {
                    progressSection(campaign)
                    if let warning = NativeCampaignQueue.quietHoursWarning(now: .now) {
                        Section {
                            Label(warning, systemImage: "moon").font(.footnote).foregroundStyle(Color.tradeWarningText)
                        }
                    }
                    if let current {
                        recipientSection(campaign, current)
                    } else {
                        finishedSection(campaign)
                    }
                    failedSection(campaign)
                    Section {
                        Text("Got a STOP or \"no thanks\" reply? Mark that person opted out on their customer page or in the campaign's results.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("This campaign is no longer on this device.").foregroundStyle(.secondary)
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle(campaign?.name ?? "Campaign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Pause") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    if campaign.map({ NativeCampaignQueue.campaignStatus($0) == .sending }) == true {
                        Button("End") { confirmingEnd = true }
                            .accessibilityLabel("End campaign")
                            .accessibilityHint("Asks before skipping everyone not yet sent")
                    }
                }
            }
            .sheet(item: $composer, onDismiss: composerDidDismiss) { item in
                NativeMessageComposer(draft: item.draft) { outcome in finished(item, outcome) }
                    .ignoresSafeArea()
            }
            .confirmationDialog("Mark \(current?.name ?? "them") as sent?", isPresented: $confirmingMarkSent, titleVisibility: .visible) {
                Button("Mark as sent") { markSent() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use this when you sent the message yourself, for example by pasting it.")
            }
            .confirmationDialog("Did \(current?.name ?? "they") ask to stop?", isPresented: $confirmingStop, titleVisibility: .visible) {
                Button("Mark Do not contact and skip", role: .destructive) { askedToStop() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They won't get this or any future campaign. Invoices and appointment messages still work.")
            }
            .confirmationDialog("End this campaign?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("End campaign", role: .destructive) { endCampaign() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everyone not yet sent is skipped. Results keep counting.")
            }
            .alert("Campaign", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: resolveLinkIfNeeded)
        }
    }

    // MARK: Sections

    private func progressSection(_ campaign: Canonical.Campaign) -> some View {
        let progress = NativeCampaignQueue.progress(campaign)
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(progress.sent) of \(progress.total) sent" + (progress.skipped > 0 ? " · \(progress.skipped) skipped" : ""))
                    .font(.headline)
                ProgressView(value: Double(progress.sent + progress.skipped), total: Double(max(progress.total, 1)))
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            if let notice {
                Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func recipientSection(_ campaign: Canonical.Campaign, _ recipient: Canonical.Campaign.Recipient) -> some View {
        let channel = NativeCampaignQueue.channel(recipient)
        let kind: NativeCampaignMessage.Kind = channel == .text ? .text : .email
        let live = store.canonicalCustomer(id: recipient.customerId)
        let contact = channel == .text ? (live?.phone ?? "") : (live?.email ?? "")
        let rendered = store.renderCampaignMessage(
            campaign, kind: kind, customerID: recipient.customerId, fallbackName: recipient.name, bookingLink: bookingLink
        )
        let lastService = NativeServiceHistory.lastService(
            customerID: recipient.customerId,
            jobsByCustomer: NativeServiceHistory.jobsByCustomer(store.canonicalJobs)
        )
        let composerAvailable = NativeMessageComposer.canPresent(channel == .text ? .sms : .email)
        let linkBlocked = usesBookingLink(campaign) && bookingLink.url == nil
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(recipient.name).font(.title3.bold())
                Label("\(channel.displayName): \(contact.isEmpty ? "missing" : contact)",
                      systemImage: channel == .text ? "message" : "envelope")
                    .font(.subheadline)
                if let lastService {
                    Text("Last service: \(NativeCampaignMessage.monthYear(lastService.date) ?? lastService.date)\(lastService.title.isEmpty ? "" : " · \(lastService.title)")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                if let subject = rendered.subject { Text("Subject: \(subject)").font(.subheadline.weight(.semibold)) }
                Text(rendered.body).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Message: \(rendered.subject.map { "Subject \($0). " } ?? "")\(rendered.body)")

            if linkBlocked {
                HStack {
                    Text(isCheckingLink ? "Checking your booking link…"
                         : bookingLink == .off ? "Your booking link is off. Turn it on in Settings to send this message."
                         : "Your booking link couldn't be checked.")
                        .font(.footnote).foregroundStyle(Color.tradeWarningText)
                    Spacer()
                    if !isCheckingLink, bookingLink != .off {
                        Button("Retry") { resolveLink() }.buttonStyle(.borderless)
                    }
                }
            }

            if awaitingFallbackFor == recipient.customerId {
                Text("Did you send it?").font(.headline)
                HStack {
                    Button("Sent") { markSent() }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Yes, I sent it to \(recipient.name)")
                    Button("Not sent") { awaitingFallbackFor = nil }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("No, I didn't send it")
                }
            } else {
                Button {
                    open(campaign, recipient, rendered: rendered, composerAvailable: composerAvailable)
                } label: {
                    Label(primaryTitle(channel, composerAvailable: composerAvailable),
                          systemImage: channel == .text ? "message" : "envelope")
                        .frame(maxWidth: .infinity)
                }
                .tradeReadyProminentButtonStyle()
                .disabled(isWorking || composer != nil || linkBlocked)
            }
            Toggle("Open the next one automatically", isOn: $autoAdvance)
        } header: {
            Text("Next up")
        } footer: {
            Text("Nothing is sent until you tap Send in the composer. Only this person is in the message.")
        }

        Section {
            Button("Skip", systemImage: "forward") { skip() }.disabled(isWorking)
            Button("They asked to stop", systemImage: "hand.raised") { confirmingStop = true }.disabled(isWorking)
            Button(copiedFor == recipient.customerId ? "Copied" : "Copy message",
                   systemImage: copiedFor == recipient.customerId ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = [rendered.subject.map { "Subject: \($0)" }, rendered.body]
                    .compactMap { $0 }.joined(separator: "\n\n")
                copiedFor = recipient.customerId
            }
            Button("Mark as sent", systemImage: "checkmark.circle") { confirmingMarkSent = true }.disabled(isWorking)
        }
    }

    private func finishedSection(_ campaign: Canonical.Campaign) -> some View {
        Section {
            Text(NativeCampaignQueue.summary(campaign)).font(.headline)
            Button("Done") { dismiss() }
                .tradeReadyProminentButtonStyle()
        } header: {
            Text(NativeCampaignQueue.campaignStatus(campaign) == .done ? "Campaign done" : "Everyone's been handled")
        }
    }

    @ViewBuilder
    private func failedSection(_ campaign: Canonical.Campaign) -> some View {
        let failed = (campaign.recipients ?? []).filter { NativeCampaignQueue.status($0) == .failed }
        if !failed.isEmpty {
            Section("Didn't send (\(failed.count))") {
                ForEach(failed, id: \.customerId) { recipient in
                    HStack {
                        Text(recipient.name)
                        Spacer()
                        Button("Retry") { retry(recipient.customerId) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Retry \(recipient.name)")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func primaryTitle(_ channel: NativeCampaignSegments.Channel, composerAvailable: Bool) -> String {
        switch (channel, composerAvailable) {
        case (.text, true): "Open in Messages"
        case (.email, true): "Open in Mail"
        case (.text, false): "Open in Messages app"
        case (.email, false): "Open in your mail app"
        }
    }

    /// Spec §7.3: the live check first (a failing customer is skipped with
    /// the reason), then exactly one composer, or the URL-scheme fallback.
    private func open(
        _ campaign: Canonical.Campaign,
        _ recipient: Canonical.Campaign.Recipient,
        rendered: NativeCampaignMessage.Rendered,
        composerAvailable: Bool
    ) {
        guard !isWorking, composer == nil else { return }
        isWorking = true
        defer { isWorking = false }
        notice = nil
        switch store.prepareCampaignRecipient(campaignID: campaign.id, customerID: recipient.customerId) {
        case let .success(.skip(reason)):
            notice = "Skipped \(recipient.name): \(reason.displayName)."
        case let .success(.ready(contact)):
            let channel = NativeCampaignQueue.channel(recipient)
            if composerAvailable {
                composerGone = false
                composer = ComposerItem(
                    customerID: recipient.customerId,
                    name: recipient.name,
                    draft: .init(channel: channel == .text ? .sms : .email, recipient: contact,
                                 subject: rendered.subject, body: rendered.body)
                )
            } else {
                let url = channel == .text
                    ? NativeCampaignMessage.smsURL(phone: contact, body: rendered.body)
                    : NativeCampaignMessage.mailtoURL(email: contact, subject: rendered.subject ?? "", body: rendered.body)
                guard let url else {
                    errorMessage = "This message couldn't be opened. Copy it instead."
                    return
                }
                openURL(url)
                awaitingFallbackFor = recipient.customerId
            }
        case .failure(.notSaved):
            errorMessage = "Progress couldn't be saved. Nothing was sent. Try again."
        case .failure:
            errorMessage = "This recipient is no longer in the campaign."
        }
    }

    private func finished(_ item: ComposerItem, _ outcome: NativeMessageComposeOutcome) {
        composer = nil
        switch store.recordCampaignOutcome(campaignID: campaignID, customerID: item.customerID,
                                           outcome: outcome, autoAdvance: autoAdvance) {
        case let .success(result):
            notice = result.notice ?? (outcome == .sent ? "Sent to \(item.name)." : nil)
            advanceAfterDismiss = result.advances && current != nil
        case .failure(.notSaved) where outcome == .sent:
            advanceAfterDismiss = false
            let first = NativeCampaignMessage.firstName(item.name)
            errorMessage = "Sent, but couldn't save progress. Mark \(first == "there" ? item.name : first) as sent before continuing."
        case .failure:
            advanceAfterDismiss = false
            errorMessage = "Progress couldn't be saved. Try again."
        }
        if composerGone { advanceIfRequested() }
    }

    private func composerDidDismiss() {
        composerGone = true
        advanceIfRequested()
    }

    /// The next composer opens only after the previous sheet is gone.
    private func advanceIfRequested() {
        guard advanceAfterDismiss, composer == nil else { return }
        advanceAfterDismiss = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard composer == nil, let campaign, let next = current else { return }
            let channel = NativeCampaignQueue.channel(next)
            let rendered = store.renderCampaignMessage(
                campaign, kind: channel == .text ? .text : .email, customerID: next.customerId,
                fallbackName: next.name, bookingLink: bookingLink
            )
            let available = NativeMessageComposer.canPresent(channel == .text ? .sms : .email)
            guard available, !(usesBookingLink(campaign) && bookingLink.url == nil) else { return }
            open(campaign, next, rendered: rendered, composerAvailable: available)
        }
    }

    private func markSent() {
        guard let recipient = current else { return }
        awaitingFallbackFor = nil
        if case .failure = store.markCampaignRecipientSent(campaignID: campaignID, customerID: recipient.customerId) {
            errorMessage = "Progress couldn't be saved. Try again."
        } else {
            notice = "Marked \(recipient.name) as sent."
        }
    }

    private func skip() {
        guard !isWorking, let recipient = current else { return }
        awaitingFallbackFor = nil
        if case .failure = store.skipCampaignRecipient(campaignID: campaignID, customerID: recipient.customerId) {
            errorMessage = "Progress couldn't be saved. Try again."
        } else {
            notice = "Skipped \(recipient.name)."
        }
    }

    private func askedToStop() {
        guard let recipient = current else { return }
        awaitingFallbackFor = nil
        if case .failure = store.campaignRecipientAskedToStop(campaignID: campaignID, customerID: recipient.customerId) {
            errorMessage = "That couldn't be saved. Try again."
        } else {
            notice = "\(recipient.name) is marked Do not contact and skipped."
        }
    }

    private func retry(_ customerID: String) {
        if case .failure = store.retryCampaignRecipient(campaignID: campaignID, customerID: customerID) {
            errorMessage = "That couldn't be saved. Try again."
        }
    }

    private func endCampaign() {
        if case .failure = store.endCampaign(id: campaignID) {
            errorMessage = "The campaign couldn't be ended. Try again."
        }
    }

    private func usesBookingLink(_ campaign: Canonical.Campaign) -> Bool {
        [campaign.message.text, campaign.message.emailBody, campaign.message.emailSubject]
            .contains { NativeCampaignMessage.uses(.bookingLink, in: $0) }
    }

    private func resolveLinkIfNeeded() {
        guard let campaign, usesBookingLink(campaign), bookingLink == .unknown else { return }
        resolveLink()
    }

    private func resolveLink() {
        guard !isCheckingLink else { return }
        isCheckingLink = true
        Task { @MainActor in
            bookingLink = await store.resolveCampaignBookingLink()
            isCheckingLink = false
        }
    }
}
