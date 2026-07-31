import * as AppleAuthentication from "expo-apple-authentication";
import Constants from "expo-constants";
import { supabase } from "./supabase";

const GOOGLE_WEB_CLIENT_ID: string = Constants.expoConfig?.extra?.googleWebClientId ?? "";
const GOOGLE_IOS_CLIENT_ID: string = Constants.expoConfig?.extra?.googleIosClientId ?? "";

export type SocialAuthResult =
  | { ok: true }
  | { ok: false; cancelled?: boolean; error?: string };

// Lazy-require so Expo Go (and bare Jest) don't crash on the unlinked native
// module. Unlike react-native-purchases (see utils/subscription.ts, the
// pattern this mirrors), the failure mode here isn't just Expo Go: both
// packages throw at MODULE-EVALUATION time when statically imported and
// their native module is absent —
// @react-native-google-signin/google-signin's errorCodes.ts calls
// NativeModule.getConstants() (TurboModuleRegistry.getEnforcing, which
// always throws on absence) at module scope, and expo-crypto's
// requireNativeModule('ExpoCrypto') does the same. Metro doesn't tree-shake,
// so a static import crashes the whole bundle before any React code runs —
// including on every existing production install the instant an OTA is
// published from a build that shipped without these native modules linked.
let GoogleSignin: any = null;
let statusCodes: any = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- @react-native-google-signin/google-signin is an unlinked native module; static import crashes Expo Go, bare Jest, and any OTA-only install lacking the native module
  const googleSignInModule = require("@react-native-google-signin/google-signin");
  GoogleSignin = googleSignInModule.GoogleSignin;
  statusCodes = googleSignInModule.statusCodes;
} catch {
  // Native module unavailable — Expo Go, a simulator without a dev build, or Jest.
}

let Crypto: any = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- expo-crypto's default export is requireNativeModule('ExpoCrypto') at module scope, which throws the same way in the same environments
  Crypto = require("expo-crypto");
} catch {
  // Native module unavailable.
}

// Google's flow below never touches expo-crypto — there's no nonce step for
// Google, only for Apple (see signInWithApple) — so Google's availability
// depends only on its own native module plus the OAuth client IDs having
// been filled in. app.json ships REPLACE_WITH_* placeholders for
// iosUrlScheme/googleWebClientId/googleIosClientId until the owner swaps in
// real values; building/OTA-ing before that swap must not let the button
// render normally and fail with a raw native OAuth error. Mirrors the
// existing `backendUrlIsPlaceholder` convention (see
// utils/invoiceHelpers.ts's VERCEL_URL_IS_PLACEHOLDER).
const GOOGLE_CLIENT_IDS_CONFIGURED =
  GOOGLE_WEB_CLIENT_ID.length > 0 &&
  GOOGLE_IOS_CLIENT_ID.length > 0 &&
  !GOOGLE_WEB_CLIENT_ID.includes("REPLACE_WITH_") &&
  !GOOGLE_IOS_CLIENT_ID.includes("REPLACE_WITH_");

// Single combined flag: covers BOTH "native module missing" (Critical fix)
// and "client IDs still placeholder" (Important #3) so callers only need one
// check.
export const SOCIAL_GOOGLE_AVAILABLE = Boolean(GoogleSignin) && GOOGLE_CLIENT_IDS_CONFIGURED;

// Apple's flow generates its own hashed nonce via expo-crypto before opening
// the native sheet (see signInWithApple) — Apple needs this native module
// even though Google's flow here doesn't touch it at all.
const CRYPTO_AVAILABLE = Boolean(Crypto);

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
  if (!CRYPTO_AVAILABLE) {
    return { ok: false, error: "Apple sign-in is unavailable in this environment." };
  }
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
  if (!SOCIAL_GOOGLE_AVAILABLE) {
    return { ok: false, error: "Google sign-in is unavailable in this environment." };
  }
  try {
    ensureGoogleConfigured();
    await GoogleSignin.hasPlayServices();
    const response = await GoogleSignin.signIn();
    // The installed @react-native-google-signin/google-signin (v16) never lets
    // a user cancellation reach the catch block below: signIn() internally
    // catches the native rejection and resolves with { type: "cancelled",
    // data: null } instead (see translateNativeRejection.js). Detect that
    // here rather than relying on a thrown SIGN_IN_CANCELLED error code.
    if (response.type === "cancelled" || !response.data) {
      return { ok: false, cancelled: true };
    }
    const idToken = response.data.idToken ?? null;
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
    // Defensive fallback: older/patched versions of the library (or a
    // future upgrade) could still throw SIGN_IN_CANCELLED instead of
    // resolving. Keep this check so that path degrades gracefully too.
    if (err?.code === statusCodes.SIGN_IN_CANCELLED) return { ok: false, cancelled: true };
    return { ok: false, error: err?.message ?? "Google sign-in failed." };
  }
}
