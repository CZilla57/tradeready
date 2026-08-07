// components/JobProfitabilitySection.tsx
// The Job Detail "Estimate vs actual" card (Phase 13C): est/actual/variance
// rows, the collection summary, honest unknown-data warnings, the "What
// changed?" drill-down, and the pre-linked "Add expense to this job" path.
// Design of record: docs/superpowers/specs/2026-08-07-job-profitability-design.md §9.
//
// Self-contained like ChangeOrdersSection: owns its own storage reads (and
// the one expense write) so JobDetailScreen only mounts it with the job.
// All reads are local-first AsyncStorage loads — nothing here waits on the
// network. Math lives in utils/jobProfitability.ts; row/item strings in
// utils/profitabilityDisplay.ts. This file is presentation only.

import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  Modal,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import {
  loadExpenses,
  loadInvoices,
  loadSettings,
  saveExpenses,
} from "../utils/storage";
import {
  computeJobProfitability,
  linkedExpensesForJob,
} from "../utils/jobProfitability";
import {
  buildCollectionSummary,
  buildProfitabilityRows,
  buildWhatChangedItems,
  shouldShowProfitability,
  warningCopy,
  type VarianceTone,
} from "../utils/profitabilityDisplay";
import { stampExpense } from "../utils/moneyUtils";
import { track, reportError } from "../utils/analytics";
import { AddExpenseModal } from "./money/AddExpenseModal";
import { Card, Divider } from "./UI";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Expense, ExpenseDraft, Invoice, Job, Settings } from "../types/models";

interface JobProfitabilitySectionProps {
  job: Job;
  /**
   * True exactly once, right after the advance that completed the job and
   * stayed on screen — opens the "What changed?" review as the completion
   * moment. Cleared via onReviewShown (component state, never persisted).
   */
  autoOpenReview?: boolean;
  onReviewShown?: () => void;
}

