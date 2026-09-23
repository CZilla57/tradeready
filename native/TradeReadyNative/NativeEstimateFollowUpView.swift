import SwiftUI
import UIKit

private struct NativeEstimateFollowUpNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let dismissAfterAcknowledgement: Bool
}

struct NativeEstimateFollowUpView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: NativeEstimateFollowUpDraft

    @State private var channel: NativeEstimateMessageChannel
    @State private var bodyText: String
    @State private var showingComposer = false
    @State private var showingUnavailable = false
    @State private var copied = false
    @State private var notice: NativeEstimateFollowUpNotice?

    init(draft: NativeEstimateFollowUpDraft) {
        self.draft = draft
        let initial: NativeEstimateMessageChannel = draft.customerPhone.isEmpty ? .email : .text
        _channel = State(initialValue: initial)
        _bodyText = State(initialValue: draft.body)
    }

    private var recipient: String {
        channel == .email ? draft.customerEmail : draft.customerPhone
    }

    private var composerDraft: NativeAppointmentMessageDraft {
        .init(
            channel: channel == .email ? .email : .sms,
            recipient: recipient,
            subject: channel == .email ? draft.emailSubject : nil,
            body: bodyText
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Estimate") {
                    Text(draft.customerName).font(.headline)
                    LabeledContent("Job", value: draft.jobTitle)
                    LabeledContent(
                        "Amount",
                        value: NSDecimalNumber(decimal: draft.estimateTotal).doubleValue.currency
                    )
                    if let sentDate = draft.sentDate {
                        LabeledContent(
                            "Sent",
                            value: sentDate.formatted(date: .abbreviated, time: .omitted)
                        )
                    }
                }

                Section("Review message") {
                    Picker("Channel", selection: $channel) {
                        Text("Text").tag(NativeEstimateMessageChannel.text)
                        Text("Email").tag(NativeEstimateMessageChannel.email)
                    }
                    .pickerStyle(.segmented)

                    if recipient.isEmpty {
                        Text("Add a customer \(channel == .email ? "email address" : "phone number") before continuing with this channel.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent(channel == .email ? "Email" : "Text", value: recipient)
                    }

                    TextEditor(text: $bodyText)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Follow-up message")

                    Button {
                        UIPasteboard.general.string = bodyText
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy message", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(copied ? "Message copied" : "Copy follow-up message")
                }

                Section {
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
                    .buttonStyle(.borderedProminent)
                    .disabled(recipient.isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Nothing is sent automatically. Review the message again and tap Send in the system composer. Following up does not change the job status.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Estimate Follow-Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showingComposer) {
                NativeMessageComposer(draft: composerDraft, onFinish: handleComposerOutcome)
                    .ignoresSafeArea()
            }
            .alert("Composer unavailable", isPresented: $showingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(channel == .email
                     ? "Set up a Mail account on this device and try again."
                     : "Messages is not available on this device.")
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(notice.dismissAfterAcknowledgement ? "Done" : "OK")) {
                        if notice.dismissAfterAcknowledgement { dismiss() }
                    }
                )
            }
        }
    }

    private func handleComposerOutcome(_ outcome: NativeMessageComposeOutcome) {
        showingComposer = false
        switch outcome {
        case .sent:
            notice = .init(
                title: "Follow-up sent",
                message: "Sent to \(draft.customerName) by \(channel == .email ? "email" : "text").",
                dismissAfterAcknowledgement: true
            )
        case .saved:
            notice = .init(
                title: "Draft saved in Mail",
                message: "The follow-up was not recorded as sent. Your editable message remains available.",
                dismissAfterAcknowledgement: false
            )
        case .failed:
            notice = .init(
                title: "Message not sent",
                message: "The system composer could not send the follow-up. Your editable message remains available.",
                dismissAfterAcknowledgement: false
            )
        case .cancelled:
            break
        }
    }
}
