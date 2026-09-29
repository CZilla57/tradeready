import Foundation

/// Lossless, wire-shaped models shared with `types/models.ts`.
///
/// These types intentionally live below a namespace while the native prototype
/// still has similarly named UI models. Date and time values remain strings: the
/// JavaScript store accepts both calendar dates and full ISO timestamps and a
/// decode/encode cycle must not normalize either representation.
public enum Canonical {}

public extension Canonical {
    typealias JobStatus = String
    typealias TradeId = String
    typealias ExpenseCategoryId = String
    typealias PaymentProvider = String
    typealias DateString = String
    typealias VehicleDeductionMethod = String
    typealias TimeString = String
    typealias JobCostCategory = String
    typealias JobCostMarkupPolicy = String
    typealias InvoiceLineCategory = String
    typealias PaymentMethod = String
    typealias BookingRequestStatus = String
    typealias RecurrenceCadence = String
    typealias RecurrenceEndCondition = String
    typealias CustomerNotes = [String: String]

    /// A JSON value used only for additive fields unknown to this app version.
    /// Decimal avoids converting persisted money through binary floating point.
    enum JSONValue: Codable, Equatable {
        case null
        case bool(Bool)
        case number(Decimal)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
            else if let decoded = try? value.decode(Decimal.self) { self = .number(decoded) }
            else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
            else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
            else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
            else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON value")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case let .bool(decoded): try value.encode(decoded)
            case let .number(decoded): try value.encode(decoded)
            case let .string(decoded): try value.encode(decoded)
            case let .array(decoded): try value.encode(decoded)
            case let .object(decoded): try value.encode(decoded)
            }
        }
    }

    /// Preservation metadata captured while decoding a raw legacy record.
    /// Unknown fields remain public for inspection; explicit nulls are retained
    /// separately so optional absence and optional null round-trip differently.
    struct Preservation: Equatable {
        public var unknownFields: [String: JSONValue]
        fileprivate var explicitNullFields: Set<String>
        /// Required-at-runtime fields that were absent in an older persisted
        /// record. Their decoded defaults stay omitted until the value changes.
        fileprivate var absentDefaultFields: [String: JSONValue]

        public init(unknownFields: [String: JSONValue] = [:]) {
            self.unknownFields = unknownFields
            self.explicitNullFields = []
            self.absentDefaultFields = [:]
        }
    }

    /// Explicit versioning for future canonical persistence. Raw legacy records
    /// continue to decode as their model type and are never mistaken for this.
    struct Envelope<Payload: Codable>: Codable {
        public var schemaVersion: Int
        public var payload: Payload
        public var preservation: Preservation

        public init(schemaVersion: Int = 1, payload: Payload) {
            self.schemaVersion = schemaVersion
            self.payload = payload
            self.preservation = .init()
        }

        public init(from decoder: Decoder) throws {
            var object = try ObjectReader(decoder)
            schemaVersion = try object.required("schemaVersion")
            payload = try object.required("payload")
            preservation = object.finish()
        }

        public func encode(to encoder: Encoder) throws {
            var object = ObjectWriter(preservation)
            try object.put(schemaVersion, for: "schemaVersion")
            try object.put(payload, for: "payload")
            try object.encode(to: encoder)
        }
    }

    /// TypeScript's `number | string`, used by live form-input models.
    enum NumberOrString: Codable, Equatable {
        case number(Decimal)
        case string(String)

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Decimal.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else {
                throw DecodingError.typeMismatch(
                    NumberOrString.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected number or string")
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case let .number(number): try value.encode(number)
            case let .string(string): try value.encode(string)
            }
        }
    }
}

public extension Canonical {
    /// Phase 12 12.00b.2-D (L286.1): the prefix of a native-private record
    /// key. Such a key is local bookkeeping, never shared data. The push
    /// request builder drops it from every outbound body
    /// (`NativeSupabaseMutationPushService`), and decoding drops it from every
    /// record (`ObjectReader.finish`), so one written by an earlier native
    /// build and kept by RN (`utils/syncMerge.ts` returns the remote job
    /// verbatim; `utils/timeTracking.ts` `applyClockOut` spreads the session)
    /// is inert.
    static let nativePrivateKeyPrefix = "__native"
}

public extension Canonical.JSONValue {
    /// This value without any object key that starts with
    /// `Canonical.nativePrivateKeyPrefix`, at any depth. Strings, including
    /// ones that contain the prefix, are never changed.
    func removingNativePrivateFields() -> Canonical.JSONValue {
        switch self {
        case let .object(fields):
            var kept: [String: Canonical.JSONValue] = [:]
            for (key, value) in fields where !key.hasPrefix(Canonical.nativePrivateKeyPrefix) {
                kept[key] = value.removingNativePrivateFields()
            }
            return .object(kept)
        case let .array(values):
            return .array(values.map { $0.removingNativePrivateFields() })
        case .null, .bool, .number, .string:
            return self
        }
    }
}

private extension Canonical.JSONValue {
    func decode<T: Decodable>(_ type: T.Type = T.self, key: String) throws -> T {
        do {
            let data = try JSONEncoder().encode(self)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw prefixCanonicalDecodingError(error, with: key)
        }
    }

    static func wrap<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Canonical.JSONValue.self, from: data)
    }
}

private func prefixCanonicalDecodingError(_ error: Error, with key: String) -> Error {
    let prefix = DynamicCodingKey(key)
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

private struct ObjectReader {
    private var fields: [String: Canonical.JSONValue]
    private var explicitNullFields: Set<String> = []
    private var absentDefaultFields: [String: Canonical.JSONValue] = [:]

    init(_ decoder: Decoder) throws {
        fields = try [String: Canonical.JSONValue](from: decoder)
    }

    mutating func required<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard let value = fields.removeValue(forKey: key) else {
            throw DecodingError.keyNotFound(
                DynamicCodingKey(key),
                .init(codingPath: [], debugDescription: "Missing required key '\(key)'")
            )
        }
        if case .null = value {
            throw DecodingError.valueNotFound(
                type,
                .init(codingPath: [], debugDescription: "Required key '\(key)' is null")
            )
        }
        return try value.decode(type, key: key)
    }

    mutating func optional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let value = fields.removeValue(forKey: key) else { return nil }
        if case .null = value {
            explicitNullFields.insert(key)
            return nil
        }
        return try value.decode(type, key: key)
    }

    mutating func defaulted<T: Codable>(_ key: String, to fallback: T) throws -> T {
        guard let value = fields.removeValue(forKey: key) else {
            absentDefaultFields[key] = try .wrap(fallback)
            return fallback
        }
        if case .null = value {
            absentDefaultFields[key] = try .wrap(fallback)
            return fallback
        }
        return try value.decode(T.self, key: key)
    }

    /// Phase 12 12.00b.2-D (L286.1): native-private keys are never kept. A
    /// record read from disk, a pull or any server response loses every
    /// `Canonical.nativePrivateKeyPrefix` key here, including one nested in
    /// another unknown field, so a stale widget-replay marker decodes, is
    /// inert, and is not written back.
    func finish() -> Canonical.Preservation {
        var kept: [String: Canonical.JSONValue] = [:]
        for (key, value) in fields where !key.hasPrefix(Canonical.nativePrivateKeyPrefix) {
            kept[key] = value.removingNativePrivateFields()
        }
        var result = Canonical.Preservation(unknownFields: kept)
        result.explicitNullFields = explicitNullFields
        result.absentDefaultFields = absentDefaultFields
        return result
    }
}

