// screens/GlobalSearchScreen.tsx
// Global search from Today: one box across jobs, customers, and invoices.
// Matching/ordering lives in utils/globalSearch.ts; this screen loads the
// collections once on focus and routes each result to its home tab —
// JobDetail, CustomerDetail (via the customer-list rollup the route expects),
// or the invoice detail modal via InvoiceList's openInvoiceId deep link.

import React, { useCallback, useMemo, useState } from "react";
import { View, Text, ScrollView, TouchableOpacity, StyleSheet } from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { Ionicons } from "@expo/vector-icons";
import { loadJobs, loadCustomers, loadInvoices } from "../utils/storage";
import { searchAll } from "../utils/globalSearch";
import { buildCustomerList } from "../utils/customerList";
import { JOB_STATUSES } from "../utils/pricingEngine";
import { getStatus } from "../utils/invoiceHelpers";
import { formatMoney } from "../utils/format";
import { Badge, EmptyState } from "../components/UI";
import { SearchField } from "../components/SearchField";
import { spacing, radius, fontSize, fonts, layout } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Customer, Invoice, Job } from "../types/models";
import type { TodayStackScreenProps } from "../types/navigation";

export default function GlobalSearchScreen({ navigation }: TodayStackScreenProps<'Search'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [query, setQuery] = useState("");
  const [jobs, setJobs] = useState<Job[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);

  useFocusEffect(
    useCallback(() => {
      let active = true;
      Promise.all([loadJobs(), loadCustomers(), loadInvoices()]).then(([j, c, i]) => {
        if (!active) return;
        setJobs(j);
        setCustomers(c);
        setInvoices(i);
      });
      return () => { active = false; };
    }, [])
  );

  const results = useMemo(
    () => searchAll({ jobs, customers, invoices }, query),
    [jobs, customers, invoices, query]
  );

  function openJob(job: Job) {
    navigation.navigate("Jobs", { screen: "JobDetail", initial: false, params: { jobId: job.id } });
  }

  function openInvoice(inv: Invoice) {
    navigation.navigate("Invoices", { screen: "InvoiceList", params: { openInvoiceId: inv.id } });
  }

  function openCustomer(customer: Customer) {
    // CustomerDetail consumes the rollup entry (invoices, totals), not the
    // bare record — build it the same way CustomersScreen does.
    const entry = buildCustomerList(invoices, customers).find((e) => e.id === customer.id);
    if (entry) {
      navigation.navigate("Customers", { screen: "CustomerDetail", initial: false, params: { customer: entry } });
    } else {
      navigation.navigate("Customers", { screen: "CustomerList" });
    }
  }

  const hasQuery = query.trim().length > 0;

  return (
    <View style={styles.container}>
      <View style={styles.searchRow}>
        <SearchField
          value={query}
          onChangeText={setQuery}
          placeholder="Search jobs, customers, invoices"
          accessibilityLabel="Search everything"
          autoFocus
        />
      </View>

      <ScrollView
        contentContainerStyle={styles.scroll}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {hasQuery && results.total === 0 && (
          <EmptyState icon="search-outline" message={`Nothing matches “${query.trim()}”.`} />
        )}

        {results.jobs.total > 0 && (
          <>
            <Text style={styles.sectionLabel}>Jobs</Text>
            {results.jobs.items.map((job) => (
              <TouchableOpacity
                key={job.id}
                style={styles.row}
                onPress={() => openJob(job)}
                accessibilityRole="button"
                accessibilityLabel={`Job: ${job.title}, ${job.customerName}`}
              >
                <Ionicons name="hammer-outline" size={18} color={colors.textSecondary} style={styles.rowIcon} />
                <View style={styles.rowBody}>
                  <Text style={styles.rowTitle} numberOfLines={1}>{job.title}</Text>
                  <Text style={styles.rowSub} numberOfLines={1}>{job.customerName}</Text>
                </View>
                <Badge label={JOB_STATUSES[job.status]?.label ?? job.status} color={JOB_STATUSES[job.status]?.color ?? "muted"} />
              </TouchableOpacity>
            ))}
            {results.jobs.total > results.jobs.items.length && (
              <Text style={styles.moreHint}>+{results.jobs.total - results.jobs.items.length} more in Jobs</Text>
            )}
          </>
        )}

        {results.customers.total > 0 && (
          <>
            <Text style={styles.sectionLabel}>Customers</Text>
            {results.customers.items.map((customer) => (
              <TouchableOpacity
                key={customer.id}
                style={styles.row}
                onPress={() => openCustomer(customer)}
                accessibilityRole="button"
                accessibilityLabel={`Customer: ${customer.name}`}
              >
                <Ionicons name="person-outline" size={18} color={colors.textSecondary} style={styles.rowIcon} />
                <View style={styles.rowBody}>
                  <Text style={styles.rowTitle} numberOfLines={1}>{customer.name}</Text>
                  {(customer.phone || customer.email) ? (
                    <Text style={styles.rowSub} numberOfLines={1}>{customer.phone || customer.email}</Text>
                  ) : null}
                </View>
              </TouchableOpacity>
            ))}
            {results.customers.total > results.customers.items.length && (
              <Text style={styles.moreHint}>+{results.customers.total - results.customers.items.length} more in Customers</Text>
            )}
          </>
        )}

        {results.invoices.total > 0 && (
          <>
            <Text style={styles.sectionLabel}>Invoices</Text>
            {results.invoices.items.map((invoice) => {
              const status = getStatus(invoice);
              return (
                <TouchableOpacity
                  key={invoice.id}
                  style={styles.row}
                  onPress={() => openInvoice(invoice)}
                  accessibilityRole="button"
                  accessibilityLabel={`Invoice ${invoice.number}, ${invoice.customer}`}
                >
                  <Ionicons name="receipt-outline" size={18} color={colors.textSecondary} style={styles.rowIcon} />
                  <View style={styles.rowBody}>
                    <Text style={styles.rowTitle} numberOfLines={1}>{invoice.number} · {invoice.customer}</Text>
                    <Text style={styles.rowSub} numberOfLines={1}>{formatMoney(invoice.amount)} · {status.label}</Text>
                  </View>
                </TouchableOpacity>
              );
            })}
            {results.invoices.total > results.invoices.items.length && (
              <Text style={styles.moreHint}>+{results.invoices.total - results.invoices.items.length} more in Invoices</Text>
            )}
          </>
        )}
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    searchRow: { paddingHorizontal: spacing.md, paddingTop: spacing.md, paddingBottom: spacing.sm, ...layout.contentColumn },
    scroll: { paddingHorizontal: spacing.md, paddingBottom: 40, ...layout.contentColumn },
    sectionLabel: {
      fontFamily: fonts.mono, fontSize: fontSize.xs, color: colors.textSecondary,
      textTransform: "uppercase", letterSpacing: 0.8,
      marginTop: spacing.md, marginBottom: spacing.sm,
    },
    row: {
      flexDirection: "row",
      alignItems: "center",
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      marginBottom: spacing.xs,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
      minHeight: 52,
      ...shadow.card,
    },
    rowIcon: { marginRight: spacing.md },
    rowBody: { flex: 1, marginRight: spacing.sm },
    rowTitle: { fontFamily: fonts.bodyMedium, fontSize: fontSize.md, color: colors.textPrimary },
    rowSub: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 1 },
    moreHint: {
      fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted,
      marginBottom: spacing.sm, marginLeft: 2,
    },
  });
}
