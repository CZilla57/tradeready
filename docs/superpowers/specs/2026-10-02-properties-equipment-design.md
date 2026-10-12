# Multi-Property & Equipment History (Roadmap Phase 21) — Design Spec

**Date:** 2026-10-02
**Status:** BUILT 2026-10-03; verified and committed 2026-10-12 on local `feat/properties-equipment`, stacked on `feat/job-forms` (native only). Gate green on its own branch tip against the master baseline (accessibility-audit and layout-metrics fail on master too); Worker `npm test`, doc reference check and the Release compile pass. Reviewed in its build record. Nothing pushed, deployed or applied. Build record: §8.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 21, build order #5
**Build target (owner, 2026-10-02):** native SwiftUI app only. **No React Native, Worker or migration changes.**

## 0. Preconditions verified against the repo

- `Canonical.Customer.address` and `Canonical.Job.address` are required free-text strings. A job's address is copied once from the customer when it's empty (`JobEditor`) and is never referenced again. Nothing stores coordinates; route geocoding happens on demand.
- The job address drives: the job detail row, route stops, widget/Today/Siri text, global search, and the `{address}` fallback in appointment messages (the customer address wins there).
- The estimate PDF prints the **customer's** address. Invoices, estimate snapshots and the portal carry no customer address.
- Address plays no part in customer identity or duplicate detection (name, phone, email only). Booking/CSV upserts are name-keyed and fill a blank address only.
- The customer save path (`AppStore.upsert(Customer)` → `canonical(from: CanonicalUIEdit…)`) preserves unknown nested fields.
- **Paths that lose fields:**
  - merge drops the loser's unknown fields
  - `duplicateJob` and `recurringJob(from:)` are whitelists
  - recurring occurrences start with a fresh `Preservation`
- `RecurringInvoice` (maintenance plans) has no address.
- There's no equipment, asset, serial or warranty concept anywhere.

## 1. Decisions

- **Storage:** nested in the customer blob (`customer.properties`). The server never writes customer blobs, so a race with server writes isn't a concern. Edits are infrequent and the size is small (a few KB for a heavy customer). No migration.
- **Primary property:** its address is **always derived from `customer.address`**; it stores no address of its own. Editing the customer's address (natively, from the web app, or from RN) can never drift away from the primary property. The identity and `getOrCreateCustomer` contract is untouched.
- **Absent `properties`** means one implicit primary property with no equipment. Existing customers need no migration and no backfill. The first property or equipment action materializes the primary property.
- **Jobs** gain optional `propertyId` and keep their `address` string as the service address of record. Every existing reader (route, widget, search, messages) keeps working unchanged.

## 2. Data model (additive-optional)

```ts
// Customer.properties?: Property[]  — when present: non-empty, exactly one primary
interface Property {
  id: string;                 // "pr<ms>_<base36>"
  primary?: true;             // exactly one; its address = customer.address (derived)
  label?: string;             // 0..40, e.g. "Home", "Rental on Elm"
  address?: string;           // required (1..300) for non-primary; ignored for primary
  notes?: string;             // 0..1000 (gate code, dog, shutoff location)
  equipment?: Equipment[];    // 0..50
  archivedAt?: string;        // non-primary only
}
interface Equipment {
  id: string;                 // "eq<ms>_<base36>"
  type: string;               // preset key or custom label, 1..40
  make?: string; model?: string; serial?: string;   // 0..80 each
  installDate?: string;       // YYYY-MM-DD local calendar date
  warrantyExpires?: string;   // YYYY-MM-DD local calendar date
  notes?: string;             // 0..500
  archivedAt?: string;        // removed/replaced equipment stays as history
}
// Job.propertyId?: string    — absent/unknown → the job's own address stands alone
```

**Equipment type presets** (stored keys): furnace, ac_condenser, heat_pump, air_handler, mini_split, boiler, water_heater, tankless_water_heater, water_softener, sump_pump, electrical_panel, generator, ev_charger, thermostat, other. Anything else is a custom label.

**Invariants:**
- **P1** — exactly one primary property, and it has no stored `address`.
- **P2** — property and equipment ids are unique within the customer.
- **P3** — a job's `propertyId`, when set, names a property on that job's customer. If it doesn't resolve (archived, removed, or a merged-away customer), the UI shows the job address only. It never crashes and never rewrites the job.

## 3. Native flows

