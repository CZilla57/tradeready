import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { collectedInRange } from '../../utils/invoicePayments';
import type { Invoice } from '../../types/models';

interface TopCustomersCardProps {
  invoices: Invoice[];
  start: Date;
  end: Date;
}

export const TopCustomersCard = React.memo(function TopCustomersCard({ invoices, start, end }: TopCustomersCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const revenueByCustomer: Record<string, number> = {};
  invoices.forEach(inv => {
    const collected = collectedInRange([inv], start, end);
    if (collected === 0) return;
    revenueByCustomer[inv.customer] = (revenueByCustomer[inv.customer] || 0) + collected;
  });

  const top = Object.entries(revenueByCustomer)
    .map(([name, amount]) => ({ name, amount }))
    .sort((a, b) => b.amount - a.amount)
    .slice(0, 5);

  if (top.length === 0) return null;

  const maxAmount = top[0].amount;

  return (
    <View style={styles.categoryCard}>
      <Text style={styles.sectionTitle}>Top Customers</Text>
      {top.map((c, i) => (
        <View key={c.name} style={styles.categoryBreakdownRow}>
          <Text style={styles.topCustomerRank}>{i + 1}</Text>
          <View style={styles.categoryBreakdownInfo}>
            <View style={styles.categoryBreakdownHeader}>
              <Text style={styles.categoryBreakdownLabel} numberOfLines={1}>{c.name}</Text>
              <Text style={[styles.categoryBreakdownAmount, { color: colors.success }]}>
                {formatMoney(c.amount)}
              </Text>
            </View>
            <View style={styles.categoryProgressBg}>
              <View style={[
                styles.categoryProgressFill,
                { width: `${(c.amount / maxAmount) * 100}%` as `${number}%`, backgroundColor: colors.success, opacity: 1 },
              ]} />
            </View>
          </View>
        </View>
      ))}
    </View>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    categoryCard: {
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
      marginBottom: spacing.md,
    },
    categoryBreakdownRow: {
      flexDirection: 'row',
      alignItems: 'center',
      marginBottom: 14,
    },
    topCustomerRank: {
      fontFamily: fonts.mono,
      fontSize: fontSize.sm,
      color: colors.textMuted,
      width: 20,
      marginRight: spacing.sm,
      textAlign: 'center',
    },
    categoryBreakdownInfo: {
      flex: 1,
    },
    categoryBreakdownHeader: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      marginBottom: spacing.xs,
    },
    categoryBreakdownLabel: {
      fontFamily: fonts.bodySemiBold,
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
    },
    categoryBreakdownAmount: {
      fontFamily: fonts.display,
      color: colors.danger,
      fontSize: fontSize.sm + 1,
      fontVariant: ['tabular-nums'],
    },
    categoryProgressBg: {
      height: 4,
      backgroundColor: colors.border,
      borderRadius: 2,
      overflow: 'hidden',
    },
    categoryProgressFill: {
      height: '100%',
      backgroundColor: colors.danger,
      borderRadius: 2,
      opacity: 0.7,
    },
  });
}
