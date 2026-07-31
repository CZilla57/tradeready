import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { computeConversionFunnel } from '../../utils/conversionFunnel';
import type { Job, JobStatus } from '../../types/models';

// Floor so a zero-count stage still renders a visible sliver instead of
// vanishing — the bar means "reached this stage at all", not just "count".
const MIN_BAR_PCT = 6;

const STATUS_COLOR_KEY: Record<JobStatus, keyof ColorScheme> = {
  lead: 'statusLead',
  estimate_sent: 'statusEstimate',
  approved: 'statusApproved',
  scheduled: 'statusScheduled',
  in_progress: 'statusInProgress',
  complete: 'statusComplete',
  invoiced: 'statusInvoiced',
  paid: 'statusPaid',
  declined: 'statusDeclined',
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
      <View style={styles.headerRow}>
        <Text style={styles.sectionTitle}>Job Pipeline</Text>
        {funnel.winRate !== null && (
          <Text style={styles.winRateBadge}>{Math.round(funnel.winRate * 100)}% win rate</Text>
        )}
      </View>

      {funnel.stages.map((stage, i) => {
        const barWidth = maxCount > 0
          ? Math.max((stage.count / maxCount) * 100, MIN_BAR_PCT)
          : MIN_BAR_PCT;
        const color = colors[STATUS_COLOR_KEY[stage.status]];

        return (
          <View key={stage.status}>
            {i > 0 && stage.rate !== null && (
              <Text style={styles.stageConnector}>
                ↓ {Math.round(stage.rate * 100)}% from {funnel.stages[i - 1].label}
              </Text>
            )}
            <View style={styles.stageCaption}>
              <Text style={styles.stageCount}>{stage.count}</Text>
              <Text style={styles.stageLabel}>{stage.label}</Text>
            </View>
            <View style={styles.stageTrack}>
              <View style={[styles.stageBar, { width: `${barWidth}%`, backgroundColor: color }]} />
            </View>
          </View>
        );
      })}
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
    headerRow: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'baseline',
      marginBottom: spacing.md,
    },
    sectionTitle: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
    },
    winRateBadge: {
      fontFamily: fonts.mono,
      color: colors.success,
      fontSize: 11,
      textTransform: 'uppercase',
      letterSpacing: 0.3,
    },
    stageConnector: {
      fontFamily: fonts.mono,
      color: colors.textMuted,
      fontSize: 10,
      textAlign: 'center',
      marginVertical: 3,
    },
    stageCaption: {
      flexDirection: 'row',
      justifyContent: 'center',
      alignItems: 'baseline',
      gap: 6,
      marginBottom: 4,
    },
    stageCount: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontVariant: ['tabular-nums'],
    },
    stageLabel: {
      fontFamily: fonts.bodyRegular,
      color: colors.textSecondary,
      fontSize: fontSize.sm,
    },
    stageTrack: {
      alignItems: 'center',
    },
    stageBar: {
      height: 24,
      borderRadius: radius.sm,
    },
  });
}
