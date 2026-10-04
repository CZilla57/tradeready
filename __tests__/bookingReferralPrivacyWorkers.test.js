// __tests__/bookingReferralPrivacyWorkers.test.js
// Phase 34 (referral program) privacy pins, spec §0 and §6, on the Worker:
// - a portal request is a server-built whitelist, so a referral code sent
//   with it is never stored and never reaches the owner email;
// - the customer manage view answers only businessName/status/slot, so a
//   stored code is never echoed back to the person who booked;
// - the legacy (pre-RPC) manage write spreads the stored blob, so the code
//   survives a customer confirm/cancel for the owner's device to resolve.

const { portalRequestCore } = require("../backend-workers/lib/estimate/portalRequest.js");
const { manageViewCore, manageActionCore } = require("../backend-workers/lib/booking/manage.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk", RESEND_API_KEY: "resend-test" };
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const CODE = "0123456789abcdef";
const REFERRAL_LINE = "Came in through a customer's referral link — open TradeReady to see who referred them.";

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe("portal requests never carry a referral code", () => {
  const PORTAL_TOKEN = "p".repeat(48);
  const customer = { user_id: "u1", id: "c1", data: { name: "Dana Fox", phone: "555-0100", email: "dana@x.com", address: "12 Elm" } };

  function mockBackend() {
    const calls = { inserts: [], emails: [] };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/customers")) return jsonRes([customer]);
      if (u.includes("/rest/v1/settings")) return jsonRes([{ data: { businessName: "Ace" } }]);
      if (u.includes("/rest/v1/portal_access_log")) return method === "POST" ? jsonRes([], 201) : jsonRes([]);
      if (u.includes("/rest/v1/bookingRequests") && method === "POST") {
        calls.inserts.push(JSON.parse(init.body));
        return jsonRes([], 201);
      }
      if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@x.com" });
      if (u.includes("api.resend.com")) { calls.emails.push(JSON.parse(init.body)); return jsonRes({}); }
      return jsonRes([]);
    });
    return calls;
  }

  test("a followup sent with referralCode / r stores neither, and the owner email has no referral line", async () => {
    const calls = mockBackend();
    const out = await portalRequestCore(ENV, {
      body: { p: PORTAL_TOKEN, kind: "followup", note: "Need the fence painted too", requestKey: "aaaabbbbcccc", referralCode: CODE, r: CODE },
      ip: "1.1.1.1",
      nowMs: NOW_MS,
    });
    expect(out).toEqual({ status: 200, json: { ok: true } });
    expect(calls.inserts).toHaveLength(1);
    expect(calls.inserts[0].data).not.toHaveProperty("referralCode");
    expect(calls.inserts[0].data).not.toHaveProperty("r");
    expect(calls.inserts[0].data.source).toBe("portal");
    expect(JSON.stringify(calls.inserts[0])).not.toContain(CODE);
    expect(calls.emails).toHaveLength(1);
    expect(calls.emails[0].text).not.toContain(REFERRAL_LINE);
  });
});

describe("the manage page never sees the code, and the legacy write keeps it", () => {
  const MANAGE = "m".repeat(48);
  const bookedData = () => ({
    id: "bk1_aa",
    status: "booked",
    kind: "booked",
    name: "Dana Fox",
    phone: "555-0100",
    email: "dana@x.com",
    address: "12 Elm",
    details: "Water heater",
    preferredTiming: "",
    referralCode: CODE,
    leadSource: "nextdoor",
    createdAt: "2026-08-07T15:00:00.000Z",
    convertedJobId: "jbk_bk1_aa",
    slot: { date: "2026-08-12", start: "09:00", end: "10:00", timeZone: "America/Phoenix", startUtc: "2026-08-12T16:00:00.000Z", endUtc: "2026-08-12T17:00:00.000Z" },
    manageToken: MANAGE,
    history: [{ at: "2026-08-07T15:00:00.000Z", actor: "customer", event: "booked" }],
  });

  function mockBackend() {
    const calls = { patches: [] };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/rpc/")) return jsonRes({ message: "function not found" }, 404);
      if (u.includes("/rest/v1/bookingRequests")) {
        if (method === "PATCH") { calls.patches.push(JSON.parse(init.body)); return jsonRes({}, 204); }
        const data = bookedData();
        return jsonRes([{ id: data.id, user_id: "u1", data }]);
      }
      if (u.includes("/rest/v1/booking_reservations")) return jsonRes({}, 204);
      if (u.includes("/rest/v1/settings")) return jsonRes([{ user_id: "u1", data: { businessName: "ABC Electrical" } }]);
      if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@x.com" });
      return jsonRes({});
    });
    return calls;
  }

  test("manage view answers only businessName, status and slot", async () => {
    mockBackend();
    const r = await manageViewCore(ENV, { token: MANAGE });
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["businessName", "slot", "status"]);
    expect(JSON.stringify(r.body)).not.toContain(CODE);
  });

  test("a legacy confirm and cancel keep referralCode on the stored blob, and the response never echoes it", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    for (const action of ["confirm", "cancel"]) {
      const calls = mockBackend();
      const r = await manageActionCore(ENV, { token: MANAGE, action, nowMs: NOW_MS });
      expect(r.status).toBe(200);
      expect(JSON.stringify(r.body)).not.toContain(CODE);
      expect(calls.patches).toHaveLength(1);
      expect(calls.patches[0].data.referralCode).toBe(CODE);
      expect(calls.patches[0].data.leadSource).toBe("nextdoor");
    }
  });
});
