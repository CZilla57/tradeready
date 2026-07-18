const { nextApproval } = require('../backend/api/estimate/respond');

const base = { token: 't', sentAt: 'x', snapshot: {} };
const meta = { consentAt: '2026-07-17T00:00:00.000Z', ip: '1.2.3.4', userAgent: 'ua' };

describe('nextApproval', () => {
  it('records an approval with server consent + signer name', () => {
    const out = nextApproval(base, { decision: 'approved', signerName: 'Sam Doe' }, meta);
    expect(out.decision).toBe('approved');
    expect(out.consentAt).toBe(meta.consentAt);
    expect(out.signerName).toBe('Sam Doe');
  });

  it('records a decline with reason', () => {
    const out = nextApproval(base, { decision: 'declined', declineReason: 'Too high' }, meta);
    expect(out.decision).toBe('declined');
    expect(out.declineReason).toBe('Too high');
  });

  it('locks once approved — further changes are ignored', () => {
    const approved = nextApproval(base, { decision: 'approved', signerName: 'Sam' }, meta);
    const out = nextApproval(approved, { decision: 'declined' }, { ...meta, consentAt: 'LATER' });
    expect(out).toBe(approved); // unchanged reference
  });

  it('allows declined -> approved (customer changed their mind)', () => {
    const declined = nextApproval(base, { decision: 'declined' }, meta);
    const out = nextApproval(declined, { decision: 'approved', signerName: 'Sam' }, { ...meta, consentAt: 'L2' });
    expect(out.decision).toBe('approved');
    expect(out.consentAt).toBe('L2');
  });
});
