import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeExpenseTrends } from '../../utils/expenseTrends';
import type { Expense } from '../../types/models';

const BAR_MAX_HEIGHT = 80;

interface ExpenseTrendsCardProps {
  expenses: Expense[];
}

export const ExpenseTrendsCard = React.memo(function ExpenseTrendsCard({ expenses }: ExpenseTrendsCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const data = useMemo(() => computeExpenseTrends(expenses), [expenses]);

  if (data.trailingTotal === 0) return null;

  const maxValue = Math.max(...data.months.map(m => m.total), 1);

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.sectionTitle}>Expense Trends</Text>
        {data.overallTrend !== null && data.overallTrend !== 0 && (
          <Text style={[styles.trendBadge, { color: data.overallTrend < 0 ? colors.success : colors.danger }]}>
            {data.overallTrend < 0 ? '↓' : '↑'} {Math.abs(data.overallTrend)}%
          </Text>
        )}
      </View>

      <View style={styles.chartArea}>
        {data.months.map((month, i) => {
          const barH = maxValue > 0 ? (month.total / maxValue) * BAR_MAX_HEIGHT : 0;
          const mom = month.momChangePct;
          const showMom = mom !== null && mom !== 0;

          return (
            <View key={i} style={styles.monthGroup}>
              <View style={[styles.barWrapper, { height: BAR_MAX_HEIGHT }]}>
                <View style={[styles.bar, { height: barH, backgroundColor: colors.danger }]} />
              </View>
              <Text style={styles.monthLabel}>{month.label}</Text>
              {showMom ? (
                <Text style={[styles.momBadge, { color: mom < 0 ? colors.success : colors.danger }]}>
                  {mom < 0 ? '↓' : '↑'}{Math.abs(mom)}
                </Text>
              ) : (
                <Text style={styles.momBadge}>{' '}</Text>
              )}
            </View>
          );
        })}
      </View>

      <View style={styles.totalsRow}>
        <View style={styles.totalCol}>
          <Text style={styles.totalLabel}>12-Mo Total</Text>
          <Text style={[styles.totalValue, { color: colors.danger }]}>{formatMoney(data.trailingTotal)}</Text>
        </View>
        <View style={styles.totalDivider} />
        <View style={styles.totalCol}>
          <Text style={styles.totalLabel}>Monthly Avg</Text>
          <Text style={styles.totalValue}>{formatMoney(data.avgMonthly)}</Text>
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
    trendBadge: {
      fontSize: fontSize.sm,
      fontWeight: '600',
    },
    chartArea: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'flex-end',
    },
    monthGroup: {
      alignItems: 'center',
      flex: 1,
    },
    barWrapper: {
      width: 6,
      justifyContent: 'flex-end',
    },
    bar: {
      width: '100%',
      borderRadius: 2,
      minHeight: 2,
    },
    monthLabel: {
      color: colors.textMuted,
      fontSize: 9,
      marginTop: 4,
    },
    momBadge: {
      fontSize: 8,
      fontWeight: '600',
      marginTop: 2,
      minHeight: 10,
    },
    totalsRow: {
      flexDirection: 'row',
      alignItems: 'center',
      marginTop: spacing.md,
      paddingTop: spacing.md,
      borderTopWidth: 1,
      borderTopColor: colors.border,
    },
    totalCol: {
      flex: 1,
      alignItems: 'center',
    },
    totalLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      marginBottom: 4,
    },
    totalValue: {
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontWeight: '600',
    },
    totalDivider: {
      width: 1,
      height: 32,
      backgroundColor: colors.border,
      marginHorizontal: spacing.sm,
    },
  });
}
