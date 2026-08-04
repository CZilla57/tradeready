// screens/StartingPointScreen.tsx
// Step 3 of the first-run flow (2026-08-03 restructure), rendered by the root
// gate AFTER the subscription decision: choose between exploring with sample
// data or starting clean. Nothing is preselected — tapping a card IS the
// choice — so sample data can never be silently seeded. The heavy lifting
// (seeding trade-matched sample invoices vs. clearing the seeds) lives in
// completeStartChoice (utils/storage/lifecycle.ts).

import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { loadSettings, completeStartChoice } from "../utils/storage";
import type { TradeId } from "../types/models";
import { track, reportError } from "../utils/analytics";

type StartChoice = "sample" | "fresh";

const OPTIONS: { id: StartChoice; icon: keyof typeof Ionicons.glyphMap; title: string; desc: string; cta: string }[] = [
  {
    id: "sample",
    icon: "bar-chart-outline",
    title: "Explore with sample data",
    desc: "Look around with example jobs, invoices, and customers already set up. Clear them any time from Settings.",
    cta: "Explore the app",
  },
  {
    id: "fresh",
    icon: "sparkles-outline",
    title: "Start with my business",
    desc: "Begin with a clean slate and add your own customers and jobs from day one.",
    cta: "Start fresh",
  },
];

export default function StartingPointScreen({ onComplete }: { onComplete: () => void }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [trade, setTrade] = useState<TradeId>("plumbing");
  const [choosing, setChoosing] = useState<StartChoice | null>(null);

  useEffect(() => {
    loadSettings().then(s => setTrade(s.trade)).catch(() => {});
    track("onboarding_step_viewed", { step: "starting_point" });
  }, []);

  async function choose(choice: StartChoice) {
    if (choosing) return;
    setChoosing(choice);
    try {
      await completeStartChoice(choice, trade);
      track("onboarding_start_choice", { choice });
      onComplete();
    } catch (err: unknown) {
      reportError(err, { context: "startChoice" });
      Alert.alert("Couldn't finish setup", "Something went wrong. Please try again.");
      setChoosing(null);
    }
  }

  return (
    <SafeAreaView style={styles.container} edges={["top", "bottom"]}>
      <Text style={styles.stepIndicator} accessibilityRole="header">
        Step 3 of 3 · Starting point
      </Text>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <Text style={styles.title}>How do you want to start?</Text>
        <Text style={styles.subtitle}>You're in — one last choice and you're working.</Text>
        {OPTIONS.map(opt => (
          <TouchableOpacity
            key={opt.id}
            style={styles.card}
            onPress={() => choose(opt.id)}
            disabled={choosing !== null}
            activeOpacity={0.8}
            accessibilityRole="button"
            accessibilityLabel={opt.title}
            accessibilityState={{ disabled: choosing !== null, busy: choosing === opt.id }}
          >
            <View style={styles.cardHeader}>
              <Ionicons name={opt.icon} size={22} color={colors.accent} />
              <Text style={styles.cardTitle}>{opt.title}</Text>
            </View>
            <Text style={styles.cardDesc}>{opt.desc}</Text>
            <View style={styles.cardCta}>
              {choosing === opt.id ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <Text style={styles.cardCtaText}>{opt.cta}</Text>
              )}
            </View>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    stepIndicator: {
      fontFamily: fonts.mono,
      fontSize: 12,
      color: colors.textSecondary,
      textAlign: "center",
      textTransform: "uppercase",
      letterSpacing: 1,
      paddingTop: spacing.md,
      paddingBottom: spacing.sm,
      ...layout.contentColumn,
    },
    scroll: { padding: spacing.lg, paddingBottom: spacing.xl, ...layout.contentColumn },
    title: { fontFamily: fonts.display, fontSize: fontSize.xxl, color: colors.textPrimary, marginBottom: spacing.xs },
    subtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textSecondary, marginBottom: spacing.lg, lineHeight: 22 },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.md, borderWidth: 2, borderColor: colors.border, ...shadow.card },
    cardHeader: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginBottom: spacing.sm },
    cardTitle: { fontFamily: fonts.bodySemiBold, flex: 1, fontSize: fontSize.lg, color: colors.textPrimary },
    cardDesc: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20, marginBottom: spacing.md },
    cardCta: { backgroundColor: colors.accent, borderRadius: radius.md, minHeight: 44, alignItems: "center", justifyContent: "center" },
    cardCtaText: { fontFamily: fonts.bodySemiBold, color: "#fff", fontSize: fontSize.md },
  });
}
