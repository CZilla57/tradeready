// utils/anthropicMessage.ts
// Single home for the client-side Anthropic Messages API call.
//
// Three screens/util functions used to each carry their own copy of this
// fetch/model/version/error-handling block (the estimate + outreach generators
// in invoiceHelpers, and the inline fetch in PricingCalculatorScreen) — with the
// model id hardcoded in each. That was jobs defect #2 (duplicate estimate
// generators). Extracting the transport here removes the duplication, unifies the
// failure behaviour (no key, API error, or empty response all fall through to the
// caller's `fallback`), and gives one place to change the model.
//
// SECURITY: the anthropic key lives only in expo-secure-store and is passed in by
// the caller; it is sent straight to Anthropic from the device (x-api-key) and
// never touches our own backend. See [[project-ai-and-security-model]].

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MODEL = "claude-sonnet-4-6";
const ANTHROPIC_VERSION = "2023-06-01";

interface AnthropicContentBlock {
  text?: string;
}

interface AnthropicResponse {
  content?: AnthropicContentBlock[];
  error?: { message?: string } | string;
}

export interface GenerateMessageOptions {
  /** The fully-built prompt to send as the single user message. */
  prompt: string;
  /** The user's Anthropic key. Falsy → skip the network call and use `fallback`. */
  apiKey?: string | null;
  max_tokens: number;
  /**
   * Produces the message when there's no key, the API errors, or the response is
   * empty. Deferred (a function) so callers don't pay to build a template unless
   * it's actually needed.
   */
  fallback: () => string;
}

/**
 * Call Claude with a single user prompt and return the text, falling back to
 * `fallback()` on any failure (missing key, transport error, API error, or empty
 * content). Never throws — the caller always gets a usable string.
 */
export async function generateMessage({
  prompt,
  apiKey,
  max_tokens,
  fallback,
}: GenerateMessageOptions): Promise<string> {
  if (!apiKey) return fallback();

  try {
    const res = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        max_tokens,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    const data: AnthropicResponse = await res.json();
    if (data.error) {
      const msg = typeof data.error === "string" ? data.error : data.error.message;
      throw new Error(msg || JSON.stringify(data.error));
    }

    const text = data.content?.map((b) => b.text || "").join("") || "";
    return text || fallback();
  } catch {
    return fallback();
  }
}
