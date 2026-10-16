# Roadmap execution prompt (phases 25 → 18)

Paste everything below the line into a new session opened in `~/dev/tradeready`.
Set the session model to **Opus 5.5** before sending (model picker in the app).

---

You are the orchestrator for finishing the TradeReady post-launch roadmap. The build order is the table "Build order (owner-set 2026-10-02)" in `docs/post-launch-feature-roadmap.md`: phases 25, 27, 32, 20, 21, 34, 24, 28, 33, 26, 23, 19, 18. Each phase has a design spec in `docs/superpowers/specs/2026-10-0*-*-design.md`. The owner has approved every recommendation in `docs/roadmap-owner-decisions-2026-10-03.md`, so build to the recommended answers and do not stop to re-ask them.

The goal is every phase built to its spec, verified, and committed locally, at the lowest token spend and wall-clock time that still gets it right. I am not watching in real time. Keep going until everything is done or blocked on something only I can do.

## What is already true

Much of this work is in flight, so this is a resume, not a fresh start. There is a local `feat/<phase>` branch per phase, most checked out as a worktree under `.claude/worktrees/`. Some branch tips are `wip` commits, several branches point at the same commit, and the main checkout (`feat/quote-expiration`) has uncommitted changes. Some specs also describe uncommitted customer-page work in the sibling `tradeready-legal` repo. Other agents may still be running in those worktrees.

## Standing rules

- Target only `native/TradeReadyNative/`, `backend-workers/`, and Supabase migration files. Do not change the React Native app, `backend/`, or `web/`.
- One local `feat/` branch per phase, stacked in build order. Local commits only. No push, no PRs, no deploys, no applied migrations, no production account access.
- Owner-run steps stay mine: `wrangler secret put`, the Stripe Dashboard, the Apple Tap to Pay entitlement, applying migrations, and committing or publishing `tradeready-legal`. Build everything up to those steps and record them, do not perform them.
- No new dependencies or SDK bumps beyond what an approved spec names.
- There are no current app users, so prefer correctness over preserving existing-user state.
- Before editing in any worktree, run `git status` there. If files are changing underneath you or the tree has uncommitted work you did not make, treat it as another agent's and skip that phase for now rather than editing over it.

## Step 1: establish the real state (do this yourself, cheaply)

Do not read whole specs or source files into your own context for this. Send one Haiku agent per phase, all in a single message so they run in parallel. Each one reports, for its phase: branch and worktree path, what it is stacked on, commits ahead of `master`, whether the tree is dirty, the spec's Status line and build-record section, which spec sections have no corresponding code yet, and the result of that phase's targeted test runners. Ask for a report under 200 words with test output quoted verbatim, and ask it to separate what it ran from what it inferred.

Write the result to `docs/roadmap-execution-ledger.md` as one row per phase: state (not started, partial, built unverified, verified, committed), remaining work, blockers, owner-run steps. This ledger is your memory. Update it after every phase event and re-read it instead of relying on conversation history, since context will be summarized during a run this long.

Then proceed straight to step 2. Do not wait for my approval of the ledger.

## Step 2: finish phases, in build order, in parallel where safe

