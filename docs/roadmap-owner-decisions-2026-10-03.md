# Roadmap phases 24–34: decisions that need the owner (2026-10-03)

> **Owner answer (2026-10-03): "approve all recommendations."** Every item below takes its Recommended answer. Owner-run steps (`wrangler secret put`, Stripe Dashboard, the Apple entitlement request, applying migrations, publishing `tradeready-legal`) stay with the owner. Items whose recommendation is "later", "defer", "not now" or "at stage B/C" stay deferred to that point.

Every remaining roadmap phase now has a design spec under `docs/superpowers/specs/`. Building continues in the owner-set order (32 → 20 → 21 → 34 → 24 → 28 → 33 → 26 → 23 → 19 → 18). Everything that doesn't need you gets built.

The items below are the ones the specs flag as **yours to decide**. Each has a recommended answer. Until you answer, the gated parts are either left out, or built switched off behind a flag that defaults to off, and written down.

How to answer: "approve all recommendations", or list the IDs you want changed.

Not on this list, because the standing build rules already cover them:
- **Migration files:** written, never applied.
- **Local commits:** one branch per phase.
- **Uncommitted `tradeready-legal` page edits:** you commit and publish them.

## Phase 32 — Quote expiration (`2026-10-03-quote-expiration-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 32-A | Enforce the 30-day default for new estimates? (It was only printed before. Owners who don't want expiry set it to 0.) | Yes |
| 32-B | Add one sentence to `terms.html` §8 that estimates can expire, and to `privacy.html` that customer-submitted requests (booking, portal, update request) are stored? | Yes |
| 32-C | Keep the extra "expires in 2 days" reminder and use the word "estimate" (not "quote") in all copy? | Yes, both |

## Phase 34 — Referral program (`2026-10-03-referral-program-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 34-D6 | Ship referral credits as invoice credit lines in v1 (vs record-only)? | Yes (being built) |
| 34-D7–D9 | No saved referral template in v1; send a "thank them" prompt after the referred customer's first payment (within 60 days); the coach may name referrers | Yes |

## Phase 24 — Card on file & autopay (`2026-10-03-card-on-file-autopay-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 24-Q2 | Terms §4: add "Automatic payments", and change "does not process payments" to "does not hold funds or act as a payment intermediary" | Yes, as drafted in the spec |
| 24-Q3 | Privacy §1/§4: add the automatic-payment records bullet (card brand/last 4/expiry, Stripe ids, consent text/time/IP/browser) | Yes, as drafted |
| 24-Q4 | Approve the customer authorization wording (spec §2.3) used on the pay page, portal, checkout and email | Yes |
| 24-Q5 | App Store privacy label + `PrivacyInfo.xcprivacy`: declare **Payment Info** (linked, app functionality, not tracking) | Yes |
| 24-ops | You'll need to: run the payment-merge trigger verify script (its applied status is contradictory in the docs), confirm the Connect webhook, `wrangler secret put PAY_LINK_SIGNING_SECRET`, and run a Stripe test-mode smoke | — |

Also fixed in Phase 24, with no decision needed: the Stripe **deposit link always fails** (confirmed bug), and **one payment link can be paid twice**.

## Phase 28 — Tips (`2026-10-03-tips-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 28-Q1 | Privacy label: Financial Info is declared for Analytics only, but payment amounts sync for app functionality (an existing gap). Add the App Functionality purpose (same update as 24-Q5)? | Yes |
| 28-Q2 | Add a terms sentence that tips go to the business? | No (current §4 covers it) |

## Phase 33 — Campaigns & tags (`2026-10-03-campaigns-tags-design.md`)

v1 sends from the phone, one composer per recipient with a resumable queue, and needs nothing from you. The following are for an optional **Stage 2** (server-side bulk email):

| ID | Question | Recommended |
|---|---|---|
| 33-A1 | Send campaign email from TradeReady's servers via Resend? | **Not now**; revisit if owners regularly email 50+ recipients |
| 33-A2–A6 | Dedicated sending subdomain with SPF/DKIM/DMARC; paid Resend plan; separate marketing mailing-address setting; terms/privacy updates; 200/day cap + kill switch | Yes, all of them, but only if A1 is ever approved |
| 33-P | **Existing gap:** `privacy.html` doesn't list Resend or Cloudflare, though invoice/reminder email already uses them. Add them now? | Yes |

