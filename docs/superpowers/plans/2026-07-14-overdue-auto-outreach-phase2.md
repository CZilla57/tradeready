# Overdue Auto-Outreach Phase 2 (Server Email Auto-Send) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in Vercel Cron that emails a one-and-done payment reminder (via Resend) for each overdue invoice once it passes the user's earliest reminder age, with a `auto_reminder_log` table providing both the send-once guard and an in-app audit trail.

**Architecture:** All new *logic* is pure and unit-tested from the existing app Jest (the backend files are plain CommonJS the app test can `require`). The cron endpoint is thin glue over three pure modules. The app gains one opt-in setting, one Settings toggle, and a small audit note. Live sending requires owner-provisioned env/migration (documented, not runnable in-session).

**Tech Stack:** Vercel serverless (CommonJS, `fetch`), Supabase REST (service-role), Resend REST API, React Native / Expo / TypeScript app, Jest (jest-expo).

## Global Constraints

- **Branch:** `feat/overdue-auto-outreach-phase2` (already created off `master`; spec commit `ad30d2b`). Phase 1 already merged (`59c07b8`). Do not push without owner approval.
- **No new dependencies** in either package. Backend logic is tested from the existing app Jest by `require`-ing the pure backend modules — do **not** add Jest (or anything) to `backend/`. No Expo SDK change.
- **Verify gate GREEN before every commit:** `npm run typecheck` (0), `npm test` (all pass), `npm run lint` (`--max-warnings=0`). `npm run lint` lints `backend/**/*.js` (only `backend/node_modules/` is ignored); tsconfig **excludes** `backend`, so backend `.js` is linted but not typechecked. Backend files must be lint-clean under `env: { node: true }` (CommonJS + `require`/`module`/`process`/`fetch` are all valid; match the style of `backend/api/delete-account.js`).
- **Trigger = one-and-done at the earliest rule age:** eligible when `daysPastDue(invoice.due) >= min(settings.rules.days)`; no rules ⇒ no send; at most one email per invoice ever, guarded by `auto_reminder_log unique (user_id, invoice_id)`.
- **Template-only** email content (no AI). **Cached `paymentLinkUrl` or omit** (no Stripe calls in the cron). **Strict one-and-done even on failure** (claim → send → record; no retries).
- **Transactional posture:** `From: "{businessName} via TradeReady <reminders@gettradereadyapp.com>"`, `Reply-To: settings.email`, plus a reply-to-stop line.
- **`autoSendEmailEnabled` default `false`, independent** of `autoOutreachEnabled`.
- **Owner-provisioned (out of session), needed only to go live:** Vercel env `RESEND_API_KEY` + `CRON_SECRET`; apply the `auto_reminder_log` migration in Supabase; confirm the Vercel plan permits the daily cron.

---

## File Structure

- `backend/lib/overdue.js` — pure: `daysPastDue(dueDate, today)`, `formatMoney(n)`. Shared by the selector and the email builder.
- `backend/lib/selectInvoicesToRemind.js` — pure: which of one user's invoices to email now.
- `backend/lib/reminderEmail.js` — pure: build the Resend payload for one invoice.
- `backend/api/cron/send-reminders.js` — the cron endpoint (glue).
- `backend/vercel.json` — add the `crons` entry.
- `backend/sql/auto_reminder_log.sql` — migration SQL, committed for the record (applied out-of-band by the owner).
- `__tests__/reminderLogic.test.js` — app-Jest tests that `require('../backend/lib/…')` — covers the three pure modules.
- `types/models.ts`, `utils/storage/defaults.ts` — the new setting + default.
- `screens/SettingsScreen.tsx` — the opt-in toggle.
- `screens/OutreachScreen.tsx` — the audit note.

---

### Task 1: Pure backend modules (overdue, selector, email builder) + tests

**Files:**
- Create: `backend/lib/overdue.js`, `backend/lib/selectInvoicesToRemind.js`, `backend/lib/reminderEmail.js`
- Test: `__tests__/reminderLogic.test.js`

