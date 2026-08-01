// screens/InvoicesScreen.tsx
// The main screen — shows all invoices, stats at the top, search bar, and
// status filter chips. Tapping an invoice opens its detail modal (payment
// history, outreach, PDF, edit); the top stat cards double as filter taps.

import React, { useState, useCallback, useEffect, useMemo } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Modal,
  ScrollView,
  Linking,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { loadInvoices, saveInvoices, loadSettings, loadJobs, saveJobs } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { getStatus, formatDate } from "../utils/invoiceHelpers";
import { summarizeInvoices, filterInvoices, isOverdue } from "../utils/invoiceStats";
import { formatMoney } from "../utils/format";
import { invoiceHtml } from "../utils/pdfTemplates";
import { exportPdf } from "../utils/pdfExport";
import { invoicePdfFilename } from "../utils/invoicePdfFile";
import { readPhotoAsDataUri } from "../utils/photoStorage";
import { track } from "../utils/analytics";
import { advanceJobsForPaidInvoices } from "../utils/jobStatus";
import { Badge, StatCard, EmptyState } from "../components/UI";
import { SearchField } from "../components/SearchField";
import { Fab } from "../components/Fab";
import { RecordPaymentSheet } from "../components/RecordPaymentSheet";
import { PaymentHistoryList } from "../components/PaymentHistoryList";
import {
  applyPayment,
  voidPayment,
  settleRemaining,
  newPaymentId,
  balanceDue,
  amountPaid,
  isPartlyPaid,
  isFullyPaid,
  isDepositSatisfied,
  effectivePayments,
  overpaidAmount,
} from "../utils/invoicePayments";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { Invoice, Settings, PaymentDraft } from "../types/models";
import type { InvoiceStackScreenProps } from "../types/navigation";

// Status chips across the top. "Unpaid" is any remaining balance; "Overdue"
// narrows that to past-due (same isOverdue the stat + row badges use, so the
// chip counts and the badges always agree).
const STATUS_FILTERS = [
  { key: "all",     label: "All" },
  { key: "unpaid",  label: "Unpaid" },
  { key: "overdue", label: "Overdue" },
  { key: "paid",    label: "Paid" },
] as const;
type StatusFilterKey = (typeof STATUS_FILTERS)[number]["key"];

function matchesStatusFilter(inv: Invoice, key: StatusFilterKey): boolean {
  switch (key) {
    case "unpaid":  return !isFullyPaid(inv);
    case "overdue": return isOverdue(inv);
    case "paid":    return isFullyPaid(inv);
    default:        return true;
  }
}

