-- stripe_accounts: maps each user to their connected Stripe Express account.
-- Written by the backend (service role key) after the user completes Connect onboarding.
-- The mobile app never writes to this table directly.

create table if not exists stripe_accounts (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  stripe_account_id text not null,
  created_at       timestamptz default now()
);

alter table stripe_accounts enable row level security;

-- Users can read their own row (e.g. to verify the link from a client).
-- No insert/update/delete policy from the client — the backend uses the service role key.
create policy "users read own stripe account"
  on stripe_accounts for select
  using (auth.uid() = user_id);
