import Foundation

// Phase 12 (L286.5b): the second durable record of a pending account-boundary
// step (`Canonical.SnapshotRepository.BoundaryStep`). A step is normally
// recorded by its file marker next to the snapshot. When that file cannot be
// written (a full or failing volume), `AppStore` records the step here
// instead, in the same native Keychain service, so a relaunch still reads it
// as pending and its gates stay closed. The item holds only a schema version:
// no account, binding, key or payload. Sign-out's `clearAccountValues` leaves
// it alone; deletion's `clearAllValues` removes it together with everything
// the steps protect.
extension NativeKeychainSecureSettingsStore {
    static func boundaryStepRecordAccount(_ step: Canonical.SnapshotRepository.BoundaryStep) -> String {
        "account-boundary-\(step.rawValue).v1"
    }

    /// Whether the step is recorded. A Keychain read error throws; the caller
    /// must treat that as "unknown" (fail closed), never as "not recorded".
    func isBoundaryStepRecorded(_ step: Canonical.SnapshotRepository.BoundaryStep) throws -> Bool {
        try backend.read(key: Self.boundaryStepRecordAccount(step)) != nil
    }

    /// A verified upsert of the step's record.
    func recordBoundaryStep(_ step: Canonical.SnapshotRepository.BoundaryStep) throws {
        let account = Self.boundaryStepRecordAccount(step)
        let data = Data(#"{"schemaVersion":1}"#.utf8)
        try backend.upsert(data, key: account)
        guard try backend.read(key: account) == data else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: account)
        }
    }

    /// A verified remove of the step's record (absent is success).
    func removeBoundaryStepRecord(_ step: Canonical.SnapshotRepository.BoundaryStep) throws {
        let account = Self.boundaryStepRecordAccount(step)
        try backend.remove(key: account)
        guard try backend.read(key: account) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: account)
        }
    }
}
