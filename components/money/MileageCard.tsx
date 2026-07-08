import React, { useState, useCallback, useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize } from '../../utils/theme';
import type { ColorScheme, ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { loadTrips, loadSettings } from '../../utils/storage';
import { mileageSummary, formatMiles, DEFAULT_MILEAGE_RATE } from '../../utils/mileageUtils';
import type { Trip } from '../../types/models';

interface Props { start: Date; end: Date; onPress: () => void; }

export function MileageCard({ start, end, onPress }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [rate, setRate] = useState<number>(DEFAULT_MILEAGE_RATE);

  useFocusEffect(
    useCallback(() => {
      loadTrips().then(setTrips);
      loadSettings().then((s) => setRate(s.mileageRate ?? DEFAULT_MILEAGE_RATE));
    }, []),
  );

  const summary = mileageSummary(trips, start, end, rate);

  return (
    <TouchableOpacity style={styles.card} onPress={onPress} activeOpacity={0.85}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>🚗 Mileage deduction</Text>
        <Text style={styles.chevron}>›</Text>
      </View>
      <Text style={styles.amount}>{formatMoney(summary.deduction)}</Text>
      <Text style={styles.sub}>
        {formatMiles(summary.totalMiles)} · {summary.tripCount} trip{summary.tripCount === 1 ? '' : 's'} · {formatMoney(rate)}/mi
      </Text>
    </TouchableOpacity>
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
    headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
    title: { color: colors.textPrimary, fontSize: fontSize.md + 1, fontWeight: '600' },
    chevron: { color: colors.textMuted, fontSize: fontSize.lg + 4, fontWeight: '400' },
    amount: { color: colors.accent, fontSize: fontSize.xl, fontWeight: '700', marginTop: spacing.sm },
    sub: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: spacing.xs },
  });
}
