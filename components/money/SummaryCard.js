import React, { useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { spacing, radius, fontSize } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';

function changePct(current, prev) {
  if (prev === null || prev === 0) return null;
  return Math.round(((current - prev) / Math.abs(prev)) * 100);
}

function ChangeLabel({ pct, inverse, colors }) {
  if (pct === null || pct === 0) return null;
  const isUp = pct > 0;
  const isGood = inverse ? !isUp : isUp;
  return (
    <Text style={[styles_changeLabel, { color: isGood ? colors.success : colors.danger }]}>
      {isUp ? '↑' : '↓'} {Math.abs(pct)}%
    </Text>
  );
}

const styles_changeLabel = {
  fontSize: fontSize.xs,
  fontWeight: '600',
  marginTop: 2,
};

export function SummaryCard({ income, expenses, prevIncome, prevExpenses, label, onAddExpense }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const profit = income - expenses;
  const prevProfit =
    prevIncome !== null && prevExpenses !== null ? prevIncome - prevExpenses : null;
  const isPositive = profit >= 0;

  const incomeChange   = changePct(income, prevIncome);
  const expensesChange = changePct(expenses, prevExpenses);
  const profitChange   = changePct(profit, prevProfit);

  return (
    <View style={styles.summaryCard}>
      <View style={styles.summaryCardHeader}>
        <Text style={styles.summaryPeriodLabel}>{label}</Text>
        <TouchableOpacity style={styles.addExpenseBtn} onPress={onAddExpense}>
          <Text style={styles.addExpenseBtnText}>+ Expense</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.summaryRow}>
        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Income</Text>
          <Text style={[styles.summaryAmount, { color: colors.success }]}>
            {formatMoney(income)}
          </Text>
          <ChangeLabel pct={incomeChange} inverse={false} colors={colors} />
        </View>

        <View style={styles.summaryDivider} />

        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Expenses</Text>
          <Text style={[styles.summaryAmount, { color: colors.danger }]}>
            {formatMoney(expenses)}
          </Text>
          <ChangeLabel pct={expensesChange} inverse={true} colors={colors} />
        </View>

        <View style={styles.summaryDivider} />

        <View style={styles.summaryColumn}>
          <Text style={styles.summaryColumnLabel}>Net Profit</Text>
          <Text style={[styles.summaryAmount, { color: isPositive ? colors.success : colors.danger }]}>
            {formatMoney(profit)}
          </Text>
          <ChangeLabel pct={profitChange} inverse={false} colors={colors} />
        </View>
      </View>

      {income > 0 && (
        <View style={styles.marginBarContainer}>
          <View style={styles.marginBarBg}>
            <View style={[
              styles.marginBarFill,
              {
                width: `${Math.max(0, Math.min(100, (profit / income) * 100))}%`,
                backgroundColor: isPositive ? colors.success : colors.danger,
              },
            ]} />
          </View>
          <Text style={styles.marginLabel}>
            {`${Math.round((profit / income) * 100)}% margin`}
          </Text>
        </View>
      )}
    </View>
  );
}

function createStyles(colors, shadow) {
  return StyleSheet.create({
    summaryCard: {
      marginHorizontal: spacing.lg,
      marginBottom: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    summaryCardHeader: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      marginBottom: spacing.md,
    },
    summaryPeriodLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontWeight: '500',
      textTransform: 'uppercase',
      letterSpacing: 0.5,
    },
    addExpenseBtn: {
      backgroundColor: colors.accent,
      paddingHorizontal: 14,
      paddingVertical: 6,
      borderRadius: radius.full,
      alignItems: 'center',
      justifyContent: 'center',
    },
    addExpenseBtnText: {
      color: colors.textOnAccent,
      fontWeight: '700',
      fontSize: fontSize.sm,
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
    marginBarContainer: {
      marginTop: spacing.md,
      flexDirection: 'row',
      alignItems: 'center',
      gap: 10,
    },
    marginBarBg: {
      flex: 1,
      height: 6,
      backgroundColor: colors.border,
      borderRadius: 3,
      overflow: 'hidden',
    },
    marginBarFill: {
      height: '100%',
      borderRadius: 3,
    },
    marginLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      minWidth: 70,
      textAlign: 'right',
    },
    changeLabel: {
      fontSize: fontSize.xs,
      fontWeight: '600',
      marginTop: 2,
    },
  });
}
