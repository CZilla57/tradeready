# Phase 3 Staging Backend Gate

This runbook prepares an isolated Cloudflare Worker and Supabase environment for
the destructive Phase 3 account-deletion rows. It does not authorize a deploy,
create paid resources, or permit production data to be used as staging.

## Current state

- `tradeready-backend-staging` is defined as a separate Wrangler environment.
- Its checked-in Supabase URL is the inert `https://staging.invalid` placeholder.
- Staging cron triggers are empty so a validation deploy cannot send reminders
  or automatic invoices.
- Staging R2 bindings use separate bucket names.
- `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` remain environment-specific
  Cloudflare secrets and must never be committed.
- The production Worker, Supabase URL, R2 buckets, and triggers are unchanged.
- The pinned Worker dependencies currently report zero npm audit findings.
- Seventeen dependency-free assertions pass against both backend shapes, and
  production/staging Wrangler dry-runs compile successfully.
- An inert local Wrangler smoke verified the actual Hono route: `OPTIONS`
  returned `200`, `GET` returned the bounded `405`, and an unauthenticated
  `POST` returned the bounded `401`, all with the expected CORS headers. No
  bearer token, Supabase request, deployment, or production mutation was used.

## Why deletion is one database operation

The backend first verifies the caller through `/auth/v1/user`, then calls the
server-only Auth admin deletion endpoint once. Every current public user-owned
table must have an `ON DELETE CASCADE` foreign key to `auth.users(id)`, allowing
PostgreSQL to remove relational data in the same transaction as the Auth user.
The previous table-by-table REST sequence could partially delete remote data if
one request failed after another succeeded.

R2 is outside PostgreSQL. Its private photo prefix is therefore purged only
after confirmed Auth deletion and is best-effort. Failure may leave inaccessible
objects for later operational cleanup, but it cannot produce a false failure
after the irreversible database boundary.

Supabase access JWTs are stateless. Deleting the Auth user removes refresh
sessions, but an access token already issued to another device can remain valid
until its `exp` time. TradeReady's current owner-equality RLS policies do not
also query `auth.sessions`. Before claiming permanent deletion in staging,
choose and verify one of these controls there:

- keep access-token lifetime short and explicitly accept/document the maximum
  residual window; or
- add a restrictive, session-aware RLS policy that requires the JWT's
  `session_id` to exist for the same user.

The second option changes authorization across every user-owned table and must
be proven with active, expired, signed-out, and deleted sessions in staging
before any production migration is considered.

## Provisioning checklist

Do not continue with this checklist until the owner has chosen a separate
TradeReady Supabase project or branch and accepted any associated cost.

1. Apply the repository migrations to the isolated Supabase environment.
2. Run `supabase/verify/account_deletion_cascade.sql` against that environment.
   It must report `Account-deletion cascade audit passed.`
3. Select and verify the residual access-token control described above.
4. Replace only `[env.staging.vars].SUPABASE_URL` in
   `backend-workers/wrangler.toml` with the isolated HTTPS project URL.
5. Create the two isolated buckets:

   ```sh
   cd backend-workers
   npx wrangler r2 bucket create tradeready-invoice-pdfs-staging
   npx wrangler r2 bucket create tradeready-photos-staging
   ```

6. Set only the staging Supabase credentials through interactive secret input:

   ```sh
   npx wrangler secret put SUPABASE_ANON_KEY --env staging
   npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY --env staging
   ```

7. Verify locally without deploying:

   ```sh
   npm test
   npm run check:staging
   ```

8. Review the generated configuration classification. It must name
   `tradeready-backend-staging`, contain no cron triggers, and reference only
   staging resources.
9. Deploy only after explicit owner authorization:

   ```sh
   npm run deploy:staging
   ```

10. An unauthenticated smoke request to `POST /api/delete-account` must return a
   bounded `401`. Do not send a real bearer token until the disposable-account
   D4/D5 device run.
11. After the deployed endpoint and its TLS URL are verified, update the native
    Release `TRADEREADY_BACKEND_URL` and rerun
    `native/run-phase-3-device-preflight.sh`.

## Evidence boundary

Host tests and the inert local route smoke prove request order, response
mapping, secret containment, failure behavior, configuration shape, and the
Hono-to-core adapter. They do not prove a deployed Worker, a staging Supabase
cascade, physical-device local cleanup, or relaunch after deletion. D4 and D5
stay pending until those steps use an approved disposable account on the
signed iPhone.
