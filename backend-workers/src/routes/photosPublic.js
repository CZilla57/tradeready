// GET /api/photos-public/:photoId?u=<userId>&e=<expiresAtSec>&s=<hmac> —
// anonymous portal photo read (Phase 12B). Auth is the HMAC signature minted
// by portal-view (lib/photoSign.js); every failure — bad params, bad
// signature, expired, missing secret, missing object — is the same
// oracle-free 404 the portal family uses. The owner-JWT /api/photos/:photoId
// route is untouched; this route can never write.

import { createRateLimiter } from '../../lib/guards.js';
import { resolvePublicPhotoKey } from '../../lib/photoSign.js';
import { PHOTO_ID_RE } from '../../lib/photoUpload.js';
import { logPortalEvent } from '../../lib/estimate/portalRequestStore.js';
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
  // Security log (Phase 12D read events) — this route authenticates by HMAC,
  // not portal token, so the prefix column carries the literal marker.
  await logPortalEvent(c.env, { userId: c.req.query('u'), tokenPrefix: 'signedurl', event: 'photo', ip: clientIp(c) });
  return c.body(obj.body, 200, {
    'Content-Type': 'image/jpeg',
    'Cache-Control': 'private, max-age=300',
  });
}
