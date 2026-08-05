/**
 * One serverless function serving all estimate routes.
 *
 * Vercel's Hobby plan caps a deployment at 12 serverless functions, and adding
 * the estimate-approval loop took this backend to 14. Every .js file under
 * api/ counts as a function; files under lib/ do not. So the handlers
 * were moved verbatim into lib/estimate/ and are dispatched from here.
 *
 * Public URLs are unchanged - /api/estimate/create-link, /api/estimate/respond,
 * /api/estimate/view and /api/estimate/portal-view (customer-portal read, 2026-08-05)
 * all still resolve, so neither the app nor the customer-facing estimate.html page
 * needed a change. Each handler still owns its own CORS headers, method check,
 * auth and rate limiting.
 */
const createLink = require('../../lib/estimate/createLink');
const respond = require('../../lib/estimate/respond');
const view = require('../../lib/estimate/view');
const portalView = require('../../lib/estimate/portalView');

const ROUTES = {
  'create-link': createLink,
  'respond': respond,
  'view': view,
  'portal-view': portalView,
};

module.exports = async function handler(req, res) {
  const action = req.query.action;
  // Own keys only — inherited names like ?action=constructor would otherwise resolve
  // via Object.prototype, slip past the not-found check and hang the invocation.
  const route = Object.prototype.hasOwnProperty.call(ROUTES, action) ? ROUTES[action] : null;
  if (!route) return res.status(404).json({ error: 'Not found' });
  return route(req, res);
};
