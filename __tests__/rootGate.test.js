// __tests__/rootGate.test.js
// The root loading gate must hold while initialSync restores a wiped device.
// Regression pin for the 2026-07-16 incident: evaluating the onboarding gate
// before the cloud pull landed re-onboarded every returning user, and the
// onboarding save clobbered their pulled settings. During that bootstrap
// window the App.tsx effect keeps onboardingDone at null, so null → loading
// is the load-bearing branch here. startChoiceDone (the post-paywall
// sample-vs-fresh gate, 2026-08-03) follows the same null-means-unknown
// contract.

import { rootGateLoading } from "../utils/rootGate";

const base = {
  initializing: false,
  hasSession: true,
  onboardingDone: true,
  startChoiceDone: true,
  subLoading: false,
};

describe("rootGateLoading", () => {
  test("app boot shows loading until auth initializes", () => {
    expect(rootGateLoading({ ...base, initializing: true, hasSession: false, onboardingDone: null, startChoiceDone: null })).toBe(true);
  });

  test("signed out renders Auth immediately (not loading)", () => {
    expect(rootGateLoading({ ...base, hasSession: false, onboardingDone: null, startChoiceDone: null })).toBe(false);
  });

  test("REGRESSION: no onboarding answer yet (initialSync in flight) holds the spinner", () => {
    expect(rootGateLoading({ ...base, onboardingDone: null, startChoiceDone: null })).toBe(true);
  });

  test("after bootstrap, a genuinely new user reaches onboarding (not loading)", () => {
    expect(rootGateLoading({ ...base, onboardingDone: false, startChoiceDone: null })).toBe(false);
  });

  test("after bootstrap, a returning user waits only on the subscription check", () => {
    expect(rootGateLoading({ ...base, subLoading: true })).toBe(true);
    expect(rootGateLoading(base)).toBe(false);
  });

  test("onboarding done but start choice unanswered holds the spinner", () => {
    expect(rootGateLoading({ ...base, startChoiceDone: null })).toBe(true);
  });

  test("start choice owed (false, not null) renders the StartingPoint gate, not the spinner", () => {
    expect(rootGateLoading({ ...base, startChoiceDone: false })).toBe(false);
  });

  test("during onboarding the start-choice answer is irrelevant", () => {
    // The wizard renders regardless — its own completion callback seeds
    // startChoiceDone before the gate re-evaluates.
    expect(rootGateLoading({ ...base, onboardingDone: false, startChoiceDone: false })).toBe(false);
  });

  test("mid-session refresh with onboarding already known does not flash the spinner", () => {
    // A token refresh re-raises AuthContext.bootstrapping, but the effect
    // early-returns and onboardingDone keeps its value — known value = no
    // spinner, by design.
    expect(rootGateLoading(base)).toBe(false);
  });
});
