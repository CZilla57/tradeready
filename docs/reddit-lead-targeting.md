# Reddit Lead Targeting — TradeReady

Purpose: replicate the capability of tractionbooster.com — scan Reddit for tradespeople voicing
specific pains, then engage naturally in existing threads. Tractionbooster's real product is a
curated subreddit list + pain-point keyword matching + engagement drafts. This doc is that map,
tuned to the TradeReady ICP.

> Note: Reddit blocks automated crawlers (including Anthropic's), so live post URLs must be pulled
> from Reddit's own search or a monitoring tool (see `monitoring/` section). This doc gives the
> targeting inputs those tools need.

## Ideal Customer Profile (ICP)

- Solo tradesperson or small-crew owner
- $50k–$200k annual revenue
- Currently quotes on spreadsheets or paper
- Loses ~10–15% margin to underpricing
- Spends 5+ hours/week on invoicing and chasing payments
- Needs an offline-capable mobile solution

The ICP is the **business owner**, not the apprentice — so the highest-signal subs are about
*running* a trade, not doing the craft.

## Subreddit scan list

### Tier 1 — home-service business owners (highest ICP density)
- **r/sweatystartup** — bullseye. Solo/small-crew service founders obsessed with pricing, margin, getting paid.
- **r/smallbusiness** — filter to trades/service posts
- **r/Contractor** — owners, not employees
- **r/EntrepreneurRideAlong**
- **r/LawnCareBusiness**, **r/pressurewashing** — heavily pricing-focused, solo operators in the revenue band

### Tier 2 — trade subs with active owner/business threads
r/HVAC · r/electricians · r/Plumbing · r/Construction · r/Flooring · r/Roofing · r/Painting ·
r/Concrete · r/handyman · r/Fencing · r/Masonry · r/Drywall · r/Landscaping

### Tier 3 — adjacent solo-operator niches (same pains, often overlooked)
r/windowcleaning · r/guttercleaning · r/AutoDetailing (mobile detailers) · r/junkremoval ·
r/arborists · r/MobileMechanics · r/Locksmith · r/poolcleaning

### Tier 4 — cross-trade identity subs
r/Trades · r/skilledtrades · r/Tradesmen

## Pain-point → search-string library

Paste into Reddit search (`reddit.com/search`). Restrict to a sub with `sub:sweatystartup <string>`.

| ICP signal | Search strings |
|---|---|
| Underpricing / margin leak | `underpriced the job` · `quoted too low` · `left money on the table` · `not charging enough` · `how do you price` |
| Spreadsheet/paper quoting | `quoting on a spreadsheet` · `still using paper invoices` · `excel estimate template` · `write quotes by hand` |
| 5+ hrs/week invoicing & chasing | `chasing payments` · `net 30 killing me` · `customer won't pay invoice` · `paperwork nights` · `quickbooks too complicated` |
| Offline-capable mobile need | `no service on jobsite` · `app that works offline` · `invoice from my phone` · `estimate app in the field` |
| App-shopping (highest intent) | `jobber vs housecall` · `alternative to jobber` · `jobber too expensive` · `best app for solo` · `field service app recommendations` |

## Post archetypes to engage (warmest entries)

1. **"How do you guys price ___?"** — the underpricing pain, live. Highest volume.
2. **"Jobber/Housecall Pro is too expensive for a one-man show"** — price-sensitive ICP shopping for your wedge.
3. **"Customer hasn't paid, how do I chase without being rude?"** — the 5-hrs-a-week pain.
4. **"Still doing quotes in Excel — is that dumb?"** — spreadsheet-to-app transition intent.
5. **"Best app that works with no signal?"** — your offline differentiator, requested unprompted.

## Engagement rules (avoid getting flagged as spam)

- Lead with genuine help; answer the actual question first, in the commenter's own terms.
- Mention TradeReady only when directly relevant, and disclose you're the maker.
- Never copy-paste the same reply — adapt per thread. Reddit auto-removes duplicate comments.
- Prefer comments on existing threads over new promo posts. One helpful comment > ten posts.
- Respect each sub's self-promo rules; some require a flair or a ratio (e.g. 9:1 help-to-promo).

See `reddit-reply-templates.md` for per-archetype drafts and `f5bot-keywords.txt` for the monitor list.
