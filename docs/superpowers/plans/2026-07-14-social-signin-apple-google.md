# Sign in with Apple & Google — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Sign in with Apple and Sign in with Google to the auth screen, alongside the existing email/password flow, resolving each provider's identity token through Supabase `signInWithIdToken`.

**Architecture:** A new `utils/socialAuth.ts` owns both provider flows and returns a plain result object (`{ ok }` / `{ ok: false, cancelled?, error? }`) so `AuthScreen` can drive UI without knowing provider internals. Both flows end at `supabase.auth.signInWithIdToken`, which fires `SIGNED_IN`; the existing `AuthContext` listener handles session setup, sync, purchases, and analytics unchanged. `AuthScreen` gains an "or" divider + two buttons. All native modules are mocked in `jest.setup.js` so the gate stays green without a device.

**Tech Stack:** Expo SDK 54, React Native 0.81, React 19, TypeScript, `@supabase/supabase-js`, `expo-apple-authentication`, `@react-native-google-signin/google-signin`, `expo-crypto`, Jest + `@testing-library/react-native` v14.

## Global Constraints

- **Branch:** all work on `feat/social-signin` (already created).
- **Green gate is non-negotiable — never commit on red.** Every commit must pass all three: `npm run typecheck` (0 errors), `npm test` (all suites pass), `npm run lint` (runs with `--max-warnings=0`).
- **Dependencies added only via `npx expo install`** (SDK-54-pinned versions). The three packages below are owner-approved (2026-07-14); no others.
- **Bundle ID / package:** `com.gettradereadyapp.tradeready` (iOS + Android).
- **Cannot be verified in Expo Go** — social sign-in requires a native EAS build. In-session verification is limited to the Jest gate; on-device verification happens in Task 5.
- **RNTL v14 render is async** — every `render(...)` must be `await`ed.
- **iOS-first.** Apple button is iOS-only; Google is wired Android-ready but only tested on iOS now.

---

### Task 1: Add dependencies and native config

**Files:**
- Modify: `package.json` (via `expo install` — do not hand-edit versions)
- Modify: `app.json`

**Interfaces:**
- Produces: three installed packages (`expo-apple-authentication`, `@react-native-google-signin/google-signin`, `expo-crypto`); `app.json` `extra.googleWebClientId` and `extra.googleIosClientId` read later by `utils/socialAuth.ts`; the Google config plugin `iosUrlScheme` and `ios.usesAppleSignIn` consumed by the native build.

- [ ] **Step 1: Install the three approved packages**

Run:
```bash
npx expo install expo-apple-authentication @react-native-google-signin/google-signin expo-crypto
```
Expected: `package.json` gains the three deps with SDK-54-compatible versions; `package-lock.json` updates.

- [ ] **Step 2: Verify the gate is still green (nothing imports the new deps yet)**

Run:
```bash
npm run typecheck && npm test && npm run lint
```
Expected: typecheck 0 errors, all test suites pass, lint 0 warnings. (Installing unused deps must not change the gate.)

- [ ] **Step 3: Add the config plugins and Apple entitlement to `app.json`**

In `app.json`, add `"usesAppleSignIn": true` to the `ios` object:
```json
    "ios": {
      "supportsTablet": false,
      "bundleIdentifier": "com.gettradereadyapp.tradeready",
      "buildNumber": "1",
      "usesAppleSignIn": true,
      "infoPlist": {
        "ITSAppUsesNonExemptEncryption": false
      }
    },
```

Append to the `plugins` array (after `"expo-font"`):
```json
      "expo-font",
      "expo-apple-authentication",
      [
        "@react-native-google-signin/google-signin",
        {
          "iosUrlScheme": "com.googleusercontent.apps.REPLACE_WITH_REVERSED_IOS_CLIENT_ID"
        }
      ]
```

- [ ] **Step 4: Add the Google client-ID keys to `app.json` `extra`**

In the `extra` object, add these two keys (alongside the existing keys):
```json
      "googleWebClientId": "REPLACE_WITH_WEB_CLIENT_ID.apps.googleusercontent.com",
      "googleIosClientId": "REPLACE_WITH_IOS_CLIENT_ID.apps.googleusercontent.com",
```

