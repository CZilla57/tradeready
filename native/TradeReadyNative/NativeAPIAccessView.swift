import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// Roadmap Phase 23 (open-API spec §9): Settings › API access. A thin view
/// over `NativeAPIAccessModel`; the server is the authority for every key and
/// nothing on this screen is cached, synced or saved.

extension SettingsDestination {
    /// The "APP" group's API access row: empty while the flag is off, so the
    /// entry is fully hidden (spec §11 stage C).
    static var apiAccessRows: [(SettingsDestination, String, String, String)] {
        NativeAPIAccessFeature.showsSettingsEntry()
            ? [(.apiAccess, "key.fill", "API access", "Connect other tools to read your data")]
            : []
    }
}

struct NativeAPIAccessView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if NativeAPIAccessFeature.showsSettingsEntry() {
            NativeAPIAccessScreen(store: store)
        } else {
            EmptyContent(title: "API access isn't available", message: "This version of TradeReady doesn't offer API keys yet.", symbol: "key")
        }
    }
}

private struct NativeAPIAccessScreen: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model: NativeAPIAccessModel
    @State private var rotating: NativeAPIKeySummary?
    @State private var revoking: NativeAPIKeySummary?

    init(store: AppStore) {
        _model = StateObject(wrappedValue: NativeAPIAccessModel(
            manager: store.apiKeyManager(),
            track: { [weak store] event in store?.trackAPIAccess(event) }
        ))
    }

    var body: some View {
        content
            .navigationTitle("API access")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                if store.apiAccessIsSignedIn, model.phase == .idle { await model.load() }
            }
            .sheet(item: sheetBinding) { sheet in
                switch sheet {
                case .create:
                    NativeAPIKeyCreateSheet(model: model)
                case let .reveal(reveal):
                    NativeAPIKeyRevealSheet(reveal: reveal) { model.dismissSheet() }
                }
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: alertBinding,
                presenting: model.alert
            ) { alert in
                if let keyId = alert.revokeKeyId {
                    Button("Revoke key", role: .destructive) { Task { await model.revoke(keyId: keyId) } }
                    Button("Not now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { alert in
                Text(alert.message)
            }
            .confirmationDialog(
                "Rotate “\(rotating?.name ?? "key")”?",
                isPresented: Binding(get: { rotating != nil }, set: { if !$0 { rotating = nil } }),
                titleVisibility: .visible,
                presenting: rotating
            ) { key in
                Button("Rotate, old key works 24 more hours") { Task { await model.rotate(key, grace: .twentyFourHours) } }
                Button("Rotate and stop the old key now", role: .destructive) { Task { await model.rotate(key, grace: .immediate) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("TradeReady makes a new key with the same name and access. Put the new key in your tool before the old one stops working.")
            }
            .confirmationDialog(
                "Revoke “\(revoking?.name ?? "key")”?",
                isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                titleVisibility: .visible,
                presenting: revoking
            ) { key in
                Button("Revoke key", role: .destructive) { Task { await model.revoke(keyId: key.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Tools using this key lose access on their next request. This can't be undone.")
            }
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        if !store.apiAccessIsSignedIn {
            ContentUnavailableView {
                Label("Sign in to manage API keys", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("API keys live in your TradeReady cloud account. Sign in to create or manage them.")
            }
        } else {
            switch model.phase {
            case .idle, .loading:
                ProgressView("Loading API keys…")
                    .accessibilityLabel("Loading API keys")
            case let .failed(error) where model.keys.isEmpty:
                failedState(error)
            default:
                keyList
            }
        }
    }

    @ViewBuilder private func failedState(_ error: NativeAPIKeyAdminError) -> some View {
        switch error {
        case .signedOut, .malformedSession, .rejectedSession:
            ContentUnavailableView {
                Label("Sign in to manage API keys", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(error.errorDescription ?? "")
            }
        default:
            ContentUnavailableView {
                Label(error == .unavailable ? "API access isn't available yet" : "Can't reach TradeReady",
                      systemImage: "icloud.slash")
            } description: {
                Text("API keys live in your TradeReady cloud account, so this page needs a connection. \(error.errorDescription ?? "")")
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .disabled(model.busy != nil)
            }
        }
    }

    // MARK: List

    private var keyList: some View {
        List {
            Section {
                Text("Let bookkeeping software, Zapier or your own scripts read your TradeReady data with a key.")
                Label(NativeAPIAccessText.freshnessNote, systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                Text(NativeAPIAccessText.readOnlyNote)
                    .font(.subheadline).foregroundStyle(.secondary)
                if let docs = URL(string: NativeAPIAccessText.developerDocsURLString) {
                    Link(destination: docs) {
                        Label("Developer documentation", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityHint("Opens the API documentation in your browser")
                }
            }

            statusSection
            pendingSection

            Section {
                Button { model.presentCreate() } label: {
                    Label("Create key", systemImage: "plus.circle.fill")
                }
                .disabled(!model.canCreate)
                .accessibilityHint("Opens a form to name the key and choose what it can read")
                if model.isAtKeyLimit {
                    Text("You have \(model.maxLiveKeys) active keys, the most allowed. Revoke one to create another. Keys being replaced don't count.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Keys · \(model.activeCount) of \(model.maxLiveKeys) active")
            }

            if model.liveKeys.isEmpty {
                Section {
                    Text("No keys yet. Create one to connect a tool.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.liveKeys) { key in
                Section {
                    NativeAPIKeyRow(key: key)
                    if key.canRotate(at: Date()) {
                        Button { rotating = key } label: {
                            actionLabel("Rotate key…", systemImage: "arrow.triangle.2.circlepath", busy: model.busy == .rotating(keyId: key.id))
                        }
                        .disabled(!model.canStartKeyChange)
                        .accessibilityHint("Asks how long the old key keeps working, then makes a replacement")
                    }
                    Button(role: .destructive) { revoking = key } label: {
                        actionLabel("Revoke key…", systemImage: "xmark.octagon", busy: model.busy == .revoking(keyId: key.id))
                            .nativeDestructiveText()
                    }
                    .disabled(model.busy != nil || model.isRateLimited())
                    .accessibilityHint("Asks for confirmation. Tools using the key lose access.")
                }
            }

            if !model.pastKeys.isEmpty {
                Section {
                    DisclosureGroup("Past keys (\(model.pastKeys.count))") {
                        ForEach(model.pastKeys) { key in NativeAPIKeyRow(key: key) }
                    }
                } footer: {
                    Text("Revoked and expired keys stay listed so you can tell what stopped working.")
                }
            }

            Section {
                NavigationLink {
                    NativeAPIActivityView(model: model)
                } label: {
                    Label("Recent activity", systemImage: "list.bullet.rectangle")
                }
            } footer: {
                Text("The last 50 requests other tools made with your keys.")
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .refreshable { await model.load() }
    }

    @ViewBuilder private var statusSection: some View {
        if model.notice != nil || model.rateLimitedUntil != nil {
            Section {
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.footnote)
                }
                if let until = model.rateLimitedUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < until {
                            Label(NativeAPIAccessText.rateLimited(until: until, now: context.date), systemImage: "hourglass")
                                .font(.footnote).foregroundStyle(Color.tradeWarningText)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var pendingSection: some View {
        if let pending = model.pending, model.sheet == nil {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pending.title).font(.headline)
                    Text("TradeReady couldn't confirm this finished. Retry sends the same request, so it never makes a second key.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button { Task { await model.retryPending() } } label: {
                    actionLabel("Retry", systemImage: "arrow.clockwise", busy: model.busy == .retrying)
                }
                .disabled(model.busy != nil || model.isRateLimited())
                .accessibilityHint("Sends the same request again. The server recognizes it, so it never makes a second key.")
                Button { Task { await model.dismissPending() } } label: {
                    Label("Dismiss and check my keys", systemImage: "xmark.circle")
                }
                .disabled(model.busy != nil)
            } header: {
                Text("Not confirmed")
            }
        }
    }

    private func actionLabel(_ title: String, systemImage: String, busy: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if busy { Spacer(); ProgressView().accessibilityLabel("\(title) in progress") }
        }
    }

    // MARK: Presentation plumbing

    /// Setting nil (a swipe-down on the create form) closes the sheet; the
    /// show-once sheet can only close through "I've saved it".
    private var sheetBinding: Binding<NativeAPIAccessModel.Sheet?> {
        Binding(get: { model.sheet }, set: { if $0 == nil { model.dismissSheet() } })
    }

    /// Alerts show here only while no sheet is up; the create form shows its own.
    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil && model.sheet == nil }, set: { if !$0 { model.alert = nil } })
    }
}

/// One key: name, status in words, prefix, access, dates. One VoiceOver element.
private struct NativeAPIKeyRow: View {
    let key: NativeAPIKeySummary

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(key.name.isEmpty ? "Unnamed key" : key.name).font(.headline)
                Spacer(minLength: 8)
                Text(NativeAPIAccessText.statusTitle(key, now: now))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(key.status(at: now)))
            }
            Text(NativeAPIAccessText.displayPrefix(key.prefix))
                .font(.subheadline.monospaced())
            Text(NativeAPIAccessText.scopeSummary(key.scopes))
                .font(.subheadline)
            Text(NativeAPIAccessText.statusDetail(key, now: now))
                .font(.caption).foregroundStyle(.secondary)
            Text([NativeAPIAccessText.created(key), NativeAPIAccessText.lastUsed(key, now: now)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NativeAPIAccessText.accessibilitySummary(key, now: now))
    }

    private func statusColor(_ status: NativeAPIKeyStatus) -> Color {
        switch status {
        case .active: Color.tradeSuccessText
        case .expiring: Color.tradeWarningText
        case .expired, .revoked: Color.secondary
        }
    }
}

// MARK: - Create

private struct NativeAPIKeyCreateSheet: View {
    @ObservedObject var model: NativeAPIAccessModel
    @State private var name = ""
    @State private var preset: NativeAPIScopePreset = .everything
    @State private var scopes: Set<NativeAPIScope> = Set(NativeAPIScope.allCases)
    @State private var expiry: NativeAPIKeyExpiry = .defaultChoice
    @State private var issue: NativeAPIKeyDraftIssue?

    private var isCreating: Bool { model.busy == .creating }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("For example, QuickBooks sync", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityLabel("Key name")
                    Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) of \(NativeAPIKeyName.maxLength) characters")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Name it after the tool that will use it, so you know which key to revoke later.")
                }

                if let issue {
                    Section {
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.tradeDangerText)
                    }
                }

                Section {
                    Picker("Access", selection: $preset) {
                        ForEach(NativeAPIScopePreset.allCases) { Text($0.title).tag($0) }
                    }
                    if preset == .custom {
                        ForEach(NativeAPIScope.allCases) { scope in
                            Toggle(isOn: binding(for: scope)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scope.title)
                                    Text(scope.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text(NativeAPIScope.canonical(scopes).map(\.title).joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What it can read")
                } footer: {
                    Text(NativeAPIAccessText.readOnlyNote)
                }

                Section {
                    Picker("Expires", selection: $expiry) {
                        ForEach(NativeAPIKeyExpiry.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Expiry")
                } footer: {
                    Text("An expired key stops working. You can rotate a key before then to keep the tool connected.")
                }

                if isCreating {
                    Section {
                        ProgressView("Creating key…")
                            .accessibilityLabel("Creating key")
                    }
                }
            }
            .nativeContentColumn(.list)
            .navigationTitle("New API key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.dismissSheet() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(model.busy != nil || !model.canCreate)
                }
            }
            .interactiveDismissDisabled(isCreating)
            .onChange(of: preset) { _, newValue in
                if let fixed = newValue.scopes { scopes = Set(fixed) }
            }
            .onChange(of: name) { _, _ in issue = nil }
            .onChange(of: scopes) { _, _ in issue = nil }
            .alert(
                model.alert?.title ?? "",
                isPresented: Binding(
                    get: { model.alert != nil && model.sheet == .create },
                    set: { if !$0 { model.alert = nil } }
                ),
                presenting: model.alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
    }

    private func binding(for scope: NativeAPIScope) -> Binding<Bool> {
        Binding(
            get: { scopes.contains(scope) },
            set: { on in
                if on { scopes.insert(scope) } else { scopes.remove(scope) }
            }
        )
    }

    private func submit() {
        guard model.busy == nil else { return }
        switch NativeAPIKeyCreateRequest.validated(name: name, scopes: scopes, expiry: expiry) {
        case let .failure(found):
            issue = found
        case let .success(request):
            issue = nil
            Task { await model.create(request) }
        }
    }
}

// MARK: - Show once

private struct NativeAPIKeyRevealSheet: View {
    let reveal: NativeAPIAccessModel.Reveal
    let onDone: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(reveal.keyName.isEmpty ? "Unnamed key" : reveal.keyName).font(.headline)
                    if scenePhase == .active {
                        Text(reveal.secret.revealedValue)
                            .font(.body.monospaced())
                            .privacySensitive()
                            .accessibilityLabel("API key")
                            .accessibilityValue(reveal.secret.revealedValue)
                    } else {
                        // Keeps the key out of the app-switcher snapshot.
                        Text("Hidden while TradeReady is in the background.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your new key")
                }

                Section {
                    Button { copy() } label: {
                        Label(copied ? "Copied" : "Copy key", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .accessibilityHint("Copies the key to this device's clipboard for two minutes")
                    if copied {
                        Text("Copied to this device only. It clears from the clipboard in 2 minutes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Label(NativeAPIAccessText.showOnceWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.tradeWarningText)
                    if let note = NativeAPIAccessText.previousKeyNote(reveal.previous, now: Date()) {
                        Text(note)
                    }
                    Text("Paste it into the tool's settings now, or save it in a password manager. Anyone with this key can read the data it allows.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Section {
                    Button { onDone() } label: {
                        Text("I've saved it").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .tradeReadyProminentButtonStyle()
                    .listRowBackground(Color.clear)
                    .accessibilityHint("Closes this sheet. The key can't be shown again.")
                }
            }
            .nativeContentColumn(.list)
            .navigationTitle("Save your key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled()
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: reveal.secret.revealedValue]],
            options: [
                .localOnly: NativeAPIKeyClipboardPolicy.localOnly,
                .expirationDate: NativeAPIKeyClipboardPolicy.expiration(from: Date()),
            ]
        )
        #endif
        copied = true
    }
}

// MARK: - Activity

private struct NativeAPIActivityView: View {
    @ObservedObject var model: NativeAPIAccessModel

    var body: some View {
        List {
            switch model.activityPhase {
            case .idle, .loading:
                ProgressView("Loading activity…")
                    .accessibilityLabel("Loading recent activity")
            case let .failed(error):
                Section {
                    Label(error.errorDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.tradeDangerText)
                    Button("Try again") { Task { await model.loadActivity() } }
                }
            case .loaded:
                if model.activity.isEmpty {
                    Text("No requests yet. When a tool uses one of your keys, it shows here.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(model.activity) { event in
                            NativeAPIActivityRow(event: event, keyName: model.keyName(for: event.keyId))
                        }
                    } footer: {
                        Text("Newest first. TradeReady keeps request logs for 90 days.")
                    }
                }
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .navigationTitle("Recent activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.loadActivity() }
        .task { await model.loadActivity() }
    }
}

private struct NativeAPIActivityRow: View {
    let event: NativeAPIActivityEvent
    let keyName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.route.isEmpty ? "Unknown request" : event.route)
                    .font(.subheadline.monospaced())
                Spacer(minLength: 8)
                Text(NativeAPIAccessText.activityOutcome(event))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(details)
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NativeAPIAccessText.activityAccessibility(event, keyName: keyName, now: Date()))
    }

    private var details: String {
        var parts: [String] = []
        if let at = event.at { parts.append(NativeAPIAccessText.dayAndTime(at, locale: .current, timeZone: .current)) }
        if let keyName, !keyName.isEmpty { parts.append(keyName) }
        if let ip = event.ip, !ip.isEmpty { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch event.kind {
        case .ok: Color.tradeSuccessText
        case .rateLimited: Color.tradeWarningText
        case .denied, .error: Color.tradeDangerText
        case .other: Color.secondary
        }
    }
}
