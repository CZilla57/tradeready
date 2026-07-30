# Receipt OCR — Implementation Plan

**Spec:** `docs/superpowers/specs/2026-07-19-receipt-ocr-design.md`
**Branch:** `feat/receipt-ocr` (off `master` @ `c3c21ee`)
**Rule:** every phase ends with the full gate green (tsc 0 / all tests / lint 0) and its own commit. No dependency, SDK, or persisted-shape changes anywhere in this plan.

## Phase 1 — Extraction core (client)

1. `utils/anthropicMessage.ts`
   - Add `GenerateMessageImage` interface (`base64`, `mediaType: "image/jpeg" | "image/png"`).
   - `GenerateMessageOptions` gains optional `image?: GenerateMessageImage`.
   - In `generateMessage`, build `content` as blocks `[image, text]` only when `image` is
     present; otherwise keep the plain string exactly as today.
2. `utils/receiptOCR.ts` (new) — see spec §2 for the full contract:
   - `ReceiptExtraction`, `MAX_RECEIPT_BASE64_CHARS`, `buildReceiptPrompt`,
     `parseReceiptExtraction` (pure), `extractReceipt` (routing: local size/mime check →
     user anthropicKey via `generateMessage` → backend `/api/receipt-extract` with Supabase
     JWT → `null`).
   - Category clamp table imported from `EXPENSE_CATEGORIES` ids (single source).
3. Tests: `__tests__/receiptOCR.test.js` (parse + routing, mocked fetch/supabase/Constants),
   `__tests__/anthropicMessage.test.js` additions (blocks shape with image; plain-string
   regression pin without).
4. Gate → commit `feat: receipt extraction core - vision transport and parser`.

## Phase 2 — Backend endpoint

1. `backend/lib/guards.js`: `MAX_RECEIPT_IMAGE_CHARS`, `RECEIPT_MEDIA_TYPES`,
   `validateReceiptPayload` (+ exports).
2. `backend/api/receipt-extract.js`: structural mirror of `pricebook-suggest.js`
   (CORS, POST, env check, JWT auth, 5/min rate limit, validation, Anthropic vision call
   with content blocks, first-JSON-object extraction, 200/4xx/5xx mapping).
3. Tests: extend `__tests__/backendGuards.test.js` for `validateReceiptPayload`.
4. Gate → commit `feat: receipt-extract backend endpoint behind JWT and rate limit`.

## Phase 3 — AddExpenseModal UX

1. `components/money/AddExpenseModal.tsx`: `scanState`, `touchedRef`, `runReceiptScan`
   with stale-uri guard, pre-fill-untouched-fields rule (D7), banner row under the
   receipt preview, banner cleared on photo remove. Reset all of it on modal open
   (existing `visible` effect).
2. `track("receipt_scanned", { outcome, route })` from `extractReceipt`'s caller —
   outcome ∈ filled/empty/failed/too_large; route ∈ user_key/backend (returned alongside
   the extraction or derived; keep analytics out of the pure util — emit from the modal).

   Correction during build if needed: `extractReceipt` returns
   `{ extraction, route } | null`-shaped info only if trivial; otherwise emit
   outcome-only. Decide in-code, keep the event PII-free either way.
3. Test: `__tests__/AddExpenseModal.test.js` (RNTL v14 async conventions; mock
   `expo-image-picker`, `utils/photoStorage`, `utils/receiptOCR`, analytics).
4. Gate → commit `feat: auto-fill expense form from scanned receipt photo`.

## Phase 4 — Docs + privacy

1. `README.md` + `ARCHITECTURE.md` feature-map entries per docs house style
   (describe reality: pre-fill with review, both routes, graceful failure).
2. `tradeready-legal` repo: held branch `feat/receipt-ocr-legal` updating the privacy
   policy — receipt photos the user chooses to scan are sent to the AI provider
   (Anthropic) to extract expense details; not used for training claims stay as-is;
   unscanned photos never leave the device.
3. Gate (app repo) → commit `docs: receipt OCR in feature map and architecture`.

## Final

Full gate, phase report (Confidence / Missing Context / Recommended Next Step), STOP —
merge/deploy/legal-push/device-smoke are owner actions listed in spec §Owner-gated.
