-- 20261003_esign_records.sql
--
-- Roadmap Phase 19 — e-signatures with audit trail (spec
-- docs/superpowers/specs/2026-10-03-esignature-upgrade-design.md §4).
-- WRITTEN, NOT APPLIED: the owner applies it in the Supabase SQL editor at
-- stage B (decision 19-Q1), before the Worker ships with ESIGN_V2 on.
-- Additive: while ESIGN_V2 is off nothing reads or writes these tables.
--
-- A link is (owner, job, change order, approval token). The raw token is
-- never stored, only its SHA-256.
--
-- 1. public.signature_records — one sealed record per signed link (unique on
--    token hash + job + change order, NULLS NOT DISTINCT: PostgreSQL 15+).
--    `record` is the canonical record JSON, `record_digest` its SHA-256,
--    `seal` the base64 Ed25519 signature over the digest bytes.
-- 2. public.signature_pending — Worker-captured evidence of a signature
--    whose first seal or insert failed: the record built when the customer
--    signed, waiting to be sealed lazily. Same per-link uniqueness. SERVICE
--    ROLE ONLY (RLS on, no policy, no client grant): a seal is only ever made
--    from a row the Worker wrote, never from the owner-writable job blob
--    (spec §11.10, security review 2026-10-03).
-- 3. public.signature_events — the audit log per link: link_created,
--    viewed, declined, signed, copy_emailed, copy_email_failed,
--    copy_downloaded. Each row names its job and change order; the Worker
--    reads events filtered on owner + job + change order + token hash.
--
-- APPEND-ONLY. Only the Worker (service role) inserts. A BEFORE UPDATE
-- trigger refuses every update, for every role. There is deliberately NO
-- delete trigger: rows must still go when the owner deletes their account
-- (ON DELETE CASCADE from auth.users, decision 19-Q6 "keep deleting", which
-- is what privacy.html already says). No client role holds insert, update or
-- delete; the owner may only read their own records and events (RLS), and
-- cannot read signature_pending at all.
--
-- 4. public.preserve_job_approvals() (20261002_job_approval_preserve.sql) is
--    replaced with the SAME body plus four server-owned keys —
--    signatureRecordId, recordDigest, signatureMethod and signatureEvidence —
--    in both server_keys and frozen_keys, so a stale device push can't strip
--    the e-signature keys from a decided approval. Nothing else changes; the
--    trigger itself is untouched. (signatureEvidence is the fourth key beyond
--    the spec's three: an informational copy for the owner app, never an
--    input to a seal — spec §11.3, §11.10.)
--
-- Verify: sh supabase/verify/esign_records.sh (throwaway local Postgres),
-- then supabase/migrations/verify/20261003_esign_records_verify.sql against
-- the project with psql -v ON_ERROR_STOP=1. Also re-run
-- supabase/verify/account_deletion_cascade.sql (every user_id table must
-- cascade, signature_pending included).
--
-- Idempotent: safe to re-run.

create table if not exists public.signature_records (
  id                     uuid primary key,
  user_id                uuid not null references auth.users(id) on delete cascade,
  approval_token_sha256  text not null check (approval_token_sha256 ~ '^[0-9a-f]{64}$'),
  job_id                 text not null,
  change_order_id        text,
  document_type          text not null check (document_type in ('estimate', 'change_order')),
  record                 jsonb not null,
  record_digest          text not null check (record_digest ~ '^[0-9a-f]{64}$'),
  seal_alg               text not null default 'Ed25519' check (seal_alg = 'Ed25519'),
  seal_key_id            text not null,
  seal                   text not null,
  signed_at              timestamptz not null,
  created_at             timestamptz not null default now(),
  constraint signature_records_document_kind
    check ((document_type = 'change_order') = (change_order_id is not null)),
  -- One record per link. The Worker inserts with
  -- on_conflict=approval_token_sha256,job_id,change_order_id.
  constraint signature_records_one_per_link
    unique nulls not distinct (approval_token_sha256, job_id, change_order_id)
);

create index if not exists signature_records_owner_job
  on public.signature_records (user_id, job_id);