- **Customer detail → "Properties" section** (after Contact):
  - It lists properties: the primary first (labelled "Primary" with the customer address), then the others. Each row shows its equipment count and its jobs at that property.
  - "Add property" (label, address with the existing `NativeAddressLookup` autocomplete, notes).
  - Property detail: address and label, notes, an equipment list (active items first; archived ones under "Past equipment"), "Add equipment", and the property's job history.
    - The job history covers jobs with that `propertyId`. For the primary, it also covers jobs with no `propertyId` whose normalized address equals the customer address.
    - The list is newest first and links into each job.
- **Equipment editor:** a type picker (presets plus "Other…"), make, model, serial, install date, warranty expiry (optional dates, local calendar), and notes. "Mark as removed" archives the item. A warranty row shows "Expires in N days" or "Expired".
- **JobEditor:** once a customer with more than one property is picked, a "Property" picker appears. Picking a property sets `propertyId` and fills `address` from it, but only when the address is empty or still equals the previously chosen property's address, so typed edits are never overwritten. Picking the primary sets `propertyId` to the primary's id.
- **Job detail:** the Schedule section's address row shows the property label when one resolves. A read-only "Equipment at this property" section shows active equipment (type, make/model, serial, warranty status) with "Add equipment".
  - If the job has no `propertyId` and its address matches none of the customer's property addresses, an "Add as a property" action creates the property and links the job. This is how booking-link jobs from a returning customer at a new address get attached.
- **Merge:**
  - The winner keeps its properties.
  - The loser's properties are unioned in: the loser's primary becomes a non-primary property with `address = loser.address`, unless it normalizes equal to the winner's address, in which case its equipment merges into the winner's primary.
  - Re-pointed jobs keep their `propertyId` (ids are globally random).
  - Undo restores both records exactly.
- **Duplicate job / recurring rules / occurrences** carry `propertyId` (whitelists updated).
- **Estimate review/PDF:** when the job address is non-empty and differs (normalized) from the customer's address, the document shows a "Service address" line under the customer block.
- **Global search** matches equipment serial and model and lands on the customer.

## 4. Warranty insight

A new `NativeInsightKind.warrantyExpiring` (muteable, 14-day snooze).

- **Selection:** active equipment whose `warrantyExpires` falls within the next 30 local days, inclusive of today.
- **Priority:** it runs after `selectMaintenanceDue` and shows at most one insight, for the soonest expiry. Ties break by customer name, then equipment id.
- **Copy:** "<Customer>'s <type> warranty ends <date>. A good time to offer a maintenance plan."
- **Target:** `.customer(customerId:)`.
- **Dates:** everything uses `NativeCashBasis` local-date parsing (FA-039 safe), and is tested under a Phoenix calendar at the day boundary.

## 5. Testing

- **New Swift `PropertiesEquipmentTests`** (runner `run-properties-equipment-tests.sh`, registered). It covers:
  - canonical round-trip, including unknown keys inside property and equipment
  - implicit primary
  - materialization
  - invariants P1–P3 and the field caps
  - property add/edit/archive
  - equipment add/edit/archive and type normalization
  - JobEditor property-pick address rules
  - the job-history query, including the legacy address match for the primary
  - merge union, including the same-address equipment merge and undo
  - whitelists for duplicate, recurring and occurrence
  - the "Service address" rule
  - warranty date math under Phoenix
- **Updated suites:** CustomerIdentityTests (merge/undo), AdapterTests, CanonicalTests fixtures, RecurringJobTests, GlobalSearchTests, TodayInsightsTests, InsightMuteTests, EstimatePDFTests.
- **Gates:** `sh native/run-all-domain-tests.sh`, the Release compile, `sh native/run-doc-reference-check.sh`.

## 6. Accepted residuals

- Booking intake doesn't auto-create properties, because address matching is fuzzy. The owner attaches a new property with one tap from the job.
- No per-job "equipment serviced" link in v1. Service history is the property's job history. Linking jobs to specific equipment is an additive follow-up.
- Properties aren't shown in the portal or on invoices.
- RN and web edits keep unknown nested fields, but neither can view or edit properties.

## 7. Owner decisions recorded

| # | Decision | Choice |
|---|---|---|
| D1 | Storage | Nested in the customer blob; no migration |
| D2 | Primary property address | Derived from `customer.address` (never stored twice) |
| D3 | Job link | `job.propertyId` plus the job's own address string as record |
| D4 | Warranty insight window | 30 days |

## 8. Build record (2026-10-03)

