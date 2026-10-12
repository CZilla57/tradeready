-- 20261003_api_keys.sql
--
-- Roadmap Phase 23 — read-only open API. Spec:
-- docs/superpowers/specs/2026-10-03-open-api-design.md §2, §4, §6 (and the
-- build record §14).
--
-- ADDITIVE ONLY: three new tables and two `security definer` RPCs. No change
-- to any existing table, policy or function. The Worker's /v1 routes and
-- /api/api-keys/manage answer 503 `unavailable` until this is applied (a
-- transport 404 on either RPC means "not deployed" — fail closed).
--
-- Written, NOT applied. The owner applies it in the Supabase SQL editor
-- (staging first if one exists), then runs
-- supabase/migrations/verify/20261003_api_keys_verify.sql. Idempotent — safe
-- to re-run. Rollback: drop the two functions and three tables (in reverse
-- order); nothing else references them.
--
-- Security model:
-- - Keys are stored as sha256(raw key) hex only. The raw key exists once, in
--   the Worker's create/rotate response, and is never written anywhere — no
--   replay table holds it (unlike portal_operations).
-- - Keys are self-verifying (spec §2, §14.4a #5): the Worker tags each key
--   with an HMAC over its own api_keys.id, the owner id and its random part,
--   using a Worker secret the database never sees. So the Worker chooses the
--   new key's id and passes it to api_key_admin (p_new_key_id); the table
--   stores no tag, no secret and nothing new beyond that id.
-- - All writes are service-role only (the Worker). Clients get read-only
--   metadata: api_keys WITHOUT key_hash and the operation bookkeeping
--   columns (column-level grants), and their own api_access_log rows.
--   api_usage_counters has no client access at all (ai_usage_log precedent).
-- - Both RPCs are executable by service_role only, and additionally refuse a
--   client JWT that reaches them anyway (booking_is_client_caller logic,
--   inlined so this file has no dependency on the booking migrations).
-- - Every row cascades from auth.users, so account deletion removes keys,
--   log rows and counters in the same transaction.

-- ── tables ────────────────────────────────────────────────────────────────

create table if not exists public.api_keys (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  key_hash      text not null unique check (key_hash ~ '^[0-9a-f]{64}$'), -- sha256 hex of the raw key
  key_prefix    text not null check (char_length(key_prefix) = 12),        -- display only, "trk_" + 8
  name          text not null check (char_length(name) between 1 and 40),
  scopes        text[] not null check (
                  cardinality(scopes) between 1 and 5
                  and scopes <@ array['customers:read','jobs:read','invoices:read','expenses:read','mileage:read']::text[]),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz,                                               -- null = never
  revoked_at    timestamptz,                                               -- one-way, never cleared
  last_used_at  timestamptz,
  replaced_by   uuid references public.api_keys(id) on delete set null,
  -- Build-record additions (spec §4 was silent on how rotate keeps the
  -- lifetime choice and how a retried create is recognized):
  expiry_days   integer check (expiry_days in (90, 365)),                  -- the owner's choice; null = never; rotate reuses it
  operation_id  uuid,                                                      -- the app's create/rotate operationId (replay → 409, no secret)
  request_hash  text                                                       -- sha256 of the mutating intent, for operation_conflict
);

create index if not exists api_keys_owner_live on public.api_keys (user_id) where revoked_at is null;
create index if not exists api_keys_owner_created on public.api_keys (user_id, created_at desc);
create unique index if not exists api_keys_operation on public.api_keys (operation_id) where operation_id is not null;

create table if not exists public.api_access_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  key_id     uuid not null references public.api_keys(id) on delete cascade,
  event      text not null check (event in ('ok', 'denied', 'rate_limited', 'error')),
  route      text not null check (char_length(route) <= 120),  -- template, e.g. '/v1/invoices/:id' — never query values
  status     int  not null,
  ip         text check (ip is null or char_length(ip) <= 64), -- cf-connecting-ip only
  created_at timestamptz not null default now()
);

create index if not exists api_access_log_owner_time on public.api_access_log (user_id, created_at desc);

create table if not exists public.api_usage_counters (   -- durable per-key windows
  key_id       uuid not null references public.api_keys(id) on delete cascade,
  window_kind  text not null check (window_kind in ('minute', 'day')),
  window_start timestamptz not null,
  hits         int not null default 0,
  primary key (key_id, window_kind, window_start)
);

