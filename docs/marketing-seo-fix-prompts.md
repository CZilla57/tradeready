# Website SEO fix prompts — gettradereadyapp.com

**Created:** 2026-09-24, from the SEO audit run that day (live crawl of all 26 sitemap
URLs + headers + JSON-LD). Companion to `docs/marketing-website-roadmap.md` (standing
constraints, shipped phases) and `docs/marketing-content-calendar.md` (article plan).

**What this is:** copy-paste prompts for a coding agent (Claude Code, Codex) to fix the
website-side SEO findings. App Store (ASO) findings are out of scope here.

**Where the work lands:** the **`tradeready-legal`** repo (GitHub `CZilla57/tradeready-legal`,
branch `main`, auto-deploys via Cloudflare Pages project `tradeready-site`). It is **not
checked out locally** — clone it first (`gh repo clone CZilla57/tradeready-legal`).
Exception: none of these prompts touch this repo's `web/` portal.

## How to use

1. Open a fresh agent session in the `tradeready-legal` checkout.
2. Paste the **Shared context** block, then **one** task prompt below it.
3. Review the diff yourself. Every prompt ends at "show me the diff" — **pushing `main`
   is a production deploy**, so commit/push is your call.
4. After deploying a batch, run **V1 (verification)** and request re-indexing of changed
   URLs in Google Search Console.

## Run order

| # | Prompt | Impact | Effort | Gate |
|---|---|---|---|---|
| 1 | P1 Homepage title, meta, H1 | High | 30 min | Owner picks H1 copy |
| 2 | P2 Homepage → guides links | High | 1 hr | — |
| 3 | P3 Organization + WebSite schema | Medium | 30 min | — |
| 4 | P4 Meta descriptions (12 pages) | Medium | 45 min | — |
| 5 | P5 Two guide titles | Low | 15 min | — |
| 6 | P6 Open Graph on utility pages + badge alt | Low | 30 min | — |
| 7 | P7 Sitemap lastmod | Low | 15 min | — |
| 8 | P8 WOFF2 fonts, preload, font caching | Low–Med | 1–2 hr | — |
| 9 | P9 Homepage FAQ | Medium | 1 hr | Owner approves copy |
| 10 | P10 Named author (E-E-A-T) | Medium | 1 hr | Owner supplies bio facts |
| 11 | P11 Hourly-rate calculator | High | Half day | — |
| 12 | P12 New-guide template (reusable) | High | Per article | Content calendar order |
| — | P13 Per-hour pages intent split | Medium | Half day | ~8–12 wks of GSC data |
| — | P14 Social proof + aggregateRating | Medium | 1 hr | Real App Store ratings exist |
| — | P15 Guide CTAs → trade custom product pages | Medium | 1 hr | CPPs created in App Store Connect |
| — | P16 Joist-alternative comparison page | Medium | Half day | ~6 mo domain age (calendar Phase 7) |
| — | V1 Post-deploy verification | — | 15 min | After any batch |

---

## Shared context (paste above every prompt)

```text
You are working in the tradeready-legal repo: the static marketing site for TradeReady
(https://gettradereadyapp.com), an iPhone app for independent tradespeople (pricing,
estimates, invoices, payment links, works offline). Plain static HTML pages, each with
its own inline <style>; no build step. Branch main auto-deploys via Cloudflare Pages.

Standing constraints. Breaking one is a release blocker:
1. The apex / must NEVER 404 (it is the App Store Connect Support URL).
2. Do NOT rename, move, or "fix" any .html file or path. Cloudflare Pages 308-redirects
   .html -> extensionless on purpose; many paths are hardcoded by the app and backend.
   Canonicals are extensionless. Leave the 308s and existing hrefs alone.
3. Claims discipline: only claim shipped, user-available features. Never claim route
   optimization, team/crew accounts, a web dashboard, a customer portal, widgets, GPS/
   fleet tracking, payroll, or inventory. Never fabricate ratings, reviews, quotes,
   user counts, or metrics.
4. Screenshot contract: every images/*.jpg has a .webp sibling served via <picture>.
   If you touch a screenshot, regenerate its webp (see images/README.md).
5. An enforcing CSP lives in _headers. It allows inline scripts/styles and self-hosted
   fonts/scripts. Any NEW external host must be added to the CSP allowlist or it will
   be silently blocked. Prefer self-hosted, zero-dependency code.
6. Guides copy (anything under /guides/) uses NO em dashes. Hyphens are fine; en dashes
   are fine for numeric ranges.
7. Keep the existing "Blueprint" visual identity: reuse existing classes/components from
   neighbouring pages instead of inventing new styles.

Working rules:
- Read the files you are changing before editing. Match the surrounding markup style.
- Do not commit or push. When done, show me the full diff and a short summary of what
  changed and how you verified it.
- Verify locally where you can (e.g. `python3 -m http.server` and curl/grep, or parse
  every JSON-LD block with a JSON parser). If something in this prompt conflicts with
  what you find in the repo, stop and tell me instead of guessing.
```

