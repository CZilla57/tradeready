// utils/aiService.js
// AI chatbot — Groq (free, fast) or Claude (stronger business reasoning).
// Groq key: console.groq.com  |  Anthropic key: console.anthropic.com

const GROQ_MODEL = "llama-3.1-8b-instant";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MODEL = "claude-sonnet-4-6";
const ANTHROPIC_VERSION = "2023-06-01";
const MAX_HISTORY = 20; // keep last 20 messages (~10 exchanges)

// messages: [{ role: "user"|"assistant", text: string }]
// systemPrompt: optional string
// apiKey: Groq API key from console.groq.com
export async function sendGroqMessage({ messages, systemPrompt, apiKey }) {
  if (!apiKey) {
    throw new Error("No AI key set. Add your Groq API key in Settings → AI Assistant.");
  }

  const recent = messages.slice(-MAX_HISTORY);

  const chatMessages = [];
  if (systemPrompt) {
    chatMessages.push({ role: "system", content: systemPrompt });
  }
  chatMessages.push(
    ...recent.map(m => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: m.text,
    }))
  );

  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: GROQ_MODEL,
      messages: chatMessages,
      max_tokens: 600,
      temperature: 0.7,
    }),
  });

  const data = await res.json();
  if (data.error) throw new Error(data.error.message || "AI error");

  const text = data.choices?.[0]?.message?.content || "";
  if (!text) throw new Error("No response from AI");
  return text;
}

// messages: [{ role: "user"|"assistant", text: string }]
// systemPrompt: optional string
// apiKey: Anthropic key from console.anthropic.com
export async function sendClaudeMessage({ messages, systemPrompt, apiKey }) {
  if (!apiKey) {
    throw new Error("No AI key set. Add your Anthropic API key in Settings → AI Assistant.");
  }

  const recent = messages.slice(-MAX_HISTORY);
  const body = {
    model: ANTHROPIC_MODEL,
    max_tokens: 600,
    messages: recent.map(m => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: m.text,
    })),
  };
  if (systemPrompt) body.system = systemPrompt;

  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
    },
    body: JSON.stringify(body),
  });

  const data = await res.json();
  if (data.error) {
    const msg = typeof data.error === "string" ? data.error : data.error.message;
    throw new Error(msg || "AI error");
  }

  const text = data.content?.map(b => b.text || "").join("") || "";
  if (!text) throw new Error("No response from AI");
  return text;
}
