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
