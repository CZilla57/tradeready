// __tests__/routeDispatcherGuard.test.js
// The two route dispatchers look actions up in a plain object literal, which
// inherits from Object.prototype — so before the hasOwnProperty guard,
// ?action=constructor resolved to a function, slipped past the not-found check
// and hung the serverless invocation until maxDuration (unauthenticated
// compute burn). These pin the guard: prototype-chain names and unknown
// actions get the 404, and every real route still dispatches.

// Stub the route handlers so requiring the dispatchers pulls in no env or
// vendor SDKs (connectStatus/createConnectAccount require('stripe') at top).
jest.mock('../backend/lib/estimate/createLink', () => jest.fn());
jest.mock('../backend/lib/estimate/respond', () => jest.fn());
jest.mock('../backend/lib/estimate/view', () => jest.fn());
jest.mock('../backend/lib/stripe/connectStatus', () => jest.fn());
jest.mock('../backend/lib/stripe/createConnectAccount', () => jest.fn());
jest.mock('../backend/lib/stripe/disconnect', () => jest.fn());
jest.mock('../backend/lib/stripe/connectReturn', () => jest.fn());

const estimateDispatcher = require('../backend/api/estimate/[action].js');
const stripeDispatcher = require('../backend/api/stripe/connect.js');

const ESTIMATE_ROUTES = {
  'create-link': require('../backend/lib/estimate/createLink'),
  'respond': require('../backend/lib/estimate/respond'),
  'view': require('../backend/lib/estimate/view'),
};

const STRIPE_ROUTES = {
  'connect-status': require('../backend/lib/stripe/connectStatus'),
  'create-connect-account': require('../backend/lib/stripe/createConnectAccount'),
  'disconnect': require('../backend/lib/stripe/disconnect'),
  'connect-return': require('../backend/lib/stripe/connectReturn'),
};

function makeRes() {
  return {
    statusCode: null,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      return this;
    },
  };
}

const PROTOTYPE_KEYS = ['constructor', '__proto__', 'hasOwnProperty', 'toString'];

beforeEach(() => {
  jest.clearAllMocks();
});

describe.each([
  ['api/estimate/[action].js', estimateDispatcher, ESTIMATE_ROUTES],
  ['api/stripe/connect.js', stripeDispatcher, STRIPE_ROUTES],
])('%s', (_name, dispatch, routes) => {
  test.each(PROTOTYPE_KEYS)('?action=%s gets the not-found response', async (key) => {
    const res = makeRes();
    await dispatch({ query: { action: key } }, res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'Not found' });
  });

  test('an unknown action gets the not-found response', async () => {
    const res = makeRes();
    await dispatch({ query: { action: 'fake-no-such-route' } }, res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'Not found' });
  });

  test('a missing action gets the not-found response', async () => {
    const res = makeRes();
    await dispatch({ query: {} }, res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'Not found' });
  });

  test.each(Object.keys(routes))('a real action (%s) still dispatches', async (action) => {
    const req = { query: { action } };
    const res = makeRes();
    await dispatch(req, res);
    expect(routes[action]).toHaveBeenCalledWith(req, res);
    // The 404 path was not taken — the handler owns the response.
    expect(res.statusCode).toBeNull();
  });
});
