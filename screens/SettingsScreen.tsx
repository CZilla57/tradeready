import React, { useState, useEffect, useLayoutEffect, useRef, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  Switch,
  StyleSheet,
  Alert,
  Linking,
  AppState,
  ActivityIndicator,
  Platform,
  Modal,
  KeyboardAvoidingView,
  type AppStateStatus,
} from "react-native";
import { Image } from "expo-image";
import { Ionicons } from "@expo/vector-icons";
import Constants from "expo-constants";
import { loadSettings, saveSettings, clearSampleData, clearAllUserData } from "../utils/storage";
import { DEFAULT_CONFIRM_TEMPLATE, DEFAULT_ON_MY_WAY_TEMPLATE } from "../utils/appointmentTemplates";
import { syncNotifications } from "../utils/notifications";
import { composeEmail } from "../utils/messaging";
import { syncIfOnline } from "../utils/sync";
import { supabase } from "../utils/supabase";
import { resetUser, reportError } from "../utils/analytics";
import { Button, SectionHeader, Divider } from "../components/UI";
import { DELETE_CONFIRM_PHRASE, deleteConfirmMatches } from "../utils/deleteConfirm";
import { settingsEqual } from "../utils/settingsDirty";
import { normalizeInvoicePrefix } from "../utils/invoiceNumber";
import BaseField from "../components/Field";
import { KeyboardDoneBar } from "../components/KeyboardDoneBar";
import { TRADE_TYPES } from "../utils/pricingEngine";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useSubscription } from "../context/SubscriptionContext";
import { openManageSubscriptions } from "../utils/subscription";
import { useTheme } from "../hooks/useTheme";
import { useSyncStatusContext } from "../context/SyncStatusContext";
import { useAuth } from "../context/AuthContext";
import { promptForLogo } from "../utils/logoPicker";
import { deletePhoto, photoExists, listPhotos } from "../utils/photoStorage";
import { orphanedLogoPaths, sweepableLogoPaths } from "../utils/logoLifecycle";
import type { Settings } from "../types/models";
import type { TodayStackScreenProps } from "../types/navigation";

const PRIVACY_URL = Constants.expoConfig?.extra?.privacyPolicyUrl ?? "https://tradeready.app/privacy";
const TERMS_URL   = Constants.expoConfig?.extra?.termsUrl          ?? "https://tradeready.app/terms";
const VERCEL_URL  = Constants.expoConfig?.extra?.backendUrl        ?? "";
// Must match the address published in the privacy policy (§ Contact) —
// the domain is gettradereadyapp.com, NOT tradeready.app (which doesn't exist).
const SUPPORT_EMAIL = "support@gettradereadyapp.com";
const APP_VERSION   = Constants.expoConfig?.version ?? "1.0.0";

interface StripeStatus {
  connected: boolean;
  details_submitted?: boolean;
  display_name?: string;
  _error?: string;
}

interface Provider {
  id: string;
  label: string;
  hint?: string;
}

const PROVIDERS: Provider[] = [
  { id: "stripe", label: "Stripe" },
  { id: "square", label: "Square", hint: "Paste your Square payment link (create one in Square Dashboard → Payment Links, e.g. https://square.link/u/abc123)" },
  { id: "paypal", label: "PayPal.Me", hint: "Enter your PayPal.Me username (e.g. johndoe)" },
  { id: "venmo", label: "Venmo", hint: "Enter your Venmo username" },
  { id: "custom", label: "Custom URL", hint: "Paste your payment page URL" },
];

