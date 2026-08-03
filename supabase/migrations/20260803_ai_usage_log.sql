-- Security roadmap item 8: durable per-user daily usage cap for the AI proxy
-- endpoints (backend/api/ai-chat.js, pricebook-suggest.js, receipt-extract.js).
-- The in-memory limiter in backend/lib/guards.js is per-Lambda-instance, so a
-- throwaway account spread across instances/cold-starts was effectively
-- unmetered against the owner's Groq key. This table is the durable layer:
-- backend/lib/aiUsage.js inserts one row per allowed request and gates on a
-- count of today's rows for that user+endpoint.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
--
-- Only the backend touches this table, with the service role (bypasses RLS).
-- RLS is enabled with NO policies at all: unlike auto_reminder_log (which the
-- app reads to show reminder history), no in-app feature displays AI usage, so
-- authenticated users get neither SELECT nor INSERT/UPDATE — a client-visible
-- counter would only tell a probing client exactly how the cap is enforced.
create table if not exists public.ai_usage_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  endpoint   text not null, -- 'ai-chat' | 'pricebook-suggest' | 'receipt-extract'
  created_at timestamptz not null default now()
);

-- The hot query: count today's rows for one user + endpoint.
create index if not exists ai_usage_log_user_endpoint_created_idx
  on public.ai_usage_log (user_id, endpoint, created_at);

alter table public.ai_usage_log enable row level security;
-- Deliberately no policies: deny-all for anon/authenticated roles.
-- The service role bypasses RLS, which is the only intended access path.
