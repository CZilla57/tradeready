import React, { useState, useEffect, useRef, useMemo } from 'react';
import {
  View,
  Text,
  ActivityIndicator,
  Animated,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Modal,
  TextInput,
  Alert,
  PanResponder,
  Platform,
} from 'react-native';
import { Image } from 'expo-image';
import * as ImagePicker from 'expo-image-picker';
import { persistPhoto, readPhotoAsDataUri } from '../../utils/photoStorage';
import { extractReceipt } from '../../utils/receiptOCR';
import { track } from '../../utils/analytics';
import { DateTimePickerSheet } from '../DateTimePickerSheet';
import { KeyboardDoneBar } from '../KeyboardDoneBar';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { EXPENSE_CATEGORIES } from '../../utils/moneyUtils';
import type { ExpenseDraft } from '../../types/models';

interface AddExpenseModalProps {
  visible: boolean;
  onClose: () => void;
  onSave: (fields: ExpenseDraft) => void;
}

/** Receipt-scan lifecycle for the banner under the photo preview. */
type ScanState = 'idle' | 'reading' | 'filled' | 'empty' | 'failed';

export const AddExpenseModal = React.memo(function AddExpenseModal({ visible, onClose, onSave }: AddExpenseModalProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [description, setDescription]       = useState('');
  const [amount, setAmount]                 = useState('');
  const [category, setCategory]             = useState<string>('materials');
  const [date, setDate]                     = useState(new Date().toISOString().split('T')[0]);
  const [notes, setNotes]                   = useState('');
  const [receiptUri, setReceiptUri]         = useState<string | null>(null);
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [scanState, setScanState]           = useState<ScanState>('idle');
  const [scanLooksBlurry, setScanLooksBlurry] = useState(false);

  // Which fields the user has edited themselves. Scan results only land in
  // untouched fields — user input is never clobbered (a re-scan after swapping
  // the photo MAY replace values a previous scan filled, since those aren't
  // the user's typing). Refs, not state: read inside the async scan callback,
  // so they must always be current.
  const touchedRef = useRef({ description: false, amount: false, date: false, category: false });
  // Monotonic scan id — results from a scan that's no longer current (photo
  // removed/replaced, modal reopened) are discarded.
  const scanIdRef = useRef(0);

  const onCloseRef  = useRef(onClose);
  onCloseRef.current = onClose;

  const translateY = useRef(new Animated.Value(600)).current;

  useEffect(() => {
    if (!visible) return;
    setDescription('');
    setAmount('');
    setCategory('materials');
    setDate(new Date().toISOString().split('T')[0]);
    setNotes('');
    setReceiptUri(null);
    setShowDatePicker(false);
    setScanState('idle');
    setScanLooksBlurry(false);
    touchedRef.current = { description: false, amount: false, date: false, category: false };
    scanIdRef.current++;
    translateY.setValue(600);
    Animated.spring(translateY, {
      toValue: 0,
      useNativeDriver: true,
      damping: 25,
      stiffness: 250,
    }).start();
  }, [visible, translateY]);

  const dismissRef = useRef<() => void>(() => {});
  dismissRef.current = () => {
    Animated.timing(translateY, {
      toValue: 600,
      duration: 220,
      useNativeDriver: true,
    }).start(() => {
      translateY.setValue(600);
      onCloseRef.current();
    });
  };
  const dismiss = () => dismissRef.current();

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onPanResponderTerminationRequest: () => false,
      onPanResponderMove: (_, { dy }) => {
        if (dy > 0) translateY.setValue(dy);
      },
      onPanResponderRelease: (_, { dy, vy }) => {
        if (dy > 80 || vy > 0.5) {
          dismissRef.current();
        } else {
          Animated.spring(translateY, { toValue: 0, useNativeDriver: true, bounciness: 6 }).start();
        }
      },
    })
  ).current;

  /**
   * Read the attached photo and pre-fill untouched fields from it. Extraction
   * NEVER blocks or replaces manual entry: every failure just shows the
   * one-line "couldn't read it" note, and saving stays entirely manual.
   */
  async function runReceiptScan(uri: string) {
    const scanId = ++scanIdRef.current;
    setScanState('reading');
    setScanLooksBlurry(false);

    const dataUri = await readPhotoAsDataUri(uri);
    if (scanIdRef.current !== scanId) return;
    if (!dataUri) {
      setScanState('failed');
      track('receipt_scanned', { outcome: 'failed' });
      return;
    }

    const result = await extractReceipt(dataUri);
    if (scanIdRef.current !== scanId) return;
    if (!result) {
      setScanState('failed');
      track('receipt_scanned', { outcome: 'failed' });
      return;
    }

    const { extraction, route } = result;
    const touched = touchedRef.current;
    let applied = 0;
    if (!touched.description && extraction.merchant) {
      setDescription(extraction.merchant);
      applied++;
    }
    if (!touched.amount && extraction.amount != null) {
      setAmount(Number.isInteger(extraction.amount) ? String(extraction.amount) : extraction.amount.toFixed(2));
      applied++;
    }
    if (!touched.date && extraction.date) {
      setDate(extraction.date);
      applied++;
    }
    if (!touched.category && extraction.category) {
      setCategory(extraction.category);
      applied++;
    }

    setScanLooksBlurry(extraction.confidence === 'low');
    setScanState(applied > 0 ? 'filled' : 'empty');
    track('receipt_scanned', { outcome: applied > 0 ? 'filled' : 'empty', route });
  }

  async function attachReceipt(tempUri: string) {
    const persisted = await persistPhoto(tempUri, 'receipts');
    setReceiptUri(persisted);
    // Awaited so the whole attach-and-scan chain is one promise (nothing in
    // prod awaits it; the UI updates via state as the scan progresses).
    await runReceiptScan(persisted);
  }

  async function pickReceipt() {
    Alert.alert('Add Receipt Photo', undefined, [
      {
        text: 'Take Photo',
        onPress: async () => {
          const { status } = await ImagePicker.requestCameraPermissionsAsync();
          if (status !== 'granted') {
            Alert.alert('Permission needed', 'Camera access is required to take a photo.');
            return;
          }
          const result = await ImagePicker.launchCameraAsync({
            mediaTypes: ['images'], quality: 0.7, allowsEditing: true, aspect: [4, 3],
          });
          if (!result.canceled) {
            await attachReceipt(result.assets[0].uri);
          }
        },
      },
      {
        text: 'Choose from Library',
        onPress: async () => {
          const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
          if (status !== 'granted') {
            Alert.alert('Permission needed', 'Photo library access is required.');
            return;
          }
          const result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ['images'], quality: 0.7, allowsEditing: true, aspect: [4, 3],
          });
          if (!result.canceled) {
            await attachReceipt(result.assets[0].uri);
          }
        },
      },
      { text: 'Cancel', style: 'cancel' },
    ]);
  }

  function removeReceipt() {
    scanIdRef.current++;
    setReceiptUri(null);
    setScanState('idle');
    setScanLooksBlurry(false);
  }

  function handleSave() {
    if (!description.trim()) {
      Alert.alert('Missing Info', 'Please enter a description.');
      return;
    }
    if (!amount || isNaN(parseFloat(amount)) || parseFloat(amount) <= 0) {
      Alert.alert('Missing Info', 'Please enter a valid amount.');
      return;
    }
    onSave({
      description: description.trim(),
      amount:      parseFloat(amount),
      category:    category as ExpenseDraft['category'],
      date:        date || new Date().toISOString().split('T')[0],
      notes:       notes.trim(),
      receiptUri:  receiptUri || null,
    });
  }

  return (
    <Modal visible={visible} animationType="none" transparent onRequestClose={dismiss}>
      <View style={styles.modalBackdrop}>
        <TouchableOpacity style={{ flex: 1 }} activeOpacity={1} onPress={dismiss} />

        <Animated.View style={[styles.modalSheet, { transform: [{ translateY }] }]}>
          <View {...panResponder.panHandlers} style={styles.modalHandleArea}>
            <View style={styles.modalHandle} />
          </View>

          <ScrollView
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
            onScrollEndDrag={({ nativeEvent }) => {
              if (Platform.OS === 'ios' && nativeEvent.contentOffset.y < -60) dismiss();
            }}
          >
            <Text style={styles.modalTitle}>Log Expense</Text>

            <Text style={styles.fieldLabel}>What was it?</Text>
            <TextInput
              style={styles.textInput}
              placeholder="e.g. PVC fittings from Home Depot"
              placeholderTextColor={colors.textMuted}
              value={description}
              onChangeText={(t) => {
                touchedRef.current.description = true;
                setDescription(t);
              }}
              returnKeyType="done"
            />

            <Text style={styles.fieldLabel}>Amount</Text>
            <TextInput
              style={styles.textInput}
              placeholder="0.00"
              placeholderTextColor={colors.textMuted}
              value={amount}
              onChangeText={(t) => {
                touchedRef.current.amount = true;
                setAmount(t);
              }}
              keyboardType="decimal-pad"
              inputAccessoryViewID="expenseModalDone"
            />

            <Text style={styles.fieldLabel}>Date</Text>
            <TouchableOpacity style={styles.expenseDateBtn} onPress={() => setShowDatePicker(true)}>
              <Text style={styles.expenseDateBtnText}>
                {new Date(date + 'T00:00:00').toLocaleDateString('en-US', {
                  weekday: 'long', month: 'long', day: 'numeric',
                })}
              </Text>
              <Text>📅</Text>
            </TouchableOpacity>

            <DateTimePickerSheet
              visible={showDatePicker}
              mode="date"
              title="Select Date"
              value={new Date(date + 'T00:00:00')}
              onChange={(d) => {
                touchedRef.current.date = true;
                setDate(d.toISOString().split('T')[0]);
              }}
              onClose={() => setShowDatePicker(false)}
            />

            <Text style={styles.fieldLabel}>Category</Text>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.categoryScroll}>
              {EXPENSE_CATEGORIES.map(cat => (
                <TouchableOpacity
                  key={cat.id}
                  style={[styles.categoryChip, category === cat.id && styles.categoryChipSelected]}
                  onPress={() => {
                    touchedRef.current.category = true;
                    setCategory(cat.id);
                  }}
                >
                  <Text style={styles.categoryChipIcon}>{cat.icon}</Text>
                  <Text style={[
                    styles.categoryChipLabel,
                    category === cat.id && styles.categoryChipLabelSelected,
                  ]}>
                    {cat.label}
                  </Text>
                </TouchableOpacity>
              ))}
            </ScrollView>

            <Text style={styles.fieldLabel}>
              Notes <Text style={styles.optionalLabel}>(optional)</Text>
            </Text>
            <TextInput
              style={[styles.textInput, styles.textInputMultiline]}
              placeholder="Job number, vendor, receipt #..."
              placeholderTextColor={colors.textMuted}
              value={notes}
              onChangeText={setNotes}
              multiline
              numberOfLines={3}
              inputAccessoryViewID="expenseModalDone"
            />

            <Text style={styles.fieldLabel}>
              Receipt photo <Text style={styles.optionalLabel}>(optional)</Text>
            </Text>
            {receiptUri ? (
              <View style={styles.receiptPreview}>
                <Image source={{ uri: receiptUri }} style={styles.receiptImage} contentFit="cover" />
                {scanState !== 'idle' && (
                  <View style={styles.scanBanner}>
                    {scanState === 'reading' && (
                      <>
                        <ActivityIndicator size="small" color={colors.accent} />
                        <Text style={styles.scanBannerText}>Reading receipt…</Text>
                      </>
                    )}
                    {scanState === 'filled' && (
                      <Text style={styles.scanBannerTextAccent}>
                        {scanLooksBlurry
                          ? '✨ Filled from receipt — the photo looks blurry, double-check the details'
                          : '✨ Filled from receipt — double-check the details'}
                      </Text>
                    )}
                    {scanState === 'empty' && (
                      <Text style={styles.scanBannerText}>Receipt read — nothing new to fill in</Text>
                    )}
                    {scanState === 'failed' && (
                      <Text style={styles.scanBannerText}>
                        Couldn't read the receipt — enter the details manually
                      </Text>
                    )}
                  </View>
                )}
                <TouchableOpacity style={styles.receiptRemoveRow} onPress={removeReceipt}>
                  <Text style={styles.receiptRemoveText}>✕  Remove photo</Text>
                </TouchableOpacity>
              </View>
            ) : (
              <TouchableOpacity style={styles.receiptBtn} onPress={pickReceipt}>
                <Text style={styles.receiptBtnText}>📷  Add receipt photo</Text>
              </TouchableOpacity>
            )}

            <View style={styles.modalActions}>
              <TouchableOpacity style={styles.cancelButton} onPress={dismiss}>
                <Text style={styles.cancelButtonText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.saveButton} onPress={handleSave}>
                <Text style={styles.saveButtonText}>Save Expense</Text>
              </TouchableOpacity>
            </View>
          </ScrollView>
          {/* Mounted inside the Modal so the accessory attaches to its
              window; serves the decimal-pad amount and multiline notes. */}
          <KeyboardDoneBar nativeID="expenseModalDone" />
        </Animated.View>
      </View>
    </Modal>
  );
});

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    modalBackdrop: {
      flex: 1,
      backgroundColor: 'rgba(0,0,0,0.4)',
    },
    modalSheet: {
      backgroundColor: colors.surface,
      borderTopLeftRadius: radius.lg + 8,
      borderTopRightRadius: radius.lg + 8,
      padding: spacing.lg,
      maxHeight: '90%',
    },
    modalHandleArea: {
      paddingVertical: 14,
      alignItems: 'center',
    },
    modalHandle: {
      width: 40,
      height: 4,
      backgroundColor: colors.borderStrong,
      borderRadius: 2,
    },
    modalTitle: {
      color: colors.textPrimary,
      fontSize: fontSize.xl,
      fontWeight: '700',
      marginBottom: spacing.lg,
    },
    fieldLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontWeight: '500',
      marginBottom: spacing.sm,
      marginTop: spacing.xs,
    },
    optionalLabel: {
      color: colors.textMuted,
      fontWeight: '400',
    },
    textInput: {
      backgroundColor: colors.surfaceSecondary,
      borderRadius: radius.sm + 2,
      padding: 14,
      color: colors.textPrimary,
      fontSize: fontSize.md,
      marginBottom: spacing.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    textInputMultiline: {
      minHeight: 80,
      textAlignVertical: 'top',
    },
    categoryScroll: {
      marginBottom: spacing.md,
    },
    categoryChip: {
      flexDirection: 'row',
      alignItems: 'center',
      backgroundColor: colors.surfaceSecondary,
      borderRadius: radius.full,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      marginRight: spacing.sm,
      borderWidth: 1,
      borderColor: colors.border,
      gap: 6,
    },
    categoryChipSelected: {
      backgroundColor: colors.accentBg,
      borderColor: colors.accent,
    },
    categoryChipIcon: {
      fontSize: fontSize.sm,
    },
    categoryChipLabel: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontWeight: '500',
    },
    categoryChipLabelSelected: {
      color: colors.accent,
      fontWeight: '600',
    },
    modalActions: {
      flexDirection: 'row',
      gap: spacing.md,
      marginTop: spacing.sm,
      paddingBottom: spacing.md,
    },
    cancelButton: {
      flex: 1,
      padding: spacing.md,
      borderRadius: radius.md,
      backgroundColor: colors.surfaceSecondary,
      alignItems: 'center',
      borderWidth: 1,
      borderColor: colors.border,
    },
    cancelButtonText: {
      color: colors.textSecondary,
      fontWeight: '600',
      fontSize: fontSize.md,
    },
    saveButton: {
      flex: 2,
      padding: spacing.md,
      borderRadius: radius.md,
      backgroundColor: colors.accent,
      alignItems: 'center',
    },
    saveButtonText: {
      color: colors.textOnAccent,
      fontWeight: '700',
      fontSize: fontSize.md,
    },
    expenseDateBtn: {
      backgroundColor: colors.surfaceSecondary,
      borderRadius: radius.sm + 2,
      padding: 14,
      borderWidth: 1,
      borderColor: colors.border,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      marginBottom: spacing.md,
    },
    expenseDateBtnText: {
      fontSize: fontSize.md,
      color: colors.textPrimary,
    },
    receiptBtn: {
      backgroundColor: colors.surfaceSecondary,
      borderRadius: radius.sm + 2,
      padding: 14,
      borderWidth: 1,
      borderColor: colors.border,
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    receiptBtnText: {
      color: colors.textSecondary,
      fontSize: fontSize.md,
    },
    receiptPreview: {
      borderRadius: radius.sm + 2,
      overflow: 'hidden',
      borderWidth: 1,
      borderColor: colors.border,
      marginBottom: spacing.md,
    },
    receiptImage: {
      width: '100%',
      height: 180,
    },
    scanBanner: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 8,
      paddingVertical: spacing.sm,
      paddingHorizontal: spacing.md,
      backgroundColor: colors.surfaceSecondary,
      borderBottomWidth: 1,
      borderBottomColor: colors.border,
    },
    scanBannerText: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      textAlign: 'center',
    },
    scanBannerTextAccent: {
      color: colors.accent,
      fontSize: fontSize.sm,
      fontWeight: '500',
      textAlign: 'center',
    },
    receiptRemoveRow: {
      padding: spacing.sm,
      alignItems: 'center',
      backgroundColor: colors.surfaceSecondary,
    },
    receiptRemoveText: {
      color: colors.danger,
      fontSize: fontSize.sm,
      fontWeight: '500',
    },
  });
}