-- ── privileges and RLS ────────────────────────────────────────────────────
-- Hosted Supabase grants ALL on new public tables to anon/authenticated by
-- default, so every client privilege is revoked first and only the intended
-- reads are granted back.

alter table public.api_keys enable row level security;
alter table public.api_access_log enable row level security;
alter table public.api_usage_counters enable row level security;

revoke all on table public.api_keys, public.api_access_log, public.api_usage_counters
  from public, anon, authenticated;
grant select, insert, update, delete on table public.api_keys, public.api_access_log, public.api_usage_counters
  to service_role;

-- api_keys: owner reads metadata. key_hash, operation_id and request_hash
-- are not in the column grant, so a client select of them is refused.
grant select (id, user_id, key_prefix, name, scopes, created_at, expires_at, revoked_at, last_used_at, replaced_by, expiry_days)
  on public.api_keys to authenticated;
drop policy if exists "owner reads own api keys" on public.api_keys;
create policy "owner reads own api keys"
  on public.api_keys for select to authenticated
  using (auth.uid() = user_id);

-- api_access_log: owner reads their own security log.
grant select on public.api_access_log to authenticated;
drop policy if exists "owner reads own api access log" on public.api_access_log;
create policy "owner reads own api access log"
  on public.api_access_log for select to authenticated
  using (auth.uid() = user_id);

-- api_usage_counters: no client policy (deny-all).
drop policy if exists "owner reads own api usage" on public.api_usage_counters;

-- ── api_key_authorize ─────────────────────────────────────────────────────
-- One transaction per /v1 request: look the hash up; refuse a revoked or
-- expired key (logging `denied`); check and increment the durable counters
-- (60/min and 5,000/day per key, 10,000/day per owner, UTC days), refusing
-- over-limit requests with `rate_limited` and the reset time; bump
-- last_used_at at most once a minute.
--
-- Refused requests do NOT consume quota (check, then increment, under a
-- per-owner advisory lock, so concurrent calls never over-admit). `denied`
-- and `rate_limited` rows are written at most once per key per minute so a
-- client hammering with a dead key cannot grow the log without bound.
--
-- Envelope (HTTP 200 at the PostgREST layer):
--   {ok:true, userId, keyId, scopes, name, prefix, expiresAt, limit, remaining, reset}
--   {ok:false, error:'invalid_key'|'key_revoked'|'key_expired'|'forbidden'}
--   {ok:false, error:'rate_limited', retryAfter, limit, remaining, reset}
-- reset is Unix seconds; retryAfter is whole seconds (≥ 1).

