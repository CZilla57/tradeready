# Marketing Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a single-page Blueprint-brand marketing homepage at gettradereadyapp.com (moving support to support.html) and cut the site's hosting over from GitHub Pages to Cloudflare Pages.

**Architecture:** All work happens in the `C:\dev\tradeready\tradeready-legal` git repo (static files, no build step). New files: `support.html` (old index content), new marketing `index.html`, `404.html`, `_redirects`, `fonts/`, `images/`. Hosting cutover is a separate, owner-gated pair of phases: Cloudflare Pages project on `pages.dev` first, custom-domain flip second. GitHub Pages stays intact as rollback.

**Tech Stack:** Hand-rolled HTML+CSS (+ trivial inline JS for image fallback), self-hosted OFL fonts, PowerShell System.Drawing for one-off icon/og-image generation, Cloudflare Pages (git-connected).

**Spec:** `docs/superpowers/specs/2026-08-05-marketing-website-design.md` (this repo). Read it first.

## Global Constraints

- **Never delete or 404 the root.** `index.html` must always serve a real page (ASC Support URL points at `/`; Apple rejected a 404 root on 2026-07-24).
- **Every pre-existing path keeps working unchanged:** `privacy.html`, `terms.html`, `reset.html`, `confirmed.html`, `estimate.html`, `change.html`, `book.html`, `portal.html`, `get.html`, `supa.js`, `CNAME`, `.nojekyll`. Do not edit any of them in this project (support content *moves out of* `index.html`, which is a rewrite of that one file only).
- **Claims discipline:** only these features may be named: everything in `tradeready/docs/app-store-listing.md` (2026-08-01 version) plus booking link, change orders, estimate follow-up nudges. NEVER mention: route optimization, team accounts, web dashboard, contract review, customer portal, trip cloud-sync, auto-invoice-on-complete, widgets. No testimonials.
- **Pricing copy verbatim:** free to download · 2-week free trial · $19.99/month or $199.99/year · billed through Apple · cancel anytime in App Store settings.
- **No new dependencies, no build step, no frameworks.** Inline CSS per page, same as every existing page in the repo.
- **Owner phase gates (change-control Rule 1):** STOP and report after Phase 1 (build), Phase 2 (pages.dev verify), Phase 3 (domain flip). Never run ahead.
- The `tradeready-legal` repo has no test gate; every task's "test" is a browser/HTTP verification step and must actually be run.
- Commits in `tradeready-legal`: imperative subject, optional `feat:`/`fix:` prefix, end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- App Store URL: `https://apps.apple.com/app/id6790681059` · app id meta: `app-id=6790681059` · support email: `support@gettradereadyapp.com`.

## Blueprint tokens (source: `tradeready/utils/theme.ts`, verified 2026-08-05)

```css
:root {
  --bg: #f5f5f1;            /* vellum */
  --surface: #ffffff;
  --ink: #14213d;           /* textPrimary */
  --muted: #8b93a3;
  --accent: #1d5c9e;        /* blueprint blue */
  --accent-bg: #e4eef7;
  --hero-navy: #0c335e;     /* splash navy — hero band, both themes */
  --hero-ink: #f2f4f8;      /* text on navy */
  --line: #d8dbe2;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #101826;
    --surface: #182238;
    --ink: #f2f4f8;
    --muted: #6e7789;
    --accent: #5b9bdb;
    --accent-bg: #1b2c40;
    --line: #2a3650;
  }
}
```

Type: Chakra Petch 700 for display/headings; Public Sans 400/500/600/700 body; IBM Plex Mono 500 for prices/eyebrow labels. All self-hosted, `font-display: swap`.

---

### Task 1: Move support content to support.html

**Files:**
- Create: `C:\dev\tradeready\tradeready-legal\support.html`

**Interfaces:**
- Produces: `/support.html` URL that Task 3's header/footer links target.

- [ ] **Step 1: Create support.html from current index.html**

