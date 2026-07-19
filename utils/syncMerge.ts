// utils/syncMerge.ts
// Decides how a record arriving from Supabase combines with the local copy.
//
// The historical rule — and still the rule for every table but one — is a
// whole-record replace: the cloud version wins outright. That is safe when
// every field is a scalar the two sides can't both meaningfully change.
//
// `invoices` is the exception. Its payment ledger can legitimately grow on
// BOTH sides at once (the Stripe webhook appends server-side while the
// tradesperson records a cash payment on the device), so replacing would
// destroy whichever side lost. Those records union instead.
//
// This is a deliberate, narrow exception to the JSON-blob replace rule
// described in ARCHITECTURE.md. Do not widen it to other tables without
// designing the merge for their shape — a blind union on the wrong record is
// worse than a replace.

import { mergePaymentLedgers, reconcilePaidFields } from "./invoicePayments";
import type { Invoice } from "../types/models";

/** The minimum a synced record must have: sync keys everything by id. */
export interface SyncRecord {
  id: string;
  [key: string]: unknown;
}

/**
 * Combine the incoming remote record with the local one.
 *
 * Returns the remote record itself (same reference) whenever the table does not
 * merge — callers rely on that being cheap. When there IS no local copy, an
 * invoice still can't be passed through verbatim: its blob may carry a `paid`
 * that predates a payment applied elsewhere (see reconcilePaidFields), so it
 * goes through the same derivation as a merge. reconcilePaidFields returns the
 * same object when the ledger is empty, so a legacy invoice is still cheap.
 */
export function mergeRemoteRecord(
  table: string,
  local: SyncRecord | undefined,
  remote: SyncRecord,
): SyncRecord {
  if (table !== "invoices") return remote;
  if (!local) {
    return reconcilePaidFields(remote as unknown as Invoice) as unknown as SyncRecord;
  }
  // Both sides are invoice blobs; mergePaymentLedgers owns the ledger rules.
  return mergePaymentLedgers(local as unknown as Invoice, remote as unknown as Invoice) as unknown as SyncRecord;
}