export default function JobProfitabilitySection({
  job,
  autoOpenReview,
  onReviewShown,
}: JobProfitabilitySectionProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [showWhatChanged, setShowWhatChanged] = useState(false);
  const [showAddExpense, setShowAddExpense] = useState(false);

  const reload = useCallback(async () => {
    try {
      const [invs, exps, sett] = await Promise.all([
        loadInvoices(),
        loadExpenses(),
        loadSettings(),
      ]);
      setInvoices(invs);
      setExpenses(exps);
      setSettings(sett);
    } catch (error: unknown) {
      reportError(error, { context: "jobProfitabilityLoad" });
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload])
  );

  useEffect(() => {
    if (autoOpenReview) {
      setShowWhatChanged(true);
      onReviewShown?.();
    }
  }, [autoOpenReview, onReviewShown]);

  async function handleSaveExpense(fields: ExpenseDraft) {
    setShowAddExpense(false);
    try {
      const current = await loadExpenses();
      const updated = [stampExpense(fields), ...current];
      await saveExpenses(updated);
      setExpenses(updated);
      track("expense_logged", {
        category: fields.category,
        linkedToJob: Boolean(fields.jobId),
      });
    } catch (error: unknown) {
      reportError(error, { context: "jobProfitabilityAddExpense" });
    }
  }

  if (!shouldShowProfitability(job) || !settings) return null;

  const p = computeJobProfitability(job, invoices, expenses, settings, new Date());
  const rows = buildProfitabilityRows(job, p);
  const summary = buildCollectionSummary(p);
  const whatChanged = buildWhatChangedItems(job, p, linkedExpensesForJob(job, expenses));

  const toneColor = (tone: VarianceTone | null): string => {
    if (tone === "good") return colors.success;
    if (tone === "bad") return colors.danger;
    return colors.textMuted;
  };

  return (
    <Card style={styles.section}>
      <View style={styles.headerRow}>
        <Text style={styles.sectionTitle}>Estimate vs actual</Text>
        <TouchableOpacity
          onPress={() => setShowWhatChanged(true)}
          accessibilityRole="button"
          accessibilityLabel="What changed on this job"
        >
          <Text style={styles.link}>What changed?</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.colHeaderRow}>
        <View style={styles.labelCol} />
        <Text style={[styles.colHeader, styles.valueCol]}>Estimate</Text>
        <Text style={[styles.colHeader, styles.valueCol]}>Actual</Text>
      </View>

      {rows.map((row) => (
        <View key={row.key} style={styles.row}>
          <View style={styles.labelCol}>
            <Text style={styles.rowLabel}>{row.label}</Text>
            {row.variance != null && (
              <Text style={[styles.variance, { color: toneColor(row.varianceTone) }]}>
                {row.variance}
              </Text>
            )}
          </View>
          <Text style={[styles.value, styles.valueCol]}>{row.estimate}</Text>
          <Text style={[styles.value, styles.valueCol, styles.valueActual]}>
            {row.actual}
          </Text>
        </View>
      ))}

      {summary != null && (
        <>
          <Divider />
          <Text style={styles.summaryLine}>{summary}</Text>
        </>
      )}

      {p.warnings.length > 0 && (
        <View style={styles.warningsBlock}>
          {p.warnings.map((w) => (
            <Text key={w} style={styles.warningText}>
              · {warningCopy(w)}
            </Text>
          ))}
        </View>
      )}

      <TouchableOpacity
        style={styles.addExpenseBtn}
        onPress={() => setShowAddExpense(true)}
        accessibilityRole="button"
        accessibilityLabel="Add expense to this job"
      >
        <Text style={styles.addExpenseText}>+ Add expense to this job</Text>
      </TouchableOpacity>

      <Modal
        visible={showWhatChanged}
        transparent
        animationType="fade"
        onRequestClose={() => setShowWhatChanged(false)}
      >
        <View style={styles.modalBackdrop}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>What changed on this job</Text>
            <ScrollView style={styles.modalList} showsVerticalScrollIndicator={false}>
              {whatChanged.length === 0 ? (
                <Text style={styles.modalEmpty}>
                  Nothing recorded beyond the original estimate yet — approved
                  changes, tracked labor and linked expenses will show up here.
                </Text>
              ) : (
                whatChanged.map((item) => (
                  <View key={item.key} style={styles.modalRow}>
                    <Text style={styles.modalRowLabel} numberOfLines={2}>
                      {item.label}
                    </Text>
                    <Text style={[styles.modalRowAmount, { color: toneColor(item.tone) }]}>
                      {item.amount}
                    </Text>
                  </View>
                ))
              )}
            </ScrollView>
            <TouchableOpacity
              style={styles.modalCloseBtn}
              onPress={() => setShowWhatChanged(false)}
              accessibilityRole="button"
              accessibilityLabel="Close"
            >
              <Text style={styles.modalCloseText}>Close</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

      <AddExpenseModal
        visible={showAddExpense}
        onClose={() => setShowAddExpense(false)}
        onSave={handleSaveExpense}
        jobs={[job]}
        defaultJobId={job.id}
      />
    </Card>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    section: {
      marginBottom: spacing.md,
    },
    headerRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: spacing.sm,
    },
    sectionTitle: {
      fontFamily: fonts.display,
      fontSize: fontSize.lg,
      color: colors.textPrimary,
    },
    link: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.accent,
    },
    colHeaderRow: {
      flexDirection: "row",
      marginBottom: spacing.xs,
    },
    colHeader: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.xs,
      color: colors.textMuted,
      textTransform: "uppercase",
      letterSpacing: 0.5,
      textAlign: "right",
    },
    row: {
      flexDirection: "row",
      alignItems: "center",
      paddingVertical: spacing.xs + 2,
    },
    labelCol: {
      flex: 1.2,
      paddingRight: spacing.sm,
    },
    valueCol: {
      flex: 1,
    },
    rowLabel: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
    variance: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.xs,
      marginTop: 1,
    },
    value: {
      fontFamily: fonts.mono,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      textAlign: "right",
    },
    valueActual: {
      color: colors.textPrimary,
    },
    summaryLine: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: spacing.xs,
    },
    warningsBlock: {
      marginTop: spacing.sm,
    },
    warningText: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.xs,
      color: colors.textMuted,
      marginBottom: 2,
    },
    addExpenseBtn: {
      marginTop: spacing.sm,
      paddingVertical: spacing.sm,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
      backgroundColor: colors.surfaceSecondary,
      alignItems: "center",
    },
    addExpenseText: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.accent,
    },
    modalBackdrop: {
      flex: 1,
      backgroundColor: "rgba(0,0,0,0.4)",
      justifyContent: "center",
      padding: spacing.lg,
    },
    modalCard: {
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      maxHeight: "70%",
      ...layout.contentColumn,
      ...shadow.card,
    },
    modalTitle: {
      fontFamily: fonts.display,
      fontSize: fontSize.lg,
      color: colors.textPrimary,
      marginBottom: spacing.md,
    },
    modalList: {
      marginBottom: spacing.md,
    },
    modalEmpty: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textMuted,
      lineHeight: 20,
    },
    modalRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      paddingVertical: spacing.xs + 2,
      gap: spacing.sm,
    },
    modalRowLabel: {
      flex: 1,
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
    modalRowAmount: {
      fontFamily: fonts.mono,
      fontSize: fontSize.sm,
    },
    modalCloseBtn: {
      paddingVertical: spacing.sm,
      borderRadius: radius.md,
      backgroundColor: colors.surfaceSecondary,
      borderWidth: 1,
      borderColor: colors.border,
      alignItems: "center",
    },
    modalCloseText: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.md,
      color: colors.textSecondary,
    },
  });
}
