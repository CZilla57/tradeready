// Which logo image files may be deleted once settings are committed.
// The Settings screen edits a draft, so a file is only deletable when the
// PERSISTED settings no longer reference it — otherwise "Discard" would
// destroy an image the saved settings still point at.

const {
  orphanedLogoPaths,
  sweepableLogoPaths,
  LOGO_SWEEP_MIN_AGE_MS,
} = require("../utils/logoLifecycle");

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

// The folder sweep. Per-session cleanup only knows the paths one session
// touched, so it can never reclaim a file stranded by an abandoned edit or a
// cleanup that was interrupted part-way. The sweep reads the folder itself and
// applies the same keep-the-referenced-file rule, plus an age guard: a file
// younger than LOGO_SWEEP_MIN_AGE_MS is never swept, so even an unforeseen race
// cannot destroy a logo the user just picked.

const NOW = 1_800_000_000_000;
const OLD = NOW - LOGO_SWEEP_MIN_AGE_MS - 1;          // safely sweepable
const RECENT = NOW - 1000;                            // one second ago

// persistPhoto names files `${Date.now()}_${random}.jpg`.
const at = (ms, tag = "x") => `file:///docs/logos/${ms}_${tag}.jpg`;

describe("sweepableLogoPaths", () => {
  test("an old unreferenced file is swept", () => {
    expect(sweepableLogoPaths([at(OLD)], null, NOW)).toEqual([at(OLD)]);
  });

  test("the referenced file is never swept, however old", () => {
    const keep = at(OLD, "keep");
    expect(sweepableLogoPaths([keep, at(OLD, "junk")], keep, NOW)).toEqual([at(OLD, "junk")]);
  });

  test("a just-picked file is protected by the age guard", () => {
    expect(sweepableLogoPaths([at(RECENT)], null, NOW)).toEqual([]);
  });

  test("a file exactly at the age threshold is old enough to sweep", () => {
    const boundary = at(NOW - LOGO_SWEEP_MIN_AGE_MS);
    expect(sweepableLogoPaths([boundary], null, NOW)).toEqual([boundary]);
  });

  test("a future timestamp is treated as young and kept (clock skew)", () => {
    expect(sweepableLogoPaths([at(NOW + 60_000)], null, NOW)).toEqual([]);
  });

  test("a filename that does not carry a timestamp is swept", () => {
    // Not produced by persistPhoto's naming, so it cannot be a recent pick.
    const foreign = "file:///docs/logos/legacy-logo.jpg";
    expect(sweepableLogoPaths([foreign], null, NOW)).toEqual([foreign]);
  });

  test("no logo referenced — every old file is reclaimed", () => {
    const files = [at(OLD, "a"), at(OLD, "b")];
    expect(sweepableLogoPaths(files, "", NOW)).toEqual(files);
  });

  test("an empty folder sweeps nothing", () => {
    expect(sweepableLogoPaths([], null, NOW)).toEqual([]);
  });

  test("mixed folder: keeps the referenced and the recent, sweeps the rest", () => {
    const keep = at(OLD, "keep");
    const result = sweepableLogoPaths(
      [keep, at(RECENT, "justpicked"), at(OLD, "abandoned"), at(OLD, "interrupted")],
      keep,
      NOW
    );
    expect(result).toEqual([at(OLD, "abandoned"), at(OLD, "interrupted")]);
  });

  test("the age guard is configurable", () => {
    // With a zero-length window even a brand-new file is sweepable.
    expect(sweepableLogoPaths([at(RECENT)], null, NOW, 0)).toEqual([at(RECENT)]);
  });

  test("defaults to the real clock when now is omitted", () => {
    // A file stamped in the distant past is sweepable against the actual Date.now().
    expect(sweepableLogoPaths([at(1)], null)).toEqual([at(1)]);
  });
});