private struct ObjectWriter {
    private var fields: [String: Canonical.JSONValue]
    private let explicitNullFields: Set<String>
    private let absentDefaultFields: [String: Canonical.JSONValue]

    init(_ preservation: Canonical.Preservation) {
        fields = preservation.unknownFields
        explicitNullFields = preservation.explicitNullFields
        absentDefaultFields = preservation.absentDefaultFields
    }

    mutating func put<T: Encodable>(_ value: T, for key: String) throws {
        fields[key] = try .wrap(value)
    }

    mutating func putOptional<T: Encodable>(_ value: T?, for key: String) throws {
        if let value { fields[key] = try .wrap(value) }
        else if explicitNullFields.contains(key) { fields[key] = .null }
        else { fields.removeValue(forKey: key) }
    }

    mutating func putDefaulted<T: Encodable>(_ value: T, for key: String) throws {
        let wrapped = try Canonical.JSONValue.wrap(value)
        if absentDefaultFields[key] == wrapped { fields.removeValue(forKey: key) }
        else { fields[key] = wrapped }
    }

    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

public extension Canonical {
    struct Material: Codable {
        public var id: String
        public var name: String
        public var quantity: Decimal
        public var unitCost: Decimal
        public var preservation: Preservation

        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); name = try o.required("name")
            quantity = try o.required("quantity"); unitCost = try o.required("unitCost")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(name, for: "name")
            try o.put(quantity, for: "quantity"); try o.put(unitCost, for: "unitCost")
            try o.encode(to: encoder)
        }
    }

    struct TimeSession: Codable {
        public var start: String
        public var end: String?
        public var preservation: Preservation
        public init(start: String, end: String? = nil, preservation: Preservation = .init()) {
            self.start = start
            self.end = end
            self.preservation = preservation
        }
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); start = try o.required("start")
            end = try o.optional("end"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(start, for: "start")
            try o.putOptional(end, for: "end"); try o.encode(to: encoder)
        }
    }

    struct LaborTimeBreakdown: Codable {
        public var onSiteHours, driveHours, supplyRunHours, setupCleanupHours: Decimal
        public var nonBillableNote: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            onSiteHours = try o.required("onSiteHours"); driveHours = try o.required("driveHours")
            supplyRunHours = try o.required("supplyRunHours"); setupCleanupHours = try o.required("setupCleanupHours")
            nonBillableNote = try o.optional("nonBillableNote"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(onSiteHours, for: "onSiteHours"); try o.put(driveHours, for: "driveHours")
            try o.put(supplyRunHours, for: "supplyRunHours"); try o.put(setupCleanupHours, for: "setupCleanupHours")
            try o.putOptional(nonBillableNote, for: "nonBillableNote"); try o.encode(to: encoder)
        }
    }

    struct JobCost: Codable {
        public var id, label: String
        public var category: JobCostCategory
        public var quantity, unitCost, markupPercent: Decimal
        public var markupPolicy: JobCostMarkupPolicy
        public var taxable, customerVisible: Bool
        public var notes: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); label = try o.required("label"); category = try o.required("category")
            quantity = try o.required("quantity"); unitCost = try o.required("unitCost")
            markupPercent = try o.required("markupPercent"); markupPolicy = try o.required("markupPolicy")
            taxable = try o.required("taxable"); customerVisible = try o.required("customerVisible")
            notes = try o.optional("notes"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(label, for: "label"); try o.put(category, for: "category")
            try o.put(quantity, for: "quantity"); try o.put(unitCost, for: "unitCost")
            try o.put(markupPercent, for: "markupPercent"); try o.put(markupPolicy, for: "markupPolicy")
            try o.put(taxable, for: "taxable"); try o.put(customerVisible, for: "customerVisible")
            try o.putOptional(notes, for: "notes"); try o.encode(to: encoder)
        }
    }

    struct JobCostInput: Codable {
        public var id, label: String?
        public var category: JobCostCategory
        public var quantity, unitCost: NumberOrString
        public var markupPercent: NumberOrString?
        public var markupPolicy: JobCostMarkupPolicy
        public var taxable, customerVisible: Bool?
        public var notes: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.optional("id"); label = try o.optional("label"); category = try o.required("category")
            quantity = try o.required("quantity"); unitCost = try o.required("unitCost")
            markupPercent = try o.optional("markupPercent"); markupPolicy = try o.required("markupPolicy")
            taxable = try o.optional("taxable"); customerVisible = try o.optional("customerVisible")
            notes = try o.optional("notes"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.putOptional(id, for: "id"); try o.putOptional(label, for: "label"); try o.put(category, for: "category")
            try o.put(quantity, for: "quantity"); try o.put(unitCost, for: "unitCost")
            try o.putOptional(markupPercent, for: "markupPercent"); try o.put(markupPolicy, for: "markupPolicy")
            try o.putOptional(taxable, for: "taxable"); try o.putOptional(customerVisible, for: "customerVisible")
            try o.putOptional(notes, for: "notes"); try o.encode(to: encoder)
        }
    }

    struct DirectCostLine: Codable {
        public var id: String?
        public var label: String
        public var category: JobCostCategory
        public var amount: Decimal
        public var markupPolicy: JobCostMarkupPolicy
        public var taxable, customerVisible: Bool
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.optional("id"); label = try o.required("label"); category = try o.required("category")
            amount = try o.required("amount"); markupPolicy = try o.required("markupPolicy")
            taxable = try o.required("taxable"); customerVisible = try o.required("customerVisible")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.putOptional(id, for: "id"); try o.put(label, for: "label"); try o.put(category, for: "category")
            try o.put(amount, for: "amount"); try o.put(markupPolicy, for: "markupPolicy")
            try o.put(taxable, for: "taxable"); try o.put(customerVisible, for: "customerVisible")
            try o.encode(to: encoder)
        }
    }

    struct EstimateApprovalSnapshot: Codable {
        public struct LineItem: Codable {
            public var label: String
            public var amount: Decimal
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); label = try o.required("label")
                amount = try o.required("amount"); preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(label, for: "label")
                try o.put(amount, for: "amount"); try o.encode(to: encoder)
            }
        }
        public var businessName, customerName, jobTitle: String
        public var lineItems: [LineItem]
        public var total: Decimal
        public var currency: String
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            businessName = try o.required("businessName"); customerName = try o.required("customerName")
            jobTitle = try o.required("jobTitle"); lineItems = try o.required("lineItems")
            total = try o.required("total"); currency = try o.required("currency"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(businessName, for: "businessName"); try o.put(customerName, for: "customerName")
            try o.put(jobTitle, for: "jobTitle"); try o.put(lineItems, for: "lineItems")
            try o.put(total, for: "total"); try o.put(currency, for: "currency"); try o.encode(to: encoder)
        }
    }

    struct EstimateApproval: Codable {
        public var token: String
        public var sentAt: DateString
        public var snapshot: EstimateApprovalSnapshot
        public var decision, signerName, declineReason, ip, userAgent: String?
        public var consentAt: DateString?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            token = try o.required("token"); sentAt = try o.required("sentAt"); snapshot = try o.required("snapshot")
            decision = try o.optional("decision"); consentAt = try o.optional("consentAt")
            signerName = try o.optional("signerName"); declineReason = try o.optional("declineReason")
            ip = try o.optional("ip"); userAgent = try o.optional("userAgent"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(token, for: "token"); try o.put(sentAt, for: "sentAt"); try o.put(snapshot, for: "snapshot")
            try o.putOptional(decision, for: "decision"); try o.putOptional(consentAt, for: "consentAt")
            try o.putOptional(signerName, for: "signerName"); try o.putOptional(declineReason, for: "declineReason")
            try o.putOptional(ip, for: "ip"); try o.putOptional(userAgent, for: "userAgent"); try o.encode(to: encoder)
        }
    }

    struct ChangeOrderDecision: Codable {
        public var decision: String
        public var decidedAt: DateString
        public var note: String?
        public var preservation: Preservation
        public init(
            decision: String,
            decidedAt: DateString,
            note: String? = nil,
            preservation: Preservation = .init()
        ) {
            self.decision = decision
            self.decidedAt = decidedAt
            self.note = note
            self.preservation = preservation
        }
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); decision = try o.required("decision")
            decidedAt = try o.required("decidedAt"); note = try o.optional("note"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(decision, for: "decision")
            try o.put(decidedAt, for: "decidedAt"); try o.putOptional(note, for: "note"); try o.encode(to: encoder)
        }
    }

    struct ChangeOrder: Codable {
        public var id, title: String
        public var description: String?
        public var amount: Decimal
        public var createdAt: DateString
        public var approval: EstimateApproval?
        public var manualDecision: ChangeOrderDecision?
        public var cancelledAt: DateString?
        public var preservation: Preservation
        public init(
            id: String,
            title: String,
            description: String? = nil,
            amount: Decimal,
            createdAt: DateString,
            approval: EstimateApproval? = nil,
            manualDecision: ChangeOrderDecision? = nil,
            cancelledAt: DateString? = nil,
            preservation: Preservation = .init()
        ) {
            self.id = id
            self.title = title
            self.description = description
            self.amount = amount
            self.createdAt = createdAt
            self.approval = approval
            self.manualDecision = manualDecision
            self.cancelledAt = cancelledAt
            self.preservation = preservation
        }
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); title = try o.required("title"); description = try o.optional("description")
            amount = try o.required("amount"); createdAt = try o.required("createdAt")
            approval = try o.optional("approval"); manualDecision = try o.optional("manualDecision")
            cancelledAt = try o.optional("cancelledAt"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(title, for: "title"); try o.putOptional(description, for: "description")
            try o.put(amount, for: "amount"); try o.put(createdAt, for: "createdAt")
            try o.putOptional(approval, for: "approval"); try o.putOptional(manualDecision, for: "manualDecision")
            try o.putOptional(cancelledAt, for: "cancelledAt"); try o.encode(to: encoder)
        }
    }
}

