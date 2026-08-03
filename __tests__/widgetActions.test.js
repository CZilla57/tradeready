// __tests__/widgetActions.test.js
// The JS-side consumer of the widget/Siri pending-action queue
// (utils/widgetActions.ts, docs/widget-plan.md Phase 3-4):
//   1. parsePendingActions — untrusted native-written JSON, dropped on any
//      structural defect.
//   2. applyTimerActions — timer_start/timer_stop replayed against jobs.
//   3. tripFromAction — trip_log replayed into a Trip, with dedupe.
//   4. replayWidgetActions — the read-clear-apply-refresh orchestrator.

import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  parsePendingActions,
  applyTimerActions,
  tripFromAction,
  replayWidgetActions,
} from "../utils/widgetActions";
import { KEYS } from "../utils/storage/keys";

// Isolate storage from sync/notification side effects, same as storage.test.js.
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));

jest.mock("../utils/notifications", () => ({
  syncNotifications: jest.fn(),
}));

// widgetActions.ts talks to the bridge directly, and saveJobs (via the
// storage barrel) also calls refreshWidgetSnapshot internally — mocking the
// module covers both call sites with the same jest.fn() instances.
// DONE_STATUSES is real (not a jest.fn()) — applyTimerActions reads it
// directly as a Set, mirroring widgetBridge.ts's own export exactly.
jest.mock("../utils/widgetBridge", () => ({
  getWidgetSharedItem: jest.fn(),
  removeWidgetSharedItem: jest.fn().mockResolvedValue(undefined),
  refreshWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
  WIDGET_ACTIONS_KEY: "widgetActions",
  DONE_STATUSES: new Set(["complete", "invoiced", "paid", "declined"]),
}));

const { getWidgetSharedItem, removeWidgetSharedItem, refreshWidgetSnapshot } =
  jest.requireMock("../utils/widgetBridge");

const job = (over = {}) => ({
  id: "j1",
  customerId: "c1",
  customerName: "Alice Johnson",
  title: "Fence repair",
  status: "scheduled",
  timeSessions: [],
  address: "12 Oak St",
  createdAt: "2026-08-01",
  ...over,
});

beforeEach(() => {
  jest.clearAllMocks();
  AsyncStorage.getItem.mockResolvedValue(null);
  AsyncStorage.setItem.mockResolvedValue(undefined);
});

// ── parsePendingActions ───────────────────────────────────────────────────────

