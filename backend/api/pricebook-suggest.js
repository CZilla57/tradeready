// Vercel serverless function — proxies Anthropic pricing suggestions for the
// Pricebook AI Assist feature, using a server-side API key so users without
// their own Anthropic key can still get suggestions.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required Vercel env vars:
//   ANTHROPIC_API_KEY
//   SUPABASE_URL
//   SUPABASE_ANON_KEY

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

const ANTHROPIC_MODEL = "claude-sonnet-4-6";
const ANTHROPIC_VERSION = "2023-06-01";

const ALLOWED_ORIGINS = ["https://tradeready.app"];

module.exports = async function handler(req, res) {
  const origin = req.headers["origin"];
  res.setHeader("Access-Control-Allow-Origin", origin && ALLOWED_ORIGINS.includes(origin) ? origin : "https://tradeready.app");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });

  if (!ANTHROPIC_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(500).json({ error: "Server misconfiguration." });
  }

  const auth = req.headers["authorization"];
  if (!auth || !auth.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid authorization header." });
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return res.status(401).json({ error: "Invalid or expired session." });
  }

  const { serviceName, description, category, materials, laborHours, laborRate, trade, region } = req.body || {};

  if (!serviceName) {
    return res.status(400).json({ error: "serviceName is required." });
  }

  const prompt = buildPricingSuggestionPrompt({ serviceName, description, category, materials, laborHours, laborRate, trade, region });

  try {
    const aiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        max_tokens: 1000,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    const data = await aiRes.json();
    if (data.error) {
      console.error("[pricebook-suggest] provider error:", data.error.message);
      return res.status(502).json({ error: "AI provider error. Please try again." });
    }

    const text = data.content?.map((b) => b.text || "").join("") || "";
    if (!text) {
      return res.status(502).json({ error: "No response from AI" });
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return res.status(502).json({ error: "Could not parse AI response" });
    }

    let suggestion;
    try {
      suggestion = JSON.parse(jsonMatch[0]);
    } catch {
      return res.status(502).json({ error: "Could not parse AI response" });
    }
    return res.status(200).json(suggestion);
  } catch {
    return res.status(502).json({ error: "Failed to reach AI provider." });
  }
};

function buildPricingSuggestionPrompt({ serviceName, description, category, materials, laborHours, laborRate, trade, region }) {
  const materialsList = (materials || [])
    .map((m) => `  - ${m.name}: qty ${m.quantity}, $${m.unitCost} each`)
    .join("\n");

  return `You are a pricing advisor for trade professionals. A ${trade || "general"} contractor${region ? ` in ${region}` : ""} wants pricing guidance for a service they're adding to their pricebook.

Service: ${serviceName}
${description ? `Description: ${description}` : ""}
${category ? `Category: ${category}` : ""}
Current labor hours: ${laborHours || "not set"}
Current labor rate: $${laborRate || "not set"}/hr
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
For the overall range: give a realistic low/mid/high that a ${trade || "general"} contractor would charge a residential customer.`;
}
