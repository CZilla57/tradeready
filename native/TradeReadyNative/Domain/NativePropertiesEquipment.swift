import Foundation

/// Phase 21 (multi-property and equipment history): the pure rules behind a
/// customer's properties and their equipment. Spec:
/// `docs/superpowers/specs/2026-10-02-properties-equipment-design.md`.
///
/// Properties live nested in the customer blob (`Canonical.Customer.properties`,
/// D1). Absent means one implicit primary property with no equipment. The
/// primary's address is always the customer's (D2): it is never stored. Jobs
/// link with `Canonical.Job.propertyId` and keep their own address (D3).
///
/// Foundation and the canonical models only. Every operation takes a record
/// and returns a new one (or throws a `PropertyError`); nothing here touches
/// persistence. Dates are `YYYY-MM-DD` local calendar strings and all day
/// math on them is civil-day arithmetic on the components, never a `Date`
/// parse of a bare date (FA-039). Callers pass today as
/// `NativeCashBasis.ymd(now)`.
enum NativePropertiesEquipment {
    // MARK: - Caps (spec §2)

    static let labelMaxLength = 40
    static let addressMaxLength = 300
    static let propertyNotesMaxLength = 1000
    static let equipmentMaxCount = 50
    /// Not in the spec (build record §8): bounds the customer blob.
    static let propertyMaxCount = 100
    static let typeMaxLength = 40
    static let detailMaxLength = 80
    static let equipmentNotesMaxLength = 500
    /// D4: the warranty insight looks 30 local days ahead, today included.
    static let warrantyWindowDays = 30

    /// The navigation id of a customer's primary before it is materialized
    /// (no stored `properties`). Generated ids are `pr<ms>_<base36>`, so it
    /// never names a stored property.
    static let implicitPrimaryID = "primary"

    // MARK: - Errors

    enum PropertyError: Error, Equatable {
        case customerNotFound
        case propertyNotFound
        case equipmentNotFound
        case jobNotFound
        /// A non-primary property needs an address (1..300).
        case addressRequired
        case addressTooLong
        case labelTooLong
        case notesTooLong
        /// An active property (or the customer's own address) already has it.
        case duplicateAddress
        case tooManyProperties
        case tooManyEquipment
        case typeRequired
        case typeTooLong
        case makeTooLong
        case modelTooLong
        case serialTooLong
        case equipmentNotesTooLong
        case invalidInstallDate
        case invalidWarrantyDate
        /// The primary is the customer's own address: it can't be archived,
        /// removed or given a stored address.
        case primaryLocked
        /// P1: no property flagged primary.
        case noPrimary
        /// P1: more than one property flagged primary.
        case multiplePrimaries
        /// P2: a property or equipment id is empty or repeated.
        case duplicateID(String)
        case invalidID
        /// The job already resolves to one of the customer's properties, has
        /// no address, or its address is already one of them.
        case jobNotAttachable
        /// This device could not save; `AppStore.migrationMessage` says why.
        case notSaved

        /// Owner-facing alert text.
        var message: String {
            switch self {
            case .customerNotFound: "This customer is no longer on this device."
            case .propertyNotFound: "This property is no longer on this device."
            case .equipmentNotFound: "This equipment is no longer on this device."
            case .jobNotFound: "This job is no longer on this device."
            case .addressRequired: "Enter the property's address."
            case .addressTooLong: "Keep the address under \(NativePropertiesEquipment.addressMaxLength) characters."
            case .labelTooLong: "Keep the name under \(NativePropertiesEquipment.labelMaxLength) characters."
            case .notesTooLong: "Keep property notes under \(NativePropertiesEquipment.propertyNotesMaxLength) characters."
            case .duplicateAddress: "This customer already has a property at that address."
            case .tooManyProperties: "A customer can have up to \(NativePropertiesEquipment.propertyMaxCount) properties."
            case .tooManyEquipment: "A property can hold up to \(NativePropertiesEquipment.equipmentMaxCount) pieces of equipment, removed ones included."
            case .typeRequired: "Choose the equipment type."
            case .typeTooLong: "Keep the equipment type under \(NativePropertiesEquipment.typeMaxLength) characters."
            case .makeTooLong: "Keep the make under \(NativePropertiesEquipment.detailMaxLength) characters."
            case .modelTooLong: "Keep the model under \(NativePropertiesEquipment.detailMaxLength) characters."
            case .serialTooLong: "Keep the serial number under \(NativePropertiesEquipment.detailMaxLength) characters."
            case .equipmentNotesTooLong: "Keep equipment notes under \(NativePropertiesEquipment.equipmentNotesMaxLength) characters."
            case .invalidInstallDate: "The install date isn't a valid date."
            case .invalidWarrantyDate: "The warranty date isn't a valid date."
            case .primaryLocked: "The primary property is the customer's own address. Edit the customer to change it."
            case .noPrimary, .multiplePrimaries, .duplicateID, .invalidID:
                "This customer's properties couldn't be read safely. Nothing was changed."
            case .jobNotAttachable: "This job's address is already one of the customer's properties."
            case .notSaved: "The change couldn't be saved. Nothing was changed."
            }
        }
    }

    // MARK: - Equipment types (spec §2)

    struct EquipmentType: Equatable {
        /// Stored on the wire; never renamed.
        let key: String
        let displayName: String
        /// Mid-sentence form ("Dana's water heater warranty ends …").
        let sentenceName: String
        /// Lowercased spellings that normalize to `key`.
        let aliases: [String]
    }

    static let otherTypeKey = "other"

