// Sample-data id namespacing.
//
// The shipped seed data used fixed ids (c1..c3, j1..j3, "1".."4"). Cloud
// tables key rows by that id globally with per-user RLS — so the FIRST
// account to sync sample data owns those rows forever, and every later
// account's upserts of the same ids are rejected by RLS ("USING expression"
// violations, verified via Sentry 2026-07-14). Fix: every install namespaces
// its sample ids with a random suffix; a flag-free migration (see
// utils/storage/sampleMigration.ts) heals installs that already carry the
// legacy ids.

export const LEGACY_SAMPLE_IDS: Set<string> = new Set([
  "c1", "c2", "c3",
  "j1", "j2", "j3",
  "1", "2", "3", "4",
]);

// Matches a legacy id with or without a namespace suffix — and nothing else.
// Real ids (c<timestamp>_<n>, INV-0042, …) must never match: clearSampleData
// uses this to delete ONLY sample records.
const SAMPLE_ID_RE = /^(c[1-3]|j[1-3]|[1-4])(-s[a-z0-9]+)?$/;

export function freshSampleSuffix(): string {
  return "s" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

export function isSampleId(id: string): boolean {
  return SAMPLE_ID_RE.test(id);
}

interface WithId { id: string }
interface WithCustomerId { customerId?: string }

// Namespaces every legacy-id record with the given suffix, recording
// old→new in idMap so cross-references (job.customerId) can follow.
export function rewriteSampleIds<T extends WithId>(
  records: T[],
  suffix: string,
  idMap: Record<string, string>
): { changed: boolean; records: T[] } {
  let changed = false;
  const out = records.map((r) => {
    if (!LEGACY_SAMPLE_IDS.has(r.id)) return r;
    const next = `${r.id}-${suffix}`;
    idMap[r.id] = next;
    changed = true;
    return { ...r, id: next };
  });
  return { changed, records: out };
}

export function relinkCustomerIds<T extends WithCustomerId>(
  records: T[],
  idMap: Record<string, string>
): { changed: boolean; records: T[] } {
  let changed = false;
  const out = records.map((r) => {
    if (!r.customerId || !idMap[r.customerId]) return r;
    changed = true;
    return { ...r, customerId: idMap[r.customerId] };
  });
  return { changed, records: out };
}
