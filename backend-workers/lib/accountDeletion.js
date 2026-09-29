// Account-deletion core shared by the Vercel handler and mirrored in the
// Cloudflare Worker bundle. This module intentionally has no vendor runtime
// dependency so its destructive boundary can be exercised with inert fakes.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const RATE_LIMIT = 5;
const WINDOW_MS = 5 * 60_000;

const MISCONFIGURED = {
  error: 'Server misconfiguration: SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY must be set in the server environment.',
};
const DELETION_FAILED = {
  error: 'Failed to delete account. Please try again or contact support.',
};

function response(status, body = null) {
  return { status, body };
}

function parseBearer(authorization) {
  if (typeof authorization !== 'string') return null;
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  return match ? match[1] : null;
}

async function readJson(value) {
  try {
    return await value.json();
  } catch {
    return null;
  }
}

function createAccountDeletionService({
  fetchImpl = (...args) => globalThis.fetch(...args),
  now = () => Date.now(),
  logger = console,
} = {}) {
  const rateLimitMap = new Map();

  function isRateLimited(ip) {
    const current = now();
    const timestamps = (rateLimitMap.get(ip) || []).filter(
      (timestamp) => current - timestamp < WINDOW_MS
    );
    if (timestamps.length >= RATE_LIMIT) {
      rateLimitMap.set(ip, timestamps);
      return true;
    }
    timestamps.push(current);
    rateLimitMap.set(ip, timestamps);
    return false;
  }

  async function purgeUserPhotos(photos, userId) {
    const prefix = `${userId}/`;
    const seenCursors = new Set();
    let cursor;

    try {
      do {
        const listing = await photos.list(cursor ? { prefix, cursor } : { prefix });
        if (!listing || !Array.isArray(listing.objects)) {
          throw new Error('invalid R2 listing');
        }

        const keys = listing.objects
          .map((object) => object?.key)
          .filter((key) => typeof key === 'string' && key.startsWith(prefix));
        if (keys.length > 0) await photos.delete(keys);

        if (!listing.truncated) break;
        if (typeof listing.cursor !== 'string' || !listing.cursor || seenCursors.has(listing.cursor)) {
          throw new Error('invalid R2 cursor');
        }
        seenCursors.add(listing.cursor);
        cursor = listing.cursor;
      } while (cursor);
    } catch {
      // The account is already gone at this point. Orphaned private objects are
      // preferable to reporting failure after the irreversible DB boundary.
      logger.error('delete-account: R2 photo purge failed after account deletion');
    }
  }

  async function handle({ method, ip = 'unknown', authorization, env = {} }) {
    if (method === 'OPTIONS') return response(200);
    if (method !== 'POST') return response(405, { error: 'Method not allowed' });

    if (isRateLimited(ip)) {
      return response(429, { error: 'Too many requests. Please wait a moment.' });
    }

    const {
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      SUPABASE_SERVICE_ROLE_KEY,
      PHOTOS,
    } = env;
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
      return response(500, MISCONFIGURED);
    }

    const userJwt = parseBearer(authorization);
    if (!userJwt) return response(401, { error: 'Unauthorized' });

    const baseURL = SUPABASE_URL.replace(/\/+$/, '');

    try {
      const userResponse = await fetchImpl(`${baseURL}/auth/v1/user`, {
        headers: {
          Authorization: `Bearer ${userJwt}`,
          apikey: SUPABASE_ANON_KEY,
        },
      });
      if (!userResponse.ok) {
        return response(401, { error: 'Invalid or expired session. Please sign in again.' });
      }

      const user = await readJson(userResponse);
      const userId = user?.id;
      if (typeof userId !== 'string' || !UUID_RE.test(userId)) {
        return response(401, { error: 'Unauthorized' });
      }

      // Every current public user-owned table has an ON DELETE CASCADE FK to
      // auth.users. Supabase performs this delete and its cascades in one DB
      // transaction, avoiding partial table-by-table remote deletion.
      const deleteUserResponse = await fetchImpl(
        `${baseURL}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
        {
          method: 'DELETE',
          headers: {
            Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
            apikey: SUPABASE_SERVICE_ROLE_KEY,
          },
        }
      );
      if (!deleteUserResponse.ok) throw new Error('auth user deletion failed');

      // R2 is outside the database transaction. Run it only after the account
      // and relational data are gone, and never turn cleanup residue into an
      // ambiguous failure response after the irreversible boundary.
      if (PHOTOS) await purgeUserPhotos(PHOTOS, userId);

      return response(200, { success: true });
    } catch {
      logger.error('delete-account: request failed before confirmed completion');
      return response(500, DELETION_FAILED);
    }
  }

  return { handle };
}

module.exports = {
  RATE_LIMIT,
  WINDOW_MS,
  createAccountDeletionService,
  parseBearer,
};
