import Foundation

@main
struct MutationQueueTests {
    static func main() throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tradeready-mutation-queue-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        func makeQueue(_ name: String, now: @escaping () -> Date = Date.init) -> Canonical.NativeMutationQueue {
            Canonical.NativeMutationQueue(
                fileURL: root.appendingPathComponent("\(name).json"),
                now: now
            )
        }

        func job(_ id: String, title: String) -> Canonical.JSONValue {
            .object(["id": .string(id), "title": .string(title)])
        }

        // Round-trip and deterministic timestamp.
        let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
        let q1 = makeQueue("roundtrip", now: { fixedDate })
        try q1.enqueue(table: "jobs", op: .upsert, recordId: "j1", payload: job("j1", title: "First"))
        let loaded = q1.load()
        expect(loaded.count == 1, "one enqueued item round-trips")
        expect(loaded.first?.table == "jobs" && loaded.first?.op == .upsert
               && loaded.first?.recordId == "j1", "queued item preserves table/op/id")
        expect(loaded.first?.payload == job("j1", title: "First"), "queued item preserves the record blob")
        expect(loaded.first?.ts == ISO8601DateFormatter.tradeReady.string(from: fixedDate),
               "enqueue stamps the injected clock, not the device clock at read time")

        // Last-writer-wins dedup by (table, recordId).
        let q2 = makeQueue("dedup")
        try q2.enqueue(table: "jobs", op: .upsert, recordId: "j1", payload: job("j1", title: "Old"))
        try q2.enqueue(table: "jobs", op: .upsert, recordId: "j1", payload: job("j1", title: "New"))
        expect(q2.load().count == 1, "a second upsert to the same record replaces the first")
        expect(q2.load().first?.payload == job("j1", title: "New"), "dedup keeps the latest payload")

        // A different record in the same table is a distinct entry.
        try q2.enqueue(table: "jobs", op: .upsert, recordId: "j2", payload: job("j2", title: "Other"))
        expect(q2.load().count == 2, "a different record id is a separate queue entry")

        // Related domain changes publish as one LWW batch with one timestamp.
        let q2b = makeQueue("batch", now: { fixedDate })
        try q2b.enqueue(table: "customers", op: .upsert, recordId: "c1", payload: job("c1", title: "Old"))
        try q2b.enqueueBatch([
            .init(table: "customers", op: .upsert, recordId: "c1", payload: job("c1", title: "Merged")),
            .init(table: "customers", op: .delete, recordId: "c2", payload: job("c2", title: "Ignored")),
            .init(table: "jobs", op: .upsert, recordId: "j1", payload: job("j1", title: "Moved"))
        ])
        let batch = q2b.load()
        expect(batch.count == 3, "a queue batch atomically replaces and appends all related records")
        expect(batch.first(where: { $0.recordId == "c1" })?.payload == job("c1", title: "Merged"),
               "a batch applies last-writer-wins replacement")
        expect(batch.first(where: { $0.recordId == "c2" })?.op == .delete
               && batch.first(where: { $0.recordId == "c2" })?.payload == nil,
               "a batch strips delete payloads")
        expect(Set(batch.map(\.ts)).count == 1,
               "every record in one queue batch receives the same transaction timestamp")

        // An upsert followed by a delete collapses to a single delete with no
        // stale payload — the push must never send an upsert then a stale delete.
        let q3 = makeQueue("upsert-then-delete")
        try q3.enqueue(table: "invoices", op: .upsert, recordId: "inv1", payload: job("inv1", title: "x"))
        try q3.enqueue(table: "invoices", op: .delete, recordId: "inv1", payload: nil)
        expect(q3.load().count == 1, "upsert then delete of one record collapses to a single change")
        expect(q3.load().first?.op == .delete && q3.load().first?.payload == nil,
               "the surviving change is a payload-free delete")

        // A payload passed with a delete is dropped.
        let q3b = makeQueue("delete-drops-payload")
        try q3b.enqueue(table: "jobs", op: .delete, recordId: "j9", payload: job("j9", title: "ignore"))
        expect(q3b.load().first?.payload == nil, "a delete never retains a payload")

        // A push may be suspended while a newer local mutation replaces one of
        // its items. A stale success acknowledgement must not erase that write.
        let q3c = makeQueue("in-flight-replacement")
        try q3c.enqueue(
            table: "jobs", op: .delete, recordId: "j-undo", payload: nil
        )
        let startedDelete = q3c.load()
        try q3c.enqueue(
            table: "jobs", op: .upsert, recordId: "j-undo",
            payload: job("j-undo", title: "Restored")
        )
        try q3c.enqueue(
            table: "invoices", op: .upsert, recordId: "i-new",
            payload: job("i-new", title: "Joined in flight")
        )
        let reconciled = try q3c.reconcilePush(startedItems: startedDelete, remaining: [])
        expect(reconciled.count == 2,
               "push reconciliation retains replacements and newly queued records")
        expect(reconciled.first(where: { $0.recordId == "j-undo" })?.op == .upsert,
               "a restored-record upsert survives its older delete acknowledgement")
        expect(reconciled.contains(where: { $0.recordId == "i-new" }),
               "a different record queued during push also survives acknowledgement")

        let q3d = makeQueue("in-flight-failure")
        try q3d.enqueue(
            table: "jobs", op: .upsert, recordId: "j-failed",
            payload: job("j-failed", title: "Retry")
        )
        let failedStarted = q3d.load()
        let retainedAfterFailure = try q3d.reconcilePush(
            startedItems: failedStarted,
            remaining: failedStarted
        )
        expect(retainedAfterFailure == failedStarted,
               "unchanged transient failures remain queued exactly once")

