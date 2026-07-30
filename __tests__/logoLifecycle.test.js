// Which logo image files may be deleted once settings are committed.
// The Settings screen edits a draft, so a file is only deletable when the
// PERSISTED settings no longer reference it — otherwise "Discard" would
// destroy an image the saved settings still point at.

const { orphanedLogoPaths } = require("../utils/logoLifecycle");

const ORIGINAL = "file:///docs/logos/original.jpg";
const PICKED_A = "file:///docs/logos/a.jpg";
const PICKED_B = "file:///docs/logos/b.jpg";

describe("orphanedLogoPaths", () => {
  // Two user scenarios collapse to this same call: the logo was never touched, and
  // the logo was removed in the draft then the edit was discarded. Removing adds
  // nothing to `touched`, so in both cases the persisted path is the keeper.
  test("keepPath present in touched — nothing is deleted (untouched, or removed then discarded)", () => {
    expect(orphanedLogoPaths([ORIGINAL], ORIGINAL)).toEqual([]);
  });

  test("replaced then saved — the old file is orphaned", () => {
    expect(orphanedLogoPaths([ORIGINAL, PICKED_A], PICKED_A)).toEqual([ORIGINAL]);
  });

  test("removed then saved — the old file is orphaned", () => {
    expect(orphanedLogoPaths([ORIGINAL], "")).toEqual([ORIGINAL]);
  });

  test("picked then discarded — the new copy is orphaned, the saved one survives", () => {
    expect(orphanedLogoPaths([ORIGINAL, PICKED_A], ORIGINAL)).toEqual([PICKED_A]);
  });

  test("picked twice then saved — every superseded file is orphaned", () => {
    expect(orphanedLogoPaths([ORIGINAL, PICKED_A, PICKED_B], PICKED_B))
      .toEqual([ORIGINAL, PICKED_A]);
  });

  test("no prior logo, picked then discarded — the new copy is orphaned", () => {
    expect(orphanedLogoPaths(["", PICKED_A], "")).toEqual([PICKED_A]);
  });

  test("empty strings are never returned as deletable paths", () => {
    expect(orphanedLogoPaths(["", ""], PICKED_A)).toEqual([]);
  });

  test("duplicates collapse to a single deletion", () => {
    expect(orphanedLogoPaths([PICKED_A, PICKED_A], "")).toEqual([PICKED_A]);
  });

  test("null and undefined keepPath behave like no logo", () => {
    expect(orphanedLogoPaths([PICKED_A], null)).toEqual([PICKED_A]);
    expect(orphanedLogoPaths([PICKED_A], undefined)).toEqual([PICKED_A]);
  });

  test("no touched paths — nothing to delete", () => {
    expect(orphanedLogoPaths([], PICKED_A)).toEqual([]);
  });
});
