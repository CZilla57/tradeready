// Routing layer for the one-shot generators (estimate document, estimate
// message, outreach message): the user's own Anthropic key when they've set
// one, otherwise the server-side Groq proxy — so keyless subscribers get real
// AI text instead of the static templates. Same layering as pricebookAI.ts
// (route ABOVE the transports; anthropicMessage.ts stays pure-Anthropic) and
// the same contract as generateMessage: NEVER throws, the caller always gets
// a usable string.
//
// Note: the backend endpoint caps output at 600 tokens (backend/api/
// ai-chat.js), so keyless estimate documents run shorter than the 1500-token
// Claude path — still well beyond the template fallback.

import { generateMessage } from "./anthropicMessage";
import { sendBackendGroqMessage } from "./aiService";

interface GenerateOneShotParams {
  prompt: string;
  apiKey?: string;
  max_tokens: number;
  fallback: () => string;
}

export async function generateOneShot({
  prompt,
  apiKey,
  max_tokens,
  fallback,
}: GenerateOneShotParams): Promise<string> {
  if (apiKey) {
    return generateMessage({ prompt, apiKey, max_tokens, fallback });
  }
  try {
    const text = await sendBackendGroqMessage({
      messages: [{ role: "user", text: prompt }],
    });
    return text.trim() ? text : fallback();
  } catch {
    return fallback();
  }
}
