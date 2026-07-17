const { buildEstimateSnapshot } = require('../utils/estimateSnapshot');

const job = {
  title: 'Kitchen sink', customerName: 'Sam', estimateTotal: 500,
  laborHours: 4, laborRate: 75, materials: [{ name: 'trap', cost: 20, qty: 1 }],
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
    expect(snap.total).toBe(500);
    expect(snap.currency).toBe('USD');
    expect(snap.lineItems.find((l) => l.label.toLowerCase().includes('labor'))).toBeTruthy();
  });
});