    /// Presets in picker order. `other` is chosen through "Other…" with no
    /// custom text (the picker does not list it twice).
    static let equipmentTypes: [EquipmentType] = [
        .init(key: "furnace", displayName: "Furnace", sentenceName: "furnace",
              aliases: ["gas furnace", "electric furnace", "oil furnace"]),
        .init(key: "ac_condenser", displayName: "AC condenser", sentenceName: "AC condenser",
              aliases: ["ac", "a/c", "air conditioner", "condenser", "ac unit", "central air", "outdoor unit"]),
        .init(key: "heat_pump", displayName: "Heat pump", sentenceName: "heat pump", aliases: ["heatpump"]),
        .init(key: "air_handler", displayName: "Air handler", sentenceName: "air handler",
              aliases: ["ahu", "blower", "air handling unit"]),
        .init(key: "mini_split", displayName: "Mini-split", sentenceName: "mini-split",
              aliases: ["mini split", "minisplit", "ductless", "ductless mini split", "ductless mini-split"]),
        .init(key: "boiler", displayName: "Boiler", sentenceName: "boiler", aliases: []),
        .init(key: "water_heater", displayName: "Water heater", sentenceName: "water heater",
              aliases: ["hot water heater", "water tank", "tank water heater", "hot water tank"]),
        .init(key: "tankless_water_heater", displayName: "Tankless water heater", sentenceName: "tankless water heater",
              aliases: ["tankless", "tankless heater", "on-demand water heater", "on demand water heater"]),
        .init(key: "water_softener", displayName: "Water softener", sentenceName: "water softener", aliases: ["softener"]),
        .init(key: "sump_pump", displayName: "Sump pump", sentenceName: "sump pump", aliases: ["sump"]),
        .init(key: "electrical_panel", displayName: "Electrical panel", sentenceName: "electrical panel",
              aliases: ["panel", "breaker panel", "breaker box", "service panel", "electric panel", "fuse box"]),
        .init(key: "generator", displayName: "Generator", sentenceName: "generator",
              aliases: ["standby generator", "backup generator"]),
        .init(key: "ev_charger", displayName: "EV charger", sentenceName: "EV charger",
              aliases: ["ev", "evse", "car charger", "level 2 charger", "electric vehicle charger"]),
        .init(key: "thermostat", displayName: "Thermostat", sentenceName: "thermostat",
              aliases: ["smart thermostat", "tstat"]),
        .init(key: otherTypeKey, displayName: "Other", sentenceName: "equipment", aliases: []),
    ]

    static func equipmentType(key: String) -> EquipmentType? {
        equipmentTypes.first { $0.key == key }
    }

    /// Trims and collapses whitespace and strips control characters; blank is
    /// `nil`. A preset key, display name or alias (any case) becomes the key;
    /// anything else is a custom label, kept verbatim. Over-long labels are
    /// not cut here: `validate` refuses them so the owner sees why.
    static func normalizeType(_ raw: String?) -> String? {
        guard let cleaned = singleLine(raw) else { return nil }
        let lowered = cleaned.lowercased()
        if let match = equipmentTypes.first(where: {
            $0.key == lowered || $0.displayName.lowercased() == lowered || $0.aliases.contains(lowered)
        }) {
            return match.key
        }
        return cleaned
    }

    static func isPresetType(_ stored: String) -> Bool {
        equipmentType(key: stored) != nil
    }

    /// The preset's display name, or a custom label verbatim.
    static func typeDisplayName(_ stored: String) -> String {
        let value = normalizeType(stored) ?? otherTypeKey
        return equipmentType(key: value)?.displayName ?? value
    }

    /// The mid-sentence name: a preset's lowercase form, or a custom label
    /// verbatim.
    static func typeSentenceName(_ stored: String) -> String {
        let value = normalizeType(stored) ?? otherTypeKey
        return equipmentType(key: value)?.sentenceName ?? value
    }

    // MARK: - Ids (P2)

    static func makePropertyID(now: Date = Date(), randomValue: UInt64? = nil) -> String {
        makeID(prefix: "pr", now: now, randomValue: randomValue)
    }

    static func makeEquipmentID(now: Date = Date(), randomValue: UInt64? = nil) -> String {
        makeID(prefix: "eq", now: now, randomValue: randomValue)
    }

    /// `<prefix><ms>_<base36 random>`, retried (bounded) until it is not in
    /// `existingIDs`. Ids are random so two customers' ids never collide when
    /// they merge.
    static func makeUniqueID(
        prefix: String,
        now: Date = Date(),
        existingIDs: Set<String>,
        randomValue: UInt64? = nil
    ) -> String {
        var id = makeID(prefix: prefix, now: now, randomValue: randomValue)
        var attempts = 0
        while existingIDs.contains(id) || id == implicitPrimaryID, attempts < 16 {
            attempts += 1
            id = makeID(prefix: prefix, now: now, randomValue: nil)
        }
        return id
    }

    /// Every property and equipment id stored on the customer.
    static func allIDs(in customer: Canonical.Customer) -> Set<String> {
        var ids = Set<String>()
        for property in customer.properties ?? [] {
            ids.insert(property.id)
            for item in property.equipment ?? [] { ids.insert(item.id) }
        }
        return ids
    }

    private static func makeID(prefix: String, now: Date, randomValue: UInt64?) -> String {
        let millis = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
        let random = randomValue ?? UInt64.random(in: 0 ... UInt64.max)
        return "\(prefix)\(millis)_\(String(random, radix: 36, uppercase: false))"
    }

    // MARK: - Read model

    /// A property as the screens see it, with the primary's address resolved
    /// from the customer (D2).
    struct ResolvedProperty: Equatable, Identifiable {
        /// The stored id, or `implicitPrimaryID` before materialization.
        let id: String
        let isPrimary: Bool
        /// The customer has no stored `properties` yet.
        let isImplicit: Bool
        let label: String?
        let address: String
        let notes: String?
        /// Stored order (archived items included).
        let equipment: [Canonical.Equipment]
        let isArchived: Bool

        var activeEquipment: [Canonical.Equipment] {
            equipment.filter { !NativePropertiesEquipment.isArchived($0.archivedAt) }
        }

