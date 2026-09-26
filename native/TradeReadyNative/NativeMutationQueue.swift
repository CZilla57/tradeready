import Foundation

public extension Canonical {
    /// The write direction of a queued mutation. It mirrors the React Native
    /// sync queue (`utils/sync.ts`): every local change is an `upsert` of the
    /// current record blob or a soft `delete` by id.
    enum MutationOp: String, Codable, Equatable {
        case upsert
        case delete
    }

    /// One durable, retryable local change awaiting a cloud push.
    ///
    /// `payload` holds the record blob for an `upsert` and is absent for a
    /// `delete`. `ts` records when the change was enqueued for support ordering
    /// only — it is never sent as `updated_at`, which the database stamps
    /// authoritatively (`supabase/migrations/20260831_updated_at_server_authority.sql`).
    struct MutationItem: Codable, Equatable {
        public var table: String
        public var op: MutationOp
        public var recordId: String
        public var payload: JSONValue?
        public var ts: String

        public init(
            table: String,
            op: MutationOp,
            recordId: String,
            payload: JSONValue?,
            ts: String
        ) {
            self.table = table
            self.op = op
            self.recordId = recordId
            self.payload = payload
            self.ts = ts
        }
    }

    /// One unstamped queue write. Multi-record domain transactions use drafts
    /// so every last-writer-wins replacement is published in one atomic queue
    /// save rather than exposing a partially enqueued transaction.
    struct MutationDraft: Equatable {
        public var table: String
        public var op: MutationOp
        public var recordId: String
        public var payload: JSONValue?

        public init(
            table: String,
            op: MutationOp,
            recordId: String,
            payload: JSONValue?
        ) {
            self.table = table
            self.op = op
            self.recordId = recordId
            self.payload = payload
        }
    }
}

