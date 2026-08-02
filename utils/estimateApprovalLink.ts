// utils/estimateApprovalLink.ts
// Mints a customer approval link for a job's estimate.
//
// Lifted out of SendEstimateScreen so the Pricing Calculator's estimate tab can
// offer the same action. That screen is where people actually finish an
// estimate, and until it could mint a link the approval feature was effectively
// unreachable: the calculator's "Email to customer" sent a link-less estimate
// and advanced the job past the only status that exposed the send screen.
//
// Returns a discriminated result rather than firing Alerts, so each caller
// decides how to surface failure (the calculator offers to send without a link;
// the send screen just reports it).

import Constants from "expo-constants";
import { loadJobs, saveJobs } from "./storage";
import { supabase } from "./supabase";
import { syncIfOnline } from "./sync";
import { buildEstimateSnapshot } from "./estimateSnapshot";
import { stampEstimateSent } from "./estimateFollowUps";
import type { Job, Customer, Settings } from "../types/models";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

export type ApprovalLinkResult =
  | { ok: true; url: string; token: string; sentAt: string }
  | { ok: false; reason: "no-backend" | "signed-out" | "server" | "network"; message: string };

/**
 * Server-mints an approval token for `job`, mirrors the write locally, and
 * returns the customer-facing URL.
 *
 * Order matters: the job must exist in Supabase before the backend can attach a
 * token to it, and saveJobs' own sync is fire-and-forget — hence the explicit
 * syncIfOnline await between saving and calling create-link.
 */
export async function createApprovalLink(
  job: Job,
  customer: Customer,
  settings: Settings
): Promise<ApprovalLinkResult> {
  if (!BACKEND_URL) {
    return { ok: false, reason: "no-backend", message: "Approval links need a network connection." };
  }

  try {
    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    const userId = sess.session?.user?.id;
    if (!jwt || !userId) {
      return { ok: false, reason: "signed-out", message: "Please sign in to send an approval link." };
    }

    const snapshot = buildEstimateSnapshot(job, customer, settings);

    const jobs = await loadJobs();
    // Stamped here too: if the fetch below fails, the job is already visibly
    // estimate_sent — it must carry a sent date or it would never nudge.
    await saveJobs(jobs.map((j): Job => (j.id === job.id ? stampEstimateSent(j, new Date()) : j)));
    await syncIfOnline(userId);

    const res = await fetch(`${BACKEND_URL}/api/estimate/create-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ jobId: job.id, snapshot }),
    });
    const out = await res.json();
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }

    // Mirror the server write locally so JobDetail reflects it immediately.
    const linked = (await loadJobs()).map((j): Job =>
      j.id === job.id
        ? { ...stampEstimateSent(j, new Date()), approval: { token: out.token, sentAt: out.sentAt, snapshot } }
        : j
    );
    await saveJobs(linked);

    return { ok: true, url: out.url as string, token: out.token as string, sentAt: out.sentAt as string };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
