#!/bin/sh
# supabase/verify/local/api_keys.sh
#
# Compiles 20261003_api_keys.sql (Roadmap Phase 23, read-only open API) on a
# THROWAWAY local PostgreSQL and exercises both RPCs with real sessions:
# grants, column privileges, RLS, the 5-key cap, the grace-key ceiling, rotate/revoke/replay, the
# denied-log throttle, and the per-key minute counter under 70 concurrent
# callers (exactly 60 admitted). Same harness as run.sh; it does NOT replace
# running supabase/migrations/verify/20261003_api_keys_verify.sql on the
# hosted project after the owner applies the migration.
#
# Usage:  sh supabase/verify/local/api_keys.sh     (needs PostgreSQL 14+ on PATH)
# It starts its own cluster in a temp dir on port 54331 and removes it at exit.
# Never point it at a real database.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MIG="$HERE/../../migrations"
PORT=${PGPORT_SCRATCH_API:-54331}
export LC_ALL=${LC_ALL:-en_US.UTF-8}
for d in /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@17/bin /usr/local/opt/postgresql@16/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
command -v initdb >/dev/null || { echo "initdb not found: install PostgreSQL (brew install postgresql@16)"; exit 2; }

TMP=$(mktemp -d)
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust >/dev/null || exit 2
pg_ctl -D "$TMP/data" -o "-p $PORT -c unix_socket_directories= -c max_connections=200" -l "$TMP/pg.log" -w start >/dev/null || { cat "$TMP/pg.log"; exit 2; }

pq() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d scratch -X -At -v ON_ERROR_STOP=1 "$@"; }
psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -X -q -c "create database scratch" >/dev/null

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

OWNER=11111111-1111-1111-1111-111111111111
OTHER=22222222-2222-2222-2222-222222222222
h() { echo "encode(extensions.digest('$1','sha256'),'hex')"; }
op() { printf '00000000-0000-4000-8000-%012d' "$1"; }
admin() { # action op_n key_id name scopes expiry_days hash_seed prefix grace [owner]
  # The request hash covers the whole intent, like the Worker's requestHash.
  rh="md5(concat_ws('|', '$1', $3::text, $4::text, $5::text, $6::text, $9::text))"
  [ "$2" = null ] && rh=null
  pq -c "select public.api_key_admin('${10:-$OWNER}', '$1', $2, $rh, $3, $4, $5, $6, $7, $8, $9)"
}

echo "== compile and re-run"
pq -q -f "$HERE/bootstrap.sql" >/dev/null 2>&1 || { echo "bootstrap failed"; exit 2; }
for i in 1 2; do
  if pq -q -f "$MIG/20261003_api_keys.sql" >/dev/null 2>"$TMP/err"; then ok "migration applies (run $i)"; else bad "migration run $i: $(head -3 "$TMP/err")"; fi
done

echo "== hosted verify SQL"
if pq -f "$MIG/verify/20261003_api_keys_verify.sql" >"$TMP/v.out" 2>"$TMP/v.err"; then ok "verify SQL passes on the fresh schema"; else bad "verify SQL: $(head -3 "$TMP/v.err")"; fi
grep -q "ALL API KEY CHECKS PASSED" "$TMP/v.err" && ok "verify SQL reports ALL API KEY CHECKS PASSED" || bad "verify SQL notice missing"
# It must catch a leak: grant the hash column, expect a failure, revoke back.
pq -q -c "grant select (key_hash) on public.api_keys to authenticated" >/dev/null
pq -f "$MIG/verify/20261003_api_keys_verify.sql" >/dev/null 2>"$TMP/v2.err" && bad "verify SQL missed a key_hash grant" || ok "verify SQL flags a leaked key_hash grant"
pq -q -c "revoke select (key_hash) on public.api_keys from authenticated" >/dev/null
pq -q -c "grant execute on function public.api_key_authorize(text,text,text) to authenticated" >/dev/null
pq -f "$MIG/verify/20261003_api_keys_verify.sql" >/dev/null 2>&1 && bad "verify SQL missed a client EXECUTE grant" || ok "verify SQL flags a client EXECUTE grant"
pq -q -c "revoke execute on function public.api_key_authorize(text,text,text) from authenticated" >/dev/null

