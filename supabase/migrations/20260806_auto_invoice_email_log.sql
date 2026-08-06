-- Fully-automatic invoice emailing (2026-08-06 spec): one-and-done audit +
-- send-once guard for the 15-minute invoice-email sweep. Sibling of
-- 20260715_auto_reminder_log.sql; schema of record for
-- backend-workers/lib/sendInvoiceEmails.js.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- The cron writes rows with the service role (bypasses RLS); the app reads its
-- own rows (owner-read policy below — unused in V1, reserved for the in-app
-- "Emailed on <date>" follow-up).
create table if not exists public.auto_invoice_email_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  invoice_id text not null,
  to_email   text,
  sent_at    timestamptz not null default now(),
  status     text not null default 'pending', -- 'pending' | 'sent' | 'failed'
  error      text,
  unique (user_id, invoice_id)
);

alter table public.auto_invoice_email_log enable row level security;

create policy "read own invoice email log"
  on public.auto_invoice_email_log for select
  using (auth.uid() = user_id);
