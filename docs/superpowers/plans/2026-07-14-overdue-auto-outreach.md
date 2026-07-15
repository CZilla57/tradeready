# Overdue Invoice Auto-Outreach (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an overdue-invoice reminder fires, let the user tap it to open a ready-to-send payment reminder for that invoice — turning the existing passive notifications into one-tap outreach, gated by a new opt-in Settings toggle.

**Architecture:** Reuse the existing pieces rather than build new ones. The `settings.rules` ages already drive `syncNotifications()`; a new `Settings.autoOutreachEnabled` flag makes those notifications *actionable* (carry a `type` + `invoiceId` in their payload). `App.tsx`'s existing notification-response listener gets one new branch that routes an `overdue_outreach` tap to the already-registered `Invoices → Outreach` screen, which already generates and sends the message. A Settings toggle exposes the flag.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript, `expo-notifications`, Jest (jest-expo), PostHog analytics wrapper (`utils/analytics.ts`).

## Global Constraints

- **Branch:** work on `feat/overdue-auto-outreach` (already created off `master`, spec commit `335cfdf`). Do not build on `feat/social-signin`.
- **No new dependencies** and **no Expo SDK change** — everything used is already installed.
- **Verify gate must be GREEN before every commit:** `npm run typecheck` (0 errors), `npm test` (all pass), `npm run lint` (`--max-warnings=0`, so 0 warnings). Never commit on red.
- **Toggle defaults to `false`** — opt-in; no behavior change until the user enables it.
- **Toggle-OFF path must stay byte-for-byte identical to today's notification** (title `Overdue invoice — {customer}`, body `Invoice {number} is now {days} days past due.`, `data: { invoiceId }`, no `type`).
- All new/changed source files stay `.ts` / `.tsx` (repo is post-TypeScript-migration).
- **Do not push** unless the owner explicitly asks.

---

## File Structure

- `types/models.ts` — add `autoOutreachEnabled: boolean` to the `Settings` interface (Notifications group).
- `utils/storage/defaults.ts` — add `autoOutreachEnabled: false` to `defaultSettings()`.
- `utils/notifications.ts` — `syncNotifications()` branches the scheduled notification's `content` on the flag.
- `__tests__/notifications.test.js` — new `describe` block covering both flag states + the absent-flag default.
- `App.tsx` — import `track`; add one `overdue_outreach` branch to the notification-response listener.
- `screens/SettingsScreen.tsx` — add the opt-in toggle card under the "Notification rules" section.

Note on existing-user safety: `loadSettings()` (`utils/storage/settings.ts:62`) returns persisted JSON as-is (it does **not** merge `defaultSettings()`), and `syncNotifications()` reads the raw `settings` JSON directly. For a user whose stored settings predate this field, `autoOutreachEnabled` is `undefined` → falsy → the OFF path everywhere. No migration is required. The Settings `<Switch>` coerces with `!!` so it renders correctly for those users. The generic `settingsEqual` (`utils/settingsDirty.ts`) compares keys structurally, so the dirty-check needs no change.

---

### Task 1: Add the `autoOutreachEnabled` setting + branch the notification content

**Files:**
- Modify: `types/models.ts:310-311` (Settings — Notifications group)
- Modify: `utils/storage/defaults.ts:216-217` (defaultSettings — Notifications)
- Modify: `utils/notifications.ts:48` and `:67-75` (syncNotifications)
- Test: `__tests__/notifications.test.js` (append a new describe block)

**Interfaces:**
- Produces: `Settings.autoOutreachEnabled: boolean`. When true, each scheduled overdue notification's `content.data` is `{ type: "overdue_outreach", invoiceId: string, daysPastDue: number }`; when false/absent it stays `{ invoiceId: string }` (no `type`). Task 2 consumes `data.type`, `data.invoiceId`, and `data.daysPastDue`.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/notifications.test.js` (after the existing `notification identifier` describe block, before end of file):

```js
// ── Auto-outreach (actionable notifications) ─────────────────────────────────

describe("auto-outreach toggle", () => {
  test("adds overdue_outreach type + daysPastDue to data when enabled", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, due: dateInDays(30) }],
      { rules: [{ days: 7 }], autoOutreachEnabled: true }
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data).toEqual({
      type: "overdue_outreach",
      invoiceId: "i7",
      daysPastDue: 7,
    });
    expect(call[0].content.body).toContain("INV-007");
  });

  test("keeps the plain reminder (no type) when disabled", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, due: dateInDays(30) }],
      { rules: [{ days: 7 }], autoOutreachEnabled: false }
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data).toEqual({ invoiceId: "i7" });
    expect(call[0].content.data.type).toBeUndefined();
  });

  test("defaults to the plain reminder when the flag is absent", async () => {
    seedStorage(
      [{ id: "i7", customer: "Alice", number: "INV-007", paid: false, due: dateInDays(30) }],
      { rules: [{ days: 7 }] } // no autoOutreachEnabled key — mirrors a pre-existing user
    );

    await syncNotifications();

    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].content.data.type).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- notifications`