public extension Canonical {
    struct Job: Codable {
        public var id, customerId, customerName, title, description: String
        public var status: JobStatus
        public var scheduledDate: DateString?
        public var scheduledStartTime, scheduledEndTime: TimeString?
        public var address: String
        public var estimateTotal, laborHours: Decimal
        public var laborBreakdown: LaborTimeBreakdown?
        public var laborRate: Decimal
        public var materials: [Material]
        public var materialMarkup: Decimal
        public var jobCosts: [JobCost]?
        public var overhead, margin: Decimal
        public var notes: String
        public var invoiceId: String?
        public var createdAt: DateString
        public var photos: [String]?
        public var timeSessions: [TimeSession]?
        public var recurringJobId: String?
        public var occurrenceNumber: Int?
        public var estimateSentAt: DateString?
        public var approval: EstimateApproval?
        public var approvalHistory: [EstimateApproval]?
        public var changeOrders: [ChangeOrder]?
        public var archivedAt: DateString?
        public var importBatchId: String?
        public var preservation: Preservation

        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); customerId = try o.required("customerId")
            customerName = try o.required("customerName"); title = try o.required("title")
            description = try o.required("description"); status = try o.required("status")
            scheduledDate = try o.optional("scheduledDate")
            scheduledStartTime = try o.optional("scheduledStartTime"); scheduledEndTime = try o.optional("scheduledEndTime")
            address = try o.required("address"); estimateTotal = try o.required("estimateTotal")
            laborHours = try o.required("laborHours"); laborBreakdown = try o.optional("laborBreakdown")
            laborRate = try o.required("laborRate"); materials = try o.required("materials")
            materialMarkup = try o.required("materialMarkup"); jobCosts = try o.optional("jobCosts")
            overhead = try o.required("overhead"); margin = try o.required("margin"); notes = try o.required("notes")
            invoiceId = try o.optional("invoiceId"); createdAt = try o.required("createdAt")
            photos = try o.optional("photos"); timeSessions = try o.optional("timeSessions")
            recurringJobId = try o.optional("recurringJobId"); occurrenceNumber = try o.optional("occurrenceNumber")
            estimateSentAt = try o.optional("estimateSentAt"); approval = try o.optional("approval")
            approvalHistory = try o.optional("approvalHistory")
            changeOrders = try o.optional("changeOrders"); archivedAt = try o.optional("archivedAt")
            importBatchId = try o.optional("importBatchId"); preservation = o.finish()
        }

        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(customerId, for: "customerId")
            try o.put(customerName, for: "customerName"); try o.put(title, for: "title")
            try o.put(description, for: "description"); try o.put(status, for: "status")
            try o.putOptional(scheduledDate, for: "scheduledDate")
            try o.putOptional(scheduledStartTime, for: "scheduledStartTime"); try o.putOptional(scheduledEndTime, for: "scheduledEndTime")
            try o.put(address, for: "address"); try o.put(estimateTotal, for: "estimateTotal")
            try o.put(laborHours, for: "laborHours"); try o.putOptional(laborBreakdown, for: "laborBreakdown")
            try o.put(laborRate, for: "laborRate"); try o.put(materials, for: "materials")
            try o.put(materialMarkup, for: "materialMarkup"); try o.putOptional(jobCosts, for: "jobCosts")
            try o.put(overhead, for: "overhead"); try o.put(margin, for: "margin"); try o.put(notes, for: "notes")
            try o.putOptional(invoiceId, for: "invoiceId"); try o.put(createdAt, for: "createdAt")
            try o.putOptional(photos, for: "photos"); try o.putOptional(timeSessions, for: "timeSessions")
            try o.putOptional(recurringJobId, for: "recurringJobId"); try o.putOptional(occurrenceNumber, for: "occurrenceNumber")
            try o.putOptional(estimateSentAt, for: "estimateSentAt"); try o.putOptional(approval, for: "approval")
            try o.putOptional(approvalHistory, for: "approvalHistory")
            try o.putOptional(changeOrders, for: "changeOrders"); try o.putOptional(archivedAt, for: "archivedAt")
            try o.putOptional(importBatchId, for: "importBatchId"); try o.encode(to: encoder)
        }
    }

    struct JobPhoto: Codable {
        public var id, jobId, createdAt: String
        public var uploadedAt: String?
        public var customerVisible: Bool?
        public var width, height: Decimal?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); jobId = try o.required("jobId"); createdAt = try o.required("createdAt")
            uploadedAt = try o.optional("uploadedAt"); customerVisible = try o.optional("customerVisible")
            width = try o.optional("width"); height = try o.optional("height"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(jobId, for: "jobId"); try o.put(createdAt, for: "createdAt")
            try o.putOptional(uploadedAt, for: "uploadedAt"); try o.putOptional(customerVisible, for: "customerVisible")
            try o.putOptional(width, for: "width"); try o.putOptional(height, for: "height"); try o.encode(to: encoder)
        }
    }

    struct PricebookEntry: Codable {
        public var id, name: String
        public var description, category: String?
        public var laborHours: Decimal
        public var laborBreakdown: LaborTimeBreakdown?
        public var laborRate: Decimal
        public var materials: [Material]
        public var materialMarkup: Decimal
        public var jobCosts: [JobCost]?
        public var overhead, margin, estimateTotal: Decimal
        public var createdAt, updatedAt: String
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); name = try o.required("name")
            description = try o.optional("description"); category = try o.optional("category")
            laborHours = try o.required("laborHours"); laborBreakdown = try o.optional("laborBreakdown")
            laborRate = try o.required("laborRate"); materials = try o.required("materials")
            materialMarkup = try o.required("materialMarkup"); jobCosts = try o.optional("jobCosts")
            overhead = try o.required("overhead"); margin = try o.required("margin")
            estimateTotal = try o.required("estimateTotal"); createdAt = try o.required("createdAt")
            updatedAt = try o.required("updatedAt"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(name, for: "name")
            try o.putOptional(description, for: "description"); try o.putOptional(category, for: "category")
            try o.put(laborHours, for: "laborHours"); try o.putOptional(laborBreakdown, for: "laborBreakdown")
            try o.put(laborRate, for: "laborRate"); try o.put(materials, for: "materials")
            try o.put(materialMarkup, for: "materialMarkup"); try o.putOptional(jobCosts, for: "jobCosts")
            try o.put(overhead, for: "overhead"); try o.put(margin, for: "margin")
            try o.put(estimateTotal, for: "estimateTotal"); try o.put(createdAt, for: "createdAt")
            try o.put(updatedAt, for: "updatedAt"); try o.encode(to: encoder)
        }
    }

    struct AIPricingSuggestion: Codable {
        public struct SuggestedValue: Codable {
            public var suggested: Decimal
            public var reasoning: String
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); suggested = try o.required("suggested")
                reasoning = try o.required("reasoning"); preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(suggested, for: "suggested")
                try o.put(reasoning, for: "reasoning"); try o.encode(to: encoder)
            }
        }
        public struct SuggestedMaterial: Codable {
            public var name: String
            public var suggestedUnitCost: Decimal
            public var reasoning: String
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); name = try o.required("name")
                suggestedUnitCost = try o.required("suggestedUnitCost"); reasoning = try o.required("reasoning")
                preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(name, for: "name")
                try o.put(suggestedUnitCost, for: "suggestedUnitCost"); try o.put(reasoning, for: "reasoning")
                try o.encode(to: encoder)
            }
        }
        public struct OverallRange: Codable {
            public var low, mid, high: Decimal
            public var reasoning: String
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); low = try o.required("low"); mid = try o.required("mid")
                high = try o.required("high"); reasoning = try o.required("reasoning"); preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(low, for: "low"); try o.put(mid, for: "mid")
                try o.put(high, for: "high"); try o.put(reasoning, for: "reasoning"); try o.encode(to: encoder)
            }
        }
        public var laborHours, laborRate: SuggestedValue?
        public var materials: [SuggestedMaterial]?
        public var overallRange: OverallRange?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            laborHours = try o.optional("laborHours"); laborRate = try o.optional("laborRate")
            materials = try o.optional("materials"); overallRange = try o.optional("overallRange")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.putOptional(laborHours, for: "laborHours"); try o.putOptional(laborRate, for: "laborRate")
            try o.putOptional(materials, for: "materials"); try o.putOptional(overallRange, for: "overallRange")
            try o.encode(to: encoder)
        }
    }

    struct InvoiceLineItem: Codable {
        public var description: String
        public var amount: Decimal
        public var category: InvoiceLineCategory
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); description = try o.required("description")
            amount = try o.required("amount"); category = try o.required("category"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(description, for: "description")
            try o.put(amount, for: "amount"); try o.put(category, for: "category"); try o.encode(to: encoder)
        }
    }

    struct Payment: Codable {
        public var id: String
        public var amount: Decimal
        public var date: DateString
        public var method: PaymentMethod
        public var note, stripeSessionId: String?
        public var voidedAt: DateString?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); amount = try o.required("amount")
            date = try o.required("date"); method = try o.required("method"); note = try o.optional("note")
            stripeSessionId = try o.optional("stripeSessionId"); voidedAt = try o.optional("voidedAt"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(amount, for: "amount")
            try o.put(date, for: "date"); try o.put(method, for: "method"); try o.putOptional(note, for: "note")
            try o.putOptional(stripeSessionId, for: "stripeSessionId"); try o.putOptional(voidedAt, for: "voidedAt")
            try o.encode(to: encoder)
        }
    }

    struct PaymentDraft: Codable {
        public var amount: Decimal
        public var date: DateString
        public var method: PaymentMethod
        public var note: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); amount = try o.required("amount"); date = try o.required("date")
            method = try o.required("method"); note = try o.optional("note"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(amount, for: "amount"); try o.put(date, for: "date")
            try o.put(method, for: "method"); try o.putOptional(note, for: "note"); try o.encode(to: encoder)
        }
    }

    struct DepositRequest: Codable {
        public var amount: Decimal
        public var percent: Decimal?
        public var requestedAt: DateString
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); amount = try o.required("amount"); percent = try o.optional("percent")
            requestedAt = try o.required("requestedAt"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(amount, for: "amount"); try o.putOptional(percent, for: "percent")
            try o.put(requestedAt, for: "requestedAt"); try o.encode(to: encoder)
        }
    }
}