extension Canonical {
    /// Versioned on-disk envelope for the pending mutation queue.
    struct MutationQueueDocument: Codable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int = currentSchemaVersion
        var items: [MutationItem] = []
    }

    /// Durable, file-backed queue of local changes awaiting a cloud push.
    ///
    /// Callers must serialize access (the app uses it from `AppStore`'s main
    /// actor, like ``SnapshotRepository``). Enqueue is last-writer-wins per
    /// `(table, recordId)`: a newer change to a record replaces any still-pending
    /// change for the same record so the push always carries the latest state and
    /// never an upsert followed by a stale delete. A corrupt or legacy queue file
    /// recovers to an empty queue; the next local save re-enqueues, and the pull
    /// side is idempotent, so no committed change is silently lost by that reset.
    struct NativeMutationQueue {
        let fileURL: URL
        private let fileManager: FileManager
        private let now: () -> Date

        init(
            fileURL: URL,
            fileManager: FileManager = .default,
            now: @escaping () -> Date = Date.init
        ) {
            self.fileURL = fileURL
            self.fileManager = fileManager
            self.now = now
        }

        /// The current queue, oldest change first. Missing, corrupt, or
        /// unversioned files intentionally read as empty rather than throwing.
        func load() -> [MutationItem] {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
            guard let document = try? Self.decoder.decode(MutationQueueDocument.self, from: data),
                  document.schemaVersion == MutationQueueDocument.currentSchemaVersion
            else { return [] }
            return document.items
        }

        /// Phase 12 (12.06): the queue, or nil when a file is on disk that
        /// `load` would read as empty because it cannot be read or decoded.
        /// The rollback-readiness check fails closed on it.
        func loadIfReadable() -> [MutationItem]? {
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            guard !data.isEmpty else { return [] }
            guard let document = try? Self.decoder.decode(MutationQueueDocument.self, from: data),
                  document.schemaVersion == MutationQueueDocument.currentSchemaVersion
            else { return nil }
            return document.items
        }

        /// Atomically publishes the queue, retaining the previous decodable file
        /// as a last-known-good backup so a torn write cannot lose pending work.
        func save(_ items: [MutationItem]) throws {
            try createParentDirectory()
            if let currentBytes = try? Data(contentsOf: fileURL),
               (try? Self.decoder.decode(MutationQueueDocument.self, from: currentBytes)) != nil {
                try atomicWrite(currentBytes, to: fileURL.appendingPathExtension("backup"))
            }
            let document = MutationQueueDocument(items: items)
            try atomicWrite(try Self.encoder.encode(document), to: fileURL)
        }

        /// Records one local change, replacing any pending change to the same
        /// record in the same table. Returns the resulting queue.
        @discardableResult
        func enqueue(
            table: String,
            op: MutationOp,
            recordId: String,
            payload: JSONValue?
        ) throws -> [MutationItem] {
            try enqueueBatch([
                MutationDraft(table: table, op: op, recordId: recordId, payload: payload)
            ])
        }

        /// Applies a related group of last-writer-wins changes in memory and
        /// atomically publishes the resulting queue once. Later drafts in the
        /// same batch replace earlier drafts for the same `(table, recordId)`.
        @discardableResult
        func enqueueBatch(_ drafts: [MutationDraft]) throws -> [MutationItem] {
            guard !drafts.isEmpty else { return load() }
            var items = load()
            let timestamp = Self.iso8601.string(from: now())
            for draft in drafts {
                items.removeAll {
                    $0.table == draft.table && $0.recordId == draft.recordId
                }
                items.append(
                    MutationItem(
                        table: draft.table,
                        op: draft.op,
                        recordId: draft.recordId,
                        payload: draft.op == .delete ? nil : draft.payload,
                        ts: timestamp
                    )
                )
            }
            try save(items)
            return items
        }

        /// Commits one push acknowledgement without discarding mutations that
        /// replaced or joined the queue while the transport was suspended.
        /// Items unchanged since `startedItems` follow the push result; newer
        /// last-writer-wins items remain queued for the coordinator's rerun.
        @discardableResult
        func reconcilePush(
            startedItems: [MutationItem],
            remaining: [MutationItem]
        ) throws -> [MutationItem] {
            var reconciled = remaining
            var startedByKey: [MutationKey: MutationItem] = [:]
            for item in startedItems { startedByKey[MutationKey(item)] = item }
            for current in load() {
                let key = MutationKey(current)
                guard startedByKey[key] != current else { continue }
                reconciled.removeAll { MutationKey($0) == key }
                reconciled.append(current)
            }
            try save(reconciled)
            return reconciled
        }

        /// Diffs a collection save into queued changes: an `upsert` for every
        /// current record and a `delete` for every id that was present before
        /// and is now gone. Mirrors `enqueueCollectionChanges` in the React
        /// Native client so both apps write the same backend contract.
        @discardableResult
        func enqueueCollectionChanges(
            table: String,
            previousIDs: [String],
            currentRecords: [(id: String, payload: JSONValue)]
        ) throws -> [MutationItem] {
            let currentIDs = Set(currentRecords.map(\.id))
            for id in previousIDs where !currentIDs.contains(id) {
                _ = try enqueue(table: table, op: .delete, recordId: id, payload: nil)
            }
            // Route each upsert through enqueue so per-record dedup and the
            // shared timestamp source stay in one place.
            var items = load()
            for record in currentRecords {
                items = try enqueue(
                    table: table,
                    op: .upsert,
                    recordId: record.id,
                    payload: record.payload
                )
            }
            return items
        }

        /// Drops queued changes whose `recordId` is in the given set. Used by the
        /// sample-id migration: legacy-id upserts can never succeed under RLS and
        /// the same records are re-enqueued under their new ids by the migration.
        @discardableResult
        func pruneRecords(_ recordIds: Set<String>) throws -> Int {
            let items = load()
            let kept = items.filter { !recordIds.contains($0.recordId) }
            let removed = items.count - kept.count
            if removed > 0 { try save(kept) }
            return removed
        }

        /// Removes the queue and its backup — used by the cross-owner and
        /// account-deletion scrub so another account never inherits pending work.
        func removeAll() throws {
            for url in [fileURL.appendingPathExtension("backup"), fileURL]
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        private func atomicWrite(_ data: Data, to url: URL) throws {
            try data.write(to: url, options: .atomic)
        }

        private func createParentDirectory() throws {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        private struct MutationKey: Hashable {
            let table: String
            let recordID: String

            init(_ item: MutationItem) {
                table = item.table
                recordID = item.recordId
            }
        }

        private static let iso8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()

        private static let decoder = JSONDecoder()
    }
}