Expected: the three new tests FAIL — the "enabled" test fails because `content.data` is `{ invoiceId: "i7" }` (no `type`/`daysPastDue`) since the flag isn't read yet. The two "disabled/absent" tests pass immediately (that path is unchanged), which is fine.

- [ ] **Step 3: Add the field to the `Settings` type**

In `types/models.ts`, replace the Notifications group (currently lines 310-311):

```ts
  // Notifications
  rules: ReminderRule[];
```

with:

```ts
  // Notifications
  rules: ReminderRule[];
  /**
   * When true, overdue-invoice notifications become actionable: tapping one
   * opens a pre-filled outreach message (App.tsx routes to Invoices → Outreach).
   * Opt-in; absent on settings persisted before this field shipped → treated as false.
   */
  autoOutreachEnabled: boolean;
```

- [ ] **Step 4: Add the default**

In `utils/storage/defaults.ts`, replace (currently lines 216-217):

```ts
    // Notifications — days after due date to send a reminder
    rules: [{ days: 1 }, { days: 7 }],
```

with:

```ts
    // Notifications — days after due date to send a reminder
    rules: [{ days: 1 }, { days: 7 }],
    autoOutreachEnabled: false, // opt-in; see docs/superpowers/specs/2026-07-14-overdue-auto-outreach-design.md
```

- [ ] **Step 5: Branch the notification content in `syncNotifications()`**

In `utils/notifications.ts`, after the line that derives `rules` (currently line 48):

```ts
    const rules: ReminderRule[] = settings.rules || [];
```

add:

```ts
    const autoOutreach = !!settings.autoOutreachEnabled;
```

Then replace the `scheduleNotificationAsync` call (currently lines 67-75):

```ts
        await Notifications.scheduleNotificationAsync({
          identifier: `inv_${inv.id}_${rule.days}d`,
          content: {
            title: `Overdue invoice — ${inv.customer}`,
            body: `Invoice ${inv.number} is now ${rule.days} days past due.`,
            data: { invoiceId: inv.id },
          },
          trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
        });
```

with:

```ts
        await Notifications.scheduleNotificationAsync({
          identifier: `inv_${inv.id}_${rule.days}d`,
          content: autoOutreach
            ? {
                title: `Follow up with ${inv.customer}`,
                body: `Tap to send a reminder for ${inv.number} — ${rule.days} days past due.`,
                data: { type: 'overdue_outreach', invoiceId: inv.id, daysPastDue: rule.days },
              }
            : {
                title: `Overdue invoice — ${inv.customer}`,
                body: `Invoice ${inv.number} is now ${rule.days} days past due.`,
                data: { invoiceId: inv.id },
              },
          trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
        });
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `npm test -- notifications`
Expected: all tests PASS, including the existing `notification identifier`, `title contains customer`, and `body contains number` assertions (the OFF branch is unchanged; the ON branch's title still contains the customer name and body still contains the invoice number).

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck` → expect 0 errors (new `autoOutreachEnabled` is now required on `Settings`; `defaultSettings()` supplies it, so no type gaps).
Run: `npm test` → expect all suites pass.
Run: `npm run lint` → expect 0 warnings.

- [ ] **Step 8: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts utils/notifications.ts __tests__/notifications.test.js
git commit -m "feat: add autoOutreachEnabled flag and make overdue notifications actionable

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Route an `overdue_outreach` notification tap to the Outreach screen

**Files:**
- Modify: `App.tsx:62` (analytics import) and `App.tsx:307-322` (notification-response listener)

**Interfaces:**
- Consumes (from Task 1): notification `data` of shape `{ type: "overdue_outreach", invoiceId: string, daysPastDue: number }`.
- Consumes (existing): `navigationRef` (typed nav container ref), `sessionRef` (signed-in guard), `track` from `utils/analytics`.
- Produces: navigation to `Main → Invoices → Outreach` with `{ invoiceId }`; a `track("overdue_outreach_opened", { daysPastDue })` event.

