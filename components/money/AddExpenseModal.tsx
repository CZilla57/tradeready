import React, { useState, useEffect, useRef, useMemo } from 'react';
import {
  View,
  Text,
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
import { persistPhoto } from '../../utils/photoStorage';
import { DateTimePickerSheet } from '../DateTimePickerSheet';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../../utils/theme';
import { useTheme } from '../../hooks/useTheme';
import { EXPENSE_CATEGORIES } from '../../utils/moneyUtils';
import type { ExpenseDraft } from '../../types/models';

interface AddExpenseModalProps {
  visible: boolean;
  onClose: () => void;
  onSave: (fields: ExpenseDraft) => void;
}

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
            setReceiptUri(await persistPhoto(result.assets[0].uri, 'receipts'));
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
            setReceiptUri(await persistPhoto(result.assets[0].uri, 'receipts'));
          }
        },
      },
      { text: 'Cancel', style: 'cancel' },
    ]);
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
              onChangeText={setDescription}
            />

            <Text style={styles.fieldLabel}>Amount</Text>
            <TextInput
              style={styles.textInput}
              placeholder="0.00"
              placeholderTextColor={colors.textMuted}
              value={amount}
              onChangeText={setAmount}
              keyboardType="decimal-pad"
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
              onChange={(d) => setDate(d.toISOString().split('T')[0])}
              onClose={() => setShowDatePicker(false)}
            />

            <Text style={styles.fieldLabel}>Category</Text>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.categoryScroll}>
              {EXPENSE_CATEGORIES.map(cat => (
                <TouchableOpacity
                  key={cat.id}
                  style={[styles.categoryChip, category === cat.id && styles.categoryChipSelected]}
                  onPress={() => setCategory(cat.id)}
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
            />

            <Text style={styles.fieldLabel}>
              Receipt photo <Text style={styles.optionalLabel}>(optional)</Text>
            </Text>
            {receiptUri ? (
              <View style={styles.receiptPreview}>
                <Image source={{ uri: receiptUri }} style={styles.receiptImage} contentFit="cover" />
                <TouchableOpacity style={styles.receiptRemoveRow} onPress={() => setReceiptUri(null)}>
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
