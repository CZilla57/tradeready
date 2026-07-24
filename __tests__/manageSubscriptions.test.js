// Regression coverage for the "Manage subscription" button that App Review
// rejected in 1.0(5) under guideline 2.1(a) — it surfaced an error on an iPad
// running the iPhone-compatibility build against a sandbox account.
//
// react-native-purchases is not linked under Jest, so the lazy require in
// utils/subscription.ts fails and RC_CONFIGURED is false. That exercises
// exactly the path that matters here: the store deep-link fallback and its
// failure mode.

describe("openManageSubscriptions", () => {
  let openManageSubscriptions;
  let Linking;
  let Platform;

  // react-native must be required AFTER resetModules so the Linking object
  // spied on here is the same instance utils/subscription.ts imports.
  beforeEach(() => {
    jest.resetModules();
    jest.restoreAllMocks();
    ({ Linking, Platform } = require("react-native"));
    ({ openManageSubscriptions } = require("../utils/subscription"));
  });

  test("opens the store deep link and reports success", async () => {
    const spy = jest.spyOn(Linking, "openURL").mockResolvedValue(undefined);

    await expect(openManageSubscriptions()).resolves.toBe(true);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  test("uses the itms-apps scheme on iOS, not an https App Store page", async () => {
    // The https URL is what shipped in 1.0(5); a sandbox Apple ID cannot load
    // it, which is how the reviewer ended up looking at an error.
    if (Platform.OS !== "ios") return;
    const spy = jest.spyOn(Linking, "openURL").mockResolvedValue(undefined);

    await openManageSubscriptions();

    expect(spy).toHaveBeenCalledWith("itms-apps://apps.apple.com/account/subscriptions");
  });

  test("returns false instead of throwing when the deep link cannot open", async () => {
    // The regression: openURL was previously called without await or catch, so
    // this rejection escaped as an unhandled promise rejection.
    jest.spyOn(Linking, "openURL").mockRejectedValue(new Error("no handler"));

    await expect(openManageSubscriptions()).resolves.toBe(false);
  });
});
