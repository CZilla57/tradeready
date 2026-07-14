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
import { loadJobs, saveJobs, loadCustomers, loadSettings, loadPricebook, savePricebook } from "../utils/storage";
import { Button, Card, Divider } from "../components/UI";
import { PricebookPickerModal } from "../components/PricebookPickerModal";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Job, Customer, Settings, PricebookEntry } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

interface LocalMaterial {
  id: string;
  name: string;
  quantity: number;
  unitCost: number;
}

export default function PricingCalculatorScreen({ route, navigation }: JobStackScreenProps<'PricingCalculator'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params || {};

  const [job, setJob] = useState<Job | null>(null);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [settings, setSettings] = useState<Settings | null>(null);

  const [laborHours, setLaborHours] = useState("2");
  const [laborRate, setLaborRate] = useState("85");
  const [materials, setMaterials] = useState<LocalMaterial[]>([]);
  const [materialMarkup, setMaterialMarkup] = useState("20");
  const [overheadPercent, setOverheadPercent] = useState("15");
  const [marginPercent, setMarginPercent] = useState("20");
  const [travelMiles, setTravelMiles] = useState("0");
  const [isEmergency, setIsEmergency] = useState(false);
  const [taxPercent, setTaxPercent] = useState("0");

  const [tab, setTab] = useState<"calculator" | "estimate">("calculator");
  const [generatedEstimate, setGeneratedEstimate] = useState("");
  const [generating, setGenerating] = useState(false);
  const [saving, setSaving] = useState(false);
  const [copied, setCopied] = useState(false);
  const [pickerVisible, setPickerVisible] = useState(false);

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
        setMaterials((j.materials as LocalMaterial[]) || []);
        setMaterialMarkup(String(j.materialMarkup ?? s.materialMarkup ?? 20));
        setOverheadPercent(String(j.overhead ?? s.overheadPercent ?? 15));
        setMarginPercent(String(j.margin ?? s.marginPercent ?? 20));
        const c = customers.find((x) => x.id === j.customerId);
        setCustomer(c || null);
      }
      setSettings(s);
      if (s && !j) {
        setLaborRate(String(s.laborRate || 85));
        setMaterialMarkup(String(s.materialMarkup ?? 20));
        setOverheadPercent(String(s.overheadPercent ?? 15));
        setMarginPercent(String(s.marginPercent ?? 20));
      }
    }
    load();
  }, [jobId]);

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
  const hasExistingData = parseFloat(laborHours) > 0 || materials.length > 0;

  function addMaterial() {
    setMaterials((prev) => [
      ...prev,
      { id: `m${Date.now()}`, name: "", quantity: 1, unitCost: 0 },
    ]);
  }

  function updateMaterial(id: string, field: keyof LocalMaterial, value: string | number) {
    setMaterials((prev) =>
      prev.map((m) => (m.id === id ? { ...m, [field]: value } : m))
    );
  }

  function removeMaterial(id: string) {
    setMaterials((prev) => prev.filter((m) => m.id !== id));
  }

  function handlePricebookSelect(entry: PricebookEntry, mode: "replace" | "add") {
    if (mode === "replace") {
      setLaborHours(String(entry.laborHours));
      setLaborRate(String(entry.laborRate));
      setMaterials(entry.materials as LocalMaterial[]);
      setMaterialMarkup(String(entry.materialMarkup));
      setOverheadPercent(String(entry.overhead));
      setMarginPercent(String(entry.margin));
    } else {
      setLaborHours(String((parseFloat(laborHours) || 0) + entry.laborHours));
      setMaterials((prev) => [...prev, ...(entry.materials as LocalMaterial[])]);
      setMaterialMarkup(String(Math.max(parseFloat(materialMarkup) || 0, entry.materialMarkup)));
      setOverheadPercent(String(Math.max(parseFloat(overheadPercent) || 0, entry.overhead)));
      setMarginPercent(String(Math.max(parseFloat(marginPercent) || 0, entry.margin)));
    }
    setPickerVisible(false);
  }

  async function savePricebookEntry(name: string) {
    const entries = await loadPricebook();
    const now = new Date().toISOString();
    const entry: PricebookEntry = {
      id: `pb-${Date.now()}`,
      name,
      laborHours: params.laborHours,
      laborRate: params.laborRate,
      materials: materials.map((m) => ({
        id: m.id,
        name: m.name,
        quantity: m.quantity,
        unitCost: m.unitCost,
      })),
      materialMarkup: params.materialMarkup,
      overhead: params.overheadPercent,
      margin: params.marginPercent,
      estimateTotal: breakdown.total,
      createdAt: now,
      updatedAt: now,
    };
    await savePricebook([...entries, entry]);
    Alert.alert("Saved", `"${name}" added to your Pricebook.`);
  }

  function handleSaveToPricebook() {
    const defaultName = job?.title?.trim() || "Untitled Service";
    if (Platform.OS === "ios" && Alert.prompt) {
      Alert.prompt(
        "Save to Pricebook",
        "Name this service:",
        (serviceName) => {
          const name = serviceName?.trim();
          if (name) savePricebookEntry(name);
        },
        "plain-text",
        defaultName,
      );
    } else {
      Alert.alert(
        "Save to Pricebook",
        `Save "${defaultName}" as a Pricebook service? You can rename it later from the Pricebook tab.`,
        [
          { text: "Cancel", style: "cancel" },
          { text: "Save", onPress: () => savePricebookEntry(defaultName) },
        ],
      );
    }
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
    if (!customer || !customer.email) {
      Alert.alert("No email", "No customer email on file.");
      return;
    }
    const sent = await composeEmail({
      recipients: [customer.email],
      subject: `Estimate: ${job?.title || "Your job"} — ${formatQuote(breakdown.total)}`,
      body: generatedEstimate,
    });
    if (!sent) return;

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
      <View style={styles.tabs}>
        <TouchableOpacity
          style={[styles.tab, tab === "calculator" && styles.tabActive]}
          onPress={() => setTab("calculator")}
          accessibilityRole="tab"
          accessibilityLabel="Calculator"
          accessibilityState={{ selected: tab === "calculator" }}
        >
          <Text style={[styles.tabText, tab === "calculator" && styles.tabTextActive]}>
            🧮 Calculator
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tab, tab === "estimate" && styles.tabActive]}
          onPress={() => { setTab("estimate"); if (!generatedEstimate) generateEstimate(); }}
          accessibilityRole="tab"
          accessibilityLabel="Estimate"
          accessibilityState={{ selected: tab === "estimate" }}
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
            onLoadFromPricebook={() => setPickerVisible(true)}
            onSaveToPricebook={handleSaveToPricebook}
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

      <PricebookPickerModal
        visible={pickerVisible}
        hasExistingData={hasExistingData}
        onSelect={handlePricebookSelect}
        onDismiss={() => setPickerVisible(false)}
      />
    </SafeAreaView>
  );
}

