#!/bin/sh
# supabase/verify/job_approval_preserve.sh
#
# Proves supabase/migrations/20261002_job_approval_preserve.sql on a THROWAWAY
# local PostgreSQL with real writes to public.jobs: plain UPDATEs (the Worker's
# PATCH) and PostgREST merge-duplicates upserts (INSERT ... ON CONFLICT DO
# UPDATE, the device push). The other triggers that production has on `jobs`
# (20260831 set_updated_at_trg, 20260920 booking fence triggers) are applied
# too, so the migration header's trigger-order claim is exercised rather than
# only argued. A negative control first shows the stale-push bug on the same
# harness without the migration.
#
# bootstrap.sql only imitates the hosted project (roles, auth.uid(), the
# inferred jobs shape). This does NOT replace applying the migration to the
# real project and confirming the trigger exists there.
#
# Usage:  sh supabase/verify/job_approval_preserve.sh   (needs PostgreSQL 14+ on PATH)
# It starts its own cluster in a temp dir on port 54330 (one above
# local/run.sh, so both can run at once; override with PGPORT_SCRATCH) and
# removes it at exit. Never point it at a real database.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MIG="$HERE/../migrations"
BOOT="$HERE/local/bootstrap.sql"
NEWMIG="$MIG/20261002_job_approval_preserve.sql"
PORT=${PGPORT_SCRATCH:-54330}
OWNER=11111111-1111-1111-1111-111111111111
export LC_ALL=${LC_ALL:-en_US.UTF-8}
for d in /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@17/bin /usr/local/opt/postgresql@16/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
command -v initdb >/dev/null || { echo "initdb not found: install PostgreSQL (brew install postgresql@16)"; exit 2; }

TMP=$(mktemp -d)
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust >/dev/null || exit 2
pg_ctl -D "$TMP/data" -o "-p $PORT -c unix_socket_directories=" -l "$TMP/pg.log" -w start >/dev/null || { cat "$TMP/pg.log"; exit 2; }
psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -X -q -c "create database scratch" >/dev/null

# SQL is fed on stdin so psql's :'var' interpolation does the literal quoting.
pq() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d scratch -X -At -v ON_ERROR_STOP=1 -v owner="$OWNER" "$@"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
now_ms()  { python3 -c 'import time;print(int(time.time()*1000))'; }
elapsed() { echo $(( $(now_ms) - $1 )); }

# Every write below must succeed: an error is a failure of its own.
run() { pq -q -f - >/dev/null 2>"$TMP/err" "$@" || { bad "SQL errored: $(head -2 "$TMP/err" | tr '\n' ' ')"; return 1; }; }

seed() { # id json — plain INSERT (the trigger never fires on INSERT)
  run -v id="$1" -v data="$2" <<'SQL'
insert into public.jobs (id, user_id, data) values (:'id', :'owner', :'data'::jsonb);
SQL
}
upsert_as() { # role id json — PostgREST merge-duplicates upsert, as that role
  run -v role="$1" -v id="$2" -v data="$3" <<'SQL'
begin;
set local role :role;
select set_config('request.jwt.claim.sub', case when :'role' = 'authenticated' then :'owner' else '' end, true) is null;
insert into public.jobs (id, user_id, data, deleted, updated_at)
values (:'id', :'owner', :'data'::jsonb, false, '2000-01-01T00:00:00Z')
on conflict (id) do update
  set user_id = excluded.user_id, data = excluded.data,
      deleted = excluded.deleted, updated_at = excluded.updated_at;
commit;
SQL
}
device_push() { upsert_as authenticated "$1" "$2"; }   # the device's sync push
server_upsert() { upsert_as service_role "$1" "$2"; }  # Worker upsertJob (changeRespond, createLink)
server_write() { # id json — Worker conditional write (updateJobIfUnchanged): plain UPDATE as service_role
  run -v id="$1" -v data="$2" <<'SQL'
begin;
set local role service_role;
update public.jobs set data = :'data'::jsonb where id = :'id';
commit;
SQL
}
expect() { # label id json — the stored blob must equal json exactly (jsonb equality; arrays are order-sensitive)
  r=$(pq -v id="$2" -v want="$3" -f - 2>&1 <<'SQL'
select case when data = :'want'::jsonb then 'same' else coalesce(data::text, '<SQL NULL>') end from public.jobs where id = :'id';
SQL
)
  if [ "$r" = "same" ]; then ok "$1"; else
    bad "$1"
    echo "         got:  ${r:-<no row>}"
    echo "         want: $(pq -v want="$3" -f - <<'SQL'
select :'want'::jsonb::text;
SQL
)"
  fi
}