        // Collection diff: removed ids become deletes, present records upserts.
        let q4 = makeQueue("collection-diff")
        try q4.enqueueCollectionChanges(
            table: "customers",
            previousIDs: ["c1", "c2", "c3"],
            currentRecords: [
                (id: "c1", payload: job("c1", title: "Kept")),
                (id: "c4", payload: job("c4", title: "New"))
            ]
        )
        let diff = q4.load()
        let deletes = diff.filter { $0.op == .delete }.map(\.recordId).sorted()
        let upserts = diff.filter { $0.op == .upsert }.map(\.recordId).sorted()
        expect(deletes == ["c2", "c3"], "collection diff enqueues deletes for removed ids")
        expect(upserts == ["c1", "c4"], "collection diff enqueues upserts for every current record")

        // Corrupt file recovers to an empty queue.
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("{ not json".utf8).write(to: corruptURL)
        let corruptQueue = Canonical.NativeMutationQueue(fileURL: corruptURL)
        expect(corruptQueue.load().isEmpty, "a corrupt queue file reads as empty")

        // A future/foreign schema version reads empty rather than mis-decoding.
        let wrongVersionURL = root.appendingPathComponent("wrong-version.json")
        try Data(#"{"schemaVersion":999,"items":[]}"#.utf8).write(to: wrongVersionURL)
        expect(Canonical.NativeMutationQueue(fileURL: wrongVersionURL).load().isEmpty,
               "a queue file from an unknown schema version reads as empty")

        // save retains the previous good file as a backup.
        let q5 = makeQueue("backup")
        try q5.enqueue(table: "jobs", op: .upsert, recordId: "j1", payload: job("j1", title: "v1"))
        try q5.enqueue(table: "jobs", op: .upsert, recordId: "j2", payload: job("j2", title: "v2"))
        expect(fileManager.fileExists(atPath: q5.fileURL.appendingPathExtension("backup").path),
               "a second save leaves a decodable backup of the previous queue")

        // pruneRecords drops matching record ids across tables.
        let q6 = makeQueue("prune")
        try q6.enqueue(table: "jobs", op: .upsert, recordId: "sample_1", payload: job("sample_1", title: "s"))
        try q6.enqueue(table: "jobs", op: .upsert, recordId: "real_1", payload: job("real_1", title: "r"))
        let removed = try q6.pruneRecords(["sample_1"])
        expect(removed == 1 && q6.load().map(\.recordId) == ["real_1"],
               "pruneRecords drops only the named record ids")

        // Phase 12 (12.00b.2-L, P12-017): a guarded upsert keeps its guard
        // through the file; a replacement stays guarded only while every
        // change it carries is, with the earlier guard.
        let older = "2026-09-27T10:00:00.123456+00:00"
        let newer = "2026-09-27T10:05:00.5+00:00"
        let q7 = makeQueue("guard")
        try q7.enqueue(table: "bookingRequests", op: .upsert, recordId: "r1", payload: job("r1", title: "stamp"),
                       ifUnchangedSince: older)
        expect(q7.load().first?.ifUnchangedSince == older, "a guarded upsert keeps its guard in the queue file")
        try q7.enqueue(table: "bookingRequests", op: .upsert, recordId: "r1", payload: job("r1", title: "stamp 2"),
                       ifUnchangedSince: newer)
        expect(q7.load().first?.ifUnchangedSince == older,
               "a guarded change replacing a guarded one keeps the earlier guard")
        try q7.enqueue(table: "customers", op: .upsert, recordId: "c1", payload: job("c1", title: "owner edit"))
        try q7.enqueue(table: "customers", op: .upsert, recordId: "c1", payload: job("c1", title: "edit + fill"),
                       ifUnchangedSince: newer)
        expect(q7.load().first { $0.recordId == "c1" }?.ifUnchangedSince == nil,
               "a guarded change replacing a whole-record write stays a whole-record write")
        try q7.enqueue(table: "bookingRequests", op: .upsert, recordId: "r1", payload: job("r1", title: "owner edit"))
        expect(q7.load().first { $0.recordId == "r1" }?.ifUnchangedSince == nil,
               "a whole-record write replacing a guarded change is a whole-record write")
        try q7.enqueue(table: "jobs", op: .delete, recordId: "j9", payload: nil)
        try q7.enqueue(table: "jobs", op: .upsert, recordId: "j9", payload: job("j9", title: "undo"),
                       ifUnchangedSince: older)
        expect(q7.load().first { $0.recordId == "j9" }?.ifUnchangedSince == nil,
               "a guarded change replacing a delete is a whole-record write")
        let legacyURL = root.appendingPathComponent("legacy.json")
        try Data(#"{"schemaVersion":1,"items":[{"table":"jobs","op":"upsert","recordId":"j1","payload":{"id":"j1"},"ts":"2026-09-27T10:00:00.000Z"}]}"#.utf8)
            .write(to: legacyURL)
        let legacy = Canonical.NativeMutationQueue(fileURL: legacyURL).load()
        expect(legacy.count == 1 && legacy.first?.ifUnchangedSince == nil,
               "a queue file written before the guard reads as whole-record writes")

        // removeAll clears the queue and its backup.
        try q5.removeAll()
        expect(!fileManager.fileExists(atPath: q5.fileURL.path)
               && !fileManager.fileExists(atPath: q5.fileURL.appendingPathExtension("backup").path),
               "removeAll deletes both the queue and its backup")
        expect(q5.load().isEmpty, "a removed queue reads as empty")

        if failures == 0 { print("PASS: native mutation queue tests") }
        else { exit(1) }
    }
}

private extension ISO8601DateFormatter {
    static let tradeReady: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
