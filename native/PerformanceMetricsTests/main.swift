import Foundation

// Task 11.12 host tests (H4): the performance signpost facade in
// `N/NativePerformanceMetrics.swift`.
//
// - Catalog: the exact interval set, each with a static CamelCase name.
// - Metadata (contract §10.1 via the 11.09 redaction rules): a signpost may
//   carry only a clamped count and a fixed outcome word. Every combination is
//   rendered and checked against the one allowed shape.
// - Facade behavior over a recording sink: begin/end pairing, idempotent end,
//   `measure` passes values and errors through unchanged, launch is measured
//   once, and a disabled or absent sink costs nothing and changes nothing.
// - The real `OSSignposter` sink runs on this host without trapping.
// - Source scans over `N/`:
//   * the facade file holds no suspension, no traps, no network, storage,
//     analytics or crash-reporting reference, and passes only its metadata
//     string to the OS as a public argument;
//   * no other `N/` file emits signposts or reaches the sink directly;
//   * every call site uses an interval case and counts only (no string
//     literal can reach a signpost), and the instrumented sites are exactly
//     the pinned inventory (launch, snapshot load, legacy migration, initial
//     sync, delta pull, background refresh, Jobs and Invoices list projection).
// Device numbers are Phase 12 (docs/native-phase-11-performance.md).
// Run with TZ=America/Phoenix.

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private struct SampleError: Error, Equatable {}

/// The one allowed metadata shape: empty, a count, an outcome word, or both.
private func isAllowedMetadata(_ text: String) -> Bool {
    let outcomes = NativePerformanceOutcome.allCases.map(\.rawValue).joined(separator: "|")
    let pattern = "^(count=(0|[1-9][0-9]{0,8}))?( ?outcome=(\(outcomes)))?$"
    guard text.range(of: pattern, options: .regularExpression) != nil else { return false }
    return !(text.hasPrefix(" "))
}