# Fixtures shared by several cases.
SNAP1='{"total": 100, "options": [{"id": "good", "total": 100}, {"id": "better", "total": 150}], "addOns": [{"id": "a1", "amount": 25}]}'
APPROVED1='{"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "snapshot": '"$SNAP1"',
  "decision": "approved", "consentAt": "2026-10-02T09:00:00Z", "signerName": "Pat Doe",
  "ip": "203.0.113.9", "userAgent": "Mozilla/5.0",
  "selection": {"tierId": "better", "addOnIds": ["a1"], "total": 175}}'
STALE1='{"id": "j1", "title": "Kitchen remodel", "notes": "bring ladder", "status": "estimate_sent",
  "crew": ["sam"], "approval": {"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "reminderCount": 1}}'
RESTORED1='{"id": "j1", "title": "Kitchen remodel", "notes": "bring ladder", "status": "estimate_sent",
  "crew": ["sam"], "approval": {"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "reminderCount": 1,
  "snapshot": '"$SNAP1"', "decision": "approved", "consentAt": "2026-10-02T09:00:00Z",
  "signerName": "Pat Doe", "ip": "203.0.113.9", "userAgent": "Mozilla/5.0",
  "selection": {"tierId": "better", "addOnIds": ["a1"], "total": 175}}}'

echo "== setup: bootstrap + the other jobs-trigger migrations"
pq -q -f "$BOOT" >/dev/null 2>&1 || { echo "bootstrap failed"; exit 2; }
for f in 20260807_booking_reservations 20260831_updated_at_server_authority 20260920_booking_lifecycle_rpcs; do
  pq -q -f "$MIG/$f.sql" >/dev/null 2>"$TMP/err" || { echo "$f failed: $(head -3 "$TMP/err")"; exit 2; }
done
pq -q -c "insert into auth.users values ('$OWNER')" >/dev/null || exit 2

echo "== negative control: without the migration a stale push erases the approval"
seed j1 '{"id": "j1", "title": "Kitchen", "status": "estimate_sent",
  "approval": {"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "snapshot": '"$SNAP1"'}}'
server_write j1 '{"id": "j1", "title": "Kitchen", "status": "estimate_sent", "approval": '"$APPROVED1"'}'
device_push j1 "$STALE1"
expect "control: the stale push stored verbatim, decision gone (the bug)" j1 "$STALE1"
pq -q -c "delete from public.jobs where id = 'j1'" >/dev/null

echo "== migration applies"
if pq -q -f "$NEWMIG" >/dev/null 2>"$TMP/err"; then ok "20261002_job_approval_preserve applies"; else bad "applies: $(head -3 "$TMP/err")"; echo; echo "passed $PASS, failed $FAIL"; exit 1; fi

echo "== 1. stale device push after an approval"
seed j1 '{"id": "j1", "title": "Kitchen", "status": "estimate_sent",
  "approval": {"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "snapshot": '"$SNAP1"'}}'
server_write j1 '{"id": "j1", "title": "Kitchen", "status": "estimate_sent", "approval": '"$APPROVED1"'}'
expect "1. the Worker's pending -> approved write is stored as sent" j1 \
  '{"id": "j1", "title": "Kitchen", "status": "estimate_sent", "approval": '"$APPROVED1"'}'
device_push j1 "$STALE1"
expect "1. decision/consentAt/signerName/ip/userAgent/selection/snapshot restored; title, notes, new key, additive approval key kept" j1 "$RESTORED1"
eq "1. set_updated_at_trg still stamped the merged write" "$(pq -c "select updated_at > '2001-01-01' from public.jobs where id = 'j1'")" "t"
device_push j1 '{"id": "j1", "title": "Kitchen remodel",
  "approval": {"token": "tok-1", "decision": null, "declineReason": "stale", "consentAt": "1999-01-01T00:00:00Z"}}'
expect "1. JSON-null decision restored; a server-owned key the stored approval lacks (declineReason) is dropped, not taken from the push" j1 \
  '{"id": "j1", "title": "Kitchen remodel", "approval": '"$APPROVED1"'}'

echo "== 2. stale device push after a decline"
seed j2 '{"id": "j2", "title": "Deck stain", "status": "estimate_sent",
  "approval": {"token": "tok-2", "sentAt": "2026-10-01T12:00:00Z", "snapshot": {"total": 80}}}'