pq -q -c "insert into auth.users values ('$OWNER'), ('$OTHER')" >/dev/null

echo "== client sessions are refused"
out=$(pq -c "set role anon; select public.api_key_authorize(repeat('a',64),'/v1/jobs',null)" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "anon cannot call api_key_authorize";; *) bad "anon authorize: $out";; esac
out=$(pq -c "set role authenticated; select public.api_key_admin('$OWNER','revoke',null,null,null,null,null,null,null,null,null)" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "authenticated cannot call api_key_admin";; *) bad "authenticated admin: $out";; esac
r=$(pq -c "select set_config('request.jwt.claims', '{\"role\":\"authenticated\"}', true); select public.api_key_authorize(repeat('a',64),'/v1/jobs',null)" | tail -1)
eq "a client JWT reaching authorize anyway is refused" "$r" '{"ok": false, "error": "forbidden"}'

echo "== create, cap, replay"
r=$(admin create "'$(op 1)'" null "'  Books  '" "array['invoices:read','customers:read']" 365 "$(h k1)" "'trk_AAAAAAAA'" null)
case "$r" in *'"decision": "committed"'*) ok "create commits";; *) bad "create: $r";; esac
case "$r" in *'"name": "Books"'*) ok "create trims the name";; *) bad "create name: $r";; esac
case "$r" in *key_hash*) bad "create envelope leaks key_hash";; *) ok "create envelope carries no key_hash";; esac
r=$(admin create "'$(op 1)'" null "'  Books  '" "array['invoices:read','customers:read']" 365 "$(h k1)" "'trk_AAAAAAAA'" null)
case "$r" in *'"error": "already_completed"'*) ok "replayed create answers already_completed";; *) bad "replay: $r";; esac
case "$r" in *'"key_prefix": "trk_AAAAAAAA"'*) ok "replay carries the key prefix";; *) bad "replay prefix: $r";; esac
case "$r" in *key_hash*) bad "replay envelope leaks key_hash";; *) ok "replay envelope carries no key_hash";; esac
r=$(admin create "'$(op 1)'" null "'Other name'" "array['jobs:read']" 365 "$(h k1b)" "'trk_AAAAAAAB'" null)
eq "same operation id, different request → operation_conflict" "$r" '{"ok": false, "error": "operation_conflict"}'
for n in 2 3 4 5; do admin create "'$(op $n)'" null "'Key $n'" "array['jobs:read']" 90 "$(h k$n)" "'trk_AAAAAAA$n'" null >/dev/null; done
eq "five live keys" "$(pq -c "select count(*) from public.api_keys where user_id = '$OWNER'")" "5"
r=$(admin create "'$(op 6)'" null "'Sixth'" "array['jobs:read']" null "$(h k6)" "'trk_AAAAAAA6'" null)
eq "a sixth live key is key_limit" "$r" '{"ok": false, "error": "key_limit"}'
r=$(admin create "'$(op 7)'" null "'Bad scope'" "array['payroll:read']" null "$(h k7)" "'trk_AAAAAAA7'" null "$OTHER")
eq "an unknown scope is invalid_args" "$r" '{"ok": false, "error": "invalid_args"}'
eq "stored hash is the sha256 hex, no raw key column exists" \
  "$(pq -c "select (key_hash = $(h k1))::text || '/' || (select count(*) from information_schema.columns where table_name='api_keys' and column_name ilike '%raw%')::text from public.api_keys where operation_id = '$(op 1)'")" "true/0"

K1=$(pq -c "select id from public.api_keys where operation_id = '$(op 1)'")
K2=$(pq -c "select id from public.api_keys where operation_id = '$(op 2)'")

echo "== rotate"
r=$(admin rotate "'$(op 8)'" "'$K1'" null null null "$(h k8)" "'trk_AAAAAAA8'" 86400)
case "$r" in *'"previous"'*'"replaced_by"'*) ok "rotate returns key and previous";; *) bad "rotate: $r";; esac
eq "old key: replaced, expiring in 24h, new key inherits name/scopes/lifetime" \
  "$(pq -c "select (o.replaced_by = n.id)::text || '/' || (o.expires_at between now() + interval '23 hours 59 minutes' and now() + interval '24 hours 1 minute')::text || '/' || (n.name = o.name and n.scopes = o.scopes and n.expiry_days = o.expiry_days)::text from public.api_keys o, public.api_keys n where o.id = '$K1' and n.operation_id = '$(op 8)'")" "true/true/true"
