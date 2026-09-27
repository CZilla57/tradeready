import Foundation

// Phase 12, task 13 (12.01), requirement SC4: the legacy migration path (Expo
// AsyncStorage -> native) must never be removed or unwired. This is a pure
// source/structure assertion, not a behavioral test:
//   1. `LegacyMigrationCoordinator` and `LegacyDataImporter.readAsyncStorageValues`
//      (the AsyncStorage reader) must still compile into this host target. If
//      either type is removed or renamed, `swiftc` fails before any of the
//      checks below run, and the runner treats that compile failure the same
//      as a failing test.
//   2. `AppStore.swift`'s launch path (its `init`, guarded by
//      `automaticallyMigrateLegacyData`) must still construct a
//      `LegacyMigrationCoordinator` and route it through `migrateLegacySource`.
//      This is a source-text check scoped to that launch-path block, not an
//      `AppStore` instantiation, so this test never touches the Keychain or
//      writes a legacy backup (ruling R53: it must pass with the console
//      locked, since a locked console makes any real legacy-backup write fail
//      with EPERM under `SnapshotRepository`'s Class A file protection).
//
// Neither `LegacyMigrationCoordinator.migrate` nor
// `LegacyDataImporter.readAsyncStorageValues` is ever called here.

@main
struct LegacyMigrationRetentionTests {
    static var failures = 0

    static func check(_ description: String, _ passed: Bool) {
        if passed {
            print("PASS: \(description)")
        } else {
            failures += 1
            print("FAIL: \(description)")
        }
    }

    static func main() {
        // 1) Compiled-symbol presence. Referencing the type and the reader's
        // exact signature (without calling it) proves both are still present
        // in the compiled source set; removing or renaming either fails the
        // swiftc invocation in the runner script, before this binary ever runs.
        _ = LegacyMigrationCoordinator.self // never invoked: proves the type compiles, without instantiating it.
        check("LegacyMigrationCoordinator compiles into the host target", true)

        let asyncStorageReader: (URL) throws -> [String: Data] = LegacyDataImporter.readAsyncStorageValues(from:)
        check("LegacyDataImporter.readAsyncStorageValues (the AsyncStorage reader) compiles into the host target", true)
        _ = asyncStorageReader // never invoked: no AsyncStorage or Keychain I/O in this test.

        // 2) Launch-path wiring, scoped to the automatic-migration block of
        // AppStore's initializer (the app's actual launch path), read as source text.
        guard let rootDir = ProcessInfo.processInfo.environment["TRADEREADY_ROOT_DIR"], !rootDir.isEmpty else {
            print("FAIL: TRADEREADY_ROOT_DIR was not supplied by the runner")
            exit(1)
        }

        let appStorePath = rootDir + "/native/TradeReadyNative/AppStore.swift"
        guard let appStoreSource = try? String(contentsOfFile: appStorePath, encoding: .utf8) else {
            print("FAIL: could not read \(appStorePath)")
            exit(1)
        }

        let launchGateAnchor = "if automaticallyMigrateLegacyData && accountScrubRecoveryError == nil {"
        let launchBlockEndAnchor = "let completedWithoutSnapshot ="

        guard let gateRange = appStoreSource.range(of: launchGateAnchor) else {
            check("AppStore's init still gates an automatic legacy migration attempt on launch", false)
            print("\nRETENTION CHECK FAILED: \(failures) assertion(s) failed.")
            exit(1)
        }
        check("AppStore's init still gates an automatic legacy migration attempt on launch", true)

        guard let blockEndRange = appStoreSource.range(of: launchBlockEndAnchor, range: gateRange.upperBound..<appStoreSource.endIndex) else {
            print("FAIL: could not find the end of the launch-migration block (`\(launchBlockEndAnchor)`)")
            print("\nRETENTION CHECK FAILED: \(failures + 1) assertion(s) failed.")
            exit(1)
        }

        let launchPathBlock = appStoreSource[gateRange.upperBound..<blockEndRange.lowerBound]

        check(
            "the launch path constructs a LegacyMigrationCoordinator",
            launchPathBlock.contains("LegacyMigrationCoordinator(")
        )
        check(
            "the launch path routes the constructed coordinator through migrateLegacySource",
            launchPathBlock.contains("try self.migrateLegacySource(with: coordinator)")
        )

        if failures > 0 {
            print("\nRETENTION CHECK FAILED: \(failures) assertion(s) failed.")
            exit(1)
        }

        print("\nRETENTION CHECK PASSED: LegacyMigrationCoordinator, the AsyncStorage reader, and the AppStore launch-path wiring are all present.")
    }
}
