-- 20260922_portal_token_admin.sql
--
-- Task 8.06 — Transactional portal token administration (contract decisions
-- §4 verbatim: G4). ADDITIVE ONLY: one table plus one `security definer` RPC
-- plus one partial unique index. No column rewrites, no RLS changes to
-- existing tables. Existing endpoint payloads and the 409 `already_exists`
-- vocabulary are untouched; replay (`operationId`) and `status` are additive.
--
-- Chosen invariant (§4/C6): at most ONE non-revoked row per
-- (user_id, customer_id), enforced by the partial unique index below. `mint`
-- answers 409 `already_exists` when ANY non-revoked row exists (change from
-- the current enabled-only guard, pinned gap G4-02). `rotate` is one
-- transaction: revoke-all + insert fresh + `portal_operations` replay row.
--
-- Locking: per-customer advisory lock (`portal-customer:<user>:<customer>`)
-- FIRST inside the RPC, so concurrent mint/rotate/toggle for one customer
-- serialize deterministically; cross-customer ops never block each other.
-- The resolver's lazy read-path backfill cannot take this lock over REST, so
-- the partial unique index plus fail-closed JS resolution (§4, portalTokenStore)
-- covers backfill racing rotation instead: a conflicting backfill errors and
-- authorizes nothing.
--
-- NO DEPLOYMENT here (task gate): apply in the Supabase SQL editor only when
-- the coordinator schedules it, AFTER this file's verify script passes and
-- after the 8.05 booking-admin migration. Rollback: drop the function, table
-- and index — pre-deploy Workers fall back to the legacy split path
-- byte-identically (the JS treats a missing function as "unavailable").
-- Idempotent — safe to re-run.
--
-- RELEASE GATE: run `supabase/verify/portal_token_admin.sql` first, then the
-- competing-session proof notes inside it (deferred to Phase 12 hardware if
-- no local PG is available — never label a mocked 409 as race proof).

-- ── replay table (§4, same 30-day lazy-TTL discipline as booking §1.3) ─────
-- The raw token lives ONLY inside `response` for mint/rotate for 30 days, so
-- a lost response replays the SAME capability instead of minting a second
-- one. Rotation (new operationId) is the recovery path for a lost display
-- copy — there is no reveal endpoint by design (§1.4, portal precedent).

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.portal_operations (
  operation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  customer_id text not null,
  action text not null,
  request_hash text not null,   -- sha256 of canonicalized mutating fields
  response jsonb not null,      -- exact bytes to replay
  created_at timestamptz not null default now()
);

create index if not exists portal_operations_owner_customer_created
  on public.portal_operations (user_id, customer_id, created_at);

-- Server-authority table: no client policy, no client grants (P12-023, see the
-- same note in 20260921_booking_admin_state.sql). `response` holds a raw token.
alter table public.portal_operations enable row level security;

drop policy if exists "users own portal_operations" on public.portal_operations;

revoke all on table public.portal_operations from public, anon, authenticated;
grant select, insert, update, delete on table public.portal_operations to service_role;

-- ── consolidation (deployment step 2; re-runnable) ─────────────────────────
-- The new index rejects tables that already hold two live rows for one
-- customer (pinned gap G4-02: mint-after-disable). Resolve each conflict by
-- keeping the blob display-copy row when it is still live (ordinary clients
-- already share that link) and revoking the rest; otherwise keep the latest
-- write. Revoked rows keep honest timestamps — nothing is deleted.

update public.portal_tokens t
   set enabled = false, revoked_at = coalesce(t.revoked_at, now())
  from public.customers c
 where c.user_id = t.user_id
   and c.id::text = t.customer_id
   and t.revoked_at is null
   and (c.data -> 'portal' ->> 'token') is not null
   and t.token_hash <> encode(extensions.digest(c.data -> 'portal' ->> 'token', 'sha256'), 'hex')
   and exists (
     select 1 from public.portal_tokens keeper
      where keeper.user_id = t.user_id
        and keeper.customer_id = t.customer_id
        and keeper.revoked_at is null
        and keeper.token_hash = encode(extensions.digest(c.data -> 'portal' ->> 'token', 'sha256'), 'hex')
   );

update public.portal_tokens t
   set enabled = false, revoked_at = coalesce(t.revoked_at, now())
 where t.revoked_at is null
   and exists (
     select 1 from public.portal_tokens newer
      where newer.user_id = t.user_id
        and newer.customer_id = t.customer_id
        and newer.revoked_at is null
        and (newer.created_at, newer.token_hash) > (t.created_at, t.token_hash)
   );

