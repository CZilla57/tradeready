// The app-side respond wrapper (Phase 11 D4) mirrors mintBookingToken's
// discriminated-result shape; Today's booking rows own presentation.

import { respondToBooking } from "../utils/bookingRespond";
import { supabase } from "../utils/supabase";

jest.mock("../utils/supabase", () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock("expo-constants", () => ({
  expoConfig: { extra: { backendUrl: "https://backend.unit.test", eas: { projectId: "proj" } } },
}));

const getSession = supabase.auth.getSession as jest.Mock;

afterEach(() => {
  jest.clearAllMocks();
  (global as { fetch?: unknown }).fetch = undefined;
});

describe("respondToBooking", () => {
  it("returns signed-out without a session", async () => {
    getSession.mockResolvedValue({ data: { session: null } });
    expect(await respondToBooking("bk1", "decline")).toMatchObject({ ok: false, reason: "signed-out" });
  });

  it("POSTs the action with the JWT and returns the new status", async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: "jwt1", user: { id: "u1" } } } });
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ ok: true, status: "confirmed" }) }) as never;
    const out = await respondToBooking("bk1", "resolve_reschedule");
    expect(out).toEqual({ ok: true, status: "confirmed" });
    const [url, opts] = (global.fetch as jest.Mock).mock.calls[0];
    expect(url).toBe("https://backend.unit.test/api/booking/respond");
    expect((opts.headers as Record<string, string>).Authorization).toBe("Bearer jwt1");
    expect(JSON.parse(opts.body as string)).toEqual({ requestId: "bk1", action: "resolve_reschedule" });
  });

  it("maps server and network failures", async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: "jwt1", user: { id: "u1" } } } });
    global.fetch = jest.fn().mockResolvedValue({ ok: false, json: async () => ({ error: "invalid_state" }) }) as never;
    expect(await respondToBooking("bk1", "decline")).toMatchObject({ ok: false, reason: "server", message: "invalid_state" });

    global.fetch = jest.fn().mockRejectedValue(new Error("offline")) as never;
    expect(await respondToBooking("bk1", "decline")).toMatchObject({ ok: false, reason: "network" });
  });
});
