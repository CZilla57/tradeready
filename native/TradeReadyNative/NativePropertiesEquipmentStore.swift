import Foundation

/// Phase 21 (multi-property and equipment history): the `AppStore` API the
/// customer-detail "Properties" section, the property and equipment screens,
/// the job editor's property picker and the job-detail equipment section
/// build on. Spec: `docs/superpowers/specs/2026-10-02-properties-equipment-design.md`.
///
/// Every write re-reads the stored customer by id, applies one pure
/// `NativePropertiesEquipment` operation (which materializes the implicit
/// primary on the first property or equipment action) and commits the whole
/// customer, plus any job it links, through `commitPropertyChange` (durable
/// save, publish, then one mutation-queue batch). Nothing changes on refusal.
/// Deleting a property or an equipment entry goes through the shared
/// deletion undo (`deleteProperty`/`deleteEquipment` in AppStore.swift).
extension AppStore {
    /// What the job screens need about where a job is.
    struct JobPropertyContext {
        let customer: Canonical.Customer
        /// The linked property (P3) or, for an unlinked job at the customer's
        /// address, the primary.
        let property: NativePropertiesEquipment.ResolvedProperty?
        /// The linked property only (what the address row labels).
        let linkedProperty: NativePropertiesEquipment.ResolvedProperty?
        /// Spec §3 "Add as a property" is offered.
        let canAddAsProperty: Bool
    }

    // MARK: - Reads

    func canonicalCustomer(id: String) -> Canonical.Customer? {
        canonicalCustomers.first { $0.id == id }
    }

    /// The customer's properties, primary first (an implicit primary when
    /// nothing is stored yet); archived ones included, after the others.
    func customerProperties(customerID: String) -> [NativePropertiesEquipment.ResolvedProperty] {
        guard let customer = canonicalCustomer(id: customerID) else { return [] }
        let all = NativePropertiesEquipment.properties(of: customer)
        return all.filter { !$0.isArchived } + all.filter(\.isArchived)
    }

    func customerProperty(customerID: String, propertyID: String) -> NativePropertiesEquipment.ResolvedProperty? {
        guard let customer = canonicalCustomer(id: customerID) else { return nil }
        return NativePropertiesEquipment.property(propertyID, of: customer)
    }

