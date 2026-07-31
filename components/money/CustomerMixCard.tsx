import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, fonts, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeCustomerMix } from '../../utils/customerMix';
import type { Invoice } from '../../types/models';

interface CustomerMixCardProps {
  invoices: Invoice[];
  start: Date;
  end: Date;
}

export const CustomerMixCard = React.memo(function CustomerMixCard({ invoices, start, end }: CustomerMixCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const mix = useMemo(() => computeCustomerMix(invoices, start, end), [invoices, start, end]);

  const total = mix.newCount + mix.returningCount;
  if (total === 0) return null;

  const totalRevenue = mix.newRevenue + mix.returningRevenue;
  const newPct = totalRevenue > 0 ? Math.round((mix.newRevenue / totalRevenue) * 100) : 0;
  const retPct = totalRevenue > 0 ? 100 - newPct : 0;

  return (
    <View style={styles.card}>
      <Text style={styles.sectionTitle}>Customer Mix</Text>

      <View style={styles.columns}>
        <View style={styles.col}>
          <Text style={[styles.colCount, { color: colors.accent }]}>{mix.newCount}</Text>
          <Text style={styles.colLabel}>New</Text>
          <Text style={styles.colRevenue}>{formatMoney(mix.newRevenue)}</Text>
        </View>

        <View style={styles.divider} />

        <View style={styles.col}>
          <Text style={[styles.colCount, { color: colors.success }]}>{mix.returningCount}</Text>
          <Text style={styles.colLabel}>Returning</Text>
          <Text style={styles.colRevenue}>{formatMoney(mix.returningRevenue)}</Text>
        </View>
      </View>

      {totalRevenue > 0 && (
        <View style={styles.barContainer}>
          {mix.newRevenue > 0 && (
            <View style={[styles.barSegment, { flex: newPct, backgroundColor: colors.accent, borderTopLeftRadius: 3, borderBottomLeftRadius: 3, borderTopRightRadius: mix.returningRevenue > 0 ? 0 : 3, borderBottomRightRadius: mix.returningRevenue > 0 ? 0 : 3 }]} />
          )}
          {mix.returningRevenue > 0 && (
            <View style={[styles.barSegment, { flex: retPct, backgroundColor: colors.success, borderTopRightRadius: 3, borderBottomRightRadius: 3, borderTopLeftRadius: mix.newRevenue > 0 ? 0 : 3, borderBottomLeftRadius: mix.newRevenue > 0 ? 0 : 3 }]} />
          )}
        </View>
      )}

      {totalRevenue > 0 && (
        <View style={styles.pctRow}>
          {mix.newRevenue > 0 && <Text style={[styles.pctLabel, { color: colors.accent }]}>{newPct}% new</Text>}
          {mix.returningRevenue > 0 && <Text style={[styles.pctLabel, { color: colors.success }]}>{retPct}% returning</Text>}
        </View>
      )}
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
      marginBottom: spacing.md,
    },
    columns: {
      flexDirection: 'row',
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    col: {
      flex: 1,
      alignItems: 'center',
    },
    colCount: {
      fontFamily: fonts.display,
      fontSize: fontSize.xl + 4,
      letterSpacing: -0.5,
      fontVariant: ['tabular-nums'],
    },
    colLabel: {
      fontFamily: fonts.mono,
      color: colors.textSecondary,
      fontSize: 10,
      textTransform: 'uppercase',
      letterSpacing: 0.3,
      marginTop: 2,
      marginBottom: 4,
    },
    colRevenue: {
      fontFamily: fonts.bodySemiBold,
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
    },
    divider: {
      width: 1,
      height: 48,
      backgroundColor: colors.border,
      marginHorizontal: spacing.sm,
    },
    barContainer: {
      flexDirection: 'row',
      height: 6,
      borderRadius: 3,
      overflow: 'hidden',
    },
    barSegment: {
      height: '100%',
    },
    pctRow: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      marginTop: 6,
    },
    pctLabel: {
      fontFamily: fonts.mono,
      fontSize: 10,
    },
  });
}
