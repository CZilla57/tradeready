# Roadmap execution ledger

Orchestrator memory for the post-launch roadmap run (prompt: `docs/roadmap-execution-prompt.md`).
Re-read this instead of relying on conversation history. Updated after every phase event.

States: not started, partial, built unverified, verified, committed.
"Verified" means the phase-done gate ran green in that worktree: `sh native/run-all-domain-tests.sh`,
`cd backend-workers && npm test`, the Release compile, `sh native/run-doc-reference-check.sh`.

Worktrees live under `.claude/worktrees/` unless noted.

## Survey snapshot (2026-10-03 23:00 MST)

- No worktree file has changed since 18:03 (five hours idle); the only recent file is the owner's
  prompt. Decision: the uncommitted work in the worktrees is abandoned in-flight work from the earlier
  run, not a live agent. Resume it, but re-check `git status` and mtimes before each edit.
- Actual stacking is NOT the build order. Real topology:
  - `feat/quote-options` (25) -> `feat/lead-source` (27) -> `feat/quote-expiration` (32, tip 127e06c)
  - `feat/job-forms` (20) sits on an older 32 commit (aa1bbbf via merge 494bd87), not on 127e06c
  - `feat/properties-equipment` (21), `feat/referrals` (34), `feat/campaigns` (33) each branch from
    494bd87 (the job-forms data-layer wip), not from the job-forms tip and not from each other
  - `feat/calendar-sync` (26) sits on the job-forms tip cdc2b29
  - `feat/autopay` (24), `feat/open-api` (23), `feat/esign` (19) each sit directly on 127e06c
  - `feat/tips` (28) and `feat/tap-to-pay` (18) are the same commit as `feat/autopay` (6b3fa4d)
- Target: linear stack 25 -> 27 -> 32 -> 20 -> 21 -> 34 -> 24 -> 28 -> 33 -> 26 -> 23 -> 19 -> 18,
  reached by merging each finished branch forward into the next.
- `tradeready-legal` is on branch `feat/quote-options` with uncommitted `book.html`, `change.html`,
  `estimate.html`, `portal.html` and untracked `developers.html`, `esign.js`, `pay.html`, `verify.html`.
  Owner commits and publishes; not touched by this run.

## Ledger

| Order | Phase | Branch / worktree | State | Remaining work | Blockers | Owner-run steps |
|---|---|---|---|---|---|---|
| 1 | 25 quote options | `feat/quote-options` 3efdb38 | committed, verified | none | none | Apply Phase 25 migration; commit/publish legal pages; deploy Worker |
| 2 | 27 lead source | `feat/lead-source` a5fa557 / `fix-quote-options` | committed, verified | none | none | Commit/publish `book.html` (`?src=`); deploy Worker |
| 3 | 32 quote expiration | `feat/quote-expiration` 23eb243 / main checkout | committed, verified | none | none | Commit/publish `estimate.html`, `portal.html`; deploy Worker |
| 4 | 20 job forms | `feat/job-forms` a0569d9 / `job-forms` | committed, verified, reviewed | none | none | Apply `20261002_forms.sql` |
| 5 | 21 properties | `feat/properties-equipment` 2b625cb / `properties` | committed, verified | none | none | none (native only) |
| 6 | 34 referrals | `feat/referrals` bd8cade / `referrals` | committed, verified, reviewed | Owner rule for P3 (credit after re-point) | none | Commit/publish `book.html` referral code; deploy Worker |
| 7 | 24 autopay | `feat/autopay` d7aebad / `autopay` | committed, verified, Fable SOUND | none | none | Apply `20261003_autopay.sql`; legal `pay.html`, `portal.html`, `terms.html`, `privacy.html`; Stripe webhook events; deploy Worker |
| 8 | 28 tips | `feat/tips` 3d53c7a / `tips` | committed, verified, Fable reviewed | none | none | Legal `pay.html` tip step (`tipCents`, `baseCents`, `in_flight` text); deploy Worker |
| 9 | 33 campaigns | `feat/campaigns` 35e115a / `campaigns` | committed, verified, reviewed | Stage 2 email deferred by owner; encoder unification (refactor only) | none | Legal `book.html` `?c=`; apply campaigns migration; deploy Worker |
| 10 | 26 calendar sync | `feat/calendar-sync` e32aa97 / `calendar` | committed, verified, reviewed | Device evidence (EventKit) | none | Apply `20261003_calendar_busy.sql`; deploy Worker; publish privacy policy |
| 11 | 23 open API | `feat/open-api` f7a7149 / `open-api` | committed, verified, Fable SOUND | none | none | Apply open-API migration; `wrangler secret put API_KEY_TAG_SECRET` (44+ chars) and `API_CURSOR_SECRET`; legal `developers.html`; deploy Worker; flip `apiAccessEnabled` |
| 12 | 19 e-signature | `feat/esign` fc50207 / `esign` | committed, verified, Fable SOUND | none | none | Apply `20261003_esign_records.sql` (PostgreSQL 15+); `wrangler secret put` Ed25519 seal key; legal `esign.js`, `verify.html`, `estimate.html`, `change.html` (503/409 handling); deploy Worker |
| 13 | 18 Tap to Pay | `feat/tap-to-pay` a7efe31 / `tap-to-pay` (STACK TOP) | stage A committed, verified (dark) | Fable re-check of the flow before stage B | Stage B/C: Individual Apple account | Organization account + entitlement; SPM stripe-terminal-ios 5.8.x; Stripe `payment_intent.succeeded` on Connect webhook before enabling; legal/privacy wording; device evidence |

## Event log

- 2026-10-03 23:00 Survey complete (13 Haiku agents). Ledger written.
- 2026-10-03 23:05 Gate runs collide across worktrees: runners build into fixed names under `$TMPDIR`.
  Always run native runners with a private temp dir (`TMPDIR=<scratch>/tmp-<phase>/`).
- 2026-10-03 23:10 Phase 33 Worker slice (spec 9.1) confirmed complete in the `campaigns` worktree, uncommitted.
  `npm test` 127/127; Jest 3 files 84/84. Deviation kept: `cleanCampaignCode` rejects non-ASCII before
  lowercasing (closes a Kelvin-sign lookalike). Build-record text still to paste into spec section 16.
- 2026-10-03 23:15 Phase 19: the 10 red tests are a security-review hardening the spec and Worker lack
  (seal only from Worker-held `signature_pending` evidence; events bound to job and change order).
  Decision (orchestrator): harden, do not drop the tests. Opus agent amending spec 3.5/4/11.3, the
  unapplied migration and the seal path. Fable review still owed afterwards.
- In flight: gate 25/27 (fix-quote-options), aggregate 32 (main), Sonnet 28 Worker (tips),
  Sonnet 23 native (open-api), Opus 19 hardening (esign).
- 2026-10-03 23:20 Phase 28 built both sides, uncommitted in `tips`: Worker tip suites added (npm test 388/0),
  native Settings toggle + payment-history tip line + money-card caption + `run-tips-tests.sh` (112 checks,
  registered). Stricter-than-spec Worker rules kept for Fable review: 409 `tips_off` on deposit links, no tip on
  any deposit-minted link, optional `baseCents` -> 409 `changed`. State: built unverified; waits on 24 committed.
