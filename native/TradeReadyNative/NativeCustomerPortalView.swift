import SwiftUI
import MessageUI

/// Phase 8 task 8.13 customer portal administration UI (requirement P1).
///
/// Thin view over the 8.06/8.07 portal authority and the 8.08 administration
/// entry point (`administerPortalLink`). Server-first actions with per-customer
/// serialization; local mirror adopted only on fresh `tokenValid` read.
struct NativeCustomerPortalView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let customerID: String
    let customerName: String

    @State private var status: NativePortalLinkStatus?
    @State private var shareURL: URL?
    @State private var busyAction: NativePortalAdminAction?
    @State private var confirmingRotate = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var didLoad = false

    private var localDisplay: (token: String?, enabled: Bool?) {
        store.portalLinkLocalDisplay(customerID: customerID)
    }

    var body: some View {
        Group {
            if !didLoad {
                ProgressView("Loading portal link…")
                    .accessibilityLabel("Loading customer portal status")
                    .onAppear { Task { await refresh(clearMessage: true) } }
            } else {
                portalForm
            }
        }
        .navigationTitle("Customer Portal")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Rotate the portal link?",
            isPresented: $confirmingRotate,
            titleVisibility: .visible
        ) {
            Button("Rotate link", role: .destructive) { Task { await rotate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current link stops working immediately. Share the new link afterwards.")
        }
    }

    private var portalForm: some View {
        Form {
            Section(header: Text("Customer")) {
                LabeledContent("Name", value: customerName)
            }

            Section(header: Text("Status")) {
                HStack {
                    stateDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateTitle).font(.headline)
                        Text(stateSubtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Portal link status: \(stateTitle). \(stateSubtitle)")

                if let url = shareURL {
                    LabeledContent("Public link") {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .accessibilityLabel("Public portal link \(url.absoluteString)")
                    }
                } else if localDisplay.token != nil {
                    Text("The saved link is stale or unverified — refresh its status before sharing. A stale token is never shared.")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityLabel("Saved link is stale or unverified. Refresh before sharing.")
                }
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.footnote).foregroundStyle(isError ? .red : .secondary)
                        .accessibilityLabel(statusMessage)
                }
            }

            Section(header: Text("Link actions")) {
                Button { Task { await refresh(clearMessage: false) } } label: {
                    actionLabel("Refresh status", systemImage: "arrow.triangle.2.circlepath", busy: busyAction == .status)
                }
                .disabled(busyAction != nil)
                .accessibilityHint("Re-reads the authoritative link state")

                if localDisplay.token == nil {
                    Button { Task { await create() } } label: {
                        actionLabel("Create portal link", systemImage: "link.badge.plus", busy: busyAction == .mint)
                    }
                    .disabled(busyAction != nil)
                    .accessibilityHint("Creates the link on the server first, then saves the local copy")
                } else {
                    if let url = shareURL {
                        ShareLink(item: url) {
                            Label("Share portal link", systemImage: "square.and.arrow.up")
                        }
                        .disabled(busyAction != nil)
                        .accessibilityHint("Cancelling the share sheet changes nothing — sharing is not delivery evidence")

                        Button { copyLink(url) } label: {
                            Label("Copy portal link", systemImage: "doc.on.doc")
                        }
                        .disabled(busyAction != nil)
                        .accessibilityHint("Copies the verified link. A stale copy is never offered here.")
                    }

                    if status?.enabled == true {
                        Button { Task { await setEnabled(false) } } label: {
                            actionLabel("Disable portal link", systemImage: "link.badge.plus", busy: busyAction == .setEnabled)
                        }
                        .disabled(busyAction != nil)
                        .accessibilityHint("Customer immediately stops reaching this link after the server confirms")
                    } else {
                        Button { Task { await setEnabled(true) } } label: {
                            actionLabel("Enable portal link", systemImage: "link", busy: busyAction == .setEnabled)
                        }
                        .disabled(busyAction != nil)
                        .accessibilityHint("Re-enables the verified link on the server first")
                    }

                    Button { confirmingRotate = true } label: {
                        actionLabel("Rotate link", systemImage: "arrow.triangle.2.circlepath.circle", busy: busyAction == .rotate)
                    }
                    .disabled(busyAction != nil)
                    .foregroundStyle(.red)
                    .accessibilityHint("Asks for confirmation, then replaces the link. The old link stops working.")
                }
            }

            Section {
                Text("A customer must be saved (not just from invoices) before a portal link can be created. Invoice-derived identities must be promoted first.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The portal link gives the customer access to their appointments, estimates, invoices, change orders, and shared photos. Share cancellation changes no delivery state.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stateDot: some View {
        let color: Color = shareURL != nil ? .green : (status == nil ? .orange : .secondary)
        return Circle().fill(color).frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var stateTitle: String {
        if shareURL != nil { return (status?.enabled ?? false) ? "Published" : "Link ready" }
        if status == nil { return "Unavailable" }
        return localDisplay.token == nil ? "No link yet" : "Needs recovery"
    }

    private var stateSubtitle: String {
        if shareURL != nil {
            return status?.enabled == true
                ? "Customer can access their portal."
                : "The link is verified but currently disabled — customer cannot access their portal."
        }
        if status == nil {
            return "Could not reach the portal service. Nothing here claims a published state."
        }
        if localDisplay.token == nil {
            return "Create a link to let this customer access their portal."
        }
        return "The saved copy no longer matches the server. Rotate with confirmation to recover — never share the stale copy."
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String, busy: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if busy { Spacer(); ProgressView().accessibilityLabel("\(title) in progress") }
        }
    }

    // MARK: - Actions

    private func refresh(clearMessage: Bool) async {
        busyAction = .status
        defer {
            busyAction = nil
            if didLoad == false { didLoad = true }
        }
        if clearMessage { statusMessage = nil; isError = false }

        do {
            let bytes = try await store.scheduleBookingSessionBytes()
            let endpoint = try NativePortalAdministrationService.resolvedEndpoint()
            let service = NativePortalAdministrationService(endpoint: endpoint)
            let displayToken = localDisplay.token
            let reconciled = try await service.status(
                customerId: customerID,
                token: displayToken,
                sessionBytes: bytes
            )
            await MainActor.run {
                status = reconciled
                shareURL = NativeScheduleBookingPolicy.mayAdoptPortalDisplayToken(
                    displayToken: displayToken,
                    status: reconciled
                ) ? NativePortalAdministrationService.portalURL(token: displayToken!) : nil

                if reconciled.tokenValid, reconciled.enabled, shareURL != nil, clearMessage == false {
                    setMessage("Verified against the server.", error: false)
                } else if reconciled.tokenValid == false, localDisplay.token != nil {
                    setMessage("The saved link is stale. Rotate with confirmation to recover.", error: false)
                } else if reconciled.tokenValid == false, localDisplay.token == nil {
                    setMessage("No verified link exists for this customer.", error: false)
                }
            }
        } catch {
            await MainActor.run {
                setMessage("Could not reach the portal service. Your saved copy is unchanged and nothing claims to be published.", error: true)
            }
        }
    }

    private func create() async {
        busyAction = .mint
        defer { busyAction = nil }
        await administer(.mint, enabled: nil, successVerb: "created")
    }

    private func setEnabled(_ enabled: Bool) async {
        busyAction = .setEnabled
        defer { busyAction = nil }
        await administer(.setEnabled, enabled: enabled, successVerb: enabled ? "enabled" : "disabled")
    }

    private func rotate() async {
        busyAction = .rotate
        defer { busyAction = nil }
        await administer(.rotate, enabled: nil, successVerb: "rotated")
    }

    private func administer(_ action: NativePortalAdminAction, enabled: Bool?, successVerb: String) async {
        let outcome = await store.administerPortalLink(
            customerID: customerID,
            action: action,
            enabled: enabled,
            operationId: UUID().uuidString
        )
        await MainActor.run {
            switch outcome {
            case .applied:
                Task { await refresh(clearMessage: true) }
                setMessage("Portal link \(successVerb) and verified.", error: false)
            case .alreadyExists(let adopted):
                Task { await refresh(clearMessage: true) }
                if adopted {
                    setMessage("A link already exists on the server. Its current state is shown — nothing was duplicated.", error: false)
                } else {
                    setMessage("A link already exists on the server. Its current state is shown — nothing was duplicated.", error: false)
                }
            case .needsExplicitRotate:
                setMessage("The saved link is stale. Rotate with confirmation to recover.", error: true)
            case .recoveryStaged:
                setMessage("Updated on the server, but the local copy could not be saved. It will finish automatically — refresh to verify. No second link was created.", error: true)
            case .unknownOutcome:
                setMessage("The request may or may not have reached the server. Check the status before trying again — nothing was retried automatically.", error: true)
            case .missingCustomer:
                setMessage("The customer was not found. It may have been removed on another device.", error: true)
            case .alreadyRunning:
                setMessage("A portal action is already running. Wait for it to finish.", error: true)
            case .failed(let reason):
                setMessage(failureText(reason: reason), error: true)
            }
        }
    }

    private func failureText(reason: String) -> String {
        switch reason {
        case "not-signed-in": "Sign in before managing the portal link."
        case "session": "Your session expired. Sign in again before managing the portal link."
        case "configuration": "Portal links are not configured for this build."
        case "status-unavailable": "Could not reach the portal service. Nothing was changed."
        case "owner-changed": "The account changed while working. Nothing was published for the wrong account."
        case "already-running": "A link action is already running. Wait for it to finish."
        case "invalid-request": "This request was invalid and was not sent."
        default: "The portal service is unavailable. Check your connection and try again."
        }
    }

    private func copyLink(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.string = url.absoluteString
        #endif
        setMessage("Copied. Pasting it somewhere is not delivery evidence.", error: false)
    }

    private func setMessage(_ text: String, error: Bool) {
        statusMessage = text
        isError = error
    }
}

// Note: portalLinkLocalDisplay is implemented in AppStore.swift as a public method