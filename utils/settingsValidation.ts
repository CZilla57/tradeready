// utils/settingsValidation.ts
// Hard validation for the Settings save path. Empty contact fields are fine
// (they're optional), but a NON-EMPTY malformed email/phone, or a labor rate
// the pricing engine can't work with, must block the save — the old
// warn-but-save-anyway behavior let bad values reach invoices and estimates.

export interface SettingsValidationInput {
  email: string;
  phone: string;
  laborRate: number;
}

export interface ContactValidationInput {
  email: string;
  phone: string;
}

export const EMAIL_RE = /^\S+@\S+\.\S+$/;

export function validateEmailPhone({ email, phone }: ContactValidationInput): string[] {
  const errors: string[] = [];
  if (email.trim() && !EMAIL_RE.test(email.trim())) {
    errors.push("Email doesn't look like a valid address.");
  }
  if (phone.trim() && phone.replace(/\D/g, "").length < 10) {
    errors.push("Phone number looks incomplete — it needs 10 digits.");
  }
  return errors;
}

export function validateLaborRate(laborRate: number): string[] {
  if (!Number.isFinite(laborRate) || laborRate <= 0) {
    return ["Hourly labor rate must be greater than $0."];
  }
  return [];
}

export function validateSettingsInput({ email, phone, laborRate }: SettingsValidationInput): string[] {
  return [...validateEmailPhone({ email, phone }), ...validateLaborRate(laborRate)];
}
