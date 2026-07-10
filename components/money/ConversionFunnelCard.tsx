import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { computeConversionFunnel } from '../../utils/conversionFunnel';
import type { Job, JobStatus } from '../../types/models';

const STATUS_COLOR_KEY: Record<JobStatus, keyof ColorScheme> = {
  lead: 'statusLead',
  estimate_sent: 'statusEstimate',
  approved: 'statusApproved',
  scheduled: 'statusScheduled',
  in_progress: 'statusInProgress',
  complete: 'statusComplete',
  invoiced: 'statusInvoiced',
  paid: 'statusPaid',
};

interface ConversionFunnelCardProps {
  jobs: Job[];
}

export const ConversionFunnelCard = React.memo(function ConversionFunnelCard({ jobs }: ConversionFunnelCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const funnel = useMemo(() => computeConversionFunnel(jobs), [jobs]);

  if (funnel.totalJobs === 0) return null;

  const maxCount = funnel.stages[0].count;

  return (
    <View style={styles.card}>
      <Text style={styles.sectionTitle}>Job Pipeline</Text>

      {funnel.stages.map((stage, i) => {
        const barWidth = maxCount > 0 ? (stage.count / maxCount) * 100 : 0;
        const color = colors[STATUS_COLOR_KEY[stage.status]];

        return (
          <View key={stage.status} style={styles.stageRow}>
            <View style={styles.stageHeader}>
              <Text style={styles.stageLabel}>{stage.label}</Text>
              <Text style={styles.stageCount}>{stage.count}</Text>
            </View>
            <View style={styles.barBg}>
              <View style={[styles.barFill, { width: `${barWidth}%`, backgroundColor: color }]} />
            </View>
            {stage.rate !== null && i > 0 && (
              <Text style={styles.stageRate}>{Math.round(stage.rate * 100)}% from {funnel.stages[i - 1].label}</Text>
            )}
          </View>
        );
      })}

      {funnel.winRate !== null && (
        <View style={styles.winRateBox}>
          <Text style={styles.winRateLabel}>Win Rate</Text>
          <Text style={styles.winRateValue}>{Math.round(funnel.winRate * 100)}%</Text>
          <Text style={styles.winRateSub}>Estimates → Approved</Text>
        </View>
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
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      fontWeight: '600',
      marginBottom: spacing.md,
    },
    stageRow: {
      marginBottom: spacing.sm + 2,
    },
    stageHeader: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'center',
      marginBottom: 4,
    },
    stageLabel: {
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontWeight: '500',
    },
    stageCount: {
      color: colors.textSecondary,
      fontSize: fontSize.sm + 1,
      fontWeight: '600',
    },
    barBg: {
      height: 6,
      backgroundColor: colors.border,
      borderRadius: 3,
      overflow: 'hidden',
    },
    barFill: {
      height: '100%',
      borderRadius: 3,
    },
    stageRate: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: 2,
    },
    winRateBox: {
      marginTop: spacing.md,
      paddingTop: spacing.md,
      borderTopWidth: 1,
      borderTopColor: colors.border,
      alignItems: 'center',
    },
    winRateLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      fontWeight: '500',
      textTransform: 'uppercase',
      letterSpacing: 0.5,
      marginBottom: 4,
    },
    winRateValue: {
      color: colors.success,
      fontSize: fontSize.xl,
      fontWeight: '700',
      letterSpacing: -0.5,
    },
    winRateSub: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: 2,
    },
  });
}
