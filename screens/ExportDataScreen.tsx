// screens/ExportDataScreen.tsx
// Accounting export (roadmap #7): pick a date range, share income /
// expenses / mileage as CSVs. All math lives in utils/csvExport — this
// screen just holds range state and hands strings to the share sheet.

import React, { useCallback, useMemo, useState } from "react";
import { Alert, ScrollView, StyleSheet, Text, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadInvoices, loadExpenses, loadTrips, loadCustomers, loadJobs } from "../utils/storage";
import { Button, Card } from "../components/UI";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import {
  buildExpensesCsv,
  buildIncomeCsv,
  buildTripsCsv,
  csvFilename,
  csvRowCount,
  exportDateRange,
  shareCsv,
  shareZip,
  type ExportRangeId,
} from "../utils/csvExport";
import { buildAccountingPackage } from "../utils/accountingPackage";
import type { DateRange } from "../utils/moneyUtils";
import type { Customer, Expense, Invoice, Job, Trip } from "../types/models";

type RangeChoice = ExportRangeId | "custom";

const RANGE_OPTIONS: { id: RangeChoice; label: string }[] = [
  { id: "this_month", label: "This Month" },
  { id: "this_quarter", label: "This Quarter" },
  { id: "this_year", label: "This Year" },
  { id: "last_year", label: "Last Year" },
  { id: "all_time", label: "All Time" },
  { id: "custom", label: "Custom" },
];

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function endOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59);
}

