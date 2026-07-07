// screens/PricingCalculatorScreen.js
// The heart of the app for blue collar workers.
// Enter hours, materials, and settings → see a live price breakdown →
// Claude writes a professional estimate → advance the job to "estimate_sent".

import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
  Switch,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { composeEmail } from "../utils/messaging";
import {
  calculatePriceRange,
  getSanityWarnings,
  buildEstimatePrompt,
  breakEvenPrice,
  buildEstimateInput,
} from "../utils/pricingEngine";
import { formatQuote } from "../utils/format";
import { generateMessage } from "../utils/anthropicMessage";
import { loadJobs, saveJobs, loadCustomers, loadSettings } from "../utils/storage";
import { Button, Card, Divider } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';

export default function PricingCalculatorScreen({ route, navigation }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params || {};

  // Job & context
  const [job, setJob] = useState(null);
  const [customer, setCustomer] = useState(null);
  const [settings, setSettings] = useState(null);

  // Pricing inputs
  const [laborHours, setLaborHours] = useState("2");
  const [laborRate, setLaborRate] = useState("85");
  const [materials, setMaterials] = useState([]);
  const [materialMarkup, setMaterialMarkup] = useState("20");
  const [overheadPercent, setOverheadPercent] = useState("15");
  const [marginPercent, setMarginPercent] = useState("20");
  const [travelMiles, setTravelMiles] = useState("0");
  const [isEmergency, setIsEmergency] = useState(false);
  const [taxPercent, setTaxPercent] = useState("0");

  // UI state
  const [tab, setTab] = useState("calculator"); // calculator | estimate
  const [generatedEstimate, setGeneratedEstimate] = useState("");
  const [generating, setGenerating] = useState(false);
  const [saving, setSaving] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    async function load() {
      const [jobs, customers, s] = await Promise.all([
        loadJobs(), loadCustomers(), loadSettings(),
      ]);
      const j = jobs.find((x) => x.id === jobId);
      if (j) {
        setJob(j);
        setLaborHours(String(j.laborHours || 2));
        setLaborRate(String(j.laborRate || s.laborRate || 85));
        setMaterials(j.materials || []);
        setMaterialMarkup(String(j.materialMarkup ?? s.materialMarkup ?? 20));
        setOverheadPercent(String(j.overhead ?? s.overheadPercent ?? 15));
        setMarginPercent(String(j.margin ?? s.marginPercent ?? 20));
        const c = customers.find((x) => x.id === j.customerId);
        setCustomer(c || null);
      }
      setSettings(s);
      // Only apply global defaults when there is no saved job — the job-load
      // block above already uses settings as a fallback for each field.
      if (s && !j) {
        setLaborRate(String(s.laborRate || 85));
        setMaterialMarkup(String(s.materialMarkup ?? 20));
        setOverheadPercent(String(s.overheadPercent ?? 15));
        setMarginPercent(String(s.marginPercent ?? 20));
      }
    }
    load();
  }, [jobId]);

  // Live calculation — recalculates on every input change
  const params = buildEstimateInput(
    { laborHours, laborRate, materials, materialMarkup, overheadPercent, marginPercent, travelMiles, isEmergency, taxPercent },
    settings,
  );

  const range = calculatePriceRange(params);
  const breakdown = range.breakdown;
  const warnings = getSanityWarnings({
    total: breakdown.total,
    laborHours: params.laborHours,
    laborRate: params.laborRate,
    materials,
    params,
  });
  const breakEven = breakEvenPrice(params);

  function addMaterial() {
    setMaterials((prev) => [
      ...prev,
      { id: `m${Date.now()}`, name: "", quantity: 1, unitCost: 0 },
    ]);
  }

  function updateMaterial(id, field, value) {
    setMaterials((prev) =>
      prev.map((m) => (m.id === id ? { ...m, [field]: value } : m))
    );
  }

  function removeMaterial(id) {
    setMaterials((prev) => prev.filter((m) => m.id !== id));
  }

  async function saveToJob() {
    if (!jobId) return;
    setSaving(true);
    const jobs = await loadJobs();
    const updated = jobs.map((j) =>
      j.id === jobId
        ? {
            ...j,
            laborHours: params.laborHours,
            laborRate: params.laborRate,
            materials,
            materialMarkup: params.materialMarkup,
            overhead: params.overheadPercent,
            margin: params.marginPercent,
            estimateTotal: breakdown.total,
          }
        : j
    );
    await saveJobs(updated);
    setSaving(false);
    Alert.alert("Saved", "Pricing saved to job.");
  }

  async function generateEstimate() {
    if (!job || !settings) return;
    setGenerating(true);
    setTab("estimate");

    const prompt = buildEstimatePrompt({
      job: { ...job, laborHours: params.laborHours, laborRate: params.laborRate, materials, materialMarkup: params.materialMarkup },
      customer: customer || { name: job.customerName, address: job.address },
      breakdown,
      settings,
      range,
    });

    const text = await generateMessage({
      prompt,
      apiKey: settings?.anthropicKey,
      max_tokens: 1500,
      fallback: () =>
        "Couldn't generate an estimate automatically. Add your Anthropic API key in Settings and check your connection, then tap Regenerate.",
    });
    setGeneratedEstimate(text);
    setGenerating(false);
  }

  async function sendEstimateByEmail() {
    if (!customer?.email && !job?.email) {
      Alert.alert("No email", "No customer email on file.");
      return;
    }
    const sent = await composeEmail({
      recipients: [customer?.email || job?.email],
      subject: `Estimate: ${job?.title || "Your job"} — ${formatQuote(breakdown.total)}`,
      body: generatedEstimate,
    });
    if (!sent) return;

    // Advance job status to estimate_sent
    if (job?.status === "lead") {
      const jobs = await loadJobs();
      await saveJobs(
        jobs.map((j) => (j.id === jobId ? { ...j, status: "estimate_sent", estimateTotal: breakdown.total } : j))
      );
    }
  }

  async function copyEstimate() {
    await Clipboard.setStringAsync(generatedEstimate);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      {/* Tab switcher */}
      <View style={styles.tabs}>
        <TouchableOpacity
          style={[styles.tab, tab === "calculator" && styles.tabActive]}
          onPress={() => setTab("calculator")}
        >
          <Text style={[styles.tabText, tab === "calculator" && styles.tabTextActive]}>
            🧮 Calculator
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tab, tab === "estimate" && styles.tabActive]}
          onPress={() => { setTab("estimate"); if (!generatedEstimate) generateEstimate(); }}
        >
          <Text style={[styles.tabText, tab === "estimate" && styles.tabTextActive]}>
            📄 Estimate
          </Text>
        </TouchableOpacity>
      </View>

      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        {tab === "calculator" ? (
          <CalculatorTab
            laborHours={laborHours} setLaborHours={setLaborHours}
            laborRate={laborRate} setLaborRate={setLaborRate}
            materials={materials}
            materialMarkup={materialMarkup} setMaterialMarkup={setMaterialMarkup}
            overheadPercent={overheadPercent} setOverheadPercent={setOverheadPercent}
            marginPercent={marginPercent} setMarginPercent={setMarginPercent}
            travelMiles={travelMiles} setTravelMiles={setTravelMiles}
            taxPercent={taxPercent} setTaxPercent={setTaxPercent}
            isEmergency={isEmergency} setIsEmergency={setIsEmergency}
            addMaterial={addMaterial}
            updateMaterial={updateMaterial}
            removeMaterial={removeMaterial}
            breakdown={breakdown}
            range={range}
            breakEven={breakEven}
            warnings={warnings}
            onSave={saveToJob}
            saving={saving}
            onGenerateEstimate={generateEstimate}
          />
        ) : (
          <EstimateTab
            generating={generating}
            generatedEstimate={generatedEstimate}
            onRegenerate={generateEstimate}
            onCopy={copyEstimate}
            onEmail={sendEstimateByEmail}
            copied={copied}
            total={breakdown.total}
          />
        )}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