// ── Calculator Tab ─────────────────────────────────────────────────────────────

interface CalculatorTabProps {
  laborHours: string; setLaborHours: (v: string) => void;
  laborRate: string; setLaborRate: (v: string) => void;
  materials: LocalMaterial[];
  materialMarkup: string; setMaterialMarkup: (v: string) => void;
  overheadPercent: string; setOverheadPercent: (v: string) => void;
  marginPercent: string; setMarginPercent: (v: string) => void;
  travelMiles: string; setTravelMiles: (v: string) => void;
  taxPercent: string; setTaxPercent: (v: string) => void;
  isEmergency: boolean; setIsEmergency: (v: boolean) => void;
  addMaterial: () => void;
  updateMaterial: (id: string, field: keyof LocalMaterial, value: string | number) => void;
  removeMaterial: (id: string) => void;
  breakdown: any;
  range: any;
  breakEven: number;
  warnings: string[];
  onSave: () => void;
  saving: boolean;
  onGenerateEstimate: () => void;
  onLoadFromPricebook: () => void;
  onSaveToPricebook: () => void;
}

function CalculatorTab({
  laborHours, setLaborHours, laborRate, setLaborRate,
  materials, materialMarkup, setMaterialMarkup,
  overheadPercent, setOverheadPercent, marginPercent, setMarginPercent,
  travelMiles, setTravelMiles, taxPercent, setTaxPercent,
  isEmergency, setIsEmergency,
  addMaterial, updateMaterial, removeMaterial,
  breakdown, range, breakEven, warnings,
  onSave, saving, onGenerateEstimate,
  onLoadFromPricebook, onSaveToPricebook,
}: CalculatorTabProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
      <View style={{ flexDirection: "row", marginBottom: spacing.md, gap: spacing.sm }}>
        <Button label="📋 Load from Pricebook" variant="secondary" onPress={onLoadFromPricebook} style={{ flex: 1 }} />
        {breakdown.total > 0 && (
          <Button label="💾 Save to Pricebook" variant="ghost" onPress={onSaveToPricebook} style={{ flex: 1 }} />
        )}
      </View>

      <Card style={styles.priceCard}>
        <Text style={styles.priceLabel}>Recommended price</Text>
        <Text style={styles.priceMain}>{formatQuote(range.recommended)}</Text>
        <Text style={styles.priceRange}>
          Range: {formatQuote(range.low)} – {formatQuote(range.high)}
        </Text>
        <Text style={styles.breakEven}>Break-even: {formatQuote(breakEven)}</Text>
      </Card>

      {warnings.map((w, i) => (
        <View key={i} style={styles.warningBox}>
          <Text style={styles.warningText}>⚠️ {w}</Text>
        </View>
      ))}

      <SectionLabel>Labor</SectionLabel>
      <Card>
        <View style={styles.inputRow}>
          <SmallInput label="Hours" value={laborHours} onChange={setLaborHours} placeholder="2" suffix="hrs" />
          <SmallInput label="Rate" value={laborRate} onChange={setLaborRate} placeholder="85" prefix="$" suffix="/hr" />
          <View style={styles.calcResult}>
            <Text style={styles.calcResultLabel}>Labor total</Text>
            <Text style={styles.calcResultValue}>{formatQuote(breakdown.laborCost)}</Text>
          </View>
        </View>
        <View style={[styles.inputRow, { marginTop: spacing.sm, alignItems: "center" }]}>
          <Text style={styles.toggleLabel}>Emergency / after-hours rate</Text>
          <Switch value={isEmergency} onValueChange={setIsEmergency} trackColor={{ true: colors.warning }} accessibilityLabel="Emergency or after-hours rate" />
        </View>
      </Card>

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
              accessibilityLabel="Material name"
            />
            <TextInput
              style={styles.matInput}
              placeholder="Qty"
              placeholderTextColor={colors.textMuted}
              value={String(m.quantity)}
              onChangeText={(v) => updateMaterial(m.id, "quantity", parseFloat(v) || 0)}
              keyboardType="decimal-pad"
              accessibilityLabel="Material quantity"
            />
            <TextInput
              style={styles.matInput}
              placeholder="$ each"
              placeholderTextColor={colors.textMuted}
              value={String(m.unitCost)}
              onChangeText={(v) => updateMaterial(m.id, "unitCost", parseFloat(v) || 0)}
              keyboardType="decimal-pad"
              accessibilityLabel="Material cost each"
            />
            <TouchableOpacity
              onPress={() => removeMaterial(m.id)}
              style={styles.removeBtn}
              accessibilityRole="button"
              accessibilityLabel={`Remove material ${m.name || "item"}`}
            >
              <Text style={styles.removeBtnText}>✕</Text>
            </TouchableOpacity>
          </View>
        ))}
        <TouchableOpacity style={styles.addMaterialBtn} onPress={addMaterial} accessibilityRole="button" accessibilityLabel="Add material">
          <Text style={styles.addMaterialText}>+ Add material</Text>
        </TouchableOpacity>
        <View style={[styles.inputRow, { marginTop: spacing.sm }]}>
          <SmallInput label="Markup %" value={materialMarkup} onChange={setMaterialMarkup} placeholder="20" suffix="%" />
          <View style={styles.calcResult}>
            <Text style={styles.calcResultLabel}>Materials total</Text>
            <Text style={styles.calcResultValue}>{formatQuote(breakdown.materialCost)}</Text>
          </View>
        </View>
      </Card>

      <SectionLabel>Business costs</SectionLabel>
      <Card>
        <View style={styles.inputRow}>
          <SmallInput label="Overhead %" value={overheadPercent} onChange={setOverheadPercent} placeholder="15" suffix="%" />
          <SmallInput label="Profit margin %" value={marginPercent} onChange={setMarginPercent} placeholder="20" suffix="%" />
          <SmallInput label="Travel miles" value={travelMiles} onChange={setTravelMiles} placeholder="0" suffix="mi" />
        </View>
        <SmallInput label="Tax %" value={taxPercent} onChange={setTaxPercent} placeholder="0" suffix="%" />
      </Card>

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

      <View style={styles.actions}>
        <Button label={saving ? "Saving..." : "Save pricing"} variant="ghost" onPress={onSave} loading={saving} style={{ flex: 1 }} />
        <View style={{ width: spacing.sm }} />
        <Button label="Generate estimate →" onPress={onGenerateEstimate} style={{ flex: 2 }} />
      </View>
    </ScrollView>
  );
}

