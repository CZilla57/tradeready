// __tests__/sync.test.js
// Tests for the initialSync ownership guard:
//   1. Local data owned by a different user must not be pushed to the new user's account.
//   2. Local data with no owner (first login on device) is pushed normally.
//   3. __dataOwner is written after every successful initialSync.
//   4. Stale local collections are cleared when a different user's data is detected.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as Network from "expo-network";
import { supabase } from "../utils/supabase";
import { initialSync } from "../utils/sync";

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
      expect.arrayContaining(["jobs", "invoices", "customers", "expenses", "customerNotes"])
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
