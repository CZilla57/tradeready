-- Supabase-shaped scaffolding for a THROWAWAY local Postgres. Not a migration:
-- it only recreates what the hosted project provides (roles, auth.uid(), the
-- `extensions` schema for pgcrypto, default grants to the API roles, and the
-- blob-sync tables that were created in the SQL editor, not in this repo).
-- Never run this against a real project.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema if not exists extensions;
-- Hosted Supabase installs pgcrypto into `extensions`, NOT `public`.
create extension if not exists pgcrypto schema extensions;

create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

grant usage on schema public, extensions, auth to anon, authenticated, service_role;
-- The hosted default: every new public object is granted to the API roles.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- Sync tables (shape inferred from the migrations' reads/writes).
create table public.settings (user_id uuid primary key references auth.users(id), data jsonb not null default '{}', updated_at timestamptz not null default now());
create table public.jobs (id text primary key, user_id uuid not null references auth.users(id), data jsonb not null default '{}', deleted boolean not null default false, updated_at timestamptz not null default now());
create table public.customers (id text primary key, user_id uuid not null references auth.users(id), data jsonb not null default '{}', deleted boolean not null default false, updated_at timestamptz not null default now());
create table public."bookingRequests" (id text primary key, user_id uuid not null references auth.users(id), data jsonb not null default '{}', deleted boolean not null default false, updated_at timestamptz not null default now());
create table public.portal_tokens (token_hash text primary key, user_id uuid not null references auth.users(id), customer_id text not null, enabled boolean not null default true, revoked_at timestamptz, created_at timestamptz not null default now());
