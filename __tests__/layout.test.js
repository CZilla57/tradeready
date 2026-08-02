// __tests__/layout.test.js
// iPad Tier 1 Phase 1: shared responsive layout tokens for content-column centering.
// The token must be spreadable in StyleSheet.create styles and usable inline;
// it is designed to be a no-op on phone (maxWidth exceeds the widest phone logical width).

import { layout } from "../utils/theme";

describe("layout token", () => {
  test("contentMaxWidth is 700", () => {
    expect(layout.contentMaxWidth).toBe(700);
  });

  test("contentColumn has the correct shape", () => {
    expect(layout.contentColumn).toEqual({
      width: "100%",
      maxWidth: 700,
      alignSelf: "center",
    });
  });

  test("contentMaxWidth is a no-op on phones (exceeds widest phone logical width of 440pt)", () => {
    // 440pt is the logical width of the iPhone Pro Max (the widest phone class).
    // When maxWidth > 440, the constraint never activates on any phone device,
    // so Tier 1 introduces no breakpoint hook or rendering change on phones.
    expect(layout.contentMaxWidth).toBeGreaterThan(440);
  });
});
