import React, { useMemo } from 'react';
import { View, Text, TouchableOpacity, Alert, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { EXPENSE_CATEGORIES } from '../../utils/moneyUtils';
import { formatMoney } from '../../utils/format';
import type { Expense } from '../../types/models';

interface ExpenseRowProps {
  expense: Expense;
  onDelete: (id: string) => void;
}

export const ExpenseRow = React.memo(function ExpenseRow({ expense, onDelete }: ExpenseRowProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const category = EXPENSE_CATEGORIES.find(c => c.id === expense.category) || EXPENSE_CATEGORIES[7];
  const dateStr = new Date(expense.date).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
  });

  function confirmDelete() {
    Alert.alert(
      'Delete Expense',
      `Remove "${expense.description}"?`,
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Delete', style: 'destructive', onPress: () => onDelete(expense.id) },
      ]
    );
  }

  return (
    <View style={styles.expenseRow}>
      <View style={styles.expenseIcon}>
        <Text style={styles.expenseIconText}>{category.icon}</Text>
      </View>

      <View style={styles.expenseDetails}>
        <Text style={styles.expenseDescription} numberOfLines={1}>
          {expense.description}
        </Text>
        <Text style={styles.expenseMeta}>
          {category.label} · {dateStr}{expense.receiptUri ? ' · 📷' : ''}
        </Text>
        {expense.notes ? (
          <Text style={styles.expenseNotes} numberOfLines={1}>{expense.notes}</Text>
        ) : null}
      </View>

      <Text style={styles.expenseAmount}>{formatMoney(expense.amount)}</Text>

      <TouchableOpacity
        style={styles.deleteBtn}
        onPress={confirmDelete}
        hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
        accessibilityLabel="Delete expense"
        accessibilityRole="button"
      >
        <Text style={styles.deleteBtnText}>✕</Text>
      </TouchableOpacity>
    </View>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    expenseRow: {
      flexDirection: 'row',
      alignItems: 'center',
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      padding: 14,
      marginBottom: spacing.sm,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    expenseIcon: {
      width: 40,
      height: 40,
      borderRadius: radius.sm + 2,
      backgroundColor: colors.surfaceSecondary,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: spacing.md,
    },
    expenseIconText: {
      fontSize: 18,
    },
    expenseDetails: {
      flex: 1,
      marginRight: spacing.md,
    },
    expenseDescription: {
      color: colors.textPrimary,
      fontSize: fontSize.md,
      fontWeight: '600',
      marginBottom: 2,
    },
    expenseMeta: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
    },
    expenseNotes: {
      color: colors.textMuted,
      fontSize: fontSize.xs - 1,
      marginTop: 2,
    },
    expenseAmount: {
      color: colors.danger,
      fontSize: fontSize.md,
      fontWeight: '700',
    },
    deleteBtn: {
      marginLeft: 10,
      width: 28,
      height: 28,
      borderRadius: 14,
      backgroundColor: colors.dangerBg,
      alignItems: 'center',
      justifyContent: 'center',
    },
    deleteBtnText: {
      fontSize: 13,
      fontWeight: '600',
      color: colors.danger,
    },
  });
}
