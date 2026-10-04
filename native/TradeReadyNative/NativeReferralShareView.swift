import SwiftUI
import UIKit

/// Phase 34 (referrals, spec 2026-10-03-referral-program-design.md §5.5):
/// customer detail › "Share referral link". The shape of
/// `NativeReviewRequestView`: a Text/Email recipient, an editable message
/// prefilled with the customer's personal booking link, and hand-off to the
/// system composer (or a copy for manual sending). Nothing is sent
/// automatically, and a send records nothing: sharing is not delivery evidence
/// and implies no reward.
struct NativeReferralShareView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let customerID: String

    @State private var channel: NativeAppointmentMessageChannel = .sms
    @State private var message = ""
    @State private var linkState: NativeReferralLinkState?
    @State private var isChecking = false
    @State private var showingComposer = false
    @State private var showingUnavailable = false
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let dismissAfter: Bool
    }

    private var customer: Canonical.Customer? {
        store.canonicalCustomers.first { $0.id == customerID }
    }

    private var recipient: String {
        guard let customer else { return "" }
        let value = channel == .email ? customer.email : customer.phone
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isReady: Bool {
        if case .ready = linkState { return true }
        return false
    }

    private var messageIsBlank: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerDraft: NativeAppointmentMessageDraft {
        .init(
            channel: channel,
            recipient: recipient,
            subject: channel == .email ? "A booking link to pass along" : nil,
            body: message
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let customer {
                    Section("Recipient") {
                        Text(customer.name).font(.headline)
                        Picker("Channel", selection: $channel) {
                            Text("Text").tag(NativeAppointmentMessageChannel.sms)
                            Text("Email").tag(NativeAppointmentMessageChannel.email)
                        }
                        .pickerStyle(.segmented)
                        if recipient.isEmpty {
                            Text(channel == .email
                                 ? "Add an email address to this customer, or copy the message for manual sending."
                                 : "Add a phone number to this customer, or copy the message for manual sending.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            LabeledContent(channel == .email ? "Email" : "Text", value: recipient)
                        }
                    }
                    linkSection
                    if isReady {
                        Section("Referral message") {
                            TextEditor(text: $message)
                                .frame(minHeight: 180)
                                .accessibilityLabel("Referral message")
                        }
                    }
                    Section {
                        Button {
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
                        .disabled(!isReady || recipient.isEmpty || messageIsBlank || showingComposer)

                        Button {
                            UIPasteboard.general.string = message
                            notice = Notice(title: "Message copied", message: "Paste it into your preferred messaging app.", dismissAfter: false)
                        } label: {
                            Label("Copy for manual sending", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!isReady || messageIsBlank)
                    } footer: {
                        Text("Nothing is sent automatically. People who book through this link never see who referred them.")
                    }
                } else {
                    ContentUnavailableView("Customer unavailable", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Share referral link")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .task { await checkLink() }
            .sheet(isPresented: $showingComposer) {
                NativeMessageComposer(draft: composerDraft) { outcome in
                    showingComposer = false
                    switch outcome {
                    case .sent:
                        notice = Notice(title: "Referral link sent", message: "Sent to \(customer?.name ?? "the customer") by \(channel == .email ? "email" : "text").", dismissAfter: true)
                    case .saved:
                        notice = Notice(title: "Draft saved", message: "The message was saved as a draft.", dismissAfter: false)
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
    }

    @ViewBuilder
    private var linkSection: some View {
        if isChecking || linkState == nil {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(NativeReferrals.checkingLinkText).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } else if let linkState, let text = linkState.message {
            Section("Referral link") {
                Label(text, systemImage: linkState == .bookingLinkOff ? "link.badge.plus" : "exclamationmark.triangle")
                    .foregroundStyle(Color.tradeWarningText)
                if linkState != .bookingLinkOff {
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await checkLink() } }
                        .disabled(isChecking)
                }
            }
        }
    }

    /// One verified status read at a time; the message is prefilled once and
    /// never overwritten after the owner starts editing.
    private func checkLink() async {
        guard !isChecking else { return }
        isChecking = true
        let state = await store.referralShareLink(customerID: customerID)
        linkState = state
        isChecking = false
        if case let .ready(url) = state, message.isEmpty, let customer {
            message = NativeReferrals.renderShareMessage(
                customerName: NativeReferrals.firstName(customer.name),
                businessName: store.settings.businessName,
                link: url
            )
            channel = customer.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .email : .sms
        }
    }
}
