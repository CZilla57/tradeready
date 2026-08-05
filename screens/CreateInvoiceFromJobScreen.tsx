// screens/CreateInvoiceFromJobScreen.tsx
// Bridges a job into an invoice — either the final bill (job complete) or an
// up-front deposit request (job approved/scheduled/in_progress, before work is
// done). Pre-fills everything it can so the user just reviews and taps the
// button — no retyping.
//
// Three modes (utils/jobStatus.ts invoiceScreenMode), keyed off
// (job.status, job.invoiceId):
//   "create"         — job complete, no invoice yet. Creates one, job -> invoiced.
//   "requestDeposit" — job approved/scheduled/in_progress, no invoice yet.
//                       Creates one WITHOUT advancing job.status.
//   "finalize"       — job complete, invoice already exists (deposit was
//                       requested earlier). Updates that invoice in place,
//                       job -> invoiced.
//
// Flow: JobDetailScreen → here → Outreach
// Side effects:
//   1. Saves the invoice to AsyncStorage (invoices key) — new row for
//      "create"/"requestDeposit", in-place update for "finalize".
//   2. Applies jobChangesAfterInvoiceSave(mode, invoiceId) to the job.

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
import { loadJobs, saveJobs, loadInvoices, saveInvoices, loadCustomers, getOrCreateCustomer, loadSettings } from "../utils/storage";
import { promptForInvoiceReminders } from "../utils/notifications";
import { prefillInvoiceDraftFromJob, buildInvoiceLineItems, computeBillableBreakdown, defaultDueDate } from "../utils/autoInvoice";
import { approvedChangeOrderTotal, jobBillableTotal } from "../utils/changeOrders";
import { invoiceScreenMode, jobChangesAfterInvoiceSave, invoiceScreenCopy, type InvoiceScreenMode } from "../utils/jobStatus";
import { amountPaid, reconcilePaidFields } from "../utils/invoicePayments";
import { formatQuote } from "../utils/format";
import Field from "../components/Field";
import { nextInvoiceNumber } from "../utils/invoiceNumber";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';
import { track, reportError } from '../utils/analytics';
import type { Job, Invoice, Customer, InvoiceLineItem } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