- 2026-10-03 23:20 Phase 23 native slice done, uncommitted in `open-api`: `run-api-access-tests.sh` (395 checks,
  registered); fixed name-trim mismatch with the Worker. View uncompiled until the Release compile.
  Owner step: flip `NativeAPIAccessFeature.apiAccessEnabled` after the Worker is live. State: built unverified.
- 2026-10-03 23:22 Phase 34: survey was wrong, the three referral Jest files exist and pass (npm test 163/0,
  Jest 99/99). No remaining build work; needs merge-forward and gate only.
- 2026-10-03 23:25 Phase 18 Worker slice built, uncommitted in `tap-to-pay`: `/api/terminal/*`, webhook
  `payment_intent.succeeded` branch, connect-status fields; `tests/terminal.test.cjs` 42/0, npm test 388/0.
  Open money rules for Fable review: amount sent in DOLLARS (native must match), no $0.50 floor,
  422 `not_synced` vs 404, root Jest file from spec section 9 not written (covered in Worker tests).
  Owner step: add `payment_intent.succeeded` to the Connect webhook endpoint. Native slice: Sonnet agent running
  (protocol + fake reader; no SPM package, no entitlement key added).
- In flight: gate 25/27, aggregate 32, Opus 19 hardening (esign), Sonnet 18 native (tap-to-pay).
- 2026-10-03 23:20 Gate 25/27 first pass: Worker 103/0, doc check 0 missing, Release compile BUILD SUCCEEDED.
  Aggregate stops at accessibility-audit: `FAIL: raw .borderedProminent at N/RootView.swift:234` (1 of 1969).
  Same line is on master, so this is a master baseline failure, not a phase regression (a fix exists on
  `native/booking-lead-local-date`, outside this stack). Gates now use a keep-going script
  (`<scratch>/gate.sh`) and are judged against the master baseline.
- 2026-10-03 23:30 DISK FULL (ENOSPC) killed both gate runs. Cause: 148 GB of build output left in three
  earlier sessions' scratchpads under `/private/tmp/claude-502/-Users-chadrector-dev-tradeready/`
  (310d8eb3..., 465b5e71..., 117a7fa9...; `dd*`, `t*`, `tmp*` dirs, idle since 18:10 or earlier), plus 47 GB
  Xcode DerivedData. Not deleted: not this session's data. Freed about 5 GB by removing this session's own
  temp dirs. Rule from here: one gate at a time, shared default TMPDIR, no private temp dirs, one compile at a time.
  Owner step: clear those scratchpads to restore headroom.
- 2026-10-03 23:35 Phase 19 seal hardening done (Opus), uncommitted in `esign`: seal only from Worker-held
  `signature_pending` (service-role only); events/lookups bound to owner+job+change order; spec 3.5/3.8/4/6/9/11
  amended, new 11.10. Jest esign routes 48/48, npm test 212/0, doc check 0 missing. Needs PostgreSQL 15+
  (`nulls not distinct`). Residuals for Fable review: triple-failure leaves approval unsigned while respond says
  `recordPending: true`; public view and repeat-approve still echo blob fields; owner route without recordId
  returns newest record. State: built unverified.
- 2026-10-03 23:45 Phase 18 native stage A built (Sonnet), uncommitted in `tap-to-pay`: card-present ledger
  entry, `recordCardPresentPayment`, reader protocol + unavailable + DEBUG fake reader, flow state machine,
  views, Settings checklist; `run-tap-to-pay-tests.sh` 172 checks, registered; 97 of 98 touched runners pass
  (only the master-baseline accessibility-audit line fails). Cross-cutting edits for Fable review:
  `commitInvoicePayment(exactEntry:)`, `Payment.channel`/`displayMethod` across three layers.
  Stage A is inert: `NativeTapToPayEnvironment.resources` is nil until stage B. Stage B (SDK reader) blocked on
  owner: SPM package stripe-terminal-ios-spm 5.8.x, Apple entitlement, Info.plist strings +
  `TradeReadyTapToPayEnabled`, webhook event. State: built unverified.
- In flight: serial gates g27 then g32 (with compile). No agents running.
- 2026-10-04 00:12 Gate 25/27 (keep-going): 132/134 runners pass; Worker 103/0; doc check 0 missing; compile
  succeeded on first pass. Failures = master baseline only: accessibility-audit (RootView.swift:234, 1 check)
  and layout-metrics (3 checks: RootView six tabs, CoachView.swift:68 shortcut, shortcut policy).
  Phases 25 and 27: VERIFIED against baseline. Disk now 145 GB free; parallel gates allowed again
  (private TMPDIR each).
- 2026-10-04 00:15 Owner: Apple Developer account is INDIVIDUAL. Per Tap to Pay spec R1/Q1 that cannot request
  the Tap to Pay entitlement. Phase 18 stops at stage A (commit it, flag off). Stage B/C blocked until the
  owner converts to an Organization account (legal entity + D-U-N-S) or decides otherwise.
