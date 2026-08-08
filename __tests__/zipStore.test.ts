import { crc32, utf8Encode, base64Encode, buildZip, ZipEntry } from "../utils/zipStore";

describe("crc32", () => {
  test("known vector for empty input", () => {
    expect(crc32(new Uint8Array([]))).toBe(0);
  });
  test('known vector for "123456789"', () => {
    // CRC-32/ISO-HDLC of the ASCII string "123456789" = 0xCBF43926
    expect(crc32(utf8Encode("123456789"))).toBe(0xcbf43926);
  });
});

describe("utf8Encode", () => {
  test("ASCII", () => {
    expect(Array.from(utf8Encode("AB"))).toEqual([0x41, 0x42]);
  });
  test("2-byte (é)", () => {
    expect(Array.from(utf8Encode("é"))).toEqual([0xc3, 0xa9]);
  });
  test("astral / surrogate pair (😀 U+1F600)", () => {
    expect(Array.from(utf8Encode("😀"))).toEqual([0xf0, 0x9f, 0x98, 0x80]);
  });
});

describe("base64Encode", () => {
  test("len % 3 == 0", () => {
    expect(base64Encode(Uint8Array.from([0x4d, 0x61, 0x6e]))).toBe("TWFu");
  });
  test("len % 3 == 1 (one pad)", () => {
    expect(base64Encode(Uint8Array.from([0x4d]))).toBe("TQ==");
  });
  test("len % 3 == 2 (two chars, one pad)", () => {
    expect(base64Encode(Uint8Array.from([0x4d, 0x61]))).toBe("TWE=");
  });
});

describe("buildZip", () => {
  test("emits a valid EOCD with the entry count and is deterministic", () => {
    const entries = [
      { name: "a.txt", bytes: utf8Encode("hello") },
      { name: "b.txt", bytes: utf8Encode("world") },
    ];
    const zip = buildZip(entries);
    // Local file header signature at offset 0.
    expect(Array.from(zip.slice(0, 4))).toEqual([0x50, 0x4b, 0x03, 0x04]);
    // End-of-central-directory signature present.
    const eocdSig = [0x50, 0x4b, 0x05, 0x06];
    let found = -1;
    for (let i = zip.length - 22; i >= 0; i--) {
      if (zip[i] === eocdSig[0] && zip[i + 1] === eocdSig[1] && zip[i + 2] === eocdSig[2] && zip[i + 3] === eocdSig[3]) { found = i; break; }
    }
    expect(found).toBeGreaterThanOrEqual(0);
    // total-entries field (LE u16) at EOCD+10 == 2.
    expect(zip[found + 10] | (zip[found + 11] << 8)).toBe(2);
    // Determinism: a second identical build is byte-for-byte equal.
    expect(Array.from(buildZip(entries))).toEqual(Array.from(zip));
  });

  test("empty archive is a bare EOCD", () => {
    const zip = buildZip([]);
    expect(Array.from(zip.slice(0, 4))).toEqual([0x50, 0x4b, 0x05, 0x06]);
    expect(zip.length).toBe(22);
  });
});

