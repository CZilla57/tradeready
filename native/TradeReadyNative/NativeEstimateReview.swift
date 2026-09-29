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
    let draft: NativeEstimateReviewDraft

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

    init(draft: NativeEstimateReviewDraft) {
        self.draft = draft
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
                    ForEach(Array(draft.snapshot.lineItems.enumerated()), id: \.offset) { _, line in
                        LabeledContent(line.label, value: money(line.amount))
                    }
                    LabeledContent("Total", value: money(draft.snapshot.total))
                        .font(.headline)
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
                        Button("Create approval link", systemImage: "link") {
                            createApprovalLink()
                        }
                        .disabled(isCreatingLink)
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
                            if store.markEstimateSent(
                                id: draft.jobID,
                                from: draft.expectedStatus
                            ) { dismiss() }
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
            .alert("Couldn’t create approval link", isPresented: Binding(
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
        isCreatingLink = true
        Task {
            let outcome = await store.createEstimateApprovalLink(for: draft)
            isCreatingLink = false
            switch outcome {
            case .success(let link):
                approvalLink = link.url
                if !emailBody.contains(link.url.absoluteString) {
                    emailBody += "\n\nView and approve your estimate here:\n\(link.url.absoluteString)"
                }
                if !textBody.contains(link.url.absoluteString) {
                    textBody += " View & approve: \(link.url.absoluteString)"
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
