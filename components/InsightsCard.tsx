// components/InsightsCard.tsx
// Proactive deterministic insights on Today (2026-08-04 spec; extended by the
// 2026-08-07 Phase 15 contextual-AI spec) — takes the setup checklist's visual
// slot once setup is complete. The rules live in utils/todayInsights.ts (pure,
// tested); this card is presentation + gating: nothing renders until the
// "Finish setting up" card is gone (dismissed or every task done — the shared
// isSetupComplete definition) and at least one insight fired. The original
// kinds self-resolve and deliberately have NO dismiss button; only kinds in
// MUTEABLE_KINDS (long-horizon conditions that can't self-clear) get
// dismiss/snooze, persisted via utils/insightMutes.ts. Every row answers
// "Why am I seeing this?" from its deterministic `reason` (long-press).

import React, { useState, useCallback, useMemo, useRef, useEffect } from "react";
import { View, Text, TouchableOpacity, StyleSheet, Alert } from "react-native";
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
import { resolveSchedule } from "../utils/scheduleConfig";
import { track } from "../utils/analytics";
import {
  loadInsightMutes,
  muteInsight,
  makeMute,
  filterMutedInsights,
  type InsightMute,
} from "../utils/insightMutes";

const VISIBLE_LIMIT = 3;

const KIND_ICONS: Record<InsightKind, keyof typeof Ionicons.glyphMap> = {
  labor_overrun: "timer-outline",
  low_margin_estimate: "trending-down-outline",
  uninvoiced_complete: "receipt-outline",
  due_soon: "alarm-outline",
  open_slot: "today-outline",
  unscheduled_approved: "calendar-outline",
};

// Kinds whose condition can't self-resolve get dismiss (and, when listed in
// SNOOZE_DAYS, snooze). The original five kinds stay OUT of this set by design
// — their rows disappear on their own as the condition resolves (2026-08-04
// owner decision). low_margin_estimate's dismissal is keyed to the job's
// current price (the insight id embeds estimateTotal), so a repriced job
// re-fires despite an earlier dismiss.
const MUTEABLE_KINDS: ReadonlySet<InsightKind> = new Set<InsightKind>(["low_margin_estimate"]);
const SNOOZE_DAYS: Partial<Record<InsightKind, number>> = {};

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
  const [mutes, setMutes] = useState<InsightMute[] | null>(null);
  const lastShownKey = useRef("");

  useFocusEffect(
    useCallback(() => {
      let active = true;
      loadSetupChecklistState().then(s => { if (active) setState(s); });
      loadInsightMutes().then(m => { if (active) setMutes(m); });
      Notifications.getPermissionsAsync()
        .then(({ status }) => { if (active) setNotifGranted(status === "granted"); })
        .catch(() => {});
      return () => {
        active = false;
        // Reset so insight_shown re-fires per focus even if TodayScreen ever
        // stops remounting this card on refocus (it currently does, via the
        // loading toggle — do not rely on that accident).
        lastShownKey.current = "";
      };
    }, [])
  );

  // Static per data change — no ticking timer; the number refreshes on focus.
  const allInsights = useMemo(
    () =>
      selectTodayInsights(
        jobs,
        invoices,
        new Date(),
        settings ? resolveSchedule(settings) : undefined,
        { targetMarginPercent: settings?.marginPercent }
      ),
    [jobs, invoices, settings]
  );

  // Mute-filter BEFORE the top-3 slice so muting a row promotes the next one.
  const insights = useMemo(
    () => filterMutedInsights(allInsights, mutes ?? [], new Date()).slice(0, VISIBLE_LIMIT),
    [allInsights, mutes]
  );

  const visible =
    !!settings &&
    state !== null &&
    mutes !== null &&
    isSetupComplete(settings, state, notifGranted) &&
    insights.length > 0;

  // insight_shown once per distinct visible set, not per render.
  const shownKey = visible ? insights.map(i => i.id).join(",") : "";
  useEffect(() => {
    if (shownKey && shownKey !== lastShownKey.current) {
      lastShownKey.current = shownKey;
      track("insight_shown", { kinds: insights.map(i => i.kind), ids: insights.map(i => i.id) });
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

  function applyMute(insight: TodayInsight, days?: number) {
    // Optimistic: drop the row immediately, persist behind it. muteInsight
    // prunes stale entries against the ids the engine can still emit.
    const now = new Date();
    setMutes(prev => [...(prev ?? []).filter(m => m.id !== insight.id), makeMute(insight.id, now, days)]);
    muteInsight(insight.id, now, { days, liveIds: allInsights.map(i => i.id) }).catch(() => {});
  }

  function handleOverflow(insight: TodayInsight) {
    const snoozeDays = SNOOZE_DAYS[insight.kind];
    Alert.alert(insight.title, undefined, [
      {
        text: "Why am I seeing this?",
        onPress: () => {
          track("insight_reason_viewed", { kind: insight.kind });
          Alert.alert("Why am I seeing this?", insight.reason);
        },
      },
      ...(MUTEABLE_KINDS.has(insight.kind) && snoozeDays
        ? [{
            text: `Snooze ${snoozeDays} days`,
            onPress: () => {
              track("insight_snoozed", { kind: insight.kind, insightId: insight.id, days: snoozeDays });
              applyMute(insight, snoozeDays);
            },
          }]
        : []),
      ...(MUTEABLE_KINDS.has(insight.kind)
        ? [{
            text: "Dismiss",
            style: "destructive" as const,
            onPress: () => {
              track("insight_dismissed", { kind: insight.kind, insightId: insight.id });
              applyMute(insight);
            },
          }]
        : []),
      { text: "Cancel", style: "cancel" as const },
    ]);
  }

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Insights</Text>
      </View>
      {insights.map((insight, i) => (
        <TouchableOpacity
          key={insight.id}
          style={[styles.row, i > 0 && styles.rowBorder]}
          onPress={() => handleTap(insight)}
          onLongPress={() => handleOverflow(insight)}
          activeOpacity={0.7}
          accessibilityRole="button"
          accessibilityLabel={insight.title}
          accessibilityActions={[
            ...(insight.coachPrompt ? [{ name: 'askCoach', label: 'Ask coach' }] : []),
            { name: 'longpress', label: 'More options' },
          ]}
          onAccessibilityAction={(e) => {
            if (e.nativeEvent.actionName === 'askCoach') handleCoach(insight);
            if (e.nativeEvent.actionName === 'longpress') handleOverflow(insight);
          }}
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
                accessibilityLabel={`Ask coach about ${insight.title}`}
              >
                <Ionicons name="chatbubble-ellipses-outline" size={13} color={colors.accent} />
                <Text style={styles.coachButtonText} maxFontSizeMultiplier={1.4}>Ask coach</Text>
              </TouchableOpacity>
            ) : null}
          </View>
          {MUTEABLE_KINDS.has(insight.kind) ? (
            <TouchableOpacity
              onPress={() => handleOverflow(insight)}
              hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
              accessibilityRole="button"
              accessibilityLabel={`Options for ${insight.title}`}
            >
              <Ionicons name="ellipsis-horizontal" size={16} color={colors.textMuted} />
            </TouchableOpacity>
          ) : null}
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