export default function InvoicesScreen({ navigation, route }: InvoiceStackScreenProps<'InvoiceList'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [search, setSearch] = useState<string>("");
  const [statusFilter, setStatusFilter] = useState<StatusFilterKey>("all");
  const [settings, setSettings] = useState<Partial<Settings>>({});
  const [viewingInvoice, setViewingInvoice] = useState<Invoice | null>(null);
  const [recordingFor, setRecordingFor] = useState<Invoice | null>(null);

  // Deep link from other tabs (Today's overdue rows): open the requested
  // invoice's detail modal once the list has loaded, then clear the param so
  // re-focusing the tab doesn't reopen it.
  const openInvoiceId = route.params?.openInvoiceId;
  useEffect(() => {
    if (!openInvoiceId) return;
    const target = invoices.find((i) => i.id === openInvoiceId);
    if (target) {
      setViewingInvoice(target);
      navigation.setParams({ openInvoiceId: undefined });
    }
  }, [openInvoiceId, invoices, navigation]);

  // useFocusEffect reloads invoices every time you come back to this screen,
  // so changes made on other screens (like marking paid) show up immediately.
  useFocusEffect(
    useCallback(() => {
      loadInvoices().then(setInvoices);
      loadSettings().then(setSettings);
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    const [invs, sets] = await Promise.all([loadInvoices(), loadSettings()]);
    setInvoices(invs);
    setSettings(sets);
  }, 'InvoicesScreen');

  const filtered: Invoice[] = filterInvoices(invoices, search).filter((inv) =>
    matchesStatusFilter(inv, statusFilter),
  );
  const { outstanding, overdueCount, collected } = summarizeInvoices(invoices);

  // Stat taps drive the filter; tapping the active one clears back to All.
  function toggleStatusFilter(key: StatusFilterKey) {
    setStatusFilter((current) => (current === key ? "all" : key));
  }

  async function handleExportPdf(inv: Invoice) {
    const logoDataUri = settings.logoPhoto
      ? await readPhotoAsDataUri(settings.logoPhoto)
      : null;
    const html = invoiceHtml(inv, settings, logoDataUri ?? undefined);
    const filename = invoicePdfFilename(inv).replace(/\.pdf$/, "");
    await exportPdf(html, filename);
  }

  function confirmDeleteInvoice(id: string, onSuccess?: () => void) {
    Alert.alert("Delete invoice?", "This cannot be undone.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          const updated = invoices.filter((i) => i.id !== id);
          setInvoices(updated);
          await saveInvoices(updated);
          syncNotifications();
          onSuccess?.();
        },
      },
    ]);
  }

  async function markPaid(id: string, onSuccess?: () => void) {
    const inv = invoices.find((i) => i.id === id);
    Alert.alert("Mark as paid?", "This will mark the invoice as collected.", [
      { text: "Cancel", style: "cancel" },
      {
        text: inv && isPartlyPaid(inv) ? "Mark rest paid" : "Mark paid",
        onPress: async () => {
          const today = new Date().toISOString().split('T')[0];
          const current = invoices.find((i) => i.id === id);
          if (!current) return;
          const settled = settleRemaining(current, today);
          if (settled === current) {
            // Already fully paid — settleRemaining is documented to no-op here.
            // Nothing changed, so there's nothing to save or track.
            onSuccess?.();
            return;
          }
          const updated = invoices.map((i) => (i.id === id ? settled : i));
          setInvoices(updated);
          await saveInvoices(updated);
          await reconcileJobsWith(updated);
          track('payment_recorded', {
            amount: balanceDue(current),
            method: 'other',
            balanceRemaining: 0,
          });
          track('invoice_paid', { amount: current.amount });
          syncNotifications();
          onSuccess?.();
        },
      },
    ]);
  }

  async function handleRecordPayment(invoice: Invoice, draft: PaymentDraft) {
    // Re-resolve against the live list rather than the snapshot captured when
    // the sheet opened: a double-tap during this await would otherwise
    // re-derive from that stale snapshot and overwrite the list that already
    // contains the first payment, silently discarding it.
    const current = invoices.find((i) => i.id === invoice.id) ?? invoice;
    const next = applyPayment(current, { id: newPaymentId(), ...draft });
    const updated = invoices.map((i) => (i.id === invoice.id ? next : i));
    setInvoices(updated);
    await saveInvoices(updated);
    await reconcileJobsWith(updated);
    track('payment_recorded', {
      amount: draft.amount,
      method: draft.method,
      balanceRemaining: balanceDue(next),
    });
    if (isFullyPaid(next) && !isFullyPaid(current)) {
      track('invoice_paid', { amount: next.amount });
    }
    syncNotifications();
    setRecordingFor(null);
  }

  // Jobs follow invoice truth (FA-038): after any save that can settle an
  // invoice, advance its linked job invoiced -> paid. Same-reference return
  // means nothing changed and the save is skipped.
  async function reconcileJobsWith(updatedInvoices: Invoice[]) {
    const jobs = await loadJobs();
    const advanced = advanceJobsForPaidInvoices(jobs, updatedInvoices);
    if (advanced !== jobs) await saveJobs(advanced);
  }

  function confirmVoid(invoice: Invoice, paymentId: string) {
    const payment = effectivePayments(invoice).find((p) => p.id === paymentId);
    if (!payment) return;
    // Only for the dialog's balance text — computed once, up front, with
    // whatever date the dialog happens to be built on. The write below
    // recomputes its own date at confirm time, so a void confirmed across
    // midnight isn't recorded against yesterday.
    const after = voidPayment(invoice, paymentId, new Date().toISOString().split('T')[0]);
    Alert.alert(
      "Void this payment?",
      `This can't be undone. ${invoice.number} will go back to ${formatMoney(balanceDue(after))} due.\n\nTo correct a mistake, record a new payment.`,
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Void payment",
          style: "destructive",
          onPress: async () => {
            // Same staleness concern as handleRecordPayment: re-resolve against
            // the live list rather than the snapshot captured when the modal
            // opened. The void date is also recomputed here, at confirm time,
            // rather than reusing the dialog-build-time date above.
            const current = invoices.find((i) => i.id === invoice.id) ?? invoice;
            const confirmVoidedAt = new Date().toISOString().split('T')[0];
            const confirmedAfter = voidPayment(current, paymentId, confirmVoidedAt);
            const updated = invoices.map((i) => (i.id === invoice.id ? confirmedAfter : i));
            setInvoices(updated);
            await saveInvoices(updated);
            track('payment_voided', { amount: payment.amount, method: payment.method });
            syncNotifications();
            // Refresh the modal's snapshot since it renders from viewingInvoice,
            // not from the live invoices array. Without this, the modal would show
            // pre-void state (payment history, balance) until closed and reopened.
            setViewingInvoice(confirmedAfter);
          },
        },
      ]
    );
  }

  function renderInvoice({ item: inv }: { item: Invoice }) {
    const status = getStatus(inv);
    const accentColor = ({
      danger:  colors.danger,
      warning: colors.warning,
      success: colors.success,
      accent:  colors.accent,
    } as Record<string, string>)[status.color];

    return (
      <TouchableOpacity
        style={[styles.invoiceCard, { borderLeftColor: accentColor }]}
        onPress={() => setViewingInvoice(inv)}
        activeOpacity={0.8}
      >
        <View style={styles.invoiceTop}>
          <Text style={styles.customerName} numberOfLines={1}>
            {inv.customer}
          </Text>
          {overpaidAmount(inv) > 0 ? (
            <Text style={styles.amount}>
              {formatMoney(inv.amount)} · overpaid by {formatMoney(overpaidAmount(inv))}
            </Text>
          ) : isPartlyPaid(inv) ? (
            <Text style={styles.amount}>
              {formatMoney(balanceDue(inv))} due · {formatMoney(amountPaid(inv))} paid
            </Text>
          ) : (
            <Text style={styles.amount}>{formatMoney(inv.amount)}</Text>
          )}
        </View>
        <View style={styles.invoiceMeta}>
          <Badge label={status.label} color={status.color} />
          <Text style={styles.metaText}>{inv.number}</Text>
          <Text style={styles.descText} numberOfLines={1}>
            {inv.desc}
          </Text>
        </View>
        <View style={styles.invoiceActions}>
          <TouchableOpacity
            style={styles.editBtn}
            onPress={() => navigation.navigate("AddInvoice", { invoiceId: inv.id })}
          >
            <Text style={styles.editBtnText}>Edit</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.editBtn} onPress={() => handleExportPdf(inv)}>
            <Text style={styles.editBtnText}>PDF</Text>
          </TouchableOpacity>
          {!isFullyPaid(inv) && (
            <TouchableOpacity style={styles.editBtn} onPress={() => setRecordingFor(inv)}>
              <Text style={styles.editBtnText}>Record payment</Text>
            </TouchableOpacity>
          )}
          {!isFullyPaid(inv) && (
            <TouchableOpacity style={styles.paidBtn} onPress={() => markPaid(inv.id)}>
              <Text style={styles.paidBtnText}>Mark paid</Text>
            </TouchableOpacity>
          )}
        </View>
      </TouchableOpacity>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      {/* Stats row — each stat doubles as a filter tap */}
      <View style={styles.statsRow}>
        <StatCard
          label="Outstanding"
          value={formatMoney(outstanding)}
          valueColor={colors.danger}
          onPress={() => toggleStatusFilter("unpaid")}
          accessibilityHint="Filters the list to unpaid invoices"
        />
        <View style={{ width: spacing.sm }} />
        <StatCard
          label="Overdue"
          value={String(overdueCount)}
          valueColor={colors.warning}
          onPress={() => toggleStatusFilter("overdue")}
          accessibilityHint="Filters the list to overdue invoices"
        />
        <View style={{ width: spacing.sm }} />
        <StatCard
          label="Collected"
          value={formatMoney(collected)}
          valueColor={colors.success}
          onPress={() => toggleStatusFilter("paid")}
          accessibilityHint="Filters the list to paid invoices"
        />
      </View>

      {/* Search bar */}
      <View style={styles.searchRow}>
        <SearchField
          value={search}
          onChangeText={setSearch}
          placeholder="Search customer or invoice #"
          accessibilityLabel="Search invoices"
        />
      </View>

      {/* Status filter chips */}
      <View style={styles.filterRow}>
        {STATUS_FILTERS.map((f) => {
          const count = f.key === "all"
            ? invoices.length
            : invoices.filter((inv) => matchesStatusFilter(inv, f.key)).length;
          return (
            <TouchableOpacity
              key={f.key}
              style={[styles.filterTab, statusFilter === f.key && styles.filterTabActive]}
              onPress={() => setStatusFilter(f.key)}
              accessibilityRole="tab"
              accessibilityLabel={`${f.label}${count > 0 ? `, ${count}` : ''}`}
              accessibilityState={{ selected: statusFilter === f.key }}
            >
              <Text style={[styles.filterTabText, statusFilter === f.key && styles.filterTabTextActive]} maxFontSizeMultiplier={1.4}>
                {f.label} {count > 0 ? `(${count})` : ""}
              </Text>
            </TouchableOpacity>
          );
        })}
      </View>

      {/* Invoice list */}
      <FlatList
        refreshing={refreshing}
        onRefresh={onRefresh}
        data={filtered}
        keyExtractor={(item) => item.id}
        renderItem={renderInvoice}
        contentContainerStyle={styles.listContent}
        ListEmptyComponent={
          invoices.length === 0 ? (
            <EmptyState
              icon="document-text-outline"
              message="No invoices yet. Create one to start collecting."
              actionLabel="+ New invoice"
              onAction={() => navigation.navigate("AddInvoice", {})}
            />
          ) : (
            <EmptyState icon="document-text-outline" message="No invoices match this filter." />
          )
        }
        showsVerticalScrollIndicator={false}
      />

      {/* Floating add button */}
      <Fab onPress={() => navigation.navigate("AddInvoice", {})} accessibilityLabel="Add new invoice" />

      {/* Invoice detail modal */}
      <Modal
        visible={!!viewingInvoice}
        animationType="slide"
        transparent
        onRequestClose={() => setViewingInvoice(null)}
      >
        <TouchableOpacity
          style={styles.modalBackdrop}
          activeOpacity={1}
          onPress={() => setViewingInvoice(null)}
        />
        {viewingInvoice && (() => {
          const inv = viewingInvoice;
          const status = getStatus(inv);
          const accentColor = ({
            danger:  colors.danger,
            warning: colors.warning,
            success: colors.success,
            accent:  colors.accent,
          } as Record<string, string>)[status.color];

          return (
            <View style={styles.modalSheet}>
              {/* Handle + close */}
              <View style={styles.modalHeader}>
                <View style={styles.modalHandle} />
                <TouchableOpacity onPress={() => setViewingInvoice(null)} style={styles.modalCloseBtn}>
                  <Ionicons name="close" size={20} color={colors.textMuted} />
                </TouchableOpacity>
              </View>

              <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.modalBody}>
                {/* Status + number */}
                <View style={styles.modalTopRow}>
                  <Text style={styles.modalInvoiceNum}>{inv.number}</Text>
                  <Badge label={status.label} color={status.color} />
                </View>

                {/* Customer + amount */}
                <Text style={styles.modalCustomer}>{inv.customer}</Text>
                {overpaidAmount(inv) > 0 ? (
                  <Text style={[styles.modalAmount, { color: accentColor }]}>
                    {formatMoney(inv.amount)} · overpaid by {formatMoney(overpaidAmount(inv))}
                  </Text>
                ) : isPartlyPaid(inv) ? (
                  <Text style={[styles.modalAmount, { color: accentColor }]}>
                    {formatMoney(balanceDue(inv))} due · {formatMoney(amountPaid(inv))} paid
                  </Text>
                ) : (
                  <Text style={[styles.modalAmount, { color: accentColor }]}>
                    {formatMoney(inv.amount)}
                  </Text>
                )}

                {/* Due date */}
                {inv.due ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Due</Text>
                    <Text style={styles.modalDetailValue}>{formatDate(inv.due)}</Text>
                  </View>
                ) : null}

                {/* Outstanding deposit ask — hidden once the invoice settles,
                    where the distinction no longer means anything. */}
                {inv.depositRequest && !isFullyPaid(inv) ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Deposit requested</Text>
                    <Text style={styles.modalDetailValue}>
                      {formatMoney(inv.depositRequest.amount)}
                      {inv.depositRequest.percent ? ` (${inv.depositRequest.percent}%)` : ""}
                      {" · "}
                      {isDepositSatisfied(inv) ? "received" : "unpaid"}
                    </Text>
                  </View>
                ) : null}

                {/* Description */}
                {inv.desc ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Description</Text>
                    <Text style={[styles.modalDetailValue, { flex: 1, textAlign: "right" }]}>{inv.desc}</Text>
                  </View>
                ) : null}

                {/* Contact */}
                {inv.email ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Email</Text>
                    <TouchableOpacity onPress={() => Linking.openURL(`mailto:${inv.email}`)}>
                      <Text style={[styles.modalDetailValue, styles.modalLink]}>{inv.email}</Text>
                    </TouchableOpacity>
                  </View>
                ) : null}
                {inv.phone ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Phone</Text>
                    <TouchableOpacity onPress={() => Linking.openURL(`tel:${inv.phone}`)}>
                      <Text style={[styles.modalDetailValue, styles.modalLink]}>{inv.phone}</Text>
                    </TouchableOpacity>
                  </View>
                ) : null}

                <View style={styles.modalDivider} />
                <Text style={styles.modalDetailLabel}>Payment history</Text>
                <PaymentHistoryList invoice={inv} onVoid={(pid) => confirmVoid(inv, pid)} />

                {/* Actions */}
                <View style={styles.modalDivider} />

                {!isFullyPaid(inv) && (
                  <TouchableOpacity
                    style={styles.modalActionPrimary}
                    onPress={() => { setViewingInvoice(null); navigation.navigate("Outreach", { invoiceId: inv.id }); }}
                  >
                    <Text style={styles.modalActionPrimaryText}>Send outreach →</Text>
                  </TouchableOpacity>
                )}

                <View style={styles.modalActionRow}>
                  <TouchableOpacity
                    style={styles.modalActionBtn}
                    onPress={() => { setViewingInvoice(null); navigation.navigate("AddInvoice", { invoiceId: inv.id }); }}
                  >
                    <Text style={styles.modalActionBtnText}>Edit</Text>
                  </TouchableOpacity>
                  <TouchableOpacity
                    style={styles.modalActionBtn}
                    onPress={() => handleExportPdf(inv)}
                  >
                    <Text style={styles.modalActionBtnText}>Save PDF</Text>
                  </TouchableOpacity>
                  {!isFullyPaid(inv) && (
                    <TouchableOpacity
                      style={[styles.modalActionBtn, styles.modalActionBtnPaid]}
                      onPress={() => markPaid(inv.id, () => setViewingInvoice(null))}
                    >
                      <Text style={[styles.modalActionBtnText, { color: colors.success, fontFamily: fonts.bodySemiBold }]}>
                        Mark paid
                      </Text>
                    </TouchableOpacity>
                  )}
                  {!isFullyPaid(inv) && (
                    <TouchableOpacity
                      style={styles.modalActionBtn}
                      onPress={() => { setViewingInvoice(null); setRecordingFor(inv); }}
                    >
                      <Text style={styles.modalActionBtnText}>Record payment</Text>
                    </TouchableOpacity>
                  )}
                </View>

                <TouchableOpacity
                  style={styles.modalDeleteBtn}
                  onPress={() => confirmDeleteInvoice(inv.id, () => setViewingInvoice(null))}
                >
                  <Text style={styles.modalDeleteBtnText}>Delete invoice</Text>
                </TouchableOpacity>
              </ScrollView>
            </View>
          );
        })()}
      </Modal>

      {recordingFor && (
        <RecordPaymentSheet
          visible
          invoice={recordingFor}
          onSave={(draft) => handleRecordPayment(recordingFor, draft)}
          onClose={() => setRecordingFor(null)}
        />
      )}
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: {
      flex: 1,
      backgroundColor: colors.background,
    },
    statsRow: {
      flexDirection: "row",
      paddingHorizontal: spacing.md,
      paddingTop: spacing.md,
      paddingBottom: spacing.sm,
    },
    searchRow: {
      paddingHorizontal: spacing.md,
      paddingBottom: spacing.sm,
    },
    filterRow: {
      flexDirection: "row",
      paddingHorizontal: spacing.md,
      gap: 6,
      marginBottom: spacing.sm,
    },
    filterTab: {
      paddingHorizontal: 12,
      paddingVertical: 6,
      borderRadius: radius.full,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
    },
    filterTabActive: {
      backgroundColor: colors.accent,
      borderColor: colors.accent,
    },
    filterTabText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    filterTabTextActive: { fontFamily: fonts.bodySemiBold, color: colors.textOnAccent },
    listContent: {
      paddingHorizontal: spacing.md,
      paddingBottom: 100,
    },
    invoiceCard: {
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.md,
      marginBottom: spacing.sm,
      borderLeftWidth: 4,
      ...shadow.card,
    },
    invoiceTop: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "flex-start",
      marginBottom: 6,
    },
    customerName: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      flex: 1,
      marginRight: spacing.sm,
    },
    amount: {
      fontFamily: fonts.display,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      fontVariant: ["tabular-nums"],
    },
    invoiceMeta: {
      flexDirection: "row",
      alignItems: "center",
      gap: 8,
      flexWrap: "wrap",
      marginBottom: 8,
    },
    metaText: {
      fontFamily: fonts.mono,
      fontSize: 11,
      color: colors.textSecondary,
    },
    descText: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      flex: 1,
    },
    invoiceActions: {
      flexDirection: "row",
      flexWrap: "wrap",
      gap: 8,
      justifyContent: "flex-end",
    },
    editBtn: {
      paddingHorizontal: 12,
      paddingVertical: 5,
      borderRadius: radius.sm,
      borderWidth: 1,
      borderColor: colors.borderStrong,
    },
    editBtnText: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textPrimary,
    },
    paidBtn: {
      paddingHorizontal: 12,
      paddingVertical: 5,
      borderRadius: radius.sm,
      backgroundColor: colors.success,
    },
    paidBtnText: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.textOnAccent,
    },
    // Invoice detail modal
    modalBackdrop: {
      flex: 1,
      backgroundColor: "rgba(0,0,0,0.4)",
    },
    modalSheet: {
      backgroundColor: colors.background,
      borderTopLeftRadius: radius.xl,
      borderTopRightRadius: radius.xl,
      maxHeight: "80%",
      ...shadow.card,
    },
    modalHeader: {
      alignItems: "center",
      paddingTop: spacing.sm,
      paddingHorizontal: spacing.md,
      paddingBottom: spacing.xs,
      flexDirection: "row",
      justifyContent: "center",
    },
    modalHandle: {
      width: 36,
      height: 4,
      borderRadius: 2,
      backgroundColor: colors.border,
    },
    modalCloseBtn: {
      position: "absolute",
      right: spacing.md,
      top: spacing.sm,
      padding: 4,
      minHeight: 44,
      minWidth: 44,
      justifyContent: "center",
      alignItems: "center",
    },
    modalBody: {
      padding: spacing.md,
      paddingBottom: 40,
    },
    modalTopRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: 6,
    },
    modalInvoiceNum: {
      fontFamily: fonts.mono,
      fontSize: 11,
      color: colors.textMuted,
      letterSpacing: 0.4,
    },
    modalCustomer: {
      fontFamily: fonts.display,
      fontSize: fontSize.xl,
      color: colors.textPrimary,
      marginBottom: 4,
    },
    modalAmount: {
      fontFamily: fonts.display,
      fontSize: 36,
      letterSpacing: -0.5,
      marginBottom: spacing.md,
      fontVariant: ["tabular-nums"],
    },
    modalDetailRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "flex-start",
      paddingVertical: 8,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.border,
    },
    modalDetailLabel: {
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.textMuted,
      textTransform: "uppercase",
      letterSpacing: 0.4,
    },
    modalDetailValue: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textPrimary,
    },
    modalLink: {
      color: colors.accent,
    },
    modalDivider: {
      height: StyleSheet.hairlineWidth,
      backgroundColor: colors.border,
      marginVertical: spacing.md,
    },
    modalActionPrimary: {
      backgroundColor: colors.accent,
      borderRadius: radius.md,
      paddingVertical: 14,
      alignItems: "center",
      marginBottom: spacing.sm,
    },
    modalActionPrimaryText: {
      fontFamily: fonts.bodyBold,
      color: colors.textOnAccent,
      fontSize: fontSize.md,
    },
    modalActionRow: {
      flexDirection: "row",
      gap: 8,
    },
    modalActionBtn: {
      flex: 1,
      paddingVertical: 10,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.borderStrong,
      alignItems: "center",
    },
    modalActionBtnPaid: {
      borderColor: colors.success + "60",
      backgroundColor: colors.successBg,
    },
    modalActionBtnText: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textPrimary,
    },
    modalDeleteBtn: {
      marginTop: spacing.md,
      paddingVertical: 10,
      alignItems: "center",
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.danger + "40",
      backgroundColor: colors.dangerBg,
    },
    modalDeleteBtnText: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.danger,
    },

  });
}