public extension Canonical {
    struct Invoice: Codable {
        public var id, customer: String
        public var customerId: String?
        public var number: String
        public var amount: Decimal
        public var due: DateString
        public var email, phone, desc: String
        public var paid: Bool
        public var paidAt: DateString?
        public var payments: [Payment]?
        public var depositRequest: DepositRequest?
        public var paymentLinkUrl: String?
        public var paymentLinkAmount: Decimal?
        public var autoEmailRequestedAt: String?
        public var lineItems: [InvoiceLineItem]?
        public var jobId, recurringInvoiceId: String?
        public var occurrenceNumber: Int?
        public var importBatchId: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            id = try o.required("id"); customer = try o.required("customer"); customerId = try o.optional("customerId")
            number = try o.required("number"); amount = try o.required("amount"); due = try o.required("due")
            email = try o.required("email"); phone = try o.required("phone"); desc = try o.required("desc")
            paid = try o.required("paid"); paidAt = try o.optional("paidAt"); payments = try o.optional("payments")
            depositRequest = try o.optional("depositRequest"); paymentLinkUrl = try o.optional("paymentLinkUrl")
            paymentLinkAmount = try o.optional("paymentLinkAmount"); autoEmailRequestedAt = try o.optional("autoEmailRequestedAt")
            lineItems = try o.optional("lineItems"); jobId = try o.optional("jobId")
            recurringInvoiceId = try o.optional("recurringInvoiceId"); occurrenceNumber = try o.optional("occurrenceNumber")
            importBatchId = try o.optional("importBatchId"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(id, for: "id"); try o.put(customer, for: "customer"); try o.putOptional(customerId, for: "customerId")
            try o.put(number, for: "number"); try o.put(amount, for: "amount"); try o.put(due, for: "due")
            try o.put(email, for: "email"); try o.put(phone, for: "phone"); try o.put(desc, for: "desc")
            try o.put(paid, for: "paid"); try o.putOptional(paidAt, for: "paidAt"); try o.putOptional(payments, for: "payments")
            try o.putOptional(depositRequest, for: "depositRequest"); try o.putOptional(paymentLinkUrl, for: "paymentLinkUrl")
            try o.putOptional(paymentLinkAmount, for: "paymentLinkAmount"); try o.putOptional(autoEmailRequestedAt, for: "autoEmailRequestedAt")
            try o.putOptional(lineItems, for: "lineItems"); try o.putOptional(jobId, for: "jobId")
            try o.putOptional(recurringInvoiceId, for: "recurringInvoiceId"); try o.putOptional(occurrenceNumber, for: "occurrenceNumber")
            try o.putOptional(importBatchId, for: "importBatchId"); try o.encode(to: encoder)
        }
    }