// ── Calculator Tab ─────────────────────────────────────────────────────────

function CalculatorTab({
  laborHours, setLaborHours, laborRate, setLaborRate,
  materials, materialMarkup, setMaterialMarkup,
  overheadPercent, setOverheadPercent, marginPercent, setMarginPercent,
  travelMiles, setTravelMiles, taxPercent, setTaxPercent,
  isEmergency, setIsEmergency,
  addMaterial, updateMaterial, removeMaterial,
  breakdown, range, breakEven, warnings,
  onSave, saving, onGenerateEstimate,
}) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">

      {/* Live price display */}
      <Card style={styles.priceCard}>
        <Text style={styles.priceLabel}>Recommended price</Text>
        <Text style={styles.priceMain}>{formatQuote(range.recommended)}</Text>
        <Text style={styles.priceRange}>
          Range: {formatQuote(range.low)} – {formatQuote(range.high)}
        </Text>
        <Text style={styles.breakEven}>Break-even: {formatQuote(breakEven)}</Text>
      </Card>

      {/* Warnings */}
      {warnings.map((w, i) => (
        <View key={i} style={styles.warningBox}>
          <Text style={styles.warningText}>⚠️ {w}</Text>
        </View>
      ))}

      {/* Labor */}
      <SectionLabel>Labor</SectionLabel>
      <Card>
        <View style={styles.inputRow}>
          <SmallInput
            label="Hours"
            value={laborHours}
            onChange={setLaborHours}
            placeholder="2"
            suffix="hrs"
          />
          <SmallInput
            label="Rate"
            value={laborRate}
            onChange={setLaborRate}
            placeholder="85"
            prefix="$"
            suffix="/hr"
          />
          <View style={styles.calcResult}>
            <Text style={styles.calcResultLabel}>Labor total</Text>
            <Text style={styles.calcResultValue}>{formatQuote(breakdown.laborCost)}</Text>
          </View>
        </View>
        <View style={[styles.inputRow, { marginTop: spacing.sm, alignItems: "center" }]}>
          <Text style={styles.toggleLabel}>Emergency / after-hours rate</Text>
          <Switch
            value={isEmergency}
            onValueChange={setIsEmergency}
            trackColor={{ true: colors.warning }}
          />
        </View>
      </Card>

      {/* Materials */}
      <SectionLabel>Materials</SectionLabel>
      <Card>
        {materials.length === 0 && (
          <Text style={styles.emptyMaterials}>No materials added yet.</Text>
        )}
        {materials.map((m) => (
          <View key={m.id} style={styles.materialRow}>
            <TextInput
              style={[styles.matInput, { flex: 2 }]}
              placeholder="Item name"
              placeholderTextColor={colors.textMuted}
              value={m.name}
              onChangeText={(v) => updateMaterial(m.id, "name", v)}
            />
            <TextInput
              style={styles.matInput}
              placeholder="Qty"
              placeholderTextColor={colors.textMuted}
              value={String(m.quantity)}
              onChangeText={(v) => updateMaterial(m.id, "quantity", parseFloat(v) || 0)}
              keyboardType="decimal-pad"
            />
            <TextInput
              style={styles.matInput}
              placeholder="$ each"
              placeholderTextColor={colors.textMuted}
              value={String(m.unitCost)}
              onChangeText={(v) => updateMaterial(m.id, "unitCost", parseFloat(v) || 0)}
              keyboardType="decimal-pad"
            />
            <TouchableOpacity onPress={() => removeMaterial(m.id)} style={styles.removeBtn}>
              <Text style={styles.removeBtnText}>✕</Text>
            </TouchableOpacity>
          </View>
        ))}
        <TouchableOpacity style={styles.addMaterialBtn} onPress={addMaterial}>
          <Text style={styles.addMaterialText}>+ Add material</Text>
        </TouchableOpacity>
        <View style={[styles.inputRow, { marginTop: spacing.sm }]}>
          <SmallInput
            label="Markup %"
            value={materialMarkup}
            onChange={setMaterialMarkup}
            placeholder="20"
            suffix="%"
          />
          <View style={styles.calcResult}>
            <Text style={styles.calcResultLabel}>Materials total</Text>
            <Text style={styles.calcResultValue}>{formatQuote(breakdown.materialCost)}</Text>
          </View>
        </View>
      </Card>

      {/* Business costs */}
      <SectionLabel>Business costs</SectionLabel>
      <Card>
        <View style={styles.inputRow}>
          <SmallInput label="Overhead %" value={overheadPercent} onChange={setOverheadPercent} placeholder="15" suffix="%" />
          <SmallInput label="Profit margin %" value={marginPercent} onChange={setMarginPercent} placeholder="20" suffix="%" />
          <SmallInput label="Travel miles" value={travelMiles} onChange={setTravelMiles} placeholder="0" suffix="mi" />
        </View>
        <SmallInput label="Tax %" value={taxPercent} onChange={setTaxPercent} placeholder="0" suffix="%" />
      </Card>

      {/* Full breakdown */}
      <SectionLabel>Full breakdown</SectionLabel>
      <Card>
        <BreakdownRow label="Labor" value={breakdown.laborCost} />
        <BreakdownRow label={`Materials (${materialMarkup}% markup)`} value={breakdown.materialCost} />
        {breakdown.travelCost > 0 && <BreakdownRow label="Travel" value={breakdown.travelCost} />}
        <BreakdownRow label={`Overhead (${overheadPercent}%)`} value={breakdown.overheadCost} />
        <BreakdownRow label={`Profit margin (${marginPercent}%)`} value={breakdown.profit} />
        {breakdown.taxAmount > 0 && <BreakdownRow label={`Tax (${taxPercent}%)`} value={breakdown.taxAmount} />}
        <Divider />
        <BreakdownRow label="TOTAL" value={breakdown.total} bold />
        <Text style={styles.effectiveRate}>
          Effective rate: {formatQuote(breakdown.effectiveHourlyRate)}/hr
        </Text>
      </Card>

      {/* Actions */}
      <View style={styles.actions}>
        <Button label={saving ? "Saving..." : "Save pricing"} variant="ghost" onPress={onSave} loading={saving} style={{ flex: 1 }} />
        <View style={{ width: spacing.sm }} />
        <Button label="Generate estimate →" onPress={onGenerateEstimate} style={{ flex: 2 }} />
      </View>
    </ScrollView>
  );
}

