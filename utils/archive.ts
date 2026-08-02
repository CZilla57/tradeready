// utils/archive.ts
// Soft-archive for jobs and customers: an optional `archivedAt` date on the
// record (absent = active — pre-existing records need no migration). Archived
// records are hidden from the Jobs list (except its Archived tab), the
// Customers list (except its Archived toggle), and global search. Everything
// else — Today, money math, invoices, notifications — deliberately still sees
// them: archiving tidies lists, it does not rewrite history.

import type { DateString } from "../types/models";

interface Archivable {
  archivedAt?: DateString;
}

export function isArchived(record: Archivable): boolean {
  return Boolean(record.archivedAt);
}

/**
 * Copy with the archive flag set or cleared. Clearing removes the key
 * entirely (not `undefined`) so persisted JSON stays clean; un-archiving an
 * active record is a same-reference no-op.
 */
export function withArchived<T extends Archivable>(record: T, archived: boolean, today: DateString): T {
  if (archived) return { ...record, archivedAt: today };
  if (!record.archivedAt) return record;
  const copy = { ...record };
  delete copy.archivedAt;
  return copy;
}

export function countArchived(list: Archivable[]): number {
  return list.filter(isArchived).length;
}
