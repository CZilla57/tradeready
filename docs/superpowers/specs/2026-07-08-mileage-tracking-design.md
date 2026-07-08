# Mileage Tracking — Design

**Date:** 2026-07-08
**Status:** Approved (design), pending implementation plan
**Repo:** `tradeready/` (branch `master`)

## Goal

Let a tradesperson log business driving — to jobs and between jobs — and see a
tax deduction total, using the US IRS **standard mileage rate** method
(business miles × a configurable per-mile rate).

## Concept & guardrails

This is a **mileage deduction log**, deliberately separate from the two travel
concepts already in the app. Do not conflate or modify them:

- `travelFeePerMile` / `travelMiles` — charging the *customer* a travel fee on
  an estimate (revenue). **Untouched.**
- `fuel` expense category — logging actual fuel spend. **Untouched.**

Mileage will **not** auto-post to the expenses ledger. IRS rules require picking
either the standard-mileage method *or* the actual-expenses method; auto-posting
a mileage deduction alongside logged fuel expenses would double-count. The
deduction is shown as an informational total only.

## Capture method

**Odometer start/end** (no GPS, no geocoding). The user enters a start and end
odometer reading per trip; the app derives the miles. Audit-friendly, works in
Expo Go today, no new dependencies or permissions, fully offline.

## Data shape — new `Trip`

Added to `types/models.ts`. A **local-only** collection modeled on
`recurringJobs` (stored on-device, cleared on sign-out, **not** synced to
Supabase).

```ts
export interface Trip {
  id: string;
  date: DateString;              // "YYYY-MM-DD"
  odometerStart: number;
  odometerEnd: number;
  miles: number;                 // derived + stored: max(0, end - start)
  fromJobId: string | null;      // null = "Home / Shop"
  fromLabel: string;             // denormalized display label (job/customer name or "Home / Shop")
  toJobId: string | null;        // null = "Home / Shop"
  toLabel: string;               // denormalized display label
  purpose: string;               // free-text note
  createdAt: DateString;
}
```

The from→to endpoint model covers all three requested cases:

- **home → job** (driving *to* a job)
- **job → job** (driving *between* jobs)
- **job → home** (return leg)

Either endpoint may be a linked job (`fromJobId`/`toJobId` set) or "Home / Shop"
(`null`). Denormalized display labels follow the codebase's existing pattern
(`Job.customerName`, `RecurringJob.customerName`) so the log renders without a
join.

## Storage (no sync-engine changes)

- New `utils/storage/trips.ts` — `loadTrips()` / `saveTrips()`, modeled on
  `utils/storage/recurringJobs.ts`: reads/writes AsyncStorage under a new key;
  **no** `enqueueCollectionChanges`, **no** `trySync`.
- Add `trips: "trips"` to `utils/storage/keys.ts`.
- Export the new functions from `utils/storage/index.ts`.
- Add `'trips'` to the sign-out `multiRemove` list in `utils/sync.ts`
  (currently `[...COLLECTION_TABLES, 'customerNotes', 'recurringJobs']`, ~line
  211) so the collection is cleared on sign-out and respects per-user
  (`__dataOwner`) isolation like `recurringJobs`.

**Deliberately not done:** wiring `trips` into the sync engine
(`COLLECTION_TABLES`) or creating a Supabase `trips` table. The upgrade path to
cloud sync later is a small additive change (add a table + RLS policies + one
`COLLECTION_TABLES` entry); it is documented here, not built. Rationale: keeps
this feature off the data-loss-sensitive sync path and off a DB migration that
cannot be applied in the current session.

## Deduction math — `utils/mileageUtils.ts`

- `computeTripMiles(start, end)` → `Math.max(0, end - start)`.
- `mileageSummary(trips, range, rate)` →
  `{ tripCount, totalMiles, deduction: totalMiles * rate }`.
- Period filtering reuses `utils/moneyUtils.isInRange` / `getDateRange`, so the
  mileage total honors the Money tab's existing period selector (This Month /
  Last Month / This Year / All Time), filtering on `Trip.date`.
- Numeric inputs parsed defensively (odometer fields arrive as strings from
  `TextInput`).

### New setting

Add `mileageRate: number` to the `Settings` interface (plain AsyncStorage,
**not** SecureStore — it is not sensitive), default `0.70`.

> The exact current IRS standard mileage rate is not verified in this design.
> The field is user-editable and the Settings UI reminds the user to set the
> correct rate for their tax year.

## UI & navigation (under the Money tab — no 8th bottom tab)

- **`screens/MoneyScreen.tsx`**: a "Mileage" card showing period total miles and
  estimated deduction (formatted with `formatMoney`); tapping opens the log.
- **`screens/MileageLogScreen.tsx`** (new): a summary header (total miles +
  deduction for the selected period) plus a trip list (date, `from → to`, miles,
  purpose), an "Add trip" button, and tap-to-edit rows.
- **`screens/AddTripScreen.tsx`** (new): form fields — date; From (Home/Shop or
  pick a job); To (Home/Shop or pick a job); odometer start; odometer end; a
  live computed-miles preview; purpose. Save and Delete actions. Validation: if
  `end < start`, miles resolve to 0 and an inline warning is shown.
- Register both new screens in the Money stack navigator.
- **`screens/SettingsScreen.tsx`**: a "Mileage rate ($/mi)" field, labeled as a
  *tax deduction* rate and visually distinct from the customer travel fee.

### Formatting

- Deduction dollars → `formatMoney` (a concrete computed amount, two decimals).
- Miles → plain numeric display with a "mi" suffix.

## Testing & gate

- `__tests__/mileageUtils.test.js`: miles derivation (including `end < start → 0`),
  deduction math, and period filtering — matching the style of the existing
  formula-regression suite (`pricingEngine.test.js`, `invoiceStats.test.js`).
- All new files are `.ts` / `.tsx` (repo is post-TypeScript-migration).
- The verify gate (typecheck / tests / lint) must be green before any commit.

## Out of scope (YAGNI)

- GPS / live location tracking.
- Auto-distance from addresses / geocoding / routing APIs.
- Cloud sync of the mileage log (local-only for now; additive upgrade path noted).
- Auto-posting the deduction into the expenses P&L.
- Personal-vs-business trip classification (every logged trip is a business trip
  by construction).
