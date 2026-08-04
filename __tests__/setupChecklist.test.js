// __tests__/setupChecklist.test.js
// The in-product setup checklist (2026-08-03 onboarding restructure): task
// completion must derive from settings where possible and from recorded state
// only where no derivation exists; the stored state must round-trip and
// tolerate corruption.

import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  deriveSetupTasks,
  loadSetupChecklistState,
  markSetupTaskDone,
  dismissSetupChecklist,
  markSampleTourDone,
  SETUP_CHECKLIST_STATE_KEY,
} from "../utils/setupChecklist";

const baseSettings = {
  businessName: "ABC Plumbing",
  contactName: "Jo",
  phone: "",
  email: "",
  address: "",
  logoPhoto: "",
  provider: "stripe",
  providerKeys: {},
  laborRate: 85,
};

function taskById(tasks, id) {
  return tasks.find((t) => t.id === id);
}

beforeEach(() => {
  jest.clearAllMocks();
  AsyncStorage.getItem.mockResolvedValue(null);
  AsyncStorage.setItem.mockResolvedValue(undefined);
});

describe("deriveSetupTasks", () => {
  test("fresh settings: only notifications-granted can be done", () => {
    const tasks = deriveSetupTasks(baseSettings, {}, false);
    expect(tasks).toHaveLength(5);
    expect(tasks.every((t) => !t.done)).toBe(true);
  });

  test("contact derives from phone AND address", () => {
    expect(taskById(deriveSetupTasks({ ...baseSettings, phone: "(555) 111-2222" }, {}, false), "contact").done).toBe(false);
    expect(
      taskById(
        deriveSetupTasks({ ...baseSettings, phone: "(555) 111-2222", address: "1 Main St" }, {}, false),
        "contact"
      ).done
    ).toBe(true);
  });

  test("logo derives from logoPhoto", () => {
    expect(taskById(deriveSetupTasks({ ...baseSettings, logoPhoto: "file://logo.png" }, {}, false), "logo").done).toBe(true);
  });

  test("rate completes only via recorded state (saving Settings)", () => {
    expect(taskById(deriveSetupTasks(baseSettings, {}, false), "rate").done).toBe(false);
    expect(taskById(deriveSetupTasks(baseSettings, { done: { rate: true } }, false), "rate").done).toBe(true);
  });

  test("stripe completes via recorded connect status OR a configured alternative processor", () => {
    expect(taskById(deriveSetupTasks(baseSettings, { done: { stripe: true } }, false), "stripe").done).toBe(true);
    const venmoSettings = { ...baseSettings, provider: "venmo", providerKeys: { venmo: "jo-the-plumber" } };
    expect(taskById(deriveSetupTasks(venmoSettings, {}, false), "stripe").done).toBe(true);
    // A configured key for a DIFFERENT provider than the selected one doesn't count.
    const mismatched = { ...baseSettings, provider: "venmo", providerKeys: { paypal: "jo" } };
    expect(taskById(deriveSetupTasks(mismatched, {}, false), "stripe").done).toBe(false);
  });

  test("notifications derives from the granted flag", () => {
    expect(taskById(deriveSetupTasks(baseSettings, {}, true), "notifications").done).toBe(true);
  });
});

describe("checklist state persistence", () => {
  test("loadSetupChecklistState returns {} for missing or corrupt payloads", async () => {
    expect(await loadSetupChecklistState()).toEqual({});
    AsyncStorage.getItem.mockResolvedValue("not-json{");
    expect(await loadSetupChecklistState()).toEqual({});
  });

  test("markSetupTaskDone records the task and preserves existing state", async () => {
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify({ done: { rate: true } }));
    await markSetupTaskDone("stripe");
    const [key, written] = AsyncStorage.setItem.mock.calls[0];
    expect(key).toBe(SETUP_CHECKLIST_STATE_KEY);
    expect(JSON.parse(written)).toEqual({ done: { rate: true, stripe: true } });
  });

  test("markSetupTaskDone skips the write when already recorded", async () => {
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify({ done: { rate: true } }));
    await markSetupTaskDone("rate");
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });

  test("dismissSetupChecklist keeps recorded completions", async () => {
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify({ done: { stripe: true } }));
    await dismissSetupChecklist();
    const [, written] = AsyncStorage.setItem.mock.calls[0];
    expect(JSON.parse(written)).toEqual({ done: { stripe: true }, dismissed: true });
  });

  test("markSampleTourDone stamps the hero flag once", async () => {
    await markSampleTourDone();
    const [, written] = AsyncStorage.setItem.mock.calls[0];
    expect(JSON.parse(written)).toEqual({ sampleTourDone: true });
    AsyncStorage.getItem.mockResolvedValue(written);
    AsyncStorage.setItem.mockClear();
    await markSampleTourDone();
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });
});
