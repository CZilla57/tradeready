import Foundation

@main
struct JobPhotoMutationTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition {
                failures += 1
                print("FAIL: \(label)")
            }
        }

        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let otherJPEG = Data([0xFF, 0xD8, 0x99, 0xFF, 0xD9])
        let fixedDate = Date(timeIntervalSince1970: 1_722_960_000)

        func isolatedRoot() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-photo-mutation-\(UUID().uuidString)", isDirectory: true)
        }

        // 1. ID grammar matches the transfer/backend contract.
        for _ in 0..<50 {
            let id = NativeJobPhotoImport.makePhotoID(now: fixedDate)
            expect(NativeJobPhotoTransferService.isValidPhotoID(id), "generated ID is valid: \(id)")
        }
        expect(NativeJobPhotoImport.makePhotoID(now: fixedDate, randomValue: 12345).hasPrefix("p1722960000000_"), "ID embeds millis timestamp")

        // 2. Import validation.
        do {
            _ = try NativeJobPhotoImport.capture(
                jobID: "  ", sourceData: jpeg, width: 100, height: 100,
                root: isolatedRoot(), now: fixedDate
            )
            expect(false, "empty job ID must be rejected")
        } catch NativeJobPhotoImportError.emptyJobID {
            expect(true, "empty job ID is rejected")
        }
        do {
            _ = try NativeJobPhotoImport.capture(
                jobID: "j1", sourceData: Data("not-jpeg".utf8), width: nil, height: nil,
                root: isolatedRoot(), now: fixedDate
            )
            expect(false, "non-JPEG must be rejected")
        } catch NativeJobPhotoImportError.invalidImage {
            expect(true, "non-JPEG is rejected without writing")
        }
        do {
            let oversized = Data([0xFF, 0xD8]) + Data(repeating: 0x01, count: NativeJobPhotoTransferService.maximumPhotoBytes) + Data([0xFF, 0xD9])
            _ = try NativeJobPhotoImport.capture(
                jobID: "j1", sourceData: oversized, width: nil, height: nil,
                root: isolatedRoot(), now: fixedDate
            )
            expect(false, "oversize bytes must be rejected")
        } catch NativeJobPhotoImportError.photoTooLarge {
            expect(true, "oversize bytes are rejected")
        }

        // 3. Deterministic path + fail-closed record.
        let root = isolatedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try NativeJobPhotoImport.capture(
            jobID: "job-1", sourceData: jpeg, width: 1600, height: 1200,
            root: root, now: fixedDate, randomValue: 987_654_321
        )
        expect(NativeJobPhotoTransferService.isValidPhotoID(captured.photo.id), "captured ID is valid")
        let expectedURL = try NativeJobPhotoStorage.photoURL(root: root, photoID: captured.photo.id)
        expect(expectedURL.lastPathComponent == "\(captured.photo.id).jpg", "filename is the photo ID")
        expect(expectedURL.deletingLastPathComponent().lastPathComponent == "job-photos", "bytes live under job-photos/")
        expect(try Data(contentsOf: expectedURL) == jpeg, "stored bytes are exact")
        expect(captured.outcome == .installed, "first capture installs")
        expect(captured.photo.jobId == "job-1", "record carries the job ID")
        expect(captured.photo.uploadedAt == nil, "new capture is not marked uploaded")
        expect(captured.photo.customerVisible == false, "import stamps fail-closed customerVisible=false")
        expect(!NativeJobPhotoImport.isCustomerVisible(captured.photo), "fail-closed read hides the new photo")
        expect(captured.photo.width == Decimal(1600) && captured.photo.height == Decimal(1200), "dimensions are committed")

        // 4. Local bytes win: a download race never overwrites.
        let race = try NativeJobPhotoStorage.installDownloadedBytes(otherJPEG, root: root, photoID: captured.photo.id)
        expect(race == .alreadyPresent, "download race reports already present")
        expect(try Data(contentsOf: expectedURL) == jpeg, "existing capture bytes win the race")

        // Forced ID collision retries instead of overwriting.
        let forcedRoot = isolatedRoot()
        defer { try? FileManager.default.removeItem(at: forcedRoot) }
        let first = try NativeJobPhotoImport.capture(
            jobID: "job-1", sourceData: jpeg, width: nil, height: nil,
            root: forcedRoot, now: fixedDate, randomValue: 42,
            existingIDs: []
        )
        let second = try NativeJobPhotoImport.capture(
            jobID: "job-1", sourceData: otherJPEG, width: nil, height: nil,
            root: forcedRoot, now: fixedDate, randomValue: 42,
            existingIDs: [first.photo.id]
        )
        expect(first.photo.id != second.photo.id, "colliding ID retries with fresh randomness")
        expect(try Data(contentsOf: try NativeJobPhotoStorage.photoURL(root: forcedRoot, photoID: first.photo.id)) == jpeg, "first file untouched by collision retry")

        // 5. Snapshot mutations: create + enqueue correctness.
        var snapshot = Canonical.Snapshot(payload: .init())
        let created = try NativeJobPhotoMutations.create(snapshot: snapshot, photo: captured.photo)
        snapshot = created.snapshot
        expect(snapshot.payload.jobPhotos?.count == 1, "create commits the record")
        expect(created.draft.table == "jobPhotos" && created.draft.op == .upsert && created.draft.recordId == captured.photo.id, "create enqueues a jobPhotos upsert")
        if case let .object(fields) = created.draft.payload {
            expect(fields["id"] == .string(captured.photo.id), "upsert payload carries the photo ID")
            expect(fields["jobId"] == .string("job-1"), "upsert payload carries the job ID")
            expect(fields["customerVisible"] == .bool(false), "upsert payload is fail-closed")
        } else {
            expect(false, "upsert payload is a record object")
        }
        do {
            _ = try NativeJobPhotoMutations.create(snapshot: snapshot, photo: captured.photo)
            expect(false, "duplicate ID must be rejected")
        } catch NativeJobPhotoImportError.duplicatePhotoID {
            expect(true, "duplicate ID is rejected")
        }

        // 6. Visibility toggle mutates only the owned field.
        let toggled = try NativeJobPhotoMutations.setVisibility(snapshot: snapshot, photoID: captured.photo.id, visible: true)
        snapshot = toggled.snapshot
        let visiblePhoto = snapshot.payload.jobPhotos!.first(where: { $0.id == captured.photo.id })!
        expect(visiblePhoto.customerVisible == true, "toggle sets customerVisible=true")
        expect(visiblePhoto.jobId == "job-1" && visiblePhoto.createdAt == captured.photo.createdAt, "toggle preserves jobId/createdAt")
        expect(visiblePhoto.width == Decimal(1600) && visiblePhoto.uploadedAt == nil, "toggle preserves dimensions/upload state")
        expect(toggled.draft.table == "jobPhotos" && toggled.draft.op == .upsert, "toggle enqueues an upsert")
        expect(NativeJobPhotoImport.isCustomerVisible(visiblePhoto), "explicit true reads as visible")
        let hidden = try NativeJobPhotoMutations.setVisibility(snapshot: snapshot, photoID: captured.photo.id, visible: false)
        expect(hidden.snapshot.payload.jobPhotos!.first!.customerVisible == false, "toggle back hides")
        // Absent flag (legacy record) reads hidden.
        var legacyPhoto = captured.photo
        legacyPhoto.customerVisible = nil
        expect(!NativeJobPhotoImport.isCustomerVisible(legacyPhoto), "absent flag reads hidden (fail-closed)")
        do {
            _ = try NativeJobPhotoMutations.setVisibility(snapshot: snapshot, photoID: "p1722960000000_nope", visible: true)
            expect(false, "unknown ID toggle must fail")
        } catch NativeJobPhotoImportError.recordNotFound {
            expect(true, "unknown ID toggle reports not found")
        }

        // 7. Delete removes metadata, enqueues a delete, and clears bytes safely.
        let sibling = try NativeJobPhotoImport.capture(
            jobID: "job-1", sourceData: otherJPEG, width: nil, height: nil,
            root: root, now: fixedDate, randomValue: 555
        )
        let withSibling = try NativeJobPhotoMutations.create(snapshot: snapshot, photo: sibling.photo)
        snapshot = withSibling.snapshot
        expect(snapshot.payload.jobPhotos?.count == 2, "sibling present before delete")
        let deleted = try NativeJobPhotoMutations.delete(snapshot: snapshot, photoID: captured.photo.id)
        snapshot = deleted.snapshot
        expect(snapshot.payload.jobPhotos?.count == 1, "delete removes only the target record")
        expect(snapshot.payload.jobPhotos?.first?.id == sibling.photo.id, "sibling record survives")
        expect(deleted.draft.table == "jobPhotos" && deleted.draft.op == .delete && deleted.draft.recordId == captured.photo.id, "delete enqueues a jobPhotos delete")
        expect(deleted.draft.payload == nil, "delete carries no payload")
        NativeJobPhotoImport.removeBytesIfPresent(root: root, photoID: captured.photo.id)
        expect(!FileManager.default.fileExists(atPath: expectedURL.path), "delete removes the deterministic bytes")
        let siblingURL = try NativeJobPhotoStorage.photoURL(root: root, photoID: sibling.photo.id)
        expect(FileManager.default.fileExists(atPath: siblingURL.path), "delete never touches sibling bytes")
        NativeJobPhotoImport.removeBytesIfPresent(root: root, photoID: captured.photo.id) // idempotent
        expect(true, "repeat byte removal is safe")
        do {
            _ = try NativeJobPhotoMutations.delete(snapshot: snapshot, photoID: captured.photo.id)
            expect(false, "double delete must fail")
        } catch NativeJobPhotoImportError.recordNotFound {
            expect(true, "double delete reports not found")
        }

        if failures > 0 {
            print("\(failures) job photo mutation test(s) failed")
            Foundation.exit(1)
        }
        print("Job photo mutation tests passed")
    }
}
