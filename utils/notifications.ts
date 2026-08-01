import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';
import type { Invoice, Settings, ReminderRule, Job, Customer, RecurringInvoice } from '../types/models';
import { isFullyPaid } from './invoicePayments';
import { selectAppointmentReminders } from './appointmentMessages';
import { isJobDunningEligible } from './jobStatus';

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: false,
    shouldSetBadge: false,
    shouldShowBanner: true,
    shouldShowList: true,
  }),
});

export async function setupNotifications(): Promise<void> {
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('invoice-reminders', {
      name: 'Invoice Reminders',
      importance: Notifications.AndroidImportance.DEFAULT,
    });
    await Notifications.setNotificationChannelAsync('review-requests', {
      name: 'Review Requests',
      importance: Notifications.AndroidImportance.DEFAULT,
    });
    await Notifications.setNotificationChannelAsync('appointment-reminders', {
      name: 'Appointment Reminders',
      importance: Notifications.AndroidImportance.DEFAULT,
    });
  }
}

export async function requestPermissions(): Promise<boolean> {
  const { status: existing } = await Notifications.getPermissionsAsync();
  if (existing === 'granted') return true;
  if (existing === 'denied') return false;
  const { status } = await Notifications.requestPermissionsAsync();
  return status === 'granted';
}

export async function syncNotifications(): Promise<void> {
  try {
    const { status } = await Notifications.getPermissionsAsync();
    if (status !== 'granted') return;

    const [invoicesRaw, settingsRaw, jobsRaw, customersRaw, recurringInvoicesRaw] = await Promise.all([
      AsyncStorage.getItem('invoices'),
      AsyncStorage.getItem('settings'),
      AsyncStorage.getItem('jobs'),
      AsyncStorage.getItem('customers'),
      AsyncStorage.getItem('recurringInvoices'),
    ]);
    const invoices: Invoice[] = invoicesRaw ? JSON.parse(invoicesRaw) : [];
    const settings: Partial<Settings> = settingsRaw ? JSON.parse(settingsRaw) : {};
    const jobs: Job[] = jobsRaw ? JSON.parse(jobsRaw) : [];
    const customers: Customer[] = customersRaw ? JSON.parse(customersRaw) : [];
    const recurringInvoiceRules: RecurringInvoice[] = recurringInvoicesRaw
      ? JSON.parse(recurringInvoicesRaw)
      : [];
    const rules: ReminderRule[] = settings.rules || [];
    const autoOutreach = !!settings.autoOutreachEnabled;

    await Notifications.cancelAllScheduledNotificationsAsync();

    const jobStatusById = new Map(jobs.map((j) => [j.id, j.status]));
    const unpaid = invoices.filter(
      (inv) =>
        !isFullyPaid(inv) &&
        inv.due &&
        isJobDunningEligible(inv.jobId ? jobStatusById.get(inv.jobId) : undefined)
    );
    const now = new Date();
    let count = 0;

    outer: for (const inv of unpaid) {
      for (const rule of rules) {
        if (count >= 60) break outer;

        const fireDate = new Date(inv.due + 'T00:00:00');
        fireDate.setDate(fireDate.getDate() + rule.days);
        fireDate.setHours(9, 0, 0, 0);

        const secondsUntil = Math.floor((fireDate.getTime() - now.getTime()) / 1000);
        if (secondsUntil <= 0) continue;

        await Notifications.scheduleNotificationAsync({
          identifier: `inv_${inv.id}_${rule.days}d`,
          content: autoOutreach
            ? {
                title: `Follow up with ${inv.customer}`,
                body: `Tap to send a reminder for ${inv.number} — ${rule.days} days past due.`,
                data: { type: 'overdue_outreach', invoiceId: inv.id, daysPastDue: rule.days },
              }
            : {
                title: `Overdue invoice — ${inv.customer}`,
                body: `Invoice ${inv.number} is now ${rule.days} days past due.`,
                data: { invoiceId: inv.id },
              },
          trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
        });
        count++;
      }
    }

    const appointments = selectAppointmentReminders(jobs, customers, {
      appointmentRemindersEnabled: !!settings.appointmentRemindersEnabled,
      appointmentConfirmTemplate: settings.appointmentConfirmTemplate ?? '',
      businessName: settings.businessName ?? '',
    }, now);

    for (const appt of appointments) {
      if (count >= 60) break;
      const secondsUntil = Math.floor((appt.fireDate.getTime() - now.getTime()) / 1000);
      if (secondsUntil <= 0) continue;
      await Notifications.scheduleNotificationAsync({
        identifier: `appt_${appt.jobId}`,
        content: {
          title: appt.title,
          body: appt.body,
          data: { type: 'appointment_confirm', jobId: appt.jobId },
        },
        trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
      });
      count++;
    }

    // Maintenance-plan (recurring invoice) "review & send" reminders — one
    // per ACTIVE rule, 9:00am on the rule's next generation date. Own
    // identifier namespace (rinv_) beside inv_/appt_; shares the 60 cap.
    // Android reuses the invoice-reminders channel: like every branch above,
    // no per-notification channelId is passed and setupNotifications creates
    // no new channel. The notification is an invitation to open the app —
    // generation itself happens on next open (AuthContext), not here.
    // Fire-date construction is deliberately kept identical to the inv_
    // branch above (local-frame `date + 'T00:00:00'` parse, then local
    // setHours(9,...)) — both branches were fixed together 2026-08-01 (owner
    // approved) after the old bare `new Date(dateString)` UTC-midnight parse
    // was found to fire 9am local on the day BEFORE the intended date in
    // every US timezone. Do not let the two branches drift independently.
    for (const rule of recurringInvoiceRules) {
      if (count >= 60) break;
      if (!rule.isActive) continue;

      const fireDate = new Date(rule.nextDueDate + 'T00:00:00');
      fireDate.setHours(9, 0, 0, 0);
      const secondsUntil = Math.floor((fireDate.getTime() - now.getTime()) / 1000);
      if (secondsUntil <= 0) continue;

      await Notifications.scheduleNotificationAsync({
        identifier: `rinv_${rule.id}`,
        content: {
          title: `Maintenance invoice ready — ${rule.customerName}`,
          body: 'Open to review & send.',
          data: { type: 'recurring_invoice', ruleId: rule.id },
        },
        trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
      });
      count++;
    }
  } catch {
    // Not critical — silently skip if notifications are unavailable
  }
}
