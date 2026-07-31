// components/money/TaxSetAsideCard.tsx
// "Put this much aside for taxes" — the current IRS payment period's reserve,
// the year-to-date total, and the period's deadline. All math lives in
// utils/taxEstimate.ts (summarizeTaxWindow); this card only presents it.
//
// Invoices and expenses arrive as props (MoneyScreen already loads them);
// trips and settings self-load on focus like MileageCard. The disclaimer is
// persistent and non-dismissable by design: this is guidance, not tax advice,
// and the card must never look like a filing document.

import React, { useState, useCallback, useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useFocusEffect } from '@react-navigation/native';
import { spacing, radius, fontSize, fonts } from '../../utils/theme';
import type { ColorScheme, ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { loadTrips, loadSettings, saveSettings } from '../../utils/storage';
import {
  summarizeTaxWindow,
  formatPeriodRange,
  formatDeadline,
} from '../../utils/taxEstimate';
import { TaxSettingsModal, type TaxSettingsDraft } from './TaxSettingsModal';
import { track } from '../../utils/analytics';
import type { Expense, Invoice, Settings, Trip } from '../../types/models';

interface Props {
  invoices: Invoice[];
  expenses: Expense[];
}

export const TaxSetAsideCard = React.memo(function TaxSetAsideCard({ invoices, expenses }: Props) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [settings, setSettings] = useState<Partial<Settings>>({});
  const [modalOpen, setModalOpen] = useState(false);

  useFocusEffect(
    useCallback(() => {
      loadTrips().then(setTrips);
      loadSettings().then(setSettings);
    }, []),
  );

  const summary = useMemo(
    () => summarizeTaxWindow({ invoices, expenses, trips, settings }),
    [invoices, expenses, trips, settings],
  );

  async function handleSaveSettings(draft: TaxSettingsDraft) {
    // Merge onto the FULL stored settings, not this card's partial state —
    // saveSettings persists whatever object it is handed.
    const full = await loadSettings();
    const next: Settings = { ...full, ...draft };
    await saveSettings(next);
    setSettings(next);
    setModalOpen(false);
    track('tax_settings_saved', {
      hasIncomeRate: draft.taxIncomeRate !== undefined,
      vehicleMethod: draft.vehicleDeductionMethod ?? 'unset',
    });
  }

  const { period, current, ytd } = summary;

  return (
    <View style={styles.card}>
      <TouchableOpacity
        onPress={() => setModalOpen(true)}
        activeOpacity={0.85}
        accessibilityRole="button"
        accessibilityLabel="Tax set-aside — open settings"
      >
        <View style={styles.headerRow}>
          <View style={styles.titleRow}>
            <Ionicons name="business-outline" size={16} color={colors.textSecondary} />
            <Text style={styles.title}>Tax set-aside</Text>
          </View>
          <Ionicons name="settings-outline" size={16} color={colors.textMuted} />
        </View>

        <Text style={styles.amount}>{formatMoney(current.reserve)}</Text>
        <Text style={styles.sub}>
          {formatPeriodRange(period)} · set aside by {formatDeadline(period)}
        </Text>
        <Text style={styles.ytd}>{formatMoney(ytd.reserve)} for the year so far</Text>

        {summary.needsVehicleChoice && (
          <Text style={styles.prompt}>
            ⚠ Choose standard mileage or actual fuel costs — until then neither
            is deducted
          </Text>
        )}
        {!summary.incomeRateSet && (
          <Text style={styles.prompt}>
            Set your income-tax rate for a fuller estimate (currently
            self-employment tax only)
          </Text>
        )}
        {!current.ratesKnown && (
          <Text style={styles.staleNote}>
            Using the latest built-in IRS rates — this year&apos;s aren&apos;t
            loaded yet
          </Text>
        )}

        <Text style={styles.disclosure}>
          Mileage from this device&apos;s trip log ({summary.ytdTripCount} trip
          {summary.ytdTripCount === 1 ? '' : 's'} this year) — not synced.
        </Text>
        <Text style={styles.disclaimer}>
          Estimate only — not tax advice. Assumes net profit under $200k.
        </Text>
      </TouchableOpacity>

      <TaxSettingsModal
        visible={modalOpen}
        settings={settings}
        onClose={() => setModalOpen(false)}
        onSave={handleSaveSettings}
      />
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
    headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
    titleRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
    title: { fontFamily: fonts.display, color: colors.textPrimary, fontSize: fontSize.md + 1 },
    amount: { fontFamily: fonts.display, color: colors.accent, fontSize: fontSize.xl, marginTop: spacing.sm, fontVariant: ['tabular-nums'] },
    sub: { fontFamily: fonts.mono, color: colors.textSecondary, fontSize: 10, marginTop: spacing.xs },
    ytd: { fontFamily: fonts.bodyRegular, color: colors.textSecondary, fontSize: fontSize.sm, marginTop: 2 },
    prompt: { fontFamily: fonts.bodyRegular, color: colors.warning, fontSize: fontSize.xs, marginTop: spacing.sm, lineHeight: 16 },
    staleNote: { fontFamily: fonts.bodyRegular, color: colors.warning, fontSize: fontSize.xs, marginTop: spacing.xs },
    disclosure: { fontFamily: fonts.bodyRegular, color: colors.textMuted, fontSize: fontSize.xs, marginTop: spacing.sm },
    disclaimer: { fontFamily: fonts.bodyRegular, color: colors.textMuted, fontSize: fontSize.xs, marginTop: 2, fontStyle: 'italic' },
  });
}
