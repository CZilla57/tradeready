# Settings — business address & logo editing

**Date:** 2026-07-30
**Branch:** `feat/settings-business-profile`
**Status:** design approved, awaiting implementation plan

## Problem

The Settings screen's "Your business" section lets the user edit business name,
contact name, phone, email, payment instructions, region and trade — but not their
**business address** or **logo**. Both are collected during onboarding
(`screens/OnboardingScreen.tsx`, step 1) and nowhere else.

A user who skipped or rushed those two onboarding inputs has no way to supply them
later, and no way to correct or replace them. The logo is the more visible loss: it
renders on invoice PDFs (`utils/invoicePdfFile.ts:49`), so "add my logo to my
invoices" is currently a one-shot, onboarding-only opportunity.

## What already exists

This is a missing editing surface, not a missing feature. The whole data path is
built:

| Piece | Location | State |
|---|---|---|
| `address: string` on Settings | `types/models.ts:323` | exists |
| `logoPhoto?: string` on Settings | `types/models.ts:325` | exists |
| Defaults | `utils/storage/defaults.ts` | exists |
| Persistence + sync | `saveSettings` / settings sync | exists, shape-complete |
| Logo consumed on invoice PDF | `utils/invoicePdfFile.ts:49` | exists |
| Collection UI | `screens/OnboardingScreen.tsx` | onboarding only |
| **Editing UI** | `screens/SettingsScreen.tsx` | **missing — this spec** |

Both fields are already initialized in `utils/storage/defaults.ts` (`address: ""` at
:205, `logoPhoto: ""` at :207), so existing users already carry the keys.

Consequently: **no data-shape change, no migration, no storage change, no sync
change, no PDF change.** Scope is confined to `screens/SettingsScreen.tsx` plus
tests.

**New imports only, no new dependencies.** `SettingsScreen.tsx` currently imports
none of `expo-image`, `expo-image-picker`, or `utils/photoStorage`; the
implementation adds all three. Every one is already a project dependency in active
use by `OnboardingScreen.tsx`, so Rule 3 (no dependency changes without approval)
is not engaged — `package.json` is untouched.

## Design

### 1. Address field

A single `Field`, inserted in the "Your business" card after Email and before
Payment instructions — mirroring onboarding's name → phone → email → address order.

```tsx
<Field label="Business address" value={s.address}
       onChangeText={(v) => update("address", v)}
       multiline autoCapitalize="words" colors={colors} shadow={shadow} />
```

Plain text entry. **No address autocomplete** — none exists in this app, and adding
one is out of scope.

One deliberate difference from onboarding: onboarding's address field
(`OnboardingScreen.tsx:341`) sets no `autoCapitalize`, so it inherits RN's `sentences`
default and capitalizes only the first letter ("123 Main st, austin"). Settings
specifies `words`, which suits a street address. `SettingsScreen`'s local `Field`
wrapper already accepts both `multiline` and `autoCapitalize`
(`SettingsScreen.tsx:875-884`), so no component change is needed.

**No Region auto-derive.** Onboarding runs `regionFromAddress(form.address)` to
prefill `region` when leaving the business step, because that step has no region
input. Settings already exposes Region as its own editable field in the same card, so
deriving it from an address edit would silently overwrite a value the user can see
and may have set deliberately. Deliberate divergence from onboarding.

### 2. Logo picker

Placed at the **end** of the "Your business" card, after the trade grid — see §4 for
why position matters. Reuses onboarding's interaction exactly:

- Three-way `Alert`: Take Photo / Choose from Library / Cancel.
- Per-branch permission checks (`requestCameraPermissionsAsync`,
  `requestMediaLibraryPermissionsAsync`) with the same "Permission needed" alerts.
- `mediaTypes: ["images"]`, `quality: 0.8`.
- `persistPhoto(uri, "logos")` to copy the picked file into app storage.
- 80pt round thumbnail via `expo-image`; dashed round placeholder with 📷 when unset.
- "Remove" text button beneath the thumbnail when a logo is set.

### 3. Draft-then-save semantics