    struct Customer: Codable {
        public struct Portal: Codable {
            public var token: String
            public var enabled: Bool
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); token = try o.required("token")
                enabled = try o.required("enabled"); preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(token, for: "token")
                try o.put(enabled, for: "enabled"); try o.encode(to: encoder)
            }
        }
        public var id, name, email, phone, address, notes: String
        public var createdAt: DateString?
        public var portal: Portal?
        public var archivedAt: DateString?
        public var importBatchId: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); name = try o.required("name")
            email = try o.required("email"); phone = try o.required("phone"); address = try o.required("address")
            notes = try o.required("notes"); createdAt = try o.optional("createdAt"); portal = try o.optional("portal")
            archivedAt = try o.optional("archivedAt"); importBatchId = try o.optional("importBatchId"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(name, for: "name")
            try o.put(email, for: "email"); try o.put(phone, for: "phone"); try o.put(address, for: "address")
            try o.put(notes, for: "notes"); try o.putOptional(createdAt, for: "createdAt"); try o.putOptional(portal, for: "portal")
            try o.putOptional(archivedAt, for: "archivedAt"); try o.putOptional(importBatchId, for: "importBatchId")
            try o.encode(to: encoder)
        }
    }

    struct Expense: Codable {
        public var id: String
        public var createdAt: DateString
        public var description: String
        public var amount: Decimal
        public var category: ExpenseCategoryId
        public var date: DateString
        public var notes: String
        public var receiptUri: String?
        public var jobId, importBatchId: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); createdAt = try o.required("createdAt")
            description = try o.required("description"); amount = try o.required("amount")
            category = try o.required("category"); date = try o.required("date"); notes = try o.required("notes")
            receiptUri = try o.optional("receiptUri"); jobId = try o.optional("jobId")
            importBatchId = try o.optional("importBatchId"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(createdAt, for: "createdAt")
            try o.put(description, for: "description"); try o.put(amount, for: "amount")
            try o.put(category, for: "category"); try o.put(date, for: "date"); try o.put(notes, for: "notes")
            try o.putOptional(receiptUri, for: "receiptUri"); try o.putOptional(jobId, for: "jobId")
            try o.putOptional(importBatchId, for: "importBatchId"); try o.encode(to: encoder)
        }
    }

    struct ExpenseDraft: Codable {
        public var description: String
        public var amount: Decimal
        public var category: ExpenseCategoryId
        public var date: DateString
        public var notes: String
        public var receiptUri: String?
        public var jobId, importBatchId: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); description = try o.required("description")
            amount = try o.required("amount"); category = try o.required("category"); date = try o.required("date")
            notes = try o.required("notes"); receiptUri = try o.optional("receiptUri")
            jobId = try o.optional("jobId"); importBatchId = try o.optional("importBatchId"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(description, for: "description")
            try o.put(amount, for: "amount"); try o.put(category, for: "category"); try o.put(date, for: "date")
            try o.put(notes, for: "notes"); try o.putOptional(receiptUri, for: "receiptUri")
            try o.putOptional(jobId, for: "jobId"); try o.putOptional(importBatchId, for: "importBatchId")
            try o.encode(to: encoder)
        }
    }

    struct Trip: Codable {
        public var id: String
        public var date: DateString
        public var odometerStart, odometerEnd, miles: Decimal
        public var fromJobId: String?
        public var fromLabel: String
        public var toJobId: String?
        public var toLabel, purpose: String
        public var createdAt: DateString
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); date = try o.required("date")
            odometerStart = try o.required("odometerStart"); odometerEnd = try o.required("odometerEnd")
            miles = try o.required("miles"); fromJobId = try o.optional("fromJobId"); fromLabel = try o.required("fromLabel")
            toJobId = try o.optional("toJobId"); toLabel = try o.required("toLabel"); purpose = try o.required("purpose")
            createdAt = try o.required("createdAt"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(date, for: "date")
            try o.put(odometerStart, for: "odometerStart"); try o.put(odometerEnd, for: "odometerEnd")
            try o.put(miles, for: "miles"); try o.putOptional(fromJobId, for: "fromJobId"); try o.put(fromLabel, for: "fromLabel")
            try o.putOptional(toJobId, for: "toJobId"); try o.put(toLabel, for: "toLabel"); try o.put(purpose, for: "purpose")
            try o.put(createdAt, for: "createdAt"); try o.encode(to: encoder)
        }
    }

    struct BookingHistoryEntry: Codable {
        public var at, actor, event: String
        public var note: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); at = try o.required("at"); actor = try o.required("actor")
            event = try o.required("event"); note = try o.optional("note"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(at, for: "at"); try o.put(actor, for: "actor")
            try o.put(event, for: "event"); try o.putOptional(note, for: "note"); try o.encode(to: encoder)
        }
    }

    struct BookingRequest: Codable {
        public struct Slot: Codable {
            public var date: DateString
            public var start, end: TimeString
            public var timeZone, startUtc, endUtc: String
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); date = try o.required("date"); start = try o.required("start")
                end = try o.required("end"); timeZone = try o.required("timeZone"); startUtc = try o.required("startUtc")
                endUtc = try o.required("endUtc"); preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(date, for: "date"); try o.put(start, for: "start")
                try o.put(end, for: "end"); try o.put(timeZone, for: "timeZone"); try o.put(startUtc, for: "startUtc")
                try o.put(endUtc, for: "endUtc"); try o.encode(to: encoder)
            }
        }
        public var id: String
        public var status: BookingRequestStatus
        public var name, phone, email, address, details, preferredTiming, createdAt: String
        public var convertedJobId, convertedCustomerId, kind: String?
        public var slot: Slot?
        public var manageToken: String?
        public var history: [BookingHistoryEntry]?
        public var source, sourceCustomerId, jobRef, portalKind, handledAt: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); status = try o.required("status")
            name = try o.required("name"); phone = try o.required("phone"); email = try o.required("email")
            address = try o.required("address"); details = try o.required("details")
            preferredTiming = try o.required("preferredTiming"); createdAt = try o.required("createdAt")
            convertedJobId = try o.optional("convertedJobId"); convertedCustomerId = try o.optional("convertedCustomerId")
            kind = try o.optional("kind"); slot = try o.optional("slot"); manageToken = try o.optional("manageToken")
            history = try o.optional("history"); source = try o.optional("source"); sourceCustomerId = try o.optional("sourceCustomerId")
            jobRef = try o.optional("jobRef"); portalKind = try o.optional("portalKind"); handledAt = try o.optional("handledAt")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(status, for: "status")
            try o.put(name, for: "name"); try o.put(phone, for: "phone"); try o.put(email, for: "email")
            try o.put(address, for: "address"); try o.put(details, for: "details")
            try o.put(preferredTiming, for: "preferredTiming"); try o.put(createdAt, for: "createdAt")
            try o.putOptional(convertedJobId, for: "convertedJobId"); try o.putOptional(convertedCustomerId, for: "convertedCustomerId")
            try o.putOptional(kind, for: "kind"); try o.putOptional(slot, for: "slot"); try o.putOptional(manageToken, for: "manageToken")
            try o.putOptional(history, for: "history"); try o.putOptional(source, for: "source")
            try o.putOptional(sourceCustomerId, for: "sourceCustomerId"); try o.putOptional(jobRef, for: "jobRef")
            try o.putOptional(portalKind, for: "portalKind"); try o.putOptional(handledAt, for: "handledAt")
            try o.encode(to: encoder)
        }
    }
}