r=$(admin create "'$(op 9)'" null "'After rotate'" "array['jobs:read']" null "$(h k9)" "'trk_AAAAAAA9'" null)
eq "a key in its rotation grace does not count toward the cap (still 5 live)" "$r" '{"ok": false, "error": "key_limit"}'
r=$(admin rotate "'$(op 10)'" "'$K1'" null null null "$(h k10)" "'trk_AAAAAA10'" 86400)
eq "an already-rotated key cannot rotate again" "$r" '{"ok": false, "error": "not_found"}'
r=$(admin rotate "'$(op 11)'" "'$K2'" null null null "$(h k11)" "'trk_AAAAAA11'" 86400 "$OTHER")
eq "another owner's key is not_found" "$r" '{"ok": false, "error": "not_found"}'
admin rotate "'$(op 12)'" "'$K2'" null null null "$(h k12)" "'trk_AAAAAA12'" 0 >/dev/null
eq "immediate rotate expires the old key now" "$(pq -c "select (expires_at <= now())::text from public.api_keys where id = '$K2'")" "true"

echo "== revoke"
K3=$(pq -c "select id from public.api_keys where operation_id = '$(op 3)'")
r=$(admin revoke null "'$K3'" null null null null null null)
case "$r" in *'"decision": "committed"'*) ok "revoke commits";; *) bad "revoke: $r";; esac
R1=$(pq -c "select revoked_at from public.api_keys where id = '$K3'")
r=$(admin revoke null "'$K3'" null null null null null null)
case "$r" in *'"decision": "unchanged"'*) ok "second revoke is unchanged";; *) bad "revoke again: $r";; esac
eq "revoked_at is one-way (not moved by the second revoke)" "$(pq -c "select revoked_at from public.api_keys where id = '$K3'")" "$R1"
r=$(admin revoke null "'$K3'" null null null null null null "$OTHER")
eq "revoking another owner's key is not_found" "$r" '{"ok": false, "error": "not_found"}'

echo "== authorize"
r=$(pq -c "select public.api_key_authorize($(h unknown), '/v1/jobs', '203.0.113.9')")
eq "unknown hash is invalid_key" "$r" '{"ok": false, "error": "invalid_key"}'
eq "unknown hash writes no log row" "$(pq -c "select count(*) from public.api_access_log")" "0"
r=$(pq -c "select public.api_key_authorize($(h k3), '/v1/jobs', '203.0.113.9') ->> 'error'")
eq "revoked key is key_revoked" "$r" "key_revoked"
pq -c "select public.api_key_authorize($(h k3), '/v1/jobs', '203.0.113.9')" >/dev/null
eq "denied is logged once per key per minute (throttled)" "$(pq -c "select count(*) || '/' || min(event) || '/' || min(route) || '/' || min(status) || '/' || min(ip) from public.api_access_log where key_id = '$K3'")" "1/denied//v1/jobs/401/203.0.113.9"
r=$(pq -c "select public.api_key_authorize($(h k2), '/v1/jobs', null) ->> 'error'")
eq "immediately-rotated key is key_expired" "$r" "key_expired"
r=$(pq -c "select public.api_key_authorize($(h k4), '/v1/jobs', null)")
case "$r" in *'"ok": true'*'"remaining": 59'*) ok "live key authorizes with 59 remaining";; *) bad "authorize: $r";; esac
case "$r" in *key_hash*) bad "authorize envelope leaks key_hash";; *) ok "authorize envelope carries no key_hash";; esac
eq "last_used_at was bumped" "$(pq -c "select (last_used_at is not null)::text from public.api_keys where key_hash = $(h k4)")" "true"
r=$(pq -c "select public.api_key_authorize($(h k1), '/v1/jobs', null) ->> 'ok'")
eq "the old key still works inside its 24h grace" "$r" "true"

