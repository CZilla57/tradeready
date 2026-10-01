#!/bin/sh
# supabase/verify/local/run.sh
#
# Compiles the three Phase 8 migrations on a THROWAWAY local PostgreSQL and
# proves the P12-023 (grants), P12-024 (compile) and P12-025 (writer fence,
# lock order) fixes with real concurrent sessions. Closes the "DEFERRED (M1)"
# gap for everything that does not need a hosted project. It does NOT replace
# the hosted-project check (Supabase's own default privileges and PostgREST
# claims) that Phase 12 Stage A still owes: bootstrap.sql only imitates them.
#
# Usage:  sh supabase/verify/local/run.sh            (needs PostgreSQL 14+ on PATH)
# It starts its own cluster in a temp dir on port 54329 and removes it at exit.
# Never point it at a real database: it drops and recreates `scratch`.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MIG="$HERE/../../migrations"
PORT=${PGPORT_SCRATCH:-54329}
export LC_ALL=${LC_ALL:-en_US.UTF-8}
for d in /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@17/bin /usr/local/opt/postgresql@16/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
command -v initdb >/dev/null || { echo "initdb not found: install PostgreSQL (brew install postgresql@16)"; exit 2; }

TMP=$(mktemp -d)
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust >/dev/null || exit 2
pg_ctl -D "$TMP/data" -o "-p $PORT -c unix_socket_directories= -c deadlock_timeout=500ms" -l "$TMP/pg.log" -w start >/dev/null || { cat "$TMP/pg.log"; exit 2; }

pq() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d scratch -X -At -v ON_ERROR_STOP=1 "$@"; }
psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -X -q -c "create database scratch" >/dev/null

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "== P12-024 compile and re-run"
pq -q -f "$HERE/bootstrap.sql" >/dev/null 2>&1 || { echo "bootstrap failed"; exit 2; }
pq -q -f "$MIG/20260807_booking_reservations.sql" >/dev/null 2>&1 || { echo "20260807 failed"; exit 2; }
for f in 20260920_booking_lifecycle_rpcs 20260921_booking_admin_state 20260922_portal_token_admin; do
  if pq -q -f "$MIG/$f.sql" >/dev/null 2>"$TMP/err"; then ok "$f applies"; else bad "$f applies: $(head -3 "$TMP/err")"; fi
  if pq -q -f "$MIG/$f.sql" >/dev/null 2>"$TMP/err"; then ok "$f re-applies (idempotent)"; else bad "$f re-applies: $(head -3 "$TMP/err")"; fi
done

echo "== P12-023 grants"
RPCS="public.claim_booking_slot(uuid,text,text,text,text,timestamptz,timestamptz,integer,integer,jsonb,jsonb)
public.transition_booking(text,uuid,text,text[],text,jsonb,boolean,jsonb)
public.admin_booking_link(uuid,text,uuid,text,boolean,integer,text,jsonb)
public.admin_portal_token(uuid,text,text,uuid,text,boolean,text,jsonb)
public.booking_take_lock(uuid)
public.booking_to_minutes(text)
public.booking_is_client_caller()"
echo "$RPCS" | while read -r fn; do
  for role in anon authenticated; do
    r=$(pq -c "select has_function_privilege('$role', '$fn', 'execute')")
    [ "$r" = "f" ] || echo "BAD $role can execute $fn"
  done
done > "$TMP/fn"; if [ -s "$TMP/fn" ]; then bad "client role can execute: $(cat "$TMP/fn")"; else ok "anon/authenticated cannot execute any Phase 8 function"; fi
echo "$RPCS" | while read -r fn; do
  [ "$(pq -c "select has_function_privilege('service_role', '$fn', 'execute')")" = "t" ] || echo "BAD service_role cannot execute $fn"
