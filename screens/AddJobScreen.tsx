// screens/AddJobScreen.tsx
// Used for both creating a new job and editing an existing one.
// Collects: customer, title, description, address, schedule, notes.
// Pricing is handled separately in PricingCalculatorScreen.

import React, { useState, useEffect, useLayoutEffect, useRef, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
  Switch,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadJobs, saveJobs, loadCustomers, loadSettings, getOrCreateCustomer, loadRecurringJobs, saveRecurringJobs } from "../utils/storage";
import { advanceStatusForSchedule } from "../utils/jobStatus";
import { calculateNextDate } from "../utils/recurringJobs";
import { track } from '../utils/analytics';
import { Button } from "../components/UI";
import Field from "../components/Field";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';
import type { Customer, RecurrenceCadence, RecurrenceEndCondition, RecurringJob } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

export default function AddJobScreen({ route, navigation }: JobStackScreenProps<'AddJob'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId, focusSchedule } = route.params || {};
  const isEditing = !!jobId;

  // Job fields
  const [customerId, setCustomerId] = useState<string>("");
  const [customerName, setCustomerName] = useState<string>("");
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [showCustomerPicker, setShowCustomerPicker] = useState<boolean>(false);
  const [customerSearch, setCustomerSearch] = useState<string>("");
  const [title, setTitle] = useState<string>("");
  const [description, setDescription] = useState<string>("");
  const [address, setAddress] = useState<string>("");
  const [scheduledDate, setScheduledDate] = useState<string>("");
  const [scheduledStartTime, setScheduledStartTime] = useState<string>("");
  const [scheduledEndTime, setScheduledEndTime] = useState<string>("");
  const [notes, setNotes] = useState<string>("");
  const [saving, setSaving] = useState<boolean>(false);
  const [showDatePicker, setShowDatePicker] = useState<boolean>(false);
  const [showStartTimePicker, setShowStartTimePicker] = useState<boolean>(false);
  const [showEndTimePicker, setShowEndTimePicker] = useState<boolean>(false);
  const [isRecurring, setIsRecurring] = useState<boolean>(false);
  const [cadence, setCadence] = useState<RecurrenceCadence>('monthly');
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>('never');
  const [endCount, setEndCount] = useState<string>('');
  const [endDate, setEndDate] = useState<string>('');
  const [showEndDatePicker, setShowEndDatePicker] = useState<boolean>(false);
  const [existingRecurringJob, setExistingRecurringJob] = useState<RecurringJob | null>(null);

  const scrollRef = useRef<any>(null);

  useLayoutEffect(() => {
    navigation.setOptions({
      title: isEditing ? "Edit Job" : "New Job",
      headerLeft: () => (
        <TouchableOpacity
          onPress={() => navigation.goBack()}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          accessibilityRole="button"
          accessibilityLabel="Cancel"
        >
          <Text style={{ color: colors.accent, fontSize: fontSize.md }}>Cancel</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, isEditing, colors.accent]);

  useEffect(() => {
    async function load() {
      const [jobs, custs] = await Promise.all([loadJobs(), loadCustomers()]);
      setCustomers(custs);
      if (isEditing) {
        const j = jobs.find((x: any) => x.id === jobId);
        if (j) {
          setCustomerId(j.customerId || "");
          setCustomerName(j.customerName || "");
          setTitle(j.title || "");
          setDescription(j.description || "");
          setAddress(j.address || "");
          setScheduledDate(j.scheduledDate || "");
          setScheduledStartTime(j.scheduledStartTime || "");
          setScheduledEndTime(j.scheduledEndTime || "");
          setNotes(j.notes || "");
          if (j.recurringJobId) {
            const recurringJobs = await loadRecurringJobs();
            const rule = recurringJobs.find(r => r.id === j.recurringJobId) ?? null;
            setExistingRecurringJob(rule);
            if (rule) {
              setIsRecurring(true);
              setCadence(rule.cadence);
              setEndCondition(rule.endCondition);
              setEndCount(rule.endCount != null ? String(rule.endCount) : '');
              setEndDate(rule.endDate ?? '');
            }
          }
        }
      }
      // If coming from "Schedule this job" shortcut, scroll to schedule section
      if (focusSchedule) {
        setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 300);
      }
    }
    load();
  }, [jobId, isEditing, focusSchedule]);

  function dateObjFromStr(str: string): Date {
    if (!str) return new Date();
    const [y, m, d] = str.split("-").map(Number);
    return new Date(y, m - 1, d);
  }

  function timeObjFromStr(str: string): Date {
    const base = new Date();
    if (str) {
      const [h, m] = str.split(":").map(Number);
      base.setHours(h, m, 0, 0);
    }
    return base;
  }

  function toDateStr(date: Date): string {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  }

  function toTimeStr(date: Date): string {
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }

  function displayDate(str: string): string | null {
    if (!str) return null;
    return dateObjFromStr(str).toLocaleDateString("en-US", {
      weekday: "long", month: "long", day: "numeric",
    });
  }

  function displayTime(str: string): string | null {
    if (!str) return null;
    return timeObjFromStr(str).toLocaleTimeString("en-US", {
      hour: "numeric", minute: "2-digit", hour12: true,
    });
  }

  function selectCustomer(c: Customer) {
    setCustomerId(c.id);
    setCustomerName(c.name);
    if (!address && c.address) setAddress(c.address);
    setShowCustomerPicker(false);
    setCustomerSearch("");
  }

  function toggleCustomerPicker() {
    setShowCustomerPicker((prev) => {
      if (prev) setCustomerSearch("");
      return !prev;
    });
  }

  async function handleSave() {
    if (!customerName.trim()) {
      Alert.alert("Customer required", "Please select or enter a customer name.");
      return;
    }
    if (!title.trim()) {
      Alert.alert("Job title required", "Please enter a brief title for this job.");
      return;
    }

    if (isRecurring) {
      if (endCondition === 'count' && (!endCount.trim() || parseInt(endCount) < 1)) {
        Alert.alert('End count required', 'Please enter a number of jobs greater than 0.');
        return;
      }
      if (endCondition === 'date' && !endDate) {
        Alert.alert('End date required', 'Please select an end date for the series.');
        return;
      }
    }

    setSaving(true);
    const [jobs, settings] = await Promise.all([loadJobs(), loadSettings()]);

    // A free-typed customer (no pick from the list) has no id yet — promote it to
    // a real record so the job links like any other (roadmap #5, folds in #3).
    let resolvedCustomerId = customerId;
    if (!resolvedCustomerId) {
      const record = await getOrCreateCustomer({ name: customerName.trim() });
      resolvedCustomerId = record?.id ?? "";
    }

    const jobData = {
      customerId: resolvedCustomerId,
      customerName: customerName.trim(),
      title: title.trim(),
      description: description.trim(),
      address: address.trim(),
      scheduledDate: scheduledDate.trim(),
      scheduledStartTime: scheduledStartTime.trim(),
      scheduledEndTime: scheduledEndTime.trim(),
      notes: notes.trim(),
    };

    async function performSave(applyToAll: boolean) {
      let updatedJobs: any[];
      if (isEditing) {
        updatedJobs = jobs.map((j: any) =>
          j.id === jobId
            ? { ...j, ...jobData, status: advanceStatusForSchedule(j.status, !!jobData.scheduledDate) }
            : j
        );
        if (applyToAll && existingRecurringJob) {
          const allRules = await loadRecurringJobs();
          const currentJob = jobs.find((j: any) => j.id === jobId);
          const updatedRules = allRules.map(r =>
            r.id === existingRecurringJob.id
              ? {
                  ...r,
                  customerId: resolvedCustomerId,
                  customerName: jobData.customerName,
                  title: jobData.title,
                  description: jobData.description,
                  address: jobData.address,
                  notes: jobData.notes,
                  // Pricing fields — carry from current job state
                  estimateTotal: currentJob?.estimateTotal ?? r.estimateTotal,
                  laborHours: currentJob?.laborHours ?? r.laborHours,
                  laborRate: currentJob?.laborRate ?? r.laborRate,
                  materials: currentJob?.materials ?? r.materials,
                  materialMarkup: currentJob?.materialMarkup ?? r.materialMarkup,
                  overhead: currentJob?.overhead ?? r.overhead,
                  margin: currentJob?.margin ?? r.margin,
                  // Recurrence config
                  cadence,
                  endCondition,
                  endCount: endCondition === 'count' ? (parseInt(endCount) || 1) : undefined,
                  endDate: endCondition === 'date' ? endDate : undefined,
                }
              : r
          );
          await saveRecurringJobs(updatedRules);
        }
      } else {
        const today = new Date().toISOString().split('T')[0];
        const startDate = jobData.scheduledDate || today;
        const newJobId = `j${Date.now()}`;

        if (isRecurring) {
          const newRuleId = `rj_${Date.now()}`;
          const recurringJob: RecurringJob = {
            id: newRuleId,
            customerId: resolvedCustomerId,
            customerName: jobData.customerName,
            title: jobData.title,
            description: jobData.description,
            address: jobData.address,
            notes: jobData.notes,
            estimateTotal: 0,
            laborHours: 0,
            laborRate: settings.laborRate ?? 85,
            materials: [],
            materialMarkup: settings.materialMarkup ?? 20,
            overhead: settings.overheadPercent ?? 15,
            margin: settings.marginPercent ?? 20,
            cadence,
            endCondition,
            endCount: endCondition === 'count' ? (parseInt(endCount) || 1) : undefined,
            endDate: endCondition === 'date' ? endDate : undefined,
            occurrenceCount: 1,
            lastGeneratedDate: startDate,
            nextDueDate: calculateNextDate(startDate, cadence),
            isActive: true,
            createdAt: today,
          };
          const allRules = await loadRecurringJobs();
          await saveRecurringJobs([...allRules, recurringJob]);

          const newJob = {
            id: newJobId,
            status: 'lead',
            estimateTotal: 0,
            laborHours: 0,
            laborRate: settings.laborRate ?? 85,
            materials: [],
            materialMarkup: settings.materialMarkup ?? 20,
            overhead: settings.overheadPercent ?? 15,
            margin: settings.marginPercent ?? 20,
            invoiceId: null,
            createdAt: today,
            recurringJobId: newRuleId,
            occurrenceNumber: 1,
            ...jobData,
          };
          updatedJobs = [...jobs, newJob];
        } else {
          const newJob = {
            id: newJobId,
            status: 'lead',
            estimateTotal: 0,
            laborHours: 0,
            laborRate: settings.laborRate ?? 85,
            materials: [],
            materialMarkup: settings.materialMarkup ?? 20,
            overhead: settings.overheadPercent ?? 15,
            margin: settings.marginPercent ?? 20,
            invoiceId: null,
            createdAt: today,
            ...jobData,
          };
          updatedJobs = [...jobs, newJob];
        }
      }

      await saveJobs(updatedJobs);
      setSaving(false);
      if (!isEditing) {
        track('job_created');
      }
      navigation.goBack();
    }

    if (isEditing && existingRecurringJob) {
      setSaving(false);
      Alert.alert(
        'Edit recurring job',
        'Apply changes to:',
        [
          { text: 'This job only', onPress: () => { setSaving(true); performSave(false); } },
          { text: 'This and all future jobs', onPress: () => { setSaving(true); performSave(true); } },
          { text: 'Cancel', style: 'cancel' },
        ]
      );
    } else {
      await performSave(false);
    }
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView
          ref={scrollRef}
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
        >
          {/* Customer */}
          <SectionLabel>Customer</SectionLabel>
          <TouchableOpacity
            style={styles.customerSelector}
            onPress={toggleCustomerPicker}
            accessibilityRole="button"
            accessibilityLabel={customerName ? `Customer: ${customerName}` : "Select a customer"}
            accessibilityState={{ expanded: showCustomerPicker }}
          >
            <Text style={customerName ? styles.customerSelected : styles.customerPlaceholder}>
              {customerName || "Select a customer..."}
            </Text>
            <Text style={styles.chevron}>{showCustomerPicker ? "▲" : "▼"}</Text>
          </TouchableOpacity>

          {showCustomerPicker && (
            <View style={styles.customerList}>
              <TextInput
                style={styles.customerSearch}
                value={customerSearch}
                onChangeText={setCustomerSearch}
                placeholder="Search customers..."
                placeholderTextColor={colors.textMuted}
                autoCapitalize="none"
                autoCorrect={false}
                clearButtonMode="while-editing"
                autoFocus
                accessibilityLabel="Search customers"
              />
              <ScrollView
                style={styles.customerScroll}
                keyboardShouldPersistTaps="handled"
                nestedScrollEnabled
              >
                {customers
                  .filter((c) => {
                    const q = customerSearch.toLowerCase();
                    return (
                      c.name.toLowerCase().includes(q) ||
                      (c.phone || "").includes(q)
                    );
                  })
                  .map((c) => (
                    <TouchableOpacity
                      key={c.id}
                      style={styles.customerOption}
                      onPress={() => selectCustomer(c)}
                      accessibilityRole="button"
                      accessibilityLabel={c.phone ? `${c.name}, ${c.phone}` : c.name}
                    >
                      <Text style={styles.customerOptionName}>{c.name}</Text>
                      {c.phone ? (
                        <Text style={styles.customerOptionSub}>{c.phone}</Text>
                      ) : null}
                    </TouchableOpacity>
                  ))}
              </ScrollView>
              <TouchableOpacity
                style={[styles.customerOption, styles.customerOptionAdd]}
                onPress={() => {
                  setShowCustomerPicker(false);
                  setCustomerSearch("");
                  navigation.navigate('AddCustomer', {});
                }}
                accessibilityRole="button"
                accessibilityLabel="Add new customer"
              >
                <Text style={{ fontSize: fontSize.sm, color: colors.accent }}>
                  + Add new customer →
                </Text>
              </TouchableOpacity>
            </View>
          )}

          {/* Or type a name manually */}
          {!customerId && (
            <TextInput
              style={[styles.input, { marginTop: 6 }]}
              placeholder="Or type customer name manually"
              placeholderTextColor={colors.textMuted}
              value={customerName}
              onChangeText={setCustomerName}
              accessibilityLabel="Customer name"
            />
          )}

          {/* Job info */}
          <SectionLabel>Job info</SectionLabel>
          <Field label="Job title *" value={title} onChangeText={setTitle} placeholder="Replace kitchen faucet" />
          <Field
            label="Description"
            value={description}
            onChangeText={setDescription}
            placeholder="What needs to be done? Be specific — this becomes your estimate."
            multiline
          />
          <Field
            label="Job address"
            value={address}
            onChangeText={setAddress}
            placeholder="123 Main St, City, ST 00000"
            keyboardType="default"
          />

          {/* Schedule */}
          <SectionLabel>Schedule (optional)</SectionLabel>

          {/* Date */}
          <View style={styles.fieldGroup}>
            <View style={styles.pickerLabelRow}>
              <Text style={styles.fieldLabel}>Date</Text>
              {scheduledDate ? (
                <TouchableOpacity
                  onPress={() => setScheduledDate("")}
                  accessibilityRole="button"
                  accessibilityLabel="Clear date"
                >
                  <Text style={styles.pickerClear}>Clear</Text>
                </TouchableOpacity>
              ) : null}
            </View>
            <TouchableOpacity
              style={styles.pickerBtn}
              onPress={() => setShowDatePicker(true)}
              accessibilityRole="button"
              accessibilityLabel={scheduledDate ? `Date: ${displayDate(scheduledDate)}` : "Select date"}
            >
              <Text style={scheduledDate ? styles.pickerBtnText : styles.pickerBtnPlaceholder}>
                {scheduledDate ? displayDate(scheduledDate) : "Select date…"}
              </Text>
              <Text style={styles.pickerIcon}>📅</Text>
            </TouchableOpacity>
          </View>

          {/* Times */}
          <View style={styles.timeRow}>
            <View style={{ flex: 1 }}>
              <View style={styles.fieldGroup}>
                <View style={styles.pickerLabelRow}>
                  <Text style={styles.fieldLabel}>Start time</Text>
                  {scheduledStartTime ? (
                    <TouchableOpacity
                      onPress={() => setScheduledStartTime("")}
                      accessibilityRole="button"
                      accessibilityLabel="Clear start time"
                    >
                      <Text style={styles.pickerClear}>Clear</Text>
                    </TouchableOpacity>
                  ) : null}
                </View>
                <TouchableOpacity
                  style={styles.pickerBtn}
                  onPress={() => setShowStartTimePicker(true)}
                  accessibilityRole="button"
                  accessibilityLabel={scheduledStartTime ? `Start time: ${displayTime(scheduledStartTime)}` : "Select start time"}
                >
                  <Text style={scheduledStartTime ? styles.pickerBtnText : styles.pickerBtnPlaceholder}>
                    {scheduledStartTime ? displayTime(scheduledStartTime) : "Start…"}
                  </Text>
                  <Text style={styles.pickerIcon}>🕐</Text>
                </TouchableOpacity>
              </View>
            </View>
            <View style={{ width: spacing.md }} />
            <View style={{ flex: 1 }}>
              <View style={styles.fieldGroup}>
                <View style={styles.pickerLabelRow}>
                  <Text style={styles.fieldLabel}>End time</Text>
                  {scheduledEndTime ? (
                    <TouchableOpacity
                      onPress={() => setScheduledEndTime("")}
                      accessibilityRole="button"
                      accessibilityLabel="Clear end time"
                    >
                      <Text style={styles.pickerClear}>Clear</Text>
                    </TouchableOpacity>
                  ) : null}
                </View>
                <TouchableOpacity
                  style={styles.pickerBtn}
                  onPress={() => setShowEndTimePicker(true)}
                  accessibilityRole="button"
                  accessibilityLabel={scheduledEndTime ? `End time: ${displayTime(scheduledEndTime)}` : "Select end time"}
                >
                  <Text style={scheduledEndTime ? styles.pickerBtnText : styles.pickerBtnPlaceholder}>
                    {scheduledEndTime ? displayTime(scheduledEndTime) : "End…"}
                  </Text>
                  <Text style={styles.pickerIcon}>🕐</Text>
                </TouchableOpacity>
              </View>
            </View>
          </View>

          {/* Notes */}
          <SectionLabel>Notes</SectionLabel>
          <Field
            label="Internal notes"
            value={notes}
            onChangeText={setNotes}
            placeholder="Gate code, parking, customer preferences..."
            multiline
          />

          <SectionLabel>Repeat</SectionLabel>
          {existingRecurringJob !== null ? (
            <View style={styles.recurringNotice}>
              <Text style={styles.recurringNoticeText}>Part of a recurring series</Text>
              <Text style={styles.recurringNoticeSubText}>
                {cadence.charAt(0).toUpperCase() + cadence.slice(1)} · {
                  endCondition === 'never' ? 'No end' :
                  endCondition === 'count' ? `Ends after ${endCount} jobs` :
                  `Ends ${displayDate(endDate) ?? endDate}`
                }
              </Text>
            </View>
          ) : (
            <>
              <View style={styles.toggleRow}>
                <Text style={styles.toggleLabel}>Repeat this job</Text>
                <Switch
                  value={isRecurring}
                  onValueChange={setIsRecurring}
                  trackColor={{ false: colors.border, true: colors.accent }}
                  thumbColor={colors.surface}
                  accessibilityLabel="Repeat this job"
                />
              </View>

              {isRecurring && (
                <>
                  <Text style={styles.fieldLabel}>Repeats</Text>
                  <View style={styles.chipRow}>
                    {(['daily', 'weekly', 'monthly', 'quarterly', 'annually'] as RecurrenceCadence[]).map(c => (
                      <TouchableOpacity
                        key={c}
                        style={[styles.chip, cadence === c && styles.chipSelected]}
                        onPress={() => setCadence(c)}
                        accessibilityRole="radio"
                        accessibilityLabel={`Repeats ${c}`}
                        accessibilityState={{ selected: cadence === c }}
                      >
                        <Text style={[styles.chipText, cadence === c && styles.chipTextSelected]}>
                          {c.charAt(0).toUpperCase() + c.slice(1)}
                        </Text>
                      </TouchableOpacity>
                    ))}
                  </View>

                  <Text style={[styles.fieldLabel, { marginTop: spacing.sm }]}>Ends</Text>
                  <View style={styles.chipRow}>
                    {(['never', 'count', 'date'] as RecurrenceEndCondition[]).map(ec => (
                      <TouchableOpacity
                        key={ec}
                        style={[styles.chip, endCondition === ec && styles.chipSelected]}
                        onPress={() => setEndCondition(ec)}
                        accessibilityRole="radio"
                        accessibilityLabel={ec === 'never' ? 'Never ends' : ec === 'count' ? 'Ends after a number of jobs' : 'Ends by date'}
                        accessibilityState={{ selected: endCondition === ec }}
                      >
                        <Text style={[styles.chipText, endCondition === ec && styles.chipTextSelected]}>
                          {ec === 'never' ? 'Never' : ec === 'count' ? 'After N jobs' : 'By date'}
                        </Text>
                      </TouchableOpacity>
                    ))}
                  </View>

                  {endCondition === 'count' && (
                    <Field
                      label="Number of jobs"
                      value={endCount}
                      onChangeText={setEndCount}
                      placeholder="e.g. 12"
                      keyboardType="number-pad"
                    />
                  )}

                  {endCondition === 'date' && (
                    <View style={styles.fieldGroup}>
                      <View style={styles.pickerLabelRow}>
                        <Text style={styles.fieldLabel}>End date</Text>
                        {endDate ? (
                          <TouchableOpacity
                            onPress={() => setEndDate('')}
                            accessibilityRole="button"
                            accessibilityLabel="Clear end date"
                          >
                            <Text style={styles.pickerClear}>Clear</Text>
                          </TouchableOpacity>
                        ) : null}
                      </View>
                      <TouchableOpacity
                        style={styles.pickerBtn}
                        onPress={() => setShowEndDatePicker(true)}
                        accessibilityRole="button"
                        accessibilityLabel={endDate ? `End date: ${displayDate(endDate)}` : "Select end date"}
                      >
                        <Text style={endDate ? styles.pickerBtnText : styles.pickerBtnPlaceholder}>
                          {endDate ? displayDate(endDate) : 'Select end date…'}
                        </Text>
                        <Text style={styles.pickerIcon}>📅</Text>
                      </TouchableOpacity>
                    </View>
                  )}
                </>
              )}
            </>
          )}

          {/* Actions */}
          <View style={styles.actions}>
            <Button label="Cancel" variant="ghost" onPress={() => navigation.goBack()} style={{ flex: 1 }} />
            <View style={{ width: spacing.sm }} />
            <Button
              label={isEditing ? "Save changes" : "Add job"}
              onPress={handleSave}
              loading={saving}
              style={{ flex: 2 }}
            />
          </View>
        </ScrollView>
      </KeyboardAvoidingView>

      {/* ── Schedule pickers ─────────────────────────────────────────────── */}
      <DateTimePickerSheet
        visible={showDatePicker}
        mode="date"
        title="Select Date"
        value={dateObjFromStr(scheduledDate)}
        onChange={(date: Date) => setScheduledDate(toDateStr(date))}
        onClose={() => setShowDatePicker(false)}
      />
      <DateTimePickerSheet
        visible={showStartTimePicker}
        mode="time"
        title="Start Time"
        value={timeObjFromStr(scheduledStartTime)}
        onChange={(date: Date) => setScheduledStartTime(toTimeStr(date))}
        onClose={() => setShowStartTimePicker(false)}
      />
      <DateTimePickerSheet
        visible={showEndTimePicker}
        mode="time"
        title="End Time"
        value={timeObjFromStr(scheduledEndTime)}
        onChange={(date: Date) => setScheduledEndTime(toTimeStr(date))}
        onClose={() => setShowEndTimePicker(false)}
      />
      <DateTimePickerSheet
        visible={showEndDatePicker}
        mode="date"
        title="End Date"
        value={dateObjFromStr(endDate || new Date().toISOString().split('T')[0])}
        onChange={(date: Date) => setEndDate(toDateStr(date))}
        onClose={() => setShowEndDatePicker(false)}
      />
    </SafeAreaView>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return <Text style={styles.sectionLabel}>{children}</Text>;
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  scroll: { padding: spacing.md, paddingBottom: 160 },
  sectionLabel: {
    fontSize: fontSize.xs, fontWeight: "600", color: colors.textSecondary,
    textTransform: "uppercase", letterSpacing: 0.6,
    marginTop: spacing.md, marginBottom: spacing.sm,
  },
  customerSelector: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    height: 44,
    paddingHorizontal: spacing.md,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    ...shadow.card,
  },
  customerSelected: { fontSize: fontSize.md, color: colors.textPrimary },
  customerPlaceholder: { fontSize: fontSize.md, color: colors.textMuted },
  chevron: { fontSize: fontSize.sm, color: colors.textMuted },
  customerList: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    marginTop: 4,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    overflow: "hidden",
    ...shadow.card,
  },
  customerSearch: {
    margin: spacing.sm,
    marginBottom: 0,
    backgroundColor: colors.background,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: 8,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  customerScroll: { maxHeight: 210 },
  customerOption: { padding: spacing.md },
  customerOptionAdd: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
  customerOptionName: { fontSize: fontSize.md, color: colors.textPrimary, fontWeight: "500" },
  customerOptionSub: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
  fieldGroup: { marginBottom: spacing.sm },
  fieldLabel: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 5, fontWeight: "500" },
  input: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    height: 44,
    paddingHorizontal: spacing.md,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  timeRow: { flexDirection: "row" },
  actions: { flexDirection: "row", marginTop: spacing.lg },

  // Picker trigger buttons
  pickerLabelRow: {
    flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginBottom: 5,
  },
  pickerClear: { fontSize: fontSize.xs, color: colors.accent },
  pickerBtn: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    height: 44,
    paddingHorizontal: spacing.md,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  pickerBtnText: { fontSize: fontSize.md, color: colors.textPrimary, flex: 1 },
  pickerBtnPlaceholder: { fontSize: fontSize.md, color: colors.textMuted, flex: 1 },
  pickerIcon: { fontSize: 16, marginLeft: spacing.sm },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    marginBottom: spacing.sm,
  },
  toggleLabel: {
    fontSize: fontSize.md,
    color: colors.textPrimary,
    fontWeight: '500',
  },
  chipRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
    marginBottom: spacing.sm,
  },
  chip: {
    paddingHorizontal: spacing.sm,
    paddingVertical: 6,
    borderRadius: radius.sm,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  chipSelected: {
    borderColor: colors.accent,
    backgroundColor: colors.accent,
  },
  chipText: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
  },
  chipTextSelected: {
    color: colors.surface,
    fontWeight: '600',
  },
  recurringNotice: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    marginBottom: spacing.sm,
  },
  recurringNoticeText: {
    fontSize: fontSize.md,
    color: colors.textPrimary,
    fontWeight: '500',
  },
  recurringNoticeSubText: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    marginTop: 2,
  },
  });
}