## Phase 26 — Calendar sync (`2026-10-03-calendar-sync-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 26-1 | Add `NSCalendarsFullAccessUsageDescription` with the spec's text (only busy start/end times leave the phone) | Yes |
| 26-2 | Leave out the write-only and legacy calendar keys | Yes |
| 26-3 | Privacy manifest: count busy times under the declared "Other User Content" (comment change only) | Yes |
| 26-4 | App Store label: fold busy times into the existing "Other User Content" row | Yes |
| 26-5 | Add the "Calendar busy times (optional)" paragraph to `privacy.html` §1 before the build ships | Yes |
| 26-7 | Server-side Google Calendar OAuth now? | No |
| 26-8 | Subscribable ICS feed in this phase? | Defer |

## Phase 23 — Read-only open API (`2026-10-03-open-api-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 23-Q2 | Privacy wording: API keys let services you choose read the data you picked; requests are logged (time, key, endpoint, IP) for 90 days | Yes |
| 23-Q3 | Add a short "API access" section to the terms | Yes |
| 23-Q4 | Base URL: existing workers.dev host for v1 (not a custom `api.` domain) | workers.dev |
| 23-Q5 | No App Store privacy-label change | Confirm |
| 23-Q6 | Keys keep working when a subscription lapses (decide later with entitlement enforcement) | Not in v1 |
| 23-Q7 | Cloudflare rate-limit binding as an extra layer | Optional, not needed |

## Phase 19 — E-signature upgrade (`2026-10-03-esignature-upgrade-design.md`)

| ID | Question | Recommended |
|---|---|---|
| 19-Q2 | Approve the electronic-records disclosure text | Yes, after one lawyer review |
| 19-Q3 | Approve the intent statement and checkbox wording | Yes |
| 19-Q4 | Rewrite terms §8 and update the privacy §1 approval-records bullet | Yes |
| 19-Q5 | Adopt the can-say / must-not-say claims lists, and never call it "legally binding" in the product | Yes |
| 19-Q6 | On account deletion keep deleting signature records (as the privacy policy says) and warn owners to export first | Keep deleting |
| 19-Q7 | Email the signer a copy through the existing Resend sender | Yes |
| 19-Q8 | Optional email-code verification for big jobs | Later, off by default |
| 19-Q9 | In-person signing on the owner's phone | Defer until FTC Cooling-Off copy is lawyer-reviewed |
| 19-Q10 | Generate an Ed25519 key pair; private key as a Worker secret, public key published | Yes (you run `wrangler secret put`) |
| 19-Q11 | No privacy-label change | Confirm |

## Phase 18 — Tap to Pay (`2026-10-03-tap-to-pay-design.md`)

Stage A can be built now: the Worker routes, the ledger `channel: "card_present"`, and a fake card reader behind a flag that defaults to off. The rest waits on you.

| ID | Question | Recommended |
|---|---|---|
| 18-Q1 | Is the Apple Developer account (team `96J48TJWX3`) an **Organization**? If so, request the Tap to Pay development entitlement now (critical path, ~4–8 weeks) | Yes, request now |
| 18-Q2 | Add the Stripe Terminal iOS SDK 5.8.x as a fifth Swift package (~30 MB) | Yes, at stage B |
| 18-Q3 | Stripe Dashboard: add `payment_intent.succeeded` to the Connect webhook (after confirming the payment-merge trigger is applied) | Yes, at stage C |
| 18-Q4 | Location and Bluetooth permission strings (the app's first location permission, asked only when Tap to Pay is turned on) | Yes |
| 18-Q5 | Privacy label/manifest updated to match the Stripe SDK's manifest | Yes, at stage B |
| 18-Q6 | Terms §4 / privacy §4 in-person payment wording | Yes |
| 18-Q7 | The launch email, splash screen and push notification Apple requires for public Tap to Pay apps | Yes, minimal versions |
| 18-Q8 | Keep direct charges on the existing Express accounts despite Stripe's caution | Yes; revisit with Phase 24 |

## Findings outside the phases (for awareness)

- **Fixed and committed:** the Worker took the client IP from a spoofable header (`dd4c9b7`), and account deletion left invoice PDFs in R2 (`965c9a3`).
- **To be fixed in the next build step:** the native app labels Stripe payments "Other".
- **Pre-existing master test failures:** the five-tab bar commit (`a4db097`) broke four audit checks. The fix is on your local branch `native/booking-lead-local-date` (`97be13e`), not merged.
- **Retiring model:** the user-key Groq model id `llama-3.1-8b-instant` (`NativeCoachTransport.swift:45`) is being retired. The Worker already uses `openai/gpt-oss-20b`.
- **Uncommitted project-file change:** `native/TradeReadyNative.xcodeproj/project.pbxproj` has a change that looks like Xcode re-saved the file. It removes `TradeReadyWidgets.entitlements` from the widget target's exception set. It was left out of every commit; please check it.
