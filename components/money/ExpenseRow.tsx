import React, { useMemo } from 'react';
import { View, Text, TouchableOpacity, Alert, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
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
        <Ionicons name={category.icon as keyof typeof Ionicons.glyphMap} size={18} color={colors.textSecondary} />
      </View>

      <View style={styles.expenseDetails}>
        <Text style={styles.expenseDescription} numberOfLines={1}>
          {expense.description}
        </Text>
        <View style={styles.expenseMetaRow}>
          <Text style={styles.expenseMeta}>
            {category.label} · {dateStr}
          </Text>
          {expense.receiptUri && (
            <Ionicons name="camera-outline" size={12} color={colors.textMuted} style={styles.receiptGlyph} />
          )}
        </View>
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
        <Ionicons name="close" size={14} color={colors.danger} />
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
    expenseDetails: {
      flex: 1,
      marginRight: spacing.md,
    },
    expenseDescription: {
      fontFamily: fonts.bodySemiBold,
      color: colors.textPrimary,
      fontSize: fontSize.md,
      marginBottom: 2,
    },
    expenseMetaRow: {
      flexDirection: 'row',
      alignItems: 'center',
    },
    expenseMeta: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 10,
    },
    receiptGlyph: {
      marginLeft: 5,
    },
    expenseNotes: {
      fontFamily: fonts.bodyRegular,
      color: colors.textMuted,
      fontSize: fontSize.xs - 1,
      marginTop: 2,
    },
    expenseAmount: {
      fontFamily: fonts.display,
      color: colors.danger,
      fontSize: fontSize.md,
      fontVariant: ['tabular-nums'],
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
  });
}