Built on `feat/properties-equipment`: native SwiftUI only. No React Native, Worker or `backend/` change, no migration, no new synced collection (D1: properties nest in the customer blob, so the existing `customers` sync carries them).

### 8.1 §0 re-verified on 2026-10-03

Every §0 statement still holds on the current tree. Customer and job `address` are required strings, and `JobEditor` copies the customer address only into an empty job address. The estimate PDF prints the customer address. Identity and duplicate detection never read the address. The customer save path (`upsert(Customer)` → `CanonicalUIAdapters.canonical(from: CanonicalUIEdit…)`) starts from the stored record, so nested fields survive. Merge kept only the winner record, `duplicateJob` and `recurringJob(from:)` were whitelists, and occurrences started with a fresh `Preservation`. `RecurringInvoice` has no address. Nothing in `N/` or `types/models.ts` had an equipment, serial or warranty concept. The Worker never writes the customer blob: portal tokens live in `portal_tokens`.

### 8.2 What was built

- **Canonical model** (`N/Domain/CanonicalModels.swift`): `Canonical.Property` and `Canonical.Equipment` follow the ObjectReader/ObjectWriter + `Preservation` pattern, so unknown keys and explicit nulls round-trip at both nested levels. `Customer.properties`, `Job.propertyId` and `RecurringJob.propertyId` are typed optionals, and absent stays absent. Invariants are never checked at decode, so a bad blob can't fail a customers pull.
- **Domain** (`N/Domain/NativePropertiesEquipment.swift`, Foundation and canonical models only; typed `PropertyError` with owner-facing text; no force-unwraps) covers:
  - the read model, with an implicit primary when nothing is stored
  - materialization (with P1 repair) and validation (P1, P2 and every §2 cap)
  - property add, edit, archive, restore and remove
  - equipment add, edit, "Mark as removed", restore and remove
  - equipment-type presets with alias normalization
  - address normalization and the "Service address" rule
  - P3 resolution, the job-history query and "Add as a property"
  - the job-editor pick rule and the merge plan
  - the search index and the warranty status and window
  - civil-day date math
- **Store API** (`N/NativePropertiesEquipmentStore.swift`, an AppStore extension):
  - reads, adds and edits as listed above, plus `addJobAddressAsProperty`
  - each write commits through `commitPropertyChange`, which lives with the other primitives in `N/AppStore.swift`: one durable save, then one queue batch (customer upsert, plus the linked job)
  - `deleteProperty`/`deleteEquipment` use the shared 8 s deletion undo
- **Nested deletes** (`N/NativeRecordDeletion.swift`): new `.property` and `.equipment` kinds. They plan a `customers` upsert, never a tombstone. Undo re-inserts the item in place only while its id is still absent and its customer (and property) still exist. `N/Components.swift` gained the two undo-banner icons. `N/NativeConfirmation.swift` gained the two delete intents.
- **Merge** (`N/NativeCustomerIdentity.swift`): the winner takes the union through `mergePlan`. Re-pointed jobs and recurring rules carry their `propertyId` through it, and undo is unchanged (exact restore).
- **Whitelists**: `duplicateJob` and `recurringJob(from:)` (`N/Domain/UIModelAdapters.swift`) and occurrences (`N/Domain/NativeRecurringJobs.swift`) carry `propertyId`. The UI `Job` gained `propertyId`, mapped through every job adapter.
- **Screens** (`N/NativePropertiesViews.swift`, with one-line insertions in shared files):
  - **Customer detail:** a "Properties" section after Contact (`N/CustomersView.swift`).
  - **Property detail:** address and label, notes, equipment (active, then "Past equipment"), "Add equipment", the job history linking into `JobDetailView`, Archive/Restore and Delete.
  - **Sheets:** the property editor (address lookup) and the equipment editor (type picker with "Other…", make, model, serial, optional local dates, warranty row, notes, Mark as removed/Restore, Delete).
  - **Job detail:** the Schedule address row shows the linked property's label (`NativeJobAddressRow`), and `NativeJobPropertySection` shows "Equipment at this property" with "Add equipment", or "Add as a property" (`N/JobsView.swift`).
  - **Job editor:** the "Property" picker, and a customer change clears `propertyId` (`N/JobsView.swift`).
- **Estimate**:
  - `AppStore.estimateReviewDraft` sets `NativeEstimateReviewDraft.serviceAddress`.
  - The review screen shows it (`N/NativeEstimateReview.swift`).
  - The PDF prints "SERVICE ADDRESS" under the customer block (`N/NativeEstimatePDF.swift`).
