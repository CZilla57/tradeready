# Phase 7 — Invoices, Payments, and Customer Communication: Spec

**Status:** Active. **Code-complete gate:** invoice-to-payment works locally, business rules match reference fixtures, auto-send protections pass host/backend tests, app builds. **Device/staging proof:** deferred to Phase 12 per 2026-09-16 owner sign-off — still required, not waived.

**Blocking rule (owner-confirmed):** a failing cross-client/backend idempotency case blocks its dependent automation. Do not weaken tests, silently discard financial records, or invent financial-data migrations to unblock.

## Baseline (what exists, what Phase 7 fixes)

| Area | Exists | Phase 7 work |
|---|---|---|
| Financial rules (`PaymentLedger`, legacy equivalence, deposits, settle, voids, numbering) | Yes — `Domain/FinancialDomain.swift`, `Models.swift`, RN oracle `utils/invoicePayments.ts` | Reuse; verify full-workflow integration |
| Invoice UI (`InvoicesView.swift` list/editor/detail/payment sheets) | Basic | Full parity, durable-save feedback, canonical editing |
| Job → invoice (`JobInvoiceDomain.swift`, `commitInvoiceFromJob`) | Manual/deposit/finalize + opt-in auto-create | Delivery + reconciliation integration |
| Payment links (`NativeInvoiceDelivery.swift`) | Authenticated Stripe link + PDF upload transport | Provider settings, Connect onboarding, reviewed amount selection, caching |
| Invoice PDF (`NativeInvoicePDF.swift`) | Frozen doc + single-page renderer | Full template, history, logo, dates, pagination, sharing |
| Auto delivery (`autoEmailRequestedAt` stamp + post-save prep) | Foundation | Owner-safe orchestration, recovery, visibility, duplicate protection |
| Recurring invoices | Canonical models only (`Canonical.RecurringInvoice` stored/synced, never generated) | Generation coordinator, rule management, auto-email gates |
| Notifications | Shared infra + appt/est families | `inv_`/`rinv_` scheduling + routing |

**Concrete defects to fix first:**
1. `InvoiceEditor`/`PaymentEditor` dismiss after `Void`-returning saves — no durable-success signal (`AppStore.upsert/recordPayment/settleInvoice/voidPayment`).
2. `persistInvoiceAndAdvancePaidJobs` (AppStore ~L4848) is invoice-save + N job-saves, not one atomic snapshot (contrast `commitInvoiceFromJob` single-save pattern).
3. Invoice renderer is single-page stacked text; missing production fields (badge, history, logo, terms, pagination).
4. `deliverNativeInvoice` needs owner/session rechecks across suspension + restart-safe prep.
5. Local occurrence-dedup alone does not prove simultaneous two-device generation safety — needs a mixed-client test before calling recurring complete.

## A. Invoice list / create / edit / detail

**List:** All/Unpaid/Overdue/Paid filters; customer-name + invoice-number search; outstanding/overdue-count/collected stats; production ordering, filter counts, stat-card filter taps; paid/partly/due-today/due-soon/overdue labels; bulk selection (remind + settle); existing refresh/empty/error/offline/delete-confirm/undo behavior.
Refs: `screens/InvoicesScreen.tsx`, `utils/invoiceStats.ts`, `utils/invoiceHelpers.ts:getStatus/daysPastDue`.

**Create/edit:** saved-customer pick + free-form create/reconcile; name, number, total, due, email, phone, description; blank number resolves from latest canonical + numbering settings at commit; trim + validate without dismissing invalid drafts; save only editor-owned fields into latest canonical; preserve payments, job/recurrence linkage, delivery metadata, import markers, nested metadata, unknown fields; recalc derived paid state on amount change; deleted/conflicting record → actionable refusal, never silent recreate.
Refs: `screens/AddInvoiceScreen.tsx`, `UIModelAdapters.swift`, `AppStore.swift`.

**Line items:** preserve/display existing canonical items + categories; keep `JobInvoiceDomain` job-generated construction; match RN labor vs additional-charges grouping; keep authoritative total when historical lines don't sum to it. No new standalone line-item authoring system (RN editor is amount-based).

**Detail:** total, collected, balance, overpayment, due, status, contacts, description, line items, payment history, deposit-request state; edit / record payment / settle / outreach / PDF / linked-job nav; missing-record state when invoice disappears while open.

**Acceptance:** edit open while webhook payment lands retains payment. Failed persistence retains draft, published state stays consistent.

## B. Payments, deposits, job reconciliation

Reuse `PaymentLedger` + lifecycle rules. Record positive payments (date/method/note); allow explicit overpayment display; settle latest remaining balance only; one stable payment ID per submitted operation (retries reuse); retain voided entries + timestamps; match synthesized legacy behavior incl. legacy voiding; preserve absent-ledger vs empty-ledger distinction; recalc `paid`/`paidAt` via payment rules; reconcile linked jobs via existing lifecycle policy (no invented reverse transitions on void); commit invoice + job transitions in **one canonical transaction**; publish via existing mutation queue.