---

## Batch 1 — Quick wins

### P1 — Homepage title, meta description, and H1

```text
Task: improve the homepage (index.html) search snippet and H1 for keyword relevance
and brand differentiation.

Context: the current H1 "Run your trade business from your pocket." has no keyword and
is nearly identical to a competitor with a confusingly similar name (GetTradeReady,
gettradeready.com, H1 "Run your trade business without the paperwork"). The title lacks
"app"/"estimate". The meta description is 175 chars and truncates in Google.

Changes:
1. <title>: `TradeReady: Estimate & Invoice App for Tradespeople`
   (escape & as &amp; in HTML). Keep it at 60 characters or fewer.
2. <meta name="description">: exactly this (154 chars):
   `Price jobs, send estimates and invoices, and get paid by card from your phone. The job app for independent tradespeople. Works offline. 2-week free trial.`
   Also update the SoftwareApplication JSON-LD "description" to match.
3. H1: replace with ONE of these (I will pick; if I haven't said, use option A):
   A. `The pricing, estimate & invoice app for independent tradespeople.`
   B. `Price it, send it, get paid: the job app for independent tradespeople.`
   Keep "Run your trade business from your pocket." on the page as the hero subhead
   (a <p>, not a heading) so the brand line survives.
4. Leave og:title / og:description as they are (social copy can differ from search copy).

Constraints: exactly one <h1> on the page; do not change hero layout beyond the text
swap; check the hero at 375px and 1280px, light and dark, for wrapping or overflow
(the new H1 is longer).

Verify: title length <= 60, description length 150-160, one <h1>, JSON-LD still parses.
```

### P2 — Link the homepage to the guides

```text
Task: add a "Learn the business side" section to the homepage (index.html) that links
directly to individual guides. Right now the homepage, the site's strongest page, links
only to /guides/ and passes no authority to any specific guide.

Changes:
1. Add a compact section between the last feature section and the pricing section
   (or wherever it reads most naturally; tell me where you put it and why).
   Heading (H2): `Learn the business side of your trade`
   One sentence of intro, then 5 links as cards or a list, using the guide's H1 as
   descriptive anchor text:
   - /guides/how-to-price-a-job  (the pillar; make it visually first)
   - /guides/how-much-to-charge-per-hour
   - /guides/markup-vs-margin
   - /guides/job-estimate-template
   - /guides/how-to-price-a-handyman-job
   Then a final "All guides" link to /guides/.
2. Reuse the card/list styling already used on /guides/index.html so it looks native.
3. Use extensionless hrefs exactly as written above (these are the canonical URLs).

Constraints: no JS, no images; heading order stays h1 -> h2 (no skipped levels); tap
targets >= 44px on mobile; works in dark mode.

Verify: all 6 links return 200 with no redirect (curl -sI against the live site paths),
one <h1> still, layout checked at 375px and 1280px.
```

### P3 — Organization + WebSite structured data

