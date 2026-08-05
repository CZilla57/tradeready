/**
 * One serverless function serving all booking-link routes — the 11th of the
 * Hobby plan's 12 (see api/estimate/[action].js for the cap story; count
 * before adding any api/ file). Handlers live in lib/booking/ and each owns
 * its CORS, method check, auth and rate limiting.
 *
 * Routes: /api/booking/mint (JWT), /api/booking/config (public, token-gated),
 * /api/booking/submit (public, token-gated).
 */
const mint = require('../../lib/booking/mint');
const config = require('../../lib/booking/config');
const submit = require('../../lib/booking/submit');

const ROUTES = {
  'mint': mint,
  'config': config,
  'submit': submit,
};

module.exports = async function handler(req, res) {
  const action = req.query.action;
  // Own keys only — inherited names like ?action=constructor would otherwise
  // resolve via Object.prototype and slip past the not-found check.
  const route = Object.prototype.hasOwnProperty.call(ROUTES, action) ? ROUTES[action] : null;
  if (!route) return res.status(404).json({ error: 'Not found' });
  return route(req, res);
};
