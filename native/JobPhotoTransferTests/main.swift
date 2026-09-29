import Foundation

private final class RecordingLoader: NativeJobPhotoHTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, Int, [String: String])] = []
    private var recordedRequests: [URLRequest] = []

    func enqueue(_ data: Data, status: Int, headers: [String: String] = [:]) {
        lock.withLock { responses.append((data, status, headers)) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let next = lock.withLock {
            recordedRequests.append(request)
            return responses.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.1,
            httpVersion: nil,
            headerFields: next.2
        )!
        return (next.0, response)
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }
}

@main
struct JobPhotoTransferTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() {
                failures += 1
                print("FAIL: \(label)")
            }
        }

        let goodID = "p1722960000000_abc123"
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let session = Data(#"{"access_token":"owner-jwt","refresh_token":"unused"}"#.utf8)
        let endpoint = URL(string: "https://staging.example/api/photos")!

        expect(NativeJobPhotoTransferService.isValidPhotoID(goodID), "valid RN photo ID is accepted")
        expect(NativeJobPhotoTransferService.isValidPhotoID("p0_abcdef"), "stable migration photo ID is accepted")
        expect(!NativeJobPhotoTransferService.isValidPhotoID("../owner/photo"), "path traversal is rejected")
        expect(!NativeJobPhotoTransferService.isValidPhotoID("p1_UPPER"), "uppercase suffix is rejected")
        expect(!NativeJobPhotoTransferService.isValidPhotoID("p_abc"), "missing timestamp is rejected")

        let uploadLoader = RecordingLoader()
        uploadLoader.enqueue(Data("ok".utf8), status: 200)
        let fixedDate = Date(timeIntervalSince1970: 1_722_960_000)
        let uploadService = NativeJobPhotoTransferService(
            endpointBaseURL: endpoint,
            loader: uploadLoader,
            now: { fixedDate }
        )
        let uploadedAt = try await uploadService.upload(
            photoID: goodID,
            bytes: jpeg,
            sessionBytes: session
        )
        let uploadRequest = uploadLoader.requests.first
        expect(uploadRequest?.httpMethod == "PUT", "upload uses PUT")
        expect(uploadRequest?.url?.absoluteString == "https://staging.example/api/photos/\(goodID)", "upload uses deterministic photo endpoint")
        expect(uploadRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer owner-jwt", "upload uses the current Supabase access token")
        expect(uploadRequest?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg", "upload declares JPEG bytes")
        expect(uploadRequest?.httpBody == jpeg, "upload sends exact local bytes")
        expect(uploadedAt == "2024-08-06T16:00:00.000Z", "upload timestamp is recorded only after success")

        let invalidLoader = RecordingLoader()
        let invalidService = NativeJobPhotoTransferService(endpointBaseURL: endpoint, loader: invalidLoader)
        do {
            _ = try await invalidService.upload(
                photoID: goodID,
                bytes: Data("not-jpeg".utf8),
                sessionBytes: session
            )
            expect(false, "invalid local bytes must not upload")
        } catch NativeJobPhotoTransferError.invalidJPEG {
            expect(invalidLoader.requests.isEmpty, "invalid local bytes fail before network access")
        }

        let rejectedLoader = RecordingLoader()
        rejectedLoader.enqueue(Data(), status: 401)
        let rejectedService = NativeJobPhotoTransferService(endpointBaseURL: endpoint, loader: rejectedLoader)
        do {
            _ = try await rejectedService.upload(photoID: goodID, bytes: jpeg, sessionBytes: session)
            expect(false, "401 upload must fail")
        } catch NativeJobPhotoTransferError.rejectedSession {
            expect(true, "401 is classified as a rejected session")
        }

        let downloadLoader = RecordingLoader()
        downloadLoader.enqueue(jpeg, status: 200, headers: ["Content-Type": "image/jpeg"])
        let downloadService = NativeJobPhotoTransferService(endpointBaseURL: endpoint, loader: downloadLoader)
        let downloaded = try await downloadService.download(photoID: goodID, sessionBytes: session)
        expect(downloaded == jpeg, "download returns validated JPEG bytes")
        expect(downloadLoader.requests.first?.httpMethod == "GET", "backfill uses GET")
        expect(downloadLoader.requests.first?.httpBody == nil, "backfill sends no body")

        let errorBodyLoader = RecordingLoader()
        errorBodyLoader.enqueue(Data(#"{"error":"Not found"}"#.utf8), status: 404, headers: ["Content-Type": "application/json"])
        let errorBodyService = NativeJobPhotoTransferService(endpointBaseURL: endpoint, loader: errorBodyLoader)
        do {
            _ = try await errorBodyService.download(photoID: goodID, sessionBytes: session)
            expect(false, "error body must not be accepted as a photo")
        } catch NativeJobPhotoTransferError.unavailable {
            expect(true, "non-success download remains retryable")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-photo-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try NativeJobPhotoStorage.installDownloadedBytes(jpeg, root: root, photoID: goodID)
        expect(installed == .installed, "download installs into an empty deterministic path")
        let destination = try NativeJobPhotoStorage.photoURL(root: root, photoID: goodID)
        let installedBytes = try Data(contentsOf: destination)
        expect(installedBytes == jpeg, "installed bytes are exact")

        let differentJPEG = Data([0xFF, 0xD8, 0x99, 0xFF, 0xD9])
        let repeated = try NativeJobPhotoStorage.installDownloadedBytes(differentJPEG, root: root, photoID: goodID)
        expect(repeated == .alreadyPresent, "resumed backfill never overwrites an existing local file")
        let preservedBytes = try Data(contentsOf: destination)
        let resumableUploadBytes = try NativeJobPhotoStorage.uploadBytes(root: root, photoID: goodID)
        expect(preservedBytes == jpeg, "existing source bytes win a download race")
        expect(resumableUploadBytes == jpeg, "a later upload reads the deterministic installed file")

        if failures > 0 {
            print("\(failures) job photo transfer test(s) failed")
            Foundation.exit(1)
        }
        print("Job photo transfer tests passed")
    }
}