**Interfaces:**
- Produces: `daysPastDue(dueDate, today?)→number`, `formatMoney(n)→string`; `selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds, today? })→Invoice[]`; `buildReminderEmail({ invoice, settings, today? })→{ from, to, reply_to, subject, text }`. Task 2 consumes `selectInvoicesToRemind` and `buildReminderEmail`.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/reminderLogic.test.js`:

```js
// __tests__/reminderLogic.test.js
// Unit tests for the Phase 2 backend reminder logic. The backend modules are
// plain CommonJS with no RN/Expo imports, so the app's Jest can require them
// directly — this keeps Phase 2 under the single app gate with no new deps.
const { daysPastDue, formatMoney } = require("../backend/lib/overdue");
const { selectInvoicesToRemind } = require("../backend/lib/selectInvoicesToRemind");
const { buildReminderEmail } = require("../backend/lib/reminderEmail");

// Fixed "today" so daysPastDue is deterministic. Local-time date (matches the
// app's daysPastDue, which uses setHours(0,0,0,0) in local time).
const TODAY = new Date(2026, 6, 15); // 2026-07-15

function inv(overrides = {}) {
  return {
    id: "i1",
    customer: "Alice",
    number: "INV-001",
    amount: 1200,
    due: "2026-07-01", // 14 days before TODAY
    email: "alice@example.com",
    paid: false,
    ...overrides,
  };
}

const settings = {
  autoSendEmailEnabled: true,
  rules: [{ days: 7 }, { days: 30 }],
  businessName: "Bob Plumbing",
  contactName: "Bob",
  email: "bob@bobplumbing.com",
  phone: "(555) 123-4567",
  paymentNotes: "We accept card, check, or bank transfer.",
};

describe("daysPastDue", () => {
  // Pass local Date objects (not "YYYY-MM-DD" strings) so the whole-day math is
  // timezone-independent — string dates parse as UTC and can shift the count by
  // a day depending on the machine TZ (see the repo's date-mock note).
  test("counts whole days from due to today", () => {
    expect(daysPastDue(new Date(2026, 6, 1), TODAY)).toBe(14);
    expect(daysPastDue(new Date(2026, 6, 15), TODAY)).toBe(0);
    expect(daysPastDue(new Date(2026, 6, 20), TODAY)).toBe(-5);
  });
});