// ── Estimate Tab ───────────────────────────────────────────────────────────

function EstimateTab({ generating, generatedEstimate, onRegenerate, onCopy, onEmail, copied, total }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <ScrollView contentContainerStyle={styles.scroll}>
      <Card style={styles.estimateHeader}>
        <Text style={styles.estimateHeaderLabel}>Estimate total</Text>
        <Text style={styles.estimateHeaderTotal}>{formatQuote(total)}</Text>
      </Card>

      <Card style={styles.estimateBody}>
        {generating ? (
          <View style={styles.generatingRow}>
            <ActivityIndicator color={colors.accent} />
            <Text style={styles.generatingText}>  Writing your estimate…</Text>
          </View>
        ) : (
          <Text style={styles.estimateText}>{generatedEstimate}</Text>
        )}
      </Card>

      {!generating && generatedEstimate ? (
        <View style={styles.estimateActions}>
          <Button label={copied ? "Copied ✓" : "Copy text"} variant="ghost" onPress={onCopy} style={{ flex: 1 }} />
          <View style={{ width: spacing.sm }} />
          <Button label="↺ Regenerate" variant="ghost" onPress={onRegenerate} style={{ flex: 1 }} />
        </View>
      ) : null}

      {!generating && generatedEstimate ? (
        <Button
          label="✉ Email to customer →"
          onPress={onEmail}
          style={{ marginTop: spacing.sm }}
        />
      ) : null}

      <Text style={styles.estimateNote}>
        Sending this email will mark the job as "Estimate sent" and start the approval clock.
      </Text>
    </ScrollView>
  );
}

