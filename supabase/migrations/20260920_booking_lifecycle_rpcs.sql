-- 20260920_booking_lifecycle_rpcs.sql
--
-- Task 8.04 — Atomic reservations and booking lifecycle (contract decisions
-- §2 verbatim: G1/G2). Two `security definer` RPCs plus helpers, and (P12-025)
-- write-fence triggers on `jobs` and `settings` that take the same owner lock.
-- No table rewrites, no column changes, no RLS changes. The existing
-- partial unique index `booking_reservations_active_slot` is KEPT as the
-- identical-start backstop (§10 step 1); the RPCs add the interval/buffer
-- serialization the index cannot express.
--
-- Lock ordering (§2.3): every function takes the per-owner serialization lock
-- FIRST (`pg_advisory_xact_lock` on `booking-owner:<user_id>`), before any row
-- lock (transition_booking looks the owner up without locking the row), then touches
-- `booking_reservations` → `"bookingRequests"` → `settings`/`jobs` blob reads,
-- never in reverse. Advisory-lock rationale (ownership): the §2.1 sentinel
-- row lives in `booking_link_state`, which task 8.05 owns. Until 8.05 lands,
-- the advisory lock provides the identical per-owner mutual exclusion with
-- zero cross-task tables; 8.05 may re-point the ordering root at the sentinel
-- row lock without changing these signatures or the JS callers.
--
-- Token authority (§3/§5): pre-adoption the settings blob is authoritative
-- (today's behavior verbatim). The claim function additionally honors an
-- ADOPTED `booking_link_state` row when that table exists (adoption-gated
-- dual read, §10 step 3): `to_regclass` guard, so this file deploys cleanly
-- before 8.05. The adopted branch compares
-- `encode(extensions.digest(p_token,'sha256'),'hex')` (pgcrypto — Supabase
-- installs it in the `extensions` schema, so the call is schema-qualified; the verify script asserts its presence) and requires
-- `enabled`. Post-adoption blob writes stay auth-inert by construction: the
-- adopted branch never reads the blob token.
--
-- Buffer predicate (§2.4, exact): candidate `[start, start+duration)` conflicts
-- with busy `[bStart, bEnd)` iff
--   `start < bEnd + buffer AND bStart < start + duration + buffer`,
-- busy ends via `blockWindow` (missing end → `max(laborHours,1h)`, capped at
-- midnight), both sides clipped to `[0,1440)`. Terminal statuses
-- (`complete/invoiced/paid/declined`) and missing-start jobs never block.
-- Touching endpoints are legal (strict inequality).
--
-- Error envelope: every function RETURNS jsonb `{ok:true,...}` or
-- `{ok:false,error:<code>,status?}` with HTTP 200 at the PostgREST layer, so
-- JS never couples to PostgREST error shapes. Uniqueness violations are
-- caught INSIDE the function (savepoint) and mapped to `slot_taken` — the
-- backstop index stays deliberate, never an exception. A transport 404 on
-- `/rpc/<fn>` unambiguously means "function not deployed" (these functions
-- never answer 404 themselves; unknown records are `not_found` inside 200).
--
-- NO DEPLOYMENT here (task 8.04 gate): apply in the Supabase SQL editor only
-- when the coordinator schedules it, AFTER the verify script passes.
-- Rollback: `drop function if exists public.claim_booking_slot(...)` and
-- `drop function if exists public.transition_booking(...)` — pre-adoption the
-- Workers dual-read falls back to the legacy split path byte-identically.
-- Idempotent — safe to re-run.
--
-- RELEASE GATE: run `supabase/verify/booking_lifecycle_rpcs.sql` first, then
-- the competing-session proof in `supabase/verify/booking_lifecycle_concurrency.sh`
-- (deferred to Phase 12 hardware if no local PG is available — never label a
-- mocked 409 as race proof).

-- ── helpers ────────────────────────────────────────────────────────────────

create or replace function public.booking_to_minutes(t text)
returns integer
language sql immutable
set search_path = pg_catalog, public
as $$
  select (split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int);
$$;

create or replace function public.booking_take_lock(p_user_id uuid)
returns void
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  -- Per-owner serialization root (§2.3 ordering root until 8.05 re-points it
  -- at the booking_link_state sentinel row). Transaction-scoped: released at
  -- commit/rollback, never held across requests.
  perform pg_advisory_xact_lock(hashtext('booking-owner:' || p_user_id::text));
end;
$$;

-- Defense in depth behind the grants below (P12-023): these functions take the
-- owner id as a parameter and trust it, so they must only ever run for the
-- server (Worker, service_role key) or a direct admin session. If a grant ever
-- regressed and an API client reached one, PostgREST would carry that client's
-- JWT role here; refuse it. The revokes are the real control, not this check.
create or replace function public.booking_is_client_caller()
returns boolean
language sql stable
set search_path = pg_catalog, public
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    nullif(current_setting('request.jwt.claim.role', true), ''),
    ''
  ) in ('anon', 'authenticated');