        var archivedEquipment: [Canonical.Equipment] {
            equipment.filter { NativePropertiesEquipment.isArchived($0.archivedAt) }
        }

        /// What a job address row shows above the address: the label, or
        /// "Primary" for an unlabeled primary.
        var title: String? {
            if let label { return label }
            return isPrimary ? "Primary" : nil
        }

        /// A row heading: the label, else "Primary" or the address.
        var displayName: String {
            title ?? (address.isEmpty ? "Property" : address)
        }
    }

    /// The customer's properties: the primary first (implicit when nothing is
    /// stored), then the others in stored order. Tolerates blobs that break
    /// P1: with no stored primary an implicit one leads; with several, the
    /// first wins and the rest read as ordinary properties.
    static func properties(of customer: Canonical.Customer) -> [ResolvedProperty] {
        let stored = customer.properties ?? []
        let primaryIndex = stored.firstIndex { $0.primary == true }
        var result: [ResolvedProperty] = []
        if let primaryIndex {
            result.append(resolve(stored[primaryIndex], customer: customer, asPrimary: true, implicit: false))
        } else {
            result.append(ResolvedProperty(
                id: implicitPrimaryID, isPrimary: true, isImplicit: stored.isEmpty, label: nil,
                address: customer.address, notes: nil, equipment: [], isArchived: false
            ))
        }
        for (index, property) in stored.enumerated() where index != primaryIndex {
            result.append(resolve(property, customer: customer, asPrimary: false, implicit: false))
        }
        return result
    }

    /// Active properties only (the primary is never archived).
    static func activeProperties(of customer: Canonical.Customer) -> [ResolvedProperty] {
        properties(of: customer).filter { !$0.isArchived }
    }

    static func property(_ id: String, of customer: Canonical.Customer) -> ResolvedProperty? {
        let all = properties(of: customer)
        if id == implicitPrimaryID { return all.first { $0.isPrimary } }
        return all.first { $0.id == id }
    }

    static func primary(of customer: Canonical.Customer) -> ResolvedProperty {
        // `properties(of:)` always leads with a primary.
        properties(of: customer).first ?? ResolvedProperty(
            id: implicitPrimaryID, isPrimary: true, isImplicit: true, label: nil,
            address: customer.address, notes: nil, equipment: [], isArchived: false
        )
    }

    private static func resolve(
        _ property: Canonical.Property,
        customer: Canonical.Customer,
        asPrimary: Bool,
        implicit: Bool
    ) -> ResolvedProperty {
        ResolvedProperty(
            id: property.id,
            isPrimary: asPrimary,
            isImplicit: implicit,
            label: singleLine(property.label),
            address: asPrimary ? customer.address : (property.address ?? customer.address),
            notes: trimmedText(property.notes),
            equipment: property.equipment ?? [],
            isArchived: !asPrimary && isArchived(property.archivedAt)
        )
    }

    // MARK: - Materialization and validation (P1, P2, caps)

    /// The stored list with P1 repaired: an absent or primary-less list gets
    /// a new primary (`newPrimaryID`) in front; extra primaries become
    /// ordinary properties at their own address (or the customer's); the
    /// primary loses any stored address or archive stamp; `primary: false`
    /// becomes absent. The first property or equipment action calls this.
    static func materialize(_ customer: Canonical.Customer, newPrimaryID: String) -> [Canonical.Property] {
        var stored = customer.properties ?? []
        var primaryFound = false
        for index in stored.indices {
            if stored[index].primary == true {
                if primaryFound {
                    stored[index].primary = nil
                    if trimmedText(stored[index].address) == nil {
                        stored[index].address = customer.address
                    }
                } else {
                    primaryFound = true
                    stored[index].address = nil
                    stored[index].archivedAt = nil
                }
            } else if stored[index].primary != nil {
                stored[index].primary = nil
            }
        }
        if !primaryFound {
            stored.insert(Canonical.Property(id: newPrimaryID, primary: true), at: 0)
        } else if let index = stored.firstIndex(where: { $0.primary == true }), index != 0 {
            let primary = stored.remove(at: index)
            stored.insert(primary, at: 0)
        }
        return stored
    }

    /// Spec §2 invariants and caps. `nil` (absent) is always valid.
    static func validate(_ properties: [Canonical.Property]?) throws {
        guard let properties else { return }
        let primaries = properties.filter { $0.primary == true }
        if primaries.isEmpty { throw PropertyError.noPrimary }
        if primaries.count > 1 { throw PropertyError.multiplePrimaries }
        if properties.count > propertyMaxCount { throw PropertyError.tooManyProperties }
        var seen = Set<String>()
        for property in properties {
            try checkID(property.id, seen: &seen)
            if property.primary == true {
                if property.address != nil || property.archivedAt != nil { throw PropertyError.primaryLocked }
            } else {
                guard let address = trimmedText(property.address) else { throw PropertyError.addressRequired }
                if address.count > addressMaxLength { throw PropertyError.addressTooLong }
            }
            if (property.label ?? "").count > labelMaxLength { throw PropertyError.labelTooLong }
            if (property.notes ?? "").count > propertyNotesMaxLength { throw PropertyError.notesTooLong }
            let equipment = property.equipment ?? []
            if equipment.count > equipmentMaxCount { throw PropertyError.tooManyEquipment }
            for item in equipment {
                try checkID(item.id, seen: &seen)
                try validate(item)
            }
        }
    }

    static func validate(_ item: Canonical.Equipment) throws {
        guard let type = singleLine(item.type) else { throw PropertyError.typeRequired }
        if type.count > typeMaxLength { throw PropertyError.typeTooLong }
        if (item.make ?? "").count > detailMaxLength { throw PropertyError.makeTooLong }
        if (item.model ?? "").count > detailMaxLength { throw PropertyError.modelTooLong }
        if (item.serial ?? "").count > detailMaxLength { throw PropertyError.serialTooLong }
        if (item.notes ?? "").count > equipmentNotesMaxLength { throw PropertyError.equipmentNotesTooLong }
        if let date = item.installDate, !isValidLocalDate(date) { throw PropertyError.invalidInstallDate }
        if let date = item.warrantyExpires, !isValidLocalDate(date) { throw PropertyError.invalidWarrantyDate }
    }

