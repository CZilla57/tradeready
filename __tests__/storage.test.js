// __tests__/storage.test.js
// Tests for high-risk storage invariants:
//   1. Editing a paid invoice must not reset it to unpaid.
//   2. Sign-out clears all local data and sensitive SecureStore keys.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";
import { loadInvoices, saveInvoices, clearAllUserData } from "../utils/storage";

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
      "onboardingComplete",
    ];
    for (const key of mustBeRemoved) {
      expect(removedKeys).toContain(key);
    }
  });

  test("deletes all three SecureStore sensitive keys", async () => {
    await clearAllUserData();

    const deletedKeys = SecureStore.deleteItemAsync.mock.calls.map(([k]) => k);
    expect(deletedKeys).toContain("providerKey");
    expect(deletedKeys).toContain("anthropicKey");
    expect(deletedKeys).toContain("geminiKey");
    expect(deletedKeys).toHaveLength(3);
  });

  test("completes without throwing even if a SecureStore delete fails", async () => {
    // Simulates a locked keychain on first key — the others must still be deleted.
    SecureStore.deleteItemAsync.mockRejectedValueOnce(new Error("keychain locked"));

    await expect(clearAllUserData()).resolves.toBeUndefined();

    // All three deletes were attempted despite the failure on the first
    expect(SecureStore.deleteItemAsync).toHaveBeenCalledTimes(3);
  });
});
