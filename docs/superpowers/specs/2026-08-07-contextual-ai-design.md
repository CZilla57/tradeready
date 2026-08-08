# Contextual AI & Proactive Operations (Phase 15) — Design

**Date:** 2026-08-07
**Status:** APPROVED 2026-08-07; v1 Phases A–C implemented 2026-08-08 on
`feat/contextual-ai-insights` (A foundation `ffcd328`, B low_margin_estimate
`c91a624`, C maintenance_due `7f9eab9`). Phase D (`expense_anomaly`) was
owner-optional; opted in and built 2026-08-08 on `feat/expense-anomaly-insight`
(business-level only per §D, strictly-greater-than threshold). Deviation from §A's id table: the
low-margin id prefix is `low_margin_estimate:` (kind-prefixed, consistent
with every other id), not the `low_margin:` shorthand written there.
**Kickoff:** `docs/post-launch-feature-roadmap.md` Phase 15 (owner-curated, 2026-08-06)
**Scope if approved:** extend `utils/todayInsights.ts` + `components/InsightsCard.tsx` with insight
identity, dismiss/snooze, "why am I seeing this", and 2–3 new deterministic rules; new
`utils/insightMutes.ts`; TodayScreen wiring; analytics additions. JS-only, OTA-eligible.

## Problem

The AI tab is a destination: it helps only when the user thinks to open a blank chat.
Meanwhile the app already computes money-on-the-table conditions deterministically
(overdue invoices, stale estimates, unscheduled approved work, labor overruns) and
surfaces some of them on Today. Phase 15 turns that into a coherent contextual action
layer: deterministic rules detect every condition and compute every number; AI is an
optional drafting/explaining assist behind an explicit user tap; every mutation stays
behind existing confirm flows.

## Precondition status (verified 2026-08-07 against the tree)

- **Phase 13 (est-vs-actual profitability) is NOT built.** No STATUS block, no
  profitability code (`actualCost|jobCost|profitability` — zero implementation hits).
  `Expense` has **no `jobId`** (types/models.ts:488–507), so job-level material/expense
  actuals cannot exist yet. Consequence: two kickoff conditions — *actual job cost above
  estimate* (beyond labor hours) and job-level cost anomalies — are **blocked** and are
  ranked accordingly below. Labor-hours overrun IS live (`timeSessions` →
  `computeTimeTracking`, the `labor_overrun` insight).
- The Phase 11 schedule engine shipped: the `open_slot` rule is already
  working-hours/blackout-aware via `resolveSchedule()`.
- The Insights v1 spec (2026-08-04) explicitly lists per-insight dismiss/snooze,
  expense anomalies, and notification variants as compatible v2 extensions — Phase 15
  is that v2.

## Insight inventory — all nine kickoff conditions, ranked by expected impact

