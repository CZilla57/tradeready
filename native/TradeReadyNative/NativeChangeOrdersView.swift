import SwiftUI

/// Job-detail change-orders block, ported from
/// `components/ChangeOrdersSection.tsx`: derived-status rows plus the add,
/// edit, on-site decision, cancel, and delete actions.
///
/// The section keeps no state of record — every action re-resolves the
/// canonical job and order inside `AppStore`, so a decision or cancellation
/// that lands while a sheet is open fails closed instead of being overwritten.
struct NativeChangeOrdersSection: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String

    @State private var editorDraft: NativeChangeOrderDraft?
    @State private var decisionPrompt: ChangeOrderDecisionPrompt?
    @State private var decisionNote = ""
    @State private var actionTarget: NativeChangeOrderRow?
    @State private var approvalReview: NativeChangeOrderReviewDraft?
    @State private var confirmation: ChangeOrderConfirmation?
    /// Refusals and failed writes are explained in place — one dialog plus one
    /// alert is the most this section presents at a time.
    @State private var errorMessage: String?

    var body: some View {
        if let state = store.changeOrderSectionState(jobID: jobID), state.isVisible {
            Section("Change orders") {
                ForEach(state.rows) { row in
                    rowView(row)
                }
                if state.canAdd {
                    Button {
                        openEditor(changeOrderID: nil)
                    } label: {
                        Label("Add change order", systemImage: "plus.circle")
                    }
                }
                if let errorMessage {
                    errorRow(errorMessage)
                }
            }
            .confirmationDialog(
                actionTarget?.title ?? "",
                isPresented: actionDialogIsPresented,
                titleVisibility: .visible,
                presenting: actionTarget
            ) { row in
                ForEach(Array(actions(for: row).enumerated()), id: \.offset) { _, action in
                    if let role = action.role {
                        Button(action.title, role: role, action: action.perform)
                    } else {
                        Button(action.title, action: action.perform)
                    }
                }
                Button("Close", role: .cancel) {}
            } message: { row in
                Text(money(row.amount))
            }
            .alert(
                confirmation?.title ?? "",
                isPresented: confirmationIsPresented,
                presenting: confirmation
            ) { request in
                Button(request.confirmLabel, role: .destructive) { perform(request) }
                Button("Keep it", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .sheet(item: $editorDraft) { draft in
                NativeChangeOrderEditorView(draft: draft)
            }
            .sheet(item: $decisionPrompt) { prompt in
                ChangeOrderDecisionSheet(
                    prompt: prompt,
                    note: $decisionNote,
                    confirm: confirmDecision,
                    cancel: closeDecisionPrompt
                )
            }
            .sheet(item: $approvalReview) { draft in
                NativeChangeOrderReviewView(draft: draft)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
            Spacer(minLength: 4)
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss change-order message")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: NativeChangeOrderRow) -> some View {
        if row.isActionable {
            Button {
                actionTarget = row
            } label: {
                rowLabel(row, showsDisclosure: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows change-order actions")
        } else {
            rowLabel(row, showsDisclosure: false)
        }
    }

    private func rowLabel(_ row: NativeChangeOrderRow, showsDisclosure: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(money(row.amount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ChangeOrderStatusBadge(tone: row.badgeTone, label: row.statusLabel)
            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
    }

    /// Row actions in React Native's order, minus the approval-link send that
    /// this slice does not implement yet.
    private func actions(for row: NativeChangeOrderRow) -> [ChangeOrderRowAction] {
        var actions: [ChangeOrderRowAction] = []
        if row.isActionable {
            actions.append(.init(
                title: row.status == .pending ? "Send for approval" : "Re-send link",
                role: nil
            ) { openApprovalReview(for: row) })
            actions.append(.init(title: "Mark approved (on site)", role: nil) {
                beginDecision(for: row, decision: .approved)
            })
            actions.append(.init(title: "Mark declined", role: nil) {
                beginDecision(for: row, decision: .declined)
            })
            actions.append(.init(title: "Cancel change order", role: .destructive) {
                confirmation = .cancel(row.id)
            })
        }
        if row.canEdit {
            actions.append(.init(title: "Edit", role: nil) {
                openEditor(changeOrderID: row.id)
            })
        }
        if row.canDelete {
            actions.append(.init(title: "Delete", role: .destructive) {
                confirmation = .delete(row.id)
            })
        }
        return actions
    }

    // MARK: - Actions

    private func openApprovalReview(for row: NativeChangeOrderRow) {
        guard let draft = store.changeOrderApprovalDraft(jobID: jobID, changeOrderID: row.id) else {
            errorMessage = "This change is no longer pending. Refresh the job and review its current status."
            return
        }
        approvalReview = NativeChangeOrderReviewDraft(draft: draft, store: store)
    }

    /// Mount-time refusals (job not addable, order no longer pending) surface as
    /// an explanation instead of an editor that cannot save — the same recovery
    /// `AddChangeOrderScreen` performs by alerting and going back.
    private func openEditor(changeOrderID: String?) {
        switch store.changeOrderDraft(jobID: jobID, changeOrderID: changeOrderID) {
        case let .success(draft):
            editorDraft = draft
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func beginDecision(for row: NativeChangeOrderRow, decision: NativeChangeOrderManualDecision) {
        // The note starts blank for every newly opened target: a note typed for
        // one order must never pre-fill the next one.
        decisionNote = ""
        decisionPrompt = .init(orderID: row.id, orderTitle: row.title, decision: decision)
    }

    private func closeDecisionPrompt() {
        decisionPrompt = nil
        decisionNote = ""
    }

    private func confirmDecision() {
        guard let prompt = decisionPrompt else { return }
        let note = decisionNote
        // Both the target and the note are cleared on every close path, so a
        // note typed for one order can never leak into the next one.
        closeDecisionPrompt()
        let saved = store.recordManualChangeOrderDecision(
            jobID: jobID,
            changeOrderID: prompt.orderID,
            decision: prompt.decision,
            note: note
        )
        if !saved {
            errorMessage = store.migrationMessage ?? "The change order could not be updated."
        }
    }

    private func perform(_ request: ChangeOrderConfirmation) {
        let saved: Bool
        switch request.kind {
        case .cancel:
            saved = store.cancelChangeOrder(jobID: jobID, changeOrderID: request.orderID)
        case .delete:
            saved = store.deletePendingChangeOrder(jobID: jobID, changeOrderID: request.orderID)
        }
        if !saved {
            errorMessage = store.migrationMessage ?? "The change order could not be updated."
        }
    }

    // MARK: - Bindings

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.currency
    }

    private var actionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { actionTarget != nil },
            set: { presented in if !presented { actionTarget = nil } }
        )
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { presented in if !presented { confirmation = nil } }
        )
    }

}

/// Add/edit change-order sheet, ported from `AddChangeOrderScreen.tsx`. The
/// amount stays raw text so a bad entry gets an explanation; validation and the
/// save itself run against the job's current canonical record inside
/// `AppStore.commitChangeOrder`.
struct NativeChangeOrderEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: NativeChangeOrderDraft
    @State private var errorMessage: String?
    @State private var closesAfterAcknowledgement = false

    private var saveLabel: String {
        draft.isEditing ? "Save changes" : "Add change order"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What changed?", text: $draft.title, axis: .vertical)
                    TextField("Details (optional)", text: $draft.description, axis: .vertical)
                    TextField("Amount ($)", text: $draft.amountText)
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    Text("Use a negative amount for a descope credit. The customer approves this change before the extra work starts.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle(draft.isEditing ? "Edit Change Order" : "Add Change Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel, action: save).fontWeight(.semibold)
                }
            }
            .onChange(of: draft) { _, _ in errorMessage = nil }
            .alert("Not saved", isPresented: acknowledgementIsPresented) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        switch store.commitChangeOrder(draft) {
        case .created, .updated:
            dismiss()
        case let .refused(error):
            errorMessage = error.localizedDescription
            // A job that can no longer take a change order, or an order that
            // was decided meanwhile, cannot be saved by retrying: close after
            // the owner acknowledges, like the oracle's navigation.goBack().
            closesAfterAcknowledgement = error.closesEditorOnFailure
        case let .failed(message):
            errorMessage = message
            closesAfterAcknowledgement = false
        }
    }

    /// Only terminal failures interrupt with an alert; correctable ones stay
    /// inline so the owner can fix the form in place.
    private var acknowledgementIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil && closesAfterAcknowledgement },
            set: { presented in
                if !presented, closesAfterAcknowledgement {
                    errorMessage = nil
                    dismiss()
                }
            }
        )
    }
}