server_write j2 '{"id": "j2", "title": "Deck stain", "status": "estimate_sent",
  "approval": {"token": "tok-2", "sentAt": "2026-10-01T12:00:00Z", "snapshot": {"total": 80},
  "decision": "declined", "consentAt": "2026-10-02T09:05:00Z", "declineReason": "Too expensive",
  "ip": "198.51.100.4", "userAgent": "Safari/17"}}'
device_push j2 '{"id": "j2", "title": "Deck stain (2 coats)", "status": "estimate_sent", "notes": "call first",
  "approval": {"token": "tok-2", "sentAt": "2026-10-01T12:00:00Z", "snapshot": {"total": 80}, "signerName": "bogus"}}'
expect "2. decline restored, device edits kept, server-owned key the decline lacks (signerName) dropped" j2 \
  '{"id": "j2", "title": "Deck stain (2 coats)", "status": "estimate_sent", "notes": "call first",
  "approval": {"token": "tok-2", "sentAt": "2026-10-01T12:00:00Z", "snapshot": {"total": 80},
  "decision": "declined", "consentAt": "2026-10-02T09:05:00Z", "declineReason": "Too expensive",
  "ip": "198.51.100.4", "userAgent": "Safari/17"}}'

echo "== 3. server transitions go through"
APPROVED2='{"token": "tok-2", "sentAt": "2026-10-01T12:00:00Z", "snapshot": {"total": 80},
  "decision": "approved", "consentAt": "2026-10-02T11:00:00Z", "signerName": "Lee Park",
  "ip": "198.51.100.7", "userAgent": "Safari/17"}'
server_write j2 '{"id": "j2", "title": "Deck stain (2 coats)", "status": "estimate_sent", "notes": "call first", "approval": '"$APPROVED2"'}'
expect "3. declined -> approved (declineReason removed by the Worker) is stored as sent" j2 \
  '{"id": "j2", "title": "Deck stain (2 coats)", "status": "estimate_sent", "notes": "call first", "approval": '"$APPROVED2"'}'
device_push j2 '{"id": "j2", "title": "Deck stain", "status": "estimate_sent",
  "approval": {"token": "tok-2", "sentAt": "2026-10-01T12:00:00Z", "snapshot": {"total": 80}}}'
expect "3. a push stale from before the decline now gets the approval back" j2 \
  '{"id": "j2", "title": "Deck stain", "status": "estimate_sent", "approval": '"$APPROVED2"'}'
seed j3 '{"id": "j3", "title": "Roof patch", "status": "declined",
  "approval": {"token": "tok-3", "sentAt": "2026-10-01T08:00:00Z", "snapshot": {"total": 300},
  "decision": "declined", "consentAt": "2026-10-01T20:00:00Z", "declineReason": "Need cheaper",
  "ip": "192.0.2.1", "userAgent": "Chrome"}}'
RESENT3='{"id": "j3", "title": "Roof patch", "status": "declined",
  "approval": {"token": "tok-3", "sentAt": "2026-10-02T14:00:00Z", "snapshot": {"total": 250},
  "decision": "declined", "consentAt": "2026-10-01T20:00:00Z", "declineReason": "Need cheaper",
  "ip": "192.0.2.1", "userAgent": "Chrome"}}'
server_upsert j3 "$RESENT3"
expect "3. create-link re-send of a declined estimate (same token, new snapshot/sentAt) is stored as sent" j3 "$RESENT3"

echo "== 4. re-send under a NEW token replaces the approval"
seed j4a '{"id": "j4a", "approval": {"token": "tok-4a", "sentAt": "2026-10-01T08:00:00Z", "snapshot": {"total": 70},
  "decision": "declined", "consentAt": "2026-10-01T21:00:00Z", "ip": "192.0.2.1", "userAgent": "Chrome"}}'
