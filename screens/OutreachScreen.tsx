import React, { useState, useEffect, useCallback, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  Switch,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { composeEmail, composeSMS } from "../utils/messaging";
import { loadInvoices, saveInvoices, loadSettings } from "../utils/storage";
import {
  getStatus,
  generateOutreachMessage,
  resolvePaymentLink,
  fetchPaymentLink,
  getProviderKey,
  cachedLinkMatches,
  type DepositAsk,
} from "../utils/invoiceHelpers";
import { formatMoney } from "../utils/format";
import { supabase } from "../utils/supabase";
import { Badge, Button, Card, Divider } from "../components/UI";
import Field from "../components/Field";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { track, reportError } from '../utils/analytics';
import {
  isFullyPaid,
  isDepositSatisfied,
  balanceDue,
  resolveDepositAmount,
  roundToCents,
} from "../utils/invoicePayments";
import type { Invoice, Settings } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

const PROVIDER_LABELS: Record<string, string> = {
  stripe: "Stripe",
  paypal: "PayPal.Me",
  venmo: "Venmo",
  square: "Square",
  custom: "Custom URL",
};

function getConfiguredProviders(s: Settings): { id: string; label: string }[] {
  return Object.entries(PROVIDER_LABELS)
    .filter(([id]) => {
      if (id === s.provider) return true;
      if (id === "stripe") return false;
      return !!(s.providerKeys?.[id]);
    })
    .map(([id, label]) => ({ id, label }));
}

/** What the payment ask is: everything owed, half up front, or a typed value. */
type DepositMode = "full" | "half" | "custom";

const DEPOSIT_MODES: { id: DepositMode; label: string }[] = [
  { id: "full", label: "Full balance" },
  { id: "half", label: "50% deposit" },
  { id: "custom", label: "Custom" },
];

export default function OutreachScreen({ route, navigation }: JobStackScreenProps<'Outreach'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { invoiceId } = route.params;

  const [invoice, setInvoice] = useState<Invoice | null>(null);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [channel, setChannel] = useState<"email" | "text">("email");
  const [message, setMessage] = useState("");
  const [subject, setSubject] = useState("");
  const [generating, setGenerating] = useState(false);
  const [generatingLink, setGeneratingLink] = useState(false);
  const [paymentLink, setPaymentLink] = useState("");
  const [paymentPlanEnabled, setPaymentPlanEnabled] = useState(false);
  const [installments, setInstallments] = useState("3");
  const [frequency, setFrequency] = useState("Bi-weekly");
  const [copied, setCopied] = useState(false);
  const [selectedProvider, setSelectedProvider] = useState<string | null>(null);
  const [autoReminder, setAutoReminder] = useState<{ sent_at: string; status: string } | null>(null);
  const [depositMode, setDepositMode] = useState<DepositMode>("full");
  const [customValue, setCustomValue] = useState("50");
  const [customIsPercent, setCustomIsPercent] = useState(true);
  // Debounced copy of customValue: the message auto-regenerates (possibly via
  // an AI call) whenever the deposit ask changes, and that must not fire per
  // keystroke while the user types an amount.
  const [debouncedCustom, setDebouncedCustom] = useState("50");

  useEffect(() => {
    const t = setTimeout(() => setDebouncedCustom(customValue), 600);
    return () => clearTimeout(t);
  }, [customValue]);

  useEffect(() => {
    async function load() {
      const [invoices, s] = await Promise.all([loadInvoices(), loadSettings()]);
      const inv = invoices.find((i) => i.id === invoiceId);
      setInvoice(inv ?? null);
      setSettings(s);
      setSelectedProvider(s.provider);
      navigation.setOptions({ title: inv?.customer || "Outreach" });
      if (!inv) return;

      // Restore an outstanding deposit ask so the screen can re-show the same
      // request (and reuse its cached link) instead of silently resetting to
      // the full balance. Once the deposit has been received — or the invoice
      // settled — the natural next ask IS the full balance, so no restore.
      const req = inv.depositRequest;
      let expectedAmount = roundToCents(balanceDue(inv));
      if (req && !isFullyPaid(inv) && !isDepositSatisfied(inv)) {
        if (req.percent === 50) {
          setDepositMode("half");
        } else {
          setDepositMode("custom");
          if (req.percent) {
            setCustomValue(String(req.percent));
            setDebouncedCustom(String(req.percent));
            setCustomIsPercent(true);
          } else {
            setCustomValue(String(req.amount));
            setDebouncedCustom(String(req.amount));
            setCustomIsPercent(false);
          }
        }
        expectedAmount = resolveDepositAmount(
          inv,
          req.percent ? { percent: req.percent } : { fixed: req.amount },
        );
      }

      // Show the cached link ONLY when it was minted for the amount this
      // screen is about to ask for. An unconditional restore here once showed
      // a link minted before a partial payment — a quiet overcharge.
      if (cachedLinkMatches(inv, expectedAmount)) {
        setPaymentLink(inv.paymentLinkUrl as string);
      }
    }
    load();
  }, [invoiceId, navigation]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data } = await supabase
          .from("auto_reminder_log")
          .select("sent_at,status")
          .eq("invoice_id", invoiceId)
          .maybeSingle();
        if (!cancelled) {
          setAutoReminder((data as { sent_at: string; status: string } | null) ?? null);
        }
      } catch {
        // best-effort — table may not exist yet; just don't show the note
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [invoiceId]);

  // The amount the payment link should charge, per the deposit selector.
  // 0 means "nothing to request" (unparseable custom input) and disables
  // link generation.
  const requestedAmount = useMemo(() => {
    if (!invoice) return 0;
    if (depositMode === "full") return roundToCents(balanceDue(invoice));
    if (depositMode === "half") return resolveDepositAmount(invoice, { percent: 50 });
    const parsed = parseFloat(debouncedCustom);
    if (!Number.isFinite(parsed) || parsed <= 0) return 0;
    return resolveDepositAmount(invoice, customIsPercent ? { percent: parsed } : { fixed: parsed });
  }, [invoice, depositMode, debouncedCustom, customIsPercent]);

  // The active deposit ask — null when the request is effectively the full
  // balance (mode "full", a custom 100%, or a fixed amount at/over the
  // balance), so messages and persistence never call the whole balance a
  // "deposit".
  const depositAsk = useMemo<DepositAsk | null>(() => {
    if (!invoice || depositMode === "full" || requestedAmount <= 0) return null;
    if (requestedAmount >= roundToCents(balanceDue(invoice))) return null;
    const percent =
      depositMode === "half" ? 50 : customIsPercent ? parseFloat(debouncedCustom) : undefined;
    return {
      amount: requestedAmount,
      ...(percent && Number.isFinite(percent) ? { percent } : {}),
    };
  }, [invoice, depositMode, requestedAmount, customIsPercent, debouncedCustom]);

  async function handleGenerateLink(providerOverride?: string, explicit: boolean = true) {
    const provider = providerOverride ?? selectedProvider;
    if (!invoice || !provider) return;
    if (!(requestedAmount > 0)) return;
    setGeneratingLink(true);
    try {
      const link = providerOverride
        ? await fetchPaymentLink(invoice, provider, getProviderKey(settings ?? {}, provider), requestedAmount)
        : await resolvePaymentLink(invoice, provider, getProviderKey(settings ?? {}, provider), requestedAmount);
      setPaymentLink(link);
      if (explicit) {
        track('payment_link_sent', { provider: provider, deposit: Boolean(depositAsk) });
      }
      // Persist the link against the amount it was ACTUALLY minted for — the
      // cache check compares against this, so writing any other number (the
      // old code wrote invoice.amount) poisons the cache and re-mints a link
      // on every visit to a partly-paid invoice. A deposit ask is persisted
      // alongside; a full-balance link supersedes (clears) any prior one.
      const today = new Date().toISOString().split("T")[0];
      const depositRequest = depositAsk
        ? { amount: depositAsk.amount, ...(depositAsk.percent ? { percent: depositAsk.percent } : {}), requestedAt: today }
        : undefined;
      const allInvoices = await loadInvoices();
      await saveInvoices(
        allInvoices.map((i) => {
          if (i.id !== invoice.id) return i;
          const next: Invoice = { ...i, paymentLinkUrl: link, paymentLinkAmount: requestedAmount };
          if (depositRequest) next.depositRequest = depositRequest;
          else delete next.depositRequest;
          return next;
        })
      );
      // Keep the in-memory invoice in step with what was just saved, so the
      // next cache check and the message params see the fresh link.
      setInvoice((prev) =>
        prev
          ? { ...prev, paymentLinkUrl: link, paymentLinkAmount: requestedAmount, depositRequest }
          : prev
      );
    } catch (err: unknown) {
      reportError(err, { context: 'generatePaymentLink' });
      Alert.alert(
        "Payment link error",
        (err as Error)?.message || "Could not generate payment link. Check your backend configuration in Settings."
      );
    }
    setGeneratingLink(false);
  }

  function handleSwitchProvider(provider: string) {
    if (provider === selectedProvider) return;
    setSelectedProvider(provider);
    setPaymentLink("");
    handleGenerateLink(provider, false);
  }

  // Any change to what's being asked invalidates the on-screen link — it was
  // minted for the previous amount. The persisted cache is untouched; going
  // back to the old selection revalidates it through cachedLinkMatches.
  function handleSelectDepositMode(mode: DepositMode) {
    if (mode === depositMode) return;
    setDepositMode(mode);
    setPaymentLink("");
  }

  function handleCustomValueChange(v: string) {
    setCustomValue(v);
    setPaymentLink("");
  }

  function handleCustomUnitChange(isPercent: boolean) {
    if (isPercent === customIsPercent) return;
    setCustomIsPercent(isPercent);
    setPaymentLink("");
  }

  const generate = useCallback(async () => {
    if (!invoice || !settings) return;
    setGenerating(true);
    setMessage("");
    try {
      const raw = await generateOutreachMessage({
        invoice,
        channel,
        biz: settings,
        paymentLink,
        paymentPlan: paymentPlanEnabled
          ? { enabled: true, installments, frequency }
          : { enabled: false },
        // Only claim the link is for the deposit when it actually is: after a
        // mode change the stale link is cleared, and a cached link is only
        // restored when its amount matches the ask — so link+deposit here are
        // always consistent.
        deposit: depositAsk ?? undefined,
        apiKey: settings.anthropicKey,
      });

      if (channel === "email" && raw.startsWith("Subject:")) {
        const lines = raw.split("\n");
        setSubject(lines[0].replace("Subject:", "").trim());
        setMessage(lines.slice(2).join("\n").trim());
      } else {
        setSubject("");
        setMessage(raw);
      }
    } catch {
      setMessage("Error generating message. Check your connection.");
    }
    setGenerating(false);
  }, [invoice, channel, settings, paymentLink, paymentPlanEnabled, installments, frequency, depositAsk]);

  useEffect(() => {
    if (invoice && !isFullyPaid(invoice) && settings) {
      generate();
    }
  }, [channel, paymentPlanEnabled, installments, frequency, paymentLink, invoice, settings, generate]);

  async function sendEmail() {
    if (!invoice) return;
    await composeEmail({
      recipients: [invoice.email],
      subject: subject || `Payment reminder: ${invoice.number}`,
      body: message,
    });
  }

  async function sendSMS() {
    if (!invoice) return;
    await composeSMS({ recipients: [invoice.phone], body: message });
  }

  async function copyToClipboard() {
    const full = channel === "email" && subject ? `Subject: ${subject}\n\n${message}` : message;
    await Clipboard.setStringAsync(full);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (!invoice || !settings) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={colors.accent} size={36} />
      </View>
    );
  }

  const status = getStatus(invoice);
  const configuredProviders = getConfiguredProviders(settings);

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>

        <Card style={styles.summaryCard}>
          <View style={styles.summaryRow}>
            <View style={{ flex: 1 }}>
              <Text style={styles.customerName}>{invoice.customer}</Text>
              <Text style={styles.invoiceMeta}>{invoice.number} · {formatMoney(invoice.amount)}</Text>
              {autoReminder?.status === "sent" && (
                <Text style={styles.autoReminderNote}>
                  ✓ Auto-reminder emailed {new Date(autoReminder.sent_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })}
                </Text>
              )}
            </View>
            <Badge label={status.label} color={status.color} />
          </View>

          {!isFullyPaid(invoice) && (
            <>
              <View style={styles.providerRow}>
                <Text style={styles.providerRowLabel}>Request</Text>
                <View style={styles.providerChips}>
                  {DEPOSIT_MODES.map((m) => (
                    <TouchableOpacity
                      key={m.id}
                      style={[styles.providerChip, depositMode === m.id && styles.providerChipActive]}
                      onPress={() => handleSelectDepositMode(m.id)}
                      accessibilityRole="radio"
                      accessibilityLabel={m.label}
                      accessibilityState={{ selected: depositMode === m.id }}
                    >
                      <Text style={[styles.providerChipText, depositMode === m.id && styles.providerChipTextActive]}>
                        {m.label}
                      </Text>
                    </TouchableOpacity>
                  ))}
                </View>
              </View>
              {depositMode === "custom" && (
                <View style={styles.customRow}>
                  <Field
                    label={customIsPercent ? "Deposit (% of total)" : "Deposit amount ($)"}
                    value={customValue}
                    onChangeText={handleCustomValueChange}
                    keyboardType="decimal-pad"
                    flex
                    containerStyle={styles.customField}
                  />
                  <View style={styles.unitToggle}>
                    {([true, false] as const).map((isPct) => (
                      <TouchableOpacity
                        key={String(isPct)}
                        style={[styles.unitBtn, customIsPercent === isPct && styles.unitBtnActive]}
                        onPress={() => handleCustomUnitChange(isPct)}
                        accessibilityRole="radio"
                        accessibilityLabel={isPct ? "Percent of total" : "Dollar amount"}
                        accessibilityState={{ selected: customIsPercent === isPct }}
                      >
                        <Text style={[styles.unitText, customIsPercent === isPct && styles.unitTextActive]}>
                          {isPct ? "%" : "$"}
                        </Text>
                      </TouchableOpacity>
                    ))}
                  </View>
                </View>
              )}
              {depositAsk ? (
                <Text style={styles.requestSummary}>
                  Requesting {formatMoney(depositAsk.amount)}
                  {depositAsk.percent ? ` (${depositAsk.percent}% of total)` : ""} of the{" "}
                  {formatMoney(roundToCents(balanceDue(invoice)))} balance
                </Text>
              ) : depositMode === "custom" && requestedAmount <= 0 ? (
                <Text style={styles.requestInvalid}>Enter an amount greater than zero.</Text>
              ) : null}
            </>
          )}

          {!isFullyPaid(invoice) && configuredProviders.length > 1 && (
            <View style={styles.providerRow}>
              <Text style={styles.providerRowLabel}>Pay via</Text>
              <View style={styles.providerChips}>
                {configuredProviders.map((p) => (
                  <TouchableOpacity
                    key={p.id}
                    style={[styles.providerChip, selectedProvider === p.id && styles.providerChipActive]}
                    onPress={() => handleSwitchProvider(p.id)}
                    accessibilityRole="radio"
                    accessibilityLabel={`Pay via ${p.label}`}
                    accessibilityState={{ selected: selectedProvider === p.id }}
                  >
                    <Text style={[styles.providerChipText, selectedProvider === p.id && styles.providerChipTextActive]}>
                      {p.label}
                    </Text>
                  </TouchableOpacity>
                ))}
              </View>
            </View>
          )}

          {paymentLink ? (
            <View style={styles.linkBadge}>
              {/* requestedAmount is always the amount this link charges: any
                  change to the ask clears the link, and a cached link is only
                  restored when its amount matches. */}
              <Text style={styles.linkBadgeText}>
                ✓ {PROVIDER_LABELS[selectedProvider ?? ""] ?? "Payment"} link ready · {formatMoney(requestedAmount)}
              </Text>
            </View>
          ) : !isFullyPaid(invoice) ? (
            <TouchableOpacity
              style={styles.generateLinkBtn}
              onPress={() => handleGenerateLink()}
              disabled={generatingLink || requestedAmount <= 0}
              accessibilityRole="button"
              accessibilityLabel="Generate payment link"
              accessibilityState={{ disabled: generatingLink || requestedAmount <= 0, busy: generatingLink }}
            >
              {generatingLink ? (
                <ActivityIndicator size="small" color={colors.accent} />
              ) : (
                <Text style={styles.generateLinkText}>Generate payment link</Text>
              )}
            </TouchableOpacity>
          ) : null}
        </Card>

        {isFullyPaid(invoice) ? (
          <Card style={styles.paidCard}>
            <Text style={styles.paidTitle}>Invoice paid</Text>
            <Text style={styles.paidSub}>No further outreach needed.</Text>
          </Card>
        ) : (
          <>
            <Card style={styles.section}>
              <View style={styles.toggleRow}>
                <Text style={styles.toggleLabel}>Offer a payment plan</Text>
                <Switch
                  value={paymentPlanEnabled}
                  onValueChange={setPaymentPlanEnabled}
                  trackColor={{ true: colors.accent }}
                  accessibilityLabel="Offer a payment plan"
                />
              </View>
              {paymentPlanEnabled && (
                <View style={styles.planOptions}>
                  <Text style={styles.planLabel}>Installments</Text>
                  {["2", "3", "4", "6"].map((n) => (
                    <TouchableOpacity
                      key={n}
                      style={[styles.chipBtn, installments === n && styles.chipBtnActive]}
                      onPress={() => setInstallments(n)}
                      accessibilityRole="radio"
                      accessibilityLabel={`${n} payments`}
                      accessibilityState={{ selected: installments === n }}
                    >
                      <Text style={[styles.chipText, installments === n && styles.chipTextActive]}>
                        {n} payments
                      </Text>
                    </TouchableOpacity>
                  ))}
                  <Text style={[styles.planLabel, { marginTop: spacing.sm }]}>Frequency</Text>
                  {["Weekly", "Bi-weekly", "Monthly"].map((f) => (
                    <TouchableOpacity
                      key={f}
                      style={[styles.chipBtn, frequency === f && styles.chipBtnActive]}
                      onPress={() => setFrequency(f)}
                      accessibilityRole="radio"
                      accessibilityLabel={f}
                      accessibilityState={{ selected: frequency === f }}
                    >
                      <Text style={[styles.chipText, frequency === f && styles.chipTextActive]}>{f}</Text>
                    </TouchableOpacity>
                  ))}
                </View>
              )}
            </Card>

            <View style={styles.channelTabs}>
              {(["email", "text"] as const).map((ch) => (
                <TouchableOpacity
                  key={ch}
                  style={[styles.tab, channel === ch && styles.tabActive]}
                  onPress={() => setChannel(ch)}
                  accessibilityRole="tab"
                  accessibilityLabel={ch === "email" ? "Email" : "Text message"}
                  accessibilityState={{ selected: channel === ch }}
                >
                  <Text style={[styles.tabText, channel === ch && styles.tabTextActive]}>
                    {ch === "email" ? "✉ Email" : "💬 Text message"}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>

            <Card style={styles.messageCard}>
              {channel === "email" && subject ? (
                <Text style={styles.subjectLine}>Subject: {subject}</Text>
              ) : null}
              {generating ? (
                <View style={styles.generatingRow}>
                  <ActivityIndicator color={colors.accent} size="small" />
                  <Text style={styles.generatingText}>  Generating message…</Text>
                </View>
              ) : (
                <Text style={styles.messageText}>{message}</Text>
              )}
            </Card>

            <View style={styles.actionRow}>
              <TouchableOpacity style={styles.copyBtn} onPress={copyToClipboard} accessibilityRole="button" accessibilityLabel={copied ? "Copied" : "Copy message"}>
                <Text style={styles.copyBtnText}>{copied ? "✓ Copied" : "Copy"}</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.regenBtn} onPress={generate} accessibilityRole="button" accessibilityLabel="Regenerate message">
                <Text style={styles.regenBtnText}>↺ Regenerate</Text>
              </TouchableOpacity>
            </View>

            <Divider />

            <Text style={styles.sendLabel}>Send via</Text>
            <Button
              label={`Open in ${channel === "email" ? "Mail" : "Messages"}`}
              onPress={channel === "email" ? sendEmail : sendSMS}
              style={{ marginBottom: spacing.sm }}
            />
            <Button
              label="Copy to clipboard"
              variant="ghost"
              onPress={copyToClipboard}
            />
          </>
        )}

      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    loading: { flex: 1, alignItems: "center", justifyContent: "center" },
    scroll: { padding: spacing.md, paddingBottom: 40 },
    summaryCard: { marginBottom: spacing.sm },
    summaryRow: { flexDirection: "row", alignItems: "flex-start" },
    customerName: { fontSize: fontSize.lg, fontWeight: "600", color: colors.textPrimary },
    invoiceMeta: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
    autoReminderNote: { fontSize: fontSize.xs, color: colors.success, marginTop: 4, fontWeight: "500" },
    linkBadge: {
      marginTop: spacing.sm,
      backgroundColor: colors.successBg,
      borderRadius: radius.sm,
      paddingHorizontal: 10,
      paddingVertical: 4,
      alignSelf: "flex-start",
    },
    linkBadgeText: { fontSize: fontSize.xs, color: colors.success, fontWeight: "600" },
    generateLinkBtn: {
      marginTop: spacing.sm,
      paddingHorizontal: 14,
      paddingVertical: 8,
      borderRadius: radius.sm,
      borderWidth: 1,
      borderColor: colors.accent,
      alignSelf: "flex-start",
      minWidth: 44,
      alignItems: "center",
    },
    generateLinkText: { fontSize: fontSize.xs, color: colors.accent, fontWeight: "600" },
    providerRow: {
      marginTop: spacing.sm,
      flexDirection: "row",
      alignItems: "center",
      flexWrap: "wrap",
      gap: spacing.sm,
    },
    providerRowLabel: { fontSize: fontSize.xs, color: colors.textMuted, fontWeight: "500" },
    providerChips: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
    providerChip: {
      paddingHorizontal: 10,
      paddingVertical: 4,
      borderRadius: radius.full,
      borderWidth: 1,
      borderColor: colors.border,
      backgroundColor: colors.surface,
    },
    providerChipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    providerChipText: { fontSize: fontSize.xs, color: colors.textSecondary, fontWeight: "500" },
    providerChipTextActive: { color: colors.accent, fontWeight: "600" },
    customRow: {
      marginTop: spacing.sm,
      flexDirection: "row",
      alignItems: "flex-end",
      gap: spacing.sm,
    },
    customField: { marginBottom: 0 },
    unitToggle: { flexDirection: "row", gap: 4, paddingBottom: 2 },
    unitBtn: {
      minWidth: 44,
      minHeight: 44,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
      alignItems: "center",
      justifyContent: "center",
      backgroundColor: colors.surface,
    },
    unitBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    unitText: { fontSize: fontSize.md, color: colors.textSecondary, fontWeight: "500" },
    unitTextActive: { color: colors.accent, fontWeight: "700" },
    requestSummary: { marginTop: spacing.sm, fontSize: fontSize.xs, color: colors.textSecondary },
    requestInvalid: { marginTop: spacing.sm, fontSize: fontSize.xs, color: colors.warning },
    section: { marginBottom: spacing.sm },
    paidCard: { marginBottom: spacing.sm, alignItems: "center", paddingVertical: spacing.lg },
    paidTitle: { fontSize: fontSize.md, fontWeight: "700", color: colors.success },
    paidSub: { fontSize: fontSize.sm, color: colors.textMuted, marginTop: 4 },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontSize: fontSize.md, color: colors.textPrimary },
    planOptions: { marginTop: spacing.sm },
    planLabel: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 6, fontWeight: "500" },
    chipBtn: {
      display: "flex", flexDirection: "row", flexWrap: "wrap",
      paddingHorizontal: 12, paddingVertical: 6,
      borderRadius: radius.full, borderWidth: 1, borderColor: colors.border,
      marginBottom: 6, marginRight: 6, alignSelf: "flex-start",
      backgroundColor: colors.surface,
    },
    chipBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    chipText: { fontSize: fontSize.sm, color: colors.textSecondary },
    chipTextActive: { color: colors.accent, fontWeight: "600" },
    channelTabs: { flexDirection: "row", gap: 8, marginBottom: spacing.sm },
    tab: {
      flex: 1, paddingVertical: 8, borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.border,
      alignItems: "center", backgroundColor: colors.surface,
    },
    tabActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tabText: { fontSize: fontSize.sm, color: colors.textSecondary },
    tabTextActive: { color: colors.accent, fontWeight: "600" },
    messageCard: { marginBottom: spacing.sm, minHeight: 120 },
    subjectLine: {
      fontSize: fontSize.sm, fontWeight: "600", color: colors.textSecondary,
      marginBottom: spacing.sm, paddingBottom: spacing.sm,
      borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border,
    },
    generatingRow: { flexDirection: "row", alignItems: "center", paddingVertical: spacing.sm },
    generatingText: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    messageText: { fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },
    actionRow: { flexDirection: "row", gap: 8, marginBottom: spacing.md },
    copyBtn: {
      flex: 1, height: 44, borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.borderStrong,
      alignItems: "center", justifyContent: "center",
    },
    copyBtnText: { fontSize: fontSize.sm, color: colors.textPrimary },
    regenBtn: {
      flex: 1, height: 44, borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.borderStrong,
      alignItems: "center", justifyContent: "center",
    },
    regenBtnText: { fontSize: fontSize.sm, color: colors.textPrimary },
    sendLabel: { fontSize: fontSize.sm, color: colors.textSecondary, fontWeight: "500", marginBottom: spacing.sm },
  });
}
