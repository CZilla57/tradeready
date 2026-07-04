import React from 'react';
import { View, Text, TouchableOpacity, Alert, StyleSheet } from 'react-native';
import { colors, spacing, radius, fontSize, shadow } from '../../utils/theme';
import { EXPENSE_CATEGORIES, formatCurrency } from '../../utils/moneyUtils';

export function ExpenseRow({ expense, onDelete }) {
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
    <TouchableOpacity style={styles.expenseRow} onLongPress={confirmDelete}>
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

      <Text style={styles.expenseAmount}>{formatCurrency(expense.amount)}</Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
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
});
