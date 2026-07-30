// __tests__/estimateCors.test.js
// The approval page's fetches are cross-origin, so a wrong Access-Control-
// Allow-Origin doesn't fail loudly — the page renders and then reports
// "This link is invalid or has expired" for a perfectly valid link. These pin
// the allowlist that lets the page move to a branded domain without a flag day.

const {
  pickAllowedOrigin,
  GITHUB_PAGES_ORIGIN,
  BRANDED_ORIGIN,
} = require('../backend/lib/estimate/cors');

describe('pickAllowedOrigin', () => {
  test('echoes the github.io origin (where the page lives today)', () => {
    expect(pickAllowedOrigin(GITHUB_PAGES_ORIGIN)).toBe(GITHUB_PAGES_ORIGIN);
  });

  test('echoes the branded origin (where it is moving)', () => {
    expect(pickAllowedOrigin(BRANDED_ORIGIN)).toBe(BRANDED_ORIGIN);
  });

  test('both are allowed at once — that is the point, no flag day', () => {
    expect(GITHUB_PAGES_ORIGIN).not.toBe(BRANDED_ORIGIN);
    expect(pickAllowedOrigin(GITHUB_PAGES_ORIGIN)).toBe(GITHUB_PAGES_ORIGIN);
    expect(pickAllowedOrigin(BRANDED_ORIGIN)).toBe(BRANDED_ORIGIN);
  });

  test('an unknown origin never gets echoed back', () => {
    expect(pickAllowedOrigin('https://evil.example.com')).toBe(GITHUB_PAGES_ORIGIN);
  });

  test('a missing Origin header falls back rather than emitting empty or *', () => {
    for (const missing of [undefined, null, '']) {
      const picked = pickAllowedOrigin(missing);
      expect(picked).toBe(GITHUB_PAGES_ORIGIN);
      expect(picked).not.toBe('*');
    }
  });
});
