import SwiftUI

// Phase 12 (12.00b.1, known issue I2; owner decision D3): Settings › Cloud
// Sync › "N changes couldn't be saved". The changes the server refused left
// the sync queue, so everything else keeps syncing; each one waits here with
// its record type, name and when it was refused. Retry sends it again through
// the normal push. Discard, after a confirmation, shows the cloud's version of
// the record on this device (a record the cloud never had is removed).

struct NativeRejectedChangesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var discardCandidate: NativeRejectedChange?
    @State private var busyID: String?
    @State private var actionError: String?

    var body: some View {
        Form {
            if store.rejectedChanges.isEmpty {
                Section {
                    Label("Every change has been saved or cleared.", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    // Newest first.
                    ForEach(store.rejectedChanges.reversed()) { change in
                        row(change)
                    }
                } footer: {
                    Text("The cloud refused these changes, so they are saved on this device only. Retry sends a change again. Discard replaces it with the cloud's version. Everything else keeps syncing.")
                }
            }
        }
        .nativeContentColumn(.list)
        .scrollContentBackground(.hidden)
        .background(Color.tradeCanvas)
        .navigationTitle("Changes not saved")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.refreshRejectedChanges() }
        .confirmationDialog(
            "Discard this change?",
            isPresented: Binding(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: discardCandidate
        ) { change in
            Button("Discard change", role: .destructive) { discard(change) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This device will show the cloud's version of this record instead. If the record was never saved to the cloud, it will be removed from this device.")
        }
        .alert(
            "Couldn't finish",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func row(_ change: NativeRejectedChange) -> some View {
        let type = NativeRejectedChangeDisplay.typeLabel(table: change.item.table)
        let name = displayName(change)
        let when = change.rejectedAt.formatted(date: .abbreviated, time: .shortened)
        let busy = busyID == change.id
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(type)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.body.weight(.medium))
                Text("Not saved \(when)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(type), \(name), not saved \(when)")
            HStack(spacing: 12) {
                Button {
                    retry(change)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Sends this change to the cloud again.")
                Button(role: .destructive) {
                    discardCandidate = change
                } label: {
                    Label("Discard", systemImage: "arrow.uturn.backward")
                        .nativeDestructiveText()
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Shows the cloud's version of this record instead.")
                if busy { ProgressView() }
            }
            .disabled(busyID != nil)
        }
        .padding(.vertical, 4)
    }

    private func displayName(_ change: NativeRejectedChange) -> String {
        if let name = store.rejectedChangeName(change) { return name }
        return change.item.op == .delete ? "Deleted on this device" : "Untitled"
    }

    private func retry(_ change: NativeRejectedChange) {
        if !store.retryRejectedChange(id: change.id) {
            actionError = "This change couldn't be sent again. Nothing was changed."
        }
    }

    private func discard(_ change: NativeRejectedChange) {
        busyID = change.id
        Task {
            let message = await store.discardRejectedChange(id: change.id)
            busyID = nil
            if let message { actionError = message }
        }
    }
}
