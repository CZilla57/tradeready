# Marketing content calendar — gettradereadyapp.com /guides/

**Created:** 2026-08-18. Companion to `docs/marketing-website-roadmap.md`.
Lives in the **tradeready repo** (NOT tradeready-legal) on purpose — CF Pages serves
every file in tradeready-legal publicly, and an internal content plan should not be
crawlable.

## Where content lands
- Articles are static `.html` pages in **tradeready-legal** under `/guides/`, built
  from the shared Blueprint shell (copy an existing guide as the template).
- Repo: tradeready-legal, branch **main**, auto-deploys via CF Pages `tradeready-site`.

## Standing rules (every article, every phase)
1. **Claims-clean** — reference only shipped, smoke-passed features. Never imply
   crew/team accounts, GPS/fleet tracking, payroll, inventory, or route optimization
   (the app is solo-operator; those topics pull the wrong audience and the CTA misfits).
2. **No em dashes** in guides copy (owner pref) — hyphens; en dashes OK for ranges.
3. **AI kept out** of the copy (part of the 2026-08-18 de-emphasis direction).
4. **Per-article publish checklist:**
   - Unique `<title>` + meta description; extensionless canonical (respects the 308
     `.html`→extensionless redirect).
   - Article + BreadcrumbList + FAQPage JSON-LD.
   - One soft App Store CTA; the teaching is the sell.
   - Link UP to the pillar + SIDEWAYS to 1-2 cluster siblings; update siblings/pillar
     to link DOWN to the new page where natural.
   - Add the URL to `sitemap.xml` and add a card to `guides/index.html`.
   - After deploy, request indexing in Google Search Console.
5. **Measure, then double down.** Review GSC ~8-12 weeks after each phase. Whichever
   trade spoke earns impressions, clone the pattern into more trades.

## Cadence
Phases are **batches ordered by ROI**, not fixed dates — publish at whatever pace is
sustainable (target ~1 article/1-2 weeks). Finish a phase's internal-linking before
starting the next so each cluster ships coherent. The only date-sensitive phase is the
tax cluster (Phase 5) — publish it **Nov-Dec** so it ranks before Jan-Apr tax season.

---

## Phase 0 — LIVE (baseline, shipped 2026-08-18)
The pricing pillar + first spokes. Everything below links back into these.

| Article | Slug | Status |
|---|---|---|
| How to price a job (pillar) | `/guides/how-to-price-a-job` | LIVE |
| How much to charge per hour | `/guides/how-much-to-charge-per-hour` | LIVE |
| Markup vs. margin | `/guides/markup-vs-margin` | LIVE |
| What to put in a job estimate (+ template) | `/guides/job-estimate-template` | LIVE |
| Guides index | `/guides/` | LIVE |

---

## Phase 1 — Trade-specific pricing spokes  ★ HIGHEST ROI, DO FIRST
Clone the (future) handyman pattern per trade. Lowest competition, exact product fit —
"how to price a [trade] job" searchers ARE the user. Each links up to the pillar and
sideways to markup-vs-margin + hourly-rate.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| How to price a handyman job | how to price handyman jobs | High | pricing calc, pricebook |
| How to price a painting job | how to price a painting job | High | pricing calc, pricebook |
| How to price drywall / plastering | how to price drywall work | High | pricing calc |
| How to price a flooring / tile job | how to price flooring jobs | High | pricing calc |
| How to price electrical work | how to price electrical jobs | High | pricing calc, min. fee |
| How to price a plumbing job | how to price plumbing jobs | High | pricing calc |
| How to price landscaping / lawn care | how to price lawn care jobs | High | recurring jobs, pricing calc |

*Expansion bank (add as spokes rank): pressure washing, gutter cleaning, fencing,
decking, roofing, HVAC, carpentry, masonry, welding.*

---

