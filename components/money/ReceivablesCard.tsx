import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import type { Invoice, Job } from '../../types/models';

const PIPELINE_STATUSES = ['lead','estimate_sent','approved','scheduled','in_progress','complete'];

interface ReceivablesCardProps {
  invoices: Invoice[];
  jobs: Job[];
}

export const ReceivablesCard = React.memo(function ReceivablesCard({ invoices, jobs }: ReceivablesCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const { unpaid, totalOutstanding, overdue, totalOverdue, pipelineJobs, pipelineValue } = useMemo(() => {
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const unpaid           = invoices.filter(inv => !inv.paid);
    const totalOutstanding = unpaid.reduce((s, inv) => s + (parseFloat(String(inv.amount)) || 0), 0);
    const overdue          = unpaid.filter(inv => inv.due && new Date(inv.due) < today);
    const totalOverdue     = overdue.reduce((s, inv) => s + (parseFloat(String(inv.amount)) || 0), 0);

    const pipelineJobs  = jobs.filter(j => PIPELINE_STATUSES.includes(j.status) && j.estimateTotal > 0);
    const pipelineValue = pipelineJobs.reduce((s, j) => s + j.estimateTotal, 0);

    return { unpaid, totalOutstanding, overdue, totalOverdue, pipelineJobs, pipelineValue };
  }, [invoices, jobs]);

  if (totalOutstanding === 0 && pipelineValue === 0) return null;

  return (
    <View style={styles.receivablesCard}>
      <Text style={styles.receivablesTitle}>Money owed to you</Text>
      <View style={styles.summaryRow}>
        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Outstanding</Text>
          <Text style={styles.summaryAmount}>{formatMoney(totalOutstanding)}</Text>
          <Text style={styles.receivablesSub}>
            {unpaid.length} invoice{unpaid.length !== 1 ? 's' : ''}
          </Text>
        </View>

        <View style={styles.summaryDivider} />

        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Overdue</Text>
          <Text style={[
            styles.summaryAmount,
            { color: overdue.length > 0 ? colors.danger : colors.textMuted },
          ]}>
            {formatMoney(totalOverdue)}
          </Text>
          <Text style={styles.receivablesSub}>
            {overdue.length} invoice{overdue.length !== 1 ? 's' : ''}
          </Text>
        </View>

        <View style={styles.summaryDivider} />

        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Pipeline</Text>
          <Text style={[styles.summaryAmount, { color: colors.accent }]}>
            {formatMoney(pipelineValue)}
          </Text>
          <Text style={styles.receivablesSub}>
            {pipelineJobs.length} job{pipelineJobs.length !== 1 ? 's' : ''}
          </Text>
        </View>
      </View>
    </View>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    receivablesCard: {
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    receivablesTitle: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontWeight: '500',
      textTransform: 'uppercase',
      letterSpacing: 0.5,
      marginBottom: spacing.md,
    },
    receivablesSub: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: 2,
    },
    summaryRow: {
      flexDirection: 'row',
      alignItems: 'center',
    },
    summaryColumn: {
      flex: 1,
      alignItems: 'center',
    },
    summaryColumnLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      marginBottom: 6,
    },
    summaryAmount: {
      fontSize: fontSize.xl - 4,
      fontWeight: '700',
      letterSpacing: -0.3,
    },
    summaryDivider: {
      width: 1,
      height: 40,
      backgroundColor: colors.border,
      marginHorizontal: spacing.sm,
    },
  });
}
