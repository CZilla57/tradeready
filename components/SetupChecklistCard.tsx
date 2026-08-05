// components/SetupChecklistCard.tsx
// The in-product "Finish setting up" card on Today — home of everything the
// slimmed onboarding no longer collects (contact details, logo, pricing
// review, payment processor, notifications). Task completion is derived or
// recorded in utils/setupChecklist.ts; the card hides itself once every task
// is done, or forever when the user dismisses it.

import React, { useState, useCallback, useMemo } from "react";
import { View, Text, TouchableOpacity, StyleSheet, Alert, Linking } from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { Ionicons } from "@expo/vector-icons";
import * as Notifications from "expo-notifications";
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { requestPermissions, syncNotifications } from "../utils/notifications";
import {
  deriveSetupTasks,
  loadSetupChecklistState,
  dismissSetupChecklist,
  type SetupChecklistState,
  type SetupTaskId,
} from "../utils/setupChecklist";
import type { Settings } from "../types/models";
import { track } from "../utils/analytics";

interface SetupChecklistCardProps {
  settings: Settings | null;
  onOpenSettings: (task: SetupTaskId) => void;
}

export function SetupChecklistCard({ settings, onOpenSettings }: SetupChecklistCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [state, setState] = useState<SetupChecklistState | null>(null);
  const [notifGranted, setNotifGranted] = useState(false);
  const [hidden, setHidden] = useState(false);

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

  if (hidden || !settings || state === null || state.dismissed) return null;

  const tasks = deriveSetupTasks(settings, state, notifGranted);
  const doneCount = tasks.filter(t => t.done).length;
  if (doneCount === tasks.length) return null;

  async function handleNotificationsTask() {
    track("setup_checklist_task_opened", { task: "notifications" });
    const granted = await requestPermissions();
    if (granted) {
      setNotifGranted(true);
      syncNotifications();
    } else {
      Alert.alert(
        "Notifications are off",
        "Enable notifications for TradeReady in your device settings to get invoice reminders.",
        [
          { text: "Not now", style: "cancel" },
          { text: "Open device settings", onPress: () => Linking.openSettings().catch(() => {}) },
        ]
      );
    }
  }

  function handleTask(id: SetupTaskId) {
    if (id === "notifications") {
      handleNotificationsTask();
      return;
    }
    track("setup_checklist_task_opened", { task: id });
    onOpenSettings(id);
  }

  function handleDismiss() {
    track("setup_checklist_dismissed", { doneCount });
    setHidden(true); // hide immediately; persistence follows
    dismissSetupChecklist();
  }

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Finish setting up</Text>
        <Text style={styles.progress}>{doneCount} of {tasks.length}</Text>
        <TouchableOpacity
          onPress={handleDismiss}
          hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
          accessibilityRole="button"
          accessibilityLabel="Hide setup checklist"
        >
          <Text style={styles.hideText}>Hide</Text>
        </TouchableOpacity>
      </View>
      {tasks.map((task, i) => (
        <TouchableOpacity
          key={task.id}
          style={[styles.taskRow, i > 0 && styles.taskRowBorder]}
          onPress={() => handleTask(task.id)}
          disabled={task.done}
          activeOpacity={0.7}
          accessibilityRole="button"
          accessibilityLabel={task.title}
          accessibilityState={{ disabled: task.done, checked: task.done }}
        >
          <Ionicons
            name={task.done ? "checkmark-circle" : "ellipse-outline"}
            size={22}
            color={task.done ? colors.success : colors.textMuted}
          />
          <View style={styles.taskText}>
            <Text style={[styles.taskTitle, task.done && styles.taskTitleDone]}>{task.title}</Text>
            {!task.done && <Text style={styles.taskSubtitle}>{task.subtitle}</Text>}
          </View>
          {!task.done && <Text style={styles.chevron}>›</Text>}
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
    progress: { fontFamily: fonts.mono, fontSize: 11, color: colors.textSecondary },
    hideText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textMuted },
    taskRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm, paddingVertical: spacing.sm, minHeight: 44 },
    taskRowBorder: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
    taskText: { flex: 1 },
    taskTitle: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    taskTitleDone: { color: colors.textMuted, textDecorationLine: "line-through" },
    taskSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textSecondary, marginTop: 1 },
    chevron: { fontFamily: fonts.bodyRegular, fontSize: fontSize.lg, color: colors.textMuted },
  });
}
