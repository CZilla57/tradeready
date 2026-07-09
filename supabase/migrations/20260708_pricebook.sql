-- pricebook: stores each user's reusable service templates.
-- Synced from the mobile app via the standard JSONB collection sync pattern.
-- Each row is one PricebookEntry; the full typed object lives in `data`.

create table if not exists public.pricebook (
  id         text        primary key,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  data       jsonb,
  updated_at timestamptz not null default now(),
  deleted    boolean     not null default false
);

alter table public.pricebook enable row level security;

create policy "users read own pricebook entries"
  on public.pricebook for select
  using (auth.uid() = user_id);

create policy "users insert own pricebook entries"
  on public.pricebook for insert
  with check (auth.uid() = user_id);

create policy "users update own pricebook entries"
  on public.pricebook for update
  using (auth.uid() = user_id);