@main
struct PerformanceMetricsTests {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        testCatalog()
        testMetadataShapes()
        testFacadeOverRecordingSink()
        testDisabledAndAbsentSinks()
        testOSSignpostSinkRuns()
        testSourceScans(root: root)
        if failures == 0 {
            print("performance-metrics tests: \(checks)/\(checks) checks passed")
        } else {
            print("performance-metrics tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }

    // MARK: Catalog

    static func testCatalog() {
        let expected = [
            "Launch", "SnapshotLoad", "LegacyMigration", "InitialSync", "DeltaPull",
            "BackgroundRefresh", "JobListProjection", "InvoiceListProjection",
        ]
        let names = NativePerformanceInterval.allCases.map(\.name)
        expectEqual(names, expected, "the interval catalog is exactly the pinned set, in order")
        expectEqual(Set(names).count, names.count, "interval names are unique")
        for name in names {
            expect(name.range(of: "^[A-Z][A-Za-z]{2,31}$", options: .regularExpression) != nil,
                   "interval name \(name) is a short static CamelCase word")
        }
        expectEqual(NativePerformanceOutcome.allCases.map(\.rawValue),
                    ["completed", "partial", "failed", "skipped"],
                    "the outcome words are the four fixed values")
    }

    // MARK: Metadata

    static func testMetadataShapes() {
        let counts: [Int?] = [nil, Int.min, -5, 0, 1, 42, 999_999_999, 1_000_000_000, Int.max]
        let outcomes: [NativePerformanceOutcome?] = [nil] + NativePerformanceOutcome.allCases
        for count in counts {
            for outcome in outcomes {
                let text = NativePerformanceMetrics.metadata(count: count, outcome: outcome)
                expect(isAllowedMetadata(text),
                       "metadata for count \(String(describing: count)) outcome \(String(describing: outcome)) has the allowed shape: '\(text)'")
            }
        }
        expectEqual(NativePerformanceMetrics.metadata(count: nil, outcome: nil), "", "no count and no outcome is empty")
        expectEqual(NativePerformanceMetrics.metadata(count: 12, outcome: nil), "count=12", "a count renders alone")
        expectEqual(NativePerformanceMetrics.metadata(count: nil, outcome: .partial), "outcome=partial",
                    "an outcome renders alone")
        expectEqual(NativePerformanceMetrics.metadata(count: 3, outcome: .failed), "count=3 outcome=failed",
                    "count and outcome render together")
        expectEqual(NativePerformanceMetrics.metadata(count: -7, outcome: nil), "count=0", "a negative count clamps to 0")
        expectEqual(NativePerformanceMetrics.metadata(count: Int.max, outcome: nil), "count=999999999",
                    "a huge count clamps to the 9-digit maximum")
        expectEqual(NativePerformanceMetrics.maximumCount, 999_999_999, "the count cap is 9 digits")
    }

    // MARK: Facade

    static func testFacadeOverRecordingSink() {
        let sink = RecordingSignpostSink()
        let metrics = NativePerformanceMetrics(sink: sink)

        let token = metrics.begin(.initialSync)
        expectEqual(sink.records, [.init(phase: .begin, interval: .initialSync, metadata: "")],
                    "begin emits one interval begin with empty metadata")
        metrics.end(token, outcome: .completed, count: 250)
        expectEqual(sink.records.last, .init(phase: .end, interval: .initialSync, metadata: "count=250 outcome=completed"),
                    "end emits the matching end with count and outcome")
        expectEqual(sink.mismatchedEnds, 0, "end hands back the state its begin returned")
        metrics.end(token, outcome: .failed)
        expectEqual(sink.records.count, 2, "a second end of the same token is a no-op")

        sink.reset()
        let counted = metrics.begin(.snapshotLoad, count: 7)
        metrics.end(counted)
        expectEqual(sink.records.map(\.metadata), ["count=7", "outcome=completed"],
                    "a begin count and the default completed outcome")

        sink.reset()
        let value = metrics.measure(.jobListProjection, count: { (items: [Int]) in items.count }) { [1, 2, 3] }
        expectEqual(value, [1, 2, 3], "measure returns the work's value unchanged")
        expectEqual(sink.records, [
            .init(phase: .begin, interval: .jobListProjection, metadata: ""),
            .init(phase: .end, interval: .jobListProjection, metadata: "count=3 outcome=completed"),
        ], "measure brackets the work and records the result count")

        sink.reset()
        var threw = false
        do {
            _ = try metrics.measure(.legacyMigration) { () throws -> Int in throw SampleError() }
        } catch let error as SampleError {
            threw = error == SampleError()
        } catch {}
        expect(threw, "measure rethrows the work's error unchanged")
        expectEqual(sink.records.last?.metadata, "outcome=failed", "a throwing measure ends with outcome failed")
        expectEqual(sink.openCount, 0, "a throwing measure leaves no interval open")

        sink.reset()
        metrics.endLaunch()
        expectEqual(sink.records.count, 0, "endLaunch before beginLaunch emits nothing")
        metrics.beginLaunch()
        metrics.beginLaunch()
        metrics.endLaunch()
        metrics.endLaunch()
        expectEqual(sink.records, [
            .init(phase: .begin, interval: .launch, metadata: ""),
            .init(phase: .end, interval: .launch, metadata: "outcome=completed"),
        ], "launch is measured exactly once per process")
        metrics.beginLaunch()
        expectEqual(sink.records.count, 2, "launch never restarts after it ended")
        expectEqual(sink.openCount, 0, "no interval is left open")
    }

    static func testDisabledAndAbsentSinks() {
        let sink = RecordingSignpostSink()
        sink.isEnabled = false
        let metrics = NativePerformanceMetrics(sink: sink)
        let token = metrics.begin(.deltaPull, count: 4)
        metrics.end(token, outcome: .partial)
        let value = metrics.measure(.invoiceListProjection) { "unchanged" }
        metrics.beginLaunch()
        metrics.endLaunch()
        expectEqual(sink.records.count, 0, "a disabled sink receives nothing")
        expectEqual(value, "unchanged", "measure still returns its value when signposts are off")

        let absent = NativePerformanceMetrics(sink: nil)
        let absentToken = absent.begin(.backgroundRefresh)
        absent.end(absentToken, outcome: .skipped)
        expectEqual(absent.measure(.snapshotLoad) { 5 }, 5, "no sink: measure is a pass-through")

        // A disabled-at-begin interval stays silent even if the sink turns on
        // before its end (Instruments attached mid-interval).
        let late = RecordingSignpostSink()
        late.isEnabled = false
        let lateMetrics = NativePerformanceMetrics(sink: late)
        let lateToken = lateMetrics.begin(.initialSync)
        late.isEnabled = true
        lateMetrics.end(lateToken)
        expectEqual(late.records.count, 0, "an end without a recorded begin emits nothing")
        expectEqual(late.mismatchedEnds, 0, "no unpaired end reaches the sink")

        // Swapping the sink (the host-test seam) routes later intervals only.
        let first = RecordingSignpostSink()
        let second = RecordingSignpostSink()
        let swapped = NativePerformanceMetrics(sink: first)
        let early = swapped.begin(.deltaPull)
        swapped.replaceSink(second)
        swapped.end(early)
        expectEqual(first.records.map(\.phase), [.begin, .end], "an interval ends on the sink that began it")
        expectEqual(first.mismatchedEnds, 0, "the begin state returns to its own sink")
        expectEqual(second.records.count, 0, "the new sink sees only intervals begun after the swap")
    }

    static func testOSSignpostSinkRuns() {
        #if canImport(os)
        let metrics = NativePerformanceMetrics(sink: NativeOSSignpostSink())
        let token = metrics.begin(.initialSync, count: 3)
        metrics.end(token, outcome: .completed, count: 3)
        let value = metrics.measure(.jobListProjection, count: { (text: String) in text.count }) { "abc" }
        metrics.beginLaunch()
        metrics.endLaunch()
        expectEqual(value, "abc", "the OS signpost sink runs on the host and passes values through")
        expect(NativePerformanceMetrics.shared.hasSink, "the shared facade uses the OS signpost sink where os is available")
        #else
        expect(!NativePerformanceMetrics.shared.hasSink, "without os the shared facade has no sink")
        #endif
    }

    // MARK: Source scans

    static func testSourceScans(root: URL) {
        let sources = loadSources(root: root)
        expect(sources.count > 100, "the N/ sources were loaded from \(root.path)")
        guard let facade = sources.first(where: { $0.relativePath == "NativePerformanceMetrics.swift" }) else {
            expect(false, "N/NativePerformanceMetrics.swift exists")
            return
        }

        // The facade itself: synchronous, trap-free, and transmits nothing.
        let forbidden = [
            "async", "await", "Task", "DispatchQueue", "assert", "assertionFailure", "precondition",
            "preconditionFailure", "fatalError", "URLSession", "URLRequest", "UserDefaults", "FileManager",
            "NativeAnalytics", "NativeAnalyticsTransport", "NativeCrashReporting", "NativeCrashReporter",
            "SentrySDK", "PostHogSDK", "print", "Logger", "os_log", "NSLog",
        ]
        for token in forbidden {
            expect(facade.occurrences(of: token).isEmpty, "the facade never uses \(token)")
        }

        // Every OS-bound message is exactly the rendered metadata, public.
        let raw = String(facade.raw)
        let osCalls = ["beginInterval(", "endInterval("].flatMap { call in
            facade.codeText.ranges(of: "signposter.\(call)")
        }
        expect(osCalls.count == 2, "the OS sink makes exactly one begin and one end call (found \(osCalls.count))")
        let publicUses = raw.components(separatedBy: "privacy: .public").count - 1
        let allowedMessage = #""\(metadata, privacy: .public)""#
        let messageUses = raw.components(separatedBy: allowedMessage).count - 1
        expectEqual(publicUses, 2, "the facade marks exactly two arguments public")
        expectEqual(messageUses, 2, "both public arguments are the rendered metadata string")
        expect(!raw.contains("privacy: .private") && !raw.contains("privacy: .auto"),
               "no other privacy class is used")
        expect(facade.codeText.contains("signposter.beginInterval(interval.signpostName,")
               && facade.codeText.contains("signposter.endInterval(interval.signpostName,"),
               "the OS name argument is the interval's StaticString, never a runtime string")

        // Only the facade touches os signposting or the sink types.
        let osTokens = ["OSSignposter", "OSSignpostID", "OSSignpostIntervalState", "os_signpost",
                        "NativeOSSignpostSink", "NativePerformanceSignpostSink", "replaceSink",
                        "beginInterval", "endInterval", "emitEvent"]
        for file in sources where file.relativePath != "NativePerformanceMetrics.swift" {
            for token in osTokens where !file.occurrences(of: token).isEmpty {
                expect(false, "\(file.relativePath) uses \(token); signposts go through NativePerformanceMetrics only")
            }
        }

        // Call sites: an interval case and counts only; exact inventory.
        var inventory: [String] = []
        for file in sources where file.relativePath != "NativePerformanceMetrics.swift" {
            for hit in file.occurrences(of: "NativePerformanceMetrics") {
                let afterType = hit + "NativePerformanceMetrics".count
                let prefix = ".shared."
                guard file.codeSlice(afterType..<min(afterType + prefix.count, file.code.count)) == prefix,
                      let (method, afterMethod) = file.identifier(at: afterType + prefix.count)
                else {
                    expect(false, "\(file.relativePath):\(file.line(of: hit)) uses NativePerformanceMetrics only as `.shared.<call>`")
                    continue
                }
                let open = file.skipSpace(afterMethod)
                guard open < file.code.count, file.code[open] == "(", let close = file.matching(open) else {
                    expect(false, "\(file.relativePath):\(file.line(of: hit)) calls \(method) with an argument list")
                    continue
                }
                let arguments = file.codeSlice((open + 1)..<close)
                expect(!arguments.contains("\""),
                       "\(file.relativePath):\(file.line(of: hit)) passes no string literal to \(method)")
                expect(!arguments.contains("await"),
                       "\(file.relativePath):\(file.line(of: hit)) adds no suspension in \(method)'s arguments")
                let labels = Set(arguments.matches(of: #/([A-Za-z_]+):/#).map { String($0.output.1) })
                expect(labels.isSubset(of: ["count", "outcome"]),
                       "\(file.relativePath):\(file.line(of: hit)) passes only count/outcome labels (found \(labels.sorted()))")
                switch method {
                case "begin", "measure":
                    let first = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard first.hasPrefix("."), let (interval, _) = SourceFile(relativePath: "", text: String(first.dropFirst())).identifier(at: 0) else {
                        expect(false, "\(file.relativePath):\(file.line(of: hit)) names its interval as a literal case")
                        continue
                    }
                    inventory.append("\(file.relativePath) \(method) .\(interval)")
                    if method == "measure" {
                        let closures = file.trailingClosuresEnd(from: close + 1).closures
                        expect(closures.count == 1, "\(file.relativePath):\(file.line(of: hit)) measures one trailing closure")
                        for closure in closures {
                            let body = file.codeSlice(closure.range)
                            expect(!body.contains("await"),
                                   "\(file.relativePath):\(file.line(of: hit)) measures synchronous work only")
                        }
                    }
                case "beginLaunch", "endLaunch":
                    expect(arguments.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(file.relativePath):\(file.line(of: hit)) \(method) takes no arguments")
                    inventory.append("\(file.relativePath) \(method)")
                case "end":
                    break
                default:
                    expect(false, "\(file.relativePath):\(file.line(of: hit)) calls an unknown facade method \(method)")
                }
            }
        }
        let expectedInventory = [
            "AppStore.swift begin .backgroundRefresh",
            "AppStore.swift begin .deltaPull",
            "AppStore.swift begin .initialSync",
            "AppStore.swift begin .snapshotLoad",
            "AppStore.swift measure .legacyMigration",
            "InvoicesView.swift measure .invoiceListProjection",
            "JobsView.swift measure .jobListProjection",
            "TradeReadyNativeApp.swift beginLaunch",
            "TradeReadyNativeApp.swift endLaunch",
        ]
        expectEqual(inventory.sorted(), expectedInventory, "the instrumented call sites are exactly the pinned inventory")

        // Every begun interval in AppStore is ended.
        if let store = sources.first(where: { $0.relativePath == "AppStore.swift" }) {
            let begins = store.codeText.ranges(of: "NativePerformanceMetrics.shared.begin(").count
            let ends = store.codeText.ranges(of: "NativePerformanceMetrics.shared.end(").count
            expect(ends >= begins, "AppStore ends every interval it begins (begins \(begins), ends \(ends))")
        }
    }
}
