// utils/onboardingDraft.ts
// Autosaved draft for the onboarding wizard so an interruption (app kill,
// phone call, backgrounding) doesn't erase what the user typed. Device-local
// only — cleared when onboarding finishes and on the sign-out wipe.

import AsyncStorage from "@react-native-async-storage/async-storage";
import type { TradeId } from "../types/models";

export const ONBOARDING_DRAFT_KEY = "onboardingDraft";

export interface OnboardingDraft {
  businessName: string;
  contactName: string;
  trade: TradeId;
  step: number;
}

export async function loadOnboardingDraft(): Promise<OnboardingDraft | null> {
  try {
    const raw = await AsyncStorage.getItem(ONBOARDING_DRAFT_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<OnboardingDraft> | null;
    if (!parsed || typeof parsed !== "object") return null;
    if (typeof parsed.businessName !== "string" || typeof parsed.contactName !== "string") {
      return null;
    }
    return {
      businessName: parsed.businessName,
      contactName: parsed.contactName,
      trade: (parsed.trade as TradeId) || "plumbing",
      step: typeof parsed.step === "number" ? parsed.step : 0,
    };
  } catch {
    return null;
  }
}

export async function saveOnboardingDraft(draft: OnboardingDraft): Promise<void> {
  try {
    await AsyncStorage.setItem(ONBOARDING_DRAFT_KEY, JSON.stringify(draft));
  } catch {
    // A failed draft write must never surface — it's a convenience, not data.
  }
}

export async function clearOnboardingDraft(): Promise<void> {
  try {
    await AsyncStorage.removeItem(ONBOARDING_DRAFT_KEY);
  } catch {}
}
