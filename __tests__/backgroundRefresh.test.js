// __tests__/backgroundRefresh.test.js
// utils/backgroundRefresh.ts — the periodic background wake that pulls sync
// and drains the widget/Siri queue without an app open
// (.superpowers/sdd/plan-widgets-tier2.md Task 1):
//   1. runBackgroundRefresh — the testable core (session → sync → replay).
//   2. defineTask registration (module-scope side effect).
//   3. registerBackgroundRefresh — registers the OS wake, never throws.

jest.mock("expo-task-manager", () => ({
  defineTask: jest.fn(),
  isAvailableAsync: jest.fn(),
}));

jest.mock("expo-background-task", () => ({
  registerTaskAsync: jest.fn(),
  BackgroundTaskResult: { Success: 1, Failed: 2 },
}));

jest.mock("../utils/supabase", () => ({
  supabase: {
    auth: {
      getSession: jest.fn(),
    },
  },
}));

jest.mock("../utils/sync", () => ({
  syncIfOnline: jest.fn(),
}));

jest.mock("../utils/widgetActions", () => ({
  replayWidgetActions: jest.fn(),
}));

const TaskManager = require("expo-task-manager");
const BackgroundTask = require("expo-background-task");
const { supabase } = require("../utils/supabase");
const { syncIfOnline } = require("../utils/sync");
const { replayWidgetActions } = require("../utils/widgetActions");

const {
  BACKGROUND_REFRESH_TASK,
  runBackgroundRefresh,
  registerBackgroundRefresh,
} = require("../utils/backgroundRefresh");

// defineTask fires exactly once, synchronously, as a side effect of the
// require() above — i.e. before any beforeEach/jest.clearAllMocks() runs.
// Capture the call now, at module-eval time, since clearAllMocks would
// otherwise wipe TaskManager.defineTask.mock.calls before any test body
// gets a chance to read it.
const defineTaskCall = TaskManager.defineTask.mock.calls[0];
const registeredExecutor = defineTaskCall && defineTaskCall[1];

beforeEach(() => {
  jest.clearAllMocks();
  syncIfOnline.mockResolvedValue(undefined);
  replayWidgetActions.mockResolvedValue(undefined);
});

// ── defineTask module-scope registration ─────────────────────────────────────

describe("module-scope defineTask side effect", () => {
  test("defines the task under BACKGROUND_REFRESH_TASK", () => {
    expect(defineTaskCall).toEqual([BACKGROUND_REFRESH_TASK, expect.any(Function)]);
  });

  test("BACKGROUND_REFRESH_TASK is the documented literal task name", () => {
    expect(BACKGROUND_REFRESH_TASK).toBe("tradeready-background-refresh");
  });

  test("the registered executor resolves BackgroundTaskResult.Success on a clean run", async () => {
    // runBackgroundRefresh is documented to never throw (every await inside
    // it is individually try/caught), so the executor's Failed branch is a
    // defensive belt-and-suspenders path with no legitimate way to trigger
    // it through mocks without misrepresenting that contract — this asserts
    // the executor wires runBackgroundRefresh to the Success result, which
    // is the only reachable outcome.
    supabase.auth.getSession.mockResolvedValue({ data: { session: null } });
    await expect(
      registeredExecutor({ data: null, error: null, executionInfo: {} })
    ).resolves.toBe(BackgroundTask.BackgroundTaskResult.Success);
  });
});

// ── runBackgroundRefresh ──────────────────────────────────────────────────────