> The three `REPLACE_WITH_*` values are **external OAuth client IDs supplied by the owner in Task 5** (Google Cloud Console). They are non-secret and safe to commit, matching the existing `extra` client-key convention. The app builds and the gate passes with the placeholders in place; only the on-device Google flow needs the real values, which Task 5 fills before the EAS build.

- [ ] **Step 5: Re-run the gate**

Run:
```bash
npm run typecheck && npm test && npm run lint
```
Expected: all green. (`app.json` is neither type-checked nor linted; tests mock `expo-constants`.)

- [ ] **Step 6: Commit**

```bash
git add package.json package-lock.json app.json
git commit -m "chore: add Apple/Google sign-in deps and native config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `utils/socialAuth.ts` — Apple & Google flows (TDD)

**Files:**
- Modify: `jest.setup.js` (add mocks for the three native modules; extend the Supabase mock)
- Test: `__tests__/socialAuth.test.js` (create)
- Create: `utils/socialAuth.ts`

**Interfaces:**
- Consumes: `supabase.auth.signInWithIdToken` from `utils/supabase`; `expo-apple-authentication`, `@react-native-google-signin/google-signin`, `expo-crypto`; `expo-constants` `extra.googleWebClientId` / `extra.googleIosClientId`.
- Produces:
  - `export type SocialAuthResult = { ok: true } | { ok: false; cancelled?: boolean; error?: string }`
  - `export async function signInWithApple(): Promise<SocialAuthResult>`
  - `export async function signInWithGoogle(): Promise<SocialAuthResult>`

- [ ] **Step 1: Add native-module mocks and extend the Supabase mock in `jest.setup.js`**

Add these three `jest.mock(...)` blocks to `jest.setup.js` (anywhere among the existing mocks):
```js
jest.mock("expo-apple-authentication", () => {
  const { View } = require("react-native");
  return {
    isAvailableAsync: jest.fn(() => Promise.resolve(true)),
    signInAsync: jest.fn(() =>
      Promise.resolve({ identityToken: "apple-id-token", fullName: null, email: null })
    ),
    AppleAuthenticationScope: { FULL_NAME: 0, EMAIL: 1 },
    AppleAuthenticationButtonType: { SIGN_IN: 0, CONTINUE: 1, SIGN_UP: 2 },
    AppleAuthenticationButtonStyle: { WHITE: 0, WHITE_OUTLINE: 1, BLACK: 2 },
    AppleAuthenticationButton: (props) => <View {...props} />,
  };
});

jest.mock("@react-native-google-signin/google-signin", () => ({
  GoogleSignin: {
    configure: jest.fn(),
    hasPlayServices: jest.fn(() => Promise.resolve(true)),
    signIn: jest.fn(() =>
      Promise.resolve({ type: "success", data: { idToken: "google-id-token" } })
    ),
  },
  statusCodes: {
    SIGN_IN_CANCELLED: "SIGN_IN_CANCELLED",
    IN_PROGRESS: "IN_PROGRESS",
    PLAY_SERVICES_NOT_AVAILABLE: "PLAY_SERVICES_NOT_AVAILABLE",
  },
}));

jest.mock("expo-crypto", () => ({
  digestStringAsync: jest.fn(() => Promise.resolve("hashed-nonce")),
  randomUUID: jest.fn(() => "11111111-1111-1111-1111-111111111111"),
  CryptoDigestAlgorithm: { SHA256: "SHA-256" },
}));
```

In the existing `@supabase/supabase-js` mock (`jest.setup.js`, the `auth` object around line 100), add one line so social sign-in has a default success:
```js
      signInWithPassword: jest.fn(),
      signInWithIdToken: jest.fn(() => Promise.resolve({ data: {}, error: null })),
      signOut: jest.fn(),
