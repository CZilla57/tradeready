import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeInvoiceAging } from '../../utils/invoiceAging';
import type { Invoice } from '../../types/models';

const MAX_SLOW_PAYERS = 3;

function daysColor(days: number, colors: ColorScheme): string {
  if (days <= 0) return colors.success;
  if (days <= 14) return colors.accent;
  if (days <= 30) return colors.warning;
  return colors.danger;
}

function daysLabel(days: number): string {
  if (days < 0) return `${Math.abs(days)}d early`;
  if (days === 0) return 'On time';
  return `${days}d late`;
}

interface InvoiceAgingCardProps {
  invoices: Invoice[];
}

export function InvoiceAgingCard({ invoices }: InvoiceAgingCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const aging = useMemo(() => computeInvoiceAging(invoices), [invoices]);

  if (aging.paidCount === 0) return null;

  const slowPayers = aging.customers.filter((c) => c.avgDays > 0).slice(0, MAX_SLOW_PAYERS);

  return (
    <View style={styles.card}>
      <Text style={styles.sectionTitle}>Days to Pay</Text>

      <View style={styles.heroRow}>
        <Text style={[styles.heroValue, { color: daysColor(aging.avgDays, colors) }]}>
          {daysLabel(aging.avgDays)}
        </Text>
        <Text style={styles.heroSub}>avg across {aging.paidCount} invoice{aging.paidCount !== 1 ? 's' : ''}</Text>
      </View>

      {slowPayers.length > 0 && (
        <View style={styles.slowSection}>
          <Text style={styles.slowHeader}>Slowest Payers</Text>
          {slowPayers.map((c) => (
            <View key={c.name} style={styles.slowRow}>
              <View style={styles.slowInfo}>
                <Text style={styles.slowName} numberOfLines={1}>{c.name}</Text>
                <Text style={styles.slowMeta}>
                  {c.invoiceCount} inv · {formatMoney(c.totalAmount)}
                </Text>
              </View>
              <Text style={[styles.slowDays, { color: daysColor(c.avgDays, colors) }]}>
                {c.avgDays}d
              </Text>
            </View>
          ))}
        </View>
      )}
    </View>
  );
}

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
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      fontWeight: '600',
      marginBottom: spacing.md,
    },
    heroRow: {
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    heroValue: {
      fontSize: fontSize.xl + 4,
      fontWeight: '700',
      letterSpacing: -0.5,
    },
    heroSub: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      marginTop: 4,
    },
    slowSection: {
      paddingTop: spacing.md,
      borderTopWidth: 1,
      borderTopColor: colors.border,
    },
    slowHeader: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      fontWeight: '500',
      textTransform: 'uppercase',
      letterSpacing: 0.5,
      marginBottom: spacing.sm,
    },
    slowRow: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      paddingVertical: 8,
    },
    slowInfo: {
      flex: 1,
      marginRight: spacing.sm,
    },
    slowName: {
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontWeight: '500',
    },
    slowMeta: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: 2,
    },
    slowDays: {
      fontSize: fontSize.md + 1,
      fontWeight: '700',
      minWidth: 40,
      textAlign: 'right',
    },
  });
}
