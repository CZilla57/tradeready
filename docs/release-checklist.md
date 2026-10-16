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
- [ ] **Backend and app agree.** If this release depends on a Worker deploy
      (`backend-workers/`, `wrangler deploy`) or a Supabase migration, confirm both
      are live *first*. Shipping a client that expects a backend it does not have is
      worse than shipping neither.

---

## Blocked features — do not ship while any of these is unresolved

- [ ] **Quote options (Phase 25, `feat/quote-options`) — apply `supabase/migrations/20261002_job_approval_preserve.sql` first.**
      Without it, a device push queued before it pulled a customer's decision
      erases that decision and the chosen option (`approval.selection`; change
      orders too). Unblocked when `sh supabase/verify/job_approval_preserve.sh`
      passes, the migration is applied in the Supabase SQL editor, and
      `preserve_job_approvals_trg` exists on `public.jobs`; then delete this entry.
- [ ] **Quote options — deploy the Worker and publish the `tradeready-legal` `feat/quote-options` pages before the native build.**
      The live `estimate.html` posts no `selection`, so the Worker refuses an
      approval of an options estimate ("Please choose an option."). Unblocked
      when the Worker and both pages (`estimate.html`, `portal.html`) are live;
      then delete this entry. Order: spec
      `docs/superpowers/specs/2026-10-02-quote-options-design.md` §12.
- [ ] **Job forms (Phase 20, `feat/job-forms`) — apply `supabase/migrations/20261002_forms.sql` before shipping the native build.**
      The native app pulls and pushes a new `forms` table. Without it the
      initial full pull fails on the missing table, so signing in on a new
      device (or after a reinstall) breaks, and every form edit stays queued
      for retry. The migration also attaches `set_updated_at_trg` (needs
      `20260831_updated_at_server_authority.sql` applied first). Unblocked
      when the migration is applied in the Supabase SQL editor and
      `public.forms` exists with RLS enabled, the `users manage own forms`
      policy and `set_updated_at_trg`; then delete this entry.
- [ ] **Campaigns (Phase 33, `feat/campaigns`) — apply `supabase/migrations/20261003_campaigns.sql` before shipping the native build.**
      The native app pulls and pushes a new `campaigns` table. Without it the
      initial full pull fails on the missing table, so signing in on a new
      device (or after a reinstall) breaks, and every campaign edit stays
      queued for retry. The migration also attaches `set_updated_at_trg`
      (needs `20260831_updated_at_server_authority.sql` applied first).
      Unblocked when the migration is applied in the Supabase SQL editor and
      `public.campaigns` exists with RLS enabled, the `users manage own
      campaigns` policy and `set_updated_at_trg`; then delete this entry.
      The campaign-code Worker validator and `book.html` `?c=` (spec §9.1,
      §9.3) are not in this branch; without them campaign links still open
      and only the 30-day window attributes bookings.

---

## Adding an entry here

Add one whenever a merged-but-unshippable change lands on `master`. An entry
needs three things: **what** is blocked, **why shipping it would hurt**, and
**what specifically unblocks it**. Delete the entry the moment it is resolved —
a checklist full of stale entries stops being read, which defeats it.