done > "$TMP/fn"; if [ -s "$TMP/fn" ]; then bad "$(cat "$TMP/fn")"; else ok "service_role can execute every Phase 8 function"; fi
eq "PUBLIC has no execute on booking_take_lock" "$(pq -c "select coalesce(bool_or(grantee = 0), false) from (select (aclexplode(proacl)).grantee from pg_proc where proname = 'booking_take_lock') a")" "f"
for t in booking_link_state booking_operations portal_operations; do
  c=$(pq -c "select count(*) from pg_policies where schemaname='public' and tablename='$t'")
  eq "$t has no client-facing policy" "$c" "0"
  eq "$t has RLS enabled" "$(pq -c "select relrowsecurity from pg_class where oid = 'public.$t'::regclass")" "t"
  for role in anon authenticated; do
    for priv in select insert update delete; do
      r=$(pq -c "select has_table_privilege('$role', 'public.$t', '$priv')")
      [ "$r" = "f" ] || echo "BAD $role $priv on $t"
    done
  done > "$TMP/tp"; if [ -s "$TMP/tp" ]; then bad "$t client privileges: $(cat "$TMP/tp")"; else ok "$t: no anon/authenticated table privileges"; fi
  r=$(pq -c "select has_table_privilege('service_role', 'public.$t', 'select') and has_table_privilege('service_role', 'public.$t', 'insert') and has_table_privilege('service_role', 'public.$t', 'update')")
  eq "$t: service_role keeps the privileges the Worker needs" "$r" "t"
done
# A real client session, not just the catalog.
OWNER=11111111-1111-1111-1111-111111111111
OTHER=22222222-2222-2222-2222-222222222222
pq -q -c "insert into auth.users values ('$OWNER'), ('$OTHER')" >/dev/null
out=$(pq -c "set role authenticated; select public.booking_take_lock('$OTHER')" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "authenticated session is refused booking_take_lock";; *) bad "authenticated booking_take_lock: $out";; esac
out=$(pq -c "set role anon; select public.admin_portal_token('$OTHER','c1','mint',null,'h',null,'t','{}')" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "anon session is refused admin_portal_token";; *) bad "anon admin_portal_token: $out";; esac
out=$(pq -c "set role authenticated; select count(*) from public.booking_operations" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "authenticated session is refused booking_operations";; *) bad "authenticated booking_operations: $out";; esac
# Defense in depth: a client JWT reaching a function anyway is refused.
r=$(pq -c "select set_config('request.jwt.claims', '{\"role\":\"authenticated\"}', true); select public.admin_booking_link('$OTHER','mint','33333333-3333-3333-3333-333333333333','h',null,null,'th','{}'::jsonb)" | tail -1)
eq "client JWT role is refused inside the function" "$r" '{"ok": false, "error": "forbidden"}'

echo "== hosted-project verify SQL runs and is clean on the scratch DB"
for v in booking_lifecycle_rpcs booking_admin_state portal_token_admin; do
  if pq -f "$HERE/../$v.sql" >"$TMP/v.out" 2>"$TMP/v.err"; then ok "$v.sql runs"; else bad "$v.sql: $(head -3 "$TMP/v.err")"; fi
done
# The grant queries are written so a clean project returns no rows; a leaked
# grant must show up in them.
pq -q -c "grant execute on function public.booking_take_lock(uuid) to authenticated" >/dev/null
pq -f "$HERE/../booking_lifecycle_rpcs.sql" 2>/dev/null | grep -q "booking_take_lock" && ok "verify SQL flags a re-granted client EXECUTE" || bad "verify SQL missed a client EXECUTE grant"
pq -q -c "revoke execute on function public.booking_take_lock(uuid) from authenticated" >/dev/null

