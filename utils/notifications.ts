import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';
import type { Invoice, Settings, ReminderRule, Job, Customer } from '../types/models';
import { selectAppointmentReminders } from './appointmentMessages';

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

    const [invoicesRaw, settingsRaw, jobsRaw, customersRaw] = await Promise.all([
      AsyncStorage.getItem('invoices'),
      AsyncStorage.getItem('settings'),
      AsyncStorage.getItem('jobs'),
      AsyncStorage.getItem('customers'),
    ]);
    const invoices: Invoice[] = invoicesRaw ? JSON.parse(invoicesRaw) : [];
    const settings: Partial<Settings> = settingsRaw ? JSON.parse(settingsRaw) : {};
    const jobs: Job[] = jobsRaw ? JSON.parse(jobsRaw) : [];
    const customers: Customer[] = customersRaw ? JSON.parse(customersRaw) : [];
    const rules: ReminderRule[] = settings.rules || [];
    const autoOutreach = !!settings.autoOutreachEnabled;

    await Notifications.cancelAllScheduledNotificationsAsync();

    const unpaid = invoices.filter(inv => !inv.paid && inv.due);
    const now = new Date();
    let count = 0;

    outer: for (const inv of unpaid) {
      for (const rule of rules) {
        if (count >= 60) break outer;

        const fireDate = new Date(inv.due);
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
  } catch {
    // Not critical — silently skip if notifications are unavailable
  }
}
