# Reddit Lead Scanner — Design Sketch

Self-hosted replacement for F5Bot + tractionbooster: poll Reddit for ICP pain signals, classify
each hit with an LLM, store the qualified leads, and email a daily digest. Runs as a new
cron-triggered path inside the existing `backend-workers` (Cloudflare Worker), reusing the same
patterns as the payment-reminder sweep.

## Why it works when Claude Code's crawler doesn't

Two independent stages (see `docs/reddit-lead-targeting.md` for the tractionbooster explanation):

1. **Fetch** — our Worker calls Reddit's official OAuth API under *our own* registered app
   credentials. Reddit allows this (100 req/min free tier); it only blocks anonymous AI crawlers.
2. **Classify** — the fetched post text goes to the LLM (Groq `gpt-oss-20b`, already wired) with a
   structured-output prompt. The model never touches Reddit — same split tractionbooster uses.

## Architecture (fits the existing worker)

```
Cloudflare cron  ──►  scheduled() in src/index.js  (new pattern branch)
                              │
                              ▼
                   lib/redditScan.js  runRedditScan(env)
                     ├─ getRedditToken(env)        ← OAuth app-only token (cached)
                     ├─ for each sub: fetch /new + keyword /search
                     ├─ filter created_utc > last_seen  (dedup via Supabase)
                     ├─ classifyPost(env, post)    ← Groq gpt-oss-20b, JSON out
                     └─ insert qualified leads → Supabase table  reddit_leads
                              │
                              ▼
                   Resend digest email (daily)  — reuse lib/sendReminders mail helper
```

Manual HTTP fallback route mirrors `routes/cron.js`: `GET /api/cron/reddit-scan` behind
`CRON_SECRET`, so you can force a run without waiting for the schedule.

## 1. Reddit app registration (one-time owner op)

1. Go to https://www.reddit.com/prefs/apps → "create another app…" → type **script**.
2. Note the **client id** (under the app name) and **secret**.
3. Add secrets to the worker:
   ```bash
   wrangler secret put REDDIT_CLIENT_ID
   wrangler secret put REDDIT_CLIENT_SECRET
   ```
4. Reddit requires a descriptive, unique **User-Agent** or it rate-limits/blocks you hard.
   We hardcode: `web:app.tradeready.leadscanner:v1 (by /u/<your-reddit-username>)`.

App-only OAuth (`client_credentials`) gives ~100 req/min — plenty for polling ~25 subs every
few hours. No user login, no password grant needed for read-only search.

## 2. OAuth token (lib/redditAuth.js)

```js
// Module-scoped cache: app-only tokens last ~24h. Worker isolates are short-lived,
// so this just avoids re-minting within a single scan run.
let cached = { token: null, exp: 0 };

const UA = 'web:app.tradeready.leadscanner:v1 (by /u/YOUR_USERNAME)';

export async function getRedditToken(env) {
  const now = Date.now();
  if (cached.token && now < cached.exp) return cached.token;

  const basic = btoa(`${env.REDDIT_CLIENT_ID}:${env.REDDIT_CLIENT_SECRET}`);
  const res = await fetch('https://www.reddit.com/api/v1/access_token', {
    method: 'POST',
    headers: {
      Authorization: `Basic ${basic}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': UA,
    },
    body: 'grant_type=client_credentials',
  });
  if (!res.ok) throw new Error(`reddit token ${res.status}`);
  const data = await res.json();
  cached = { token: data.access_token, exp: now + (data.expires_in - 60) * 1000 };
  return cached.token;
}

export const REDDIT_UA = UA;
```

## 3. Scan + fetch (lib/redditScan.js)

```js
import { getRedditToken, REDDIT_UA } from './redditAuth.js';
import { classifyPost } from './redditClassify.js';

