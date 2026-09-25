# Phase 12 Deferred Device and Staging Evidence Index

Created: 2026-09-25 by task 12.03 of the
[Phase 12 implementation plan](native-phase-12-implementation-plan.md). Source line
numbers are at commit `1c6859a` (branch native/phase-12).

## 1. Purpose

Phases 2–11 deferred every physical-device, isolated-staging, TestFlight and store check
to Phase 12 (roadmap "Verification deferral decision (2026-09-16)", RM L13–40). This
index puts those checks in one place so the stage owners can run them:

- the rows of the Phase 2/3, 4, 7, 9, 10 and 11 device runsheets and the Phase 2, 3 and 4
  contract docs;
- the Phase 5, 6 and 8 rows, which had no runsheet. They are recovered from the roadmap,
  the parity matrix and the Phase 8 plan, spec and contract decisions, and every one cites
  the line it came from;
- the three plan §7 items routed to 12.03, each linked onto its existing Phase 11 row;
- the charter §5.1 G1 waiver condition (an upgraded device keeps its Expo push token);
- the App Store rating-prompt check that commit `1e47f26` deferred.

Every source row maps to exactly one index row. Where several sources describe the same
scenario, one row cites all of them (§7 lists the counts, and each phase section lists
its merges). 12.04 (Stage A), 12.05 (Stage B) and 12.07 (Stage C) run the rows and
append their run records in §24. 12.00b, 12.02 and 12.06 append their own device rows
in §23.

## 2. How to use

1. **A row closes only with real evidence**: a physical device, a TestFlight build,
   App Store Connect or the released App Store build. A host test, simulator run,
   generic or unsigned build, or source reading never closes a row.
2. **Record** in the Evidence column: `[x]`, the date, the build number, the device
   model and OS, a team or synthetic account alias, the environment (REL, STG, …) and a
   link to evidence kept outside the repository. Never record an email, token, key,
   DSN, full device identifier, raw backend URL or customer data (DTR L72–84,
   P4R L77–87).
3. **A failing row** becomes a defect (`P12-001` onward, charter §2 rule 4) with the
   build number. It is never silently waived. A waiver needs a dated owner entry in the
   decision log, linked on the row.
4. **Never mark a parity row `Verified` from this index.** A parity row moves only when
   its full evidence set exists (parity matrix, "Evidence required for `Verified`").
   §22 shows which index rows feed each parity row.
5. **STG rows** run only on a staging-configured signed Release build (SETUP-STG-5)
   with team accounts against the isolated staging backend. `https://staging.invalid`
   stays until staging exists, and production is never substituted (D4, PL12 L222). A
   cohort user on production never produces STG evidence; a cohort observation may be
   linked as supplementary only. While D4 is open, an STG row is **blocked, not
   waived**.
6. **Stage** column. The plan asks for Stage-A-eligible versus Stage-B-eligible rows
   (PL12 L524–526), and charter §4.3 lets the owner move a row to Stage B only if it is
   Stage-B-eligible, so the column uses five values:
   - **A**: runs in Stage A (internal TestFlight, team and synthetic accounts, staging
     where the row says STG). It must have evidence by Stage A exit.
   - **A/B**: Stage-A-eligible and also Stage-B-eligible (Stripe test mode, booking or
     portal, recurring work, iPad, mixed-client, established history). Run it in
     Stage A where possible; the owner may log its move to Stage B (charter §4.3).
   - **B**: needs the external cohort itself (cohort aggregates).
   - **C**: needs the production release or App Store Connect entry at Stage C.
   - **X**: not a device row: setup, an implementation gate or a decision.
7. **Prerequisites.** Every row whose environment includes REL, REL+KEYS or DBG needs
   SIGN-1, VER-1 and TF-INT (DBG needs SIGN-1 only). The Prereqs column lists only the
   extra ones; "—" means none. §5 defines each name.
8. **Merged rows** cite every source. An ID written "X (= Y)" carries both IDs because
   other docs refer to both.
9. **Order.** Run the setup rows (§9) first; they satisfy STG, DEV2, RN-STG and the
   preflights. Then run by stage.

## 3. Environment and build codes

The first nine codes are the Phase 11 runsheet's (P11R L38–48); the rest are added here.

| Code | Meaning |
|---|---|
| **REL** | The signed Release build of the stage (the 12.04 internal TestFlight build; record the build number). The widget extension must be embedded (P11R L40) |
| **REL+KEYS** | REL with the owner's staging PostHog key and host and staging Sentry DSN supplied at build time; nothing committed (P11R L41) |
| **DBG** | A Debug build, used only to prove it sends nothing (P11R L42) |
| **SE17** | iPhone SE-class on iOS 17.x (P11R L43) |
| **STD18** | A standard iPhone on iOS 18.x (P11R L44) |
| **PM27** | iPhone 16 Pro Max on iOS 27.0, the recorded baseline device (P11R L45; DTR L45–46) |
| **IPAD** | iPad 11-inch and iPad mini on iPadOS 27, and an iPad 13-inch where a row says so (P11R L46) |
| **STG** | The trusted isolated staging backend, reached from a staging-configured REL (SETUP-STG-5). Blocked while D4 is open (P11R L47) |
| **RN-UP** | A device upgraded in place from the App Store Expo build, no delete (P11R L48) |
| **IPH** | Any physical iPhone on a supported iOS (17 or later). Record model and OS |
| **+DEV2** | A second physical iPhone running the same native build, signed in to the same account |
| **+RN2** | A second physical iPhone running the current React Native build, signed in to the same account (P4R L62–63) |
| **DEV-SIGNED** | A development-signed build installed from Xcode on a physical device. Only this build type shows the StoreKit review sheet on demand (P12-RATE-1) |
| **APPSTORE** | The released App Store build (Stage C) |
| **ASC** | App Store Connect, used by the owner |
| **BROWSER** | A browser on the hosted customer pages (estimate, change, booking and portal pages; see HOSTED) |
| **Archive of REL** | The 12.01 archive of the stage build (P11R rows EXT-4, CR-1, CR-9) |

## 4. Source aliases

| Alias | Source |
|---|---|
| DTR | `docs/native-device-test-runsheet.md` (Phase 2 and 3 consolidated runsheet) |
| P2P | `docs/native-phase-2-persistence.md` |
| P3M | `docs/native-phase-3-device-matrix.md` |
| P3S | `docs/native-phase-3-staging.md` |
| P4R | `docs/native-phase-4-device-runsheet.md` |
| P4B | `docs/native-phase-4-background-refresh.md` |
| P4J | `docs/native-phase-4-job-photo-transfer.md` |
| P4X | `docs/native-phase-4-mixed-client-convergence.md` |
| RM | `docs/native-ios-migration-roadmap.md` |
| PM | `docs/native-parity-matrix.md` |
| P7R | `docs/native-phase-7-device-runsheet.md` |
| PL8 | `docs/native-phase-8-implementation-plan.md` |
| P8S | `docs/native-phase-8-calendar-booking-routes-portals-spec.md` |
| P8C | `docs/native-phase-8-contract-decisions.md` |
| P9R | `docs/native-phase-9-device-runsheet.md` |
| P10R | `docs/native-phase-10-device-runsheet.md` |
| P11R | `docs/native-phase-11-device-runsheet.md` |
| CH | `docs/native-phase-12-cutover-charter.md` |
| PL12 | `docs/native-phase-12-implementation-plan.md` |
| 1e47f26 | Commit `1e47f26`, "feat(native): ask for an App Store rating after the owner gets paid" |

No Phase 5 or Phase 6 plan doc exists, and no Phase 8 device runsheet exists (PL8 L397–400
planned one in task 8.15; PL8 L455–461 records every Phase 8 task as pending).

## 5. Prerequisites (status on 2026-09-25)