Copy `index.html` → `support.html` byte-identical, then make exactly these edits:
1. `<title>Support — TradeReady</title>` → `<title>TradeReady Support</title>`
2. After `<div class="brand">TradeReady</div>` add a back-link line:
   `<p class="meta" style="margin-bottom:0"><a href="/">← gettradereadyapp.com home</a></p>`
3. Add `<link rel="canonical" href="https://gettradereadyapp.com/support.html">` in `<head>`.

Everything else (FAQ copy, styles, dark mode, CTA) stays identical — the copy is review-proven; do not rewrite it.

- [ ] **Step 2: Verify locally**

Start the existing preview config (`.claude/launch.json` name `legal-site`, npx serve on :3456) and load `http://localhost:3456/support.html`. Expected: page renders identical to the old support page plus the home back-link; all links work (`privacy.html`, `terms.html`, mailto, App Store).

- [ ] **Step 3: Commit**

```bash
git add support.html
git commit -m "feat: move support page content to support.html ahead of marketing homepage"
```

(index.html is NOT modified in this task — the root keeps serving support until Task 3 replaces it atomically.)

---

### Task 2: Brand assets — fonts, icons, og-image, images contract

**Files:**
- Create: `C:\dev\tradeready\tradeready-legal\fonts\` (ChakraPetch-Bold.ttf, PublicSans-Regular.ttf, PublicSans-Medium.ttf, PublicSans-SemiBold.ttf, PublicSans-Bold.ttf, IBMPlexMono-Medium.ttf, OFL.txt — copied from `C:\dev\tradeready\tradeready\assets\fonts\`)
- Create: `favicon.png` (48×48), `apple-touch-icon.png` (180×180), `og-image.png` (1200×630) — generated from `C:\dev\tradeready\tradeready\assets\icon.png`
- Create: `images\README.md` (screenshot drop-in contract)

**Interfaces:**
- Produces: font files at `/fonts/<name>.ttf`, icons at `/favicon.png`, `/apple-touch-icon.png`, `/og-image.png`, and the four screenshot paths Task 3 references: `/images/hero-today.png`, `/images/shot-invoice.png`, `/images/shot-pricing.png`, `/images/shot-chat.png` (absent until owner supplies).

- [ ] **Step 1: Copy fonts**

```powershell
New-Item -ItemType Directory -Force C:\dev\tradeready\tradeready-legal\fonts
Copy-Item C:\dev\tradeready\tradeready\assets\fonts\* C:\dev\tradeready\tradeready-legal\fonts\
```

- [ ] **Step 2: Generate favicon, touch icon, og-image with System.Drawing**

```powershell
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile('C:\dev\tradeready\tradeready\assets\icon.png')
foreach ($spec in @(@{n='favicon.png';s=48}, @{n='apple-touch-icon.png';s=180})) {
  $bmp = New-Object System.Drawing.Bitmap($spec.s, $spec.s)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.DrawImage($src, 0, 0, $spec.s, $spec.s); $g.Dispose()
  $bmp.Save("C:\dev\tradeready\tradeready-legal\$($spec.n)"); $bmp.Dispose()
}
# og-image: 1200x630, splash navy, icon centered at 400px
$og = New-Object System.Drawing.Bitmap(1200, 630)
$g = [System.Drawing.Graphics]::FromImage($og)
$g.Clear([System.Drawing.ColorTranslator]::FromHtml('#0c335e'))
$g.InterpolationMode = 'HighQualityBicubic'
$g.DrawImage($src, 400, 115, 400, 400); $g.Dispose()
$og.Save('C:\dev\tradeready\tradeready-legal\og-image.png'); $og.Dispose(); $src.Dispose()
```

- [ ] **Step 3: Write images/README.md**

```markdown
# Screenshot drop-in contract

The homepage upgrades automatically (next deploy) when these files exist.
Portrait iPhone captures, 6.7" App Store size (1290×2796) or same ratio.
Light mode preferred (frames sit on navy/vellum grounds).

