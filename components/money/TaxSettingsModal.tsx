// components/money/TaxSettingsModal.tsx
// The tax set-aside settings: the user's effective income-tax rate and the
// IRS vehicle-deduction election. Opened from TaxSetAsideCard — there is
// deliberately no Settings-screen entry (the card is the feature's one home).
//
// The vehicle election is a REAL tax election (standard mileage OR actual
// vehicle costs, never both), so the modal explains the consequence and the
// app never pre-selects one. Clearing back to "not chosen" is intentionally
// impossible here — un-electing has no tax meaning; switching methods does.

import React, { useEffect, useMemo, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Modal,
  TextInput,
  Alert,
} from 'react-native';
import { KeyboardDoneBar } from '../KeyboardDoneBar';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { formatMoney } from '../../utils/format';
import { DEFAULT_MILEAGE_RATE } from '../../utils/mileageUtils';
import type { Settings, VehicleDeductionMethod } from '../../types/models';

export interface TaxSettingsDraft {
  taxIncomeRate?: number;
  vehicleDeductionMethod?: VehicleDeductionMethod;
}

interface TaxSettingsModalProps {
  visible: boolean;
  settings: Partial<Settings>;
  onClose: () => void;
  onSave: (draft: TaxSettingsDraft) => void;
}

export const TaxSettingsModal = React.memo(function TaxSettingsModal({
  visible,
  settings,
  onClose,
  onSave,
}: TaxSettingsModalProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [rate, setRate] = useState('');
  const [method, setMethod] = useState<VehicleDeductionMethod | undefined>(undefined);

  // Re-seed from the live settings each time the sheet opens.
  useEffect(() => {
    if (!visible) return;
    setRate(
      settings.taxIncomeRate !== undefined && settings.taxIncomeRate !== null
        ? String(settings.taxIncomeRate)
        : '',
    );
    setMethod(settings.vehicleDeductionMethod);
  }, [visible, settings.taxIncomeRate, settings.vehicleDeductionMethod]);

  function handleSave() {
    const trimmed = rate.trim();
    const draft: TaxSettingsDraft = {};
    if (trimmed.length > 0) {
      const parsed = parseFloat(trimmed);
      if (!Number.isFinite(parsed) || parsed < 0 || parsed > 60) {
        Alert.alert(
          'Check the rate',
          'Enter your effective income-tax rate as a percentage between 0 and 60 — most solo trades land between 10 and 25.',
        );
        return;
      }
      draft.taxIncomeRate = parsed;
    }
    if (method) draft.vehicleDeductionMethod = method;
    onSave(draft);
  }

  const mileageRate = settings.mileageRate ?? DEFAULT_MILEAGE_RATE;

  return (
    <Modal visible={visible} animationType="slide" transparent onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <TouchableOpacity style={{ flex: 1 }} activeOpacity={1} onPress={onClose} />
        <View style={styles.sheet}>
          <ScrollView showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled">
            <Text style={styles.title}>Tax set-aside settings</Text>

            <Text style={styles.label}>Income-tax rate (%)</Text>
            <Text style={styles.help}>
              Your effective federal + state income-tax rate. Self-employment tax
              (15.3%) is always included; this adds the income-tax layer on top.
              Leave blank to estimate with self-employment tax only.
            </Text>
            <TextInput
              style={styles.input}
              value={rate}
              onChangeText={setRate}
              placeholder="e.g. 15"
              placeholderTextColor={colors.textMuted}
              keyboardType="decimal-pad"
              inputAccessoryViewID="taxSettingsDone"
              accessibilityLabel="Income-tax rate percent"
            />

            <Text style={styles.label}>Vehicle deduction</Text>
            <Text style={styles.help}>
              The IRS allows standard mileage ({formatMoney(mileageRate)}/mi from
              your trip log) OR actual costs (your fuel expenses) — never both.
              Until you choose, the estimate deducts neither, which reserves a
              little extra.
            </Text>
            <View style={styles.methodRow}>
              <TouchableOpacity
                style={[styles.methodChip, method === 'mileage' && styles.methodChipActive]}
                onPress={() => setMethod('mileage')}
                accessibilityRole="radio"
                accessibilityLabel="Standard mileage"
                accessibilityState={{ selected: method === 'mileage' }}
              >
                <Text style={[styles.methodText, method === 'mileage' && styles.methodTextActive]}>
                  🚗 Standard mileage
                </Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.methodChip, method === 'actual' && styles.methodChipActive]}
                onPress={() => setMethod('actual')}
                accessibilityRole="radio"
                accessibilityLabel="Actual fuel costs"
                accessibilityState={{ selected: method === 'actual' }}
              >
                <Text style={[styles.methodText, method === 'actual' && styles.methodTextActive]}>
                  ⛽ Actual fuel costs
                </Text>
              </TouchableOpacity>
            </View>
            {!method && (
              <Text style={styles.unsetNote}>No method chosen yet.</Text>
            )}

            <Text style={styles.disclaimer}>
              Estimates only — not tax advice. Talk to a tax professional about
              which method suits your situation.
            </Text>

            <View style={styles.actions}>
              <TouchableOpacity style={styles.cancelBtn} onPress={onClose} accessibilityRole="button" accessibilityLabel="Cancel">
                <Text style={styles.cancelText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.saveBtn} onPress={handleSave} accessibilityRole="button" accessibilityLabel="Save tax settings">
                <Text style={styles.saveText}>Save</Text>
              </TouchableOpacity>
            </View>
          </ScrollView>
          <KeyboardDoneBar nativeID="taxSettingsDone" />
        </View>
      </View>
    </Modal>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.4)' },
    sheet: {
      backgroundColor: colors.surface,
      borderTopLeftRadius: radius.lg + 8,
      borderTopRightRadius: radius.lg + 8,
      padding: spacing.lg,
      maxHeight: '85%',
      ...shadow.card,
    },
    title: { color: colors.textPrimary, fontSize: fontSize.xl, fontWeight: '700', marginBottom: spacing.md },
    label: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '600', marginTop: spacing.sm },
    help: { color: colors.textMuted, fontSize: fontSize.sm, marginTop: 4, marginBottom: spacing.sm, lineHeight: 18 },
    input: {
      backgroundColor: colors.surfaceSecondary,
      borderRadius: radius.sm + 2,
      padding: 14,
      color: colors.textPrimary,
      fontSize: fontSize.md,
      marginBottom: spacing.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    methodRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, marginBottom: spacing.sm },
    methodChip: {
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      borderRadius: radius.full,
      borderWidth: 1,
      borderColor: colors.border,
      backgroundColor: colors.surfaceSecondary,
      minHeight: 44,
      justifyContent: 'center',
    },
    methodChipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    methodText: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '500' },
    methodTextActive: { color: colors.accent, fontWeight: '600' },
    unsetNote: { color: colors.textMuted, fontSize: fontSize.xs, marginBottom: spacing.sm },
    disclaimer: { color: colors.textMuted, fontSize: fontSize.xs, marginTop: spacing.sm, lineHeight: 16 },
    actions: { flexDirection: 'row', gap: spacing.md, marginTop: spacing.md, paddingBottom: spacing.sm },
    cancelBtn: {
      flex: 1, padding: spacing.md, borderRadius: radius.md,
      backgroundColor: colors.surfaceSecondary, alignItems: 'center',
      borderWidth: 1, borderColor: colors.border,
    },
    cancelText: { color: colors.textSecondary, fontWeight: '600', fontSize: fontSize.md },
    saveBtn: {
      flex: 2, padding: spacing.md, borderRadius: radius.md,
      backgroundColor: colors.accent, alignItems: 'center',
    },
    saveText: { color: colors.textOnAccent, fontWeight: '700', fontSize: fontSize.md },
  });
}
