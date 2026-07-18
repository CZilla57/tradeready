// utils/appointmentMessages.ts
// Pure logic for appointment confirmations and "on my way" messages. NO I/O and
// no Expo/RN imports — everything here is unit-testable directly. Mirrors the
// backend's pure selectInvoicesToRemind. The I/O (opening a composer) lives in
// utils/appointmentSend.ts; the scheduling I/O lives in utils/notifications.ts.
import type { Job, Customer, Settings, DateString, TimeString, JobStatus } from "../types/models";
import { resolveCustomer } from "./storage/customers";
import { formatDisplayDate, formatTimeRange } from "./dateHelpers";

// Re-exported from the dependency-free module so existing importers of these
// constants from "./appointmentMessages" keep working (see appointmentTemplates.ts
// for why defaults.ts imports them from there instead).
export { DEFAULT_CONFIRM_TEMPLATE, DEFAULT_ON_MY_WAY_TEMPLATE } from "./appointmentTemplates";

// Statuses for which an appointment reminder / on-my-way action makes sense.
const ACTIVE_STATUSES: ReadonlySet<JobStatus> = new Set(["approved", "scheduled", "in_progress"]);

export type ApptChannel = "sms" | "email" | "none";
export type ApptSettings = Pick<
  Settings,
  "appointmentRemindersEnabled" | "appointmentConfirmTemplate" | "businessName"
>;
export type ApptReminder = { jobId: string; fireDate: Date; title: string; body: string };

/** Replace each {key} in `template` with vars[key] (global). Unknown placeholders left intact. */
export function renderTemplate(template: string, vars: Record<string, string>): string {
  return Object.entries(vars).reduce(
    (acc, [key, value]) => acc.replace(new RegExp(`\\{${key}\\}`, "g"), () => value),
    template,
  );
}

/** SMS preferred, email fallback, else none. Whitespace-only counts as absent. */
export function resolveChannel(customer: Pick<Customer, "phone" | "email">): ApptChannel {
  if (customer.phone && customer.phone.trim()) return "sms";
  if (customer.email && customer.email.trim()) return "email";
  return "none";
}

/** Human date + time for templates. Missing start time → neutral "the scheduled time". */
export function formatApptDateTime(
  date: DateString,
  startTime: TimeString | null,
): { date: string; time: string } {
  const time = startTime ? formatTimeRange(startTime, null) : "the scheduled time";
  return { date: formatDisplayDate(date), time };
}

/** 5pm local on the day before `scheduledDate`. */
function fireDateFor(scheduledDate: DateString): Date {
  const [y, m, d] = scheduledDate.split("-").map(Number);
  const fire = new Date(y, m - 1, d, 17, 0, 0, 0);
  fire.setDate(fire.getDate() - 1);
  return fire;
}

/** Which scheduled jobs get a confirmation notification, and when. Pure. */
export function selectAppointmentReminders(
  jobs: Job[],
  customers: Customer[],
  settings: ApptSettings,
  now: Date,
): ApptReminder[] {
  if (!settings.appointmentRemindersEnabled) return [];

  const out: ApptReminder[] = [];
  for (const job of jobs || []) {
    if (!job || !job.scheduledDate) continue;
    if (!ACTIVE_STATUSES.has(job.status)) continue;
    const customer = resolveCustomer(customers, job);
    if (!customer || resolveChannel(customer) === "none") continue;

    const fireDate = fireDateFor(job.scheduledDate);
    if (fireDate.getTime() <= now.getTime()) continue;

    const { date } = formatApptDateTime(job.scheduledDate, job.scheduledStartTime);
    out.push({
      jobId: job.id,
      fireDate,
      title: `Confirm tomorrow's job — ${customer.name}`,
      body: `Tap to send ${customer.name} a confirmation for ${date}.`,
    });
  }
  out.sort((a, b) => a.fireDate.getTime() - b.fireDate.getTime());
  return out;
}
