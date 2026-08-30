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

## Scope (v1)

Read-first portal:

- **Login** — email/password, Google OAuth, password reset
- **Today** — today's scheduled jobs + earnings/outstanding summary
- **Jobs** — filterable list + job detail (status timeline, materials, customer, invoice)
- **Invoices** — list with status badges + detail (payments ledger, line items)
- **Customers** — list + detail (job & invoice history, revenue/owed)
- **Money** — collected / expenses / net / outstanding + 6-month revenue chart

Editing is intentionally out of scope for v1. The write path
(`src/lib/repository.ts#upsertRecord`) is already wired to the same blob
contract for the editing surface that follows.

## Develop

```bash
cd web
npm install
npm run dev        # http://localhost:5173
```

Sign in with a real TradeReady account. Other scripts:

```bash
npm run typecheck  # tsc, no emit
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
   (`https://app.gettradereadyapp.com`) to **Redirect URLs** so the Google
   OAuth and password-reset return handshakes are accepted.
3. **Google Cloud OAuth client** — add `https://app.gettradereadyapp.com` to
   **Authorized JavaScript origins** (and the Supabase callback URL to
   **Authorized redirect URIs** if not already present).

No new secrets are required — the portal uses only the public Supabase URL and
anon key.
