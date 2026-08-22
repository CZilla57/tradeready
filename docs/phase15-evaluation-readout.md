# Phase 15 — AI-tab-vs-contextual Evaluation Readout

**Spec:** `docs/superpowers/specs/2026-08-07-contextual-ai-design.md` §J
**OTA shipped:** 2026-08-07 (group `d75fd3a5`, runtime `1.1.0`) — Phase 15 A–C.
**Run the readout on/after:** ~2026-09-04 (4 weeks post-OTA, per §J).

> Phase 15-**D** `expense_anomaly` OTA'd separately on a later `eas update`; its
> `expense_anomaly` funnel row only becomes meaningful 4 weeks after *that* ship
> date, not after 2026-08-07. Note the D ship date here when it goes out: __________

This is an executable template. Fill the blanks from PostHog once the window closes.

## Instrumentation audit (verified in the OTA'd tree, 2026-08-08)

All events §J depends on fire in the shipped build:

| §J needs | Event / property | Location |
|---|---|---|
| Funnel: impressions | `insight_shown { kinds:[], ids:[] }` (once per distinct visible set) | InsightsCard.tsx:139 |
| Funnel: engagement | `insight_tapped { kind }`, `insight_coach_opened { kind }` | InsightsCard.tsx:146,152 |
| Funnel: rejection | `insight_dismissed { kind, insightId }`, `insight_snoozed { kind, insightId, days }` | InsightsCard.tsx:178,188 |
| "Why" curiosity | `insight_reason_viewed { kind }` | InsightsCard.tsx:170 |
| Contextual vs organic AI | `ai_chat_sent { source:'insight_prefill'\|'organic', provider:'anthropic'\|'groq'\|'backend' }` | ChatScreen.tsx:168 |
| AI-tab traffic trend | `$screen: ChatHome` autocapture (`useNavigationTracker()` inside the container) | App.tsx:781, 328 |
| Maintenance→job conversion | `job_created { customerId? }` (internal id, not PII, omitted when unresolved) | AddJobScreen.tsx:400 |

**Query-shape caveats (not bugs):**

1. `insight_shown` carries `kinds`/`ids` as **arrays**, one event per visible-set
   change — *not* one event per row. "Impressions for kind K" = count of
   `insight_shown` where `kinds ∋ K` (a focus/session-level denominator, correct
   for ratios, not a literal per-row count).
2. `insight_tapped` / `insight_coach_opened` / `insight_reason_viewed` carry
   `kind` only, **no `insightId`**. Only dismiss/snooze carry `insightId`. Per-kind
   funnels are clean; per-specific-insight joins are only possible on the
   dismiss/snooze end and via the `ids` array in `insight_shown`.

## Cohort

Events on/after 2026-08-07, app runtime `1.1.0` train. Exclude internal/test
distinct_ids.

## 1 — Funnel per kind (is the rule noisy?)

For each kind ∈ {`low_margin_estimate`, `maintenance_due`, `labor_overrun`, + the
live 5 (`uninvoiced_complete`, `due_soon`, `open_slot`, `unscheduled_approved`,
`estimate_followup`)}:

- impressions = `insight_shown` where `kinds ∋ kind`
- engagement rate = (`insight_tapped` + `insight_coach_opened` for kind) / impressions
- dismiss rate = `insight_dismissed` for kind / impressions
  (only `maintenance_due` + `expense_anomaly` are dismissable per D3 — primary
  quality signal for the two new muteable rules)

**Thresholds / decisions:**

- Dismiss rate **>40%** over ≥30 impressions → noisy. Tune the constant
  (`MARGIN_TOLERANCE_PTS`, `MAINTENANCE_DUE_MONTHS`, `EXPENSE_ANOMALY_MULT`) or kill.
- Engagement **<5%** with low dismiss → ignored, not harmful; deprioritize.
- `insight_reason_viewed` spike for a kind → copy unclear, rewrite.

| kind | impressions | engagement % | dismiss % | verdict |
|---|---|---|---|---|
| low_margin_estimate | | | (n/a — not dismissable) | |
| maintenance_due | | | | |
| labor_overrun | | | (n/a) | |
| expense_anomaly (after D OTA) | | | | |
| (live 5, spot-check) | | | | |

## 2 — Contextual vs organic AI (does it replace the tab?)

- prefill share = `ai_chat_sent{source:insight_prefill}` / all `ai_chat_sent` = ____
- organic ChatHome trend = weekly `$screen:ChatHome` count, slope over 4 weeks = ____
- provider mix = breakdown by `provider` (sanity: most on free `backend`/`groq`,
  not surprise `anthropic`-key usage) = ____

**Read:**

- Meaningful prefill share **with flat-or-rising** organic ChatHome → insights are
  additive; tab stays.
- Prefill share climbing **while** organic ChatHome falls → the contextual layer is
  absorbing the tab's job → evidence a future demote/remove could rest on.
- **No tab change happens this phase regardless (§J item 4).** This only gathers evidence.

## 3 — Conversions

- **maintenance_due → job:** within 7 days, a `job_created` whose `customerId`
  matches an id in a `maintenance_due:{customerId}` insight id (from
  `insight_shown.ids`). Matched conversions / customers shown = ____
- **low_margin_estimate → reprice-before-approval:** churn in the
  `low_margin_estimate:{jobId}:{estimateTotal}` id across successive
  `insight_shown.ids` for the same jobId (the `estimateTotal` segment changing =
  price edited after the warning). Count of repriced jobs shown = ____

## 4 — AI tab

Untouched this phase, by design. Removal/demotion is a separate later decision gated
on the item-2 evidence above.

## Expansion gate

More of the nine kickoff conditions + notification variants only *after* this readout
(§J closing line).