Rank = expected revenue/time impact × confidence in the deterministic signal.
"LIVE" = a deterministic rule already ships; per the kickoff ("extend rather than
duplicate") live conditions get evaluation/instrumentation, not rebuilds.

| # | Condition | Today | Verdict for Phase 15 |
|---|---|---|---|
| 1 | Overdue invoice follow-up | **LIVE ×3 layers**: server dunning (`selectInvoicesToRemind`, one-and-done log, 25/day cap), local `inv_` notifications, Today Overdue section → OutreachScreen with AI draft + template fallback | No new rule (would duplicate the Overdue section — v1's "net-new only" decision stands). Gets analytics only. |
| 2 | Estimates below target margin | **NONE proactively** — calculator sanity warnings check effective rate / materials share / min fee, but never margin-vs-target or break-even | **BUILD — v1 pick #1** (`low_margin_estimate`, §D2). All inputs exist on the saved Job; catches negotiated-down and hand-edited prices before approval locks them in. |
| 3 | Estimates awaiting customer action | **LIVE**: `estimateFollowUps` notification + Today amber row + prefilled editable message | No new rule. Optional later: AI-drafted variant of `buildFollowUpMessage` via `generateOneShot` (template fallback). Not in v1. |
| 4 | Repeat customers due for maintenance | **NONE.** No `lastServiceDate` anywhere; recurring rules are explicit user-created generators, local-only | **BUILD — v1 pick #2** (`maintenance_due`, §D3). Highest per-hit revenue (a whole recovered job) of the new rules; identity hazards handled by strict exclusions. |
| 5 | Approved jobs that still need dates | **LIVE** (`unscheduled_approved` insight + Calendar queue rail) | No change. |
| 6 | Schedule gaps that fit unscheduled work | **LIVE** (`open_slot`, schedule-config-aware since Phase 11) | No change. |
| 7 | Actual job cost above estimate | **PARTIAL**: labor hours live (`labor_overrun` + "Ask coach"); materials/expense actuals **BLOCKED on Phase 13** (`Expense.jobId` absent) | No new rule possible without inventing costs. Re-rank into v1 of Phase 13. |
| 8 | Unusual expense or cash-flow changes | **NONE as a rule** — `computeExpenseTrends` is descriptive display only | **BUILD — v1 pick #3, owner-optional** (`expense_anomaly`, §D4). Business-level only (no job link needed), conservative threshold. Cash-flow (revenue-side) variant deferred. |
| 9 | Customers eligible for a review request | **PARTIAL**: on-complete delayed nudge + JobDetail CTAs + one-shot `review_requests` ledger. Missing only "which customers deserve an ask" scoring | Defer. The trigger machinery is live and one-shot-guarded; scoring adds little until there's rating data. |

**Proposed v1 build set: foundation (identity/mutes/why/analytics) + `low_margin_estimate` +
`maintenance_due`, with `expense_anomaly` as an owner call.** That satisfies the kickoff's
"implement two or three highest-value insights first."

## Proposed decisions (each needs owner sign-off)

- **D1 — Host surface:** extend the existing Insights card, not a new surface or inline
  chat. Insights keep the checklist's slot, the top-3 cap, and the no-network render
  path (local-first invariant).
- **D2 — Dismiss/snooze storage:** new device-local AsyncStorage key **`insightMutes`**
  (added to `storage/keys.ts` + the `lifecycle.ts` sign-out wipe list). NOT synced in
  v1 — a dismissal doesn't roam devices (solo-operator; accepted). This is a new
  persisted key → explicit approval per change control.
- **D3 — Dismiss policy:** the five existing self-resolving kinds stay dismiss-free (v1
  owner decision preserved). Dismiss/snooze exists ONLY on the new long-horizon kinds
  where no derivable condition self-clears them — the same justification as the
  `portal_change` `handledAt` exception.
- **D4 — Maintenance cadence:** fixed constant `MAINTENANCE_DUE_MONTHS = 6` in v1 (the
  work-day-constant precedent). A per-trade table or Settings field is a later,
  separately-approved persisted-shape change.
- **D5 — Margin thresholds:** warn when implied margin ≤ `settings.marginPercent − 3`
  percentage points; severe copy when the price doesn't cover costs + overhead at the
  job's own stored percents. Tolerance is a named constant.
- **D6 — AI role stays prefill-only.** No new AI calls anywhere: the only AI touchpoint
  is the existing "Ask coach" prefill (never auto-sent) plus the compose screens'
  existing generators. Deterministic copy is the primary content everywhere; AI
  unavailable ⇒ the feature is simply the deterministic card (kickoff's degrade rule is
  satisfied by construction).
- **D7 — Analytics additions** (§F), including two properties on `ai_chat_sent`
  (`source`, `provider`) — required for the kickoff's "don't remove the AI tab until
  analytics demonstrate replacement" evaluation. The AI tab is untouched this phase.
- **D8 — `job_created` gains an optional `customerId` property** so maintenance-due
  conversions are measurable (internal id, not PII; PostHog already holds user ids).

## Data-shape changes

**Persisted models: NONE.** No new fields on Job/Invoice/Customer/Expense/Settings, no
sync changes, no dependencies, no backend changes. New state:

- `insightMutes` AsyncStorage key (D2): `{ id: string; mutedAt: string; until?: string }[]`
  — `until` absent = permanent dismiss, present = snooze expiry (local date). Pruned on
  write to ids the engine can still emit. Wiped on sign-out.
- Additive analytics properties only (D7/D8).

## Design

### A. Insight identity + mutes (foundation)

Every `TodayInsight` gains two fields:

```ts
id: string;      // stable dedup identity, deterministic per kind (table below)
reason: string;  // "why am I seeing this" — deterministic, numbers computed in code
```

| kind | id | Re-fire semantics |
|---|---|---|
| labor_overrun | `labor_overrun:${jobId}` | (unchanged rule) |
| uninvoiced_complete | `uninvoiced_complete:${jobId}` / `:all` | (unchanged) |
| due_soon | `due_soon:${invoiceId}` / `:all` | (unchanged) |
| open_slot | `open_slot:${date}` | (unchanged) |
| unscheduled_approved | `unscheduled_approved:${jobId}` / `:all` | (unchanged) |
| low_margin_estimate | `low_margin:${jobId}:${estimateTotal}` | editing the price resets a dismissal — a repriced job is a new question |
| maintenance_due | `maintenance_due:${customerId}` | snooze-driven; self-clears when a new job is scheduled |
| expense_anomaly | `expense_anomaly:${YYYY-MM}` | scoped per calendar month; next month is a fresh id |

`InsightsCard` rows key on `insight.id` (replacing the index key). New pure module
**`utils/insightMutes.ts`**: `loadInsightMutes()`, `muteInsight(id, until?)`,
`filterMuted(insights, mutes, now)` (pure; snoozes compare local-frame dates, FA-039),
`pruneMutes(mutes, liveIds)` — modeled on `duplicateCustomers.ts` dismissed-pairs.
TodayScreen loads mutes in its existing `Promise.all` and filters before passing to the
card, so the engine stays pure and mute-unaware.

### B. New rule: `low_margin_estimate` (utils/todayInsights.ts)

Candidates: jobs with status ∈ {`lead`, `estimate_sent`} (price still changeable;
after approval it's contracted), not archived, `estimateTotal > 0`, `laborHours > 0`,
`laborRate > 0` (jobs without real pricing inputs — e.g. CSV imports — are excluded:
never infer).

Math, from the job's own stored fields only (mirrors `calculateEstimate`'s structure;
`computeEstimateBreakdown` gives labor and marked-up materials):

```
costBase   = laborCost + materialCost            // breakdown fields
overheadAt = costBase × (job.overhead / 100)     // the job's own overhead %
profit     = estimateTotal − costBase − overheadAt
implied%   = profit / (costBase + overheadAt) × 100   // same base the engine applies margin to
```

Fire when `implied% ≤ settings.marginPercent − MARGIN_TOLERANCE_PTS (3)`. Severe copy
when `profit < 0` ("doesn't cover your costs and overhead"). Travel isn't stored on
Job, so costs are understated if travel existed — errs toward silence, never a false
alarm (stated in `reason`   only if we can detect it; we can't, so it's a doc-level
caveat instead). One row per job, capped at the worst offender when several qualify
(detail line carries the count).

Title: `'{title}' is priced {N} points under your {target}% margin` · detail:
`{formatQuote(profit)} profit on {formatQuote(estimateTotal)}` · target: `job` →
JobDetail. Reason: the full equation with the job's numbers. Ask-coach pill (§E).
Priority slot: directly after `labor_overrun` (both are "money leaking on active work").

Considered and rejected: extending `getSanityWarnings` in the calculator — margin is an
explicit *input* there, so "below target" at compose time is a user choice, not drift.
The saved-job insight is where negotiated/hand-edited prices decay.

### C. New rule: `maintenance_due` (utils/todayInsights.ts)

Candidates: customers (new param, §E) that are not archived, have contact
(`phone || email`), and whose **last service** — `max(scheduledDate)` over their jobs
with status ∈ {`complete`, `invoiced`, `paid`} and a real `customerId` join (jobs with
`customerId === ""` are excluded; invoice-only customers have no job history and are
excluded in v1 — stated limitation) — is ≥ `MAINTENANCE_DUE_MONTHS (6)` ago
(local-frame month math). Suppressed while the customer has ANY job in the active
pipeline (lead…in_progress) or an active local `RecurringJob` rule.

One customer: `It's been {N} months since you worked for {name}` · detail: last job
title · target: **new `InsightTarget` variant `{ type: "customer"; customerId }`** →
Customers tab / CustomerDetail (**cross-tab navigate — MUST carry `initial: false`**,
arch-contract §2; add to `crossTabNavigation.test.tsx`). Several: `{N} customers
haven't been serviced in {M}+ months` → CustomerList. Reason: the date math. Ask-coach
pill with a win-back drafting prompt (§E). Snooze (30 days) + dismiss via the row's
overflow (§E); self-clears when a new job is scheduled for that customer.

Priority slot: after `unscheduled_approved` (long-horizon; never crowds out
today's-money rows given the top-3 cap).

### D. New rule (owner-optional): `expense_anomaly` (utils/todayInsights.ts)

Fire when month-to-date expense total > `EXPENSE_ANOMALY_MULT (1.5)` × the average of
the prior 3 **full** months, all three non-zero (sample floor — no proration, no
guessing), and MTD ≥ $200 (small-base noise floor). Business-level only; per-job
attribution is Phase 13 territory. Title: `Spending is running {X}% above your recent
monthly average` · detail: `{formatMoney(mtd)} so far vs {formatMoney(avg)} average` ·
target: Money tab. Reason: the comparison equation + top category delta (computable
from existing category sums). Dismiss = mute for the month (id is month-scoped).
Priority: last.

### E. Card + TodayScreen wiring

- `selectTodayInsights` signature gains `customers` and `expenses` arrays (additive
  params). TodayScreen's existing `Promise.all` adds `loadCustomers()` +
  `loadExpenses()` — local AsyncStorage reads only; the render path stays
  network-free.
- Rows for muteable kinds get an overflow affordance (long-press + a small ellipsis
  target, 44pt): action sheet with **Why am I seeing this?** (alert showing `reason`;
  available on ALL kinds), **Snooze 30 days** (maintenance_due only), **Dismiss**
  (muteable kinds only). Existing five kinds: "Why" only — no dismiss (D3).
- Ask-coach pill appears on `labor_overrun` (existing), `low_margin_estimate`, and
  `maintenance_due`. Prompts are built deterministically in todayInsights.ts, prefill
  the chat input, and are **never auto-sent** (existing `initialPrompt` contract).
- `VISIBLE_LIMIT` stays 3; setup-checklist gate and `!hero` gate unchanged; sample
  data treated as real (existing precedent).

**Exact data sent to AI, per insight (kickoff requirement).** Detection sends
NOTHING off-device — rules run on-device over local data. AI sees data only if the
user taps Ask coach AND sends; the send then carries the standard chat system prompt +
BUSINESS DATA block (already-disclosed categories: business identity/rates, revenue,
outstanding, top-customer names/spend/owed) plus the prefill:

| Insight | Prefill contains | Deliberately omitted |
|---|---|---|
| labor_overrun (existing) | job title, tracked vs estimated hours, rate, estimate total | customer identity |
| low_margin_estimate | job title, implied margin %, target %, labor cost, material cost, overhead $, estimate total | customer identity |
| maintenance_due | customer **first name**, months since last service, last job title | financials, contact details, full name |
| expense_anomaly | MTD total, 3-month average, top category + delta | customer data entirely |

### F. Analytics (D7/D8)

New: `insight_dismissed { kind, insightId }` · `insight_snoozed { kind, insightId,
days }` · `insight_reason_viewed { kind }`. Extended: `insight_shown` gains `ids`;
**`ai_chat_sent` gains `{ source: 'organic' | 'insight_prefill', provider:
'anthropic' | 'groq' | 'backend' }`** (source derived from the consumed-initialPrompt
flag; provider from the branch actually taken); `job_created` gains optional
`customerId`. All via the existing `track()` — no registry to edit.

### G. Privacy plan

No new data categories leave the device: names + financials to AI providers are
already disclosed in the published privacy policy (2026-07-05), and the new prefills
are strictly narrower than the chat's existing BUSINESS DATA block. Detection is 100%
on-device. → **No privacy-policy change required** (owner to confirm). The
maintenance prompt's first-name-only and the money-only prompts follow the
estimate-scope generator's minimization precedent.

### H. Cost plan

Detection: zero AI calls, zero tokens, O(n) passes over already-loaded arrays. AI
cost is incurred only on user-initiated chat sends, riding the existing paths and
caps unchanged — user Anthropic key (their cost) or the Worker proxy
(`GROQ_API_KEY`, llama-3.1-8b-instant, 600-token replies, 20/min + 200/day per user,
fail-open counter). No new endpoints, no cap changes, no entitlement changes.
Worst-case marginal vendor cost ≈ a few hundred extra Groq 8B chat turns/day across
all users — negligible at current pricing.

### I. Fallback plan

Deterministic copy IS the product: every insight renders complete, actionable,
numeric content with no AI involved. AI failure modes change nothing on Today; a
failed chat send shows the existing error bubble with the prefill still editable. The
compose-screen generators keep their template fallbacks (`generateMessage` /
`generateOneShot` never-throw contracts untouched).

### J. Evaluation plan (kickoff: compare against the AI tab before expanding)

Four weeks post-OTA, from PostHog:

1. **Funnel per kind:** `insight_shown` → `insight_tapped` / `insight_coach_opened` →
   `insight_dismissed` (a high dismiss rate = a noisy rule → tune thresholds or kill).
2. **Contextual vs organic AI:** share of `ai_chat_sent` with
   `source: 'insight_prefill'` vs `'organic'`, and the `$screen: ChatHome` trend.
3. **Conversions:** maintenance_due → `job_created` with matching `customerId` within
   7 days; low_margin → job's `estimateTotal` changed before approval (readable from
   the re-fire id churn in `insight_shown.ids`).
4. **The AI tab is not touched this phase** — removal/demotion is a separate future
   decision that requires this data (kickoff rule honored literally).

Expansion (more of the nine, notification variants) only after this readout.

## Edge cases

- **All dates local-frame** (FA-039): month math for maintenance/anomaly uses the
  `formatLocalDate` family; snooze expiries compare local dates; no `toISOString`
  date math.
- **Muted-row backfill:** filtering happens before the top-3 slice, so muting row 1
  promotes row 4 — the card never shows blanks.
- **maintenance_due identity hazards:** `customerId === ""` jobs and invoice-only
  customers are excluded, not guessed. Renamed-customer split (known residual) can
  produce a false "due" for the old record — mitigated by the active-pipeline
  suppression checking the same (possibly split) id; accepted at the same level the
  app already accepts the split.
- **low_margin on imports/quick-adds:** excluded via `laborHours/laborRate > 0` guards.
- **Notification variants of new insights: none in v1** — deliberately avoiding the
  `review_` sweep-rebuild trap; the card is the only surface.
- **Mutes growth:** pruned on every write against live ids; snoozes expire naturally.
- **Concurrent devices:** mutes are device-local (D2) — a dismissal on the phone
  doesn't hide the row on a tablet. Accepted for v1; a synced variant would need a
  collection, not a key.

## Out of scope (v1)

Removing/demoting the AI tab; inline AI-generated text on Today (network on render
path — forbidden); AI-drafted follow-up/maintenance *messages* in compose screens
(compatible later); per-trade or user-configurable cadence/thresholds (Settings
shape change); review-eligibility scoring; cash-flow (revenue-side) anomaly;
job-level cost insights (**Phase 13**); notification variants; syncing mutes;
Expense.jobId (Phase 13's approval item).

## Testing

- `__tests__/todayInsights.test.ts` — fixed-clock cases per new rule: margin exactly
  at −3 pts vs −2.9 (fires/doesn't); profit < 0 severe copy; laborHours=0 excluded;
  6-months-minus-a-day vs 6-months (local-frame, incl. a DST-crossing case);
  active-pipeline and recurring-rule suppression; empty-contact exclusion; anomaly
  1.49× vs 1.5× and 2-full-months sample (silent); id stability incl. the
  `low_margin` reprice reset; priority order with the new kinds; formatMoney vs
  formatQuote mapping.
- New `__tests__/insightMutes.test.ts` — filter, snooze expiry at local midnight,
  prune, corrupt-JSON tolerance.
- `crossTabNavigation.test.tsx` — the new `customer` target carries `initial: false`.
- Lifecycle: `insightMutes` wiped on sign-out (extend the existing wipe assertions).
- Gate green (tsc 0 / all tests / lint 0) before every commit; phase-gated commits.

## Ship path

JS-only, zero dependencies, zero native/backend/schema changes → OTA-eligible; rides
the next OTA per the standing owner call. No store-listing claims from this feature.

Implementation phasing (each gated, each stops for go-ahead):
**A** foundation — ids, `reason`, `insightMutes`, card overflow UI, analytics props ·
**B** `low_margin_estimate` · **C** `maintenance_due` (+ the `customer` nav target) ·
**D** `expense_anomaly` (if approved) · **E** docs (README/ARCHITECTURE) + report.

## Incidental findings from the inventory (report-only, NOT in scope)

1. `sendOnboardingAI` (`utils/aiService.ts:144`) has zero callers — dead export.
2. `oneShotAI`'s keyless backend branch is unreachable from `generateEstimateMessage`
   and `generateOutreachMessage` (both pre-guard `!apiKey → fallback()`), contradicting
   its header comment; only the calculator's scope generator reaches it.
3. Stale docs: `pricebookAI.ts:6`, `receiptOCR.ts:7`, `README.md:81` claim a
   server-side `ANTHROPIC_API_KEY`; all three Worker AI endpoints use `GROQ_API_KEY`.
   `ARCHITECTURE.md:554` says "33 business events"; the true count is 49.
4. `ai_chat_sent` fires before the request with no properties — counts attempts, not
   outcomes (partially addressed by D7).
