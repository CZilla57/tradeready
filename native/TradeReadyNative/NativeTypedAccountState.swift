import CryptoKit
import Foundation

enum NativeTypedAccountStateError: Error, Equatable {
    case missingEnvelope
    case malformedEnvelope
    case unsupportedEnvelopeSchema
    case invalidEnvelopeScope
    case accountBindingMismatch
    case duplicateEntry
    case invalidEntryDigest
    case invalidTransactionDigest
    case invalidValue(key: String)
}

/// Typed, read-only views of the account-scoped values that the legacy app
/// deliberately staged after live identity verification. Absence remains
/// distinct from `false` or an empty collection so consumers do not invent
/// account state that was never present in the migration artifact.
struct NativeTypedAccountState: Equatable, Sendable {
    enum OnboardingStage: String, Equatable, Sendable {
        case personalized
        case done
    }

    enum Trade: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case plumbing, electrical, hvac, carpenter, bricklayer, plasterer
        case landscaping, cleaning, painting, handyman, other
    }

    struct OnboardingDraft: Codable, Equatable, Sendable {
        let businessName: String
        let contactName: String
        let trade: Trade
        let step: Int
    }

    struct SetupChecklistState: Codable, Equatable, Sendable {
        struct Done: Codable, Equatable, Sendable {
            let contact: Bool?
            let logo: Bool?
            let rate: Bool?
            let stripe: Bool?
            let notifications: Bool?
        }

        let dismissed: Bool?
        let done: Done?
        let sampleTourDone: Bool?
    }

    struct ReviewRequest: Codable, Equatable, Sendable {
        let jobId: String
        let customerId: String
        let customerName: String
        let customerPhone: String
        let customerEmail: String
        let scheduledAt: String
        let sentAt: String?
    }

    struct InsightMute: Codable, Equatable, Sendable {
        let id: String
        // Older JS reads admitted id-only records. Keep these optional so a
        // typed consumer can preserve that compatible legacy shape.
        let mutedAt: String?
        let until: String?
    }

    let onboardingComplete: Bool?
    let onboardingStage: OnboardingStage?
    let onboardingDraft: OnboardingDraft?
    let setupChecklistState: SetupChecklistState?
    let reviewRequests: [ReviewRequest]?
    let dismissedDuplicatePairs: [String]?
    let insightMutes: [InsightMute]?
    let invoiceReminderPromptShown: Bool?
}

/// Authenticated-envelope decoder for typed account-state consumers. It does
/// not expose generic entry lookup: sync queues, cursors, owner markers, and
/// future opaque keys can therefore never become replay input through this API.
enum NativeTypedAccountStateConsumer {
    private struct Envelope: Decodable {
        let schemaVersion: Int
        let sourceArtifactSHA256: String
        let transactionID: String
        let scope: NativeAuxiliaryActivationPlan.Scope
        let accountBinding: String?
        let entries: [NativeAuxiliaryActivationPlan.Entry]
    }

    private static let knownKeys: Set<String> = [
        "onboardingComplete", "onboardingStage", "onboardingDraft",
        "setupChecklistState", "review_requests", "dismissed_duplicate_pairs",
        "insightMutes", "invoiceReminderPromptShown"
    ]

    static func load(
        activationRootURL: URL,
        accountBinding: String,
        fileManager: FileManager = .default
    ) throws -> NativeTypedAccountState {
        guard isDigest(accountBinding) else {
            throw NativeTypedAccountStateError.accountBindingMismatch
        }
        let url = activationRootURL.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent("\(accountBinding).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw NativeTypedAccountStateError.missingEnvelope
        }
        do {
            return try decode(
                envelopeBytes: Data(contentsOf: url),
                expectedAccountBinding: accountBinding
            )
        } catch let error as NativeTypedAccountStateError {
            throw error
        } catch {
            throw NativeTypedAccountStateError.malformedEnvelope
        }
    }