- 2026-10-04 00:40 Gate 32: 133/136 runners; Worker 160/0; doc 0 missing; BUILD SUCCEEDED. Beyond baseline, one
  failure: save-rollback source pin flagged `withValidity` (a local named `snapshot` in a draft extension, not a
  live-snapshot write). Renamed the local; save-rollback 190/190. Phase 32 review fixes COMMITTED as 23eb243 on
  `feat/quote-expiration`; spec Status updated. Phase 32: committed + verified.
  Left uncommitted in the main checkout on purpose (not this run's work): `.claude/launch.json`, Xcode churn in
  `project.pbxproj` (drops `TradeReadyWidgets.entitlements` from an exception set: do not commit blindly).
- 2026-10-04 00:45 `feat/job-forms`: in-flight work wip-committed, 32 merged forward (9d4fd46, manifest
  regenerated). Gate g20 (with compile) running; Opus review of `feat/quote-expiration...feat/job-forms` running.
- 2026-10-04 00:45 Merging 20 into 21 hit real conflicts (10 files: insights, analytics, confirmation, runner
  lists). One Opus agent is merging the whole chain forward: 21<-20, 34<-21, 24<-34, 28<-24, 33<-28, 26<-33,
  23<-26, 19<-23, 18<-19, wip-committing dirty trees first. After it: gate each branch (3 in parallel, private
  TMPDIR), reviews per routing table (Fable for 24, 28, 18, 19, 23), then final `feat(...)` commits.
- 2026-10-04 01:30 Phase 20 DONE: gate g20 135/137 (baseline only), Worker 160/0, doc 0 missing, BUILD SUCCEEDED.
  Opus review: no P1/P2; two P3s fixed in 0b01407 (title save on end-edit/debounce; forms rebase test), compile
  re-run SUCCEEDED. Spec Status updated; tip of `feat/job-forms` is the feat(job-forms) commit. Must be merged
  forward again up the stack after the Opus chain merge finishes (two small commits past 9d4fd46).
- 2026-10-04 02:00 Gate 21 (properties, after merging 20): 135/138 runners; failures = baseline two + stale fixture
  manifest (mechanical; regenerate on the next merge-forward pass). Worker 160/0, doc 0 missing, BUILD SUCCEEDED.
  Phase 21 was reviewed in its own build record (spec 8). State: verified pending manifest refresh.
- 2026-10-04 02:00 Gate 34 (referrals, after merging 21): 136/139; same three. Worker 213/0, doc 0 missing,
  BUILD SUCCEEDED. Opus review of c087b2d running.
- Chain merge progress at 01:21: 21, 34, 24 merged; 28 in progress. Second pass needed afterwards to carry
  job-forms a0569d9 (two small commits) up the stack and refresh manifests.
- 2026-10-04 02:15 Phase 34 Opus review: no P1/P2. One P3 NOT FIXED (owner decision, spec-level): the referral
  credit balance is recomputed from current data (N/Domain/NativeReferrals.swift:258-277), so re-pointing or
  removing a referral AFTER its credit was applied can double-credit the new referrer and silently cancel the old
  referrer's next credit. Follows from spec rule R3 ("the reward moves with the referral"); needs an owner rule
  (e.g. lock a referral once its credit is applied). Phase 34: verified + reviewed, pending manifest refresh and
  spec Status update on the second merge pass.
- 2026-10-04 03:45 Chain merge pass 1 (Opus): steps 1-8 committed (692aadc, b57bff2, 1a4eaa4, e9de233, 2e7bc04,
  2965269, a82a450, b935768); dirty trees wip-committed first (autopay 5d10fa0, tips d548913, campaigns 18b28a1,
  calendar 3dc57ef, open-api 2512c2a, esign 861d9ad, tap-to-pay 7d27259). Non-mechanical resolutions: a resolved
  referral code beats a campaign code at intake (campaigns spec 9.2); duplicate `canonicalCustomer(id:)` removed;
  accounting-package CRCs re-pinned; in-row destructive pin now 25.
  Step 9 decision (orchestrator): `displayPaymentMethod("stripe")` = "Card (online)" per Phase 18 spec D6;
  AdapterTests pin updated. Phases 24/28 had "Stripe".
  Three failures found on incoming branches, being fixed at source: (1) open-api phase11-qualification catalog
  count 52 vs 54; (2) esign breaks Phase 32 quote-expiry-store "declined: unrevised re-send with a fresh date is
  still blocked" (real regression); (3) tap-to-pay layout-metrics: sheet needs `.nativeContentColumn(.list)` +
  inventory entry. Same Opus agent resumed: finish step 9, fix the three, second pass carrying job-forms a0569d9
  up, manifests regenerated on every tip.
  Note: Mac was locked 02:15-02:35; `.completeFileProtection` writes fail while locked, so store-integration and
  legacy-reimport fail then. Do not trust a gate that ran across a lock.
  Follow-up not done (campaigns spec 9.2 note): unify `NativeAttributionCode` and `NativeReferrals.makeCode`.
- After it: gates in parallel (3 at a time) for 24, 28, 33, 26, 23, 19, 18; reviews: Fable 24, 28, 23, 19, 18;
  Opus 33, 26.
- 2026-10-04 04:10 Phase 24 Fable review: TWO P1 double-charge paths in the autopay sweep, same root cause (the
  sweep never re-reads the invoice/enrollment between its start-of-run snapshot and the charge):
  P1-1 a resumed claim charges an invoice paid/part-paid/deleted meanwhile (reproduced: "paid 240 of 120";
  runAutopayCharges.js:528-541, :442, :370-383); P1-2 a completed-but-unbooked pay-page session is invisible to
  `expireInvoiceSessions` (only lists open sessions), so the sweep charges too (:259-280, :500-506).
  P2: sweep reads unpaginated (store.js:113-115,148-152,185-197): past the PostgREST row cap, due invoices are
  skipped and housekeeping can revoke live enrollments. P3: activation not retried on transient failure (per spec
  4.5); consent IP/UA readable by the owner via RLS (spec self-contradiction vs 4.8).
  Fix: Opus agent on branch `fix/autopay-sweep` in new worktree `autopay-fix` (off feat/autopay 1a4eaa4-era tip),
  to be merged into feat/autopay after the chain's second pass, then merged forward again. Repro test saved at
  `<scratch>/autopay-p1-repro.test.cjs`. Phase 24 is NOT verified until this lands and Fable re-checks the fix.
- 2026-10-04 04:20 Phase 19 Fable review: ONE P1, two P2. P1: owner-planted `approval.selection` in the job blob
  is sealed as the customer's choice on non-option estimates and all change orders (respond.js:62-75,172-176,
  changeRespond.js:103, record.js:111, pdf.js:310-314); reproduced ($5,000 document sealed with a $50,000
  "chosen option"). P2: native shows "Signed by" from the blob alone (NativeESignature.swift:305-338,
  NativeSignatureRecordView.swift:67-75,146-163). P2: residual (a), triple failure still answers
  `recordPending: true` (service.js:217-230). P3: slot collision returns stored:true on id mismatch
  (service.js:84-87); respond echoes blob recordId/digest (respond.js:234); newest-record fallback (store.js:95);
  copy email to any typed address once per link (not fixing: by design, rate-limited). Lazy-seal hardening,
  key handling, verify route, migration grants: clean.
  Fix: Opus agent on branch `fix/esign-seal` in new worktree `esign-fix`, merged into feat/esign after the chain's
  second pass. Phase 19 NOT verified until this lands and Fable re-checks.
- 2026-10-04 04:30 Phase 33 Opus review: no P1; two P2. P2: referral share ignores marketing opt-out
  (NativeReferralShareView.swift:88-100; spec 4.3/D4, deferred to the 34 merge and never done). P2: opt-out is per
  customer record, not per phone/email, so a duplicate record with the same number still gets texted
  (NativeCampaignSegments.swift:294, :357-406, liveCheck :722-737). P3: overlapping campaigns can text one customer
  twice (:531-540); tag containing `|` splits on CSV round-trip (NativeCustomerTags.swift:83-85); referral+campaign
  code together on a matched blank-source customer drops the referral (NativeBookingIntake.swift); two code
  encoders remain (not fixing: works, refactor only). Test gaps: referral-beats-campaign precedence; share opt-out.
  Merge resolutions and Worker privacy: clean.
  Fix queued (Sonnet, branch `fix/campaigns-optout` in worktree `campaigns-fix`) as soon as an agent slot frees
  (running: chain merge pass 2, autopay-fix, esign-fix).
- 2026-10-04 04:50 Autopay fix committed on `fix/autopay-sweep` 7517ba5 (Opus): one charge path
  (`processClaim`) re-reads invoice/enrollment/plan/account and lists completed sessions before every charge or
  replay; new `charge_sent_at` column on the claim (unapplied migration) so a possibly-sent charge is reconciled
  with Stripe and never released; reads paginated, read errors abort; housekeeping re-checks before revoking;
  owner cannot read consent IP/UA (column grant). npm test 418/0; doc check 0 missing. 17 new tests fail on old
  code. OPEN OWNER DECISION: money arriving for a deleted invoice: kept deleted, payment booked, owner alerted
  (payment not visible in app); alternative is to resurrect the invoice. Unverified against live Stripe:
  `status: 'complete'` list filter; 8-day lookback assumes Stripe webhook retries stop after 3 days.
  Next: Fable re-check of 7517ba5; merge into feat/autopay after chain pass 2; merge forward.
