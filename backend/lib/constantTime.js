// Constant-time string comparison shared by the estimate-approval endpoints
// (via estimateStore) and the RevenueCat subscription webhook. Extracted from
// estimateStore.js 2026-08-03 so secret checks don't have to import the whole
// Supabase store. NOT routed by Vercel (lives under lib/, not api/).

const crypto = require('crypto');

// Length-safe constant-time string compare (both must be non-empty strings).
function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length === 0 || b.length === 0) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

module.exports = { constantTimeEqual };