// Tier 1–2 from docs/reddit-lead-targeting.md. Start narrow; widen once volume is known.
const SUBS = [
  'sweatystartup', 'smallbusiness', 'Contractor', 'HVAC', 'electricians',
  'Plumbing', 'LawnCareBusiness', 'pressurewashing', 'handyman', 'Construction',
];

// High-intent phrases (subset of f5bot-keywords.txt). Site-wide search catches subs
// not in SUBS; per-sub /new catches everything in the core subs.
const KEYWORDS = [
  'jobber too expensive', 'app that works offline', 'underpriced the job',
  'chasing payments', 'quoting on a spreadsheet', 'best app for solo contractor',
];

async function redditGet(env, path) {
  const token = await getRedditToken(env);
  const res = await fetch(`https://oauth.reddit.com${path}`, {
    headers: { Authorization: `Bearer ${token}`, 'User-Agent': REDDIT_UA },
  });
  if (!res.ok) throw new Error(`reddit ${path} → ${res.status}`);
  const json = await res.json();
  return (json.data?.children || []).map(ch => ch.data);
}

export async function runRedditScan(env) {
  const sinceUtc = await getLastSeenUtc(env);       // max(created_utc) from reddit_leads
  const seen = new Set();
  const candidates = [];

  // (a) newest posts per core sub
  for (const sub of SUBS) {
    const posts = await redditGet(env, `/r/${sub}/new?limit=50`);
    for (const p of posts) if (p.created_utc > sinceUtc) pushUnique(p);
    await sleep(1100); // stay under 100 req/min, be a good citizen
  }
  // (b) keyword search site-wide (catches Tier-3 niche subs)
  for (const kw of KEYWORDS) {
    const q = encodeURIComponent(`"${kw}"`);
    const posts = await redditGet(env, `/search?q=${q}&sort=new&limit=25&type=link`);
    for (const p of posts) if (p.created_utc > sinceUtc) pushUnique(p);
    await sleep(1100);
  }

  function pushUnique(p) {
    if (seen.has(p.id)) return;
    seen.add(p.id);
    candidates.push({
      id: p.id, sub: p.subreddit, title: p.title,
      body: (p.selftext || '').slice(0, 1500),
      url: `https://reddit.com${p.permalink}`,
      author: p.author, created_utc: p.created_utc,
    });
  }

  // Classify (LLM). Sequential keeps us off provider rate limits; volume is low.
  const leads = [];
  for (const c of candidates) {
    const verdict = await classifyPost(env, c);
    if (verdict.is_lead && verdict.confidence >= 0.6) {
      leads.push({ ...c, ...verdict });
    }
  }

  await insertLeads(env, leads);            // upsert on id → dedup across runs
  return { scanned: candidates.length, qualified: leads.length };
}
```

`getLastSeenUtc`, `insertLeads`, `pushUnique` dedup, and `sleep` are small helpers — Supabase REST
calls with the service-role key, identical style to `lib/sendReminders.js`.

## 4. Classify (lib/redditClassify.js) — the "Sonnet" step

Reuses the Groq call from `routes/aiChat.js`. Swap to Claude here if you want higher precision
(see note below); the interface is identical.

```js
const MODEL = 'openai/gpt-oss-20b';

const SYSTEM = `You qualify Reddit posts as sales leads for TradeReady, a mobile quoting +
invoicing app for solo tradespeople and small crews ($50k–$200k revenue) who quote on
spreadsheets/paper, underprice jobs, waste 5+ hrs/week on invoicing and chasing payments, and
need offline mobile tools. Return STRICT JSON only.`;

const RUBRIC = `Given a post, decide if the AUTHOR is a plausible ICP voicing one of these pains:
underpricing, spreadsheet/paper quoting, invoicing/payment-chasing time, offline field need, or
shopping for a field-service app. Ignore posts from customers, employees/apprentices, or vendors.
Return: {"is_lead": bool, "confidence": 0..1, "pain": "underpricing|quoting|invoicing|offline|app_shopping|none", "reply_angle": "<one sentence: how TradeReady helps, for a human to adapt>"}`;

