import Constants from "expo-constants";
import { supabase } from "./supabase";

const GROQ_MODEL = "llama-3.1-8b-instant";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MODEL = "claude-sonnet-4-6";
const ANTHROPIC_VERSION = "2023-06-01";
const MAX_HISTORY = 20;
const BACKEND_URL = Constants.expoConfig?.extra?.backendUrl ?? "";

export interface ChatMessage {
  role: "user" | "assistant";
  text: string;
}

export interface SendGroqMessageParams {
  messages: ChatMessage[];
  systemPrompt?: string;
  apiKey: string;
}

export interface SendClaudeMessageParams {
  messages: ChatMessage[];
  systemPrompt?: string;
  apiKey: string;
}

export async function sendGroqMessage({ messages, systemPrompt, apiKey }: SendGroqMessageParams): Promise<string> {
  if (!apiKey) {
    throw new Error("No AI key set. Add your Groq API key in Settings → AI Assistant.");
  }

  const recent = messages.slice(-MAX_HISTORY);

  const chatMessages: { role: string; content: string }[] = [];
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

  const text: string = data.choices?.[0]?.message?.content || "";
  if (!text) throw new Error("No response from AI");
  return text;
}

export async function sendClaudeMessage({ messages, systemPrompt, apiKey }: SendClaudeMessageParams): Promise<string> {
  if (!apiKey) {
    throw new Error("No AI key set. Add your Anthropic API key in Settings → AI Assistant.");
  }

  const recent = messages.slice(-MAX_HISTORY);
  const body: Record<string, unknown> = {
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

  const text: string = data.content?.map((b: { text?: string }) => b.text || "").join("") || "";
  if (!text) throw new Error("No response from AI");
  return text;
}

export interface SendBackendGroqMessageParams {
  messages: ChatMessage[];
  systemPrompt?: string;
}

export async function sendBackendGroqMessage({ messages, systemPrompt }: SendBackendGroqMessageParams): Promise<string> {
  if (!BACKEND_URL) {
    throw new Error("Backend not configured.");
  }

  const { data: { session } } = await supabase.auth.getSession();
  if (!session?.access_token) {
    throw new Error("Sign in to use the AI assistant.");
  }

  const recent = messages.slice(-MAX_HISTORY);

  const res = await fetch(`${BACKEND_URL}/api/ai-chat`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      messages: recent.map(m => ({ role: m.role, text: m.text })),
      systemPrompt,
    }),
  });

  const data = await res.json();
  if (!res.ok || data.error) {
    throw new Error(data.error || "AI error");
  }

  const text: string = data.text || "";
  if (!text) throw new Error("No response from AI");
  return text;
}

export async function sendOnboardingAI({ prompt }: { prompt: string }): Promise<string> {
  try {
    return await sendBackendGroqMessage({
      messages: [{ role: "user", text: prompt }],
    });
  } catch {
    return "";
  }
}