public extension Canonical {
    struct ReminderRule: Codable {
        public var days: Int
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); days = try o.required("days"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(days, for: "days"); try o.encode(to: encoder)
        }
    }

    /// Discriminated union from `PaymentPlan`; false plans reject enabled-only
    /// fields when read by consumers but retain them if a future writer adds any.
    struct PaymentPlan: Codable {
        public var enabled: Bool
        public var installments: NumberOrString?
        public var frequency: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); enabled = try o.required("enabled")
            installments = try o.optional("installments"); frequency = try o.optional("frequency")
            if enabled, installments == nil {
                throw DecodingError.keyNotFound(DynamicCodingKey("installments"), .init(codingPath: decoder.codingPath, debugDescription: "Enabled payment plan requires installments"))
            }
            if enabled, frequency == nil {
                throw DecodingError.keyNotFound(DynamicCodingKey("frequency"), .init(codingPath: decoder.codingPath, debugDescription: "Enabled payment plan requires frequency"))
            }
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(enabled, for: "enabled")
            try o.putOptional(installments, for: "installments"); try o.putOptional(frequency, for: "frequency")
            try o.encode(to: encoder)
        }
    }

    struct RecurringJob: Codable {
        public var id, customerId, customerName, title, description, address, notes: String
        public var estimateTotal, laborHours, laborRate: Decimal
        public var materials: [Material]
        public var materialMarkup: Decimal
        public var jobCosts: [JobCost]?
        public var overhead, margin: Decimal
        public var cadence: RecurrenceCadence
        public var endCondition: RecurrenceEndCondition
        public var endCount: Int?
        public var endDate: DateString?
        public var occurrenceCount: Int
        public var lastGeneratedDate: DateString?
        public var nextDueDate: DateString
        public var isActive: Bool
        public var createdAt: DateString
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); customerId = try o.required("customerId")
            customerName = try o.required("customerName"); title = try o.required("title"); description = try o.required("description")
            address = try o.required("address"); notes = try o.required("notes"); estimateTotal = try o.required("estimateTotal")
            laborHours = try o.required("laborHours"); laborRate = try o.required("laborRate"); materials = try o.required("materials")
            materialMarkup = try o.required("materialMarkup"); jobCosts = try o.optional("jobCosts")
            overhead = try o.required("overhead"); margin = try o.required("margin"); cadence = try o.required("cadence")
            endCondition = try o.required("endCondition"); endCount = try o.optional("endCount"); endDate = try o.optional("endDate")
            occurrenceCount = try o.required("occurrenceCount"); lastGeneratedDate = try o.optional("lastGeneratedDate")
            nextDueDate = try o.required("nextDueDate"); isActive = try o.required("isActive"); createdAt = try o.required("createdAt")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(customerId, for: "customerId")
            try o.put(customerName, for: "customerName"); try o.put(title, for: "title"); try o.put(description, for: "description")
            try o.put(address, for: "address"); try o.put(notes, for: "notes"); try o.put(estimateTotal, for: "estimateTotal")
            try o.put(laborHours, for: "laborHours"); try o.put(laborRate, for: "laborRate"); try o.put(materials, for: "materials")
            try o.put(materialMarkup, for: "materialMarkup"); try o.putOptional(jobCosts, for: "jobCosts")
            try o.put(overhead, for: "overhead"); try o.put(margin, for: "margin"); try o.put(cadence, for: "cadence")
            try o.put(endCondition, for: "endCondition"); try o.putOptional(endCount, for: "endCount"); try o.putOptional(endDate, for: "endDate")
            try o.put(occurrenceCount, for: "occurrenceCount"); try o.putOptional(lastGeneratedDate, for: "lastGeneratedDate")
            try o.put(nextDueDate, for: "nextDueDate"); try o.put(isActive, for: "isActive"); try o.put(createdAt, for: "createdAt")
            try o.encode(to: encoder)
        }
    }

    struct RecurringInvoice: Codable {
        public var id, customerId, customerName, description: String
        public var amount: Decimal
        public var dueDays: Int
        public var cadence: RecurrenceCadence
        public var endCondition: RecurrenceEndCondition
        public var endCount: Int?
        public var endDate: DateString?
        public var occurrenceCount: Int
        public var lastGeneratedDate: DateString?
        public var nextDueDate: DateString
        public var isActive: Bool
        public var createdAt: DateString
        public var autoSendEnabled: Bool?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); customerId = try o.required("customerId")
            customerName = try o.required("customerName"); description = try o.required("description"); amount = try o.required("amount")
            dueDays = try o.required("dueDays"); cadence = try o.required("cadence"); endCondition = try o.required("endCondition")
            endCount = try o.optional("endCount"); endDate = try o.optional("endDate"); occurrenceCount = try o.required("occurrenceCount")
            lastGeneratedDate = try o.optional("lastGeneratedDate"); nextDueDate = try o.required("nextDueDate")
            isActive = try o.required("isActive"); createdAt = try o.required("createdAt")
            autoSendEnabled = try o.optional("autoSendEnabled"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(customerId, for: "customerId")
            try o.put(customerName, for: "customerName"); try o.put(description, for: "description"); try o.put(amount, for: "amount")
            try o.put(dueDays, for: "dueDays"); try o.put(cadence, for: "cadence"); try o.put(endCondition, for: "endCondition")
            try o.putOptional(endCount, for: "endCount"); try o.putOptional(endDate, for: "endDate"); try o.put(occurrenceCount, for: "occurrenceCount")
            try o.putOptional(lastGeneratedDate, for: "lastGeneratedDate"); try o.put(nextDueDate, for: "nextDueDate")
            try o.put(isActive, for: "isActive"); try o.put(createdAt, for: "createdAt")
            try o.putOptional(autoSendEnabled, for: "autoSendEnabled"); try o.encode(to: encoder)
        }
    }

    struct ScheduleBlackout: Codable {
        public var id: String
        public var start, end: DateString
        public var reason: String?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.required("id"); start = try o.required("start")
            end = try o.required("end"); reason = try o.optional("reason"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(id, for: "id"); try o.put(start, for: "start")
            try o.put(end, for: "end"); try o.putOptional(reason, for: "reason"); try o.encode(to: encoder)
        }
    }

    struct ScheduleConfig: Codable {
        public var timeZone: String?
        public var workDays: [Int]?
        public var workDayStart, workDayEnd: TimeString?
        public var defaultDurationMinutes, bufferMinutes, slotLeadHours, slotWindowDays: Int?
        public var blackouts: [ScheduleBlackout]?
        public var bookableSlotsEnabled: Bool?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); timeZone = try o.optional("timeZone"); workDays = try o.optional("workDays")
            workDayStart = try o.optional("workDayStart"); workDayEnd = try o.optional("workDayEnd")
            defaultDurationMinutes = try o.optional("defaultDurationMinutes"); bufferMinutes = try o.optional("bufferMinutes")
            slotLeadHours = try o.optional("slotLeadHours"); slotWindowDays = try o.optional("slotWindowDays")
            blackouts = try o.optional("blackouts"); bookableSlotsEnabled = try o.optional("bookableSlotsEnabled")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.putOptional(timeZone, for: "timeZone"); try o.putOptional(workDays, for: "workDays")
            try o.putOptional(workDayStart, for: "workDayStart"); try o.putOptional(workDayEnd, for: "workDayEnd")
            try o.putOptional(defaultDurationMinutes, for: "defaultDurationMinutes"); try o.putOptional(bufferMinutes, for: "bufferMinutes")
            try o.putOptional(slotLeadHours, for: "slotLeadHours"); try o.putOptional(slotWindowDays, for: "slotWindowDays")
            try o.putOptional(blackouts, for: "blackouts"); try o.putOptional(bookableSlotsEnabled, for: "bookableSlotsEnabled")
            try o.encode(to: encoder)
        }
    }
}

