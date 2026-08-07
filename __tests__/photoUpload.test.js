const {
  PHOTO_ID_RE,
  MAX_PHOTO_BYTES,
  isValidPhotoId,
  isJpegContentType,
  validatePhotoUpload,
} = require("../backend-workers/lib/photoUpload");

// A JobPhoto id: `p<timestamp>_<base36-rand>`.
const GOOD_ID = "p1723000000000_ab12xyz";

describe("isValidPhotoId / PHOTO_ID_RE", () => {
  test("accepts a well-formed JobPhoto id", () => {
    expect(isValidPhotoId(GOOD_ID)).toBe(true);
    expect(PHOTO_ID_RE.test(GOOD_ID)).toBe(true);
  });
  test("rejects traversal, wrong shape, and non-strings", () => {
    for (const bad of [
      "",
      "../secret",
      "p1/2",
      "p1_ab.jpg",
      "x1723_ab",          // must start with 'p'
      "p_ab",              // no timestamp digits
      "p1723_",            // no rand
      "P1723_ab",          // uppercase p
      "p1723_AB",          // uppercase rand
      "p" + "1".repeat(21) + "_ab", // timestamp too long
      "p1_" + "a".repeat(33),       // rand too long
      42,
      null,
      undefined,
    ]) {
      expect(isValidPhotoId(bad)).toBe(false);
    }
  });
});

describe("isJpegContentType", () => {
  test("accepts image/jpeg (with optional params, any case)", () => {
    expect(isJpegContentType("image/jpeg")).toBe(true);
    expect(isJpegContentType("Image/JPEG")).toBe(true);
    expect(isJpegContentType(" image/jpeg ")).toBe(true);
    expect(isJpegContentType("image/jpeg; charset=binary")).toBe(true);
  });
  test("rejects other types and non-strings", () => {
    for (const bad of ["image/png", "application/pdf", "text/plain", "", null, 1]) {
      expect(isJpegContentType(bad)).toBe(false);
    }
  });
});

describe("validatePhotoUpload", () => {
  test("accepts a well-formed jpeg PUT under the cap", () => {
    const r = validatePhotoUpload({
      photoId: GOOD_ID,
      contentType: "image/jpeg",
      contentLength: "204800",
    });
    expect(r.ok).toBe(true);
    expect(r.status).toBe(200);
  });
  test("rejects a bad photoId with 400", () => {
    const r = validatePhotoUpload({
      photoId: "../x",
      contentType: "image/jpeg",
      contentLength: "100",
    });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(400);
  });
  test("rejects a non-jpeg content type with 415", () => {
    const r = validatePhotoUpload({
      photoId: GOOD_ID,
      contentType: "image/png",
      contentLength: "100",
    });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(415);
  });
  test("allows an absent Content-Length (native uploader owns the header)", () => {
    for (const absent of [undefined, null, ""]) {
      const r = validatePhotoUpload({
        photoId: GOOD_ID,
        contentType: "image/jpeg",
        contentLength: absent,
      });
      expect(r.ok).toBe(true);
    }
  });
  test("rejects a present-but-malformed Content-Length with 400", () => {
    for (const bad of ["0", "-5", "abc", "12.5"]) {
      const r = validatePhotoUpload({
        photoId: GOOD_ID,
        contentType: "image/jpeg",
        contentLength: bad,
      });
      expect(r.ok).toBe(false);
      expect(r.status).toBe(400);
    }
  });
  test("rejects an over-cap payload with 413", () => {
    const r = validatePhotoUpload({
      photoId: GOOD_ID,
      contentType: "image/jpeg",
      contentLength: String(MAX_PHOTO_BYTES + 1),
    });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(413);
  });
  test("accepts exactly at the cap", () => {
    const r = validatePhotoUpload({
      photoId: GOOD_ID,
      contentType: "image/jpeg",
      contentLength: String(MAX_PHOTO_BYTES),
    });
    expect(r.ok).toBe(true);
  });
});
