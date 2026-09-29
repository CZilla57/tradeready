import CryptoKit
import Foundation

// Phase 12 (L286.5b review I1; controller ruling 2026-09-25, the brief's
// candidate (b)): an AI provider key is bound to the owner it was saved for,
// inside the same Keychain item. The item's bytes are one small JSON object
// holding the key and a tag of that owner, written by a single verified
// upsert, so the key can never be stored without its tag. A read returns the
// key only when the tag is the current verified owner's. A key the
// account-boundary wipe could not remove is then inert for the next owner even
// if the step's pending state was lost too (file marker, Keychain record and
// wipe all failing, then a relaunch). An untagged item (an RN-era key the
// launch migration copied before any owner was verified) or another owner's
// item reads as absent until the owner saves a key again.
//
// The tag uses the widget owner stamp's derivation (`NativeWidgetOwnerTag`:
// lowercase hex SHA-256 of a versioned prefix plus the binding) with its own
// prefix, over the verified account binding (an HMAC of the user id under a
// device-local key). The item stores neither the binding nor any user id or
// email.
enum NativeAIProviderKeyOwnerTag {
    static let prefix = "tradeready.ai-key.owner.v1:"
    static let schemaVersion = 1

    static func make(binding: String) -> String {
        SHA256.hash(data: Data((prefix + binding).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The Keychain item's bytes for `key`, saved by the owner `binding`.
    static func seal(_ key: String, binding: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Item(schemaVersion: schemaVersion, ownerTag: make(binding: binding), key: key))
    }

    /// The key in `data` when it is a tagged item saved by `binding`. Nil for
    /// no item, no owner, an untagged or malformed item, or another owner's.
    static func open(_ data: Data?, binding: String?) -> String? {
        guard let data, let binding, !binding.isEmpty,
              let item = try? JSONDecoder().decode(Item.self, from: data),
              item.schemaVersion == schemaVersion,
              item.ownerTag == make(binding: binding)
        else { return nil }
        return NativeAIProviderKeyPolicy.storedKey(from: Data(item.key.utf8))
    }

    private struct Item: Codable {
        let schemaVersion: Int
        let ownerTag: String
        let key: String
    }
}
