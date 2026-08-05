// utils/changeOrderLink.ts
// Mints a customer approval link for ONE change order. Sibling of
// estimateApprovalLink.ts (same result contract, same sync-before-mint
// ordering) minus the estimate-specific status stamping: sending a CO link
// never touches job.status or estimateSentAt.

import Constants from "expo-constants";
import { loadJobs, saveJobs } from "./storage";
import { supabase } from "./supabase";
import { syncIfOnline } from "./sync";
import { buildChangeOrderSnapshot } from "./changeOrders";
import type { ApprovalLinkResult } from "./estimateApprovalLink";
import type { ChangeOrder, Customer, Job, Settings } from "../types/models";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

/**
 * Server-mints an approval token into `co.approval`, mirrors the write
 * locally, and returns the customer-facing change.html URL. The job (with
 * the CO already saved on it) must reach Supabase before create-link can
 * find it — hence the explicit syncIfOnline await.
 */
export async function createChangeOrderLink(
  job: Job,
  co: ChangeOrder,
  customer: Customer,
  settings: Settings,
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

    const snapshot = buildChangeOrderSnapshot(co, job, customer, settings);
    await syncIfOnline(userId);

    const res = await fetch(`${BACKEND_URL}/api/estimate/create-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ jobId: job.id, changeOrderId: co.id, snapshot }),
    });
    const out = await res.json();
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }

    // Mirror the server write locally so the section reflects "awaiting"
    // immediately (approval presence is what flips the derived status).
    const linked = (await loadJobs()).map((j): Job =>
      j.id === job.id
        ? {
            ...j,
            changeOrders: (j.changeOrders ?? []).map((c) =>
              c.id === co.id ? { ...c, approval: { token: out.token, sentAt: out.sentAt, snapshot } } : c,
            ),
          }
        : j,
    );
    await saveJobs(linked);

    return { ok: true, url: out.url as string, token: out.token as string, sentAt: out.sentAt as string };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
