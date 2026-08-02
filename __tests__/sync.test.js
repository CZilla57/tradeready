// __tests__/sync.test.js
// Tests for the initialSync ownership guard:
//   1. Local data owned by a different user must not be pushed to the new user's account.
//   2. Local data with no owner (first login on device) is pushed normally.
//   3. __dataOwner is written after every successful initialSync.
//   4. Stale local collections are cleared when a different user's data is detected.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as Network from "expo-network";
import { supabase } from "../utils/supabase";
import { initialSync, syncIfOnline } from "../utils/sync";

// ── Supabase mock helpers ─────────────────────────────────────────────────────
//
// We override supabase.from in beforeEach so each test gets a fresh chain.
// The chain distinguishes the count query (select with { count: 'exact' })
// from pull queries so they resolve to the right shapes.

let mockUpsert;

function buildFromMock({ countResult = 0 } = {}) {
  mockUpsert = jest.fn().mockResolvedValue({ error: null });

  supabase.from.mockImplementation(() => {
    const chain = { _isCount: false };

    chain.select = jest.fn((fields, opts) => {
      if (opts?.count === "exact") chain._isCount = true;
      return chain;
    });

    // When this is the count query, eq() resolves to { count: countResult }.
    // Otherwise it returns the chain so further calls (.gt, .maybeSingle) work.
    chain.eq = jest.fn(() =>
      chain._isCount
        ? Promise.resolve({ count: countResult, data: [], error: null })
        : chain
    );

    chain.gt = jest.fn().mockResolvedValue({ data: [], error: null });
    chain.maybeSingle = jest.fn().mockResolvedValue({ data: null });
    chain.upsert = mockUpsert;
    chain.update = jest.fn(() => ({
      eq: jest.fn(() => ({ eq: jest.fn().mockResolvedValue({ error: null }) })),
    }));

    return chain;
  });
}

// ── Setup / teardown ──────────────────────────────────────────────────────────

beforeEach(() => {
  jest.clearAllMocks();

  // AsyncStorage defaults: nothing stored
  AsyncStorage.getItem.mockResolvedValue(null);
  AsyncStorage.setItem.mockResolvedValue(undefined);
  AsyncStorage.multiRemove.mockResolvedValue(undefined);

  // Network: online by default
  Network.getNetworkStateAsync.mockResolvedValue({ isConnected: true });

  // Supabase: user has no existing cloud jobs (first-device scenario)
  buildFromMock({ countResult: 0 });
});

// ── Ownership guard ───────────────────────────────────────────────────────────

describe("initialSync ownership guard", () => {
  test("does not push local data when __dataOwner belongs to a different user", async () => {
    // Local data was created while user-a was signed in, but user-b is now logging in.
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__initDone_user-b") return Promise.resolve(null);
      if (key === "__dataOwner") return Promise.resolve(JSON.stringify("user-a"));
      if (key === "jobs")
        return Promise.resolve(
          JSON.stringify([{ id: "j1", title: "Stale job from user-a" }])
        );
      return Promise.resolve(null);
    });

    await initialSync("user-b");

    // The stale job must NOT have been pushed to user-b's cloud account.
    expect(mockUpsert).not.toHaveBeenCalled();
  });

  test("pushes local data when no __dataOwner is set (first login on device)", async () => {
    // Device has local data from pre-login usage; first time any user signs in.
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__initDone_user-new") return Promise.resolve(null);
      if (key === "__dataOwner") return Promise.resolve(null); // no owner yet
      if (key === "jobs")
        return Promise.resolve(
          JSON.stringify([{ id: "j1", title: "My pre-login job" }])
        );
      return Promise.resolve(null);
    });

    await initialSync("user-new");

    // Local data should be pushed because no ownership conflict exists.
    expect(mockUpsert).toHaveBeenCalled();
  });

  test("skips push (pulls instead) when user already has cloud data", async () => {
    // countResult = 3 → user has records in the cloud → second device / reinstall
    buildFromMock({ countResult: 3 });

    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__initDone_user-y") return Promise.resolve(null);
      if (key === "__dataOwner") return Promise.resolve(null);
      if (key === "jobs")
        return Promise.resolve(
          JSON.stringify([{ id: "j1", title: "Local job" }])
        );
      return Promise.resolve(null);
    });

    await initialSync("user-y");

    // Should not push — cloud data takes precedence on second device.
    expect(mockUpsert).not.toHaveBeenCalled();
    // The last-synced timestamp should be reset to trigger a full pull.
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      "__lastSyncedAt",
      JSON.stringify({})
    );
  });

  test("sets __dataOwner to the signed-in userId after successful sync", async () => {
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__initDone_user-x") return Promise.resolve(null);
      if (key === "__dataOwner") return Promise.resolve(null);
      return Promise.resolve(null);
    });

    await initialSync("user-x");

    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      "__dataOwner",
      JSON.stringify("user-x")
    );
  });

  test("clears stale local collections before pulling when a different user's data is detected", async () => {
    // Even if clearAllUserData() partially failed and left stale jobs on disk,
    // initialSync must wipe them before merging the correct user's cloud data.
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__initDone_user-b") return Promise.resolve(null);
      if (key === "__dataOwner") return Promise.resolve(JSON.stringify("user-a"));
      return Promise.resolve(null);
    });

    await initialSync("user-b");

    // multiRemove should have been called to clear the stale collections.
    expect(AsyncStorage.multiRemove).toHaveBeenCalledWith(
      expect.arrayContaining([
        "jobs",
        "invoices",
        "customers",
        "expenses",
        "customerNotes",
        "recurringInvoices",
        "recurringJobs",
        "trips",
        "pricebook",
        "review_requests",
      ])
    );
  });

  test("does not re-run initial sync if already completed for this user", async () => {
    // __initDone_user-z is set — should skip straight to syncIfOnline, no ownership check.
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__initDone_user-z") return Promise.resolve("true");
      return Promise.resolve(null);
    });

    await initialSync("user-z");

    // Verify the ownership-guard path was skipped: __dataOwner is only read
    // during the first-time setup path, not when INIT_DONE is already set.
    const dataOwnerRead = AsyncStorage.getItem.mock.calls.some(
      ([k]) => k === "__dataOwner"
    );
    expect(dataOwnerRead).toBe(false);
  });
});

