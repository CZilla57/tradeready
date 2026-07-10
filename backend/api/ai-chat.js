// Vercel serverless function — proxies Groq chat completions using a
// server-side API key so users without their own key can still use the
// AI Business Advisor.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required Vercel env vars:
//   GROQ_API_KEY
//   SUPABASE_URL
//   SUPABASE_ANON_KEY

const GROQ_API_KEY = process.env.GROQ_API_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

const GROQ_MODEL = 'llama-3.1-8b-instant';

const ALLOWED_ORIGINS = ['https://tradeready.app'];

module.exports = async function handler(req, res) {
  const origin = req.headers['origin'];
  res.setHeader('Access-Control-Allow-Origin', origin && ALLOWED_ORIGINS.includes(origin) ? origin : 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(204).end();

  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (!GROQ_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration. Check Vercel environment variables.' });
  }

  // Authenticate caller via Supabase JWT
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid authorization header.' });
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return res.status(401).json({ error: 'Invalid or expired session.' });
  }

  const { messages, systemPrompt } = req.body || {};
  if (!Array.isArray(messages) || messages.length === 0) {
    return res.status(400).json({ error: 'messages array is required.' });
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
        max_tokens: 600,
        temperature: 0.7,
      }),
    });

    const data = await groqRes.json();
    if (data.error) {
      console.error('[ai-chat] provider error:', data.error.message);
      return res.status(502).json({ error: 'AI provider error. Please try again.' });
    }

    const text = data.choices?.[0]?.message?.content || '';
    if (!text) {
      return res.status(502).json({ error: 'No response from AI' });
    }

    return res.status(200).json({ text });
  } catch {
    return res.status(502).json({ error: 'Failed to reach AI provider.' });
  }
};
