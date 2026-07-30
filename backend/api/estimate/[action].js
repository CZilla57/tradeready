/**
 * One serverless function serving all three estimate-approval routes.
 *
 * Vercel's Hobby plan caps a deployment at 12 serverless functions, and adding
 * the estimate-approval loop took this backend to 14. Every .js file under
 * api/ counts as a function; files under lib/ do not. So the three handlers
 * were moved verbatim into lib/estimate/ and are dispatched from here.
 *
 * Public URLs are unchanged - /api/estimate/create-link, /api/estimate/respond
 * and /api/estimate/view all still resolve, so neither the app nor the
 * customer-facing estimate.html page needed a change. Each handler still owns
 * its own CORS headers, method check, auth and rate limiting.
 */
const createLink = require('../../lib/estimate/createLink');
const respond = require('../../lib/estimate/respond');
const view = require('../../lib/estimate/view');

const ROUTES = {
  'create-link': createLink,
  'respond': respond,
  'view': view,
};

module.exports = async function handler(req, res) {
  const route = ROUTES[req.query.action];
  if (!route) return res.status(404).json({ error: 'Not found' });
  return route(req, res);
};
