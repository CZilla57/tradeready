// __tests__/storage.test.js
// Tests for high-risk storage invariants:
//   1. Editing a paid invoice must not reset it to unpaid.
//   2. Sign-out clears all local data and sensitive SecureStore keys.
//   3. Sign-out rotates the sample-seed namespace so re-seeded ids never
//      collide with seed rows a previous account already pushed.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import {
  loadInvoices, saveInvoices,
  loadJobs, saveJobs,
  loadCustomers, saveCustomers,
  saveExpenses,
  clearAllUserData,
} from "../utils/storage";
import { defaultCustomers, defaultJobs, defaultInvoices, resetSampleSeed } from "../utils/storage/defaults";
import { isSampleId } from "../utils/sampleData";

// Isolate storage from sync and notification side-effects so these tests
// only assert on AsyncStorage / SecureStore calls.
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));

jest.mock("../utils/notifications", () => ({
  syncNotifications: jest.fn(),
}));

beforeEach(() => {
  jest.clearAllMocks();
  AsyncStorage.getItem.mockResolvedValue(null);
  AsyncStorage.setItem.mockResolvedValue(undefined);
  AsyncStorage.multiRemove.mockResolvedValue(undefined);
});

// ── Invoice paid-status preservation ──────────────────────────────────────────

describe("editing a paid invoice does not reset paid status", () => {
  test("spread-merge preserves paid:true when the edit payload omits paid", () => {
    // This is the exact pattern used in AddInvoiceScreen when saving an edit.
    const existing = { id: "1", customer: "Alice", amount: 500, paid: true, number: "INV-001" };
    const invoiceFields = { customer: "Alice Updated", amount: 600 }; // no 'paid' key
    const merged = { ...existing, ...invoiceFields };

    expect(merged.paid).toBe(true);
    expect(merged.amount).toBe(600);
    expect(merged.customer).toBe("Alice Updated");
  });

  test("spread-merge preserves paid:false when the edit payload omits paid", () => {
    const existing = { id: "2", customer: "Bob", amount: 200, paid: false, number: "INV-002" };
    const invoiceFields = { amount: 250 };
    const merged = { ...existing, ...invoiceFields };

    expect(merged.paid).toBe(false);
    expect(merged.amount).toBe(250);
  });

  test("loadInvoices returns paid:true after saveInvoices stores it", async () => {
    const invoice = {
      id: "42", customer: "Carol", number: "INV-042",
      amount: 300, paid: true, due: "2026-01-01",
    };
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify([invoice]));

    const loaded = await loadInvoices();

    expect(loaded).toHaveLength(1);
    expect(loaded[0].paid).toBe(true);
  });

  test("saveInvoices preserves paid:true on untouched invoices during a sibling edit", async () => {
    // Pre-populate storage with two invoices: one paid, one not.
    const original = [
      { id: "1", customer: "Alice", amount: 500, number: "INV-001", paid: true,  due: "2026-01-01" },
      { id: "2", customer: "Bob",   amount: 200, number: "INV-002", paid: false, due: "2026-06-01" },
    ];

    // Simulate AddInvoiceScreen editing invoice 2 only (spread-merge, no 'paid' key)
    const invoiceFields = { customer: "Bob Updated", amount: 250 };
    const updated = original.map((i) =>
      i.id === "2" ? { ...i, ...invoiceFields } : i
    );

    await saveInvoices(updated);

    // Verify what was actually written to AsyncStorage
    const [, writtenJson] = AsyncStorage.setItem.mock.calls[0];
    const written = JSON.parse(writtenJson);

    expect(written[0].paid).toBe(true);    // Alice still paid
    expect(written[1].paid).toBe(false);   // Bob still unpaid
    expect(written[1].amount).toBe(250);   // Bob's amount updated
    expect(written[1].customer).toBe("Bob Updated");
  });
});

// ── Sign-out / local data cleanup ─────────────────────────────────────────────

