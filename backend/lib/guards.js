// Shared request guards for the AI proxy endpoints (ai-chat, pricebook-suggest).
//
// Rate limiting is an in-memory sliding window — per serverless instance.
// Vercel may run several instances (each with its own window) and cold starts
// reset counts, so these limits are a cost ceiling per instance, not a hard
// global quota. That is enough to stop runaway client loops and casual
// scripted abuse of the owner's vendor API keys without adding a datastore
// dependency. If real abuse shows up in the logs, upgrade to a shared store.

const DEFAULT_WINDOW_MS = 60 * 1000;
const MAX_TRACKED_KEYS = 1000;

function createRateLimiter({ limit, windowMs = DEFAULT_WINDOW_MS }) {
  const hits = new Map(); // key -> timestamps within the window

  return function allow(key, now = Date.now()) {
    const cutoff = now - windowMs;
    const recent = (hits.get(key) || []).filter((t) => t > cutoff);
    if (recent.length >= limit) {
      hits.set(key, recent);
      return false;
    }
    recent.push(now);
    hits.set(key, recent);

    // Opportunistic cleanup so a long-lived instance doesn't grow unbounded.
    if (hits.size > MAX_TRACKED_KEYS) {
      for (const [k, stamps] of hits) {
        if (stamps.every((t) => t <= cutoff)) hits.delete(k);
      }
    }
    return true;
  };
}

// Input caps for the chat proxy. The client already slices history to 20
// messages (MAX_HISTORY in utils/aiService.ts); the server enforces it so a
// modified client can't send unbounded token bills.
const MAX_MESSAGES = 20;
const MAX_MESSAGE_CHARS = 4000;
const MAX_SYSTEM_PROMPT_CHARS = 8000;

// Returns null when valid, or a client-safe error string.
function validateChatPayload(messages, systemPrompt) {
  if (!Array.isArray(messages) || messages.length === 0) {
    return 'messages array is required.';
  }
  if (messages.length > MAX_MESSAGES) {
    return `Too many messages (max ${MAX_MESSAGES}).`;
  }
  for (const m of messages) {
    const text = (m && (m.text != null ? m.text : m.content)) || '';
    if (typeof text !== 'string' || text.length > MAX_MESSAGE_CHARS) {
      return `Message too long (max ${MAX_MESSAGE_CHARS} characters).`;
    }
  }
  if (systemPrompt != null && (typeof systemPrompt !== 'string' || systemPrompt.length > MAX_SYSTEM_PROMPT_CHARS)) {
    return `System prompt too long (max ${MAX_SYSTEM_PROMPT_CHARS} characters).`;
  }
  return null;
}

// Input caps for the pricebook suggestion proxy.
const MAX_FIELD_CHARS = 1000;
const MAX_MATERIALS = 50;

// Returns null when valid, or a client-safe error string.
function validatePricebookPayload(body) {
  const { serviceName, description, category, materials, trade, region } = body || {};
  if (!serviceName || typeof serviceName !== 'string') {
    return 'serviceName is required.';
  }
  const stringFields = { serviceName, description, category, trade, region };
  for (const [name, value] of Object.entries(stringFields)) {
    if (value != null && (typeof value !== 'string' || value.length > MAX_FIELD_CHARS)) {
      return `${name} too long (max ${MAX_FIELD_CHARS} characters).`;
    }
  }
  if (materials != null) {
    if (!Array.isArray(materials) || materials.length > MAX_MATERIALS) {
      return `materials must be a list of at most ${MAX_MATERIALS} items.`;
    }
    for (const m of materials) {
      const name = m && m.name;
      if (name != null && (typeof name !== 'string' || name.length > MAX_FIELD_CHARS)) {
        return `material name too long (max ${MAX_FIELD_CHARS} characters).`;
      }
    }
  }
  return null;
}

module.exports = {
  createRateLimiter,
  validateChatPayload,
  validatePricebookPayload,
  MAX_MESSAGES,
  MAX_MESSAGE_CHARS,
  MAX_SYSTEM_PROMPT_CHARS,
  MAX_FIELD_CHARS,
  MAX_MATERIALS,
};