echo "== claim behavior (service_role path)"
D=$(pq -c "select (current_date + (case when extract(isodow from current_date + 3) = 7 then 4 else 3 end))::text")
pq -q -c "insert into public.settings (user_id, data) values ('$OWNER', jsonb_build_object('bookingLink', jsonb_build_object('token','tok','enabled',true), 'schedule', jsonb_build_object('timeZone','America/Phoenix','bookableSlotsEnabled',true,'slotLeadHours',0,'slotWindowDays',30,'defaultDurationMinutes',60,'bufferMinutes',0,'workDayStart','08:00','workDayEnd','17:00')))" >/dev/null
claim() { # owner start end reqid resid [buffer]
  pq -c "select public.claim_booking_slot('$1','tok','$D','$2','$3', ('$D ' || '$2')::timestamptz, ('$D ' || '$3')::timestamptz, 60, ${6:-0}, jsonb_build_object('id','$4','status','booked'), jsonb_build_object('id','$5'))"
}
eq "claim 09:00 succeeds" "$(claim $OWNER 09:00 10:00 rq1 rs1)" '{"ok": true}'
eq "identical start is slot_taken" "$(claim $OWNER 09:00 10:00 rq2 rs2)" '{"ok": false, "error": "slot_taken"}'
eq "overlapping 09:30 is slot_taken" "$(claim $OWNER 09:30 10:30 rq3 rs3)" '{"ok": false, "error": "slot_taken"}'
eq "disjoint 11:00 succeeds" "$(claim $OWNER 11:00 12:00 rq4 rs4)" '{"ok": true}'
eq "no orphan rows from the failed claims" "$(pq -c "select count(*) from public.\"bookingRequests\" where id in ('rq2','rq3')")" "0"

echo "== adopted token path (extensions.digest at runtime)"
pq -q -c "select public.admin_booking_link('$OWNER','rotate','44444444-4444-4444-4444-444444444444','h1',null,null, encode(extensions.digest('newtok','sha256'),'hex'), '{\"ok\":true}'::jsonb)" >/dev/null
r=$(pq -c "select public.claim_booking_slot('$OWNER','newtok','$D','13:00','14:00', ('$D 13:00')::timestamptz, ('$D 14:00')::timestamptz, 60, 0, '{\"id\":\"rq5\"}', '{\"id\":\"rs5\"}')")
eq "adopted token hash claim succeeds" "$r" '{"ok": true}'
r=$(pq -c "select public.claim_booking_slot('$OWNER','tok','$D','15:00','16:00', ('$D 15:00')::timestamptz, ('$D 16:00')::timestamptz, 60, 0, '{\"id\":\"rq6\"}', '{\"id\":\"rs6\"}')")
eq "old blob token is auth-inert after adoption" "$r" '{"ok": false, "error": "slot_taken"}'
r=$(pq -c "select public.admin_portal_token('$OWNER','nocust','mint',null,'h',null,'x','{\"ok\":true}'::jsonb)")
eq "portal admin reaches ownership check (not_found)" "$r" '{"ok": false, "error": "not_found"}'
pq -q -c "insert into public.customers (id, user_id) values ('cu1','$OWNER')" >/dev/null
r=$(pq -c "select public.admin_portal_token('$OWNER','cu1','mint','55555555-5555-5555-5555-555555555555','h',null,encode(extensions.digest('ptok','sha256'),'hex'),'{\"ok\":true}'::jsonb) ->> 'decision'")
eq "portal mint commits" "$r" "committed"
r=$(pq -c "select public.admin_portal_token('$OWNER','cu1','mint','66666666-6666-6666-6666-666666666666','h2',null,encode(extensions.digest('ptok2','sha256'),'hex'),'{\"ok\":true}'::jsonb) ->> 'error'")
eq "portal second mint is already_exists" "$r" "already_exists"

echo "== P12-025 writer fence vs claim (two real sessions)"
# A fresh owner with an empty calendar so the only conflict is the raced write.
pq -q -c "insert into auth.users values ('77777777-7777-7777-7777-777777777777')" >/dev/null
RO=77777777-7777-7777-7777-777777777777
pq -q -c "insert into public.settings (user_id, data) select '$RO', data from public.settings where user_id = '$OWNER'" >/dev/null
elapsed() { # millis since $1 (epoch ms)
  echo $(( $(python3 -c 'import time;print(int(time.time()*1000))') - $1 ))
}
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

