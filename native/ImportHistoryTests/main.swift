import Foundation

// Device-local import history tests (task 9.07).
//
// Ports __tests__/importHistory.test.ts semantics against a real file store:
// newest-first prepend, same-file lookup per entity, deterministic batch ids,
// undo bookkeeping, and crash-safe degradation on a corrupt file.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func record(_ batchID: String, entity: String = "expenses", hash: String) -> NativeImportBatchRecord {
    NativeImportBatchRecord(
        batchId: batchID,
        entity: entity,
        fileHash: hash,
        date: "2026-03-01",
        counts: NativeImportCountsCodable(NativeImportCounts(ok: 3, skip: 1, flag: 0, created: 2, matched: 1))
    )
}

private func testHistory() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-import-history-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    expectEqual(NativeImportHistory.load(from: directory), [], "missing file reads as empty history")

    expect(NativeImportHistory.record(record("imp_1", hash: "aaa"), in: directory), "first batch records")
    expect(NativeImportHistory.record(record("imp_2", hash: "bbb"), in: directory), "second batch records")
    let history = NativeImportHistory.load(from: directory)
    expectEqual(history.count, 2, "two batches persisted")
    expectEqual(history.first?.batchId, "imp_2", "newest batch is first")
    expectEqual(history.last?.batchId, "imp_1", "older batch second")

    expectEqual(NativeImportHistory.findBatch(entity: "expenses", fileHash: "aaa", in: directory)?.batchId, "imp_1", "same-file lookup hits")
    expect(NativeImportHistory.findBatch(entity: "expenses", fileHash: "zzz", in: directory) == nil, "unknown hash misses")
    expect(NativeImportHistory.findBatch(entity: "jobs", fileHash: "aaa", in: directory) == nil, "entity must match too")

    expect(NativeImportHistory.record(record("imp_3", entity: "jobs", hash: "aaa"), in: directory), "same hash, different entity records")
    expectEqual(NativeImportHistory.findBatch(entity: "jobs", fileHash: "aaa", in: directory)?.batchId, "imp_3", "per-entity lookup")

    expect(NativeImportHistory.remove(batchID: "imp_2", in: directory), "batch removal")
    expectEqual(NativeImportHistory.load(from: directory).map(\.batchId), ["imp_3", "imp_1"], "removed batch is gone")

    expectEqual(NativeImportHistory.newBatchID(nowMs: 1_772_323_200_000, counter: 7), "imp_1772323200000_7", "batch id shape")

    // Crash safety: a corrupt file degrades to "no history" instead of throwing.
    let url = directory.appendingPathComponent(NativeImportHistory.storageKey)
    try? Data("{ not json".utf8).write(to: url)
    expectEqual(NativeImportHistory.load(from: directory), [], "corrupt history reads as empty")
    expect(NativeImportHistory.record(record("imp_4", hash: "ccc"), in: directory), "recording recovers from corruption")
    expectEqual(NativeImportHistory.load(from: directory).map(\.batchId), ["imp_4"], "history rewritten cleanly")

    // Counts survive the Codable round-trip.
    expectEqual(NativeImportHistory.load(from: directory).first?.counts.counts.created, 2, "counts round-trip")
}

testHistory()

if failures == 0 {
    print("ImportHistoryTests: all checks passed")
} else {
    print("ImportHistoryTests: \(failures) failure(s)")
    exit(1)
}