describe("selectInvoicesToRemind", () => {
  test("selects an eligible overdue invoice", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out.map((i) => i.id)).toEqual(["i1"]);
  });

  test("returns none when the feature is off", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings: { ...settings, autoSendEmailEnabled: false }, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("returns none when there are no reminder rules", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings: { ...settings, rules: [] }, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes paid invoices", () => {
    const out = selectInvoicesToRemind({ invoices: [inv({ paid: true })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes invoices with no email", () => {
    const out = selectInvoicesToRemind({ invoices: [inv({ email: "" })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes invoices not yet at the earliest rule age", () => {
    // Earliest rule is 7 days; this invoice is only 3 days overdue.
    const out = selectInvoicesToRemind({ invoices: [inv({ due: "2026-07-12" })], settings, alreadySentInvoiceIds: [], today: TODAY });
    expect(out).toEqual([]);
  });

  test("excludes invoices already reminded", () => {
    const out = selectInvoicesToRemind({ invoices: [inv()], settings, alreadySentInvoiceIds: ["i1"], today: TODAY });
    expect(out).toEqual([]);
  });
});

describe("buildReminderEmail", () => {
  test("builds a transactional reminder with the right envelope", () => {
    const email = buildReminderEmail({ invoice: inv(), settings, today: TODAY });
    expect(email.from).toBe("Bob Plumbing via TradeReady <reminders@gettradereadyapp.com>");
    expect(email.to).toEqual(["alice@example.com"]);
    expect(email.reply_to).toBe("bob@bobplumbing.com");
    expect(email.subject).toBe("Payment reminder – INV-001");
    expect(email.text).toContain("INV-001");
    expect(email.text).toMatch(/\d+ days past due/);
    expect(email.text).toContain("$1,200.00");
    expect(email.text).toContain("reply to this email");
  });

  test("includes the payment link only when present", () => {
    const withLink = buildReminderEmail({ invoice: inv({ paymentLinkUrl: "https://pay.example/abc" }), settings, today: TODAY });
    expect(withLink.text).toContain("https://pay.example/abc");
    const without = buildReminderEmail({ invoice: inv(), settings, today: TODAY });
    expect(without.text).not.toContain("pay securely here");
  });

  test("omits reply_to when the business has no email", () => {
    const email = buildReminderEmail({ invoice: inv(), settings: { ...settings, email: "" }, today: TODAY });
    expect(email.reply_to).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- reminderLogic`
Expected: FAIL — `Cannot find module '../backend/lib/overdue'` (modules not created yet).

- [ ] **Step 3: Create `backend/lib/overdue.js`**

```js
// backend/lib/overdue.js
// Pure date/money helpers for the auto-reminder cron. No I/O. Mirrors the app's
// invoiceHelpers.daysPastDue (local-midnight, whole days) — duplicated here
// because the backend is a separate package and cannot import the RN util.

function daysPastDue(dueDate, today = new Date()) {
  const due = new Date(dueDate);
  const t = new Date(today);
  t.setHours(0, 0, 0, 0);
  return Math.floor((t.getTime() - due.getTime()) / 86400000);
}

function formatMoney(n) {
  return Number(n || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
}

module.exports = { daysPastDue, formatMoney };
```

- [ ] **Step 4: Create `backend/lib/selectInvoicesToRemind.js`**

```js
// backend/lib/selectInvoicesToRemind.js
// Pure. Given ONE user's invoices + settings + the ids already auto-reminded,
// returns the invoices to email now. No I/O.

const { daysPastDue } = require("./overdue");

function selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds, today = new Date() }) {
  if (!settings || !settings.autoSendEmailEnabled) return [];
  const rules = Array.isArray(settings.rules) ? settings.rules : [];
  if (rules.length === 0) return [];
  const earliest = Math.min(...rules.map((r) => Number(r.days)));
  if (!Number.isFinite(earliest)) return [];

  const sent = new Set(alreadySentInvoiceIds || []);
  return (invoices || []).filter(
    (invoice) =>
      invoice &&
      !invoice.paid &&
      typeof invoice.email === "string" &&
      invoice.email.trim() !== "" &&
      invoice.due &&
      daysPastDue(invoice.due, today) >= earliest &&
      !sent.has(invoice.id)
  );
}

module.exports = { selectInvoicesToRemind };
```

- [ ] **Step 5: Create `backend/lib/reminderEmail.js`**

```js
// backend/lib/reminderEmail.js
// Pure. Builds the Resend payload for one overdue invoice. Template-only —
// deterministic, no AI (unattended mail the user never previews). No I/O.

const { daysPastDue, formatMoney } = require("./overdue");

const SENDER = "reminders@gettradereadyapp.com";

function buildReminderEmail({ invoice, settings, today = new Date() }) {
  const amount = formatMoney(invoice.amount);
  const days = daysPastDue(invoice.due, today);
  const biz = settings.businessName || "your contractor";
  const linkLine = invoice.paymentLinkUrl
    ? `\nYou can pay securely here: ${invoice.paymentLinkUrl}\n`
    : "";
  const notes = settings.paymentNotes ? `\n${settings.paymentNotes}\n` : "";

  const text = `Hi ${invoice.customer},

This is a friendly reminder that invoice ${invoice.number} for ${amount} is now ${days} days past due.
${linkLine}
If you've already sent payment, thank you — please disregard this note. Questions, or want to stop these reminders? Just reply to this email or contact ${biz}.
${notes}
Best regards,
${settings.contactName || ""}
${settings.businessName || ""}
${settings.phone || ""}`.replace(/\n{3,}/g, "\n\n");

  const email = {
    from: `${biz} via TradeReady <${SENDER}>`,
    to: [invoice.email],
    subject: `Payment reminder – ${invoice.number}`,
    text,
  };
  if (settings.email) email.reply_to = settings.email;
  return email;
}

module.exports = { buildReminderEmail };
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `npm test -- reminderLogic`
Expected: PASS (all describe blocks).

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck` → 0 errors (backend excluded from tsconfig; no app types changed).
Run: `npm test` → all pass.
Run: `npm run lint` → 0 warnings (new backend `.js` are linted; ensure no unused vars).

- [ ] **Step 8: Commit**

```bash
git add backend/lib/overdue.js backend/lib/selectInvoicesToRemind.js backend/lib/reminderEmail.js __tests__/reminderLogic.test.js
git commit -m "feat(backend): pure auto-reminder selection + email-builder logic (Phase 2)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Cron endpoint + vercel.json cron + migration SQL

**Files:**
- Create: `backend/api/cron/send-reminders.js`
- Create: `backend/sql/auto_reminder_log.sql`
- Modify: `backend/vercel.json`

**Interfaces:**
- Consumes (Task 1): `selectInvoicesToRemind`, `buildReminderEmail`.
- Produces: the deployed cron behavior (no code consumes it). Not unit-tested (glue over live Supabase + Resend); verified by lint + review + owner smoke.

- [ ] **Step 1: Create the migration SQL (committed for the record; applied out-of-band)**

Create `backend/sql/auto_reminder_log.sql`:

```sql
-- Phase 2: one-and-done auto-reminder audit + send-once guard.
-- Apply via the Supabase migration flow (see docs/run-and-operate). The cron
-- writes rows with the service role (bypasses RLS); the app reads its own rows.
create table if not exists public.auto_reminder_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  invoice_id text not null,
  to_email   text,
  sent_at    timestamptz not null default now(),
  status     text not null default 'sent',   -- 'sent' | 'failed'
  error      text,
  unique (user_id, invoice_id)
);

alter table public.auto_reminder_log enable row level security;

create policy "read own reminder log"
  on public.auto_reminder_log for select
  using (auth.uid() = user_id);
```

- [ ] **Step 2: Create the cron endpoint**

Create `backend/api/cron/send-reminders.js`:

```js
// GET /api/cron/send-reminders
// Vercel Cron (daily). Emails a one-and-done payment reminder for each overdue
// invoice whose owner opted in (settings.autoSendEmailEnabled) once it passes
// the owner's earliest reminder age. Idempotency + audit via auto_reminder_log.
//
// Required Vercel env vars:
//   CRON_SECRET               — Vercel Cron sends "Authorization: Bearer <CRON_SECRET>"
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY — service role (bypasses RLS to scan all users)
//   RESEND_API_KEY            — Resend REST API key (sender domain already verified)

const { selectInvoicesToRemind } = require("../../lib/selectInvoicesToRemind");
const { buildReminderEmail } = require("../../lib/reminderEmail");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RESEND_API_KEY = process.env.RESEND_API_KEY;
const CRON_SECRET = process.env.CRON_SECRET;

function sbFetch(path, init = {}) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

module.exports = async function handler(req, res) {
  if (!CRON_SECRET || req.headers["authorization"] !== `Bearer ${CRON_SECRET}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !RESEND_API_KEY) {
    return res.status(500).json({ error: "Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required." });
  }

  const today = new Date();
  let scanned = 0;
  let sent = 0;
  let failed = 0;

  try {
    const [invRows, setRows, logRows] = await Promise.all([
      // All non-deleted invoices; selectInvoicesToRemind filters out paid ones.
      // (Avoids fragile JSONB-filter URL encoding; scale is small at launch.)
      sbFetch("invoices?deleted=is.false&select=id,user_id,data").then((r) => r.json()),
      sbFetch("settings?select=user_id,data").then((r) => r.json()),
      sbFetch("auto_reminder_log?select=user_id,invoice_id").then((r) => r.json()),
    ]);

    const settingsByUser = new Map((setRows || []).map((r) => [r.user_id, r.data]));
    const sentByUser = new Map();
    for (const row of logRows || []) {
      if (!sentByUser.has(row.user_id)) sentByUser.set(row.user_id, new Set());
      sentByUser.get(row.user_id).add(row.invoice_id);
    }

    const invByUser = new Map();
    for (const row of invRows || []) {
      const invoice = { ...row.data, id: row.id };
      if (!invByUser.has(row.user_id)) invByUser.set(row.user_id, []);
      invByUser.get(row.user_id).push(invoice);
    }

    for (const [userId, invoices] of invByUser) {
      const settings = settingsByUser.get(userId);
      const alreadySent = [...(sentByUser.get(userId) || [])];
      const toSend = selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: alreadySent, today });

      for (const invoice of toSend) {
        scanned++;

        // CLAIM: insert-first; a conflict on (user_id, invoice_id) returns [] so we skip.
        const claimRes = await sbFetch("auto_reminder_log?on_conflict=user_id,invoice_id", {
          method: "POST",
          headers: { Prefer: "return=representation,resolution=ignore-duplicates" },
          body: JSON.stringify({ user_id: userId, invoice_id: invoice.id, to_email: invoice.email, status: "sent" }),
        });
        const claimed = await claimRes.json().catch(() => []);
        if (!Array.isArray(claimed) || claimed.length === 0) continue;
        const logId = claimed[0].id;

        // SEND, then RECORD failure on the claimed row (no retry — one-and-done).
        try {
          const email = buildReminderEmail({ invoice, settings, today });
          const r = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify(email),
          });
          if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
          sent++;
        } catch (err) {
          failed++;
          console.error("[send-reminders] send failed", invoice.id, err.message);
          await sbFetch(`auto_reminder_log?id=eq.${logId}`, {
            method: "PATCH",
            body: JSON.stringify({ status: "failed", error: String(err.message).slice(0, 500) }),
          });
        }
      }
    }

    return res.status(200).json({ scanned, sent, failed });
  } catch (err) {
    console.error("[send-reminders] fatal", err.message);
    return res.status(500).json({ error: "Reminder run failed" });
  }
};
```

- [ ] **Step 3: Add the cron to `backend/vercel.json`**

Replace the file with:

```json
{
  "version": 2,
  "functions": {
    "api/**/*.js": {
      "memory": 256,
      "maxDuration": 10
    }
  },
  "crons": [
    { "path": "/api/cron/send-reminders", "schedule": "0 15 * * *" }
  ]
}
```

- [ ] **Step 4: Run the gate**

Run: `npm run lint` → 0 warnings (the new `backend/api/cron/send-reminders.js` is linted; ensure no unused vars — e.g. all of `scanned/sent/failed` are used in the return).
Run: `npm run typecheck` → 0 (backend excluded).
Run: `npm test` → all pass (no app code changed; the pure modules are already covered).

- [ ] **Step 5: Commit**

```bash
git add backend/api/cron/send-reminders.js backend/sql/auto_reminder_log.sql backend/vercel.json
git commit -m "feat(backend): daily auto-reminder cron + auto_reminder_log migration (Phase 2)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: App setting `autoSendEmailEnabled` + Settings toggle

**Files:**
- Modify: `types/models.ts` (Settings — Notifications group, next to `autoOutreachEnabled`)
- Modify: `utils/storage/defaults.ts` (defaultSettings — Notifications)
- Modify: `screens/SettingsScreen.tsx` (insert a toggle card immediately after the Phase 1 `autoOutreachEnabled` card)

**Interfaces:**
- Produces: `Settings.autoSendEmailEnabled: boolean`, read server-side by the cron (via `settings.data`).

- [ ] **Step 1: Add the field to the `Settings` type**

In `types/models.ts`, find the Phase 1 field:

```ts
  autoOutreachEnabled: boolean;
```

Add immediately after it:

```ts
  /**
   * When true, the backend automatically EMAILS a one-and-done payment reminder
   * for an overdue invoice once it passes the earliest reminder age (Phase 2 —
   * Vercel Cron + Resend). Opt-in; independent of autoOutreachEnabled.
   */
  autoSendEmailEnabled: boolean;
```

- [ ] **Step 2: Add the default**

In `utils/storage/defaults.ts`, find:

```ts
    autoOutreachEnabled: false, // opt-in; see docs/superpowers/specs/2026-07-14-overdue-auto-outreach-design.md
```

Add immediately after it:

```ts
    autoSendEmailEnabled: false, // opt-in; Phase 2 server email auto-send
```

- [ ] **Step 3: Add the Settings toggle**

In `screens/SettingsScreen.tsx`, find the Phase 1 toggle card (the `autoOutreachEnabled` block):

```tsx
        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Draft a reminder I can send with one tap</Text>
            <Switch
              value={!!s.autoOutreachEnabled}
              onValueChange={(v) => update("autoOutreachEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Draft a reminder I can send with one tap"
            />
          </View>
        </View>
```

Insert this new card immediately AFTER that block's closing `</View>` (and before the `<Divider />`):

```tsx
        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Automatically email overdue reminders</Text>
            <Switch
              value={!!s.autoSendEmailEnabled}
              onValueChange={(v) => update("autoSendEmailEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Automatically email overdue reminders"
            />
          </View>
          <Text style={styles.keyNote}>
            When on, TradeReady emails the customer a payment reminder once an invoice passes your earliest reminder age — no tap needed. Sent under your business name; replies come to your email.
          </Text>
        </View>
```

(`styles.keyNote` already exists in this file — it's used in the Review-requests section.)

- [ ] **Step 4: Run the gate**

Run: `npm run typecheck` → 0 (`update("autoSendEmailEnabled", v)` typechecks; the field is `keyof Settings`).
Run: `npm test` → all pass.
Run: `npm run lint` → 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts screens/SettingsScreen.tsx
git commit -m "feat: add autoSendEmailEnabled opt-in + Settings toggle (Phase 2)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: OutreachScreen audit note

**Files:**
- Modify: `screens/OutreachScreen.tsx` (import the supabase client, read the user's own `auto_reminder_log` row for this invoice, render a note)

**Interfaces:**
- Consumes: the `auto_reminder_log` table (RLS-scoped to `auth.uid()`), the existing `supabase` client (`utils/supabase.ts`).

- [ ] **Step 1: Import the supabase client**

In `screens/OutreachScreen.tsx`, add to the imports (near the other `../utils/...` imports):

```ts
import { supabase } from "../utils/supabase";
```

- [ ] **Step 2: Add state + a best-effort read**

Inside the component, alongside the other `useState` hooks, add:

```tsx
  const [autoReminder, setAutoReminder] = useState<{ sent_at: string; status: string } | null>(null);
```

And add an effect (near the existing load effect) that reads the user's own log row for this invoice. Failures (e.g. table not yet migrated) are swallowed so the note simply doesn't show:

```tsx
  useEffect(() => {
    supabase
      .from("auto_reminder_log")
      .select("sent_at,status")
      .eq("invoice_id", invoiceId)
      .maybeSingle()
      .then(({ data }) => setAutoReminder((data as { sent_at: string; status: string } | null) ?? null))
      .catch(() => {});
  }, [invoiceId]);
```

- [ ] **Step 3: Render the note in the summary card**

In the summary `Card`, immediately after the `invoiceMeta` line:

```tsx
              <Text style={styles.invoiceMeta}>{invoice.number} · {formatMoney(invoice.amount)}</Text>
```

add:

```tsx
              {autoReminder?.status === "sent" && (
                <Text style={styles.autoReminderNote}>
                  ✓ Auto-reminder emailed {new Date(autoReminder.sent_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })}
                </Text>
              )}
```

- [ ] **Step 4: Add the style**

In `createStyles`, add one entry (near `invoiceMeta`):

```ts
    autoReminderNote: { fontSize: fontSize.xs, color: colors.success, marginTop: 4, fontWeight: "500" },
```

- [ ] **Step 5: Run the gate**

Run: `npm run typecheck` → 0.
Run: `npm test` → all pass.
Run: `npm run lint` → 0 warnings (`autoReminder`, `supabase`, and the new style are all used).

- [ ] **Step 6: Commit**

```bash
git add screens/OutreachScreen.tsx
git commit -m "feat: show auto-reminder audit note on the Outreach screen (Phase 2)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Integration verification, docs, and go-live checklist

**Files:**
- Possibly modify: `ARCHITECTURE.md`

**Interfaces:** none (verification + docs).

- [ ] **Step 1: Full gate, clean run**

Run: `npm run typecheck` → 0. `npm test` → all pass (includes the new `reminderLogic` suite). `npm run lint` → 0 warnings.

- [ ] **Step 2: Docs — extend the settings map**

In `ARCHITECTURE.md`, find the Settings list line for Phase 1:

```
- Notification rules (+ auto-outreach toggle: tap an overdue reminder to open a ready-to-send message)
```

Replace it with:

```
- Notification rules (+ auto-outreach toggle: tap an overdue reminder to open a ready-to-send message; + auto-email toggle: backend emails a one-and-done reminder once overdue)
```

Then find the settings-keys list line:

```
- notificationRules, autoOutreachEnabled
```

Replace it with:

```
- notificationRules, autoOutreachEnabled, autoSendEmailEnabled
```

- [ ] **Step 3: Commit the docs change**

```bash
git add ARCHITECTURE.md
git commit -m "docs: note the Phase 2 auto-email toggle in ARCHITECTURE

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Hand the go-live checklist to the owner**

These cannot be done in-session and are required before the feature sends any email. Summarize for the owner:
1. **Supabase:** apply `backend/sql/auto_reminder_log.sql` (creates the table + RLS).
2. **Vercel env vars:** add `RESEND_API_KEY` (Resend key for `gettradereadyapp.com`) and `CRON_SECRET` (random string). Confirm `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are present.
3. **Vercel plan:** confirm the plan permits the daily cron (`0 15 * * *`); redeploy the backend so `vercel.json` `crons` registers.
4. **Smoke test (owner):** with one opted-in account holding a >earliest-age unpaid invoice, invoke the endpoint (Vercel Cron will, or `curl -H "Authorization: Bearer $CRON_SECRET" https://backend-tradeready1.vercel.app/api/cron/send-reminders`), then confirm: a Resend email arrives, an `auto_reminder_log` row exists (`status='sent'`), a second invocation sends nothing (one-and-done), and the OutreachScreen note appears.
- **Do not push** the branch unless the owner asks.

---

## Definition of Done

- Pure logic (`overdue`, `selectInvoicesToRemind`, `buildReminderEmail`) implemented and unit-tested from the app Jest; gate green.
- Cron endpoint + `vercel.json` cron + migration SQL committed; endpoint lint-clean.
- `autoSendEmailEnabled` setting (default false), Settings toggle, and OutreachScreen audit note shipped.
- Verify gate green (typecheck 0 / tests pass / lint 0) at every commit; no new dependencies; nothing pushed without owner approval.
- Go-live checklist handed to the owner (env vars, migration, cron/plan, smoke test).

## Deviations / decisions (noted)

- **No backend test harness.** The pure modules are tested from the existing app Jest by `require`-ing them (`__tests__/reminderLogic.test.js`), avoiding a backend Jest dependency and the change-control approval it would need. If that cross-package require ever hits a jest-haste collision, the fallback is a minimal backend Jest (owner approval) — not expected, since the gate is already green with `backend/` present.
- **Cron endpoint is not unit-tested** (thin glue over live Supabase + Resend); it is lint-checked, reviewed, and owner-smoke-tested. The decision logic it depends on is fully unit-tested (Task 1).
- **Migration SQL is committed but applied out-of-band** (no `.sql` migration runner exists in the repo; same pattern as the mileage spec).
