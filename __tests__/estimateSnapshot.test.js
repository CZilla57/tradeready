const { buildEstimateSnapshot } = require('../utils/estimateSnapshot');

// estimateTotal is deliberately labor + material (300 + 20 = 320) with no slack,
// so the overhead line (a residual: estimateTotal - laborCost - materialCost in
// computeEstimateBreakdown) comes out to exactly 0 and is omitted — see the
// second test below.
const job = {
  title: 'Kitchen sink', customerName: 'Sam', estimateTotal: 320,
  laborHours: 4, laborRate: 75, materials: [{ name: 'trap', quantity: 1, unitCost: 20 }],
  materialMarkup: 0, overhead: 0, margin: 0,
};
const customer = { name: 'Sam Doe' };
const settings = { businessName: 'Ace Plumbing' };

describe('buildEstimateSnapshot', () => {
  it('captures business, customer, title, total and a labor line', () => {
    const snap = buildEstimateSnapshot(job, customer, settings);
    expect(snap.businessName).toBe('Ace Plumbing');
    expect(snap.customerName).toBe('Sam Doe');
    expect(snap.jobTitle).toBe('Kitchen sink');
    expect(snap.total).toBe(320);
    expect(snap.currency).toBe('USD');
    expect(snap.lineItems.find((l) => l.label.toLowerCase().includes('labor'))).toBeTruthy();
  });

  it('includes a finite materials line and omits overhead when overhead is 0', () => {
    const snap = buildEstimateSnapshot(job, customer, settings);
    const mat = snap.lineItems.find((l) => l.label.toLowerCase().includes('material'));
    expect(mat).toBeTruthy();
    expect(Number.isFinite(mat.amount)).toBe(true);
    expect(mat.amount).toBe(20);
    expect(snap.lineItems.some((l) => l.label.toLowerCase().includes('overhead'))).toBe(false);
    for (const li of snap.lineItems) expect(Number.isFinite(li.amount)).toBe(true);
  });
});
