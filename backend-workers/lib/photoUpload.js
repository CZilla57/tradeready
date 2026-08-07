// backend-workers/lib/photoUpload.js
// Pure validation for the PUT /api/photos/:photoId upload (2026-08-06 job-photo
// R2 sync spec). No I/O — the route (src/routes/photos.js) does auth + R2 put
// around it. Mirrors lib/invoicePdfUpload.js, but photos stream as a raw binary
// PUT body (FileSystem.uploadAsync) rather than a base64 JSON field, so this
// validates the id + request headers, not a decoded body.

// JobPhoto ids are `p<timestamp>_<base36-rand>` (see types/models.ts JobPhoto).
// Bounded lengths keep a hostile id from producing an absurd R2 key and block
// path traversal (no '/', '.', etc.).
const PHOTO_ID_RE = /^p[0-9]{1,20}_[a-z0-9]{1,32}$/;

// Post-compression (1600px / JPEG 0.7) a photo is ~0.2–0.6 MB; 6 MB is generous
// headroom while still rejecting an un-compressed multi-MB original.
const MAX_PHOTO_BYTES = 6 * 1024 * 1024;

function isValidPhotoId(photoId) {
  return typeof photoId === "string" && PHOTO_ID_RE.test(photoId);
}

// contentType comes off the request header; accept only JPEG (what the client
// produces via ImageManipulator SaveFormat.JPEG). Lenient on trailing params.
function isJpegContentType(contentType) {
  return (
    typeof contentType === "string" &&
    contentType.trim().toLowerCase().startsWith("image/jpeg")
  );
}

// Validate a PUT before streaming the body to R2. contentLength is the raw
// Content-Length header value (string | null). It is treated as an ADVISORY
// cap, not a hard requirement: the native uploader (FileSystem.uploadAsync)
// owns that header, so a present-but-oversized value is rejected, while an
// absent one is allowed through — client-side compression is the real size
// control and the Workers platform caps request-body size regardless.
function validatePhotoUpload({ photoId, contentType, contentLength }) {
  if (!isValidPhotoId(photoId)) {
    return { ok: false, status: 400, error: "Invalid photoId" };
  }
  if (!isJpegContentType(contentType)) {
    return { ok: false, status: 415, error: "Content-Type must be image/jpeg" };
  }
  if (contentLength != null && String(contentLength).length > 0) {
    const size = Number(contentLength);
    if (!Number.isInteger(size) || size <= 0) {
      return { ok: false, status: 400, error: "Invalid Content-Length" };
    }
    if (size > MAX_PHOTO_BYTES) {
      return { ok: false, status: 413, error: "Photo too large" };
    }
  }
  return { ok: true, status: 200 };
}

module.exports = {
  PHOTO_ID_RE,
  MAX_PHOTO_BYTES,
  isValidPhotoId,
  isJpegContentType,
  validatePhotoUpload,
};
