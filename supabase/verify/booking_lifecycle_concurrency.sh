#!/bin/sh
# supabase/verify/booking_lifecycle_concurrency.sh
# Task 8.04 — CHECKED-IN commands for actual PostgreSQL concurrency proof.
#
# STATUS: DEFERRED (M1). No local PostgreSQL exists in this repo or on the
# 8.04 host (no psql/docker); a mocked 409 is characterization, NOT race
# evidence. Run this against an isolated staging project (Phase 12 / 8.14),
# record the session transcripts as evidence, and NEVER against production.
#
# Prerequisites: migration 20260920_booking_lifecycle_rpcs.sql applied,
# verify/booking_lifecycle_rpcs.sql queries 1–5 green, two test owners
# (OWNER_A, OWNER_B) each with an enabled booking-link settings blob:
#   data = {"businessName":"...","schedule":{"timeZone":"America/Chicago",
#     "bookableSlotsEnabled":true,"slotLeadHours":0,...}}
# and no jobs on 2026-09-22.
#
# How to run: open TWO psql sessions (A and B) with the SERVICE ROLE session
# (RPCs are security definer, service_role-only EXECUTE). In each session:
#   begin;
#   select public.claim_booking_slot('<OWNER>', '<TOKEN>', '2026-09-22',
#     '<START>', '10:00', '<START_UTC>', '2026-09-22T15:00:00Z',
#     60, 0,
#     jsonb_build_object('id','<REQ_ID>','status','booked','kind','booked'),
#     jsonb_build_object('id','<RES_ID>'));
# Commit protocol per case below. Because both txns serialize on
# booking_take_lock(<owner>), the second claim blocks until the first
# commits/rolls back, then re-evaluates against the committed snapshot.
#
# Case 1 — concurrent identical-start (same owner, same slot):
#   A and B claim 09:00 with distinct request ids. Commit A, then B.
#   EXPECT: A {"ok":true}; B {"ok":false,"error":"slot_taken"}.
#   EXPECT: exactly one booking_reservations row status='booked' and exactly
#   one "bookingRequests" row for 09:00.
#
# Case 2 — overlapping different-start (same owner, 09:00 vs 09:30, dur 60):
#   EXPECT: winner {"ok":true}; loser {"ok":false,"error":"slot_taken"}.
#   (The pre-RPC partial unique index CANNOT serialize this pair — G1-01 gap.
#   Exactly one winner here is the RPC proof.)
#
# Case 3 — buffer-only (same owner, buffer 60, 09:00 vs 10:00):
#   Set settings bufferMinutes=60 first (or pass p_buffer_minutes=60 with the
#   settings blob at 60). EXPECT: one winner, loser slot_taken. (G1-02 gap.)
#
# Case 4 — disjoint (same owner, 09:00 vs 11:00, buffer 0):
#   EXPECT: both {"ok":true}. (No false serialization from the owner lock —
#   the lock orders, the predicate decides.)
#
# Case 5 — cross-owner (OWNER_A and OWNER_B claim 09:00 simultaneously):
#   EXPECT: both {"ok":true}. (Owner-scoped predicates never conflict.)
#
# Case 6 — write failure/rollback (same owner):
#   B claims 09:00 with a DUPLICATE reservation id (reuse A's committed
#   reservation id). EXPECT: B {"ok":false,"error":"slot_taken"} via the
#   unique-violation branch, zero partial rows (single txn, no compensation
#   DELETE issued — confirm via `select * from pg_stat_statements` or audit
#   log that no DELETE ran, or simply that no orphan 'booked' row exists for
#   B's request id).
#
# Case 7 — confirm-vs-cancel race (same booking, owner + customer):
#   A: transition_booking('<REQ>','<OWNER_A>',null,'{booked,confirmed,
#        reschedule_requested}','declined',<hist>,true,null)
#   B: transition_booking('<REQ>',null,'<MANAGE>','{booked}','confirmed',
#        <hist>,false,null)
#   Run concurrently; commit A then B (then repeat B-then-A on a fresh row).
#   EXPECT: exactly one {"ok":true}; the other
#   {"ok":false,"error":"invalid_state","status":<winner-target>} with exactly
#   ONE appended history entry total and at most one reservation flip.
#
# Cleanup after each case (same session):
#   delete from public.booking_reservations where request_id like 'bk_verify%';
#   delete from public."bookingRequests" where id like 'bk_verify%';
#
# Record: psql transcripts (both sessions, \timing on), the final row counts,
# and the history-length assertion. Attach to the 8.14 evidence log.
echo "DEFERRED: needs an isolated staging Postgres (see header). Nothing executed."
exit 2
