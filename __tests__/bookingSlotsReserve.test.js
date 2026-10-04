// __tests__/bookingSlotsReserve.test.js
// Phase 11 C1/C2: the Workers slots + reserve handler cores
// (backend-workers/lib/booking/{slots,reserve}.js). Everything network is a
// mocked global.fetch keyed by URL; time and randomness are injected so the
// cores stay deterministic. The atomic-claim story: Postgres's partial
// unique index answers a racing INSERT with 409/23505 → the API returns
// 409 slot_taken and inserts NO request row.

const { slotsCore } = require("../backend-workers/lib/booking/slots.js");
const { reserveCore } = require("../backend-workers/lib/booking/reserve.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
// 2026-08-10T12:00Z = Mon Aug 10, 07:00 in America/Chicago
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const RAND = "abc123";
const MANAGE = "m".repeat(48);

const enabledSettings = (over = {}) => ({
  businessName: "Rivera Plumbing",
  pushToken: { token: "ExponentPushToken[xyz]", platform: "ios", updatedAt: "2026-08-01" },
  schedule: {
    timeZone: "America/Chicago",
    slotLeadHours: 0,
    bookableSlotsEnabled: true,
    ...over,
  },
});

function jsonRes(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

/** URL-dispatching Supabase/Resend/Expo mock. Every branch overridable. */
function mockBackend({
  settingsRows = [],
  jobsRows = [],
  reservationRows = [],
  reserveInsertStatus = 201,
  requestInsertStatus = 201,
} = {}) {
  const calls = { reservePosts: [], requestPosts: [], deletes: [], pushPosts: [] };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    if (u.includes("/rest/v1/settings")) return jsonRes(settingsRows);
    if (u.includes("/rest/v1/jobs")) return jsonRes(jobsRows);
    if (u.includes("/rest/v1/booking_reservations")) {
      if (method === "POST") {
        calls.reservePosts.push(JSON.parse(init.body));
        return jsonRes({}, reserveInsertStatus);
      }
      if (method === "DELETE") {
        calls.deletes.push(u);
        return jsonRes({}, 204);
      }
      return jsonRes(reservationRows);
    }
    if (u.includes("/rest/v1/bookingRequests")) {
      calls.requestPosts.push(JSON.parse(init.body));
      return jsonRes({}, requestInsertStatus);
    }
    if (u.includes("exp.host")) {
      calls.pushPosts.push(JSON.parse(init.body));
      return jsonRes({});
    }
    if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@x.com" });
    if (u.includes("api.resend.com")) return jsonRes({});
    return jsonRes([]);
  });
  return calls;
}

const settingsRow = (data) => [{ user_id: "u1", data }];

afterEach(() => {
  delete global.fetch;
});

