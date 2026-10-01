import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// Business logo media tests. Mirrors RN `utils/logoPicker.ts` + `utils/photoStorage.ts`
// (512px cap, PNG so transparency survives, local file only — the path rides in the
// synced settings blob and the bytes never leave the device) and the native receipt
// media contract (atomic install, deterministic `logos/logo_<32 hex>.png` path that the
// legacy importer already accepts).

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

/// Encodes a solid RGBA image whose bottom-left quarter is fully transparent.
private func sampleImage(width: Int, height: Int, type: UTType) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.clear(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

// MARK: IDs and paths

let id = NativeLogoMedia.makeLogoID()
expect(NativeLogoMedia.isValidLogoID(id), "generated id is valid")
expectEqual(id.count, 32, "id is 32 characters")
expect(id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil, "id is lowercase hex")
expect(NativeLogoMedia.makeLogoID() != id, "ids are unique")
for bad in ["", "abc", String(repeating: "g", count: 32), String(repeating: "A", count: 32),
            "../" + String(repeating: "a", count: 29), String(repeating: "a", count: 33)] {
    expect(!NativeLogoMedia.isValidLogoID(bad), "rejects id \(bad)")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("logo-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

let url = try! NativeLogoMedia.logoURL(root: root, logoID: id)
expectEqual(url.lastPathComponent, "logo_\(id).png", "file name")
expectEqual(url.deletingLastPathComponent().lastPathComponent, "logos", "lives in logos/")
var threw = false
do { _ = try NativeLogoMedia.logoURL(root: root, logoID: "../etc") } catch { threw = true }
expect(threw, "invalid id throws")

// MARK: Normalisation (512 px cap, PNG, alpha kept, never upscaled)

let big = NativeLogoMedia.normalizedPNGBytes(from: sampleImage(width: 2048, height: 1024, type: .jpeg))
expect(big != nil, "large jpeg normalises")
if let big {
    expect(Array(big.prefix(8)) == pngSignature, "output is PNG")
    let image = decode(big)
    expectEqual(image?.width, 512, "long side capped at 512")
    expectEqual(image?.height, 256, "aspect preserved")
}

let tall = NativeLogoMedia.normalizedPNGBytes(from: sampleImage(width: 600, height: 1200, type: .png))
expectEqual(tall.flatMap(decode)?.height, 512, "tall image capped on height")
expectEqual(tall.flatMap(decode)?.width, 256, "tall image aspect preserved")

let small = NativeLogoMedia.normalizedPNGBytes(from: sampleImage(width: 100, height: 50, type: .png))
expectEqual(small.flatMap(decode)?.width, 100, "small image not upscaled (w)")
expectEqual(small.flatMap(decode)?.height, 50, "small image not upscaled (h)")

if let transparent = NativeLogoMedia.normalizedPNGBytes(from: sampleImage(width: 800, height: 800, type: .png)),
   let image = decode(transparent) {
    let info = image.alphaInfo
    expect(info != .none && info != .noneSkipLast && info != .noneSkipFirst, "alpha channel kept")
} else {
    failures += 1; print("FAIL: transparent png normalises")
}

expect(NativeLogoMedia.normalizedPNGBytes(from: Data()) == nil, "empty data rejected")
expect(NativeLogoMedia.normalizedPNGBytes(from: Data("not an image".utf8)) == nil, "garbage rejected")

// MARK: Install (atomic, local bytes win)

let bytes = Data([1, 2, 3, 4])
expectEqual(try? NativeLogoMedia.installBytes(bytes, root: root, logoID: id), .installed, "first install")
expectEqual(try? Data(contentsOf: url), bytes, "bytes written")
expectEqual(try? NativeLogoMedia.installBytes(Data([9, 9]), root: root, logoID: id), .alreadyPresent, "second install keeps first")
expectEqual(try? Data(contentsOf: url), bytes, "existing bytes never overwritten")
let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
expect(leftovers.allSatisfy { !$0.hasSuffix(".tmp") }, "no temp files left behind")
threw = false
do { _ = try NativeLogoMedia.installBytes(Data(), root: root, logoID: NativeLogoMedia.makeLogoID()) } catch { threw = true }
expect(threw, "empty bytes refused")

// MARK: Ownership-guarded removal

expect(NativeLogoMedia.isOwnedLogoFile(url, root: root), "own logo file is owned")
expect(!NativeLogoMedia.isOwnedLogoFile(root.appendingPathComponent("receipts/r1_a.jpg"), root: root), "receipt is not a logo")
expect(!NativeLogoMedia.isOwnedLogoFile(URL(fileURLWithPath: "/etc/hosts"), root: root), "outside file is not owned")
expect(!NativeLogoMedia.isOwnedLogoFile(root.appendingPathComponent("logos/../receipts/logo_\(id).png"), root: root), "traversal is not owned")
expect(!NativeLogoMedia.isOwnedLogoFile(root.appendingPathComponent("logos/notes.txt"), root: root), "wrong name is not owned")

let foreign = root.appendingPathComponent("receipts/r1_a.jpg")
try? FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
try? Data([7]).write(to: foreign)
NativeLogoMedia.removeFile(reference: foreign.absoluteString, root: root)
expect(FileManager.default.fileExists(atPath: foreign.path), "removal never touches a non-logo file")
NativeLogoMedia.removeFile(reference: "", root: root)
NativeLogoMedia.removeFile(reference: "not a url", root: root)
NativeLogoMedia.removeFile(reference: url.absoluteString, root: root)
expect(!FileManager.default.fileExists(atPath: url.path), "owned logo removed")
NativeLogoMedia.removeFile(reference: url.absoluteString, root: root) // already gone: no crash

// MARK: Reference resolution (dangling reference reads as "no logo")

expect(NativeLogoMedia.fileExists(reference: nil) == false, "nil reference")
expect(NativeLogoMedia.fileExists(reference: "") == false, "empty reference")
expect(NativeLogoMedia.fileExists(reference: url.absoluteString) == false, "dangling reference")
_ = try? NativeLogoMedia.installBytes(bytes, root: root, logoID: id)
expect(NativeLogoMedia.fileExists(reference: url.absoluteString), "existing reference")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("Logo media tests passed.")