create or replace function public.api_key_authorize(p_key_hash text, p_route text, p_ip text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  c_minute_limit constant integer := 60;
  c_day_limit    constant integer := 5000;
  c_owner_limit  constant integer := 10000;
  v_now          timestamptz := now();
  v_minute       timestamptz := date_trunc('minute', v_now);
  v_day          timestamptz := date_trunc('day', v_now at time zone 'UTC') at time zone 'UTC';
  v_route        text := left(coalesce(p_route, ''), 120);
  v_ip           text := nullif(left(coalesce(p_ip, ''), 64), '');
  v_key          record;
  v_minute_hits  integer;
  v_day_hits     integer;
  v_owner_hits   integer;
  v_reset        timestamptz;
begin
  if coalesce(
       nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
       nullif(current_setting('request.jwt.claim.role', true), ''),
       '') in ('anon', 'authenticated') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;

  select k.id, k.user_id, k.name, k.key_prefix, k.scopes, k.expires_at, k.revoked_at, k.last_used_at
    into v_key
    from public.api_keys k
   where k.key_hash = p_key_hash;
  if not found then
    -- Unknown hash: there is no owner to log against.
    return jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;

  if v_key.revoked_at is not null or (v_key.expires_at is not null and v_key.expires_at <= v_now) then
    if not exists (
      select 1 from public.api_access_log l
       where l.user_id = v_key.user_id and l.key_id = v_key.id
         and l.event = 'denied' and l.created_at >= v_minute
    ) then
      insert into public.api_access_log (user_id, key_id, event, route, status, ip)
      values (v_key.user_id, v_key.id, 'denied', v_route, 401, v_ip);
    end if;
    return jsonb_build_object('ok', false, 'error',
      case when v_key.revoked_at is not null then 'key_revoked' else 'key_expired' end);
  end if;

  -- Per-owner serialization: the check-then-increment below is exact under
  -- concurrent requests across all of the owner's keys.
  perform pg_advisory_xact_lock(hashtext('api-usage:' || v_key.user_id::text));

  select coalesce(sum(c.hits) filter (where c.window_kind = 'minute' and c.window_start = v_minute), 0),
         coalesce(sum(c.hits) filter (where c.window_kind = 'day' and c.window_start = v_day), 0)
    into v_minute_hits, v_day_hits
    from public.api_usage_counters c
   where c.key_id = v_key.id
     and ((c.window_kind = 'minute' and c.window_start = v_minute)
       or (c.window_kind = 'day' and c.window_start = v_day));

  select coalesce(sum(c.hits), 0) into v_owner_hits
    from public.api_usage_counters c
    join public.api_keys k on k.id = c.key_id
   where k.user_id = v_key.user_id
     and c.window_kind = 'day'
     and c.window_start = v_day;

  if v_minute_hits >= c_minute_limit or v_day_hits >= c_day_limit or v_owner_hits >= c_owner_limit then
    v_reset := case when v_minute_hits >= c_minute_limit and v_day_hits < c_day_limit and v_owner_hits < c_owner_limit
                    then v_minute + interval '1 minute'
                    else v_day + interval '1 day' end;
    if not exists (
      select 1 from public.api_access_log l
       where l.user_id = v_key.user_id and l.key_id = v_key.id
         and l.event = 'rate_limited' and l.created_at >= v_minute
    ) then
      insert into public.api_access_log (user_id, key_id, event, route, status, ip)
      values (v_key.user_id, v_key.id, 'rate_limited', v_route, 429, v_ip);
    end if;
    return jsonb_build_object(
      'ok', false,
      'error', 'rate_limited',
      'retryAfter', greatest(1, ceil(extract(epoch from (v_reset - v_now))))::integer,
      'limit', c_minute_limit,
      'remaining', 0,
      'reset', extract(epoch from v_reset)::bigint);
  end if;

  insert into public.api_usage_counters as c (key_id, window_kind, window_start, hits)
  values (v_key.id, 'minute', v_minute, 1)
  on conflict (key_id, window_kind, window_start) do update set hits = c.hits + 1
  returning c.hits into v_minute_hits;

  insert into public.api_usage_counters as c (key_id, window_kind, window_start, hits)
  values (v_key.id, 'day', v_day, 1)
  on conflict (key_id, window_kind, window_start) do update set hits = c.hits + 1;

  if v_key.last_used_at is null or v_key.last_used_at < v_now - interval '1 minute' then
    update public.api_keys set last_used_at = v_now where id = v_key.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'userId', v_key.user_id,
    'keyId', v_key.id,
    'scopes', to_jsonb(v_key.scopes),
    'name', v_key.name,
    'prefix', v_key.key_prefix,
    'expiresAt', v_key.expires_at,
    'limit', c_minute_limit,
    'remaining', greatest(0, c_minute_limit - v_minute_hits),
    'reset', extract(epoch from v_minute + interval '1 minute')::bigint);
end;
$$;

revoke all on function public.api_key_authorize(text, text, text) from public, anon, authenticated;
grant execute on function public.api_key_authorize(text, text, text) to service_role;

