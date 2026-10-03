// __tests__/bookingValidateLeadSource.test.js
// Phase 27 (lead source tracking): the optional `leadSource` on the Cloudflare
// Worker's booking validator. It is a marketing URL param (the booking page's
// ?src=), so it is cleaned and capped, never rejected: no leadSource input may
// fail an otherwise-valid booking. The native app normalizes presets, so the
// Worker keeps the casing it was given.
//
// Targets the Worker copy. The dormant Vercel twin (backend/lib/booking/
// validate.js) is intentionally unchanged and stays covered by
// bookingValidate.test.js.

const { validateBookingPayload } = require('../backend-workers/lib/booking/validate');

const good = {
  name: '  Dana Rivers ', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings',
};

const EMOJI = '\u{1F600}'; // one code point, two UTF-16 units
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

const withSource = (leadSource) => validateBookingPayload({ ...good, leadSource });

describe('validateBookingPayload leadSource (Worker copy)', () => {
  it('leaves no leadSource key when the field is absent', () => {
    const out = validateBookingPayload(good);
    expect(out.ok).toBe(true);
    expect('leadSource' in out.value).toBe(false);
    expect(Object.keys(out.value).sort()).toEqual(
      ['address', 'details', 'email', 'name', 'phone', 'preferredTiming']
    );
  });

  it('keeps a plain preset-style value as given', () => {
    const out = withSource('nextdoor');
    expect(out.ok).toBe(true);
    expect(out.value.leadSource).toBe('nextdoor');
  });

  it('does not lowercase or map the value (the native app normalizes presets)', () => {
    expect(withSource('NextDoor').value.leadSource).toBe('NextDoor');
    expect(withSource('Home Show 2026').value.leadSource).toBe('Home Show 2026');
    expect(withSource('google ads').value.leadSource).toBe('google ads');
  });

  it('trims surrounding whitespace and collapses internal runs to one space', () => {
    expect(withSource('  nextdoor  ').value.leadSource).toBe('nextdoor');
    expect(withSource('  home    show    2026  ').value.leadSource).toBe('home show 2026');
  });

  it('turns tabs and newlines into spaces instead of fusing the words', () => {
    expect(withSource('home\tshow').value.leadSource).toBe('home show');
    expect(withSource('home\nshow').value.leadSource).toBe('home show');
    expect(withSource('home\r\nshow').value.leadSource).toBe('home show');
    expect(withSource('\n\thome \t\n show\r\n').value.leadSource).toBe('home show');
  });

  it('strips control characters (Cc) without touching the text around them', () => {
    expect(withSource('next\u0000door').value.leadSource).toBe('nextdoor');
    expect(withSource('\u0001\u0007nextdoor\u001F').value.leadSource).toBe('nextdoor');
    expect(withSource('next\u007Fdoor').value.leadSource).toBe('nextdoor');
    expect(withSource('next\u0080\u0085\u009Fdoor').value.leadSource).toBe('nextdoor');
    expect(withSource('google\u0000 ads').value.leadSource).toBe('google ads');
  });

  it.each([
    ['number', 42],
    ['zero', 0],
    ['object', { src: 'nextdoor' }],
    ['array', ['nextdoor']],
    ['true', true],
    ['false', false],
    ['null', null],
    ['undefined', undefined],
  ])('drops a non-string (%s) silently and the booking still validates', (_label, bad) => {
    const out = withSource(bad);
    expect(out.ok).toBe(true);
    expect('leadSource' in out.value).toBe(false);
  });

  it.each([
    ['empty', ''],
    ['spaces only', '   '],
    ['tabs and newlines only', '\t\n\r\n '],
    ['control characters only', '\u0000\u0001\u007F\u009F'],
    ['control characters and spaces only', ' \u0000 \t \u0007 '],
  ])('drops an empty-after-cleaning value (%s) silently', (_label, empty) => {
    const out = withSource(empty);
    expect(out.ok).toBe(true);
    expect('leadSource' in out.value).toBe(false);
  });

  it('never returns an error for any leadSource input', () => {
    const weird = ['x'.repeat(5000), '\u0000'.repeat(500), { $gt: '' }, [], NaN, Symbol.iterator, () => 1];
    for (const input of weird) {
      const out = withSource(input);
      expect(out.ok).toBe(true);
    }
  });

  it('keeps a value of exactly 40 characters and truncates anything longer to 40', () => {
    expect(withSource('a'.repeat(40)).value.leadSource).toBe('a'.repeat(40));
    expect(withSource('a'.repeat(41)).value.leadSource).toBe('a'.repeat(40));
    expect(withSource('a'.repeat(500)).value.leadSource).toBe('a'.repeat(40));
  });

  it('trims again after truncating so the cut never leaves trailing whitespace', () => {
    const out = withSource('a'.repeat(39) + ' ' + 'b'.repeat(10));
    expect(out.value.leadSource).toBe('a'.repeat(39));
  });

  it('cleans before capping, so stripped characters do not eat the 40-character budget', () => {
    const out = withSource('\u0000'.repeat(30) + 'a'.repeat(40) + '   ');
    expect(out.value.leadSource).toBe('a'.repeat(40));
  });

  it('never splits an emoji at the 40-character boundary into a lone surrogate', () => {
    // 39 letters + emoji + tail: the emoji is the 40th character and is kept whole.
    const atBoundary = withSource('a'.repeat(39) + EMOJI + 'zzz').value.leadSource;
    expect(atBoundary).toBe('a'.repeat(39) + EMOJI);
    expect(LONE_SURROGATE.test(atBoundary)).toBe(false);
    expect(Array.from(atBoundary)).toHaveLength(40);

    // 40 letters + emoji: the emoji is character 41 and is dropped whole.
    const pastBoundary = withSource('a'.repeat(40) + EMOJI).value.leadSource;
    expect(pastBoundary).toBe('a'.repeat(40));
    expect(LONE_SURROGATE.test(pastBoundary)).toBe(false);

    // 38 letters + emoji + emoji: the second emoji is character 41 and is dropped whole.
    const twoEmoji = withSource('a'.repeat(38) + EMOJI + EMOJI + EMOJI).value.leadSource;
    expect(twoEmoji).toBe('a'.repeat(38) + EMOJI + EMOJI);
    expect(LONE_SURROGATE.test(twoEmoji)).toBe(false);
  });

  it('counts characters, not UTF-16 units, so an all-emoji value keeps 40 emoji', () => {
    const out = withSource(EMOJI.repeat(60)).value.leadSource;
    expect(out).toBe(EMOJI.repeat(40));
    expect(out.length).toBe(80);
    expect(LONE_SURROGATE.test(out)).toBe(false);
  });

  it('leaves the existing fields exactly as before when leadSource is present', () => {
    const withLead = validateBookingPayload({ ...good, leadSource: 'nextdoor' });
    const without = validateBookingPayload(good);
    expect(withLead.ok).toBe(true);
    const { leadSource, ...rest } = withLead.value;
    expect(leadSource).toBe('nextdoor');
    expect(rest).toEqual(without.value);
    expect(rest.name).toBe('Dana Rivers');
    expect(rest.preferredTiming).toBe('Mornings');
  });

  it('still enforces every existing rule when leadSource is present', () => {
    const lead = { leadSource: 'nextdoor' };
    expect(validateBookingPayload({ ...good, ...lead, name: '  ' }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...lead, details: '' }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...lead, phone: ' ', email: '' }).error).toMatch(/phone or email/i);
    expect(validateBookingPayload({ ...good, ...lead, email: 'not-an-email' }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...lead, name: 'x'.repeat(101) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...lead, details: { $gt: '' } }).ok).toBe(false);
  });

  it('does not let a bad leadSource mask or replace an existing-field error', () => {
    const out = validateBookingPayload({ ...good, leadSource: 42, name: '' });
    expect(out.ok).toBe(false);
    expect(out.error).toMatch(/your name/i);
  });

  it('is not a hard-capped CAPS field: an over-length value never produces a "too long" error', () => {
    const out = withSource('y'.repeat(41));
    expect(out.ok).toBe(true);
    expect(out.error).toBeUndefined();
  });
});
