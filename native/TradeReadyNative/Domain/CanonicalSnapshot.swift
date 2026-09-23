import Foundation

public extension Canonical {
    /// All plain-storage business families captured at one consistency point.
    /// Optional properties intentionally distinguish an absent legacy key from
    /// an explicitly stored null. Repository defaults are applied above this
    /// loss-preserving wire boundary.
    struct SnapshotPayload: Codable {
        public var invoices: [Invoice]?
        public var jobs: [Job]?
        public var customers: [Customer]?
        public var settings: Settings?
        public var expenses: [Expense]?
        public var customerNotes: CustomerNotes?
        public var recurringJobs: [RecurringJob]?
        public var recurringInvoices: [RecurringInvoice]?
        public var trips: [Trip]?
        public var pricebook: [PricebookEntry]?
        public var bookingRequests: [BookingRequest]?
        public var jobPhotos: [JobPhoto]?

        /// Additive fields unknown to this client are emitted unchanged.
        public private(set) var unknownFields: [String: JSONValue]
        private var explicitNullFields: Set<String>

        public init(
            invoices: [Invoice]? = nil,
            jobs: [Job]? = nil,
            customers: [Customer]? = nil,
            settings: Settings? = nil,
            expenses: [Expense]? = nil,
            customerNotes: CustomerNotes? = nil,
            recurringJobs: [RecurringJob]? = nil,
            recurringInvoices: [RecurringInvoice]? = nil,
            trips: [Trip]? = nil,
            pricebook: [PricebookEntry]? = nil,
            bookingRequests: [BookingRequest]? = nil,
            jobPhotos: [JobPhoto]? = nil,
            unknownFields: [String: JSONValue] = [:]
        ) {
            self.invoices = invoices
            self.jobs = jobs
            self.customers = customers
            self.settings = settings
            self.expenses = expenses
            self.customerNotes = customerNotes
            self.recurringJobs = recurringJobs
            self.recurringInvoices = recurringInvoices
            self.trips = trips
            self.pricebook = pricebook
            self.bookingRequests = bookingRequests
            self.jobPhotos = jobPhotos
            self.unknownFields = unknownFields
            self.explicitNullFields = []
        }

        public init(from decoder: Decoder) throws {
            var fields = try [String: JSONValue](from: decoder)
            explicitNullFields = []
            invoices = try Self.take("invoices", from: &fields, nulls: &explicitNullFields)
            jobs = try Self.take("jobs", from: &fields, nulls: &explicitNullFields)
            customers = try Self.take("customers", from: &fields, nulls: &explicitNullFields)
            settings = try Self.take("settings", from: &fields, nulls: &explicitNullFields)
            expenses = try Self.take("expenses", from: &fields, nulls: &explicitNullFields)
            customerNotes = try Self.take("customerNotes", from: &fields, nulls: &explicitNullFields)
            recurringJobs = try Self.take("recurringJobs", from: &fields, nulls: &explicitNullFields)
            recurringInvoices = try Self.take("recurringInvoices", from: &fields, nulls: &explicitNullFields)
            trips = try Self.take("trips", from: &fields, nulls: &explicitNullFields)
            pricebook = try Self.take("pricebook", from: &fields, nulls: &explicitNullFields)
            bookingRequests = try Self.take("bookingRequests", from: &fields, nulls: &explicitNullFields)
            jobPhotos = try Self.take("jobPhotos", from: &fields, nulls: &explicitNullFields)
            unknownFields = fields
        }

        public func encode(to encoder: Encoder) throws {
            var fields = unknownFields
            try Self.put(invoices, key: "invoices", into: &fields, nulls: explicitNullFields)
            try Self.put(jobs, key: "jobs", into: &fields, nulls: explicitNullFields)
            try Self.put(customers, key: "customers", into: &fields, nulls: explicitNullFields)
            try Self.put(settings, key: "settings", into: &fields, nulls: explicitNullFields)
            try Self.put(expenses, key: "expenses", into: &fields, nulls: explicitNullFields)
            try Self.put(customerNotes, key: "customerNotes", into: &fields, nulls: explicitNullFields)
            try Self.put(recurringJobs, key: "recurringJobs", into: &fields, nulls: explicitNullFields)
            try Self.put(recurringInvoices, key: "recurringInvoices", into: &fields, nulls: explicitNullFields)
            try Self.put(trips, key: "trips", into: &fields, nulls: explicitNullFields)
            try Self.put(pricebook, key: "pricebook", into: &fields, nulls: explicitNullFields)
            try Self.put(bookingRequests, key: "bookingRequests", into: &fields, nulls: explicitNullFields)
            try Self.put(jobPhotos, key: "jobPhotos", into: &fields, nulls: explicitNullFields)
            try fields.encode(to: encoder)
        }

        private static func take<T: Decodable>(
            _ key: String,
            from fields: inout [String: JSONValue],
            nulls: inout Set<String>
        ) throws -> T? {
            guard let value = fields.removeValue(forKey: key) else { return nil }
            if case .null = value {
                nulls.insert(key)
                return nil
            }
            return try SnapshotJSON.decode(T.self, from: value, key: key)
        }

