# Native Phase 1 — Domain Layer Evidence

Updated: 2026-09-06

## Completion status

Phase 1 is complete. The Swift target now has a canonical, loss-preserving data
boundary and tested domain rules for the migration's highest-risk calculations
and state transitions.

Implemented in `native/TradeReadyNative/Domain/FinancialDomain.swift`:

- Decimal-backed estimate calculations.
- Labor, emergency multiplier, materials and material markup.
- Travel, overhead, true margin, minimum fee, and tax.
- Direct costs with in-margin and pass-through policies.
- Non-taxable pass-through exclusion from the tax base.
- Legacy invoice fallback, partial payments, overpayments, and paid epsilon.
- Idempotent payment application, irreversible voids, chronological `paidAt`,
  and canonical ledger merge behavior.
- Percent/fixed deposits with remaining-balance clamping.

The invoice UI routes balance and status derivations through this domain layer.
Payment settlement advances linked invoiced jobs through the lifecycle rules,
and scheduling an approved job uses the scheduling transition rule.

## Golden verification

Run:

```sh
native/run-domain-tests.sh
```

The executable vectors in `native/DomainTests/main.swift` are transcribed from:

- `__tests__/pricingEngine.test.js`
- `__tests__/pricingEngineDirectCosts.test.js`
- `__tests__/paymentMathParity.test.js`
- `__fixtures__/paymentVectors.js`

Result on 2026-09-06:

```text
PASS: native financial domain golden tests
```

The complete native source also passes an iPhoneOS Swift type-check. The Xcode
verification boundary on this host is recorded below.

The React Native Jest comparison was attempted, but dependencies are absent in
this checkout (`jest: command not found`). Install the locked npm dependencies
before using the JavaScript suite as fresh runtime evidence.

## XCTest verification

`TradeReadyNativeTests` is an app-hosted XCTest target covering representative
canonical fixture round trips, pricing/payment rules, and non-financial rules.
Its three JSON fixtures are bundled as test resources. On this host, a generic
iPhoneOS `build-for-testing` succeeds when `Assets.xcassets` is excluded; normal
asset compilation and simulator execution remain blocked by the unavailable
CoreSimulator runtime. The complete production source separately passes an
iPhoneOS type-check with warnings treated as errors.

## Exit criteria evidence

- Rich, legacy, additive-forward, auxiliary, and full-snapshot fixtures decode
  and re-encode without losing meaningful fields, explicit nulls, or unknown
  additions.
- Golden rule suites match the React Native pricing, payment, tax,
  profitability, recurrence, lifecycle, numbering, archive, and identifier
  vectors.
- `AppStore` persists only `Canonical.Snapshot`; the smaller SwiftUI structs are
  transient projections/drafts merged back against canonical baselines.
- The React Native importer decodes all twelve plain-storage families directly
  into canonical models, including large manifest-backed values. The old flat
  native snapshot exists only as a decode-only upgrade shape.
- `native/run-all-domain-tests.sh`, warnings-as-errors iPhoneOS type-checking,
  and the generic-device XCTest `build-for-testing` gate pass on 2026-09-06.

## Canonical model integration boundary

The canonical wire models live in the `Canonical` namespace to keep their JSON
contract separate from the SwiftUI screen projections. `AppStore` owns a
`Canonical.Snapshot` as its sole persisted business-data source of truth;
adapters project only the fields current screens can edit and baseline-merge
those edits back without discarding unrepresented fields.

`CanonicalModels.swift` now covers every interface and alias in
`types/models.ts`, including persisted records, settings and its nested values,
draft/input shapes, AI pricing suggestions, and estimate result shapes. Run
`native/run-canonical-tests.sh` for semantic JSON round trips across rich,
legacy, forward-compatible, and auxiliary fixtures.

Raw records retain date/time strings and open string union values. Unknown
fields and explicit nulls survive decode/edit/encode, including inside nested
records. Additive settings fields use production-compatible defaults while
remembering their original absence, so an unchanged re-encode does not invent
fields in an older record.

The complete in-memory settings shape includes SecureStore fields. The plain
snapshot codec always removes `providerKey`, `anthropicKey`, and `groqKey`
before writing bytes. Phase 2 now imports and verifies those values in native
Keychain storage. All checked-in fixtures use synthetic values.

The initial preservation implementation converts individual fields through a
JSON representation. Profile large-account decoding before production storage
integration; fixture correctness alone is not performance evidence.

`UIModelAdapters.swift` now projects canonical customers, jobs, invoices,
payments, expenses, and settings into the existing SwiftUI forms and merges
edits back against an immutable canonical baseline. This preserves fields the
prototype UI cannot represent, including unknown additive values. Legacy paid
invoices retain their paid display state without inventing a ledger entry, and
the settings adapter never fabricates a backend-owned booking token.

## Canonical persistence snapshot

`CanonicalSnapshot.swift` defines a single consistency envelope for all twelve
plain-storage business families in the contract inventory: invoices, jobs,
customers, settings, expenses, customer notes, recurring jobs, recurring
invoices, trips, pricebook entries, booking requests, and job photos. `AppStore`
writes this envelope atomically and upgrades the earliest native flat snapshot
on read.

The current encoded shape is `{ "schemaVersion": 1, "payload": { ... } }`.
Unversioned flat aggregate snapshots remain decodable as schema 0 and are
upgraded to the current shape when encoded. Unknown envelope and payload fields
are retained, as is the distinction between an absent optional family and an
explicit `null`. Encoding uses sorted JSON keys to provide deterministic bytes.

Run the isolated fixture suite with:

```sh
native/run-snapshot-tests.sh
```

The fixtures cover legacy upgrade, current-version round trip, every persisted
family, unknown fields, explicit nulls, deterministic encoding, secure-field
redaction, and malformed envelope errors. Corruption recovery, migration
journaling, and Keychain migration are implemented in Phase 2; sync behavior
remains later work.

## Non-financial rules

The isolated rule layer in
`native/TradeReadyNative/Domain/BusinessRules.swift` now ports these production
behaviors without coupling them to the prototype screen models:

- Local-calendar recurrence for daily, weekly, monthly, quarterly, and annual
  cadences, including JavaScript's accepted month/day overflow behavior.
- Count/date/never end conditions and recurring-invoice resume fast-forwarding.
- Configurable invoice prefix, starting-number floor, legacy digit scanning,
  padding, and digit-bearing-prefix handling.
- The job lifecycle pipeline, estimate decisions, schedule advancement,
  deposit/final-invoice modes, paid-invoice advancement, and dunning eligibility.
- Optional-date soft archive semantics.
- Existing timestamp, counter, recurrence-link, and random-suffix ID formats,
  with same-millisecond collision protection where the React Native client has it.

Run the separate command-line golden suite with:

```sh
native/run-business-rules-tests.sh
```

Its vectors are transcribed from the focused React Native suites for recurrence,
invoice numbering, job status/dunning, archive behavior, and identifier formats.
The active native scheduling, invoice numbering, settlement, and paid-job paths
use these rules. Feature phases will attach the remaining isolated rules as
their corresponding screens are built.
