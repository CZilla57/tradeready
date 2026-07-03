// screens/InvoicesScreen.js
// The main screen — shows all invoices, stats at the top, search bar.
// Tapping an invoice opens the Outreach screen for that invoice.

import React, { useState, useCallback } from "react";
import {
  View,
  Text,
  FlatList,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadInvoices, saveInvoices, loadSettings } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { getStatus, formatCurrency, formatDate } from "../utils/invoiceHelpers";
import { invoiceHtml } from "../utils/pdfTemplates";
import { exportPdf } from "../utils/pdfExport";
import { Badge, StatCard, EmptyState, Button } from "../components/UI";
import { colors, spacing, radius, fontSize, shadow } from "../utils/theme";

export default function InvoicesScreen({ navigation }) {
  const [invoices, setInvoices] = useState([]);
  const [search, setSearch] = useState("");
  const [settings, setSettings] = useState({});

  // useFocusEffect reloads invoices every time you come back to this screen,
  // so changes made on other screens (like marking paid) show up immediately.
  useFocusEffect(
    useCallback(() => {
      loadInvoices().then(setInvoices);
      loadSettings().then(setSettings);
    }, [])
  );

  const filtered = invoices.filter(
    (inv) =>
      inv.customer.toLowerCase().includes(search.toLowerCase()) ||
      inv.number.toLowerCase().includes(search.toLowerCase())
  );

  const outstanding = invoices
    .filter((i) => !i.paid)
    .reduce((sum, i) => sum + i.amount, 0);

  const overdueCount = invoices.filter(
    (i) => !i.paid && new Date(i.due) < new Date()
  ).length;

  const collected = invoices
    .filter((i) => i.paid)
    .reduce((sum, i) => sum + i.amount, 0);

  async function handleExportPdf(inv) {
    const html = invoiceHtml(inv, settings);
    const filename = `Invoice-${inv.number || inv.id}-${inv.customer.replace(/\s+/g, "-")}`;
    await exportPdf(html, filename);
  }

  async function markPaid(id) {
    Alert.alert("Mark as paid?", "This will mark the invoice as collected.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Mark paid",
        onPress: async () => {
          const updated = invoices.map((i) => (i.id === id ? { ...i, paid: true } : i));
          setInvoices(updated);
          await saveInvoices(updated);
          syncNotifications(); // cancels this invoice's scheduled reminders
        },
      },
    ]);
  }

  function renderInvoice({ item: inv }) {
    const status = getStatus(inv);
    const accentColor = {
      danger: colors.danger,
      warning: colors.warning,
      success: colors.success,
      accent: colors.accent,
    }[status.color];

    return (
      <TouchableOpacity
        style={[styles.invoiceCard, { borderLeftColor: accentColor }]}
        onPress={() => navigation.navigate("Outreach", { invoiceId: inv.id })}
        activeOpacity={0.8}
      >
        <View style={styles.invoiceTop}>
          <Text style={styles.customerName} numberOfLines={1}>
            {inv.customer}
          </Text>
          <Text style={styles.amount}>{formatCurrency(inv.amount)}</Text>
        </View>
        <View style={styles.invoiceMeta}>
          <Badge label={status.label} color={status.color} />
          <Text style={styles.metaText}>{inv.number}</Text>
          <Text style={[styles.metaText, styles.descText]} numberOfLines={1}>
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
        <StatCard label="Outstanding" value={formatCurrency(outstanding)} valueColor={colors.danger} />
        <View style={{ width: spacing.sm }} />
        <StatCard label="Overdue" value={String(overdueCount)} valueColor={colors.warning} />
        <View style={{ width: spacing.sm }} />
        <StatCard label="Collected" value={formatCurrency(collected)} valueColor={colors.success} />
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
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
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
