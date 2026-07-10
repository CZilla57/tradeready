import React, { useMemo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { computeAvgJobValue } from '../../utils/avgJobValue';
import type { Job } from '../../types/models';

interface AvgJobValueCardProps {
  jobs: Job[];
  start: Date;
  end: Date;
  prevStart: Date | null;
  prevEnd: Date | null;
}

export const AvgJobValueCard = React.memo(function AvgJobValueCard({ jobs, start, end, prevStart, prevEnd }: AvgJobValueCardProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const current = useMemo(() => computeAvgJobValue(jobs, start, end), [jobs, start, end]);
  const previous = useMemo(
    () => (prevStart && prevEnd ? computeAvgJobValue(jobs, prevStart, prevEnd) : null),
    [jobs, prevStart, prevEnd],
  );
  const allTime = useMemo(() => computeAvgJobValue(jobs), [jobs]);

  if (allTime.count === 0) return null;

  const changePct =
    previous && previous.avgValue > 0
      ? Math.round(((current.avgValue - previous.avgValue) / previous.avgValue) * 100)
      : null;

  return (
    <View style={styles.card}>
      <Text style={styles.sectionTitle}>Avg Job Value</Text>

      <View style={styles.heroRow}>
        <Text style={styles.heroValue}>{formatMoney(current.count > 0 ? current.avgValue : allTime.avgValue)}</Text>
        {changePct !== null && changePct !== 0 && (
          <Text style={[styles.changeBadge, { color: changePct > 0 ? colors.success : colors.danger }]}>
            {changePct > 0 ? '↑' : '↓'} {Math.abs(changePct)}%
          </Text>
        )}
      </View>

      <View style={styles.detailRow}>
        <View style={styles.detailColumn}>
          <Text style={styles.detailLabel}>Completed</Text>
          <Text style={styles.detailValue}>{current.count > 0 ? current.count : allTime.count} jobs</Text>
        </View>
        <View style={styles.detailDivider} />
        <View style={styles.detailColumn}>
          <Text style={styles.detailLabel}>Total Value</Text>
          <Text style={styles.detailValue}>{formatMoney(current.count > 0 ? current.totalValue : allTime.totalValue)}</Text>
        </View>
      </View>

      {current.count === 0 && allTime.count > 0 && (
        <Text style={styles.allTimeNote}>Showing all-time average</Text>
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
      color: colors.textPrimary,
      fontSize: fontSize.md + 1,
      fontWeight: '600',
      marginBottom: spacing.md,
    },
    heroRow: {
      flexDirection: 'row',
      alignItems: 'baseline',
      gap: spacing.sm,
      marginBottom: spacing.md,
    },
    heroValue: {
      color: colors.accent,
      fontSize: fontSize.xl + 4,
      fontWeight: '700',
      letterSpacing: -0.5,
    },
    changeBadge: {
      fontSize: fontSize.sm,
      fontWeight: '600',
    },
    detailRow: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingTop: spacing.md,
      borderTopWidth: 1,
      borderTopColor: colors.border,
    },
    detailColumn: {
      flex: 1,
      alignItems: 'center',
    },
    detailLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.xs,
      marginBottom: 4,
    },
    detailValue: {
      color: colors.textPrimary,
      fontSize: fontSize.sm + 1,
      fontWeight: '600',
    },
    detailDivider: {
      width: 1,
      height: 32,
      backgroundColor: colors.border,
      marginHorizontal: spacing.sm,
    },
    allTimeNote: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      textAlign: 'center',
      marginTop: spacing.sm,
    },
  });
}
