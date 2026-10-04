import SwiftUI
import UIKit

private struct NativeEstimatePDFExport: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct NativeEstimateDeliveryNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let dismissReviewAfterAcknowledgement: Bool
}

struct NativeEstimateReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// Phase 32: rebuilt through the store when the owner changes the
    /// valid-until date, so the snapshot, messages and PDF follow it.
    @State private var draft: NativeEstimateReviewDraft

    @State private var channel: NativeEstimateMessageChannel
    @State private var emailSubject: String
    @State private var emailBody: String
    @State private var textBody: String
    @State private var showingComposer = false
    @State private var showingUnavailable = false
    @State private var approvalLink: URL?
    @State private var isCreatingLink = false
    @State private var linkErrorMessage: String?
    @State private var dismissAfterLinkError = false
    @State private var pdfExport: NativeEstimatePDFExport?
    @State private var pdfExportCleanupURL: URL?
    @State private var isExportingPDF = false
    @State private var pdfErrorMessage: String?
    @State private var deliveryNotice: NativeEstimateDeliveryNotice?
    @State private var copiedMessage = false
    @State private var showingRegenerateConfirmation = false
    @State private var showingValidityEditor = false
    @State private var lastChosenValidUntil: String?
    /// Channels whose owner-edited message was kept across a date change.
    @State private var staleEditedChannels: Set<NativeEstimateMessageChannel> = []
    @State private var validityErrorMessage: String?
    @State private var markSentErrorMessage: String?
    @State private var linkErrorTitle = "Couldn’t create approval link"

    init(draft: NativeEstimateReviewDraft) {
        _draft = State(initialValue: draft)
        _lastChosenValidUntil = State(initialValue: draft.validUntil)
        let initial: NativeEstimateMessageChannel = draft.customerEmail.isEmpty && !draft.customerPhone.isEmpty
            ? .text : .email
        let preparedEmail = NativeEstimateMessageDrafting.prepare(review: draft, channel: .email)
        let preparedText = NativeEstimateMessageDrafting.prepare(review: draft, channel: .text)
        _channel = State(initialValue: initial)
        _emailSubject = State(initialValue: preparedEmail.subject)
        _emailBody = State(initialValue: preparedEmail.body)
        _textBody = State(initialValue: preparedText.body)
    }

    private var recipient: String {
        channel == .email ? draft.customerEmail : draft.customerPhone
    }

    private var visibleSubject: String {
        channel == .email ? emailSubject : ""
    }

    private var visibleBody: String {
        channel == .email ? emailBody : textBody
    }

    private var visibleBodyBinding: Binding<String> {
        Binding(
            get: { channel == .email ? emailBody : textBody },
            set: { value in
                if channel == .email { emailBody = value }
                else { textBody = value }
            }
        )
    }

    /// Once a link is minted in this sheet its date is the customer's; the
    /// date can only change through a fresh review or "Extend" on the job.
    private var validityLocked: Bool { approvalLink != nil || isCreatingLink }

    private var validityToday: String { store.estimateValidityToday() }

    private var validUntilText: String {
        draft.validUntil.map { NativeQuoteExpiry.displayDate($0, style: .medium) } ?? "Doesn’t expire"
    }

    private var fallbackValidUntil: String {
        NativeValidUntilPicker.fallback(
            lastChosen: lastChosenValidUntil,
            validityDays: store.settings.estimateValidityDays,
            today: validityToday
        )
    }

    private var doesNotExpireBinding: Binding<Bool> {
        Binding(
            get: { draft.validUntil == nil },
            set: { doesNotExpire in
                applyValidity(doesNotExpire ? .doesNotExpire : .date(fallbackValidUntil))
            }
        )
    }

    private var validUntilDateBinding: Binding<Date> {
        Binding(
            get: { NativeValidUntilPicker.date(from: draft.validUntil ?? fallbackValidUntil) ?? Date() },
            set: { applyValidity(.date(NativeValidUntilPicker.ymd(from: $0))) }
        )
    }

    /// The customer's current, unanswered approval link (a re-send).
    private var undecidedLinkApproval: Canonical.EstimateApproval? {
        guard let approval = store.activeEstimateApproval(jobID: draft.jobID),
              approval.decision == nil
        else { return nil }
        return approval
    }

    /// §6.4: the existing link still shows a different date than this draft.
    private var staleLinkDateNote: String? {
        guard approvalLink == nil, let approval = undecidedLinkApproval,
              approval.snapshot.validUntil != draft.validUntil
        else { return nil }
        let shown = approval.snapshot.validUntil
            .map { NativeQuoteExpiry.displayDate($0, style: .medium) } ?? "no valid-until date"
        return "The customer’s approval link still shows \(shown). Update the approval link so it matches."
    }

    private var composerDraft: NativeAppointmentMessageDraft {
        .init(
            channel: channel == .email ? .email : .sms,
            recipient: recipient,
            subject: channel == .email ? emailSubject : nil,
            body: visibleBody
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Estimate") {
                    Text(draft.snapshot.jobTitle).font(.headline)
                    LabeledContent("Customer", value: draft.snapshot.customerName)
                    if !draft.serviceAddress.isEmpty { LabeledContent("Service address", value: draft.serviceAddress) }
                    if let options = draft.snapshot.options {
                        optionRows(options)
                    } else {
                        ForEach(Array(draft.snapshot.lineItems.enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.label, value: money(line.amount))
                        }
                        LabeledContent("Total", value: money(draft.snapshot.total))
                            .font(.headline)
                    }
                    validityRow
                    Button {
                        exportPDF()
                    } label: {
                        if isExportingPDF {
                            Label("Preparing PDF…", systemImage: "hourglass")
                        } else {
                            Label("Save or share PDF", systemImage: "doc.richtext")
                        }
                    }
                    .disabled(isExportingPDF)
                }

                Section {
                    Picker("Channel", selection: $channel) {
                        ForEach(NativeEstimateMessageChannel.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: channel) { _, _ in copiedMessage = false }
                    if recipient.isEmpty {
                        Text("Add a customer \(channel == .email ? "email address" : "phone number") before continuing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Recipient", value: recipient)
                    }
                    if channel == .email {
                        TextField("Subject", text: $emailSubject)
                    }
                    TextEditor(text: visibleBodyBinding)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Estimate message")
                    if staleEditedChannels.contains(channel) {
                        Text("Your edited message may mention the old date. Use Restore default message to update it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button {
                            copyMessage()
                        } label: {
                            Label(copiedMessage ? "Copied" : "Copy", systemImage: copiedMessage ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel(copiedMessage ? "Message copied" : "Copy estimate message")

                        Spacer()

                        Button {
                            requestRegeneration()
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .accessibilityHint("Restores the default message from this reviewed estimate")
                    }
                    .buttonStyle(.bordered)
                    if let approvalLink {
                        LabeledContent("Approval link") {
                            Text(approvalLink.absoluteString)
                                .font(.caption)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Button(
                            undecidedLinkApproval == nil ? "Create approval link" : "Update approval link",
                            systemImage: "link"
                        ) {
                            createApprovalLink()
                        }
                        .disabled(isCreatingLink)
                        if let staleLinkDateNote {
                            Text(staleLinkDateNote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        if NativeMessageComposer.canPresent(composerDraft.channel) {
                            showingComposer = true
                        } else {
                            showingUnavailable = true
                        }
                    } label: {
                        Label(
                            channel == .email ? "Continue to Mail" : "Continue to Messages",
                            systemImage: channel == .email ? "envelope" : "message"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .tradeReadyProminentButtonStyle()
                    .disabled(recipient.isEmpty || isCreatingLink)
                } header: {
                    Text("Delivery")
                } footer: {
                    Text("Nothing is sent automatically. Review the draft again and tap Send in the system composer.")
                }

                if draft.expectedStatus == .lead {
                    Section {
                        Button("Mark estimate as sent", systemImage: "checkmark.circle") {
                            // Only this attempt's refusal explains a failure.
                            store.migrationMessage = nil
                            if store.markEstimateSent(
                                id: draft.jobID,
                                from: draft.expectedStatus,
                                validUntil: draft.validUntil
                            ) {
                                dismiss()
                            } else {
                                markSentErrorMessage = store.migrationMessage
                                    ?? "The estimate could not be marked sent. Nothing was changed."
                            }
                        }
                    } footer: {
                        Text("Use this only after delivering the estimate. It starts the approval follow-up clock without claiming a message was sent automatically.")
                    }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Send Estimate")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .sheet(isPresented: $showingComposer) {
                NativeMessageComposer(
                    draft: composerDraft,
                    onFinish: handleComposerOutcome
                )
                .ignoresSafeArea()
            }
            .sheet(item: $pdfExport, onDismiss: cleanupPDFExport) { export in
                NativeActivitySheet(items: [export.url])
                    .ignoresSafeArea()
            }
            .alert("Composer unavailable", isPresented: $showingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(channel == .email
                     ? "Set up a Mail account on this device and try again."
                     : "Messages is not available on this device.")
            }
            .alert("Couldn’t change the date", isPresented: Binding(
                get: { validityErrorMessage != nil },
                set: { if !$0 { validityErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { validityErrorMessage = nil }
            } message: {
                Text(validityErrorMessage ?? "Close this estimate and review it again.")
            }
            .alert("Couldn’t mark the estimate sent", isPresented: Binding(
                get: { markSentErrorMessage != nil },
                set: { if !$0 { markSentErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { markSentErrorMessage = nil }
            } message: {
                Text(markSentErrorMessage ?? "Please try again.")
            }
            .alert(linkErrorTitle, isPresented: Binding(
                get: { linkErrorMessage != nil },
                set: { if !$0 { linkErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    linkErrorMessage = nil
                    if dismissAfterLinkError { dismiss() }
                }
            } message: {
                Text(linkErrorMessage ?? "Please try again.")
            }
            .alert("Couldn’t create PDF", isPresented: Binding(
                get: { pdfErrorMessage != nil },
                set: { if !$0 { pdfErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { pdfErrorMessage = nil }
            } message: {
                Text(pdfErrorMessage ?? "Please try again.")
            }
            .alert(item: $deliveryNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(notice.dismissReviewAfterAcknowledgement ? "Done" : "OK")) {
                        if notice.dismissReviewAfterAcknowledgement { dismiss() }
                    }
                )
            }
            .confirmationDialog(
                "Replace edited message?",
                isPresented: $showingRegenerateConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore default message", role: .destructive) {
                    applyPreparedMessage(for: channel)
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("This replaces your current subject and message. The reviewed estimate and approval link stay unchanged.")
            }
            .onDisappear { cleanupPDFExport() }
        }
        .nativeAnalyticsScreen(.estimateReview)
    }

    /// Phase 25 (good/better/best): every tier of an undecided options
    /// snapshot in order (name, a text "Recommended" marker, description, its
    /// lines and its total), then the optional add-ons. An accepted estimate's
    /// snapshot has no `options`, so it keeps the single-estimate rows above.
    @ViewBuilder
    private func optionRows(_ options: Canonical.EstimateApprovalSnapshot.Options) -> some View {
        ForEach(Array(options.tiers.enumerated()), id: \.offset) { index, tier in
            let isRecommended = tier.id == options.recommendedTierId
            VStack(alignment: .leading, spacing: 4) {
                Text("Option \(index + 1): \(tier.name)")
                    .font(.headline)
                if isRecommended {
                    Label("Recommended", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tradeInfoText)
                }
                if let description = tier.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, index == 0 ? 0 : 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(tier.lineItems.enumerated()), id: \.offset) { _, line in
                LabeledContent(line.label, value: money(line.amount))
            }
            LabeledContent("Option \(index + 1) total", value: money(tier.total))
                .font(.headline)
        }
        if !options.addOns.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Optional add-ons")
                    .font(.headline)
                Text("The customer can add any of these to the option they choose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(options.addOns.enumerated()), id: \.offset) { _, addOn in
                LabeledContent {
                    Text("+\(money(addOn.amount))")
                } label: {
                    Text(addOn.label)
                    if let description = addOn.description, !description.isEmpty {
                        Text(description)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(addOnAccessibilityLabel(addOn))
            }
        }
    }

    /// Phase 32 (spec §6.4): "Valid until" with the date or "Doesn't
    /// expire"; expanding it shows the "Doesn't expire" toggle and a date
    /// picker limited to today…today+365. Locked once a link is created here.
    @ViewBuilder
    private var validityRow: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { showingValidityEditor && !validityLocked },
            set: { showingValidityEditor = $0 }
        )) {
            Toggle("Doesn’t expire", isOn: doesNotExpireBinding)
            if draft.validUntil != nil {
                DatePicker(
                    "Valid-until date",
                    selection: validUntilDateBinding,
                    in: NativeValidUntilPicker.range(today: validityToday),
                    displayedComponents: .date
                )
            }
            Text("Customers can’t approve the estimate online after this date.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } label: {
            LabeledContent("Valid until", value: validUntilText)
        }
        .disabled(validityLocked)
        .accessibilityHint(validityLocked
            ? "The approval link was created with this date."
            : "Shows options to change the date the customer can approve this estimate until.")
    }

    /// Changes the draft's date through the store. Only the date and its
    /// zone change: the prices and names stay the ones the owner reviewed
    /// (review fix 2026-10-03), so the send-time guards still catch a newer
    /// estimate. Messages the owner has not edited are regenerated; edited
    /// ones keep their text and get a footnote.
    private func applyValidity(_ choice: NativeEstimateValidUntilChoice) {
        guard !validityLocked else { return }
        let requested: String? = if case .date(let date) = choice { date } else { nil }
        guard requested != draft.validUntil else { return }
        store.migrationMessage = nil
        guard let rebuilt = store.estimateReviewDraft(draft, changingValidUntilTo: choice) else {
            validityErrorMessage = store.migrationMessage
                ?? "The estimate could not be updated. Close it and review it again."
            return
        }
        if let requested { lastChosenValidUntil = requested }
        let oldEmail = NativeEstimateMessageDrafting.prepare(review: draft, channel: .email)
        let oldText = NativeEstimateMessageDrafting.prepare(review: draft, channel: .text)
        let newEmail = NativeEstimateMessageDrafting.prepare(review: rebuilt, channel: .email)
        let newText = NativeEstimateMessageDrafting.prepare(review: rebuilt, channel: .text)
        draft = rebuilt
        if emailSubject == oldEmail.subject && emailBody == oldEmail.body {
            emailSubject = newEmail.subject
            emailBody = newEmail.body
        } else if newEmail != oldEmail {
            staleEditedChannels.insert(.email)
        }
        if textBody == oldText.body {
            textBody = newText.body
        } else if newText.body != oldText.body {
            staleEditedChannels.insert(.text)
        }
        copiedMessage = false
    }

    private func addOnAccessibilityLabel(_ addOn: Canonical.EstimateApprovalSnapshot.OptionAddOn) -> String {
        var parts = ["Optional add-on: \(addOn.label)", "adds \(money(addOn.amount))"]
        if let description = addOn.description, !description.isEmpty { parts.append(description) }
        return parts.joined(separator: ", ")
    }

    private func copyMessage() {
        let visible = NativeEstimatePreparedMessage(
            subject: visibleSubject,
            body: visibleBody
        )
        UIPasteboard.general.string = visible.clipboardText(channel: channel)
        copiedMessage = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedMessage = false
        }
    }

    private func requestRegeneration() {
        let regenerated = NativeEstimateMessageDrafting.prepare(
            review: draft,
            channel: channel,
            approvalLink: approvalLink
        )
        let hasEdits = visibleBody != regenerated.body
            || (channel == .email && emailSubject != regenerated.subject)
        if hasEdits {
            showingRegenerateConfirmation = true
        } else {
            applyPreparedMessage(for: channel)
        }
    }

    private func applyPreparedMessage(for channel: NativeEstimateMessageChannel) {
        let prepared = NativeEstimateMessageDrafting.prepare(
            review: draft,
            channel: channel,
            approvalLink: approvalLink
        )
        if channel == .email {
            emailSubject = prepared.subject
            emailBody = prepared.body
        } else {
            textBody = prepared.body
        }
        staleEditedChannels.remove(channel)
        copiedMessage = false
    }

    private func handleComposerOutcome(_ outcome: NativeMessageComposeOutcome) {
        showingComposer = false
        switch NativeEstimateDeliveryPolicy.resolution(for: outcome) {
        case .recordDelivery:
            switch store.recordEstimateDelivery(for: draft) {
            case .recorded:
                dismiss()
            case .preservedNewerState:
                deliveryNotice = .init(
                    title: "Estimate sent; job preserved",
                    message: "The job changed while the composer was open, so the current job was not overwritten. Review it before sending another estimate.",
                    dismissReviewAfterAcknowledgement: true
                )
            case .failed:
                deliveryNotice = .init(
                    title: "Sent status not saved",
                    message: "The composer reported the estimate as sent, but TradeReady could not save that status. Your existing job data was preserved.",
                    dismissReviewAfterAcknowledgement: true
                )
            }
        case .keepReview:
            break
        case .keepReviewWithSavedDraftNotice:
            deliveryNotice = .init(
                title: "Draft saved in Mail",
                message: "The estimate was not marked sent. You can continue editing or reopen Mail when you’re ready.",
                dismissReviewAfterAcknowledgement: false
            )
        case .keepReviewWithFailureNotice:
            deliveryNotice = .init(
                title: "Message not sent",
                message: "The system composer could not send the estimate. Your draft is still here so you can try again.",
                dismissReviewAfterAcknowledgement: false
            )
        }
    }

    @MainActor
    private func exportPDF() {
        isExportingPDF = true
        cleanupPDFExport()
        do {
            let document = NativeEstimatePDFDocument(review: draft)
            let data = try NativeEstimatePDFRenderer.data(
                for: document,
                logoReference: draft.businessLogoReference
            )
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "TradeReadyEstimateExports", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appending(path: document.filename, directoryHint: .notDirectory)
            try data.write(to: url, options: .atomic)
            pdfExportCleanupURL = url
            pdfExport = NativeEstimatePDFExport(url: url)
        } catch {
            pdfErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The estimate PDF could not be created. Your job and estimate were not changed."
        }
        isExportingPDF = false
    }

    private func cleanupPDFExport() {
        pdfExport = nil
        guard let url = pdfExportCleanupURL else { return }
        pdfExportCleanupURL = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func createApprovalLink() {
        guard !isCreatingLink else { return }
        linkErrorTitle = undecidedLinkApproval == nil
            ? "Couldn’t create approval link" : "Couldn’t update approval link"
        showingValidityEditor = false
        isCreatingLink = true
        Task {
            let outcome = await store.createEstimateApprovalLink(for: draft)
            isCreatingLink = false
            switch outcome {
            case .success(let link):
                approvalLink = link.url
                // Phase 25: an options snapshot invites a choice, not a yes.
                let hasOptions = draft.snapshot.options != nil
                if !emailBody.contains(link.url.absoluteString) {
                    emailBody += hasOptions
                        ? "\n\nView your options and approve here:\n\(link.url.absoluteString)"
                        : "\n\nView and approve your estimate here:\n\(link.url.absoluteString)"
                }
                if !textBody.contains(link.url.absoluteString) {
                    textBody += hasOptions
                        ? " View options & approve: \(link.url.absoluteString)"
                        : " View & approve: \(link.url.absoluteString)"
                }
            case .failure(let error):
                dismissAfterLinkError = error == .estimateChanged
                    || store.jobs.first(where: { $0.id == draft.jobID })?.status != draft.expectedStatus
                linkErrorMessage = error.localizedDescription
            }
        }
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.currency
    }

}