- 2026-10-04 05:05 Fable re-check of autopay fix 7517ba5: SOUND. P1-1, P1-2, P2, resurrection, consent IP/UA all
  CLOSED; new tests give 20 failures on pre-fix code. Five new P3s. Fixing four (same Opus agent resumed on
  `fix/autopay-sweep`): claim `created_at` uses run start so an overlapping run can mislabel a stamped claim
  failed; non-card 4xx on a stamped replay emails a pay link without reconciling first; recordPayment writes
  `deleted` from a stale read; a stamped claim on an unreachable account stays `in_flight` forever.
  NOT FIXING (fails safe; recorded in spec 13.7): completed-session listing is account-wide and capped at 2000 per
  8 days, above which autopay stands down for that owner.
  No second Fable re-check planned for these four unless the fix is large.
- 2026-10-04 05:20 Autopay follow-ups committed: `fix/autopay-sweep` 6875d08 (four P3s; npm test 424/0; doc 0
  missing). Residual recorded in spec 13.7: an invoice deleted between recordPayment's read and write gets the
  payment booked and stays deleted but the owner gets no deleted-invoice alert. `fix/autopay-sweep` is READY to
  merge into feat/autopay once chain pass 2 finishes.
- 2026-10-04 05:20 Reviews launched on fixed commits: Fable 28 (d548913), Fable 23 (2b683c8 + 2512c2a),
  Opus 26 (7ff0a93 + 3dc57ef). Still to launch: Fable 18 (after the merge agent's layout fix), Fable re-check of
  the esign fix.
- Running: chain merge pass 2 (Opus), esign-fix (Opus), campaigns-fix (Sonnet), three reviews.
- 2026-10-04 05:30 Phase 23 Fable review: no P1 (no auth bypass, cross-tenant read or key exposure). P2: the
  failed-auth IP block rejects VALID keys from the same IP before the Bearer is parsed (lib/api/v1.js:261-262;
  counted at :245,:266,:279): 20 junk requests/min from a shared egress IP lock out other owners' keys. P3:
  rate-limited valid keys never shed before the DB (v1.js:282-284); `.textSelection(.enabled)` on the secret
  bypasses the local-only 2-minute clipboard (NativeAPIAccessView.swift:482); 5-key cap exceedable via rotation
  grace keys (20261003_api_keys.sql:352-357,379-383). Test gaps: valid key unaffected by another caller's
  failures; real-SQL revoke/expiry/rotation only in supabase/verify/local/api_keys.sh (not run).
  Fix all four: QUEUED (Sonnet, branch `fix/open-api-guard`, worktree `open-api-fix`) for the next free slot.
- 2026-10-04 05:35 Phase 28 Fable review (d548913): nothing at P1/P2; no path to a wrong charge or balance. All
  four stricter-than-spec refusals judged right/acceptable. P3 (PLAUSIBLE): tip A -> B -> A inside one 10-minute
  bucket replays A's idempotency key and lands on an expired session (payService.js:317-326,:386; a Phase 24
  mechanism); P3 (PLAUSIBLE): a second checkout with a different tip inside webhook lag makes a fresh session ->
  overpayment (payService.js:386); P3: spec 13 lacks `baseCents`, `tip_invalid`, deposit-minted rule;
  docs/native-parity-matrix.md lacks the tips entry spec 6.3 requires.
  Fix plan: after `fix/autopay-sweep` is merged (it adds completed-unbooked session detection the pay page can
  reuse), one Sonnet agent on feat/tips: retrieve-after-create or nonce for the replay; refuse checkout when a
  recent completed session exists; docs.
  Note for owner: the in-progress `tradeready-legal/pay.html` has no tip step yet and sends neither `tipCents`
  nor `baseCents`.
- 2026-10-04 05:45 Phase 26 Opus review: no P1; privacy clean (busy intervals only, service-role table). P2: the
  job mirror adopts ANY writable calendar titled "TradeReady" when no stored id exists
  (NativeEventKitBridge.swift:165-177; enableMirror with nil id, NativeCalendarSyncCoordinator.swift:539-545) and
  removal deletes the whole calendar (Bridge:299-307; default on "Remove calendar" Coordinator:565; silently on
  account deletion :318-323) -> account B can delete account A's or the user's own calendar and events. Breaks
  spec 2.5. P3: duplicate mirror events when device zone != schedule zone at window edges (Coordinator:769-775,
  Bridge:203, NativeCalendarMirror.swift:236-237); mirror turns itself off on a transient empty read
  (Coordinator:753-762); a calendar titled "TradeReady" cannot be unchecked (Coordinator:342); background refresh
  runs the calendar step (20-40 s) before widget/Siri action replay (AppStore.swift:8873).
  Fix all: QUEUED (Sonnet, branch `fix/calendar-mirror`, worktree `calendar-fix`).
- Fix queue (slots full: chain pass 2, esign-fix, campaigns-fix): 23 open-api guard; 26 calendar mirror;
  28 tips replay/overpay (after autopay fix is merged).
- 2026-10-04 06:00 Campaigns fix committed: `fix/campaigns-optout` 2ee4b4c (Sonnet): opt-out suppression per
  normalized phone/email in segments, liveCheck and referral share; `recently_contacted` skip across campaigns;
  `|` treated as a tag separator; referral wins when both codes resolve; tests added (campaign 291, tags 124,
  referral 246). View change in NativeReferralShareView.swift NOT yet compiled. READY to merge into feat/campaigns
  after chain pass 2. Deviations kept: blocked customers also lose "Copy for manual sending"; no fallback to the
  other channel when the chosen one is opted out.
- Worktrees `calendar-fix` (fix/calendar-mirror) and `open-api-fix` (fix/open-api-guard) created.
- 2026-10-04 06:30 CHAIN MERGE COMPLETE (Opus, pass 2). Stack is linear in build order. Tips at that point:
  properties 577a05d, referrals a00e3f1, autopay 13f4a18, tips 02a20c5, campaigns d7eb4e5, calendar-sync 23dd26a,
  open-api 7f240ab, esign 957a903, tap-to-pay ab740ca. Step 9 ad816f0 ("Card (online)"). Source fixes:
  7c4ffb9 open-api (phase11 catalog pin 54 + nativeOnlyEvents); e320343 esign (root cause: esignEstimateSnapshot
  always adds e-sign fields so Phase 32's declined guard never matched a pre-19 decline; guard now ignores those
  fields only when the declined snapshot has no `esign`); ccfe368 tap-to-pay (sheet layout column, inventory,
  cancel shortcut). All nine tips: manifest check passes; 145/147 runners on the top tip (baseline two only).
