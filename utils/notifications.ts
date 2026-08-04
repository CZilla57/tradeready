import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Notifications from 'expo-notifications';
import { Alert, Platform } from 'react-native';
import type { Invoice, Settings, ReminderRule, Job, Customer, RecurringInvoice } from '../types/models';
import { isFullyPaid } from './invoicePayments';
import { selectAppointmentReminders } from './appointmentMessages';
import { isJobDunningEligible } from './jobStatus';
import { parseLocalDate } from './moneyUtils';
import { selectEstimateFollowUps, FOLLOW_UP_DAYS } from './estimateFollowUps';
import { REMINDER_PROMPT_KEY } from './storage/keys';
import {
  getPendingReviewRequests,
  reviewRequestDelaySeconds,
  buildReviewRequestNotification,
} from './reviewRequest';

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

// One-shot contextual permission ask, replacing the generic onboarding prompt
// (2026-08-03 flow restructure): fires the first time the user creates an
// invoice — the moment reminders become concretely useful. Asks at most once;
// silent when the OS permission is already settled either way. The flag key
// lives in storage/keys.ts so the sign-out wipe can list it without importing
// this module.
export async function promptForInvoiceReminders(): Promise<void> {
  try {
    const shown = await AsyncStorage.getItem(REMINDER_PROMPT_KEY);
    if (shown) return;
    const { status } = await Notifications.getPermissionsAsync();
    // Stamp before showing: settled permissions need no prompt, and a shown
    // prompt must not repeat even if the user dismisses it without choosing.
    await AsyncStorage.setItem(REMINDER_PROMPT_KEY, 'true');
    if (status !== 'undetermined') return;
    Alert.alert(
      'Invoice reminders',
      'Want a heads-up before invoices go overdue? TradeReady can notify you so nothing slips through the cracks.',
      [
        { text: 'Not now', style: 'cancel' },
        {
          text: 'Turn on',
          onPress: () => {
            requestPermissions()
              .then((granted) => { if (granted) syncNotifications(); })
              .catch(() => {});
          },
        },
      ]
    );
  } catch {
    // Never let a permission prompt failure interfere with saving an invoice.
  }
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

        // inv.due comes from a free-text Field (AddInvoiceScreen) with no
        // format validation, so it is not guaranteed to be strict
        // "YYYY-MM-DD". parseLocalDate (utils/moneyUtils.ts) is the same
        // defensive local-frame parser already used for this reason in
        // utils/customerMix.ts — strict ISO date parses as local midnight;
        // anything else falls back to `new Date(raw)` rather than throwing.
        const fireDate = parseLocalDate(inv.due);
        fireDate.setDate(fireDate.getDate() + rule.days);
        fireDate.setHours(9, 0, 0, 0);

        const secondsUntil = Math.floor((fireDate.getTime() - now.getTime()) / 1000);
        if (!Number.isFinite(secondsUntil) || secondsUntil <= 0) continue;

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
    // Fire-date construction is deliberately kept to the same local-frame
    // construction as the inv_ branch above (local-frame `date +
    // 'T00:00:00'` parse, then local setHours(9,...)) — the inv_ branch
    // additionally applies a days offset. Both branches were fixed together
    // 2026-08-01 (owner approved) after the old bare `new Date(dateString)`
    // UTC-midnight parse was found to fire 9am local on the day BEFORE the
    // intended date in every US timezone. Do not let the two branches drift
    // independently.
    for (const rule of recurringInvoiceRules) {
      if (count >= 60) break;
      if (!rule.isActive) continue;

      const fireDate = new Date(rule.nextDueDate + 'T00:00:00');
      fireDate.setHours(9, 0, 0, 0);
      const secondsUntil = Math.floor((fireDate.getTime() - now.getTime()) / 1000);
      if (!Number.isFinite(secondsUntil) || secondsUntil <= 0) continue;

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

    // Estimate follow-up nudges — one-shot "no response" reminder per silent
    // estimate, FOLLOW_UP_DAYS after the send, 9:00am local. Fourth namespace
    // (est_) beside inv_/appt_/rinv_; shares the 60 cap and runs after invoice
    // dunning and appointments so they keep priority. Fire-date math lives in
    // the pure selector (utils/estimateFollowUps.ts) using the same
    // local-frame construction as the branches above — do not let them drift.
    // ABSENT estimateFollowUpsEnabled means ON (default-on; the reverse of
    // appointmentRemindersEnabled — see types/models.ts).
    if (settings.estimateFollowUpsEnabled !== false) {
      for (const nudge of selectEstimateFollowUps(jobs, now)) {
        if (count >= 60) break;
        const secondsUntil = Math.floor((nudge.fireDate.getTime() - now.getTime()) / 1000);
        if (!Number.isFinite(secondsUntil) || secondsUntil <= 0) continue;
        await Notifications.scheduleNotificationAsync({
          identifier: `est_${nudge.jobId}`,
          content: {
            title: `Estimate follow-up — ${nudge.customerName}`,
            body: `Estimate for "${nudge.jobTitle}" sent ${FOLLOW_UP_DAYS} days ago with no response. Tap to follow up.`,
            data: { type: 'estimate_follow_up', jobId: nudge.jobId },
          },
          trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
        });
        count++;
      }
    }

    // Review-request nudges (review_) — the one namespace NOT derived by this
    // sweep: scheduleReviewRequest (utils/reviewRequest.ts) arms a one-shot at
    // job completion, so the cancel-all above just killed any still-pending
    // one. Rebuild it here from the review_requests records (sentAt null =
    // still pending) — without this, any sweep inside the delay window
    // (including the saveJobs sweep fired by the completion itself, or just
    // reopening the app) ate the nudge forever: the pending record makes
    // scheduleReviewRequest's one-shot guard refuse to ever re-arm. The fire
    // instant is re-derived from the record's scheduledAt via the shared
    // delay formula, so a rebuild never moves it; one already past means the
    // notification fired (or was missed) — never re-nag late. The job lookup
    // is load-bearing twice: it supplies the title for the body, and it drops
    // records whose job is gone — including records left by a previous
    // account, since review_requests survives sign-out but the jobs
    // collection does not. Toggle off = not rebuilt = pending nudges stop,
    // same semantics as the appt_/est_ toggles. Fifth namespace; shares the
    // 60 cap and runs last.
    if (settings.reviewRequestEnabled) {
      const delayMs = reviewRequestDelaySeconds(settings.reviewRequestDelayHours) * 1000;
      const jobById = new Map(jobs.map((j) => [j.id, j]));
      for (const record of await getPendingReviewRequests()) {
        if (count >= 60) break;
        const job = jobById.get(record.jobId);
        if (!job) continue;
        const secondsUntil = Math.floor(
          (new Date(record.scheduledAt).getTime() + delayMs - now.getTime()) / 1000
        );
        if (!Number.isFinite(secondsUntil) || secondsUntil <= 0) continue;
        await Notifications.scheduleNotificationAsync({
          ...buildReviewRequestNotification(record.jobId, record.customerName, job.title),
          trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
        });
        count++;
      }
    }
  } catch {
    // Not critical — silently skip if notifications are unavailable
  }
}
