// __tests__/estimateCors.test.js
// The approval page's fetches are cross-origin, so a wrong Access-Control-
// Allow-Origin doesn't fail loudly — the page renders and then reports
// "This link is invalid or has expired" for a perfectly valid link. That
// happened for real on 2026-07-30 when the Pages custom domain was switched
// on before the matching backend deploy landed.
//
// These pin the CUMULATIVE allowlist: every host the page has ever been served
// from stays allowed, because GitHub 301s retired hosts to the current one and
// the browser then reports the current host as the Origin — so dropping an
// entry silently breaks links already sitting in customers' inboxes.

const {
  pickAllowedOrigin,
  ALLOWED_ORIGINS,
  GITHUB_PAGES_ORIGIN,
} = require('../backend/lib/estimate/cors');

const ESTIMATES_SUBDOMAIN = 'https://estimates.gettradereadyapp.com';
const APEX = 'https://gettradereadyapp.com';
const WWW = 'https://www.gettradereadyapp.com';

describe('pickAllowedOrigin', () => {
  test('echoes the original Pages host — oldest links still resolve there', () => {
    expect(pickAllowedOrigin(GITHUB_PAGES_ORIGIN)).toBe(GITHUB_PAGES_ORIGIN);
  });

  test('echoes the estimates subdomain — the first branded host', () => {
    expect(pickAllowedOrigin(ESTIMATES_SUBDOMAIN)).toBe(ESTIMATES_SUBDOMAIN);
  });

  test('echoes the apex and www — the intended home', () => {
    expect(pickAllowedOrigin(APEX)).toBe(APEX);
    expect(pickAllowedOrigin(WWW)).toBe(WWW);
  });

  test('all four are allowed at once — no flag day on a domain move', () => {
    for (const o of [GITHUB_PAGES_ORIGIN, ESTIMATES_SUBDOMAIN, APEX, WWW]) {
      expect(ALLOWED_ORIGINS).toContain(o);
      expect(pickAllowedOrigin(o)).toBe(o);
    }
  });

  test('an unknown origin never gets echoed back', () => {
    expect(pickAllowedOrigin('https://evil.example.com')).toBe(GITHUB_PAGES_ORIGIN);
  });

  test('a look-alike host is not matched by prefix or suffix', () => {
    for (const impostor of [
      'https://gettradereadyapp.com.evil.test',
      'https://notgettradereadyapp.com',
      'http://gettradereadyapp.com', // plain http is a different origin
    ]) {
      expect(pickAllowedOrigin(impostor)).toBe(GITHUB_PAGES_ORIGIN);
    }
  });

  test('a missing Origin header falls back rather than emitting empty or *', () => {
    for (const missing of [undefined, null, '']) {
      const picked = pickAllowedOrigin(missing);
      expect(picked).toBe(GITHUB_PAGES_ORIGIN);
      expect(picked).not.toBe('*');
    }
  });
});
