# Portal Completion Phase B (customer-visible photos) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner mark individual job photos as customer-visible and serve them on the portal via short-lived HMAC-signed URLs — no signed URL ever persisted, absent flag means hidden.

**Architecture:** One additive optional field on `JobPhoto` (D2, owner-approved). A pure signing module (`lib/photoSign.js`, HMAC-SHA256 over `userId|photoId|expiry`) used twice: portal-view signs at response time, a new anonymous `GET /api/photos-public/:photoId` route verifies and streams from the existing `PHOTOS` R2 bucket. Missing `PORTAL_URL_SIGNING_SECRET` → the photos section is silently empty (fail-soft) and the public route 404s. Owner UI is an eye badge per thumbnail in JobDetail's PhotosCard.

**Tech Stack:** As Phase A, plus `node:crypto` `createHmac` (already used by the Workers runtime — `randomBytes` precedent in booking mint) and the existing `PHOTO_ID_RE` / R2 binding from the photos route.

## Global Constraints

- Spec §6 + decisions D2/D4/D5 (approved). Everything from Phase A's Global Constraints still applies (whitelist discipline, oracle-free 404s, Workers-only, gate green per commit — baseline now 2576 tests / 191 suites).
- `customerVisible` ABSENT MEANS HIDDEN — every read is `=== true`, never truthiness of presence.
- Signed URLs: TTL 900 s, computed per response, never written to any store. Signature = hex HMAC-SHA256 of `` `${userId}|${photoId}|${expiresAtSec}` ``.
- The public route must verify the signature with `constantTimeEqual` BEFORE deriving the R2 key, validate `photoId` against `PHOTO_ID_RE`, and answer 404 `{ error: 'This link is invalid.' }` for every failure (bad params, bad sig, expired, missing object, missing secret).
- The owner-JWT `/api/photos/:photoId` route is untouched.
- Only photos with `uploadedAt` set are ever offered (bytes known to be in R2).

---

### Task 1: `JobPhoto.customerVisible` + storage toggle helper

**Files:**
- Modify: `types/models.ts` (JobPhoto block, after `uploadedAt`)
- Modify: `utils/storage/jobPhotos.ts` (add `setJobPhotoVisibility`)
- Test: extend `__tests__/jobPhotosStorage.test.ts`

**Interfaces:**
- Produces: `setJobPhotoVisibility(photoId: string, visible: boolean): Promise<JobPhoto | null>` — loads, maps, saves through the normal diff-enqueue path; returns the updated record or null when the id is unknown. Consumed by Task 6.

- [ ] Model addition (doc comment carries the fail-closed rule):

```ts
  /**
   * TRUE = the owner explicitly marked this photo visible on the customer
   * portal (Phase 12B). ABSENT MEANS HIDDEN — every consumer checks
   * `=== true`, so old records and new captures are private by default.
   */
  customerVisible?: boolean;
```

- [ ] Helper in `utils/storage/jobPhotos.ts`:

```ts
/**
 * Flip a photo's portal visibility (Phase 12B). Goes through the normal
 * load → map → save path so the change diff-enqueues and syncs like any
 * other record edit. Returns the updated record, or null for an unknown id.
 */
export async function setJobPhotoVisibility(photoId: string, visible: boolean): Promise<JobPhoto | null> {
  const photos = await loadJobPhotos();
  const idx = photos.findIndex((p) => p.id === photoId);
  if (idx === -1) return null;
  const updated: JobPhoto = { ...photos[idx], customerVisible: visible };
  const next = photos.slice();
  next[idx] = updated;
  await saveJobPhotos(next);
  return updated;
}
```

