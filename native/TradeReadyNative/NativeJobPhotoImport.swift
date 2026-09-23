import Foundation
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif

/// Local capture/import pipeline for job photos (Batch 1).
///
/// Contract (mirrors `NativeJobPhotoTransfer` + `NativeJobPhotoStorage` exactly,
/// never weakened):
/// - Only JPEG bytes `<= 6 MiB` with SOI/EOI markers are stored.
/// - IDs match `p<digits>_<base36>` (`NativeJobPhotoTransferService.isValidPhotoID`).
/// - Bytes live at the deterministic `<root>/job-photos/<id>.jpg`.
/// - Local bytes always win: an existing file is never overwritten, including
///   on a download race (`installDownloadedBytes` keeps the same guarantee).
/// - `customerVisible` is fail-closed: reads require `== true`, imports stamp
///   an explicit `false`, and the toggle mutates only that field.
enum NativeJobPhotoImportError: Error, Equatable {
    case emptyJobID
    case invalidImage
    case photoTooLarge
    case duplicatePhotoID
    case writeFailed
    case recordNotFound
}

extension Canonical.JobPhoto {
    init(
        importedID id: String,
        jobID: String,
        createdAt: String,
        customerVisible: Bool?,
        width: Decimal?,
        height: Decimal?
    ) {
        self.id = id
        self.jobId = jobID
        self.createdAt = createdAt
        self.uploadedAt = nil
        self.customerVisible = customerVisible
        self.width = width
        self.height = height
        self.preservation = .init()
    }
}

enum NativeJobPhotoImport {
    /// `p<millis>_<base36>` — same grammar the backend and RN client enforce.
    /// `randomValue` is injectable so tests can force deterministic collisions.
    static func makePhotoID(now: Date = Date(), randomValue: UInt64? = nil) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let random = randomValue ?? UInt64.random(in: 0 ... UInt64.max)
        let suffix = String(random, radix: 36, uppercase: false)
        return "p\(millis)_\(suffix.isEmpty ? "0" : suffix)"
    }

    static func timestampString(from date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Fail-closed visibility read: only an explicit `true` is visible.
    static func isCustomerVisible(_ photo: Canonical.JobPhoto) -> Bool {
        photo.customerVisible == true
    }

    /// Normalizes arbitrary image bytes to the JPEG contract. Already-JPEG
    /// input is returned byte-identical (local bytes win); any other decodable
    /// format is re-encoded as single-frame JPEG. Returns nil when the input
    /// cannot be represented as JPEG on this platform.
    static func normalizedJPEGBytes(from data: Data) -> Data? {
        if isJPEGMarker(data) { return data }
        return convertFirstFrameToJPEG(data)
    }

    static func isJPEGMarker(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
            && data[data.index(before: data.endIndex)] == 0xD9
            && data[data.index(data.endIndex, offsetBy: -2)] == 0xFF
    }

    /// Validates + converts source bytes to the exact transfer contract
    /// (JPEG markers, `<= 6 MiB`). Conversion keeps the source untouched; the
    /// converted bytes are what gets stored and uploaded.
    static func validatedJPEGBytes(from sourceData: Data) throws -> Data {
        guard let normalized = normalizedJPEGBytes(from: sourceData) else {
            throw NativeJobPhotoImportError.invalidImage
        }
        do {
            try NativeJobPhotoTransferService.validateJPEG(normalized)
        } catch NativeJobPhotoTransferError.photoTooLarge {
            throw NativeJobPhotoImportError.photoTooLarge
        } catch {
            throw NativeJobPhotoImportError.invalidImage
        }
        return normalized
    }

    struct CapturedPhoto {
        let photo: Canonical.JobPhoto
        let bytes: Data
        let outcome: NativeJobPhotoStorage.InstallOutcome
    }

    /// Validates/converts `sourceData` to JPEG, mints a valid photo ID, writes
    /// `<root>/job-photos/<id>.jpg` atomically without ever overwriting an
    /// existing file, and returns the committed `Canonical.JobPhoto` record
    /// (fail-closed `customerVisible: false`). The caller durably commits the
    /// returned record (AppStore) or folds it into a snapshot (tests).
    ///
    /// - Parameters:
    ///   - existingIDs: IDs already present in the snapshot; a generated
    ///     collision retries with fresh randomness (bounded).
    static func capture(
        jobID: String,
        sourceData: Data,
        width: Int?,
        height: Int?,
        root: URL,
        now: Date = Date(),
        randomValue: UInt64? = nil,
        existingIDs: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> CapturedPhoto {
        let trimmed = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NativeJobPhotoImportError.emptyJobID }
        let bytes = try validatedJPEGBytes(from: sourceData)

        var photoID = makePhotoID(now: now, randomValue: randomValue)
        if existingIDs.contains(photoID) || fileManager.fileExists(atPath: (try? NativeJobPhotoStorage.photoURL(root: root, photoID: photoID).path) ?? "") {
            // A forced test collision (or an astronomically unlikely random
            // collision) must never reuse an ID or overwrite bytes. Retry with
            // fresh randomness; the injected value is only a first attempt.
            var attempts = 0
            repeat {
                attempts += 1
                photoID = makePhotoID(now: now)
                guard attempts < 8 else { throw NativeJobPhotoImportError.duplicatePhotoID }
            } while existingIDs.contains(photoID)
        }
        try NativeJobPhotoTransferService.validatePhotoID(photoID)

        let outcome = try writeBytesWithoutOverwrite(bytes, root: root, photoID: photoID, fileManager: fileManager)
        let photo = Canonical.JobPhoto(
            importedID: photoID,
            jobID: trimmed,
            createdAt: timestampString(from: now),
            customerVisible: false,
            width: width.map { Decimal($0) },
            height: height.map { Decimal($0) }
        )
        return CapturedPhoto(photo: photo, bytes: bytes, outcome: outcome)
    }

    /// Atomic deterministic write that never replaces an existing file. Mirrors
    /// `NativeJobPhotoStorage.installDownloadedBytes`: temp file + re-check +
    /// move, so a concurrent download/capture cannot clobber local bytes.
    @discardableResult
    static func writeBytesWithoutOverwrite(
        _ bytes: Data,
        root: URL,
        photoID: String,
        fileManager: FileManager = .default
    ) throws -> NativeJobPhotoStorage.InstallOutcome {
        do {
            try NativeJobPhotoTransferService.validateJPEG(bytes)
        } catch NativeJobPhotoTransferError.photoTooLarge {
            throw NativeJobPhotoImportError.photoTooLarge
        } catch {
            throw NativeJobPhotoImportError.invalidImage
        }
        let destination: URL
        do {
            destination = try NativeJobPhotoStorage.photoURL(root: root, photoID: photoID)
        } catch {
            throw NativeJobPhotoImportError.invalidImage
        }
        if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }
        do {
            let directory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".capture-\(UUID().uuidString).tmp")
            do {
                try bytes.write(to: temporary, options: [.atomic])
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: temporary)
                    return .alreadyPresent
                }
                try fileManager.moveItem(at: temporary, to: destination)
                return .installed
            } catch {
                try? fileManager.removeItem(at: temporary)
                if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }
                throw error
            }
        } catch let error as NativeJobPhotoImportError {
            throw error
        } catch {
            throw NativeJobPhotoImportError.writeFailed
        }
    }

    /// Best-effort removal of one photo's bytes. Only the exact deterministic
    /// file is touched; missing files and I/O failures are swallowed so a
    /// metadata commit is never rolled back by a filesystem miss.
    static func removeBytesIfPresent(
        root: URL,
        photoID: String,
        fileManager: FileManager = .default
    ) {
        guard let url = try? NativeJobPhotoStorage.photoURL(root: root, photoID: photoID) else { return }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func convertFirstFrameToJPEG(_ data: Data) -> Data? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let converted = output as Data
        return isJPEGMarker(converted) ? converted : nil
        #else
        return nil
        #endif
    }
}

