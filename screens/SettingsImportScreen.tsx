// screens/SettingsImportScreen.tsx
// Data import is an IMMEDIATE-action page: it reads a CSV the user picks, maps
// columns, validates, previews, then commits with ONE saveX per collection. No
// draft state (SettingsBookingScreen precedent) — do not add useSettingsDraft.
// All parse/map/validate logic lives in the pure utils/* modules; this screen is
// just orchestration + I/O. P3 added Jobs; P4 added Invoices (including
// historical PAID ones — see buildInvoiceImport's money-semantics doc); P5
// adds Expenses — all four entities with a wired pure builder now appear in
// the selector.
import React, { useEffect, useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity, Alert } from "react-native";
import * as DocumentPicker from "expo-document-picker";
import * as FileSystem from "expo-file-system/legacy";
import { Button } from "../components/UI";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { parseCsv, hashCsv } from "../utils/csvImport";
import { detectMapping, detectDateFormat, FIELD_DEFS, type ImportEntity, type DateFormat } from "../utils/importMapping";
import {
  buildCustomerImport,
  buildJobImport,
  buildInvoiceImport,
  buildExpenseImport,
  stripBatch,
  type ImportCounts,
  type RowOutcome,
} from "../utils/importEngine";
import { newBatchId, recordImportBatch, findBatchByFileHash } from "../utils/importHistory";
import {
  loadCustomers, saveCustomers,
  loadJobs, saveJobs,
  loadInvoices, saveInvoices,
  loadExpenses, saveExpenses,
  loadSettings,
  clearSampleData,
} from "../utils/storage";
import { isSampleId } from "../utils/sampleData";
import { reportError } from "../utils/analytics";
import { getTodayDateString } from "../utils/dateHelpers";
import type { TodayStackScreenProps } from "../types/navigation";

type Stage = "idle" | "mapping" | "preview" | "report";

// The cap on how many skip/flag rows the report renders directly — a bad
// file can produce thousands of outcomes, and the screen isn't a table
// viewer; the remainder is summarized as "+N more" instead.
const REPORT_ROW_CAP = 50;

const ENTITY_OPTIONS: { key: ImportEntity; label: string }[] = [
  { key: "customers", label: "Customers" },
  { key: "jobs", label: "Jobs" },
  { key: "invoices", label: "Invoices" },
  { key: "expenses", label: "Expenses" },
];

// Which mapped field key carries "the" date for a given entity — drives the
// date-format selector below. For invoices this is "due", but the SAME chosen
// format is applied to BOTH `due` and `paidAt` parsing inside
// buildInvoiceImport — a CSV export uses one date convention throughout,
// never two.
const DATE_FIELD_BY_ENTITY: Partial<Record<ImportEntity, string>> = {
  jobs: "scheduledDate",
  invoices: "due",
  expenses: "date",
};

type DateFormatChoice = "auto" | DateFormat;

const DATE_FORMAT_OPTIONS: { key: DateFormatChoice; label: string }[] = [
  { key: "auto", label: "Auto" },
  { key: "MDY", label: "M-D-Y" },
  { key: "DMY", label: "D-M-Y" },
  { key: "YMD", label: "Y-M-D" },
];

