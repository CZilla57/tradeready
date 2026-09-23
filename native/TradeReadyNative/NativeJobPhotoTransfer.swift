import Foundation

enum NativeJobPhotoTransferError: Error, Equatable {
    case invalidConfiguration
    case malformedSession
    case invalidPhotoID
    case invalidJPEG
    case photoTooLarge
    case rejectedSession
    case unavailable
}

protocol NativeJobPhotoHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeJobPhotoHTTPDataLoading {}

protocol NativeJobPhotoTransferring: Sendable {
    func upload(photoID: String, bytes: Data, sessionBytes: Data) async throws -> String
    func download(photoID: String, sessionBytes: Data) async throws -> Data
}

struct NativeJobPhotoTransferOutcome: Equatable, Sendable {
    var uploadedCount = 0
    var downloadedCount = 0
    var failedCount = 0
    var didRun = false
}

/// Authenticated byte transport for the existing Cloudflare Worker photo API.
/// The app never chooses an owner path: the Worker verifies the Supabase JWT
/// and derives the R2 key from that verified subject plus this validated ID.
struct NativeJobPhotoTransferService: NativeJobPhotoTransferring {
    static let maximumPhotoBytes = 6 * 1024 * 1024

    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private let endpointBaseURL: URL
    private let loader: any NativeJobPhotoHTTPDataLoading
    private let now: @Sendable () -> Date

    init(
        endpointBaseURL: URL,
        loader: any NativeJobPhotoHTTPDataLoading = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpointBaseURL = endpointBaseURL
        self.loader = loader
        self.now = now
    }

    func upload(photoID: String, bytes: Data, sessionBytes: Data) async throws -> String {
        try Self.validatePhotoID(photoID)
        try Self.validateJPEG(bytes)
        let token = try accessToken(from: sessionBytes)
        var request = URLRequest(url: endpointBaseURL.appendingPathComponent(photoID))
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await load(request)
        try Self.validateSuccess(response)
        return Self.timestamp.string(from: now())
    }

    func download(photoID: String, sessionBytes: Data) async throws -> Data {
        try Self.validatePhotoID(photoID)
        let token = try accessToken(from: sessionBytes)
        var request = URLRequest(url: endpointBaseURL.appendingPathComponent(photoID))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await load(request)
        try Self.validateSuccess(response)
        if let http = response as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !contentType.hasPrefix("image/jpeg") {
            throw NativeJobPhotoTransferError.invalidJPEG
        }
        try Self.validateJPEG(bytes)
        return bytes
    }

    static func isValidPhotoID(_ value: String) -> Bool {
        guard value.count >= 4, value.count <= 55, value.first == "p" else { return false }
        let remainder = value.dropFirst()
        guard let underscore = remainder.firstIndex(of: "_") else { return false }
        let timestamp = remainder[..<underscore]
        let suffix = remainder[remainder.index(after: underscore)...]
        guard (1...20).contains(timestamp.count), (1...32).contains(suffix.count),
              timestamp.allSatisfy(\.isNumber)
        else { return false }
        return suffix.allSatisfy { character in
            character.isNumber || ("a"..."z").contains(character)
        }
    }

    static func validatePhotoID(_ value: String) throws {
        guard isValidPhotoID(value) else { throw NativeJobPhotoTransferError.invalidPhotoID }
    }

    static func validateJPEG(_ bytes: Data) throws {
        guard bytes.count <= maximumPhotoBytes else {
            throw NativeJobPhotoTransferError.photoTooLarge
        }
        guard bytes.count >= 4,
              bytes[bytes.startIndex] == 0xFF,
              bytes[bytes.index(after: bytes.startIndex)] == 0xD8,
              bytes[bytes.index(before: bytes.endIndex)] == 0xD9,
              bytes[bytes.index(bytes.endIndex, offsetBy: -2)] == 0xFF
        else { throw NativeJobPhotoTransferError.invalidJPEG }
    }

    private func accessToken(from bytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: bytes),
              !session.accessToken.isEmpty
        else { throw NativeJobPhotoTransferError.malformedSession }
        return session.accessToken
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw NativeJobPhotoTransferError.unavailable }
    }

    private static func validateSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NativeJobPhotoTransferError.unavailable
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw NativeJobPhotoTransferError.rejectedSession
        default: throw NativeJobPhotoTransferError.unavailable
        }
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Deterministic local storage contract shared by legacy adoption and cloud
/// transfer. Existing local bytes always win; a download can only fill a gap.
enum NativeJobPhotoStorage {
    enum InstallOutcome: Equatable { case installed, alreadyPresent }

    static func photoURL(root: URL, photoID: String) throws -> URL {
        try NativeJobPhotoTransferService.validatePhotoID(photoID)
        return root
            .appendingPathComponent("job-photos", isDirectory: true)
            .appendingPathComponent("\(photoID).jpg", isDirectory: false)
    }

    static func uploadBytes(
        root: URL,
        photoID: String,
        fileManager: FileManager = .default
    ) throws -> Data? {
        let url = try photoURL(root: root, photoID: photoID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NativeJobPhotoTransferError.invalidJPEG
        }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        try NativeJobPhotoTransferService.validateJPEG(bytes)
        return bytes
    }

    static func installDownloadedBytes(
        _ bytes: Data,
        root: URL,
        photoID: String,
        fileManager: FileManager = .default
    ) throws -> InstallOutcome {
        try NativeJobPhotoTransferService.validateJPEG(bytes)
        let destination = try photoURL(root: root, photoID: photoID)
        if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }

        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".download-\(UUID().uuidString).tmp")
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
            throw error
        }
    }
}
