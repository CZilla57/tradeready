// screens/CreateInvoiceFromJobScreen.tsx
// Bridges a completed job into a new invoice.
// Pre-fills everything it can from the job record so the user just reviews
// and taps "Create invoice" — no retyping.
//
// Flow: JobDetailScreen (complete) → here → InvoiceList
// Side effects:
//   1. Saves new invoice to AsyncStorage (invoices key)
//   2. Updates job status to "invoiced" and writes invoiceId back to the job

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
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadJobs, saveJobs, loadInvoices, saveInvoices, loadCustomers, getOrCreateCustomer } from "../utils/storage";
import { formatQuote } from "../utils/format";
import Field from "../components/Field";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';
import type { Job, Invoice, Customer } from "../types/models";

function trackedDisplay(sessions: any[] = []): string | null {
  const ms = sessions
    .filter((s) => s.end)
    .reduce((sum: number, s: any) => sum + (new Date(s.end) as any) - (new Date(s.start) as any), 0);
  if (ms <= 0) return null;
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

// Default payment terms: 30 days from today
function defaultDueDate(): string {
  const d = new Date();
  d.setDate(d.getDate() + 30);
  return d.toISOString().split("T")[0];
}

// Auto-generate the next invoice number from existing invoices
function nextInvoiceNumber(invoices: Invoice[]): string {
  const nums = invoices
    .map((inv) => parseInt((inv.number || "").replace(/\D/g, ""), 10))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}

export default function CreateInvoiceFromJobScreen({ route, navigation }: { route: any; navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params;

  const [loading, setLoading]   = useState<boolean>(true);
  const [saving, setSaving]     = useState<boolean>(false);
  const [job, setJob]           = useState<Job | null>(null);

  // Editable invoice fields — pre-filled from the job
  const [customer, setCustomer] = useState<string>("");
  const [number, setNumber]     = useState<string>("");
  const [amount, setAmount]     = useState<string>("");
  const [due, setDue]           = useState<string>(defaultDueDate());
  const [email, setEmail]       = useState<string>("");
  const [phone, setPhone]       = useState<string>("");
  const [desc, setDesc]         = useState<string>("");

  useEffect(() => {
    navigation.setOptions({ title: "Create Invoice" });
    async function prefillFromJob() {
      try {
        const [jobs, invoices, customers] = await Promise.all([loadJobs(), loadInvoices(), loadCustomers()]);
        const j: Job | undefined = jobs.find((x: Job) => x.id === jobId);

        if (!j) {
          Alert.alert("Error", "Job not found.");
          navigation.goBack();
          return;
        }

        const matchingCustomer: Customer | undefined = customers.find((c: Customer) => c.id === j.customerId);

        setJob(j);
        setCustomer(j.customerName || "");
        setAmount(j.estimateTotal > 0 ? String(j.estimateTotal) : "");
        setEmail(matchingCustomer?.email || "");
        setPhone(matchingCustomer?.phone || "");
        setDesc(j.title || "");
        setNumber(nextInvoiceNumber(invoices));
      } catch (err: unknown) {
        console.error("CreateInvoiceFromJobScreen: prefill failed", err);
      } finally {
        setLoading(false);
      }
    }
    prefillFromJob();
  }, [jobId, navigation]);

  async function handleCreate() {
    if (!customer.trim()) {
      Alert.alert("Missing info", "Customer name is required.");
      return;
    }
    const parsedAmount = parseFloat(amount);
    if (!amount || isNaN(parsedAmount) || parsedAmount <= 0) {
      Alert.alert("Missing info", "Please enter a valid invoice amount.");
      return;
    }

    setSaving(true);
    try {
      const [jobs, invoices] = await Promise.all([loadJobs(), loadInvoices()]);

      // Link to a real customer record (matches the job's customer by name, or
      // creates one); `customer` stays as the denormalized display name (#5).
      const record = await getOrCreateCustomer({
        name: customer.trim(),
        email: email.trim(),
        phone: phone.trim(),
      });

      // Build the invoice record — matches the shape expected by InvoicesScreen / AddInvoiceScreen
      const newInvoice = {
        id:         `inv${Date.now()}`,
        customer:   customer.trim(),
        customerId: record?.id ?? "",
        number:   number.trim() || nextInvoiceNumber(invoices),
        amount:   parsedAmount,
        due,
        email:    email.trim(),
        phone:    phone.trim(),
        desc:     desc.trim(),
        paid:     false,
        jobId,    // back-reference so we can cross-link later
      };

      await saveInvoices([...invoices, newInvoice]);

      // Advance the job to "invoiced" and record which invoice was created
      const updatedJobs = jobs.map((j): Job =>
        j.id === jobId
          ? { ...j, status: "invoiced", invoiceId: newInvoice.id }
          : j
      );
      await saveJobs(updatedJobs);

      // Go straight to the outreach screen so they can send the invoice immediately.
      // Replace this screen in the stack so Back doesn't return here.
      navigation.replace("Outreach", { invoiceId: newInvoice.id });
    } catch (err: unknown) {
      console.error("CreateInvoiceFromJobScreen: save failed", err);
      Alert.alert("Error", "Could not create invoice. Please try again.");
    } finally {
      setSaving(false);
    }
  }

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator color={colors.accent} size={36} />
      </View>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
        >
          {/* Pre-fill notice */}
          {job && job.estimateTotal > 0 && (
            <View style={styles.prefillBanner}>
              <Text style={styles.prefillBannerText}>
                Pre-filled from job estimate ({formatQuote(job.estimateTotal)}). Review and adjust if needed.
              </Text>
            </View>
          )}

          {/* Tracked time hint */}
          {job && (() => {
            const tracked = trackedDisplay((job as any).timeSessions);
            if (!tracked) return null;
            const estH = job.laborHours || 0;
            return (
              <View style={styles.trackBanner}>
                <Text style={styles.trackBannerText}>
                  ⏱ Time tracked: {tracked}
                  {estH > 0 ? ` (estimated ${estH}h)` : ""}. Adjust the amount above if needed.
                </Text>
              </View>
            );
          })()}

          <Field label="Customer name *" value={customer} onChangeText={setCustomer} placeholder="Jane Smith" />
          <Field label="Invoice #" value={number} onChangeText={setNumber} placeholder="INV-0001" />

          <View style={styles.row}>
            <View style={{ flex: 1 }}>
              <Field
                label="Amount ($) *"
                value={amount}
                onChangeText={setAmount}
                placeholder="0.00"
                keyboardType="decimal-pad"
              />
            </View>
            <View style={{ width: spacing.md }} />
            <View style={{ flex: 1 }}>
              <Field
                label="Due date"
                value={due}
                onChangeText={setDue}
                placeholder="YYYY-MM-DD"
                keyboardType="numbers-and-punctuation"
              />
            </View>
          </View>

          <Field
            label="Customer email"
            value={email}
            onChangeText={setEmail}
            placeholder="jane@example.com"
            keyboardType="email-address"
            autoCapitalize="none"
          />
          <Field
            label="Customer phone"
            value={phone}
            onChangeText={setPhone}
            placeholder="(555) 123-4567"
            keyboardType="phone-pad"
          />
          <Field
            label="Description of work"
            value={desc}
            onChangeText={setDesc}
            placeholder="What was completed?"
            multiline
          />

          <View style={styles.actions}>
            <TouchableOpacity
              style={styles.cancelBtn}
              onPress={() => navigation.goBack()}
            >
              <Text style={styles.cancelBtnText}>Cancel</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.createBtn, saving && styles.createBtnDisabled]}
              onPress={handleCreate}
              disabled={saving}
            >
              <Text style={styles.createBtnText}>
                {saving ? "Creating..." : "Create invoice →"}
              </Text>
            </TouchableOpacity>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
  container:        { flex: 1, backgroundColor: colors.background },
  loadingContainer: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: colors.background },
  scroll:           { padding: spacing.md, paddingBottom: 40 },

  prefillBanner: {
    backgroundColor: colors.accentBg,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.md,
    borderLeftWidth: 3,
    borderLeftColor: colors.accent,
  },
  prefillBannerText: {
    fontSize: fontSize.sm,
    color: colors.accent,
    lineHeight: 20,
  },
  trackBanner: {
    backgroundColor: colors.surfaceSecondary,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.md,
    borderLeftWidth: 3,
    borderLeftColor: colors.textMuted,
  },
  trackBannerText: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    lineHeight: 20,
  },

  row:        { flexDirection: "row" },

  actions: {
    flexDirection: "row",
    gap: spacing.sm,
    marginTop: spacing.lg,
  },
  cancelBtn: {
    flex: 1,
    height: 48,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    alignItems: "center",
    justifyContent: "center",
  },
  cancelBtnText: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    fontWeight: "500",
  },
  createBtn: {
    flex: 2,
    height: 48,
    borderRadius: radius.md,
    backgroundColor: colors.accent,
    alignItems: "center",
    justifyContent: "center",
  },
  createBtnDisabled: {
    opacity: 0.6,
  },
  createBtnText: {
    fontSize: fontSize.md,
    color: colors.textOnAccent,
    fontWeight: "700",
  },
  });
}
