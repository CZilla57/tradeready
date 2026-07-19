# TradeReady — Pre-Release Checklist

Run this before **any** build that reaches users — an EAS build submitted to a
store, or an OTA update via `eas update`. It takes a couple of minutes.

It exists because this repo has long-lived feature branches whose client-side
changes go live the moment *any* build ships off `master`, including a build
made for an unrelated reason. A hotfix for something else can carry a dormant
feature's data-layer change into production with it. That is not hypothetical —
see the deposits entry below.

Written 2026-07-18.

---

## Every release

- [ ] **`npm run typecheck && npm test && npm run lint`** — all three clean. Lint
      runs with `--max-warnings=0`; a warning is a failure.
- [ ] **Check the blocked-features list below.** If any entry is still unresolved
      and its code is merged to `master`, you cannot ship — resolve it or revert
      the merge first.
- [ ] **Know what changed in the data layer.** `git log --oneline <last-release>..HEAD -- utils/storage/ utils/sync.ts utils/syncMerge.ts types/models.ts`.
      Anything here changes what gets written to users' devices and to Supabase.
      An empty result is a good sign; a non-empty one deserves a read.
- [ ] **Backend and app agree.** If this release depends on a Vercel deployment or
      a Supabase migration, confirm both are live *first*. Shipping a client that
      expects a backend it does not have is worse than shipping neither.

---

## Blocked features — do not ship while any of these is unresolved

### Deposits & partial payments — BLOCKED as of 2026-07-18

**Branch:** `feat/deposits-partial-payments` (unmerged at time of writing).

**Why it blocks a release once merged:** the client half is live code, not
dormant. `pullRemote` routes invoice records through a payment-ledger merge
(`utils/sync.ts` → `utils/syncMerge.ts`), so any build off a `master` that
contains this branch will start deriving and writing `payments` arrays on
users' devices and pushing them to Supabase — whether or not the feature's UI
is reachable, and whether or not that build was made for this feature.

**The blocking dependency:** the Supabase migration
`supabase/migrations/20260718_invoice_payment_merge.sql` is **written but not
applied**, and the Vercel backend is **not deployed**. The currently deployed
Stripe webhook writes a bare `paid: true` with no ledger entry, which the
ledger merge discards — erasing a real customer payment on any invoice that
carries a recorded payment.

**To unblock,** work through `docs/deposits-resume-here.md` §4 in order. The
ordering is load-bearing: **never deploy the backend before applying the
migration.** Then delete this entry.

**Also note:** the Postgres trigger has never executed against a real database,
and the `invoices` table's `id` column type is inferred rather than confirmed.
Run `\d public.invoices` before applying.

---

## Adding an entry here

Add one whenever a merged-but-unshippable change lands on `master`. An entry
needs three things: **what** is blocked, **why shipping it would hurt**, and
**what specifically unblocks it**. Delete the entry the moment it is resolved —
a checklist full of stale entries stops being read, which defeats it.
