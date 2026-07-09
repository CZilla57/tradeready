// utils/pricebookAI.ts
// AI pricing suggestions for the Pricebook. Follows the same client-key /
// backend-fallback split as the rest of the AI layer: if the user has their
// own anthropicKey, call Claude directly via the shared `generateMessage`
// transport; otherwise fall back to the Vercel `pricebook-suggest` endpoint,
// which uses a server-side ANTHROPIC_API_KEY behind Supabase JWT auth.

import { generateMessage } from "./anthropicMessage";
import { supabase } from "./supabase";
import Constants from "expo-constants";
import type { AIPricingSuggestion, Material, Settings } from "../types/models";

const backendUrl = Constants.expoConfig?.extra?.backendUrl;

interface PricebookAIInput {
  serviceName: string;
  description?: string;
  category?: string;
  materials: Material[];
  laborHours: number;
  laborRate: number;
  settings: Settings | null;
}

export async function getAIPricingSuggestion(input: PricebookAIInput): Promise<AIPricingSuggestion | null> {
  const { settings } = input;
  const trade = settings?.trade || "general";
  const region = settings?.region || "";

  if (settings?.anthropicKey) {
    return getFromClientKey(input, trade, region, settings.anthropicKey);
  }

  return getFromBackend(input, trade, region);
}

async function getFromClientKey(
  input: PricebookAIInput,
  trade: string,
  region: string,
  apiKey: string,
): Promise<AIPricingSuggestion | null> {
  const prompt = buildPrompt(input, trade, region);
  const text = await generateMessage({
    prompt,
    apiKey,
    max_tokens: 1000,
    fallback: () => "",
  });

  if (!text) return null;
  try {
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    return jsonMatch ? JSON.parse(jsonMatch[0]) : null;
  } catch {
    return null;
  }
}

async function getFromBackend(
  input: PricebookAIInput,
  trade: string,
  region: string,
): Promise<AIPricingSuggestion | null> {
  if (!backendUrl) return null;

  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData?.session?.access_token;
  if (!token) return null;

  try {
    const res = await fetch(`${backendUrl}/api/pricebook-suggest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        serviceName: input.serviceName,
        description: input.description,
        category: input.category,
        materials: input.materials,
        laborHours: input.laborHours,
        laborRate: input.laborRate,
        trade,
        region,
      }),
    });

    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

function buildPrompt(input: PricebookAIInput, trade: string, region: string): string {
  const materialsList = input.materials
    .map((m) => `  - ${m.name}: qty ${m.quantity}, $${m.unitCost} each`)
    .join("\n");

  return `You are a pricing advisor for trade professionals. A ${trade} contractor${region ? ` in ${region}` : ""} wants pricing guidance for a service they're adding to their pricebook.

Service: ${input.serviceName}
${input.description ? `Description: ${input.description}` : ""}
${input.category ? `Category: ${input.category}` : ""}
Current labor hours: ${input.laborHours || "not set"}
Current labor rate: $${input.laborRate || "not set"}/hr
${materialsList ? `Current materials:\n${materialsList}` : "No materials listed yet."}

Respond ONLY with a JSON object (no markdown, no explanation outside the JSON) in this exact format:
{
  "laborHours": { "suggested": <number>, "reasoning": "<one sentence>" },
  "laborRate": { "suggested": <number>, "reasoning": "<one sentence>" },
  "materials": [
    { "name": "<material name>", "suggestedUnitCost": <number>, "reasoning": "<one sentence>" }
  ],
  "overallRange": { "low": <number>, "mid": <number>, "high": <number>, "reasoning": "<one sentence>" }
}

For materials: include suggestions for each material listed above (with updated pricing if appropriate), plus any commonly-needed materials the contractor may have forgotten. Base prices on current US market rates${region ? ` for the ${region} area` : ""}.
For labor: base on typical complexity and industry standards for this type of work.
For the overall range: give a realistic low/mid/high that a ${trade} contractor would charge a residential customer.`;
}
