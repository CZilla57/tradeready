// GET /api/booking/config?b=<token>
// Form bootstrap for book.html. Returns ONLY the business display name —
// the settings blob it reads also holds contact info, rates and the push
// token, none of which may leak to an anonymous caller.

const { lookupUserByBookingToken } = require('./store');
const { applyCors } = require('../estimate/cors');
const { createRateLimiter } = require('../guards');

const allow = createRateLimiter({ limit: 30 });

module.exports = async function config(req, res) {
  applyCors(req, res, 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const token = req.query.b;
  if (!token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await lookupUserByBookingToken(String(token));
  } catch (err) {
    console.error('[booking/config] lookup failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) return res.status(404).json({ error: 'This link is invalid.' });

  return res.status(200).json({ businessName: String(row.data?.businessName || '').slice(0, 120) });
};
