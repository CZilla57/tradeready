# Phase 8 Device and Live-Backend Runsheet

Status: **not run.** Scheduled for Phase 12 per the 2026-09-16 deferral decision.
Host evidence only so far.

The authoritative rows are P8-1 to P8-15 in
[native-phase-12-evidence-index.md](native-phase-12-evidence-index.md); record
results there, not here. They cover layout, VoiceOver, day/week reschedule, Maps
handoff, share cancellation, offline relaunch, time zone, the public booking race,
link disable/rotate, React Native/Swift convergence, portal content and requests,
photo visibility, ICS, approval/payment navigation, and database concurrency.

Blockers common to most rows: the `d5eff92` backend migrations are applied in no
environment (BE-DEPLOY), and there is no isolated staging (D4). The database proofs
are `supabase/verify/booking_lifecycle_concurrency.sh` and
`supabase/verify/portal_token_admin.sql`.
