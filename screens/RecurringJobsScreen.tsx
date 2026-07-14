import React, { useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  Alert,
  StyleSheet,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadRecurringJobs, saveRecurringJobs } from "../utils/storage";
import { Badge, EmptyState } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { RecurringJob } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

const CADENCE_LABELS: Record<string, string> = {
  daily: "Daily",
  weekly: "Weekly",
  monthly: "Monthly",
  quarterly: "Quarterly",
  annually: "Annually",
};

export default function RecurringJobsScreen({ navigation }: JobStackScreenProps<'RecurringJobs'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [rules, setRules] = useState<RecurringJob[]>([]);

  useFocusEffect(
    useCallback(() => {
      loadRecurringJobs().then(setRules);
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    setRules(await loadRecurringJobs());
  }, 'RecurringJobsScreen');

  function formatEndCondition(rule: RecurringJob): string {
    if (rule.endCondition === "count") return `Ends after ${rule.endCount} jobs`;
    if (rule.endCondition === "date") return `Ends ${rule.endDate}`;
    return "No end date";
  }

  function handleRowPress(rule: RecurringJob) {
    const actions: { text: string; onPress?: () => void; style?: "cancel" | "destructive" | "default" }[] = [
      {
        text: rule.isActive ? "Pause series" : "Resume series",
        onPress: async () => {
          const updated = rules.map((r) =>
            r.id === rule.id ? { ...r, isActive: !r.isActive } : r
          );
          await saveRecurringJobs(updated);
          setRules(updated);
        },
      },
      {
        text: "Cancel series",
        style: "destructive" as const,
        onPress: () => {
          Alert.alert(
            "Cancel recurring series?",
            "No more jobs will be generated. Jobs already created are not affected.",
            [
              { text: "Keep series", style: "cancel" },
              {
                text: "Cancel series",
                style: "destructive",
                onPress: async () => {
                  const updated = rules.map((r) =>
                    r.id === rule.id ? { ...r, isActive: false } : r
                  );
                  await saveRecurringJobs(updated);
                  setRules(updated);
                },
              },
            ]
          );
        },
      },
      { text: "Dismiss", style: "cancel" as const },
    ];

    Alert.alert(
      rule.title,
      `${CADENCE_LABELS[rule.cadence]} · ${formatEndCondition(rule)}`,
      actions
    );
  }

  function renderRule({ item: rule }: { item: RecurringJob }) {
    return (
      <TouchableOpacity
        style={styles.ruleCard}
        onPress={() => handleRowPress(rule)}
        activeOpacity={0.8}
        accessibilityRole="button"
        accessibilityLabel={`${rule.title}, ${rule.customerName}, ${CADENCE_LABELS[rule.cadence]}, ${rule.isActive ? "active" : "paused"}`}
      >
        <View style={styles.cardTop}>
          <View style={{ flex: 1, marginRight: spacing.sm }}>
            <Text style={styles.ruleTitle} numberOfLines={1}>{rule.title}</Text>
            <Text style={styles.ruleCustomer}>{rule.customerName}</Text>
          </View>
          <Badge
            label={rule.isActive ? "Active" : "Paused"}
            color={rule.isActive ? "success" : "muted"}
          />
        </View>
        <View style={styles.cardBottom}>
          <Text style={styles.ruleMeta}>
            {CADENCE_LABELS[rule.cadence]} · {rule.occurrenceCount} {rule.occurrenceCount === 1 ? "job" : "jobs"} generated
          </Text>
          <Text style={styles.ruleMeta}>{formatEndCondition(rule)}</Text>
        </View>
        {rule.isActive && (
          <Text style={styles.ruleNext}>Next: {rule.nextDueDate}</Text>
        )}
      </TouchableOpacity>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <FlatList
        refreshing={refreshing}
        onRefresh={onRefresh}
        data={rules}
        keyExtractor={(r) => r.id}
        renderItem={renderRule}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <EmptyState message={"Open any job and enable 'Repeat' to set one up."} />
        }
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    list: { padding: spacing.md, paddingBottom: 40 },
    ruleCard: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      padding: spacing.md,
      marginBottom: spacing.sm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
      ...shadow.card,
    },
    cardTop: {
      flexDirection: "row",
      alignItems: "center",
      marginBottom: spacing.xs,
    },
    ruleTitle: {
      fontSize: fontSize.md,
      fontWeight: "600",
      color: colors.textPrimary,
    },
    ruleCustomer: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
    },
    cardBottom: {
      flexDirection: "row",
      justifyContent: "space-between",
      marginTop: spacing.xs,
    },
    ruleMeta: {
      fontSize: fontSize.xs,
      color: colors.textMuted,
    },
    ruleNext: {
      fontSize: fontSize.xs,
      color: colors.accent,
      marginTop: spacing.xs,
    },
  });
}