**Deposits:** full balance, 50% of total, custom fixed, custom percent. Clamp to remaining balance with cent rounding. Full-balance request clears prior deposit request. Restore outstanding deposit selection; default to balance once satisfied.
Refs: `utils/invoicePayments.ts`, `FinancialDomain.swift`, `OutreachScreen.tsx` deposit selector.

**Acceptance:** partial, exact settle, overpay, resubmit, void, legacy, amount-edit, concurrent local/webhook. Opening a Stripe success page never marks paid by itself.

## C. Providers + Stripe Connect

**Settings:** Stripe Connect, Square payment-page links, PayPal.Me, Venmo, custom URLs. Retain per-provider values across switches. Reuse secure-settings boundary + legacy provider-value migration.
Refs: `screens/SettingsPaymentsScreen.tsx`, `utils/stripeStatus.ts`.

**Stripe lifecycle** (existing routes, reuse): `GET /api/stripe/connect-status`, `POST /api/stripe/create-connect-account`, `POST /api/stripe/disconnect`, `POST /api/create-payment-link`. States: loading, disconnected, connected-incomplete, connected-submitted, unavailable/retry. Browser open for onboarding URL; foreground-return refresh (return ≠ proof). Copy reflects actual contract: status exposes `details_submitted`, not full charges/payouts capabilities.

**Link policy:** reuse only amount-valid cached link (epsilon compare); force fresh on provider switch; invalidate visible link on amount change; reject legacy Square credential links (`squareup.com/pay/`); never present placeholder URLs as usable; recheck owner/existence/request/financial state post-await; verified-refresh on 401/403; no tight retry on 429; preserve "contact me to pay" draft on mint failure.
Refs: `utils/invoiceHelpers.ts:80-241`, `NativeInvoiceDelivery.swift`.

**Acceptance:** tests prove partial payment or provider switch cannot leave stale link presented as current.

## D. Invoice + estimate documents

Extend `NativeInvoicePDF.swift`; reuse estimate export architecture (`NativeEstimatePDF.swift`, `NativeActivitySheet`).

**Invoice contract:** business name/contacts/separate address/optional logo; customer contacts; number, issue date, due date, status badge; labor + additional-charges grouping; description fallback; total + partial balance block; customer-visible payment history; terms/footer. `invoiceIssueDate` parity (timestamp IDs → issue date; legacy IDs → injected render date). Exclude voided + synthetic `legacy_` entries from customer history (retain internally).
Refs: `utils/pdfTemplates.ts`, `__tests__/pdfTemplates.test.js`, `invoicePdfIssueDate.test.js`.

**Render/export:** freeze before render; wrap long fields; paginate; keep totals/history readable; missing logo omits only logo; sanitized filenames; temp files live through share/compose then clean; sharing never mutates status or implies delivery. Same pass verifies estimate docs (typography, arithmetic, long content, sharing).

**Acceptance goldens:** unpaid, partial, paid, overpaid, legacy, no-lines, long-lines, long-desc, missing-logo, long-address.

## E. Reviewed outreach + bulk

**Individual:** email + text channels, separately retained drafts; editable subject/body; copy + regenerate; provider + deposit selectors; payment-plan wording (installments/frequency); both balance + total in partly-paid copy; auto-reminder status when available; PDF attach for email; missing-contact + unavailable-composer handling. Deterministic templates work offline. Optional AI via existing one-shot contract (user key → backend proxy → deterministic fallback; never throws); ignore late results after account/invoice/channel/draft change.
Refs: `OutreachScreen.tsx`, `invoiceHelpers.ts:243-475`, `messaging.ts`, `oneShotAI.ts`, `emailHtml.ts`.

**Composer outcomes** (typed native results): sent → record outcome + supersede pending auto request; cancelled → preserve draft, no delivery claim; saved Mail draft → explain saved, no delivery claim; failed → preserve + retry; external/unknown → not labeled sent; apply documented conservative auto-suppression policy. Keep delivery evidence separate from duplicate-suppression.

**Bulk:** single confirm; resolve latest selected; settle all applicable + reconcile jobs in one canonical transaction; sequential reviewed reminder composers with per-invoice recheck; skip paid/deleted/unreachable with summary; stop on account change / unavailable composer; cancel between messages; deterministic bulk drafts (no N AI calls).
Refs: `utils/bulkInvoiceActions.ts`, `InvoicesScreen.tsx:222-312`.

**Cooldowns:** preserve backend claim/cap semantics + link rate-limit (10/60s); disable duplicate taps while busy. `resendCooldown.ts` is auth-email only — do not reuse for invoices.

## F. Recurring invoices