## Phase 2 — Pricing-cluster deepeners
Money concepts that strengthen the pillar and catch anxious-searcher queries.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| What's a good profit margin for a contractor? | good profit margin contractor | Mid/High | job profitability card |
| How to calculate your overhead | contractor overhead costs | Mid | pricing calc (overhead) |
| Should you charge a minimum job / call-out fee? | minimum call out fee | High | pricing calc |
| Flat-rate vs. hourly pricing | flat rate vs hourly | High | pricing calc |
| How to price emergency / after-hours work | emergency call out rate | Mid | pricing calc |

---

## Phase 3 — Getting paid cluster
Ties to invoicing, payment links, deposits, overdue reminders. New mini-cluster with
its own internal links; cross-link to the estimate template.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| How to write an invoice (+ free template) | invoice template / how to write an invoice | High | invoicing, PDF |
| How to get paid faster as a tradesperson | get paid faster contractor | Mid | payment links, deposits |
| Should you ask for a deposit? How much? | how much deposit contractor | High | deposits |
| How to handle a customer who won't pay | customer not paying invoice | High | overdue reminders |
| Estimate vs. quote vs. invoice (standalone) | estimate vs quote | High | estimates, invoicing |

---

## Phase 4 — Going solo (top-of-funnel)
Catches people BEFORE they need any app — the exact audience the app teaches. Highest
reach, longest payback. Trade-specific variants scale here too.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| How to start a [trade] business / go out on your own | how to start a handyman business | High | soft (whole app) |
| Do you need a license / insurance to start? | do handymen need a license | High | soft |
| How much can you make self-employed in [trade]? | how much do electricians make self employed | Mid | soft |
| First 5 things to set up when you go solo | starting a trade business checklist | Mid | soft (whole app) |
| How to name and brand a trades business | trade business name ideas | Mid | soft |

---

## Phase 5 — Tax & bookkeeping  ⏰ PUBLISH NOV-DEC (seasonal)
Strong Jan-Apr search spikes; publish 1-2 months ahead to rank in time. Ties to
expenses, mileage log, receipt scanning, tax set-aside, accountant export.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| Tax deductions every tradesperson should track | tradesman tax deductions | High | expenses, receipt scan |
| How much to set aside for taxes (self-employed) | how much to save for taxes self employed | High | tax set-aside |
| Mileage deduction: tracking trips for taxes | self employed mileage deduction | High | mileage log |
| Bookkeeping without an accountant / what yours needs | small business bookkeeping trades | Mid | accountant export |

---

## Phase 6 — Growth & getting customers
Ties to booking link and review requests. Broadens beyond pricing.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| How to get more customers as a new tradesperson | how to get more work as a contractor | Mid | booking link |
| How to get Google reviews (and why they win jobs) | how to get more google reviews | High | review requests |
| Should you use a booking link? | online booking for contractors | Mid | booking link |
| How to win jobs on value, not price | how to compete without lowering price | Mid | estimates |

---

## Phase 7 — Bottom-funnel / comparison  (only after domain authority builds, ~6mo+)
Highest purchase intent, hardest to rank, lowest volume. Honest positioning: the
affordable, solo-first option — do NOT claim crew/dispatch features the app lacks.

| Article | Primary keyword | Intent | App tie-in |
|---|---|---|---|
| Best invoicing app for tradespeople | best invoicing app for tradesmen | High | direct |
| Jobber / Housecall Pro alternatives for solo operators | jobber alternatives | High | direct (positioning) |

---

## Rough sequencing summary
1. **Phase 1** (trade spokes) — start now, biggest compounding win.
2. **Phase 2** (pricing deepeners) — while Phase 1 marinates in the index.
3. **Phase 3** (getting paid) — new cluster once pricing cluster is deep.
4. **Phase 4** (going solo) — top-of-funnel reach.
5. **Phase 5** (tax) — slot into Nov-Dec regardless of where the queue is.
6. **Phase 6** (growth), then **Phase 7** (comparison) once authority exists.

Re-prioritize off real GSC data after Phase 1-2 land: the trades that show impressions
tell you which spokes to clone next.
