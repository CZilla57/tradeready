import Foundation

public extension Canonical {
    /// Versioned on-disk record of which accounts have had their local snapshot
    /// backfilled into the outbound queue, so the one-time enqueue never repeats.
    struct SyncBackfillDocument: Codable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int = currentSchemaVersion
        var completedSubjects: [String] = []
    }

    /// One-time enqueue of every local record that entered the snapshot without
    /// going through `AppStore`'s mutation methods.
    ///
    /// Records created by a user edit already enqueue at the call site, but
    /// legacy-migration imports and sample-seeding write straight to the snapshot
    /// and so never reach the outbound queue. On the first completed initial sync
    /// for an account this backfill enqueues the entire local snapshot — every
    /// collection row, the scrubbed settings blob, and each customer note — so the
    /// push carries records the cloud has never seen. It mirrors the React Native
    /// client's first-device `pushAllLocalToCloud` / `backfillLocalOnlyCollections`
    /// (`utils/sync.ts`), unified onto the single queue path.
    ///
    /// It is safe to call repeatedly: a per-subject flag gates it, and even if the
    /// flag file is lost the enqueue is idempotent — the queue de-duplicates
    /// last-writer-wins per `(table, recordId)` and the push upserts with
    /// `merge-duplicates`, so a redundant run cannot create duplicate or stale
    /// cloud rows. It is safe offline: enqueue is a local write and the durable
    /// queue is drained later by the coordinator.
    struct NativeSyncBackfill {
        let stateURL: URL
        private let fileManager: FileManager

        /// Collection families backfilled as `id`/`data` rows, paired with the
        /// backend table name the push transport expects.
        static let collectionTables = [
            "jobs", "invoices", "customers", "expenses", "pricebook",
            "recurringJobs", "recurringInvoices", "trips", "bookingRequests", "jobPhotos"
        ]

        init(stateURL: URL, fileManager: FileManager = .default) {
            self.stateURL = stateURL
            self.fileManager = fileManager
        }

        /// Whether `subject` has already been backfilled.
        func isCompleted(subject: String) -> Bool {
            load().completedSubjects.contains(subject)
        }

        /// Enqueues the whole local snapshot for `subject` the first time it is
        /// seen, then stamps the flag. Returns the number of items enqueued, or
        /// `0` when the subject was already backfilled (the flag short-circuits
        /// before any queue read or write).
        @discardableResult
        func backfillIfNeeded(
            subject: String,
            snapshot: Canonical.Snapshot,
            queue: Canonical.NativeMutationQueue
        ) throws -> Int {
            guard !isCompleted(subject: subject) else { return 0 }
            let enqueued = try enqueueLocalRecords(from: snapshot.payload, into: queue)
            try markCompleted(subject: subject)
            return enqueued
        }

        private func enqueueLocalRecords(
            from payload: Canonical.SnapshotPayload,
            into queue: Canonical.NativeMutationQueue
        ) throws -> Int {
            var count = 0

            func enqueueCollection<Record: Encodable>(_ table: String, _ records: [Record]?) throws {
                guard let records else { return }
                for record in records {
                    let value = try Self.jsonValue(record)
                    // A blob with no string `id` can never be addressed on the
                    // wire; skip it exactly as the RN backfill's `if (record.id)`
                    // guard does, rather than enqueue an unsendable row.
                    guard case let .object(fields) = value,
                          case let .string(id)? = fields["id"], !id.isEmpty
                    else { continue }
                    try queue.enqueue(table: table, op: .upsert, recordId: id, payload: value)
                    count += 1
                }
            }

            try enqueueCollection("jobs", payload.jobs)
            try enqueueCollection("invoices", payload.invoices)
            try enqueueCollection("customers", payload.customers)
            try enqueueCollection("expenses", payload.expenses)
            try enqueueCollection("pricebook", payload.pricebook)
            try enqueueCollection("recurringJobs", payload.recurringJobs)
            try enqueueCollection("recurringInvoices", payload.recurringInvoices)
            try enqueueCollection("trips", payload.trips)
            try enqueueCollection("bookingRequests", payload.bookingRequests)
            try enqueueCollection("jobPhotos", payload.jobPhotos)

            if let settings = payload.settings {
                let value = try Self.jsonValue(settings)
                if case var .object(fields) = value {
                    // Scrub credentials before they can reach the plain queue
                    // file — the same boundary the snapshot codec and the push
                    // transport both enforce.
                    for key in Canonical.SnapshotCodec.secureSettingsKeys {
                        fields.removeValue(forKey: key)
                    }
                    try queue.enqueue(
                        table: "settings", op: .upsert, recordId: "settings",
                        payload: .object(fields)
                    )
                    count += 1
                }
            }

            if let notes = payload.customerNotes {
                for (customerKey, note) in notes where !customerKey.isEmpty {
                    try queue.enqueue(
                        table: "customer_notes", op: .upsert, recordId: customerKey,
                        payload: .string(note)
                    )
                    count += 1
                }
            }

            return count
        }

        /// Removes the flag file so a re-created account re-runs the backfill.
        /// Called by the cross-owner and account-deletion scrub alongside the
        /// queue removal, so a new owner never inherits a stale "done" flag.
        func removeAll() throws {
            if fileManager.fileExists(atPath: stateURL.path) {
                try fileManager.removeItem(at: stateURL)
            }
        }

        private func load() -> SyncBackfillDocument {
            guard let data = try? Data(contentsOf: stateURL), !data.isEmpty,
                  let document = try? JSONDecoder().decode(SyncBackfillDocument.self, from: data),
                  document.schemaVersion == SyncBackfillDocument.currentSchemaVersion
            else { return SyncBackfillDocument() }
            return document
        }

        private func markCompleted(subject: String) throws {
            var document = load()
            guard !document.completedSubjects.contains(subject) else { return }
            document.completedSubjects.append(subject)
            try fileManager.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(document).write(to: stateURL, options: .atomic)
        }

        private static func jsonValue<Record: Encodable>(_ record: Record) throws -> Canonical.JSONValue {
            try JSONDecoder().decode(Canonical.JSONValue.self, from: encoder.encode(record))
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()
    }
}