| File | Content |
|---|---|
| hero-today.png | Today screen |
| shot-invoice.png | Invoice with payment link |
| shot-pricing.png | Pricing calculator |
| shot-chat.png | AI coach chat |
```

- [ ] **Step 4: Verify**

`Get-ChildItem` shows 7 font files + OFL.txt, three PNGs at repo root with expected dimensions (`[System.Drawing.Image]::FromFile(...).Size`). Open `favicon.png` and `og-image.png` to eyeball them.

- [ ] **Step 5: Commit**

```bash
git add fonts images favicon.png apple-touch-icon.png og-image.png
git commit -m "feat: add Blueprint fonts, favicon, touch icon, og-image, screenshot contract"
```

---

### Task 3: Marketing homepage (index.html rewrite)

**Files:**
- Modify: `C:\dev\tradeready\tradeready-legal\index.html` (full rewrite)

**Interfaces:**
- Consumes: `/support.html` (Task 1), fonts/icons/og-image and `images/*` paths (Task 2).

- [ ] **Step 1: Write the page**

Self-contained HTML+CSS. Head requirements:

```html
<title>TradeReady — job management & invoicing for tradespeople</title>
<meta name="description" content="Price jobs with confidence, send estimates and invoices in seconds, and get paid faster with payment links. The job management app for independent tradespeople. Works offline.">
<link rel="canonical" href="https://gettradereadyapp.com/">
<meta name="apple-itunes-app" content="app-id=6790681059">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:title" content="TradeReady — run your trade business from your pocket">
<meta property="og:description" content="Pricing, estimates, invoices, and getting paid — a few taps between jobs. Built for independent tradespeople. 2-week free trial.">
<meta property="og:image" content="https://gettradereadyapp.com/og-image.png">
<meta property="og:url" content="https://gettradereadyapp.com/">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
```

`@font-face` for the six fonts (`/fonts/...`, `font-display: swap`). CSS custom properties exactly per the Global-Constraints token block (light + dark).

Page copy (verbatim — every claim traced to the approved listing):

**Header:** wordmark "TradeReady" (Chakra Petch, accent color) · links Features / Pricing / Support · button "Get the app".

**Hero** (navy band `--hero-navy`, blueprint-grid texture via repeating-linear-gradient at low opacity):
- H1: "Run your trade business from your pocket."
- Sub: "TradeReady is the job management app for independent tradespeople. Price jobs with confidence, send estimates and invoices in seconds, and get paid faster — no office software, no experience needed."
- CTA: Apple App Store badge (inline official-style SVG badge, link `https://apps.apple.com/app/id6790681059`) + mono caption "Free to download · 2-week free trial".
- Right/below: phone-framed `images/hero-today.png`.

**Value strip** (3 columns): "Price it — a calculator built for the trades. Know your break-even before you quote." / "Send it — professional estimates and invoices by text or email." / "Get paid — card-payment links that mark the invoice paid the moment the money lands."

**Feature sections** (eyebrow label in Plex Mono, H2 in Chakra Petch, bullets in Public Sans):
1. *PRICE WITH CONFIDENCE* — "Never guess a price again." Bullets: pricing calculator (labor, materials with markup, overhead, profit margin); break-even warnings before you quote too low; AI rate suggestions for your trade and area; pricebook of standard services you reuse in seconds.
2. *WIN THE WORK* — "From lead to paid, one pipeline." Bullets: track every job lead-to-paid; polished PDF estimates by text or email; customers approve estimates online with one tap — you're notified the moment they say yes; a booking link that turns website visitors into quote requests; recurring jobs for your regulars.
3. *GET PAID FASTER* — "Stop chasing checks." Bullets: invoices in seconds from any job; secure card-payment links (powered by Stripe) that mark invoices paid automatically; deposits & partial payments; overdue reminders plus AI-written follow-ups that stay friendly and get you paid; change orders your customer approves online.
4. *KNOW YOUR NUMBERS* — "An AI coach that knows your business." Bullets: ask about your revenue, overdue invoices, or what to charge — zero setup; profit & loss, revenue trends, conversion funnel, cash-flow forecast; expenses, mileage log, receipt scanning with your camera; tax set-aside so tax time never stings.
5. *WORKS WHERE YOU WORK* — "Basements. Crawl spaces. Dead zones." Bullets: fully offline, syncs when you're back in signal; secure cloud backup that follows you to a new phone; job photos, customer history, notes in one place; dark mode for early starts and late finishes.

Screenshot slots: `shot-pricing.png` beside section 1, `shot-invoice.png` beside section 3, `shot-chat.png` beside section 4. Each is a CSS phone frame whose `<img>` carries `loading="lazy"` and `onerror="this.closest('.shot').classList.add('missing')"`; `.shot.missing img {display:none}` reveals a Blueprint-grid placeholder with a Plex Mono caption ("Screenshot coming soon").

**Pricing section** (id="pricing", surface card): H2 "Simple pricing. Real trial." Copy: "TradeReady is free to download, and every new account starts with a 2-week free trial — run real jobs through it before paying a cent." Price line in Plex Mono: "$19.99/month · or · $199.99/year". Footnote: "Billed through your Apple ID. Cancel anytime in App Store settings." CTA badge repeat.

**Footer:** Support (`/support.html`) · Privacy Policy (`/privacy.html`) · Terms (`/terms.html`) · `support@gettradereadyapp.com` · "© 2026 Chad Rector. TradeReady is not affiliated with Apple Inc."

Responsive: single column ≤720px; no horizontal scroll at 375px; header collapses to wordmark + Get-the-app.

- [ ] **Step 2: Verify in browser pane**

Serve `legal-site`, load `http://localhost:3456/`. Check: both themes (resize_window colorScheme light/dark), 375px + desktop widths, all header/footer anchors and links resolve, placeholders render for the four missing screenshots, no console errors, no horizontal scroll.

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "feat: replace support root page with Blueprint marketing homepage"
```

---

### Task 4: 404 page and www redirect config

**Files:**
- Create: `C:\dev\tradeready\tradeready-legal\404.html`
- Create: `C:\dev\tradeready\tradeready-legal\_redirects`

**Interfaces:**
- Produces: Cloudflare Pages picks up `404.html` automatically; `_redirects` is Pages-only (GitHub Pages ignores it — harmless in the interim).

- [ ] **Step 1: Write 404.html**

Minimal Blueprint page (same token block as index, Chakra Petch H1): "Page not found." + body "That link doesn't go anywhere. The homepage has everything — or email support@gettradereadyapp.com." + links Home / Support. Include `<meta name="robots" content="noindex">`.

- [ ] **Step 2: Write _redirects**

```
https://www.gettradereadyapp.com/* https://gettradereadyapp.com/:splat 301
```

- [ ] **Step 3: Verify + commit**

Load `http://localhost:3456/404.html` (serve returns it directly). Then:

```bash
git add 404.html _redirects
git commit -m "feat: add 404 page and www-to-apex redirect for Cloudflare Pages"
```

---

### Task 5: Phase-1 gate — full local pass, push, STOP

- [ ] **Step 1: Full local verification**

With `legal-site` running, request every path and expect 200 + correct content-type:

```powershell
$paths = '/', '/support.html', '/privacy.html', '/terms.html', '/reset.html',
         '/confirmed.html', '/estimate.html', '/change.html', '/book.html',
         '/portal.html', '/get.html', '/404.html', '/favicon.png',
         '/apple-touch-icon.png', '/og-image.png', '/fonts/ChakraPetch-Bold.ttf'
foreach ($p in $paths) {
  $r = Invoke-WebRequest "http://localhost:3456$p" -UseBasicParsing
  "{0} {1}" -f $r.StatusCode, $p
}
```

Expected: sixteen `200` lines.

- [ ] **Step 2: Push (deploys to GitHub Pages — acceptable per spec: support stays linked from the new root)**

```bash
git push origin master
```

Confirm live: `https://gettradereadyapp.com/` shows the new homepage, `/support.html` serves support.

- [ ] **Step 3: STOP — phase report to owner**

Report Confidence / Missing Context / Recommended Next Step. Next step = Phase 2 (owner creates the Cloudflare Pages project). Do not proceed without go-ahead.

---

### Task 6 (Phase 2): Cloudflare Pages project + pages.dev verification

**[OWNER] steps (dashboard, one-time):**
1. Cloudflare dashboard → Workers & Pages → Create → Pages → Connect to Git.
2. Authorize GitHub for `CZilla57/tradeready-legal`; project name `tradeready-site`; production branch = default; framework preset **None**; build command empty; output dir `/`.
3. First deploy runs automatically; note the `https://tradeready-site.pages.dev` URL.

- [ ] **Step 1 [ENG]: Scripted parity check on pages.dev**

Same loop as Task 5 Step 1 with base `https://tradeready-site.pages.dev` — expect sixteen 200s. Additionally: fetch `/` and confirm `<title>TradeReady — job management` present; fetch a nonexistent path `/nope-xyz` and expect the branded 404 (status 404, body contains "Page not found").

- [ ] **Step 2: STOP — phase report; next step = domain flip.**

---

### Task 7 (Phase 3): Custom-domain flip + live verification

**[OWNER] steps:**
1. Pages project → Custom domains → add `gettradereadyapp.com` → confirm (Cloudflare rewrites the zone's apex record; the old A records to 185.199.108–111.153 are replaced).
2. Add `www.gettradereadyapp.com` the same way (replaces the CNAME to czilla57.github.io).
3. Do NOT touch the GitHub repo's Pages settings — leave enabled for the github.io 301s and rollback.

- [ ] **Step 1 [ENG]: Live verification**

```powershell
foreach ($p in '/', '/support.html', '/privacy.html', '/terms.html', '/reset.html', '/estimate.html') {
  $r = Invoke-WebRequest "https://gettradereadyapp.com$p" -UseBasicParsing
  "{0} {1}" -f $r.StatusCode, $p
}
(Invoke-WebRequest 'https://www.gettradereadyapp.com/' -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode  # expect 301 to apex
```

Plus in the browser pane: live homepage renders both themes; smart-banner meta present; open `https://gettradereadyapp.com/book.html?b=test` and expect the page's own "link is invalid" state (proves the Worker API call path still works); `https://czilla57.github.io/tradeready-legal/privacy.html` still 301s to the apex.

Rollback if anything is wrong: remove the custom domains from the Pages project (Cloudflare restores nothing automatically — re-create the apex A records to 185.199.108.153/109/110/111 and the www CNAME to `czilla57.github.io` in the zone; GitHub Pages is still serving).

- [ ] **Step 2: STOP — phase report; remaining follow-ups are owner actions.**

---

### Task 8 (Phase 4): Follow-ups (tracking only)

- [ ] **[OWNER]** Drop the four screenshots into `images/` per `images/README.md`, push → auto-deploy.
- [ ] **[OWNER]** At the next App Store submission: change ASC Support URL to `https://gettradereadyapp.com/support.html` (listing doc note; do not resubmit just for this).
- [ ] **[ENG]** Update memory (`MEMORY.md` + project file) and, if hosting facts moved, flag `tradeready-run-and-operate` skill drift (it documents GitHub Pages as the legal-site host).
- [ ] **[OWNER, much later]** Optionally disable GitHub Pages after the Workers-migration monitoring window — NOT now.

---

## Self-review (done at write time)

- **Spec coverage:** hosting/cutover → Tasks 6–7; homepage structure/copy → Task 3; support move → Task 1; screenshot contract → Tasks 2/8; visual design tokens → header block + Task 3; SEO/meta/404 → Tasks 3–4; verification → Tasks 5–7; rollback → Task 7. Out-of-scope items excluded.
- **Placeholders:** none — copy deck, commands, and expected outputs are inline.
- **Consistency:** filenames `hero-today/shot-invoice/shot-pricing/shot-chat` match the spec table; token values match `utils/theme.ts`; paths match the repo listing verified this session.
