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
-- Checks: the three tables exist with RLS on; all cascade from auth.users
-- (account deletion keeps deleting signature evidence, decision 19-Q6);
-- the API roles cannot write, and cannot touch signature_pending at all;
-- only SELECT policies exist and they scope to the owner; UPDATE raises on
-- all three; one record per link (token hash + job + change order), the
-- same token on another job is a different link (spec §11.10); pending rows
-- are unique per record id only, so one link can hold several (§11.11);
-- preserve_job_approvals() freezes the four e-signature keys. The real cascade DELETE is exercised by the
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
  if to_regclass('public.signature_records') is null or to_regclass('public.signature_events') is null
     or to_regclass('public.signature_pending') is null then
    raise exception '1. signature_records / signature_events missing (or signature_pending)';
  end if;
  select count(*) into n from pg_class
   where oid in ('public.signature_records'::regclass, 'public.signature_pending'::regclass, 'public.signature_events'::regclass)
     and relrowsecurity;
  if n <> 3 then raise exception '1. RLS is not enabled on all three tables'; end if;
  raise notice 'ok 1. signature_records, signature_pending, signature_events exist with RLS enabled';

  -- 2. Cascade from auth.users on all three (account deletion removes them).
  select count(*) into n from pg_constraint
   where conrelid in ('public.signature_records'::regclass, 'public.signature_pending'::regclass, 'public.signature_events'::regclass)
     and contype = 'f' and confrelid = 'auth.users'::regclass and confdeltype = 'c';
  if n <> 3 then raise exception '2. expected 3 ON DELETE CASCADE FKs to auth.users, found %', n; end if;
  raise notice 'ok 2. all three tables cascade on auth.users delete';

  -- 3. The API roles cannot write; the owner role can read records and
  -- events; nobody but the service role touches signature_pending.
  foreach r in array array['anon', 'authenticated'] loop
    foreach k in array array['insert', 'update', 'delete', 'truncate'] loop
      if has_table_privilege(r, 'public.signature_records', k) or has_table_privilege(r, 'public.signature_events', k) then
        raise exception '3. % holds % on signature evidence', r, k;
      end if;
    end loop;
    foreach k in array array['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger'] loop
      if has_table_privilege(r, 'public.signature_pending', k) then
        raise exception '3. % holds % on signature_pending', r, k;
      end if;
    end loop;
  end loop;
  if not has_table_privilege('authenticated', 'public.signature_records', 'select')
     or not has_table_privilege('authenticated', 'public.signature_events', 'select') then
    raise exception '3. authenticated cannot select its signature evidence';
  end if;
  raise notice 'ok 3. anon/authenticated hold no write privilege and no access to signature_pending; authenticated may select records and events';

  -- 4. Only SELECT policies, and none at all on signature_pending.
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename in ('signature_records', 'signature_events') and cmd <> 'SELECT';
  if n <> 0 then raise exception '4. % non-SELECT policies on signature evidence', n; end if;
  select count(*) into n from pg_policies where schemaname = 'public' and tablename = 'signature_pending';
  if n <> 0 then raise exception '4. % policies on signature_pending (expected none)', n; end if;
  raise notice 'ok 4. only SELECT policies; none on signature_pending';

  -- 5. Append-only: UPDATE raises on all three tables, for the table owner
  -- too. One record per link; pending rows unique per record id (§11.11).
  insert into public.signature_records
    (id, user_id, approval_token_sha256, job_id, change_order_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
  values
    (gen_random_uuid(), uid, tok, 'verify_esign_job', null, 'estimate', '{"recordVersion": 1}', repeat('b', 64), 'verify', 'c2lnbmF0dXJl', now());
  insert into public.signature_pending
    (id, user_id, approval_token_sha256, job_id, change_order_id, document_type, record, record_digest, signed_at)
  values
    (gen_random_uuid(), uid, tok, 'verify_esign_job', null, 'estimate', '{"recordVersion": 1}', repeat('b', 64), now());
  insert into public.signature_events (user_id, job_id, change_order_id, approval_token_sha256, event)
  values (uid, 'verify_esign_job', null, tok, 'viewed');
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
    update public.signature_pending set record_digest = repeat('e', 64) where approval_token_sha256 = tok;
  exception when others then raised := true;
  end;
  if not raised then raise exception '5. UPDATE on signature_pending did not raise'; end if;
  raised := false;
  begin
    insert into public.signature_records
      (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
    values (gen_random_uuid(), uid, tok, 'verify_esign_job', 'estimate', '{}', repeat('c', 64), 'verify', 'x', now());
  exception when unique_violation then raised := true;
  end;
  if not raised then raise exception '5. a second record for the same link was accepted'; end if;
  -- A second pending row for the same link (a decision that never landed,
  -- then a retry) is accepted; the same record id twice is not, and the
  -- Worker's on_conflict=id insert must infer the primary key.
  insert into public.signature_pending
    (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, signed_at)
  values ('00000000-0000-4000-8000-0000000000e5', uid, tok, 'verify_esign_job', 'estimate', '{}', repeat('c', 64), now());
  select count(*) into n from public.signature_pending where approval_token_sha256 = tok;
  if n <> 2 then raise exception '5. expected two pending rows for one link, found %', n; end if;
  raised := false;
  begin
    insert into public.signature_pending
      (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, signed_at)
    values ('00000000-0000-4000-8000-0000000000e5', uid, tok, 'verify_esign_job', 'estimate', '{}', repeat('d', 64), now());
  exception when unique_violation then raised := true;
  end;
  if not raised then raise exception '5. a second pending row with the same record id was accepted'; end if;
  insert into public.signature_pending
    (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, signed_at)
  values ('00000000-0000-4000-8000-0000000000e5', uid, tok, 'verify_esign_job', 'estimate', '{}', repeat('d', 64), now())
  on conflict (id) do nothing;
  select count(*) into n from public.signature_pending where approval_token_sha256 = tok;
  if n <> 2 then raise exception '5. on conflict (id) did not dedupe: % pending rows', n; end if;
  -- The Worker's PostgREST insert (resolution=ignore-duplicates on exactly
  -- these columns) must infer the constraint, null change_order_id included.
  insert into public.signature_records
    (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
  values (gen_random_uuid(), uid, tok, 'verify_esign_job', 'estimate', '{}', repeat('c', 64), 'verify', 'x', now())
  on conflict (approval_token_sha256, job_id, change_order_id) do nothing;
  select count(*) into n from public.signature_records where approval_token_sha256 = tok;
  if n <> 1 then raise exception '5. on conflict (token, job, change order) did not dedupe: % rows', n; end if;
  -- The same token on another job, or on a change order, is another link.
  insert into public.signature_records
    (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
  values (gen_random_uuid(), uid, tok, 'verify_esign_other_job', 'estimate', '{}', repeat('c', 64), 'verify', 'x', now());
  insert into public.signature_records
    (id, user_id, approval_token_sha256, job_id, change_order_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
  values (gen_random_uuid(), uid, tok, 'verify_esign_job', 'co-1', 'change_order', '{}', repeat('c', 64), 'verify', 'x', now());
  raised := false;
  begin
    insert into public.signature_records
      (id, user_id, approval_token_sha256, job_id, change_order_id, document_type, record, record_digest, seal_key_id, seal, signed_at)
    values (gen_random_uuid(), uid, tok, 'verify_esign_job', 'co-2', 'estimate', '{}', repeat('c', 64), 'verify', 'x', now());
  exception when check_violation then raised := true;
  end;
  if not raised then raise exception '5. an estimate record with a change_order_id was accepted'; end if;
  raised := false;
  begin
    insert into public.signature_events (user_id, approval_token_sha256, event) values (uid, tok, 'viewed');
  exception when not_null_violation then raised := true;
  end;
  if not raised then raise exception '5. an event without job_id was accepted'; end if;
  raise notice 'ok 5. UPDATE raises on all three tables; one record per link (token hash + job + change order); pending rows unique per record id; events name their job';

  -- 6. RLS scopes reads to the owner, and the owner cannot insert.
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.signature_records where approval_token_sha256 = tok;
  if n <> 3 then raise exception '6. owner sees % of their 3 records', n; end if;
  raised := false;
  begin
    insert into public.signature_events (user_id, job_id, approval_token_sha256, event) values (uid, 'verify_esign_job', tok, 'signed');
  exception when insufficient_privilege then raised := true;
  end;
  if not raised then raise exception '6. authenticated could insert an event'; end if;
  raised := false;
  begin
    perform 1 from public.signature_pending limit 1;
  exception when insufficient_privilege then raised := true;
  end;
  if not raised then raise exception '6. authenticated could read signature_pending'; end if;
  raised := false;
  begin
    insert into public.signature_pending
      (id, user_id, approval_token_sha256, job_id, document_type, record, record_digest, signed_at)
    values (gen_random_uuid(), uid, repeat('f', 64), 'verify_esign_job', 'estimate', '{}', repeat('c', 64), now());
  exception when insufficient_privilege then raised := true;
  end;
  if not raised then raise exception '6. authenticated could insert a pending signature'; end if;
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  select count(*) into n from public.signature_records where approval_token_sha256 = tok;
  if n <> 0 then raise exception '6. another user sees the owner''s record'; end if;
  execute 'reset role';
  raise notice 'ok 6. RLS: owner reads own records only, cannot write, cannot read or write signature_pending';

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
