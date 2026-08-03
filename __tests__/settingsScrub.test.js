// __tests__/settingsScrub.test.js
// The 2026-08 Square credential healing pass: builds before the fix told
// users to paste their Square ACCESS TOKEN into Settings, which then sat in
// plaintext AsyncStorage and synced into the cloud settings blob.
// scrubLegacySquareToken must remove token-shaped values (and push the
// cleaned blob via saveSettings' enqueue, overwriting the cloud copy) while
// leaving real payment links alone — and a run that finds nothing must not
// write, because every save re-enqueues a cloud upsert.

import AsyncStorage from "@react-native-async-storage/async-storage";
import { scrubLegacySquareToken } from "../utils/storage";
import { enqueue } from "../utils/sync";

// Isolate storage from sync and notification side-effects, same as
// storage.test.js.
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));

jest.mock("../utils/notifications", () => ({
  syncNotifications: jest.fn(),
}));

const settingsBlob = (providerKeys) =>
  JSON.stringify({ businessName: "Trades Co", provider: "square", providerKeys });

function storeSettings(blob) {
  AsyncStorage.getItem.mockImplementation((key) =>
    Promise.resolve(key === "settings" ? blob : null)
  );
}

beforeEach(() => {
  jest.clearAllMocks();
  AsyncStorage.getItem.mockResolvedValue(null);
  AsyncStorage.setItem.mockResolvedValue(undefined);
});

describe("scrubLegacySquareToken", () => {
  test("removes a legacy Access Token and re-saves, so device AND cloud get the cleaned blob", async () => {
    storeSettings(settingsBlob({ square: "EAAAl_legacy_access_token", paypal: "johndoe" }));

    const changed = await scrubLegacySquareToken();

    expect(changed).toBe(true);
    const written = JSON.parse(
      AsyncStorage.setItem.mock.calls.find(([key]) => key === "settings")[1]
    );
    expect(written.providerKeys.square).toBeUndefined();
    expect(written.providerKeys.paypal).toBe("johndoe");
    // The cloud upsert payload must carry the cleaned map — this is what
    // overwrites the token already sitting in the Supabase settings row.
    expect(enqueue).toHaveBeenCalledWith(
      "settings",
      "upsert",
      "settings",
      expect.objectContaining({ providerKeys: { paypal: "johndoe" } })
    );
  });

  test("leaves a real square.link payment link alone — and does not write", async () => {
    storeSettings(settingsBlob({ square: "https://square.link/u/abc123" }));

    const changed = await scrubLegacySquareToken();

    expect(changed).toBe(false);
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
    expect(enqueue).not.toHaveBeenCalled();
  });

  test("a scheme-less square.link value counts as a link and survives", async () => {
    storeSettings(settingsBlob({ square: "square.link/u/abc123" }));

    expect(await scrubLegacySquareToken()).toBe(false);
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });

  test("no square entry at all is a no-op", async () => {
    storeSettings(settingsBlob({ paypal: "johndoe" }));

    expect(await scrubLegacySquareToken()).toBe(false);
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });

  test("idempotent: the run after a scrub reports no change and writes nothing", async () => {
    let stored = settingsBlob({ square: "EAAAl_legacy_access_token" });
    AsyncStorage.getItem.mockImplementation((key) =>
      Promise.resolve(key === "settings" ? stored : null)
    );
    AsyncStorage.setItem.mockImplementation((key, value) => {
      if (key === "settings") stored = value;
      return Promise.resolve();
    });

    expect(await scrubLegacySquareToken()).toBe(true);
    expect(await scrubLegacySquareToken()).toBe(false);
  });
});
