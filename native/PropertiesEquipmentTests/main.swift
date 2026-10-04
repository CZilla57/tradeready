import Foundation

// Phase 21 (multi-property and equipment history) host tests. Spec:
// docs/superpowers/specs/2026-10-02-properties-equipment-design.md §5.
// Covers the pure rules in `N/Domain/NativePropertiesEquipment.swift` and
// their seams: the canonical round-trip, the customer merge, the duplicate /
// recurring / occurrence whitelists, the nested delete + undo, the "Service
// address" rule and the warranty insight. Run with TZ=America/Phoenix (the
// runner defaults it): the warranty day boundary assumes a west-of-UTC zone
// (FA-039).

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectThrows(_ expected: NativePropertiesEquipment.PropertyError, _ label: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL: \(label) (no error)")
    } catch let error as NativePropertiesEquipment.PropertyError {
        if error != expected {
            failures += 1
            print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(error)")
        }
    } catch {
        failures += 1
        print("FAIL: \(label) (unexpected \(error))")
    }
}

typealias P = NativePropertiesEquipment

let decoder = JSONDecoder()
let wire: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

func expectSameWire<T: Encodable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    let left = (try? wire.encode(actual)).flatMap { String(data: $0, encoding: .utf8) } ?? "<encode failed>"
    let right = (try? wire.encode(expected)).flatMap { String(data: $0, encoding: .utf8) } ?? "<encode failed>"
    if left != right {
        failures += 1
        print("FAIL: \(label)\n  expected: \(right)\n  actual:   \(left)")
    }
}

func json<T: Encodable>(_ value: T) -> Canonical.JSONValue {
    // swiftlint:disable:next force_try
    (try? decoder.decode(Canonical.JSONValue.self, from: wire.encode(value))) ?? .null
}

func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
    try? decoder.decode(type, from: Data(text.utf8))
}

