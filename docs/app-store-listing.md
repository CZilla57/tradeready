# App Store listing — TradeReady 1.0 (draft 2026-07-14)

Everything below respects the claims rule: only device-verified or
code-verified-and-shipping features are claimed. Route optimization, OCR/
receipt scanning, tax tools, team accounts, and a web dashboard are NOT
mentioned anywhere — they don't exist.

---

## App name (30 chars max)

**TradeReady** (10)

## Subtitle (30 chars max)

**Jobs, invoices & AI pricing** (27)

## Category

Primary: **Business** · Secondary: **Productivity**

## Promotional text (170 chars max — editable anytime without review)

> Price jobs with confidence, send estimates and invoices in seconds, and
> get paid faster with payment links. Your AI coach knows your numbers.
> Works offline. (161)

## Keywords (100 chars max, comma-separated — avoid repeating name/subtitle words)

`estimate,plumber,electrician,handyman,contractor,hvac,landscaping,quote,tradesman,payment` (89)

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

TradeReady is a subscription with a free trial, so you can run real jobs
through it before paying a cent. Cancel anytime in your App Store settings.

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
> Email: [OWNER: create e.g. demo@gettradereadyapp.com and confirm it]
> Password: [OWNER: set + paste]
>
> Subscription: the app shows a paywall after onboarding. The demo account /
> sandbox environment supports the free-trial purchase flow. Restore
> Purchases is on the paywall.
>
> Payment links are processed via Stripe Connect on the user's own Stripe
> account; the app itself never handles card data. The AI assistant uses a
> server-side proxy; no user API key is required.

## Privacy nutrition label — cheat sheet (fill in App Store Connect)

Data linked to the user:
- Contact info: name, email, phone (account + business profile)
- Financial info: invoice/job amounts (user's business records; no card data)
- User content: customer records, notes, photos metadata (photos stay on-device)
- Identifiers: user ID
- Usage data + diagnostics: analytics (PostHog), crash logs (Sentry)

Third parties receiving data (disclose): Supabase (database/auth), Anthropic
& Groq (AI requests incl. business snapshot), RevenueCat (subscription
receipts), Stripe (payment links), PostHog (analytics), Sentry (crashes),
OpenStreetMap/Nominatim (address autocomplete queries).

Tracking (ATT): none — no cross-app tracking, no ads. Answer "No" to
tracking.

## Owner pre-submission checklist

- [ ] Verify the trial length shown on the live paywall matches whatever the
      description implies (copy above deliberately says only "free trial")
- [ ] 30-second tap-through of the four least-tested features named in the
      copy: Pricebook, Recurring jobs, Review requests, Mileage log
- [ ] Create + confirm the demo account, load sample data, put credentials
      in the review notes
- [ ] Screenshots: Today, Jobs, Pricing calculator, Invoice + payment link,
      AI chat, dark mode variant (6.7" and 6.1" sets)
- [ ] Support URL for ASC: use the legal site or a simple page listing
      support@gettradereadyapp.com
