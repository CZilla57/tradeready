import Foundation

// Deterministic ZIP writer tests (task 9.06).
//
// Ports __tests__/zipStore.test.ts: CRC/UTF-8/base64 vectors, EOCD structure,
// determinism, and a stored-ZIP round-trip reader that parses the real archive
// structure (EOCD -> central directory -> local headers) so a writer regression
// in offsets/sizes/CRCs fails here.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func testPrimitives() {
    expectEqual(NativeZipArchive.crc32([]), 0, "crc32 of empty input")
    expectEqual(NativeZipArchive.crc32(NativeZipArchive.utf8Encode("123456789")), 0xCBF4_3926, "CRC-32/ISO-HDLC of 123456789")
    expectEqual(NativeZipArchive.utf8Encode("AB"), [0x41, 0x42], "ASCII")
    expectEqual(NativeZipArchive.utf8Encode("é"), [0xC3, 0xA9], "two-byte")
    expectEqual(NativeZipArchive.utf8Encode("😀"), [0xF0, 0x9F, 0x98, 0x80], "astral surrogate pair")
    expectEqual(NativeZipArchive.base64Encode([0x4D, 0x61, 0x6E]), "TWFu", "base64 len%3==0")
    expectEqual(NativeZipArchive.base64Encode([0x4D]), "TQ==", "base64 one pad")
    expectEqual(NativeZipArchive.base64Encode([0x4D, 0x61]), "TWE=", "base64 two chars one pad")
}

// MARK: - stored-ZIP reader

private struct DecodedEntry: Equatable {
    var name: String
    var storedCrc: UInt32
    var storedSize: Int
    var data: [UInt8]
}

private func readU16(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
}

private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
}

private func decodeStoredZip(_ zip: [UInt8]) -> [DecodedEntry] {
    var eocd = -1
    var i = zip.count - 22
    while i >= 0 {
        if readU32(zip, i) == 0x0605_4B50 { eocd = i; break }
        i -= 1
    }
    guard eocd >= 0 else { return [] }
    let count = readU16(zip, eocd + 10)
    let centralSize = Int(readU32(zip, eocd + 12))
    let centralOffset = Int(readU32(zip, eocd + 16))
    guard centralOffset + centralSize == eocd else { return [] }

    var entries: [DecodedEntry] = []
    var cursor = centralOffset
    for _ in 0..<count {
        guard readU32(zip, cursor) == 0x0201_4B50 else { return [] }
        let compressedSize = Int(readU32(zip, cursor + 20))
        let uncompressedSize = Int(readU32(zip, cursor + 24))
        let nameLen = readU16(zip, cursor + 28)
        let extraLen = readU16(zip, cursor + 30)
        let commentLen = readU16(zip, cursor + 32)
        let localOffset = Int(readU32(zip, cursor + 42))
        guard compressedSize == uncompressedSize else { return [] }
        guard readU32(zip, localOffset) == 0x0403_4B50 else { return [] }
        let localCrc = readU32(zip, localOffset + 14)
        let localNameLen = readU16(zip, localOffset + 26)
        let localExtraLen = readU16(zip, localOffset + 28)
        guard localNameLen == nameLen else { return [] }
        let nameStart = localOffset + 30
        let nameBytes = Array(zip[nameStart..<(nameStart + nameLen)])
        let dataStart = nameStart + nameLen + localExtraLen
        let data = Array(zip[dataStart..<(dataStart + compressedSize)])
        entries.append(DecodedEntry(
            name: String(decoding: nameBytes, as: UTF8.self),
            storedCrc: localCrc,
            storedSize: compressedSize,
            data: data
        ))
        cursor += 46 + nameLen + extraLen + commentLen
    }
    return entries
}

private func testBuildZip() {
    let entries = [
        NativeZipEntry(name: "a.txt", bytes: NativeZipArchive.utf8Encode("hello")),
        NativeZipEntry(name: "b.txt", bytes: NativeZipArchive.utf8Encode("world")),
    ]
    let zip = NativeZipArchive.buildZip(entries)
    expectEqual(Array(zip[0..<4]), [0x50, 0x4B, 0x03, 0x04], "local header signature first")
    expectEqual(NativeZipArchive.buildZip(entries), zip, "deterministic across runs")

    let empty = NativeZipArchive.buildZip([])
    expectEqual(Array(empty[0..<4]), [0x50, 0x4B, 0x05, 0x06], "empty archive is a bare EOCD")
    expectEqual(empty.count, 22, "bare EOCD is 22 bytes")

    let input = [
        NativeZipEntry(name: "notes.txt", bytes: NativeZipArchive.utf8Encode("hello world, this is ASCII")),
        NativeZipEntry(name: "José 😀.txt", bytes: NativeZipArchive.utf8Encode("José 😀 — multibyte name and body")),
        NativeZipEntry(name: "empty.txt", bytes: []),
        NativeZipEntry(name: "data.bin", bytes: [0, 1, 2, 255, 254]),
    ]
    let decoded = decodeStoredZip(NativeZipArchive.buildZip(input))
    expectEqual(decoded.count, 4, "decoded entry count")
    for (index, entry) in input.enumerated() {
        expectEqual(decoded[index].name, entry.name, "entry \(index) name round-trips")
        expectEqual(decoded[index].data, entry.bytes, "entry \(index) bytes round-trip")
        expectEqual(decoded[index].storedCrc, NativeZipArchive.crc32(entry.bytes), "entry \(index) stored CRC")
        expectEqual(decoded[index].storedSize, entry.bytes.count, "entry \(index) stored size")
    }

    // Flag bit 11 (UTF-8 names) is set on every header.
    let flagged = NativeZipArchive.buildZip([NativeZipEntry(name: "x.txt", bytes: [1])])
    expectEqual(readU16(flagged, 6), 0x0800, "local header sets the UTF-8 flag")
    expectEqual(readU16(flagged, 8), 0, "method is stored (0)")
    expectEqual(readU16(flagged, 10), 0, "mod time zeroed")
    expectEqual(readU16(flagged, 12), 0, "mod date zeroed")
}

testPrimitives()
testBuildZip()

if failures == 0 {
    print("ZipArchiveTests: all checks passed")
} else {
    print("ZipArchiveTests: \(failures) failure(s)")
    exit(1)
}
