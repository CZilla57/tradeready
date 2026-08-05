// utils/setupChecklist.ts
// The in-product "Finish setting up" checklist that replaced the heavy
// onboarding steps (2026-08-03 flow restructure). Onboarding now collects only
// name/business/trade; contact details, logo, pricing, Stripe and
// notifications live here as post-signup tasks surfaced on the Today tab.
//
// Completion is DERIVED from settings wherever possible (contact, logo) and
// stored only where no honest derivation exists (rate = "user saved the Pricing settings page",
// stripe = "connect-status came back connected"). The stored state is
// device-local and deliberately NOT synced: on a new device the checklist
// re-derives what it can and the user can dismiss the rest.

import AsyncStorage from "@react-native-async-storage/async-storage";
import type { Settings } from "../types/models";

export const SETUP_CHECKLIST_STATE_KEY = "setupChecklistState";

export type SetupTaskId = "contact" | "logo" | "rate" | "stripe" | "notifications";

export interface SetupChecklistState {
  dismissed?: boolean;
  done?: Partial<Record<SetupTaskId, boolean>>;
  /** Sample-data users: the Today hero card was used once and should hide. */
  sampleTourDone?: boolean;
}

export interface SetupTask {
  id: SetupTaskId;
  title: string;
  subtitle: string;
  done: boolean;
}

export function deriveSetupTasks(
  settings: Settings,
  state: SetupChecklistState,
  notifGranted: boolean
): SetupTask[] {
  const done = state.done ?? {};
  const providerKeys = (settings as { providerKeys?: Record<string, string> }).providerKeys ?? {};
  const altProviderConfigured =
    settings.provider !== "stripe" && !!providerKeys[settings.provider]?.trim();
  return [
    {
      id: "contact",
      title: "Add your contact details",
      subtitle: "Phone and address appear on invoices and estimates.",
      done: !!(settings.phone?.trim() && settings.address?.trim()),
    },
    {
      id: "logo",
      title: "Add your logo",
      subtitle: "Shown on estimates, invoices and PDFs.",
      done: !!settings.logoPhoto,
    },
    {
      id: "rate",
      title: "Review your pricing defaults",
      subtitle: "Labor rate, markup and margin power every estimate.",
      done: done.rate === true,
    },
    {
      id: "stripe",
      title: "Connect a payment processor",
      subtitle: "Send payment links so customers can pay you online.",
      done: done.stripe === true || altProviderConfigured,
    },
    {
      id: "notifications",
      title: "Turn on invoice reminders",
      subtitle: "Get notified before invoices go overdue.",
      done: notifGranted,
    },
  ];
}

/**
 * The single shared definition of "the Finish-setting-up card is off the
 * screen": the user dismissed it, or every derived task is done. The Today
 * InsightsCard gates on this so it can never disagree with
 * SetupChecklistCard's own hide condition.
 */
export function isSetupComplete(
  settings: Settings,
  state: SetupChecklistState,
  notifGranted: boolean
): boolean {
  if (state.dismissed) return true;
  return deriveSetupTasks(settings, state, notifGranted).every((t) => t.done);
}

export async function loadSetupChecklistState(): Promise<SetupChecklistState> {
  try {
    const raw = await AsyncStorage.getItem(SETUP_CHECKLIST_STATE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? (parsed as SetupChecklistState) : {};
  } catch {
    return {};
  }
}

async function saveState(state: SetupChecklistState): Promise<void> {
  try {
    await AsyncStorage.setItem(SETUP_CHECKLIST_STATE_KEY, JSON.stringify(state));
  } catch {
    // Checklist state is a convenience; a failed write must never surface.
  }
}

export async function markSetupTaskDone(id: SetupTaskId): Promise<void> {
  const state = await loadSetupChecklistState();
  if (state.done?.[id]) return; // already recorded — skip the write
  await saveState({ ...state, done: { ...state.done, [id]: true } });
}

export async function dismissSetupChecklist(): Promise<void> {
  const state = await loadSetupChecklistState();
  await saveState({ ...state, dismissed: true });
}

export async function markSampleTourDone(): Promise<void> {
  const state = await loadSetupChecklistState();
  if (state.sampleTourDone) return;
  await saveState({ ...state, sampleTourDone: true });
}
