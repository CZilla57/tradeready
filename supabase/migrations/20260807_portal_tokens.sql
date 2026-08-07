-- Phase 12D (2026-08-07 portal-completion spec §3a, decision D1-A): portal
-- capability tokens move to a server-owned table. Stores sha256 HASHES only —
-- the raw token appears exactly once in the mint/rotate response. The device
-- keeps a display copy in Customer.portal; THIS table is the auth authority:
-- disable and rotate take effect on the next request, no sync round-trip.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this
-- repo). Service-role writes; the device never reads it (the owner-read
-- policy below is the multi-tenant floor rule, reserved for future use).
create table if not exists public.portal_tokens (
  token_hash  text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  customer_id text not null,
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz  -- one-way: rotate stamps it; nothing clears it
);

create index if not exists portal_tokens_customer_idx
  on public.portal_tokens (user_id, customer_id);

alter table public.portal_tokens enable row level security;

create policy "read own portal tokens"
  on public.portal_tokens for select
  using (auth.uid() = user_id);