- [ ] **Step 1: Import `track`**

In `App.tsx`, replace (line 62):

```ts
import { posthogRef } from "./utils/analytics";
```

with:

```ts
import { posthogRef, track } from "./utils/analytics";
```

- [ ] **Step 2: Add the routing branch**

In `App.tsx`, replace the listener effect (currently lines 307-322):

```ts
  useEffect(() => {
    const sub = Notifications.addNotificationResponseReceivedListener((response) => {
      const data = response.notification.request.content.data;
      // Signed out: the Main route isn't mounted, so navigating would be an
      // unhandled action (a warning in dev, a silent no-op in prod). Ignore
      // the tap explicitly instead.
      if (!sessionRef.current) return;
      if (data?.type === "review_request" && data?.jobId && navigationRef.isReady()) {
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "ReviewRequest", params: { jobId: String(data.jobId) } },
        });
      }
    });
    return () => sub.remove();
  }, []);
```

with:

```ts
  useEffect(() => {
    const sub = Notifications.addNotificationResponseReceivedListener((response) => {
      const data = response.notification.request.content.data;
      // Signed out: the Main route isn't mounted, so navigating would be an
      // unhandled action (a warning in dev, a silent no-op in prod). Ignore
      // the tap explicitly instead.
      if (!sessionRef.current) return;
      if (data?.type === "review_request" && data?.jobId && navigationRef.isReady()) {
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "ReviewRequest", params: { jobId: String(data.jobId) } },
        });
      }
      if (data?.type === "overdue_outreach" && data?.invoiceId && navigationRef.isReady()) {
        track("overdue_outreach_opened", { daysPastDue: data.daysPastDue });
        navigationRef.navigate("Main", {
          screen: "Invoices",
          params: { screen: "Outreach", params: { invoiceId: String(data.invoiceId) } },
        });
      }
    });
    return () => sub.remove();
  }, []);
```

- [ ] **Step 3: Run the gate**

Run: `npm run typecheck` → expect 0 errors. (`InvoiceStackParamList.Outreach` is `{ invoiceId: string }`, so the nested `navigate` typechecks exactly like the existing `ReviewRequest` branch; `data.invoiceId`/`data.daysPastDue` are `unknown` and are passed through `String(...)` / an untyped props record, matching the existing `String(data.jobId)` usage.)
Run: `npm test` → expect all suites pass (no test change; behavior added is not unit-covered — see manual verification).
Run: `npm run lint` → expect 0 warnings (`track` is now used, so no unused-import warning).

- [ ] **Step 4: Manual verification (device/dev build — routing is not unit-testable)**

This path requires a real notification tap, which Jest can't drive. Verify on a running app (Expo dev build or TestFlight) once Task 3 lands so the flag can be enabled:
1. Enable the toggle (Task 3) and set a reminder rule whose fire time is imminent, or trigger a local notification for an unpaid overdue invoice.
2. Background the app; tap the notification when it fires.
3. Expect: the app opens the **Invoices** tab's Outreach screen for that invoice, message pre-generating.
4. Confirm a `overdue_outreach_opened` event appears in PostHog with a `daysPastDue` property.
Defer this to the Task 4 integration checklist if no device is available mid-plan.

- [ ] **Step 5: Commit**

```bash
git add App.tsx
git commit -m "feat: route overdue_outreach notification taps to the Outreach screen

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Add the opt-in toggle to the Settings screen

**Files:**
- Modify: `screens/SettingsScreen.tsx:509-513` (insert a toggle card between the "+ Add rule" button and the following `<Divider />`, within the Notification rules section)

**Interfaces:**
- Consumes (existing): the `update(key, value)` state helper, `s.autoOutreachEnabled`, `colors`, and the existing `styles.ruleSubtitle` / `styles.card` / `styles.toggleRow` / `styles.toggleLabel` (all already defined and used by the Review-requests section). `Switch` is already imported and used in this file. Saving already calls `syncNotifications()` (`SettingsScreen.tsx:270`), which reschedules notifications with the new content.

- [ ] **Step 1: Insert the toggle card**

In `screens/SettingsScreen.tsx`, find the "+ Add rule" button followed by the divider (currently lines 509-513):

```tsx
        <TouchableOpacity style={styles.addRuleBtn} onPress={addRule} accessibilityRole="button" accessibilityLabel="Add reminder rule">
          <Text style={styles.addRuleBtnText}>+ Add rule</Text>
        </TouchableOpacity>

        <Divider />
