# Receipt OCR — Design Spec

**Date:** 2026-07-19
**Roadmap item:** Post-launch feature #5 (`docs/post-launch-feature-roadmap.md`)
**Branch:** `feat/receipt-ocr` (off `master` @ `c3c21ee` — deliberately NOT stacked on the
deposits/tax branches; the stack touches none of the files this feature changes)
**Status:** Owner-gated. Built on this branch; merge, backend deploy, legal-site push, and
device smoke are owner actions.

## What it does

When the user attaches a receipt photo to an expense (camera or library, in
`AddExpenseModal`), the app reads the photo and pre-fills the expense form: description
(merchant), amount, date, and suggested category. The user reviews and taps **Save
Expense** exactly as today — extraction never auto-saves, never blocks manual entry, and
never overwrites something the user already typed. If extraction fails for any reason the
form behaves exactly as it does today, plus a one-line "couldn't read it" note.

## Decisions (with rationale)

| # | Decision | Rationale |
|---|---|---|
| D1 | Route extraction **user-anthropicKey → backend proxy → give up (null)**, mirroring `utils/pricebookAI.ts` | This is the documented AI-layer routing rule ("client-key / backend-fallback split"). Zero-setup users get OCR via the proxy; key-owners never touch our backend. |
| D2 | Vision transport = **extend `generateMessage`** with an optional `image` param rather than a new fetch | Architecture contract: "any new Claude-powered one-shot feature calls `generateMessage`. Do not write a new fetch." When `image` is absent the request body is **byte-identical** to today (content stays a plain string), so the three existing call sites are untouched. Never-throws contract unchanged. |
| D3 | Backend endpoint uses the **existing server-side `ANTHROPIC_API_KEY`** (same as `pricebook-suggest.js`), model `claude-sonnet-4-6` (vision-capable) | No new Vercel env var, no new provider, no Groq vision-model verification burden. Mirrors an endpoint that is already live and JWT-authed. |
| D4 | **No new dependencies.** Image sizing relies on the existing picker settings (`quality: 0.7`, `allowsEditing` crop) plus a hard client-side cap; oversized images fail gracefully to manual entry | Rule 3 (owner approval for deps) not triggered. `expo-image-manipulator` resize can be a later enhancement if real-world failure rates warrant it. |
| D5 | Size cap `MAX_RECEIPT_BASE64_CHARS = 5_000_000` (~3.7 MB decoded) enforced on client AND server | Stays under Vercel's 4.5 MB request-body limit and Anthropic's 5 MB image limit with margin. Server enforces independently (modified-client rule, same as chat caps). |
| D6 | **No data-shape change.** `Expense.receiptUri` already exists; extraction output only pre-fills transient form state | Avoids the persisted-migration approval gate entirely. |
| D7 | Pre-fill only **untouched** fields: description if empty, amount if empty, date if the user hasn't picked one this session, category if the user hasn't tapped a chip | "Never clobber user input" — same principle as `upsertCustomerInList` backfilling only blank fields. |
| D8 | Rate limit **5/min per user** on the endpoint | Vision calls are the most expensive proxy calls; receipts are occasional (a user logging a stack of receipts hits ~1 every 12s, still fine). |
| D9 | Privacy policy updated **in the same change** (held branch in `tradeready-legal`) | AI-layer privacy boundary: receipt photos are a new data category leaving the device. Policy must not lag the code. |
| D10 | Analytics: one event `receipt_scanned` with `{ outcome: "filled" \| "empty" \| "failed" \| "too_large", route: "user_key" \| "backend" }` — no PII, no image data | Matches the existing PostHog wrapper pattern; tells us whether the feature earns its keep. |

## Components

### 1. `utils/anthropicMessage.ts` (extend)

```ts
export interface GenerateMessageImage {
  /** Raw base64 (no data: prefix). */
  base64: string;
  mediaType: "image/jpeg" | "image/png";
}
// GenerateMessageOptions gains: image?: GenerateMessageImage
```

When `image` is present, `messages[0].content` becomes
`[{ type: "image", source: { type: "base64", media_type, data } }, { type: "text", text: prompt }]`.
When absent: plain string, exactly as today. Contract (never throws, all failures →
`fallback()`) unchanged.

### 2. `utils/receiptOCR.ts` (new)

```ts
export interface ReceiptExtraction {
  merchant: string | null;   // trimmed, ≤ 80 chars
  amount: number | null;     // total incl. tax, finite, > 0
  date: string | null;       // "YYYY-MM-DD", must be a real calendar date
  category: ExpenseCategoryId | null; // clamped to the 8 known ids
  confidence: "high" | "low";
}
export const MAX_RECEIPT_BASE64_CHARS = 5_000_000;
export function parseReceiptExtraction(text: string): ReceiptExtraction | null;
export function buildReceiptPrompt(): string;
export async function extractReceipt(dataUri: string): Promise<ReceiptExtraction | null>;
```

