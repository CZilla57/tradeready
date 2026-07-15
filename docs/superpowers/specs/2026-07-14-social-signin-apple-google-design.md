# Design: Sign in with Apple & Google

**Date:** 2026-07-14
**Status:** Approved (design); implementation pending
**Author:** owner + Claude
**Ships in:** Build #2 (fast-follow after the iOS launch build). Native change — **not** OTA-compatible; requires a fresh EAS build.

---

## 1. Goal & scope

Add **Sign in with Apple** and **Sign in with Google** as options *alongside* the
existing email/password flow. Nothing about email/password is removed or changed.

- **Platform priority:** iOS-first (matches the launch decision — no Android device
  available for testing). Google is wired to be Android-ready, but only tested on iOS
  for now. Apple sign-in is inherently iOS-only.
- **Why both, together:** App Store Guideline 4.8 requires that any app offering a
  *social* login (Google) also offer Sign in with Apple. Shipping Google without
  Apple would risk rejection. Email/password alone does not trigger 4.8; adding Google
  does. Bundling both is the correct iOS posture.

### Non-goals
- No custom account-linking UI (rely on Supabase's default email-based identity linking — see §7).
- No change to `AuthContext`, sync, or the `__dataOwner` guard.
- No Android store submission in this work (deferred).
- No web sign-in changes.

---

## 2. UI — `screens/AuthScreen.tsx`

Below the existing email/password `card`, add an **"or" divider** and two buttons.
Shown in `login` and `signup` modes; **hidden in `forgot` mode**.

- **Apple button** — rendered only when `Platform.OS === 'ios'` **and**
  `AppleAuthentication.isAvailableAsync()` resolves true (async check stored in state).
  Uses Apple's official `AppleAuthentication.AppleAuthenticationButton` component.
  Apple *requires* their branded button; a custom-styled Apple button risks rejection.
  Use `buttonStyle` that adapts to the current theme (WHITE / WHITE_OUTLINE for light,
  BLACK for dark).
- **Google button** — custom `TouchableOpacity` following Google's branding
  guidelines (official multi-color "G" mark, correct wordmark, neutral surface,
  minimum touch target 44pt). Rendered on all platforms.

Both buttons show a spinner / disabled state while their request is in flight, and
route failures through the existing `friendlyAuthError` + inline `errorText` UI. A
user-cancelled Apple/Google prompt is **silent** (no error banner).

Styling follows the screen's existing `createStyles(colors, shadow)` + `useMemo`
pattern — no new theming primitives.

---

## 3. Auth logic — new `utils/socialAuth.ts`

Two exported async functions. Both terminate in Supabase's `signInWithIdToken`, which
establishes a session and fires `SIGNED_IN` — the existing `AuthContext` listener does
the rest.

### `signInWithApple()`
1. Generate a cryptographically random raw nonce.
2. SHA-256 hash it (`expo-crypto` `digestStringAsync`).
3. `AppleAuthentication.signInAsync({ requestedScopes: [FULL_NAME, EMAIL], nonce: hashedNonce })`.
4. `supabase.auth.signInWithIdToken({ provider: 'apple', token: credential.identityToken, nonce: rawNonce })`.
5. On `ERR_REQUEST_CANCELED`, return quietly (treated as user cancel, not an error).

Note: Apple returns the user's name/email **only on first authorization**. We capture
what's available but do not depend on it (email is always present in the identity token
claims that Supabase reads).

### `signInWithGoogle()`
1. `GoogleSignin.configure({ webClientId, iosClientId })` (from `app.json` `extra`).
2. `await GoogleSignin.hasPlayServices()` (Android; no-op benign on iOS).
3. `const { data } = await GoogleSignin.signIn()` → read `data.idToken`.
4. `supabase.auth.signInWithIdToken({ provider: 'google', token: idToken })`.
5. On `statusCodes.SIGN_IN_CANCELLED`, return quietly.

### `AuthContext` — **no changes**
`context/AuthContext.tsx`'s `onAuthStateChange` handler already runs `loginPurchases`,
`initialSync` (with the `__dataOwner` guard), notifications, and `identifyUser` on
`SIGNED_IN`. A social login is just another way to arrive at a session; it reuses the
same path. This is a deliberate invariant of the design — the new code produces a
Supabase session and stops.

---

## 4. Dependencies & native config (⚠️ owner-approved 2026-07-14)

Install via `npx expo install` so versions are pinned to SDK 54 compatible ranges:

| Package | Purpose |
|---|---|
| `expo-apple-authentication` | Apple sign-in API, branded button, entitlement config plugin |
| `@react-native-google-signin/google-signin` | Native Google account picker → idToken; includes config plugin |
| `expo-crypto` | SHA-256 hashing for the Apple nonce |

### `app.json` changes
- Add to `plugins`:
  - `"expo-apple-authentication"`
  - `["@react-native-google-signin/google-signin", { "iosUrlScheme": "<REVERSED_IOS_CLIENT_ID>" }]`
