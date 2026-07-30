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
