import SwiftUI
import MessageUI

/// Presents Apple's message or mail composer with a prefilled draft. Neither
/// path sends until the user explicitly taps Send in the system UI.
struct NativeMessageComposer: UIViewControllerRepresentable {
    let draft: NativeAppointmentMessageDraft
    let onFinish: (NativeMessageComposeOutcome) -> Void

    static func canPresent(_ channel: NativeAppointmentMessageChannel) -> Bool {
        switch channel {
        case .sms: MFMessageComposeViewController.canSendText()
        case .email: MFMailComposeViewController.canSendMail()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch draft.channel {
        case .sms:
            let controller = MFMessageComposeViewController()
            controller.messageComposeDelegate = context.coordinator
            controller.recipients = [draft.recipient]
            controller.body = draft.body
            return controller
        case .email:
            let controller = MFMailComposeViewController()
            controller.mailComposeDelegate = context.coordinator
            controller.setToRecipients([draft.recipient])
            controller.setSubject(draft.subject ?? "")
            controller.setMessageBody(draft.body, isHTML: false)
            for attachment in draft.attachments {
                controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
            }
            return controller
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onFinish: (NativeMessageComposeOutcome) -> Void

        init(onFinish: @escaping (NativeMessageComposeOutcome) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            let outcome: NativeMessageComposeOutcome = switch result {
            case .sent: .sent
            case .cancelled: .cancelled
            case .failed: .failed
            @unknown default: .failed
            }
            controller.dismiss(animated: true) { self.onFinish(outcome) }
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            let outcome: NativeMessageComposeOutcome = switch result {
            case .sent: .sent
            case .cancelled: .cancelled
            case .saved: .saved
            case .failed: .failed
            @unknown default: .failed
            }
            controller.dismiss(animated: true) { self.onFinish(outcome) }
        }
    }
}

struct NativeOnMyWayReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let draft: NativeAppointmentMessageDraft?
    @State private var bodyText: String
    @State private var showingComposer = false
    @State private var showingUnavailable = false

    init(job: Job, customer: Customer?, settings: BusinessSettings) {
        let input = NativeAppointmentMessageInput(
            customerName: customer?.name ?? job.customerName,
            customerPhone: customer?.phone ?? "",
            customerEmail: customer?.email ?? "",
            customerAddress: customer?.address ?? "",
            jobAddress: job.address,
            scheduledDate: job.scheduledAt?.dateOnlyString,
            scheduledStartTime: job.scheduledAt?.nativeAppointmentTime,
            businessName: settings.businessName,
            appointmentConfirmationTemplate: settings.appointmentConfirmTemplate,
            onMyWayTemplate: settings.onMyWayTemplate
        )
        if case let .draft(value) = NativeAppointmentMessaging.draft(kind: .onMyWay, input: input) {
            draft = value
            _bodyText = State(initialValue: value.body)
        } else {
            draft = nil
            _bodyText = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    Form {
                        Section("Recipient") {
                            LabeledContent(draft.channel == .sms ? "Text" : "Email", value: draft.recipient)
                        }
                        Section("Review message") {
                            TextEditor(text: $bodyText)
                                .frame(minHeight: 180)
                                .accessibilityLabel("On my way message")
                        }
                        Section {
                            Button {
                                if NativeMessageComposer.canPresent(draft.channel) {
                                    showingComposer = true
                                    store.recordAppointmentComposerOpened(onMyWay: true)
                                } else {
                                    showingUnavailable = true
                                }
                            } label: {
                                Label(
                                    draft.channel == .sms ? "Continue to Messages" : "Continue to Mail",
                                    systemImage: draft.channel == .sms ? "message" : "envelope"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } footer: {
                            Text("Nothing is sent until you review it again and tap Send in the system composer.")
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No contact info", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text("Add a phone number or email address for this customer before sending an on-my-way message.")
                    }
                }
            }
            .navigationTitle("On my way")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showingComposer) {
                if let draft {
                    NativeMessageComposer(
                        draft: .init(
                            channel: draft.channel,
                            recipient: draft.recipient,
                            subject: draft.subject,
                            body: bodyText
                        ),
                        onFinish: { outcome in
                            showingComposer = false
                            if outcome == .sent { dismiss() }
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .alert("Composer unavailable", isPresented: $showingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(draft?.channel == .sms
                     ? "Messages is not available on this device."
                     : "Set up a Mail account on this device and try again.")
            }
        }
    }
}

struct NativeAppointmentConfirmationReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let draft: NativeAppointmentMessageDraft?
    @State private var bodyText: String
    @State private var showingComposer = false
    @State private var showingUnavailable = false

    init(job: Job, customer: Customer?, settings: BusinessSettings) {
        let input = NativeAppointmentMessageInput(
            customerName: customer?.name ?? job.customerName,
            customerPhone: customer?.phone ?? "",
            customerEmail: customer?.email ?? "",
            customerAddress: customer?.address ?? "",
            jobAddress: job.address,
            scheduledDate: job.scheduledAt?.dateOnlyString,
            scheduledStartTime: job.scheduledAt?.nativeAppointmentTime,
            businessName: settings.businessName,
            appointmentConfirmationTemplate: settings.appointmentConfirmTemplate,
            onMyWayTemplate: settings.onMyWayTemplate
        )
        if case let .draft(value) = NativeAppointmentMessaging.draft(kind: .confirmation, input: input) {
            draft = value
            _bodyText = State(initialValue: value.body)
        } else {
            draft = nil
            _bodyText = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    Form {
                        Section("Recipient") {
                            LabeledContent(draft.channel == .sms ? "Text" : "Email", value: draft.recipient)
                        }
                        Section("Review message") {
                            TextEditor(text: $bodyText)
                                .frame(minHeight: 180)
                                .accessibilityLabel("Appointment confirmation message")
                        }
                        Section {
                            Button {
                                if NativeMessageComposer.canPresent(draft.channel) {
                                    showingComposer = true
                                    store.recordAppointmentComposerOpened(onMyWay: false)
                                } else {
                                    showingUnavailable = true
                                }
                            } label: {
                                Label(
                                    draft.channel == .sms ? "Continue to Messages" : "Continue to Mail",
                                    systemImage: draft.channel == .sms ? "message" : "envelope"
                                ).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } footer: {
                            Text("Nothing is sent until you review it again and tap Send in the system composer.")
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No contact info", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text("Add a phone number or email address for this customer before sending a confirmation.")
                    }
                }
            }
            .navigationTitle("Appointment confirmation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showingComposer) {
                if let draft {
                    NativeMessageComposer(
                        draft: .init(channel: draft.channel, recipient: draft.recipient, subject: draft.subject, body: bodyText),
                        onFinish: { outcome in
                            showingComposer = false
                            if outcome == .sent { dismiss() }
                        }
                    ).ignoresSafeArea()
                }
            }
            .alert("Composer unavailable", isPresented: $showingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(draft?.channel == .sms ? "Messages is not available on this device." : "Set up a Mail account on this device and try again.")
            }
        }
    }
}

private extension Date {
    var nativeAppointmentTime: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: self)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