function trackedDisplay(sessions: any[] = []): string | null {
  const ms = sessions
    .filter((s) => s.end)
    .reduce((sum: number, s: any) => sum + (new Date(s.end) as any) - (new Date(s.start) as any), 0);
  if (ms <= 0) return null;
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export default function CreateInvoiceFromJobScreen({ route, navigation }: JobStackScreenProps<'CreateInvoiceFromJob'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params;

  const [loading, setLoading]   = useState<boolean>(true);
  const [saving, setSaving]     = useState<boolean>(false);
  const [job, setJob]           = useState<Job | null>(null);
  const [mode, setMode]         = useState<InvoiceScreenMode>("create");
  const [existingInvoice, setExistingInvoice] = useState<Invoice | null>(null);

  // Editable invoice fields — pre-filled from the job (or, in "finalize" mode,
  // from the existing deposit invoice, so a manually-adjusted amount survives).
  const [customer, setCustomer] = useState<string>("");
  const [number, setNumber]     = useState<string>("");
  const [amount, setAmount]     = useState<string>("");
  const [due, setDue]           = useState<string>(defaultDueDate());
  const [email, setEmail]       = useState<string>("");
  const [phone, setPhone]       = useState<string>("");
  const [desc, setDesc]         = useState<string>("");
  // True when the prefilled amount bills tracked timer hours instead of the
  // estimate's hours (create mode only) — switches the ⏱ banner copy.
  const [billedFromTracked, setBilledFromTracked] = useState<boolean>(false);
  // Non-zero when finalize re-derived the amount because approved change
  // orders exist — switches on the explanatory banner.
  const [finalizeCoTotal, setFinalizeCoTotal] = useState<number>(0);

  useEffect(() => {
    async function prefillFromJob() {
      try {
        const [jobs, invoices, customers, settings] = await Promise.all([loadJobs(), loadInvoices(), loadCustomers(), loadSettings()]);
        const j: Job | undefined = jobs.find((x: Job) => x.id === jobId);

        if (!j) {
          Alert.alert("Error", "Job not found.");
          navigation.goBack();
          return;
        }

        const screenMode = invoiceScreenMode(j.status, !!j.invoiceId);
        if (!screenMode) {
          Alert.alert("Error", "This job's invoice is already open — find it from the Invoices tab.");
          navigation.goBack();
          return;
        }
        setMode(screenMode);
        navigation.setOptions({ title: invoiceScreenCopy(screenMode).title });

        const matchingCustomer: Customer | undefined = customers.find((c: Customer) => c.id === j.customerId);

        setJob(j);

        if (screenMode === "finalize") {
          const existing = invoices.find((inv) => inv.id === j.invoiceId);
          if (!existing) {
            Alert.alert("Error", "The deposit invoice for this job could not be found.");
            navigation.goBack();
            return;
          }
          setExistingInvoice(existing);
          setCustomer(existing.customer);
          setNumber(existing.number);
          // The deposit invoice's amount was fixed at request time. When
          // approved change orders exist, re-derive the amount fresh (the
          // same recomputation the line items below already do) — otherwise
          // keep the existing amount so a manual adjustment survives.
          const coTotal = approvedChangeOrderTotal(j);
          if (coTotal !== 0) {
            setAmount(String(computeBillableBreakdown(j).total));
            setFinalizeCoTotal(coTotal);
          } else {
            setAmount(String(existing.amount));
          }
          // Deliberately NOT existing.due: that was computed as "30 days from
          // deposit-request time," which can already be in the past by the
          // time the job finishes. Payment terms restart when the real bill
          // is issued, so `due` keeps its useState initial default (today+30).
          setEmail(existing.email);
          setPhone(existing.phone);
          setDesc(existing.desc);
        } else {
          // Shared derivation with the auto-invoice flow (utils/autoInvoice) —
          // bills tracked timer hours in create mode; requestDeposit stays on
          // the estimate (the util gates tracked billing on done statuses).
          const draft = prefillInvoiceDraftFromJob(j, invoices, settings, matchingCustomer);
          setCustomer(draft.customer);
          setAmount(draft.amount > 0 ? String(draft.amount) : "");
          setEmail(draft.email);
          setPhone(draft.phone);
          setDesc(draft.desc);
          setNumber(draft.number);
          setBilledFromTracked(draft.usedTrackedTime);
        }
      } catch (err: unknown) {
        console.error("CreateInvoiceFromJobScreen: prefill failed", err);
        reportError(err, { context: 'invoicePrefill' });
        // Do not leave `mode` at its "create" default here: a save from this
        // degraded state would take the create branch and advance job.status
        // to "invoiced" regardless of the job's real status (invoiceScreenMode
        // never ran to guard it). Bail out instead.
        Alert.alert("Error", "Could not load this job. Please try again.");
        navigation.goBack();
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
      const [jobs, invoices, settings] = await Promise.all([loadJobs(), loadInvoices(), loadSettings()]);

      // Link to a real customer record (matches the job's customer by name, or
      // creates one); `customer` stays as the denormalized display name (#5).
      const record = await getOrCreateCustomer({
        name: customer.trim(),
        email: email.trim(),
        phone: phone.trim(),
      });

      // Derive line items from the job's current estimate breakdown — recomputed
      // fresh even in "finalize" mode, so estimate edits made after the deposit
      // was requested (extra materials, a change order) are picked up. Shared
      // with the auto-invoice flow; bills tracked timer hours on done jobs.
      const lineItems: InvoiceLineItem[] = job ? buildInvoiceLineItems(job) : [];

      let savedInvoiceId: string;
      let savedInvoicePaid = false;

      if (mode === "finalize" && existingInvoice) {
        // Build from the freshly-loaded row, not the `existingInvoice` state
        // captured back at mount/prefill time — a background sync pull could
        // have landed a payment (e.g. a Stripe webhook write from another
        // device) on this invoice while the screen sat open, and spreading
        // the stale snapshot would silently drop it from the ledger.
        const freshInvoice = invoices.find((inv) => inv.id === existingInvoice.id) ?? existingInvoice;
        // reconcilePaidFields re-derives paid/paidAt from the ledger (a no-op
        // if there's no ledger yet) — required because `amount` just changed:
        // AddInvoiceScreen.tsx follows this same edit-existing-invoice pattern
        // for the same reason (see its handleSave).
        const updatedInvoice: Invoice = reconcilePaidFields({
          ...freshInvoice,
          customer:   customer.trim(),
          customerId: record?.id ?? freshInvoice.customerId ?? "",
          number:     number.trim() || freshInvoice.number,
          amount:     parsedAmount,
          due,
          email:      email.trim(),
          phone:      phone.trim(),
          desc:       desc.trim(),
          lineItems:  lineItems.length > 0 ? lineItems : freshInvoice.lineItems,
        });
        const updatedInvoices = invoices.map((inv) => (inv.id === freshInvoice.id ? updatedInvoice : inv));
        await saveInvoices(updatedInvoices);
        track('invoice_finalized', { source: 'from_job' });
        savedInvoiceId = freshInvoice.id;
        savedInvoicePaid = !!updatedInvoice.paid;
      } else {
        const newInvoice = {
          id:         `inv${Date.now()}`,
          customer:   customer.trim(),
          customerId: record?.id ?? "",
          number:   number.trim() || nextInvoiceNumber(invoices, settings),
          amount:   parsedAmount,
          due,
          email:    email.trim(),
          phone:    phone.trim(),
          desc:     desc.trim(),
          paid:     false,
          jobId,
          ...(lineItems.length > 0 ? { lineItems } : {}),
        };
        await saveInvoices([...invoices, newInvoice]);
        track('invoice_created', { source: 'from_job', mode });
        // Contextual permission ask (once): the user just created an invoice,
        // so overdue reminders are concretely useful right now.
        promptForInvoiceReminders();
        savedInvoiceId = newInvoice.id;
      }

      const jobChanges = jobChangesAfterInvoiceSave(mode, savedInvoiceId, savedInvoicePaid);
      const updatedJobs = jobs.map((j): Job =>
        j.id === jobId ? { ...j, ...jobChanges } : j
      );
      await saveJobs(updatedJobs);

      // Go straight to the outreach screen so they can send it immediately.
      // Replace this screen in the stack so Back doesn't return here.
      navigation.replace("Outreach", { invoiceId: savedInvoiceId });
    } catch (err: unknown) {
      console.error("CreateInvoiceFromJobScreen: save failed", err);
      reportError(err, { context: 'invoiceCreate' });
      Alert.alert("Error", "Could not save invoice. Please try again.");
    } finally {
      setSaving(false);
    }
  }

  const copy = invoiceScreenCopy(mode);

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator color={colors.accent} size={36} />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
        >
          {/* Deposit-already-requested notice (finalize mode only) */}
          {mode === "finalize" && existingInvoice?.depositRequest && (
            <View style={styles.prefillBanner}>
              <Text style={styles.prefillBannerText}>
                Deposit already requested: {formatQuote(existingInvoice.depositRequest.amount)}
                {existingInvoice.depositRequest.percent ? ` (${existingInvoice.depositRequest.percent}%)` : ""}
                {amountPaid(existingInvoice) > 0
                  ? ` — ${formatQuote(amountPaid(existingInvoice))} received.`
                  : " — not yet received."}
                {" "}Review the total below before finalizing.
              </Text>
            </View>
          )}

          {/* Pre-fill notice (create / requestDeposit modes only — finalize
              prefills from the existing invoice, not the raw estimate) */}
          {mode !== "finalize" && job && jobBillableTotal(job) > 0 && (
            <View style={styles.prefillBanner}>
              <Text style={styles.prefillBannerText}>
                Pre-filled from job estimate ({formatQuote(jobBillableTotal(job))}). Review and adjust if needed.
              </Text>
            </View>
          )}

          {/* Finalize re-derivation notice (approved change orders only) */}
          {mode === "finalize" && finalizeCoTotal !== 0 && (
            <View style={styles.trackBanner}>
              <Text style={styles.trackBannerText}>
                Amount updated to include approved change orders ({finalizeCoTotal > 0 ? "+" : ""}{formatQuote(finalizeCoTotal)}). Review and adjust if needed.
              </Text>
            </View>
          )}

          {/* Tracked time hint */}
          {job && (() => {
            const tracked = trackedDisplay(job.timeSessions);
            if (!tracked) return null;
            const estH = job.laborHours || 0;
            return (
              <View style={styles.trackBanner}>
                <Text style={styles.trackBannerText}>
                  {billedFromTracked
                    ? `⏱ Billed from tracked time: ${tracked}${estH > 0 ? ` (estimated ${estH}h)` : ""}. Amount updated to match hours worked.`
                    : `⏱ Time tracked: ${tracked}${estH > 0 ? ` (estimated ${estH}h)` : ""}. Adjust the amount above if needed.`}
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
              accessibilityRole="button"
              accessibilityLabel="Cancel"
            >
              <Text style={styles.cancelBtnText}>Cancel</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.createBtn, saving && styles.createBtnDisabled]}
              onPress={handleCreate}
              disabled={saving}
              accessibilityRole="button"
              accessibilityLabel={copy.title}
              accessibilityState={{ disabled: saving, busy: saving }}
            >
              <Text style={styles.createBtnText}>
                {saving ? "Saving..." : copy.cta}
              </Text>
            </TouchableOpacity>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
  container:        { flex: 1, backgroundColor: colors.background },
  loadingContainer: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: colors.background },
  scroll:           { padding: spacing.md, paddingBottom: 40, ...layout.contentColumn },

  prefillBanner: {
    backgroundColor: colors.accentBg,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.md,
    borderLeftWidth: 3,
    borderLeftColor: colors.accent,
  },
  prefillBannerText: {
    fontFamily: fonts.bodyRegular,
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
    fontFamily: fonts.bodyRegular,
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
    fontFamily: fonts.bodyMedium,
    fontSize: fontSize.md,
    color: colors.textSecondary,
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
    fontFamily: fonts.bodyBold,
    fontSize: fontSize.md,
    color: colors.textOnAccent,
  },
  });
}
