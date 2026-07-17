# App Store listing — TradeReady 1.0 (refreshed 2026-07-16 for build 1.0.0(5))

Everything below respects the claims rule: only device-verified or
code-verified-and-shipping features are claimed. Route optimization, OCR/
receipt scanning, tax tools, team accounts, and a web dashboard are NOT
mentioned anywhere — they don't exist. Auto-SENT overdue emails (server
cron) are live but the real send path is unexercised, so the copy claims
only "overdue reminders" (device-verified notifications).

2026-07-16 refresh: 2-week free trial confirmed on the live paywall
($19.99/mo, $199.99/yr) so the description now names the trial length; demo
account exists (support-demo@gettradereadyapp.com); nutrition-label section
expanded to the full ASC questionnaire; ASC quick answers added.

---

## App name (30 chars max)

**TradeReady: Trade Job Manager** (29)

Bare "TradeReady" is taken ("TradeReady — Trades Training", an education
app); this suffix both clears the collision and differentiates us as
management software. The name under the icon on the device stays
**TradeReady** (app config, unchanged — no rebuild needed).

## Subtitle (30 chars max)

**Invoice, estimate & AI pricing** (30)

("Job" moved into the name, so the subtitle stopped spending characters on
it and picked up "estimate" instead — Apple indexes name + subtitle +
keywords, and duplicates waste slots.)

## Category

Primary: **Business** · Secondary: **Productivity**

## Promotional text (170 chars max — editable anytime without review)

> Price jobs with confidence, send estimates and invoices in seconds, and
> get paid faster with payment links. Your AI coach knows your numbers.
> Works offline. (161)

## Keywords (100 chars max, comma-separated — avoid repeating name/subtitle words)

`roofer,plumber,electrician,handyman,contractor,hvac,landscaping,quote,tradesman,payment,carpenter` (97)

("estimate" moved to the subtitle; freed characters went to two more
trades, roofer and carpenter.)

## Description (4000 chars max — draft ~2600)

Built for tradespeople who'd rather be on the tools than at a desk.

TradeReady turns the business side of your trade — pricing, estimates,
invoices, getting paid — into a few taps between jobs. No spreadsheets, no
office software, no experience needed. If you're going out on your own for
the first time, TradeReady teaches you the business as you use it.

PRICE EVERY JOB WITH CONFIDENCE
• Pricing calculator built for the trades: labor, materials with markup,
  overhead, and profit margin
• Break-even warnings before you quote too low
• AI rate suggestions for your trade and your area
• Build a pricebook of your standard services and reuse it in seconds

WIN THE WORK
• Track every job from lead to paid with a simple pipeline
• Turn a price into a professional estimate and send it by text or email
• Generate a polished PDF your customer can keep
• Recurring jobs for your regulars — maintenance visits schedule themselves

GET PAID FASTER
• Create invoices in seconds from any job
• Send secure card-payment links (powered by Stripe) — invoices mark
  themselves paid when the money lands
• Overdue reminders so nothing slips through the cracks
• AI-written follow-up messages that stay friendly and get you paid

KNOW YOUR NUMBERS
• An AI business coach that actually knows your business — ask it about
  your revenue, overdue invoices, or what to charge, no setup required
• Profit & loss, revenue trends, conversion funnel, and cash-flow forecasts
• Expense tracking and a mileage log for tax time
• Time tracking with clock in/out on every job

WORKS WHERE YOU WORK
• Fully offline — basements, crawl spaces, dead zones. Everything syncs
  when you're back in signal
• Your data backs up securely to the cloud and follows you to a new phone
• Job photos, customer history, and notes in one place
• Dark mode for early starts and late finishes

Ask your happy customers for Google reviews automatically after a job wraps
up — the referral engine most tradespeople never get around to building.

TradeReady is a subscription with a 2-week free trial, so you can run real
jobs through it before paying a cent. Cancel anytime in your App Store
settings.

Privacy policy: https://czilla57.github.io/tradeready-legal/privacy.html
Terms of use: https://czilla57.github.io/tradeready-legal/terms.html
Questions? support@gettradereadyapp.com — a real person reads it.

## What's New (version 1.0)

> Welcome to TradeReady 1.0 — price jobs, send estimates and invoices, get
> paid with payment links, and run your whole trade business from your
> pocket. Works offline, syncs everywhere.

---

## App Review notes (paste into App Store Connect "Notes" + attach demo account)

