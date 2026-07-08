import React, { useState, useEffect, useMemo, useLayoutEffect } from 'react';
import { View, Text, TextInput, TouchableOpacity, ScrollView, StyleSheet, Alert } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { spacing, radius, fontSize } from '../utils/theme';
import type { ColorScheme, ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { loadJobs, loadTrips, saveTrips } from '../utils/storage';
import { computeTripMiles, formatMiles, generateTripId, HOME_LABEL } from '../utils/mileageUtils';
import type { Job, Trip } from '../types/models';

interface Endpoint { jobId: string | null; label: string; }

export default function AddTripScreen({ navigation, route }: any) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const editingId: string | undefined = route.params?.tripId;

  const [jobs, setJobs] = useState<Job[]>([]);
  const [date, setDate] = useState<string>(new Date().toISOString().slice(0, 10));
  const [from, setFrom] = useState<Endpoint>({ jobId: null, label: HOME_LABEL });
  const [to, setTo] = useState<Endpoint>({ jobId: null, label: HOME_LABEL });
  const [odoStart, setOdoStart] = useState<string>('');
  const [odoEnd, setOdoEnd] = useState<string>('');
  const [purpose, setPurpose] = useState<string>('');

  useEffect(() => {
    loadJobs().then(setJobs);
    if (editingId) {
      loadTrips().then((trips) => {
        const t = trips.find((x) => x.id === editingId);
        if (!t) return;
        setDate(t.date);
        setFrom({ jobId: t.fromJobId, label: t.fromLabel });
        setTo({ jobId: t.toJobId, label: t.toLabel });
        setOdoStart(String(t.odometerStart || ''));
        setOdoEnd(String(t.odometerEnd || ''));
        setPurpose(t.purpose || '');
      });
    }
  }, [editingId]);

  useLayoutEffect(() => {
    navigation.setOptions({ title: editingId ? 'Edit Trip' : 'Add Trip' });
  }, [navigation, editingId]);

  const startNum = parseFloat(odoStart) || 0;
  const endNum = parseFloat(odoEnd) || 0;
  const miles = computeTripMiles(startNum, endNum);
  const invalid = odoEnd !== '' && endNum < startNum;

  const renderEndpoints = (current: Endpoint, setter: (e: Endpoint) => void) => (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chipRow}>
      <TouchableOpacity
        style={[styles.chip, current.jobId === null && styles.chipActive]}
        onPress={() => setter({ jobId: null, label: HOME_LABEL })}
      >
        <Text style={[styles.chipText, current.jobId === null && styles.chipTextActive]}>{HOME_LABEL}</Text>
      </TouchableOpacity>
      {jobs.map((j) => {
        const label = j.customerName || j.title || 'Job';
        return (
          <TouchableOpacity
            key={j.id}
            style={[styles.chip, current.jobId === j.id && styles.chipActive]}
            onPress={() => setter({ jobId: j.id, label })}
          >
            <Text style={[styles.chipText, current.jobId === j.id && styles.chipTextActive]} numberOfLines={1}>
              {label}
            </Text>
          </TouchableOpacity>
        );
      })}
    </ScrollView>
  );

  const handleSave = async () => {
    if (!date || isNaN(new Date(date).getTime())) {
      Alert.alert('Invalid date', 'Enter the trip date as YYYY-MM-DD.');
      return;
    }
    if (!odoStart || !odoEnd) {
      Alert.alert('Missing readings', 'Enter both start and end odometer readings.');
      return;
    }
    if (invalid) {
      Alert.alert('Check readings', 'End reading must be greater than or equal to the start reading.');
      return;
    }
    const trips = await loadTrips();
    const existing = editingId ? trips.find((t) => t.id === editingId) : undefined;
    const record: Trip = {
      id: editingId || generateTripId(),
      date,
      odometerStart: startNum,
      odometerEnd: endNum,
      miles,
      fromJobId: from.jobId,
      fromLabel: from.label,
      toJobId: to.jobId,
      toLabel: to.label,
      purpose: purpose.trim(),
      createdAt: existing?.createdAt || new Date().toISOString(),
    };
    const next = editingId ? trips.map((t) => (t.id === editingId ? record : t)) : [record, ...trips];
    await saveTrips(next);
    navigation.goBack();
  };

  const handleDelete = () => {
    Alert.alert('Delete trip', 'Remove this trip from your mileage log?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: async () => {
          const trips = await loadTrips();
          await saveTrips(trips.filter((t) => t.id !== editingId));
          navigation.goBack();
        },
      },
    ]);
  };

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.label}>Date</Text>
        <TextInput style={styles.input} value={date} onChangeText={setDate} placeholder="YYYY-MM-DD" placeholderTextColor={colors.textMuted} />

        <Text style={styles.label}>From</Text>
        {renderEndpoints(from, setFrom)}

        <Text style={styles.label}>To</Text>
        {renderEndpoints(to, setTo)}

        <Text style={styles.label}>Odometer start</Text>
        <TextInput style={styles.input} value={odoStart} onChangeText={setOdoStart} keyboardType="decimal-pad" placeholder="e.g. 45210" placeholderTextColor={colors.textMuted} />

        <Text style={styles.label}>Odometer end</Text>
        <TextInput style={styles.input} value={odoEnd} onChangeText={setOdoEnd} keyboardType="decimal-pad" placeholder="e.g. 45240" placeholderTextColor={colors.textMuted} />

        <Text style={[styles.milesPreview, invalid && styles.milesInvalid]}>
          {invalid ? 'End reading is less than start' : `Trip distance: ${formatMiles(miles)}`}
        </Text>

        <Text style={styles.label}>Purpose (optional)</Text>
        <TextInput style={[styles.input, styles.multiline]} value={purpose} onChangeText={setPurpose} placeholder="e.g. Drive to job site" placeholderTextColor={colors.textMuted} multiline />

        <TouchableOpacity style={styles.saveBtn} onPress={handleSave} activeOpacity={0.85}>
          <Text style={styles.saveBtnText}>{editingId ? 'Save Changes' : 'Add Trip'}</Text>
        </TouchableOpacity>

        {editingId && (
          <TouchableOpacity style={styles.deleteBtn} onPress={handleDelete} activeOpacity={0.85}>
            <Text style={styles.deleteBtnText}>Delete Trip</Text>
          </TouchableOpacity>
        )}
        <View style={{ height: 60 }} />
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    content: { padding: spacing.lg },
    label: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '600', marginBottom: spacing.xs, marginTop: spacing.md },
    input: {
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      color: colors.textPrimary,
      fontSize: fontSize.md,
    },
    multiline: { minHeight: 70, textAlignVertical: 'top' },
    chipRow: { gap: spacing.sm, paddingVertical: spacing.xs },
    chip: {
      paddingHorizontal: 14,
      paddingVertical: 8,
      borderRadius: radius.full,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      maxWidth: 180,
    },
    chipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    chipText: { color: colors.textSecondary, fontSize: fontSize.sm, fontWeight: '500' },
    chipTextActive: { color: colors.accent, fontWeight: '600' },
    milesPreview: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '600', marginTop: spacing.md },
    milesInvalid: { color: colors.danger },
    saveBtn: { backgroundColor: colors.accent, borderRadius: radius.md, paddingVertical: 14, alignItems: 'center', marginTop: spacing.xl },
    saveBtnText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
    deleteBtn: { borderRadius: radius.md, paddingVertical: 14, alignItems: 'center', marginTop: spacing.md },
    deleteBtnText: { color: colors.danger, fontSize: fontSize.md, fontWeight: '600' },
  });
}
