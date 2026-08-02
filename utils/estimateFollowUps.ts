// utils/estimateFollowUps.ts
// Pure logic for estimate follow-up nudges — which silent estimates get a
// one-shot "no response" reminder and when, plus the prefilled follow-up
// message and the shared status+timestamp stamp for every send path. NO I/O
// and no Expo/RN imports — everything here is unit-testable directly
// (mirrors utils/appointmentMessages.ts). The scheduling I/O lives in
// utils/notifications.ts; the compose I/O in EstimateFollowUpScreen.
import type { Job, DateString } from "../types/models";
import { parseLocalDate } from "./moneyUtils";
import { formatLocalDate } from "./recurrence";
import { formatQuote } from "./format";

/** Days of silence after a send before the one-shot nudge fires. */
export const FOLLOW_UP_DAYS = 3;

export type EstimateFollowUpReminder = {
  jobId: string;
  customerName: string;
  jobTitle: string;
  fireDate: Date;
};

/**
 * When the estimate was last sent, or null when unknowable (legacy manual
 * sends predating estimateSentAt). estimateSentAt (local "YYYY-MM-DD") wins
 * over approval.sentAt (backend ISO timestamp). parseLocalDate handles both
 * shapes defensively — strict date → local midnight, anything else →
 * new Date(raw) — and the NaN guard keeps a malformed value from producing
 * NaN fire-date math (same defect class as the malformed-due fix, 2026-08-01).
 */
export function estimateSentDate(job: Job): Date | null {
  const raw: DateString | undefined = job.estimateSentAt ?? job.approval?.sentAt;
  if (!raw) return null;
  const d = parseLocalDate(raw);
  return Number.isFinite(d.getTime()) ? d : null;
}

/**
 * The status flip + local-frame stamp in ONE place so the three send sites
 * (SendEstimateScreen.markAsSent, estimateApprovalLink's two writes,
 * JobDetail's revise-and-resend) can never drift. Callers spread extras
 * (e.g. the approval object) on top of the returned job.
 */
export function stampEstimateSent(job: Job, now: Date): Job {
  return { ...job, status: "estimate_sent", estimateSentAt: formatLocalDate(now) };
}

/** sent + FOLLOW_UP_DAYS at 9:00am LOCAL — same local-frame construction as
 * the inv_/rinv_ branches in utils/notifications.ts (FA-039). */
function fireDateFor(sent: Date): Date {
  const fire = new Date(sent.getFullYear(), sent.getMonth(), sent.getDate(), 9, 0, 0, 0);
  fire.setDate(fire.getDate() + FOLLOW_UP_DAYS);
  return fire;
}

/**
 * Which silent estimates get a nudge, and when. Pure. One-shot semantics fall
 * out of the future-fire-date filter: once 9am on day FOLLOW_UP_DAYS passes,
 * no re-sweep ever re-creates the notification. Re-stamping estimateSentAt on
 * a re-send moves the fire date forward, deliberately re-arming it.
 */
export function selectEstimateFollowUps(jobs: Job[], now: Date): EstimateFollowUpReminder[] {
  const out: EstimateFollowUpReminder[] = [];
  for (const job of jobs || []) {
    if (!job || job.status !== "estimate_sent") continue;
    const sent = estimateSentDate(job);
    if (!sent) continue;
    const fireDate = fireDateFor(sent);
    if (fireDate.getTime() <= now.getTime()) continue;
    out.push({ jobId: job.id, customerName: job.customerName, jobTitle: job.title, fireDate });
  }
  out.sort((a, b) => a.fireDate.getTime() - b.fireDate.getTime());
  return out;
}

/**
 * Jobs for Today's "awaiting response" row: still estimate_sent and silent
 * >= FOLLOW_UP_DAYS. Overlaps selectEstimateFollowUps for a few hours on day
 * FOLLOW_UP_DAYS (the row shows while the 9am notification is still pending)
 * — intentional, see the 2026-08-01 spec. Don't "fix" it.
 */
export function selectAwaitingFollowUp(jobs: Job[], now: Date): Job[] {
  return (jobs || []).filter((job) => {
    if (!job || job.status !== "estimate_sent") return false;
    const sent = estimateSentDate(job);
    if (!sent) return false;
    return now.getTime() - sent.getTime() >= FOLLOW_UP_DAYS * 86400000;
  });
}

/** Today-row copy. */
export function awaitingResponseLabel(count: number): string {
  return `${count} estimate${count === 1 ? "" : "s"} awaiting response`;
}

/** Default follow-up message — editable on-screen before sending. Estimate
 * headline money uses formatQuote (utils/format.ts mapping rule). */
export function buildFollowUpMessage(job: Job, customerFirstName: string): string {
  return (
    `Hi ${customerFirstName}, just checking in on the estimate I sent over for ` +
    `${job.title} (${formatQuote(job.estimateTotal)}). Happy to answer any ` +
    `questions — want me to get you on the schedule?`
  );
}
