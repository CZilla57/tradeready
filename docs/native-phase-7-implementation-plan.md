# Phase 7 Implementation Plan (cheaper-agent execution)

Spec: `docs/native-phase-7-invoices-payments-spec.md`. Device rows: `docs/native-phase-7-device-runsheet.md`.
Roadmap section: `docs/native-ios-migration-roadmap.md` Phase 7 (L863-885).

## Rules every task follows

1. One task per agent session. Return: files changed, acceptance cases, commands + actual results, blockers, next task ID.
2. Reuse canonical models, `PaymentLedger`, repository transactions, owner verification, mutation queue, native composers.
3. Resolve current canonical records by stable ID at mutation time. Merge only owned fields. Preserve unknown fields + concurrent payment/server state. Success only after durable persistence.
4. Async: capture owner + request identity, recheck after suspension, discard stale results. Financial/provider logic out of SwiftUI views.
5. If a test exposes backend/cross-client idempotency gap: document exact failing case, stop dependent automation at gate. Do not weaken test or invent financial-data migration. (Owner-confirmed blocking rule.)
6. No commit/deploy unless requested.

## Task table

| Task | Scope | Reference files | Completion check |
|---|---|---|---|
| 7.00 Freeze contracts | This spec + plan + runsheet; fixture/acceptance index; note stale "Phases 6–12: Not started" roadmap summary without marking unfinished work complete; launch 7.16 characterization probes | Roadmap, parity matrix, RN screens | Every requirement mapped to source, test, task |
| 7.01 Invoice projections | Pure `Domain/NativeInvoiceList.swift` + detail projection | `utils/invoiceStats.ts`, `invoiceHelpers.ts`, `screens/InvoicesScreen.tsx` | Stats, status precedence, search, counts, ordering fixtures |
| 7.02 Canonical invoice editor | `Domain/NativeInvoiceEditing.swift`; field-scoped commits, typed results | `AddInvoiceScreen.tsx`, `UIModelAdapters.swift`, `AppStore.swift` | Concurrent payment retained; failure keeps draft; customer/number resolution |
| 7.03 Payment transactions | Atomic invoice + job commit; stable IDs; legacy/void/overpay | `invoicePayments.ts`, `FinancialDomain.swift`, AppStore payment methods | All ledger cases; no silent job-regress on void |
| 7.04 Complete invoice screens | Wire list/editor/detail/history/linked-job/missing-record in `InvoicesView.swift` | `InvoicesView.swift`, Phase 5 shared components | Every action works; no unconditional dismiss |
| 7.05 Provider/link policy | Pure `Domain/NativeInvoicePaymentLinks.swift` | `invoiceHelpers.ts`, `paymentLink.test.js`, `NativeInvoiceDelivery.swift` | Deposit clamp, stale-cache rejection, provider switch, Square legacy rejection |
| 7.06 Stripe + provider settings | `NativeStripeConnect.swift` + settings UI; link orchestration | `SettingsPaymentsScreen.tsx`, Workers stripe routes | Mocked status/onboarding/disconnect, foreground refresh, 429, owner-change |
| 7.07 PDF content contract | Expand frozen invoice document model | `pdfTemplates.ts`, `invoicePdfIssueDate.test.js`, `pdfTemplates.test.js` | All fields + financial branches match fixtures |
| 7.08 PDF rendering/export | Wrapping, pagination, logo, share lifecycle, compose attachment | Invoice/estimate PDF implementations | Long docs, file lifetime, cleanup, estimate regression |
| 7.09 Outreach policy | `Domain/NativeInvoiceOutreach.swift`; deterministic copy, outcome policy | `OutreachScreen.tsx`, `invoiceHelpers.ts`, `messaging.ts` | Partial/deposit copy, per-channel edits, outcome/suppression matrix |
| 7.10 Outreach UI + AI | `NativeInvoiceOutreachView.swift`; composers, copy/regenerate, one-shot AI | `oneShotAI.ts`, `emailHtml.ts`, native composers | Offline fallback, stale-result rejection, no duplicate composer |
| 7.11 Bulk operations | Selection, canonical bulk settle, sequential reminders | `bulkInvoiceActions.ts`, `InvoicesScreen.tsx` | Mixed eligible/skipped, cancel, rechecks, atomic settle |
| 7.12 Recurring generation | `Domain/NativeRecurringInvoices.swift` + atomic coordinator | `recurringInvoices.ts`, `recurringAutoSend.ts`, `NativeRecurringJobs.swift` | Catch-up, resume, ends, ID/numbering, dedupe fixtures |
| 7.13 Recurring management UI | Rule list/editor + auto-send confirmation/settings | Both RN recurring-invoice screens | CRUD/pause/resume/cancel/delete preserve generated invoices |
| 7.14 Auto preparation/recovery | Owner-bound resumable orchestration replacing fire-and-forget | `AppStore.deliverNativeInvoice`, `autoInvoice.ts`, backend selectors/senders | Relaunch/offline recovery, stale balance, import exclusion, gates |
| 7.15 Invoice notifications | `NativeInvoiceNotifications.swift` + shared scheduling + tap routing | `notifications.ts`, native coordinators | Namespaces, cap, dates/DST, permissions, owner change, tap validation |
| 7.16 Cross-client/backend qual | Webhook/payment merge, recurring race, manual/auto race, claim idempotency | Webhook/senders, payment SQL, mixed-client suites | Evidence per race; failures block dependents |
| 7.17 Closeout | Aggregate tests, Release build, parity + runsheet updates | Runners + docs | Code-complete evidence + deferred rows listed for Phase 12 |

