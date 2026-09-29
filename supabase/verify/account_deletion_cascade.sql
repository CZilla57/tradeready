-- Read-only Phase 3 deployment gate. Run this against the isolated staging
-- project before enabling POST /api/delete-account. Success is one NOTICE and
-- no persistent schema or data changes.
--
-- The Worker deletes auth.users once and relies on PostgreSQL to cascade every
-- public user-owned row in that same transaction. This gate fails when an
-- expected table is missing or any public table with user_id lacks a cascading
-- FK to auth.users(id).

do $account_deletion_audit$
declare
  failures text;
begin
  with expected(table_name) as (
    values
      ('ai_usage_log'),
      ('auto_invoice_email_log'),
      ('auto_reminder_log'),
      ('bookingRequests'),
      ('booking_reservations'),
      ('customer_notes'),
      ('customers'),
      ('expenses'),
      ('invoices'),
      ('jobPhotos'),
      ('jobs'),
      ('portal_access_log'),
      ('portal_tokens'),
      ('pricebook'),
      ('recurringInvoices'),
      ('recurringJobs'),
      ('settings'),
      ('stripe_accounts'),
      ('subscriptions'),
      ('trips')
  ),
  public_tables as (
    select c.oid, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
  ),
  cascade_tables as (
    select distinct con.conrelid
    from pg_constraint con
    join pg_class parent on parent.oid = con.confrelid
    join pg_namespace parent_namespace on parent_namespace.oid = parent.relnamespace
    where con.contype = 'f'
      and parent_namespace.nspname = 'auth'
      and parent.relname = 'users'
      and con.confdeltype = 'c'
  ),
  tables_with_user_id as (
    select distinct table_oid
    from (
      select a.attrelid as table_oid
      from pg_attribute a
      where a.attname = 'user_id'
        and a.attnum > 0
        and not a.attisdropped
    ) columns
  ),
  violations as (
    select format('missing expected table public.%I', expected.table_name) as issue
    from expected
    left join public_tables on public_tables.relname = expected.table_name
    where public_tables.oid is null

    union all

    select format('public.%I has user_id without ON DELETE CASCADE to auth.users', public_tables.relname)
    from public_tables
    join tables_with_user_id on tables_with_user_id.table_oid = public_tables.oid
    left join cascade_tables on cascade_tables.conrelid = public_tables.oid
    where cascade_tables.conrelid is null
  )
  select string_agg(issue, E'\n' order by issue)
  into failures
  from violations;

  if failures is not null then
    raise exception 'Account-deletion cascade audit failed:%', E'\n' || failures;
  end if;

  raise notice 'Account-deletion cascade audit passed.';
end
$account_deletion_audit$;
