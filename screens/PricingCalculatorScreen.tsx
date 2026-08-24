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
import { Ionicons } from "@expo/vector-icons";
import * as Clipboard from "expo-clipboard";
import { composeEmail } from "../utils/messaging";
import { emailHtmlFromText } from "../utils/emailHtml";
import {
  calculatePriceRange,
  getSanityWarnings,
  breakEvenPrice,
  buildEstimateInput,
  getTimeAndTripWarnings,
  JOB_STATUSES,
} from "../utils/pricingEngine";
import { track } from "../utils/analytics";
import { formatQuote } from "../utils/format";
import { generateOneShot } from "../utils/oneShotAI";
import {
  buildEstimateDocument,
  buildScopePrompt,
  sanitizeScope,
  cannedScope,
} from "../utils/estimateDocument";
import { loadJobs, saveJobs, loadCustomers, loadSettings, loadPricebook, savePricebook, resolveCustomer, loadInvoices, loadExpenses } from "../utils/storage";
import { computeProfitabilityHistory, getHistoryWarnings, type ProfitabilityHistory } from "../utils/profitabilityAggregate";
import { createApprovalLink } from "../utils/estimateApprovalLink";
import { stampEstimateSent } from "../utils/estimateFollowUps";
import { Button, Card, Divider } from "../components/UI";
import { KeyboardDoneBar } from "../components/KeyboardDoneBar";
import { PricebookPickerModal } from "../components/PricebookPickerModal";
import { JobCostsEditor } from "../components/JobCostsEditor";
import { LaborHoursEditor } from "../components/LaborHoursEditor";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Job, Customer, Settings, PricebookEntry, JobCost, LaborTimeBreakdown, Material } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

// One Done bar serves every decimal-pad input on the calculator tab
// (SmallInput and the material rows reference this ID).
const CALC_DONE_ID = "pricingCalcDone";

interface LocalMaterial {
  id: string;
  name: string;
  // number|string so the inputs can hold a partial decimal ("8." → "8.50")
  // while typing — parsed to numbers only when persisted (toNumericMaterials).
  // Matches the Pricebook entry screen's material handling.
  quantity: number | string;
  unitCost: number | string;
}

function toNumericMaterials(mats: LocalMaterial[]): Material[] {
  return mats.map((m) => ({
    id: m.id,
    name: m.name,
    quantity: parseFloat(String(m.quantity)) || 0,
    unitCost: parseFloat(String(m.unitCost)) || 0,
  }));
}

