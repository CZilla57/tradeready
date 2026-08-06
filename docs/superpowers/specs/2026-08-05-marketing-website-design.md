# Marketing website for gettradereadyapp.com — design

**Date:** 2026-08-05 · **Status:** approved by owner (this session) · **Target repo:** `tradeready-legal` (sibling of this repo), plus one ASC listing follow-up

## Goal

Replace the support-page-at-the-root arrangement with a real marketing site: someone
visiting gettradereadyapp.com sees what TradeReady is and why to download it, not a
FAQ. Support and legal content stay fully reachable.

## Owner decisions (2026-08-05)

1. **Scope:** single-page marketing site at the root; support moves to `support.html`;
   legal/transactional pages unchanged.
2. **Visuals:** owner supplies real App Store / device screenshots; page ships with
   styled placeholders in fixed-filename slots until then.
3. **Design:** match the app's Blueprint design system.
4. **Hosting:** move the site to **Cloudflare Pages** (owner chose this over staying
   on GitHub Pages, accepting hosting churn during the Workers-migration monitoring
   window).

## Hard constraints

- **ASC Support URL is `https://gettradereadyapp.com/`** and Apple once rejected the
  app when the root 404'd (2026-07-24). The root must always serve a functional page,
  and support content must be prominently reachable from it. The listing's "Do not
  delete index.html" rule is honored: index.html becomes the marketing page and links
  to Support in header and footer. At the **next submission** the owner updates the
  ASC Support URL to `https://gettradereadyapp.com/support.html` (same deferred
  pattern as the legal-URL host move).
- **Every existing path must keep working byte-for-byte** through the hosting move:
  `privacy.html`, `terms.html`, `reset.html`, `confirmed.html` (hardcoded in
  app.json extra), `estimate.html` (Worker `ESTIMATE_PUBLIC_BASE`), `change.html`,
  `book.html`, `portal.html`, `get.html`, `supa.js`, CNAME semantics. Same repo, same
  filenames, new host.
- **Claims discipline** (launch-readiness skill): only device-smoked features are
  claimed. Approved sources: the 2026-08-01 store listing (`docs/app-store-listing.md`)
  plus later smoke-passed features (booking link, change orders, Today insights,
  estimate follow-up nudges). NEVER claim: route optimization, team accounts, web
  dashboard, contract review, customer portal (built, unmerged), trip cloud-sync
  (unsmoked), auto-invoice-on-complete (smoke pending), widgets (not shipped).
  Prices are claimable as configured: $19.99/mo, $199.99/yr, 2-week free trial.
- No testimonials/reviews are invented. None exist yet; the section is omitted.

## Architecture and cutover

**Verified 2026-08-05:** gettradereadyapp.com's nameservers are already Cloudflare
(`amy`/`elmo.ns.cloudflare.com`); apex A records point at GitHub Pages
(185.199.108–111.153); `www` CNAMEs to `czilla57.github.io`. So the Cloudflare Pages
custom-domain attach is an in-zone record flip — no registrar work, automatic TLS.

Phased rollout (each phase gates on the previous; owner go-ahead between phases per
change-control Rule 1):

1. **Build** — new `index.html` (marketing) + `support.html` (current support content
   verbatim, retitled) + `404.html` + `images/` + `fonts/` in `tradeready-legal`.
   Local browser verification. Nothing deployed yet; GitHub Pages would serve the new
   pages on push, which is acceptable (support stays reachable via prominent links).
2. **Pages project** — create Cloudflare Pages project `tradeready-site` connected to
   the `CZilla57/tradeready-legal` GitHub repo (owner one-time dashboard OAuth;
   production branch = default branch). Verify every pre-existing path returns 200
   with expected content on `<project>.pages.dev` before touching DNS.
3. **Domain flip** — attach `gettradereadyapp.com` and `www.gettradereadyapp.com` as
   custom domains on the Pages project (Cloudflare rewrites the zone records).
   `_redirects` file handles `www` → apex 301. GitHub Pages keeps serving until the
   flip; the repo's Pages config stays enabled afterwards so old
   `czilla57.github.io/tradeready-legal/*` links keep 301-ing to the apex.
4. **Follow-ups** — re-verify live apex + smart banner + one estimate/booking link
   end-to-end; owner updates ASC Support URL at next submission. Optionally disable
   GitHub Pages much later (NOT during the Workers-migration monitoring window).

**Rollback at any point:** detach the custom domains / re-point apex A records at
GitHub Pages IPs (still configured, still serving the same repo).

**CORS note:** the backend's two CORS policies and the 4th origin
(`czilla57.github.io`) are untouched — page origins don't change (`gettradereadyapp.com`),
and github.io 301s resolve to the apex anyway. Do not unify (standing warning).

## index.html structure

