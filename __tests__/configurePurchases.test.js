// Regression guard for the launch crash found during the 2026-07-30 device smoke:
// RevenueCat's Browser Mode (Expo Go) rejects a live `appl_` key and throws from
// Purchases.configure(). configurePurchases() didn't catch it, so the error escaped
// AuthProvider's useEffect and tripped the root ErrorBoundary — the entire app became
// "Something went wrong. Please restart." The same would happen in production to every
// user if the key were ever rotated or mistyped.
//
// Every other wrapper in utils/subscription.ts already guards itself; this pins the
// one that didn't. The module reads its key at import time and lazily requires the
// native module, so each case re-imports it under isolated mocks.

const RC_KEY = "appl_notARealKey";

function loadSubscription(configureImpl) {
  let configure;
  let setLogLevel;
  let mod;
  jest.isolateModules(() => {
    jest.doMock("expo-constants", () => ({
      expoConfig: { extra: { rcAppleApiKey: RC_KEY, rcGoogleApiKey: RC_KEY } },
    }));
    configure = jest.fn(configureImpl);
    setLogLevel = jest.fn();
    jest.doMock("react-native-purchases", () => ({
      default: { configure, setLogLevel },
      LOG_LEVEL: { DEBUG: "debug" },
    }));
    mod = require("../utils/subscription");
  });
  return { mod, configure, setLogLevel };
}

describe("configurePurchases", () => {
  afterEach(() => {
    jest.dontMock("expo-constants");
    jest.dontMock("react-native-purchases");
  });

  test("treats the key as configured when the native module and a key are present", () => {
    const { mod } = loadSubscription(() => {});
    expect(mod.RC_CONFIGURED).toBe(true);
  });

  test("passes the api key through when configure succeeds", () => {
    const { mod, configure } = loadSubscription(() => {});
    mod.configurePurchases();
    expect(configure).toHaveBeenCalledWith({ apiKey: RC_KEY });
  });

  test("does not throw when RevenueCat rejects the key", () => {
    const { mod, configure } = loadSubscription(() => {
      throw new Error(
        "Invalid API key. The native store is not available when running inside Expo Go"
      );
    });
    // The assertion that matters: this must not propagate. If it does, AuthProvider's
    // effect throws and the app renders the ErrorBoundary fallback instead of the app.
    expect(() => mod.configurePurchases()).not.toThrow();
    expect(configure).toHaveBeenCalled();
  });
});