// MARK: - Sheet and dialog state

private struct ChangeOrderDecisionPrompt: Identifiable, Equatable {
    let orderID: String
    let orderTitle: String
    let decision: NativeChangeOrderManualDecision

    var id: String { "\(orderID)-\(decision.rawValue)" }
}

private struct ChangeOrderConfirmation: Identifiable, Equatable {
    enum Kind: Equatable { case cancel, delete }

    let orderID: String
    let kind: Kind

    var id: String { "\(kind)-\(orderID)" }

    var title: String {
        kind == .cancel ? "Cancel this change order?" : "Delete this change order?"
    }

    var message: String {
        kind == .cancel
            ? "It stays in the list as cancelled and won't be billed."
            : "It was never sent, so no record is needed."
    }

    var confirmLabel: String { kind == .cancel ? "Cancel change order" : "Delete" }

    static func cancel(_ orderID: String) -> Self { .init(orderID: orderID, kind: .cancel) }
    static func delete(_ orderID: String) -> Self { .init(orderID: orderID, kind: .delete) }
}

private struct ChangeOrderRowAction {
    let title: String
    let role: ButtonRole?
    let perform: () -> Void
}

@MainActor
struct NativeChangeOrderReviewDraft: Identifiable {
    let approval: NativeChangeOrderApprovalDraft
    let customerName: String
    let customerEmail: String
    let customerPhone: String
    let businessName: String
    let businessContactName: String
    let businessPhone: String

