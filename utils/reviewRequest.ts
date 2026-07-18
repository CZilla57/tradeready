import AsyncStorage from "@react-native-async-storage/async-storage";
import * as Notifications from "expo-notifications";
import type { Job, Customer, Settings } from "../types/models";

const STORAGE_KEY = "review_requests";

interface ReviewRequestRecord {
  jobId: string;
  customerId: string;
  customerName: string;
  customerPhone: string;
  customerEmail: string;
  scheduledAt: string;
  sentAt: string | null;
}

async function loadRecords(): Promise<ReviewRequestRecord[]> {
  const raw = await AsyncStorage.getItem(STORAGE_KEY);
  return raw ? JSON.parse(raw) : [];
}

async function saveRecords(records: ReviewRequestRecord[]): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(records));
}

// True when the rendered message would be missing its review link: the template
// still references {googleReviewLink} but no link is set. Returns false when the
// user removed the placeholder or hardcoded a URL into the template — in those
// cases there is nothing to guard. The ReviewRequest screen uses this to block
// sending a linkless review ask.
export function reviewMessageMissingLink(
  template: string,
  googleReviewLink: string,
): boolean {
  return template.includes("{googleReviewLink}") && googleReviewLink.trim() === "";
}

export function buildReviewMessage(
  template: string,
  businessName: string,
  customerName: string,
  googleReviewLink: string,
): string
{
  const withNames = template
    .replace(/\{businessName\}/g, businessName)
    .replace(/\{customerName\}/g, customerName);

  // When there's no link, drop the placeholder along with a dangling colon and
  // the blank line it would otherwise leave, so the preview reads cleanly
  // instead of showing an empty hole. (Sending is blocked in this state.)
  if (googleReviewLink.trim() === "") {
    return withNames
      .replace(/:?[ \t]*\n*\{googleReviewLink\}\n*[ \t]*/g, "\n\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  return withNames.replace(/\{googleReviewLink\}/g, googleReviewLink);
}

export async function isReviewRequestPending(jobId: string): Promise<boolean> {
  const records = await loadRecords();
  return records.some((r) => r.jobId === jobId);
}

export async function scheduleReviewRequest(
  job: Job,
  customer: Customer,
  settings: Settings,
): Promise<void> {
  if (!settings.reviewRequestEnabled) return;
  if (!customer.phone && !customer.email) return;

  const already = await isReviewRequestPending(job.id);
  if (already) return;

  const delaySeconds = Math.max(1, (settings.reviewRequestDelayHours || 3)) * 3600;

  await Notifications.scheduleNotificationAsync({
    identifier: `review_${job.id}`,
    content: {
      title: "Time to ask for a review!",
      body: `Send ${customer.name} a review request for "${job.title}".`,
      data: { type: "review_request", jobId: job.id },
    },
    trigger: { seconds: delaySeconds } as Notifications.NotificationTriggerInput,
  });

  const records = await loadRecords();
  records.push({
    jobId: job.id,
    customerId: customer.id,
    customerName: customer.name,
    customerPhone: customer.phone,
    customerEmail: customer.email,
    scheduledAt: new Date().toISOString(),
    sentAt: null,
  });
  await saveRecords(records);
}

export async function markReviewRequestSent(jobId: string): Promise<void> {
  const records = await loadRecords();
  const updated = records.map((r) =>
    r.jobId === jobId ? { ...r, sentAt: new Date().toISOString() } : r,
  );
  await saveRecords(updated);
}

export async function getReviewRequestRecord(
  jobId: string,
): Promise<ReviewRequestRecord | null> {
  const records = await loadRecords();
  return records.find((r) => r.jobId === jobId) ?? null;
}

export async function getPendingReviewRequests(): Promise<ReviewRequestRecord[]> {
  const records = await loadRecords();
  return records.filter((r) => !r.sentAt);
}
