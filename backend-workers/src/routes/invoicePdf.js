// Workers route: POST /api/invoice-pdf — stores a device-generated invoice PDF
// in R2 so the auto-email sweep can attach it (2026-08-06 spec).
//
// SECURITY MODEL:
//   Caller sends their Supabase JWT ("Authorization: Bearer <token>"); the
//   server verifies it (anon key), extracts the user id, and writes the object
//   under that user's prefix only. The service role key is never involved —
//   R2 access is via the binding.
//
// Required bindings: SUPABASE_URL, SUPABASE_ANON_KEY, INVOICE_PDFS (R2).

import { appCors, clientIp, jsonBody } from "../appCors.js";
import { validateUpload } from "../../lib/invoicePdfUpload.js";

// One PDF per completed job — 20 per IP per minute is generous headroom.
const rateLimitMap = new Map();
const RATE_LIMIT = 20;
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

export async function invoicePdfHandler(c) {
  appCors(c, "POST, OPTIONS");
  if (c.req.method === "OPTIONS") return c.body(null, 200);
  if (c.req.method !== "POST") return c.json({ error: "Method not allowed" }, 405);

  const ip = clientIp(c);
  if (isRateLimited(ip)) {
    return c.json({ error: "Too many requests. Please wait a moment." }, 429);
  }

  const { SUPABASE_URL, SUPABASE_ANON_KEY, INVOICE_PDFS } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !INVOICE_PDFS) {
    return c.json({ error: "Server misconfiguration: SUPABASE_URL, SUPABASE_ANON_KEY, and the INVOICE_PDFS R2 binding are required." }, 500);
  }

  const auth = c.req.header("authorization");
  if (!auth || !auth.startsWith("Bearer ")) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const userJwt = auth.slice(7);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return c.json({ error: "Invalid or expired session. Please sign in again." }, 401);
  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) return c.json({ error: "Unauthorized" }, 401);

  const body = (await jsonBody(c)) || {};
  const check = validateUpload({ invoiceId: body.invoiceId, pdfBase64: body.pdfBase64 });
  if (!check.ok) return c.json({ error: check.error }, check.status);

  try {
    await INVOICE_PDFS.put(`${userId}/${body.invoiceId}.pdf`, check.bytes, {
      httpMetadata: { contentType: "application/pdf" },
    });
    return c.json({ ok: true }, 200);
  } catch (err) {
    console.error("[invoice-pdf] R2 put failed:", err.message);
    return c.json({ error: "Could not store the PDF. Please try again." }, 500);
  }
}