```text
Task: add Organization and WebSite JSON-LD to the homepage (index.html) and link the
existing SoftwareApplication to them, so search engines can tell this TradeReady apart
from other businesses using the same name (gettradeready.com, tradeready.app,
trade-ready.co.uk, tradeready.ca).

Changes:
1. Add a new <script type="application/ld+json"> block with an @graph containing:
   {
     "@type": "Organization",
     "@id": "https://gettradereadyapp.com/#organization",
     "name": "TradeReady",
     "url": "https://gettradereadyapp.com/",
     "logo": { "@type": "ImageObject", "url": "https://gettradereadyapp.com/apple-touch-icon.png" },
     "email": "support@gettradereadyapp.com",
     "sameAs": ["https://apps.apple.com/app/id6790681059"]
   },
   {
     "@type": "WebSite",
     "@id": "https://gettradereadyapp.com/#website",
     "name": "TradeReady",
     "url": "https://gettradereadyapp.com/",
     "publisher": { "@id": "https://gettradereadyapp.com/#organization" }
   }
   Do not add a SearchAction (the site has no search).
   Only add other sameAs URLs if the repo already links to an official social profile;
   do not invent any.
2. In the existing SoftwareApplication block add
   "publisher": { "@id": "https://gettradereadyapp.com/#organization" }.
   Do NOT add aggregateRating (gated on real ratings, see roadmap).
3. In every guide's Article JSON-LD, add "@id": "https://gettradereadyapp.com/#organization"
   to the existing publisher Organization object (keep its other fields).

Verify: parse every JSON-LD block on every changed page with a JSON parser (report any
failure); confirm no duplicate @id with conflicting data.
```

### P4 — Trim meta descriptions to 160 characters

```text
Task: replace over-long or missing meta descriptions. Google truncates around 155-160
characters. For each page below, set <meta name="description"> to the new text exactly.
If the page has an og:description or twitter:description that duplicates the OLD meta
description word-for-word, update it to the new text too; otherwise leave it.
Do not touch the Article JSON-LD "description" fields.

| Page file (under guides/ unless noted) | New description (chars) |
|---|---|
| how-to-calculate-overhead.html | How to total your overhead, turn it into a percentage, and build it into every price so each job pays its share of the cost of being in business. (145) |
| good-profit-margin-contractor.html | What's a good profit margin for a contractor? Pricing margin vs. net profit, an illustrative range to sanity-check against, and how to set your own target. (155) |
| minimum-call-out-fee.html | Small jobs lose money when the drive and paperwork cost more than the work. How to set a minimum job fee or call-out fee, and how to explain it to customers. (157) |
| flat-rate-vs-hourly.html | Hourly pricing punishes you for being fast; flat-rate rewards it if you know your numbers. When each one fits and how to price a flat rate without guessing. (156) |
| emergency-after-hours-rates.html | How to price emergency and after-hours work: how the multiplier works, what a fair after-hours rate looks like, and how to charge it without gouging. (149) |
| job-estimate-template.html | A free, copy-ready job estimate template plus a nine-part checklist: scope, pricing, deposits, permits, taxes, and expiry dates. Check your local rules. (152) |
| how-much-do-plumbers-charge-per-hour.html | What plumbers charge per hour, plus service-call fees, minimums, flat rates, and permits. For customers comparing quotes and plumbers setting their rates. (154) |
| how-much-do-electricians-charge-per-hour.html | What electricians charge per hour, plus service-call fees, permits, inspections, and flat rates. For customers comparing quotes and electricians setting rates. (159) |
| how-much-do-hvac-techs-charge-per-hour.html | What HVAC techs charge per hour, why diagnostic and after-hours fees exist, and how an HVAC owner builds a rate that covers certification and unbillable time. (158) |
| privacy.html (repo root) | How TradeReady collects, uses, stores, and protects your business and customer data, which third parties are involved, and the privacy rights you have. (151) |
| terms.html (repo root) | The terms of service for TradeReady, the job management and invoicing app for tradespeople: subscriptions, payments, estimate approvals, and your data. (151) |

(The homepage description is handled in P1.)

Constraints: guides copy has no em dashes (the texts above have none; keep it that way).
If any claim in a new description doesn't match what the page actually says, tell me
rather than shipping it (e.g. confirm the overhead guide really covers all three steps).

Verify: print every sitemap page's description length after the change; all must be
<= 160 and non-empty.
```

### P5 — Two guide titles

```text
Task: fix two <title> tags. Do not change H1s, slugs, or canonicals.

1. guides/how-much-do-electricians-charge-per-hour.html
   Current (64 chars, truncates): How Much Do Electricians Charge Per Hour? Rates, Fees & Examples
   New: `How Much Do Electricians Charge Per Hour? Rates & Fees` (54)
2. guides/how-much-do-hvac-techs-charge-per-hour.html
   Current (39 chars, inconsistent with sibling pages): How Much Do HVAC Techs Charge Per Hour?
   New: `How Much Do HVAC Techs Charge Per Hour? Rates & Fees` (52)

Escape & as &amp;. If either page has an og:title identical to the old <title>, update it
to match. Also update the matching card title on guides/index.html only if it repeats the
old <title> text verbatim.

Verify: both titles <= 60 chars, rendered correctly (no literal "&amp;amp;").
```

