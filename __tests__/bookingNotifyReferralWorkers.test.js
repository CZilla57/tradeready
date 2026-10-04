// __tests__/bookingNotifyReferralWorkers.test.js
// Phase 34 (referral program): the Worker's owner alert for a booking that
// came in through a customer's referral link (spec §3, §6). Both email
// variants gain one line just before the closing line, only when the stored
// request carries a code. The line names nobody (the server never resolves
// the code) and the code itself never reaches the email, the push or a log.
// The push body is unchanged.
//
// Targets the Worker copy. The dormant Vercel twin (backend/lib/booking/
// notifyOwner.js) is intentionally unchanged and stays covered by
// bookingNotify.test.js.

const { buildBookingEmail, notifyOwner } = require("../backend-workers/lib/booking/notifyOwner");

const REFERRAL_LINE = "Came in through a customer's referral link — open TradeReady to see who referred them.";
const CODE = "vtpvxvr024h36h2n";

const quoteRequest = (over = {}) => ({
  id: "bk1_x", status: "new", name: "Dana Rivers", phone: "555-0142",
  email: "dana@example.com", address: "12 Elm St",
  details: "Water heater is leaking", preferredTiming: "Mornings",
  createdAt: "2026-08-04T15:00:00.000Z",
  ...over,
});
const bookedRequest = (over = {}) =>
  quoteRequest({
    status: "booked",
    kind: "booked",
    slot: { date: "2026-08-10", start: "08:00", end: "09:00", timeZone: "America/Chicago" },
    ...over,
  });

const linesOf = (request) => buildBookingEmail({ to: "owner@example.com", request }).text.split("\n");

describe("buildBookingEmail referral line (Worker copy)", () => {
  it.each([
    ["quote request", quoteRequest, "Open TradeReady to see the new lead in Jobs."],
    ["booked appointment", bookedRequest, "The slot is held for them. Open TradeReady to see it on your calendar."],
  ])("%s: the line sits just before the closing line when a code is present", (_label, make, closing) => {
    const lines = linesOf(make({ referralCode: CODE }));
    expect(lines[lines.length - 1]).toBe(closing);
    expect(lines[lines.length - 2]).toBe(REFERRAL_LINE);
    expect(lines.filter((l) => l === REFERRAL_LINE)).toHaveLength(1);
  });

  it.each([
    ["quote request", quoteRequest],
    ["booked appointment", bookedRequest],
  ])("%s: everything but the inserted line is unchanged", (_label, make) => {
    const withCode = linesOf(make({ referralCode: CODE }));
    const without = linesOf(make());
    expect(withCode.filter((l) => l !== REFERRAL_LINE)).toEqual(without);
    const a = buildBookingEmail({ to: "o@x.com", request: make({ referralCode: CODE }) });
    const b = buildBookingEmail({ to: "o@x.com", request: make() });
    expect(a.subject).toBe(b.subject);
    expect(a.from).toBe(b.from);
    expect(a.to).toBe(b.to);
  });

  it.each([
    ["absent", undefined],
    ["empty", ""],
    ["a non-string", 42],
    ["null", null],
  ])("no line when the code is %s", (_label, referralCode) => {
    const request = quoteRequest();
    if (referralCode !== undefined) request.referralCode = referralCode;
    expect(linesOf(request)).not.toContain(REFERRAL_LINE);
    expect(linesOf(request)).toEqual(linesOf(quoteRequest()));
  });

  it("never echoes the code", () => {
    for (const make of [quoteRequest, bookedRequest]) {
      const email = buildBookingEmail({ to: "o@x.com", request: make({ referralCode: CODE }) });
      expect(JSON.stringify(email)).not.toContain(CODE);
    }
  });
});

describe("notifyOwner referral handling (Worker copy)", () => {
  const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk", RESEND_API_KEY: "resend-test" };
  const settingsData = { pushToken: { token: "ExponentPushToken[x]" } };

  function jsonRes(body, status = 200) {
    return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
  }
  function mockBackend() {
    const calls = { emails: [], pushes: [] };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@example.com" });
      if (u.includes("api.resend.com")) { calls.emails.push(JSON.parse(init.body)); return jsonRes({}); }
      if (u.includes("exp.host")) { calls.pushes.push(JSON.parse(init.body)); return jsonRes({}); }
      return jsonRes([]);
    });
    return calls;
  }

  afterEach(() => {
    delete global.fetch;
    jest.restoreAllMocks();
  });

  it.each([
    ["quote request", quoteRequest],
    ["booked appointment", bookedRequest],
  ])("%s: the email carries the line and the push body is unchanged", async (_label, make) => {
    const logSpies = ["log", "warn", "error"].map((level) => jest.spyOn(console, level).mockImplementation(() => {}));

    const withCode = mockBackend();
    await notifyOwner(ENV, { userId: "u1", settingsData, request: make({ referralCode: CODE }) });
    const without = mockBackend();
    await notifyOwner(ENV, { userId: "u1", settingsData, request: make() });

    expect(withCode.emails).toHaveLength(1);
    expect(withCode.emails[0].text).toContain(REFERRAL_LINE);
    expect(without.emails[0].text).not.toContain(REFERRAL_LINE);

    expect(withCode.pushes).toHaveLength(1);
    expect(withCode.pushes[0]).toEqual(without.pushes[0]);
    expect(JSON.stringify(withCode.pushes[0])).not.toContain(CODE);
    expect(JSON.stringify(withCode.emails[0])).not.toContain(CODE);

    for (const spy of logSpies) {
      for (const args of spy.mock.calls) expect(args.map(String).join(" ")).not.toContain(CODE);
    }
  });

  it("an email failure is still swallowed and the push still goes out", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    const pushes = [];
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@example.com" });
      if (u.includes("api.resend.com")) return jsonRes({ message: "down" }, 500);
      if (u.includes("exp.host")) { pushes.push(JSON.parse(init.body)); return jsonRes({}); }
      return jsonRes([]);
    });
    await expect(
      notifyOwner(ENV, { userId: "u1", settingsData, request: quoteRequest({ referralCode: CODE }) })
    ).resolves.toBeUndefined();
    expect(pushes).toHaveLength(1);
  });
});