- **Search** (`N/NativeGlobalSearch.swift`): `search(…, customerEquipment:)` matches equipment serial and model and lands on the customer.
- **Warranty insight**:
  - The `NativeInsightKind.warrantyExpiring` selector runs right after `selectMaintenanceDue` (`N/Domain/NativeTodayInsights.swift`).
  - It is muteable with a 14-day snooze and a shield icon (`N/Domain/NativeInsightsCardPolicy.swift`).
  - `warranty_expiring` is added to the analytics `InsightKind` enum in both the embedded catalog (`N/NativeAnalytics.swift`) and the contract block (`docs/native-phase-11-platform-hardening-contract-decisions.md`). `catalogVersion` stays 1.
- **Diagnostics:** the property and equipment key names join the support report's safe decode-path keys (names only, never values).

### 8.3 Decisions where the spec was silent

1. **Caps and ids**
   - **Property cap:** 100 properties per customer (bounds the blob).
   - **Over-long text:** refused with a typed error, never cut. A custom equipment type is kept verbatim. Lead source caps its labels instead.
   - **Id checks:** ids must be non-empty, unique across properties and equipment (P2), and never the reserved `primary`. Ids are generated as `pr<ms>_<base36>`/`eq<ms>_<base36>`, but the format isn't enforced, so an id written by another client still validates.
   - **Implicit primary:** before materialization it uses the navigation id `primary`, which is never stored. A view never materializes it; the first write does.
2. **Materialization repair:**
   - With no primary, a new one goes first.
   - Extra primaries become ordinary properties, at their stored address or the customer's.
   - The primary drops any stored address or archive stamp, and moves to the front.
   - `primary: false` becomes absent.
3. **Addresses**
   - **Normalization:** lowercase, `.,#` dropped and whitespace collapsed, for every "same address" decision.
   - **Duplicate addresses:** add, edit and restore refuse an address that matches, after normalization, the customer's own address or another active property's.
   - **Primary's address:** the property editor shows it read-only ("Change it from Edit customer").
4. **Equipment types and counts**
   - **"Other…" with no text** stores the `other` preset, so the picker doesn't list Other twice. Custom types already used on any customer are offered again.
   - **Row count:** the equipment count on a property row is active items only.
5. **Job history**
   - **Archived jobs:** left out (routing refuses them).
   - **Customer match:** by id, or by normalized name as the customer detail's Jobs list does.
   - **Sort:** newest first by scheduled date, else the created date, then created time, then id.
   - **Archived property:** still lists its own history.
6. **P3 and "Add as a property"**
   - **Archived property:** doesn't resolve.
   - **"Add as a property" is offered** when the job has no `propertyId`, or one that names nothing on the customer (removed or merged away).
   - **Not offered** for a link to an archived property.
   - **Legacy primary match:** an unlinked job at the customer's address also shows "Equipment at this property".
7. **Job-editor pick**
   - **Matching the previous address:** the comparison is trimmed and case-sensitive, so a case change counts as a typed edit.
   - **Nothing picked yet:** the "previous" address is the primary's, so the address auto-filled from the customer still moves to the picked property.
   - **"Not set":** clears the link and keeps the address.
   - **Unresolved link:** stays selected until the owner picks again. The picker names it "Archived property" when the property is archived, and "Removed property" when it was deleted or merged away.
   - **Customer change:** clears the link.