### P6 — Open Graph on utility pages + App Store badge alt text

```text
Task: two small metadata fixes.

1. support.html, privacy.html, terms.html, whats-new.html have no Open Graph tags, so
   shared links render without a preview. Copy the OG/Twitter block pattern used by the
   guide pages and fill it per page:
   og:title (= the page <title>), og:description (= the page meta description),
   og:url (= the page's canonical URL), og:type "website",
   og:image https://gettradereadyapp.com/og-image.png, twitter:card summary_large_image.
2. Add `<meta property="og:image:alt" content="TradeReady app for tradespeople">` next to
   every og:image on the site (homepage, guides, and the four pages above).
3. On every page under guides/ (including guides/index.html) the App Store badge is
   `<img src="/images/app-store-badge.svg" alt="" ...>` inside a link that has an
   aria-label. Set alt="Download TradeReady on the App Store" on the img. Keep the
   aria-label on the link.

Verify: grep that no img under guides/ has alt="" any more; each of the four utility
pages has og:title/og:description/og:url/og:image.
```

### P7 — Sitemap lastmod

```text
Task: sitemap.xml gives <lastmod> for guides but not for /, /support, /privacy, /terms,
/whats-new. Add <lastmod> to those five using each source file's last real content
change date: `git log -1 --format=%cs -- <file>`. Format YYYY-MM-DD.

Also double-check every existing guide <lastmod> against the same git command and tell
me about (but don't auto-fix) any that disagree by more than a day. Don't add or remove
URLs. Verify the XML is well-formed (`xmllint --noout sitemap.xml`).
```

### P8 — WOFF2 fonts, preload, and font caching

```text
Task: the site loads 6 self-hosted TTF fonts (~80 KB each) from /fonts/ with no WOFF2
and no preload. Convert to WOFF2 and preload the two above-the-fold faces.

Changes:
1. Generate a .woff2 next to each .ttf in fonts/ (e.g. `pip install fonttools brotli`
   then `python3 -c "from fontTools.ttLib import TTFont; f=TTFont('X.ttf'); f.flavor='woff2'; f.save('X.woff2')"`).
   Keep the .ttf files (don't delete anything).
   Report before/after sizes.
2. Every page has its own inline @font-face rules. On EVERY html page that declares
   them, change each src to:
   src: url('/fonts/NAME.woff2') format('woff2'), url('/fonts/NAME.ttf') format('truetype');
   Keep font-display: swap. Find all pages with `grep -l "@font-face" -r --include=*.html .`
   (includes transactional pages like estimate/change/book; update them too, carefully,
   without touching anything else in those files).
3. On the homepage and every guide page, add in <head>:
   <link rel="preload" href="/fonts/ChakraPetch-Bold.woff2" as="font" type="font/woff2" crossorigin>
   <link rel="preload" href="/fonts/PublicSans-Regular.woff2" as="font" type="font/woff2" crossorigin>
4. In _headers, add a rule so fonts cache for a year (filenames never change):
   /fonts/*
     Cache-Control: public, max-age=31536000, immutable
   Do NOT add long caching for /images/* (screenshots are replaced under the same
   filenames, see the screenshot contract) or for HTML. Keep all existing _headers rules
   exactly as they are.

Constraints: CSP font-src is 'self', so self-hosted woff2 is fine; add no external
hosts. Transactional pages must behave identically (only the font src lines change).

Verify: every @font-face src lists woff2 first; every referenced .woff2 file exists;
_headers still contains the security headers unchanged (diff it); load index.html
locally and confirm fonts render (Network tab or curl the woff2 paths).
```

---

## Batch 2 — Needs owner input

### P9 — Homepage FAQ section

