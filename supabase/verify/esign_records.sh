#!/bin/sh
# supabase/verify/esign_records.sh
#
# Proves supabase/migrations/20261003_esign_records.sql (Phase 19) on a
# THROWAWAY local PostgreSQL: it applies (twice), the project verify script
# (migrations/verify/20261003_esign_records_verify.sql) passes, and a REAL
# auth.users delete cascades through signature_records, signature_pending and
# signature_events —
# the account-deletion path (decision 19-Q6). A negative control first shows
# the verify script failing on a database without the migration.
#
# bootstrap.sql only imitates the hosted project. This does NOT replace
# applying the migration to the project and running the verify script there.
#
# Usage:  sh supabase/verify/esign_records.sh   (needs PostgreSQL 15+ on PATH:
#         the per-link unique constraints use NULLS NOT DISTINCT)
# Own cluster on port 54331 (override with PGPORT_SCRATCH), removed at exit.
# Never point it at a real database.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MIG="$HERE/../migrations"
BOOT="$HERE/local/bootstrap.sql"
VERIFY="$MIG/verify/20261003_esign_records_verify.sql"
PORT=${PGPORT_SCRATCH:-54331}
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
pq() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d scratch -X -At -v ON_ERROR_STOP=1 "$@"; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "== setup: bootstrap + the jobs-trigger migrations"
pq -q -f "$BOOT" >/dev/null 2>&1 || { echo "bootstrap failed"; exit 2; }
for f in 20260807_booking_reservations 20260831_updated_at_server_authority 20260920_booking_lifecycle_rpcs 20261002_job_approval_preserve; do
  pq -q -f "$MIG/$f.sql" >/dev/null 2>"$TMP/err" || { echo "$f failed: $(head -3 "$TMP/err")"; exit 2; }
done
pq -q -c "insert into auth.users values ('$OWNER')" >/dev/null || exit 2

echo "== negative control: the verify script fails without the migration"
if pq -q -f "$VERIFY" >/dev/null 2>"$TMP/err"; then bad "verify passed without the migration"; else ok "verify fails without the migration: $(grep -o 'signature_records / signature_events missing' "$TMP/err" | head -1)"; fi

echo "== migration"
if pq -q -f "$MIG/20261003_esign_records.sql" >/dev/null 2>"$TMP/err"; then ok "20261003_esign_records applies"; else bad "applies: $(head -3 "$TMP/err")"; fi
if pq -q -f "$MIG/20261003_esign_records.sql" >/dev/null 2>"$TMP/err"; then ok "re-applies (idempotent)"; else bad "re-applies: $(head -3 "$TMP/err")"; fi

echo "== project verify script"
if pq -f "$VERIFY" >"$TMP/out" 2>&1; then
  grep -o 'ok [0-9]\..*' "$TMP/out" | sed 's/^/       /'
  grep -q 'ALL CHECKS PASSED' "$TMP/out" && ok "verify script: ALL CHECKS PASSED" || bad "verify script printed no ALL CHECKS PASSED"
else
  bad "verify script failed: $(grep -m2 ERROR "$TMP/out")"
fi
eq "verify script rolled back (no rows left)" "$(pq -c "select (select count(*) from public.signature_records) + (select count(*) from public.signature_pending) + (select count(*) from public.signature_events)")" "0"

echo "== account deletion: a real auth.users delete cascades"
OTHER=22222222-2222-2222-2222-222222222222
pq -q -c "insert into auth.users values ('$OTHER')" >/dev/null
pq -q >/dev/null <<SQL
insert into public.signature_records (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
values (gen_random_uuid(), '$OWNER', repeat('1', 64), 'j1', 'estimate', '{}', repeat('2', 64), 'k', 's', now()),
       (gen_random_uuid(), '$OTHER', repeat('3', 64), 'j2', 'estimate', '{}', repeat('4', 64), 'k', 's', now());
insert into public.signature_pending (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, signed_at)
values (gen_random_uuid(), '$OWNER', repeat('5', 64), 'j3', 'estimate', '{}', repeat('6', 64), now()),
       (gen_random_uuid(), '$OTHER', repeat('7', 64), 'j4', 'estimate', '{}', repeat('8', 64), now());
insert into public.signature_events (user_id, job_id, approval_token_sha256, event)
values ('$OWNER', 'j1', repeat('1', 64), 'viewed'), ('$OWNER', 'j1', repeat('1', 64), 'signed'), ('$OTHER', 'j2', repeat('3', 64), 'viewed');
SQL
if pq -q -c "delete from public.signature_records where user_id = '$OWNER'" >/dev/null 2>&1; then
  ok "a direct delete is possible for the table owner (no delete trigger, so the cascade can run)"
  pq -q >/dev/null <<SQL
insert into public.signature_records (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
values (gen_random_uuid(), '$OWNER', repeat('1', 64), 'j1', 'estimate', '{}', repeat('2', 64), 'k', 's', now());
SQL
else
  bad "a delete trigger blocks deletes (it would block account deletion)"
fi
if pq -q -c "delete from auth.users where id = '$OWNER'" >/dev/null 2>"$TMP/err"; then ok "deleting the auth user succeeds"; else bad "auth user delete failed: $(head -2 "$TMP/err")"; fi
eq "the owner's records are gone" "$(pq -c "select count(*) from public.signature_records where user_id = '$OWNER'")" "0"
eq "the owner's pending signatures are gone" "$(pq -c "select count(*) from public.signature_pending where user_id = '$OWNER'")" "0"
eq "the owner's events are gone" "$(pq -c "select count(*) from public.signature_events where user_id = '$OWNER'")" "0"
eq "another owner's evidence is untouched" "$(pq -c "select (select count(*) from public.signature_records) || '/' || (select count(*) from public.signature_pending) || '/' || (select count(*) from public.signature_events)")" "1/1/1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