> TradeReady requires an account (email + password with email confirmation).
> Please use the demo account below — it's pre-loaded with sample data:
>
> Email: support-demo@gettradereadyapp.com
> Password: [OWNER: paste the demo password — never store it in this repo]
>
> Subscription: the app shows a paywall after onboarding. The demo account /
> sandbox environment supports the free-trial purchase flow. Restore
> Purchases is on the paywall.
>
> Payment links are processed via Stripe Connect on the user's own Stripe
> account; the app itself never handles card data. The AI assistant uses a
> server-side proxy; no user API key is required.

## Privacy nutrition label — full ASC questionnaire (App Privacy section)

Ground truth (verified 2026-07-16): Supabase (database/auth), Anthropic &
Groq via our proxy (AI requests incl. business snapshot), RevenueCat
(subscription receipts), Stripe (payment links on the user's own Connect
account), PostHog (analytics, identified by user id), Sentry (crashes,
identified by user id), OpenStreetMap/Nominatim (typed address queries).
Photos and mileage trips never leave the device. No ads, no data brokers,
no cross-app tracking. `identifyUser()` ties PostHog + Sentry to the
Supabase user id, so usage/diagnostics are LINKED to identity — answer
honestly, it costs nothing.

**Q: "Do you or your third-party partners collect data from this app?"** → **Yes**

Then declare exactly these data types (everything below: **used for
tracking = No**; **linked to the user's identity = Yes** unless noted):

| ASC data type | Declare | Purposes to tick | Why |
|---|---|---|---|
| Contact Info → Name | Yes | App Functionality | account + business profile (Supabase) |
| Contact Info → Email Address | Yes | App Functionality | sign-in identity |
| Contact Info → Phone Number | Yes | App Functionality | business profile, synced |
| Financial Info → Other Financial Info | Yes | App Functionality | invoice/job amounts in the user's records (no card data — Stripe hosts payment pages) |
| Purchases → Purchase History | Yes | App Functionality | RevenueCat subscription receipts |
| User Content → Other User Content | Yes | App Functionality | customer records, jobs, notes (synced to Supabase; snapshots sent to AI providers) |
| User Content → Photos or Videos | **No — do not declare** | — | job photos are device-local only, never transmitted |
| Identifiers → User ID | Yes | App Functionality, Analytics | Supabase uid; also identifies PostHog/Sentry |
| Usage Data → Product Interaction | Yes | Analytics | PostHog screen/feature events |
| Diagnostics → Crash Data | Yes | App Functionality | Sentry crash reports |
| Location (any) | **No — do not declare** | — | no location permission; typed customer addresses are user content, not device location |

**Tracking section ("used to track you across apps/websites"): No for
everything.** No ATT prompt exists in the app, correctly.

## ASC quick answers (the small form fields)

- Price: **Free** (with in-app subscription — Monthly $19.99, Annual $199.99,
  2-week free trial; both products "Ready to Submit")
- Age rating questionnaire: all "No" → **4+**
- Copyright: **© 2026 Chad Rector**
- Support URL: https://czilla57.github.io/tradeready-legal/ (verify it
  renders and shows support@gettradereadyapp.com; any page with the support
  email satisfies Apple)
- Privacy Policy URL: https://czilla57.github.io/tradeready-legal/privacy.html
- Version: 1.0.0 — attach **build 5** (2f33dfff, smoke-passed 2026-07-16)

## Owner pre-submission checklist (state as of 2026-07-16)

- [x] Trial length verified — live paywall shows "2-week free trial";
      description now says the same
- [x] Demo account created + confirmed + re-seeded post-recovery
      (support-demo@gettradereadyapp.com); paste the password into the
      review notes in ASC only
- [x] Build attached is the fixed binary: 1.0.0(5), smoke-passed on device
- [ ] 30-second tap-through of the four least-tested features named in the
      copy: Pricebook, Recurring jobs, Review requests, Mileage log
- [ ] Screenshots: Today, Jobs, Pricing calculator, Invoice + payment link,
      AI chat, dark mode variant (6.7" and 6.1" sets)
- [ ] Verify the support URL renders (see quick answers above)
- [ ] **Attach BOTH subscriptions to the 1.0 version** (In-App Purchases and
      Subscriptions section on the version page) — first-time subs are
      reviewed with the binary; forgetting this is a guaranteed rejection
- [ ] Fill the App Privacy questionnaire per the table above, review notes +
      demo credentials in App Review Information, submit
