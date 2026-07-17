// __tests__/Field.test.js
// The shared Field's smart autoCapitalize default. Multiline fields hold
// prose (job descriptions, customer notes) — Title-Casing Every Word there
// was a reported annoyance (2026-07-16); single-line fields keep "words"
// (names, titles, addresses) and email keyboards keep "none".
//
// Also: every Field keyboard must be dismissible (owner requirement,
// 2026-07-16) — single-line inputs get returnKeyType "done", and multiline /
// iOS pad keyboards (no return key) get a KeyboardDoneBar accessory.

import React from "react";
import { Platform } from "react-native";
import { render } from "@testing-library/react-native";
import Field from "../components/Field";

const noop = () => {};

async function capFor(props) {
  const { getByLabelText } = await render(
    <Field label="Test field" value="" onChangeText={noop} {...props} />
  );
  return getByLabelText("Test field").props.autoCapitalize;
}

describe("Field autoCapitalize default", () => {
  test("single-line fields default to words", async () => {
    expect(await capFor({})).toBe("words");
  });

  test("multiline (prose) fields default to sentences", async () => {
    expect(await capFor({ multiline: true })).toBe("sentences");
  });

  test("email keyboards default to none", async () => {
    expect(await capFor({ keyboardType: "email-address" })).toBe("none");
  });

  test("an explicit prop always wins", async () => {
    expect(await capFor({ multiline: true, autoCapitalize: "characters" })).toBe("characters");
    expect(await capFor({ autoCapitalize: "none" })).toBe("none");
  });
});

describe("Field keyboard dismissal", () => {
  const originalOS = Platform.OS;
  beforeEach(() => { Platform.OS = "ios"; });
  afterEach(() => { Platform.OS = originalOS; });

  async function inputFor(props) {
    const result = await render(
      <Field label="Test field" value="" onChangeText={noop} {...props} />
    );
    return { input: result.getByLabelText("Test field"), ...result };
  }

  test("single-line fields default to a Done return key", async () => {
    const { input } = await inputFor({});
    expect(input.props.returnKeyType).toBe("done");
  });

  test("an explicit returnKeyType wins", async () => {
    const { input } = await inputFor({ returnKeyType: "search" });
    expect(input.props.returnKeyType).toBe("search");
  });

  test("multiline keeps return = newline but gets a Done accessory bar", async () => {
    const { input, getByRole } = await inputFor({ multiline: true });
    expect(input.props.returnKeyType).toBeUndefined();
    expect(input.props.inputAccessoryViewID).toBeTruthy();
    expect(getByRole("button", { name: "Dismiss keyboard" })).toBeTruthy();
  });

  // One render per test — RNTL v14's async render does not support several
  // renders inside a single test (overlapping act() scopes).
  test.each(["decimal-pad", "number-pad", "phone-pad"])(
    "%s keyboards (no return key on iOS) get a Done accessory bar",
    async (keyboardType) => {
      const { input, getByRole } = await inputFor({ keyboardType });
      expect(input.props.inputAccessoryViewID).toBeTruthy();
      expect(getByRole("button", { name: "Dismiss keyboard" })).toBeTruthy();
    }
  );

  test("plain single-line keyboards need no accessory bar", async () => {
    const { input, queryByRole } = await inputFor({});
    expect(input.props.inputAccessoryViewID).toBeUndefined();
    expect(queryByRole("button", { name: "Dismiss keyboard" })).toBeNull();
  });
});