```

Also add the two Google keys to the `expo-constants` mock's `extra` (around line 9) so the config read is exercised:
```js
      backendUrl: "https://backend-tradeready1.vercel.app",
      backendUrlIsPlaceholder: false,
      googleWebClientId: "test-web.apps.googleusercontent.com",
      googleIosClientId: "test-ios.apps.googleusercontent.com",
      posthogApiKey: "PLACEHOLDER_POSTHOG_KEY",
      sentryDsn: "PLACEHOLDER_SENTRY_DSN",
```

- [ ] **Step 2: Write the failing tests**

Create `__tests__/socialAuth.test.js`:
```js
import { signInWithApple, signInWithGoogle } from "../utils/socialAuth";
import * as AppleAuthentication from "expo-apple-authentication";
import { GoogleSignin } from "@react-native-google-signin/google-signin";
import { supabase } from "../utils/supabase";

describe("signInWithApple", () => {
  beforeEach(() => jest.clearAllMocks());

  it("exchanges the Apple identity token with Supabase", async () => {
    const res = await signInWithApple();
    expect(AppleAuthentication.signInAsync).toHaveBeenCalled();
    expect(supabase.auth.signInWithIdToken).toHaveBeenCalledWith({
      provider: "apple",
      token: "apple-id-token",
      nonce: expect.any(String),
    });
    expect(res).toEqual({ ok: true });
  });

  it("returns cancelled when the user dismisses the Apple sheet", async () => {
    AppleAuthentication.signInAsync.mockRejectedValueOnce({ code: "ERR_REQUEST_CANCELED" });
    const res = await signInWithApple();
    expect(res).toEqual({ ok: false, cancelled: true });
    expect(supabase.auth.signInWithIdToken).not.toHaveBeenCalled();
  });

  it("surfaces a Supabase error message", async () => {
    supabase.auth.signInWithIdToken.mockResolvedValueOnce({ data: {}, error: { message: "bad token" } });
    const res = await signInWithApple();
    expect(res).toEqual({ ok: false, error: "bad token" });
  });
});

