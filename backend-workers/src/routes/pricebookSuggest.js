// Workers port of backend/api/pricebook-suggest.js — proxies Groq pricing
// suggestions for the Pricebook AI Assist feature, using a server-side API key
// so users without their own Anthropic key can still get suggestions. Groq,
// not Anthropic, because GROQ_API_KEY was already funded and configured
// (ai-chat) while no ANTHROPIC_API_KEY has ever been set — see the
// tradeready-ai-layer skill for the routing rationale. The user's-own-key path
// (utils/pricebookAI.ts, no user key set here) is unaffected and still calls
// Anthropic directly.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required bindings: GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY

import { createRateLimiter, validatePricebookPayload } from '../../lib/guards.js';
import { enforceDailyCap } from '../../lib/aiUsage.js';
import { appCors, jsonBody } from '../appCors.js';

const GROQ_MODEL = 'openai/gpt-oss-20b';

// 10 suggestions per user per minute — pricebook entries are one-shot lookups;
// this caps abuse of the server-side Groq key.
const allowRequest = createRateLimiter({ limit: 10 });

export async function pricebookSuggestHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 204);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { GROQ_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY } = c.env;
  if (!GROQ_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return c.json({ error: 'Server misconfiguration.' }, 500);
  }

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

  const body = await jsonBody(c);
  const invalid = validatePricebookPayload(body);
  if (invalid) {
    return c.json({ error: invalid }, 400);
  }

  // Durable per-user daily cap — second layer behind the in-memory limiter
  // (see lib/aiUsage.js). Runs after validation so malformed requests
  // never consume quota; fails open on counter-infrastructure errors.
  if (user && user.id) {
    const cap = await enforceDailyCap(c.env, user.id, 'pricebook-suggest');
    if (!cap.allowed) {
      return c.json({ error: cap.error }, 429);
    }
  }

  const { serviceName, description, category, materials, laborHours, laborRate, trade, region } = body || {};

  const prompt = buildPricingSuggestionPrompt({ serviceName, description, category, materials, laborHours, laborRate, trade, region });

  try {
    const aiRes = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${GROQ_API_KEY}`,
      },
      body: JSON.stringify({
        model: GROQ_MODEL,
        max_tokens: 1536,
        messages: [{ role: 'user', content: prompt }],
        // GPT-OSS is a reasoning model: minimize thinking tokens and strip them
        // from `content` so the JSON answer isn't truncated or preceded by
        // reasoning text that would confuse the parser below.
        reasoning_effort: 'low',
        reasoning_format: 'hidden',
      }),
    });

    const data = await aiRes.json();
    if (data.error) {
      console.error('[pricebook-suggest] provider error:', data.error.message);
      return c.json({ error: 'AI provider error. Please try again.' }, 502);
    }

    const text = data.choices?.[0]?.message?.content || '';
    if (!text) {
      return c.json({ error: 'No response from AI' }, 502);
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return c.json({ error: 'Could not parse AI response' }, 502);
    }

    let suggestion;
    try {
      suggestion = JSON.parse(jsonMatch[0]);
    } catch {
      return c.json({ error: 'Could not parse AI response' }, 502);
    }
    return c.json(suggestion, 200);
  } catch {
    return c.json({ error: 'Failed to reach AI provider.' }, 502);
  }
}

function buildPricingSuggestionPrompt({ serviceName, description, category, materials, laborHours, laborRate, trade, region }) {
  const materialsList = (materials || [])
    .map((m) => `  - ${m.name}: qty ${m.quantity}, $${m.unitCost} each`)
    .join('\n');

  return `You are a pricing advisor for trade professionals. A ${trade || 'general'} contractor${region ? ` in ${region}` : ''} wants pricing guidance for a service they're adding to their pricebook.

Service: ${serviceName}
${description ? `Description: ${description}` : ''}
${category ? `Category: ${category}` : ''}
Current labor hours: ${laborHours || 'not set'}
Current labor rate: $${laborRate || 'not set'}/hr
${materialsList ? `Current materials:\n${materialsList}` : 'No materials listed yet.'}

Respond ONLY with a JSON object (no markdown, no explanation outside the JSON) in this exact format:
{
  "laborHours": { "suggested": <number>, "reasoning": "<one sentence>" },
  "laborRate": { "suggested": <number>, "reasoning": "<one sentence>" },
  "materials": [
    { "name": "<material name>", "suggestedUnitCost": <number>, "reasoning": "<one sentence>" }
  ],
  "overallRange": { "low": <number>, "mid": <number>, "high": <number>, "reasoning": "<one sentence>" }
}

For materials: include suggestions for each material listed above (with updated pricing if appropriate), plus any commonly-needed materials the contractor may have forgotten. Base prices on current US market rates${region ? ` for the ${region} area` : ''}.
For labor: base on typical complexity and industry standards for this type of work.
For the overall range: give a realistic low/mid/high that a ${trade || 'general'} contractor would charge a residential customer.`;
}
