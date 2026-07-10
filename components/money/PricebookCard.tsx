import React, { useState, useCallback, useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize } from '../../utils/theme';
import type { ColorScheme, ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { loadPricebook } from '../../utils/storage';
import type { PricebookEntry } from '../../types/models';

interface Props { onPress: () => void; }

export const PricebookCard = React.memo(function PricebookCard({ onPress }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [entries, setEntries] = useState<PricebookEntry[]>([]);

  useFocusEffect(
    useCallback(() => {
      loadPricebook().then(setEntries);
    }, []),
  );

  const categoryCount = new Set(entries.map(e => e.category).filter(Boolean)).size;

  return (
    <TouchableOpacity style={styles.card} onPress={onPress} activeOpacity={0.85}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>📋 Pricebook</Text>
        <Text style={styles.chevron}>›</Text>
      </View>
      <Text style={styles.amount}>
        {entries.length} service{entries.length === 1 ? '' : 's'}
      </Text>
      <Text style={styles.sub}>
        {categoryCount > 0
          ? `${categoryCount} categor${categoryCount === 1 ? 'y' : 'ies'}`
          : 'No categories yet'}
        {' · Tap to manage'}
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
    title: { color: colors.textPrimary, fontSize: fontSize.md + 1, fontWeight: '600' },
    chevron: { color: colors.textMuted, fontSize: fontSize.lg + 4, fontWeight: '400' },
    amount: { color: colors.accent, fontSize: fontSize.xl, fontWeight: '700', marginTop: spacing.sm },
    sub: { color: colors.textSecondary, fontSize: fontSize.sm, marginTop: spacing.xs },
  });
}