NEW4A='{"id": "j4a", "status": "estimate_sent", "approval": {"token": "tok-4b", "sentAt": "2026-10-02T15:00:00Z", "snapshot": {"total": 60}}}'
device_push j4a "$NEW4A"
expect "4. declined tok-4a -> pending tok-4b stored as sent" j4a "$NEW4A"
seed j4c '{"id": "j4c", "approval": {"token": "tok-4c", "snapshot": {"total": 70}, "decision": "approved", "consentAt": "t", "signerName": "A"}}'
NEW4C='{"id": "j4c", "approval": {"token": "tok-4d", "sentAt": "2026-10-02T15:00:00Z", "snapshot": {"total": 65}}}'
device_push j4c "$NEW4C"
expect "4. even an approved approval is replaced when the token differs" j4c "$NEW4C"

echo "== 5. approval removed entirely (revise-declined)"
seed j5 '{"id": "j5", "title": "Fence", "status": "declined",
  "approval": {"token": "tok-5", "sentAt": "2026-10-01T08:00:00Z", "snapshot": {"total": 900},
  "decision": "declined", "consentAt": "2026-10-01T22:00:00Z", "ip": "192.0.2.1", "userAgent": "Chrome"}}'
REVISED5='{"id": "j5", "title": "Fence", "status": "lead",
  "approvalHistory": [{"token": "tok-5", "sentAt": "2026-10-01T08:00:00Z", "snapshot": {"total": 900},
  "decision": "declined", "consentAt": "2026-10-01T22:00:00Z", "ip": "192.0.2.1", "userAgent": "Chrome"}]}'
server_write j5 "$REVISED5"
expect "5. revise-declined's write (no approval key) is stored as sent" j5 "$REVISED5"

echo "== 6. approved is terminal: snapshot and decision stay frozen"
APPROVED6='{"token": "tok-6", "sentAt": "2026-10-01T07:00:00Z",
  "snapshot": {"total": 200, "options": [{"id": "good", "total": 200}, {"id": "best", "total": 400}]},
  "decision": "approved", "consentAt": "2026-10-01T23:00:00Z", "signerName": "Sam Lee",
  "ip": "192.0.2.9", "userAgent": "Firefox", "selection": {"tierId": "good", "addOnIds": [], "total": 200}}'
seed j6 '{"id": "j6", "title": "Water heater", "status": "approved", "approval": '"$APPROVED6"'}'
device_push j6 '{"id": "j6", "title": "Water heater (50 gal)", "status": "approved",
  "approval": {"token": "tok-6", "sentAt": "2026-10-02T16:00:00Z", "snapshot": {"total": 999},
  "decision": "approved", "consentAt": "2026-10-02T16:00:00Z", "signerName": "Mallory",
  "ip": "10.0.0.1", "userAgent": "device", "selection": {"tierId": "best", "addOnIds": [], "total": 400},
  "declineReason": "x", "pdfCachedAt": "2026-10-02"}}'
expect "6. device-sent snapshot/sentAt/decision fields ignored, additive key kept" j6 \
  '{"id": "j6", "title": "Water heater (50 gal)", "status": "approved", "approval": {"pdfCachedAt": "2026-10-02",
  "token": "tok-6", "sentAt": "2026-10-01T07:00:00Z",
  "snapshot": {"total": 200, "options": [{"id": "good", "total": 200}, {"id": "best", "total": 400}]},
  "decision": "approved", "consentAt": "2026-10-01T23:00:00Z", "signerName": "Sam Lee",
  "ip": "192.0.2.9", "userAgent": "Firefox", "selection": {"tierId": "good", "addOnIds": [], "total": 200}}}'
server_write j6 '{"id": "j6", "title": "Water heater (50 gal)", "status": "approved",
  "approval": {"token": "tok-6", "decision": "declined", "consentAt": "2026-10-02T17:00:00Z",
  "declineReason": "changed mind", "ip": "198.51.100.1", "userAgent": "Edge"}}'
expect "6. a later same-token decline from any writer cannot flip an approval" j6 \
  '{"id": "j6", "title": "Water heater (50 gal)", "status": "approved", "approval": '"$APPROVED6"'}'

echo "== 7. change orders: matched by id + token"
seed j7 '{"id": "j7", "title": "Bathroom", "status": "in_progress", "changeOrders": [
  {"id": "co1", "title": "Extra outlet", "amount": 120, "approval": {"token": "c-1", "sentAt": "2026-10-01T11:00:00Z", "snapshot": {"amount": 120}}},
  {"id": "co2", "title": "Paint trim", "amount": 80, "approval": {"token": "c-2", "sentAt": "2026-10-01T11:05:00Z", "snapshot": {"amount": 80}}},
  {"id": "co3", "title": "Move sink", "amount": 300, "manualDecision": {"decision": "approved", "decidedAt": "2026-10-01"}},
  {"id": "co5", "title": "Vanity", "amount": 50, "approval": {"token": "c-5a", "sentAt": "2026-10-01T11:10:00Z", "snapshot": {"amount": 50}}}]}'
