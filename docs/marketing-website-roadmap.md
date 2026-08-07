# Marketing Website Roadmap — gettradereadyapp.com

**Created:** 2026-08-07, from an external (Codex) passive review of the live site dated
2026-08-07, with every finding re-verified against the `tradeready-legal` repo and live
response headers before inclusion. Findings Codex got wrong or that conflict with
owner-accepted decisions are listed in "Rejected / adjusted" at the bottom — do not
re-open them.

**Where work lands:** all website changes go in the **`tradeready-legal` repo (branch
`main`)** — it deploys automatically via Cloudflare Pages project `tradeready-site`.
App-side items (trip-sync smoke) are noted where they gate website copy.

---

## Standing constraints (carry into every phase)

These override anything below. Breaking one is a release blocker, not a style choice.

1. **The apex `/` must NEVER 404.** It is the App Store Connect Support URL (Apple
   rejected the app over this 2026-07-24). Owner flips ASC Support URL to
   `/support.html` at the next submission — not before.
2. **Do not rename or "fix" `.html` paths.** Cloudflare Pages 308-redirects
   `.html` → extensionless; this is owner-accepted behavior. All pre-existing paths
   (privacy/terms/reset/confirmed/estimate/change/book/booking/portal/get/supa.js) are
   hardcoded consumers (app.json extra, Worker `ESTIMATE_PUBLIC_BASE`, Supabase
   allowlist) and must stay byte-compatible in URL terms.
3. **Claims discipline:** the homepage may only claim smoke-passed, shipped-to-users
   features. Never add: route optimization, team accounts, web dashboard, customer
   portal, widgets — and no fabricated ratings, quotes, or metrics, ever.
4. **Screenshot contract:** every committed screenshot `.jpg` has a `.webp` sibling
   that browsers prefer. Replacing a jpg without regenerating its webp serves the
   stale webp. Regen commands live in `tradeready-legal/images/README.md`.
5. **The Workers backend CORS setup (two policies + czilla57.github.io origin) is
   intentional.** Nothing in this roadmap touches backend CORS. Don't unify.

---

## Phase W1 — Security headers + security.txt

**✅ SHIPPED + ENFORCING 2026-08-07** — `tradeready-legal` `6e0965c` (headers
report-only + security.txt) then `96b6277` (owner-approved enforce flip). Live
verification: all four headers on marketing + transactional paths, every path
still 200, security.txt 200, and zero CSP violations/console errors across
index, reset (CDN supabase-js + SRI loads), book, booking, estimate, change,
portal, and confirmed under the **enforcing** policy, with backend round-trips
confirmed. Maintenance rule: any new external script/CDN/API host must be added
to the `_headers` allowlist or it will be silently blocked.

*Codex priority 1 (verified: live response has only `nosniff` + referrer-policy;
HSTS, CSP, Permissions-Policy, and frame-ancestors/X-Frame-Options are all absent;
no `_headers` file exists in the repo). Highest-value, but CSP is the one item in
this roadmap that can break live flows — treat it with real care.*

- [ ] Add a `_headers` file to `tradeready-legal` covering all paths (`/*`):
  - `Strict-Transport-Security: max-age=15552000; includeSubDomains` — 180 days, **no
    `preload`** initially (preload is effectively irreversible; revisit after a clean
    quarter). Alternative: enable HSTS at the Cloudflare zone level instead — pick one
    home, not both.
  - `X-Frame-Options: DENY` and CSP `frame-ancestors 'none'` (belt and braces; no page
    on this site should ever be framed).
  - `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()`.
- [ ] **CSP in two steps.** Start with `Content-Security-Policy-Report-Only` and watch
  for violations before enforcing. The policy must account for:
  - inline `<style>`/`<script>` blocks used throughout the site (`'unsafe-inline'` or
    a hash-based approach);
  - `supa.js` (self-hosted, fine under `script-src 'self'`);
  - `connect-src` for the Workers backend (`tradeready-backend.tradeready.workers.dev`)
    and Supabase — **estimate.html, change.html, book.html, booking.html, portal.html,
    reset.html, and confirmed.html are live transactional pages**, and a careless CSP
    silently breaks estimate approval, password reset, and online booking;
  - Cloudflare's analytics beacon (`static.cloudflareinsights.com`).
- [ ] Publish `/.well-known/security.txt` per RFC 9116: `Contact:
  mailto:support@gettradereadyapp.com`, `Expires:` ~1 year out, `Canonical:` URL.
