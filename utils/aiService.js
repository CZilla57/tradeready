// utils/aiService.js
// AI chatbot — uses Groq's free API (Llama 3 model).
// Get a free key at console.groq.com — no billing required.

const GROQ_MODEL = "llama-3.1-8b-instant";
const MAX_HISTORY = 20; // keep last 20 messages (~10 exchanges)

// messages: [{ role: "user"|"assistant", text: string }]
// systemPrompt: optional string
// apiKey: Groq API key from console.groq.com
export async function sendGeminiMessage({ messages, systemPrompt, apiKey }) {
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
