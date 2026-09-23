# TradeReady

Expo/React Native app (root) being migrated to a native SwiftUI app (`native/`).
Backend: Cloudflare Worker (`backend-workers/`, live) + legacy Vercel (`backend/`).

## Swift migration: where things stand
- Source of truth for status: `docs/native-ios-migration-roadmap.md` ("Current progress").
- Per-phase plans: `docs/native-phase-<N>-implementation-plan.md`, each with an
  execution ledger. Contract decisions: `docs/native-phase-<N>-*-contract-decisions.md`.
- Parity status: `docs/native-parity-matrix.md`. Device evidence is deferred to
  Phase 12 (roadmap "Verification deferral decision (2026-09-16)").
- `N/` in docs means `native/TradeReadyNative/`.

## Verify
- Swift host tests: `sh native/run-<name>-tests.sh`; everything: `sh native/run-all-domain-tests.sh`.
- RN oracles: `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath <files>`
  (a west-of-UTC timezone exposes the FA-039 local-date bugs).
- Compile: `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- Plan/doc file references: `sh native/run-doc-reference-check.sh` (reports
  backticked paths in `docs/native-*.md` that don't exist; run it after editing
  or reviewing a plan).

## Rules
- Other agents (e.g. Codex) may be editing concurrently. Check `git status` and
  ask before touching files another agent is working on.
- No commits, deploys, live migrations, or production account access unless asked.
- Never point staging config at production (`https://staging.invalid` stays until real staging exists).
- No current app users: choose correctness over preserving existing-user state.
