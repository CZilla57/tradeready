# Deposits & Partial Payments — Design

**Date:** 2026-07-18
**Branch:** `feat/deposits-partial-payments` (off `master` @ 78383e3)
**Roadmap:** Phase 3 of `docs/post-launch-feature-roadmap.md`
**Status:** design approved, implementation not started

## Problem

Invoices are all-or-nothing. `Invoice.paid` is a boolean; a payment link is
always for the full amount. Solo trades routinely take a deposit before
starting work ("50% up front, balance on completion") and get paid in cash or
cheque part-way through a job. Today the app cannot represent either, which
is a named churn reason toward Jobber and Housecall Pro.

A related honesty problem: the Outreach screen already has an "Offer a
payment plan" toggle backed by `PaymentPlan` (`types/models.ts:253`). It only
splices a sentence into the reminder message ("We can also arrange 3 payments
of $333 monthly"). Nothing is tracked, no links are generated, nothing is
persisted. The app promises something it cannot honour. This feature makes it
real.

## Scope

**In scope**
- A payment ledger on the invoice: any number of partial payments, each with
  its own amount, date and method.
- Requesting a deposit at send time, as a percentage or a fixed amount, and
  generating a Stripe payment link for that partial amount.
- Recording non-Stripe payments manually (cash, cheque, card, other).
- Reconciling Stripe partials automatically via the Connect webhook.
- Counting collected revenue on the date each payment was received.
- Showing paid-to-date and balance-due everywhere an invoice amount appears.

**Out of scope**
- Scheduled or automatic installment plans (recurring-billing infrastructure;
  roadmap #6). The existing payment-plan toggle stays a message affordance —
  it merely stops misreporting what has been paid.
- Partial-payment support for non-Stripe processors beyond manual recording.
  PayPal.Me, Venmo, Square and Custom URL links stay client-built and are
  reconciled by hand, as they are today.
- Refunds and negative payments.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Workflow | Full progress billing — deposit request plus ad-hoc partials | Covers deposit-before-work and pay-as-you-go without two mechanisms |
| Deposit input | Percentage or fixed amount, chosen at send time | No settings-level policy to maintain; matches how trades actually quote |
| Recording | Stripe webhook plus a manual "Record payment" sheet | Trades take a lot of cash and cheques; Stripe-only would cover a minority of payments |
| Revenue timing | Each payment counts on its own date | Cash-basis and truthful. A $500 deposit today is $500 collected today |
| Model | Payment ledger on the invoice (`Invoice.payments[]`) | See "Approaches considered" |
| Money-tab sweep | All read sites converted in one phase | No interim state where two cards disagree |
| Deleting a payment | Allowed, behind a confirm dialog | Correcting a mistyped cash entry must be possible; the confirm names the consequence |

### Approaches considered

**A — Payment ledger on the invoice (chosen).** `Invoice.payments?: Payment[]`
plus a derivations module. Migration-free: absent on every existing invoice,
and a legacy `paid: true` invoice derives as a single implicit payment of the
full amount. Fits the existing JSON-blob sync (no backend migration).

**B — A separate `payments` Supabase table.** Relationally cleaner, and
append-only rows sidestep the last-write-wins hazard naturally. Rejected: it
costs a seventh synced table with its own RLS policy, sync-queue wiring and a
migration, and every read site would need a join the local-first layer does
not perform. Disproportionate for a solo-operator app.

**C — A scalar `amountPaid` field.** Cheapest. Rejected: it loses payment
dates, which defeats the per-payment revenue-timing decision, and gives no
key on which to dedupe repeated Stripe webhook deliveries.

## Data model

Added to `types/models.ts`:

```ts
export type PaymentMethod = 'stripe' | 'cash' | 'check' | 'card' | 'other';

export interface Payment {
  id: string;              // `p<ts>_<n>` locally; `stripe_<session_id>` from the webhook
  amount: number;
  date: DateString;        // "YYYY-MM-DD" — the date money was received
  method: PaymentMethod;
  note?: string;
  /** Present only on webhook-created payments; doubles as the idempotency key. */
  stripeSessionId?: string;
}

export interface DepositRequest {
  amount: number;          // the resolved dollar amount
  percent?: number;        // set when the user chose a percentage
  requestedAt: DateString;
}
```

Two optional fields on `Invoice`:

- `payments?: Payment[]` — the ledger. Absent on every pre-existing invoice.
- `depositRequest?: DepositRequest` — what was asked for up front, so the UI
  can show "Deposit requested: $500 — unpaid" and regenerate the same link.

`paid: boolean` **stays**, now maintained as `balanceDue(inv) <= 0.005`. It
remains the field read by the PDF template, the backend reminder selector and
any client running older code. There is no migration and no backfill.

Locally-generated payment ids follow the `newCustomerId()` precedent
(`utils/storage/customers.ts`): timestamp plus a counter, so same-millisecond
entries cannot collide.

## Derivations — `utils/invoicePayments.ts` (new)

One module owns all payment math. No screen or analytics helper sums a
ledger by hand.

```ts
amountPaid(inv): number
  // inv.payments?.length ? sum(payments) : (inv.paid ? inv.amount : 0)

balanceDue(inv): number          // max(0, inv.amount - amountPaid(inv))
isPartlyPaid(inv): boolean       // amountPaid > PAID_EPSILON && !isFullyPaid(inv)
isFullyPaid(inv): boolean        // balanceDue <= 0.005
paymentsInRange(inv, start, end): Payment[]
collectedInRange(invoices, start, end): number
```

The legacy fallback inside `amountPaid` is what makes the change
migration-free. An old `paid: true` invoice reads as one implicit payment of
the full amount dated `paidAt || due` — exactly the bucketing every current
Money-tab site already applies. Converted analytics therefore return
identical numbers on legacy data, which is also how the Phase 4 sweep is
proven behaviour-neutral.

All balance comparisons use a `<= 0.005` epsilon. Never compare a derived
balance to zero with `===`.

`getStatus` (`utils/invoiceHelpers.ts:22`) gains one branch, placed **after**
the paid check but **before** the not-yet-due branch, and gated on
`days <= 0`: a partly-paid invoice that is not past due renders
`{ label: "Partly paid", color: "accent" }` with the balance alongside. A
partly-paid invoice that *is* past due keeps its `Nd overdue` label and
warning/danger colour — partial payment does not clear an overdue state, and
the overdue signal is the more urgent of the two. The balance is still shown
next to the badge in that case, so no information is lost.

`isOverdue` (`utils/invoiceStats.ts:25`) correspondingly becomes
`!isFullyPaid(inv) && daysPastDue(inv.due) > 0`, which preserves its current
result on every legacy invoice.

## Sync and webhook

This is the highest-risk area of the feature and the reason Phase 2 lands
before anything can write a payment.

### The hazard

`pullRemote` (`utils/sync.ts:158`) replaces whole records: `local[idx] =
remote.data`. `pushQueue` runs before it. Today that is harmless, because
`paid` is an idempotent boolean — whichever side wins, the result is the
same. With a ledger it is not: if the Stripe webhook appends a payment while
the device edits the same invoice, the device's push overwrites the record
and the payment is destroyed silently.

### The fix

Replace the assignment with a `mergeRemoteRecord(table, localRecord,
remoteRecord)` helper. For every table except `invoices` it performs the
current replace, preserving existing behaviour exactly. For `invoices` it
replaces scalar fields with the remote values, then unions `payments` by `id`
across both sides, then recomputes `paid` and `paidAt` from the merged
ledger.

Union of two sets keyed by a deterministic id is commutative and idempotent,
so arrival order does not matter and a duplicate delivery cannot double-count
even if it races a device push. Webhook payments use `stripe_<session_id>`;
device payments use the local counter id. The two id spaces cannot collide.

This is a deliberate, documented exception to the JSON-blob replace rule in
`tradeready-architecture-contract` §1, confined to one field on one table.
The exception must be noted in that skill when the feature lands.

### Webhook changes — `backend/api/stripe/webhook.js`

- Read the amount from `session.amount_total / 100` rather than assuming the
  full invoice amount.
- Replace the `if (data?.paid) return` dedupe guard (line 109) with a check on
  the ledger: skip if `data.payments?.some(p => p.stripeSessionId ===
  session.id)`. Retain the `data.paid` fast path for legacy full-amount links,
  which carry no ledger.
- Append the payment, recompute `paid` and set `paidAt` to the date of the
  payment that closed the balance, then upsert as today.
- All other guards unchanged: signature verification, `payment_status ===
  'paid'`, `metadata.invoiceId` present, invoice-not-yet-synced returns 200
  without a retry.

`backend/api/create-payment-link.js` accepts the requested partial amount in
the request body instead of deriving it from the invoice.

## UI surfaces

### Invoice row and detail modal — `screens/InvoicesScreen.tsx`

When an invoice is partly paid, the amount line becomes balance-forward:
`$500 due · $500 paid`, with a "Partly paid" badge.

"Mark paid" stays in place and keeps its one-tap meaning; it now records a
single payment for the remaining balance with method `other`. Muscle memory
is preserved.

A new secondary action, **"Record payment"**, opens a sheet: amount
(pre-filled with the current balance), date (via the shared
`DateTimePickerSheet`), method chips, optional note.

The detail modal gains a payment-history list — `date · method · amount` per
entry. Long-press deletes an entry behind a confirm dialog. Deleting the
payment that closed an invoice flips it from Paid back to Partly paid, and
the confirm dialog says so explicitly. Because the change syncs, another
device will see the same regression; this is correct and intended.

### Outreach screen — `screens/OutreachScreen.tsx`

Above the payment-link block, a segmented control: `Full balance | 50% deposit
| Custom`. Custom takes either a percentage or a dollar amount in one field,
with a `%` suffix toggle deciding the interpretation. The selection writes
`depositRequest` onto the invoice and drives the payment-link amount.

`buildGenericMessage` (`utils/invoiceHelpers.ts:132`) currently hardcodes
`formatMoney(invoice.amount)`. It takes the requested amount instead and adds
a balance line when a ledger exists.

The "Offer a payment plan" toggle stays. With a real ledger behind it, the
message can state what has already been paid rather than implying nothing
has.

### Payment-link caching

`resolvePaymentLink` (`utils/invoiceHelpers.ts:69`) caches only while
`paymentLinkAmount === invoice.amount`, so a deposit link would refetch on
every render. It gains an explicit `requestedAmount` parameter and caches
against that value. Callers in `OutreachScreen` pass the deposit amount.

### PDF — `utils/pdfTemplates.ts`

When payments exist, the totals block gains `Paid to date` and `Balance due`
lines plus a compact payment-history table. The `isPaid` watermark logic is
unchanged.

## Phases

Each phase ends with the gate green (`tsc`, tests, lint — zero warnings) and
stops for the owner's go-ahead before the next begins.

| # | Phase | Contents |
|---|---|---|
| 1 | Model and derivations | `Payment`, `PaymentMethod`, `DepositRequest`; `Invoice.payments` / `depositRequest`; `utils/invoicePayments.ts` plus unit tests including legacy equivalence. No UI, no behaviour change. |
| 2 | Sync safety | `mergeRemoteRecord` in `pullRemote`, union-by-id for `payments`, tests for concurrent edit and duplicate delivery. Lands before anything can write a payment. |
| 3 | Recording UI | Record-payment sheet; "Mark paid" rewired to the ledger; payment history with confirm-guarded delete; `getStatus` partly-paid branch; balance-forward invoice rows. |
| 4 | Money-tab conversion | Every read site converted in one sweep: `invoiceStats`, `MoneyScreen`, `ReceivablesCard`, `MonthlyChart`, `TopCustomersCard`, `customerList`, `customerMix`, `invoiceAging`, `seasonalTrends`, `businessSnapshot`, `storage/dailyOps`, `CustomerDetailScreen`, and backend `selectInvoicesToRemind`. Legacy-equivalence tests prove no drift. |
| 5 | Deposit request and Stripe partials | Outreach deposit selector; `resolvePaymentLink` amount parameter; message-builder changes; `create-payment-link` partial amount; webhook rewrite. |
| 6 | PDF and polish | PDF balance and history block; accessibility labels; dark-mode pass; final review. |

Phase 5 is the only phase requiring a backend deploy, and is deliberately
late so that nothing is live until the device side is proven. Phase 4 is the
largest and touches the most existing code; it is kept whole so no two
money surfaces can disagree.

## Testing

Per-phase unit tests, plus three areas that get specific attention because
they are where money is lost:

1. **Legacy equivalence.** A property test over generated legacy invoices
   (no `payments` field, mixed `paid` and `paidAt` states) asserting every
   converted analytics function returns exactly what the pre-change
   implementation returned. This is the safety net for the Phase 4 sweep.
2. **Merge commutativity.** `merge(a,b)` equals `merge(b,a)`, and
   `merge(x,x)` equals `x`, for the payments union. Plus the concrete race:
   the device edits a description while the webhook appends a payment, and
   both survive.
3. **Webhook idempotency.** The same session id delivered twice appends one
   payment. Two different partial payments on one invoice sum correctly and
   flip `paid` only on the second.

Device smoke tests at the end of Phase 5: request a 50% deposit, pay it in
Stripe test mode, background and foreground the app, confirm the invoice
shows Partly paid with the correct balance, then settle the remainder in cash
via Record payment and confirm it flips to Paid.

## Risks and open items

- **Sync merge is a real exception to a load-bearing rule.** It must be
  documented in `tradeready-architecture-contract` and
  `tradeready-storage-and-sync` when it lands, or a future session will
  "simplify" it back to a replace and reintroduce silent payment loss.
- **Deleting a payment can un-pay a synced invoice.** Accepted, behind a
  confirm dialog that names the consequence.
- **Non-Stripe processors gain no automation.** PayPal.Me, Venmo, Square and
  Custom URL partials must be recorded by hand. Unchanged from today, but the
  gap widens visibly once Stripe reconciles automatically.
- **Overdue semantics for partly-paid invoices.** A partly-paid invoice past
  its due date still counts as overdue, including for the backend reminder
  cron. If that proves too aggressive in practice, revisit after real usage
  rather than pre-emptively.