describe("signInWithGoogle", () => {
  beforeEach(() => jest.clearAllMocks());

  it("exchanges the Google id token with Supabase", async () => {
    const res = await signInWithGoogle();
    expect(GoogleSignin.hasPlayServices).toHaveBeenCalled();
    expect(supabase.auth.signInWithIdToken).toHaveBeenCalledWith({
      provider: "google",
      token: "google-id-token",
    });
    expect(res).toEqual({ ok: true });
  });

  it("returns cancelled when the user dismisses the Google sheet", async () => {
    GoogleSignin.signIn.mockRejectedValueOnce({ code: "SIGN_IN_CANCELLED" });
    const res = await signInWithGoogle();
    expect(res).toEqual({ ok: false, cancelled: true });
    expect(supabase.auth.signInWithIdToken).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```bash
npx jest socialAuth -t "signInWithApple"
```
Expected: FAIL — `Cannot find module '../utils/socialAuth'` (file not created yet).

- [ ] **Step 4: Implement `utils/socialAuth.ts`**

Create `utils/socialAuth.ts`:
```ts
import * as AppleAuthentication from "expo-apple-authentication";
import * as Crypto from "expo-crypto";
import { GoogleSignin, statusCodes } from "@react-native-google-signin/google-signin";
import Constants from "expo-constants";
import { supabase } from "./supabase";

const GOOGLE_WEB_CLIENT_ID: string = Constants.expoConfig?.extra?.googleWebClientId ?? "";
const GOOGLE_IOS_CLIENT_ID: string = Constants.expoConfig?.extra?.googleIosClientId ?? "";

export type SocialAuthResult =
  | { ok: true }
  | { ok: false; cancelled?: boolean; error?: string };

let googleConfigured = false;
function ensureGoogleConfigured(): void {
  if (googleConfigured) return;
  GoogleSignin.configure({
    webClientId: GOOGLE_WEB_CLIENT_ID,
    iosClientId: GOOGLE_IOS_CLIENT_ID,
  });
  googleConfigured = true;
}

export async function signInWithApple(): Promise<SocialAuthResult> {
  try {
    // Apple requires a hashed nonce in the request; the raw nonce is handed to
    // Supabase so it can verify the token's nonce claim.
    const rawNonce = `${Crypto.randomUUID()}${Crypto.randomUUID()}`;
    const hashedNonce = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      rawNonce
    );
    const credential = await AppleAuthentication.signInAsync({
      requestedScopes: [
        AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
        AppleAuthentication.AppleAuthenticationScope.EMAIL,
      ],
      nonce: hashedNonce,
    });
    if (!credential.identityToken) {
      return { ok: false, error: "Apple did not return an identity token." };
    }
    const { error } = await supabase.auth.signInWithIdToken({
      provider: "apple",
      token: credential.identityToken,
      nonce: rawNonce,
    });
    if (error) return { ok: false, error: error.message };
    return { ok: true };
  } catch (e: unknown) {
    const err = e as { code?: string; message?: string };
    if (err?.code === "ERR_REQUEST_CANCELED") return { ok: false, cancelled: true };
    return { ok: false, error: err?.message ?? "Apple sign-in failed." };
  }
}

export async function signInWithGoogle(): Promise<SocialAuthResult> {
  try {
    ensureGoogleConfigured();
    await GoogleSignin.hasPlayServices();
    const response = await GoogleSignin.signIn();
    const idToken = response?.data?.idToken ?? null;
    if (!idToken) {
      return { ok: false, error: "Google did not return an ID token." };
    }
    const { error } = await supabase.auth.signInWithIdToken({
      provider: "google",
      token: idToken,
    });
    if (error) return { ok: false, error: error.message };
    return { ok: true };
  } catch (e: unknown) {
    const err = e as { code?: string; message?: string };
    if (err?.code === statusCodes.SIGN_IN_CANCELLED) return { ok: false, cancelled: true };
    return { ok: false, error: err?.message ?? "Google sign-in failed." };
  }
}
```

> **Version check:** confirm the installed `@react-native-google-signin/google-signin` returns `{ data: { idToken } }` from `signIn()` (v13+ shape, matched above). If the installed version returns `{ idToken }` at the top level, adjust the read to `response?.idToken` and the mock in Step 1 to match.

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
npx jest socialAuth
```
Expected: PASS (5 tests).

- [ ] **Step 6: Typecheck and lint**

Run:
```bash
npm run typecheck && npm run lint
```
Expected: 0 errors, 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add jest.setup.js __tests__/socialAuth.test.js utils/socialAuth.ts
git commit -m "feat: add Apple and Google sign-in via Supabase signInWithIdToken

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: AuthScreen — divider + Apple/Google buttons (TDD)

**Files:**
- Test: `__tests__/AuthScreen.test.tsx` (create)
- Modify: `screens/AuthScreen.tsx`

**Interfaces:**
- Consumes: `signInWithApple`, `signInWithGoogle` from `utils/socialAuth`; `AppleAuthentication` (button + `isAvailableAsync`); `useTheme().isDark`; existing `track`, `friendlyAuthError`.
- Produces: a Google button labelled `"Continue with Google"` (all platforms) and an Apple button wrapped in a `testID="apple-signin-button"` view (iOS, once available).

- [ ] **Step 1: Write the failing test**

Create `__tests__/AuthScreen.test.tsx`:
```tsx
import React from "react";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import AuthScreen from "../screens/AuthScreen";
import { signInWithGoogle } from "../utils/socialAuth";

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }) => children,
}));

jest.mock("../utils/socialAuth", () => ({
  signInWithApple: jest.fn(() => Promise.resolve({ ok: true })),
  signInWithGoogle: jest.fn(() => Promise.resolve({ ok: true })),
}));