func customer(
    id: String = "c1",
    name: String = "Dana Smith",
    address: String = "12 Oak St",
    properties: String? = nil,
    extra: String = ""
) -> Canonical.Customer {
    let props = properties.map { #","properties":\#($0)"# } ?? ""
    let text = #"{"id":"\#(id)","name":"\#(name)","email":"","phone":"555-0100","address":"\#(address)","notes":""\#(props)\#(extra)}"#
    guard let value = decode(Canonical.Customer.self, text) else {
        fatalError("customer fixture does not decode: \(text)")
    }
    return value
}

func job(
    id: String,
    customerID: String = "c1",
    customerName: String = "Dana Smith",
    address: String = "12 Oak St",
    propertyID: String? = nil,
    scheduledDate: String? = nil,
    createdAt: String = "2026-09-01T10:00:00.000Z",
    archivedAt: String? = nil,
    status: String = "complete"
) -> Canonical.Job {
    var fields: [String: Canonical.JSONValue] = [
        "id": .string(id), "customerId": .string(customerID), "customerName": .string(customerName),
        "title": .string("Job \(id)"), "description": .string(""), "status": .string(status),
        "address": .string(address), "estimateTotal": .number(100), "laborHours": .number(1),
        "laborRate": .number(85), "materials": .array([]), "materialMarkup": .number(0),
        "overhead": .number(0), "margin": .number(0), "notes": .string(""), "createdAt": .string(createdAt),
    ]
    if let propertyID { fields["propertyId"] = .string(propertyID) }
    if let scheduledDate { fields["scheduledDate"] = .string(scheduledDate) }
    if let archivedAt { fields["archivedAt"] = .string(archivedAt) }
    guard let data = try? wire.encode(Canonical.JSONValue.object(fields)),
          let value = try? decoder.decode(Canonical.Job.self, from: data)
    else { fatalError("job fixture does not decode") }
    return value
}

func counter(_ prefix: String) -> () -> String {
    var next = 0
    return {
        next += 1
        return "\(prefix)\(next)"
    }
}

// MARK: - Canonical round-trip

func testCanonicalRoundTrip() {
    let text = #"""
    {"id":"c1","name":"Dana","email":"","phone":"","address":"12 Oak St","notes":"","properties":[
      {"id":"pr1_a","primary":true,"label":"Home","futureKey":{"nested":[1,2]},"equipment":[
        {"id":"eq1_a","type":"furnace","make":null,"serial":"S-1","warrantyExpires":"2027-01-31","futureEquipmentKey":"kept"}
      ]},
      {"id":"pr1_b","label":"Rental","address":"44 Elm St","notes":"Dog","archivedAt":"2026-09-01"}
    ]}
    """#
    guard let decoded = decode(Canonical.Customer.self, text) else {
        expect(false, "round-trip: the customer with properties decodes")
        return
    }
    let original = decode(Canonical.JSONValue.self, text) ?? .null
    expectEqual(json(decoded), original, "round-trip: properties and equipment re-encode exactly (unknown keys, explicit null)")
    expectEqual(decoded.properties?.count, 2, "round-trip: two properties")
    expectEqual(decoded.properties?.first?.preservation.unknownFields["futureKey"],
                .object(["nested": .array([.number(1), .number(2)])]), "round-trip: an unknown property key is preserved")
    expectEqual(decoded.properties?.first?.equipment?.first?.preservation.unknownFields["futureEquipmentKey"],
                .string("kept"), "round-trip: an unknown equipment key is preserved")
    expect(decoded.preservation.unknownFields["properties"] == nil, "round-trip: properties is typed, not unknown")

    let plain = customer()
    expect(plain.properties == nil, "round-trip: absent properties decode as nil")
    if case let .object(fields) = json(plain) {
        expect(fields["properties"] == nil, "round-trip: absent properties stay absent")
    } else {
        expect(false, "round-trip: a plain customer encodes as an object")
    }

    // Jobs and recurring rules carry `propertyId` as a typed field.
    let linked = job(id: "j1", propertyID: "pr1_b")
    expectEqual(linked.propertyId, "pr1_b", "round-trip: a job's propertyId decodes")
    if case let .object(fields) = json(linked) {
        expectEqual(fields["propertyId"], .string("pr1_b"), "round-trip: a job's propertyId encodes")
    }
    let unlinked = job(id: "j2")
    if case let .object(fields) = json(unlinked) {
        expect(fields["propertyId"] == nil, "round-trip: an unlinked job writes no propertyId")
    }

    // A blob that breaks P1 still decodes: a pull never fails over it.
    let broken = customer(properties: #"[{"id":"x","primary":true},{"id":"y","primary":true}]"#)
    expectEqual(broken.properties?.count, 2, "round-trip: a two-primary blob still decodes")
}

// MARK: - Implicit primary and materialization

func testImplicitPrimary() {
    let plain = customer(address: "12 Oak St")
    let list = P.properties(of: plain)
    expectEqual(list.count, 1, "implicit: one property")
    expectEqual(list.first?.id, P.implicitPrimaryID, "implicit: the navigation id")
    expect(list.first?.isPrimary == true && list.first?.isImplicit == true, "implicit: primary and implicit")
    expectEqual(list.first?.address, "12 Oak St", "implicit: the address is the customer's (D2)")
    expect(list.first?.equipment.isEmpty == true, "implicit: no equipment")
    expectEqual(P.property(P.implicitPrimaryID, of: plain)?.address, "12 Oak St", "implicit: lookup by the navigation id")
    expect(!P.showsPropertyPicker(customer: plain), "implicit: no job-editor picker for one property")

    // The primary's address always follows the customer's.
    var moved = customer(properties: #"[{"id":"pr_h","primary":true}]"#)
    moved.address = "99 New Rd"
    expectEqual(P.primary(of: moved).address, "99 New Rd", "derived: editing the customer address moves the primary")
}

func testMaterialization() {
    let plain = customer()
    let fresh = P.materialize(plain, newPrimaryID: "pr_new")
    expectEqual(fresh.map(\.id), ["pr_new"], "materialize: an absent list becomes one primary")
    expectEqual(fresh.first?.primary, true, "materialize: flagged primary")
    expect(fresh.first?.address == nil, "materialize: the primary stores no address (P1)")

    let noPrimary = customer(properties: #"[{"id":"pr_b","address":"44 Elm St"}]"#)
    expectEqual(P.materialize(noPrimary, newPrimaryID: "pr_new").map(\.id), ["pr_new", "pr_b"],
                "materialize: a primary-less list gets a primary in front")

    let twoPrimaries = customer(properties: #"[{"id":"pr_a","primary":true,"address":"stale","archivedAt":"2026-01-01"},{"id":"pr_b","primary":true}]"#)
    let repaired = P.materialize(twoPrimaries, newPrimaryID: "unused")
    expectEqual(repaired.map(\.id), ["pr_a", "pr_b"], "materialize: no new primary when one exists")
    expect(repaired[0].primary == true && repaired[0].address == nil && repaired[0].archivedAt == nil,
           "materialize: the first primary loses its stored address and archive stamp")
    expect(repaired[1].primary == nil && repaired[1].address == "12 Oak St",
           "materialize: an extra primary becomes a property at the customer's address")
    expectNoThrow("materialize: the repaired list is valid") { try P.validate(repaired) }

    let primaryLater = customer(properties: #"[{"id":"pr_b","address":"44 Elm St","primary":false},{"id":"pr_a","primary":true}]"#)
    let reordered = P.materialize(primaryLater, newPrimaryID: "unused")
    expectEqual(reordered.map(\.id), ["pr_a", "pr_b"], "materialize: the primary moves first")
    expect(reordered[1].primary == nil, "materialize: primary:false becomes absent")

    // The first property action materializes.
    let added = try? P.addProperty(
        to: plain, draft: .init(label: "Rental", address: "44 Elm St"), propertyID: "pr_r", primaryID: "pr_p"
    )
    expectEqual(added?.customer.properties?.map(\.id), ["pr_p", "pr_r"], "materialize: Add property creates the primary too")
    let equipment = try? P.addEquipment(
        to: plain, propertyID: P.implicitPrimaryID, draft: .init(type: "Furnace"), equipmentID: "eq_1", primaryID: "pr_p"
    )
    expectEqual(equipment?.propertyID, "pr_p", "materialize: equipment on the implicit primary lands on the new primary")
    expectEqual(equipment?.customer.properties?.first?.equipment?.map(\.id), ["eq_1"], "materialize: the item is stored")
}

func expectNoThrow(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do { try body() } catch {
        failures += 1
        print("FAIL: \(label) (\(error))")
    }
}

// MARK: - Invariants and caps

func testInvariantsAndCaps() {
    expectNoThrow("validate: absent is valid") { try P.validate(nil) }
    expectThrows(.noPrimary, "P1: a list needs a primary") {
        try P.validate([Canonical.Property(id: "a", address: "1 A St")])
    }
    expectThrows(.noPrimary, "P1: an empty list has no primary") { try P.validate([]) }
    expectThrows(.multiplePrimaries, "P1: one primary only") {
        try P.validate([Canonical.Property(id: "a", primary: true), Canonical.Property(id: "b", primary: true)])
    }
    expectThrows(.primaryLocked, "P1: the primary stores no address") {
        try P.validate([Canonical.Property(id: "a", primary: true, address: "1 A St")])
    }
    expectThrows(.primaryLocked, "P1: the primary is never archived") {
        try P.validate([Canonical.Property(id: "a", primary: true, archivedAt: "2026-01-01")])
    }
    expectThrows(.duplicateID("a"), "P2: property ids are unique") {
        try P.validate([Canonical.Property(id: "a", primary: true), Canonical.Property(id: "a", address: "2 B St")])
    }
    expectThrows(.duplicateID("a"), "P2: equipment ids are unique against property ids too") {
        try P.validate([Canonical.Property(id: "a", primary: true, equipment: [Canonical.Equipment(id: "a", type: "boiler")])])
    }
    expectThrows(.invalidID, "P2: an empty id is refused") {
        try P.validate([Canonical.Property(id: " ", primary: true)])
    }
    expectThrows(.addressRequired, "caps: a non-primary property needs an address") {
        try P.validate([Canonical.Property(id: "a", primary: true), Canonical.Property(id: "b", address: "  ")])
    }
    let primary = Canonical.Property(id: "p", primary: true)
    expectThrows(.addressTooLong, "caps: address 300") {
        try P.validate([primary, Canonical.Property(id: "b", address: String(repeating: "x", count: 301))])
    }
    expectNoThrow("caps: address of exactly 300 fits") {
        try P.validate([primary, Canonical.Property(id: "b", address: String(repeating: "x", count: 300))])
    }
    expectThrows(.labelTooLong, "caps: label 40") {
        try P.validate([Canonical.Property(id: "a", primary: true, label: String(repeating: "x", count: 41))])
    }
    expectThrows(.notesTooLong, "caps: property notes 1000") {
        try P.validate([Canonical.Property(id: "a", primary: true, notes: String(repeating: "x", count: 1001))])
    }
    let fifty = (0..<50).map { Canonical.Equipment(id: "e\($0)", type: "boiler") }
    expectNoThrow("caps: 50 equipment fit") {
        try P.validate([Canonical.Property(id: "a", primary: true, equipment: fifty)])
    }
    expectThrows(.tooManyEquipment, "caps: equipment 50 per property") {
        try P.validate([Canonical.Property(id: "a", primary: true, equipment: fifty + [Canonical.Equipment(id: "e50", type: "boiler")])])
    }
    let many = [primary] + (0..<P.propertyMaxCount).map { Canonical.Property(id: "p\($0)", address: "\($0) Main St") }
    expectThrows(.tooManyProperties, "caps: \(P.propertyMaxCount) properties per customer") { try P.validate(many) }
    func item(_ change: (inout Canonical.Equipment) -> Void) -> [Canonical.Property] {
        var value = Canonical.Equipment(id: "e", type: "boiler")
        change(&value)
        return [Canonical.Property(id: "a", primary: true, equipment: [value])]
    }
    expectThrows(.typeRequired, "caps: type is required") { try P.validate(item { $0.type = " " }) }
    expectThrows(.typeTooLong, "caps: type 40") { try P.validate(item { $0.type = String(repeating: "t", count: 41) }) }
    expectThrows(.makeTooLong, "caps: make 80") { try P.validate(item { $0.make = String(repeating: "m", count: 81) }) }
    expectThrows(.modelTooLong, "caps: model 80") { try P.validate(item { $0.model = String(repeating: "m", count: 81) }) }
    expectThrows(.serialTooLong, "caps: serial 80") { try P.validate(item { $0.serial = String(repeating: "s", count: 81) }) }
    expectThrows(.equipmentNotesTooLong, "caps: equipment notes 500") {
        try P.validate(item { $0.notes = String(repeating: "n", count: 501) })
    }
    expectThrows(.invalidInstallDate, "dates: install date must be a real date") { try P.validate(item { $0.installDate = "2026-02-30" }) }
    expectThrows(.invalidWarrantyDate, "dates: warranty must be YYYY-MM-DD") {
        try P.validate(item { $0.warrantyExpires = "2026-10-03T00:00:00Z" })
    }
    expect(P.isValidLocalDate("2028-02-29") && !P.isValidLocalDate("2027-02-29"), "dates: leap years")
    expect(!P.isValidLocalDate("2026-1-05") && !P.isValidLocalDate("") && !P.isValidLocalDate("2026-13-01"),
           "dates: malformed and out-of-range months are refused")
}

// MARK: - Property edits

func testPropertyEdits() {
    let base = customer(address: "12 Oak St")
    guard let added = try? P.addProperty(
        to: base, draft: .init(label: "  Rental   on Elm ", address: " 44 Elm St ", notes: "  Dog  "),
        propertyID: "pr_r", primaryID: "pr_p"
    ) else {
        expect(false, "add: a property is added")
        return
    }
    let rental = added.customer.properties?.last
    expect(rental?.label == "Rental on Elm" && rental?.address == "44 Elm St" && rental?.notes == "Dog",
           "add: label collapsed, address and notes trimmed")
    expect(rental?.primary == nil, "add: the new property is not primary")
    expect(P.showsPropertyPicker(customer: added.customer), "add: two active properties show the job-editor picker")

    expectThrows(.addressRequired, "add: an address is required") {
        _ = try P.addProperty(to: base, draft: .init(address: "  "), propertyID: "x", primaryID: "y")
    }
    expectThrows(.duplicateAddress, "add: the customer's own address is refused (normalized)") {
        _ = try P.addProperty(to: base, draft: .init(address: "12 OAK ST."), propertyID: "x", primaryID: "y")
    }
    expectThrows(.duplicateAddress, "add: another active property's address is refused") {
        _ = try P.addProperty(to: added.customer, draft: .init(address: "44 elm st"), propertyID: "x", primaryID: "y")
    }
    expectThrows(.duplicateID("pr_r"), "add: a repeated id is refused") {
        _ = try P.addProperty(to: added.customer, draft: .init(address: "7 Pine"), propertyID: "pr_r", primaryID: "y")
    }

    // Edit: the primary takes label and notes only.
    let primaryEdited = try? P.updateProperty(
        in: added.customer, propertyID: "pr_p", draft: .init(label: "Home", address: "ignored", notes: "Gate 12"),
        primaryID: "unused"
    )
    let home = primaryEdited?.properties?.first
    expect(home?.label == "Home" && home?.notes == "Gate 12" && home?.address == nil,
           "edit: the primary keeps no stored address")
    let rentalEdited = try? P.updateProperty(
        in: added.customer, propertyID: "pr_r", draft: .init(label: "", address: "46 Elm St", notes: ""),
        primaryID: "unused"
    )
    expect(rentalEdited?.properties?.last?.address == "46 Elm St" && rentalEdited?.properties?.last?.label == nil,
           "edit: a blank label is removed and the address saved")
    expectThrows(.duplicateAddress, "edit: moving onto the customer's address is refused") {
        _ = try P.updateProperty(in: added.customer, propertyID: "pr_r", draft: .init(address: "12 Oak St"), primaryID: "u")
    }
    expectThrows(.propertyNotFound, "edit: an unknown property") {
        _ = try P.updateProperty(in: added.customer, propertyID: "nope", draft: .init(address: "1 A"), primaryID: "u")
    }
    // Editing the implicit primary materializes it.
    let implicitEdit = try? P.updateProperty(
        in: base, propertyID: P.implicitPrimaryID, draft: .init(label: "Home"), primaryID: "pr_made"
    )
    expectEqual(implicitEdit?.properties?.map(\.id), ["pr_made"], "edit: the implicit primary materializes on edit")

    // Archive and restore.
    guard let archived = try? P.setPropertyArchived(
        in: added.customer, propertyID: "pr_r", archived: true, at: "2026-10-03", primaryID: "u"
    ) else {
        expect(false, "archive: a property archives")
        return
    }
    expectEqual(archived.properties?.last?.archivedAt, "2026-10-03", "archive: stamped")
    expect(!P.showsPropertyPicker(customer: archived), "archive: an archived property leaves the picker")
    expectEqual(P.activeProperties(of: archived).count, 1, "archive: only the primary stays active")
    expectThrows(.primaryLocked, "archive: the primary can't be archived") {
        _ = try P.setPropertyArchived(in: added.customer, propertyID: "pr_p", archived: true, at: "2026-10-03", primaryID: "u")
    }
    expectThrows(.propertyNotFound, "archive: the implicit primary can't be archived") {
        _ = try P.setPropertyArchived(in: base, propertyID: P.implicitPrimaryID, archived: true, at: "2026-10-03", primaryID: "u")
    }
    let restored = try? P.setPropertyArchived(in: archived, propertyID: "pr_r", archived: false, at: "x", primaryID: "u")
    expect(restored?.properties?.last?.archivedAt == nil, "archive: restore clears the stamp")
    // Restore refuses an address an active property took meanwhile.
    if let readded = try? P.addProperty(to: archived, draft: .init(address: "44 Elm St"), propertyID: "pr_r2", primaryID: "u") {
        expectThrows(.duplicateAddress, "archive: restore refuses a duplicate active address") {
            _ = try P.setPropertyArchived(in: readded.customer, propertyID: "pr_r", archived: false, at: "x", primaryID: "u")
        }
    } else {
        expect(false, "archive: an archived property's address can be re-added")
    }

    // Remove (the delete action).
    let removal = try? P.removeProperty(from: added.customer, propertyID: "pr_r", primaryID: "u")
    expect(removal?.removed.id == "pr_r" && removal?.index == 1 && removal?.customer.properties?.count == 1,
           "remove: the property leaves, its index is kept for undo")
    expectThrows(.primaryLocked, "remove: the primary can't be removed") {
        _ = try P.removeProperty(from: added.customer, propertyID: "pr_p", primaryID: "u")
    }
}

// MARK: - Equipment edits and type normalization

func testEquipment() {
    expectEqual(P.normalizeType("  Hot   Water Heater "), "water_heater", "type: an alias normalizes to its key")
    expectEqual(P.normalizeType("A/C"), "ac_condenser", "type: A/C")
    expectEqual(P.normalizeType("Mini-Split"), "mini_split", "type: display name, any case")
    expectEqual(P.normalizeType("ev_charger"), "ev_charger", "type: a key stays")
    expectEqual(P.normalizeType("Pool  heater"), "Pool heater", "type: a custom label is kept, whitespace collapsed")
    expectEqual(P.normalizeType("\u{7}"), nil, "type: control characters alone are blank")
    expectEqual(P.normalizeType(nil), nil, "type: nil")
    expectEqual(P.typeDisplayName("tankless_water_heater"), "Tankless water heater", "type: display name")
    expectEqual(P.typeDisplayName("Pool heater"), "Pool heater", "type: custom display verbatim")
    expectEqual(P.typeSentenceName("ac_condenser"), "AC condenser", "type: sentence name keeps the acronym")
    expectEqual(P.typeSentenceName("furnace"), "furnace", "type: sentence name is lowercase")
    expectEqual(P.typeSentenceName(P.otherTypeKey), "equipment", "type: other reads as equipment")
    let keys = P.equipmentTypes.map(\.key)
    expectEqual(keys, ["furnace", "ac_condenser", "heat_pump", "air_handler", "mini_split", "boiler", "water_heater",
                       "tankless_water_heater", "water_softener", "sump_pump", "electrical_panel", "generator",
                       "ev_charger", "thermostat", "other"], "type: the spec's preset keys, in order")
    var owner: [String: String] = [:]
    for type in P.equipmentTypes {
        for spelling in Set([type.key, type.displayName.lowercased()] + type.aliases) {
            expect(owner[spelling] == nil, "type: \"\(spelling)\" maps to one preset only")
            owner[spelling] = type.key
        }
        expect(type.aliases.allSatisfy { $0 == $0.lowercased() }, "type: \(type.key) aliases are lowercase")
    }

    let base = customer(properties: #"[{"id":"pr_p","primary":true},{"id":"pr_r","address":"44 Elm St"}]"#)
    guard let added = try? P.addEquipment(
        to: base, propertyID: "pr_r",
        draft: .init(type: "Gas furnace", make: " Carrier ", model: "59SC5", serial: "", installDate: "2019-04-02",
                     warrantyExpires: "2029-04-02", notes: ""),
        equipmentID: "eq_1", primaryID: "unused"
    ) else {
        expect(false, "equipment: an item is added")
        return
    }
    let stored = added.customer.properties?.last?.equipment?.first
    expect(stored?.type == "furnace" && stored?.make == "Carrier" && stored?.model == "59SC5",
           "equipment: type normalized, text trimmed")
    expect(stored?.serial == nil && stored?.notes == nil, "equipment: blank fields are absent")
    expect(stored?.installDate == "2019-04-02" && stored?.warrantyExpires == "2029-04-02", "equipment: dates stored verbatim")
    expectThrows(.typeRequired, "equipment: a type is required") {
        _ = try P.addEquipment(to: base, propertyID: "pr_r", draft: .init(type: " "), equipmentID: "eq_2", primaryID: "u")
    }
    expectThrows(.invalidWarrantyDate, "equipment: a bad warranty date is refused") {
        _ = try P.addEquipment(to: base, propertyID: "pr_r", draft: .init(type: "boiler", warrantyExpires: "2026-02-31"),
                               equipmentID: "eq_2", primaryID: "u")
    }
    expectThrows(.duplicateID("pr_r"), "equipment: an id used by a property is refused (P2)") {
        _ = try P.addEquipment(to: base, propertyID: "pr_r", draft: .init(type: "boiler"), equipmentID: "pr_r", primaryID: "u")
    }
    expectThrows(.propertyNotFound, "equipment: an unknown property") {
        _ = try P.addEquipment(to: base, propertyID: "nope", draft: .init(type: "boiler"), equipmentID: "eq_2", primaryID: "u")
    }
    var full = base
    full.properties?[1].equipment = (0..<50).map { Canonical.Equipment(id: "e\($0)", type: "boiler") }
    expectThrows(.tooManyEquipment, "equipment: the 51st item is refused") {
        _ = try P.addEquipment(to: full, propertyID: "pr_r", draft: .init(type: "boiler"), equipmentID: "eq_x", primaryID: "u")
    }

    // Edit keeps the id, archive state and unknown fields.
    var withUnknown = added.customer
    withUnknown.properties?[1].equipment?[0].preservation.unknownFields["future"] = .bool(true)
    let edited = try? P.updateEquipment(
        in: withUnknown, propertyID: "pr_r", equipmentID: "eq_1",
        draft: .init(type: "Pool heater", serial: "PH-9"), primaryID: "u"
    )
    let editedItem = edited?.properties?[1].equipment?[0]
    expect(editedItem?.type == "Pool heater" && editedItem?.serial == "PH-9" && editedItem?.make == nil,
           "equipment: edit replaces the editable fields")
    expectEqual(editedItem?.preservation.unknownFields["future"], .bool(true), "equipment: edit keeps unknown fields")

    // Mark as removed, then restore.
    let removed = try? P.setEquipmentArchived(
        in: added.customer, propertyID: "pr_r", equipmentID: "eq_1", archived: true, at: "2026-10-03", primaryID: "u"
    )
    let removedProperty = removed.flatMap { P.property("pr_r", of: $0) }
    expect(removedProperty?.activeEquipment.isEmpty == true && removedProperty?.archivedEquipment.count == 1,
           "equipment: Mark as removed moves it to Past equipment")
    let again = removed.flatMap {
        try? P.setEquipmentArchived(in: $0, propertyID: "pr_r", equipmentID: "eq_1", archived: true, at: "2027-01-01", primaryID: "u")
    }
    expectEqual(again?.properties?[1].equipment?[0].archivedAt, "2026-10-03", "equipment: archiving twice keeps the first stamp")
    let back = removed.flatMap {
        try? P.setEquipmentArchived(in: $0, propertyID: "pr_r", equipmentID: "eq_1", archived: false, at: "x", primaryID: "u")
    }
    expect(back?.properties?[1].equipment?[0].archivedAt == nil, "equipment: restore clears the stamp")
    expectThrows(.equipmentNotFound, "equipment: an item on another property is not found") {
        _ = try P.setEquipmentArchived(in: added.customer, propertyID: "pr_p", equipmentID: "eq_1", archived: true, at: "x", primaryID: "u")
    }
    let deleted = try? P.removeEquipment(from: added.customer, propertyID: "pr_r", equipmentID: "eq_1", primaryID: "u")
    expect(deleted?.removed.id == "eq_1" && deleted?.index == 0 && deleted?.customer.properties?[1].equipment == nil,
           "equipment: remove drops the item and the empty list")
}

// MARK: - Job editor property pick

func testJobEditorPick() {
    expectEqual(P.addressAfterPicking(currentAddress: "", previousPropertyAddress: nil, pickedAddress: "44 Elm St"),
                "44 Elm St", "pick: an empty address is filled")
    expectEqual(P.addressAfterPicking(currentAddress: "  ", previousPropertyAddress: "12 Oak St", pickedAddress: "44 Elm St"),
                "44 Elm St", "pick: a blank address is filled")
    expectEqual(P.addressAfterPicking(currentAddress: "12 Oak St", previousPropertyAddress: "12 Oak St", pickedAddress: "44 Elm St"),
                "44 Elm St", "pick: the previous pick's address is replaced")
    expectEqual(P.addressAfterPicking(currentAddress: "12 Oak St, Unit B", previousPropertyAddress: "12 Oak St", pickedAddress: "44 Elm St"),
                "12 Oak St, Unit B", "pick: a typed edit is never overwritten")
    expectEqual(P.addressAfterPicking(currentAddress: "12 Oak St", previousPropertyAddress: nil, pickedAddress: "44 Elm St"),
                "12 Oak St", "pick: with no previous pick, an existing address stays")
    expectEqual(P.addressAfterPicking(currentAddress: "12 oak st", previousPropertyAddress: "12 Oak St", pickedAddress: "44 Elm St"),
                "12 oak st", "pick: a case change counts as a typed edit")

    let two = customer(properties: #"[{"id":"pr_p","primary":true,"label":"Home"},{"id":"pr_r","label":"Rental","address":"44 Elm St"},{"id":"pr_x","address":"9 Gone Rd","archivedAt":"2026-01-01"}]"#)
    let options = P.pickerOptions(customer: two)
    expectEqual(options.map(\.id), ["pr_p", "pr_r"], "pick: active properties, primary first")
    expectEqual(options.first?.title, "Primary · Home", "pick: the primary is labelled Primary")
    expectEqual(options.first?.address, "12 Oak St", "pick: the primary's address is the customer's")
    expect(options.first?.isPrimary == true, "pick: picking the primary sets its stored id")

    // The whole pick, as the job editor applies it.
    let autoFilled = P.pick("pr_r", currentPropertyID: nil, currentAddress: "12 Oak St", options: options)
    expect(autoFilled.propertyID == "pr_r" && autoFilled.address == "44 Elm St",
           "pick: the address auto-filled from the customer moves to the picked property")
    let typed = P.pick("pr_r", currentPropertyID: nil, currentAddress: "12 Oak St, back gate", options: options)
    expect(typed.propertyID == "pr_r" && typed.address == "12 Oak St, back gate", "pick: a typed address stays")
    let primary = P.pick("pr_p", currentPropertyID: "pr_r", currentAddress: "44 Elm St", options: options)
    expect(primary.propertyID == "pr_p" && primary.address == "12 Oak St", "pick: picking the primary sets its id and address")
    let cleared = P.pick(nil, currentPropertyID: "pr_r", currentAddress: "44 Elm St", options: options)
    expect(cleared.propertyID == nil && cleared.address == "44 Elm St", "pick: Not set clears the link and keeps the address")
    let fromArchived = P.pick("pr_r", currentPropertyID: "pr_x", currentAddress: "9 Gone Rd", options: options)
    expect(fromArchived.propertyID == "pr_r" && fromArchived.address == "9 Gone Rd",
           "pick: leaving an archived link never overwrites its address")
}

// MARK: - Job history and P3

func testJobHistory() {
    let owner = customer(properties: #"[{"id":"pr_p","primary":true},{"id":"pr_r","address":"44 Elm St"},{"id":"pr_x","address":"9 Gone Rd","archivedAt":"2026-01-01"}]"#)
    let jobs = [
        job(id: "legacy", address: " 12 OAK ST. ", scheduledDate: "2026-03-01"),
        job(id: "linkedPrimary", address: "12 Oak St", propertyID: "pr_p", scheduledDate: "2026-05-01"),
        job(id: "rental1", address: "44 Elm St", propertyID: "pr_r", scheduledDate: "2026-04-01"),
        job(id: "rental2", address: "44 Elm Street", propertyID: "pr_r", createdAt: "2026-06-02T09:00:00.000Z"),
        job(id: "elsewhere", address: "1 Other Pl"),
        job(id: "rentalUnlinked", address: "44 Elm St"),
        job(id: "archived", address: "12 Oak St", archivedAt: "2026-09-01"),
        job(id: "otherCustomer", customerID: "c2", customerName: "Someone", address: "12 Oak St", propertyID: "pr_r"),
        job(id: "legacyName", customerID: "", customerName: "  dana smith ", address: "12 Oak St", scheduledDate: "2026-01-01"),
        job(id: "linkedArchived", address: "9 Gone Rd", propertyID: "pr_x"),
    ]
    expectEqual(P.jobHistory(propertyID: "pr_p", customer: owner, jobs: jobs).map(\.id),
                ["linkedPrimary", "legacy", "legacyName"],
                "history: the primary has its linked jobs plus unlinked jobs at the customer's address, newest first")
    expectEqual(P.jobHistory(propertyID: "pr_r", customer: owner, jobs: jobs).map(\.id), ["rental2", "rental1"],
                "history: a property has only its linked jobs (created date when unscheduled)")
    expectEqual(P.jobHistory(propertyID: "pr_x", customer: owner, jobs: jobs).map(\.id), ["linkedArchived"],
                "history: an archived property still lists its jobs")
    expectEqual(P.jobHistory(propertyID: "nope", customer: owner, jobs: jobs).map(\.id), [],
                "history: an unknown property has none")
    let implicitOwner = customer()
    expectEqual(P.jobHistory(propertyID: P.implicitPrimaryID, customer: implicitOwner, jobs: jobs).map(\.id),
                ["legacy", "legacyName"], "history: the implicit primary matches by address only")

    // P3: resolution never crashes and never rewrites.
    expectEqual(P.resolvedProperty(for: jobs[2], customer: owner)?.id, "pr_r", "P3: a linked job resolves")
    expect(P.resolvedProperty(for: jobs[9], customer: owner) == nil, "P3: an archived property does not resolve")
    expect(P.resolvedProperty(for: jobs[7], customer: owner) == nil, "P3: another customer's job does not resolve")
    expect(P.resolvedProperty(for: job(id: "dangling", propertyID: "pr_gone"), customer: owner) == nil,
           "P3: a removed property does not resolve")
    expect(P.resolvedProperty(for: jobs[2], customer: nil) == nil, "P3: a merged-away customer does not resolve")
    expectEqual(P.property(atJob: jobs[0], customer: owner)?.id, "pr_p", "at job: an unlinked job at the customer address is at the primary")
    expect(P.property(atJob: jobs[4], customer: owner) == nil, "at job: an unlinked job elsewhere is at no property")

    // "Add as a property".
    expect(P.canAddJobAddressAsProperty(jobs[4], customer: owner), "add-as: a new address is offered")
    expect(!P.canAddJobAddressAsProperty(jobs[5], customer: owner), "add-as: an address that is already a property is not")
    expect(!P.canAddJobAddressAsProperty(jobs[0], customer: owner), "add-as: the customer's address is not")
    expect(!P.canAddJobAddressAsProperty(jobs[2], customer: owner), "add-as: a linked job is not")
    expect(!P.canAddJobAddressAsProperty(jobs[9], customer: owner), "add-as: a job linked to an archived property is not")
    expect(P.canAddJobAddressAsProperty(job(id: "d", address: "5 New Way", propertyID: "pr_gone"), customer: owner),
           "add-as: a job whose property was removed is offered")
    expect(!P.canAddJobAddressAsProperty(job(id: "e", address: "  "), customer: owner), "add-as: a blank address is not")
    if let attached = try? P.addJobAddressAsProperty(job: jobs[4], customer: owner, propertyID: "pr_new", primaryID: "u") {
        expectEqual(attached.job.propertyId, "pr_new", "add-as: the job is linked")
        expectEqual(attached.customer.properties?.last?.address, "1 Other Pl", "add-as: the property takes the job's address")
        expectEqual(attached.job.address, "1 Other Pl", "add-as: the job keeps its own address")
    } else {
        expect(false, "add-as: the property is created")
    }
    expectThrows(.jobNotAttachable, "add-as: refused when not offered") {
        _ = try P.addJobAddressAsProperty(job: jobs[0], customer: owner, propertyID: "x", primaryID: "u")
    }
}

// MARK: - Merge

func testMerge() throws {
    // Different addresses: the loser's primary becomes a property.
    let winner = customer(id: "w", name: "Dana Smith", address: "12 Oak St")
    let loser = customer(
        id: "l", name: "Dana S", address: "44 Elm St",
        properties: #"[{"id":"pr_lp","primary":true,"label":"Rental","equipment":[{"id":"eq_l1","type":"boiler"}]},{"id":"pr_lb","address":"7 Pine Ct","futureKey":1}]"#
    )
    let legacyJob = job(id: "lj1", customerID: "l", customerName: "Dana S", address: "44 elm st")
    let linkedJob = job(id: "lj2", customerID: "l", customerName: "Dana S", address: "7 Pine Ct", propertyID: "pr_lb")
    let otherJob = job(id: "lj3", customerID: "l", customerName: "Dana S", address: "1 Elsewhere")
    let winnerJob = job(id: "wj1", customerID: "w", address: "12 Oak St")
    var rule = decode(Canonical.RecurringJob.self, #"{"id":"rj1","customerId":"l","customerName":"Dana S","title":"Service","description":"","address":"44 Elm St","notes":"","estimateTotal":0,"laborHours":0,"laborRate":0,"materials":[],"materialMarkup":0,"overhead":0,"margin":0,"cadence":"monthly","endCondition":"never","occurrenceCount":0,"nextDueDate":"2026-11-01","isActive":true,"createdAt":"2026-10-01"}"#)
    expect(rule != nil, "merge: the recurring fixture decodes")
    rule?.propertyId = nil
    // Every dependent collection is present: merge undo writes back empty
    // collections it restored into (pre-existing behavior).
    let original = Canonical.Snapshot(payload: .init(
        invoices: [],
        jobs: [legacyJob, linkedJob, otherJob, winnerJob],
        customers: [winner, loser],
        recurringJobs: rule.map { [$0] } ?? [],
        recurringInvoices: []
    ))
    let merged = try NativeCustomerIdentity.merge(
        snapshot: original, winnerID: "w", loserID: "l", makePropertyID: counter("pr_m")
    )
    let after = merged.snapshot.payload.customers?.first { $0.id == "w" }
    expectEqual(after?.properties?.map(\.id), ["pr_m1", "pr_lp", "pr_lb"],
                "merge: the winner's new primary, then the loser's primary and others")
    expectEqual(after?.properties?.first?.primary, true, "merge: one primary (the winner's)")
    expect(after?.properties?[1].primary == nil && after?.properties?[1].address == "44 Elm St",
           "merge: the loser's primary becomes a property at the loser's address")
    expect(after?.properties?[1].label == "Rental" && after?.properties?[1].equipment?.map(\.id) == ["eq_l1"],
           "merge: it keeps its label and equipment")
    expectEqual(after?.properties?[2].preservation.unknownFields["futureKey"], .number(1),
                "merge: the loser's other properties keep their unknown fields")
    expectNoThrow("merge: the merged list is valid") { try P.validate(after?.properties) }
    let jobsAfter = Dictionary(uniqueKeysWithValues: (merged.snapshot.payload.jobs ?? []).map { ($0.id, $0) })
    expectEqual(jobsAfter["lj1"]?.propertyId, "pr_lp", "merge: a legacy job at the loser's address links to its old primary")
    expectEqual(jobsAfter["lj2"]?.propertyId, "pr_lb", "merge: a linked job keeps its propertyId")
    expect(jobsAfter["lj3"]?.propertyId == nil, "merge: a job elsewhere stays unlinked")
    expect(jobsAfter["wj1"]?.propertyId == nil, "merge: the winner's jobs are untouched")
    expectEqual(merged.snapshot.payload.recurringJobs?.first?.propertyId, "pr_lp",
                "merge: a recurring rule at the loser's address follows too")
    if let after {
        expectEqual(P.jobHistory(propertyID: "pr_lp", customer: after, jobs: merged.snapshot.payload.jobs ?? []).map(\.id),
                    ["lj1"], "merge: the old primary's history survives the merge")
    }
    let undone = try NativeCustomerIdentity.undo(snapshot: merged.snapshot, token: merged.undo)
    expectSameWire(undone.snapshot, original, "merge: undo restores both customers and every job exactly")

    // Same address: the loser's primary equipment merges into the winner's.
    let sameWinner = customer(id: "w", address: "12 Oak St",
                              properties: #"[{"id":"pr_wp","primary":true,"equipment":[{"id":"eq_w1","type":"furnace"}]}]"#)
    let sameLoser = customer(id: "l", name: "Dana S", address: " 12 OAK ST ",
                             properties: #"[{"id":"pr_lp","primary":true,"label":"Home","notes":"Gate 4","equipment":[{"id":"eq_l1","type":"water_heater"}]}]"#)
    let loserLinked = job(id: "lj", customerID: "l", customerName: "Dana S", address: "12 Oak St", propertyID: "pr_lp")
    let sameSnapshot = Canonical.Snapshot(payload: .init(
        invoices: [], jobs: [loserLinked], customers: [sameWinner, sameLoser], recurringJobs: [], recurringInvoices: []
    ))
    let same = try NativeCustomerIdentity.merge(snapshot: sameSnapshot, winnerID: "w", loserID: "l", makePropertyID: counter("pr_m"))
    let sameAfter = same.snapshot.payload.customers?.first { $0.id == "w" }
    expectEqual(sameAfter?.properties?.map(\.id), ["pr_wp"], "same address: no extra property")
    expectEqual(sameAfter?.properties?.first?.equipment?.map(\.id), ["eq_w1", "eq_l1"],
                "same address: the loser's equipment joins the winner's primary")
    expect(sameAfter?.properties?.first?.label == "Home" && sameAfter?.properties?.first?.notes == "Gate 4",
           "same address: the winner's blank label and notes fill from the loser's primary")
    expectEqual(same.snapshot.payload.jobs?.first?.propertyId, "pr_wp",
                "same address: a job linked to the loser's primary re-links to the winner's")
    let sameUndone = try NativeCustomerIdentity.undo(snapshot: same.snapshot, token: same.undo)
    expectSameWire(sameUndone.snapshot, sameSnapshot, "same address: undo restores both records exactly")

    // Nothing stored on the loser and the same address: absent stays absent.
    let quiet = Canonical.Snapshot(payload: .init(customers: [
        customer(id: "w", address: "12 Oak St"), customer(id: "l", name: "Dana S", address: "12 oak st"),
    ]))
    let quietMerged = try NativeCustomerIdentity.merge(snapshot: quiet, winnerID: "w", loserID: "l", makePropertyID: counter("pr_m"))
    expect(quietMerged.snapshot.payload.customers?.first?.properties == nil,
           "merge: two plain customers at one address stay without properties")

    // A blank winner address takes the loser's, so the loser's primary is the
    // same place.
    let blankWinner = customer(id: "w", address: "")
    let backfilled = try NativeCustomerIdentity.merge(
        snapshot: .init(payload: .init(customers: [blankWinner, customer(id: "l", name: "Dana S", address: "44 Elm St")])),
        winnerID: "w", loserID: "l", makePropertyID: counter("pr_m")
    )
    let backfilledWinner = backfilled.snapshot.payload.customers?.first
    expect(backfilledWinner?.address == "44 Elm St" && backfilledWinner?.properties == nil,
           "merge: the backfilled address is compared, so no duplicate property")

    // A plain loser at a different address keeps that address as a property.
    let plainLoser = try NativeCustomerIdentity.merge(
        snapshot: .init(payload: .init(
            jobs: [job(id: "pj", customerID: "l", customerName: "Dana S", address: "44 Elm St")],
            customers: [customer(id: "w", address: "12 Oak St"), customer(id: "l", name: "Dana S", address: "44 Elm St")]
        )),
        winnerID: "w", loserID: "l", makePropertyID: counter("pr_m")
    )
    let plainWinner = plainLoser.snapshot.payload.customers?.first
    expectEqual(plainWinner?.properties?.map(\.id), ["pr_m1", "pr_m2"], "merge: a plain loser's address becomes a property")
    expectEqual(plainWinner?.properties?.last?.address, "44 Elm St", "merge: at the loser's address")
    expectEqual(plainLoser.snapshot.payload.jobs?.first?.propertyId, "pr_m2", "merge: and the loser's jobs there link to it")

    // Colliding ids (both copies of one record) are re-minted.
    let twin = customer(id: "w", address: "12 Oak St", properties: #"[{"id":"pr_a","primary":true},{"id":"pr_b","address":"7 Pine"}]"#)
    var twinLoser = twin
    twinLoser.id = "l"
    twinLoser.name = "Dana S"
    twinLoser.address = "44 Elm St"
    let twins = try NativeCustomerIdentity.merge(
        snapshot: .init(payload: .init(
            jobs: [job(id: "tj", customerID: "l", customerName: "Dana S", address: "7 Pine", propertyID: "pr_b")],
            customers: [twin, twinLoser]
        )),
        winnerID: "w", loserID: "l", makePropertyID: counter("pr_m")
    )
    let twinAfter = twins.snapshot.payload.customers?.first
    expectNoThrow("merge: colliding ids are re-minted (P2)") { try P.validate(twinAfter?.properties) }
    let relinked = twins.snapshot.payload.jobs?.first?.propertyId
    expect(relinked != nil && relinked != "pr_b" && twinAfter?.properties?.contains { $0.id == relinked } == true,
           "merge: a job on a re-minted property follows the new id")
}

// MARK: - Whitelists

func testWhitelists() throws {
    var source = job(id: "src", address: "44 Elm St", propertyID: "pr_r", scheduledDate: "2026-10-10", status: "approved")
    source.approval = nil
    let draft = try CanonicalUIAdapters.duplicateJob(source, id: "dup", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    expectEqual(draft.canonicalTemplate.propertyId, "pr_r", "whitelist: Duplicate job carries propertyId")
    expectEqual(draft.job.propertyId, "pr_r", "whitelist: the duplicate's screen model carries it")
    let unlinkedDraft = try CanonicalUIAdapters.duplicateJob(job(id: "u"), id: "dup2", createdAt: Date())
    expect(unlinkedDraft.canonicalTemplate.propertyId == nil, "whitelist: an unlinked duplicate stays unlinked")

    let rule = try CanonicalUIAdapters.recurringJob(
        from: source, id: "rj_1", startDate: "2026-10-10", cadence: .monthly, endCondition: .never,
        endCount: nil, endDate: nil, createdAt: "2026-10-03"
    )
    expectEqual(rule.propertyId, "pr_r", "whitelist: Set up repeat carries propertyId onto the rule")
    let generation = NativeRecurringJobs.generate(
        rules: [rule], jobs: [], today: "2026-12-15", makeJobID: { "occ_\($0)_\($1)" }
    )
    expect(!generation.newJobs.isEmpty && generation.newJobs.allSatisfy { $0.propertyId == "pr_r" },
           "whitelist: every generated occurrence is at the rule's property")
    expect(generation.newJobs.allSatisfy { $0.address == "44 Elm St" }, "whitelist: occurrences keep the rule's address")

    // The screen model round-trips propertyId through the edit adapter.
    var edit = try CanonicalUIAdapters.edit(source)
    expectEqual(edit.value.propertyId, "pr_r", "adapter: the job screen model reads propertyId")
    edit.value.propertyId = "pr_p"
    expectEqual(try CanonicalUIAdapters.canonical(from: edit).propertyId, "pr_p", "adapter: picking a property writes it")
    edit.value.propertyId = nil
    let cleared = try CanonicalUIAdapters.canonical(from: edit)
    if case let .object(fields) = json(cleared) {
        expect(fields["propertyId"] == nil, "adapter: clearing the pick removes the key")
    }
}

// MARK: - Nested delete and undo

func testDeleteAndUndo() throws {
    let owner = customer(properties: #"[{"id":"pr_p","primary":true,"equipment":[{"id":"eq_1","type":"furnace"},{"id":"eq_2","type":"boiler"}]},{"id":"pr_r","label":"Rental","address":"44 Elm St"}]"#)
    let snapshot = Canonical.Snapshot(payload: .init(customers: [owner]))
    let deleted = try NativeRecordDeletion.deleteEquipment(
        snapshot: snapshot, customerID: "c1", propertyID: "pr_p", equipmentID: "eq_1", primaryID: "u"
    )
    expectEqual(deleted.snapshot.payload.customers?.first?.properties?.first?.equipment?.map(\.id), ["eq_2"],
                "delete: the equipment entry is gone")
    expect(deleted.mutation.table == "customers" && deleted.mutation.op == .upsert && deleted.mutation.recordId == "c1",
           "delete: nested deletes upsert the customer")
    expectEqual(deleted.undo.bannerMessage, "Deleted equipment Furnace", "delete: the undo banner names the type")
    let restored = try NativeRecordDeletion.undo(snapshot: deleted.snapshot, token: deleted.undo)
    expectSameWire(restored.snapshot, snapshot, "undo: the equipment returns to its place")
    expect(restored.mutation.table == "customers" && restored.mutation.op == .upsert, "undo: the customer is upserted again")

    let propertyDeleted = try NativeRecordDeletion.deleteProperty(
        snapshot: snapshot, customerID: "c1", propertyID: "pr_r", primaryID: "u"
    )
    expectEqual(propertyDeleted.undo.bannerMessage, "Deleted property Rental", "delete: the property banner")
    let propertyRestored = try NativeRecordDeletion.undo(snapshot: propertyDeleted.snapshot, token: propertyDeleted.undo)
    expectSameWire(propertyRestored.snapshot, snapshot, "undo: the property returns")
    do {
        _ = try NativeRecordDeletion.deleteProperty(snapshot: snapshot, customerID: "c1", propertyID: "pr_p", primaryID: "u")
        expect(false, "delete: the primary is refused")
    } catch {
        expect(true, "delete: the primary is refused")
    }
    do {
        _ = try NativeRecordDeletion.deleteProperty(snapshot: snapshot, customerID: "c1", propertyID: "nope", primaryID: "u")
        expect(false, "delete: an unknown property is not found")
    } catch NativeRecordDeletionError.recordNotFound {
        expect(true, "delete: an unknown property is not found")
    }
    // A recreated id is never overwritten.
    var recreated = deleted.snapshot
    recreated.payload.customers?[0].properties?[0].equipment?.append(Canonical.Equipment(id: "eq_1", type: "heat_pump"))
    do {
        _ = try NativeRecordDeletion.undo(snapshot: recreated, token: deleted.undo)
        expect(false, "undo: a recreated id conflicts")
    } catch NativeRecordDeletionError.undoConflict {
        expect(true, "undo: a recreated id conflicts")
    }
}

// MARK: - Service address and search

func testServiceAddressAndSearch() {
    expectEqual(P.serviceAddressLine(jobAddress: "44 Elm St", customerAddress: "12 Oak St"), "44 Elm St",
                "service address: shown when it differs")
    expectEqual(P.serviceAddressLine(jobAddress: " 12 oak st. ", customerAddress: "12 Oak St"), nil,
                "service address: hidden when it normalizes equal")
    expectEqual(P.serviceAddressLine(jobAddress: "  ", customerAddress: "12 Oak St"), nil, "service address: hidden when blank")
    expectEqual(P.serviceAddressLine(jobAddress: "44 Elm St", customerAddress: ""), "44 Elm St",
                "service address: shown when the customer has none")
    expectEqual(P.normalizedAddress("  12  Oak St.,\n Tucson, AZ #4 "), "12 oak st tucson az 4", "normalize: punctuation and spacing")

    let owner = customer(properties: #"[{"id":"pr_p","primary":true,"equipment":[{"id":"e1","type":"furnace","model":"59SC5","serial":"CAR-123"},{"id":"e2","type":"boiler","serial":"OLD-9","archivedAt":"2020-01-01"}]}]"#)
    let index = P.equipmentSearchIndex(customers: [owner, customer(id: "c2")])
    expectEqual(index["c1"].map { Set($0) }, Set(["CAR-123", "59SC5", "OLD-9"]),
                "search: serials and models, removed equipment included")
    expect(index["c2"] == nil, "search: customers without equipment are left out")
}

// MARK: - Warranty (Phoenix day boundary)

func testWarranty() {
    expectEqual(P.daysBetween("2026-10-03", "2026-10-03"), 0, "days: same day")
    expectEqual(P.daysBetween("2026-10-03", "2026-11-02"), 30, "days: across a month")
    expectEqual(P.daysBetween("2026-12-31", "2027-01-01"), 1, "days: across a year")
    expectEqual(P.daysBetween("2028-02-28", "2028-03-01"), 2, "days: leap day")
    expectEqual(P.daysBetween("2026-10-03", "2026-10-02"), -1, "days: negative when earlier")
    expectEqual(P.daysBetween("2026-10-03", "bad"), nil, "days: invalid input")
    // The civil count agrees with the local calendar for every day of a year
    // (DST included when the zone has it).
    let calendar = NativeCashBasis.localCalendar
    var agree = true
    for offset in 0..<370 {
        guard let start = NativeCashBasis.parseLocalDate("2026-01-01"),
              let day = calendar.date(byAdding: .day, value: offset, to: start)
        else { agree = false; break }
        if P.daysBetween("2026-01-01", NativeCashBasis.ymd(day)) != offset { agree = false }
    }
    expect(agree, "days: civil arithmetic matches the local calendar")
    expectEqual(P.displayDate("2026-10-20"), "Oct 20, 2026", "dates: display without a Date round trip")

    let item = { (date: String) in Canonical.Equipment(id: "e", type: "furnace", warrantyExpires: date) }
    expectEqual(P.warrantyStatus(item("2026-10-15"), today: "2026-10-03"), .expiresIn(days: 12), "status: days left")
    expectEqual(P.warrantyStatus(item("2026-10-02"), today: "2026-10-03"), .expired, "status: expired")
    expectEqual(P.warrantyText(.expiresIn(days: 12)), "Expires in 12 days", "text: N days")
    expectEqual(P.warrantyText(.expiresIn(days: 1)), "Expires in 1 day", "text: one day")
    expectEqual(P.warrantyText(.expiresIn(days: 0)), "Expires today", "text: today")
    expectEqual(P.warrantyText(.expired), "Expired", "text: expired")
    expect(P.warrantyStatus(Canonical.Equipment(id: "e", type: "furnace"), today: "2026-10-03") == nil, "status: none without a date")

    expectEqual(TimeZone.current.identifier, "America/Phoenix", "warranty: the suite runs in Phoenix")
    // 23:30 on Oct 3 in Phoenix is already Oct 4 in UTC.
    let lateEvening = NativeCashBasis.localDate(year: 2026, month: 9, day: 3, hour: 23, minute: 30)
    expectEqual(NativeCashBasis.ymd(lateEvening), "2026-10-03", "warranty: today is the local date")
    let customers = [
        customer(id: "c1", name: "Dana Smith", properties: #"[{"id":"pr_1","primary":true,"equipment":[{"id":"e_today","type":"water_heater","warrantyExpires":"2026-10-03"},{"id":"e_gone","type":"boiler","warrantyExpires":"2026-10-02"},{"id":"e_last","type":"furnace","warrantyExpires":"2026-11-01"},{"id":"e_out","type":"furnace","warrantyExpires":"2026-11-02"},{"id":"e_removed","type":"furnace","warrantyExpires":"2026-10-03","archivedAt":"2026-09-01"}]}]"#),
        customer(id: "c2", name: "Abe Lane", properties: #"[{"id":"pr_2","primary":true,"equipment":[{"id":"e_abe","type":"ac_condenser","make":"Trane","model":"XR14","warrantyExpires":"2026-10-03"}]}]"#),
        customer(id: "c3", name: "Zed Archived", properties: #"[{"id":"pr_3","primary":true,"equipment":[{"id":"e_z","type":"furnace","warrantyExpires":"2026-10-03"}]}]"#, extra: #","archivedAt":"2026-01-01""#),
        customer(id: "c4", name: "Ola Rental", properties: #"[{"id":"pr_4","primary":true},{"id":"pr_4b","address":"9 Gone","archivedAt":"2026-01-01","equipment":[{"id":"e_ap","type":"furnace","warrantyExpires":"2026-10-03"}]}]"#),
    ]
    let hits = P.expiringWarranties(customers: customers, today: NativeCashBasis.ymd(lateEvening))
    expectEqual(hits.map(\.equipment.id), ["e_abe", "e_today", "e_last"],
                "window: today through 29 days ahead; ties by customer name; removed, archived and expired left out")
    expectEqual(hits.map(\.days), [0, 0, 29], "window: day counts")

    let insights = NativeTodayInsights.selectWarrantyExpiring(customers: customers, now: lateEvening)
    expectEqual(insights.count, 1, "insight: at most one row")
    let insight = insights.first
    expectEqual(insight?.kind, .warrantyExpiring, "insight: kind")
    expectEqual(insight?.id, "warranty_expiring:e_abe:2026-10-03", "insight: id carries the item and the expiry")
    expectEqual(insight?.title, "Abe Lane's AC condenser warranty ends Oct 3, 2026", "insight: copy")
    expectEqual(insight?.detail, "A good time to offer a maintenance plan.", "insight: detail")
    expectEqual(insight?.target, .customer(customerId: "c2"), "insight: lands on the customer")
    expect(insight?.reason.contains("today") == true && insight?.reason.contains("Trane XR14") == true,
           "insight: the reason says when and which unit")
    expect(insight?.coachPrompt?.contains("Abe's AC condenser") == true, "insight: the coach prompt uses the first name")
    expectEqual(NativeTodayInsights.selectWarrantyExpiring(customers: [customers[0]], now: lateEvening).first?.id,
                "warranty_expiring:e_today:2026-10-03", "insight: an expiry today still counts at 23:30 local")
    let nextMorning = NativeCashBasis.localDate(year: 2026, month: 9, day: 4, hour: 0, minute: 30)
    expectEqual(NativeTodayInsights.selectWarrantyExpiring(customers: [customers[0]], now: nextMorning).first?.id,
                "warranty_expiring:e_last:2026-11-01", "insight: after local midnight the expired one drops out")

    // Priority: right after maintenance due, before the expense anomaly.
    let all = NativeTodayInsights.select(jobs: [], invoices: [], now: lateEvening, customers: customers)
    expectEqual(all.map(\.kind), [.warrantyExpiring], "insight: selected by the engine")
}

testCanonicalRoundTrip()
testImplicitPrimary()
testMaterialization()
testInvariantsAndCaps()
testPropertyEdits()
testEquipment()
testJobEditorPick()
testJobHistory()
do { try testMerge() } catch { expect(false, "merge tests threw \(error)") }
do { try testWhitelists() } catch { expect(false, "whitelist tests threw \(error)") }
do { try testDeleteAndUndo() } catch { expect(false, "delete tests threw \(error)") }
testServiceAddressAndSearch()
testWarranty()

if failures == 0 {
    print("PASS: properties and equipment tests (\(checks) checks)")
} else {
    print("properties and equipment tests: \(failures) of \(checks) checks FAILED")
    exit(1)
}