DECIDED7='{"id": "j7", "title": "Bathroom", "status": "in_progress", "changeOrders": [
  {"id": "co1", "title": "Extra outlet", "amount": 120, "approval": {"token": "c-1", "sentAt": "2026-10-01T11:00:00Z", "snapshot": {"amount": 120},
    "decision": "approved", "consentAt": "2026-10-02T10:00:00Z", "signerName": "Pat Doe", "ip": "203.0.113.9", "userAgent": "Mozilla/5.0"}},
  {"id": "co2", "title": "Paint trim", "amount": 80, "approval": {"token": "c-2", "sentAt": "2026-10-01T11:05:00Z", "snapshot": {"amount": 80},
    "decision": "declined", "consentAt": "2026-10-02T10:05:00Z", "declineReason": "Not now", "ip": "203.0.113.9", "userAgent": "Mozilla/5.0"}},
  {"id": "co3", "title": "Move sink", "amount": 300, "manualDecision": {"decision": "approved", "decidedAt": "2026-10-01"}},
  {"id": "co5", "title": "Vanity", "amount": 50, "approval": {"token": "c-5a", "sentAt": "2026-10-01T11:10:00Z", "snapshot": {"amount": 50},
    "decision": "declined", "consentAt": "2026-10-02T10:10:00Z", "ip": "203.0.113.9", "userAgent": "Mozilla/5.0"}}]}'
server_upsert j7 "$DECIDED7"
expect "7. the Worker's change-order decisions (upsertJob) are stored as sent" j7 "$DECIDED7"
device_push j7 '{"id": "j7", "title": "Bathroom", "status": "in_progress", "notes": "tile Friday", "changeOrders": [
  {"id": "co4", "title": "Grab bar", "amount": 40, "approval": {"token": "c-4", "sentAt": "2026-10-02T13:00:00Z", "snapshot": {"amount": 40}}},
  {"id": "co2", "title": "Paint trim and doors", "amount": 95, "approval": {"token": "c-2", "sentAt": "2026-10-01T11:05:00Z", "snapshot": {"amount": 80}}},
  {"id": "co1", "title": "Extra outlet", "amount": 120, "approval": {"token": "c-1", "sentAt": "2026-10-01T11:00:00Z", "snapshot": {"amount": 120}, "shareCount": 2}},
  {"id": "co1-copy", "title": "Extra outlet (copy)", "amount": 120, "approval": {"token": "c-1", "sentAt": "2026-10-01T11:00:00Z"}},
  {"id": "co3", "title": "Move sink", "amount": 300, "manualDecision": {"decision": "approved", "decidedAt": "2026-10-01", "note": "agreed on site"}},
  {"id": "co5", "title": "Vanity", "amount": 55, "approval": {"token": "c-5b", "sentAt": "2026-10-02T13:30:00Z", "snapshot": {"amount": 55}}}]}'
expect "7. co1/co2 decisions restored by id+token; new co4, same-token-other-id co1-copy, co3, re-issued co5 and array order untouched" j7 \
  '{"id": "j7", "title": "Bathroom", "status": "in_progress", "notes": "tile Friday", "changeOrders": [
  {"id": "co4", "title": "Grab bar", "amount": 40, "approval": {"token": "c-4", "sentAt": "2026-10-02T13:00:00Z", "snapshot": {"amount": 40}}},
  {"id": "co2", "title": "Paint trim and doors", "amount": 95, "approval": {"token": "c-2", "sentAt": "2026-10-01T11:05:00Z", "snapshot": {"amount": 80},
    "decision": "declined", "consentAt": "2026-10-02T10:05:00Z", "declineReason": "Not now", "ip": "203.0.113.9", "userAgent": "Mozilla/5.0"}},
  {"id": "co1", "title": "Extra outlet", "amount": 120, "approval": {"token": "c-1", "sentAt": "2026-10-01T11:00:00Z", "snapshot": {"amount": 120}, "shareCount": 2,
    "decision": "approved", "consentAt": "2026-10-02T10:00:00Z", "signerName": "Pat Doe", "ip": "203.0.113.9", "userAgent": "Mozilla/5.0"}},
  {"id": "co1-copy", "title": "Extra outlet (copy)", "amount": 120, "approval": {"token": "c-1", "sentAt": "2026-10-01T11:00:00Z"}},
  {"id": "co3", "title": "Move sink", "amount": 300, "manualDecision": {"decision": "approved", "decidedAt": "2026-10-01", "note": "agreed on site"}},
  {"id": "co5", "title": "Vanity", "amount": 55, "approval": {"token": "c-5b", "sentAt": "2026-10-02T13:30:00Z", "snapshot": {"amount": 55}}}]}'

