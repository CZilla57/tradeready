import Foundation

// Task 11.15 (contract §11, C19): user-entered AI provider keys go through the
// existing secure store — the same `NativeKeychainSecureSettingsStore` backing
// and accounts (`anthropicKey`, `groqKey`) that migrated keys use — so they
// share its Keychain attributes (`AfterFirstUnlockThisDeviceOnly`) and its
// owner wipe (`clearAccountValues` / `clearAllValues`). No second Keychain
// wrapper exists. Policy lives in `NativeAIProviderKeyPolicy`.
//
// Phase 12 (L286.5b review I1): each item holds the key with the tag of the
// owner who saved it (`NativeAIProviderKeyOwnerTag`), and reads return it
// only for that owner.
extension NativeKeychainSecureSettingsStore {
    /// The key saved by `ownerBinding`, trimmed; nil when absent, empty,
    /// unreadable, untagged or another owner's. The coach reads through this,
    /// so any of those routes to the backend.
    func readAIProviderKey(_ kind: NativeAIProviderKeyKind, ownerBinding: String?) -> String? {
        NativeAIProviderKeyOwnerTag.open(try? backend.read(key: kind.secureAccount), binding: ownerBinding)
    }

    /// The status row's view of the key: a read error is `.unreadable`, never
    /// "Not set" (fix round 1, M5); an untagged item or another owner's is
    /// "Not set", exactly like no item.
    func aiProviderKeyState(_ kind: NativeAIProviderKeyKind, ownerBinding: String?) -> NativeAIProviderKeyPolicy.SavedState {
        do {
            let data = try backend.read(key: kind.secureAccount)
            return NativeAIProviderKeyOwnerTag.open(data, binding: ownerBinding) == nil ? .notSet : .saved
        } catch {
            return .unreadable
        }
    }

    /// Contract §11 save: a verified upsert of the key sealed with its
    /// owner's tag, one Keychain item in one write.
    func saveAIProviderKey(_ key: String, kind: NativeAIProviderKeyKind, ownerBinding: String) throws {
        let data = try NativeAIProviderKeyOwnerTag.seal(key, binding: ownerBinding)
        try backend.upsert(data, key: kind.secureAccount)
        guard try backend.read(key: kind.secureAccount) == data else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: kind.secureAccount)
        }
    }

    /// Contract §11 clear: a verified remove of the account.
    func clearAIProviderKey(_ kind: NativeAIProviderKeyKind) throws {
        try backend.remove(key: kind.secureAccount)
        guard try backend.read(key: kind.secureAccount) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: kind.secureAccount)
        }
    }

    /// Phase 12 (L205.e): every account an AI provider credential can occupy —
    /// the two keys above plus the migrated legacy `providerKey` and
    /// `geminiKey` fields. Nothing reads the legacy fields after migration,
    /// but they are credentials, so the switch/recovery-exit boundary wipe
    /// removes them too (sign-out and deletion already do, through
    /// `clearAccountValues`).
    static let accountBoundaryAIKeyAccounts = NativeAIProviderKeyKind.allCases.map(\.secureAccount)
        + ["providerKey", "geminiKey"]

    /// A verified remove of one of `accountBoundaryAIKeyAccounts`.
    func clearAccountBoundaryAIKey(account: String) throws {
        try backend.remove(key: account)
        guard try backend.read(key: account) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: account)
        }
    }
}
