/**
 * One serverless function serving the four Stripe Connect routes.
 *
 * Same reason as api/estimate/[action].js: the Hobby plan allows 12 serverless
 * functions per deployment and every .js under api/ counts as one, so these
 * four handlers were moved verbatim into lib/stripe/ and are dispatched here.
 *
 * Reached through explicit rewrites in vercel.json rather than a dynamic
 * [action].js segment, deliberately: api/stripe/webhook.js is a sibling route
 * that MUST keep receiving Stripe's requests directly, because it verifies a
 * signature over the raw request body. A dynamic segment would sit next to it
 * and rely on static-beats-dynamic route precedence; explicit rewrites leave no
 * room for that to go wrong, and a silently shadowed webhook would stop
 * invoices from auto-marking paid.
 *
 * Public URLs are unchanged - /api/stripe/connect-status,
 * /api/stripe/create-connect-account, /api/stripe/disconnect and
 * /api/stripe/connect-return all still resolve. Each handler still owns its own
 * method check, auth and CORS.
 */
const connectStatus = require('../../lib/stripe/connectStatus');
const createConnectAccount = require('../../lib/stripe/createConnectAccount');
const disconnect = require('../../lib/stripe/disconnect');
const connectReturn = require('../../lib/stripe/connectReturn');

const ROUTES = {
  'connect-status': connectStatus,
  'create-connect-account': createConnectAccount,
  'disconnect': disconnect,
  'connect-return': connectReturn,
};

module.exports = async function handler(req, res) {
  const action = req.query.action;
  // Own keys only — inherited names like ?action=constructor would otherwise resolve
  // via Object.prototype, slip past the not-found check and hang the invocation.
  const route = Object.prototype.hasOwnProperty.call(ROUTES, action) ? ROUTES[action] : null;
  if (!route) return res.status(404).json({ error: 'Not found' });
  return route(req, res);
};
