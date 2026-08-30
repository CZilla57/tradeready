# TradeReady Web Portal

A standalone web portal that lets a TradeReady user sign in from a browser
(target: **app.gettradereadyapp.com**) and work the same business data they see
in the mobile app.

It is a Vite + React + TypeScript single-page app that authenticates against the
**same Supabase project** as the mobile app and reads the same row-level-secured
tables. It does **not** run the React Native code — it reuses the mobile app's
canonical model types (`../types/models.ts`) and its react-native-free pure
utility helpers (`../utils/*`) through the `@shared` path alias.

## How it shares data with the app

Every synced table in Supabase is an owner-scoped blob:

```
{ id, user_id, data jsonb, updated_at, deleted }   -- RLS: auth.uid() = user_id
```

(plus `settings` keyed by `user_id`, and `customer_notes`). The portal signs the
user in with `@supabase/supabase-js`, then reads `data` from each table exactly
as the mobile sync layer does (`../utils/sync.ts`). RLS guarantees a session
only ever sees its own account's rows — the anon key is public by design (it
already ships inside the distributed mobile app bundle).

## Scope

Read-first portal:

- **Login** — email/password, Google OAuth, password reset
- **Reset password** (`/reset-password`) — the one place a signed-in-via-recovery
  user sets a new password (the only write to auth this portal performs)
- **Today** — today's scheduled jobs + earnings/outstanding summary
- **Calendar** — week view of scheduled jobs with work-day/blackout shading (via
  `resolveSchedule`) + a "needs scheduling" queue; week navigation
- **Jobs** — filterable list + job detail (status timeline, materials, customer, invoice)
- **Estimates** — estimate-stage jobs + detail (as-sent line items, approval
  status/signer, change orders, billable total)
- **Invoices** — list with status badges + detail (payments ledger, line items)
- **Customers** — list + detail (job & invoice history, revenue/owed)
- **Money** — collected / expenses / net / outstanding + 6-month revenue chart
- **Recurring** — recurring jobs + maintenance plans (cadence, next due, active)
- **Pricebook** — saved services + detail (materials, labor, margins)
- **Settings** — read-only business profile, pricing, invoicing, schedule,
  payments, and automation toggles (secret keys are never rendered)

Editing is intentionally out of scope. The write path
(`src/lib/repository.ts#upsertRecord`) is already wired to the same blob
contract for the editing surface that follows.

### Password recovery flow

The portal is otherwise read-only with respect to business data; the sole
mutation it performs is changing the signed-in user's own password.

1. From **Login → Forgot password?**, `resetPassword` calls
   `supabase.auth.resetPasswordForEmail(email, { redirectTo:
   <origin>/reset-password })`.
2. The emailed link returns to `/reset-password`. `detectSessionInUrl`
   establishes a short-lived recovery session and fires a one-shot
   `PASSWORD_RECOVERY` event.
3. `AuthContext` records that event in React state **and** a `localStorage`
   flag (`tradeready.passwordRecovery`) so recovery mode survives the re-render,
   a manual reload, **and a second/reopened tab** — the one-shot event fires
   only in the tab that consumed the link, but the flag lives in the same
   `localStorage` the Supabase session is persisted in, so every tab holding the
   recovery session stays in recovery mode. (A stale flag left with no live
   session is dropped on init.) While the flag is set, `App` routes every path
   to the password-update screen, so a recovery session can **not** fall through
   into the authenticated portal before the user finishes.
4. `ResetPasswordScreen` collects and validates a new password (min length +
   matching confirmation), calls `supabase.auth.updateUser({ password })`,
   then clears recovery, signs out, and redirects to `/login`.
5. Invalid, expired, or already-used links produce no session (Supabase encodes
   the reason in the URL fragment). The screen detects the absence of a recovery
   session, shows the reason, and offers a path back to request another reset
   email.

Not available on the web: mileage/**Trips** and the AI Coach — Trips are a
Supabase collection but not surfaced here yet; the AI Coach needs the
Cloudflare Worker backend rather than Supabase alone.

## Develop

```bash
cd web
npm install
npm run dev        # http://localhost:5173
```

Sign in with a real TradeReady account. Other scripts:

```bash
npm run typecheck  # tsc, no emit
npm run test       # vitest run (jsdom + Testing Library)
npm run build      # typecheck + production build to web/dist
npm run preview    # serve the production build locally
```

> Build note: `vite.config.ts` sets `esbuild.tsconfigRaw` to a string so Vite
> skips its per-file tsconfig lookup. Without it, esbuild walks up from the
> imported `../utils/*.ts` files to the Expo project's root `tsconfig.json`
> (which `extends "expo/tsconfig.base"`) and fails because that base config is
> not installed in this standalone workspace.

## Deploy (owner operations)

The build output in `web/dist` is a static SPA — host it anywhere (Cloudflare
Pages, Vercel, Netlify, or a Workers static asset binding). Because it uses
client-side routing, configure a **SPA fallback** so unknown paths serve
`index.html`.

1. **DNS / hosting** — point `app.gettradereadyapp.com` at the host serving
   `web/dist`, with the SPA fallback above.
2. **Supabase Auth → URL Configuration** — add the web origin
   (`https://app.gettradereadyapp.com`) **and** the recovery return path
   (`https://app.gettradereadyapp.com/reset-password`) to **Redirect URLs** so
   the Google OAuth and password-reset return handshakes are accepted. (The SPA
   fallback above is what lets `/reset-password` load on a fresh visit.)
3. **Google Cloud OAuth client** — add `https://app.gettradereadyapp.com` to
   **Authorized JavaScript origins** (and the Supabase callback URL to
   **Authorized redirect URIs** if not already present).

No new secrets are required — the portal uses only the public Supabase URL and
anon key.