describe("buildZip round-trip", () => {
  // Minimal self-contained stored-ZIP reader. Parses the real archive
  // structure (EOCD -> central directory -> local headers) rather than
  // assuming fixed offsets, so it catches offset/size/CRC regressions in
  // the writer instead of just re-deriving them.

  const readU16 = (bytes: Uint8Array, off: number): number => bytes[off] | (bytes[off + 1] << 8);
  const readU32 = (bytes: Uint8Array, off: number): number =>
    (bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | (bytes[off + 3] << 24)) >>> 0;

  const EOCD_SIG = 0x06054b50;
  const CENTRAL_SIG = 0x02014b50;
  const LOCAL_SIG = 0x04034b50;

  type DecodedEntry = { nameBytes: Uint8Array; storedCrc: number; dataBytes: Uint8Array };
  type Decoded = { entries: DecodedEntry[]; eocdCount: number; centralDirOffset: number };

  function findEocd(zip: Uint8Array): number {
    // No archive comment in these fixtures, but scan from the end for
    // robustness rather than assuming EOCD is the last 22 bytes.
    for (let i = zip.length - 22; i >= 0; i--) {
      if (readU32(zip, i) === EOCD_SIG) return i;
    }
    throw new Error("EOCD signature not found");
  }

  function decodeStoredZip(zip: Uint8Array): Decoded {
    const eocdOff = findEocd(zip);
    const eocdCount = readU16(zip, eocdOff + 10);
    const centralDirSize = readU32(zip, eocdOff + 12);
    const centralDirOffset = readU32(zip, eocdOff + 16);
    expect(centralDirOffset + centralDirSize).toBe(eocdOff);

    const entries: DecodedEntry[] = [];
    let cdPos = centralDirOffset;
    for (let i = 0; i < eocdCount; i++) {
      expect(readU32(zip, cdPos)).toBe(CENTRAL_SIG);
      const compressedSize = readU32(zip, cdPos + 20);
      const uncompressedSize = readU32(zip, cdPos + 24);
      const nameLen = readU16(zip, cdPos + 28);
      const extraLen = readU16(zip, cdPos + 30);
      const commentLen = readU16(zip, cdPos + 32);
      const localHeaderOffset = readU32(zip, cdPos + 42);

      // Stored (method 0): compressed size must equal uncompressed size.
      expect(compressedSize).toBe(uncompressedSize);

      expect(readU32(zip, localHeaderOffset)).toBe(LOCAL_SIG);
      const localCrc = readU32(zip, localHeaderOffset + 14);
      const localCompressedSize = readU32(zip, localHeaderOffset + 18);
      const localUncompressedSize = readU32(zip, localHeaderOffset + 22);
      const localNameLen = readU16(zip, localHeaderOffset + 26);
      const localExtraLen = readU16(zip, localHeaderOffset + 28);

      expect(localCompressedSize).toBe(compressedSize);
      expect(localUncompressedSize).toBe(uncompressedSize);
      expect(localNameLen).toBe(nameLen);

      const nameStart = localHeaderOffset + 30;
      const nameBytes = zip.slice(nameStart, nameStart + localNameLen);
      const dataStart = nameStart + localNameLen + localExtraLen;
      const dataBytes = zip.slice(dataStart, dataStart + localCompressedSize);

      entries.push({ nameBytes, storedCrc: localCrc, dataBytes });

      cdPos += 46 + nameLen + extraLen + commentLen;
    }

    return { entries, eocdCount, centralDirOffset };
  }

  test("decoded entries match the inputs exactly", () => {
    const input: ZipEntry[] = [
      { name: "notes.txt", bytes: utf8Encode("hello world, this is ASCII") },
      { name: "José 😀.txt", bytes: utf8Encode("José 😀 — multibyte name and body") },
      { name: "empty.txt", bytes: new Uint8Array(0) },
      { name: "data.bin", bytes: Uint8Array.from([0, 1, 2, 255, 254]) },
    ];

    const zip = buildZip(input);
    const decoded = decodeStoredZip(zip);

    expect(decoded.entries.length).toBe(input.length);
    expect(decoded.eocdCount).toBe(input.length);

    // Central-directory offset sanity: the byte range EOCD points at
    // really does start with a central-directory header.
    expect(readU32(zip, decoded.centralDirOffset)).toBe(CENTRAL_SIG);

    for (let i = 0; i < input.length; i++) {
      const expected = input[i];
      const actual = decoded.entries[i];

      expect(Array.from(actual.nameBytes)).toEqual(Array.from(utf8Encode(expected.name)));
      expect(Array.from(actual.dataBytes)).toEqual(Array.from(expected.bytes));

      const expectedCrc = crc32(expected.bytes);
      expect(actual.storedCrc).toBe(expectedCrc);
      expect(actual.storedCrc).toBe(crc32(actual.dataBytes));
    }

    // The zero-byte file specifically exercises size=0 handling.
    const emptyEntry = decoded.entries[2];
    expect(emptyEntry.dataBytes.length).toBe(0);
    expect(emptyEntry.storedCrc).toBe(0);
  });
});