- [ ] Tests (extend the existing suite's conventions — it already mocks AsyncStorage + sync): toggle on persists `customerVisible: true` and enqueues; toggle off persists `false`; unknown id returns null and saves nothing.
- [ ] Gate + commit: `feat(portal): JobPhoto.customerVisible flag + visibility toggle helper`

### Task 2: `lib/photoSign.js` — sign + verify

**Files:**
- Create: `backend-workers/lib/photoSign.js`
- Test: `__tests__/photoSignWorkers.test.js`

**Interfaces:**
- Produces: `photoSignature({ secret, userId, photoId, expiresAtSec }) → hex string`; `verifyPhotoSignature({ secret, userId, photoId, expiresAtSec, sig, nowMs }) → boolean`; `PHOTO_URL_TTL_SEC = 900`. Consumed by Tasks 3 and 5.

```js
// HMAC signing for anonymous portal photo reads (Phase 12B). The signature
// binds userId + photoId + expiry to a server-held secret, so a signed URL
// grants exactly one object for a bounded time and nothing else. Signatures
// are computed per portal-view response and NEVER persisted (spec §6).

const { createHmac } = require('node:crypto');
const { constantTimeEqual } = require('./constantTime.js');

const PHOTO_URL_TTL_SEC = 900; // 15 minutes — one portal page session

function photoSignature({ secret, userId, photoId, expiresAtSec }) {
  return createHmac('sha256', String(secret))
    .update(`${userId}|${photoId}|${expiresAtSec}`)
    .digest('hex');
}

function verifyPhotoSignature({ secret, userId, photoId, expiresAtSec, sig, nowMs }) {
  if (!secret || typeof sig !== 'string') return false;
  const exp = Number(expiresAtSec);
  if (!Number.isFinite(exp) || nowMs / 1000 > exp) return false;
  return constantTimeEqual(photoSignature({ secret, userId, photoId, expiresAtSec }), sig);
}

module.exports = { photoSignature, verifyPhotoSignature, PHOTO_URL_TTL_SEC };
```

- [ ] Test vectors: valid round-trip; tampered photoId / userId / expiry each fail; expired (nowMs past expiry) fails; wrong secret fails; empty/undefined sig fails; missing secret fails.
- [ ] Gate + commit: `feat(portal): HMAC photo URL signing module`

### Task 3: anonymous `GET /api/photos-public/:photoId` route

**Files:**
- Create: `backend-workers/src/routes/photosPublic.js`
- Modify: `backend-workers/src/index.js` (import + route line beside `/api/photos/:photoId`)
- Test: extend `__tests__/photoSignWorkers.test.js` with the decision core

**Interfaces:**
- Consumes: Task 2's verify; `PHOTO_ID_RE` from `backend-workers/lib/photoUpload.js`; `PHOTOS` R2 binding; `clientIp` from `src/appCors.js`.
- Produces: the route Task 5's signed URLs point at. To keep R2 streaming thin, the accept/reject decision lives in `lib/photoSign.js` as `resolvePublicPhotoKey({ env, photoId, query, nowMs }) → { ok: true, key } | { ok: false }`:

```js
const UUID_RE = /^[0-9a-fA-F-]{36}$/;

// Route-level decision for /api/photos-public. Validates shape BEFORE the
// signature check and derives the R2 key ONLY from verified values, so a
// forged or expired URL can never shape a key. Callers answer the same
// oracle-free 404 for every { ok: false }.
function resolvePublicPhotoKey({ secret, photoId, userId, expiresAtSec, sig, nowMs, photoIdRe }) {
  if (!secret) return { ok: false };
  if (typeof userId !== 'string' || !UUID_RE.test(userId)) return { ok: false };
  if (typeof photoId !== 'string' || !photoIdRe.test(photoId)) return { ok: false };
  if (!/^\d{1,12}$/.test(String(expiresAtSec))) return { ok: false };
  if (!verifyPhotoSignature({ secret, userId, photoId, expiresAtSec, sig, nowMs })) return { ok: false };
  return { ok: true, key: `${userId}/${photoId}.jpg` };
}
```

Route handler:

```js
// GET /api/photos-public/:photoId?u=<userId>&e=<expiresAtSec>&s=<hmac> —
// anonymous portal photo read (Phase 12B). Auth is the HMAC signature minted
// by portal-view; every failure (bad params, bad sig, expired, missing
// secret, missing object) is the same oracle-free 404. The owner-JWT
// /api/photos/:photoId route is untouched.

import { createRateLimiter } from '../../lib/guards.js';
import { resolvePublicPhotoKey } from '../../lib/photoSign.js';
import { PHOTO_ID_RE } from '../../lib/photoUpload.js';
import { clientIp } from '../appCors.js';

const allow = createRateLimiter({ limit: 60 });

export async function photosPublicHandler(c) {
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests.' }, 429);
  if (!c.env.PHOTOS) return c.json({ error: 'This link is invalid.' }, 404);

  const out = resolvePublicPhotoKey({
    secret: c.env.PORTAL_URL_SIGNING_SECRET,
    photoId: c.req.param('photoId'),
    userId: c.req.query('u'),
    expiresAtSec: c.req.query('e'),
    sig: c.req.query('s'),
    nowMs: Date.now(),
    photoIdRe: PHOTO_ID_RE,
  });
  if (!out.ok) return c.json({ error: 'This link is invalid.' }, 404);

  const obj = await c.env.PHOTOS.get(out.key);
  if (!obj) return c.json({ error: 'This link is invalid.' }, 404);
  return c.body(obj.body, 200, {
    'Content-Type': 'image/jpeg',
    'Cache-Control': 'private, max-age=300',
  });
}
```

Registration in `src/index.js` after the photos route: `app.all('/api/photos-public/:photoId', photosPublicHandler);`

- [ ] Tests for `resolvePublicPhotoKey`: happy path yields the prefix-derived key; each validation failure (missing secret, bad uuid, bad photo id, bad expiry shape, bad sig) → `{ ok: false }`; key is derived from the SIGNED values only.
- [ ] Gate + commit: `feat(portal): anonymous signed-URL photo route`

### Task 4: portal store — `fetchCustomerJobPhotos`

**Files:**
- Modify: `backend-workers/lib/estimate/portalStore.js`
- Test: extend `__tests__/portalStoreWorkers.test.js`

**Interfaces:**
- Produces: `fetchCustomerJobPhotos(env, userId, jobIds) → Promise<rows>` — empty array without a network call when `jobIds` is empty; caps at 50 ids. Consumed by Task 5's route change.

```js
// Photo metadata for this customer's jobs (Phase 12B) — used to offer
// customer-visible photos on the portal. Scoped by user_id AND an explicit
// job-id list that itself came from the customer-scoped jobs query, so the
// tenant boundary holds transitively. Ids are server-generated
// (p<digits>_<base36>), safe to embed in the in-list.
async function fetchCustomerJobPhotos(env, userId, jobIds) {
  const ids = (Array.isArray(jobIds) ? jobIds : []).slice(0, 50);
  if (!ids.length) return [];
  const list = ids.map((id) => `"${String(id).replace(/[^A-Za-z0-9_-]/g, '')}"`).join(',');
  return get(
    env,
    `jobPhotos?user_id=eq.${encodeURIComponent(userId)}&data->>jobId=in.(${list})&deleted=eq.false&select=id,data`
  );
}
```

- [ ] Tests: URL pins `user_id` + `data->>jobId=in.("j1","j2")` + `deleted=eq.false`; empty jobIds makes zero fetch calls; hostile characters in ids are stripped.
- [ ] Gate + commit: `feat(portal): customer job-photos read in portal store`

### Task 5: assembler `photos` section + route wiring + secret docs

**Files:**
- Modify: `backend-workers/lib/estimate/portalAssemble.js` (add `buildPhotos`, response key)
- Modify: `backend-workers/src/routes/estimate/portalView.js` (fetch photos, pass `userId`/`secret`)
- Modify: `backend-workers/wrangler.toml` (comment documenting the secret)
- Test: extend `__tests__/portalAssembleWorkers.test.js`

**Interfaces:**
- Consumes: Task 2's `photoSignature`/`PHOTO_URL_TTL_SEC`, Task 4's rows.
- `assemblePortalView` gains `photoRows`, `userId`, `photoSecret` params; response gains `photos: [{ jobTitle, url }]`.

`buildPhotos` (in portalAssemble.js):

```js
// Only photos the owner EXPLICITLY marked customer-visible, and only ones
// whose bytes are confirmed in R2 (uploadedAt). Absent flag = hidden — fail
// closed. URLs are signed per response with a 15-minute TTL and never
// persisted (spec §6); no secret configured → the section is empty and the
// portal otherwise works.
function buildPhotos(jobRows, photoRows, { userId, apiOrigin, photoSecret, nowMs }) {
  if (!photoSecret) return [];
  const titleByJobId = new Map(jobRows.map((r) => [r.id, cap(r.data && r.data.title, 200)]));
  const expiresAtSec = Math.floor(nowMs / 1000) + PHOTO_URL_TTL_SEC;
  const out = [];
  for (const r of Array.isArray(photoRows) ? photoRows : []) {
    const d = r && r.data;
    if (!d || d.customerVisible !== true || !d.uploadedAt) continue;
    const sig = photoSignature({ secret: photoSecret, userId, photoId: r.id, expiresAtSec });
    out.push({
      jobTitle: titleByJobId.get(d.jobId) || '',
      url: `${apiOrigin}/api/photos-public/${encodeURIComponent(r.id)}?u=${encodeURIComponent(userId)}&e=${expiresAtSec}&s=${sig}`,
    });
  }
  return out;
}
```

Route change in portalView.js (after the Promise.all; photos read is conditional so a missing secret costs nothing):

```js
  let photoRows = [];
  if (c.env.PORTAL_URL_SIGNING_SECRET) {
    try {
      photoRows = await fetchCustomerJobPhotos(c.env, row.user_id, jobRows.map((r) => r.id));
    } catch (err) {
      console.error('[estimate/portal-view] photos fetch failed:', err.message);
      photoRows = []; // photos are additive — never fail the whole portal for them
    }
  }
```

and the assemble call gains `photoRows`, `userId: row.user_id`, `photoSecret: c.env.PORTAL_URL_SIGNING_SECRET`.

wrangler.toml comment (beside the PHOTOS binding):

```toml
# Phase 12B: portal photo URLs are HMAC-signed with PORTAL_URL_SIGNING_SECRET
# (set via `wrangler secret put PORTAL_URL_SIGNING_SECRET` — never in this
# file). Missing secret = portal photos section stays empty (fail-soft).
```

- [ ] Tests (extend portalAssembleWorkers): top-level keys now include `photos` (seven keys); photo items carry exactly `["jobTitle","url"]`; hidden/absent-flag/un-uploaded photos excluded; URL embeds the signature verifiable by `verifyPhotoSignature` with the same inputs; no secret → `photos: []` and everything else unchanged.
- [ ] Gate + commit: `feat(portal): customer-visible photos in portal-view with signed URLs`

### Task 6: JobDetail per-photo visibility toggle

**Files:**
- Modify: `screens/JobDetailScreen.tsx` (PhotosCard props + eye badge + handler; export PhotosCard for the test)
- Test: `__tests__/jobPhotoVisibilityToggle.test.tsx` (RNTL on the exported PhotosCard)

**Interfaces:**
- Consumes: Task 1's `setJobPhotoVisibility`.
- PhotosCard signature becomes `{ photos, readyIds, onAdd, onDelete, onToggleVisible }`.

- [ ] Badge on each thumb (mirror of the delete circle, bottom-left; eye = visible, eye-off = hidden):

```tsx
              <TouchableOpacity
                style={styles.photoVisibilityBtn}
                onPress={() => onToggleVisible(photo.id)}
                accessibilityRole="button"
                accessibilityLabel={photo.customerVisible === true ? "Visible to customer — tap to hide" : "Hidden from customer — tap to show on portal"}
              >
                <View style={[styles.photoDeleteCircle, photo.customerVisible === true && styles.photoVisibleCircle]}>
                  <Ionicons name={photo.customerVisible === true ? "eye" : "eye-off"} size={13} color="#fff" />
                </View>
              </TouchableOpacity>
```

with styles `photoVisibilityBtn` (absolute, bottom/left 4) and `photoVisibleCircle` (`backgroundColor: colors.success`).

- [ ] Screen handler + wiring:

```tsx
  async function handleTogglePhotoVisibility(photoId: string) {
    const current = jobPhotos.find((p) => p.id === photoId);
    if (!current) return;
    const nextVisible = current.customerVisible !== true;
    setJobPhotos((prev) => prev.map((p) => (p.id === photoId ? { ...p, customerVisible: nextVisible } : p)));
    await setJobPhotoVisibility(photoId, nextVisible);
  }
```

- [ ] RNTL test: renders PhotosCard with one hidden + one visible photo; hidden shows the "Hidden from customer" label; pressing it calls `onToggleVisible` with the photo id; visible photo shows the eye label.
- [ ] Gate + commit: `feat(portal): per-photo customer-visibility toggle in JobDetail`

## Self-review notes

- Spec §6 requirements each map to a task: flag (1), signing (2), delivery (3), read (4), response+fail-soft+secret docs (5), owner UI (6). "Never persist signed URLs" holds — no task writes a URL anywhere.
- Fail-closed audit: `customerVisible !== true` skips (5), absent flag hidden (1), missing secret → empty section (5) and 404 route (3), `uploadedAt` required (5).
- Type consistency: `setJobPhotoVisibility` name matches Tasks 1/6; `photoSignature`/`verifyPhotoSignature`/`PHOTO_URL_TTL_SEC`/`resolvePublicPhotoKey` names match Tasks 2/3/5.
