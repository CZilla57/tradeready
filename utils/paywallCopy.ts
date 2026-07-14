// Derives the paywall's trial wording from the RevenueCat package's
// intro-offer data instead of hardcoding "14-day free trial". The store
// products are configured in the dashboards, so hardcoded copy can silently
// diverge from the real offer — an App Review "misleading claims" (2.3.1)
// risk — and a dashboard trial change should never require an app update.
// Only genuinely FREE intro offers produce trial copy; paid intro offers and
// products without one get the no-trial wording.

interface IntroPriceLike {
  price: number;
  periodUnit: string; // "DAY" | "WEEK" | "MONTH" | "YEAR"
  periodNumberOfUnits: number;
}

interface PackageLike {
  product?: {
    introPrice?: IntroPriceLike | null;
  } | null;
}

export interface TrialCopy {
  badge: string; // e.g. "14-day free trial — no charge until it ends"
  cta: string; //   "Start Free Trial"
  sub: string; //   "No charge for 14 days. Cancel anytime."
}

const UNIT_WORDS: Record<string, string> = {
  DAY: "day",
  WEEK: "week",
  MONTH: "month",
  YEAR: "year",
};

// Returns trial wording for a package with a free intro offer, or null when
// the package has no free trial (callers then show the no-trial wording).
export function trialCopy(pkg: PackageLike | null | undefined): TrialCopy | null {
  const intro = pkg?.product?.introPrice;
  if (!intro) return null;
  if (intro.price !== 0) return null; // paid intro offer — not a free trial

  const n = intro.periodNumberOfUnits;
  const unit = UNIT_WORDS[intro.periodUnit];
  if (!unit || !n || n < 1) return null;

  const adjective = `${n}-${unit}`; //          "14-day"
  const noun = n === 1 ? `1 ${unit}` : `${n} ${unit}s`; // "14 days"

  return {
    badge: `${adjective} free trial — no charge until it ends`,
    cta: "Start Free Trial",
    sub: `No charge for ${noun}. Cancel anytime.`,
  };
}

// Wording when the selected package has no (usable) free trial.
export const NO_TRIAL_COPY: TrialCopy = {
  badge: "",
  cta: "Subscribe",
  sub: "Renews automatically. Cancel anytime.",
};

// What the paywall's plan area should render. "empty" is the case the screen
// historically dropped on the floor: offerings loaded fine but contained no
// monthly/annual package (misconfigured or still-propagating store products),
// which left the user staring at a disabled CTA with no explanation.
export type OfferingsDisplayState = "loading" | "error" | "empty" | "plans";

export function offeringsDisplayState(
  offerings: { packageType?: string }[] | null,
  loadError: string | null
): OfferingsDisplayState {
  if (loadError) return "error";
  if (offerings === null) return "loading";
  const usable = offerings.some(
    (p) => p?.packageType === "MONTHLY" || p?.packageType === "ANNUAL"
  );
  return usable ? "plans" : "empty";
}