describe("AuthScreen social sign-in", () => {
  beforeEach(() => jest.clearAllMocks());

  it("renders the Google button and triggers Google sign-in on press", async () => {
    const { getByLabelText } = await render(<AuthScreen />);
    fireEvent.press(getByLabelText("Continue with Google"));
    await waitFor(() => expect(signInWithGoogle).toHaveBeenCalledTimes(1));
  });

  it("shows the Apple button on iOS once availability resolves", async () => {
    const { findByTestId } = await render(<AuthScreen />);
    expect(await findByTestId("apple-signin-button")).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
npx jest AuthScreen
```
Expected: FAIL — `Unable to find an element with accessibilityLabel: Continue with Google` (buttons not built yet).

- [ ] **Step 3: Implement the AuthScreen changes**

In `screens/AuthScreen.tsx`:

(a) Add imports near the top (after the existing `friendlyAuthError` import):
```tsx
import * as AppleAuthentication from 'expo-apple-authentication';
import { signInWithApple, signInWithGoogle } from '../utils/socialAuth';
```

(b) Add `isDark` to the theme destructure (line ~38):
```tsx
  const { colors, shadow, isDark } = useTheme();
```

(c) Add state next to the other `useState` hooks (after `resending`, line ~55):
```tsx
  const [appleAvailable, setAppleAvailable] = useState(false);
  const [socialBusy, setSocialBusy] = useState<null | 'apple' | 'google'>(null);
```

(d) Add an availability effect (after the existing cooldown `useEffect`, line ~67):
```tsx
  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    let active = true;
    AppleAuthentication.isAvailableAsync().then(v => { if (active) setAppleAvailable(v); });
    return () => { active = false; };
  }, []);
```

(e) Add the two handlers (after `handleResend`, before `toggle`):
```tsx
  async function handleApple() {
    setError('');
    setSocialBusy('apple');
    const res = await signInWithApple();
    setSocialBusy(null);
    if (res.ok) { track('sign_in', { method: 'apple' }); return; }
    if (!res.cancelled) setError(friendlyAuthError(res.error ?? ''));
  }

  async function handleGoogle() {
    setError('');
    setSocialBusy('google');
    const res = await signInWithGoogle();
    setSocialBusy(null);
    if (res.ok) { track('sign_in', { method: 'google' }); return; }
    if (!res.cancelled) setError(friendlyAuthError(res.error ?? ''));
  }
```

(f) Add the social section JSX immediately after the closing `</View>` of the `card` (line ~265), before the `pendingConfirmEmail` resend block:
```tsx
        {mode !== 'forgot' && (
          <View style={styles.socialSection}>
            <View style={styles.dividerRow}>
              <View style={styles.dividerLine} />
              <Text style={styles.dividerText}>or</Text>
              <View style={styles.dividerLine} />
            </View>

            {appleAvailable && (
              <View testID="apple-signin-button" style={styles.appleWrap}>
                <AppleAuthentication.AppleAuthenticationButton
                  buttonType={AppleAuthentication.AppleAuthenticationButtonType.CONTINUE}
                  buttonStyle={
                    isDark
                      ? AppleAuthentication.AppleAuthenticationButtonStyle.WHITE
                      : AppleAuthentication.AppleAuthenticationButtonStyle.BLACK
                  }
                  cornerRadius={radius.md}
                  style={styles.appleBtn}
                  onPress={handleApple}
                />
              </View>
            )}

            <TouchableOpacity
              style={styles.googleBtn}
              onPress={handleGoogle}
              disabled={socialBusy !== null}
              activeOpacity={0.85}
              accessibilityRole="button"
              accessibilityLabel="Continue with Google"
              accessibilityState={{ disabled: socialBusy !== null, busy: socialBusy === 'google' }}
            >
              {socialBusy === 'google' ? (
                <ActivityIndicator color={colors.textPrimary} />
              ) : (
                <>
                  <Ionicons name="logo-google" size={18} color="#4285F4" style={styles.googleIcon} />
                  <Text style={styles.googleBtnText}>Continue with Google</Text>
                </>
              )}
            </TouchableOpacity>
          </View>
        )}
```

(g) Add these styles to the `createStyles` `StyleSheet.create({ ... })` block:
```tsx
    socialSection: { marginTop: spacing.lg },
    dividerRow: { flexDirection: 'row', alignItems: 'center', marginBottom: spacing.md },
    dividerLine: { flex: 1, height: 1, backgroundColor: colors.border },
    dividerText: { marginHorizontal: spacing.md, color: colors.textMuted, fontSize: fontSize.sm },
    appleWrap: { marginBottom: spacing.sm },
    appleBtn: { height: 48, width: '100%' },
    googleBtn: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: spacing.sm,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      paddingVertical: 12,
    },
    googleIcon: {},
    googleBtnText: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '600' },
