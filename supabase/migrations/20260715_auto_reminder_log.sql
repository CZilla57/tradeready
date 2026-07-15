-- Phase 2 (overdue auto-outreach): one-and-done auto-reminder audit + send-once guard.
-- Schema of record for the auto-email cron (backend/api/cron/send-reminders.js).
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- The cron writes rows with the service role (bypasses RLS); the app reads its own rows.
create table if not exists public.auto_reminder_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  invoice_id text not null,
  to_email   text,
  sent_at    timestamptz not null default now(),
  status     text not null default 'pending', -- 'pending' | 'sent' | 'failed'
  error      text,
  unique (user_id, invoice_id)
);

alter table public.auto_reminder_log enable row level security;

create policy "read own reminder log"
  on public.auto_reminder_log for select
  using (auth.uid() = user_id);
