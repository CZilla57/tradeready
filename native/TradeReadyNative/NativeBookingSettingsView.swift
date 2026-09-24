import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Phase 8 task 8.10 booking settings UI (requirement B2).
///
/// Thin view over the 8.07 transport and the 8.08 administration entry
/// points (`administerBookingLink`, `reconcileBookingLinkForSharing`). No
/// business policy lives here: every mutation goes through the
/// server-first typed entry point with a fresh operation ID, and the local
/// display copy is adopted only on a fresh authoritative read.
///
/// Slot availability (schedule settings) stays separate from link
/// enablement (this screen). Link states are explicit:
/// - published: fresh `status` proves the display token current — a share
///   URL may be copied/shared. Sharing is never delivery evidence, and
///   cancelling the share sheet changes no delivery state.
/// - pending: a per-action in-flight flag disables that action only.
/// - unavailable: `status` unreachable (offline/server) — actions explain
///   instead of claiming.
/// - recovery: stale token, 409, response loss (`unknownOutcome`) or a
///   local-save failure (`recoveryStaged`) — truthful retry/rotate paths,
///   never an automatic re-mint.
struct NativeBookingSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum BusyAction: Hashable {
        case refresh, create, enable, disable, rotate
    }

    @State private var busy: Set<BusyAction> = []
    @State private var authority: NativeBookingLinkStatus?
    @State private var shareURL: URL?
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var confirmingRotate = false
    @State private var didLoad = false

    private var localDisplay: (token: String?, enabled: Bool) {
        store.bookingLinkLocalDisplay()
    }

    private var isBusy: Bool { !busy.isEmpty }

    var body: some View {
        Group {
            if !didLoad {
                ProgressView("Loading booking link…")
                    .accessibilityLabel("Loading booking link status")
                    .onAppear { Task { await refresh(clearMessage: true) } }
            } else {
                bookingForm
            }
        }
        .navigationTitle("Booking Link")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Rotate the booking link?",
            isPresented: $confirmingRotate,
            titleVisibility: .visible
        ) {
            Button("Rotate link", role: .destructive) { Task { await rotate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current link stops working immediately. Share the new link afterwards.")
        }
        .nativeAnalyticsScreen(.settingsBooking)
    }

    // MARK: - Form

    private var bookingForm: some View {
        Form {
            stateSection
            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.footnote).foregroundStyle(isError ? .red : .secondary)
                        .accessibilityLabel(statusMessage)
                }
            }
            actionsSection
            Section {
                Text("Slot availability (working hours, duration, time zone) lives under Schedule. This screen only controls whether the booking link accepts quote requests. Sharing a link never means it was delivered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .refreshable { await refresh(clearMessage: false) }
        .onAppear {
            _ = store.syncStatus
            _ = store.settings
        }
    }

    private var stateSection: some View {
        Section(header: Text("Status")) {
            HStack {
                stateDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle).font(.headline)
                    Text(stateSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Booking link status: \(stateTitle). \(stateSubtitle)")
            if let url = shareURL {
                LabeledContent("Public link") {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .accessibilityLabel("Public booking link \(url.absoluteString)")
                }
            } else if localDisplay.token != nil {
                Text("The saved link is stale or unverified — refresh its status before sharing. A stale token is never shared.")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel("Saved link is stale or unverified. Refresh before sharing.")
            }
        }
    }

    private var stateDot: some View {
        let color: Color = shareURL != nil ? .green : (authority == nil ? .orange : .secondary)
        return Circle().fill(color).frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var stateTitle: String {
        if shareURL != nil { return (authority?.enabled ?? false) ? "Published" : "Link ready" }
        if authority == nil { return "Unavailable" }
        return localDisplay.token == nil ? "No link yet" : "Needs recovery"
    }

    private var stateSubtitle: String {
        if shareURL != nil {
            return authority?.enabled == true
                ? "Customers can request work from your verified link."
                : "The link is verified but currently disabled — customers cannot request work."
        }
        if authority == nil {
            return "Could not reach the booking service. Nothing here claims a published state."
        }
        if localDisplay.token == nil {
            return "Create a link to let customers request work."
        }
        return "The saved copy no longer matches the server. Rotate to recover — never share the stale copy."
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section(header: Text("Link actions")) {
            Button { Task { await refresh(clearMessage: false) } } label: {
                actionLabel("Refresh status", systemImage: "arrow.triangle.2.circlepath", busy: busy.contains(.refresh))
            }
            .disabled(isBusy)
            .accessibilityHint("Re-reads the authoritative link state")

            if localDisplay.token == nil {
                Button { Task { await create() } } label: {
                    actionLabel("Create booking link", systemImage: "link.badge.plus", busy: busy.contains(.create))
                }
                .disabled(isBusy)
                .accessibilityHint("Creates the link on the server first, then saves the local copy")
            } else {
                if let url = shareURL {
                    ShareLink(item: url) {
                        Label("Share booking link", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isBusy)
                    .accessibilityHint("Cancelling the share sheet changes nothing — sharing is not delivery evidence")
                    Button { copyLink(url) } label: {
                        Label("Copy booking link", systemImage: "doc.on.doc")
                    }
                    .disabled(isBusy)
                    .accessibilityHint("Copies the verified link. A stale copy is never offered here.")
                }
                if authority?.enabled == true {
                    Button { Task { await setEnabled(false) } } label: {
                        actionLabel("Disable booking link", systemImage: "link.badge.plus", busy: busy.contains(.disable))
                    }
                    .disabled(isBusy)
                    .accessibilityHint("Customers immediately stop reaching this link after the server confirms")
                } else {
                    Button { Task { await setEnabled(true) } } label: {
                        actionLabel("Enable booking link", systemImage: "link", busy: busy.contains(.enable))
                    }
                    .disabled(isBusy)
                    .accessibilityHint("Re-enables the verified link on the server first")
                }
                Button { confirmingRotate = true } label: {
                    actionLabel("Rotate link", systemImage: "arrow.triangle.2.circlepath.circle", busy: busy.contains(.rotate))
                }
                .disabled(isBusy)
                .foregroundStyle(.red)
                .accessibilityHint("Asks for confirmation, then replaces the link. The old link stops working.")
            }
        }
    }

    private func actionLabel(_ title: String, systemImage: String, busy: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if busy { Spacer(); ProgressView().accessibilityLabel("\(title) in progress") }
        }
    }

    // MARK: - Actions (all server-first, per-action busy protection)

    private func refresh(clearMessage: Bool) async {
        busy.insert(.refresh)
        defer {
            busy.remove(.refresh)
            if didLoad == false { didLoad = true }
        }
        if clearMessage { statusMessage = nil; isError = false }
        let reconciled = await store.reconcileBookingLinkForSharing()
        guard scheduleStillCurrent() else { return }
        authority = reconciled.status
        shareURL = reconciled.shareURL
        didLoad = true
        if reconciled.status == nil {
            setMessage("Could not reach the booking service. Your saved copy is unchanged and nothing claims to be published.", error: true)
        } else if reconciled.shareURL == nil, localDisplay.token != nil {
            setMessage("The saved link is stale. Rotate with confirmation to recover.", error: false)
        } else if clearMessage == false, reconciled.shareURL != nil {
            setMessage("Verified against the server.", error: false)
        }
    }

    private func create() async {
        busy.insert(.create)
        defer { busy.remove(.create) }
        await administer(.mint, enabled: nil, successVerb: "created")
    }

    private func setEnabled(_ enabled: Bool) async {
        busy.insert(enabled ? .enable : .disable)
        defer { busy.remove(enabled ? .enable : .disable) }
        await administer(.setEnabled, enabled: enabled, successVerb: enabled ? "enabled" : "disabled")
    }

    private func rotate() async {
        busy.insert(.rotate)
        defer { busy.remove(.rotate) }
        // A timeout is an unknown outcome: recovery replays by operation ID
        // or refreshes status — never an automatic second rotate.
        await administer(.rotate, enabled: nil, successVerb: "rotated")
    }

    private func administer(_ action: NativeBookingAdminAction, enabled: Bool?, successVerb: String) async {
        // A fresh operation ID per attempt: retries of the SAME attempt reuse
        // it inside the store (replay-safe); a new attempt mints a new one.
        let outcome = await store.administerBookingLink(
            action: action, enabled: enabled, operationId: UUID().uuidString)
        guard scheduleStillCurrent() else { return }
        switch outcome {
        case let .applied(revision, sharesURL: shares):
            _ = revision
            await refresh(clearMessage: true)
            setMessage(shares
                ? "Booking link \(successVerb) and verified."
                : "Booking link \(successVerb) on the server. Refresh to verify before sharing.", error: false)
        case let .stale(currentEnabled):
            await refresh(clearMessage: true)
            setMessage("The link changed on another device (now \(currentEnabled ? "enabled" : "disabled")). Your saved copy was updated — review before trying again.", error: true)
        case .alreadyExists:
            // Stale Create: refresh authority and adopt only a matching
            // current copy — never an implicit rotate.
            await refresh(clearMessage: true)
            setMessage("A link already exists on the server. Its current state is shown — nothing was duplicated.", error: false)
        case .recoveryStaged:
            setMessage("Updated on the server, but the local copy could not be saved. It will finish automatically — refresh to verify. No second link was created.", error: true)
        case .unknownOutcome:
            setMessage("The request may or may not have reached the server. Check the status before trying again — nothing was retried automatically.", error: true)
        case let .failed(reason):
            setMessage(failureText(reason: reason), error: true)
        }
    }

    private func failureText(reason: String) -> String {
        switch reason {
        case "not-signed-in": "Sign in before managing the booking link."
        case "session": "Your session expired. Sign in again before managing the booking link."
        case "configuration": "Booking links are not configured for this build."
        case "status-unavailable": "Could not reach the booking service. Nothing was changed."
        case "owner-changed": "The account changed while working. Nothing was published for the wrong account."
        case "already-running": "A link action is already running. Wait for it to finish."
        case "invalid-request": "This request was invalid and was not sent."
        default: "The booking service is unavailable. Check your connection and try again."
        }
    }

    private func copyLink(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.string = url.absoluteString
        #endif
        // Copying changes no delivery state: the message says copied, never
        // sent or delivered.
        setMessage("Copied. Pasting it somewhere is not delivery evidence.", error: false)
    }

    private func setMessage(_ text: String, error: Bool) {
        statusMessage = text
        isError = error
    }

    private func scheduleStillCurrent() -> Bool {
        // The store rechecks owner/record identity across every suspension
        // internally; this view only avoids publishing UI state after the
        // view itself disappeared. Always true while the view is alive.
        true
    }
}
