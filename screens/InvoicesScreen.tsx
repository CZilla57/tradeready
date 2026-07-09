// screens/InvoicesScreen.tsx
// The main screen — shows all invoices, stats at the top, search bar.
// Tapping an invoice opens the Outreach screen for that invoice.

import React, { useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  FlatList,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Modal,
  ScrollView,
  Linking,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadInvoices, saveInvoices, loadSettings } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { getStatus, formatDate } from "../utils/invoiceHelpers";
import { summarizeInvoices, filterInvoices } from "../utils/invoiceStats";
import { formatMoney } from "../utils/format";
import { invoiceHtml } from "../utils/pdfTemplates";
import { exportPdf } from "../utils/pdfExport";
import { readPhotoAsDataUri } from "../utils/photoStorage";
import { Badge, StatCard, EmptyState } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Invoice, Settings } from "../types/models";

export default function InvoicesScreen({ navigation }: { navigation: any }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [search, setSearch] = useState<string>("");
  const [settings, setSettings] = useState<Partial<Settings>>({});
  const [viewingInvoice, setViewingInvoice] = useState<Invoice | null>(null);

  // useFocusEffect reloads invoices every time you come back to this screen,
  // so changes made on other screens (like marking paid) show up immediately.
  useFocusEffect(
    useCallback(() => {
      loadInvoices().then(setInvoices);
      loadSettings().then(setSettings);
    }, [])
  );

  const filtered: Invoice[] = filterInvoices(invoices, search);
  const { outstanding, overdueCount, collected } = summarizeInvoices(invoices);

  async function handleExportPdf(inv: Invoice) {
    const logoDataUri = settings.logoPhoto
      ? await readPhotoAsDataUri(settings.logoPhoto)
      : null;
    const html = invoiceHtml(inv, settings, logoDataUri ?? undefined);
    const filename = `Invoice-${inv.number || inv.id}-${(inv as any).customer.replace(/\s+/g, "-")}`;
    await exportPdf(html, filename);
  }

  async function markPaid(id: string, onSuccess?: () => void) {
    Alert.alert("Mark as paid?", "This will mark the invoice as collected.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Mark paid",
        onPress: async () => {
          const today = new Date().toISOString().split('T')[0];
          const updated = invoices.map((i) => (i.id === id ? { ...i, paid: true, paidAt: today } : i));
          setInvoices(updated);
          await saveInvoices(updated);
          syncNotifications();
          onSuccess?.();
        },
      },
    ]);
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
            {(inv as any).customer}
          </Text>
          <Text style={styles.amount}>{formatMoney((inv as any).amount)}</Text>
        </View>
        <View style={styles.invoiceMeta}>
          <Badge label={status.label} color={status.color} />
          <Text style={styles.metaText}>{inv.number}</Text>
          <Text style={[styles.metaText, styles.descText]} numberOfLines={1}>
            {(inv as any).desc}
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
          {!inv.paid && (
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
      {/* Stats row */}
      <View style={styles.statsRow}>
        <StatCard label="Outstanding" value={formatMoney(outstanding)} valueColor={colors.danger} />
        <View style={{ width: spacing.sm }} />
        <StatCard label="Overdue" value={String(overdueCount)} valueColor={colors.warning} />
        <View style={{ width: spacing.sm }} />
        <StatCard label="Collected" value={formatMoney(collected)} valueColor={colors.success} />
      </View>

      {/* Search bar */}
      <View style={styles.searchRow}>
        <TextInput
          style={styles.searchInput}
          placeholder="Search customer or invoice #"
          placeholderTextColor={colors.textMuted}
          value={search}
          onChangeText={setSearch}
          clearButtonMode="while-editing"
        />
      </View>

      {/* Invoice list */}
      <FlatList
        data={filtered}
        keyExtractor={(item) => item.id}
        renderItem={renderInvoice}
        contentContainerStyle={styles.listContent}
        ListEmptyComponent={
          <EmptyState message="No invoices yet. Tap + to add your first one." />
        }
        showsVerticalScrollIndicator={false}
      />

      {/* Floating add button */}
      <TouchableOpacity
        style={styles.fab}
        onPress={() => navigation.navigate("AddInvoice", {})}
        activeOpacity={0.85}
      >
        <Text style={styles.fabText}>+</Text>
      </TouchableOpacity>

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
                  <Text style={styles.modalCloseText}>✕</Text>
                </TouchableOpacity>
              </View>

              <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.modalBody}>
                {/* Status + number */}
                <View style={styles.modalTopRow}>
                  <Text style={styles.modalInvoiceNum}>{inv.number}</Text>
                  <Badge label={status.label} color={status.color} />
                </View>

                {/* Customer + amount */}
                <Text style={styles.modalCustomer}>{(inv as any).customer}</Text>
                <Text style={[styles.modalAmount, { color: accentColor }]}>
                  {formatMoney((inv as any).amount)}
                </Text>

                {/* Due date */}
                {inv.due ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Due</Text>
                    <Text style={styles.modalDetailValue}>{formatDate(inv.due)}</Text>
                  </View>
                ) : null}

                {/* Description */}
                {(inv as any).desc ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Description</Text>
                    <Text style={[styles.modalDetailValue, { flex: 1, textAlign: "right" }]}>{(inv as any).desc}</Text>
                  </View>
                ) : null}

                {/* Contact */}
                {(inv as any).email ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Email</Text>
                    <TouchableOpacity onPress={() => Linking.openURL(`mailto:${(inv as any).email}`)}>
                      <Text style={[styles.modalDetailValue, styles.modalLink]}>{(inv as any).email}</Text>
                    </TouchableOpacity>
                  </View>
                ) : null}
                {(inv as any).phone ? (
                  <View style={styles.modalDetailRow}>
                    <Text style={styles.modalDetailLabel}>Phone</Text>
                    <TouchableOpacity onPress={() => Linking.openURL(`tel:${(inv as any).phone}`)}>
                      <Text style={[styles.modalDetailValue, styles.modalLink]}>{(inv as any).phone}</Text>
                    </TouchableOpacity>
                  </View>
                ) : null}

                {/* Actions */}
                <View style={styles.modalDivider} />

                {!inv.paid && (
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
                  {!inv.paid && (
                    <TouchableOpacity
                      style={[styles.modalActionBtn, styles.modalActionBtnPaid]}
                      onPress={() => markPaid(inv.id, () => setViewingInvoice(null))}
                    >
                      <Text style={[styles.modalActionBtnText, { color: colors.success, fontWeight: "600" }]}>
                        Mark paid
                      </Text>
                    </TouchableOpacity>
                  )}
                </View>
              </ScrollView>
            </View>
          );
        })()}
      </Modal>
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
    searchInput: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      height: 40,
      paddingHorizontal: spacing.md,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      ...shadow.card,
    },
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
      fontSize: fontSize.md,
      fontWeight: "600",
      color: colors.textPrimary,
      flex: 1,
      marginRight: spacing.sm,
    },
    amount: {
      fontSize: fontSize.md,
      fontWeight: "600",
      color: colors.textPrimary,
    },
    invoiceMeta: {
      flexDirection: "row",
      alignItems: "center",
      gap: 8,
      flexWrap: "wrap",
      marginBottom: 8,
    },
    metaText: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
    descText: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      flex: 1,
    },
    invoiceActions: {
      flexDirection: "row",
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
      fontSize: fontSize.sm,
      color: colors.textOnAccent,
      fontWeight: "600",
    },
    // Invoice detail modal
    modalBackdrop: {
      flex: 1,
      backgroundColor: "rgba(0,0,0,0.4)",
    },
    modalSheet: {
      backgroundColor: colors.background,
      borderTopLeftRadius: (radius as any).xl ?? 20,
      borderTopRightRadius: (radius as any).xl ?? 20,
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
    },
    modalCloseText: {
      fontSize: fontSize.md,
      color: colors.textMuted,
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
      fontSize: fontSize.sm,
      color: colors.textMuted,
      fontWeight: "500",
    },
    modalCustomer: {
      fontSize: fontSize.xl,
      fontWeight: "700",
      color: colors.textPrimary,
      marginBottom: 4,
    },
    modalAmount: {
      fontSize: 36,
      fontWeight: "700",
      letterSpacing: -1,
      marginBottom: spacing.md,
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
      fontSize: fontSize.sm,
      color: colors.textMuted,
      fontWeight: "500",
    },
    modalDetailValue: {
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
      color: colors.textOnAccent,
      fontSize: fontSize.md,
      fontWeight: "700",
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
      fontSize: fontSize.sm,
      color: colors.textPrimary,
    },

    fab: {
      position: "absolute",
      right: spacing.lg,
      bottom: spacing.xl,
      width: 56,
      height: 56,
      borderRadius: 28,
      backgroundColor: colors.accent,
      alignItems: "center",
      justifyContent: "center",
      shadowColor: colors.accent,
      shadowOffset: { width: 0, height: 4 },
      shadowOpacity: 0.35,
      shadowRadius: 8,
      elevation: 6,
    },
    fabText: {
      color: colors.textOnAccent,
      fontSize: 28,
      lineHeight: 32,
      fontWeight: "300",
    },
  });
}