// ── Estimate Tab ───────────────────────────────────────────────────────────────

interface EstimateTabProps {
  generating: boolean;
  generatedEstimate: string;
  onRegenerate: () => void;
  onCopy: () => void;
  onEmail: () => void;
  copied: boolean;
  total: number;
}

function EstimateTab({ generating, generatedEstimate, onRegenerate, onCopy, onEmail, copied, total }: EstimateTabProps) {
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
        <Button label="✉ Email to customer →" onPress={onEmail} style={{ marginTop: spacing.sm }} />
      ) : null}

      <Text style={styles.estimateNote}>
        Sending this email will mark the job as "Estimate sent" and start the approval clock.
      </Text>
    </ScrollView>
  );
}

// ── Small reusable pieces ──────────────────────────────────────────────────────

function SectionLabel({ children }: { children: React.ReactNode }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return <Text style={styles.sectionLabel}>{children}</Text>;
}

interface SmallInputProps {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder: string;
  prefix?: string;
  suffix?: string;
}

function SmallInput({ label, value, onChange, placeholder, prefix, suffix }: SmallInputProps) {
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
          accessibilityLabel={label}
        />
        {suffix ? <Text style={styles.inputAdornment}>{suffix}</Text> : null}
      </View>
    </View>
  );
}

function BreakdownRow({ label, value, bold }: { label: string; value: number; bold?: boolean }) {
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

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    tabs: {
      flexDirection: "row", padding: spacing.sm, gap: spacing.sm,
      backgroundColor: colors.surface,
      borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border,
    },
    tab: { flex: 1, paddingVertical: 8, borderRadius: radius.md, alignItems: "center", backgroundColor: colors.background },
    tabActive: { backgroundColor: colors.accent },
    tabText: { fontSize: fontSize.sm, color: colors.textSecondary, fontWeight: "500" },
    tabTextActive: { color: colors.textOnAccent, fontWeight: "600" },
    scroll: { padding: spacing.md, paddingBottom: 60 },
    priceCard: { alignItems: "center", paddingVertical: spacing.lg, marginBottom: spacing.sm, backgroundColor: colors.accent },
    priceLabel: { fontSize: fontSize.sm, color: "rgba(255,255,255,0.8)", marginBottom: 4 },
    priceMain: { fontSize: 40, fontWeight: "700", color: colors.textOnAccent },
    priceRange: { fontSize: fontSize.sm, color: "rgba(255,255,255,0.9)", marginTop: 4 },
    breakEven: { fontSize: fontSize.xs, color: "rgba(255,255,255,0.7)", marginTop: 2 },
    warningBox: {
      backgroundColor: colors.warningBg, borderRadius: radius.md, padding: spacing.sm,
      marginBottom: spacing.sm, borderLeftWidth: 3, borderLeftColor: colors.warning,
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
      flex: 1, height: 44, backgroundColor: colors.background, borderRadius: radius.sm,
      paddingHorizontal: spacing.sm, fontSize: fontSize.sm, color: colors.textPrimary,
      borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
    },
    inputAdornment: { fontSize: fontSize.sm, color: colors.textMuted, paddingHorizontal: 4 },
    calcResult: { flex: 1, alignItems: "flex-end" },
    calcResultLabel: { fontSize: fontSize.xs, color: colors.textMuted },
    calcResultValue: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    toggleLabel: { flex: 1, fontSize: fontSize.sm, color: colors.textPrimary },
    materialRow: { flexDirection: "row", gap: 6, marginBottom: 6, alignItems: "center" },
    matInput: {
      flex: 1, height: 44, backgroundColor: colors.background, borderRadius: radius.sm,
      paddingHorizontal: spacing.sm, fontSize: fontSize.sm, color: colors.textPrimary,
      borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
    },
    removeBtn: {
      padding: 6,
      minHeight: 44,
      minWidth: 44,
      justifyContent: "center",
      alignItems: "center",
    },
    removeBtnText: { color: colors.danger, fontSize: fontSize.md },
    addMaterialBtn: {
      paddingVertical: spacing.sm, alignItems: "center", borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", marginTop: 4,
    },
    addMaterialText: { fontSize: fontSize.sm, color: colors.accent },
    emptyMaterials: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.sm },
    breakdownRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginBottom: 6 },
    breakdownLabel: { fontSize: fontSize.sm, color: colors.textSecondary, flex: 1 },
    breakdownValue: { fontSize: fontSize.sm, color: colors.textPrimary, fontWeight: "500" },
    effectiveRate: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: spacing.xs, textAlign: "right" },
    actions: { flexDirection: "row", marginTop: spacing.lg },
    estimateHeader: { alignItems: "center", paddingVertical: spacing.md, marginBottom: spacing.sm, backgroundColor: colors.successBg },
    estimateHeaderLabel: { fontSize: fontSize.sm, color: colors.success },
    estimateHeaderTotal: { fontSize: fontSize.xl, fontWeight: "700", color: colors.success },
    estimateBody: { marginBottom: spacing.sm, minHeight: 200 },
    generatingRow: { flexDirection: "row", alignItems: "center", padding: spacing.md },
    generatingText: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    estimateText: { fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },
    estimateActions: { flexDirection: "row", marginBottom: spacing.sm },
    estimateNote: { fontSize: fontSize.xs, color: colors.textMuted, textAlign: "center", marginTop: spacing.md, lineHeight: 18 },
  });
}