# 1. A device job write is in flight (not yet committed) when a claim for an
# overlapping slot arrives. Without the fence the claim reads the old jobs and
# succeeds (overbook). With it the claim waits for the write, then sees it.
( pq -q -c "begin; select set_config('request.jwt.claim.sub','$RO', true); set local role authenticated;
  insert into public.jobs (id, user_id, data) values ('jw1','$RO', jsonb_build_object('scheduledDate','$D','scheduledStartTime','09:00','scheduledEndTime','10:00','status','scheduled'));
  select pg_sleep(2); commit;" >/dev/null 2>"$TMP/wa" ) &
WPID=$!
sleep 0.6
T0=$(now_ms)
r=$(claim $RO 09:00 10:00 rqf1 rsf1)
EL=$(elapsed "$T0")
wait $WPID
eq "claim behind an in-flight job write is slot_taken" "$r" '{"ok": false, "error": "slot_taken"}'
[ "$EL" -ge 1000 ] && ok "claim waited for the job write (${EL} ms)" || bad "claim did not wait for the in-flight write (${EL} ms)"
[ ! -s "$TMP/wa" ] || bad "job write session errored: $(head -2 "$TMP/wa")"

# 2. The reverse: a claim holds the owner lock mid-transaction; a device
# settings write arrives and must wait for the claim to commit.
RO2=88888888-8888-8888-8888-888888888888
pq -q -c "insert into auth.users values ('$RO2')" >/dev/null
pq -q -c "insert into public.settings (user_id, data) select '$RO2', data from public.settings where user_id = '$OWNER'" >/dev/null
( pq -q -c "begin; select public.claim_booking_slot('$RO2','tok','$D','09:00','10:00', ('$D 09:00')::timestamptz, ('$D 10:00')::timestamptz, 60, 0, '{\"id\":\"rqr1\"}', '{\"id\":\"rsr1\"}'); select pg_sleep(2); commit;" >/dev/null 2>&1 ) &
CPID=$!
sleep 0.6
T0=$(now_ms)
pq -q -c "begin; select set_config('request.jwt.claim.sub','$RO2', true); set local role authenticated; update public.settings set data = data || '{\"x\":1}' where user_id = '$RO2'; commit;" >/dev/null 2>"$TMP/wb"
EL=$(elapsed "$T0")
wait $CPID
[ "$EL" -ge 1000 ] && ok "settings write waited for the in-flight claim (${EL} ms)" || bad "settings write did not wait for the claim (${EL} ms)"
[ ! -s "$TMP/wb" ] || bad "settings write errored: $(head -2 "$TMP/wb")"

# 3. A service_role writer (no auth.uid) is fenced by the row trigger.
RO3=99999999-9999-9999-9999-999999999999
pq -q -c "insert into auth.users values ('$RO3')" >/dev/null
pq -q -c "insert into public.settings (user_id, data) select '$RO3', data from public.settings where user_id = '$OWNER'" >/dev/null
( pq -q -c "begin; select public.claim_booking_slot('$RO3','tok','$D','09:00','10:00', ('$D 09:00')::timestamptz, ('$D 10:00')::timestamptz, 60, 0, '{\"id\":\"rqs1\"}', '{\"id\":\"rss1\"}'); select pg_sleep(2); commit;" >/dev/null 2>&1 ) &
CPID=$!
sleep 0.6
T0=$(now_ms)
pq -q -c "begin; set local role service_role; insert into public.jobs (id, user_id, data) values ('js1','$RO3','{}'); commit;" >/dev/null 2>"$TMP/wc"
EL=$(elapsed "$T0")
wait $CPID
[ "$EL" -ge 1000 ] && ok "service_role job write waited for the claim (${EL} ms)" || bad "service_role write was not fenced (${EL} ms)"

echo "== P12-025 lock order (no deadlock) and claim races"
# Overlapping multi-row writers plus claims and transitions, all for one owner,
# run together; any deadlock surfaces as SQLSTATE 40P01 in the logs.
RO4=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
pq -q -c "insert into auth.users values ('$RO4')" >/dev/null
pq -q -c "insert into public.settings (user_id, data) select '$RO4', data from public.settings where user_id = '$OWNER'" >/dev/null
pq -q -c "insert into public.jobs (id, user_id) select 'j4_'||g, '$RO4' from generate_series(1,40) g" >/dev/null
pq -q -c "insert into public.\"bookingRequests\" (id, user_id, data) values ('bt1','$RO4','{\"status\":\"booked\",\"manageToken\":\"mt\"}'), ('bt2','$RO4','{\"status\":\"booked\",\"manageToken\":\"mt2\"}')" >/dev/null
pq -q -c "insert into public.booking_reservations (id, user_id, request_id, slot_date, slot_start, slot_end, slot_start_utc, slot_end_utc) values ('rsv_bt1','$RO4','bt1','$D','16:00','17:00', now(), now())" >/dev/null 2>&1
: > "$TMP/dl"
for i in 1 2 3 4; do
  ( for n in 1 2 3 4 5; do
      pq -q -c "begin; select set_config('request.jwt.claim.sub','$RO4', true); set local role authenticated; update public.jobs set data = jsonb_build_object('n', $i$n) where id between 'j4_1' and 'j4_9'; commit;" >/dev/null 2>>"$TMP/dl"
    done ) &
done
( for n in 1 2 3 4 5 6 7 8; do
    pq -c "select public.transition_booking('bt1','$RO4',null,array['booked','confirmed'],'confirmed','[]'::jsonb,false,null)" >/dev/null 2>>"$TMP/dl"
    pq -c "select public.transition_booking('bt2',null,'mt2',array['booked','confirmed'],'confirmed','[]'::jsonb,false,null)" >/dev/null 2>>"$TMP/dl"
    claim $RO4 10:00 11:00 "rqd$n" "rsd$n" >/dev/null 2>>"$TMP/dl"
  done ) &
wait
if grep -q -i "deadlock" "$TMP/dl" "$TMP/pg.log"; then bad "deadlock detected: $(grep -i deadlock "$TMP/dl" "$TMP/pg.log" | head -2)"; else ok "no deadlock across overlapping writers, claims and transitions"; fi
[ ! -s "$TMP/dl" ] && ok "every concurrent statement succeeded" || bad "concurrent statement errors: $(head -3 "$TMP/dl")"

# Claim races (concurrency script cases 1, 2, 4, 5), run as true simultaneous sessions.
RO5=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
pq -q -c "insert into auth.users values ('$RO5')" >/dev/null
pq -q -c "insert into public.settings (user_id, data) select '$RO5', data from public.settings where user_id = '$OWNER'" >/dev/null
claim $RO5 09:00 10:00 rc1 rcs1 > "$TMP/c1" &
claim $RO5 09:00 10:00 rc2 rcs2 > "$TMP/c2" &
claim $RO5 09:30 10:30 rc3 rcs3 > "$TMP/c3" &
wait
WIN=$(cat "$TMP/c1" "$TMP/c2" "$TMP/c3" | grep -c '"ok": true')
eq "three racing overlapping claims: exactly one winner" "$WIN" "1"
eq "exactly one booked reservation for the racing slot" "$(pq -c "select count(*) from public.booking_reservations where user_id='$RO5' and status='booked'")" "1"
claim $RO5 11:00 12:00 rc4 rcs4 > "$TMP/c4" &
claim $RO5 13:00 14:00 rc5 rcs5 > "$TMP/c5" &
wait
eq "disjoint racing claims both win" "$(cat "$TMP/c4" "$TMP/c5" | grep -c '"ok": true')" "2"
# Confirm-vs-cancel on one booking: one wins, the other sees invalid_state.
pq -q -c "insert into public.\"bookingRequests\" (id, user_id, data) values ('bt3','$RO5','{\"status\":\"booked\",\"manageToken\":\"m3\"}')" >/dev/null
pq -c "select public.transition_booking('bt3','$RO5',null,array['booked'],'confirmed','[{\"a\":1}]'::jsonb,false,null)" > "$TMP/t1" &
pq -c "select public.transition_booking('bt3',null,'m3',array['booked'],'cancelled','[{\"a\":2}]'::jsonb,true,null)" > "$TMP/t2" &
wait
eq "confirm-vs-cancel: exactly one transition wins" "$(cat "$TMP/t1" "$TMP/t2" | grep -c '"ok": true')" "1"
eq "confirm-vs-cancel: exactly one history entry appended" "$(pq -c "select jsonb_array_length(data->'history') from public.\"bookingRequests\" where id='bt3'")" "1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
