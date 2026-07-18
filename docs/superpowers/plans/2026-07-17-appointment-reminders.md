# Appointment & "On My Way" Reminders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two on-device, customer-facing touch points to scheduled jobs — an opt-in day-before confirmation reminder and an always-available "I'm on my way" one-tap button — reusing the existing notification + composer plumbing.

**Architecture:** All logic is on-device. Pure, I/O-free functions in `utils/appointmentMessages.ts` (template rendering + which-jobs-to-remind selection) do the real work and are fully unit-tested. A thin I/O helper (`utils/appointmentSend.ts`) opens the SMS/email composer. `syncNotifications` is extended to schedule day-before confirmations; `App.tsx` routes taps to JobDetail; JobDetail, the Today JobCard, and Settings get the UI. No backend, cron, Resend, Supabase table, or new dependency.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript, `expo-notifications`, `expo-sms`, `expo-mail-composer`, Jest (jest-expo), PostHog (`track`).

**Spec:** `docs/superpowers/specs/2026-07-17-appointment-reminders-design.md`

## Global Constraints

- **Gate must be green before every commit** (`npm run typecheck && npm test && npm run lint`) — zero tsc errors, zero failing tests, zero lint warnings. Never commit on red. (`tradeready-change-control`.)
- **No new dependency, no Expo SDK change.** Reuse existing modules only.
- **Local-first invariant:** no user-facing read may `await` network. Nothing in this feature touches sync except adding a `syncNotifications()` call to `saveJobs` (fire-and-forget, matching `saveInvoices`).
- **Settings `loadSettings` does NOT merge defaults.** Every read of a new Settings field MUST coerce for absence: booleans via `!!settings.x`; templates via `settings.x?.trim() || DEFAULT_…`. Absent field = safe default.
- **Template placeholders** (match the existing review-request convention): `{customerName}`, `{businessName}`, `{date}`, `{time}`, `{address}`.
- **Analytics is registry-free** — `track(event, props)` takes arbitrary event-name strings. New events: `appointment_confirm_sent`, `on_my_way_sent`, `appointment_confirm_opened`. No analytics.ts edit required; just call `track(...)` at the sites.
- **Reuse, never re-duplicate** (`tradeready-architecture-contract` §9): `composeSMS`/`composeEmail` from `utils/messaging.ts`, `resolveCustomer` from `utils/storage/customers.ts`, `formatDisplayDate`/`formatTimeRange` from `utils/dateHelpers.ts`, the `useTheme`+`createStyles(colors, shadow)` factory, and the `Button` component from `components/UI.tsx`.
- **Qualifying job** for both features: `scheduledDate` set, `status ∈ {approved, scheduled, in_progress}`, and a resolvable customer with a phone or email. Confirmation notification additionally requires `appointmentRemindersEnabled === true`.

---

## File Structure

