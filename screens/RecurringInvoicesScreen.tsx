// screens/RecurringInvoicesScreen.tsx
// Maintenance-plan (recurring invoice) manager — mirror of RecurringJobsScreen
// over RecurringInvoice rules.
//
// DELIBERATE DIVERGENCE from the mirror: this action sheet HAS an Edit action
// (RecurringJobsScreen's sheet is pause/cancel only) because maintenance-plan
// amounts change (price increases) and cancel-and-recreate would reset the
// occurrence history. Do not "fix" this back to parity.
//
// Cancel follows the jobs precedent exactly: soft-deactivate behind a
// destructive confirm. Generated invoices are real receivables — never touched.

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
import { loadRecurringInvoices, saveRecurringInvoices } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { Badge, EmptyState } from "../components/UI";
import { Fab } from "../components/Fab";
import { formatMoney } from "../utils/format";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { RecurringInvoice } from "../types/models";
import type { InvoiceStackScreenProps } from "../types/navigation";

const CADENCE_LABELS: Record<string, string> = {
  daily: "Daily",
  weekly: "Weekly",
  monthly: "Monthly",
  quarterly: "Quarterly",
  annually: "Annually",
};

export default function RecurringInvoicesScreen({ navigation }: InvoiceStackScreenProps<'RecurringInvoices'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [rules, setRules] = useState<RecurringInvoice[]>([]);

  useFocusEffect(
    useCallback(() => {
      loadRecurringInvoices().then(setRules);
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    setRules(await loadRecurringInvoices());
  }, 'RecurringInvoicesScreen');

  function formatEndCondition(rule: RecurringInvoice): string {
    if (rule.endCondition === "count") return `Ends after ${rule.endCount} invoices`;
    if (rule.endCondition === "date") return `Ends ${rule.endDate}`;
    return "No end date";
  }

  async function setActive(rule: RecurringInvoice, isActive: boolean) {
    const updated = rules.map((r) => (r.id === rule.id ? { ...r, isActive } : r));
    await saveRecurringInvoices(updated);
    setRules(updated);
    // Fire-and-forget: rules aren't saved through saveInvoices, so the sweep
    // doesn't rerun on its own — mirror AddInvoiceScreen's explicit call.
    syncNotifications();
  }

  function handleRowPress(rule: RecurringInvoice) {
    Alert.alert(
      rule.customerName,
      `${CADENCE_LABELS[rule.cadence]} · ${formatMoney(rule.amount)} · ${formatEndCondition(rule)}`,
      [
        {
          text: rule.isActive ? "Pause plan" : "Resume plan",
          onPress: () => { setActive(rule, !rule.isActive); },
        },
        {
          // Deliberate divergence from RecurringJobsScreen — see header comment.
          text: "Edit plan",
          onPress: () => navigation.navigate("AddRecurringInvoice", { ruleId: rule.id }),
        },
        {
          text: "Cancel plan",
          style: "destructive" as const,
          onPress: () => {
            Alert.alert(
              "Cancel maintenance plan?",
              "No more invoices will be generated. Invoices already created are not affected.",
              [
                { text: "Keep plan", style: "cancel" },
                {
                  text: "Cancel plan",
                  style: "destructive",
                  onPress: () => { setActive(rule, false); },
                },
              ]
            );
          },
        },
        { text: "Dismiss", style: "cancel" as const },
      ]
    );
  }

  function renderRule({ item: rule }: { item: RecurringInvoice }) {
    return (
      <TouchableOpacity
        style={styles.ruleCard}
        onPress={() => handleRowPress(rule)}
        activeOpacity={0.8}
        accessibilityRole="button"
        accessibilityLabel={`${rule.customerName}, ${formatMoney(rule.amount)} ${CADENCE_LABELS[rule.cadence]}, ${rule.isActive ? "active" : "paused"}`}
      >
        <View style={styles.cardTop}>
          <View style={{ flex: 1, marginRight: spacing.sm }}>
            <Text style={styles.ruleTitle} numberOfLines={1}>{rule.customerName}</Text>
            <Text style={styles.ruleDesc} numberOfLines={1}>{rule.description || "Maintenance plan"}</Text>
          </View>
          <Badge
            label={rule.isActive ? "Active" : "Paused"}
            color={rule.isActive ? "success" : "muted"}
          />
        </View>
        <View style={styles.cardBottom}>
          <Text style={styles.ruleMeta}>
            {CADENCE_LABELS[rule.cadence]} · {formatMoney(rule.amount)} · {rule.occurrenceCount} {rule.occurrenceCount === 1 ? "invoice" : "invoices"} generated
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
          <EmptyState message={"No maintenance plans yet. Tap + to bill a customer on a schedule."} />
        }
      />
      <Fab
        onPress={() => navigation.navigate("AddRecurringInvoice", {})}
        accessibilityLabel="Add maintenance plan"
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    list: { padding: spacing.md, paddingBottom: 120 },
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
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.md,
      color: colors.textPrimary,
    },
    ruleDesc: {
      fontFamily: fonts.bodyRegular,
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
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.textMuted,
    },
    ruleNext: {
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.accent,
      marginTop: spacing.xs,
    },
  });
}