// ── Small reusable pieces ──────────────────────────────────────────────────

function SectionLabel({ children }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return <Text style={styles.sectionLabel}>{children}</Text>;
}

function SmallInput({ label, value, onChange, placeholder, prefix, suffix }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.smallInputWrap}>
      <Text style={styles.smallLabel}>{label}</Text>
      <View style={styles.smallInputRow}>
        {prefix ? <Text style={styles.inputAdornment}>{prefix}</Text> : null}
        <TextInput
          style={styles.smallInput}
          value={String(value)}
          onChangeText={onChange}
          placeholder={placeholder}
          placeholderTextColor={colors.textMuted}
          keyboardType="decimal-pad"
        />
        {suffix ? <Text style={styles.inputAdornment}>{suffix}</Text> : null}
      </View>
    </View>
  );
}

function BreakdownRow({ label, value, bold }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.breakdownRow}>
      <Text style={[styles.breakdownLabel, bold && { fontWeight: "700", color: colors.textPrimary }]}>
        {label}
      </Text>
      <Text style={[styles.breakdownValue, bold && { fontWeight: "700", fontSize: fontSize.md }]}>
        {formatQuote(value)}
      </Text>
    </View>
  );
}

function createStyles(colors, shadow) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  tabs: {
    flexDirection: "row",
    padding: spacing.sm,
    gap: spacing.sm,
    backgroundColor: colors.surface,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  tab: {
    flex: 1, paddingVertical: 8, borderRadius: radius.md,
    alignItems: "center", backgroundColor: colors.background,
  },
  tabActive: { backgroundColor: colors.accent },
  tabText: { fontSize: fontSize.sm, color: colors.textSecondary, fontWeight: "500" },
  tabTextActive: { color: colors.textOnAccent, fontWeight: "600" },
  scroll: { padding: spacing.md, paddingBottom: 60 },

  priceCard: {
    alignItems: "center", paddingVertical: spacing.lg, marginBottom: spacing.sm,
    backgroundColor: colors.accent,
  },
  priceLabel: { fontSize: fontSize.sm, color: "rgba(255,255,255,0.8)", marginBottom: 4 },
  priceMain: { fontSize: 40, fontWeight: "700", color: colors.textOnAccent },
  priceRange: { fontSize: fontSize.sm, color: "rgba(255,255,255,0.9)", marginTop: 4 },
  breakEven: { fontSize: fontSize.xs, color: "rgba(255,255,255,0.7)", marginTop: 2 },

  warningBox: {
    backgroundColor: colors.warningBg,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.sm,
    borderLeftWidth: 3,
    borderLeftColor: colors.warning,
  },
  warningText: { fontSize: fontSize.sm, color: colors.warning },

  sectionLabel: {
    fontSize: fontSize.xs, fontWeight: "600", color: colors.textSecondary,
    textTransform: "uppercase", letterSpacing: 0.6,
    marginTop: spacing.md, marginBottom: spacing.sm,
  },

  inputRow: { flexDirection: "row", gap: spacing.sm, alignItems: "flex-end" },
  smallInputWrap: { flex: 1 },
  smallLabel: { fontSize: fontSize.xs, color: colors.textSecondary, marginBottom: 4 },
  smallInputRow: { flexDirection: "row", alignItems: "center" },
  smallInput: {
    flex: 1, height: 36, backgroundColor: colors.background,
    borderRadius: radius.sm, paddingHorizontal: spacing.sm,
    fontSize: fontSize.sm, color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
  },
  inputAdornment: { fontSize: fontSize.sm, color: colors.textMuted, paddingHorizontal: 4 },

  calcResult: { flex: 1, alignItems: "flex-end" },
  calcResultLabel: { fontSize: fontSize.xs, color: colors.textMuted },
  calcResultValue: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },

  toggleLabel: { flex: 1, fontSize: fontSize.sm, color: colors.textPrimary },

  materialRow: { flexDirection: "row", gap: 6, marginBottom: 6, alignItems: "center" },
  matInput: {
    flex: 1, height: 36, backgroundColor: colors.background,
    borderRadius: radius.sm, paddingHorizontal: spacing.sm,
    fontSize: fontSize.sm, color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
  },
  removeBtn: { padding: 6 },
  removeBtnText: { color: colors.danger, fontSize: fontSize.md },
  addMaterialBtn: {
    paddingVertical: spacing.sm, alignItems: "center",
    borderRadius: radius.md, borderWidth: 1,
    borderColor: colors.border, borderStyle: "dashed", marginTop: 4,
  },
  addMaterialText: { fontSize: fontSize.sm, color: colors.accent },
  emptyMaterials: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.sm },

  breakdownRow: {
    flexDirection: "row", justifyContent: "space-between",
    alignItems: "center", marginBottom: 6,
  },
  breakdownLabel: { fontSize: fontSize.sm, color: colors.textSecondary, flex: 1 },
  breakdownValue: { fontSize: fontSize.sm, color: colors.textPrimary, fontWeight: "500" },
  effectiveRate: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: spacing.xs, textAlign: "right" },

  actions: { flexDirection: "row", marginTop: spacing.lg },

  estimateHeader: {
    alignItems: "center", paddingVertical: spacing.md,
    marginBottom: spacing.sm, backgroundColor: colors.successBg,
  },
  estimateHeaderLabel: { fontSize: fontSize.sm, color: colors.success },
  estimateHeaderTotal: { fontSize: fontSize.xl, fontWeight: "700", color: colors.success },
  estimateBody: { marginBottom: spacing.sm, minHeight: 200 },
  generatingRow: { flexDirection: "row", alignItems: "center", padding: spacing.md },
  generatingText: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
  estimateText: { fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },
  estimateActions: { flexDirection: "row", marginBottom: spacing.sm },
  estimateNote: {
    fontSize: fontSize.xs, color: colors.textMuted,
    textAlign: "center", marginTop: spacing.md, lineHeight: 18,
  },
  });
}
