import SwiftUI

// Phase 21 (multi-property and equipment history) screens. Spec:
// `docs/superpowers/specs/2026-10-02-properties-equipment-design.md` §3.
//
// Kept in their own file so the shared screens only gain one-line
// insertions: `NativeCustomerPropertiesSection` (customer detail, after
// Contact), `NativeJobAddressRow` and `NativeJobPropertySection` (job detail)
// and `NativeJobPropertyPicker` (job editor). Every write goes through the
// `AppStore` properties API (`NativePropertiesEquipmentStore.swift`).

private typealias Properties = NativePropertiesEquipment

// MARK: - Customer detail › Properties

/// The customer detail "Properties" section: the primary first (labelled
/// "Primary", the customer's address), then the others; each row shows its
/// equipment count and its jobs. Archived properties come last.
struct NativeCustomerPropertiesSection: View {
    @EnvironmentObject private var store: AppStore
    let customerID: String
    @State private var showingAddProperty = false

    var body: some View {
        let properties = store.customerProperties(customerID: customerID)
        Section {
            ForEach(properties) { property in
                NavigationLink {
                    NativePropertyDetailView(customerID: customerID, propertyID: property.id)
                } label: {
                    NativePropertyRow(
                        property: property,
                        jobCount: store.propertyJobHistory(customerID: customerID, propertyID: property.id).count
                    )
                }
            }
            Button("Add property", systemImage: "plus.circle") { showingAddProperty = true }
        } header: {
            Text("Properties")
        } footer: {
            if properties.count == 1 {
                Text("Add a property when this customer has work at more than one address, like a rental.")
            }
        }
        .sheet(isPresented: $showingAddProperty) {
            NativePropertyEditor(customerID: customerID, propertyID: nil)
        }
    }
}

private struct NativePropertyRow: View {
    let property: NativePropertiesEquipment.ResolvedProperty
    let jobCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(property.isPrimary ? (property.label.map { "Primary · \($0)" } ?? "Primary") : property.displayName)
                    .font(.headline)
                if property.isArchived {
                    Text("Archived")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if !property.address.isEmpty, property.isPrimary || property.label != nil {
                Text(property.address).font(.subheadline).foregroundStyle(.secondary)
            } else if property.address.isEmpty {
                Text("No address yet").font(.subheadline).foregroundStyle(.secondary)
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let count = property.activeEquipment.count
        let equipment = count == 1 ? "1 piece of equipment" : "\(count) pieces of equipment"
        let jobs = jobCount == 1 ? "1 job" : "\(jobCount) jobs"
        return "\(equipment) · \(jobs)"
    }
}

// MARK: - Property detail

struct NativePropertyDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let customerID: String
    let propertyID: String
    @State private var editingProperty = false
    @State private var equipmentTarget: NativeEquipmentEditorTarget?
    @State private var confirmationRequest: NativeConfirmationRequest?
    @State private var errorMessage: String?

    private var property: NativePropertiesEquipment.ResolvedProperty? {
        store.customerProperty(customerID: customerID, propertyID: propertyID)
    }