- 2026-10-04 06:35 Merged `fix/autopay-sweep` into feat/autopay (99269ad) and feat/autopay into feat/tips
  (99468e6); tips npm test 466/0. Fix branches still to merge at their phase then forward: fix/campaigns-optout
  2ee4b4c (ready), fix/esign-seal (running), fix/calendar-mirror (running), fix/open-api-guard (running).
  Next free slot: tips P3 fix (replay key, overpay inside webhook lag, docs) in the `tips` worktree.
  Fable review of Phase 18 running (7d27259, ccfe368, ad816f0).
- Remaining per phase after fixes land: third merge pass (mechanical), gates (3 parallel) for 24, 28, 33, 26, 23,
  19, 18 plus re-gate 21/34 tips, spec Status lines + final feat(...) commits, Fable re-check of esign fix.
- 2026-10-04 06:50 Open-API fix committed: `fix/open-api-guard` a69a535 (Sonnet). Bearer parsed first; IP guard
  blocks only keyless/malformed traffic; hash-keyed negative cache (5 unknown per 60 s) and rate-limited shed;
  maps capped at 2,000; `.textSelection` removed with a source-scan check; key cap: 5 live + at most 5 grace
  (10 working) because a hard 5 would make rotate fail (spec 14.4 #2). npm test 555/0; Jest 44/44; api-access 397;
  local Postgres harness 61/0 (7 fail on the old migration). READY to merge into feat/open-api.
  Owner note: max working keys is 10, not 5, during rotation grace.
- Tips P3 fix (Sonnet) running in `tips` on feat/tips.
- 2026-10-04 07:00 Automated commit security check flagged "resource-cap-defeat in backend-workers/lib/api/v1.js"
  on a69a535 (details not delivered). Inferred gap: distinct well-formed random keys bypass both the IP guard and
  the per-hash negative cache -> unbounded authorize RPCs. Same Sonnet agent resumed: unknown-hash failures count
  per IP, small per-IP RPC budget for unknown hashes once over threshold, bounded positive cache of known-good
  hashes (RPC still called). fix/open-api-guard NOT ready until that commit lands.
- 2026-10-04 07:05 Phase 18 Fable review (tip ab740ca): no P1; stage A safe to ship dark (nothing renders or
  charges in Release). P2 (PLAUSIBLE, must fix before stage B): after an ambiguous reader failure the amount is
  editable and a retry with a new amount mints a second PaymentIntent (NativeTapToPayFlow.swift:126,154-159;
  NativeTapToPayViews.swift:82). P3: 422 `not_synced` vs 404 leaks invoice existence, ids guessable
  (lib/terminal/terminal.js:163-168); Close enabled during "Preparing" (Views:98); no sub-$0.50 floor ->
  misleading `stripe_rejected` (routes/terminal.js:40-42); "Card (online)" label maps to `other` in void analytics
  (AppStore.swift:4900, NativeAnalyticsEvents.swift:290); reader's PaymentIntent id not cross-checked
  (Flow:166) and pendingEntry nil if ledgerEntry throws; invoice-number edit between retries -> 409 forever.
  Gaps: root Jest file from spec 9 absent and unrecorded; tests for amount change after reader error, sub-$0.50,
  mergeInvoice with device+webhook copies. Stage C ordering (webhook subscribed before enabling) must hold.
  Fix all: QUEUED (Sonnet, in `tap-to-pay` on feat/tap-to-pay) for the next free slot.
- Running (4, one over the cap until one finishes): esign-fix (Opus), calendar-fix (Sonnet), tips fix (Sonnet),
  open-api guard follow-up (Sonnet).
- 2026-10-04 07:15 Open-API guard follow-up committed: fix/open-api-guard 2f985f6. 500 distinct unknown keys from
  one IP cost exactly 25 RPCs; positive cache (hash only, 5 min, cap 500) never skips the RPC. Jest 48/48; npm
  test 556/0. Known limit: a client with many IPv6 addresses can still churn the per-IP maps.
  Merged fix/campaigns-optout into feat/campaigns and fix/open-api-guard into feat/open-api (local).
- 2026-10-04 07:25 Second automated check on 2f985f6: "denial-of-service / lockout regression" in v1.js (details
  not delivered; the notice says "pushed commits" but nothing has been pushed). Reading: the accepted trade-off
  (flood on a shared IP drains the budget and locks out valid keys the isolate has not seen). Same agent resumed:
  valid keys refund the budget; known-good window 60 min; residual stated in spec 14.4a (full fix needs a shared
  store = new service, out of scope). fix/open-api-guard gets one more commit, then re-merge into feat/open-api.
- 2026-10-04 07:30 Tips fix committed on feat/tips 8e938b9 (Sonnet): live-status read after every create with
  re-mint on expired; 409 `in_flight` when a completed session is unbooked; session helpers extracted to
  lib/autopay/sessions.js (sweep behaviour unchanged, autopay tests green); spec 13.2; parity matrix rows.
  npm test 479/0. Owner notes: each checkout makes one extra Stripe GET; `in_flight` message text changed
  ("A payment for this invoice is being processed") and `tradeready-legal/pay.html` handling of it is unchecked.
- Phase 18 fix (Sonnet) running in `tap-to-pay`. Also running: esign-fix (Opus), calendar-fix (Sonnet),
  open-api guard round 3 (Sonnet).
- 2026-10-04 07:40 Open-API guard round 3: fix/open-api-guard a750759, merged into feat/open-api. Valid keys
  refund the blocked-IP budget; known-good window 60 min, cap 1,000; flood bound still exactly 25 RPCs;
  Jest 50/50; npm test 556/0. Residual (spec 14.4a, for the final report): during an active flood from a shared
  IP, a valid key not seen by that isolate in 60 min can get 429 if attacker requests hold all five budget slots
  at that moment; full fix needs a shared store (new service).
- 2026-10-04 07:55 Third automated flag on the open-API guard (a750759): "resource-cap-defeat" in auth.js and
  v1.js, no details. Stopped guessing; Fable re-check of the guard at ba0d7b7 measured: P1 outage makes the bound
  infinite (refund on unavailable/throw: 1,000 keys -> 1,000 RPCs); P1 threshold counts outcomes not admissions
  (3 concurrent bursts -> 3,000 RPCs); P1 no global cap, IPv6 /64 rotation -> 5,000 RPCs; P2 churn evicts failure
  counters; P2 no in-flight cap for known keys (2,000 concurrent -> 2,000 RPCs); P3 cross-window refund; P3
  missing-IP shared bucket. Two Sonnet attempts failed -> escalated to OPUS on fix/open-api-guard with the
  reviewer's single design: client key = IPv4 or IPv6 /64; positive-cache keys max 4 in flight; other keys take a
  per-client (10/60 s) and a global per-isolate (60/60 s) token BEFORE the await; refund only on ok/rate_limited in
  the same window; negative-cache denials 60 s; junk path only affects keyless traffic.
  OWNER DECISION (not built): self-verifying keys (HMAC tag in the key, checked before any RPC) would close the
  residual lockout without a shared store; costs one Worker secret and a key-format change.
  Phase 23 NOT verified until this lands; re-merge into feat/open-api afterwards.
- 2026-10-04 08:10 Calendar fix committed: fix/calendar-mirror 9d9fbba (Sonnet), merged into feat/calendar-sync.
  Mirror calendar found by stored id only; adoption/removal decided in the domain layer by owner tag; plan matches
  by job id; fetch margin 2 days (zones can be 26 h apart; with margin 0 the edge tests show 5 duplicates);
  transient empty read no longer disables the mirror; picker hides only the own mirror; calendar step now last in
  background refresh. calendar-sync 195 checks; store-integration, save-rollback pass.
  Untested (EventKit adapter, compile-only): findMirrorCalendar, createMirrorCalendar, mirrorEvents slicing,
  `apply` guard. Residual: ownership judged over today +/- 5 years. Needs device evidence.
- 2026-10-12 07:00 RESUME (new session; previous one cut off by usage limits about 2026-10-04 05:13 local). Survey: the
  three in-flight fixes left uncommitted work, untouched since 10-04: `esign-fix` (fix/esign-seal, 15 files),
  `open-api-fix` (fix/open-api-guard Opus round 4, 7 files), `tap-to-pay` (Phase 18 review fixes, 12 files).
  The old scratchpads under `/private/tmp/claude-502/` are already gone (tmp cleared); disk 99 GB free. The old
  `<scratch>/gate.sh` and `<scratch>/autopay-p1-repro.test.cjs` went with them (the repro is covered by committed tests).
  Relaunched all three agents to finish, test and commit on their own branches.
- 2026-10-12 07:10 Open-API guard round 4 committed: fix/open-api-guard 3a65522 (Opus). Reviewer's design built:
  admission-counted per-client (10/60 s, IPv4 or IPv6 /64) and global (60/60 s) tokens taken before the await; known
  keys max 4 in flight, map cap 1,000 (new key 429 at saturation, a deviation that keeps the 4-per-key cap); refund only
  ok/rate_limited in the same window. Measured: outage 1,000 keys -> 10 RPCs; 3 bursts -> 10 each; /64 rotation -> 10;
  5,000 clients -> 60/window; 2,000 concurrent one known key -> 4. Re-ran myself: npm test 562/0, Jest 63/63.
  Fable re-review of a750759..3a65522 running. Not merged into feat/open-api until it is SOUND.
- 2026-10-12 07:20 Fourth automated flag on the guard (3a65522), with details this time: MEDIUM lockout. Six junk-key
  clients drain GLOBAL_TOKENS (60) and every valid key outside the positive cache gets 429 for the window.
  OWNER DECISION (2026-10-12): build HMAC self-verifying keys (tag checked with a Worker secret before any budget or
  RPC). New owner-run step: `wrangler secret put` for the key-signing secret before deploy. Implementation waits for the
  Fable re-review so its findings go to the same agent.
- 2026-10-12 07:15 Fable re-review of the open-API guard 3a65522: SOUND for its RPC bound (all claimed numbers
  reproduced; slots release in finally; IPv6 spellings and IPv4-mapped collapse correctly). P2 CONFIRMED: lockout costs
  60 req/min from 6 IPv4s or 6 /64s (one /48) and can be held indefinitely. Options 1-3 can't fix it; HMAC tags can.
  Follow-ups folded into the HMAC brief: negative-cache revoked/expired keys for their lifetime; per-owner budget via a
  key id in the tagged key; docs "60 + refunded admissions". HMAC round 5 (Opus) running on fix/open-api-guard.
- 2026-10-12 07:20 Phase 19 esign fix committed: fix/esign-seal 6a3d57c (Opus). Evidence stored before the decision;
  503 `signature_not_recorded` when it can't be; selection sealed only on option estimates, matched to the frozen
  snapshot; native shows signer only from a Worker-confirmed sealed record; owner route requires recordId. npm 606/0,
  Jest 61/61, esign 224 checks. Spec 11.11 records deviations (evidence-first replaces 3.5; recordId required; no
  per-link uniqueness on `signature_pending`). Owner note: legal signing pages must handle the new 503.
- 2026-10-12 07:15 RELEASE COMPILE FAILED on fix/esign-seal: NativeRecurringInvoicesView.swift:104 "unable to
  type-check this expression in reasonable time". Root cause is Phase 24 (5d10fa0 grew the plans List body), carried
  into every branch from 24 up; nothing from 24 up had been compiled. Fixed at source: feat/autopay dafca3c (plans
  section split into a property; no behaviour change). Autopay compile SUCCEEDED; recurring-invoice, save-rollback pass;
  a11y and layout-metrics only the baseline failures.
- 2026-10-12 07:25 Third merge pass: autopay -> tips aaf57ae -> campaigns fb054dd (parity-matrix conflict resolved,
  keeping both the Phase 33 Tags note and the Phase 28 tips note; manifest regenerated; npm 496/0) -> calendar-sync
  ab3c07b -> open-api 5393d63 -> esign cd7b416; fix/esign-seal merged into feat/esign da99838 (compile SUCCEEDED,
  npm 649/0).
- 2026-10-12 07:30 Phase 18 review fixes committed: feat/tap-to-pay f7adb32 + bea5774 (Sonnet). Amount and operation
  locked once collection starts; after a reader error the outcome is read back with `status(of:)` (succeeded books
  once, canceled unlocks, requiresPaymentMethod retries the same op, unknown stays locked); uniform 422 for
  missing/foreign invoices; Worker 400 `below_minimum` under $0.50 and a matching native check; "Card (online)" and Tap
  to Pay map to `stripe` in analytics; the reader's PaymentIntent id is cross-checked; invoice number frozen per
  operation (optional `invoiceNumber`, spec 2.1). Fixed an intermittent hang in the FakeTerminalService test fake.
  tap-to-pay 244/0, npm 648/0. Residual: closing the sheet while the outcome is unknown lets a new sheet start a new
  operation (in the build record). `status(of:)` is a stub until stage B. No re-review now; a Fable re-check of the
  flow is due BEFORE stage B.
- 2026-10-12 07:35 Merged feat/esign into feat/tap-to-pay 008d667. Stack top: Release compile SUCCEEDED, npm 694/0,
  doc check 0 missing, manifest current. Full native aggregate running at the top tip.
- 2026-10-12 07:35 Fable re-check of the esign fix (b935768..6a3d57c): SOUND; P1, both P2s and P3s CLOSED; no P1/P2
  regressions. New P3s queued to Sonnet on fix/esign-seal: re-run of the migration keeps the old per-link constraint;
  500 on a missing snapshot; legacy blob selection echo; native confirmation flash on a record-id change; document that
  `signature_pending` rows are retained (append-only).
- 2026-10-12 07:55 Esign P3 follow-ups committed: fix/esign-seal f4c4228 (Sonnet), merged into feat/esign 2464d8a
  (compile SUCCEEDED, npm 649/0). Migration re-run now drops the old per-link constraint (verified converging on a
  throwaway DB; esign_records.sh 11/0); 409 `snapshot_missing`; the legacy selection is echoed only when it
  re-resolves against the snapshot (residual in spec: on a pre-record approval, a planted valid tier can't be told from
  the customer's); native confirmation keyed to the record id; `signature_pending` retention documented. Jest 65/65.
- 2026-10-12 08:00 HMAC keys committed: fix/open-api-guard 0a61dc7 (Opus, 19 files). `trk_` + 80 bytes (key id | owner
  id | 32 random | 128-bit HMAC-SHA256 tag, secret `API_KEY_TAG_SECRET`). Forged keys: 0 RPCs/tokens/cache entries;
  6-IP drain no longer locks out valid keys; revoked/expired replay: 1 RPC for the key's life; per owner 10/window;
  missing secret 503 `not_configured`. `api_key_admin` gains `p_new_key_id` (unapplied migration drops the old overload).
  npm 569/0, Jest 70/70, api-access 398, api_keys.sh 68/0. New OWNER STEP (spec 14.8 2a): `wrangler secret put
  API_KEY_TAG_SECRET` (32+ random bytes) before deploy; update `developers.html` for the new key length.
  Fable review running. Merge into feat/open-api after it is SOUND.
- 2026-10-12 08:20 Fable review of HMAC keys (3a65522..0a61dc7): SOUND for crypto (tag-bit and spelling flips all
  rejected; constant-time; secret never logged), minting (owner from JWT, key id from CSPRNG, ownership checked in SQL)
  and auth. Random-key lockout P2 CLOSED. New P2 CONFIRMED: dead keys still drain the isolate bucket, so 6 accounts'
  revoked-key pool (2,004 keys) or 6 deleted accounts (`invalid_key` cached only 60 s) lock out unseen valid keys in
  120/120 windows; 200 accounts x 5 live keys evict the positive cache. P3: secret minimum is 32 chars, not 32 bytes;
  HMAC runs before the junk-counter check. Round 6 (same Opus agent): `invalid_key` one-way dead; denials charged
  per owner; churn-resistant caches (LRU, per-owner caps); durable per-owner mint limit in `api_key_admin`; secret >= 44
  chars. Phase 23 not verified until this lands and is checked.
- 2026-10-12 08:45 Open-API round 6 committed: fix/open-api-guard 8a998a7 (Opus). `invalid_key` for a tag-valid key cached
  for life; shared pool 60 plus a 240 reserve for owners holding no token (hard bound 300 + refunds; the first RPC
  failure closes the reserve so an outage stays 60); negative cache 10,000 (100 per owner), positive cache 10,000 (10 per
  owner, LRU on hit); `api_key_admin` 20 create+rotate per owner per rolling 24 h; secret >= 44 chars. Reviewer's
  scenarios: victim authorized in every window. Re-ran: npm 572/0, Jest 74/74; api_keys.sh 75/0 (agent). Residual: N
  accounts get min(10N, 300) dead-key RPCs per window. Focused Fable re-check running.
- 2026-10-12 08:45 Stack top: merged feat/esign into feat/tap-to-pay 8fe5b85. The first aggregate stopped at the
  baseline a11y failure (the aggregate is fail-fast); the keep-going gate script was rebuilt at `<scratch>/gate.sh` and is
  running.
- 2026-10-12 09:10 Fable focused re-check of round 6: SOUND; P2 CLOSED (scenarios a/b/c lock the victim out in 0/120
  windows); 300 bound hard under concurrency; reserve close-on-failure not attacker-reachable; mint-limit SQL serialised
  by an advisory lock. One P3 fixed in round 7, fix/open-api-guard 0d173a8: one unrefunded reserve take per owner per
  GLOBAL window (straddling owner windows had allowed two, so a lockout needed only 126 accounts; the spec now says 246,
  as measured). Spec 14.9 residual: rotating at the mint limit answers rate_limited and leaves the old key live (revoke is
  not limited). Re-ran: npm 572/0, Jest 75/75.
  PHASE 23 guard work DONE. Merged fix/open-api-guard into feat/open-api 039524c; feat/open-api into feat/esign 61d5d0b
  (wrangler.toml comment conflict: kept both the ESIGN_SEAL_PRIVATE_KEY and API_KEY_TAG_SECRET lines). esign tip: npm
  665/0, Release compile SUCCEEDED.
- 2026-10-12 09:30 STACK TOP feat/tap-to-pay 4242ea0 (all fixes merged up): Release compile SUCCEEDED; npm 710/0; doc 0
  missing; manifest current; keep-going gate 147/149 at 8fe5b85 with only baseline a11y/layout failures; after the open-API
  merge, api-access 398, error-redaction, ai-provider-key, phase11, save-rollback, support-diagnostics, registration all
  pass. All three interrupted fixes are DONE. Remaining for the run: own-branch gates for 21, 34, 24, 28, 33, 26, 23, 19 (the
  stack top passing covers their code, but each tip is still unverified alone); spec Status lines; final feat(...)
  commits.
- 2026-10-12 13:10 RESUME 2. The previous session had run all eight own-branch gates (09:01-11:44). Beyond the baseline
  a11y/layout failures, five runners failed with EPERM ("Operation not permitted" on protected-file writes: the Mac-lock
  signature). Re-ran them serially: legacy-reimport on 21/34/24 (933 checks each), migration-coordinator and
  store-integration on 23, repository on 19: all PASS. Release compiles: 21, 34, 24 (previous session) and 28, 33, 26, 23, 19
  (now) all BUILD SUCCEEDED. Worker npm test green on every tip (160 to 665). Doc check 0 missing everywhere.
- 2026-10-12 13:15 Final commits: spec Status lines on all nine specs (21 2b625cb, 34 bd8cade, 24 d7aebad, 28 3d53c7a,
  33 35e115a incl. new spec 16.7 recording the §9.1 Worker slice, 26 e32aa97, 23 f7a7149, 19 fc50207, 18 a7efe31), each
  branch merged forward before its commit. Stack top differs from verified 4242ea0 only in those spec files; doc, manifest
  and registration checks pass there. RUN COMPLETE: every phase committed and verified; 18 stages B/C blocked on owner.
- 2026-10-12 13:40 BASELINE FIX (owner: "fix what's not fully green"). Cherry-picked 97be13e (from
  `native/booking-lead-local-date`, never merged to master) onto feat/quote-options as c5eaabe: Ask Coach button uses
  `tradeReadyProminentButtonStyle()`, Coach Done gets `.keyboardShortcut(.cancelAction)`, LayoutMetricsTests expects five
  tabs. Merged forward through all 13 branches (manifest regenerated each step; no other conflicts). accessibility-audit
  and layout-metrics now PASS on every tip (top: 2286/2286, 1110/1110). New tips: 27 1d80935, 32 e5b2f09, 20 cfd14c3,
  21 bbb1645, 34 60c49f3, 24 71ecaea, 28 0373919, 33 7f494e2, 26 46d91f1, 23 c887497, 19 836ce0f, 18 e255c96.
  Note for owner: when `native/booking-lead-local-date` merges to master, 97be13e and c5eaabe are the same change.
- 2026-10-12 14:30 Stack-top check after the baseline fix: Worker 710/0, doc 0 missing, Release compile SUCCEEDED. The
  fail-fast aggregate stopped at store-integration (launch migration FAILs, then a crash on missing
  `LaunchNative/store.json`). Cause: the SCREEN WAS LOCKED (`CGSSessionScreenIsLocked` true; a one-line
  `.completeFileProtection` write fails too). The old open-api commit 039524c, which passed at 12:50, fails identically
  now, so this is not a regression. A background job waits for unlock, then re-runs the full aggregate at the top
  (log: `<scratch>/unlocked-run.log`).
- 2026-10-15 RESUME 3. The 2026-10-14 09:39 post-unlock re-run died after one minute (log stopped at "Mileage log tests
  passed"; no exit line). Re-ran `sh native/run-all-domain-tests.sh` at the stack top feat/tap-to-pay e255c96 with a
  private TMPDIR, screen unlocked throughout: exit 0, 0 FAIL lines; accessibility-audit 2286/2286, layout-metrics
  1110/1110, canonical AppStore integration PASS, migration coordinator PASS. With the 14:30 Worker 710/0, doc 0 missing
  and Release compile SUCCEEDED, the stack top is fully green. RUN COMPLETE, nothing outstanding except owner steps.
- Main checkout (feat/quote-expiration) still carries pre-run dirt, not part of any phase: a 2026-10-02 re-serialized
  `project.pbxproj` that also drops `TradeReadyWidgets.entitlements` from the widget folder's membership exceptions
  (added on purpose in c35c248), an owner `launch.json` entry for the promo Remotion studio, and stale untracked
  drafts of the 20/21/26/33/34 specs whose committed versions live on the phase branches.
- 2026-10-15 Ship wizard (`scripts/ship-roadmap-wizard.sh`) stage 4 failed on the owner's run: the invoice-payment merge
  verify. Nothing in the repo records `20260718_invoice_payment_merge.sql` as applied to production
  (`docs/deposits-resume-here.md` still says NOT applied), and autopay spec §9 step 1 only says "confirm". Stage 4 now
  checks the `invoices.id` type, that `auth.users` has a row (the verify seeds against one), and that
  `merge_invoice_payments_trg` exists, offers to apply the migration if not, and prints psql's error on failure. Tested
  on a throwaway local Postgres: no user -> "no auth.users row"; no trigger -> "CHECK 2 FAILED"; after apply ->
  "ALL CHECKS PASSED", 0 rows left behind.
- 2026-10-15 Stage 4 second failure: `public.invoices.id` type came back empty, i.e. the pasted connection string reached a
  database with no visible `public.invoices`. Nothing pointed at an inherited `DATABASE_URL`, so most likely another
  Supabase project's string (unconfirmed). The wizard now refuses a database without `public.invoices`, warns when the
  string lacks project ref `ncbqswfdvckmdocbawaa`, prints user/database/table count on connect, and reads the id type
  from `pg_attribute` (not privilege-filtered `information_schema`). Tested on throwaway Postgres.
- 2026-10-15 Owner progress: wizard stages 1-14 done (migrations applied and verified, open-API secrets set, Worker
  deployed). At stage 15 the owner reported an event missing from the Connect endpoint's list (which event not yet
  confirmed). Stage 15 now checks mode, URL and Connected-accounts scope, and checkout.session.completed separately from
  adding payment_intent.succeeded (same endpoint: the Worker verifies against one signing secret). Stage 17 now
  requires stage 15.
- 2026-10-15 Owner: neither checkout.session.completed nor payment_intent.succeeded is on the endpoint they found. No
  record says Stripe live payments were ever activated; the 2026-08-05 runbooks put the Worker endpoint in the SANDBOX,
  and live mode has a separate webhook list. Likely they were looking in live mode (unconfirmed). Stage 15 now asks
  which mode applies; the go-live runbook Part 2 now lists both events on the one live endpoint.
- 2026-10-15 CORRECTION to the entry above: the owner was in live mode and checkout.session.completed IS on the live
  Worker endpoint, and on the sandbox one. So live payments were activated (the go-live runbook ran; the repo just never
  recorded it). Only payment_intent.succeeded is missing, as expected; stage 15 adds it to the live endpoint, then the
  sandbox one. Wizard text fixed.
- 2026-10-15 Owner: payment_intent.succeeded added to the live and sandbox Connect endpoints (checkout.session.completed
  already on both). Wizard stage 15 marked done. Next: stage 16, legal pages (waits on the reviewed text).
- 2026-10-15 Legal wording applied, uncommitted, in tradeready-legal for owner review before wizard stage 16:
  terms.html §4 (autopay paragraph; "does not hold funds or act as a payment intermediary"), §7 API access paragraph,
  §8 expiry sentence (32-B, newly drafted); privacy.html §1 calendar, customer-requests (32-B, newly drafted), referral,
  autopay bullets, §4 Stripe clause + new Resend and Cloudflare bullets (33-P, newly drafted), §5 API sentence.
  Effective dates set to 2026-10-15. E-signature (19-Q4) and Tap to Pay (18-Q6) wording NOT applied: later stages.
- 2026-10-15 Owner approved the stage 16 wording in terms.html and privacy.html as applied, including the four new drafts
  (terms §8 expiry sentence, privacy "Customer requests", Resend and Cloudflare bullets). Ready for wizard stage 16.
- 2026-10-15 Owner lifted the e-signature lawyer review (19-Q2 now "approved as drafted"; decisions doc updated). The
  esign spec §11.6 terms §8 / privacy §1 rewrite is pre-applied, uncommitted, in tradeready-legal (with the 32-B expiry
  sentence kept in the new §8) so wizard stage 22 publishes it together with verify.html, right after ESIGN_V2 is on.
  Nothing else may commit tradeready-legal before stage 22, or the e-signature terms go live early. Owner is at stage 19.
- 2026-10-15 Stage 19 version: 2.0.0 (native N, never submitted; must stay below Expo rollback candidate R 2.1.1),
  build 15 (above every recorded upload: native 2.0.0 builds 1-3, R build 14; owner to confirm nothing higher in
  TestFlight). Upload via `native/phase-12-testflight-upload.sh`, not Xcode's Archive menu (project build number is 1).
  Wizard stage 19 updated (atomic swap; the owner's running copy keeps the old text).
- 2026-10-15 Archived 2.0.0 (15) from master 905bd76 (API access on), owner-approved, without the Sentry DSN (owner:
  "crash reporting off is fine for now"): ARCHIVE SUCCEEDED; app + widget 2.0.0 (15), codesign verify OK, dSYMs present.
  At ~/Library/Developer/Xcode/Archives/2026-10-15/, opened in Organizer for the owner to Distribute › Upload.
  Not uploaded by the agent. A later build with the DSN needs build 16+.
- 2026-10-15 Organizer upload of 2.0.0 (15) warned: no dSYM for Sentry.framework (UUID 761704F3-…, matches the embedded
  binary). sentry-cocoa 9.29.0's prebuilt SPM Sentry.xcframework ships no dSYMs and its binary has no DWARF/OSO
  entries, so no real dSYM can be produced locally. Non-blocking: only Apple-side symbolication of frames inside
  Sentry.framework is lost (the app's own dSYMs are in the archive). Not fixed.
