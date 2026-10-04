-- 20261003_esign_records_verify.sql
--
-- Self-checking verification for 20261003_esign_records.sql (Phase 19
-- e-signatures). Wrapped in a transaction that ALWAYS rolls back, so it
-- leaves no rows behind.
--
-- Run once against the project after applying the migration:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20261003_esign_records_verify.sql
-- psql ONLY (the SQL editor may autocommit per statement). Without
-- -v ON_ERROR_STOP=1 a failed check can exit 0. Needs one auth.users row.
--
-- Checks: both tables exist with RLS on; both cascade from auth.users
-- (account deletion keeps deleting signature evidence, decision 19-Q6);
-- the API roles cannot write; only SELECT policies exist and they scope to
-- the owner; UPDATE raises on both tables; preserve_job_approvals() freezes
-- the four e-signature keys. The real cascade DELETE is exercised by the
-- local harness supabase/verify/esign_records.sh (deleting an auth user is
-- not something to do on the project).
--
-- Success prints one NOTICE per check, ending with "ALL CHECKS PASSED".

begin;

do $$
declare
  uid      uuid;
  tok      text := repeat('a', 64);
  n        int;
  raised   boolean;
  r        text;
  src      text;
  k        text;
  stored   jsonb;
  signed   jsonb;
begin
  select id into uid from auth.users limit 1;
  if uid is null then
    raise exception 'no auth.users row available to satisfy the FK';
  end if;

  -- 1. Tables and RLS.
  if to_regclass('public.signature_records') is null or to_regclass('public.signature_events') is null then
    raise exception '1. signature_records / signature_events missing';
  end if;
  select count(*) into n from pg_class
   where oid in ('public.signature_records'::regclass, 'public.signature_events'::regclass)
     and relrowsecurity;
  if n <> 2 then raise exception '1. RLS is not enabled on both tables'; end if;
  raise notice 'ok 1. both tables exist with RLS enabled';

  -- 2. Cascade from auth.users on both (account deletion removes them).
  select count(*) into n from pg_constraint
   where conrelid in ('public.signature_records'::regclass, 'public.signature_events'::regclass)
     and contype = 'f' and confrelid = 'auth.users'::regclass and confdeltype = 'c';
  if n <> 2 then raise exception '2. expected 2 ON DELETE CASCADE FKs to auth.users, found %', n; end if;
  raise notice 'ok 2. both tables cascade on auth.users delete';

  -- 3. The API roles cannot write; the owner role can read.
  foreach r in array array['anon', 'authenticated'] loop
    foreach k in array array['insert', 'update', 'delete', 'truncate'] loop
      if has_table_privilege(r, 'public.signature_records', k) or has_table_privilege(r, 'public.signature_events', k) then
        raise exception '3. % holds % on signature evidence', r, k;
      end if;
    end loop;
  end loop;
  if not has_table_privilege('authenticated', 'public.signature_records', 'select')
     or not has_table_privilege('authenticated', 'public.signature_events', 'select') then
    raise exception '3. authenticated cannot select its signature evidence';
  end if;
  raise notice 'ok 3. anon/authenticated hold no write privilege; authenticated may select';

  -- 4. Only SELECT policies.
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename in ('signature_records', 'signature_events') and cmd <> 'SELECT';
  if n <> 0 then raise exception '4. % non-SELECT policies on signature evidence', n; end if;
  raise notice 'ok 4. only SELECT policies';

  -- 5. Append-only: UPDATE raises on both tables, for the table owner too.
  insert into public.signature_records
    (id, user_id, approval_token_sha256, job_id, change_order_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
  values
    (gen_random_uuid(), uid, tok, 'verify_esign_job', null, 'estimate', '{"recordVersion": 1}', repeat('b', 64), 'verify', 'c2lnbmF0dXJl', now());
  insert into public.signature_events (user_id, approval_token_sha256, event) values (uid, tok, 'viewed');
  raised := false;
  begin
    update public.signature_records set seal = 'tampered' where approval_token_sha256 = tok;
  exception when others then raised := true;
  end;
  if not raised then raise exception '5. UPDATE on signature_records did not raise'; end if;
  raised := false;
  begin
    update public.signature_events set event = 'signed' where approval_token_sha256 = tok;
  exception when others then raised := true;
  end;
  if not raised then raise exception '5. UPDATE on signature_events did not raise'; end if;
  raised := false;
  begin
    insert into public.signature_records
      (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
    values (gen_random_uuid(), uid, tok, 'verify_esign_job', 'estimate', '{}', repeat('c', 64), 'verify', 'x', now());
  exception when unique_violation then raised := true;
  end;
  if not raised then raise exception '5. a second record for the same token hash was accepted'; end if;
  raise notice 'ok 5. UPDATE raises on both tables; one record per token hash';

  -- 6. RLS scopes reads to the owner, and the owner cannot insert.
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.signature_records where approval_token_sha256 = tok;
  if n <> 1 then raise exception '6. owner sees % of their records', n; end if;
  raised := false;
  begin
    insert into public.signature_events (user_id, approval_token_sha256, event) values (uid, tok, 'signed');
  exception when insufficient_privilege then raised := true;
  end;
  if not raised then raise exception '6. authenticated could insert an event'; end if;
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  select count(*) into n from public.signature_records where approval_token_sha256 = tok;
  if n <> 0 then raise exception '6. another user sees the owner''s record'; end if;
  execute 'reset role';
  raise notice 'ok 6. RLS: owner reads own rows only and cannot write';

  -- 7. preserve_job_approvals() freezes the e-signature keys.
  select prosrc into src from pg_proc where oid = 'public.preserve_job_approvals()'::regprocedure;
  foreach k in array array['signatureRecordId', 'recordDigest', 'signatureMethod', 'signatureEvidence'] loop
    if (length(src) - length(replace(src, quote_literal(k), ''))) / length(quote_literal(k)) < 2 then
      raise exception '7. % is not in both server_keys and frozen_keys', k;
    end if;
  end loop;
  signed := jsonb_build_object(
    'token', 'verify-tok', 'sentAt', '2026-10-01T10:00:00Z', 'snapshot', '{"total": 90}'::jsonb,
    'decision', 'approved', 'consentAt', '2026-10-02T09:00:00Z', 'signerName', 'Pat',
    'signatureRecordId', '3f0c1a2b-1111-4222-8333-444455556666', 'recordDigest', repeat('d', 64),
    'signatureMethod', 'typed', 'signatureEvidence', '{"v": 1, "events": []}'::jsonb);
  insert into public.jobs (id, user_id, data, updated_at, deleted)
  values ('verify_esign_job', uid, jsonb_build_object('approval', signed), now(), false);
  update public.jobs
     set data = '{"approval": {"token": "verify-tok", "sentAt": "2026-10-01T10:00:00Z", "snapshot": {"total": 90}}}'::jsonb
   where id = 'verify_esign_job';
  select data -> 'approval' into stored from public.jobs where id = 'verify_esign_job';
  if stored is distinct from signed then
    raise exception '7. a stale push changed the signed approval: %', stored;
  end if;
  raise notice 'ok 7. preserve_job_approvals keeps all four e-signature keys';

  raise notice 'ALL CHECKS PASSED';
end
$$;

rollback;