| Name | What it is | Owner | Status on 2026-09-25 | Blocks | Source |
|---|---|---|---|---|---|
| **STG** (D4) | A trusted isolated staging backend: a separate Supabase project or branch, staging R2 buckets and a deployed staging Worker, reached from a staging-configured REL. SETUP-STG-1 to SETUP-STG-5 build it | Owner | **Not provisioned. D4 answered "Not yet": a hard blocker.** `https://staging.invalid` stays; production is never substituted | Every row with STG; SA3; Stage A exit | PL12 L222; CH L163; P4R L16–37 |
| **SIGN-1** | A signed Release build with the App Group for `TradeReadyWidgets` (owner signs in to Xcode) | Owner, then 12.01 | Open | Every REL, DBG, TestFlight and archive row; Stage A entry | CH L159 |
| **VER-1** | Native `MARKETING_VERSION` above the live Expo version 1.2.1 | Owner, then 12.01 | Open | Stage A upload (TF-INT); 12.06 numbering | CH L160 |
| **OI-1** | Privacy-label declaration of first-party backend data (email, synced records, photos) | 12.01 decides; owner enters labels | Open | EXT-4; PRIV-1 (labels entered at Stage C entry) | CH L161; P11R L61 |
| **OI-2** | Sentry project `tradeready-ios` in org `tradeready-3r` | Owner | Open (project does not exist) | CR-1 to CR-9, AI-5, PERF-9 | CH L162; P11R L62 |
| **KEYS** | The owner's staging PostHog key and host and staging Sentry DSN, supplied at build time for REL+KEYS; and the owner's own Groq and Anthropic keys, entered on device for live-AI rows. Never committed | Owner | Not supplied | REL+KEYS rows; AI-1, AI-5, P7-20, P9-15, P9-31, P10-18, P10-19, P10-28 | P11R L41, L154; P10R L97; P9R L38, L60 |
| **TF-INT** | Internal TestFlight upload of the stage build (owner-authorized App Store Connect action) | Owner (12.04) | Not uploaded; needs SIGN-1 and VER-1 | Every REL row | PL12 L545–546; DTR L50–51 |
| **BAR** | Beta App Review approval of the external TestFlight build | Owner (12.05) | Not submitted | Stage B entry; B rows | CH L211; PL12 L568–569 |
| **EXPO-BUILD** | The App Store Expo build installed on the test device and kept installable for upgrade and rollback | Owner | Not recorded as prepared | RN-UP rows, P2 rows, P2-RB, P12-G1-1, PERF-10 | DTR L47–48; P2P L68–71; P11R L48 |
| **COHORT** | The external beta cohort covering the SB1 segments plus one two-device mixed-client user; consent per the legal disclosures | Owner (12.05) | Not recruited | B rows | CH L213–216; PL12 L575–580 |
| **DEV2** | A second physical iPhone for two-device rows | Owner | Open (P4R L24, 2026-09-13; no later record) | +DEV2 rows; SETUP-DEV-2 | P4R L24, L62 |
| **RN-STG** | The current React Native build pointed at staging, on the second iPhone | Owner | Open; needs STG and DEV2 | +RN2 rows (P4 and cross-client rows) | P4R L62–63; P4X L55–56 |
| **SANDBOX** | StoreKit sandbox testers for subscription rows | Owner | No record of provisioning | P3-S1 to P3-S3, P3-S5 to P3-S7, Q11-P12-4 | DTR L56 |
| **STRIPE-TEST** | Stripe test mode on synthetic connected accounts (two connected accounts for P10-17) | Owner | Not recorded | P7-11 to P7-13, P7-15, P8-14, P10-17 | CH L144 (TH-9: "Stage A uses Stripe test mode on synthetic accounts"); P10R L93 |
| **G6** | The RN-source-file retention policy, approved before any SA2 upgrade run | Owner | Provisional policy recorded (CH §5.4); approval open | RN-UP rows (P2, Q11-P12-6, PERF-5, P12-G1-1) | CH L181, L303–305; P11R L60 |
| **BE-DEPLOY** | Backend the native app calls that is not on this branch at `1c6859a`: the booking admin route, the estimate revise-declined route (both hit the Worker's 404 catch-alls for `/api/booking/:action` and `/api/estimate/:action` in `backend-workers/src/index.js`), and the Phase 8 SQL migrations (booking lifecycle RPCs, booking admin state, portal token admin; the latest migration on the branch is dated 2026-08-31). Commit, review, then deploy to staging and later production | Owner / backend | Not committed on this branch | P6-8, P6-9, P8-3, P8-8, P8-9, P8-11, P8-15 | code: `N/NativeBookingAdministration.swift`, `N/NativeEstimateApprovalLink.swift`; RM L860–862 |
| **HOSTED** | The hosted customer pages in the separate tradeready-legal deployment (estimate, change, book, booking, portal), reachable and calling the backend under test (for an STG row, the staging Worker) | Owner | Not in this repository; availability unconfirmed (P8C M2: unavailable) | P6-4, P6-8, P6-9, P6-12, P6-18, P8-8, P8-9, P8-11 to P8-14, P10-4, P12-G1-1 | P8S L27–30; P8C L42–43, L464 |
| **P8-CODE** | Phase 8 native code is on the branch, but the Phase 8 plan still records every task pending and no 8.15 closeout exists. Reconcile the Phase 8 status (plan ledger, roadmap, parity rows) before its rows run | Owner / Phase 12.00 | Open | P8-1 to P8-15, P10-4 | PL8 L5, L455–461; PM L39–41, L87–89, L124 |
| **AGG-1** | The aggregate test runner ends in a `backend-workers` `npm test` with no committed test script | Owner / backend | Open | Not a row here: SA3 and Stage A exit (CH L164) | CH L164 |

## 6. Rows per stage

Counted from the Stage column of every index row on 2026-09-25.

| Section | A | A/B | B | C | X | Total |
|---|---|---|---|---|---|---|
| §9 Setup | 0 | 0 | 0 | 0 | 10 | 10 |
| §10 Phase 2 and Phase 3 | 29 | 0 | 0 | 0 | 0 | 29 |
| §11 Phase 4 | 11 | 9 | 0 | 0 | 0 | 20 |
| §12 Phase 5 | 8 | 0 | 0 | 0 | 0 | 8 |
| §13 Phase 6 | 17 | 1 | 0 | 0 | 0 | 18 |
| §14 Phase 7 | 20 | 7 | 0 | 0 | 0 | 27 |
| §15 Phase 8 | 0 | 15 | 0 | 0 | 0 | 15 |
| §16 Phase 9 | 47 | 4 | 0 | 0 | 0 | 51 |
| §17 Phase 10 | 39 | 3 | 0 | 0 | 4 | 46 |
| §18 Phase 11 | 85 | 18 | 2 | 1 | 8 | 114 |
| §19 Phase 12 | 2 | 0 | 0 | 0 | 0 | 2 |
| **Total** | **258** | **57** | **2** | **1** | **22** | **340** |

318 rows are device rows (A, A/B, B, C). 104 of them need STG (74 A, 30 A/B) and stay
blocked while D4 is open; 214 do not need STG. The 22 X rows are 10 setup rows, the four
Phase 10 implementation gates, PERF-3 (a decision) and the seven Phase 11 owned items.

## 7. Coverage

Counted by script from the sources at `1c6859a`. An item is a checkbox line of a
runsheet, a data row of a P11R, P3M or P2P table, or a list item of the P3S staging
checklist or the P4B, P4J and P4X device lists. Each item is placed exactly once: on one
index row (several items may share one merged row), in §8 (passed or closed), in §20
(exit or rule) or in §21 (no device row). Four P4 contract items name two or three
scenarios and are split over P4 rows, each part once: P4J L66–67 (P4-P1, P4-P2, P4-P3),
P4J L70–72 (P4-P5, P4-P6), P4X L57–58 (P4-C1, P4-C3) and P4X L63 (P4-C5, P4-P3,
P4-P4).

| Source | Items | On index rows | Distinct index rows | Passed or closed (§8) | Exit or rule (§20) | No device row (§21) |
|---|---|---|---|---|---|---|
| DTR checkboxes | 63 | 55 | 37 | 5 | 3 | 0 |
| P2P matrix (L75–82) | 8 | 8 | 8 | 0 | 0 | 0 |
| P3M matrix rows (L151–190) | 25 | 20 | 20 | 5 | 0 | 0 |
| P3S staging checklist (L59–101) | 11 | 11 | 5 | 0 | 0 | 0 |
| P4R checkboxes | 34 | 29 | 25 | 0 | 5 | 0 |
| P4B device list (L57–68) | 6 | 6 | 5 | 0 | 0 | 0 |
| P4J device list (L66–78) | 6 | 6 | 8 | 0 | 0 | 0 |
| P4X device list (L55–67) | 7 | 7 | 10 | 0 | 0 | 0 |
| P7R checkboxes | 33 | 30 | 30 | 0 | 3 | 0 |
| P9R checkboxes | 55 | 52 | 52 | 0 | 3 | 0 |
| P10R checkboxes | 55 | 50 | 48 | 1 | 4 | 0 |
| P11R rows (L71–245), owned items (L58–65) and exit checkboxes (L249–257) | 122 | 114 | 114 | 2 | 6 | 0 |

DTR, P2P, P3M and P3S describe the same Phase 2 and 3 scenarios, and P4R restates the P4B,
P4J and P4X lists, so their items land on the same rows (§9 to §11 list the merges). The
other merges across phases are P7R L13, P9R L26 and P10R L76 into P5-8; P7R L14 into P5-6;
P7R L46 into Q11-P12-7; P10R L132, L135 and L136 into P4-B1, P4-B4 and P4-B3; P10R L143
and L144 into P10-36; P10R L137 and L138 into P10-GATE-3 and P10-GATE-4.

Sources without runsheet rows are placed statement by statement:

| Source | Deferred statements | Placed |
|---|---|---|
| RM Phase 5 (L283–376; exit L656–658) | The umbrella at L374–376 and three exit criteria | P5-1 to P5-8 cite the slice lines; L657 on P5-5, L658 on P5-7; L656 in §21 |
| RM Phase 6 (L662–949) | 26 statements (§13 mapping) | 18 P6 rows, plus AN-1, SIRI-4, Q11-P12-8, SOAK-3 and P4-P3; BE-DEPLOY as a prerequisite; 4 in §21 |
| Phase 8 (P8S, PL8, P8C, RM L996–998) | 16 statements (§15 mapping), plus C16 and C17 | P8-1 to P8-15; HOSTED as a prerequisite; RM L996, C16 and C17 in §21 |
| PM (L28–149) | 82 parity rows | Each mapped in §22; the parity-only gaps of PM L50, L52 and L53 in §21 |
| P10R implementation gates (L31–67) | 5 | P10-GATE-1 to P10-GATE-4; gate 5 closed (§8) |
| PL12 §7 items routed to 12.03 (L898, L904, L916) and the fixed row L901 | 4 | Linked onto A11-TT-1, IPAD-MT-3, A11B-FR1-1 and A11B-FR1-2, IPAD-KB-1; no new row |
| CH L283 (G1 waiver condition) | 1 | P12-G1-1 |
| Commit `1e47f26` (rating prompt) | 1 | P12-RATE-1 |

## 8. Passed and closed items (not rows)

These source rows already have evidence or were closed, so they are not deferred. They are
listed so the coverage count adds up.

| Source item | Source | State | Note |
|---|---|---|---|
| A1 — new email account, confirmation required | DTR L152–154; P3M L151, L100–102 | Pass 2026-09-09 | See note below |
| A7 — Sign in with Apple | DTR L168–170; P3M L157, L115–119 | Pass 2026-09-09 | See note below |
| O1 — returning account, online initial pull | DTR L177–179; P3M L164, L130–134 | Pass 2026-09-09 | See note below |
| S4 — restore for the same account | DTR L201–202; P3M L177, L139–141 | Pass 2026-09-09 | Its TestFlight repeat is open in P3-S7 |
| D1 — online sign-out | DTR L214–216; P3M L186, L111–114 | Pass 2026-09-09 | See note below |
| 10.09 (c) — post-sync publish on mismatch | P10R L139; P10R L60–67 (gate 5) | Closed 2026-09-23 (final-review I6) | Host forcing test; an implementation gate, not a device row |
| OI-4 — Phase 11 known code issues | P11R L65; P11R L254 | Closed for Phase 11 | Items 1, 3, 4, 5 fixed; item 2 re-owned as I2 (§18, gates) |

Note: the five passes ran on a one-off production-override signed build installed
directly, not on TestFlight, with disposable accounts; the owner approved that exception
for that run only (P3M L7–9, L35–38, L91–96). The sources do not ask for a re-run. A
Stage A owner who repeats them on REL records it in the Stage A run record (§24).

## 9. Setup rows

Owner work that the device rows depend on. None of it is an agent action: no deploy,
Supabase write, secret entry or App Store Connect step is done by an agent.
Each setup row merges the DTR precondition and staging checkboxes, the P3S checklist
steps and the P4R preconditions that its Source cell names.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| SETUP-STG-1 | Isolated Supabase project, buckets and verified migrations | 1. Owner chooses a separate Supabase project or branch and accepts any cost. 2. Apply the repository migrations (and BE-DEPLOY's once committed). 3. Run the account-deletion cascade audit (DTR L254 and P3S L60 name `supabase/verify/account_deletion_cascade.sql`, which is not in the repository at `1c6859a`; locate or restore it first). 4. Run `supabase/migrations/verify/20260831_updated_at_server_authority_verify.sql` and `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql` and keep privacy-safe outputs outside the repository. 5. Create the R2 buckets `tradeready-invoice-pdfs-staging` and `tradeready-photos-staging` | The audit prints "Account-deletion cascade audit passed."; both verification scripts succeed; nothing touches production | Owner; staging Supabase and R2 | X | — (creates STG) | DTR L252, L253, L254–255, L263–264; P3S L56–61, L65–71; P4R L41–42, L43–46 | [ ] |
| SETUP-STG-2 | Residual access-token control | Choose either a short access-token lifetime with a documented maximum residual window, or a session-aware RLS policy that requires the JWT `session_id` to exist for the same user. Prove the choice in staging with active, expired, signed-out and deleted sessions | A dated decision; the control holds for all four session states | Owner; staging | X | STG | DTR L256–260; P3S L39–52, L62 | [ ] |
| SETUP-STG-3 | Staging Worker configuration | 1. Replace only `[env.staging.vars].SUPABASE_URL` in `backend-workers/wrangler.toml` with the isolated project URL. 2. Set only the staging `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` by interactive secret input. 3. Run `npm test` and `npm run check:staging` locally in `backend-workers/` (AGG-1: committed code has no `test` script) and review the configuration classification | The classification names `tradeready-backend-staging`, has no cron triggers and references only staging resources; no secret is committed | Owner | X | STG | DTR L261–262, L265–266, L267; P3S L63–64, L73–89 | [ ] |
| SETUP-STG-4 | Staging Worker deployed | After explicit owner authorization run `npm run deploy:staging`; then send one unauthenticated `POST /api/delete-account` | The deploy targets only `tradeready-backend-staging`; the smoke returns a bounded `401`; no real bearer token is sent before P3-D4 | Owner | X | STG; BE-DEPLOY for the rows that need it | DTR L268–270, L271; P3S L90–98; P4R L47 | [ ] |
| SETUP-STG-5 | Staging-configured signed Release build | Build a signed Release app whose backend URL is the verified staging Worker and whose active Supabase URL and publishable key come from that staging project's Connect dialog. Keep `TRADEREADY_PRODUCTION_SUPABASE_URL` and `TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY` matched to production (they are the runtime guard). Rerun `native/run-phase-3-device-preflight.sh` | Preflight exit `0`; signed-device sign-in and Data API calls reach staging only; a configuration that matches the production Worker project fails the preflight | Owner; REL on STG | X | STG, SIGN-1 | DTR L272–273; P3S L99–101; P4R L48–52, L53–57, L58–61 | [ ] |
| SETUP-DEV-1 | Devices and builds for the Phase 2/3 rows | Confirm a signed physical iPhone (baseline PM27), an installable copy of the App Store Expo build kept for upgrade and rollback, the signed Release native build, and its TestFlight distribution | All four are available; record models, OS versions and build numbers | PM27, REL | X | SIGN-1, TF-INT, EXPO-BUILD | DTR L45–46, L47–48, L49, L50–51 | [ ] |
| SETUP-ACCT-1 | Accounts and services | Use disposable or staging team accounts only; provision StoreKit sandbox testers; confirm the custom redirect `tradeready://reset-password` is allow-listed on the environment under test | Accounts recorded by alias only; testers exist; the redirect is allow-listed (the owner reported it allow-listed, RM L131; confirm again for staging) | Owner | X | SANDBOX | DTR L55, L56, L57 | [ ] |
| SETUP-PRE-3 | Phase 3 preflight | From the repository root run `native/run-phase-3-device-preflight.sh` | Exit `0`: ready. Exit `1`: a configuration contract failed; fix it first. Exit `2`: a physical device or trusted staging is still missing. It prints classifications only | Mac and the connected iPhone | X | SIGN-1, STG | DTR L61–70; P3M L11–28 | [ ] |
| SETUP-DEV-2 | Two devices for the mixed-client rows | Prepare two physical iPhones, one with the current React Native build and one with the Swift build, signed in to the same disposable staging account | Both clients run against the same staging project | REL, +RN2 | X | DEV2, RN-STG, STG | P4R L62–63; P4X L55–56 | [ ] |
| SETUP-PRE-4 | Phase 4 preflight | Enable Background App Refresh for the Swift app. Run `native/run-phase-4-device-preflight.sh` with `--updated-at-verification` and `--payment-merge-verification` set to the saved SQL outputs from SETUP-STG-1 | Exit `0` means the Phase 4 rows may begin (`1`: configuration failure; `2`: a prerequisite is missing) | Mac and both iPhones | X | STG, DEV2 | P4R L64, L65–75; P4B L51–55; P4J L60–64; P4X L49–53 | [ ] |

## 10. Phase 2 and Phase 3

The Phase 2 rows merge each DTR P-row checkbox with the matching P2P matrix row, and the
Phase 3 rows merge each DTR A/O/S/D checkbox with the matching P3M matrix row. IDs keep
the source IDs with a `P2-` or `P3-` prefix.

### Phase 2 — upgrade matrix (SA2)

Per-row procedure (DTR L104–115; P2P L68–71, L84–87): install the App Store Expo build;
create the fixture on the device (offline where the row says); install REL as an in-place
upgrade without deleting the app; launch it twice; export the Settings support report;
compare record counts and representative records with the fixture; inspect migrated
media; confirm the Expo-format backup is still recoverable; exercise the widget timer and
Siri mileage actions across foreground and background. P2P L68 asks for a development or
staging account; charter §4.2 requires team accounts and synthetic data (SA1). 12.04
step 2 adds its own SA2 checks (pending Expo notifications reconciled; the 12.01 step 3b
continuity checks) to the same run and records them in the Stage A run record.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P2-P1 | Clean install | Install REL on a device that never had TradeReady; launch twice; export the support report | No legacy source is invented; onboarding receives an empty native store | REL, PM27 | A | — | DTR L119–120; P2P L75 | [ ] |
| P2-P2 | Sample account | Per-row procedure with a sample account fixture | Counts, money, dates, settings, photos, session and owner binding all match | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L121–122; P2P L76 | [ ] |
| P2-P3 | Large account | Per-row procedure with a large fixture | External manifest values, more than ten session chunks, 512 queued actions and all photo directories migrate without truncation | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L123–125; P2P L77 | [ ] |
| P2-P4 | Offline account | Per-row procedure with the fixture created offline; first native launches offline | Local records and credentials survive; identity-gated state stays quarantined until live verification succeeds | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L126–127; P2P L78 | [ ] |
| P2-P5 | Partially synced account | Per-row procedure with queued, unsynced Expo changes | Local queue and cursors stay inert and recoverable; no server or local record is overwritten | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L128–129; P2P L79 | [ ] |
| P2-P6 | Interrupted migration | Per-row procedure; force-quit after each checkpoint: backup, snapshot publication, secure publication, widget claim, replay commit | Every relaunch converges with no duplicates | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L130–132; P2P L80 | [ ] |
| P2-P7 | Account mismatch | Per-row procedure; sign in to native as a different verified team account | The other user receives none of the prior account's state, action replay or customer data | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L133–134; P2P L81 | [ ] |
| P2-P8 | Corruption recovery | Per-row procedure; corrupt the primary store only, then primary plus backup | Recovery or read-only blocking matches the support report | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | DTR L135–136; P2P L82 | [ ] |
| P2-RB | Rollback rehearsal (Phase 2) | Reinstall the retained Expo build after the native upgrade; record how it was installed (12.06 owns version numbering and the TestFlight rehearsal, CH L207–210) | The retained Expo build reinstalls successfully | EXPO-BUILD, PM27 | A | EXPO-BUILD, VER-1 | DTR L141; P2P L91–93 | [ ] |

### Phase 3 — authentication, onboarding, subscription, sign-out and deletion

P3M L5–9 requires every Phase 3 row to run on a signed physical iPhone against an
isolated test environment; the 2026-09-09 production exception applied to that run only.
So every Phase 3 row is STG. Running one on the production-configured stage build with
disposable team accounts needs a new dated owner exception in the decision log.
Acceptance wording is P3M's (DTR L7–9).

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P3-A2 | Returning email account | Sign in with a valid password for a returning team account; relaunch. Separately submit invalid credentials | A valid password reaches initial sync and the correct owner namespace; invalid credentials expose no server detail (only the synthetic `.invalid` path is proven, P3M L103–106) | REL, PM27, STG | A | STG | DTR L155–157; P3M L152, L103–106 | [ ] |
| P3-A3 | Expired access token, valid refresh | Foreground the app after the access token has expired while the refresh token is valid | The session rotates and lands on the same account without showing an intermediate main screen | REL, PM27, STG | A | STG | DTR L158–160; P3M L153 | [ ] |
| P3-A4 | Expired or rejected refresh token | Foreground or relaunch with an expired or rejected refresh token | The app returns to sign-in and keeps recoverable owner-bound local data | REL, PM27, STG | A | STG | DTR L161–162; P3M L154 | [ ] |
| P3-A5 | Password reset, cold and warm callback | Request a reset; open the mail link with the app killed, then with it running; set a new password | Mail/browser handoff returns only through `tradeready://reset-password`; the new password is accepted after the recovery-only screen completes | REL, PM27, STG | A | STG; redirect (SETUP-ACCT-1) | DTR L163–165; P3M L155 | [ ] |
| P3-A6 | Reused, expired, malformed and cancelled reset | Open a reused, an expired and a malformed reset link; cancel a reset | Every invalid path fails closed; cancelling returns to sign-in without deleting business data | REL, PM27, STG | A | STG | DTR L166–167; P3M L156 | [ ] |
| P3-A8 | Sign in with Google (matching owner) | Sign in with Google as the matching owner; relaunch; sign out; cancel once at the account picker | Account picker, callback, nonce-bound exchange, independent subject check, relaunch and SDK credential clearing succeed; cancelling is silent (cancel and non-owner rejection passed 2026-09-09, P3M L120–129) | REL, PM27, STG | A | STG | DTR L171–173; P3M L158, L120–129 | [ ] |
| P3-O2 | Initial pull interrupted or offline | Interrupt a first-ever initial pull (airplane mode mid-pull); relaunch. Separately open a previously live-verified, bound account offline | A first-ever or incomplete bootstrap keeps the retryable cloud gate and never applies a partial candidate; the verified, bound account opens its local snapshot offline | REL, PM27, STG | A | STG | DTR L180–183; P3M L165 | [ ] |
| P3-O3 | Onboarding interrupted on each step | Force-quit on each onboarding step and relaunch; then sign in as another account | The same verified account's draft and current step are restored; another account cannot adopt them | REL, PM27, STG | A | STG | DTR L184–185; P3M L166 | [ ] |
| P3-O4 | Sample start interrupted | Force-quit while the sample starting point is being created; relaunch | The same sample transaction and IDs replay without duplicating or replacing real records | REL, PM27, STG | A | STG | DTR L186–187; P3M L167 | [ ] |
| P3-O5 | Fresh start after an interrupted sample | After P3-O4's interruption choose a fresh start | Only native sample IDs are removed; real and unknown canonical records remain | REL, PM27, STG | A | STG | DTR L188–189; P3M L168 | [ ] |
| P3-S1 | New unsubscribed account | Sign in with a new account and reach the paywall | Localized monthly and annual offerings load, annual is preferred when present, and main data stays behind the paywall | REL, PM27, STG | A | STG, SANDBOX | DTR L193–194; P3M L174 | [ ] |
| P3-S2 | Purchase cancelled | Start a purchase and cancel it | Cancellation is silent and the entitlement gate stays closed | REL, PM27, STG | A | STG, SANDBOX | DTR L195–196; P3M L175 | [ ] |
| P3-S3 | Sandbox purchase or trial | Complete a sandbox purchase or start a trial | Only the exact active `TradeReady Pro` entitlement advances to starting-point selection; Settings shows trial or active (the active Settings status was seen 2026-09-09, not a purchase, P3M L135–138) | REL, PM27, STG | A | STG, SANDBOX | DTR L197–200; P3M L176, L135–138 | [ ] |
| P3-S5 | Restore into a different account | While signed in to account B, restore purchases made under account A | RevenueCat uses the newly verified Supabase subject; account A's local business data is never exposed to account B | REL, PM27, STG | A | STG, SANDBOX | DTR L203–205; P3M L178 | [ ] |
| P3-S6 | Expiry or lapse, then foreground refresh | Let a sandbox subscription lapse; foreground the app | The latest inactive entitlement returns the account to the paywall without crossing identity generations | REL, PM27, STG | A | STG, SANDBOX | DTR L206–207; P3M L179 | [ ] |
| P3-S7 | TestFlight purchase-critical repeat | In the distributed TestFlight build repeat S1, S2, S3, S4 (restore), S5 and S6, and the App Store subscription-management handoff. If S1–S6 above already ran on the TestFlight build, link them here | Each behaves as in the directly installed build; the handoff returns to TradeReady without changing status (direct-install handoff passed, P3M L142–145) | REL (TestFlight), PM27, STG | A | STG, SANDBOX | DTR L208–210, L237, L238, L239, L240, L241, L242, L243; P3M L180, L142–145 | [ ] |
| P3-D2 | Offline sign-out | Sign out while offline; then accept the device-only confirmation | The remote failure keeps data intact until the separate device-only confirmation; accepting it finishes the local scrub | REL, PM27, STG | A | STG | DTR L217–218; P3M L187 | [ ] |
| P3-D3 | Account A to account B switch | Sign out of A and sign in as B on the same device | B cannot view A's snapshot, backup, onboarding draft, pending links, widget or Siri actions, media or auxiliary activation state (only the confirmation gate is proven, P3M L107–110) | REL, PM27, STG | A | STG | DTR L219–221; P3M L188, L107–110 | [ ] |
| P3-D4 | Approved disposable-account deletion | On a disposable staging account: force one deletion failure first, then delete with the exact `DELETE` confirmation. Can share a run with EXT-3, AN-3 and AI-3 | Failure preserves local data; success removes the remote account and every documented local recovery artifact | REL, PM27, STG | A | STG | DTR L222–225; P3M L189; P3S L103–110 | [ ] |
| P3-D5 | Relaunch after deletion | Interrupt the post-deletion cleanup; relaunch | Cleanup resumes, the deleted session cannot restore, and the app lands at sign-in with no deleted-account data visible | REL, PM27, STG | A | STG | DTR L226–228; P3M L190; P3S L103–110 | [ ] |

## 11. Phase 4 — background refresh, job-photo transfer, mixed-client convergence

All Phase 4 rows are STG: P4B L51–52, P4J L60–61 and P4X L49–50 require trusted staging
and physical iPhones, and P4R L37 forbids substituting production. Run SETUP-PRE-4 first.
Evidence rules: P4R L77–87 (a retry row passes only if the interrupted attempt kept the
snapshot, source bytes, queue and cursor; an account-boundary row passes only if the next
account cannot view, install, apply, replay or acknowledge the previous owner's work).

Merges: the P4R rows absorb the matching P4B, P4J and P4X bullets; P10R L132, L135 and
L136 (Phase 10 background rows) merge into P4-B1, P4-B4 and P4-B3 because they are the
same background-task scenarios (P10R L135 names P4B as the owner of the task lifecycle).

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P4-B1 (= P10-41) | Delivered background refresh | Queue a Swift edit; create a remote edit from the other client; let `BGAppRefreshTask` fire (or deliver it) and record when it fired | Push then pull converge without duplicates; the task fires within the OS scheduling window (30-minute earliest reschedule). A deferral beyond 30 minutes is expected and not a failure by itself (P4B L67–68) | REL, +RN2, STG | A | STG, RN-STG | P4R L102–104; P4B L57–58, L67–68; P10R L132 | [ ] |
| P4-B2 | Offline delivery | Deliver a background task in airplane mode; restore connectivity | The queue and snapshot stay intact; a later foreground or background pass converges | REL, STG | A | STG | P4R L105–107; P4B L59–60 | [ ] |
| P4-B3 (= P10-45) | Signed-out cold launch, and no-op passes | Deliver a task while signed out (cold launch); repeat with the device offline | The task completes without rendering or mutating the previous workspace; the signed-out and offline passes are no-ops for the sync work and for the Phase 10 reconcile/refresh hook | REL, STG | A | STG | P4R L108–109; P4B L61–62; P10R L136 | [ ] |
| P4-B4 (= P10-44) | Expiration | Expire a task during a delayed request | Completion is unsuccessful exactly once; unacknowledged queue and cursor work remains; no duplicate notification reconcile and no double snapshot publish | REL, STG | A | STG | P4R L110–111; P4B L63–64; P10R L135 | [ ] |
| P4-B5 | Account boundary during a pass | Sign out, or switch accounts, while a background pass is suspended | No prior-owner mutation, pull, photo or widget action commits under the new account | REL, STG | A | STG | P4R L112–113; P4B L65–66 | [ ] |
| P4-P1 | Swift photo upload | Add a local JPEG to a job and let it upload | It uploads byte-exactly and only then gains `uploadedAt` | REL, STG | A | STG | P4R L117–118; P4J L66–67 | [ ] |
| P4-P2 | Swift-to-Swift backfill | Sign in to the same account on a second Swift device | The bytes install at the deterministic path without overwriting an existing local file | REL, +DEV2, STG | A | STG, DEV2 | P4R L119–120; P4J L66–67 | [ ] |
| P4-P3 | Swift-to-React Native photo | Upload a synthetic photo from Swift; open the job on the React Native client | React Native receives the Swift metadata and object and renders the same photo | REL, +RN2, STG | A/B | STG, RN-STG | P4R L121–122; P4J L66–67; P4X L63; RM L933–935 (Phase 6 job photos: device convergence proof) | [ ] |
| P4-P4 | React Native-to-Swift photo | Add a photo on React Native; sync the Swift device | React Native-origin metadata and object backfill to Swift without replacing an existing file | REL, +RN2, STG | A/B | STG, RN-STG | P4R L123–124; P4J L68–69; P4X L63 | [ ] |
| P4-P5 | Upload interruption | Terminate the app during the PUT, and between the PUT and the local metadata commit; relaunch | The original file and snapshot stay intact; relaunch repeats safely and converges without duplicates | REL, STG | A | STG | P4R L125–126; P4J L70–72 | [ ] |
| P4-P6 | Download interruption | Terminate the app during the GET, and before the atomic move; relaunch | The destination is absent or valid, never partial; a later pass converges | REL, +DEV2, STG | A | STG, DEV2 | P4R L127–128; P4J L70–72 | [ ] |
| P4-P7 | Offline and retryable failures | Airplane mode during upload and backfill; then responses 401/403, 404, 429, 5xx, oversized, JSON error body and malformed JPEG | Local bytes and metadata are preserved; the destination stays absent; each case retries safely; restoring connectivity completes the same pending work | REL, STG | A | STG | P4R L129–131; P4J L73–74, L77–78 | [ ] |
| P4-P8 | Photo account boundary | Switch accounts during an upload and during a download | No bytes or metadata cross owners; nothing commits into or shows in the next account's workspace | REL, STG | A | STG | P4R L132–133; P4J L75–76 | [ ] |
| P4-C1 | Independent creates | Each client creates a different job (and edits it); foreground sync both | Both clients converge to exactly one copy of each | REL, +RN2, STG | A/B | STG, RN-STG | P4R L137–138; P4X L57–58 | [ ] |
| P4-C2 | Ordered concurrent edit | Both clients edit the same job offline; reconnect in a recorded order | The database's last writer wins on both clients | REL, +RN2, STG | A/B | STG, RN-STG | P4R L139–140; P4X L59–60 | [ ] |
| P4-C3 | Deletes | Each client deletes a record the other created | Both apply the owner-scoped tombstone; no duplicates | REL, +RN2, STG | A/B | STG, RN-STG | P4R L141–142; P4X L57–58 | [ ] |
| P4-C4 | Payments | Each client adds a distinct payment to one invoice; void one | Both entries and any void state survive on both clients (the database payment-merge trigger and each pull path keep both) | REL, +RN2, STG | A/B | STG, RN-STG | P4R L143–144; P4X L61–62 | [ ] |
| P4-C5 | Booking history | Make a server or customer booking-history write concurrent with a device conversion | History and conversion fields survive and converge without duplicate history, in both directions | REL, +RN2, STG | A/B | STG, RN-STG | P4R L145–146; P4X L63 | [ ] |
| P4-C6 | Relaunch replay | Interrupt each client after the server accepted a write but before its local queue commit (and during a pull); relaunch | No duplicate rows; the durable queue and cursor recover without lost or cross-account data | REL, +RN2, STG | A/B | STG, RN-STG | P4R L147–148; P4X L64–65 | [ ] |
| P4-C7 | Mixed-client account boundary | Switch the Swift device to another account while React Native writes and work is suspended | None of the old account's state appears; neither client applies or exposes the previous owner's state | REL, +RN2, STG | A/B | STG, RN-STG | P4R L149–150; P4X L66–67 | [ ] |

## 12. Phase 5 — customers, search and shared interaction states

Phase 5 has no runsheet. RM L374–376 records that it "remains open only for physical-device
interaction evidence and trusted-staging sync proof". Each row below cites the roadmap
slice that describes the behavior and the parity clause that names the remaining proof.

Merges: the pull-to-refresh rows of P7R L13, P9R L26 and P10R L76 are the same scenario
as the Phase 5 shared refresh contract and merge into P5-8; P7R L14 (delete with 8-second
undo) merges into P5-6.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P5-1 | Customer list | On Customers: archive and restore a stored customer; open an invoice-derived customer and promote it; review a possible-duplicate suggestion and dismiss it; open a customer from global search | Invoice-derived customers show without records being created silently; promotion is explicit; archive/restore is reversible; dismissal mutates no business record; search opens the exact customer | REL, IPH | A | — | RM L283–298; PM L83 | [ ] |
| P5-2 | Customer detail history, routing and notes | Open a customer with jobs and invoices; tap an invoice row, including one deleted elsewhere; edit the inline note; create an invoice draft from the detail | Jobs order by latest scheduled date and invoices by latest due date; invoice rows route by exact ID and a missing one fails closed; the note saves only after a durable commit and keeps every other field; the draft carries the exact customer ID | REL, IPH | A | — | RM L338–349; PM L84 | [ ] |
| P5-3 | Contact actions | From customer and job detail: call, text and email; repeat where Mail or Messages is unavailable | Recipients are normalized; reviewed in-app Mail/Messages drafts are preferred; recipient-only system URLs are the fallback; copy is offered when nothing can handle the action; nothing sends automatically | REL, IPH | A | — | RM L333–337; PM L84 | [ ] |
| P5-4 | Add/edit customer and address lookup | Create a customer using MapKit address completions; save an address offline; try to create a second customer with the same trimmed, case-insensitive name; force a save failure | At most five unique completions and stale results ignored; free-form addresses save offline; the duplicate name blocks creation with the draft kept; a failed save keeps the editor open and reports that data was preserved | REL, IPH | A | — | RM L306–312, L346–349, L370–373; PM L85 | [ ] |
| P5-5 | Merge and archive: reversible and synced | Merge two customers that own jobs, invoices and recurring records; undo; merge again and let it sync; archive and restore a customer; check a second device | Merge is one loss-preserving commit; Undo restores only the affected records and fails closed after a later edit; archive/restore is reversible; both sync to the second device correctly | REL, +DEV2, STG | A | STG, DEV2 | RM L298–305, L657; PM L86 | [ ] |
| P5-6 (= P7-6) | Typed delete confirmation and 8-second undo | Delete a job, an invoice (with payments) and a customer through the typed confirmation; undo each within 8 s; delete again and undo while the tombstone is in flight to the server | The confirmation warns about payment history (invoice) and kept history (customer); undo restores the exact record, list position and payments while its ID is absent; newer mutations are kept; a recreated ID fails closed; the queued tombstone is replaced by the upsert | REL, IPH, STG | A | STG | RM L350–356, L357–365; P7R L14; PM L84 | [ ] |
| P5-7 | Global search | From Today open search; search jobs, customers and invoices; use the new-job, new-customer and new-invoice actions; select results, including an archived and a deleted record; use a hardware keyboard and VoiceOver; pull to refresh | Field sets, ordering, archived exclusion, eight-result caps and true totals match RN; selection changes to the owning tab and opens the exact detail once; missing or archived records fail closed; focus, keyboard and VoiceOver work | REL, IPH | A | — | RM L313–321, L658; PM L42 | [ ] |
| P5-8 (= P7-5, P9-6, P10-6) | Shared interaction states and pull-to-refresh against staging | On Jobs, Invoices, Customers, search, Money and Today: pull to refresh online; repeat offline; repeat with a failing refresh | Refresh awaits a real manual sync pass; offline and failed passes keep cached content and figures visible and show the bounded sync banner; no success is fabricated; true-empty and no-match states show their reset actions | REL, IPH, STG | A | STG | RM L322–332; P7R L13; P9R L26; P10R L76; PM L50, L69 | [ ] |

## 13. Phase 6 — jobs, estimates and field operations

Phase 6 has no runsheet. RM L916–918 defers "physical-device and end-to-end workflow
proof for every Phase 6 slice above" to Phase 12; the slices and their explicit
"remains open" sentences are listed per row. The source mapping below the table accounts
for every deferred statement.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P6-1 | Jobs list | On Jobs: switch every group (Active, Quotes, Complete, Paid, Declined, All, Archived); search; archive and restore a job; create and edit a job | Counts, rare-chip fallback, archive boundaries, newest-first order and the three stats match RN; create/edit reports success only after a durable commit; archive/restore replaces the pending upsert | REL, IPH | A | — | RM L666–682; PM L50 | [ ] |
| P6-2 | Duplication and one-step status transitions | Duplicate a job, cancel once, then save; on job detail use each one-step transition (estimate sent → approved, scheduled → in progress, in progress → complete); tap a transition after the status changed elsewhere | The duplicate carries only the RN whitelist and the source is unchanged; Cancel writes nothing; each transition advances exactly one step and a stale tap is refused; approved jobs route through the schedule editor | REL, IPH | A | — | RM L683–695; PM L51, L52 | [ ] |
| P6-3 | Pricing calculator | Price a lead with labor, the four labor buckets, materials and markup, direct costs, overhead, margin, minimum fee, travel, emergency and tax; save; edit the job elsewhere during the edit | The figures match the golden engine; advisory warnings never block saving; save changes only calculator-owned fields and the estimate total and dismisses after a durable commit | REL, IPH | A | — | RM L696–712; PM L53 | [ ] |
| P6-4 | Estimate review, mark as sent and approval link | Open the estimate review for a priced lead; edit the email or text; mark as sent; create the approval link and open it in a browser | The review is frozen from the canonical job; mark-as-sent commits the exact transition and follow-up date; the link is minted by the server after a completed pull; nothing is sent automatically; the hosted page shows the frozen snapshot | REL, IPH, STG, BROWSER | A | STG, HOSTED | RM L713–729; PM L54 | [ ] |
| P6-5 | Estimate PDF share and visual comparison | Export the reviewed estimate as a PDF; share it; compare it with the golden PDFs; repeat with a missing logo | The PDF matches the golden documents; the temporary directory is removed after dismissal; a missing logo omits only the logo; nothing is marked sent | REL, IPH | A | — | RM L729–737, L787–790; PM L54 | [ ] |
| P6-6 | Estimate Mail/Messages outcomes | Send the estimate through Mail and Messages; also cancel, save a Mail draft, and force a failure | Only a real `.sent` records delivery; cancel keeps the edited review; a saved draft stays unrecorded with a notice; failure keeps the draft for retry; a changed snapshot is not labelled sent | REL, IPH | A | — | RM L737–743, L791–794; PM L54 | [ ] |
| P6-7 | Copy, regenerate and channel switch | In the review: copy the email (with subject) and the text; switch channels with edits in both; regenerate one channel; use the keyboard throughout | Copy uses the exact visible text; edits are kept per channel; regeneration touches only the visible channel, keeps the approval link and asks before replacing edits; no canonical write | REL, IPH | A | — | RM L744–749, L795–798; PM L54 | [ ] |
| P6-8 | Declined revision: history and old-link invalidation | Have the customer decline on the hosted page; request a revision natively; open the old link; revise and resend | The job returns to Lead with the decline appended to history (snapshots, totals, signer, reasons visible; no tokens); the old link stops resolving; an unchanged snapshot cannot be resent; pricing opens | REL, IPH, STG, BROWSER | A | STG, BE-DEPLOY, HOSTED | RM L750–764, L860–862; PM L54 | [ ] |
| P6-9 | Declined revision racing a customer decision | Request a revision while the customer submits a decision on the old link at the same moment | The conditional write yields a conflict, not an overwrite; a retry after a completed write is idempotent; native keeps the local job if it changed during the await | REL, IPH, STG, BROWSER | A | STG, BE-DEPLOY, HOSTED | RM L750–764, L860–862; PM L54 | [ ] |
| P6-10 | Estimate follow-up: notification, Today row, tap and composer | Mark an estimate sent; wait for the 9:00 a.m. reminder three days later (or set the device date); tap it; check the Today row; deny permission; toggle the setting off; sign out | The `est_` reminder fires once; the tap opens an editable Mail/Messages review after the owner and job recheck; the Today row stays after the reminder expires; denial, toggle-off and sign-out remove pending `est_` requests only; nothing sends automatically | REL, IPH | A | — | RM L764–780, L799–806; PM L55 | [ ] |
| P6-11 | Change orders on device | On an approved, scheduled, in-progress and complete job: add, edit and delete a pending change order; record an on-site approval and decline with a note; cancel one; open an editor while a decision arrives | Status, badges and billable totals match RN; the note never pre-fills the next order; cancellation is one-way; a save after a decision or cancellation fails closed | REL, IPH | A | — | RM L807–855; PM L56 | [ ] |
| P6-12 | Change-order approval link and live customer decision | Send a change order for approval; the customer signs (and separately declines) on the hosted change page; sync native | Delivery uses the typed composers; the decision and signature sync back to native and are not overwritten by a re-send | REL, IPH, STG, BROWSER | A | STG, HOSTED | RM L844–846, L904–906, L927–929; PM L56 | [ ] |
| P6-13 | Invoice from job and automatic completion routing | Use create, request-deposit and finalize from job detail; complete an in-progress job with automatic invoicing on, then off; tap twice quickly | Lines rebuild from the current job; tracked time replaces quoted labor only for done hourly work; one atomic save; stale or duplicate taps and deposit paths create no second final invoice; the app routes to the created invoice after the durable commit | REL, IPH | A | — | RM L863–912; PM L57 | [ ] |
| P6-14 | Job profitability card | Open job detail for jobs with and without actuals and warnings | The card matches the RN warning and display contracts and preserves unknown actuals | REL, IPH | A | — | PM L60 | [ ] |
| P6-15 | Recurring jobs | Create, edit, pause and resume a recurring job rule; foreground to generate a due occurrence; open the occurrence; repeat the generation with the RN app on a second device | Cadence and end conditions, catch-up and date-overflow behavior match RN; one occurrence per due date, locally and across clients; the manager and occurrence markers navigate correctly | REL, IPH, +RN2, STG | A/B | STG, RN-STG | RM L936–938; PM L58 | [ ] |
| P6-16 | Appointment confirmations | Schedule a job for tomorrow; wait for the 5 p.m. day-before `appt_` notification; tap it; send the confirmation | The notification fires at 5 p.m. local the day before; the tap opens the exact confirmation review; the typed composer records only a real send | REL, IPH | A | — | RM L936–938; PM L62 | [ ] |
| P6-17 | Review requests | Complete (or mark paid) a job with review requests on; wait for the three-hour `review_` notification; tap it; use the paid/complete/invoiced CTAs | The request is owner-bound and scheduled at completion; the tap opens the review draft; composer outcomes are typed; nothing sends automatically | REL, IPH | A | — | RM L936–938; PM L63 | [ ] |
| P6-18 | End to end: lead to invoice without Expo | On one device only: create a lead, price it, send the estimate, approve it on the hosted page, schedule, start (on-my-way, clock in, photo), complete, invoice | Every step works natively with no Expo app; the job ends linked to a durable invoice (payment collection is Phase 7) | REL, IPH, STG, BROWSER | A | STG, HOSTED | RM L916–918, L946–947 | [ ] |

Phase 6 source mapping (every deferred statement in RM L662–949):

| Source | Deferred item | Index row |
|---|---|---|
| RM L682 | device and end-to-end workflow verification (jobs list slice) | P6-1 |
| RM L779–780 | analytics | AN-1 |
| RM L779–780 | physical-device notification/tap and composer proof | P6-10 |
| RM L779–780 | withdrawal of an undecided live approval link | Unplaced (§21): an implementation gap |
| RM L789–790 | device sharing and visual comparison against golden PDFs | P6-5 |
| RM L793–794 | Mail/Messages result handling | P6-6 |
| RM L797–798 | clipboard, keyboard and channel-switch proof | P6-7 |
| RM L805–806 | analytics | AN-1 |
| RM L805–806 | notification, Today-row, tap-routing and composer proof | P6-10 |
| RM L854–855 | add/edit/decision/cancel proof | P6-11 |
| RM L860–862 | backend deployment | Prerequisite BE-DEPLOY (on P6-8, P6-9) |
| RM L860–862 | live old-link invalidation | P6-8 |
| RM L860–862 | racing customer decision | P6-9 |
| RM L860–862 | device revision/history proof | P6-8 |
| RM L904–906 | change-order approval-link delivery and signature | P6-12 |
| RM L904–906 | time-tracking cross-device, widget and Siri replay | Q11-P12-8 |
| RM L904–906 | profitability aggregation | Unplaced (§21): an implementation gap |
| RM L911–912 | invoice-from-job modes and automatic completion routing | P6-13 |
| RM L916–918 | device and end-to-end proof for every slice | P6-18 (end to end) and one row per slice: P6-1 to P6-17 |
| RM L927–929 | change orders: analytics; device proof | AN-1; P6-11 |
| RM L930–932 | time tracking: aggregate reporting; cross-device/widget/Siri proof | Unplaced (§21); Q11-P12-8 |
| RM L933–935 | job photos: device convergence proof | P4-P3 |
| RM L936–938 | analytics; device proof for recurring jobs, appointment confirmations, on-my-way messaging, review requests | AN-1; P6-15, P6-16, SIRI-4, P6-17 |
| RM L946–947 | exit: lead to durable invoice without Expo | P6-18 |
| RM L948 | exit: estimate and change-order totals match golden documents | Unplaced (§21): a host criterion (P6-5 covers the device PDF) |
| RM L949 | exit: offline field actions sync safely | SOAK-3 |

## 14. Phase 7 — invoices, payments and communication

IDs P7-1 to P7-30 follow the checkbox order of P7R L9–56. Three are merged elsewhere:
P7-5 (P7R L13, pull-to-refresh) into P5-8; P7-6 (P7R L14, delete and undo) into P5-6;
P7-23 (P7R L46, recurring rule lifecycle) into Q11-P12-7 (= P7-23) in §18, which already
covers "Cancel plan" and "Delete plan" on the same screen.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P7-1 | Invoice list | Use every filter, search, the stat cards and the ordering; repeat in dark mode and at large Dynamic Type | Filters, search, stats and ordering match RN; legible in light, dark and large type | REL, IPH | A | — | P7R L9; PM L69 | [ ] |
| P7-2 | Create and edit invoice | Create and edit invoices; submit an invalid draft; force a save failure | The invalid draft keeps its input; a failed save keeps the draft | REL, IPH | A | — | P7R L10; PM L71 | [ ] |
| P7-3 | Concurrent edit and synced payment | Edit an invoice while a payment for it arrives by sync | The payment is retained | REL, +DEV2, STG | A | STG, DEV2 | P7R L11; PM L72 | [ ] |
| P7-4 | Missing-record state | Open an invoice; delete it on another device | The detail shows the explicit missing-record state | REL, +DEV2, STG | A | STG, DEV2 | P7R L12; PM L70 | [ ] |
| P7-7 | Payment ledger | Record a partial payment, settle, overpay and void | The ledger matches the RN fixtures | REL, IPH | A | — | P7R L18; PM L72 | [ ] |
| P7-8 | Linked job on settle and void | Settle an invoice linked to a job; then void a payment | The linked job advances on settle; a void does not regress it, per policy | REL, IPH | A | — | P7R L19 | [ ] |
| P7-9 | Two-device payment convergence | Two devices add payments to the same invoice at the same time; sync both | Payments merge: no duplicate, no lost update | REL, +DEV2, STG | A | STG, DEV2 | P7R L20; PM L72 | [ ] |
| P7-10 | Offline payment queue replay | Record payments offline; reconnect | The queue replays on reconnect, once | REL, IPH, STG | A | STG | P7R L21 | [ ] |
| P7-11 | Stripe Connect onboarding | Start Connect onboarding; finish it in the system browser; return to the app | The foreground refresh shows the connected state | REL (TestFlight), IPH | A/B | STRIPE-TEST | P7R L25; PM L75 | [ ] |
| P7-12 | Stripe disconnect and reconnect | Disconnect; try an existing payment link; reconnect | Links stop after disconnect; reconnecting resumes them | REL, IPH | A/B | STRIPE-TEST | P7R L26; PM L75 | [ ] |
| P7-13 | Payment-link mint and stale-link recheck | Mint a link for the full balance and one for a deposit; record a partial payment; reuse the earlier link | Both amounts mint; the stale link is rechecked after the partial payment | REL, IPH | A/B | STRIPE-TEST | P7R L27; PM L75 | [ ] |
| P7-14 | Non-Stripe providers | Produce Square, PayPal, Venmo and custom payment links | Each is shareable; a placeholder is never presented as usable | REL, IPH | A | — | P7R L28 | [ ] |
| P7-15 | Stripe webhook end to end | A customer pays a payment link; separately, open only the success page for another invoice | The webhook marks the invoice paid; opening the success page alone marks nothing | REL, IPH, STG, BROWSER | A/B | STG, STRIPE-TEST | P7R L29; PM L75; CH L144 (TH-9) | [ ] |
| P7-16 | Invoice PDF visual comparison | Share invoice PDFs for unpaid, partial, paid, overpaid, legacy, no-lines and long invoices; compare with the golden HTML PDFs (colors: Q11-P12-5) | Each matches its golden PDF | REL, IPH | A | — | P7R L33; PM L74 | [ ] |
| P7-17 | Long invoice and missing logo | Share a long invoice and one with no logo | It paginates; totals and history are readable; a missing logo omits only the logo | REL, IPH | A | — | P7R L34 | [ ] |
| P7-18 | Email with PDF attachment | Compose an email with the PDF attached; force the attachment to fail | The attachment is present; on failure the "PDF not attached" path shows without blocking send | REL, IPH | A | — | P7R L35; PM L70 | [ ] |
| P7-19 | Email and SMS composer outcomes | In each composer: send, cancel, save a draft and fail | Each outcome follows the outcome matrix | REL, IPH | A | — | P7R L39; PM L73 | [ ] |
| P7-20 | Copy and regenerate | Copy and regenerate offline; then with a client key and via the proxy | Deterministic and offline-capable; the AI route runs only with a key or proxy, otherwise the fallback | REL, IPH | A | KEYS | P7R L40 | [ ] |
| P7-21 | Bulk settle and reviewed reminders | Select several invoices; bulk settle with confirmation; send sequential reviewed reminders, skip one, cancel between messages | Confirmation is required; the skip summary shows; cancel stops the chain | REL, IPH | A | — | P7R L41; PM L69 | [ ] |
| P7-22 | No double-send | On staging, race a manual compose against the automatic sweep for one invoice | Exactly one customer email | REL, IPH, STG | A | STG | P7R L42 | [ ] |
| P7-24 | Recurring invoice generation on foreground | Foreground after a sync with due occurrences | Catch-up, numbering and due dates match the fixtures | REL, IPH | A/B | — | P7R L47; PM L76 | [ ] |
| P7-25 | Simultaneous two-device generation (BLOCKING per spec) | Two devices generate the same occurrence at the same time on staging | No double bill; document the outcome (simultaneous-offline generation is a pinned RN-parity divergence, PM L76) | REL, +DEV2, STG | A/B | STG, DEV2 | P7R L48; PM L76 | [ ] |
| P7-26 | Auto-send selection | Let a backlog of occurrences generate with auto-send on | Only the newest occurrence is sent, gated by the rule, the master switch and a plausible email; the backlog is never emailed | REL, IPH, STG | A/B | STG | P7R L49 | [ ] |
| P7-27 | Auto-email sweep end to end | On staging, let an invoice go through stamp, link/PDF preparation, claim, send and log; include one older than 7 days and one imported | Each step happens once; the stale and the imported invoice are excluded | REL, IPH, STG | A | STG | P7R L53; PM L77 | [ ] |
| P7-28 | Reminder sweep | Let overdue rules fire; include imported and pre-completion deposit invoices | Overdue reminders go out; imported and pre-completion deposit invoices are never emailed | REL, IPH, STG | A | STG | P7R L54 | [ ] |
| P7-29 | Daily caps and claim-before-send | Run the sweep twice in one day | The second sweep does not resend; daily caps hold | STG | A | STG | P7R L55 | [ ] |
| P7-30 | Invoice local notifications | Create overdue and recurring invoices; wait for 9 a.m. local; tap each; mark one paid and delete one; switch account; exceed 60 pending requests | `inv_` and `rinv_` fire at 9 a.m. local; taps route to the review; paid, deleted and account-change cleanup; the 60 cap keeps unrelated families (see also P10-29, P10-36) | REL, IPH | A | — | P7R L56 | [ ] |

## 15. Phase 8 — calendar, booking, routes and portals

Phase 8 has no runsheet: PL8 L397–400 planned one in task 8.15, and PL8 L5 and L455–461
record every Phase 8 task as pending. The native Phase 8 screens are on this branch, but
the parity rows still read Prototype or Not started (PM L39–41, L87–89, L124). Every row
below therefore needs **P8-CODE**: reconcile Phase 8's status before running it. Rows are
the P8S L438–442 checklist ("to be expanded in task 8.15"), one row per item except the
first three, which are one layout run. Record build, environment, steps,
expected/actual, evidence location and pass/fail/deferred for each row (P8S L442–443).

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P8-1 | Layout on iPhone and iPad, light and dark, large Dynamic Type | Open Calendar (day and week), Route, booking requests, booking settings and portal administration on iPhone and iPad, in light and dark, at large Dynamic Type | Nothing clips or overlaps; the accessible list sits beside the visual grid | REL, IPH, IPAD | A/B | P8-CODE | P8S L438–439 (items 1–3); PL8 L298, L302 | [ ] |
| P8-2 | VoiceOver and keyboard | Use VoiceOver and a hardware keyboard through the same screens | Every control has a label; the list alternative is reachable; keyboard navigation works | REL, IPH, IPAD | A/B | P8-CODE | P8S L439 (item 4) | [ ] |
| P8-3 | Day/week reschedule | Reschedule a job in day view and in week view, including one that conflicts and one booked appointment; force a save failure | Schedule-only save by latest ID; a conflict warns but saves; failure keeps the draft; a booked appointment publishes its reschedule before the old slot is released | REL, IPH, STG | A/B | P8-CODE, STG, BE-DEPLOY (booked jobs) | P8S L439–440 (item 5), L423 (S3), L427 (B4) | [ ] |
| P8-4 | Real Maps handoff | From Route open Apple Maps for one stop and for the full route; include a stop with no address and an unsupported handoff | Maps opens; a missing address and an open failure fall back, with copy offered; the route screen writes no business data | REL, IPH | A/B | P8-CODE | P8S L440 (item 6), L428 (R1); PL8 L350–352 | [ ] |
| P8-5 | Share and mail cancellation | Share a booking link and a portal link; cancel the share sheet; cancel the mail composer | Cancelling writes nothing and records no send | REL, IPH | A/B | P8-CODE | P8S L440 (item 7) | [ ] |
| P8-6 | Offline and relaunch | Use Calendar, booking settings and portal administration offline; relaunch | The offline state is shown truthfully; nothing is lost after relaunch; server-first actions wait for a connection | REL, IPH, STG | A/B | P8-CODE, STG | P8S L440 (item 8), L425 (B1–B2) | [ ] |
| P8-7 | Time-zone change | Change the device time zone; view the calendar and booking slots | The stored business date does not shift | REL, IPH | A/B | P8-CODE | P8S L440–441 (item 9), L133–134 | [ ] |
| P8-8 | Public booking race | Two browsers reserve the same slot on the hosted booking page at the same moment | Exactly one reservation succeeds; the other gets the defined conflict | BROWSER (two), STG | A/B | P8-CODE, STG, BE-DEPLOY, HOSTED | P8S L441 (item 10); RM L997 | [ ] |
| P8-9 | Disable and rotate before normal sync | Disable, then rotate, the booking link and the portal link; open the old links before the device's next normal sync; check a second device | The old link stops working as soon as the server acknowledges; the second device shows the new state | REL, +DEV2, STG, BROWSER | A/B | P8-CODE, STG, BE-DEPLOY, HOSTED, DEV2 | P8S L441 (item 11), L425 (B1–B2), L429 (P1); RM L998 | [ ] |
| P8-10 | React Native and Swift edits | Edit schedules, schedule settings, booking conversions and handled requests on each client | Both clients converge; server history and status are preserved | REL, +RN2, STG | A/B | P8-CODE, STG, RN-STG | P8S L441 (item 12), L426 (B3) | [ ] |
| P8-11 | Portal requests and content | As a customer on the hosted portal: view estimates, invoices, appointments and change orders; send a message, a reschedule request and a cancel request | Content is scoped to that customer; requests reach native as attention rows and convert; handled state converges | REL, IPH, STG, BROWSER | A/B | P8-CODE, STG, BE-DEPLOY, HOSTED | P8S L441–442 (item 13), L430–431 (P2, P3) | [ ] |
| P8-12 | Photo visibility | Mark job photos visible and hidden; view the portal | Only visible photos appear | REL, IPH, STG, BROWSER | A/B | P8-CODE, STG, HOSTED | P8S L442 (item 14), L430 (P2) | [ ] |
| P8-13 | ICS | Download the appointment ICS from the portal and from the booking manage page; add it to Calendar | The manage page and its ICS show the original slot; the portal shows the job schedule (C11) | BROWSER, IPH, STG | A/B | P8-CODE, STG, HOSTED | P8S L442 (item 15); P8C L460 (C11) | [ ] |
| P8-14 | Approval and payment navigation | From the portal open an estimate approval and an invoice payment | Each opens the correct approval page or payment link | BROWSER, STG | A/B | P8-CODE, STG, HOSTED, STRIPE-TEST | P8S L442 (item 16) | [ ] |
| P8-15 | Database concurrency and deployed migrations | With the Phase 8 migrations deployed to staging, run the G1–G4 competing-session proof against the staging database | Real competing operations, interruption recovery and stale clients behave as G1–G4 require; recorded apart from local-harness coverage and unfinished implementation | Staging database | A/B | P8-CODE, STG, BE-DEPLOY | P8S L413–415, L432; PL8 L199–200; P8C L38–41 (M1), L462 (C13) | [ ] |

Phase 8 source mapping:

| Source | Deferred item | Index row |
|---|---|---|
| P8S L438–442 | 16-item device/staging checklist | P8-1 (items 1–3), P8-2 to P8-14 (items 4–16) |
| P8S L43–47 | parity-verified level: device, isolated-staging, hosted-browser and cross-client evidence | Umbrella over P8-1 to P8-15 |
| P8S L27–30 | hosted pages live in tradeready-legal | Prerequisite HOSTED |
| P8S L413–415 | real database concurrency and deployed migration evidence | P8-15 |
| PL8 L199–200 | PostgreSQL concurrency proof, labelled deferred | P8-15 |
| PL8 L302 | device layout proof | P8-1 |
| PL8 L351–352 | device Maps/URL rows | P8-4 |
| PL8 L388–390 | database, staging and hosted-browser proof deferred to Phase 12 | Umbrella: P8-15 (database); the STG and BROWSER rows above |
| PL8 L397–400 | 8.15 creates a Phase 8 runsheet | Not created; this section stands in for it |
| P8C L38–41 (M1) | real competing-session proof deferred | P8-15 |
| P8C L42–43 (M2) | tradeready-legal unavailable; browser rows are dependencies | Prerequisite HOSTED |
| P8C L462 (C13) | real database concurrency evidence, BLOCKED | P8-15 |
| P8C L464 (C15) | hosted-page and browser evidence, BLOCKED | Prerequisite HOSTED (on P8-8, P8-9, P8-11 to P8-14) |
| RM L996 | exit: availability parity fixtures match | Unplaced (§21): a host criterion |
| RM L997 | exit: concurrent attempts cannot reserve the same slot | P8-8 |
| RM L998 | exit: disabling or rotating a link invalidates the old link immediately | P8-9 |

## 16. Phase 9 — Money, expenses, mileage, pricebook, export and import

IDs P9-1 to P9-52 follow the checkbox order of P9R L21–90. One is merged elsewhere: P9-6
(P9R L26, pull-to-refresh against staging) into P5-8. Rows that compare with React Native
use the RN app on the same team account ("RN reference").

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P9-1 | Money period chips | Switch This Month, Last Month, This Year and All Time | Every card changes consistently | REL, IPH | A | — | P9R L21; PM L95 | [ ] |
| P9-2 | Summary at large type and in dark mode | View the cash-basis summary, margin block and previous-window deltas at large Dynamic Type and in dark mode | They render without truncation (see also A11-AX5-1) | REL, IPH | A | — | P9R L22; PM L95 | [ ] |
| P9-3 | Money cards render | View the six-month chart, expenses by category, expense trends, top customers, customer mix and invoice aging | Each renders without truncation | REL, IPH | A | — | P9R L23; PM L95 | [ ] |
| P9-4 | Cards hide like RN | On accounts where RN hides them, view receivables, conversion funnel, revenue forecast, average job value, revenue by type and profitability | Each card hides exactly when RN hides it | REL, IPH; RN reference | A | — | P9R L24; PM L95 | [ ] |
| P9-5 | True-empty state | Use an account with no invoices, expenses or jobs; then add one of each in turn | The true-empty state shows only while all three are empty | REL, IPH | A | — | P9R L25 | [ ] |
| P9-7 | Tax set-aside card | Open the tax card with and without a vehicle election | It states its own IRS window and deadline; the vehicle-choice prompt appears for an unset election (the G2 editor row is appended by 12.00b.3, §23) | REL, IPH | A | — | P9R L27; PM L99 | [ ] |
| P9-8 | Create expense | Create an expense with a category, an optional job link and notes | The row shows the receipt glyph and the job label | REL, IPH | A | — | P9R L31; PM L96 | [ ] |
| P9-9 | Edit expense and concurrent change | Edit an expense; change the same expense on another device first, then save the stale copy | `createdAt` is kept; the stale copy is refused and the draft retained, per policy | REL, +DEV2, STG | A | STG, DEV2 | P9R L32; PM L96 | [ ] |
| P9-10 | Delete expense | Delete by swipe and from the editor | Each asks for confirmation first | REL, IPH | A | — | P9R L33 | [ ] |
| P9-11 | Attach receipt | Attach a receipt from the camera and from the photo library | The photo previews after attaching | REL, IPH | A | — | P9R L34; PM L96 | [ ] |
| P9-12 | Photo permission denied | Deny photo-library access, then try to attach | The flow states the problem; manual entry still saves | REL, IPH | A | — | P9R L35; PM L96 | [ ] |
| P9-13 | Camera unavailable | Try to attach where the camera is unavailable | Only the library option is offered | REL, IPH | A | — | P9R L36 | [ ] |
| P9-14 | Oversize or unreadable image | Attach an oversize or unreadable image | "That image couldn't be used for a receipt." shows and the form is unchanged | REL, IPH | A | — | P9R L37 | [ ] |
| P9-15 | Receipt scan with a client key | Save a client Anthropic key; scan a receipt | Fields pre-fill for review only; Save is still required | REL, IPH | A | KEYS | P9R L38; PM L103 | [ ] |
| P9-16 | Receipt scan without a client key | Signed in, with no client key, scan a receipt | The backend bearer path fills the fields or fails truthfully | REL, IPH | A | — | P9R L39; PM L103 | [ ] |
| P9-17 | Receipt scan offline or backend down | Scan in airplane mode (or with the backend unreachable) | "Couldn't read the receipt — enter the details manually"; manual save works | REL, IPH | A | — | P9R L40 | [ ] |
| P9-18 | Scan never clobbers | Type a field, then scan; then remove the photo | The typed field is unchanged; removing the photo clears the banner | REL, IPH | A | — | P9R L41 | [ ] |
| P9-19 | Receipt survives relaunch | Attach a receipt; relaunch | The receipt bytes persist under the app's media root | REL, IPH | A | — | P9R L42 | [ ] |
| P9-20 | Mileage period chips | Switch the period chips on the mileage log | The log filters; the summary card matches the trips in view | REL, IPH | A | — | P9R L46; PM L97 | [ ] |
| P9-21 | Add trip | "+ Add trip" with from/to chips (base and jobs) | It saves and shows the live distance line | REL, IPH | A | — | P9R L47 | [ ] |
| P9-22 | Odometer validation | Enter an end reading below the start; then equal readings | Below the start blocks save with the RN copy; equal readings save | REL, IPH | A | — | P9R L48 | [ ] |
| P9-23 | Edit and delete trip | Edit a trip; delete one from the row and one from the editor | `createdAt` is kept; both deletes work | REL, IPH | A | — | P9R L49 | [ ] |
| P9-24 | Mileage rate round trip | Edit the mileage rate | It round-trips to Settings and changes the deduction on the log card and the Money card | REL, IPH | A | — | P9R L50 | [ ] |
| P9-25 | Zero start reading | Save a trip with start reading `0`; reopen and save | It reopens with `0`, not blank, and saves unchanged | REL, IPH | A | — | P9R L51 | [ ] |
| P9-26 | Pricebook list | Search; check category grouping and quoted totals; delete an item | Uncategorized is last; totals match; delete asks for confirmation | REL, IPH | A | — | P9R L55; PM L98 | [ ] |
| P9-27 | Create service | Create a service with labor, materials, markup, overhead and margin | The editor's Estimated Total tracks every input | REL, IPH | A | — | P9R L56 | [ ] |
| P9-28 | Materials and direct costs | Add, edit and delete materials and direct costs, including a passthrough cost | A passthrough direct cost ignores markup | REL, IPH | A | — | P9R L57 | [ ] |
| P9-29 | Template picker | Apply a template to an empty item; then type first and apply one | It seeds empty lines and the scope checklist; typed input is never overwritten | REL, IPH | A | — | P9R L58 | [ ] |
| P9-30 | Use in a job | "Use in a job" for a chosen job | The prefill lands in that job's pricing calculator and saves only on that screen | REL, IPH | A | — | P9R L59 | [ ] |
| P9-31 | Pricebook AI panel | Request suggestions with a client key and through the backend; apply one row; force a malformed or error reply | Apply works per row; a bad reply shows "AI pricing is unavailable right now" | REL, IPH | A | KEYS | P9R L60; PM L98 | [ ] |
| P9-32 | Pricebook edit preserves data | Edit an item that carries unknown fields | Unknown fields and `createdAt` are kept | REL, IPH | A | — | P9R L61 | [ ] |
| P9-33 | Export range chips | Switch This Month, This Quarter, This Year, Last Year and All Time | The row counts change accordingly | REL, IPH | A | — | P9R L65; PM L101 | [ ] |
| P9-34 | Custom range guard | Set a custom range with From after To | It blocks with "Check your dates" | REL, IPH | A | — | P9R L66 | [ ] |
| P9-35 | Share CSVs | Share the income, expenses and mileage CSVs | Each opens correctly in Numbers and Files | REL, IPH | A | — | P9R L67; PM L101 | [ ] |
| P9-36 | Share accountant package | Share the accountant package | The ZIP opens and contains the 11 documented entries | REL, IPH | A | — | P9R L68; PM L102 | [ ] |
| P9-37 | CSV accents | Open the shared CSVs in Excel, Numbers and Google Sheets | Accents are correct (UTF-8 BOM) | REL, IPH | A | — | P9R L69 | [ ] |
| P9-38 | Cancelled share | Cancel the share sheet | No partial file is left in the user's view | REL, IPH | A | — | P9R L70 | [ ] |
| P9-39 | Pick a CSV | Pick CSVs with the document picker, including an unreadable and an empty file | Each is reported truthfully | REL, IPH | A | — | P9R L74; PM L100, L122 | [ ] |
| P9-40 | Header mapping | Import a file; override a column's mapping; set one column to Ignore | Headers auto-detect; each column can be overridden; Ignore is available | REL, IPH | A | — | P9R L75 | [ ] |
| P9-41 | Date format | Import with and without a date column mapped | The selector appears only with a date column; Auto matches the file | REL, IPH | A | — | P9R L76 | [ ] |
| P9-42 | Required columns | Tap "Preview import" before mapping the required columns | It refuses with "Still need: …" | REL, IPH | A | — | P9R L77 | [ ] |
| P9-43 | Import now | Run "Import now" | It writes once and reports exact counts (ok, created, matched, skipped, flagged) | REL, IPH | A | — | P9R L78 | [ ] |
| P9-44 | Re-import | Import the same file again | It asks "Already imported?" and imports only on confirmation | REL, IPH | A | — | P9R L79 | [ ] |
| P9-45 | Row limit | Import a file with more than 5,000 rows | It warns and imports the first 5,000 | REL, IPH | A | — | P9R L80 | [ ] |
| P9-46 | Import undo | Undo an import batch that matched an existing record | Only that batch's records are removed; the existing record is untouched | REL, IPH | A | — | P9R L81 | [ ] |
| P9-47 | Import history | Relaunch; then switch account on the same device | History is visible after relaunch and gone after the account switch | REL, IPH | A | — | P9R L82 | [ ] |
| P9-48 | Imported records sync | Import on one device; open a second device | The records sync and appear in Money, Jobs and Invoices | REL, +DEV2, STG | A | STG, DEV2 | P9R L83; PM L100, L122 | [ ] |
| P9-49 | Same figures on RN and native | Open Money on RN and native for the same account on one date | Identical figures (screenshot pair) | REL, +RN2, STG | A/B | STG, RN-STG | P9R L87 | [ ] |
| P9-50 | Same CSV bytes | Export the same range from RN and from native | Identical CSV bytes (diff) | REL, +RN2, STG | A/B | STG, RN-STG | P9R L88 | [ ] |
| P9-51 | Same import result | Import one CSV on native and the same CSV on RN | Identical records | REL, +RN2, STG | A/B | STG, RN-STG | P9R L89 | [ ] |
| P9-52 | Export and re-import round trip | Re-import a native export on RN, and an RN export on native | The counts round-trip | REL, +RN2, STG | A/B | STG, RN-STG | P9R L90 | [ ] |

## 17. Phase 10 — Today, insights, coach, notifications and background

IDs P10-1 to P10-51 follow the checkbox order of P10R L71–145. Merged elsewhere: P10-6
(L76) into P5-8; P10-41 (L132) into P4-B1; P10-44 (L135) into P4-B4; P10-45 (L136) into
P4-B3; P10-46 (L137) into P10-GATE-3 and P10-47 (L138) into P10-GATE-4 (the same gates
as the numbered list); P10-49 (L143) and P10-50 (L144) into P10-36 (the same tap-routing
scenario). P10-48 (L139) is closed (§8).

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P10-1 | Day/week schedule strip | Use the strip on Today; select days, including an empty one | It matches the RN week/day projection, including the current-day default and the empty-selected-day row | REL, IPH; RN reference | A | — | P10R L71; PM L39 | [ ] |
| P10-2 | Stats row | Compare Today's stats (earnings, overdue, leads) with RN for the same account and date | Identical figures (screenshot pair) | REL, IPH; RN reference | A | — | P10R L72; PM L39 | [ ] |
| P10-3 | Briefing sections | Open the overdue-invoice and follow-up/lead sections; use see-more; tap rows | Exact caps and see-more; each tap routes to the correct record | REL, IPH | A | — | P10R L73 | [ ] |
| P10-4 | Booking and portal attention rows | Create booking and portal requests; use each row's actions; resolve them | Contextual actions render; rows self-dismiss once resolved, including the native-only `missingJob` and `unconvertedActive` rows | REL, IPH, STG, BROWSER | A/B | P8-CODE, STG, HOSTED | P10R L74; PM L39 | [ ] |
| P10-5 | First-action hero | Use a sample-tour account before and after the first action; tap the hero | It appears and disappears per the "used once" rule and its tap routes correctly | REL, IPH | A | — | P10R L75 | [ ] |
| P10-7 | Today at large type and in dark mode | View every Today row at large Dynamic Type and in dark mode | No truncation (see also A11-AX5-1, A11-DARK-1) | REL, IPH | A | — | P10R L77 | [ ] |
| P10-8 | Setup checklist derivation | Compare the checklist with RN for a fresh and for a fully set-up account | Task derivation and the progress bar match RN | REL, IPH; RN reference | A | — | P10R L81; PM L43 | [ ] |
| P10-9 | Checklist dismissal | Dismiss the checklist; relaunch | Dismissal persists on the device and survives relaunch | REL, IPH | A | — | P10R L82 | [ ] |
| P10-10 | Checklist navigation | Tap each task's settings link | Each lands on the correct screen | REL, IPH | A | — | P10R L83 | [ ] |
| P10-11 | In-card notification permission | With permission undetermined, tap the `notifications` task's request; grant. Repeat and deny; tap "Open device settings" | The real system dialog shows; on grant the card updates without navigating away; on denial the card offers "Open device settings" and the link opens Settings | REL, IPH | A | — | P10R L84; PM L127 | [ ] |
| P10-12 | `rate` task deviation | Open Pricing Defaults and leave it | The `rate` task is marked done on leaving the page (the recorded deviation from RN's save trigger) and reads correctly | REL, IPH | A | — | P10R L85; PM L43 | [ ] |
| P10-13 | Eight insight kinds | On an account with realistic history, surface each of the eight insight kinds | Correct copy, priority order and top-three slice | REL, IPH | A/B | — | P10R L89; PM L44 | [ ] |
| P10-14 | Insights gated by setup | View Today before and after setup completion | The insights card is gated exactly as host-tested | REL, IPH | A | — | P10R L90; PM L44 | [ ] |
| P10-15 | Mute and snooze | Mute one insight and snooze one for N days; relaunch; let a snooze expire; sign out and switch account | Both persist on the device and are owner-bound; expired entries prune; both are scrubbed at sign-out and account switch | REL, IPH | A | — | P10R L91; PM L44 | [ ] |
| P10-16 | "Why am I seeing this?" | Open the reason sheet for every insight row through the long-press menu and the VoiceOver action, and through the ellipsis dialog on muteable rows | The sheet shows the insight's reason on every path; each path sends `insight_reason_viewed` once | REL+KEYS, IPH | A | KEYS | P10R L92 | [ ] |
| P10-17 | Stripe account-switch race (device) | With two Stripe-connected accounts, switch accounts while a Stripe status refresh is in flight | The checklist `stripe` task is never marked done for the wrong owner (implementation gate: P10-GATE-1) | REL, IPH | A/B | STRIPE-TEST | P10R L93 | [ ] |
| P10-18 | Coach provider routing (live) | Ask the coach with a client Anthropic key, with a client Groq key, and signed in with no key (backend proxy) | Each path gets a real reply from a live provider (see also AI-1) | REL, IPH | A | KEYS | P10R L97; PM L109 | [ ] |
| P10-19 | Coach system prompt | Capture the coach request body on the device | It cites the same business figures Today shows and never contains a secret provider key | REL, IPH | A | KEYS | P10R L98; PM L109 | [ ] |
| P10-20 | Coach transcript | Chat past `MAX_HISTORY`; sign out; switch account | The transcript persists in the session, respects `MAX_HISTORY` and is gone after sign-out and account switch | REL, IPH | A | — | P10R L99; PM L109 | [ ] |
| P10-21 | Coach rendering and errors | Get replies with bold, lists and line breaks; copy one; force a network failure, a malformed reply and a usage limit | Markdown-lite renders; copy works; each typed error bubble shows | REL, IPH | A | — | P10R L100 | [ ] |
| P10-22 | Coach `sending` boundary (device) | Send a message, background the app, then sign out or switch account before and after the reply | No residual `sending` state survives; RootView's teardown ran on each path (implementation gate: P10-GATE-2) | REL, IPH | A | — | P10R L101; PM L109 | [ ] |
| P10-23 | Data-aware quick prompts | Compare quick prompts with RN for the same account | Labels reference real job, invoice and customer counts and match RN | REL, IPH; RN reference | A | — | P10R L105; PM L110 | [ ] |
| P10-24 | Empty-state quick prompts | Open Coach on an account with no jobs or invoices | The empty-state prompts show | REL, IPH | A | — | P10R L106; PM L110 | [ ] |
| P10-25 | Quick-prompt icons | Show every current quick prompt | Each icon renders (four mapped, `sparkles` fallback); flag any fifth icon | REL, IPH | A | — | P10R L107; PM L110 | [ ] |
| P10-26 | Insight handoff | Tap "Ask coach" on an insight | The Coach tab opens with the prompt prefilled, editable and never auto-sent | REL, IPH | A | — | P10R L111; PM L111 | [ ] |
| P10-27 | Prefill consumed once | After P10-26, leave Coach and come back | The prefill does not return | REL, IPH | A | — | P10R L112; PM L111 | [ ] |
| P10-28 | Insight analytics transport | Show an insight and hand it off, with staging keys | The insight-shown and handoff events arrive through the real transport | REL+KEYS, IPH | A | KEYS | P10R L113; PM L111 | [ ] |
| P10-29 | Five namespaces deliver | Schedule `est_`, `appt_`, `review_`, `inv_` and `rinv_` notifications, more than 60 in total | Each delivers as an OS notification in the documented priority order under the shared 60-request cap | REL, IPH | A | — | P10R L117; PM L127, L139 | [ ] |
| P10-30 | Soft-ask shows once | Fresh account, permission undetermined: create the first invoice; then a second (same session and after relaunch) | The "Invoice reminders" alert shows exactly once and never again | REL, IPH | A | — | P10R L118; PM L127 | [ ] |
| P10-31 | Soft-ask "Turn on" | Tap "Turn on"; then Allow. Repeat on another fresh account with Don't Allow | The alert dismisses and the iOS dialog shows; Allow schedules pending reminders (one reconcile); Don't Allow schedules nothing and the alert never returns | REL, IPH | A | — | P10R L119; PM L127 | [ ] |
| P10-32 | Soft-ask "Not now" | Tap "Not now" | No iOS dialog; the alert never returns for that account | REL, IPH | A | — | P10R L120; PM L127 | [ ] |
| P10-33 | Soft-ask silent when settled | With permission already granted (and separately denied), create the first invoice | No alert (the flag is still stamped) | REL, IPH | A | — | P10R L121; PM L127 | [ ] |
| P10-34 | Soft-ask cancelled by sign-out | Trigger the alert, then sign out or switch account before answering | The alert is cleared on the next reconcile and never shows for the other account; the new account gets its own one-time ask | REL, IPH | A | — | P10R L122; PM L127 | [ ] |
| P10-35 | Categories survive relaunch | Kill and relaunch the app; check delivered notifications' actions | Categories are registered and work after relaunch | REL, IPH | A | — | P10R L123 | [ ] |
| P10-36 (= P10-49, P10-50) | Notification tap routing | Tap a delivered notification of each family (job, invoice, estimate, appointment, recurring invoice, review); then a stale or deleted record, a foreign-owner payload and an unrecognized payload | Each opens the exact still-open, owner-verified record it names; stale, foreign and unrecognized payloads fail closed with no navigation and no crash | REL, IPH | A | — | P10R L124, L143, L144; PM L127, L141 | [ ] |
| P10-37 | Archived job routing | Archive a job with a scheduled appointment and a pending review request; tap each notification; repeat with a deleted job | The Today row and the `appt_`/`review_` notifications remain and open the job, confirmation or review draft; the deleted job's notification fails closed | REL, IPH | A | — | P10R L125; PM L127 | [ ] |
| P10-38 | Cold-launch notification tap | With the app killed, tap a delivered notification of each family | Record the behavior: the tap is dropped until the auth gate resolves; no crash; no wrong record after sign-in; note whether the owner wants a deferred route (a product follow-up, not a Phase 10 defect) | REL, IPH | A | — | P10R L126 | [ ] |
| P10-39 | Owner-scoped cleanup | Sign out, and switch account, with pending requests from both accounts' families | Only the signing-out account's pending requests are cleared; foreign families are untouched | REL, IPH | A | — | P10R L127; PM L127 | [ ] |
| P10-40 | Invoice-dunning body variant | Trigger the invoice-dunning auto-outreach notification | The body variant renders and never auto-sends | REL, IPH | A | — | P10R L128; PM L127 | [ ] |
| P10-42 | Post-sync derived-state seam | After a real background sync pass with new data | (a) notifications reconcile from the committed snapshot; (b) the cached business snapshot refreshes; (c) Today and insights show the new data on the next foreground; exactly once per committed pass | REL, IPH, STG | A | STG | P10R L133; PM L140 | [ ] |
| P10-43 | Photo transfer during a background pass | Queue a job photo; let a background pass run that also reconciles notifications | The authenticated upload or backfill completes; no ordering regression | REL, IPH, STG | A | STG | P10R L134; PM L140 | [ ] |
| P10-51 | Cross-tab one-shot routing | Route from Today search, insights and booking rows, and from the Coach insight prefill; then navigate somewhere unrelated | Each lands on the right tab and record exactly once and leaves no stale route state (see also P5-7) | REL, IPH | A | — | P10R L145; PM L141 | [ ] |

### Phase 10 implementation gates (X rows)

These are not device rows (P10R L21–29). Each closes with a real fix or an explicit,
dated re-acceptance before Phase 12 exit (P10R L151), never by a device run.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P10-GATE-1 | 10.12 I4: Stripe account-switch write race | Add an injectable Stripe transport seam and an end-to-end test, or re-accept with a dated rationale | Closed or re-accepted before Phase 12 exit; device row P10-17 still runs | Host (implementation gate) | X | — | P10R L31–37 | [ ] |
| P10-GATE-2 | 10.13: Coach `sending` stuck-flag boundary | Add a test that forces the account boundary without RootView teardown, or re-accept with a dated rationale | Closed or re-accepted; device row P10-22 still runs | Host (implementation gate) | X | — | P10R L38–43 | [ ] |
| P10-GATE-3 (= P10-46) | 10.09 (a): stale cache after a failed later publish | Force a `makeSnapshot` failure on a later publish after an earlier one committed; decide whether a fix is needed | Closed with a fix or re-accepted with a dated rationale | Host (implementation gate) | X | — | P10R L44–50, L137 | [ ] |
| P10-GATE-4 (= P10-47) | 10.09 (b): three pre-commit failure codes | Add forcing tests for `pull/local-commit`, `pull/cursor-commit` and `pull/authentication` | Each proves the pre-`publish` return guard, or a dated re-acceptance | Host (implementation gate) | X | — | P10R L51–59, L138 | [ ] |

## 18. Phase 11 — widgets, Siri, deep links, analytics, crash reporting, accessibility, iPad, performance and cross-client

These are the 107 rows of P11R L71–245, in the source order and under the source IDs. The
Requirement column holds the Phase 11 requirement codes (P11R rows). The Phase 11 owned
items (P11R L58–64) follow as X rows at the end of this section.

Merged into these rows:

- Plan §7 items routed to 12.03 (PL12 L898, L904, L916; CH L606–612): L215.c is linked
  onto A11-TT-1 ("first tap hits"), L223.e onto IPAD-MT-3, and L249.e onto A11B-FR1-1 and
  A11B-FR1-2. None adds a row. L223.b (PL12 L901) fixed IPAD-KB-1 in the runsheet; the
  row is copied as it stands.
- P7R L46 (recurring invoice "Cancel plan" and "Delete plan") is the same check as
  Q11-P12-7, which carries both IDs.
- Roadmap Phase 6 device-proof items: on-my-way messaging (RM L936–938) into SIRI-4;
  time-tracking cross-device, widget and Siri replay (RM L904–906, L930–932) into
  Q11-P12-8; the Phase 6 analytics items (RM L779–780, L805–806, L927–929, L936–938)
  into AN-1; the Phase 6 exit "offline field actions sync safely" (RM L949) into SOAK-3.
  The Phase 6 source mapping (§13) lists each item.

### P11 — Build and extension packaging (11.01, 11.14)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| EXT-1 | W1 | Install REL. Long-press the Home Screen, open the widget gallery, search TradeReady | Next Job (small, medium) and Job Timer (small, medium) are listed | REL, STD18 and SE17 | A | — | P11R L71 | [ ] |
| EXT-2 | W1 | Sign in, create a job with a start time, background the app | The app writes `widgetSnapshot` into the real App Group container, and the widgets' timelines reload with the new job | REL, STD18, STG | A | STG | P11R L72 | [ ] |
| EXT-3 | W1, W4 | With widgets on the Home Screen: sign out; separately, delete the account | The App Group container is emptied and both widgets blank to the signed-out state | REL, STD18, STG | A | STG | P11R L73 | [ ] |
| EXT-4 | M1 | Archive the stage build (12.01, owner-approved) and inspect `TradeReadyWidgets.appex` and the app bundle | `PrivacyInfo.xcprivacy` is present in both; the extension declares no collected data; the app matches contract §8 (and OI-1's decision) | Archive of REL | A | OI-1 | P11R L74 | [ ] |

### P11 — Next Job widget (11.02)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| NJ-1 | W2 | Add Next Job small and medium to the gallery preview and the Home Screen | Both families are correctly sized and legible | REL, SE17, STD18, IPAD | A/B | — | P11R L80 | [ ] |
| NJ-2 | W2, L1 | Tap a `.job` card; then tap each other state (empty, signed out, stale) | The job card opens the app at the linked job; every other state opens the app root | REL, STD18 | A | — | P11R L81 | [ ] |
| NJ-3 | W2, W4 | Leave the device 24 h with the app closed, then open the app | After 24 h the widget shows the stale state; it recovers on the next app-triggered reload | REL, STD18 | A | — | P11R L82 | [ ] |

### P11 — Job Timer widget (11.03)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| JT-1 | W3 | Add Job Timer small and medium; drive it through all seven states | Every state renders sized and legible in the gallery and on the Home Screen | REL, SE17, STD18 | A | — | P11R L88 | [ ] |
| JT-2 | W3, A3 | Tap Start, then Stop, on the widget; then open the app | Each tap queues an action; the widget shows the pending state within one reload; the app replays it into canonical state on the next foreground or launch | REL, SE17 (iOS 17 interactive floor), STD18 | A | — | P11R L89 | [ ] |
| JT-3 | W3, A3 | Double-tap Start (two taps before the first reload lands) | Never two applied timer transitions | REL, STD18 | A | — | P11R L90 | [ ] |
| JT-4 | W3, W4 | Leave the device 24 h with the app closed, once with a timer running and once without | The stale-but-running and stale-with-no-timer states show; both recover on the next app-triggered reload | REL, STD18 | A | — | P11R L91 | [ ] |
| JT-5 | W3 | Where interactive widgets are unavailable (StandBy), tap the card | The whole-card fallback opens the correct job or the app root | REL, STD18 | A | — | P11R L92 | [ ] |

### P11 — App Intents and Siri (11.04)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| SIRI-1 | A1, A2 | Open the Shortcuts app; speak each §5.2 phrase | All eight app shortcuts are listed (Start/Stop Timer are not discoverable), and each phrase triggers its intent | REL, STD18, SE17 | A | — | P11R L98 | [ ] |
| SIRI-2 | A2, A3 | "Start a trip in TradeReady" with an odometer, then "Stop my trip …" | One trip is logged with the right miles, exactly once (`t_siri_` id) | REL, STD18, STG | A | STG | P11R L99 | [ ] |
| SIRI-3 | A2, A3 | "Log an expense …" with an amount and category | The §5.3 category labels are offered; the replay records the spoken amount (`e_siri_` id) | REL, STD18 | A | — | P11R L100 | [ ] |
| SIRI-4 | A1, L1 | "I'm on my way in TradeReady", once from a cold app and once warm | The review sheet for the next job opens once; nothing is sent automatically | REL, STD18 | A | — | P11R L101; RM L936–938 (on-my-way messaging device proof) | [ ] |
| SIRI-5 | A2, W4 | Sign out, then run every writing intent | Each answers "Open TradeReady and sign in first." and the container stays empty | REL, STD18 | A | — | P11R L102 | [ ] |
| SIRI-6 | A2 | "What's my next job …" and "How much am I owed …" with data, with none, and with a snapshot older than 24 h | The §5.1 dialogs; the stale snapshot is refused | REL, STD18 | A | — | P11R L103 | [ ] |

### P11 — Owner gating and stale data (11.05)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| OWN-1 | W4 | Sign out with widgets on the Home Screen, then ask Siri "Clock in" | Both widgets clear within one reload; Siri answers with the sign-in prompt | REL, STD18, STG | A | STG | P11R L109 | [ ] |
| OWN-2 | W4, A3 | Queue a widget action as account A, sign out, sign in as account B | The widgets show only B's data; A's queued action is never applied | REL, STD18, STG (two team accounts) | A | STG | P11R L110 | [ ] |
| OWN-3 | W4, L2 | Run a widget or Siri action against a deleted, then an archived, job; separately leave a widget 24 h without the app | Each fails closed with no wrong-record route | REL, STD18 | A | — | P11R L111 | [ ] |

### P11 — Deep links and routing gates (11.06)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| DL-1 | L1, L2 | Cold launch from a Next Job or Job Timer tap while signed in; repeat signed out, then sign in as the same owner; repeat, then sign in as a different owner | Signed in: the exact job opens. Signed out: it opens after the same owner signs in. A different owner: nothing opens | REL, STD18, STG | A | STG | P11R L117 | [ ] |
| DL-2 | A1, L1 | Siri "On My Way", warm and from a cold launch | One editable review, never twice, never sent automatically | REL, STD18 | A | — | P11R L118 | [ ] |
| DL-3 | L2 | Widget tap on an archived job, on a deleted job, and on an archived job with a running timer | Archived or deleted: "Job not found". Archived with a running timer: the job opens | REL, STD18 | A | — | P11R L119 | [ ] |
| DL-4 | L1 | Park a widget link while signed out, then complete Google Sign-In | Sign-in completes; the parked link then routes per DL-1 | REL, STD18, STG | A | STG | P11R L120 | [ ] |
| DL-5 | L1 | Tap an `est_` notification for an archived estimate | Its follow-up review opens | REL, STD18 | A | — | P11R L121 | [ ] |
| DL-6 | L2 | Trigger "Job not found" while another sheet is up (an On My Way review, an estimate follow-up, a job editor) | The sheet appears on top or after the other closes, is never silently lost, and Done dismisses only it | REL, STD18, IPAD | A/B | — | P11R L122 | [ ] |

### P11 — Analytics (11.07, 11.08)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| AN-1 | P1 | REL+KEYS: use the app for a session. Then a DBG build and a keyless REL | REL+KEYS sends catalog events, `Application Opened`/`Backgrounded` and `$identify` to the staging PostHog project. DBG and keyless REL send nothing (proxy or live view) | REL+KEYS, DBG, REL; STD18 | A | KEYS | P11R L128; RM L779–780, L805–806, L927–929, L936–938 (Phase 6 analytics proof) | [ ] |
| AN-2 | P4 | A REL+KEYS session exercising every tab | No `$autocapture`, `$rageclick`, `$exception`, push or feature-flag event arrives; every event carries only allow-listed properties | REL+KEYS, STD18 | A | KEYS | P11R L129 | [ ] |
| AN-3 | P3 | Sign in with a password, with Apple and with Google; then sign out, "Use another account" and delete the account | Each sign-in shows `$identify` with the Supabase id and `sign_in{method}`. Each exit shows a reset (a new anonymous distinct id) before the next owner's first event | REL+KEYS, STD18, STG | A | KEYS, STG | P11R L130 | [ ] |
| AN-4 | P2 | Navigate the tabs and detail screens | `$screen` arrives with the RN leaf route names | REL+KEYS, STD18 | A | KEYS | P11R L131 | [ ] |
| AN-5 | P2 | Tap an estimate follow-up, an overdue-invoice and an appointment notification | Each sends its `*_opened` event once | REL+KEYS, STD18 | A | KEYS | P11R L132 | [ ] |
| AN-6 | P2 | Run onboarding and the paywall on a fresh account | `welcome` → `business` → `starting_point`, and `subscription_paywall_shown{onboarding_gate}` once per presentation | REL+KEYS, STD18, STG | A | KEYS, STG | P11R L133 | [ ] |

### P11 — Crash reporting and privacy manifest (11.09)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| CR-1 | R1 | After OI-2: archive with `TRADEREADY_SENTRY_DSN` set, then `SENTRY_AUTH_TOKEN=… sh native/scripts/upload-sentry-dsyms.sh <App.xcarchive>` (add `SENTRY_INCLUDE_SOURCES=1` only if uploading source is intended) | Sentry lists the app and widget dSYMs; no source bundle is sent by default | Archive of REL+KEYS | A | OI-2, KEYS | P11R L139 | [ ] |
| CR-2 | R1, R2 | Trigger a test crash and a `deleteAccount` failure | Each arrives symbolicated with `release = <bundle>@<version>+<build>`, `environment`, user `{id}` only (no email, IP or device name) and a `[Filtered]` URL token | REL+KEYS, STD18, STG | A | OI-2, KEYS, STG | P11R L140 | [ ] |
| CR-3 | R3 | Queue a change offline, then make the push fail | One `pushQueue` issue titled `[<code>] Sync push left changes queued` | REL+KEYS, STD18, STG | A | OI-2, KEYS, STG | P11R L141 | [ ] |
| CR-4 | R1 | Use the app across several sessions | Sessions appear under Release Health; traces sample at about 20 % | REL+KEYS, STD18 | A | OI-2, KEYS | P11R L142 | [ ] |
| CR-5 | R1 | A DBG build and a REL without the DSN | Nothing is sent | DBG, REL; STD18 | A | OI-2, KEYS | P11R L143 | [ ] |
| CR-6 | R2 | On the CR-2 events, inspect the full stored event JSON | Every field the SDK writes back after `beforeSend` (device context, breadcrumbs, request, threads) is covered by the redactor: no secret, token, email or customer text survives | REL+KEYS, STD18 | A | OI-2, KEYS | P11R L144 | [ ] |
| CR-7 | R3 | Report a non-`Error` (plain-object) failure through `reportError` | The Sentry issue title is the `NSDebugDescriptionErrorKey` text, redacted, as contract §10.4 records | REL+KEYS, STD18 | A | OI-2, KEYS | P11R L145 | [ ] |
| CR-8 | R2 | Inspect a sampled transaction and its spans | Transaction and span descriptions/data are redacted; the only redaction path for transactions is `beforeSendSpan` (confirm nothing unredacted reaches Sentry through another path) | REL+KEYS, STD18 | A | OI-2, KEYS | P11R L146 | [ ] |
| CR-9 | R1 | Inspect the archive's dSYMs | Release produces dSYMs (`DEBUG_INFORMATION_FORMAT` resolves to `dwarf-with-dsym`; the project sets no override); each dSYM's UUID matches the binary (`dwarfdump --uuid`) and Sentry symbolicates CR-2 with it | Archive of REL | A | OI-2 | P11R L147 | [ ] |
| PRIV-1 | M1 | Enter the App Store Connect privacy labels (12.01) | The labels match the app `PrivacyInfo.xcprivacy` and the OI-1 decision (email, synced records, photos) | App Store Connect (owner) | C | OI-1 | P11R L148 | [ ] |

### P11 — Settings › AI Assistant keys (11.15)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| AI-1 | P4 | Switch Advanced on; save a real Groq key, then a real Anthropic key; remove Anthropic; remove both | The Provider row reads Groq, then "Anthropic (Claude)", and the coach answers through that provider. Without Anthropic: Groq. Without both: TradeReady AI (backend) | REL, STD18 (owner-held provider keys) | A | KEYS | P11R L154 | [ ] |
| AI-2 | P4 | VoiceOver through the Advanced section | It reads "Advanced AI settings", "Groq API key" and "Anthropic API key"; the field shows dots; the status reads only "Saved"; the key is never spoken | REL, STD18 | A | — | P11R L155 | [ ] |
| AI-3 | P4 | Sign out and back in; separately delete the account | Both keys are gone after each | REL, STD18, STG | A | STG | P11R L156 | [ ] |
| AI-4 | P4 | Save both keys. "Use another account" from "Cloud data unavailable" and sign in as B; repeat with the password-recovery link (cancel it; separately finish it) | B sees "Not set" for both keys and the Provider row reads TradeReady AI; no key survives either exit (see OI-4 items 3 and 4) | REL, STD18, STG | A | STG | P11R L157 | [ ] |
| AI-5 | P4, R2 | REL+KEYS: enter a key, send a coach message | No Sentry event, PostHog event or `$screen` payload contains the key | REL+KEYS, STD18 | A | KEYS, OI-2 | P11R L158 | [ ] |

### P11 — Accessibility (11.10a, 11.10b)

Row IDs are the ones the tasks assigned (plan §7).

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| A11-VO-1 | H1 | VoiceOver sweep of Today, Jobs, Invoices, Customers, Money and Settings, plus the booking, route and recurring plus buttons | Every control reads a meaningful label; none reads "Button" or "plus" | REL, STD18 | A | — | P11R L166 | [ ] |
| A11-VO-2 | H1 | Today job card: reach "On my way" with VoiceOver (A13) | Reachable and actionable | REL, STD18 | A | — | P11R L167 | [ ] |
| A11-VO-3 | H1 | Reading order on Today, Money and Job detail (A12) | Order follows the visual layout | REL, STD18 | A | — | P11R L168 | [ ] |
| A11-AX5-1 | H1 | AX5 on the Money cards, Today stats, Jobs stats and Invoices metrics | Rows stack; no amount is truncated or split | REL, SE17 | A | — | P11R L169 | [ ] |
| A11-AX5-2 | H1 | AX5 on the auth and recovery submit buttons, the paywall and onboarding | Labels are not clipped; buttons grow | REL, SE17 | A | — | P11R L170 | [ ] |
| A11-AX5-3 | H1 | AX5 on the week strip | Capped at AX1 without overlap; VoiceOver reads each day | REL, SE17 | A | — | P11R L171 | [ ] |
| A11-DARK-1 | H1 | Dark mode: tint text and outlines, prominent buttons, selected chips, week day, Today hero, working days | Legible; the selected state is visible; white labels sit on the fill | REL, STD18 | A | — | P11R L172 | [ ] |
| A11-RM-1 | H1 | Reduce Motion on: Money section expand, coach scroll-to-bottom | No animation | REL, STD18 | A | — | P11R L173 | [ ] |
| A11-SC-1 | H1 | Switch Control on auth (email → password → submit), schedule working days, route reorder | Items are reachable in order; 44 pt targets activate | REL, STD18 | A | — | P11R L174 | [ ] |
| A11-KB-1 | H1 | Hardware keyboard on auth and recovery: Return chains | Email → password → submit; new password → confirmation → submit | REL, IPAD | A/B | — | P11R L175 | [ ] |
| A11-TT-1 | H1 | Touch targets: week arrows, route chevrons, working days | Each hits on the first tap | REL, SE17 | A | — | P11R L176; PL12 L898 (§7 L215.c); CH L610 | [ ] |
| A11-IC-1 | H1 | Increase Contrast on and off, light and dark | No regression against the §12.1 table | REL, STD18 | A | — | P11R L177 | [ ] |
| A11-W-1 | H1 | Widgets at AX sizes (A9) | The fixed canvas is legible, matching RN | REL, STD18 | A | — | P11R L178 | [ ] |
| A11B-KB-1 | H1 | iPad hardware keyboard: hold ⌘ on Jobs, Invoices, Customers, Maintenance plans and Coach | The HUD lists "Add new job", "Add new invoice", "Add new customer", "Add maintenance plan" and "New chat", with no blank entry | REL, IPAD | A/B | — | P11R L179 | [ ] |
| A11B-KB-2 | H1 | Done bar on a price/rate/phone field and a notes field in the job, invoice, expense, trip and pricebook editors and Settings › Pricing | "Done" shows above the keyboard, reads "Dismiss keyboard", dismisses it, and appears once | REL, STD18 | A | — | P11R L180 | [ ] |
| A11B-VO-1 | H1 | VoiceOver on the Money charts (Last 6 Months, 12-Month Trend, Expense Trends) | One element per chart reads "{title} chart" and every month with its figures | REL, STD18 | A | — | P11R L181 | [ ] |
| A11B-VO-2 | H1 | VoiceOver on the Today job card: swipe up or down for actions | "On my way to {name}" is offered and sends | REL, STD18 | A | — | P11R L182 | [ ] |
| A11B-VO-3 | H1 | VoiceOver on a job photo whose delete or visibility change failed | The error is read after "Open job photo" | REL, STD18 | A | — | P11R L183 | [ ] |
| A11B-DARK-1 | H1 | Dark mode: clock out, sheet error text, the Money danger tone, the booking "Cancelled" kind | Rust text and fills are legible; white text sits on the fill | REL, STD18 | A | — | P11R L184 | [ ] |
| A11B-AX5-1 | H1 | AX5: Today schedule, booking requests, route list and preview, job photos, Settings avatar and sync badge | Time and kind sit above their rows; nothing clips; at least one photo fits the row | REL, SE17 | A | — | P11R L185 | [ ] |
| A11B-TT-1 | H1 | Tap the Today card's "On my way" at its edge | It sends "On my way" instead of opening the job | REL, SE17 | A | — | P11R L186 | [ ] |
| A11B-FR1-1 | H1 | Light and dark: Settings Sign out and Delete account, the delete sheet's toolbar Delete (enabled and disabled), the paywall Sign out, editor Delete rows, Remove receipt photo, the job-photo trash, a booking Decline — on iOS 17 and 18 as well as 27 | Each label is rust, not system red; a disabled one reads as disabled; VoiceOver still announces it as destructive | REL, SE17, STD18, PM27 | A | — | P11R L187; PL12 L916 (§7 L249.e); CH L612 | [ ] |
| A11B-FR1-2 | H1 | Tap 12 pt above and below the Today card's "On my way" text | It sends "On my way"; the status row is no taller than a card without the link | REL, SE17, STD18 | A | — | P11R L188; PL12 L916 (§7 L249.e); CH L612 | [ ] |

### P11 — iPad layout, multitasking and keyboard (11.11)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| IPAD-L-1 | H2 | iPad 11-inch (portrait and landscape) and iPad mini (portrait): Today, Jobs, Invoices, Customers, Money, Coach, Settings and one editor sheet | A centered ~700 pt column; scroll area, indicators and backgrounds full width; nothing clipped | REL, IPAD | A/B | — | P11R L194 | [ ] |
| IPAD-L-2 | H2 | iPad 13-inch landscape, and a large sheet under Stage Manager | Sheet content capped at 700 pt; the calendar and route sheets read correctly | REL, IPAD (13-inch) | A/B | — | P11R L195 | [ ] |
| IPAD-L-3 | H2 | iPhone Pro Max landscape: Jobs and Today | 700 pt column inside the safe areas; portrait unchanged | REL, PM27 | A | — | P11R L196 | [ ] |
| IPAD-L-4 | H2 | iOS 17 floor (SE-class; an iPad on iPadOS 17): a list wider than 740 pt | Rows at the computed margin as measured on iOS 26; otherwise open an item | REL, SE17 and an iPadOS 17 iPad | A/B | — | P11R L197 | [ ] |
| IPAD-MT-1 | H2 | Split View at 1/3, 1/2 and 2/3 beside another app, both orientations | No clipping; narrow widths full width; one tab bar and one navigation bar | REL, IPAD | A/B | — | P11R L198 | [ ] |
| IPAD-MT-2 | H2 | Slide Over (320 pt): every tab plus the job, invoice and expense editors | Usable without horizontal clipping | REL, IPAD | A/B | — | P11R L199 | [ ] |
| IPAD-MT-3 | H2 | Stage Manager: drag a window slowly across 690–760 pt on a list and a scroll screen; open a wide screen and a large sheet fresh | The column engages without a jump or layout loop; record any one-frame shift on first appearance (review M6) | REL, IPAD | A/B | — | P11R L200; PL12 L904 (§7 L223.e); CH L611 | [ ] |
| IPAD-ROT-1 | H2 | Rotate through all four orientations with a pushed detail, an open sheet and the keyboard up | State kept; no second navigation bar; the focused field stays visible; the Coach composer rises with the keyboard | REL, IPAD | A/B | — | P11R L201 | [ ] |
| IPAD-KB-1 | H1, H2 | Hardware keyboard: Esc, ⌘S, ⌘⏎ (change-order Confirm), ⌘N on the five owners, including under sheets, dialogs, pushed screens and a UIKit child sheet; cancel a swipe-back on a pushed plan, then ⌘N (see plan §7, 11.11 for the full list) | Each fires once, only for the visible screen; ⌘N does nothing while its owner presents or is covered; on Maintenance plans ⌘N opens a new plan; Esc dismisses only the top sheet; no key triggers delete-account Delete | REL, IPAD | A/B | — | P11R L202; PL12 L901 (§7 L223.b: the fixed row, copied as it stands) | [ ] |
| IPAD-KB-2 | H1, H2 | Tab/Shift-Tab through the job, invoice, customer and expense editors; Return in a single-line field and in Coach | Focus follows visual order; Return ends editing (a newline in Coach) | REL, IPAD | A/B | — | P11R L203 | [ ] |
| IPAD-AX-1 | H1, H2 | AX5 on iPad in 1/2 Split View: Money cards, Today stats, editors | The column and the AX stacks do not clip | REL, IPAD | A/B | — | P11R L204 | [ ] |

### P11 — Performance, poor network and soak (11.12)

The full steps, data tiers and record fields are in
[native-phase-11-performance.md](native-phase-11-performance.md) §2–§4; the Phase 12 owner
of each row is named there. That document sets **no numeric threshold**; Phase 12.00
owns thresholds (absolute targets). "Expected result" below is the pass evidence the
row must record.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| PERF-1 | H4 | Cold launch, one launch per App Launch trace, per data tier, five runs | Time to first frame plus `Launch`, `SnapshotLoad` (and first-run `LegacyMigration`) intervals recorded against the 12.00 targets | REL, SE17, PM27, STG | A | STG | P11R L216 | [ ] |
| PERF-2 | H4 | Warm launch (background, force-quit, relaunch within 10 s) | As PERF-1 | REL, SE17, PM27 | A | — | P11R L217 | [ ] |
| PERF-3 | H4 | Decide whether to add a UI-test target for `XCTApplicationLaunchMetric` (none exists) | A recorded decision; results if added | 12.02 decision | X | — | P11R L218 | [ ] |
| PERF-4 | H3, H4 | Xcode Organizer and TestFlight MetricKit aggregates (launch, hangs, memory, disk writes, battery, terminations) | Per-build percentiles, or "insufficient data" recorded | REL (TestFlight cohort) | B | COHORT, BAR | P11R L219 | [ ] |
| PERF-5 | H4 | Profile the first native launch of the 12.04 upgrade | `LegacyMigration`/`SnapshotLoad` durations and the migration outcome | REL, RN-UP, PM27 | A | EXPO-BUILD, G6 | P11R L220 | [ ] |
| PERF-6 | H4 | Sign in on a fresh install for each data tier | `InitialSync` duration, outcome and count | REL, SE17, PM27, STG | A | STG | P11R L221 | [ ] |
| PERF-7 | H3 | Foreground and manual sync on typical and large tiers | `DeltaPull` durations and outcome mix; Cloud Sync diagnostic codes (the OI-3 signal) | REL, STD18, STG | A | STG | P11R L222 | [ ] |
| PERF-8 | H4 | Large tier: scroll Jobs and Invoices, search, switch every filter under Time Profiler and Hangs | `JobListProjection`/`InvoiceListProjection` durations; hitches or hangs recorded | REL, SE17, PM27 | A | — | P11R L223 | [ ] |
| PERF-9 | R1, H4 | Read crash-free sessions from Sentry per build | Crash-free session rate recorded | REL+KEYS (cohort) | B | COHORT, BAR, OI-2, KEYS | P11R L224 | [ ] |
| PERF-10 | H4 | Optional: PERF-1 and PERF-2 on the installed App Store Expo build, same device | A reference launch time only, never a threshold | App Store Expo build, PM27 | A | EXPO-BUILD | P11R L225 | [ ] |
| SOAK-1 | H3 | Typical tier, 5 queued edits, "Very Bad Network"; trigger the background task, then 2 h natural scheduling; repeat with "100% Loss" | Each task completes exactly once; server rows = local records; pending reaches 0 after recovery | REL, STD18, STG | A | STG | P11R L226 | [ ] |
| SOAK-2 | H3 | Large tier, 30 min of mixed use under Allocations and Leaks | No unbounded memory growth; no leaks in `N/` types; no jetsam | REL, SE17, STG | A | STG | P11R L227 | [ ] |
| SOAK-3 | H3 | Airplane mode, 10 edits incl. a re-edit and delete; force-quit; relaunch offline; reconnect; repeat with a 1 s mid-sync drop (RM L949: include Phase 6 field actions among the edits, e.g. a status change, a clock in/out and a job photo) | Each change on the server once, in order; nothing lost or duplicated; Cloud Sync recovers | REL, STD18, STG | A | STG | P11R L228; RM L949 (exit: offline field actions sync) | [ ] |
| SOAK-4 | H3 | Low Power Mode, typical tier, 60 min use plus 2 h idle | Foreground sync works; background deferral recorded; no busy loop while idle; battery % recorded | REL, STD18, STG | A | STG | P11R L229 | [ ] |
| SOAK-5 | H2, H3 | Stage Manager width drag across 690–760 pt for 60 s under Time Profiler | CPU returns to idle after the drag; no layout loop; one-frame shift recorded | REL, IPAD | A/B | — | P11R L230 | [ ] |
| SOAK-6 | H3 | Typical tier, 60 min with 20 background/foreground cycles, a sign-out/sign-in and widget refreshes | Memory stays level; no crash; Organizer terminations recorded | REL, STD18, STG | A | STG | P11R L231 | [ ] |
| SYNC-1 | H3 | Fresh install. Sign in to an account that has a due recurring job rule and a recurring plan whose occurrence another device already generated. Background and foreground the app while the initial sync is loading | Exactly one occurrence per rule, locally and on the server; no duplicate after the sync completes (the host counterpart is the 11.12 fix round 3 case in `native/PoorNetworkTests/main.swift`, driven through the `AppStore.testRunRecurringGenerationAfterInitialSync` hook) | REL, STD18 plus a second device, STG | A/B | STG, DEV2 | P11R L232 | [ ] |

### P11 — Cross-client qualification (11.13)

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| Q11-P12-1 | W1, W4 | Same run as EXT-2, EXT-3, OWN-1. On an iPhone and an iPad: install REL, sign in, create a job and an invoice, clock in, then sign out; sign in as another owner | The Next Job and Job Timer widgets show the owner's data, then clear on sign-out; nothing from the previous owner appears after the new sign-in | REL, STD18, IPAD, STG | A/B | STG | P11R L238 | [ ] |
| Q11-P12-2 | W2, W3 | Same run as NJ-1, JT-1 to JT-4. Add Next Job (small, medium) and Job Timer; use the interactive timer button; leave the device a day | The widgets render; the button starts and stops the timer through the queue; a snapshot older than 24 h shows the stale state | REL, STD18 | A | — | P11R L239 | [ ] |
| Q11-P12-3 | A1, A2 | Same run as SIRI-1 to SIRI-4, DL-2. Speak each of the ten App Intent phrases (contract §5), including On My Way, from a cold and a warm app | Each intent's action replays once (trip `t_siri_`, expense `e_siri_`, timer); On My Way routes to the job composer | REL, STD18 | A | — | P11R L240 | [ ] |
| Q11-P12-4 | P1, R1 | StoreKit sandbox or TestFlight purchase and restore, with staging PostHog and Sentry keys supplied | `subscription_purchased` and catalog events arrive with allow-listed properties only; Sentry receives a redacted event | REL+KEYS, STD18, STG | A | KEYS, STG, SANDBOX | P11R L241 | [ ] |
| Q11-P12-5 | H1 | Share an invoice PDF in each status and an estimate PDF; view on the device and in Mail; print one | Stamps and accent use the A30 colors and stay legible when printed | REL, STD18 | A | — | P11R L242 | [ ] |
| Q11-P12-6 | R2 | On an RN-UP device, read the `LegacyBackups/` files' protection class and the backup-exclusion flag | Every file is `NSFileProtectionComplete`, and the tree is excluded from iCloud and Finder backup | REL, RN-UP | A | EXPO-BUILD, G6 | P11R L243 | [ ] |
| Q11-P12-7 (= P7-23) | H1 | Final review I1. On Maintenance plans, open a plan's actions and tap "Cancel plan", then confirm; repeat with "Delete plan"; separately dismiss each confirmation (P7R L46: also create and edit a rule, then pause and resume it) | Confirming cancels (or deletes) that plan, visibly and after a relaunch; dismissing changes nothing; Pause still works; generated invoices are preserved through cancel and delete | REL, STD18, IPAD | A/B | — | P11R L244; P7R L46 | [ ] |
| Q11-P12-8 | W2, A1 | Final review C1. With a second device (or the RN app) signed in to the same account: start the timer from the Job Timer widget, log a trip and an expense by Siri, then open the app online and wait for a sync; stop the timer from the widget and sync again (RM L904–906: also clock in and out from job detail on the first device) | The timer session, trip and expense reach the server and the second device; a pull while they are pending does not drop them; the stop syncs too; the job-detail session reaches the second device too | REL, STD18 plus a second device, STG | A | STG, DEV2 | P11R L245; RM L904–906, L930–932 (time tracking cross-device, widget and Siri replay) | [ ] |

### P11 — Owned items and open gates (X rows)

The Phase 11 owned items (P11R L50–64) are decisions or builds, not device rows. Each
closes with a dated decision, a build or a waiver linked on the row. OI-4 is closed (§8).
IDs carry the `P11-` prefix because Phase 8 uses G1–G4 for other items (P8S L432).

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P11-G1 | No native remote push (booking alerts) | Dated waiver taken 2026-09-25 (CH §5.1, D1). Its conditions: 12.01 confirms, read-only, that the production Worker has its email binding; P12-G1-1 runs on an upgraded device | Waiver recorded; both conditions met; re-read at 12.08 | Decision | X | — | P11R L58; CH L273–285 | [ ] |
| P11-G2 | No native tax-settings editor | Built in 12.00b.3 before Stage A (CH §5.2, D2). 12.00b.3 appends its device row in §23 | The editor is built and its device row passes | Build (12.00b.3) | X | — | P11R L59; CH L287–292 | [ ] |
| P11-G6 | Retention of the RN source files and legacy backups | Owner approves the provisional keep-never-delete policy (CH §5.4) | Approval dated and linked before any SA2 upgrade run (then prerequisite G6 is met) | Decision | X | — | P11R L60; CH L181, L303–305 | [ ] |
| P11-OI-1 | Privacy-label declaration of first-party backend data | 12.01 decides the declaration (email, synced records, photos); the owner enters the labels | Decision linked; EXT-4 and PRIV-1 can then close | Decision | X | — | P11R L61; CH L161 | [ ] |
| P11-OI-2 | Sentry project `tradeready-ios` in org `tradeready-3r` | The owner creates the project before the first dSYM upload | Project exists; CR-1 to CR-9 unblock | Owner action | X | — | P11R L62; CH L162 | [ ] |
| P11-OI-3 | 429 push policy | Provisional policy recorded (CH §5.5): accept for Stages A and B, monitor TH-6 through PERF-7, collect the real rate limits before Stage B entry | Decision linked; the rate limits recorded; the blocker condition not hit | Decision | X | — | P11R L63; CH L348–373 | [ ] |
| P11-I2 | Sync push wedges on a non-auth 4xx | Fixed in 12.00b.1 (CH §5.3, D3; unwaivable). 12.00b.1 appends its device row in §23 if it has one; 12.02 makes TH-7 a monitored signal | Fixed before cutover; the rejected-change surface works as D3 describes | Build (12.00b.1) | X | — | P11R L64; CH L294–301 | [ ] |

## 19. Phase 12 rows

Two checks were deferred to this index by Phase 12 sources rather than by a runsheet.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|
| P12-G1-1 | G1 waiver condition: an upgraded device keeps its Expo-era push token | On an RN-UP device whose Expo build registered for push, open the native stage build and let it sync, so the synced settings keep the Expo-era `settings.pushToken` (do not record the token). As a customer on the hosted booking page for that owner, submit a new request; then, from the booking manage page, a reschedule request and a cancellation | For each alert the owner email arrives. No push is delivered, because the native build has no `aps-environment` entitlement; if a push does arrive, tapping it opens the app without a crash. Record which of the two happened | REL, RN-UP, BROWSER | A | EXPO-BUILD, G6, HOSTED | CH L283 (§5.1 Conditions) | [ ] |
| P12-RATE-1 | App Store rating prompt after the owner gets paid | On a **development-signed build** on a fresh install (the prompt state is device-scoped UserDefaults): send two estimates, then mark an invoice fully paid (the third win). Then mark another invoice fully paid. On a separate fresh install, send three estimates only. Optional at Stage C: note whether the sheet appears in the App Store build | About 2 s after the third win (an invoice paid), the StoreKit rating sheet appears (its submit is disabled in a development build). It does not appear again in the same app version. Estimate-sent wins alone do not show it before the tenth win. A paid status that arrives by sync does not count. In TestFlight the sheet never appears, which is not a failure. In the App Store build it appears only within Apple's limit of three a year, so its absence there is not a failure either | DEV-SIGNED, STD18 (optional: APPSTORE) | A | SIGN-1 | 1e47f26 (commit message: "Device check of the system sheet deferred to Phase 12 (never shown in TestFlight)"); `N/Domain/NativeAppRatingPrompt.swift`; `N/NativeAppRatingPromptPresenter.swift` | [ ] |

P12-RATE-1: only a development-signed build shows the sheet on demand. TestFlight builds
never show it, and the App Store build shows it at Apple's discretion. The row therefore
runs on a development-signed build installed from Xcode, which needs SIGN-1 but not
VER-1 or TF-INT. The 120-day cooldown and the clock-rollback rule are host-tested
(`native/AppRatingPromptTests/main.swift`) and are not repeated on a device.

## 20. Exit, aggregate and rule items (not rows)

The runsheets end with exit checklists. Their items are aggregates over the rows above or
restate a rule from §2, so they are not index rows. Each is listed once here.

| Source | Item | Where it is satisfied |
|---|---|---|
| DTR L140 | Phase 2 exit: P1–P8 pass on a physical device | P2-P1 to P2-P8 |
| DTR L282–283 | Phase 2 complete: P1–P8 pass and the Expo rollback rehearsal succeeds | P2-P1 to P2-P8 and P2-RB |
| DTR L284 | Phase 3 complete: every A/O/S/D row passes, including S7 | §10 Phase 3 rows plus the passes in §8 |
| P4R L154 | B1–B5 all pass | P4-B1 to P4-B5 |
| P4R L155 | P1–P8 all pass | P4-P1 to P4-P8 |
| P4R L156 | C1–C7 all pass | P4-C1 to P4-C7 |
| P4R L157 | Every interrupted path reconverges automatically | Aggregate over §11 (the interrupted-path rows record it) |
| P4R L158 | No duplicate, lost, partial or cross-account data observed | Aggregate over §11 |
| P7R L60 | All rows have device/staging evidence or explicit waivers | Aggregate over §14 and the merged rows P5-6, P5-8, Q11-P12-7 |
| P7R L61 | No unresolved severity-1/2 defects | Rule 3 (§2); charter §2 defect severity |
| P7R L62 | Phase 7 parity rows advance to `Verified` only after the sheet passes | Rule 4 (§2) |
| P9R L94 | Every row has device/staging evidence or a recorded waiver | Aggregate over §16 and P5-8 |
| P9R L95 | A failing row is a defect with the build ID | Rule 3 (§2) |
| P9R L96 | Parity to `Verified` only after the rows pass | Rule 4 (§2) |
| P10R L149 | Every row has evidence or a recorded waiver | Aggregate over §17 and the merged rows it names |
| P10R L150 | A failing row is a defect with the build ID | Rule 3 (§2) |
| P10R L151 | The four open implementation gates are closed or re-accepted before Phase 12 exit | P10-GATE-1 to P10-GATE-4 |
| P10R L152 | Parity to `Verified` only after the rows pass | Rule 4 (§2) |
| P11R L249–250 | Every row has evidence or a dated waiver recorded in this index | Aggregate over §18 |
| P11R L251–252 | G1 and G2 are built or waived before cutover | P11-G1, P11-G2 |
| P11R L253 | G6, OI-1, OI-2 and OI-3 are decided and linked | P11-G6, P11-OI-1, P11-OI-2, P11-OI-3 |
| P11R L255 | I2 is fixed before cutover | P11-I2 |
| P11R L256 | A failing row is a defect with the build number | Rule 3 (§2) |
| P11R L257–258 | Phase 11 parity rows to `Verified` only after their rows pass | Rule 4 (§2) |

P11R L254 (OI-4, already checked) is in §8.

## 21. Source items with no device row

These deferred items could not be placed on a device row. Each is listed with the reason,
so none is silently dropped.

| Source | Item | Reason |
|---|---|---|
| RM L779–780; PM L54 | Withdrawal of an undecided live estimate approval link | Remaining implementation, not only proof: no native code path withdraws a link (no match for "withdraw" in the approval-link code at `1c6859a`). It needs a build decision (a defect or a 12.00b-class task) before a device row can exist |
| RM L904–906; PM L59, L60 | Profitability aggregation (the Money-tab aggregate and expense linking) | Remaining implementation: PM L60 says the Money-tab aggregate and expense linking "remain open". A device row follows the build |
| RM L930–932 | Time-tracking aggregate reporting | Remaining implementation: RM L930–932 lists aggregate reporting as remaining beside the device proof (the proof is Q11-P12-8) |
| PM L50 | Dedicated quick-action destinations and recurring-job navigation from the Jobs list | Listed as remaining work, not as deferred proof. The recurring-job manager navigation that exists is exercised by P6-15 |
| PM L52 | Complete validation, conflict handling, recurrence editing and undo in the job editor | Listed as remaining work, not as deferred proof |
| PM L53 | Pricing-calculator history warnings and exhaustive UI parity | Listed as remaining work; the device proof in the same sentence is P6-3 |
| RM L948 | Phase 6 exit: estimate and change-order totals match golden documents | A host criterion (golden-document tests). The device PDF comparison is P6-5 |
| RM L656 | Phase 5 exit: customer rollups match production fixtures | A host criterion (fixture tests) |
| RM L996 | Phase 8 exit: availability parity fixtures match | A host criterion (fixture tests) |
| P8C L465 (C16) | Old-RN post-adoption rotation without an update | Blocked by design (L1): the payload cannot be told apart. Accepted as inert-safe with a prompt; there is nothing to observe on a device |
| P8C L466 (C17) | Proof-less legacy resolve verification | Blocked by design (L2): an accepted compatibility gap |

## 22. Parity matrix rows and the index rows that feed them

Every row of the parity matrix (PM L28–149, 82 rows) is listed. "Feeds" means the index
rows whose evidence the parity row needs. Passing them is necessary for `Verified`, not
sufficient: the matrix's own evidence list (PM L151 onward) still applies, and this index
never marks a parity row `Verified` (§2 rule 4). A status marked "(stale?)" reads
`Prototype` or `Not started` although later phases implemented the surface; 12.03 does not
change the matrix.

| PM line | Parity row | PM status | Feeds from this index | Note |
|---|---|---|---|---|
| L28 | Auth | In progress | P3-A2 to P3-A6, P3-A8 | A1, A7 passed (§8) |
| L29 | Onboarding | In progress | P3-O2, P3-O3 | O1 passed (§8) |
| L30 | Paywall | In progress | P3-S1 to P3-S3, P3-S5 to P3-S7, Q11-P12-4 | S4 passed (§8) |
| L31 | Starting point | In progress | P3-O4, P3-O5 | |
| L32 | Root gate | In progress | P2-P1, P3-O2 to P3-O5 | |
| L33 | Account lifecycle | In progress | P3-D2 to P3-D5, EXT-3 | D1 passed (§8) |
| L39 | Today | Prototype (stale?) | P10-1 to P10-5, P10-7, P5-8 | Phase 10 implemented Today |
| L40 | Calendar | Prototype (stale?) | P8-1 to P8-3, P8-6, P8-7, P8-10 | P8-CODE |
| L41 | Route | Not started (stale?) | P8-4, P8-1 | P8-CODE |
| L42 | Global search | In progress | P5-7 | |
| L43 | Setup checklist | In progress | P10-8 to P10-12 | |
| L44 | Proactive insights | In progress | P10-13 to P10-17 | Gates P10-GATE-1 |
| L50 | Jobs list | In progress | P6-1, P5-6, P5-8 | Unplaced part in §21 |
| L51 | Job detail | In progress | P6-2 | |
| L52 | Add/edit/duplicate job | In progress | P6-1, P6-2 | Unplaced part in §21 |
| L53 | Pricing calculator | In progress | P6-3 | Unplaced part in §21 |
| L54 | Send estimate | In progress | P6-4 to P6-9 | BE-DEPLOY; unplaced part in §21 |
| L55 | Estimate follow-up | In progress | P6-10 | |
| L56 | Change orders | In progress | P6-11, P6-12 | |
| L57 | Create invoice from job | In progress | P6-13 | |
| L58 | Recurring jobs | In progress | P6-15, SYNC-1 | |
| L59 | Time tracking | In progress | Q11-P12-8, JT-1 to JT-5 | Aggregation unplaced (§21) |
| L60 | Job profitability | In progress | P6-14 | Aggregate unplaced (§21) |
| L61 | Job photos | In progress | P4-P1 to P4-P8, P8-12 | |
| L62 | Appointment messages | In progress | P6-16, SIRI-4 | |
| L63 | Review request action | In progress | P6-17 | |
| L69 | Invoice list | In progress | P7-1, P7-21, P5-8 | |
| L70 | Invoice detail | In progress | P7-4, P7-8, P7-18 | |
| L71 | Add/edit invoice | In progress | P7-2, P7-3 | |
| L72 | Payment ledger | In progress | P7-3, P7-7, P7-9, P7-10 | |
| L73 | Outreach | In progress | P7-19, P7-20, P7-22 | |
| L74 | PDF generation | In progress | P7-16, P7-17, Q11-P12-5 | |
| L75 | Stripe payment links | In progress | P7-11 to P7-15 | STRIPE-TEST |
| L76 | Recurring invoices | In progress | P7-24, P7-25, Q11-P12-7 (= P7-23), P7-30, SYNC-1 | |
| L77 | Auto invoice | In progress | P7-26 to P7-29 | |
| L83 | Customer list | In progress | P5-1 | |
| L84 | Customer detail | In progress | P5-2, P5-3, P5-6 | |
| L85 | Add/edit customer | In progress | P5-4 | |
| L86 | Customer merge | In progress | P5-5 | |
| L87 | Customer portal | Not started (stale?) | P8-5, P8-9, P8-15 | P8-CODE, BE-DEPLOY |
| L88 | Portal content | Not started (stale?) | P8-11 to P8-14 | P8-CODE, HOSTED |
| L89 | Portal requests | Not started (stale?) | P8-11, P10-4 | P8-CODE, HOSTED |
| L95 | Money overview | In progress | P9-1 to P9-5, P5-8 | |
| L96 | Expenses | In progress | P9-8 to P9-14, P9-19 | |
| L97 | Mileage log/add trip | In progress | P9-20 to P9-25 | |
| L98 | Pricebook | In progress | P9-26 to P9-32 | |
| L99 | Tax set-aside | In progress | P9-7 | The G2 editor row is appended by 12.00b.3 (§23) |
| L100 | CSV import | In progress | P9-39 to P9-48, P9-51, P9-52 | |
| L101 | CSV export | In progress | P9-33 to P9-35, P9-37, P9-38, P9-50 | |
| L102 | Accountant package | In progress | P9-36 | |
| L103 | Receipt OCR | In progress | P9-15 to P9-18 | |
| L109 | AI coach | In progress | P10-18 to P10-22 | Gate P10-GATE-2 |
| L110 | Quick prompts | In progress | P10-23 to P10-25 | |
| L111 | Insight handoff | In progress | P10-26 to P10-28 | |
| L117 | Settings hub | Prototype | None | No source defers a device check for this surface |
| L118 | Business profile | Prototype | None | As L117 |
| L119 | Schedule | Prototype | None | As L117 |
| L120 | Pricing defaults | Prototype | P10-12 (the `rate` task on leaving the screen) | Only that behavior has a deferred check |
| L121 | Invoice numbering | Prototype | None | As L117 |
| L122 | Import data | In progress | P9-39 to P9-48; P2-P2 to P2-P8 (legacy RN data import) | |
| L123 | Payments | Prototype (stale?) | P7-11, P7-12, P7-14 | Phase 7 implemented Stripe and non-Stripe providers |
| L124 | Booking link | Prototype (stale?) | P8-5, P8-8, P8-9, P8-15 | P8-CODE, BE-DEPLOY |
| L125 | Appearance | Prototype | None | As L117 |
| L126 | AI Assistant | In progress | AI-1 to AI-5 | |
| L127 | Notifications (settings) | In progress | P10-11, P10-29 to P10-40, P6-10 | |
| L128 | Review requests (settings) | Prototype | None | As L117 (P6-17 covers the review request action, not these settings) |
| L129 | Subscription | In progress | P3-S1 to P3-S3, P3-S5 to P3-S7, Q11-P12-4 | |
| L130 | Account | In progress | P3-D2 to P3-D5, EXT-3 | |
| L136 | Local persistence | Blocked | P2-P1 to P2-P8 | |
| L137 | AsyncStorage upgrade | Blocked | P2-P2 to P2-P8, P2-RB, Q11-P12-6, PERF-5 | G6 |
| L138 | Supabase sync | In progress | P4-B1 to P4-B5, P4-C1 to P4-C7, P5-5, SYNC-1, SOAK-1 to SOAK-6, PERF-6, PERF-7 | P11-I2, P11-OI-3 |
| L139 | Notifications (platform) | In progress | P10-29 to P10-40, P6-10, P6-16, P6-17, P7-30 | |
| L140 | Background refresh | In progress | P4-B1 to P4-B5, P10-42, P10-43 | Gates P10-GATE-3, P10-GATE-4 |
| L141 | Deep links | In progress | DL-1 to DL-6, P10-36, P10-51 | |
| L142 | WidgetKit | In progress | EXT-1 to EXT-3, NJ-1 to NJ-3, JT-1 to JT-5, OWN-1 to OWN-3, Q11-P12-1, Q11-P12-2, Q11-P12-8 | |
| L143 | App Intents/Siri | In progress | SIRI-1 to SIRI-6, Q11-P12-3, Q11-P12-8 | |
| L144 | Analytics | In progress | AN-1 to AN-6, Q11-P12-4, P10-16, P10-28 | |
| L145 | Crash reporting | In progress | CR-1 to CR-9, PERF-9 | P11-OI-2 |
| L146 | Accessibility | In progress | A11-VO-1 to A11B-FR1-2 (the 23 rows of the P11 accessibility table), P8-2 | |
| L147 | iPad layout and multitasking | In progress | IPAD-L-1 to IPAD-AX-1 (the 11 rows of the P11 iPad table), SOAK-5, P8-1 | |
| L148 | Privacy manifests | In progress | EXT-4, PRIV-1 | P11-OI-1 |
| L149 | Release migration | Not started | PERF-1 to PERF-10, Q11-P12-1 to Q11-P12-8, P2-RB, P12-G1-1 | Also the rows 12.05 and 12.06 append (§23) |

## 23. Appended by later Phase 12 tasks

Later Phase 12 tasks add their own device rows here, in the same columns, and update §6
and §7. The expected additions: 12.00b (the G2 tax-settings editor from 12.00b.3, and any
device row of 12.00b.1, 12.00b.2 or 12.00b.4), 12.02 (monitoring and dry-run checks that
need a device or TestFlight) and 12.06 (the rollback rehearsal on TestFlight). An
appended row follows the rules in §2.

| ID | Requirement | Steps | Expected result | Env / build | Stage | Prereqs | Source | Evidence |
|---|---|---|---|---|---|---|---|---|

## 24. Stage run records

Each stage task appends one record per run: date, build number, devices and OS, accounts
(aliases), environment, the rows run with their results, defects raised (`P12-…`) and any
row moved from Stage A to Stage B with the owner's log entry (charter §4.3).

### Stage A (12.04)

No run recorded yet.

### Stage B (12.05)

No run recorded yet.

### Stage C (12.07)

No run recorded yet.
