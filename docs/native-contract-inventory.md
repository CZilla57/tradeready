# Native Migration Contract Inventory

Updated: 2026-09-06

This document records the interfaces the Swift app must preserve. It is an
inventory, not permission to change the production backend.

## Application identity and platform contract

| Item | Production value |
|---|---|
| Display name | TradeReady |
| Bundle identifier | `com.gettradereadyapp.tradeready` |
| Apple team | `96J48TJWX3` |
| URL scheme | `tradeready` |
| Minimum native target | iOS 17.0 |
| Device families | iPhone and iPad |
| App group | `group.com.gettradereadyapp.tradeready` |
| Apple sign-in | Enabled in current app |
| Interface style | System/light/dark |
| Encryption declaration | Non-exempt encryption is false |

Required native capabilities eventually include Sign in with Apple, app groups,
push notifications, background tasks, camera/photo library, associated service
configuration for Google, StoreKit/RevenueCat, and WidgetKit/App Intents.

## Navigation inventory

- Root: Auth, Onboarding, Paywall, Starting Point, Main, dismissible Paywall.
- Tabs: Today, Jobs, Invoices, Customers, Money, AI Coach.
- Today stack: Today, Calendar, Route, Settings hub, 13 settings detail pages,
  Global Search.
- Jobs stack: list, detail, add/edit/duplicate, pricing calculator, change order,
  create invoice, send estimate, add customer, outreach, recurring jobs, review
  request, estimate follow-up.
- Invoices stack: list/detail presentation, add/edit, outreach, recurring list,
  recurring rule editor.
- Customers stack: list, detail, add/edit, add invoice, outreach.
- Money stack: overview, mileage, trip editor, pricebook, pricebook entry, export.
- Coach stack: chat with optional insight-prefilled prompt.

## Plain storage keys

`invoices`, `jobs`, `customers`, `settings`, `expenses`, `customerNotes`,
`recurringJobs`, `recurringInvoices`, `trips`, `pricebook`, `bookingRequests`, and
`jobPhotos`.

Additional lifecycle/operational storage includes onboarding and starting-point
flags, setup checklist state, duplicate dismissals, review-request records,
import history, insight mutes, notification permission prompts, sync queue,
sync cursors, per-user backfill/initial-sync markers, and data-owner identity.

Secure fields that must never enter plain synced settings are `providerKey`,
`anthropicKey`, and `groqKey`.

## App-group contract

Suite: `group.com.gettradereadyapp.tradeready`

| Key | Purpose |
|---|---|
| `widgetSnapshot` | Next job, active timer, and outstanding balance |
| `widgetActions` | Pending widget/Siri mutations replayed by the app |
| `activeTrip` | Siri-owned in-progress mileage state |
| `pendingOpenUrl` | Fresh cold-launch URL handoff |

Widget/App Intent mutations are queued requests; the main application remains
the authoritative writer.

## Deep-link contract

- `tradeready://job/<encoded-job-id>` opens a job.
- `tradeready://onmyway/<encoded-job-id>` opens the job and initiates the
  reviewed on-my-way action.
- A stashed `pendingOpenUrl` is accepted for at most five minutes and must still
  pass strict URL parsing.

## Notification payload contract

| Type | Required identifier | Destination |
|---|---|---|
| `overdue_outreach` | `invoiceId`, `daysPastDue` | Invoice outreach |
| `appointment_confirm` | `jobId` | Job detail |
| `recurring_invoice` | `ruleId` | Latest generated invoice or invoice list |
| `estimate_follow_up` | `jobId` | Estimate follow-up |
| `review_request` | `jobId` | Review request |
| `booking_request` | request context | Jobs list/attention queue |
| `booking_update` | optional `jobId` | Job detail or Jobs list |

## Cloudflare Worker HTTP contract

### AI and files

- `/api/ai-chat`
- `/api/pricebook-suggest`
- `/api/receipt-extract`
- `/api/invoice-pdf`
- `/api/photos/:photoId`
- `/api/photos-public/:photoId`

### Account, subscription, and payments

- `/api/delete-account`
- `/api/subscription/webhook`
- `/api/create-payment-link`
- `/api/stripe/connect-status`
- `/api/stripe/create-connect-account`
- `/api/stripe/disconnect`
- `/api/stripe/connect-return`
- `/api/stripe/webhook`

### Booking

- `/api/booking/mint`
- `/api/booking/config`
- `/api/booking/submit`
- `/api/booking/slots`
- `/api/booking/reserve`
- `/api/booking/manage`
- `/api/booking/respond`

### Estimates, change orders, and portals

- `/api/estimate/create-link`
- `/api/estimate/respond`
- `/api/estimate/view`
- `/api/estimate/change-view`
- `/api/estimate/change-respond`
- `/api/estimate/portal-view`
- `/api/estimate/portal-ics`
- `/api/estimate/portal-request`
- `/api/estimate/portal-manage`

### Scheduled operations

- `/api/cron/send-reminders`
- `/api/cron/send-invoice-emails`

The native client must match authorization, method, CORS-independent mobile
semantics, request shape, response shape, idempotency, and error behavior before
an endpoint is marked verified.

## Analytics event inventory

Current explicitly tracked events:

`ai_chat_sent`, `appointment_confirm_opened`, `booking_request_opened`,
`booking_update_opened`, `bulk_invoice_reminders`, `bulk_invoices_marked_paid`,
`change_order_created`, `change_order_decided`, `change_order_sent`,
`customer_created`, `customers_merged`, `estimate_follow_up_opened`,
`estimate_follow_up_sent`, `estimate_sent`, `expense_logged`,
`first_action_tapped`, `insight_coach_opened`, `insight_dismissed`,
`insight_reason_viewed`, `insight_shown`, `insight_snoozed`, `insight_tapped`,
`invoice_created`, `invoice_finalized`, `invoice_paid`, `job_created`,
`job_status_changed`, `on_my_way_sent`, `onboarding_completed`,
`onboarding_start_choice`, `onboarding_step_viewed`, `overdue_outreach_opened`,
`payment_link_sent`, `payment_recorded`, `payment_voided`,
`pricebook_entry_saved`, `pull_to_refresh`, `receipt_scanned`,
`review_request_sent`, `sample_job_opened`, `setup_checklist_dismissed`,
`setup_checklist_task_opened`, `sign_in`, `sign_up`,
`sign_up_confirmation_resent`, `subscription_paywall_shown`,
`subscription_purchased`, `tax_settings_saved`, `time_tracking_started`,
`trip_logged`, and `widget_deep_link_opened`.

Event names alone are insufficient for parity; property schemas and privacy
classification must be recorded before analytics implementation.

## Test baseline

The React Native repository currently contains 212 test files. These tests are
the primary behavior oracle, with special priority given to pricing, payment
math, sync/merge, migrations, recurring generation, booking availability,
estimate/change-order snapshots, PDF output, and accounting exports.