$$;

-- ── writer fence (P12-025, fix plan F2) ────────────────────────────────────
-- claim_booking_slot reads `settings` and `jobs` under the owner lock, but
-- device sync writes those tables with plain PostgREST upserts that never took
-- it, so a schedule or availability change could commit around a claim. These
-- triggers make every write to either table take the SAME owner lock, so a
-- write and a claim serialize in either order: the claim sees every committed
-- write, and a write that arrives mid-claim waits for the claim to commit.
--
-- Statement trigger: takes the lock for auth.uid() (every device write) BEFORE
-- any row lock, so two writers touching overlapping rows cannot deadlock on
-- (row lock, owner lock) vs (owner lock, row lock).
-- Row trigger: backstop for writers with no auth.uid() (service_role: webhooks,
-- server stores). It is a no-op re-lock when the statement trigger already
-- took the same lock (advisory xact locks are re-entrant).
-- Both are `security definer` because the writer is `authenticated`, which has
-- no EXECUTE on booking_take_lock. `bookingRequests` is deliberately NOT fenced:
-- its row lock precedes any trigger, so fencing it would reverse the order.

create or replace function public.booking_fence_statement()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is not null then
    perform public.booking_take_lock(auth.uid());
  end if;
  return null;
end;
$$;

create or replace function public.booking_fence_row()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  perform public.booking_take_lock(new.user_id);
  return new;
end;
$$;

drop trigger if exists booking_fence_statement_trg on public.settings;
create trigger booking_fence_statement_trg
  before insert or update on public.settings
  for each statement execute function public.booking_fence_statement();
drop trigger if exists booking_fence_row_trg on public.settings;
create trigger booking_fence_row_trg
  before insert or update on public.settings
  for each row execute function public.booking_fence_row();

drop trigger if exists booking_fence_statement_trg on public.jobs;
create trigger booking_fence_statement_trg
  before insert or update on public.jobs
  for each statement execute function public.booking_fence_statement();
drop trigger if exists booking_fence_row_trg on public.jobs;
create trigger booking_fence_row_trg
  before insert or update on public.jobs
  for each row execute function public.booking_fence_row();

-- ── G1: atomic claim ───────────────────────────────────────────────────────

