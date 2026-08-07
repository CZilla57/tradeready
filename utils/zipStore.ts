// utils/zipStore.ts
// Zero-dependency "stored" (compression method 0) ZIP writer, plus the UTF-8
// and base64 primitives it needs. Pure and deterministic: the only otherwise-
// variable header fields (DOS mod time/date) are fixed to zero, so identical
// entries produce byte-identical archives. Hermes has no guaranteed TextEncoder
// or btoa, so both are hand-rolled here.
// Spec: docs/superpowers/specs/2026-08-07-accountant-package-design.md

let CRC_TABLE: Uint32Array | null = null;
function crcTable(): Uint32Array {
  if (CRC_TABLE) return CRC_TABLE;
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  CRC_TABLE = t;
  return t;
}

export function crc32(bytes: Uint8Array): number {
  const t = crcTable();
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = t[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let code = s.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i++;
      }
    }
    if (code < 0x80) out.push(code);
    else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    else if (code < 0x10000)
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    else
      out.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
  }
  return Uint8Array.from(out);
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
export function base64Encode(bytes: Uint8Array): string {
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
  }
  const rem = bytes.length - i;
  if (rem === 1) {
    const n = bytes[i] << 16;
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + "==";
  } else if (rem === 2) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + "=";
  }
  return out;
}

export type ZipEntry = { name: string; bytes: Uint8Array };

const u16 = (n: number): number[] => [n & 0xff, (n >>> 8) & 0xff];
const u32 = (n: number): number[] => [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff];

/**
 * A stored (uncompressed) ZIP. Flag bit 11 (0x0800) marks filenames UTF-8.
 * mod time/date are zeroed for determinism; compressed size == uncompressed size.
 */
export function buildZip(entries: ZipEntry[]): Uint8Array {
  const out: number[] = [];
  const records: { nameBytes: Uint8Array; crc: number; size: number; offset: number }[] = [];

  for (const e of entries) {
    const nameBytes = utf8Encode(e.name);
    const crc = crc32(e.bytes);
    const size = e.bytes.length;
    const offset = out.length;
    out.push(
      ...u32(0x04034b50), ...u16(20), ...u16(0x0800), ...u16(0),
      ...u16(0), ...u16(0), ...u32(crc), ...u32(size), ...u32(size),
      ...u16(nameBytes.length), ...u16(0),
    );
    for (let i = 0; i < nameBytes.length; i++) out.push(nameBytes[i]);
    for (let i = 0; i < e.bytes.length; i++) out.push(e.bytes[i]);
    records.push({ nameBytes, crc, size, offset });
  }

  const centralStart = out.length;
  for (const r of records) {
    out.push(
      ...u32(0x02014b50), ...u16(20), ...u16(20), ...u16(0x0800), ...u16(0),
      ...u16(0), ...u16(0), ...u32(r.crc), ...u32(r.size), ...u32(r.size),
      ...u16(r.nameBytes.length), ...u16(0), ...u16(0), ...u16(0), ...u16(0),
      ...u32(0), ...u32(r.offset),
    );
    for (let i = 0; i < r.nameBytes.length; i++) out.push(r.nameBytes[i]);
  }
  const centralSize = out.length - centralStart;

  out.push(
    ...u32(0x06054b50), ...u16(0), ...u16(0),
    ...u16(records.length), ...u16(records.length),
    ...u32(centralSize), ...u32(centralStart), ...u16(0),
  );

  return Uint8Array.from(out);
}
