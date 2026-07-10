import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeSeasonalTrends } from '../../utils/seasonalTrends';
import type { Invoice } from '../../types/models';

const BAR_MAX_HEIGHT = 80;

interface SeasonalTrendsCardProps {
  invoices: Invoice[];
}

export const SeasonalTrendsCard = React.memo(function SeasonalTrendsCard({ invoices }: SeasonalTrendsCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const data = useMemo(() => computeSeasonalTrends(invoices), [invoices]);

  const hasAnyData = data.thisYearTotal > 0 || data.lastYearTotal > 0;
  if (!hasAnyData) return null;

  const maxValue = Math.max(
    ...data.months.map((m) => Math.max(m.thisYear, m.lastYear)),
    1,
  );

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.sectionTitle}>12-Month Trend</Text>
        {data.yoyChangePct !== null && data.yoyChangePct !== 0 && (
          <Text style={[styles.yoyBadge, { color: data.yoyChangePct > 0 ? colors.success : colors.danger }]}>
            {data.yoyChangePct > 0 ? '↑' : '↓'} {Math.abs(data.yoyChangePct)}% YoY
          </Text>
        )}
      </View>

      <View style={styles.legend}>
        <View style={styles.legendItem}>
          <View style={[styles.legendDot, { backgroundColor: colors.accent }]} />
          <Text style={styles.legendLabel}>This year</Text>
        </View>
        <View style={styles.legendItem}>
          <View style={[styles.legendDot, { backgroundColor: colors.border, opacity: 0.8 }]} />
          <Text style={styles.legendLabel}>Last year</Text>
        </View>
      </View>

      <View style={styles.chartArea}>
        {data.months.map((month, i) => {
          const thisH = maxValue > 0 ? (month.thisYear / maxValue) * BAR_MAX_HEIGHT : 0;
          const lastH = maxValue > 0 ? (month.lastYear / maxValue) * BAR_MAX_HEIGHT : 0;

          return (
            <View key={i} style={styles.monthGroup}>
              <View style={styles.barPair}>
                <View style={[styles.barWrapper, { height: BAR_MAX_HEIGHT }]}>
                  <View style={[styles.ghostBar, { height: lastH, backgroundColor: colors.border }]} />
                </View>
                <View style={[styles.barWrapper, { height: BAR_MAX_HEIGHT }]}>
                  <View style={[styles.bar, { height: thisH, backgroundColor: colors.accent }]} />
                </View>
              </View>
              <Text style={styles.monthLabel}>{month.label}</Text>
            </View>
          );
        })}
      </View>

      <View style={styles.totalsRow}>
        <View style={styles.totalCol}>
          <Text style={styles.totalLabel}>This Year</Text>
          <Text style={[styles.totalValue, { color: colors.accent }]}>{formatMoney(data.thisYearTotal)}</Text>
        </View>
        {data.lastYearTotal > 0 && (
          <>
            <View style={styles.totalDivider} />
            <View style={styles.totalCol}>
              <Text style={styles.totalLabel}>Last Year</Text>
              <Text style={styles.totalValue}>{formatMoney(data.lastYearTotal)}</Text>
            </View>
          </>
        )}
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
    yoyBadge: {
      fontSize: fontSize.sm,
      fontWeight: '600',
    },
    legend: {
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
    monthGroup: {
      alignItems: 'center',
      flex: 1,
    },
    barPair: {
      flexDirection: 'row',
      alignItems: 'flex-end',
      gap: 1,
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
    ghostBar: {
      width: '100%',
      borderRadius: 2,
      minHeight: 2,
      opacity: 0.5,
    },
    monthLabel: {
      color: colors.textMuted,
      fontSize: 9,
      marginTop: 4,
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
