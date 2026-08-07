// screens/SettingsImportScreen.tsx
// Data import is an IMMEDIATE-action page: it reads a CSV the user picks, maps
// columns, validates, previews, then commits with ONE saveX per collection. No
// draft state (SettingsBookingScreen precedent) — do not add useSettingsDraft.
// All parse/map/validate logic lives in the pure utils/* modules; this screen is
// just orchestration + I/O. P2 supports the Customers slot only — Jobs/Invoices/
// Expenses slots land in later phases (YAGNI for now).
import React, { useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity, Alert } from "react-native";
import * as DocumentPicker from "expo-document-picker";
import * as FileSystem from "expo-file-system/legacy";
import { Button } from "../components/UI";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { parseCsv, hashCsv } from "../utils/csvImport";
import { detectMapping, FIELD_DEFS, type ImportEntity } from "../utils/importMapping";
import { buildCustomerImport, stripBatch, type ImportCounts } from "../utils/importEngine";
import { newBatchId, recordImportBatch, findBatchByFileHash } from "../utils/importHistory";
import { loadCustomers, saveCustomers } from "../utils/storage";
import { reportError } from "../utils/analytics";
import { getTodayDateString } from "../utils/dateHelpers";
import type { TodayStackScreenProps } from "../types/navigation";

type Stage = "idle" | "mapping" | "preview" | "report";

export default function SettingsImportScreen({ navigation }: TodayStackScreenProps<"SettingsImport">) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  useSettingsTabPop(navigation);

  const [entity] = useState<ImportEntity>("customers"); // P2: customers only; P3-P5 add slots
  const [stage, setStage] = useState<Stage>("idle");
  const [headers, setHeaders] = useState<string[]>([]);
  const [rows, setRows] = useState<string[][]>([]);
  const [mapping, setMapping] = useState<(string | null)[]>([]);
  const [fileHash, setFileHash] = useState("");
  const [counts, setCounts] = useState<ImportCounts | null>(null);
  const [lastBatchId, setLastBatchId] = useState<string | null>(null);

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
    try {
      const batchId = newBatchId();
      const existing = await loadCustomers();
      const res = buildCustomerImport(rows, mapping, existing, batchId);
      await saveCustomers(res.records); // ONE save for the whole collection
      await recordImportBatch({ batchId, entity, fileHash, date: getTodayDateString(), counts: res.counts });
      setCounts(res.counts);
      setLastBatchId(batchId);
      setStage("report");
    } catch (e) {
      reportError(e, { context: "csvImport.commit" });
      Alert.alert("Import failed", "Nothing was changed. Please try again.");
    }
  }

  async function undo() {
    if (!lastBatchId) return;
    try {
      const existing = await loadCustomers();
      await saveCustomers(stripBatch(existing, lastBatchId));
      Alert.alert("Import undone", "The imported customers were removed.");
      setLastBatchId(null);
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
          Bring customers in from a Jobber, Housecall Pro, QuickBooks, or spreadsheet CSV export.
        </Text>

        {stage === "idle" && (
          <View style={styles.card}>
            <Button label="Choose a CSV file" onPress={() => { void pickFile(); }} />
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
            <Text style={styles.sub}>
              {counts.created} new · {counts.matched} matched existing · {counts.skip} skipped
            </Text>
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
    rowMap: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginVertical: spacing.xs },
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