```text
Task: the homepage is thin (~530 words) and has no FAQ. Add a short FAQ section with
FAQPage JSON-LD. Note: Google only shows FAQ rich results for government/health sites
since 2023, so this is for on-page content, long-tail matching, and AI answer engines,
not for star snippets.

Draft 5 questions and answers and SHOW THEM TO ME BEFORE EDITING. Every answer must be
backed by something already stated on the site (homepage, support page, pricing section,
terms) or that I confirm. Suggested questions:
1. How much does TradeReady cost? (use the real prices on the page: $19.99/mo,
   $199.99/yr, 2-week free trial; cancel in App Store settings)
2. Does it work without signal? (use the homepage's existing offline/sync wording exactly;
   do not strengthen it)
3. Which trades is it for? (independent/solo tradespeople; name trades only as examples)
4. How do customers pay me? (card payment links powered by Stripe, as the site says)
5. Is it on Android? (answer honestly: iPhone and iPad; confirm with me)

Constraints: claims discipline (no web dashboard, no customer portal, no team accounts,
no widgets). Place the section after pricing, before the footer. H2 "Common questions",
each question as H3. Use <details>/<summary> only if it matches an existing pattern;
otherwise plain headings + paragraphs. Visible text and JSON-LD text must match exactly.

After I approve the copy, implement it and verify: one <h1>, heading order valid,
JSON-LD parses, visible Q&A == JSON-LD Q&A.
```

### P10 — Named author on the guides (E-E-A-T)

```text
Task: every guide's Article JSON-LD has author = the TradeReady Organization and there's
no visible human author. Guides give money advice, where Google weighs experience and
authorship heavily. Add a named author.

FIRST ask me for: the author's display name, a 2-3 sentence bio (real experience only),
optional headshot file, and optional profile URL (e.g. LinkedIn). Do not invent any
credentials, years of experience, or trade background.

Then:
1. On guides/about.html, add an author section (H2) with the name + bio, with
   id="author" so it can be linked.
2. In every guide's byline area (near "Published <date>"), add "By <Name>" linking to
   /guides/about#author. Match existing byline styling.
3. In every guide's Article JSON-LD, set
   "author": { "@type": "Person", "name": "<Name>", "url": "https://gettradereadyapp.com/guides/about#author" }
   (add "sameAs": [profile URL] only if I gave one). Keep publisher as the Organization.
4. In guides/about.html's AboutPage JSON-LD, add the same Person as "author" or
   "mainEntity" (whichever fits the existing structure).

Constraints: no em dashes in guides copy. Update dateModified ONLY on pages whose visible
content changed (the byline counts; update it to today's date) and keep sitemap
<lastmod> in sync with dateModified.

Verify: every guide has the byline and a parsing Person author; about#author anchor
resolves.
```

---

## Batch 3 — Growth (content and tools)

### P11 — Free hourly-rate calculator

```text
Task: build a free, interactive "Hourly rate calculator for tradespeople" page. This is a
link-earning asset and the web version of the app's pricing calculator.

FIRST read guides/how-much-to-charge-per-hour.html completely. The calculator MUST
implement exactly the formula and steps that guide teaches (target wage, billable
hours, overhead, profit, etc.). Report the formula back to me in plain math before
building.

Build:
- New page: guides/hourly-rate-calculator.html (extensionless canonical
  https://gettradereadyapp.com/guides/hourly-rate-calculator), using the guide page shell.
- Inputs with <label>s, sensible defaults matching the guide's worked example, numeric
  validation, and a results panel announced with aria-live="polite".
- Show the working (each step's number), not just the final rate, plus a one-line
  "why" for each step linking to the matching section of the guide.
- Vanilla JS in an inline <script> (CSP allows inline; no external libraries, no CDN,
  no tracking, no network requests). No form submission; nothing leaves the browser.
- Page works without JS: the formula is written out in text with the worked example.
- ~400-700 words of supporting copy: when to use it, the four numbers people mix up
  (link to the guide), one soft App Store CTA ("TradeReady does this on every job").
- <title> <= 60 chars, meta description <= 160, one H1, Breadcrumb JSON-LD
  (Home > Guides > Hourly rate calculator) and a WebApplication JSON-LD
  (applicationCategory "BusinessApplication", offers price 0, isAccessibleForFree true).

Wire it in: add to sitemap.xml with today's lastmod; add a card on guides/index.html;
link to it from guides/how-much-to-charge-per-hour.html (near the worksheet section) and
guides/how-to-price-a-job.html (labor section). Update those pages' dateModified and
sitemap lastmod.

Constraints: no em dashes; money formatted as USD with 2 decimals; handle zero/blank/
negative inputs gracefully; test in light and dark at 375px and 1280px.

Verify: write a tiny test (node or python) that runs the guide's worked example through
the same math and matches the guide's published answer. Show me the output.

Follow-ups (separate sessions, same pattern): a markup <-> margin converter embedded in
guides/markup-vs-margin.html, then a job price calculator tied to how-to-price-a-job.
```

