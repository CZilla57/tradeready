-- Phase 12C (2026-08-07 portal-completion spec §8): security log for the
-- customer portal + durable per-token daily cap for the portal-request write
-- path. Sibling of 20260806_auto_invoice_email_log.sql. Applied out-of-band
-- via the Supabase SQL editor (no CLI runner in this repo). Service-role
-- writes (bypass RLS); the owner may read their own rows (reserved for a
-- future "portal was viewed" surface). NEVER stores a raw portal token —
-- token_prefix is the first 8 chars only.
create table if not exists public.portal_access_log (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  token_prefix text not null,
  event        text not null, -- 'request' | 'denied' (view/ics/photo reserved for Phase D)
  ip           text,
  created_at   timestamptz not null default now()
);

create index if not exists portal_access_log_cap_idx
  on public.portal_access_log (user_id, token_prefix, event, created_at);

alter table public.portal_access_log enable row level security;

create policy "read own portal access log"
  on public.portal_access_log for select
  using (auth.uid() = user_id);