Work in build order because the branches stack. A later phase can be worked on in parallel with an earlier one only when it does not depend on it (34 depends on 27; check each spec's "Builds on" line) and its remaining work does not touch files the earlier one is still changing. Cap it at three implementation agents at a time. Each must work in its own phase worktree, never two in one tree.

Inside one phase, split native Swift work and Worker work into two agents when both remain, since they share no files. Do not split further unless the spec has clearly separate sections with separate files.

These files are touched by nearly every phase and are where stacked merges conflict: `native/TradeReadyNative.xcodeproj/project.pbxproj`, `native/TradeReadyNative/AppStore.swift`, `native/run-all-domain-tests.sh`, `docs/native-fixture-manifest.json`. When an earlier branch changes, merge it forward up the stack one branch at a time and resolve these yourself or with one Opus agent. Regenerate the fixture manifest with `node scripts/parity-manifest.mjs --write` rather than hand-merging it.

## Model routing

Pick the model by what the work demands, not by how important the phase sounds. The specs are detailed, with file and line code maps, which is what makes the cheaper models safe for implementation here.

| Work | Model | Why |
|---|---|---|
| Orchestration: sequencing, ledger, merge decisions, accepting or rejecting agent reports | Opus 5.5 (you, the main session) | Long-lived context, many small judgment calls. Stay lean: delegate reading and building. |
| State survey, locating code, running test runners and quoting failures, doc reference check, runner registration, manifest regeneration | Haiku 4.5 (`model: "haiku"`, `Explore` type for pure search) | Mechanical and high volume. Fastest and cheapest, and nothing here needs design judgment. |
| Implementing a spec section whose design is settled: Swift domain types, views, host tests, Worker routes and their tests | Sonnet 5.5 (`model: "sonnet"`) | Best value for writing code to a precise spec. This should be the bulk of all tokens spent. |
| Work with real design latitude or cross-cutting risk: changes to sync or merge logic, the frozen approval snapshot and its digest, `AppStore` state flow, resolving non-trivial stack conflicts, a spec section that turns out to be wrong against the code | Opus 5.5 (`model: "opus"`) | Needs to hold several interacting invariants at once. |
| Independent review of a finished phase against its spec | Opus 5.5, fresh agent, given the spec path and the branch diff range only | A reviewer that did not write the code and is not handed your conclusions. |
| Review of money, auth and signature code: phase 24 autopay sweep and pay page, 28 tips, 18 Tap to Pay, 19 signature seal and signed-copy records, 23 API key issuance and auth | Fable 5.1 (`model: "fable"`) | The cost of a missed bug here is a wrong charge or a broken legal record. Use it for review of these diffs only, not for building them. |
| A bug that has survived two fix attempts by a cheaper model | Escalate one tier (Sonnet to Opus, Opus to Fable) with the failed attempts and their output in the brief | Stops a cheap model from looping. Never retry a third time at the same tier. |

Do not use Fable for implementation or orchestration, and do not use Opus for anything in the Haiku row. Do the work yourself, without an agent, when it is a handful of commands: running one test script, a small merge, a ledger edit, a commit.

## How to brief an agent

Each agent starts with no context, and you only see its summary, so the brief decides the quality. Every brief states:

1. The goal in one sentence and the phase it belongs to.
2. The worktree path to work in and the branch that should be checked out there.
3. The spec file and the exact section numbers to implement or check. Tell it to read those sections and the files the spec's code map names, not the whole spec or the whole of `AppStore.swift`.
4. Which files it owns, and that everything else is read-only for it.
5. The standing rules above that apply (native and Worker only, no commit unless you tell it to, no deploy, no migration apply).
6. The exact verification commands to run and to quote output from.
7. The report format: files changed, test commands and their verbatim result lines, any place it deviated from the spec and why, anything it could not verify. Under 300 words.

If the spec and the code disagree, the agent reports the mismatch instead of guessing. You decide, or hand the decision to an Opus agent, and record it in the spec's build record.

## Verification

Trust test output, not agent summaries. Verification is tiered to keep it fast:

- **While building:** the agent runs only the phase's own runners (`sh native/run-<name>-tests.sh`) and the Worker tests for the routes it touched.
- **When a phase claims done:** you run, in that worktree, `sh native/run-all-domain-tests.sh`, the Worker test suite, the Release compile from `CLAUDE.md`, and `sh native/run-doc-reference-check.sh`. Run one Release compile at a time across all worktrees, since it saturates the machine.
- **Then review:** one fresh review agent per the routing table. Fix confirmed findings with a Sonnet agent, re-run the affected runners, and do not re-review unless the fix was large.
- **Then commit** on the phase branch with a `feat(<phase>): Phase <N> ...` message, update the spec's Status line and build record, update the ledger, and merge forward into the next branch in the stack.

New host test targets must be registered in `native/run-all-domain-tests.sh`, or the registration guard fails the aggregate. Device evidence is out of scope here. Note what needs a device in the ledger instead.

## When to stop

Stop a phase, not the run, when it needs an owner-run step, a decision the approved decisions doc does not cover, or a worktree another agent is using. Record it in the ledger and move to the next phase that can proceed.

End the run when every phase is committed and verified or is recorded as blocked. The final message is the ledger table, the list of owner-run steps in the order I should do them, anything a reviewer flagged that you chose not to fix and why, and any test or build that is not green, with its output.
