// Vercel serverless function — permanently deletes a user account and all data.
//
// SECURITY MODEL:
//   The caller sends their Supabase JWT as "Authorization: Bearer <token>".
//   The server verifies the JWT via Supabase (anon key), extracts the user ID,
//   then uses the service role key to delete all data rows and the auth user.
//   The service role key never leaves this server.
//
// REQUIRED VERCEL ENV VARS:
//   SUPABASE_URL              — e.g. https://xxxx.supabase.co
//   SUPABASE_ANON_KEY         — publishable anon key (for JWT verification)
//   SUPABASE_SERVICE_ROLE_KEY — secret service role key (for admin deletes)

const { createAccountDeletionService } = require('../lib/accountDeletion');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const accountDeletionService = createAccountDeletionService();

module.exports = async function handler(req, res) {
  // Real hosts this project serves — tradeready.app was never ours (dead
  // entry from the original scaffold; see backend/lib/estimate/cors.js for
  // the canonical list rationale).
  const allowedOrigins = [
    'https://estimates.gettradereadyapp.com',
    'https://gettradereadyapp.com',
    'https://www.gettradereadyapp.com',
    'https://czilla57.github.io',
  ];
  const origin = req.headers['origin'];
  res.setHeader(
    'Access-Control-Allow-Origin',
    origin && allowedOrigins.includes(origin) ? origin : 'https://gettradereadyapp.com'
  );
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  const result = await accountDeletionService.handle({
    method: req.method,
    ip,
    authorization: req.headers['authorization'],
    env: { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY },
  });

  if (result.body === null) return res.status(result.status).end();
  return res.status(result.status).json(result.body);
};