### P12 — New guide template (reusable for the content calendar)

```text
Task: write and publish one new guide.
  Topic: [TOPIC]
  Slug: /guides/[SLUG]
  Primary keyword: [PRIMARY KEYWORD]
  Secondary keywords: [LIST]
  Pillar/sibling pages to link: [e.g. /guides/how-to-price-a-job, /guides/job-estimate-template]
  App tie-in (shipped features only): [e.g. invoicing, payment links, deposits]

Before writing: read 2 existing guides
(guides/how-to-price-a-handyman-job.html and guides/markup-vs-margin.html) as the
template for structure, voice, and markup, and search the web for the current top 5
results for the primary keyword. Tell me in 5 bullets what they cover and the angle we
take that they don't. Wait for my OK.

Then build guides/[SLUG].html by copying an existing guide's shell:
- <title> <= 60 chars with the primary keyword; unique meta description <= 160.
- Extensionless canonical. One H1. Primary keyword in the first 100 words.
- 1,800-3,000 words, plain English, worked example with real arithmetic, a
  "how people get this wrong" section, "The bottom line", 4-6 "Common questions".
- Any figure (rates, costs, legal points) must be sourced or clearly illustrative, per
  guides/about.html's editorial principles. Say "varies by location" where it does.
- Article (datePublished = dateModified = today, author/publisher as other guides),
  BreadcrumbList, and FAQPage JSON-LD; visible FAQ text == JSON-LD text.
- One soft App Store CTA using the existing CTA block. The teaching is the sell.
- Link UP to the pillar and SIDEWAYS to 1-2 siblings; then edit those pages to link
  DOWN to the new guide where it reads naturally (update their dateModified + lastmod).
- Add to sitemap.xml and add a card to guides/index.html in the right section.

Constraints: no em dashes; claims discipline; no AI-feature talk in guide copy.

Verify: word count, title/description lengths, JSON-LD parses, every internal link
returns 200, no em dash characters (grep for U+2014).

Suggested fills, in content-calendar order:
- Getting paid: contractor invoice template (+ free template); how much deposit should a
  contractor ask for; what to do when a customer won't pay; estimate vs quote vs invoice.
- Trade spokes: how to price a pressure washing job; gutter cleaning; fencing; decking.
- Handyman task pages (short, 800-1,200 words, under /guides/): how much to charge to
  mount a TV / hang a door / assemble furniture, each linking up to the handyman guide.
- Tax cluster (publish Nov-Dec): tradesperson tax deductions; how much to set aside;
  mileage deduction.
```

---

## Gated prompts (run only when the gate opens)

### P13 — Split intent on the "how much do X charge per hour" pages
**Gate:** 8-12 weeks of Google Search Console data for these URLs.

```text
Task: I'm giving you a Search Console query export for these three pages:
/guides/how-much-do-plumbers-charge-per-hour, /guides/how-much-do-electricians-charge-per-hour,
/guides/how-much-do-hvac-techs-charge-per-hour. [PASTE CSV: query, clicks, impressions, CTR, position]

Each page currently serves two audiences (customers comparing quotes, and trades setting
rates). Classify the queries as customer-intent vs trade-intent and report the
impression share for each page. Then propose (don't implement yet):
- If customer intent dominates: restructure so the customer answer (typical ranges,
  what drives price, service-call fees) leads, the trade section is shortened and
  links to the matching /guides/how-to-price-a-*-job page, and title/description target
  the winning queries.
- If trade intent dominates: the reverse.
Include proposed title/description/H2 outline per page. Keep slugs unchanged.
```

### P14 — Social proof + aggregateRating
**Gate:** real App Store ratings exist (roadmap W6). Check at
`https://itunes.apple.com/lookup?id=6790681059` → `userRatingCount`, `averageUserRating`.

```text
Task: add a restrained social-proof element to the homepage, backed only by real data.

1. Fetch https://itunes.apple.com/lookup?id=6790681059&country=us and report
   averageUserRating and userRatingCount. If count < [N, owner decides], stop here.
2. Add one small element near the pricing section: "Rated X.X on the App Store" with the
   rating count, linking to the App Store listing. If I give you a genuine customer
   review, add it verbatim with only the attribution I approve.
3. Add to the SoftwareApplication JSON-LD:
   "aggregateRating": { "@type": "AggregateRating", "ratingValue": "<real>", "ratingCount": "<real>" }
   Values must match the App Store exactly, and I must update them as they change; add
   an HTML comment next to it saying where the numbers came from and the date.

Constraints: claims discipline; never round a rating up; no invented quotes or metrics.
```

