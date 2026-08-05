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

const { planChangeOrderLink } = require('../backend/lib/estimate/createLink');

describe('planChangeOrderLink', () => {
  const mint = () => 'MINTED';
  const snap = { total: 850 };
  const cos = [
    { id: 'coA', title: 'Subfloor', amount: 850, createdAt: 'd' },
    { id: 'coB', title: 'Done', amount: 100, createdAt: 'd', manualDecision: { decision: 'approved', decidedAt: 'd' } },
  ];

  it('mints into the right CO and leaves the others untouched', () => {
    const out = planChangeOrderLink(cos, 'coA', snap, 's1', mint);
    expect(out.error).toBeUndefined();
    expect(out.changed).toBe(true);
    expect(out.token).toBe('MINTED');
    expect(out.changeOrders[0].approval).toEqual({ token: 'MINTED', sentAt: 's1', snapshot: snap });
    expect(out.changeOrders[1]).toBe(cos[1]);   // untouched reference
    expect(cos[0].approval).toBeUndefined();     // input not mutated
  });

  it('errors not-found for an unknown CO', () => {
    expect(planChangeOrderLink(cos, 'nope', snap, 's1', mint)).toEqual({ error: 'not-found' });
  });

  it('errors decided for a manually-decided CO', () => {
    expect(planChangeOrderLink(cos, 'coB', snap, 's1', mint)).toEqual({ error: 'decided' });
  });

  it('freezes once link-approved (planApprovalWrite semantics carry over)', () => {
    const approved = [{ id: 'coA', title: 'X', amount: 1, createdAt: 'd',
      approval: { token: 'T', sentAt: 's0', snapshot: snap, decision: 'approved' } }];
    const out = planChangeOrderLink(approved, 'coA', { total: 999 }, 's9', mint);
    expect(out.changed).toBe(false);
    expect(out.token).toBe('T');
    expect(out.changeOrders[0].approval.snapshot).toBe(snap); // NOT the new snapshot
  });

  it('handles a non-array changeOrders as not-found', () => {
    expect(planChangeOrderLink(undefined, 'coA', snap, 's1', mint)).toEqual({ error: 'not-found' });
  });
});
