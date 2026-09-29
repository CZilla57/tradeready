-- 20260921_booking_admin_state.sql
--
-- Task 8.05 — Server-authoritative booking links (contract decisions §1, §3,
-- §5 verbatim: G3). ADDITIVE ONLY: two tables plus one `security definer`
-- RPC. No rewrites, no column changes, no RLS changes to existing tables.
-- The existing mint route and all public shapes are untouched; public
-- resolution keeps working pre-adoption byte-identically (dual reads, §10
-- step 3). No migration deployment here (task gate): apply in the Supabase
-- SQL editor only when the coordinator schedules it, AFTER the 8.04 lifecycle
-- migration AND this file's verify script pass. Rollback: drop the function
-- and tables — pre-adoption the Workers fall back to the blob path
-- byte-identically (the JS treats a missing table as "not adopted").
-- Idempotent — safe to re-run.
--
-- Ordering: this filename sorts AFTER 20260920_booking_lifecycle_rpcs.sql so
-- the G1/G2 functions exist first. The admin RPC does NOT call them; it
-- inlines the same per-owner advisory-lock key (`booking-owner:<user_id>`)
-- so admin mutations serialize with 8.04 claims/transitions on one ordering
-- root (§2.3) without a cross-file function dependency.
--
-- Token storage (§1.4): the state table holds sha256 HASHES only (portal
-- precedent; needs pgcrypto — the verify script asserts its presence).
-- There is deliberately NO raw-token reveal: the ONLY server copy of a raw
-- token lives inside the `booking_operations.response` replay row for 30
-- days, so a lost response replays the SAME capability instead of minting a
-- second one (§1.3). Rotation is the recovery path for a lost display copy.
--
-- Backfill (§3, deployment step 2): the INSERT below copies each settings
-- blob token into the state table with adopted_at=NULL (pre-adoption:
-- authority stays the blob verbatim). Re-runnable (ON CONFLICT DO NOTHING);
-- the verify script carries the row-count / zero-mismatch gates. Adoption
-- happens per-owner on the first admin MUTATION (adopted_at=now()); `status`
-- reads never adopt.
--
-- RELEASE GATE: run `supabase/verify/booking_admin_state.sql` first, then
-- the competing-admin proof notes in the concurrency script (deferred to
-- Phase 12 hardware if no local PG is available — never label a mocked 409
-- as race proof).

create table if not exists public.booking_link_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token_hash text,                       -- sha256 hex; null when never minted
  enabled boolean not null default false,
  revision integer not null default 0,   -- bumped on every committed mutation
  adopted_at timestamptz,                -- NULL = pre-adoption (§3/§5)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.booking_operations (
  operation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  request_hash text not null,   -- sha256 of canonicalized mutating fields
  response jsonb not null,      -- exact bytes to replay (holds the raw token
                                -- for mint/rotate for 30 days — see header)
  created_at timestamptz not null default now()
);

create index if not exists booking_operations_owner_created
  on public.booking_operations (user_id, created_at);

-- Multi-tenant floor (same posture as booking_reservations): owner-scoped
-- policy on every new table holding user data. Public/anon traffic reaches
-- these rows only through the service-role RPC; the device never reads them
-- directly (8.07 uses POST /api/booking/admin).
alter table public.booking_link_state enable row level security;
alter table public.booking_operations enable row level security;

drop policy if exists "users own booking_link_state" on public.booking_link_state;
create policy "users own booking_link_state"
  on public.booking_link_state
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "users own booking_operations" on public.booking_operations;
create policy "users own booking_operations"
  on public.booking_operations
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ── backfill (deployment step 2; re-runnable) ─────────────────────────────
-- One row per settings blob carrying bookingLink.token, adopted_at=NULL.
-- enabled follows (enabled!==false): a missing flag counts as enabled, which
-- matches the pre-adoption blob gate the public path enforces today.

insert into public.booking_link_state (user_id, token_hash, enabled, revision, adopted_at)
select s.user_id,
       encode(digest(s.data -> 'bookingLink' ->> 'token', 'sha256'), 'hex'),
       (s.data -> 'bookingLink' ->> 'enabled') is distinct from 'false',
       1,
       NULL
  from public.settings s
 where s.data -> 'bookingLink' ->> 'token' is not null
on conflict (user_id) do nothing;

-- ── G3: atomic admin mutation ─────────────────────────────────────────────
-- Single transaction per mutating action (mint | set_enabled | rotate):
-- per-owner lock FIRST (same advisory key as booking_take_lock, §2.3
-- ordering root), then replay lookup, revision check, state write and
-- operations-row insert. Any unhandled error rolls back ALL of it — a
-- committed mutation always has exactly one state bump (+1) and one
-- operations row; a failed one holds nothing.
--
-- Error envelope: RETURNS jsonb {ok:true,decision,response} or
-- {ok:false,error,...} with HTTP 200 at the PostgREST layer (same envelope
-- discipline as claim_booking_slot/transition_booking). A transport 404 on
-- /rpc/admin_booking_link unambiguously means "function not deployed".
--
-- p_result carries the response FIELDS the caller knows
-- ({ok:true, operationId} plus the raw token for mint/rotate); the function
-- stamps `enabled` + `revision` from the COMMITTED row so the stored copy is
-- always truthful, then returns/stores those exact bytes (verbatim replay).
-- p_expected_revision NULL = absent = last-writer-wins (legacy/RN compat);
-- non-null and ≠ current = 409 stale_revision with current state echoed.

