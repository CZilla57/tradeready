// utils/recurringAutoSend.ts
// Phase 6 — pick the single generated recurring invoice (if any) to stamp for
// auto-delivery. Pure. The CURRENT occurrence only (the newest generated this
// run): a dormant plan that generates a backlog of past-due occurrences must
// never auto-email the whole batch. Reuses the same plausible-email gate the
// job-completion auto-email path uses (isPlausiblyEmailable), so a plan can't
// silently queue a send to an address the backend sweep would refuse.

import type { Invoice } from "../types/models";
import { isPlausiblyEmailable } from "./autoInvoice";

export function selectRecurringInvoiceToAutoSend(
  createdForRule: Invoice[],
  opts: { ruleAutoSendEnabled?: boolean; masterEnabled: boolean; customerEmail?: string },
): Invoice | null {
  if (!opts.ruleAutoSendEnabled) return null;
  if (!opts.masterEnabled) return null;
  if (!isPlausiblyEmailable((opts.customerEmail || "").trim())) return null;
  if (createdForRule.length === 0) return null;
  return createdForRule.reduce((newest, inv) =>
    (inv.occurrenceNumber ?? 0) > (newest.occurrenceNumber ?? 0) ? inv : newest,
  );
}
