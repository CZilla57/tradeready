// __tests__/bookingNotifyCampaign.test.js
// Phase 33 (past-customer campaigns, spec §9.1): the Worker's owner alert for
// a booking that came in through one of the owner's campaign links. Both
// email variants gain one fixed plain-text line just before the closing line,
// only when the stored request carries a code. The line names no campaign
// (the server never resolves the code) and the code itself never reaches the
// email, the push or a log. The push body is unchanged.
//
// Targets the Worker copy. The dormant Vercel twin (backend/lib/booking/
// notifyOwner.js) is intentionally unchanged and stays covered by
// bookingNotify.test.js.

const { buildBookingEmail, notifyOwner } = require("../backend-workers/lib/booking/notifyOwner");

const CAMPAIGN_LINE = "Came in through one of your campaign links. Open TradeReady to see which one.";
const CODE = "vtpvxvr024h36h2n";
const QUOTE_CLOSING = "Open TradeReady to see the new lead in Jobs.";
const BOOKED_CLOSING = "The slot is held for them. Open TradeReady to see it on your calendar.";

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

const emailOf = (request) => buildBookingEmail({ to: "owner@example.com", request });
const linesOf = (request) => emailOf(request).text.split("\n");

describe("buildBookingEmail campaign line (Worker copy)", () => {
  it.each([
    ["quote request", quoteRequest, QUOTE_CLOSING],
    ["booked appointment", bookedRequest, BOOKED_CLOSING],
  ])("%s: the line sits just before the closing line when a code is present", (_label, make, closing) => {
    const lines = linesOf(make({ campaignCode: CODE }));
    expect(lines[lines.length - 1]).toBe(closing);
    expect(lines[lines.length - 2]).toBe(CAMPAIGN_LINE);
    expect(lines.filter((l) => l === CAMPAIGN_LINE)).toHaveLength(1);
  });

  it.each([
    ["quote request", quoteRequest],
    ["booked appointment", bookedRequest],
  ])("%s: everything but the inserted line is unchanged", (_label, make) => {
    const withCode = linesOf(make({ campaignCode: CODE }));
    const without = linesOf(make());
    expect(withCode.filter((l) => l !== CAMPAIGN_LINE)).toEqual(without);
    const a = emailOf(make({ campaignCode: CODE }));
    const b = emailOf(make());
    expect(Object.keys(a).sort()).toEqual(Object.keys(b).sort());
    expect(a.subject).toBe(b.subject);
    expect(a.from).toBe(b.from);
    expect(a.to).toBe(b.to);
  });

  it.each([
    ["absent", undefined],
    ["empty", ""],
    ["a non-string", 42],
    ["an object", { code: CODE }],
    ["null", null],
  ])("no line when the code is %s", (_label, campaignCode) => {
    const request = quoteRequest();
    if (campaignCode !== undefined) request.campaignCode = campaignCode;
    expect(linesOf(request)).not.toContain(CAMPAIGN_LINE);
    expect(linesOf(request)).toEqual(linesOf(quoteRequest()));
  });

  it("never echoes the code", () => {
    for (const make of [quoteRequest, bookedRequest]) {
      const email = emailOf(make({ campaignCode: CODE }));
      expect(JSON.stringify(email)).not.toContain(CODE);
    }
  });

  it("is plain text only, and the line is the fixed string whatever the stored value holds", () => {
    // The validator only ever stores a canonical code, but a hand-edited row
    // must not be able to put markup or header text into the alert.
    const hostile = "<script>alert(1)</script>\r\nBcc: attacker@example.com";
    const email = emailOf(quoteRequest({ campaignCode: hostile }));
    expect(Object.keys(email).sort()).toEqual(["from", "subject", "text", "to"]);
    expect(email).not.toHaveProperty("html");
    expect(email.text).toContain(CAMPAIGN_LINE);
    expect(email.text).not.toContain("<script>");
    expect(email.text).not.toContain("attacker@example.com");
    expect(email.subject).toBe("New quote request from Dana Rivers");
    expect(CAMPAIGN_LINE).toMatch(/^[A-Za-z .]+$/);
  });

  it("with a referral code too, the campaign line still sits just before the closing line", () => {
    // Phase 34 (feat/referrals) adds its own line in the same place. Merged,
    // the order is referral line, campaign line, closing line.
    const lines = linesOf(quoteRequest({ campaignCode: CODE, referralCode: "0123456789abcdef" }));
    expect(lines[lines.length - 1]).toBe(QUOTE_CLOSING);
    expect(lines[lines.length - 2]).toBe(CAMPAIGN_LINE);
    expect(lines.filter((l) => l === CAMPAIGN_LINE)).toHaveLength(1);
  });
});

describe("notifyOwner campaign handling (Worker copy)", () => {
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
    await notifyOwner(ENV, { userId: "u1", settingsData, request: make({ campaignCode: CODE }) });
    const without = mockBackend();
    await notifyOwner(ENV, { userId: "u1", settingsData, request: make() });

    expect(withCode.emails).toHaveLength(1);
    expect(withCode.emails[0].text).toContain(CAMPAIGN_LINE);
    expect(without.emails[0].text).not.toContain(CAMPAIGN_LINE);

    expect(withCode.pushes).toHaveLength(1);
    expect(withCode.pushes[0]).toEqual(without.pushes[0]);
    expect(JSON.stringify(withCode.pushes[0])).not.toContain(CODE);
    expect(JSON.stringify(withCode.emails[0])).not.toContain(CODE);

    for (const spy of logSpies) {
      for (const args of spy.mock.calls) expect(args.map(String).join(" ")).not.toContain(CODE);
    }
  });

  it("an email failure is still swallowed, never logs the code, and the push still goes out", async () => {
    const errors = jest.spyOn(console, "error").mockImplementation(() => {});
    const pushes = [];
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@example.com" });
      if (u.includes("api.resend.com")) return jsonRes({ message: "down" }, 500);
      if (u.includes("exp.host")) { pushes.push(JSON.parse(init.body)); return jsonRes({}); }
      return jsonRes([]);
    });
    await expect(
      notifyOwner(ENV, { userId: "u1", settingsData, request: quoteRequest({ campaignCode: CODE }) })
    ).resolves.toBeUndefined();
    expect(pushes).toHaveLength(1);
    expect(errors).toHaveBeenCalled();
    for (const args of errors.mock.calls) expect(args.map(String).join(" ")).not.toContain(CODE);
  });
});