8. **Merge**
   - **Comparison point:** the loser's address is compared with the winner's after the contact backfill, and a blank loser address counts as the same address.
   - **Converted primary:** keeps its id, label, notes and equipment. The loser's unlinked jobs and recurring rules at its address link to it.
   - **Same-address merge:**
     - Equipment is appended (the winner's first), and the winner primary's blank label and notes are filled.
     - Jobs linked to the loser's primary re-link to the winner's.
   - **Colliding ids:** re-minted and remapped. Caps are not enforced, so a merge never fails.
   - **Absent stays absent:** a loser with nothing stored at the same address leaves the winner's list untouched.
   - **Plain loser at a different address:** still becomes a property. The spec says the implicit primary becomes a non-primary.
9. **Warranty**
   - **Window:** today through today + 29 (30 local days, today included). Removed equipment, archived properties, archived customers and expired warranties are left out.
   - **Day math:** civil-day arithmetic on `YYYY-MM-DD`, never a `Date` parse. Today is `NativeCashBasis.ymd(now)`, and the editor's date pickers convert through `NativeCashBasis.parseLocalDate`/`ymd`.
   - **Insight id:** `warranty_expiring:<equipmentId>:<expires>`, so a corrected date resurfaces after a dismissal.
   - **Copy:** the title is the spec's first sentence, and the detail is "A good time to offer a maintenance plan."
   - **Mute consequence:** a mute applies after selection, so muting the soonest row hides the kind until it lifts. That is the spec's "at most one".
10. **Delete with undo:** added for a non-primary property and for an equipment entry made by mistake. Archive and "Mark as removed" stay the history-keeping path.
11. **Search:** includes removed equipment, so an old serial still finds its customer.
12. **Archive stamps:** use the local date (`dateOnlyString`), as customers and jobs do.
13. **Docs:**
   - **Release checklist:** no entry, because nothing needs applying or deploying.
   - **Roadmap row:** the `post-launch-feature-roadmap.md` row is left as is (the neighboring Phase 20 row is being edited on `feat/job-forms`).

### 8.4 Tests

**New suite:** `native/PropertiesEquipmentTests` (runner `native/run-properties-equipment-tests.sh`, registered in `native/run-all-domain-tests.sh`; TZ defaults to America/Phoenix). It has 312 checks covering every §5 item. The warranty boundary is pinned at 23:30 local on Oct 3 in Phoenix (already Oct 4 in UTC): a warranty ending that day still counts as "today", and after local midnight it drops out.

**Updated suites:**
- **CanonicalTests:** the rich fixture's customer gains properties and equipment with unknown keys and an explicit nested null; the job and recurring rule gain `propertyId`.
- **AdapterTests:** customer edits keep properties; the job `propertyId` projects, edits and clears; duplicate and recurring keep it.
- **CustomerIdentityTests:** merge union with shared ids, a different-address loser, and exact undo.
- **RecurringJobTests:** occurrences carry the rule's property.
- **GlobalSearchTests:** serial and model matches.
- **TodayInsightsTests:** the window, ties, and the order (after maintenance due, before the expense anomaly).
- **InsightMuteTests:** the 14-day snooze and the expiry-scoped id.
- **EstimatePDFTests:** the service address.
- **RecordDeletionTests:** nested delete and undo.
- **StoreIntegrationTests:** the AppStore API end to end.
- **Accessibility and layout audit inventories:** updated for the new view file.

**Final review (2026-10-03, after the build was resumed):** the diff was read once against §1–§5. One fix: the job-editor picker had labelled every unresolved link "Archived property", including one to a deleted property. It now says "Removed property" for those (8.3, item 7).

**Results (2026-10-03, final run after that fix, one runner at a time, TMPDIR in the session scratchpad):**
- **Scope:** every runner in `native/run-all-domain-tests.sh` that compiles a changed source or has a changed `main.swift`. That is 96 runners, the brief's required list among them. The three runners the owner runs in the final gate (`analytics-event`, `error-redaction`, `save-rollback`) were left out. The other 37 registered runners compile no changed file.
- **Passed:** 94 of 96, including:
  - `properties-equipment` (312 checks)
  - `store-integration`, which this time ran in full with the Mac unlocked; the Phase 21 block passed
  - `repository`, `migration-coordinator` and `legacy-reimport` (933 checks), which also passed this time
  - `canonical`, `adapter`, `snapshot`, `initial-sync`, `delta-sync`, `mutation-push`, `sync-coordinator`, `today-insights`, `customer-identity`, `record-deletion`, `recurring-job`, `global-search`, `insight-mute`, `estimate-pdf` and `phase10-qualification`
- **Known failures only:**
  - **`accessibility-audit`:** 1 of 1997 failed, the known `RootView.swift:234` `.borderedProminent`.
  - **`layout-metrics`:** 3 of 900 failed: the known six tabs, `CoachView.swift:68` Done, and the shortcut count (expected 54, got 53, unchanged).
- **Runner registration:** `sh native/check-runner-registration.sh` passed.
- **Fixture manifest:** `node scripts/parity-manifest.mjs --write` (136 runners), then `sh native/run-fixture-manifest-check.sh`: current.
- **Docs:** `sh native/run-doc-reference-check.sh`: 2364 references, 0 missing.
- **Release compile** (`xcodebuild … -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`): BUILD SUCCEEDED. Its only warnings are 4 that were already there, in `NativeChangeOrdersView.swift`.