export default function PricingCalculatorScreen({ route, navigation }: JobStackScreenProps<'PricingCalculator'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params || {};

  const [job, setJob] = useState<Job | null>(null);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [settings, setSettings] = useState<Settings | null>(null);

  const [laborHours, setLaborHours] = useState("2");
  const [laborBreakdown, setLaborBreakdown] = useState<LaborTimeBreakdown | undefined>(undefined);
  const [laborRate, setLaborRate] = useState("85");
  const [materials, setMaterials] = useState<LocalMaterial[]>([]);
  const [jobCosts, setJobCosts] = useState<JobCost[]>([]);
  const [materialMarkup, setMaterialMarkup] = useState("20");
  const [overheadPercent, setOverheadPercent] = useState("15");
  const [marginPercent, setMarginPercent] = useState("20");
  const [travelMiles, setTravelMiles] = useState("0");
  const [isEmergency, setIsEmergency] = useState(false);
  const [taxPercent, setTaxPercent] = useState("0");

  const [tab, setTab] = useState<"calculator" | "estimate">("calculator");
  const [linking, setLinking] = useState(false);
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
        setLaborBreakdown(j.laborBreakdown);
        setLaborRate(String(j.laborRate || s.laborRate || 85));
        setMaterials((j.materials as LocalMaterial[]) || []);
        setJobCosts((j.jobCosts as JobCost[]) || []);
        setMaterialMarkup(String(j.materialMarkup ?? s.materialMarkup ?? 20));
        setOverheadPercent(String(j.overhead ?? s.overheadPercent ?? 15));
        setMarginPercent(String(j.margin ?? s.marginPercent ?? 20));
        // Name-join fallback keeps the email/phone on file reachable when the
        // id link dangles (e.g. recurring-rule jobs after a sample-id remap).
        setCustomer(resolveCustomer(customers, j));
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

  // Trailing-history "reality check" (Phase 13D): best-effort context — the
  // calculator works identically without it, and getHistoryWarnings stays
  // silent until >= 3 completed jobs carry real tracked data per metric.
  const [history, setHistory] = useState<ProfitabilityHistory | null>(null);
  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const [jobs, invoices, expenses, s] = await Promise.all([
          loadJobs(), loadInvoices(), loadExpenses(), loadSettings(),
        ]);
        if (active) {
          setHistory(computeProfitabilityHistory(jobs, invoices, expenses, s, new Date()));
        }
      } catch {
        // History is optional context; the calculator renders without it.
      }
    })();
    return () => { active = false; };
  }, []);

  const params = buildEstimateInput(
    { laborHours, laborRate, materials, materialMarkup, jobCosts, overheadPercent, marginPercent, travelMiles, isEmergency, taxPercent },
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
  const tripWarnings = getTimeAndTripWarnings({
    driveHours: laborBreakdown?.driveHours ?? 0,
    travelMiles: parseFloat(travelMiles) || 0,
    jobCosts,
  });
  const historyWarnings = history
    ? getHistoryWarnings(history, {
        effectiveHourlyRate: breakdown.effectiveHourlyRate,
        materialBaseCost: breakdown.materialBaseCost,
        subtotal: breakdown.subtotal,
        overheadCost: breakdown.overheadCost,
        profit: breakdown.profit,
        marginPercent: params.marginPercent ?? 20,
      })
    : [];
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
      setLaborBreakdown(entry.laborBreakdown);
      setMaterials(entry.materials as LocalMaterial[]);
      setJobCosts((entry.jobCosts as JobCost[]) || []);
      setMaterialMarkup(String(entry.materialMarkup));
      setOverheadPercent(String(entry.overhead));
      setMarginPercent(String(entry.margin));
    } else {
      setLaborHours(String((parseFloat(laborHours) || 0) + entry.laborHours));
      // Summed hours can't carry a per-component split — fall back to single total.
      setLaborBreakdown(undefined);
      setMaterials((prev) => [...prev, ...(entry.materials as LocalMaterial[])]);
      setJobCosts((prev) => [...prev, ...((entry.jobCosts as JobCost[]) || [])]);
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
      ...(laborBreakdown ? { laborBreakdown } : {}),
      laborRate: params.laborRate,
      materials: toNumericMaterials(materials),
      materialMarkup: params.materialMarkup,
      ...(jobCosts.length > 0 ? { jobCosts } : {}),
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
            laborBreakdown,
            laborRate: params.laborRate,
            materials: toNumericMaterials(materials),
            materialMarkup: params.materialMarkup,
            jobCosts,
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

    // The document is assembled deterministically — every number comes from
    // the pricing engine (letting the model write the whole thing produced
    // wrong math and cheap formatting; beta finding 2026-07-14). AI writes
    // only the scope paragraph, and a canned one keeps the document complete
    // when AI is unavailable.
    const fallbackScope = cannedScope({ jobTitle: job.title, description: job.description });
    const aiScope = await generateOneShot({
      prompt: buildScopePrompt({ jobTitle: job.title, description: job.description, trade: settings.trade }),
      apiKey: settings?.anthropicKey,
      max_tokens: 200,
      fallback: () => "",
    });

    setGeneratedEstimate(
      buildEstimateDocument({
        businessName: settings.businessName,
        contactName: settings.contactName,
        phone: settings.phone,
        email: settings.email,
        customerName: customer?.name || job.customerName,
        customerAddress: customer?.address || job.address,
        jobTitle: job.title,
        laborHours: params.laborHours,
        laborRate: params.laborRate,
        materialsCount: materials.length,
        breakdown,
        scope: sanitizeScope(aiScope, fallbackScope),
      })
    );
    setGenerating(false);
  }

  // Advances a lead to the pipeline's next stage (estimate_sent) — shared by
  // the email path and the explicit no-email "Mark estimate as sent" button.
  async function markEstimateSent() {
    if (!job || job.status !== "lead") return;
    const next = JOB_STATUSES.lead.next;
    if (!next) return;
    const now = new Date();
    // Stamping estimateSentAt only when the transition actually lands in
    // estimate_sent keeps this in step with the follow-up nudge's other three
    // send sites (see stampEstimateSent's docstring in utils/estimateFollowUps).
    const advance = (j: Job): Job =>
      next === "estimate_sent"
        ? { ...stampEstimateSent(j, now), estimateTotal: breakdown.total }
        : { ...j, status: next, estimateTotal: breakdown.total };
    const jobs = await loadJobs();
    await saveJobs(jobs.map((j) => (j.id === jobId ? advance(j) : j)));
    setJob(advance(job));
    track("estimate_sent");
  }

  // Persist what's currently on the calculator onto the job. The approval
  // snapshot is built from the JOB, not from this screen's state, so minting a
  // link before saving would show the customer a stale (often zero) estimate.
  async function persistPricingToJob(): Promise<Job | null> {
    if (!job || !jobId) return null;
    const updated: Job = {
      ...job,
      laborHours: params.laborHours,
      laborBreakdown,
      laborRate: params.laborRate,
      materials: toNumericMaterials(materials),
      materialMarkup: params.materialMarkup,
      jobCosts,
      overhead: params.overheadPercent,
      margin: params.marginPercent,
      estimateTotal: breakdown.total,
    };
    const jobs = await loadJobs();
    await saveJobs(jobs.map((j) => (j.id === jobId ? updated : j)));
    setJob(updated);
    return updated;
  }

  async function sendEstimateByEmail() {
    if (!customer || !customer.email) {
      Alert.alert(
        "No email",
        'No customer email on file. Add one on the customer record, or use "Mark estimate as sent" below.'
      );
      return;
    }

    // Attach a customer approval link so the estimate can be approved or
    // declined online. Best-effort: minting needs a session, the network, and
    // the job synced to Supabase, none of which are guaranteed — so a failure
    // offers to send the plain estimate rather than blocking the send outright.
    let body = generatedEstimate;
    const saved = await persistPricingToJob();
    if (saved && settings) {
      setLinking(true);
      const result = await createApprovalLink(saved, customer, settings);
      setLinking(false);
      if (result.ok) {
        body = `${generatedEstimate}\n\nView and approve your estimate here:\n${result.url}`;
      } else {
        const proceed = await new Promise<boolean>((resolve) =>
          Alert.alert(
            "Couldn't create approval link",
            `${result.message}\n\nSend the estimate without an approval link?`,
            [
              { text: "Cancel", style: "cancel", onPress: () => resolve(false) },
              { text: "Send anyway", onPress: () => resolve(true) },
            ]
          )
        );
        if (!proceed) return;
      }
    }

    const sent = await composeEmail({
      recipients: [customer.email],
      subject: `Estimate: ${job?.title || "Your job"} — ${formatQuote(breakdown.total)}`,
      // Escaped + linkified at send time: the approval URL renders as a
      // labeled anchor instead of a raw token string (utils/emailHtml).
      body: emailHtmlFromText(body),
      isHtml: true,
    });
    if (!sent) return;
    await markEstimateSent();
  }

  async function copyEstimate() {
    await Clipboard.setStringAsync(generatedEstimate);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <View style={styles.container}>
      <View style={styles.tabs}>
        <TouchableOpacity
          style={[styles.tab, tab === "calculator" && styles.tabActive]}
          onPress={() => setTab("calculator")}
          accessibilityRole="tab"
          accessibilityLabel="Calculator"
          accessibilityState={{ selected: tab === "calculator" }}
        >
          <Ionicons
            name="calculator-outline"
            size={14}
            color={tab === "calculator" ? colors.textOnAccent : colors.textSecondary}
          />
          <Text style={[styles.tabText, tab === "calculator" && styles.tabTextActive]}>
            Calculator
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tab, tab === "estimate" && styles.tabActive]}
          onPress={() => { setTab("estimate"); if (!generatedEstimate) generateEstimate(); }}
          accessibilityRole="tab"
          accessibilityLabel="Estimate"
          accessibilityState={{ selected: tab === "estimate" }}
        >
          <Ionicons
            name="document-text-outline"
            size={14}
            color={tab === "estimate" ? colors.textOnAccent : colors.textSecondary}
          />
          <Text style={[styles.tabText, tab === "estimate" && styles.tabTextActive]}>
            Estimate
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
            laborBreakdown={laborBreakdown} setLaborBreakdown={setLaborBreakdown}
            laborRate={laborRate} setLaborRate={setLaborRate}
            materials={materials}
            jobCosts={jobCosts}
            setJobCosts={setJobCosts}
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
            warnings={[...warnings, ...tripWarnings, ...historyWarnings]}
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
            linking={linking}
            onMarkSent={async () => {
              await markEstimateSent();
              Alert.alert("Marked as sent", 'The job moved to "Estimate sent".');
            }}
            canMarkSent={!!job && job.status === "lead"}
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
      <KeyboardDoneBar nativeID={CALC_DONE_ID} />
    </View>
  );
}

