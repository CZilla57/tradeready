import CryptoKit
import Foundation

enum NativeAuxiliaryActivationError: Error, Equatable {
    case invalidIdentity
    case unsupportedArtifactSchema
    case duplicateArtifactKey
    case invalidAccountBinding
    case conflictingEnvelope
    case corruptReceipt
    case conflictingReceipt
}

/// This value may only be created after an authentication boundary has
/// verified the opaque provider subject. The initializer deliberately does
/// not trim, lowercase, or otherwise rewrite identity.
struct NativeVerifiedAuxiliaryIdentity: Equatable, Sendable {
    let opaqueSubject: String
    let email: String?

    init(opaqueSubject: String, email: String? = nil) throws {
        guard !opaqueSubject.isEmpty,
              !opaqueSubject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw NativeAuxiliaryActivationError.invalidIdentity }
        self.opaqueSubject = opaqueSubject
        self.email = email
    }
}

/// Production supplies a keyed, app-local binding (for example HMAC-SHA256
/// using a Keychain-held key). Tests inject a deterministic implementation.
/// The raw account subject is never persisted by this component.
protocol NativeAuxiliaryAccountBindingProviding {
    func keyedBinding(for opaqueSubject: String) throws -> Data
}

struct NativeAuxiliaryActivationPlan: Equatable, Sendable {
    enum Scope: String, Codable, Equatable, Sendable {
        case device
        case account
    }

    struct Entry: Codable, Equatable, Sendable {
        let key: String
        let value: Data
        let digest: String
    }

    struct Transaction: Equatable, Sendable {
        let id: String
        let scope: Scope
        let accountBinding: String?
        let entries: [Entry]
    }

    enum AccountDisposition: Equatable, Sendable {
        case notRequested
        case staged
        case identityNotProven
    }

    let sourceArtifactSHA256: String
    let transactions: [Transaction]
    let accountDisposition: AccountDisposition
}

enum NativeAuxiliaryActivationPlanner {
    private static let excludedAccountKeys: Set<String> = [
        "__syncQueue", "__lastSyncedAt", "__dataOwner"
    ]

    static func plan(
        sourceArtifactBytes: Data,
        identity: NativeVerifiedAuxiliaryIdentity?,
        accountBindingProvider: NativeAuxiliaryAccountBindingProviding
    ) throws -> NativeAuxiliaryActivationPlan {
        let artifact = try JSONDecoder().decode(
            NativeAuxiliaryStateArtifact.self,
            from: sourceArtifactBytes
        )
        guard artifact.schemaVersion == NativeAuxiliaryStateArtifact.currentSchemaVersion else {
            throw NativeAuxiliaryActivationError.unsupportedArtifactSchema
        }
        guard Set(artifact.entries.map(\.key)).count == artifact.entries.count else {
            throw NativeAuxiliaryActivationError.duplicateArtifactKey
        }

        let artifactDigest = sha256(sourceArtifactBytes)
        var transactions: [NativeAuxiliaryActivationPlan.Transaction] = []

        let deviceEntries = artifact.entries.compactMap { entry -> NativeAuxiliaryActivationPlan.Entry? in
            guard entry.key == "__themePreference",
                  entry.scope == .device,
                  entry.activationPolicy == .restorable,
                  let value = String(data: entry.value, encoding: .utf8),
                  ["light", "dark", "system"].contains(value)
            else { return nil }
            return stagedEntry(entry)
        }.sorted { $0.key < $1.key }
        if !deviceEntries.isEmpty {
            transactions.append(transaction(
                scope: .device,
                accountBinding: nil,
                entries: deviceEntries,
                artifactDigest: artifactDigest
            ))
        }

        let accountCandidates = artifact.entries.filter {
            $0.scope == .account
                && $0.activationPolicy == .activateAfterIdentity
                && !excludedAccountKeys.contains($0.key)
        }
        let accountDisposition: NativeAuxiliaryActivationPlan.AccountDisposition
        if accountCandidates.isEmpty {
            accountDisposition = .notRequested
        } else if let identity,
                  owner(in: artifact) == identity.opaqueSubject {
            let rawBinding = try accountBindingProvider.keyedBinding(for: identity.opaqueSubject)
            guard !rawBinding.isEmpty else {
                throw NativeAuxiliaryActivationError.invalidAccountBinding
            }
            let binding = sha256(framed([
                Data("tradeready-aux-account-binding-v1".utf8), rawBinding
            ]))
            let entries = accountCandidates.map(stagedEntry).sorted { $0.key < $1.key }
            transactions.append(transaction(
                scope: .account,
                accountBinding: binding,
                entries: entries,
                artifactDigest: artifactDigest
            ))
            accountDisposition = .staged
        } else {
            // Missing, malformed, empty, or mismatched ownership all collapse
            // to the same non-disclosing result and write no account state.
            accountDisposition = .identityNotProven
        }

        return NativeAuxiliaryActivationPlan(
            sourceArtifactSHA256: artifactDigest,
            transactions: transactions,
            accountDisposition: accountDisposition
        )
    }

