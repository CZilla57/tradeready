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

import { appCors, clientIp } from '../appCors.js';
import { createAccountDeletionService } from '../../lib/accountDeletion.js';

const accountDeletionService = createAccountDeletionService();

export async function deleteAccountHandler(c) {
  appCors(c, 'POST, OPTIONS');

  const result = await accountDeletionService.handle({
    method: c.req.method,
    ip: clientIp(c),
    authorization: c.req.header('authorization'),
    env: c.env,
  });

  if (result.body === null) return c.body(null, result.status);
  return c.json(result.body, result.status);
}