describe("clearAllUserData", () => {
  test("removes all AsyncStorage keys including sync queue and onboarding flag", async () => {
    await clearAllUserData();

    expect(AsyncStorage.multiRemove).toHaveBeenCalledTimes(1);
    const [removedKeys] = AsyncStorage.multiRemove.mock.calls[0];

    const mustBeRemoved = [
      "invoices",
      "jobs",
      "customers",
      "settings",
      "expenses",
      "customerNotes",
      "__syncQueue",
      "__lastSyncedAt",
      "__dataOwner",
      "onboardingComplete",
    ];
    for (const key of mustBeRemoved) {
      expect(removedKeys).toContain(key);
    }
  });

  test("deletes all SecureStore sensitive keys including legacy geminiKey", async () => {
    await clearAllUserData();

    const deletedKeys = SecureStore.deleteItemAsync.mock.calls.map(([k]) => k);
    expect(deletedKeys).toContain("providerKey");
    expect(deletedKeys).toContain("anthropicKey");
    expect(deletedKeys).toContain("groqKey");
    expect(deletedKeys).toContain("geminiKey"); // legacy key cleanup
    // Supabase auth session cleanup: base key + a bounded 10-slot chunk range
    // (utils/storage/lifecycle.ts / utils/secureStoreAdapter.ts).
    expect(deletedKeys).toContain("supabase_session");
    expect(deletedKeys).toContain("supabase_session_chunk_1");
    expect(deletedKeys).toContain("supabase_session_chunk_10");
    // 4 credential keys + session base key + 10 chunk slots = 15.
    expect(deletedKeys).toHaveLength(15);
  });

  test("completes without throwing even if a SecureStore delete fails", async () => {
    // Simulates a locked keychain on first key — the others must still be deleted.
    SecureStore.deleteItemAsync.mockRejectedValueOnce(new Error("keychain locked"));

    await expect(clearAllUserData()).resolves.toBeUndefined();

    // All 15 deletes (4 credential keys + session base key + 10 chunk slots)
    // were attempted despite the failure on the first.
    expect(SecureStore.deleteItemAsync).toHaveBeenCalledTimes(15);
  });
});

// ── Storage key-name contracts ────────────────────────────────────────────────
// These tests pin the AsyncStorage key strings. If a key is ever renamed in
// KEYS (storage.js) without updating dependent code (sync.js, these tests),
// the test fails loudly rather than silently reading from the wrong bucket.

describe("storage key contracts", () => {
  test("loadJobs reads from the 'jobs' key", async () => {
    await loadJobs();
    expect(AsyncStorage.getItem).toHaveBeenCalledWith("jobs");
  });

  test("saveJobs writes to the 'jobs' key", async () => {
    const jobs = [{ id: "j1", title: "Test job" }];
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify(jobs));
    await saveJobs(jobs);
    const writtenKey = AsyncStorage.setItem.mock.calls[0][0];
    expect(writtenKey).toBe("jobs");
  });

  test("loadCustomers reads from the 'customers' key", async () => {
    await loadCustomers();
    expect(AsyncStorage.getItem).toHaveBeenCalledWith("customers");
  });

  test("saveCustomers writes to the 'customers' key", async () => {
    const customers = [{ id: "c1", name: "Alice" }];
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify(customers));
    await saveCustomers(customers);
    const writtenKey = AsyncStorage.setItem.mock.calls[0][0];
    expect(writtenKey).toBe("customers");
  });

  test("loadInvoices reads from the 'invoices' key", async () => {
    await loadInvoices();
    expect(AsyncStorage.getItem).toHaveBeenCalledWith("invoices");
  });

  test("saveExpenses writes to the 'expenses' key", async () => {
    const expenses = [{ id: "e1", amount: 50 }];
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify(expenses));
    await saveExpenses(expenses);
    const writtenKey = AsyncStorage.setItem.mock.calls[0][0];
    expect(writtenKey).toBe("expenses");
  });

  test("clearAllUserData removes __dataOwner", async () => {
    await clearAllUserData();
    const [removedKeys] = AsyncStorage.multiRemove.mock.calls[0];
    expect(removedKeys).toContain("__dataOwner");
  });
});

// ── Sample-seed namespace rotation ────────────────────────────────────────────
// The seeds materialize on any read of an empty collection. If the namespace
// suffix survives a sign-out, the next account re-seeds the SAME ids the
// previous account may have pushed, and RLS rejects the upserts forever
// (demo-account sync wedge, 2026-07-16).

describe("sample seed namespacing", () => {
  test("seeds share one suffix so job→customer links resolve", () => {
    const customers = defaultCustomers();
    const suffix = customers[0].id.slice("c1-".length);
    expect(customers.map((c) => c.id)).toEqual([
      `c1-${suffix}`, `c2-${suffix}`, `c3-${suffix}`,
    ]);
    for (const job of defaultJobs()) {
      expect(customers.some((c) => c.id === job.customerId)).toBe(true);
    }
    for (const record of [...customers, ...defaultInvoices()]) {
      expect(isSampleId(record.id)).toBe(true);
    }
  });

  test("resetSampleSeed rotates the suffix and keeps links consistent", () => {
    const before = defaultCustomers()[0].id;
    resetSampleSeed();
    const customers = defaultCustomers();
    expect(customers[0].id).not.toBe(before);
    for (const job of defaultJobs()) {
      expect(customers.some((c) => c.id === job.customerId)).toBe(true);
    }
    expect(isSampleId(customers[0].id)).toBe(true);
  });

  test("clearAllUserData rotates the seed so re-seeded ids cannot collide with the previous account's", async () => {
    const before = defaultCustomers()[0].id;
    await clearAllUserData();
    expect(defaultCustomers()[0].id).not.toBe(before);
  });
});