The Settings screen holds all edits in local state `s` and commits only on "Save
settings", with an unsaved-edits guard on blur (`SettingsScreen.tsx:100-120`). The
logo picker has filesystem side effects, so it must be reconciled with that contract
rather than bypassing it.

**Decision (owner, 2026-07-30): the logo behaves like every other field — draft
until Save.** Onboarding's immediate-delete behavior is NOT carried over.

| Action | Effect |
|---|---|
| Pick | `persistPhoto` copies the file in, then `update("logoPhoto", uri)`. Draft only. Any previously-referenced path is recorded in a pending-deletion ref. |
| Remove | `update("logoPhoto", "")` **only — no `deletePhoto` call.** |
| Save (success) | Delete every pending path that is not the just-saved `logoPhoto`. |
| Discard / leave dirty | Delete newly-copied files the draft abandoned; never delete a path the *saved* settings still reference. Clear the pending set. |

The rule that makes this safe: **`deletePhoto` is only ever called on a path that the
persisted settings no longer reference.**

Why not immediate-apply: it would give one screen two different save rules, and
"Remove logo → Discard" would silently destroy the image while the saved settings
still pointed at it — an unrecoverable loss from a button labelled Discard.

**The unsaved-edits guard needs no changes.** `settingsEqual`
(`utils/settingsDirty.ts:8`) is a generic recursive deep-equal over defined keys, so
`address` and `logoPhoto` become dirty-tracked automatically.

### 4. Multiline layout fix

`SettingsScreen.tsx:906` styles multiline inputs with a **fixed** `height: 80`.
Onboarding hit and fixed the consequence of that on device
(`OnboardingScreen.tsx:776-779`, 2026-07-14):

> minHeight (not height): a fixed height fought BaseField's multiline sizing — the
> address input painted taller than its layout box and the logo section rendered on
> top of it (device finding, 2026-07-14).

Settings escapes this today only because its one multiline field (Payment
instructions) has no logo beneath it. Adding a multiline address *and* a logo block
to the same card makes the bug reachable again.

**Two mitigations, both applied:**

1. `inputMultiline` changes `height: 80` → `minHeight: 80`, carrying the onboarding
   fix forward. This also affects the existing Payment instructions field — a latent
   fix, flagged and owner-approved (2026-07-30) rather than applied silently.
2. The logo block sits at the end of the card, not adjacent to the address input, so
   the overlap geometry does not arise even if the sizing regresses.

## Testing

**Unit (`__tests__/`)** — the file-lifecycle logic is the part with a data-loss edge,
so it carries the test weight:

- Save commits the new logo and deletes the replaced file.
- Save with no logo change deletes nothing.
- Remove → Save clears `logoPhoto` and deletes the old file.
- Remove → Discard deletes nothing and leaves the saved path intact.
- Pick → Discard deletes the newly-copied orphan, not the saved logo.
- `settingsEqual` reports dirty for an `address` edit and for a `logoPhoto` change.

**Render** — both controls appear in "Your business"; typing an address updates the
draft; the logo thumbnail renders when set and the placeholder when not.

**Device smoke (cannot be covered by Jest)** — camera and library branches with real
permission prompts; address-then-logo layout on a physical device (the 2026-07-14 bug
only ever manifested on hardware, never in tests).

## Out of scope

- Address autocomplete / geocoding.
- Logo cropping, rotation or size validation.
- Showing the logo anywhere new (estimates, emails, app header) — PDF-only today.
- Region auto-derive in Settings (see §1).
- Backfilling `address`/`logoPhoto` for existing users.

## Risks

| Risk | Mitigation |
|---|---|
| Mishandled file lifecycle destroys a user's logo | The single rule in §3, plus five unit tests covering each branch |
| Multiline sizing bug returns on device | §4: both the `minHeight` fix and logo placement |
| `minHeight` change alters Payment instructions field | Owner-approved; visually it can only grow to fit content, not shrink |
| Orphaned files accumulate in `logos/` | Pending-deletion set covers both the save and discard paths |