describe("runBackgroundRefresh", () => {
  test("session present: syncs then replays, in order", async () => {
    supabase.auth.getSession.mockResolvedValue({ data: { session: { user: { id: "u1" } } } });
    const order = [];
    syncIfOnline.mockImplementation(async () => {
      order.push("sync");
    });
    replayWidgetActions.mockImplementation(async () => {
      order.push("replay");
    });

    await runBackgroundRefresh();

    expect(syncIfOnline).toHaveBeenCalledWith("u1");
    expect(replayWidgetActions).toHaveBeenCalledTimes(1);
    expect(order).toEqual(["sync", "replay"]);
  });

  test("no session: calls neither sync nor replay", async () => {
    supabase.auth.getSession.mockResolvedValue({ data: { session: null } });

    await runBackgroundRefresh();

    expect(syncIfOnline).not.toHaveBeenCalled();
    expect(replayWidgetActions).not.toHaveBeenCalled();
  });

  test("session with no user id: calls neither sync nor replay", async () => {
    supabase.auth.getSession.mockResolvedValue({ data: { session: { user: null } } });

    await runBackgroundRefresh();

    expect(syncIfOnline).not.toHaveBeenCalled();
    expect(replayWidgetActions).not.toHaveBeenCalled();
  });

  test("getSession rejecting resolves without throwing and calls neither", async () => {
    supabase.auth.getSession.mockRejectedValue(new Error("secure storage exploded"));

    await expect(runBackgroundRefresh()).resolves.toBeUndefined();

    expect(syncIfOnline).not.toHaveBeenCalled();
    expect(replayWidgetActions).not.toHaveBeenCalled();
  });

  // sync rejecting: replay is still attempted. Draining the widget/Siri queue
  // and re-mirroring the snapshot doesn't depend on the network call that
  // just failed, so skipping it too would silently delay actions the user
  // already made (see the doc comment in utils/backgroundRefresh.ts).
  test("sync rejecting resolves without throwing; replay is still attempted", async () => {
    supabase.auth.getSession.mockResolvedValue({ data: { session: { user: { id: "u1" } } } });
    syncIfOnline.mockRejectedValue(new Error("offline"));

    await expect(runBackgroundRefresh()).resolves.toBeUndefined();

    expect(syncIfOnline).toHaveBeenCalledWith("u1");
    expect(replayWidgetActions).toHaveBeenCalledTimes(1);
  });

  test("replay rejecting still resolves without throwing", async () => {
    supabase.auth.getSession.mockResolvedValue({ data: { session: { user: { id: "u1" } } } });
    replayWidgetActions.mockRejectedValue(new Error("bridge exploded"));

    await expect(runBackgroundRefresh()).resolves.toBeUndefined();
  });
});

// ── registerBackgroundRefresh ─────────────────────────────────────────────────

describe("registerBackgroundRefresh", () => {
  test("available: registers the task with the name and a ~30 minute interval", async () => {
    TaskManager.isAvailableAsync.mockResolvedValue(true);
    BackgroundTask.registerTaskAsync.mockResolvedValue(undefined);

    await registerBackgroundRefresh();

    expect(BackgroundTask.registerTaskAsync).toHaveBeenCalledWith(
      BACKGROUND_REFRESH_TASK,
      expect.objectContaining({ minimumInterval: 30 })
    );
  });

  test("unavailable (Expo Go / web): never calls registerTaskAsync, never throws", async () => {
    TaskManager.isAvailableAsync.mockResolvedValue(false);

    await expect(registerBackgroundRefresh()).resolves.toBeUndefined();

    expect(BackgroundTask.registerTaskAsync).not.toHaveBeenCalled();
  });

  test("available but native module absent: registerTaskAsync rejects (UnavailabilityError) and it still doesn't throw", async () => {
    TaskManager.isAvailableAsync.mockResolvedValue(true);
    BackgroundTask.registerTaskAsync.mockRejectedValue(
      new Error("UnavailabilityError: BackgroundTask.registerTaskAsync is not available")
    );

    await expect(registerBackgroundRefresh()).resolves.toBeUndefined();

    expect(BackgroundTask.registerTaskAsync).toHaveBeenCalledWith(
      BACKGROUND_REFRESH_TASK,
      expect.any(Object)
    );
  });

  test("isAvailableAsync itself rejecting doesn't throw", async () => {
    TaskManager.isAvailableAsync.mockRejectedValue(new Error("native call failed"));

    await expect(registerBackgroundRefresh()).resolves.toBeUndefined();
    expect(BackgroundTask.registerTaskAsync).not.toHaveBeenCalled();
  });
});
