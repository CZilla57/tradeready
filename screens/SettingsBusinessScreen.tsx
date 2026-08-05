// screens/SettingsBusinessScreen.tsx
import React, { useEffect, useMemo, useRef } from "react";
import { View, Text, ScrollView, TouchableOpacity, StyleSheet, KeyboardAvoidingView, Platform } from "react-native";
import { Image } from "expo-image";
import { Ionicons } from "@expo/vector-icons";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { validateEmailPhone } from "../utils/settingsValidation";
import { TRADE_TYPES } from "../utils/pricingEngine";
import { promptForLogo } from "../utils/logoPicker";
import { deletePhoto, photoExists, listPhotos } from "../utils/photoStorage";
import { orphanedLogoPaths, sweepableLogoPaths } from "../utils/logoLifecycle";
import { useAuth } from "../context/AuthContext";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

function formatPhone(raw: string): string {
  const digits = raw.replace(/\D/g, "").slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
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

export default function SettingsBusinessScreen({ navigation }: TodayStackScreenProps<'SettingsBusiness'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  // The sweep's precondition is that the settings we just loaded are
  // authoritative for this user. While initialSync is still pulling them down
  // they are not — right after a sign-out/sign-in on the same device, local
  // settings read back as defaults (logoPhoto "") while the user's real logo
  // file is still on disk, and sweeping against that would delete it. Mirrored
  // into a ref because the load effect is registered once.
  const { bootstrapping } = useAuth();
  const bootstrappingRef = useRef(bootstrapping);
  useEffect(() => { if (bootstrapping) bootstrappingRef.current = true; }, [bootstrapping]);

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

  const { s, update } = useSettingsDraft(navigation, {
    validate: (flushed) => validateEmailPhone({ email: flushed.email, phone: flushed.phone }),
    // Both save paths and the guard's Discard reclaim logo files the
    // committed settings no longer reference — the old screen's
    // cleanupLogoFiles contract, unchanged.
    onSaved: (saved) => cleanupLogoFiles(saved.logoPhoto),
    onDiscarded: (saved) => cleanupLogoFiles(saved.logoPhoto),
    // The old load effect's logo half (monolith lines 317–341), verbatim
    // including the raw-path-before-sanitization comment. The provider-key
    // half (lines 307–316) belongs to SettingsPaymentsScreen.
    prepare: async (loaded) => {
      const persistedLogoPath = loaded.logoPhoto;
      let next = loaded;
      if (next.logoPhoto && !(await photoExists(next.logoPhoto))) {
        next = { ...next, logoPhoto: "" };
      }
      if (!bootstrappingRef.current) {
        await sweepOrphanedLogos(persistedLogoPath);
      }
      touchedLogoPathsRef.current = next.logoPhoto ? [next.logoPhoto] : [];
      return next;
    },
  });

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

  if (!s) return null;

  return (
    <View style={styles.container}>
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
        <View style={styles.card}>
          <Field label="Business name" value={s.businessName} onChangeText={(v) => update("businessName", v)} colors={colors} />
          <Field label="Your name" value={s.contactName} onChangeText={(v) => update("contactName", v)} colors={colors} />
          <Field label="Phone" value={s.phone} onChangeText={(v) => update("phone", formatPhone(v))} keyboardType="phone-pad" colors={colors} />
          <Field label="Email" value={s.email} onChangeText={(v) => update("email", v)} keyboardType="email-address" colors={colors} />
          <Field label="Business address" value={s.address} onChangeText={(v) => update("address", v)} multiline autoCapitalize="words" colors={colors} />
          <Field label="Payment instructions" value={s.paymentNotes} onChangeText={(v) => update("paymentNotes", v)} multiline autoCapitalize="sentences" colors={colors} />
          <Field label="Region" value={s.region || ""} onChangeText={(v) => update("region", v)} colors={colors} />
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
      </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    fieldLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 5 },
    tradeGrid: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 4 },
    tradeBtn: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background },
    tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tradeLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    tradeLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    logoHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginBottom: spacing.sm },
    logoPicker: { alignSelf: "flex-start", marginBottom: spacing.xs },
    logoImage: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.background },
    logoPlaceholder: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", alignItems: "center", justifyContent: "center" },
    logoPlaceholderIcon: { marginBottom: 2 },
    logoPlaceholderText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted },
    logoRemoveBtn: { alignSelf: "flex-start", marginTop: 4, minHeight: 44, justifyContent: "center" },
    logoRemoveText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.danger },
  });
}
