# Booking / Request-a-Quote Link — Design Spec

**Date:** 2026-08-04
**Status:** Approved architecture (owner memo sign-off 2026-08-04); spec pending owner review
**Roadmap:** Phase 9 (docs/post-launch-feature-roadmap.md) — "biggest growth item"
**Sequencing:** Builds first; the customer portal (separate spec) follows and reuses this
infrastructure. Push-notification pipeline is included here as its first use case
(owner-added scope, 2026-08-04).

## 1. Goal

A tradesperson shares one public link. A customer opens it, fills in a short
request-a-quote form, and the request lands in the tradesperson's Jobs list as a
`lead` with a proper Customer record — plus an immediate email (and, once push
credentials are live, a push notification) so a hot lead is never missed while
on a job.

**v1 scope decisions (owner, 2026-08-04):**
- Quote-request form only. No slot picking, no public availability, nothing
  auto-schedules. Preferred timing is captured as free text into job notes.
- Auto-convert: every valid submission becomes Customer + lead Job. No review
  inbox. Spam cost accepted (rate limit + honeypot + capability-URL mitigate).
- Alerts: email now (Resend, already wired); push built ready-to-fire (§7).

## 2. Architecture overview

Mirrors the shipped estimate-approval loop end to end:

```
Settings (app)                    book.html (GitHub Pages, apex domain)
  │ mint (JWT-authed) ────────────────► customer fills form
  │ token saved in settings blob        │ GET  /api/booking/config?b=<token>
  │ (syncs via normal engine)           │ POST /api/booking/submit
  ▼                                     ▼
Supabase settings row  ◄─lookup─  api/booking/[action].js (Vercel, service role)
                                        │ insert bookingRequests row
                                        │ fire-and-forget: email + push to owner
                                        ▼
Device pullRemote (existing sync) ── applyBookingRequests() converts:
                                     getOrCreateCustomer + lead Job (deterministic id)
                                     marks request converted → syncs back
```

