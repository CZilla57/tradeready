// __tests__/portalStoreWorkers.test.js
// Phase 12A: first direct coverage of the WORKERS portal store (v1 tests pin
// only the Vercel twin). The URL strings ARE the tenant-isolation boundary —
// every jobs/invoices/bookingRequests query must filter by BOTH user_id and
// customerId, and the token lookup must require enabled=true.

const store = require("../backend-workers/lib/estimate/portalStore.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };

function mockFetch(rows = []) {
  global.fetch = jest.fn(async () => ({ ok: true, status: 200, json: async () => rows, text: async () => "[]" }));
  return global.fetch;
}

afterEach(() => { delete global.fetch; });

test("token lookup filters token + enabled + not-deleted and uses the service role", async () => {
  const f = mockFetch([{ user_id: "u1", id: "c1", data: {} }]);
  const row = await store.lookupCustomerByPortalToken(ENV, "tok");
  expect(row).toEqual({ user_id: "u1", id: "c1", data: {} });
  const [url, init] = f.mock.calls[0];
  expect(url).toContain("customers?data->portal->>token=eq.tok");
  expect(url).toContain("data->portal->>enabled=eq.true");
  expect(url).toContain("deleted=eq.false");
  expect(init.headers.Authorization).toBe("Bearer srk");
});

test("unknown token resolves null (no oracle)", async () => {
  mockFetch([]);
  expect(await store.lookupCustomerByPortalToken(ENV, "nope")).toBeNull();
});

test.each([
  ["fetchCustomerJobs", "jobs"],
  ["fetchCustomerInvoices", "invoices"],
  ["fetchCustomerBookingRequests", "bookingRequests"],
])("%s scopes by BOTH user_id and customerId", async (fn, table) => {
  const f = mockFetch([]);
  await store[fn](ENV, "u1", "c1");
  const url = String(f.mock.calls[0][0]);
  expect(url).toContain(`${table}?user_id=eq.u1`);
  expect(url).toContain(
    table === "bookingRequests" ? "data->>convertedCustomerId=eq.c1" : "data->>customerId=eq.c1"
  );
  expect(url).toContain("deleted=eq.false");
});

test("business name read selects only data", async () => {
  const f = mockFetch([{ data: { businessName: "Ace" } }]);
  expect(await store.fetchBusinessName(ENV, "u1")).toBe("Ace");
  expect(String(f.mock.calls[0][0])).toContain("settings?user_id=eq.u1&select=data");
});

describe("fetchCustomerJobPhotos (Phase 12B)", () => {
  test("scopes by user_id and an explicit quoted job-id in-list", async () => {
    const f = mockFetch([]);
    await store.fetchCustomerJobPhotos(ENV, "u1", ["j1", "j2"]);
    const url = String(f.mock.calls[0][0]);
    expect(url).toContain("jobPhotos?user_id=eq.u1");
    expect(url).toContain('data->>jobId=in.("j1","j2")');
    expect(url).toContain("deleted=eq.false");
  });

  test("empty job list makes zero network calls", async () => {
    const f = mockFetch([]);
    expect(await store.fetchCustomerJobPhotos(ENV, "u1", [])).toEqual([]);
    expect(f).not.toHaveBeenCalled();
  });

  test("hostile characters in ids are stripped from the in-list", async () => {
    const f = mockFetch([]);
    await store.fetchCustomerJobPhotos(ENV, "u1", ['j1"),(select', "j2"]);
    const url = String(f.mock.calls[0][0]);
    expect(url).toContain('in.("j1select","j2")');
  });
});
