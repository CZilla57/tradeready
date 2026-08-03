// __tests__/widgetBridge.test.js
// The JS half of the App Group widget bridge (utils/widgetBridge.ts):
//   1. selectNextJob — earliest upcoming schedule wins; done/archived/past
//      jobs never surface; the projection carries ONLY the fields the widget
//      displays (minimal-PII invariant).
//   2. selectActiveTimer — the running clock-in session, latest start wins.
//   3. buildWidgetSnapshot — outstanding total matches summarizeInvoices.
//   4. refresh/clear are strict no-ops without the native module (Expo Go,
//      Android, pre-widget builds) and never throw from a save path.

import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  selectNextJob,
  selectActiveTimer,
  buildWidgetSnapshot,
  refreshWidgetSnapshot,
  clearWidgetSnapshot,
  WIDGET_SNAPSHOT_KEY,
} from "../utils/widgetBridge";
import { KEYS } from "../utils/storage/keys";

const mockBridge = { setSharedItem: jest.fn(), clearShared: jest.fn() };
let mockBridgeAvailable = true;
jest.mock("expo-modules-core", () => ({
  requireOptionalNativeModule: jest.fn(() => (mockBridgeAvailable ? mockBridge : null)),
}));

// Local-noon construction keeps "today" unambiguous in any timezone (the
// date-mock TZ trap from tradeready-validation-and-diagnostics).
const NOW = new Date(2026, 7, 3, 12, 0, 0).getTime(); // Mon 2026-08-03 12:00 local

const job = (over = {}) => ({
  id: "j1",
  customerId: "c1",
  customerName: "Alice Johnson",
  title: "Fence repair",
  description: "",
  status: "scheduled",
  scheduledDate: null,
  scheduledStartTime: null,
  scheduledEndTime: null,
  address: "12 Oak St",
  estimateTotal: 0,
  laborHours: 0,
  laborRate: 0,
  materials: [],
  materialMarkup: 0,
  overhead: 0,
  margin: 0,
  notes: "",
  invoiceId: null,
  createdAt: "2026-08-01",
  ...over,
});

const invoice = (over = {}) => ({
  id: "i1",
  customer: "Alice Johnson",
  number: "INV-0001",
  amount: 100,
  due: "2026-08-10",
  paid: false,
  ...over,
});

beforeEach(() => {
  jest.clearAllMocks();
  mockBridgeAvailable = true;
  mockBridge.setSharedItem.mockResolvedValue(undefined);
  mockBridge.clearShared.mockResolvedValue(undefined);
  AsyncStorage.getItem.mockResolvedValue(null);
});

// ── selectNextJob ─────────────────────────────────────────────────────────────

describe("selectNextJob", () => {
  test("picks the earliest upcoming job by date, then start time", () => {
    const jobs = [
      job({ id: "tomorrow", scheduledDate: "2026-08-04", scheduledStartTime: "08:00" }),
      job({ id: "today-pm", scheduledDate: "2026-08-03", scheduledStartTime: "14:00" }),
      job({ id: "today-am", scheduledDate: "2026-08-03", scheduledStartTime: "09:00" }),
    ];
    expect(selectNextJob(jobs, NOW).id).toBe("today-am");
  });

  test("a job earlier today stays 'next' even after its start time passes", () => {
    // NOW is noon; the 09:00 job is likely the one in progress — still the answer.
    const jobs = [job({ id: "current", scheduledDate: "2026-08-03", scheduledStartTime: "09:00" })];
    expect(selectNextJob(jobs, NOW).id).toBe("current");
  });

  test("same-day jobs without a start time sort after timed ones", () => {
    const jobs = [
      job({ id: "no-time", scheduledDate: "2026-08-03", scheduledStartTime: null }),
      job({ id: "timed", scheduledDate: "2026-08-03", scheduledStartTime: "15:00" }),
    ];
    expect(selectNextJob(jobs, NOW).id).toBe("timed");
  });

  test("skips past dates, archived jobs, done statuses, and unscheduled jobs", () => {
    const jobs = [
      job({ id: "yesterday", scheduledDate: "2026-08-02", scheduledStartTime: "08:00" }),
      job({ id: "archived", scheduledDate: "2026-08-03", archivedAt: "2026-08-01" }),
      job({ id: "done", scheduledDate: "2026-08-03", status: "complete" }),
      job({ id: "paid", scheduledDate: "2026-08-03", status: "paid" }),
      job({ id: "declined", scheduledDate: "2026-08-03", status: "declined" }),
      job({ id: "unscheduled", scheduledDate: null }),
    ];
    expect(selectNextJob(jobs, NOW)).toBeNull();
  });

  test("a lead created with a schedule still counts (new jobs start as lead)", () => {
    const jobs = [job({ id: "lead-job", status: "lead", scheduledDate: "2026-08-05" })];
    expect(selectNextJob(jobs, NOW).id).toBe("lead-job");
  });

  test("projects ONLY the fields the widget displays — no extra PII", () => {
    const jobs = [
      job({
        id: "j9",
        scheduledDate: "2026-08-04",
        scheduledStartTime: "10:30",
        notes: "gate code 4471", // must NOT reach the shared container
      }),
    ];
    expect(selectNextJob(jobs, NOW)).toEqual({
      id: "j9",
      customerName: "Alice Johnson",
      title: "Fence repair",
      scheduledDate: "2026-08-04",
      scheduledStartTime: "10:30",
      address: "12 Oak St",
    });
  });
});

