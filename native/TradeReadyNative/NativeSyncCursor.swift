import Foundation

public extension Canonical {
    /// Per-table high-water marks for the incremental delta pull.
    ///
    /// Each value is a **server** `updated_at` string returned by Supabase, never
    /// a device clock reading — the database stamps `updated_at` authoritatively
    /// (`supabase/migrations/20260831_updated_at_server_authority.sql`), so a
    /// device with a fast or slow clock can never poison the cursor. The version
    /// is load-bearing: any cursor that is not the current version reads as empty
    /// and triggers one safe, idempotent full pull, mirroring the React Native
    /// client's v2 cursor (`utils/sync.ts`).
    struct NativeSyncCursor: Codable, Equatable {
        public static let currentVersion = 2
        /// Re-pull this far behind each watermark so a transaction that committed
        /// just behind the previous high-water mark is still seen next pass. The
        /// overlap is harmless because every remote merge is idempotent.
        static let overlap: TimeInterval = 5 * 60
        static let epoch = "1970-01-01T00:00:00.000Z"

        public var version: Int
        public var tables: [String: String]

        public init(version: Int = NativeSyncCursor.currentVersion, tables: [String: String] = [:]) {
            self.version = version
            self.tables = tables
        }

        public static func empty() -> NativeSyncCursor { NativeSyncCursor() }

        /// The `updated_at=gte.<value>` lower bound for `table`: epoch when there
        /// is no usable watermark yet, otherwise the watermark minus the overlap.
        func pullStart(for table: String) -> String {
            guard let watermark = tables[table], let date = Self.parse(watermark) else {
                return Self.epoch
            }
            let start = max(0, date.timeIntervalSince1970 - Self.overlap)
            return Self.format(Date(timeIntervalSince1970: start))
        }

        /// Returns a copy whose `table` watermark advances to `candidate` when it
        /// is strictly later than the current one (raw server string preserved).
        func advancing(_ table: String, to candidate: String) -> NativeSyncCursor {
            var next = self
            next.tables[table] = Self.later(tables[table], candidate)
            return next
        }

        static func later(_ current: String?, _ candidate: String) -> String {
            guard let current else { return candidate }
            guard let candidateDate = parse(candidate) else { return current }
            guard let currentDate = parse(current), currentDate >= candidateDate else {
                return candidate
            }
            return current
        }

        static func parse(_ value: String) -> Date? {
            withFraction.date(from: value) ?? withoutFraction.date(from: value)
        }

        private static func format(_ date: Date) -> String {
            withFraction.string(from: date)
        }

        private static let withFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static let withoutFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    }

    /// File-backed persistence for the delta-pull cursor. A missing, corrupt, or
    /// wrong-version file reads as an empty cursor, so a lost cursor costs one
    /// idempotent full pull rather than silently skipping remote changes.
    struct NativeSyncCursorStore {
        let fileURL: URL
        private let fileManager: FileManager

        public init(fileURL: URL, fileManager: FileManager = .default) {
            self.fileURL = fileURL
            self.fileManager = fileManager
        }

        public func load() -> NativeSyncCursor {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
                  let cursor = try? JSONDecoder().decode(NativeSyncCursor.self, from: data),
                  cursor.version == NativeSyncCursor.currentVersion
            else { return .empty() }
            return cursor
        }

        public func save(_ cursor: NativeSyncCursor) throws {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(cursor).write(to: fileURL, options: .atomic)
        }

        /// Removes the cursor so another account never resumes from this one's
        /// watermarks — called by the cross-owner and account-deletion scrub.
        public func removeAll() throws {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()
    }
}
