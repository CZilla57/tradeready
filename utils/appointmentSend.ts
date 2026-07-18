// utils/appointmentSend.ts
// Renders an appointment template for a job/customer and opens the SMS (preferred)
// or email composer. The only I/O in the appointment feature besides notification
// scheduling. Returns true iff a composer opened.
import { Alert } from "react-native";
import type { Job, Customer, Settings } from "../types/models";
import { composeSMS, composeEmail } from "./messaging";
import {
  renderTemplate,
  resolveChannel,
  formatApptDateTime,
  DEFAULT_CONFIRM_TEMPLATE,
  DEFAULT_ON_MY_WAY_TEMPLATE,
} from "./appointmentMessages";

export async function sendAppointmentMessage(args: {
  job: Job;
  customer: Customer;
  settings: Settings;
  kind: "confirm" | "on_my_way";
}): Promise<boolean> {
  const { job, customer, settings, kind } = args;
  const channel = resolveChannel(customer);
  if (channel === "none") {
    Alert.alert("No contact info", `${customer.name} has no phone or email on file. Add one to send a message.`);
    return false;
  }

  const template =
    kind === "confirm"
      ? settings.appointmentConfirmTemplate?.trim() || DEFAULT_CONFIRM_TEMPLATE
      : settings.onMyWayTemplate?.trim() || DEFAULT_ON_MY_WAY_TEMPLATE;

  const { date, time } = formatApptDateTime(job.scheduledDate ?? "", job.scheduledStartTime);
  const body = renderTemplate(template, {
    customerName: customer.name,
    businessName: settings.businessName || "your contractor",
    date,
    time,
    address: customer.address || job.address || "",
  });

  if (channel === "sms") {
    return composeSMS({ recipients: [customer.phone], body });
  }
  const subject = kind === "confirm" ? "Appointment confirmation" : "On my way";
  return composeEmail({ recipients: [customer.email], subject, body });
}