// ── selectActiveTimer ─────────────────────────────────────────────────────────

describe("selectActiveTimer", () => {
  test("returns null when no session is running", () => {
    const jobs = [
      job({ timeSessions: [{ start: "2026-08-03T08:00:00.000Z", end: "2026-08-03T10:00:00.000Z" }] }),
      job({ id: "j2", timeSessions: [] }),
      job({ id: "j3" }),
    ];
    expect(selectActiveTimer(jobs)).toBeNull();
  });

  test("returns the running session's job and clock-in time", () => {
    const jobs = [
      job({
        id: "j2",
        title: "Deck build",
        customerName: "Bob Smith",
        timeSessions: [
          { start: "2026-08-03T08:00:00.000Z", end: "2026-08-03T09:00:00.000Z" },
          { start: "2026-08-03T10:00:00.000Z" },
        ],
      }),
    ];
    expect(selectActiveTimer(jobs)).toEqual({
      jobId: "j2",
      jobTitle: "Deck build",
      customerName: "Bob Smith",
      startedAt: "2026-08-03T10:00:00.000Z",
    });
  });

  test("when data disagrees and two sessions run, the latest clock-in wins", () => {
    const jobs = [
      job({ id: "older", timeSessions: [{ start: "2026-08-03T08:00:00.000Z" }] }),
      job({ id: "newer", timeSessions: [{ start: "2026-08-03T11:00:00.000Z" }] }),
    ];
    expect(selectActiveTimer(jobs).jobId).toBe("newer");
  });
});

// ── buildWidgetSnapshot ───────────────────────────────────────────────────────

describe("buildWidgetSnapshot", () => {
  test("outstanding total sums unpaid balances, matching the Invoices stat", () => {
    const invoices = [
      invoice({ id: "unpaid", amount: 100 }),
      invoice({
        id: "partly",
        amount: 100,
        payments: [{ id: "p1", amount: 40, date: "2026-08-01", method: "cash" }],
      }),
      invoice({ id: "settled", amount: 500, paid: true }),
    ];
    const snap = buildWidgetSnapshot([], invoices, NOW);
    expect(snap.outstandingTotal).toBe(160); // 100 + (100 − 40) + 0
  });

  test("carries version, mirror timestamp, and null placeholders", () => {
    const snap = buildWidgetSnapshot([], [], NOW);
    expect(snap).toEqual({
      version: 1,
      updatedAt: new Date(NOW).toISOString(),
      nextJob: null,
      timer: null,
      outstandingTotal: 0,
    });
  });
});

// ── refreshWidgetSnapshot ─────────────────────────────────────────────────────

describe("refreshWidgetSnapshot", () => {
  test("mirrors the snapshot JSON into the shared container", async () => {
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === KEYS.jobs) {
        // Far-future date so the fixture qualifies against the real clock.
        return Promise.resolve(JSON.stringify([
          job({ id: "j1", scheduledDate: "2099-01-01", scheduledStartTime: "08:00" }),
        ]));
      }
      if (key === KEYS.invoices) {
        return Promise.resolve(JSON.stringify([invoice({ amount: 250 })]));
      }
      return Promise.resolve(null);
    });

    await refreshWidgetSnapshot();

    expect(mockBridge.setSharedItem).toHaveBeenCalledTimes(1);
    const [key, json] = mockBridge.setSharedItem.mock.calls[0];
    expect(key).toBe(WIDGET_SNAPSHOT_KEY);
    const snap = JSON.parse(json);
    expect(snap.version).toBe(1);
    expect(snap.nextJob.id).toBe("j1");
    expect(snap.nextJob.customerName).toBe("Alice Johnson");
    expect(snap.timer).toBeNull();
    expect(snap.outstandingTotal).toBe(250);
  });

  test("a cold cache mirrors an empty snapshot, never sample seed data", async () => {
    await refreshWidgetSnapshot();

    const [, json] = mockBridge.setSharedItem.mock.calls[0];
    const snap = JSON.parse(json);
    expect(snap.nextJob).toBeNull();
    expect(snap.timer).toBeNull();
    expect(snap.outstandingTotal).toBe(0);
  });

  test("no-ops without touching storage when the native module is absent", async () => {
    mockBridgeAvailable = false;

    await expect(refreshWidgetSnapshot()).resolves.toBeUndefined();

    expect(AsyncStorage.getItem).not.toHaveBeenCalled();
    expect(mockBridge.setSharedItem).not.toHaveBeenCalled();
  });

  test("never throws into a save path when the native write fails", async () => {
    mockBridge.setSharedItem.mockRejectedValue(new Error("plist write failed"));

    await expect(refreshWidgetSnapshot()).resolves.toBeUndefined();
  });
});

// ── clearWidgetSnapshot ───────────────────────────────────────────────────────

describe("clearWidgetSnapshot", () => {
  test("clears the shared container", async () => {
    await clearWidgetSnapshot();

    expect(mockBridge.clearShared).toHaveBeenCalledTimes(1);
  });

  test("no-ops when the native module is absent", async () => {
    mockBridgeAvailable = false;

    await expect(clearWidgetSnapshot()).resolves.toBeUndefined();

    expect(mockBridge.clearShared).not.toHaveBeenCalled();
  });

  test("never throws into the sign-out path when the native clear fails", async () => {
    mockBridge.clearShared.mockRejectedValue(new Error("container unavailable"));

    await expect(clearWidgetSnapshot()).resolves.toBeUndefined();
  });
});
