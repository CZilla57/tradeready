// components/InsightsCard.tsx
// Proactive deterministic insights on Today (2026-08-04 spec) — takes the
// setup checklist's visual slot once setup is complete. The rules live in
// utils/todayInsights.ts (pure, tested); this card is presentation + gating:
// nothing renders until the "Finish setting up" card is gone (dismissed or
// every task done — the shared isSetupComplete definition) and at least one
// insight fired. No dismiss button by design: rows disappear on their own as
// the underlying condition resolves.

import React, { useState, useCallback, useMemo, useRef, useEffect } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { Ionicons } from "@expo/vector-icons";
import * as Notifications from "expo-notifications";
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import {
  isSetupComplete,
  loadSetupChecklistState,
  type SetupChecklistState,
} from "../utils/setupChecklist";
import {
  selectTodayInsights,
  type InsightKind,
  type InsightTarget,
  type TodayInsight,
} from "../utils/todayInsights";
import type { Job, Invoice, Settings } from "../types/models";
import { track } from "../utils/analytics";

const VISIBLE_LIMIT = 3;

const KIND_ICONS: Record<InsightKind, keyof typeof Ionicons.glyphMap> = {
  labor_overrun: "timer-outline",
  uninvoiced_complete: "receipt-outline",
  due_soon: "alarm-outline",
  open_slot: "today-outline",
  unscheduled_approved: "calendar-outline",
};

interface InsightsCardProps {
  jobs: Job[];
  invoices: Invoice[];
  settings: Settings | null;
  onNavigate: (target: InsightTarget) => void;
  onAskCoach: (prompt: string) => void;
}

export function InsightsCard({ jobs, invoices, settings, onNavigate, onAskCoach }: InsightsCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [state, setState] = useState<SetupChecklistState | null>(null);
  const [notifGranted, setNotifGranted] = useState(false);

  useFocusEffect(
    useCallback(() => {
      let active = true;
      loadSetupChecklistState().then(s => { if (active) setState(s); });
      Notifications.getPermissionsAsync()
        .then(({ status }) => { if (active) setNotifGranted(status === "granted"); })
        .catch(() => {});
      return () => { active = false; };
    }, [])
  );

  // Static per data change — no ticking timer; the number refreshes on focus.
  const insights = useMemo(
    () => selectTodayInsights(jobs, invoices, new Date()).slice(0, VISIBLE_LIMIT),
    [jobs, invoices]
  );

  const visible =
    !!settings && state !== null && isSetupComplete(settings, state, notifGranted) && insights.length > 0;

  // insight_shown once per distinct visible-kinds set, not per render.
  const shownKey = visible ? insights.map(i => i.kind).join(",") : "";
  const lastShownKey = useRef("");
  useEffect(() => {
    if (shownKey && shownKey !== lastShownKey.current) {
      lastShownKey.current = shownKey;
      track("insight_shown", { kinds: insights.map(i => i.kind) });
    }
  }, [shownKey, insights]);

  if (!visible) return null;

  function handleTap(insight: TodayInsight) {
    track("insight_tapped", { kind: insight.kind });
    onNavigate(insight.target);
  }

  function handleCoach(insight: TodayInsight) {
    if (!insight.coachPrompt) return;
    track("insight_coach_opened", { kind: insight.kind });
    onAskCoach(insight.coachPrompt);
  }

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Insights</Text>
      </View>
      {insights.map((insight, i) => (
        <TouchableOpacity
          key={`${insight.kind}_${i}`}
          style={[styles.row, i > 0 && styles.rowBorder]}
          onPress={() => handleTap(insight)}
          activeOpacity={0.7}
          accessibilityRole="button"
          accessibilityLabel={insight.title}
        >
          <Ionicons name={KIND_ICONS[insight.kind]} size={22} color={colors.accent} />
          <View style={styles.rowText}>
            <Text style={styles.rowTitle}>{insight.title}</Text>
            {insight.detail ? <Text style={styles.rowDetail}>{insight.detail}</Text> : null}
            {insight.coachPrompt ? (
              <TouchableOpacity
                style={styles.coachButton}
                onPress={() => handleCoach(insight)}
                hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                accessibilityRole="button"
                accessibilityLabel="Ask coach about this overrun"
              >
                <Ionicons name="chatbubble-ellipses-outline" size={13} color={colors.accent} />
                <Text style={styles.coachButtonText} maxFontSizeMultiplier={1.4}>Ask coach</Text>
              </TouchableOpacity>
            ) : null}
          </View>
          <Text style={styles.chevron}>›</Text>
        </TouchableOpacity>
      ))}
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    card: {
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.md,
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      ...shadow.card,
    },
    headerRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginBottom: spacing.xs },
    title: { fontFamily: fonts.bodySemiBold, flex: 1, fontSize: fontSize.md, color: colors.textPrimary },
    row: { flexDirection: "row", alignItems: "flex-start", gap: spacing.sm, paddingVertical: spacing.sm, minHeight: 44 },
    rowBorder: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
    rowText: { flex: 1 },
    rowTitle: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    rowDetail: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textSecondary, marginTop: 1 },
    coachButton: {
      flexDirection: "row",
      alignItems: "center",
      gap: 4,
      alignSelf: "flex-start",
      marginTop: spacing.xs,
      paddingHorizontal: spacing.sm,
      paddingVertical: 4,
      borderRadius: radius.sm,
      backgroundColor: colors.accent + "1a",
    },
    coachButtonText: { fontFamily: fonts.bodyBold, fontSize: fontSize.xs, color: colors.accent },
    chevron: { fontFamily: fonts.bodyRegular, fontSize: fontSize.lg, color: colors.textMuted },
  });
}
