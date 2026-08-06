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
import { Ionicons } from "@expo/vector-icons";
import * as Clipboard from "expo-clipboard";
import { composeEmailWithOutcome, composeSMSWithOutcome } from "../utils/messaging";
import { emailHtmlFromText } from "../utils/emailHtml";
import { loadInvoices, saveInvoices, loadSettings } from "../utils/storage";
import { clearAutoEmailRequest } from "../utils/autoInvoice";
import {
  getStatus,
  generateOutreachMessage,
  resolvePaymentLink,
  fetchPaymentLink,
  getProviderKey,
  cachedLinkMatches,
  type DepositAsk,
} from "../utils/invoiceHelpers";
import { buildInvoicePdfFile } from "../utils/invoicePdfFile";
import { formatMoney } from "../utils/format";
import { supabase } from "../utils/supabase";
import { Badge, Button, Card, Divider } from "../components/UI";
import Field from "../components/Field";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
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
  const [preparingPdf, setPreparingPdf] = useState(false);
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
    setPreparingPdf(true);
    try {
      // buildInvoicePdfFile reports its own errors and resolves null on failure;
      // the catch is belt-and-braces so a PDF problem can never block the send.
      const pdfUri = await buildInvoicePdfFile(invoice, settings ?? {}).catch(() => null);
      const { opened, outcome } = await composeEmailWithOutcome({
        recipients: [invoice.email],
        subject: subject || `Payment reminder: ${invoice.number}`,
        // The editor keeps plain text; at send time the body is escaped and
        // any payment URL becomes a labeled anchor (utils/emailHtml).
        body: emailHtmlFromText(message),
        isHtml: true,
        attachments: pdfUri ? [pdfUri] : undefined,
      });
      if (outcome !== "notSent") {
        // A manual send supersedes a pending auto-email (2026-08-06 spec).
        // "unknown" counts as sent — same conservative read as the one-shot
        // flows; an explicit cancel keeps the auto-email alive.
        clearAutoEmailRequest(invoice.id).catch(() => {});
      }
      // Warned only after the composer closes: alerting first leaves a UIAlertController
      // on top, and iOS presents the mail sheet from the topmost controller, which can
      // stop it appearing at all. Skipped when composeEmail already alerted itself.
      // Copy stays neutral about the outcome — `opened` only tells us the sheet was
      // dismissed, not whether the draft was sent, saved, or cancelled.
      if (opened && !pdfUri) {
        Alert.alert(
          "PDF not attached",
          "Couldn't attach the invoice PDF, so the draft didn't include it."
        );
      }
    } catch (err: unknown) {
      reportError(err, { context: 'invoiceEmailCompose' });
      Alert.alert(
        "Couldn't open Mail",
        "Something went wrong opening your mail app. Please try again."
      );
    } finally {
      // Held across both awaits so a second tap can't open a duplicate draft.
      setPreparingPdf(false);
    }
  }

  async function sendSMS() {
    if (!invoice) return;
    const { outcome } = await composeSMSWithOutcome({ recipients: [invoice.phone], body: message });
    if (outcome !== "notSent") {
      // Texting the invoice manually also supersedes the pending auto-email.
      clearAutoEmailRequest(invoice.id).catch(() => {});
    }
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
    <View style={styles.container}>
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
                  <Ionicons
                    name={ch === "email" ? "mail-outline" : "chatbubble-outline"}
                    size={14}
                    color={channel === ch ? colors.accent : colors.textSecondary}
                  />
                  <Text style={[styles.tabText, channel === ch && styles.tabTextActive]}>
                    {ch === "email" ? "Email" : "Text message"}
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
              loading={channel === "email" && preparingPdf}
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
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    loading: { flex: 1, alignItems: "center", justifyContent: "center" },
    scroll: { padding: spacing.md, paddingBottom: 40, ...layout.contentColumn },
    summaryCard: { marginBottom: spacing.sm },
    summaryRow: { flexDirection: "row", alignItems: "flex-start" },
    customerName: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.lg, color: colors.textPrimary },
    invoiceMeta: { fontFamily: fonts.mono, fontSize: 11, color: colors.textSecondary, marginTop: 3 },
    autoReminderNote: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.success, marginTop: 4 },
    linkBadge: {
      marginTop: spacing.sm,
      backgroundColor: colors.successBg,
      borderRadius: radius.sm,
      paddingHorizontal: 10,
      paddingVertical: 4,
      alignSelf: "flex-start",
    },
    linkBadgeText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.success },
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
    generateLinkText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.xs, color: colors.accent },
    providerRow: {
      marginTop: spacing.sm,
      flexDirection: "row",
      alignItems: "center",
      flexWrap: "wrap",
      gap: spacing.sm,
    },
    providerRowLabel: { fontFamily: fonts.mono, fontSize: 10, color: colors.textMuted, textTransform: "uppercase", letterSpacing: 0.4 },
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
    providerChipText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.xs, color: colors.textSecondary },
    providerChipTextActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
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
    unitText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.md, color: colors.textSecondary },
    unitTextActive: { fontFamily: fonts.bodyBold, color: colors.accent },
    requestSummary: { fontFamily: fonts.bodyRegular, marginTop: spacing.sm, fontSize: fontSize.xs, color: colors.textSecondary },
    requestInvalid: { fontFamily: fonts.bodyRegular, marginTop: spacing.sm, fontSize: fontSize.xs, color: colors.warning },
    section: { marginBottom: spacing.sm },
    paidCard: { marginBottom: spacing.sm, alignItems: "center", paddingVertical: spacing.lg },
    paidTitle: { fontFamily: fonts.display, fontSize: fontSize.md, color: colors.success },
    paidSub: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, marginTop: 4 },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    planOptions: { marginTop: spacing.sm },
    planLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 6 },
    chipBtn: {
      display: "flex", flexDirection: "row", flexWrap: "wrap",
      paddingHorizontal: 12, paddingVertical: 6,
      borderRadius: radius.full, borderWidth: 1, borderColor: colors.border,
      marginBottom: 6, marginRight: 6, alignSelf: "flex-start",
      backgroundColor: colors.surface,
    },
    chipBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    chipText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    chipTextActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    channelTabs: { flexDirection: "row", gap: 8, marginBottom: spacing.sm },
    tab: {
      flex: 1, paddingVertical: 8, borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.border,
      alignItems: "center", justifyContent: "center",
      flexDirection: "row", gap: 6,
      backgroundColor: colors.surface,
    },
    tabActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tabText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    tabTextActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    messageCard: { marginBottom: spacing.sm, minHeight: 120 },
    subjectLine: {
      fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textSecondary,
      marginBottom: spacing.sm, paddingBottom: spacing.sm,
      borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border,
    },
    generatingRow: { flexDirection: "row", alignItems: "center", paddingVertical: spacing.sm },
    generatingText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    messageText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },
    actionRow: { flexDirection: "row", gap: 8, marginBottom: spacing.md },
    copyBtn: {
      // minHeight (not height): accessibility text grows the buttons instead
      // of clipping — components/Field.tsx pattern.
      flex: 1, minHeight: 44, borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.borderStrong,
      alignItems: "center", justifyContent: "center",
    },
    copyBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    regenBtn: {
      flex: 1, minHeight: 44, borderRadius: radius.md,
      borderWidth: 1, borderColor: colors.borderStrong,
      alignItems: "center", justifyContent: "center",
    },
    regenBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },
    sendLabel: { fontFamily: fonts.mono, fontSize: fontSize.xs, color: colors.textSecondary, textTransform: "uppercase", letterSpacing: 0.8, marginBottom: spacing.sm },
  });
}
