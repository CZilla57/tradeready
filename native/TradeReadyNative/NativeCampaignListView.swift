import SwiftUI

// MARK: - Phase 33: the campaign list (spec §5.5 entry points, §7.2 resume)
//
// Presented as a sheet from the Customers toolbar ("Campaigns") and from the
// Today `maintenance_due:all` row (with the "Due for maintenance" preset, which
// opens the builder on an unsaved draft). Drafts and campaigns in progress
// come first ("22 of 34 sent · Resume"), then done ones.

enum NativeCampaignRoute: Hashable {
    /// A new, unsaved draft from a preset.
    case newDraft(NativeCampaignSegments.Preset)
    case builder(String)
    case detail(String)
}

/// A Today request to open the builder with a preset (`sheet(item:)`).
struct NativeCampaignPresetRequest: Identifiable, Equatable {
    var id: String { preset.rawValue }
    let preset: NativeCampaignSegments.Preset
}

struct NativeCampaignListView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var initialPreset: NativeCampaignSegments.Preset?
    @State private var path: [NativeCampaignRoute] = []
    @State private var choosingPreset = false
    @State private var handledInitialPreset = false
    @State private var deleting: Canonical.Campaign?
    @State private var errorMessage: String?

    init(initialPreset: NativeCampaignSegments.Preset? = nil) {
        self.initialPreset = initialPreset
    }

    private var active: [Canonical.Campaign] {
        store.campaigns.filter { NativeCampaignQueue.campaignStatus($0) != .done }
    }

    private var done: [Canonical.Campaign] {
        store.campaigns.filter { NativeCampaignQueue.campaignStatus($0) == .done }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button("New campaign", systemImage: "plus") { choosingPreset = true }
                } footer: {
                    Text("Text or email past customers, one reviewed message at a time from your phone. Nothing sends until you tap Send.")
                }
                if store.campaigns.isEmpty {
                    EmptyContent(
                        title: "No campaigns yet",
                        message: "Bring past customers back with a tune-up reminder or a check-in.",
                        symbol: "megaphone"
                    )
                    .listRowBackground(Color.clear)
                }
                if !active.isEmpty {
                    Section("Drafts and in progress") { ForEach(active, id: \.id) { row($0) } }
                }
                if !done.isEmpty {
                    Section("Done") { ForEach(done, id: \.id) { row($0) } }
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle("Campaigns")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .navigationDestination(for: NativeCampaignRoute.self) { route in
                switch route {
                case let .newDraft(preset): NativeCampaignBuilderView(preset: preset)
                case let .builder(id): NativeCampaignBuilderView(campaignID: id)
                case let .detail(id): NativeCampaignDetailView(campaignID: id)
                }
            }
            .confirmationDialog("Who is it for?", isPresented: $choosingPreset, titleVisibility: .visible) {
                ForEach(NativeCampaignSegments.Preset.allCases, id: \.self) { preset in
                    Button(preset.displayName) { path.append(.newDraft(preset)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pick a starting audience. You can change every filter next.")
            }
            .confirmationDialog(
                "Delete \(deleting?.name ?? "campaign")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete campaign", role: .destructive) {
                    if let id = deleting?.id, !store.deleteCampaign(id: id) {
                        errorMessage = "The campaign could not be deleted. Nothing was changed."
                    }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its results stop showing. Customers keep their records. You can undo for a few seconds.")
            }
            .alert("Campaign", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                guard !handledInitialPreset else { return }
                handledInitialPreset = true
                if let initialPreset { path = [.newDraft(initialPreset)] }
            }
        }
    }

    private func row(_ campaign: Canonical.Campaign) -> some View {
        let status = NativeCampaignQueue.campaignStatus(campaign)
        return NavigationLink(value: status == .draft ? NativeCampaignRoute.builder(campaign.id) : .detail(campaign.id)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(campaign.name).font(.headline)
                Text(Self.statusLine(campaign)).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if case .failure = store.duplicateCampaign(id: campaign.id) {
                    errorMessage = "The copy could not be saved. Nothing was changed."
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = campaign }
        }
    }

    /// "Draft", "Paused · 22 left · Resume", "Done · Sent 31".
    static func statusLine(_ campaign: Canonical.Campaign) -> String {
        let progress = NativeCampaignQueue.progress(campaign)
        switch NativeCampaignQueue.campaignStatus(campaign) {
        case .draft:
            return "Draft"
        case .sending:
            let left = progress.pending + progress.failed
            return progress.sent == 0
                ? "Ready to send · \(left) left · Resume"
                : "Paused · \(progress.sent) of \(progress.total) sent · \(left) left · Resume"
        case .done:
            return "Done · " + NativeCampaignQueue.summary(campaign)
        }
    }
}