function formatPhone(raw: string): string {
  const digits = raw.replace(/\D/g, "").slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

/**
 * Folds any notification-rule box that is still being edited (a pending
 * draft, keyed by rule index, holding raw typed text) into `settings.rules`,
 * so saving while a field is focused persists what's typed instead of the
 * last-committed number. Mirrors commitRule's parse/normalize exactly:
 * an empty or non-numeric draft parses to NaN, and NaN (or anything < 1)
 * falls back to 1 — the same fallback commitRule itself commits, not the
 * previously-committed rule.days. Pure, so it can be applied to either the
 * live `s`/`ruleDrafts` state (handleSave, `dirty`) or the ref mirrors read
 * by the once-registered blur/beforeRemove guards.
 */
function applyRuleDrafts(settings: Settings, drafts: Record<number, string>): Settings {
  if (Object.keys(drafts).length === 0) return settings;
  const rules = settings.rules.map((rule, i) => {
    const draft = drafts[i];
    if (draft === undefined) return rule;
    const parsed = parseInt(draft, 10);
    return { days: Number.isNaN(parsed) || parsed < 1 ? 1 : parsed };
  });
  return { ...settings, rules };
}

/**
 * Reclaims logo files no persisted setting references — a pick the user
 * abandoned without reaching a commit point, or a cleanup interrupted part-way.
 * Per-session cleanup (cleanupLogoFiles) only knows the paths THIS session
 * touched, so it can never see those; this reads the folder itself.
 *
 * Runs from the load effect before `setS`, and the screen renders null until `s`
 * is set, so the picker cannot be reached mid-sweep. `logos/` is written only by
 * the logo picker — job photos and receipts live in their own folders — so the
 * sweep cannot reach any other kind of image.
 *
 * `persistedLogoPath` must be the RAW stored path, not one already blanked by
 * the dangling-path check: see the comment at the call site.
 */
async function sweepOrphanedLogos(persistedLogoPath: string | undefined): Promise<void> {
  const onDisk = await listPhotos("logos");
  for (const path of sweepableLogoPaths(onDisk, persistedLogoPath)) {
    await deletePhoto(path);
  }
}

export default function SettingsScreen({ navigation }: TodayStackScreenProps<'Settings'>) {
  const { colors, shadow, preference, setTheme } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [s, setS] = useState<Settings | null>(null);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleteModalVisible, setDeleteModalVisible] = useState(false);
  const [deleteConfirmText, setDeleteConfirmText] = useState("");
  const [showAdvanced, setShowAdvanced] = useState(false);
  // While a notification-rule box is being edited we keep its raw text here so it
  // can be empty/intermediate; the numeric model is committed on blur (see commitRule).
  const [ruleDrafts, setRuleDrafts] = useState<Record<number, string>>({});
  const { isSubscribed, isTrialing } = useSubscription();
  const { pendingCount } = useSyncStatusContext();
  // The sweep's precondition is that the settings we just loaded are
  // authoritative for this user. While initialSync is still pulling them down
  // they are not — right after a sign-out/sign-in on the same device, local
  // settings read back as defaults (logoPhoto "") while the user's real logo
  // file is still on disk, and sweeping against that would delete it. Mirrored
  // into a ref because the load effect is registered once.
  const { bootstrapping } = useAuth();
  const bootstrappingRef = useRef(bootstrapping);
  useEffect(() => { if (bootstrapping) bootstrappingRef.current = true; }, [bootstrapping]);

  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  const [stripeConnecting, setStripeConnecting] = useState(false);
  const [stripeDisconnecting, setStripeDisconnecting] = useState(false);
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);

  // Unsaved-edits guard: edits live only in `s` until "Save settings", so
  // leaving the tab with a dirty copy silently loses work. Track the
  // last-saved snapshot and warn on blur. Refs mirror state because the blur
  // listener is registered once and would otherwise close over stale values.
  const [savedSnapshot, setSavedSnapshot] = useState<Settings | null>(null);

  // Sticky Save in the native header (the screen only has a header at all
  // since the gear move). Enabled exactly when the dirty-guard would fire.
  // Compared against the flushed settings (drafts folded into `rules`) so an
  // in-progress "days past due" edit — never committed to `s` until blur —
  // still counts as a change; otherwise Save would stay disabled and the
  // unsaved-edits guards below would silently let the typing be discarded.
  const dirty = !!s && !!savedSnapshot && !settingsEqual(applyRuleDrafts(s, ruleDrafts), savedSnapshot);
  useLayoutEffect(() => {
    navigation.setOptions({
      headerRight: () => (
        <TouchableOpacity
          onPress={handleSave}
          disabled={!dirty || saving}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          // Header buttons: paddingLeft/alignSelf are what center the text;
          // alignItems/justifyContent are no-ops in a native-stack header slot.
          // marginRight matches CustomerDetail's Edit — without it the label
          // hugs the screen edge.
          style={{ alignSelf: "center", marginRight: 8, paddingLeft: 10 }}
          accessibilityRole="button"
          accessibilityLabel="Save settings"
          accessibilityState={{ disabled: !dirty || saving, busy: saving }}
        >
          <Text
            style={{
              fontFamily: fonts.bodySemiBold,
              fontSize: fontSize.md,
              color: !dirty || saving ? colors.textMuted : colors.accent,
            }}
          >
            Save
          </Text>
        </TouchableOpacity>
      ),
    });
  });

  const sRef = useRef<Settings | null>(null);
  const savedSnapshotRef = useRef<Settings | null>(null);
  const ruleDraftsRef = useRef<Record<number, string>>({});
  const suppressDirtyWarnRef = useRef(false); // sign-out/delete wipe data on purpose

  // Every logo path this session has referenced — the one loaded from settings plus
  // each file the picker copied in. At each commit point, whichever of these the
  // persisted settings no longer reference is deleted. Seeded on load so an
  // untouched logo is trivially "kept".
  const touchedLogoPathsRef = useRef<string[]>([]);

  // Delete the image files the just-committed settings no longer reference, then
  // reset the session's tracking to that surviving path.
  async function cleanupLogoFiles(committedLogoPath: string | undefined) {
    const orphans = orphanedLogoPaths(touchedLogoPathsRef.current, committedLogoPath);
    touchedLogoPathsRef.current = committedLogoPath ? [committedLogoPath] : [];
    for (const path of orphans) {
      await deletePhoto(path);
    }
  }

  useEffect(() => { sRef.current = s; }, [s]);
  useEffect(() => { savedSnapshotRef.current = savedSnapshot; }, [savedSnapshot]);
  useEffect(() => { ruleDraftsRef.current = ruleDrafts; }, [ruleDrafts]);

  // Tab-switch-away used to leave Settings sitting on the Today stack, so
  // returning to the Today tab landed back here (owner smoke finding,
  // 2026-07-31). Pop to TodayHome instead. The pop is a removal, so the
  // beforeRemove guard below owns the unsaved-edits prompt for this path
  // too — one prompt path for back, swipe, and tab-switch alike.
  // The parent-state check keeps root-stack covers (PaywallModal via
  // Subscribe) from popping Settings out from under the modal: those blur
  // this screen without changing the active tab.
  useEffect(() => {
    const unsub = navigation.addListener("blur", () => {
      const tabState = navigation.getParent()?.getState();
      const activeTab = tabState ? tabState.routes[tabState.index]?.name : undefined;
      if (activeTab && activeTab !== "Today") {
        navigation.popToTop();
      }
    });
    return unsub;
  }, [navigation]);

  // THE unsaved-edits guard — the single prompt for every removal path:
  // back button, swipe-back, and the tab-switch pop dispatched by the blur
  // listener above. Intercept the removal, ask, then resume the same action.
  // suppressDirtyWarnRef is set before each resumed dispatch so re-entering
  // this listener during the resumed removal stays quiet; sign-out and
  // delete-account set it too, so root resets pass through silently.
  useEffect(() => {
    const unsub = navigation.addListener("beforeRemove", (e) => {
      const current = sRef.current;
      const saved = savedSnapshotRef.current;
      if (suppressDirtyWarnRef.current || !current || !saved) return;
      if (settingsEqual(applyRuleDrafts(current, ruleDraftsRef.current), saved)) return;
      e.preventDefault();
      Alert.alert(
        "Unsaved settings",
        "You changed settings but didn't tap Save. Keep your changes?",
        [
          {
            text: "Discard",
            style: "destructive",
            onPress: () => {
              // No setS: the screen is about to unmount; next mount reloads
              // from storage. Logo files copied during the abandoned edit are
              // orphans now — same cleanup as the blur path.
              suppressDirtyWarnRef.current = true;
              cleanupLogoFiles(saved.logoPhoto);
              navigation.dispatch(e.data.action);
            },
          },
          {
            text: "Save",
            onPress: async () => {
              const current = sRef.current;
              if (!current) return;
              // Flush any in-progress "days past due" draft before saving —
              // saving sRef.current raw would silently drop it.
              const toSave = applyRuleDrafts(current, ruleDraftsRef.current);
              await saveSettings(toSave);
              syncNotifications();
              setSavedSnapshot(toSave);
              await cleanupLogoFiles(toSave.logoPhoto);
              suppressDirtyWarnRef.current = true;
              navigation.dispatch(e.data.action);
            },
          },
        ]
      );
    });
    return unsub;
  }, [navigation]);

  useEffect(() => {
    loadSettings().then(async (loaded) => {
      if (
        loaded.provider !== "stripe" &&
        loaded.providerKey &&
        !loaded.providerKeys?.[loaded.provider]
      ) {
        loaded = {
          ...loaded,
          providerKeys: { ...loaded.providerKeys, [loaded.provider]: loaded.providerKey },
        };
      }
      // Captured BEFORE the sanitization below, and swept against, deliberately.
      // photoExists fails closed, so a transient filesystem error blanks
      // logoPhoto — and sweeping against a blank keeper would delete the user's
      // real logo, turning a one-session display glitch into permanent loss.
      // The raw path still matches the real file, so it survives.
      const persistedLogoPath = loaded.logoPhoto;

      // A logoPhoto path can outlive the file it points at (reinstall, or a path
      // synced from another device). Treat a dangling path as unset so the "Add
      // logo" placeholder shows instead of an invisible circle, and so the next
      // save clears the stale reference.
      if (loaded.logoPhoto && !(await photoExists(loaded.logoPhoto))) {
        loaded = { ...loaded, logoPhoto: "" };
      }
      // Skipping a sweep costs only disk; sweeping against non-authoritative
      // settings costs the user's logo. When in doubt, skip — the next launch
      // sweeps instead.
      if (!bootstrappingRef.current) {
        await sweepOrphanedLogos(persistedLogoPath);
      }
      setS(loaded);
      setSavedSnapshot(loaded);
      touchedLogoPathsRef.current = loaded.logoPhoto ? [loaded.logoPhoto] : [];
    });
  }, []);

  useEffect(() => {
    fetchStripeStatus();
    const sub = AppState.addEventListener("change", (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === "active") {
        fetchStripeStatus();
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, []);

  async function fetchStripeStatus() {
    if (!VERCEL_URL) { setStripeStatus({ connected: false }); return; }
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) { setStripeStatus({ connected: false }); return; }
      const res = await fetch(`${VERCEL_URL}/api/stripe/connect-status`, {
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      const data = await res.json();
      if (res.ok) {
        setStripeStatus(data);
      } else {
        setStripeStatus({ connected: false, _error: data?.error });
      }
    } catch {
      setStripeStatus({ connected: false });
    }
  }

  async function handleStripeConnect() {
    setStripeConnecting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) throw new Error("You must be signed in.");
      const res = await fetch(`${VERCEL_URL}/api/stripe/create-connect-account`, {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
      });
      const data = await res.json();
      if (data.error) throw new Error(data.error);
      await Linking.openURL(data.onboarding_url);
    } catch (err: unknown) {
      reportError(err, { context: 'stripeConnect' });
      Alert.alert("Stripe Connect error", (err as Error).message || "Could not start Stripe onboarding.");
    } finally {
      setStripeConnecting(false);
    }
  }

  async function handleStripeDisconnect() {
    Alert.alert("Disconnect Stripe", "Your Stripe account will be unlinked. Payment links will stop working until you reconnect.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Disconnect",
        style: "destructive",
        onPress: async () => {
          setStripeDisconnecting(true);
          try {
            const { data: { session } } = await supabase.auth.getSession();
            if (!session?.access_token) throw new Error("You must be signed in.");
            const res = await fetch(`${VERCEL_URL}/api/stripe/disconnect`, {
              method: "POST",
              headers: { Authorization: `Bearer ${session.access_token}` },
            });
            if (!res.ok) throw new Error("Failed to disconnect.");
            setStripeStatus({ connected: false });
          } catch (err: unknown) {
            reportError(err, { context: 'stripeDisconnect' });
            Alert.alert("Error", (err as Error).message || "Could not disconnect Stripe account.");
          } finally {
            setStripeDisconnecting(false);
          }
        },
      },
    ]);
  }

  function update(field: string, value: unknown) {
    setS(prev => prev ? { ...prev, [field]: value } as Settings : prev);
  }

  // The logo follows this screen's draft contract: picking copies the file in and
  // points the draft at it, removing only clears the draft reference. Neither
  // deletes anything — cleanup happens once settings are committed, so "Discard"
  // can still restore the previous image. See utils/logoLifecycle.ts.
  function handlePickLogo() {
    promptForLogo((uri) => {
      touchedLogoPathsRef.current = [...touchedLogoPathsRef.current, uri];
      update("logoPhoto", uri);
    });
  }

  function handleRemoveLogo() {
    update("logoPhoto", "");
  }

  // Keep only the raw text while typing so the box can be emptied to enter a new
  // number; the value is normalized to a number on blur (commitRule).
  function updateRule(index: number, text: string) {
    setRuleDrafts(prev => ({ ...prev, [index]: text.replace(/[^0-9]/g, "") }));
  }

  function commitRule(index: number) {
    const draft = ruleDrafts[index];
    if (draft === undefined) return;
    const parsed = parseInt(draft, 10);
    const days = Number.isNaN(parsed) || parsed < 1 ? 1 : parsed;
    setS(prev => {
      if (!prev) return prev;
      const rules = [...prev.rules];
      rules[index] = { days };
      return { ...prev, rules };
    });
    setRuleDrafts(prev => {
      const next = { ...prev };
      delete next[index];
      return next;
    });
  }

  function addRule() {
    setRuleDrafts({});
    setS(prev => prev ? { ...prev, rules: [...prev.rules, { days: 7 }] } : prev);
  }

  function removeRule(index: number) {
    setRuleDrafts({});
    setS(prev => {
      if (!prev) return prev;
      return { ...prev, rules: prev.rules.filter((_, i) => i !== index) };
    });
  }

  function updateProviderKey(value: string) {
    if (!s) return;
    if (s.provider === "stripe") {
      update("providerKey", value);
    } else {
      setS(prev => prev ? {
        ...prev,
        providerKeys: { ...prev.providerKeys, [prev.provider]: value },
      } : prev);
    }
  }

  async function handleSave() {
    if (!s) return;
    const flushed = applyRuleDrafts(s, ruleDrafts);
    setSaving(true);
    await saveSettings(flushed);
    syncNotifications();
    setS(flushed);
    setRuleDrafts({});
    setSavedSnapshot(flushed);
    await cleanupLogoFiles(flushed.logoPhoto);
    setSaving(false);
    Alert.alert("Saved", "Your settings have been saved.");
  }

  async function performDeleteAccount() {
    suppressDirtyWarnRef.current = true; // deleting the account discards edits by definition
    setDeleting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) { Alert.alert("Error", "No active session. Please sign in again."); return; }
      const res = await fetch(`${VERCEL_URL}/api/delete-account`, {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || "Failed to delete account.");
      }
      resetUser();
      await clearAllUserData();
      await supabase.auth.signOut();
    } catch (err: unknown) {
      reportError(err, { context: 'deleteAccount' });
      Alert.alert("Error", (err as Error).message || "Something went wrong. Please try again.");
      suppressDirtyWarnRef.current = false; // deletion failed; the guard matters again
    } finally {
      setDeleting(false);
    }
  }

  if (!s) return null;

  const selectedProvider = PROVIDERS.find((p) => p.id === s.provider);

  return (
    <View style={styles.container}>
      {/* automaticallyAdjustKeyboardInsets accumulated phantom bottom inset on
          device (endless empty scroll space — beta finding); use the same
          KeyboardAvoidingView pattern as the Add/Edit screens instead. */}
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
      >
        <SectionHeader title="Your business" />
        <View style={styles.card}>
          <Field label="Business name" value={s.businessName} onChangeText={(v) => update("businessName", v)} colors={colors} shadow={shadow} />
          <Field label="Your name" value={s.contactName} onChangeText={(v) => update("contactName", v)} colors={colors} shadow={shadow} />
          <Field label="Phone" value={s.phone} onChangeText={(v) => update("phone", formatPhone(v))} keyboardType="phone-pad" colors={colors} shadow={shadow} />
          <Field label="Email" value={s.email} onChangeText={(v) => update("email", v)} keyboardType="email-address" colors={colors} shadow={shadow} />
          <Field label="Business address" value={s.address} onChangeText={(v) => update("address", v)} multiline autoCapitalize="words" colors={colors} shadow={shadow} />
          <Field label="Payment instructions" value={s.paymentNotes} onChangeText={(v) => update("paymentNotes", v)} multiline autoCapitalize="sentences" colors={colors} shadow={shadow} />
          <Field label="Region" value={s.region || ""} onChangeText={(v) => update("region", v)} colors={colors} shadow={shadow} />
          <Text style={[styles.fieldLabel, { marginTop: spacing.sm }]}>Your trade</Text>
          <View style={styles.tradeGrid}>
            {TRADE_TYPES.map((t) => (
              <TouchableOpacity
                key={t.id}
                style={[styles.tradeBtn, s.trade === t.id && styles.tradeBtnActive]}
                onPress={() => update("trade", t.id)}
                accessibilityRole="radio"
                accessibilityLabel={t.label}
                accessibilityState={{ selected: s.trade === t.id }}
              >
                <Text style={[styles.tradeLabel, s.trade === t.id && styles.tradeLabelActive]}>{t.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
          <Text style={[styles.fieldLabel, { marginTop: spacing.md }]}>Your logo</Text>
          <Text style={styles.logoHint}>Optional — appears on invoices and estimates.</Text>
          <TouchableOpacity
            style={styles.logoPicker}
            onPress={handlePickLogo}
            activeOpacity={0.7}
            accessibilityRole="button"
            accessibilityLabel={s.logoPhoto ? "Change your business logo" : "Add your business logo"}
          >
            {s.logoPhoto ? (
              <Image source={{ uri: s.logoPhoto }} style={styles.logoImage} contentFit="cover" />
            ) : (
              <View style={styles.logoPlaceholder}>
                <Ionicons name="camera-outline" size={22} color={colors.textMuted} style={styles.logoPlaceholderIcon} />
                <Text style={styles.logoPlaceholderText}>Add logo</Text>
              </View>
            )}
          </TouchableOpacity>
          {!!s.logoPhoto && (
            <TouchableOpacity
              onPress={handleRemoveLogo}
              style={styles.logoRemoveBtn}
              accessibilityRole="button"
              accessibilityLabel="Remove your business logo"
            >
              <Text style={styles.logoRemoveText}>Remove</Text>
            </TouchableOpacity>
          )}
        </View>

        <Divider />

        <SectionHeader title="Pricing defaults" />
        <Text style={styles.ruleSubtitle}>These pre-fill your estimate calculator. You can always override them per job.</Text>
        <View style={styles.card}>
          <Field label="Your hourly labor rate ($)" value={String(s.laborRate || "")} onChangeText={(v) => update("laborRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Material markup (%)" value={String(s.materialMarkup || "")} onChangeText={(v) => update("materialMarkup", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Overhead % (insurance, truck, tools)" value={String(s.overheadPercent || "")} onChangeText={(v) => update("overheadPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Profit margin %" value={String(s.marginPercent || "")} onChangeText={(v) => update("marginPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Minimum job fee ($)" value={String(s.minimumJobFee || "")} onChangeText={(v) => update("minimumJobFee", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Emergency/after-hours multiplier (e.g. 1.5 = 50% extra)" value={String(s.emergencyMultiplier || "")} onChangeText={(v) => update("emergencyMultiplier", parseFloat(v) || 1)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Mileage rate ($ per mile)" value={String(s.mileageRate ?? 0.70)} onChangeText={(v) => update("mileageRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Text style={styles.keyNote}>
            Used to estimate the tax deduction for logged trips (Money → Mileage). Set to the standard mileage rate for your tax year.
          </Text>
        </View>

        <Divider />

        <SectionHeader title="Invoice numbering" />
        <View style={styles.card}>
          <Field
            label="Invoice number prefix"
            value={s.invoicePrefix ?? ""}
            onChangeText={(v: string) => update("invoicePrefix", v)}
            placeholder="INV"
            autoCapitalize="characters"
            colors={colors}
            shadow={shadow}
          />
          <Field
            label="Numbers start at"
            value={s.invoiceStartNumber != null ? String(s.invoiceStartNumber) : ""}
            onChangeText={(v: string) => {
              const parsed = parseInt(v.replace(/[^0-9]/g, ""), 10);
              update("invoiceStartNumber", Number.isNaN(parsed) ? undefined : parsed);
            }}
            placeholder="1"
            keyboardType="number-pad"
            colors={colors}
            shadow={shadow}
          />
          <Text style={styles.keyNote}>
            Auto-numbers look like {normalizeInvoicePrefix(s.invoicePrefix)}-{String(Math.max(1, Math.floor(s.invoiceStartNumber || 1))).padStart(4, "0")}. The starting number only matters until your numbering grows past it — existing invoices keep their numbers.
          </Text>
        </View>

        <Divider />

        <SectionHeader title="Appearance" />
        <View style={styles.card}>
          <Text style={styles.providerHint}>Choose how TradeReady looks on your device.</Text>
          <View style={styles.providerGrid}>
            {([{ key: "light", label: "Light" }, { key: "system", label: "System" }, { key: "dark", label: "Dark" }] as const).map((opt) => (
              <TouchableOpacity
                key={opt.key}
                style={[styles.providerBtn, preference === opt.key && styles.providerBtnActive]}
                onPress={() => setTheme(opt.key)}
                accessibilityRole="radio"
                accessibilityLabel={`${opt.label} appearance`}
                accessibilityState={{ selected: preference === opt.key }}
              >
                <Text style={[styles.providerLabel, preference === opt.key && styles.providerLabelActive]}>{opt.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        <Divider />

        <SectionHeader title="Payment processor" />
        <View style={styles.providerGrid}>
          {PROVIDERS.map((p) => (
            <TouchableOpacity
              key={p.id}
              style={[styles.providerBtn, s.provider === p.id && styles.providerBtnActive]}
              onPress={() => update("provider", p.id)}
              accessibilityRole="radio"
              accessibilityLabel={p.label}
              accessibilityState={{ selected: s.provider === p.id }}
            >
              <Text style={[styles.providerLabel, s.provider === p.id && styles.providerLabelActive]}>{p.label}</Text>
            </TouchableOpacity>
          ))}
        </View>
        {s.provider === "stripe" ? (
          <View style={styles.card}>
            {stripeStatus === null ? (
              <ActivityIndicator size="small" color={colors.accent} />
            ) : stripeStatus.connected ? (
              <>
                <View style={styles.stripeConnectedRow}>
                  <View style={styles.stripeConnectedDot} />
                  <Text style={styles.stripeConnectedLabel}>
                    {stripeStatus.details_submitted
                      ? (stripeStatus.display_name ? `Connected — ${stripeStatus.display_name}` : "Connected")
                      : "Connected — finish onboarding"}
                  </Text>
                </View>
                {!stripeStatus.details_submitted && (
                  <Text style={styles.stripeOnboardingHint}>
                    Tap below to complete your Stripe account setup before accepting payments.
                  </Text>
                )}
                <View style={styles.stripeButtonRow}>
                  {!stripeStatus.details_submitted && (
                    <TouchableOpacity style={[styles.stripeBtn, stripeConnecting && { opacity: 0.5 }]} onPress={handleStripeConnect} disabled={stripeConnecting} accessibilityRole="button" accessibilityLabel="Complete Stripe setup" accessibilityState={{ disabled: stripeConnecting, busy: stripeConnecting }}>
                      {stripeConnecting ? <ActivityIndicator size="small" color={colors.accent} /> : <Text style={styles.stripeBtnText}>Complete setup</Text>}
                    </TouchableOpacity>
                  )}
                  <TouchableOpacity style={[styles.stripeBtnDanger, stripeDisconnecting && { opacity: 0.5 }]} onPress={handleStripeDisconnect} disabled={stripeDisconnecting} accessibilityRole="button" accessibilityLabel="Disconnect Stripe" accessibilityState={{ disabled: stripeDisconnecting, busy: stripeDisconnecting }}>
                    {stripeDisconnecting ? <ActivityIndicator size="small" color={colors.danger} /> : <Text style={styles.stripeBtnDangerText}>Disconnect</Text>}
                  </TouchableOpacity>
                </View>
              </>
            ) : (
              <>
                <Text style={styles.providerHint}>Connect your Stripe account to generate payment links for your customers. Payments go directly to your Stripe account.</Text>
                <TouchableOpacity style={[styles.stripeConnectBtn, stripeConnecting && { opacity: 0.5 }]} onPress={handleStripeConnect} disabled={stripeConnecting} accessibilityRole="button" accessibilityLabel="Connect Stripe account" accessibilityState={{ disabled: stripeConnecting, busy: stripeConnecting }}>
                  {stripeConnecting ? <ActivityIndicator size="small" color="#fff" /> : <Text style={styles.stripeConnectBtnText}>Connect Stripe account</Text>}
                </TouchableOpacity>
              </>
            )}
          </View>
        ) : selectedProvider ? (
          <View style={styles.card}>
            <Text style={styles.providerHint}>{selectedProvider.hint}</Text>
            <TextInput
              style={styles.input}
              value={s.provider === "stripe" ? s.providerKey : (s.providerKeys?.[s.provider] ?? "")}
              onChangeText={updateProviderKey}
              placeholder="Paste link or username here"
              placeholderTextColor={colors.textMuted}
              autoCapitalize="none"
              autoCorrect={false}
              returnKeyType="done"
              accessibilityLabel={`${selectedProvider.label} link or username`}
            />
            <Text style={styles.keyNote}>This appears in the payment links you send to customers — never paste a password, API key, or access token here.</Text>
          </View>
        ) : null}

        <Divider />

        <SectionHeader title="AI Assistant" />
        <View style={styles.card}>
          <Text style={styles.providerHint}>
            AI features work automatically via our cloud service. Toggle Advanced to use your own API keys instead.
          </Text>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Advanced</Text>
            <Switch
              value={showAdvanced}
              onValueChange={setShowAdvanced}
              trackColor={{ false: colors.border, true: colors.accent }}
              accessibilityLabel="Advanced AI settings"
            />
          </View>
        </View>
        {showAdvanced && (
          <>
            <View style={[styles.card, { marginTop: spacing.sm }]}>
              <Text style={styles.providerHint}>Groq API key — powers the AI chat tab (estimates, advice, invoice messages). Get a free key at console.groq.com — no billing required.</Text>
              <TextInput style={styles.input} value={s.groqKey} onChangeText={(v) => update("groqKey", v)} placeholder="gsk_..." placeholderTextColor={colors.textMuted} autoCapitalize="none" autoCorrect={false} secureTextEntry returnKeyType="done" accessibilityLabel="Groq API key" />
              <Text style={styles.keyNote}>Stored only on your device. Never share this key.</Text>
            </View>
            <View style={[styles.card, { marginTop: spacing.sm }]}>
              <Text style={styles.providerHint}>Anthropic (Claude) API key — used for AI-generated invoice outreach messages. Get one at console.anthropic.com.</Text>
              <TextInput style={styles.input} value={s.anthropicKey} onChangeText={(v) => update("anthropicKey", v)} placeholder="sk-ant-..." placeholderTextColor={colors.textMuted} autoCapitalize="none" autoCorrect={false} secureTextEntry returnKeyType="done" accessibilityLabel="Anthropic API key" />
              <Text style={styles.keyNote}>Stored only on your device. Never share this key.</Text>
            </View>
          </>
        )}

        <Divider />

        <SectionHeader title="Notification rules" />
        <Text style={styles.ruleSubtitle}>Get notified when an invoice is this many days past due:</Text>
        {s.rules.map((rule, i) => (
          <View key={i} style={styles.ruleRow}>
            <TextInput style={styles.ruleInput} value={ruleDrafts[i] !== undefined ? ruleDrafts[i] : String(rule.days)} onChangeText={(v) => updateRule(i, v)} onBlur={() => commitRule(i)} keyboardType="number-pad" maxLength={3} inputAccessoryViewID="settingsDone" accessibilityLabel={`Reminder rule ${i + 1}: days past due`} />
            <Text style={styles.ruleSuffix}>days past due</Text>
            <TouchableOpacity onPress={() => removeRule(i)} style={styles.removeBtn} accessibilityRole="button" accessibilityLabel={`Remove reminder rule ${i + 1}`}>
              <Ionicons name="close" size={16} color={colors.danger} />
            </TouchableOpacity>
          </View>
        ))}
        <TouchableOpacity style={styles.addRuleBtn} onPress={addRule} accessibilityRole="button" accessibilityLabel="Add reminder rule">
          <Text style={styles.addRuleBtnText}>+ Add rule</Text>
        </TouchableOpacity>

        <Text style={[styles.ruleSubtitle, { marginTop: spacing.sm }]}>
          Turn those reminders into one-tap outreach: tapping a reminder opens a ready-to-send message for that invoice.
        </Text>
        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Draft a reminder I can send with one tap</Text>
            <Switch
              value={!!s.autoOutreachEnabled}
              onValueChange={(v) => update("autoOutreachEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Draft a reminder I can send with one tap"
            />
          </View>
        </View>

        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Automatically email overdue reminders</Text>
            <Switch
              value={!!s.autoSendEmailEnabled}
              onValueChange={(v) => update("autoSendEmailEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Automatically email overdue reminders"
            />
          </View>
          <Text style={styles.keyNote}>
            When on, TradeReady emails the customer a payment reminder once an invoice passes your earliest reminder age — no tap needed. Sent under your business name; replies come to your email.
          </Text>
        </View>

        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Appointment reminders</Text>
            <Switch
              value={!!s.appointmentRemindersEnabled}
              onValueChange={(v) => update("appointmentRemindersEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Appointment reminders"
            />
          </View>
          <Text style={styles.keyNote}>
            Remind me the evening before a scheduled job to confirm with the customer.
          </Text>
        </View>

        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Estimate follow-up reminders</Text>
            <Switch
              value={s.estimateFollowUpsEnabled !== false}
              onValueChange={(v) => update("estimateFollowUpsEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Estimate follow-up reminders"
            />
          </View>
          <Text style={styles.keyNote}>
            Remind me when an estimate gets no response for 3 days.
          </Text>
        </View>

        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Auto-invoice completed jobs</Text>
            <Switch
              value={!!s.autoInvoiceOnComplete}
              onValueChange={(v) => update("autoInvoiceOnComplete", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Auto-invoice completed jobs"
            />
          </View>
          <Text style={styles.keyNote}>
            When you mark a job complete, create the invoice automatically — billing tracked time when the timer was used — and open the send screen.
          </Text>
        </View>

        <Text style={[styles.ruleSubtitle, { marginTop: spacing.sm }]}>Message templates</Text>
        <View style={styles.card}>
          <Field
            label="Confirmation message"
            value={s.appointmentConfirmTemplate ?? DEFAULT_CONFIRM_TEMPLATE}
            onChangeText={(v) => update("appointmentConfirmTemplate", v)}
            multiline
            autoCapitalize="sentences"
            colors={colors}
            shadow={shadow}
          />
          <Text style={styles.keyNote}>
            Available: {"{customerName}"}, {"{businessName}"}, {"{date}"}, {"{time}"}, {"{address}"}
          </Text>
        </View>
        <View style={styles.card}>
          <Field
            label="On-my-way message"
            value={s.onMyWayTemplate ?? DEFAULT_ON_MY_WAY_TEMPLATE}
            onChangeText={(v) => update("onMyWayTemplate", v)}
            multiline
            autoCapitalize="sentences"
            colors={colors}
            shadow={shadow}
          />
          <Text style={styles.keyNote}>
            Available: {"{customerName}"}, {"{businessName}"}, {"{date}"}, {"{time}"}, {"{address}"}
          </Text>
        </View>

        <Divider />

        <SectionHeader title="Review requests" />
        <Text style={styles.ruleSubtitle}>
          Automatically prompt customers for a Google review after you complete a job.
        </Text>
        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Enable review requests</Text>
            <Switch
              value={s.reviewRequestEnabled}
              onValueChange={(v) => update("reviewRequestEnabled", v)}
              trackColor={{ true: colors.accent }}
              accessibilityLabel="Enable review requests"
            />
          </View>
        </View>
        {s.reviewRequestEnabled && (
          <>
            <View style={styles.card}>
              <Field
                label="Google review link"
                value={s.googleReviewLink}
                onChangeText={(v) => update("googleReviewLink", v)}
                autoCapitalize="none"
                colors={colors}
                shadow={shadow}
              />
              <Text style={styles.keyNote}>
                Find this in your Google Business Profile → "Ask for reviews" → copy the link.
              </Text>
            </View>
            <View style={styles.card}>
              <Field
                label="Delay after job completion (hours)"
                value={String(s.reviewRequestDelayHours || 3)}
                onChangeText={(v) => update("reviewRequestDelayHours", parseInt(v) || 3)}
                keyboardType="number-pad"
                colors={colors}
                shadow={shadow}
              />
            </View>
            <View style={styles.card}>
              <Field
                label="Message template"
                value={s.reviewRequestTemplate}
                onChangeText={(v) => update("reviewRequestTemplate", v)}
                multiline
                autoCapitalize="sentences"
                colors={colors}
                shadow={shadow}
              />
              <Text style={styles.keyNote}>
                Use {"{businessName}"}, {"{customerName}"}, and {"{googleReviewLink}"} as placeholders.
              </Text>
            </View>
          </>
        )}

        <Divider />

        <Button label="Save settings" onPress={handleSave} loading={saving} />

        <Divider />

        <SectionHeader title="Subscription" />
        <View style={styles.card}>
          {isTrialing ? (
            <View style={styles.subStatusRow}>
              <View style={[styles.subStatusDot, { backgroundColor: colors.warning }]} />
              <Text style={[styles.subStatusLabel, { color: colors.warning }]}>Free trial active</Text>
            </View>
          ) : isSubscribed ? (
            <View style={styles.subStatusRow}>
              <View style={[styles.subStatusDot, { backgroundColor: colors.success }]} />
              <Text style={[styles.subStatusLabel, { color: colors.success }]}>Subscription active</Text>
            </View>
          ) : (
            <Text style={styles.providerHint}>Subscribe to unlock all features.</Text>
          )}
          {isSubscribed || isTrialing ? (
            <TouchableOpacity style={[styles.stripeBtn, { marginTop: spacing.sm }]} accessibilityRole="button" accessibilityLabel="Manage subscription" onPress={async () => {
              if (await openManageSubscriptions()) return;
              // Neither the StoreKit sheet nor the store deep link is available
              // (sandbox / iPad compatibility mode) — tell the user where to go
              // rather than letting the failure surface as an error.
              Alert.alert(
                "Manage your subscription",
                Platform.OS === "ios"
                  ? "Open the Settings app, tap your name, then tap Subscriptions to change or cancel TradeReady Pro."
                  : "Open the Google Play Store, tap your profile picture, then tap Payments & subscriptions."
              );
            }}>
              <Text style={styles.stripeBtnText}>Manage subscription</Text>
            </TouchableOpacity>
          ) : (
            /* PaywallModal lives on the ROOT stack: TodayStack → MainTabs → RootStack, hence two hops. */
            <TouchableOpacity style={[styles.stripeConnectBtn, { marginTop: spacing.sm }]} accessibilityRole="button" accessibilityLabel="Subscribe" onPress={() => navigation.getParent()?.getParent()?.navigate("PaywallModal", { canDismiss: true })}>
              <Text style={styles.stripeConnectBtnText}>Subscribe</Text>
            </TouchableOpacity>
          )}
        </View>

        <Divider />

        <SectionHeader title="Help & Support" />
        <View style={styles.card}>
          <TouchableOpacity
            style={styles.listRow}
            onPress={() =>
              composeEmail({
                recipients: [SUPPORT_EMAIL],
                subject: `TradeReady support (v${APP_VERSION}, ${Platform.OS})`,
                body: "",
              })
            }
            activeOpacity={0.7}
            accessibilityRole="button"
            accessibilityLabel="Contact support by email"
          >
            <View style={{ flex: 1 }}>
              <Text style={styles.listRowText}>Contact Support</Text>
              <Text style={styles.listRowSub}>{SUPPORT_EMAIL}</Text>
            </View>
            <Text style={styles.listRowChevron}>›</Text>
          </TouchableOpacity>
        </View>

        <Divider />

        <SectionHeader title="Legal" />
        <View style={styles.card}>
          <TouchableOpacity style={styles.listRow} onPress={() => Linking.openURL(PRIVACY_URL)} activeOpacity={0.7} accessibilityRole="link" accessibilityLabel="Privacy Policy">
            <Text style={styles.listRowText}>Privacy Policy</Text>
            <Text style={styles.listRowChevron}>›</Text>
          </TouchableOpacity>
          <View style={styles.listRowDivider} />
          <TouchableOpacity style={styles.listRow} onPress={() => Linking.openURL(TERMS_URL)} activeOpacity={0.7} accessibilityRole="link" accessibilityLabel="Terms of Service">
            <Text style={styles.listRowText}>Terms of Service</Text>
            <Text style={styles.listRowChevron}>›</Text>
          </TouchableOpacity>
        </View>

        <Divider />

        <SectionHeader title="Account" />

        <TouchableOpacity
          style={styles.clearSampleBtn}
          accessibilityRole="button"
          accessibilityLabel="Clear sample data"
          onPress={() => Alert.alert("Clear sample data", "This permanently removes all sample customers, jobs, and invoices. Your own data is not affected.", [
            { text: "Cancel", style: "cancel" },
            { text: "Clear sample data", style: "destructive", onPress: async () => { await clearSampleData(); Alert.alert("Done", "Sample data has been removed."); } },
          ])}
        >
          <Text style={styles.clearSampleText}>Clear Sample Data</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.signOutBtn}
          accessibilityRole="button"
          accessibilityLabel="Sign out"
          onPress={() => {
            const doSignOut = async () => { suppressDirtyWarnRef.current = true; resetUser(); await clearAllUserData(); await supabase.auth.signOut(); };
            if (pendingCount > 0) {
              Alert.alert("Unsynced changes", "You have changes that haven't been saved to the cloud yet. Sync now to keep them.", [
                { text: "Cancel", style: "cancel" },
                { text: "Sync & sign out", onPress: async () => { const { data: { session } } = await supabase.auth.getSession(); if (session?.user?.id) await syncIfOnline(session.user.id); await doSignOut(); } },
                { text: "Sign out anyway", style: "destructive", onPress: doSignOut },
              ]);
            } else {
              Alert.alert("Sign out", "Are you sure you want to sign out?", [
                { text: "Cancel", style: "cancel" },
                { text: "Sign out", style: "destructive", onPress: doSignOut },
              ]);
            }
          }}
        >
          <Text style={styles.signOutText}>Sign Out</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.deleteAccountBtn, deleting && { opacity: 0.5 }]}
          disabled={deleting}
          accessibilityRole="button"
          accessibilityLabel="Delete account"
          accessibilityState={{ disabled: deleting, busy: deleting }}
          onPress={() => { setDeleteConfirmText(""); setDeleteModalVisible(true); }}
        >
          <Text style={styles.deleteAccountText}>{deleting ? "Deleting account…" : "Delete Account"}</Text>
        </TouchableOpacity>
      </ScrollView>
      </KeyboardAvoidingView>
      {/* Serves the number-pad reminder-rule inputs. */}
      <KeyboardDoneBar nativeID="settingsDone" />

      <Modal
        visible={deleteModalVisible}
        transparent
        animationType="fade"
        onRequestClose={() => setDeleteModalVisible(false)}
      >
        <KeyboardAvoidingView
          style={styles.modalBackdrop}
          behavior={Platform.OS === "ios" ? "padding" : undefined}
        >
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle} accessibilityRole="header">Delete account</Text>
            <Text style={styles.modalBody}>
              This permanently deletes your account and all your data — jobs, invoices,
              customers, and expenses. This cannot be undone.
            </Text>
            <Text style={styles.modalBody}>Type {DELETE_CONFIRM_PHRASE} to confirm.</Text>
            <TextInput
              style={styles.input}
              value={deleteConfirmText}
              onChangeText={setDeleteConfirmText}
              placeholder={DELETE_CONFIRM_PHRASE}
              placeholderTextColor={colors.textMuted}
              autoCapitalize="characters"
              autoCorrect={false}
              returnKeyType="done"
              accessibilityLabel={`Type ${DELETE_CONFIRM_PHRASE} to confirm account deletion`}
            />
            <View style={styles.modalBtnRow}>
              <TouchableOpacity
                style={styles.modalCancelBtn}
                onPress={() => setDeleteModalVisible(false)}
                accessibilityRole="button"
                accessibilityLabel="Cancel"
              >
                <Text style={styles.modalCancelText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.modalDeleteBtn, !deleteConfirmMatches(deleteConfirmText) && { opacity: 0.5 }]}
                disabled={!deleteConfirmMatches(deleteConfirmText)}
                onPress={() => { setDeleteModalVisible(false); performDeleteAccount(); }}
                accessibilityRole="button"
                accessibilityLabel="Delete my account"
                accessibilityState={{ disabled: !deleteConfirmMatches(deleteConfirmText) }}
              >
                <Text style={styles.modalDeleteText}>Delete my account</Text>
              </TouchableOpacity>
            </View>
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </View>
  );
}

interface FieldProps {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  keyboardType?: string;
  multiline?: boolean;
  placeholder?: string;
  autoCapitalize?: "none" | "sentences" | "words" | "characters";
  colors: ColorScheme;
  shadow: ShadowScheme;
}

function Field({ multiline, colors, shadow, ...props }: FieldProps) {
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <BaseField
      {...(props as any)}
      multiline={multiline}
      containerStyle={styles.fieldGroup}
      inputStyle={multiline ? [styles.input, styles.inputMultiline] : styles.input}
    />
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    fieldGroup: { marginBottom: spacing.sm },
    fieldLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 5 },
    // minHeight (not height) so larger accessibility text grows the field
    // instead of clipping — components/Field.tsx pattern. This also retires
    // the old fixed-height paint bug (device finding 2026-07-14): nothing
    // pins the field anymore, so multiline no longer needs to cancel it.
    input: { fontFamily: fonts.bodyRegular, backgroundColor: colors.background, borderRadius: radius.md, minHeight: 44, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    // `minHeight: 88` is load-bearing — do NOT delete it as redundant. This
    // style is applied after `input` above (whose minHeight: 44 would
    // otherwise override BaseField's own 88pt `inputMulti` floor, shrinking
    // the pre-existing Payment instructions field). The old `height:
    // undefined` cancel is gone with the fixed height it cancelled.
    inputMultiline: { minHeight: 88, paddingTop: spacing.sm, textAlignVertical: "top" },
    logoHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginBottom: spacing.sm },
    logoPicker: { alignSelf: "flex-start", marginBottom: spacing.xs },
    logoImage: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.background },
    logoPlaceholder: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", alignItems: "center", justifyContent: "center" },
    logoPlaceholderIcon: { marginBottom: 2 },
    logoPlaceholderText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted },
    logoRemoveBtn: { alignSelf: "flex-start", marginTop: 4, minHeight: 44, justifyContent: "center" },
    logoRemoveText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.danger },
    providerGrid: { flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: spacing.sm },
    providerBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    providerBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    providerLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    providerLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
    ruleSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    ruleRow: { flexDirection: "row", alignItems: "center", backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.sm, marginBottom: spacing.sm, ...shadow.card },
    ruleInput: { fontFamily: fonts.bodyRegular, width: 56, height: 36, backgroundColor: colors.background, borderRadius: radius.sm, textAlign: "center", fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, marginRight: spacing.sm },
    ruleSuffix: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.sm, color: colors.textSecondary },
    removeBtn: { padding: spacing.sm },
    addRuleBtn: { paddingVertical: spacing.sm, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", marginBottom: spacing.sm },
    addRuleBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.accent },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    clearSampleBtn: { marginTop: spacing.lg, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    clearSampleText: { fontFamily: fonts.bodyMedium, color: colors.textSecondary, fontSize: fontSize.md },
    signOutBtn: { marginTop: spacing.sm, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger + "50", backgroundColor: colors.dangerBg },
    signOutText: { fontFamily: fonts.bodySemiBold, color: colors.danger, fontSize: fontSize.md },
    deleteAccountBtn: { marginTop: spacing.sm, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, backgroundColor: colors.danger },
    deleteAccountText: { fontFamily: fonts.bodySemiBold, color: "#fff", fontSize: fontSize.md },
    modalBackdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.5)", justifyContent: "center", padding: spacing.lg },
    // Centred alert-style card (the backdrop insets it with `padding`, not a
    // margin, so the column token composes safely here). Keeps the card from
    // spanning the full iPad window; a no-op below 700pt.
    modalCard: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.lg, ...shadow.card, ...layout.contentColumn },
    modalTitle: { fontFamily: fonts.display, fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: spacing.sm },
    modalBody: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    modalBtnRow: { flexDirection: "row", justifyContent: "flex-end", gap: 12, marginTop: spacing.md },
    modalCancelBtn: { minHeight: 44, justifyContent: "center", paddingHorizontal: 16, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border },
    modalCancelText: { fontFamily: fonts.bodyMedium, color: colors.textPrimary, fontSize: fontSize.md },
    modalDeleteBtn: { minHeight: 44, justifyContent: "center", paddingHorizontal: 16, borderRadius: radius.md, backgroundColor: colors.danger },
    modalDeleteText: { fontFamily: fonts.bodySemiBold, color: "#fff", fontSize: fontSize.md },
    tradeGrid: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 4 },
    tradeBtn: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background },
    tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tradeLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    tradeLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    listRow: { flexDirection: "row", alignItems: "center", paddingVertical: 13 },
    listRowText: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.md, color: colors.textPrimary },
    listRowSub: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 2 },
    listRowChevron: { fontSize: 20, color: colors.textMuted },
    listRowDivider: { height: StyleSheet.hairlineWidth, backgroundColor: colors.border },
    subStatusRow: { flexDirection: "row", alignItems: "center" },
    subStatusDot: { width: 8, height: 8, borderRadius: 4, marginRight: 8 },
    subStatusLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm },
    stripeConnectedRow: { flexDirection: "row", alignItems: "center", marginBottom: 6 },
    stripeConnectedDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.success, marginRight: 8 },
    stripeConnectedLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.success },
    stripeOnboardingHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    stripeButtonRow: { flexDirection: "row", gap: 8, marginTop: spacing.sm },
    stripeBtn: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.accent, alignItems: "center", justifyContent: "center" },
    stripeBtnText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.accent },
    stripeBtnDanger: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger + "80", alignItems: "center", justifyContent: "center" },
    stripeBtnDangerText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.danger },
    stripeConnectBtn: { marginTop: spacing.sm, paddingVertical: 12, borderRadius: radius.md, backgroundColor: colors.accent, alignItems: "center" },
    stripeConnectBtnText: { fontFamily: fonts.bodyBold, fontSize: fontSize.sm, color: "#fff" },
  });
}