### P15 — Guide CTAs to trade-specific App Store custom product pages
**Gate:** custom product pages exist in App Store Connect (each has a `ppid`).

```text
Task: point each trade guide's App Store CTA at the matching custom product page instead
of the generic listing. Here is the mapping of trade -> ppid: [PASTE, e.g. painter: abc123...].

For each guide whose trade has a ppid, change the CTA link(s) (the mini-cta and the
store-badge link) from https://apps.apple.com/app/id6790681059 to
https://apps.apple.com/app/id6790681059?ppid=<ppid>. Leave non-trade guides, the
homepage, and the apple-itunes-app meta tag on the generic listing. Report the final
page -> URL table.
```

### P16 — Joist-alternative comparison page
**Gate:** ~6 months of domain age / some authority (content calendar Phase 7).

```text
Task: write /guides/joist-alternative ("A Joist alternative for solo tradespeople").

Research Joist's current features and pricing from joist.com and its App Store listing
TODAY; cite each claim with URL and access date in an HTML comment. Compare only
dimensions where both products' facts are verified. Be honest about where Joist is
stronger. Position TradeReady as the solo-first option with built-in pricing math and
offline use. Never claim crew/dispatch features, never disparage, use the Joist name only
descriptively (no logos). Follow the P12 guide checklist for structure, schema, links,
sitemap, and index card. Show me the draft before publishing.
```

---

## V1 — Post-deploy verification

```text
Task: verify the live site after a deploy. Don't edit anything; just report.

Using curl against https://gettradereadyapp.com, fetch sitemap.xml and every URL in it,
then write and run a small Python script (stdlib only; if Python's SSL store fails, fetch
with curl and parse the saved files) that checks and prints a pass/fail table for:
- HTTP 200 with no redirect for each sitemap URL; apex / returns 200.
- <title> present and <= 60 chars; unique across pages.
- meta description present, 120-160 chars, unique.
- Exactly one <h1>.
- Canonical present, extensionless, equal to the sitemap URL.
- Every application/ld+json block parses; list the @types per page.
- Every <img> has a non-empty alt, except images with role="presentation" or inside a
  link that has an aria-label (report those separately).
- Every internal href resolves to 200 or 308 (308 .html redirects are expected and fine).
- No robots noindex on sitemap pages; noindex still present on /estimate, /change,
  /book, /booking, /portal, /reset, /confirmed, /get.
- Response headers on / still include content-security-policy and
  strict-transport-security; /fonts/*.woff2 (if present) has max-age=31536000.
Summarize failures first, then the full table.
```

---

## Deliberately excluded (don't reopen)

- **Footer links to `/privacy.html`, `/support.html`, `/terms.html`.** They 308 to the
  extensionless canonicals. That behavior is owner-accepted (roadmap constraint 2), and a
  308 passes link equity. SEO impact is negligible.
- **Converting screenshots to WebP.** Already done: the homepage serves WebP via
  `<picture>` (30–78 KB) with JPG fallback.
- **Long cache on `/images/*`.** Would serve stale screenshots after a refresh, since
  replacements keep the same filename. Only `/fonts/*` gets a 1-year cache (P8).
- **Web portal meta description (`app.gettradereadyapp.com`).** Already present in
  this repo's `web/index.html`. The audit's check missed the multi-line tag.
- **`aggregateRating` now.** Gated on real ratings (P14, roadmap W4/W6).

## Owner tasks (not agent prompts)

- Confirm index coverage in Google Search Console, and add the site to Bing Webmaster Tools
  (Bing results feed ChatGPT search). A web search for the domain didn't return it on
  2026-09-24.
- Brand collision: GetTradeReady (gettradeready.com, Texas FSM with an iOS app),
  tradeready.app (trade CRM), trade-ready.co.uk, tradeready.ca. Worth a trademark
  attorney's view before investing further in the name. P1 and P3 reduce confusion on
  the SEO side either way.
- App Store (ASO) fixes are separate from this doc: an in-app rating prompt (none exists in
  RN or native), a title/subtitle/keyword-field rework, release notes and promotional
  text, and custom product pages.
