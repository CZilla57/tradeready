// __tests__/onboardingFlow.test.js
// Pins the 2026-08-03 flow restructure's stage machine and draft autosave:
//   1. The starting-point choice is owed ONLY between personalization and the
//      explicit choice — an absent stage key (legacy users, returning users
//      restored from the cloud) must never re-prompt, because re-prompting
//      could re-seed sample data into a real account.
//   2. completeStartChoice executes the choice (seed vs. clear) and closes
//      the stage.
//   3. The wizard draft round-trips and survives corruption.

import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  markOnboardingPersonalized,
  isStartChoiceComplete,
  completeStartChoice,
} from "../utils/storage";
import {
  loadOnboardingDraft,
  saveOnboardingDraft,
  clearOnboardingDraft,
  ONBOARDING_DRAFT_KEY,
} from "../utils/onboardingDraft";

// Same isolation as storage.test.js: keep sync / notification / widget side
// effects out of these assertions.
jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));

jest.mock("../utils/notifications", () => ({
  syncNotifications: jest.fn(),
}));

jest.mock("../utils/widgetBridge", () => ({
  refreshWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
  clearWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
}));

// In-memory AsyncStorage so stage reads see prior writes within a test.
let store = {};
beforeEach(() => {
  jest.clearAllMocks();
  store = {};
  AsyncStorage.getItem.mockImplementation((k) => Promise.resolve(store[k] ?? null));
  AsyncStorage.setItem.mockImplementation((k, v) => { store[k] = v; return Promise.resolve(); });
  AsyncStorage.removeItem.mockImplementation((k) => { delete store[k]; return Promise.resolve(); });
});

describe("starting-point stage machine", () => {
  test("absent stage key means no choice is owed (legacy / returning users)", async () => {
    expect(await isStartChoiceComplete()).toBe(true);
  });

  test("personalization opens the gate; the explicit choice closes it", async () => {
    await markOnboardingPersonalized();
    expect(await isStartChoiceComplete()).toBe(false);

    await completeStartChoice("fresh", "plumbing");
    expect(await isStartChoiceComplete()).toBe(true);
  });

  test("choosing fresh clears the sample seeds", async () => {
    await markOnboardingPersonalized();
    await completeStartChoice("fresh", "plumbing");
    // clearSampleData saves each collection through the normal save path;
    // with a cold cache the seeds re-materialize and are filtered to empty.
    const written = JSON.parse(store["invoices"]);
    expect(written).toEqual([]);
  });

  test("choosing sample seeds trade-matched sample invoices", async () => {
    await markOnboardingPersonalized();
    await completeStartChoice("sample", "electrical");
    const written = JSON.parse(store["invoices"]);
    expect(written.length).toBeGreaterThan(0);
    expect(await isStartChoiceComplete()).toBe(true);
  });
});

describe("onboarding draft autosave", () => {
  test("round-trips the typed form and step", async () => {
    const draft = { businessName: "ABC Plumbing", contactName: "Jo", trade: "plumbing", step: 1 };
    await saveOnboardingDraft(draft);
    expect(await loadOnboardingDraft()).toEqual(draft);
  });

  test("returns null when empty, corrupt, or structurally wrong", async () => {
    expect(await loadOnboardingDraft()).toBeNull();
    store[ONBOARDING_DRAFT_KEY] = "{not json";
    expect(await loadOnboardingDraft()).toBeNull();
    store[ONBOARDING_DRAFT_KEY] = JSON.stringify({ businessName: 42 });
    expect(await loadOnboardingDraft()).toBeNull();
  });

  test("clearOnboardingDraft removes the draft", async () => {
    await saveOnboardingDraft({ businessName: "A", contactName: "B", trade: "hvac", step: 0 });
    await clearOnboardingDraft();
    expect(await loadOnboardingDraft()).toBeNull();
  });
});
