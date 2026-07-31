import React, { useState, useCallback, useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize, fonts } from '../../utils/theme';
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
        <View style={styles.titleRow}>
          <Ionicons name="pricetags-outline" size={16} color={colors.textSecondary} />
          <Text style={styles.title}>Pricebook</Text>
        </View>
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
    titleRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
    title: { fontFamily: fonts.display, color: colors.textPrimary, fontSize: fontSize.md + 1 },
    chevron: { color: colors.textMuted, fontSize: fontSize.lg + 4, fontWeight: '400' },
    amount: { fontFamily: fonts.display, color: colors.accent, fontSize: fontSize.xl, marginTop: spacing.sm, fontVariant: ['tabular-nums'] },
    sub: { fontFamily: fonts.mono, color: colors.textSecondary, fontSize: 10, marginTop: spacing.xs },
  });
}