    /// Spec §3: the property's job history, newest first, as screen models.
    func propertyJobHistory(customerID: String, propertyID: String) -> [Job] {
        guard let customer = canonicalCustomer(id: customerID) else { return [] }
        let ids = NativePropertiesEquipment.jobHistory(propertyID: propertyID, customer: customer, jobs: canonicalJobs)
            .map(\.id)
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func jobPropertyContext(jobID: String) -> JobPropertyContext? {
        guard let job = canonicalJobs.first(where: { $0.id == jobID }) else { return nil }
        let customer = canonicalCustomer(id: job.customerId) ?? canonicalCustomers.first {
            NativePropertiesEquipment.job(job, belongsTo: $0)
        }
        guard let customer else { return nil }
        return JobPropertyContext(
            customer: customer,
            property: NativePropertiesEquipment.property(atJob: job, customer: customer),
            linkedProperty: NativePropertiesEquipment.resolvedProperty(for: job, customer: customer),
            canAddAsProperty: NativePropertiesEquipment.canAddJobAddressAsProperty(job, customer: customer)
        )
    }

    /// Spec §3: equipment serial and model text per customer, for search.
    var customerEquipmentSearchIndex: [String: [String]] {
        NativePropertiesEquipment.equipmentSearchIndex(customers: canonicalCustomers)
    }

    /// Today in the local calendar (FA-039).
    func warrantyStatus(_ item: Canonical.Equipment, now: Date = .now) -> NativePropertiesEquipment.WarrantyStatus? {
        NativePropertiesEquipment.warrantyStatus(item, today: NativeCashBasis.ymd(now))
    }

    func showsPropertyPicker(customerID: String) -> Bool {
        NativePropertiesEquipment.showsPropertyPicker(customer: canonicalCustomer(id: customerID))
    }

    func propertyPickerOptions(customerID: String) -> [NativePropertiesEquipment.PickerOption] {
        guard let customer = canonicalCustomer(id: customerID) else { return [] }
        return NativePropertiesEquipment.pickerOptions(customer: customer)
    }

    // MARK: - Properties

    /// "Add property". Returns the new property's id.
    @discardableResult
    func addProperty(
        customerID: String,
        draft: NativePropertiesEquipment.PropertyDraft,
        on date: Date = .now
    ) -> Result<String, NativePropertiesEquipment.PropertyError> {
        guard let customer = canonicalCustomer(id: customerID) else { return .failure(.customerNotFound) }
        let used = NativePropertiesEquipment.allIDs(in: customer)
        let propertyID = NativePropertiesEquipment.makeUniqueID(prefix: "pr", now: date, existingIDs: used)
        let primaryID = NativePropertiesEquipment.makeUniqueID(prefix: "pr", now: date, existingIDs: used.union([propertyID]))
        do {
            let added = try NativePropertiesEquipment.addProperty(
                to: customer, draft: draft, propertyID: propertyID, primaryID: primaryID
            )
            return commitPropertyChange(customer: added.customer).map { _ in added.propertyID }
        } catch {
            return .failure(Self.propertyError(error))
        }
    }

    /// Saves label, address and notes (label and notes only for the primary).
    @discardableResult
    func updateProperty(
        customerID: String,
        propertyID: String,
        draft: NativePropertiesEquipment.PropertyDraft
    ) -> Result<Canonical.Customer, NativePropertiesEquipment.PropertyError> {
        mutateCustomerProperties(customerID: customerID) { customer, primaryID in
            try NativePropertiesEquipment.updateProperty(
                in: customer, propertyID: propertyID, draft: draft, primaryID: primaryID
            )
        }
    }

    @discardableResult
    func setPropertyArchived(
        customerID: String,
        propertyID: String,
        archived: Bool,
        on date: Date = .now
    ) -> Result<Canonical.Customer, NativePropertiesEquipment.PropertyError> {
        mutateCustomerProperties(customerID: customerID) { customer, primaryID in
            try NativePropertiesEquipment.setPropertyArchived(
                in: customer, propertyID: propertyID, archived: archived, at: date.dateOnlyString, primaryID: primaryID
            )
        }
    }

    // MARK: - Equipment

    /// "Add equipment". Returns the property id it landed on (the primary's
    /// stored id when the target was the implicit primary) and the item id.
    @discardableResult
    func addEquipment(
        customerID: String,
        propertyID: String,
        draft: NativePropertiesEquipment.EquipmentDraft,
        on date: Date = .now
    ) -> Result<(propertyID: String, equipmentID: String), NativePropertiesEquipment.PropertyError> {
        guard let customer = canonicalCustomer(id: customerID) else { return .failure(.customerNotFound) }
        let used = NativePropertiesEquipment.allIDs(in: customer)
        let equipmentID = NativePropertiesEquipment.makeUniqueID(prefix: "eq", now: date, existingIDs: used)
        let primaryID = NativePropertiesEquipment.makeUniqueID(prefix: "pr", now: date, existingIDs: used.union([equipmentID]))
        do {
            let added = try NativePropertiesEquipment.addEquipment(
                to: customer, propertyID: propertyID, draft: draft, equipmentID: equipmentID, primaryID: primaryID
            )
            return commitPropertyChange(customer: added.customer).map { _ in (added.propertyID, added.equipmentID) }
        } catch {
            return .failure(Self.propertyError(error))
        }
    }

    @discardableResult
    func updateEquipment(
        customerID: String,
        propertyID: String,
        equipmentID: String,
        draft: NativePropertiesEquipment.EquipmentDraft
    ) -> Result<Canonical.Customer, NativePropertiesEquipment.PropertyError> {
        mutateCustomerProperties(customerID: customerID) { customer, primaryID in
            try NativePropertiesEquipment.updateEquipment(
                in: customer, propertyID: propertyID, equipmentID: equipmentID, draft: draft, primaryID: primaryID
            )
        }
    }

    /// "Mark as removed" (`archived: true`) or restore.
    @discardableResult
    func setEquipmentArchived(
        customerID: String,
        propertyID: String,
        equipmentID: String,
        archived: Bool,
        on date: Date = .now
    ) -> Result<Canonical.Customer, NativePropertiesEquipment.PropertyError> {
        mutateCustomerProperties(customerID: customerID) { customer, primaryID in
            try NativePropertiesEquipment.setEquipmentArchived(
                in: customer, propertyID: propertyID, equipmentID: equipmentID, archived: archived,
                at: date.dateOnlyString, primaryID: primaryID
            )
        }
    }

    // MARK: - Jobs

    /// Spec §3 "Add as a property": creates a property at the job's address
    /// and links the job, in one commit. Returns the new property's id.
    @discardableResult
    func addJobAddressAsProperty(
        jobID: String,
        label: String = "",
        on date: Date = .now
    ) -> Result<String, NativePropertiesEquipment.PropertyError> {
        guard let job = canonicalJobs.first(where: { $0.id == jobID }) else { return .failure(.jobNotFound) }
        guard let context = jobPropertyContext(jobID: jobID) else { return .failure(.customerNotFound) }
        let used = NativePropertiesEquipment.allIDs(in: context.customer)
        let propertyID = NativePropertiesEquipment.makeUniqueID(prefix: "pr", now: date, existingIDs: used)
        let primaryID = NativePropertiesEquipment.makeUniqueID(prefix: "pr", now: date, existingIDs: used.union([propertyID]))
        do {
            let result = try NativePropertiesEquipment.addJobAddressAsProperty(
                job: job, customer: context.customer, label: label, propertyID: propertyID, primaryID: primaryID
            )
            return commitPropertyChange(customer: result.customer, jobs: [result.job]).map { _ in propertyID }
        } catch {
            return .failure(Self.propertyError(error))
        }
    }

    // MARK: - Private

    /// Re-reads the customer, applies one pure operation, and commits it when
    /// anything changed (an unchanged customer writes nothing).
    private func mutateCustomerProperties(
        customerID: String,
        _ change: (Canonical.Customer, String) throws -> Canonical.Customer
    ) -> Result<Canonical.Customer, NativePropertiesEquipment.PropertyError> {
        guard let customer = canonicalCustomer(id: customerID) else { return .failure(.customerNotFound) }
        do {
            let next = try change(customer, newPrimaryPropertyID(customerID: customerID))
            if Self.sameWire(next, customer) { return .success(customer) }
            return commitPropertyChange(customer: next)
        } catch {
            return .failure(Self.propertyError(error))
        }
    }

    private static func sameWire(_ lhs: Canonical.Customer, _ rhs: Canonical.Customer) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    private static func propertyError(_ error: Error) -> NativePropertiesEquipment.PropertyError {
        (error as? NativePropertiesEquipment.PropertyError) ?? .notSaved
    }
}
