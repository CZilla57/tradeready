import React, { useState, useMemo, useCallback } from 'react';
import { View, Text, FlatList, TouchableOpacity, ScrollView, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { useRefresh } from '../hooks/useRefresh';
import { DATE_FILTERS, getDateRange, isInRange } from '../utils/moneyUtils';
import { formatMoney } from '../utils/format';
import { loadTrips, loadSettings } from '../utils/storage';
import { mileageSummary, formatMiles, DEFAULT_MILEAGE_RATE } from '../utils/mileageUtils';
import type { Trip } from '../types/models';

export default function MileageLogScreen({ navigation, route }: any) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [rate, setRate] = useState<number>(DEFAULT_MILEAGE_RATE);
  const [activeFilter, setActiveFilter] = useState<string>(route.params?.initialFilter ?? 'this_year');

  useFocusEffect(
    useCallback(() => {
      loadTrips().then(setTrips);
      loadSettings().then((s) => setRate(s.mileageRate ?? DEFAULT_MILEAGE_RATE));
    }, []),
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    setTrips(await loadTrips());
    const s = await loadSettings();
    setRate(s.mileageRate ?? DEFAULT_MILEAGE_RATE);
  }, 'MileageLogScreen');

  const { start, end } = getDateRange(activeFilter);
  const summary = mileageSummary(trips, start, end, rate);
  const inRange = useMemo(
    () =>
      trips
        .filter((t) => isInRange(t.date, start, end))
        .sort((a, b) => (a.date < b.date ? 1 : -1)),
    [trips, start, end],
  );

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.filterScroll} contentContainerStyle={styles.filterScrollContent}>
        {DATE_FILTERS.map((f) => (
          <TouchableOpacity
            key={f.id}
            style={[styles.filterChip, activeFilter === f.id && styles.filterChipActive]}
            onPress={() => setActiveFilter(f.id)}
          >
            <Text style={[styles.filterChipText, activeFilter === f.id && styles.filterChipTextActive]}>{f.label}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      <View style={styles.summaryCard}>
        <Text style={styles.summaryLabel}>Estimated deduction</Text>
        <Text style={styles.summaryAmount}>{formatMoney(summary.deduction)}</Text>
        <Text style={styles.summarySub}>
          {formatMiles(summary.totalMiles)} · {summary.tripCount} trip{summary.tripCount === 1 ? '' : 's'} · {formatMoney(rate)}/mi
        </Text>
      </View>

      <FlatList
        refreshing={refreshing}
        onRefresh={onRefresh}
        data={inRange}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => (
          <TouchableOpacity style={styles.row} onPress={() => navigation.navigate('AddTrip', { tripId: item.id })} activeOpacity={0.7}>
            <View style={{ flex: 1 }}>
              <Text style={styles.rowRoute} numberOfLines={1}>{item.fromLabel} → {item.toLabel}</Text>
              <Text style={styles.rowMeta}>{item.date}{item.purpose ? ` · ${item.purpose}` : ''}</Text>
            </View>
            <Text style={styles.rowMiles}>{formatMiles(item.miles)}</Text>
          </TouchableOpacity>
        )}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyIcon}>🚗</Text>
            <Text style={styles.emptyTitle}>No trips logged</Text>
            <Text style={styles.emptyBody}>Tap "+ Add trip" to log your first business drive for this period.</Text>
          </View>
        }
        ListFooterComponent={<View style={{ height: 100 }} />}
      />

      <TouchableOpacity style={styles.addBtn} onPress={() => navigation.navigate('AddTrip')} activeOpacity={0.85}>
        <Text style={styles.addBtnText}>+ Add trip</Text>
      </TouchableOpacity>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    filterScroll: { paddingLeft: spacing.lg, marginTop: spacing.md, marginBottom: spacing.sm, maxHeight: 44 },
    filterScrollContent: { paddingRight: spacing.lg, gap: spacing.sm, alignItems: 'flex-start' as const },
    filterChip: { paddingHorizontal: 14, paddingVertical: 7, borderRadius: radius.full, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, marginRight: spacing.sm },
    filterChipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    filterChipText: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '500' },
    filterChipTextActive: { color: colors.accent, fontWeight: '600' },
    summaryCard: { marginHorizontal: spacing.lg, marginBottom: spacing.md, backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.lg, borderWidth: 1, borderColor: colors.border, ...shadow.card },
    summaryLabel: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '600' },
    summaryAmount: { color: colors.accent, fontSize: fontSize.xxl, fontWeight: '800', marginTop: spacing.xs },
    summarySub: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: spacing.xs },
    list: { paddingHorizontal: spacing.lg },
    row: { flexDirection: 'row', alignItems: 'center', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, marginBottom: spacing.sm },
    rowRoute: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '600' },
    rowMeta: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: 2 },
    rowMiles: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '700', marginLeft: spacing.md },
    empty: { alignItems: 'center', paddingVertical: 60, paddingHorizontal: 40 },
    emptyIcon: { fontSize: 48, marginBottom: spacing.md },
    emptyTitle: { color: colors.textPrimary, fontSize: fontSize.lg, fontWeight: '600', marginBottom: spacing.sm },
    emptyBody: { color: colors.textSecondary, fontSize: fontSize.sm, textAlign: 'center', lineHeight: 20 },
    addBtn: { position: 'absolute', bottom: spacing.xl, alignSelf: 'center', backgroundColor: colors.accent, borderRadius: radius.full, paddingVertical: 14, paddingHorizontal: 28, ...shadow.card },
    addBtnText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
  });
}
