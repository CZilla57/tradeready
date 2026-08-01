/**
 * Decides which logo image files may be deleted from disk.
 *
 * The Settings screen edits a draft: logo changes are not persisted until the
 * user taps Save, and "Discard" must restore the previous image. A logo file is
 * therefore only deletable once the PERSISTED settings no longer reference it.
 *
 * Callers accumulate every logo path touched during the session (the one loaded
 * from settings, plus each file copied in by the picker) and pass the path the
 * persisted settings now hold. Everything else is an orphan.
 */
export function orphanedLogoPaths(
  touched: readonly string[],
  keepPath: string | null | undefined,
): string[] {
  const seen = new Set<string>();
  const orphans: string[] = [];
  for (const path of touched) {
    if (!path || path === keepPath || seen.has(path)) continue;
    seen.add(path);
    orphans.push(path);
  }
  return orphans;
}

/** A logo file younger than this is never swept. See sweepableLogoPaths. */
export const LOGO_SWEEP_MIN_AGE_MS = 5 * 60 * 1000;

/**
 * `persistPhoto` names every file `${Date.now()}_${random}.<ext>` (`.png` for a
 * logo that the pick-time resize re-encoded, `.jpg` otherwise), so a file's
 * creation time is recoverable from its name — no stat call per file. Only the
 * timestamp prefix is parsed, so the extension is irrelevant here.
 *
 * A name that does not parse was not produced by that scheme, so it cannot be a
 * recent pick and is not treated as young. A timestamp in the future (clock
 * skew, or a file restored from a backup) yields a negative age and IS treated
 * as young, which errs toward keeping the file.
 */
function isRecentlyCreated(path: string, now: number, minAgeMs: number): boolean {
  const filename = path.slice(path.lastIndexOf("/") + 1);
  const match = /^(\d+)_/.exec(filename);
  if (!match) return false;
  const created = Number(match[1]);
  if (!Number.isFinite(created)) return false;
  return now - created < minAgeMs;
}

/**
 * Which files in the logos folder may be reclaimed, given everything currently
 * on disk and the path the PERSISTED settings reference.
 *
 * This is the same rule as orphanedLogoPaths — keep the referenced file, drop
 * the rest — applied to a directory listing rather than one session's history,
 * so it also reclaims files stranded by an abandoned edit or a cleanup that was
 * interrupted part-way.
 *
 * The age guard is deliberate belt-and-braces. Callers run this before the
 * picker is reachable, so nothing should be able to pick a logo mid-sweep; the
 * guard means that even if some future path does, a just-created file survives.
 * `now` is injectable so tests need no clock mocking.
 */
export function sweepableLogoPaths(
  allPaths: readonly string[],
  keepPath: string | null | undefined,
  now: number = Date.now(),
  minAgeMs: number = LOGO_SWEEP_MIN_AGE_MS,
): string[] {
  return orphanedLogoPaths(allPaths, keepPath).filter(
    (path) => !isRecentlyCreated(path, now, minAgeMs),
  );
}