    init(draft: NativeChangeOrderApprovalDraft, store: AppStore) {
        self.approval = draft
        let job = store.jobs.first { $0.id == draft.jobID }
        let customer = NativeCustomerIdentity.resolve(
            customers: store.customers,
            customerID: job?.customerId,
            customerName: job?.customerName
        )
        customerName = customer?.name ?? job?.customerName ?? draft.snapshot.customerName
        customerEmail = customer?.email ?? ""
        customerPhone = customer?.phone ?? ""
        businessName = store.settings.businessName
        businessContactName = store.settings.contactName
        businessPhone = store.settings.phone
    }

    var id: String { "\(approval.jobID)-\(approval.changeOrderID)" }
}

/// On-site decision note sheet. Mirrors the oracle's in-component modal: the
/// note is optional. `confirmDecision` clears the target synchronously before
/// committing, so a fast double-tap on Confirm is already a no-op — the oracle
/// needed a busy flag only because its mutation was asynchronous.
private struct ChangeOrderDecisionSheet: View {
    let prompt: ChangeOrderDecisionPrompt
    @Binding var note: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                } footer: {
                    Text("Record how the customer decided — e.g. \u{201C}verbal OK on site\u{201D}.")
                }
            }
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle(prompt.decision == .approved ? "Mark approved" : "Mark declined")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm", action: confirm)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct NativeChangeOrderDeliveryNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum NativeChangeOrderMessageDrafting {
    static func prepare(_ draft: NativeChangeOrderReviewDraft, channel: NativeEstimateMessageChannel, link: URL? = nil) -> NativeEstimatePreparedMessage {
        let amount = NSDecimalNumber(decimal: draft.approval.snapshot.total).doubleValue.currency
        let title = draft.approval.snapshot.jobTitle
        let customer = draft.customerName
        let business = draft.businessName.isEmpty ? "Your tradesperson" : draft.businessName
        if channel == .text {
            let suffix = link.map { " View & approve: \($0.absoluteString)" } ?? ""
            return .init(subject: "", body: "Hi \(customer), \(business) here. Change order for \"\(title)\": \(amount).\(suffix)")
        }
        var lines = [
            "Hi \(customer),",
            "",
            "Please review this change order for \(title):",
            "",
            "  \(draft.approval.snapshot.lineItems.first?.label ?? "Change")  \(amount)",
            "",
            "Please review and approve this change before the extra work starts."
        ]
        if let link { lines += ["", "View and approve your change order here:", link.absoluteString] }
        lines += ["", "Best regards,", draft.businessContactName, business, draft.businessPhone]
        return .init(subject: "Change order for \(title) – \(business)", body: lines.joined(separator: "\n"))
    }
}