echo "== concurrency: 70 parallel callers, one key, one minute"
K5H=$(pq -c "select $(h k5)")
# Avoid a minute boundary splitting the burst.
s=$(pq -c "select extract(second from now())::int"); [ "$s" -ge 50 ] && sleep $((62 - s))
i=0
while [ $i -lt 70 ]; do
  ( pq -c "select public.api_key_authorize('$K5H', '/v1/invoices', null) ->> 'ok'" > "$TMP/c.$i" 2>&1 ) &
  i=$((i+1))
done
wait
okc=$(cat "$TMP"/c.* | grep -c '^true$'); limc=$(cat "$TMP"/c.* | grep -c '^false$')
eq "exactly 60 admitted" "$okc" "60"
eq "exactly 10 rate_limited" "$limc" "10"
eq "minute counter = 60 (refused calls consume nothing)" "$(pq -c "select hits from public.api_usage_counters c join public.api_keys k on k.id = c.key_id where k.key_hash = '$K5H' and window_kind = 'minute'")" "60"
r=$(pq -c "select public.api_key_authorize('$K5H', '/v1/invoices', null)")
case "$r" in *rate_limited*retryAfter*) ok "61st call carries retryAfter";; *) bad "61st: $r";; esac
eq "rate_limited logged once per minute despite 11 refusals" "$(pq -c "select count(*) from public.api_access_log l join public.api_keys k on k.id = l.key_id where k.key_hash = '$K5H' and event = 'rate_limited'")" "1"

echo "== per-owner daily cap"
K8=$(pq -c "select id from public.api_keys where operation_id = '$(op 8)'")
pq -q -c "insert into public.api_usage_counters values ('$K8', 'day', date_trunc('day', now() at time zone 'UTC') at time zone 'UTC', 9999) on conflict (key_id, window_kind, window_start) do update set hits = 9999" >/dev/null
total=$(pq -c "select sum(hits) from public.api_usage_counters c join public.api_keys k on k.id = c.key_id where k.user_id = '$OWNER' and window_kind = 'day'")
[ "$total" -ge 10000 ] && r=$(pq -c "select public.api_key_authorize($(h k4), '/v1/jobs', null) ->> 'error'") || r="setup:$total"
eq "owner over 10,000/day is rate_limited on any key" "$r" "rate_limited"

echo "== client reads"
r=$(pq -q -c "begin; select set_config('request.jwt.claim.sub','$OWNER', true); set local role authenticated; select count(*) from public.api_keys; commit;" | sed -n 2p)
[ "$r" -ge 1 ] && ok "owner reads own key metadata ($r rows)" || bad "owner metadata read: $r"
r=$(pq -q -c "begin; select set_config('request.jwt.claim.sub','$OTHER', true); set local role authenticated; select count(*) from public.api_keys; commit;" | sed -n 2p)
eq "another owner sees none of them" "$r" "0"
out=$(pq -c "begin; select set_config('request.jwt.claim.sub','$OWNER', true); set local role authenticated; select key_hash from public.api_keys; commit;" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "owner cannot read key_hash";; *) bad "key_hash read: $out";; esac
out=$(pq -c "begin; select set_config('request.jwt.claim.sub','$OWNER', true); set local role authenticated; select count(*) from public.api_usage_counters; commit;" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "owner cannot read usage counters";; *) bad "counters read: $out";; esac
out=$(pq -c "begin; select set_config('request.jwt.claim.sub','$OWNER', true); set local role authenticated; update public.api_keys set revoked_at = null; commit;" 2>&1 >/dev/null)
case "$out" in *"permission denied"*) ok "owner cannot un-revoke (no client writes)";; *) bad "client update: $out";; esac

echo "== service_role writes the access log (the Worker's insert)"
r=$(pq -q -c "begin; set local role service_role; insert into public.api_access_log (user_id, key_id, event, route, status, ip) values ('$OWNER', '$K8', 'ok', '/v1/invoices', 200, null) returning event; commit;" | sed -n 1p)
eq "service_role inserts an ok row (identity column usable)" "$r" "ok"

