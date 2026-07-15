-- Phase 2: one-and-done auto-reminder audit + send-once guard.
-- Apply via the Supabase migration flow (see docs/run-and-operate). The cron
-- writes rows with the service role (bypasses RLS); the app reads its own rows.
create table if not exists public.auto_reminder_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  invoice_id text not null,
  to_email   text,
  sent_at    timestamptz not null default now(),
  status     text not null default 'sent',   -- 'sent' | 'failed'
  error      text,
  unique (user_id, invoice_id)
);

alter table public.auto_reminder_log enable row level security;

create policy "read own reminder log"
  on public.auto_reminder_log for select
  using (auth.uid() = user_id);