create or replace function public.admin_booking_link(
  p_user_id uuid,
  p_action text,
  p_operation_id uuid,
  p_request_hash text,
  p_enabled boolean,
  p_expected_revision integer,
  p_token_hash text,
  p_result jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_ttl constant interval := interval '30 days';
  v_state record;
  v_op record;
  v_current_rev integer := 0;
  v_current_enabled boolean := false;
  v_new_enabled boolean;
  v_new_rev integer;
  v_response jsonb;
begin
  if p_action not in ('mint', 'set_enabled', 'rotate') then
    return jsonb_build_object('ok', false, 'error', 'invalid_action');
  end if;

  -- Ordering root FIRST (§2.3): same key as 8.04 booking_take_lock, so an
  -- admin disable/rotate serializes with public claims and lifecycle
  -- transitions per owner. Transaction-scoped, never held across requests.
  perform pg_advisory_xact_lock(hashtext('booking-owner:' || p_user_id::text));

  -- Best-effort expiry sweep for this owner's replay rows (lazy TTL, §1.3 —
  -- no pg_cron/extension dependency).
  delete from public.booking_operations
   where user_id = p_user_id
     and created_at <= now() - v_ttl;

  -- Replay BEFORE any other check (§1.3): a retried POST after a committed
  -- mutation must return the stored copy even though the revision has since
  -- moved (its own commit bumped it).
  select o.user_id, o.request_hash, o.response, o.created_at into v_op
    from public.booking_operations o
   where o.operation_id = p_operation_id;
  if v_op.user_id is not null then
    if v_op.user_id is distinct from p_user_id then
      -- Foreign operation id = unknown (no oracle, booking-respond parity).
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    if v_op.created_at <= now() - v_ttl then
      delete from public.booking_operations
       where operation_id = p_operation_id;
    elsif v_op.request_hash is distinct from p_request_hash then
      return jsonb_build_object('ok', false, 'error', 'operation_conflict');
    else
      return jsonb_build_object('ok', true, 'decision', 'replay', 'response', v_op.response);
    end if;
  end if;

  -- State row lock (second in the §2.3 order, inside the owner lock).
  select b.token_hash, b.enabled, b.revision, b.adopted_at into v_state
    from public.booking_link_state b
   where b.user_id = p_user_id
     for update;
  if v_state.revision is not null then
    v_current_rev := v_state.revision;
    v_current_enabled := v_state.enabled;
  end if;

  -- Version / conflict contract (§1.4).
  if p_expected_revision is not null and p_expected_revision <> v_current_rev then
    return jsonb_build_object('ok', false, 'error', 'stale_revision',
                              'enabled', v_current_enabled, 'revision', v_current_rev);
  end if;

  if p_action = 'mint' then
    -- 409 only when an ENABLED token is already present (portal P1 parity
    -- for the create path; rotate covers the from-zero case). Minting over a
    -- disabled link re-issues and re-enables.
    if v_state.token_hash is not null and v_state.enabled then
      return jsonb_build_object('ok', false, 'error', 'already_exists');
    end if;
    if p_token_hash is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    v_new_enabled := true;
  elsif p_action = 'rotate' then
    -- Rotate-as-create (portal parity): works from zero rows. Enablement is
    -- preserved — rotation swaps the capability, set_enabled toggles it.
    if p_token_hash is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    v_new_enabled := coalesce(v_state.enabled, true);
  else -- set_enabled
    if v_state.revision is null then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    if p_enabled is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    v_new_enabled := p_enabled;
  end if;

  v_new_rev := v_current_rev + 1;
  v_response := p_result
    || jsonb_build_object('enabled', v_new_enabled, 'revision', v_new_rev);

  -- Operations row FIRST so a PK race (cross-owner id collision, or a retry
  -- that slipped the replay read) returns operation_conflict with NOTHING
  -- else written. A later failure rolls the whole transaction back.
  begin
    insert into public.booking_operations
      (operation_id, user_id, action, request_hash, response)
    values
      (p_operation_id, p_user_id, p_action, p_request_hash, v_response);
  exception when unique_violation then
    select o.request_hash, o.response into v_op
      from public.booking_operations o
     where o.operation_id = p_operation_id;
    if found and v_op.request_hash is not distinct from p_request_hash then
      return jsonb_build_object('ok', true, 'decision', 'replay', 'response', v_op.response);
    end if;
    return jsonb_build_object('ok', false, 'error', 'operation_conflict');
  end;

  -- Committed mutation: token row + revision bump + adoption in one write.
  -- First mutation adopts (adopted_at=now()); later ones keep the stamp.
  -- Post-adoption blob writes are auth-inert by construction: no reader
  -- consults the blob again (store.js dual read + claim RPC adopted branch).
  insert into public.booking_link_state
    (user_id, token_hash, enabled, revision, adopted_at, updated_at)
  values
    (p_user_id,
     case when p_action = 'set_enabled' then v_state.token_hash else p_token_hash end,
     v_new_enabled, v_new_rev,
     coalesce(v_state.adopted_at, now()), now())
  on conflict (user_id) do update set
    token_hash = excluded.token_hash,
    enabled = excluded.enabled,
    revision = excluded.revision,
    adopted_at = excluded.adopted_at,
    updated_at = now();

  return jsonb_build_object('ok', true, 'decision', 'committed', 'response', v_response);
end;
$$;

revoke all on function public.admin_booking_link(uuid, text, uuid, text, boolean, integer, text, jsonb) from public;
grant execute on function public.admin_booking_link(uuid, text, uuid, text, boolean, integer, text, jsonb) to service_role;
