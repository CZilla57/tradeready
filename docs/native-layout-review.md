# Native iOS — Layout & Labeling Review

Walkthrough of the native SwiftUI app on the iOS Simulator (iPhone 17 Pro,
sample-data account), focused on layout clarity and the "boxes with no idea what
they're for" problem. Screens are grouped by priority.

## The one root cause behind most of this

**Form fields use their placeholder text as the *only* label.** There is no
persistent (floating) label above a field. This reads fine on an **empty create
form** (the placeholder stands in for the label), but on any **pre-filled
screen** the placeholder disappears the moment a value is present, leaving a bare
box with no indication of what it holds.

- Empty, fine: New Customer form — `Name` / `Phone` / `Email` / `Address` /
  `Access details, preferences…` all read clearly *because they're empty*.
- Filled, broken: Business Profile and Pricing Defaults (below) are the same
  components with data in them — and you can't tell what each box is.

**Recommended fix (one change, many screens):** give the shared text-field
component a persistent caption/floating label above the value. Fixing the
component fixes Business Profile, Pricing Defaults, and every edit-existing-record
screen at once.

---

## High priority — unlabeled filled fields

### Business Profile  (Settings › Business profile)
- **BUSINESS**: two stacked boxes show `Demo Plumbing Co` and `Review Tester`
  with no labels — which is business name, which is owner/contact name? Not
  knowable at a glance.
- **CONTACT**: the filled email box has no label; only the empty `Phone` and
  `Business address` boxes read clearly (because they're empty placeholders).
- **`Trade` row** is ambiguous — "Trade" reads as if it could be either the field
  label or the selected value.
- **CUSTOMER DOCUMENTS**: a single multiline box (`Payment due upon completion…`)
  with no label and no helper. Compare to Review Requests' message box, which has
  an "Available fields:" helper — that's the pattern to copy.
- **Fix**: add labels (Business name, Your name, Trade, Email, Phone, Address) and
  a caption on the documents box ("Default terms shown on invoices & estimates").

### Pricing Defaults  (Settings › Pricing defaults)
This page is self-inconsistent — one section is a model, two are unlabeled:
- **LABOR**: `85.00` and `0.00` — bare numeric boxes, no labels. Is 85 the hourly
  rate? What is 0.00 for?
- **MINIMUMS & TRAVEL**: `75.00`, `0.70`, `1.5` — three bare numbers. Minimum
  charge? Per-mile rate? A multiplier? No way to tell.
- **MARKUP & MARGIN**: `Material markup 20%`, `Overhead 15%`, `Profit margin 20%`
  — **this is the correct pattern**: inline label + value + unit. Apply it to the
  other two sections.

---

## Medium priority

### More menu (Money / Coach)
- The `Money` and `Coach` rows have icon + chevron but **no subtitles**,
  inconsistent with the Settings list where every row has a helper line. Add
  subtitles, e.g. "Income, expenses & profit" and "Ask the AI assistant".

### Notifications (Settings › Notifications)
- **`Automatically email once`** is ambiguous — email *what*, once? It reads as a
  sub-option of `Overdue invoice reminders` but has no indentation, helper, or
  disabled-until-parent-on state to show that dependency.
- Consider a one-line helper under the less obvious toggles
  (`Create invoice when complete`, `Estimate follow-ups`).

### Settings list — missing icon
- The **`Pricing defaults`** row renders a **blank light-blue square** where its
  icon should be. Every other row has an icon.

### Money — category chart
- "Spending by category" renders **all 8 categories even when only one has data**,
  leaving 7 empty rows consuming vertical space. Collapse/compact zero-value
  categories, or sort non-zero to the top.

---

## Low priority / polish

- **Invoice Numbering**: the `INV-` prefix box has no explicit label (inferable
  from the FORMAT header + live "Next invoice → INV-0001" preview, so low risk).
- **Coach**: large empty vertical gap between the "Ask about pricing…" subtitle
  and the suggested-prompt chips; pull the prompts up or center the header block.
- **Review Requests**: `Delay: 1 hour` doesn't say *after what* (after job
  completion?). Add two words.

---

## Screens that are already good (use as the reference pattern)

Inline labels, section headers, and helper text done right — no changes needed:

- **Settings top-level list** — every row has a descriptive subtitle.
- **Schedule** — intro helper line + every control inline-labeled.
- **Import Data** — section header *and* explanatory paragraph per action.
- **Payments**, **Booking Link**, **AI Assistant**, **Appearance**,
  **Subscription**, **Account** — clear status/labels/helpers throughout.
- **Review Requests** — the message-template box with an "Available fields:"
  helper is the model for any editable free-text box.
- **Today, Jobs, Job Detail, Invoices, Customers** — strong, consistent
  card/section hierarchy; everything labeled.

---

### Note on how this was reviewed
Reviewed on a real signed-in fresh account. Reaching the main app required
getting past the RevenueCat paywall without a StoreKit sandbox purchase; a
runtime-gated debug bypass (launch argument `-TRReviewBypassPaywall`) was used for
the review only and is not part of the shipping flow. The Subscription screen
therefore shows "active" as a side effect of that bypass — not a real entitlement
and not a layout finding.
