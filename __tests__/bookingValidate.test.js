// __tests__/bookingValidate.test.js
// Server-authoritative field rules from spec §6. The page validates too, but
// only this layer is trusted.

const { validateBookingPayload } = require('../backend/lib/booking/validate');

const good = {
  name: '  Dana Rivers ', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings',
};

describe('validateBookingPayload', () => {
  it('accepts a full payload and returns trimmed values', () => {
    const out = validateBookingPayload(good);
    expect(out.ok).toBe(true);
    expect(out.value.name).toBe('Dana Rivers');
    expect(out.value.preferredTiming).toBe('Mornings');
  });

  it('accepts phone-only and email-only contact', () => {
    expect(validateBookingPayload({ ...good, email: '' }).ok).toBe(true);
    expect(validateBookingPayload({ ...good, phone: '' }).ok).toBe(true);
  });

  it('rejects when name or details is missing', () => {
    expect(validateBookingPayload({ ...good, name: '  ' }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, details: '' }).ok).toBe(false);
  });

  it('rejects when BOTH phone and email are empty', () => {
    const out = validateBookingPayload({ ...good, phone: ' ', email: '' });
    expect(out.ok).toBe(false);
    expect(out.error).toMatch(/phone or email/i);
  });

  it('rejects a malformed email but allows empty when phone exists', () => {
    expect(validateBookingPayload({ ...good, email: 'not-an-email' }).ok).toBe(false);
  });

  it('enforces length caps (name 100, phone 50, email 200, address 300, details 2000, timing 200)', () => {
    expect(validateBookingPayload({ ...good, name: 'x'.repeat(101) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, phone: 'x'.repeat(51) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, email: 'a@' + 'x'.repeat(199) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, address: 'x'.repeat(301) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, details: 'x'.repeat(2001) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, preferredTiming: 'x'.repeat(201) }).ok).toBe(false);
  });

  it('rejects non-string fields instead of coercing', () => {
    expect(validateBookingPayload({ ...good, details: { $gt: '' } }).ok).toBe(false);
  });
});