export default function SettingsImportScreen({ navigation }: TodayStackScreenProps<"SettingsImport">) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  useSettingsTabPop(navigation);

  const [entity, setEntity] = useState<ImportEntity>("customers");
  const [stage, setStage] = useState<Stage>("idle");
  const [headers, setHeaders] = useState<string[]>([]);
  const [rows, setRows] = useState<string[][]>([]);
  const [mapping, setMapping] = useState<(string | null)[]>([]);
  const [fileHash, setFileHash] = useState("");
  const [counts, setCounts] = useState<ImportCounts | null>(null);
  const [outcomes, setOutcomes] = useState<RowOutcome[]>([]);
  const [lastBatchId, setLastBatchId] = useState<string | null>(null);
  const [dateFormatChoice, setDateFormatChoice] = useState<DateFormatChoice>("auto");
  // Whether any sample (seed) records are still present — drives the "clear
  // sample data first" offer on the idle stage. null = still checking.
  const [samplePresent, setSamplePresent] = useState<boolean | null>(null);

  const dateFieldKey = DATE_FIELD_BY_ENTITY[entity];
  const dateColIndex = dateFieldKey ? mapping.findIndex((k) => k === dateFieldKey) : -1;
  // Once a file is picked, switching entities would silently discard the
  // loaded mapping/report — lock the selector until back to idle.
  const entityLocked = stage !== "idle";

  useEffect(() => {
    let cancelled = false;
    async function checkSampleData() {
      try {
        const [customers, jobs, invoices, expenses] = await Promise.all([
          loadCustomers(), loadJobs(), loadInvoices(), loadExpenses(),
        ]);
        const present = [...customers, ...jobs, ...invoices, ...expenses].some((r) => isSampleId(r.id));
        if (!cancelled) setSamplePresent(present);
      } catch (e) {
        reportError(e, { context: "csvImport.sampleCheck" });
        if (!cancelled) setSamplePresent(false);
      }
    }
    void checkSampleData();
    return () => { cancelled = true; };
  }, []);

  function selectEntity(next: ImportEntity) {
    if (entityLocked || next === entity) return;
    setEntity(next);
    setStage("idle");
    setHeaders([]);
    setRows([]);
    setMapping([]);
    setFileHash("");
    setCounts(null);
    setOutcomes([]);
    setLastBatchId(null);
    setDateFormatChoice("auto");
  }

  async function clearSampleDataFirst() {
    Alert.alert(
      "Clear sample data?",
      "This removes the example customers, jobs, invoices, and expenses TradeReady seeded for you. Your own data is not affected.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Clear sample data",
          style: "destructive",
          onPress: () => {
            void (async () => {
              try {
                await clearSampleData();
                setSamplePresent(false);
              } catch (e) {
                reportError(e, { context: "csvImport.clearSampleData" });
                Alert.alert("Could not clear sample data", "Please try again.");
              }
            })();
          },
        },
      ]
    );
  }

  async function pickFile() {
    try {
      const res = await DocumentPicker.getDocumentAsync({
        type: ["text/csv", "text/comma-separated-values", "*/*"],
        copyToCacheDirectory: true,
      });
      if (res.canceled || !res.assets?.[0]) return;
      const text = await FileSystem.readAsStringAsync(res.assets[0].uri, {
        encoding: FileSystem.EncodingType.UTF8,
      });
      const parsed = parseCsv(text);
      if (parsed.headers.length === 0) {
        Alert.alert("Empty file", "That file has no readable rows.");
        return;
      }
      const hash = hashCsv(text);
      const prior = await findBatchByFileHash(entity, hash);
      const proceed = () => {
        setHeaders(parsed.headers);
        setRows(parsed.rows);
        setMapping(detectMapping(entity, parsed.headers).mapping);
        setFileHash(hash);
        setStage("mapping");
        if (parsed.truncated) {
          Alert.alert("Large file", "Only the first 5,000 rows were read.");
        }
      };
      if (prior) {
        Alert.alert("Already imported?", "This exact file looks imported already. Import again?", [
          { text: "Cancel", style: "cancel" },
          { text: "Import again", onPress: proceed },
        ]);
      } else {
        proceed();
      }
    } catch (e) {
      reportError(e, { context: "csvImport.pickFile" });
      Alert.alert("Could not read file", "Please try a different CSV export.");
    }
  }

  function validateAndPreview() {
    const required = FIELD_DEFS[entity].filter((f) => f.required).map((f) => f.key);
    const missing = required.filter((k) => !mapping.includes(k));
    if (missing.length > 0) {
      Alert.alert("Map required columns", `Still need: ${missing.join(", ")}`);
      return;
    }
    setStage("preview");
  }

  async function commit() {
    let batchId = "";
    let resultCounts: ImportCounts;
    let resultOutcomes: RowOutcome[];
    try {
      batchId = newBatchId();
      switch (entity) {
        case "customers": {
          const existing = await loadCustomers();
          const res = buildCustomerImport(rows, mapping, existing, batchId);
          await saveCustomers(res.records); // ONE save for the whole collection — the durable write
          resultCounts = res.counts;
          resultOutcomes = res.outcomes;
          break;
        }
        case "jobs": {
          const resolvedDateFormat: DateFormat | null =
            dateFormatChoice === "auto"
              ? detectDateFormat(dateColIndex >= 0 ? rows.map((r) => r[dateColIndex]) : [])
              : dateFormatChoice;
          const existingCustomers = await loadCustomers();
          const existingJobs = await loadJobs();
          const res = buildJobImport(rows, mapping, existingCustomers, existingJobs, batchId, resolvedDateFormat);
          await saveCustomers(res.customers); // ONE save for the customers collection
          await saveJobs(res.jobs);           // ONE save for the jobs collection
          resultCounts = res.counts;
          resultOutcomes = res.outcomes;
          break;
        }
        case "invoices": {
          // Money phase: paid semantics, id/number derivation, and the
          // customer join all live in buildInvoiceImport — see its doc.
          const resolvedDateFormat: DateFormat | null =
            dateFormatChoice === "auto"
              ? detectDateFormat(dateColIndex >= 0 ? rows.map((r) => r[dateColIndex]) : [])
              : dateFormatChoice;
          const settings = await loadSettings(); // carries invoicePrefix/invoiceStartNumber
          const existingCustomers = await loadCustomers();
          const existingInvoices = await loadInvoices();
          const res = buildInvoiceImport(
            rows,
            mapping,
            existingCustomers,
            existingInvoices,
            batchId,
            resolvedDateFormat,
            settings,
            Date.now(),
          );
          await saveCustomers(res.customers); // ONE save for the customers collection
          await saveInvoices(res.invoices);   // ONE save for the invoices collection
          resultCounts = res.counts;
          resultOutcomes = res.outcomes;
          break;
        }
        case "expenses": {
          const resolvedDateFormat: DateFormat | null =
            dateFormatChoice === "auto"
              ? detectDateFormat(dateColIndex >= 0 ? rows.map((r) => r[dateColIndex]) : [])
              : dateFormatChoice;
          const existing = await loadExpenses();
          const res = buildExpenseImport(rows, mapping, existing, batchId, resolvedDateFormat);
          await saveExpenses(res.expenses); // ONE save for the whole collection — the durable write
          resultCounts = res.counts;
          resultOutcomes = res.outcomes;
          break;
        }
        default:
          // An entity reaches the selector only once it has a wired case above
          // (see ENTITY_OPTIONS) — this guards a future unwired entity from
          // silently running a different entity's commit logic.
          reportError(new Error(`Unwired import entity: ${entity}`), { context: "csvImport.commit" });
          return;
      }
    } catch (e) {
      reportError(e, { context: "csvImport.commit" });
      Alert.alert("Import failed", "Nothing was changed. Please try again.");
      return;
    }
    // Collections are durably saved — always surface the report/undo now, even if
    // the operational metadata write below fails.
    setCounts(resultCounts);
    setOutcomes(resultOutcomes);
    setLastBatchId(batchId);
    setStage("report");
    try {
      await recordImportBatch({ batchId, entity, fileHash, date: getTodayDateString(), counts: resultCounts });
    } catch (histErr) {
      reportError(histErr, { context: "csvImport.recordHistory" });
    }
  }

  async function undo() {
    if (!lastBatchId) return;
    try {
      switch (entity) {
        case "customers": {
          const existing = await loadCustomers();
          await saveCustomers(stripBatch(existing, lastBatchId));
          Alert.alert("Import undone", "The imported customers were removed.");
          break;
        }
        case "jobs": {
          // Owner decision: undoing a jobs import removes only the jobs.
          // Batch-created customers stay in place — later invoice imports
          // may reference them.
          const existingJobs = await loadJobs();
          await saveJobs(stripBatch(existingJobs, lastBatchId));
          Alert.alert("Import undone", "The imported jobs were removed.");
          break;
        }
        case "invoices": {
          // Same rationale as jobs: undo strips only the invoices. A
          // customer created during import is a real customer — later
          // imports (or the owner) may already be depending on it.
          const existingInvoices = await loadInvoices();
          await saveInvoices(stripBatch(existingInvoices, lastBatchId));
          Alert.alert("Import undone", "The imported invoices were removed.");
          break;
        }
        case "expenses": {
          const existingExpenses = await loadExpenses();
          await saveExpenses(stripBatch(existingExpenses, lastBatchId));
          Alert.alert("Import undone", "The imported expenses were removed.");
          break;
        }
        default:
          reportError(new Error(`Unwired import entity: ${entity}`), { context: "csvImport.undo" });
          return;
      }
      setLastBatchId(null);
      setOutcomes([]);
      setStage("idle");
    } catch (e) {
      reportError(e, { context: "csvImport.undo" });
      Alert.alert("Undo failed", "Please try again.");
    }
  }

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <Text style={styles.h1}>Import data</Text>
        <Text style={styles.sub}>
          Bring customers, jobs, invoices, or expenses in from a Jobber, Housecall Pro, QuickBooks, or spreadsheet CSV export.
        </Text>

        <View style={styles.entityRow}>
          {ENTITY_OPTIONS.map((opt) => (
            <TouchableOpacity
              key={opt.key}
              style={[styles.chip, entity === opt.key && styles.chipOn, entityLocked && styles.chipLocked]}
              onPress={() => selectEntity(opt.key)}
              disabled={entityLocked}
              accessibilityRole="button"
              accessibilityState={{ disabled: entityLocked }}
              accessibilityLabel={`Import ${opt.label}`}
            >
              <Text style={[styles.chipText, entity === opt.key && styles.chipTextOn]}>{opt.label}</Text>
            </TouchableOpacity>
          ))}
        </View>

        {stage === "idle" && (
          <View style={styles.card}>
            <Button label="Choose a CSV file" onPress={() => { void pickFile(); }} />
            {samplePresent && (
              <TouchableOpacity
                onPress={() => { void clearSampleDataFirst(); }}
                accessibilityRole="button"
                accessibilityLabel="Clear sample data first"
                style={styles.sampleRow}
              >
                <Text style={styles.link}>Clear sample data first</Text>
              </TouchableOpacity>
            )}
          </View>
        )}

        {stage === "mapping" && (
          <View style={styles.card}>
            <Text style={styles.h2}>Match columns</Text>
            {headers.map((h, i) => (
              <View key={i} style={styles.rowMap}>
                <Text style={styles.headerCell}>{h}</Text>
                <Text style={styles.arrow}>→</Text>
                <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                  {[{ key: null as string | null, label: "Ignore" }, ...FIELD_DEFS[entity]].map((f) => (
                    <TouchableOpacity
                      key={String(f.key)}
                      style={[styles.chip, mapping[i] === f.key && styles.chipOn]}
                      onPress={() => setMapping((m) => m.map((v, j) => (j === i ? f.key : v)))}
                      accessibilityRole="button"
                      accessibilityLabel={`Map "${h}" to ${f.label}`}
                    >
                      <Text style={[styles.chipText, mapping[i] === f.key && styles.chipTextOn]}>{f.label}</Text>
                    </TouchableOpacity>
                  ))}
                </ScrollView>
              </View>
            ))}
            {dateColIndex >= 0 && (
              <View style={styles.dateFormatRow}>
                <Text style={styles.sub}>Date format</Text>
                <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                  {DATE_FORMAT_OPTIONS.map((opt) => (
                    <TouchableOpacity
                      key={opt.key}
                      style={[styles.chip, dateFormatChoice === opt.key && styles.chipOn]}
                      onPress={() => setDateFormatChoice(opt.key)}
                      accessibilityRole="button"
                      accessibilityLabel={`Date format ${opt.label}`}
                    >
                      <Text style={[styles.chipText, dateFormatChoice === opt.key && styles.chipTextOn]}>{opt.label}</Text>
                    </TouchableOpacity>
                  ))}
                </ScrollView>
              </View>
            )}
            <Button label="Preview import" onPress={validateAndPreview} style={styles.actionBtn} />
          </View>
        )}

        {stage === "preview" && (
          <View style={styles.card}>
            <Text style={styles.h2}>Preview</Text>
            {rows.slice(0, 5).map((r, i) => (
              <Text key={i} style={styles.previewRow}>{r.join(" · ")}</Text>
            ))}
            <Text style={styles.sub}>{rows.length} row(s) ready to import.</Text>
            <Button label="Import now" onPress={() => { void commit(); }} style={styles.actionBtn} />
          </View>
        )}

        {stage === "report" && counts && (
          <View style={styles.card}>
            <Text style={styles.h2}>Import complete</Text>
            {entity === "jobs" && (
              <Text style={styles.sub}>
                {counts.ok} imported · {counts.flag} flagged (unrecognized status) · {counts.skip} skipped
              </Text>
            )}
            {entity === "invoices" && (
              <Text style={styles.sub}>
                {counts.ok} imported · {counts.flag} flagged (paid claim, no paid date) · {counts.skip} skipped
              </Text>
            )}
            {entity === "customers" && (
              <Text style={styles.sub}>
                {counts.created} new · {counts.matched} matched existing · {counts.skip} skipped
              </Text>
            )}
            {entity === "expenses" && (
              <Text style={styles.sub}>
                {counts.ok} imported · {counts.flag} flagged (unrecognized category) · {counts.skip} skipped
              </Text>
            )}
            {(() => {
              const problems = outcomes.filter((o) => o.status !== "ok");
              if (problems.length === 0) return null;
              const shown = problems.slice(0, REPORT_ROW_CAP);
              const extra = problems.length - shown.length;
              return (
                <View style={styles.reportDetail}>
                  {shown.map((o) => (
                    <Text
                      key={o.rowIndex}
                      style={o.status === "flag" ? styles.reportRowFlag : styles.reportRowSkip}
                    >
                      Row {o.rowIndex + 1}: {o.reason ?? (o.status === "flag" ? "Flagged" : "Skipped")}
                    </Text>
                  ))}
                  {extra > 0 && <Text style={styles.sub}>+{extra} more</Text>}
                </View>
              );
            })()}
            <Button label="Undo this import" variant="secondary" onPress={() => { void undo(); }} style={styles.actionBtn} />
            <TouchableOpacity onPress={() => setStage("idle")} accessibilityRole="button" accessibilityLabel="Import another file">
              <Text style={styles.link}>Import another file</Text>
            </TouchableOpacity>
          </View>
        )}
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginTop: spacing.md, ...shadow.card },
    h1: { fontSize: fontSize.xl, fontFamily: fonts.display, color: colors.textPrimary },
    h2: { fontSize: fontSize.lg, fontFamily: fonts.display, color: colors.textPrimary, marginBottom: spacing.sm },
    sub: { fontSize: fontSize.sm, fontFamily: fonts.bodyRegular, color: colors.textMuted, marginTop: spacing.xs },
    entityRow: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.sm },
    chipLocked: { opacity: 0.5 },
    sampleRow: { marginTop: spacing.sm },
    reportDetail: { marginTop: spacing.sm, gap: spacing.xs },
    reportRowSkip: { fontSize: fontSize.sm, fontFamily: fonts.mono, color: colors.textMuted },
    reportRowFlag: { fontSize: fontSize.sm, fontFamily: fonts.mono, color: colors.warning },
    rowMap: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginVertical: spacing.xs },
    dateFormatRow: { marginTop: spacing.sm },
    headerCell: { width: 110, fontFamily: fonts.mono, fontSize: fontSize.sm, color: colors.textPrimary },
    arrow: { color: colors.textMuted },
    chip: {
      paddingHorizontal: spacing.sm,
      paddingVertical: spacing.xs,
      borderRadius: radius.full,
      borderWidth: 1,
      borderColor: colors.border,
      marginRight: spacing.xs,
    },
    chipOn: { backgroundColor: colors.accent, borderColor: colors.accent },
    chipText: { fontSize: fontSize.sm, fontFamily: fonts.bodyRegular, color: colors.textPrimary },
    chipTextOn: { color: colors.textOnAccent },
    previewRow: { fontFamily: fonts.mono, fontSize: fontSize.sm, color: colors.textPrimary },
    actionBtn: { marginTop: spacing.md },
    link: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.accent, marginTop: spacing.md },
  });
}