| File | Responsibility |
|---|---|
| `types/models.ts` | +3 `Settings` fields (data shape). |
| `utils/storage/defaults.ts` | default values for the 3 fields. |
| `utils/appointmentMessages.ts` | **new, pure** — default templates, `renderTemplate`, `resolveChannel`, `formatApptDateTime`, `selectAppointmentReminders`. |
| `utils/appointmentSend.ts` | **new, I/O** — `sendAppointmentMessage` (composer dispatch). |
| `utils/notifications.ts` | extend `syncNotifications` to schedule confirmations; add Android channel. |
| `utils/storage/collections.ts` | `saveJobs` → `syncNotifications()`. |
| `App.tsx` | notification-tap branch for `appointment_confirm`. |
| `screens/JobDetailScreen.tsx` | Appointment action row (Send confirmation + I'm on my way). |
| `screens/TodayScreen.tsx` | JobCard "On my way" action. |
| `screens/SettingsScreen.tsx` | toggle + two template editors. |
| `__tests__/appointmentMessages.test.js` | pure-logic tests (Task 1). |
| `__tests__/appointmentSend.test.js` | send-helper tests with mocked messaging (Task 2). |
| `__tests__/notifications.test.js` | extended for appointment scheduling (Task 3). |

---

## Task 1: Settings fields + pure appointment logic

The data foundation and the pure, fully-tested core. A reviewer can gate this entirely on unit tests.

**Files:**
- Modify: `types/models.ts` (Settings interface, Notifications section ~line 316–330)
- Modify: `utils/storage/defaults.ts` (`defaultSettings`, ~line 225–239)
- Create: `utils/appointmentMessages.ts`
- Test: `__tests__/appointmentMessages.test.js`

**Interfaces:**
- Consumes: `Job`, `Customer`, `Settings`, `DateString`, `TimeString` from `types/models.ts`; `resolveCustomer` from `utils/storage/customers.ts`; `formatDisplayDate`, `formatTimeRange` from `utils/dateHelpers.ts`.
- Produces:
  - `DEFAULT_CONFIRM_TEMPLATE: string`, `DEFAULT_ON_MY_WAY_TEMPLATE: string`
  - `renderTemplate(template: string, vars: Record<string, string>): string`
  - `type ApptChannel = "sms" | "email" | "none"`
  - `resolveChannel(customer: Pick<Customer, "phone" | "email">): ApptChannel`
  - `formatApptDateTime(date: DateString, startTime: TimeString | null): { date: string; time: string }`
  - `selectAppointmentReminders(jobs: Job[], customers: Customer[], settings: ApptSettings, now: Date): ApptReminder[]`
    where `type ApptSettings = Pick<Settings, "appointmentRemindersEnabled" | "appointmentConfirmTemplate" | "businessName">`
    and `type ApptReminder = { jobId: string; fireDate: Date; title: string; body: string }`

- [ ] **Step 1: Add the three Settings fields**

In `types/models.ts`, inside the `Settings` interface Notifications block (right after `autoSendEmailEnabled: boolean;`), add:

```ts
  /**
   * When true, a local notification fires at 5pm the day before a scheduled
   * job, reminding the tradesperson to send the customer a confirmation.
   * Opt-in; absent on settings persisted before this field shipped → false.
   */
  appointmentRemindersEnabled: boolean;
  /** Editable day-before confirmation template. Blank/absent → DEFAULT_CONFIRM_TEMPLATE. */
  appointmentConfirmTemplate: string;
  /** Editable "on my way" template. Blank/absent → DEFAULT_ON_MY_WAY_TEMPLATE. */
  onMyWayTemplate: string;
```

- [ ] **Step 2: Add defaults**

In `utils/storage/defaults.ts`, add an import at the top with the other util imports:

```ts
import { DEFAULT_CONFIRM_TEMPLATE, DEFAULT_ON_MY_WAY_TEMPLATE } from "../appointmentMessages";
```

Then in `defaultSettings()`'s returned object, right after `autoSendEmailEnabled: false,`, add:

```ts
    appointmentRemindersEnabled: false, // opt-in; day-before confirmation reminder
    appointmentConfirmTemplate: DEFAULT_CONFIRM_TEMPLATE,
    onMyWayTemplate: DEFAULT_ON_MY_WAY_TEMPLATE,
```

- [ ] **Step 3: Write the failing test**

Create `__tests__/appointmentMessages.test.js`:

```js
// __tests__/appointmentMessages.test.js
// Pure logic for appointment/on-my-way reminders. No Expo/RN imports here, so
// this runs entirely under the app Jest with no mocking.
import {
  DEFAULT_CONFIRM_TEMPLATE,
  DEFAULT_ON_MY_WAY_TEMPLATE,
  renderTemplate,
  resolveChannel,
  formatApptDateTime,
  selectAppointmentReminders,
} from "../utils/appointmentMessages";

// A local date so fireDate math is timezone-independent.
const NOW = new Date(2026, 6, 17, 9, 0, 0); // 2026-07-17 09:00 local

function job(overrides = {}) {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Alice",
    status: "scheduled",
    scheduledDate: "2026-07-19", // 2 days out
    scheduledStartTime: "09:00",
    scheduledEndTime: "11:00",
    address: "12 Oak St",
    ...overrides,
  };
}
function customer(overrides = {}) {
  return { id: "c1", name: "Alice", email: "a@x.com", phone: "5551234567", address: "12 Oak St", ...overrides };
}
const settings = {
  appointmentRemindersEnabled: true,
  appointmentConfirmTemplate: DEFAULT_CONFIRM_TEMPLATE,
  businessName: "Bob Plumbing",
};

describe("renderTemplate", () => {
  test("replaces every provided placeholder globally", () => {
    const out = renderTemplate("Hi {customerName} from {businessName} on {date}", {
      customerName: "Alice",
      businessName: "Bob Plumbing",
      date: "Sunday, July 19",
    });
    expect(out).toBe("Hi Alice from Bob Plumbing on Sunday, July 19");
  });

  test("leaves unknown placeholders untouched (surfaces typos)", () => {
    expect(renderTemplate("Hi {nope}", { customerName: "Alice" })).toBe("Hi {nope}");
  });

  test("empty var renders as empty string", () => {
    expect(renderTemplate("at {time}!", { time: "" })).toBe("at !");
  });
});

describe("resolveChannel", () => {
  test("prefers SMS when a phone exists", () => {
    expect(resolveChannel({ phone: "5551234567", email: "a@x.com" })).toBe("sms");
  });
  test("falls back to email when no phone", () => {
    expect(resolveChannel({ phone: "", email: "a@x.com" })).toBe("email");
  });
  test("blank/whitespace phone is treated as absent", () => {
    expect(resolveChannel({ phone: "   ", email: "a@x.com" })).toBe("email");
  });
  test("none when neither is present", () => {
    expect(resolveChannel({ phone: "", email: "" })).toBe("none");
  });
});

describe("formatApptDateTime", () => {
  test("formats date and a present start time", () => {
    const { date, time } = formatApptDateTime("2026-07-19", "09:00");
    expect(date).toBe("Sunday, July 19");
    expect(time).toBe("9:00 AM");
  });
  test("missing start time falls back to a neutral phrase", () => {
    const { time } = formatApptDateTime("2026-07-19", null);
    expect(time).toBe("the scheduled time");
  });
});

describe("selectAppointmentReminders", () => {
  test("returns a reminder for a qualifying job, firing 5pm the day before", () => {
    const out = selectAppointmentReminders([job()], [customer()], settings, NOW);
    expect(out).toHaveLength(1);
    expect(out[0].jobId).toBe("j1");
    // 5pm local on 2026-07-18 (day before the 07-19 job)
    expect(out[0].fireDate).toEqual(new Date(2026, 6, 18, 17, 0, 0, 0));
    expect(out[0].body).toContain("Alice");
  });

  test("returns [] when the toggle is off", () => {
    expect(selectAppointmentReminders([job()], [customer()], { ...settings, appointmentRemindersEnabled: false }, NOW)).toEqual([]);
  });

  test("excludes terminal statuses", () => {
    expect(selectAppointmentReminders([job({ status: "complete" })], [customer()], settings, NOW)).toEqual([]);
    expect(selectAppointmentReminders([job({ status: "paid" })], [customer()], settings, NOW)).toEqual([]);
  });

  test("excludes jobs whose customer has no contact info", () => {
    expect(selectAppointmentReminders([job()], [customer({ phone: "", email: "" })], settings, NOW)).toEqual([]);
  });

  test("excludes jobs with no scheduledDate", () => {
    expect(selectAppointmentReminders([job({ scheduledDate: null })], [customer()], settings, NOW)).toEqual([]);
  });

  test("drops reminders whose 5pm-day-before is already past", () => {
    // Job is tomorrow (07-18); 5pm the day before is 07-17 17:00, but NOW is 07-17 09:00,
    // so it is still in the future — keep. Make the job today to force a past fireDate.
    const past = selectAppointmentReminders([job({ scheduledDate: "2026-07-17" })], [customer()], settings, NOW);
    expect(past).toEqual([]);
  });

  test("orders results by fireDate (soonest first)", () => {
    const soon = job({ id: "soon", scheduledDate: "2026-07-19" });
    const later = job({ id: "later", scheduledDate: "2026-07-25" });
    const out = selectAppointmentReminders([later, soon], [customer(), customer()], settings, NOW);
    expect(out.map((r) => r.jobId)).toEqual(["soon", "later"]);
  });
});
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `npm test -- appointmentMessages`
Expected: FAIL — `Cannot find module '../utils/appointmentMessages'`.

- [ ] **Step 5: Implement `utils/appointmentMessages.ts`**

```ts
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
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `npm test -- appointmentMessages`
Expected: PASS (all describe blocks green).

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: typecheck clean, all tests pass, zero lint warnings.

- [ ] **Step 8: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts utils/appointmentMessages.ts __tests__/appointmentMessages.test.js
git commit -m "feat: settings fields + pure appointment-reminder logic

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Send helper (`utils/appointmentSend.ts`)

The one I/O function that renders a template for a job/customer and opens the right composer. Kept separate from the pure module.

**Files:**
- Create: `utils/appointmentSend.ts`
- Test: `__tests__/appointmentSend.test.js`

**Interfaces:**
- Consumes: `renderTemplate`, `resolveChannel`, `formatApptDateTime`, `DEFAULT_CONFIRM_TEMPLATE`, `DEFAULT_ON_MY_WAY_TEMPLATE` from `utils/appointmentMessages.ts`; `composeSMS`, `composeEmail` from `utils/messaging.ts`; `Alert` from `react-native`.
- Produces:
  - `sendAppointmentMessage(args: { job: Job; customer: Customer; settings: Settings; kind: "confirm" | "on_my_way" }): Promise<boolean>` — returns true iff a composer opened.

- [ ] **Step 1: Write the failing test**

Create `__tests__/appointmentSend.test.js`:

```js
// __tests__/appointmentSend.test.js
import { sendAppointmentMessage } from "../utils/appointmentSend";
import { composeSMS, composeEmail } from "../utils/messaging";
import { Alert } from "react-native";

jest.mock("../utils/messaging", () => ({
  composeSMS: jest.fn(() => Promise.resolve(true)),
  composeEmail: jest.fn(() => Promise.resolve(true)),
}));
jest.spyOn(Alert, "alert").mockImplementation(() => {});

const job = {
  id: "j1", customerId: "c1", customerName: "Alice", status: "scheduled",
  scheduledDate: "2026-07-19", scheduledStartTime: "09:00", scheduledEndTime: null, address: "12 Oak St",
};
const settings = { businessName: "Bob Plumbing", appointmentConfirmTemplate: "", onMyWayTemplate: "" };

beforeEach(() => jest.clearAllMocks());

test("texts the customer when a phone exists", async () => {
  const ok = await sendAppointmentMessage({
    job, customer: { id: "c1", name: "Alice", phone: "5551234567", email: "a@x.com", address: "" },
    settings, kind: "on_my_way",
  });
  expect(ok).toBe(true);
  expect(composeSMS).toHaveBeenCalledWith(expect.objectContaining({ recipients: ["5551234567"] }));
  expect(composeSMS.mock.calls[0][0].body).toContain("Alice");
  expect(composeEmail).not.toHaveBeenCalled();
});

test("emails when there is no phone", async () => {
  const ok = await sendAppointmentMessage({
    job, customer: { id: "c1", name: "Alice", phone: "", email: "a@x.com", address: "" },
    settings, kind: "confirm",
  });
  expect(ok).toBe(true);
  expect(composeEmail).toHaveBeenCalledWith(expect.objectContaining({ recipients: ["a@x.com"] }));
  expect(composeSMS).not.toHaveBeenCalled();
});

test("alerts and returns false when the customer has no contact info", async () => {
  const ok = await sendAppointmentMessage({
    job, customer: { id: "c1", name: "Alice", phone: "", email: "", address: "" },
    settings, kind: "confirm",
  });
  expect(ok).toBe(false);
  expect(Alert.alert).toHaveBeenCalled();
  expect(composeSMS).not.toHaveBeenCalled();
  expect(composeEmail).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- appointmentSend`
Expected: FAIL — `Cannot find module '../utils/appointmentSend'`.

- [ ] **Step 3: Implement `utils/appointmentSend.ts`**

```ts
// utils/appointmentSend.ts
// Renders an appointment template for a job/customer and opens the SMS (preferred)
// or email composer. The only I/O in the appointment feature besides notification
// scheduling. Returns true iff a composer opened.
import { Alert } from "react-native";
import type { Job, Customer, Settings } from "../types/models";
import { composeSMS, composeEmail } from "./messaging";
import {
  renderTemplate,
  resolveChannel,
  formatApptDateTime,
  DEFAULT_CONFIRM_TEMPLATE,
  DEFAULT_ON_MY_WAY_TEMPLATE,
} from "./appointmentMessages";

export async function sendAppointmentMessage(args: {
  job: Job;
  customer: Customer;
  settings: Settings;
  kind: "confirm" | "on_my_way";
}): Promise<boolean> {
  const { job, customer, settings, kind } = args;
  const channel = resolveChannel(customer);
  if (channel === "none") {
    Alert.alert("No contact info", `${customer.name} has no phone or email on file. Add one to send a message.`);
    return false;
  }

  const template =
    kind === "confirm"
      ? settings.appointmentConfirmTemplate?.trim() || DEFAULT_CONFIRM_TEMPLATE
      : settings.onMyWayTemplate?.trim() || DEFAULT_ON_MY_WAY_TEMPLATE;

  const { date, time } = formatApptDateTime(job.scheduledDate ?? "", job.scheduledStartTime);
  const body = renderTemplate(template, {
    customerName: customer.name,
    businessName: settings.businessName || "your contractor",
    date,
    time,
    address: customer.address || job.address || "",
  });

  if (channel === "sms") {
    return composeSMS({ recipients: [customer.phone], body });
  }
  const subject = kind === "confirm" ? "Appointment confirmation" : "On my way";
  return composeEmail({ recipients: [customer.email], subject, body });
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- appointmentSend`
Expected: PASS.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add utils/appointmentSend.ts __tests__/appointmentSend.test.js
git commit -m "feat: appointment/on-my-way send helper (SMS with email fallback)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Schedule day-before confirmations + wire job saves

Extend `syncNotifications` to also schedule appointment confirmations, add the Android channel, and make `saveJobs` re-derive notifications.

**Files:**
- Modify: `utils/notifications.ts`
- Modify: `utils/storage/collections.ts` (`saveJobs`, ~line 45–51)
- Test: `__tests__/notifications.test.js`

**Interfaces:**
- Consumes: `selectAppointmentReminders` from `utils/appointmentMessages.ts`; `Job`, `Customer` from `types/models.ts`.
- Produces: no new exports — extends `syncNotifications` behavior. Scheduled appointment notifications carry `identifier: \`appt_${jobId}\`` and `data: { type: "appointment_confirm", jobId }`.

- [ ] **Step 1: Write the failing test**

Add to `__tests__/notifications.test.js`. First, extend the existing `seedStorage` helper so it can also serve jobs and customers (find the helper near the top and replace it):

```js
function seedStorage(invoices, settings = { rules: [{ days: 1 }] }, jobs = [], customers = []) {
  AsyncStorage.getItem.mockImplementation((key) => {
    if (key === "invoices") return Promise.resolve(JSON.stringify(invoices));
    if (key === "settings") return Promise.resolve(JSON.stringify(settings));
    if (key === "jobs") return Promise.resolve(JSON.stringify(jobs));
    if (key === "customers") return Promise.resolve(JSON.stringify(customers));
    return Promise.resolve(null);
  });
}
```

Then add a new describe block:

```js
describe("syncNotifications — appointment confirmations", () => {
  function apptJob(overrides = {}) {
    return {
      id: "j1", customerId: "c1", customerName: "Alice", status: "scheduled",
      scheduledDate: dateInDays(3), scheduledStartTime: "09:00", scheduledEndTime: "11:00",
      address: "12 Oak St", ...overrides,
    };
  }
  const cust = { id: "c1", name: "Alice", phone: "5551234567", email: "a@x.com", address: "12 Oak St" };
  const apptSettings = {
    rules: [], appointmentRemindersEnabled: true,
    appointmentConfirmTemplate: "", businessName: "Bob Plumbing",
  };

  test("schedules an appointment_confirm notification for a qualifying job", async () => {
    Notifications.getPermissionsAsync.mockResolvedValue({ status: "granted" });
    seedStorage([], apptSettings, [apptJob()], [cust]);
    await syncNotifications();
    const calls = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0]);
    const appt = calls.find((c) => c.identifier === "appt_j1");
    expect(appt).toBeTruthy();
    expect(appt.content.data).toEqual({ type: "appointment_confirm", jobId: "j1" });
  });

  test("schedules nothing when the toggle is off", async () => {
    Notifications.getPermissionsAsync.mockResolvedValue({ status: "granted" });
    seedStorage([], { ...apptSettings, appointmentRemindersEnabled: false }, [apptJob()], [cust]);
    await syncNotifications();
    const ids = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0].identifier);
    expect(ids).not.toContain("appt_j1");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- notifications`
Expected: FAIL — no `appt_j1` notification is scheduled (the appointment branch doesn't exist yet).

- [ ] **Step 3: Add the Android notification channel**

In `utils/notifications.ts` `setupNotifications`, after the `review-requests` channel block, add:

```ts
    await Notifications.setNotificationChannelAsync('appointment-reminders', {
      name: 'Appointment Reminders',
      importance: Notifications.AndroidImportance.DEFAULT,
    });
```

- [ ] **Step 4: Extend `syncNotifications`**

In `utils/notifications.ts`:

Add imports at the top:

```ts
import type { Invoice, Settings, ReminderRule, Job, Customer } from '../types/models';
import { selectAppointmentReminders } from './appointmentMessages';
```

(replace the existing `import type { Invoice, Settings, ReminderRule }` line accordingly).

Inside `syncNotifications`, change the initial read to also load jobs + customers:

```ts
    const [invoicesRaw, settingsRaw, jobsRaw, customersRaw] = await Promise.all([
      AsyncStorage.getItem('invoices'),
      AsyncStorage.getItem('settings'),
      AsyncStorage.getItem('jobs'),
      AsyncStorage.getItem('customers'),
    ]);
    const invoices: Invoice[] = invoicesRaw ? JSON.parse(invoicesRaw) : [];
    const settings: Partial<Settings> = settingsRaw ? JSON.parse(settingsRaw) : {};
    const jobs: Job[] = jobsRaw ? JSON.parse(jobsRaw) : [];
    const customers: Customer[] = customersRaw ? JSON.parse(customersRaw) : [];
    const rules: ReminderRule[] = settings.rules || [];
    const autoOutreach = !!settings.autoOutreachEnabled;
```

Then, after the existing invoice-reminder `outer:` loop (right before the closing of the `try`), add the appointment loop, sharing the existing `count`/cap:

```ts
    const appointments = selectAppointmentReminders(jobs, customers, {
      appointmentRemindersEnabled: !!settings.appointmentRemindersEnabled,
      appointmentConfirmTemplate: settings.appointmentConfirmTemplate ?? '',
      businessName: settings.businessName ?? '',
    }, now);

    for (const appt of appointments) {
      if (count >= 60) break;
      const secondsUntil = Math.floor((appt.fireDate.getTime() - now.getTime()) / 1000);
      if (secondsUntil <= 0) continue;
      await Notifications.scheduleNotificationAsync({
        identifier: `appt_${appt.jobId}`,
        content: {
          title: appt.title,
          body: appt.body,
          data: { type: 'appointment_confirm', jobId: appt.jobId },
        },
        trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
      });
      count++;
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- notifications`
Expected: PASS (both new tests plus all pre-existing invoice tests).

- [ ] **Step 6: Wire `saveJobs` to re-derive notifications**

In `utils/storage/collections.ts`, add `syncNotifications();` as the last line of `saveJobs` (it is already imported at the top of the file for `saveInvoices`):

```ts
export async function saveJobs(jobs: Job[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.jobs);
  const old: Job[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.jobs, JSON.stringify(jobs));
  await enqueueCollectionChanges("jobs", old, jobs);
  trySync();
  syncNotifications();
}
```

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add utils/notifications.ts utils/storage/collections.ts __tests__/notifications.test.js
git commit -m "feat: schedule day-before appointment confirmations

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Route confirmation-notification taps (`App.tsx`)

**Files:**
- Modify: `App.tsx` (the `addNotificationResponseReceivedListener` effect, ~line 316–335)

**Interfaces:**
- Consumes: the `data: { type: "appointment_confirm", jobId }` payload from Task 3; existing `navigationRef`, `sessionRef`, `track`.
- Produces: navigation to `Jobs → JobDetail` on tap.

- [ ] **Step 1: Add the routing branch**

In `App.tsx`, inside the notification-response listener, after the existing `overdue_outreach` branch, add:

```ts
      if (data?.type === "appointment_confirm" && data?.jobId && navigationRef.isReady()) {
        track("appointment_confirm_opened", {});
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "JobDetail", params: { jobId: String(data.jobId) } },
        });
      }
```

- [ ] **Step 2: Run typecheck**

Run: `npm run typecheck`
Expected: clean (the `Main → Jobs → JobDetail` param path already typechecks — `JobDetail` is registered in `JobStack`).

- [ ] **Step 3: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add App.tsx
git commit -m "feat: route appointment-confirmation notification taps to JobDetail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: JobDetail appointment actions

Add an "Appointment" action row on scheduled jobs: **Send confirmation** and **I'm on my way**.

**Files:**
- Modify: `screens/JobDetailScreen.tsx`

**Interfaces:**
- Consumes: `sendAppointmentMessage` from `utils/appointmentSend.ts`; existing `job`, `customer`, `loadSettings`, `Button`, `track`, and the `createStyles(colors, shadow)` factory already in the file.
- Produces: two on-screen buttons.

**Note (no unit test):** This is UI wired to already-tested logic. Verification is the gate (typecheck/lint) plus the manual smoke in Task 8. Do NOT add a renderer test — the repo tests logic, not screens, for this kind of change.

- [ ] **Step 1: Import the send helper**

At the top of `screens/JobDetailScreen.tsx`, add:

```ts
import { sendAppointmentMessage } from "../utils/appointmentSend";
```

- [ ] **Step 2: Add a handler**

Inside the `JobDetailScreen` component body (near the other handlers such as `advanceStatus`), add:

```ts
  async function handleAppointmentSend(kind: "confirm" | "on_my_way") {
    if (!job || !customer) return;
    const settings = await loadSettings();
    const opened = await sendAppointmentMessage({ job, customer, settings, kind });
    if (opened) {
      track(kind === "confirm" ? "appointment_confirm_sent" : "on_my_way_sent", {});
    }
  }
```

- [ ] **Step 3: Render the action row**

In the JSX, inside the existing `job.scheduledDate` conditional block (the one that renders the 📅 date around line 147–152), after the date line, add the two buttons. Match the surrounding `Button` usage in the file:

```tsx
      {job.scheduledDate && customer && (
        <View style={styles.apptActions}>
          <Button
            title="Send confirmation"
            variant="secondary"
            onPress={() => handleAppointmentSend("confirm")}
          />
          <Button
            title="I'm on my way"
            variant="primary"
            onPress={() => handleAppointmentSend("on_my_way")}
          />
        </View>
      )}
```

- [ ] **Step 4: Add the style**

In this file's `createStyles(colors, shadow)`, add an `apptActions` entry (match the spacing tokens used elsewhere in the file, e.g. `gap: spacing.sm, marginTop: spacing.sm`):

```ts
    apptActions: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.sm },
```

(Import `spacing` from `../utils/theme` if not already imported in this file.)

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add screens/JobDetailScreen.tsx
git commit -m "feat: appointment confirmation + on-my-way buttons on JobDetail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Today JobCard "On my way" action

Add a compact "On my way" action to today's scheduled jobs — the place the tradesperson glances before leaving.

**Files:**
- Modify: `screens/TodayScreen.tsx`

**Interfaces:**
- Consumes: `sendAppointmentMessage`; the job already rendered by the JobCard; `loadCustomers`/`resolveCustomer`, `loadSettings`, `track`.
- Produces: an on-screen action on today's job cards.

**Note (no unit test):** UI wired to tested logic; verify via gate + manual smoke.

- [ ] **Step 1: Inspect the JobCard**

Read `screens/TodayScreen.tsx` and locate the `JobCard` component and how it receives its `job` (and whether it already has the customer). Confirm the prop names before editing. The action should only render when `job.scheduledDate` is set and `job.status ∈ {approved, scheduled, in_progress}`.

- [ ] **Step 2: Add a handler that resolves the customer**

Because the Today JobCard may not already hold the full customer record, resolve it on tap:

```ts
  async function handleOnMyWay(job: Job) {
    const [customers, settings] = await Promise.all([loadCustomers(), loadSettings()]);
    const customer = resolveCustomer(customers, job);
    if (!customer) {
      Alert.alert("No customer", "This job has no linked customer to message.");
      return;
    }
    const opened = await sendAppointmentMessage({ job, customer, settings, kind: "on_my_way" });
    if (opened) track("on_my_way_sent", {});
  }
```

Add the needed imports (`sendAppointmentMessage` from `../utils/appointmentSend`; `resolveCustomer`, `loadCustomers`, `loadSettings` from `../utils/storage`; `Alert` from `react-native`) if not already present.

- [ ] **Step 3: Render the action**

Add a compact button/pressable to the JobCard, guarded by the qualifying condition:

```tsx
      {job.scheduledDate && ["approved", "scheduled", "in_progress"].includes(job.status) && (
        <Button title="On my way" variant="ghost" onPress={() => handleOnMyWay(job)} />
      )}
```

Match the JobCard's existing layout/spacing so it doesn't crowd the card. If `Button` isn't already used in this file, use the same touchable/text pattern the card already uses for its actions.

- [ ] **Step 4: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add screens/TodayScreen.tsx
git commit -m "feat: on-my-way action on today's job cards

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Settings — toggle + template editors

**Files:**
- Modify: `screens/SettingsScreen.tsx`

**Interfaces:**
- Consumes: the `appointmentRemindersEnabled`, `appointmentConfirmTemplate`, `onMyWayTemplate` Settings fields; the screen's existing settings state + save flow (same pattern used for `reviewRequestEnabled` / `reviewRequestTemplate`).
- Produces: UI controls that persist to Settings.

**Note (no unit test):** Mirrors the existing review-request settings UI; verify via gate + manual smoke.

- [ ] **Step 1: Inspect the review-request settings UI**

Read `screens/SettingsScreen.tsx` and locate the `reviewRequestEnabled` toggle and `reviewRequestTemplate` editor. Copy that exact pattern (state field, `Switch`/toggle, multiline `Field`/TextInput, save handler wiring) for the appointment fields.

- [ ] **Step 2: Add the toggle**

Under the Notifications section (near `autoOutreachEnabled`), add an "Appointment reminders" toggle bound to `appointmentRemindersEnabled`, with a one-line description: `"Remind me the evening before a scheduled job to confirm with the customer."`

- [ ] **Step 3: Add the two template editors**

Below the toggle, add two multiline template editors (confirmation, on-my-way) bound to `appointmentConfirmTemplate` and `onMyWayTemplate`, each with helper text listing the placeholders: `Available: {customerName}, {businessName}, {date}, {time}, {address}`. Follow the `reviewRequestTemplate` editor's markup and save behavior exactly.

- [ ] **Step 4: Verify absence-coercion**

Confirm the editors show the default template text when the stored value is blank — read with `settings.appointmentConfirmTemplate?.trim() || DEFAULT_CONFIRM_TEMPLATE` (import the defaults from `../utils/appointmentMessages`), matching how the review template surfaces its default.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: appointment-reminder toggle + editable templates in Settings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Manual smoke verification

No code — exercise the feature in a running app (Expo Go is fine; local notifications and the composer both work there) and confirm behavior before wrapping up.

- [ ] **Step 1: Confirmation notification path**
  - In Settings, enable "Appointment reminders" and grant notification permission.
  - Create/edit a job: link a customer with a phone, set status `scheduled`, set `scheduledDate` to tomorrow. Save.
  - Confirm (via `Notifications.getAllScheduledNotificationsAsync()` in a dev log, or by shortening the fire offset temporarily) that an `appt_<jobId>` notification is scheduled for 5pm today.
  - Tap the notification → app opens JobDetail for that job.

- [ ] **Step 2: JobDetail buttons**
  - On the scheduled job's JobDetail, tap **Send confirmation** → SMS composer opens, pre-filled, addressed to the customer's phone, with `{customerName}/{date}/{time}` filled.
  - Tap **I'm on my way** → SMS composer opens with the on-my-way text.
  - Remove the customer's phone (email only) → both buttons open the email composer instead.
  - Remove both phone and email → tapping shows the "No contact info" alert; no composer.

- [ ] **Step 3: Today card**
  - With a job scheduled for today, confirm the **On my way** action shows on the Today card and opens the composer.

- [ ] **Step 4: Settings templates**
  - Edit the confirmation template, save, reopen Settings → edit persists. Send again → new wording appears.
  - Toggle "Appointment reminders" off → no new `appt_` notifications are scheduled after saving a job.

- [ ] **Step 5: Final gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all green. Feature complete on branch `feat/appointment-reminders` (do NOT merge — owner gates merges).

---

## Self-Review notes

- **Spec coverage:** data model (T1) · pure templates/selection (T1) · send helper (T2) · scheduling + Android channel + saveJobs wiring (T3) · tap routing (T4) · JobDetail buttons (T5) · Today card (T6) · Settings toggle+templates (T7) · analytics events (fired in T4/T5/T6) · tests (T1–T3) · manual smoke (T8). All spec sections mapped.
- **Placeholder alignment:** `{customerName}`, `{businessName}`, `{date}`, `{time}`, `{address}` used consistently in defaults, `renderTemplate` vars, and Settings helper text.
- **Type/name consistency:** `selectAppointmentReminders(jobs, customers, settings, now)`, `resolveChannel`, `formatApptDateTime`, `sendAppointmentMessage({ job, customer, settings, kind })`, notification `identifier` `appt_${jobId}` and `data.type` `appointment_confirm` are identical across every task that references them.
- **Deviation from spec:** the spec listed a `utils/analytics.ts` event-list edit; the repo has no event registry (`track` takes arbitrary strings), so events are fired directly at their sites — no analytics.ts change. The on-my-way default template omits `{address}` (kept as an available placeholder) to avoid empty-address artifacts; `{time}` falls back to "the scheduled time" when a job has no start time.