-- ── api_key_admin ─────────────────────────────────────────────────────────
-- create | rotate | revoke for one owner, under a per-owner advisory lock.
-- The Worker passes the new key's HASH and display prefix — never the raw
-- key. Ownership is checked here: a key id that is not the caller's is
-- `not_found`, indistinguishable from a missing one.
--
-- create: 5-live-key cap (live = not revoked, not expired, not replaced).
-- rotate: one transaction: insert the replacement (same name, scopes and
--   lifetime choice), then set the old key's replaced_by and cut its
--   expires_at to least(current, now + grace). Only a live key rotates.
--   Rotation never changes the live count, so it never fails on the cap.
-- Working-key ceiling: a key in a rotation grace window (replaced, not yet
--   expired) still authorizes, so it is bounded separately: rotating a key
--   ends its own grace predecessor immediately (one grace key per lineage),
--   and after every rotate at most c_max_grace (5) grace keys keep working;
--   the ones expiring soonest are ended now. An owner therefore never has
--   more than 5 live + 5 grace = 10 working keys, however often they rotate.
-- revoke: sets revoked_at once (never cleared); idempotent.
-- Key id: create/rotate insert the new row under p_new_key_id, the id the
--   Worker embedded (and tagged) in the raw key. It is required; a collision
--   is operation_conflict like any other unique violation.
-- Replay: create/rotate carry the app's operationId. A committed id answers
--   already_completed with the key's id and prefix (no secret exists to
--   return); the same id with a different request is operation_conflict.
--
-- Envelope: {ok:true, decision, key, previous?} | {ok:false, error, key?}
-- where key/previous are the public metadata columns (never key_hash).

-- The pre-tag signature minted keys without an id the Worker chose; drop it
-- if an earlier draft of this file created it, so only one admin RPC exists.
drop function if exists public.api_key_admin(uuid, text, uuid, text, uuid, text, text[], integer, text, text, integer);