// ── Calculator Tab ─────────────────────────────────────────────────────────────

interface CalculatorTabProps {
  laborHours: string; setLaborHours: (v: string) => void;
  laborBreakdown: LaborTimeBreakdown | undefined; setLaborBreakdown: (v: LaborTimeBreakdown | undefined) => void;
  laborRate: string; setLaborRate: (v: string) => void;
  materials: LocalMaterial[];
  jobCosts: JobCost[];
  setJobCosts: (v: JobCost[]) => void;
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
  laborHours, setLaborHours, laborBreakdown, setLaborBreakdown, laborRate, setLaborRate,
  materials, materialMarkup, setMaterialMarkup,
  jobCosts, setJobCosts,
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
  const [helpOpen, setHelpOpen] = useState(false);
  return (
    <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
      <View style={{ flexDirection: "row", marginBottom: spacing.md, gap: spacing.sm }}>
        <Button label="Load from Pricebook" variant="secondary" onPress={onLoadFromPricebook} style={{ flex: 1 }} />
        {breakdown.total > 0 && (
          <Button label="Save to Pricebook" variant="ghost" onPress={onSaveToPricebook} style={{ flex: 1 }} />
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
          <Text style={styles.warningText}>⚠ {w}</Text>
        </View>
      ))}

      <Card style={{ marginBottom: spacing.sm }}>
        <TouchableOpacity
          style={styles.helpHeader}
          onPress={() => setHelpOpen((v) => !v)}
          accessibilityRole="button"
          accessibilityLabel={helpOpen ? "Hide how this price works" : "Show how this price works"}
        >
          <Text style={styles.helpTitle}>Understanding your price</Text>
          <Ionicons name={helpOpen ? "chevron-up" : "chevron-down"} size={18} color={colors.textSecondary} />
        </TouchableOpacity>
        {helpOpen && (
          <View style={{ marginTop: spacing.xs }}>
            <HelpItem text="Rate is your billing rate, not your take-home pay — set it high enough to cover slow days, tools, and time off." styles={styles} />
            <HelpItem text="Markup covers the hassle of sourcing materials. Margin is your profit as a share of the final price — they're different, and you can use both." styles={styles} />
            <HelpItem text="Overhead is the share of your insurance, vehicle, and tools this job should carry, entered as a percent of the job." styles={styles} />
            <HelpItem text="Recommended is your target price. Break-even is the floor that covers costs with zero profit — quoting below it loses money." styles={styles} />
            <HelpItem text="Minimum job fee is charged when a job prices below it — it covers turning up for small work." styles={styles} />
            <HelpItem text="Emergency / after-hours raises your labor rate by your multiplier for nights, weekends, and urgent calls." styles={styles} />
            <HelpItem text="Direct costs (permits, disposal, rental, subcontractors) can be billed at cost or marked up. Permits are usually billed at cost." styles={styles} />
            <Text style={styles.helpNote}>These are tools to price with intention — they don&apos;t guarantee a profit.</Text>
          </View>
        )}
      </Card>