-- ── the invariant (C6): one live row per customer ──────────────────────────

create unique index if not exists portal_tokens_single_active
  on public.portal_tokens (user_id, customer_id)
  where revoked_at is null;

-- ── G4: atomic portal token mutation ───────────────────────────────────────
-- Single transaction per mutating action (mint | set_enabled | rotate):
-- per-customer lock FIRST, then replay lookup, customer check, legacy
-- backfill, state write and operations-row insert. Any unhandled error rolls
-- back ALL of it — a committed mutation always has exactly one state change
-- and at most one operations row; a failed one (e.g. insert error after
-- revoke, pinned gap G4-04) holds nothing, so the previous token stays live.
--
-- Error envelope: RETURNS jsonb {ok:true,decision,response} or
-- {ok:false,error,...} with HTTP 200 at the PostgREST layer (same envelope
-- discipline as admin_booking_link). A transport 404 on
-- /rpc/admin_portal_token unambiguously means "function not deployed".
--
-- p_operation_id NULL = legacy caller without replay (existing RN/native
-- portal-manage payloads carry no operationId): the mutation still commits
-- atomically, only the replay row is skipped. p_result carries the response
-- FIELDS the caller knows ({ok:true} plus the raw token for mint/rotate);
-- the function stamps `enabled` (+ `adopted:true`) from the COMMITTED state
-- so the stored copy is always truthful, then returns/stores those exact
-- bytes (verbatim replay). There is no revision counter on this family
-- (frozen §6 status shape: {ok, enabled, tokenValid, adopted}); last writer
-- wins across devices and `status` reconciles — rotate stays the explicit
-- destructive path.