- [ ] **Acceptance:** every existing path still returns 200/308 as before; estimate
  approval, password reset, and booking smoke-tested E2E on the live site with the
  enforced CSP; headers verified with a fresh curl.

## Phase W2 — Claims and privacy truth-up

**✅ SHIPPED 2026-08-07** — `tradeready-legal` `71cfb41`, all three items
live-verified. Resolutions: homepage narrowed "everything syncs" → "your work
syncs" (the trip-sync device smoke is still pending — restore the absolute only
after it passes); privacy retention bullet now covers encrypted backups (≤30
days — conservative vs Supabase's 28-day PITR max; owner may tighten after
confirming the plan's actual backup config), crash/diagnostic reports (≤90
days, Sentry default), support emails, and a legal-hold carve-out; support page
now carries the never-send-sensitive-data warning.

*Codex priorities 2–3, corrected against current app state (its app audit was stale).*

- [ ] **"Fully offline — everything syncs" / "secure cloud backup"
  (index.html:394–395):** the sync-durability work has since landed (local collections
  sync migration applied, backend redeployed 2026-08-04), so these claims are much
  closer to true than Codex's stale audit suggested. The one residual: **trip/mileage
  sync is code-complete but not device-smoked.** Action: run the trip-sync device
  smoke (app-side, owner). If it passes, the claims stand as written; if it can't be
  scheduled soon, narrow line 394 to name the record types that are proven to sync.