echo "== working-key ceiling: grace keys are bounded (5 live + 5 grace)"
working() { pq -c "select count(*) from public.api_keys where user_id = '$OTHER' and revoked_at is null and (expires_at is null or expires_at > now())"; }
graceing() { pq -c "select count(*) from public.api_keys where user_id = '$OTHER' and revoked_at is null and replaced_by is not null and expires_at > now()"; }
keyid() { pq -c "select id from public.api_keys where operation_id = '$(op $1)'"; }
pfx() { printf 'trk_%08d' "$1"; }
G=100
r=$(admin create "'$(op $G)'" null "'Lineage'" "array['jobs:read']" 90 "$(h g$G)" "'$(pfx $G)'" null "$OTHER"); case "$r" in *committed*) ok "ceiling: lineage root created";; *) bad "ceiling create: $r";; esac
CUR=$(keyid $G); FIRST=$CUR
for n in 1 2 3 4 5 6; do
  G=$((G+1))
  r=$(admin rotate "'$(op $G)'" "'$CUR'" null null null "$(h g$G)" "'$(pfx $G)'" 86400 "$OTHER")
  case "$r" in *'"decision": "committed"'*) ;; *) bad "ceiling rotate $n: $r";; esac
  CUR=$(keyid $G)
done
eq "six rotations of one key leave 2 working keys (live + one grace predecessor)" "$(working)" "2"
eq "the first key's grace was ended when its successor rotated" "$(pq -c "select (expires_at <= now())::text from public.api_keys where id = '$FIRST'")" "true"
# A revoked replacement leaves its predecessor in grace with no live successor.
# Repeat create + rotate + revoke: the lineage rule alone would leave one
# grace key per round; the hard bound keeps it at 5.
for n in 1 2 3 4 5 6 7 8; do
  G=$((G+1)); admin create "'$(op $G)'" null "'Churn'" "array['jobs:read']" 90 "$(h g$G)" "'$(pfx $G)'" null "$OTHER" >/dev/null
  OLD=$(keyid $G); G=$((G+1))
  admin rotate "'$(op $G)'" "'$OLD'" null null null "$(h g$G)" "'$(pfx $G)'" 86400 "$OTHER" >/dev/null
  admin revoke null "'$(keyid $G)'" null null null null null null "$OTHER" >/dev/null
done
eq "create/rotate/revoke churn leaves at most 5 grace keys" "$(graceing)" "5"
eq "and 6 working keys in all (1 live + 5 grace)" "$(working)" "6"
# Fill the live cap, then rotate at the cap: rotate must not fail on it.
for n in 1 2 3 4; do G=$((G+1)); admin create "'$(op $G)'" null "'Fill'" "array['jobs:read']" 90 "$(h g$G)" "'$(pfx $G)'" null "$OTHER" >/dev/null; done
r=$(admin create "'$(op 200)'" null "'Over'" "array['jobs:read']" 90 "$(h g200)" "'$(pfx 200)'" null "$OTHER")
eq "five live keys: a sixth create is key_limit" "$r" '{"ok": false, "error": "key_limit"}'
G=$((G+1)); r=$(admin rotate "'$(op $G)'" "'$(keyid $((G-1)))'" null null null "$(h g$G)" "'$(pfx $G)'" 86400 "$OTHER")
case "$r" in *'"decision": "committed"'*) ok "rotate at the live cap still commits";; *) bad "rotate at cap: $r";; esac
eq "working keys never exceed 5 live + 5 grace" "$(pq -c "select (count(*) <= 10)::text from public.api_keys where user_id = '$OTHER' and revoked_at is null and (expires_at is null or expires_at > now())")" "true"
eq "live keys stay at 5" "$(pq -c "select count(*) from public.api_keys where user_id = '$OTHER' and revoked_at is null and replaced_by is null and (expires_at is null or expires_at > now())")" "5"

echo "== account deletion cascades"
pq -q -c "delete from auth.users where id in ('$OWNER', '$OTHER')" >/dev/null
eq "keys, log rows and counters are gone" "$(pq -c "select (select count(*) from public.api_keys) + (select count(*) from public.api_access_log) + (select count(*) from public.api_usage_counters)")" "0"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