public extension Canonical {
    struct Settings: Codable {
        public struct BookingLink: Codable {
            public var token: String
            public var enabled: Bool
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); token = try o.required("token")
                enabled = try o.required("enabled"); preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(token, for: "token")
                try o.put(enabled, for: "enabled"); try o.encode(to: encoder)
            }
        }

        public struct PushToken: Codable {
            public var token, platform, updatedAt: String
            public var preservation: Preservation
            public init(from decoder: Decoder) throws {
                var o = try ObjectReader(decoder); token = try o.required("token")
                platform = try o.required("platform"); updatedAt = try o.required("updatedAt")
                preservation = o.finish()
            }
            public func encode(to encoder: Encoder) throws {
                var o = ObjectWriter(preservation); try o.put(token, for: "token")
                try o.put(platform, for: "platform"); try o.put(updatedAt, for: "updatedAt")
                try o.encode(to: encoder)
            }
        }

        public var businessName, contactName, phone, email, address: String
        public var region, logoPhoto: String?
        public var trade: TradeId
        public var laborRate: Decimal
        public var laborCostRate: Decimal?
        public var materialMarkup, overheadPercent, marginPercent, minimumJobFee: Decimal
        public var travelFeePerMile, emergencyMultiplier, mileageRate: Decimal
        public var taxIncomeRate: Decimal?
        public var vehicleDeductionMethod: VehicleDeductionMethod?
        public var bookingLink: BookingLink?
        public var pushToken: PushToken?
        public var schedule: ScheduleConfig?
        public var invoicePrefix: String?
        public var invoiceStartNumber: Int?
        public var paymentNotes: String
        public var provider: PaymentProvider
        public var providerKey: String
        public var providerKeys: [String: String]
        public var rules: [ReminderRule]
        public var autoOutreachEnabled, autoSendEmailEnabled, appointmentRemindersEnabled: Bool
        public var appointmentConfirmTemplate, onMyWayTemplate: String
        public var estimateFollowUpsEnabled, autoInvoiceOnComplete, autoEmailInvoiceOnComplete: Bool
        public var autoSendRecurringInvoicesEnabled: Bool?
        public var anthropicKey, groqKey: String
        public var reviewRequestEnabled: Bool
        public var reviewRequestTemplate, googleReviewLink: String
        public var reviewRequestDelayHours: Int
        public var preservation: Preservation

        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder)
            businessName = try o.required("businessName"); contactName = try o.required("contactName")
            phone = try o.required("phone"); email = try o.required("email"); address = try o.required("address")
            region = try o.optional("region"); logoPhoto = try o.optional("logoPhoto"); trade = try o.required("trade")
            laborRate = try o.required("laborRate"); laborCostRate = try o.optional("laborCostRate")
            materialMarkup = try o.required("materialMarkup"); overheadPercent = try o.required("overheadPercent")
            marginPercent = try o.required("marginPercent"); minimumJobFee = try o.required("minimumJobFee")
            travelFeePerMile = try o.required("travelFeePerMile"); emergencyMultiplier = try o.required("emergencyMultiplier")
            mileageRate = try o.defaulted("mileageRate", to: Decimal(string: "0.70")!); taxIncomeRate = try o.optional("taxIncomeRate")
            vehicleDeductionMethod = try o.optional("vehicleDeductionMethod"); bookingLink = try o.optional("bookingLink")
            pushToken = try o.optional("pushToken"); schedule = try o.optional("schedule")
            invoicePrefix = try o.optional("invoicePrefix"); invoiceStartNumber = try o.optional("invoiceStartNumber")
            paymentNotes = try o.required("paymentNotes"); provider = try o.required("provider")
            providerKey = try o.defaulted("providerKey", to: ""); providerKeys = try o.defaulted("providerKeys", to: [:])
            rules = try o.required("rules"); autoOutreachEnabled = try o.defaulted("autoOutreachEnabled", to: false)
            autoSendEmailEnabled = try o.defaulted("autoSendEmailEnabled", to: false)
            appointmentRemindersEnabled = try o.defaulted("appointmentRemindersEnabled", to: false)
            appointmentConfirmTemplate = try o.defaulted("appointmentConfirmTemplate", to: "")
            onMyWayTemplate = try o.defaulted("onMyWayTemplate", to: "")
            estimateFollowUpsEnabled = try o.defaulted("estimateFollowUpsEnabled", to: true)
            autoInvoiceOnComplete = try o.defaulted("autoInvoiceOnComplete", to: false)
            autoEmailInvoiceOnComplete = try o.defaulted("autoEmailInvoiceOnComplete", to: false)
            autoSendRecurringInvoicesEnabled = try o.optional("autoSendRecurringInvoicesEnabled")
            anthropicKey = try o.defaulted("anthropicKey", to: ""); groqKey = try o.defaulted("groqKey", to: "")
            reviewRequestEnabled = try o.defaulted("reviewRequestEnabled", to: false)
            reviewRequestTemplate = try o.defaulted("reviewRequestTemplate", to: "")
            googleReviewLink = try o.defaulted("googleReviewLink", to: "")
            reviewRequestDelayHours = try o.defaulted("reviewRequestDelayHours", to: 3)
            preservation = o.finish()
        }

        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation)
            try o.put(businessName, for: "businessName"); try o.put(contactName, for: "contactName")
            try o.put(phone, for: "phone"); try o.put(email, for: "email"); try o.put(address, for: "address")
            try o.putOptional(region, for: "region"); try o.putOptional(logoPhoto, for: "logoPhoto"); try o.put(trade, for: "trade")
            try o.put(laborRate, for: "laborRate"); try o.putOptional(laborCostRate, for: "laborCostRate")
            try o.put(materialMarkup, for: "materialMarkup"); try o.put(overheadPercent, for: "overheadPercent")
            try o.put(marginPercent, for: "marginPercent"); try o.put(minimumJobFee, for: "minimumJobFee")
            try o.put(travelFeePerMile, for: "travelFeePerMile"); try o.put(emergencyMultiplier, for: "emergencyMultiplier")
            try o.putDefaulted(mileageRate, for: "mileageRate"); try o.putOptional(taxIncomeRate, for: "taxIncomeRate")
            try o.putOptional(vehicleDeductionMethod, for: "vehicleDeductionMethod")
            try o.putOptional(bookingLink, for: "bookingLink"); try o.putOptional(pushToken, for: "pushToken")
            try o.putOptional(schedule, for: "schedule"); try o.putOptional(invoicePrefix, for: "invoicePrefix")
            try o.putOptional(invoiceStartNumber, for: "invoiceStartNumber"); try o.put(paymentNotes, for: "paymentNotes")
            try o.put(provider, for: "provider"); try o.putDefaulted(providerKey, for: "providerKey")
            try o.putDefaulted(providerKeys, for: "providerKeys"); try o.put(rules, for: "rules")
            try o.putDefaulted(autoOutreachEnabled, for: "autoOutreachEnabled"); try o.putDefaulted(autoSendEmailEnabled, for: "autoSendEmailEnabled")
            try o.putDefaulted(appointmentRemindersEnabled, for: "appointmentRemindersEnabled")
            try o.putDefaulted(appointmentConfirmTemplate, for: "appointmentConfirmTemplate"); try o.putDefaulted(onMyWayTemplate, for: "onMyWayTemplate")
            try o.putDefaulted(estimateFollowUpsEnabled, for: "estimateFollowUpsEnabled"); try o.putDefaulted(autoInvoiceOnComplete, for: "autoInvoiceOnComplete")
            try o.putDefaulted(autoEmailInvoiceOnComplete, for: "autoEmailInvoiceOnComplete")
            try o.putOptional(autoSendRecurringInvoicesEnabled, for: "autoSendRecurringInvoicesEnabled")
            try o.putDefaulted(anthropicKey, for: "anthropicKey"); try o.putDefaulted(groqKey, for: "groqKey")
            try o.putDefaulted(reviewRequestEnabled, for: "reviewRequestEnabled"); try o.putDefaulted(reviewRequestTemplate, for: "reviewRequestTemplate")
            try o.putDefaulted(googleReviewLink, for: "googleReviewLink"); try o.putDefaulted(reviewRequestDelayHours, for: "reviewRequestDelayHours")
            try o.encode(to: encoder)
        }
    }
}

