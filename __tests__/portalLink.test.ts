// __tests__/portalLink.test.ts
// The portal mint IS the booking mint (spec §3: the endpoint is a
// purpose-agnostic stateless RNG) — the identity assertion pins that reuse
// so nobody later forks a duplicate fetch wrapper.

import { buildPortalUrl, mintPortalToken, PORTAL_PUBLIC_BASE } from '../utils/portalLink';
import { mintBookingToken } from '../utils/bookingLink';

describe('portalLink', () => {
  it('builds the portal URL with an encoded token', () => {
    expect(PORTAL_PUBLIC_BASE).toBe('https://gettradereadyapp.com/portal.html');
    expect(buildPortalUrl('abc123')).toBe('https://gettradereadyapp.com/portal.html?p=abc123');
    expect(buildPortalUrl('a&b')).toBe('https://gettradereadyapp.com/portal.html?p=a%26b');
  });

  it('mintPortalToken IS mintBookingToken (single mint wrapper, no fork)', () => {
    expect(mintPortalToken).toBe(mintBookingToken);
  });
});