function ymd(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export default function ExportDataScreen() {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [jobNameById, setJobNameById] = useState<Record<string, string>>({});

  const [choice, setChoice] = useState<RangeChoice>("this_year");
  const [customStart, setCustomStart] = useState<Date>(() => new Date(new Date().getFullYear(), 0, 1));
  const [customEnd, setCustomEnd] = useState<Date>(() => new Date());
  const [pickerFor, setPickerFor] = useState<"start" | "end" | null>(null);

  useFocusEffect(
    useCallback(() => {
      loadInvoices().then(setInvoices);
      loadExpenses().then(setExpenses);
      loadTrips().then(setTrips);
      loadCustomers().then(setCustomers);
      loadJobs().then((jobs: Job[]) => {
        const byId: Record<string, string> = {};
        jobs.forEach((job) => {
          byId[job.id] = job.title;
        });
        setJobNameById(byId);
      });
    }, [])
  );

  const range: DateRange = useMemo(() => {
    if (choice === "custom") {
      return { start: startOfDay(customStart), end: endOfDay(customEnd) };
    }
    return exportDateRange(choice);
  }, [choice, customStart, customEnd]);

  const csvs = useMemo(
    () => ({
      income: buildIncomeCsv(invoices, range.start, range.end),
      expenses: buildExpensesCsv(expenses, range.start, range.end),
      mileage: buildTripsCsv(trips, range.start, range.end),
    }),
    [invoices, expenses, trips, range]
  );

  function handleShare(dataset: "income" | "expenses" | "mileage") {
    if (choice === "custom" && startOfDay(customStart) > endOfDay(customEnd)) {
      Alert.alert("Check your dates", "The start date is after the end date.");
      return;
    }
    shareCsv(csvs[dataset], csvFilename(dataset, range, choice));
  }

  function handlePackage() {
    if (choice === "custom" && startOfDay(customStart) > endOfDay(customEnd)) {
      Alert.alert("Check your dates", "The start date is after the end date.");
      return;
    }
    const pkg = buildAccountingPackage(
      { invoices, expenses, trips, customers, jobNameById },
      range.start, range.end,
    );
    shareZip(pkg.bytes, pkg.filename);
  }

  const datasets: { key: "income" | "expenses" | "mileage"; label: string; hint: string }[] = [
    { key: "income", label: "Income", hint: "One row per payment received" },
    { key: "expenses", label: "Expenses", hint: "One row per expense" },
    { key: "mileage", label: "Mileage", hint: "One row per logged trip" },
  ];

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Text style={styles.heading}>Date range</Text>
        <View style={styles.chipRow}>
          {RANGE_OPTIONS.map((opt) => {
            const active = choice === opt.id;
            return (
              <TouchableOpacity
                key={opt.id}
                style={[styles.chip, active && { backgroundColor: colors.accent }]}
                onPress={() => setChoice(opt.id)}
                accessibilityRole="button"
                accessibilityState={{ selected: active }}
                accessibilityLabel={`Range: ${opt.label}`}
              >
                <Text style={[styles.chipText, active && styles.chipTextActive]}>
                  {opt.label}
                </Text>
              </TouchableOpacity>
            );
          })}
        </View>

        {choice === "custom" ? (
          <View style={styles.customRow}>
            <TouchableOpacity
              style={styles.dateField}
              onPress={() => setPickerFor("start")}
              accessibilityRole="button"
              accessibilityLabel="Start date"
            >
              <Text style={styles.dateLabel}>From</Text>
              <Text style={styles.dateValue}>{ymd(customStart)}</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={styles.dateField}
              onPress={() => setPickerFor("end")}
              accessibilityRole="button"
              accessibilityLabel="End date"
            >
              <Text style={styles.dateLabel}>To</Text>
              <Text style={styles.dateValue}>{ymd(customEnd)}</Text>
            </TouchableOpacity>
          </View>
        ) : null}

        <Text style={styles.heading}>Export</Text>
        <Card style={styles.rowCard}>
          <View style={styles.rowLeft}>
            <Text style={styles.rowLabel}>Accountant package (.zip)</Text>
            <Text style={styles.rowHint}>Everything your accountant needs, in one file</Text>
          </View>
          <Button label="Share" onPress={handlePackage} style={styles.shareBtn} />
        </Card>
        {datasets.map((d) => (
          <Card key={d.key} style={styles.rowCard}>
            <View style={styles.rowLeft}>
              <Text style={styles.rowLabel}>{d.label}</Text>
              <Text style={styles.rowHint}>
                {csvRowCount(csvs[d.key])} rows · {d.hint}
              </Text>
            </View>
            <Button label="Share" onPress={() => handleShare(d.key)} style={styles.shareBtn} />
          </Card>
        ))}
        <Text style={styles.footnote}>
          CSV files open in Excel, Numbers, Google Sheets, and import into
          accounting software. Amounts are plain numbers; income is listed by
          payment received.
        </Text>
      </ScrollView>

      <DateTimePickerSheet
        visible={pickerFor !== null}
        mode="date"
        value={pickerFor === "start" ? customStart : customEnd}
        title={pickerFor === "start" ? "Start date" : "End date"}
        onChange={(d) => (pickerFor === "start" ? setCustomStart(d) : setCustomEnd(d))}
        onClose={() => setPickerFor(null)}
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 120, ...layout.contentColumn },
    heading: {
      fontFamily: fonts.mono,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: spacing.md,
      marginBottom: spacing.sm,
      textTransform: "uppercase",
      letterSpacing: 0.5,
    },
    chipRow: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
    chip: {
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      borderRadius: radius.md,
      backgroundColor: colors.surface,
      ...shadow.card,
    },
    chipText: { color: colors.textPrimary, fontSize: fontSize.sm, fontFamily: fonts.bodyMedium },
    chipTextActive: { color: colors.textOnAccent, fontWeight: "600" },
    customRow: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.sm },
    dateField: {
      flex: 1,
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      padding: spacing.md,
      ...shadow.card,
    },
    dateLabel: { color: colors.textMuted, fontSize: fontSize.xs, marginBottom: 2 },
    dateValue: { color: colors.textPrimary, fontSize: fontSize.md, fontFamily: fonts.mono },
    rowCard: {
      flexDirection: "row",
      alignItems: "center",
      justifyContent: "space-between",
      marginBottom: spacing.sm,
    },
    rowLeft: { flex: 1, paddingRight: spacing.md },
    rowLabel: { color: colors.textPrimary, fontSize: fontSize.lg, fontFamily: fonts.bodySemiBold },
    rowHint: { color: colors.textMuted, fontSize: fontSize.xs, marginTop: 2 },
    shareBtn: { minWidth: 92 },
    footnote: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: spacing.md,
      lineHeight: 18,
    },
  });
}
