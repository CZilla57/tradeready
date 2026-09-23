# Phase 7 Device Runsheet (scheduled for Phase 12)

Per the 2026-09-16 deferral decision, physical-device + isolated-staging rows below are **scheduled work for Phase 12 TestFlight/beta**, not per-phase gates. Host evidence (focused suites, aggregate suite, Release build) gates code-complete; rows here gate `Verified`.

Conventions: `[ ]` open, `[x]` passed with evidence link/date. Record device model, iOS version, account type, build ID per row.

## Invoice list / editor / detail (device)

- [ ] Invoice filters, search, stats, ordering on device (light/dark, large Dynamic Type)
- [ ] Create/edit invoice on device; invalid draft retains input; failed save retains draft
- [ ] Concurrent edit vs sync payment on device — payment retained
- [ ] Missing-record state (invoice deleted on another device while open)
- [ ] Pull-to-refresh against staging; offline retains local content via sync banner
- [ ] Delete + 8s undo on device; in-flight queue reconciliation

## Payments (device + staging)

- [ ] Record partial / settle / overpay / void on device; ledger matches RN fixtures
- [ ] Linked job advances on settle; void does not regress per policy
- [ ] Two-device payment convergence (staging): concurrent payments merge, no duplicate, no lost update
- [ ] Offline payment queue replay on reconnect (staging)

## Providers / Stripe (device + staging)

- [ ] Stripe Connect onboarding via system browser → foreground refresh → connected state (StoreKit sandbox / TestFlight)
- [ ] Disconnect → links stop; reconnect resumes
- [ ] Payment-link mint for full balance + deposit amounts; stale-link-after-partial-payment recheck on device
- [ ] Non-Stripe providers (Square/PayPal/Venmo/custom) produce shareable links; placeholder never presented as usable
- [ ] Webhook end-to-end (staging): customer pays link → invoice marked paid; opening success page alone marks nothing

## PDF (device)

- [ ] Invoice PDF share on device; visual comparison vs golden HTML PDFs (unpaid/partial/paid/overpaid/legacy/no-lines/long)
- [ ] Long invoice paginates; totals/history readable; missing logo omits only logo
- [ ] Email compose with PDF attachment on device; failure shows "PDF not attached" path without blocking send

## Outreach / bulk (device)

- [ ] Email + SMS composers on device: sent/cancelled/saved-draft/failed per outcome matrix
- [ ] Copy + regenerate (deterministic, offline-capable); AI route only with key/proxy, fallback otherwise
- [ ] Bulk settle confirm + sequential reviewed reminders; skip summary; cancel between messages
- [ ] No double-send: manual compose vs auto-sweep race on staging leaves exactly one customer email

## Recurring invoices (device + staging)

- [ ] Rule CRUD + pause/resume/cancel/delete on device; generated invoices preserved
- [ ] Generation on foreground after sync; catch-up + numbering + due dates match fixtures
- [ ] Simultaneous two-device generation (staging, BLOCKING per spec): same occurrence → no double-bill; document outcome
- [ ] Auto-send selection: only newest occurrence, gated by rule + master + plausible email; backlog never emailed

## Auto email / reminders / notifications (device + staging)

- [ ] Auto-email sweep end-to-end on staging: stamp → link/PDF prep → claim → send → log; 7-day stale exclusion; import exclusion
- [ ] Reminder sweep: overdue rules fire; imported + pre-completion deposit invoices never emailed
- [ ] Daily caps + claim-before-send: second sweep does not resend
- [ ] Local notifications on device: `inv_`/`rinv_` at 9am local; tap routes to review; paid/deleted/account-change cleanup; 60-cap with unrelated families preserved

## Exit checklist for Phase 12

- [ ] All rows above have device/staging evidence or explicit waivers
- [ ] No unresolved severity-1/2 defects
- [ ] Parity matrix Phase 7 rows advanced to `Verified` only after this sheet passes