- [ ] **Privacy deletion wording (privacy.html:80,82):** "immediately" is accurate for
  the live database (the delete-account endpoint hard-deletes) but the policy is
  silent on other copies. Add a short retention paragraph covering: encrypted database
  backups (state the actual Supabase backup/PITR window — owner to confirm from the
  dashboard before we write a number), support emails (kept as correspondence),
  diagnostic/crash data (Sentry retention), and a legally-required-retention carve-out.
  Give one honest maximum ("removed from live systems immediately; residual copies in
  backups expire within N days").
- [ ] **Support-page data warning (support.html, near line 79):** one line — "Never
  include passwords, payment card numbers, or your customers' personal details in a
  support email. We only need your sign-in email address."

## Phase W3 — Mobile ergonomics and accessibility

**✅ SHIPPED 2026-08-07** — `tradeready-legal` `807ada4` + `44b49ee`/`08becc3`
(tap-target 1px fixes after live measurement). Live-verified at 375px and
1280px, light + dark: steps headings h3→h2 (heading order now h1→h2), skip
link (drops in on focus, verified programmatically), nav links 44px, footer
links 45px, theme-color meta, sticky desktop header 80px < 84px
scroll-padding, no horizontal overflow. **Correction:** the italic note below
is WRONG — the mobile topbar was already `position: static` ≤720px (a
max-width block later in the stylesheet); Codex's sticky-mobile-header
complaint was mistaken, and no un-stick change was needed.

*Codex design items 1–2, verified in source. The two-row mobile nav is sticky at ALL
widths (`.topbar { position: sticky }` with no media gate — index.html:64), so Codex's
~104px-of-sticky-viewport complaint is correct.*

- [ ] Mobile header: either un-stick the topbar below 721px or collapse nav links into
  a compact menu so the sticky cost is one row. Keep the wordmark + App Store CTA
  always reachable.
- [ ] Tap targets to ≥44px: mobile nav links (~35px) and footer links (~17px) — the
  footer item was already on the known-open list from the 2026-08-06 UX pass.
- [ ] Heading order: the steps strip renders H1 (line 226) → 3× H3 (266–276) → first
  H2 (285). Make "Price it / Send it / Get paid" H2s (or nest them under a shared H2)
  — also already known-open.
- [ ] Add a skip-to-content link as the first focusable element.
- [ ] Add `theme-color` meta (known-open from the UX pass).

## Phase W4 — SEO and indexing hygiene

**✅ SHIPPED 2026-08-07** — `tradeready-legal` `a4b72d1`, all items live-verified:
noindex on all 7 transactional pages (and confirmed absent on the 4 marketing
pages), robots.txt + sitemap.xml (4 extensionless URLs), SoftwareApplication
JSON-LD on the homepage (parses in the live DOM, no CSP issues, no
aggregateRating). Also aligned canonicals with the extensionless URL forms:
support's `.html` canonical corrected, privacy/terms canonicals added.

*Codex noted the missing sitemap and structured data. The bigger gap it missed: the
transactional pages are indexable.*

- [ ] **`noindex` the seven transactional pages** — estimate.html, change.html,
  book.html, booking.html, portal.html, reset.html, confirmed.html (get.html already
  has it, use it as the template). These are tokenized utility pages; letting search
  engines index them risks stale/broken results surfacing for the brand query.
- [ ] `robots.txt` + `sitemap.xml` listing only the four marketing pages: `/`,
  `/support.html`, `/privacy.html`, `/terms.html`.
- [ ] `SoftwareApplication` JSON-LD on the homepage: real names, category, `offers`
  with the real prices ($19.99/mo, $199.99/yr). **No `aggregateRating` until real App
  Store ratings exist** — fabricating one violates the claims rule and Google's
  guidelines.

## Phase W5 — Support and legal page visual alignment

**✅ SHIPPED 2026-08-07** — `tradeready-legal` `7f72765` (built by a subagent,
reviewed + live-verified). support.html: full Blueprint treatment (navy topbar,
drafting-grid page band, title-block footer); mono email at clamp size renders
single-line at 375px (old mid-word break gone). privacy/terms: lighter
same-family shell, and they gained the dark scheme they never had. Text-diff
confirmed every sentence verbatim; zero external resources; zero JS; fonts
verified loading live under the enforced CSP.*

*Codex design item 4.*

- [ ] Restyle support.html (and give privacy/terms a lighter version of the same
  shell) with the Blueprint identity — title-block header, sheet framing — so the
  jump from the homepage isn't jarring. Content stays verbatim; this is chrome only.
- [ ] Fix the support email wrapping (`word-break: break-word` on a 40-char address
  produces ugly mid-word breaks at 390px; wrap the whole address or shrink it).

## Phase W6 — Content growth (gated)

**◐ PARTIAL 2026-08-07** — the one ungated item shipped: `/whats-new.html`
(`tradeready-legal` commit, approved ASC What's New copy verbatim for 1.1 +
1.0, legal-page shell, in sitemap, linked from the homepage footer Rev cell).
Still gated and NOT done: **booking section** (client OTA not shipped — a
fact-checked, paste-ready section is staged in
`docs/website-booking-section-staged.md`), **social proof** (no real ratings
yet), **screenshot refresh** (needs owner assets).

*Codex design item 3 plus forward-looking additions. Every item here has an explicit
gate — none are "just do it".*

- [ ] **Online booking feature section** — the calendar/availability/booking feature
  is merged and owner-smoked E2E, but the client rides the NEXT OTA. Add a homepage
  section ("Let customers book you online") only **after** the OTA ships to users.
  This is the strongest new marketing claim available and it's nearly unlocked.
- [ ] **Social proof** — gate: real App Store ratings/reviews exist. Then one
  restrained section: verified rating and/or a genuine quote. Never invented metrics.
- [ ] **Screenshot refresh** as new features ship (calendar view is a good candidate)
  — follow the webp regeneration contract (constraint 4).
- [ ] Optional, owner's call: a lightweight `/whats-new.html` release-notes page —
  gives returning visitors and App Review a change trail; zero forms, zero JS.

---

## Rejected / adjusted from the Codex review

- **"Tax money 'earmarked' overclaims"** — rejected. "Earmark a slice of every
  payment" (index.html:371) accurately describes the feature: it designates and
  tracks a portion, and never claims to move money. Wording stands.
- **"Maintenance visits 'schedule themselves' overclaims"** — rejected. Recurring
  jobs are shipped and smoked; the recurrence engine genuinely auto-generates the
  visits. Acceptable marketing register.
- **"Sync claims contradict the app audit"** — adjusted, not accepted as-is. Codex's
  underlying audit predates the sync-durability work that landed 2026-08-04. Only the
  trip-sync smoke residual remains (Phase W2).
- **`Access-Control-Allow-Origin: *`** — agree it's harmless here, and note it is
  injected at the platform level (no `_headers` file exists in the repo to remove).
  Left as-is for static content; the Workers backend has its own deliberate CORS
  setup (constraint 5) and will not inherit anything from Pages.
- **Anything implying the `.html` → extensionless 308s need fixing** — owner-accepted
  behavior (constraint 2). Codex didn't flag it, but any future reviewer will;
  pre-rejected here.

## Suggested order

W1 (headers, biggest risk-reduction) → W2 (honesty items, cheap) → W4 (indexing
hygiene, cheap) → W3 (mobile/a11y) → W5 (visual alignment) → W6 (as gates unlock).
W1's CSP-enforce switch, the Supabase backup-window number (W2), the trip-sync smoke
(W2), and both W6 gates are owner checkpoints.
