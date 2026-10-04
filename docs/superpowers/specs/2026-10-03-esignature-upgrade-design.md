# E-Signature Upgrade: Consent, Audit Trail and Sealed Copies (Roadmap Phase 19) — Design Spec

**Date:** 2026-10-03
**Status:** SCOPED. Builds on `feat/esign-upgrade`, stacked on the build-order branches before it (#1–#11, ending with `feat/open-api`). Owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user". Code map verified 2026-10-03 against the `feat/quote-expiration` working tree (Phase 32 uncommitted) and the `tradeready-legal` `feat/quote-options` working tree (`estimate.html` uncommitted). Nothing built. **Not legal advice.** Every piece of customer-facing legal wording below is a draft that needs owner approval (§10).
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 19, build order #12. The roadmap frames it as evaluate-first: "does a drawn signature meaningfully add legal or trust value over the typed-name consent already shipped?"
**Builds on:** the estimate approval loop (`2026-07-17-estimate-approval-loop-design.md`), change orders (`2026-08-05-change-orders-design.md`), quote options (digest, conditional write), quote expiration, the approval-preserve trigger
**Build target:** the Worker, `estimate.html` and `change.html` in `CZilla57/tradeready-legal`, and the native SwiftUI app. **No React Native changes.** One migration file, which the owner applies. No new dependencies.

## 0. Preconditions verified

`N/` means `native/TradeReadyNative/`. Legal pages are `tradeready-legal/…`.

**What is captured today**
- **The page.** `estimate.html` asks "Type your full name to approve" and shows an "Approve estimate" button (`tradeready-legal/estimate.html:176-179`, the options variant `:237-240`). The only consent language is a page footer, far from the button: "By approving, you consent to an electronic signature record … being stored" (`:61`). There is no checkbox, no disclosure, and no statement that typing the name is a signature. `change.html` has only "By typing your name you approve this change …" (`tradeready-legal/change.html:41`, form `:104-107`).
- **Once approved, the page shows only a banner.** `render()` returns before drawing the estimate (`estimate.html:153-157`), so the signer can never see or save what they signed. There is no download and no emailed copy.
- **Server.** `respond` requires a non-empty typed name on approve (`backend-workers/src/routes/estimate/respond.js:74-76`). It stamps `consentAt` from the server clock and records `ip` and `userAgent` (`:78-82`), and merges the result with `nextApproval` (`:44-58`). It accepts no consent flag.
- **The digest is never stored.** The snapshot digest is computed on view and compared on respond (`backend-workers/src/routes/estimate/view.js:48`, `respond.js:97-104`, `backend-workers/lib/estimate/quoteOptions.js:117-133`).
- **Change orders share the same merge.** `changeRespond` reuses `nextApproval` (`backend-workers/src/routes/estimate/changeRespond.js:54`).
- **The recorded IP is spoofable.** Both routes take `ip` from `clientIp`, which prefers the first `x-forwarded-for` entry (`backend-workers/src/appCors.js:33-37`; `respond.js:68`, `changeRespond.js:22`). Cloudflare appends to an incoming `X-Forwarded-For`, so a signer can choose that value. `CF-Connecting-IP` is the edge-observed address ([Cloudflare HTTP headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/)).
- **The record lives inside the owner's job blob.** It is `approval.{decision, consentAt, signerName, ip, userAgent, selection}` (`N/Domain/CanonicalModels.swift:672-679`). The approval-preserve trigger freezes these keys and the snapshot once a decision is approved (`supabase/migrations/20261002_job_approval_preserve.sql:23-36,108-116`). It does **not** cover a stale push that carries no approval or an older token (`:86-89`), and deleting the account deletes everything (`tradeready-legal/privacy.html:153`).
- **The snapshot is narrower than the PDF.** It holds business name, customer name, job title, line items, total, options and valid-until (`N/Domain/CanonicalModels.swift:464-600`). The estimate PDF the customer receives also shows the job description and business contact details (`N/NativeEstimatePDF.swift:40-60`). So what is signed is not everything the customer read.
- **The token is a bearer capability**, delivered by the owner through the share sheet. The server never learns the recipient (`2026-07-17-estimate-approval-loop-design.md` line 167).
- **Legal pages today.** Terms §8 describes the typed name, timestamp, IP and user agent, and puts the burden on the owner (`tradeready-legal/terms.html:141-142`). Privacy §1 lists the same fields (`tradeready-legal/privacy.html:114`).
- **The owner app** shows the signer name inside approval history only (`N/JobsView.swift:854-883`). On-site change-order decisions (`manualDecision`) carry no signature (`N/NativeChangeOrders.swift:362-366`).
- **Worker constraints.** The Worker has no PDF library (dependencies are `hono` and `stripe` only, `backend-workers/package.json`). Workers WebCrypto supports Ed25519 and HMAC sign and verify ([Workers Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/)). Resend email with attachments already exists (`backend-workers/lib/invoiceEmail.js:74-80`).

**Law (U.S.; sources fetched 2026-10-03; summaries, not legal advice)**
- **ESIGN §7001(a)** ([15 U.S.C. 7001](https://www.law.cornell.edu/uscode/text/15/7001)): a signature or contract affecting interstate commerce can't be denied legal effect *solely* because it is electronic. §7001(b) leaves every other legal requirement intact.
- **"Electronic signature"** (§7006(5), [15 U.S.C. 7006](https://www.law.cornell.edu/uscode/text/15/7006)): any electronic sound, symbol or process attached to or logically associated with a record and adopted with intent to sign. UETA §2(8) uses the same definition, and NY State Technology Law §302(3) is equivalent. **No technology is privileged.** UETA §2 comment 7 says a typed name or a click can be a signature, and whether a record was signed is a question of fact.
- **Consumer consent (§7001(c))** applies only where a law requires information to be given to a consumer *in writing*. The consumer must first get a clear and conspicuous statement covering:
  - any right to a paper copy, and to withdraw consent, with consequences and fees;
  - the scope of the consent;
  - how to withdraw and how to update contact details;
  - how to get a paper copy and any fee;
  - hardware and software requirements.
- **Electronic consent must "reasonably demonstrate"** that the consumer can access the electronic form used. Contractor deals often fall under such writing laws:
  - The FTC Cooling-Off Rule requires a receipt or contract and a cancellation notice for sales of $25 or more at the buyer's home ([16 CFR 429.0](https://www.law.cornell.edu/cfr/text/16/429.0), [429.1](https://www.law.cornell.edu/cfr/text/16/429.1)).
  - State home-improvement statutes such as [Cal. Bus. & Prof. §7159](https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?lawCode=BPC&sectionNum=7159) and [NY GBL §771](https://www.nysenate.gov/legislation/laws/GBS/771) require a written contract signed by both parties, with specific notices.
- **Retention and accuracy (§7001(d), §7001(e)):** where a law requires a writing or retention, the electronic record must accurately reflect the agreement and be capable of retention and accurate reproduction by everyone entitled to it. Otherwise it can be denied effect.
- **UETA** ([NCCUSL 1999 final act with comments](https://scs.nevada.edu/wp-content/uploads/2020/07/FED_Act99.pdf); [ULC](https://www.uniformlaws.org/committees/community-home?CommunityKey=2c04b76c-2b7d-4399-977e-d5876ba7e034)):
  - §5: electronic dealings are voluntary and inferred from context.
  - §8(c): a record whose sender inhibits printing or storing is not enforceable against the recipient.
  - §9: attribution may be shown "in any manner," including a security procedure.
  - §10: security procedures for detecting changes.
  - §12: retention means accurate and still accessible.
  - Every state except New York has adopted UETA (Washington in 2020, [RCW 1.80](https://app.leg.wa.gov/RCW/default.aspx?cite=1.80); Illinois in 2021). New York uses ESRA ([STT §304](https://www.nysenate.gov/legislation/laws/STT/304)).
- **Proving who signed.**
  - FRE 901 needs evidence that an item is what it claims to be. FRE 902(14) lets a copy self-authenticate by "digital identification," and the committee note names the hash value ([FRE 901](https://www.law.cornell.edu/rules/fre/rule_901), [FRE 902](https://www.law.cornell.edu/rules/fre/rule_902)). **A hash proves integrity, not identity.**
  - California appellate courts have rejected bare e-signature stamps when the business could not explain *how* the signature was placed and attributed:
    - *Ruiz v. Moss Bros.* (2014): typed-signature arbitration agreement.
    - *Fabian v. Renovate America* (2019): DocuSign markers on a residential financing contract, with no audit trail produced.
    - Secondary sources: [AALRR on Ruiz](https://aalrr.com/Labor-Employment-Law-Blog/california-court-of-appeal-refuses-to-enforce-electronically-signed-employment-arbitration-agreement-after-employee-disputes-signature), [CLA on Fabian](https://calawyers.org/business-law/fabian-v-renovate-america-inc-cal-app/). The reporter citations are unverified.

## 1. Assessment and recommendation

**Does a drawn signature add legal value over the typed name? No.** The statutes are technology-neutral. A typed name adopted with intent is a signature. The disputes that go wrong turn on **process evidence**: how the signature was placed, by whom, what the signer agreed to, and whether the record can be reproduced. They don't turn on how the mark looks.

**Does it add trust value? Somewhat.** On a $20k roof, a drawn signature feels more serious to both sides. That is the roadmap's own reading. It is cheap to add with no dependency.

**The real gaps are elsewhere** (§2): no explicit intent statement next to the button, no electronic-records consent, a spoofable IP, no stored digest, a record the owner's own device can wipe, and **no copy for the signer**. That last one is the most serious against §7001(e) and UETA §8(c).

**Recommendation: GO**, scoped as an *evidence* upgrade with a drawn signature as an option:
1. On approval, a sealed, append-only **signature record**: the document as shown, its digest, the consent and intent texts with their hashes, signer data, the event trail, and an Ed25519 seal.
2. Explicit **consent checkbox and disclosure**, plus an **intent statement** adjacent to an "Approve and sign" button.
3. **Typed name stays the legal act.** An **optional drawn signature** is stored as vector strokes and is never required (accessibility, no legal gain).
4. **The signer keeps a copy:** the full signed estimate stays viewable and downloadable as a PDF from the same link, independent of the job, plus an optional emailed copy.
5. **Trusted IP** from `cf-connecting-ip`.
6. **The snapshot gains what the customer actually read:** the job description, the owner's optional agreement terms, and business contact details.
7. All of it applies to estimates and change orders through one module, `backend-workers/lib/esign/`, and is ready for future documents.

The feature name in the product is **"E-signatures with audit trail"**. "Legally binding" is not used anywhere customer- or owner-facing (§7).

## 2. Gap analysis

| Expectation (source) | Today | Gap | Upgrade |
|---|---|---|---|
| Intent to sign (§7006(5); UETA §2(8)) | Typed name and "Approve estimate". Consent sentence in the footer | Nothing says that typing the name is signing | Intent statement directly above the button, which becomes "Approve and sign". The statement text and its hash go into the record |
| Agreement to transact electronically (UETA §5(b)); consumer disclosure where a writing law applies (§7001(c)) | None | No disclosure, no affirmative consent, nothing versioned | Required checkbox with a versioned disclosure (§3.2), shown on the same page and in the same format as the record. Version and hash recorded |
| Signature logically associated with the record (§7006(5)) | Approval keys sit beside `snapshot` in the job blob. Digest not stored | Association depends on a mutable blob | Sealed record binds signer, snapshot and digest in one signed object |
| Attribution (UETA §9; FRE 901) | Bearer link, server time, IP (spoofable), user agent | Weak IP, no view trail | Trusted IP, an event trail (link created by the authenticated owner, each view, consent, sign). Optional email-code verification later (Q8) |
| Change detection (UETA §10; FRE 902(14)) | Snapshot frozen after approval for same-token writes | No digest at rest, no seal, preserve-trigger gaps | SHA-256 document and record digests and an Ed25519 seal. Public verify endpoint and published public key |
| Signer can retain and reproduce (§7001(d)-(e); UETA §8(c), §12) | Approved view is a banner. No copy | **Signer has nothing** | Signed view, PDF download and optional email copy. Record survives job deletion |
| What was signed equals what was read | Snapshot lacks description, terms and contact details | Mismatch with the PDF | Snapshot gains `scope`, `terms` and `businessContact` (digest-covered) |
| Paper-copy and withdrawal path (§7001(c)(1)(B)) | None | — | Disclosure names the business contact. A paper copy is free from the business |

## 3. Design

### 3.1 Signing page (`estimate.html`, `change.html`; shared `esign.js` on `tradeready-legal`)

The pages show the full document as today, including the job description and terms when present. Then comes an **"Agree and sign"** block:
1. **Disclosure checkbox** (required for approve, not for decline): "I agree to use electronic records and signatures for this estimate. *Read the electronic records disclosure*". The link expands the disclosure inline.
2. "Your full name" text field (required).
3. "Draw your signature (optional)": a `<canvas>` pad using vanilla JS pointer events, with a Clear button. It is hidden when the owner turned the pad off (snapshot `signature.drawPad`).
4. "Email me a signed copy (optional)": an email field.
5. **Intent statement**, directly above the button (draft, Q3): "By selecting Approve and sign, you are signing this estimate electronically. Your typed name — and your drawing, if you add one — is your signature."
6. "Approve and sign" and "Decline" buttons.

Before signing, a "Download this estimate (PDF)" link serves the unsigned rendering (§3.6), so the consumer can see that the PDF form opens. Once approved, the page renders the **signed view**: the document, the signature block (name, drawn mark, date and time), the record id and fingerprint, and "Download signed copy (PDF)". It no longer stops at a banner.

Accessibility:
- Every control is labelled. The pad has `aria-describedby` saying it is optional and that the typed name is enough.
- Keyboard and screen-reader users never meet a required drawing step.

### 3.2 Disclosure (versioned text, draft for Q2)

`esignDisclosureV1` is a constant shared by the page and the Worker; the Worker stores its version and SHA-256.

> **Using electronic records and signatures.** {Business} uses TradeReady to send you this estimate electronically. If you agree, you'll sign it electronically and receive your copy electronically.
> - **Paper copy:** you can ask {Business} for a paper copy at no charge — {phone} · {email}.
> - **Your choice:** you don't have to sign electronically. To sign on paper instead, contact {Business}. Withdrawing your agreement later doesn't affect anything you already signed.
> - **Scope:** this agreement covers this estimate and any change orders to this job.
> - **Contact details:** to change the email address for your copies, tell {Business}.
> - **What you need:** a device with a current web browser that can open and save PDF files. You can open this page, so you can view these records; use "Download this estimate (PDF)" to check that you can open and save the PDF.

The disclosure is always shown, not only when a writing law applies. Owners can't reliably know which deals are covered, and the cost is one checkbox.

### 3.3 Signature data

- `typedName`: trimmed, 1–200 characters (the current limit at `respond.js:51`).
- `drawn` is optional: `{w, h, strokes: [[x, y, tMs], …][]}`.
  - Coordinates are normalized to integers on a 600×200 box.
  - Caps: at most 40 strokes and 2,000 points in total, at most 24 KB of JSON. Anything over is rejected with 400 and a message.
  - An empty or single-dot drawing counts as "not drawn". Strokes are vectors, so there is no image storage and no Supabase Storage bucket. That is a simplification of the approval-loop spec's `signatureRef` plan.
- `signerEmail` is optional, format-checked and at most 254 characters. It is used only to send the copy and is kept in the record.
- `signatureMethod` is `typed` or `typed_drawn`.

### 3.4 Snapshot additions (device-built at create-link; additive and digest-covered)

| Field | Source | Notes |
|---|---|---|
| `scope` | The job's `description`, customer-facing, at most 4,000 characters | Already printed on the PDF |
| `terms` | New optional setting `estimateTerms` (Settings ▸ Customer documents), at most 4,000 characters | Also printed on the estimate PDF. The owner's own text; TradeReady supplies none |
| `businessContact` | `{phone, email}` from settings | Needed for the disclosure's paper-copy right |
| `signature` | `{drawPad: Bool}` from the new setting `signatureDrawPad`, default `true` | |
| `esign` | `{version: 1}` | Tells the Worker to require consent |

The Worker validates lengths in `create-link` the same way it validates options and validity. The existing quote-options digest covers the new keys automatically. A legacy snapshot without `esign` keeps today's behavior until the flag `ESIGN_REQUIRE_CONSENT` is on (§8).

### 3.5 Server flow

New `backend-workers/lib/esign/`, made of pure modules plus thin stores:

| Module | Responsibility |
|---|---|
| `record.js` | `buildRecord({…})` returns the canonical record object (below). `recordDigest = sha256(canonicalJson(record))`, reusing `quoteOptions.canonicalJson` |
| `seal.js` | Ed25519 sign and verify over the digest bytes (WebCrypto). Key from secret `ESIGN_SEAL_PRIVATE_KEY` (PKCS8), id from var `ESIGN_SEAL_KEY_ID`. `publicKeys()` for verification |
| `pdf.js` | Deterministic, dependency-free PDF 1.4 writer (§3.6) |
| `validate.js` | Consent, name, drawing, email and size caps |
| `store.js` | Insert-only `signature_records` and `signature_events`, through service-role REST |
| `ip.js` | `edgeClientIp(c)` returns the `cf-connecting-ip` header or `null`, **never** XFF |

**Record (version 1)**
```jsonc
{ "recordVersion": 1, "recordId": "<uuid>", "documentType": "estimate" | "change_order",
  "jobId": "…", "changeOrderId": null, "approvalTokenSha256": "…",
  "document": { /* the snapshot exactly as stored */ }, "documentDigest": "<sha256 canonical snapshot>",
  "selection": { /* resolved tier/add-ons */ } | null,
  "consent": { "version": 1, "textSha256": "…", "acceptedAt": "<ISO>" },
  "intent":  { "text": "<statement shown>", "textSha256": "…" },
  "signer":  { "typedName": "…", "drawn": { … } | null, "email": "…" | null },
  "signatureMethod": "typed" | "typed_drawn",
  "signedAt": "<server ISO>", "ip": "<cf-connecting-ip>" | null, "userAgent": "…",
  "context": "remote_link",
  "events": [ { "type": "link_created", "at": "…" }, { "type": "viewed", "at": "…", "ip": "…" }, … ],
  "renderer": "pdf-v1" }
```

**`respond` (approve) when the snapshot has `esign`:**
1. Validate the payload: `consent.accepted === true`, `consent.version` is a known version, plus name, drawing and email. Return 400 with a message on failure.
2. Run today's checks unchanged: token, digest (409), expiry (410), selection.
3. Write the decision as today with the conditional job write, adding the server-owned keys `signatureRecordId` (pre-minted UUID), `recordDigest` and `signatureMethod`. `ip` becomes `edgeClientIp`. **The decision is authoritative and is written first.**
4. Build, seal and insert the record (unique on `approvalTokenSha256`). If this fails, the response is still 200 with `recordPending: true`, and the next `view` or `copy` call **lazily seals** from the stored approval. Sealing is idempotent by token hash, the portal-token backfill pattern.
5. If an email was given, use `executionCtx.waitUntil` to send the copy (Resend, PDF attached, `from: "{business} via TradeReady"`). Log `copy_emailed` or `copy_email_failed`.
6. Return `{ok, decision, consentAt, selection?, recordId, recordDigest}`.

**Declines** are not signatures. They log a `declined` event and keep today's merge.

**`changeRespond`** takes the same path, with `documentType: "change_order"`.

**New routes**
- `GET /api/esign/copy?j=&t=[&c=]&format=pdf|json` is token-gated, with the same CORS as estimate routes. It resolves through `signature_records` by token hash, so it **works after the job is deleted**. It serves the deterministic PDF, or the canonical record JSON for independent verification, and logs `copy_downloaded`.
- `GET /api/esign/preview?j=&t=` returns the unsigned PDF of the current snapshot (shown before signing).
- `GET /api/esign/verify?r=<recordId>&d=<digest>` is public and rate-limited. It returns `{valid, signedAt, documentType, keyId}` and no names or amounts. `GET /api/esign/public-keys` returns the published Ed25519 public keys by id.
- `POST /api/esign/record` (owner JWT, `appCors`) takes `{jobId, changeOrderId?}` and returns the record JSON and PDF (base64) for the owner app, scoped by `user_id`.

**Events.** `create-link` logs `link_created` with the owner's id as actor. `view` logs `viewed` (the first 20 per token, trusted IP, UA). Both are best-effort inserts and never fail the route, following the `logPortalEvent` precedent.

### 3.6 Signed copy (PDF, no dependency)

`pdf.js` writes a minimal PDF 1.4: Helvetica and Helvetica-Bold (standard fonts, not embedded), WinAnsi text, word-wrap from the embedded Helvetica width table, multi-page, and line operators to draw the signature strokes.

- **Pages:** the document (header, customer, scope, line items or chosen option, totals, terms, valid-until), then a **Signature certificate** page containing:
  - the signer's typed name and drawn mark;
  - signed at (UTC and the owner's time zone when known), IP and user agent;
  - consent version, the event trail, record id;
  - document SHA-256, record SHA-256, seal key id, the Ed25519 seal (base64);
  - "Verify at gettradereadyapp.com/verify".
- **Deterministic:** no wall clock (CreationDate is `signedAt`) and `/ID` is derived from the record digest. **PDF bytes are not stored.** The sealed JSON record is the evidence, and the PDF is a reproducible rendering of it. Each renderer version is frozen by golden-byte tests (`renderer: "pdf-v1"`), so a later layout change ships as `pdf-v2` and never alters old copies.
- Characters outside WinAnsi print as "?" in the PDF only. The exact UTF-8 text stays in the sealed JSON, which the certificate notes.
- This is **not** a PAdES or Adobe-trusted signature: the PDF viewer shows no "signed" ribbon. Verification is through the published key or our verify endpoint (§9).

### 3.7 Owner app (native)

- **Job detail approval card:**
  - "Signed by {name} · {date}", the drawn mark (rendered from strokes with `Path`), and "Signed copy" (fetches `POST /api/esign/record`, then the share sheet).
  - An "Audit trail" disclosure listing events, IP and the fingerprint.
  - It replaces the signer-only row in `EstimateApprovalHistoryRow` (`N/JobsView.swift:854-883`) for v2 records. Legacy approvals show "Typed-name approval (before audit trail)".
- **Change orders:** the same card. Manual on-site decisions are labelled "Recorded by you — not signed by the customer".
- **Settings ▸ Customer documents:**
  - "Signature pad" toggle (`signatureDrawPad`, default on).
  - "Agreement terms" editor (`estimateTerms`), with the helper line "Your own terms. TradeReady doesn't provide legal terms."
  - Both are settings-blob fields (additive, no migration).
- **Canonical:**
  - `EstimateApproval` gains `signatureRecordId`, `recordDigest` and `signatureMethod` as typed optionals.
  - `EstimateApprovalSnapshot` gains `scope`, `terms`, `businessContact`, `signature` and `esign`.
  - `Settings` gains the two fields.
  - The estimate PDF prints `terms`.
- **Account deletion copy** gains: "Signed estimate records are deleted with your account. Save any copies you need first. Your customers keep the copies they downloaded or were emailed."

### 3.8 Retention

- `signature_records` and `signature_events` live for the life of the owner's account. They cascade on `auth.users` delete, which matches the current privacy policy (`tradeready-legal/privacy.html:153`).
- They are independent of job edits, re-sends and soft deletes. The approval-preserve gap (§0) no longer threatens the evidence, because the evidence is no longer in the blob.
- Keeping records after account deletion would need a privacy-policy change (Q6).

## 4. Data model and migration (`supabase/migrations/20261003_esign_records.sql`; the owner applies it)

```sql
create table public.signature_records (
  id                     uuid primary key,
  user_id                uuid not null references auth.users(id) on delete cascade,
  approval_token_sha256  text not null unique,
  job_id                 text not null,
  change_order_id        text,
  document_type          text not null check (document_type in ('estimate','change_order')),
  record                 jsonb not null,          -- canonical record (§3.5)
  record_digest          text not null,           -- sha256 hex of canonicalJson(record)
  seal_alg               text not null default 'Ed25519',
  seal_key_id            text not null,
  seal                   text not null,           -- base64 signature over record_digest bytes
  signed_at              timestamptz not null,
  created_at             timestamptz not null default now()
);
create index signature_records_owner_job on public.signature_records (user_id, job_id);

create table public.signature_events (
  id                    bigint generated always as identity primary key,
  user_id               uuid not null references auth.users(id) on delete cascade,
  approval_token_sha256 text not null,
  event                 text not null,  -- link_created|viewed|declined|signed|copy_emailed|copy_email_failed|copy_downloaded
  ip                    text,
  user_agent            text,
  created_at            timestamptz not null default now()
);
create index signature_events_token on public.signature_events (approval_token_sha256, created_at);
```

- **Immutability.** A `before update` trigger on `signature_records` raises an exception. There is no `before delete` trigger, because one would block the account-deletion cascade. Deletes are possible only for the service role and the cascade: there is no client grant or policy for writes.
- **RLS:** owner `select` on both tables, with no client insert, update or delete.
- **Approval-preserve trigger:** `create or replace function public.preserve_job_approvals()` with `signatureRecordId`, `recordDigest` and `signatureMethod` added to both `server_keys` and `frozen_keys` (`20261002_job_approval_preserve.sql:108-116`). Nothing else changes, and the existing verify script gains cases for them.
- **Verify script:** `supabase/migrations/verify/20261003_esign_records_verify.sql` checks RLS, that an update raises, and that the cascade delete works.

## 5. Interactions

| With | Effect |
|---|---|
| Quote options (Phase 25) | `selection` goes into the record. The digest flow is unchanged |
| Quote expiration (Phase 32) | 410 before any sealing. Expired estimates are never sealed |
| Revise-declined | Archives the declined approval. Declines have no record, so nothing changes |
| Phase 23 API | `estimates` may gain `signatureMethod` and `recordDigest` additively. The record itself, IP and email stay excluded |
| Phase 18 | None |
| Old cached pages | Until `ESIGN_REQUIRE_CONSENT` is on, a v1 page approving a v2 snapshot still works and gets a record with `consent: null`. Once it is on, 400 "Please reload the page". There are no current users, so the window is short by design |

## 6. Testing

- **Worker** (`backend-workers/tests/esign*.test.cjs`, `node --test`):
  - Canonical record bytes and digests from golden fixtures.
  - Ed25519 seal and verify round-trip with a test key, rejecting a tampered record or digest.
  - Validation caps: name, strokes, points, bytes, email, consent version.
  - **PDF golden bytes** for estimate, option estimate and change-order fixtures, including a drawn signature and non-WinAnsi names. Output must be byte-identical across runs.
  - `edgeClientIp` ignores XFF.
- **Routes** (root Jest under `TZ=America/Phoenix`, stubbed fetch):
  - Approve with consent writes the decision, then the record. Without consent: 400 when the flag is on.
  - Record-insert failure gives 200 with `recordPending`, then a lazy seal on the next `view`.
  - Double approve stays on the terminal lock with no second record (unique token hash). Decline logs an event and no record.
  - `copy` works after a job soft-delete. `verify` returns no PII.
  - The email copy is sent only with an email, and a send failure never fails respond.
  - Change orders reach parity.
  - Existing `estimateRespond`, `estimateApprovals` and `estimateSnapshot` tests stay green.
- **SQL:** the preserve-trigger verify gains the three keys, and the new verify script runs.
- **Native** (`run-esign-tests.sh`, registered):
  - Snapshot additions and their length caps.
  - Settings round-trip.
  - Approval decode with and without the new keys.
  - Stroke-to-`Path` scaling.
  - Audit-trail view model ordering.
  - Labels for legacy and manual decisions.
  - Estimate PDF prints terms.
- **Pages:** manual check on iOS Safari and desktop. Approve with and without a drawing, decline, keyboard-only signing, VoiceOver labels, the signed view, PDF download. Plus a static check that the intent statement immediately precedes the button.
- **Gates:** `sh native/run-all-domain-tests.sh`, the Release compile, `cd backend-workers && npm test`, the targeted Jest under `TZ=America/Phoenix`, and `sh native/run-doc-reference-check.sh`.

## 7. What we can and cannot claim

**Can say** (exact wording needs owner approval, Q5):
- "Customers sign with their typed name, and can add a drawn signature, after agreeing to use electronic records."
- "Each signature comes with a time-stamped audit trail and a tamper-evident certificate."
- "Your customer gets a signed PDF copy."
- A cited statement of law, for example: "Under the U.S. ESIGN Act, a signature or contract can't be denied legal effect solely because it's electronic." Pair it with the disclaimer: "TradeReady isn't a law firm and this isn't legal advice. Whether a signed estimate is an enforceable contract depends on its terms and on the law where you work. Some agreements, such as certain home-improvement contracts and sales made at a customer's home, have extra requirements like specific notices and cancellation rights."

**Must not say** (anywhere: app, pages, store listing, marketing):
- "legally binding", "enforceable", "court-admissible", "court-proof", "guaranteed"
- "ESIGN/UETA compliant" as a blanket certification
- "meets home-improvement contract requirements" or "satisfies the Cooling-Off Rule"
- "identity verified" (unless Q8 ships, and then only "email verified")
- "notarized", "certified" or "qualified signature"
- "as valid as DocuSign"
- Any claim that the drawn signature is "more legal"

The roadmap title "Legally-binding e-signature" stays an internal planning name only.

## 8. Rollout stages

| Stage | Contents | Gate |
|---|---|---|
| A — buildable now | `lib/esign` (record, seal with a test key, PDF, validate, ip), route changes behind `ESIGN_V2` (default off) and `ESIGN_REQUIRE_CONSENT` (default off), new routes, native display, settings and snapshot additions, page changes on a `tradeready-legal` branch (unpublished), the migration and verify files written, all tests | None. Nothing deployed, nothing published |
| B — approvals | Apply the migration (Q1). Approve the disclosure, intent, terms and privacy wording (Q2–Q4). The owner generates the Ed25519 key and sets `ESIGN_SEAL_PRIVATE_KEY` and `ESIGN_SEAL_KEY_ID` (Q10) | Owner |
| C — ship | Deploy the Worker with `ESIGN_V2` on. Publish the pages and the `verify.html` page with the public key. Turn on `ESIGN_REQUIRE_CONSENT`. Ship native | Owner deploy. Device smoke: sign, download, email, verify, owner copy |
| D — optional | Email-code verification (Q8). In-person "sign on this phone" (Q9). Owner countersignature (a second sealed record chained to the first, for states requiring both signatures) | Separate go-ahead |

Rollback: turn `ESIGN_V2` off. Records already sealed stay valid and downloadable.

## 9. Accepted residuals

- **Attribution is still link possession.** The record proves who held the link, from where and when, not their legal identity. Q8 narrows this.
- **The server can't see delivery.** It doesn't know which phone number or email received the link, because the owner sends it from their own device.
- **Not a PAdES or Adobe-trusted PDF signature.** That would need a PDF-signing library and a CA certificate (dependency plus cost). The sealed record and published key are the integrity mechanism.
- **The seal key is a Worker secret.** If it leaks, old seals still verify, but new forgeries become possible: rotate (new key id) and publish revocation. If it is lost, old seals still verify through the published public key.
- **Records die with the owner's account** (Q6). The signer's copy is the durable one.
- **WinAnsi limits** in PDF text (the exact text stays in the sealed JSON).
- **No legal notices are generated** (Cooling-Off cancellation forms, state-specific contract terms). Those are the owner's responsibility, and the claims list says so.
- **The XFF-first `clientIp`** stays on the non-signature routes (see the Phase 23 spec §12).

## 10. Decisions

**Decided (recommendations; owner may override)**
| # | Decision | Choice |
|---|---|---|
| D1 | Go/no-go | Go, as an evidence upgrade. Drawn signature optional |
| D2 | Legal act | Typed name plus consent plus "Approve and sign". Drawing optional, never required |
| D3 | Drawn storage | Vector strokes in the sealed record, capped. No image storage |
| D4 | Consent | Required checkbox with the versioned disclosure on every v2 signing, not only where a writing law applies |
| D5 | Evidence store | Append-only `signature_records` and `signature_events`, separate from the job blob |
| D6 | Seal | SHA-256 record digest plus an Ed25519 signature (WebCrypto), with published public keys |
| D7 | Signer copy | Signed view and PDF on the link (survives job deletion), plus an optional emailed PDF |
| D8 | PDF | Dependency-free, deterministic renderer, versioned. Bytes regenerated, not stored |
| D9 | IP | `cf-connecting-ip` only, for all signature evidence |
| D10 | Snapshot | Adds scope, owner terms, business contact, pad setting and esign version |
| D11 | Scope | Estimates and change orders share one module. Declines are events, not signatures |
| D12 | Naming | "E-signatures with audit trail". Never "legally binding" |
| D13 | Order of writes | Decision first. Record sealed after, lazily repaired if it fails |

**NEEDS OWNER APPROVAL**
| # | Item | Question | Recommendation |
|---|---|---|---|
| Q1 | Migration `20261003_esign_records.sql` | Apply two new append-only tables and the updated `preserve_job_approvals()` key lists before the Worker deploy? | **Yes.** Additive. The routes keep today's behavior while `ESIGN_V2` is off |
| Q2 | Disclosure text (§3.2) | Approve the electronic-records disclosure as drafted, ideally after one review by a lawyer? | **Yes, with one counsel review.** It is the one text most likely to matter in a dispute |
| Q3 | Intent statement and checkbox copy (§3.1) | Approve "By selecting Approve and sign, you are signing this estimate electronically…" and the checkbox label? | **Yes** |
| Q4 | Terms and privacy | Rewrite `terms.html` §8 (consent disclosure, audit trail, drawn signature, signer copies, the owner's responsibility for contract content and notices) and update the `privacy.html` §1 approval-records bullet (consent version, optional drawn signature, optional signer email, view events with IP, retention)? | **Yes**, published with stage C |
| Q5 | Claims | Adopt the §7 "can say / must not say" lists for app, pages, store listing and marketing? | **Yes.** Rename the feature away from "legally binding" |
| Q6 | Retention after account deletion | Keep deleting signature records with the account (current policy), or retain sealed records for N years as business records (a privacy-policy change)? | **Keep the current policy.** Warn the owner to export first. The signer keeps their own copy |
| Q7 | Emailed copy | Send the signer a copy (PDF attached) through the existing Resend sender when they enter an email? | **Yes.** No new service; covered by Q4's privacy wording |
| Q8 | Email-code verification | Add an optional per-estimate "verify signer by email code" (sent to the customer email on file) for big jobs? | **Later (stage D), off by default.** It is the strongest attribution upgrade, but it adds friction |
| Q9 | In-person signing | Offer "Sign on this phone" (the customer signs on the owner's device at the job), recorded as `context: in_person_owner_device`, with owner-facing copy noting that in-home sales may need a cancellation notice? | **Defer to stage D.** Ship only with counsel-reviewed reminder copy (FTC Cooling-Off Rule) |
| Q10 | Seal key | Generate an Ed25519 key pair, set the private key as a Worker secret, and publish the public key on `verify.html`? | **Yes**, at stage B |
| Q11 | Privacy label | Confirm no App Store privacy-label change. The new data comes from customers on the web pages, not from app users, and the label already declares name, email and user content | **No change**, re-checked at ship |