create or replace function public.admin_portal_token(
  p_user_id uuid,
  p_customer_id text,
  p_action text,
  p_operation_id uuid,
  p_request_hash text,
  p_enabled boolean,
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
  v_op record;
  v_customer record;
  v_live record;
  v_live_count integer := 0;
  v_blob_token text;
  v_blob_enabled boolean := false;
  v_new_enabled boolean;
  v_response jsonb;
begin
  if public.booking_is_client_caller() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if p_action not in ('mint', 'set_enabled', 'rotate') then
    return jsonb_build_object('ok', false, 'error', 'invalid_action');
  end if;

  -- Serialization root FIRST: one customer never interleaves mint, toggle
  -- and rotate. Transaction-scoped, never held across requests.
  perform pg_advisory_xact_lock(hashtext('portal-customer:' || p_user_id::text || ':' || p_customer_id));

  if p_operation_id is not null then
    -- Best-effort expiry sweep for this customer's replay rows (lazy TTL,
    -- §1.3 — no pg_cron/extension dependency).
    delete from public.portal_operations
     where user_id = p_user_id
       and customer_id = p_customer_id
       and created_at <= now() - v_ttl;

    -- Replay BEFORE any other check: a retried POST after a committed
    -- mutation returns the stored copy verbatim (same token, no second
    -- capability, no extra state bump).
    select o.user_id, o.customer_id, o.request_hash, o.response, o.created_at into v_op
      from public.portal_operations o
     where o.operation_id = p_operation_id;
    if v_op.user_id is not null then
      if v_op.user_id is distinct from p_user_id or v_op.customer_id is distinct from p_customer_id then
        -- Foreign operation id = unknown (no oracle, booking-respond parity).
        return jsonb_build_object('ok', false, 'error', 'not_found');
      end if;
      if v_op.created_at <= now() - v_ttl then
        delete from public.portal_operations
         where operation_id = p_operation_id;
      elsif v_op.request_hash is distinct from p_request_hash then
        return jsonb_build_object('ok', false, 'error', 'operation_conflict');
      else
        return jsonb_build_object('ok', true, 'decision', 'replay', 'response', v_op.response);
      end if;
    end if;
  end if;

  -- Ownership as a 404, no oracle about other tenants (booking-respond
  -- convention). Soft-deleted customers stay invisible here.
  select c.user_id, c.id, c.data into v_customer
    from public.customers c
   where c.user_id = p_user_id
     and c.id::text = p_customer_id
     and c.deleted = false
     for update;
  if v_customer.user_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Legacy backfill in-txn: a pre-Phase-D customer carries only the blob
  -- token. Materialize it first so every action below operates purely on
  -- server state. ON CONFLICT DO NOTHING: a racing resolver backfill or a
  -- concurrent admin call may have won — the re-read below then governs.
  -- Lock the live rows, then count them: FOR UPDATE is not allowed together
  -- with an aggregate, so the two steps are separate statements.
  perform 1
    from public.portal_tokens t
   where t.user_id = p_user_id
     and t.customer_id = p_customer_id
     and t.revoked_at is null
     for update;
  select count(*) into v_live_count
    from public.portal_tokens t
   where t.user_id = p_user_id
     and t.customer_id = p_customer_id
     and t.revoked_at is null;
  v_blob_token := v_customer.data -> 'portal' ->> 'token';
  if v_live_count = 0 and v_blob_token is not null then
    v_blob_enabled := coalesce((v_customer.data -> 'portal' ->> 'enabled') is distinct from 'false', true);
    insert into public.portal_tokens (token_hash, user_id, customer_id, enabled)
    values (encode(extensions.digest(v_blob_token, 'sha256'), 'hex'), p_user_id, p_customer_id, v_blob_enabled)
    on conflict do nothing;
    select count(*) into v_live_count
      from public.portal_tokens t
     where t.user_id = p_user_id
       and t.customer_id = p_customer_id
       and t.revoked_at is null;
  end if;

  if p_action = 'mint' then
    -- 409 on ANY live row (C6 — the enabled-only guard is retired here).
    -- Re-enable via set_enabled(true); destruction only via rotate.
    if v_live_count > 0 then
      return jsonb_build_object('ok', false, 'error', 'already_exists');
    end if;
    if p_token_hash is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    v_new_enabled := true;
  elsif p_action = 'rotate' then
    -- Rotate-as-create: works from zero rows (portal P1 parity). Enablement
    -- is preserved — rotation swaps the capability, set_enabled toggles it.
    if p_token_hash is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    select t.enabled into v_live
      from public.portal_tokens t
     where t.user_id = p_user_id
       and t.customer_id = p_customer_id
       and t.revoked_at is null
     order by t.created_at desc nulls last
     limit 1;
    v_new_enabled := coalesce(v_live.enabled, true);
  else -- set_enabled
    if v_live_count = 0 then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    if p_enabled is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_args');
    end if;
    v_new_enabled := p_enabled;
  end if;

  v_response := p_result
    || jsonb_build_object('enabled', v_new_enabled, 'adopted', true);

  -- Operations row FIRST (replay callers only) so a PK race returns
  -- operation_conflict with NOTHING else written. A later failure rolls the
  -- whole transaction back — the previous token stays live (G4-04 closed).
  if p_operation_id is not null then
    begin
      insert into public.portal_operations
        (operation_id, user_id, customer_id, action, request_hash, response)
      values
        (p_operation_id, p_user_id, p_customer_id, p_action, p_request_hash, v_response);
    exception when unique_violation then
      select o.request_hash, o.response into v_op
        from public.portal_operations o
       where o.operation_id = p_operation_id;
      if found and v_op.request_hash is not distinct from p_request_hash then
        return jsonb_build_object('ok', true, 'decision', 'replay', 'response', v_op.response);
      end if;
      return jsonb_build_object('ok', false, 'error', 'operation_conflict');
    end;
  end if;

  if p_action = 'rotate' then
    update public.portal_tokens t
       set enabled = false, revoked_at = now()
     where t.user_id = p_user_id
       and t.customer_id = p_customer_id
       and t.revoked_at is null;
  end if;

  if p_action = 'mint' or p_action = 'rotate' then
    insert into public.portal_tokens (token_hash, user_id, customer_id, enabled)
    values (p_token_hash, p_user_id, p_customer_id, v_new_enabled);
  else
    -- Single live row by construction (partial unique index); the predicate
    -- keeps historical revocation timestamps honest.
    update public.portal_tokens t
       set enabled = v_new_enabled
     where t.user_id = p_user_id
       and t.customer_id = p_customer_id
       and t.revoked_at is null;
  end if;

  return jsonb_build_object('ok', true, 'decision', 'committed', 'response', v_response);
end;
$$;

revoke all on function public.admin_portal_token(uuid, text, text, uuid, text, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.admin_portal_token(uuid, text, text, uuid, text, boolean, text, jsonb) to service_role;