        private static func put<T: Encodable>(
            _ value: T?,
            key: String,
            into fields: inout [String: JSONValue],
            nulls: Set<String>
        ) throws {
            if let value {
                fields[key] = try SnapshotJSON.wrap(value)
            } else if nulls.contains(key) {
                fields[key] = .null
            } else {
                fields.removeValue(forKey: key)
            }
        }
    }

    /// Versioned persistence envelope. Decoder compatibility is deliberately
    /// asymmetric: legacy flat snapshots are accepted, while every encode uses
    /// the current envelope shape.
    struct Snapshot: Codable {
        public static let currentSchemaVersion = 1

        public var schemaVersion: Int
        public var payload: SnapshotPayload
        public private(set) var unknownFields: [String: JSONValue]

        public init(
            schemaVersion: Int = currentSchemaVersion,
            payload: SnapshotPayload,
            unknownFields: [String: JSONValue] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.payload = payload
            self.unknownFields = unknownFields
        }

        public init(from decoder: Decoder) throws {
            var fields = try [String: JSONValue](from: decoder)
            if let rawPayload = fields.removeValue(forKey: "payload") {
                guard case .null = rawPayload else {
                    payload = try SnapshotJSON.decode(SnapshotPayload.self, from: rawPayload, key: "payload")
                    guard let rawVersion = fields.removeValue(forKey: "schemaVersion") else {
                        throw SnapshotError.missingSchemaVersion
                    }
                    schemaVersion = try SnapshotJSON.decode(Int.self, from: rawVersion, key: "schemaVersion")
                    unknownFields = fields
                    return
                }
                throw SnapshotError.nullPayload
            }

            // AsyncStorage-era aggregate snapshots were unversioned and flat.
            schemaVersion = 0
            payload = try SnapshotJSON.decode(SnapshotPayload.self, from: .object(fields), key: "legacySnapshot")
            unknownFields = [:]
        }

        public func encode(to encoder: Encoder) throws {
            var fields = unknownFields
            fields["schemaVersion"] = try SnapshotJSON.wrap(
                schemaVersion == 0 ? Self.currentSchemaVersion : schemaVersion
            )
            fields["payload"] = try SnapshotJSON.wrap(payload)
            try fields.encode(to: encoder)
        }
    }

    enum SnapshotError: Error, Equatable {
        case missingSchemaVersion
        case nullPayload
    }

    /// Stable bytes for fixtures, hashing, and atomic repository writes.
    enum SnapshotCodec {
        /// These values belong in Keychain/SecureStore and must never be
        /// serialized into the plain snapshot or synchronized as settings.
        public static let secureSettingsKeys: Set<String> = ["providerKey", "anthropicKey", "groqKey"]

        public static func decode(_ data: Data) throws -> Snapshot {
            try JSONDecoder().decode(Snapshot.self, from: data)
        }

        public static func encode(_ snapshot: Snapshot) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var root = try SnapshotJSON.wrap(snapshot)
            if case var .object(envelope) = root,
               case var .object(payload)? = envelope["payload"],
               case var .object(settings)? = payload["settings"] {
                for key in secureSettingsKeys { settings.removeValue(forKey: key) }
                payload["settings"] = .object(settings)
                envelope["payload"] = .object(payload)
                root = .object(envelope)
            }
            return try encoder.encode(root)
        }
    }
}

private enum SnapshotJSON {
    static func decode<T: Decodable>(_ type: T.Type, from value: Canonical.JSONValue, key: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        } catch {
            throw prefix(error, with: key)
        }
    }

    static func wrap<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
        try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(value))
    }

    private static func prefix(_ error: Error, with key: String) -> Error {
        let prefix = SnapshotCodingKey(stringValue: key)
        switch error {
        case let DecodingError.keyNotFound(missingKey, context):
            return DecodingError.keyNotFound(
                missingKey,
                .init(
                    codingPath: [prefix] + context.codingPath,
                    debugDescription: context.debugDescription,
                    underlyingError: context.underlyingError
                )
            )
        case let DecodingError.valueNotFound(type, context):
            return DecodingError.valueNotFound(
                type,
                .init(
                    codingPath: [prefix] + context.codingPath,
                    debugDescription: context.debugDescription,
                    underlyingError: context.underlyingError
                )
            )
        case let DecodingError.typeMismatch(type, context):
            return DecodingError.typeMismatch(
                type,
                .init(
                    codingPath: [prefix] + context.codingPath,
                    debugDescription: context.debugDescription,
                    underlyingError: context.underlyingError
                )
            )
        case let DecodingError.dataCorrupted(context):
            return DecodingError.dataCorrupted(
                .init(
                    codingPath: [prefix] + context.codingPath,
                    debugDescription: context.debugDescription,
                    underlyingError: context.underlyingError
                )
            )
        default:
            return error
        }
    }

    private struct SnapshotCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }
}