Server writes are confined to inserting rows in one new table. The server never
writes jobs, customers, or settings. All Customer/Job creation happens on-device
through the sanctioned paths (`getOrCreateCustomer`; JOB pipeline untouched —
new jobs are born `lead` exactly like AddJob's). Device owns all conversions,
mirroring `applyEstimateDecisions`.

**Why not server-created jobs/customers:** `Job` has no email/phone fields
(types/models.ts:117), so a direct job insert strands the lead's contact info;
server-side customer creation would fork `upsertCustomerInList`'s normalized-name
dedup into a second implementation. Both rejected in the memo.

## 3. Data model

### 3.1 New synced collection: `bookingRequests`

New type in `types/models.ts`:

```ts
export interface BookingRequest {
  id: string;            // server-minted: bk<epoch-ms>_<6 hex> — unguessable enough for an id, uniqueness is what matters
  status: "new" | "converted";
  name: string;          // required
  phone: string;         // at least one of phone/email non-empty
  email: string;
  address: string;       // optional
  details: string;       // required — "what do you need done"
  preferredTiming: string; // optional free text ("weekday mornings", "ASAP")
  createdAt: string;     // ISO timestamp, server clock
  convertedJobId?: string;      // stamped by the device converter
  convertedCustomerId?: string; // stamped by the device converter
}
```

Client storage follows the §7 "add a NEW collection" recipe in
tradeready-storage-and-sync exactly: key in `keys.ts`, `[]` default,
`loadBookingRequests`/`saveBookingRequests` in `collections.ts` (setItem →
`enqueueCollectionChanges` → `trySync`), table name appended to
`COLLECTION_TABLES` in `utils/sync.ts` (pull + cross-user wipe are then
automatic), `clearAllUserData` picks the key up via `Object.values(KEYS)`.
`clearSampleData` does NOT clear it (requests are never sample data).

Supabase migration `supabase/migrations/20260804_booking_requests.sql`: table
`"bookingRequests"` (camelCase-quoted, matching the 2026-08-03 durability
tables) with the standard blob shape `(id text pk, user_id uuid, data jsonb,
updated_at timestamptz, deleted boolean default false)` + the standard
owner-scoped RLS ALL policy `auth.uid() = user_id` (architecture-contract §8
floor). The service role bypasses RLS for inserts; the device reads its own
rows through pull with its user JWT.

### 3.2 Settings additions (optional fields — no migration needed)

```ts
bookingLink?: { token: string; enabled: boolean };
pushToken?: { token: string; platform: "ios" | "android"; updatedAt: string };
```

Both live in the synced settings blob and are **device-written only**. The
server only reads them (token lookup; push send). Absent means: no booking
link minted / no push target. Neither is a SECURE_FIELD: the booking token is
public-by-design (it's in the shared URL), and an Expo push token is not a
secret credential.

Known accepted risk (same LWW class as existing settings fields): a stale
device's settings save can clobber `bookingLink`/`pushToken` minted on another
device. Solo-operator app; accepted, documented in README limitations.

### 3.3 Job / Customer

**No shape changes.** Converted jobs use existing fields only:
`title: "Quote request"`, `description: request.details`, `address:
request.address`, `notes: "Preferred timing: <preferredTiming>\nCame in via
booking link <date>"` (timing line omitted when empty), `status: "lead"`,
schedule fields null, and pricing fields exactly as AddJob initializes a new
job (estimateTotal 0, empty materials, rates from the same settings-derived
defaults — parity with AddJob is the requirement, verified in the plan phase).
The lead job id is **deterministic**: `jbk_<request.id>` — so if the converter crashes between
saving the job and marking the request converted, the rerun regenerates the
same id and the pull/save merge-by-id absorbs it. No duplicate leads, no flags
(same idempotence philosophy as the recurring engines' ruleId+occurrenceNumber
dedupe guard).

**Residual risk (final review 2026-08-04):** the deterministic `jbk_<request.id>`
job id protects JOBS from cross-device double-conversion, but customer ids are
time-based, not deterministic — two devices converting the same request
concurrently can each create a Customer record for the same person. The
existing duplicate-customer detection/merge flow surfaces the pair for the
owner to resolve. Accepted for a solo-operator app.

## 4. Backend

One new Vercel function — `api/booking/[action].js`, a dispatcher identical in
shape to `api/estimate/[action].js` — takes the deployment **10 → 11 of 12**
functions (verified count 2026-08-04; memory's "9" predated receipt-extract).
Handlers live in `backend/lib/booking/`:

| Action | Auth | Purpose |
|---|---|---|
| `mint` | JWT (Supabase session), rate-limited per user | Returns `{ token }` from `crypto.randomBytes(24).toString('hex')`. **Stateless** — writes nothing; the device saves the token into settings and normal sync publishes it. (Device has no secure RNG; create-link precedent.) |
| `config` | Public, token-gated, IP rate-limited | `GET ?b=<token>` → `{ businessName }` and nothing else. Resolves the token via the settings table; 404 `{error: "This link is invalid."}` when unknown/disabled (no oracle distinguishing the two). |
| `submit` | Public, token-gated, IP rate-limited | `POST { b, name, phone, email, address, details, preferredTiming, website }` → validates (§6), inserts the bookingRequests row with service role, fire-and-forget alerts (§5), returns `{ ok: true }`. |

Token → user resolution: PostgREST JSON-path filter on the settings table,
`data->bookingLink->>token=eq.<t>` with `data->bookingLink->>enabled=eq.true`,
`select=user_id,data`. One row per user, tiny table — no index needed at
current scale. Token comparison is by-lookup (the filter), not in code, so no
constant-time concern; the token is a 48-hex-char capability.

Shared plumbing reused, not duplicated: `applyCors` from `lib/estimate/cors.js`
(same allowlist — the page lives on the same origins), `createRateLimiter` from
`lib/guards.js`, service-role fetch headers pattern from `lib/estimateStore.js`
(booking gets its own `lib/booking/store.js` for settings-lookup + insert; it
does not touch estimateStore).

**Rollback note:** if the deploy ever needs reverting, the dispatcher is one
file — deleting `api/booking/` returns the count to 10 and nothing else
references it.

## 5. Alerts (email now, push when credentials exist)

Fired from `submit` after a successful insert, both fire-and-forget with
`console.error` logging — **an alert failure never fails the submission**.

- **Email** — `lib/booking/notifyOwner.js`. Recipient: the owner's auth email,
  fetched via the service-role admin endpoint
  (`GET /auth/v1/admin/users/<user_id>`). Sender/transport: Resend REST,
  exactly the pattern of `lib/reminderEmail.js` (reuses `RESEND_API_KEY`; no
  new env vars). Content: name, contact, address, details, preferred timing,
  "Open TradeReady to see the new lead in Jobs."
- **Push** — if `settings.pushToken` exists, POST to
  `https://exp.host/--/api/v2/push/send` with
  `{ to, title: "New quote request", body: "<name> — <details, truncated>", data: { type: "booking_request" } }`.
  Plain fetch, no SDK, no receipt handling in v1.

## 6. Security & abuse posture

- **Capability URL**: submitting requires the 48-hex token; there is no
  enumerate-users surface. `config` leaks only the business name.
- **Rate limiting**: `createRateLimiter` per IP on `config`/`submit` (same
  in-memory, per-instance, best-effort limiter as estimate view/respond — its
  known per-lambda-instance limitation is accepted there and here).
- **Honeypot**: hidden `website` field; non-empty → return `{ ok: true }` and
  drop silently (don't teach the bot).
- **Input hygiene**: server-side trims + length caps (name 100, phone 50,
  email 200, address 300, details 2000, preferredTiming 200); name and details
  required; at least one of phone/email required; everything stored as plain
  text. Rendering safety is the client's job: the app renders via RN `Text`
  (inert), `book.html` uses the `esc()` pattern from `estimate.html`.
- **Disable/rotate**: Settings toggle flips `enabled:false` (link 404s on next
  lookup); re-mint replaces the token, instantly killing the old link.
  Both are plain settings saves.
- **RLS**: new table ships with the standard owner-scoped policy (§3.1) —
  the architecture-contract §8 floor for any new table.
- **CORS**: allowlist via the existing `applyCors`; deploy the backend BEFORE
  publishing `book.html` (the ordering lesson from the domain move).

## 7. Push-notification pipeline (owner-added scope)

First use case: booking requests. Built now, degrades gracefully until
credentials/entitlement are live.

**Device (JS-only, OTA-eligible):** `utils/pushToken.ts` —
`registerPushToken()` called from the session effect in App.tsx (beside
`applyEstimateDecisions`) and on foreground:
1. Skip silently if notification permission isn't granted (the existing local
   reminders flow owns the permission prompt; we never double-prompt).
2. `getExpoPushTokenAsync({ projectId })` (projectId already in app.json extra).
   Any failure (Expo Go, missing entitlement, no network) → silent no-op.
3. If the token differs from `settings.pushToken.token`, save via
   `saveSettings` (only-on-change, to avoid enqueue churn).

**Notification tap:** a response listener routes `data.type ===
"booking_request"` to the Jobs tab. The plan phase verifies where the existing
notification-response wiring lives (`utils/notifications.ts`) and extends it
rather than adding a second listener.

**Hard constraints (stated honestly):**
- app.json entitlements carry only the widget App Group — **no push
  entitlement is declared**, and EAS credential state (APNs key) is not
  visible from the repo. If build 7 lacks the entitlement, current installs
  no-op on registration and push lights up at the next EAS build (the planned
  1.2.0/build-11 path). Email is the guaranteed v1 alert.
- **Owner checkpoint task:** run `eas credentials` (iOS) and confirm/add the
  APNs push key before expecting push to fire.
- Remote push **cannot be smoke-tested in Expo Go** — TestFlight only.
- Android/FCM: deferred with Android generally.

## 8. App UI

One new Settings section, "Booking link" (below the existing payment/business
sections, standard Settings patterns):
- Disabled state: explainer + **Create my booking link** (calls `mint`, saves
  settings).
- Enabled state: the link (tappable to copy), **Share link** (native share
  sheet), toggle **Accepting requests** (`enabled`), and **Get a new link**
  (re-mint with an Alert warning that the old link stops working).
- Mint requires a session + network; failures surface as a normal Alert.

No new screens. Converted leads appear through every existing lead surface
(Jobs list, Today's lead flows). v1 deliberately adds no other entry points;
a Jobs-empty-state share button is a possible follow-up.

## 9. book.html (tradeready-legal repo)

Static page beside `estimate.html`, same conventions: no framework, `esc()`
for all interpolation, fetch to the backend, friendly error states.
States: loading → form (headed "<businessName> — Request a quote") →
submitted ("Thanks — <businessName> will get back to you") | invalid-link |
network-error. Honeypot field visually hidden. Minimal validation client-side
(required fields, basic email shape); the server is authoritative.
Published only after the backend deploy (§6 CORS ordering).

## 10. Error handling

| Failure | Behavior |
|---|---|
| Invalid/disabled token on config/submit | 404 `{error: "This link is invalid."}` — page shows the invalid-link state |
| Validation failure on submit | 400 with a field-level message; page shows it inline |
| Supabase insert fails | 500; page offers retry; nothing partial persists (single insert) |
| Email/push alert fails | Logged server-side; submission still succeeds |
| Converter crashes mid-run | Deterministic job id + idempotent re-run converge; request stays `new` until fully converted |
| Device offline | Requests arrive at next successful pull; conversion runs after pull in the same pass |
| Mint offline / no session | Alert in Settings; nothing saved |

## 11. Testing strategy

Backend (Jest, node env — pattern of `__tests__/estimateCors.test.js` and
existing endpoint tests):
- Dispatcher routes the three actions; unknown action 404s.
- `submit`: validation matrix (missing name/details/contact, length caps,
  honeypot drop returns ok-but-no-insert), token lookup (valid / unknown /
  disabled), insert row shape, alerts fired on success and skipped on
  validation failure, alert failure doesn't fail the request.
- `mint`: requires JWT; returns 48-hex token; stateless (no writes).
- `notifyOwner`: recipient resolution, Resend payload shape, push skipped
  when no `pushToken`.

Client (Jest + RNTL conventions from tradeready-validation-and-diagnostics):
- `applyBookingRequests` pure core: converts new requests (customer created
  with full contact via the real `upsertCustomerInList`, lead job shape valid,
  deterministic id), idempotence (run twice → no new writes), skips
  `converted`, stamps `convertedJobId`/`convertedCustomerId`, only saves
  collections that changed.
- Storage: bookingRequests load/save enqueue like siblings (mirror the
  durability-work tests).
- `registerPushToken`: permission-gated, only-on-change save, silent no-op on
  getExpoPushTokenAsync throw (mocked).
- Settings UI: mint/share/toggle/re-mint flows with mocked backend.

Gate rule: tsc 0 / all tests / lint 0 before every commit (change-control
Rule 2). Feature branch; owner device smoke before OTA claim.

## 12. Out of scope (v1)

Slot picking & availability publishing · review inbox · customer portal (own
spec, next) · Android FCM · push receipts/retries · payment anything ·
Jobs-empty-state share entry · listing copy ("online booking" may NOT be
claimed until device-smoked; claims discipline per tradeready-launch-readiness).

## 13. Launch chain (owner-gated, in order)

1. Owner: apply `20260804_booking_requests.sql` in Supabase SQL editor.
2. Owner: `eas credentials` — confirm/add APNs push key (push readiness only;
   nothing else blocks on it).
3. Backend deploy (`npx vercel deploy --prod --yes` from `backend/`) —
   **before** the page publishes.
4. Push `book.html` to tradeready-legal `main` (goes live on Pages).
5. Owner device smoke: mint link → submit from a browser → lead appears with
   customer + contact info → email received.
6. OTA the app-side JS with the normal post-1.1.0 release train.
