#!/usr/bin/env node
// One-time setup: creates TradeReady's three Sentry alert rules.
// See docs/ops-monthly-checklist.md (Appendix A) for what each rule is for.
//
// Usage, from the tradeready/ folder:
//   1. Create an org auth token at
//      https://tradeready-3r.sentry.io/settings/auth-tokens/
//      with scopes: alerts:write, org:read, project:read, member:read
//   2. PowerShell:  $env:SENTRY_AUTH_TOKEN = "sntrys_..."
//                   node scripts/create-sentry-alerts.mjs
//      Bash:        SENTRY_AUTH_TOKEN="sntrys_..." node scripts/create-sentry-alerts.mjs
//
// Safe to re-run: rules whose names already exist are skipped, not duplicated.
// If the org ever has more than one member, set SENTRY_ALERT_EMAIL to the
// address that should receive the alerts.

const ORG = "tradeready-3r"; // app.json → plugins → @sentry/react-native
const PROJECT = "react-native";
const BASE = `https://us.sentry.io/api/0/organizations/${ORG}`;

// Events per hour that count as "something is breaking at scale".
// Raise this as real usage grows.
const SPIKE_THRESHOLD = 20;

const RULE_NEW = "New error type — notify owner";
const RULE_RETURNED = "Resolved error came back — notify owner";
const RULE_SPIKE = `Error volume spike — >${SPIKE_THRESHOLD} errors/hour`;

const TOKEN = process.env.SENTRY_AUTH_TOKEN;
if (!TOKEN) {
  console.error(
    "SENTRY_AUTH_TOKEN is not set — see the usage comment at the top of this file.",
  );
  process.exit(1);
}

async function api(path, init = {}) {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: res.status, body };
}

function emailAction(userId) {
  return {
    type: "email",
    integrationId: null,
    data: {},
    config: { targetType: "user", targetIdentifier: String(userId), targetDisplay: null },
    status: "active",
  };
}

// Issue-workflow payload (Sentry workflow-engine API, beta as of 2026-07).
function workflowPayload(name, triggerTypes, userId, frequency) {
  return {
    name,
    enabled: true,
    environment: null,
    config: { frequency },
    triggers: {
      logicType: "any-short",
      conditions: triggerTypes.map((type) => ({
        type,
        comparison: true,
        conditionResult: true,
      })),
      actions: [],
    },
    actionFilters: [
      { logicType: "all", conditions: [], actions: [emailAction(userId)] },
    ],
  };
}

// Metric-alert payload (stable alert-rules API). Used for the spike rule
// because the workflow engine's triggers (first seen / regression /
// reappeared / resolved) cannot express "an existing issue is spiking".
function spikePayload(userId) {
  return {
    name: RULE_SPIKE,
    aggregate: "count()",
    dataset: "events",
    eventTypes: ["error"],
    query: "",
    queryType: 0,
    timeWindow: 60,
    thresholdType: 0,
    resolveThreshold: null,
    environment: null,
    projects: [PROJECT],
    owner: null,
    triggers: [
      {
        label: "critical",
        alertThreshold: SPIKE_THRESHOLD,
        actions: [
          { type: "email", targetType: "user", targetIdentifier: String(userId) },
        ],
      },
    ],
  };
}

async function main() {
  // 1. Resolve the notification recipient.
  const members = await api("/members/");
  if (members.status !== 200 || !Array.isArray(members.body)) {
    console.error(`Could not list org members (HTTP ${members.status}):`, members.body);
    console.error("Check the token's scopes (needs member:read / org:read).");
    process.exit(1);
  }
  const wanted = process.env.SENTRY_ALERT_EMAIL;
  const memberEmail = (m) => m.email ?? m.user?.email;
  let member;
  if (wanted) {
    member = members.body.find((m) => memberEmail(m) === wanted);
    if (!member) {
      console.error(`No org member with email ${wanted}. Members:`, members.body.map(memberEmail));
      process.exit(1);
    }
  } else if (members.body.length === 1) {
    member = members.body[0];
  } else {
    console.error(
      "Org has multiple members — set SENTRY_ALERT_EMAIL to pick the recipient. Members:",
      members.body.map(memberEmail),
    );
    process.exit(1);
  }
  const userId = member.user?.id ?? member.id;
  console.log(`Recipient: ${memberEmail(member)} (user id ${userId})`);

  let failures = 0;

  // 2. Issue workflows (skip any that already exist by name).
  const existing = await api("/workflows/");
  const existingNames = new Set(
    (Array.isArray(existing.body) ? existing.body : []).map((w) => w.name),
  );
  const workflows = [
    { name: RULE_NEW, triggers: ["first_seen_event"], frequency: 30 },
    { name: RULE_RETURNED, triggers: ["regression_event", "reappeared_event"], frequency: 60 },
  ];
  for (const wf of workflows) {
    if (existingNames.has(wf.name)) {
      console.log(`SKIP (already exists): ${wf.name}`);
      continue;
    }
    const res = await api("/workflows/", {
      method: "POST",
      body: JSON.stringify(workflowPayload(wf.name, wf.triggers, userId, wf.frequency)),
    });
    if (res.status === 201) {
      console.log(`CREATED: ${wf.name} → https://${ORG}.sentry.io/monitors/alerts/${res.body.id}/`);
    } else {
      failures += 1;
      console.error(`FAILED (HTTP ${res.status}): ${wf.name}`, JSON.stringify(res.body, null, 2));
    }
  }

  // 3. Metric alert for volume spikes (skip if it already exists by name).
  const existingMetric = await api("/alert-rules/");
  const metricNames = new Set(
    (Array.isArray(existingMetric.body) ? existingMetric.body : []).map((r) => r.name),
  );
  if (metricNames.has(RULE_SPIKE)) {
    console.log(`SKIP (already exists): ${RULE_SPIKE}`);
  } else {
    const res = await api("/alert-rules/", {
      method: "POST",
      body: JSON.stringify(spikePayload(userId)),
    });
    if (res.status === 201) {
      console.log(`CREATED: ${RULE_SPIKE} → https://${ORG}.sentry.io/alerts/rules/`);
    } else {
      failures += 1;
      console.error(`FAILED (HTTP ${res.status}): ${RULE_SPIKE}`, JSON.stringify(res.body, null, 2));
    }
  }

  if (failures > 0) {
    console.error(`\n${failures} rule(s) failed — full API responses are above.`);
    process.exit(1);
  }
  console.log(`\nAll rules in place. View them at https://${ORG}.sentry.io/alerts/rules/`);
}

main().catch((err) => {
  console.error("Unexpected error:", err);
  process.exit(1);
});