create table if not exists public.signature_pending (
  id                     uuid primary key,
  user_id                uuid not null references auth.users(id) on delete cascade,
  approval_token_sha256  text not null check (approval_token_sha256 ~ '^[0-9a-f]{64}$'),
  job_id                 text not null,
  change_order_id        text,
  document_type          text not null check (document_type in ('estimate', 'change_order')),
  record                 jsonb not null,
  record_digest          text not null check (record_digest ~ '^[0-9a-f]{64}$'),
  signed_at              timestamptz not null,
  created_at             timestamptz not null default now(),
  constraint signature_pending_document_kind
    check ((document_type = 'change_order') = (change_order_id is not null)),
  constraint signature_pending_one_per_link
    unique nulls not distinct (approval_token_sha256, job_id, change_order_id)
);

create index if not exists signature_pending_owner_job
  on public.signature_pending (user_id, job_id);

create table if not exists public.signature_events (
  id                     bigint generated always as identity primary key,
  user_id                uuid not null references auth.users(id) on delete cascade,
  job_id                 text not null,
  change_order_id        text,
  approval_token_sha256  text not null check (approval_token_sha256 ~ '^[0-9a-f]{64}$'),
  event                  text not null check (event in (
                           'link_created', 'viewed', 'declined', 'signed',
                           'copy_emailed', 'copy_email_failed', 'copy_downloaded')),
  ip                     text,
  user_agent             text,
  created_at             timestamptz not null default now()
);

create index if not exists signature_events_link
  on public.signature_events (approval_token_sha256, job_id, created_at);

-- Append-only: refuse every UPDATE (service role included).
create or replace function public.esign_refuse_update()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
begin
  raise exception 'public.% is append-only: rows cannot be updated', TG_TABLE_NAME
    using errcode = 'P0001';
end;
$$;

revoke all on function public.esign_refuse_update() from public, anon, authenticated;

drop trigger if exists signature_records_no_update on public.signature_records;
create trigger signature_records_no_update
  before update on public.signature_records
  for each row
  execute function public.esign_refuse_update();

drop trigger if exists signature_pending_no_update on public.signature_pending;
create trigger signature_pending_no_update
  before update on public.signature_pending
  for each row
  execute function public.esign_refuse_update();

drop trigger if exists signature_events_no_update on public.signature_events;
create trigger signature_events_no_update
  before update on public.signature_events
  for each row
  execute function public.esign_refuse_update();

-- RLS: the owner reads their own records and events; nobody but the service
-- role writes. signature_pending has no policy: service role only.
alter table public.signature_records enable row level security;
alter table public.signature_pending enable row level security;
alter table public.signature_events enable row level security;

drop policy if exists "read own signature records" on public.signature_records;
create policy "read own signature records"
  on public.signature_records for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "read own signature events" on public.signature_events;
create policy "read own signature events"
  on public.signature_events for select
  to authenticated
  using (auth.uid() = user_id);

-- The hosted project grants ALL on new public tables to the API roles by
-- default; take writes back so the policies are not the only guard.
revoke all on table public.signature_records from anon, authenticated;
revoke all on table public.signature_pending from anon, authenticated;
revoke all on table public.signature_events from anon, authenticated;
grant select on table public.signature_records to authenticated;
grant select on table public.signature_events to authenticated;

-- 4. preserve_job_approvals(): 20261002's body with the e-signature keys
-- added to server_keys and frozen_keys. The trigger is unchanged.
create or replace function public.preserve_job_approvals()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  -- Written only by the Worker (respond.js nextApproval / changeRespond.js).
  server_keys constant text[] := array[
    'decision', 'consentAt', 'signerName', 'declineReason', 'ip', 'userAgent',
    'selection',
    -- Phase 19 (20261003_esign_records.sql): the e-signature keys.
    'signatureRecordId', 'recordDigest', 'signatureMethod', 'signatureEvidence'
  ];
  -- Once approved, the estimate the customer accepted is frozen as well.
  frozen_keys constant text[] := array[
    'decision', 'consentAt', 'signerName', 'declineReason', 'ip', 'userAgent',
    'selection', 'snapshot', 'sentAt',
    'signatureRecordId', 'recordDigest', 'signatureMethod', 'signatureEvidence'
  ];
  old_cos   jsonb;
  new_cos   jsonb;
  n_cos     int := 0;
  cos_dirty boolean := false;
  elem      jsonb;   -- NEW change-order element for the current slot
  o         jsonb;   -- stored approval (OLD)
  n         jsonb;   -- incoming approval (NEW)
  keep      text[];  -- keys whose presence and value come from O
  merged    jsonb;
