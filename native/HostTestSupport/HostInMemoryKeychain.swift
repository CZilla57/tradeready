import Foundation

// Phase 12.00b.2-A review M6: an in-memory stand-in for the login Keychain, so
// host runners never read or write the developer's (or a headless CI host's)
// real Keychain. `AppStore.init` reads the account-boundary step records from
// its secure store, and on a locked or absent Keychain every step would read
// as unverified and gate unrelated tests.
//
// One instance is shared per test process, so two `AppStore`s built on the
// same file (a "relaunch") still see the same secure items, as they did on the
// real Keychain. It is never persisted: every run starts empty.
final class HostInMemoryKeychain: NativeSecureKeyValueBacking, @unchecked Sendable {
    static let shared = HostInMemoryKeychain()

    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func upsert(_ value: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func read(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}

/// The secure settings store every host-test `AppStore` uses unless a test
/// injects its own fake.
func hostTestSecureSettingsStore() -> NativeKeychainSecureSettingsStore {
    NativeKeychainSecureSettingsStore(backend: HostInMemoryKeychain.shared)
}