export async function classifyPost(env, post) {
  const res = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.GROQ_API_KEY}` },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 300,
      temperature: 0,
      reasoning_effort: 'low',
      reasoning_format: 'hidden',
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: `${RUBRIC}\n\nPOST:\nr/${post.sub} — ${post.title}\n${post.body}` },
      ],
    }),
  });
  const data = await res.json();
  try {
    return JSON.parse(data.choices?.[0]?.message?.content || '{}');
  } catch {
    return { is_lead: false, confidence: 0, pain: 'none', reply_angle: '' };
  }
}
```

## 5. Storage (Supabase table)

```sql
-- backend/sql/reddit_leads.sql
create table if not exists reddit_leads (
  id           text primary key,          -- reddit post id (t3 base36) → dedup
  subreddit    text not null,
  title        text not null,
  url          text not null,
  author       text,
  created_utc  double precision not null,
  pain         text,
  confidence   real,
  reply_angle  text,
  status       text default 'new',        -- new | replied | ignored
  inserted_at  timestamptz default now()
);
create index if not exists reddit_leads_created_idx on reddit_leads (created_utc desc);
```

`insertLeads` upserts on `id` (`Prefer: resolution=merge-duplicates`), so re-scanning the same
window never double-inserts — this is the durable dedup, replacing `last_seen` fragility.

## 6. Notify + wire-up

- **Digest email:** after `runRedditScan`, if `qualified > 0`, send a Resend email (reuse the mail
  helper in `lib/sendReminders.js`) listing each lead: sub, title, link, pain, reply_angle.
  One email/day beats F5Bot's per-hit spam.
- **Cron trigger:** add a pattern to `wrangler.toml` (e.g. `"0 13 * * *"` — daily 13:00 UTC) and a
  branch in `scheduled()` in `src/index.js` that calls `runRedditScan(env)`, matching how the
  `*/15` invoice sweep is dispatched.
- **Manual route:** add `cronRedditScanHandler` to `routes/cron.js` (copy the `CRON_SECRET` guard),
  mount at `GET /api/cron/reddit-scan` in `index.js`.

## Secrets to add

```bash
wrangler secret put REDDIT_CLIENT_ID
wrangler secret put REDDIT_CLIENT_SECRET
# GROQ_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY, CRON_SECRET already set
```

## Groq vs. Claude for the classify step

- **Groq `gpt-oss-20b`** (default): already wired, effectively free at this volume, fast. Fine for
  a binary is-this-a-lead + pain-bucket call. Recommended to start.
- **Claude (Sonnet)** — what tractionbooster markets: higher precision on ambiguous posts and
  noticeably better `reply_angle` drafts. Swap `classifyPost`'s fetch to the Anthropic Messages
  API (`https://api.anthropic.com/v1/messages`, `x-api-key`, `anthropic-version` header). Worth it
  if you later auto-draft full replies rather than just angles. Keep the same JSON contract.

## Guardrails / ToS

- **Reddit API terms** allow read + monitoring under a registered app; **do not** auto-post
  replies from a bot — that violates most subs' rules and Reddit's automation policy. This system
  surfaces leads for a *human* to answer. Keep it read-only.
- Descriptive User-Agent + ≤100 req/min or Reddit blocks the app.
- Respect the same self-promo etiquette in `docs/reddit-reply-templates.md` when you engage.

## Build order

1. Register Reddit app, add secrets.
2. `lib/redditAuth.js` + a throwaway test hitting `/r/sweatystartup/new` — confirm token + fetch.
3. `reddit_leads.sql` migration.
4. `lib/redditClassify.js` — test on 5 pasted posts, tune the rubric.
5. `lib/redditScan.js` — wire fetch → classify → insert.
6. Manual route + `CRON_SECRET` — run end-to-end via curl.
7. Add cron trigger + digest email once precision looks good.
```
