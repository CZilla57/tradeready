// utils/bookingAttention.ts
// Which bookings need the owner's eyes on Today (Phase 11 D4, 2026-08-07
// spec §7). Pure selector, mirrors the Today-insights philosophy: rows
// disappear on their own as the underlying condition resolves.
//
// - reschedule_requested: surfaced until the owner responds (via the
//   respond endpoint — utils/bookingRespond.ts).
// - cancelled / owner-declined: surfaced ONLY while the converted job still
//   holds the slot on the calendar. Clearing, moving, archiving, or
//   terminal-ing the job self-dismisses the row — no lingering badges.

import type { BookingRequest, Job } from "../types/models";
import { TERMINAL_STATUSES } from "./scheduleSmarts";
import { isArchived } from "./archive";

export type BookingAttention =
  | { kind: "reschedule_requested"; request: BookingRequest; jobId?: string; note?: string }
  | { kind: "cancelled"; request: BookingRequest; jobId?: string };

function lastRescheduleNote(request: BookingRequest): string | undefined {
  const entries = (request.history ?? []).filter(
    (h) => h.actor === "customer" && h.event === "request_reschedule" && h.note
  );
  return entries.length > 0 ? entries[entries.length - 1].note : undefined;
}

/** True while the converted job still occupies the booked slot. */
function jobStillHoldsSlot(request: BookingRequest, jobs: Job[]): boolean {
  if (!request.convertedJobId || !request.slot) return false;
  const job = jobs.find((j) => j.id === request.convertedJobId);
  if (!job) return false;
  if (isArchived(job) || TERMINAL_STATUSES.has(job.status)) return false;
  return (
    job.scheduledDate === request.slot.date &&
    job.scheduledStartTime === request.slot.start
  );
}

export function selectBookingAttention(
  requests: BookingRequest[],
  jobs: Job[]
): BookingAttention[] {
  const out: BookingAttention[] = [];
  for (const r of requests) {
    if (r.kind !== "booked" || !r.slot) continue;
    if (r.status === "reschedule_requested") {
      out.push({
        kind: "reschedule_requested",
        request: r,
        jobId: r.convertedJobId,
        note: lastRescheduleNote(r),
      });
    } else if (
      (r.status === "cancelled" || r.status === "declined") &&
      jobStillHoldsSlot(r, jobs)
    ) {
      out.push({ kind: "cancelled", request: r, jobId: r.convertedJobId });
    }
  }
  return out.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "reschedule_requested" ? -1 : 1;
    return (a.request.slot?.date ?? "").localeCompare(b.request.slot?.date ?? "");
  });
}