Self-contained HTML+CSS, no JS frameworks, no build step (matches every other page in
the repo). Sections in order:

1. **Header** — TradeReady wordmark, links: Features · Pricing · Support, App Store
   badge button.
2. **Hero** — headline + subhead aimed at independent tradespeople going out on their
   own; App Store badge CTA; device-framed hero screenshot slot. Subtle blueprint-grid
   background texture.
3. **Value strip** — Price it → Send it → Get paid, one line each.
4. **Five feature sections** (content mirrors the approved listing's groups):
   - *Price with confidence* — trades pricing calculator (labor, materials + markup,
     overhead, margin), break-even warnings, AI rate suggestions, pricebook.
   - *Win the work* — lead-to-paid pipeline, estimates → professional PDF by text or
     email, one-tap online estimate approval, booking link, recurring jobs.
   - *Get paid faster* — invoices in seconds, Stripe card-payment links with
     automatic mark-paid, deposits & partial payments, overdue reminders, AI-written
     follow-ups, change orders customers approve online.
   - *Know your numbers* — zero-setup AI business coach that knows your revenue and
     receivables; P&L, revenue trends, funnel, cash-flow forecast; expenses, mileage
     log, receipt scanning; tax set-aside.
   - *Works where you work* — fully offline, syncs when back in signal; secure cloud
     backup; job photos + customer history; dark mode.
5. **Screenshot gallery** — three framed slots interleaved near relevant sections.
6. **Pricing** — free to download; 2-week free trial; $19.99/month or $199.99/year;
   billed through Apple; cancel anytime in App Store settings.
7. **Footer** — Support, Privacy Policy, Terms, support@gettradereadyapp.com,
   © 2026 Chad Rector, "not affiliated with Apple Inc." line.

Meta/SEO: title ("TradeReady — job management & invoicing for tradespeople" family),
meta description, canonical `https://gettradereadyapp.com/`, Open Graph + Twitter
card (og:image generated from brand art), existing `apple-itunes-app` smart-banner
meta (app-id=6790681059), favicon + apple-touch-icon derived from the app icon.

## support.html

Current index.html content moved verbatim; `<title>` and `<h1>` become "TradeReady
Support"; adds a small header link back to the homepage. No content rewrites in this
project (FAQ copy is already good and review-proven).

## Screenshot contract

Fixed filenames under `images/` — owner drops files in, page upgrades automatically
on next deploy; until then each slot renders a Blueprint-styled placeholder frame:

| File | Content | Orientation |
|---|---|---|
| `images/hero-today.png` | Today screen | portrait iPhone |
| `images/shot-invoice.png` | Invoice with payment link | portrait iPhone |
| `images/shot-pricing.png` | Pricing calculator | portrait iPhone |
| `images/shot-chat.png` | AI coach chat | portrait iPhone |

Recommended: 6.7" App Store captures (1290×2796) or any same-ratio capture; light
mode preferred for contrast against the navy hero (dark variants optional later).

## Visual design

Blueprint system, matching the app and its public pages:

- **Type:** Chakra Petch (Bold) for display/headings; Public Sans
  (Regular/Medium/SemiBold/Bold) for body; IBM Plex Mono (Medium) for
  prices/numbers/labels.
- **Fonts self-hosted** in `tradeready-legal/fonts/` — copied from
  `tradeready/assets/fonts/` (OFL-licensed, license file copied alongside). TTF with
  `font-display: swap` is acceptable at these sizes (~80 KB each).
- **Palette:** ink-navy `#0c335e` family + the app's accent blue; light + dark themes
  via `prefers-color-scheme` like existing pages.
- Mobile-first responsive; readable at 375 px through desktop; no horizontal scroll.

## Verification

1. Local: open the page in the browser pane — both themes, mobile + desktop widths,
   all internal links, smart-banner meta present.
2. `pages.dev`: scripted 200-check + content spot-check of ALL pre-existing paths
   (the 11 files above) plus new ones before any DNS change.
3. Post-flip: live apex serves the new homepage; `/support.html`, `/privacy.html`,
   `/terms.html`, `/reset.html`, `/estimate.html` spot-checked live; `www` redirects;
   `czilla57.github.io/tradeready-legal/` still 301s.

## Out of scope

- Rewriting support/legal copy; the customer portal page; any app-repo code change;
  analytics on the website; email capture; blog/SEO content pages; disabling GitHub
  Pages (deferred, owner-gated, after the Workers monitoring window).

## Action ownership

- **[ENG]** build pages, fonts, images scaffolding, `_redirects`, 404; pages.dev
  verification scripts; post-flip verification.
- **[OWNER]** Cloudflare dashboard: create Pages project + GitHub OAuth connect;
  attach custom domains (or approve API-based attach); supply screenshots; update
  ASC Support URL at next submission.
