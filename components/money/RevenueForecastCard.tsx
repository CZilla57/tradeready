import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeRevenueForecast } from '../../utils/revenueForecast';
import { CardScope } from './CardScope';
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
  const likelyPct = data.totalForecast > 0 ? (data.certainValue / data.totalForecast) * 100 : 0;

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.sectionTitle}>Revenue Forecast</Text>
        {winRatePct !== null && (
          <Text style={[styles.winRateBadge, { color: winRatePct > 50 ? colors.success : colors.warning }]}>
            {winRatePct}% win rate
          </Text>
        )}
      </View>
      <CardScope label="Open pipeline" />

      <View style={styles.headlineBlock}>
        <Text style={[styles.headlineValue, { color: colors.accent }]}>
          {formatMoney(data.totalForecast)}
        </Text>
        <Text style={styles.headlineLabel}>Forecasted Revenue</Text>
      </View>

      {/* Confidence bar: opacity stands in for certainty since the app has no
          gradient/pattern-fill primitive — solid "likely", faint "projected". */}
      <View style={styles.confidenceBar}>
        <View style={[styles.confidenceLikely, { width: `${likelyPct}%` }]} />
        <View style={[styles.confidenceProjected, { width: `${100 - likelyPct}%` }]} />
      </View>

      <View style={styles.breakdownRow}>
        <View style={styles.breakdownCol}>
          <View style={styles.breakdownLabelRow}>
            <View style={[styles.swatch, { backgroundColor: colors.accent }]} />
            <Text style={styles.breakdownLabel}>Likely</Text>
          </View>
          <Text style={styles.breakdownValue}>{formatMoney(data.certainValue)}</Text>
          <Text style={styles.breakdownSub}>
            {data.certainCount} job{data.certainCount !== 1 ? 's' : ''} at 100%
          </Text>
        </View>

        <View style={styles.breakdownDivider} />

        <View style={styles.breakdownCol}>
          <View style={styles.breakdownLabelRow}>
            <View style={[styles.swatch, styles.swatchProjected, { borderColor: colors.accent }]} />
            <Text style={styles.breakdownLabel}>Projected</Text>
          </View>
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
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
    },
    winRateBadge: {
      fontFamily: fonts.mono,
      fontSize: 11,
      textTransform: 'uppercase',
      letterSpacing: 0.3,
    },
    headlineBlock: {
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    headlineValue: {
      fontFamily: fonts.display,
      fontSize: fontSize.xxl,
      letterSpacing: -0.3,
      fontVariant: ['tabular-nums'],
    },
    headlineLabel: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 10,
      textTransform: 'uppercase',
      letterSpacing: 0.5,
      marginTop: 6,
    },
    confidenceBar: {
      flexDirection: 'row',
      height: 10,
      borderRadius: 5,
      overflow: 'hidden',
      backgroundColor: colors.border,
      marginBottom: spacing.md,
    },
    confidenceLikely: {
      backgroundColor: colors.accent,
    },
    confidenceProjected: {
      backgroundColor: colors.accent,
      opacity: 0.3,
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
    breakdownLabelRow: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 5,
      marginBottom: 4,
    },
    swatch: {
      width: 8,
      height: 8,
      borderRadius: 2,
    },
    swatchProjected: {
      backgroundColor: 'transparent',
      borderWidth: 1.5,
    },
    breakdownLabel: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 9.5,
      textTransform: 'uppercase',
      letterSpacing: 0.4,
    },
    breakdownValue: {
      fontFamily: fonts.display,
      color: colors.textPrimary,
      fontSize: fontSize.md,
      fontVariant: ['tabular-nums'],
    },
    breakdownSub: {
      fontFamily: fonts.bodyRegular,
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
