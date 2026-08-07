// utils/syncMerge.ts
// Decides how a record arriving from Supabase combines with the local copy.
//
// The historical rule — and still the rule for every table but one — is a
// whole-record replace: the cloud version wins outright. That is safe when
// every field is a scalar the two sides can't both meaningfully change.
//
// TWO exceptions exist, each designed for its shape:
//
// `invoices` — the payment ledger can legitimately grow on BOTH sides at
// once (the Stripe webhook appends server-side while the tradesperson
// records a cash payment on the device), so replacing would destroy
// whichever side lost. Those records union by payment id.
//
// `bookingRequests` — the `history` audit trail is SERVER-appended
// (customer manage actions) while the device stamps conversion fields on
// the same blob, so a device push racing a server append could drop a
// history entry; the pull side unions history by (at, actor, event) while
// every other field stays last-write-wins (Phase 11 D7, owner-approved
// 2026-08-07). Push remains whole-blob replace — same residual as the
// invoice ledger, documented in ARCHITECTURE.md.
//
// These are deliberate, narrow exceptions to the JSON-blob replace rule
// described in ARCHITECTURE.md. Do not widen them to other tables without
// designing the merge for their shape — a blind union on the wrong record is
// worse than a replace.

import { mergePaymentLedgers, reconcilePaidFields } from "./invoicePayments";
import type { BookingHistoryEntry, Invoice } from "../types/models";

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
  if (table === "invoices") {
    if (!local) {
      return reconcilePaidFields(remote as unknown as Invoice) as unknown as SyncRecord;
    }
    // Both sides are invoice blobs; mergePaymentLedgers owns the ledger rules.
    return mergePaymentLedgers(local as unknown as Invoice, remote as unknown as Invoice) as unknown as SyncRecord;
  }
  if (table === "bookingRequests" && local) {
    return mergeBookingHistories(local, remote);
  }
  return remote;
}

/** History union for a booking request: remote wins every scalar (normal
 *  LWW); history entries union by (at, actor, event) and sort by timestamp.
 *  Returns the remote reference untouched when the local side adds nothing —
 *  callers rely on that being cheap. */
function mergeBookingHistories(local: SyncRecord, remote: SyncRecord): SyncRecord {
  const localH = (local.history as BookingHistoryEntry[] | undefined) ?? [];
  const remoteH = (remote.history as BookingHistoryEntry[] | undefined) ?? [];
  if (localH.length === 0) return remote;

  const key = (e: BookingHistoryEntry) => `${e.at}|${e.actor}|${e.event}`;
  const seen = new Set(remoteH.map(key));
  const extra = localH.filter((e) => !seen.has(key(e)));
  if (extra.length === 0) return remote;

  const history = [...remoteH, ...extra].sort((a, b) => a.at.localeCompare(b.at));
  return { ...remote, history };
}
