import SwiftUI
import UIKit

/// Compact app-wide status for offline, pending, or failed synchronization.
/// Healthy idle state stays out of the way; full details live in Settings.
struct NativeSyncBanner: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if isVisible {
            HStack(spacing: 9) {
                if store.syncStatus.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(accentColor)
                }
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !store.syncStatus.isSyncing && !isOffline {
                    Button("Sync") { store.syncNow() }
                        .font(.subheadline.weight(.semibold))
                        .tradeReadyProminentButtonStyle()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(accentColor.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }

    private var isVisible: Bool {
        store.syncStatus.isSyncing
            || isOffline
            || store.syncStatus.pendingCount > 0
            || store.syncStatus.diagnosticCode != nil
    }

    private var isOffline: Bool {
        if case .offline? = store.syncStatus.lastOutcome { return true }
        return false
    }

    private var message: String {
        if store.syncStatus.isSyncing { return "Syncing changes…" }
        if isOffline { return "You're offline — changes are safe on this device" }
        if store.syncStatus.diagnosticCode != nil { return "Sync needs attention" }
        let count = store.syncStatus.pendingCount
        return "\(count) change\(count == 1 ? "" : "s") waiting to sync"
    }

    private var symbol: String {
        if isOffline { return "icloud.slash.fill" }
        if store.syncStatus.diagnosticCode != nil { return "exclamationmark.triangle.fill" }
        return "icloud.and.arrow.up.fill"
    }

    private var accentColor: Color {
        isOffline || store.syncStatus.diagnosticCode != nil ? .orange : .tradeReady
    }
}

/// Short-lived, app-wide reversal for the latest supported mutation. AppStore
/// re-checks current canonical state before restoring anything.
struct NativeUndoBanner: View {
    @EnvironmentObject private var store: AppStore

    @ViewBuilder
    var body: some View {
        if let deletion = store.pendingRecordDeleteUndo {
            undoRow(
                symbol: deletionSymbol(deletion.kind),
                message: deletion.bannerMessage,
                undo: { store.undoRecordDeletion() },
                dismiss: { store.dismissRecordDeleteUndo() },
                dismissLabel: "Dismiss deletion undo"
            )
        } else if let merge = store.pendingCustomerMergeUndo {
            undoRow(
                symbol: "person.2.fill",
                message: "Merged \(merge.loserName) into \(merge.winnerName)",
                undo: { store.undoCustomerMerge() },
                dismiss: { store.dismissCustomerMergeUndo() },
                dismissLabel: "Dismiss merge undo"
            )
        }
    }

    private func deletionSymbol(_ kind: NativeRecordDeletionKind) -> String {
        switch kind {
        case .job: "hammer.fill"
        case .invoice: "doc.text.fill"
        case .customer: "person.fill"
        }
    }

    private func undoRow(
        symbol: String,
        message: String,
        undo: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        dismissLabel: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.tradeReady)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.bold))
                .tradeReadyProminentButtonStyle()
                .controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var color: Color = .tradeReady
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold)).foregroundStyle(color)
                        .frame(width: badgeSize, height: badgeSize).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            Text(value).font(.system(.title2, design: .rounded, weight: .bold)).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.72)
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary) }
        .shadow(color: .black.opacity(0.045), radius: 8, y: 3)
    }
}

struct StatusBadge: View {
    let status: JobStatus
    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

struct EmptyContent: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

extension View {
    func tradeReadyListStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .listStyle(.insetGrouped)
    }
}

struct ContactButtons: View {
    let phone: String
    let email: String
    @Environment(\.openURL) private var openURL
    @State private var composerDraft: NativeAppointmentMessageDraft?
    @State private var unavailableTarget: NativeCustomerContactTarget?

    private var targets: [NativeCustomerContactTarget] {
        NativeCustomerContactActions.targets(phone: phone, email: email)
    }

    var body: some View {
        HStack {
            ForEach(targets, id: \.action) { target in
                Button {
                    perform(target)
                } label: {
                    Label(target.title, systemImage: target.symbol)
                }
                .buttonStyle(.bordered)
            }
        }
        .labelStyle(.iconOnly)
        .sheet(isPresented: Binding(
            get: { composerDraft != nil },
            set: { if !$0 { composerDraft = nil } }
        )) {
            if let composerDraft {
                NativeMessageComposer(
                    draft: composerDraft,
                    onFinish: { _ in self.composerDraft = nil }
                )
                .ignoresSafeArea()
            }
        }
        .alert(item: Binding(
            get: { unavailableTarget },
            set: { if $0 == nil { unavailableTarget = nil } }
        )) { item in
            Alert(
                title: Text("\(item.title) unavailable"),
                message: Text(item.unavailableMessage),
                primaryButton: .default(Text("Copy \(item.copyLabel)")) {
                    UIPasteboard.general.string = item.recipient
                    unavailableTarget = nil
                },
                secondaryButton: .cancel { unavailableTarget = nil }
            )
        }
    }

    private func perform(_ target: NativeCustomerContactTarget) {
        switch target.action {
        case .call:
            openExternally(target)
        case .text, .email:
            let channel: NativeAppointmentMessageChannel = target.action == .text ? .sms : .email
            if NativeMessageComposer.canPresent(channel) {
                composerDraft = .init(
                    channel: channel,
                    recipient: target.recipient,
                    subject: nil,
                    body: ""
                )
            } else {
                openExternally(target)
            }
        }
    }

    private func openExternally(_ target: NativeCustomerContactTarget) {
        guard let url = target.externalURL else {
            unavailableTarget = target
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
            DispatchQueue.main.async { unavailableTarget = target }
        }
    }
}

private extension NativeCustomerContactTarget {
    var title: String {
        switch action {
        case .call: "Call"
        case .text: "Text"
        case .email: "Email"
        }
    }

    var symbol: String {
        switch action {
        case .call: "phone.fill"
        case .text: "message.fill"
        case .email: "envelope.fill"
        }
    }

    var copyLabel: String { action == .email ? "email" : "number" }

    var unavailableMessage: String {
        switch action {
        case .call: "Calling is not available on this device. You can copy the number instead."
        case .text: "Messages is not available on this device. You can copy the number instead."
        case .email: "Mail is not available on this device. You can copy the email address instead."
        }
    }
}

struct CurrencyField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A form field that keeps its label visible above the input, so a filled-in
/// value never leaves the user guessing what the box is for. Use for free-text
/// or multiline fields where an inline trailing value would be cramped.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.vertical, 3)
    }
}

struct DismissableFormToolbar: ToolbarContent {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let save: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .principal) { Text(title).font(.headline) }
        ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
    }
}
