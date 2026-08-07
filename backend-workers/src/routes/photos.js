// Workers route: /api/photos/:photoId — cross-device job-photo mirror in R2
// (2026-08-06 job-photo R2 sync spec). PUT stores, GET streams back, DELETE
// removes. The device always renders photos from local disk; R2 is a background
// mirror that survives reinstall and syncs across a user's devices.
//
// SECURITY MODEL (identical to invoicePdf.js):
//   Caller sends their Supabase JWT ("Authorization: Bearer <token>"); the
//   server verifies it (anon key), extracts the user id, and reads/writes
//   ONLY under that user's key prefix. A user therefore can never touch another
//   user's photos — the key's userId comes from the verified token, not input.
//   The service role key is never involved; R2 access is via the binding.
//
// Required bindings: SUPABASE_URL, SUPABASE_ANON_KEY, PHOTOS (R2).

import { appCors, clientIp } from "../appCors.js";
import { validatePhotoUpload, isValidPhotoId } from "../../lib/photoUpload.js";

// Attaching a few photos to a job is a burst; 60/IP/min is generous headroom
// while still capping abuse.
const rateLimitMap = new Map();
const RATE_LIMIT = 60;
const WINDOW_MS = 60_000;

function isRateLimited(ip) {
  const now = Date.now();
  const timestamps = (rateLimitMap.get(ip) || []).filter((t) => now - t < WINDOW_MS);
  if (timestamps.length >= RATE_LIMIT) {
    rateLimitMap.set(ip, timestamps);
    return true;
  }
  timestamps.push(now);
  rateLimitMap.set(ip, timestamps);
  return false;
}

// Verify the Supabase JWT → user id, or return an error Response.
async function authUserId(c, SUPABASE_URL, SUPABASE_ANON_KEY) {
  const auth = c.req.header("authorization");
  if (!auth || !auth.startsWith("Bearer ")) {
    return { error: c.json({ error: "Unauthorized" }, 401) };
  }
  const userJwt = auth.slice(7);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return { error: c.json({ error: "Invalid or expired session. Please sign in again." }, 401) };
  }
  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) return { error: c.json({ error: "Unauthorized" }, 401) };
  return { userId };
}

export async function photosHandler(c) {
  appCors(c, "GET, PUT, DELETE, OPTIONS");
  if (c.req.method === "OPTIONS") return c.body(null, 200);

  const method = c.req.method;
  if (method !== "GET" && method !== "PUT" && method !== "DELETE") {
    return c.json({ error: "Method not allowed" }, 405);
  }

  const ip = clientIp(c);
  if (isRateLimited(ip)) {
    return c.json({ error: "Too many requests. Please wait a moment." }, 429);
  }

  const { SUPABASE_URL, SUPABASE_ANON_KEY, PHOTOS } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !PHOTOS) {
    return c.json({ error: "Server misconfiguration: SUPABASE_URL, SUPABASE_ANON_KEY, and the PHOTOS R2 binding are required." }, 500);
  }

  const { userId, error } = await authUserId(c, SUPABASE_URL, SUPABASE_ANON_KEY);
  if (error) return error;

  const photoId = c.req.param("photoId");
  const key = `${userId}/${photoId}.jpg`;

  if (method === "PUT") {
    const check = validatePhotoUpload({
      photoId,
      contentType: c.req.header("content-type"),
      contentLength: c.req.header("content-length"),
    });
    if (!check.ok) return c.json({ error: check.error }, check.status);
    try {
      await PHOTOS.put(key, c.req.raw.body, {
        httpMetadata: { contentType: "image/jpeg" },
      });
      return c.json({ ok: true }, 200);
    } catch (err) {
      console.error("[photos] R2 put failed:", err.message);
      return c.json({ error: "Could not store the photo. Please try again." }, 500);
    }
  }

  // GET and DELETE carry no body — still validate the id so it can't shape a
  // key outside the user's prefix.
  if (!isValidPhotoId(photoId)) {
    return c.json({ error: "Invalid photoId" }, 400);
  }

  if (method === "GET") {
    try {
      const obj = await PHOTOS.get(key);
      if (!obj) return c.json({ error: "Not found" }, 404);
      c.header("Content-Type", obj.httpMetadata?.contentType || "image/jpeg");
      c.header("Cache-Control", "private, max-age=86400");
      return c.body(obj.body, 200);
    } catch (err) {
      console.error("[photos] R2 get failed:", err.message);
      return c.json({ error: "Could not fetch the photo. Please try again." }, 500);
    }
  }

  // DELETE — R2 delete is idempotent (no error when the key is absent).
  try {
    await PHOTOS.delete(key);
    return c.body(null, 204);
  } catch (err) {
    console.error("[photos] R2 delete failed:", err.message);
    return c.json({ error: "Could not delete the photo. Please try again." }, 500);
  }
}