create or replace function public.claim_booking_slot(
  p_user_id uuid,
  p_token text,
  p_slot_date text,
  p_slot_start text,
  p_slot_end text,
  p_slot_start_utc timestamptz,
  p_slot_end_utc timestamptz,
  p_duration_minutes integer,
  p_buffer_minutes integer,
  p_request jsonb,
  p_reservation jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_settings jsonb;
  v_sched jsonb;
  v_enabled boolean;
  v_zone text;
  v_work_start integer;
  v_work_end integer;
  v_duration integer;
  v_buffer integer;
  v_lead numeric;
  v_window numeric;
  v_workdays integer[];
  v_dow integer;
  v_blackout boolean;
  v_start_min integer;
  v_end_min integer;
  v_rec record;
  v_busy_start integer;
  v_busy_end integer;
  v_adopted_exists boolean := false;
begin
  if public.booking_is_client_caller() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  perform public.booking_take_lock(p_user_id);

  -- Settings blob read INSIDE the snapshot, under the owner lock (§2.5): a
  -- concurrent device job/settings save serializes behind this claim.
  select s.data into v_settings
    from public.settings s
   where s.user_id = p_user_id;
  if v_settings is null then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end if;

  -- Adoption-gated authority (§3/§5): an adopted link-state row replaces the
  -- blob token for AUTH decisions. Blob writes stay auth-inert post-adoption.
  if to_regclass('public.booking_link_state') is not null then
    select true into v_adopted_exists
      from public.booking_link_state b
     where b.user_id = p_user_id
       and b.adopted_at is not null;
    if v_adopted_exists then
      -- 8.05 contract: hash match + enabled, else indistinguishable 404.
      -- Public claim maps unknown/disabled to slot_taken (the page remedy —
      -- refresh the slot list — is identical; no oracle either way).
      perform 1
        from public.booking_link_state b
       where b.user_id = p_user_id
         and b.enabled = true
         and b.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
      if not found then
        return jsonb_build_object('ok', false, 'error', 'slot_taken');
      end if;
    end if;
  end if;

  if not coalesce(v_adopted_exists, false) then
    -- Pre-adoption authority verbatim: blob token + enabled gate, unknown and
    -- disabled indistinguishable.
    if (v_settings -> 'bookingLink' ->> 'token') is distinct from p_token
       or coalesce((v_settings -> 'bookingLink' ->> 'enabled'), 'false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', 'slot_taken');
    end if;
  end if;

  -- Resolved schedule with RN fallbacks (resolveSchedule twin: defaults when
  -- invalid, never an automatic rewrite — this only READS). Non-object
  -- schedule blobs fall back to defaults (device-written junk fails closed).
  v_sched := case when jsonb_typeof(v_settings -> 'schedule') = 'object'
    then v_settings -> 'schedule' else '{}'::jsonb end;
  v_enabled := coalesce((v_sched ->> 'bookableSlotsEnabled') = 'true', false);
  v_zone := nullif(v_sched ->> 'timeZone', '');
  if not v_enabled or v_zone is null then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end if;

  v_work_start := 480; v_work_end := 1020; -- 08:00–17:00 defaults
  if v_sched ->> 'workDayStart' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     and v_sched ->> 'workDayEnd' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     and (v_sched ->> 'workDayStart') < (v_sched ->> 'workDayEnd') then
    v_work_start := public.booking_to_minutes(v_sched ->> 'workDayStart');
    v_work_end := public.booking_to_minutes(v_sched ->> 'workDayEnd');
  end if;
  v_duration := case
    when (v_sched ->> 'defaultDurationMinutes') ~ '^[0-9]+$'
     and (v_sched ->> 'defaultDurationMinutes')::int > 0
    then (v_sched ->> 'defaultDurationMinutes')::int else 60 end;
  v_buffer := case
    when (v_sched ->> 'bufferMinutes') ~ '^[0-9]+$'
    then (v_sched ->> 'bufferMinutes')::int else 0 end;
  v_lead := case
    when (v_sched ->> 'slotLeadHours') ~ '^[0-9]+(\.[0-9]+)?$'
    then (v_sched ->> 'slotLeadHours')::numeric else 24 end;
  v_window := case
    when (v_sched ->> 'slotWindowDays') ~ '^[0-9]+$'
     and (v_sched ->> 'slotWindowDays')::int > 0
    then (v_sched ->> 'slotWindowDays')::numeric else 14 end;

  -- Buffer/duration edits between offer and claim are honored at claim time
  -- (§2.5): a stale offer fails closed instead of overbooking.
  if v_duration <> p_duration_minutes or v_buffer <> p_buffer_minutes then
    return jsonb_build_object('ok', false, 'error', 'slot_changed');
  end if;

  -- Workday (ISO Mon=1), blackout (inclusive), grid, lead, horizon, window.
  v_dow := extract(isodow from p_slot_date::date)::int;
  select case when jsonb_typeof(v_sched -> 'workDays') = 'array' then coalesce(
      (select array_agg(x::int order by x::int) from jsonb_array_elements_text(v_sched -> 'workDays') x
        where x ~ '^[1-7]$'),
      array[1,2,3,4,5,6]) else array[1,2,3,4,5,6] end
    into v_workdays;
  if not (v_dow = any (v_workdays)) then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end if;
  select exists (
    select 1 from jsonb_array_elements(
      case when jsonb_typeof(v_sched -> 'blackouts') = 'array'
        then v_sched -> 'blackouts' else '[]'::jsonb end) b
     where (b ->> 'start') <= p_slot_date and p_slot_date <= (b ->> 'end')
  ) into v_blackout;
  if v_blackout then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end if;

  v_start_min := public.booking_to_minutes(p_slot_start);
  v_end_min := public.booking_to_minutes(p_slot_end);
  if (v_start_min % 30) <> 0
     or v_start_min < v_work_start
     or v_start_min + p_duration_minutes > v_work_end
     or p_slot_start_utc < now() + (v_lead || ' hours')::interval
     or p_slot_start_utc > now() + (v_window || ' days')::interval then
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end if;

  -- In-txn busy recompute (§2.1 step 3, §2.4 predicate): live jobs plus
  -- status='booked' reservations, buffer-padded, clipped to [0,1440).
  -- Jobs (blob table, read in-snapshot; terminal + missing-start never block).
  for v_rec in
    select (j.data ->> 'scheduledStartTime') as s,
           (j.data ->> 'scheduledEndTime') as e,
           case when coalesce(j.data ->> 'laborHours', '') ~ '^[0-9]+(\.[0-9]+)?$'
             then (j.data ->> 'laborHours')::numeric else 0 end as labor
      from public.jobs j
     where j.user_id = p_user_id
       and coalesce(j.deleted, false) = false
       and (j.data ->> 'scheduledDate') = p_slot_date
       and nullif(j.data ->> 'scheduledStartTime', '') is not null
       and coalesce(j.data ->> 'status', '') not in ('complete','invoiced','paid','declined')
  loop
    v_busy_start := public.booking_to_minutes(v_rec.s);
    if v_rec.e ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      v_busy_end := public.booking_to_minutes(v_rec.e);
    else
      v_busy_end := least(v_busy_start + (greatest(v_rec.labor, 1) * 60)::int, 1440);
    end if;
    v_busy_start := greatest(0, v_busy_start - v_buffer);
    v_busy_end := least(1440, v_busy_end + v_buffer);
    if v_start_min < v_busy_end and v_busy_start < v_start_min + p_duration_minutes then
      return jsonb_build_object('ok', false, 'error', 'slot_taken');
    end if;
  end loop;

  -- Active reservations (same predicate; the backstop unique index additionally
  -- serializes identical starts below us).
  for v_rec in
    select r.slot_start as s, r.slot_end as e
      from public.booking_reservations r
     where r.user_id = p_user_id
       and r.status = 'booked'
       and r.slot_date = p_slot_date
  loop
    v_busy_start := greatest(0, public.booking_to_minutes(v_rec.s) - v_buffer);
    v_busy_end := least(1440, public.booking_to_minutes(v_rec.e) + v_buffer);
    if v_start_min < v_busy_end and v_busy_start < v_start_min + p_duration_minutes then
      return jsonb_build_object('ok', false, 'error', 'slot_taken');
    end if;
  end loop;

  -- Atomic dual insert (§2.1 step 4): both rows or neither — no compensation
  -- delete, no orphan hold. Any error below rolls back the whole claim.
  begin
    insert into public.booking_reservations (
      id, user_id, request_id, slot_date, slot_start, slot_end,
      slot_start_utc, slot_end_utc, status
    ) values (
      p_reservation ->> 'id', p_user_id, p_request ->> 'id',
      p_slot_date, p_slot_start, p_slot_end,
      p_slot_start_utc, p_slot_end_utc, 'booked'
    );
    insert into public."bookingRequests" (id, user_id, data, deleted)
    values (p_request ->> 'id', p_user_id, p_request, false);
  exception when unique_violation then
    -- Backstop index hit (identical-start race): deliberate 409, nothing held.
    return jsonb_build_object('ok', false, 'error', 'slot_taken');
  end;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.claim_booking_slot(uuid, text, text, text, text, timestamptz, timestamptz, integer, integer, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.claim_booking_slot(uuid, text, text, text, text, timestamptz, timestamptz, integer, integer, jsonb, jsonb) to service_role;

-- ── G2: atomic lifecycle transition ────────────────────────────────────────

create or replace function public.transition_booking(
  p_request_id text,
  p_owner_id uuid,
  p_manage_token text,
  p_expected text[],
  p_target text,
  p_history jsonb,
  p_release boolean,
  p_proof jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_row record;
  v_owner uuid;
  v_current text;
  v_data jsonb;
  v_hist jsonb;
  v_job record;
begin
  if public.booking_is_client_caller() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if (p_owner_id is null) = (p_manage_token is null) then
    return jsonb_build_object('ok', false, 'error', 'invalid_args');
  end if;

  -- Owner lock BEFORE any row lock (§2.3, P12-025). The customer path only has
  -- the request id, so learn the owner with a plain read (no row lock), take
  -- the owner lock, then re-read the row FOR UPDATE under it. No lock is ever
  -- held across the JS boundary — the whole function is one txn.
  select r.user_id into v_owner
    from public."bookingRequests" r
   where r.id = p_request_id
     and coalesce(r.deleted, false) = false;
  if v_owner is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  perform public.booking_take_lock(v_owner);

  -- Authoritative read under the owner lock (covers a writer that committed
  -- between the lookup and the lock grant).
  select r.user_id, r.data into v_row
    from public."bookingRequests" r
   where r.id = p_request_id
     and coalesce(r.deleted, false) = false
     for update;
  if v_row.user_id is null or v_row.user_id is distinct from v_owner then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Credential gate with owner-404 isolation (foreign = unknown, no oracle):
  -- owner path checks user_id, customer path checks the per-booking capability.
  if p_owner_id is not null then
    if v_row.user_id is distinct from p_owner_id then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
  else
    if (v_row.data ->> 'manageToken') is distinct from p_manage_token then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
  end if;

  -- Expected-state predicate IN the statement's transaction (§2.2): zero
  -- match → 409 with current status echoed for refresh-free reconciliation.
  v_current := v_row.data ->> 'status';
  if not (v_current = any (p_expected)) then
    return jsonb_build_object('ok', false, 'error', 'invalid_state', 'status', v_current);
  end if;

  -- Replacement-schedule publication proof (§7 steps 2–3): the job blob must
  -- still carry (date, start) with updated_at >= proof.updatedAt, else 409
  -- schedule_changed and the hold is NOT released. NULL proof = legacy call
  -- (L2 compat gap, accepted): transition proceeds unverified.
  if p_proof is not null then
    select j.data, j.updated_at into v_job
      from public.jobs j
     where j.id = (p_proof ->> 'jobId')
       and j.user_id = v_row.user_id
       and coalesce(j.deleted, false) = false;
    if v_job.data is null
       or (v_job.data ->> 'scheduledDate') is distinct from (p_proof ->> 'date')
       or (v_job.data ->> 'scheduledStartTime') is distinct from (p_proof ->> 'start')
       or v_job.updated_at < (p_proof ->> 'updatedAt')::timestamptz then
      return jsonb_build_object('ok', false, 'error', 'schedule_changed', 'status', v_current);
    end if;
  end if;

  -- Order: release the reservation BEFORE patching the request (G2-09 pinned
  -- order — if the patch below failed, the slot is merely re-offerable early;
  -- the reverse could show a terminal status while the slot stays held).
  if p_release then
    update public.booking_reservations
       set status = 'cancelled'
     where request_id = p_request_id
       and status = 'booked';
  end if;

  -- Server-authored patch: status flip + exactly ONE appended history entry.
  -- Unknown/concurrent blob fields survive (merge, never whole-doc replace).
  v_hist := v_row.data -> 'history';
  -- A request without a history field (NULL here) starts a fresh array; NULL ||
  -- entry would otherwise write `history: null`.
  if v_hist is null or jsonb_typeof(v_hist) <> 'array' then
    v_hist := '[]'::jsonb;
  end if;
  v_data := v_row.data || jsonb_build_object(
    'status', p_target,
    'history', v_hist || p_history
  );
  update public."bookingRequests"
     set data = v_data
   where id = p_request_id;

  return jsonb_build_object('ok', true, 'status', p_target);
end;
$$;

revoke all on function public.transition_booking(text, uuid, text, text[], text, jsonb, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.transition_booking(text, uuid, text, text[], text, jsonb, boolean, jsonb) to service_role;

-- Helpers and fences: never callable through the API. booking_take_lock would
-- let any caller hold an arbitrary owner's advisory lock (P12-023). Supabase
-- grants EXECUTE on new public functions directly to anon/authenticated, which
-- `revoke ... from public` does not remove, so name the roles.
revoke all on function public.booking_take_lock(uuid) from public, anon, authenticated;
grant execute on function public.booking_take_lock(uuid) to service_role;
revoke all on function public.booking_to_minutes(text) from public, anon, authenticated;
grant execute on function public.booking_to_minutes(text) to service_role;
revoke all on function public.booking_is_client_caller() from public, anon, authenticated;
grant execute on function public.booking_is_client_caller() to service_role;
revoke all on function public.booking_fence_statement() from public, anon, authenticated;
revoke all on function public.booking_fence_row() from public, anon, authenticated;
