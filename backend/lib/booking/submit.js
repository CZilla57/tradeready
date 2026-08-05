// POST /api/booking/submit  { b, name, phone, email, address, details,
// preferredTiming, website }
// Public, token-gated write path for the booking link. Inserts ONE row into
// bookingRequests (service role); the DEVICE converts it to Customer + lead
// Job (utils/storage/bookingConversion.ts). Alerts are fire-and-forget —
// their failure never fails the submission. `website` is the honeypot: bots
// fill it, humans never see it; a hit gets a fake success so the bot learns
// nothing.

const crypto = require('crypto');
const { lookupUserByBookingToken, insertBookingRequest, newRequestId } = require('./store');
const { validateBookingPayload } = require('./validate');
const { notifyOwner } = require('./notifyOwner');
const { applyCors } = require('../estimate/cors');
const { createRateLimiter } = require('../guards');

const allow = createRateLimiter({ limit: 10 });

module.exports = async function submit(req, res) {
  applyCors(req, res, 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  const body = req.body || {};
  if (typeof body.website === 'string' && body.website.trim() !== '') {
    return res.status(200).json({ ok: true }); // honeypot — silent drop
  }

  const token = body.b;
  if (!token || typeof token !== 'string') return res.status(400).json({ error: 'Missing link parameters.' });

  const checked = validateBookingPayload(body);
  if (!checked.ok) return res.status(400).json({ error: checked.error });

  let row;
  try {
    row = await lookupUserByBookingToken(token);
  } catch (err) {
    console.error('[booking/submit] lookup failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) return res.status(404).json({ error: 'This link is invalid.' });

  const request = {
    id: newRequestId(Date.now(), crypto.randomBytes(3).toString('hex')),
    status: 'new',
    ...checked.value,
    createdAt: new Date().toISOString(),
  };

  try {
    await insertBookingRequest(row.user_id, request);
  } catch (err) {
    console.error('[booking/submit] insert failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }

  try {
    await notifyOwner({ userId: row.user_id, settingsData: row.data, request });
  } catch (err) {
    console.error('[booking/submit] notify failed:', err.message);
  }

  return res.status(200).json({ ok: true });
};