      <SectionLabel>Labor</SectionLabel>
      <Card>
        <LaborHoursEditor
          value={{ hours: laborHours, breakdown: laborBreakdown }}
          onChange={(v) => { setLaborHours(v.hours); setLaborBreakdown(v.breakdown); }}
          doneBarId={CALC_DONE_ID}
        />
        <View style={[styles.inputRow, { marginTop: spacing.sm }]}>
          <SmallInput label="Rate" value={laborRate} onChange={setLaborRate} placeholder="85" prefix="$" suffix="/hr" />
          <View style={styles.calcResult}>
            <Text style={styles.calcResultLabel}>Labor total</Text>
            <Text style={styles.calcResultValue}>{formatQuote(breakdown.laborCost)}</Text>
          </View>
        </View>
        <View style={[styles.inputRow, { marginTop: spacing.sm, alignItems: "center" }]}>
          <Text style={styles.toggleLabel}>Emergency / after-hours rate</Text>
          <Switch value={isEmergency} onValueChange={setIsEmergency} trackColor={{ true: colors.warning }} accessibilityLabel="Emergency or after-hours rate — raises your labor rate by your multiplier" />
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
              returnKeyType="done"
              accessibilityLabel="Material name"
            />
            <TextInput
              style={styles.matInput}
              placeholder="Qty"
              placeholderTextColor={colors.textMuted}
              value={String(m.quantity)}
              onChangeText={(v) => updateMaterial(m.id, "quantity", v)}
              keyboardType="decimal-pad"
              inputAccessoryViewID={CALC_DONE_ID}
              accessibilityLabel="Material quantity"
            />
            <TextInput
              style={styles.matInput}
              placeholder="$ each"
              placeholderTextColor={colors.textMuted}
              value={String(m.unitCost)}
              onChangeText={(v) => updateMaterial(m.id, "unitCost", v)}
              keyboardType="decimal-pad"
              inputAccessoryViewID={CALC_DONE_ID}
              accessibilityLabel="Material cost each"
            />
            <TouchableOpacity
              onPress={() => removeMaterial(m.id)}
              style={styles.removeBtn}
              accessibilityRole="button"
              accessibilityLabel={`Remove material ${m.name || "item"}`}
            >
              <Ionicons name="close" size={16} color={colors.danger} />
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

