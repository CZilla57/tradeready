const { planApprovalWrite } = require('../backend/lib/estimateStore');

const snap = { jobTitle: 'X', total: 100 };
const newSnap = { jobTitle: 'X', total: 250 };
const mint = () => 'MINTED';

describe('planApprovalWrite', () => {
  it('mints a token and sets snapshot for a fresh job', () => {
    const out = planApprovalWrite(undefined, snap, 's1', mint);
    expect(out.changed).toBe(true);
    expect(out.token).toBe('MINTED');
    expect(out.approval.snapshot).toBe(snap);
    expect(out.approval.token).toBe('MINTED');
    expect(out.sentAt).toBe('s1');
  });

  it('reuses an existing token and refreshes snapshot when not yet approved', () => {
    const existing = { token: 'T', sentAt: 's0', snapshot: snap };
    const out = planApprovalWrite(existing, newSnap, 's2', mint);
    expect(out.changed).toBe(true);
    expect(out.token).toBe('T');            // reused, not re-minted
    expect(out.approval.snapshot).toBe(newSnap);
    expect(out.sentAt).toBe('s2');
  });

  it('reuses an existing token and refreshes snapshot after a decline', () => {
    const existing = { token: 'T', sentAt: 's0', snapshot: snap, decision: 'declined' };
    const out = planApprovalWrite(existing, newSnap, 's2', mint);
    expect(out.changed).toBe(true);
    expect(out.approval.snapshot).toBe(newSnap);
  });

  it('FREEZES the snapshot once approved — returns existing unchanged', () => {
    const existing = { token: 'T', sentAt: 's0', snapshot: snap, decision: 'approved', consentAt: 'c1' };
    const out = planApprovalWrite(existing, newSnap, 's9', mint);
    expect(out.changed).toBe(false);
    expect(out.approval).toBe(existing);    // same ref — nothing overwritten
    expect(out.token).toBe('T');
    expect(out.sentAt).toBe('s0');          // original sentAt preserved
    expect(out.approval.snapshot).toBe(snap); // NOT newSnap
  });
});
