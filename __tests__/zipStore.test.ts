import { crc32, utf8Encode, base64Encode, buildZip } from "../utils/zipStore";

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