// ── pullRemote invoice payment-ledger merge ───────────────────────────────────

describe("pullRemote merges invoice payment ledgers", () => {
  test("a webhook payment in the cloud does not clobber a device payment", async () => {
    const localInvoice = {
      id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
      amount: 1000, due: "2026-07-01", paid: false,
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    };
    // The cloud copy has the Stripe payment but NOT the device's cash payment.
    const remoteInvoice = {
      ...localInvoice,
      payments: [{ id: "stripe_cs_1", amount: 600, date: "2026-07-20", method: "stripe" }],
    };

    supabase.from.mockImplementation((table) => {
      const chain = {};
      chain.select = jest.fn(() => chain);
      chain.eq = jest.fn(() => chain);
      chain.gt = jest.fn().mockResolvedValue({
        data: table === "invoices"
          ? [{ id: "i1", data: remoteInvoice, deleted: false }]
          : [],
        error: null,
      });
      chain.maybeSingle = jest.fn().mockResolvedValue({ data: null });
      chain.upsert = jest.fn().mockResolvedValue({ error: null });
      return chain;
    });

    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "invoices") return Promise.resolve(JSON.stringify([localInvoice]));
      return Promise.resolve(null);
    });

    await syncIfOnline("user-a");

    const write = AsyncStorage.setItem.mock.calls.find(([key]) => key === "invoices");
    expect(write).toBeDefined();
    const stored = JSON.parse(write[1]);
    expect(stored).toHaveLength(1);
    // BOTH payments survive — this is the whole point of the phase.
    expect(stored[0].payments.map((p) => p.id).sort()).toEqual(["p1", "stripe_cs_1"]);
    expect(stored[0].paid).toBe(true);
  });

  test("a non-invoice table still replaces wholesale", async () => {
    const localJob = { id: "j1", title: "local version" };
    const remoteJob = { id: "j1", title: "remote version" };

    supabase.from.mockImplementation((table) => {
      const chain = {};
      chain.select = jest.fn(() => chain);
      chain.eq = jest.fn(() => chain);
      chain.gt = jest.fn().mockResolvedValue({
        data: table === "jobs" ? [{ id: "j1", data: remoteJob, deleted: false }] : [],
        error: null,
      });
      chain.maybeSingle = jest.fn().mockResolvedValue({ data: null });
      chain.upsert = jest.fn().mockResolvedValue({ error: null });
      return chain;
    });

    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "jobs") return Promise.resolve(JSON.stringify([localJob]));
      return Promise.resolve(null);
    });

    await syncIfOnline("user-a");

    const write = AsyncStorage.setItem.mock.calls.find(([key]) => key === "jobs");
    const stored = JSON.parse(write[1]);
    expect(stored[0].title).toBe("remote version");
    // A merge invokes mergePaymentLedgers which adds a payments field even to
    // non-invoice records. A pure replace would not. If this field exists,
    // the record went through a merge — which is exactly what must not happen for jobs.
    expect(stored[0].payments).toBeUndefined();
  });
});

// ── pushQueue stamps updated_at with push time, not save time ────────────────
//
// item.ts records when the user SAVED (enqueue time). If a push is delayed
// (failed push retried, offline device reconnecting) and pushQueue stamped
// updated_at with that old item.ts, the row would land in the database
// backdated. Any device whose lastSynced watermark already passed that
// timestamp would then skip the row forever on `gt('updated_at', since)`
// pulls — a real data-loss path for e.g. a late-arriving payment. pushQueue
// must stamp updated_at with the actual push time instead.

