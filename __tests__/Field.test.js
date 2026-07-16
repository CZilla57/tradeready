// __tests__/Field.test.js
// The shared Field's smart autoCapitalize default. Multiline fields hold
// prose (job descriptions, customer notes) — Title-Casing Every Word there
// was a reported annoyance (2026-07-16); single-line fields keep "words"
// (names, titles, addresses) and email keyboards keep "none".

import React from "react";
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
