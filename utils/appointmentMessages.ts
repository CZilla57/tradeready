// utils/appointmentMessages.ts
// Pure logic for appointment confirmations and "on my way" messages. NO I/O and
// no Expo/RN imports — everything here is unit-testable directly. Mirrors the
// backend's pure selectInvoicesToRemind. The I/O (opening a composer) lives in
// utils/appointmentSend.ts; the scheduling I/O lives in utils/notifications.ts.
import type { Job, Customer, Settings, DateString, TimeString, JobStatus } from "../types/models";
import { resolveCustomer } from "./storage/customers";
import { formatDisplayDate, formatTimeRange } from "./dateHelpers";

export const DEFAULT_CONFIRM_TEMPLATE =
  "Hi {customerName}, this is {businessName} confirming your appointment for {date} at {time}. " +
  "Reply here if you need to reschedule — see you then!";

export const DEFAULT_ON_MY_WAY_TEMPLATE =
  "Hi {customerName}, this is {businessName} — I'm on my way now. See you shortly!";

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
    (acc, [key, value]) => acc.replace(new RegExp(`\\{${key}\\}`, "g"), value),
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
  const business = settings.businessName || "your contractor";
  const template = settings.appointmentConfirmTemplate?.trim() || DEFAULT_CONFIRM_TEMPLATE;

  const out: ApptReminder[] = [];
  for (const job of jobs || []) {
    if (!job || !job.scheduledDate) continue;
    if (!ACTIVE_STATUSES.has(job.status)) continue;
    const customer = resolveCustomer(customers, job);
    if (!customer || resolveChannel(customer) === "none") continue;

    const fireDate = fireDateFor(job.scheduledDate);
    if (fireDate.getTime() <= now.getTime()) continue;

    const { date, time } = formatApptDateTime(job.scheduledDate, job.scheduledStartTime);
    const body = renderTemplate(template, {
      customerName: customer.name,
      businessName: business,
      date,
      time,
      address: customer.address || job.address || "",
    });
    out.push({
      jobId: job.id,
      fireDate,
      title: `Confirm tomorrow's job — ${customer.name}`,
      body: `Tap to send ${customer.name} a confirmation for ${date}.`,
    });
    // (body used above for the actionable text; the rendered customer message is
    // built fresh at send time from live settings, so we don't persist it here.)
    void body;
  }
  out.sort((a, b) => a.fireDate.getTime() - b.fireDate.getTime());
  return out;
}
