import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeRevenueForecast } from '../../utils/revenueForecast';
import type { Job } from '../../types/models';

interface RevenueForecastCardProps {
  jobs: Job[];
}

export const RevenueForecastCard = React.memo(function RevenueForecastCard({ jobs }: RevenueForecastCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const data = useMemo(() => computeRevenueForecast(jobs), [jobs]);

  if (data.totalForecast === 0) return null;

  const winRatePct = data.winRate !== null ? Math.round(data.winRate * 100) : null;

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.sectionTitle}>Revenue Forecast</Text>
        {winRatePct !== null && (
          <Text style={[styles.winRateBadge, { color: winRatePct > 50 ? colors.success : colors.warning }]}>
            Win Rate: {winRatePct}%
          </Text>
        )}
      </View>

      <View style={styles.headlineBlock}>
        <Text style={[styles.headlineValue, { color: colors.accent }]}>
          {formatMoney(data.totalForecast)}
        </Text>
        <Text style={styles.headlineLabel}>Forecasted Revenue</Text>
      </View>

      <View style={styles.breakdownRow}>
        <View style={styles.breakdownCol}>
          <Text style={styles.breakdownLabel}>Likely</Text>
          <Text style={styles.breakdownValue}>{formatMoney(data.certainValue)}</Text>
          <Text style={styles.breakdownSub}>
            {data.certainCount} job{data.certainCount !== 1 ? 's' : ''} at 100%
          </Text>
        </View>

        <View style={styles.breakdownDivider} />

        <View style={styles.breakdownCol}>
          <Text style={styles.breakdownLabel}>Projected</Text>
          <Text style={styles.breakdownValue}>{formatMoney(data.projectedValue)}</Text>
          <Text style={styles.breakdownSub}>
            {data.speculativeCount} job{data.speculativeCount !== 1 ? 's' : ''}{' '}
            {winRatePct !== null ? `at ${winRatePct}%` : '(no win rate)'}
          </Text>
        </View>
      </View>
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
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    sectionTitle: {
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      fontWeight: '600',
    },
    winRateBadge: {
      fontSize: fontSize.sm,
      fontWeight: '600',
    },
    headlineBlock: {
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    headlineValue: {
      fontSize: fontSize.xl,
      fontWeight: '700',
      letterSpacing: -0.5,
    },
    headlineLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      marginTop: 4,
    },
    breakdownRow: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingTop: spacing.md,
      borderTopWidth: 1,
      borderTopColor: colors.border,
    },
    breakdownCol: {
      flex: 1,
      alignItems: 'center',
    },
    breakdownLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      marginBottom: 4,
    },
    breakdownValue: {
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontWeight: '600',
    },
    breakdownSub: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: 2,
    },
    breakdownDivider: {
      width: 1,
      height: 40,
      backgroundColor: colors.border,
      marginHorizontal: spacing.sm,
    },
  });
}
