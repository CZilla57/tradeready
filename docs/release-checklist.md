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

None currently. See "Adding an entry here" below for the bar a new one needs
to clear.

---

## Adding an entry here

Add one whenever a merged-but-unshippable change lands on `master`. An entry
needs three things: **what** is blocked, **why shipping it would hurt**, and
**what specifically unblocks it**. Delete the entry the moment it is resolved —
a checklist full of stale entries stops being read, which defeats it.
