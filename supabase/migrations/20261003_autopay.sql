-- Card on file & autopay for recurring invoices (Roadmap Phase 24,
-- docs/superpowers/specs/2026-10-03-card-on-file-autopay-design.md §3.1;
-- owner decision 24-Q1 approved 2026-10-03).
--
-- Two SERVER-OWNED tables. Only the Worker writes them, with the service
-- role (backend-workers/lib/autopay/*, lib/pay/*). RLS is enabled with
-- owner-read policies only, following 20260806_auto_invoice_email_log.sql;
-- there are deliberately NO insert/update/delete policies, so no client can
-- write a consent record or a charge claim. Rows hold no card numbers: only
-- brand, last 4, expiry and Stripe ids. Both cascade on account deletion.
-- The owner role reads enrollments through a column grant that leaves out
-- the consent IP and user agent (spec §4.8: never sent to the owner); the
-- Worker reads everything with the service role.
--
-- Applied out-of-band by the owner (no CLI runner in this repo), BEFORE the
-- Worker deploy (spec §9 step 3). Then run:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20261003_autopay_verify.sql
-- Dormant Vercel twin: none. backend/ never reads these tables.

-- One row per customer authorization ("enrollment") for one recurring plan.
-- pending  → a consenting checkout started (consent record already stored)
-- active   → Stripe confirmed a saved card (webhook activation)
-- revoked  → turned off by the customer, the owner or the system
-- replaced → superseded by a newer active enrollment for the same plan
-- The consent record (text, version, time, IP, user agent) survives
-- revocation for dispute evidence.
create table if not exists public.autopay_enrollments (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  stripe_account_id     text not null,           -- account at consent; must equal stripe_accounts at charge time
  customer_id           text not null,           -- TradeReady customers.id (plan.customerId at consent)
  recurring_invoice_id  text not null,           -- TradeReady plan id
  stripe_customer_id    text not null,           -- cus_… on the connected account
  payment_method_id     text,                    -- pm_…; null while pending
  card_brand            text, card_last4 text, card_exp_month int, card_exp_year int, card_wallet text,
  billing_email         text,                    -- Checkout-entered email (receipts fall back to it)
  max_amount_cents      integer not null check (max_amount_cents > 0),
  status                text not null check (status in ('pending','active','revoked','replaced')),
  consent_version       text not null,
  consent_text          text not null,           -- exactly what was shown
  consented_at          timestamptz not null default now(),
  consent_ip            text, consent_user_agent text,
  checkout_session_id   text unique,
  activated_at          timestamptz, revoked_at timestamptz,
  revoked_by            text check (revoked_by in ('customer','owner','system')),
  revoke_reason         text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- At most one active authorization per plan. Activation replaces the prior
-- active row first, then activates the new one.
create unique index if not exists autopay_one_active_per_plan
  on public.autopay_enrollments (user_id, recurring_invoice_id) where status = 'active';
create index if not exists autopay_by_customer on public.autopay_enrollments (user_id, customer_id);

-- One automatic charge attempt per invoice, ever (v1 writes attempt = 1 only;
-- the column keeps a later owner-triggered retry additive). The unique key is
-- the claim: the sweep inserts first with on_conflict + ignore-duplicates, so
-- two concurrent sweeps can never both charge the same invoice.
create table if not exists public.autopay_charges (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  invoice_id         text not null,
  enrollment_id      uuid not null references public.autopay_enrollments(id) on delete cascade,
  attempt            smallint not null default 1,
  amount_cents       integer not null,
  status             text not null check (status in ('claimed','succeeded','failed','skipped')),
  payment_intent_id  text,
  charge_sent_at     timestamptz,             -- stamped right before paymentIntents.create; once set the claim is never released (§13.7)
  failure_code       text, decline_code text, failure_message text,
  customer_notified_at timestamptz, owner_notified_at timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (user_id, invoice_id, attempt)
);

-- Re-runs over an earlier draft of this table (unapplied, so local only).
alter table public.autopay_charges add column if not exists charge_sent_at timestamptz;

-- The owner status route reads the last 120 days per user.
create index if not exists autopay_charges_by_user_created
  on public.autopay_charges (user_id, created_at desc);

alter table public.autopay_enrollments enable row level security;
alter table public.autopay_charges enable row level security;

drop policy if exists "read own autopay enrollments" on public.autopay_enrollments;
create policy "read own autopay enrollments"
  on public.autopay_enrollments for select
  using (auth.uid() = user_id);

drop policy if exists "read own autopay charges" on public.autopay_charges;
create policy "read own autopay charges"
  on public.autopay_charges for select
  using (auth.uid() = user_id);

-- Grants (review fix 2026-10-04, spec §13.7). Hosted Supabase grants every
-- new public table to anon/authenticated, and the owner-read policies above
-- would then expose every column over PostgREST, including the customer's
-- consent IP and user agent. No client reads these tables (the app goes
-- through the Worker's owner routes, which use the service role), so the
-- client roles get exactly the owner-read surface: enrollments minus the
-- consent IP / user agent, and charges. No client write grants at all.
revoke all on table public.autopay_enrollments from public, anon, authenticated;
revoke all on table public.autopay_charges from public, anon, authenticated;
grant select, insert, update, delete on table public.autopay_enrollments to service_role;
grant select, insert, update, delete on table public.autopay_charges to service_role;
grant select (
  id, user_id, stripe_account_id, customer_id, recurring_invoice_id, stripe_customer_id,
  payment_method_id, card_brand, card_last4, card_exp_month, card_exp_year, card_wallet,
  billing_email, max_amount_cents, status, consent_version, consent_text, consented_at,
  checkout_session_id, activated_at, revoked_at, revoked_by, revoke_reason, created_at, updated_at
) on public.autopay_enrollments to authenticated;
grant select on table public.autopay_charges to authenticated;