```

> The Google "G" uses the already-imported `Ionicons` `logo-google` glyph in Google blue — dependency-free and review-safe on a neutral button. For strict multicolor-logo brand compliance the owner may later swap in Google's official asset; the icon is an acceptable interim mark.

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
npx jest AuthScreen
```
Expected: PASS (2 tests). `Platform.OS` defaults to `ios` under jest-expo, so `isAvailableAsync` (mocked true) makes the Apple button appear.

- [ ] **Step 5: Typecheck, lint, and full test run**

Run:
```bash
npm run typecheck && npm test && npm run lint
```
Expected: all green across the whole suite.

- [ ] **Step 6: Commit**

```bash
git add screens/AuthScreen.tsx __tests__/AuthScreen.test.tsx
git commit -m "feat: add Apple & Google sign-in buttons to AuthScreen

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `sign_in` analytics for the password path

**Files:**
- Modify: `screens/AuthScreen.tsx` (the `mode === 'login'` branch of `handleSubmit`)
- Modify: `__tests__/AuthScreen.test.tsx` (add one assertion)

**Interfaces:**
- Consumes: existing `track` from `utils/analytics`; `supabase.auth.signInWithPassword` (mocked).
- Produces: a `track('sign_in', { method: 'password' })` call on successful email/password login, giving all three sign-in methods a uniform `sign_in` event.

- [ ] **Step 1: Add the failing assertion**

Append to `__tests__/AuthScreen.test.tsx` inside the existing `describe`:
```tsx
  it("tracks a password sign_in event on successful email login", async () => {
    const analytics = require("../utils/analytics");
    const trackSpy = jest.spyOn(analytics, "track");
    const { supabase } = require("../utils/supabase");
    supabase.auth.signInWithPassword.mockResolvedValueOnce({ data: {}, error: null });

    const { getByLabelText, getByRole } = await render(<AuthScreen />);
    fireEvent.changeText(getByLabelText("Email address"), "a@b.com");
    fireEvent.changeText(getByLabelText("Password"), "secret1");
    fireEvent.press(getByRole("button", { name: "Sign In" }));

    await waitFor(() =>
      expect(trackSpy).toHaveBeenCalledWith("sign_in", { method: "password" })
    );
  });
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
npx jest AuthScreen -t "password sign_in"
```
Expected: FAIL — `track` not called with `sign_in`.

- [ ] **Step 3: Implement**

In `screens/AuthScreen.tsx`, in `handleSubmit`, add the track call right after the successful password login (inside the `if (mode === 'login')` block, after the `if (error) throw error;`):
```tsx
      if (mode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) throw error;
        track('sign_in', { method: 'password' });
      } else {
```

- [ ] **Step 4: Run to verify it passes**

Run:
```bash
npx jest AuthScreen
```
Expected: PASS (3 tests).

- [ ] **Step 5: Full gate + commit**

```bash
npm run typecheck && npm test && npm run lint
git add screens/AuthScreen.tsx __tests__/AuthScreen.test.tsx
git commit -m "feat: track sign_in event for email/password login

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: External configuration + real client IDs + on-device verification (owner-executed)

> This task has no automated test — it wires the provider dashboards, replaces the `app.json` placeholders with real IDs, cuts an EAS build, and runs the on-device matrix. It cannot be done from the dev session; the owner performs the dashboard steps.

**Files:**
- Modify: `app.json` (replace the three `REPLACE_WITH_*` placeholders with real values)

- [ ] **Step 1: Apple Developer (developer.apple.com)**
  - App ID `com.gettradereadyapp.tradeready` → enable the **Sign in with Apple** capability.
  - Create a **Services ID** (used to generate the Supabase client secret).
  - Create a **Sign in with Apple Key** (`.p8`); record **Key ID**, **Team ID**, and download the key.

- [ ] **Step 2: Google Cloud Console (console.cloud.google.com)**
  - Configure the **OAuth consent screen** (External): app name, support email, logo, and the existing legal URLs (`privacy.html` / `terms.html` from `app.json` `extra`).
  - Create an **iOS OAuth client** (bundle ID `com.gettradereadyapp.tradeready`) → record the **iOS client ID** and its reversed form `com.googleusercontent.apps.<iOS client ID>`.
  - Create a **Web OAuth client** → record the **Web client ID and secret**.

- [ ] **Step 3: Supabase dashboard → Authentication → Providers**
  - **Apple:** enable; set the authorized **Client ID** to the bundle ID `com.gettradereadyapp.tradeready`; provide the client secret generated from the Services ID + `.p8` key + Team ID + Key ID.
  - **Google:** enable; set **Client ID / Secret** to the **Web** OAuth client; add the **iOS client ID** to **Authorized Client IDs** so native iOS idTokens are accepted.

- [ ] **Step 4: Replace the `app.json` placeholders with the real values**
  - `plugins` → Google plugin `iosUrlScheme` → `com.googleusercontent.apps.<iOS client ID>`
  - `extra.googleWebClientId` → `<Web client ID>.apps.googleusercontent.com`
  - `extra.googleIosClientId` → `<iOS client ID>.apps.googleusercontent.com`
  - Run `npm run typecheck && npm test && npm run lint` (still green), then commit:
    ```bash
    git add app.json
    git commit -m "chore: real Apple/Google OAuth client IDs for social sign-in

    Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
    ```

- [ ] **Step 5: Cut an EAS build and run the on-device verification matrix**
  - Build (bump `ios.buildNumber` first per release convention): `eas build --platform ios --profile <production/preview>`; install via TestFlight or a dev build.
  - Verify on device:
    - Apple: new user → account created; returning user → same account; cancel mid-prompt → no error banner, no session.
    - Google: new user; returning user; cancel mid-prompt → silent.
    - **Same-email linking (spec §7):** sign up with `x@gmail.com` (password), then Google-sign-in with the same address → confirm a **single** account / one `__dataOwner`, not two.
    - Sign out (Settings) → sign back in via each provider → data continuity intact.
    - Dark mode: Apple button style flips (WHITE on dark, BLACK on light); Google button legible in both themes.

---

## Self-Review

**Spec coverage** (against `2026-07-14-social-signin-apple-google-design.md`):
- §2 UI (divider, Apple iOS-only + availability, Google all-platforms, hidden in forgot, themed) → Task 3 ✅
- §3 `utils/socialAuth.ts` (Apple nonce flow, Google idToken, AuthContext unchanged) → Task 2 ✅ (AuthContext deliberately untouched)
- §4 deps + app.json (3 packages, 2 plugins, `usesAppleSignIn`, 2 extra keys) → Task 1 ✅
- §5 external config (Apple / Google / Supabase) → Task 5 ✅
- §6 analytics (`sign_in` + `method` for apple/google/password) → Tasks 3 & 4 ✅
- §7 account linking (verify single account) → Task 5 Step 5 ✅
- §8 testing (mocks for 3 modules + supabase `signInWithIdToken`; socialAuth unit tests; AuthScreen render test; on-device matrix) → Tasks 2, 3, 5 ✅
- §10 file summary → every listed file appears in a task ✅

**Placeholder scan:** the only placeholders are the three `REPLACE_WITH_*` external OAuth client IDs, which are legitimately owner-supplied credentials filled in Task 5 (documented, not vague implementation gaps). No `TODO`/`TBD`/"handle edge cases"/"similar to Task N" in any step; all code steps show complete code.

**Type consistency:** `SocialAuthResult` and `signInWithApple`/`signInWithGoogle` signatures are defined in Task 2 and consumed with matching shapes (`res.ok`, `res.cancelled`, `res.error`) in Task 3. `track('sign_in', { method })` uses the `track(event, properties)` signature from `utils/analytics.ts`. The Google `signIn()` return shape (`response.data.idToken`) is used consistently in the mock (Task 2 Step 1) and implementation (Task 2 Step 4), with an explicit version-check note.
