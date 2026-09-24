import CryptoKit
import Foundation

// Task 11.05 (W4): the single owner identity every widget/Siri path compares.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §2.5 (one owner predicate `O = AppStore.derivedStatePublishBinding`),
// §4.5 (owner stamping; replay drops untagged and mismatched actions) and
// decision C22 (the replay gate uses `O` and `.signedIn`, never the migrated
// owner alone). App target only: the extension copies the tag from the
// snapshot and never derives one.

// MARK: - Owner tag (contract §2.3, §2.5)

enum NativeWidgetOwnerTag {
    static let prefix = "tradeready.widget.owner.v1:"

    /// Lowercase hex SHA-256 of `prefix + binding`, where `binding` is the
    /// single owner predicate `AppStore.derivedStatePublishBinding` (or, on the
    /// seam, the publish's `expectedOwnerBinding`). Hashed again so the raw
    /// binding never enters the App Group. 11.04 (actions, `activeTrip`, the
    /// stash), 11.05 (replay gate) and 11.06 (pending-URL gate) compare
    /// against this same function.
    static func make(binding: String) -> String {
        SHA256.hash(data: Data((prefix + binding).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// §4.5: true only for a present tag equal to `hash(binding)`. A missing
    /// tag (an RN-era or foreign write) never matches.
    static func matches(_ tag: String?, binding: String) -> Bool {
        guard let tag else { return false }
        return tag == make(binding: binding)
    }
}

// MARK: - Replay gate (contract §2.5 table row "Replay gate", C22)

enum NativeWidgetReplayOwnerGate {
    /// The binding widget/Siri replay may run for, or nil.
    ///
    /// - Parameters:
    ///   - ownerBinding: the §2.5 predicate `O` (`derivedStatePublishBinding`).
    ///     It already requires an exact workspace (migrated-owner proof OR a
    ///     completed persisted workspace bound to the verified binding), so a
    ///     native-only account qualifies.
    ///   - isSignedIn: replay mutates canonical data, so it additionally
    ///     requires the `.signedIn` gate (the writer may run in the
    ///     post-sign-in gates; replay may not).
    ///   - accountBoundaryOpen: an explicit sign-out/deletion scrub is in
    ///     progress, pending or blocked. Nothing is claimed across it.
    static func replayBinding(
        ownerBinding: String?,
        isSignedIn: Bool,
        accountBoundaryOpen: Bool
    ) -> String? {
        guard isSignedIn, !accountBoundaryOpen, let ownerBinding, !ownerBinding.isEmpty else { return nil }
        return ownerBinding
    }
}
