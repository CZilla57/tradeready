import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { getLast6MonthLabels, parseLocalDate } from '../../utils/moneyUtils';
import type { Invoice, Expense } from '../../types/models';

const BAR_MAX_HEIGHT = 80;

interface MonthlyChartProps {
  invoices: Invoice[];
  expenses: Expense[];
}

export const MonthlyChart = React.memo(function MonthlyChart({ invoices, expenses }: MonthlyChartProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const chartData = useMemo(() => {
    const months = getLast6MonthLabels();
    return months.map(({ label, year, month }) => {
      const monthIncome = invoices
        .filter(inv => {
          const dateStr = inv.paidAt || inv.due;
          if (!inv.paid || !dateStr) return false;
          const d = parseLocalDate(dateStr);
          return d.getFullYear() === year && d.getMonth() === month;
        })
        .reduce((sum, inv) => sum + (parseFloat(String(inv.amount)) || 0), 0);

      const monthExpenses = expenses
        .filter(exp => {
          const d = parseLocalDate(exp.date);
          return d.getFullYear() === year && d.getMonth() === month;
        })
        .reduce((sum, exp) => sum + (parseFloat(String(exp.amount)) || 0), 0);

      return { label, income: monthIncome, expenses: monthExpenses };
    });
  }, [invoices, expenses]);

  const maxValue = Math.max(
    ...chartData.map(d => Math.max(d.income, d.expenses)),
    1
  );

  return (
    <View style={styles.chartCard}>
      <Text style={styles.sectionTitle}>Last 6 Months</Text>

      <View style={styles.chartLegend}>
        <View style={styles.legendItem}>
          <View style={[styles.legendDot, { backgroundColor: colors.success }]} />
          <Text style={styles.legendLabel}>Income</Text>
        </View>
        <View style={styles.legendItem}>
          <View style={[styles.legendDot, { backgroundColor: colors.danger }]} />
          <Text style={styles.legendLabel}>Expenses</Text>
        </View>
      </View>

      <View style={styles.chartArea}>
        {chartData.map((month, index) => (
          <View key={index} style={styles.chartMonthGroup}>
            <View style={[styles.chartBarWrapper, { height: BAR_MAX_HEIGHT }]}>
              <View style={[
                styles.chartBar,
                { height: (month.income / maxValue) * BAR_MAX_HEIGHT, backgroundColor: colors.success },
              ]} />
            </View>
            <View style={[styles.chartBarWrapper, { height: BAR_MAX_HEIGHT }]}>
              <View style={[
                styles.chartBar,
                { height: (month.expenses / maxValue) * BAR_MAX_HEIGHT, backgroundColor: colors.danger },
              ]} />
            </View>
            <Text style={styles.chartMonthLabel}>{month.label}</Text>
          </View>
        ))}
      </View>
    </View>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    chartCard: {
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
    chartLegend: {
      flexDirection: 'row',
      gap: spacing.md,
      marginBottom: spacing.md,
    },
    legendItem: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 6,
    },
    legendDot: {
      width: 8,
      height: 8,
      borderRadius: 4,
    },
    legendLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
    },
    chartArea: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'flex-end',
    },
    chartMonthGroup: {
      alignItems: 'center',
      flex: 1,
    },
    chartBarWrapper: {
      width: 12,
      justifyContent: 'flex-end',
      marginHorizontal: 2,
    },
    chartBar: {
      width: '100%',
      borderRadius: 3,
      minHeight: 2,
    },
    chartMonthLabel: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: 6,
    },
  });
}
