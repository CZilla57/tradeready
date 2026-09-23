import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func fixture(_ name: String) throws -> Data {
    guard let root = ProcessInfo.processInfo.environment["SNAPSHOT_FIXTURES_PATH"] else {
        throw NSError(domain: "SnapshotTests", code: 1)
    }
    return try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name))
}

private func canonicalFixture(_ name: String) throws -> [String: Canonical.JSONValue] {
    guard let root = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"] else {
        throw NSError(domain: "SnapshotTests", code: 3)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name))
    return try JSONDecoder().decode([String: Canonical.JSONValue].self, from: data)
}

private func field<T: Decodable>(_ key: String, in source: [String: Canonical.JSONValue]) throws -> T {
    guard let value = source[key] else { throw NSError(domain: "SnapshotTests", code: 4) }
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func object(_ data: Data) throws -> [String: Canonical.JSONValue] {
    try JSONDecoder().decode([String: Canonical.JSONValue].self, from: data)
}

private func run(_ label: String, _ body: () throws -> Void) {
    do { try body() }
    catch {
        failures += 1
        print("FAIL: \(label) — \(error)")
    }
}

run("legacy flat snapshot upgrades without loss") {
    let snapshot = try Canonical.SnapshotCodec.decode(fixture("legacy-unversioned.json"))
    expect(snapshot.schemaVersion == 0, "legacy input is identified as schema zero")
    expect(snapshot.payload.settings == nil, "legacy explicit null decodes as nil")
    expect(snapshot.payload.customerNotes?["customer-a"] == "Call before arrival", "legacy notes decode")
    expect(snapshot.payload.unknownFields["legacyExtension"] == .object(["enabled": .bool(true)]), "legacy unknown field retained")

    let encoded = try Canonical.SnapshotCodec.encode(snapshot)
    let root = try object(encoded)
    expect(root["schemaVersion"] == .number(1), "legacy encode upgrades to current schema")
    guard case let .object(payload)? = root["payload"] else { throw NSError(domain: "SnapshotTests", code: 2) }
    expect(payload["settings"] == .null, "legacy explicit null survives upgrade")
    expect(payload["legacyExtension"] == .object(["enabled": .bool(true)]), "legacy unknown field survives upgrade")
}

run("current envelope round trip") {
    let input = try fixture("current-versioned.json")
    let snapshot = try Canonical.SnapshotCodec.decode(input)
    expect(snapshot.schemaVersion == Canonical.Snapshot.currentSchemaVersion, "current schema version decodes")
    expect(snapshot.unknownFields["futureEnvelope"] == .null, "unknown envelope null retained")
    expect(snapshot.payload.unknownFields["futurePayload"] == .array([.number(1), .null, .string("retained")]), "unknown payload field retained")

    let encoded = try Canonical.SnapshotCodec.encode(snapshot)
    let encodedObject = try object(encoded)
    let inputObject = try object(input)
    let encodedAgain = try Canonical.SnapshotCodec.encode(snapshot)
    expect(encodedObject == inputObject, "current snapshot semantic JSON round trip")
    expect(encoded == encodedAgain, "encoding is byte deterministic")
}

run("all persisted families remain distinct") {
    let snapshot = try Canonical.SnapshotCodec.decode(fixture("current-versioned.json"))
    let payload = snapshot.payload
    expect(payload.invoices != nil, "invoices family")
    expect(payload.jobs != nil, "jobs family")
    expect(payload.customers != nil, "customers family")
    expect(payload.expenses != nil, "expenses family")
    expect(payload.customerNotes != nil, "customer notes family")
    expect(payload.recurringJobs != nil, "recurring jobs family")
    expect(payload.recurringInvoices != nil, "recurring invoices family")
    expect(payload.trips != nil, "trips family")
    expect(payload.pricebook != nil, "pricebook family")
    expect(payload.bookingRequests != nil, "booking requests family")
    expect(payload.jobPhotos != nil, "job photos family")
    // Settings is present-but-null in this fixture; re-encoding above proves
    // that it is represented independently from absence.
}

run("populated model families round trip") {
    let rich = try canonicalFixture("canonical-rich.json")
    let payload = Canonical.SnapshotPayload(
        invoices: [try field("invoice", in: rich)],
        jobs: [try field("job", in: rich)],
        customers: [try field("customer", in: rich)],
        settings: try field("settings", in: rich),
        expenses: [try field("expense", in: rich)],
        customerNotes: try field("customerNotes", in: rich),
        recurringJobs: [try field("recurringJob", in: rich)],
        recurringInvoices: [try field("recurringInvoice", in: rich)],
        trips: [try field("trip", in: rich)],
        pricebook: [try field("pricebookEntry", in: rich)],
        bookingRequests: [try field("bookingRequest", in: rich)],
        jobPhotos: [try field("jobPhoto", in: rich)]
    )
    let first = Canonical.Snapshot(payload: payload)
    let bytes = try Canonical.SnapshotCodec.encode(first)
    let stored = try object(bytes)
    guard case let .object(storedPayload)? = stored["payload"],
          case let .object(storedSettings)? = storedPayload["settings"] else {
        throw NSError(domain: "SnapshotTests", code: 5)
    }
    expect(Canonical.SnapshotCodec.secureSettingsKeys.allSatisfy { storedSettings[$0] == nil },
           "plain snapshot excludes every secure settings field")
    let second = try Canonical.SnapshotCodec.decode(bytes)
    let secondBytes = try Canonical.SnapshotCodec.encode(second)
    expect(bytes == secondBytes, "populated snapshot is a stable round trip")
    expect(second.payload.invoices?.count == 1 && second.payload.jobs?.count == 1, "primary collections survive")
    expect(second.payload.recurringInvoices?.count == 1 && second.payload.jobPhotos?.count == 1, "auxiliary collections survive")
    expect(second.payload.settings != nil && second.payload.customerNotes?.isEmpty == false, "singleton and map survive")
}

run("missing and malformed envelope version fail clearly") {
    let missing = Data(#"{"payload":{}}"#.utf8)
    do {
        _ = try Canonical.SnapshotCodec.decode(missing)
        expect(false, "missing schema version should fail")
    } catch Canonical.SnapshotError.missingSchemaVersion {}

    let nullPayload = Data(#"{"schemaVersion":1,"payload":null}"#.utf8)
    do {
        _ = try Canonical.SnapshotCodec.decode(nullPayload)
        expect(false, "null payload should fail")
    } catch Canonical.SnapshotError.nullPayload {}
}

run("nested snapshot decoding retains a safe field path") {
    let invalid = Data(#"{"schemaVersion":1,"payload":{"jobs":[{"id":1}]}}"#.utf8)
    do {
        _ = try Canonical.SnapshotCodec.decode(invalid)
        expect(false, "invalid nested field should fail")
    } catch let DecodingError.typeMismatch(_, context) {
        let actualPath = context.codingPath.map(\.stringValue)
        expect(
            actualPath == ["payload", "jobs", "id"],
            "nested decoding path survives snapshot wrappers: \(actualPath)"
        )
    }
}

if failures == 0 {
    print("PASS: native canonical snapshot tests")
} else {
    print("FAILED: \(failures) native canonical snapshot test(s)")
    exit(1)
}
