// screens/AddJobScreen.js
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
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadJobs, saveJobs, loadCustomers, loadSettings, getOrCreateCustomer } from "../utils/storage";
import { advanceStatusForSchedule } from "../utils/jobStatus";
import { Button } from "../components/UI";
import Field from "../components/Field";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { spacing, radius, fontSize } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';

export default function AddJobScreen({ route, navigation }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId, focusSchedule } = route.params || {};
  const isEditing = !!jobId;

  // Job fields
  const [customerId, setCustomerId] = useState("");
  const [customerName, setCustomerName] = useState("");
  const [customers, setCustomers] = useState([]);
  const [showCustomerPicker, setShowCustomerPicker] = useState(false);
  const [customerSearch, setCustomerSearch] = useState("");
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [address, setAddress] = useState("");
  const [scheduledDate, setScheduledDate] = useState("");
  const [scheduledStartTime, setScheduledStartTime] = useState("");
  const [scheduledEndTime, setScheduledEndTime] = useState("");
  const [notes, setNotes] = useState("");
  const [saving, setSaving] = useState(false);
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [showStartTimePicker, setShowStartTimePicker] = useState(false);
  const [showEndTimePicker, setShowEndTimePicker] = useState(false);

  const scrollRef = useRef(null);

  useLayoutEffect(() => {
    navigation.setOptions({
      title: isEditing ? "Edit Job" : "New Job",
      headerLeft: () => (
        <TouchableOpacity onPress={() => navigation.goBack()} hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}>
          <Text style={{ color: colors.accent, fontSize: fontSize.md }}>Cancel</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, isEditing]);

  useEffect(() => {
    async function load() {
      const [jobs, custs] = await Promise.all([loadJobs(), loadCustomers()]);
      setCustomers(custs);
      if (isEditing) {
        const j = jobs.find((x) => x.id === jobId);
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
        }
      }
      // If coming from "Schedule this job" shortcut, scroll to schedule section
      if (focusSchedule) {
        setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 300);
      }
    }
    load();
  }, [jobId, isEditing, focusSchedule]);

  function dateObjFromStr(str) {
    if (!str) return new Date();
    const [y, m, d] = str.split("-").map(Number);
    return new Date(y, m - 1, d);
  }

  function timeObjFromStr(str) {
    const base = new Date();
    if (str) {
      const [h, m] = str.split(":").map(Number);
      base.setHours(h, m, 0, 0);
    }
    return base;
  }

  function toDateStr(date) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  }

  function toTimeStr(date) {
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }

  function displayDate(str) {
    if (!str) return null;
    return dateObjFromStr(str).toLocaleDateString("en-US", {
      weekday: "long", month: "long", day: "numeric",
    });
  }

  function displayTime(str) {
    if (!str) return null;
    return timeObjFromStr(str).toLocaleTimeString("en-US", {
      hour: "numeric", minute: "2-digit", hour12: true,
    });
  }

  function selectCustomer(c) {
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

    let updated;
    if (isEditing) {
      // Adding a schedule to an approved job advances it to "scheduled"
      // (guarded so later statuses never regress — see utils/jobStatus).
      updated = jobs.map((j) =>
        j.id === jobId
          ? { ...j, ...jobData, status: advanceStatusForSchedule(j.status, !!jobData.scheduledDate) }
          : j
      );
    } else {
      const newJob = {
        id: `j${Date.now()}`,
        status: "lead",
        estimateTotal: 0,
        laborHours: 0,
        laborRate: settings.laborRate ?? 85,
        materials: [],
        materialMarkup: settings.materialMarkup ?? 20,
        overhead: settings.overheadPercent ?? 15,
        margin: settings.marginPercent ?? 20,
        invoiceId: null,
        createdAt: new Date().toISOString().split("T")[0],
        ...jobData,
      };
      updated = [...jobs, newJob];
    }

    await saveJobs(updated);
    setSaving(false);
    navigation.goBack();
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
                  navigation.navigate('AddCustomer');
                }}
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
                <TouchableOpacity onPress={() => setScheduledDate("")}>
                  <Text style={styles.pickerClear}>Clear</Text>
                </TouchableOpacity>
              ) : null}
            </View>
            <TouchableOpacity style={styles.pickerBtn} onPress={() => setShowDatePicker(true)}>
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
                    <TouchableOpacity onPress={() => setScheduledStartTime("")}>
                      <Text style={styles.pickerClear}>Clear</Text>
                    </TouchableOpacity>
                  ) : null}
                </View>
                <TouchableOpacity style={styles.pickerBtn} onPress={() => setShowStartTimePicker(true)}>
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
                    <TouchableOpacity onPress={() => setScheduledEndTime("")}>
                      <Text style={styles.pickerClear}>Clear</Text>
                    </TouchableOpacity>
                  ) : null}
                </View>
                <TouchableOpacity style={styles.pickerBtn} onPress={() => setShowEndTimePicker(true)}>
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
        onChange={(date) => setScheduledDate(toDateStr(date))}
        onClose={() => setShowDatePicker(false)}
      />
      <DateTimePickerSheet
        visible={showStartTimePicker}
        mode="time"
        title="Start Time"
        value={timeObjFromStr(scheduledStartTime)}
        onChange={(date) => setScheduledStartTime(toTimeStr(date))}
        onClose={() => setShowStartTimePicker(false)}
      />
      <DateTimePickerSheet
        visible={showEndTimePicker}
        mode="time"
        title="End Time"
        value={timeObjFromStr(scheduledEndTime)}
        onChange={(date) => setScheduledEndTime(toTimeStr(date))}
        onClose={() => setShowEndTimePicker(false)}
      />
    </SafeAreaView>
  );
}

function SectionLabel({ children }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return <Text style={styles.sectionLabel}>{children}</Text>;
}

function createStyles(colors, shadow) {
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
  });
}
