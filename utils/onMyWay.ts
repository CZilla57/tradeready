// utils/onMyWay.ts
// Builds the "I'm on my way" SMS body for the on-my-way deep link
// (tradeready://onmyway/<jobId> — utils/deepLinks.ts), wired from the widget
// button and the Siri "I'm on my way" intent (docs/widget-plan.md Phase 3-4).
// Pure text formatting only — JobDetailScreen owns opening the SMS composer.

import type { Job } from "../types/models";

/**
 * `Hi <first name>, it's <businessName> — I'm on my way to <address> now.
 * See you soon!` First name is the first word of job.customerName. A job
 * with no address on file gets "your place" instead of naming nothing.
 * Trims any double space left behind by an empty businessName/address so
 * the message never reads oddly to the customer.
 */
export function buildOnMyWayMessage(job: Job, businessName: string): string {
  const firstName = job.customerName.trim().split(/\s+/)[0] || job.customerName;
  const destination = job.address && job.address.trim() ? job.address.trim() : "your place";
  const message = `Hi ${firstName}, it's ${businessName} — I'm on my way to ${destination} now. See you soon!`;
  return message.replace(/ {2,}/g, " ");
}
