import Foundation
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - Receipt media storage (task 9.10, requirement E2)
//
// Receipt photos follow the job-photo contract rather than inventing a second
// one: a deterministic `<media-root>/receipts/<id>.jpg`, atomic install, and
// local bytes always win (an existing file is never overwritten, so a repeated
// attach or a legacy adoption pass cannot silently replace the user's photo).
//
// The canonical record only ever carries the local reference string; bytes stay
// on the device, exactly like RN's `expo-file-system` receipt paths.

enum NativeReceiptMedia {
    enum InstallOutcome: Equatable { case installed, alreadyPresent }

    /// Receipt ids are `r<millis>_<base36>` — the same shape RN's
    /// `persistPhoto` filename uses, and the shape the legacy importer already
    /// accepts as a native reference beneath `receipts/`.
    static func makeReceiptID(now: Date = Date(), randomValue: UInt64? = nil) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let random = randomValue ?? UInt64.random(in: 0 ... UInt64.max)
        let suffix = String(random, radix: 36, uppercase: false)
        return "r\(millis)_\(suffix.isEmpty ? "0" : suffix)"
    }

    /// A receipt id is safe to interpolate into a path when it is non-empty,
    /// bounded, and free of separators or traversal.
    static func isValidReceiptID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("/"), !value.contains("\\"), !value.contains("..")
        else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func receiptURL(root: URL, receiptID: String) throws -> URL {
        guard isValidReceiptID(receiptID) else { throw NativeReceiptMediaError.invalidReceiptID }
        return root
            .appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent("\(receiptID).jpg", isDirectory: false)
    }

    /// Writes normalized JPEG bytes to the deterministic path. Existing bytes
    /// win: the file is never overwritten, and a losing race reports
    /// `.alreadyPresent` instead of clobbering.
    @discardableResult
    static func installBytes(
        _ bytes: Data,
        root: URL,
        receiptID: String,
        fileManager: FileManager = .default
    ) throws -> InstallOutcome {
        guard !bytes.isEmpty else { throw NativeReceiptMediaError.unsupportedImage }
        let destination = try receiptURL(root: root, receiptID: receiptID)
        if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }

        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".receipt-\(UUID().uuidString).tmp")
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

    // MARK: OCR contract

    /// Longest side the receipt is downscaled to before it is handed to the
    /// vision call. RN leans on the picker's `quality: 0.7` + 4:3 crop; native
    /// bounds the encoded size explicitly so the `MAX_RECEIPT_BASE64_CHARS` cap
    /// is a property of the stored bytes, not of whatever the camera produced.
    static let maxDimension = 2048
    static let compressionQuality = 0.7
    /// Below this the thumbnail is too small to read a receipt, so giving up is
    /// more honest than shipping an unreadable image.
    static let minimumDimension = 320

    /// Base64 length for `byteCount` bytes (4 chars per 3-byte group, padded).
    static func base64Length(_ byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return 4 * ((byteCount + 2) / 3)
    }

    static func fitsOCRContract(_ jpeg: Data, maxBase64Chars: Int = NativeReceiptOCR.maxReceiptBase64Chars) -> Bool {
        base64Length(jpeg.count) <= maxBase64Chars
    }

    /// Normalizes arbitrary picked/captured bytes to a JPEG that fits the OCR
    /// contract. Returns nil when the input is undecodable or cannot be brought
    /// under the cap — the caller then keeps manual entry and says so.
    static func normalizedJPEGBytes(
        from data: Data,
        maxBase64Chars: Int = NativeReceiptOCR.maxReceiptBase64Chars
    ) -> Data? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var dimension = maxDimension
        while dimension >= minimumDimension {
            if let jpeg = thumbnailJPEG(source: source, maxDimension: dimension),
               fitsOCRContract(jpeg, maxBase64Chars: maxBase64Chars),
               isJPEGMarker(jpeg) {
                return jpeg
            }
            dimension /= 2
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Same SOI/EOI marker test the job-photo pipeline uses; kept local so the
    /// receipt contract does not depend on the photo-transfer stack.
    static func isJPEGMarker(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
            && data[data.endIndex - 2] == 0xFF
            && data[data.endIndex - 1] == 0xD9
    }

    #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    private static func thumbnailJPEG(source: CGImageSource, maxDimension: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
    #endif
}

enum NativeReceiptMediaError: Error, Equatable {
    case invalidReceiptID
    case unsupportedImage
}
