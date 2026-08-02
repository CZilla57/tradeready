// screens/AddRecurringInvoiceScreen.tsx
// Create / edit a maintenance plan (RecurringInvoice rule). Modal in the
// Invoices stack: navigation.navigate("AddRecurringInvoice", { ruleId }) to
// edit, ...("AddRecurringInvoice", {}) to create.
//
// No invoice is created here. The engine (utils/recurringInvoices.ts)
// generates on its next run — a start date of today or in the past produces
// invoices on the next app open/foreground, mirroring recurring jobs.

import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { loadRecurringInvoices, saveRecurringInvoices, loadCustomers, getOrCreateCustomer, resolveCustomer } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { Button } from "../components/UI";
import Field from "../components/Field";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { RecurrenceCadence, RecurrenceEndCondition, RecurringInvoice } from "../types/models";
import type { InvoiceStackScreenProps } from "../types/navigation";

function todayStr(): string {
  return new Date().toISOString().split("T")[0];
}

function dateObjFromStr(str: string): Date {
  if (!str) return new Date();
  const [y, m, d] = str.split("-").map(Number);
  return new Date(y, m - 1, d);
}

function toDateStr(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function displayDate(str: string): string | null {
  if (!str) return null;
  return dateObjFromStr(str).toLocaleDateString("en-US", {
    weekday: "long", month: "long", day: "numeric",
  });
}

export default function AddRecurringInvoiceScreen({ route, navigation }: InvoiceStackScreenProps<'AddRecurringInvoice'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { ruleId } = route.params || {};
  const isEditing = !!ruleId;

  const [customer, setCustomer] = useState<string>("");
  const [email, setEmail] = useState<string>("");
  const [phone, setPhone] = useState<string>("");
  const [amount, setAmount] = useState<string>("");
  const [desc, setDesc] = useState<string>("");
  const [dueDays, setDueDays] = useState<string>("30");
  const [cadence, setCadence] = useState<RecurrenceCadence>("monthly");
  const [startDate, setStartDate] = useState<string>(todayStr());
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>("never");
  const [endCount, setEndCount] = useState<string>("");
  const [endDate, setEndDate] = useState<string>("");
  const [showStartDatePicker, setShowStartDatePicker] = useState<boolean>(false);
  const [showEndDatePicker, setShowEndDatePicker] = useState<boolean>(false);
  const [existingRule, setExistingRule] = useState<RecurringInvoice | null>(null);
  const [saving, setSaving] = useState<boolean>(false);

  useEffect(() => {
    navigation.setOptions({ title: isEditing ? "Edit Maintenance Plan" : "New Maintenance Plan" });
    if (!isEditing) return;
    (async () => {
      const [rules, customers] = await Promise.all([loadRecurringInvoices(), loadCustomers()]);
      const rule = rules.find((r) => r.id === ruleId);
      if (!rule) {
        Alert.alert("Error", "Maintenance plan not found.");
        navigation.goBack();
        return;
      }
      setExistingRule(rule);
      setCustomer(rule.customerName);
      setAmount(String(rule.amount));
      setDesc(rule.description);
      setDueDays(String(rule.dueDays));
      setCadence(rule.cadence);
      setStartDate(rule.nextDueDate);
      setEndCondition(rule.endCondition);
      setEndCount(rule.endCount != null ? String(rule.endCount) : "");
      setEndDate(rule.endDate ?? "");
      const record = resolveCustomer(customers, { customerId: rule.customerId, customerName: rule.customerName });
      setEmail(record?.email ?? "");
      setPhone(record?.phone ?? "");
    })();
  }, [ruleId, isEditing, navigation]);

  async function handleSave() {
    if (!customer.trim()) {
      Alert.alert("Missing info", "Customer name is required.");
      return;
    }
    const parsedAmount = parseFloat(amount);
    if (!amount.trim() || isNaN(parsedAmount) || parsedAmount <= 0) {
      Alert.alert("Missing info", "Please enter a valid invoice amount.");
      return;
    }
    const parsedDueDays = parseInt(dueDays, 10);
    if (!dueDays.trim() || isNaN(parsedDueDays) || parsedDueDays < 0) {
      Alert.alert("Missing info", "Enter payment terms in days (e.g. 30).");
      return;
    }
    const parsedEndCount = parseInt(endCount, 10);
    if (endCondition === "count" && (!endCount.trim() || isNaN(parsedEndCount) || parsedEndCount < 1)) {
      Alert.alert("End count required", "Please enter a number of invoices greater than 0.");
      return;
    }
    if (endCondition === "date" && !endDate) {
      Alert.alert("End date required", "Please select an end date for the plan.");
      return;
    }

    setSaving(true);
    // The only sanctioned customer-creation path: upsert by normalized name;
    // blank contact fields backfill, existing values are never clobbered.
    const record = await getOrCreateCustomer({
      name: customer.trim(),
      email: email.trim(),
      phone: phone.trim(),
    });
    const rules = await loadRecurringInvoices();

    const shared = {
      customerId: record?.id ?? "",
      customerName: customer.trim(),
      description: desc.trim(),
      amount: parsedAmount,
      dueDays: parsedDueDays,
      cadence,
      endCondition,
      endCount: endCondition === "count" ? parsedEndCount : undefined,
      endDate: endCondition === "date" ? endDate : undefined,
      nextDueDate: startDate,
    };

    let updated: RecurringInvoice[];
    if (isEditing && existingRule) {
      // Edit preserves the plan's history (id, occurrenceCount,
      // lastGeneratedDate, isActive, createdAt) — the reason the action sheet
      // offers Edit instead of cancel-and-recreate.
      updated = rules.map((r) => (r.id === existingRule.id ? { ...r, ...shared } : r));
    } else {
      const rule: RecurringInvoice = {
        id: `ri${Date.now()}`,
        ...shared,
        occurrenceCount: 0,
        lastGeneratedDate: null,
        isActive: true,
        createdAt: todayStr(),
      };
      updated = [...rules, rule];
    }

    await saveRecurringInvoices(updated);
    // Fire-and-forget: rules aren't saved through saveInvoices, so the sweep
    // doesn't rerun on its own — mirror AddInvoiceScreen's explicit call.
    syncNotifications();
    setSaving(false);
    navigation.goBack();
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
          <Field label="Customer name *" value={customer} onChangeText={setCustomer} placeholder="Jane's Bakery" />
          <Field label="Customer email" value={email} onChangeText={setEmail} placeholder="jane@example.com" keyboardType="email-address" autoCapitalize="none" />
          <Field label="Customer phone" value={phone} onChangeText={setPhone} placeholder="(555) 123-4567" keyboardType="phone-pad" />
          <View style={styles.row}>
            <Field label="Amount ($) *" value={amount} onChangeText={setAmount} placeholder="150" keyboardType="decimal-pad" flex />
            <View style={{ width: spacing.md }} />
            <Field label="Due (days)" value={dueDays} onChangeText={setDueDays} placeholder="30" keyboardType="number-pad" flex />
          </View>
          <Field label="Description of work" value={desc} onChangeText={setDesc} placeholder="Monthly maintenance visit" multiline />

          <Text style={styles.fieldLabel}>Repeats</Text>
          <View style={styles.chipRow}>
            {(["daily", "weekly", "monthly", "quarterly", "annually"] as RecurrenceCadence[]).map((c) => (
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

          <View style={styles.fieldGroup}>
            <Text style={styles.fieldLabel}>{isEditing ? "Next invoice date" : "First invoice date"}</Text>
            <TouchableOpacity
              style={styles.pickerBtn}
              onPress={() => setShowStartDatePicker(true)}
              accessibilityRole="button"
              accessibilityLabel={`${isEditing ? "Next" : "First"} invoice date: ${displayDate(startDate)}`}
            >
              <Text style={styles.pickerBtnText}>{displayDate(startDate)}</Text>
              <Ionicons name="calendar-outline" size={16} color={colors.textMuted} style={styles.pickerIcon} />
            </TouchableOpacity>
          </View>

          <Text style={styles.fieldLabel}>Ends</Text>
          <View style={styles.chipRow}>
            {(["never", "count", "date"] as RecurrenceEndCondition[]).map((ec) => (
              <TouchableOpacity
                key={ec}
                style={[styles.chip, endCondition === ec && styles.chipSelected]}
                onPress={() => setEndCondition(ec)}
                accessibilityRole="radio"
                accessibilityLabel={ec === "never" ? "Never ends" : ec === "count" ? "Ends after a number of invoices" : "Ends by date"}
                accessibilityState={{ selected: endCondition === ec }}
              >
                <Text style={[styles.chipText, endCondition === ec && styles.chipTextSelected]}>
                  {ec === "never" ? "Never" : ec === "count" ? "After N invoices" : "By date"}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          {endCondition === "count" && (
            <Field label="Number of invoices" value={endCount} onChangeText={setEndCount} placeholder="e.g. 12" keyboardType="number-pad" />
          )}

          {endCondition === "date" && (
            <View style={styles.fieldGroup}>
              <View style={styles.pickerLabelRow}>
                <Text style={styles.fieldLabel}>End date</Text>
                {endDate ? (
                  <TouchableOpacity
                    onPress={() => setEndDate("")}
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
                  {endDate ? displayDate(endDate) : "Select end date…"}
                </Text>
                <Ionicons name="calendar-outline" size={16} color={colors.textMuted} style={styles.pickerIcon} />
              </TouchableOpacity>
            </View>
          )}

          <View style={styles.actions}>
            <Button label="Cancel" variant="ghost" onPress={() => navigation.goBack()} style={{ flex: 1 }} />
            <View style={{ width: spacing.sm }} />
            <Button label={isEditing ? "Save changes" : "Create plan"} onPress={handleSave} loading={saving} style={{ flex: 2 }} />
          </View>
        </ScrollView>
      </KeyboardAvoidingView>

      <DateTimePickerSheet
        visible={showStartDatePicker}
        mode="date"
        title={isEditing ? "Next Invoice Date" : "First Invoice Date"}
        value={dateObjFromStr(startDate)}
        onChange={(date: Date) => setStartDate(toDateStr(date))}
        onClose={() => setShowStartDatePicker(false)}
      />
      <DateTimePickerSheet
        visible={showEndDatePicker}
        mode="date"
        title="End Date"
        value={dateObjFromStr(endDate || todayStr())}
        onChange={(date: Date) => setEndDate(toDateStr(date))}
        onClose={() => setShowEndDatePicker(false)}
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: 160 },
    row: { flexDirection: "row" },
    fieldGroup: { marginBottom: spacing.sm },
    fieldLabel: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginBottom: 5,
    },
    chipRow: {
      flexDirection: "row",
      flexWrap: "wrap",
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
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
    chipTextSelected: {
      fontFamily: fonts.bodySemiBold,
      color: colors.surface,
    },
    pickerLabelRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: 5,
    },
    pickerClear: {
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.accent,
      textTransform: "uppercase",
      letterSpacing: 0.4,
    },
    pickerBtn: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      // minHeight (not height): accessibility text grows the control instead
      // of clipping — components/Field.tsx pattern.
      minHeight: 44,
      paddingHorizontal: spacing.md,
      flexDirection: "row",
      alignItems: "center",
      justifyContent: "space-between",
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
    },
    pickerBtnText: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      flex: 1,
    },
    pickerBtnPlaceholder: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textMuted,
      flex: 1,
    },
    pickerIcon: { marginLeft: spacing.sm },
    actions: { flexDirection: "row", marginTop: spacing.lg },
  });
}
