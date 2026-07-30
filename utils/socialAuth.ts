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
