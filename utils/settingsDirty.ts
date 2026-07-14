// Structural equality for Settings dirty-detection. The Settings screen edits
// a local copy and only persists on "Save settings"; comparing the edited copy
// against the last-saved snapshot is what decides whether to warn on leave.
// Handles the JSON-ish shapes Settings actually contains (primitives, the
// rules array, the providerKeys map). Object keys holding undefined count as
// absent, since spreads and optional fields produce them interchangeably.

export function settingsEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;

  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((item, i) => settingsEqual(item, b[i]));
  }

  if (typeof a === "object" && typeof b === "object" && a !== null && b !== null) {
    const definedKeys = (o: object) =>
      Object.keys(o).filter((k) => (o as Record<string, unknown>)[k] !== undefined);
    const keysA = definedKeys(a);
    const keysB = definedKeys(b);
    if (keysA.length !== keysB.length) return false;
    return keysA.every((k) =>
      settingsEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k])
    );
  }

  return false;
}
