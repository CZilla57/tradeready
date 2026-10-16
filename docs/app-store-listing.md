# App Store listing — TradeReady (refreshed 2026-10-16 for 2.0.0, build 15)

Everything below respects the claims rule: only device-verified or
code-verified-and-shipping features are claimed. Route optimization, team
accounts, a web dashboard, automatic (GPS) mileage, bulk email from our
servers, and "legally binding" e-signatures are NOT mentioned anywhere.

2026-10-16 refresh (2.0.0, build 15 — the native SwiftUI app, roadmap
phases 25 → 18): new promo text, rewritten description (AEO, see below),
What's New for 2.0.0, screenshot captions, refreshed quick answers.
Claimable because ship-wizard stages 1–19 are done (migrations applied,
Worker deployed, legal pages published, pay-page links and API access on,
build uploaded; `scripts/.ship-roadmap-progress`):
quote options (25), lead source (27), quote expiration (32), job forms (20),
properties & equipment (21), referrals (34), autopay (24), tips (28),
campaigns & tags stage 1 (33), calendar sync (26), read-only API (23).
NOT claimed:
- E-signature upgrade (19) — off until `ESIGN_V2` (wizard stages 21–24).
  Basic online estimate approval (shipping since 1.1) is still claimed.
  When it ships, follow the esign spec §7 can-say/must-not-say lists;
  never say "legally binding".
- Tap to Pay (18) — dark at stage A; Individual Apple account.
- Push notifications — native 2.0 has local notifications only (waiver
  G1, `docs/native-phase-12-cutover-charter.md` §5.1); booking alerts
  arrive by email. Copy never says "push" or "instant alerts".
- Campaign email from our servers (33 stage 2) — deferred; campaigns are
  claimed only as "sent from your phone".
- "Faster" — no performance evidence for the rewrite is recorded, so the
  copy says "rebuilt natively", not "faster".
- Seamless data carry-over from 1.2.1 — the AsyncStorage-upgrade parity
  rows are still blocked on device evidence. Add a line only after the
  TestFlight upgrade check passes (checklist below).

AEO (answer-engine optimization) applied to the description and captions:
- Opening sentence is a self-contained definition — what it is
  ("a job management app"), who it's for (named trades), what it does.
  AI assistants and web search lift this sentence when answering "what's
  a good app for a plumber to send invoices?". Keep it first and literal.
- Entity consistency: always "TradeReady", always "estimates" (not
  "quotes", owner decision 32-C), "job management app" as the category
  phrase, same trades list as the keywords field.
- Each bullet is a standalone fact with a concrete number or noun
  (30 days, two or three options, make/model/serial), so it survives
  being quoted out of context. No unverifiable superlatives.
- A closing QUICK ANSWERS block in question → answer form mirrors the
  questions people ask assistants (who it's for, do customers need the
  app, do I need Stripe, how much). Plain text: App Store descriptions
  render no markup, so ALL-CAPS section labels stand in for headings.
- Siri phrasing is quoted exactly as the App Shortcut phrase
  ("What's my next job in TradeReady"), not a paraphrase.
- No competitor names anywhere in metadata (App Review Guideline 2.3.7).
- Limits of the technique: Apple's own search indexes the name, subtitle
  and keywords field, not the description. The description is what
  assistants and web search read from the public apps.apple.com page,
  and it drives conversion. Screenshot-caption indexing is reported by
  ASO vendors but unconfirmed by Apple, and one controlled test found
  almost no ranking effect: treat captions as conversion copy first.