    private static func owner(in artifact: NativeAuxiliaryStateArtifact) -> String? {
        guard let entry = artifact.entries.first(where: { $0.key == "__dataOwner" }),
              entry.scope == .account,
              entry.activationPolicy == .preserveOnly,
              let owner = try? JSONDecoder().decode(String.self, from: entry.value),
              !owner.isEmpty,
              !owner.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return owner
    }

    private static func stagedEntry(
        _ entry: NativeAuxiliaryStateArtifact.Entry
    ) -> NativeAuxiliaryActivationPlan.Entry {
        let digest = sha256(framed([
            Data("tradeready-aux-entry-v1".utf8),
            Data(entry.key.utf8),
            entry.value,
            Data(entry.scope.rawValue.utf8),
            Data(entry.activationPolicy.rawValue.utf8)
        ]))
        return .init(key: entry.key, value: entry.value, digest: digest)
    }

    private static func transaction(
        scope: NativeAuxiliaryActivationPlan.Scope,
        accountBinding: String?,
        entries: [NativeAuxiliaryActivationPlan.Entry],
        artifactDigest: String
    ) -> NativeAuxiliaryActivationPlan.Transaction {
        var fields = [
            Data("tradeready-aux-transaction-v1".utf8),
            Data(artifactDigest.utf8),
            Data(scope.rawValue.utf8),
            Data((accountBinding ?? "").utf8)
        ]
        fields.append(contentsOf: entries.map { Data($0.digest.utf8) })
        return .init(
            id: sha256(framed(fields)),
            scope: scope,
            accountBinding: accountBinding,
            entries: entries
        )
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

struct NativeAuxiliaryActivationReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Transaction: Codable, Equatable, Sendable {
        let id: String
        let scope: NativeAuxiliaryActivationPlan.Scope
        let accountBinding: String?
        let entryDigests: [String]
        let stagedAt: Date
    }

    let schemaVersion: Int
    let sourceArtifactSHA256: String
    var transactions: [Transaction]
}

private struct NativeAuxiliaryActivationEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceArtifactSHA256: String
    let transactionID: String
    let scope: NativeAuxiliaryActivationPlan.Scope
    let accountBinding: String?
    let entries: [NativeAuxiliaryActivationPlan.Entry]
}