describe("slotsCore", () => {
  test("missing token → 400", async () => {
    mockBackend();
    expect((await slotsCore(ENV, { token: undefined, nowMs: NOW_MS })).status).toBe(400);
  });

  test("unknown token → 404, no oracle", async () => {
    mockBackend({ settingsRows: [] });
    const r = await slotsCore(ENV, { token: "t".repeat(48), nowMs: NOW_MS });
    expect(r.status).toBe(404);
    expect(r.body).toEqual({ error: "This link is invalid." });
  });

  test("link enabled but slot booking off (or no timezone) → same 404", async () => {
    mockBackend({
      settingsRows: settingsRow(enabledSettings({ bookableSlotsEnabled: false })),
    });
    expect((await slotsCore(ENV, { token: "t".repeat(48), nowMs: NOW_MS })).status).toBe(404);

    mockBackend({ settingsRows: settingsRow(enabledSettings({ timeZone: undefined })) });
    expect((await slotsCore(ENV, { token: "t".repeat(48), nowMs: NOW_MS })).status).toBe(404);
  });

  test("returns businessName + timeZone + UTC-resolved slots, nothing else", async () => {
    mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const r = await slotsCore(ENV, { token: "t".repeat(48), nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["businessName", "slots", "timeZone"]);
    expect(r.body.businessName).toBe("Rivera Plumbing");
    expect(r.body.timeZone).toBe("America/Chicago");
    // Monday 07:00 local, lead 0 → first offer 08:00 CDT = 13:00Z
    expect(r.body.slots[0]).toEqual({
      date: "2026-08-10",
      start: "08:00",
      end: "09:00",
      startUtc: "2026-08-10T13:00:00.000Z",
      endUtc: "2026-08-10T14:00:00.000Z",
    });
  });

  test("jobs and active reservations subtract from the offers", async () => {
    mockBackend({
      settingsRows: settingsRow(enabledSettings()),
      jobsRows: [
        {
          data: {
            id: "j1",
            status: "scheduled",
            scheduledDate: "2026-08-10",
            scheduledStartTime: "08:00",
            scheduledEndTime: "10:00",
            laborHours: 2,
          },
        },
      ],
      reservationRows: [
        { slot_date: "2026-08-10", slot_start: "10:00", slot_end: "12:00" },
      ],
    });
    const r = await slotsCore(ENV, { token: "t".repeat(48), nowMs: NOW_MS });
    const monday = r.body.slots.filter((s) => s.date === "2026-08-10");
    expect(monday[0].start).toBe("12:00");
  });

  test("database failure → 500", async () => {
    mockBackend();
    global.fetch = jest.fn(async () => jsonRes({ boom: true }, 500));
    expect((await slotsCore(ENV, { token: "t".repeat(48), nowMs: NOW_MS })).status).toBe(500);
  });
});

const reserveBody = (over = {}) => ({
  b: "t".repeat(48),
  slot: { date: "2026-08-10", start: "08:00" },
  name: "Dana Fox",
  phone: "555-0100",
  email: "dana@x.com",
  address: "12 Elm",
  details: "Water heater replacement",
  ...over,
});

const runReserve = (body) =>
  reserveCore(ENV, { body, nowMs: NOW_MS, randHex: RAND, manageToken: MANAGE });

describe("reserveCore", () => {
  test("honeypot → fake success, nothing written", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const r = await runReserve(reserveBody({ website: "spam.biz" }));
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true });
    expect(calls.reservePosts).toHaveLength(0);
    expect(calls.requestPosts).toHaveLength(0);
  });

  test("malformed slot or failed contact validation → 400", async () => {
    mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    expect((await runReserve(reserveBody({ slot: { date: "soon", start: "8" } }))).status).toBe(400);
    expect((await runReserve(reserveBody({ name: "" }))).status).toBe(400);
  });

  test("unknown token or slots-off both → 404", async () => {
    mockBackend({ settingsRows: [] });
    expect((await runReserve(reserveBody())).status).toBe(404);
    mockBackend({ settingsRows: settingsRow(enabledSettings({ bookableSlotsEnabled: false })) });
    expect((await runReserve(reserveBody())).status).toBe(404);
  });

  test("a slot outside current availability → 409 slot_taken, nothing written", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const r = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "06:00" } }));
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_taken" });
    expect(calls.reservePosts).toHaveLength(0);
  });

  test("happy path: atomic reservation + booked request + manage token + owner push", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);
    expect(r.body.manageToken).toBe(MANAGE);
    expect(r.body.slot.startUtc).toBe("2026-08-10T13:00:00.000Z");

    expect(calls.reservePosts).toHaveLength(1);
    const resv = calls.reservePosts[0];
    expect(resv).toMatchObject({
      id: `rv${NOW_MS}_${RAND}`,
      user_id: "u1",
      request_id: `bk${NOW_MS}_${RAND}`,
      slot_date: "2026-08-10",
      slot_start: "08:00",
      slot_end: "09:00",
      slot_start_utc: "2026-08-10T13:00:00.000Z",
      slot_end_utc: "2026-08-10T14:00:00.000Z",
      status: "booked",
    });

    expect(calls.requestPosts).toHaveLength(1);
    const req = calls.requestPosts[0].data;
    expect(req).toMatchObject({
      id: `bk${NOW_MS}_${RAND}`,
      status: "booked",
      kind: "booked",
      name: "Dana Fox",
      manageToken: MANAGE,
    });
    expect(req.slot).toEqual({
      date: "2026-08-10",
      start: "08:00",
      end: "09:00",
      timeZone: "America/Chicago",
      startUtc: "2026-08-10T13:00:00.000Z",
      endUtc: "2026-08-10T14:00:00.000Z",
    });
    expect(req.history).toEqual([
      { at: new Date(NOW_MS).toISOString(), actor: "customer", event: "booked" },
    ]);

    expect(calls.pushPosts).toHaveLength(1);
    expect(calls.pushPosts[0].title).toBe("New booked appointment");
    expect(calls.pushPosts[0].data).toEqual({ type: "booking_request" });
  });

  test("leadSource from the booking page lands in the stored request blob", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const r = await runReserve(reserveBody({ leadSource: "  nextdoor " }));
    expect(r.status).toBe(200);
    expect(calls.requestPosts).toHaveLength(1);
    expect(calls.requestPosts[0].data).toMatchObject({
      id: `bk${NOW_MS}_${RAND}`,
      kind: "booked",
      name: "Dana Fox",
      leadSource: "nextdoor",
    });
  });

  test("a missing or unusable leadSource leaves no key on the stored request and never fails the booking", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    expect((await runReserve(reserveBody())).status).toBe(200);
    expect((await runReserve(reserveBody({ leadSource: { src: "nextdoor" } }))).status).toBe(200);
    expect(calls.requestPosts).toHaveLength(2);
    for (const post of calls.requestPosts) {
      expect(post.data).not.toHaveProperty("leadSource");
    }
  });

  test("unique-index conflict (racing customer) → 409 slot_taken, no request row", async () => {
    const calls = mockBackend({
      settingsRows: settingsRow(enabledSettings()),
      reserveInsertStatus: 409,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_taken" });
    expect(calls.requestPosts).toHaveLength(0);
  });

  test("request-row failure compensates by releasing the reservation → 500", async () => {
    const calls = mockBackend({
      settingsRows: settingsRow(enabledSettings()),
      requestInsertStatus: 500,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(500);
    expect(calls.deletes).toHaveLength(1);
    expect(calls.deletes[0]).toContain(`id=eq.rv${NOW_MS}_${RAND}`);
  });

  // Phase 33: the booking page's ?c= campaign code rides the same spread.
  // These sit at the end of the block, apart from Phase 34's referral cases,
  // so the two branches merge without touching each other's lines.
  test("campaignCode from the booking page lands lowercased in the stored request blob", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const r = await runReserve(reserveBody({ campaignCode: " VTPVXVR024H36H2N ", leadSource: "nextdoor" }));
    expect(r.status).toBe(200);
    expect(calls.requestPosts).toHaveLength(1);
    expect(calls.requestPosts[0].data).toMatchObject({
      id: `bk${NOW_MS}_${RAND}`,
      kind: "booked",
      name: "Dana Fox",
      leadSource: "nextdoor",
      campaignCode: "vtpvxvr024h36h2n",
    });
    expect(calls.reservePosts).toHaveLength(1);
    expect(calls.reservePosts[0]).not.toHaveProperty("campaignCode");
  });

  test("a missing or garbage campaignCode leaves no key on the stored request and never fails the booking", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const bad = [undefined, "0123456789abcdeu", "0123456789abcde", "K123456789abcdef", "<i>x</i>", 42, { $ne: "" }, ["0123456789abcdef"], null];
    for (const campaignCode of bad) {
      const body = campaignCode === undefined ? reserveBody() : reserveBody({ campaignCode });
      expect((await runReserve(body)).status).toBe(200);
    }
    expect(calls.requestPosts).toHaveLength(bad.length);
    for (const post of calls.requestPosts) {
      expect(post.data).not.toHaveProperty("campaignCode");
    }
  });

  test("valid, unknown, malformed and absent campaign codes get identical reserve responses (no oracle)", async () => {
    const bodies = [
      reserveBody({ campaignCode: "0123456789abcdef" }),
      reserveBody({ campaignCode: "zzzzzzzzzzzzzzzz" }),
      reserveBody({ campaignCode: "not-a-code" }),
      reserveBody(),
    ];
    const seen = [];
    for (const body of bodies) {
      mockBackend({ settingsRows: settingsRow(enabledSettings()) });
      seen.push(JSON.stringify(await runReserve(body)));
    }
    expect(new Set(seen).size).toBe(1);
  });

  test("on the atomic claim RPC path the campaign code rides in p_request, never in p_reservation", async () => {
    mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const fallback = global.fetch;
    const rpcBodies = [];
    global.fetch = jest.fn(async (url, init = {}) => {
      if (String(url).includes("/rest/v1/rpc/claim_booking_slot")) {
        rpcBodies.push(JSON.parse(init.body));
        return jsonRes({ ok: true });
      }
      return fallback(url, init);
    });
    const r = await runReserve(reserveBody({ campaignCode: "0123456789ABCDEF" }));
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["manageToken", "ok", "slot"]);
    expect(rpcBodies).toHaveLength(1);
    expect(rpcBodies[0].p_request.campaignCode).toBe("0123456789abcdef");
    expect(rpcBodies[0].p_reservation).not.toHaveProperty("campaignCode");
  });

  test("a referral code beside it never changes the stored campaign code", async () => {
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    for (const referralCode of ["vtpvxvr024h36h2n", "garbage", 42]) {
      expect((await runReserve(reserveBody({ campaignCode: "0123456789ABCDEF", referralCode }))).status).toBe(200);
    }
    expect(calls.requestPosts).toHaveLength(3);
    for (const post of calls.requestPosts) expect(post.data.campaignCode).toBe("0123456789abcdef");
  });

  test("the owner email gains the campaign line; the push and the response never carry the code", async () => {
    const code = "vtpvxvr024h36h2n";
    const line = "Came in through one of your campaign links. Open TradeReady to see which one.";
    const env = { ...ENV, RESEND_API_KEY: "resend-test" };
    const run = async (over) => {
      const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
      const fallback = global.fetch;
      const emails = [];
      global.fetch = jest.fn(async (url, init = {}) => {
        if (String(url).includes("api.resend.com")) emails.push(JSON.parse(init.body));
        return fallback(url, init);
      });
      const r = await reserveCore(env, { body: reserveBody(over), nowMs: NOW_MS, randHex: RAND, manageToken: MANAGE });
      return { r, emails, pushes: calls.pushPosts };
    };
    const withCode = await run({ campaignCode: code });
    const without = await run({});
    expect(withCode.r).toEqual(without.r);
    expect(JSON.stringify(withCode.r)).not.toContain(code);
    expect(withCode.emails).toHaveLength(1);
    const lines = withCode.emails[0].text.split("\n");
    expect(lines[lines.length - 2]).toBe(line);
    expect(JSON.stringify(withCode.emails[0])).not.toContain(code);
    expect(without.emails[0].text).not.toContain(line);
    expect(withCode.pushes).toEqual(without.pushes);
  });
});
