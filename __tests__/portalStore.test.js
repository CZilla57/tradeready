// __tests__/portalStore.test.js
// Portal backend store is READ-ONLY (spec §2) and tenant-scoped: every
// jobs/invoices query carries BOTH user_id and customerId — the assertion
// that a portal token can never read across tenants lives here.

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-role-test';

const {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
} = require('../backend/lib/estimate/portalStore');

afterEach(() => { delete global.fetch; });

function okFetch(rows) {
  global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => rows });
}

describe('lookupCustomerByPortalToken', () => {
  it('filters by JSON-path token + enabled + not deleted and selects user_id,id,data', async () => {
    okFetch([{ user_id: 'u1', id: 'c1', data: { name: 'Dana' } }]);
    const row = await lookupCustomerByPortalToken('tok123');
    expect(row.id).toBe('c1');
    const url = global.fetch.mock.calls[0][0];
    expect(url).toContain('/rest/v1/customers');
    expect(url).toContain('data->portal->>token=eq.tok123');
    expect(url).toContain('data->portal->>enabled=eq.true');
    expect(url).toContain('deleted=eq.false');
    expect(url).toContain('select=user_id,id,data');
  });

  it('returns null when no row matches (unknown and disabled are indistinguishable)', async () => {
    okFetch([]);
    expect(await lookupCustomerByPortalToken('nope')).toBeNull();
  });

  it('throws on a non-ok response', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 500, text: async () => 'boom' });
    await expect(lookupCustomerByPortalToken('x')).rejects.toThrow('Supabase');
  });
});

describe('fetchBusinessName', () => {
  it('reads the settings row and returns businessName, empty-string fallback', async () => {
    okFetch([{ data: { businessName: 'Rivera Plumbing' } }]);
    expect(await fetchBusinessName('u1')).toBe('Rivera Plumbing');
    expect(global.fetch.mock.calls[0][0]).toContain('settings?user_id=eq.u1');
    okFetch([]);
    expect(await fetchBusinessName('u1')).toBe('');
  });
});

describe.each([
  ['fetchCustomerJobs', fetchCustomerJobs, 'jobs'],
  ['fetchCustomerInvoices', fetchCustomerInvoices, 'invoices'],
])('%s', (_name, fn, table) => {
  it('scopes by BOTH user_id and customerId, excludes deleted', async () => {
    okFetch([{ id: 'r1', data: {} }]);
    const rows = await fn('u1', 'c1');
    expect(rows).toHaveLength(1);
    const url = global.fetch.mock.calls[0][0];
    expect(url).toContain(`/rest/v1/${table}`);
    expect(url).toContain('user_id=eq.u1');
    expect(url).toContain('data->>customerId=eq.c1');
    expect(url).toContain('deleted=eq.false');
    expect(url).toContain('select=id,data');
  });
});