public extension Canonical {
    struct EstimateMaterialInput: Codable {
        public var id, name: String?
        public var quantity, unitCost: NumberOrString
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); id = try o.optional("id"); name = try o.optional("name")
            quantity = try o.required("quantity"); unitCost = try o.required("unitCost"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.putOptional(id, for: "id"); try o.putOptional(name, for: "name")
            try o.put(quantity, for: "quantity"); try o.put(unitCost, for: "unitCost"); try o.encode(to: encoder)
        }
    }

    struct EstimateInput: Codable {
        public var laborHours, laborRate: Decimal?
        public var materials: [EstimateMaterialInput]?
        public var materialMarkup: Decimal?
        public var jobCosts: [JobCostInput]?
        public var overheadPercent, marginPercent, travelMiles, travelFeePerMile: Decimal?
        public var isEmergency: Bool?
        public var emergencyMultiplier, minimumJobFee, taxPercent: Decimal?
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); laborHours = try o.optional("laborHours"); laborRate = try o.optional("laborRate")
            materials = try o.optional("materials"); materialMarkup = try o.optional("materialMarkup")
            jobCosts = try o.optional("jobCosts"); overheadPercent = try o.optional("overheadPercent")
            marginPercent = try o.optional("marginPercent"); travelMiles = try o.optional("travelMiles")
            travelFeePerMile = try o.optional("travelFeePerMile"); isEmergency = try o.optional("isEmergency")
            emergencyMultiplier = try o.optional("emergencyMultiplier"); minimumJobFee = try o.optional("minimumJobFee")
            taxPercent = try o.optional("taxPercent"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.putOptional(laborHours, for: "laborHours"); try o.putOptional(laborRate, for: "laborRate")
            try o.putOptional(materials, for: "materials"); try o.putOptional(materialMarkup, for: "materialMarkup")
            try o.putOptional(jobCosts, for: "jobCosts"); try o.putOptional(overheadPercent, for: "overheadPercent")
            try o.putOptional(marginPercent, for: "marginPercent"); try o.putOptional(travelMiles, for: "travelMiles")
            try o.putOptional(travelFeePerMile, for: "travelFeePerMile"); try o.putOptional(isEmergency, for: "isEmergency")
            try o.putOptional(emergencyMultiplier, for: "emergencyMultiplier"); try o.putOptional(minimumJobFee, for: "minimumJobFee")
            try o.putOptional(taxPercent, for: "taxPercent"); try o.encode(to: encoder)
        }
    }

    struct EstimateBreakdown: Codable {
        public var laborCost, materialBaseCost, materialMarkupAmount, materialCost, travelCost: Decimal
        public var directCostMarginBase, directCostPassthrough: Decimal
        public var directCostLines: [DirectCostLine]
        public var subtotal, overheadCost, profit, preTaxTotal, totalBeforeTax, taxAmount, total, effectiveHourlyRate: Decimal
        public var hitMinimum: Bool
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); laborCost = try o.required("laborCost")
            materialBaseCost = try o.required("materialBaseCost"); materialMarkupAmount = try o.required("materialMarkupAmount")
            materialCost = try o.required("materialCost"); travelCost = try o.required("travelCost")
            directCostMarginBase = try o.required("directCostMarginBase"); directCostPassthrough = try o.required("directCostPassthrough")
            directCostLines = try o.required("directCostLines"); subtotal = try o.required("subtotal")
            overheadCost = try o.required("overheadCost"); profit = try o.required("profit")
            preTaxTotal = try o.required("preTaxTotal"); totalBeforeTax = try o.required("totalBeforeTax")
            taxAmount = try o.required("taxAmount"); total = try o.required("total")
            effectiveHourlyRate = try o.required("effectiveHourlyRate"); hitMinimum = try o.required("hitMinimum")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(laborCost, for: "laborCost")
            try o.put(materialBaseCost, for: "materialBaseCost"); try o.put(materialMarkupAmount, for: "materialMarkupAmount")
            try o.put(materialCost, for: "materialCost"); try o.put(travelCost, for: "travelCost")
            try o.put(directCostMarginBase, for: "directCostMarginBase"); try o.put(directCostPassthrough, for: "directCostPassthrough")
            try o.put(directCostLines, for: "directCostLines"); try o.put(subtotal, for: "subtotal")
            try o.put(overheadCost, for: "overheadCost"); try o.put(profit, for: "profit")
            try o.put(preTaxTotal, for: "preTaxTotal"); try o.put(totalBeforeTax, for: "totalBeforeTax")
            try o.put(taxAmount, for: "taxAmount"); try o.put(total, for: "total")
            try o.put(effectiveHourlyRate, for: "effectiveHourlyRate"); try o.put(hitMinimum, for: "hitMinimum")
            try o.encode(to: encoder)
        }
    }

    struct PriceRange: Codable {
        public var low, recommended, high: Decimal
        public var breakdown: EstimateBreakdown
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); low = try o.required("low"); recommended = try o.required("recommended")
            high = try o.required("high"); breakdown = try o.required("breakdown"); preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(low, for: "low"); try o.put(recommended, for: "recommended")
            try o.put(high, for: "high"); try o.put(breakdown, for: "breakdown"); try o.encode(to: encoder)
        }
    }

    struct JobEstimateBreakdown: Codable {
        public var laborCost, materialBaseCost, materialCost: Decimal
        public var directCostLines: [DirectCostLine]
        public var overheadLine, estimateTotal: Decimal
        public var hasMaterials: Bool
        public var preservation: Preservation
        public init(from decoder: Decoder) throws {
            var o = try ObjectReader(decoder); laborCost = try o.required("laborCost")
            materialBaseCost = try o.required("materialBaseCost"); materialCost = try o.required("materialCost")
            directCostLines = try o.required("directCostLines"); overheadLine = try o.required("overheadLine")
            estimateTotal = try o.required("estimateTotal"); hasMaterials = try o.required("hasMaterials")
            preservation = o.finish()
        }
        public func encode(to encoder: Encoder) throws {
            var o = ObjectWriter(preservation); try o.put(laborCost, for: "laborCost")
            try o.put(materialBaseCost, for: "materialBaseCost"); try o.put(materialCost, for: "materialCost")
            try o.put(directCostLines, for: "directCostLines"); try o.put(overheadLine, for: "overheadLine")
            try o.put(estimateTotal, for: "estimateTotal"); try o.put(hasMaterials, for: "hasMaterials")
            try o.encode(to: encoder)
        }
    }
}
