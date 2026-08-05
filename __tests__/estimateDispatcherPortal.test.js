// __tests__/estimateDispatcherPortal.test.js
// portal-view joins the estimate dispatcher (2026-08-05 portal spec — the
// owner-approved amendment to the dispatcher's route set). The three
// original routes must keep routing untouched.

jest.mock('../backend/lib/estimate/createLink', () => jest.fn((q, r) => r.status(200).json({ route: 'create-link' })));
jest.mock('../backend/lib/estimate/respond', () => jest.fn((q, r) => r.status(200).json({ route: 'respond' })));
jest.mock('../backend/lib/estimate/view', () => jest.fn((q, r) => r.status(200).json({ route: 'view' })));
jest.mock('../backend/lib/estimate/portalView', () => jest.fn((q, r) => r.status(200).json({ route: 'portal-view' })));
jest.mock('../backend/lib/estimate/changeView', () => jest.fn((q, r) => r.status(200).json({ route: 'change-view' })));
jest.mock('../backend/lib/estimate/changeRespond', () => jest.fn((q, r) => r.status(200).json({ route: 'change-respond' })));

const handler = require('../backend/api/estimate/[action]');

function mockRes() {
  const res = { statusCode: 0, body: null };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  return res;
}

describe('estimate dispatcher with portal-view', () => {
  it.each(['create-link', 'respond', 'view', 'portal-view', 'change-view', 'change-respond'])('routes %s', async (action) => {
    const res = mockRes();
    await handler({ query: { action } }, res);
    expect(res.body).toEqual({ route: action });
  });

  it('404s unknown and prototype-inherited actions', async () => {
    for (const action of ['nope', 'constructor']) {
      const res = mockRes();
      await handler({ query: { action } }, res);
      expect(res.statusCode).toBe(404);
    }
  });
});
