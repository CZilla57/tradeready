// utils/appointmentTemplates.ts
// Default appointment message templates. Kept in a dependency-free module so
// utils/storage/defaults.ts can import them without pulling in the rest of
// appointmentMessages.ts (which imports storage/customers → collections →
// defaults, which would close an import cycle).
export const DEFAULT_CONFIRM_TEMPLATE =
  "Hi {customerName}, this is {businessName} confirming your appointment for {date} at {time}. " +
  "Reply here if you need to reschedule — see you then!";

export const DEFAULT_ON_MY_WAY_TEMPLATE =
  "Hi {customerName}, this is {businessName} — I'm on my way now. See you shortly!";
