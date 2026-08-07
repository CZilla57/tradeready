// __tests__/photoSignWorkers.test.js
// Phase 12B: HMAC signing for anonymous portal photo reads. The signature
// binds userId + photoId + expiry to a server-held secret — a signed URL
// grants exactly one object for a bounded time. Signatures are computed per
// portal-view response and NEVER persisted. resolvePublicPhotoKey is the
// public route's whole accept/reject decision: shape checks BEFORE the HMAC,
// and the R2 key is derived only from verified values.

const {
  photoSignature,
  verifyPhotoSignature,
  resolvePublicPhotoKey,
  PHOTO_URL_TTL_SEC,
} = require("../backend-workers/lib/photoSign.js");
const { PHOTO_ID_RE } = require("../backend-workers/lib/photoUpload.js");

const SECRET = "s".repeat(32);
const USER = "0f8fad5b-d9cb-469f-a165-70867728950e";
const PHOTO = "p1723000000000_ab12xyz";
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const EXP = Math.floor(NOW_MS / 1000) + PHOTO_URL_TTL_SEC;

const base = { secret: SECRET, userId: USER, photoId: PHOTO, expiresAtSec: EXP };

describe("photoSignature / verifyPhotoSignature", () => {
  test("valid signature round-trips", () => {
    const sig = photoSignature(base);
    expect(sig).toMatch(/^[0-9a-f]{64}$/);
    expect(verifyPhotoSignature({ ...base, sig, nowMs: NOW_MS })).toBe(true);
  });

  test.each([
    ["photoId", { photoId: "p1723000000000_evil" }],
    ["userId", { userId: "1f8fad5b-d9cb-469f-a165-70867728950e" }],
    ["expiry", { expiresAtSec: EXP + 1 }],
  ])("tampered %s fails", (_label, over) => {
    const sig = photoSignature(base);
    expect(verifyPhotoSignature({ ...base, ...over, sig, nowMs: NOW_MS })).toBe(false);
  });

  test("expired signature fails even when authentic", () => {
    const sig = photoSignature(base);
    expect(verifyPhotoSignature({ ...base, sig, nowMs: (EXP + 1) * 1000 })).toBe(false);
  });

  test("wrong secret / missing secret / missing sig all fail", () => {
    const sig = photoSignature(base);
    expect(verifyPhotoSignature({ ...base, secret: "x".repeat(32), sig, nowMs: NOW_MS })).toBe(false);
    expect(verifyPhotoSignature({ ...base, secret: undefined, sig, nowMs: NOW_MS })).toBe(false);
    expect(verifyPhotoSignature({ ...base, sig: undefined, nowMs: NOW_MS })).toBe(false);
    expect(verifyPhotoSignature({ ...base, sig: "", nowMs: NOW_MS })).toBe(false);
  });
});

describe("resolvePublicPhotoKey", () => {
  const args = (over = {}) => ({
    secret: SECRET,
    photoId: PHOTO,
    userId: USER,
    expiresAtSec: String(EXP),
    sig: photoSignature(base),
    nowMs: NOW_MS,
    photoIdRe: PHOTO_ID_RE,
    ...over,
  });

  test("valid request yields the prefix-derived R2 key", () => {
    expect(resolvePublicPhotoKey(args())).toEqual({ ok: true, key: `${USER}/${PHOTO}.jpg` });
  });

  test.each([
    ["missing secret", { secret: undefined }],
    ["malformed userId", { userId: "../other" }],
    ["malformed photoId", { photoId: "../../etc/passwd" }],
    ["non-numeric expiry", { expiresAtSec: "soon" }],
    ["tampered sig", { sig: "f".repeat(64) }],
  ])("%s → { ok: false }", (_label, over) => {
    expect(resolvePublicPhotoKey(args(over))).toEqual({ ok: false });
  });
});
