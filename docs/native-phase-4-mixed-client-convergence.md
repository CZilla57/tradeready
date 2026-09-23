# Native Phase 4 Mixed-Client Convergence

Updated: 2026-09-13

Status: modeled React Native/Swift wire-contract verification complete; trusted-
staging and physical-device concurrency evidence remains required.

## Implemented contract evidence

`native/TwoDeviceConvergenceTests/main.swift` now drives a narrow React Native
reference client and the production Swift push/delta-pull services against one
deterministic in-memory Supabase Data API. The reference client mirrors the
collection contract in `utils/sync.ts`:

- React Native upserts send `{id,user_id,data,updated_at,deleted:false}` while
  Swift omits `updated_at`.
- React Native and Swift deletes are owner-filtered soft updates.
- Both pull through a database-timestamp cursor with a five-minute overlap.
- Ordinary collection records remain whole-blob last-writer-wins; the existing
  focused suites retain the invoice-payment and booking-history merge coverage.
- The database model always replaces a client-provided timestamp, matching
  `supabase/migrations/20260831_updated_at_server_authority.sql`.

The mixed-client scenarios prove that:

- a React Native-origin job is pulled by Swift;
- Swift stores the database timestamp, not a far-future React Native device
  timestamp;
- a Swift edit is pulled by the React Native reference client;
- a later React Native edit wins even when its device timestamp is decades old;
- a Swift-created job is discovered by React Native; and
- a React Native owner-scoped soft delete removes the job on Swift.

Run:

```sh
native/run-two-device-convergence-tests.sh
npm test -- --runInBand __tests__/sync.test.js
native/run-all-domain-tests.sh
```

The Jest suite remains the executable React Native oracle for queue shape,
database-clock cursor behavior, pagination, payment-ledger merge, booking-
history merge, and push-time timestamp behavior. The native suite checks that
the Swift transport interoperates with those wire rules.

## Required external evidence

This host model is not proof that two installed apps converge against the live
service. Keep Phase 4 open until all of the following pass on trusted staging:

Run `native/run-phase-4-device-preflight.sh` first and record results in
`native-phase-4-device-runsheet.md`.

- Install the current React Native build and native Swift build on separate
  physical devices, signed into the same disposable account.
- Create, edit, and delete distinct records from each client; confirm both
  clients converge without duplicates after foreground sync.
- Edit the same record offline on both clients, reconnect in a recorded order,
  and confirm the server-last writer appears on both.
- Add payments to the same invoice from both clients and confirm the database
  payment-merge trigger plus each pull path retain both ledger entries.
- Exercise booking-history and job-photo propagation in both directions.
- Interrupt each client during push and pull, relaunch it, and confirm the
  durable queue/cursor recovers without lost or cross-account data.
- Repeat an account switch while work is suspended; neither client may apply or
  expose the previous owner's state.

Record no credentials, tokens, customer values, full device identifiers, or
raw URLs in repository evidence.
