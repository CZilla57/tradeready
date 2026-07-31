import React, { useState, useCallback, useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize, fonts } from '../../utils/theme';
import type { ColorScheme, ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { loadTrips, loadSettings } from '../../utils/storage';
import { mileageSummary, formatMiles, DEFAULT_MILEAGE_RATE } from '../../utils/mileageUtils';
import type { Trip } from '../../types/models';

interface Props { start: Date; end: Date; onPress: () => void; }

export const MileageCard = React.memo(function MileageCard({ start, end, onPress }: Props) {
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
        <View style={styles.titleRow}>
          <Ionicons name="car-outline" size={16} color={colors.textSecondary} />
          <Text style={styles.title}>Mileage deduction</Text>
        </View>
        <Text style={styles.chevron}>›</Text>
      </View>
      <Text style={styles.amount}>{formatMoney(summary.deduction)}</Text>
      <Text style={styles.sub}>
        {formatMiles(summary.totalMiles)} · {summary.tripCount} trip{summary.tripCount === 1 ? '' : 's'} · {formatMoney(rate)}/mi
      </Text>
    </TouchableOpacity>
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
    headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
    titleRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
    title: { fontFamily: fonts.display, color: colors.textPrimary, fontSize: fontSize.md + 1 },
    chevron: { color: colors.textMuted, fontSize: fontSize.lg + 4, fontWeight: '400' },
    amount: { fontFamily: fonts.display, color: colors.accent, fontSize: fontSize.xl, marginTop: spacing.sm, fontVariant: ['tabular-nums'] },
    sub: { fontFamily: fonts.mono, color: colors.textSecondary, fontSize: 10, marginTop: spacing.xs },
  });
}