create or replace function public.api_key_admin(
  p_user_id        uuid,
  p_action         text,
  p_operation_id   uuid,
  p_request_hash   text,
  p_key_id         uuid,
  p_name           text,
  p_scopes         text[],
  p_expiry_days    integer,
  p_key_hash       text,
  p_key_prefix     text,
  p_grace_seconds  integer,
  p_new_key_id     uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  c_max_live  constant integer := 5;
  c_max_grace constant integer := 5;
  v_now       timestamptz := now();
  v_existing  record;
  v_old       public.api_keys;
  v_new       public.api_keys;
  v_live      integer;
begin
  if coalesce(
       nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
       nullif(current_setting('request.jwt.claim.role', true), ''),
       '') in ('anon', 'authenticated') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if p_user_id is null or p_action not in ('create', 'rotate', 'revoke') then
    return jsonb_build_object('ok', false, 'error', 'invalid_action');
  end if;

  perform pg_advisory_xact_lock(hashtext('api-keys:' || p_user_id::text));

  if p_action = 'revoke' then
    update public.api_keys k
       set revoked_at = coalesce(k.revoked_at, v_now)
     where k.id = p_key_id and k.user_id = p_user_id
    returning * into v_old;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    return jsonb_build_object('ok', true,
      'decision', case when v_old.revoked_at = v_now then 'committed' else 'unchanged' end,
      'key', public.api_key_public(v_old));
  end if;

  -- create / rotate need an operation id, the new key's id, hash and prefix.
  if p_operation_id is null or p_request_hash is null or p_new_key_id is null
     or p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$'
     or p_key_prefix is null or char_length(p_key_prefix) <> 12 then
    return jsonb_build_object('ok', false, 'error', 'invalid_args');
  end if;

  -- Replay BEFORE any other check: a committed operation never mints twice.
  select k.id, k.user_id, k.key_prefix, k.request_hash into v_existing
    from public.api_keys k
   where k.operation_id = p_operation_id;
  if found then
    if v_existing.user_id is distinct from p_user_id or v_existing.request_hash is distinct from p_request_hash then
      return jsonb_build_object('ok', false, 'error', 'operation_conflict');
    end if;
    return jsonb_build_object('ok', false, 'error', 'already_completed',
      'key', jsonb_build_object('id', v_existing.id, 'key_prefix', v_existing.key_prefix));
  end if;

  if p_action = 'create' then
    if p_name is null or char_length(btrim(p_name)) not between 1 and 40
       or p_scopes is null or cardinality(p_scopes) not between 1 and 5
       or not (p_scopes <@ array['customers:read','jobs:read','invoices:read','expenses:read','mileage:read']::text[])
       or (p_expiry_days is not null and p_expiry_days not in (90, 365)) then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    select count(*) into v_live
      from public.api_keys k
     where k.user_id = p_user_id
       and k.revoked_at is null
       and k.replaced_by is null
       and (k.expires_at is null or k.expires_at > v_now);
    if v_live >= c_max_live then
      return jsonb_build_object('ok', false, 'error', 'key_limit');
    end if;
    insert into public.api_keys
      (id, user_id, key_hash, key_prefix, name, scopes, expires_at, expiry_days, operation_id, request_hash)
    values
      (p_new_key_id, p_user_id, p_key_hash, p_key_prefix, btrim(p_name), p_scopes,
       case when p_expiry_days is null then null else v_now + make_interval(days => p_expiry_days) end,
       p_expiry_days, p_operation_id, p_request_hash)
    returning * into v_new;
    return jsonb_build_object('ok', true, 'decision', 'committed', 'key', public.api_key_public(v_new));
  end if;

  -- rotate
  if p_key_id is null or p_grace_seconds is null or p_grace_seconds not in (0, 86400) then
    return jsonb_build_object('ok', false, 'error', 'invalid_args');
  end if;
  select * into v_old
    from public.api_keys k
   where k.id = p_key_id and k.user_id = p_user_id
   for update;
  if not found
     or v_old.revoked_at is not null
     or v_old.replaced_by is not null
     or (v_old.expires_at is not null and v_old.expires_at <= v_now) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  insert into public.api_keys
    (id, user_id, key_hash, key_prefix, name, scopes, expires_at, expiry_days, operation_id, request_hash)
  values
    (p_new_key_id, p_user_id, p_key_hash, p_key_prefix, v_old.name, v_old.scopes,
     case when v_old.expiry_days is null then null else v_now + make_interval(days => v_old.expiry_days) end,
     v_old.expiry_days, p_operation_id, p_request_hash)
  returning * into v_new;

  -- A key still in grace behind the one being rotated ends now: one grace
  -- key per lineage.
  update public.api_keys g
     set expires_at = v_now
   where g.user_id = p_user_id
     and g.replaced_by = v_old.id
     and g.revoked_at is null
     and (g.expires_at is null or g.expires_at > v_now);

  update public.api_keys k
     set replaced_by = v_new.id,
         expires_at = case
           when k.expires_at is null or k.expires_at > v_now + make_interval(secs => p_grace_seconds)
             then v_now + make_interval(secs => p_grace_seconds)
           else k.expires_at end
   where k.id = v_old.id
  returning * into v_old;

  -- Hard bound on grace keys (a revoked replacement leaves its predecessor
  -- in grace with no live successor, so the lineage rule alone is not
  -- enough): keep the c_max_grace latest-expiring working grace keys, end
  -- the rest now.
  update public.api_keys k
     set expires_at = v_now
   where k.id in (
     select g.id
       from public.api_keys g
      where g.user_id = p_user_id
        and g.revoked_at is null
        and g.replaced_by is not null
        and g.expires_at > v_now
      order by g.expires_at desc, g.created_at desc, g.id
     offset c_max_grace);

  select * into v_old from public.api_keys k where k.id = v_old.id;

  return jsonb_build_object('ok', true, 'decision', 'committed',
    'key', public.api_key_public(v_new), 'previous', public.api_key_public(v_old));
exception when unique_violation then
  -- A racing create/rotate with the same operation id (the advisory lock
  -- makes this a cross-owner collision only), or a key-hash or key-id
  -- collision.
  return jsonb_build_object('ok', false, 'error', 'operation_conflict');
end;
$$;

-- The public metadata projection used by api_key_admin envelopes. Never
-- includes key_hash, operation_id or request_hash.
create or replace function public.api_key_public(k public.api_keys)
returns jsonb
language sql
immutable
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'id', k.id,
    'name', k.name,
    'key_prefix', k.key_prefix,
    'scopes', to_jsonb(k.scopes),
    'created_at', k.created_at,
    'expires_at', k.expires_at,
    'revoked_at', k.revoked_at,
    'last_used_at', k.last_used_at,
    'replaced_by', k.replaced_by);
$$;

revoke all on function public.api_key_public(public.api_keys) from public, anon, authenticated;
grant execute on function public.api_key_public(public.api_keys) to service_role;

revoke all on function public.api_key_admin(uuid, text, uuid, text, uuid, text, text[], integer, text, text, integer, uuid)
  from public, anon, authenticated;
grant execute on function public.api_key_admin(uuid, text, uuid, text, uuid, text, text[], integer, text, text, integer, uuid)
  to service_role;
