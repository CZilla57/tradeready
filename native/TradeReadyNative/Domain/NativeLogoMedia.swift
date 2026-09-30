import Foundation
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - Business logo media storage
//
// Mirrors RN's logo handling (`utils/logoPicker.ts`, `utils/photoStorage.ts`):
// the picked image is capped at 512px on its longest side and stored as PNG (logos
// are commonly transparent, and JPEG would flatten that onto a solid box on the PDF
// letterhead). Only the local file reference rides in the synced settings blob
// (`settings.logoPhoto`); the bytes stay on the device, exactly as in RN, so another
// device sees a dangling reference and treats it as "no logo".
//
// The deterministic `<media-root>/logos/logo_<32 hex>.png` shape is the one the
// legacy importer already accepts as a native logo reference.

enum NativeLogoMedia {
    enum InstallOutcome: Equatable { case installed, alreadyPresent }

    /// RN `logoResizeActions` cap: the longest side of a stored logo.
    static let maxDimension = 512

    /// 32 lowercase hex characters, the importer's `logo_<digest>` stem shape.
    static func makeLogoID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isValidLogoID(_ value: String) -> Bool {
        value.count == 32 && value.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil
    }

    static func logoURL(root: URL, logoID: String) throws -> URL {
        guard isValidLogoID(logoID) else { throw NativeLogoMediaError.invalidLogoID }
        return root
            .appendingPathComponent("logos", isDirectory: true)
            .appendingPathComponent("logo_\(logoID).png", isDirectory: false)
    }

    /// Writes the bytes to the deterministic path through a temp file. Existing
    /// bytes win: the file is never overwritten.
    @discardableResult
    static func installBytes(
        _ bytes: Data,
        root: URL,
        logoID: String,
        fileManager: FileManager = .default
    ) throws -> InstallOutcome {
        guard !bytes.isEmpty else { throw NativeLogoMediaError.unsupportedImage }
        let destination = try logoURL(root: root, logoID: logoID)
        if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }

        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".logo-\(UUID().uuidString).tmp")
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

    /// True only for `<root>/logos/logo_<32 hex>.png`. Deletion is gated on this so a
    /// migrated, foreign or hand-edited reference can never remove anything else.
    static func isOwnedLogoFile(_ url: URL, root: URL) -> Bool {
        guard url.isFileURL, !url.pathComponents.contains("..") else { return false }
        let logosDirectory = root.appendingPathComponent("logos", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent == logosDirectory else { return false }
        let name = url.lastPathComponent
        guard name.hasPrefix("logo_"), url.pathExtension == "png" else { return false }
        return isValidLogoID(String(name.dropFirst("logo_".count).dropLast(".png".count)))
    }

    /// Removes the referenced file if, and only if, it is an app-owned logo. A
    /// missing file, an empty or non-file reference, and a failed delete are all
    /// silent: the caller's settings write is what matters, and a stranded file is
    /// harmless.
    static func removeFile(reference: String?, root: URL, fileManager: FileManager = .default) {
        guard let reference, !reference.isEmpty,
              let url = URL(string: reference), isOwnedLogoFile(url, root: root)
        else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Whether the reference still points at a readable file. A reference that
    /// outlives its file (reinstall, another device's path) reads as "no logo".
    static func fileExists(reference: String?, fileManager: FileManager = .default) -> Bool {
        guard let reference, !reference.isEmpty,
              let url = URL(string: reference), url.isFileURL
        else { return false }
        return fileManager.isReadableFile(atPath: url.path)
    }

    /// The picked bytes capped at `maxDimension` on the longest side (never upscaled)
    /// and re-encoded as PNG with alpha kept. nil when the input is undecodable.
    static func normalizedPNGBytes(from data: Data, maxDimension: Int = NativeLogoMedia.maxDimension) -> Data? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
        #else
        return nil
        #endif
    }
}

enum NativeLogoMediaError: Error, Equatable {
    case invalidLogoID
    case unsupportedImage
}