    private static func checkID(_ id: String, seen: inout Set<String>) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id != implicitPrimaryID
        else { throw PropertyError.invalidID }
        guard seen.insert(id).inserted else { throw PropertyError.duplicateID(id) }
    }

    // MARK: - Property edits

    /// What the property editor submits. Blank fields are absent.
    struct PropertyDraft: Equatable {
        var label: String = ""
        var address: String = ""
        var notes: String = ""

        init(label: String = "", address: String = "", notes: String = "") {
            self.label = label
            self.address = address
            self.notes = notes
        }

        init(_ property: ResolvedProperty) {
            label = property.label ?? ""
            address = property.isPrimary ? "" : property.address
            notes = property.notes ?? ""
        }
    }

    /// Adds a non-primary property (materializing the primary first).
    /// Returns the customer and the new property's id.
    static func addProperty(
        to customer: Canonical.Customer,
        draft: PropertyDraft,
        propertyID: String,
        primaryID: String
    ) throws -> (customer: Canonical.Customer, propertyID: String) {
        guard let address = trimmedText(draft.address) else { throw PropertyError.addressRequired }
        if address.count > addressMaxLength { throw PropertyError.addressTooLong }
        if activeAddressKeys(of: customer).contains(normalizedAddress(address)) { throw PropertyError.duplicateAddress }
        var next = customer
        var list = materialize(customer, newPrimaryID: primaryID)
        guard !list.contains(where: { $0.id == propertyID }), propertyID != implicitPrimaryID
        else { throw PropertyError.duplicateID(propertyID) }
        list.append(Canonical.Property(
            id: propertyID,
            label: singleLine(draft.label),
            address: address,
            notes: trimmedText(draft.notes)
        ))
        next.properties = list
        try validate(next.properties)
        return (next, propertyID)
    }

    /// Saves label, address and notes. The primary takes label and notes
    /// only: its address is the customer's.
    static func updateProperty(
        in customer: Canonical.Customer,
        propertyID: String,
        draft: PropertyDraft,
        primaryID: String
    ) throws -> Canonical.Customer {
        var (next, index) = try locate(propertyID, in: customer, primaryID: primaryID)
        guard var list = next.properties else { throw PropertyError.propertyNotFound }
        list[index].label = singleLine(draft.label)
        list[index].notes = trimmedText(draft.notes)
        if list[index].primary != true {
            guard let address = trimmedText(draft.address) else { throw PropertyError.addressRequired }
            if address.count > addressMaxLength { throw PropertyError.addressTooLong }
            let key = normalizedAddress(address)
            if key != normalizedAddress(list[index].address ?? ""),
               activeAddressKeys(of: customer, excluding: list[index].id).contains(key) {
                throw PropertyError.duplicateAddress
            }
            list[index].address = address
        }
        next.properties = list
        try validate(next.properties)
        return next
    }

    /// Archives (or restores) a non-primary property. Its jobs keep their
    /// `propertyId` and show their own address only while it is archived
    /// (P3). Restoring refuses an address an active property already has.
    static func setPropertyArchived(
        in customer: Canonical.Customer,
        propertyID: String,
        archived: Bool,
        at timestamp: String,
        primaryID: String
    ) throws -> Canonical.Customer {
        guard propertyID != implicitPrimaryID, customer.properties?.contains(where: { $0.id == propertyID }) == true
        else { throw PropertyError.propertyNotFound }
        var (next, index) = try locate(propertyID, in: customer, primaryID: primaryID)
        guard var list = next.properties else { throw PropertyError.propertyNotFound }
        guard list[index].primary != true else { throw PropertyError.primaryLocked }
        if archived {
            guard !isArchived(list[index].archivedAt) else { return customer }
            list[index].archivedAt = timestamp
        } else {
            guard isArchived(list[index].archivedAt) else { return customer }
            if activeAddressKeys(of: customer, excluding: propertyID)
                .contains(normalizedAddress(list[index].address ?? "")) {
                throw PropertyError.duplicateAddress
            }
            list[index].archivedAt = nil
        }
        next.properties = list
        try validate(next.properties)
        return next
    }

    /// Removes a non-primary property (the delete action with undo). Its
    /// jobs keep their `propertyId`, which no longer resolves (P3).
    static func removeProperty(
        from customer: Canonical.Customer,
        propertyID: String,
        primaryID: String
    ) throws -> (customer: Canonical.Customer, removed: Canonical.Property, index: Int) {
        guard propertyID != implicitPrimaryID, customer.properties?.contains(where: { $0.id == propertyID }) == true
        else { throw PropertyError.propertyNotFound }
        var (next, index) = try locate(propertyID, in: customer, primaryID: primaryID)
        guard var list = next.properties else { throw PropertyError.propertyNotFound }
        guard list[index].primary != true else { throw PropertyError.primaryLocked }
        let removed = list.remove(at: index)
        next.properties = list
        try validate(next.properties)
        return (next, removed, index)
    }

    // MARK: - Equipment edits

    /// What the equipment editor submits. Blank text fields are absent.
    struct EquipmentDraft: Equatable {
        var type: String = ""
        var make: String = ""
        var model: String = ""
        var serial: String = ""
        var installDate: String?
        var warrantyExpires: String?
        var notes: String = ""

        init(
            type: String = "",
            make: String = "",
            model: String = "",
            serial: String = "",
            installDate: String? = nil,
            warrantyExpires: String? = nil,
            notes: String = ""
        ) {
            self.type = type
            self.make = make
            self.model = model
            self.serial = serial
            self.installDate = installDate
            self.warrantyExpires = warrantyExpires
            self.notes = notes
        }

        init(_ item: Canonical.Equipment) {
            type = item.type
            make = item.make ?? ""
            model = item.model ?? ""
            serial = item.serial ?? ""
            installDate = item.installDate
            warrantyExpires = item.warrantyExpires
            notes = item.notes ?? ""
        }
    }

    /// Adds equipment to a property (materializing the primary first when
    /// the target is the implicit primary). Returns the customer, the
    /// resolved property id and the new item's id.
    static func addEquipment(
        to customer: Canonical.Customer,
        propertyID: String,
        draft: EquipmentDraft,
        equipmentID: String,
        primaryID: String
    ) throws -> (customer: Canonical.Customer, propertyID: String, equipmentID: String) {
        var (next, index) = try locate(propertyID, in: customer, primaryID: primaryID)
        guard var list = next.properties else { throw PropertyError.propertyNotFound }
        guard !allIDs(in: next).contains(equipmentID), equipmentID != implicitPrimaryID
        else { throw PropertyError.duplicateID(equipmentID) }
        var items = list[index].equipment ?? []
        if items.count >= equipmentMaxCount { throw PropertyError.tooManyEquipment }
        var item = Canonical.Equipment(id: equipmentID, type: otherTypeKey)
        try apply(draft, to: &item)
        items.append(item)
        list[index].equipment = items
        next.properties = list
        try validate(next.properties)
        return (next, list[index].id, equipmentID)
    }

    /// Saves an item's fields as edited; its id, archive state and unknown
    /// fields are kept.
    static func updateEquipment(
        in customer: Canonical.Customer,
        propertyID: String,
        equipmentID: String,
        draft: EquipmentDraft,
        primaryID: String
    ) throws -> Canonical.Customer {
        try mutateEquipment(in: customer, propertyID: propertyID, equipmentID: equipmentID, primaryID: primaryID) { item in
            try apply(draft, to: &item)
        }
    }

    /// "Mark as removed" (or restore): archived equipment stays as history
    /// under "Past equipment".
    static func setEquipmentArchived(
        in customer: Canonical.Customer,
        propertyID: String,
        equipmentID: String,
        archived: Bool,
        at timestamp: String,
        primaryID: String
    ) throws -> Canonical.Customer {
        try mutateEquipment(in: customer, propertyID: propertyID, equipmentID: equipmentID, primaryID: primaryID) { item in
            if archived {
                if !isArchived(item.archivedAt) { item.archivedAt = timestamp }
            } else {
                item.archivedAt = nil
            }
        }
    }

    /// Removes an item outright (an entry made by mistake; the delete action
    /// with undo).
    static func removeEquipment(
        from customer: Canonical.Customer,
        propertyID: String,
        equipmentID: String,
        primaryID: String
    ) throws -> (customer: Canonical.Customer, removed: Canonical.Equipment, index: Int) {
        let (located, propertyIndex) = try locateEquipment(equipmentID, propertyID: propertyID, in: customer, primaryID: primaryID)
        var next = located
        guard var list = next.properties, var items = list[propertyIndex].equipment,
              let index = items.firstIndex(where: { $0.id == equipmentID })
        else { throw PropertyError.equipmentNotFound }
        let removed = items.remove(at: index)
        list[propertyIndex].equipment = items.isEmpty ? nil : items
        next.properties = list
        try validate(next.properties)
        return (next, removed, index)
    }

    private static func mutateEquipment(
        in customer: Canonical.Customer,
        propertyID: String,
        equipmentID: String,
        primaryID: String,
        _ change: (inout Canonical.Equipment) throws -> Void
    ) throws -> Canonical.Customer {
        let (located, propertyIndex) = try locateEquipment(equipmentID, propertyID: propertyID, in: customer, primaryID: primaryID)
        var next = located
        guard var list = next.properties, var items = list[propertyIndex].equipment,
              let index = items.firstIndex(where: { $0.id == equipmentID })
        else { throw PropertyError.equipmentNotFound }
        try change(&items[index])
        list[propertyIndex].equipment = items
        next.properties = list
        try validate(next.properties)
        return next
    }

    /// The customer materialized and the index of the property holding the
    /// item; `equipmentNotFound` when the item is not stored there.
    private static func locateEquipment(
        _ equipmentID: String,
        propertyID: String,
        in customer: Canonical.Customer,
        primaryID: String
    ) throws -> (Canonical.Customer, Int) {
        guard let stored = customer.properties, let storedPropertyIndex = storedIndex(of: propertyID, in: stored),
              stored[storedPropertyIndex].equipment?.contains(where: { $0.id == equipmentID }) == true
        else { throw PropertyError.equipmentNotFound }
        let target = stored[storedPropertyIndex].id
        let (next, index) = try locate(target, in: customer, primaryID: primaryID)
        return (next, index)
    }

    private static func apply(_ draft: EquipmentDraft, to item: inout Canonical.Equipment) throws {
        guard let type = normalizeType(draft.type) else { throw PropertyError.typeRequired }
        if type.count > typeMaxLength { throw PropertyError.typeTooLong }
        item.type = type
        item.make = singleLine(draft.make)
        item.model = singleLine(draft.model)
        item.serial = singleLine(draft.serial)
        item.installDate = trimmedText(draft.installDate)
        item.warrantyExpires = trimmedText(draft.warrantyExpires)
        item.notes = trimmedText(draft.notes)
        try validate(item)
    }

    /// The stored index of `propertyID`; the implicit id names the stored
    /// primary, if any.
    private static func storedIndex(of propertyID: String, in list: [Canonical.Property]) -> Int? {
        if propertyID == implicitPrimaryID { return list.firstIndex { $0.primary == true } }
        return list.firstIndex { $0.id == propertyID }
    }

    /// The customer with its list materialized, and the target's index.
    private static func locate(
        _ propertyID: String,
        in customer: Canonical.Customer,
        primaryID: String
    ) throws -> (Canonical.Customer, Int) {
        var next = customer
        next.properties = materialize(customer, newPrimaryID: primaryID)
        guard let list = next.properties, let index = storedIndex(of: propertyID, in: list)
        else { throw PropertyError.propertyNotFound }
        return (next, index)
    }

    // MARK: - Addresses

    /// Lowercased, punctuation `.,#` dropped, whitespace collapsed. Used for
    /// every "same address" decision (legacy job match, duplicate property,
    /// "Service address", merge).
    static func normalizedAddress(_ value: String) -> String {
        let dropped = value.lowercased().unicodeScalars.map { scalar -> Character in
            ".,#".unicodeScalars.contains(scalar) ? " " : Character(scalar)
        }
        return String(dropped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The normalized addresses of the customer's active properties (the
    /// primary's is the customer's). Blank addresses are left out.
    static func activeAddressKeys(of customer: Canonical.Customer, excluding propertyID: String? = nil) -> Set<String> {
        Set(activeProperties(of: customer)
            .filter { $0.id != propertyID }
            .map { normalizedAddress($0.address) }
            .filter { !$0.isEmpty })
    }

    /// Spec §3: the estimate review/PDF "Service address" line, shown when
    /// the job address is set and differs (normalized) from the customer's.
    static func serviceAddressLine(jobAddress: String, customerAddress: String) -> String? {
        let trimmed = jobAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return normalizedAddress(trimmed) == normalizedAddress(customerAddress) ? nil : trimmed
    }

    // MARK: - Jobs at a property

    /// The job belongs to the customer: same id, or (legacy RN rows) the same
    /// normalized name, matching the customer detail's Jobs section.
    static func job(_ job: Canonical.Job, belongsTo customer: Canonical.Customer) -> Bool {
        if !job.customerId.isEmpty, job.customerId == customer.id { return true }
        let name = customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !name.isEmpty && job.customerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
    }

    /// P3: the active property of the job's customer that `propertyId` names;
    /// `nil` when absent, archived, removed or on another customer. Never
    /// rewrites the job.
    static func resolvedProperty(for job: Canonical.Job, customer: Canonical.Customer?) -> ResolvedProperty? {
        guard let propertyID = job.propertyId, !propertyID.isEmpty, propertyID != implicitPrimaryID,
              let customer, self.job(job, belongsTo: customer),
              let property = properties(of: customer).first(where: { $0.id == propertyID }),
              !property.isArchived
        else { return nil }
        return property
    }

    /// Where the job is: its linked property (P3), else the primary when the
    /// job has no link and its address is the customer's (legacy match).
    static func property(atJob job: Canonical.Job, customer: Canonical.Customer?) -> ResolvedProperty? {
        if let linked = resolvedProperty(for: job, customer: customer) { return linked }
        guard let customer, self.job(job, belongsTo: customer), (job.propertyId ?? "").isEmpty else { return nil }
        let key = normalizedAddress(job.address)
        guard !key.isEmpty, key == normalizedAddress(customer.address) else { return nil }
        return primary(of: customer)
    }

    /// Spec §3 job history: the customer's non-archived jobs with that
    /// `propertyId`; for the primary, also jobs with no `propertyId` whose
    /// normalized address equals the customer's. Newest first by service
    /// date (scheduled date, else created date), then created time, then id.
    static func jobHistory(
        propertyID: String,
        customer: Canonical.Customer,
        jobs: [Canonical.Job]
    ) -> [Canonical.Job] {
        guard let target = property(propertyID, of: customer) else { return [] }
        let customerKey = normalizedAddress(customer.address)
        let matches = jobs.filter { job in
            guard !isArchived(job.archivedAt), self.job(job, belongsTo: customer) else { return false }
            if let linked = job.propertyId, !linked.isEmpty {
                return linked == target.id
            }
            return target.isPrimary && !customerKey.isEmpty && normalizedAddress(job.address) == customerKey
        }
        return matches.sorted { left, right in
            let l = serviceDate(left), r = serviceDate(right)
            if l != r { return l > r }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id < right.id
        }
    }

    /// `scheduledDate`, else the date part of `createdAt`.
    static func serviceDate(_ job: Canonical.Job) -> String {
        if let date = job.scheduledDate, !date.isEmpty { return String(date.prefix(10)) }
        return String(job.createdAt.prefix(10))
    }

    /// Spec §3 "Add as a property": offered when the job has a non-empty
    /// address, is linked to none of its customer's properties (no id, or
    /// one that names nothing on the customer), and its address matches no
    /// active property address.
    static func canAddJobAddressAsProperty(_ job: Canonical.Job, customer: Canonical.Customer) -> Bool {
        guard self.job(job, belongsTo: customer) else { return false }
        if let linked = job.propertyId, !linked.isEmpty,
           properties(of: customer).contains(where: { $0.id == linked }) {
            return false
        }
        let key = normalizedAddress(job.address)
        guard !key.isEmpty, job.address.trimmingCharacters(in: .whitespacesAndNewlines).count <= addressMaxLength
        else { return false }
        return !activeAddressKeys(of: customer).contains(key)
    }

    /// Creates a property at the job's address and links the job to it.
    static func addJobAddressAsProperty(
        job: Canonical.Job,
        customer: Canonical.Customer,
        label: String = "",
        propertyID: String,
        primaryID: String
    ) throws -> (customer: Canonical.Customer, job: Canonical.Job) {
        guard canAddJobAddressAsProperty(job, customer: customer) else { throw PropertyError.jobNotAttachable }
        let added = try addProperty(
            to: customer,
            draft: PropertyDraft(label: label, address: job.address),
            propertyID: propertyID,
            primaryID: primaryID
        )
        var linked = job
        linked.propertyId = added.propertyID
        return (added.customer, linked)
    }

    // MARK: - Job editor (spec §3)

    struct PickerOption: Equatable, Identifiable {
        let id: String
        let title: String
        let address: String
        let isPrimary: Bool
    }

    /// The "Property" picker appears once the job's customer has more than
    /// one active property.
    static func showsPropertyPicker(customer: Canonical.Customer?) -> Bool {
        guard let customer else { return false }
        return activeProperties(of: customer).count > 1
    }

    /// Active properties, primary first. Only materialized customers reach
    /// the picker, so every id is stored.
    static func pickerOptions(customer: Canonical.Customer) -> [PickerOption] {
        activeProperties(of: customer).filter { !$0.isImplicit && $0.id != implicitPrimaryID }.map { property in
            PickerOption(
                id: property.id,
                title: property.isPrimary ? "Primary" + (property.label.map { " · \($0)" } ?? "") : property.displayName,
                address: property.address,
                isPrimary: property.isPrimary
            )
        }
    }

    /// Picking a property fills the job address only when it is empty or
    /// still the previously picked property's address, so typed edits are
    /// never overwritten. Compared after trimming, case kept.
    static func addressAfterPicking(
        currentAddress: String,
        previousPropertyAddress: String?,
        pickedAddress: String
    ) -> String {
        let current = currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty { return pickedAddress }
        if let previous = previousPropertyAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !previous.isEmpty, previous == current {
            return pickedAddress
        }
        return currentAddress
    }

    /// The job editor's whole pick: the new `propertyId` and address.
    /// "Not set" (`nil` or an id that is not offered) clears the link and
    /// keeps the address. With nothing picked yet, the "previous" address is
    /// the primary's, so the address auto-filled from the customer still
    /// moves to the picked property.
    static func pick(
        _ pickedID: String?,
        currentPropertyID: String?,
        currentAddress: String,
        options: [PickerOption]
    ) -> (propertyID: String?, address: String) {
        guard let pickedID, let picked = options.first(where: { $0.id == pickedID }) else {
            return (nil, currentAddress)
        }
        let previous = options.first { $0.id == currentPropertyID }?.address
            ?? ((currentPropertyID ?? "").isEmpty ? options.first(where: \.isPrimary)?.address : nil)
        return (picked.id, addressAfterPicking(
            currentAddress: currentAddress, previousPropertyAddress: previous, pickedAddress: picked.address
        ))
    }

    // MARK: - Merge (spec §3)

    /// How a customer merge treats properties: the winner's list after the
    /// union, and how each re-pointed job's `propertyId` follows.
    struct MergePlan {
        /// The winner's new `properties` (`nil` keeps it absent).
        let properties: [Canonical.Property]?
        /// Old property id → the id it became (the loser's primary when its
        /// equipment merged into the winner's, or a re-id after a collision).
        let remap: [String: String]
        /// The property the loser's primary became, when it became a
        /// non-primary property: the loser's legacy-matched jobs (no
        /// `propertyId`, the loser's address) link to it.
        let legacyTargetID: String?
        let loserAddressKey: String

        /// The `propertyId` a re-pointed job (or recurring rule) carries
        /// after the merge. Ids are random, so linked jobs keep theirs.
        func propertyID(afterMerge propertyID: String?, address: String) -> String? {
            if let propertyID, !propertyID.isEmpty { return remap[propertyID] ?? propertyID }
            guard let legacyTargetID, !loserAddressKey.isEmpty,
                  NativePropertiesEquipment.normalizedAddress(address) == loserAddressKey
            else { return propertyID }
            return legacyTargetID
        }
    }

    /// The winner keeps its properties; the loser's are unioned in. The
    /// loser's primary becomes a non-primary property at the loser's address
    /// (keeping its id, label, notes and equipment), unless that address is
    /// blank or normalizes equal to the winner's (`winner` is the record
    /// after the contact backfill), in which case its equipment, and its
    /// label and notes where the winner's primary has none, merge into the
    /// winner's primary. Caps are not enforced: a merge never fails over
    /// them.
    static func mergePlan(
        winner: Canonical.Customer,
        loser: Canonical.Customer,
        makeID: () -> String
    ) -> MergePlan {
        let loserKey = normalizedAddress(loser.address)
        let sameAddress = loserKey.isEmpty || loserKey == normalizedAddress(winner.address)
        let loserStored = loser.properties ?? []
        let loserPrimaryIndex = loserStored.firstIndex { $0.primary == true }
        let loserPrimary = loserPrimaryIndex.map { loserStored[$0] }
        let loserOthers = loserStored.enumerated().filter { $0.offset != loserPrimaryIndex }.map(\.element)

        // Nothing stored on the loser and the same address: keep the
        // winner's list exactly as it is (absent stays absent).
        if loserStored.isEmpty, sameAddress {
            return MergePlan(properties: winner.properties, remap: [:], legacyTargetID: nil, loserAddressKey: loserKey)
        }

        var usedIDs = allIDs(in: winner)
        func freshID() -> String {
            var id = makeID()
            var attempts = 0
            while usedIDs.contains(id) || id == implicitPrimaryID, attempts < 16 { attempts += 1; id = makeID() }
            usedIDs.insert(id)
            return id
        }
        var list = materialize(winner, newPrimaryID: freshID())
        for property in list { usedIDs.insert(property.id) }
        var remap: [String: String] = [:]
        var legacyTargetID: String?

        func uniqueEquipment(_ items: [Canonical.Equipment]?) -> [Canonical.Equipment] {
            (items ?? []).map { item in
                var copy = item
                if usedIDs.contains(copy.id) { copy.id = freshID() } else { usedIDs.insert(copy.id) }
                return copy
            }
        }

        if sameAddress {
            if let loserPrimary {
                list[0].equipment = (list[0].equipment ?? []) + uniqueEquipment(loserPrimary.equipment)
                if list[0].equipment?.isEmpty == true { list[0].equipment = nil }
                if singleLine(list[0].label) == nil { list[0].label = singleLine(loserPrimary.label) }
                if trimmedText(list[0].notes) == nil { list[0].notes = trimmedText(loserPrimary.notes) }
                remap[loserPrimary.id] = list[0].id
            }
        } else {
            var converted = loserPrimary ?? Canonical.Property(id: freshID())
            if loserPrimary != nil {
                if usedIDs.contains(converted.id) {
                    let newID = freshID()
                    remap[converted.id] = newID
                    converted.id = newID
                } else {
                    usedIDs.insert(converted.id)
                }
            }
            converted.primary = nil
            converted.address = loser.address.trimmingCharacters(in: .whitespacesAndNewlines)
            converted.archivedAt = nil
            converted.equipment = loserPrimary == nil ? nil : uniqueEquipment(converted.equipment)
            if converted.equipment?.isEmpty == true { converted.equipment = nil }
            list.append(converted)
            legacyTargetID = converted.id
        }
        for var property in loserOthers {
            property.primary = nil
            if usedIDs.contains(property.id) {
                let newID = freshID()
                remap[property.id] = newID
                property.id = newID
            } else {
                usedIDs.insert(property.id)
            }
            property.equipment = property.equipment.map { uniqueEquipment($0) }
            list.append(property)
        }
        return MergePlan(properties: list, remap: remap, legacyTargetID: legacyTargetID, loserAddressKey: loserKey)
    }

    // MARK: - Search (spec §3)

    /// Equipment serial and model text per customer id (archived items
    /// included: an old serial still finds its customer). Customers with no
    /// equipment are left out.
    static func equipmentSearchIndex(customers: [Canonical.Customer]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for customer in customers {
            var values: [String] = []
            for property in customer.properties ?? [] {
                for item in property.equipment ?? [] {
                    if let serial = singleLine(item.serial) { values.append(serial) }
                    if let model = singleLine(item.model) { values.append(model) }
                }
            }
            if !values.isEmpty { index[customer.id, default: []].append(contentsOf: values) }
        }
        return index
    }

    // MARK: - Warranty (spec §3, §4)

    enum WarrantyStatus: Equatable {
        /// 0 is today.
        case expiresIn(days: Int)
        case expired
    }

    /// `nil` when the item has no (valid) warranty date.
    static func warrantyStatus(_ item: Canonical.Equipment, today: String) -> WarrantyStatus? {
        guard let expires = item.warrantyExpires, let days = daysBetween(today, expires) else { return nil }
        return days < 0 ? .expired : .expiresIn(days: days)
    }

    /// "Expires today", "Expires in 1 day", "Expires in 12 days", "Expired".
    static func warrantyText(_ status: WarrantyStatus) -> String {
        switch status {
        case .expired: return "Expired"
        case .expiresIn(let days) where days == 0: return "Expires today"
        case .expiresIn(let days) where days == 1: return "Expires in 1 day"
        case .expiresIn(let days): return "Expires in \(days) days"
        }
    }

    /// One active item whose warranty ends within the window.
    struct ExpiringWarranty: Equatable {
        let customer: Canonical.Customer
        let property: ResolvedProperty
        let equipment: Canonical.Equipment
        let expires: String
        let days: Int

        static func == (lhs: ExpiringWarranty, rhs: ExpiringWarranty) -> Bool {
            lhs.customer.id == rhs.customer.id && lhs.property == rhs.property
                && lhs.equipment == rhs.equipment && lhs.expires == rhs.expires && lhs.days == rhs.days
        }
    }

    /// Spec §4: active equipment (on an active property of a non-archived
    /// customer) whose `warrantyExpires` falls within the next `windowDays`
    /// local days, today included. Soonest first; ties by customer name
    /// (case-insensitive), then equipment id.
    static func expiringWarranties(
        customers: [Canonical.Customer],
        today: String,
        windowDays: Int = warrantyWindowDays
    ) -> [ExpiringWarranty] {
        var hits: [ExpiringWarranty] = []
        for customer in customers where !customer.id.isEmpty && !isArchived(customer.archivedAt) {
            for property in activeProperties(of: customer) {
                for item in property.activeEquipment {
                    guard let expires = item.warrantyExpires, let days = daysBetween(today, expires),
                          days >= 0, days < windowDays
                    else { continue }
                    hits.append(ExpiringWarranty(
                        customer: customer, property: property, equipment: item, expires: expires, days: days
                    ))
                }
            }
        }
        return hits.sorted { left, right in
            if left.days != right.days { return left.days < right.days }
            let l = left.customer.name.lowercased(), r = right.customer.name.lowercased()
            if l != r { return l < r }
            return left.equipment.id < right.equipment.id
        }
    }

    // MARK: - Local calendar dates (FA-039)

    /// A real `YYYY-MM-DD` Gregorian date.
    static func isValidLocalDate(_ value: String) -> Bool {
        components(value) != nil
    }

    /// Whole days from `from` to `to` (negative when `to` is earlier), by
    /// civil-day arithmetic on the components: no `Date`, no time zone.
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = dayNumber(from), let b = dayNumber(to) else { return nil }
        return b - a
    }

    /// "Oct 20, 2026" from `2026-10-20`, without a `Date` round trip.
    static func displayDate(_ value: String) -> String {
        guard let (year, month, day) = components(value) else { return value }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[month - 1]) \(day), \(year)"
    }

    private static func components(_ value: String) -> (Int, Int, Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month)
        else { return nil }
        return (year, month, day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
    private static func dayNumber(_ value: String) -> Int? {
        guard let (year, month, day) = components(value) else { return nil }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    // MARK: - Text

    static func isArchived(_ archivedAt: String?) -> Bool {
        !(archivedAt ?? "").isEmpty
    }

    /// Trimmed, internal whitespace collapsed to single spaces, control
    /// characters dropped; blank is `nil`.
    static func singleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control || CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        let cleaned = visible.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Trimmed (line breaks inside kept); blank is `nil`.
    static func trimmedText(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