      <SectionLabel>Direct costs</SectionLabel>
      <Card>
        <JobCostsEditor value={jobCosts} onChange={setJobCosts} doneBarId={CALC_DONE_ID} />
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
  linking: boolean;
  onMarkSent: () => void;
  canMarkSent: boolean;
  copied: boolean;
  total: number;
}

function EstimateTab({ generating, generatedEstimate, onRegenerate, onCopy, onEmail, onMarkSent, canMarkSent, copied, total, linking }: EstimateTabProps) {
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
          label={linking ? "Creating approval link..." : "Email to customer →"}
          onPress={onEmail}
          loading={linking}
          style={{ marginTop: spacing.sm }}
        />
      ) : null}

      {!generating && generatedEstimate && canMarkSent ? (
        <Button
          label="Mark estimate as sent"
          variant="secondary"
          onPress={onMarkSent}
          style={{ marginTop: spacing.sm }}
        />
      ) : null}

      <Text style={styles.estimateNote}>
        Email it — or mark it sent yourself if you delivered it another way.
        Either moves the job to "Estimate sent" and starts the approval clock.
      </Text>
    </ScrollView>
  );
}

// ── Small reusable pieces ──────────────────────────────────────────────────────

function HelpItem({ text, styles }: { text: string; styles: ReturnType<typeof createStyles> }) {
  const { colors } = useTheme();
  return (
    <View style={styles.helpRow}>
      <Ionicons name="ellipse" size={5} color={colors.textMuted} style={{ marginTop: 7 }} />
      <Text style={styles.helpText}>{text}</Text>
    </View>
  );
}

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
          inputAccessoryViewID={CALC_DONE_ID}
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
      <Text style={[styles.breakdownLabel, bold && { fontFamily: fonts.bodySemiBold, color: colors.textPrimary }]}>
        {label}
      </Text>
      <Text style={[styles.breakdownValue, bold && { fontFamily: fonts.display, fontSize: fontSize.md }]}>
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
      ...layout.contentColumn,
    },
    tab: { flex: 1, paddingVertical: 8, borderRadius: radius.md, alignItems: "center", justifyContent: "center", flexDirection: "row", gap: 6, backgroundColor: colors.background },
    tabActive: { backgroundColor: colors.accent },
    tabText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    tabTextActive: { fontFamily: fonts.bodySemiBold, color: colors.textOnAccent },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    priceCard: { alignItems: "center", paddingVertical: spacing.lg, marginBottom: spacing.sm, backgroundColor: colors.accent },
    priceLabel: { fontFamily: fonts.mono, fontSize: 10, color: "rgba(255,255,255,0.8)", marginBottom: 4, textTransform: "uppercase", letterSpacing: 0.8 },
    priceMain: { fontFamily: fonts.display, fontSize: 40, color: colors.textOnAccent, fontVariant: ["tabular-nums"] },
    priceRange: { fontFamily: fonts.mono, fontSize: 11, color: "rgba(255,255,255,0.9)", marginTop: 4 },
    breakEven: { fontFamily: fonts.mono, fontSize: 10, color: "rgba(255,255,255,0.7)", marginTop: 2 },
    warningBox: {
      backgroundColor: colors.warningBg, borderRadius: radius.md, padding: spacing.sm,
      marginBottom: spacing.sm, borderLeftWidth: 3, borderLeftColor: colors.warning,
    },
    warningText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.warning },
    sectionLabel: {
      fontFamily: fonts.mono, fontSize: fontSize.xs, color: colors.textSecondary,
      textTransform: "uppercase", letterSpacing: 0.8,
      marginTop: spacing.md, marginBottom: spacing.sm,
    },
    inputRow: { flexDirection: "row", gap: spacing.sm, alignItems: "flex-end" },
    smallInputWrap: { flex: 1 },
    smallLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.textSecondary, marginBottom: 4 },
    smallInputRow: { flexDirection: "row", alignItems: "center" },
    smallInput: {
      fontFamily: fonts.bodyRegular,
      // minHeight (not height): accessibility text grows the inputs instead
      // of clipping — components/Field.tsx pattern.
      flex: 1, minHeight: 44, backgroundColor: colors.background, borderRadius: radius.sm,
      paddingHorizontal: spacing.sm, fontSize: fontSize.sm, color: colors.textPrimary,
      borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border,
    },
    inputAdornment: { fontFamily: fonts.mono, fontSize: 11, color: colors.textMuted, paddingHorizontal: 4 },
    calcResult: { flex: 1, alignItems: "flex-end" },
    calcResultLabel: { fontFamily: fonts.mono, fontSize: 10, color: colors.textMuted, textTransform: "uppercase", letterSpacing: 0.4 },
    calcResultValue: { fontFamily: fonts.display, fontSize: fontSize.md, color: colors.textPrimary, fontVariant: ["tabular-nums"] },
    toggleLabel: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.sm, color: colors.textPrimary },
    materialRow: { flexDirection: "row", gap: 6, marginBottom: 6, alignItems: "center" },
    matInput: {
      fontFamily: fonts.bodyRegular,
      flex: 1, minHeight: 44, backgroundColor: colors.background, borderRadius: radius.sm,
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
    addMaterialBtn: {
      paddingVertical: spacing.sm, alignItems: "center", borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", marginTop: 4,
    },
    addMaterialText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.accent },
    emptyMaterials: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.sm },
    helpHeader: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    helpTitle: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.textPrimary },
    helpRow: { flexDirection: "row", gap: spacing.sm, alignItems: "flex-start", marginBottom: spacing.xs },
    helpText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, flex: 1, lineHeight: 20 },
    helpNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: spacing.xs, fontStyle: "italic" },
    breakdownRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginBottom: 6 },
    breakdownLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, flex: 1 },
    breakdownValue: { fontFamily: fonts.mono, fontSize: 12, color: colors.textPrimary },
    effectiveRate: { fontFamily: fonts.mono, fontSize: 10, color: colors.textMuted, marginTop: spacing.xs, textAlign: "right" },
    actions: { flexDirection: "row", marginTop: spacing.lg },
    estimateHeader: { alignItems: "center", paddingVertical: spacing.md, marginBottom: spacing.sm, backgroundColor: colors.successBg },
    estimateHeaderLabel: { fontFamily: fonts.mono, fontSize: 10, color: colors.success, textTransform: "uppercase", letterSpacing: 0.8 },
    estimateHeaderTotal: { fontFamily: fonts.display, fontSize: fontSize.xl, color: colors.success, fontVariant: ["tabular-nums"], marginTop: 2 },
    estimateBody: { marginBottom: spacing.sm, minHeight: 200 },
    generatingRow: { flexDirection: "row", alignItems: "center", padding: spacing.md },
    generatingText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    estimateText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },
    estimateActions: { flexDirection: "row", marginBottom: spacing.sm },
    estimateNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, textAlign: "center", marginTop: spacing.md, lineHeight: 18 },
  });
}