begin
  -- Nothing to preserve against on INSERT (the trigger is BEFORE UPDATE only;
  -- this is a second guard, not the first).
  if TG_OP <> 'UPDATE' then
    return NEW;
  end if;

  if NEW.data is null or OLD.data is null then
    return NEW;
  end if;

  -- `->` on a non-object yields SQL NULL rather than erroring, but jsonb_set
  -- below needs an object; a blob of any other shape is left exactly as sent.
  if jsonb_typeof(NEW.data) <> 'object' or jsonb_typeof(OLD.data) <> 'object' then
    return NEW;
  end if;

  -- Non-array changeOrders on either side degrade to "no change orders"
  -- (jsonb_array_length / jsonb_array_elements would hard-error on them).
  old_cos := OLD.data -> 'changeOrders';
  if jsonb_typeof(old_cos) is distinct from 'array' then
    old_cos := '[]'::jsonb;
  end if;
  new_cos := NEW.data -> 'changeOrders';
  if jsonb_typeof(new_cos) = 'array' then
    n_cos := jsonb_array_length(new_cos);
  end if;

  -- Slot 0 is the estimate approval; slot k (1..n_cos) is NEW's change order at
  -- array index k-1. One loop so the rule below exists exactly once.
  for slot in 0 .. n_cos loop
    o := null;
    if slot = 0 then
      n := NEW.data -> 'approval';
      o := OLD.data -> 'approval';
    else
      elem := new_cos -> (slot - 1);
      n := elem -> 'approval';            -- NULL unless elem is an object
      if jsonb_typeof(n) = 'object'
         and (n ->> 'token') is not null
         and (elem ->> 'id') is not null then
        select e -> 'approval'
          into o
          from jsonb_array_elements(old_cos) with ordinality as t(e, ord)
         where e ->> 'id' = elem ->> 'id'
           and jsonb_typeof(e -> 'approval') = 'object'
           and (e -> 'approval' ->> 'token') = (n ->> 'token')
         order by ord
         limit 1;
      end if;
    end if;

    -- THE RULE (see header). jsonb_typeof(NULL) is NULL, so a missing side
    -- simply fails the condition.
    keep := null;
    if jsonb_typeof(o) = 'object'
       and jsonb_typeof(n) = 'object'
       and (o ->> 'token') is not null
       and (o ->> 'token') = (n ->> 'token') then
      if (o ->> 'decision') = 'approved' then
        keep := frozen_keys;
      elsif (o ->> 'decision') is not null and (n ->> 'decision') is null then
        keep := server_keys;
      end if;
    end if;

    if keep is not null then
      -- Strip N's copy of every kept key, then add back O's — so a key O lacks
      -- ends up absent, not inherited from N.
      merged := (n - keep) || coalesce(
        (select jsonb_object_agg(key, value) from jsonb_each(o) where key = any(keep)),
        '{}'::jsonb
      );
      if merged is distinct from n then
        if slot = 0 then
          NEW.data := jsonb_set(NEW.data, '{approval}', merged, false);
        else
          new_cos := jsonb_set(
            new_cos,
            array[(slot - 1)::text],
            jsonb_set(elem, '{approval}', merged, false),
            false
          );
          cos_dirty := true;
        end if;
      end if;
    end if;
  end loop;

  if cos_dirty then
    NEW.data := jsonb_set(NEW.data, '{changeOrders}', new_cos, false);
  end if;

  return NEW;
end;
$$;

-- ROLLBACK
--   Re-run 20261002_job_approval_preserve.sql to restore the previous key
--   lists. The tables are evidence: drop them only if no record was ever
--   sealed (select count(*) from public.signature_records), e.g.
--     drop table if exists public.signature_events;
--     drop table if exists public.signature_pending;
--     drop table if exists public.signature_records;
--     drop function if exists public.esign_refuse_update();
