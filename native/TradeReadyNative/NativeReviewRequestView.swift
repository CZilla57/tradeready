import SwiftUI
import UIKit

struct NativeReviewRequestView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String

    @State private var channel: NativeAppointmentMessageChannel = .sms
    @State private var message = ""
    @State private var showingComposer = false
    @State private var showingUnavailable = false
    @State private var copied = false
    @State private var notice: Notice?

    private var draft: NativeReviewRequestDraft? { store.reviewRequestDraft(jobID: jobID) }
    private var recipient: String {
        guard let draft else { return "" }
        return channel == .email ? draft.customerEmail : draft.customerPhone
    }
    private var composerDraft: NativeAppointmentMessageDraft {
        .init(
            channel: channel,
            recipient: recipient,
            subject: channel == .email ? "Thanks for choosing \(store.settings.businessName)!" : nil,
            body: message
        )
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let dismissAfter: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    Section("Recipient") {
                        Text(draft.customerName).font(.headline)
                        Picker("Channel", selection: $channel) {
                            Text("Text").tag(NativeAppointmentMessageChannel.sms)
                            Text("Email").tag(NativeAppointmentMessageChannel.email)
                        }
                        .pickerStyle(.segmented)
                        if recipient.isEmpty {
                            Text("Add a phone number or email address before sending.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            LabeledContent(channel == .email ? "Email" : "Text", value: recipient)
                        }
                    }
                    Section("Review message") {
                        TextEditor(text: $message)
                            .frame(minHeight: 180)
                            .accessibilityLabel("Review request message")
                        Button {
                            UIPasteboard.general.string = message
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy message", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    if draft.missingLink {
                        Section {
                            Label("Add your Google review link in Settings before sending.", systemImage: "link.badge.plus")
                                .foregroundStyle(Color.tradeWarningText)
                        }
                    }
                    Section {
                        Button {
                            guard !draft.missingLink else { return }
                            if NativeMessageComposer.canPresent(channel) {
                                showingComposer = true
                            } else {
                                showingUnavailable = true
                            }
                        } label: {
                            Label(channel == .email ? "Continue to Mail" : "Continue to Messages",
                                  systemImage: channel == .email ? "envelope" : "message")
                                .frame(maxWidth: .infinity)
                        }
                        .tradeReadyProminentButtonStyle()
                        .disabled(recipient.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.missingLink)

                        Button {
                            UIPasteboard.general.string = message
                            notice = Notice(title: "Message copied", message: "Paste it into your preferred messaging app.", dismissAfter: false)
                        } label: {
                            Label("Copy for manual sending", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text("Nothing is sent automatically. Review the message again and tap Send in the system composer.")
                    }
                } else {
                    ContentUnavailableView("Review request unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Request a review")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .onAppear {
                guard let draft, message.isEmpty else { return }
                message = draft.message
                channel = draft.customerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .email : .sms
            }
            .sheet(isPresented: $showingComposer) {
                NativeMessageComposer(draft: composerDraft) { outcome in
                    showingComposer = false
                    switch outcome {
                    case .sent:
                        store.markReviewRequestSent(
                            jobID: jobID,
                            fallback: draft?.fallback,
                            channel: channel == .email ? .email : .sms
                        )
                        notice = Notice(title: "Review request sent", message: "Sent to \(draft?.customerName ?? "the customer") by \(channel == .email ? "email" : "text").", dismissAfter: true)
                    case .saved:
                        notice = Notice(title: "Draft saved", message: "The request was not recorded as sent.", dismissAfter: false)
                    case .failed:
                        notice = Notice(title: "Message not sent", message: "The message remains available to edit.", dismissAfter: false)
                    case .cancelled:
                        break
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Composer unavailable", isPresented: $showingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(channel == .email ? "Set up a Mail account on this device, or copy the message for manual sending." : "Messages is not available on this device. Copy the message for manual sending.")
            }
            .alert(item: $notice) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text(notice.dismissAfter ? "Done" : "OK")) {
                    if notice.dismissAfter { dismiss() }
                })
            }
        }
        .nativeAnalyticsScreen(.reviewRequest)
    }
}