2026-08-18 refresh: de-emphasized "AI" (owner call — "AI" in the subtitle
was suspected to make trade searchers scroll past). Subtitle "Invoice,
estimate & AI pricing" → "Estimates, invoices & pricing"; promo text and
three description bullets reworded ("pricing engine", "Smart rate
suggestions", "Ready-to-send follow-ups", "built-in coach"). No feature
was dropped — the pricing engine and coach are still described, just not
headlined. NOT a review-relevant change (metadata only), so it can go into
ASC anytime without a new build. Keywords unchanged (no "ai" keyword to
remove there).

2026-08-01 refresh: added What's New for 1.1.0 (build 7); legal/support
URLs moved from czilla57.github.io to gettradereadyapp.com (the apex
serves the site directly since 2026-07-30; old github.io URLs 301, but
the listing should carry the canonical host); version quick-answer now
points at 1.1.0 build 7.

2026-07-16 refresh: 2-week free trial confirmed on the live paywall
($19.99/mo, $199.99/yr) so the description now names the trial length; demo
account exists (support-demo@gettradereadyapp.com); nutrition-label section
expanded to the full ASC questionnaire; ASC quick answers added.

---

## App name (30 chars max)

**TradeReady: Trade Job Manager** (29) — unchanged

Bare "TradeReady" is taken ("TradeReady — Trades Training", an education
app); this suffix both clears the collision and differentiates us as
management software. The name under the icon on the device stays
**TradeReady**.

## Subtitle (30 chars max)

**Estimates, invoices & pricing** (29) — unchanged

Considered for 2.0 and rejected: "Estimates, invoices & autopay" (29).
Autopay is new but applies only to maintenance plans, while pricing is
the core differentiator and the owner's 2026-08-18 call. Revisit if ASC
search data shows "autopay" queries landing on us.

## Category

Primary: **Business** · Secondary: **Productivity**

## Promotional text (170 chars max — editable anytime without review)

> New in 2.0: rebuilt for iPhone and iPad, with good/better/best estimates, autopay for maintenance plans, tips, job checklists, equipment history and calendar sync. (163)

Once 2.0 has been live a few weeks, swap back to an evergreen line, e.g.
the 1.x text: "Price jobs with confidence, send estimates and invoices in
seconds, and get paid faster with payment links. A built-in coach knows
your numbers. Works offline." (164)

## Keywords (100 chars max, comma-separated — avoid repeating name/subtitle words)

`roofer,plumber,electrician,handyman,contractor,hvac,landscaping,quote,tradesman,payment,carpenter` (97) — unchanged

Keywords are an ASO lever, not an AEO one, and nothing in the repo
records ASC search-volume data to justify a swap. Candidates if a slot
frees up: booking, checklist, autopay. Never add a competitor's name.

## Description (4000 chars max — this draft 3930)

TradeReady is a job management app for self-employed tradespeople: plumbers, electricians, HVAC techs, roofers, carpenters, landscapers, handymen and other solo contractors. It prices jobs, sends estimates and invoices, collects card payments, and keeps your schedule, customers and numbers on your iPhone or iPad.

No experience needed: if you're new to running your own business, TradeReady teaches you as you go.

PRICE JOBS AND WIN THE WORK
• A pricing engine for the trades: labor, materials with markup, overhead and profit margin, with a warning before you quote below break-even
• Good/better/best estimates: offer two or three options plus add-ons. Your customer picks one online and their choice flows into the invoice
• Estimates show a valid-until date (30 days by default, or your choice), and customers can ask for an updated one
• Send estimates by text or email as a polished PDF; customers approve online, no app needed
• A pricebook of your standard services, reusable in seconds

GET PAID FASTER
• Invoices in seconds from any job, with card-payment links powered by Stripe. Invoices mark themselves paid
• Autopay for maintenance plans: customers can choose to save a card and be charged on each due date, never more than the amount they approved, with an emailed receipt every time
• Optional tips when a customer pays an invoice online. Tips go to you
• Deposits, partial payments, recurring invoices and overdue reminders

RUN EVERY JOB
• Job forms and checklists: ready-made templates (site safety, HVAC maintenance, electrical, plumbing and more) or your own, with photos on any item and a shareable PDF report
• Properties and equipment history: every service address for a customer, plus the make, model, serial number, install date and warranty of the equipment there, with a heads-up before a warranty runs out
• Online booking: customers pick a real open slot from your link, and a customer portal lets them reschedule or cancel
• Calendar sync: busy times from the calendars on your iPhone keep those slots off your booking page, and your jobs can appear in a TradeReady calendar
• Time tracking, photos and notes on every job

GROW WITH THE CUSTOMERS YOU HAVE
• Lead sources: see which channels bring in work, with close rate and cash collected for each
• Referrals: share a personal referral link, see who referred whom, and add a thank-you credit to the next invoice
• Campaigns: pick past customers who are due for maintenance or haven't booked in a while, then send each a personal text or email from your own phone, with opt-outs respected
• Customer tags and review requests

KNOW YOUR NUMBERS
• Profit and loss, job profitability (estimate vs. actual), cash-flow forecasts and tax set-aside
• A business coach that knows your numbers: ask about revenue, overdue invoices or what to charge
• Expenses with receipt scanning, a mileage log, and a one-tap accountant export
• Read-only API keys to connect your bookkeeping tools

BUILT FOR THE JOB SITE
• Jobs, estimates, invoices and notes work without signal and sync when you're back online
• Home Screen widgets for your next job and job timer
• Siri: ask "What's my next job in TradeReady," clock in, log an expense or start a trip, hands-free
• Dark mode, and full support for iPad

QUICK ANSWERS
Who is TradeReady for? Solo and small trade businesses that do their own quoting, scheduling and billing.
Do my customers need the app? No. They approve estimates, book, and pay from a link in any web browser.
Do I need a Stripe account? Only to take card payments, autopay or tips. Everything else works without one.
How much is it? Free to download, with a 2-week free trial of the subscription, then monthly or yearly. Cancel anytime in your App Store settings.

Privacy policy: https://gettradereadyapp.com/privacy.html
Terms of use: https://gettradereadyapp.com/terms.html
Questions? support@gettradereadyapp.com. A real person reads it.

## Screenshot captions (2.0.0 set — 6.9" and 13" iPad)

Marketing frames (upload these): `assets/app-store/2.0.0/marketing/`,
rendered in Remotion from `~/dev/tradeready-promo/src/appstore/Marketing.tsx`
(`npx remotion still src/appstore/index.ts <id> <out.png>`). The style matches
the live 1.x set: navy field, blue glow behind the device, bold two-line
headline, one-line subhead. The headline and subhead are the caption text;
copy lives in `SLIDES` in `Marketing.tsx`. Order is deliberate: the first
three are what most people see without swiping.

| # | File | Headline | Subhead | Screen |
|---|---|---|---|---|
| 1 | `M01-Today.png` | Start every day in control. | Jobs, follow-ups, and insights at a glance. | Today |
| 2 | `M02-Options.png` | Good, better, best estimates. | Offer options. Customers pick one online. | Send Estimate |
| 3 | `M03-Pricing.png` | Price every job with confidence. | Labor, materials, overhead, and margin in one place. | Pricing calculator |
| 4 | `M04-Autopay.png` | Get paid without chasing it. | Autopay for maintenance plans, card payment links, and tips. | Invoice with autopay (mockup) |
| 5 | `M05-Checklists.png` | Checklists that finish the job. | Inspection and safety forms with photos and a PDF report. | Job checklist |
| 6 | `M06-Equipment.png` | Know every unit you service. | Equipment, serial numbers, and warranties at every address. | Property & equipment |
| 7 | `M07-Calendar.png` | Your schedule, sorted. | Day and week views that work around your calendar. | Calendar |
| 8 | `M08-Profit.png` | Know your profit on every job. | Estimate vs. actual, down to what you earned per hour. | Estimate vs actual (mockup) |
| 9 | `M09-Widgets.png` | Your next job, one glance away. | Home Screen widgets for your next job and job timer. | Home Screen widgets |
| 10 | `M10-iPad.png` (13" iPad, 2064×2752) | Built for iPhone and iPad. | Your whole business on a bigger screen. | iPad job detail, dark |

Frames 1–9 are 6.9" iPhone (1320×2868). ASC needs a separate 13" iPad
set; M10 is the only iPad frame so far (ASC requires at least one).
Raw captures the frames are built from are in `assets/app-store/2.0.0/`
(the 04b tip invoice is a spare in `mock/`).

Demo data only (the "Explore with sample data" business), never a real
customer's name, address or card.

Captures live in `assets/app-store/2.0.0/` (gitignored). Frames 4 and 8
are Remotion mockups (`assets/app-store/2.0.0/mock/`, source in
`~/dev/tradeready-promo/src/appstore/`, render with
`npx remotion still src/appstore/index.ts <id> <out.png>`). They use the real
status bar and tab bar cropped from simulator captures and show only states
the app can really display, with strings taken from the native code
(`InvoicesView.swift`, `Domain/NativeAutopay.swift`,
`NativeJobProfitabilityView.swift`). App Review Guideline 2.3.3 wants
screenshots to show the app in use. Replace a mockup with a real capture
once the state can be produced (Stripe connected for 4; a completed job
with tracked hours and expenses for 8).

## What's New (version 2.0.0, build 15 — paste into ASC as-is)

TradeReady 2.0 is rebuilt from the ground up as a native iPhone and iPad app, with new ways to win work and get paid.

NEW
• Good/better/best estimates — offer two or three options plus add-ons. Your customer picks one online and the choice carries into the invoice
• Estimates now have a valid-until date — 30 days by default or your choice, a reminder before one lapses, and customers can request an updated estimate
• Autopay for maintenance plans — customers can choose to save a card and pay each plan invoice on its due date, never more than the amount they approved
• Tips — let customers add an optional tip when they pay an invoice online
• Job forms and checklists — ready-made safety and inspection templates or your own, with photos and a shareable PDF report
• Properties and equipment — every service address for a customer and the equipment at each one, with a heads-up before a warranty runs out
• Lead sources — see which channels bring in work and what each one is worth
• Referrals — share referral links, see who referred whom, and say thanks with an invoice credit
• Campaigns and customer tags — reach past customers who are due for maintenance with personal texts or emails sent from your phone
• Calendar sync — busy times from your iPhone calendars stay off your booking page, and your jobs can appear in your calendar
• API access — create read-only keys to connect your bookkeeping tools

IMPROVED
• Everything you rely on from 1.2 — widgets, Siri, online booking, the customer portal, job profitability and the accountant export — rebuilt natively
• Dozens of smaller fixes and polish throughout

Questions? support@gettradereadyapp.com — a real person reads it.

Notes cover everything since the 1.2.1 STORE release (Expo). Every NEW
item is one of the eleven claimable phases above. Not mentioned on
purpose: e-signature upgrade, Tap to Pay, push notifications, data
carry-over (see the header). If the owner wants to tell 1.2.1 users that
booking alerts now arrive by email instead of push, add under IMPROVED:
"New booking requests, reschedules and cancellations now arrive by
email." That is an owner call, not drafted in by default.

## What's New (version 1.2.0, build 12 — paste into ASC as-is)

TradeReady 1.2 puts your day on your Home Screen and lets your customers
help themselves.

NEW
• Home Screen widgets — Next Job and Job Timer keep you moving without
  opening the app
• Talk to TradeReady — "Hey Siri, what's my next job," clock in and out,
  log an expense, start a mileage trip, or check what you're owed, all
  hands-free
• Customers can book you online — share your own booking link and they
  pick a real open slot around your working hours, buffers, and days off
• A customer portal — customers see their appointments and photos, request
  changes, and reschedule or cancel themselves, no account needed
• Job profitability — see estimate vs. actual cost on every job, right
  down to the margin
• One-tap accountant export — a complete package of CSVs, zipped and ready
  to hand off at tax time
• A smarter Today screen — TradeReady now flags low-margin estimates,
  maintenance coming due, and expenses that look off
• Import your existing customers, jobs, and invoices from a spreadsheet
• Turn on auto-invoicing — the moment a job is marked complete, TradeReady
  creates the invoice and emails it for you
• Full iPad support

IMPROVED
• Smarter scheduling — end times auto-fill and overlaps get flagged
  before you double-book
• Faster, friendlier estimate follow-ups
• Fixed a bug where switching tabs could leave the back button on the
  wrong screen
• Dozens of smaller fixes and polish throughout

Questions? support@gettradereadyapp.com — a real person reads it.

Notes cover everything since the 1.1.0 STORE release (build 7), including
features delivered by OTA on 2026-08-06/08-07 (calendar/availability/
booking, customer portal expansion, job profitability, accountant export,
contextual AI insights, CSV import, auto-invoicing) plus the widgets/Siri/
iPad support that ship natively for the first time in build 12. Claims
discipline per docs/release-runbook-1.2.0.md: widgets/Siri copy is only
valid once the Tier-2 smoke checklist has passed on this build — confirm
before submitting, since build 12's own device smoke was still pending as
of 2026-08-08.

## What's New (version 1.1.0, build 7 — paste into ASC as-is)

TradeReady 1.1 is our biggest update yet.

NEW
• Sign in with Apple or Google — get started in seconds
• Deposits & partial payments — request money up front and track every
  payment against the balance
• Recurring invoices — bill your regulars automatically, on their schedule
• Customers can now approve estimates online with one tap — you're
  notified the moment they say yes
• Appointment reminders and one-tap "On my way" texts
• Tax set-aside — automatically earmark a slice of every payment so tax
  time never stings
• Scan receipts with your camera — the details are filled in for you
• Email invoices as professional PDF attachments, with your business logo
  on every document
• Export invoices, jobs, customers, and expenses to CSV for your accountant

IMPROVED
• A fresh new look across the whole app — cleaner, bolder, easier to read
• Simpler navigation — Settings now lives behind the gear on your Today
  screen
• Find jobs, customers, and invoices faster with search everywhere
• Jobs mark themselves paid the moment their invoice is paid
• Invoice and estimate emails are now far smaller and faster to send
• Dozens of smaller fixes and polish throughout

Questions? support@gettradereadyapp.com — a real person reads it.

Notes cover everything since the 1.0 STORE release, including features
delivered by OTA on 2026-07-30 (estimate approval, appointment reminders,
receipt scanning, PDF attachments) — 1.0's notes were only the welcome
blurb, so all of it is "new" against the last store notes. Claims rule
before submitting for review: build 7 is the first binary carrying the new
native modules, so on TestFlight verify Apple AND Google sign-in complete,
send one invoice email with a logo end-to-end, and tap through deposits,
receipt scan, recurring invoices, tax set-aside, and CSV export.
(COMPLETED 2026-08-01 — owner ran the smoke pass and submitted for review.)

## What's New (version 1.0 — shipped 2026-07-24, kept for the record)

> Welcome to TradeReady 1.0 — price jobs, send estimates and invoices, get
> paid with payment links, and run your whole trade business from your
> pocket. Works offline, syncs everywhere.

---

## App Review notes (paste into App Store Connect "Notes" + attach demo account)

**For 2.0.0 use the note in `docs/native-phase-12-release-readiness.md`
§7 (updated 2026-10-15 for the native build: sample-data onboarding,
calendar permission, local-only notifications, the Stripe vs In-App
Purchase paragraph, API access).** It is kept there so the two never
drift. The note below is the 1.x (Expo) version, kept for the record.

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

Ground truth (verified 2026-07-16; amended 2026-08-06 — receipt OCR shipped
in 1.1.0 and trip cloud-sync rides the post-1.1.0 OTA, label republished in
ASC accordingly): Supabase (database/auth), Anthropic & Groq via our proxy
(AI requests incl. business snapshot; receipt photos relayed to Groq for
OCR, not stored on our servers), RevenueCat (subscription receipts), Stripe
(payment links on the user's own Connect account), PostHog (analytics,
identified by user id), Sentry (crashes, identified by user id),
OpenStreetMap/Nominatim (typed address queries). Mileage trips sync to
Supabase like other collections; job photos remain device-local. No ads,
no data brokers, no cross-app tracking. `identifyUser()` ties PostHog + Sentry to the
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
| Financial Info → Payment Info | Yes (declared 2026-10-03, Phase 24 Q5) | App Functionality | autopay: the app shows the owner's customers' saved-card brand, last four digits and expiry (full card numbers stay with Stripe; card entry is on Stripe's hosted page) |
| Financial Info → Other Financial Info | Yes | App Functionality, Analytics | invoice/job amounts in the user's records; payment amounts in analytics events (Phase 28 Q1 added App Functionality to the manifest 2026-10-03) |
| Purchases → Purchase History | Yes | App Functionality | RevenueCat subscription receipts |
| User Content → Other User Content | Yes | App Functionality | customer records, jobs, notes, mileage trips, job forms, properties/equipment, tags (synced to Supabase; snapshots sent to AI providers); optional calendar busy start/end times only (Phase 26 decision 26-4, folded in 2026-10-16) |
| User Content → Photos or Videos | Yes (declared 2026-08-06) | App Functionality | receipt scans sent via the authenticated backend to Groq for OCR, not stored server-side; job photos stay device-local |
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
- Support URL: https://gettradereadyapp.com/ — the apex serves the
  tradeready-legal site directly (custom domain since 2026-07-30); the root
  serves `index.html`, a support page with support@gettradereadyapp.com and
  a FAQ. Added 2026-07-24 after App Review rejected this URL as
  non-functional: the repo had no index.html, so the site root returned
  404. Do not delete index.html from tradeready-legal.
- Privacy Policy URL: https://gettradereadyapp.com/privacy.html
- Version: **2.0.0** — attach **build 15** (native, archived 2026-10-15 from
  master `905bd76`, uploaded via Organizer; must stay below Expo rollback
  candidate R 2.1.1). Minimum iOS 17.0; iPhone and iPad.
- Previous: 1.1.0 build 7 (submitted 2026-08-01); live before 2.0 is
  1.2.1 (Expo).

## Owner pre-submission checklist — 2.0.0 (added 2026-10-16)

- [ ] Paste promo text, description, What's New and captions above; the
      name, subtitle and keywords are unchanged. If 2.0 is already in
      review, What's New and the description are locked until it is
      removed from review; promo text can change anytime
- [ ] Confirm the paywall on build 15 still shows a 2-week free trial
      (the native app reads it from StoreKit, `N/NativeSubscription.swift`);
      if not, fix "2-week" in the description's QUICK ANSWERS
- [ ] Wizard stage 20 (open API smoke test) passes before submitting,
      or cut the "API access" lines from the description and What's New
- [ ] Privacy label: fold calendar busy times into Other User Content
      (table above). Build 15 ships without the Sentry DSN; leave Crash
      Data declared (a later build turns it back on) unless the owner
      decides otherwise
- [ ] Screenshots per the caption list, from the sample-data business
- [ ] Optional: after the TestFlight upgrade check from 1.2.1 passes, add
      "Sign in and your jobs, customers and invoices are right where you
      left them" under IMPROVED
- [ ] When e-signature (stages 21–24) or Tap to Pay ships, refresh this
      listing and the review note (both currently leave them out)

## Owner pre-submission checklist (1.0, state as of 2026-07-16)

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
- [ ] Verify the support URL renders (see quick answers above) — index.html
      added 2026-07-24; re-check the live root URL after the Pages deploy
- [ ] **Attach BOTH subscriptions to the 1.0 version** (In-App Purchases and
      Subscriptions section on the version page) — first-time subs are
      reviewed with the binary; forgetting this is a guaranteed rejection
- [ ] Fill the App Privacy questionnaire per the table above, review notes +
      demo credentials in App Review Information, submit