echo "== 8. malformed shapes: no error, no change"
seed j8a '{"id": "j8a", "approval": '"$APPROVED1"'}'
device_push j8a '{"id": "j8a", "approval": "tok-1"}'
expect "8. approval pushed as a string over an approval" j8a '{"id": "j8a", "approval": "tok-1"}'
seed j8b '{"id": "j8b", "approval": "garbage"}'
device_push j8b '{"id": "j8b", "approval": {"token": "garbage", "sentAt": "x"}}'
expect "8. stored approval is a string (poisoned OLD)" j8b '{"id": "j8b", "approval": {"token": "garbage", "sentAt": "x"}}'
seed j8c '{"id": "j8c", "changeOrders": [{"id": "co1", "approval": {"token": "c-8", "decision": "approved", "consentAt": "t"}}]}'
device_push j8c '{"id": "j8c", "changeOrders": {"co1": {"id": "co1", "approval": {"token": "c-8"}}}}'
expect "8. changeOrders pushed as an object" j8c '{"id": "j8c", "changeOrders": {"co1": {"id": "co1", "approval": {"token": "c-8"}}}}'
seed j8d '{"id": "j8d", "changeOrders": {"id": "co1", "approval": {"token": "c-9", "decision": "approved", "consentAt": "t"}}}'
device_push j8d '{"id": "j8d", "changeOrders": [{"id": "co1", "approval": {"token": "c-9"}}]}'
expect "8. stored changeOrders is an object (poisoned OLD)" j8d '{"id": "j8d", "changeOrders": [{"id": "co1", "approval": {"token": "c-9"}}]}'
seed j8e '{"id": "j8e", "approval": '"$APPROVED1"'}'
device_push j8e '{"id": "j8e", "approval": null}'
expect "8. approval pushed as jsonb null" j8e '{"id": "j8e", "approval": null}'
seed j8f '{"id": "j8f", "approval": '"$APPROVED1"', "changeOrders": [{"id": "co1", "approval": {"token": "c-f", "decision": "declined"}}]}'
device_push j8f 'null'
expect "8. whole blob pushed as jsonb null" j8f 'null'
device_push j8f '{"id": "j8f", "approval": {"token": "tok-1"}}'
expect "8. write over a stored jsonb-null blob" j8f '{"id": "j8f", "approval": {"token": "tok-1"}}'
device_push j8f '[{"approval": {"token": "tok-1"}}]'
expect "8. whole blob pushed as an array" j8f '[{"approval": {"token": "tok-1"}}]'
seed j8g '{"id": "j8g", "changeOrders": ["junk", 5, null, [], {"id": "co1", "approval": "x"},
  {"id": "co2", "approval": {"token": "c-g", "decision": "approved", "consentAt": "t"}}]}'
MIXED8G='{"id": "j8g", "changeOrders": [null, 7, "s", {"id": "co2", "approval": ["array"]}, {"id": "co2"},
  {"approval": {"token": "c-g"}}, {"id": "co1", "approval": {"token": "x"}}]}'