/// Pure snapshot-level job-photo mutations. Each op re-resolves the canonical
/// record by ID, mutates only its owned fields, and returns the committed
/// snapshot with its `jobPhotos` queue draft — the same durable-commit-before-
/// publish + enqueue boundary `AppStore` uses for every other family.
enum NativeJobPhotoMutations {
    struct Effect {
        let snapshot: Canonical.Snapshot
        let draft: Canonical.MutationDraft
    }

    static func create(
        snapshot: Canonical.Snapshot,
        photo: Canonical.JobPhoto
    ) throws -> Effect {
        try NativeJobPhotoTransferService.validatePhotoID(photo.id)
        guard !(photo.jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw NativeJobPhotoImportError.emptyJobID
        }
        var updated = snapshot
        var records = updated.payload.jobPhotos ?? []
        guard !records.contains(where: { $0.id == photo.id }) else {
            throw NativeJobPhotoImportError.duplicatePhotoID
        }
        records.append(photo)
        updated.payload.jobPhotos = records
        let payload = try mutationPayload(photo)
        return Effect(
            snapshot: updated,
            draft: .init(table: "jobPhotos", op: .upsert, recordId: photo.id, payload: payload)
        )
    }

    static func setVisibility(
        snapshot: Canonical.Snapshot,
        photoID: String,
        visible: Bool
    ) throws -> Effect {
        try NativeJobPhotoTransferService.validatePhotoID(photoID)
        var updated = snapshot
        guard var records = updated.payload.jobPhotos,
              let index = records.firstIndex(where: { $0.id == photoID })
        else { throw NativeJobPhotoImportError.recordNotFound }
        records[index].customerVisible = visible
        updated.payload.jobPhotos = records
        let payload = try mutationPayload(records[index])
        return Effect(
            snapshot: updated,
            draft: .init(table: "jobPhotos", op: .upsert, recordId: photoID, payload: payload)
        )
    }

    static func delete(
        snapshot: Canonical.Snapshot,
        photoID: String
    ) throws -> Effect {
        try NativeJobPhotoTransferService.validatePhotoID(photoID)
        var updated = snapshot
        guard var records = updated.payload.jobPhotos,
              records.contains(where: { $0.id == photoID })
        else { throw NativeJobPhotoImportError.recordNotFound }
        records.removeAll(where: { $0.id == photoID })
        updated.payload.jobPhotos = records
        return Effect(
            snapshot: updated,
            draft: .init(table: "jobPhotos", op: .delete, recordId: photoID, payload: nil)
        )
    }

    private static func mutationPayload(_ record: Canonical.JobPhoto) throws -> Canonical.JSONValue {
        do {
            return try JSONDecoder().decode(
                Canonical.JSONValue.self,
                from: JSONEncoder().encode(record)
            )
        } catch {
            throw NativeJobPhotoImportError.invalidImage
        }
    }
}