describe("parsePendingActions", () => {
  test("null input → empty array", () => {
    expect(parsePendingActions(null)).toEqual([]);
  });

  test("empty string → empty array", () => {
    expect(parsePendingActions("")).toEqual([]);
  });

  test("malformed JSON → empty array", () => {
    expect(parsePendingActions("{not json")).toEqual([]);
  });

  test("valid JSON that isn't an array → empty array", () => {
    expect(parsePendingActions(JSON.stringify({ id: "a1", type: "timer_start", at: "x" }))).toEqual([]);
  });

  test("drops entries missing id, type, or at; keeps valid ones", () => {
    const raw = JSON.stringify([
      { id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" },
      { type: "timer_start", at: "2026-08-03T09:00:00.000Z" }, // missing id
      { id: "a3", at: "2026-08-03T09:00:00.000Z" }, // missing type
      { id: "a4", type: "timer_stop" }, // missing at
      null,
      "not an object",
    ]);
    expect(parsePendingActions(raw)).toEqual([
      { id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" },
    ]);
  });
});

// ── applyTimerActions ─────────────────────────────────────────────────────────

describe("applyTimerActions", () => {
  test("timer_start clocks the matching job in", () => {
    const jobs = [job({ id: "j1", status: "scheduled" })];
    const actions = [{ id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" }];
    const { jobs: result, changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(true);
    expect(result[0].timeSessions).toEqual([{ start: "2026-08-03T09:00:00.000Z", end: null }]);
    expect(result[0].status).toBe("in_progress");
  });

  test("timer_start with no matching job is dropped", () => {
    const jobs = [job({ id: "j1" })];
    const actions = [{ id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "ghost" }];
    const { jobs: result, changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(false);
    expect(result).toEqual(jobs);
  });

  test("timer_start on a job that's already clocked in is dropped (applyClockIn guard)", () => {
    const jobs = [job({ id: "j1", timeSessions: [{ start: "2026-08-03T08:00:00.000Z", end: null }] })];
    const actions = [{ id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" }];
    const { changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(false);
  });

  test.each(["complete", "invoiced", "paid", "declined"])(
    "timer_start is dropped for a '%s' job — replay-layer policy (applyClockIn itself has no status guard; the in-app button still clocks into complete/invoiced jobs)",
    (status) => {
      const jobs = [job({ id: "j1", status })];
      const actions = [{ id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" }];
      const { jobs: result, changed } = applyTimerActions(jobs, actions);
      expect(changed).toBe(false);
      expect(result).toEqual(jobs);
    }
  );

  test("timer_stop with jobId closes that job's session", () => {
    const jobs = [
      job({ id: "j1", timeSessions: [{ start: "2026-08-03T08:00:00.000Z", end: null }] }),
      job({ id: "j2" }),
    ];
    const actions = [{ id: "a1", type: "timer_stop", at: "2026-08-03T10:00:00.000Z", jobId: "j1" }];
    const { jobs: result, changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(true);
    expect(result[0].timeSessions[0].end).toBe("2026-08-03T10:00:00.000Z");
  });

  test("timer_stop with no jobId falls back to the single job with an active session", () => {
    const jobs = [
      job({ id: "j1" }),
      job({ id: "j2", timeSessions: [{ start: "2026-08-03T08:00:00.000Z", end: null }] }),
    ];
    const actions = [{ id: "a1", type: "timer_stop", at: "2026-08-03T10:00:00.000Z" }];
    const { jobs: result, changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(true);
    expect(result[1].timeSessions[0].end).toBe("2026-08-03T10:00:00.000Z");
  });

  test("timer_stop with nothing running anywhere is dropped", () => {
    const jobs = [job({ id: "j1" })];
    const actions = [{ id: "a1", type: "timer_stop", at: "2026-08-03T10:00:00.000Z" }];
    const { changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(false);
  });

  test("timer_stop with an explicit jobId whose job has no active session is dropped", () => {
    const jobs = [job({ id: "j1", timeSessions: [] })];
    const actions = [{ id: "a1", type: "timer_stop", at: "2026-08-03T10:00:00.000Z", jobId: "j1" }];
    const { jobs: result, changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(false);
    expect(result).toEqual(jobs);
  });

  test("applies a start-then-stop pair for the same job in order", () => {
    const jobs = [job({ id: "j1", status: "scheduled" })];
    const actions = [
      { id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" },
      { id: "a2", type: "timer_stop", at: "2026-08-03T11:00:00.000Z", jobId: "j1" },
    ];
    const { jobs: result, changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(true);
    expect(result[0].timeSessions).toEqual([
      { start: "2026-08-03T09:00:00.000Z", end: "2026-08-03T11:00:00.000Z" },
    ]);
    expect(result[0].status).toBe("in_progress");
  });

  test("ignores trip_log actions entirely", () => {
    const jobs = [job({ id: "j1" })];
    const actions = [{ id: "a1", type: "trip_log", at: "2026-08-03T09:00:00.000Z", date: "2026-08-03", odometerStart: 0, odometerEnd: 10 }];
    const { changed } = applyTimerActions(jobs, actions);
    expect(changed).toBe(false);
  });
});

// ── tripFromAction ────────────────────────────────────────────────────────────

describe("tripFromAction", () => {
  const tripAction = (over = {}) => ({
    id: "sa1",
    type: "trip_log",
    at: "2026-08-03T09:30:00.000Z",
    date: "2026-08-03",
    odometerStart: 100,
    odometerEnd: 115,
    ...over,
  });

  test("builds a Trip with the t_siri_<id> prefix and Home/Shop endpoints", () => {
    const trip = tripFromAction(tripAction(), []);
    expect(trip).toEqual({
      id: "t_siri_sa1",
      date: "2026-08-03",
      odometerStart: 100,
      odometerEnd: 115,
      miles: 15,
      fromJobId: null,
      fromLabel: "Home / Shop",
      toJobId: null,
      toLabel: "Home / Shop",
      purpose: "Business trip (Siri)",
      createdAt: "2026-08-03",
    });
  });

  test("clamps miles to 0 when the end reading is before the start (bad odometer entry)", () => {
    const trip = tripFromAction(tripAction({ odometerStart: 200, odometerEnd: 150 }), []);
    expect(trip.miles).toBe(0);
  });

  test("dedupes: null when a trip with this id already exists", () => {
    const existing = [{ id: "t_siri_sa1" }];
    expect(tripFromAction(tripAction(), existing)).toBeNull();
  });

  test.each([
    ["odometerStart missing", { odometerStart: undefined }],
    ["odometerEnd missing", { odometerEnd: undefined }],
    ["odometerStart negative", { odometerStart: -1 }],
    ["odometerEnd negative", { odometerEnd: -1 }],
    ["odometerStart non-finite", { odometerStart: Infinity }],
    ["odometerStart not a number", { odometerStart: "100" }],
  ])("drops the action when %s", (_label, over) => {
    expect(tripFromAction(tripAction(over), [])).toBeNull();
  });

  test("drops the action when date is missing", () => {
    expect(tripFromAction(tripAction({ date: undefined }), [])).toBeNull();
  });
});

// ── replayWidgetActions ───────────────────────────────────────────────────────

describe("replayWidgetActions", () => {
  // Empty queue is the overwhelmingly common case (most launches/foregrounds
  // have nothing pending) — it must still refresh the widget snapshot
  // exactly once, or a fresh install stays on stale/seed data forever and
  // sync's raw writes never reach the widget. Only the read/remove/apply
  // portion is skipped; removeSharedItem must NOT fire for a queue that was
  // never there to begin with.
  test.each([
    ["absent (native module missing or nothing queued)", null],
    ["an empty string", ""],
  ])("empty queue (%s): no removeSharedItem call, but exactly one snapshot refresh", async (_label, rawValue) => {
    getWidgetSharedItem.mockResolvedValue(rawValue);

    await expect(replayWidgetActions()).resolves.toBeUndefined();

    expect(removeWidgetSharedItem).not.toHaveBeenCalled();
    expect(refreshWidgetSnapshot).toHaveBeenCalledTimes(1);
    // refreshWidgetSnapshot is mocked out entirely in this file (see the
    // jest.mock above) — it never touches AsyncStorage here regardless of
    // how many times it's called. This assertion is about replayWidgetActions
    // itself skipping loadJobs/loadTrips when there's no queue, not about
    // what the real refreshWidgetSnapshot does (that's widgetBridge.test.js's
    // job — the real one DOES read AsyncStorage once the bridge is present).
    expect(AsyncStorage.getItem).not.toHaveBeenCalled();
  });

  test("reads, removes, replays a timer action, saves jobs, and refreshes", async () => {
    const actions = [{ id: "a1", type: "timer_start", at: "2026-08-03T09:00:00.000Z", jobId: "j1" }];
    getWidgetSharedItem.mockResolvedValue(JSON.stringify(actions));
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === KEYS.jobs) return Promise.resolve(JSON.stringify([job({ id: "j1", status: "scheduled" })]));
      return Promise.resolve(null);
    });

    await replayWidgetActions();

    expect(removeWidgetSharedItem).toHaveBeenCalledWith("widgetActions");
    const savedJobsCall = AsyncStorage.setItem.mock.calls.find(([key]) => key === KEYS.jobs);
    expect(savedJobsCall).toBeDefined();
    const savedJobs = JSON.parse(savedJobsCall[1]);
    expect(savedJobs[0].timeSessions).toEqual([{ start: "2026-08-03T09:00:00.000Z", end: null }]);
    expect(savedJobs[0].status).toBe("in_progress");
    // Twice here: saveJobs (utils/storage/collections.ts) already mirrors on
    // every save, and replayWidgetActions finishes with its own explicit
    // refresh so the trip-only path (saveTrips does NOT self-mirror) still
    // gets one. Harmless double-refresh, not a bug — see replayWidgetActions.
    expect(refreshWidgetSnapshot).toHaveBeenCalledTimes(2);
  });

  test("reads, removes, replays a trip_log action, saves trips, and refreshes", async () => {
    const actions = [
      { id: "a1", type: "trip_log", at: "2026-08-03T09:00:00.000Z", date: "2026-08-03", odometerStart: 10, odometerEnd: 25 },
    ];
    getWidgetSharedItem.mockResolvedValue(JSON.stringify(actions));
    AsyncStorage.getItem.mockResolvedValue(null);

    await replayWidgetActions();

    const savedTripsCall = AsyncStorage.setItem.mock.calls.find(([key]) => key === KEYS.trips);
    expect(savedTripsCall).toBeDefined();
    const savedTrips = JSON.parse(savedTripsCall[1]);
    expect(savedTrips).toHaveLength(1);
    expect(savedTrips[0]).toMatchObject({ id: "t_siri_a1", miles: 15, purpose: "Business trip (Siri)" });
    expect(refreshWidgetSnapshot).toHaveBeenCalledTimes(1);
  });

  test("a batch that fails every guard still removes the key and refreshes, without saving", async () => {
    getWidgetSharedItem.mockResolvedValue("not valid json");
    AsyncStorage.getItem.mockResolvedValue(null);

    await replayWidgetActions();

    expect(removeWidgetSharedItem).toHaveBeenCalledTimes(1);
    expect(refreshWidgetSnapshot).toHaveBeenCalledTimes(1);
    expect(AsyncStorage.setItem).not.toHaveBeenCalledWith(KEYS.jobs, expect.anything());
    expect(AsyncStorage.setItem).not.toHaveBeenCalledWith(KEYS.trips, expect.anything());
  });

  test("never throws, even when reading the shared item rejects outright", async () => {
    getWidgetSharedItem.mockRejectedValue(new Error("bridge exploded"));

    await expect(replayWidgetActions()).resolves.toBeUndefined();
  });

  test("never throws, even when the final refresh rejects", async () => {
    getWidgetSharedItem.mockResolvedValue(JSON.stringify([]));
    refreshWidgetSnapshot.mockRejectedValue(new Error("mirror failed"));

    await expect(replayWidgetActions()).resolves.toBeUndefined();
  });
});