    static func decode(
        envelopeBytes: Data,
        expectedAccountBinding: String
    ) throws -> NativeTypedAccountState {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: envelopeBytes)
        } catch {
            throw NativeTypedAccountStateError.malformedEnvelope
        }
        guard envelope.schemaVersion == 1 else {
            throw NativeTypedAccountStateError.unsupportedEnvelopeSchema
        }
        guard envelope.scope == .account else {
            throw NativeTypedAccountStateError.invalidEnvelopeScope
        }
        guard isDigest(expectedAccountBinding),
              envelope.accountBinding == expectedAccountBinding
        else { throw NativeTypedAccountStateError.accountBindingMismatch }
        guard isDigest(envelope.sourceArtifactSHA256),
              isDigest(envelope.transactionID)
        else { throw NativeTypedAccountStateError.malformedEnvelope }
        guard Set(envelope.entries.map(\.key)).count == envelope.entries.count else {
            throw NativeTypedAccountStateError.duplicateEntry
        }

        for entry in envelope.entries {
            let expected = sha256(framed([
                Data("tradeready-aux-entry-v1".utf8),
                Data(entry.key.utf8),
                entry.value,
                Data(NativeAuxiliaryStateScope.account.rawValue.utf8),
                Data(NativeAuxiliaryStateActivationPolicy.activateAfterIdentity.rawValue.utf8)
            ]))
            guard entry.digest == expected else {
                throw NativeTypedAccountStateError.invalidEntryDigest
            }
        }

        let transactionDigest = sha256(framed([
            Data("tradeready-aux-transaction-v1".utf8),
            Data(envelope.sourceArtifactSHA256.utf8),
            Data(NativeAuxiliaryActivationPlan.Scope.account.rawValue.utf8),
            Data(expectedAccountBinding.utf8)
        ] + envelope.entries.map { Data($0.digest.utf8) }))
        guard envelope.transactionID == transactionDigest else {
            throw NativeTypedAccountStateError.invalidTransactionDigest
        }

        // Ignore every non-consumer key after authenticating the complete
        // envelope. In particular, sync keys are never decoded or returned.
        let entries = Dictionary(uniqueKeysWithValues: envelope.entries.compactMap {
            knownKeys.contains($0.key) ? ($0.key, $0.value) : nil
        })

        return NativeTypedAccountState(
            onboardingComplete: try decodeRawBool(entries["onboardingComplete"], key: "onboardingComplete"),
            onboardingStage: try decodeStage(entries["onboardingStage"]),
            onboardingDraft: try decodeJSON(NativeTypedAccountState.OnboardingDraft.self, entries["onboardingDraft"], key: "onboardingDraft"),
            setupChecklistState: try decodeJSON(NativeTypedAccountState.SetupChecklistState.self, entries["setupChecklistState"], key: "setupChecklistState"),
            reviewRequests: try decodeJSON([NativeTypedAccountState.ReviewRequest].self, entries["review_requests"], key: "review_requests"),
            dismissedDuplicatePairs: try decodeJSON([String].self, entries["dismissed_duplicate_pairs"], key: "dismissed_duplicate_pairs"),
            insightMutes: try decodeJSON([NativeTypedAccountState.InsightMute].self, entries["insightMutes"], key: "insightMutes"),
            invoiceReminderPromptShown: try decodeRawBool(entries["invoiceReminderPromptShown"], key: "invoiceReminderPromptShown")
        )
    }

    private static func decodeStage(
        _ bytes: Data?
    ) throws -> NativeTypedAccountState.OnboardingStage? {
        guard let bytes else { return nil }
        guard let raw = String(data: bytes, encoding: .utf8),
              let value = NativeTypedAccountState.OnboardingStage(rawValue: raw)
        else { throw NativeTypedAccountStateError.invalidValue(key: "onboardingStage") }
        return value
    }

    private static func decodeRawBool(_ bytes: Data?, key: String) throws -> Bool? {
        guard let bytes else { return nil }
        if bytes == Data("true".utf8) { return true }
        if bytes == Data("false".utf8) { return false }
        throw NativeTypedAccountStateError.invalidValue(key: key)
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        _ bytes: Data?,
        key: String
    ) throws -> T? {
        guard let bytes else { return nil }
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw NativeTypedAccountStateError.invalidValue(key: key) }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func framed(_ values: [Data]) -> Data {
        var result = Data()
        for value in values {
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(value)
        }
        return result
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
