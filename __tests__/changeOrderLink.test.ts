import { createChangeOrderLink } from "../utils/changeOrderLink";
import { loadJobs, saveJobs } from "../utils/storage";
import { supabase } from "../utils/supabase";
import type { Job, ChangeOrder } from "../types/models";

// Mock the storage + network edges; assert the orchestration order and the
// local mirror write (the estimateApprovalLink contract, minus status stamping).
jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(),
  saveJobs: jest.fn().mockResolvedValue(undefined),
}));
jest.mock("../utils/supabase", () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock("../utils/sync", () => ({ syncIfOnline: jest.fn().mockResolvedValue(undefined) }));
jest.mock("expo-constants", () => ({
  __esModule: true,
  default: { expoConfig: { extra: { backendUrl: "https://backend.test" } } },
}));

const co: ChangeOrder = { id: "coB", title: "Subfloor", amount: 200, createdAt: "d" };
const job = {
  id: "j1", customerName: "Dana", title: "Bath", estimateTotal: 2400,
  changeOrders: [co], status: "in_progress",
} as unknown as Job;
const customer = { id: "c1", name: "Dana R", email: "", phone: "", address: "", notes: "" };
const settings = { businessName: "Rivera Plumbing" } as never;

beforeEach(() => {
  jest.clearAllMocks();
  (loadJobs as jest.Mock).mockResolvedValue([job]);
  (supabase.auth.getSession as jest.Mock).mockResolvedValue({
    data: { session: { access_token: "JWT", user: { id: "u1" } } },
  });
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ url: "https://x/change.html?j=j1&co=coB&t=TOK", token: "TOK", sentAt: "S" }),
  }) as jest.Mock;
});

it("mints via create-link with changeOrderId and mirrors approval locally", async () => {
  const out = await createChangeOrderLink(job, co, customer as never, settings);
  expect(out.ok).toBe(true);
  const call = (global.fetch as jest.Mock).mock.calls[0];
  expect(call[0]).toBe("https://backend.test/api/estimate/create-link");
  const body = JSON.parse(call[1].body);
  expect(body.jobId).toBe("j1");
  expect(body.changeOrderId).toBe("coB");
  expect(body.snapshot.total).toBe(200);
  // local mirror: the CO gained approval {token, sentAt, snapshot}
  const savedJobs = (saveJobs as jest.Mock).mock.calls.at(-1)[0];
  const savedCo = savedJobs[0].changeOrders[0];
  expect(savedCo.approval.token).toBe("TOK");
  expect(savedCo.approval.sentAt).toBe("S");
});

it("returns a server failure without writing locally", async () => {
  (global.fetch as jest.Mock).mockResolvedValue({ ok: false, json: async () => ({ error: "nope" }) });
  const out = await createChangeOrderLink(job, co, customer as never, settings);
  expect(out.ok).toBe(false);
  expect(saveJobs).not.toHaveBeenCalled();
});

it("returns signed-out when there is no session", async () => {
  (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: null } });
  const out = await createChangeOrderLink(job, co, customer as never, settings);
  expect(out).toMatchObject({ ok: false, reason: "signed-out" });
});
