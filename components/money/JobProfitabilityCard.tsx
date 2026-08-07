// components/money/JobProfitabilityCard.tsx
// Money-tab aggregate job-profitability card (Phase 13D): medians of
// estimate-vs-actual across completed jobs WITH tracked data. The coverage
// line is explicit about how many jobs actually carry data — medians are
// never presented as if they covered everything. Per-job-type grouping was
// deliberately deferred (owner decision D5, 2026-08-07 design spec §3.5).
// Math: utils/profitabilityAggregate.ts; row strings:
// utils/profitabilityDisplay.ts buildHistorySummaryRows.

import React, { useCallback, useMemo, useState } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { loadSettings } from '../../utils/storage';
import { computeProfitabilityHistory } from '../../utils/profitabilityAggregate';
import { buildHistorySummaryRows } from '../../utils/profitabilityDisplay';
import { CardScope } from './CardScope';
import type { Expense, Invoice, Job, Settings } from '../../types/models';

interface JobProfitabilityCardProps {
  jobs: Job[];
  invoices: Invoice[];
  expenses: Expense[];
}

export const JobProfitabilityCard = React.memo(function JobProfitabilityCard({
  jobs,
  invoices,
  expenses,
}: JobProfitabilityCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  // Settings (laborCostRate) loaded here like TaxSetAsideCard loads its tax
  // fields — MoneyScreen deliberately doesn't hold a settings copy.
  const [settings, setSettings] = useState<Settings | null>(null);

  useFocusEffect(
    useCallback(() => {
      let active = true;
      loadSettings()
        .then((s) => {
          if (active) setSettings(s);
        })
        .catch(() => {});
      return () => {
        active = false;
      };
    }, [])
  );

  const history = useMemo(
    () =>
      settings
        ? computeProfitabilityHistory(jobs, invoices, expenses, settings, new Date())
        : null,
    [jobs, invoices, expenses, settings]
  );

  if (!history || history.doneJobs === 0) return null;

  const rows = buildHistorySummaryRows(history);

  return (
    <View style={styles.card}>
      <Text style={styles.sectionTitle}>Job Profitability</Text>
      <CardScope label="Completed jobs, all time" />

      <Text style={styles.coverage}>
        {history.jobsWithData} of {history.doneJobs} completed job
        {history.doneJobs !== 1 ? 's' : ''} have tracked data
      </Text>

      {rows.length === 0 ? (
        <Text style={styles.emptyText}>
          Track hours and link expenses on jobs to see how your estimates hold
          up in reality.
        </Text>
      ) : (
        rows.map((r) => (
          <View key={r.key} style={styles.row}>
            <Text style={styles.rowLabel}>{r.label}</Text>
            <Text style={styles.rowValue}>{r.value}</Text>
          </View>
        ))
      )}
    </View>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    card: {
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    sectionTitle: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      marginBottom: spacing.md,
    },
    coverage: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 10,
      textTransform: 'uppercase',
      letterSpacing: 0.5,
      marginBottom: spacing.sm,
    },
    emptyText: {
      fontFamily: fonts.bodyRegular,
      color: colors.textMuted,
      fontSize: fontSize.sm,
      lineHeight: 20,
    },
    row: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      paddingVertical: 8,
    },
    rowLabel: {
      fontFamily: fonts.bodyMedium,
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      flex: 1,
      marginRight: spacing.sm,
    },
    rowValue: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.md,
      textAlign: 'right',
    },
  });
}