```

Replace it with (add the toggle card between the button and the divider):

```tsx
        <TouchableOpacity style={styles.addRuleBtn} onPress={addRule} accessibilityRole="button" accessibilityLabel="Add reminder rule">
          <Text style={styles.addRuleBtnText}>+ Add rule</Text>
        </TouchableOpacity>

        <Text style={[styles.ruleSubtitle, { marginTop: spacing.sm }]}>
          Turn those reminders into one-tap outreach: tapping a reminder opens a ready-to-send message for that invoice.
        </Text>
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

        <Divider />
```

(`spacing` is imported at `SettingsScreen.tsx:32` and used inline in JSX exactly this way elsewhere, e.g. line 329 — `{ marginTop: spacing.sm }`.)

- [ ] **Step 2: Run the gate**

Run: `npm run typecheck` → expect 0 errors (`update("autoOutreachEnabled", v)` typechecks because `autoOutreachEnabled` is now `keyof Settings` with a `boolean` value).
Run: `npm test` → expect all suites pass.
Run: `npm run lint` → expect 0 warnings.

- [ ] **Step 3: Manual verification (dev build)**

1. Open Settings → Notification rules. Expect the new "Draft a reminder I can send with one tap" toggle below "+ Add rule", default OFF for a fresh install.
2. Toggle ON, tap **Save settings**, navigate away and back → expect it stays ON (persisted).
3. Confirm no "Unsaved settings" dirty-warning appears after saving (the generic `settingsEqual` picks up the new key automatically).

- [ ] **Step 4: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: add auto-outreach opt-in toggle to Settings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Integration verification + docs check

**Files:**
- Possibly modify: `ARCHITECTURE.md` (only if it documents the notifications flow)

**Interfaces:** none (verification + docs only).

- [ ] **Step 1: Full gate, clean run**

Run: `npm run typecheck` → 0 errors.
Run: `npm test` → all suites pass.
Run: `npm run lint` → 0 warnings.

- [ ] **Step 2: End-to-end manual smoke on a dev build**

Perform the Task 2 Step 4 device walkthrough end to end with the toggle enabled: reminder fires → tap → lands on Invoices → Outreach for the right invoice → message generates → `overdue_outreach_opened` recorded. Then flip the toggle OFF, reschedule, and confirm the notification reverts to the plain "Overdue invoice — {customer}" reminder whose tap does nothing (today's behavior).

- [ ] **Step 3: Docs check**

Run: `grep -n "syncNotifications\|Notification rules\|reminder" ARCHITECTURE.md README.md`
If the notifications flow is described there, add one sentence noting the opt-in `autoOutreachEnabled` toggle that makes overdue reminders tap-to-outreach. If neither file documents the notifications flow, make no change (do not invent a section).

- [ ] **Step 4: Commit any docs change (skip if none)**

```bash
git add ARCHITECTURE.md README.md
git commit -m "docs: note the auto-outreach toggle in the notifications flow

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Hand back to the owner**

Summarize for the owner: commits on `feat/overdue-auto-outreach`, gate status (tests count / typecheck / lint), and the manual-smoke result. **Do not push or open a PR unless the owner asks.**

---

## Definition of Done

- `Settings.autoOutreachEnabled` exists, defaults to `false`, and persists.
- With the flag ON, overdue notifications carry `data.type === "overdue_outreach"` + `invoiceId` + `daysPastDue`; tapping opens Invoices → Outreach for that invoice and fires `overdue_outreach_opened`.
- With the flag OFF/absent, notifications are byte-for-byte today's plain reminders.
- Settings shows the opt-in toggle under Notification rules.
- Verify gate green (typecheck 0 / tests pass / lint 0) at every commit.
- No new dependencies; no Expo SDK change; nothing pushed without owner approval.

## Deviations from the spec (noted)

- The spec suggested extending "settings-defaults assertions (e.g. `__tests__/storage.test.js`)". There is **no existing defaults-assertion test** to extend (`storage.test.js` covers merge/persistence, not the default shape). Rather than invent a shape-assertion suite that doesn't match the repo's behavior-regression testing style, the default is guaranteed by the `Settings` type + `defaultSettings()` and is exercised through the new notifications tests (including the absent-flag case). If the owner wants an explicit defaults test, it can be added to `storage.test.js` as a follow-up.
- Telemetry is fired in the `App.tsx` listener using `data.daysPastDue` stamped at schedule time (not a route param into OutreachScreen), which avoids touching `navigation.ts` param types and `OutreachScreen`. The property is named `daysPastDue` to match the codebase's `daysPastDue()` helper.