    var body: some View {
        Group {
            if let property {
                List { sections(property) }
                    .nativeContentColumn(.list)
                    .tradeReadyListStyle()
                    .navigationTitle(property.isPrimary ? "Primary property" : property.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Edit", systemImage: "pencil") { editingProperty = true }
                    }
                    .sheet(isPresented: $editingProperty) {
                        NativePropertyEditor(customerID: customerID, propertyID: property.id)
                    }
            } else {
                EmptyContent(
                    title: "Property unavailable",
                    message: "This property is no longer on this device.",
                    symbol: "house.slash"
                )
            }
        }
        .sheet(item: $equipmentTarget) { target in
            NativeEquipmentEditor(target: target)
        }
        .nativeConfirmation($confirmationRequest) { intent in
            guard case let .deleteProperty(customerID, propertyID) = intent else { return }
            if store.deleteProperty(customerID: customerID, propertyID: propertyID) {
                dismiss()
            } else {
                errorMessage = Properties.PropertyError.notSaved.message
            }
        }
        .alert("Couldn’t update property", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func sections(_ property: NativePropertiesEquipment.ResolvedProperty) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if let label = property.label {
                    Text(label).font(.title3.bold())
                }
                Label(property.address.isEmpty ? "No address yet" : property.address, systemImage: "mappin.and.ellipse")
                if property.isPrimary {
                    Text("Primary property: the customer's own address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if property.isArchived {
                    Text("Archived. Its jobs show their own address only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        if let notes = property.notes {
            Section("Notes") { Text(notes) }
        }
        Section("Equipment") {
            if property.activeEquipment.isEmpty {
                Text("No equipment yet").foregroundStyle(.secondary)
            }
            ForEach(property.activeEquipment, id: \.id) { item in
                Button {
                    equipmentTarget = .edit(customerID: customerID, propertyID: property.id, equipmentID: item.id)
                } label: {
                    NativeEquipmentRow(item: item, status: store.warrantyStatus(item))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the equipment details")
            }
            Button("Add equipment", systemImage: "plus.circle") {
                equipmentTarget = .add(customerID: customerID, propertyID: property.id)
            }
        }
        if !property.archivedEquipment.isEmpty {
            Section("Past equipment") {
                ForEach(property.archivedEquipment, id: \.id) { item in
                    Button {
                        equipmentTarget = .edit(customerID: customerID, propertyID: property.id, equipmentID: item.id)
                    } label: {
                        NativeEquipmentRow(item: item, status: nil, isPast: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the equipment details")
                }
            }
        }
        let history = store.propertyJobHistory(customerID: customerID, propertyID: property.id)
        Section("Job history") {
            if history.isEmpty {
                Text("No jobs at this property yet").foregroundStyle(.secondary)
            }
            ForEach(history) { job in
                NavigationLink {
                    JobDetailView(jobID: job.id)
                } label: {
                    JobRow(job: job)
                }
            }
        }
        if !property.isPrimary {
            Section {
                Button(
                    property.isArchived ? "Restore property" : "Archive property",
                    systemImage: property.isArchived ? "arrow.uturn.backward" : "archivebox"
                ) {
                    let result = store.setPropertyArchived(
                        customerID: customerID, propertyID: property.id, archived: !property.isArchived
                    )
                    if case let .failure(error) = result { errorMessage = error.message }
                }
                Button(role: .destructive) {
                    confirmationRequest = .deleteProperty(
                        customerID: customerID, propertyID: property.id, name: property.displayName
                    )
                } label: {
                    Label("Delete property", systemImage: "trash").nativeDestructiveText()
                }
            } footer: {
                Text("Archiving keeps the equipment and job history. Its jobs keep their own address.")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

/// One equipment row: type, make and model, serial and warranty, read as one
/// VoiceOver element. Warranty state is always spelled out, never color only.
struct NativeEquipmentRow: View {
    let item: Canonical.Equipment
    let status: NativePropertiesEquipment.WarrantyStatus?
    var isPast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Properties.typeDisplayName(item.type)).font(.headline).foregroundStyle(.primary)
            let model = [item.make, item.model].compactMap { Properties.singleLine($0) }.joined(separator: " ")
            if !model.isEmpty {
                Text(model).font(.subheadline).foregroundStyle(.secondary)
            }
            if let serial = Properties.singleLine(item.serial) {
                Text("Serial \(serial)").font(.caption).foregroundStyle(.secondary)
            }
            if isPast {
                Text(item.archivedAt.map { "Removed \(Properties.displayDate($0))" } ?? "Removed")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let status, let expires = item.warrantyExpires {
                Label(
                    "Warranty \(Properties.displayDate(expires)): \(Properties.warrantyText(status))",
                    systemImage: status == .expired ? "exclamationmark.shield" : "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(status == .expired ? Color.tradeWarningText : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Property editor

struct NativePropertyEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let customerID: String
    /// `nil` adds a property.
    let propertyID: String?
    @State private var draft = NativePropertiesEquipment.PropertyDraft()
    @State private var isPrimary = false
    @State private var primaryAddress = ""
    @State private var didLoad = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @StateObject private var addressLookup = NativeAddressLookupModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Property") {
                    LabeledField(label: "Name (optional)") {
                        TextField("Home, Rental on Elm…", text: $draft.label)
                            .textInputAutocapitalization(.words)
                    }
                }
                Section {
                    if isPrimary {
                        Text(primaryAddress.isEmpty ? "No address yet" : primaryAddress)
                            .accessibilityLabel("Address, \(primaryAddress.isEmpty ? "none yet" : primaryAddress)")
                    } else {
                        addressFields
                    }
                } header: {
                    Text("Address")
                } footer: {
                    if isPrimary {
                        Text("The primary property is the customer's own address. Change it from Edit customer.")
                    }
                }
                Section {
                    TextField("Gate code, dog, shutoff location…", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Property notes")
                } header: {
                    Text("Notes")
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(propertyID == nil ? "New Property" : "Edit Property")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                DismissableFormToolbar(title: "Property") { save() }
            }
            .alert("Property not saved", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private var addressFields: some View {
        TextField("Street, city, state ZIP", text: Binding(
            get: { draft.address },
            set: {
                draft.address = $0
                addressLookup.update(query: $0)
            }
        ), axis: .vertical)
        .textContentType(.fullStreetAddress)
        .accessibilityLabel("Address")
        if addressLookup.state == .searching {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding addresses…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        ForEach(addressLookup.suggestions) { suggestion in
            Button {
                draft.address = addressLookup.select(suggestion)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title).foregroundStyle(.primary)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Use address \(suggestion.address)")
        }
        if addressLookup.state == .selected {
            Label("Address selected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.tradeSuccessText)
        } else if addressLookup.state == .noResults {
            Text("No matching address found. You can still save what you entered.")
                .font(.caption).foregroundStyle(.secondary)
        } else if addressLookup.state == .unavailable {
            Text("Address lookup is unavailable. You can still save what you entered.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let propertyID, let property = store.customerProperty(customerID: customerID, propertyID: propertyID)
        else { return }
        draft = .init(property)
        isPrimary = property.isPrimary
        primaryAddress = property.address
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let failure: NativePropertiesEquipment.PropertyError?
        if let propertyID {
            if case let .failure(error) = store.updateProperty(customerID: customerID, propertyID: propertyID, draft: draft) {
                failure = error
            } else { failure = nil }
        } else {
            if case let .failure(error) = store.addProperty(customerID: customerID, draft: draft) {
                failure = error
            } else { failure = nil }
        }
        if let failure { errorMessage = failure.message } else { dismiss() }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Equipment editor

/// Which equipment sheet to show.
enum NativeEquipmentEditorTarget: Identifiable, Equatable {
    case add(customerID: String, propertyID: String)
    case edit(customerID: String, propertyID: String, equipmentID: String)

    var id: String {
        switch self {
        case let .add(customerID, propertyID): "add:\(customerID):\(propertyID)"
        case let .edit(customerID, propertyID, equipmentID): "edit:\(customerID):\(propertyID):\(equipmentID)"
        }
    }

    var customerID: String {
        switch self {
        case let .add(customerID, _), let .edit(customerID, _, _): customerID
        }
    }

    var propertyID: String {
        switch self {
        case let .add(_, propertyID), let .edit(_, propertyID, _): propertyID
        }
    }

    var equipmentID: String? {
        if case let .edit(_, _, equipmentID) = self { return equipmentID }
        return nil
    }
}

struct NativeEquipmentEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: NativeEquipmentEditorTarget
    @State private var draft = NativePropertiesEquipment.EquipmentDraft(type: "furnace")
    @State private var isArchived = false
    @State private var didLoad = false
    /// True while "Other…" is chosen, so an empty custom field stays open.
    @State private var isEnteringOtherType = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmationRequest: NativeConfirmationRequest?

    /// Picker tag for "Other…" (control characters never survive
    /// normalization, so no stored type can collide with it).
    private static let otherTag = "\u{1}other"

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    typePicker
                    if typeSelection == Self.otherTag {
                        TextField("Pool heater, humidifier…", text: Binding(
                            get: { draft.type == Properties.otherTypeKey ? "" : draft.type },
                            set: {
                                isEnteringOtherType = true
                                draft.type = $0.isEmpty ? Properties.otherTypeKey : $0
                            }
                        ))
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Other equipment type")
                    }
                    LabeledField(label: "Make") {
                        TextField("Carrier, Rheem…", text: $draft.make).textInputAutocapitalization(.words)
                    }
                    LabeledField(label: "Model") {
                        TextField("Model number", text: $draft.model).textInputAutocapitalization(.characters)
                    }
                    LabeledField(label: "Serial number") {
                        TextField("Serial number", text: $draft.serial)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }
                Section {
                    dateRow(title: "Install date", value: $draft.installDate)
                    dateRow(title: "Warranty expires", value: $draft.warrantyExpires)
                    if let expires = draft.warrantyExpires,
                       let days = Properties.daysBetween(NativeCashBasis.ymd(.now), expires) {
                        Text(Properties.warrantyText(days < 0 ? .expired : .expiresIn(days: days)))
                            .font(.subheadline)
                            .foregroundStyle(days < 0 ? Color.tradeWarningText : Color.secondary)
                    }
                } header: {
                    Text("Dates")
                } footer: {
                    Text("Optional. Today's insights mention a warranty that ends within 30 days.")
                }
                Section {
                    TextField("Filter size, last service, quirks…", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Equipment notes")
                } header: {
                    Text("Notes")
                }
                if let equipmentID = target.equipmentID {
                    Section {
                        Button(
                            isArchived ? "Restore equipment" : "Mark as removed",
                            systemImage: isArchived ? "arrow.uturn.backward" : "archivebox"
                        ) {
                            setArchived(!isArchived)
                        }
                        Button(role: .destructive) {
                            confirmationRequest = .deleteEquipment(
                                customerID: target.customerID, propertyID: target.propertyID,
                                equipmentID: equipmentID, name: Properties.typeDisplayName(draft.type)
                            )
                        } label: {
                            Label("Delete equipment", systemImage: "trash").nativeDestructiveText()
                        }
                    } footer: {
                        Text("Removed or replaced equipment stays under Past equipment as history. Delete only an entry made by mistake.")
                    }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(target.equipmentID == nil ? "New Equipment" : "Edit Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                DismissableFormToolbar(title: "Equipment") { save() }
            }
            .nativeConfirmation($confirmationRequest) { intent in
                guard case let .deleteEquipment(customerID, propertyID, equipmentID) = intent else { return }
                if store.deleteEquipment(customerID: customerID, propertyID: propertyID, equipmentID: equipmentID) {
                    dismiss()
                } else {
                    errorMessage = Properties.PropertyError.notSaved.message
                }
            }
            .alert("Equipment not saved", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Type picker

    /// Custom types already used on any customer, offered again.
    private var customTypes: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for customer in store.canonicalCustomers {
            for property in customer.properties ?? [] {
                for item in property.equipment ?? [] {
                    guard let type = Properties.normalizeType(item.type), !Properties.isPresetType(type),
                          seen.insert(type.lowercased()).inserted
                    else { continue }
                    labels.append(type)
                }
            }
        }
        return labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var typeSelection: String {
        if isEnteringOtherType { return Self.otherTag }
        let value = Properties.normalizeType(draft.type) ?? Properties.otherTypeKey
        if value == Properties.otherTypeKey { return Self.otherTag }
        if Properties.isPresetType(value) { return value }
        return customTypes.first { $0.caseInsensitiveCompare(value) == .orderedSame } ?? Self.otherTag
    }

    private var typePicker: some View {
        Picker("Type", selection: Binding<String>(
            get: { typeSelection },
            set: { tag in
                if tag == Self.otherTag {
                    if !isEnteringOtherType { draft.type = Properties.otherTypeKey }
                    isEnteringOtherType = true
                } else {
                    isEnteringOtherType = false
                    draft.type = tag
                }
            }
        )) {
            ForEach(Properties.equipmentTypes.filter { $0.key != Properties.otherTypeKey }, id: \.key) { type in
                Text(type.displayName).tag(type.key)
            }
            ForEach(customTypes, id: \.self) { label in
                Text(label).tag(label)
            }
            Text("Other…").tag(Self.otherTag)
        }
        .pickerStyle(.menu)
    }

    // MARK: Dates

    /// An optional local calendar date: a toggle, then a date-only picker.
    /// The stored value is `YYYY-MM-DD` in the local calendar (FA-039).
    @ViewBuilder
    private func dateRow(title: String, value: Binding<String?>) -> some View {
        Toggle(title, isOn: Binding(
            get: { value.wrappedValue != nil },
            set: { value.wrappedValue = $0 ? (value.wrappedValue ?? NativeCashBasis.ymd(.now)) : nil }
        ))
        if let current = value.wrappedValue {
            DatePicker(
                title,
                selection: Binding(
                    get: { NativeCashBasis.parseLocalDate(current) ?? .now },
                    set: { value.wrappedValue = NativeCashBasis.ymd($0) }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            .accessibilityLabel(title)
        }
    }

    // MARK: Actions

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let equipmentID = target.equipmentID,
              let property = store.customerProperty(customerID: target.customerID, propertyID: target.propertyID),
              let item = property.equipment.first(where: { $0.id == equipmentID })
        else { return }
        draft = .init(item)
        isArchived = Properties.isArchived(item.archivedAt)
        isEnteringOtherType = Properties.normalizeType(item.type) == Properties.otherTypeKey
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let failure: NativePropertiesEquipment.PropertyError?
        if let equipmentID = target.equipmentID {
            let result = store.updateEquipment(
                customerID: target.customerID, propertyID: target.propertyID, equipmentID: equipmentID, draft: draft
            )
            if case let .failure(error) = result { failure = error } else { failure = nil }
        } else {
            let result = store.addEquipment(customerID: target.customerID, propertyID: target.propertyID, draft: draft)
            if case let .failure(error) = result { failure = error } else { failure = nil }
        }
        if let failure { errorMessage = failure.message } else { dismiss() }
    }

    private func setArchived(_ archived: Bool) {
        guard let equipmentID = target.equipmentID, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let result = store.setEquipmentArchived(
            customerID: target.customerID, propertyID: target.propertyID, equipmentID: equipmentID, archived: archived
        )
        switch result {
        case .success: dismiss()
        case let .failure(error): errorMessage = error.message
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Job detail

/// The Schedule section's address row: the linked property's label (P3)
/// above the job's own address, which stays the address of record.
struct NativeJobAddressRow: View {
    @EnvironmentObject private var store: AppStore
    let job: Job

    var body: some View {
        if !job.address.isEmpty {
            let title = store.jobPropertyContext(jobID: job.id)?.linkedProperty?.title
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(.subheadline.weight(.semibold)) }
                    Text(job.address)
                }
            } icon: {
                Image(systemName: "mappin.and.ellipse")
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Job detail "Equipment at this property" (read-only, with "Add
/// equipment"), or "Add as a property" when the job's address is none of the
/// customer's properties (spec §3).
struct NativeJobPropertySection: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String
    @State private var equipmentTarget: NativeEquipmentEditorTarget?
    @State private var isAttaching = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let context = store.jobPropertyContext(jobID: jobID) {
                if let property = context.property {
                    Section("Equipment at this property") {
                        if property.activeEquipment.isEmpty {
                            Text("No equipment recorded").foregroundStyle(.secondary)
                        }
                        ForEach(property.activeEquipment, id: \.id) { item in
                            NativeEquipmentRow(item: item, status: store.warrantyStatus(item))
                        }
                        Button("Add equipment", systemImage: "plus.circle") {
                            equipmentTarget = .add(customerID: context.customer.id, propertyID: property.id)
                        }
                    }
                } else if context.canAddAsProperty {
                    Section {
                        Button {
                            attach()
                        } label: {
                            if isAttaching {
                                Label("Adding property…", systemImage: "hourglass")
                            } else {
                                Label("Add as a property", systemImage: "house.badge.plus")
                            }
                        }
                        .disabled(isAttaching)
                    } header: {
                        Text("Property")
                    } footer: {
                        Text("This address isn't one of \(context.customer.name)'s properties yet. Add it to keep its equipment and job history together.")
                    }
                }
            }
        }
        .sheet(item: $equipmentTarget) { NativeEquipmentEditor(target: $0) }
        .alert("Couldn’t add the property", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func attach() {
        guard !isAttaching else { return }
        isAttaching = true
        defer { isAttaching = false }
        if case let .failure(error) = store.addJobAddressAsProperty(jobID: jobID) {
            errorMessage = error.message
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Job editor

/// The job editor's "Property" picker, shown once the chosen customer has
/// more than one active property. Picking one sets `propertyId` and fills
/// the address only when it is empty or still the previous pick's address.
struct NativeJobPropertyPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var job: Job

    var body: some View {
        if store.showsPropertyPicker(customerID: job.customerId) {
            let options = store.propertyPickerOptions(customerID: job.customerId)
            Picker("Property", selection: Binding<String>(
                get: { job.propertyId ?? "" },
                set: { picked in
                    let next = Properties.pick(
                        picked.isEmpty ? nil : picked, currentPropertyID: job.propertyId,
                        currentAddress: job.address, options: options
                    )
                    // An archived link stays selectable as itself.
                    if next.propertyID == nil, picked == job.propertyId { return }
                    job.propertyId = next.propertyID
                    job.address = next.address
                }
            )) {
                Text("Not set").tag("")
                ForEach(options) { option in
                    Text(option.isPrimary ? option.title : "\(option.title) · \(option.address)").tag(option.id)
                }
                if let current = job.propertyId, !current.isEmpty, !options.contains(where: { $0.id == current }) {
                    // P3: a link that no longer resolves stays as it is until the owner picks again.
                    let archived = store.customerProperty(customerID: job.customerId, propertyID: current)?.isArchived == true
                    Text(archived ? "Archived property" : "Removed property").tag(current)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
