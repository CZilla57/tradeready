import SwiftUI

// MARK: - Trip editor (task 9.11, requirements T1, T2 rates)
//
// Port of `screens/AddTripScreen.tsx`: date, from/to endpoint chips (base +
// every job), odometer readings with a live distance line, an optional purpose,
// save, and delete-with-confirm. Validation, miles math, and the canonical
// projection come from `NativeMileage` (9.03); the commit is the typed,
// field-scoped 9.08 `commitTripEdit`, which preserves `createdAt` and every
// unknown field on edit.

/// Which trip the editor is working on.
enum NativeTripEditorTarget: Identifiable, Equatable {
    case create
    case edit(String)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit-\(id)"
        }
    }
}

struct NativeTripEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let target: NativeTripEditorTarget
    /// The canonical record as opened, used to seed the form and as the commit's
    /// stale-copy baseline.
    let opened: Canonical.Trip?

    @State private var draft: NativeTripDraft
    @State private var alert: NativeTripAlert?
    @State private var showingDeleteConfirmation = false

    init(target: NativeTripEditorTarget, opened: Canonical.Trip? = nil) {
        self.target = target
        self.opened = opened
        _draft = State(initialValue: opened.map(NativeMileageLog.draft(from:)) ?? NativeMileageLog.newDraft())
    }

    private var isEditing: Bool { if case .edit = target { return true }; return false }
    private var title: String { isEditing ? "Edit Trip" : "Add Trip" }
    private var invalid: Bool { NativeMileage.endBelowStart(draft) }

    private var endpoints: [NativeTripEndpoint] {
        NativeMileageLog.endpointChips(store.canonicalJobs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(label: "Date") {
                        TextField("YYYY-MM-DD", text: $draft.date)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }

                Section("From") { endpointChips(selected: draft.from, select: { draft.from = $0 }) }
                Section("To") { endpointChips(selected: draft.to, select: { draft.to = $0 }) }

                Section("Odometer") {
                    LabeledField(label: "Start") {
                        TextField("e.g. 45210", text: $draft.odometerStartText)
                            .keyboardType(.decimalPad)
                    }
                    LabeledField(label: "End") {
                        TextField("e.g. 45240", text: $draft.odometerEndText)
                            .keyboardType(.decimalPad)
                    }
                    Text(NativeMileageLog.distanceText(draft))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(invalid ? Color.tradeDangerText : Color.primary)
                        .accessibilityLabel(NativeMileageLog.distanceText(draft))
                }

                Section {
                    LabeledField(label: "Purpose (optional)") {
                        TextField("e.g. Drive to job site", text: $draft.purpose, axis: .vertical)
                    }
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                            Label("Delete Trip", systemImage: "trash")
                        }
                    }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save Changes" : "Add Trip") { save() }
                        .fontWeight(.semibold)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .alert(alert?.title ?? "", isPresented: showingAlert, presenting: alert) { _ in
                Button("OK", role: .cancel) { alert = nil }
            } message: { value in
                Text(value.message)
            }
            .confirmationDialog(
                "Delete trip",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove this trip from your mileage log?")
            }
        }
        .nativeAnalyticsScreen(.tripEditor)
    }

    private func endpointChips(
        selected: NativeTripEndpoint,
        select: @escaping (NativeTripEndpoint) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(endpoints.enumerated()), id: \.offset) { _, endpoint in
                    let isSelected = selected.jobId == endpoint.jobId
                    Button { select(endpoint) } label: {
                        Text(endpoint.label)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.tradeReadyFill : Color.tradeInk.opacity(0.06),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityLabel(endpoint.label)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Save / delete

    private func save() {
        if let error = NativeMileage.validationError(draft) {
            let copy = NativeMileageLog.validationAlert(error)
            alert = .validation(title: copy.title, message: copy.message)
            return
        }
        switch store.commitTripEdit(id: opened?.id, opened: opened, draft: draft) {
        case .success:
            dismiss()
        case .failure(let refusal):
            alert = .failure(title: "Couldn't Save", message: Self.refusalCopy(refusal))
        }
    }

    private func delete() {
        guard case .edit(let id) = target else { return }
        if store.deleteTripRecord(id: id) {
            dismiss()
        } else {
            alert = .failure(
                title: "Couldn't Delete",
                message: "That trip couldn't be deleted. Nothing was changed."
            )
        }
    }

    static func refusalCopy(_ refusal: NativeMoneyRecordRefusal) -> String {
        switch refusal {
        case .persistenceUnavailable: "Your trip couldn't be saved. Nothing was changed."
        case .missingRecord: "That trip is no longer available. Reopen the log."
        case .staleEditorCopy: "This trip changed on another device. Reopen it and try again."
        case .conflictingRecord: "That trip already exists."
        case .invalidDraft(let message): message
        }
    }

    private var showingAlert: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )
    }
}

/// RN's `Alert.alert` cases from the trip screen.
private enum NativeTripAlert: Equatable {
    case validation(title: String, message: String)
    case failure(title: String, message: String)

    var title: String {
        switch self {
        case .validation(let title, _), .failure(let title, _): title
        }
    }

    var message: String {
        switch self {
        case .validation(_, let message), .failure(_, let message): message
        }
    }
}
