import Foundation

/// Phase 12 (12.06 fix round 2, R45 and R45a): tells the Expo rollback build
/// that a native build ran on this device since the Expo build last looked
/// (`docs/native-phase-12-rollback-playbook.md` §5.3, E-1).
///
/// `Application Support/TradeReadyNative/native-run-marker.json`, beside
/// `store.json`: `{"run":<n>,"schemaVersion":1}`. Every production launch adds
/// one to `run` after the store's launch work, whatever that work found (a
/// blocked or signed-out launch is still a native run). A missing or
/// unreadable marker starts at a random run instead (fix round 3), so a
/// restart cannot land on a value the Expo build already recorded. The native
/// directory itself is permanent, so it can only say that native has ever
/// run; this counter tells one native run from the next.
///
/// It holds no account data, identifier or time, and it is not a snapshot
/// write (the Task 11b commit rule does not apply). No account boundary
/// removes it, `.all` included: it is device state, like the directory, and
/// keeping it means `run` never repeats a value for the life of the install,
/// so the Expo build cannot mistake a later native run for one it already
/// recorded. Deleting the app removes it, together with the Expo build's
/// AsyncStorage.
struct NativeRunMarker: Codable, Equatable {
    static let filename = "native-run-marker.json"
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var run: Int
}

struct NativeRunMarkerStore {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(NativeRunMarker.filename)
    }

    /// The marker on disk, or nil when there is none or it does not decode
    /// as this schema.
    func load() -> NativeRunMarker? {
        guard let data = try? Data(contentsOf: fileURL),
              let marker = try? JSONDecoder().decode(NativeRunMarker.self, from: data),
              marker.schemaVersion == NativeRunMarker.currentSchemaVersion,
              marker.run > 0
        else { return nil }
        return marker
    }

    /// Records one more native run: the previous run plus one, wrapping at
    /// `Int.max` to 1. A missing or unreadable marker starts at a random run
    /// in 1...Int32.max, never a fixed value: the Expo build compares for
    /// inequality (playbook §5.3 E-1), so a restart that repeated the run it
    /// last recorded would hide this native run from it.
    @discardableResult
    func recordRun() throws -> NativeRunMarker {
        let run = load().map { $0.run == Int.max ? 1 : $0.run + 1 }
            ?? Int.random(in: 1...Int(Int32.max))
        let marker = NativeRunMarker(
            schemaVersion: NativeRunMarker.currentSchemaVersion,
            run: run
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(marker).write(to: fileURL, options: .atomic)
        return marker
    }
}
