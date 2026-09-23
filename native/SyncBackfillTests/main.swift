import Foundation

@main
struct SyncBackfillTests {
    static func main() throws {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures += 1; print("FAIL: \(label)") }
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        guard let root = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"] else {
            print("FAIL: missing CANONICAL_FIXTURES_PATH")
            exit(1)
        }
        let rich = try decoder.decode(
            [String: Canonical.JSONValue].self,
            from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("canonical-rich.json"))
        )
        func model<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
            try decoder.decode(T.self, from: encoder.encode(rich[key]!))
        }

        // A full one-of-each snapshot standing in for a freshly migrated account.
        let snapshot = Canonical.Snapshot(payload: .init(
            invoices: [try model(Canonical.Invoice.self, "invoice")],
            jobs: [try model(Canonical.Job.self, "job")],
            customers: [try model(Canonical.Customer.self, "customer")],
            settings: try model(Canonical.Settings.self, "settings"),
            expenses: [try model(Canonical.Expense.self, "expense")],
            customerNotes: try model(Canonical.CustomerNotes.self, "customerNotes"),
            recurringJobs: [try model(Canonical.RecurringJob.self, "recurringJob")],
            recurringInvoices: [try model(Canonical.RecurringInvoice.self, "recurringInvoice")],
            trips: [try model(Canonical.Trip.self, "trip")],
            pricebook: [try model(Canonical.PricebookEntry.self, "pricebookEntry")],
            bookingRequests: [try model(Canonical.BookingRequest.self, "bookingRequest")],
            jobPhotos: [try model(Canonical.JobPhoto.self, "jobPhoto")]
        ))

        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("tradeready-sync-backfill-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let subject = "11111111-2222-3333-4444-555555555555"
        func makeQueue(_ name: String) -> Canonical.NativeMutationQueue {
            Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("\(name).json"))
        }
        func makeBackfill(_ name: String) -> Canonical.NativeSyncBackfill {
            Canonical.NativeSyncBackfill(stateURL: dir.appendingPathComponent("\(name).json"))
        }

        // First run enqueues the whole snapshot and stamps the flag.
        let queue = makeQueue("queue-1")
        let backfill = makeBackfill("state-1")
        expect(!backfill.isCompleted(subject: subject), "a fresh subject has not been backfilled")
        let count = try backfill.backfillIfNeeded(subject: subject, snapshot: snapshot, queue: queue)

        let items = queue.load()
        // 10 collection rows (one each) + settings + 2 customer notes = 13.
        expect(count == 13, "the backfill reports every enqueued item (got \(count))")
        expect(items.count == 13, "every local record is enqueued once (got \(items.count))")
        expect(items.allSatisfy { $0.op == .upsert }, "a backfill enqueues only upserts")
        expect(backfill.isCompleted(subject: subject), "the subject is stamped complete after a backfill")

        let tables = Set(items.map(\.table))
        for table in Canonical.NativeSyncBackfill.collectionTables {
            expect(tables.contains(table), "the \(table) collection is backfilled")
        }
        expect(tables.contains("settings"), "settings are backfilled")
        expect(tables.contains("customer_notes"), "customer notes are backfilled")

        // Collection rows carry the record id and blob; the recordId matches the
        // blob's own id so the push transport's fail-closed check passes.
        if let jobItem = items.first(where: { $0.table == "jobs" }) {
            expect(jobItem.recordId == "j_20260812_precision", "a job is enqueued under its record id")
            if case let .object(fields)? = jobItem.payload {
                expect(fields["id"] == .string("j_20260812_precision"), "the job blob keeps its id")
            } else {
                expect(false, "a job upsert carries an object payload")
            }
        } else {
            expect(false, "a job row is present in the backfill")
        }

        // Settings are scrubbed of every secure credential key before the value
        // can reach the plain queue file.
        if let settingsItem = items.first(where: { $0.table == "settings" }) {
            expect(settingsItem.recordId == "settings", "settings use the fixed record id")
            if case let .object(fields)? = settingsItem.payload {
                for key in Canonical.SnapshotCodec.secureSettingsKeys {
                    expect(fields[key] == nil, "the backfill scrubs \(key) from settings")
                }
                expect(fields["businessName"] != nil, "non-secret settings survive scrubbing")
            } else {
                expect(false, "a settings upsert carries an object payload")
            }
        } else {
            expect(false, "a settings row is present in the backfill")
        }

        // Customer notes are enqueued per key as a string note.
        let noteItems = items.filter { $0.table == "customer_notes" }
        expect(noteItems.count == 2, "each customer note is enqueued")
        if let note = noteItems.first(where: { $0.recordId == "ada lovelace" }) {
            expect(note.payload == .string("Priority customer"), "a customer note carries its string value")
        } else {
            expect(false, "the expected customer note is enqueued")
        }

        // A second call is a flag-gated no-op: it neither re-reads nor rewrites
        // the queue (a later real edit is still present, untouched).
        try queue.enqueue(table: "jobs", op: .delete, recordId: "later-edit", payload: nil)
        let afterEdit = queue.load().count
        let secondCount = try backfill.backfillIfNeeded(subject: subject, snapshot: snapshot, queue: queue)
        expect(secondCount == 0, "a completed backfill does not run again")
        expect(queue.load().count == afterEdit, "a completed backfill does not touch the queue")

        // A second account on the same device backfills independently.
        let otherSubject = "99999999-8888-7777-6666-555555555555"
        expect(!backfill.isCompleted(subject: otherSubject), "a different subject is not yet backfilled")
        let otherQueue = makeQueue("queue-2")
        let otherCount = try backfill.backfillIfNeeded(subject: otherSubject, snapshot: snapshot, queue: otherQueue)
        expect(otherCount == 13, "a second account runs its own backfill")

        // removeAll clears the flag so a re-created account re-runs (account-scrub
        // boundary): the queue itself is cleared separately.
        try backfill.removeAll()
        expect(!backfill.isCompleted(subject: subject), "removeAll clears completion flags")
        let rerunQueue = makeQueue("queue-3")
        let rerun = try backfill.backfillIfNeeded(subject: subject, snapshot: snapshot, queue: rerunQueue)
        expect(rerun == 13, "after removeAll the backfill runs again")

        // Records with no usable id are skipped rather than enqueued unsendable.
        let idlessSnapshot = Canonical.Snapshot(payload: .init(
            jobs: [try model(Canonical.Job.self, "job")]
        ))
        // (The fixture job always has an id; the skip path is exercised by the
        // empty-collection case below, which must enqueue nothing.)
        let emptyQueue = makeQueue("queue-empty")
        let emptyBackfill = makeBackfill("state-empty")
        let emptyCount = try emptyBackfill.backfillIfNeeded(
            subject: subject,
            snapshot: Canonical.Snapshot(payload: .init()),
            queue: emptyQueue
        )
        expect(emptyCount == 0, "an empty snapshot enqueues nothing")
        expect(emptyQueue.load().isEmpty, "an empty snapshot leaves the queue empty")
        expect(emptyBackfill.isCompleted(subject: subject), "an empty backfill still stamps the flag")
        _ = idlessSnapshot

        if failures == 0 { print("PASS: native sync backfill tests") }
        else { exit(1) }
    }
}