## Dependency order

```text
7.00 → 7.01 → 7.02 → 7.03 → 7.04
7.04 → 7.05 → 7.06
7.04 → 7.07 → 7.08
7.06 + 7.08 → 7.09 → 7.10 → 7.11
7.03 → 7.12 → 7.13
7.06 + 7.08 + 7.09 + 7.12 → 7.14
7.13 + 7.14 → 7.15 → 7.16 → 7.17
```

Run 7.16 probes during 7.00 as characterization.

## Verification

Focused suites (standalone `swiftc` harness): invoice list/editing, payment transactions, link policy, Stripe transport, PDF contract, outreach policy, bulk, recurring, notification scheduling, delivery recovery.

Oracles:
- `invoicePayments.test.js`, `invoicePaymentsLegacyEquivalence.test.js`, `paymentMathParity.test.js`
- `invoiceStats.test.js`, `paymentLink.test.js`, `bulkInvoiceActions.test.ts`
- `recurringInvoices.test.ts`, `recurringAutoSend.test.ts`
- `pdfTemplates.test.js`, `invoiceEmailHardening.test.js`
- `selectInvoicesToAutoEmail.test.js`, `selectInvoicesToRemind.test.js`, `stripeWebhookOwnership.test.js`

```sh
npm test -- --runInBand --runTestsByPath __tests__/invoicePayments.test.js __tests__/invoicePaymentsLegacyEquivalence.test.js __tests__/paymentMathParity.test.js
sh native/run-all-domain-tests.sh
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Unsigned vs signed builds recorded separately.

## Adversarial cases

Webhook-during-edit; payment-change-during-link-mint; account-change during PDF/Stripe; save-failure after payment submit; double settle; generation interrupted pre/post commit; two clients same occurrence; composer vs auto sweep; imported invoice with stale stamp; notification for paid/deleted/prior-account invoice.

## Handoff prompt (per task)

> Implement only task **7.XX** above. Read listed refs + existing focused tests first. Reuse canonical models, financial rules, repo transactions, owner verification, mutation queue, native composers. Resolve by stable ID at mutation time; merge owned fields only; preserve unknown + concurrent server state; success after durable save. Capture owner/request identity across async; discard stale. Keep financial/provider decisions out of views. Add fixture tests, run focused checks, compile when UI/platform changes. Backend/cross-client gap → document exact case, gate dependents, no test-weakening or financial migration. Return files, results, blockers, next task ID. No commit/deploy unless asked.
