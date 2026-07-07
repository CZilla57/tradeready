-- subscriptions: server-side record of each user's subscription status.
-- Updated via RevenueCat webhooks (POST /api/subscription/webhook).
-- The mobile app uses the RevenueCat SDK as the primary entitlement source;
-- this table is for server-side verification, analytics, and compliance.
-- ON DELETE CASCADE ensures this row disappears when the user is deleted.

create table if not exists public.subscriptions (
  user_id            uuid        primary key references auth.users(id) on delete cascade,
  status             text        not null default 'inactive',
    -- 'trialing' | 'active' | 'cancelled' | 'expired' | 'inactive'
  plan               text,
    -- 'monthly' | 'annual'
  period_type        text,
    -- 'TRIAL' | 'NORMAL' | 'INTRO'
  expires_at         timestamptz,
  product_identifier text,
  updated_at         timestamptz not null default now()
);

alter table public.subscriptions enable row level security;

-- Users can read their own subscription row (e.g. for a server-verified settings screen).
-- All writes go through the backend using the service role key — no client write policy needed.
create policy "users read own subscription"
  on public.subscriptions for select
  using (auth.uid() = user_id);