- Add `"usesAppleSignIn": true` under `ios`.
- Add under `extra`:
  - `"googleWebClientId": "<WEB_CLIENT_ID>.apps.googleusercontent.com"`
  - `"googleIosClientId": "<IOS_CLIENT_ID>.apps.googleusercontent.com"`

Values are non-secret OAuth client IDs (safe to commit, consistent with the existing
`extra` keys). The reversed iOS client ID is `com.googleusercontent.apps.<IOS_CLIENT_ID>`.

---

## 5. External configuration checklist (owner performs; I can't from here)

### A. Apple Developer (developer.apple.com)
1. App ID `com.gettradereadyapp.tradeready` → enable **Sign in with Apple** capability.
2. Create a **Services ID** (used by Supabase for the client secret).
3. Create a **Sign in with Apple Key** (`.p8`) → record **Key ID**, **Team ID**, and the key file.

### B. Google Cloud Console (console.cloud.google.com)
1. Configure the **OAuth consent screen** (external, app name, support email, logo, privacy/terms URLs — reuse existing GitHub Pages legal URLs).
2. Create an **iOS OAuth client ID** (bundle ID `com.gettradereadyapp.tradeready`)
   → yields the **iOS client ID** and its reversed form for the URL scheme.
3. Create a **Web OAuth client ID** → yields the **Web client ID + secret** (used both
   as `webClientId` in the app and as Supabase's Google provider credentials).

### C. Supabase dashboard → Authentication → Providers
1. **Apple:** enable; set authorized **Client ID** = bundle ID `com.gettradereadyapp.tradeready`;
   provide the generated client secret (from the Services ID + `.p8` key + Team/Key IDs).
2. **Google:** enable; set **Client ID / secret** = the **Web** OAuth client; add the
   **iOS client ID** to **Authorized Client IDs** (comma-separated) so native iOS
   idTokens are accepted.

The implementation plan will restate this as an ordered, copy-paste runbook with the
exact field names.

---

## 6. Analytics

- Add `sign_in` event with a `method` property (`'apple' | 'google' | 'password'`),
  tracked via the existing `utils/analytics.ts` `track()`.
- Keep the existing `sign_up` event for the email flow. Social first-time sign-ups are
  not separately distinguished in v1 (Supabase's `signInWithIdToken` does not cleanly
  signal new-vs-returning without an extra round trip — out of scope).

---

## 7. Account linking (known behavior)

If a user previously created an email/password account with, e.g., `x@gmail.com`, and
later taps **Sign in with Google** for the same verified address, Supabase links them
into a **single** account by verified email (its default identity-linking behavior). We
rely on this default and build no custom linking. **To verify on the first EAS build:**
confirm the same-email case resolves to one account and one `__dataOwner`, not two.

---

## 8. Testing & the green gate

**Cannot be tested in Expo Go** (native modules). Verified only on an EAS dev/preview
build or TestFlight.

To keep `typecheck / tests / lint` green (the non-negotiable gate):
- Add Jest mocks in `jest.setup.js` for:
  - `expo-apple-authentication` (`isAvailableAsync`, `signInAsync`, `AppleAuthenticationButton` as a `View`, scope/button enums).
  - `@react-native-google-signin/google-signin` (`GoogleSignin.configure/hasPlayServices/signIn`, `statusCodes`).
  - `expo-crypto` (`digestStringAsync`, `CryptoDigestAlgorithm`, random bytes helper).
- Extend the existing `@supabase/supabase-js` mock (`jest.setup.js:99`) with
  `signInWithIdToken: jest.fn()`.
- Add a unit test for `utils/socialAuth.ts` (mocked deps): success path calls
  `signInWithIdToken` with the right provider/token; cancel path returns quietly.
- Update/extend the `AuthScreen` test if one exists, so the added buttons don't break rendering.

Manual on-device (EAS build) verification matrix:
- Apple: new user, returning user, cancel mid-prompt.
- Google: new user, returning user, cancel mid-prompt.
- Same-email cross-provider linking (§7).
- Sign out → sign back in via each provider (data continuity via `__dataOwner`).

---

## 9. Effort

- **Code + mocks + tests:** ~1 focused dev session.
- **External config:** the longer pole — Apple Developer + Google Cloud + Supabase
  dashboard, plus one EAS build to test. Mostly clicking, gated on Apple/Google review
  of the OAuth consent screen (usually fast for a login scope).

---

## 10. File-level change summary

| File | Change |
|---|---|
| `utils/socialAuth.ts` | **new** — `signInWithApple()`, `signInWithGoogle()` |
| `screens/AuthScreen.tsx` | add divider + Apple/Google buttons + handlers + availability state |
| `app.json` | 2 plugins, `ios.usesAppleSignIn`, 2 `extra` client IDs |
| `package.json` | +3 deps (via `expo install`) |
| `jest.setup.js` | mocks for the 3 native modules; extend supabase mock with `signInWithIdToken` |
| `utils/analytics.ts` | (usage only) `sign_in` event with `method` |
| `__tests__/socialAuth.test.js` | **new** — unit tests for the two functions |
