// Workers port of backend/api/ai-chat.js — proxies Groq chat completions using
// a server-side API key so users without their own key can still use the
// AI Business Advisor.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required bindings: GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY

import { createRateLimiter, validateChatPayload } from '../../lib/guards.js';
import { enforceDailyCap } from '../../lib/aiUsage.js';
import { appCors, jsonBody } from '../appCors.js';

const GROQ_MODEL = 'openai/gpt-oss-20b';

// 20 chat turns per user per minute — far above human usage, low enough to
// stop runaway loops from burning the server-side Groq key.
const allowRequest = createRateLimiter({ limit: 20 });

export async function aiChatHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 204);

  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY } = c.env;
  if (!GROQ_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return c.json({ error: 'Server misconfiguration. Check Vercel environment variables.' }, 500);
  }

  // Authenticate caller via Supabase JWT
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) {
    return c.json({ error: 'Missing or invalid authorization header.' }, 401);
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return c.json({ error: 'Invalid or expired session.' }, 401);
  }

  const user = await userRes.json().catch(() => null);
  const rateKey = (user && user.id) || c.req.header('x-forwarded-for') || 'anonymous';
  if (!allowRequest(rateKey)) {
    return c.json({ error: 'Too many requests. Please wait a minute and try again.' }, 429);
  }

  const { messages, systemPrompt } = (await jsonBody(c)) || {};
  const invalid = validateChatPayload(messages, systemPrompt);
  if (invalid) {
    return c.json({ error: invalid }, 400);
  }

  // Durable per-user daily cap — second layer behind the in-memory limiter
  // (see lib/aiUsage.js). Runs after validation so malformed requests
  // never consume quota; fails open on counter-infrastructure errors.
  if (user && user.id) {
    const cap = await enforceDailyCap(c.env, user.id, 'ai-chat');
    if (!cap.allowed) {
      return c.json({ error: cap.error }, 429);
    }
  }

  const chatMessages = [];
  if (systemPrompt) {
    chatMessages.push({ role: 'system', content: systemPrompt });
  }
  chatMessages.push(
    ...messages.map(m => ({
      role: m.role === 'assistant' ? 'assistant' : 'user',
      content: m.text || m.content || '',
    }))
  );

  try {
    const groqRes = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${GROQ_API_KEY}`,
      },
      body: JSON.stringify({
        model: GROQ_MODEL,
        messages: chatMessages,
        max_tokens: 1024,
        temperature: 0.7,
        // GPT-OSS is a reasoning model: keep the thinking pass cheap and out of
        // `content` so the visible reply isn't truncated or polluted.
        reasoning_effort: 'low',
        reasoning_format: 'hidden',
      }),
    });

    const data = await groqRes.json();
    if (data.error) {
      console.error('[ai-chat] provider error:', data.error.message);
      return c.json({ error: 'AI provider error. Please try again.' }, 502);
    }

    const text = data.choices?.[0]?.message?.content || '';
    if (!text) {
      return c.json({ error: 'No response from AI' }, 502);
    }

    return c.json({ text }, 200);
  } catch {
    return c.json({ error: 'Failed to reach AI provider.' }, 502);
  }
}