struct NativeChangeOrderReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let draft: NativeChangeOrderReviewDraft

    @State private var channel: NativeEstimateMessageChannel
    @State private var emailSubject: String
    @State private var emailBody: String
    @State private var textBody: String
    @State private var showingComposer = false
    @State private var isCreatingLink = false
    @State private var linkError: String?
    @State private var notice: NativeChangeOrderDeliveryNotice?

    init(draft: NativeChangeOrderReviewDraft) {
        self.draft = draft
        let initial: NativeEstimateMessageChannel = draft.customerEmail.isEmpty && !draft.customerPhone.isEmpty ? .text : .email
        let email = NativeChangeOrderMessageDrafting.prepare(draft, channel: .email)
        let text = NativeChangeOrderMessageDrafting.prepare(draft, channel: .text)
        _channel = State(initialValue: initial)
        _emailSubject = State(initialValue: email.subject)
        _emailBody = State(initialValue: email.body)
        _textBody = State(initialValue: text.body)
    }

    private var recipient: String { channel == .email ? draft.customerEmail : draft.customerPhone }
    private var bodyText: Binding<String> {
        Binding(get: { channel == .email ? emailBody : textBody }, set: { value in
            if channel == .email { emailBody = value } else { textBody = value }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Change order") {
                    Text(draft.approval.snapshot.jobTitle).font(.headline)
                    LabeledContent("Customer", value: draft.customerName)
                    LabeledContent("Amount", value: NSDecimalNumber(decimal: draft.approval.snapshot.total).doubleValue.currency)
                }
                Section {
                    Picker("Channel", selection: $channel) {
                        ForEach(NativeEstimateMessageChannel.allCases) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    if recipient.isEmpty {
                        Text("Add a customer \(channel == .email ? "email address" : "phone number") before continuing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Recipient", value: recipient)
                    }
                    if channel == .email { TextField("Subject", text: $emailSubject) }
                    TextEditor(text: bodyText).frame(minHeight: 180)
                        .accessibilityLabel("Change-order message")
                    Button {
                        mintAndOpenComposer()
                    } label: {
                        if isCreatingLink { Label("Creating approval link…", systemImage: "hourglass") }
                        else { Label(channel == .email ? "Continue to Mail" : "Continue to Messages", systemImage: channel == .email ? "envelope" : "message") }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .disabled(recipient.isEmpty || isCreatingLink)
                } header: {
                    Text("Delivery")
                } footer: {
                    Text("The approval link is created before the system composer opens. Nothing is sent until you tap Send there.")
                }
            }
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle("Send for approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showingComposer) {
                NativeMessageComposer(
                    draft: .init(channel: channel == .email ? .email : .sms, recipient: recipient, subject: channel == .email ? emailSubject : nil, body: channel == .email ? emailBody : textBody),
                    onFinish: handleComposerOutcome
                ).ignoresSafeArea()
            }
            .alert("Couldn’t create approval link", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("OK", role: .cancel) { linkError = nil }
            } message: { Text(linkError ?? "Please try again.") }
            .alert(item: $notice) { value in
                Alert(title: Text(value.title), message: Text(value.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func mintAndOpenComposer() {
        isCreatingLink = true
        Task {
            let result = await store.createChangeOrderApprovalLink(for: draft.approval)
            isCreatingLink = false
            switch result {
            case .success(let link):
                // Keep owner edits intact; minting only appends the fresh URL.
                if channel == .email {
                    if !emailBody.contains(link.url.absoluteString) {
                        emailBody += "\n\nView and approve your change order here:\n\(link.url.absoluteString)"
                    }
                } else if !textBody.contains(link.url.absoluteString) {
                    textBody += " View & approve: \(link.url.absoluteString)"
                }
                if NativeMessageComposer.canPresent(channel == .email ? .email : .sms) {
                    showingComposer = true
                } else {
                    notice = .init(title: "Composer unavailable", message: channel == .email ? "Set up a Mail account on this device and try again." : "Messages is not available on this device.")
                }
            case .failure(let error):
                linkError = error.localizedDescription
            }
        }
    }

    private func handleComposerOutcome(_ outcome: NativeMessageComposeOutcome) {
        showingComposer = false
        switch outcome {
        case .sent:
            dismiss()
        case .saved:
            notice = .init(title: "Draft saved in Mail", message: "The change order was not marked sent. You can reopen Mail when you’re ready.")
        case .failed:
            notice = .init(title: "Message not sent", message: "The system composer could not send the change order. Your draft is still here so you can try again.")
        case .cancelled:
            break
        }
    }
}

private struct ChangeOrderStatusBadge: View {
    let tone: NativeChangeOrderBadgeTone
    let label: String

    private var color: Color {
        switch tone {
        case .muted: .secondary
        case .accent: .tradeReady
        case .success: .green
        case .danger: .red
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Change order \(label)")
    }
}