- `parseReceiptExtraction` is **pure** (the unit-test surface): extracts the first JSON
  object from the text, validates/clamps every field independently (a bad field becomes
  `null`, it doesn't sink the rest), returns `null` only when merchant AND amount AND date
  are all null (nothing useful extracted).
- `extractReceipt` splits the data URI into mediaType + base64, rejects unknown mime types
  and oversize payloads locally (no network), loads settings itself (`loadSettings()` —
  merges SecureStore keys), then routes per D1. **Never throws; `null` = no extraction.**
- Prompt instructs JSON-only output with the exact shape above, describes the 8 category
  ids with the same meanings as `EXPENSE_CATEGORIES` (e.g. `labor` = subcontractors, not
  the user's own time), asks for the receipt **total** (not subtotal), and `confidence:
  "low"` when the image is blurry/partial. `max_tokens: 300`.

### 3. `backend/api/receipt-extract.js` (new) + `backend/lib/guards.js` (extend)

Handler mirrors `pricebook-suggest.js` line-for-line in structure: CORS allowlist, POST
only, env-var check, Supabase JWT → user id, rate limit (`createRateLimiter({ limit: 5 })`),
payload validation, Anthropic call, extract first JSON object, `200` with the parsed object.
Guard additions:

```js
MAX_RECEIPT_IMAGE_CHARS = 5_000_000;
RECEIPT_MEDIA_TYPES = ["image/jpeg", "image/png"];
validateReceiptPayload(body) // → null | error string
//   imageBase64: required string, ≤ cap, plausibly base64 (charset check)
//   mediaType:   required, must be in RECEIPT_MEDIA_TYPES
```

The server does NOT re-validate extraction fields — the client's
`parseReceiptExtraction` is the single validation home (server revalidation would
duplicate the clamp table and drift).

### 4. `components/money/AddExpenseModal.tsx` (extend)

- New state: `scanState: "idle" | "reading" | "filled" | "empty" | "failed"`, plus a
  `touchedRef` (`{ description, amount, date, category }` booleans set by the existing
  input handlers).
- Both attach paths (camera/library) already call `persistPhoto(...)`; after `setReceiptUri`
  they now fire `runReceiptScan(persistedUri)` (not awaited by the UI).
- `runReceiptScan`: `readPhotoAsDataUri(uri)` (existing util) → `extractReceipt(dataUri)`
  → if the modal's current `receiptUri` still equals `uri` (stale guard — user may have
  removed/replaced the photo mid-flight), apply the pre-fill per D7 and set
  `filled`/`empty`/`failed`.
- Banner row under the receipt preview: "Reading receipt…" (with ActivityIndicator) /
  "✨ Filled from receipt — double-check the details" / "Couldn't read the receipt — enter
  the details manually". Low confidence renders the "filled" banner with a "…looks blurry,
  double-check" variant. Banner clears when the photo is removed.
- Save flow, validation, and every existing style/interaction untouched.

### Error handling summary

Every failure mode — no network, no session token, backend 4xx/5xx/429, non-JSON reply,
junk fields, oversize image, unsupported mime — collapses to `null` from `extractReceipt`
(or a discarded stale result), which renders the one-line "failed" note and leaves manual
entry exactly as it is today. There is no code path from extraction to a thrown error, an
Alert, or a blocked save.

## Testing

| Surface | File | Cases |
|---|---|---|
| Parse/clamp (pure) | `__tests__/receiptOCR.test.js` | valid full payload; JSON wrapped in prose; bad category → null category; bad/impossible date → null date; zero/negative/NaN amount → null amount; all-null → null; merchant trimming/cap; confidence default |
| Routing | same file | user key → `generateMessage` called with image + no backend fetch; keyless → backend fetch with JWT + parsed result; backend non-200 → null; no session → null; oversize base64 → null with zero network calls; bad mime → null |
| Transport | `__tests__/anthropicMessage.test.js` (extend) | with `image` → content-blocks shape [image, text]; without `image` → plain-string content (regression pin); never-throws paths unchanged |
| Guards | `__tests__/backendGuards.test.js` (extend) | missing/oversize/non-string imageBase64; bad mediaType; happy path |
| UI | `__tests__/AddExpenseModal.test.js` (new) | attach → prefill of empty fields; user-typed description survives extraction; failed scan → fields untouched + note shown; removing photo clears banner; saved payload carries user-reviewed values |

Existing gate baseline on `master`: 553 tests / 55 suites, tsc 0, lint 0 (re-verified at
branch time, 2026-07-19).

## Out of scope (explicitly)

- Resizing/compressing images beyond the picker's existing `quality: 0.7` (needs a new
  dependency → owner approval; revisit if too-large failures show up in analytics).
- OCR for job photos or invoice attachments.
- Storing extraction output on the Expense record (form pre-fill only).
- Store-listing claims (blocked on device smoke per claims discipline).

## Owner-gated ship steps (none performed by this session)

1. Merge `feat/receipt-ocr` (independent of the deposits/tax stack).
2. Deploy the backend (`backend/`) to Vercel — picks up `receipt-extract.js`. Note the
   deposits branch also carries undeployed backend changes; deploy order follows merge order.
3. Push the `tradeready-legal` privacy-policy branch (receipt-photo AI disclosure).
4. Device smoke test (camera + library attach, keyless route, failure route) — required
   before the feature may be claimed in the store listing.
