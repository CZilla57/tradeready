import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  newBatchId,
  recordImportBatch,
  loadImportHistory,
  findBatchByFileHash,
} from "../utils/importHistory";

// The global jest.setup.js mock for @react-native-async-storage/async-storage
// is a set of stateless jest.fn() stubs (getItem always resolves null; setItem
// is a no-op) — other suites work around this by asserting on mock.calls or
// stubbing per-test return values. This suite needs real read-after-write
// persistence (record then read back, find-by-hash), so it overrides the mock
// locally with a real in-memory store. Scoped to this file only — no shared
// config touched, no new dependency (the package is already installed). Jest
// hoists this above the imports above regardless of textual position.
jest.mock("@react-native-async-storage/async-storage", () => {
  let store: Record<string, string> = {};
  return {
    getItem: jest.fn((key: string) => Promise.resolve(store[key] ?? null)),
    setItem: jest.fn((key: string, value: string) => {
      store[key] = value;
      return Promise.resolve();
    }),
    removeItem: jest.fn((key: string) => {
      delete store[key];
      return Promise.resolve();
    }),
    clear: jest.fn(() => {
      store = {};
      return Promise.resolve();
    }),
    getAllKeys: jest.fn(() => Promise.resolve(Object.keys(store))),
    multiGet: jest.fn(() => Promise.resolve([])),
    multiSet: jest.fn(() => Promise.resolve()),
    multiRemove: jest.fn(() => Promise.resolve()),
  };
});

beforeEach(async () => { await AsyncStorage.clear(); });

test("newBatchId returns unique ids", () => {
  expect(newBatchId()).not.toBe(newBatchId());
});

test("records and reads back batch history (newest first)", async () => {
  await recordImportBatch({ batchId: "b1", entity: "customers", fileHash: "h1", date: "2026-08-06", counts: { ok: 2, skip: 0, flag: 0, created: 2, matched: 0 } });
  await recordImportBatch({ batchId: "b2", entity: "jobs", fileHash: "h2", date: "2026-08-06", counts: { ok: 1, skip: 1, flag: 0, created: 1, matched: 0 } });
  const hist = await loadImportHistory();
  expect(hist.map((h) => h.batchId)).toEqual(["b2", "b1"]);
});

test("finds a prior batch by entity + file hash", async () => {
  await recordImportBatch({ batchId: "b1", entity: "customers", fileHash: "hAAA", date: "2026-08-06", counts: { ok: 2, skip: 0, flag: 0, created: 2, matched: 0 } });
  expect((await findBatchByFileHash("customers", "hAAA"))?.batchId).toBe("b1");
  expect(await findBatchByFileHash("jobs", "hAAA")).toBeNull();
});
