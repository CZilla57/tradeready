import Foundation

// Shared host-test support (11.12): a signpost sink that records what the
// `NativePerformanceMetrics` facade emits, so a suite can check the interval
// names, the begin/end pairing and the exact metadata strings. Compiled into
// `run-performance-metrics-tests.sh` and `run-poor-network-tests.sh`.

final class RecordingSignpostSink: NativePerformanceSignpostSink, @unchecked Sendable {
    enum Phase: Equatable {
        case begin
        case end
    }

    struct Record: Equatable {
        let phase: Phase
        let interval: NativePerformanceInterval
        let metadata: String
    }

    /// The opaque state handed back on `begin`; `end` must return the same one.
    private final class State {
        let interval: NativePerformanceInterval
        init(_ interval: NativePerformanceInterval) { self.interval = interval }
    }

    var isEnabled = true
    private(set) var records: [Record] = []
    /// Ends whose state was not issued by this sink or was issued for another interval.
    private(set) var mismatchedEnds = 0
    private var open: [State] = []

    func beginInterval(_ interval: NativePerformanceInterval, metadata: String) -> AnyObject? {
        let state = State(interval)
        open.append(state)
        records.append(Record(phase: .begin, interval: interval, metadata: metadata))
        return state
    }

    func endInterval(_ interval: NativePerformanceInterval, state: AnyObject?, metadata: String) {
        if let state = state as? State, let index = open.firstIndex(where: { $0 === state }), state.interval == interval {
            open.remove(at: index)
        } else {
            mismatchedEnds += 1
        }
        records.append(Record(phase: .end, interval: interval, metadata: metadata))
    }

    /// Intervals begun and not yet ended.
    var openCount: Int { open.count }

    func records(for interval: NativePerformanceInterval) -> [Record] {
        records.filter { $0.interval == interval }
    }

    func reset() {
        records.removeAll()
        open.removeAll()
        mismatchedEnds = 0
    }
}