describe("pushQueue stamps updated_at with push time, not the queued item's ts", () => {
  const OLD_TS = "2020-01-01T00:00:00.000Z";
  const PUSH_TIME = new Date(2026, 6, 18, 12, 0, 0);

  // Generic chain: same shape as buildFromMock's, but also records upsert/
  // update payloads per table so we can assert on the exact object sent to
  // Supabase (buildFromMock only exposes a single shared upsert mock, which
  // isn't enough to distinguish settings/customer_notes/collection/delete
  // calls from each other in the same test).
  function buildPushMock() {
    const upsertCalls = [];
    const updateCalls = [];
    supabase.from.mockImplementation((table) => {
      const chain = {};
      chain.select = jest.fn(() => chain);
      chain.eq = jest.fn(() => chain);
      chain.gt = jest.fn().mockResolvedValue({ data: [], error: null });
      chain.maybeSingle = jest.fn().mockResolvedValue({ data: null });
      chain.upsert = jest.fn((payload) => {
        upsertCalls.push({ table, payload });
        return Promise.resolve({ error: null });
      });
      chain.update = jest.fn((payload) => {
        updateCalls.push({ table, payload });
        return {
          eq: jest.fn(() => ({
            eq: jest.fn().mockResolvedValue({ error: null }),
          })),
        };
      });
      return chain;
    });
    return { upsertCalls, updateCalls };
  }

  function seedQueue(items) {
    AsyncStorage.getItem.mockImplementation((key) => {
      if (key === "__syncQueue") return Promise.resolve(JSON.stringify(items));
      return Promise.resolve(null);
    });
  }

  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(PUSH_TIME);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test("collection table upsert uses push time, not item.ts", async () => {
    const { upsertCalls } = buildPushMock();
    seedQueue([
      { table: "jobs", op: "upsert", recordId: "j1", payload: { id: "j1" }, ts: OLD_TS },
    ]);

    await syncIfOnline("user-a");

    const call = upsertCalls.find((c) => c.table === "jobs");
    expect(call).toBeDefined();
    expect(call.payload.updated_at).not.toBe(OLD_TS);
    expect(call.payload.updated_at).toBe(PUSH_TIME.toISOString());
  });

  test("settings upsert uses push time, not item.ts", async () => {
    const { upsertCalls } = buildPushMock();
    seedQueue([
      { table: "settings", op: "upsert", recordId: "settings", payload: { businessName: "Acme" }, ts: OLD_TS },
    ]);

    await syncIfOnline("user-a");

    const call = upsertCalls.find((c) => c.table === "settings");
    expect(call).toBeDefined();
    expect(call.payload.updated_at).not.toBe(OLD_TS);
    expect(call.payload.updated_at).toBe(PUSH_TIME.toISOString());
  });

  test("customer_notes upsert uses push time, not item.ts", async () => {
    const { upsertCalls } = buildPushMock();
    seedQueue([
      { table: "customer_notes", op: "upsert", recordId: "acme", payload: "note text", ts: OLD_TS },
    ]);

    await syncIfOnline("user-a");

    const call = upsertCalls.find((c) => c.table === "customer_notes");
    expect(call).toBeDefined();
    expect(call.payload.updated_at).not.toBe(OLD_TS);
    expect(call.payload.updated_at).toBe(PUSH_TIME.toISOString());
  });

  test("delete op uses push time, not item.ts", async () => {
    const { updateCalls } = buildPushMock();
    seedQueue([
      { table: "jobs", op: "delete", recordId: "j1", payload: null, ts: OLD_TS },
    ]);

    await syncIfOnline("user-a");

    const call = updateCalls.find((c) => c.table === "jobs");
    expect(call).toBeDefined();
    expect(call.payload.updated_at).not.toBe(OLD_TS);
    expect(call.payload.updated_at).toBe(PUSH_TIME.toISOString());
    expect(call.payload.deleted).toBe(true);
  });

  test("each item in the same push gets its own push-time stamp (computed once per item)", async () => {
    const { upsertCalls } = buildPushMock();
    seedQueue([
      { table: "jobs", op: "upsert", recordId: "j1", payload: { id: "j1" }, ts: OLD_TS },
      { table: "invoices", op: "upsert", recordId: "i1", payload: { id: "i1" }, ts: OLD_TS },
    ]);

    await syncIfOnline("user-a");

    const jobsCall = upsertCalls.find((c) => c.table === "jobs");
    const invoicesCall = upsertCalls.find((c) => c.table === "invoices");
    expect(jobsCall.payload.updated_at).toBe(PUSH_TIME.toISOString());
    expect(invoicesCall.payload.updated_at).toBe(PUSH_TIME.toISOString());
  });
});
