import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: false,
    shouldSetBadge: false,
  }),
});

export async function setupNotifications() {
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('invoice-reminders', {
      name: 'Invoice Reminders',
      importance: Notifications.AndroidImportance.DEFAULT,
    });
  }
}

export async function requestPermissions() {
  const { status: existing } = await Notifications.getPermissionsAsync();
  if (existing === 'granted') return true;
  if (existing === 'denied') return false;
  const { status } = await Notifications.requestPermissionsAsync();
  return status === 'granted';
}

// Reads invoices + settings directly from AsyncStorage (avoids circular import
// with storage.js) and schedules one local notification per invoice × rule
// where the threshold date is still in the future.
export async function syncNotifications() {
  try {
    const { status } = await Notifications.getPermissionsAsync();
    if (status !== 'granted') return;

    const [invoicesRaw, settingsRaw] = await Promise.all([
      AsyncStorage.getItem('invoices'),
      AsyncStorage.getItem('settings'),
    ]);
    const invoices = invoicesRaw ? JSON.parse(invoicesRaw) : [];
    const settings = settingsRaw ? JSON.parse(settingsRaw) : {};
    const rules = settings.rules || [];

    await Notifications.cancelAllScheduledNotificationsAsync();

    const unpaid = invoices.filter(inv => !inv.paid && inv.due);
    const now = new Date();
    let count = 0;

    outer: for (const inv of unpaid) {
      for (const rule of rules) {
        if (count >= 60) break outer; // Stay under iOS 64-notification limit

        const fireDate = new Date(inv.due);
        fireDate.setDate(fireDate.getDate() + rule.days);
        fireDate.setHours(9, 0, 0, 0);

        const secondsUntil = Math.floor((fireDate.getTime() - now.getTime()) / 1000);
        if (secondsUntil <= 0) continue; // Threshold already passed

        await Notifications.scheduleNotificationAsync({
          identifier: `inv_${inv.id}_${rule.days}d`,
          content: {
            title: `Overdue invoice — ${inv.customer}`,
            body: `Invoice ${inv.number} is now ${rule.days} days past due.`,
            data: { invoiceId: inv.id },
          },
          trigger: { seconds: secondsUntil },
        });
        count++;
      }
    }
  } catch {
    // Not critical — silently skip if notifications are unavailable
  }
}
