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
};

// Returns true if the mail composer opened, false if Mail isn't set up.
export async function composeEmail({
  recipients,
  subject,
  body,
}: EmailOptions): Promise<boolean> {
  const available = await MailComposer.isAvailableAsync();
  if (!available) {
    Alert.alert(
      "Mail not available",
      "Please set up the Mail app on this device first."
    );
    return false;
  }
  await MailComposer.composeAsync({ recipients, subject, body });
  return true;
}

type SMSOptions = {
  recipients: string[];
  body: string;
};

// Returns true if the SMS composer opened, false if the device can't text.
export async function composeSMS({
  recipients,
  body,
}: SMSOptions): Promise<boolean> {
  const available = await SMS.isAvailableAsync();
  if (!available) {
    Alert.alert("SMS not available", "This device can't send text messages.");
    return false;
  }
  await SMS.sendSMSAsync(recipients, body);
  return true;
}