device_push j8g "$MIXED8G"
expect "8. non-object elements, array approvals, id-less and token-mismatched change orders" j8g "$MIXED8G"
seed j8h '{"id": "j8h", "approval": {"token": null, "decision": "approved", "consentAt": "t"}}'
device_push j8h '{"id": "j8h", "approval": {"token": null, "title": "x"}}'
expect "8. null tokens on both sides never match" j8h '{"id": "j8h", "approval": {"token": null, "title": "x"}}'
# The real column's nullability is unconfirmed (bootstrap.sql only infers it),
# so prove the SQL-NULL guard on this throwaway table and put it back.
seed j8i '{"id": "j8i", "approval": '"$APPROVED1"'}'
pq -q -c "alter table public.jobs alter column data drop not null" >/dev/null
pq -q -c "update public.jobs set data = null where id = 'j8i'" >/dev/null 2>"$TMP/err" && ok "8. UPDATE to SQL NULL data does not error" || bad "8. UPDATE to SQL NULL data errored: $(head -2 "$TMP/err")"
eq "8. SQL NULL data stored as sent" "$(pq -c "select data is null from public.jobs where id = 'j8i'")" "t"
pq -q -c "update public.jobs set data = '{\"id\": \"j8i\"}' where id = 'j8i'" >/dev/null 2>"$TMP/err" && ok "8. UPDATE over SQL NULL stored data does not error" || bad "8. UPDATE over SQL NULL data errored: $(head -2 "$TMP/err")"
pq -q -c "delete from public.jobs where id = 'j8i'; alter table public.jobs alter column data set not null" >/dev/null

echo "== 9. INSERT unaffected; migration re-runs idempotently"
INS9='{"id": "j9", "approval": {"token": "tok-9", "decision": null, "selection": {"tierId": "x"}}, "changeOrders": "?"}'
device_push j9 "$INS9"
expect "9. an upsert that inserts a new row is stored as sent" j9 "$INS9"
eq "9. trigger events: BEFORE UPDATE FOR EACH ROW only" \
  "$(pq -c "select string_agg(event_manipulation || '/' || action_timing || '/' || action_orientation, ',') from information_schema.triggers where trigger_name = 'preserve_job_approvals_trg' and event_object_table = 'jobs'")" \
  "UPDATE/BEFORE/ROW"
if pq -q -f "$NEWMIG" >/dev/null 2>"$TMP/err"; then ok "migration re-applies (idempotent)"; else bad "re-apply: $(head -3 "$TMP/err")"; fi
eq "9. exactly one preserve_job_approvals_trg after re-apply" \
  "$(pq -c "select count(*) from pg_trigger where tgrelid = 'public.jobs'::regclass and tgname = 'preserve_job_approvals_trg'")" "1"
eq "9. function is security invoker with a pinned search_path" \
  "$(pq -c "select prosecdef::text || ' ' || array_to_string(proconfig, ';') from pg_proc where oid = 'public.preserve_job_approvals()'::regprocedure")" \
  "false search_path=pg_catalog, public"
eq "9. jobs BEFORE-row trigger set (order = name order) is the one the header reasons about" \
  "$(pq -c "select string_agg(tgname, ' ' order by tgname) from pg_trigger where tgrelid = 'public.jobs'::regclass and not tgisinternal")" \
  "booking_fence_row_trg booking_fence_statement_trg preserve_job_approvals_trg set_updated_at_trg"
pq -q -c "delete from public.jobs where id = 'j1'" >/dev/null
seed j1 '{"id": "j1", "title": "Kitchen", "approval": '"$APPROVED1"'}'
device_push j1 "$STALE1"
expect "9. still restores after the re-apply" j1 "$RESTORED1"

echo "== 10. race: a device push that arrives while the decision is in flight"
seed j10 '{"id": "j10", "title": "Kitchen", "status": "estimate_sent",
  "approval": {"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "snapshot": '"$SNAP1"'}}'
( pq -q -v data='{"id": "j10", "title": "Kitchen", "status": "estimate_sent", "approval": '"$APPROVED1"'}' -f - >/dev/null 2>"$TMP/w10" <<'SQL'
begin;
set local role service_role;
update public.jobs set data = :'data'::jsonb where id = 'j10';
select pg_sleep(1.5);
commit;
SQL
) &
WPID=$!
sleep 0.5
T0=$(now_ms)
device_push j10 '{"id": "j10", "title": "Kitchen remodel", "notes": "bring ladder", "status": "estimate_sent",
  "crew": ["sam"], "approval": {"token": "tok-1", "sentAt": "2026-10-01T10:00:00Z", "reminderCount": 1}}'
EL=$(elapsed "$T0")
wait $WPID
[ ! -s "$TMP/w10" ] || bad "10. Worker write errored: $(head -2 "$TMP/w10")"
[ "$EL" -ge 700 ] && ok "10. device push waited for the in-flight decision (${EL} ms)" || bad "10. device push did not wait (${EL} ms)"
expect "10. the push that waited is merged onto the committed decision" j10 \
  "$(echo "$RESTORED1" | sed 's/"id": "j1"/"id": "j10"/')"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