**Rule management** (port both RN screens): create/edit; customer, description, amount, due-days terms; cadence + start; never/count/date ends; pause/resume; cancel = deactivate; delete rule preserves generated invoices; rule auto-send opt-in + confirmation copy.
Refs: `RecurringInvoicesScreen.tsx`, `AddRecurringInvoiceScreen.tsx`.

**Generation** (pure planner + atomic coordinator): run after verified workspace + initial sync; serialize overlapping runs; catch-up eligible occurrences; dedupe present occurrences by `(ruleID, occurrence)`; number across full working batch; commit invoices + advanced rules together; due = occurrence + net terms; snapshot customer contacts; keep JS recurrence overflow + date-frame semantics pinned in fixtures; resume skips elapsed paused periods ( unbilled, uncounted); keep generated-ID compat with issue-date extraction.
Refs: `utils/recurringInvoices.ts`, `recurringAutoSend.ts`, `NativeRecurringJobs.swift` (pattern only — jobs back-fill, invoices must not).

**Auto-send selection:** only newest invoice for a rule in that run, and only when rule opted in + master `autoSendRecurringInvoicesEnabled` + plausible customer email. Catch-up backlog never auto-sends.

**Concurrency qualification (BLOCKING):** add simultaneous-generation mixed-client test before calling complete. Local occurrence check alone is insufficient. A failing case stays a backend-compatibility blocker; no silent ID change or financial-record discard as a fix.

## G. Auto email, reminders, notifications

**Auto email:** backend sender stays sender of record. Native persists eligibility/request + prepares link/PDF; runs no second autonomous sender. Resume prep after relaunch/offline. Recheck exact owner + current state before publishing. Independent job-completion vs recurring master switches. Keep 7-day request age, no stamping of pre-existing invoices on opt-in, explicit import exclusion, backend claim-before-send + daily caps (25/user/day) + PDF grace + status semantics. Pending/ambiguous server claim is never retried as unclaimed.
Refs: `AppStore.deliverNativeInvoice`, `autoInvoice.ts`, `selectInvoicesToAutoEmail.js`, `sendInvoiceEmails.js`, `selectInvoicesToRemind.js`, `sendReminders.js`.

Manual-vs-sweep race must be tested. Clearing local request post-compose is not proof an in-flight sweep was cancelled.

**Local notifications:** `inv_<invoiceID>_<days>d`, `rinv_<ruleID>`, invoice-detail payload, `overdue_outreach`, `recurring_invoice`. 9am local; shared 60-request budget + family priority; no imported-invoice or pre-completion deposit dunning; remove obsolete on paid/deleted/paused/disabled/sign-out/denied; preserve unrelated families; validate payload + owner/record on tap; taps open review, never send.
Refs: `utils/notifications.ts`, native appt/est coordinators.

## Requirement → source → test → task index

| Req | RN source | Native target | Oracle tests | Task |
|---|---|---|---|---|
| List/stats/search/filter | InvoicesScreen, invoiceStats, invoiceHelpers | Domain/NativeInvoiceList.swift + InvoicesView | invoiceStats, invoiceHelpers | 7.01, 7.04 |
| Editor canonical commit | AddInvoiceScreen | Domain/NativeInvoiceEditing.swift | invoicePayments (reconcile), store integration | 7.02, 7.04 |
| Payments/deposits/reconcile | invoicePayments.ts | FinancialDomain + AppStore atomic commit | invoicePayments, legacyEquivalence, paymentMathParity | 7.03 |
| Providers/links/Stripe | SettingsPaymentsScreen, invoiceHelpers, Workers stripe/createPaymentLink | Domain/NativeInvoicePaymentLinks + NativeStripeConnect | paymentLink, stripeWebhookOwnership | 7.05, 7.06 |
| PDF | pdfTemplates.ts, invoicePdfFile.ts | NativeInvoicePDF.swift | pdfTemplates, invoicePdfIssueDate, pdfBizHeader | 7.07, 7.08 |
| Outreach/bulk | OutreachScreen, bulkInvoiceActions, messaging, oneShotAI, emailHtml | Domain/NativeInvoiceOutreach + OutreachView | bulkInvoiceActions, invoiceEmailHardening, selectInvoicesToAutoEmail/Remind | 7.09–7.11 |
| Recurring | RecurringInvoicesScreen, AddRecurringInvoiceScreen, recurringInvoices, recurringAutoSend | Domain/NativeRecurringInvoices + coordinator + UI | recurringInvoices, recurringAutoSend, recurrence | 7.12, 7.13 |
| Auto/notifications | autoInvoice.ts, sendInvoiceEmails, sendReminders, notifications.ts | Delivery orchestration + NativeInvoiceNotifications | selectInvoicesToAutoEmail/Remind, recurringAutoSend | 7.14, 7.15 |
| Cross-client/backend | webhook route, payment SQL, mixed-client suites | Qualification gates | stripeWebhookOwnership, two-device model | 7.16 (blocking) |
