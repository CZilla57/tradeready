// utils/messaging.ts
// Single home for the "is the composer available? → open it, else explain why"
// dance (roadmap #4 — replaces 3 near-identical sendEmail/sendSMS copies across
// OutreachScreen, SendEstimateScreen, PricingCalculatorScreen).
//
// Each function shows the standard "not available" alert itself and returns a
// boolean, so callers can gate their own follow-up side effects (e.g. advancing
// a job to "estimate_sent") on the composer having actually opened.
//
// The caller owns recipient selection — pass the array you want (possibly empty
// when there's no address/number on file, which the native composers accept).

import { Alert } from "react-native";
import * as MailComposer from "expo-mail-composer";
import * as SMS from "expo-sms";

type EmailOptions = {
  recipients: string[];
  subject: string;
  body: string;
  /** File URIs to attach (e.g. an invoice PDF from utils/invoicePdfFile.ts). */
  attachments?: string[];
  /** Treat `body` as HTML (anchor tags render as tappable links). */
  isHtml?: boolean;
};

/**
 * What actually happened in the composer, as far as the platform reports:
 * "notSent" is an explicit user cancel (or an email saved as a draft) —
 * one-shot flows must not consume their shot on it. "unknown" means the
 * platform can't say (Android SMS reports "unknown"; Android mail always
 * claims "sent"); callers treat unknown like "sent" so those platforms keep
 * the old composer-opened behavior.
 */
export type ComposeOutcome = "sent" | "notSent" | "unknown";
export type ComposeResult = { opened: boolean; outcome: ComposeOutcome };

function mapMailStatus(status: string | undefined): ComposeOutcome {
  if (status === "sent") return "sent";
  if (status === "cancelled" || status === "saved") return "notSent";
  return "unknown";
}

// Outcome-reporting variant; composeEmail below keeps the boolean contract.
export async function composeEmailWithOutcome({
  recipients,
  subject,
  body,
  attachments,
  isHtml,
}: EmailOptions): Promise<ComposeResult> {
  const available = await MailComposer.isAvailableAsync();
  if (!available) {
    Alert.alert(
      "Mail not available",
      "Please set up the Mail app on this device first."
    );
    return { opened: false, outcome: "notSent" };
  }
  const result = await MailComposer.composeAsync({
    recipients,
    subject,
    body,
    // Omit the key entirely when there's nothing to attach, so callers that
    // never attach keep their exact previous call shape.
    ...(attachments?.length ? { attachments } : {}),
    // Same omit-when-falsy convention: plain-text callers keep their shape.
    ...(isHtml ? { isHtml } : {}),
  });
  return { opened: true, outcome: mapMailStatus(result?.status) };
}

// Returns true if the mail composer opened, false if Mail isn't set up.
export async function composeEmail(options: EmailOptions): Promise<boolean> {
  return (await composeEmailWithOutcome(options)).opened;
}

type SMSOptions = {
  recipients: string[];
  body: string;
};

function mapSmsResult(result: string | undefined): ComposeOutcome {
  if (result === "sent") return "sent";
  if (result === "cancelled") return "notSent";
  return "unknown";
}

// Outcome-reporting variant; composeSMS below keeps the boolean contract.
export async function composeSMSWithOutcome({
  recipients,
  body,
}: SMSOptions): Promise<ComposeResult> {
  const available = await SMS.isAvailableAsync();
  if (!available) {
    Alert.alert("SMS not available", "This device can't send text messages.");
    return { opened: false, outcome: "notSent" };
  }
  const result = await SMS.sendSMSAsync(recipients, body);
  return { opened: true, outcome: mapSmsResult(result?.result) };
}

// Returns true if the SMS composer opened, false if the device can't text.
export async function composeSMS(options: SMSOptions): Promise<boolean> {
  return (await composeSMSWithOutcome(options)).opened;
}
