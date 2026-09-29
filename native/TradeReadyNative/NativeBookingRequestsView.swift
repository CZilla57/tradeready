import SwiftUI
import MessageUI

/// Phase 8 task 8.11 booking/portal request attention UI (requirements B3, B4, P3).
///
/// Thin view over the 8.02 attention selector (`bookingAttentionRows`) and
/// the 8.08/8.07 response entry points (`declineBookingRequest`,
/// `acceptBookingReschedule` (Phase 12, P12-015),
/// `stampBookingRequestHandled`). No business policy lives here: every
/// mutation goes through the typed store entry points with fresh operation
/// identity; the view only maps row kinds to actions and surfaces the
/// authoritative state returned by the server.
struct NativeBookingRequestsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 56
    @State private var rows: [NativeBookingAttention.Row] = []
    @State private var busyRequestIDs: Set<String> = []
    @State private var showingJobID: IdentifiableString?
    @State private var showingComposer: NativeMessageComposerView?
    @State private var didLoad = false
    /// Phase 12 (12.00b.2-J, P12-015): the outcome of "Resolve" (and, since
    /// 12.00b.2-L, of "Decline").
    @State private var notice: AppStore.BookingRescheduleNotice?

    var body: some View {
        Group {
            if !didLoad {
                ProgressView("Loading requests…")
                    .accessibilityLabel("Loading booking requests")
                    .onAppear { refreshRows() }
            } else if rows.isEmpty {
                emptyState
            } else {
                requestList
            }
        }
        .navigationTitle("Booking Requests")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .refreshable { refreshRows() }
        .sheet(item: $showingJobID) { jobID in
            JobDetailView(jobID: jobID.value)
        }
        .sheet(item: $showingComposer) { composer in
            composer.view
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: emptyIconSize))
                .foregroundStyle(Color.tradeSuccessText)
            Text("All caught up")
                .font(.title2.bold())
            Text("No booking requests need your attention right now.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var requestList: some View {
        List {
            ForEach(rows, id: \.request.id) { row in
                RequestRowView(
                    row: row,
                    isBusy: busyRequestIDs.contains(row.request.id),
                    onViewJob: { jobID in showingJobID = IdentifiableString(value: jobID) },
                    onContact: { target in showingComposer = target },
                    onResolveReschedule: { await resolveReschedule(row) },
                    onDecline: { await decline(row) },
                    onMarkHandled: { await markHandled(row) }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .nativeContentColumn(.list)
        .listStyle(.plain)
    }

    private func refreshRows() {
        rows = store.bookingAttentionRows()
        didLoad = true
    }

    // MARK: - Actions

    /// Phase 12 (12.00b.2-J, P12-015): the owner has moved the job; this
    /// confirms the booking for the job's current schedule through the same
    /// entry point as Today's "I've rescheduled it", and shows every outcome
    /// on this screen.
    private func resolveReschedule(_ row: NativeBookingAttention.Row) async {
        guard !busyRequestIDs.contains(row.request.id) else { return }
        busyRequestIDs.insert(row.request.id)
        defer { busyRequestIDs.remove(row.request.id) }

        let outcome = await store.acceptBookingReschedule(requestID: row.request.id)
        await MainActor.run {
            notice = outcome.ownerNotice(actionLabel: "Resolve")
            refreshRows()
        }
    }

    private func decline(_ row: NativeBookingAttention.Row) async {
        guard !busyRequestIDs.contains(row.request.id) else { return }
        busyRequestIDs.insert(row.request.id)
        defer { busyRequestIDs.remove(row.request.id) }

        let outcome = await store.declineBookingRequest(requestID: row.request.id)
        await MainActor.run {
            // Phase 12 (12.00b.2-L, P12-017): every outcome but a decline is
            // shown here, as on Today.
            notice = outcome.declineNotice(actionLabel: "Decline")
            switch outcome {
            case .applied:
                refreshRows()
            case .needsReview:
                refreshRows()
            case .awaitingAck, .unknownOutcome, .missing, .failed:
                break
            }
        }
    }

    private func markHandled(_ row: NativeBookingAttention.Row) async {
        guard !busyRequestIDs.contains(row.request.id) else { return }
        busyRequestIDs.insert(row.request.id)
        defer { busyRequestIDs.remove(row.request.id) }

        let outcome = store.stampBookingRequestHandled(requestID: row.request.id)
        await MainActor.run {
            switch outcome {
            case .handled:
                refreshRows()
            case .alreadyHandled, .missing, .failed:
                break
            }
        }
    }
}

// MARK: - String wrapper for Identifiable conformance

private struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}

// MARK: - Row View

private struct RequestRowView: View {
    let row: NativeBookingAttention.Row
    let isBusy: Bool
    let onViewJob: (String) -> Void
    let onContact: (NativeMessageComposerView) -> Void
    let onResolveReschedule: () async -> Void
    let onDecline: () async -> Void
    let onMarkHandled: () async -> Void

    private var request: Canonical.BookingRequest { row.request }
    private var kind: NativeBookingAttention.Kind { row.kind }
    private var customerName: String { request.name }
    private var details: String { request.details }
    private var slotDate: String? { request.slot?.date }
    private var slotStart: String? { request.slot?.start }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if let note = row.note, !note.isEmpty {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            actionsSection
        }
        .padding(.vertical, 4)
    }

    private var headerSection: some View {
        // 11.10b A16: at AX sizes the kind sits above the name instead of in a
        // 64pt column that squeezes the name and details.
        NativeAccessibilityAdaptiveRow(alignment: .top, spacing: 12) {
            kindIndicator
            VStack(alignment: .leading, spacing: 4) {
                Text(customerName.isEmpty ? "Unknown customer" : customerName)
                    .font(.headline)
                if !details.isEmpty {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let date = slotDate, let start = slotStart {
                    Text("Requested: \(date) at \(start)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else if let date = slotDate {
                    Text("Requested: \(date)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var kindIndicator: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // One line, full width: the label is never squeezed into 56pt.
            HStack(spacing: 6) {
                Image(systemName: kindIcon)
                    .foregroundStyle(kindColor)
                Text(kindLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(kindColor)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: kindIcon)
                    .font(.title2)
                    .foregroundStyle(kindColor)
                Text(kindLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(kindColor)
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
            }
            .frame(width: 64)
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
            switch kind {
            case .rescheduleRequested:
                if let jobID = row.jobID {
                    Button { onViewJob(jobID) } label: {
                        Label("View Job", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                contactButtons
                Button("Resolve") { Task { await onResolveReschedule() } }
                    .tradeReadyProminentButtonStyle()
                    .disabled(isBusy)
                Button(role: .destructive) { Task { await onDecline() } } label: {
                    Text("Decline").nativeDestructiveText()
                }
                .buttonStyle(.bordered)
                .tint(Color.tradeDangerText)
                .disabled(isBusy)

            case .portalChange:
                if let jobID = row.jobID {
                    Button { onViewJob(jobID) } label: {
                        Label("View Job", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                contactButtons
                Button("Done") { Task { await onMarkHandled() } }
                    .tradeReadyProminentButtonStyle()
                    .disabled(isBusy)

            case .cancelled:
                if let jobID = row.jobID {
                    Button { onViewJob(jobID) } label: {
                        Label("View Job", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                contactButtons
                Text("Booking was cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .missingJob:
                Text("Linked job not found")
                    .font(.caption)
                    .foregroundStyle(Color.tradeDangerText)
                Button("Reconcile") { /* TODO: reconciliation flow */ }
                    .buttonStyle(.bordered)
                    .disabled(true)

            case .unconvertedActive:
                Text("Needs conversion")
                    .font(.caption)
                    .foregroundStyle(Color.tradeWarningText)
            }
            Spacer()
        }
    }

    private var kindIcon: String {
        switch kind {
        case .rescheduleRequested: "arrow.clockwise.circle"
        case .portalChange: "person.crop.circle.badge.exclamationmark"
        case .cancelled: "xmark.circle"
        case .missingJob: "questionmark.circle"
        case .unconvertedActive: "exclamationmark.triangle"
        }
    }

    private var kindColor: Color {
        switch kind {
        case .rescheduleRequested: Color.tradeWarningText
        case .portalChange: Color.tradeInfoText
        case .cancelled: .tradeDangerText
        case .missingJob: Color.tradePurpleText
        case .unconvertedActive: Color.tradeWarningText
        }
    }

    private var kindLabel: String {
        switch kind {
        case .rescheduleRequested: "Reschedule"
        case .portalChange: "Portal"
        case .cancelled: "Cancelled"
        case .missingJob: "Missing"
        case .unconvertedActive: "Unconverted"
        }
    }

    private var contactButtons: some View {
        Group {
            let targets = NativeCustomerContactActions.targets(
                phone: request.phone,
                email: request.email
            )
            ForEach(targets) { target in
                Button {
                    if let url = target.externalURL,
                       let composer = NativeMessageComposerView(target: target, url: url) {
                        onContact(composer)
                    }
                } label: {
                    Image(systemName: contactIcon(target.action))
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(NativeAccessibilityAudit.Label.contact(contactVerb(target.action), name: request.name))
                .disabled(isBusy)
            }
        }
    }

    private func contactVerb(_ action: NativeCustomerContactAction) -> NativeAccessibilityAudit.ContactVerb {
        switch action {
        case .call: .call
        case .text: .text
        case .email: .email
        }
    }

    private func contactIcon(_ action: NativeCustomerContactAction) -> String {
        switch action {
        case .call: "phone"
        case .text: "message"
        case .email: "envelope"
        }
    }
}

// MARK: - Message Composer Wrapper

private struct NativeMessageComposerView: Identifiable {
    let id: String
    let view: AnyView

    init?(target: NativeCustomerContactTarget, url: URL) {
        guard let scheme = url.scheme else { return nil }
        switch scheme {
        case "sms":
            id = "sms:\(target.recipient)"
            view = AnyView(
                NativeSMSComposer(recipient: target.recipient)
                    .ignoresSafeArea()
            )
        case "mailto":
            id = "mailto:\(target.recipient)"
            view = AnyView(
                NativeMailComposer(recipient: target.recipient)
                    .ignoresSafeArea()
            )
        default:
            return nil
        }
    }
}

private struct NativeSMSComposer: UIViewControllerRepresentable {
    let recipient: String
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
        }
    }
}

private struct NativeMailComposer: UIViewControllerRepresentable {
    let recipient: String
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([recipient])
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
        }
    }
}

// MARK: - TodayView Integration Helper

/// Computes the booking attention summary for the Today screen.
/// Shows only the count of actionable rows (reschedule, portal change, cancelled, missing).
@MainActor
func bookingAttentionSummary(store: AppStore) -> (count: Int, hasActionable: Bool) {
    let rows = store.bookingAttentionRows()
    let actionable = rows.filter { row in
        switch row.kind {
        case .rescheduleRequested, .portalChange, .cancelled, .missingJob:
            return true
        case .unconvertedActive:
            return false
        }
    }
    return (actionable.count, !actionable.isEmpty)
}