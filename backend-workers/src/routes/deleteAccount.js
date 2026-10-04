// Workers port of backend/api/delete-account.js — permanently deletes a user
// account and all data.
//
// SECURITY MODEL:
//   The caller sends their Supabase JWT as "Authorization: Bearer <token>".
//   The server verifies the JWT via Supabase (anon key), extracts the user ID,
//   then uses the service role key to delete all data rows and the auth user.
//   The service role key never leaves this server.
//
// Required bindings:
//   SUPABASE_URL              — e.g. https://xxxx.supabase.co
//   SUPABASE_ANON_KEY         — publishable anon key (for JWT verification)
//   SUPABASE_SERVICE_ROLE_KEY — secret service role key (for admin deletes)

//
// Phase 24 (spec §4.11): saved autopay cards are detached on the owner's
// connected account, best-effort. The core (lib/accountDeletion.js) stays
// vendor-free and byte-identical with its Vercel twin, so this route does the
// Stripe part around it: before the core runs it reads the owner's live
// enrollments (the rows cascade with the account), and only after the core
// reports success does it detach their cards. A failed or refused deletion
// therefore leaves autopay untouched.

import { appCors, clientIp } from '../appCors.js';
import { createAccountDeletionService } from '../../lib/accountDeletion.js';
import { makeStripe } from '../../lib/stripe/client.js';
import { fetchEnrollmentsForUser } from '../../lib/autopay/store.js';
import { detachCards } from '../../lib/autopay/revoke.js';

const accountDeletionService = createAccountDeletionService();

// The caller's user id when the bearer is valid, else null (the core then
// answers 401 itself). Never throws.
async function peekUserId(env, authorization) {
  try {
    if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) return null;
    const res = await fetch(`${env.SUPABASE_URL.replace(/\/+$/, '')}/auth/v1/user`, {
      headers: { Authorization: authorization, apikey: env.SUPABASE_ANON_KEY },
    });
    if (!res.ok) return null;
    const user = await res.json();
    return user && typeof user.id === 'string' ? user.id : null;
  } catch {
    return null;
  }
}

export function createDeleteAccountHandler({ service = accountDeletionService, stripeFactory = makeStripe } = {}) {
  return async function deleteAccountHandler(c) {
    appCors(c, 'POST, OPTIONS');

    let enrollments = [];
    const authorization = c.req.header('authorization');
    if (c.req.method === 'POST' && c.env.STRIPE_SECRET_KEY && c.env.SUPABASE_SERVICE_ROLE_KEY) {
      const userId = await peekUserId(c.env, authorization);
      if (userId) {
        try {
          enrollments = await fetchEnrollmentsForUser(c.env, userId, { statuses: ['active', 'pending'] });
        } catch (err) {
          console.error('[delete-account] autopay read failed:', err.message);
        }
      }
    }

    const result = await service.handle({
      method: c.req.method,
      ip: clientIp(c),
      authorization,
      env: c.env,
    });

    if (result.status === 200 && enrollments.some((e) => e.payment_method_id)) {
      try {
        await detachCards(stripeFactory(c.env), enrollments);
      } catch (err) {
        console.error('[delete-account] autopay card detach failed:', err.message);
      }
    }

    if (result.body === null) return c.body(null, result.status);
    return c.json(result.body, result.status);
  };
}

export const deleteAccountHandler = createDeleteAccountHandler();
