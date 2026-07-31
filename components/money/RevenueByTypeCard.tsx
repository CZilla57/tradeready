import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeRevenueByType } from '../../utils/revenueByType';
import type { Job } from '../../types/models';

interface RevenueByTypeCardProps {
  jobs: Job[];
}

export const RevenueByTypeCard = React.memo(function RevenueByTypeCard({ jobs }: RevenueByTypeCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const data = useMemo(() => computeRevenueByType(jobs), [jobs]);

  if (data.jobCount === 0) return null;

  return (
    <View style={styles.card}>
      <Text style={styles.sectionTitle}>Revenue Breakdown</Text>
      <Text style={styles.subtitle}>
        {formatMoney(data.totalRevenue)} from {data.jobCount} completed job{data.jobCount !== 1 ? 's' : ''}
      </Text>

      {data.components.map((comp) => (
        <View key={comp.label} style={styles.row}>
          <View style={styles.rowHeader}>
            <Text style={styles.rowLabel}>{comp.label}</Text>
            <Text style={styles.rowAmount}>{formatMoney(comp.total)}</Text>
          </View>
          <View style={styles.barBg}>
            <View style={[styles.barFill, { width: `${comp.pct}%`, backgroundColor: colors[comp.color] }]} />
          </View>
          <Text style={styles.rowPct}>{comp.pct}%</Text>
        </View>
      ))}
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
      marginBottom: 4,
    },
    subtitle: {
      fontFamily: fonts.bodyRegular,
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      marginBottom: spacing.md,
    },
    row: {
      marginBottom: spacing.sm + 2,
    },
    rowHeader: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'center',
      marginBottom: 4,
    },
    rowLabel: {
      fontFamily: fonts.bodySemiBold,
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
    },
    rowAmount: {
      fontFamily: fonts.display,
      color: colors.textSecondary,
      fontSize: fontSize.sm + 1,
      fontVariant: ['tabular-nums'],
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
    rowPct: {
      fontFamily: fonts.mono,
      color: colors.textMuted,
      fontSize: 10,
      marginTop: 2,
    },
  });
}