/// Serializes staging so two callers cannot lose receipt transactions. Raw
/// values are held only in native-owned envelopes; the receipt contains
/// digests and a keyed account binding, never an account subject or value.
actor NativeAuxiliaryActivationStore {
    struct Outcome: Equatable, Sendable {
        let newlyStagedCount: Int
        let alreadyStagedCount: Int
    }

    static let receiptFilename = "auxiliary-activation-receipt.json"

    let rootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.now = now
    }

    func stage(_ plan: NativeAuxiliaryActivationPlan) throws -> Outcome {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var receipt = try loadReceipt(for: plan.sourceArtifactSHA256)
        guard Set(plan.transactions.map(\.id)).count == plan.transactions.count else {
            throw NativeAuxiliaryActivationError.conflictingEnvelope
        }
        var prepared: [(
            transaction: NativeAuxiliaryActivationPlan.Transaction,
            bytes: Data,
            destination: URL,
            alreadyExists: Bool,
            entryDigests: [String]
        )] = []

        // Preflight every conflict before publishing any envelope. An account
        // conflict must not leave a newly staged device transaction behind.
        for transaction in plan.transactions {
            guard transaction.scope == .device && transaction.accountBinding == nil
                    || transaction.scope == .account && !(transaction.accountBinding ?? "").isEmpty
            else { throw NativeAuxiliaryActivationError.invalidAccountBinding }
            let envelope = NativeAuxiliaryActivationEnvelope(
                schemaVersion: 1,
                sourceArtifactSHA256: plan.sourceArtifactSHA256,
                transactionID: transaction.id,
                scope: transaction.scope,
                accountBinding: transaction.accountBinding,
                entries: transaction.entries
            )
            let envelopeBytes = try Self.encode(envelope)
            let destination = envelopeURL(for: transaction)
            let exists = fileManager.fileExists(atPath: destination.path)
            if exists, try Data(contentsOf: destination) != envelopeBytes {
                throw NativeAuxiliaryActivationError.conflictingEnvelope
            }
            let entryDigests = transaction.entries.map(\.digest).sorted()
            if let existing = receipt.transactions.first(where: { $0.id == transaction.id }) {
                guard existing.scope == transaction.scope,
                      existing.accountBinding == transaction.accountBinding,
                      existing.entryDigests == entryDigests
                else { throw NativeAuxiliaryActivationError.conflictingReceipt }
            }
            prepared.append((transaction, envelopeBytes, destination, exists, entryDigests))
        }

        var newlyStaged = 0
        var alreadyStaged = 0

        for item in prepared {
            let transaction = item.transaction
            if item.alreadyExists {
                alreadyStaged += 1
            } else {
                try protectedAtomicWrite(item.bytes, to: item.destination)
                newlyStaged += 1
            }

            if !receipt.transactions.contains(where: { $0.id == transaction.id }) {
                receipt.transactions.append(.init(
                    id: transaction.id,
                    scope: transaction.scope,
                    accountBinding: transaction.accountBinding,
                    entryDigests: item.entryDigests,
                    stagedAt: now()
                ))
                receipt.transactions.sort { $0.id < $1.id }
                try protectedAtomicWrite(
                    try Self.encode(receipt),
                    to: rootURL.appendingPathComponent(Self.receiptFilename)
                )
            }
        }
        return .init(newlyStagedCount: newlyStaged, alreadyStagedCount: alreadyStaged)
    }

    func loadReceipt() throws -> NativeAuxiliaryActivationReceipt? {
        let url = rootURL.appendingPathComponent(Self.receiptFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let receipt = try decoder.decode(
                NativeAuxiliaryActivationReceipt.self,
                from: Data(contentsOf: url)
            )
            guard receipt.schemaVersion == NativeAuxiliaryActivationReceipt.currentSchemaVersion else {
                throw NativeAuxiliaryActivationError.corruptReceipt
            }
            return receipt
        } catch let error as NativeAuxiliaryActivationError {
            throw error
        } catch {
            throw NativeAuxiliaryActivationError.corruptReceipt
        }
    }

    private func loadReceipt(for artifactDigest: String) throws -> NativeAuxiliaryActivationReceipt {
        guard let receipt = try loadReceipt() else {
            return .init(
                schemaVersion: NativeAuxiliaryActivationReceipt.currentSchemaVersion,
                sourceArtifactSHA256: artifactDigest,
                transactions: []
            )
        }
        guard receipt.sourceArtifactSHA256 == artifactDigest else {
            throw NativeAuxiliaryActivationError.conflictingReceipt
        }
        return receipt
    }

    private func envelopeURL(
        for transaction: NativeAuxiliaryActivationPlan.Transaction
    ) -> URL {
        switch transaction.scope {
        case .device:
            rootURL.appendingPathComponent("auxiliary-activation-device.json")
        case .account:
            rootURL.appendingPathComponent("Accounts", isDirectory: true)
                .appendingPathComponent("\(transaction.accountBinding!).json")
        }
    }

    private func protectedAtomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
